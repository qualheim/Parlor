# Requirements — 05 Tile Rummy

## Introduction

This spec defines **Tile Rummy**, an original-name implementation of the classic tile-rummy family
(roadmap Spec 5, "Tile games" in `product.md`). It is built entirely from the platform foundation
(Spec 1): the 106-tile set already defined in `EngineCore`, the host-authoritative session
architecture, the AIKit toolkit, and the generic `TableKit` renderer. The trademarked brand name for
this family is **never** used anywhere — not in code, identifiers, assets, UI text, or docs; the stable
game id is the kebab-case string `tile-rummy` (`structure.md`).

Tile Rummy is played by 2–4 players, each with a private rack, against a shared table of melded sets.
It exercises engine features no earlier game does at once: a large multiset of visually identical
pieces (piece conservation matters), a shared mutable public zone that any player may rearrange, a
per-turn snapshot for "reset," an optional per-turn timer, and jokers that stand in for a value.

### Binding source documents

The four steering documents are binding and are **not restated** here; requirements trace back to them:

- `product.md` — vision, audience, product principles, roadmap, Definition of Done, non-goals.
- `tech.md` — platform, rendering, architecture rules 1–9, security/privacy, dependencies, build/tooling,
  testing, performance budgets, code conventions.
- `structure.md` — repository layout, enforced dependency direction, conventions.
- `ux-guidelines.md` — north star, platform, visual language, motion, interaction, table conventions,
  learning/help, accessibility, sound, voice/copy.

This spec also inherits Spec 1 (`/.kiro/specs/01-platform-foundation/`); its requirement IDs (`R-ENG-*`,
`R-SESS-*`, `R-AI-*`, `R-TABLE-*`, `R-APP-*`, `R-PERS-*`, `R-A11Y-*`, `R-QA-*`, `R-BUILD-*`, `R-NFR-*`)
are referenced without restatement.

### Terminology

Terms (Seat, Player, Controller, Host, View, Zone, Action, Event, Hand, Match) are used as defined in the
`product.md` Glossary. Additional terms local to this spec:

- **Tile** — a physical piece with a unique `PieceID` and a `TileFace` (`EngineCore`, R-ENG-1). A face is
  either `.numbered(1…13, TileColor)` or `.joker(index:)`; `TileColor` is `red | blue | black | orange`.
- **Pool** — the shared face-down draw stock of undealt tiles.
- **Rack** — a seat's private holding of tiles, split into a lower **main row** and an upper **staging
  row** (a two-tier rack, `ux-guidelines.md` / R-TR-UX-4).
- **Table** — the shared public zone holding the melded sets.
- **Set** — a **group** (3–4 tiles of the same number, all different colors) or a **run** (3+ consecutive
  numbers of the same color).
- **Initial meld** — the first tiles a seat places on the table, which must total ≥ 30 points from that
  seat's own rack.
- **Round** — one hand: deal → play until a seat empties its rack (or a stop condition) → score. A match
  is a sequence of rounds (`product.md` Glossary: Hand → Match).

### EARS conventions

Acceptance criteria use EARS keywords: **WHEN** (event), **WHILE** (state), **IF/THEN** (unwanted
condition / decision), **WHERE** (feature is included), and ubiquitous **SHALL**. Each requirement has a
stable ID `R-TR-<AREA>-<n>.<m>` (areas: `RULES`, `TURN`, `JOKER`, `SCORE`, `UX`, `AI`, `DOC`, `QA`,
`NFR`). IDs are referenced by `design.md` and `tasks.md` and MUST NOT be renumbered once merged.

---

## 1. Tiles, players, and the deal (RULES)

### R-TR-RULES-1 — Tile set reused from EngineCore
**User story:** As a rules author, I want the 106-tile set to come from the existing engine deck
definition, so I never redefine the piece type or its composition.

- R-TR-RULES-1.1 Tile Rummy SHALL use the existing `EngineCore` `Tile`/`TileFace` types and the
  `DeckDefinition` with id `tile-rummy-106` (numbers 1–13 in 4 colors, two of each, plus 2 jokers);
  it SHALL NOT edit `Tile`/`TileFace` or add a new deck composition (per `tech.md` rule 9; R-ENG-1,
  R-ENG-2.2).
- R-TR-RULES-1.2 Each of the 106 tiles SHALL retain a unique, stable `PieceID` distinct from its face, so
  the two identical faces (e.g. both red 7s) are distinguishable in the log and in views (R-ENG-1.2).
