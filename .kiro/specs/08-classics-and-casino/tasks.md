# Tasks — 08 Classics and Casino

Implementation plan for `requirements.md` / `design.md`. Tasks are small and incremental. **Every task
ends with `make build test lint` passing** (Swift 6 strict concurrency, zero warnings — `R-BUILD-5`) and
cites the requirement IDs it satisfies. Ordering reaches a playable vertical slice per game early.
**Checkpoint** tasks are review gates: implementation pauses for the user to **play the game** and approve
before continuing. 🎨 = produces a **placeholder asset flagged "needs production art"** (`R-DS-6`).

**Prerequisite:** Spec 6 (`06-poker-room`) must be complete before Casino tasks that reuse its evaluator
or chip/bet UI begin (A-1). Q-1/Q-2 (Spec 6 API shapes) and Q-3 (game IDs / target layout) must be
resolved before task 0.2 / 2.1 / 3.1 respectively.

---

## Phase 0 — Prerequisites, scaffold, ADR

- [ ] **0.1 Resolve blocking Open Questions.** Confirm Q-3 (game IDs `cribbage`/`blackjack`/`video-poker`
  and Cribbage-own-family / Casino-shared-family layout), and confirm Spec 6 completeness (A-1). Record
  answers in the rules docs and `design.md`. _(R-REUSE-3.1, R-REUSE-4.1; Q-3)_
- [ ] **0.2 Write ADR 0003 + scaffold targets.** Write `Docs/ADR/0003-casino-cribbage-families.md` (family
  targets, `blackjack-shoe-6` deck, Spec-6 reuse contract). Scaffold `Packages/Games/Cribbage` (+
  `CribbageUI`) and `Packages/Games/Casino` (+ `CasinoUI`) with the fixed folder shape, wired into
  `project.yml` per the enforced dependency direction; lint confirms the Casino/Cribbage rules targets
  import only stdlib + Foundation. _(R-REUSE-3.1, R-REUSE-3.2, R-REUSE-3.3, R-NFR-DOC-08.2)_
- [ ] **0.3 Deck definitions + composition tests.** Reuse `standard-52`; add `blackjack-shoe-6`
  `DeckDefinition` (312 cards, distinct `PieceID`s) with a composition test (312 total, 24 per rank, 78
  per suit); add Blackjack `CardSemantics` (2–10 face, J/Q/K = 10, Ace 1/11). No edits to `Card`/`Tile`.
  _(R-REUSE-4.3, R-ENG-2.2)_

## Phase 1 — Cribbage rules, scoring, and the exhaustive verification

- [ ] **1.1 Cribbage scoring function + unit tests.** Pure `score(hand, starter, isCrib)` → total +
  itemized breakdown: fifteens, pairs (incl. trips/quads), runs with duplicate-multiplier (double/triple/
  double-double), hand flush (4/5) vs crib flush (5-only), nobs. No force unwraps/`try!`. Unit tests for
  each scoring category and the hand-vs-crib flush distinction. _(R-CRIB-3.1–3.6, R-NFR-QUAL-08.1)_
- [ ] **1.2 Cribbage exhaustive verification + histogram fixture.** `Scripts/` step runs the full
  12,994,800-combination brute force, produces
  `Packages/Games/Cribbage/Tests/Fixtures/cribbage-score-histogram.json`; add the `make test-long` test
  asserting **max 29 / exactly 4 combinations at 29 / 19·25·26·27 absent** (fails loudly, never skips) and
  the fast `make test` test asserting the checked-in histogram's invariants + a deterministic sample.
  Record the fast-vs-long placement decision (Q-9). _(R-QA-CRIB-1.1–1.4; Q-9)_
- [ ] **1.3 Cribbage GameDefinition — deal, discard, starter, heels.** Conform to `GameDefinition` for
  `cribbage`: 2 players, deal 6 each, simultaneous discard to the dealer's crib, non-dealer cut + dealer
  flips starter, starter-Jack → dealer +2 (heels), dealer rotation. Redact opponent hand + crib until
  turned. _(R-CRIB-1.1–1.7, R-SESS-3.2, R-ENG-5.\*)_
- [ ] **1.4 Cribbage pegging.** Alternating play, running total ≤ 31, legality (no card that exceeds 31),
  fifteen = 2, pair/trips/quad = 2/6/12, runs ≥ 3 regardless of play order, 31 = 2, go = 1, last card = 1,
  reset after 31/go. Emit `scoreChanged`/caption events per score. _(R-CRIB-2.1–2.9)_
