// Crazy Eights state and actions — the board, and the moves a player can make (R-CE-1…R-CE-4; R-ENG-5).
//
// The board is modeled with EngineCore `Zone`s so redaction (R-ENG-8) and layout come for free from the
// shared machinery — Crazy Eights never hand-rolls visibility (R-ENG-3.3). For an N-seat game the zones
// are:
//
//   • one hand per seat ("hand" owned by seat i), `ownerOnly`: each player sees only their own hand
//     (R-CE-1.2);
//   • the stock ("stock"), `hidden`: the face-down draw pile (R-CE-1.3, R-CE-2.3); and
//   • the discard ("discard"), `topCardOnly`: only the top card is public — that is the card players
//     match against (R-CE-2.1).
//
// Alongside the zones the state carries the bits the zones don't:
//
//   • a `faces` map from every `PieceID` to its real `CardFace` (so redaction and rule checks can read a
//     card's rank/suit);
//   • the current `activeSuit` — the suit that must be matched right now. Normally this equals the top
//     discard's suit, but when an 8 is played it is set to the suit the player NAMED (R-CE-2.2), which
//     can differ from the 8's own suit; tracking it separately is the only way to model a wild 8's
//     lingering effect (the top card is an 8 of one suit, but play must follow the named suit);
//   • whose `turn` it is (a `SeatID`);
//   • the `direction` of play — clockwise or counter-clockwise — which the Ace reverses under the
//     action-card option (R-CE-4.1);
//   • `pendingDraw` — the number of cards the next player must draw before playing, accumulated by
//     stacked 2s under the action-card option (R-CE-4.1); and
//   • the immutable `options`.
//
// `Zone` is `Codable & Sendable` (Zones.swift) so the whole state is `GameState` (R-ENG-8.5) — savable,
// hashable for the determinism contract (R-ENG-4.4), and safe across the host actor boundary.

import EngineCore
import Foundation

// MARK: - Zone naming

/// Stable zone names for a Crazy Eights table. Centralized so state, layout, and tests agree.
///
/// These are the stable public contract of the board: the same zone ids appear in the redacted
/// `PlayerView`, so the UI layer references them to lay out and target the board. Public so a TableKit
/// adapter and layout can build the same ids without hard-coding the strings.
public enum CrazyEightsZone {
    public static let hand = "hand"
    public static let stock = "stock"
    public static let discard = "discard"

    /// The hand zone owned by seat `index` (R-CE-1.2), `ownerOnly`.
    public static func hand(_ index: Int) -> ZoneID {
        ZoneID(name: hand, owner: CrazyEightsState.seat(index))
    }
    /// The shared, face-down stock (R-CE-1.3).
    public static let stockID = ZoneID(name: stock)
    /// The shared discard pile; only the top card is public (R-CE-2.1).
    public static let discardID = ZoneID(name: discard)
}

// MARK: - Direction

/// The direction turns rotate around the table. Reversed by an Ace under the action-card option
/// (R-CE-4.1).
public enum CrazyEightsDirection: String, Codable, Sendable {
    /// Ascending seat order: seat 0 → 1 → 2 → … → 0.
    case clockwise
    /// Descending seat order: seat 0 → N−1 → … → 0.
    case counterClockwise

    /// The direction reversed (R-CE-4.1).
    public var reversed: CrazyEightsDirection {
        self == .clockwise ? .counterClockwise : .clockwise
    }
}

// MARK: - State

/// The authoritative state of a single Crazy Eights hand (R-CE-1…R-CE-4). Conforms to `GameState`, so it
/// is `Codable & Sendable`, hashable for the determinism contract, and savable (R-ENG-8.5, R-ENG-4.4).
public struct CrazyEightsState: GameState {
    /// One hand per seat, in seat order, `ownerOnly` (R-CE-1.2).
    public var hands: [Zone]
    /// The face-down stock, `hidden` (R-CE-1.3, R-CE-2.3).
    public var stock: Zone
    /// The discard pile, `topCardOnly`; players match its top (R-CE-2.1).
    public var discard: Zone

    /// Every piece's real face, keyed by identity — the game's source of truth for what a card *is*
    /// (identity is separate from face, R-ENG-1.2). Used by rule checks and by redaction's face
    /// resolver.
    public var faces: [PieceID: CardFace]

    /// The suit that must be matched right now (R-CE-2.1). Equals the top discard's suit normally, but is
    /// set to the NAMED suit after an 8 is played (R-CE-2.2) — which can differ from the 8's own suit.
    public var activeSuit: Suit

    /// The seat whose turn it is (R-CE-2.1).
    public var turn: SeatID

    /// The direction turns rotate; reversed by an Ace under the action-card option (R-CE-4.1).
    public var direction: CrazyEightsDirection

    /// Cards the current player must draw before they may play, accumulated by stacked 2s under the
    /// action-card option (R-CE-4.1). Zero when no draw-two is pending.
    public var pendingDraw: Int

    /// The immutable options this hand was dealt under (R-CE-1…R-CE-4). Carried in state so `apply`,
    /// `legalActions`, and scoring can read them without a side channel.
    public var options: CrazyEightsOptions

