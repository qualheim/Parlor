# Tasks — 05 Tile Rummy

Implementation plan for `requirements.md` / `design.md`. Tasks are small and incremental. **Every task
ends with `make build test lint` passing** (Swift 6 strict concurrency, zero warnings — R-BUILD-5) and
cites the requirement IDs it satisfies. Tile Rummy is added as **game-specific modules only** (no
EngineCore/TableKit API change; see `design.md` §0), so this plan assumes the Spec 1 platform foundation
exists (A-TR-1). Ordering reaches a playable vertical slice before polish. **Checkpoint** (⛳) tasks are
review gates: implementation pauses for the user to run the app and approve before continuing.

Legend: 🎨 = produces a **placeholder asset flagged "needs production art"** (R-DS-6, R-DS-4.2).

---

## Phase 1 — Rules doc, game skeleton, valid sets

- [ ] **1.1 Author `Docs/Rules/tile-rummy.md`.** Original writing (never copied): the 106-tile set, 2–4
  players, deal 14, hidden pool; group/run definitions (1 low, no wrap); initial meld ≥ 30 with jokers as
  represented value; table rearrangement after opening; End Turn gate; voluntary Reset & Draw +1; per-turn
  timer (incl. "no timer") and timer-expiry Reset & Draw +3; joker retrieval; end-of-round scoring with
  the +30 racked-joker penalty. List **every option with its default and the presets Standard / Casual /
  Tournament**, and mark each NEEDS REVIEW item (Q-TR-1..Q-TR-9). Update `Docs/Architecture.md` to note
  the new game and rules doc (same-task docs rule). _(R-TR-DOC-1, R-TR-TURN-4.1, R-NFR-DOC.1; resolves-in
  Q-TR-1..Q-TR-9)_
- [ ] **1.2 TileRummy target skeleton + GameDefinition metadata.** Create
  `Packages/Games/TileRummy/{Rules,AI,Layout,Tutorial,Tests}` and `Packages/Games/TileRummyUI` per
  `structure.md`; conform `TileRummyDefinition` to `GameDefinition` with id `tile-rummy`, seat range 2–4,
  family/duration/complexity; wire package deps (rules → AIKit, EngineCore; UI → TileRummy, TableKit).
  Reuse the `tile-rummy-106` `DeckDefinition`; supply tile point values through the existing
  `CardSemantics` extension point (`points`), not a new parallel type (no `Tile` edit). _(R-TR-RULES-1.1,
  R-TR-RULES-1.3, R-ENG-5.1, R-TR-NFR-7)_
- [ ] **1.3 State model + zones + redaction.** Implement `TileRummyState`, `Rack` (staging/main),
  `TableSet`, `TurnSnapshot`; pool = hidden, racks = owner-only, table = public; `redactedView` yields
  opaque tokens for pool/opponent racks. _(R-TR-RULES-2.3, R-TR-NFR-5, R-ENG-3.2, R-ENG-8.3)_
- [ ] **1.4 Valid group/run + joker resolution.** Implement `isGroup`, `isRun` (1 low, no wrap past 13),
  `resolveJokers`, `isValidSet`, `tableValid`; typed `RuleViolation` reasons for each failure. Scenario
  tests for groups (3–4 distinct colors), runs (consecutive, wrap rejected), and joker-substituted sets.
  _(R-TR-RULES-3, R-TR-RULES-4, R-TR-RULES-5, R-TR-TURN-1.2, R-TR-NFR-6, R-TR-QA-1)_

## Phase 2 — Deal, initial meld, turn loop, Reset & Draw, timer

- [ ] **2.1 Deal + draw.** Seeded Fisher–Yates shuffle of the 106 tiles; deal 14 × N; rest to pool;
  `dealt` event; pool draw emits `pieceRevealed` to the drawing seat only; determinism test (same
  seed+log → identical hash). _(R-TR-RULES-2.2, R-TR-RULES-2.4, R-TR-NFR-2, R-ENG-4)_
- [ ] **2.2 Initial-meld validation.** Implement `validateInitialMeld` (own-rack provenance, each set
  legal, sum ≥ 30 with jokers as represented value, multi-set opening allowed); add seat to `hasOpened`;
  gate table rearrangement until opened. **Scenario tests for initial-meld point counting including
  jokers**, and for the "may not rearrange table before opening" rule. _(R-TR-RULES-6, R-TR-RULES-7.1,
  R-TR-RULES-6.4, R-TR-QA-1)_
- [ ] **2.3 Turn loop + End Turn gate + snapshot.** Record `TurnSnapshot` at turn start; track
  `placedThisTurn`; `legalActions` includes `endTurn` only when table valid AND ≥ 1 tile placed;
  `turnChanged` on end. **Scenario tests for End Turn validity gating** (disabled when invalid or nothing
  placed; enabled otherwise). _(R-TR-TURN-1, R-TR-TURN-2, R-TR-QA-1)_
