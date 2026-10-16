import Foundation
import Testing

@testable import EngineCore

// Tests for the seeded RNG and our Fisher–Yates shuffle (R-ENG-4.1, R-ENG-4.2, R-ENG-4.4; ADR 0002).

@Suite("Seeded RNG and Fisher–Yates (R-ENG-4)")
struct RNGTests {

    // MARK: - SeededRNG determinism (R-ENG-4.1, R-ENG-4.4)

    @Test("same seed produces an identical sequence")
    func sameSeedSameSequence() {
        var a = SeededRNG(seed: 0x1234_5678_9ABC_DEF0)
        var b = SeededRNG(seed: 0x1234_5678_9ABC_DEF0)
        let seqA = (0..<64).map { _ in a.next() }
        let seqB = (0..<64).map { _ in b.next() }
        #expect(seqA == seqB)
    }

    @Test("different seeds produce different sequences")
    func differentSeedsDiffer() {
        var a = SeededRNG(seed: 1)
        var b = SeededRNG(seed: 2)
        let seqA = (0..<64).map { _ in a.next() }
        let seqB = (0..<64).map { _ in b.next() }
        #expect(seqA != seqB)
    }

    @Test("a zero seed still yields a non-degenerate sequence")
    func zeroSeedNonDegenerate() {
        // SplitMix64 seeding must avoid xoshiro's forbidden all-zero state.
        var rng = SeededRNG(seed: 0)
        let values = (0..<16).map { _ in rng.next() }
        #expect(values.contains { $0 != 0 })
        #expect(Set(values).count > 1)
    }

    @Test(
        "sequences differ across a spread of seeds",
        arguments: [UInt64](stride(from: 0, through: 90, by: 10)))
    func seedsProduceDistinctFirstWords(_ seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        var other = SeededRNG(seed: seed &+ 1)
        #expect(rng.next() != other.next())
    }

    // MARK: - Fisher–Yates determinism + permutation (R-ENG-4.1, R-ENG-4.2, R-ENG-4.4)

    @Test("same seed yields an identical permutation")
    func shuffleDeterministic() {
        var itemsA = Array(0..<52)
        var itemsB = Array(0..<52)
        var rngA = SeededRNG(seed: 42)
        var rngB = SeededRNG(seed: 42)
        Shuffle.fisherYates(&itemsA, using: &rngA)
        Shuffle.fisherYates(&itemsB, using: &rngB)
        #expect(itemsA == itemsB)
    }

    @Test("different seeds usually yield different orders")
    func shuffleDiffersBySeed() {
        var itemsA = Array(0..<52)
        var itemsB = Array(0..<52)
        var rngA = SeededRNG(seed: 1)
        var rngB = SeededRNG(seed: 999)
        Shuffle.fisherYates(&itemsA, using: &rngA)
        Shuffle.fisherYates(&itemsB, using: &rngB)
        #expect(itemsA != itemsB)
    }

    @Test("shuffle is a permutation — the multiset is preserved")
    func shuffleIsPermutation() {
        var items = Array(0..<106)
        let original = items
        var rng = SeededRNG(seed: 7)
        Shuffle.fisherYates(&items, using: &rng)
        #expect(items.sorted() == original)
        #expect(items.count == original.count)
    }

    @Test("empty and single-element arrays are unchanged")
    func shuffleEdgeCases() {
        var empty: [Int] = []
        var single = [99]
        var rng = SeededRNG(seed: 3)
        Shuffle.fisherYates(&empty, using: &rng)
        Shuffle.fisherYates(&single, using: &rng)
        #expect(empty.isEmpty)
        #expect(single == [99])
    }

    /// Distribution sanity check: over many shuffles of a small array, every element must land in
    /// every position at least once. An obviously biased shuffle (e.g. one that can never move the
    /// first element, or a modulo-biased index) would leave some (element, position) cells empty.
    @Test("every element reaches every position over many shuffles")
    func shuffleDistributionCoverage() {
        let n = 6
        let trials = 5_000
        // reached[element][position] = did `element` ever land at `position`?
        var reached = Array(repeating: Array(repeating: false, count: n), count: n)
        var rng = SeededRNG(seed: 0xDEAD_BEEF)
        for _ in 0..<trials {
            var items = Array(0..<n)
            Shuffle.fisherYates(&items, using: &rng)
            for position in 0..<n {
                reached[items[position]][position] = true
            }
        }
        for element in 0..<n {
            for position in 0..<n {
                #expect(
                    reached[element][position],
                    "element \(element) never reached position \(position)")
            }
        }
    }
}
