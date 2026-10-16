// TableRenderModel — the event-stream-driven, reducible render state (R-TABLE-1.1, R-TABLE-1.2).
//
// This is the "(b) event stream" half of the generic renderer (R-TABLE-1.1) and the reason a new game
// needs NO custom animation code (R-TABLE-1.2). It models the table as a plain value: for each piece, its
// current zone / index / face-up state, keyed by the piece's stable `RenderKey`. A `GameEvent` is applied
// by `apply(_:)` to produce the next model — deal places pieces, move retargets a piece's zone/index,
// flip toggles face-up, and `pieceRevealed` REBINDS a hidden token's node to the revealed identity so a
// flip stays visually continuous (design.md §2.8/§6; R-ENG-8.4).
//
// Because the model is a pure value reduced by events, the animation itself is trivial and generic: the
// SwiftUI view (`TableView`) resolves this model through `LayoutResolver` into frames and wraps state
// changes in `withAnimation`, letting matched geometry interpolate a piece from its old frame to its new
// one. No game writes any of this. The full animation QUEUE (speed setting, fast-forward, reduce-motion)
// lives in `AnimationQueue.swift` / `AnimationDriver.swift` (task 5.5); the render model stays a pure
// reducer and knows nothing about timing.

import EngineCore
import Foundation

// MARK: - Piece node

/// The render model's record for one piece: where it is and how it is shown, keyed by `RenderKey`.
///
/// `identity` is the real `PieceID` once known (for a `.known` piece from the start, or after a
/// `pieceRevealed` rebinds a formerly-hidden token). It stays `nil` while a piece is only known by its
/// hidden token, which is all a viewer is allowed to know until the reveal (R-ENG-8.3/8.4).
public struct PieceNode: Sendable, Hashable {
    /// Stable render key (known id or hidden token) — the matched-geometry identity.
    public var key: RenderKey
    /// The zone the piece currently occupies.
    public var zone: ZoneID
    /// The piece's index within its zone.
    public var index: Int
    /// Whether the piece is face-up.
    public var faceUp: Bool
    /// The revealed identity, once known (see type doc).
    public var identity: PieceID?

    public init(key: RenderKey, zone: ZoneID, index: Int, faceUp: Bool, identity: PieceID?) {
        self.key = key
        self.zone = zone
        self.index = index
        self.faceUp = faceUp
        self.identity = identity
    }
}

// MARK: - Render model

/// The reducible render state of the table: a set of piece nodes keyed by their stable `RenderKey`
/// (R-TABLE-1.1).
///
/// Built initially from a `PlayerView` (the redacted zones) and then advanced by applying `GameEvent`s.
/// Kept a pure value type so it can be tested exhaustively without SwiftUI: assert that deal/move/flip/
/// reveal update nodes as expected. The SwiftUI layer holds one of these and re-resolves frames after
/// each `apply`.
public struct TableRenderModel: Sendable, Hashable {
    /// The live piece nodes, keyed by their stable render identity.
    public private(set) var nodes: [RenderKey: PieceNode]

    public init(nodes: [RenderKey: PieceNode] = [:]) {
        self.nodes = nodes
    }

    /// Build an initial model from a redacted `PlayerView`: every piece in every zone becomes a node,
    /// keyed by its id (known) or token (hidden). This is the starting snapshot the event stream advances.
    public init(playerView: PlayerView) {
        var nodes: [RenderKey: PieceNode] = [:]
        for zone in playerView.zones {
            for (index, piece) in zone.pieces.enumerated() {
                switch piece {
                case .known(let known):
                    let key = RenderKey.known(known.id)
                    nodes[key] = PieceNode(
                        key: key, zone: zone.id, index: index, faceUp: true, identity: known.id)
                case .hidden(let token):
                    let key = RenderKey.hidden(token)
                    nodes[key] = PieceNode(
                        key: key, zone: zone.id, index: index, faceUp: false, identity: nil)
                }
            }
        }
        self.nodes = nodes
    }

    // MARK: Reduction

    /// Apply one `GameEvent`, returning the next model (R-TABLE-1.2). Pure: does not mutate `self`.
    ///
    /// Only the events that change piece geometry/appearance affect the model; purely informational events
    /// (turn/score/trick/caption/suit/handEnded) leave the piece nodes untouched — those drive HUD/caption
    /// (task 5.6), not motion, and are handled by other consumers of the same stream.
    public func applying(_ event: GameEvent) -> TableRenderModel {
        var copy = self
        copy.apply(event)
        return copy
    }

    /// In-place form of `applying(_:)`.
    public mutating func apply(_ event: GameEvent) {
        switch event {
        case .dealt(let descriptors):
            for descriptor in descriptors { place(descriptor) }
        case .pieceMoved(let descriptor):
            place(descriptor)
        case .pieceFlipped(let id, let faceUp):
            let key = RenderKey.known(id)
            if var node = nodes[key] {
                node.faceUp = faceUp
                nodes[key] = node
            }
        case .pieceRevealed(let token, let identity):
            rebind(token: token, to: identity)
        case .turnChanged, .trickWon, .scoreChanged, .handEnded, .suitNamed, .captioned:
            // Non-geometry events: no change to the piece layout. Handled by HUD/caption consumers.
            break
        }
    }

