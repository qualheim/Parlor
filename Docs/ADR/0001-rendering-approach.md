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
   (R-TABLE-2.1). Memory stays bounded by the key space: sizes are quantized into scale buckets, so the
   number of distinct images is finite. The cache can be dropped wholesale (`clear()`); per-key eviction
   is not implemented (see *Implementation status* below).
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

## Task 8.3 benchmark addendum — 2026-10-04

The required performance gate was run on an arm64 `Mac17,3` with 16 GiB RAM and 10 logical CPUs
(Xcode 27.0 / Swift 6.4). The headless measurements below are Debug SwiftPM measurements; they are
useful regression evidence but are not a substitute for the release-build baseline in `tech.md`.

- **104-card layout resolution:** 20–34 µs per measured iteration, below the 16.67 ms frame budget.
  XCTest reported a 36,773 kB peak physical footprint for the stress test, below the 400 MB memory cap.
- **104-card deal reduction + frame resolution:** 92–105 µs per measured iteration, below the 16.67 ms
  frame budget.
- **104-card input feedback reduction + frame resolution:** 64–79 µs per measured iteration, below the
  50 ms input-to-visual-feedback budget.
- **Hard Crazy Eights decision:** 20 real decisions through the redacted-view `DecisionContext` using the
  default Hard strategy. The p95 was **1.00210975 s**, exceeding the **1.0 s** p95 budget. The measured
  samples were `[1.001069375, 1.000399125, 1.000248084, 1.001912833, 1.001193333, 0.000012958,
  1.000480333, 1.00210975, 1.001831375, 1.000431959, 1.000676542, 1.001569542, 1.000807958,
  1.000637541, 1.000844417, 1.001554958, 1.001044125, 1.001680709, 1.000934542, 1.002496958]`.
  Nineteen samples reached the one-second compute deadline; one forced-move sample short-circuited in
  approximately 13 µs. This is a real budget failure, not a renderer measurement, so task 8.3 stops here.

No rendering approach was changed. The AI gate failure does not demonstrate that SwiftUI cannot meet its
budget, and therefore does not trigger a switch to `MTKView` or SpriteKit. Cold-launch and on-screen
104-card frame/memory profiles were intentionally not run after the first failed budget, per task 8.3's
stop rule. The Hard-tier compute path must be optimized or otherwise explicitly resolved before the
performance gate can be marked complete.

**Resolution (task 8.5 re-run, 2026-10-04).** The Hard strategy now stops searching
`deadlineHeadroomSeconds` (50 ms) before the caller's deadline, so finishing the in-flight rollout and
picking the move no longer overshoots the 1.0 s budget. `testHardDecisionP95StaysWithinOneSecond` passes
in `make test` on the same machine (20 samples, Debug SwiftPM). The fix is AI-side only; no rendering
approach changed. The release-build M1 baseline, cold launch, and on-screen 104-card frame/memory
profiles are still to be run by the user at Checkpoint 7 (`UITests/PerformanceUITests.swift`).

## Implementation status (task 8.5 audit)

Checked against the code at foundation sign-off:

- **Decision 1 — SwiftUI renderer, stable identity.** Matches. `TableView` and `TableInteractionView`
  key every piece with `matchedGeometryEffect(id: piece.key, …)`; layout comes from `LayoutResolver`
  and motion from the event-driven `TableRenderModel` + `AnimationDriver`.
- **Decision 2 — cached vector faces.** Matches, with one refinement. `CardFaceCache` rasterizes
  `CardFaceCanvas` once per `CardFaceKey` (theme, deck style, face, scale bucket, appearance) through
  `ImageRenderer` and reuses the image afterwards. There is no LRU eviction; the cache can only be
  cleared wholesale. Add eviction if profiling ever shows memory pressure.
- **Decision 3 — Metal materials.** Matches. `TableMaterials.metal` (felt, wood, matte) is applied via
  SwiftUI `colorEffect` with `ShaderLibrary.default`. The app compiles the shader source; SwiftPM only
  copies it as a resource.
- **Decision 4 — SpriteKit only for overlays.** Matches. The only `SKScene` is the Klondike win
  celebration (`KlondikeWinCelebrationView`).
- **Decision 5 — identity across reveal.** Matches. `TableRenderModel` rebinds a token's node to the
  revealed identity on `pieceRevealed`.
- **Decision 6 — animation queue.** Matches. `AnimationQueue` honors Relaxed/Normal/Fast/Instant,
  fast-forwards, and swaps movement for crossfades under Reduce Motion.

## Consequences

- **Positive:** inherits macOS look and accessibility; games avoid bespoke animation code; faces are
  cheap after first cache; materials scale crisply to 6K.
- **Negative / risks:** SwiftUI animation throughput under 104 pieces during simultaneous drag+deal is the
  main risk; mitigated by identity stability, image caching, and the stress scene as an early warning.
- **Follow-ups:** headless stress-scene numbers are recorded above. Still open: the release-build M1
  baseline and on-screen frame/memory profile of the 104-card stress scene (Checkpoint 7), and
  per-key cache eviction if that profile shows a need.
