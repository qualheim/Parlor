// HUDModel — the pure, testable state behind the table HUD (task 5.6; R-TABLE-6.1–6.3).
//
// R-TABLE-6 asks for a *quiet, complete* HUD: seat plates, a scoreboard, a caption bar, a history drawer,
// a pause menu, and a toolbar — laid out so it never covers the cards a player needs (R-TABLE-6.1–6.3).
// Following the same split the rest of TableKit uses (a pure value core with a thin SwiftUI shell on top —
// see `TableRenderModel`, `LayoutResolver`, `AnimationQueue`), this file is the FOUNDATION-ONLY heart of
// the HUD. It holds no SwiftUI: every decision a HUD makes — which seat is active, what a seat plate shows,
// which seat leads the scoreboard, how the event stream narrates into history, where the HUD's chrome sits
// so it clears the play zones — is a plain, deterministic value computed here and unit-tested headless.
//
// The SwiftUI views (`SeatPlateView`, `ScoreboardView`, `CaptionBarView`, `HistoryDrawerView`,
// `PauseMenuView`, `TableToolbarView`, and the composing `TableHUDView`) live in `HUDView.swift` and are
// intentionally thin over these types. The seat RING (local player bottom-center, others clockwise) reuses
// the existing `SeatArrangement` (TableLayout.swift) so plate positions match the exact anchors the
// renderer already uses for per-seat zones — the HUD and the table never disagree about where a seat is.

import CoreGraphics
import EngineCore
import Foundation

// MARK: - Role badge (R-TABLE-6.2)

/// A short role a seat plate can advertise — the "role badges" R-TABLE-6.2 calls for (dealer is shown
/// separately as the dealer button; these are the other, game-supplied roles).
///
/// Kept a small closed set plus a free-form `.custom` so a game can surface its own role words (e.g. a
/// Sheepshead "Picker") without TableKit knowing every game. Each carries a short `label` the plate draws
/// and VoiceOver reads. Roles are additive: a seat can be both the leader and to-play, for instance.
public enum SeatRole: Sendable, Hashable, Codable {
    /// The seat currently leading the match by cumulative score.
    case leader
    /// The seat that leads/opens the current trick or round.
    case toLead
    /// A game-specific role, carrying its own short label (e.g. "Picker", "Declarer").
    case custom(String)

    /// The short word shown on the badge and read by VoiceOver.
    public var label: String {
        switch self {
        case .leader: return "Leader"
        case .toLead: return "Lead"
        case .custom(let text): return text
        }
    }
}

// MARK: - Seat plate state (R-TABLE-6.2)

/// Everything one seat plate shows, as a pure value (R-TABLE-6.2).
///
/// A plate advertises the seat's `profile` (avatar + name via `AvatarReference`/`displayName`), its
/// current `score`, whether it holds the `isDealer` button, whether it is the `isActiveTurn` seat (which
/// drives the active-turn glow), whether its AI is currently `isThinking` (the thinking indicator), and any
/// `roles` badges. It is built by `HUDModel.seatPlate(...)` from the engine's profile + `Match` + turn/
/// thinking signals, so the plate view is a pure function of this value.
public struct SeatPlateState: Sendable, Hashable, Identifiable {
    /// The seat this plate represents.
    public let seat: SeatID
    /// The identity occupying the seat (avatar + display name + controller kind).
    public let profile: PlayerProfile
    /// The seat's current score to show (cumulative match score, typically).
    public let score: Int
    /// Whether this seat holds the dealer button (R-TABLE-6.2).
    public let isDealer: Bool
    /// Whether it is currently this seat's turn — drives the active-turn glow (R-TABLE-6.2).
    public let isActiveTurn: Bool
    /// Whether this seat's AI is currently deciding — drives the thinking indicator (R-TABLE-6.2).
    public let isThinking: Bool
    /// The seat's role badges, in display order (R-TABLE-6.2).
    public let roles: [SeatRole]

    /// Stable identity for `ForEach`.
    public var id: SeatID { seat }

    public init(
        seat: SeatID,
        profile: PlayerProfile,
        score: Int,
        isDealer: Bool = false,
        isActiveTurn: Bool = false,
        isThinking: Bool = false,
        roles: [SeatRole] = []
    ) {
        self.seat = seat
        self.profile = profile
        self.score = score
        self.isDealer = isDealer
        self.isActiveTurn = isActiveTurn
        self.isThinking = isThinking
        self.roles = roles
    }

