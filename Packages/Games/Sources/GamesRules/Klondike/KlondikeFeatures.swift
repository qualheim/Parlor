// Klondike features — the pure, testable game-logic behind task 3.5's player conveniences
// (R-KLON-3.1, R-KLON-3.2, R-KLON-3.3, R-KLON-3.5, R-KLON-3.6, R-KLON-3.7).
//
// These are helpers *around* the rules, not new rules: every action they choose is one the existing
// `legalActions`/`apply` already validate, so a feature can never make an illegal move. Each function is
// a pure function of `KlondikeState` (plus, where relevant, a `RenderKey`/`PieceID`) so it can be unit-
// tested exhaustively without any UI. The TableKit/SwiftUI wiring that *uses* these lives in GamesUI (a
// UI-layer module that may import TableKit); GamesRules stays pure (stdlib + Foundation + EngineCore).
//
// What lives here:
//
//   • auto-move-to-foundation policy (R-KLON-3.2): `autoMoves(in:)` returns the ordered foundation moves
//     to perform under the state's `autoMove` policy, using the standard safe-autoplay heuristic;
//   • smart move (R-KLON-3.3): `smartDestination(for:in:)` — the double-click preferred destination for a
//     piece by `PieceID` (foundation if legal, else a legal tableau build); the GamesUI adapter maps
//     TableKit's `RenderKey` → `PieceID` → `ZoneID`;
//   • auto-complete (R-KLON-3.3): `canAutoComplete(_:)` + `autoCompleteSequence(from:)` — detect a
//     solved-but-not-terminal board and produce the ordered foundation moves that finish it;
//   • no-moves detection (R-KLON-3.6): `hasNoMoves(_:)` — no legal action remains (including stock
//     cycling), so the host shows the inline banner (state modeled in `KlondikeSession`);
//   • heuristic hints (R-KLON-3.5): `hint(_:)` — a reasonable next move chosen by heuristic priority;
//   • numbered deals (R-KLON-3.7): `seed(forDealNumber:)` — a deterministic deal-number → seed mapping so
//     "deal #N" always deals the same game.

import EngineCore
import Foundation

extension Klondike {

    // MARK: - Auto-move to foundations (R-KLON-3.2)

    /// The ordered list of foundation auto-moves to perform in `state` under its `autoMove` policy
    /// (R-KLON-3.2).
    ///
    /// The policy comes from `state.options.autoMove`:
    ///   • `.off` — returns `[]`; nothing is auto-played.
    ///   • `.always` — every card (waste top or tableau top) that legally can go to a foundation.
    ///   • `.safeOnly` — only cards that are *safe* per the standard safe-autoplay heuristic (see
    ///     `isSafeToAutoPlay(rank:color:in:)`): Aces and twos are always safe; a rank-N card (N ≥ 3) is
    ///     safe iff both opposite-color foundations are already at rank ≥ N − 1, so it can never be
    ///     needed on the tableau to receive an opposite-color card.
    ///
    /// The result is a single pass over the current tops. The host applies them one at a time (re-reading
    /// state and calling this again if it wants to cascade), so the returned list is deliberately the set
    /// of moves legal *right now*, in a stable order (waste first, then tableau piles left-to-right). Each
    /// entry is a real `KlondikeAction` that `apply` accepts.
    public func autoMoves(in state: KlondikeState) -> [KlondikeAction] {
        guard state.options.autoMove != .off, !isTerminal(state) else { return [] }
        var moves: [KlondikeAction] = []

        // Waste top → foundation.
        if let wasteTop = state.waste.contents.last, let face = state.face(of: wasteTop),
            let fi = Self.foundationIndex(accepting: face, in: state),
            Self.passesAutoPolicy(face, state: state)
        {
            moves.append(.wasteToFoundation(toFoundation: fi))
        }

        // Each tableau top → foundation.
        for (ti, pile) in state.tableau.enumerated() {
            guard let top = pile.contents.last, pile.isFaceUp(top), let face = state.face(of: top),
                let fi = Self.foundationIndex(accepting: face, in: state),
                Self.passesAutoPolicy(face, state: state)
            else { continue }
            moves.append(.tableauToFoundation(fromPile: ti, toFoundation: fi))
        }

        return moves
    }

    /// Whether `face` clears the state's auto-move policy gate (`.always` = always, `.safeOnly` = the
    /// safe heuristic; `.off` never reaches here).
    private static func passesAutoPolicy(_ face: CardFace, state: KlondikeState) -> Bool {
        switch state.options.autoMove {
        case .off: return false
        case .always: return true
        case .safeOnly:
            guard let rank = KlondikeCard.rankValue(face), let color = KlondikeCard.color(face)
            else { return false }
            return isSafeToAutoPlay(rank: rank, color: color, in: state)
        }
    }

