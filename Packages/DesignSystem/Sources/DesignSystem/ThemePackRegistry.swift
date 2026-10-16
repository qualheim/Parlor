// ThemePackRegistry — the runtime-switchable catalog of loaded theme packs (R-DS-4.1).
//
// The registry is the "loaded at runtime and switchable without a restart" half of R-DS-4.1: it holds
// the decoded `ThemePack`s and a *selected* pack that can be changed at any time. Because it is a pure,
// Foundation-only value (no SwiftUI/Metal), the whole load → select → switch behavior is verifiable
// headless in `swift test`; the SwiftUI glue that pushes the selection into the environment lives in
// `ThemePack+SwiftUI.swift`.
//
// Loading is *lenient*: `loadingDirectory` decodes every `Assets/ThemePacks/<id>/theme.json` it finds and
// SKIPS (rather than crashes on) any pack whose manifest is malformed, collecting the failures so the
// caller can log them (R-DS-4.1). If no packs load at all, the registry falls back to `built-in` packs
// synthesized from the DesignSystem catalog so the app always has a table to render.

import Foundation

/// A runtime, switchable catalog of theme packs (R-DS-4.1).
///
/// Order is preserved (packs appear in Settings in load order). One pack is always `selected`; changing
/// the selection is how a live theme switch happens (no restart — R-DS-4.1).
public struct ThemePackRegistry: Sendable, Hashable {
    /// The loaded packs, in presentation order. Never empty (a fallback built-in pack is always present).
    public private(set) var packs: [ThemePack]
    /// The id of the currently selected pack. Always the id of a member of `packs`.
    public private(set) var selectedID: String

    /// Create a registry from already-resolved packs. If `packs` is empty, the built-in fallback packs
    /// are used instead so the registry is never empty. The selection defaults to the first pack unless a
    /// valid `selectedID` is given.
    public init(packs: [ThemePack], selectedID: String? = nil) {
        let resolved = packs.isEmpty ? ThemePackRegistry.builtIn : packs
        self.packs = resolved
        if let selectedID, resolved.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            self.selectedID = resolved[0].id
        }
    }

    /// The currently selected pack (always present).
    public var selected: ThemePack {
        packs.first { $0.id == selectedID } ?? packs[0]
    }

    /// Look up a loaded pack by id.
    public func pack(id: String) -> ThemePack? {
        packs.first { $0.id == id }
    }

    /// Switch the selected pack at runtime (R-DS-4.1). No-op if `id` is not a loaded pack, so an invalid
    /// selection can never leave the registry without a valid theme.
    public mutating func select(_ id: String) {
        guard packs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// A copy with a different selected pack (value-type convenience for the switch).
    public func selecting(_ id: String) -> ThemePackRegistry {
        var copy = self
        copy.select(id)
        return copy
    }
}

// MARK: - Loading from disk (R-DS-4.1)

extension ThemePackRegistry {
    /// The result of a lenient directory load: the packs that decoded, plus the ones that failed.
    public struct LoadReport: Sendable {
        /// The registry built from every pack that decoded successfully (falls back to built-ins if none).
        public let registry: ThemePackRegistry
        /// The manifests that failed to decode, keyed by the folder/path that produced them.
        public let failures: [(source: String, error: ThemePackError)]

        public init(
            registry: ThemePackRegistry, failures: [(source: String, error: ThemePackError)]
        ) {
            self.registry = registry
            self.failures = failures
        }
    }

    /// Load every `theme.json` under `directory` (one `<id>/theme.json` per pack), skipping malformed
    /// packs and reporting them (R-DS-4.1).
    ///
    /// The manifest file inside each pack folder is `theme.json` by default. A pack that fails to decode
    /// is left out of the registry and recorded in `failures` — a bad pack never crashes the load.
    public static func loadingDirectory(
        _ directory: URL,
        manifestName: String = "theme.json",
        selectedID: String? = nil,
        decoder: ThemePackDecoder = ThemePackDecoder()
    ) -> LoadReport {
        let fm = FileManager.default
        var packs: [ThemePack] = []
        var failures: [(source: String, error: ThemePackError)] = []

        let subdirs =
            (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]))
            ?? []

        // Deterministic order (by folder name) so Settings order is stable across runs.
        for folder in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir =
                (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let manifestURL = folder.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            switch decoder.decode(data) {
            case let .success(pack):
                packs.append(pack)
            case let .failure(error):
                failures.append((source: folder.lastPathComponent, error: error))
            }
        }

        let registry = ThemePackRegistry(packs: packs, selectedID: selectedID)
        return LoadReport(registry: registry, failures: failures)
    }
}

// MARK: - Built-in fallback packs

extension ThemePackRegistry {
    /// Built-in packs synthesized from the DesignSystem catalog, used when no manifests load so the app
    /// always has a table to render (R-DS-4.1). Each mirrors a `TableTheme` and offers the full built-in
    /// deck-style / card-back catalogs; all are flagged `placeholder` until production art ships
    /// (R-DS-4.2, R-DS-6).
    public static let builtIn: [ThemePack] = TableTheme.all.map { theme in
        ThemePack(
            id: theme.id,
            displayName: theme.displayName,
            tableTheme: theme,
            deckStyles: DeckStyle.all,
            cardBacks: CardBack.all,
            audio: [:],
            placeholder: true
        )
    }
}
