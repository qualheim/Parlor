// Viewers, events, per-hand outcome, and undo policy — the boundary types `GameDefinition` returns.
//
// Everything that crosses the host boundary (config, actions, views, events, outcomes) is `Codable`,
// `Sendable`, and schema-versioned (R-ENG-8.5, tech.md rule 4). This file introduces the small set of
// boundary types the `GameDefinition` protocol (task 2.5, R-ENG-5) refers to in its signature:
//
//   • `Viewer` — who is looking (a seat, a spectator, or a debug-only omniscient viewer, R-ENG-8.2);
//   • `GameEvent` — the semantic event stream one game transition emits (R-ENG-8.1);
//   • `PlayerView` — a per-viewer redacted snapshot (R-ENG-8.2, R-ENG-8.3);
//   • `HandOutcome` — the scoring/outcome of a finished hand (R-ENG-5.5, R-ENG-6.3); and
//   • `UndoPolicy` — how far a game permits undo (R-ENG-7.3, R-ENG-7.4).
//
// NOTE — SCOPE. `Viewer`, `HandOutcome`, and `UndoPolicy` are built here in full because task 2.5 needs
// them to close the protocol. `GameEvent` and `PlayerView` began as MINIMAL PLACEHOLDERS for task 2.5;
// task 2.6 (R-ENG-8) has now grown them into the full design: the complete semantic event set, the
// `ViewToken`/`ViewPiece`/`ZoneView` redaction types, and the extended `PlayerView`. The per-view token
// permutation and the redaction helper that interprets each zone's `Visibility` live in `Redaction.swift`.

import Foundation

// MARK: - Viewer (R-ENG-8.2)

/// Who is observing the game — the perspective a `PlayerView` is redacted for (R-ENG-8.2).
///
/// `redactedView(of:for:)` (R-ENG-5.5) takes one of these and returns only what that observer may see.
/// A `spectator` sees the public game with every hidden zone concealed; `debugOmniscient` sees
/// everything and is for debugging/inspection only — it MUST NOT be used in shipping redaction paths
/// (design.md §2.8).
public enum Viewer: Codable, Sendable, Hashable {
    /// A specific seat at the table; sees its own private zones plus everything public.
    case seat(SeatID)

    /// A non-seated observer; sees only what every seat can see (public zones), no private hands.
    case spectator

    /// Debug-only omniscient viewer that sees all identities. Never used in shipping redaction
    /// (design.md §2.8); present so tools and tests can inspect full state.
    case debugOmniscient
}

// MARK: - Piece move descriptor (R-ENG-8.1)

/// The animation-relevant description of a single piece moving between zones — enough for the client to
/// play the move without consulting authoritative state (R-ENG-8.1).
///
/// It names the piece, where it came from and went to (by `ZoneID`), the destination index within the
/// target zone's ordered `contents`, and whether it lands face-up. The client reads this straight off the
/// event stream to slide/flip the on-screen node; it never needs the game's `State`. Carried by both
/// `dealt(pieces:)` and `pieceMoved` so a deal and a single move share one shape.
///
/// `piece` is the *real* `PieceID`. When a move concerns a piece that a particular viewer cannot see, the
/// redaction layer is responsible for not surfacing that identity to that viewer; the descriptor itself is
/// the authoritative, omniscient record the host holds and only shares with clients that may see it. (A
/// hidden piece is revealed to a viewer via `pieceRevealed`, R-ENG-8.4, not by leaking this descriptor.)
public struct PieceMoveDescriptor: Codable, Sendable, Hashable {
    /// The physical piece that moved (R-ENG-1.2).
    public let piece: PieceID
    /// The zone the piece left, or `nil` if it entered play (e.g. dealt from outside any tracked zone).
    public let from: ZoneID?
    /// The zone the piece entered.
    public let to: ZoneID
    /// The piece's index within the destination zone's ordered `contents` after the move.
    public let toIndex: Int
    /// Whether the piece is face-up at its destination (drives the flip in the move animation).
    public let faceUp: Bool

