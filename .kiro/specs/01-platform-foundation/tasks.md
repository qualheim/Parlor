# Tasks — 01 Platform Foundation

Implementation plan for `requirements.md` / `design.md`. Tasks are small and incremental. **Every task
ends with `make build test lint` passing** (Swift 6 strict concurrency, zero warnings — R-BUILD-5) and
cites the requirement IDs it satisfies. Ordering reaches a working vertical slice early. **Checkpoint**
tasks are review gates: implementation pauses for the user to run the app and approve before continuing.

Legend: 🎨 = produces a **placeholder asset flagged "needs production art"** (R-DS-6, R-DS-4.2).

---

## Phase 1 — Scaffold, build pipeline, empty window

- [x] **1.1 Repo scaffold + XcodeGen + package graph.** Create the `structure.md` layout: `project.yml`,
  empty Swift packages (`EngineCore`, `AIKit`, `Games`, `TableKit`, `DesignSystem`, `Persistence`,
  `SimulationCLI`) with dependencies wired per the enforced direction, and the thin `App/` target.
  _(R-BUILD-1.1, R-BUILD-1.2, R-BUILD-1.3, R-BUILD-1.4)_
- [x] **1.2 Makefile targets.** Implement `bootstrap`, `generate`, `build`, `test`, `test-long`, `lint`,
  `format`, `run`, `sim`. `bootstrap` checks for/installs Xcode CLT + XcodeGen then generates the project;
  `run` builds and launches with local signing. _(R-BUILD-2.1, R-BUILD-2.2, R-BUILD-2.3, R-BUILD-2.4)_
- [x] **1.3 Entitlements + privacy manifest.** App Sandbox + Hardened Runtime on, no network entitlements;
  add `PrivacyInfo.xcprivacy` (no tracking/collection, required-reason for UserDefaults) and
  `Parlor.entitlements`. _(R-BUILD-3.1, R-BUILD-3.2, R-BUILD-3.3)_
- [-] **1.4 Lint scripts.** `Scripts/` checks that fail on forbidden imports/APIs, on UI-framework imports
  inside EngineCore/AIKit/rules targets, on dependency-direction violations, and on unexpected
  entitlements; wire into `make lint` alongside `swift-format --check`. _(R-BUILD-4.1, R-BUILD-4.2,
  R-BUILD-4.3, R-BUILD-4.4, R-BUILD-3.4)_
- [~] **1.5 Empty window + logging.** Thin SwiftUI app opens an empty window (min 1024×700), standard menu
  bar skeleton, `os.Logger` categories, debug-only FPS/state-inspector overlay hook. 🎨 placeholder app
  icon. _(R-APP-6.4, R-NFR-QUAL.4, R-DS-6.1)_
- [~] **⛳ CHECKPOINT 1.** User runs `make bootstrap && make run`: an empty, sandboxed window launches;
  `make lint` and `make build test` pass green. Review before Phase 2.

## Phase 2 — EngineCore with tests

- [~] **2.1 Components + identity.** `PieceID`, `Card`/`CardFace`, `Tile`/`TileFace`; unique identity
  distinct from face; no rank/points/suit baked in. _(R-ENG-1.1, R-ENG-1.2, R-ENG-1.3)_
- [~] **2.2 Deck/set definitions + composition tests.** `DeckDefinition` as data for standard-52, 52+jokers,
  Euchre-24, Sheepshead-32, Spider-104, Pinochle-48, Tile-Rummy-106, each with a composition test; add the
  `CardSemantics` extension point. _(R-ENG-2.1, R-ENG-2.2, R-ENG-2.3)_
- [~] **2.3 Zones + visibility.** `Zone`, `ZoneID`, `Visibility` (hidden/ownerOnly/public/topCardOnly/
  perPieceFaceState). _(R-ENG-3.1, R-ENG-3.2)_
- [~] **2.4 RNG + Fisher–Yates + determinism test.** `SeededRNG` (SplitMix64→xoshiro256\*\* per ADR 0002),
  unbiased Fisher–Yates; determinism test (same seed+log → identical hash). _(R-ENG-4.1, R-ENG-4.2,
  R-ENG-4.3, R-ENG-4.4)_
- [~] **2.5 GameDefinition protocol + RuleViolation.** Metadata, options schema + presets, initial state,
  phases, `legalActions`, `apply` → events or typed `RuleViolation`, terminal/outcome. _(R-ENG-5.1–5.6,
  R-NFR-QUAL.1)_
- [~] **2.6 Events + Views/redaction + tokens.** Codable `GameEvent` set; `Viewer`, `ViewToken`,
  `PlayerView`; per-view token permutation; `pieceRevealed` binding. _(R-ENG-8.1–8.5)_
