import Foundation
import Testing

@testable import EngineCore

// The view-leak property test (task 2.8, R-QA-3.1, implements R-ENG-8.3).
//
// Task 2.6's ViewsRedactionTests prove the redaction mechanism with targeted, hand-built cases. This
// file proves the *property* those cases only sample: across many RANDOM game states and EVERY viewer,
// the SERIALIZED view (the JSON that would actually cross the host boundary) contains no identity of any
// piece hidden from that viewer (R-QA-3.1). It also proves, at the serialized-view level, the two
// guarantees that make redaction trustworthy rather than merely present:
//
//   • non-vacuity — every piece the policy *does* expose to a viewer is revealed with its real identity,
//     so redaction is not just hiding everything; and
//   • non-correlation (R-ENG-8.3) — the token a hidden piece gets under one viewer/salt is unrelated to
//     the token it gets under another, so two serialized views cannot be joined by token value to
//     deanonymize a piece.
//
// Every fixture is fully determined by its seed via `SeededRNG`, so a failure prints the offending seed
// and is reproducible on its own. `debugOmniscient` is exercised separately: it is the debug-only path
// that intentionally sees everything (design.md §2.8), so it documents the exception and the
// leak-freedom assertion applies to the shipping viewers (seats + spectator).

// MARK: - Random fixture

/// A randomly generated authoritative game state: a set of `Zone`s over a real deck of pieces, plus the
/// seats at the table and a face resolver. Everything is derived deterministically from a single seed, so
/// the whole fixture is reproducible from the seed printed on failure.
private struct Fixture {
    /// The seats at the table (owners of some zones and the seat viewers).
    let seats: [SeatID]
    /// The authoritative zones (ground truth the host holds).
    let zones: [Zone]
    /// Real face for every materialized piece, by identity — the game's PieceID → face map.
    let faces: [PieceID: KnownPiece]
    /// The seed this fixture was generated from (for reproducibility on failure).
    let seed: UInt64

    /// Resolve a piece's real face, as a game's `faceResolver` would.
    func resolve(_ id: PieceID) -> KnownPiece? { faces[id] }
}

/// Builds a random `Fixture` from `seed`. The generation walks the same `SeededRNG` the engine uses, so
/// the state is reproducible; it deliberately covers all five `Visibility` policies, owned and shared
/// zones, and a random face-up subset per zone so the sampled space is broad.
private enum FixtureFactory {
    /// Every visibility policy, so random zones cover all five (R-ENG-3.2).
    private static let policies: [Visibility] = [
        .hidden, .ownerOnly, .publicAll, .topCardOnly, .perPieceFaceState,
    ]

    /// A varied pool of real decks (cards and tiles) to draw pieces from, so fixtures exercise both
    /// `KnownPiece` kinds and duplicate faces (Spider, Pinochle, Tile Rummy) with unique `PieceID`s.
    private static let decks: [DeckDefinition] = [
        .standard52, .euchre24, .spider104, .pinochle48, .tileRummy106,
    ]

