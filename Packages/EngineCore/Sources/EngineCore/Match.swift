// Match structure and the action log — the authoritative record a session runs from (R-ENG-6, R-ENG-7).
//
// Two things live here, and they are the single source of truth the whole session derives from:
//
//   • The ACTION LOG (R-ENG-7). An ordered list of `LogEntry` values — each recording the seat, the
//     type-erased action, the resulting authoritative state hash, and non-authoritative metadata
//     (timestamps live ONLY in metadata, tech.md rule 8; R-ENG-7.1). Because it is ordered and each
//     entry carries the post-action state hash, the log alone powers save/restore, undo where permitted,
//     replays, and future network sync (R-ENG-7.2). `ActionLog` is a pure value type exposing the
//     primitives those features need: append, rewind (for undo), and read-a-tail (for replay/sync).
//
//   • The MATCH (R-ENG-6). A match is a sequence of hands, each hand a sequence of phases, each phase a
//     sequence of turns (R-ENG-6.1); `Phase`/turn sequencing already live on `GameDefinition`
//     (GameDefinition.swift), so `Match` models the layer above a single hand: the recorded per-hand
//     seeds (R-ENG-4.3), the current dealer, cumulative scores, the end condition, and a per-hand summary
//     history (R-ENG-6.2, R-ENG-6.3). It provides the operations R-ENG-6.2 needs — dealer rotation,
//     accumulating a finished hand's outcome, and the end-condition check.
//
// Undo policy (R-ENG-7.3, R-ENG-7.4). The `UndoPolicy` enum itself lives in Views.swift (the protocol
// references it). This file supplies the pure LOG-LEVEL undo mechanics keyed to that policy: for
// `unlimited` (Solitaire) rewind + redo; for `none` undo is disallowed; for `practiceMode` the pure
// computation of "how far to rewind to drop the trailing AI actions back to the last human action", plus
// the excluded-from-statistics flag (R-ENG-7.4). Actually re-deciding the AI is the host's job in Phase 4
// (design.md §2.9); EngineCore provides the primitives and a documented seam, not the AI loop.
//
// SEAT ORDERING. Dealer rotation and turn order need a seat *order*. Rather than duplicating it onto
// `Match` (where it could drift from the session's actual seat list), the rotation operations take the
// `[SeatID]` seat order as a parameter — the host owns the authoritative seat list and passes it in. This
// keeps `Match` focused on match-level bookkeeping and avoids a second, stale copy of the seating.

import Foundation

// MARK: - Log metadata (R-ENG-7.1; tech.md rule 8)

/// Non-authoritative metadata attached to a single `LogEntry` — the ONE place a timestamp may live
/// (tech.md rule 8; R-ENG-7.1).
///
/// Authoritative state must never contain wall-clock time, or the determinism hash would differ between
/// runs (StateHash.swift; ADR 0002 decision 4). So anything time-like or otherwise incidental to the
/// game's logic — when the action was recorded, an optional free-form note — is quarantined here, on the
/// log entry's metadata, and is deliberately NOT fed into `resultingStateHash`. Keeping this type
/// separate from the action and the hash is what makes "timestamps live only in metadata" enforceable by
/// construction rather than by convention.
public struct LogMetadata: Codable, Sendable, Hashable {
    /// The current schema version of this metadata payload; bumped on any format change (R-ENG-8.5).
    public static let currentSchemaVersion = 1

    /// The schema version this value was produced with (R-ENG-8.5).
    public let schemaVersion: Int

    /// When the entry was recorded, in whole seconds since the Unix epoch. Metadata ONLY — never hashed
    /// into authoritative state (tech.md rule 8). Optional so a replay/test can record an entry without a
    /// clock and still be deterministic.
    public let createdAtUnix: Int?

    /// An optional free-form note for tooling/debugging (e.g. "resumed", "hint-taken"). Non-authoritative.
    public let note: String?

    public init(
        createdAtUnix: Int? = nil,
        note: String? = nil,
        schemaVersion: Int = LogMetadata.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.createdAtUnix = createdAtUnix
        self.note = note
    }

    /// Empty metadata — the deterministic default used by replays and tests that record no clock.
    public static let none = LogMetadata()

