// App settings — the full settings surface (R-APP-5.1), modeled as one Codable value with sensible
// defaults, plus the store/codec seam that mirrors SaveStore.swift / StatisticsStore.swift.
//
// This is the DATA MODEL + STORAGE only. Persistence imports no UI framework (design.md §1), so nothing
// here references SwiftUI, TableKit, or DesignSystem. Instead the settings groups are modeled as
// framework-independent values (enums / Doubles / Bool), and the App maps them onto its own runtime types
// (TableKit's `AnimationSpeed`, DesignSystem's `SoundMix`, the environment card-size override, etc.). Each
// mapping is documented on the type so the App knows what a value means without importing anything back
// into Persistence.
//
// Layout mirrors the other stores so the persistence seams stay consistent:
//
//   • `AppSettings` — one `Codable` value holding every settings group, with `.defaults`.
//   • `SettingsStore` — a protocol for the raw I/O of the WHOLE settings value (load / save).
//   • `SandboxSettingsStore` — the production conformer: ONE JSON file in the app's sandbox container
//     (Application Support) and ONLY there — no cloud (R-PERS-3.1). Atomic write, created on demand, a
//     missing OR CORRUPT file loads as `.defaults` so an edited/damaged file never crashes the app.
//   • `InMemorySettingsStore` — a lock-guarded conformer for headless tests and previews.
//   • `SettingsCodec` — bytes ⇄ `AppSettings`, kept separate so the JSON round-trip is testable without a
//     file system (same split as `SaveCodec` / `StatisticsCodec`).
//
// VALIDATION / CLAMPING (robustness). `AppSettings` validates on decode so a hand-edited or corrupt file
// can never carry a nonsense value into the app: sound levels are clamped to `0...1`, and every enum
// decodes via its raw string with an unknown value falling back to that enum's default rather than
// throwing. `SettingsCodec.decode` returns a fully-valid, in-range `AppSettings` for any JSON object, and
// `SandboxSettingsStore.load` degrades a genuinely corrupt (non-JSON) payload to `.defaults` too — the
// app keeps running with defaults instead of crashing.

import Foundation

// MARK: - Appearance settings (R-APP-5.1)

/// Physical card size — also the accessibility card-size override (R-APP-5.1, R-A11Y-4.1).
///
/// The App maps a case to a concrete point size / scale for the card views and, since this doubles as the
/// accessibility override, feeds it into the environment the renderer reads. Raw-string `Codable` so the
/// on-disk form is stable and readable; `CaseIterable` so the App can list the four choices.
public enum CardSize: String, Codable, Sendable, CaseIterable, Equatable {
    case small = "S"
    case medium = "M"
    case large = "L"
    case extraLarge = "XL"

    /// The default card size — Medium.
    public static var `default`: CardSize { .medium }
}

/// The appearance group: which theme pack, deck style, and card back are selected, plus the card size
/// (R-APP-5.1).
///
/// The three ids are opaque handles the App resolves against DesignSystem's registries (theme packs, deck
/// styles, card backs); Persistence stores them as plain strings and does not validate that a given id
/// still exists — the App falls back if a pack was removed. `cardSize` is the accessibility override
/// (R-A11Y-4.1).
public struct AppearanceSettings: Codable, Sendable, Equatable {
    /// Selected theme-pack id (e.g. "classic-felt"). Opaque handle resolved by the App.
    public var themePackID: String
    /// Selected deck-style id (e.g. "classic"). Opaque handle resolved by the App.
    public var deckStyleID: String
    /// Selected card-back id (e.g. "back-1"). Opaque handle resolved by the App.
    public var cardBackID: String
    /// Physical card size / accessibility card-size override (R-A11Y-4.1).
    public var cardSize: CardSize

    public init(
        themePackID: String = "classic-felt",
        deckStyleID: String = "classic",
        cardBackID: String = "classic-back",
        cardSize: CardSize = .default
    ) {
        self.themePackID = themePackID
        self.deckStyleID = deckStyleID
        self.cardBackID = cardBackID
        self.cardSize = cardSize
    }

    /// The default appearance.
    public static var defaults: AppearanceSettings { AppearanceSettings() }

