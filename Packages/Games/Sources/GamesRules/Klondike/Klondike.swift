// Klondike — the `GameDefinition` conformance (R-KLON-1, R-KLON-2, R-KLON-3.4; R-ENG-5).
//
// This is the whole rules contribution for Klondike: metadata, an options schema with presets, the
// initial deal from a seed, phases, legal-action enumeration, the transition function `apply`, terminal
// detection + outcome, view redaction, and the undo policy. No EngineCore or TableKit edits are needed
// (R-ENG-5.6; design.md §11).
//
// Design notes worth stating up front:
//
//   • The tableau top is kept face-up as a *rule*: whenever a move exposes a new top card on a tableau
//     pile, `apply` turns it face-up and emits `pieceFlipped`. This is standard Klondike and part of the
//     rules, distinct from the *auto-flip toggle* feature (task 3.5) which governs whether the UI does it
//     automatically vs. on tap. Keeping the exposed top turned up here is the minimal, correct behavior
//     and the seam for 3.5 is the toggle, not the flip itself.
//   • Scoring is centralized: Vegas (−52 start, +5 per card to a foundation) is applied inline;
//     Standard reads only the named constants in `KlondikeStandardScoring` (Q-1 NEEDS REVIEW); None
//     keeps no score. Score deltas are emitted as `scoreChanged` events.
//   • Redaction reuses EngineCore's `Redaction.zoneViews` over the state's zones (stock hidden, tableau
//     per-piece, waste/foundations public), so no hidden identity leaks (R-ENG-8.3).

import EngineCore
import Foundation

/// Klondike Solitaire as a `GameDefinition` (R-ENG-5; R-KLON-1/2/3.4).
public struct Klondike: GameDefinition {
    public typealias State = KlondikeState
    public typealias Action = KlondikeAction
    public typealias Options = KlondikeOptions

    public init() {}

    // MARK: - Metadata (R-ENG-5.1)

    public static let metadata = GameMetadata(
        id: "klondike",
        name: "Klondike",
        family: .solitaire,
        seatRange: 1...1,
        typicalDuration: DurationRange(minMinutes: 5, maxMinutes: 15),
        complexity: .light
    )

    // MARK: - Options schema + presets (R-ENG-5.2, R-KLON-2.5)

    /// Defaults (Draw 1, Standard, Unlimited passes, timed off) plus the named presets documented in
    /// `Docs/Rules/klondike.md` (R-KLON-2.5). Presets are what the setup sheet lists first (R-APP-2.1).
    public static let optionsSchema = OptionsSchema<KlondikeOptions>(
        defaults: KlondikeOptions(),
        presets: [
            OptionsPreset(
                name: "Draw 1 / Standard",
                options: KlondikeOptions(
                    drawCount: .one, scoring: .standard, stockPasses: .unlimited, timed: false)
            ),
            OptionsPreset(
                name: "Draw 3 / Vegas",
                options: KlondikeOptions(
                    drawCount: .three, scoring: .vegas, stockPasses: .three, timed: false,
                    vegasCumulative: false)
            ),
            OptionsPreset(
                name: "Relaxed / No scoring",
                options: KlondikeOptions(
                    drawCount: .one, scoring: .none, stockPasses: .unlimited, timed: false)
            ),
        ]
    )

    // MARK: - Phases (R-ENG-5.3)

    /// The single play phase. Klondike deals up front (in `initialState`) and then plays until the hand
    /// ends; there is no separate bidding/scoring phase to sequence.
    public static let playPhase = Phase(rawValue: "play")

    public func phase(of state: KlondikeState) -> Phase { Self.playPhase }

    public var undoPolicy: UndoPolicy { .unlimited }  // R-KLON-3.4

    // MARK: - Initial deal (R-KLON-1.1, R-ENG-5.3, R-ENG-4)