- R-TR-RULES-1.3 Tile Rummy SHALL supply its own tile point values (a numbered tile is worth its number;
  a joker's value is context-dependent, see R-TR-RULES-6 and R-TR-SCORE-1) through the **existing
  `CardSemantics` extension point** (`points`, per the Architecture.md "How to add a new game" step 2), as
  game semantics layered over the face — never baked into `Tile` and never a new parallel engine type
  (R-ENG-2.3).

### R-TR-RULES-2 — Players, deal, and pool
**User story:** As a player, I want a correct 2–4 player deal with a hidden pool, so the round starts
fairly.

- R-TR-RULES-2.1 Tile Rummy SHALL support 2, 3, or 4 seats: the local human plus 1–3 opponents
  (`product.md` Glossary; seat range 2–4).
- R-TR-RULES-2.2 WHEN a round starts, the host SHALL shuffle the 106 tiles with the seeded Fisher–Yates
  shuffle (R-ENG-4) and deal 14 tiles to each seat's rack.
- R-TR-RULES-2.3 The remaining tiles SHALL form the face-down **pool**; the pool SHALL be a `hidden`
  zone and each seat's rack SHALL be `ownerOnly` (R-ENG-3.2), so opponents' racks and the pool appear as
  opaque tokens in every other viewer's `PlayerView` (R-ENG-8.3; R-TR-NFR-5).
- R-TR-RULES-2.4 WHEN a seat draws from the pool, the top-of-pool tile SHALL move to that seat's rack and
  a `pieceRevealed` event SHALL bind its token to its identity for that viewer only (R-ENG-8.4).

### R-TR-RULES-3 — Valid group
**User story:** As a player, I want groups validated correctly, so only legal melds can rest on the table.

- R-TR-RULES-3.1 A **group** SHALL be 3 or 4 tiles that all share the same number and each have a
  different color (so a group of 4 uses all four colors; a group of 3 uses three distinct colors).
- R-TR-RULES-3.2 IF two tiles in a candidate group share the same color, THEN the group SHALL be invalid.

### R-TR-RULES-4 — Valid run
**User story:** As a player, I want runs validated correctly, so consecutive sequences are legal and
wrapping is rejected.

- R-TR-RULES-4.1 A **run** SHALL be 3 or more tiles of the same color whose numbers are consecutive and
  strictly increasing (e.g. red 4-5-6).
- R-TR-RULES-4.2 The number **1** SHALL always be the low end of a run; a run SHALL NOT wrap past 13
  (there is no 13-1-2 and no 12-13-1). IF a candidate run wraps, THEN it SHALL be invalid (R-TR-RULES-4.2
  is confirmed non-ambiguous; see Q-TR-3 only for the separately-flagged low-ace assumption).

### R-TR-RULES-5 — Jokers as substitutes
**User story:** As a player, I want jokers to stand in for a needed tile, so I can complete sets.

- R-TR-RULES-5.1 A joker in a set SHALL represent exactly one specific tile (a number+color) that would
  make that set valid; a set containing a joker SHALL be valid only WHERE the joker's represented tile
  makes the whole set a legal group or run.
- R-TR-RULES-5.2 A single set SHALL contain at most one joker WHERE that constraint is enabled by the
  active options; the default and any variant are recorded in `Docs/Rules/tile-rummy.md` (see Q-TR-5).

### R-TR-RULES-6 — Initial meld ≥ 30 from own rack
**User story:** As a player, I want the standard 30-point opening requirement, so opening play matches the
classic ruleset.

- R-TR-RULES-6.1 A seat's **initial meld** SHALL consist only of tiles from that seat's own rack (not
  tiles already on the table) and SHALL total **≥ 30 points**.
- R-TR-RULES-6.2 WHEN counting initial-meld points, a numbered tile SHALL count as its number and a joker
  SHALL count as the value of the tile it represents in its set (R-TR-RULES-5.1).
- R-TR-RULES-6.3 The initial meld MAY comprise more than one set, provided every set placed is itself a
  valid group or run and the combined point total is ≥ 30 (R-TR-RULES-3, R-TR-RULES-4).
- R-TR-RULES-6.4 WHILE a seat has not completed its own initial meld, that seat SHALL NOT rearrange tiles
  already on the table; its only table interaction SHALL be placing its own initial meld (R-TR-TURN-2
  gates the turn).

### R-TR-RULES-7 — Table rearrangement after the opening
**User story:** As a player who has opened, I want to rearrange existing table sets, so I can extend and
recombine melds like the real game.

- R-TR-RULES-7.1 WHERE a seat has completed its own initial meld, that seat MAY, on its turn, move,
  split, and recombine any tiles already on the table together with tiles from its own rack, as long as
  every group and run on the table is a valid set at the moment the turn ends (R-TR-TURN-1).
- R-TR-RULES-7.2 A seat MAY complete its initial meld and, in the same turn (after the opening is
  satisfied), rearrange the table; whether that is allowed within one turn is the standard rule and is
  confirmed in `Docs/Rules/tile-rummy.md` (see Q-TR-6).

---

## 2. Turn structure, End Turn, Reset & Draw, timer (TURN)

### R-TR-TURN-1 — Table validity is the turn-end gate
**User story:** As a player, I want the turn to end only when the board is legal, so the table is never
left in a broken state.

- R-TR-TURN-1.1 The host SHALL take a **start-of-turn snapshot** of the table and the acting seat's rack
  at the beginning of each turn, to support Reset & Draw (R-TR-TURN-3, R-TR-TURN-4).
- R-TR-TURN-1.2 A set on the table SHALL be **valid** WHEN it is a legal group (R-TR-RULES-3) or run
  (R-TR-RULES-4), jokers resolved (R-TR-RULES-5); the table SHALL be **valid** WHILE every set on it is
  valid.
- R-TR-TURN-1.3 WHILE the table is invalid, the `endTurn` action SHALL NOT be a legal action for the
  acting seat (R-ENG-5.3).

### R-TR-TURN-2 — End Turn enablement
**User story:** As a player, I want "End Turn" available only after a legal, non-empty move, so I cannot
pass off an unfinished rearrangement.

- R-TR-TURN-2.1 The `endTurn` action SHALL be legal only WHILE the table is valid (R-TR-TURN-1.2) **AND**
  the acting seat has placed at least one tile from its rack onto the table this turn.
- R-TR-TURN-2.2 IF the acting seat has placed no tile this turn (or the table is invalid), THEN the only
  turn-ending action available SHALL be `resetAndDraw` (R-TR-TURN-3); no other end-of-turn path SHALL
  exist while the board is invalid (R-TABLE-4.1 governs the UI feedback, not a dialog).
- R-TR-TURN-2.3 A seat that cannot or does not wish to play SHALL end its turn via `resetAndDraw`, which
  draws the penalty tile(s) defined in R-TR-TURN-3 (see Q-TR-4 for the "draw exactly one and pass"
  variant).

### R-TR-TURN-3 — Voluntary Reset & Draw (+1)
**User story:** As a player, I want to undo my turn's arrangement and draw, so a dead end costs only one
tile.

- R-TR-TURN-3.1 WHEN a seat invokes `resetAndDraw`, the host SHALL restore the table and that seat's rack
  to the start-of-turn snapshot (R-TR-TURN-1.1), draw **1** tile from the pool into that seat's rack as a
  penalty, and end the turn.
- R-TR-TURN-3.2 IF the pool is empty when a penalty draw is required, THEN the host SHALL apply the
  pool-exhaustion rule (R-TR-TURN-5); no crash and no negative-count state SHALL occur (R-NFR-QUAL.1).

### R-TR-TURN-4 — Per-turn timer and timer-expiry Reset & Draw (+3)
**User story:** As a player, I want a configurable turn timer that penalizes leaving the board broken, so
timed play matches the classic penalty.

- R-TR-TURN-4.1 Tile Rummy SHALL provide a per-turn timer option whose length is configurable, **including
  a "no timer" setting** (default and preset values recorded in `Docs/Rules/tile-rummy.md`).
- R-TR-TURN-4.2 WHILE a timer is configured and the timer expires, IF the table is invalid at that
  instant, THEN the host SHALL restore the table and the acting seat's rack to the start-of-turn snapshot
  and draw **3** tiles from the pool into that seat's rack as a penalty, then end the turn.
- R-TR-TURN-4.3 WHEN the timer expires WHILE the table is valid and at least one tile was placed, the host
  SHALL treat it as `endTurn` (no penalty); WHEN it expires WHILE the table is valid but no tile was
  placed, the host SHALL treat it as voluntary Reset & Draw (+1) (R-TR-TURN-3) — the exact
  valid-but-idle expiry behavior is recorded in the rules doc (see Q-TR-7).
- R-TR-TURN-4.4 The timer SHALL be a UI/host-scheduling concern only; rules code SHALL NOT read
  wall-clock time (`tech.md` rule 8) — the host injects a "timer expired" action into the turn loop.

### R-TR-TURN-5 — Pool exhaustion
**User story:** As a player, I want a defined behavior when the pool empties, so the round always
terminates cleanly.

- R-TR-TURN-5.1 The behavior when the pool is empty and a seat cannot play or must draw a penalty SHALL be
  a documented option (round ends and is scored, versus play continues until no seat can improve the
  board); the default is recorded in `Docs/Rules/tile-rummy.md` (see Q-TR-8).
- R-TR-TURN-5.2 The round SHALL always terminate within a bounded number of actions (no infinite draw
  loop); a simulation invariant SHALL assert bounded length (R-QA-2.1; R-TR-QA-2).

---

## 3. Jokers on the table (JOKER)

### R-TR-JOKER-1 — Joker retrieval
**User story:** As a player, I want to reclaim a joker by playing the exact tile it represents, so a
joker can be freed for a bigger play.

- R-TR-JOKER-1.1 WHERE a seat has completed its initial meld, that seat MAY reclaim a joker resting in a
  table set by placing, in the joker's position, a tile from its rack whose number and color exactly
  match the tile the joker currently represents (R-TR-RULES-5.1).
- R-TR-JOKER-1.2 WHEN a joker is reclaimed, the replacing tile SHALL take the joker's place (leaving that
  set still valid) and the joker SHALL move to the reclaiming seat's rack.
