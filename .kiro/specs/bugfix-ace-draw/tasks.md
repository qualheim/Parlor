# Implementation Plan: Bugfix — Stock Draw Move Rejection

## Overview
This bugfix investigates and fixes the bug where cards drawn from stock cannot be moved. The approach is diagnostic first (identify root cause via tests), then targeted fix, then error reporting.

## Tasks

- [ ] 1. Diagnostic Test — Shadow State After Draw. Write unit test in `KlondikeTableControllerTests.swift` that creates a game, draws a card, and verifies `latestState.waste.contents` is non-empty and `latestState.faces[cardID]` exists. Depends on: (none)

- [ ] 2. Diagnostic Test — Adapter Action Mapping. Write unit test in `KlondikeTableAdapterTests.swift` that builds a state with Ace in waste and verifies `KlondikeTableAdapter.action(for: move, in: state)` returns the expected `.wasteToFoundation` action. Depends on: Task 1

- [ ] 3. Analyze Diagnostic Results. Run Tasks 1 & 2, interpret results, and identify which hypothesis is correct (A: state sync, B: zone ID, or C: face map). Document findings. Depends on: Tasks 1, 2

- [ ] 4. Fix State Reconciliation (Hypothesis A). If Task 3 identifies state sync divergence, add face map validation in `KlondikeTableController.performSubmission` to detect and log missing faces. Depends on: Task 3 (if root cause is A)

- [ ] 5. Fix Zone ID Matching (Hypothesis B). If Task 3 identifies zone ID mismatch, add enhanced logging to `KlondikeTableAdapter.action(for:in:)` to diagnose zone ID equality failures. Depends on: Task 3 (if root cause is B)

- [ ] 6. Add Error Captions. Ensure caption is set when `action(for:in:)` returns nil. In `KlondikeTableController.resolve`, explicitly set `caption = "That move isn't available."` before returning failure. Depends on: (none, independent)

- [ ] 7. Verify Caption Display. Manually test that captions appear when moves are rejected and persist for 2+ seconds. Depends on: Task 6

- [ ] 8. Regression Test. Write comprehensive test in `KlondikeTableControllerTests` that draws a card and successfully moves it to a valid destination, with assertions that move succeeds and no error caption appears. Depends on: Tasks 4 or 5 (fix completed)

- [ ] 9. Manual Verification. User plays Klondike, draws until Ace appears, drags it to foundation and drops successfully. Verify no spring-back and no error caption. Depends on: Task 8

- [ ] 10. Complete Bugfix Spec. Mark tasks complete, close bugfix spec, and return to main spec to resume CHECKPOINT 6. Depends on: Task 9

## Task Dependency Graph

```json
{
  "waves": [
    {
      "wave": 1,
      "tasks": ["1", "6"]
    },
    {
      "wave": 2,
      "tasks": ["2", "7"]
    },
    {
      "wave": 3,
      "tasks": ["3"]
    },
    {
      "wave": 4,
      "tasks": ["4", "5"]
    },
    {
      "wave": 5,
      "tasks": ["8"]
    },
    {
      "wave": 6,
      "tasks": ["9"]
    },
    {
      "wave": 7,
      "tasks": ["10"]
    }
  ]
}
```

## Notes

- **Task 1 & 2 priority**: Must run first to diagnose root cause correctly
- **Task 3 analysis**: Critical decision point — all subsequent work depends on this
- **Task 6 independent**: Can work on error captions while waiting for diagnostic results
- **Task 8 blocker**: Regression test only writes after root cause is fixed
- **Manual test (Task 9)**: Should confirm the fix works in real gameplay before returning to CHECKPOINT 6
