# Tasks — 02 Solitaire Collection

Implementation plan for `requirements.md` / `design.md`. Tasks are small and incremental. **Every task
ends with `make build test lint` passing** (Swift 6 strict concurrency, zero warnings — R-BUILD-5) and
cites the requirement IDs it satisfies. This spec **reuses** `EngineCore`, `AIKit`, and `TableKit` as they
stand after Spec 1 and **retrofits** Klondike; no `EngineCore`/`TableKit` public-API change is made without
an ADR first (R-SETUP2-1.3). Each new game follows the nine-step "How to add a new game" checklist in
`Docs/Architecture.md` (R-SETUP2-1.1). Ordering **builds the shared solver first**, because the Klondike
retrofit and every game's winnable-deal pool depend on it. **Checkpoint** tasks are review gates:
implementation pauses for the user to run the app and approve — including a **play-the-game** checkpoint
after each new game.

Legend: 🎨 = produces a **placeholder asset flagged "needs production art"** (R-DS-6, R-DS-4.2).

---

## Phase 1 — Shared solver (`SolverKit`) + package placement (build the solver first)

- [ ] **1.1 Create `Packages/SolverKit` + wire the dependency graph.** Add a new **pure** SwiftPM package
  `SolverKit` (Swift stdlib + Foundation only, no UI frameworks) depending only on `EngineCore`; wire
  `GamesRules → SolverKit`, `AIKit → SolverKit`, and `SimulationCLI → SolverKit` into `project.yml` and the
  enforced dependency direction. Add the forbidden-import / dependency-direction lint coverage for the new
  package (`SolverKit` must **not** depend on `AIKit`, keeping the graph acyclic). _(R-SOLVER-2.1,
  R-SOLVER-2.2, R-SETUP2-1.3)_
- [ ] **1.2 Update `Docs/Architecture.md` + finalize ADR 0003.** Apply the exact `design.md` §1.2 edit:
  add the `SolverKit` node and edges `SolverKit → EngineCore`, `GamesRules → SolverKit`,
  `AIKit → SolverKit`, `SimulationCLI → SolverKit` to the layered module-map mermaid block; add the
  `SolverKit` module-description line; add exactly those four edges (and no others) to the lint
  dependency-direction allow-list; add ADR 0003 to the Architecture Decision Records list. Finalize
  `Docs/ADR/0003-solver-package-placement.md` (solver placement decision + dependency-direction impact),
  resolving **Q2-7** / affirming **A2-11**. _(R-SOLVER-2.2, R-NFR-DOC.1, R-NFR-DOC.2)_
- [ ] **1.3 Solver public surface + deterministic budget.** Implement `SolveResult`
  (`winnable(bestFirstMove:)` / `unwinnable` / `unknown`), `SolverMove`, the `SolveBudget` (authoritative
  `maxNodes` node/iteration cap, optional `maxDepth`, non-authoritative `wallClock` safety valve), the
  `SolvableGame` protocol, and the `DealSolver` driver (sync + cancellable `async` wrapper running off the
  main actor). State intake is public-surface-only (`initialState`/`legalActions`/`apply`/`isTerminal`),
  no engine API change. _(R-SOLVER-1.1, R-SOLVER-1.3, R-SOLVER-1.4, R-SOLVER-3.3, R-SETUP2-1.3)_
- [ ] **1.4 Search core: canonical hashing, transposition table, pruning.** Implement `canonicalHash`
  (64-bit fixed-mixing digest over a canonical node serialization — columns sorted by stable key,
  foundations in fixed suit order, no wall-clock/address fields, ADR-0002 discipline), the transposition
  (visited) table with deterministic eviction, `isDead` local dead-state proofs, symmetry reduction (equal
  empty columns / interchangeable suits), and the verdict logic (`winnable` on `isWon`; `unwinnable` only
  when the reachable non-dead space is exhausted within budget; else `unknown` at `maxNodes`).
  _(R-SOLVER-1.1, R-SOLVER-3.1, R-NFR-SOLVER.3)_