    // Decoding tolerates an absent `schemaVersion` (treated as version 1) so older encodings decode
    // (R-ENG-8.5).
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, createdAtUnix, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.createdAtUnix = try c.decodeIfPresent(Int.self, forKey: .createdAtUnix)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

// MARK: - Log entry (R-ENG-7.1)

/// One authoritative record in the action log: which seat acted, what they did, the resulting state
/// hash, and non-authoritative metadata (R-ENG-7.1).
///
/// `index` is the entry's position in the ordered log (0-based). `action` is type-erased
/// (`AnyGameAction`) so the log can hold moves from any game without EngineCore knowing the concrete
/// type (R-ENG-5.6). `resultingStateHash` is the canonical hash of authoritative state *after* applying
/// the action, which is what the determinism/replay contract compares (R-ENG-4.4). `metadata` carries
/// timestamps and notes, kept out of the hash (tech.md rule 8). Everything is `Codable & Sendable` so an
/// entry round-trips in a save and crosses the host boundary (R-ENG-8.5).
public struct LogEntry: Codable, Sendable, Hashable {
    /// The entry's 0-based position in the ordered log (R-ENG-7.1).
    public let index: Int
    /// The seat that took the action.
    public let seat: SeatID
    /// The action taken, type-erased for the log (R-ENG-7.1, R-ENG-5.6).
    public let action: AnyGameAction
    /// The canonical hash of authoritative state *after* the action (R-ENG-7.1, R-ENG-4.4).
    public let resultingStateHash: StateHash
    /// Non-authoritative metadata (timestamps, notes) — never hashed (R-ENG-7.1; tech.md rule 8).
    public let metadata: LogMetadata

    public init(
        index: Int,
        seat: SeatID,
        action: AnyGameAction,
        resultingStateHash: StateHash,
        metadata: LogMetadata = .none
    ) {
        self.index = index
        self.seat = seat
        self.action = action
        self.resultingStateHash = resultingStateHash
        self.metadata = metadata
    }
}

// MARK: - Action log (R-ENG-7.1, R-ENG-7.2)

/// The ordered action log — the authoritative record save/restore, undo, replay, and future network sync
/// all derive from (R-ENG-7.1, R-ENG-7.2).
///
/// A pure value type wrapping `[LogEntry]` in strictly ascending `index` order (0, 1, 2, …). Mutation is
/// confined to a few primitives so the invariant "indices are contiguous and ordered" is easy to keep:
///
///   • `append(seat:action:resultingStateHash:metadata:)` records the next action, assigning the next
///     index automatically — the write path every accepted action takes (R-PERS-1.1).
///   • `rewind(to:)` truncates the log back to a prior length, dropping the tail — the undo primitive
///     (R-ENG-7.2). It returns the dropped entries so a caller (e.g. an `unlimited` redo stack) can retain
///     them.
///   • `entries(since:)` returns the tail from an index onward — the replay/sync read path (R-ENG-7.2):
///     a restorer replays them, a future network peer ships them.
///
/// Being a value type, copying the log snapshots it (useful for the host's save cursor); it carries no
/// reference identity or concurrency of its own — the `GameHost` actor owns the single authoritative
/// instance (R-SESS-1.1).
public struct ActionLog: Codable, Sendable, Hashable {
    /// The entries in ascending `index` order. Private so the contiguous-index invariant is preserved
    /// through the mutating primitives.
    private var storage: [LogEntry]

    /// Create a log, optionally seeded with existing entries (e.g. decoded from a save). Entries are
    /// assumed already contiguous and ordered from index 0.
    public init(entries: [LogEntry] = []) {
        self.storage = entries
    }

    /// The entries in order (read-only).
    public var entries: [LogEntry] { storage }

    /// The number of entries — also the index the next appended entry will receive (R-ENG-7.1).
    public var count: Int { storage.count }

    /// Whether the log is empty.
    public var isEmpty: Bool { storage.isEmpty }

    /// The most recent entry, or `nil` if the log is empty.
    public var last: LogEntry? { storage.last }

