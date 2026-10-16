import Foundation
import Testing

@testable import Persistence

/// Compare everything EXCEPT the profile id, which `AppSettings.defaults` mints fresh on every access
/// (a new local profile gets a unique `ProfileID`). The settings-group values are what "is this the
/// default surface?" means; the profile identity is intentionally not stable across two `.defaults`.
private func hasDefaultSettingsGroups(_ settings: AppSettings) -> Bool {
    settings.appearance == .defaults
        && settings.gameplay == .defaults
        && settings.sound == .defaults
        && settings.accessibility == .defaults
}

// Settings — task 6.4 (R-APP-5.1). Covers the defaults for every group, the JSON round-trip through the
// codec and the store, clamping of sound levels on decode, unknown-enum fallback to defaults, degrading a
// corrupt payload to defaults, and the mutate-and-persist flow through a `SettingsStore`.

@Suite("AppSettings defaults")
struct AppSettingsDefaultsTests {
    @Test("defaults populate every group with sensible values")
    func defaultsPopulated() {
        let settings = AppSettings.defaults
        #expect(settings.appearance.cardSize == .medium)
        #expect(settings.appearance.themePackID == "classic-felt")
        #expect(settings.gameplay.animationSpeed == .normal)
        #expect(settings.gameplay.aiPace == .normal)
        #expect(settings.gameplay.autoMoves == .safe)
        #expect(settings.gameplay.hintsEnabled)
        #expect(settings.gameplay.confirmationsEnabled)
        #expect(settings.sound.masterMuted == false)
        #expect(settings.accessibility.fourColorDeck == false)
        #expect(settings.profile.controllerKind == .localHuman)
    }

    @Test("card size covers exactly S/M/L/XL")
    func cardSizeCases() {
        #expect(CardSize.allCases.map(\.rawValue) == ["S", "M", "L", "XL"])
    }
}

@Suite("AppSettings round-trip")
struct AppSettingsRoundTripTests {
    private let codec = SettingsCodec()

    @Test("a fully-populated settings value round-trips through the codec unchanged")
    func roundTrip() throws {
        var settings = AppSettings.defaults
        settings.appearance = AppearanceSettings(
            themePackID: "midnight",
            deckStyleID: "four-color",
            cardBackID: "back-3",
            cardSize: .extraLarge)
        settings.gameplay = GameplaySettings(
            animationSpeed: .fast,
            aiPace: .relaxed,
            autoMoves: .always,
            hintsEnabled: false,
            confirmationsEnabled: false)
        settings.sound = SoundSettings(effectsLevel: 0.3, ambienceLevel: 0.7, masterMuted: true)
        settings.accessibility = AccessibilitySettings(
            forceReduceMotion: true, highContrastCards: true, fourColorDeck: true)

        let data = try codec.encode(settings)
        let decoded = try codec.decode(from: data)
        #expect(decoded == settings)
    }
}

@Suite("AppSettings validation on decode")
struct AppSettingsValidationTests {
    private let codec = SettingsCodec()

    @Test("sound levels are clamped to 0...1 on decode")
    func soundClampedOnDecode() throws {
        let json = """
            {"sound": {"effectsLevel": 5.0, "ambienceLevel": -2.0, "masterMuted": false}}
            """
        let decoded = try codec.decode(from: Data(json.utf8))
        #expect(decoded.sound.effectsLevel == 1.0)
        #expect(decoded.sound.ambienceLevel == 0.0)
    }

    @Test("an unknown enum raw value falls back to that enum's default")
    func unknownEnumFallsBack() throws {
        let json = """
            {"appearance": {"cardSize": "HUGE"},
             "gameplay": {"animationSpeed": "warp", "aiPace": "sluggish", "autoMoves": "maybe"}}
            """
        let decoded = try codec.decode(from: Data(json.utf8))
        #expect(decoded.appearance.cardSize == .medium)
        #expect(decoded.gameplay.animationSpeed == .normal)
        #expect(decoded.gameplay.aiPace == .normal)
        #expect(decoded.gameplay.autoMoves == .safe)
    }

    @Test("an empty JSON object decodes to full defaults")
    func emptyObjectDecodesToDefaults() throws {
        let decoded = try codec.decode(from: Data("{}".utf8))
        #expect(hasDefaultSettingsGroups(decoded))
    }

    @Test("SoundSettings init clamps levels out of range")
    func soundInitClamps() {
        let sound = SoundSettings(effectsLevel: 2.0, ambienceLevel: -1.0, masterMuted: false)
        #expect(sound.effectsLevel == 1.0)
        #expect(sound.ambienceLevel == 0.0)
    }
}

@Suite("SandboxSettingsStore on disk")
struct SandboxSettingsStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a missing settings file loads as defaults")
    func missingFileLoadsDefaults() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SandboxSettingsStore(directory: dir)
        #expect(hasDefaultSettingsGroups(try store.load()))
    }

    @Test("save then load round-trips through the real disk path")
    func saveThenLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SandboxSettingsStore(directory: dir)
        var settings = AppSettings.defaults
        settings.appearance.cardSize = .large
        settings.sound.masterMuted = true
        try store.save(settings)
        #expect(try store.load() == settings)
    }

    @Test("a corrupt (non-JSON) file degrades to defaults instead of throwing")
    func corruptFileDegradesToDefaults() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("Settings.json", isDirectory: false)
        try Data("this is not json {{{".utf8).write(to: fileURL)
        let store = try SandboxSettingsStore(directory: dir)
        #expect(hasDefaultSettingsGroups(try store.load()))
    }
}

@Suite("SettingsStore mutate-and-persist")
struct SettingsStoreMutateTests {
    @Test("mutating a loaded value and saving it persists through an in-memory store")
    func mutateAndPersist() throws {
        let store = InMemorySettingsStore()
        var settings = try store.load()
        #expect(hasDefaultSettingsGroups(settings))

        settings.gameplay.hintsEnabled = false
        settings.appearance.deckStyleID = "modern"
        settings.profile.displayName = "Ada"
        try store.save(settings)

        let reloaded = try store.load()
        #expect(reloaded.gameplay.hintsEnabled == false)
        #expect(reloaded.appearance.deckStyleID == "modern")
        #expect(reloaded.profile.displayName == "Ada")
    }
}