- [ ] **1.5 Per-game `SolvableGame` conformances + move ordering.** Add compact `SolverNode` encodings and
  ordered `generateMoves` for Klondike (IDDFS, Draw-1/3 variant in-node), FreeCell (IDDFS), Spider 1- and
  2-suit (IDDFS, `spider-104` codes), Pyramid (best-first, 28-bit mask), and TriPeaks (best-first, 28-bit
  mask + current card). Document 4-suit Spider coverage / expected timeout rate, resolving **Q2-6**.
  Move ordering: forced/auto moves, then foundation/removal gains, then heuristic tableau moves, then
  reversible cell/stock moves. _(R-SOLVER-1.2, R-SOLVER-1.3, R-SOLVER-3.1)_
- [ ] **1.6 Solver correctness cross-checks + determinism + #11982 fixture.** Cross-check the solver
  against an exhaustive brute-force oracle on small, brute-forceable deals per game — `winnable` never for
  a provably-unwinnable deal, `unwinnable` never for a provably-winnable deal; a determinism test (same
  deal + same budget → same classification and same best move across runs); and a named regression fixture
  asserting Microsoft FreeCell deal **#11982** classifies **unwinnable** (fixture data landed here even
  though FreeCell numbering ships in Phase 2). Confirm interactive/generation budget defaults, resolving
  **Q2-11**. _(R-SOLVER-3.2, R-SOLVER-1.4, R-QA2-3.1, R-QA2-3.2, R-QA2-3.3, R-FREECELL-4.4, R-NFR-SOLVER.1,
  R-NFR-SOLVER.2, R-NFR-SOLVER.3)_
- [ ] **⛳ CHECKPOINT 1.** The solver classifies the known fixtures correctly (including MS deal #11982 =
  unsolvable), passes the exhaustive cross-checks and the determinism test, and honors the deterministic
  node budget; `Docs/Architecture.md` + ADR 0003 reflect `SolverKit`; `make build test lint` green. Review
  before Phase 2.

## Phase 2 — FreeCell (`freecell`) — first solver consumer, Microsoft numbering

- [ ] **2.1 FreeCell rules `GameDefinition`.** Deal 8 tableau columns (four of 7, four of 6, all face up),
  4 free cells (≤ 1 card each), 4 foundations; foundations build up by suit A→K, tableau builds down in
  alternating colors; empty column takes any single card or legal movable sequence; win when all 52 reach
  foundations. Author `Docs/Rules/freecell.md` (original writing; mirror the MS algorithm and mark any
  uncertain items NEEDS REVIEW). _(R-FREECELL-1.1, R-FREECELL-1.2, R-FREECELL-1.3, R-FREECELL-1.4,
  R-FREECELL-1.5, R-SETUP2-1.1, R-SETUP2-1.6, R-NFR-DOC.1)_
- [ ] **2.2 Supermove capacity (default on).** Implement the capacity rule
  **N ≤ (freeCells + 1) × 2^(emptyColumns)** with the **empty-destination exclusion** (a move into an empty
  column does not count that column, halving capacity); over-capacity springs back with a caption (no
  dialog); with supermove off, only single-card moves; coordinate the multi-card animation across drag /
  click-to-place / keyboard. _(R-FREECELL-2.1, R-FREECELL-2.2, R-FREECELL-2.3, R-FREECELL-2.4,
  R-FREECELL-2.5)_
- [ ] **2.3 Safe autoplay reusing Klondike's "Safe".** Wire the **Off / Safe (default) / Always** autoplay
  option to foundations, reusing Klondike's exact Spec 1 "Safe" definition (R-KLON-3.2) with no
  redefinition. _(R-FREECELL-3.1, R-FREECELL-3.2)_