    /// Append the next action, assigning it the next sequential `index`, and return the created entry
    /// (R-ENG-7.1, R-PERS-1.1).
    ///
    /// The index is always `count` before the append, so indices stay contiguous (0, 1, 2, …) regardless
    /// of prior rewinds.
    @discardableResult
    public mutating func append(
        seat: SeatID,
        action: AnyGameAction,
        resultingStateHash: StateHash,
        metadata: LogMetadata = .none
    ) -> LogEntry {
        let entry = LogEntry(
            index: storage.count,
            seat: seat,
            action: action,
            resultingStateHash: resultingStateHash,
            metadata: metadata)
        storage.append(entry)
        return entry
    }

    /// Rewind the log to `length` entries, dropping and returning everything after — the undo primitive
    /// (R-ENG-7.2).
    ///
    /// `length` is clamped to `0...count`, so rewinding past the ends is a no-op / full clear rather than
    /// a crash. The dropped tail is returned (in order) so an `unlimited` redo stack can retain it to
    /// replay later; passing `count` returns an empty array and changes nothing.
    @discardableResult
    public mutating func rewind(to length: Int) -> [LogEntry] {
        let clamped = min(max(length, 0), storage.count)
        let dropped = Array(storage[clamped...])
        storage.removeLast(storage.count - clamped)
        return dropped
    }

    /// The entries from `index` onward (inclusive) — the replay/sync read path (R-ENG-7.2).
    ///
    /// `index` is clamped to `0...count`; `entries(since: 0)` is the whole log and `entries(since: count)`
    /// is empty. A restorer replays these against the recorded seeds; a future network peer ships them.
    public func entries(since index: Int) -> [LogEntry] {
        let clamped = min(max(index, 0), storage.count)
        return Array(storage[clamped...])
    }
}

// MARK: - End condition (R-ENG-6.2)

/// When a match ends (R-ENG-6.2).
///
/// A match is more than one hand, and games end matches differently: some race to a target cumulative
/// score (Crazy Eights to 100), some play a fixed number of hands, some are open-ended (a Solitaire
/// "match" is a single hand). Modeled as an enum with associated values so the check is total and the
/// save encoding matches design.md §4's `{ "kind": "targetScore", "value": 100 }` shape. `Codable`
/// uses an explicit `kind` discriminator + `value` so the JSON reads exactly as the design specifies
/// (R-ENG-8.5).
public enum EndCondition: Codable, Sendable, Hashable {
    /// The match ends when any seat's cumulative score reaches or exceeds `value` (R-ENG-6.2).
    case targetScore(value: Int)

    /// The match ends after exactly `value` completed hands.
    case handCount(value: Int)

    /// The match never ends on its own — e.g. a single-hand Solitaire "match" or an endless session.
    case openEnded

    // Encode as { "kind": "...", "value": N } to match the save schema (design.md §4).
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case targetScore, handCount, openEnded }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .targetScore:
            self = .targetScore(value: try c.decode(Int.self, forKey: .value))
        case .handCount:
            self = .handCount(value: try c.decode(Int.self, forKey: .value))
        case .openEnded:
            self = .openEnded
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .targetScore(let value):
            try c.encode(Kind.targetScore, forKey: .kind)
            try c.encode(value, forKey: .value)
        case .handCount(let value):
            try c.encode(Kind.handCount, forKey: .kind)
            try c.encode(value, forKey: .value)
        case .openEnded:
            try c.encode(Kind.openEnded, forKey: .kind)
        }
    }
}

// MARK: - Hand summary (R-ENG-6.3)

/// The per-hand summary a match records once a hand finishes (R-ENG-6.3).
///
/// It captures everything needed to review or reconstruct a completed hand without re-deriving it: the
/// hand's `index` (0-based), the seat that dealt it, the seed it was dealt from (R-ENG-4.3), the
/// `HandOutcome` (winners + per-hand scores, from Views.swift), and a *snapshot* of the cumulative
/// scores as they stood after this hand was applied. The cumulative snapshot means the scoreboard's
/// history is available per hand without replaying every prior outcome. `Codable & Sendable` so it rides
/// in the save's `handSummaries` array (design.md §4; R-ENG-8.5).
public struct HandSummary: Codable, Sendable, Hashable {
    /// The 0-based hand index within the match.
    public let handIndex: Int
    /// The seat that dealt this hand.
    public let dealer: SeatID
    /// The seed this hand was dealt from (R-ENG-4.3).
    public let seed: UInt64
    /// The hand's outcome — winners and per-hand score deltas (Views.swift).
    public let outcome: HandOutcome
    /// A snapshot of cumulative match scores immediately after this hand was applied (R-ENG-6.2).
    public let cumulativeScores: [SeatID: Int]

