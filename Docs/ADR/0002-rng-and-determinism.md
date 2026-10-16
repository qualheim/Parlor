# ADR 0002 — RNG algorithm and determinism

- **Status:** Accepted (foundation baseline)
- **Date:** 2026-09-28
- **Context spec:** `/.kiro/specs/01-platform-foundation/`
- **Relates to requirements:** R-ENG-4, R-QA-2, R-QA-4, R-AI-3.2
- **Supersedes / superseded by:** none

## Context

`tech.md` architecture rule 5 requires: the host owns a seeded PRNG (algorithm documented) and our own
Fisher–Yates shuffle; rules code never uses `Int.random`, `shuffle()`, or `SystemRandomNumberGenerator`;
seeds are generated once per hand, outside the rules; and the same seed plus the same action log must
produce an identical state hash on every run. Fair play (`product.md` principle 2) requires shuffles to be
uniformly random and reproducible from a seed. `parlor-sim` and the save/restore round-trip tests depend
on deterministic replay (R-QA-2.1, R-QA-4.1).

## Decision

1. **PRNG algorithm: xoshiro256\*\*, seeded via SplitMix64.** A 64-bit hand seed is expanded through
   SplitMix64 to fill xoshiro256\*\*'s 256-bit state; `next() -> UInt64` returns the xoshiro256\*\* output.
   xoshiro256\*\* is fast, well-distributed, and trivially portable to Linux (no platform RNG). This choice
   is revisable only by superseding this ADR (Assumption A-2).
2. **Fisher–Yates only.** Shuffling uses our own unbiased Fisher–Yates over the `SeededRNG`, computing an
   unbiased index in `0...i` via rejection sampling. Rules code must call this; `Int.random`,
   `shuffle()`, and `SystemRandomNumberGenerator` are forbidden and lint-checked (R-ENG-4.2, R-BUILD-4).
3. **Seed lifecycle.** One seed is generated per hand **outside** the rules and recorded in the match
   (`handSeeds`) and the save file (R-ENG-4.3). The AI receives its own injected RNG so AI-vs-AI runs are
   reproducible (R-AI-3.2).
4. **State hash.** After each applied action the host computes a stable digest (SHA-256) over the
   canonical `Codable` encoding of authoritative state, using deterministic key ordering and no wall-clock
   fields (timestamps live only in log metadata, `tech.md` rule 8). The hash is stored per log entry
   (Assumption A-3).
5. **Determinism contract.** Given the same hand seed(s) and the same ordered action log, replay produces
   an identical final state hash on every run and platform. This is asserted by a dedicated determinism
   test (R-ENG-4.4), by `parlor-sim`'s replay invariant (R-QA-2.1), and by the save/restore round-trip
   (R-QA-4.1).

## Consequences

- **Positive:** reproducible hands enable verification, replays, save/restore correctness, and future
  network sync; no dependency on any platform RNG keeps the pure layer Linux-portable.
- **Negative / risks:** determinism requires disciplined canonical encoding (stable key order, no
  incidental nondeterminism such as `Set` iteration order leaking into the hash); the canonical encoder
  and hash inputs must be reviewed whenever state types change (a save-format change also triggers an ADR
  per `structure.md`).
- **Follow-ups:** add a cross-platform determinism check once a Linux CI runner exists.

## Implementation status (task 8.5 audit)

Checked against the code at foundation sign-off. The decisions match the implementation, except that
the RNG-API ban in decision 2 is not lint-enforced yet (details below).

- **PRNG** (`EngineCore/RNG.swift`). `SeededRNG` fills xoshiro256\*\*'s four state words from four
  SplitMix64 outputs of the hand seed and returns the reference `rotl(s1 * 5, 7) * 9` scrambler. It uses
  only wrapping fixed-width integer arithmetic, so it is Linux-portable.
- **Shuffle.** `Shuffle.fisherYates` walks from the last index down to 1 and draws each swap index in
  `0...i` by rejection sampling (draws at or above the largest multiple of `n` are redrawn), so there is
  no modulo bias.
- **Banned RNG APIs — one deviation.** Decision 2 says `Int.random`, `shuffle()`, and
  `SystemRandomNumberGenerator` are lint-checked. They are **not** yet: `Scripts/lint.sh` checks
  networking/analytics APIs, pure-layer UI imports, dependency direction, and entitlements, but has no RNG
  rule. The 8.5 audit grepped EngineCore, AIKit, and GamesRules and found no use of these APIs; every
  shuffle goes through `Shuffle.fisherYates`. Follow-up: add an RNG-API rule for the pure layer to
  `Scripts/lint.sh`.
- **Seeds.** One seed per hand lives in `Match.handSeeds` and the save file. Klondike's numbered deals map
  the deal number straight to the seed. AI strategies get their own `SeededRNG` through
  `DecisionContext`.
- **State hash** (`EngineCore/StateHash.swift`). SHA-256 is implemented in pure Swift (FIPS 180-4), not
  CryptoKit, so the digest stays Linux-portable and byte-identical to standard SHA-256. It is stored as
  lowercase hex.

**Canonical-encoding rules** (this closes the earlier follow-up). Any type that feeds
`StateHash.canonical(_:)` must follow them:

1. Encode with `JSONEncoder` using `[.sortedKeys, .withoutEscapingSlashes]`. `StateHash.canonical` does
   this for you.
2. Never encode a `Set` directly. Synthesized `Set` encoding follows hash order, which Swift randomizes
   per process. `Zone.faceUp` is encoded as an array sorted by `PieceID.raw`.
3. Never encode a dictionary with non-`String` keys directly. These encode as arrays in hash order.
   `KlondikeState.faces` and `CrazyEightsState.faces` are encoded as entry arrays sorted by `PieceID.raw`.
4. No wall-clock values in hashed state. Timestamps live only in `LogMetadata`; Klondike's timer and move
   counter live in `KlondikeSession`, outside the authoritative state.

`StateHashTests`, the replay invariant in `parlor-sim`, and the Persistence round-trip tests enforce the
contract. The save-format and state-type ADR trigger in `structure.md` still applies when any of these
types change.
