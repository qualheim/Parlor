// VariationSelector — the "never the same sound twice in a row" picker (R-DS-5.1).
//
// A theme pack maps each cue to a *list* of interchangeable audio variations (e.g. six subtly different
// deal sounds). When a cue fires, the engine must pick one variation, and the same variation must NEVER
// play twice consecutively *for that cue* (R-DS-5.1) — otherwise repeated dealing sounds mechanical.
//
// This selector is the pure heart of that rule: given a cue's variation list and the last index it
// returned for that cue, it picks a new index that differs from the last one (whenever the list has more
// than one entry), using an injected `RandomNumberGenerator` so the choice is reproducible in tests. It is
// a plain `Sendable` value with no audio/UI dependency, so the no-repeat invariant is verifiable headless
// (including as a property test over many draws).
//
// Design notes:
//   * With a 1-element list there is nothing to vary; index 0 repeats (the rule is "never twice in a row"
//     which is vacuously the best we can do with one option — a one-element list is inherently repetitive).
//   * With ≥ 2 elements, the pick is uniform over the (n-1) indices that are NOT the last one, so the
//     distribution stays even and the no-repeat guarantee is exact.

import Foundation

/// Picks audio-variation indices per cue such that no cue ever repeats its previous index back-to-back
/// (R-DS-5.1). Holds the last-played index for each cue so the guarantee is per-cue, not global.
public struct VariationSelector: Sendable, Hashable, Codable {
    /// The last index returned for each cue, so the next pick for that cue can avoid it. Absent until a
    /// cue has been played at least once.
    private var lastIndex: [SoundCue: Int]

    public init() {
        self.lastIndex = [:]
    }

    /// The last index played for `cue`, if any (exposed for testing/inspection).
    public func lastPlayedIndex(for cue: SoundCue) -> Int? { lastIndex[cue] }

    /// Pick the next variation index for `cue` from a list of `count` variations, avoiding the index most
    /// recently returned for that cue (R-DS-5.1). Returns `nil` when `count <= 0` (the cue has no audio).
    ///
    /// Records the chosen index as the new "last" for `cue`, so consecutive calls form the no-repeat
    /// chain. `rng` is injected for reproducibility.
    public mutating func next<R: RandomNumberGenerator>(
        forCueWith count: Int, cue: SoundCue, using rng: inout R
    ) -> Int? {
        guard count > 0 else {
            // No variations for this cue — nothing to play, and don't disturb the last-index chain.
            return nil
        }
        guard count > 1 else {
            // Only one option: it necessarily repeats. Record it and return it.
            lastIndex[cue] = 0
            return 0
        }

        let previous = lastIndex[cue]
        let chosen: Int
        if let previous, previous >= 0, previous < count {
            // Draw uniformly from the (count - 1) indices that are NOT `previous`, then shift past the gap.
            var pick = Int.random(in: 0..<(count - 1), using: &rng)
            if pick >= previous { pick += 1 }
            chosen = pick
        } else {
            // No valid previous (first play, or the list shrank) — any index is fine.
            chosen = Int.random(in: 0..<count, using: &rng)
        }
        lastIndex[cue] = chosen
        return chosen
    }

    /// Reset the no-repeat memory (e.g. when the selected theme pack changes and cue lists differ).
    public mutating func reset() {
        lastIndex.removeAll()
    }
}