- [ ] **2.4 Deal numbering — Parlor + Microsoft.** Implement **Parlor numbering** (deal numbers
  1–1,000,000 seeding the ADR-0002 `SeededRNG` + Fisher–Yates over the standard 52-card deck) and
  **Microsoft numbering** (deal numbers 1–32,000) using the exact `design.md` §3 LCG (state seeded to the
  deal number; `state = state*214013 + 2531011 mod 2^32`; `rand = (state >> 16) & 0x7FFF`; deck order
  A♣…K♣, A♦…K♦, A♥…K♥, A♠…K♠; `idx = rand % remaining`; swap-with-last removal; round-robin into 8
  columns). Add restart-same-deal and "Play deal #…" entry points for both modes. Confirm the deck
  orientation / column-fill authority against fixtures, resolving **Q2-14**. _(R-FREECELL-4.1,
  R-FREECELL-4.2, R-FREECELL-4.5)_
- [ ] **2.5 FreeCell scenario tests + MS conformance.** Given/When/Then tests per rule/option traceable to
  `Docs/Rules/freecell.md`, including supermove **boundary values** (exactly at capacity, one over, and
  into an empty destination column with halved capacity — the §7.2 worked example); Microsoft-numbering
  conformance for deal **#1**, one arbitrary mid-range deal, and **#11982** (byte-for-byte dealt order);
  and a Parlor-numbering determinism test. _(R-QA2-1.1, R-QA2-1.2, R-QA2-2.1, R-QA2-2.2, R-QA2-2.3,
  R-FREECELL-4.3)_
- [ ] **2.6 FreeCell layout + catalog registration.** Declarative table layout (8 columns, 4 free cells,
  4 foundations; no custom animation code); register `freecell` in the catalog behind a feature flag; wire
  FreeCell into the solver-backed hint path (§6 hint interface, R-AI-6) so hints report
  winnable/unknown/unwinnable and a best move. 🎨 placeholder game-tile art. Update
  `Docs/Architecture.md` game list. _(R-SETUP2-1.1, R-SETUP2-1.2, R-SETUP2-1.4, R-SETUP2-1.5, R-DS-6.1,
  R-NFR-DOC.1)_
- [ ] **⛳ CHECKPOINT 2.** User **plays a FreeCell deal end-to-end** via drag *and* keyboard (supermoves,
  free cells, safe autoplay), and confirms a Microsoft deal number reproduces the classic layout. Review
  before Phase 3.

## Phase 3 — Spider (`spider`)

- [ ] **3.1 Spider rules `GameDefinition`.** Use `spider-104` (two 52-card decks, 104 cards) with the
  **1 / 2 (default) / 4** suit-count option (reduced suits still total 104 per A2-2); deal 10 columns
  (columns 0–3 hold 6, columns 4–9 hold 5; 54 dealt, top of each face up), remaining 50 form the stock;
  no separate foundations. Author `Docs/Rules/spider.md` (original writing; mark the "move" definition +
  score floor NEEDS REVIEW). _(R-SPIDER-1.1, R-SPIDER-1.2, R-SPIDER-1.3, R-SPIDER-1.4, R-SPIDER-1.5,
  R-SETUP2-1.1, R-SETUP2-1.6, R-NFR-DOC.1)_
- [ ] **3.2 Spider moves, sequences, auto-flip, auto-collect.** Place any card on a card exactly one rank
  higher regardless of suit; move a **same-suit descending sequence** as a unit, mixed sequences one card
  at a time; empty column takes any single card or same-suit sequence; auto-flip a newly exposed top card;
  a King→Ace same-suit run **auto-collects** off the tableau; win when all 8 runs (104 cards) collected.
  _(R-SPIDER-2.1, R-SPIDER-2.2, R-SPIDER-2.3, R-SPIDER-2.4, R-SPIDER-3.1, R-SPIDER-3.2)_
