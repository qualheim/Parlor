# Requirements — 02 Solitaire Collection

## Introduction

This spec extends **Parlor** with four new single-player solitaire games — **Spider**, **FreeCell**,
**Pyramid**, and **TriPeaks** — and a shared **solver** that powers real hints, provably winnable deals,
and a per-game **Daily Deal**. It also **retrofits Klondike** (built in Spec 1) with the same
solver-backed features. Every game in this spec must reach the `product.md` **Game Definition of Done**
(with the "Easy/Medium/Hard opponents" clause interpreted as **N/A** for these solo games, since they
have no opponents — hints, coach mode, tutorial, rules reference, layout/animation/sound/captions,
VoiceOver + keyboard, save/resume, statistics, and catalog registration all still apply).

Each new game is added by writing **game-specific modules only** — a `GameDefinition`, a table layout,
a rules document, tests, and a catalog registration — following the nine-step "How to add a new game"
checklist in `Docs/Architecture.md`, with **no changes to `EngineCore` or `TableKit` public APIs** unless
an ADR is written first (`tech.md` architecture rule 9; `structure.md`).

### Binding source documents

The four steering documents are binding and are **not restated** here; requirements trace back to them:

- `product.md` — vision, audience, product principles, roadmap, Definition of Done, non-goals.
- `tech.md` — platform, rendering, architecture rules 1–9, security/privacy, dependencies, build/tooling,
  testing, performance budgets, code conventions.
- `structure.md` — repository layout, enforced dependency direction, conventions.
- `ux-guidelines.md` — north star, platform, visual language, motion, interaction, table conventions,
  learning/help, accessibility, sound, voice/copy.

### Prior spec

This spec **reuses** `EngineCore`, `AIKit`, and `TableKit` as they stand after Spec 1
(`.kiro/specs/01-platform-foundation/`) and does not redefine their capabilities. In particular it relies
on: `Card`/`Tile` with unique `PieceID` identity (R-ENG-1); `DeckDefinition` data including the
`spider-104` double deck (R-ENG-2.2); zones with visibility policy (R-ENG-3); the seeded PRNG
(SplitMix64 → xoshiro256\*\*) and our Fisher–Yates shuffle (R-ENG-4; ADR 0002); the `GameDefinition`
protocol (R-ENG-5); the `GameHost` actor as sole mutator (R-SESS-1); the `PlayerController` async seam
(R-SESS-2); the `Codable`/`Sendable`/schema-versioned host boundary (R-ENG-8.5); the action log and
`Match` model (R-ENG-6, R-ENG-7); view redaction and opaque tokens (R-ENG-8); the AIKit hint interface
returning a suggested action plus a plain-language reason (R-AI-6); TableKit's generic renderer, input
paths, animation queue, and HUD (R-TABLE-\*); statistics (R-APP-4); and the `parlor-sim` invariant harness
(R-QA-2). This spec **retrofits Klondike** (id `klondike`, built in Spec 1, R-KLON-\*) rather than
rebuilding it; Spec 1 IDs are **referenced, never renumbered or restated**.

WHERE this spec would otherwise require a change to an `EngineCore` or `TableKit` public API (for example,
to host the solver or a new zone shape), that change SHALL be treated as an architecture smell and an ADR
SHALL be written before the change (per `tech.md` rule 9; ADR numbering continues at 0003+).

### Terminology

Terms (Seat, Player, Controller, Host, View, Zone, Action, Event, Hand, Match) are used as defined in the
`product.md` Glossary. **Solitaire-specific terms:** *tableau* (the play columns/piles), *stock* (the
undealt draw pile), *waste* (discards turned from the stock), *foundation* (the ordered build-up pile),
*free cell* (a single-card holding slot in FreeCell), *supermove* (moving a multi-card sequence in one
gesture, enabled by free cells and empty columns), *exposed* card (a card free to be played per that
game's rules), *current card* (TriPeaks' active waste card), *run* (a same-suit descending sequence in
Spider), *redeal* (recycling the waste back through the stock), and *deal number* (an integer that,
together with the numbering scheme, deterministically produces a specific starting layout).

### EARS conventions

Acceptance criteria use EARS keywords: **WHEN** (event), **WHILE** (state), **IF/THEN** (unwanted
condition / decision), **WHERE** (feature is included), and ubiquitous **SHALL**. Each requirement has a
stable ID (`R-<area>-<n>.<m>`). IDs are referenced by `design.md` and `tasks.md` and must not be
renumbered once merged. Spec-2 IDs use **new area prefixes** (`R-SPIDER`, `R-FREECELL`, `R-PYR`,
`R-TRIP`, `R-SOLVER`, `R-WINNABLE`, `R-DAILY`, `R-KLON2`, `R-STATS2`, `R-QA2`, `R-NFR-SOLVER`) and a fresh
`A2-*` / `Q2-*` namespace for Assumptions and Open Questions, so no Spec-1 ID is reused.

---

## 1. Integration and Definition of Done

### R-SETUP2-1 — New games plug in without engine changes
**User story:** As a maintainer, I want the four new games added as game-specific modules only, so the
enforced dependency direction and future multiplayer readiness are preserved.

