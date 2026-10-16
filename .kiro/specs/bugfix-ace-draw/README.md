# Bugfix Spec: Stock Draw Move Rejection

**Status**: Ready for Investigation
**Priority**: Critical (blocks CHECKPOINT 6)
**Created**: 2026-10-01

## Quick Summary

Users cannot move cards after drawing them from the stock. Specifically:
- Draw stock card → appears in waste, looks legal, but all drop attempts spring back
- No error caption shown
- Tests pass (rules layer is correct)
- Issue is in UI/state reconciliation layer

## Root Cause (Unknown — To Be Diagnosed)

Three hypotheses under investigation:

1. **Hypothesis A**: State sync divergence after draw
2. **Hypothesis B**: Zone ID mismatch in adapter 
3. **Hypothesis C**: Face map incomplete after draw

See `design.md` for detailed analysis and testing strategy.

## Workflow

This spec uses the **bugfix workflow**:

1. **Phase 1 (Diagnostic)**: Run tests to pinpoint root cause
2. **Phase 2 (Fix)**: Apply targeted fix based on diagnosis
3. **Phase 3 (Polish)**: Add better error reporting
4. **Phase 4 (Verify)**: Regression test + manual verification

## Files

- `requirements.md` — Problem definition, hypotheses, acceptance criteria
- `design.md` — Investigation strategy, implementation plan
- `tasks.md` — Actionable steps (tests, code fixes, verification)
- `README.md` — This file

## Next Steps

1. Start with **Task 1.1** (diagnostic test)
2. Run **Task 1.3** (analyze results)
3. Execute the appropriate fix task (2.1 or 2.2)
4. Complete **Task 3.1** (error reporting)
5. Verify with **Task 5.1** (manual test)

## Blockers

This bugfix is **blocking**:
- ⛳ **CHECKPOINT 6** — Accessibility manual review (user can't play games)
- Cannot proceed to Phase 8 (quality gates) until core gameplay works

Once fixed, user returns to CHECKPOINT 6.

---

**Estimated Effort**: 2-4 hours investigation + fix + verification
**Risk**: Medium (state sync issues are tricky; good test coverage helps)
**Success Criteria**: User can move Aces and other cards after drawing; no spring-back

