# Klondike

Klondike is the solitaire most people picture when they hear the word: seven fanned columns, four tidy
home piles, and a face-down stock you turn through looking for the next play. It is a game for one.

This document is the single source of truth for how Parlor plays Klondike. Every rule and option below
is written so it can be checked on its own — the scenario suite mirrors these sections one-for-one. Where
a value is not yet settled it is marked **NEEDS REVIEW** with a question tag (Q-1, Q-2); those items must
be confirmed before this variant is considered final.

_Original text written for Parlor. No third-party rules text is reproduced here._

---

## Objective

Move all fifty-two cards to the four foundations. Each foundation collects one suit and fills from Ace up
to King. Clear every card home and the game is won.

- **R-KLON-1.2 / win:** the game is over and won the moment all four foundations are complete (13 cards
  each, 52 in total).

---

## The deal and the board

A single standard 52-card pack is shuffled and dealt into the starting layout:

- **Seven tableau columns** on the table, holding one card in the first column up to seven in the last.
  The last card dealt to each column lands face up; every card beneath it stays face down.
- **A stock** of the twenty-four remaining cards, face down, off to the side.
- **An empty waste**, where cards turned from the stock go.
- **Four empty foundations**, one per suit, waiting for their Aces.

Facts a test can pin down (**R-KLON-1.1**):

- The seven columns hold 1, 2, 3, 4, 5, 6, and 7 cards — twenty-eight in all.
- Exactly one card per column is face up at the start (the top card).
- The stock holds twenty-four cards, all face down.
- The waste starts empty; all four foundations start empty.

---

## Play

You move cards between the waste, the tableau, and the foundations, turning the stock when you run out of
plays. The rules for what may go where:

### Foundations build up by suit

A foundation takes only its own suit, in ascending order. An empty foundation accepts an Ace; after that
each card must be the next rank up in the same suit (Ace, then 2, then 3, … up to King).

- **R-KLON-1.2:** a card may go to a foundation only if it is the same suit as the pile and exactly one
  rank higher than the current top; an empty foundation accepts only an Ace.

### The tableau builds down in alternating colors

A card placed on a tableau column must be one rank lower than the card it lands on **and** the opposite
color. Clubs and spades are black; hearts and diamonds are red. So a red six sits on a black seven, a
black five sits on that red six, and so on.

- **R-KLON-1.2:** a tableau placement is legal only if the moving card is one rank below the target's top
  card and of the opposite color.

### Face-up sequences move as a unit

Any run of face-up cards that is already in proper down-and-alternating order can be picked up and moved
together to another column, as long as the card at the bottom of the run follows the destination's top
card by the tableau rule above.

- **R-KLON-1.3:** a face-up sequence (a descending, alternating-color run) may be moved as a single unit;
  the run's lead card must be a legal tableau placement on the destination.

### Only a King fills an empty column

When a column is emptied, only a King — or a sequence led by a King — may be moved into the gap.

- **R-KLON-1.4:** an empty tableau column accepts only a King, or a run whose lowest-in-pile (lead) card
  is a King.

### Cards may come back from a foundation

A card already sent to a foundation may be moved back down onto the tableau if it makes a legal tableau
placement. This helps when a card you parked on a foundation is needed to accept another color below it.

- **R-KLON-1.5:** the top card of a foundation may return to the tableau, subject to the tableau
  build-down rule.

### Turning the stock exposes a fresh column top