- R-SETUP2-1.1 Each new game (`spider`, `freecell`, `pyramid`, `tri-peaks`) SHALL be added by following
  the nine-step "How to add a new game" checklist in `Docs/Architecture.md` (conform to `GameDefinition`,
  supply deck semantics, layout, rules doc, catalog registration, tests, tutorial, doc update).
- R-SETUP2-1.2 Each new game SHALL register in the catalog behind a feature flag; a game not yet complete
  SHALL NOT appear in the Library (per `product.md` roadmap; implements R-APP-1.2).
- R-SETUP2-1.3 IF adding any game or the solver would require a change to an `EngineCore` or `TableKit`
  public API, THEN an ADR SHALL be written before that change (per `tech.md` rule 9; R-NFR-DOC.2).
- R-SETUP2-1.4 Each new game SHALL meet the `product.md` Game Definition of Done, with the
  "Easy/Medium/Hard opponents" clause treated as **N/A** because these games are solo; all other DoD
  items (canonical rules doc, scenario tests traceable to it, hints + coach + tutorial + rules reference,
  layout/animation/sound/captions, VoiceOver + keyboard, save/resume, statistics, catalog registration)
  SHALL apply.
- R-SETUP2-1.5 Each new game SHALL use stable kebab-case ids `spider`, `freecell`, `pyramid`,
  `tri-peaks`; these ids SHALL NOT change once shipped (per `structure.md` conventions).
- R-SETUP2-1.6 Each new game SHALL author a canonical rules document at `Docs/Rules/<game-id>.md` in
  original prose (per `ux-guidelines.md` voice); every uncertain rule SHALL be marked NEEDS REVIEW there
  and mirrored in this spec's Open Questions.

---

## 2. Spider

### R-SPIDER-1 — Deck, suits, and deal
**User story:** As a Spider player, I want the standard double-deck deal with a selectable suit count, so
I can play my preferred difficulty.

- R-SPIDER-1.1 Spider SHALL always be dealt from two 52-card decks (104 cards total) regardless of suit
  count, reusing the `spider-104` `DeckDefinition` (R-ENG-2.2).
- R-SPIDER-1.2 The suit-count option SHALL be **1 suit**, **2 suits** (default), or **4 suits**; WHERE
  fewer than 4 suits are selected, the 104 cards SHALL still be present but composed of the reduced suit
  set (for example, 2 suits = eight copies of two suits) so the total is always 104.
- R-SPIDER-1.3 The deal SHALL create 10 tableau columns: the first 4 columns SHALL hold 6 cards each and
  the last 6 columns SHALL hold 5 cards each (54 cards dealt), with the top card of each column face up
  and the rest face down.
- R-SPIDER-1.4 The remaining 50 cards SHALL form the stock.
- R-SPIDER-1.5 There SHALL be no separate foundations; completed runs are removed from the tableau
  (see R-SPIDER-3).

### R-SPIDER-2 — Moves and sequences
**User story:** As a Spider player, I want correct building and multi-card moves, so the tableau plays as
expected.

- R-SPIDER-2.1 Any card MAY be placed on a tableau card whose rank is exactly one higher, regardless of
  suit.
- R-SPIDER-2.2 Only a **same-suit descending sequence** SHALL be movable as a single unit; a mixed-suit
  descending sequence MAY sit on the tableau but its cards SHALL be moved individually.
- R-SPIDER-2.3 An empty tableau column MAY receive any single card or any same-suit descending sequence.
- R-SPIDER-2.4 WHEN a face-down card becomes the new top of a column, it SHALL flip face up automatically
  (auto-flip).

### R-SPIDER-3 — Completed runs
**User story:** As a Spider player, I want completed suits to clear automatically, so progress is
obvious.

- R-SPIDER-3.1 WHEN a complete same-suit descending run from King down to Ace forms on a tableau column,
  it SHALL auto-collect (be removed) off the tableau as a unit.
- R-SPIDER-3.2 WHEN all 8 runs (104 cards) have been collected, the game SHALL be won.

### R-SPIDER-4 — Dealing from the stock
**User story:** As a Spider player, I want the standard "deal 10" behavior, so pacing matches the classic
game.

- R-SPIDER-4.1 WHEN the player clicks the stock, exactly one card SHALL be dealt face up onto each of the
  10 columns (10 cards per deal), consuming the stock in 5 deals.
- R-SPIDER-4.2 By default, IF any tableau column is empty, THEN dealing from the stock SHALL be refused
  with a gentle spring-back and a caption (no modal error; per `ux-guidelines.md`).
- R-SPIDER-4.3 WHERE the "allow dealing onto empty columns" option is on, R-SPIDER-4.2 SHALL NOT apply and
  a deal SHALL proceed even with empty columns. This option SHALL default off.

### R-SPIDER-5 — Scoring and options
**User story:** As a Spider player, I want the classic scoring plus a timer-only mode, so I can play for
score or just for fun.

- R-SPIDER-5.1 Scoring SHALL start at 500, subtract 1 per move, and add 100 per completed 13-card run.
- R-SPIDER-5.2 The scoring option SHALL be **Standard** (per R-SPIDER-5.1, default) or **No scoring,
  timer only**.
- R-SPIDER-5.3 The exact definition of a "move" for scoring purposes and any minimum-score floor SHALL be
  documented in `Docs/Rules/spider.md` (see Q2-1).

---

## 3. FreeCell

