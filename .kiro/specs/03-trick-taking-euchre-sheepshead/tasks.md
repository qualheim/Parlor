# Tasks — 03 Trick-Taking I (Euchre & Sheepshead)

Implementation plan for `requirements.md` / `design.md`. Tasks are small and incremental. **Every task
ends with `make build test lint` passing** (Swift 6 strict concurrency, zero warnings — R-NFR-BUILD.1;
`01:R-BUILD-5`) and cites the requirement IDs it satisfies. The plan builds the **shared trick-taking core
first**, then Euchre, then Sheepshead, so the abstractions are proven before either game's specifics.
**Checkpoint** tasks are review gates: implementation pauses for the user to play a full hand and approve
before continuing.

This spec assumes the Spec 01 foundation exists (`EngineCore`, `AIKit`, `TableKit`, `parlor-sim`, the
`Makefile` targets, the save/stats/settings/library shell). It reuses those surfaces unchanged except for
the two **additive** touchpoints recorded in **ADR 0003**.

Legend: 📝 = authors/updates a doc; ⚖️ = requires an ADR decision to be settled first; 🔎 = contains a
NEEDS REVIEW item to resolve before the task is marked complete.

---

## Phase 0 — ADR and module scaffold

- [ ] **0.1 ADR 0003 + module scaffold.** ⚖️📝 Write `Docs/ADR/0003-trick-taking-core.md` (format matching
  ADR 0001/0002): the stable `TrickTaking` public contract, the additive EngineCore declaration/reveal
  `GameEvent` cases (§A), and the additive TableKit declaration input path (§B). Create the pure package
  `Packages/Games/TrickTaking/` and empty `Euchre`/`Sheepshead` rules targets + a `TrickTakingUI` target,
  wired into `project.yml` per the enforced dependency direction; lint confirms no UI imports in the pure
  targets. _(R-NFR-DOC.2, R-TT-6.1, A-1, A-2; `01:R-BUILD-1.4`, `01:R-BUILD-4.3`)_

## Phase 1 — Reusable trick-taking core (built and tested before either game)

- [ ] **1.1 TrumpScheme + effective suit + trick-rank.** Implement `TrumpScheme`, `TrickContext`, and
  `TrickRules.legalPlays/winner/violationForIllegalPlay`; unit tests for effective-suit shifting (a card
  whose printed suit ≠ effective suit follows/wins as its effective suit) and trump-beats-nontrump ordering.
  _(R-TT-1.1, R-TT-1.2, R-TT-1.3, R-TT-1.4, R-TT-1.5)_
- [ ] **1.2 Trick lifecycle.** Implement `Play`, `Trick`, `TrickPlayState` (leader, active-seat set that can
  be smaller than physical seats, completed tricks, winners, next-leader = winner); emit `trickWon` +
  move descriptors; tests for winner determination and completed-trick exposure for peek. _(R-TT-2.1,
  R-TT-2.2, R-TT-2.3, R-TT-2.4)_
- [ ] **1.3 Partnerships.** Implement `Partnership` (`fixed`, `hiddenPartner`, `loneDeclarer`), `SideID`,
  and per-viewer `side(of:asKnownTo:)` redaction; a view-leak unit test proves a hidden partner is nil in
  non-partner views until reveal. _(R-TT-3.1, R-TT-3.2, R-TT-3.3, R-TT-3.4, R-TT-3.5; `01:R-QA-3`)_
- [ ] **1.4 VoidTracker.** Record a seat void when it plays off-suit while a suit was led; expose as public
  facts; unit test that a recorded void constrains the `DeterminizationSampler` (no sampled hand holds a
  void suit). _(R-TT-4.1, R-TT-4.2, R-TT-4.3, R-TT-4.4)_
- [ ] **1.5 Auction/declaration framework.** Implement `Declaration`, `Auction`, `AuctionRules`
  (turn-ordered bidding, forced-declaration terminal rule), auction state in the redacted view, and
  declaration events (per ADR 0003 §A); unit tests for turn order, pass-through, and a forced terminal.
  _(R-TT-5.1, R-TT-5.2, R-TT-5.3, R-TT-5.4)_
- [ ] **1.6 Core determinism + purity test.** Property test: same seed + action log over core-only
  scenarios → identical state hash; lint confirms stdlib+Foundation only and no force-unwraps/`try!`.
  _(R-TT-6.1, R-TT-6.2, R-TT-6.3, R-NFR-BUILD.2; `01:R-ENG-4.4`)_

## Phase 2 — Euchre rules, doc, and scenario tests

