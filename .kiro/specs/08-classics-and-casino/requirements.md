# Requirements — 08 Classics and Casino

## Introduction

This spec rounds out the Parlor catalog (`product.md` roadmap, Spec 8 "Classics and casino") with three
fast-playing classics: **Cribbage** (2-player, head-to-head), **Blackjack** (dealer vs. 1–N seats,
6-deck shoe), and **Video Poker (Jacks or Better)** (single-player, 9/6 pay table). Each game must reach
the **Game Definition of Done** in `product.md`: a canonical rules document, engine rules with traceable
scenario tests, Easy/Medium/Hard AI where the game has opponents, hints (plus coach mode where it makes
sense), an interactive tutorial, the in-app rules reference, a table layout with animations/sounds/
captions for every event, VoiceOver and keyboard support for every action, save/resume, statistics, and a
catalog registration.

Each game is added as **game-specific modules only** — a `GameDefinition`, AI strategies, a table layout,
a rules document, and a catalog registration — following the "How to add a new game" checklist in
`Docs/Architecture.md` and `01-platform-foundation/design.md` §11, with **no changes to `EngineCore` or
`TableKit`** (`tech.md` rule 9). IF any such change proves necessary, THEN an ADR is required (recorded in
`design.md` and flagged in `tasks.md`).

All chips in Blackjack and Video Poker are **play chips with no monetary value** (`product.md` non-goals);
this spec builds no networking, accounts, telemetry, real-money or redeemable wagering, or progressive
jackpots.

### Cross-spec prerequisite (binding)

This spec **requires Spec 6 (`06-poker-room`) to be complete.** Video Poker reuses Spec 6's **5-card poker
hand evaluator**, and both Blackjack and Video Poker reuse Spec 6's **chip and bet-sizing UI components**.
Those components MUST be reused or extended, never duplicated (`tech.md` rule 9 architecture-smell rule).
Because Spec 6 is not yet authored, the exact evaluator and chip/bet UI API shapes are documented as an
**Assumption** (A-1) and their concrete signatures are marked **NEEDS REVIEW** (Q-1, Q-2). See
`design.md` §3 for the reuse contract expressed against the expected interface.

### Binding source documents

The four steering documents are binding and are **not restated** here; requirements trace back to them:

- `product.md` — vision, audience, product principles, roadmap, Definition of Done, non-goals.
- `tech.md` — platform, rendering, architecture rules 1–9, security/privacy, dependencies, build/tooling,
  testing, performance budgets, code conventions.
- `structure.md` — repository layout, enforced dependency direction, conventions.
- `ux.md` — north star, platform, visual language, motion, interaction, table conventions, learning/help,
  accessibility, sound, voice/copy.

The platform-wide capabilities defined in `01-platform-foundation` (EngineCore, AIKit, TableKit,
DesignSystem, Persistence, the app shell, and the quality gates) are assumed present and are reused, not
redefined. Requirement IDs from Spec 1 (`R-ENG-*`, `R-SESS-*`, `R-AI-*`, `R-TABLE-*`, `R-APP-*`,
`R-PERS-*`, `R-A11Y-*`, `R-QA-*`, `R-NFR-*`) are cited where this spec depends on them.

### Terminology

Terms (Seat, Player, Controller, Host, View, Zone, Action, Event, Hand, Match) are used as defined in the
`product.md` Glossary. Game-specific terms (crib, starter, pegging, go, nobs, heels, Muggins, shoe, peek,
insurance, upcard, hard/soft total, hold/draw, pay table) are defined in the respective
`Docs/Rules/<game-id>.md`.

### EARS conventions

Acceptance criteria use EARS keywords: **WHEN** (event), **WHILE** (state), **IF/THEN** (unwanted
condition / decision), **WHERE** (feature is included), and ubiquitous **SHALL**. Each requirement has a
stable ID (`R-<AREA>-<n>`). IDs are referenced by `design.md` and `tasks.md` and must not be renumbered
once merged.

---

## 1. Shared: reuse, structure, and registration

### R-REUSE-1 — Reuse Spec 6's poker hand evaluator (no duplication)
**User story:** As a maintainer, I want Video Poker to rank hands with the same evaluator the poker room
uses, so ranking logic exists in exactly one place and stays consistent.

- R-REUSE-1.1 Video Poker SHALL rank final 5-card hands using Spec 6's 5-card poker hand evaluator; it
  SHALL NOT introduce a second hand-ranking implementation (`tech.md` rule 9).
- R-REUSE-1.2 WHERE the Jacks-or-Better pay table needs a category the evaluator does not already
  distinguish (notably "Jacks or Better" — one pair of rank Jack, Queen, King, or Ace — versus a lower
  pair), Video Poker SHALL derive that distinction from the evaluator's output (rank category plus the
  ranks of the paired cards), NOT by re-ranking the hand.
- R-REUSE-1.3 IF reuse requires a change to the evaluator's public API, THEN that change SHALL be made in
  the Spec 6 evaluator (shared code), an ADR SHALL be written, and no copy SHALL be made in the Casino
  target (`tech.md` rule 9; `structure.md`).

### R-REUSE-2 — Reuse Spec 6's chip and bet-sizing UI (no duplication)
**User story:** As a player, I want chips and bet controls in Blackjack and Video Poker to look and behave
exactly like the poker room's, so the app feels coherent.

- R-REUSE-2.1 Blackjack and Video Poker SHALL present bets, balances, and payouts using Spec 6's chip and
  bet-sizing UI components; they SHALL NOT reimplement chip stacks, chip-to-pot motion, or bet-sizing
  controls.
- R-REUSE-2.2 All chips SHALL be play chips with no monetary value; no component SHALL expose real-money,
  purchase, or redemption affordances (`product.md` non-goals).
