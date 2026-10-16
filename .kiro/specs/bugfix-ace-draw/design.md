# Design Document

## Overview

**Purpose**: Fix the bug where cards drawn from the stock cannot be moved to valid destinations.

**Approach**: Diagnostic testing followed by targeted fix, then error reporting improvement.

The bug manifests as: user draws a card, sees correct highlighting, but all drops are silently rejected. Root cause is unknown and could be in three layers:
1. State synchronization (shadow state diverged from host)
2. Zone ID matching (adapter can't map moves)
3. Face map population (piece identity lost after draw)

## Architecture

The Klondike table interaction has three main layers:

```
User Input (drag/drop)
    ↓
TableInteractionView (SwiftUI)
    ↓
KlondikeTableController (GamesUI, handles state sync + submission)
    ↓
KlondikeTableAdapter (pure mapping: rules ↔ table interaction)
    ↓
Klondike Rules (GamesRules, pure: state → legal actions)
    ↓
GameHost (session layer, authoritative state)
```

**Bug Location**: Likely in `KlondikeTableController` or `KlondikeTableAdapter`. The rules layer (Klondike) is correct (tests pass).

## Components and Interfaces

### KlondikeTableController
- **Responsibility**: Maintain shadow state in sync with host; serialize submissions
- **Key State**: `latestState` (shadow copy), `latestView` (redacted view)
- **Key Method**: `performSubmission` (reconciles state after host acceptance)
- **Potential Bug**: After draw, `latestState.faces` may not include drawn card's face

### KlondikeTableAdapter
- **Responsibility**: Pure mapping between user gestures (TableMove) and game actions (KlondikeAction)
- **Key Method**: `action(for:in:)` — maps TableMove to action, returns nil if no match
- **Potential Bug**: Zone ID from `move.destination` doesn't match zone ID from `pieceAndDestination`

### AnimationDriver + Render Model
- **Responsibility**: Reconcile to new view state after host acceptance
- **Potential Bug**: Render model loses piece identity during reconciliation

## Data Models

### Key Types Involved
- **PieceID**: Stable unique identifier for a card (never changes)
- **RenderKey**: Opaque reference for rendering (`.known(PieceID)` or `.hidden(ViewToken)`)
- **ZoneID**: Zone name + owner (e.g., `ZoneID(name: "foundation-0")`)
- **TableMove**: User's gesture as a move (piece, source, destination)
- **KlondikeAction**: Game rule enumerating legal moves

### State Flow After a Draw

1. **Initial**: Stock=[A♠,...], Waste=[], Foundations=[]
2. **User taps stock**: TableInteractionView calls `resolveAction(.drawFromStock)`
3. **Controller submits**: Sends action to GameHost
4. **Host accepts**: Returns `ResultEnvelope(.accepted(events, views))`
5. **Controller reconciles**: 
   - Calls `applyToShadow` → `latestState = newState`
   - Gets `latestView = envelope.view(for: localSeat)`
   - Calls `driver.reconcile(to: latestView)` → render model updates
6. **Expected postcondition**: 
   - `latestState.waste.contents` has [A♠]
   - `latestState.faces[A♠.id]` has the card's face
   - `KlondikeZone.foundation(0)` in reconciled state == `KlondikeZone.foundation(0)` from `legalTargets`

## Testing Strategy

### Phase 1: Diagnostic Tests
**Goal**: Identify which hypothesis is correct.

1. **Test State Consistency**: After draw, verify `latestState` is complete
2. **Test Adapter Mapping**: After draw, verify adapter can map the move
3. **Test Zone Equality**: Verify zone IDs are exactly equal

### Phase 2: Root Cause Fix
Apply targeted fix based on which test fails:
- **Test 1 fails** → Fix state reconciliation
- **Test 2 fails** → Fix adapter zone ID matching
- **Both pass but user still can't move** → Investigate host/session layer

### Phase 3: Error Reporting
Add diagnostic logging and ensure error captions display.

### Phase 4: Regression Test
Write permanent test that reproduces the full workflow.

## Correctness Properties

**Invariant After Every Accepted Move**:
```
∀ piece ∈ latestView.zones[*].pieces:
  piece case .known(card) ⟹ latestState.faces[card.id] ≠ nil
```
(Every known piece in the view must have its face in the state.)

**Invariant For Move Legality**:
```
TableMove → KlondikeTableAdapter.action(...) → KlondikeAction
  ⟺ action ∈ Klondike().legalActions(for: seat, in: state)
```
(A move is legal if and only if its action is in legal actions.)

## Error Handling

**Current Behavior**: Silent spring-back (no error feedback)

**Required Behavior**: 
- When `action(for:in:)` returns nil, set `caption = "That move isn't available."`
- When host rejects, set `caption = violation.reason`
- Log detailed diagnostic info in both cases

**Logging Improvements**:
- Log when `action` is not found: which hypothesis is violated?
- Log zone ID equality checks for debugging
- Log face map lookups to catch missing entries