    enum CodingKeys: String, CodingKey {
        case themePackID, deckStyleID, cardBackID, cardSize
    }

    /// Tolerant decode: absent ids default, and an unknown `cardSize` raw value falls back to the default
    /// rather than throwing (so an edited/corrupt file never crashes).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let theme =
            try container.decodeIfPresent(String.self, forKey: .themePackID) ?? "classic-felt"
        let deck =
            try container.decodeIfPresent(String.self, forKey: .deckStyleID) ?? "classic"
        let back =
            try container.decodeIfPresent(String.self, forKey: .cardBackID) ?? "classic-back"
        let size = decodeEnum(CardSize.self, in: container, forKey: .cardSize, default: .default)
        self.init(themePackID: theme, deckStyleID: deck, cardBackID: back, cardSize: size)
    }
}

// MARK: - Gameplay settings (R-APP-5.1)

/// The animation-speed setting (R-APP-5.1, R-TABLE-5.1).
///
/// An equivalent of TableKit's `AnimationSpeed`, modeled independently because Persistence cannot import
/// TableKit (dependency direction, R-BUILD-1.3). The App maps a case one-to-one onto TableKit's
/// `AnimationSpeed` when it configures the animation queue. Raw-string `Codable`.
public enum AnimationSpeedSetting: String, Codable, Sendable, CaseIterable, Equatable {
    case relaxed
    case normal
    case fast
    case instant

    /// The default animation speed — Normal.
    public static var `default`: AnimationSpeedSetting { .normal }
}

/// The AI pacing setting (R-APP-5.1, R-AI-6.1) — how long an AI seat appears to "think".
///
/// Independent of `AnimationSpeedSetting` (R-AI-6.1 requires AI pacing be separate from animation speed).
/// The App maps a case onto AIKit's pacing. Raw-string `Codable`.
public enum AIPaceSetting: String, Codable, Sendable, CaseIterable, Equatable {
    case instant
    case fast
    case normal
    case relaxed

    /// The default AI pace — Normal.
    public static var `default`: AIPaceSetting { .normal }
}

/// The auto-move policy for Klondike (R-APP-5.1, R-KLON-3.2): never, only safe moves, or always.
///
/// Mirrors the Klondike auto-move option modeled in the Games layer; kept here as an independent enum so
/// settings can round-trip it without importing Games. Raw-string `Codable`.
public enum AutoMoveSetting: String, Codable, Sendable, CaseIterable, Equatable {
    case off
    case safe
    case always

    /// The default auto-move policy — Safe.
    public static var `default`: AutoMoveSetting { .safe }
}

/// The gameplay group: animation speed, AI pace, auto-moves, hints, confirmations (R-APP-5.1).
public struct GameplaySettings: Codable, Sendable, Equatable {
    /// How fast table animations play (R-TABLE-5.1).
    public var animationSpeed: AnimationSpeedSetting
    /// How long AI seats appear to think (R-AI-6.1, independent of `animationSpeed`).
    public var aiPace: AIPaceSetting
    /// Klondike auto-move policy (R-KLON-3.2).
    public var autoMoves: AutoMoveSetting
    /// Whether hints are offered (R-KLON-3.8).
    public var hintsEnabled: Bool
    /// Whether destructive/irreversible actions ask for confirmation first (per ux-guidelines.md).
    public var confirmationsEnabled: Bool
    /// Vegas cumulative bankroll: persists across games (R-KLON-2.2)
    public var vegasBankroll: Int

    public init(
        animationSpeed: AnimationSpeedSetting = .default,
        aiPace: AIPaceSetting = .default,
        autoMoves: AutoMoveSetting = .default,
        hintsEnabled: Bool = true,
        confirmationsEnabled: Bool = true,
        vegasBankroll: Int = 0
    ) {
        self.animationSpeed = animationSpeed
        self.aiPace = aiPace
        self.autoMoves = autoMoves
        self.hintsEnabled = hintsEnabled
        self.confirmationsEnabled = confirmationsEnabled
        self.vegasBankroll = vegasBankroll
    }

    /// The default gameplay settings.
    public static var defaults: GameplaySettings { GameplaySettings() }