    static func make(seed: UInt64) -> Fixture {
        var rng = SeededRNG(seed: seed)

        // Materialize one real deck. `makeCards`/`makeTiles` mint a unique PieceID per slot (R-ENG-1.2),
        // so every piece in the fixture has a distinct identity — which is what makes the leak scan
        // sound (a raw id belongs to exactly one piece).
        let deck = decks[Int(rng.next() % UInt64(decks.count))]
        var faces: [PieceID: KnownPiece] = [:]
        var allPieces: [PieceID] = []
        for card in deck.makeCards() {
            faces[card.id] = .card(card)
            allPieces.append(card.id)
        }
        for tile in deck.makeTiles() {
            faces[tile.id] = .tile(tile)
            allPieces.append(tile.id)
        }

        // Shuffle the pieces with the engine's own Fisher–Yates so distribution is seed-reproducible.
        Shuffle.fisherYates(&allPieces, using: &rng)

        // 2…5 seats.
        let seatCount = 2 + Int(rng.next() % 4)
        let seats = (0..<seatCount).map { SeatID.index($0) }

        // 3…8 zones. Partition the shuffled pieces across them into contiguous ordered runs so order is
        // meaningful and every piece lives in exactly one zone.
        let zoneCount = 3 + Int(rng.next() % 6)
        var zones: [Zone] = []
        zones.reserveCapacity(zoneCount)

        // Compute a random split of `allPieces.count` into `zoneCount` non-negative sizes.
        let sizes = randomPartition(total: allPieces.count, into: zoneCount, using: &rng)
        var cursor = 0
        for z in 0..<zoneCount {
            let size = sizes[z]
            let contents = Array(allPieces[cursor..<(cursor + size)])
            cursor += size

            let policy = policies[Int(rng.next() % UInt64(policies.count))]

            // Owner: for owned-style zones sometimes give a real seat, sometimes leave shared (nil), so
            // the ownerOnly-with-no-owner path and shared zones are both covered.
            let owner: SeatID?
            if rng.next() % 3 == 0 {
                owner = nil
            } else {
                owner = seats[Int(rng.next() % UInt64(seats.count))]
            }

            // A random face-up subset (relevant to perPieceFaceState and topCardOnly), each piece 50/50.
            var faceUp: Set<PieceID> = []
            for piece in contents where rng.next() % 2 == 0 {
                faceUp.insert(piece)
            }

            zones.append(
                Zone(
                    id: ZoneID(name: "zone-\(z)", owner: owner),
                    visibility: policy,
                    contents: contents,
                    faceUp: faceUp))
        }

        return Fixture(seats: seats, zones: zones, faces: faces, seed: seed)
    }

    /// Split `total` into `parts` non-negative integers summing to `total`, chosen from `rng`. Uses a
    /// simple stars-and-bars style walk: for each part but the last, take a random share of what remains.
    private static func randomPartition(total: Int, into parts: Int, using rng: inout SeededRNG)
        -> [Int]
    {
        guard parts > 0 else { return [] }
        var sizes: [Int] = []
        var remaining = total
        for part in 0..<parts {
            if part == parts - 1 {
                sizes.append(remaining)
            } else {
                let take = remaining == 0 ? 0 : Int(rng.next() % UInt64(remaining + 1))
                sizes.append(take)
                remaining -= take
            }
        }
        return sizes
    }
}

// MARK: - Serialized-view leak analysis

/// The result of decoding and analyzing a serialized `PlayerView` against the fixture's ground truth.
private struct LeakAnalysis {
    /// Identities the viewer is allowed to see (visible under the zone policy).
    var visible: Set<PieceID> = []
    /// Identities hidden from the viewer (must never appear in the serialized view).
    var hidden: Set<PieceID> = []
    /// Identities that actually appeared as `.known` in the decoded view.
    var revealedIdentities: Set<PieceID> = []
    /// Tokens the decoded view showed for hidden slots (for cross-view non-correlation checks).
    var hiddenTokensByPiece: [PieceID: UInt64] = [:]
}

@Suite("View-leak property test (R-QA-3.1)")
struct ViewLeakPropertyTests {

    /// Number of random fixtures sampled. Each fixture is checked against every seat viewer plus the
    /// spectator, so the number of redacted, serialized views examined is far larger than this.
    private static let sampleCount: UInt64 = 400

    /// A fixed, arbitrary per-view salt. The property must hold for any salt; a constant one keeps
    /// failures reproducible and lets the cross-view check vary only the viewer.
    private static let salt: UInt64 = 0x5A17_0000_0000_0001

    // MARK: - The property

