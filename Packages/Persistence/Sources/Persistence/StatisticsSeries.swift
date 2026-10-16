// Chart-series helpers — pure functions that turn a history of finished games into the point arrays a
// Swift Charts view binds to (R-APP-4.1, R-APP-4.2).
//
// Persistence must not import Charts (or any UI framework), so this file stops at the DATA a chart needs:
// arrays of plain `(index, value)` points, plus optional dates for time-axis charts. The App's
// DesignSystem layer renders these with Swift Charts — a `LineMark`/`BarMark` per series — per R-APP-4.2
// and tech.md rendering. Keeping the derivation here, as pure functions over an ordered history, means the
// "what the chart shows" logic is unit-testable without a view: feed a history, assert the points.
//
// The history is an ordered list of `GameResult` (oldest first) — the same value the recorder consumes.
// The App keeps such a history per bucket (or derives it from a log); these helpers do not persist it,
// they only shape it. Excluded (Practice-Mode) results are filtered out first, so the charts match the
// recorded stats (R-ENG-7.4).

import Foundation

// MARK: - A chart point

/// One point in a derived series — an ordinal `index` (0-based position in the history), an optional
/// `date` for time-axis charts, and the `value` plotted (R-APP-4.2).
///
/// A plain, `Equatable` value with no UI type, so a Swift Charts `LineMark`/`PointMark` in the App can map
/// it to `x`/`y` however it likes (by `index` for an evenly-spaced axis, or by `date` when present). Tests
/// assert the array of points a helper produces.
public struct StatisticsPoint: Sendable, Equatable {
    /// The 0-based position of this point in the history it was derived from.
    public let index: Int
    /// The timestamp for this point, when the caller supplied dated history; `nil` for index-only series.
    public let date: Date?
    /// The plotted value (a win %, a streak length, a score, …).
    public let value: Double

    public init(index: Int, date: Date? = nil, value: Double) {
        self.index = index
        self.date = date
        self.value = value
    }
}

// MARK: - Series derivation

/// Pure derivations of chart-friendly series from an ordered game history (oldest first) — the arrays a
/// Swift Charts view in the App binds to (R-APP-4.1, R-APP-4.2).
///
/// Every function first drops results flagged `isExcludedFromStatistics` (Practice Mode, R-ENG-7.4) so the
/// charts match the recorded stats, then walks the remaining results in order. The App/DesignSystem
/// renders the returned points with Swift Charts (R-APP-4.2); Persistence stays UI-free.
public enum StatisticsSeries {
    /// Drop excluded (Practice-Mode) results, preserving order (R-ENG-7.4).
    private static func included(_ history: [GameResult]) -> [GameResult] {
        history.filter { !$0.isExcludedFromStatistics }
    }

    /// The CUMULATIVE win percentage after each game, in `0...1` — a line that shows how the win rate
    /// trends over a session (R-APP-4.1, R-APP-4.2).
    ///
    /// Point `i` is (wins in the first `i+1` games) / (`i+1`). Empty history → no points. `dated` walks
    /// the optional per-game timestamps for a time-axis chart; pass `nil` (default) for an index-only
    /// series.
    public static func winPercentageOverTime(
        _ history: [GameResult], dates: [Date]? = nil
    ) -> [StatisticsPoint] {
        let games = included(history)
        var wins = 0
        return games.enumerated().map { index, result in
            if result.won { wins += 1 }
            return StatisticsPoint(
                index: index,
                date: dates?[safe: index],
                value: Double(wins) / Double(index + 1))
        }
    }

    /// The CURRENT win-streak length after each game — increments on a win, resets to 0 on a loss —
    /// visualizing streak history (R-APP-4.1, R-APP-4.2).
    public static func streakHistory(
        _ history: [GameResult], dates: [Date]? = nil
    ) -> [StatisticsPoint] {
        let games = included(history)
        var streak = 0
        return games.enumerated().map { index, result in
            streak = result.won ? streak + 1 : 0
            return StatisticsPoint(
                index: index, date: dates?[safe: index], value: Double(streak))
        }
    }

    /// The score of each SCORED game over time — a point per game that reported a score (R-APP-4.1,
    /// R-APP-4.2).
    ///
    /// Games with no score (`result.score == nil`) are skipped, but the point's `index` stays the game's
    /// position in the (included) history so the x-axis spacing reflects real order. When `dates` is
    /// supplied each point carries its game's timestamp for a time-axis chart.
    public static func scoreOverTime(
        _ history: [GameResult], dates: [Date]? = nil
    ) -> [StatisticsPoint] {
        let games = included(history)
        return games.enumerated().compactMap { index, result in
            guard let score = result.score else { return nil }
            return StatisticsPoint(
                index: index, date: dates?[safe: index], value: Double(score))
        }
    }
}

// MARK: - Safe indexing

extension Array {
    /// The element at `index`, or `nil` if out of bounds — used to pair optional dates with points
    /// without trapping when the dates array is shorter than the history.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