### R-FREECELL-1 — Deal and board
**User story:** As a FreeCell player, I want the standard 8-column deal with free cells and foundations,
so the game plays as expected.

- R-FREECELL-1.1 FreeCell SHALL deal a standard 52-card deck into 8 tableau columns: four columns holding
  7 cards and four holding 6 cards, all face up.
- R-FREECELL-1.2 The board SHALL provide 4 free cells (each holding at most one card) and 4 foundations.
- R-FREECELL-1.3 Foundations SHALL build up by suit from Ace to King; tableau columns SHALL build down in
  alternating colors.
- R-FREECELL-1.4 An empty tableau column MAY receive any single card or any legal movable sequence
  (subject to supermove capacity, R-FREECELL-2).
- R-FREECELL-1.5 WHEN all 52 cards reach the foundations, the game SHALL be won.

### R-FREECELL-2 — Supermove
**User story:** As a FreeCell player, I want to move a valid sequence in one gesture up to the capacity my
free cells and empty columns allow, so play is fluid.

- R-FREECELL-2.1 WHERE the supermove option is on (default on), moving a sequence of **N** cards in one
  gesture SHALL be legal when **N ≤ (freeCells + 1) × 2^(emptyColumns)**, where `freeCells` is the number
  of empty free cells and `emptyColumns` is the number of empty tableau columns.
- R-FREECELL-2.2 WHEN the destination of a supermove is itself an empty column, that destination column
  SHALL NOT count toward `emptyColumns`, which functionally halves the capacity for moves into an empty
  column.
- R-FREECELL-2.3 IF the requested sequence length exceeds the computed capacity, THEN the move SHALL be
  refused with a spring-back and a caption explaining the capacity (no modal error; per
  `ux-guidelines.md`).
- R-FREECELL-2.4 WHERE the supermove option is off, only single-card moves (and moves to/from free cells)
  SHALL be permitted; a multi-card sequence SHALL be moved one card at a time.
- R-FREECELL-2.5 The supermove SHALL be presented as direct manipulation, click-to-place, and keyboard,
  and SHALL animate as a coordinated multi-card move (per R-TABLE-3, R-TABLE-5).

### R-FREECELL-3 — Safe autoplay to foundations
**User story:** As a FreeCell player, I want automatic safe moves to the foundations, so I don't have to
click obvious plays.

- R-FREECELL-3.1 Safe autoplay to foundations SHALL be on by default and SHALL use the **exact same
  "Safe" definition** as Klondike's auto-move (Spec 1 R-KLON-3.2); it SHALL NOT be redefined here.
- R-FREECELL-3.2 The autoplay option SHALL be **Off / Safe only (default) / Always**, matching Klondike's
  three-way option (R-KLON-3.2).

### R-FREECELL-4 — Deal numbering
**User story:** As a FreeCell player, I want to play numbered deals, including the classic Microsoft
deals, so I can reproduce and share layouts.

- R-FREECELL-4.1 FreeCell SHALL support a **Parlor numbering** mode over deal numbers **1–1,000,000**
  that seeds the engine PRNG (R-ENG-4) so the same deal number reproduces the same layout on any machine.
- R-FREECELL-4.2 WHERE the **Microsoft numbering** mode is selected, deal numbers **1–32,000** SHALL
  reproduce the classic Microsoft FreeCell deals exactly, using the documented linear-congruential
  algorithm (LCG constants 214013 and 2531011; `rand = (state >> 16) & 0x7FFF`; deck initialized in the
  order A♣…K♣, A♦…K♦, A♥…K♥, A♠…K♠; repeatedly draw `idx = rand % cardsLeft`, deal that card using
  swap-with-last removal, dealing round-robin into the 8 columns). The exact step-by-step algorithm SHALL
  be specified in `design.md` and mirrored in `Docs/Rules/freecell.md`.
- R-FREECELL-4.3 The Microsoft numbering mode SHALL reproduce, byte-for-byte in dealt card order, at
  least deals **#1**, one arbitrary mid-range deal, and **#11982**; these SHALL be named regression cases
  (implements R-QA2-2.3).
- R-FREECELL-4.4 Microsoft deal **#11982** is the famously **unsolvable** deal; the bundled solver
  (section 6) SHALL classify it as **unsolvable**, and this SHALL be a named regression case
  (R-QA2-3.3).
- R-FREECELL-4.5 The game SHALL support restarting the same deal and a "Play deal #…" entry point for
  both numbering modes (parallels R-KLON-3.7).

---

## 4. Pyramid

### R-PYR-1 — Layout and deal
**User story:** As a Pyramid player, I want the standard 28-card pyramid over a stock, so the game plays
as expected.

- R-PYR-1.1 The deal SHALL place 28 cards into a pyramid of 7 rows holding 1, 2, 3, 4, 5, 6, and 7 cards
  respectively, with each card overlapping the two cards below it.
- R-PYR-1.2 The remaining 24 cards SHALL form the stock, with the waste initially empty.
- R-PYR-1.3 A pyramid card SHALL be **exposed** (playable) only once both cards below it in the pyramid
  have been removed; the 7 cards in the bottom row start exposed.

### R-PYR-2 — Removals
**User story:** As a Pyramid player, I want to remove cards summing to thirteen, so the pyramid clears
correctly.

