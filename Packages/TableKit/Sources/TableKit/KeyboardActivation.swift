// KeyboardActivation — pure, testable resolution of NON-DRAG keyboard actions (R-A11Y-2.1, R-TABLE-3.4).
//
// Full keyboard play means EVERY action must be reachable with the keyboard, not just moves expressed as
// "drag piece P to zone Z". Some actions are not moves at all: drawing/recycling the stock in Klondike,
// drawing (or, when there is no legal play, passing) in Crazy Eights, and — after playing an 8 — choosing
// the next suit. Dragging cannot express these, so the keyboard needs a separate, first-class path.
//
// TableKit does not know any of these rules (R-SESS-1.2). So, exactly like `MoveTarget` supplies legal
// move destinations as host DATA, this file models the two remaining keyboard concerns as pure host-fed
// data + pure resolution functions, which `TableInteractionView` calls and `TableInteractionInput` (the
// seam) carries:
//
//   • `ZoneAction`          — a named non-drag action attached to a ZONE (e.g. "draw", "recycle", "pass"),
//                             with an opaque `id` the host maps back to a concrete `AnyGameAction`.
//   • `KeyboardActivation`  — the pure resolver: given the current `FocusTarget` and the host's available
//                             zone actions, return the action to invoke when the player presses
//                             space/return on a focused ZONE (or `nil` when there is none).
//   • `ChoiceOption` / `ChoicePrompt` — a game-agnostic modal keyboard choice (the suit picker is the
//                             canonical case): an ordered list of options the player navigates and selects
//                             by index or by a shortcut key, all pure and host-supplied.
//
// Everything here is a value type with no SwiftUI or rules dependency, so the resolution is exhaustively
// unit-tested headless. The view stays thin: it reads focus, calls `KeyboardActivation.action(for:in:)`,
// and invokes the returned action's host closure.

import EngineCore
import Foundation

// MARK: - ZoneAction (R-A11Y-2.1)

/// A non-drag action the host attaches to a ZONE, invokable from the keyboard by focusing that zone and
/// pressing space/return (R-A11Y-2.1).
///
/// The `id` is an opaque, host-defined token (e.g. `"draw"`, `"recycle"`, `"pass"`) that the host maps
/// back to a concrete game action when its `perform` closure runs — TableKit never interprets it. `zone`
/// is the zone the action lives on (the stock pile for draw/recycle; a hand or the table for pass). Only
/// one primary action per zone is offered to the keyboard; when a host wants several it lists several
/// `ZoneAction`s and TableKit picks the first for the focused zone (the host orders them by priority).
public struct ZoneAction: Sendable, Hashable {
    /// The zone this action is offered on (the focus target that activates it).
    public let zone: ZoneID
    /// An opaque, host-defined identifier for the action (e.g. "draw", "recycle", "pass").
    public let id: String
    /// A short human-readable title for VoiceOver / hint text (e.g. "Draw from stock").
    public let title: String

    public init(zone: ZoneID, id: String, title: String) {
        self.zone = zone
        self.id = id
        self.title = title
    }
}

// MARK: - KeyboardActivation (pure resolver)

/// Pure resolution of "which non-drag action does activating the current focus invoke?" (R-A11Y-2.1).
///
/// Stateless: the current focus and the host's available `ZoneAction`s are passed in and the action to run
/// (or `nil`) is returned, so the rule is a pure function the tests pin exactly. Only a `.zone` focus can
/// carry a primary action here (a `.piece` focus is handled by the existing select/place path); the first
/// action whose `zone` matches the focused zone wins, letting the host express priority by ordering.
public enum KeyboardActivation {
    /// The primary non-drag action to invoke when the player activates `focus`, or `nil` if none applies.
    ///
    /// Returns `nil` for a `.piece` focus (pieces are moved via select/place, not zone actions) and for a
    /// `.zone` focus with no matching action. When several actions target the focused zone, the FIRST in
    /// `actions` is chosen — the host orders them by priority (e.g. "recycle" only appears when the stock
    /// is empty, so at most one of draw/recycle is present for the stock zone at a time).
    public static func action(
        for focus: FocusTarget, in actions: [ZoneAction]
    ) -> ZoneAction? {
        guard case .zone(let zoneID) = focus else { return nil }
        return actions.first { $0.zone == zoneID }
    }

