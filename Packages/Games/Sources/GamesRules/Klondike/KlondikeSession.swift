// Klondike session — the per-play *presentation* state that must stay OUT of the hashed authoritative
// state (R-KLON-3.6, R-KLON-3.7, R-KLON-3.8; tech.md: timestamps/clock live outside the determinism hash).
//
// `KlondikeState` is `Hashable` and its hash is the determinism/save-replay contract (R-ENG-4.4): two
// runs that reach the same board must hash identically. A move counter and a wall-clock timer would
// break that (they are wall-clock/UI concerns and would differ between an original play and a replay), so
// they must NOT be fields of `KlondikeState`. This file models them separately, in a small value type the
// host/UI owns alongside the authoritative state:
//
//   • `KlondikeBannerState` — the inline no-moves banner (R-KLON-3.6): `.playing` or `.noMoves` offering
//     undo / restart / new game. NO modal — the banner is just state a thin view renders.
//   • `KlondikeSession` — move count (R-KLON-3.8), the elapsed-time timer model (R-KLON-3.8), the current
//     deal number (R-KLON-3.7, for "restart same deal" / "deal #N"), and the banner state. It advances by
//     explicit calls the host makes on accepted player moves and clock ticks; it never touches the board.
//
// Everything here is pure and `Sendable`; the timer is modeled as an accumulated interval + an optional
// running-since mark, so the UI can tick a derived `elapsed(at:)` without this type reaching for a clock.

import EngineCore
import Foundation

// MARK: - No-moves banner (R-KLON-3.6)

/// The inline banner state shown at the bottom of the table — never a modal dialog (R-KLON-3.6).
///
/// The board is either in normal `playing` state, or dead (`noMoves`) in which case the banner offers the
/// three recovery actions. Which of those are *available* is also modeled so the view can enable/disable
/// them (e.g. undo is only offered when there is history to undo).
public enum KlondikeBannerState: Sendable, Hashable {
    /// Normal play — no banner is shown.
    case playing
    /// No legal move remains; the banner offers the given recovery options (R-KLON-3.6).
    case noMoves(offering: KlondikeNoMovesOptions)
}

/// Which recovery actions the no-moves banner offers (R-KLON-3.6). Undo is only meaningful when the match
/// has undo history; restart and new game are always available.
public struct KlondikeNoMovesOptions: Sendable, Hashable {
    /// Offer "Undo" — take back the last move (available only when there is history).
    public var canUndo: Bool
    /// Offer "Restart this deal" — replay the same deal number/seed (R-KLON-3.7). Always available.
    public var canRestart: Bool
    /// Offer "New game" — deal a fresh game. Always available.
    public var canNewGame: Bool

    public init(canUndo: Bool, canRestart: Bool = true, canNewGame: Bool = true) {
        self.canUndo = canUndo
        self.canRestart = canRestart
        self.canNewGame = canNewGame
    }
}

// MARK: - Session (R-KLON-3.7, R-KLON-3.8)

/// The per-play presentation state that rides *alongside* the authoritative `KlondikeState` but is
/// deliberately kept out of its determinism hash (R-KLON-3.8; tech.md clock/UI rule).
///
/// The host creates one per game (seeding `dealNumber` from "deal #N" or a fresh number), advances
/// `moveCount` on each accepted player move, ticks the timer from a display clock, and sets `banner` from
/// `Klondike.hasNoMoves`. None of this feeds back into the board, so save/replay determinism is intact.
public struct KlondikeSession: Sendable, Hashable {
    /// The number of player-initiated moves accepted so far (R-KLON-3.8). Auto-moves the host performs may
    /// be counted or not at the host's discretion; `recordPlayerMove()` is the single increment point for
    /// player-initiated moves.
    public private(set) var moveCount: Int

    /// The deal number this game was dealt from (R-KLON-3.7), so "restart this deal" can re-deal the same
    /// seed via `Klondike.initialState(options:dealNumber:)`.
    public let dealNumber: Int

    /// The current inline banner state (R-KLON-3.6).
    public var banner: KlondikeBannerState

    /// Elapsed time already accumulated while the timer was previously running, in seconds (R-KLON-3.8).
    public private(set) var accumulated: TimeInterval

    /// The display-clock instant the timer was (re)started at, or `nil` when paused/stopped. Stored as a
    /// bare `TimeInterval` mark supplied by the host's display clock — this type never reads a clock
    /// itself, keeping it pure and out of the authoritative state.
    public private(set) var runningSince: TimeInterval?

    public init(
        dealNumber: Int,
        moveCount: Int = 0,
        banner: KlondikeBannerState = .playing,
        accumulated: TimeInterval = 0,
        runningSince: TimeInterval? = nil
    ) {
        self.dealNumber = dealNumber
        self.moveCount = moveCount
        self.banner = banner
        self.accumulated = accumulated
        self.runningSince = runningSince
    }

    // MARK: Move counter (R-KLON-3.8)

    /// Record one accepted player-initiated move, incrementing the counter (R-KLON-3.8).
    public mutating func recordPlayerMove() {
        moveCount += 1
    }

    // MARK: Timer (R-KLON-3.8)

    /// Start (or resume) the timer at display-clock instant `now` (R-KLON-3.8). No-op if already running.
    public mutating func startTimer(now: TimeInterval) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    /// Pause the timer at display-clock instant `now`, folding the running span into `accumulated`
    /// (R-KLON-3.8). No-op if already paused.
    public mutating func pauseTimer(now: TimeInterval) {
        guard let since = runningSince else { return }
        accumulated += max(0, now - since)
        runningSince = nil
    }

    /// The elapsed time to display at display-clock instant `now` (R-KLON-3.8): accumulated time plus the
    /// current running span, if any. The UI ticks this on a timer to update the HUD.
    public func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let since = runningSince else { return accumulated }
        return accumulated + max(0, now - since)
    }
}