- R-REUSE-2.3 IF reuse requires a change to a shared chip/bet UI component's public API, THEN that change
  SHALL be made in the shared component, an ADR SHALL be written, and no copy SHALL be made
  (`tech.md` rule 9).

### R-REUSE-3 — Target and module layout
**User story:** As a maintainer, I want these games placed in the target layout `structure.md` already
names, so the package graph stays predictable.

- R-REUSE-3.1 Cribbage SHALL live in a `Cribbage` rules target with a matching `CribbageUI` target;
  Blackjack and Video Poker SHALL live in the `Casino` rules target with a matching `CasinoUI` target
  (`structure.md` Games list), unless the game-id/target-layout review (Q-3) directs otherwise.
- R-REUSE-3.2 Each game folder SHALL follow the fixed shape `Rules/`, `AI/`, `Layout/`, `Tutorial/`,
  `Tests/` (`structure.md`).
- R-REUSE-3.3 The package graph SHALL match the enforced dependency direction in `structure.md`; the
  Casino/Cribbage rules targets SHALL import only the Swift standard library and Foundation (`tech.md`
  rule 1), and SHALL NOT import SwiftUI/AppKit/SpriteKit/Combine (enforced by lint, R-BUILD-4.3).

### R-REUSE-4 — Stable game IDs and catalog registration
**User story:** As a maintainer, I want stable kebab-case IDs and feature-flagged catalog entries, so
saves/statistics key correctly and unfinished games stay hidden.

- R-REUSE-4.1 The stable game IDs SHALL be `cribbage`, `blackjack`, and `video-poker` (pending Q-3),
  fixed once shipped (`structure.md`).
- R-REUSE-4.2 Each game SHALL register in the catalog behind a feature flag; games not yet built SHALL
  NOT appear in the Library (`R-APP-1.2`).
- R-REUSE-4.3 Each game SHALL supply its `DeckDefinition`(s) and `CardSemantics` as data; no game SHALL
  edit `Card`/`Tile` (`R-ENG-1.3`, `R-ENG-2`). Blackjack SHALL supply a `CardSemantics` that maps 10/J/Q/K
  to a 10-value and Ace to the dual 1/11 handling described in R-BJ-3.

---

## 2. Cribbage

### R-CRIB-1 — Players, deal, and the crib
**User story:** As a Cribbage player, I want a correct 2-player deal with a crib, so the hand starts as it
does on a real board.

- R-CRIB-1.1 Cribbage SHALL support exactly 2 players (the local human plus one opponent); 3/4-handed
  Cribbage is out of scope (`product.md` backlog).
- R-CRIB-1.2 WHEN a hand begins, the dealer SHALL deal 6 cards to each player from a standard 52-card
  deck (`R-ENG-2`).
- R-CRIB-1.3 Each player SHALL discard exactly 2 cards to a shared 4-card **crib** that belongs to the
  dealer; each player SHALL keep a 4-card hand.
- R-CRIB-1.4 WHEN both players have discarded, the non-dealer SHALL cut and the dealer SHALL flip the top
  card of the remaining deck as the **starter**.
- R-CRIB-1.5 IF the starter is a Jack, THEN the dealer SHALL immediately score **2 points for "his
  heels"** (also called "nibs").
- R-CRIB-1.6 The dealer button SHALL rotate to the other player after each hand (`R-ENG-6.2`).
- R-CRIB-1.7 The discard phase SHALL be modeled as a simultaneous phase (both players discard, then
  resolve) (`R-SESS-3.2`), so neither player's discard is revealed to the other before both have
  committed.

### R-CRIB-2 — Pegging (the play)
**User story:** As a Cribbage player, I want correct pegging with all its scoring, so the play phase
scores exactly as at a real table.

- R-CRIB-2.1 WHILE pegging, players SHALL alternate playing one card face up, the non-dealer playing
  first, each announcing the running total; the running total SHALL never exceed 31.
- R-CRIB-2.2 WHEN a played card would take the running total above 31, that card SHALL NOT be playable; a
  player with no card that keeps the total ≤ 31 SHALL say **"go."**
- R-CRIB-2.3 WHEN a play brings the running total to exactly **15**, that play SHALL score **2**.
- R-CRIB-2.4 WHEN the last two cards played form a **pair**, that play SHALL score **2**; three of a kind
  (last three plays same rank) SHALL score **6**; four of a kind SHALL score **12**.
- R-CRIB-2.5 WHEN the most recently played cards form a **run of 3 or more** consecutive ranks, the play
  SHALL score points equal to the run length, regardless of the order in which those cards were played,
  provided no non-consecutive card intervenes.
- R-CRIB-2.6 WHEN a play brings the running total to exactly **31**, that play SHALL score **2**.
- R-CRIB-2.7 WHEN neither player can play and the total is below 31, the last player to have played a card
  SHALL score **1 "for the go."**
- R-CRIB-2.8 WHEN the running total resets (at 31 or after a go), remaining cards SHALL continue to be
  played from a fresh total of 0 until all pegging cards are exhausted.
- R-CRIB-2.9 WHEN a player plays their final pegging card and no reset/go has already awarded it, the last
  card of the entire pegging phase SHALL score **1** (a "last card" / go point) if it did not reach 31.

### R-CRIB-3 — Hand and crib counting
**User story:** As a Cribbage player, I want the show (hand and crib counting) scored exactly, including
the crib's stricter flush rule, so totals are correct.

- R-CRIB-3.1 After pegging, each 4-card hand plus the starter (5 cards) SHALL be scored, in order:
  **non-dealer's hand first, then dealer's hand, then the crib** (dealer counts the crib).