- R-PYR-2.1 Card values SHALL be Ace = 1, pip cards = face value, Jack = 11, Queen = 12, King = 13.
- R-PYR-2.2 An exposed King (value 13) SHALL be removable alone.
- R-PYR-2.3 Any two exposed cards whose values sum to 13 SHALL be removable together
  (Q+A, J+2, 10+3, 9+4, 8+5, 7+6).
- R-PYR-2.4 An exposed pyramid card MAY be paired with the current waste top card or with the current
  stock/waste card, subject to the same sum-to-13 rule; the precise set of eligible partners (pyramid,
  waste top, stock top) SHALL be documented in `Docs/Rules/pyramid.md` (see Q2-2).
- R-PYR-2.5 WHEN both cards below a pyramid card are removed, that card SHALL become exposed.

### R-PYR-3 — Stock, waste, and redeals
**User story:** As a Pyramid player, I want to draw from the stock and recycle it a limited number of
times, so the standard flow works.

- R-PYR-3.1 WHEN the player draws from the stock, one card SHALL move face up to the waste and become
  eligible for pairing.
- R-PYR-3.2 The redeal option SHALL be **0, 1, 2 (default), or unlimited**; a redeal recycles the waste
  back through the stock.
- R-PYR-3.3 The exact redeal mechanic (whole waste reshuffled versus recycled in the same order) SHALL be
  documented in `Docs/Rules/pyramid.md` (see Q2-3).

### R-PYR-4 — Win and scoring
**User story:** As a Pyramid player, I want a clear win condition and a documented score, so results are
meaningful.

- R-PYR-4.1 WHEN all 28 pyramid cards have been removed, the game SHALL be won.
- R-PYR-4.2 WHEN no legal removal or draw remains and no redeal is available, the game SHALL detect the
  loss and offer undo, restart, or a new game (no modal error; inline banner per `ux-guidelines.md`).
- R-PYR-4.3 Scoring SHALL be by cards remaining and/or time; the exact formula SHALL be documented in
  `Docs/Rules/pyramid.md` (see Q2-4).

---

## 5. TriPeaks

### R-TRIP-1 — Layout and deal
**User story:** As a TriPeaks player, I want the three-peaks layout over a stock, so the game plays as
expected.

- R-TRIP-1.1 The deal SHALL place 28 cards into three overlapping peaks arranged in rows of 3, 6, 9, and
  10 cards (top to bottom), with each higher card overlapping the two cards below it.
- R-TRIP-1.2 The remaining 24 cards SHALL form the stock; 1 card SHALL be turned face up as the starting
  **current card**, leaving 23 cards to draw.
- R-TRIP-1.3 A peak card SHALL be **exposed** (playable) only once both cards overlapping it from below
  have been removed; the 10 cards in the bottom row start exposed.

### R-TRIP-2 — Play
**User story:** As a TriPeaks player, I want to build runs up or down from the current card, so the peaks
clear.

- R-TRIP-2.1 An exposed card MAY be played onto the current card when its rank is exactly one higher or
  one lower than the current card, regardless of suit; the played card then becomes the new current card.
- R-TRIP-2.2 WHERE the King–Ace wrap option is on (default on), Ace and King SHALL be treated as adjacent
  (King ↔ Ace) for the one-rank rule; WHERE it is off, no wrap SHALL apply.
- R-TRIP-2.3 WHEN a peak card's two lower neighbors are both removed, that peak card SHALL become exposed.
- R-TRIP-2.4 WHEN all 28 peak cards have been removed, the game SHALL be won.

### R-TRIP-3 — Stock and end of game
**User story:** As a TriPeaks player, I want to draw a new current card when stuck, so play continues
until truly blocked.

- R-TRIP-3.1 WHEN the player draws from the stock, one card SHALL turn face up and become the new current
  card, and any active streak SHALL reset (see R-TRIP-4).
- R-TRIP-3.2 WHEN the stock is empty and no exposed card is playable, the game SHALL end (loss if any
  peak cards remain).

### R-TRIP-4 — Streak scoring
**User story:** As a TriPeaks player, I want streak-based scoring, so long chains are rewarded.

- R-TRIP-4.1 WHILE the player makes consecutive plays without drawing, the per-card bonus SHALL increase
  with the streak length.
- R-TRIP-4.2 WHEN the player draws from the stock, the streak SHALL reset to zero.
- R-TRIP-4.3 The game SHALL track the **longest streak** for statistics (see R-STATS2-1).
- R-TRIP-4.4 The exact streak bonus schedule and any base per-card and peak-clear bonuses SHALL be
  documented in `Docs/Rules/tri-peaks.md` (see Q2-5).

---

## 6. Shared solver

### R-SOLVER-1 — Solver service and classification
**User story:** As a learner and as a deal generator, I want a service that can tell whether a deal is
winnable, so hints and winnable-deal pools are trustworthy.

- R-SOLVER-1.1 The spec SHALL provide a solver **service** that, given a game deal (initial state) and a
  search budget, classifies it as **winnable**, **unwinnable**, or **unknown** (budget exhausted / timed
  out).
- R-SOLVER-1.2 The solver SHALL support Klondike, FreeCell, Spider (at least 1-suit and 2-suit), Pyramid,
  and TriPeaks. WHERE 4-suit Spider is included, its coverage and expected timeout rate SHALL be
  documented (see Q2-6).
