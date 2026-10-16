// ThemePackDecoder — parse + validate a theme-pack manifest into a resolved `ThemePack` (R-DS-4.1).
//
// This is the runtime loader's core: it turns raw manifest JSON (either bytes or an already-decoded
// `ThemePackManifest`) into a `ThemePack` of DesignSystem values, or a typed `ThemePackError` describing
// exactly what was wrong. It NEVER traps on malformed input — an unknown material, a bad hex color, an
// unsupported schema version, an empty deck/back list, or a deck/back id with no matching built-in all
// return a descriptive error the caller can surface (or skip that pack) without crashing (R-DS-4.1).
//
// The loader is Foundation-only so it runs headless in `swift test`; the SwiftUI/registry glue that makes
// theme switching live-without-restart sits on top of it (`ThemePackRegistry`, `ThemePack+SwiftUI`).
//
// Asset-reference mapping (R-DS-4.2): the manifest names deck styles, card backs, shader source, and
// audio by *id/path*, so replacing a placeholder pack's files with commissioned production art needs no
// code change — the ids stay the same and only `placeholder` flips to `false`.

import Foundation

/// A typed, human-readable failure from decoding a theme pack. Returned instead of crashing so a
/// malformed pack can be reported or skipped at runtime (R-DS-4.1).
public enum ThemePackError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The manifest JSON could not be decoded into the manifest shape at all (with the underlying reason).
    case malformedManifest(reason: String)
    /// The manifest's `schemaVersion` is not the version this loader understands.
    case unsupportedSchemaVersion(found: Int, expected: Int)
    /// The manifest `id` (or another required string) was empty.
    case emptyIdentifier(field: String)
    /// The `table.material` name is not one of `felt` / `wood` / `matte`.
    case unknownMaterial(String)
    /// A color string was not a valid `#RRGGBB` (or `#RGB`) hex value.
    case invalidColor(field: String, value: String)
    /// The pack listed no deck styles, or no card backs.
    case emptyDeckList(field: String)
    /// A deck-style id or card-back id in the manifest has no matching built-in in the catalog.
    case unknownReference(kind: String, id: String)

    public var description: String {
        switch self {
        case let .malformedManifest(reason):
            return "malformed theme-pack manifest: \(reason)"
        case let .unsupportedSchemaVersion(found, expected):
            return "unsupported theme-pack schemaVersion \(found) (expected \(expected))"
        case let .emptyIdentifier(field):
            return "theme-pack \(field) must not be empty"
        case let .unknownMaterial(name):
            return "unknown table material '\(name)' (expected felt, wood, or matte)"
        case let .invalidColor(field, value):
            return "invalid color for \(field): '\(value)' is not a #RRGGBB hex value"
        case let .emptyDeckList(field):
            return "theme-pack decks.\(field) must list at least one entry"
        case let .unknownReference(kind, id):
            return "theme-pack references unknown \(kind) '\(id)'"
        }
    }
}

/// Decodes and validates theme-pack manifests into resolved `ThemePack` values (R-DS-4.1).
///
/// Stateless and `Sendable`; safe to use from any actor. All entry points return `Result` so callers can
/// load a directory of packs and skip (rather than crash on) any malformed one.
public struct ThemePackDecoder: Sendable {
    public init() {}

    /// Decode raw manifest JSON bytes into a resolved `ThemePack` (R-DS-4.1).
    public func decode(_ data: Data) -> Result<ThemePack, ThemePackError> {
        let manifest: ThemePackManifest
        do {
            manifest = try JSONDecoder().decode(ThemePackManifest.self, from: data)
        } catch {
            return .failure(.malformedManifest(reason: "\(error)"))
        }
        return resolve(manifest)
    }

