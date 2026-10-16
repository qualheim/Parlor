// Tests for the pure Library view-model (R-APP-1.1, R-APP-1.2).

import EngineCore
import Testing

@testable import GamesRules

@Suite("Library model — grouping, filters, continue, favorites, recents")
struct LibraryModelTests {
    private var catalog: GameCatalog { .bundled }

    // MARK: - Family grouping (R-APP-1.1)

    @Test("tiles group by family, only visible games — R-APP-1.1, R-APP-1.2")
    func familyGrouping() {
        let model = LibraryModel(catalog: catalog)
        let families = model.familySections.map(\.family)
        // Klondike (solitaire) and Crazy Eights (shedding) each form a section; euchre is hidden.
        #expect(families.contains(.solitaire))
        #expect(families.contains(.shedding))
        #expect(!families.contains(.trickTaking))  // euchre is disabled

        let allEntries = model.familySections.flatMap(\.entries).map(\.metadata.id)
        #expect(!allEntries.contains("euchre"))
    }

    // MARK: - Filters (R-APP-1.1)

    @Test("family filter keeps only that family — R-APP-1.1")
    func familyFilter() {
        let model = LibraryModel(catalog: catalog, filter: LibraryFilter(family: .solitaire))
        let ids = model.filteredEntries.map(\.metadata.id)
        #expect(ids == ["klondike"])
    }

    @Test("player-count filter keeps games that seat that many — R-APP-1.1")
    func playerCountFilter() {
        // 3 players: Crazy Eights seats 2...5 (yes), Klondike seats 1...1 (no).
        let three = LibraryModel(catalog: catalog, filter: LibraryFilter(playerCount: 3))
        #expect(three.filteredEntries.map(\.metadata.id) == ["crazy-eights"])

        // 1 player: only Klondike.
        let one = LibraryModel(catalog: catalog, filter: LibraryFilter(playerCount: 1))
        #expect(one.filteredEntries.map(\.metadata.id) == ["klondike"])
    }

    @Test("duration filter keeps games within the max — R-APP-1.1")
    func durationFilter() {
        // Klondike typical 5...15, Crazy Eights 5...20. Max 15 keeps only Klondike.
        let model = LibraryModel(catalog: catalog, filter: LibraryFilter(maxDurationMinutes: 15))
        #expect(model.filteredEntries.map(\.metadata.id) == ["klondike"])
    }

    @Test("empty filter passes everything visible")
    func emptyFilterPassesAll() {
        let model = LibraryModel(catalog: catalog)
        #expect(model.filteredEntries.count == catalog.visibleEntries.count)
        #expect(!LibraryFilter.none.isActive)
        #expect(LibraryFilter(family: .solitaire).isActive)
    }

    // MARK: - Continue hero (R-APP-1.1)

    @Test("continue hero surfaces the in-progress game, most-recent first — R-APP-1.1")
    func continueHero() {
        let state = LibraryState(
            recentlyPlayedGameIDs: ["crazy-eights", "klondike"],
            inProgressGameIDs: ["klondike", "crazy-eights"])
        let model = LibraryModel(catalog: catalog, state: state)
        // Both are in progress; crazy-eights is more recent, so it is the hero.
        #expect(model.continueHero?.metadata.id == "crazy-eights")
        #expect(model.continueEntries.map(\.metadata.id) == ["crazy-eights", "klondike"])
    }

    @Test("no continue hero when nothing is in progress — R-APP-1.1")
    func noContinueHero() {
        let model = LibraryModel(catalog: catalog, state: .empty)
        #expect(model.continueHero == nil)
        #expect(model.continueEntries.isEmpty)
    }

    @Test("continue hero never points at a hidden game — R-APP-1.2")
    func continueHeroIgnoresHiddenGames() {
        // A stale in-progress id for the disabled game must not surface.
        let state = LibraryState(inProgressGameIDs: ["euchre"])
        let model = LibraryModel(catalog: catalog, state: state)
        #expect(model.continueHero == nil)
    }

    // MARK: - Favorites (R-APP-1.1)

    @Test("favorites list only visible favorited games — R-APP-1.1")
    func favorites() {
        let state = LibraryState(favoriteGameIDs: ["klondike", "euchre"])
        let model = LibraryModel(catalog: catalog, state: state)
        // euchre is hidden, so only klondike shows as a favorite.
        #expect(model.favoriteEntries.map(\.metadata.id) == ["klondike"])
        #expect(model.isFavorite(catalog.entry(id: "klondike")!))
    }

    @Test("toggling a favorite adds then removes it")
    func toggleFavorite() {
        let s0 = LibraryState.empty
        let s1 = s0.togglingFavorite("klondike")
        #expect(s1.favoriteGameIDs.contains("klondike"))
        let s2 = s1.togglingFavorite("klondike")
        #expect(!s2.favoriteGameIDs.contains("klondike"))
    }

    // MARK: - Recently played (R-APP-1.1)

    @Test("recently played preserves order and hides invisible games — R-APP-1.1, R-APP-1.2")
    func recentlyPlayed() {
        let state = LibraryState(
            recentlyPlayedGameIDs: ["crazy-eights", "euchre", "klondike"])
        let model = LibraryModel(catalog: catalog, state: state)
        // euchre is dropped; order is preserved.
        #expect(model.recentlyPlayedEntries.map(\.metadata.id) == ["crazy-eights", "klondike"])
    }

    @Test("recording a play moves it to front, dedups, and bounds the list")
    func recordingPlayed() {
        var state = LibraryState(recentlyPlayedGameIDs: ["klondike", "crazy-eights"])
        state = state.recordingPlayed("crazy-eights")
        #expect(state.recentlyPlayedGameIDs == ["crazy-eights", "klondike"])

        // Bound: recording many distinct ids keeps at most `limit`.
        var bounded = LibraryState.empty
        for i in 0..<20 { bounded = bounded.recordingPlayed("game-\(i)", limit: 5) }
        #expect(bounded.recentlyPlayedGameIDs.count == 5)
        #expect(bounded.recentlyPlayedGameIDs.first == "game-19")
    }

    // MARK: - Property-style invariants over arbitrary state

    @Test("no accessor ever surfaces a disabled game — R-APP-1.2")
    func disabledNeverSurfaces() {
        // Exhaustively drive every id (visible and hidden) through every list.
        let allIDs = catalog.entries.map(\.metadata.id)
        let state = LibraryState(
            favoriteGameIDs: Set(allIDs),
            recentlyPlayedGameIDs: allIDs,
            inProgressGameIDs: Set(allIDs))
        let model = LibraryModel(catalog: catalog, state: state)

        let disabledIDs = Set(catalog.entries.filter { !$0.enabled }.map(\.metadata.id))
        func none(_ entries: [CatalogEntry]) -> Bool {
            entries.allSatisfy { !disabledIDs.contains($0.metadata.id) }
        }
        #expect(none(model.filteredEntries))
        #expect(none(model.favoriteEntries))
        #expect(none(model.recentlyPlayedEntries))
        #expect(none(model.continueEntries))
        #expect(none(model.familySections.flatMap(\.entries)))
    }
}