    /// The index of a foundation that would legally accept `face`, or `nil` if none (R-KLON-1.2).
    static func foundationIndex(accepting face: CardFace, in state: KlondikeState) -> Int? {
        for (fi, foundation) in state.foundations.enumerated()
        where KlondikeCard.foundationFollows(face, onto: topFace(of: foundation, in: state)) {
            return fi
        }
        return nil
    }

    /// The standard "safe autoplay" test for a card of `rank` and `color` (R-KLON-3.2).
    ///
    /// A card is safe to send home when it can never be needed on the tableau to receive an opposite-
    /// color card of rank N − 1:
    ///   • Aces (rank 1) and twos (rank 2) are always safe — nothing lower needs them.
    ///   • A rank-N card (N ≥ 3) is safe iff BOTH foundations of the *opposite* color have already
    ///     reached at least rank N − 1. If both opposite-color foundations are at ≥ N − 1, then any
    ///     opposite-color card that could have landed on this card is already home (or can go home), so
    ///     parking this card on the tableau serves no purpose.
    ///
    /// "Opposite color" foundations: for a black card, the red foundations (hearts, diamonds); for a red
    /// card, the black foundations (clubs, spades). We read the current top rank of each foundation by the
    /// suit's color.
    static func isSafeToAutoPlay(rank: Int, color: KlondikeColor, in state: KlondikeState) -> Bool {
        if rank <= 2 { return true }
        let oppositeColor: KlondikeColor = color == .black ? .red : .black
        let ranks = foundationTopRanks(ofColor: oppositeColor, in: state)
        // Need both opposite-color suits present as foundations and each at ≥ rank − 1.
        guard ranks.count == 2 else { return false }
        return ranks.allSatisfy { $0 >= rank - 1 }
    }

    /// The current top ranks (0 when empty) of the two foundations whose suit has `color` (R-KLON-3.2).
    ///
    /// Foundations are not suit-fixed by index, so we scan every foundation and bucket by the color of
    /// its top card (an empty foundation contributes rank 0 to *both* colors, since it could still take
    /// either color's Ace). We return the two lowest per-color tops that matter: for the safe test we want
    /// the two opposite-color suits, so we compute, for each of the two suits of `color`, the top rank of
    /// the foundation currently holding that suit (or 0 if that suit has no foundation yet).
    static func foundationTopRanks(ofColor color: KlondikeColor, in state: KlondikeState) -> [Int] {
        let suits: [Suit] = color == .black ? [.clubs, .spades] : [.hearts, .diamonds]
        return suits.map { suit in
            for foundation in state.foundations {
                guard let top = foundation.contents.last, let face = state.face(of: top),
                    KlondikeCard.suit(face) == suit
                else { continue }
                return KlondikeCard.rankValue(face) ?? 0
            }
            return 0  // no foundation holds this suit yet
        }
    }

    // MARK: - Smart move / double-click (R-KLON-3.3)

    /// The preferred smart destination zone for the piece with identity `id` in `state`, or `nil` if the
    /// piece cannot move (R-KLON-3.3). This is the double-click / click-smart-move target the GamesUI
    /// adapter maps into TableKit's `smartTarget` seam (TableKit's `RenderKey` is a UI concern and lives
    /// in that layer; GamesRules stays pure and works on `PieceID`).
    ///
    /// Preference order (standard Klondike double-click behavior):
    ///   1. a foundation the piece may legally enter (send it home);
    ///   2. otherwise a legal tableau build — preferring a non-empty pile over an empty one so a
    ///      double-click does not gratuitously move a King into an empty column;
    ///   3. otherwise `nil`.
    ///
    /// Only the *lead* of a movable face-up run is a smart-move candidate for a tableau→tableau build; a
    /// single top card (waste top, tableau top, foundation top) is handled the same way. A piece that is
    /// not a legal move source (buried, face-down) returns `nil`.
    public func smartDestination(for id: PieceID, in state: KlondikeState) -> ZoneID? {
        guard !isTerminal(state), let face = state.face(of: id) else { return nil }
        let source = Self.sourceZone(of: id, in: state)
        guard let source else { return nil }

        // Only movable pieces: the waste top, a face-up tableau card that leads a valid run, or a
        // foundation top. Anything buried/face-down is not a smart-move source.
        guard Self.isSmartSource(id, in: state, source: source) else { return nil }

        // 1. Foundation, if a legal single-card send exists (only for a single top card, not a multi-run
        //    lead — a run cannot go to a foundation). A tableau lead that also happens to be the pile top
        //    is a single card and may go home.
        if Self.isSingleTop(id, in: state, source: source),
            let fi = Self.foundationIndex(accepting: face, in: state)
        {
            return KlondikeZone.foundation(fi)
        }

        // 2. A legal tableau build: prefer a non-empty destination, then an empty one.
        var emptyDestination: ZoneID?
        for ti in state.tableau.indices {
            guard KlondikeZone.tableau(ti) != source else { continue }
            guard Self.canPlaceOnTableau(face, pileIndex: ti, in: state) else { continue }
            if state.tableau[ti].contents.isEmpty {
                if emptyDestination == nil { emptyDestination = KlondikeZone.tableau(ti) }
            } else {
                return KlondikeZone.tableau(ti)
            }
        }
        return emptyDestination
    }