- R-CRIB-3.2 Counting SHALL award: **fifteens** — 2 points per distinct combination of cards summing to
  15 (face cards count 10, Ace counts 1); **pairs** — 2 points per pair (so three of a kind = 6, four of a
  kind = 12); **runs** — points equal to run length, with duplicate ranks multiplying the run (double,
  triple, and double-double runs) per the enumerated table in `Docs/Rules/cribbage.md`.
- R-CRIB-3.3 A **flush** SHALL score **4** if all 4 cards of a hand share a suit, plus **1** more if the
  starter also matches (5-card flush = 5).
- R-CRIB-3.4 For the **crib**, a flush SHALL score **only** when all 5 cards (the crib's 4 cards plus the
  starter) share a suit (5 points); a 4-card-only flush in the crib SHALL score **0** (the hand-vs-crib
  flush distinction).
- R-CRIB-3.5 **"One for his nobs"** SHALL score **1** if the hand (or crib) contains the Jack whose suit
  matches the starter's suit.
- R-CRIB-3.6 The scoring function SHALL be a pure function of (4 kept cards, starter, isCrib) returning a
  total and an itemized breakdown for captions and coaching; it SHALL contain no force unwraps or `try!`
  (`R-NFR-QUAL.1`).

### R-CRIB-4 — Match target, win, and skunks
**User story:** As a Cribbage player, I want the standard 121-point game (or a short 61-point game) and
skunk tracking, so matches end and stats reflect margins.

- R-CRIB-4.1 The match target SHALL default to **121 points**, with a **61-point** game available as an
  option.
- R-CRIB-4.2 WHEN a player reaches or exceeds the target during pegging or counting, the game SHALL end
  immediately (before further counting) and that player SHALL win.
- R-CRIB-4.3 **Skunk** bonuses SHALL be recorded as a documented statistics flag on the hand/match
  outcome, NOT as a different win condition; the exact winning-margin thresholds (single skunk, double
  skunk) SHALL be defined in `Docs/Rules/cribbage.md` and are **NEEDS REVIEW** (Q-4).

### R-CRIB-5 — Manual counting and Muggins (off by default)
**User story:** As a Cribbage player who wants the traditional experience, I want manual counting with
Muggins, so I can claim my own points and be penalized for miscounts.

- R-CRIB-5.1 By default, counting SHALL be **automatic**: the engine computes and awards each hand/crib
  score with no Muggins interaction.
- R-CRIB-5.2 WHERE **Manual Counting** is on, the counting player SHALL state their own count (via a
  keyboard/click entry), and only the stated amount SHALL be pegged.
- R-CRIB-5.3 WHERE Manual Counting is on and the opponent calls **"Muggins,"** the opponent SHALL be
  awarded any points the counting player under-counted (the difference between the correct score and the
  stated score), per the Muggins rule in `Docs/Rules/cribbage.md`.
- R-CRIB-5.4 IF Manual Counting is off, THEN no Muggins affordance SHALL be presented.

### R-CRIB-6 — Peg board and captions
**User story:** As a Cribbage player, I want an animated peg board and clear narration, so I can follow
pegging and counting like on a physical board.

- R-CRIB-6.1 The table SHALL render an animated **peg board** matching a physical board's
  **double-track-per-player** layout (two pegs per player, the rear peg leapfrogging the front on each
  score) (`ux.md` visual language; `ux.md` motion).
- R-CRIB-6.2 WHEN any pegging or counting score occurs, a caption SHALL narrate it (e.g. "Fifteen two,
  and a pair is four") and the peg SHALL animate to the new position (`R-ENG-8.1`, `ux.md` table
  conventions).
- R-CRIB-6.3 A history drawer SHALL show the full hand log, and the table SHALL offer "peek at the last
  play" consistent with `ux.md` table conventions.
- R-CRIB-6.4 WHERE Reduce Motion is on, peg movement SHALL be replaced with a crossfade/step with no loss
  of information (`R-TABLE-5.3`).

### R-CRIB-7 — AI
**User story:** As a Cribbage player, I want opponents that scale from casual to strong, so the game stays
interesting.

- R-CRIB-7.1 Easy AI SHALL discard a reasonable-looking 4-card hand and peg safely (avoid handing obvious
  runs/pairs where cheap to do so).
- R-CRIB-7.2 Medium AI SHALL choose its discard by optimizing the expected value of hand-plus-crib (crib
  value signed for/against depending on whose crib it is) and SHALL peg with limited lookahead.
- R-CRIB-7.3 Hard AI SHALL run a full discard-value search (expected hand-plus-crib value over starter and
  opponent-discard distributions) and stronger pegging.
- R-CRIB-7.4 All AI tiers SHALL see only the redacted `PlayerView` (never the opponent's kept cards or the
  crib before it is turned) (`R-AI-1.1`).
- R-CRIB-7.5 AI decisions SHALL be time-budgeted, cancellable, and run off the main actor (`R-AI-3`); the
  Hard p95 budget for Cribbage is defined in R-NFR-PERF-08 (NEEDS REVIEW, Q-5).

### R-CRIB-8 — Hints, coach, tutorial, rules doc
**User story:** As a learner, I want hints, a coach, a tutorial, and a rules reference, so I can learn
Cribbage in the app.

- R-CRIB-8.1 The game SHALL provide a hint (H) that suggests a discard or a pegging play with a short
  plain-language reason, reusing the AIKit hint interface (`R-AI-6`).