- [~] **2.7 Match structure + action log.** Match→hands→phases→turns, dealer rotation, cumulative scores,
  end conditions, per-hand summaries; ordered log (seat, action, state hash, metadata); undo policies
  incl. Practice Mode. _(R-ENG-6.1–6.3, R-ENG-7.1–7.4)_
- [~] **2.8 View-leak property test.** Random states × every viewer → serialized view leaks no hidden
  identity. _(R-QA-3.1)_

## Phase 3 — Minimal TableKit + Klondike playable (placeholder visuals)

- [~] **3.1 Klondike rules.** `GameDefinition` for `klondike`: deal, tableau build-down alt-color,
  foundations up-by-suit, movable sequences, King-to-empty, foundation→tableau; options (Draw 1/3, scoring
  Standard/Vegas/None, passes, timed); unlimited undo/redo. Author `Docs/Rules/klondike.md` (original
  writing; mark Q-1/Q-2 items NEEDS REVIEW). _(R-KLON-1.\*, R-KLON-2.\*, R-KLON-3.4, R-NFR-DOC.1)_
- [~] **3.2 Klondike scenario tests.** Given/When/Then per rule/option, traceable to the rules doc.
  _(R-QA-1.1)_
- [~] **3.3 Minimal TableKit renderer.** Declarative layout → positions; event-stream-driven deal/move/
  flip/collect with no per-game animation code; placeholder rectangle card views. _(R-TABLE-1.1, R-TABLE-1.2)_
- [~] **3.4 Input paths + illegal feedback.** Drag single + stacks, click-select-then-place, double-click
  smart move, keyboard nav (focus/select/place/cancel), right-click "why can't I play this?"; illegal →
  spring-back + shake + caption from `RuleViolation` (no dialog); highlight legal targets. _(R-TABLE-3.1–3.6,
  R-TABLE-4.1)_
- [~] **3.5 Klondike features.** Auto-flip; auto-move Off/Safe/Always; smart move; auto-complete; no-moves
  detection (inline banner → undo/restart/new); restart same deal; numbered "Play deal #…"; timer + move
  counter; heuristic hints. _(R-KLON-3.1, R-KLON-3.2, R-KLON-3.3, R-KLON-3.5, R-KLON-3.6, R-KLON-3.7,
  R-KLON-3.8)_
- [~] **⛳ CHECKPOINT 2.** User plays Klondike end-to-end with placeholder visuals via drag *and* keyboard,
  undo/redo, hints. Review before Phase 4.

## Phase 4 — GameHost, controllers, AI framework, Crazy Eights

- [~] **4.1 GameHost actor + transport envelope.** Sole state mutator owning RNG + log; Codable
  `ClientMessage`/`HostMessage` over in-process `Transport`; submit → accepted/rejected + views + events.
  _(R-SESS-1.1, R-SESS-1.2, R-SESS-4.1, R-SESS-4.2)_
- [~] **4.2 Controllers + turn models.** `PlayerController` async API; `LocalHumanController`,
  `AIController`; sequential/simultaneous/out-of-turn models with optional timeouts (default none);
  document the `RemoteController` seam (no networking). _(R-SESS-2.1–2.4, R-SESS-3.1–3.4)_
- [~] **4.3 Profiles + concurrent sessions.** Player profiles (id/name/avatar/controller), editable local
  profile, bundled personas; verify two independent `GameHost` sessions run at once. 🎨 placeholder
  avatars. _(R-SESS-5.1, R-SESS-5.2, R-SESS-6.1, R-DS-6.1)_
- [~] **4.4 AIKit toolkit + information barrier.** Strategy API taking only `(PlayerView, publicLog,
  legal)`; determinization sampler (incl. inferred voids), Monte Carlo, ISMCTS, evaluator helpers;
  time-budgeted, cancellable, off-main-actor, injected RNG; pacing (Instant/Fast/Normal/Relaxed,
  independent of animation speed); personas; hint interface. _(R-AI-1.1, R-AI-2.1, R-AI-2.2, R-AI-3.1–3.3,
  R-AI-4.1, R-AI-4.2, R-AI-5.1, R-AI-6.1, R-AI-6.2)_
- [~] **4.5 Crazy Eights rules.** `GameDefinition` for `crazy-eights`: 2–5 players, deal 7/5, starter
  (bury 8), match on suit/rank, 8 wild + name suit, draw-until/draw-one option, stock-out reshuffle/end
  option, scoring (8=50, KQJ=10, A=1, else face), target 100 configurable, action-cards option off by
  default. Author `Docs/Rules/crazy-eights.md` (original writing; mark Q-3/Q-4/Q-5 NEEDS REVIEW).
  _(R-CE-1.\*, R-CE-2.\*, R-CE-3.\*, R-CE-4.1, R-NFR-DOC.1)_
