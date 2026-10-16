// Crazy Eights determinizer — build a plausible full hand from the redacted view (R-AI-2.2, R-CE-5.3).
//
// The Hard tier reasons with Monte Carlo, which needs a CONCRETE full state to play out — but a strategy
// only sees its own redacted `PlayerView` (the barrier, R-AI-1.1). So it must invent a plausible full
// state consistent with everything it legitimately knows: its own hand, the public top discard, the
// active/named suit, the public counts of every hidden pile, and the public options (player count, draw
// mode, stock-out, action cards) that were chosen at setup. It fills the unseen slots (opponents' hands,
// the stock, and the buried/under-top discard cards) with the cards it cannot see, honoring counts and
// inferred opponent voids via AIKit's `DeterminizationSampler` (R-AI-2.2). All randomness flows through
// the injected `SeededRNG`, so a determinization is reproducible for a given seed (R-AI-3.2).
//
// The unseen pool is the standard-52 pack minus the cards the view reveals (own hand + the known top
// discard). Those unseen cards must be distributed across three kinds of hidden group:
//   • each OPPONENT hand — count read from that hand zone's token count in the view;
//   • the STOCK — count read from the stock zone's token count; and
//   • the DISCARD's non-top cards — count read from the discard zone (everything below the visible top).
// Only opponent hands carry inferred voids (a seat that drew is void in the then-active suit); the stock
// and buried discard accept any suit.

import AIKit
import EngineCore
import Foundation

/// Builds a full, plausible `CrazyEightsState` from a seat's redacted view — the root state the Hard
/// tier's Monte Carlo plays out (R-AI-2.2, R-CE-5.3).
struct CrazyEightsDeterminizer {
    /// The public options the hand was dealt under (player count, draw mode, stock-out, action cards) —
    /// chosen at setup and therefore public, not hidden state (R-AI-1.1).
    let options: CrazyEightsOptions

    /// A slot key for the determinization sampler: an opponent hand, the stock, or the buried discard.
    private enum Slot: Hashable {
        case hand(SeatID)
        case stock
        case buriedDiscard
    }

    /// Build a full state from `view` for the deciding `seat`, using `log` for inferred voids and `rng`
    /// for the sample (R-AI-2.2). Returns `nil` if the view is malformed or the instance is infeasible.
    func makeState(
        view: PlayerView, seat: SeatID, log: PublicLog, rng: inout SeededRNG
    ) -> CrazyEightsState? {
        // Zones from the view, by name.
        let handZones = view.zones.filter { $0.id.name == CrazyEightsZone.hand }
        guard let discardZone = view.zones.first(where: { $0.id.name == CrazyEightsZone.discard }),
            let stockZone = view.zones.first(where: { $0.id.name == CrazyEightsZone.stock }),
            case .known(.card(let topCard))? = discardZone.pieces.last
        else { return nil }

        // Known cards: the seat's own hand + the public top discard.
        let ownHand = CrazyEightsAI.handCards(in: view, seat: seat)
        var known: Set<PieceID> = [topCard.id]
        for card in ownHand { known.insert(card.id) }

        // The unseen pool: standard-52 minus the known cards.
        let full = DeckDefinition.standard52.makeCards()
        let unseen = full.filter { !known.contains($0.id) }

        // Hidden groups and their counts (read from the view's token counts).
        var groups: [HiddenGroup<Slot>] = []
        var handSeats: [SeatID] = []
        for zone in handZones {
            guard let owner = zone.id.owner else { continue }
            handSeats.append(owner)
            if owner == seat { continue }  // own hand is known, not sampled
            groups.append(HiddenGroup(key: .hand(owner), count: zone.pieces.count))
        }
        groups.append(HiddenGroup(key: .stock, count: stockZone.pieces.count))
        let buriedCount = max(0, discardZone.pieces.count - 1)
        groups.append(HiddenGroup(key: .buriedDiscard, count: buriedCount))

        // Inferred voids → constraints (opponent hands only) (R-AI-2.2).
        let activeSuit = CrazyEightsAI.activeSuit(in: view)
        let voids = CrazyEightsAI.inferredVoids(from: log, startingSuit: activeSuit)
        var constraints = DeterminizationConstraints<Slot, Suit>()
        for (voidSeat, suits) in voids where voidSeat != seat {
            for suit in suits { constraints.addVoid(slot: .hand(voidSeat), category: suit) }
        }

        // Sample an assignment of the unseen cards to the hidden groups (R-AI-2.2, R-AI-3.2).
        guard
            let sample = DeterminizationSampler.sample(
                unseen: unseen,
                groups: groups,
                constraints: constraints,
                category: { CrazyEightsCard.suit($0.face) ?? .clubs },
                using: &rng)
        else { return nil }

        // Assemble the full state.
        var faces: [PieceID: CardFace] = [:]
        for card in full { faces[card.id] = card.face }

        // Hands in seat order.
        let orderedSeats = handSeats.sorted { seatIndex($0) < seatIndex($1) }
        var hands: [Zone] = []
        for owner in orderedSeats {
            let contents: [PieceID]
            if owner == seat {
                contents = ownHand.map(\.id)
            } else {
                contents = (sample.assignment[.hand(owner)] ?? []).map(\.id)
            }
            hands.append(
                Zone(
                    id: CrazyEightsZone.hand(seatIndex(owner)), visibility: .ownerOnly,
                    contents: contents))
        }

        let stockIDs = (sample.assignment[.stock] ?? []).map(\.id)
        let stock = Zone(id: CrazyEightsZone.stockID, visibility: .hidden, contents: stockIDs)

        // Discard: buried cards below the public top.
        let buriedIDs = (sample.assignment[.buriedDiscard] ?? []).map(\.id)
        let discardContents = buriedIDs + [topCard.id]
        let discard = Zone(
            id: CrazyEightsZone.discardID, visibility: .topCardOnly, contents: discardContents,
            faceUp: [topCard.id])

        return CrazyEightsState(
            hands: hands,
            stock: stock,
            discard: discard,
            faces: faces,
            activeSuit: activeSuit,
            turn: seat,
            direction: .clockwise,
            pendingDraw: 0,
            options: options)
    }

    /// The seat index parsed from a `SeatID.raw` of the form `"seat-<n>"`, else a large sentinel so
    /// unknown seats sort last (they should not occur).
    private func seatIndex(_ seat: SeatID) -> Int {
        guard let dash = seat.raw.lastIndex(of: "-"),
            let n = Int(seat.raw[seat.raw.index(after: dash)...])
        else { return Int.max }
        return n
    }
}