- R-CRIB-8.2 Coach mode SHALL reuse the hint interface to explain the suggested move (`R-AI-6.2`).
- R-CRIB-8.3 The game SHALL provide an interactive tutorial with scripted deals (`product.md` DoD).
- R-CRIB-8.4 `Docs/Rules/cribbage.md` SHALL be authored as original writing listing every option, its
  default, and presets, with uncertain rules (skunk thresholds) marked NEEDS REVIEW (`product.md` DoD;
  `ux.md` voice/copy).

---

## 3. Blackjack

### R-BJ-1 — Table, shoe, and seats
**User story:** As a Blackjack player, I want a dealer, a configurable number of seats, and a 6-deck shoe,
so the table plays like a real one.

- R-BJ-1.1 Blackjack SHALL pit a dealer against a configurable number of player seats; the human plays one
  seat, the others MAY be AI or empty (the seat count and which seats are filled are configured at setup)
  (`R-APP-2.2`).
- R-BJ-1.2 The game SHALL deal from a **6-deck shoe** (312 cards) dealt visually from a shoe
  (`ux.md` motion — deal in the real deal order).
- R-BJ-1.3 The shoe SHALL be **reshuffled at a documented penetration threshold** (a cut-card position);
  the exact threshold SHALL be defined in `Docs/Rules/blackjack.md` (NEEDS REVIEW, Q-6) and SHALL be
  reproducible from the hand seed (`R-ENG-4`).
- R-BJ-1.4 The shoe SHALL be shuffled with the seeded Fisher–Yates from EngineCore; rules code SHALL NOT
  use `Int.random`/`shuffle()` (`R-ENG-4.2`).

### R-BJ-2 — Round flow, peek, and insurance
**User story:** As a Blackjack player, I want correct dealing, dealer peek, and insurance timing, so the
round resolves fairly and unambiguously.

- R-BJ-2.1 WHEN a round begins, each active seat and the dealer SHALL receive two cards; the dealer's
  first card (upcard) SHALL be face up and the second (hole card) face down.
- R-BJ-2.2 WHEN the dealer's upcard is an **Ace**, the game SHALL offer **insurance** to each player
  before resolving the dealer's hole card; insurance SHALL cost up to half the original bet and pay 2:1 if
  the dealer has blackjack.
- R-BJ-2.3 WHEN the dealer shows an **Ace or a 10-value card**, the dealer SHALL **peek** for blackjack;
  insurance (offered on an Ace upcard) SHALL be resolved **before** the peek's result is revealed.
- R-BJ-2.4 IF the dealer has blackjack on the peek, THEN the round SHALL resolve immediately: player
  blackjacks push, other player hands lose, and insurance bets pay 2:1.
- R-BJ-2.5 The exact peek/insurance ordering and edge cases SHALL be documented in
  `Docs/Rules/blackjack.md`; the intended ordering is "insurance offered on Ace upcard, resolved before
  the peek result is revealed" (R-BJ-2.3) and is confirmed there (NEEDS REVIEW, Q-7).
- R-BJ-2.6 IF a player attempts an action that is not legal for the current hand state (e.g. hitting a
  stood hand), THEN the attempt SHALL be rejected with a spring-back and caption, never a modal dialog
  (`R-TABLE-4.1`).

### R-BJ-3 — Player options and totals
**User story:** As a Blackjack player, I want hit/stand/double/split with correct soft-total handling, so
strategy plays out correctly.

- R-BJ-3.1 A player SHALL be able to **hit**, **stand**, **double down**, and (where legal) **split** and
  **take insurance**; card values SHALL be 2–10 at face, J/Q/K = 10, and Ace = 1 or 11 (soft/hard totals)
  chosen to the player's benefit automatically.
- R-BJ-3.2 A two-card 21 SHALL be a **blackjack** (natural), distinct from a multi-card 21.
- R-BJ-3.3 IF a hand's hard total exceeds 21, THEN the hand SHALL **bust** and lose immediately.
- R-BJ-3.4 **Double down** SHALL deal exactly one additional card and double that hand's bet.

### R-BJ-4 — Splitting rules
**User story:** As a Blackjack player, I want standard split rules including DAS and split-Ace
restrictions, so pairs play correctly.

- R-BJ-4.1 A player MAY **split** a two-card pair; splitting SHALL be allowed **up to 3 times (4 total
  hands)**.
- R-BJ-4.2 **Double After Split (DAS)** SHALL be **allowed by default** and available as a toggle.
- R-BJ-4.3 **Re-splitting Aces** SHALL follow the same up-to-3-splits limit as other pairs.
- R-BJ-4.4 **Split Aces** SHALL each receive **exactly one card** with **no further hitting** (and, per
  standard rule and the rules doc, a 21 on a split Ace is **not** a blackjack).
- R-BJ-4.5 The exact pair-matching rule for splitting (e.g. whether any two 10-value cards may be split)
  SHALL be documented in `Docs/Rules/blackjack.md`.

### R-BJ-5 — Dealer rules and payouts
**User story:** As a Blackjack player, I want S17 by default (with an H17 preset) and correct payouts, so
outcomes match a real table.

- R-BJ-5.1 The dealer SHALL **Stand on Soft 17 (S17)** by default, with a **Hit Soft 17 (H17)** preset
  available (`ux.md` learning/help — presets first, one-line explanations).
- R-BJ-5.2 The dealer SHALL draw to a minimum of hard 17 per the S17/H17 setting, then stand.
- R-BJ-5.3 **Blackjack SHALL pay 3:2.**
- R-BJ-5.4 A win SHALL pay 1:1, a push SHALL return the bet, a loss SHALL forfeit the bet, and insurance
  SHALL pay 2:1; payout math SHALL be exact (integer play-chip arithmetic; no rounding that loses chips).