- [~] **4.6 Crazy Eights AI + scenario tests.** Easy/Medium/Hard (Hard = determinized Monte Carlo); hint;
  Given/When/Then tests per rule/option traceable to the rules doc. _(R-CE-5.1, R-CE-5.2, R-CE-5.3,
  R-QA-1.1)_
- [~] **⛳ CHECKPOINT 3.** User plays a full Crazy Eights hand vs AI (hidden hands, per-viewer views, turn
  flow, thinking indicator). Review before Phase 5.

## Phase 5 — Design system, themes, animation polish, sound

- [~] **5.1 Tokens + chrome.** Color/type/spacing/radius/shadow/motion tokens; light/dark chrome; WCAG 2.2
  AA contrast; semantic-color-only. _(R-DS-1.1, R-DS-1.2)_
- [~] **5.2 Themes + shaders.** ≥ 4 procedural table themes (Classic Felt, Midnight, Walnut Parlor,
  Minimal) via Metal shaders; themes independent of system appearance; height-scaled shadows. _(R-DS-2.1,
  R-DS-2.2, R-TABLE-1.3)_
- [~] **5.3 Deck styles + backs + card faces.** Classic/Modern/Four-Color/Jumbo Index; ≥ 6 backs; 🎨
  original placeholder court-card designs; cached vector faces keyed by (theme,face,scale,appearance).
  _(R-DS-3.1, R-DS-3.2, R-DS-3.3, R-TABLE-2.1, R-TABLE-2.2)_
- [~] **5.4 Theme-pack loader.** JSON manifest + vector assets + audio, runtime-switchable without restart;
  🎨 placeholder packs flagged "needs production art". _(R-DS-4.1, R-DS-4.2)_
- [~] **5.5 Animation queue polish.** Speed setting (Relaxed/Normal/Fast/Instant), click/keypress
  fast-forward, non-blocking; Reduce Motion → crossfades, no parallax/particles; 150–350 ms springs.
  _(R-TABLE-5.1, R-TABLE-5.2, R-TABLE-5.3)_
- [~] **5.6 HUD components.** Seat plates (avatar/name/score/dealer/role/active-glow/thinking), scoreboard,
  caption bar, history drawer, pause menu, toolbar (New/Undo/Hint/Rules/Menu); local player bottom-center,
  others clockwise; HUD never covers needed cards. _(R-TABLE-6.1, R-TABLE-6.2, R-TABLE-6.3)_
- [~] **5.7 Sound engine.** Event-driven cues (shuffle/deal/flip/place/chips/win) with randomized
  variations (never twice in a row), effects/ambience volumes, master mute, mute-in-background; 🎨 audio
  original/CC0/synthesized, noted in `THIRD_PARTY_NOTICES.md`. _(R-DS-5.1, R-DS-5.2)_
- [~] **5.8 Klondike win celebration.** ≤ 3 s skippable cascading-cards homage + modern flourish
  (SpriteKit overlay). _(R-KLON-3.9)_
- [~] **⛳ CHECKPOINT 4.** User switches themes/decks live, hears sound, sees polished motion and the win
  celebration. Review before Phase 6.

## Phase 6 — Persistence, statistics, settings, library

- [~] **6.1 Versioned save + autosave/resume.** Codable save (schema-versioned) written after every
  accepted action; relaunch resumes exactly, incl. mid-hand vs AI; local sandbox container only. _(R-PERS-1.1,
  R-PERS-1.2, R-PERS-3.1)_
- [~] **6.2 Migration + corruption handling + round-trip test.** Version migration registry + tests;
  corrupted/incompatible save → non-modal notice + discard, no crash; save/restore round-trip test.
  _(R-PERS-2.1, R-PERS-2.2, R-QA-4.1)_
- [~] **6.3 Statistics + Swift Charts.** Per game/variant: played, won, win %, current/best streak, best
  score, best time, game-specific metrics; Swift Charts visualization; confirm-on-reset; Practice Mode
  excluded. _(R-APP-4.1, R-APP-4.2, R-APP-4.3, R-ENG-7.4)_
- [~] **6.4 Settings.** Appearance (theme/deck/back/card size S/M/L/XL), gameplay (animation speed, AI
  pace, auto-moves, hints, confirmations), sound, accessibility overrides, player profile. _(R-APP-5.1)_