- [ ] **1.5 Cribbage the show + match/win + skunks.** Count non-dealer, then dealer, then crib (crib
  flush = 5-only); target 121 default / 61 option; end immediately on reaching target; skunk flags as
  stats only (thresholds NEEDS REVIEW). _(R-CRIB-3.1, R-CRIB-4.1–4.3; Q-4)_
- [ ] **1.6 Manual counting + Muggins (off by default).** Automatic counting default; Manual Counting
  option where the player states a count and only that is pegged; opponent "Muggins" claims under-counted
  points. No Muggins affordance when off. _(R-CRIB-5.1–5.4)_
- [ ] **1.7 Cribbage scenario tests.** Given/When/Then per rule/option, traceable to
  `Docs/Rules/cribbage.md`: every pegging score, heels, nobs, hand-vs-crib flush distinction, Muggins.
  _(R-QA-CRIB-2.1, R-QA-1.1)_
- [ ] **1.8 Cribbage rules doc.** Author `Docs/Rules/cribbage.md` (original writing): every option/default/
  preset, the run-multiplier table, counting order, skunk thresholds marked **NEEDS REVIEW** (Q-4).
  _(R-CRIB-8.4, R-NFR-DOC-08.1; Q-4)_

## Phase 2 — Cribbage AI, table, peg board, tutorial

- [ ] **2.1 Cribbage AI (Easy/Medium/Hard) + hint.** Easy = reasonable discard + safe pegging; Medium =
  expected hand+crib value at discard + limited-lookahead pegging; Hard = full discard-value search + AI
  sees only the redacted view; time-budgeted, cancellable, off-main-actor; hint via AIKit interface.
  Confirm/record the Hard p95 budget (Q-5). _(R-CRIB-7.1–7.5, R-CRIB-8.1, R-AI-1.1, R-AI-3, R-AI-6; Q-5)_
- [ ] **2.2 Cribbage table layout + peg board.** Declarative layout (hands, crib, play area, starter);
  `CribbageUI` **double-track-per-player** peg board driven by `scoreChanged` events, captions per score,
  Reduce-Motion crossfade, "peek at last play," history drawer. Confirm no TableKit change is required
  (else ADR). 🎨 peg-board art. _(R-CRIB-6.1–6.4, R-DOD-2.1, R-DOD-2.2, R-TABLE-1.2; ADR if TableKit
  touched)_
- [ ] **2.3 Cribbage coach + tutorial + a11y + stats + catalog.** Coach reuses the hint; interactive
  tutorial with scripted deals; VoiceOver labels for pegs/board and keyboard-only play; per-game stats
  (skunks for/against, avg hand/crib, best hand); register `cribbage` behind a feature flag. _(R-CRIB-8.2,
  R-CRIB-8.3, R-DOD-1.2, R-DOD-1.3, R-DOD-3.1, R-DOD-3.2, R-A11Y-\*)_
- [ ] **⛳ CHECKPOINT 1 — Play Cribbage.** User plays a full Cribbage match vs AI (deal, discard, pegging
  with captions, the show, animated peg board), tries Manual Counting + Muggins, and uses the hint.
  `make build test lint` green. Review before Phase 3.

## Phase 3 — Blackjack (reuses Spec 6 chip/bet UI)

- [ ] **3.1 Blackjack GameDefinition — shoe, deal, peek, insurance.** Conform for `blackjack`: 6-deck shoe
  from seeded Fisher–Yates, penetration-threshold reshuffle (NEEDS REVIEW Q-6), configurable seats
  (human + AI/empty), deal two each (dealer upcard up / hole down), insurance out-of-turn window on Ace
  upcard, dealer peek on Ace/10, **insurance resolved before peek result revealed** (Q-7), immediate
  resolve on dealer blackjack. Redact the hole card. _(R-BJ-1.1–1.4, R-BJ-2.1–2.6, R-SESS-3.3; Q-6, Q-7)_
- [ ] **3.2 Blackjack player actions + totals + splits.** Hit/stand/double (one card, double bet); soft/
  hard totals (Ace 1/11 to benefit); bust; split up to 3 (4 hands); DAS default on (toggle); re-split Aces
  under the same limit; split Aces one card, no further hits, split-Ace 21 not a blackjack; illegal
  attempt → spring-back + caption. _(R-BJ-3.1–3.4, R-BJ-4.1–4.5, R-TABLE-4.1)_
