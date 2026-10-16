// Klondike near-win fixture tests (task 7.4) — the deterministic near-win position the accessibility UI
// suite drives to a keyboard-only win (R-A11Y-5.1).
//
// The pure `Klondike.nearWinState(options:)` factory lives in the package so it is unit-testable here,
// while the app's DEBUG launch-argument reader that calls it is compiled by the Xcode project. These
// tests prove the fixture is (a) a well-formed 52-card position, (b) not yet terminal, and (c) exactly
// one `tableauToFoundation` move per suit away from a win — so the UI test's few key presses genuinely
// finish the game rather than relying on incidental behavior.

import EngineCore
import Foundation
import Testing

@testable import GamesRules

@Suite("Klondike — near-win fixture (R-A11Y-5.1)")
struct KlondikeDebugTests {
    let game = Klondike()

    @Test("near-win state contains all 52 cards exactly once")
    func containsFullPack() {
        let s = Klondike.nearWinState()
        let idsInZones =
            s.stock.contents + s.waste.contents
            + s.tableau.flatMap(\.contents) + s.foundations.flatMap(\.contents)
        #expect(idsInZones.count == 52)
        #expect(Set(idsInZones).count == 52)  // no duplicate identities
        #expect(s.faces.count == 52)
        #expect(Set(s.faces.values).count == 52)  // all 52 distinct faces present
    }

    @Test("48 cards are home and the four Kings sit face-up on tableau piles 0–3")
    func layoutIsNearWin() {
        let s = Klondike.nearWinState()
        // Every foundation is built A→Q (12 cards), so 48 are home and 4 remain.
        #expect(s.foundations.allSatisfy { $0.contents.count == 12 })
        #expect(s.foundations.reduce(0) { $0 + $1.contents.count } == 48)

        // Piles 0–3 each hold exactly one face-up King; piles 4–6 are empty.
        for pile in 0..<4 {
            let zone = s.tableau[pile]
            #expect(zone.contents.count == 1)
            let top = zone.contents[0]
            #expect(zone.isFaceUp(top))
            #expect(KlondikeCard.isKing(s.face(of: top)!))
        }
        #expect(s.tableau[4...].allSatisfy { $0.contents.isEmpty })

        // Stock and waste are empty — no drawing needed to finish.
        #expect(s.stock.contents.isEmpty)
        #expect(s.waste.contents.isEmpty)
    }

    @Test("near-win state is not yet terminal")
    func notYetTerminal() {
        #expect(!game.isTerminal(Klondike.nearWinState()))
    }

    @Test("the four King-to-foundation moves are available, and taking them wins in four")
    func fourMovesToWin() {
        var state = Klondike.nearWinState()

        // Exactly one King→foundation move is available per suit (four in all). Note the board is NOT
        // limited to these four legal actions: a lone King may also move to any of the empty tableau
        // piles 4–6 (the King-to-empty rule, R-KLON-1.4), so the full legal set is larger. What matters
        // for the near-win fixture is that the four home moves exist and completing them wins.
        let foundationMoves = game.legalActions(for: klondikeSeat, in: state).filter {
            if case .tableauToFoundation = $0 { return true }
            return false
        }
        #expect(foundationMoves.count == 4)

        // Greedily take a King→foundation move each turn; the game is won in exactly four such moves.
        var applied = 0
        while !game.isTerminal(state) {
            let move = game.legalActions(for: klondikeSeat, in: state).first { action in
                if case .tableauToFoundation = action { return true }
                return false
            }
            guard let move else { break }
            let (next, _) = try! game.apply(move, by: klondikeSeat, to: state).get()
            state = next
            applied += 1
            #expect(applied <= 4)  // must not take more than four foundation moves
        }
        #expect(game.isTerminal(state))
        #expect(applied == 4)
        #expect(game.outcome(state).winners == [klondikeSeat])
    }

