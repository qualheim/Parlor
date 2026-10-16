// HUDAvatarView — TableKit's resolver for an engine `AvatarReference` (task 5.6; R-SESS-5.1, R-DS-6.1).
//
// A seat plate needs to draw the seat's avatar, and TableKit is a UI-layer package that cannot depend on
// the App (the App's `AvatarView` sits above TableKit in the dependency graph). So TableKit carries its
// OWN small resolver here — the same pattern as the App's `PlaceholderAvatar` — turning the UI-free
// `AvatarReference` data (Profiles.swift) into a SwiftUI view:
//   • `.generatedGlyph(symbol, tint)` → the SF Symbol on a tinted filled circle;
//   • `.namedPlaceholder(name)` → looks for a bundled image, else falls back to a neutral generated glyph
//     so a plate is never blank.
//
// 🎨 PLACEHOLDER ART — NEEDS PRODUCTION ART (R-DS-6.1). Generated glyphs are stand-ins tracked in the
// Placeholder-art register (task 4.3, re-audited in task 8.5). Commissioned art replaces this resolver
// without touching the engine's `AvatarReference` model (R-DS-4.2).

import EngineCore
import SwiftUI

/// Renders an engine `AvatarReference` as a SwiftUI view for a seat plate (R-SESS-5.1, R-DS-6.1).
///
/// Decorative by default — the seat plate carries the seat's name as its accessibility label, so the glyph
/// itself is hidden from VoiceOver to avoid a redundant announcement (design.md §9).
struct HUDAvatarView: View {
    /// The engine avatar reference to resolve.
    let reference: AvatarReference
    /// The rendered diameter in points.
    var size: CGFloat = 40

    var body: some View {
        switch reference {
        case .generatedGlyph(let symbol, let tint):
            glyph(symbol: symbol, tint: Color(tableKitHex: tint) ?? .accentColor)
        case .namedPlaceholder(let name):
            if let image = Self.bundledImage(named: name) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            } else {
                // Named placeholder art is not bundled here; fall back so a plate always shows something
                // (🎨 needs production art — R-DS-6.1).
                glyph(symbol: "person.crop.circle.fill", tint: .secondary)
            }
        }
    }

    private func glyph(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.58))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: Circle())
            .accessibilityHidden(true)
    }

    /// Whether a named image asset exists in the app bundle, returned as an `Image` if so.
    private static func bundledImage(named name: String) -> Image? {
        #if canImport(AppKit)
            if NSImage(named: name) != nil {
                return Image(name)
            }
        #endif
        return nil
    }
}

// MARK: - Local hex color helper

extension Color {
    /// Parse a `#RRGGBB` (or `#RRGGBBAA`) hex string into a `Color`, or `nil` if malformed.
    ///
    /// `AvatarReference.generatedGlyph` carries its tint as a hex string (engine data is UI-free), so the
    /// resolver needs a hex→`Color` bridge. Named `tableKitHex:` to avoid colliding with any other
    /// `Color(hex:)` a consumer of TableKit might define. A full semantic color system is DesignSystem's
    /// job (R-DS-1.1); this only decodes a persona/profile tint.
    init?(tableKitHex hex: String) {
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
