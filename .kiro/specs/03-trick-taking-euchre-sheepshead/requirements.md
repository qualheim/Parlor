# Requirements — 03 Trick-Taking I (Euchre & Sheepshead)

## Introduction

This spec builds a **reusable trick-taking core** on top of the platform foundation (Spec 01) and proves
it with two partnership trick games with trump: **Euchre** (`euchre`, 4-handed, fixed partners) and
**Sheepshead** (`sheepshead`, 5-handed Called Ace). The core is designed as a **stable contract**: Spec 07
(Hearts, Spades) must reuse it **without modifying it**. Getting the trump/effective-suit, partnership,
void-tracking, and bidding/declaration abstractions right is therefore the primary goal of this spec.

The trick-taking core is a **new, reusable rules module** that plugs into `EngineCore`, `AIKit`, and
`TableKit` **as they stand** (Spec 01 `design.md` defines their public surface). Per `tech.md` architecture
rule 9 and `Docs/Architecture.md` "How to add a new game," a game (or shared game-family core) must be
game-specific modules only. **IF** the core or either game would require a change to the public API of
`EngineCore` or `TableKit`, **THEN** that is an architecture smell and an ADR is required (§Assumptions;
`structure.md`). This spec anticipates two such needs and records them in ADR 0003 (see §12 and
`Docs/ADR/0003-trick-taking-core.md`).

Both games must reach the **Game Definition of Done** (`product.md`): a canonical rules document, rules in
the engine with traceable scenario tests, Easy/Medium/Hard opponents passing simulation invariants, hints
and coach mode, an interactive tutorial, an in-app rules reference, a table layout with animations, sounds,
and captions for every event, full VoiceOver and keyboard support, save/resume at any point, statistics,
and a registered catalog entry.

### Binding source documents

The four steering documents are binding and are **not restated** here; requirements trace back to them:

- `product.md` — vision, principles, roadmap (Euchre/Sheepshead are Spec 3; Hearts/Spades are Spec 7),
  Definition of Done, non-goals.
- `tech.md` — platform, rendering, architecture rules 1–9, determinism, performance budgets, testing,
  `make` targets, code conventions.
- `structure.md` — repository layout, enforced dependency direction, per-game folder shape (`Rules/`,
  `AI/`, `Layout/`, `Tutorial/`, `Tests/`), stable kebab-case game IDs.
- `ux-guidelines.md` — trick-taking table conventions, caption bar, "peek at last trick," motion,
  accessibility.

### Foundation dependency

This spec **reuses** the Spec 01 public surface without change unless an ADR says otherwise: `Card`,
`CardFace`, `Suit`, `Rank`, `PieceID`, `DeckDefinition`, `CardSemantics`/`TrumpContext`, `Zone`/`ZoneID`/
`Visibility`, `SeededRNG`/`Shuffle` (ADR 0002), `GameDefinition`, `GameEvent`, `Viewer`/`ViewToken`/
`PlayerView`, `GameHost`, `PlayerController`/`AIController`/`LocalHumanController`, `Transport`, `Match`/
`LogEntry`/`UndoPolicy`, and the AIKit toolkit (`DeterminizationSampler`, `MonteCarlo`, `ISMCTS`,
`Evaluator`, personas, pacing, hint interface). Requirement IDs from Spec 01 are cited as `01:R-…`.

### Terminology