- [ ] **3.3 Blackjack dealer rules + payouts.** S17 default / H17 preset; dealer draws to hard 17 per
  setting; blackjack 3:2; win 1:1; push returns bet; insurance 2:1; exact integer chip conservation;
  resolution captions + chip animation via reused chip UI. _(R-BJ-5.1–5.5, R-REUSE-2)_
- [ ] **3.4 Blackjack scenario tests.** S17/H17, peek+insurance timing, DAS on/off, split limits, split-
  Ace restrictions, payout math (3:2, insurance 2:1, pushes, conservation); traceable to the rules doc.
  _(R-QA-BJ-1.1, R-QA-1.1)_
- [ ] **3.5 Blackjack AI + coach + Hi-Lo trainer.** AI Easy/Medium/Hard (basic strategy for the configured
  S17/H17 + DAS), sees only the redacted view, never uses Hi-Lo; coach overlay (off by default) reuses the
  hint; Hi-Lo trainer (off by default) display-only with a test asserting it changes **no** game state/
  outcome. _(R-BJ-6.1–6.3, R-BJ-7.1, R-BJ-7.2, R-AI-6)_
- [ ] **3.6 Blackjack chip/bet UI reuse.** Wire `CasinoUI` bets/balances/payouts to Spec 6's chip and
  bet-sizing components (no reimplementation); play chips only, no monetary affordances. IF a needed prop/
  callback is missing, extend the shared component + ADR (do not copy). _(R-REUSE-2.1–2.3; ADR if shared
  API changed)_
- [ ] **3.7 Blackjack tutorial + a11y + stats + catalog + rules doc.** Interactive tutorial (scripted
  deals); VoiceOver labels for cards/chips, keyboard-only play; stats (hands, net chips, blackjacks, win/
  push/loss); register `blackjack` behind a feature flag; author `Docs/Rules/blackjack.md` (S17/H17, DAS,
  split limits, penetration, peek/insurance timing) with NEEDS REVIEW (Q-6, Q-7). _(R-BJ-8.1–8.3,
  R-DOD-1.\*, R-DOD-3.\*, R-NFR-DOC-08.1; Q-6, Q-7)_
- [ ] **⛳ CHECKPOINT 2 — Play Blackjack.** User plays Blackjack (S17 default; try H17), takes insurance on
  an Ace upcard, splits, doubles, sees 3:2 payouts, toggles coach + Hi-Lo trainer (confirming the trainer
  changes nothing). `make build test lint` green. Review before Phase 4.

## Phase 4 — Video Poker (reuses Spec 6 evaluator + chip/bet UI)

- [ ] **4.1 Video Poker GameDefinition — deal, hold, draw.** Conform for `video-poker`: single player,
  fresh seeded 52-card shuffle per hand, bet 1–5 credits (reused chip UI), deal 5 face up, hold/discard via
  keys 1–5 (toggle) or click, draw once, then score. Redact undrawn deck order. _(R-VP-1.1–1.6,
  R-DOD-3.2)_
- [ ] **4.2 Video Poker pay table + evaluator reuse.** Pay table as data (exact 9/6 table incl. 5-credit
  Royal 4,000 bonus, J/Q/K/A restriction); rank final hands with **Spec 6's evaluator** via a small pure
  adapter (derive Jacks-or-Better from paired-rank detail, do not re-rank). IF the evaluator lacks that
  detail, change the **shared** evaluator + ADR. Exact-pay-table test. _(R-VP-2.1–2.4, R-REUSE-1.1–1.3,
  R-QA-VP-1.1; ADR if shared API changed; Q-1)_
- [ ] **4.3 Video Poker EV-hint (32-subset exhaustive) + correctness test.** On-demand hint (H key/button)
  evaluating all 32 holds' exact EV over remaining-deck draws, ranked by the shared evaluator + pay table,
  display-only. Run off-main-actor/cancellable if needed; record live-vs-precomputed choice + measured
  latency (Q-8). Independent brute-force reference in the test target with a documented tie-break;
  assert the shipping hint matches on a seeded sample. _(R-VP-3.1–3.5, R-QA-VP-1.2, R-NFR-PERF-08.3; Q-8)_
