// ProfileStore — the app's editable local player profile, persisted (interim) in UserDefaults
// (R-SESS-5.2).
//
// R-SESS-5.2 requires the app to provide an editable local profile. The profile MODEL is a pure
// EngineCore value type (`PlayerProfile`, Profiles.swift) surfaced to the App through Persistence's
// `@_exported import EngineCore` — the App never imports the internal EngineCore module directly, keeping
// the dependency graph legal (design.md §1).
//
// INTERIM PERSISTENCE. The full versioned save/settings store is Phase 6 (task 6.4; R-PERS-3.1). Until
// then the local profile is stored as one JSON blob under a single UserDefaults key inside the sandbox
// container — local-only, no cloud (R-PERS-3.1). This is deliberately thin and is expected to be replaced
// by the Persistence settings store; the key and codec live here so that migration is a straight read.
//
// The encode/decode + apply-edit logic is written as pure, side-effect-free statics so it is unit-testable
// without a live `UserDefaults` (the SwiftPM App target is not unit-tested; these statics keep the logic
// verifiable and are exercised by the app at runtime). `LocalProfileStore` is the thin `@Observable`
// wrapper the SwiftUI view binds to.

import Foundation
import Observation
import Persistence  // re-exports EngineCore: PlayerProfile, AvatarReference, ProfileID (R-SESS-5)

// MARK: - Pure codec / edit logic (unit-testable)

/// Pure, storage-agnostic helpers for the local profile: encode, decode-with-fallback, and applying an
/// edit. Kept free of `UserDefaults` so the logic is verifiable and reused by the `@Observable` store.
enum ProfileCodec {
    /// The UserDefaults key the interim local profile is stored under (Phase 6 replaces this store).
    static let defaultsKey = "com.parlor.localProfile.v1"

    /// Encode a profile to JSON for storage. Sorted keys keep the blob stable across writes.
    static func encode(_ profile: PlayerProfile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(profile)
    }

    /// Decode a stored profile, returning `nil` if the data is absent or unreadable (a corrupt blob is
    /// treated as "no saved profile" so the caller falls back to a fresh default — never a crash,
    /// R-PERS-2.2 in spirit).
    static func decode(_ data: Data?) -> PlayerProfile? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(PlayerProfile.self, from: data)
    }

    /// Load the stored profile, or a fresh default local human when none is saved yet (R-SESS-5.2).
    /// Preserves the stored profile's stable `id` so edits never re-mint identity.
    static func loadOrDefault(from data: Data?) -> PlayerProfile {
        decode(data) ?? PlayerProfile.defaultLocalHuman()
    }

    /// Apply a display-name + avatar edit to `profile`, keeping its stable `id` and `controllerKind`
    /// (R-SESS-5.1: id is independent of name/avatar). A blank name is normalized to a sensible default so
    /// the seat plate is never empty.
    static func applyingEdit(
        to profile: PlayerProfile,
        displayName: String,
        avatar: AvatarReference
    ) -> PlayerProfile {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlayerProfile(
            id: profile.id,
            displayName: trimmed.isEmpty ? "Player" : trimmed,
            avatar: avatar,
            controllerKind: profile.controllerKind)
    }
}

// MARK: - Observable store the UI binds to

/// The app's live local-profile store: loads on init, persists on every change (R-SESS-5.2).
///
/// A thin `@Observable` wrapper over `ProfileCodec` + a `UserDefaults` (injectable for tests/previews).
/// SwiftUI views observe `profile` and call `update(...)` to edit it; the change is written back to the
/// sandbox container immediately (local-only; R-PERS-3.1). This interim store is superseded by the Phase 6
/// Persistence settings store (task 6.4).
@MainActor
@Observable
final class LocalProfileStore {
    /// The current local profile. Views read this; `update(...)` is the only mutator.
    private(set) var profile: PlayerProfile

    /// The backing store — the sandbox `UserDefaults`. Injectable so previews/tests use an isolated suite.
    private let defaults: UserDefaults

    /// Load the stored profile (or a fresh default) from `defaults` (R-SESS-5.2).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: ProfileCodec.defaultsKey)
        self.profile = ProfileCodec.loadOrDefault(from: data)
    }

    /// Edit the local profile's display name and avatar, keeping its stable id, and persist immediately
    /// (R-SESS-5.1, R-SESS-5.2).
    func update(displayName: String, avatar: AvatarReference) {
        profile = ProfileCodec.applyingEdit(
            to: profile, displayName: displayName, avatar: avatar)
        if let data = ProfileCodec.encode(profile) {
            defaults.set(data, forKey: ProfileCodec.defaultsKey)
        }
    }
}