- R-SOLVER-1.3 WHEN a deal is classified **winnable**, the solver SHALL be able to return a winning line
  (a sequence of actions) or at least a **best next move** for the current position.
- R-SOLVER-1.4 The solver SHALL be **deterministic**: given the same deal and the same budget, it SHALL
  return the same classification and (where applicable) the same best move on every run.

### R-SOLVER-2 — Placement and purity
**User story:** As an architect, I want the solver in the pure layer, so rules targets, AIKit, the
simulation CLI, and generation scripts can all reuse it and it stays Linux-portable.

- R-SOLVER-2.1 The solver SHALL live in the **pure layer** (Swift standard library and Foundation only,
  no Apple-only UI frameworks), so it is usable by rules targets, AIKit, `SimulationCLI`, and `Scripts/`
  seed-pool generation, and stays portable to a future Linux server (per `tech.md` rule 1).
- R-SOLVER-2.2 The solver's placement — inside `AIKit` or in a new pure package (for example
  `Packages/SolverKit`) — SHALL be **decided and documented in `design.md`**; IF a new package is
  introduced, THEN it SHALL slot into the enforced dependency direction and `Docs/Architecture.md` SHALL
  be updated in the same task (R-NFR-DOC.1; see Q2-7).
- R-SOLVER-2.3 The solver SHALL be usable both interactively (for a single-position hint) and in bulk
  (for offline/background winnable-deal generation).

### R-SOLVER-3 — Search and correctness
**User story:** As a fairness and quality owner, I want the solver's answers proven correct on small
cases, so its classifications can be trusted at scale.

- R-SOLVER-3.1 The solver's algorithm and data structures (search strategy, state encoding/canonicalization,
  transposition/visited detection, move ordering, and the budget model) SHALL be specified in `design.md`
  precisely enough to implement without guessing.
- R-SOLVER-3.2 The solver SHALL be cross-checked against exhaustive search on a set of small,
  brute-forceable deals; a **winnable** classification SHALL never be returned for a provably unwinnable
  deal, and an **unwinnable** classification SHALL never be returned for a provably winnable deal
  (implements R-QA2-3.1).
- R-SOLVER-3.3 A solver run SHALL be cancellable and SHALL run off the main actor when invoked for an
  interactive hint (consistent with R-AI-3.1, R-NFR-PERF.4).

---

## 7. Winnable deals and Daily Deal

### R-WINNABLE-1 — Winnable-deal pools
**User story:** As a player who dislikes dead-end deals, I want a "winnable only" option, so I only face
deals that can be won.

- R-WINNABLE-1.1 For each game — and for each Spider suit-count variant (1, 2, and 4 suits) — a bundled
  pool of **at least 10,000 solver-confirmed winnable deals** SHALL be produced.
- R-WINNABLE-1.2 The pools SHALL be generated by a script in `Scripts/` that uses the solver (R-SOLVER)
  to confirm each entry, and SHALL be either checked into the repo or generated once and cached at build
  time; the choice SHALL be documented in `design.md` (see Q2-8).
- R-WINNABLE-1.3 A pool entry SHALL be stored as a compact, deterministic deal identifier (for example a
  seed or deal number) rather than a full board, so a pool is small and a deal is regenerated
  reproducibly (R-ENG-4).
- R-WINNABLE-1.4 A **"Winnable deals only"** game-setup option SHALL, WHEN on, draw the starting deal
  from the appropriate pool instead of a fully random shuffle; it SHALL default off.
- R-WINNABLE-1.5 WHERE "Winnable deals only" is on for Spider, the pool for the currently selected suit
  count SHALL be used.

### R-DAILY-1 — Daily Deal
**User story:** As a returning player, I want one shared daily puzzle per game, so I have a reason to come
back — without any network.

- R-DAILY-1.1 Each game SHALL offer a **Daily Deal**: a deterministic deal chosen from that game's
  winnable pool using the **local calendar date** as the seed, so the same date on the same machine
  yields the same deal, with **no network and no server** (per `product.md` principle 3; `tech.md`).
- R-DAILY-1.2 The mapping from local date to a pool index SHALL be deterministic and documented in
  `design.md`; the exact date→index mapping SHALL be marked NEEDS REVIEW (see Q2-9).
- R-DAILY-1.3 The Daily Deal SHALL always be a winnable deal (drawn from the pool of R-WINNABLE-1).
- R-DAILY-1.4 The Daily Deal SHALL be reachable from the Library and/or the game setup sheet as a
  distinct entry (per `ux-guidelines.md` learning/help layout).
- R-DAILY-1.5 The Daily Deal SHALL read the local calendar date only; rules code SHALL NOT read
  wall-clock time (per `tech.md` rule 8) — the date is supplied to the host as configuration, not read
  inside the rules.

---

## 8. Klondike retrofit

### R-KLON2-1 — Solver-backed hints
**User story:** As a Klondike player, I want hints that know whether my position is still winnable, so I
can decide whether to keep going.

- R-KLON2-1.1 Klondike SHALL add **solver-backed hints** that classify the current position as
  **winnable**, **unknown**, or **unwinnable** (via R-SOLVER), reported through the existing hint
  interface (R-AI-6) with a plain-language reason.
