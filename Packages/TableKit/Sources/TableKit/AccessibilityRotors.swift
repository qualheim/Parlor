// AccessibilityRotors — the pure rotor-entry + announcement derivation for VoiceOver (task 7.1; R-A11Y-1.2).
//
// R-A11Y-1.2 requires two things beyond per-element labels: CUSTOM ROTORS that let a VoiceOver user spin
// directly to "Hand" or "Piles" and step through those elements, and spoken ANNOUNCEMENTS of opponent
// actions and results. Both are derived here as pure values so they are unit-testable headless and carry
// no SwiftUI:
//
//   • `TableRotorModel` groups the on-table pieces into named rotors ("Hand", "Piles") whose entries point
//     at the exact `RenderKey`s the renderer draws, so `.accessibilityRotor` in the table view can focus
//     them. The grouping is derived from the resolved pieces + which zones are the local hand, so the rotor
//     can never list an element the table isn't showing.
//   • `AccessibilityAnnouncement` turns a `GameEvent` into the spoken line for opponent actions/results,
//     reusing `HUDModel.narrate` so the announcement, the caption, and the history are one derivation
//     (design.md §9). The App posts these via `AccessibilityNotification.Announcement` when events arrive;
//     the seam is `AccessibilityAnnouncer` below.
//
// No UI framework is imported here (R-BUILD-4.2); the SwiftUI application lives in the table view.

import EngineCore
import Foundation

// MARK: - Rotor model (R-A11Y-1.2)

/// One entry in a custom rotor: the `RenderKey` of a piece the rotor can focus, plus the spoken `label`
/// VoiceOver reads when it lands there. Derived from the resolved pieces so it always matches the view.
public struct RotorEntry: Sendable, Hashable, Identifiable {
    /// The render identity of the piece this entry focuses (matches the piece view's matched-geometry id).
    public let key: RenderKey
    /// The spoken label for the entry (the piece's `combinedLabel`).
    public let label: String

    public var id: RenderKey { key }

    public init(key: RenderKey, label: String) {
        self.key = key
        self.label = label
    }
}

/// A named custom rotor and its ordered entries — e.g. "Hand" or "Piles" (R-A11Y-1.2).
public struct Rotor: Sendable, Hashable, Identifiable {
    /// The rotor's spoken name, shown in the VoiceOver rotor picker.
    public let name: String
    /// The entries, in display/navigation order.
    public let entries: [RotorEntry]

    public var id: String { name }

    public init(name: String, entries: [RotorEntry]) {
        self.name = name
        self.entries = entries
    }
}

/// The complete set of custom rotors for a table: the "Hand" rotor (the local player's hand pieces) and
/// the "Piles" rotor (every other pile's top-of-pile entry), derived purely from resolved pieces
/// (R-A11Y-1.2). Empty rotors are omitted so VoiceOver never offers a rotor with nothing in it.
public struct TableRotorModel: Sendable, Hashable {
    /// The rotors to expose, in order. "Hand" first (most-used), then "Piles".
    public let rotors: [Rotor]

    public init(rotors: [Rotor]) {
        self.rotors = rotors
    }

    /// Derive the rotors from the resolved pieces on the table (R-A11Y-1.2).
    ///
    /// - Parameters:
    ///   - pieces: the resolved pieces the renderer is drawing.
    ///   - handZones: the `ZoneID`s that make up the LOCAL player's hand (grouped into the "Hand" rotor).
    ///   - describe: how to derive an entry's spoken label for a given piece (the same derivation the
    ///     piece view applies), so rotor labels never drift from element labels (design.md §9).
    ///
    /// The "Hand" rotor lists the hand pieces in pile order. The "Piles" rotor lists ONE entry per other
    /// zone — the top piece of each pile — so spinning the rotor steps pile to pile rather than card to
    /// card (piles are navigated by their top, hands card by card), matching how a sighted player scans.
    public static func derive(
        pieces: [ResolvedPiece],
        handZones: Set<ZoneID>,
        describe: (ResolvedPiece) -> String
    ) -> TableRotorModel {
        // Hand entries: every piece in a hand zone, in (zone, index) order.
        let handPieces =
            pieces
            .filter { handZones.contains($0.zone) }
            .sorted { lhs, rhs in
                if lhs.zone != rhs.zone {
                    return zoneSortKey(lhs.zone) < zoneSortKey(rhs.zone)
                }
                return lhs.index < rhs.index
            }
        let handEntries = handPieces.map { RotorEntry(key: $0.key, label: describe($0)) }

        // Pile entries: the top piece (highest index) of each non-hand zone, one per zone.
        var topByZone: [ZoneID: ResolvedPiece] = [:]
        for piece in pieces where !handZones.contains(piece.zone) {
            if let existing = topByZone[piece.zone], existing.index >= piece.index { continue }
            topByZone[piece.zone] = piece
        }
        let pileEntries =
            topByZone.values
            .sorted { zoneSortKey($0.zone) < zoneSortKey($1.zone) }
            .map { RotorEntry(key: $0.key, label: describe($0)) }

        var rotors: [Rotor] = []
        if !handEntries.isEmpty { rotors.append(Rotor(name: "Hand", entries: handEntries)) }
        if !pileEntries.isEmpty { rotors.append(Rotor(name: "Piles", entries: pileEntries)) }
        return TableRotorModel(rotors: rotors)
    }

    /// A stable sort key for a zone (name then owner) so rotor order is deterministic frame to frame.
    private static func zoneSortKey(_ zone: ZoneID) -> String {
        "\(zone.name)#\(zone.owner?.raw ?? "")"
    }
}

// MARK: - Announcements (R-A11Y-1.2)

/// A VoiceOver announcement derived from a `GameEvent`: the spoken `text` and whether it is
/// high-priority (results interrupt; routine turn/score updates queue). Pure and testable.
public struct AccessibilityAnnouncement: Sendable, Hashable {
    /// The line VoiceOver speaks.
    public let text: String
    /// Whether the announcement is high-priority — a result (hand ended) interrupts; routine updates do
    /// not. Maps to `AccessibilityNotification.Announcement`'s priority when posted by the App.
    public let isHighPriority: Bool

    public init(text: String, isHighPriority: Bool = false) {
        self.text = text
        self.isHighPriority = isHighPriority
    }

    /// Derive the announcement for a single `GameEvent`, reusing `HUDModel.narrate` so the spoken line
    /// matches the caption/history exactly (R-A11Y-1.2; design.md §9). Returns `nil` for events that have
    /// nothing to announce (pure-geometry deal/move/flip/reveal), which drive animation, not speech.
    ///
    /// A hand result (`handEnded`) is flagged high-priority so VoiceOver interrupts to speak it; everything
    /// else queues behind the current utterance.
    public static func from(
        _ event: GameEvent, nameForSeat: (SeatID) -> String
    ) -> AccessibilityAnnouncement? {
        guard let text = HUDModel.narrate(event, nameForSeat: nameForSeat) else { return nil }
        let highPriority: Bool
        if case .handEnded = event { highPriority = true } else { highPriority = false }
        return AccessibilityAnnouncement(text: text, isHighPriority: highPriority)
    }

    /// Derive announcements for a batch of events in order, dropping ones with nothing to say
    /// (R-A11Y-1.2). The App calls this when a `ResultEnvelope`'s events arrive and posts each in turn.
    public static func from(
        events: [GameEvent], nameForSeat: (SeatID) -> String
    ) -> [AccessibilityAnnouncement] {
        events.compactMap { from($0, nameForSeat: nameForSeat) }
    }
}
