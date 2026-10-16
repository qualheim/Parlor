# Crazy Eights

Crazy Eights is the shedding game most people learned at a kitchen table: match the top of the pile by
suit or rank, play a wild 8 to change the suit when you are stuck, and race to be the first with an empty
hand. It seats two to five, one of whom is you and the rest of whom Parlor plays.

This document is the single source of truth for how Parlor plays Crazy Eights. Every rule and option
below is written so it can be checked on its own — the scenario suite mirrors these sections one-for-one
and each test is named after the rule it proves. Where a value is not yet settled it is marked **NEEDS
REVIEW** with a question tag (Q-3, Q-4, Q-5); those items must be confirmed before this variant is
considered final.

_Original text written for Parlor. No third-party rules text is reproduced here._

---

## Objective

Be the first player to get rid of every card in your hand. The moment a player empties their hand they
"go out" and the hand is over. The player who went out scores the cards their opponents are still
holding; those points accumulate across hands toward a match target.

---

## Players and the deal

A single standard 52-card pack is shuffled and dealt. Crazy Eights seats **two to five players**: the
local human plus one to four AI opponents.

- **R-CE-1.1 / players:** the game supports 2–5 players — you plus 1–4 AI opponents.
- **R-CE-1.2 / deal:** with **2 players** each hand is dealt **7 cards**; with **3, 4, or 5 players**
  each hand is dealt **5 cards**.

After the hands are dealt, one card is turned up from the remaining pack to start the discard pile — the
**starter**. The rest of the pack, face down, becomes the **stock** you draw from.

- **R-CE-1.3 / starter:** the game turns up a starter card. **If the starter is an 8**, it is buried back
  into the stock and another card is turned up, repeating until the starter is not an 8. (An 8 is wild
  and would leave the first suit undefined, so it never starts the pile.)

Facts a test can pin down:

- Two players → each hand holds 7 cards after the deal; three-to-five players → each holds 5.
- Exactly one card sits face up on the discard at the start, and it is never an 8.
- The stock holds every card not dealt to a hand and not turned up as the starter.

### The board

- **One hand per player**, private to its owner — you see only your own cards.
- **A stock**, face down, that players draw from.
- **A discard pile**, of which only the **top card** is public — that is the card you match against.

---

## Play

Play passes from player to player around the table. On your turn you either play a card that matches the
top of the discard, or you draw (and possibly play the drawn card, depending on the draw option below).

### Matching by suit or rank

To play a card it must match the current pile: the same **suit** as what the pile currently calls for,
**or** the same **rank** as the top card.

- **R-CE-2.1 / match:** a card may be played if it matches the top discard's suit or its rank. Normally
  the suit that must be matched is the top card's own suit; after an 8 is played it is the suit that
  player **named** (see below), which can differ from the 8's printed suit.

### Eights are wild