    @Test("initialState with debugNearWin deals the near-win fixture (seed ignored)")
    func initialStateHonorsDebugNearWin() throws {
        // The DEBUG launch-argument path (task 7.4) sets `debugNearWin` on the options; `initialState`
        // must then return the near-win fixture rather than a random deal, regardless of the seed — this
        // is what lets the near-win deal flow through the normal GameHost/AutosaveSession path.
        let options = KlondikeOptions(debugNearWin: true)
        let dealt = game.initialState(options: options, seed: 12_345)
        let fixture = Klondike.nearWinState(options: options)

        // Compare LOGICALLY, order-independently: `KlondikeState` is not `Equatable`, and its `faces`
        // (`[PieceID: CardFace]`) and each zone's `faceUp` (`Set`) have no stable serialization order, so a
        // raw JSON byte comparison is not a valid equality check (that ordering is exactly what the
        // engine's canonical hashing normalizes away — R-ENG-4.4). `logicalKey(_:)` folds a state into an
        // order-independent snapshot for comparison.
        #expect(logicalKey(dealt) == logicalKey(fixture))

        // A different seed still yields the same near-win position (seed is ignored when the flag is on).
        let otherSeed = game.initialState(options: options, seed: 999)
        #expect(logicalKey(dealt) == logicalKey(otherSeed))

        // The dealt position is genuinely four foundation moves from a win.
        var state = dealt
        var applied = 0
        while !game.isTerminal(state) {
            let move = game.legalActions(for: klondikeSeat, in: state).first { action in
                if case .tableauToFoundation = action { return true }
                return false
            }
            guard let move else { break }
            state = try game.apply(move, by: klondikeSeat, to: state).get().0
            applied += 1
        }
        #expect(game.isTerminal(state))
        #expect(applied == 4)
    }

    @Test("a normal deal (debugNearWin off) is NOT the near-win fixture")
    func normalDealDiffersFromFixture() throws {
        let normal = game.initialState(options: KlondikeOptions(), seed: 1)
        // A fresh deal has 24 cards in the stock; the fixture's stock is empty.
        #expect(!normal.stock.contents.isEmpty)
        #expect(!game.isTerminal(normal))
    }

    @Test("fixture is deterministic — identical across calls")
    func deterministic() throws {
        // Two constructions describe the SAME logical position. We compare with the order-independent
        // `logicalKey`, not a raw byte encoding, because `faces` (a dictionary) and `faceUp` (a set) have
        // no guaranteed iteration order — the very ordering the engine's canonical hashing normalizes away
        // (R-ENG-4.4). Comparing sorted contents proves the fixture is reproducible without depending on
        // incidental collection ordering.
        #expect(logicalKey(Klondike.nearWinState()) == logicalKey(Klondike.nearWinState()))
    }

    /// An order-independent snapshot of a `KlondikeState` for equality comparison in tests.
    ///
    /// Folds the state into fully-ordered primitive components: each zone's ordered `contents` and its
    /// `faceUp` set as a sorted array, plus the `faces` map as key/value pairs sorted by `PieceID.raw`,
    /// plus the scalar fields. Two states with the same logical position produce the same key regardless
    /// of dictionary/set iteration order (the ordering the canonical state hash also ignores — R-ENG-4.4).
    private func logicalKey(_ s: KlondikeState) -> String {
        func zoneKey(_ z: Zone) -> String {
            let contents = z.contents.map { String($0.raw) }.joined(separator: ",")
            let faceUp = z.faceUp.map { $0.raw }.sorted().map(String.init).joined(separator: ",")
            return "\(z.id.name)|[\(contents)]|{\(faceUp)}"
        }
        let zones =
            ([s.stock, s.waste] + s.tableau + s.foundations).map(zoneKey).joined(separator: ";")
        let faces =
            s.faces
            .map { (id, face) in "\(id.raw)=\(String(describing: face))" }
            .sorted()
            .joined(separator: ",")
        return "zones=\(zones)|faces=\(faces)|score=\(s.score)|passes=\(s.passes)"
    }
}