    /// Resolve an already-decoded manifest into a `ThemePack`, validating every field (R-DS-4.1).
    public func resolve(_ manifest: ThemePackManifest) -> Result<ThemePack, ThemePackError> {
        // Schema version gate — refuse formats we don't understand rather than mis-decode (design.md §7).
        guard manifest.schemaVersion == themePackSchemaVersion else {
            return .failure(
                .unsupportedSchemaVersion(
                    found: manifest.schemaVersion, expected: themePackSchemaVersion))
        }
        guard !manifest.id.isEmpty else { return .failure(.emptyIdentifier(field: "id")) }
        guard !manifest.displayName.isEmpty else {
            return .failure(.emptyIdentifier(field: "displayName"))
        }

        // Material.
        guard let material = TableMaterial(rawValue: manifest.table.material) else {
            return .failure(.unknownMaterial(manifest.table.material))
        }

        // Colors.
        let base: TokenColor
        let accent: TokenColor
        let shadowInk: TokenColor
        switch Self.parseColor(manifest.table.base, field: "table.base") {
        case let .success(c): base = c
        case let .failure(e): return .failure(e)
        }
        switch Self.parseColor(manifest.table.accent, field: "table.accent") {
        case let .success(c): accent = c
        case let .failure(e): return .failure(e)
        }
        switch Self.parseColor(manifest.table.shadowInk, field: "table.shadowInk") {
        case let .success(c): shadowInk = c
        case let .failure(e): return .failure(e)
        }

        // Deck styles / card backs must be non-empty and resolvable against the built-in catalogs.
        guard !manifest.decks.styles.isEmpty else {
            return .failure(.emptyDeckList(field: "styles"))
        }
        guard !manifest.decks.backs.isEmpty else {
            return .failure(.emptyDeckList(field: "backs"))
        }
        var deckStyles: [DeckStyle] = []
        for id in manifest.decks.styles {
            guard let style = DeckStyle.style(id: id) else {
                return .failure(.unknownReference(kind: "deck style", id: id))
            }
            deckStyles.append(style)
        }
        var cardBacks: [CardBack] = []
        for id in manifest.decks.backs {
            guard let back = CardBack.back(id: id) else {
                return .failure(.unknownReference(kind: "card back", id: id))
            }
            cardBacks.append(back)
        }

        let parameters = MaterialParameters(
            base: base,
            accent: accent,
            grainScale: manifest.table.grainScale,
            grainStrength: manifest.table.grainStrength,
            sheenStrength: manifest.table.sheenStrength,
            vignette: manifest.table.vignette
        )
        let theme = TableTheme(
            id: manifest.id,
            displayName: manifest.displayName,
            material: material,
            parameters: parameters,
            shadowInk: shadowInk
        )
        let pack = ThemePack(
            id: manifest.id,
            displayName: manifest.displayName,
            tableTheme: theme,
            deckStyles: deckStyles,
            cardBacks: cardBacks,
            audio: manifest.audio ?? [:],
            placeholder: manifest.placeholder
        )
        return .success(pack)
    }

    // MARK: - Hex color parsing

    /// Parse a `#RRGGBB` (or `#RGB`) hex color string into a `TokenColor`, or a typed error.
    ///
    /// Accepts an optional leading `#`. `#RGB` shorthand expands each nibble (e.g. `#0af` → `#00aaff`).
    /// Any other length or a non-hex digit is a typed `invalidColor` failure — never a trap (R-DS-4.1).
    static func parseColor(_ raw: String, field: String) -> Result<TokenColor, ThemePackError> {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let hexDigits = s.uppercased()

        func fail() -> Result<TokenColor, ThemePackError> {
            .failure(.invalidColor(field: field, value: raw))
        }
        guard hexDigits.allSatisfy(\.isHexDigit) else { return fail() }

        let expanded: String
        switch hexDigits.count {
        case 6:
            expanded = hexDigits
        case 3:
            // #RGB → #RRGGBB
            expanded = hexDigits.map { "\($0)\($0)" }.joined()
        default:
            return fail()
        }
        guard let value = UInt32(expanded, radix: 16) else { return fail() }
        return .success(TokenColor(hex: value))
    }
}