- [ ] **4.4 Video Poker chip/bet UI reuse + payout animation.** Wire bet 1–5 and payout animation to Spec
  6's chip UI (no reimplementation); play chips only. _(R-REUSE-2.1–2.3, R-VP-1.2, R-VP-1.6)_
- [ ] **4.5 Video Poker tutorial + a11y + stats + catalog + rules doc.** Interactive tutorial (scripted
  deals); VoiceOver labels for cards + hold indicators; keyboard-only play (1–5 holds, H hint); stats
  (hands, best hand, royals, net chips); register `video-poker` behind a feature flag; author
  `Docs/Rules/video-poker.md` (pay table, bet range, hold/draw, EV-hint). _(R-VP-4.1, R-VP-4.2,
  R-DOD-1.\*, R-DOD-3.\*, R-NFR-DOC-08.1)_
- [ ] **⛳ CHECKPOINT 3 — Play Video Poker.** User plays Video Poker (bet 1–5, hold via 1–5 keys and click,
  draw, correct payouts incl. the 5-credit royal bonus), and uses the H optimal-hold hint.
  `make build test lint` green. Review before Phase 5.

## Phase 5 — Quality gates, sim, docs

- [ ] **5.1 Sim invariants for all three.** Wire `cribbage`, `blackjack`, `video-poker` into `parlor-sim`:
  shoe/deck conservation (312 / 52), only-legal-actions, bounded length, chip conservation, deterministic
  replay (seed + log → identical hash); `make test` fast sample, `make test-long` full volume. _(R-QA-SIM-1.1,
  R-QA-SIM-1.2)_
- [ ] **5.2 View-leak + save/restore for all three.** View-leak property test covers Cribbage opponent
  hand + crib, Blackjack hole card, Video Poker undrawn deck order; save/restore round trips at random
  action indices for all three. _(R-QA-VIEW-1.1, R-QA-VIEW-1.2)_
- [ ] **5.3 Coverage + performance gates.** ≥ 90% line coverage for the Cribbage and Casino rules targets;
  performance tests for Cribbage Hard AI p95 (Q-5) and Video Poker EV-hint latency (Q-8) against
  R-NFR-PERF-08. _(R-QA-COV-1.1, R-NFR-PERF-08.2, R-NFR-PERF-08.3)_
- [ ] **5.4 Docs finalize + Open-Question resolution + placeholder audit.** Update `Docs/Architecture.md`
  (three new games, family targets, Spec-6 reuse note); confirm ADR 0003 matches implementation and write
  any triggered ADR (Q-1 evaluator API, Q-2 chip UI API, or a TableKit change for the peg board); resolve
  or re-affirm all Open Questions Q-1..Q-9 in the rules docs / design.md; verify every 🎨 placeholder is
  flagged for replacement. _(R-NFR-DOC-08.1, R-NFR-DOC-08.2, R-DS-6.1)_
- [ ] **⛳ CHECKPOINT 4 (final).** User runs `make test-long`; the Cribbage exhaustive verification, all
  scenario tests, sim invariants, coverage, and performance budgets pass. All three games reach the Game
  Definition of Done. Review complete.

---

## Documentation-sync note

Per `structure.md` / `R-NFR-DOC-08.1`, `Docs/Architecture.md` and the `Docs/Rules/*.md` are updated in the
task that changes behavior — hence the rules docs are authored inside each game's phase (tasks 1.8, 3.7,
4.5) and Architecture.md is finalized in task 5.4. Because this spec-authoring change introduces no
behavior yet, only ADR 0003 (a family/target-registration decision) is written up front; behavior docs and
any triggered ADRs are produced during implementation.

## Placeholder-art register (needs production art — R-DS-6)

- Cribbage peg-board art (task 2.2) 🎨
- (Card faces, chips, table themes, and game-tile art are inherited from Spec 1 / Spec 6 and reused.)

## Traceability note

Every task lists the requirement IDs it implements; every requirement in `requirements.md` is covered by
at least one task above. Open Questions Q-1..Q-9 must be resolved before their dependent tasks (Q-1 → 4.2,
Q-2 → 3.6/4.4, Q-3 → 0.1/0.2, Q-4 → 1.5/1.8, Q-5 → 2.1/5.3, Q-6/Q-7 → 3.1/3.7, Q-8 → 4.3/5.3, Q-9 → 1.2)
are marked complete.
