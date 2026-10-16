// ProfileSettingsView — the editable local profile surface + bundled personas listing (R-SESS-5.2).
//
// R-SESS-5.2 requires an editable local profile and bundled AI personas. This is the thin, standard-SwiftUI
// surface for both, reached via the standard Settings scene (⌘,) wired in `ParlorApp`. It stays minimal on
// purpose — the full Settings screen (appearance, gameplay, sound, accessibility) is task 6.4 (R-APP-5.1);
// here we deliver just the profile section and a read-only persona roster.
//
// Standard SwiftUI `Form`/`TabView` chrome is used so the app inherits the current macOS design language
// automatically (R-APP-6.4). The local player's display name and avatar are edited and persisted through
// `LocalProfileStore` (interim UserDefaults; full Persistence is Phase 6). Bundled personas come from
// `AIPersona.bundled` (EngineCore data, surfaced via Persistence) and are shown read-only for now —
// selecting them for opponents is the setup sheet's job (task 6.5; R-APP-2.2).

import Persistence  // re-exports EngineCore: PlayerProfile, AIPersona, AvatarReference (R-SESS-5)
import SwiftUI

// MARK: - Settings root (⌘,)

/// The app Settings window content (R-APP-6.4). Profile tab populated; other tabs added in gap 5 fix.
struct ParlorSettingsView: View {
    let profileStore: LocalProfileStore

    // Gap 5 fix: Add settings environment for Appearance, Gameplay, Sound, Accessibility
    @State private var appearanceSettings = AppearanceSettings()
    @State private var gameplaySettings = GameplaySettings()
    @State private var soundSettings = SoundSettings()

    var body: some View {
        TabView {
            ProfileSettingsView(store: profileStore)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }

            AppearanceSettingsView(settings: appearanceSettings)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            GameplaySettingsView(settings: gameplaySettings)
                .tabItem { Label("Gameplay", systemImage: "gamecontroller") }

            SoundSettingsView(settings: soundSettings)
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }

            StatisticsSettingsView()
                .tabItem { Label("Statistics", systemImage: "chart.bar") }
        }
        .frame(width: 500, height: 480)
    }
}

// MARK: - Appearance Settings (gap 5)

struct AppearanceSettings {
    var themeID: String = TableTheme.default.id
    var deckStyleID: String = DeckStyle.default.id
    var cardBackID: String = "classic"
    var cardSize: CardSizeScale = .medium
}

struct AppearanceSettingsView: View {
    @Bindable var settings: AppearanceSettings

    var body: some View {
        Form {
            Section("Table Theme") {
                Picker("Theme", selection: $settings.themeID) {
                    ForEach(TableTheme.all, id: \.id) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            }

            Section("Deck Style") {
                Picker("Deck", selection: $settings.deckStyleID) {
                    ForEach(DeckStyle.all, id: \.id) { style in
                        Text(style.name).tag(style.id)
                    }
                }

                Picker("Card Size", selection: $settings.cardSize) {
                    Text("Small").tag(CardSizeScale.small)
                    Text("Medium").tag(CardSizeScale.medium)
                    Text("Large").tag(CardSizeScale.large)
                    Text("Extra Large").tag(CardSizeScale.extraLarge)
                }
            }
        }
        .padding()
    }
}

// MARK: - Gameplay Settings (gap 5)

struct GameplaySettings {
    var animationSpeed: Double = 0.5
    var autoMove: Bool = true
    var autoComplete: Bool = true
    var hints: Bool = true
}

struct GameplaySettingsView: View {
    @Bindable var settings: GameplaySettings

    var body: some View {
        Form {
            Section("Animation") {
                Slider(value: $settings.animationSpeed, in: 0...1) {
                    Text("Speed")
                } minimumValueLabel: {
                    Text("Instant")
                } maximumValueLabel: {
                    Text("Relaxed")
                }
            }

            Section("Assists") {
                Toggle("Auto-move to foundation", isOn: $settings.autoMove)
                Toggle("Auto-complete when won", isOn: $settings.autoComplete)
                Toggle("Show hints", isOn: $settings.hints)
            }
        }
        .padding()
    }
}

// MARK: - Sound Settings (gap 5)

struct SoundSettings {
    var enabled: Bool = true
    var volume: Double = 0.8
    var masterMuted: Bool = false
}

struct SoundSettingsView: View {
    @Bindable var settings: SoundSettings

    var body: some View {
        Form {
            Section("Audio") {
                Toggle("Enable Sound", isOn: $settings.enabled)

                if settings.enabled {
                    Slider(value: $settings.volume, in: 0...1) {
                        Text("Volume")
                    } minimumValueLabel: {
                        Text("Mute")
                    } maximumValueLabel: {
                        Text("Max")
                    }

                    Toggle("Master Mute", isOn: $settings.masterMuted)
                }
            }

            Section("About Sound") {
                Text("Game sounds: shuffle, deal, flip, place, chips, win.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Editable local profile (R-SESS-5.2)

/// Edit the local player's display name and placeholder avatar, and browse the bundled AI personas
/// (R-SESS-5.1, R-SESS-5.2).
struct ProfileSettingsView: View {
    /// The observable local-profile store; edits persist immediately (interim UserDefaults).
    @Bindable var store: LocalProfileStore

    /// Working copy of the editable display name, committed to the store on change.
    @State private var draftName: String = ""
    /// The currently selected avatar reference.
    @State private var selectedAvatar: AvatarReference = PlayerProfile.defaultLocalHuman().avatar

    var body: some View {
        Form {
            Section("Local player") {
                HStack(spacing: 16) {
                    AvatarView(reference: selectedAvatar, size: 64)
                        .accessibilityLabel("Your avatar")
                    VStack(alignment: .leading) {
                        TextField("Display name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commit)
                        Text("Shown on your seat plate at the table.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Avatar") {
                // 🎨 Placeholder avatars — needs production art (R-DS-6.1). Real art replaces these later.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(Array(AvatarChoices.all.enumerated()), id: \.offset) { _, avatar in
                        Button {
                            selectedAvatar = avatar
                            commit()
                        } label: {
                            AvatarView(reference: avatar, size: 44)
                                .overlay {
                                    if avatar == selectedAvatar {
                                        Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Avatar option")
                        .accessibilityAddTraits(avatar == selectedAvatar ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 4)
                Text("Placeholder avatars — production art to come.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bundled AI personas") {
                // Read-only roster at the foundation stage; opponent selection is the setup sheet (6.5).
                ForEach(AIPersona.bundled) { persona in
                    HStack(spacing: 12) {
                        AvatarView(reference: persona.avatar, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(persona.name)
                            Text(personaSummary(persona))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draftName = store.profile.displayName
            selectedAvatar = store.profile.avatar
        }
    }

    /// Persist the current draft name + selected avatar to the store (R-SESS-5.2).
    private func commit() {
        store.update(displayName: draftName, avatar: selectedAvatar)
        // Reflect any normalization (e.g. blank name → "Player") back into the field.
        draftName = store.profile.displayName
    }

    /// A short human-readable summary of a persona's tier + documented style params (A-6).
    private func personaSummary(_ persona: AIPersona) -> String {
        let tier = persona.tier.rawValue.capitalized
        let aggression = Int((persona.style.aggression * 100).rounded())
        let risk = Int((persona.style.riskTolerance * 100).rounded())
        return "\(tier) · aggression \(aggression)% · risk \(risk)%"
    }
}