- [~] **6.5 Library + catalog + setup sheet.** Continue hero, family groups, filters (family/count/
  duration), favorites, recently played; feature-flagged catalog (unbuilt games hidden); 🎨 placeholder
  game-tile art with hover parallax; setup sheet (presets first, options + house rules grouped, opponent
  setup, remember choices). _(R-APP-1.1, R-APP-1.2, R-APP-1.3, R-APP-2.1, R-APP-2.2, R-DS-6.1)_
- [~] **6.6 Table screen + rules inspector + macOS integration.** Full-bleed table, quiet toolbar, HUD,
  pause menu; in-place rules inspector from `Docs/Rules/<game-id>.md`; menu bar + shortcuts, full screen,
  window restoration, multi-window independent games, About + third-party notices; ≤ 3-step first-run
  tour; "Replay last game" (Should). _(R-APP-3.1, R-APP-3.2, R-APP-6.1, R-APP-6.2, R-APP-6.3, R-APP-7.1,
  R-PERS-4.1)_
- [~] **⛳ CHECKPOINT 5.** User browses the library, configures a game, quits and resumes mid-hand, views
  stats. Review before Phase 7.

## Phase 7 — Accessibility

- [~] **7.1 VoiceOver.** Meaningful label/value/hint for every card/tile/pile/control; custom rotors for
  hands and piles; announce opponent actions and results. _(R-A11Y-1.1, R-A11Y-1.2)_
- [~] **7.2 Keyboard-only play.** Full keyboard play for both games and every flow, visible focus
  indicator. _(R-A11Y-2.1)_
- [~] **7.3 Color independence + system settings.** Suit shapes always present, Four-Color deck; respect
  Reduce Motion/Reduce Transparency/Increase Contrast; card sizes S/M/L/XL. _(R-A11Y-3.1, R-A11Y-4.1)_
- [~] **7.4 Accessibility UI tests.** Keyboard-only completion of Klondike (debug near-win) and a Crazy
  Eights hand; XCUITest accessibility audits on library/setup/table. _(R-A11Y-5.1, R-A11Y-5.2)_
- [~] **⛳ CHECKPOINT 6.** User completes both games with VoiceOver + keyboard only. Review before Phase 8.

## Phase 8 — Quality gates, performance, docs

- [~] **8.1 parlor-sim + invariants.** AI-vs-AI and random-legal runs checking piece conservation,
  only-legal-actions, bounded length, scoring consistency, deterministic replay; `make test` = 500
  games/game, `make test-long` = 10,000; `Scripts/` seed-pool generation. _(R-QA-2.1, R-QA-2.2)_
- [~] **8.2 Full UI test suite.** Library → setup → Klondike (drag + keyboard) → undo → win from debug
  near-win seed; full Crazy Eights hand vs AI; theme/deck change; quit & resume. _(R-QA-5.1)_
- [~] **8.3 Performance tests.** Launch, deal animation, AI decision time vs `tech.md` budgets; profile the
  104-card stress scene; if a budget fails, stop and extend ADR 0001 with benchmark data. _(R-QA-6.1,
  R-TABLE-7.1, R-TABLE-7.2, R-NFR-PERF.\*)_
- [~] **8.4 Coverage gate.** ≥ 90% line coverage for EngineCore and both rules targets; enforce in
  `make test`. _(R-QA-7.1)_
- [~] **8.5 Docs finalize + placeholder audit.** Update `Docs/Architecture.md` and both rules docs; confirm
  ADR 0001/0002 match implementation; verify every 🎨 placeholder is flagged "needs production art" and
  listed for replacement; resolve or re-affirm Open Questions Q-1..Q-8. _(R-NFR-DOC.1, R-NFR-DOC.2,
  R-DS-4.2, R-DS-6.1)_
- [~] **⛳ CHECKPOINT 7 (final).** User runs `make test-long`; all quality gates, performance budgets, and
  accessibility audits pass; foundation is proven by Klondike + Crazy Eights.

---

## Placeholder-art register (needs production art — R-DS-6, R-DS-4.2)

Tracked here and re-audited in task 8.5:

- App icon (task 1.5) 🎨
- Player/persona avatars (task 4.3) 🎨
- Court-card designs / deck faces (task 5.3) 🎨
- Theme packs' vector art + audio (tasks 5.4, 5.7) 🎨
- Game-tile artwork (task 6.5) 🎨

## Traceability note

Every task lists the requirement IDs it implements; every requirement in `requirements.md` is covered by
at least one task above. Open Questions (Q-1..Q-8) must be resolved before their dependent tasks (3.1,
4.5, 6.6) are marked complete.
