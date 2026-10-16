// Crazy Eights — the `GameDefinition` conformance (R-CE-1…R-CE-4; R-ENG-5).
//
// This is the whole rules contribution for one HAND of Crazy Eights: metadata, an options schema with
// presets, the initial deal from a seed, the single play phase, legal-action enumeration, the transition
// function `apply`, terminal detection + outcome, view redaction, and the undo policy. No EngineCore or
// TableKit edits are needed (R-ENG-5.6; design.md §11).
//
// SCOPE — HAND vs MATCH. A `CrazyEights` value models a single hand: deal → play until someone goes out
// (or, with `stockOut == .endHand`, until no one can play). Its `outcome` reports the per-hand points the
// player who went out earned from the cards left in opponents' hands (R-CE-3.1). Accumulating those
// points across hands toward the configurable match target (R-CE-3.2) is the EngineCore Match /
// EndCondition machinery (Match.swift), which already exists and sums per-hand `HandOutcome`s — so this
// file deliberately does NOT re-implement match orchestration. The target lives in the options
// (`CrazyEightsOptions.matchTarget`) as the value the host feeds that machinery.
//
// Design notes worth stating up front:
//
//   • The named suit after an 8 is tracked as `activeSuit` on the state, separate from the top discard's
//     own suit, because a wild 8 can rename the suit to something the 8 itself is not (R-CE-2.2). Play
//     matches `activeSuit`, not the 8's printed suit.
//   • `direction` and `pendingDraw` on the state carry the action-card effects (Ace reverse, stacked 2s)
//     so the transition stays a pure function of the state (R-CE-4.1). With action cards off they never
//     change: direction stays clockwise and `pendingDraw` stays 0.
//   • Redaction reuses EngineCore's `Redaction.zoneViews` over the state's zones (hands ownerOnly, stock
//     hidden, discard top public), so no hidden identity leaks (R-ENG-8.3). The public named suit rides
//     in the view's `phase` (see `phase(of:)`), which is public information after an 8.

import EngineCore
import Foundation

/// Crazy Eights as a `GameDefinition` for one hand (R-ENG-5; R-CE-1…R-CE-4).
public struct CrazyEights: GameDefinition {
    public typealias State = CrazyEightsState
    public typealias Action = CrazyEightsAction
    public typealias Options = CrazyEightsOptions

    public init() {}

    // MARK: - Metadata (R-ENG-5.1)

    public static let metadata = GameMetadata(
        id: "crazy-eights",
        name: "Crazy Eights",
        family: .shedding,
        seatRange: 2...5,
        typicalDuration: DurationRange(minMinutes: 5, maxMinutes: 20),
        complexity: .light
    )

    // MARK: - Options schema + presets (R-ENG-5.2)

    /// Defaults (2 players, draw-until, reshuffle, target 100, no action cards) plus the named presets
    /// documented in `Docs/Rules/crazy-eights.md`. Presets are what the setup sheet lists first
    /// (R-APP-2.1).
    public static let optionsSchema = OptionsSchema<CrazyEightsOptions>(
        defaults: CrazyEightsOptions(),
        presets: [
            OptionsPreset(
                name: "Classic",
                options: CrazyEightsOptions(
                    playerCount: 2, drawMode: .drawUntilCanPlay, stockOut: .reshuffleDiscards,
                    matchTarget: 100, actionCards: false)
            ),
            OptionsPreset(
                name: "Action Cards",
                options: CrazyEightsOptions(
                    playerCount: 4, drawMode: .drawUntilCanPlay, stockOut: .reshuffleDiscards,
                    matchTarget: 100, actionCards: true)
            ),
            OptionsPreset(
                name: "Quick",
                options: CrazyEightsOptions(
                    playerCount: 2, drawMode: .drawOneThenPass, stockOut: .reshuffleDiscards,
                    matchTarget: 50, actionCards: false)
            ),
        ]
    )

    // MARK: - Phases (R-ENG-5.3)

    /// The single play phase, carrying the public active suit in its raw value (e.g. `"play:hearts"`) so
    /// the redacted view surfaces the named suit after an 8 without leaking any hidden identity — the
    /// active suit is public information (R-CE-2.2). `phase(of:)` builds it from the state.
    public func phase(of state: CrazyEightsState) -> Phase {
        Phase(rawValue: "play:\(state.activeSuit.rawValue)")
    }

    public var undoPolicy: UndoPolicy { .none }  // multi-seat default (R-ENG-7.3)

    // MARK: - Initial deal (R-CE-1, R-ENG-5.3, R-ENG-4)