    public init(piece: PieceID, from: ZoneID?, to: ZoneID, toIndex: Int, faceUp: Bool) {
        self.piece = piece
        self.from = from
        self.to = to
        self.toIndex = toIndex
        self.faceUp = faceUp
    }
}

// MARK: - Localized caption key (R-ENG-8.1)

/// A stable, localizable key for a narration string shown in the caption bar (R-ENG-8.1).
///
/// EngineCore is the pure layer (stdlib + Foundation only, `tech.md` rule 1), so it must NOT pull in
/// SwiftUI's `LocalizedStringKey` or any UI framework. This is a thin `Codable`/`Sendable` wrapper over a
/// stable string key plus optional string arguments; the UI layer resolves it against a string catalog at
/// render time. Keeping the key (not the resolved sentence) in the event stream is what lets captions,
/// VoiceOver, and the log localize independently from one event (R-ENG-8.1, design.md §9).
public struct LocalizedKey: Codable, Sendable, Hashable {
    /// Stable lookup key into the string catalog, e.g. `"caption.trickWon"`.
    public let key: String
    /// Ordered substitution arguments for the localized format string (e.g. a seat name), if any.
    public let arguments: [String]

    public init(_ key: String, arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
    }
}

// MARK: - Game events (R-ENG-8.1)

/// A semantic event emitted by a game transition; one stream feeds animation, captions, VoiceOver,
/// sound, and the log (R-ENG-8.1).
///
/// Events are *semantic* — they say what happened in the game's own terms ("a trick was won", "a piece
/// was revealed"), not how to draw it — so every consumer derives its behavior from the same source and
/// they can never drift (design.md §9). All associated values are `Codable & Sendable & Hashable`, so the
/// whole enum is; it crosses the host boundary in a `ResultEnvelope` and is replayed from the log
/// (R-ENG-8.5). This is the full set design.md §2.6 specifies; games emit the subset they need.
public enum GameEvent: Codable, Sendable, Hashable {
    /// A batch of pieces were dealt/placed, each described for animation (R-ENG-8.1). Replaces the coarse
    /// `dealt(count:)` placeholder with per-piece descriptors so the deal can be animated piece by piece.
    case dealt(pieces: [PieceMoveDescriptor])

    /// A single piece moved between zones (R-ENG-8.1), described for animation.
    case pieceMoved(PieceMoveDescriptor)

    /// A previously hidden piece became visible: this binds the opaque `token` that viewer's view had
    /// assigned to the piece's real `identity`, so the client rebinds the on-screen node and keeps the
    /// flip animation continuous without having leaked the identity beforehand (R-ENG-8.4).
    case pieceRevealed(token: ViewToken, identity: PieceID)

    /// A piece was turned face-up or face-down in place (R-ENG-8.1) — e.g. flipping a Klondike tableau
    /// card. The `PieceID` is public here because a flip is, by definition, a visible act on a piece the
    /// viewer can already locate; games do not emit this for pieces still hidden from a viewer.
    case pieceFlipped(PieceID, faceUp: Bool)

    /// The active turn passed to a seat (R-ENG-8.1).
    case turnChanged(to: SeatID)

    /// A trick was won by a seat (R-ENG-8.1) — trick-taking games.
    case trickWon(by: SeatID)

    /// A seat's score changed by `delta` to a running `total` (R-ENG-8.1).
    case scoreChanged(seat: SeatID, delta: Int, total: Int)

    /// The hand ended with the given outcome (R-ENG-8.1).
    case handEnded(HandOutcome)

    /// A suit was named by a seat (R-ENG-8.1) — e.g. the effect of playing an 8 in Crazy Eights
    /// (R-CE-2.2).
    case suitNamed(Suit, by: SeatID)

    /// A narration line for the caption bar, as a localizable key resolved by the UI (R-ENG-8.1).
    case captioned(LocalizedKey)
}

// MARK: - View token (R-ENG-8.3)

