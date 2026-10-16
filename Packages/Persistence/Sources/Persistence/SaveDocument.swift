// The versioned, Codable save document — the on-disk shape a game session persists to and resumes from
// (R-PERS-1, R-PERS-2, R-PERS-3; design.md §4).
//
// A save is the authoritative record a session runs from, frozen to disk: the recorded action log plus
// the seeds and options needed to replay it, plus the match bookkeeping and the seating. It is exactly the
// document design.md §4 specifies — a `schemaVersion`, a stable `gameID`, created/updated metadata, an
// options snapshot, the `match`, the `seats`, the `actionLog`, and a `cursor` (the last applied log index =
// the resume point). Restore rebuilds the host by replaying `actionLog` against `match.handSeeds` /
// `options`, so restore + continue equals an uninterrupted run (R-PERS-1.2, R-QA-4.1).
//
// GENERIC OVER OPTIONS. A game's `Options` are game-specific (GameDefinition.swift), but everything else in
// the save is game-agnostic (log entries are type-erased `AnyGameAction`, the match/seats are engine
// types). Rather than erase the options too — which would lose their concrete shape — the document is
// generic over the game's `Options`, mirroring how `GameHost` is generic over its `Game`. The autosave
// layer, which already knows the concrete game, encodes/decodes the matching `SaveDocument<Options>`. This
// keeps the options snapshot strongly typed and round-trippable while the rest of the document stays
// game-independent.
//
// SCHEMA VERSIONING (the migration SEAM, not the chain — task 6.1). The document carries a
// `schemaVersion`; decoding tolerates an absent version (older encodings) and records the version a value
// was produced with, matching the convention EngineCore's boundary types use (Views.swift `PlayerView`).
// The `CURRENT` version constant and this field are the clean seam task 6.2 hangs the migration REGISTRY
// and corruption handling off of; this task deliberately does NOT build the migration chain.

import Foundation

// MARK: - Seat snapshot (design.md §4 "seats")

/// One seat as recorded in a save: the seat's position id, who occupied it, and how it was controlled
/// (design.md §4 `seats`; R-SESS-5.1).
///
/// This freezes the identity + controller binding a running session had, so a restored session seats the
/// same players and re-binds the same controllers (the host/session layer instantiates live controllers
/// from `controller` + `persona`/`difficulty`; a `SavedSeat` is pure data, like `PlayerProfile`,
/// Profiles.swift). For an AI seat, `persona` names the bundled `AIPersona` and `difficulty` records the
/// tier it played at, so a resumed game keeps the same opponents (R-PERS-1.2). Everything is `Codable`,
/// so a seat round-trips in the save (R-ENG-8.5).
public struct SavedSeat: Codable, Sendable, Hashable {
    /// The seat position this record describes (e.g. `seat-0`).
    public let id: SeatID
    /// The profile that occupied the seat — a human's local profile or an AI persona's profile.
    public let profile: PlayerProfile
    /// Which kind of controller drove the seat, mirroring `PlayerProfile.controllerKind` at save time.
    public let controller: ControllerKind
    /// The persona driving an AI seat, or `nil` for a human seat (design.md §4 `persona`).
    public let persona: PersonaID?
    /// The difficulty tier an AI seat played at, or `nil` for a human seat (design.md §4 `difficulty`).
    public let difficulty: DifficultyTier?

    public init(
        id: SeatID,
        profile: PlayerProfile,
        controller: ControllerKind,
        persona: PersonaID? = nil,
        difficulty: DifficultyTier? = nil
    ) {
        self.id = id
        self.profile = profile
        self.controller = controller
        self.persona = persona
        self.difficulty = difficulty
    }

    /// Build a `SavedSeat` from a seat id and the `PlayerProfile` occupying it, deriving the controller
    /// kind (and, for an AI seat, its persona + difficulty) from the profile so the recorded seat always
    /// matches the profile it was made from.
    ///
    /// `personaDifficulty` supplies the tier for an AI seat (the profile references a persona by id but
    /// does not itself carry a tier); the caller — which resolved the persona to seat it — passes it.
    public init(id: SeatID, profile: PlayerProfile, personaDifficulty: DifficultyTier? = nil) {
        self.id = id
        self.profile = profile
        self.controller = profile.controllerKind
        switch profile.controllerKind {
        case .localHuman:
            self.persona = nil
            self.difficulty = nil
        case .ai(let persona):
            self.persona = persona
            self.difficulty = personaDifficulty
        }
    }
}

