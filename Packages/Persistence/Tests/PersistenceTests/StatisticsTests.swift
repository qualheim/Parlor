import Foundation
import Testing

@testable import Persistence

// Statistics — task 6.3. Covers the pure accumulation rules (counts, streaks, best score = max, best time
// = min, metrics merge), the derived win %, the Practice-Mode exclusion (R-ENG-7.4), confirm-on-reset
// (R-APP-4.3), the JSON round-trip through the store (R-PERS-3.1), and the chart-series derivation
// (R-APP-4.2).

@Suite("GameStatistics accumulation")
struct GameStatisticsTests {
    private let key = StatisticsKey(gameID: "klondike", variantKey: "draw1")

    @Test("recording a win increments played, won, and the current/best streak")
    func recordingWin() {
        var stats = GameStatistics.empty
        stats = stats.recording(GameResult(key: key, won: true))
        stats = stats.recording(GameResult(key: key, won: true))
        #expect(stats.gamesPlayed == 2)
        #expect(stats.gamesWon == 2)
        #expect(stats.currentStreak == 2)
        #expect(stats.bestStreak == 2)
    }

    @Test("a loss resets the current streak but keeps the best streak")
    func lossResetsStreak() {
        var stats = GameStatistics.empty
        stats = stats.recording(GameResult(key: key, won: true))
        stats = stats.recording(GameResult(key: key, won: true))
        stats = stats.recording(GameResult(key: key, won: false))
        #expect(stats.gamesPlayed == 3)
        #expect(stats.gamesWon == 2)
        #expect(stats.currentStreak == 0)
        #expect(stats.bestStreak == 2)
    }

    @Test("best score keeps the maximum; best time keeps the minimum")
    func bestScoreMaxBestTimeMin() {
        var stats = GameStatistics.empty
        stats = stats.recording(GameResult(key: key, won: true, score: 100, time: 300))
        stats = stats.recording(GameResult(key: key, won: false, score: 250, time: 500))
        stats = stats.recording(GameResult(key: key, won: true, score: 180, time: 120))
        #expect(stats.bestScore == 250)
        #expect(stats.bestTime == 120)
    }

    @Test("a nil score or time leaves the prior best untouched")
    func nilScoreTimeUntouched() {
        var stats = GameStatistics.empty
        stats = stats.recording(GameResult(key: key, won: true, score: 90, time: 200))
        stats = stats.recording(GameResult(key: key, won: true, score: nil, time: nil))
        #expect(stats.bestScore == 90)
        #expect(stats.bestTime == 200)
    }

    @Test("metrics merge by keeping the max per key")
    func metricsMergeMax() {
        var stats = GameStatistics.empty
        stats = stats.recording(
            GameResult(key: key, won: true, metrics: ["moves": 120, "hints": 2]))
        stats = stats.recording(
            GameResult(key: key, won: true, metrics: ["moves": 90, "hints": 5]))
        #expect(stats.metrics["moves"] == 120)
        #expect(stats.metrics["hints"] == 5)
    }

    @Test("winPercentage is derived from counts and is 0 for an empty bucket")
    func winPercentageDerivation() {
        #expect(GameStatistics.empty.winPercentage == 0)
        var stats = GameStatistics.empty
        stats = stats.recording(GameResult(key: key, won: true))
        stats = stats.recording(GameResult(key: key, won: false))
        stats = stats.recording(GameResult(key: key, won: true))
        stats = stats.recording(GameResult(key: key, won: true))
        #expect(stats.gamesPlayed == 4)
        #expect(stats.gamesWon == 3)
        #expect(abs(stats.winPercentage - 0.75) < 1e-9)
    }
}

@Suite("StatisticsService flow")
struct StatisticsServiceTests {
    private let key = StatisticsKey(gameID: "crazy-eights", variantKey: "target100")

    @Test("recording a normal result counts it")
    func recordCountsResult() async throws {
        let service = StatisticsService(store: InMemoryStatisticsStore())
        let stats = try await service.record(GameResult(key: key, won: true, score: 50))
        #expect(stats.gamesPlayed == 1)
        #expect(stats.gamesWon == 1)
        #expect(try await service.statistics(for: key).bestScore == 50)
    }

    @Test("a Practice-Mode result is NOT recorded (R-ENG-7.4)")
    func practiceModeExcluded() async throws {
        let service = StatisticsService(store: InMemoryStatisticsStore())
        let stats = try await service.record(
            GameResult(key: key, won: true, score: 999, isExcludedFromStatistics: true))
        #expect(stats.gamesPlayed == 0)
        #expect(stats.gamesWon == 0)
        #expect(stats.bestScore == nil)
        // And the stored bucket is still empty.
        #expect(try await service.statistics(for: key) == .empty)
    }

    @Test("unconfirmed reset is a no-op; confirmed reset clears the bucket (R-APP-4.3)")
    func resetRequiresConfirmation() async throws {
        let service = StatisticsService(store: InMemoryStatisticsStore())
        _ = try await service.record(GameResult(key: key, won: true))
        _ = try await service.record(GameResult(key: key, won: true))

        let unconfirmed = try await service.reset(key: key, confirmed: false)
        #expect(unconfirmed == false)
        #expect(try await service.statistics(for: key).gamesPlayed == 2)

        let confirmed = try await service.reset(key: key, confirmed: true)
        #expect(confirmed == true)
        #expect(try await service.statistics(for: key) == .empty)
    }

