// The statistics store + recorder — where the per-game/variant records live, and the flow that records a
// finished game, reads a bucket, and resets (R-APP-4.1, R-APP-4.3, R-ENG-7.4, R-PERS-3.1).
//
// Mirrors SaveStore.swift's shape so the persistence seams are consistent:
//
//   • `StatisticsStore` — a protocol for the raw I/O of the WHOLE stats table (load all, save all). Unlike
//     saves there is one small table (a dictionary keyed by `StatisticsKey`), so the store moves the whole
//     table at once rather than per-slot files; per-key access is a convenience layered on top.
//   • `SandboxStatisticsStore` — the production conformer, writing ONE JSON file in the app's sandbox
//     container (Application Support) and ONLY there — no cloud (R-PERS-3.1). Atomic write, created on
//     demand.
//   • `InMemoryStatisticsStore` — a dictionary-backed conformer for headless tests and previews.
//   • `StatisticsCodec` — encodes the stats table to bytes and back, kept separate so the JSON round-trip
//     is testable without a file system (same split as `SaveCodec`).
//   • `StatisticsService` — the recorder/flow: record a `GameResult` (SKIPPING an excluded Practice-Mode
//     result, R-ENG-7.4), read a bucket, and `reset`/`resetAll` gated behind an explicit confirmation
//     (R-APP-4.3). It reads/writes the table through an injected `StatisticsStore`, so the whole flow runs
//     headless in tests against `InMemoryStatisticsStore`.
//
// CONFIRM-ON-RESET (R-APP-4.3). Reset is destructive, so the service models the confirmation as a required
// explicit argument: `reset(key:confirmed:)` / `resetAll(confirmed:)` are NO-OPS unless `confirmed == true`.
// The App shows the destructive confirmation DIALOG (per ux-guidelines.md) and only then calls with
// `confirmed: true`; Persistence has no UI, so it owns the *gate*, not the dialog. Modeling it as a value/
// flow keeps "unconfirmed reset does nothing; confirmed reset clears" fully testable.

import Foundation

// MARK: - The stats table

/// The whole statistics table: every bucket keyed by its `StatisticsKey` (R-APP-4.1).
///
/// A thin, `Codable` value wrapping the dictionary so the store moves one small document. Encoded as a
/// JSON object whose keys are the `StatisticsKey`'s `"gameID#variant"` string form (see `StatisticsKey`).
public struct StatisticsTable: Sendable, Codable, Equatable {
    /// Every recorded bucket, keyed by game + variant.
    public var buckets: [StatisticsKey: GameStatistics]

    public init(buckets: [StatisticsKey: GameStatistics] = [:]) {
        self.buckets = buckets
    }

    /// The empty table — no games recorded yet.
    public static var empty: StatisticsTable { StatisticsTable() }

    /// The record for `key`, or the empty record if the bucket has seen no games.
    public func statistics(for key: StatisticsKey) -> GameStatistics {
        buckets[key] ?? .empty
    }
}

// MARK: - StatisticsStore protocol

/// The raw I/O of the whole statistics table — the seam tests swap for an in-memory store (R-PERS-3.1).
///
/// The table is small, so the store loads/saves it whole rather than per-key; per-key reads/writes are
/// offered as defaulted conveniences implemented in terms of the whole-table methods. `Sendable` so the
/// service can hold it across the concurrency boundary.
public protocol StatisticsStore: Sendable {
    /// Load the full statistics table, or `.empty` if nothing has been stored yet.
    func load() throws -> StatisticsTable
    /// Persist the full statistics table, replacing any prior contents (R-PERS-3.1).
    func save(_ table: StatisticsTable) throws
}

extension StatisticsStore {
    /// The record for one bucket — a convenience over `load()`.
    public func statistics(for key: StatisticsKey) throws -> GameStatistics {
        try load().statistics(for: key)
    }

    /// Replace one bucket's record and persist — a convenience over `load()` + `save(_:)`.
    public func setStatistics(_ stats: GameStatistics, for key: StatisticsKey) throws {
        var table = try load()
        table.buckets[key] = stats
        try save(table)
    }
}

// MARK: - Statistics codec (bytes ⇄ table)

/// Encodes the `StatisticsTable` to bytes and back — kept separate from the store so the JSON round-trip
/// is testable independently of the file system (same split as `SaveCodec`).
///
/// JSON with sorted keys for a stable, diff-friendly on-disk form (matching the save codec's convention).
public struct StatisticsCodec: Sendable {
    public init() {}

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    /// Encode `table` to JSON bytes (R-PERS-3.1).
    public func encode(_ table: StatisticsTable) throws -> Data {
        try encoder.encode(table)
    }

    /// Decode a `StatisticsTable` from `data`.
    public func decode(from data: Data) throws -> StatisticsTable {
        try decoder.decode(StatisticsTable.self, from: data)
    }
}

// MARK: - Sandbox container store (R-PERS-3.1)