When a move empties the face-up cards off a column and leaves a face-down card on top, that card turns
face up and becomes playable. The *turn itself is part of the rules* — the exposed top always becomes
face up, which keeps the board legal and playable. Whether the app **presents** that turn automatically
or waits for a tap is the separate *auto-flip* setting in [Features](#features) (R-KLON-3.1); it changes
only the presentation, never the authoritative state.

---

## Options

Each option is listed with its **default** and the behavior it selects. Presets bundle common
combinations and appear first on the setup sheet.

### Draw count — **default: Draw 1** (R-KLON-2.1)

How many cards turn from the stock to the waste per draw.

- **Draw 1** — turn one card at a time. The default.
- **Draw 3** — turn three at a time; only the top of the three is immediately playable.

### Scoring — **default: Standard** (R-KLON-2.2)

Which scoring scheme runs during play. See [Scoring](#scoring) below for the details of each.

- **Standard** — classic point scoring. The default.
- **Vegas** — money scoring; start in the hole and earn as cards reach the foundations.
- **None** — no score is kept.

### Stock passes — **default: Unlimited** (R-KLON-2.3)

How many times you may run through the stock. When the stock is empty and the waste is not, recycling the
waste turns it back into a fresh face-down stock and counts as beginning another pass.

- **Unlimited** — recycle as often as you like. The default.
- **Three passes** — you may run through the stock three times in total.
- **One pass** — a single run through the stock; no recycling.
- **Vegas override:** when Scoring is Vegas, passes default to **one** with Draw 1 and **three** with
  Draw 3, matching the usual Vegas convention. This override applies unless a different explicit choice is
  made for that game.

### Timed scoring — **default: Off** (R-KLON-2.4)

Whether the game keeps a clock that can influence the score.

- **Off** — no time pressure. The default.
- **On** — a timer runs; under Standard scoring, time can contribute to the final score (see the Standard
  table's time bonus, which is **NEEDS REVIEW (Q-1)**).

### Vegas cumulative bankroll — **default: Off** (R-KLON-2.2)

Whether a Vegas balance carries from one game into the next instead of each game starting fresh at −52.

- **Off** — every Vegas game starts its own bankroll at −52. The default.
- **On** — the bankroll carries across games.
- **NEEDS REVIEW (Q-2):** whether the carried bankroll also persists across app launches, and how a
  player resets it, is deferred to the persistence work. Parlor models the on/off choice now; the
  persistence behavior is not yet settled.

### Presets (R-KLON-2.5)

- **Draw 1 / Standard** — the classic default game: Draw 1, Standard scoring, Unlimited passes, timer off.
- **Draw 3 / Vegas** — Draw 3 with Vegas money scoring; passes follow the Vegas override (three).
- **Relaxed / No scoring** — Draw 1, no score, Unlimited passes; a low-pressure game to just play.

---

## Features

Beyond the rules and variant options, Parlor's Klondike offers the player-convenience features below.
None of these change what is *legal* — every move a feature makes is one the rules already allow — so
they cannot help you cheat; they just save clicks. Each lists its **default**.

### Auto-flip — **default: On** (R-KLON-3.1)

Whether a newly exposed tableau top card is turned face up automatically.

- **On** — an exposed face-down top flips up on its own the moment it is uncovered. The default.
- **Off** — the card is turned up on a tap instead.

The exposed top always *becomes* face up either way (that is the rule above); this toggle governs only
whether it happens automatically or on a tap, and it never affects the authoritative state or replay.

### Auto-move to foundations — **default: Safe only** (R-KLON-3.2)

Whether cards are sent home to the foundations for you after each move.

- **Off** — never auto-play; you send every card home yourself.
- **Safe only** — auto-play a card only when it is *safe*, i.e. it can never be needed on the tableau to
  receive an opposite-color card later. The default. The safe test: Aces and twos are always safe; a
  card of rank N (N ≥ 3) is safe when **both** foundations of the opposite color have already reached at
  least rank N − 1 (so any opposite-color card that could have landed on it is already home). For a black
  card the opposite color is red (hearts, diamonds); for a red card it is black (clubs, spades).
- **Always** — auto-play any card that can legally go to a foundation, safe or not.

### Smart move (double-click) — always on (R-KLON-3.3)

Double-clicking a card (or the lead of a movable run) sends it to its preferred destination: a foundation
if the card can legally go home, otherwise a legal tableau build (preferring a build onto an existing
column over dropping a King into an empty one). If no legal destination exists, nothing happens.

### Auto-complete — offered when the game is solved (R-KLON-3.3)

When the board reaches a state where every remaining card can be sent home with no further decisions —
all tableau cards face up and the stock and waste empty — Parlor offers to finish the game for you,
lifting the cards to the foundations in order until you win.

### No-moves handling — inline banner, never a dialog (R-KLON-3.6)

When no legal move remains (no tableau or foundation play, and no stock draw or recycle left), Parlor
shows an **inline banner** — never a modal error dialog — offering three ways forward:

- **Undo** — take back your last move (offered when there is history to undo);
- **Restart this deal** — replay the very same deal from the start (see below);
- **New game** — deal a fresh game.

### Restart the same deal & numbered deals — (R-KLON-3.7)

Every deal has a **number**. "Play deal #N" deals the same game every time: the deal number maps
deterministically to the shuffle seed, so deal #N is identical on any machine and any build. "Restart
this deal" simply re-deals the current number with the same options, letting you try the same layout
again.

### Timer & move counter — (R-KLON-3.8)

The game shows a running **timer** (elapsed play time) and a **move counter** (the number of moves you
have made). These are display information only: they are kept outside the authoritative game state, so
they never affect determinism, saves, or replay.

### Hints — heuristic (R-KLON-3.5)

Ask for a hint and Parlor suggests a reasonable next move by a quick heuristic: it prefers a move that
uncovers a face-down card, then one that empties a column (opening a slot for a King), then a safe
foundation advance, then any legal foundation move, then any legal move at all. If there are no moves, it
says so. (Deeper, solver-backed hints are a later, separate capability and are out of scope here.)

---

## Scoring

### Standard — **exact values NEEDS REVIEW (Q-1)**

Standard scoring follows the classic point scheme in spirit: you gain points for productive moves and lose
points for undoing progress. The **structure** below is settled; the **exact point values, the time-bonus
formula, and the recycle penalty are provisional and flagged Q-1** until confirmed. They live in one
adjustable table in the code so a confirmed set of numbers drops in without touching the move logic.

| Move                                        | Points (provisional — Q-1) |
| ------------------------------------------- | -------------------------- |
| Waste card played onto the tableau          | +5                         |
| Card sent to a foundation                   | +10                        |
| Face-down tableau card turned face up       | +5                         |
| Card moved back from a foundation to tableau| −15                        |
| Recycling the waste into the stock          | −20 (which passes it applies to is also Q-1) |
| Time bonus (when Timed is on)               | formula **NEEDS REVIEW (Q-1)** |

These magnitudes are a fresh table authored for Parlor pending review; do not treat them as final.

### Vegas

Vegas is money scoring:

- The bankroll **starts at −52** — as if you paid a dollar per card for the deck.
- Each card that reaches a foundation is worth **+5**.
- A perfect game therefore nets +208 (52 × 5 − 52).

Settled facts a test can pin down (**R-KLON-2.2**):

- A new Vegas game's score starts at exactly −52.
- Sending any card to a foundation increases the score by exactly 5.
- Moving a card back off a foundation does not refund; Vegas scores only cards *sent* home.

The **cumulative** variant (carry the bankroll between games) is the option above; its persistence detail
is **NEEDS REVIEW (Q-2)**.

### None

No score is tracked. The score reads zero throughout and the outcome reports zero. Useful for a relaxed
game or for practice.

---

## Undo

Klondike offers **unlimited undo and redo** (R-KLON-3.4). Any move can be taken back, all the way to the
start of the deal, and redone again. This is declared by the game itself; the shared engine provides the
machinery.

---

## Open questions

- **Q-1 — Standard scoring exact values.** The per-move points, the timed-play bonus formula, and the
  recycle-waste penalty in the Standard table above are provisional. They must be confirmed before
  Standard scoring is treated as final.
- **Q-2 — Vegas cumulative persistence.** The cumulative-bankroll option exists, but whether the balance
  persists across app launches (and how it is reset) is deferred to the persistence phase and not yet
  settled.