- R-BJ-5.5 WHEN the round resolves, the table SHALL narrate each seat's outcome with a caption and animate
  chips to/from the pot using the reused chip UI (`R-REUSE-2`, `R-ENG-8.1`).

### R-BJ-6 — Coach mode and Hi-Lo trainer (both off by default)
**User story:** As a Blackjack learner, I want optional basic-strategy coaching and a card-counting
trainer that never affects play, so I can practice without changing the game.

- R-BJ-6.1 **Coach mode** SHALL be **off by default**; WHERE on, it SHALL show the basic-strategy-
  recommended action for the current hand as an overlay, reusing the hint interface (`R-AI-6`).
- R-BJ-6.2 **Hi-Lo trainer** SHALL be **off by default**; WHERE on, it SHALL display the running and true
  Hi-Lo count as cards are dealt, purely as a display-only educational overlay.
- R-BJ-6.3 The Hi-Lo trainer SHALL **not** affect betting limits, payouts, shuffle timing, AI, or any
  other gameplay mechanic; a test SHALL assert that enabling it changes no game state or outcome.

### R-BJ-7 — AI
**User story:** As a Blackjack player, I want AI seatmates that play sensibly, so a multi-seat table feels
alive.

- R-BJ-7.1 AI seats SHALL play at Easy/Medium/Hard where a seat is AI-controlled: Easy plays a simple
  fixed policy, Medium plays basic strategy, Hard plays basic strategy accurately for the configured
  S17/H17 and DAS settings.
- R-BJ-7.2 AI SHALL see only the redacted `PlayerView` (the dealer hole card is hidden until revealed)
  (`R-AI-1.1`); AI SHALL NOT use the Hi-Lo count or any hidden information.

### R-BJ-8 — Tutorial, hints, rules doc
- R-BJ-8.1 The game SHALL provide a hint (H) reusing the AIKit hint interface (`R-AI-6.1`) and the coach
  overlay (R-BJ-6.1).
- R-BJ-8.2 The game SHALL provide an interactive tutorial with scripted deals (`product.md` DoD).
- R-BJ-8.3 `Docs/Rules/blackjack.md` SHALL be authored as original writing listing every option, default,
  and preset (S17/H17, DAS, split limits, penetration threshold, peek/insurance timing), with uncertain
  items marked NEEDS REVIEW (Q-6, Q-7) (`product.md` DoD; `ux.md` voice/copy).

---

## 4. Video Poker (Jacks or Better)

### R-VP-1 — Deal, hold/draw, and shoe
**User story:** As a Video Poker player, I want a fresh 52-card deal, a bet of 1–5 credits, and a single
hold-and-draw, so the game plays like a standard machine.

- R-VP-1.1 Video Poker SHALL be single-player against a **freshly shuffled 52-card deck each hand** (a new
  shuffle per hand, seeded per hand — `R-ENG-4.3`).
- R-VP-1.2 The player SHALL wager **1 to 5 credits** before the deal, using the reused chip/bet UI
  (`R-REUSE-2`).
- R-VP-1.3 WHEN the player commits the bet, the game SHALL deal **5 cards face up**.
- R-VP-1.4 The player SHALL **hold or discard each of the 5 cards**, using keys **1–5** (each key toggles
  the hold state of the card in that position) or a click on the card (`ux.md` interaction — keyboard and
  direct manipulation).
- R-VP-1.5 WHEN the player draws, the discarded cards SHALL be replaced from the same 52-card deck
  **exactly once**, and the final hand SHALL then be scored; there SHALL be no second draw.
- R-VP-1.6 WHEN the final hand is scored, the reused chip UI SHALL animate the payout (or loss of the bet)
  (`R-REUSE-2`, `R-ENG-8.1`).

### R-VP-2 — Pay table (9/6 Jacks or Better)
**User story:** As a Video Poker player, I want the exact 9/6 Jacks or Better pay table, so payouts are
correct and the royal-flush max-bet bonus applies.

- R-VP-2.1 The pay table, **per credit bet**, SHALL be exactly:

  | Hand | 1 credit | 5 credits |
  |---|---|---|
  | Royal Flush | 250 | **4,000** (bonus at max bet) |
  | Straight Flush | 50 | 250 |
  | Four of a Kind | 25 | 125 |
  | Full House | 9 | 45 |
  | Flush | 6 | 30 |
  | Straight | 4 | 20 |
  | Three of a Kind | 3 | 15 |
  | Two Pair | 2 | 10 |
  | Jacks or Better (one pair, rank J/Q/K/A only) | 1 | 5 |
  | anything else | 0 | 0 |

- R-VP-2.2 Every payout except the Royal Flush SHALL be linear in the bet (per-credit value × credits
  bet); the **Royal Flush at 5 credits** SHALL pay **4,000** total (the max-bet bonus), not 1,250
  (250 × 5).
- R-VP-2.3 "Jacks or Better" SHALL pay only for a single pair whose rank is **Jack, Queen, King, or Ace**;
  a pair of Tens or lower SHALL pay **0** (unless the hand qualifies for a higher category).
- R-VP-2.4 The pay table SHALL be defined as data and asserted **exactly** by a test (R-QA-VP-1).

### R-VP-3 — Optimal-hold hint (EV-maximizing)
**User story:** As a Video Poker player, I want an on-demand hint that shows the mathematically best hold,
so I can learn and verify optimal play.

- R-VP-3.1 The game SHALL provide an **on-demand optimal-hold hint** triggered by the **H key** or a
  button (`ux.md` — H for hint).
- R-VP-3.2 The hint SHALL show the **expected-value-maximizing hold selection**, computed by
  **exhaustively evaluating all 32 hold/discard subsets** of the current 5-card hand and, for each subset,
  the exact expected return over all possible draws from the remaining deck.