- [ ] **2.4 Voluntary Reset & Draw (+1).** Restore snapshot, draw 1, end turn; safe when pool empty (route
  to pool-exhaustion rule, no negative count). **Scenario test for voluntary Reset & Draw**, including
  piece conservation across the zone moves. _(R-TR-TURN-3, R-TR-TURN-5, R-TR-NFR-5, R-TR-QA-1)_
- [ ] **2.5 Timer + timer-expiry Reset & Draw (+3).** Host injects `timerExpired` (rules never read the
  clock); on expiry: invalid → restore + draw 3; valid+placed → endTurn; valid+idle → per Q-TR-7. Timer
  length configurable incl. "no timer". **Scenario test for timer-expiry Reset & Draw (+3).** _(R-TR-TURN-4,
  R-TR-QA-1)_
- [ ] **⛳ CHECKPOINT 1 (rules engine).** User runs the Tile Rummy scenario suite (`make test`): deal,
  initial meld with jokers, End Turn gating, both Reset & Draw flavors pass green with piece conservation
  holding. Review before Phase 3.

## Phase 3 — Jokers on the table, scoring, simulation invariants

- [ ] **3.1 Joker retrieval.** `reclaimJoker(from:using:)`: only after opening, exact represented
  number+color, joker → rack, set stays valid; implement the hold-vs-use rule that `Docs/Rules/tile-rummy.md`
  fixes for Q-TR-1. **Scenario test for joker retrieval.** _(R-TR-JOKER-1, R-TR-QA-1)_
- [ ] **3.2 End-of-round scoring.** Count remaining rack tiles (numbered = number), **racked joker = +30
  penalty**; winner convention per Q-TR-2; match accumulation + end condition via engine `Match`.
  **Scenario test for the end-of-round joker penalty** and winner scoring. _(R-TR-SCORE-1, R-TR-SCORE-2,
  R-TR-QA-1)_
- [ ] **3.3 parlor-sim wiring + piece-conservation invariant.** Register Tile Rummy in `parlor-sim`;
  assert every step: **all 106 tiles in exactly one place (pool/rack/table)**, only-legal-actions, bounded
  length, scoring consistency, deterministic replay; include Tile Rummy in the view-leak property test.
  `make test` = sample volume, `make test-long` = full. _(R-TR-NFR-5, R-TR-NFR-2, R-TR-QA-2, R-TR-QA-4,
  R-TR-TURN-5.2)_
- [ ] **3.4 Save/restore round trip (incl. mid-turn).** Persist `TileRummyState` with `startOfTurn`,
  `placedThisTurn`, `hasOpened`; restore at random points (including mid-turn) → identical outcome. _(R-TR-QA-5,
  R-PERS-1)_

## Phase 4 — AI

- [ ] **4.1 Easy/Medium AI.** Play the **first legal board extension from own rack** (open with a ≥ 30
  meld if unopened); Reset & Draw when none; see only `(PlayerView, publicLog, legal)`; off main actor,
  cancellable, injected RNG. Pass sim invariants. _(R-TR-AI-1.1, R-TR-AI-1.2, R-AI-1.1, R-TR-AI-2.3,
  R-TR-DOC-3)_
- [ ] **4.2 Hard AI: exact solver + heuristic/beam fallback.** Maximize tiles placed over the table+rack
  multiset; exact small-scale solver when small enough, beam/heuristic when too large; anytime and
  cancellable within the **≤ 1.5 s p95** budget. _(R-TR-AI-1.3, R-TR-AI-2.1, R-TR-AI-2.2, R-TR-NFR-1)_
- [ ] **4.3 AI solver-correctness test + hint/coach.** Hand-crafted small boards with a **known optimal
  play** assert the solver returns it (and the fallback returns a legal, non-worse-than-greedy play);
  `hint(view:)` returns a suggested action + reason; coach reuses it. _(R-TR-QA-3, R-TR-AI-3)_
- [ ] **⛳ CHECKPOINT 2 (AI).** User plays a hand vs the Hard AI; decisions stay within budget, are
  followable (pacing separate from animation speed), and never block the UI. Review before Phase 5.

## Phase 5 — Table UI, interaction, accessibility

- [ ] **5.1 Declarative layout + color+symbol tiles.** `TileRummyLayout` (pool, two-row racks per seat,
  shared table); cached vector tile faces keyed by (theme, face, scale, appearance) with a **distinct
  glyph per color** visible at S/M/L/XL. 🎨 placeholder tile glyphs/faces. _(R-TR-UX-6, R-TABLE-2.1,
  R-A11Y-3, R-A11Y-4, R-DS-6.1)_
- [ ] **5.2 Zoom/pan + two-tier rack + sort toggles.** Scroll/pinch-zoom and drag-pan the wide table
  (Reduce Motion → crossfades); staging vs. main rack rows; `sortRack` "by number" / "by run" as view-only
  toggles that never affect the End Turn gate. _(R-TR-UX-1, R-TR-UX-4, R-TR-UX-5, R-TABLE-5.3)_
