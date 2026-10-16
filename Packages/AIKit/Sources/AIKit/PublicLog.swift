// PublicLog — the redacted, public-information history an AI strategy may read (R-AI-1.1, R-AI-2.2).
//
// A `PlayerView` (EngineCore/Views.swift) is a *snapshot* — the redacted zones/scores/phase as they
// stand right now. But a strategy that wants to infer, say, that an opponent is void in a suit (because
// they failed to follow suit earlier) needs the *history* of what happened, not just the current frame.
// The `PublicLog` is that history, restricted to strictly public information.
//
// WHAT IT CONTAINS. Two public projections of what has happened, both free of any hidden identity:
//
//   • `events` — the ordered public `GameEvent`s (EngineCore/Views.swift) that were visible to everyone.
//     These are already safe by construction: hidden pieces appear only as `ViewToken`s (R-ENG-8.3), and
//     `pieceRevealed` binds a token to an identity only when it legitimately became public (R-ENG-8.4).
//     A strategy reads these to reconstruct the public course of play (turns, tricks, named suits, …).
//
//   • `actions` — the public projection of the action log: each entry is a `(seat, action)` pair drawn
//     from `LogEntry` (EngineCore/Match.swift), carrying ONLY the publicly-known action. It never carries
//     the resulting state hash, timestamps, or any hidden identity — just "seat X did publicly-visible
//     move Y". A strategy reads these to model opponents' *behavior* over time.
//
// WHAT IT MUST NOT CONTAIN. No authoritative `State`, no un-redacted hand contents, no hidden `PieceID`
// behind a token — those never enter this type. Together with `DecisionContext` (Strategy.swift), which
// hands a strategy *only* a view, this log, and the legal actions, the information barrier (R-AI-1.1) is
// enforced by the types: there is no member on either type through which authoritative state is reachable.
//
// This lives in AIKit (not EngineCore) because it is an AI-facing convenience assembled from the engine's
// already-public boundary values (`GameEvent`, `LogEntry`); it introduces no new engine concept, only a
// public-only *view* of the ones the engine already emits.

import Foundation
import EngineCore

// MARK: - Public action entry (R-AI-1.1)

/// One entry in the public projection of the action log: the seat that acted and the publicly-known
/// action, and nothing else (R-AI-1.1).
///
/// Derived from an EngineCore `LogEntry` by dropping everything that is not public — the resulting state
/// hash and the metadata (timestamps/notes) never cross into the AI boundary. The `action` is the same
/// type-erased `AnyGameAction` the log records; because it is the *publicly-known* action (the move a
/// seat made in the open), it carries no hidden identity. A strategy uses the ordered stream of these to
/// infer opponent tendencies (e.g. inferred suit voids — see `DeterminizationConstraints`).
public struct PublicActionEntry: Sendable, Hashable, Codable {
    /// The seat that took the action.
    public let seat: SeatID

    /// The publicly-known action the seat took, type-erased as in the action log (R-ENG-7.1).
    public let action: AnyGameAction

    public init(seat: SeatID, action: AnyGameAction) {
        self.seat = seat
        self.action = action
    }

    /// Project a `LogEntry` down to its public `(seat, action)` pair, discarding the resulting state hash
    /// and non-authoritative metadata (R-AI-1.1). This is the ONE place the private parts of a log entry
    /// are dropped on the way to a strategy.
    public init(_ entry: LogEntry) {
        self.seat = entry.seat
        self.action = entry.action
    }
}

// MARK: - PublicLog (R-AI-1.1, R-AI-2.2)

/// The public, redacted history a strategy may read: the ordered public events plus the public projection
/// of the action log (R-AI-1.1).
///
/// Strictly public by construction — it holds only `GameEvent`s (which tokenize hidden pieces, R-ENG-8.3)
/// and `PublicActionEntry` pairs (which carry only the publicly-known action). There is no path from a
/// `PublicLog` to authoritative `State`; combined with `DecisionContext`, this makes the AI information
/// barrier structural (R-AI-1.1). `Sendable` so it can be handed to a strategy running off the main actor
/// (R-AI-3.1); `Codable` so an AI-vs-AI harness can record and replay it.
public struct PublicLog: Sendable, Hashable, Codable {
    /// The ordered public events visible to everyone, oldest first (R-ENG-8.1).
    public let events: [GameEvent]

    /// The public projection of the action log, oldest first — `(seat, publicly-known action)` pairs
    /// (R-AI-1.1).
    public let actions: [PublicActionEntry]

    public init(events: [GameEvent] = [], actions: [PublicActionEntry] = []) {
        self.events = events
        self.actions = actions
    }

    /// Build a `PublicLog` from an EngineCore `ActionLog`, projecting each entry to its public pair
    /// (R-AI-1.1). Optionally include the public event stream alongside.
    ///
    /// The caller (the host/session) is responsible for only passing events that are public to every seat;
    /// the action projection is public by construction (it drops hash + metadata and carries the
    /// already-public action).
    public init(actionLog: ActionLog, events: [GameEvent] = []) {
        self.events = events
        self.actions = actionLog.entries.map(PublicActionEntry.init)
    }

    /// The empty log — a convenient neutral value for the start of a hand or for tests.
    public static let empty = PublicLog()

    /// The public actions taken by a specific seat, in order — a small convenience for opponent modeling.
    public func actions(by seat: SeatID) -> [PublicActionEntry] {
        actions.filter { $0.seat == seat }
    }
}
