// The GameDefinition protocol — one protocol that fully describes a game (R-ENG-5).
//
// The foundation's whole bet is that adding a game is game-specific modules ONLY: a `GameDefinition`
// conformance, AI strategies, a table layout, a rules doc, and a catalog entry — with no edits to
// EngineCore or TableKit (R-ENG-5.6; design.md §11). This file is the contract that makes that true.
// A conforming type supplies:
//
//   • metadata — a stable id, name, family, seat range, typical duration, complexity (R-ENG-5.1);
//   • an options schema — defaults plus named presets (R-ENG-5.2);
//   • `initialState(options:seed:)`, `phase(of:)`, and `legalActions(for:in:)` (R-ENG-5.3);
//   • `apply(_:by:to:)` returning either the new state + an ordered event list, or a typed
//     `RuleViolation` with a human-readable reason (R-ENG-5.4, R-NFR-QUAL.1); and
//   • terminal detection, per-hand outcome, view redaction, and an undo policy (R-ENG-5.5, R-ENG-7.3).
//
// State/Action/Options are associated types constrained to marker protocols so they are always
// `Codable & Sendable` — everything crossing the host boundary is (R-ENG-8.5, tech.md rule 4). Because
// the protocol is generic over those types, the engine never needs to know a specific game to run one;
// that is the mechanism behind "no EngineCore edits per game" (R-ENG-5.6). `AnyGameAction` type-erases
// an action for the log and views (task 2.7/2.6), which is the one place the engine handles actions
// without knowing the concrete game.
//
// Boundary types this protocol returns — `Viewer`, `GameEvent`, `PlayerView`, `HandOutcome`,
// `UndoPolicy` — live in `Views.swift` (`GameEvent`/`PlayerView` are minimal there and task 2.6
// extends them).

import Foundation

// MARK: - Marker protocols for the boundary payloads (R-ENG-8.5)

/// A game's authoritative state. `Codable & Sendable` so it can be hashed for the determinism contract
/// (R-ENG-4.4), saved, and passed to the host actor (R-ENG-8.5). Games define a concrete conforming
/// type; the engine treats it opaquely.
public protocol GameState: Codable, Sendable {}

/// A single move a seat can make. `Codable & Sendable` so it can be logged, type-erased into
/// `AnyGameAction`, and sent across the host boundary (R-ENG-8.5).
public protocol GameAction: Codable, Sendable {}

/// A game's configuration (variant/house-rule choices). `Codable & Sendable` so it can be snapshotted
/// into a save and carried in presets (R-ENG-5.2, R-ENG-8.5).
public protocol GameOptions: Codable, Sendable {}

// MARK: - Metadata (R-ENG-5.1)

/// The family a game belongs to, used to group it in the Library (R-APP-1.1) and to organize rules
/// modules (design.md §11).
///
/// Modeled as a value type wrapping a stable `id` string rather than a fixed enum, so a new family can
/// be introduced by a game module WITHOUT editing EngineCore (R-ENG-5.6). Well-known families are
/// provided as static constants for convenience; games may still mint their own.
public struct GameFamily: Codable, Sendable, Hashable, RawRepresentable {
    /// Stable, kebab-case family id, e.g. `"solitaire"`, `"shedding"`.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Solitaire / patience games (e.g. Klondike).
    public static let solitaire = GameFamily(rawValue: "solitaire")
    /// Shedding games where you race to empty your hand (e.g. Crazy Eights).
    public static let shedding = GameFamily(rawValue: "shedding")
    /// Trick-taking games (e.g. Euchre, Sheepshead).
    public static let trickTaking = GameFamily(rawValue: "trick-taking")
    /// Rummy-style melding games (e.g. Tile Rummy).
    public static let rummy = GameFamily(rawValue: "rummy")
}

/// A rough playing-time band for a game, shown in the Library and used by duration filters (R-APP-1.1).
///
/// Minutes are inclusive bounds; a "quick" game might be `5...15`. This is descriptive metadata, not a
/// timer — the actual game clock is a Klondike feature (R-KLON-3).
public struct DurationRange: Codable, Sendable, Hashable {
    /// Shortest typical play time, in minutes.
    public let minMinutes: Int
    /// Longest typical play time, in minutes.
    public let maxMinutes: Int

    public init(minMinutes: Int, maxMinutes: Int) {
        self.minMinutes = minMinutes
        self.maxMinutes = maxMinutes
    }
}

/// How involved a game is to learn/play, for Library presentation (R-ENG-5.1, R-APP-1.1).
public enum Complexity: String, Codable, Sendable, CaseIterable {
    case light
    case medium
    case heavy
}