    // MARK: Reconciliation to a fresh view (single source of truth)

    /// Rebuild the node set so it is EXACTLY what `playerView` describes, preserving each surviving node's
    /// `RenderKey` so matched geometry animates the difference (slides for moved pieces, a crossfade for a
    /// hidden→known reveal). This is the "single source of truth" primitive (design.md §2.8/§6): after the
    /// host accepts an action, the client reconciles its render model to the host's fresh redacted view
    /// instead of trying to re-derive the board from the raw omniscient event stream.
    ///
    /// Why reconcile rather than replace: a plain `TableRenderModel(playerView:)` would be a brand-new value
    /// with no identity continuity, so SwiftUI could not animate a card from its old frame to its new one.
    /// By computing the target nodes from the view and assigning them to a model that already keys pieces by
    /// the SAME stable `RenderKey`s, every piece that survived keeps its matched-geometry id and animates;
    /// pieces that left the viewer's sight are dropped and new ones appear. Hidden pieces keep their node iff
    /// their `ViewToken` is stable across views (it is, once the game uses a stable tokenizer salt), so an
    /// untouched face-down pile does not flicker.
    ///
    /// Pure: computes the next node map and swaps it in. No event replay, no ghost nodes, no stale
    /// face-down cards — the model after this call projects back to exactly `playerView`'s zones.
    public mutating func reconcile(to playerView: PlayerView) {
        self.nodes = TableRenderModel(playerView: playerView).nodes
    }

    /// Non-mutating form of `reconcile(to:)`.
    public func reconciling(to playerView: PlayerView) -> TableRenderModel {
        var copy = self
        copy.reconcile(to: playerView)
        return copy
    }

    // MARK: Projection to zones

    /// Project the live nodes back into ordered `ZoneView`s so `LayoutResolver` (which consumes zones)
    /// can place them. Pieces within a zone are ordered by their `index`. The projected `ViewPiece`
    /// carries only what the resolver needs — `.known(id)` vs `.hidden(token)`; the drawn FACE is looked
    /// up separately by the view via `faceContent`, so a placeholder face is used here. Pure and testable.
    public func zoneViews() -> [ZoneView] {
        var byZone: [ZoneID: [(Int, ViewPiece)]] = [:]
        for node in nodes.values {
            let piece: ViewPiece
            switch node.key {
            case .known(let id):
                piece = .known(.card(Card(id: id, face: .joker(index: 0))))
            case .hidden(let token):
                piece = .hidden(token)
            }
            byZone[node.zone, default: []].append((node.index, piece))
        }
        return byZone.map { (zoneID, entries) in
            let ordered = entries.sorted { $0.0 < $1.0 }.map { $0.1 }
            return ZoneView(id: zoneID, visibility: .publicAll, pieces: ordered)
        }
    }

    // MARK: Helpers

    /// Place (deal or move) a piece per a descriptor. The descriptor carries the real `PieceID`, so a
    /// piece the viewer already tracks by identity is updated in place; a piece the viewer only knew by a
    /// hidden token is matched by its recorded identity if the token was already revealed.
    private mutating func place(_ descriptor: PieceMoveDescriptor) {
        let knownKey = RenderKey.known(descriptor.piece)
        if var node = nodes[knownKey] {
            node.zone = descriptor.to
            node.index = descriptor.toIndex
            node.faceUp = descriptor.faceUp
            node.identity = descriptor.piece
            nodes[knownKey] = node
            return
        }
        // No node under the known key yet: this piece is entering the viewer's tracked set as a known
        // identity (e.g. dealt face-up into a public zone). Create it.
        nodes[knownKey] = PieceNode(
            key: knownKey,
            zone: descriptor.to,
            index: descriptor.toIndex,
            faceUp: descriptor.faceUp,
            identity: descriptor.piece
        )
    }

    /// Rebind a hidden token's node to its revealed identity, preserving the node's position/index so the
    /// flip animates continuously (design.md §2.8/§6; R-ENG-8.4). The node is re-keyed from the token to
    /// the real id; its zone/index carry over. If a known node for that identity already exists, the
    /// hidden token node is simply removed (the identity node wins).
    private mutating func rebind(token: ViewToken, to identity: PieceID) {
        let hiddenKey = RenderKey.hidden(token)
        guard let hidden = nodes[hiddenKey] else { return }
        nodes.removeValue(forKey: hiddenKey)
        let knownKey = RenderKey.known(identity)
        if var existing = nodes[knownKey] {
            // An identity node already tracked this piece; keep it, adopt the revealed face-up state.
            existing.faceUp = true
            existing.identity = identity
            nodes[knownKey] = existing
        } else {
            nodes[knownKey] = PieceNode(
                key: knownKey,
                zone: hidden.zone,
                index: hidden.index,
                faceUp: true,
                identity: identity
            )
        }
    }
}

// The animation-settings seam that used to be a placeholder here is now the real animation queue: see
// `AnimationSettings`, `AnimationQueue`, and the SwiftUI `AnimationDriver` in `AnimationQueue.swift` /
// `AnimationDriver.swift` (task 5.5; R-TABLE-5).
