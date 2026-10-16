# Requirements Document

## Introduction

**Bug ID**: `BUG-STOCK-DRAW-MOVE-REJECTION`

**Title**: Cards Drawn from Stock Cannot Move to Valid Destinations

After drawing one or more cards from the Klondike stock pile, the drawn card(s) appear in the waste zone with correct legal-move highlighting, but all attempts to move them are rejected by the host with a silent spring-back (no error caption). The move IS legal per Klondike rules and SHOULD succeed. This is a **critical blocker** for gameplay.

### Symptom
Users cannot move Aces or other cards that have been drawn from the stock, even when the destination zones highlight as valid. The UI shows correct highlighting but silently rejects every drop attempt.

### Scope
- **Component**: Klondike table interaction (UI state reconciliation + move validation)
- **Severity**: Critical — core gameplay broken
- **Impact**: CHECKPOINT 6 blocked; game is unplayable

---

## Requirements

### R-BUG-1: State Consistency After Draw
After `drawFromStock` or `recycleWaste` succeeds at the host layer:

- The shadow state's `latestState.waste.contents` MUST contain the moved piece(s)
- Each piece ID MUST have an entry in `latestState.faces` (face map MUST be complete)
- Zone IDs in the reconciled state MUST be exactly comparable (by value) to those used in legal-action enumeration
- The render model (AnimationDriver) MUST be reconciled to match the redacted view

**Rationale**: Without state consistency, the table controller cannot correctly enumerate legal moves or map user gestures to valid actions.

### R-BUG-2: View Reconciliation Preserves Piece Identity
After `driver.reconcile(to: freshView)` is called with the host's fresh view:

- All known (non-tokenized) pieces in the fresh view MUST have corresponding entries in `latestState.faces`
- Drawing a card MUST NOT cause its PieceID to be lost or reassigned during the redaction/reconciliation cycle
- The relationship between RenderKey and underlying PieceID MUST be stable

**Rationale**: If piece identity is lost during reconciliation, the adapter cannot find the piece in state and cannot generate a valid move action.

### R-BUG-3: Error Captions on Rejection
When a move is submitted and rejected by the host (or fails synchronous validation):

- If `KlondikeTableAdapter.action(for:in:)` returns `nil`, a meaningful error caption MUST be set: "That move isn't available."
- The caption MUST appear on screen in the caption bar (HUD top band)
- The caption MUST be visible for at least 2 seconds before auto-clearing
- Currently: No caption appears when moves are rejected

**Rationale**: Users need feedback on why their actions failed; silent spring-back is confusing and breaks flow.

### R-BUG-4: Regression Testing
The test suite MUST include a permanent test that reproduces and verifies the fix:

1. Set up a known state: stock has cards, waste is empty, foundations are empty, tableau is dealt
2. Execute `drawFromStock` (or use host to draw)
3. Verify the waste now contains the drawn card and its face is in the state
4. Verify `legalActions` includes a move from waste to a valid destination (e.g., waste-to-foundation for an Ace)
5. Verify `legalTargets` includes that same destination
6. Attempt the move (create TableMove, call resolve, await quiescence)
7. Assert the move succeeds WITHOUT spring-back
8. Assert no error caption is shown (move was legal and succeeded)

**Rationale**: A regression test ensures this bug cannot silently return in future releases.

### R-BUG-5: Diagnostic Logging
To assist future debugging:

- When `action(for:in:)` fails to map a move, log:
  - Whether no legal actions exist at all
  - Whether the piece exists in any legal action
  - Whether the piece has legal destinations but none match the attempted destination
  - Exact zone ID values involved (for comparison debugging)
- When caption is set due to rejection, log the violation code and reason

**Rationale**: Logs help developers quickly diagnose similar issues without requiring the full test suite setup.

---

## Root Cause Analysis

### Observations from Manual Testing
- ✅ Stock draw itself works (cards appear in waste)
- ✅ UI highlighting is correct (foundation zones show as valid for Ace)
- ✅ Unit tests pass (KlondikeMoveTests confirms waste-Ace-to-foundation is legal)
- ❌ Host rejects move on drop (silent spring-back)
- ❌ No error caption shown (violation's reason isn't reaching the UI)

### Hypotheses (To Be Tested)

**Hypothesis A: State Synchronization Divergence**
After a successful draw, the shadow state (`latestState`) and the host's state have diverged:
- The UI shadow is reconciled to the redacted view returned by the host
- But the redacted view contains tokenized (hidden) pieces instead of known ones
- When the adapter tries to convert `TableMove(piece: aceID, destination: foundation-0)` to an action, it fails to find the piece in `state.waste.contents`
- Result: `action(for:in:)` returns `nil`, move is rejected

**Hypothesis B: Zone ID Mismatch Post-Draw**
After reconciliation, zone IDs might not match exactly:
- `legalTargets` generates destinations from `KlondikeZone.foundation(i)`
- After a redaction/reconciliation cycle, the state's foundation zones might be recreated with different construction order or timing
- When `action(for:in:)` searches `legalActions` and compares `destination == move.destination`, the equality check fails
- Result: The matching action is found but skipped due to zone ID inequality

**Hypothesis C: Ace's Face Not in Face Map Post-Draw**
The Ace's `PieceID` exists but its face is not in the state's `faces` map:
- `state.face(of: aceID)` returns `nil`
- `KlondikeCard.rankValue(nil)` returns `nil`
- `foundationFollows(_, onto: nil)` cannot verify the card is an Ace
- The move is never added to `legalActions`
- Result: No highlighting, no action mapping, silent spring-back

---

## Related Requirements
- **R-TABLE-3**: Table interaction seam (legal actions drive highlighting)
- **R-TABLE-4.1**: Gentle spring-back on illegal moves (caption shows reason, no modal)
- **R-SESS-1.1**: Serialized submission pipeline (one move at a time, no racing)
- **R-KLON-1.2**: Klondike foundation rules (Ace builds foundation alone)
- **R-ENG-8.2**: Redaction (zones are redacted per visibility policy)
- **R-ENG-5.3**: Legal actions (pure function of state, complete enumeration)

---

## Success Criteria

1. ✅ User can move Ace from waste to foundation after drawing from stock
2. ✅ Card move succeeds without spring-back
3. ✅ No error caption shown (move was legal)
4. ✅ If a move IS illegal, caption explains why ("That move isn't available.")
5. ✅ New regression test passes consistently
6. ✅ Manual testing confirms gameplay is smooth
7. ✅ CHECKPOINT 6 can proceed (user can play both games end-to-end)

