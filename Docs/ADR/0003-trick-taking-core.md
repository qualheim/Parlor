# ADR 0003 — Trick-taking core and its EngineCore/TableKit touchpoints

- **Status:** Accepted (Spec 03 baseline)
- **Date:** 2026-09-28
- **Context spec:** `/.kiro/specs/03-trick-taking-euchre-sheepshead/`
- **Relates to requirements:** R-TT-1..R-TT-6, R-TT-5.4, R-UX-1, R-EUC-3, R-SHP-2, R-SHP-5, R-NFR-DOC.2
- **Supersedes / superseded by:** none

## Context

Spec 03 builds a **reusable trick-taking core** and proves it with two partnership trump games, Euchre
(`euchre`) and Sheepshead (`sheepshead`). `tech.md` architecture rule 9 and `Docs/Architecture.md`
("How to add a new game") require a game to be **game-specific modules only**; IF a game needs a change to
the public API of `EngineCore` or `TableKit`, THEN that is an architecture smell and an ADR is required
(`structure.md`). Spec 07 (Hearts, Spades) is required to **reuse this core without modifying it**, so the
core's public surface must be treated as a stable contract from the moment it merges.

Two needs cannot be met by game-specific modules alone and therefore touch shared public APIs:

1. Bidding/declaration and hidden-partner **reveals** must flow through the one semantic event stream that
   already drives animation, captions, VoiceOver, sound, and the log (`01:R-ENG-8.1`). The Spec 01
   `GameEvent` set has no case for a declaration, a named trump, a picker being chosen, or a partner being
   revealed (R-TT-5.4, R-SHP-5).
2. Auctions need a **declaration input path** in TableKit (a bidding panel) alongside the existing card
   input paths, with the same three input methods and keyboard access (R-UX-1; `01:R-TABLE-3`).

Both are shared by every trick game (Spec 03 and Spec 07), so they belong in the shared layer, not in a
single game.

## Decision

1. **New shared, pure `TrickTaking` module.** `Packages/Games/TrickTaking/` imports only the Swift standard
   library and Foundation (`tech.md` rule 1; R-TT-6.1). It sits between the per-game rules targets and
   `EngineCore`/`AIKit` in the enforced dependency direction (`structure.md`). Its public contract —
   `TrumpScheme`, `TrickContext`, `TrickRules`, `Trick`/`TrickPlayState`, `Partnership`/`PartnerMethod`,
   `VoidTracker`, and `Auction`/`AuctionRules`/`Declaration` (Spec 03 `design.md` §2) — is a **stable
   contract**: Spec 07 consumes it unchanged. Any later change that would break that reuse requires a new
   ADR superseding this one.

2. **Additive EngineCore change (§A): new `GameEvent` cases.** Add `declared(SeatID, AnyDeclaration)`,
   `trumpNamed(Suit, by: SeatID)`, `pickerChosen(SeatID)`, and `partnerRevealed(SeatID, via: PieceID)` to
   the `GameEvent` enum. The additions are **additive and schema-versioned** (`01:R-ENG-8.5`); no existing
   case changes shape, so Spec 01 consumers and saves are unaffected. Reveals reuse the existing
   `pieceRevealed` token-binding mechanism (`01:R-ENG-8.4`) so animation stays continuous and no hidden
   identity leaks before the reveal (R-TT-3.5).

3. **Additive TableKit change (§B): declaration input path.** Add a generic **declaration panel** that
   renders the current `Auction`'s legal declarations from the redacted view, each with a one-line
   explanation, and offers direct manipulation, click-to-select-then-confirm, and keyboard, with a visible
   focus indicator (R-UX-1; `01:R-TABLE-3`, `01:R-A11Y-2`). This is additive; existing card input paths and
   the animation queue are unchanged, and the center trick pile reuses the existing layout/animation
   machinery with no per-game animation code (`01:R-TABLE-1.2`, `01:R-TABLE-5`).

4. **No other EngineCore/TableKit public-API changes.** Trump order, bowers, points, partnership, void
   tracking, and scoring are expressed entirely in the `TrickTaking` core and each game's `TrumpScheme`/
   `CardSemantics`; `Card`/`Tile` are not edited (`01:R-ENG-1.3`, `01:R-ENG-2.3`). The `euchre-24` and
   `sheepshead-32` `DeckDefinition`s already exist from Spec 01 (`01:R-ENG-2.2`).

## Consequences

- **Positive:** trick games become game-specific modules over one shared, tested core; Spec 07 adds Hearts
  and Spades without touching the core (the reuse guarantee this ADR protects); bidding/reveal narration,
  animation, VoiceOver, and the log all stay driven by the single event stream.
- **Negative / risks:** the two additive public-API changes must remain additive — a breaking change to the
  `GameEvent` set or the declaration path would require superseding this ADR and a save-format review
  (`structure.md`); the "stable contract" only holds if Spec 07 is genuinely served by the current surface,
  which is a design assumption validated at that time.
- **Follow-ups:** when Spec 07 lands, confirm Hearts (no-trump: `trump == nil`) and Spades (fixed trump +
  `Partnership.fixed`) reuse the core unchanged; if not, write a superseding ADR with the specific gap.
  Update `Docs/Architecture.md` to list this ADR and the `TrickTaking` module (Spec 03 task 7.5).
