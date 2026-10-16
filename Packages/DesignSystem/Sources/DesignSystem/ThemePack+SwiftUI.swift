// ThemePack+SwiftUI — the runtime-switch glue: an observable store + environment injectors (R-DS-4.1).
//
// The `ThemePackRegistry` value holds the loaded packs and the selection; this file makes switching the
// selected pack a *live* UI operation with no restart (R-DS-4.1). A `@MainActor` observable
// `ThemePackStore` wraps the registry; when the app calls `store.select(id)`, the new pack's `TableTheme`,
// deck style, and card back flow into the environment through the `.tableTheme` / `.deckStyle` /
// `.cardBack` values, and every table view re-renders. The `.tableTheme` key already lives in
// `TableTheme+SwiftUI.swift`; this file adds the matching `.deckStyle` / `.cardBack` keys and the
// convenience modifier that applies a whole pack at once.

import SwiftUI

// MARK: - Observable store (the switchable selection — R-DS-4.1)

/// A `@MainActor` observable wrapper around a `ThemePackRegistry` for live theme switching (R-DS-4.1).
///
/// The app owns one store, seeds it from a `ThemePackRegistry` (typically
/// `ThemePackRegistry.loadingDirectory(...)`), and calls `select(_:)` when the player picks a theme in
/// Settings. Views observe `selected` and re-render — no restart needed.
@MainActor
@Observable
public final class ThemePackStore {
    /// The underlying registry (packs + current selection).
    public private(set) var registry: ThemePackRegistry

    public init(registry: ThemePackRegistry) {
        self.registry = registry
    }

    /// The loaded packs, in presentation order (for a Settings picker).
    public var packs: [ThemePack] { registry.packs }

    /// The currently selected pack.
    public var selected: ThemePack { registry.selected }

    /// The id of the selected pack.
    public var selectedID: String { registry.selectedID }

    /// Switch the selected theme pack at runtime; observing views re-render (R-DS-4.1). No-op for an
    /// unknown id.
    public func select(_ id: String) {
        registry.select(id)
    }
}

// MARK: - Deck-style / card-back environment keys (companions to `.tableTheme`)

/// The environment key carrying the current deck style. Defaults to Classic.
private struct DeckStyleKey: EnvironmentKey {
    static let defaultValue: DeckStyle = .default
}

/// The environment key carrying the current card back. Defaults to Lattice.
private struct CardBackKey: EnvironmentKey {
    static let defaultValue: CardBack = .default
}

extension EnvironmentValues {
    /// The current deck-face style. The app sets it (from the selected theme pack or the Settings
    /// override); TableKit renders cached vector faces from it (R-TABLE-2.1). Runtime-switchable
    /// (task 5.4).
    public var deckStyle: DeckStyle {
        get { self[DeckStyleKey.self] }
        set { self[DeckStyleKey.self] = newValue }
    }

    /// The current card back for face-down cards. The app sets it (from the selected pack or a Settings
    /// override). Runtime-switchable (task 5.4).
    public var cardBack: CardBack {
        get { self[CardBackKey.self] }
        set { self[CardBackKey.self] = newValue }
    }
}

extension View {
    /// Inject a deck style into the environment for this subtree (runtime-switchable — task 5.4).
    public func deckStyle(_ style: DeckStyle) -> some View {
        environment(\.deckStyle, style)
    }

    /// Inject a card back into the environment for this subtree (runtime-switchable — task 5.4).
    public func cardBack(_ back: CardBack) -> some View {
        environment(\.cardBack, back)
    }

    /// Apply a whole theme pack at once — its table theme, default deck style, and default card back —
    /// so switching the selected pack re-themes the table live, without a restart (R-DS-4.1).
    public func themePack(_ pack: ThemePack) -> some View {
        self
            .tableTheme(pack.tableTheme)
            .deckStyle(pack.defaultDeckStyle)
            .cardBack(pack.defaultCardBack)
    }
}
