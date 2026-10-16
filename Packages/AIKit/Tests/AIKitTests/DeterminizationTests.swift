// Determinization sampler tests (R-AI-2.2, R-AI-3.2).

import EngineCore
import Testing

@testable import AIKit

// A toy "card": an id plus a suit (the category voids are expressed over).
private struct ToyCard: Hashable, Sendable {
    let id: Int
    let suit: Suit
}

private func suit(of c: ToyCard) -> Suit { c.suit }

@Suite("Determinization sampler")
struct DeterminizationTests {

    // A full deal into two hidden hands honors each hand's count and places every unseen card exactly
    // once.
    @Test("assigns all unseen pieces, honoring per-slot counts")
    func honorsCounts() {
        let unseen = (0..<6).map { ToyCard(id: $0, suit: Suit.allCases[$0 % 4]) }
        let groups = [
            HiddenGroup(key: SeatID.index(1), count: 3),
            HiddenGroup(key: SeatID.index(2), count: 3),
        ]
        let constraints = DeterminizationConstraints<SeatID, Suit>()
        var rng = SeededRNG(seed: 100)
        let sample = DeterminizationSampler.sample(
            unseen: unseen, groups: groups, constraints: constraints, category: suit(of:),
            using: &rng)
        #expect(sample != nil)
        guard let sample else { return }
        #expect(sample.assignment[SeatID.index(1)]?.count == 3)
        #expect(sample.assignment[SeatID.index(2)]?.count == 3)
        let placed =
            (sample.assignment[SeatID.index(1)] ?? []) + (sample.assignment[SeatID.index(2)] ?? [])
        #expect(Set(placed) == Set(unseen))  // each card placed exactly once
    }

    // An inferred void means the voided seat never receives a card of the excluded suit (R-AI-2.2).
    @Test("respects an inferred void")
    func respectsVoid() {
        // seat-1 is void in hearts. Provide enough non-hearts so a valid assignment exists.
        let unseen = [
            ToyCard(id: 0, suit: .hearts),
            ToyCard(id: 1, suit: .hearts),
            ToyCard(id: 2, suit: .clubs),
            ToyCard(id: 3, suit: .spades),
            ToyCard(id: 4, suit: .diamonds),
            ToyCard(id: 5, suit: .clubs),
        ]
        var constraints = DeterminizationConstraints<SeatID, Suit>()
        constraints.addVoid(slot: SeatID.index(1), category: .hearts)
        let groups = [
            HiddenGroup(key: SeatID.index(1), count: 3),
            HiddenGroup(key: SeatID.index(2), count: 3),
        ]
        // Many samples must all respect the void.
        for seed in UInt64(0)..<50 {
            var rng = SeededRNG(seed: seed)
            let sample = DeterminizationSampler.sample(
                unseen: unseen, groups: groups, constraints: constraints,
                category: suit(of:), using: &rng)
            #expect(sample != nil)
            guard let sample else { continue }
            let hand1 = sample.assignment[SeatID.index(1)] ?? []
            #expect(hand1.allSatisfy { $0.suit != .hearts })
            // Both hearts must therefore be in seat-2's hand.
            let hand2 = sample.assignment[SeatID.index(2)] ?? []
            #expect(hand2.filter { $0.suit == .hearts }.count == 2)
        }
    }

    // Same seed → identical sample (reproducible, R-AI-3.2).
    @Test("same seed yields identical sample")
    func reproducible() {
        let unseen = (0..<8).map { ToyCard(id: $0, suit: Suit.allCases[$0 % 4]) }
        let groups = [
            HiddenGroup(key: SeatID.index(1), count: 4),
            HiddenGroup(key: SeatID.index(2), count: 4),
        ]
        let constraints = DeterminizationConstraints<SeatID, Suit>()
        var rngA = SeededRNG(seed: 555)
        var rngB = SeededRNG(seed: 555)
        let a = DeterminizationSampler.sample(
            unseen: unseen, groups: groups, constraints: constraints, category: suit(of:),
            using: &rngA)
        let b = DeterminizationSampler.sample(
            unseen: unseen, groups: groups, constraints: constraints, category: suit(of:),
            using: &rngB)
        #expect(a?.assignment == b?.assignment)
    }

    // Different seeds explore different assignments (the sampler actually randomizes).
    @Test("different seeds cover different assignments")
    func coversSpace() {
        let unseen = (0..<6).map { ToyCard(id: $0, suit: Suit.allCases[$0 % 4]) }
        let groups = [
            HiddenGroup(key: SeatID.index(1), count: 3),
            HiddenGroup(key: SeatID.index(2), count: 3),
        ]
        let constraints = DeterminizationConstraints<SeatID, Suit>()
        var seen: Set<[Int]> = []
        for seed in UInt64(0)..<40 {
            var rng = SeededRNG(seed: seed)
            if let s = DeterminizationSampler.sample(
                unseen: unseen, groups: groups, constraints: constraints,
                category: suit(of:), using: &rng)
            {
                seen.insert((s.assignment[SeatID.index(1)] ?? []).map(\.id).sorted())
            }
        }
        #expect(seen.count > 1)
    }

    // Infeasible instances return nil rather than looping.
    @Test("infeasible counts return nil")
    func infeasibleReturnsNil() {
        let unseen = (0..<3).map { ToyCard(id: $0, suit: .clubs) }
        let groups = [HiddenGroup(key: SeatID.index(1), count: 5)]  // needs 5, only 3 available
        let constraints = DeterminizationConstraints<SeatID, Suit>()
        var rng = SeededRNG(seed: 1)
        let sample = DeterminizationSampler.sample(
            unseen: unseen, groups: groups, constraints: constraints, category: suit(of:),
            using: &rng)
        #expect(sample == nil)
    }

    // A void that makes a group unfillable returns nil (all remaining are the excluded suit).
    @Test("unfillable void returns nil")
    func unfillableVoidReturnsNil() {
        let unseen = [
            ToyCard(id: 0, suit: .hearts),
            ToyCard(id: 1, suit: .hearts),
        ]
        var constraints = DeterminizationConstraints<SeatID, Suit>()
        constraints.addVoid(slot: SeatID.index(1), category: .hearts)
        let groups = [HiddenGroup(key: SeatID.index(1), count: 2)]  // needs 2 non-hearts, has none
        var rng = SeededRNG(seed: 1)
        let sample = DeterminizationSampler.sample(
            unseen: unseen, groups: groups, constraints: constraints, category: suit(of:),
            using: &rng)
        #expect(sample == nil)
    }
}
