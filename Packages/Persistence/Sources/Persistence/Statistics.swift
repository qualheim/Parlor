// Statistics value types — the pure, Foundation-only record of how a game/variant has been played
// (R-APP-4.1, R-ENG-7.4; design.md §4 "Statistics").
//
// These are plain values with no I/O and no UI: a `StatisticsKey` names one bucket (a game id + a
// variant key the caller derives from the options), a `GameStatistics` accumulates the counts/streaks/
// bests/metrics for that bucket, and a `GameResult` is the input a finished game produces. The store
// (StatisticsStore.swift) persists them; the series helpers (StatisticsSeries.swift) turn a history into
// chart-friendly points. Keeping the accumulation logic here — as a pure `recording(result:)` that
// returns an updated copy — means the counting/streak/best rules are unit- and property-testable without
// a file system or a running host.
//
// PRACTICE MODE. A `GameResult` carries `isExcludedFromStatistics`, which the caller sets from
// `EngineCore`'s `UndoEngine.isExcludedFromStatistics` (true for `UndoPolicy.practiceMode`). The recorder
// (StatisticsStore.swift) SKIPS such a result entirely, so a practice-mode game never counts (R-ENG-7.4).

import Foundation

// MARK: - Statistics key (game + variant)

/// Names one statistics bucket: a game id plus a `variantKey` the caller derives from the game options
/// (R-APP-4.1).
///
/// Statistics are tracked "per game AND variant" (R-APP-4.1): Klondike Draw-1 and Draw-3 keep separate
/// records, as do Crazy Eights at different targets. The `gameID` is the stable kebab-case id
/// (`GameMetadata.id`); the `variantKey` is an opaque, stable string the caller builds from the options
/// that define a variant (e.g. `"draw1-vegas"`). An empty `variantKey` means "the game's default / only
/// variant". The pair is the codable dictionary key the store uses, encoded as a single `"gameID#variant"`
/// string so it survives a JSON object round-trip (JSON object keys must be strings).
public struct StatisticsKey: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The stable, kebab-case game id this bucket belongs to (e.g. `"klondike"`).
    public let gameID: String
    /// A stable, opaque string identifying the variant within the game, derived by the caller from the
    /// options (e.g. `"draw1-vegas"`). Empty means the default variant.
    public let variantKey: String

    public init(gameID: String, variantKey: String = "") {
        self.gameID = gameID
        self.variantKey = variantKey
    }

    public var description: String {
        variantKey.isEmpty ? gameID : "\(gameID)#\(variantKey)"
    }

    // Encoded as a single "gameID#variantKey" string so the key can serve as a JSON object key in the
    // store's stats map (JSON forbids non-string object keys). `#` cannot appear in a kebab-case game id,
    // so the split is unambiguous on the first `#`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let hash = raw.firstIndex(of: "#") {
            self.gameID = String(raw[raw.startIndex..<hash])
            self.variantKey = String(raw[raw.index(after: hash)...])
        } else {
            self.gameID = raw
            self.variantKey = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Game result (input to the recorder)

/// The outcome a finished game reports to the statistics recorder (R-APP-4.1, R-ENG-7.4).
///
/// A pure input value: which bucket it belongs to (`key`), whether it was a win, the optional final
/// `score` and elapsed `time`, an extensible `metrics` bag for game-specific numbers, and the
/// `isExcludedFromStatistics` flag the caller copies from `UndoEngine.isExcludedFromStatistics`. The
/// recorder ignores an excluded result entirely (R-ENG-7.4), so Practice Mode never affects the record.
public struct GameResult: Sendable, Codable, Equatable {
    /// The bucket this result counts toward (game + variant).
    public let key: StatisticsKey
    /// Whether the game was won.
    public let won: Bool
    /// The final score, if the game scores; `nil` for unscored games. Higher is better (best = max).
    public let score: Int?
    /// The elapsed play time, if timed; `nil` otherwise. Lower is better (best = min).
    public let time: TimeInterval?
    /// Game-specific numeric metrics to merge into the bucket's extensible bag (e.g. moves, foundations).
    public let metrics: [String: Double]
    /// Whether this result must be excluded from statistics — set from
    /// `UndoEngine.isExcludedFromStatistics` (true for Practice Mode, R-ENG-7.4). The recorder skips it.
    public let isExcludedFromStatistics: Bool

    public init(
        key: StatisticsKey,
        won: Bool,
        score: Int? = nil,
        time: TimeInterval? = nil,
        metrics: [String: Double] = [:],
        isExcludedFromStatistics: Bool = false
    ) {
        self.key = key
        self.won = won
        self.score = score
        self.time = time
        self.metrics = metrics
        self.isExcludedFromStatistics = isExcludedFromStatistics
    }
}

// MARK: - Accumulated statistics for one bucket

/// The accumulated statistics for one game/variant bucket (R-APP-4.1).
///
/// A pure value: games played and won, the current and best win streaks, the best (max) score and best
/// (min) time, and an extensible `metrics` bag for game-specific aggregates. `winPercentage` is DERIVED
/// (never stored), so it can never drift from the counts. `recording(_:)` returns an updated copy for a
/// completed game — the single place the counting/streak/best rules live, so they are testable in
/// isolation. All fields are `Codable`, so a bucket round-trips through the store's JSON.
public struct GameStatistics: Sendable, Codable, Equatable {
    /// Total games played in this bucket (excluding Practice Mode, R-ENG-7.4).
    public var gamesPlayed: Int
    /// Total games won in this bucket.
    public var gamesWon: Int
    /// The current consecutive-win streak: incremented on a win, reset to 0 on a loss.
    public var currentStreak: Int
    /// The longest win streak ever reached in this bucket.
    public var bestStreak: Int
    /// The best (highest) score recorded, or `nil` if no scored game has completed.
    public var bestScore: Int?
    /// The best (lowest) time recorded, or `nil` if no timed game has completed.
    public var bestTime: TimeInterval?
    /// Extensible game-specific aggregates (e.g. `"bestMoves"`, `"totalFoundations"`). Merged per the
    /// game's own semantics; the recorder keeps the best (max) seen per key by default (see `recording`).
    public var metrics: [String: Double]

    public init(
        gamesPlayed: Int = 0,
        gamesWon: Int = 0,
        currentStreak: Int = 0,
        bestStreak: Int = 0,
        bestScore: Int? = nil,
        bestTime: TimeInterval? = nil,
        metrics: [String: Double] = [:]
    ) {
        self.gamesPlayed = gamesPlayed
        self.gamesWon = gamesWon
        self.currentStreak = currentStreak
        self.bestStreak = bestStreak
        self.bestScore = bestScore
        self.bestTime = bestTime
        self.metrics = metrics
    }

    /// The empty starting record for a bucket that has seen no games.
    public static var empty: GameStatistics { GameStatistics() }

    /// Games won as a fraction of games played, in `0...1` — DERIVED, never stored (R-APP-4.1).
    ///
    /// Returns `0` when no games have been played, so the App can show `0%` for a fresh bucket without a
    /// divide-by-zero. Multiply by 100 for the percentage the UI displays.
    public var winPercentage: Double {
        gamesPlayed == 0 ? 0 : Double(gamesWon) / Double(gamesPlayed)
    }

    /// Return a copy of this record updated for one completed `result` (R-APP-4.1).
    ///
    /// The single place the accumulation rules live, so they are unit- and property-testable:
    ///   • `gamesPlayed` += 1 always; `gamesWon` += 1 on a win.
    ///   • `currentStreak` increments on a win and resets to 0 on a loss; `bestStreak` = max(bestStreak,
    ///     currentStreak) so it only ever grows.
    ///   • `bestScore` = max(existing, result.score) — a higher score is better; a `nil` result score
    ///     leaves it unchanged.
    ///   • `bestTime` = min(existing, result.time) — a lower time is better; a `nil` result time leaves
    ///     it unchanged.
    ///   • `metrics` merge by keeping the max per key (a sensible "personal best" default for extensible
    ///     game-specific numbers); a key absent from `result.metrics` is untouched.
    ///
    /// This does NOT consult `result.isExcludedFromStatistics` — excluding a Practice-Mode game is the
    /// recorder's job (StatisticsStore.swift), which never calls this for an excluded result (R-ENG-7.4).
    public func recording(_ result: GameResult) -> GameStatistics {
        var copy = self
        copy.gamesPlayed += 1
        if result.won {
            copy.gamesWon += 1
            copy.currentStreak += 1
            copy.bestStreak = max(copy.bestStreak, copy.currentStreak)
        } else {
            copy.currentStreak = 0
        }
        if let score = result.score {
            copy.bestScore = copy.bestScore.map { max($0, score) } ?? score
        }
        if let time = result.time {
            copy.bestTime = copy.bestTime.map { min($0, time) } ?? time
        }
        for (name, value) in result.metrics {
            copy.metrics[name] = copy.metrics[name].map { max($0, value) } ?? value
        }
        return copy
    }
}