    @Test("unconfirmed resetAll is a no-op; confirmed resetAll clears everything (R-APP-4.3)")
    func resetAllRequiresConfirmation() async throws {
        let service = StatisticsService(store: InMemoryStatisticsStore())
        let other = StatisticsKey(gameID: "klondike")
        _ = try await service.record(GameResult(key: key, won: true))
        _ = try await service.record(GameResult(key: other, won: false))

        #expect(try await service.resetAll(confirmed: false) == false)
        #expect(try await service.allStatistics().buckets.count == 2)

        #expect(try await service.resetAll(confirmed: true) == true)
        #expect(try await service.allStatistics() == .empty)
    }
}

@Suite("Statistics store + codec round-trip")
struct StatisticsStoreTests {
    @Test("the table round-trips through the JSON codec")
    func codecRoundTrip() throws {
        var table = StatisticsTable.empty
        table.buckets[StatisticsKey(gameID: "klondike", variantKey: "draw3")] =
            GameStatistics(
                gamesPlayed: 5, gamesWon: 3, currentStreak: 1, bestStreak: 2,
                bestScore: 300, bestTime: 90, metrics: ["moves": 88])
        table.buckets[StatisticsKey(gameID: "crazy-eights")] =
            GameStatistics(gamesPlayed: 2, gamesWon: 1)

        let codec = StatisticsCodec()
        let data = try codec.encode(table)
        let decoded = try codec.decode(from: data)
        #expect(decoded == table)
    }

    @Test("StatisticsKey encodes as gameID#variant and round-trips, incl. empty variant")
    func keyEncoding() throws {
        let codec = StatisticsCodec()
        var table = StatisticsTable.empty
        let withVariant = StatisticsKey(gameID: "klondike", variantKey: "draw1")
        let noVariant = StatisticsKey(gameID: "crazy-eights")
        table.buckets[withVariant] = GameStatistics(gamesPlayed: 1)
        table.buckets[noVariant] = GameStatistics(gamesPlayed: 2)

        let decoded = try codec.decode(from: try codec.encode(table))
        #expect(decoded.buckets[withVariant]?.gamesPlayed == 1)
        #expect(decoded.buckets[noVariant]?.gamesPlayed == 2)
        #expect(withVariant.description == "klondike#draw1")
        #expect(noVariant.description == "crazy-eights")
    }

    @Test("SandboxStatisticsStore writes and reads one JSON file in its directory (R-PERS-3.1)")
    func sandboxStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parlor-stats-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SandboxStatisticsStore(directory: dir)
        // A missing file loads as empty.
        #expect(try store.load() == .empty)

        var table = StatisticsTable.empty
        table.buckets[StatisticsKey(gameID: "klondike")] =
            GameStatistics(gamesPlayed: 7, gamesWon: 4)
        try store.save(table)

        let reloaded = try SandboxStatisticsStore(directory: dir).load()
        #expect(reloaded == table)
    }

    @Test("the in-memory store keeps stats in memory across load/save")
    func inMemoryStore() throws {
        let store = InMemoryStatisticsStore()
        var table = StatisticsTable.empty
        table.buckets[StatisticsKey(gameID: "klondike")] = GameStatistics(gamesPlayed: 3)
        try store.save(table)
        #expect(try store.load() == table)
    }
}

@Suite("Statistics series derivation")
struct StatisticsSeriesTests {
    private let key = StatisticsKey(gameID: "klondike")

    private func result(_ won: Bool, score: Int? = nil, excluded: Bool = false) -> GameResult {
        GameResult(key: key, won: won, score: score, isExcludedFromStatistics: excluded)
    }

    @Test("cumulative win percentage over time")
    func winPercentageSeries() {
        let history = [result(true), result(false), result(true), result(true)]
        let points = StatisticsSeries.winPercentageOverTime(history)
        #expect(points.map(\.index) == [0, 1, 2, 3])
        #expect(points[0].value == 1.0)
        #expect(abs(points[1].value - 0.5) < 1e-9)
        #expect(abs(points[2].value - 2.0 / 3.0) < 1e-9)
        #expect(points[3].value == 0.75)
    }

    @Test("streak history increments on wins and resets on losses")
    func streakSeries() {
        let history = [result(true), result(true), result(false), result(true)]
        let points = StatisticsSeries.streakHistory(history)
        #expect(points.map(\.value) == [1, 2, 0, 1])
    }

    @Test("score-over-time skips unscored games but keeps positional index")
    func scoreSeries() {
        let history = [result(true, score: 100), result(false), result(true, score: 250)]
        let points = StatisticsSeries.scoreOverTime(history)
        #expect(points.count == 2)
        #expect(points[0].index == 0)
        #expect(points[0].value == 100)
        #expect(points[1].index == 2)
        #expect(points[1].value == 250)
    }

    @Test("excluded Practice-Mode results are dropped before deriving series (R-ENG-7.4)")
    func excludedDropped() {
        let history = [result(true), result(true, excluded: true), result(false)]
        let points = StatisticsSeries.winPercentageOverTime(history)
        // Only the two included games remain: win then loss.
        #expect(points.count == 2)
        #expect(points[0].value == 1.0)
        #expect(abs(points[1].value - 0.5) < 1e-9)
    }

    @Test("dates thread through to points when supplied")
    func datedPoints() {
        let base = Date(timeIntervalSince1970: 1_000)
        let dates = [base, base.addingTimeInterval(60), base.addingTimeInterval(120)]
        let history = [result(true, score: 10), result(false), result(true, score: 30)]
        let points = StatisticsSeries.scoreOverTime(history, dates: dates)
        #expect(points.first?.date == base)
        #expect(points.last?.date == base.addingTimeInterval(120))
    }
}