    enum CodingKeys: String, CodingKey {
        case animationSpeed, aiPace, autoMoves, hintsEnabled, confirmationsEnabled, vegasBankroll
    }

    /// Tolerant decode: each field defaults if absent, and any unknown enum raw value falls back to that
    /// enum's default rather than throwing (so an edited/corrupt file never crashes).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let speed = decodeEnum(
            AnimationSpeedSetting.self, in: container, forKey: .animationSpeed, default: .default)
        let pace = decodeEnum(
            AIPaceSetting.self, in: container, forKey: .aiPace, default: .default)
        let auto = decodeEnum(
            AutoMoveSetting.self, in: container, forKey: .autoMoves, default: .default)
        let hints = try container.decodeIfPresent(Bool.self, forKey: .hintsEnabled) ?? true
        let confirmations =
            try container.decodeIfPresent(Bool.self, forKey: .confirmationsEnabled) ?? true
        self.init(
            animationSpeed: speed,
            aiPace: pace,
            autoMoves: auto,
            hintsEnabled: hints,
            confirmationsEnabled: confirmations)
    }
}

// MARK: - Tolerant enum decoding helper

/// Decode a raw-representable enum from `container`, falling back to `default` when the key is absent OR
/// the stored raw value is unknown (an enum case was renamed/removed, or the file was hand-edited). Keeps
/// a corrupt/edited settings file from ever throwing during decode.
private func decodeEnum<E, K>(
    _ type: E.Type, in container: KeyedDecodingContainer<K>, forKey key: K, default fallback: E
) -> E where E: RawRepresentable, E.RawValue == String, K: CodingKey {
    let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
    guard let raw else { return fallback }
    return E(rawValue: raw) ?? fallback
}

// MARK: - Sound settings (R-APP-5.1, R-DS-5.2)

/// The sound group: effects level, ambience level, and master mute (R-APP-5.1, R-DS-5.2).
///
/// The two levels mirror DesignSystem's `SoundMix` volumes as plain `Double`s in `0...1`; the App maps
/// `SoundSettings` onto a `SoundMix` when it configures the sound engine. Both levels are clamped to
/// `0...1` on init and on decode so a corrupt/edited file can never push a volume out of range.
public struct SoundSettings: Codable, Sendable, Equatable {
    /// Effects volume, 0 (silent) … 1 (full).
    public var effectsLevel: Double
    /// Ambience volume, 0 (silent) … 1 (full).
    public var ambienceLevel: Double
    /// Master mute — silences everything regardless of the two levels (R-DS-5.2).
    public var masterMuted: Bool

    public init(
        effectsLevel: Double = 0.8,
        ambienceLevel: Double = 0.5,
        masterMuted: Bool = false
    ) {
        self.effectsLevel = SoundSettings.clampLevel(effectsLevel)
        self.ambienceLevel = SoundSettings.clampLevel(ambienceLevel)
        self.masterMuted = masterMuted
    }

    /// The default sound settings.
    public static var defaults: SoundSettings { SoundSettings() }

    /// Clamp a level to the valid `0...1` range.
    static func clampLevel(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let effects =
            try container.decodeIfPresent(Double.self, forKey: .effectsLevel) ?? 0.8
        let ambience =
            try container.decodeIfPresent(Double.self, forKey: .ambienceLevel) ?? 0.5
        let muted = try container.decodeIfPresent(Bool.self, forKey: .masterMuted) ?? false
        self.init(effectsLevel: effects, ambienceLevel: ambience, masterMuted: muted)
    }
}

// MARK: - Accessibility overrides (R-APP-5.1, R-A11Y-4.1)

