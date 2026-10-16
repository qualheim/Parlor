// View redaction and the per-view token permutation — the core of R-ENG-8.2–8.4.
//
// A `PlayerView` must show a viewer only what it may see: pieces in zones the policy exposes appear as
// their real faces (`ViewPiece.known`), and everything hidden appears as an opaque `ViewToken`
// (`ViewPiece.hidden`) that cannot be traced back to the real piece (R-ENG-8.3). This file is the single
// interpreter of `Visibility` (R-ENG-3.3) plus the keyed token permutation that makes the "cannot be
// correlated across views" guarantee true rather than aspirational (R-QA-3.1).
//
// Two pieces, kept deliberately separate:
//
//   • `ViewTokenizer` — a deterministic, keyed map from a hidden `PieceID` to a `ViewToken`. Keyed by the
//     viewer *and* a per-view salt, it is a consistent bijection *within one view* (same `PieceID` → same
//     token, distinct pieces → distinct tokens) but produces *different* tokens under a different salt or
//     viewer, so two views cannot be joined to deanonymize a piece (R-ENG-8.3). It is pure — built on the
//     engine's own SHA-256 (StateHash.swift) — so it stays Linux-portable and needs no crypto framework
//     (`tech.md` rule 1).
//
//   • `Redaction` — given a set of `Zone`s, a `Viewer`, a per-view `salt`, and a resolver from `PieceID`
//     to its real face, it applies each zone's `Visibility` policy (plus per-piece face state) and emits
//     the redacted `[ZoneView]`. Games call this from `redactedView(of:for:)` (R-ENG-5.5) instead of
//     hand-rolling redaction per game (R-ENG-3.3).
//
// The `pieceRevealed` binding (R-ENG-8.4) closes the loop: when a hidden piece becomes visible, the host
// emits `.pieceRevealed(token:identity:)` where `token` is exactly the token *that viewer's* tokenizer
// assigned to the piece — recomputed with the same viewer + salt via `ViewTokenizer.token(for:)` — so the
// client can rebind the on-screen node and keep the flip continuous. See `tokenForReveal(...)` below.

import Foundation

// MARK: - Per-view token permutation (R-ENG-8.3)

/// A deterministic, keyed permutation from hidden `PieceID`s to opaque `ViewToken`s for a single view
/// (R-ENG-8.3).
///
/// Construct one per view with the `Viewer` and a per-view `salt`. Within that view the mapping is a
/// consistent bijection: asking for the same `PieceID` twice yields the same token, and two distinct
/// pieces never share a token. Because the token is derived by hashing `(salt, viewer, pieceID, nonce)`,
/// changing the salt or the viewer changes every token, so the same `PieceID` maps to unrelated tokens in
/// different views and the two cannot be correlated (R-QA-3.1).
///
/// The tokenizer is a `class` (reference type) because it memoizes the assignments it has made for this
/// view, which is what guarantees consistency and bijectivity as pieces are requested one at a time during
/// redaction. It is intended to be used within a single redaction pass and not shared across concurrency
/// domains; it is therefore not `Sendable`.
public final class ViewTokenizer {
    /// The viewer this permutation is keyed to.
    public let viewer: Viewer
    /// The per-view salt; a fresh salt yields an unrelated permutation (R-ENG-8.3).
    public let salt: UInt64

    /// Memoized `PieceID` → token assignments made in this view (ensures a consistent bijection).
    private var assigned: [PieceID: ViewToken] = [:]
    /// Tokens already handed out in this view, so a derivation collision can be detected and avoided.
    private var used: Set<UInt64> = []

    public init(viewer: Viewer, salt: UInt64) {
        self.viewer = viewer
        self.salt = salt
    }

    /// The `ViewToken` this view assigns to `piece`, deriving and memoizing it on first request
    /// (R-ENG-8.3).
    ///
    /// The token is the first 64 bits of `SHA-256(salt ‖ viewerKey ‖ pieceID ‖ nonce)`, starting at
    /// `nonce == 0` and incrementing only on the astronomically rare event that the derived value is
    /// already used by another piece in *this* view — which keeps the mapping an exact bijection while
    /// remaining fully deterministic for a given `(viewer, salt)`. Subsequent calls for the same piece
    /// return the memoized token.
    public func token(for piece: PieceID) -> ViewToken {
        if let existing = assigned[piece] { return existing }
        var nonce: UInt64 = 0
        while true {
            let candidate = Self.derive(salt: salt, viewer: viewer, piece: piece, nonce: nonce)
            if !used.contains(candidate) {
                let token = ViewToken(opaque: candidate)
                assigned[piece] = token
                used.insert(candidate)
                return token
            }
            nonce &+= 1
        }
    }