- [ ] **3.3 Spider stock deal + empty-column rule + scoring.** Clicking the stock deals one card face up
  onto each of the 10 columns (consuming the stock in 5 deals); by default a deal is **refused** (spring-
  back + caption) if any column is empty, unless the "allow dealing onto empty columns" option (default
  off) is on; scoring **Standard** (start 500, −1 per move, +100 per completed run) or **timer-only**.
  Document the exact "move" definition/score floor (resolve **Q2-1**) and the empty-column option scope
  re: scoring/pool winnability (resolve **Q2-12**) in `Docs/Rules/spider.md`. _(R-SPIDER-4.1, R-SPIDER-4.2,
  R-SPIDER-4.3, R-SPIDER-5.1, R-SPIDER-5.2, R-SPIDER-5.3)_
- [ ] **3.4 Spider scenario tests + layout + catalog.** Given/When/Then tests for run auto-collection,
  same-suit-only unit moves, and the empty-column deal rule + its option, traceable to
  `Docs/Rules/spider.md`; declarative 10-column layout (no custom animation code); register `spider` behind
  a feature flag; wire the solver-backed hint (1- and 2-suit). 🎨 placeholder game-tile art. Update
  `Docs/Architecture.md`. _(R-QA2-1.1, R-QA2-1.3, R-SETUP2-1.1, R-SETUP2-1.2, R-SETUP2-1.4, R-SETUP2-1.5,
  R-DS-6.1, R-NFR-DOC.1)_
- [ ] **⛳ CHECKPOINT 3.** User **plays a Spider deal end-to-end** (at least 1-suit and 2-suit) via drag
  *and* keyboard (deal 10, same-suit unit moves, run auto-collect). Review before Phase 4.

## Phase 4 — Pyramid (`pyramid`)

- [ ] **4.1 Pyramid rules `GameDefinition`.** Deal a 28-card pyramid (rows of 1..7, each card overlapping
  the two below), remaining 24 form the stock, waste initially empty; a pyramid card is exposed only when
  both cards below it are gone (bottom row starts exposed). Author `Docs/Rules/pyramid.md` (original
  writing; mark pairing partners, redeal mechanic, and scoring formula NEEDS REVIEW). _(R-PYR-1.1,
  R-PYR-1.2, R-PYR-1.3, R-SETUP2-1.1, R-SETUP2-1.6, R-NFR-DOC.1)_
- [ ] **4.2 Pyramid removals + exposure.** Card values A=1, pips face value, J=11, Q=12, K=13; an exposed
  King removes alone; any two exposed cards summing to 13 remove together (Q+A, J+2, 10+3, 9+4, 8+5, 7+6);
  removing both children exposes the parent. Document the eligible pairing partners (pyramid / waste top /
  stock top), resolving **Q2-2**. _(R-PYR-2.1, R-PYR-2.2, R-PYR-2.3, R-PYR-2.4, R-PYR-2.5)_
- [ ] **4.3 Pyramid stock, waste, redeals, win/loss, scoring.** Drawing moves one card face up to the
  waste; redeal option **0 / 1 / 2 (default) / unlimited**; win when all 28 pyramid cards removed; detect
  the no-move/no-redeal loss with an inline banner offering undo/restart/new (no dialog); scoring by cards
  remaining and/or time. Document the exact redeal mechanic (resolve **Q2-3**) and the exact scoring
  formula (resolve **Q2-4**) in `Docs/Rules/pyramid.md`. _(R-PYR-3.1, R-PYR-3.2, R-PYR-3.3, R-PYR-4.1,
  R-PYR-4.2, R-PYR-4.3)_
- [ ] **4.4 Pyramid scenario tests + layout + catalog.** Given/When/Then tests for sum-to-13 pairs,
  King-alone removal, exposure rules, and each redeal setting, traceable to `Docs/Rules/pyramid.md`;
  declarative pyramid + stock/waste layout (no custom animation code); register `pyramid` behind a feature
  flag; wire the solver-backed hint. 🎨 placeholder game-tile art. Update `Docs/Architecture.md`.
  _(R-QA2-1.1, R-QA2-1.4, R-SETUP2-1.1, R-SETUP2-1.2, R-SETUP2-1.4, R-SETUP2-1.5, R-DS-6.1, R-NFR-DOC.1)_