- R-TR-JOKER-1.3 The exact conditions on the reclaimed joker — whether the seat MUST use it in a set
  during the **same** turn, or MAY hold it for a later turn — are **NEEDS REVIEW** and recorded in
  `Docs/Rules/tile-rummy.md` (see Q-TR-1); the engine SHALL implement whichever the rules doc fixes and a
  scenario test SHALL cover it (R-TR-QA-1).

---

## 4. Scoring (SCORE)

### R-TR-SCORE-1 — End-of-round tile values and joker penalty
**User story:** As a player, I want standard end-of-round counting, so scoring matches the classic game.

- R-TR-SCORE-1.1 WHEN a round ends, each non-winning seat's remaining rack SHALL be counted: a numbered
  tile counts as its number.
- R-TR-SCORE-1.2 A **joker remaining in a seat's rack** at round end SHALL count as a **30-point penalty**
  against that seat.

### R-TR-SCORE-2 — Winner scoring convention
**User story:** As a player, I want the winner scored by the classic convention, so the match total is
correct.

- R-TR-SCORE-2.1 WHEN a round ends, each seat's remaining rack total SHALL be counted per R-TR-SCORE-1
  (a numbered tile counts as its number; a racked joker counts as a 30-point penalty). The **round winner**
  is the seat that empties its rack (or the best board position if the pool-exhaustion option ends play).
  The **winner/loser scoring convention** — how those remaining-rack totals translate into each seat's
  round score (whether the winner receives a positive sum equal to opponents' totals, whether losers score
  their own remaining totals as negatives, or both in a zero-sum split) — is **NEEDS REVIEW** and recorded
  in `Docs/Rules/tile-rummy.md` (see Q-TR-2); the engine SHALL implement whichever convention the rules
  doc fixes, and a scenario test SHALL cover it (R-TR-QA-1).