    /// Derive the raw 64-bit token value for `(salt, viewer, piece, nonce)` via the engine's SHA-256.
    ///
    /// The inputs are concatenated in a fixed, unambiguous byte layout so the derivation is stable across
    /// runs and platforms (it reuses the same pure SHA-256 as the state hash, ADR 0002). A one-way hash is
    /// what makes the token opaque: nothing about `piece.raw` can be recovered from the output without the
    /// salt, and the salt never crosses the boundary (R-ENG-8.3).
    private static func derive(salt: UInt64, viewer: Viewer, piece: PieceID, nonce: UInt64)
        -> UInt64
    {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(8 + 1 + 64 + 8 + 8)
        appendBigEndian(salt, to: &bytes)
        // A short viewer discriminator so different viewers key different permutations.
        bytes.append(viewerTag(viewer))
        if case .seat(let seat) = viewer {
            bytes.append(contentsOf: Array(seat.raw.utf8))
        }
        appendBigEndian(piece.raw, to: &bytes)
        appendBigEndian(nonce, to: &bytes)
        let digest = SHA256.digest(bytes)
        // Fold the first 8 digest bytes into a UInt64 (big-endian).
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(digest[i])
        }
        return value
    }

    /// A stable one-byte discriminator per `Viewer` case, so a seat, a spectator, and the debug viewer
    /// key different permutations even at the same salt.
    private static func viewerTag(_ viewer: Viewer) -> UInt8 {
        switch viewer {
        case .seat: return 0x01
        case .spectator: return 0x02
        case .debugOmniscient: return 0x03
        }
    }

    /// Append `value` to `bytes` in big-endian order (stable byte layout for hashing).
    private static func appendBigEndian(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}

// MARK: - Redaction (R-ENG-8.2, R-ENG-8.3, R-ENG-3.3)

/// The single interpreter of zone `Visibility` that turns authoritative zones into per-viewer `ZoneView`s
/// (R-ENG-3.3, R-ENG-8.2, R-ENG-8.3).
///
/// Games supply their zones and a `faceResolver` (a pure map from a `PieceID` to its real `KnownPiece`,
/// i.e. card or tile face) and get back a redacted `[ZoneView]`; they never re-implement the visibility
/// rules. This keeps the "no client sees a hidden identity" property (R-QA-3.1) enforced in one place.
public enum Redaction {

    /// Whether a piece in `zone` is visible to `viewer` under the zone's `Visibility` policy plus its
    /// per-piece face state (R-ENG-3.2, R-ENG-3.3).
    ///
    /// - `hidden`: never visible to anyone.
    /// - `ownerOnly`: visible only to the seat that owns the zone (and to `debugOmniscient`); a zone with
    ///   no owner is visible to no one under this policy.
    /// - `publicAll`: visible to everyone.
    /// - `topCardOnly`: only the top piece (last in `contents`) is visible; the rest are hidden.
    /// - `perPieceFaceState`: a piece is visible iff it is in the zone's `faceUp` set.
    ///
    /// `debugOmniscient` sees every identity regardless of policy (debug-only path, design.md §2.8); it
    /// must never be used in shipping redaction.
    public static func isVisible(
        piece: PieceID,
        in zone: Zone,
        to viewer: Viewer
    ) -> Bool {
        if case .debugOmniscient = viewer { return true }
        switch zone.visibility {
        case .hidden:
            return false
        case .ownerOnly:
            guard let owner = zone.owner else { return false }
            if case .seat(let seat) = viewer { return seat == owner }
            return false
        case .publicAll:
            return true
        case .topCardOnly:
            return zone.top == piece
        case .perPieceFaceState:
            return zone.isFaceUp(piece)
        }
    }

    /// Produce the redacted `[ZoneView]` for `viewer` over `zones`, tokenizing every hidden piece with
    /// `tokenizer` and resolving every visible piece's face with `faceResolver` (R-ENG-8.2, R-ENG-8.3).
    ///
    /// Zone and piece order are preserved so positional meaning survives redaction. A visible piece whose
    /// face the resolver cannot supply is, conservatively, tokenized as hidden rather than dropped — the
    /// safe default is to reveal nothing when the game cannot vouch for a face.
    public static func zoneViews(
        of zones: [Zone],
        for viewer: Viewer,
        using tokenizer: ViewTokenizer,
        faceResolver: (PieceID) -> KnownPiece?
    ) -> [ZoneView] {
        zones.map { zone in
            let pieces: [ViewPiece] = zone.contents.map { piece in
                if isVisible(piece: piece, in: zone, to: viewer),
                    let known = faceResolver(piece)
                {
                    return .known(known)
                } else {
                    return .hidden(tokenizer.token(for: piece))
                }
            }
            return ZoneView(id: zone.id, visibility: zone.visibility, pieces: pieces)
        }
    }

    /// Convenience that builds a fresh `ViewTokenizer` for `(viewer, salt)` and redacts `zones` in one
    /// call (R-ENG-8.2, R-ENG-8.3). Games without their own tokenizer bookkeeping use this.
    public static func zoneViews(
        of zones: [Zone],
        for viewer: Viewer,
        salt: UInt64,
        faceResolver: (PieceID) -> KnownPiece?
    ) -> [ZoneView] {
        let tokenizer = ViewTokenizer(viewer: viewer, salt: salt)
        return zoneViews(of: zones, for: viewer, using: tokenizer, faceResolver: faceResolver)
    }

    /// The `ViewToken` a `pieceRevealed` event must carry when `piece` becomes visible to `viewer`
    /// (R-ENG-8.4).
    ///
    /// A reveal binds the token the viewer's view had shown to the piece's real identity so the client
    /// rebinds the same on-screen node and the flip stays continuous. The host computes it with the *same*
    /// `(viewer, salt)` the view used, so `token` matches what the viewer saw before the reveal; it then
    /// emits `.pieceRevealed(token: token, identity: piece)`. This helper exists so the binding is derived
    /// identically in both places and can never drift.
    public static func tokenForReveal(
        piece: PieceID,
        seenBy viewer: Viewer,
        salt: UInt64
    ) -> ViewToken {
        ViewTokenizer(viewer: viewer, salt: salt).token(for: piece)
    }
}
