// Klondike state and actions — the board, and the moves a player can make (R-KLON-1, R-ENG-5.3/5.4).
//
// The board is modeled with EngineCore `Zone`s so redaction (R-ENG-8) and layout (task 3.3) come for
// free from the shared machinery — Klondike never hand-rolls visibility (R-ENG-3.3). There are
// thirteen zones:
//
//   • 7 tableau piles ("tableau-0"…"tableau-6"), `perPieceFaceState`: some cards face-down, the rest
//     the face-up run (R-KLON-1.1);
//   • the stock ("stock"), `hidden`: face-down draw pile (R-KLON-1.1);
//   • the waste ("waste"), `publicAll`: turned cards, played from the top (R-KLON-1.1); and
//   • 4 foundations ("foundation-0"…"foundation-3"), `publicAll`: built up by suit A→K (R-KLON-1.1).
//
// Alongside the zones the state carries the bits the zones don't: a `faces` map from every `PieceID` to
// its real `CardFace` (so redaction and rule checks can read a card's rank/suit), the running `score`,
// the number of stock `passes` used so far (R-KLON-2.3), and the immutable `options`. `Zone` is
// `Codable & Sendable` (Zones.swift) so the whole state is `GameState` (R-ENG-8.5) — savable, hashable
// for the determinism contract (R-ENG-4.4), and safe across the host actor boundary.

import EngineCore
import Foundation

// MARK: - Zone naming

/// Stable zone names for the single Klondike seat. Centralized so state, layout, and tests agree.
///
/// These are the stable public contract of the Klondike board: the same zone ids appear in the redacted
/// `PlayerView`, so the UI layer (GamesUI) references them to lay out and target the board. Public so the
/// TableKit adapter and layout can build the same ids without hard-coding the strings.
public enum KlondikeZone {
    public static let stock = "stock"
    public static let waste = "waste"
    public static let tableauPrefix = "tableau-"
    public static let foundationPrefix = "foundation-"

    /// The number of tableau piles (R-KLON-1.1).
    public static let tableauCount = 7
    /// The number of foundations (R-KLON-1.1).
    public static let foundationCount = 4

    public static func tableau(_ index: Int) -> ZoneID { ZoneID(name: "\(tableauPrefix)\(index)") }
    public static func foundation(_ index: Int) -> ZoneID {
        ZoneID(name: "\(foundationPrefix)\(index)")
    }
    public static let stockID = ZoneID(name: stock)
    public static let wasteID = ZoneID(name: waste)
}

/// The single seat at a Klondike table (R-ENG-5.1: `seatRange == 1...1`).
public let klondikeSeat = SeatID.index(0)

// MARK: - State

/// The authoritative state of a Klondike game (R-KLON-1). Conforms to `GameState`, so it is
/// `Codable & Sendable`, hashable for the determinism contract, and savable (R-ENG-8.5, R-ENG-4.4).
public struct KlondikeState: GameState {
    /// The stock (face-down draw pile), `hidden` (R-KLON-1.1).
    public var stock: Zone
    /// The waste (turned cards), `publicAll`; play from the top (R-KLON-1.1).
    public var waste: Zone
    /// The 7 tableau piles, `perPieceFaceState` (R-KLON-1.1).
    public var tableau: [Zone]
    /// The 4 foundations, `publicAll`, built up by suit (R-KLON-1.1).
    public var foundations: [Zone]

    /// Every piece's real face, keyed by identity — the game's source of truth for what a card *is*
    /// (identity is separate from face, R-ENG-1.2). Used by rule checks and by redaction's face
    /// resolver.
    public var faces: [PieceID: CardFace]

    /// The running score under the chosen scheme (0 when scoring is `none`) (R-KLON-2.2).
    public var score: Int

    /// How many passes through the stock have been consumed so far (R-KLON-2.3). The initial deal-down
    /// counts as pass 1; each recycle of the waste increments it.
    public var passes: Int

    /// The immutable options this game was dealt under (R-KLON-2). Carried in state so `apply`,
    /// `legalActions`, and scoring can read them without a side channel.
    public var options: KlondikeOptions

    public init(
        stock: Zone,
        waste: Zone,
        tableau: [Zone],
        foundations: [Zone],
        faces: [PieceID: CardFace],
        score: Int,
        passes: Int,
        options: KlondikeOptions
    ) {
        self.stock = stock
        self.waste = waste
        self.tableau = tableau
        self.foundations = foundations
        self.faces = faces
        self.score = score
        self.passes = passes
        self.options = options
    }

    /// All thirteen zones in a stable order (stock, waste, tableau 0–6, foundations 0–3) for redaction
    /// and layout.
    public var allZones: [Zone] {
        [stock, waste] + tableau + foundations
    }

    /// The face of a piece, or `nil` if unknown (should never happen for a well-formed state).
    public func face(of piece: PieceID) -> CardFace? { faces[piece] }
}

// MARK: - Action

/// A single move a player can make in Klondike (R-ENG-5.4). Conforms to `GameAction` so it is
/// `Codable & Sendable`, loggable, and type-erasable for views (R-ENG-8.5).
///
/// Every case names concrete zones/pieces so the action is fully determined and replayable. `legalActions`
/// enumerates the currently-valid values; `apply` validates and performs them.
public enum KlondikeAction: GameAction, Hashable {
    /// Turn the draw-count cards from the stock onto the waste (R-KLON-2.1).
    case drawFromStock
    /// Recycle the waste back into the stock when the stock is empty, consuming a pass (R-KLON-2.3).
    case recycleWaste
    /// Move the top waste card onto tableau pile `toPile`.
    case wasteToTableau(toPile: Int)
    /// Move the top waste card onto foundation `toFoundation`.
    case wasteToFoundation(toFoundation: Int)
    /// Move a face-up run starting at `card` from tableau pile `fromPile` onto tableau pile `toPile`
    /// (a movable sequence, R-KLON-1.3; King-led into an empty pile, R-KLON-1.4).
    case tableauToTableau(fromPile: Int, card: PieceID, toPile: Int)
    /// Move the top card of tableau pile `fromPile` onto foundation `toFoundation`.
    case tableauToFoundation(fromPile: Int, toFoundation: Int)
    /// Move the top card of foundation `fromFoundation` back onto tableau pile `toPile` (R-KLON-1.5).
    case foundationToTableau(fromFoundation: Int, toPile: Int)
}