/// A game's descriptive metadata: a stable id plus everything the Library and setup need to present it
/// (R-ENG-5.1).
///
/// `id` is the stable kebab-case identifier used throughout — save files, rules docs `Docs/Rules/<id>.md`,
/// the catalog (structure.md). `seatRange` bounds how many seats the game supports (`1...1` for
/// Solitaire, `2...5` for Crazy Eights). All fields are `Codable & Sendable` so metadata can be listed
/// and cached without instantiating the game.
public struct GameMetadata: Codable, Sendable, Hashable {
    /// Stable, kebab-case game id, e.g. `"klondike"`, `"crazy-eights"` (structure.md).
    public let id: String
    /// Human-readable display name, e.g. `"Klondike"`.
    public let name: String
    /// The family this game groups under (R-APP-1.1).
    public let family: GameFamily
    /// The supported number of seats, inclusive, e.g. `1...1` or `2...5` (R-ENG-5.1).
    public let seatRange: ClosedRange<Int>
    /// Typical play-time band, in minutes (R-APP-1.1 duration filter).
    public let typicalDuration: DurationRange
    /// How involved the game is (R-ENG-5.1).
    public let complexity: Complexity

    public init(
        id: String,
        name: String,
        family: GameFamily,
        seatRange: ClosedRange<Int>,
        typicalDuration: DurationRange,
        complexity: Complexity
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.seatRange = seatRange
        self.typicalDuration = typicalDuration
        self.complexity = complexity
    }
}

// MARK: - Options schema: defaults + named presets (R-ENG-5.2)

/// A named bundle of option choices — a one-tap starting point on the setup sheet (R-ENG-5.2, R-APP-2.1).
///
/// A preset is just a display `name` plus a concrete `Options` value (e.g. "Vegas" Klondike, "Classic"
/// Crazy Eights). Generic over the game's `Options` so it stays `Codable & Sendable` alongside them.
public struct OptionsPreset<Options: GameOptions>: Codable, Sendable {
    /// Human-readable preset name shown first on the setup sheet (R-APP-2.1).
    public let name: String
    /// The concrete option values this preset selects.
    public let options: Options

    public init(name: String, options: Options) {
        self.name = name
        self.options = options
    }
}

/// The options a game exposes: its `defaults` plus a list of named `presets` (R-ENG-5.2).
///
/// The setup sheet lists `presets` first, then the individual options; `defaults` is the value used when
/// no preset is chosen (R-APP-2.1). Generic over the game's `Options` type and `Codable & Sendable` so a
/// game can declare its whole schema as data.
public struct OptionsSchema<Options: GameOptions>: Codable, Sendable {
    /// The default option values, used when the player picks no preset (R-ENG-5.2).
    public let defaults: Options
    /// Named presets offered first on the setup sheet (R-ENG-5.2, R-APP-2.1).
    public let presets: [OptionsPreset<Options>]

    public init(defaults: Options, presets: [OptionsPreset<Options>] = []) {
        self.defaults = defaults
        self.presets = presets
    }

    /// Look up a preset by name, or `nil` if none matches.
    public func preset(named name: String) -> OptionsPreset<Options>? {
        presets.first { $0.name == name }
    }
}

// MARK: - Phase (R-ENG-5.3)

/// A named phase within a hand — dealing, bidding, playing tricks, scoring (R-ENG-5.3).
///
/// A lightweight string identifier rather than a fixed enum, so each game names its own phases without
/// editing EngineCore (R-ENG-5.6). The match model (task 2.7) sequences hands → phases → turns
/// (R-ENG-6.1); `GameDefinition.phase(of:)` reports which phase a given state is in.
public struct Phase: Codable, Sendable, Hashable, RawRepresentable, CustomStringConvertible {
    /// Stable phase id, e.g. `"deal"`, `"play"`, `"scoring"`.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

// MARK: - Rule violation (R-ENG-5.4, R-NFR-QUAL.1)

/// A typed rejection of an illegal action, carrying a machine `code` and a human-readable `reason`
/// (R-ENG-5.4).
///
/// Returned by `apply` (as the failure of its `Result`) when an action is not legal. The `reason` is the
/// text the table surfaces as the gentle spring-back caption — never a modal dialog (R-TABLE-4.1,
/// R-NFR-QUAL.1); `code` is a stable token for tests and the "why can't I play this?" explainer
/// (R-TABLE-3.5). Conforms to `Error` so `apply` can be used ergonomically, and `Codable & Sendable` so
/// it can cross the host boundary in a rejected result (R-ENG-8.5).
public struct RuleViolation: Error, Codable, Sendable, Hashable {
    /// Stable, machine-readable violation code, e.g. `"not-your-turn"`, `"wrong-color"`.
    public let code: String
    /// Human-readable reason shown as the spring-back caption (R-TABLE-4.1, R-NFR-QUAL.1).
    public let reason: String

    public init(code: String, reason: String) {
        self.code = code
        self.reason = reason
    }
}

// MARK: - Type-erased action (for log/views — task 2.6/2.7)

/// A type-erased, `Codable` game action for use where the engine handles actions without knowing the
/// concrete game — the action log's `LogEntry` (R-ENG-7.1) and a view's own legal actions (R-ENG-8.2).
///
/// It preserves the concrete action's stable `typeName` plus its canonical JSON `payload`, so a logged
/// action round-trips and stays inspectable without EngineCore depending on any game (R-ENG-5.6). The
/// full match log/view integration is task 2.6/2.7; this type is introduced here because those tasks and
/// the boundary types reference it, and because it lets `apply` results be logged generically.
public struct AnyGameAction: Codable, Sendable, Hashable {
    /// A stable identifier for the concrete action type (e.g. its type name), for decoding/inspection.
    public let typeName: String
    /// The canonical JSON encoding of the concrete action (sorted keys), as UTF-8 bytes.
    public let payload: Data