    /// Deal a fresh Crazy Eights hand from `options` and a recorded `seed` (R-CE-1).
    ///
    /// The standard-52 pack is materialized, shuffled with the seeded Fisher–Yates (R-ENG-4.1), then
    /// dealt: each seat gets `handSize` cards (7 for 2 players, 5 for 3–5, R-CE-1.2). A starter is turned
    /// up onto the discard; if it is an 8 it is buried back into the stock and another is turned, until a
    /// non-8 starter shows (R-CE-1.3). The remaining cards form the stock. The active suit starts as the
    /// starter's suit; the first turn is seat 0 (the local human); direction starts clockwise and no draw
    /// is pending.
    public func initialState(options: CrazyEightsOptions, seed: UInt64) -> CrazyEightsState {
        var cards = DeckDefinition.standard52.makeCards()
        var rng = SeededRNG(seed: seed)
        Shuffle.fisherYates(&cards, using: &rng)

        var faces: [PieceID: CardFace] = [:]
        faces.reserveCapacity(cards.count)
        for card in cards { faces[card.id] = card.face }

        // Deal `handSize` to each seat, one whole hand at a time from the top of the shuffled pack.
        var index = 0
        let handSize = options.handSize
        var hands: [Zone] = []
        hands.reserveCapacity(options.playerCount)
        for seatIdx in 0..<options.playerCount {
            let slice = cards[index..<(index + handSize)]
            index += handSize
            hands.append(
                Zone(
                    id: CrazyEightsZone.hand(seatIdx),
                    visibility: .ownerOnly,
                    contents: slice.map(\.id)
                )
            )
        }

        // Turn up a starter; bury any 8 back into the stock and turn another (R-CE-1.3). We take the
        // starter from the top of the remaining pack; a buried 8 goes to the BOTTOM of the stock (front
        // of the remaining slice) so it is not immediately re-drawn.
        var remaining = Array(cards[index...])
        var buried: [PieceID] = []
        var starter = remaining.removeFirst()
        while CrazyEightsCard.isEight(starter.face) {
            buried.append(starter.id)
            starter = remaining.removeFirst()
        }
        // The stock is the untouched remaining pack with any buried 8s tucked at the bottom (front).
        let stockIDs = buried + remaining.map(\.id)
        let stock = Zone(id: CrazyEightsZone.stockID, visibility: .hidden, contents: stockIDs)

        let discard = Zone(
            id: CrazyEightsZone.discardID, visibility: .topCardOnly, contents: [starter.id],
            faceUp: [starter.id])

        // The starter is never an 8 here, so its suit is a real suit.
        let activeSuit = CrazyEightsCard.suit(starter.face) ?? .clubs

        return CrazyEightsState(
            hands: hands,
            stock: stock,
            discard: discard,
            faces: faces,
            activeSuit: activeSuit,
            turn: CrazyEightsState.seat(0),
            direction: .clockwise,
            pendingDraw: 0,
            options: options
        )
    }

    // MARK: - Terminal + outcome (R-ENG-5.5)

    /// A hand ends when a player empties their hand (goes out), OR — under `stockOut == .endHand` — when
    /// the stock is empty and no seat can play (R-CE-2.4). Under `reshuffleDiscards` a stuck position is
    /// not terminal because the discards recycle into a fresh stock (R-CE-2.4).
    public func isTerminal(_ state: CrazyEightsState) -> Bool {
        if state.hands.contains(where: { $0.contents.isEmpty }) { return true }
        if state.options.stockOut == .endHand, Self.handIsStuck(state) { return true }
        return false
    }

    /// The per-hand outcome (R-ENG-5.5, R-CE-3.1). The player who went out (an empty hand) wins and
    /// scores the sum of the cards left in every other seat's hand by the R-CE-3.1 values (8 = 50,
    /// K/Q/J = 10, A = 1, else pip). When a hand ends stuck (`endHand`) with no one out, the seat with
    /// the fewest points still in hand is the winner and scores the others' remaining cards.
    public func outcome(_ state: CrazyEightsState) -> HandOutcome {
        // Points still held in each seat's hand.
        var held: [SeatID: Int] = [:]
        for hand in state.hands {
            guard let seat = hand.owner else { continue }
            held[seat] = hand.contents.reduce(0) { sum, piece in
                sum + (state.face(of: piece).map(CrazyEightsCard.points) ?? 0)
            }
        }

        // The winner: a seat that went out, else the seat holding the fewest points (a stuck endHand).
        let winner: SeatID?
        if let out = state.hands.first(where: { $0.contents.isEmpty })?.owner {
            winner = out
        } else {
            winner = held.min { $0.value < $1.value }?.key
        }
        guard let winner else { return .draw }

        // The winner scores every OTHER seat's remaining points (R-CE-3.1).
        let earned = held.reduce(0) { sum, entry in
            entry.key == winner ? sum : sum + entry.value
        }
        return HandOutcome(winners: [winner], scores: [winner: earned])
    }

    // MARK: - Redaction (R-ENG-5.5, R-ENG-8)

    /// The redacted view for `viewer`, built from the shared `Redaction` machinery over the state's
    /// zones (R-ENG-8.2/8.3). Each hand is `ownerOnly` (a seat sees only its own), the stock is hidden,
    /// and the discard exposes only its top card; a hidden card appears only as an opaque token. The
    /// public active/named suit rides in `phase` (R-CE-2.2). The salt is derived from the state so the
    /// tokenization is stable within a view yet uncorrelated across views (R-QA-3.1).
    public func redactedView(of state: CrazyEightsState, for viewer: Viewer) -> PlayerView {
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
        if case .seat(let seat) = viewer, seat == state.turn {
            legal = legalActions(for: seat, in: state).compactMap { try? AnyGameAction($0) }
        } else {
            legal = []
        }
        // Scores are per-hand outcome deltas, reported at the hand's end; during play no running score
        // is shown (the match model accumulates across hands, R-ENG-6.2). Show 0 for each seat.
        var scores: [SeatID: Int] = [:]
        for hand in state.hands { if let seat = hand.owner { scores[seat] = 0 } }
        return PlayerView(
            viewer: viewer,
            zones: zones,
            scores: scores,
            phase: phase(of: state),
            legalActions: legal
        )
    }

    /// A per-state salt for view tokenization — the hidden stock size mixed with the discard size. Any
    /// stable-per-state value works; this avoids a fixed salt without needing external entropy.
    private static func viewSalt(for state: CrazyEightsState) -> UInt64 {
        var salt: UInt64 = 0x0CE8_0CE8_1234_ABCD
        salt = salt &+ UInt64(state.stock.contents.count) &* 0x1000_0001
        salt = salt &+ UInt64(state.discard.contents.count) &* 0x100_0007
        for hand in state.hands {
            salt = salt &+ UInt64(hand.contents.count) &* 0x10_0021
        }
        return salt
    }
}