/// The explicit app-level accessibility overrides (R-APP-5.1, R-A11Y-4.1).
///
/// These are the toggles the app offers ON TOP OF the OS settings. The system Reduce Motion / Reduce
/// Transparency / Increase Contrast are READ FROM the OS by the App (R-A11Y-4.1) and are not stored here;
/// these fields are the explicit overrides the app itself exposes:
///   • `forceReduceMotion` — force reduced motion even if the OS setting is off.
///   • `highContrastCards` — a higher-contrast card appearance independent of the OS contrast setting.
///   • `fourColorDeck` — the four-color suit deck for color independence (R-A11Y-3.1).
/// The card-size override lives on `AppearanceSettings.cardSize` (R-A11Y-4.1) since it is also the visible
/// appearance choice.
public struct AccessibilitySettings: Codable, Sendable, Equatable {
    /// Force reduced motion regardless of the OS Reduce Motion setting.
    public var forceReduceMotion: Bool
    /// Use a higher-contrast card appearance (independent of the OS Increase Contrast setting).
    public var highContrastCards: Bool
    /// Use the four-color suit deck for color independence (R-A11Y-3.1).
    public var fourColorDeck: Bool

    public init(
        forceReduceMotion: Bool = false,
        highContrastCards: Bool = false,
        fourColorDeck: Bool = false
    ) {
        self.forceReduceMotion = forceReduceMotion
        self.highContrastCards = highContrastCards
        self.fourColorDeck = fourColorDeck
    }

    /// The default accessibility overrides — all off (defer to the OS).
    public static var defaults: AccessibilitySettings { AccessibilitySettings() }
}

// MARK: - AppSettings (R-APP-5.1)

/// The full settings surface as one `Codable` value (R-APP-5.1): appearance, gameplay, sound, accessibility
/// overrides, and the editable local player profile.
///
/// One value keeps the store simple (load/save the whole thing) and gives the App an observable-friendly
/// snapshot it can hand to the environment. `profile` is the editable local `PlayerProfile` (an EngineCore
/// type re-exported through Persistence, R-SESS-5.2); the App already owns a `ProfileStore`, so this simply
/// round-trips the local profile alongside the rest of the settings.
///
/// Decoding is TOLERANT: every group decodes with a default when absent, and unknown enum raw values fall
/// back to their enum default, so a partial, older, or edited file still yields a fully-valid value
/// (see `SettingsCodec` and `SandboxSettingsStore.load`).
public struct AppSettings: Codable, Sendable, Equatable {
    /// Appearance: theme pack, deck style, card back, card size (R-APP-5.1).
    public var appearance: AppearanceSettings
    /// Gameplay: animation speed, AI pace, auto-moves, hints, confirmations (R-APP-5.1).
    public var gameplay: GameplaySettings
    /// Sound: effects/ambience levels, master mute (R-APP-5.1).
    public var sound: SoundSettings
    /// Explicit app-level accessibility overrides (R-APP-5.1, R-A11Y-4.1).
    public var accessibility: AccessibilitySettings
    /// The editable local player profile (R-SESS-5.2).
    public var profile: PlayerProfile

    public init(
        appearance: AppearanceSettings = .defaults,
        gameplay: GameplaySettings = .defaults,
        sound: SoundSettings = .defaults,
        accessibility: AccessibilitySettings = .defaults,
        profile: PlayerProfile = .defaultLocalHuman()
    ) {
        self.appearance = appearance
        self.gameplay = gameplay
        self.sound = sound
        self.accessibility = accessibility
        self.profile = profile
    }

    /// The out-of-the-box defaults every settings group starts at, with a fresh local profile.
    public static var defaults: AppSettings { AppSettings() }

    enum CodingKeys: String, CodingKey {
        case appearance, gameplay, sound, accessibility, profile
    }

    /// Tolerant decode: each group defaults if absent, so a partial/older file still yields a valid value.
    /// Enum-level fallback for unknown raw values happens in the group decoders (see `decodeEnum`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appearance =
            (try? container.decodeIfPresent(AppearanceSettings.self, forKey: .appearance))
            .flatMap { $0 } ?? .defaults
        self.gameplay =
            (try? container.decodeIfPresent(GameplaySettings.self, forKey: .gameplay))
            .flatMap { $0 } ?? .defaults
        self.sound =
            (try? container.decodeIfPresent(SoundSettings.self, forKey: .sound))
            .flatMap { $0 } ?? .defaults
        self.accessibility =
            (try? container.decodeIfPresent(AccessibilitySettings.self, forKey: .accessibility))
            .flatMap { $0 } ?? .defaults
        self.profile =
            (try? container.decodeIfPresent(PlayerProfile.self, forKey: .profile))
            .flatMap { $0 } ?? .defaultLocalHuman()
    }
}

