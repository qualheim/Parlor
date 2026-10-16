// SoundEngine — the event-driven sound engine (R-DS-5.1, R-DS-5.2).
//
// This is the piece that turns "a cue fired" into "play file X at gain G", tying together the pure value
// layer and the thin AVFoundation shell:
//
//   * the theme pack supplies each cue's list of interchangeable audio variations
//     (`ThemePack.audio[cue.manifestKey]`) — resolved to URLs by an injected `variations(for:)` resolver;
//   * `VariationSelector` picks one variation, NEVER the same one twice in a row for that cue (R-DS-5.1);
//   * `SoundMix` resolves the gain, folding in the per-category volume, the master mute, and the
//     mute-when-in-background state (R-DS-5.1);
//   * `AudioPlayer` plays the chosen file at that gain — real (`AVFoundationAudioPlayer`) in the app, a
//     spy in tests.
//
// It is `@MainActor` and `@Observable` so Settings can bind sliders/toggles and see them take effect
// live. Crucially the *decision* (`resolve(_:)`) is a pure function of the value layer, exposed separately
// from `play(_:)` so tests can assert the no-repeat and mixing behavior without an audio device. The app
// drives cues from the same `GameEvent` stream that feeds animation/captions/VoiceOver (design.md §7,
// R-ENG-8.1); the EngineCore→SoundCue mapping lives in TableKit, which depends on both layers.
//
// All shipped audio is original / CC0 / procedurally synthesized and recorded in `THIRD_PARTY_NOTICES.md`
// (R-DS-5.2). Theme-pack placeholder audio is flagged "needs production art" (🎨 tasks 5.4 / 5.7).

import Foundation
import SwiftUI

/// The result of resolving a cue: which file to play and at what gain — or `nil` when nothing should play
/// (no variations, or the mix is silent). Exposed so the selection/mixing decision is testable apart from
/// actual playback.
public struct ResolvedCue: Sendable, Hashable {
    /// The chosen variation file to play.
    public let url: URL
    /// The linear gain (0...1) to play it at, after volume/mute/background resolution.
    public let gain: Double

    public init(url: URL, gain: Double) {
        self.url = url
        self.gain = gain
    }
}

/// The event-driven sound engine (R-DS-5.1). Owns the volume/mute mix, the per-cue no-repeat selector, and
/// a pluggable resolver from cue → variation URLs, and plays through an injected `AudioPlayer`.
@MainActor
@Observable
public final class SoundEngine {
    /// The current volume/mute state (effects/ambience levels, master mute, background). Observed by
    /// Settings; mutating it takes effect on the next cue (R-DS-5.1).
    public var mix: SoundMix {
        didSet {
            // Backgrounding or muting silences anything currently playing immediately (R-DS-5.1).
            if !mix.isAudible && oldValue.isAudible {
                player.stopAll()
            }
        }
    }

    /// The per-cue no-repeat variation memory (R-DS-5.1). Not observed (internal selection state).
    @ObservationIgnored private var selector: VariationSelector

    /// The playback shell (real AVFoundation player in the app, spy in tests).
    @ObservationIgnored private let player: AudioPlayer

    /// Resolves a cue to its ordered list of variation file URLs (from the selected theme pack). Injected
    /// so the engine has no direct dependency on how packs are stored, and so tests can supply fixtures.
    @ObservationIgnored private var variationsResolver: @MainActor (SoundCue) -> [URL]

    /// The RNG driving variation selection. Injected for reproducibility in tests; defaults to the
    /// system RNG in the app.
    @ObservationIgnored private var rng: any RandomNumberGenerator

    /// Create an engine.
    /// - Parameters:
    ///   - mix: initial volume/mute state (defaults to `.default`).
    ///   - player: the playback shell (defaults to the AVFoundation-backed player).
    ///   - rng: the RNG for variation selection (defaults to the system RNG).
    ///   - variations: resolver from a cue to its ordered variation URLs.
    public init(
        mix: SoundMix = .default,
        player: AudioPlayer,
        rng: any RandomNumberGenerator = SystemRandomNumberGenerator(),
        variations: @escaping @MainActor (SoundCue) -> [URL]
    ) {
        self.mix = mix
        self.player = player
        self.rng = rng
        self.variationsResolver = variations
        self.selector = VariationSelector()
    }

    /// Convenience initializer that resolves cue variations from a `ThemePack` and a base directory
    /// (`Assets/ThemePacks/<id>/`). Each manifest audio entry is a file name relative to that directory.
    public convenience init(
        mix: SoundMix = .default,
        player: AudioPlayer,
        rng: any RandomNumberGenerator = SystemRandomNumberGenerator(),
        pack: ThemePack,
        packDirectory: URL
    ) {
        self.init(mix: mix, player: player, rng: rng) { cue in
            (pack.audio[cue.manifestKey] ?? []).map { name in
                packDirectory.appendingPathComponent(name)
            }
        }
    }

    /// Swap the cue→variation resolver at runtime (e.g. when the selected theme pack changes) and reset
    /// the no-repeat memory, since the variation lists may differ (R-DS-4.1, R-DS-5.1).
    public func useVariations(_ resolver: @escaping @MainActor (SoundCue) -> [URL]) {
        variationsResolver = resolver
        selector.reset()
    }

    /// Point the engine at a different theme pack's audio at runtime (R-DS-4.1).
    public func usePack(_ pack: ThemePack, directory: URL) {
        useVariations { cue in
            (pack.audio[cue.manifestKey] ?? []).map { directory.appendingPathComponent($0) }
        }
    }

    // MARK: - The testable decision (selection + mixing), separate from playback

    /// Decide what a cue should play right now — picking a no-repeat variation and resolving the gain —
    /// without playing it (R-DS-5.1). Returns `nil` when the cue has no variations or the mix is silent
    /// (muted / backgrounded / zero level). This mutates the no-repeat memory, so it is the single
    /// decision point `play(_:)` also uses.
    public func resolve(_ cue: SoundCue) -> ResolvedCue? {
        let urls = variationsResolver(cue)
        guard let index = selector.next(forCueWith: urls.count, cue: cue, using: &rng) else {
            return nil
        }
        let gain = mix.effectiveGain(for: cue)
        guard gain > 0 else { return nil }
        return ResolvedCue(url: urls[index], gain: gain)
    }

    // MARK: - Playing cues (R-DS-5.1)

    /// Play a cue: pick a no-repeat variation, resolve the gain, and hand it to the player (R-DS-5.1).
    /// A silent mix or an audio-less cue is a no-op.
    public func play(_ cue: SoundCue) {
        guard let resolved = resolve(cue) else { return }
        player.play(resolved.url, gain: resolved.gain)
    }

    // MARK: - Volume / mute controls (R-DS-5.1)

    /// Set a category's level (0...1) live (R-DS-5.1).
    public func setLevel(_ value: Double, for category: SoundCategory) {
        mix.setLevel(value, for: category)
    }

    /// Toggle the master mute (R-DS-5.1). Muting stops anything currently playing.
    public func setMuted(_ muted: Bool) {
        mix.isMuted = muted
    }

    /// Update the background state — the app calls this from `scenePhase` (R-DS-5.1). Backgrounding
    /// silences all audio; returning to the foreground resumes future cues.
    public func setInBackground(_ inBackground: Bool) {
        mix.isInBackground = inBackground
    }
}
