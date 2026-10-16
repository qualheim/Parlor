import Foundation
import Testing

@testable import DesignSystem

/// Tests for the event-driven sound engine: the cue vocabulary, the no-repeat variation selector, the
/// volume/mute/background mixing policy, and the engine's selection + playback wiring (R-DS-5.1, R-DS-5.2).
///
/// The engine is split into a pure value layer (verifiable headless here) and a thin AVFoundation shell
/// (exercised through a spy `AudioPlayer`), so every rule below is checked without an audio device.
@MainActor
@Suite("Sound engine")
struct SoundEngineTests {
    // MARK: - Fixtures

    /// A small, fully deterministic RNG so variation selection is reproducible in tests (a plain LCG).
    struct DeterministicRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// A spy player that records every `play`/`stopAll` call so tests can assert on gains and files.
    final class SpyPlayer: AudioPlayer {
        struct Play: Equatable {
            let url: URL
            let gain: Double
        }
        private(set) var plays: [Play] = []
        private(set) var stopAllCount = 0
        func play(_ url: URL, gain: Double) { plays.append(Play(url: url, gain: gain)) }
        func stopAll() { stopAllCount += 1 }
    }

    /// Build variation URLs `cue_0.caf ... cue_(n-1).caf` for a cue with `count` variations.
    static func urls(for cue: SoundCue, count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/tmp/\(cue.rawValue)_\($0).caf") }
    }

    // MARK: - Cue vocabulary (R-DS-5.1)

    @Test("the six required cues exist and are all effects")
    func cueVocabulary() {
        #expect(Set(SoundCue.allCases) == [.shuffle, .deal, .flip, .place, .chips, .win])
        #expect(SoundCue.allCases.allSatisfy { $0.category == .effects })
        #expect(DesignSystem.soundCues == SoundCue.allCases)
    }

    @Test("each cue reads from a manifest key matching its raw value")
    func manifestKeys() {
        for cue in SoundCue.allCases {
            #expect(cue.manifestKey == cue.rawValue)
        }
    }

    // MARK: - Mix: volume / mute / background (R-DS-5.1)

    @Test("levels are clamped into 0...1 and NaN normalizes to 0")
    func mixClamps() {
        var mix = SoundMix()
        mix.setLevel(2.0, for: .effects)
        #expect(mix.level(for: .effects) == 1)
        mix.setLevel(-1.0, for: .effects)
        #expect(mix.level(for: .effects) == 0)
        mix.setLevel(.nan, for: .ambience)
        #expect(mix.level(for: .ambience) == 0)
    }

    @Test("effective gain is the category level when audible")
    func gainWhenAudible() {
        let mix = SoundMix(effectsLevel: 0.7, ambienceLevel: 0.3)
        #expect(mix.effectiveGain(for: .effects) == 0.7)
        #expect(mix.effectiveGain(for: .ambience) == 0.3)
        #expect(mix.effectiveGain(for: .deal) == 0.7)  // deal is an effect
    }

    @Test("master mute silences every category (R-DS-5.1)")
    func masterMuteSilences() {
        var mix = SoundMix(effectsLevel: 1.0, ambienceLevel: 1.0)
        mix.isMuted = true
        #expect(!mix.isAudible)
        #expect(mix.effectiveGain(for: .effects) == 0)
        #expect(mix.effectiveGain(for: .ambience) == 0)
    }

    @Test("background state silences every category (mute-when-in-background — R-DS-5.1)")
    func backgroundSilences() {
        var mix = SoundMix(effectsLevel: 1.0, ambienceLevel: 1.0)
        mix.isInBackground = true
        #expect(!mix.isAudible)
        #expect(mix.effectiveGain(for: .effects) == 0)
        #expect(mix.effectiveGain(for: .ambience) == 0)
    }

    @Test("categories are independent — muting one via level does not affect the other")
    func categoriesIndependent() {
        var mix = SoundMix(effectsLevel: 1.0, ambienceLevel: 1.0)
        mix.setLevel(0, for: .effects)
        #expect(mix.effectiveGain(for: .effects) == 0)
        #expect(mix.effectiveGain(for: .ambience) == 1.0)
    }

    // MARK: - No-repeat variation selector (R-DS-5.1)

