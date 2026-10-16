import Foundation
import Testing

@testable import DesignSystem

/// Tests for the theme-pack loader: manifest decode, validation, malformed-input handling, and the
/// runtime-switchable registry (R-DS-4.1, R-DS-4.2; design.md §7).
@Suite("Theme packs")
struct ThemePackTests {
    // MARK: - Fixtures

    /// A well-formed manifest matching the on-disk `walnut-parlor/theme.json` shape.
    static func validManifestJSON(
        id: String = "walnut-parlor",
        schemaVersion: Int = themePackSchemaVersion,
        material: String = "wood",
        base: String = "#5A3A22",
        placeholder: Bool = true
    ) -> Data {
        """
        {
          "schemaVersion": \(schemaVersion),
          "id": "\(id)",
          "displayName": "Walnut Parlor",
          "table": {
            "material": "\(material)",
            "shader": "parlorWood",
            "base": "\(base)",
            "accent": "#3A2414",
            "grainScale": 90,
            "grainStrength": 0.50,
            "sheenStrength": 0.35,
            "vignette": 0.25,
            "shadowInk": "#1A0E06"
          },
          "decks": {
            "styles": ["classic", "modern", "four-color", "jumbo-index"],
            "backs": ["lattice", "art-deco", "linen", "checker", "wave", "crest"]
          },
          "assets": { "kind": "procedural", "shaderSource": "Shaders/TableMaterials.metal" },
          "placeholder": \(placeholder)
        }
        """.data(using: .utf8)!
    }

    private let decoder = ThemePackDecoder()

    // MARK: - Decode → resolve (R-DS-4.1)

    @Test("a well-formed manifest decodes into a resolved pack mapping to DesignSystem models")
    func decodeValid() throws {
        let pack = try decoder.decode(Self.validManifestJSON()).get()
        #expect(pack.id == "walnut-parlor")
        #expect(pack.displayName == "Walnut Parlor")
        #expect(pack.tableTheme.material == .wood)
        // Colors parsed from hex map onto TokenColor exactly.
        #expect(pack.tableTheme.parameters.base == TokenColor(hex: 0x5A3A22))
        #expect(pack.tableTheme.shadowInk == TokenColor(hex: 0x1A0E06))
        // Deck styles / backs resolve to the built-in catalog values, in manifest order.
        #expect(pack.deckStyles == DeckStyle.all)
        #expect(pack.cardBacks == CardBack.all)
        #expect(pack.placeholder)
    }

    @Test(
        "the resolved table theme matches the built-in catalog entry (manifest mirrors TableTheme.all)"
    )
    func decodeMirrorsCatalog() throws {
        let pack = try decoder.decode(Self.validManifestJSON()).get()
        #expect(pack.tableTheme == TableTheme.walnutParlor)
    }

    @Test("a #RGB shorthand color expands correctly")
    func rgbShorthand() {
        switch ThemePackDecoder.parseColor("#0af", field: "x") {
        case let .success(color):
            #expect(color == TokenColor(hex: 0x00AAFF))
        case .failure:
            Issue.record("expected #0af to parse")
        }
    }

    @Test("a bare (unprefixed) hex color parses")
    func bareHex() {
        switch ThemePackDecoder.parseColor("1B5E20", field: "x") {
        case let .success(color):
            #expect(color == TokenColor(hex: 0x1B5E20))
        case .failure:
            Issue.record("expected bare hex to parse")
        }
    }

    // MARK: - Graceful malformed handling (R-DS-4.1 — never crash)

    @Test("unparseable JSON is a typed malformedManifest error, not a crash")
    func malformedJSON() {
        let data = Data("{ not json ".utf8)
        switch decoder.decode(data) {
        case .success: Issue.record("expected malformed JSON to fail")
        case let .failure(error):
            if case .malformedManifest = error {} else { Issue.record("wrong error: \(error)") }
        }
    }