- [ ] **⛳ CHECKPOINT 4.** User **plays a Pyramid deal end-to-end** via drag *and* keyboard (sum-to-13
  removals, draws, redeals). Review before Phase 5.

## Phase 5 — TriPeaks (`tri-peaks`)

- [ ] **5.1 TriPeaks rules `GameDefinition`.** Deal 28 cards into three overlapping peaks (rows of 3, 6, 9,
  10), remaining 24 form the stock with 1 turned face up as the starting **current card** (23 to draw); a
  peak card is exposed only when both cards overlapping it from below are removed (bottom row of 10 starts
  exposed). Confirm the `tri-peaks` id spelling, resolving **Q2-13**. Author `Docs/Rules/tri-peaks.md`
  (original writing; mark the streak bonus schedule NEEDS REVIEW). _(R-TRIP-1.1, R-TRIP-1.2, R-TRIP-1.3,
  R-SETUP2-1.1, R-SETUP2-1.5, R-SETUP2-1.6, R-NFR-DOC.1)_
- [ ] **5.2 TriPeaks play + wrap + end of game.** Play an exposed card exactly one rank higher or lower
  than the current card, regardless of suit (it becomes the new current card); **King–Ace wrap on by
  default** (K↔A adjacent), option to disable; removing a card can expose peak cards beneath; win when all
  28 peak cards removed; drawing turns one card up as the new current card; when the stock is empty and
  nothing is playable, the game ends (loss if peaks remain). _(R-TRIP-2.1, R-TRIP-2.2, R-TRIP-2.3,
  R-TRIP-2.4, R-TRIP-3.1, R-TRIP-3.2)_
- [ ] **5.3 TriPeaks streak scoring.** Consecutive plays without drawing increase the per-card bonus;
  drawing resets the streak to zero; track the **longest streak** for statistics. Document the exact
  streak bonus schedule / base values (resolve **Q2-5**) in `Docs/Rules/tri-peaks.md`. _(R-TRIP-4.1,
  R-TRIP-4.2, R-TRIP-4.3, R-TRIP-4.4)_
- [ ] **5.4 TriPeaks scenario tests + layout + catalog.** Given/When/Then tests for one-rank up/down play
  with wrap **on and off**, exposure, and streak reset on draw, traceable to `Docs/Rules/tri-peaks.md`;
  declarative three-peaks + stock/current-card layout (no custom animation code); register `tri-peaks`
  behind a feature flag; wire the solver-backed hint. 🎨 placeholder game-tile art. Update
  `Docs/Architecture.md`. _(R-QA2-1.1, R-QA2-1.5, R-SETUP2-1.1, R-SETUP2-1.2, R-SETUP2-1.4, R-SETUP2-1.5,
  R-DS-6.1, R-NFR-DOC.1)_
- [ ] **⛳ CHECKPOINT 5.** User **plays a TriPeaks deal end-to-end** via drag *and* keyboard (up/down play,
  wrap, draws, streak). Review before Phase 6.

## Phase 6 — Winnable-deal pools, Daily Deal, Klondike retrofit, statistics

- [ ] **6.1 `parlor-seedgen` winnable-deal generator + pool artifacts.** Add the `Scripts/`
  `parlor-seedgen` executable (SwiftPM, depends on `SolverKit` + rules targets + `EngineCore`, no UI) that
  deterministically generates **≥ 10,000 solver-confirmed winnable deals per game and per Spider
  suit-count variant (1, 2, 4)**, emitting the versioned `Codable` JSON pool artifact (schemaVersion,
  gameID, variant, numbering, generator/solver versions, budget, `deals` = deal identifiers only — never
  full boards). Wire a `make seedgen` target and the build-time verification hook. Resolve the pools
  checked-in-vs-cached + footprint decision (**Q2-8**) and the pool-generation time/space targets
  (**Q2-11 / R-NFR-SOLVER.4**). _(R-WINNABLE-1.1, R-WINNABLE-1.2, R-WINNABLE-1.3, R-NFR-SOLVER.4)_