- [ ] **2.1 Euchre TrumpScheme + deck + deal.** 🔎 Reuse `euchre-24`; implement Euchre's `TrumpScheme`
  (right/left bower, trump order A K Q 10 9, left bower as trump), 4 seats in fixed 2v2, deal 5 each + turn
  up the kitty top; composition test. Resolve Q-EUC-1 (deal pattern) or leave documented NEEDS REVIEW.
  _(R-EUC-1.1, R-EUC-1.2, R-EUC-1.3, R-EUC-1.4, R-EUC-3.1, R-EUC-3.2, R-EUC-3.3, R-EUC-3.4)_
- [ ] **2.2 Euchre bidding via the Auction framework.** Round-1 order-up (dealer picks up + discards, suit
  becomes trump), round-2 name-suit (except turned-down), stick-the-dealer default with a redeal option;
  makers/defenders recorded; declaration events + captions. _(R-EUC-2.1, R-EUC-2.2, R-EUC-2.3, R-EUC-2.4,
  R-EUC-2.5, R-EUC-2.6, R-TT-5.\*)_
- [ ] **2.3 Euchre going alone + play + scoring.** Going alone (partner sits out → 3 active seats),
  optional defend-alone; trick play via `TrickRules`; scoring 1/2/4 and euchre = 2; match to 10
  (configurable); physical-marker cosmetic option. _(R-EUC-4.1, R-EUC-4.2, R-EUC-4.3, R-EUC-5.1, R-EUC-5.2,
  R-EUC-5.3, R-EUC-5.5, R-EUC-5.6)_
- [ ] **2.4 Euchre rules doc + scenario tests.** 📝🔎 Author `Docs/Rules/euchre.md` (original writing; mark
  Q-EUC-1..Q-EUC-4 NEEDS REVIEW incl. the defender-alone bonus R-EUC-5.4); Given/When/Then scenario tests
  for round-1/round-2 bidding, stick-the-dealer + redeal, right/left bower ranking, left-bower-follows-as-
  trump, going alone, and each scoring outcome; each traceable to the doc. _(R-DOD-1.1, R-DOD-1.2,
  R-EUC-5.4, R-QA-1.1, R-QA-1.2)_
- [ ] **⛳ CHECKPOINT 1 (Euchre playable).** User plays a **full hand of Euchre** vs AI (round-1/round-2
  bidding, a loner, trick play with bowers, scoring) via drag, click, and keyboard, with captions and peek
  at last trick. Review before Phase 3. _(R-EUC-\*, R-UX-\*)_

## Phase 3 — Sheepshead rules, doc, and scenario tests

- [ ] **3.1 Sheepshead TrumpScheme + deck + points + deal.** 🔎 Reuse `sheepshead-32`; implement the 14-card
  trump order (Q♣>Q♠>Q♥>Q♦>J♣>J♠>J♥>J♦>A♦>10♦>K♦>9♦>8♦>7♦), fail order A 10 K 9 8 7, and points
  (A11/10 10/K4/Q3/J2/rest 0); 5 seats, deal 6 each + 2-card blind; composition test asserts 120 points.
  Resolve/flag Q-SHP-1. _(R-SHP-1.1, R-SHP-1.2, R-SHP-1.3, R-SHP-1.4, R-SHP-2.1, R-SHP-2.2, R-SHP-2.3,
  R-SHP-3.1, R-SHP-3.2, R-SHP-3.3, R-QA-2.2)_
- [ ] **3.2 Sheepshead pick/pass + bury.** Pick/pass auction (first to pick wins), take blind unseen, bury 2
  (buried points count for picker side); bury restrictions flagged Q-SHP-3. _(R-SHP-4.1, R-SHP-4.2,
  R-SHP-4.3)_
- [ ] **3.3 Sheepshead partner determination.** 🔎 Called Ace (default) via `hiddenPartner`; call-a-ten when
  picker holds all fail Aces (Q-SHP-5); "unknown"/"under" and picker-go-alone declarations (Q-SHP-6);
  Jack-of-Diamonds-always-partner option; partner redacted until the reveal event. Flag Q-SHP-4, Q-SHP-8.
  _(R-SHP-5.1, R-SHP-5.2, R-SHP-5.3, R-SHP-5.4, R-SHP-5.5, R-SHP-5.6, R-TT-3.3)_
- [ ] **3.4 Sheepshead no-pick options + play.** 🔎 Leaster (default), Doubler, Forced pick (one active per
  match); follow rules under trump/fail split; called-Ace-must-play rule flagged Q-SHP-8; Leaster
  objective/scoring/tie-break flagged Q-SHP-7. _(R-SHP-7.1, R-SHP-7.2, R-SHP-7.3, R-SHP-7.4, R-SHP-8.1,
  R-SHP-8.2)_
