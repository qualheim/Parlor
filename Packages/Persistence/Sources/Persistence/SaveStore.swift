// The save file store — a small, testable abstraction over where save bytes live (R-PERS-3.1).
//
// Two jobs are deliberately split so save encode/decode is testable headless without touching the real
// container (task 6.1 requirement):
//
//   • `SaveStore` — a protocol for the raw byte I/O of a save, keyed by a stable `SaveID`: write, read,
//     delete, exists, list. It knows nothing about `SaveDocument` or JSON; it just moves bytes. This is
//     the seam a test swaps for an in-memory store.
//   • `SandboxSaveStore` — the production conformer that reads/writes files under the app's sandbox
//     container (Application Support), and ONLY there — no cloud, no network (R-PERS-3.1). It creates the
//     directory on demand and writes atomically so a crash mid-write can't corrupt a prior good save.
//   • `InMemorySaveStore` — a conformer backed by a dictionary, for headless tests and previews. Same
//     behavior, no disk.
//
// The `SaveCodec` (below) turns a `SaveDocument` into bytes and back; the autosave layer composes a
// `SaveStore` + `SaveCodec` so the JSON encoding is tested independently of the file system.

import Foundation

// MARK: - Save identity

/// A stable key naming one save slot (R-PERS-1.1).
///
/// A thin value over a filename-safe string. The app keys a save by the game and (later) the session, so
/// resuming finds the right slot; task 6.1 uses one slot per game id (e.g. `"crazy-eights"`), which is
/// enough for autosave/resume. `sanitized` guards the on-disk filename against path separators so a
/// `SaveID` can never escape the container directory.
public struct SaveID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The raw slot name (e.g. a game id). Treated as an opaque handle.
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    /// A save slot for a game id — one autosave slot per game (task 6.1).
    public static func game(_ gameID: String) -> SaveID {
        SaveID(gameID)
    }

    public var description: String { raw }

    /// A filename-safe form of `raw`: anything that is not alphanumeric, `-`, or `_` becomes `_`, so the
    /// id can never contain a path separator or otherwise point outside the container directory.
    var sanitized: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = raw.map { allowed.contains($0) ? $0 : "_" }
        let cleaned = String(mapped)
        return cleaned.isEmpty ? "save" : cleaned
    }
}

// MARK: - SaveStore protocol

/// The raw byte I/O of a save, keyed by `SaveID` — the seam tests swap for an in-memory store
/// (R-PERS-3.1).
///
/// It moves bytes only; encoding to/from a `SaveDocument` is the `SaveCodec`'s job, so JSON round-tripping
/// is testable without a file system. `Sendable` so a store can be held across the concurrency boundary by
/// the autosave layer.
public protocol SaveStore: Sendable {
    /// Persist `data` for `id`, replacing any existing bytes (R-PERS-1.1).
    func write(_ data: Data, for id: SaveID) throws
    /// The bytes stored for `id`, or `nil` if there is no save under that id.
    func read(_ id: SaveID) throws -> Data?
    /// Remove the save under `id`, if any. A no-op when nothing is stored (used by the discard path,
    /// R-PERS-2.2, wired in task 6.2).
    func delete(_ id: SaveID) throws
    /// Whether a save exists under `id`.
    func exists(_ id: SaveID) -> Bool
    /// The ids of all stored saves — the Library's "Continue" hero reads this (R-APP-1.1, task 6.5).
    func allSaveIDs() throws -> [SaveID]
}

// MARK: - Sandbox container store (R-PERS-3.1)

/// A `SaveStore` that reads/writes files under the app's local sandbox container and ONLY there — no
/// cloud, no network (R-PERS-3.1).
///
/// Saves live in a `Saves/` subdirectory of the app's Application Support directory, which inside the App
/// Sandbox resolves to the app's own container (R-BUILD-3.1) — data never leaves the user's Mac. The
/// directory is created on first write. Writes are atomic (`.atomic`) so an interrupted write leaves the
/// previous good save intact rather than a half-written file. Each save is a single `.json` file named
/// from the `SaveID` (sanitized), so the store maps ids ↔ files without a separate index.
public struct SandboxSaveStore: SaveStore {
    /// The directory saves are stored in (…/Application Support/<container>/Saves).
    private let directory: URL