- [ ] **6.2 "Winnable deals only" setup option (all five games).** Add a **"Winnable deals only"** setup
  option (default off) that draws the starting deal identifier from the appropriate pool instead of a fully
  random shuffle (Spider uses the current suit-count pool); selection is a cheap pool lookup that meets the
  ≤ 300 ms start-a-game budget (no at-launch solve). _(R-WINNABLE-1.4, R-WINNABLE-1.5, R-NFR-SOLVER.5)_
- [ ] **6.3 Daily Deal (all five games).** Add a per-game **Daily Deal**: the local calendar date is read
  at the host/UI layer and passed as config (rules never read wall-clock time); form
  `key = year*10000 + month*100 + day`, then `index = mix64(key) % poolCount` (fixed SplitMix64 finalizer)
  to pick a deal from the winnable pool, so same date + same machine → same deal, no network/server; the
  Daily Deal is always winnable and reachable as a distinct Library/setup entry. Document and resolve the
  exact date→index mapping incl. pool-growth stability (**Q2-9**). _(R-DAILY-1.1, R-DAILY-1.2, R-DAILY-1.3,
  R-DAILY-1.4, R-DAILY-1.5)_
- [ ] **6.4 Klondike retrofit — solver-backed hints.** Add a `SolverHintProvider` behind the existing
  Spec 1 hint interface (R-AI-6) reporting **winnable / unknown / unwinnable** with a plain-language reason
  and surfacing the **best next move** when winnable; it runs **alongside** the Spec 1 heuristic hints
  (R-KLON-3.5), which remain as a fast fallback when the solver returns `.unknown` within the interactive
  budget. No renumbering/restating of Spec 1 R-KLON-* requirements; no EngineCore/TableKit API change.
  _(R-KLON2-1.1, R-KLON2-1.2, R-KLON2-1.3, R-KLON2-1.4, R-NFR-SOLVER.1)_
- [ ] **6.5 Klondike retrofit — Winnable deals only + Daily Deal.** Add "Winnable deals only" (default off,
  drawing from a Klondike winnable pool) and a Daily Deal (using that pool) as additive options in
  Klondike's existing options schema. Decide/document the Klondike pool granularity (separate pools per
  winnability-affecting variant, at minimum Draw 1 vs Draw 3) and which variant the Daily Deal uses,
  resolving **Q2-10**. Update `Docs/Rules/klondike.md` for the retrofit. _(R-KLON2-2.1, R-KLON2-2.2,
  R-KLON2-2.3, R-NFR-DOC.1)_
- [ ] **6.6 Extended statistics + Daily Deal streak.** Additively extend the Spec 1 statistics model
  (R-APP-4) to all five solitaires (`klondike`, `spider` per suit count, `freecell`, `pyramid`,
  `tri-peaks`); add a per-game **Daily Deal streak** (current + best consecutive days won); add
  game-specific metrics (Spider completed runs + suit count; FreeCell numbering mode + deal number; Pyramid
  cards cleared; TriPeaks longest streak); keep Swift Charts visualization and confirm-on-reset. Additive
  fields → no save-format change / no ADR. _(R-STATS2-1.1, R-STATS2-1.2, R-STATS2-1.3, R-STATS2-1.4)_
- [ ] **⛳ CHECKPOINT 6.** User verifies that, for a fixed date/seed, **"Winnable deals only"** and the
  **Daily Deal** are deterministic across all five games, and that Klondike shows **solver-backed hints**
  (winnable/unknown/unwinnable + best move) alongside the heuristic hints. Review before Phase 7.

## Phase 7 — Tutorials & help, quality gates, docs finalize

- [ ] **7.1 Tutorials, hints, coach, in-app rules reference.** Add an interactive tutorial with scripted
  deals, hints (H), and coach mode (reusing the solver-backed hint interface to explain the suggested move)
  for each of `freecell`, `spider`, `pyramid`, and `tri-peaks`, and the Klondike solver-hint coach; each
  game's in-app rules reference opens in an inspector from `Docs/Rules/<id>.md` without losing game state.
  _(R-SETUP2-1.4, R-KLON2-1.1)_
