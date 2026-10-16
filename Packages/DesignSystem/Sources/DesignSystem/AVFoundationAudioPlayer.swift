// AVFoundationAudioPlayer — the real, AVFoundation-backed playback shell (R-DS-5.1, R-DS-5.2).
//
// This is the only file in the sound engine that touches an audio framework. It is intentionally
// policy-free: it takes a fully-resolved `(url, gain)` from the engine and plays it. All the interesting
// behavior — which variation, at what volume, whether to play at all — has already been decided by the
// pure value layer (`SoundCue` / `VariationSelector` / `SoundMix`) and the `SoundEngine`, so this shell has
// nothing to test beyond "it forwards to AVAudioPlayer".
//
// AVFoundation is allowed for audio (tech.md; it is not in the lint's forbidden import/API sets). The
// player keeps strong references to in-flight `AVAudioPlayer`s so a fire-and-forget one-shot is not
// deallocated mid-sound, and prunes any that have finished on the next `play`/`stopAll` — this keeps
// everything main-actor-isolated (no `nonisolated` delegate crossing the concurrency boundary), which
// matters under Swift 6 strict concurrency.
//
// All shipped clips are original / CC0 / procedurally synthesized (R-DS-5.2), noted in
// `THIRD_PARTY_NOTICES.md`. Placeholder audio is flagged "needs production art" (🎨 tasks 5.4 / 5.7).

import AVFoundation
import Foundation
import os

/// The AVFoundation-backed `AudioPlayer` used by the app (R-DS-5.1). Plays one-shot clips at a linear
/// gain, holding each until it finishes so short sounds are not cut off by ARC.
@MainActor
public final class AVFoundationAudioPlayer: AudioPlayer {
    private static let log = Logger(subsystem: "com.parlor.designsystem", category: "sound")

    /// In-flight players, retained so a fire-and-forget clip survives until playback completes. Pruned of
    /// finished players on each `play`/`stopAll`.
    private var active: [AVAudioPlayer] = []

    public init() {}

    /// Play `url` at linear `gain` (0...1). A non-positive gain plays nothing (the engine uses gain 0 to
    /// mean "muted / backgrounded / zero slider"). Failures to open the file are logged and swallowed —
    /// audio is never allowed to crash play (R-DS-5.1).
    public func play(_ url: URL, gain: Double) {
        pruneFinished()
        guard gain > 0 else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = Float(min(1, max(0, gain)))
            active.append(player)
            player.prepareToPlay()
            player.play()
        } catch {
            Self.log.error(
                "failed to play audio at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Stop and release everything currently playing (mute / background — R-DS-5.1).
    public func stopAll() {
        for player in active { player.stop() }
        active.removeAll()
    }

    /// Drop references to players that have finished so the retain set does not grow unbounded.
    private func pruneFinished() {
        active.removeAll { !$0.isPlaying }
    }
}
