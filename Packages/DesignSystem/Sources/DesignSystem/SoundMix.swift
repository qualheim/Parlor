// SoundMix — the pure volume/mute policy for the sound engine (R-DS-5.1).
//
// This is the value layer that answers one question with no side effects: "for this cue, right now, what
// gain (0...1) should actually play — if anything?" It folds together the separate effects/ambience
// levels, the master mute, and the mute-when-in-background state (R-DS-5.1). Because it is a plain
// `Sendable` value with pure functions, the whole mixing policy is unit-testable headless; the
// `SoundEngine` (and its AVFoundation shell) simply asks the mix for a gain and plays at that level.
//
// Keeping volume as a *linear* 0...1 gain here (not decibels) keeps the value layer simple and framework-
// agnostic; the AVFoundation player maps a linear gain straight onto `AVAudioPlayer.volume`, which is
// itself linear 0...1.

import Foundation

/// The resolved volume/mute state of the engine, as a pure value (R-DS-5.1).
///
/// Holds a per-category level (effects, ambience), a master mute, and whether the app is currently
/// backgrounded. `effectiveGain(for:)` resolves all of these into the single gain that should play, so no
/// consumer has to re-implement the muting rules.
public struct SoundMix: Sendable, Hashable, Codable {
    /// The effects-category level, clamped to 0...1.
    public private(set) var effectsLevel: Double
    /// The ambience-category level, clamped to 0...1.
    public private(set) var ambienceLevel: Double
    /// The master mute — when on, nothing plays regardless of category levels (R-DS-5.1).
    public var isMuted: Bool
    /// Whether the app is currently in the background — when true, all audio is silenced
    /// (mute-when-in-background — R-DS-5.1).
    public var isInBackground: Bool

    /// The default mix: full effects, a subtle ambience bed, not muted, foregrounded.
    public static let `default` = SoundMix(
        effectsLevel: 0.8, ambienceLevel: 0.4, isMuted: false, isInBackground: false)

    public init(
        effectsLevel: Double = 0.8,
        ambienceLevel: Double = 0.4,
        isMuted: Bool = false,
        isInBackground: Bool = false
    ) {
        self.effectsLevel = SoundMix.clamp(effectsLevel)
        self.ambienceLevel = SoundMix.clamp(ambienceLevel)
        self.isMuted = isMuted
        self.isInBackground = isInBackground
    }

    /// The stored level for a category (before master mute / background silencing).
    public func level(for category: SoundCategory) -> Double {
        switch category {
        case .effects: return effectsLevel
        case .ambience: return ambienceLevel
        }
    }

    /// Set a category's level, clamped to 0...1. Mutating a level never touches the mute flags.
    public mutating func setLevel(_ value: Double, for category: SoundCategory) {
        let clamped = SoundMix.clamp(value)
        switch category {
        case .effects: effectsLevel = clamped
        case .ambience: ambienceLevel = clamped
        }
    }

    /// A copy with one category's level changed (value-type convenience).
    public func settingLevel(_ value: Double, for category: SoundCategory) -> SoundMix {
        var copy = self
        copy.setLevel(value, for: category)
        return copy
    }

    /// True when *any* audio can play right now: not muted and not backgrounded (R-DS-5.1). Note a
    /// category whose level is 0 still counts as "audible" here — silence from a zero slider is a per-cue
    /// gain of 0, distinct from the global mute/background gate.
    public var isAudible: Bool { !isMuted && !isInBackground }

    /// The gain (0...1) a cue in `category` should actually play at right now, folding in the category
    /// level, the master mute, and the background state (R-DS-5.1). Returns 0 whenever nothing should be
    /// heard — the engine treats a 0 gain as "don't start the sound".
    public func effectiveGain(for category: SoundCategory) -> Double {
        guard isAudible else { return 0 }
        return level(for: category)
    }

    /// The gain a specific cue should play at (convenience over `effectiveGain(for:)` using the cue's
    /// category).
    public func effectiveGain(for cue: SoundCue) -> Double {
        effectiveGain(for: cue.category)
    }

    /// Clamp a level into the valid 0...1 range (also normalizes NaN to 0 so a bad input can't poison the
    /// mix).
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
