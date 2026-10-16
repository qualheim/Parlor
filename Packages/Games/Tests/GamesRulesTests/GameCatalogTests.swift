// Tests for the feature-flagged game catalog (R-APP-1.2, R-APP-1.3, R-DS-6.1).

import EngineCore
import Foundation
import Testing

@testable import GamesRules

@Suite("Game catalog — feature flags + tile art")
struct GameCatalogTests {
    @Test("visible entries are only the enabled ones (unbuilt games hidden) — R-APP-1.2")
    func visibleEntriesAreEnabledOnly() {
        let catalog = GameCatalog.bundled
        let visibleIDs = catalog.visibleEntries.map(\.metadata.id)

        // Both built games appear.
        #expect(visibleIDs.contains("klondike"))
        #expect(visibleIDs.contains("crazy-eights"))
        // The disabled "coming soon" game does NOT appear, even though it is registered.
        #expect(catalog.entry(id: "euchre") != nil)
        #expect(!visibleIDs.contains("euchre"))
        // Every visible entry is enabled.
        let allEnabled = catalog.visibleEntries.allSatisfy(\.enabled)
        #expect(allEnabled)
    }

    @Test("visibleEntry only resolves enabled games — R-APP-1.2")
    func visibleEntryHidesDisabled() {
        let catalog = GameCatalog.bundled
        #expect(catalog.visibleEntry(id: "klondike") != nil)
        #expect(catalog.visibleEntry(id: "euchre") == nil)  // disabled
        #expect(catalog.visibleEntry(id: "does-not-exist") == nil)
    }

    @Test("flipping a feature flag reveals a previously hidden game — R-APP-1.2")
    func flippingFlagRevealsGame() {
        // Start with a disabled entry, then register it enabled — it becomes visible with no other change.
        let meta = GameMetadata(
            id: "euchre", name: "Euchre", family: .trickTaking, seatRange: 4...4,
            typicalDuration: DurationRange(minMinutes: 15, maxMinutes: 30), complexity: .medium)
        let hidden = GameCatalog(entries: [
            CatalogEntry(
                metadata: meta, enabled: false,
                tileArt: .generatedPlaceholder(symbol: "suit.spade.fill", tint: "#5F3DC4"))
        ])
        #expect(hidden.visibleEntries.isEmpty)

        let revealed = GameCatalog(entries: [
            CatalogEntry(
                metadata: meta, enabled: true,
                tileArt: .generatedPlaceholder(symbol: "suit.spade.fill", tint: "#5F3DC4"))
        ])
        #expect(revealed.visibleEntries.map(\.metadata.id) == ["euchre"])
    }

    @Test("every bundled tile art is a placeholder flagged needs-production-art — R-DS-6.1")
    func tileArtIsPlaceholder() {
        for entry in GameCatalog.bundled.entries {
            let needsArt = entry.tileArt.needsProductionArt
            #expect(needsArt)
        }
    }

    @Test("entries prefer parallax by default (App disables under Reduce Motion) — R-APP-1.3")
    func entriesPreferParallax() {
        let allPreferParallax = GameCatalog.bundled.visibleEntries.allSatisfy(\.prefersParallax)
        #expect(allPreferParallax)
    }

    @Test("catalog entries are Codable round-trip")
    func codableRoundTrip() throws {
        let entry = GameCatalog.bundled.entry(id: "klondike")!
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(CatalogEntry.self, from: data)
        #expect(decoded == entry)
    }
}
