# Requirements — 01 Platform Foundation

## Introduction

This spec defines the production-quality foundation for **Parlor** and proves it end-to-end with two
reference games. The foundation must be complete enough that every later game on the roadmap
(`product.md`, Specs 2–8) can be added by writing **game-specific modules only** — a `GameDefinition`,
AI strategies, a table layout, a rules document, and a catalog registration — with no changes to
`EngineCore` or `TableKit` (`tech.md` architecture rule 9; `structure.md` conventions).

- **Klondike Solitaire** proves solo play: drag and drop, unlimited undo/redo, hints, scoring, timer,
  and statistics.
- **Crazy Eights** proves the multiplayer-ready architecture: multiple seats, hidden hands, AI
  opponents, sequential turn flow, per-viewer redacted views, match scoring, and save/resume mid-hand.

### Binding source documents

The four steering documents are binding and are **not restated** here; requirements trace back to them:

- `product.md` — vision, audience, product principles, roadmap, Definition of Done, non-goals.
- `tech.md` — platform, rendering, architecture rules 1–9, security/privacy, dependencies, build/tooling,
  testing, performance budgets, code conventions.
- `structure.md` — repository layout, enforced dependency direction, conventions.
- `ux-guidelines.md` — north star, platform, visual language, motion, interaction, table conventions,
  learning/help, accessibility, sound, voice/copy.

### Terminology

Terms (Seat, Player, Controller, Host, View, Zone, Action, Event, Hand, Match) are used as defined in
the `product.md` Glossary.

### EARS conventions

Acceptance criteria use EARS keywords: **WHEN** (event), **WHILE** (state), **IF/THEN** (unwanted
condition / decision), **WHERE** (feature is included), and ubiquitous **SHALL**. Each requirement has a
stable ID (`R-<area>-<n>`). IDs are referenced by `design.md` and `tasks.md` and must not be renumbered
once merged.

---

## 1. Project and build

### R-BUILD-1 — Repository layout and packages
**User story:** As a maintainer, I want the repository laid out exactly as `structure.md` prescribes, so
that dependency direction is enforceable and later games slot in predictably.

- R-BUILD-1.1 The repository SHALL contain the top-level layout defined in `structure.md`
  (`project.yml`, `Makefile`, `App/`, `Packages/{EngineCore, AIKit, Games, TableKit, DesignSystem,
  Persistence, SimulationCLI}`, `Assets/ThemePacks/`, `Docs/`, `Scripts/`, `UITests/`).
- R-BUILD-1.2 Nearly all code SHALL live in local Swift packages; the `App/` target SHALL be a thin shell
  (per `tech.md` build/tooling), so `swift build` and `swift test` run headless.
- R-BUILD-1.3 The Xcode project SHALL be generated from `project.yml` via XcodeGen; the `.pbxproj` SHALL
  never be hand-edited (per `tech.md`).
- R-BUILD-1.4 The package graph SHALL match the enforced dependency direction in `structure.md`; a build
  or lint step SHALL fail if a package imports outside its allowed direction.

### R-BUILD-2 — Makefile targets
**User story:** As a developer, I want every workflow to run headless from a terminal, so CI and local
runs behave identically.

- R-BUILD-2.1 The `Makefile` SHALL provide all targets named in `tech.md`: `bootstrap`, `generate`,
  `build`, `test`, `test-long`, `lint`, `format`, `run`, `sim`.
- R-BUILD-2.2 WHEN `make bootstrap` runs, it SHALL check for the required tools (Xcode command line
  tools, XcodeGen) and install any that are missing or absent, then generate the Xcode project.
- R-BUILD-2.3 WHEN `make run` runs, it SHALL build and launch the app using local (ad-hoc) signing.
- R-BUILD-2.4 WHEN `make test` runs, it SHALL execute the fast test sample headlessly (see R-QA-2);
  WHEN `make test-long` runs, it SHALL execute the full-volume suite (see R-QA-2).

### R-BUILD-3 — Entitlements and offline posture
**User story:** As a privacy-focused user, I want the app fully sandboxed and offline, so no data ever
leaves my Mac.

- R-BUILD-3.1 The app SHALL enable App Sandbox and Hardened Runtime (per `tech.md`).
- R-BUILD-3.2 The app SHALL declare no network entitlements (client or server) (per `tech.md`).
- R-BUILD-3.3 The app SHALL ship a `PrivacyInfo.xcprivacy` declaring no tracking and no collected data,
  with a required-reason declaration for every such API used (e.g. UserDefaults) (per `tech.md`).
- R-BUILD-3.4 IF any entitlement other than the expected set is present, THEN `make lint` SHALL fail.

### R-BUILD-4 — Lint and forbidden imports/APIs
**User story:** As a maintainer, I want the architecture and privacy rules enforced automatically, so
violations cannot be merged.

- R-BUILD-4.1 WHEN `make lint` runs, it SHALL run `swift-format` in check mode against the checked-in
  config (per `tech.md`).
- R-BUILD-4.2 `make lint` SHALL fail on any forbidden import or API from `tech.md`
  (`URLSession`, `Network`, `WebKit`, `CFNetwork`, `MultipeerConnectivity`, `GameKit`, `CloudKit`, and any
  analytics/crash-reporting SDK).
- R-BUILD-4.3 `make lint` SHALL fail on any UI-framework import (SwiftUI, AppKit, SpriteKit, Combine, or
  other Apple-only UI framework) inside `EngineCore`, `AIKit`, or any rules target (per `tech.md`
  architecture rule 1).