- [ ] **7.2 `parlor-sim` invariants at Spec 1 volumes.** Wire each new game and each Spider suit-count
  variant into `parlor-sim` with the Spec 1 invariants (piece conservation, only-legal-actions, bounded
  termination, scoring consistency, deterministic replay) at **500 games/game/variant** in `make test` and
  **10,000** in `make test-long`. _(R-QA2-4.1, R-QA2-4.2)_
- [ ] **7.3 UI tests — win each game (drag + keyboard) + determinism.** XCUITest that wins one deal of each
  new game (`freecell`, `spider`, `pyramid`, `tri-peaks`) via **drag** and, separately, via **keyboard
  only**; verify that a fixed date/seed yields a **deterministic** "Winnable deals only" and Daily Deal
  selection. _(R-QA2-5.1, R-QA2-5.2)_
- [ ] **7.4 Coverage gate.** Enforce ≥ 90% line coverage for each new rules target **and for the solver**
  (`SolverKit`), in addition to EngineCore, wired into `make test`. _(R-QA2-6.1)_
- [ ] **7.5 Docs finalize + placeholder audit + Open Questions.** Confirm `Docs/Architecture.md` (incl. the
  `SolverKit` dependency-diagram update) and all `Docs/Rules/*.md` (spider, freecell, pyramid, tri-peaks,
  and the Klondike update) match implementation; confirm ADR 0003 matches the shipped placement and that no
  further ADR (0004+) was silently required; verify every 🎨 placeholder is flagged "needs production art"
  and listed for replacement; **resolve or re-affirm all Open Questions Q2-1..Q2-14** and confirm each was
  closed before its dependent task completed. _(R-NFR-DOC.1, R-NFR-DOC.2, R-DS-4.2, R-DS-6.1)_
- [ ] **⛳ CHECKPOINT 7 (final).** User runs `make test-long`; all quality gates, solver correctness, sim
  invariants, UI/keyboard, and coverage pass across all five solitaire games; the collection is proven end
  to end. `make build test lint` (and `make test-long`) green.

---

## Placeholder-art register (needs production art — R-DS-6, R-DS-4.2)

Tracked here and re-audited in task 7.5:

- FreeCell game-tile artwork (task 2.6) 🎨
- Spider game-tile artwork (task 3.4) 🎨
- Pyramid game-tile artwork (task 4.4) 🎨
- TriPeaks game-tile artwork (task 5.4) 🎨

## Traceability note

Every task lists the requirement IDs it implements; every requirement area in `requirements.md`
(R-SETUP2, R-SPIDER, R-FREECELL, R-PYR, R-TRIP, R-SOLVER, R-WINNABLE, R-DAILY, R-KLON2, R-STATS2, R-QA2,
R-NFR-SOLVER) is covered by at least one task above. The shared solver (`SolverKit`) is built in **Phase 1**,
before the winnable-deal pools (Phase 6) and the Klondike retrofit (Phase 6) that depend on it. A
play-the-game **⛳ CHECKPOINT** exists after each new game — FreeCell (2), Spider (3), Pyramid (4), TriPeaks
(5) — and after the winnable/Daily-Deal/Klondike-retrofit phase (6), with a final `make test-long` gate (7).
Open Questions **Q2-1..Q2-14** must be resolved before their dependent tasks are marked complete:
Q2-1/Q2-12 (3.3), Q2-2 (4.2), Q2-3/Q2-4 (4.3), Q2-5 (5.3), Q2-6/Q2-11 (1.5, 1.6, 6.1), Q2-7 (1.2),
Q2-8 (6.1), Q2-9 (6.3), Q2-10 (6.5), Q2-13 (5.1), Q2-14 (2.4), and all are re-affirmed in task 7.5.
