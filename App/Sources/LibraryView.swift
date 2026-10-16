// LibraryView — the real Library home: Continue hero, family groups, filters, favorites, recently
// played, feature-flagged tiles with hover parallax (R-APP-1.1, R-APP-1.2, R-APP-1.3).
//
// NOTE ON BUILD: compiled by the Xcode project, not SwiftPM (design.md §1).
//
// This is the SwiftUI rendering of the PURE `LibraryModel` (GamesRules), which computes everything the
// home screen shows from the feature-flagged `GameCatalog` + the player's `LibraryState`. The view holds
// no library logic of its own — it reads `LibraryModel`'s accessors (`continueHero`, `familySections`,
// `favoriteEntries`, `recentlyPlayedEntries`) and renders standard SwiftUI chrome (design.md §10):
//
//   • CONTINUE HERO (R-APP-1.1) — a prominent card for the most-recently-played game in progress; tapping
//     it resumes that game (R-PERS-1.2). Hidden when nothing is resumable.
//   • FILTERS (R-APP-1.1) — family / player-count / duration, bound to the coordinator's `LibraryModel`
//     filter; a "Clear" affordance appears when any facet is active.
//   • FAMILY SECTIONS (R-APP-1.1) — visible entries grouped by family, each a grid of game tiles. Only
//     ENABLED catalog entries appear, so the disabled "euchre" entry never shows (R-APP-1.2).
//   • FAVORITES + RECENTS (R-APP-1.1) — quick rows above the family groups.
//   • TILES (R-APP-1.3, R-DS-6.1) — each tile draws its placeholder art (`TileArt`) with a subtle hover
//     parallax that is DISABLED under Reduce Motion (R-APP-1.3). A favorite toggle sits on each tile.
//
// Tapping a tile opens the setup sheet (R-APP-2.1) via the coordinator; the Continue hero resumes.

import GamesUI  // LibraryModel, GameCatalog, CatalogEntry, TileArt, FamilySection, GameFamily
import SwiftUI

// MARK: - Library home

/// The Library home screen (R-APP-1.1). Renders the pure `LibraryModel` and routes tile taps / the
/// Continue hero through the window's `LibraryNavigation` coordinator.
struct LibraryView: View {
    /// The window's navigation + deal coordinator (catalog, library state, deal/resume routing).
    @Bindable var navigation: LibraryNavigation

    /// The active filter, bound to the filter controls; recomputed into the `LibraryModel` on change.
    @State private var filter = LibraryFilter.none

