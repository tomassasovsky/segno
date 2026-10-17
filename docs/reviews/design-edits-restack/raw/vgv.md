# VGV Code Review

## Summary

Reviewed the complete 34-file reconstructed slice-2a diff against `09c8e9c2d79d2bb5c1090319db6ae6b223cb92a9`, including the staged merge of `6cdfb9fb`, generated bindings, test adaptations, and changed callers. The accepted removal of clear-before-mode-switch is implemented through the engine's gate, the repository owns grouped edit metadata, and presentation dispatches through Bloc/repository boundaries. The initial review found four actionable recovery/state-ownership defects. Independent follow-up has resolved the three repository/Bloc findings; the native mode-history correction still awaits its author's completion and final independent re-review.

This report evaluates the initial reconstructed content, before the corrective work assigned during this review. Earlier PR CI, later-tip validation, and historical ledger counts do not certify this revision. Hardware timing and appliance behavior are not verified here.

## Initial Critical Findings

The descriptions below preserve the initial evidence. Current status is recorded in the follow-up section at the end.

### Count mode reports before suppressing an equal projection

- **Location:** `packages/looper_repository/lib/src/looper_repository.dart:656`
- **Why:** `_poll` returns when the projected state equals `_last` before `_rememberLooperMode` counts the report. An accepted mode request that the audio thread drops can therefore remain the repository's intended mode indefinitely on a stationary rig. The twelve-report timeout counts changing projections, not polls; stopping/restarting can replay the rejected mode. The existing regression advances master position every iteration and misses this case.
- **Reproduction:** Start a repository reporting a connected, unchanged Multi snapshot, request Band, then deliver fifteen unchanged snapshots. `intendedLooperMode` remains Band instead of returning to Multi. A temporary behavioral test against this checkout fails this exact assertion.
- **Fix:** Reconcile the pending mode request on every actual poll before projection deduplication, while keeping local re-projections outside the report counter. Add a stationary-snapshot regression and verify restart replay follows the reported mode after rejection.

### Correct the persisted mode when an accepted request is later dropped

- **Location:** `lib/looper/bloc/looper_bloc.dart:496`
- **Why:** `LooperModeChanged` immediately persists the requested repository intent. `LooperStateUpdated` only persists a mode when it differs from the Bloc's previous reported mode. If Multi rejects a queued Band request, every report remains Multi, so no correction reaches settings even after the repository's request timeout successfully returns its intent to Multi. The next application launch then loads Band, contradicting the stated reported-mode ownership rule.
- **Reproduction:** With a real repository, Bloc, and in-memory settings, request Band while the fake engine continues reporting Multi. Advance fifteen distinct master-position reports so the repository timeout completes. The repository reports intended Multi, but `loadLooperMode()` still returns Band (`3` rather than `0`). A temporary behavioral test fails the durable-setting assertion while passing the repository-intent assertion.
- **Fix:** Make accepted/rejected request settlement observable to the persistence owner, or persist confirmed running modes while separately handling choices made with a closed engine. Cover both late rejection and offline selection with real repository-to-Bloc-to-settings behavior; do not rely only on reported-mode changes.

### Preserve frozen restore metadata when redo cancels its waiting undo

- **Location:** `packages/looper_repository/lib/src/looper_repository.dart:1767`
- **Why:** When a grouped undo is waiting for a frozen capture's restore point, redo removes both the waiting tap and `_clearRestore`, even though the original native clear remains restorable. After the point lands, the next undo restores the audio without its saved lane effects, enable flags, or provenance. The same path puts the still-pending member directly into `_clearAllGroup`; an intactness check before its report arrives treats the pending point as retired and dissolves the group.
- **Reproduction:** Clear All with one completed member and one capturing member carrying a lane effect. Undo, then redo before the capture's frozen report lands. If the report then arrives, another grouped undo restores an empty effect list instead of the original effect. If `undoRestoresClearAll` is queried before the report arrives, it returns false and ends the group. Separate temporary tests fail both assertions.
- **Fix:** Cancel only the waiting undo, retain the original restore metadata, and rebuild the re-cleared group's confirmed and pending membership separately. Test the complete clear → undo → immediate redo → undo cycle with a frozen member, saved lane metadata, and a query while its point is still pending.

### Reconcile restored history with the current looper mode

