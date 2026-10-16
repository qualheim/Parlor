// The save-format migration registry — a chain of `schemaVersion n → n+1` transforms run against the raw
// decoded form BEFORE strong-typing to the current `SaveDocument` (R-PERS-2.1; design.md §4 "Migration").
//
// WHY MIGRATE THE RAW FORM, NOT THE TYPED DOCUMENT. `SaveDocument` is the shape of the CURRENT schema; a
// value written by an older version might not have today's keys (or might spell them differently), so it
// cannot be decoded into `SaveDocument` at all until it has been brought up to the current shape. The
// registry therefore operates on the loosely-typed JSON object (`[String: Any]`) that `JSONSerialization`
// produces: each transform reshapes that dictionary from one version to the next, and only once the chain
// has reached `currentSchemaVersion` does the codec strong-type the result. This is exactly design.md §4:
// "A registry maps schemaVersion n → n+1 transforms; loading an older save runs the chain."
//
// TYPED FAILURE, NEVER A TRAP (R-PERS-2.2). If the object has no version we treat it as the same floor the
// document's decoder uses (version 1 — see `SaveDocument.init(from:)`). If the version is NEWER than this
// build understands, or a step in the chain has no registered transform, or the payload is not a JSON
// object at all, the migrator returns a typed `MigrationError`. The resume/load layer turns that into a
// non-modal notice + discard (never a crash) — the graceful handling task 6.2 wires in `AutosaveSession`.
//
// SCHEMA VERSION 1 TODAY. `SaveDocument.currentSchemaVersion` is 1, so production has no real n → n+1 step
// yet. The registry ships the MECHANISM plus the seam to register transforms; the tests register a
// synthetic v0 → v1 transform (and drive an unknown-version failure) to prove the chain runs, is applied
// in order, and reports incompatible versions — so the machinery is proven before a real bump needs it.

import Foundation

// MARK: - Migration failure (typed; graceful handling is the loader's job)

/// Why a raw save form could not be migrated to the current schema (R-PERS-2.2).
///
/// Returned (never trapped) so the loader can discard the save and show a non-modal notice rather than
/// crash. Distinguishes the "we simply can't read this" cases so a caller could, in principle, message
/// them differently.
public enum MigrationError: Error, Sendable, Equatable {
    /// The bytes were not a JSON object at the top level, so there is nothing to migrate.
    case notAnObject
    /// The save's `schemaVersion` is newer than this build supports — a save written by a FUTURE version
    /// (an incompatible, not merely old, save).
    case versionTooNew(found: Int, current: Int)
    /// The chain reached a version with no registered transform to the next one — a gap the registry
    /// cannot bridge (an unknown/incompatible intermediate version).
    case noTransform(fromVersion: Int)
    /// A registered transform threw while reshaping the object (a malformed older save).
    case transformFailed(fromVersion: Int)
}

// MARK: - Migration registry (design.md §4 "Migration")

/// A registry of `schemaVersion n → n+1` transforms applied to the raw decoded JSON object, run as a chain
/// to bring an older save up to the current schema before it is strong-typed (R-PERS-2.1).
///
/// A transform receives the JSON object at version `n` and returns the object reshaped to version `n+1`
/// (it need not touch the `schemaVersion` key — the migrator stamps the new version after each step). The
/// registry is keyed by the SOURCE version, so `register(fromVersion: 0) { … }` upgrades a v0 save to v1.
///
/// `Sendable` and value-semantic so the codec can hold one; transforms are `@Sendable` closures over pure
/// dictionary reshaping (no I/O, no state), matching the engine's "transforms are data" style.
public struct SaveMigrator: Sendable {
    /// One `n → n+1` reshaping of the raw JSON object. Pure: it maps the dictionary at version `n` to the
    /// dictionary at version `n+1`, throwing if the input is too malformed to upgrade.
    public typealias Transform = @Sendable ([String: Any]) throws -> [String: Any]

    /// Transforms keyed by their SOURCE version: `transforms[n]` upgrades a version-`n` object to `n+1`.
    private var transforms: [Int: Transform]

    /// The version an object with no `schemaVersion` key is treated as — the same floor
    /// `SaveDocument.init(from:)` uses (1), so a save with an absent version is already current and the
    /// chain is a no-op. A test may lower this (e.g. to 0) to exercise a synthetic older version.
    private let absentVersionFloor: Int

    /// Build a migrator. `absentVersionFloor` is the version assumed when a save omits `schemaVersion`
    /// (defaults to 1, matching the document decoder); tests lower it to drive a v0 → v1 chain.
    public init(absentVersionFloor: Int = 1) {
        self.transforms = [:]
        self.absentVersionFloor = absentVersionFloor
    }

    /// Register the transform that upgrades a version-`fromVersion` object to `fromVersion + 1`.
    ///
    /// Returns a new migrator with the transform added (value semantics), so a caller composes a chain
    /// declaratively: `SaveMigrator().registering(fromVersion: 0) { … }.registering(fromVersion: 1) { … }`.
    public func registering(fromVersion: Int, _ transform: @escaping Transform) -> SaveMigrator {
        var copy = self
        copy.transforms[fromVersion] = transform
        return copy
    }

    /// The version recorded in `object`, or `absentVersionFloor` when the key is absent — matching the
    /// document decoder's tolerance of an older save with no version (`SaveDocument.init(from:)`).
    private func version(of object: [String: Any]) -> Int {
        (object["schemaVersion"] as? Int) ?? absentVersionFloor
    }

    /// Migrate `object` from its recorded version up to `targetVersion`, running each registered
    /// `n → n+1` transform in order and stamping the new `schemaVersion` after each step (R-PERS-2.1).
    ///
    /// - A save already at `targetVersion` is returned unchanged (the chain is empty).
    /// - A save NEWER than `targetVersion` is `versionTooNew` — this build cannot read a future format.
    /// - A step with no registered transform is `noTransform` — an unknown/incompatible intermediate.
    /// The result always carries `schemaVersion == targetVersion`, ready to strong-type.
    public func migrate(
        _ object: [String: Any], to targetVersion: Int
    ) throws -> [String: Any] {
        var current = object
        var currentVersion = version(of: current)

        if currentVersion > targetVersion {
            throw MigrationError.versionTooNew(found: currentVersion, current: targetVersion)
        }

        while currentVersion < targetVersion {
            guard let transform = transforms[currentVersion] else {
                throw MigrationError.noTransform(fromVersion: currentVersion)
            }
            do {
                current = try transform(current)
            } catch {
                throw MigrationError.transformFailed(fromVersion: currentVersion)
            }
            currentVersion += 1
            current["schemaVersion"] = currentVersion
        }
        return current
    }
}