An **8** may be played on anything. When you play an 8 you **name a suit**, and the next player must
follow that named suit (or play another 8, or match the 8's rank by playing another 8).

- **R-CE-2.2 / wild eight:** 8s are wild — an 8 is always a legal play, and the player who plays one
  names the suit that must be matched next. The named suit is public information; it can be a suit the 8
  itself is not.

### Drawing when you cannot (or will not) play

If you cannot play a matching card — or choose not to — you draw from the stock. Two options govern
exactly how:

- **R-CE-2.3 / draw:** the player **draws until they can play** (the default), or **draws one card and
  passes** (option). See the [Options](#options) section for the two draw modes.

### When the stock runs out

The stock is finite. When it empties mid-hand, one of two things happens depending on the option:

- **R-CE-2.4 / stock-out:** the game **reshuffles the discards except the top card** back into a fresh
  stock (the default), or **ends the hand once no one can play** (option). See [Options](#options).

### Passing

A player may pass **only** when they genuinely cannot act — that is, only when the stock cannot yield a
card (it is empty and reshuffle is off or impossible) and they hold no playable card. As long as a draw
or a legal play is available, passing is not allowed.

> **NEEDS REVIEW (Q-3):** Under "draw until you can play," when the stock is empty and reshuffle is off,
> is there a maximum number of draws before the player is forced to pass? Parlor's current behavior:
> "draw until you can play" simply **stops drawing when the stock is exhausted** — there is no infinite
> draw and no separate numeric cap; the player then passes if still stuck. Whether a different explicit
> cap is wanted is deferred. (Trace: R-CE-2.3, R-CE-2.4.)

---

## Options

Each option is listed with its **default** and the behavior it selects. Presets bundle common
combinations and appear first on the setup sheet.

### Player count — **default: 2** (R-CE-1.1)

The number of players at the table, from 2 to 5 (you plus 1–4 AI). The deal size follows from this: 7
cards each at 2 players, 5 cards each at 3–5.

### Draw mode — **default: Draw until you can play** (R-CE-2.3)

What a player does when they have no matching card (or choose not to play a match).

- **Draw until you can play** — keep drawing from the stock until a playable card appears; that draw ends
  the turn. The default. (When the stock is exhausted and cannot be refilled, drawing simply stops — see
  Q-3.)
- **Draw one then pass** — draw exactly one card and pass the turn, whether or not the drawn card is
  playable.

### Stock-out behavior — **default: Reshuffle discards** (R-CE-2.4)

What happens when the stock empties during a hand.

- **Reshuffle discards** — take every discard except the current top card, and rebuild the stock from
  them so play continues. The default. The top card and the current named suit are unchanged.
- **End the hand** — once the stock is gone and no player can play, the hand ends and is scored on the
  cards still in hand.

### Match target — **default: 100, configurable** (R-CE-3.2)

The number of points a player must reach to win the **match**. A single hand scores the going-out
player's points (below); those points accumulate across hands until someone reaches the target.

- **R-CE-3.2:** the match target defaults to **100** and is configurable.

### Action cards — **default: Off** (R-CE-4.1)

The livelier variant in which three ranks carry special effects. **Off by default.**

- **Off** — no card has a special effect; only the wild 8 is special. The default.
- **On** — the action-card ranks take effect (see [Action cards](#action-cards-option) below).

### Presets (setup sheet lists these first)

- **Classic** — 2 players, draw until you can play, reshuffle on stock-out, target 100, action cards off.
  The standard game.
- **Action Cards** — 4 players, draw until you can play, reshuffle on stock-out, target 100, action cards
  on. The livelier table.
- **Quick** — 2 players, draw one then pass, reshuffle on stock-out, target 50, action cards off. A
  shorter game.

---

## Scoring

When a player goes out, they score the value of the cards **left in every other player's hand**. Card
values:

- **R-CE-3.1 / scoring:** the player who goes out scores the cards left in opponents' hands, valued as —
  - an **8** = **50**;
  - a **King, Queen, or Jack** = **10**;
  - an **Ace** = **1**; and
  - every **other card** at its **face (pip) value** — a 2 counts 2, a 10 counts 10, and so on.

The number cards 2 through 10 count their pip value, and the Ace counts 1 (not 11); this face-value
counting is authoritative here and matches assumption A-5 in the requirements.

Across hands, each hand's points are added to the winner's running total; the first to reach the match
target (default 100) wins the match. The per-hand outcome is reported by this game; the cross-hand
accumulation to the target is handled by the shared match machinery.

If a hand ends under the **End the hand** stock-out option with nobody having gone out, the player holding
the **fewest points** in hand is treated as the winner and scores the others' remaining cards.

---

## Action cards (option)

**Off by default (R-CE-4.1).** When the action-cards option is on, three ranks gain effects on top of the
normal matching rules. They are still played by the ordinary match rule (suit or rank); the effect is
what happens *after* they are played.

- **2 — draw two, and 2s stack.** The next player must draw two cards. If instead they play their own 2,
  the penalty **stacks**: the following player then owes four, and so on, until someone cannot (or will
  not) stack and pays the whole accumulated draw.
- **Jack — skip.** The next player is skipped; play passes to the player after them.
- **Ace — reverse.** The direction of play reverses (clockwise ↔ counter-clockwise).

- **R-CE-4.1:** with action cards on, a 2 makes the next player draw two and 2s stack; a Jack skips the
  next player; an Ace reverses direction. This option defaults off.

An 8 is **only ever wild** — it is not an action card, even with the option on.

**Paying a draw-two.** While a draw is pending, the player who owes it has exactly two choices: stack
another 2, or draw the whole amount. An 8 cannot cover a pending draw, and neither can any other
matching card. Drawing pays the debt in full (or as much as the stock can supply) and ends that player's
turn; the cards drawn cannot be played until their next turn.

> **NEEDS REVIEW (Q-4):** Action-card edge cases. Parlor's current behavior, pending confirmation:
>
> - In a **2-player** game, a **Jack (skip)** skips the only opponent, so the turn returns to the player
>   who played it — they play again.
> - In a **2-player** game, an **Ace (reverse)** flips the direction, but with only two seats the next
>   player is still the opponent. A reverse therefore plays like an ordinary card at a 2-player table.
> - An **8 is never an action card** — it is only wild.
> - A **2 drawn from the stock** is a normal card in hand. It cannot stack the debt it was drawn to pay,
>   because paying ends the turn. On a later turn it plays (and stacks) like any other 2.
>
> Whether any of these should behave differently is deferred. (Trace: R-CE-4.1.)

> **NEEDS REVIEW (Q-5):** Starter card that is an action card. With action cards on, if the turned-up
> starter is a 2, Jack, or Ace, does its effect apply to the **first** player? Parlor's current behavior:
> the starter's action effect **does not apply** — the first hand begins with no pending draw and
> clockwise direction regardless of the starter's rank. (Only an 8 gets special starter handling: it is
> buried, per R-CE-1.3.) Whether the starter's action effect should apply to the first player is
> deferred. (Trace: R-CE-1.3, R-CE-4.1.)

---

## AI opponents

Crazy Eights ships three difficulty levels (detailed in the AI task, listed here for reference):

- **Easy** — plays a random legal card and spends its 8s early (R-CE-5.1).
- **Medium** — holds 8s for when they are needed, names its longest suit when it does play one, and
  tracks suits opponents have failed to follow (R-CE-5.2).
- **Hard** — uses determinized Monte Carlo search from the shared AI toolkit (R-CE-5.3).

---

## Undo

Crazy Eights is a multi-player game with hidden hands, so it does **not** offer free undo during normal
play: taking back a move would reveal information a player should not see. (Practice Mode, a
platform-level feature, is the exception where stepping back is allowed.)

---

## Open questions

All three remain **NEEDS REVIEW** as of the foundation sign-off (task 8.5). Each ships with the default
below, and each default is pinned by a scenario test so a change is a deliberate decision.

- **Q-3 — "Draw until you can play" cap.** When the stock is empty and reshuffle is off, is there a
  maximum number of draws before a forced pass? **Chosen default:** no numeric cap. Drawing stops when
  the stock is exhausted, and a player who still cannot play then passes.
- **Q-4 — Action-card edge cases.** With action cards on: how do Jack (skip) and Ace (reverse) behave in
  a 2-player game, can an 8 also be an action card, and does a drawn 2 stack? **Chosen default:** a
  2-player Jack gives the player another turn; a 2-player Ace passes to the opponent as usual; an 8 is
  only wild; a 2 drawn to pay a debt cannot stack that debt.
- **Q-5 — Starter card that is an action card.** With action cards on, if the turned-up starter is a 2,
  Jack, or Ace, does its effect apply to the first player? **Chosen default:** no. The hand starts
  clockwise with seat 0 to play and nothing owed, whatever the starter's rank.
