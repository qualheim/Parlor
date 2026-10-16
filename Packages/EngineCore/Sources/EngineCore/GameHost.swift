// The GameHost actor — the single authority that owns and mutates game state (R-SESS-1).
//
// tech.md rule 2 and R-SESS-1.1 demand ONE mutator of authoritative state. `GameHost` is that actor: it
// owns the game's `State`, the per-hand `SeededRNG`, and the `ActionLog`, and nothing else may touch them.
// Clients (the UI, an AI, a future remote seat) never see `State`; they submit actions and receive
// redacted `PlayerView`s and `GameEvent`s across the Codable boundary (R-SESS-1.2, R-SESS-4). Making
// `State` a `private` field of the actor is what enforces "sole mutator" by construction rather than by
// convention — there is no accessor that vends it.
//
// The host is generic over `Game: GameDefinition`, so a single implementation runs any game with NO
// EngineCore edits per game (R-ENG-5.6). Knowing the concrete `Game.Action` is exactly what lets the host
// decode the type-erased `AnyGameAction` that crosses the boundary (design.md §2.9) — the one place the
// erased action is turned back into a concrete move.
//
// SCOPE (task 4.1). This host implements the submit → accepted/rejected + view/events loop for a single
// hand: `receive(_:)` (the transport entry point), `submit(_:)`, and `view(for:)`. The async
// `PlayerController` seam, the sequential/simultaneous/out-of-turn turn models, dealer rotation across
// hands, and the undo/redo re-decide loop are task 4.2+ (R-SESS-2, R-SESS-3, R-ENG-7); the `ActionLog`,
// `UndoEngine`, and `Match` primitives they build on already exist (Match.swift). The host records one
// `LogEntry` per accepted action with the resulting state hash so the determinism/replay contract holds
// from here on (R-ENG-4.4, R-ENG-7.1).

import Foundation