    public init(
        hands: [Zone],
        stock: Zone,
        discard: Zone,
        faces: [PieceID: CardFace],
        activeSuit: Suit,
        turn: SeatID,
        direction: CrazyEightsDirection = .clockwise,
        pendingDraw: Int = 0,
        options: CrazyEightsOptions
    ) {
        self.hands = hands
        self.stock = stock
        self.discard = discard
        self.faces = faces
        self.activeSuit = activeSuit
        self.turn = turn
        self.direction = direction
        self.pendingDraw = pendingDraw
        self.options = options
    }

    /// The seat at position `index` (R-ENG-3.1 naming). Static so `CrazyEightsZone` can build hand ids.
    public static func seat(_ index: Int) -> SeatID { SeatID.index(index) }

    /// The number of seats at the table.
    public var seatCount: Int { hands.count }

    /// The seat index for a `SeatID`, or `nil` if it is not at this table.
    public func seatIndex(of seat: SeatID) -> Int? {
        hands.firstIndex { $0.owner == seat }
    }

    /// The hand zone for `seat`, or `nil` if the seat is not at this table.
    public func hand(of seat: SeatID) -> Zone? {
        hands.first { $0.owner == seat }
    }

    /// All zones in a stable order (hands in seat order, then stock, then discard) for redaction and
    /// layout.
    public var allZones: [Zone] {
        hands + [stock, discard]
    }

    /// The face of a piece, or `nil` if unknown (should never happen for a well-formed state).
    public func face(of piece: PieceID) -> CardFace? { faces[piece] }

    /// The top discard's real face, or `nil` if the discard is empty.
    public var topDiscardFace: CardFace? {
        guard let top = discard.contents.last else { return nil }
        return faces[top]
    }

    /// The seat that follows `seat` in the current `direction`, `steps` seats away (default 1). Wraps
    /// around the table. Used to advance the turn and to skip a seat (R-CE-4.1).
    public func seat(after seat: SeatID, steps: Int = 1) -> SeatID {
        let count = seatCount
        guard count > 0, let idx = seatIndex(of: seat) else { return seat }
        let delta = direction == .clockwise ? steps : -steps
        let next = ((idx + delta) % count + count) % count
        return Self.seat(next)
    }
}

// MARK: - Deterministic Codable state encoding

/// A sorted face entry keeps state hashes stable across dictionary iteration order.
private struct CrazyEightsFaceEntry: Codable {
    let id: PieceID
    let face: CardFace
}

extension CrazyEightsState {
    private enum CodingKeys: String, CodingKey {
        case hands, stock, discard, faces, activeSuit, turn, direction, pendingDraw, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hands = try container.decode([Zone].self, forKey: .hands)
        stock = try container.decode(Zone.self, forKey: .stock)
        discard = try container.decode(Zone.self, forKey: .discard)
        let entries = try container.decode([CrazyEightsFaceEntry].self, forKey: .faces)
        var decodedFaces: [PieceID: CardFace] = [:]
        decodedFaces.reserveCapacity(entries.count)
        for entry in entries { decodedFaces[entry.id] = entry.face }
        faces = decodedFaces
        activeSuit = try container.decode(Suit.self, forKey: .activeSuit)
        turn = try container.decode(SeatID.self, forKey: .turn)
        direction = try container.decode(CrazyEightsDirection.self, forKey: .direction)
        pendingDraw = try container.decode(Int.self, forKey: .pendingDraw)
        options = try container.decode(CrazyEightsOptions.self, forKey: .options)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hands, forKey: .hands)
        try container.encode(stock, forKey: .stock)
        try container.encode(discard, forKey: .discard)
        let entries = faces.map { CrazyEightsFaceEntry(id: $0.key, face: $0.value) }
            .sorted { $0.id.raw < $1.id.raw }
        try container.encode(entries, forKey: .faces)
        try container.encode(activeSuit, forKey: .activeSuit)
        try container.encode(turn, forKey: .turn)
        try container.encode(direction, forKey: .direction)
        try container.encode(pendingDraw, forKey: .pendingDraw)
        try container.encode(options, forKey: .options)
    }
}

// MARK: - Action

/// A single move a player can make in Crazy Eights (R-ENG-5.4). Conforms to `GameAction` so it is
/// `Codable & Sendable`, loggable, and type-erasable for views (R-ENG-8.5).
///
/// Every case names concrete pieces (and the named suit for an 8) so the action is fully determined and
/// replayable. `legalActions` enumerates the currently-valid values; `apply` validates and performs
/// them.
public enum CrazyEightsAction: GameAction, Hashable {
    /// Play a non-8 card from hand that matches the active suit or the top discard's rank (R-CE-2.1). For
    /// an 8, use `playEight` instead — an 8 is wild and must name a suit (R-CE-2.2).
    case play(card: PieceID)
    /// Play an 8 (wild) from hand and name the suit that must be matched next (R-CE-2.2).
    case playEight(card: PieceID, namedSuit: Suit)
    /// Draw from the stock. Under `drawUntilCanPlay` this draws until a playable card appears (or the
    /// stock is exhausted per the stock-out option); under `drawOneThenPass` it draws exactly one and
    /// passes (R-CE-2.3). It also serves paying a pending draw-two under the action-card option
    /// (R-CE-4.1).
    case draw
    /// Pass the turn without playing — legal only when the player genuinely cannot play and the rules do
    /// not force a draw (e.g. the stock is empty and reshuffle is off) (R-CE-2.4). See Q-3.
    case pass
}