    public init(
        handIndex: Int,
        dealer: SeatID,
        seed: UInt64,
        outcome: HandOutcome,
        cumulativeScores: [SeatID: Int]
    ) {
        self.handIndex = handIndex
        self.dealer = dealer
        self.seed = seed
        self.outcome = outcome
        self.cumulativeScores = cumulativeScores
    }
}

// MARK: - Match (R-ENG-6)

/// A match: the layer above a single hand — recorded per-hand seeds, the current dealer, cumulative
/// scores, the end condition, and the per-hand summaries (R-ENG-6.1, R-ENG-6.2, R-ENG-6.3).
///
/// `Match` sits at the top of match → hands → phases → turns (R-ENG-6.1); phase/turn sequencing within a
/// hand belongs to `GameDefinition`, so this type owns only match-level bookkeeping. Its mutating
/// operations are the ones R-ENG-6.2/6.3 call for:
///
///   • `rotateDealer(order:)` — advance the dealer to the next seat in a supplied seat order, wrapping.
///   • `applyHand(outcome:seed:order:advanceDealer:)` — accumulate a finished hand's per-hand scores into
///     `cumulativeScores`, record the hand's `seed`, append a `HandSummary`, and (by default) rotate the
///     dealer for the next hand.
///   • `isMatchOver` — evaluate the `target` end condition against the current state.
///
/// Seat order is passed in (not stored) so it never drifts from the host's authoritative seat list (see
/// the file header). `Codable & Sendable` so the whole match snapshots into a save (design.md §4;
/// R-ENG-8.5).
public struct Match: Codable, Sendable, Hashable {
    /// One recorded seed per hand played, in order (R-ENG-4.3). `handSeeds.count` is the number of
    /// completed hands.
    public var handSeeds: [UInt64]
    /// The seat that deals the next hand; rotates between hands (R-ENG-6.2).
    public var dealer: SeatID
    /// Each seat's cumulative match score, accumulated across hands (R-ENG-6.2).
    public var cumulativeScores: [SeatID: Int]
    /// The condition that ends the match (R-ENG-6.2).
    public var target: EndCondition
    /// The per-hand summaries, one per completed hand, in order (R-ENG-6.3).
    public var handSummaries: [HandSummary]

    public init(
        dealer: SeatID,
        target: EndCondition,
        cumulativeScores: [SeatID: Int] = [:],
        handSeeds: [UInt64] = [],
        handSummaries: [HandSummary] = []
    ) {
        self.dealer = dealer
        self.target = target
        self.cumulativeScores = cumulativeScores
        self.handSeeds = handSeeds
        self.handSummaries = handSummaries
    }

    /// The number of completed hands — one seed and one summary are recorded per hand (R-ENG-6.3).
    public var completedHandCount: Int { handSummaries.count }

    /// Advance `dealer` to the next seat in `order`, wrapping past the end (R-ENG-6.2).
    ///
    /// If the current dealer is not found in `order` (e.g. a mismatched seat list), the dealer resets to
    /// the first seat, which keeps rotation total rather than silently stalling. A no-op if `order` is
    /// empty.
    public mutating func rotateDealer(order: [SeatID]) {
        guard !order.isEmpty else { return }
        if let current = order.firstIndex(of: dealer) {
            dealer = order[(current + 1) % order.count]
        } else {
            dealer = order[0]
        }
    }