- R-BUILD-4.4 `make lint` SHALL fail on any unexpected entitlement (implements R-BUILD-3.4).

### R-BUILD-5 — Warnings and concurrency
**User story:** As a maintainer, I want a clean, concurrency-safe build, so latent races and drift never
accumulate.

- R-BUILD-5.1 The project SHALL compile in Swift 6 language mode with complete strict-concurrency
  checking (per `tech.md`).
- R-BUILD-5.2 The build SHALL produce zero compiler warnings; a warning SHALL be treated as a build
  failure (per `tech.md`).

---

## 2. Engine core (EngineCore)

### R-ENG-1 — Components with unique identity
**User story:** As a rules author, I want every physical piece to carry a unique identity, so a double
deck's two identical faces can be told apart.

- R-ENG-1.1 EngineCore SHALL define `Card` (a rank+suit, or a joker) and `Tile` (a number+color, or a
  joker) as value types.
- R-ENG-1.2 Every piece instance SHALL carry a unique, stable identity distinct from its face value, so
  the two queens of spades in a double deck are distinguishable.
- R-ENG-1.3 The `Card`/`Tile` types SHALL NOT hard-code rank order, point values, or effective suit; each
  game supplies these (see R-ENG-2).

### R-ENG-2 — Deck/set definitions as data, with composition tests
**User story:** As a rules author, I want decks and sets described as data with per-game semantics, so I
never edit the piece type to add a game.

- R-ENG-2.1 Deck and set definitions SHALL be data (not hard-coded into `Card`/`Tile`).
- R-ENG-2.2 EngineCore SHALL provide, each with a composition test, at least: standard 52; 52 + jokers;
  Euchre 24 (9–A); Sheepshead 32 (7–A); Spider double deck 104; Pinochle 48; and the Tile Rummy set of
  106 (1–13 in 4 colors, two of each, plus 2 jokers).
- R-ENG-2.3 Each game SHALL supply its own rank order, point values, and "effective suit" mapping (e.g.
  Euchre left bower, Sheepshead trump); EngineCore SHALL provide the extension points, not the values.

### R-ENG-3 — Zones with visibility policy
**User story:** As a rules author, I want zones with owners and visibility rules, so redaction and
layout can be driven declaratively.

- R-ENG-3.1 A `Zone` SHALL have an owner (a seat, or none/shared) and an ordered contents.
- R-ENG-3.2 A `Zone` SHALL declare a visibility policy from at least: hidden, owner-only, public,
  top-card-only, and face-up/face-down per piece.
- R-ENG-3.3 View redaction (R-ENG-8) SHALL be derived from zone visibility policy plus per-piece
  face-up/face-down state.

### R-ENG-4 — Seeded PRNG and Fisher–Yates shuffle
**User story:** As a fairness auditor, I want reproducible shuffles from a recorded seed, so any hand can
be re-derived and verified.

- R-ENG-4.1 EngineCore SHALL provide a seeded PRNG (algorithm documented in ADR 0002) and its own
  Fisher–Yates shuffle (per `tech.md` rule 5).
- R-ENG-4.2 Rules code SHALL NOT use `Int.random`, `shuffle()`, or `SystemRandomNumberGenerator`; seeds
  SHALL be generated once per hand, outside the rules (per `tech.md` rule 5).
- R-ENG-4.3 A seed SHALL be recorded for every hand.
- R-ENG-4.4 WHEN the same seed and the same action log are replayed, the engine SHALL produce an
  identical final state hash on every run; a test SHALL prove this (per `tech.md` rule 5).

### R-ENG-5 — GameDefinition protocol
**User story:** As a game author, I want one protocol that fully describes a game, so adding a game is a
matter of conforming to it.

- R-ENG-5.1 EngineCore SHALL define a `GameDefinition` protocol exposing metadata: stable id, name,
  family, seat range, typical duration, and complexity.
- R-ENG-5.2 `GameDefinition` SHALL expose an options schema with defaults and named presets.
- R-ENG-5.3 `GameDefinition` SHALL produce the initial state from config + seed, define phases, and
  enumerate the legal actions for a given seat and state.
- R-ENG-5.4 `GameDefinition.apply(action, to: state)` SHALL return either the new state plus an ordered
  list of events, or a typed `RuleViolation` carrying a human-readable reason.
- R-ENG-5.5 `GameDefinition` SHALL provide terminal detection, scoring/outcome, and view redaction
  (via R-ENG-8).