    /// The composed pure Library model for the current catalog + persisted state + active filter.
    private var model: LibraryModel {
        LibraryModel(
            catalog: navigation.catalog,
            state: navigation.libraryState.state,
            filter: filter)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let hero = model.continueHero {
                    continueHero(hero)
                }
                filterBar
                if !model.favoriteEntries.isEmpty {
                    entryRow(
                        title: "Favorites", systemImage: "star.fill", entries: model.favoriteEntries
                    )
                }
                if !model.recentlyPlayedEntries.isEmpty {
                    entryRow(
                        title: "Recently Played", systemImage: "clock.arrow.circlepath",
                        entries: model.recentlyPlayedEntries)
                }
                ForEach(model.familySections) { section in
                    familySection(section)
                }
                if model.familySections.isEmpty {
                    ContentUnavailableView(
                        "No games match", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try clearing the filters to see all games.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Parlor")
        // A stable identifier so the accessibility UI suite can confirm it reached the library (task 7.4).
        .accessibilityIdentifier("library.home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await navigation.replayLastGame() }
                } label: {
                    Label("Replay Last Game", systemImage: "arrow.counterclockwise.circle")
                }
                .help("Reopen your most recent game")
                .accessibilityIdentifier("library.replayLast")
            }
        }
        // A calm, non-modal note when a game's table isn't wired yet, or a save couldn't be resumed.
        .alert(
            "Heads up",
            isPresented: Binding(
                get: { navigation.unsupportedTableMessage != nil },
                set: { if !$0 { navigation.unsupportedTableMessage = nil } })
        ) {
            Button("OK", role: .cancel) { navigation.unsupportedTableMessage = nil }
        } message: {
            Text(navigation.unsupportedTableMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Parlor")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Choose a game to deal a new table.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Continue hero (R-APP-1.1)

    /// The prominent "Continue" card for the most recently played in-progress game (R-APP-1.1). Tapping it
    /// resumes the game from its autosave (R-PERS-1.2).
    private func continueHero(_ entry: CatalogEntry) -> some View {
        Button {
            Task { await navigation.resume(entry) }
        } label: {
            HStack(spacing: 20) {
                TileArtView(art: entry.tileArt, prefersParallax: false)
                    .frame(width: 132, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(entry.metadata.name)
                        .font(.title2.weight(.semibold))
                    Text(gameSubtitle(entry))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Continue \(entry.metadata.name)")
        .accessibilityHint("Resumes your game in progress")
        .accessibilityIdentifier("library.continueHero")
    }

    // MARK: - Filters (R-APP-1.1)

    /// The filter bar: family, player count, and duration pickers, plus a Clear button when any facet is
    /// active (R-APP-1.1).
    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Family", selection: familyBinding) {
                Text("All families").tag(GameFamily?.none)
                ForEach(availableFamilies, id: \.rawValue) { family in
                    Text(familyName(family)).tag(GameFamily?.some(family))
                }
            }
            Picker("Players", selection: playerCountBinding) {
                Text("Any players").tag(Int?.none)
                ForEach(availablePlayerCounts, id: \.self) { count in
                    Text("\(count) player\(count == 1 ? "" : "s")").tag(Int?.some(count))
                }
            }
            Picker("Length", selection: durationBinding) {
                Text("Any length").tag(Int?.none)
                Text("≤ 15 min").tag(Int?.some(15))
                Text("≤ 30 min").tag(Int?.some(30))
                Text("≤ 60 min").tag(Int?.some(60))
            }
            if filter.isActive {
                Button("Clear") { filter = .none }
                    .buttonStyle(.borderless)
            }
            Spacer()
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("library.filters")
    }

    private var familyBinding: Binding<GameFamily?> {
        Binding(get: { filter.family }, set: { filter.family = $0 })
    }
    private var playerCountBinding: Binding<Int?> {
        Binding(get: { filter.playerCount }, set: { filter.playerCount = $0 })
    }
    private var durationBinding: Binding<Int?> {
        Binding(get: { filter.maxDurationMinutes }, set: { filter.maxDurationMinutes = $0 })
    }

    /// The families present among the visible catalog entries (so the picker only offers real choices).
    private var availableFamilies: [GameFamily] {
        var seen: [GameFamily] = []
        for entry in navigation.catalog.visibleEntries where !seen.contains(entry.metadata.family) {
            seen.append(entry.metadata.family)
        }
        return seen
    }

    /// The distinct player counts the visible games can seat (union of their seat ranges).
    private var availablePlayerCounts: [Int] {
        var counts: Set<Int> = []
        for entry in navigation.catalog.visibleEntries {
            for n in entry.metadata.seatRange { counts.insert(n) }
        }
        return counts.sorted()
    }

    // MARK: - Family section + tile rows (R-APP-1.1)

    /// One family's group of game tiles (R-APP-1.1).
    private func familySection(_ section: FamilySection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(familyName(section.family))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            tileGrid(section.entries)
        }
    }

    /// A titled horizontal row of tiles (favorites / recents).
    private func entryRow(title: String, systemImage: String, entries: [CatalogEntry]) -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            tileGrid(entries)
        }
    }

    /// A responsive grid of game tiles.
    private func tileGrid(_ entries: [CatalogEntry]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)],
            alignment: .leading, spacing: 16
        ) {
            ForEach(entries) { entry in
                GameTileView(
                    entry: entry,
                    isFavorite: model.isFavorite(entry),
                    subtitle: gameSubtitle(entry),
                    onOpen: { navigation.openSetup(for: entry) },
                    onToggleFavorite: { navigation.libraryState.toggleFavorite(entry.metadata.id) })
            }
        }
    }

    // MARK: - Presentation helpers

    /// A one-line subtitle for a tile / hero: seat range · duration · complexity.
    private func gameSubtitle(_ entry: CatalogEntry) -> String {
        let seats = entry.metadata.seatRange
        let seatText =
            seats.lowerBound == seats.upperBound
            ? "\(seats.lowerBound) player\(seats.lowerBound == 1 ? "" : "s")"
            : "\(seats.lowerBound)–\(seats.upperBound) players"
        let d = entry.metadata.typicalDuration
        let durationText = "\(d.minMinutes)–\(d.maxMinutes) min"
        return "\(seatText) · \(durationText) · \(entry.metadata.complexity.rawValue.capitalized)"
    }

    /// A friendly display name for a family id.
    private func familyName(_ family: GameFamily) -> String {
        switch family {
        case .solitaire: return "Solitaire"
        case .shedding: return "Shedding"
        case .trickTaking: return "Trick-Taking"
        case .rummy: return "Rummy"
        default:
            return family.rawValue
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}