    /// Whether this seat is driven by an AI persona (thinking indicator is only meaningful for AI seats).
    public var isAI: Bool {
        if case .ai = profile.controllerKind { return true }
        return false
    }

    /// A single VoiceOver-friendly sentence summarizing the plate, derived from the same fields the plate
    /// draws so the spoken label can never drift from the visuals (R-A11Y-1.2, design.md §9). E.g.
    /// "Even Steven, 40 points, dealer, to play, thinking".
    public var accessibilitySummary: String {
        var parts: [String] = [profile.displayName, "\(score) points"]
        if isDealer { parts.append("dealer") }
        for role in roles { parts.append(role.label.lowercased()) }
        if isActiveTurn { parts.append("to play") }
        if isThinking { parts.append("thinking") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Scoreboard (R-TABLE-6.1)

/// One row of the scoreboard: a seat, its display name, its cumulative score, and whether it currently
/// leads the match (R-TABLE-6.1). A pure value the scoreboard view renders directly.
public struct ScoreboardRow: Sendable, Hashable, Identifiable {
    /// The seat this row is for.
    public let seat: SeatID
    /// The name shown for the seat.
    public let name: String
    /// The seat's cumulative match score.
    public let score: Int
    /// Whether this seat is (tied for) the match leader — highlighted in the scoreboard.
    public let isLeader: Bool

    public var id: SeatID { seat }

    public init(seat: SeatID, name: String, score: Int, isLeader: Bool) {
        self.seat = seat
        self.name = name
        self.score = score
        self.isLeader = isLeader
    }
}

/// The scoreboard model: the rows to show plus how many hands have been played and whether the match is
/// over (R-TABLE-6.1). Built from `Match` + the seat profiles, sorted highest score first.
public struct ScoreboardModel: Sendable, Hashable {
    /// The rows, sorted by score descending (ties broken by seat id for stable order).
    public let rows: [ScoreboardRow]
    /// How many hands have completed (from the match summaries).
    public let handsPlayed: Int
    /// Whether the match has ended under its end condition.
    public let isMatchOver: Bool

    public init(rows: [ScoreboardRow], handsPlayed: Int, isMatchOver: Bool) {
        self.rows = rows
        self.handsPlayed = handsPlayed
        self.isMatchOver = isMatchOver
    }
}

// MARK: - History (R-TABLE-6.1)

/// One entry in the history drawer: an ordered narration line for something that happened in the match
/// (R-TABLE-6.1). Built from the same `GameEvent` stream that drives animation/captions/VoiceOver, so the
/// history can never drift from what actually occurred (design.md §9).
public struct HistoryEntry: Sendable, Hashable, Identifiable {
    /// A stable, ascending ordinal (the entry's position in the history).
    public let index: Int
    /// The human-readable narration line.
    public let text: String

    public var id: Int { index }

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

// MARK: - Toolbar (R-TABLE-6.1)

/// A toolbar action the HUD offers — exactly the five R-TABLE-6.1 names (New, Undo, Hint, Rules, Menu).
///
/// `CaseIterable` in the required left→right order, each carrying a `title` and an SF Symbol `systemImage`
/// so the toolbar view is a pure function of the enum. `Undo` and `Hint` can be disabled (no undo
/// available / no hint) — the enabled set is supplied to the view; the enum itself just names the actions.
public enum ToolbarAction: String, Sendable, Hashable, CaseIterable, Identifiable {
    case new
    case undo
    case hint
    case rules
    case menu

    public var id: String { rawValue }

    /// The button title.
    public var title: String {
        switch self {
        case .new: return "New"
        case .undo: return "Undo"
        case .hint: return "Hint"
        case .rules: return "Rules"
        case .menu: return "Menu"
        }
    }

    /// The SF Symbol name for the button.
    public var systemImage: String {
        switch self {
        case .new: return "plus.square.on.square"
        case .undo: return "arrow.uturn.backward"
        case .hint: return "lightbulb"
        case .rules: return "book"
        case .menu: return "line.3.horizontal"
        }
    }

    /// A short VoiceOver hint describing what activating the control does (R-A11Y-1.1 — every control
    /// carries a hint, not just a label).
    public var accessibilityHint: String {
        switch self {
        case .new: return "Starts a new game"
        case .undo: return "Undoes your last move"
        case .hint: return "Suggests a move"
        case .rules: return "Opens the rules"
        case .menu: return "Opens the menu"
        }
    }
}

// MARK: - Pause menu (R-TABLE-6.1)

/// One item in the pause menu (R-TABLE-6.1). A small closed set covering the standard pause actions plus a
/// `.custom` escape hatch a game/host can add. Each carries a `title` and SF Symbol so the menu view is a
/// pure function of the item list.
public enum PauseMenuItem: Sendable, Hashable, Identifiable {
    /// Dismiss the pause menu and return to the game.
    case resume
    /// Restart the current deal/hand.
    case restart
    /// Start a brand-new game.
    case newGame
    /// Open settings.
    case settings
    /// Open the rules inspector.
    case rules
    /// Quit to the library.
    case quitToLibrary
    /// A game/host-specific item carrying its own id, title, and symbol.
    case custom(id: String, title: String, systemImage: String)

    public var id: String {
        switch self {
        case .resume: return "resume"
        case .restart: return "restart"
        case .newGame: return "newGame"
        case .settings: return "settings"
        case .rules: return "rules"
        case .quitToLibrary: return "quitToLibrary"
        case .custom(let id, _, _): return "custom.\(id)"
        }
    }

    /// The item's title.
    public var title: String {
        switch self {
        case .resume: return "Resume"
        case .restart: return "Restart Deal"
        case .newGame: return "New Game"
        case .settings: return "Settings"
        case .rules: return "Rules"
        case .quitToLibrary: return "Quit to Library"
        case .custom(_, let title, _): return title
        }
    }

    /// The item's SF Symbol.
    public var systemImage: String {
        switch self {
        case .resume: return "play.fill"
        case .restart: return "arrow.counterclockwise"
        case .newGame: return "plus.square.on.square"
        case .settings: return "gearshape"
        case .rules: return "book"
        case .quitToLibrary: return "rectangle.portrait.and.arrow.right"
        case .custom(_, _, let symbol): return symbol
        }
    }

    /// The default pause-menu item list, in display order (R-TABLE-6.1).
    public static let standard: [PauseMenuItem] = [
        .resume, .restart, .newGame, .settings, .rules, .quitToLibrary,
    ]
}

// MARK: - HUD chrome regions (R-TABLE-6.3)

/// The reserved chrome regions the HUD lays its components in, in NORMALIZED (0…1) table space
/// (R-TABLE-6.3).
///
/// R-TABLE-6.3 is the load-bearing constraint: the HUD must NOT cover the cards a player needs. Rather than
/// float the toolbar/scoreboard over the felt and hope they miss the piles, the HUD reserves thin bands at
/// the table EDGES — a top band (scoreboard/caption), a bottom band (toolbar), and left/right rails
/// (history drawer, when open) — and the layout is arranged so the play zones sit in the central region
/// between them. `playRegion` is the inset rectangle the renderer's zones should occupy; a game's
/// `TableLayout` places its zones inside it, so HUD chrome and cards never overlap. All regions are pure
/// geometry, so the "no overlap" guarantee is unit-testable (see `HUDLayout.overlaps`).
public struct HUDLayout: Sendable, Hashable {
    /// The top chrome band (scoreboard + caption bar), full width.
    public let topBand: NormalizedRect
    /// The bottom chrome band (toolbar), full width.
    public let bottomBand: NormalizedRect
    /// The right rail the history drawer occupies when open (empty width when closed).
    public let rightRail: NormalizedRect
    /// The central region reserved for play zones — the area a game's layout should keep its cards within
    /// so the HUD never covers them (R-TABLE-6.3).
    public let playRegion: NormalizedRect

    public init(
        topBand: NormalizedRect,
        bottomBand: NormalizedRect,
        rightRail: NormalizedRect,
        playRegion: NormalizedRect
    ) {
        self.topBand = topBand
        self.bottomBand = bottomBand
        self.rightRail = rightRail
        self.playRegion = playRegion
    }

    /// Compute the HUD chrome layout for the given band thicknesses (as fractions of the table height/
    /// width), reserving the top/bottom bands and (when `historyOpen`) the right rail, and deriving the
    /// central `playRegion` as what remains (R-TABLE-6.3).
    ///
    /// Thicknesses are clamped so the bands can never eat the whole table (the play region always keeps at
    /// least a sliver), which keeps the guarantee well-formed for any inputs.
    public static func standard(
        topBandHeight: CGFloat = 0.12,
        bottomBandHeight: CGFloat = 0.11,
        rightRailWidth: CGFloat = 0.22,
        historyOpen: Bool = false
    ) -> HUDLayout {
        // Clamp each band so top+bottom < 1 and the rail < 1, leaving a non-empty play region.
        let top = clamp(topBandHeight, upper: 0.45)
        let bottom = clamp(bottomBandHeight, upper: 0.45)
        let rail = historyOpen ? clamp(rightRailWidth, upper: 0.5) : 0

        let topBand = NormalizedRect(x: 0, y: 0, width: 1, height: top)
        let bottomBand = NormalizedRect(x: 0, y: 1 - bottom, width: 1, height: bottom)
        let rightRail = NormalizedRect(x: 1 - rail, y: top, width: rail, height: 1 - top - bottom)

        let playRegion = NormalizedRect(
            x: 0,
            y: top,
            width: 1 - rail,
            height: max(0.05, 1 - top - bottom))
        return HUDLayout(
            topBand: topBand, bottomBand: bottomBand, rightRail: rightRail, playRegion: playRegion)
    }

    /// Whether two normalized rects overlap (share any interior area). Used to prove HUD chrome does not
    /// intrude on the play region (R-TABLE-6.3) in tests.
    public static func overlaps(_ a: NormalizedRect, _ b: NormalizedRect) -> Bool {
        let ax2 = a.x + a.width
        let ay2 = a.y + a.height
        let bx2 = b.x + b.width
        let by2 = b.y + b.height
        // Treat touching edges as non-overlapping (a band that ends where the play region begins is fine).
        return a.x < bx2 && ax2 > b.x && a.y < by2 && ay2 > b.y
    }

    private static func clamp(_ v: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(v, 0), upper)
    }
}

// MARK: - HUDModel (the pure builders — R-TABLE-6.1, 6.2)

/// The pure HUD builder: turns engine data (`PlayerProfile`s, `Match`, the turn/thinking signals, and the
/// `GameEvent` stream) into the value types the HUD views render (R-TABLE-6.1, R-TABLE-6.2).
///
/// Namespaced as an empty enum of static functions (like `TableFocusModel`): no instance state, just pure
/// transforms that are trivially unit-testable. The SwiftUI HUD calls these to derive plates, the
/// scoreboard, and the history, then renders the results.
public enum HUDModel {
    // MARK: Seat ordering & positioning

    /// The seat plate anchor for `seatIndex` of `count` seats, reusing the renderer's `SeatArrangement`
    /// so plates sit exactly where the table places that seat's zones — local player bottom-center, others
    /// clockwise (R-TABLE-6.2). Returned in normalized (0…1) table space.
    public static func seatAnchor(
        seatIndex: Int, seatCount: Int, seating: SeatArrangement = SeatArrangement()
    ) -> CGPoint {
        seating.anchor(seatIndex: seatIndex, count: seatCount)
    }

    /// Build one seat's plate state from its profile, the match, and the live turn/thinking signals
    /// (R-TABLE-6.2).
    ///
    /// Score comes from the match's cumulative scores (0 if the seat has none yet). Dealer is the match's
    /// current dealer. `activeSeat` (the seat whose turn it is) drives the glow; `thinkingSeats` (the AI
    /// seats currently deciding) drives the thinking indicator, but only for AI seats. Leader/other roles
    /// are supplied by the caller in `extraRoles` (a game knows its own roles), and the match leader is
    /// added automatically.
    public static func seatPlate(
        seat: SeatID,
        profile: PlayerProfile,
        match: Match,
        activeSeat: SeatID?,
        thinkingSeats: Set<SeatID> = [],
        extraRoles: [SeatRole] = []
    ) -> SeatPlateState {
        var roles = extraRoles
        if match.leaders.contains(seat) && !match.cumulativeScores.isEmpty
            && !roles.contains(.leader)
        {
            roles.append(.leader)
        }
        let isAI: Bool
        if case .ai = profile.controllerKind { isAI = true } else { isAI = false }
        return SeatPlateState(
            seat: seat,
            profile: profile,
            score: match.cumulativeScores[seat] ?? 0,
            isDealer: match.dealer == seat,
            isActiveTurn: activeSeat == seat,
            isThinking: isAI && thinkingSeats.contains(seat),
            roles: roles)
    }

    /// Build every seat plate for the table, in the caller's seat order (index 0 = local player), pairing
    /// each seat with its profile (R-TABLE-6.2). Seats without a profile in `profiles` are skipped.
    public static func seatPlates(
        seatOrder: [SeatID],
        profiles: [SeatID: PlayerProfile],
        match: Match,
        activeSeat: SeatID?,
        thinkingSeats: Set<SeatID> = [],
        extraRoles: [SeatID: [SeatRole]] = [:]
    ) -> [SeatPlateState] {
        seatOrder.compactMap { seat in
            guard let profile = profiles[seat] else { return nil }
            return seatPlate(
                seat: seat,
                profile: profile,
                match: match,
                activeSeat: activeSeat,
                thinkingSeats: thinkingSeats,
                extraRoles: extraRoles[seat] ?? [])
        }
    }

    // MARK: Scoreboard

    /// Build the scoreboard model from the match and the seat profiles, sorted highest score first
    /// (R-TABLE-6.1). Ties are broken by seat id so the order is stable frame to frame. A seat with no
    /// recorded score shows 0. Leader rows are flagged from `match.leaders`.
    public static func scoreboard(
        seatOrder: [SeatID],
        profiles: [SeatID: PlayerProfile],
        match: Match
    ) -> ScoreboardModel {
        let leaders = Set(match.leaders)
        let hasScores = !match.cumulativeScores.isEmpty
        let rows =
            seatOrder
            .map { seat -> ScoreboardRow in
                ScoreboardRow(
                    seat: seat,
                    name: profiles[seat]?.displayName ?? seat.raw,
                    score: match.cumulativeScores[seat] ?? 0,
                    isLeader: hasScores && leaders.contains(seat))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.seat.raw < rhs.seat.raw
            }
        return ScoreboardModel(
            rows: rows,
            handsPlayed: match.completedHandCount,
            isMatchOver: match.isMatchOver)
    }

    // MARK: History narration

    /// Narrate a single `GameEvent` into a short history/caption line, resolving seat ids to display names
    /// via `nameForSeat` (R-TABLE-6.1; design.md §9). Returns `nil` for events that are pure geometry with
    /// nothing to say (a plain move/flip/reveal); those drive animation, not the history log.
    ///
    /// `captioned` events already carry a `LocalizedKey`; here we surface its arguments joined into a
    /// readable line (the App resolves the key against its string catalog at render time — this pure layer
    /// gives a sensible fallback usable headless and in tests).
    public static func narrate(
        _ event: GameEvent,
        nameForSeat: (SeatID) -> String
    ) -> String? {
        switch event {
        case .turnChanged(let seat):
            return "\(nameForSeat(seat)) to play"
        case .trickWon(let seat):
            return "\(nameForSeat(seat)) won the trick"
        case .scoreChanged(let seat, let delta, let total):
            let sign = delta >= 0 ? "+" : ""
            return "\(nameForSeat(seat)) \(sign)\(delta) (\(total))"
        case .suitNamed(let suit, let seat):
            return "\(nameForSeat(seat)) named \(suit.rawValue.capitalized)"
        case .handEnded(let outcome):
            if outcome.winners.isEmpty {
                return "Hand ended in a draw"
            }
            let names = outcome.winners.map(nameForSeat).joined(separator: ", ")
            return "Hand won by \(names)"
        case .captioned(let key):
            // Fall back to the key's arguments (a human-supplied sentence usually) or the key itself.
            return key.arguments.isEmpty ? key.key : key.arguments.joined(separator: " ")
        case .dealt, .pieceMoved, .pieceFlipped, .pieceRevealed:
            return nil
        }
    }

    /// Build the ordered history entries from an event stream, dropping events with nothing to narrate
    /// (R-TABLE-6.1). Entries are indexed in stream order so the drawer shows them chronologically.
    public static func history(
        events: [GameEvent],
        nameForSeat: (SeatID) -> String
    ) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for event in events {
            if let text = narrate(event, nameForSeat: nameForSeat) {
                out.append(HistoryEntry(index: out.count, text: text))
            }
        }
        return out
    }
}
