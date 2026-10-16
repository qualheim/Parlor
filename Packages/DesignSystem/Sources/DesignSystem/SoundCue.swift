// SoundCue — the semantic audio cues the table plays, and their volume category (R-DS-5.1).
//
// The sound engine is *event-driven*: the same `GameEvent` stream that drives animation, captions, and
// VoiceOver drives sound (design.md §7, R-ENG-8.1). DesignSystem is a leaf UI package with NO dependency
// on EngineCore (design.md §1), so it cannot name `GameEvent` directly. Instead it speaks in `SoundCue`s
// — a small, closed vocabulary of what a table can *sound* like (shuffle / deal / flip / place / chips /
// win) — and the TableKit layer (which depends on both EngineCore and DesignSystem) maps each `GameEvent`
// to a cue. Keeping the cue vocabulary here means the whole selection/mixing/no-repeat policy is a pure,
// Foundation-only value layer, verifiable headless in `swift test`, with the AVFoundation playback shell
// sitting thinly on top.
//
// Each cue also declares which volume *category* it belongs to (effects vs ambience — R-DS-5.1), so the
// mixer can resolve a per-category level and the master mute against it without the caller caring.

import Foundation

/// A semantic table sound cue (R-DS-5.1). Games never spell out file names or volumes; they (via
/// TableKit) request a cue, and the engine resolves it to one of the theme pack's randomized variations
/// for that cue, at the category's current volume, respecting the master mute and background state.
public enum SoundCue: String, Sendable, Hashable, CaseIterable, Codable {
    /// The deck being shuffled (maps from the reshuffle/new-deal moment).
    case shuffle
    /// A card/tile being dealt to a zone (maps from `GameEvent.dealt`).
    case deal
    /// A card/tile turning face-up or face-down (maps from `GameEvent.pieceFlipped`).
    case flip
    /// A piece being placed/moved onto a target (maps from `GameEvent.pieceMoved`).
    case place
    /// Chips/score changing hands (maps from `GameEvent.scoreChanged`).
    case chips
    /// A win / hand-ending flourish (maps from `GameEvent.handEnded` with a win outcome).
    case win

    /// The volume category this cue is mixed under (R-DS-5.1). All the built-in cues are one-shot
    /// *effects*; the *ambience* category exists for looping room tone that a theme pack may add.
    public var category: SoundCategory {
        // Every game-action cue is an effect. Ambience is driven separately (a looping bed), not by these
        // discrete cues, so it has no representative here.
        .effects
    }

    /// The manifest audio key this cue reads its variation list from (`ThemePack.audio[key]`). Matches the
    /// keys documented in design.md §7 and shipped in the theme-pack manifests.
    public var manifestKey: String { rawValue }
}

/// The two independently controllable volume categories (R-DS-5.1).
///
/// `effects` covers the one-shot game sounds (`SoundCue`); `ambience` covers a continuous room-tone bed.
/// Each has its own level and the master mute applies on top of both.
public enum SoundCategory: String, Sendable, Hashable, CaseIterable, Codable {
    /// One-shot game action sounds (shuffle/deal/flip/place/chips/win).
    case effects
    /// Continuous ambient room tone / table bed.
    case ambience
}