- [ ] **5.3 Three input paths + multi-select run drag + spring-back.** Drag (single + contiguous-run),
  click-select-then-place, keyboard with visible focus, double-click smart move; illegal placement →
  spring-back + shake + caption from `RuleViolation`, **no dialog**. _(R-TR-UX-3, R-TR-UX-7, R-TR-UX-8,
  R-TABLE-3, R-TABLE-4.1)_
- [ ] **5.4 Live invalid-set outlining.** Derive per-set validity from the `PlayerView`; outline invalid
  sets in a **semantic warning token** plus a non-color hazard cue, updated live as tiles move, so a
  disabled End Turn is self-explanatory. _(R-TR-UX-2, R-A11Y-3)_
- [ ] **5.5 Animations, sounds, captions for every event.** Map `dealt`/`pieceMoved`/`pieceRevealed`/
  `scoreChanged`/`handEnded`/`turnChanged`/`captioned` to animation-queue moves, randomized sound cues
  (never twice in a row), and caption-bar narration; honor animation speed + Reduce Motion; AI pacing a
  separate setting. 🎨 placeholder audio (original/CC0/synthesized, noted in `THIRD_PARTY_NOTICES.md`).
  _(R-TR-UX-9, R-TR-DOC-5, R-DS-5.1, R-DS-6.1)_
- [ ] **5.6 VoiceOver + full keyboard play.** Meaningful label/value/hint for every tile, the pool, each
  rack row, each table set, and every control; announce opponent actions and results; complete a whole
  turn keyboard-only with a visible focus indicator. _(R-TR-UX-9.1, R-TR-UX-8, R-A11Y-1, R-A11Y-2)_
- [ ] **⛳ CHECKPOINT 3 (USER PLAYS A FULL ROUND).** The user plays **one complete round end-to-end** —
  deal, initial meld (≥ 30 with a joker), table rearrangement, End Turn and Reset & Draw (both flavors),
  joker retrieval, and round end with scoring — **using drag AND using keyboard only**, with live
  invalid-set outlining and the rules inspector. Do not continue until the user approves. _(R-TR-UX-*,
  R-TR-TURN-*, R-TR-JOKER-1, R-TR-SCORE-*, R-A11Y-2)_

## Phase 6 — Tutorial, rules reference, catalog, trademark guard, docs

- [ ] **6.1 Interactive tutorial + in-app rules reference.** Scripted deals teaching opening, extending,
  rearranging, jokers, and Reset & Draw; coach mode reuses the hint; rules inspector renders
  `Docs/Rules/tile-rummy.md` in place without losing game state. _(R-TR-DOC-4, R-TR-UX-9.4, R-APP-3.2)_
- [ ] **6.2 Statistics + catalog registration (feature-flagged).** Per-variant stats (rounds/matches
  played, won, win %, best score, tiles-placed metric); register Tile Rummy in the catalog behind a
  feature flag so it appears in the Library when ready. _(R-TR-DOC-6, R-APP-4.1, R-APP-1.2)_
- [ ] **6.3 Trademark-guard lint/test.** Add a `Scripts/` check (wired into `make lint`) **and** a test
  that **fails the build if the trademarked tile-rummy brand name appears anywhere in the repository** —
  source, identifiers, assets, UI strings, and docs (case-insensitive). _(R-TR-DOC-7)_
- [ ] **6.4 Coverage gate + docs finalize + placeholder audit.** Enforce ≥ 90% line coverage for the
  TileRummy rules target in `make test`; confirm `Docs/Architecture.md` and `Docs/Rules/tile-rummy.md` are
  current; **resolve or re-affirm Q-TR-1..Q-TR-9** in the rules doc; verify every 🎨 placeholder is flagged
  "needs production art". _(R-TR-NFR-3, R-NFR-DOC.1, R-DS-4.2, R-DS-6.1)_
- [ ] **⛳ CHECKPOINT 4 (final).** User runs `make test-long`; all Tile Rummy quality gates pass (sim
  invariants incl. piece conservation, view-leak, save/restore, coverage), the Hard AI meets its budget,
  the trademark guard is green, and the tutorial + rules reference work. Tile Rummy meets the `product.md`
  Definition of Done.

---

## Placeholder-art register (needs production art — R-DS-6, R-DS-4.2)

Tracked here and re-audited in task 6.4:

- Tile glyphs / color symbols and tile faces (task 5.1) 🎨
- Tile Rummy sound cues (task 5.5) 🎨
- Game-tile artwork for the Library entry (task 6.2) 🎨

## Traceability note

Every task lists the requirement IDs it implements; every requirement in `requirements.md` is covered by
at least one task above. The NEEDS REVIEW items (Q-TR-1..Q-TR-9) must be resolved in
`Docs/Rules/tile-rummy.md` before their dependent tasks (3.1 joker hold-vs-use Q-TR-1; 3.2 winner scoring
Q-TR-2; 2.5 idle-timer Q-TR-7; 2.2 initial-meld edges Q-TR-9) are marked complete.