// MARK: - Save document (design.md §4)

/// The versioned, Codable save document a session writes after every accepted action and resumes from on
/// relaunch (R-PERS-1.1, R-PERS-1.2; design.md §4).
///
/// Generic over the game's `Options` so the options snapshot stays strongly typed while the rest of the
/// document is game-agnostic (see the file header). The document is the single source a restore needs:
/// rebuild the initial state from `options` + the recorded seed(s) in `match.handSeeds`, replay
/// `actionLog` in order (each entry carries its resulting state hash for verification), and the session is
/// exactly where it left off — `cursor` naming the last applied log index (R-PERS-1.2, R-QA-4.1).
///
/// `createdAt`/`updatedAt` are metadata only and never feed the determinism hash (tech.md rule 8); they
/// are for display and housekeeping. Local storage only — the document lives in the sandbox container, no
/// cloud (R-PERS-3.1, enforced by `SaveStore`).
public struct SaveDocument<Options: GameOptions>: Codable, Sendable {
    /// The save schema version this document was written with. Bumped on any format change; the seam
    /// task 6.2 attaches the migration registry to (R-PERS-2.1; design.md §4).
    public static var currentSchemaVersion: Int { 1 }

    /// The schema version of this document (R-PERS-2.1). Defaults to `currentSchemaVersion`; decoding an
    /// older save with no version treats it as version 1 (see `init(from:)`).
    public let schemaVersion: Int

    /// The stable, kebab-case game id this save belongs to, e.g. `"crazy-eights"` — used to route a save
    /// to the right game on resume (structure.md; design.md §4).
    public let gameID: String

    /// When the save was first created — metadata only, never hashed (tech.md rule 8).
    public let createdAt: Date

    /// When the save was last written (after the most recent accepted action) — metadata only
    /// (tech.md rule 8).
    public var updatedAt: Date

    /// The game options snapshot the session was configured with; restore rebuilds the initial state from
    /// these plus the recorded seed (R-ENG-5.3; design.md §4 `options`).
    public let options: Options

    /// The match bookkeeping: per-hand seeds, dealer, cumulative scores, end condition, and per-hand
    /// summaries (R-ENG-6; design.md §4 `match`). `handSeeds` is what restore replays against.
    public var match: Match

    /// The seating at save time: who sat where and how each seat was controlled (design.md §4 `seats`).
    public let seats: [SavedSeat]

    /// The ordered action log — the authoritative record restore replays (R-ENG-7.2; design.md §4
    /// `actionLog`). Recorded whole; the resume point is `cursor`.
    public var actionLog: [LogEntry]

    /// The last applied log index — the resume point (R-PERS-1.2; design.md §4 `cursor`). For a save
    /// written after every accepted action this is `actionLog.count - 1` (or `-1` when the log is empty),
    /// but it is stored explicitly so a restore replays exactly up to it.
    public var cursor: Int

    public init(
        gameID: String,
        options: Options,
        match: Match,
        seats: [SavedSeat],
        actionLog: [LogEntry],
        cursor: Int,
        createdAt: Date,
        updatedAt: Date,
        schemaVersion: Int = SaveDocument.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.gameID = gameID
        self.options = options
        self.match = match
        self.seats = seats
        self.actionLog = actionLog
        self.cursor = cursor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The log entries up to and including `cursor` — exactly what a restore replays (R-PERS-1.2).
    ///
    /// A save written after every accepted action has `cursor == actionLog.count - 1`, so this is the
    /// whole log; storing the cursor explicitly still lets a restore stop precisely at the resume point
    /// even if a log carries entries beyond it.
    public var entriesToReplay: [LogEntry] {
        guard cursor >= 0 else { return [] }
        let upper = min(cursor + 1, actionLog.count)
        return Array(actionLog[0..<upper])
    }

    // Decoding tolerates an absent `schemaVersion` (treated as version 1) so an older encoding decodes —
    // the seam task 6.2's migration registry builds on (R-PERS-2.1; design.md §4).
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, gameID, createdAt, updatedAt, options, match, seats, actionLog, cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.gameID = try c.decode(String.self, forKey: .gameID)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.options = try c.decode(Options.self, forKey: .options)
        self.match = try c.decode(Match.self, forKey: .match)
        self.seats = try c.decode([SavedSeat].self, forKey: .seats)
        self.actionLog = try c.decode([LogEntry].self, forKey: .actionLog)
        self.cursor = try c.decode(Int.self, forKey: .cursor)
    }
}
