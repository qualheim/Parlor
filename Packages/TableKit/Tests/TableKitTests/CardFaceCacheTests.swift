import CoreGraphics
import DesignSystem
import EngineCore
import Testing

@testable import TableKit

// Tests for task 5.3 — the cache actually caches: one rasterization per key, reused on subsequent
// requests, so faces are not redrawn every frame (R-TABLE-2.1). Runs on the main actor because the cache
// drives the main-actor `ImageRenderer`.

@Suite("Card face cache", .serialized)
@MainActor
struct CardFaceCacheTests {
    private let size = CGSize(width: 80, height: 112)

    private func fetch(
        _ cache: CardFaceCache,
        face: CardFaceDescriptor,
        theme: TableTheme = .classicFelt,
        style: DeckStyle = .classic,
        appearance: CardAppearance = .standard
    ) {
        let key = CardFaceKey(
            themeID: theme.id, deckStyleID: style.id, face: face,
            scaleBucket: CardFaceKey.scaleBucket(forPixelSize: 160), appearance: appearance)
        _ = cache.image(
            for: key, style: style, back: .default, theme: theme, size: size, displayScale: 2)
    }

    @Test("the same key rasterizes once and is a hit thereafter")
    func cachesByKey() {
        let cache = CardFaceCache()
        fetch(cache, face: .spot(rank: 5, suit: .hearts))
        #expect(cache.count == 1)
        #expect(cache.missCount == 1)
        #expect(cache.hitCount == 0)

        // Same key again → a hit, no new rasterization.
        fetch(cache, face: .spot(rank: 5, suit: .hearts))
        #expect(cache.count == 1)
        #expect(cache.missCount == 1)
        #expect(cache.hitCount == 1)
    }

    @Test("distinct faces, themes, styles, and appearances cache separately")
    func distinctKeysDistinctImages() {
        let cache = CardFaceCache()
        fetch(cache, face: .spot(rank: 5, suit: .hearts))
        fetch(cache, face: .court(rank: .queen, suit: .spades))
        fetch(cache, face: .back(backID: CardBack.default.id))
        fetch(cache, face: .spot(rank: 5, suit: .hearts), theme: .midnight)
        fetch(cache, face: .spot(rank: 5, suit: .hearts), style: .fourColor)
        fetch(cache, face: .spot(rank: 5, suit: .hearts), appearance: .highContrast)
        #expect(cache.count == 6)
        #expect(cache.missCount == 6)
        #expect(cache.hitCount == 0)
    }

    @Test("clear drops the cache so keys re-rasterize")
    func clearResets() {
        let cache = CardFaceCache()
        fetch(cache, face: .spot(rank: 5, suit: .hearts))
        #expect(cache.count == 1)
        cache.clear()
        #expect(cache.count == 0)
        #expect(cache.missCount == 0)
        fetch(cache, face: .spot(rank: 5, suit: .hearts))
        #expect(cache.missCount == 1)
    }
}

// MARK: - CardPresentation defaults (R-TABLE-2.2)

@Suite("Card presentation state")
struct CardPresentationTests {
    @Test("a plain card is resting, face-up, and not selected/highlighted/dimmed")
    func defaults() {
        let p = CardPresentation()
        #expect(p.faceUp)
        #expect(p.lift == 0)
        #expect(!p.isSelected)
        #expect(!p.isLegalTarget)
        #expect(!p.isDimmed)
    }

    @Test("presentation flags are independently settable")
    func flags() {
        let p = CardPresentation(
            faceUp: false, lift: 12, isSelected: true, isLegalTarget: true, isDimmed: true)
        #expect(!p.faceUp)
        #expect(p.lift == 12)
        #expect(p.isSelected)
        #expect(p.isLegalTarget)
        #expect(p.isDimmed)
    }
}