- [ ] **3.5 Sheepshead scoring table + zero-sum test.** 🔎 Implement the payout table (61–90 / 91–120
  schneider / all-tricks schwarz / 31–60 loss / ≤30 / no-tricks), double-on-the-bump on/off (R-SHP-6.2),
  and go-alone share-folding (Q-SHP-9); **unit test asserts every tier sums to zero** across all 5 players
  for bump on/off and with/without partner; boundary scenario tests at 60/61, 90/91, schwarz, and 0-trick.
  _(R-SHP-6.1, R-SHP-6.2, R-SHP-6.3, R-SHP-6.4, R-SHP-6.5, R-QA-2.1, R-QA-1.1)_
- [ ] **3.6 Sheepshead rules doc + remaining scenario tests.** 📝🔎 Author `Docs/Rules/sheepshead.md`
  (original writing; mark Q-SHP-1..Q-SHP-11 NEEDS REVIEW, flagging the go-alone interpretation clearly for
  confirmation); scenario tests for pick/bury, Called Ace + call-a-ten + unknown/under + go-alone + J♦
  option, and no-pick options; each traceable to the doc. _(R-DOD-1.1, R-DOD-1.2, R-QA-1.1, R-QA-1.2)_
- [ ] **⛳ CHECKPOINT 2 (Sheepshead playable).** User plays a **full hand of Sheepshead** vs AI (pick/pass,
  bury, Called-Ace partner with a reveal, trick play, the animated point tally, and the payout) via drag,
  click, and keyboard, with captions and peek at last trick. Review before Phase 4. _(R-SHP-\*, R-SHP-9,
  R-UX-\*)_

## Phase 4 — AI for both games

- [ ] **4.1 Euchre AI (Easy/Medium/Hard) + hint.** Easy: bid on strong hands, play highest legal; Medium:
  count trump + track voids in bid/play; Hard: determinized ISMCTS over kitty + opposing hands respecting
  voids; hint + coach explanation. Hard meets the p95 budget. _(R-EUC-6.1, R-EUC-6.2, R-EUC-6.3,
  R-NFR-AI.1, R-DOD-2.2)_
- [ ] **4.2 Sheepshead AI (Easy/Medium/Hard) + hint.** Easy/Medium: bid on trump count + high fail cards,
  play straightforwardly; Hard: called-partner belief model + determinized rollouts respecting voids
  (design §6.3); hint + coach explanation. Hard meets the p95 budget. _(R-SHP-11.1, R-SHP-11.2, R-NFR-AI.1,
  R-DOD-2.2)_
- [ ] **4.3 Void-respecting determinization wiring.** Confirm both games' `DeterminizationSampler` usage
  never assigns a void suit and never sees authoritative state; information-barrier test. _(R-TT-4.3,
  R-EUC-6.3, R-SHP-11.2; `01:R-AI-1.1`)_

## Phase 5 — Shared trick-taking UX (TableKit conventions)

- [ ] **5.1 Bidding/declaration UI (ADR 0003 §B).** Generic declaration panel driven by the `Auction` view,
  each option with a one-line explanation and three input paths + keyboard focus; reused by both games.
  _(R-UX-1.1, R-UX-1.2, R-TT-5.5; `01:R-TABLE-3`)_
- [ ] **5.2 Center trick pile + collection + captions + role badges.** Center pile collects to winner via
  the existing animation queue (no custom animation code); caption bar narrates bids/trump/trick/reveal/
  result; seat plates show dealer/Maker/Alone (Euchre) and Picker/Partner (Sheepshead, post-reveal) badges,
  active-turn glow, thinking indicator. _(R-UX-2.1, R-UX-2.2, R-UX-2.3; `01:R-TABLE-5`, `01:R-TABLE-6.2`)_
- [ ] **5.3 Legal-target highlight, "why not," peek, history, Sheepshead tally.** Highlight legal plays /
  dim unplayable; illegal → spring-back + shake + caption from `RuleViolation` (no dialog); peek at last
  trick + history drawer; Sheepshead animated point count-up then payout, skippable + Reduce-Motion aware.
  _(R-UX-3.1, R-UX-3.2, R-UX-3.3, R-SHP-9.1, R-SHP-9.2)_
- [ ] **5.4 Trick-taking accessibility.** VoiceOver labels speak trump/effective suit + playability;
  announce bids/trump/trick-wins/partner-reveals; keyboard-only play for all declarations; suit shapes +
  Four-Color deck. _(R-UX-4.1, R-UX-4.2, R-UX-4.3, R-UX-4.4; `01:R-A11Y-*`)_
- [ ] **⛳ CHECKPOINT 3 (UX + accessibility).** User completes a hand of **each** game keyboard-only and with
  VoiceOver, uses peek at last trick, and sees the Sheepshead tally. Review before Phase 6. _(R-UX-\*)_

## Phase 6 — Tutorials, setup, catalog, save/resume, statistics