- **Location:** `packages/segno_engine/src/core/engine_process.c:317`; affected history callers at `LE_CMD_RESTORE_CLEAR` (`:2329`) and `LE_CMD_REDO_FROM_EMPTY`.
- **Why:** Mode switching now preserves undo/redo history while changing clock ownership. The existing restore path still assumes that a clear point's saved master belongs to the current mode: it restores `cmd->restore.master_len` before checking Free/Song. Conversely, a Free/Song clear point has no saved shared master, so restoring it after switching to Multi leaves a populated shared-clock rig with no master. These old restore invariants must change with the new switch behavior.
- **Reproduction:** A native runner built from this checkout records a 2,000-frame Multi take, clears it, switches to Free, and undoes the clear. The snapshot incorrectly reports a 2,000-frame shared master. A new Free sibling recorded for 500 frames becomes 2,000 frames. The inverse sequence—500-frame Free take, clear, switch to Multi, undo—reports take length 500 and master length 0. All three expected clock/duration assertions fail.
- **Fix:** Restore clocks according to the current mode, keeping Free/Song's master dormant and establishing the correct shared base when history restores the first Multi/Sync/Band take. Apply the rule to both clear restoration and redo-from-empty, preserve audio lengths, and add native tests across both directions and subsequent recording/playback.

## Important — Should Fix

None separate from the correctness fixes and regression coverage above.

## Suggestions — Nice to Have

None. Stale explanatory comments were not promoted into preference-only findings.

## Simplicity Assessment

- Lines that could be removed: no independent deletion recommendation. The request settlement paths should have one observable owner rather than relying on two partially overlapping persistence triggers.
- Unnecessary abstractions: none identified. The native gate and repository-level grouped edit are appropriate boundaries for these behaviors.
- YAGNI violations: none identified. Removed clear-before-switch UI and strings reflect the accepted behavioral change, not a compatibility shim.
- Complexity verdict: the main layering is appropriate; the remaining complexity is in asynchronous history and request settlement, where the failing cases need explicit invariants.

## Testing Assessment

- Reviewed native mode/cancel/freeze race tests, Dart engine bindings and fakes, repository grouped undo/redo tests, Bloc persistence tests, and chooser/controller widget adaptations.
- Existing tests meaningfully cover mode gates, content preservation, recording cancellation, overdub punch-out, frozen restoration, and queue ordering. They miss stationary request settlement, durable late rejection, a second recovery cycle after parked redo, and history restoration across mode ownership changes.
- Reviewer execution: four temporary Dart behavioral checks failed as described above. A separately compiled native runner failed the three clock/duration assertions described above. The temporary runners changed no repository implementation files.
- Full analyzer, coverage, native configurations, and application suites remain the parent's validation responsibility for the corrected current content. No historical check result is substituted for those gates.

## Independent Follow-up — Repository and Bloc

Reviewed the corrections in `looper_repository.dart` and `looper_bloc.dart`, the updated package group tests, the existing Bloc test adaptations, and the new `test/looper/bloc/looper_mode_persistence_test.dart` against the original failing sequences.

- **Resolved — Count mode reports before suppressing an equal projection.** Poll reconciliation now runs before equality suppression. Local re-projections can confirm a request but do not advance its grace counter. The package regression holds the snapshot constant for twelve polls, checks settlement to the reported mode, and verifies the next start replays that settled mode.
- **Resolved — Correct persisted mode after a late rejection.** The repository exposes a nullable `settledLooperMode`; pending running-engine requests are not eligible for persistence. Settlement publishes one repository update even when the visible value is unchanged. The Bloc processes that update before its own emission deduplication and deduplicates persisted mode separately. The real repository/Bloc/settings tests verify confirmed selection, rejection on stationary reports, offline selection, and a rejected boot replay returning durable settings to the engine's mode.
- **Resolved — Preserve frozen restore metadata when redo cancels its waiting undo.** Redo retains the frozen member's metadata and puts it back into pending membership. The extended test queries group integrity before the report arrives, then restores the take and repeats the redo/undo cycle, checking lane effects, enable flags, and provenance on every member.
- **Pending — Reconcile restored history with the current looper mode.** The native author was still editing at this follow-up boundary. No partial native change is marked reviewed here.

Independent execution on the corrected repository/Bloc content: 28 selected tests passed, covering the two new end-to-end persistence tests, repository mode/grouped-edit groups, and matching restart/session mode cases. No new actionable repository/Bloc issue was found. Full final-head gates and native follow-up remain separate obligations.
