import Testing

@testable import DesignSystem

/// Structural tests for the non-color token scales: type, spacing, radius, shadow, motion (R-DS-1.1).
@Suite("Type / spacing / radius / shadow / motion tokens")
struct TokensTests {
    // MARK: Typography

    @Test("type ramp is strictly descending in size")
    func typeRampDescending() {
        let sizes = Typography.all.map(\.size)
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test("large-text classification follows the WCAG rule")
    func largeTextRule() {
        // ≥ 18 pt regular is large.
        #expect(Typography.title2.isLargeText)  // 22 pt
        #expect(Typography.title2.contrastUsage == .largeText)
        // 15 pt body is normal text.
        #expect(!Typography.body.isLargeText)
        #expect(Typography.body.contrastUsage == .normalText)
        // 14 pt bold counts as large; 14 pt regular does not.
        let boldCallout = TypeToken(size: 14, weight: .bold)
        let regularCallout = TypeToken(size: 14, weight: .regular)
        #expect(boldCallout.isLargeText)
        #expect(!regularCallout.isLargeText)
    }

    // MARK: Spacing & radius

    @Test("spacing ramp is strictly ascending and non-negative")
    func spacingRamp() {
        #expect(Spacing.ramp == Spacing.ramp.sorted())
        #expect(Spacing.ramp.allSatisfy { $0 >= 0 })
        #expect(Spacing.ramp.first == Spacing.xxs)
    }

    @Test("radius ramp is ascending and non-negative")
    func radiusRamp() {
        #expect(Radius.ramp == Radius.ramp.sorted())
        #expect(Radius.ramp.allSatisfy { $0 >= 0 })
        #expect(Radius.pill > Radius.xl)
    }

    // MARK: Shadow

    @Test("elevation opacity increases with height and stays in 0...1")
    func elevationRamp() {
        let opacities = Elevation.all.map(\.opacity)
        #expect(opacities == opacities.sorted())
        #expect(opacities.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(Elevation.none.opacity == 0)
    }

    // MARK: Motion

    @Test("default table motions sit in the 150-350 ms band")
    func motionBand() {
        for token in [Motion.quick, Motion.standard, Motion.relaxed] {
            #expect(
                Motion.defaultBand.contains(token.duration),
                "duration \(token.duration) outside 150-350 ms band"
            )
        }
        // Instant is deliberately below the band (Reduce Motion / Instant speed).
        #expect(!Motion.defaultBand.contains(Motion.instant.duration))
        #expect(Motion.instant.duration < Motion.defaultBand.lowerBound)
    }

    @Test("motion damping fractions are within 0...1")
    func motionDamping() {
        #expect(Motion.all.allSatisfy { $0.dampingFraction >= 0 && $0.dampingFraction <= 1 })
    }
}