    @Test("with one variation the index is 0 (nothing to vary)")
    func singleVariationRepeats() {
        var selector = VariationSelector()
        var rng = DeterministicRNG(seed: 1)
        for _ in 0..<5 {
            #expect(selector.next(forCueWith: 1, cue: .deal, using: &rng) == 0)
        }
    }

    @Test("with zero variations nothing is selected")
    func zeroVariations() {
        var selector = VariationSelector()
        var rng = DeterministicRNG(seed: 1)
        #expect(selector.next(forCueWith: 0, cue: .deal, using: &rng) == nil)
    }

    @Test("the same variation never plays twice in a row for a cue (R-DS-5.1)")
    func neverTwiceInARow() {
        var selector = VariationSelector()
        var rng = DeterministicRNG(seed: 42)
        var previous: Int? = nil
        // Many draws over a small list — the strictest test of the no-repeat rule.
        for _ in 0..<2000 {
            let index = selector.next(forCueWith: 4, cue: .shuffle, using: &rng)!
            #expect(index >= 0 && index < 4)
            if let previous {
                #expect(index != previous, "variation \(index) repeated back-to-back")
            }
            previous = index
        }
    }

    @Test("no-repeat is tracked per cue, not globally")
    func noRepeatIsPerCue() {
        var selector = VariationSelector()
        var rng = DeterministicRNG(seed: 7)
        // Interleave two cues; each cue's chain is independent, so a deal index may equal the previous
        // flip index without violating the per-cue rule.
        var lastDeal: Int? = nil
        var lastFlip: Int? = nil
        for _ in 0..<500 {
            let deal = selector.next(forCueWith: 3, cue: .deal, using: &rng)!
            let flip = selector.next(forCueWith: 3, cue: .flip, using: &rng)!
            if let lastDeal { #expect(deal != lastDeal) }
            if let lastFlip { #expect(flip != lastFlip) }
            lastDeal = deal
            lastFlip = flip
        }
    }

    @Test("over many draws every variation is eventually used (even distribution)")
    func coversAllVariations() {
        var selector = VariationSelector()
        var rng = DeterministicRNG(seed: 99)
        var seen = Set<Int>()
        for _ in 0..<1000 {
            seen.insert(selector.next(forCueWith: 5, cue: .place, using: &rng)!)
        }
        #expect(seen == Set(0..<5))
    }

    @Test("reset clears the no-repeat memory")
    func resetClearsMemory() {
        var selector = VariationSelector()
        var rng = DeterministicRNG(seed: 3)
        _ = selector.next(forCueWith: 2, cue: .win, using: &rng)
        #expect(selector.lastPlayedIndex(for: .win) != nil)
        selector.reset()
        #expect(selector.lastPlayedIndex(for: .win) == nil)
    }

    // MARK: - Engine: resolve + play (R-DS-5.1)

    /// Build an engine over fixed variation lists for a given set of cues.
    func makeEngine(
        mix: SoundMix = .default,
        seed: UInt64 = 1,
        counts: [SoundCue: Int]
    ) -> (SoundEngine, SpyPlayer) {
        let spy = SpyPlayer()
        let engine = SoundEngine(
            mix: mix,
            player: spy,
            rng: DeterministicRNG(seed: seed)
        ) { cue in Self.urls(for: cue, count: counts[cue] ?? 0) }
        return (engine, spy)
    }

    @Test("playing a cue plays a variation at the effects gain")
    func playPlaysAtGain() {
        let (engine, spy) = makeEngine(
            mix: SoundMix(effectsLevel: 0.6), counts: [.deal: 4])
        engine.play(.deal)
        #expect(spy.plays.count == 1)
        #expect(spy.plays[0].gain == 0.6)
        #expect(spy.plays[0].url.lastPathComponent.hasPrefix("deal_"))
    }

    @Test("a cue with no variations plays nothing")
    func noVariationsPlaysNothing() {
        let (engine, spy) = makeEngine(counts: [.deal: 0])
        engine.play(.deal)
        #expect(spy.plays.isEmpty)
    }

    @Test("muted engine plays nothing (R-DS-5.1)")
    func mutedPlaysNothing() {
        let (engine, spy) = makeEngine(mix: SoundMix(isMuted: true), counts: [.deal: 4])
        engine.play(.deal)
        #expect(spy.plays.isEmpty)
        #expect(engine.resolve(.deal) == nil)
    }

    @Test("backgrounded engine plays nothing (R-DS-5.1)")
    func backgroundedPlaysNothing() {
        let (engine, spy) = makeEngine(counts: [.deal: 4])
        engine.setInBackground(true)
        engine.play(.deal)
        #expect(spy.plays.isEmpty)
    }

    @Test("going to the background stops anything playing (R-DS-5.1)")
    func backgroundingStopsAll() {
        let (engine, spy) = makeEngine(counts: [.deal: 4])
        engine.play(.deal)
        #expect(spy.plays.count == 1)
        engine.setInBackground(true)
        #expect(spy.stopAllCount == 1)
    }

    @Test("muting stops anything playing (R-DS-5.1)")
    func mutingStopsAll() {
        let (engine, spy) = makeEngine(counts: [.deal: 4])
        engine.play(.deal)
        engine.setMuted(true)
        #expect(spy.stopAllCount == 1)
    }

    @Test("returning to the foreground lets cues play again")
    func foregroundResumes() {
        let (engine, spy) = makeEngine(counts: [.deal: 4])
        engine.setInBackground(true)
        engine.play(.deal)
        #expect(spy.plays.isEmpty)
        engine.setInBackground(false)
        engine.play(.deal)
        #expect(spy.plays.count == 1)
    }

    @Test("the engine never plays the same variation twice in a row for a cue (R-DS-5.1)")
    func engineNeverRepeats() {
        let (engine, spy) = makeEngine(seed: 5, counts: [.deal: 4])
        for _ in 0..<200 { engine.play(.deal) }
        let files = spy.plays.map(\.url.lastPathComponent)
        #expect(files.count == 200)
        for i in 1..<files.count {
            #expect(files[i] != files[i - 1], "repeated \(files[i]) back-to-back")
        }
    }

    @Test("live volume changes take effect on the next cue (R-DS-5.1)")
    func liveVolumeChange() {
        let (engine, spy) = makeEngine(mix: SoundMix(effectsLevel: 1.0), counts: [.deal: 4])
        engine.play(.deal)
        engine.setLevel(0.25, for: .effects)
        engine.play(.deal)
        #expect(spy.plays.count == 2)
        #expect(spy.plays[0].gain == 1.0)
        #expect(spy.plays[1].gain == 0.25)
    }

    @Test("switching packs resets the no-repeat memory and uses the new audio")
    func switchingPacksResets() {
        let (engine, spy) = makeEngine(counts: [.deal: 4])
        engine.play(.deal)
        // Swap to a resolver with a single distinct variation.
        let newURL = URL(fileURLWithPath: "/tmp/newpack/deal_only.caf")
        engine.useVariations { cue in cue == .deal ? [newURL] : [] }
        engine.play(.deal)
        #expect(spy.plays.last?.url == newURL)
    }

    // MARK: - Theme-pack wiring (R-DS-4.1, R-DS-5.1)

    @Test("the pack convenience initializer resolves cue files under the pack directory")
    func packInitializerResolvesFiles() {
        let dir = URL(fileURLWithPath: "/tmp/ThemePacks/classic-felt")
        let pack = ThemePack(
            id: "classic-felt",
            displayName: "Classic Felt",
            tableTheme: .default,
            deckStyles: DeckStyle.all,
            cardBacks: CardBack.all,
            audio: ["deal": ["deal_a.caf", "deal_b.caf"]],
            placeholder: true)
        let spy = SpyPlayer()
        let engine = SoundEngine(
            player: spy,
            rng: DeterministicRNG(seed: 1),
            pack: pack,
            packDirectory: dir)
        engine.play(.deal)
        #expect(spy.plays.count == 1)
        let played = spy.plays[0].url
        #expect(played.deletingLastPathComponent().path == dir.path)
        #expect(["deal_a.caf", "deal_b.caf"].contains(played.lastPathComponent))
        // A cue absent from the pack audio plays nothing.
        engine.play(.win)
        #expect(spy.plays.count == 1)
    }
}