    @Test("random states × every shipping viewer → serialized view leaks no hidden identity")
    func serializedViewLeaksNoHiddenIdentity() throws {
        let encoder = JSONEncoder()
        var totalViewsChecked = 0
        var totalHiddenSlotsChecked = 0
        var totalRevealedSlotsChecked = 0

        for seed in Self.sampleCount == 0 ? [] : Array(UInt64(1)...Self.sampleCount) {
            let fixture = FixtureFactory.make(seed: seed)

            // Every shipping viewer: each seat at the table, plus a spectator. debugOmniscient is the
            // debug-only exception and is checked separately below.
            var viewers: [Viewer] = fixture.seats.map { .seat($0) }
            viewers.append(.spectator)

            for viewer in viewers {
                let analysis = try analyze(fixture: fixture, viewer: viewer, encoder: encoder)

                // (1) Leak-freedom: no identity hidden from this viewer may appear as a revealed
                // identity anywhere in the serialized view (R-QA-3.1).
                let leaked = analysis.hidden.intersection(analysis.revealedIdentities)
                #expect(
                    leaked.isEmpty,
                    """
                    hidden identity leaked into the serialized view — \
                    seed=\(fixture.seed) viewer=\(viewer) leaked=\(leaked.map(\.raw).sorted())
                    """)

                // (2) Non-vacuity: every identity the policy exposes to this viewer IS revealed, so the
                // test cannot pass by simply hiding everything.
                let overRedacted = analysis.visible.subtracting(analysis.revealedIdentities)
                #expect(
                    overRedacted.isEmpty,
                    """
                    a piece the viewer should see was over-redacted — \
                    seed=\(fixture.seed) viewer=\(viewer) missing=\(overRedacted.map(\.raw).sorted())
                    """)

                totalViewsChecked += 1
                totalHiddenSlotsChecked += analysis.hiddenTokensByPiece.count
                totalRevealedSlotsChecked += analysis.revealedIdentities.count
            }
        }

        // The suite is only meaningful if it exercised both hidden and revealed slots across the sample;
        // otherwise "no leak" would be vacuously true. Assert the sample was substantive.
        #expect(totalViewsChecked > 0, "no views were checked — fixture generation is broken")
        #expect(
            totalHiddenSlotsChecked > 0,
            "no hidden slots were exercised — the leak assertion would be vacuous")
        #expect(
            totalRevealedSlotsChecked > 0,
            "no revealed slots were exercised — the non-vacuity check would be meaningless")
    }

    // MARK: - Byte-level backstop

    @Test("no hidden piece's raw identity appears anywhere in the serialized JSON bytes")
    func serializedBytesContainNoHiddenIdentity() throws {
        // A stronger, structure-independent backstop: scan the raw JSON string for the numeric raw id of
        // any piece that is *exclusively hidden* from the viewer in this fixture. Because every piece has
        // a unique PieceID (R-ENG-1.2) and lives in exactly one zone, an id that belongs to a hidden
        // piece belongs to no visible piece, so its appearance in the bytes would be a real leak. Ids
        // that are also legitimately visible are excluded from the scan to keep it sound.
        let encoder = JSONEncoder()
        var scans = 0
        var idsScanned = 0

        for seed in Array(UInt64(1)...min(Self.sampleCount, 120)) {
            let fixture = FixtureFactory.make(seed: seed)
            var viewers: [Viewer] = fixture.seats.map { .seat($0) }
            viewers.append(.spectator)

            for viewer in viewers {
                // Every piece has a unique id and lives in exactly one zone, so a piece not visible to
                // this viewer is exclusively hidden: its raw id belongs to no visible piece.
                let visible = Self.visibleIdentities(in: fixture, to: viewer)
                let hiddenExclusive = Set(fixture.faces.keys).subtracting(visible)

                let view = Self.makeView(fixture: fixture, viewer: viewer)
                let data = try encoder.encode(view)
                let json = String(decoding: data, as: UTF8.self)

                for id in hiddenExclusive {
                    // A PieceID always serializes as `{"raw":<number>}`, and a revealed piece carries its
                    // identity as the `id` field of a card/tile, i.e. `"id":{"raw":<N>}`. So the exact,
                    // collision-free needle for "this hidden identity leaked" is the substring
                    // `"raw":<N>` terminated by a non-digit. Seat ids also use a `raw` key but encode as
                    // strings (`"raw":"seat-1"`) — the character after the colon is a quote, not a digit,
                    // so they never match a numeric PieceID and the scan stays sound. A hidden slot is an
                    // opaque token (`{"opaque":<64-bit>}`) whose value is unrelated to the raw id.
                    #expect(
                        !Self.jsonContainsRawIdentity(json, rawID: id.raw),
                        """
                        hidden piece raw id \(id.raw) found in serialized bytes — \
                        seed=\(fixture.seed) viewer=\(viewer)
                        """)
                    idsScanned += 1
                }
                scans += 1
            }
        }

        #expect(scans > 0)
        #expect(idsScanned > 0, "no hidden ids were scanned — backstop would be vacuous")
    }

    // MARK: - Non-correlation across views (R-ENG-8.3)

    @Test("the same hidden piece gets uncorrelated tokens across two different viewers")
    func hiddenTokensUncorrelatedAcrossViewers() throws {
        // For each fixture with at least two seats, take the two seat viewers and, at the serialized-view
        // level, confirm that the pieces hidden from BOTH never share a token value. If they never share
        // a token, an attacker cannot join the two serialized views by token value to align a piece
        // across them (R-ENG-8.3, R-QA-3.1).
        let encoder = JSONEncoder()
        var comparisons = 0
        var sharedHiddenPieces = 0

        for seed in Array(UInt64(1)...min(Self.sampleCount, 200)) {
            let fixture = FixtureFactory.make(seed: seed)
            guard fixture.seats.count >= 2 else { continue }
            let viewerA = Viewer.seat(fixture.seats[0])
            let viewerB = Viewer.seat(fixture.seats[1])

            let a = try analyze(fixture: fixture, viewer: viewerA, encoder: encoder)
            let b = try analyze(fixture: fixture, viewer: viewerB, encoder: encoder)

            // Pieces hidden from both viewers: these are the ones an attacker would try to correlate.
            let bothHidden = Set(a.hiddenTokensByPiece.keys)
                .intersection(b.hiddenTokensByPiece.keys)
            for piece in bothHidden {
                sharedHiddenPieces += 1
                let tokenA = a.hiddenTokensByPiece[piece]
                let tokenB = b.hiddenTokensByPiece[piece]
                #expect(
                    tokenA != tokenB,
                    """
                    a hidden piece kept the same token across two viewers (correlatable) — \
                    seed=\(fixture.seed) piece=\(piece.raw)
                    """)
            }
            comparisons += 1
        }

        #expect(comparisons > 0, "no two-seat fixtures were compared")
        #expect(
            sharedHiddenPieces > 0,
            "no piece was hidden from both viewers — the non-correlation check would be vacuous")
    }

    // MARK: - debugOmniscient documents the exception (design.md §2.8)

    @Test("debugOmniscient sees every identity — the documented debug-only exception")
    func debugOmniscientSeesEverything() throws {
        // debugOmniscient is intentionally not leak-free: it is the debug/inspection path that bypasses
        // policy (design.md §2.8). This test documents that exception so the leak-freedom property is
        // understood to apply to the shipping viewers only.
        let encoder = JSONEncoder()
        var checked = 0
        for seed in Array(UInt64(1)...min(Self.sampleCount, 60)) {
            let fixture = FixtureFactory.make(seed: seed)
            let analysis = try analyze(
                fixture: fixture, viewer: .debugOmniscient, encoder: encoder)
            // Everything with a resolvable face is revealed; nothing is tokenized.
            #expect(
                analysis.hiddenTokensByPiece.isEmpty,
                "debugOmniscient tokenized a piece — seed=\(fixture.seed)")
            #expect(analysis.revealedIdentities == Set(fixture.faces.keys))
            checked += 1
        }
        #expect(checked > 0)
    }

    // MARK: - Serialization stability

    @Test("re-serializing the same redacted view is byte-stable")
    func reserializationIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for seed in Array(UInt64(1)...min(Self.sampleCount, 40)) {
            let fixture = FixtureFactory.make(seed: seed)
            let view = Self.makeView(fixture: fixture, viewer: .spectator)
            let first = try encoder.encode(view)
            let second = try encoder.encode(view)
            #expect(first == second, "serialized view was not stable — seed=\(fixture.seed)")
        }
    }

    // MARK: - Helpers

    /// Build the redacted `PlayerView` for `viewer` over the fixture's zones, using the fixed salt.
    private static func makeView(fixture: Fixture, viewer: Viewer) -> PlayerView {
        let zoneViews = Redaction.zoneViews(
            of: fixture.zones, for: viewer, salt: salt, faceResolver: fixture.resolve)
        let scores = Dictionary(uniqueKeysWithValues: fixture.seats.map { ($0, 0) })
        return PlayerView(
            viewer: viewer,
            zones: zoneViews,
            scores: scores,
            phase: Phase(rawValue: "play"),
            legalActions: [])
    }

    /// The ground-truth set of identities visible to `viewer`, derived independently from the redaction
    /// under test via `Redaction.isVisible` plus the fixture's own face resolver (a piece the resolver
    /// cannot vouch for is conservatively hidden, matching `zoneViews`).
    private static func visibleIdentities(in fixture: Fixture, to viewer: Viewer) -> Set<PieceID> {
        var visible: Set<PieceID> = []
        for zone in fixture.zones {
            for piece in zone.contents
            where Redaction.isVisible(piece: piece, in: zone, to: viewer)
                && fixture.resolve(piece) != nil
            {
                visible.insert(piece)
            }
        }
        return visible
    }

    /// Encode `viewer`'s redacted view, decode it back, and reconcile the decoded structure against the
    /// fixture's ground truth: what the viewer may see, what is hidden, what identities actually appeared
    /// as `.known`, and the token shown for each hidden slot.
    private func analyze(fixture: Fixture, viewer: Viewer, encoder: JSONEncoder) throws
        -> LeakAnalysis
    {
        let view = Self.makeView(fixture: fixture, viewer: viewer)
        let data = try encoder.encode(view)
        let decoded = try JSONDecoder().decode(PlayerView.self, from: data)

        var analysis = LeakAnalysis()
        analysis.visible = Self.visibleIdentities(in: fixture, to: viewer)
        analysis.hidden = Set(fixture.faces.keys).subtracting(analysis.visible)

        // Collect every identity that appeared as `.known` anywhere in the decoded view; these are the
        // identities actually revealed to the viewer.
        for zoneView in decoded.zones {
            for piece in zoneView.pieces {
                if case .known(let known) = piece {
                    analysis.revealedIdentities.insert(known.id)
                }
            }
        }

        // Map each hidden slot's token back to the real piece it stands for, positionally: redaction
        // preserves zone and piece order (proven in task 2.6), so slot `i` of decoded zone `z` is the
        // authoritative piece at slot `i` of zone `z`. This lets the cross-view non-correlation check
        // compare the tokens two viewers assigned to the SAME real piece (R-ENG-8.3).
        for (zoneIndex, zone) in fixture.zones.enumerated() {
            let decodedPieces = decoded.zones[zoneIndex].pieces
            for (slot, piece) in zone.contents.enumerated() {
                if case .hidden(let token) = decodedPieces[slot] {
                    analysis.hiddenTokensByPiece[piece] = token.opaque
                }
            }
        }

        return analysis
    }

    /// Whether `json` contains the encoded form of a `PieceID` with value `rawID` — the substring
    /// `"raw":<rawID>` terminated by a non-digit. Anchoring on the `"raw":` key plus a trailing
    /// non-digit means it matches only a serialized numeric identity: it will not match a longer number
    /// (`16` inside `160`), a 64-bit `opaque` token value (a different key), or a string seat id
    /// (`"raw":"seat-1"`, where the byte after the colon is a quote, not a digit).
    private static func jsonContainsRawIdentity(_ json: String, rawID: UInt64) -> Bool {
        let needle = "\"raw\":\(rawID)"
        let chars = Array(json.utf8)
        let target = Array(needle.utf8)
        guard !target.isEmpty, chars.count >= target.count else { return false }

        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

        var i = 0
        let end = chars.count - target.count
        while i <= end {
            if Array(chars[i..<(i + target.count)]) == target {
                let afterIndex = i + target.count
                let after = afterIndex < chars.count ? chars[afterIndex] : nil
                // The match is a real identity only if the number ends here (next byte is not a digit),
                // so `"raw":16` is not seen inside `"raw":160`.
                if after.map({ !isDigit($0) }) ?? true { return true }
            }
            i += 1
        }
        return false
    }
}