/// An opaque stand-in for a piece hidden from a viewer (R-ENG-8.3).
///
/// A hidden piece appears in a `PlayerView` as a `ViewToken`, never as its real `PieceID` or face. The
/// token is drawn from a per-view keyed permutation (see `Redaction.swift`): within a single view the
/// mapping from hidden `PieceID` → `ViewToken` is a consistent bijection, but the same `PieceID` gets a
/// *different* token in a different view (different viewer or salt), so tokens cannot be joined across two
/// views to deanonymize a piece (R-ENG-8.3, R-QA-3.1). The `opaque` value is a handle only; nothing about
/// the real identity may be recovered from it.
public struct ViewToken: Codable, Sendable, Hashable {
    /// Opaque per-view handle. Treat as a token; it carries no recoverable link to the real `PieceID`.
    public let opaque: UInt64

    public init(opaque: UInt64) {
        self.opaque = opaque
    }
}

// MARK: - Known piece (R-ENG-8.3)

/// The revealed face of a piece a viewer *may* see — a card or a tile (R-ENG-8.3).
///
/// `ViewPiece.known` needs to carry a concrete face, and the platform hosts both card games and rummy
/// tile games (Components.swift). Rather than making the whole view stack generic over a piece type — which
/// would infect `PlayerView`, `ZoneView`, and the protocol — a hidden piece is represented by this small
/// closed enum. It keeps the redacted view a single concrete `Codable` type usable by every family, while
/// still exposing the real `Card`/`Tile` (identity + face) to viewers allowed to see it.
public enum KnownPiece: Codable, Sendable, Hashable {
    /// A visible playing card, with its real identity and face.
    case card(Card)
    /// A visible rummy tile, with its real identity and face.
    case tile(Tile)

    /// The revealed piece's real identity, whichever kind it is.
    public var id: PieceID {
        switch self {
        case .card(let c): return c.id
        case .tile(let t): return t.id
        }
    }
}

// MARK: - View piece (R-ENG-8.3)

/// One entry in a redacted zone: either a piece the viewer may see (`known`) or an opaque `token`
/// standing in for one they may not (R-ENG-8.3).
///
/// This is the single place a hidden identity is replaced by a token, so the invariant "a view contains no
/// hidden identity" (R-QA-3.1) is expressible and testable on one type.
public enum ViewPiece: Codable, Sendable, Hashable {
    /// A piece the viewer may see, carrying its real identity and face.
    case known(KnownPiece)
    /// A piece hidden from the viewer, shown as an opaque per-view token (R-ENG-8.3).
    case hidden(ViewToken)
}

// MARK: - Zone view (R-ENG-8.2, R-ENG-8.3)

/// The redacted view of a single `Zone`: its identity and visibility policy plus its ordered pieces, each
/// either `known` or replaced by a per-view `hidden` token (R-ENG-8.2, R-ENG-8.3).
///
/// Order is preserved from the underlying `Zone.contents` so positional concepts (top of a pile) survive
/// redaction. Which entries are `known` vs `hidden` is decided by the zone's `Visibility` policy plus its
/// per-piece face state, interpreted once in `Redaction.swift` (R-ENG-3.3).
public struct ZoneView: Codable, Sendable, Hashable {
    /// The zone this is a redacted view of.
    public let id: ZoneID
    /// The zone's visibility policy (carried so the client can present piles appropriately).
    public let visibility: Visibility
    /// The zone's pieces in order, each revealed (`known`) or tokenized (`hidden`) per redaction.
    public let pieces: [ViewPiece]

    public init(id: ZoneID, visibility: Visibility, pieces: [ViewPiece]) {
        self.id = id
        self.visibility = visibility
        self.pieces = pieces
    }
}

// MARK: - Player view (R-ENG-8.2, R-ENG-8.3, R-ENG-8.5)

/// A per-viewer redacted snapshot of the game (R-ENG-8.2). Pieces hidden from the viewer appear only as
/// opaque tokens, never as their real identities (R-ENG-8.3).
///
/// This is what a client (UI, AI, log) consumes; there is no path from it to authoritative `State`
/// (design.md §5, the AI information barrier). It carries the redacted `zones`, the visible `scores`, the
/// current `phase`, and the viewer's *own* `legalActions` (type-erased) — a seat sees only the moves it
/// may make (R-ENG-8.2). `schemaVersion` versions this boundary document so the format can evolve with
/// tested migrations, matching the save schema's convention (design.md §4; R-ENG-8.5).
public struct PlayerView: Codable, Sendable, Hashable {
    /// The current schema version of this boundary type; bumped on any format change (R-ENG-8.5).
    public static let currentSchemaVersion = 1