    @Test("an unsupported schema version is rejected with a typed error")
    func unsupportedSchema() {
        let data = Self.validManifestJSON(schemaVersion: 999)
        switch decoder.decode(data) {
        case .success: Issue.record("expected schema-version rejection")
        case let .failure(error):
            #expect(
                error == .unsupportedSchemaVersion(found: 999, expected: themePackSchemaVersion))
        }
    }

    @Test("an unknown material is rejected with a typed error")
    func unknownMaterial() {
        let data = Self.validManifestJSON(material: "velvet")
        switch decoder.decode(data) {
        case .success: Issue.record("expected unknown-material rejection")
        case let .failure(error):
            #expect(error == .unknownMaterial("velvet"))
        }
    }

    @Test("an invalid color is rejected with a typed error naming the field")
    func invalidColor() {
        let data = Self.validManifestJSON(base: "#ZZZ")
        switch decoder.decode(data) {
        case .success: Issue.record("expected invalid-color rejection")
        case let .failure(error):
            if case let .invalidColor(field, _) = error {
                #expect(field == "table.base")
            } else {
                Issue.record("wrong error: \(error)")
            }
        }
    }

    @Test("an empty id is rejected")
    func emptyID() {
        let data = Self.validManifestJSON(id: "")
        switch decoder.decode(data) {
        case .success: Issue.record("expected empty-id rejection")
        case let .failure(error): #expect(error == .emptyIdentifier(field: "id"))
        }
    }

    @Test("a deck style / card back id with no built-in match is rejected")
    func unknownReference() throws {
        let manifest = ThemePackManifest(
            schemaVersion: themePackSchemaVersion,
            id: "x",
            displayName: "X",
            table: .init(
                material: "felt", base: "#111111", accent: "#222222",
                grainScale: 100, grainStrength: 0.3, sheenStrength: 0.1, vignette: 0.3,
                shadowInk: "#000000"),
            decks: .init(styles: ["not-a-style"], backs: ["lattice"]),
            assets: .init(kind: "procedural"),
            placeholder: true)
        switch decoder.resolve(manifest) {
        case .success: Issue.record("expected unknown-reference rejection")
        case let .failure(error):
            #expect(error == .unknownReference(kind: "deck style", id: "not-a-style"))
        }
    }

    @Test("an empty deck list is rejected")
    func emptyDeckList() {
        let manifest = ThemePackManifest(
            schemaVersion: themePackSchemaVersion,
            id: "x", displayName: "X",
            table: .init(
                material: "felt", base: "#111111", accent: "#222222",
                grainScale: 100, grainStrength: 0.3, sheenStrength: 0.1, vignette: 0.3,
                shadowInk: "#000000"),
            decks: .init(styles: [], backs: ["lattice"]),
            assets: .init(kind: "procedural"),
            placeholder: true)
        switch decoder.resolve(manifest) {
        case .success: Issue.record("expected empty-deck rejection")
        case let .failure(error): #expect(error == .emptyDeckList(field: "styles"))
        }
    }

    // MARK: - Runtime-switchable registry (R-DS-4.1)

    @Test("the registry is never empty and always has a valid selection")
    func registryNeverEmpty() {
        let empty = ThemePackRegistry(packs: [])
        #expect(!empty.packs.isEmpty)
        #expect(empty.pack(id: empty.selectedID) != nil)
        #expect(empty.packs == ThemePackRegistry.builtIn)
    }

    @Test("selecting a loaded pack switches the current theme at runtime")
    func runtimeSwitch() throws {
        let packs = try Self.builtInResolved()
        var registry = ThemePackRegistry(packs: packs)
        let first = registry.selectedID
        // Pick a different pack and confirm the selection (and its theme) actually changes.
        let other = packs.first { $0.id != first }!
        registry.select(other.id)
        #expect(registry.selectedID == other.id)
        #expect(registry.selected.id == other.id)
        #expect(registry.selected.tableTheme == other.tableTheme)
        #expect(registry.selected.tableTheme != packs.first { $0.id == first }!.tableTheme)
    }

    @Test("selecting an unknown pack is a no-op, leaving a valid selection")
    func selectUnknownIsNoOp() {
        var registry = ThemePackRegistry(packs: ThemePackRegistry.builtIn)
        let before = registry.selectedID
        registry.select("does-not-exist")
        #expect(registry.selectedID == before)
    }

    @Test("an explicit valid selectedID is honored at construction")
    func honorSelectedID() {
        let registry = ThemePackRegistry(
            packs: ThemePackRegistry.builtIn, selectedID: "walnut-parlor")
        #expect(registry.selectedID == "walnut-parlor")
    }

    // MARK: - Placeholder flagging (R-DS-4.2)

    @Test("built-in fallback packs are all flagged needs-production-art")
    func builtInsArePlaceholders() {
        #expect(!ThemePackRegistry.builtIn.isEmpty)
        #expect(ThemePackRegistry.builtIn.allSatisfy { $0.placeholder })
        #expect(DesignSystem.builtInThemePacks == ThemePackRegistry.builtIn)
    }

    // MARK: - The shipped on-disk manifests (R-DS-4.1, R-DS-4.2)

    @Test("every shipped Assets/ThemePacks manifest decodes and is flagged placeholder")
    func shippedManifestsDecode() throws {
        let dir = try Self.themePacksDirectory()
        let report = ThemePackRegistry.loadingDirectory(dir)
        // No manifest should have failed to decode.
        let failedSources = report.failures.map { $0.source }
        #expect(report.failures.isEmpty, "malformed shipped manifests: \(failedSources)")
        let ids = Set(report.registry.packs.map(\.id))
        #expect(ids.isSuperset(of: ["classic-felt", "midnight", "walnut-parlor", "minimal"]))
        // Every shipped pack is still placeholder art (R-DS-4.2).
        #expect(report.registry.packs.allSatisfy { $0.placeholder })
    }

    @Test("loading a directory skips a malformed pack and reports it, keeping the good ones")
    func lenientLoadSkipsMalformed() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-packs-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tmp) }
        // One good pack.
        let good = tmp.appendingPathComponent("walnut-parlor")
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        try Self.validManifestJSON().write(to: good.appendingPathComponent("theme.json"))
        // One malformed pack.
        let bad = tmp.appendingPathComponent("broken")
        try fm.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: bad.appendingPathComponent("theme.json"))

        let report = ThemePackRegistry.loadingDirectory(tmp)
        #expect(report.registry.pack(id: "walnut-parlor") != nil)
        #expect(report.failures.contains { $0.source == "broken" })
    }

    @Test("packs round-trip through Codable unchanged")
    func packsCodableRoundTrip() throws {
        let packs = try Self.builtInResolved()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for pack in packs {
            let data = try encoder.encode(pack)
            let restored = try decoder.decode(ThemePack.self, from: data)
            #expect(restored == pack)
        }
    }

    // MARK: - Helpers

    /// The four shipped manifests, decoded from disk (used where resolved packs are needed).
    static func builtInResolved() throws -> [ThemePack] {
        let dir = try themePacksDirectory()
        let report = ThemePackRegistry.loadingDirectory(dir)
        return report.registry.packs
    }

    /// Locate the repo's `Assets/ThemePacks` directory by walking up from this test source file.
    static func themePacksDirectory() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Assets/ThemePacks")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw ThemePackTestError.assetsDirectoryNotFound
    }

    enum ThemePackTestError: Error { case assetsDirectoryNotFound }
}