    /// The zone that currently contains `id` (waste, a tableau pile, or a foundation), or `nil`.
    static func sourceZone(of id: PieceID, in state: KlondikeState) -> ZoneID? {
        if state.waste.contents.contains(id) { return KlondikeZone.wasteID }
        for (ti, pile) in state.tableau.enumerated() where pile.contents.contains(id) {
            return KlondikeZone.tableau(ti)
        }
        for (fi, f) in state.foundations.enumerated() where f.contents.contains(id) {
            return KlondikeZone.foundation(fi)
        }
        return nil
    }

    /// Whether `id` is a legal smart-move *source* from `source`: the waste top; a face-up tableau card
    /// that leads a valid run; or a foundation top.
    static func isSmartSource(_ id: PieceID, in state: KlondikeState, source: ZoneID) -> Bool {
        if source == KlondikeZone.wasteID { return state.waste.contents.last == id }
        if source.name.hasPrefix(KlondikeZone.foundationPrefix) {
            return state.foundations.contains { $0.contents.last == id }
        }
        // Tableau: must be face-up and the lead of a valid run.
        for pile in state.tableau where pile.contents.contains(id) {
            guard pile.isFaceUp(id) else { return false }
            return faceUpRunLeads(of: pile, in: state).contains(id)
        }
        return false
    }

    /// Whether `id` is a single movable top card (waste top, tableau *pile* top, or foundation top) — as
    /// opposed to the lead of a multi-card run. Only single tops may go to a foundation.
    static func isSingleTop(_ id: PieceID, in state: KlondikeState, source: ZoneID) -> Bool {
        if source == KlondikeZone.wasteID { return state.waste.contents.last == id }
        if source.name.hasPrefix(KlondikeZone.foundationPrefix) {
            return state.foundations.contains { $0.contents.last == id }
        }
        for pile in state.tableau where pile.contents.contains(id) {
            return pile.contents.last == id
        }
        return false
    }

    // MARK: - Auto-complete (R-KLON-3.3)

    /// Whether the board can be finished with no further decisions (R-KLON-3.3).
    ///
    /// True when every remaining card can be sent home mechanically. The condition is the standard
    /// "all cards face up and the stock is trivially drainable" state:
    ///   • every tableau card is face up (no face-down cards remain), and
    ///   • the stock and waste are empty, OR every stock/waste card is face-up-known and can be turned to
    ///     the waste and played (we take the conservative, always-safe condition: stock+waste empty).
    ///
    /// We use the conservative-but-standard rule: **all tableau cards are face up AND the stock and waste
    /// are both empty.** In that state the tableau is a set of ordered descending runs whose cards can be
    /// greedily lifted to the foundations in rank order, always with a legal move available, until the
    /// game is won (proven by `autoCompleteSequence(from:)` returning a full 52-card finish). Returns
    /// `false` on a terminal (already-won) board — there is nothing to auto-complete.
    public func canAutoComplete(_ state: KlondikeState) -> Bool {
        guard !isTerminal(state) else { return false }
        guard state.stock.contents.isEmpty, state.waste.contents.isEmpty else { return false }
        let allFaceUp = state.tableau.allSatisfy { pile in
            pile.contents.allSatisfy { pile.isFaceUp($0) }
        }
        guard allFaceUp else { return false }
        // Sanity: a full finishing sequence must exist. (It always does when the above holds, but this
        // ties the predicate to the constructive check so they can never disagree.)
        return autoCompleteSequence(from: state)?.isEmpty == false
    }

