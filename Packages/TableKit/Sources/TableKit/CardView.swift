// CardView — a card view over cached vector faces, with flip/lift/selection/highlight/dimming (R-TABLE-2).
//
// `CardView` renders ONE card by compositing a CACHED vector face or back (R-TABLE-2.1) with the
// interaction states R-TABLE-2.2 requires:
//   • 3D flip           — a `rotation3DEffect` about the Y axis; the face shown swaps at the halfway
//                         point, so a face-down back turns into the card's face.
//   • lift on hover     — a height-scaled shadow (DesignSystem `liftShadow`) + slight scale, the "card
//                         off the table" cue (R-TABLE-1.3 shared geometry).
//   • selection         — a themed selection ring.
//   • legal-target highlight — a soft glow marking a legal drop/target.
//   • optional dimming  — reduced opacity for an unplayable card.
//
// The face itself is NEVER redrawn per frame: the cached image is fetched from `CardFaceCache` by a
// `CardFaceKey` derived from (theme, face, scale, appearance) (R-TABLE-2.1). Flipping/lifting/selecting a
// card only changes cheap overlays and transforms over that one cached bitmap.

import DesignSystem
import EngineCore
import SwiftUI

/// The presentation state of a card view (R-TABLE-2.2). All flags default off, so a plain resting card is
/// `CardPresentation()`.
public struct CardPresentation: Sendable, Hashable {
    /// Whether the card is face-up (the face is shown) or face-down (the back is shown).
    public var faceUp: Bool
    /// Normalized lift height in points for the height-scaled shadow (0 = resting).
    public var lift: Double
    /// Whether the card is selected (draws a selection ring).
    public var isSelected: Bool
    /// Whether the card is a highlighted legal target (draws a legal-target glow).
    public var isLegalTarget: Bool
    /// Whether the card is dimmed as unplayable (reduced opacity).
    public var isDimmed: Bool

    public init(
        faceUp: Bool = true,
        lift: Double = 0,
        isSelected: Bool = false,
        isLegalTarget: Bool = false,
        isDimmed: Bool = false
    ) {
        self.faceUp = faceUp
        self.lift = lift
        self.isSelected = isSelected
        self.isLegalTarget = isLegalTarget
        self.isDimmed = isDimmed
    }
}

/// A single card view backed by a cached vector face/back (R-TABLE-2.1) supporting the R-TABLE-2.2 states.
public struct CardView: View {
    /// The card's printed face (used when face-up).
    private let face: CardFace
    /// The presentation state (flip/lift/selection/highlight/dimming).
    private let presentation: CardPresentation
    /// The draw size in points.
    private let size: CGSize
    /// The VoiceOver description for this card (R-A11Y-1.1). When `nil`, it is derived from the face +
    /// presentation (face-down → "Face-down card", selected → "selected"); callers with game context
    /// (trump/playable) pass an enriched description.
    private let accessibility: AccessibilityDescription?

    @Environment(\.cardFaceCache) private var cache
    @Environment(\.tableTheme) private var theme
    @Environment(\.deckStyle) private var style
    @Environment(\.cardBack) private var back
    @Environment(\.cardAppearance) private var appearance
    @Environment(\.displayScale) private var displayScale

    public init(
        face: CardFace,
        presentation: CardPresentation = .init(),
        size: CGSize,
        accessibility: AccessibilityDescription? = nil
    ) {
        self.face = face
        self.presentation = presentation
        self.size = size
        self.accessibility = accessibility
    }

    /// The description applied to VoiceOver: the caller's enriched one, or a derivation from the current
    /// face + presentation so a card always has a meaningful label/value/hint (R-A11Y-1.1).
    private var resolvedAccessibility: AccessibilityDescription {
        if let accessibility { return accessibility }
        if !presentation.faceUp {
            return PieceAccessibility.faceDown()
        }
        let context = PieceAccessibilityContext(
            isPlayable: presentation.isDimmed ? false : nil,
            isSelected: presentation.isSelected)
        return PieceAccessibility.card(face, context: context)
    }