- R-TR-SCORE-2.2 A match SHALL be a sequence of rounds with cumulative scores and a configurable end
  condition (target score or fixed number of rounds), reusing the engine match model (R-ENG-6).

---

## 5. Table, rack, and interaction UX (UX)

### R-TR-UX-1 — Zoomable, pannable table
**User story:** As a player, I want to zoom and pan the board, so a table wide with many sets stays
readable.

- R-TR-UX-1.1 The table SHALL be zoomable (pinch on a trackpad and scroll-to-zoom) and pannable (drag on
  empty table), so a board that grows wide with many sets can be navigated without losing tiles off
  screen (`ux-guidelines.md` platform).
- R-TR-UX-1.2 WHERE Reduce Motion is on, zoom/pan SHALL remain functional with movement replaced by
  crossfades where animated, with no loss of information (R-TABLE-5.3, R-A11Y-4).

### R-TR-UX-2 — Live invalid-set outlining
**User story:** As a player, I want invalid sets outlined as I arrange, so a disabled "End Turn" is always
self-explanatory.

- R-TR-UX-2.1 WHILE the acting seat is arranging tiles, any group or run on the table that is currently
  **invalid** SHALL be outlined in a semantic warning color, updated live as tiles move (R-TR-TURN-1.2;
  `ux-guidelines.md` visual language, semantic tokens).
- R-TR-UX-2.2 The warning outline SHALL carry a non-color cue (e.g. a dashed/hazard border and a caption)
  so it is perceivable independent of color (R-A11Y-3; `ux-guidelines.md` Differentiate Without Color).

### R-TR-UX-3 — Multi-select and contiguous run drag
**User story:** As a player, I want to select and drag a whole run at once, so rearranging is not tile by
tile.

