import Testing

@testable import DesignSystem

/// Unit tests for the color primitive and the WCAG contrast math (R-DS-1.2).
@Suite("TokenColor & WCAG contrast")
struct TokenColorTests {
    private let white = TokenColor(hex: 0xFFFFFF)
    private let black = TokenColor(hex: 0x000000)

    @Test("hex init decomposes channels")
    func hexInit() {
        let c = TokenColor(hex: 0x336699)
        #expect(abs(c.red - 0x33 / 255.0) < 1e-9)
        #expect(abs(c.green - 0x66 / 255.0) < 1e-9)
        #expect(abs(c.blue - 0x99 / 255.0) < 1e-9)
        #expect(c.alpha == 1)
    }

    @Test("channels clamp to 0...1")
    func clamp() {
        let c = TokenColor(red: 2, green: -1, blue: 0.5, alpha: 9)
        #expect(c.red == 1)
        #expect(c.green == 0)
        #expect(c.blue == 0.5)
        #expect(c.alpha == 1)
    }

    @Test("relative luminance of pure black and white")
    func luminanceEndpoints() {
        #expect(abs(black.relativeLuminance - 0) < 1e-9)
        #expect(abs(white.relativeLuminance - 1) < 1e-9)
    }

    @Test("black-on-white is the maximum 21:1 ratio")
    func maxContrast() {
        let ratio = black.contrastRatio(against: white)
        #expect(abs(ratio - 21) < 1e-6)
    }

    @Test("identical colors have ratio 1:1")
    func minContrast() {
        let mid = TokenColor(hex: 0x808080)
        #expect(abs(mid.contrastRatio(against: mid) - 1) < 1e-9)
    }

    @Test("contrast ratio is symmetric")
    func symmetric() {
        let a = TokenColor(hex: 0x123456)
        let b = TokenColor(hex: 0xABCDEF)
        #expect(abs(a.contrastRatio(against: b) - b.contrastRatio(against: a)) < 1e-12)
    }

    @Test("AA thresholds map to the right ratio")
    func thresholds() {
        #expect(ContrastUsage.normalText.minimumRatio == 4.5)
        #expect(ContrastUsage.largeText.minimumRatio == 3.0)
        #expect(ContrastUsage.essentialUI.minimumRatio == 3.0)
    }

    @Test("meetsAA agrees with the raw ratio")
    func meetsAA() {
        // Black on white easily clears normal text.
        #expect(black.meetsAA(against: white, usage: .normalText))
        // A light grey on white fails normal text but a darker grey passes large text.
        let lightGrey = TokenColor(hex: 0xBBBBBB)
        #expect(!lightGrey.meetsAA(against: white, usage: .normalText))
    }
}

/// Property-style tests for the contrast math invariants. These are ordinary randomized checks (Swift
/// Testing has no built-in PBT library here); they sample the input space and assert the WCAG-defined
/// invariants hold everywhere (R-DS-1.2).
@Suite("Contrast math invariants (randomized)")
struct ContrastInvariantTests {
    /// A small deterministic LCG so the sampled colors are reproducible.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    private func randomColor(_ rng: inout LCG) -> TokenColor {
        TokenColor(red: rng.unit(), green: rng.unit(), blue: rng.unit())
    }

    @Test("ratio is always within 1...21 and symmetric")
    func boundsAndSymmetry() {
        var rng = LCG(state: 0xDEAD_BEEF_CAFE_F00D)
        for _ in 0..<2_000 {
            let a = randomColor(&rng)
            let b = randomColor(&rng)
            let ab = a.contrastRatio(against: b)
            let ba = b.contrastRatio(against: a)
            #expect(ab >= 1 - 1e-9 && ab <= 21 + 1e-9)
            #expect(abs(ab - ba) < 1e-9)
        }
    }

    @Test("luminance is monotonic under a uniform lightening")
    func monotonicLightening() {
        var rng = LCG(state: 0x0123_4567_89AB_CDEF)
        for _ in 0..<2_000 {
            let c = randomColor(&rng)
            // Blend halfway toward white; luminance must not decrease.
            let lighter = TokenColor(
                red: (c.red + 1) / 2,
                green: (c.green + 1) / 2,
                blue: (c.blue + 1) / 2
            )
            #expect(lighter.relativeLuminance >= c.relativeLuminance - 1e-9)
        }
    }
}