- [ ] **6.1 Tutorials + coach + rules reference.** Scripted-deal interactive tutorials for both games;
  coach mode reuses the hint interface; in-app rules reference opens from `Docs/Rules/<game-id>.md` without
  losing state. _(R-DOD-2.1, R-DOD-2.2, R-DOD-2.3)_
- [ ] **6.2 Setup, presets, catalog, save/resume, statistics.** 🔎 Setup sheets (presets first — Euchre
  Standard; Sheepshead Standard/Casual/Tournament — then options + house rules grouped, each with a
  one-line explanation; preset contents flagged Q-EUC-4/Q-SHP-11); register both games in the catalog behind
  feature flags; save/resume at any point incl. mid-hand vs AI; per-game/variant statistics. _(R-DOD-3.1,
  R-DOD-3.2, R-DOD-3.3, R-DOD-3.4)_

## Phase 7 — Quality gates, sim, docs

- [ ] **7.1 parlor-sim wiring + invariants (reduced budget).** Wire both games into `parlor-sim` with
  invariants (piece conservation, only-legal-actions, bounded length, scoring consistency incl. Sheepshead
  zero-sum, deterministic replay) in **both** `make test` and `make test-long`; document the reduced AI
  search budget and its justification (design §7.1) in the sim config. _(R-QA-3.1, R-QA-3.2; `01:R-QA-2`)_
- [ ] **7.2 AI-tier-strength statistical test.** Seeded Hard-vs-Medium and Medium-vs-Easy for each game over
  the documented sample size; assert the stronger tier's advantage is statistically significant at the
  documented α; reproducible via injected RNG. _(R-QA-4.1, R-QA-4.2)_
- [ ] **7.3 View-leak + save/restore + coverage.** Extend the view-leak test to a hidden Sheepshead
  partnership (partner never in a non-partner view pre-reveal); save/restore round-trip at mid-bid,
  mid-hand, and post-reveal in both games; ≥ 90% coverage for the core and both rules targets. _(R-QA-5.1,
  R-QA-5.2, R-QA-6.1)_
- [ ] **7.4 Determinism + performance checks.** Full-hand same-seed-+-log → identical hash for each game;
  confirm start ≤ 300 ms, ≥ 60 fps and ≤ 50 ms input on the trick table, memory ≤ 400 MB (extend ADR 0001
  with data only if a budget fails). _(R-NFR-DET.1, R-NFR-PERF.1, R-NFR-PERF.2)_
- [ ] **7.5 Docs finalize + NEEDS REVIEW audit.** 📝🔎 Update `Docs/Architecture.md` (add the `TrickTaking`
  core + the two games to the module map; note ADR 0003); confirm ADR 0003 matches the implementation;
  confirm both rules docs are complete; resolve or re-affirm every Q-EUC-\* and Q-SHP-\* NEEDS REVIEW item.
  _(R-NFR-DOC.1, R-NFR-DOC.2, R-DOD-1.2)_
- [ ] **⛳ CHECKPOINT 4 (final, Definition of Done).** User runs `make test-long`; all quality gates
  (scenario, zero-sum, sim invariants, AI-tier strength, view-leak, save/restore, coverage, determinism,
  performance) pass; both games meet the Game Definition of Done; the `TrickTaking` core is proven and ready
  for Spec 07 to reuse unchanged.

## Should (nice-to-have, not required for completion)

- [ ] **S.1 3-handed Sheepshead.** 🔎 Add a 3-handed variant (ruleset documented, Q-SHP-10 NEEDS REVIEW).
  _(R-SHP-10.1)_

---

## Open Questions register (resolve before the dependent task is complete)

- **Euchre:** Q-EUC-1 deal pattern (task 2.1), Q-EUC-2 defender-alone bonus (task 2.4), Q-EUC-3 misdeal
  option (task 2.4), Q-EUC-4 preset contents (task 6.2).
- **Sheepshead:** Q-SHP-1 deal/blind pattern (3.1), Q-SHP-2 re/contra betting (out of base scope),
  Q-SHP-3 bury restrictions (3.2), Q-SHP-4 legal-call constraints (3.3), Q-SHP-5 call-a-ten fallback (3.3),
  Q-SHP-6 unknown/under + go-alone presentation (3.3), Q-SHP-7 Leaster scoring/tie-break (3.4), Q-SHP-8
  partner-must-play-called-Ace (3.3/3.4), Q-SHP-9 go-alone defender-count/payment (3.5), Q-SHP-10 3-handed
  (S.1), Q-SHP-11 tournament preset (6.2).

## Traceability note

Every task lists the requirement IDs it implements; every requirement in `requirements.md` is covered by at
least one task above. NEEDS REVIEW items (🔎) must be resolved or re-affirmed before their dependent task is
marked complete (audited in task 7.5).