    /// Whether activating `focus` would invoke a non-drag zone action (for the view to decide whether to
    /// fall through to select/place). Convenience over `action(for:in:)`.
    public static func hasAction(
        for focus: FocusTarget, in actions: [ZoneAction]
    ) -> Bool {
        action(for: focus, in: actions) != nil
    }
}

// MARK: - ChoicePrompt (R-CE-2 suit choice; game-agnostic)

/// One option in a keyboard-navigable choice, e.g. a suit to name after playing an 8 (R-CE-2.\*).
///
/// Game-agnostic: `id` is an opaque host token (e.g. a suit name) mapped back to a concrete action by the
/// host; `title` is shown/spoken; `shortcut` is an optional single character that selects the option
/// directly (e.g. "H" for hearts). The suit picker is the canonical use, but any post-move modal choice
/// (name a suit, pick a pile, choose a scoring option) reuses this shape.
public struct ChoiceOption: Sendable, Hashable {
    /// An opaque, host-defined identifier for this option (e.g. "hearts").
    public let id: String
    /// A short human-readable title (e.g. "Hearts").
    public let title: String
    /// An optional single-character shortcut that selects this option directly (case-insensitive).
    public let shortcut: Character?

    public init(id: String, title: String, shortcut: Character? = nil) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
    }
}

/// A pure, keyboard-navigable modal choice: an ordered list of options with a current highlight index
/// (R-A11Y-2.1). The canonical case is the "name a suit" prompt after playing an 8 (R-CE-2.\*).
///
/// The host builds one of these when the rules demand a choice (its options derived from `legalActions`,
/// so it stays rules-owned), TableKit surfaces it as a focusable overlay, and selection is resolved purely
/// here: arrow/tab moves the highlight (`moving(_:)`), a shortcut key jumps to an option
/// (`option(forShortcut:)`), and space/return commits the highlighted option (`selected`). None of this
/// mutates game state — the view hands the chosen `ChoiceOption.id` back to the host to apply.
public struct ChoicePrompt: Sendable, Hashable {
    /// The options in display/navigation order (must be non-empty for a live prompt).
    public let options: [ChoiceOption]
    /// The index of the currently highlighted option (clamped into `options`).
    public private(set) var highlightedIndex: Int

    /// Create a prompt. `highlightedIndex` defaults to the first option; it is clamped into range so an
    /// out-of-bounds start is corrected rather than crashing.
    public init(options: [ChoiceOption], highlightedIndex: Int = 0) {
        self.options = options
        if options.isEmpty {
            self.highlightedIndex = 0
        } else {
            self.highlightedIndex = min(max(highlightedIndex, 0), options.count - 1)
        }
    }

    /// The currently highlighted option, or `nil` if there are no options.
    public var highlighted: ChoiceOption? {
        options.indices.contains(highlightedIndex) ? options[highlightedIndex] : nil
    }

    /// A copy with the highlight moved one step in `direction`, wrapping around the ends (R-A11Y-2.1).
    ///
    /// Left/Up move to the previous option; Right/Down to the next; both wrap. The choice is a small
    /// linear list, so a single wrapping ring is the natural keyboard model. Returns `self` unchanged when
    /// there are no options.
    public func moving(_ direction: FocusDirection) -> ChoicePrompt {
        guard !options.isEmpty else { return self }
        let delta: Int
        switch direction {
        case .left, .up: delta = -1
        case .right, .down: delta = 1
        }
        let next = (highlightedIndex + delta + options.count) % options.count
        return ChoicePrompt(options: options, highlightedIndex: next)
    }

    /// The option whose `shortcut` matches `character` (case-insensitive), or `nil` if none does.
    ///
    /// Lets the player jump straight to "Hearts" by pressing H rather than arrowing to it. Matching folds
    /// case so both "h" and "H" hit the same option.
    public func option(forShortcut character: Character) -> ChoiceOption? {
        let lowered = Character(character.lowercased())
        return options.first { option in
            guard let shortcut = option.shortcut else { return false }
            return Character(shortcut.lowercased()) == lowered
        }
    }

    /// The option that committing now (space/return) selects: the currently highlighted one.
    public var selected: ChoiceOption? { highlighted }
}
