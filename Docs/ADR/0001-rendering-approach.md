# ADR 0001 — Rendering approach

- **Status:** Accepted (foundation baseline)
- **Date:** 2026-09-28
- **Context spec:** `/.kiro/specs/01-platform-foundation/`
- **Relates to requirements:** R-TABLE-1, R-TABLE-2, R-TABLE-5, R-TABLE-7, R-NFR-PERF
- **Supersedes / superseded by:** none

## Context

Parlor's north star is "a beautifully lit card table in a private club": richness from light, material,
depth, and motion, without clutter (`ux-guidelines.md`). `tech.md` mandates a SwiftUI-first table with
lightweight card/tile views, motion via SwiftUI animations/springs/matched geometry, and visual effects
via Metal shaders through SwiftUI's shader APIs. It also sets hard performance budgets (≥ 60 fps including
104-card layouts, ≤ 50 ms input feedback, ≤ 400 MB) and requires that, if profiling shows SwiftUI cannot
meet a budget, we stop and write an ADR with benchmark data before changing approach.

We need one decision that (a) satisfies these constraints, (b) lets a new game get deal/move/flip/collect
animation without custom animation code, and (c) keeps card faces from being redrawn every frame.

## Decision

1. **SwiftUI is the primary renderer.** Cards and tiles are lightweight SwiftUI views with **stable
   identity**; motion uses SwiftUI springs and `matchedGeometryEffect`. A generic renderer is driven by
   each game's declarative layout plus the host's event stream, so games get standard animations for free
   (R-TABLE-1).
2. **Vector faces cached as images.** Faces and backs are drawn as vectors (e.g. SwiftUI `Canvas`) and
   cached as images keyed by `(theme, face, scale, appearance)`. Faces are never redrawn per frame
   (R-TABLE-2.1). The cache is bounded and evicts by scale/appearance to respect the memory budget.
3. **Metal shaders for materials.** Felt fiber/vignette, wood rails, brass/leather accents, and card sheen
   use Metal shaders through SwiftUI's shader APIs — procedural, not large bitmaps (R-TABLE-1.3; R-DS-2.1).
4. **SpriteKit only for overlays.** Particle/physics effects (e.g. the win celebration) may use SpriteKit
   hosted in SwiftUI; it is never the table renderer (`tech.md`).
5. **Identity continuity across reveal.** On a `pieceRevealed` event the on-screen node is rebound from
   its opaque token to the real face so the flip stays continuous without leaking identity beforehand
   (R-ENG-8.4).
6. **Animation queue.** A queue sequences events, honors the speed setting (Relaxed/Normal/Fast/Instant),
   supports fast-forward on click/keypress, and never blocks input longer than the animation currently
   playing (R-TABLE-5). Reduce Motion replaces movement with crossfades and disables parallax/particles.

## Fallback trigger (binding)

A **104-card stress scene** (R-TABLE-7.2) is the standing profiling harness. IF profiling on the baseline
(M1 MacBook Air, release build) shows SwiftUI cannot hold a budget in R-NFR-PERF, THEN implementation
stops and a follow-up ADR is written **with benchmark data** before any approach change (e.g. moving a hot
path to a `MTKView`/SpriteKit-hosted layer). No approach change happens without that ADR (`tech.md`).

## Consequences

- **Positive:** inherits macOS look and accessibility; games avoid bespoke animation code; faces are
  cheap after first cache; materials scale crisply to 6K.
- **Negative / risks:** SwiftUI animation throughput under 104 pieces during simultaneous drag+deal is the
  main risk; mitigated by identity stability, image caching, and the stress scene as an early warning.
- **Follow-ups:** benchmark the stress scene as soon as TableKit can render it; record numbers here.