    /// The schema version this value was produced with (R-ENG-8.5). Defaults to `currentSchemaVersion`.
    public let schemaVersion: Int

    /// Who this view was redacted for.
    public let viewer: Viewer

    /// The redacted zones: each piece is `.known` (visible to this viewer) or `.hidden(ViewToken)`
    /// (R-ENG-8.2, R-ENG-8.3).
    public let zones: [ZoneView]

    /// Scores visible to this viewer, keyed by seat.
    public let scores: [SeatID: Int]

    /// The current phase, as reported by `GameDefinition.phase(of:)`.
    public let phase: Phase

    /// The viewer's own legal actions, type-erased — empty for a spectator or when it is not their turn
    /// (R-ENG-8.2).
    public let legalActions: [AnyGameAction]

    public init(
        viewer: Viewer,
        zones: [ZoneView] = [],
        scores: [SeatID: Int],
        phase: Phase,
        legalActions: [AnyGameAction] = [],
        schemaVersion: Int = PlayerView.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.viewer = viewer
        self.zones = zones
        self.scores = scores
        self.phase = phase
        self.legalActions = legalActions
    }

    // Decoding tolerates an absent `schemaVersion` (treated as version 1) so older encodings and callers
    // that construct views inline stay decodable (R-ENG-8.5).
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, viewer, zones, scores, phase, legalActions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.viewer = try c.decode(Viewer.self, forKey: .viewer)
        self.zones = try c.decodeIfPresent([ZoneView].self, forKey: .zones) ?? []
        self.scores = try c.decode([SeatID: Int].self, forKey: .scores)
        self.phase = try c.decode(Phase.self, forKey: .phase)
        self.legalActions =
            try c.decodeIfPresent([AnyGameAction].self, forKey: .legalActions) ?? []
    }
}

// MARK: - Hand outcome (R-ENG-5.5, R-ENG-6.3)

/// The scoring/outcome of a finished hand: who won and each seat's per-hand score (R-ENG-5.5).
///
/// Games with a single winner list one seat in `winners`; cooperative or drawn hands may list several
/// or none. `scores` is the per-hand delta (not cumulative — the match model, task 2.7, accumulates
/// across hands, R-ENG-6.2). Kept small and `Codable`/`Sendable` so it can ride in a `GameEvent` and a
/// `HandSummary` alike (R-ENG-8.5).
public struct HandOutcome: Codable, Sendable, Hashable {
    /// The seat(s) that won this hand; empty for a draw or a still-scoring cooperative result.
    public let winners: [SeatID]

    /// Each seat's score *for this hand* (a per-hand delta, not the cumulative match score).
    public let scores: [SeatID: Int]

    public init(winners: [SeatID] = [], scores: [SeatID: Int] = [:]) {
        self.winners = winners
        self.scores = scores
    }

    /// A drawn/no-winner outcome with no scores — a convenient neutral value.
    public static let draw = HandOutcome()
}

// MARK: - Undo policy (R-ENG-7.3, R-ENG-7.4)

/// How far a game permits undo — declared by each `GameDefinition` (R-ENG-7.3).
///
/// Solitaire games choose `unlimited` (full undo/redo); multi-seat games default to `none`; a multi-seat
/// game may offer `practiceMode`, where undoing the last human action rolls back and re-decides any AI
/// actions taken after it, and the game is excluded from statistics (R-ENG-7.4). The match/undo
/// machinery that acts on this policy is task 2.7; the enum lives here because the protocol references
/// it (design.md §2.7).
public enum UndoPolicy: Codable, Sendable, Hashable {
    /// Unlimited undo and redo — Solitaire (R-ENG-7.3).
    case unlimited

    /// No undo — the multi-seat default (R-ENG-7.3).
    case none

    /// Undo the last human action, rolling back and re-deciding AI actions after it; excluded from
    /// statistics (R-ENG-7.4).
    case practiceMode
}