- R-ENG-5.6 A `GameDefinition` SHALL be self-contained such that registering a new game requires no edits
  to EngineCore or TableKit (per `tech.md` rule 9); IF a game would require such edits, THEN an ADR SHALL
  be written (recorded in `design.md`'s "How to add a new game").

### R-ENG-6 — Match structure
**User story:** As a player, I want matches made of hands with rotating dealers and cumulative scores, so
multi-hand games track correctly.

- R-ENG-6.1 EngineCore SHALL model match → hands → phases → turns.
- R-ENG-6.2 The match model SHALL support dealer rotation, cumulative scores, and end conditions
  including target-score.
- R-ENG-6.3 The match model SHALL produce a per-hand summary.

### R-ENG-7 — Action log
**User story:** As a maintainer, I want an authoritative ordered log, so save/restore, undo, replays, and
future network sync all derive from one source of truth.

- R-ENG-7.1 EngineCore SHALL maintain an ordered action log recording, per entry: seat, action, resulting
  state hash, and metadata (timestamps live only in metadata, per `tech.md` rule 8).
- R-ENG-7.2 The action log SHALL power save/restore, undo where permitted, replays, and future network
  sync.
- R-ENG-7.3 Each game SHALL declare its undo policy: Solitaire games get unlimited undo and redo;
  multi-seat games have undo off by default.
- R-ENG-7.4 WHERE a multi-seat game enables Practice Mode, undoing the last human action SHALL roll back
  any AI actions taken after it and re-decide them, AND that game SHALL be excluded from statistics.

### R-ENG-8 — Events and Views/redaction
**User story:** As a client author (UI/AI/log), I want to consume semantic events and per-viewer redacted
views, so no client ever sees hidden identities.

- R-ENG-8.1 Events SHALL be semantic and Codable, including at least `pieceMoved`, `pieceRevealed`,
  `turnChanged`, `trickWon`, `scoreChanged`, and `handEnded`; animation, captions, VoiceOver, sound, and
  the log all consume the same events.
- R-ENG-8.2 EngineCore SHALL provide `view(for: Viewer)` where `Viewer` is a seat, a spectator, or a
  debug-only omniscient viewer.
- R-ENG-8.3 In a view, pieces hidden from that viewer SHALL appear as opaque tokens that cannot be
  correlated with real piece identities and are unique per view (per `tech.md` rule 3).
- R-ENG-8.4 WHEN a hidden piece becomes visible, a reveal event SHALL bind its token to its real
  identity, so animations stay continuous without leaking information before the reveal.
- R-ENG-8.5 Everything crossing the host boundary (config, actions, views, events, errors) SHALL be
  `Codable`, `Sendable`, and schema-versioned (per `tech.md` rule 4).

---

## 3. Multiplayer-ready session architecture (seams only, no networking)

### R-SESS-1 — Host-authoritative state
**User story:** As an architect, I want a single authority mutating state, so fairness and future
server-authority hold.

- R-SESS-1.1 A `GameHost` actor SHALL own the state, the RNG, and the action log, and SHALL be the only
  component that mutates state (per `tech.md` rule 2).
- R-SESS-1.2 The UI, AI, and future remote players SHALL only submit actions and receive views/events;
  no client SHALL reach into authoritative state.

### R-SESS-2 — PlayerController protocol
**User story:** As an architect, I want an async controller seam, so a remote controller can be added
later without restructuring.

- R-SESS-2.1 EngineCore SHALL define a `PlayerController` protocol with an async decision API.
- R-SESS-2.2 `LocalHumanController` (driven by the UI) and `AIController` SHALL conform to it.
- R-SESS-2.3 `design.md` SHALL document how a future `RemoteController` plugs in; no networking code
  SHALL be written in this spec (per `product.md` non-goals).
- R-SESS-2.4 The turn loop SHALL await controller decisions so a `Remote` controller plugs in without
  restructuring (per `tech.md` rule 6).

### R-SESS-3 — Turn models
**User story:** As a rules author, I want sequential, simultaneous, and out-of-turn turn models, so games
like Hearts passing and Cribbage discards fit later without engine changes.

- R-SESS-3.1 The host SHALL support sequential turns.
- R-SESS-3.2 The host SHALL support simultaneous phases: collect actions from every required seat, then
  resolve.
- R-SESS-3.3 The host SHALL support out-of-turn windows.
- R-SESS-3.4 Timeouts SHALL be part of the turn model; the default SHALL be none.

### R-SESS-4 — Codable message envelope over in-process transport
**User story:** As an architect, I want the local UI to talk to the host exactly as a network client
would, so multiplayer is a transport swap, not a rewrite.

- R-SESS-4.1 The UI SHALL communicate with the host through a Codable message envelope: submit an action
  → accepted or rejected; view updates; events.
- R-SESS-4.2 The transport SHALL be in-process for this spec, and the local app SHALL use this boundary
  exactly the way a future network client would.

### R-SESS-5 — Player profiles and personas
**User story:** As a player, I want a local profile and named AI personas, so seats have identity.

- R-SESS-5.1 EngineCore SHALL model player profiles (id, display name, avatar, controller type).
- R-SESS-5.2 The app SHALL provide an editable local profile and bundled AI personas.

### R-SESS-6 — Concurrent sessions
**User story:** As a power user, I want multiple independent games at once, so windows and the sim CLI
don't collide.

- R-SESS-6.1 The architecture SHALL support multiple concurrent, independent sessions (e.g. two windows
  plus the simulation CLI) with no game-state singletons (per `tech.md` rule 7).

---

## 4. AI framework (AIKit)

### R-AI-1 — Strategies see only views
**User story:** As a fairness auditor, I want AI restricted to what a human in that seat sees, so
computer opponents never cheat (`product.md` principle 2).

- R-AI-1.1 AI strategies SHALL receive only a `PlayerView`, the public log, and the legal actions — never
  authoritative state; the API types SHALL make authoritative state unreachable from a strategy.

### R-AI-2 — Difficulty tiers and shared toolkit
**User story:** As a player, I want Easy/Medium/Hard opponents backed by real technique, so difficulty is
meaningful.

- R-AI-2.1 AIKit SHALL support Easy, Medium, and Hard tiers per game (where the game has opponents).
- R-AI-2.2 AIKit SHALL provide a shared toolkit: a determinization sampler that respects everything
  observed (including inferred voids), Monte Carlo rollouts, ISMCTS, and evaluator helpers.

### R-AI-3 — Time-budgeted, cancellable, reproducible decisions
**User story:** As a player, I want responsive AI that never blocks the UI and replays deterministically,
so play feels good and simulations are reproducible.

- R-AI-3.1 AI decisions SHALL be time-budgeted and cancellable, and SHALL run off the main actor
  (per `tech.md` performance budgets).
- R-AI-3.2 The AI's RNG SHALL be injected so AI-vs-AI runs are reproducible.
- R-AI-3.3 A Hard decision SHALL meet the `tech.md` p95 budget (≤ 1.0 s per move; ≤ 1.5 s for poker and
  Tile Rummy), excluding cosmetic pacing delay.

### R-AI-4 — Pacing
**User story:** As a player, I want AI thinking time to feel natural and be tunable, so opponents are
followable.

- R-AI-4.1 AIKit SHALL apply natural, jittered thinking delays with settings Instant / Fast / Normal /
  Relaxed (per `ux-guidelines.md` motion).
- R-AI-4.2 AI pacing SHALL be set independently of animation speed (per `ux-guidelines.md`).

### R-AI-5 — Personas
**User story:** As a player, I want opponents with names, avatars, and styles, so the table feels
populated.

- R-AI-5.1 AIKit SHALL provide named personas with avatars and style parameters (e.g. cautious,
  aggressive).

### R-AI-6 — Hint interface
**User story:** As a learner, I want a suggested move with a plain-language reason, so I can improve; and
coach mode should reuse it.

- R-AI-6.1 AIKit SHALL provide a hint interface returning a suggested action plus a short plain-language
  explanation.
- R-AI-6.2 Coach mode SHALL reuse the hint interface (per `ux-guidelines.md` learning/help).

---

## 5. Table rendering, interaction, and animation (TableKit)

### R-TABLE-1 — Generic, layout- and event-driven renderer
**User story:** As a game author, I want a renderer driven by declarative layout + the host event stream,
so I get deal/move/flip/collect animations for free.

- R-TABLE-1.1 TableKit SHALL provide a generic renderer driven by (a) each game's declarative layout
  (zones → position, stacking/fanning style, seat arrangement for 1–9 seats, plus responsive rules) and
  (b) the host's event stream.
- R-TABLE-1.2 A new game SHALL obtain deal, move, flip, and collect animations without writing custom
  animation code (per `tech.md` rule 9; `structure.md`).
- R-TABLE-1.3 The renderer SHALL be SwiftUI-first with stable card/tile identity and matched geometry;
  visual effects use Metal shaders through SwiftUI shader APIs (per `tech.md` rendering; ADR 0001).

### R-TABLE-2 — Card views
**User story:** As a player, I want tactile, legible cards, so play feels like a real table
(`ux-guidelines.md` visual language).

- R-TABLE-2.1 Card views SHALL use cached vector faces and backs, keyed by (theme, face, scale,
  appearance), never redrawn every frame (per `tech.md` rendering).
- R-TABLE-2.2 Card views SHALL support 3D flip, lift on hover, selection, highlighting of legal targets,
  and optional dimming of unplayable cards.

### R-TABLE-3 — Input paths
**User story:** As every player (including keyboard-only), I want three input paths plus a "why not?"
explainer, so any action is reachable and understandable.

- R-TABLE-3.1 TableKit SHALL support drag and drop of single cards and stacks.
- R-TABLE-3.2 TableKit SHALL support click-to-select then click-to-place.
- R-TABLE-3.3 TableKit SHALL support double-click "smart move" where a game defines one.
- R-TABLE-3.4 TableKit SHALL support full keyboard navigation: move focus between zones and pieces,
  select, place, and cancel, with a visible focus indicator.
- R-TABLE-3.5 Right-click on a card SHALL offer a "Why can't I play this?" explanation built from the
  relevant `RuleViolation` reason.
- R-TABLE-3.6 WHILE a card is dragged or selected, TableKit SHALL highlight its legal targets
  (per `ux-guidelines.md` interaction).

### R-TABLE-4 — Illegal attempts
**User story:** As a player, I never want an error dialog mid-play, so mistakes stay gentle
(`ux-guidelines.md` interaction).

- R-TABLE-4.1 IF a player attempts an illegal move, THEN the card SHALL spring back with a gentle shake
  and a short caption built from the `RuleViolation` reason SHALL appear; no modal error dialog SHALL open.

### R-TABLE-5 — Animation queue
**User story:** As a player, I want smooth, skippable animation that never blocks me, so the game keeps
up with my pace.

- R-TABLE-5.1 TableKit SHALL provide an animation queue that sequences events, honors the speed setting
  (Relaxed/Normal/Fast/Instant), and supports fast-forward via click or keypress.
- R-TABLE-5.2 The animation queue SHALL never block input for longer than the animation currently
  playing.
- R-TABLE-5.3 Default durations SHALL be 150–350 ms using springs/physically plausible arcs; WHERE Reduce
  Motion is on, movement SHALL be replaced with crossfades and parallax/particles disabled, with no loss
  of information (per `ux-guidelines.md` motion).

### R-TABLE-6 — HUD components
**User story:** As a player, I want a quiet, complete HUD, so I can read state and act without clutter.

- R-TABLE-6.1 TableKit SHALL provide seat plates, a scoreboard, a caption bar, a history drawer, a pause
  menu, and a toolbar (New, Undo, Hint, Rules, Menu).
- R-TABLE-6.2 Seat plates SHALL show avatar, name, score, dealer button, role badges, active-turn glow,
  and an AI thinking indicator; the local player SHALL sit bottom-center with others clockwise
  (per `ux-guidelines.md` table conventions).
- R-TABLE-6.3 The HUD SHALL NOT cover cards the player needs (per `ux-guidelines.md`).

### R-TABLE-7 — Performance and stress scene
**User story:** As a performance owner, I want the renderer to meet budgets under load, so play stays at
frame rate even in 104-card layouts.

- R-TABLE-7.1 The renderer SHALL meet the `tech.md` performance budgets (see R-NFR-PERF).
- R-TABLE-7.2 TableKit SHALL include a 104-card stress scene for profiling.

---

## 6. Design system, themes, assets, and sound (DesignSystem)

### R-DS-1 — Tokens and chrome
- R-DS-1.1 DesignSystem SHALL define tokens for color, type, spacing, radius, shadow, and motion, and
  SHALL support light and dark chrome (per `ux-guidelines.md`).
- R-DS-1.2 Color SHALL come only from semantic tokens; all text and essential UI SHALL meet WCAG 2.2 AA
  contrast (per `ux-guidelines.md`).

### R-DS-2 — Themes
- R-DS-2.1 DesignSystem SHALL provide at least 4 table themes (e.g. Classic Felt, Midnight, Walnut
  Parlor, Minimal), built from procedural shaders and materials rather than large bitmaps (per `tech.md`
  rendering; `ux-guidelines.md`).
- R-DS-2.2 Table themes SHALL be independent of the system light/dark appearance (per `ux-guidelines.md`).

### R-DS-3 — Deck styles and backs
- R-DS-3.1 DesignSystem SHALL provide deck styles Classic, Modern, Four-Color, and Jumbo Index.
- R-DS-3.2 DesignSystem SHALL provide at least 6 card backs.
- R-DS-3.3 Court cards SHALL use original designs (geometric or ornamental acceptable) (per
  `ux-guidelines.md`; `product.md` distribution intent).

### R-DS-4 — Theme-pack system
- R-DS-4.1 A theme pack SHALL be a JSON manifest plus vector assets and audio, loaded at runtime and
  switchable without a restart.
- R-DS-4.2 The theme-pack system SHALL allow commissioned art to replace placeholders later without code
  changes; every placeholder asset SHALL be flagged "needs production art" in `tasks.md`.

### R-DS-5 — Sound engine
- R-DS-5.1 DesignSystem SHALL provide an event-driven sound engine with randomized variations (the same
  sound never plays twice in a row), separate volume categories for effects and ambience, a master mute,
  and mute-when-in-background (per `ux-guidelines.md` sound).
- R-DS-5.2 All audio SHALL be original, CC0, or procedurally synthesized, recorded in
  `THIRD_PARTY_NOTICES.md` where applicable (per `tech.md`).

### R-DS-6 — Placeholder art
- R-DS-6.1 Generated placeholders SHALL be acceptable for the app icon and game-tile artwork, and SHALL
  be flagged for replacement in `tasks.md`.

---

## 7. App shell and navigation

### R-APP-1 — Library (home)
- R-APP-1.1 The Library SHALL show a "Continue" hero for games in progress, game tiles grouped by family,
  filters (family, player count, duration), favorites, and recently played.
- R-APP-1.2 Games SHALL register in a catalog behind feature flags; games not yet built SHALL NOT appear
  (per `product.md` roadmap; `structure.md` catalog registration).
- R-APP-1.3 Game tiles SHALL show rich illustrated artwork with subtle parallax on hover (disabled under
  Reduce Motion) (per `ux-guidelines.md`).

### R-APP-2 — Game setup sheet
- R-APP-2.1 The setup sheet SHALL list presets first, then options and house rules (grouped separately),
  each with a one-line explanation (per `ux-guidelines.md` learning/help).
- R-APP-2.2 The setup sheet SHALL provide opponent setup (count, persona, difficulty) and a "Remember my
  choices" option.

### R-APP-3 — Table screen
- R-APP-3.1 The table screen SHALL present a full-bleed table, a quiet toolbar, the HUD, and a pause menu.
- R-APP-3.2 The rules viewer SHALL open in place as an inspector, rendered from the bundled
  `Docs/Rules/<game-id>.md`, without losing game state (per `ux-guidelines.md`).

### R-APP-4 — Statistics
- R-APP-4.1 Statistics SHALL be tracked per game and variant: games played, games won, win percentage,
  current and best streak, best score, best time, and game-specific metrics.
- R-APP-4.2 Statistics SHALL be visualized with Swift Charts (per `tech.md` rendering).
- R-APP-4.3 IF the player resets statistics, THEN the app SHALL ask for confirmation first (per
  `ux-guidelines.md` interaction — destructive action).

### R-APP-5 — Settings
- R-APP-5.1 Settings SHALL cover appearance (theme, deck, card back, card size S/M/L/XL), gameplay
  (animation speed, AI pace, auto-moves, hints, confirmations), sound, accessibility overrides, and the
  player profile.

### R-APP-6 — macOS integration
- R-APP-6.1 The app SHALL provide the standard menu bar and shortcuts from `ux-guidelines.md` (⌘N, ⌘Z /
  ⇧⌘Z, ⌘,, ⌘?, H, Space/Return, Esc, ⌃⌘F), full screen, and window restoration.
- R-APP-6.2 The app SHALL support multiple windows, each holding an independent game (implements
  R-SESS-6.1 at the UI layer).
- R-APP-6.3 The app SHALL provide an About window with third-party notices.
- R-APP-6.4 Chrome SHALL use standard SwiftUI components so the app inherits the current macOS design
  language automatically (per `ux-guidelines.md` platform); the minimum window SHALL be 1024×700 and
  layouts SHALL scale to 6K.

### R-APP-7 — First-run tour
- R-APP-7.1 The first-run tour SHALL have at most 3 skippable steps (per `ux-guidelines.md`).

---

## 8. Persistence

### R-PERS-1 — Autosave and resume
- R-PERS-1.1 The app SHALL autosave after every accepted action.
- R-PERS-1.2 WHEN the app relaunches, it SHALL resume exactly where the player left off, including
  mid-hand against the AI.

### R-PERS-2 — Versioned save format and migration
- R-PERS-2.1 The save format SHALL be versioned, with migration tests.
- R-PERS-2.2 IF a save is corrupted or incompatible, THEN the app SHALL handle it gracefully (a notice,
  then discard), never with a crash.

### R-PERS-3 — Local-only storage
- R-PERS-3.1 Statistics and settings SHALL be stored locally in the sandbox container; no cloud
  (per `product.md` principle 3; `tech.md`).

### R-PERS-4 — Replay last game (Should)
- R-PERS-4.1 The app SHOULD provide "Replay last game" reconstructed from the action log.

---

## 9. Accessibility

### R-A11Y-1 — VoiceOver
- R-A11Y-1.1 Every card, tile, pile, and control SHALL have a meaningful label, value, and hint (e.g.
  "Queen of clubs, trump, playable").
- R-A11Y-1.2 The app SHALL provide custom rotors for hands and piles and SHALL announce opponent actions
  and results (per `ux-guidelines.md`).

### R-A11Y-2 — Keyboard
- R-A11Y-2.1 Every game and flow SHALL be fully playable keyboard-only, with a visible focus indicator
  (per `ux-guidelines.md`; implements R-TABLE-3.4).

### R-A11Y-3 — Color independence
- R-A11Y-3.1 Suits SHALL always carry shapes; a Four-Color deck option SHALL be available (per
  `ux-guidelines.md`; implements R-DS-3.1).

### R-A11Y-4 — System accessibility settings
- R-A11Y-4.1 The app SHALL respect Reduce Motion, Reduce Transparency, and Increase Contrast, and SHALL
  offer a card size setting of S / M / L / XL (per `ux-guidelines.md`; implements R-APP-5.1, R-TABLE-5.3).

### R-A11Y-5 — Accessibility UI tests
- R-A11Y-5.1 UI tests SHALL finish a Klondike game (using a debug near-win deal) and a Crazy Eights hand
  using only the keyboard.
- R-A11Y-5.2 Automated XCUITest accessibility audits SHALL run on the library, setup, and table screens.

---

## 10. Klondike

### R-KLON-1 — Deal and board
**User story:** As a Solitaire player, I want a correct standard Klondike layout, so the game plays as
expected.

- R-KLON-1.1 The initial deal SHALL be 7 tableau piles holding 1–7 cards (top card face up), a 24-card
  stock, an empty waste, and 4 empty foundations.
- R-KLON-1.2 The tableau SHALL build down in alternating colors; foundations SHALL build up by suit from
  Ace to King.
- R-KLON-1.3 Any face-up sequence SHALL be movable as a unit.
- R-KLON-1.4 Only a King, or a sequence led by a King, SHALL fill an empty tableau pile.
- R-KLON-1.5 Moving a card from a foundation back to the tableau SHALL be allowed.

### R-KLON-2 — Options
**User story:** As a Solitaire player, I want the standard configurable options, so I can play my
preferred variant.

- R-KLON-2.1 Draw count SHALL be Draw 1 (default) or Draw 3.
- R-KLON-2.2 Scoring SHALL be Standard (classic Windows-style values, documented in the rules doc),
  Vegas (start at −52, +5 per card sent to a foundation, optionally cumulative across games), or None.
- R-KLON-2.3 Stock passes SHALL be Unlimited (default), 3, or 1; Vegas SHALL default to 1 pass for Draw 1
  and 3 passes for Draw 3.
- R-KLON-2.4 Timed scoring SHALL be on or off.
- R-KLON-2.5 Each option SHALL be documented with its default and appear in presets in
  `Docs/Rules/klondike.md`.

### R-KLON-3 — Features
**User story:** As a Solitaire player, I want the full quality-of-life feature set, so play is fast and
pleasant.

- R-KLON-3.1 The game SHALL provide auto-flip of a newly exposed tableau top card.
- R-KLON-3.2 Auto-move to foundations SHALL be Off / Safe only (default) / Always.
- R-KLON-3.3 The game SHALL provide smart move (double-click) and auto-complete when the board is solved.
- R-KLON-3.4 The game SHALL provide unlimited undo and redo (implements R-ENG-7.3).
- R-KLON-3.5 The game SHALL provide heuristic hints (solver-backed hints are Spec 2, out of scope here).
- R-KLON-3.6 WHEN no legal moves remain, the game SHALL detect it and offer undo, restart, or a new game
  (no modal error; use inline banner per `ux-guidelines.md`).
- R-KLON-3.7 The game SHALL support restarting the same deal and numbered deals with "Play deal #…".
- R-KLON-3.8 The game SHALL show a timer and move counter.
- R-KLON-3.9 WHEN the player wins, the game SHALL play a short (≤ 3 s), skippable win celebration (a
  homage to cascading cards plus a modern flourish) (per `ux-guidelines.md` motion).
- R-KLON-3.10 The game SHALL record statistics (implements R-APP-4.1).

---

## 11. Crazy Eights

### R-CE-1 — Players and deal
**User story:** As a card player, I want a correct Crazy Eights deal for 2–5 players, so the game starts
fairly.

- R-CE-1.1 The game SHALL support 2–5 players: the local human plus 1–4 AI opponents.
- R-CE-1.2 The deal SHALL be 7 cards each with 2 players, or 5 cards each with 3–5 players.
- R-CE-1.3 The game SHALL turn up a starter card; IF the starter is an 8, THEN it SHALL be buried in the
  stock and another turned up.

### R-CE-2 — Play
**User story:** As a card player, I want standard matching/wild/draw rules, so play is correct.

- R-CE-2.1 On a turn, a player SHALL play a card matching the top discard's suit or rank.
- R-CE-2.2 8s SHALL be wild; the player who plays one SHALL name a suit.
- R-CE-2.3 IF a player cannot or chooses not to play, THEN they SHALL draw until they can play (default)
  or draw one card and pass (option).
- R-CE-2.4 WHEN the stock runs out, the game SHALL reshuffle the discards except the top card (default),
  or end the hand once no one can play (option).

### R-CE-3 — Scoring
**User story:** As a card player, I want standard Crazy Eights scoring, so matches resolve correctly.

- R-CE-3.1 The player who goes out SHALL score the cards left in opponents' hands: 8 = 50; K/Q/J = 10;
  A = 1; other cards at face value.
- R-CE-3.2 The match target SHALL default to 100 and be configurable.

### R-CE-4 — Action-card option (off by default)
**User story:** As a card player, I want optional action cards, so I can play the livelier variant.

- R-CE-4.1 WHERE the action-cards option is on: a 2 SHALL make the next player draw two, and 2s SHALL
  stack; a Jack SHALL skip the next player; an Ace SHALL reverse direction. This option SHALL default off.

### R-CE-5 — AI
**User story:** As a player, I want Crazy Eights opponents that scale with difficulty, so the game stays
interesting.

- R-CE-5.1 Easy AI SHALL play a random legal card and spend 8s early.
- R-CE-5.2 Medium AI SHALL keep 8s for when needed, name its longest suit, and track suits opponents have
  failed to follow.
- R-CE-5.3 Hard AI SHALL use determinized Monte Carlo (from the AIKit toolkit, R-AI-2.2).

---

## 12. Quality gates

### R-QA-1 — Scenario tests
- R-QA-1.1 Every rule and option in both rules documents (`Docs/Rules/klondike.md`,
  `Docs/Rules/crazy-eights.md`) SHALL have a Given/When/Then scenario test traceable to that document
  (per `product.md` Definition of Done).

### R-QA-2 — Simulation and invariants
- R-QA-2.1 `parlor-sim` SHALL run AI-vs-AI and random-legal games and check invariants at every step:
  piece conservation (each piece in exactly one zone); only legal actions accepted; games end within a
  bounded number of actions; scoring consistency; and deterministic replay (seed + log → identical final
  hash).
- R-QA-2.2 `make test` SHALL run 500 games per game; `make test-long` SHALL run 10,000 games per game.

### R-QA-3 — View-leak property test
- R-QA-3.1 For random states and every viewer, the serialized view SHALL contain no identity of any piece
  hidden from that viewer; a property test SHALL assert this (implements R-ENG-8.3).

### R-QA-4 — Save/restore round trips
- R-QA-4.1 Restoring at random points and continuing SHALL produce the same outcome as an uninterrupted
  run with the same seeds; a test SHALL assert this (implements R-PERS-1, R-ENG-4.4).

### R-QA-5 — UI tests
- R-QA-5.1 UI tests SHALL cover: library → setup → play Klondike with both drag and keyboard → undo → win
  from a debug near-win seed; a full Crazy Eights hand against the AI; changing the theme and deck;
  quitting and resuming.

### R-QA-6 — Performance tests
- R-QA-6.1 Performance tests SHALL cover launch, deal animation, and AI decision time, checked against
  the `tech.md` budgets (see R-NFR-PERF).

### R-QA-7 — Coverage
- R-QA-7.1 Line coverage SHALL be at least 90% for `EngineCore` and every rules target (per `tech.md`
  testing).

---

## Non-functional requirements (measurable)

### R-NFR-PERF — Performance budgets (baseline: M1 MacBook Air, release build; from `tech.md`)
- R-NFR-PERF.1 Cold launch to an interactive library SHALL be ≤ 1.5 s; starting a game SHALL be ≤ 300 ms.
- R-NFR-PERF.2 Animation SHALL sustain ≥ 60 fps at all times, targeting 120 fps on ProMotion, including
  104-card layouts during drag and deal.
- R-NFR-PERF.3 Input-to-visual-feedback SHALL be ≤ 50 ms.
- R-NFR-PERF.4 AI decision at Hard SHALL be ≤ 1.0 s p95 per move (≤ 1.5 s for poker and Tile Rummy),
  excluding cosmetic pacing delay; decisions SHALL be cancellable and run off the main actor.
- R-NFR-PERF.5 Memory SHALL be ≤ 400 MB; idle CPU with no animation running SHALL be < 1%.

### R-NFR-QUAL — Code quality (from `tech.md`)
- R-NFR-QUAL.1 Engine and rules code SHALL contain no force unwraps or `try!`; rule violations SHALL be
  typed errors with human-readable reasons.
- R-NFR-QUAL.2 Public APIs SHALL have doc comments; value types SHALL be preferred; files SHALL stay
  focused (~400 lines guideline).
- R-NFR-QUAL.3 All user-facing strings SHALL go through String Catalogs (`.xcstrings`); English only for
  now, but all strings SHALL remain localizable (per `product.md` non-goals).
- R-NFR-QUAL.4 Logging SHALL use `os.Logger` with categories; debug builds include an FPS and
  state-inspector overlay, release builds do not (per `tech.md`).

### R-NFR-DEP — Dependencies (from `tech.md`)
- R-NFR-DEP.1 Only Apple frameworks and Apple-maintained Swift packages (swift-collections,
  swift-algorithms, swift-numerics) SHALL be runtime dependencies; swift-snapshot-testing is test-only;
  anything else requires an ADR. No runtime dependency SHALL perform network access.

### R-NFR-DOC — Documentation upkeep (from `structure.md`)
- R-NFR-DOC.1 `Docs/Architecture.md` and the relevant `Docs/Rules/*.md` SHALL be updated in the same task
  that changes behavior.
- R-NFR-DOC.2 ADRs SHALL be written for new dependencies, changes to EngineCore/TableKit public APIs,
  rendering-approach changes, and save-format changes.

---

## Assumptions

These are working assumptions made to avoid guessing at rules; they can be revised without reopening the
whole spec.

- A-1 **Toolchain host.** `make bootstrap` targets a developer macOS machine with Homebrew available for
  installing XcodeGen; the headless CI/sandbox path builds the Swift packages directly with
  `swift build`/`swift test` and does not require the full app build. (Trace: R-BUILD-2.)
- A-2 **PRNG algorithm.** SplitMix64 seeding a xoshiro256\*\* stream is the intended documented algorithm
  (see ADR 0002); this is an implementation choice, revisable in the ADR. (Trace: R-ENG-4.)
- A-3 **State hash.** The determinism hash is a stable, order-independent-where-appropriate digest (e.g.
  SHA-256) over the canonical `Codable` state encoding; the exact digest is an implementation choice.
  (Trace: R-ENG-4.4, R-QA-2.1.)
- A-4 **Klondike Standard scoring values** follow the classic Windows Solitaire scheme; the exact point
  table is authored fresh in `Docs/Rules/klondike.md` (original writing per `ux-guidelines.md` voice) and
  is the single source of truth. (Trace: R-KLON-2.2.)
- A-5 **Crazy Eights face-value counting** uses pip value for number cards 2–10 and 10 (Ace = 1 per
  R-CE-3.1); the rules doc is authoritative. (Trace: R-CE-3.1.)
- A-6 **Avatars/personas** ship as generated placeholders flagged "needs production art"; persona style
  parameters are a small documented set (aggression, risk tolerance). (Trace: R-AI-5, R-DS-6.)
- A-7 **`parlor-sim` volume** (500 / 10,000) is per game per invariant suite; a sampling seed pool is
  generated by a `Scripts/` step. (Trace: R-QA-2.2.)
- A-8 **Card-face vector rendering** uses SwiftUI `Canvas`/vector drawing cached to images; the specific
  drawing API is an ADR-0001 implementation detail. (Trace: R-TABLE-2.1.)

## Open Questions / NEEDS REVIEW

Items that would otherwise require inventing a rule or a product decision. Each is marked NEEDS REVIEW and
must be resolved before the corresponding task is implemented.

- Q-1 **Klondike Standard scoring exact values** (per-move points, time bonus formula, "recycle waste"
  penalty). NEEDS REVIEW — confirm the exact point table before authoring `Docs/Rules/klondike.md`
  §Scoring. (Trace: R-KLON-2.2, A-4.)
- Q-2 **Vegas cumulative scoring persistence** — does the running Vegas bankroll persist across app
  launches, and does it reset on demand? NEEDS REVIEW. (Trace: R-KLON-2.2.)
- Q-3 **Crazy Eights "draw until you can play" cap** — is there a maximum number of draws before a forced
  pass when the stock is empty and reshuffle is off? NEEDS REVIEW. (Trace: R-CE-2.3, R-CE-2.4.)
- Q-4 **Action-card edge cases** — with action cards on: does a Jack (skip) or Ace (reverse) behave
  differently in a 2-player game, and can an 8 also be an action card? Does a drawn 2 stack? NEEDS REVIEW.
  (Trace: R-CE-4.1.)
- Q-5 **Starter card that is an action card** — with action cards on, if the turned-up starter is a 2 or
  Jack or Ace, does its effect apply to the first player? NEEDS REVIEW. (Trace: R-CE-1.3, R-CE-4.1.)
- Q-6 **Bundled display face** — which specific OFL display face is bundled for titles/game names?
  NEEDS REVIEW (must be OFL-licensed per `tech.md`). (Trace: `ux-guidelines.md` typography.)
- Q-7 **Practice Mode statistics exclusion granularity** — is an entire match excluded once Practice
  undo is used, or only the affected hand? NEEDS REVIEW. (Trace: R-ENG-7.4.)
- Q-8 **"Replay last game" scope** (Should) — replay of the last hand only, or the full match? And is it
  a passive playback or an interactive re-entry? NEEDS REVIEW. (Trace: R-PERS-4.1.)
