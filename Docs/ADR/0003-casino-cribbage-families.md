# ADR 0003 — Casino and Cribbage family targets and Spec-6 component reuse

- **Status:** Accepted (spec-time; 08-classics-and-casino)
- **Date:** 2026-09-28
- **Context spec:** `/.kiro/specs/08-classics-and-casino/`
- **Relates to requirements:** R-REUSE-1, R-REUSE-2, R-REUSE-3, R-REUSE-4, R-ENG-2, R-NFR-DOC-08
- **Depends on:** `06-poker-room` (prerequisite; see Assumption A-1)
- **Supersedes / superseded by:** none

## Context

Spec 8 adds three games — **Cribbage**, **Blackjack**, and **Video Poker (Jacks or Better)** — to round
out the catalog (`product.md` roadmap). Per `tech.md` rule 9 and `structure.md`, a new game is
game-specific modules only and must not require changes to `EngineCore` or `TableKit`; adding a family
target, a new deck composition, or reusing shared code across families is a structural decision worth
recording. Two facts make this ADR necessary now:

1. **`structure.md` already names the target families** (Games list includes `Casino` and `Cribbage`).
   This ADR fixes where each game lands and the game IDs, which are stable-once-shipped (`structure.md`).
2. **Blackjack and Video Poker must reuse Spec 6's poker hand evaluator and chip/bet-sizing UI** rather
   than duplicating them (`tech.md` rule 9). Because reuse crosses spec/target boundaries, the reuse
   contract and the "change-the-shared-code-not-a-copy" rule are recorded here.

Spec 6 (`06-poker-room`) is a prerequisite and is not yet authored; the exact shared API shapes are
therefore **NEEDS REVIEW** (spec Open Questions Q-1, Q-2). This ADR records the structural decisions that
do not depend on those exact signatures.

## Decision

1. **Family targets and folder shape.** Cribbage lives in `Packages/Games/Cribbage` (rules, pure) with a
   matching `CribbageUI`; Blackjack and Video Poker live together in `Packages/Games/Casino` (rules, pure)
   with a matching `CasinoUI`. Each game uses the fixed folder shape `Rules/`, `AI/`, `Layout/`,
   `Tutorial/`, `Tests/` (`structure.md`; R-REUSE-3.1, R-REUSE-3.2). The Casino and Cribbage **rules**
   targets import only the Swift standard library and Foundation (`tech.md` rule 1; R-REUSE-3.3),
   lint-enforced (R-BUILD-4.3).

2. **Stable game IDs.** `cribbage`, `blackjack`, `video-poker` (kebab-case), fixed once shipped
   (`structure.md`; R-REUSE-4.1). Confirmed by spec Q-3.

3. **New deck composition.** Add a `blackjack-shoe-6` `DeckDefinition` = 6× standard-52 (312 faces), each
   physical card a distinct `PieceID`, with a composition test (312 total; 24 per rank; 78 per suit)
   (R-ENG-2.2 pattern; R-REUSE-4.3). Cribbage and Video Poker reuse `standard-52`. Blackjack supplies a
   `CardSemantics` (2–10 face, J/Q/K = 10, Ace 1/11). `Card`/`Tile` are **not** edited.

4. **Reuse Spec 6's poker hand evaluator (no duplicate).** Video Poker ranks its final 5-card hands with
   Spec 6's shared, pure 5-card evaluator (R-REUSE-1.1). "Jacks or Better" is derived from the evaluator's
   output (one-pair category + the paired rank), not by a second ranking implementation (R-REUSE-1.2). IF
   the shared evaluator does not already expose the paired-rank detail, the change is made **in the shared
   evaluator** with its own follow-up ADR — never copied into `Casino` (R-REUSE-1.3). The exact evaluator
   API is NEEDS REVIEW pending Spec 6 (Q-1).

5. **Reuse Spec 6's chip and bet-sizing UI (no duplicate).** Blackjack and Video Poker present bets,
   balances, and payouts using Spec 6's chip/bet-sizing UI components in `CasinoUI`; they do not
   reimplement chip stacks, chip-to-pot motion, or bet controls (R-REUSE-2.1). All chips are **play chips
   with no monetary value**; no purchase/redemption affordance exists (R-REUSE-2.2; `product.md`
   non-goals). IF a needed prop/callback is missing, the shared component is extended with its own
   follow-up ADR — never copied (R-REUSE-2.3). The exact chip/bet UI API is NEEDS REVIEW pending Spec 6
   (Q-2).

6. **No EngineCore/TableKit change intended.** The Cribbage peg board is a `CribbageUI`-local view driven
   by standard `scoreChanged` events; it is designed to need no TableKit primitive. IF implementation
   proves otherwise, a follow-up ADR is required before the change (`tech.md` rule 9).

## Consequences

- **Positive:** ranking logic and chip/bet UI exist in exactly one place, keeping payouts and presentation
  consistent across the poker room and the casino games; the Casino/Cribbage rules stay pure and
  Linux-portable; adding the three games needs no EngineCore/TableKit edits.
- **Negative / risks:** Spec 8 has a hard dependency on Spec 6 shipping the reusable evaluator and chip/bet
  UI in shared, reachable locations (A-1). If Spec 6's actual API lacks a needed capability (Q-1, Q-2),
  Spec 8 must wait on a shared-API change plus a follow-up ADR rather than working around it with a copy.
- **Follow-ups:** confirm Q-1 (evaluator API), Q-2 (chip/bet UI API), Q-3 (IDs/layout) as Spec 6 lands;
  write a follow-up ADR if any shared API or TableKit/EngineCore surface must change; update
  `Docs/Architecture.md` when the three games register (spec task 5.4).
