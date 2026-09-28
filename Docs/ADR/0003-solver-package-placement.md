# ADR 0003 — Solver package placement (`SolverKit`)

- **Status:** Accepted (Spec 2 baseline)
- **Date:** 2026-10-19
- **Context spec:** `/.kiro/specs/02-solitaire-collection/`
- **Relates to requirements:** R-SOLVER-2, R-SOLVER-1, R-SOLVER-3, R-WINNABLE-1, R-DAILY-1, R-KLON2-1, R-NFR-SOLVER, R-NFR-DOC.1
- **Supersedes / superseded by:** none

## Context

Spec 2 introduces a shared deal **solver** that classifies a deal as winnable / unwinnable / unknown for
Klondike, FreeCell, Spider (1- and 2-suit at least), Pyramid, and TriPeaks (R-SOLVER-1). The solver has an
unusually broad set of consumers:

- the **Games rules targets** (Klondike retrofit hints, and the four new solitaires), for solver-backed
  hints (R-KLON2-1);
- **`Scripts/`** seed-pool generation, which runs the solver in bulk to build the ≥ 10,000-deal winnable
  pools per game/variant (R-WINNABLE-1);
- **`SimulationCLI`** (`parlor-sim`), which may use the solver as an oracle in invariant checks
  (R-QA2-3, R-QA2-4);
- potentially **AIKit**, if a future solitaire AI or coach wants a solved line.

`tech.md` architecture rule 1 requires all rules/AI code to be **pure** (Swift standard library and
Foundation only, no Apple-only UI frameworks) so it stays portable to a future Linux server; the solver
must obey the same rule (R-SOLVER-2.1). The solver must also introduce **no `EngineCore` or `TableKit`
public-API change** (per `tech.md` rule 9; R-SETUP2-1.3), and must slot into the lint-enforced dependency
direction (`structure.md`). Requirements deliberately deferred the choice of solver placement to
`design.md` (R-SOLVER-2.2, Assumption A2-11, Open Question Q2-7).

Two placements were considered:

1. **Inside `AIKit`.** Simplest: no new package, no dependency-diagram change. But it forces every solver
   consumer to depend on all of AIKit (determinization, ISMCTS, personas, pacing), couples the solitaire
   solver to the multi-seat AI toolkit it does not use, and makes `Scripts/` seed generation and
   `SimulationCLI` pull in AIKit purely to reach the solver. It also blurs the responsibility line: AIKit
   is "how a seat decides a move," whereas the solver is "is this deal winnable at all."
2. **A new pure package `Packages/SolverKit`.** A focused, single-responsibility package in the pure tier
   that depends only on `EngineCore`. Rules targets, AIKit, `SimulationCLI`, and the `Scripts/` generator
   can each depend on it directly without dragging in unrelated code. It keeps the solver Linux-portable
   and independently testable to the ≥ 90 % coverage bar (R-QA2-6.1). The cost is one new package, one new
   node in the enforced dependency graph, and a required update to `Docs/Architecture.md`.

## Decision

1. **Add `Packages/SolverKit`, a pure package** (Swift standard library + Foundation only), in the same
   tier as `EngineCore`/`AIKit`. It depends only on `EngineCore` and consumes only public
   `GameDefinition`/state/action surfaces, so **no `EngineCore` or `TableKit` public-API change is
   required** (R-SOLVER-2.1, R-SETUP2-1.3).
2. **Enforced dependency direction gains these edges** (all downward, acyclic):
   `SolverKit → EngineCore`; `Games rules targets → SolverKit`; `AIKit → SolverKit`;
   `SimulationCLI → SolverKit`; and the `Scripts/` seed-pool generator (built as a small executable
   target) `→ SolverKit`. `SolverKit` does **not** depend on `AIKit`, keeping the graph acyclic.
3. **`Docs/Architecture.md` is updated in the same task that introduces `SolverKit`** (R-NFR-DOC.1): the
   layered module map mermaid diagram adds the `SolverKit` node and the edges above, and the module list
   gains a one-line description. The lint dependency-direction allow-list is updated to permit exactly
   these edges and no others. The precise diff is specified in
   `/.kiro/specs/02-solitaire-collection/design.md` §1.
4. **Solver determinism and budget discipline follow ADR 0002.** The solver reuses the ADR-0002
   `SeededRNG` + Fisher–Yates for any deal regeneration and the canonical, wall-clock-free state-hash
   discipline for its transposition table; a timeout is modeled as a deterministic node/iteration cap, not
   solely elapsed real time, so classifications are reproducible (R-SOLVER-1.4, R-NFR-SOLVER.3).

## Consequences

- **Positive:** the solver is a focused, reusable, Linux-portable unit; consumers depend only on what they
  use; seed generation and `parlor-sim` avoid pulling in AIKit; the solver is independently coverable to
  ≥ 90 %. No engine/table API change is required, preserving multiplayer readiness.
- **Negative / risks:** one more package and one more enforced dependency edge to maintain; the
  Architecture.md map and the lint allow-list must be updated together with the package (tracked as an
  explicit `tasks.md` item so the doc never drifts).
- **Follow-ups:** if profiling later shows the solver needs a data structure that only `EngineCore` can
  provide efficiently, that would be a separate ADR (an `EngineCore` public-API change); this ADR
  deliberately keeps `SolverKit` on the existing public surface.