- R-VP-3.3 The hint SHALL rank hands with Spec 6's evaluator (`R-REUSE-1`) and score them with the pay
  table (R-VP-2), so the hint is consistent with actual payouts.
- R-VP-3.4 The hint SHALL be display-only and SHALL NOT auto-hold or change the player's selection; the
  player MAY accept or ignore it.
- R-VP-3.5 The choice between **live computation and a precomputed table**, and the measured performance
  of the hint, SHALL be documented in `design.md` (NEEDS REVIEW where a budget is uncertain, Q-8).

### R-VP-4 — Tutorial, rules doc
- R-VP-4.1 The game SHALL provide an interactive tutorial with scripted deals (`product.md` DoD).
- R-VP-4.2 `Docs/Rules/video-poker.md` SHALL be authored as original writing listing the pay table,
  bet range, hold/draw flow, and the EV-hint behavior (`product.md` DoD; `ux.md` voice/copy).
- R-VP-4.3 Multi-hand/multi-line variants and pay tables other than 9/6 Jacks or Better are out of scope
  (`product.md` non-goals for this spec).

---

## 5. Definition-of-Done coverage (all three games)

### R-DOD-1 — Save/resume, statistics, catalog
**User story:** As a player, I want to save, resume, and track stats for each game, so nothing is lost and
progress is visible.

- R-DOD-1.1 Each game SHALL autosave after every accepted action and resume exactly on relaunch,
  including mid-hand (`R-PERS-1.1`, `R-PERS-1.2`).
- R-DOD-1.2 Each game SHALL record per-game/variant statistics (`R-APP-4.1`): Cribbage (games/matches
  played and won, win %, skunks for/against, average hand and crib points, best hand); Blackjack (hands
  played, net play-chip result, blackjacks, win/push/loss counts); Video Poker (hands played, best hand,
  royal flushes, net play-chip result). Game-specific metrics are defined in each rules doc.
- R-DOD-1.3 Each game SHALL register in the catalog behind a feature flag (`R-REUSE-4.2`).

### R-DOD-2 — Table, animation, sound, captions
- R-DOD-2.1 Each game SHALL have a declarative table layout that obtains deal/move/flip/collect (and, for
  Cribbage, peg and, for Blackjack/Video Poker, chip) animations without custom animation code where the
  existing TableKit primitives suffice (`R-TABLE-1.2`); Cribbage's peg board is the one game-specific
  visual (design.md §5), and chips reuse Spec 6's components (`R-REUSE-2`).
- R-DOD-2.2 Each game event SHALL produce a caption, a sound cue with randomized variation, and a
  VoiceOver announcement (`R-ENG-8.1`, `R-DS-5.1`, `R-A11Y-1`).

