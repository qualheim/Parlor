// LibraryStateStore — the app's persisted Library player-state: favorites + recently played, plus the
// live in-progress set sourced from the save store (R-APP-1.1, R-PERS-3.1).
//
// NOTE ON BUILD: compiled by the Xcode project, not SwiftPM (design.md §1).
//
// The pure Library logic (grouping, filtering, the Continue hero, favorites, recents) lives in
// `LibraryModel` (GamesRules) and computes everything from a `GameCatalog` + a `LibraryState` value. This
// store is the App's thin persistence + observation wrapper around that `LibraryState`:
//
//   • FAVORITES + RECENTS are the player's choices; they persist across launches. Interim persistence is
//     one JSON blob under a single UserDefaults key in the sandbox container — local-only, no cloud
//     (R-PERS-3.1) — mirroring `ProfileStore`. Only the two mutable facets are stored; the in-progress
//     set is NOT stored here because it is derived from the saves on disk.
//   • IN-PROGRESS games are sourced live from `SaveStore.allSaveIDs()` (SaveStore.swift): a game has a
//     "Continue" candidate exactly when an autosave slot exists for its id (R-APP-1.1). `refreshInProgress`
//     re-reads the store, so the hero reflects reality after a deal, a resume, or a quit-to-library.
//
// The `@Observable` store hands the SwiftUI Library a ready `LibraryState`; the Library composes it with
// the bundled catalog + the active filter into a `LibraryModel` for rendering.

import Foundation
import GamesUI  // re-exports GamesRules: LibraryState
import Observation
import Persistence  // SaveStore, SandboxSaveStore, SaveID

// MARK: - Pure codec (unit-testable)

/// Pure encode/decode for the persisted Library facets (favorites + recents). Kept free of `UserDefaults`
/// so the logic is verifiable and reused by the `@Observable` store. Only the two mutable facets round-trip
/// through storage; `inProgressGameIDs` is derived from the save store, never persisted here.
enum LibraryStateCodec {
    /// The UserDefaults key the interim Library state is stored under.
    static let defaultsKey = "com.parlor.libraryState.v1"

    /// The two persisted facets — favorites and recents — as a small Codable blob. `inProgressGameIDs` is
    /// deliberately excluded (it is sourced from the save store at load time).
    struct Persisted: Codable, Sendable, Equatable {
        var favoriteGameIDs: [String]
        var recentlyPlayedGameIDs: [String]
    }

    /// Encode the persistable facets of `state` to JSON. Sorted keys keep the blob stable across writes.
    static func encode(_ state: LibraryState) -> Data? {
        let persisted = Persisted(
            favoriteGameIDs: state.favoriteGameIDs.sorted(),
            recentlyPlayedGameIDs: state.recentlyPlayedGameIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(persisted)
    }

    /// Decode the persisted facets, returning empty when absent or unreadable (a corrupt blob is treated
    /// as "no saved state" so the caller falls back to empty — never a crash, R-PERS-2.2 in spirit).
    static func decodePersisted(_ data: Data?) -> Persisted {
        guard let data, let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return Persisted(favoriteGameIDs: [], recentlyPlayedGameIDs: [])
        }
        return persisted
    }

    /// Fold the persisted facets + the live in-progress ids into a full `LibraryState`.
    static func state(persisted: Persisted, inProgress: Set<String>) -> LibraryState {
        LibraryState(
            favoriteGameIDs: Set(persisted.favoriteGameIDs),
            recentlyPlayedGameIDs: persisted.recentlyPlayedGameIDs,
            inProgressGameIDs: inProgress)
    }
}

// MARK: - Observable store the Library binds to

/// The app's live Library-state store: loads favorites/recents on init, sources in-progress from the save
/// store, and persists the mutable facets on every change (R-APP-1.1, R-PERS-3.1).
///
/// A thin `@Observable` wrapper over `LibraryStateCodec` + a `UserDefaults` (injectable for previews/tests)
/// + a `SaveStore` (the sandbox store in production). SwiftUI reads `state` and calls the mutators; each
/// change writes the two persistable facets back to the container immediately.
@MainActor
@Observable
final class LibraryStateStore {
    /// The current Library state — favorites, recents, and the derived in-progress set. Views read this.
    private(set) var state: LibraryState

    /// The backing defaults — the sandbox `UserDefaults`. Injectable so previews/tests use an isolated suite.
    private let defaults: UserDefaults

    /// The save store the in-progress set is sourced from (R-APP-1.1). The sandbox store in production.
    private let saveStore: (any SaveStore)?

    /// Load the persisted facets (or empty) and the live in-progress set from `saveStore`.
    init(defaults: UserDefaults = .standard, saveStore: (any SaveStore)? = nil) {
        self.defaults = defaults
        // Default to the sandbox save store; degrade to no store (empty in-progress) if it can't be made.
        let store = saveStore ?? (try? SandboxSaveStore())
        self.saveStore = store
        let persisted = LibraryStateCodec.decodePersisted(
            defaults.data(forKey: LibraryStateCodec.defaultsKey))
        self.state = LibraryStateCodec.state(
            persisted: persisted, inProgress: LibraryStateStore.inProgressIDs(from: store))
    }

    /// The set of game ids that currently have an autosave slot — the "Continue" candidates (R-APP-1.1).
    private static func inProgressIDs(from store: (any SaveStore)?) -> Set<String> {
        guard let store, let ids = try? store.allSaveIDs() else { return [] }
        return Set(ids.map(\.raw))
    }

    /// Re-read the in-progress set from the save store — call after a deal, resume, or quit-to-library so
    /// the Continue hero reflects the saves on disk (R-APP-1.1).
    func refreshInProgress() {
        state.inProgressGameIDs = LibraryStateStore.inProgressIDs(from: saveStore)
    }

    /// Toggle whether `gameID` is a favorite and persist (R-APP-1.1).
    func toggleFavorite(_ gameID: String) {
        state = state.togglingFavorite(gameID)
        persist()
    }

    /// Record that `gameID` was just played (move it to the front of recents) and persist (R-APP-1.1).
    func recordPlayed(_ gameID: String) {
        state = state.recordingPlayed(gameID)
        persist()
    }

    /// Write the two persistable facets back to the sandbox container (R-PERS-3.1).
    private func persist() {
        if let data = LibraryStateCodec.encode(state) {
            defaults.set(data, forKey: LibraryStateCodec.defaultsKey)
        }
    }
}