    /// The ordered sequence of foundation moves that finishes the game from `state`, or `nil` if the board
    /// cannot be finished this way (R-KLON-3.3).
    ///
    /// Greedy: repeatedly find any tableau/waste top that legally goes to a foundation, record and apply
    /// that move, and continue until the game is won or no move is available. Because auto-complete is
    /// offered only when `canAutoComplete` holds (all face up, stock/waste empty), the greedy loop always
    /// reaches a win; if it stalls before winning, we return `nil` (the board was not actually finishable
    /// mechanically). Pure: applies moves to local copies via `apply`.
    public func autoCompleteSequence(from state: KlondikeState) -> [KlondikeAction]? {
        var current = state
        var moves: [KlondikeAction] = []
        // Upper bound on iterations: at most 52 cards go home.
        for _ in 0..<52 {
            if isTerminal(current) { return moves }
            guard let move = firstFoundationMove(in: current) else { return nil }
            guard case .success(let (next, _)) = apply(move, by: klondikeSeat, to: current) else {
                return nil
            }
            moves.append(move)
            current = next
        }
        return isTerminal(current) ? moves : nil
    }

    /// The first available tableau/waste → foundation move in `state` (waste first, then piles), or
    /// `nil`. Used by the auto-complete greedy loop.
    private func firstFoundationMove(in state: KlondikeState) -> KlondikeAction? {
        if let wasteTop = state.waste.contents.last, let face = state.face(of: wasteTop),
            let fi = Self.foundationIndex(accepting: face, in: state)
        {
            return .wasteToFoundation(toFoundation: fi)
        }
        for (ti, pile) in state.tableau.enumerated() {
            guard let top = pile.contents.last, pile.isFaceUp(top), let face = state.face(of: top),
                let fi = Self.foundationIndex(accepting: face, in: state)
            else { continue }
            return .tableauToFoundation(fromPile: ti, toFoundation: fi)
        }
        return nil
    }

    // MARK: - No-moves detection (R-KLON-3.6)

    /// Whether no legal move remains — the dead-board condition (R-KLON-3.6).
    ///
    /// True when the seat has no legal actions at all. `legalActions` already accounts for stock cycling:
    /// it offers `.drawFromStock` while the stock has cards and `.recycleWaste` while the waste is
    /// non-empty and a pass remains, so "no legal actions" genuinely means no productive stock cycling is
    /// left either. A terminal (won) board is not "no moves" — the game is over successfully — so this
    /// returns `false` there.
    public func hasNoMoves(_ state: KlondikeState) -> Bool {
        guard !isTerminal(state) else { return false }
        return legalActions(for: klondikeSeat, in: state).isEmpty
    }

    // MARK: - Heuristic hints (R-KLON-3.5)

    /// A reasonable next move chosen by heuristic priority, or `nil` if none exists (R-KLON-3.5).
    ///
    /// Solver-backed hints are Spec 2 (out of scope). This is a cheap, one-ply heuristic that prefers
    /// moves that tend to make progress, in this order:
    ///   1. **Expose a face-down card** — a tableau→tableau or tableau→foundation move that uncovers a
    ///      face-down card beneath (turns a hidden card up next turn).
    ///   2. **Empty a column** — a tableau→tableau move that clears a pile whose only cards are the moved
    ///      run (opening a slot for a King).
    ///   3. **Advance a foundation safely** — a safe auto-move to a foundation (per the safe heuristic).
    ///   4. **Any legal foundation move** — send a card home even if not "safe".
    ///   5. **Any other legal move** — fall back to the first legal action (a tableau build, a stock
    ///      draw, etc.).
    ///
    /// Returns `nil` only when there are no legal actions (the caller then shows "no moves").
    public func hint(_ state: KlondikeState) -> KlondikeAction? {
        let actions = legalActions(for: klondikeSeat, in: state)
        guard !actions.isEmpty else { return nil }

        // 1. Prefer a move that exposes a face-down card.
        if let exposing = actions.first(where: { Self.exposesFaceDownCard($0, in: state) }) {
            return exposing
        }
        // 2. Prefer a move that empties a column (a King can then fill it).
        if let emptying = actions.first(where: { Self.emptiesAColumn($0, in: state) }) {
            return emptying
        }
        // 3. A safe foundation advance.
        let safe = autoMovesForHint(in: state)
        if let safeMove = safe.first { return safeMove }
        // 4. Any legal foundation move.
        if let anyFoundation = actions.first(where: { Self.isFoundationMove($0) }) {
            return anyFoundation
        }
        // 5. Any legal move.
        return actions.first
    }

