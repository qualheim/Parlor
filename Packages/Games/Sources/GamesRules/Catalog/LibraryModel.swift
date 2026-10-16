// The Library view-model — pure logic that turns the catalog + player state into what the home screen
// shows (R-APP-1.1).
//
// The Library home shows: a "Continue" hero for games in progress, game tiles grouped by family, filters
// (family / player count / duration), favorites, and recently played (R-APP-1.1). All of that is pure
// computation over (a) the feature-flagged `GameCatalog` (only visible entries, R-APP-1.2) and (b) a
// small `LibraryState` value carrying the player's favorites, recently-played order, and in-progress
// games. Keeping it in the pure layer (GamesRules) makes every rule — grouping, filtering, hero
// selection — unit-testable headless; the App persists `LibraryState` (favorites/recents via the
// settings/store layer, in-progress from `SaveStore.allSaveIDs`) and renders thin SwiftUI on top
// (design.md §10).

import EngineCore
import Foundation

// MARK: - Library filters (R-APP-1.1)

/// The Library's filter selection: family, player count, and duration (R-APP-1.1).
///
/// Each facet is optional — `nil` means "don't filter on this facet". A `family` keeps only games in that
/// family; a `playerCount` keeps only games whose `seatRange` can seat exactly that many; a
/// `maxDurationMinutes` keeps only games whose typical play fits within that many minutes. Pure value so
/// the App can bind it to filter controls and hand it back for recomputation.
public struct LibraryFilter: Hashable, Sendable {
    /// Keep only games in this family, or `nil` for all families (R-APP-1.1).
    public var family: GameFamily?
    /// Keep only games that can seat exactly this many players, or `nil` for any count (R-APP-1.1).
    public var playerCount: Int?
    /// Keep only games whose typical play fits within this many minutes, or `nil` for any duration
    /// (R-APP-1.1). Compared against `typicalDuration.maxMinutes`.
    public var maxDurationMinutes: Int?

    public init(
        family: GameFamily? = nil,
        playerCount: Int? = nil,
        maxDurationMinutes: Int? = nil
    ) {
        self.family = family
        self.playerCount = playerCount
        self.maxDurationMinutes = maxDurationMinutes
    }

    /// The empty filter — everything passes.
    public static var none: LibraryFilter { LibraryFilter() }

    /// Whether any facet is active (drives a "clear filters" affordance in the App).
    public var isActive: Bool {
        family != nil || playerCount != nil || maxDurationMinutes != nil
    }

    /// Whether `entry` passes every active facet of this filter.
    func matches(_ entry: CatalogEntry) -> Bool {
        if let family, entry.metadata.family != family { return false }
        if let playerCount, !entry.metadata.seatRange.contains(playerCount) { return false }
        if let maxDurationMinutes, entry.metadata.typicalDuration.maxMinutes > maxDurationMinutes {
            return false
        }
        return true
    }
}

// MARK: - Library state (what the App persists)

/// The player-specific state the Library layers over the catalog (R-APP-1.1).
///
/// Pure data the App owns and persists: which games are favorited, the recently-played order (most recent
/// first), and which games have a save in progress. The App sources `inProgressGameIDs` from
/// `SaveStore.allSaveIDs()` (SaveStore.swift) and persists `favoriteGameIDs` / `recentlyPlayedGameIDs`
/// via the settings/store layer. Modeled as ids (not entries) so it round-trips independently of the
/// catalog and tolerates a game being disabled or removed — the view-model intersects with the visible
/// catalog when it builds sections.
public struct LibraryState: Hashable, Codable, Sendable {
    /// The game ids the player has favorited (R-APP-1.1).
    public var favoriteGameIDs: Set<String>
    /// Recently-played game ids, MOST RECENT FIRST (R-APP-1.1).
    public var recentlyPlayedGameIDs: [String]
    /// Game ids with a save in progress — the "Continue" hero candidates (R-APP-1.1). Sourced from
    /// `SaveStore.allSaveIDs()` by the App.
    public var inProgressGameIDs: Set<String>

    public init(
        favoriteGameIDs: Set<String> = [],
        recentlyPlayedGameIDs: [String] = [],
        inProgressGameIDs: Set<String> = []
    ) {
        self.favoriteGameIDs = favoriteGameIDs
        self.recentlyPlayedGameIDs = recentlyPlayedGameIDs
        self.inProgressGameIDs = inProgressGameIDs
    }

    /// The empty state — no favorites, recents, or games in progress.
    public static var empty: LibraryState { LibraryState() }

    /// Toggle whether `gameID` is a favorite, returning the updated state (App persists the result).
    public func togglingFavorite(_ gameID: String) -> LibraryState {
        var copy = self
        if copy.favoriteGameIDs.contains(gameID) {
            copy.favoriteGameIDs.remove(gameID)
        } else {
            copy.favoriteGameIDs.insert(gameID)
        }
        return copy
    }

    /// Record that `gameID` was just played: move it to the front of the recents (dedup), returning the
    /// updated state. Keeps at most `limit` entries so the recents list stays bounded.
    public func recordingPlayed(_ gameID: String, limit: Int = 12) -> LibraryState {
        var copy = self
        copy.recentlyPlayedGameIDs.removeAll { $0 == gameID }
        copy.recentlyPlayedGameIDs.insert(gameID, at: 0)
        if copy.recentlyPlayedGameIDs.count > limit {
            copy.recentlyPlayedGameIDs = Array(copy.recentlyPlayedGameIDs.prefix(limit))
        }
        return copy
    }
}