/// A `StatisticsStore` that reads/writes ONE JSON file under the app's local sandbox container and ONLY
/// there — no cloud (R-PERS-3.1).
///
/// The file lives directly in the app's Application Support directory, which inside the App Sandbox
/// resolves to the app's own container (R-BUILD-3.1) — the record never leaves the user's Mac. The
/// directory is created on demand; the write is atomic so an interrupted write leaves the prior record
/// intact. A missing file loads as `.empty` (a fresh install has no stats yet). Composes a
/// `StatisticsCodec`, so encode/decode stays testable without disk.
public struct SandboxStatisticsStore: StatisticsStore {
    private let fileURL: URL
    private let codec: StatisticsCodec

    /// Create a store writing `Statistics.json` under `directory`, creating it if needed. Defaults to the
    /// app's Application Support container — the sandbox-local location stats belong in (R-PERS-3.1).
    ///
    /// A test may pass an explicit `directory` (e.g. a temp dir) to exercise the real disk path; the
    /// default reaches only the container. `FileManager.default` is thread-safe, so it is used directly
    /// rather than stored (it is not `Sendable`, and the store must be).
    public init(directory: URL? = nil, codec: StatisticsCodec = StatisticsCodec()) throws {
        let fileManager = FileManager.default
        let dir: URL
        if let directory {
            dir = directory
        } else {
            dir = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("Statistics.json", isDirectory: false)
        self.codec = codec
    }

    public func load() throws -> StatisticsTable {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        return try codec.decode(from: data)
    }

    public func save(_ table: StatisticsTable) throws {
        let data = try codec.encode(table)
        try data.write(to: fileURL, options: [.atomic])
    }
}

// MARK: - In-memory store (headless tests / previews)

/// A synchronous, `Sendable` in-memory `StatisticsStore` for tests and previews, backed by a lock-guarded
/// box — so the record/read/reset flow runs entirely in memory (R-PERS-3.1 seam).
///
/// A small `NSLock`-guarded box keeps it `Sendable` without an actor hop, mirroring `InMemorySaveStore`.
public final class InMemoryStatisticsStore: StatisticsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var table: StatisticsTable

    public init(_ table: StatisticsTable = .empty) {
        self.table = table
    }

    public func load() throws -> StatisticsTable {
        lock.lock()
        defer { lock.unlock() }
        return table
    }

    public func save(_ table: StatisticsTable) throws {
        lock.lock()
        defer { lock.unlock() }
        self.table = table
    }
}

// MARK: - Statistics service (record / read / reset)

/// Records finished games, reads buckets, and resets — the flow the App drives, gated so Practice Mode is
/// never counted and a reset always requires explicit confirmation (R-APP-4.1, R-APP-4.3, R-ENG-7.4).
///
/// Reads and writes the table through an injected `StatisticsStore`, so the whole flow is testable
/// headless against `InMemoryStatisticsStore`. It is an `actor` so read-modify-write of the table (load →
/// update → save) is atomic per call: two concurrent records can't clobber each other's update.
public actor StatisticsService {
    private let store: any StatisticsStore

    public init(store: any StatisticsStore) {
        self.store = store
    }

    /// Record one finished game, updating its bucket — UNLESS the result is excluded (Practice Mode),
    /// in which case nothing is recorded (R-APP-4.1, R-ENG-7.4).
    ///
    /// Returns the bucket's record after recording (or its unchanged record for an excluded result), so a
    /// caller can show the just-updated stats without a second read. An excluded result is dropped whole
    /// per R-ENG-7.4 — a practice-mode game must not count at all — so `gamesPlayed` does not move.
    @discardableResult
    public func record(_ result: GameResult) throws -> GameStatistics {
        var table = try store.load()
        let current = table.statistics(for: result.key)
        guard !result.isExcludedFromStatistics else { return current }
        let updated = current.recording(result)
        table.buckets[result.key] = updated
        try store.save(table)
        return updated
    }

    /// The record for `key`, or the empty record if the bucket has seen no games (R-APP-4.1).
    public func statistics(for key: StatisticsKey) throws -> GameStatistics {
        try store.statistics(for: key)
    }

    /// The full statistics table — for the App's stats screen and the series helpers (R-APP-4.2).
    public func allStatistics() throws -> StatisticsTable {
        try store.load()
    }

    /// Reset ONE bucket's statistics — a NO-OP unless `confirmed` is true (R-APP-4.3).
    ///
    /// Resetting is destructive, so the App must first show its confirmation dialog (per ux-guidelines.md)
    /// and only then call with `confirmed: true`. Persistence owns the gate, not the dialog: an
    /// unconfirmed call changes nothing and returns `false`; a confirmed call clears the bucket and
    /// returns `true`. Clearing removes the bucket entirely so it reads back as `.empty`.
    @discardableResult
    public func reset(key: StatisticsKey, confirmed: Bool) throws -> Bool {
        guard confirmed else { return false }
        var table = try store.load()
        table.buckets[key] = nil
        try store.save(table)
        return true
    }

    /// Reset ALL statistics — a NO-OP unless `confirmed` is true (R-APP-4.3).
    ///
    /// The whole-table counterpart to `reset(key:confirmed:)`, gated the same way: unconfirmed does
    /// nothing and returns `false`; confirmed replaces the table with `.empty` and returns `true`.
    @discardableResult
    public func resetAll(confirmed: Bool) throws -> Bool {
        guard confirmed else { return false }
        try store.save(.empty)
        return true
    }
}