### R-DOD-3 — Accessibility
- R-DOD-3.1 Every card, chip, pile, peg, and control SHALL have a meaningful VoiceOver label, value, and
  hint (`R-A11Y-1.1`), including the Cribbage peg board (both pegs and each player's score) and the Video
  Poker hold indicators.
- R-DOD-3.2 Every action in every game SHALL be reachable keyboard-only with a visible focus indicator
  (`R-A11Y-2.1`); Video Poker's keys 1–5 (toggle hold) and H (hint) SHALL work keyboard-only.
- R-DOD-3.3 Suits SHALL carry shapes and a Four-Color deck option SHALL be available (`R-A11Y-3.1`);
  Reduce Motion, Reduce Transparency, Increase Contrast, and card sizes S/M/L/XL SHALL be respected
  (`R-A11Y-4.1`).

---

## 6. Quality gates

### R-QA-CRIB-1 — Cribbage exhaustive scoring verification
**User story:** As a maintainer, I want the Cribbage scorer verified against an independently known fact
about Cribbage, so a scoring bug fails loudly.

- R-QA-CRIB-1.1 A verification test SHALL evaluate the hand-scoring function across **all 12,994,800
  possible (4-card hand + starter) combinations** — every way to choose 5 distinct cards from 52 where one
  is designated the starter — and SHALL assert: the **maximum possible score is 29**, it is achieved by
  **exactly 4 distinct combinations**, and the scores **19, 25, 26, and 27 never occur** for any
  combination.
- R-QA-CRIB-1.2 The verification SHALL be computed against the hand flush rule (R-CRIB-3.3), not the crib
  flush rule, and SHALL exclude "his heels" (a pegging/starter-Jack score, not a hand-count score) and
  "nobs" is included per R-CRIB-3.5 as it is part of hand counting.
- R-QA-CRIB-1.3 IF the full brute-force run is too slow for routine CI, THEN a precomputed **verification
  table** (a checked-in digest/histogram of the score distribution) SHALL be produced by a `Scripts/`
  step and checked in CI, with the full brute-force run gated to `make test-long` (design.md §4; Q-9).
- R-QA-CRIB-1.4 The test SHALL **fail loudly** (not skip) if any asserted fact does not hold.

### R-QA-CRIB-2 — Cribbage scenario tests
- R-QA-CRIB-2.1 Given/When/Then scenario tests SHALL cover **every pegging score** (fifteen, pair, triple,
  quad, run of 3/4/5/6/7, thirty-one, go, last card), **heels** (starter Jack → dealer 2), **nobs**
  (Jack matching starter suit → 1), the **hand-vs-crib flush distinction** (4-card flush scores in a hand
  but not in the crib), and **Muggins** (opponent claims under-counted points when Manual Counting is on),
  each traceable to `Docs/Rules/cribbage.md` (`R-QA-1.1`).

### R-QA-BJ-1 — Blackjack scenario tests
- R-QA-BJ-1.1 Given/When/Then scenario tests SHALL cover: **S17 and H17** dealer behavior; **peek and
  insurance timing** (insurance resolved before peek result revealed); **DAS** (double allowed after
  split when on, blocked when off); **split limits** (up to 3 splits / 4 hands); **split-Ace restrictions**
  (one card each, no further hits, split-Ace 21 not a blackjack); and **payout math** (blackjack 3:2,
  insurance 2:1, pushes return the bet, integer chip conservation), each traceable to
  `Docs/Rules/blackjack.md` (`R-QA-1.1`).

### R-QA-VP-1 — Video Poker pay-table and EV-hint tests
- R-QA-VP-1.1 A test SHALL assert the **pay table exactly** as specified in R-VP-2, including the Royal
  Flush 5-credit bonus (4,000) and the Jacks-or-Better rank restriction.
- R-QA-VP-1.2 A test SHALL confirm the **optimal-hold hint matches an independent brute-force
  expected-value calculation** on a sample of hands: for each sampled dealt hand, the hint's chosen hold
  SHALL equal the EV-maximizing hold computed by an independent reference implementation (ties resolved by
  a documented deterministic rule).

### R-QA-SIM-1 — Simulation invariants (all three games)
- R-QA-SIM-1.1 `parlor-sim` SHALL run each game headlessly and check invariants every step: **shoe/deck
  conservation** (every card in exactly one place; Blackjack's 312-card shoe and Video Poker's 52-card
  deck never gain or lose a card across a hand); only-legal-actions accepted; games/hands end within a
  bounded number of actions; scoring/payout consistency (chips conserved); and **deterministic replay**
  (seed + action log → identical final state hash) (`R-QA-2.1`).
- R-QA-SIM-1.2 `make test` SHALL run the fast sample volume and `make test-long` the full volume per game
  (`R-QA-2.2`).

### R-QA-VIEW-1 — View-leak and save/restore
- R-QA-VIEW-1.1 The view-leak property test (`R-QA-3.1`) SHALL cover Cribbage (opponent hand + crib hidden
  before turn), Blackjack (dealer hole card hidden until reveal), and Video Poker (no hidden opponent, but
  undrawn deck order SHALL not leak).
- R-QA-VIEW-1.2 Save/restore round trips (`R-QA-4.1`) SHALL cover all three games at random action
  indices.

### R-QA-COV-1 — Coverage
- R-QA-COV-1.1 Line coverage SHALL be **≥ 90%** for the Cribbage and Casino rules targets (`R-QA-7.1`,
  `tech.md` testing).

---

## Non-functional requirements (measurable)

### R-NFR-PERF-08 — Performance budgets for these games
These inherit `tech.md` / `R-NFR-PERF` and add game-specific budgets:

- R-NFR-PERF-08.1 Starting any of the three games SHALL be ≤ 300 ms and all animation SHALL sustain ≥ 60
  fps (`R-NFR-PERF.1`, `R-NFR-PERF.2`).
- R-NFR-PERF-08.2 **Cribbage** Hard AI decision (discard search) SHALL meet a p95 budget; the proposed
  budget is **≤ 1.0 s** per decision (the general `tech.md` budget). This budget is **NEEDS REVIEW** (Q-5)
  because a full discard-value search over starter and opponent-discard distributions may need the poker/
  Tile-Rummy-style **≤ 1.5 s** allowance; the chosen value SHALL be recorded in `design.md`.
- R-NFR-PERF-08.3 **Video Poker** optimal-hold hint (32-subset exhaustive EV) SHALL return within an
  interactive budget; the proposed budget is **≤ 200 ms** for a live computation on the M1 baseline. This
  budget and the live-vs-precomputed choice are **NEEDS REVIEW** (Q-8) and SHALL be recorded in
  `design.md` with measured data.
- R-NFR-PERF-08.4 **Blackjack** AI (basic strategy) is table-lookup fast and SHALL be well under the
  `tech.md` budget; no special allowance is needed.

### R-NFR-QUAL-08 — Code quality (from `tech.md`)
- R-NFR-QUAL-08.1 Cribbage and Casino rules code SHALL contain no force unwraps or `try!`; rule violations
  SHALL be typed errors with human-readable reasons (`R-NFR-QUAL.1`).
- R-NFR-QUAL-08.2 All user-facing strings SHALL go through String Catalogs (`.xcstrings`) (`R-NFR-QUAL.3`).

### R-NFR-DEP-08 — Dependencies
- R-NFR-DEP-08.1 No new runtime dependency SHALL be introduced; these games use only EngineCore, AIKit,
  TableKit, DesignSystem, and Spec 6's shared evaluator/UI (`R-NFR-DEP.1`). Anything else requires an ADR.

### R-NFR-DOC-08 — Documentation upkeep
- R-NFR-DOC-08.1 `Docs/Architecture.md` and the relevant `Docs/Rules/*.md` SHALL be updated in the same
  task that changes behavior (`R-NFR-DOC.1`).
- R-NFR-DOC-08.2 ADRs SHALL be written for new dependencies, changes to EngineCore/TableKit public APIs,
  changes to Spec 6's shared evaluator/chip-UI public APIs, rendering-approach changes, and save-format
  changes (`R-NFR-DOC.2`, `R-REUSE-1.3`, `R-REUSE-2.3`).

---

## Assumptions

Working assumptions made to avoid guessing; revisable without reopening the whole spec.

- A-1 **Spec 6 is complete and provides the reusable pieces.** `06-poker-room` ships (a) a pure 5-card
  poker hand evaluator in a shared location reachable by the Casino rules target (a rules/EngineCore-level
  target, not a UI target), returning at least a hand category and the ranks needed to distinguish
  Jacks-or-Better, and (b) chip and bet-sizing UI components in a shared UI location reachable by
  `CasinoUI`/`CribbageUI`. The precise module location, type names, and signatures are **NEEDS REVIEW**
  (Q-1, Q-2) pending Spec 6. (Trace: R-REUSE-1, R-REUSE-2.)
- A-2 **Target layout.** Cribbage → `Packages/Games/Cribbage` (+`CribbageUI`); Blackjack + Video Poker →
  `Packages/Games/Casino` (+`CasinoUI`), matching the `structure.md` Games list. Confirmed unless Q-3
  directs otherwise. (Trace: R-REUSE-3.)
- A-3 **Game IDs** are `cribbage`, `blackjack`, `video-poker` (kebab-case, stable). (Trace: R-REUSE-4.1.)
- A-4 **Standard 52 deck for Cribbage and Video Poker**, and a **6-deck (312-card) shoe for Blackjack**,
  supplied as `DeckDefinition`s with composition tests; Blackjack's shoe is a 6× standard-52 multiset with
  distinct `PieceID`s per physical card (`R-ENG-1.2`). (Trace: R-CRIB-1.2, R-BJ-1.2, R-VP-1.1.)
- A-5 **Cribbage counting order and totals** follow standard 2-hand Cribbage; `Docs/Rules/cribbage.md` is
  the single source of truth for the run-multiplier table and the exact scoring phrasing (original
  writing). (Trace: R-CRIB-3.)
- A-6 **Blackjack default rule set**: 6 decks, S17, DAS on, split to 4 hands, split Aces one card, 3:2
  blackjack, insurance 2:1. Presets (e.g. "Vegas Strip"-style vs a house preset) are named in the rules
  doc; the penetration threshold and exact peek/insurance edge cases are Q-6/Q-7. (Trace: R-BJ-*.)
- A-7 **Video Poker EV-hint reference.** The brute-force reference used by R-QA-VP-1.2 is an independent,
  simpler (possibly slower) implementation living in the test target, distinct from the shipping hint, so
  the test cannot pass by comparing the code to itself. (Trace: R-VP-3, R-QA-VP-1.2.)
- A-8 **Exhaustive Cribbage verification cost.** ~13M combinations × a fast scorer is expected to run in
  seconds-to-low-minutes; if it exceeds the fast-test budget it moves to `make test-long` with a
  checked-in verification table guarding `make test` (design.md §4). (Trace: R-QA-CRIB-1.)

## Open Questions / NEEDS REVIEW

Each is marked NEEDS REVIEW and must be resolved before the dependent task is implemented.

- Q-1 **Spec 6 evaluator API shape.** Exact module, type name, and method signature of the 5-card poker
  hand evaluator, and whether it already exposes the paired-rank detail needed for Jacks-or-Better. NEEDS
  REVIEW pending Spec 6. IF the needed detail is absent, a shared-API change + ADR is required
  (R-REUSE-1.3). (Trace: R-REUSE-1, A-1.)
- Q-2 **Spec 6 chip/bet UI API shape.** Exact components, their public props/callbacks (bet amount,
  balance, chip-to-pot animation hooks), and their module location for reuse by `CasinoUI`/`CribbageUI`.
  NEEDS REVIEW pending Spec 6. (Trace: R-REUSE-2, A-1.)
- Q-3 **Game IDs and target layout confirmation.** Confirm `cribbage`/`blackjack`/`video-poker` IDs and
  the Cribbage-own-family / Casino-shared-family placement (vs. e.g. `jacks-or-better` as the Video Poker
  id). NEEDS REVIEW. (Trace: R-REUSE-3.1, R-REUSE-4.1, A-2, A-3.)
- Q-4 **Cribbage skunk thresholds.** Exact winning-margin thresholds for single skunk and double skunk
  (commonly a loser under 91 = skunk and under 61 = double skunk in a 121-game, but confirm) and whether
  they only affect statistics. NEEDS REVIEW before authoring `Docs/Rules/cribbage.md` §Skunks.
  (Trace: R-CRIB-4.3.)
- Q-5 **Cribbage Hard AI budget.** Confirm the Hard discard-search p95 budget: general ≤ 1.0 s vs. a
  ≤ 1.5 s allowance if a full expected-value search over starter/opponent distributions needs it. NEEDS
  REVIEW; record the chosen value in `design.md`. (Trace: R-CRIB-7.5, R-NFR-PERF-08.2.)
- Q-6 **Blackjack penetration threshold.** Exact cut-card position / penetration fraction that triggers a
  reshuffle of the shoe. NEEDS REVIEW before authoring `Docs/Rules/blackjack.md`. (Trace: R-BJ-1.3.)
- Q-7 **Blackjack peek/insurance timing confirmation.** Confirm the exact ordering and edge cases:
  insurance offered on an Ace upcard and resolved before the peek result is revealed; dealer peeks on Ace
  or 10-value; behavior when the human has a blackjack vs a peeked dealer blackjack (push). NEEDS REVIEW.
  (Trace: R-BJ-2.3, R-BJ-2.5.)
- Q-8 **Video Poker EV-hint compute approach.** Confirm live 32-subset computation vs a precomputed table,
  and the measured/target latency budget (proposed ≤ 200 ms live). NEEDS REVIEW; record measured data in
  `design.md`. (Trace: R-VP-3.5, R-NFR-PERF-08.3.)
- Q-9 **Cribbage verification-run placement.** Confirm whether the full ~13M brute-force run is fast enough
  for `make test` or must be gated to `make test-long` behind a checked-in verification table. NEEDS
  REVIEW; record the decision in `design.md` §4. (Trace: R-QA-CRIB-1.3, A-8.)