    /// Safe foundation moves regardless of the state's configured `autoMove` policy — used by the hint so
    /// a hint is offered even when auto-move is `.off`.
    private func autoMovesForHint(in state: KlondikeState) -> [KlondikeAction] {
        var moves: [KlondikeAction] = []
        if let wasteTop = state.waste.contents.last, let face = state.face(of: wasteTop),
            let fi = Self.foundationIndex(accepting: face, in: state),
            let rank = KlondikeCard.rankValue(face), let color = KlondikeCard.color(face),
            Self.isSafeToAutoPlay(rank: rank, color: color, in: state)
        {
            moves.append(.wasteToFoundation(toFoundation: fi))
        }
        for (ti, pile) in state.tableau.enumerated() {
            guard let top = pile.contents.last, pile.isFaceUp(top), let face = state.face(of: top),
                let fi = Self.foundationIndex(accepting: face, in: state),
                let rank = KlondikeCard.rankValue(face), let color = KlondikeCard.color(face),
                Self.isSafeToAutoPlay(rank: rank, color: color, in: state)
            else { continue }
            moves.append(.tableauToFoundation(fromPile: ti, toFoundation: fi))
        }
        return moves
    }

    /// Whether `action` is a move to a foundation.
    static func isFoundationMove(_ action: KlondikeAction) -> Bool {
        switch action {
        case .wasteToFoundation, .tableauToFoundation: return true
        default: return false
        }
    }

    /// Whether `action` would uncover a face-down card by lifting the face-up cards above it off a
    /// tableau pile (R-KLON-3.5 heuristic 1).
    static func exposesFaceDownCard(_ action: KlondikeAction, in state: KlondikeState) -> Bool {
        switch action {
        case .tableauToTableau(let fromPile, let card, _):
            return liftingExposesFaceDown(fromPile: fromPile, lead: card, in: state)
        case .tableauToFoundation(let fromPile, _):
            // The top card leaves; if the card beneath it is face-down, it gets exposed.
            let pile = state.tableau[fromPile]
            guard pile.contents.count >= 2 else { return false }
            let beneath = pile.contents[pile.contents.count - 2]
            return !pile.isFaceUp(beneath)
        default:
            return false
        }
    }

    /// Whether moving the run led by `lead` off `fromPile` would expose a face-down card beneath it.
    private static func liftingExposesFaceDown(
        fromPile: Int, lead: PieceID, in state: KlondikeState
    )
        -> Bool
    {
        let pile = state.tableau[fromPile]
        guard let start = pile.contents.firstIndex(of: lead), start > 0 else { return false }
        let beneath = pile.contents[start - 1]
        return !pile.isFaceUp(beneath)
    }

    /// Whether `action` would empty a tableau column (the moved run is the whole pile) (R-KLON-3.5
    /// heuristic 2). Only meaningful for tableau→tableau moves that are not into an empty pile.
    static func emptiesAColumn(_ action: KlondikeAction, in state: KlondikeState) -> Bool {
        guard case .tableauToTableau(let fromPile, let card, let toPile) = action else {
            return false
        }
        // Moving into an empty pile just relocates the run; it does not net-empty a column.
        guard !state.tableau[toPile].contents.isEmpty else { return false }
        return state.tableau[fromPile].contents.first == card
    }

    // MARK: - Numbered deals (R-KLON-3.7)

    /// The deterministic seed for numbered deal `n` (R-KLON-3.7).
    ///
    /// "Play deal #N" must always deal the same game, so the mapping from a human deal number to the
    /// engine seed must be stable across builds and platforms — it cannot depend on `Hasher` (which is
    /// randomized per process). We use a fixed SplitMix64-style finalizer over the deal number: a pure
    /// integer mix with well-known constants, deterministic everywhere. Distinct deal numbers almost
    /// always produce distinct seeds (the mix is a bijection on `UInt64`), so different N deal different
    /// games. `SeededRNG` then expands this seed for the shuffle (ADR 0002).
    public static func seed(forDealNumber n: Int) -> UInt64 {
        var z = UInt64(bitPattern: Int64(n)) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return z
    }

    /// Deal numbered game `n` under `options` — a convenience over `initialState` using the numbered-deal
    /// seed (R-KLON-3.7). "Restart the same deal" replays this with the same `n` + `options`.
    public func initialState(options: KlondikeOptions, dealNumber n: Int) -> KlondikeState {
        initialState(options: options, seed: Self.seed(forDealNumber: n))
    }
}