// MARK: - Family section (grouped tiles)

/// A group of games in one family — the "tiles grouped by family" the Library shows (R-APP-1.1).
public struct FamilySection: Hashable, Sendable, Identifiable {
    /// The family these entries belong to.
    public let family: GameFamily
    /// The visible entries in this family, in display order (by name).
    public let entries: [CatalogEntry]

    /// Identify a section by its family id.
    public var id: String { family.rawValue }

    public init(family: GameFamily, entries: [CatalogEntry]) {
        self.family = family
        self.entries = entries
    }
}

// MARK: - LibraryModel (R-APP-1.1)

/// The pure Library view-model: computes everything the home screen shows from the catalog + player state
/// (R-APP-1.1).
///
/// Constructed from a feature-flagged `GameCatalog` and the player's `LibraryState`. Every accessor works
/// only over the catalog's VISIBLE (enabled) entries (R-APP-1.2), so an unbuilt game can never appear in
/// a section, a hero, favorites, or recents even if a stale id lingers in `LibraryState`. All computation
/// is deterministic and side-effect free, so the App can rebuild it whenever the catalog, state, or
/// filter changes.
public struct LibraryModel: Sendable {
    /// The catalog backing the Library.
    public let catalog: GameCatalog
    /// The player's favorites / recents / in-progress state.
    public let state: LibraryState
    /// The active filter (family / player count / duration).
    public let filter: LibraryFilter

    public init(
        catalog: GameCatalog,
        state: LibraryState = .empty,
        filter: LibraryFilter = .none
    ) {
        self.catalog = catalog
        self.state = state
        self.filter = filter
    }

    /// Return a copy with a different `filter` (the App swaps this as the player edits filter controls).
    public func applying(_ filter: LibraryFilter) -> LibraryModel {
        LibraryModel(catalog: catalog, state: state, filter: filter)
    }

    /// The visible entries that pass the active filter, sorted by display name — the flat, filtered set
    /// every grouped/favorite/recent accessor derives from (R-APP-1.1, R-APP-1.2).
    public var filteredEntries: [CatalogEntry] {
        catalog.visibleEntries
            .filter { filter.matches($0) }
            .sorted { $0.metadata.name < $1.metadata.name }
    }

    /// The filtered entries grouped by family, one `FamilySection` per family (R-APP-1.1).
    ///
    /// Families are ordered by their first-appearing entry's name so ordering is stable and
    /// content-driven; entries within a family are sorted by name. Empty families are omitted.
    public var familySections: [FamilySection] {
        var order: [GameFamily] = []
        var buckets: [GameFamily: [CatalogEntry]] = [:]
        for entry in filteredEntries {
            let family = entry.metadata.family
            if buckets[family] == nil { order.append(family) }
            buckets[family, default: []].append(entry)
        }
        return order.map { FamilySection(family: $0, entries: buckets[$0] ?? []) }
    }

    /// The "Continue" hero candidates: visible games with a save in progress (R-APP-1.1).
    ///
    /// Ordered by recents (a game played more recently sorts first); in-progress games not in the recents
    /// list follow, by name. Respects the active filter and the catalog's visibility, so a hero never
    /// points at an unbuilt or filtered-out game (R-APP-1.2).
    public var continueEntries: [CatalogEntry] {
        let inProgress = filteredEntries.filter { state.inProgressGameIDs.contains($0.metadata.id) }
        return inProgress.sorted { lhs, rhs in
            let li = recentIndex(lhs.metadata.id)
            let ri = recentIndex(rhs.metadata.id)
            if li != ri { return li < ri }
            return lhs.metadata.name < rhs.metadata.name
        }
    }

    /// The single primary "Continue" hero — the most recently played game in progress, or `nil` when
    /// nothing is resumable (R-APP-1.1). The App features this; `continueEntries` lists the rest.
    public var continueHero: CatalogEntry? {
        continueEntries.first
    }

    /// The favorited games, among the visible + filtered entries, sorted by name (R-APP-1.1).
    public var favoriteEntries: [CatalogEntry] {
        filteredEntries.filter { state.favoriteGameIDs.contains($0.metadata.id) }
    }

    /// The recently-played games, MOST RECENT FIRST, among the visible + filtered entries (R-APP-1.1).
    ///
    /// Preserves the `recentlyPlayedGameIDs` order and drops any id that is not a visible, filter-passing
    /// entry (an unbuilt/removed/filtered game), so recents can never surface a hidden game (R-APP-1.2).
    public var recentlyPlayedEntries: [CatalogEntry] {
        let byID = Dictionary(uniqueKeysWithValues: filteredEntries.map { ($0.metadata.id, $0) })
        return state.recentlyPlayedGameIDs.compactMap { byID[$0] }
    }

    /// Whether `entry` is currently favorited.
    public func isFavorite(_ entry: CatalogEntry) -> Bool {
        state.favoriteGameIDs.contains(entry.metadata.id)
    }

    /// The index of `gameID` in the recents list (most-recent = 0), or `Int.max` when absent — used to
    /// order continue candidates by recency.
    private func recentIndex(_ gameID: String) -> Int {
        state.recentlyPlayedGameIDs.firstIndex(of: gameID) ?? Int.max
    }
}