- R-TR-UX-3.1 TableKit interaction SHALL allow selecting multiple tiles and dragging a **contiguous run**
  as a single unit, in addition to single-tile drag. This SHALL map onto Spec 1's existing single-cards-
  and-stacks drag capability (R-TABLE-3.1) via a Tile Rummy selection model, introducing no new TableKit
  input path; IF the existing drag payload cannot carry an arbitrary multi-tile selection, THEN that is a
  TableKit public-API change requiring an ADR (`Docs/ADR/0003-*.md`) per A-TR-2 (`tech.md` rule 9), to be
  verified before implementation (see `design.md` §11).
- R-TR-UX-3.2 Multi-tile selection and placement SHALL also be reachable by click-to-select-then-place and
  by keyboard (R-TABLE-3.2, R-TABLE-3.4; R-TR-UX-8).

### R-TR-UX-4 — Two-tier rack
**User story:** As a player, I want a staging row separate from my hand, so I can assemble a play before
committing it.

- R-TR-UX-4.1 The rack SHALL present two rows: a lower **main row** for the seat's tiles and an upper
  **staging row** for tiles currently being arranged for the turn.
- R-TR-UX-4.2 Tiles in the staging row SHALL not be committed to the table until placed; ending the turn
  or Reset & Draw SHALL resolve the staging row per R-TR-TURN-2/3/4.

### R-TR-UX-5 — Rack sort toggles
**User story:** As a player, I want the two standard sorts, so I can organize my rack quickly.

- R-TR-UX-5.1 The rack SHALL provide a **"by number"** sort (same-number tiles grouped together) and a
  **"by run"** sort (same-color tiles in ascending number order), as toggle actions.
- R-TR-UX-5.2 Sorting SHALL be a view-only rack arrangement; it SHALL NOT count as placing a tile and
  SHALL NOT affect turn-end gating (R-TR-TURN-2.1).

### R-TR-UX-6 — Color plus symbol on every tile
**User story:** As a color-blind player, I want each color to carry a symbol, so I can tell colors apart
at any size.

- R-TR-UX-6.1 Every tile SHALL render a distinct **symbol** per `TileColor` (red/blue/black/orange) in
  addition to color, visible at every card-size setting **S / M / L / XL** (R-A11Y-3, R-A11Y-4;
  `ux-guidelines.md` Differentiate Without Color).

### R-TR-UX-7 — Illegal attempts spring back, no dialog
**User story:** As a player, I never want an error dialog mid-play, so mistakes stay gentle.

- R-TR-UX-7.1 IF a player attempts an illegal placement (e.g. a color-clashing group, a wrapped run, or
  an initial meld under 30), THEN the tile(s) SHALL spring back with a gentle shake and a short caption
  built from the `RuleViolation` reason (e.g. "Your first meld must total at least 30"); no modal error
  dialog SHALL open (R-TABLE-4.1).

### R-TR-UX-8 — Three input paths and keyboard-only play
**User story:** As every player, including keyboard-only, I want all three input paths, so every action
is reachable.

- R-TR-UX-8.1 Every Tile Rummy action SHALL be reachable via (a) drag and drop (including a contiguous-run
  drag, R-TR-UX-3), (b) click-to-select then click-to-place, and (c) keyboard, with a visible focus
  indicator (R-TABLE-3.1–3.4, R-A11Y-2).
- R-TR-UX-8.2 WHERE a game defines a "smart move," double-click SHALL perform it; Tile Rummy's smart move
  is documented in `design.md` (e.g. auto-extend the selected tile onto the best legal set) (R-TABLE-3.3).

### R-TR-UX-9 — VoiceOver, captions, motion, and sound
**User story:** As a player using assistive tech, I want full narration and settings, so play is fully
accessible.

