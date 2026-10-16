import Foundation
import Testing

@testable import DesignSystem

/// Tests for the pure accessibility fold: OS settings + app-level overrides → effective flags
/// (R-A11Y-4.1, R-A11Y-3.1).
@Suite("Effective accessibility fold")
struct EffectiveAccessibilityTests {
    // A convenience wrapper defaulting every input off, so each test flips only what it exercises.
    private func resolve(
        osReduceMotion: Bool = false,
        osIncreaseContrast: Bool = false,
        osReduceTransparency: Bool = false,
        forceReduceMotion: Bool = false,
        highContrastCards: Bool = false,
        fourColorDeck: Bool = false
    ) -> EffectiveAccessibility {
        EffectiveAccessibility.resolve(
            osReduceMotion: osReduceMotion,
            osIncreaseContrast: osIncreaseContrast,
            osReduceTransparency: osReduceTransparency,
            forceReduceMotion: forceReduceMotion,
            highContrastCards: highContrastCards,
            fourColorDeck: fourColorDeck)
    }

    @Test("all inputs off yields the plain baseline")
    func allOff() {
        #expect(resolve() == .standard)
        #expect(EffectiveAccessibility.standard.reduceMotion == false)
        #expect(EffectiveAccessibility.standard.increaseContrast == false)
        #expect(EffectiveAccessibility.standard.reduceTransparency == false)
        #expect(EffectiveAccessibility.standard.fourColorDeck == false)
    }

    // MARK: - Reduce Motion = OS OR override

    @Test("reduce motion is effective when the OS setting is on")
    func reduceMotionFromOS() {
        #expect(resolve(osReduceMotion: true).reduceMotion)
    }

    @Test("reduce motion is effective when the app forces it")
    func reduceMotionFromOverride() {
        #expect(resolve(forceReduceMotion: true).reduceMotion)
    }

    @Test("reduce motion is off only when both the OS setting and the override are off")
    func reduceMotionOffWhenBothOff() {
        #expect(resolve(osReduceMotion: false, forceReduceMotion: false).reduceMotion == false)
        // Either source alone is enough (OR semantics).
        #expect(resolve(osReduceMotion: true, forceReduceMotion: true).reduceMotion)
    }

    // MARK: - Increase Contrast = OS OR override

    @Test("increase contrast is effective when the OS setting is on")
    func contrastFromOS() {
        #expect(resolve(osIncreaseContrast: true).increaseContrast)
    }

    @Test("increase contrast is effective when the high-contrast-cards override is on")
    func contrastFromOverride() {
        #expect(resolve(highContrastCards: true).increaseContrast)
    }

    @Test("increase contrast is off only when both the OS setting and the override are off")
    func contrastOffWhenBothOff() {
        #expect(
            resolve(osIncreaseContrast: false, highContrastCards: false).increaseContrast == false)
    }

    // MARK: - Reduce Transparency = OS only

    @Test("reduce transparency follows the OS setting")
    func transparencyFromOS() {
        #expect(resolve(osReduceTransparency: true).reduceTransparency)
        #expect(resolve(osReduceTransparency: false).reduceTransparency == false)
    }

    @Test("no app override affects reduce transparency (it is OS-only)")
    func transparencyIgnoresOverrides() {
        // Turning on every APP override must not turn on reduce transparency.
        let folded = resolve(
            osReduceTransparency: false,
            forceReduceMotion: true,
            highContrastCards: true,
            fourColorDeck: true)
        #expect(folded.reduceTransparency == false)
    }

    // MARK: - Four-Color deck = override only

    @Test("the four-color deck follows the app override only")
    func fourColorFromOverride() {
        #expect(resolve(fourColorDeck: true).fourColorDeck)
        #expect(resolve(fourColorDeck: false).fourColorDeck == false)
    }

    @Test("no OS setting turns on the four-color deck")
    func fourColorIgnoresOS() {
        let folded = resolve(
            osReduceMotion: true, osIncreaseContrast: true, osReduceTransparency: true,
            fourColorDeck: false)
        #expect(folded.fourColorDeck == false)
    }

    // MARK: - Exhaustive property: each effective flag depends only on its own sources

    @Test("fold matches the rule table across all 64 input combinations")
    func exhaustiveTruthTable() {
        for bits in 0..<64 {
            let osRM = bits & 1 != 0
            let osIC = bits & 2 != 0
            let osRT = bits & 4 != 0
            let frm = bits & 8 != 0
            let hcc = bits & 16 != 0
            let fcd = bits & 32 != 0
            let e = resolve(
                osReduceMotion: osRM, osIncreaseContrast: osIC, osReduceTransparency: osRT,
                forceReduceMotion: frm, highContrastCards: hcc, fourColorDeck: fcd)
            #expect(e.reduceMotion == (osRM || frm))
            #expect(e.increaseContrast == (osIC || hcc))
            #expect(e.reduceTransparency == osRT)
            #expect(e.fourColorDeck == fcd)
        }
    }
}

/// Tests for the card-size accessibility scale S / M / L / XL (R-A11Y-4.1).
@Suite("Card size scale")
struct CardSizeScaleTests {
    @Test("the four sizes ship with S/M/L/XL raw values")
    func fourSizes() {
        #expect(CardSizeScale.allCases.count == 4)
        #expect(CardSizeScale.small.rawValue == "S")
        #expect(CardSizeScale.medium.rawValue == "M")
        #expect(CardSizeScale.large.rawValue == "L")
        #expect(CardSizeScale.extraLarge.rawValue == "XL")
    }

    @Test("medium is the 1.0 baseline")
    func mediumIsBaseline() {
        #expect(CardSizeScale.medium.multiplier == 1.0)
        #expect(CardSizeScale.default == .medium)
    }

    @Test("multipliers are strictly monotonic: S < M < L < XL")
    func monotonic() {
        let ordered: [CardSizeScale] = [.small, .medium, .large, .extraLarge]
        let multipliers = ordered.map(\.multiplier)
        for i in 1..<multipliers.count {
            #expect(
                multipliers[i] > multipliers[i - 1], "\(ordered[i]) must exceed \(ordered[i - 1])")
        }
    }

    @Test("small shrinks below baseline and extra-large enlarges above it")
    func extremes() {
        #expect(CardSizeScale.small.multiplier < 1.0)
        #expect(CardSizeScale.extraLarge.multiplier > 1.0)
    }

    @Test("card size scale round-trips through Codable")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for size in CardSizeScale.allCases {
            let data = try encoder.encode(size)
            #expect(try decoder.decode(CardSizeScale.self, from: data) == size)
        }
    }
}