    public init(typeName: String, payload: Data) {
        self.typeName = typeName
        self.payload = payload
    }

    /// Type-erase a concrete `GameAction` by capturing its type name and canonical encoding.
    ///
    /// Uses sorted-key JSON so the erased form is stable (matching the state-hash canonicalization,
    /// ADR 0002 decision 4), which keeps logged actions comparable across runs.
    public init<Action: GameAction>(_ action: Action) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.typeName = String(describing: Action.self)
        self.payload = try encoder.encode(action)
    }

    /// Recover the concrete action, decoding the payload as `Action`.
    public func decode<Action: GameAction>(as type: Action.Type) throws -> Action {
        try JSONDecoder().decode(Action.self, from: payload)
    }
}

// MARK: - GameDefinition (R-ENG-5)

/// One protocol that fully describes a game (R-ENG-5). Conforming — plus AI, layout, a rules doc, and a
/// catalog entry — is the *entire* contribution of a new game; EngineCore and TableKit are never edited
/// (R-ENG-5.6; design.md §11).
///
/// `State`, `Action`, and `Options` are the game's own `Codable & Sendable` types. A definition is a
/// pure description: `initialState` builds a hand from options + a recorded seed (R-ENG-5.3, R-ENG-4.3),
/// `legalActions` enumerates what a seat may do, and `apply` is the single transition function — it
/// returns the next state with an ordered event list, or a typed `RuleViolation` (R-ENG-5.4). Terminal
/// detection, per-hand `outcome`, `redactedView`, and `undoPolicy` complete the description (R-ENG-5.5,
/// R-ENG-7.3). `Sendable` because the host actor holds a definition and calls it across the concurrency
/// boundary (R-SESS-1.1).
public protocol GameDefinition: Sendable {
    /// The game's authoritative state type.
    associatedtype State: GameState
    /// The game's action type — one move a seat can make.
    associatedtype Action: GameAction
    /// The game's configuration type (variant/house-rule choices).
    associatedtype Options: GameOptions

    /// Descriptive metadata: stable id, name, family, seat range, duration, complexity (R-ENG-5.1).
    static var metadata: GameMetadata { get }

    /// The options schema: defaults plus named presets (R-ENG-5.2).
    static var optionsSchema: OptionsSchema<Options> { get }

    /// Build the initial state for a hand from `options` and a recorded `seed` (R-ENG-5.3, R-ENG-4.3).
    ///
    /// The seed drives all shuffling via `SeededRNG`/`Shuffle`, so the same options + seed always
    /// produce the same starting position (R-ENG-4.4).
    func initialState(options: Options, seed: UInt64) -> State

    /// The current phase of `state` (R-ENG-5.3).
    func phase(of state: State) -> Phase

    /// Every legal action `seat` may take in `state` (R-ENG-5.3).
    ///
    /// Empty when the seat has no move (e.g. it is not their turn). Drives legal-target highlighting
    /// (R-TABLE-3.6) and bounds AI/search.
    func legalActions(for seat: SeatID, in state: State) -> [Action]

    /// Apply `action` taken `by` a seat `to` a state (R-ENG-5.4).
    ///
    /// On success returns the new state plus the ordered `GameEvent`s the transition produced (which
    /// feed animation, captions, VoiceOver, sound, and the log, R-ENG-8.1). On failure returns a typed
    /// `RuleViolation` whose `reason` is the human-readable spring-back caption (R-TABLE-4.1,
    /// R-NFR-QUAL.1). Pure: it never mutates `state` in place.
    func apply(_ action: Action, by seat: SeatID, to state: State)
        -> Result<(State, [GameEvent]), RuleViolation>

    /// Whether `state` is terminal — the hand is over (R-ENG-5.5).
    func isTerminal(_ state: State) -> Bool

    /// The scoring/outcome of `state` as a finished hand (R-ENG-5.5, R-ENG-6.3).
    func outcome(_ state: State) -> HandOutcome

    /// The redacted view of `state` for `viewer`, revealing only what that observer may see
    /// (R-ENG-5.5, R-ENG-8.2).
    ///
    /// Redaction follows each zone's visibility policy plus per-piece face state (R-ENG-3.3); hidden
    /// pieces must never leak their identity (R-ENG-8.3). The full token-permutation guarantee is task
    /// 2.6; the requirement is declared here in the protocol.
    func redactedView(of state: State, for viewer: Viewer) -> PlayerView

    /// The undo policy this game permits (R-ENG-7.3).
    var undoPolicy: UndoPolicy { get }
}