    public var body: some View {
        let shownFace = presentation.faceUp ? CardFaceDescriptor(face) : .back(back)
        let key = CardFaceKey(
            themeID: theme.id,
            deckStyleID: style.id,
            face: shownFace,
            scaleBucket: CardFaceKey.scaleBucket(
                forPixelSize: Double(max(size.width, size.height) * displayScale)),
            appearance: appearance
        )
        let image = cache.image(
            for: key, style: style, back: back, theme: theme, size: size, displayScale: displayScale
        )

        let description = resolvedAccessibility
        return
            image
            .resizable()
            .frame(width: size.width, height: size.height)
            .overlay(legalTargetGlow)
            .overlay(selectionRing)
            .opacity(presentation.isDimmed ? 0.45 : 1)
            .scaleEffect(1 + CGFloat(liftFraction) * 0.04)
            .rotation3DEffect(
                .degrees(presentation.faceUp ? 0 : 180), axis: (x: 0, y: 1, z: 0)
            )
            .liftShadow(presentation.lift, theme: theme)
            .animation(Motion.standard.swiftUIAnimation, value: presentation.faceUp)
            .animation(Motion.quick.swiftUIAnimation, value: presentation.lift)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(description.label))
            .accessibilityValue(Text(description.value))
            .accessibilityHint(Text(description.hint))
    }

    // MARK: Overlays

    private var liftFraction: Double { LiftShadow.table.normalizedLift(presentation.lift) }

    private var corner: CGFloat { min(size.width, size.height) * 0.10 }

    @ViewBuilder
    private var selectionRing: some View {
        if presentation.isSelected {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    theme.parameters.accent.swiftUIColor, lineWidth: max(2, size.width * 0.03))
        }
    }

    @ViewBuilder
    private var legalTargetGlow: some View {
        if presentation.isLegalTarget {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.9), lineWidth: max(2, size.width * 0.025))
                .shadow(color: Color.yellow.opacity(0.6), radius: size.width * 0.08)
        }
    }
}

// MARK: - Environment plumbing for the chosen deck style / back / appearance

private struct DeckStyleKey: EnvironmentKey {
    static let defaultValue: DeckStyle = .default
}

private struct CardBackKey: EnvironmentKey {
    static let defaultValue: CardBack = .default
}

private struct CardAppearanceKey: EnvironmentKey {
    static let defaultValue: CardAppearance = .standard
}

extension EnvironmentValues {
    /// The current deck-face style (Classic/Modern/Four-Color/Jumbo Index — R-DS-3.1). Card views read it
    /// to derive the cache key and draw the face.
    public var deckStyle: DeckStyle {
        get { self[DeckStyleKey.self] }
        set { self[DeckStyleKey.self] = newValue }
    }

    /// The current card back (≥ 6 — R-DS-3.2), used when a card is face-down.
    public var cardBack: CardBack {
        get { self[CardBackKey.self] }
        set { self[CardBackKey.self] = newValue }
    }

    /// The current card appearance (standard / high-contrast — R-A11Y-4.1), part of the cache key.
    public var cardAppearance: CardAppearance {
        get { self[CardAppearanceKey.self] }
        set { self[CardAppearanceKey.self] = newValue }
    }
}

extension View {
    /// Inject the chosen deck-face style for this subtree (runtime-switchable — task 5.4).
    public func deckStyle(_ style: DeckStyle) -> some View {
        environment(\.deckStyle, style)
    }

    /// Inject the chosen card back for this subtree (runtime-switchable — task 5.4).
    public func cardBack(_ back: CardBack) -> some View {
        environment(\.cardBack, back)
    }

    /// Inject the card appearance (standard / high-contrast) for this subtree.
    public func cardAppearance(_ appearance: CardAppearance) -> some View {
        environment(\.cardAppearance, appearance)
    }

    /// Inject the deck-face style into TableKit's rendering environment under a DISTINCT name (R-TABLE-2.1,
    /// R-A11Y-3.1). Identical in effect to `deckStyle(_:)`, but unambiguous for a host that also imports
    /// DesignSystem (which vends its own `deckStyle(_:)` modifier): the app calls this to be certain the
    /// value lands on the key the card renderer reads.
    public func tableDeckStyle(_ style: DeckStyle) -> some View {
        environment(\.deckStyle, style)
    }
}
