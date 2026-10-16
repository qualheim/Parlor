import DesignSystem
import EngineCore
import Foundation
import Testing

@testable import TableKit

// Tests for task 5.3 — the cached-vector card-face KEY and its derivation from an EngineCore face
// (R-TABLE-2.1). These are pure value-level tests: they prove that (theme, face, scale, appearance) is
// captured correctly and that equal inputs produce equal keys (so the cache reuses one image), while any
// differing dimension produces a distinct key (so a variant caches separately, not repaints).

@Suite("Card face descriptor bridge")
struct CardFaceDescriptorTests {
    @Test("spot cards (ace..ten) map to .spot with the mirrored suit")
    func spotCards() {
        #expect(CardFaceDescriptor(.standard(.ace, .spades)) == .spot(rank: 1, suit: .spades))
        #expect(CardFaceDescriptor(.standard(.ten, .hearts)) == .spot(rank: 10, suit: .hearts))
        #expect(CardFaceDescriptor(.standard(.seven, .diamonds)) == .spot(rank: 7, suit: .diamonds))
    }

    @Test("court cards map to .court with the right court rank")
    func courtCards() {
        #expect(CardFaceDescriptor(.standard(.jack, .clubs)) == .court(rank: .jack, suit: .clubs))
        #expect(
            CardFaceDescriptor(.standard(.queen, .spades)) == .court(rank: .queen, suit: .spades))
        #expect(CardFaceDescriptor(.standard(.king, .hearts)) == .court(rank: .king, suit: .hearts))
    }

    @Test("jokers map to .joker preserving the index")
    func jokers() {
        #expect(CardFaceDescriptor(.joker(index: 0)) == .joker(index: 0))
        #expect(CardFaceDescriptor(.joker(index: 1)) == .joker(index: 1))
        #expect(CardFaceDescriptor(.joker(index: 0)) != CardFaceDescriptor(.joker(index: 1)))
    }

    @Test("EngineCore.Suit bridges to the styling DeckSuit by name")
    func suitBridge() {
        #expect(DeckSuit(Suit.clubs) == .clubs)
        #expect(DeckSuit(Suit.diamonds) == .diamonds)
        #expect(DeckSuit(Suit.hearts) == .hearts)
        #expect(DeckSuit(Suit.spades) == .spades)
    }
}

@Suite("Card face cache key")
struct CardFaceKeyTests {
    private func key(
        theme: String = "classic-felt",
        deck: String = "classic",
        face: CardFaceDescriptor = .spot(rank: 5, suit: .hearts),
        scale: Int = 10,
        appearance: CardAppearance = .standard
    ) -> CardFaceKey {
        CardFaceKey(
            themeID: theme, deckStyleID: deck, face: face, scaleBucket: scale,
            appearance: appearance)
    }

    @Test("identical inputs produce equal keys (one cached image is reused)")
    func equalInputsEqualKeys() {
        #expect(key() == key())
    }

    @Test("each of the four dimensions distinguishes the key")
    func dimensionsDistinguish() {
        let base = key()
        #expect(base != key(theme: "midnight"))
        #expect(base != key(deck: "four-color"))
        #expect(base != key(face: .spot(rank: 6, suit: .hearts)))
        #expect(base != key(face: .spot(rank: 5, suit: .spades)))
        #expect(base != key(scale: 11))
        #expect(base != key(appearance: .highContrast))
    }

    @Test("face-up vs face-down are different faces in the key")
    func faceUpVsBack() {
        let up = CardFaceDescriptor(.standard(.king, .hearts))
        let down = CardFaceDescriptor.back(.default)
        #expect(up != down)
    }

    @Test("scale bucketing quantizes nearby sizes to one key but separates distant ones")
    func scaleBucketing() {
        // Two nearby pixel sizes fall in the same bucket → same cached image.
        let a = CardFaceKey.scaleBucket(forPixelSize: 120, step: 8)
        let b = CardFaceKey.scaleBucket(forPixelSize: 123, step: 8)
        #expect(a == b)
        // A clearly larger size falls in a different bucket → distinct cached image.
        let c = CardFaceKey.scaleBucket(forPixelSize: 200, step: 8)
        #expect(a != c)
        // Non-negative and stable at zero.
        #expect(CardFaceKey.scaleBucket(forPixelSize: -5) == 0)
    }

    @Test("keys round-trip through Codable")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let k = key(face: .court(rank: .queen, suit: .diamonds), appearance: .highContrast)
        let data = try encoder.encode(k)
        #expect(try decoder.decode(CardFaceKey.self, from: data) == k)
    }
}
