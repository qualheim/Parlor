// LiftShadow — a card's shadow scales with its lift height (R-TABLE-1.3; ux-guidelines visual language).
//
// The parlor look is "a beautifully lit table": a resting card sits almost flat with a tight, dark
// contact shadow; as a card is lifted (hover, drag, deal-in-flight) its shadow grows softer, larger, and
// offsets further — exactly as a real card would cast under table lighting. This file expresses that as a
// *pure function of a normalized lift height* so it is testable headless and shared by every piece view.
//
// The mapping is deliberately monotonic: as lift increases, blur radius grows, the vertical offset grows,
// and opacity eases up toward a ceiling (a very high card's shadow is diffuse, not pitch black). The
// endpoints are anchored to the existing elevation tokens (`Elevation.low` at rest → `Elevation.high`
// fully lifted) so the height-scaled shadow stays consistent with the rest of the shadow scale
// (`Tokens.swift`). The shadow is tinted with the current `TableTheme.shadowInk` at the call site, so a
// felt surface and a wood surface ground their cards differently.
//
// SwiftUI application (`.shadow(...)`) lives in `TableTheme+SwiftUI.swift`; this is the geometry only.

import Foundation

/// Computes the `ShadowToken` a card casts at a given lift height (R-TABLE-1.3).
///
/// `LiftShadow` is a small, `Sendable` value describing the resting and fully-lifted shadow endpoints and
/// the maximum lift the scale is defined over. `shadow(atLift:)` interpolates between the endpoints, so a
/// card's shadow visibly scales with how far it is lifted off the table.
public struct LiftShadow: Sendable, Hashable {
    /// The shadow of a card resting flat on the table (lift 0). Tight, low, fairly opaque contact shadow.
    public let resting: ShadowToken
    /// The shadow of a card at maximum lift. Large, soft, offset, and slightly less opaque (diffuse).
    public let lifted: ShadowToken
    /// The lift height (in points) at which `lifted` is reached; lifts clamp to this. `> 0`.
    public let maxLift: Double

    public init(resting: ShadowToken, lifted: ShadowToken, maxLift: Double) {
        self.resting = resting
        self.lifted = lifted
        self.maxLift = max(0.0001, maxLift)
    }

    /// The default table lift-shadow, anchored to the elevation tokens: `Elevation.low` at rest grows to
    /// `Elevation.high` at full lift, over a 24 pt lift range (a card lifted a couple of card-thicknesses
    /// for hover/drag). As the card lifts, its shadow blurs wider, drops further, and reads more strongly
    /// — the visual cue that the card is off the table (ux-guidelines visual language).
    public static let table = LiftShadow(
        resting: Elevation.low,
        lifted: Elevation.high,
        maxLift: 24
    )

    /// The `ShadowToken` for a card lifted `lift` points off the table. `lift` is clamped to `0...maxLift`.
    ///
    /// Blur radius, vertical offset, and opacity all ease from the resting endpoint toward the lifted
    /// endpoint as lift increases, so a card's shadow grows with its height (R-TABLE-1.3 / ux-guidelines).
    public func shadow(atLift lift: Double) -> ShadowToken {
        let t = LiftShadow.clamp01(lift / maxLift)
        return ShadowToken(
            radius: LiftShadow.lerp(resting.radius, lifted.radius, t),
            offsetX: LiftShadow.lerp(resting.offsetX, lifted.offsetX, t),
            offsetY: LiftShadow.lerp(resting.offsetY, lifted.offsetY, t),
            opacity: LiftShadow.lerp(resting.opacity, lifted.opacity, t)
        )
    }

    /// The fraction of full lift `lift` represents, in 0...1 (useful for other height-driven effects).
    public func normalizedLift(_ lift: Double) -> Double { LiftShadow.clamp01(lift / maxLift) }

    // MARK: Math helpers (pure)

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}