- R-KLON2-1.2 WHEN the position is classified winnable and a best move is known, the hint SHALL surface
  that **best move** (R-SOLVER-1.3).
- R-KLON2-1.3 The solver-backed hints SHALL be provided **alongside** the Spec 1 heuristic hints
  (R-KLON-3.5), not as a replacement; the heuristic path SHALL remain available (for example as a fast
  fallback WHEN the solver returns unknown within budget).
- R-KLON2-1.4 These changes SHALL NOT renumber or restate Spec 1 R-KLON-\* requirements; they extend
  Klondike's feature set only.

### R-KLON2-2 — Winnable deals and Daily Deal for Klondike
**User story:** As a Klondike player, I want the same winnable-only and Daily Deal options as the new
games, so Klondike is a first-class member of the collection.

- R-KLON2-2.1 Klondike SHALL add a **"Winnable deals only"** setup option drawing from a Klondike
  winnable pool (R-WINNABLE-1), defaulting off.
- R-KLON2-2.2 Klondike SHALL add a **Daily Deal** (R-DAILY-1) using the Klondike winnable pool.
- R-KLON2-2.3 The Klondike winnable pool and Daily Deal SHALL respect Klondike's option variants (for
  example Draw 1 vs Draw 3) as documented in `design.md` (see Q2-10).

---

## 9. Statistics

### R-STATS2-1 — Extended statistics for all five solitaires
**User story:** As a player, I want statistics across all my solitaire games, including a daily streak,
so I can track progress.

- R-STATS2-1.1 Statistics (Spec 1 R-APP-4, not restated) SHALL be extended to cover all five solitaire
  games and their variants: `klondike`, `spider` (per suit count), `freecell`, `pyramid`, and
  `tri-peaks`.
- R-STATS2-1.2 Each game SHALL track a **Daily Deal streak** (consecutive days the Daily Deal was won),
  including current and best streak, alongside the standard R-APP-4.1 metrics.
- R-STATS2-1.3 Game-specific metrics SHALL include at least: Spider completed runs and suit count played;
  FreeCell numbering mode and deal number; Pyramid cards cleared; and TriPeaks longest streak
  (R-TRIP-4.3).
- R-STATS2-1.4 Statistics SHALL continue to be visualized with Swift Charts and reset only after
  confirmation (implements R-APP-4.2, R-APP-4.3).

---

## 10. Quality gates

### R-QA2-1 — Scenario tests for every rule and option
**User story:** As a maintainer, I want every new rule and option covered by a traceable test, so
correctness is provable.

- R-QA2-1.1 Every rule and option in `Docs/Rules/{spider,freecell,pyramid,tri-peaks}.md` and the
  Klondike retrofit SHALL have a Given/When/Then scenario test traceable to that document (per
  `product.md` Definition of Done; parallels R-QA-1.1).
- R-QA2-1.2 FreeCell supermove capacity (R-FREECELL-2.1, R-FREECELL-2.2) SHALL have scenario tests **at
  its boundary values**, including moves that are exactly at capacity, one over capacity, and moves into
  an empty destination column (where the destination does not count).
- R-QA2-1.3 Spider run auto-collection (R-SPIDER-3.1), same-suit-only unit moves (R-SPIDER-2.2), and the
  empty-column deal rule and its option (R-SPIDER-4.2, R-SPIDER-4.3) SHALL each have scenario tests.
- R-QA2-1.4 Pyramid sum-to-13 pairs and King-alone removal (R-PYR-2), exposure rules (R-PYR-1.3,
  R-PYR-2.5), and each redeal setting (R-PYR-3.2) SHALL have scenario tests.
- R-QA2-1.5 TriPeaks one-rank up/down play with wrap on and off (R-TRIP-2.1, R-TRIP-2.2), exposure
  (R-TRIP-2.3), and streak reset on draw (R-TRIP-4.2) SHALL have scenario tests.

### R-QA2-2 — Microsoft numbering conformance
**User story:** As a FreeCell player, I want the classic deals reproduced exactly, so shared deal numbers
match everyone else's.

- R-QA2-2.1 A conformance test SHALL assert that Microsoft numbering (R-FREECELL-4.2) produces the exact
  documented dealt card order.
- R-QA2-2.2 The conformance test SHALL cover deal **#1**, at least one arbitrary mid-range deal, and deal
  **#11982**, each producing the exact documented card order (implements R-FREECELL-4.3).
- R-QA2-2.3 The Parlor numbering mode (R-FREECELL-4.1) SHALL have a determinism test (same deal number →
  same layout across runs).

### R-QA2-3 — Solver correctness and the #11982 regression
**User story:** As a quality owner, I want the solver proven correct and the famous unsolvable deal
locked in, so classifications stay trustworthy.

- R-QA2-3.1 Solver correctness SHALL be cross-checked against exhaustive search on a set of small,
  brute-forceable deals for each supported game (implements R-SOLVER-3.2).
- R-QA2-3.2 A determinism test SHALL assert the solver returns identical classification and best move for
  the same deal and budget across runs (implements R-SOLVER-1.4).
- R-QA2-3.3 A named regression test SHALL assert the solver classifies Microsoft FreeCell deal **#11982**
  as **unsolvable** (implements R-FREECELL-4.4).

