import Foundation
import Testing

@testable import EngineCore

// Tests for zones and visibility (R-ENG-3.1, R-ENG-3.2), plus the SeatID owner type they rely on.

@Suite("Zones and visibility (R-ENG-3)")
struct ZonesTests {

    // MARK: - Ownership: seat vs shared/none (R-ENG-3.1)

    @Test("a zone can be owned by a seat")
    func ownedBySeat() {
        let seat = SeatID.index(0)
        let zone = Zone(id: ZoneID(name: "hand", owner: seat), visibility: .ownerOnly)
        #expect(zone.owner == seat)
        #expect(zone.id.owner == seat)
    }

    @Test("a zone with no owner is shared/none")
    func sharedZone() {
        let zone = Zone(id: ZoneID(name: "stock"), visibility: .hidden)
        #expect(zone.owner == nil)
        #expect(zone.id.owner == nil)
    }

    @Test("SeatID.index produces the documented seat-<n> token")
    func seatIndexToken() {
        #expect(SeatID.index(2) == SeatID(raw: "seat-2"))
        #expect(SeatID.index(2).description == "seat-2")
    }

    @Test("SeatID round-trips through Codable")
    func seatCodableRoundTrip() throws {
        let seat = SeatID.index(3)
        let data = try JSONEncoder().encode(seat)
        let decoded = try JSONDecoder().decode(SeatID.self, from: data)
        #expect(decoded == seat)
    }

    // MARK: - Ordered contents (R-ENG-3.1)

    @Test("contents preserve insertion order")
    func contentsOrdered() {
        let ids = (0..<5).map { PieceID(raw: UInt64($0)) }
        let zone = Zone(
            id: ZoneID(name: "tableau", owner: nil), visibility: .publicAll, contents: ids)
        #expect(zone.contents == ids)
    }

    @Test("top is the last piece in contents, nil when empty")
    func topIsLast() {
        let ids = [PieceID(raw: 10), PieceID(raw: 20), PieceID(raw: 30)]
        let zone = Zone(id: ZoneID(name: "discard"), visibility: .topCardOnly, contents: ids)
        #expect(zone.top == PieceID(raw: 30))

        let empty = Zone(id: ZoneID(name: "discard"), visibility: .topCardOnly)
        #expect(empty.top == nil)
    }

    @Test("contents order survives a Codable round-trip")
    func contentsCodableRoundTrip() throws {
        let ids = (0..<8).map { PieceID(raw: UInt64($0 * 3)) }
        let zone = Zone(id: ZoneID(name: "stock"), visibility: .hidden, contents: ids)
        let data = try JSONEncoder().encode(zone)
        let decoded = try JSONDecoder().decode(Zone.self, from: data)
        #expect(decoded.contents == ids)
    }

    // MARK: - Visibility cases present + Codable (R-ENG-3.2)

    /// Every visibility case the requirements call out must exist and round-trip.
    static let allVisibilities: [Visibility] = [
        .hidden, .ownerOnly, .publicAll, .topCardOnly, .perPieceFaceState,
    ]

    @Test("every required visibility case round-trips through Codable", arguments: allVisibilities)
    func visibilityCodableRoundTrip(_ visibility: Visibility) throws {
        let data = try JSONEncoder().encode(visibility)
        let decoded = try JSONDecoder().decode(Visibility.self, from: data)
        #expect(decoded == visibility)
    }

    @Test("the required visibility policies are all present")
    func requiredVisibilityCasesPresent() {
        // hidden, owner-only, public, top-card-only, and face-up/face-down per piece (R-ENG-3.2).
        #expect(Self.allVisibilities.count == 5)
        #expect(Set(Self.allVisibilities).count == 5)
    }

    // MARK: - faceUp behaviour for perPieceFaceState / topCardOnly (R-ENG-3.3)

    @Test("faceUp set records which pieces are face-up for perPieceFaceState")
    func perPieceFaceState() {
        let a = PieceID(raw: 1)
        let b = PieceID(raw: 2)
        let c = PieceID(raw: 3)
        let zone = Zone(
            id: ZoneID(name: "tableau", owner: nil),
            visibility: .perPieceFaceState,
            contents: [a, b, c],
            faceUp: [b, c]
        )
        #expect(zone.isFaceUp(a) == false)
        #expect(zone.isFaceUp(b))
        #expect(zone.isFaceUp(c))
    }

    @Test("faceUp defaults to empty — all pieces face-down")
    func faceUpDefaultsEmpty() {
        let ids = [PieceID(raw: 1), PieceID(raw: 2)]
        let zone = Zone(
            id: ZoneID(name: "hand", owner: .index(0)), visibility: .ownerOnly, contents: ids)
        #expect(zone.faceUp.isEmpty)
        #expect(ids.allSatisfy { !zone.isFaceUp($0) })
    }

    @Test("faceUp and visibility are mutable as pieces flip over a hand")
    func faceUpMutable() {
        let top = PieceID(raw: 99)
        var zone = Zone(id: ZoneID(name: "discard"), visibility: .topCardOnly, contents: [top])
        #expect(zone.isFaceUp(top) == false)
        zone.faceUp.insert(top)
        #expect(zone.isFaceUp(top))
        zone.visibility = .publicAll
        #expect(zone.visibility == .publicAll)
    }

    @Test("faceUp set survives a Codable round-trip")
    func faceUpCodableRoundTrip() throws {
        let contents = (0..<4).map { PieceID(raw: UInt64($0)) }
        let zone = Zone(
            id: ZoneID(name: "tableau", owner: nil),
            visibility: .perPieceFaceState,
            contents: contents,
            faceUp: [contents[1], contents[3]]
        )
        let data = try JSONEncoder().encode(zone)
        let decoded = try JSONDecoder().decode(Zone.self, from: data)
        #expect(decoded.faceUp == zone.faceUp)
    }

    // MARK: - ZoneID equality/hashing keyed by name + owner (R-ENG-3.1)

    @Test("ZoneIDs with the same name but different owners are distinct")
    func zoneIDDistinctByOwner() {
        let hand0 = ZoneID(name: "hand", owner: .index(0))
        let hand1 = ZoneID(name: "hand", owner: .index(1))
        #expect(hand0 != hand1)

        var set: Set<ZoneID> = [hand0, hand1]
        #expect(set.count == 2)
        set.insert(ZoneID(name: "hand", owner: .index(0)))  // duplicate
        #expect(set.count == 2)
    }

    @Test("ZoneIDs with the same name and owner are equal and hash equally")
    func zoneIDEqualByNameAndOwner() {
        let a = ZoneID(name: "stock", owner: nil)
        let b = ZoneID(name: "stock", owner: nil)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("a shared ZoneID differs from a seat-owned one with the same name")
    func zoneIDSharedVsOwned() {
        let shared = ZoneID(name: "discard", owner: nil)
        let owned = ZoneID(name: "discard", owner: .index(0))
        #expect(shared != owned)
    }

    @Test("ZoneID round-trips through Codable")
    func zoneIDCodableRoundTrip() throws {
        for id in [ZoneID(name: "hand", owner: .index(2)), ZoneID(name: "stock", owner: nil)] {
            let data = try JSONEncoder().encode(id)
            let decoded = try JSONDecoder().decode(ZoneID.self, from: data)
            #expect(decoded == id)
        }
    }
}