    /// Deal a fresh Klondike game from `options` and a recorded `seed` (R-KLON-1.1).
    ///
    /// The standard-52 pack is materialized, shuffled with the seeded Fisher–Yates (R-ENG-4.1), then
    /// dealt into 7 tableau piles of 1…7 cards (top card face up), 24 cards face-down to the stock, an
    /// empty waste, and 4 empty foundations. Vegas seeds the score at −52 (R-KLON-2.2); other schemes
    /// start at 0. `passes` starts at 1 (the initial deal-down counts as the first pass, R-KLON-2.3).
    public func initialState(options: KlondikeOptions, seed: UInt64) -> KlondikeState {
        var cards = DeckDefinition.standard52.makeCards()
        var rng = SeededRNG(seed: seed)
        Shuffle.fisherYates(&cards, using: &rng)

        var faces: [PieceID: CardFace] = [:]
        faces.reserveCapacity(cards.count)
        for card in cards { faces[card.id] = card.face }

        // Deal the tableau: pile i gets i+1 cards; the last dealt to each pile is face-up.
        var index = 0
        var tableau: [Zone] = []
        tableau.reserveCapacity(KlondikeZone.tableauCount)
        for pile in 0..<KlondikeZone.tableauCount {
            let count = pile + 1
            let slice = cards[index..<(index + count)]
            index += count
            let ids = slice.map(\.id)
            let faceUp: Set<PieceID> = ids.isEmpty ? [] : [ids[ids.count - 1]]
            tableau.append(
                Zone(
                    id: KlondikeZone.tableau(pile),
                    visibility: .perPieceFaceState,
                    contents: ids,
                    faceUp: faceUp
                )
            )
        }

        // Remaining 24 cards form the stock, face-down (hidden).
        let stockIDs = cards[index...].map(\.id)
        let stock = Zone(id: KlondikeZone.stockID, visibility: .hidden, contents: Array(stockIDs))

        let waste = Zone(id: KlondikeZone.wasteID, visibility: .publicAll)
        let foundations = (0..<KlondikeZone.foundationCount).map { i in
            Zone(id: KlondikeZone.foundation(i), visibility: .publicAll)
        }

        let startScore = options.scoring == .vegas ? -52 : 0

        return KlondikeState(
            stock: stock,
            waste: waste,
            tableau: tableau,
            foundations: foundations,
            faces: faces,
            score: startScore,
            passes: 1,
            options: options
        )
    }

    // MARK: - Terminal + outcome (R-ENG-5.5)

    /// A game is won when every foundation is complete — all 52 cards on the foundations (R-KLON-1.2).
    public func isTerminal(_ state: KlondikeState) -> Bool {
        state.foundations.reduce(0) { $0 + $1.contents.count } == 52
    }

    /// The outcome of a finished game: the single seat wins, with its score under the chosen scheme
    /// (R-ENG-5.5). A game reported terminal is always a win (all cards home); scoring conveys quality.
    public func outcome(_ state: KlondikeState) -> HandOutcome {
        let won = isTerminal(state)
        let score = state.options.scoring == .none ? 0 : state.score
        return HandOutcome(
            winners: won ? [klondikeSeat] : [],
            scores: [klondikeSeat: score]
        )
    }

    // MARK: - Redaction (R-ENG-5.5, R-ENG-8)

    /// The redacted view for `viewer`, built from the shared `Redaction` machinery over the state's
    /// zones (R-ENG-8.2/8.3). Stock is hidden, tableau reveals per face state, waste and foundations are
    /// public; a hidden card appears only as an opaque token. The salt is derived from the state so the
    /// tokenization is stable within a view yet uncorrelated across views (R-QA-3.1).
    public func redactedView(of state: KlondikeState, for viewer: Viewer) -> PlayerView {
        let salt = Self.viewSalt(for: state)
        let zones = Redaction.zoneViews(
            of: state.allZones,
            for: viewer,
            salt: salt,
            faceResolver: { piece in
                state.faces[piece].map { KnownPiece.card(Card(id: piece, face: $0)) }
            }
        )
        let legal: [AnyGameAction]
        if case .seat(let seat) = viewer, seat == klondikeSeat {
            legal = (try? legalActions(for: seat, in: state).map { try AnyGameAction($0) }) ?? []
        } else {
            legal = []
        }
        let visibleScore = state.options.scoring == .none ? 0 : state.score
        return PlayerView(
            viewer: viewer,
            zones: zones,
            scores: [klondikeSeat: visibleScore],
            phase: Self.playPhase,
            legalActions: legal
        )
    }

    /// A per-state salt for view tokenization — the count of hidden stock/tableau cards, mixed. Any
    /// stable-per-state value works; this avoids a fixed salt without needing external entropy.
    private static func viewSalt(for state: KlondikeState) -> UInt64 {
        var salt: UInt64 = 0xA5A5_5A5A_1234_ABCD
        salt = salt &+ UInt64(state.stock.contents.count) &* 0x1000_0001
        for pile in state.tableau {
            salt = salt &+ UInt64(pile.contents.count - pile.faceUp.count) &* 0x100_0007
        }
        return salt
    }
}
