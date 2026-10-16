import Foundation
import Testing

@testable import DesignSystem

/// Tests for height-scaled shadows: a card's shadow scales with its lift height (R-TABLE-1.3;
/// ux-guidelines visual language).
@Suite("Lift-scaled shadows")
struct LiftShadowTests {
    // MARK: - Endpoints

    @Test("at rest the shadow equals the resting endpoint; at full lift, the lifted endpoint")
    func endpoints() {
        let s = LiftShadow.table
        #expect(s.shadow(atLift: 0) == s.resting)
        #expect(s.shadow(atLift: s.maxLift) == s.lifted)
    }

    @Test("the default table lift-shadow is anchored to the elevation tokens")
    func anchoredToElevation() {
        #expect(LiftShadow.table.resting == Elevation.low)
        #expect(LiftShadow.table.lifted == Elevation.high)
    }

    @Test("lift clamps below 0 and above maxLift")
    func clamps() {
        let s = LiftShadow.table
        #expect(s.shadow(atLift: -10) == s.resting)
        #expect(s.shadow(atLift: s.maxLift * 3) == s.lifted)
        #expect(s.normalizedLift(-5) == 0)
        #expect(s.normalizedLift(s.maxLift * 2) == 1)
    }

    // MARK: - The property: the shadow grows with lift (R-TABLE-1.3)

    @Test("blur radius, vertical offset, and opacity all increase monotonically with lift")
    func monotonicWithLift() {
        let s = LiftShadow.table
        // The default table shadow's lifted endpoint is strictly larger on each axis than the resting
        // one, so the interpolation is strictly increasing — the precondition for a height cue.
        #expect(s.lifted.radius > s.resting.radius)
        #expect(s.lifted.offsetY > s.resting.offsetY)
        #expect(s.lifted.opacity > s.resting.opacity)

        // Sample many lifts across the range; each successive shadow is >= the previous on every axis,
        // and strictly greater when the two lifts differ (property-style check over the input space).
        let steps = 200
        var previous = s.shadow(atLift: 0)
        for i in 1...steps {
            let lift = s.maxLift * Double(i) / Double(steps)
            let current = s.shadow(atLift: lift)
            #expect(current.radius >= previous.radius, "radius decreased at lift \(lift)")
            #expect(current.offsetY >= previous.offsetY, "offsetY decreased at lift \(lift)")
            #expect(current.opacity >= previous.opacity, "opacity decreased at lift \(lift)")
            // Strict growth between distinct sampled lifts.
            #expect(current.radius > previous.radius, "radius not strictly growing at lift \(lift)")
            previous = current
        }
    }

    @Test("normalizedLift is the linear fraction of maxLift")
    func normalizedLiftLinear() {
        let s = LiftShadow.table
        for i in 0...10 {
            let f = Double(i) / 10.0
            let lift = s.maxLift * f
            #expect(abs(s.normalizedLift(lift) - f) < 1e-9)
        }
    }

    @Test("a custom lift-shadow interpolates between arbitrary endpoints")
    func customEndpoints() {
        let resting = ShadowToken(radius: 1, offsetY: 0.5, opacity: 0.1)
        let lifted = ShadowToken(radius: 21, offsetY: 10.5, opacity: 0.5)
        let s = LiftShadow(resting: resting, lifted: lifted, maxLift: 20)
        let mid = s.shadow(atLift: 10)
        #expect(abs(mid.radius - 11) < 1e-9)
        #expect(abs(mid.offsetY - 5.5) < 1e-9)
        #expect(abs(mid.opacity - 0.3) < 1e-9)
    }

    @Test("maxLift is guarded against zero to avoid division by zero")
    func maxLiftGuarded() {
        let s = LiftShadow(resting: Elevation.low, lifted: Elevation.high, maxLift: 0)
        #expect(s.maxLift > 0)
        // Any positive lift maps to (essentially) full lift without crashing.
        #expect(s.shadow(atLift: 1) == s.lifted)
    }
}
