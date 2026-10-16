// GameTileView + TileArtView — a game tile with placeholder art and subtle hover parallax, disabled
// under Reduce Motion (R-APP-1.3, R-DS-6.1).
//
// NOTE ON BUILD: compiled by the Xcode project, not SwiftPM (design.md §1).
//
// R-APP-1.3: game tiles show illustrated artwork with SUBTLE PARALLAX ON HOVER, DISABLED under Reduce
// Motion. The pure catalog carries only a UI-free `TileArt` reference (`GameCatalog.swift`) and a
// `prefersParallax` hint; this file is the App's RESOLVER + the parallax rendering — the same "generated
// placeholder + flagged in the register" pattern `PlaceholderAvatar` uses for avatars (🎨 R-DS-6.1;
// tracked in the tasks.md Placeholder-art register, task 6.5).
//
// PARALLAX (R-APP-1.3). On hover the art layer shifts a few points toward the cursor with a spring, and
// the tile lifts slightly. Under Reduce Motion (OS or app override) the parallax + lift are DISABLED —
// the tile still highlights on hover so hover is not lost, but nothing moves (R-TABLE-5.3 spirit). The
// motion is gated on the SwiftUI `accessibilityReduceMotion` environment AND the tile's `prefersParallax`
// catalog hint.

import GamesUI  // CatalogEntry, TileArt
import SwiftUI

// MARK: - Game tile (R-APP-1.3)

/// One game tile in the Library grid (R-APP-1.1, R-APP-1.3). Tapping the tile opens setup; a star toggles
/// the favorite. The art draws its placeholder with hover parallax (disabled under Reduce Motion).
struct GameTileView: View {
    /// The catalog entry this tile represents.
    let entry: CatalogEntry
    /// Whether the game is currently favorited (drives the star).
    let isFavorite: Bool
    /// The one-line subtitle (seats · duration · complexity).
    let subtitle: String
    /// Open the setup sheet for this game (R-APP-2.1).
    let onOpen: () -> Void
    /// Toggle this game's favorite state (R-APP-1.1).
    let onToggleFavorite: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                TileArtView(art: entry.tileArt, prefersParallax: entry.prefersParallax)
                    .frame(height: 128)
                    .overlay(alignment: .topTrailing) { favoriteButton }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.metadata.name)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.metadata.name)
        .accessibilityValue(subtitle)
        .accessibilityHint("Opens game setup")
        .accessibilityIdentifier("library.tile.\(entry.metadata.id)")
    }

    /// The favorite star overlaid on the art. A separate control so VoiceOver/keyboard can toggle it apart
    /// from opening the game.
    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.white))
                .padding(6)
                .background(.black.opacity(0.35), in: Circle())
                .padding(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isFavorite
                ? "Remove \(entry.metadata.name) from favorites"
                : "Add \(entry.metadata.name) to favorites"
        )
        .accessibilityIdentifier("library.favorite.\(entry.metadata.id)")
    }
}

// MARK: - Tile art with hover parallax (R-APP-1.3, R-DS-6.1)

/// The tile's artwork layer: draws the placeholder `TileArt` and, on hover, applies subtle parallax +
/// lift — DISABLED under Reduce Motion (R-APP-1.3). 🎨 placeholder art (needs production art — R-DS-6.1).
struct TileArtView: View {
    /// The UI-free art reference resolved to pixels here.
    let art: TileArt
    /// Whether this tile opts into hover parallax (catalog hint). Reduce Motion still overrides this off.
    var prefersParallax: Bool = true

    /// The OS Reduce Motion setting — parallax is disabled when it is on (R-APP-1.3, R-TABLE-5.3).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the cursor is over the tile (drives the parallax shift + lift).
    @State private var hovering = false

    /// Whether motion is allowed: the catalog hint AND not Reduce Motion (R-APP-1.3).
    private var motionEnabled: Bool { prefersParallax && !reduceMotion }

    var body: some View {
        placeholder
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Subtle lift on hover; only when motion is allowed (R-APP-1.3).
            .scaleEffect(motionEnabled && hovering ? 1.03 : 1.0)
            .shadow(
                color: .black.opacity(hovering ? 0.22 : 0.10),
                radius: hovering ? 10 : 4, y: hovering ? 5 : 2
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
            .accessibilityHidden(true)
    }

    /// The generated placeholder: an SF Symbol over a tinted gradient, with the foreground glyph shifting
    /// slightly toward the cursor on hover for the parallax effect (disabled under Reduce Motion).
    @ViewBuilder
    private var placeholder: some View {
        switch art {
        case .generatedPlaceholder(let symbol, let tint):
            let tintColor = Color(hex: tint) ?? .accentColor
            ZStack {
                LinearGradient(
                    colors: [tintColor.opacity(0.95), tintColor.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    // Parallax: the glyph drifts a few points on hover when motion is allowed.
                    .offset(
                        x: motionEnabled && hovering ? 6 : 0,
                        y: motionEnabled && hovering ? -4 : 0
                    )
                    .animation(.spring(response: 0.35, dampingFraction: 0.65), value: hovering)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
