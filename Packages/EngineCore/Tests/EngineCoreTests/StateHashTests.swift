import Foundation
import Testing

@testable import EngineCore

// Tests for the stable state digest and the determinism contract (R-ENG-4.4; ADR 0002 decision 4/5).

@Suite("State hashing and determinism (R-ENG-4.4)")
struct StateHashTests {

    // MARK: - Known-answer vectors (prove it is standard SHA-256)

    @Test("empty input matches the standard SHA-256 vector")
    func sha256EmptyVector() {
        let hash = StateHash.of([UInt8]())
        #expect(hash.hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("\"abc\" matches the standard SHA-256 vector")
    func sha256AbcVector() {
        let hash = StateHash.of(Array("abc".utf8))
        #expect(hash.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("a multi-block message matches the standard SHA-256 vector")
    func sha256MultiBlockVector() {
        // 448-bit message that forces a second padded block — FIPS 180-4 example 2.
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        let hash = StateHash.of(Array(message.utf8))
        #expect(hash.hex == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    // MARK: - Digest shape + hex round-trip

    @Test("digest is 32 bytes / 64 hex chars")
    func digestShape() {
        let hash = StateHash.of(Array("parlor".utf8))
        #expect(hash.bytes.count == 32)
        #expect(hash.hex.count == 64)
    }

    @Test("StateHash round-trips through Codable as hex")
    func codableRoundTrip() throws {
        let hash = StateHash.of(Array("state".utf8))
        let data = try JSONEncoder().encode(hash)
        let decoded = try JSONDecoder().decode(StateHash.self, from: data)
        #expect(decoded == hash)
        #expect(decoded.hex == hash.hex)
    }

    // MARK: - Canonical encoding determinism (ADR 0002 decision 4)

    /// A small Codable state stand-in. The determinism primitive under test is: identical logical state
    /// → identical hash, regardless of in-memory ordering (dictionaries here exercise `.sortedKeys`).
    private struct FakeState: Codable {
        var seats: [String]
        var scores: [String: Int]
        var handSeed: UInt64
    }

    @Test("equal logical state hashes identically regardless of dictionary insertion order")
    func canonicalDictionaryOrderStable() throws {
        let a = FakeState(
            seats: ["seat-0", "seat-1"],
            scores: ["seat-0": 3, "seat-1": 7, "seat-2": 0],
            handSeed: 12345)
        // Same values, different insertion order for the dictionary.
        var reordered: [String: Int] = [:]
        reordered["seat-2"] = 0
        reordered["seat-1"] = 7
        reordered["seat-0"] = 3
        let b = FakeState(seats: ["seat-0", "seat-1"], scores: reordered, handSeed: 12345)

        let hashA = try StateHash.canonical(a)
        let hashB = try StateHash.canonical(b)
        #expect(hashA == hashB)
    }

    @Test("a change in state changes the hash")
    func changeChangesHash() throws {
        let base = FakeState(seats: ["seat-0"], scores: ["seat-0": 1], handSeed: 1)
        let changed = FakeState(seats: ["seat-0"], scores: ["seat-0": 2], handSeed: 1)
        #expect(try StateHash.canonical(base) != StateHash.canonical(changed))
    }

    // MARK: - Determinism contract primitive (R-ENG-4.4)

    /// The determinism contract at the primitive level: the same hand seed replayed through the same
    /// recorded sequence of operations (here, shuffles) yields an identical final state hash on every
    /// run. Full action-log replay is exercised later in parlor-sim (task 8.1); this proves the seed →
    /// shuffle → canonical-hash chain is reproducible.
    private func finalHash(seed: UInt64, operationSeeds: [UInt64]) throws -> StateHash {
        var deck = Array(0..<52)
        var rng = SeededRNG(seed: seed)
        Shuffle.fisherYates(&deck, using: &rng)
        // Apply a recorded sequence of further shuffles as stand-in "operations".
        for opSeed in operationSeeds {
            var opRNG = SeededRNG(seed: opSeed)
            Shuffle.fisherYates(&deck, using: &opRNG)
        }
        return try StateHash.canonical(deck)
    }

    @Test("same seed + same operation log → identical final hash across runs")
    func determinismReplay() throws {
        let ops: [UInt64] = [10, 20, 30, 40]
        let run1 = try finalHash(seed: 2024, operationSeeds: ops)
        let run2 = try finalHash(seed: 2024, operationSeeds: ops)
        #expect(run1 == run2)
    }

    @Test("a different seed → a different final hash")
    func determinismSeedSensitive() throws {
        let ops: [UInt64] = [10, 20, 30, 40]
        let run1 = try finalHash(seed: 2024, operationSeeds: ops)
        let run2 = try finalHash(seed: 2025, operationSeeds: ops)
        #expect(run1 != run2)
    }

    @Test("a different operation log → a different final hash")
    func determinismLogSensitive() throws {
        let run1 = try finalHash(seed: 2024, operationSeeds: [10, 20, 30, 40])
        let run2 = try finalHash(seed: 2024, operationSeeds: [10, 20, 30, 41])
        #expect(run1 != run2)
    }
}