// MARK: - SettingsStore protocol

/// The raw I/O of the whole `AppSettings` value — the seam tests swap for an in-memory store
/// (R-PERS-3.1).
///
/// Settings are one small value, so the store loads/saves it whole (mirroring `StatisticsStore`).
/// `Sendable` so it can be held across the concurrency boundary by an observable settings holder in the
/// App.
public protocol SettingsStore: Sendable {
    /// Load the settings, or `.defaults` if nothing has been stored yet (or the stored file is corrupt).
    func load() throws -> AppSettings
    /// Persist the settings, replacing any prior contents (R-PERS-3.1).
    func save(_ settings: AppSettings) throws
}

// MARK: - Settings codec (bytes ⇄ AppSettings)

/// Encodes `AppSettings` to bytes and back — kept separate from the store so the JSON round-trip is
/// testable without a file system (same split as `SaveCodec` / `StatisticsCodec`).
///
/// JSON with sorted keys for a stable, diff-friendly on-disk form. `decode` is TOLERANT: it relies on
/// `AppSettings`'s tolerant decoders so any JSON object yields a fully-valid, in-range value (sound levels
/// clamped, unknown enums defaulted, absent groups defaulted).
public struct SettingsCodec: Sendable {
    public init() {}

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    /// Encode `settings` to JSON bytes (R-PERS-3.1).
    public func encode(_ settings: AppSettings) throws -> Data {
        try encoder.encode(settings)
    }

    /// Decode `AppSettings` from `data`. A non-JSON payload still throws (the caller degrades that to
    /// `.defaults`); a JSON object always yields a valid, in-range value thanks to the tolerant decoders.
    public func decode(from data: Data) throws -> AppSettings {
        try decoder.decode(AppSettings.self, from: data)
    }
}

// MARK: - Sandbox container store (R-PERS-3.1)

/// A `SettingsStore` that reads/writes ONE JSON file under the app's local sandbox container and ONLY
/// there — no cloud (R-PERS-3.1).
///
/// The file lives directly in the app's Application Support directory, which inside the App Sandbox
/// resolves to the app's own container (R-BUILD-3.1). The directory is created on demand; the write is
/// atomic so an interrupted write leaves the prior settings intact. `load` degrades to `.defaults` for a
/// missing file (fresh install) AND for a genuinely corrupt (non-JSON) payload, so a damaged/edited file
/// never crashes the app. Composes a `SettingsCodec`, so encode/decode stays testable without disk.
public struct SandboxSettingsStore: SettingsStore {
    private let fileURL: URL
    private let codec: SettingsCodec

    /// Create a store writing `Settings.json` under `directory`, creating it if needed. Defaults to the
    /// app's Application Support container — the sandbox-local location settings belong in (R-PERS-3.1).
    ///
    /// A test may pass an explicit `directory` (e.g. a temp dir) to exercise the real disk path; the
    /// default reaches only the container. `FileManager.default` is thread-safe, so it is used directly
    /// rather than stored (it is not `Sendable`, and the store must be).
    public init(directory: URL? = nil, codec: SettingsCodec = SettingsCodec()) throws {
        let fileManager = FileManager.default
        let dir: URL
        if let directory {
            dir = directory
        } else {
            dir = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("Settings.json", isDirectory: false)
        self.codec = codec
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .defaults }
        let data = try Data(contentsOf: fileURL)
        // A corrupt (non-JSON) payload must never crash the app: degrade to defaults (R-APP-5.1).
        return (try? codec.decode(from: data)) ?? .defaults
    }

    public func save(_ settings: AppSettings) throws {
        let data = try codec.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }
}

// MARK: - In-memory store (headless tests / previews)

/// A synchronous, `Sendable` in-memory `SettingsStore` for tests and previews, backed by a lock-guarded
/// box — so the load/save flow runs entirely in memory (R-PERS-3.1 seam).
///
/// A small `NSLock`-guarded box keeps it `Sendable` without an actor hop, mirroring the other in-memory
/// stores.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings

    public init(_ settings: AppSettings = .defaults) {
        self.settings = settings
    }

    public func load() throws -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
    }
}
