// Seeded RNG and our own Fisher–Yates shuffle (R-ENG-4; ADR 0002).
//
// Fair play (product.md principle 2) and deterministic replay (R-QA-2.1, R-QA-4.1) require that every
// shuffle be uniformly random *and* reproducible from a recorded seed. ADR 0002 fixes the algorithm:
//
//   • the PRNG is xoshiro256** whose 256-bit state is filled by expanding a single 64-bit hand seed
//     through SplitMix64 (ADR 0002 decision 1), and
//   • shuffling uses our own unbiased Fisher–Yates that draws a bounded index in `0...i` by rejection
//     sampling — never `Int.random`, `shuffle()`, or `SystemRandomNumberGenerator`, which are forbidden
//     and lint-checked (ADR 0002 decision 2; R-ENG-4.2, R-BUILD-4).
//
// Both are deliberately portable: they use only fixed-width integer arithmetic from the standard library,
// so the pure layer keeps working on Linux for a future server (tech.md rule 1). All multiplies and adds
// are wrapping (`&*`, `&+`) because the reference algorithms are defined over modular 64-bit arithmetic.

import Foundation

// MARK: - SplitMix64 (seed expansion)

/// SplitMix64 — the seed-expansion generator ADR 0002 uses to fill xoshiro256**'s 256-bit state from a
/// single 64-bit hand seed (decision 1).
///
/// It is a well-known, tiny generator whose `next()` advances an internal 64-bit counter and mixes it.
/// We use it *only* to derive the four seed words for xoshiro256**; it is not the game PRNG itself. The
/// constants are the canonical SplitMix64 reference values.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - SeededRNG (xoshiro256**)

/// A deterministic pseudo-random number generator: xoshiro256** seeded via SplitMix64 (ADR 0002
/// decision 1; R-ENG-4.1).
///
/// A 64-bit hand seed is expanded through SplitMix64 into xoshiro256**'s 256-bit state; `next()` returns
/// the xoshiro256** output word. The same seed always produces the same sequence on every run and
/// platform, which is what makes shuffles reproducible for replay and save/restore (R-ENG-4.4). It
/// conforms to `RandomNumberGenerator` so it can drive standard-library generic randomness *within the
/// engine* — but rules code shuffles only through ``Shuffle/fisherYates(_:using:)`` (R-ENG-4.2).
///
/// `Sendable` because the host owns one per hand and hands it to the shuffle and (a separate injected
/// instance) to the AI (R-AI-3.2); it carries only value state, no reference or shared mutable data.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    /// xoshiro256**'s 256-bit state as four 64-bit words.
    private var s: (UInt64, UInt64, UInt64, UInt64)

    /// Create a generator from a 64-bit hand seed, expanding it through SplitMix64 to fill the 256-bit
    /// state (ADR 0002 decision 1). Any seed value is valid; SplitMix64 avoids the all-zero state that
    /// xoshiro256** cannot leave.
    public init(seed: UInt64) {
        var mixer = SplitMix64(seed: seed)
        s = (mixer.next(), mixer.next(), mixer.next(), mixer.next())
    }

    /// Rotate-left by `k` bits, the mixing primitive xoshiro256** uses.
    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    /// Produce the next 64-bit output and advance the state (the reference xoshiro256** step).
    ///
    /// The output word is `rotl(s1 * 5, 7) * 9` (the "**" scrambler); the state update is the standard
    /// xoshiro256 linear step. All arithmetic is wrapping per the algorithm's modular definition.
    public mutating func next() -> UInt64 {
        let result = SeededRNG.rotl(s.1 &* 5, 7) &* 9

        let t = s.1 << 17
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = SeededRNG.rotl(s.3, 45)

        return result
    }
}

// MARK: - Fisher–Yates

/// Our own unbiased Fisher–Yates shuffle over a `SeededRNG` (ADR 0002 decision 2; R-ENG-4.1, R-ENG-4.2).
///
/// Rules code must shuffle through here; the standard-library `shuffle()`, `Int.random`, and
/// `SystemRandomNumberGenerator` are forbidden (lint-checked) because they are neither seed-reproducible
/// across platforms nor guaranteed unbiased for our contract.
public enum Shuffle {
    /// Draw a uniformly random index in `0...upperInclusive` from `rng`, without modulo bias.
    ///
    /// Naïvely reducing a random 64-bit word modulo `n` skews toward the low indices whenever `n` does
    /// not divide 2^64. We instead reject the small unusable tail: with `bound = n`, values at or above
    /// the largest multiple of `n` that fits in 64 bits (`limit`) are discarded and redrawn, so every
    /// index in `0..<n` is equally likely (ADR 0002 decision 2). For `n <= 1` there is only one choice.
    private static func unbiasedIndex(upperInclusive: Int, using rng: inout SeededRNG) -> Int {
        let n = UInt64(upperInclusive) &+ 1
        if n <= 1 { return 0 }
        // Largest multiple of n representable in 64 bits; draws >= limit fall in the biased tail.
        let limit = UInt64.max - (UInt64.max % n)
        var r = rng.next()
        while r >= limit {
            r = rng.next()
        }
        return Int(r % n)
    }

    /// Shuffle `items` in place with an unbiased Fisher–Yates pass driven by `rng` (R-ENG-4.1).
    ///
    /// Iterating from the last index down to 1, each element is swapped with one at a uniformly random
    /// index in `0...i` (drawn via ``unbiasedIndex(upperInclusive:using:)``), which yields a uniform
    /// permutation. The result is fully determined by the generator's seed, so replaying the same seed
    /// reproduces the same order (R-ENG-4.4). Empty and single-element arrays are left unchanged.
    public static func fisherYates<T>(_ items: inout [T], using rng: inout SeededRNG) {
        guard items.count > 1 else { return }
        var i = items.count - 1
        while i > 0 {
            let j = unbiasedIndex(upperInclusive: i, using: &rng)
            if i != j {
                items.swapAt(i, j)
            }
            i -= 1
        }
    }
}