### R-QA2-4 — Simulation invariants
**User story:** As a maintainer, I want the sim harness to cover the new games at the Spec 1 volumes, so
regressions surface early.

- R-QA2-4.1 `parlor-sim` SHALL run each new game and each Spider suit-count variant with the Spec 1
  invariants (R-QA-2.1): piece conservation, only legal actions accepted, bounded termination, scoring
  consistency, and deterministic replay.
- R-QA2-4.2 `make test` SHALL run **500 games per game/variant**; `make test-long` SHALL run **10,000
  games per game/variant** (matches R-QA-2.2).

### R-QA2-5 — UI and determinism tests
**User story:** As a player relying on keyboard or on daily reproducibility, I want each game winnable by
keyboard and the winnable/daily selection deterministic, so the experience is complete and fair.

- R-QA2-5.1 UI tests SHALL win one deal of each new game (`spider`, `freecell`, `pyramid`, `tri-peaks`)
  via **drag** and, separately, via **keyboard only** (parallels R-QA-5, R-A11Y-5).
- R-QA2-5.2 UI (or integration) tests SHALL verify that, given a fixed date/seed, the **"Winnable deals
  only"** selection (R-WINNABLE-1.4) and the **Daily Deal** selection (R-DAILY-1) are **deterministic**
  (same date/seed → same deal).

### R-QA2-6 — Coverage
- R-QA2-6.1 Line coverage SHALL be at least 90% for each new rules target and for the solver (per
  `tech.md` testing; parallels R-QA-7.1).

---

## Non-functional requirements (measurable)

Spec 1 non-functional requirements (`R-NFR-PERF`, `R-NFR-QUAL`, `R-NFR-DEP`, `R-NFR-DOC`) continue to
apply and are **not restated**. This section adds only what is new.

### R-NFR-SOLVER — Solver budgets (baseline: M1 MacBook Air, release build)
- R-NFR-SOLVER.1 **Interactive hint path:** a solver-backed hint for the current position SHALL return
  within a bounded wall-clock budget of **≤ 1.0 s p95** per request, running off the main actor and
  cancellable (consistent with R-NFR-PERF.4, R-AI-3.1). IF the budget is exhausted, THEN the solver SHALL
  return **unknown** and the UI SHALL fall back to the heuristic hint (R-KLON2-1.3). The exact interactive
  budget default is NEEDS REVIEW (see Q2-11).
- R-NFR-SOLVER.2 **Offline/background generation path:** the solver SHALL support a larger per-deal budget
  suitable for winnable-deal generation, expressed as a node/iteration cap and/or a wall-clock cap; the
  concrete default caps are NEEDS REVIEW (see Q2-11).
- R-NFR-SOLVER.3 The solver's classification of a given deal at a given budget SHALL be reproducible
  (R-SOLVER-1.4); reproducibility SHALL NOT depend on wall-clock timing (a timeout SHALL be modeled as a
  deterministic node/iteration cap, not solely as elapsed real time, so results are stable across runs;
  see Q2-11).
- R-NFR-SOLVER.4 **Pool generation cost:** generating each pool of ≥ 10,000 winnable deals SHALL fit an
  offline/build-time budget documented in `design.md`; the pool storage footprint SHALL stay small by
  storing deal identifiers rather than full boards (R-WINNABLE-1.3). Concrete time/space targets are
  NEEDS REVIEW (see Q2-8, Q2-11).
- R-NFR-SOLVER.5 Starting any game (including from a winnable pool or Daily Deal) SHALL still meet the
  Spec 1 start-a-game budget (≤ 300 ms, R-NFR-PERF.1); winnable/daily selection SHALL therefore be a
  cheap pool lookup, not an at-launch solve.

---

## Assumptions

These are working assumptions made to avoid guessing at rules; they can be revised without reopening the
whole spec. Each cites the requirement(s) it supports.

- A2-1 **Game ids.** The stable kebab-case ids are `spider`, `freecell`, `pyramid`, and `tri-peaks`;
  `tri-peaks` (hyphenated) is chosen over `tripeaks`. (Trace: R-SETUP2-1.5; see Q2-13.)
- A2-2 **Spider composition.** Reduced-suit Spider still totals 104 cards by repeating the selected suits
  (2 suits = eight copies of two suits; 1 suit = sixteen copies of one suit), reusing `spider-104`.
  (Trace: R-SPIDER-1.1, R-SPIDER-1.2.)
- A2-3 **Spider default suit count** is 2 suits. (Trace: R-SPIDER-1.2.)
- A2-4 **Microsoft LCG constants** are 214013 (multiplier) and 2531011 (increment) over a 32-bit state,
  with `rand = (state >> 16) & 0x7FFF`, deck order clubs→diamonds→hearts→spades (A..K within each), and
  swap-with-last removal dealing round-robin into 8 columns — this is the documented algorithm.
  (Trace: R-FREECELL-4.2.)
- A2-5 **FreeCell Safe autoplay** reuses Klondike's exact Spec 1 "Safe" definition (R-KLON-3.2) with no
  changes. (Trace: R-FREECELL-3.1.)
- A2-6 **Pool size** is exactly 10,000 winnable deals per game and per Spider suit-count variant (a floor,
  not a cap). (Trace: R-WINNABLE-1.1.)