- R-TR-UX-9.1 Every tile, the pool, each rack row, each table set, and every control SHALL have a
  meaningful VoiceOver label, value, and hint (e.g. "Red 7, staging row, playable"; "Table set: run,
  red 4 to 6, valid") (R-A11Y-1).
- R-TR-UX-9.2 A caption bar SHALL narrate each significant event (deal, initial meld, extension,
  rearrangement, joker reclaimed, Reset & Draw, round end) from the same event stream that drives
  animation, VoiceOver, and sound (R-ENG-8.1; `ux-guidelines.md` table conventions).
- R-TR-UX-9.3 Animations SHALL honor the animation-speed setting and Reduce Motion; AI pacing SHALL be a
  separate setting from animation speed (R-TABLE-5, R-AI-4). Sounds SHALL use randomized variations so
  the same cue never plays twice in a row (R-DS-5.1).
- R-TR-UX-9.4 The rules reference SHALL open in place as an inspector rendered from
  `Docs/Rules/tile-rummy.md` without losing game state (R-APP-3.2).

---

## 6. AI (AI)

### R-TR-AI-1 — Difficulty tiers
**User story:** As a player, I want Easy/Medium/Hard opponents, so difficulty is meaningful.

- R-TR-AI-1.1 Tile Rummy SHALL provide Easy, Medium, and Hard opponents (R-AI-2.1).
- R-TR-AI-1.2 Easy and Medium AI SHALL play the **first legal board extension they find from their own
  rack** (Medium may use a lightly ordered search but SHALL NOT run the full Hard solver); WHEN no legal
  extension exists, they SHALL Reset & Draw (draw the penalty tile) to end the turn (R-TR-TURN-3).
- R-TR-AI-1.3 Hard AI SHALL run a search to choose the play that places the most tiles (or otherwise best
  improves its position per its evaluator) over the multiset of table + rack tiles, respecting the
  initial-meld and validity rules (R-TR-RULES-6, R-TR-TURN-1.2).

### R-TR-AI-2 — Search, time budget, and fallback
**User story:** As a player, I want the Hard AI to be strong yet responsive, so it never blocks play.

- R-TR-AI-2.1 The Hard AI SHALL use an **exact small-scale solver** (an exhaustive/DP/ILP-style
  rearrangement over the multiset of table + rack tiles that maximizes tiles placed) WHEN the board is
  small enough to solve within the time budget, and a **heuristic/beam search** fallback WHEN the board is
  too large to solve exactly within budget; the approach and its fallback are documented in `design.md`.
- R-TR-AI-2.2 A Hard decision SHALL meet the Tile Rummy p95 budget of **≤ 1.5 s** per move, excluding
  cosmetic pacing delay (R-AI-3.3, R-NFR-PERF.4).
- R-TR-AI-2.3 AI decisions SHALL be cancellable, SHALL run off the main actor, and SHALL use an injected
  RNG so AI-vs-AI runs are reproducible (R-AI-1.1, R-AI-3.1, R-AI-3.2).

### R-TR-AI-3 — Hints and coach mode
**User story:** As a learner, I want a suggested move and an explanation, so I can improve.

- R-TR-AI-3.1 Tile Rummy SHALL provide a hint (H) returning a suggested action plus a short plain-language
  reason, and coach mode SHALL reuse the same hint interface (R-AI-6).

---

## 7. Game Definition of Done (DOC)

**User story:** As a product owner, I want Tile Rummy to reach the `product.md` Definition of Done, so it
ships at the same quality bar as every other game.

- R-TR-DOC-1 A canonical rules document SHALL exist at `Docs/Rules/tile-rummy.md` (original writing) that
  lists every option, its default, and presets (Standard / Casual / Tournament), with uncertain rules
  marked **NEEDS REVIEW** (`product.md` DoD; R-NFR-DOC.1).
- R-TR-DOC-2 The rules SHALL be implemented in the engine as a `GameDefinition`, with scenario tests
  traceable to `Docs/Rules/tile-rummy.md` (R-TR-QA-1).
- R-TR-DOC-3 Easy/Medium/Hard opponents SHALL pass the simulation invariants (R-TR-QA-2, R-AI-2.1).
- R-TR-DOC-4 Hints, an interactive tutorial with scripted deals, coach mode, and the in-app rules
  reference SHALL be provided (R-TR-AI-3, R-AI-6; `product.md` DoD).
- R-TR-DOC-5 A declarative table layout, animations, sounds, and captions SHALL exist for every game
  event, with VoiceOver and full keyboard support for every action (R-TR-UX-9, R-TR-UX-8).
- R-TR-DOC-6 Save and resume at any point (including mid-turn with the start-of-turn snapshot),
  statistics, and a catalog registration behind a feature flag SHALL be provided (R-PERS-1, R-APP-4,
  R-APP-1.2).

### R-TR-DOC-7 — Trademark guard
**User story:** As a maintainer, I want the trademarked brand name blocked automatically, so it can never
be merged.

- R-TR-DOC-7.1 A lint-or-test check SHALL fail the build IF the trademarked brand name for this tile-rummy
  family appears anywhere in the repository (source code, identifiers, assets, UI strings, or docs); it
  SHALL be wired into `make lint` and/or the test suite (`product.md` distribution intent — generic names
  for trademarked games; `tech.md` build/tooling).

---

## Non-functional requirements (measurable)

### R-TR-NFR — Tile Rummy non-functional budgets

- R-TR-NFR-1 A Hard AI decision SHALL be **≤ 1.5 s p95** per move, excluding cosmetic pacing delay
  (R-NFR-PERF.4); decisions SHALL be cancellable and off the main actor (R-AI-3.1).
- R-TR-NFR-2 The same seed plus the same action log SHALL produce an identical final state hash on every
  run; a determinism test SHALL prove it for Tile Rummy (R-ENG-4.4, R-QA-2.1).
- R-TR-NFR-3 Line coverage SHALL be **≥ 90%** for the Tile Rummy rules target (R-QA-7.1, R-NFR-PERF is
  separate).
- R-TR-NFR-4 Input-to-visual-feedback SHALL be **≤ 50 ms**, and animation SHALL sustain **≥ 60 fps**
  (targeting 120 fps on ProMotion) including a wide table with many sets during drag (R-NFR-PERF.2,
  R-NFR-PERF.3).
- R-TR-NFR-5 **Piece conservation:** every one of the 106 tiles SHALL be in **exactly one** location — the
  pool, exactly one seat's rack, or the table — at every step; a simulation invariant SHALL assert this
  (R-QA-2.1; R-TR-QA-2). Opponents' racks and the pool SHALL be opaque tokens in a non-owner's view, with
  no correlation to real identities (R-ENG-8.3, R-QA-3).
- R-TR-NFR-6 Engine and rules code SHALL contain no force unwraps or `try!`; rule violations SHALL be
  typed errors with human-readable reasons that drive the spring-back caption (R-NFR-QUAL.1, R-TR-UX-7).
- R-TR-NFR-7 The Tile Rummy rules and AI targets SHALL import only the Swift standard library and
  Foundation (no SwiftUI/AppKit/SpriteKit/Combine), so they stay Linux-portable (`tech.md` rule 1,
  R-BUILD-4.3).
- R-TR-NFR-8 All user-facing Tile Rummy strings SHALL go through String Catalogs (`.xcstrings`), English
  only for now but localizable (R-NFR-QUAL.3).

### R-TR-QA — Quality gates

- R-TR-QA-1 **Scenario tests** (Swift Testing, Given/When/Then), traceable to `Docs/Rules/tile-rummy.md`,
  SHALL cover at least: initial-meld point counting including jokers (R-TR-RULES-6); End Turn validity
  gating (R-TR-TURN-2); voluntary Reset & Draw +1 (R-TR-TURN-3); timer-expiry Reset & Draw +3
  (R-TR-TURN-4); and joker retrieval plus its end-of-round 30-point penalty (R-TR-JOKER-1, R-TR-SCORE-1.2).
- R-TR-QA-2 **Simulation invariants:** `parlor-sim` SHALL run AI-vs-AI and random-legal Tile Rummy games
  and assert every step: **piece conservation** (each of the 106 tiles in exactly one place, R-TR-NFR-5),
  only-legal-actions accepted, bounded length (R-TR-TURN-5.2), scoring consistency, and deterministic
  replay (R-QA-2.1).
- R-TR-QA-3 **AI solver correctness:** a test SHALL run the Hard AI's search/solver on small, hand-crafted
  boards with a **known optimal play** and assert the solver finds it (R-TR-AI-2.1).
- R-TR-QA-4 **View-leak:** the view-leak property test (R-QA-3) SHALL include Tile Rummy, proving a
  non-owner's view never contains a hidden rack tile's or pool tile's identity.
- R-TR-QA-5 **Save/restore round trip:** restoring at random points (including mid-turn) and continuing
  SHALL match an uninterrupted run with the same seeds (R-QA-4.1; the start-of-turn snapshot is part of
  the saved state).

---

## Assumptions

Working assumptions made to avoid guessing; revisable without reopening the spec.

- A-TR-1 **Platform foundation is a prerequisite.** This spec depends on Spec 1
  (`/.kiro/specs/01-platform-foundation/`): `EngineCore` `Tile`/`TileFace` + the `tile-rummy-106`
  `DeckDefinition`, `GameHost`, `PlayerController`, `PlayerView`/redaction, the AIKit toolkit, the generic
  `TableKit` renderer, and the `Makefile` `make build test lint / test-long / sim` contract. **That
  scaffolding is not materialized on this branch**; the build/test contract is treated as the documented
  target from `tech.md` and Spec 1, and every task below is written to end green on `make build test lint`
  once the foundation exists. (Trace: all R-TR-*.)
- A-TR-2 **No EngineCore/TableKit API change is expected.** Tile Rummy is intended to be addable as
  game-specific modules only (Architecture.md "How to add a new game"), reusing existing generic
  `GameEvent` cases (`dealt`, `pieceMoved`, `pieceRevealed`, `scoreChanged`, `handEnded`, `captioned`,
  `turnChanged`). IF an unavoidable public-API change is found, an ADR (`Docs/ADR/0003-*.md`) is required
  (R-NFR-DOC.2); otherwise `design.md` states explicitly that none is required. (Trace: R-TR-RULES-1,
  R-TR-UX-*.)
- A-TR-3 **Joker value in a set is inferred, not stored on the tile.** The value a table joker represents
  is derived from the set it sits in (the single number+color that makes the set legal); it is game
  semantics, not baked into `Tile` (R-ENG-2.3, R-TR-RULES-1.3). (Trace: R-TR-RULES-5, R-TR-JOKER-1.)
- A-TR-4 **Timer is host-scheduled.** The per-turn timer is a host/UI scheduling concern; expiry enters
  the turn loop as an injected action, so rules code never reads wall-clock time (`tech.md` rule 8).
  (Trace: R-TR-TURN-4.4.)
- A-TR-5 **Point values.** A numbered tile is worth its number for both the initial meld and end-of-round
  counting; a table joker is worth the value it represents; a racked joker at round end is +30 against its
  holder (R-TR-SCORE-1.2). The rules doc is the single source of truth. (Trace: R-TR-RULES-6, R-TR-SCORE-1.)
- A-TR-6 **Presets.** Standard / Casual / Tournament presets differ mainly in timer length (Tournament
  timed, Casual no timer) and any enabled house rules; exact preset values are authored in
  `Docs/Rules/tile-rummy.md`. (Trace: R-TR-DOC-1, R-TR-TURN-4.1.)

## Open Questions / NEEDS REVIEW

Items that would otherwise require inventing a rule or product decision. Each is marked NEEDS REVIEW and
must be resolved in `Docs/Rules/tile-rummy.md` before the dependent task is marked complete.

- Q-TR-1 **Joker retrieval — hold vs. use immediately.** After a seat reclaims a table joker by playing
  the exact tile it represented, must the seat use that joker in a set during the **same** turn, or may it
  hold the joker for a later turn? NEEDS REVIEW. (Trace: R-TR-JOKER-1.3.)
- Q-TR-2 **Winner-scoring convention.** Does the winner score a positive total equal to the sum of every
  opponent's remaining rack value while losers score nothing further; or do losers score their own
  remaining total as a negative while the winner scores 0; or does the winner score the positive sum
  **and** each loser scores their own negative total (zero-sum)? More than one variant is common.
  NEEDS REVIEW. (Trace: R-TR-SCORE-2.1.)
- Q-TR-3 **Ace/1 handling.** The number 1 is fixed as the low end of a run and there is no wrap past 13
  (R-TR-RULES-4.2). Confirm there is no "high 1" variant to be offered as a house rule. NEEDS REVIEW.
  (Trace: R-TR-RULES-4.2.)
- Q-TR-4 **Non-playing turn.** When a seat cannot or will not play, does it simply draw exactly **one**
  tile and pass (with no board reset needed because it placed nothing), and is that distinct from the
  voluntary Reset & Draw +1 penalty? NEEDS REVIEW — confirm whether "draw one and pass" and "Reset & Draw
  +1" are the same action. (Trace: R-TR-TURN-2.3, R-TR-TURN-3.1.)
- Q-TR-5 **Jokers per set / count on table.** May a single set contain more than one joker, and is there a
  cap on how many of the 2 jokers may be on the table at once? NEEDS REVIEW. (Trace: R-TR-RULES-5.2.)
- Q-TR-6 **Open-and-rearrange in one turn.** May a seat complete its initial meld and then rearrange
  existing table tiles within the **same** turn, or only from a subsequent turn? NEEDS REVIEW.
  (Trace: R-TR-RULES-7.2, R-TR-RULES-6.4.)
- Q-TR-7 **Valid-but-idle timer expiry.** If the timer expires while the table is valid but the seat
  placed no tile, is the outcome the +1 voluntary Reset & Draw, a no-penalty pass, or the +3 penalty?
  NEEDS REVIEW. (Trace: R-TR-TURN-4.3.)
- Q-TR-8 **Pool exhaustion.** When the pool empties, does the round end immediately and get scored, or
  does play continue (seats may still rearrange the table but cannot draw) until no seat can improve the
  board? NEEDS REVIEW. (Trace: R-TR-TURN-5.1.)
- Q-TR-9 **Initial-meld edge cases.** Confirm the 30-point counting edge cases: a joker in the initial
  meld counts as the value it represents (R-TR-RULES-6.2) — verify there is no cap or special case (e.g.
  a joker representing a 13 counting 13), and that a multi-set opening summing to ≥ 30 is permitted.
  NEEDS REVIEW. (Trace: R-TR-RULES-6.2, R-TR-RULES-6.3.)
