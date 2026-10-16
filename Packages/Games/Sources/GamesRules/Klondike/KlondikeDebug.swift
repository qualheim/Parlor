// Klondike debug/test fixtures — deterministic near-win positions for UI tests (R-A11Y-5.1).
//
// The accessibility UI suite (task 7.4) needs to finish a Klondike game using ONLY the keyboard, but
// dealing and solving a full random game by hand would be slow and flaky. Instead the app exposes a
// DEBUG launch argument that starts Klondike from a NEAR-WIN position: nearly every card is already home
// on the foundations, so a handful of keyboard moves complete the game. The launch-argument WIRING lives
// in `App/Sources` (it is compiled by the Xcode project, not SwiftPM); the PURE position it starts from
// lives here so it is deterministic, reusable, and unit-testable under SwiftPM (design.md §1, §8).
//
// This is a fixture, not a rule: it constructs a valid `KlondikeState` directly rather than dealing from
// a seed, so the resulting board is guaranteed to be exactly one move away from a win per foundation.
// It is not `#if DEBUG`-gated in the package because the pure factory is harmless data and its unit test
// must build under the normal package test configuration; only the app's launch-argument READER that
// calls it is DEBUG-only.

import EngineCore
import Foundation

extension Klondike {

    /// A stable per-suit foundation index so the fixture (and its test) always agree which foundation
    /// holds which suit. Foundation `i` is built up in `suitOrder[i]`.
    static let debugFoundationSuitOrder: [Suit] = [.clubs, .diamonds, .hearts, .spades]

    /// Build a deterministic **near-win** Klondike position: every foundation already built up from Ace
    /// to Queen (48 cards home), and the four Kings sitting face-up as the sole card of tableau piles
    /// 0–3 (R-A11Y-5.1). The stock, waste, and tableau piles 4–6 are empty.
    ///
    /// From this position the game is exactly four `tableauToFoundation` moves from a win — one King per
    /// suit onto its matching foundation — so a UI test can finish Klondike keyboard-only in a few key
    /// presses. `PieceID`s are minted deterministically (suit-major, rank-minor) so the state is fully
    /// reproducible and hashes identically across runs (R-ENG-4.4).
    ///
    /// - Parameter options: the options the fixture game runs under (scoring/draw/passes are irrelevant
    ///   here since no draw/recycle is needed; defaults to `KlondikeOptions()`).
    /// - Returns: a valid `KlondikeState` one move-per-suit away from a win.
    public static func nearWinState(options: KlondikeOptions = KlondikeOptions()) -> KlondikeState {
        var faces: [PieceID: CardFace] = [:]

        // Deterministic id minting: suit index (0…3) major, rank raw value (1…13) minor. This keeps ids
        // stable and collision-free across the whole 52-card pack.
        func id(suitIndex: Int, rank: Rank) -> PieceID {
            PieceID(raw: UInt64(suitIndex * 13 + rank.rawValue))
        }
        func card(_ rank: Rank, _ suit: Suit, suitIndex: Int) -> Card {
            let c = Card(id: id(suitIndex: suitIndex, rank: rank), face: .standard(rank, suit))
            faces[c.id] = c.face
            return c
        }

        // Ranks Ace…Queen, in ascending foundation-build order (Ace at the bottom, Queen on top).
        let throughQueen: [Rank] = [
            .ace, .two, .three, .four, .five, .six, .seven, .eight, .nine, .ten, .jack, .queen,
        ]

        // Foundations: each built up A→Q in its suit (48 cards home). The King is intentionally absent.
        var foundations: [Zone] = []
        foundations.reserveCapacity(KlondikeZone.foundationCount)
        for (suitIndex, suit) in debugFoundationSuitOrder.enumerated() {
            let cards = throughQueen.map { card($0, suit, suitIndex: suitIndex) }
            foundations.append(
                Zone(
                    id: KlondikeZone.foundation(suitIndex),
                    visibility: .publicAll,
                    contents: cards.map(\.id)))
        }

        // Tableau: piles 0–3 each hold a single face-up King (its matching suit); piles 4–6 are empty.
        var tableau: [Zone] = []
        tableau.reserveCapacity(KlondikeZone.tableauCount)
        for pile in 0..<KlondikeZone.tableauCount {
            if pile < debugFoundationSuitOrder.count {
                let king = card(.king, debugFoundationSuitOrder[pile], suitIndex: pile)
                tableau.append(
                    Zone(
                        id: KlondikeZone.tableau(pile),
                        visibility: .perPieceFaceState,
                        contents: [king.id],
                        faceUp: [king.id]))
            } else {
                tableau.append(
                    Zone(id: KlondikeZone.tableau(pile), visibility: .perPieceFaceState))
            }
        }

        let stock = Zone(id: KlondikeZone.stockID, visibility: .hidden)
        let waste = Zone(id: KlondikeZone.wasteID, visibility: .publicAll)

        return KlondikeState(
            stock: stock,
            waste: waste,
            tableau: tableau,
            foundations: foundations,
            faces: faces,
            score: options.scoring == .vegas ? -52 : 0,
            passes: 1,
            options: options)
    }
}