    /// Apply a completed hand's outcome to the match (R-ENG-6.2, R-ENG-6.3).
    ///
    /// Accumulates each seat's per-hand `outcome.scores` into `cumulativeScores`, records the hand's
    /// `seed` (R-ENG-4.3), appends a `HandSummary` capturing the dealer, seed, outcome, and the resulting
    /// cumulative snapshot (R-ENG-6.3), and — unless `advanceDealer` is `false` — rotates the dealer for
    /// the next hand using `order`. The summary's `dealer` is the seat that dealt *this* hand (recorded
    /// before rotation), and its `handIndex` is this hand's position.
    public mutating func applyHand(
        outcome: HandOutcome,
        seed: UInt64,
        order: [SeatID],
        advanceDealer: Bool = true
    ) {
        let handIndex = handSummaries.count
        let dealerForHand = dealer

        for (seat, delta) in outcome.scores {
            cumulativeScores[seat, default: 0] += delta
        }

        handSeeds.append(seed)
        handSummaries.append(
            HandSummary(
                handIndex: handIndex,
                dealer: dealerForHand,
                seed: seed,
                outcome: outcome,
                cumulativeScores: cumulativeScores))

        if advanceDealer {
            rotateDealer(order: order)
        }
    }

    /// Whether the match has ended under its `target` end condition (R-ENG-6.2).
    ///
    ///   • `.targetScore(v)` — over once any seat's cumulative score is `>= v`.
    ///   • `.handCount(n)` — over once `n` hands have completed.
    ///   • `.openEnded` — never over on its own.
    public var isMatchOver: Bool {
        switch target {
        case .targetScore(let value):
            return cumulativeScores.values.contains { $0 >= value }
        case .handCount(let value):
            return completedHandCount >= value
        case .openEnded:
            return false
        }
    }

    /// The seat(s) leading the match by cumulative score, or empty when there are no scores yet.
    ///
    /// A convenience for scoreboards and end-of-match presentation; ties return every leading seat.
    public var leaders: [SeatID] {
        guard let best = cumulativeScores.values.max() else { return [] }
        return cumulativeScores.filter { $0.value == best }.map(\.key).sorted { $0.raw < $1.raw }
    }
}

// MARK: - Undo (R-ENG-7.3, R-ENG-7.4)

/// The pure, log-level undo machinery keyed to a game's `UndoPolicy` (R-ENG-7.3, R-ENG-7.4).
///
/// `UndoPolicy` (Views.swift) says *how far* a game permits undo; this engine turns that into concrete
/// operations over an `ActionLog`, while leaving the parts that need the running game (re-applying
/// actions to rebuild state, re-deciding the AI) to the host in Phase 4 (design.md §2.9). Everything here
/// is pure computation on the log so it is fully testable without a `GameHost`:
///
///   • `.unlimited` (Solitaire) — `undo` rewinds one entry and hands it back so the caller can push it
///     onto a redo stack; `redo` re-appends a previously undone entry. The engine keeps the redo *stack*;
///     the host re-applies the action to rebuild state on redo.
///   • `.none` (multi-seat default) — `undo`/`redo` are disallowed and return `nil`.
///   • `.practiceMode` — `rewindIndexForLastHumanUndo(...)` computes how far to rewind so the trailing AI
///     actions after the last human action are dropped, so the host can re-decide the AI from there
///     (R-ENG-7.4). `isExcludedFromStatistics` surfaces that a practice-mode game must not count in stats
///     (R-ENG-7.4, honored by task 6.3).
///
/// The engine is a `struct` holding the `ActionLog` plus the redo stack, so a session's undo state is a
/// value the host owns and saves; it carries no concurrency of its own.
public struct UndoEngine: Sendable {
    /// The policy governing what undo/redo are permitted to do (R-ENG-7.3).
    public let policy: UndoPolicy

    /// The authoritative action log this engine operates on.
    public private(set) var log: ActionLog

    /// Entries that have been undone and may be redone, most-recently-undone last. Retained only while
    /// `.unlimited` and cleared whenever a new action diverges the timeline (see `recordDivergingAppend`).
    public private(set) var redoStack: [LogEntry]

    public init(policy: UndoPolicy, log: ActionLog = ActionLog(), redoStack: [LogEntry] = []) {
        self.policy = policy
        self.log = log
        self.redoStack = redoStack
    }