Terms (Seat, Player, Controller, Host, View, Zone, Action, Event, Hand, Match) are used as defined in the
`product.md` Glossary. Additional trick-taking terms: **trick** (one card per active seat, won by the
highest-ranking card by trick order), **trump** (the suit whose cards beat all non-trump), **effective
suit** (the suit a card counts as for following, which trump can change — e.g. Euchre's left bower),
**effective trick-rank** (a card's rank for the purpose of winning a trick under the active trump),
**bower** (Euchre: right bower = Jack of trump; left bower = Jack of the same-color suit), **picker**
(Sheepshead: the player who takes the blind and makes trump), **partner** (the picker's secret ally),
**blind** (Sheepshead: 2 cards set aside), **bury** (Sheepshead: cards the picker sets aside face down as
their points), **void** (a seat is void in an effective suit when it has failed to follow it).

### EARS conventions

Acceptance criteria use EARS keywords: **WHEN** (event), **WHILE** (state), **IF/THEN** (unwanted
condition / decision), **WHERE** (feature/option is included), and ubiquitous **SHALL**. Each requirement
has a stable ID (`R-<AREA>-<n>`) with `.<m>` sub-criteria. IDs are referenced by `design.md` and `tasks.md`
and must not be renumbered once merged.

---

## 1. Reusable trick-taking core (TrickTaking module)

### R-TT-1 — Effective suit and effective trick-rank resolution
**User story:** As a rules author, I want a card's suit-for-following and trick-rank to be resolved against
the active trump, so trump-shifting cards (like Euchre's left bower) behave correctly without editing
`Card`.

- R-TT-1.1 The core SHALL define a `TrickContext` (active trump if any, the led effective suit if a card
  has been led, and the game's trump/rank scheme) and SHALL resolve, for any `CardFace`, its **effective
  suit** and **effective trick-rank** in that context, layered over `CardSemantics` (`01:R-ENG-2.3`); it
  SHALL NOT bake rank/suit into `Card`/`CardFace` (`01:R-ENG-1.3`).
- R-TT-1.2 WHERE a card's printed suit differs from its effective suit under trump (e.g. the left bower),
  the core SHALL treat it as a card of its **effective** suit for both following and winning, never as a
  card of its printed suit.
- R-TT-1.3 WHEN comparing two cards played to a trick, the core SHALL rank a trump above any non-trump, and
  among trump SHALL use the game-supplied trump order; among non-trump it SHALL rank a card of the led
  effective suit above any off-suit card, and off-suit cards SHALL never win.
- R-TT-1.4 The core SHALL compute the set of **legal plays** for a seat given its hand and the led
  effective suit: WHILE a seat holds at least one card of the led effective suit, that seat SHALL be
  required to follow suit; otherwise any card SHALL be legal (subject to per-game rules).
- R-TT-1.5 IF a seat attempts a play that does not follow the led effective suit while able to, THEN the
  core SHALL return a typed `RuleViolation` whose reason names the required suit (e.g. "You must follow
  suit — you have a heart"), feeding the spring-back caption (`01:R-TABLE-4.1`).

### R-TT-2 — Trick lifecycle
**User story:** As a rules author, I want a standard trick lifecycle, so lead/follow/winner/collection are
consistent across games.

- R-TT-2.1 The core SHALL model a trick as an ordered set of (seat, card) plays with a designated leader,
  and SHALL determine the leader of the next trick as the winner of the current one.
- R-TT-2.2 WHEN every active seat has played to a trick, the core SHALL determine the winner by R-TT-1.3
  and SHALL emit a `trickWon(by:)` event (`01:R-ENG-8.1`) plus the per-card move descriptors needed for
  collection animation.
- R-TT-2.3 The core SHALL support 1–9 seats and a configurable number of active seats per hand (e.g. a
  Euchre loner sits a partner out), independent of the physical seat count.
- R-TT-2.4 The core SHALL expose the completed tricks of the current hand so the UI can offer "peek at
  last trick" (`ux-guidelines.md`; R-UX-3.3).

### R-TT-3 — Partnerships
**User story:** As a rules author, I want a partnership model covering fixed pairs and dynamically
determined partners, so both Euchre and Sheepshead (and later Spades) fit one abstraction.

- R-TT-3.1 The core SHALL define a `Partnership` abstraction that maps each active seat to a **side** for
  the purpose of combining trick counts and points.
- R-TT-3.2 WHERE a game uses fixed partnerships (Euchre), the core SHALL support statically defined sides
  (2 v 2) for the whole match.
- R-TT-3.3 WHERE a game determines the partner during the hand (Sheepshead Called Ace), the core SHALL
  support a **hidden partnership** in which one seat is the picker's secret partner, the partner's identity
  is redacted from other viewers until revealed, and a reveal event binds the partner when the triggering
  card is played (`01:R-ENG-8.4`).
- R-TT-3.4 WHERE a game allows a lone declarer (Euchre "going alone"; Sheepshead picker with no partner),
  the core SHALL support a side of one, and side scoring SHALL adjust accordingly (R-EUC-5, R-SHP-6).
- R-TT-3.5 The `Partnership` for a hand SHALL be part of authoritative state and SHALL be redacted per
  viewer so that a hidden partner's identity is never leaked before its reveal (verified by the view-leak
  test, `01:R-QA-3`).

### R-TT-4 — Void / card tracking
**User story:** As an AI author and as a learner, I want the engine to record which effective suits each
seat has failed to follow, so AI can infer holdings and the UI can explain "why can't I play this."

- R-TT-4.1 WHEN a seat fails to follow the led effective suit (plays off-suit while the trick had a led
  suit), the core SHALL record that the seat is **void** in that effective suit for the remainder of the
  hand, in authoritative state.
- R-TT-4.2 The recorded voids SHALL be exposed to a seat's own AI **only** as public, observation-derived
  facts (things any seat at the table could deduce from the played cards), never as hidden holdings
  (`product.md` fair-play principle 2; `01:R-AI-1.1`).
- R-TT-4.3 The `DeterminizationSampler` (`01:R-AI-2.2`) SHALL consume recorded voids so sampled hidden
  hands never assign a seat a card of a suit it is known to be void in.
- R-TT-4.4 The core SHALL provide, for any illegal play attempt, a machine-readable explanation (which suit
  must be followed and why) that the UI turns into a "Why can't I play this?" caption (R-TT-1.5;
  `01:R-TABLE-3.5`).

### R-TT-5 — Bidding / declaration framework
**User story:** As a rules author, I want a reusable bidding/declaration framework, so Euchre's two-round
order-up and Sheepshead's pick/pass both fit and Spec 7 can add its own auctions without core changes.

- R-TT-5.1 The core SHALL define an `Auction`/declaration phase abstraction that presents, in turn order, a
  game-supplied set of legal declarations to each seat (e.g. order up, pass, name suit, pick), collects
  responses, and terminates by a game-supplied rule.
- R-TT-5.2 The framework SHALL support **turn-ordered** bidding (each seat in sequence, as in Euchre and
  Sheepshead) and SHALL expose the current bid state as part of the redacted view so the UI and AI see the
  same declarations a human seat would.
- R-TT-5.3 The framework SHALL support a **forced-declaration** terminal rule (e.g. Euchre stick-the-dealer;
  Sheepshead forced pick) as a configurable outcome when all seats pass.
- R-TT-5.4 The framework SHALL emit declaration events (`01:R-ENG-8.1`, extended per ADR 0003) for the
  caption bar (e.g. "East ordered up hearts," "South picks").
- R-TT-5.5 The bidding/declaration UI framework (TableKit) SHALL be reusable across both games and SHALL
  present each legal declaration with three input paths (direct, click-to-select, keyboard) per
  `ux-guidelines.md` and `01:R-TABLE-3` (R-UX-1).

### R-TT-6 — Determinism and purity
**User story:** As a maintainer, I want the core to obey the same purity and determinism rules as the rest
of the engine, so it stays Linux-portable and replayable.

- R-TT-6.1 The TrickTaking core SHALL import only the Swift standard library and Foundation; a UI-framework
  import SHALL fail `make lint` (`tech.md` rule 1; `01:R-BUILD-4.3`).
- R-TT-6.2 The core SHALL use only the injected `SeededRNG` and `Shuffle.fisherYates` for any randomness and
  SHALL NOT read wall-clock time or device state (`tech.md` rules 5, 8; ADR 0002).
- R-TT-6.3 WHEN the same hand seed and action log are replayed, a hand in either game SHALL produce an
  identical final state hash (`01:R-ENG-4.4`).

---

## 2. Euchre (`euchre`)

### R-EUC-1 — Deck and deal
**User story:** As a Euchre player, I want the standard 24-card deal with a turned-up card, so the game
starts as expected.

- R-EUC-1.1 Euchre SHALL use a 24-card deck of 9, 10, J, Q, K, A in each of the four suits
  (`DeckDefinition` "euchre-24", `01:R-ENG-2.2`).
- R-EUC-1.2 Euchre SHALL seat exactly 4 players in two fixed partnerships (seats across from each other are
  partners), with the local player bottom-center and others clockwise (`ux-guidelines.md`).
- R-EUC-1.3 WHEN a hand is dealt, each player SHALL receive 5 cards and the top card of the remaining
  4-card kitty SHALL be turned face up; the other 3 kitty cards SHALL remain face down.
- R-EUC-1.4 The deal pattern SHALL be animated in a real deal order (`ux-guidelines.md` motion); the exact
  2-3/3-2 deal pattern is a documented option (see Q-EUC-1, NEEDS REVIEW).

### R-EUC-2 — Bidding
**User story:** As a Euchre player, I want the standard two-round bidding with stick-the-dealer, so trump
is chosen the usual way.

- R-EUC-2.1 In round 1, in turn starting to the dealer's left, each player SHALL be able to **order up** the
  turned card (making its suit trump) or **pass**.
- R-EUC-2.2 WHEN a player orders up in round 1, the dealer SHALL pick up the turned card into hand and SHALL
  discard exactly one card face down; that card's suit SHALL become trump and round 1 SHALL end.
- R-EUC-2.3 WHERE round 1 is passed by all four players, round 2 SHALL begin: in turn, each player SHALL be
  able to name any suit **except** the turned-down suit as trump, or pass.
- R-EUC-2.4 WHERE all four players pass round 2 and stick-the-dealer is on (default), the dealer SHALL be
  required to name a trump suit (any suit except the turned-down suit); the dealer SHALL NOT be allowed to
  pass.
- R-EUC-2.5 WHERE stick-the-dealer is off, IF all players pass round 2 THEN the hand SHALL be redealt by
  the next dealer.
- R-EUC-2.6 The side that names trump SHALL be recorded as the **makers**; the other side SHALL be the
  **defenders**.

### R-EUC-3 — Bowers and trump order
**User story:** As a Euchre player, I want the bowers to behave correctly, so trump ranking is right.

- R-EUC-3.1 The Jack of the trump suit ("right bower") SHALL be the highest trump.
- R-EUC-3.2 The Jack of the other suit of the same color ("left bower") SHALL be the second-highest trump
  and SHALL count as a trump card, never as a card of its printed suit (implements R-TT-1.2).
- R-EUC-3.3 The remaining trump order, highest to lowest after the two bowers, SHALL be A, K, Q, 10, 9 of
  the trump suit; non-trump suits SHALL rank A, K, Q, (J), 10, 9 with the trump-color Jack removed from its
  printed suit.
- R-EUC-3.4 Following suit SHALL use effective suit (R-TT-1.4): a player holding only the left bower as a
  "trump" SHALL NOT be treated as holding a card of the left bower's printed suit.

### R-EUC-4 — Going alone
**User story:** As a Euchre player, I want to go alone for a bigger score, so the standard high-risk play is
available.

- R-EUC-4.1 WHEN a side has named trump, one player on that side SHALL be able to declare **going alone**,
  sitting their partner out for the hand (the partner plays no cards); that hand SHALL then have 3 active
  seats.
- R-EUC-4.2 WHERE the "defenders may defend alone" option is on (off by default), a defender SHALL be able
  to declare defending alone against a lone maker, sitting their own partner out.
- R-EUC-4.3 The active-seat set for the hand SHALL reflect any alone declarations (implements R-TT-2.3,
  R-TT-3.4).

### R-EUC-5 — Scoring and match
**User story:** As a Euchre player, I want standard scoring to 10, so matches end correctly.

- R-EUC-5.1 IF the makers take 3 or 4 of the 5 tricks, THEN the makers SHALL score 1 point.
- R-EUC-5.2 IF the makers take all 5 tricks (a march), THEN the makers SHALL score 2 points, OR 4 points
  WHERE the maker went alone.
- R-EUC-5.3 IF the defenders take 3 or more tricks (a euchre), THEN the defenders SHALL score 2 points.
- R-EUC-5.4 WHERE a defender defended alone and euchres a lone maker, the defender's bonus SHALL follow the
  documented rule (see Q-EUC-2, NEEDS REVIEW; common default 4 points).
- R-EUC-5.5 A match SHALL end when a side reaches 10 points; the target SHALL be a configurable option
  (default 10).
- R-EUC-5.6 WHERE the "physical score markers" cosmetic option is on (off by default), the scoreboard SHALL
  display 6/4-style card markers instead of a numeric score, with no change to the underlying scoring.

### R-EUC-6 — AI
**User story:** As a Euchre player, I want Easy/Medium/Hard opponents that play by real technique, so the
game is fun at every level.

- R-EUC-6.1 Easy SHALL bid only on strong hands and SHALL play the highest legal card.
- R-EUC-6.2 Medium SHALL count trump and track voids (R-TT-4) before bidding and playing, and SHALL make
  reasonable order-up / call decisions from hand strength.
- R-EUC-6.3 Hard SHALL use determinized ISMCTS (`01:R-AI-2.2`) over the hidden kitty and opposing hands,
  respecting recorded voids (R-TT-4.3), and SHALL meet the Hard p95 decision budget (R-NFR-AI.1).

---

## 3. Sheepshead — deck, deal, and points (`sheepshead`)

### R-SHP-1 — Deck, deal, and blind
**User story:** As a Sheepshead player, I want the standard 32-card 5-handed deal with a blind, so the game
starts correctly.

- R-SHP-1.1 Sheepshead SHALL use a 32-card deck of 7, 8, 9, 10, J, Q, K, A in each suit
  (`DeckDefinition` "sheepshead-32", `01:R-ENG-2.2`).
- R-SHP-1.2 Sheepshead SHALL seat exactly 5 players (3-handed is a Should, R-SHP-10).
- R-SHP-1.3 WHEN a hand is dealt, each player SHALL receive 6 cards (30 dealt) and 2 cards SHALL be set
  aside face down as the **blind**.
- R-SHP-1.4 The deal pattern SHALL be animated in a real deal order; the exact grouping and when the blind
  is set aside are documented options (see Q-SHP-1, NEEDS REVIEW).

### R-SHP-2 — Trump and fail order
**User story:** As a Sheepshead player, I want the correct fixed trump order, so ranking is right.

- R-SHP-2.1 The 14 trump cards, highest to lowest, SHALL be: Q♣, Q♠, Q♥, Q♦, J♣, J♠, J♥, J♦, A♦, 10♦, K♦,
  9♦, 8♦, 7♦ (all Queens, all Jacks, then the rest of the diamonds).
- R-SHP-2.2 Every Queen and every Jack SHALL be trump regardless of printed suit and SHALL count as trump
  for following (implements R-TT-1.2); the three non-diamond suits contain only their A, 10, K, 9, 8, 7 as
  **fail** cards.
- R-SHP-2.3 Within each fail suit, the order highest to lowest SHALL be A, 10, K, 9, 8, 7.

### R-SHP-3 — Card point values
**User story:** As a Sheepshead player, I want the standard point values, so scoring the hand is correct.

- R-SHP-3.1 Card point values SHALL be: Ace 11, Ten 10, King 4, Queen 3, Jack 2, and nine/eight/seven 0.
- R-SHP-3.2 The deck SHALL total 120 points; a composition/points test SHALL assert this
  (implements R-QA-1).
- R-SHP-3.3 The picker's side SHALL need **61 or more** of the 120 points (including any buried points) to
  win the hand (R-SHP-6).

---

## 4. Sheepshead — bidding and partnership

### R-SHP-4 — Picking and burying
**User story:** As a Sheepshead player, I want to pick or pass in turn, so the bid is decided the usual way.

- R-SHP-4.1 In turn order, each player SHALL be able to **pick** (take the 2-card blind unseen into hand) or
  **pass**; the first player to pick SHALL win the bid and become the **picker**, ending the pick phase.
- R-SHP-4.2 WHEN a player picks, they SHALL hold 8 cards and SHALL **bury** exactly 2 cards face down; the
  buried cards' points SHALL count for the picker's side at the hand tally.
- R-SHP-4.3 IF the picker attempts to bury a card that a called-partner rule forbids (e.g. burying the
  called suit's Ace under Called Ace), THEN a typed `RuleViolation` SHALL explain why (see Q-SHP-3, NEEDS
  REVIEW for the exact restriction).

### R-SHP-5 — Partner determination (Called Ace and alternatives)
**User story:** As a Sheepshead player, I want Called Ace partnership with the common fallbacks, so partner
determination works even in edge cases.

- R-SHP-5.1 WHERE the partner method is **Called Ace** (default), the picker SHALL name a fail suit whose
  Ace they do **not** hold; the holder of that Ace SHALL be the secret partner (R-TT-3.3), revealed when
  that Ace is played.
- R-SHP-5.2 The picker SHALL be required to hold at least one card of the called suit (so the called Ace
  can legally be pulled); the precise "must hold a card of the called suit" and "cannot call a suit you
  have no cards in" constraints are marked NEEDS REVIEW (Q-SHP-4) and implemented as the common defaults.
- R-SHP-5.3 IF the picker holds all three fail-suit Aces, THEN the picker SHALL instead call a **Ten** of a
  fail suit as the partner card, per the common default (marked NEEDS REVIEW, Q-SHP-5).
- R-SHP-5.4 The engine SHALL offer an **"unknown"/"under" call** and a **picker-going-alone** declaration;
  how each is presented and scored is documented and marked NEEDS REVIEW (Q-SHP-6).
- R-SHP-5.5 WHERE the partner method is **"Jack of Diamonds is always partner"** (an alternative option),
  the holder of J♦ SHALL be the partner instead of a called Ace, revealed when J♦ is played.
- R-SHP-5.6 The partner's identity SHALL be redacted from all other viewers until the reveal event
  (R-TT-3.3, R-TT-3.5); a wrong guess by an opponent SHALL never be confirmable from the view.

---

## 5. Sheepshead — no-pick options and play

### R-SHP-7 — No-pick options
**User story:** As a Sheepshead player, I want the standard no-pick handling options, so a passed-out deal
resolves my way.

- R-SHP-7.1 WHERE **Leaster** is selected (default), IF all players pass THEN the hand SHALL be played with
  every player for themselves; the exact Leaster objective, scoring, and tie-break are marked NEEDS REVIEW
  (Q-SHP-7) and implemented as the common default (win by taking the fewest points while taking at least
  one trick).
- R-SHP-7.2 WHERE **Doubler** is selected, IF all players pass THEN the hand SHALL be redealt and the next
  hand SHALL be played at double stakes.
- R-SHP-7.3 WHERE **Forced pick** is selected, IF all players pass THEN the dealer (or the lowest-ranked
  non-bidder, per option) SHALL be required to pick.
- R-SHP-7.4 Exactly one no-pick option SHALL be active per match, chosen in setup, with a one-line
  explanation each (`ux-guidelines.md` learning/help).

### R-SHP-8 — Play and following
**User story:** As a Sheepshead player, I want correct follow rules under the trump/fail split, so play is
legal and legible.

- R-SHP-8.1 WHILE a player holds a card of the led effective suit (trump counts as one suit), that player
  SHALL follow it (R-TT-1.4).
- R-SHP-8.2 WHEN the called Ace's suit is led (Called Ace), the partner SHALL be required to play the called
  Ace if able, per the common default (marked NEEDS REVIEW, Q-SHP-8).

---

## 6. Sheepshead — scoring

### R-SHP-6 — Hand scoring table
**User story:** As a Sheepshead player, I want the standard hand-points payout table, so results are
correct and always sum to zero.

- R-SHP-6.1 "Each defender" SHALL mean each of the (up to) 3 players not on the picker's side. The base
  payout table (double-on-the-bump ON, default) SHALL be:
  - IF the picker's side takes **61–90** points, THEN picker +2, partner +1, each defender −1.
  - IF the picker's side takes **91–120** points (schneider), THEN picker +4, partner +2, each defender −2.
  - IF the picker's side takes **all tricks** (schwarz), THEN picker +6, partner +3, each defender −3.
  - IF the picker's side takes **31–60** points (a loss on the bump), THEN picker −4, partner −2, each
    defender +2.
  - IF the picker's side takes **30 or fewer** points, THEN picker −8, partner −4, each defender +4.
  - IF the picker's side takes **no tricks at all**, THEN picker −12, partner −6, each defender +6.
- R-SHP-6.2 WHERE "double on the bump" is off, a loss SHALL pay the same magnitude as the corresponding win
  tier rather than double (e.g. a 31–60 loss pays −2/−1/+1 instead of −4/−2/+2); the exact off-the-bump
  mapping for each losing tier is documented in `Docs/Rules/sheepshead.md`.
- R-SHP-6.3 WHERE the picker goes alone (no partner seat), the picker SHALL take the partner's share in
  addition to their own; exactly how the defender count and the payment magnitudes adjust when there is no
  partner seat is marked NEEDS REVIEW (Q-SHP-9) and implemented as a best interpretation, clearly flagged.
- R-SHP-6.4 Every scoring tier SHALL sum to **zero** across all 5 players; a unit test SHALL assert this for
  every tier and every option combination (implements R-QA-2).
- R-SHP-6.5 The tier boundaries SHALL be exact: 60 vs 61 (loss vs win), 90 vs 91 (win vs schneider), the
  all-tricks (schwarz) edge, and the 0-trick edge; scenario tests SHALL cover each boundary (R-QA-1).

### R-SHP-9 — End-of-hand tally
**User story:** As a Sheepshead player, I want an animated count of the trick points and the payout, so the
result is clear.

- R-SHP-9.1 WHEN a hand ends, the UI SHALL show an animated count-up of each side's trick points, followed
  by the scoring-table result and a caption (`ux-guidelines.md`; R-UX-2).
- R-SHP-9.2 The tally SHALL be skippable and SHALL respect the animation speed and Reduce Motion settings
  (`01:R-TABLE-5.3`).

### R-SHP-10 — 3-handed Sheepshead (Should)
**User story:** As a Sheepshead player, I want 3-handed play, so a smaller table still works.

- R-SHP-10.1 The engine SHOULD support 3-handed Sheepshead (rules variant documented, marked NEEDS REVIEW,
  Q-SHP-10); it is a nice-to-have and NOT required for this spec to be considered complete.

### R-SHP-11 — AI
**User story:** As a Sheepshead player, I want Easy/Medium/Hard opponents, so the 5-handed game is
competitive.

- R-SHP-11.1 Easy and Medium SHALL bid on hand strength (trump count plus high fail cards) and play
  straightforwardly.
- R-SHP-11.2 Hard SHALL infer the likely called-partner identity (R-AI inference, design §5) and run
  determinized rollouts respecting recorded voids (R-TT-4.3), meeting the Hard p95 budget (R-NFR-AI.1).

---

## 7. Shared UX for trick-taking (TableKit conventions)

### R-UX-1 — Bidding/declaration UI
- R-UX-1.1 The bidding/declaration UI SHALL present each legal declaration with three input paths (direct
  manipulation, click-to-select-then-confirm, keyboard) and a visible focus indicator (`01:R-TABLE-3`,
  `01:R-A11Y-2`).
- R-UX-1.2 Each declaration option SHALL carry a one-line explanation (e.g. what "order up" or "go alone"
  does) per `ux-guidelines.md` learning/help.

### R-UX-2 — Trick table, captions, and collection
- R-UX-2.1 The table SHALL show a **center trick pile** that collects to the winning seat with animation
  (`ux-guidelines.md` motion), reusing the TableKit animation queue (`01:R-TABLE-5`) with no custom
  animation code (`01:R-TABLE-1.2`).
- R-UX-2.2 A caption bar SHALL narrate the last significant event (bids, trump named, trick won, partner
  revealed, hand result) from the event stream (`01:R-ENG-8.1`).
- R-UX-2.3 Seat plates SHALL show role badges appropriate to each game (dealer button; Euchre Maker/Alone;
  Sheepshead Picker/Partner once revealed) and an active-turn glow and AI thinking indicator
  (`01:R-TABLE-6.2`).

### R-UX-3 — Legal-target highlighting, "why not," and peek
- R-UX-3.1 WHILE a card is selected or dragged, TableKit SHALL highlight its legal targets and MAY dim
  unplayable cards (`01:R-TABLE-3.6`).
- R-UX-3.2 IF a player attempts an illegal play, THEN the card SHALL spring back with a shake and a caption
  built from the `RuleViolation` reason; no modal dialog SHALL appear (`01:R-TABLE-4.1`; R-TT-1.5).
- R-UX-3.3 The table SHALL offer **"peek at last trick"** (R-TT-2.4) and a history drawer with the full hand
  log (`ux-guidelines.md` table conventions).

### R-UX-4 — Accessibility for trick-taking
- R-UX-4.1 Every card, the trick pile, each seat plate, and every declaration control SHALL have a
  meaningful VoiceOver label, value, and hint (e.g. "Jack of clubs, trump, playable"); trump/effective suit
  SHALL be spoken (`01:R-A11Y-1`).
- R-UX-4.2 Bids, trump declarations, trick wins, and partner reveals SHALL be announced to VoiceOver
  (`01:R-A11Y-1.2`).
- R-UX-4.3 Both games SHALL be fully playable keyboard-only, including all bidding/declaration choices
  (`01:R-A11Y-2`).
- R-UX-4.4 Suits SHALL always carry shapes and a Four-Color deck option SHALL be available so trump and led
  suit are distinguishable without color (`01:R-A11Y-3`).

---

## 8. Learning, help, and Definition of Done

### R-DOD-1 — Rules documents
- R-DOD-1.1 A canonical rules document SHALL exist at `Docs/Rules/euchre.md` and at
  `Docs/Rules/sheepshead.md` (original writing, never copied from published sources — `ux-guidelines.md`
  voice/copy), each listing every option, its default, and presets.
- R-DOD-1.2 Every uncertain rule SHALL be marked **NEEDS REVIEW** in the rules doc until confirmed
  (`product.md` DoD); the Open Questions in §11 SHALL be reflected there.

### R-DOD-2 — Tutorials, hints, coach, rules reference
- R-DOD-2.1 Each game SHALL have an interactive tutorial with scripted deals (`ux-guidelines.md`).
- R-DOD-2.2 Each game SHALL provide hints (H) and an optional coach mode that explains the suggested move,
  reusing the AIKit hint interface (`01:R-AI-6`).
- R-DOD-2.3 The in-app rules reference SHALL open in an inspector rendered from the game's
  `Docs/Rules/<game-id>.md` without losing game state (`01:R-APP-3.2`).

### R-DOD-3 — Catalog, save/resume, statistics, presets
- R-DOD-3.1 Each game SHALL register in the catalog behind a feature flag (`01:R-APP-1.2`).
- R-DOD-3.2 Each game SHALL support save and resume at any point, including mid-hand against AI
  (`01:R-PERS-1`).
- R-DOD-3.3 Each game SHALL track statistics per game and variant (`01:R-APP-4`).
- R-DOD-3.4 Setup SHALL list presets first (e.g. Euchre Standard; Sheepshead Standard/Casual/Tournament),
  then options and house rules grouped separately, each with a one-line explanation (`01:R-APP-2`;
  `ux-guidelines.md`); the preset contents are documented and any uncertain preset is marked NEEDS REVIEW.

---

## 9. Quality gates

### R-QA-1 — Scenario tests
- R-QA-1.1 Scenario tests (Swift Testing `@Test`/`#expect`, Given/When/Then, named after the rule they
  prove — `structure.md`) SHALL cover: Euchre bidding (round 1 order-up, round 2 call, stick-the-dealer and
  the redeal option), bowers (right/left bower ranking and left-bower-follows-as-trump), going alone (and
  defend-alone when on); Sheepshead pick/pass and bury, Called Ace and its fallbacks (call-a-ten, unknown/
  under, go-alone, Jack-of-Diamonds option), no-pick options (Leaster/Doubler/Forced), and every scoring
  tier including the exact 60/61, 90/91, all-tricks (schwarz), and 0-trick boundaries.
- R-QA-1.2 Every scenario test SHALL be traceable to a rule in the relevant `Docs/Rules/<game-id>.md`.

### R-QA-2 — Zero-sum and points invariants
- R-QA-2.1 A unit test SHALL assert every Sheepshead scoring tier sums to zero across all 5 players, for
  double-on-the-bump on and off, and for the go-alone interpretation (R-SHP-6.4).
- R-QA-2.2 A test SHALL assert the Sheepshead deck totals 120 points and each game's deck composition is
  exact (R-SHP-3.2; `01:R-ENG-2.2`).

### R-QA-3 — Simulation invariants at reduced budget
- R-QA-3.1 Both games SHALL be wired into `parlor-sim`; invariants (piece conservation, only-legal-actions,
  bounded hand length, scoring consistency incl. zero-sum, deterministic replay) SHALL run in **both**
  `make test` (fast sample) and `make test-long` (full volume) (`01:R-QA-2`).
- R-QA-3.2 AI-vs-AI simulation for trick-taking games SHALL run at a **reduced AI search budget** relative
  to the interactive Hard budget; the reduced budget and the justification that it remains representative
  SHALL be documented in `design.md` (§7). The reduced budget SHALL still exercise determinization, void
  respect, and legal-only play.

### R-QA-4 — AI-tier-strength statistical test
- R-QA-4.1 Over a documented sample size, a statistical test SHALL assert that **Hard beats Medium** and
  **Medium beats Easy** by a statistically significant margin in each game; the sample size, metric
  (win-rate or net points), and significance threshold SHALL be documented in `design.md`.
- R-QA-4.2 The strength test SHALL use injected, seeded RNG so results are reproducible (`01:R-AI-3.2`).

### R-QA-5 — View-leak and save/restore
- R-QA-5.1 The view-leak property test (`01:R-QA-3`) SHALL include a hidden Sheepshead partnership and
  confirm the partner's identity never appears in any non-partner viewer's serialized view before the
  reveal.
- R-QA-5.2 Save/restore round-trip (`01:R-QA-4`) SHALL cover mid-bid, mid-hand, and post-reveal states in
  both games.

### R-QA-6 — Coverage
- R-QA-6.1 Line coverage SHALL be ≥ 90% for the TrickTaking core and for each of the `euchre` and
  `sheepshead` rules targets (`tech.md` testing; `01:R-QA-7`).

---

## 10. Non-functional requirements (measurable)

### R-NFR-AI — AI decision budgets
- R-NFR-AI.1 A Hard decision SHALL meet the `tech.md` p95 budget of ≤ 1.0 s per move (excluding cosmetic
  pacing), be cancellable, and run off the main actor (`01:R-AI-3`).
- R-NFR-AI.2 AI pacing SHALL be natural and jittered and set independently of animation speed
  (`01:R-AI-4`).

### R-NFR-PERF — Rendering budgets
- R-NFR-PERF.1 A trick-taking table (≤ 5 seats × ≤ 8 cards) SHALL hold ≥ 60 fps (120 fps target on
  ProMotion) during deal, play, and trick collection, and input-to-feedback SHALL be ≤ 50 ms
  (`tech.md` budgets; ADR 0001).
- R-NFR-PERF.2 Starting either game SHALL take ≤ 300 ms and memory SHALL stay ≤ 400 MB (`tech.md`).

### R-NFR-DET — Determinism
- R-NFR-DET.1 Same seed + same action log SHALL reproduce an identical final state hash for a full hand of
  each game (R-TT-6.3; `01:R-ENG-4.4`).

### R-NFR-BUILD — Build discipline
- R-NFR-BUILD.1 All new targets SHALL compile in Swift 6 strict-concurrency mode with zero warnings
  (`01:R-BUILD-5`).
- R-NFR-BUILD.2 The TrickTaking core and both rules targets SHALL contain no UI-framework imports and no
  force-unwraps/`try!`; violations SHALL fail `make lint` (`tech.md` rules 1 and code conventions;
  `01:R-BUILD-4.3`).

### R-NFR-DOC — Documentation upkeep
- R-NFR-DOC.1 `Docs/Architecture.md` SHALL be updated in the same task that changes behavior (add the
  TrickTaking core to the module map and note the two games) (`structure.md`).
- R-NFR-DOC.2 IF any EngineCore/TableKit public-API change is made, THEN ADR 0003 SHALL record it before
  the change lands (`tech.md` rule 9; §12).

---

## 11. Assumptions and Open Questions / NEEDS REVIEW

Sheepshead in particular has genuine regional variation; the following are flagged rather than guessed. Each
is mirrored in the relevant `Docs/Rules/<game-id>.md` as **NEEDS REVIEW** and must be resolved (or
re-affirmed) before its dependent task is marked complete.

### Assumptions
- A-1 The TrickTaking core is a **new shared module** under `Packages/Games/TrickTaking/` (rules-pure), with
  `euchre` and `sheepshead` as rules targets that depend on it, mirroring the per-family folder shape in
  `structure.md`. Spec 07 (Hearts, Spades) will depend on the **same** core without modifying it.
- A-2 `EngineCore` and `TableKit` public surfaces are as defined in Spec 01 `design.md`; two additive,
  backward-compatible extensions are anticipated and captured in ADR 0003 (declaration/reveal events and a
  declaration input path). No breaking changes are assumed.
- A-3 Standard North American Euchre and 5-handed Called-Ace Sheepshead are the reference rulesets; house
  rules extend them via options.

### Open Questions — Euchre
- Q-EUC-1 Exact deal pattern (e.g. 3-2 then 2-3) — default documented, marked NEEDS REVIEW. (R-EUC-1.4)
- Q-EUC-2 Defender-alone euchre bonus (2 vs 4 points) when the option is on. (R-EUC-5.4)
- Q-EUC-3 Whether "farmer's hand" / misdeal reshuffle rules are offered as an option (default off).
- Q-EUC-4 Preset contents for Euchre (Standard vs regional). (R-DOD-3.4)

### Open Questions — Sheepshead
- Q-SHP-1 Exact deal/blind pattern and timing. (R-SHP-1.4)
- Q-SHP-2 Whether "blitz"/"crack"/"double" (re/contra) betting is offered (default off; out of base scope).
- Q-SHP-3 Precise burying restrictions under Called Ace (e.g. may the called Ace or a card of the called
  suit be buried?). (R-SHP-4.3)
- Q-SHP-4 Exact "must hold a card of the called suit" / legal-call constraints. (R-SHP-5.2)
- Q-SHP-5 Fallback when the picker holds all three fail Aces (call a ten — which ten, and precedence).
  (R-SHP-5.3)
- Q-SHP-6 Presentation and scoring of the "unknown"/"under" call and picker-going-alone. (R-SHP-5.4)
- Q-SHP-7 Exact Leaster objective, scoring, and tie-break. (R-SHP-7.1)
- Q-SHP-8 Whether the partner must play the called Ace when its suit is led, and the "called-suit must be
  led first / cannot be led until pulled" family of rules. (R-SHP-8.2)
- Q-SHP-9 Exact defender-count and payment adjustments when the picker goes alone (no partner seat).
  (R-SHP-6.3)
- Q-SHP-10 3-handed Sheepshead ruleset (Should). (R-SHP-10.1)
- Q-SHP-11 Tournament preset contents and stakes. (R-DOD-3.4)

---

## 12. Architecture Decision Records introduced by this spec

- **ADR 0003 — Trick-taking core and its EngineCore/TableKit touchpoints.** Records (a) the new shared
  TrickTaking rules module and its **stable public contract** (Spec 07 reuses it unchanged), and (b) two
  anticipated **additive** extensions to Spec 01 public APIs: declaration/partner-reveal `GameEvent` cases
  and a TableKit declaration input path for auctions. Per `tech.md` rule 9 and `structure.md`, any genuine
  EngineCore/TableKit public-API change requires an ADR; this ADR is the gate. See
  `Docs/ADR/0003-trick-taking-core.md`.

## 13. Traceability note

Every requirement here is implemented by at least one task in `tasks.md`, which cites requirement IDs;
`design.md` cites requirement IDs inline. Open Questions Q-EUC-\* and Q-SHP-\* must be resolved before their
dependent tasks are marked complete.