    /// Create a store rooted at `directory`, creating it if needed. Defaults to the app's Application
    /// Support container — the sandbox-local location saves belong in (R-PERS-3.1).
    ///
    /// A caller may pass an explicit `directory` (e.g. a temp dir in a test that still wants the real disk
    /// path), but the default is the container; nothing here reaches outside it. `FileManager.default` is
    /// documented thread-safe, so it is used directly in the methods rather than stored (it is not
    /// `Sendable`, and the store must be).
    public init(directory: URL? = nil) throws {
        let fileManager = FileManager.default
        if let directory {
            self.directory = directory
        } else {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            self.directory = base.appendingPathComponent("Saves", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
    }

    private func fileURL(for id: SaveID) -> URL {
        directory.appendingPathComponent("\(id.sanitized).json", isDirectory: false)
    }

    public func write(_ data: Data, for id: SaveID) throws {
        try data.write(to: fileURL(for: id), options: [.atomic])
    }

    public func read(_ id: SaveID) throws -> Data? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func delete(_ id: SaveID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func exists(_ id: SaveID) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    public func allSaveIDs() throws -> [SaveID] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return
            contents
            .filter { $0.pathExtension == "json" }
            .map { SaveID($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.raw < $1.raw }
    }
}

// MARK: - In-memory store (headless tests / previews)

/// A synchronous, `Sendable` in-memory `SaveStore` for tests and previews, backed by a lock-guarded box —
/// so save encode/decode and autosave/resume can be exercised without touching the real container (task
/// 6.1 requirement).
///
/// The `SaveStore` protocol is synchronous (its methods mirror simple file I/O), so the test store is too;
/// a small `NSLock`-guarded reference box keeps it `Sendable` without an actor hop. Use this in tests to
/// drive the autosave layer entirely in memory.
public final class InMemorySaveStore: SaveStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SaveID: Data] = [:]

    public init() {}

    public func write(_ data: Data, for id: SaveID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = data
    }

    public func read(_ id: SaveID) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    public func delete(_ id: SaveID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = nil
    }

    public func exists(_ id: SaveID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[id] != nil
    }

    public func allSaveIDs() throws -> [SaveID] {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.sorted { $0.raw < $1.raw }
    }
}

// MARK: - Save codec (bytes ⇄ document)

/// Encodes a `SaveDocument` to bytes and back — kept separate from `SaveStore` so the JSON round-trip is
/// tested independently of the file system (task 6.1 requirement).
///
/// JSON with sorted keys so the on-disk form is stable and diff-friendly (matching the engine's canonical
/// encoding convention, ADR 0002 decision 4). Dates encode as ISO-8601 so `createdAt`/`updatedAt` read as
/// the timestamps design.md §4 shows. Generic over the game's `Options` so it encodes the matching
/// `SaveDocument<Options>`.
public struct SaveCodec: Sendable {
    public init() {}

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Encode `document` to JSON bytes (R-PERS-1.1).
    public func encode<Options: GameOptions>(_ document: SaveDocument<Options>) throws -> Data {
        try encoder.encode(document)
    }

    /// Decode a `SaveDocument` from `data` for the given game `Options` type (R-PERS-1.2).
    public func decode<Options: GameOptions>(
        _ type: SaveDocument<Options>.Type, from data: Data
    ) throws -> SaveDocument<Options> {
        try decoder.decode(SaveDocument<Options>.self, from: data)
    }

    /// Decode a `SaveDocument` from `data`, first running `migrator`'s `n → n+1` chain against the raw
    /// JSON form so an older save is brought up to the current schema BEFORE it is strong-typed
    /// (R-PERS-2.1; design.md §4 "Migration").
    ///
    /// The bytes are parsed to a loosely-typed JSON object, migrated up to
    /// `SaveDocument.currentSchemaVersion`, re-serialized, and only then decoded into the current
    /// `SaveDocument<Options>`. A payload that is not a JSON object, is at a version this build cannot
    /// read, or hits a gap in the migration chain surfaces as a `MigrationError` — which the loader turns
    /// into a non-modal notice + discard rather than a crash (R-PERS-2.2). A genuinely corrupt payload
    /// (not JSON) throws before migration, exactly as the non-migrating `decode` would.
    public func decodeMigrating<Options: GameOptions>(
        _ type: SaveDocument<Options>.Type, from data: Data, migrator: SaveMigrator
    ) throws -> SaveDocument<Options> {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationError.notAnObject
        }
        let migrated = try migrator.migrate(
            object, to: SaveDocument<Options>.currentSchemaVersion)
        // Re-serialize the migrated object with ISO-8601 dates preserved as strings (they survive the
        // dictionary round-trip untouched), then strong-type through the same decoder as `decode`.
        let migratedData = try JSONSerialization.data(withJSONObject: migrated)
        return try decoder.decode(SaveDocument<Options>.self, from: migratedData)
    }
}