    /// Whether this game is excluded from statistics — true exactly for Practice Mode (R-ENG-7.4).
    ///
    /// Surfaced so the statistics layer (task 6.3) can skip a practice-mode game without knowing the undo
    /// internals.
    public var isExcludedFromStatistics: Bool {
        policy == .practiceMode
    }

    /// Whether an undo is currently permitted and possible.
    ///
    /// `.none` never permits undo (R-ENG-7.3). `.unlimited` and `.practiceMode` permit it whenever the
    /// log is non-empty.
    public var canUndo: Bool {
        switch policy {
        case .none:
            return false
        case .unlimited, .practiceMode:
            return !log.isEmpty
        }
    }

    /// Whether a redo is currently possible (only meaningful for `.unlimited`).
    public var canRedo: Bool {
        policy == .unlimited && !redoStack.isEmpty
    }

    /// Record that a fresh action was appended to the log, diverging the timeline and invalidating any
    /// pending redo (R-ENG-7.2).
    ///
    /// The host calls this after appending a newly *decided* action (as opposed to a redo). Once the
    /// player acts anew, the previously undone future can no longer be redone, so the redo stack is
    /// cleared — the standard undo/redo semantics.
    public mutating func recordDivergingAppend() {
        redoStack.removeAll(keepingCapacity: false)
    }

    /// Undo the last action for an `.unlimited` game, returning the removed entry (or `nil` if undo is
    /// not permitted / nothing to undo) (R-ENG-7.3).
    ///
    /// The removed entry is also pushed onto the redo stack so it can be redone. The host, on getting the
    /// entry back, rebuilds state by replaying the log from the recorded seed(s) up to the new length
    /// (the log/seed replay is the host's job, design.md §2.9). Only valid for `.unlimited`; multi-seat
    /// Practice Mode uses `rewindIndexForLastHumanUndo(...)` instead.
    @discardableResult
    public mutating func undo() -> LogEntry? {
        guard policy == .unlimited, !log.isEmpty else { return nil }
        let dropped = log.rewind(to: log.count - 1)
        guard let entry = dropped.first else { return nil }
        redoStack.append(entry)
        return entry
    }

    /// Redo the most recently undone action for an `.unlimited` game, re-appending it and returning it
    /// (or `nil` if there is nothing to redo) (R-ENG-7.3).
    ///
    /// The re-appended entry keeps its recorded action, hash, and metadata and is placed at the current
    /// end of the log (its `index` is reassigned to the current length so indices stay contiguous). The
    /// host re-applies the action to rebuild state.
    @discardableResult
    public mutating func redo() -> LogEntry? {
        guard policy == .unlimited, let entry = redoStack.popLast() else { return nil }
        return log.append(
            seat: entry.seat,
            action: entry.action,
            resultingStateHash: entry.resultingStateHash,
            metadata: entry.metadata)
    }

    /// For Practice Mode: the log length to rewind to so that undoing the last human action also drops
    /// every AI action taken after it (R-ENG-7.4).
    ///
    /// `isAI` classifies a seat as AI-controlled (the host builds it from its seat→controller bindings).
    /// The computation walks the log from the end, skipping trailing AI entries, and returns the index of
    /// the last *human* entry — i.e. the length the log should be rewound to so that both that human
    /// action and the AI actions after it are removed, letting the host re-decide the AI from a clean
    /// point. Returns `nil` when undo is not permitted here (policy is not `.practiceMode`) or there is no
    /// human action to undo (empty log or only AI entries).
    ///
    /// EngineCore stops at computing the rewind target; the host performs the rewind, rebuilds state by
    /// replay, and re-runs the AI controllers from there (the re-decide loop is design.md §2.9, Phase 4).
    public func rewindIndexForLastHumanUndo(isAI: (SeatID) -> Bool) -> Int? {
        guard policy == .practiceMode else { return nil }
        var i = log.entries.count - 1
        // Skip the trailing AI actions.
        while i >= 0, isAI(log.entries[i].seat) {
            i -= 1
        }
        // `i` now indexes the last human action, or is -1 if there is none.
        guard i >= 0 else { return nil }
        return i
    }
}
