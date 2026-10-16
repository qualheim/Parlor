// AudioPlayer — the thin playback seam behind which the sound engine's selection logic stays testable
// (R-DS-5.1, R-DS-5.2).
//
// The whole point of splitting the sound engine into a *value layer* (cue vocabulary, no-repeat selector,
// volume/mute mix) and a *shell* is that the value layer can be exercised headlessly. `AudioPlayer` is
// that seam: the engine only ever asks a player to "play this file at this gain" or "stop", so a test can
// inject a spy player that records calls and assert on the selection/mixing behavior without touching
// CoreAudio. The real, AVFoundation-backed player (`AVFoundationAudioPlayer`) is the only piece that
// reaches a framework, and it is deliberately dumb — no policy lives in it.
//
// AVFoundation is permitted for audio playback (tech.md — it is not among the forbidden imports/APIs the
// lint enforces). All shipped audio is original / CC0 / procedurally synthesized and recorded in
// `THIRD_PARTY_NOTICES.md` (R-DS-5.2).

import Foundation

/// A one-shot audio-clip player, abstracted so the engine's selection/mixing logic is testable without
/// real audio (R-DS-5.1). Implementations are the AVFoundation-backed shell in the app and a spy in tests.
///
/// `@MainActor` because the concrete AVFoundation player owns UI-adjacent playback state; the engine that
/// drives it is also main-actor. Not `Sendable` for the same reason.
@MainActor
public protocol AudioPlayer: AnyObject {
    /// Play the clip at `url` at the given linear `gain` (0...1). A `gain` of 0 means "play nothing".
    /// Implementations must be non-blocking (fire-and-forget); overlapping cues may play concurrently.
    func play(_ url: URL, gain: Double)

    /// Stop all currently playing audio immediately (used when muting or backgrounding — R-DS-5.1).
    func stopAll()
}