/// The authoritative game host: an `actor` that solely owns and mutates the game's state, RNG, and action
/// log, exposing only redacted views and events across a Codable boundary (R-SESS-1).
///
/// Construct one with a `GameDefinition`, its `Options`, the seat order, and a hand `seed`; the host builds
/// the initial state deterministically from `(options, seed)` (R-ENG-5.3, R-ENG-4.3). Clients then talk to
/// it only through `receive(_:)` (usually via a `Transport`) — submitting actions and requesting views.
/// Because it is an `actor`, all state access is serialized, so two sessions (two windows, or `parlor-sim`)
/// each hold an independent host with no shared/static state (R-SESS-6).
public actor GameHost<Game: GameDefinition> {
    /// The pure rules definition. Immutable; the host calls it but never lets it hold state.
    private let game: Game

    /// The immutable options used to rebuild the private state after undo/redo. Options remain host-owned
    /// construction context and never cross the client boundary (R-SESS-1.1).
    private let options: Game.Options

    /// The authoritative game state. PRIVATE and never vended — the host is its only mutator (R-SESS-1.1,
    /// R-SESS-1.2). Clients observe it only through redacted `PlayerView`s.
    private var state: Game.State

    /// The per-hand deterministic RNG, seeded from the recorded `seed` (R-ENG-4.3). Owned here so all
    /// randomness flows through the single authority (R-SESS-1.1). Held for shuffles a game transition may
    /// need in later tasks; `state` is built from the seed at init.
    private var rng: SeededRNG

    /// The seed this hand was dealt from — recorded so the hand can be replayed/verified (R-ENG-4.3).
    private let seed: UInt64

    /// The ordered action log: one `LogEntry` per accepted action, each carrying the resulting state hash
    /// (R-ENG-7.1, R-ENG-4.4). Owned solely by the host (R-SESS-1.1).
    /// The ordered action log: one `LogEntry` per accepted action, each carrying the resulting state hash
    /// (R-ENG-7.1, R-ENG-4.4). Owned solely by the host (R-SESS-1.1).
    private var log: ActionLog

    /// Host-owned undo/redo bookkeeping. The engine stores log entries only; state is rebuilt from the
    /// recorded seed and remaining log after each operation, so the host remains the sole state mutator.
    private var undoEngine: UndoEngine

    /// The seat order at the table. The host owns the authoritative seat list (Match.swift header); used to
    /// address per-seat views on an accepted action.
    private let seats: [SeatID]

    /// Start a host for `game` with `options`, the given `seats`, and a hand `seed` (R-SESS-1.1,
    /// R-ENG-5.3).
    ///
    /// Builds the initial state deterministically from `(options, seed)` and seeds the RNG from the same
    /// `seed`, so the starting position is reproducible (R-ENG-4.4). The action log starts empty.
    public init(game: Game, options: Game.Options, seats: [SeatID], seed: UInt64) {
        self.game = game
        self.options = options
        self.seed = seed
        self.rng = SeededRNG(seed: seed)
        self.state = game.initialState(options: options, seed: seed)
        self.seats = seats
        self.log = ActionLog()
        self.undoEngine = UndoEngine(policy: game.undoPolicy)
    }

    // MARK: - Restore by replay (R-PERS-1.2, R-ENG-7.2, R-QA-4.1)

    /// A typed failure from `GameHost.restoring(...)` — a save's recorded log could not be replayed
    /// faithfully (R-PERS-1.2). Reported (never thrown as a trap) so the loader can surface a notice and
    /// discard the save rather than crash (R-PERS-2.2, handled fully in task 6.2).
    public enum RestoreError: Error, Sendable, Equatable {
        /// A recorded action at `index` could not be decoded for this game's `Action` type.
        case undecodableAction(index: Int)
        /// Replaying the recorded action at `index` was rejected by the rules — the log does not
        /// describe a legal run of this game/options/seed.
        case rejectedAction(index: Int, code: String)
        /// Hashing the state after replaying the action at `index` failed.
        case hashFailed(index: Int)
        /// The state hash after replaying the action at `index` did not match the hash recorded in the
        /// save — the save is inconsistent with this game/options/seed (corruption or a version mismatch).
        case hashMismatch(index: Int)
    }

    /// Rebuild a host by replaying a recorded action log against the same `game`, `options`, `seats`, and
    /// `seed` — the resume path a save restores through (R-PERS-1.2, R-ENG-7.2).
    ///
    /// This is exactly the design's restore contract: "restore replays the log against the recorded seeds,
    /// so restore + continue equals an uninterrupted run" (design.md §4; R-QA-4.1). Starting from the same
    /// deterministic initial state, each recorded `LogEntry` is decoded to a concrete `Game.Action` and fed
    /// through the pure `game.apply(_:by:to:)` in order; the resulting state hash is recomputed and checked
    /// against the hash the save recorded, so a corrupted or incompatible log is caught rather than
    /// silently producing a wrong position. On success the host holds the same private state, the same
    /// rebuilt log, and can accept new actions as if it had never stopped (mid-hand vs AI included,
    /// R-PERS-1.2).
    ///
    /// Returns a failure (never traps) so the persistence loader can present a notice and discard the save
    /// (R-PERS-2.2). `entries` must be the ordered log from index 0 (the save records the whole log; the
    /// resume `cursor` equals its last index).
    public static func restoring(
        game: Game,
        options: Game.Options,
        seats: [SeatID],
        seed: UInt64,
        replaying entries: [LogEntry]
    ) -> Result<GameHost<Game>, RestoreError> {
        do {
            let host = try GameHost(
                game: game, options: options, seats: seats, seed: seed, replaying: entries)
            return .success(host)
        } catch let error as RestoreError {
            return .failure(error)
        } catch {
            // `restoring` only ever throws `RestoreError`; this arm keeps the compiler happy.
            return .failure(.hashFailed(index: 0))
        }
    }

    /// Designated restoring initializer: build the initial state, then replay `entries` in order,
    /// throwing a `RestoreError` on the first inconsistency (R-PERS-1.2, R-QA-4.1).
    ///
    /// Runs in the initializer (nonisolated), so it may set the actor's stored `state`/`log` directly
    /// while the instance is still being formed. Callers use `restoring(...)` for the non-throwing
    /// `Result` surface the persistence loader wants.
    private init(
        game: Game,
        options: Game.Options,
        seats: [SeatID],
        seed: UInt64,
        replaying entries: [LogEntry]
    ) throws {
        self.game = game
        self.options = options
        self.seed = seed
        self.rng = SeededRNG(seed: seed)
        self.state = game.initialState(options: options, seed: seed)
        self.seats = seats
        self.log = ActionLog()
        self.undoEngine = UndoEngine(policy: game.undoPolicy)

        for (offset, entry) in entries.enumerated() {
            let action: Game.Action
            do {
                action = try entry.action.decode(as: Game.Action.self)
            } catch {
                throw RestoreError.undecodableAction(index: offset)
            }

            switch game.apply(action, by: entry.seat, to: state) {
            case .success(let (newState, _)):
                let hash: StateHash
                do {
                    hash = try StateHash.canonical(newState)
                } catch {
                    throw RestoreError.hashFailed(index: offset)
                }
                // The replayed hash must match the recorded one, or the save does not describe this
                // game/options/seed faithfully (R-QA-4.1).
                guard hash == entry.resultingStateHash else {
                    throw RestoreError.hashMismatch(index: offset)
                }
                state = newState
                let recorded = log.append(
                    seat: entry.seat,
                    action: entry.action,
                    resultingStateHash: hash,
                    metadata: entry.metadata)
                undoEngine.recordAccepted(recorded)
            case .failure(let violation):
                throw RestoreError.rejectedAction(index: offset, code: violation.code)
            }
        }
    }

    // MARK: - Transport entry point (R-SESS-4)

    /// Handle one `ClientMessage` and produce the `HostMessage` reply — the single boundary a client (via a
    /// `Transport`) uses (R-SESS-4.1).
    ///
    /// `submit` runs validation + application and returns the `ResultEnvelope`; `requestView` returns the
    /// current redacted view. The host never returns raw `State` here — only redacted, event-carrying
    /// messages (R-SESS-1.2).
    public func receive(_ message: ClientMessage) -> HostMessage {
        switch message {
        case .submit(let envelope):
            return .result(submit(envelope))
        case .requestView(let viewer):
            return .viewUpdate(view(for: viewer))
        }
    }

    // MARK: - Submit (R-SESS-1, R-SESS-4.1)

    /// Validate and (if legal) apply the action in `envelope`, returning the accepted or rejected result
    /// (R-SESS-4.1).
    ///
    /// The type-erased action is decoded to the concrete `Game.Action` (the host knows the type — the one
    /// place erasure is undone, design.md §2.9), then passed to the pure `game.apply(_:by:to:)`. On success
    /// the host commits the new state, appends a `LogEntry` with the resulting canonical state hash
    /// (R-ENG-7.1, R-ENG-4.4), and returns `.accepted` with the produced events plus a redacted
    /// `PlayerView` for every seat and the spectator (R-ENG-8.2). On a `RuleViolation` the host returns
    /// `.rejected` and does NOT mutate state (R-SESS-1.2). A malformed/undecodable action is reported as a
    /// rejection rather than crashing the host.
    public func submit(_ envelope: ActionEnvelope) -> ResultEnvelope {
        let action: Game.Action
        do {
            action = try envelope.action.decode(as: Game.Action.self)
        } catch {
            return .rejected(
                RuleViolation(
                    code: "undecodable-action",
                    reason: "The submitted action could not be decoded for this game."))
        }

        switch game.apply(action, by: envelope.seat, to: state) {
        case .success(let (newState, events)):
            // Hash the resulting state BEFORE committing anything, so a (should-never-happen) hashing
            // failure rejects cleanly with state and log untouched (R-SESS-1.2). Encoding a `Codable`
            // state should never fail; hashing first is what keeps the failure path non-mutating.
            let hash: StateHash
            do {
                hash = try StateHash.canonical(newState)
            } catch {
                return .rejected(
                    RuleViolation(
                        code: "state-hash-failed",
                        reason: "The resulting state could not be hashed."))
            }
            // Commit the new state (the only place state is mutated) and log the transition with the
            // resulting canonical hash so replay/determinism holds (R-SESS-1.1, R-ENG-4.4, R-ENG-7.1).
            state = newState
            let recorded = log.append(
                seat: envelope.seat, action: envelope.action, resultingStateHash: hash)
            undoEngine.recordAccepted(recorded)
            return .accepted(events: events, views: viewsForAllViewers())

        case .failure(let violation):
            // Rejected: state is untouched (R-SESS-1.2).
            return .rejected(violation)
        }
    }

    /// Redo the most recently undone action for an unlimited-undo game. The action is re-applied through
    /// the pure rules transition before the host commits it, so redo follows the same sole-mutator path as
    /// a fresh submission (R-ENG-7.2).
    @discardableResult
    public func redo() -> Bool {
        guard undoEngine.redo() != nil else { return false }
        log = undoEngine.log
        guard rebuildState(from: log) else {
            _ = undoEngine.undo()
            log = undoEngine.log
            _ = rebuildState(from: log)
            return false
        }
        return true
    }

    /// Undo the most recent accepted action for an unlimited-undo game. The host truncates its log and
    /// rebuilds private state from the original seed; callers observe the result only through a fresh view.
    /// Multi-seat games retain their declared `.none` policy and therefore return `false` (R-ENG-7.3).
    @discardableResult
    public func undo() -> Bool {
        guard undoEngine.undo() != nil else { return false }
        log = undoEngine.log
        guard rebuildState(from: log) else {
            _ = undoEngine.redo()
            log = undoEngine.log
            _ = rebuildState(from: log)
            return false
        }
        return true
    }

    /// Reconstruct the private state from the immutable deal context and an accepted log prefix. This is
    /// deliberately host-internal: the UI receives only redacted views after the rebuild.
    private func rebuildState(from log: ActionLog) -> Bool {
        var rebuilt = game.initialState(options: options, seed: seed)
        for entry in log.entries {
            guard let action = try? entry.action.decode(as: Game.Action.self),
                case .success(let (next, _)) = game.apply(action, by: entry.seat, to: rebuilt),
                let hash = try? StateHash.canonical(next), hash == entry.resultingStateHash
            else { return false }
            rebuilt = next
        }
        state = rebuilt
        return true
    }

    // MARK: - Views (R-SESS-1.2, R-ENG-8.2)

    /// The current redacted view for `viewer` (R-ENG-8.2).
    ///
    /// Delegates to the game's `redactedView(of:for:)`, which reveals only what the viewer may see and
    /// tokenizes hidden pieces (R-ENG-8.3). This is the only way a client observes state — there is no
    /// accessor for raw `State` (R-SESS-1.2).
    public func view(for viewer: Viewer) -> PlayerView {
        game.redactedView(of: state, for: viewer)
    }

    /// The number of entries in the action log — observable so tests/tools can confirm the log grew on an
    /// accepted action and did not on a rejection, without touching `State` (R-ENG-7.1).
    public var logCount: Int { log.count }

    /// The resulting state hash recorded by the most recent accepted action, or `nil` if none yet — the
    /// value the determinism/replay contract compares (R-ENG-4.4).
    public var lastStateHash: StateHash? { log.last?.resultingStateHash }

    /// A snapshot of the ordered action log — the authoritative record a save serializes and a restore
    /// replays (R-ENG-7.2, R-PERS-1.1). `ActionLog` is a value type, so this is a copy; the host remains
    /// the sole owner of its live log (R-SESS-1.1). The autosave layer reads this after every accepted
    /// action to write the versioned save (R-PERS-1.1).
    public var actionLog: ActionLog { log }

    /// The seed this hand was dealt from (R-ENG-4.3) — recorded in the save so restore can rebuild the
    /// same initial state before replaying the log (R-PERS-1.2).
    public var handSeed: UInt64 { seed }

    // MARK: - Private helpers

    /// Build a redacted view for every seat plus the spectator — the viewers an accepted transition is
    /// addressed to (R-ENG-8.2).
    ///
    /// Each seat sees its own view (its private zones + public state + its own legal actions); the spectator
    /// view carries only public information. `debugOmniscient` is never included — it must not appear on a
    /// shipping redaction path (design.md §2.8).
    private func viewsForAllViewers() -> [PlayerView] {
        var views = seats.map { game.redactedView(of: state, for: .seat($0)) }
        views.append(game.redactedView(of: state, for: .spectator))
        return views
    }
}
