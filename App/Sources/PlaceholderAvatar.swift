// PlaceholderAvatar — generated placeholder avatars, flagged "needs production art" (R-DS-6.1).
//
// R-SESS-5.1 models an avatar as UI-free data in EngineCore (`AvatarReference`, Profiles.swift): either a
// named bundled placeholder or a procedurally drawn glyph (an SF Symbol + a tint). This file is the App's
// RESOLVER — the one place that turns that data into a SwiftUI view. Keeping resolution here (not in the
// engine) is what lets commissioned art replace placeholders later by swapping this resolver, with no
// engine change (R-DS-4.2).
//
// 🎨 PLACEHOLDER ART — NEEDS PRODUCTION ART (R-DS-6.1). Every avatar produced here is a generated
// placeholder: an SF Symbol on a tinted circle. They are tracked in the Placeholder-art register in
// `.kiro/specs/01-platform-foundation/tasks.md` ("Player/persona avatars (task 4.3) 🎨") and re-audited in
// task 8.5. Real illustrated avatars replace `AvatarChoices.all` and this drawing without touching the
// profile model.
//
// This follows the same "generated placeholder + flagged in the register" pattern task 1.5 used for the
// app icon.

import Persistence  // re-exports EngineCore: AvatarReference (R-SESS-5)
import SwiftUI

// MARK: - The bundled placeholder avatar palette (🎨 needs production art)

/// The set of generated placeholder avatars the profile editor offers (R-SESS-5.2, R-DS-6.1).
///
/// 🎨 Each is a procedural glyph (SF Symbol + tint) — a stand-in until production avatar art is
/// commissioned (tracked in the Placeholder-art register, task 4.3; re-audited task 8.5).
enum AvatarChoices {
    /// The selectable placeholder avatars, as engine `AvatarReference` values so a choice stores directly
    /// on the profile.
    static let all: [AvatarReference] = [
        .generatedGlyph(symbol: "person.crop.circle.fill", tint: "#4C6EF5"),
        .generatedGlyph(symbol: "face.smiling.inverse", tint: "#2F9E44"),
        .generatedGlyph(symbol: "star.circle.fill", tint: "#E8590C"),
        .generatedGlyph(symbol: "leaf.circle.fill", tint: "#0CA678"),
        .generatedGlyph(symbol: "bolt.circle.fill", tint: "#F08C00"),
        .generatedGlyph(symbol: "moon.circle.fill", tint: "#7048E8"),
        .generatedGlyph(symbol: "flame.circle.fill", tint: "#E03131"),
        .generatedGlyph(symbol: "pawprint.circle.fill", tint: "#1098AD"),
    ]
}

// MARK: - Rendering an AvatarReference

/// Renders an `AvatarReference` as a SwiftUI view — the App's avatar resolver (🎨 placeholder art;
/// R-SESS-5.1, R-DS-6.1).
///
/// A `.generatedGlyph` draws its SF Symbol on a tinted filled circle; a `.namedPlaceholder` resolves the
/// named asset from the bundle, falling back to a neutral generated glyph if the asset is missing so a
/// profile always shows *something*. Decorative by default (VoiceOver reads the profile name, not the
/// glyph); callers that need a label add one.
struct AvatarView: View {
    let reference: AvatarReference
    var size: CGFloat = 44

    var body: some View {
        switch reference {
        case .generatedGlyph(let symbol, let tint):
            glyph(symbol: symbol, tint: Color(hex: tint) ?? .accentColor)
        case .namedPlaceholder(let name):
            // Named placeholder assets are not bundled yet; fall back to a neutral generated glyph so the
            // avatar is never blank (🎨 needs production art — R-DS-6.1).
            if let uiImageName = Bundle.main.image(named: name) {
                uiImageName
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                glyph(symbol: "person.crop.circle.fill", tint: .secondary)
            }
        }
    }

    private func glyph(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.6))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Small helpers

extension Color {
    /// Parse a `#RRGGBB` (or `#RRGGBBAA`) hex string into a `Color`, or `nil` if malformed. Kept local to
    /// the App shell — a full color-token system is DesignSystem's job (R-DS-1.1).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let r: Double
        let g: Double
        let b: Double
        let a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255.0
            g = Double((value >> 16) & 0xFF) / 255.0
            b = Double((value >> 8) & 0xFF) / 255.0
            a = Double(value & 0xFF) / 255.0
        } else {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension Bundle {
    /// Whether a named image asset exists in the bundle, returning it as an `Image` if so. Used to prefer
    /// a bundled placeholder asset over the generated fallback when one is present.
    fileprivate func image(named name: String) -> Image? {
        #if canImport(AppKit)
            if NSImage(named: name) != nil {
                return Image(name)
            }
        #endif
        return nil
    }
}
