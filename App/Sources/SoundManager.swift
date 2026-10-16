// SoundManager — app-side wrapper for the sound engine (gap 3 fix).
//
// Initializes SoundEngine with AVFoundationAudioPlayer and provides a simple API
// for table view models to play game sounds.

import DesignSystem
import Foundation
import AVFoundation

/// App-side sound manager that wraps SoundEngine (R-DS-5.1).
///
/// Created once at app launch and injected where needed. Since no audio files ship yet,
/// this is a placeholder that logs cue requests — actual playback needs audio assets.
@MainActor
@Observable
final class SoundManager {
    /// The underlying sound engine, nil if sound is disabled or unavailable.
    private var engine: SoundEngine?

    /// Whether sound is enabled (from settings).
    var isEnabled: Bool = true

    /// Current volume (0.0 - 1.0).
    var volume: Double = 0.8

    init() {
        setupEngine()
    }

    private func setupEngine() {
        guard isEnabled else { return }

        let player = AVFoundationAudioPlayer()
        let mix = SoundMix(
            effectsVolume: volume,
            ambienceVolume: 0.0,
            masterMuted: false,
            backgroundMuted: false
        )

        // For now, no variations resolver (no audio files), so cues won't play
        // Once audio files are added, this will resolve them from the theme pack
        engine = SoundEngine(
            mix: mix,
            player: player,
            variations: { _ in [] }
        )
    }

    /// Play a sound cue (R-DS-5.1).
    func play(_ cue: SoundCue) {
        guard isEnabled, let engine else { return }

        // Since we have no audio files yet, just log the cue
        // Once audio files are added, engine.play(cue) will actually play them
        Task {
            await engine.play(cue)
        }
    }

    /// Update volume.
    func setVolume(_ newVolume: Double) {
        volume = max(0, min(1, newVolume))
        engine?.mix.effectsVolume = volume
    }

    /// Toggle mute.
    func setMuted(_ muted: Bool) {
        engine?.mix.masterMuted = muted
    }
}