- A2-7 **Pool entries store deal identifiers** (seeds / deal numbers), not full boards, so a pool is small
  and each deal is regenerated deterministically via R-ENG-4. (Trace: R-WINNABLE-1.3.)
- A2-8 **Daily Deal seed** is derived from the local calendar date (year-month-day), mapped through a
  documented function to an index into the game's winnable pool; the date is passed to the host as config,
  not read inside the rules. (Trace: R-DAILY-1.1, R-DAILY-1.5.)
- A2-9 **Solver algorithm family** is a bounded depth-first / best-first search with state
  canonicalization and a transposition (visited) table, tuned per game; the exact strategy is an
  implementation choice fixed in `design.md`. (Trace: R-SOLVER-3.1.)
- A2-10 **Solver timeout is a deterministic node/iteration cap** (not solely elapsed real time) so
  classifications are reproducible across machines and runs. (Trace: R-SOLVER-1.4, R-NFR-SOLVER.3.)
- A2-11 **Solver placement** is expected to be a new pure package `Packages/SolverKit` in the AIKit tier
  (stdlib + Foundation only); this is finalized in `design.md`. (Trace: R-SOLVER-2.2; see Q2-7.)

## Open Questions / NEEDS REVIEW

Items that would otherwise require inventing a rule or a product decision. Each is marked NEEDS REVIEW and
must be resolved before the corresponding task is implemented.

- Q2-1 **Spider "move" definition and score floor** — does a single card, a unit sequence move, or a
  stock deal each count as one move for the −1 penalty, and is there a minimum-score floor? NEEDS REVIEW.
  (Trace: R-SPIDER-5.1, R-SPIDER-5.3.)
- Q2-2 **Pyramid eligible pairing partners** — may an exposed pyramid card pair with the waste top and/or
  the stock top, or only with another exposed pyramid card plus the waste? NEEDS REVIEW.
  (Trace: R-PYR-2.4.)
- Q2-3 **Pyramid redeal mechanic** — on redeal, is the waste reshuffled or recycled in the same order,
  and does the pyramid remain untouched? NEEDS REVIEW. (Trace: R-PYR-3.2, R-PYR-3.3.)
- Q2-4 **Pyramid scoring formula** — the exact points for cards remaining and/or time, and any bonus for
  clearing in fewer redeals. NEEDS REVIEW before authoring `Docs/Rules/pyramid.md` §Scoring.
  (Trace: R-PYR-4.3.)
- Q2-5 **TriPeaks streak bonus schedule** — the exact per-card base value, the streak multiplier curve,
  and any per-peak-clear bonus. NEEDS REVIEW before authoring `Docs/Rules/tri-peaks.md` §Scoring.
  (Trace: R-TRIP-4.4.)
- Q2-6 **4-suit Spider solver coverage** — is 4-suit Spider fully supported by the solver, or supported
  with a documented higher timeout/unknown rate? NEEDS REVIEW. (Trace: R-SOLVER-1.2, R-WINNABLE-1.1.)
- Q2-7 **Solver placement** — `AIKit` vs a new pure package (for example `Packages/SolverKit`), and the
  resulting `Docs/Architecture.md` dependency-diagram update. NEEDS REVIEW; finalize in `design.md`.
  (Trace: R-SOLVER-2.2, A2-11.)
- Q2-8 **Pools checked in vs cached at build time** — are the ≥ 10,000-deal pools committed to the repo
  or generated once and cached during the build, and what is the acceptable repo/build footprint? NEEDS
  REVIEW. (Trace: R-WINNABLE-1.2, R-NFR-SOLVER.4.)
- Q2-9 **Daily Deal date→index mapping** — the exact function from local date to pool index (for example
  days-since-epoch modulo pool size, or a hashed date), and behavior when the pool grows between builds
  (so a past date keeps its deal). NEEDS REVIEW. (Trace: R-DAILY-1.2, A2-8.)
- Q2-10 **Klondike winnable pool granularity** — is there one Klondike pool or separate pools per option
  variant (Draw 1 vs Draw 3, scoring, passes), and which variant the Daily Deal uses? NEEDS REVIEW.
  (Trace: R-KLON2-2.3.)
- Q2-11 **Solver budget defaults** — the concrete interactive p95 budget, the offline/generation node and
  wall-clock caps, and pool-generation time/space targets. NEEDS REVIEW. (Trace: R-NFR-SOLVER.1,
  R-NFR-SOLVER.2, R-NFR-SOLVER.4.)
- Q2-12 **Spider "allow dealing onto empty columns" scope** — is the option purely about the stock deal
  (R-SPIDER-4.3), and does it interact with scoring or winnability of pool deals? NEEDS REVIEW.
  (Trace: R-SPIDER-4.3.)
- Q2-13 **Id spelling** — confirm `tri-peaks` (hyphenated) as the stable id rather than `tripeaks`; the
  id is unchangeable once shipped. NEEDS REVIEW. (Trace: R-SETUP2-1.5, A2-1.)
- Q2-14 **Microsoft deal card-order tie-breaks** — if any published reference is ambiguous about the
  starting deck orientation or column fill order, the algorithm in `design.md` (A2-4) is authoritative;
  confirm it against the #1, mid-range, and #11982 fixtures. NEEDS REVIEW. (Trace: R-FREECELL-4.2,
  R-QA2-2.2.)
