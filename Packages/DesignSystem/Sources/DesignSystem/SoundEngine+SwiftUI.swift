// SoundEngine+SwiftUI — environment injection and the mute-when-in-background hook (R-DS-5.1).
//
// The engine itself is framework-agnostic (it only knows `AudioPlayer` and pure values). This file is the
// SwiftUI glue: it puts a shared `SoundEngine` into the environment so any view can request a cue, and it
// provides the `scenePhase` bridge that flips the engine's background state so audio mutes when the app is
// not active (mute-when-in-background — R-DS-5.1). Keeping this SwiftUI-only glue in its own file mirrors
// the `ThemePack+SwiftUI` split and keeps the engine testable headless.

import SwiftUI

// MARK: - Environment key

/// The environment key carrying the app's shared sound engine. Defaults to a silent engine (no audio and
/// a null player) so previews and tests that don't inject one never make noise or crash.
private struct SoundEngineKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: SoundEngine = SoundEngine(
        player: SilentAudioPlayer(), variations: { _ in [] })
}

extension EnvironmentValues {
    /// The shared sound engine for this subtree (R-DS-5.1). The app injects its engine at the root; views
    /// read it to play cues.
    public var soundEngine: SoundEngine {
        get { self[SoundEngineKey.self] }
        set { self[SoundEngineKey.self] = newValue }
    }
}

extension View {
    /// Inject a sound engine into the environment (R-DS-5.1).
    public func soundEngine(_ engine: SoundEngine) -> some View {
        environment(\.soundEngine, engine)
    }

    /// Mute the given engine whenever the app leaves the active scene phase, and unmute on return
    /// (mute-when-in-background — R-DS-5.1). Apply once near the app root.
    public func muteSoundInBackground(_ engine: SoundEngine) -> some View {
        modifier(BackgroundMuteModifier(engine: engine))
    }
}

/// Watches `scenePhase` and pushes the background state into the engine (R-DS-5.1).
private struct BackgroundMuteModifier: ViewModifier {
    let engine: SoundEngine
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Anything other than .active is "in the background" for audio purposes.
                engine.setInBackground(phase != .active)
            }
    }
}

// MARK: - Silent player (default / preview)

/// An `AudioPlayer` that plays nothing — the environment default so previews stay silent and tests that
/// forget to inject a player never touch CoreAudio (R-DS-5.1).
@MainActor
public final class SilentAudioPlayer: AudioPlayer {
    public init() {}
    public func play(_ url: URL, gain: Double) {}
    public func stopAll() {}
}
