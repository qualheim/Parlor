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
- **Follow-ups:** document the exact canonical-encoding rules alongside the `StateHash` implementation and
  add a cross-run (and, when available, cross-platform) determinism CI check.
