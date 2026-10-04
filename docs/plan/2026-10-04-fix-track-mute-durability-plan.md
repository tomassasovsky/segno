# Preserve accepted track mute across restart

Issue #1127, prerequisite of Foot Mixer #1123. Human merge gate. Build after
monitor-mute admission #1125; do not mix the two publication diffs.

## Reproduced problem

An ordinary whole-track mute reaches audio and a saved Session but does not
update the existing lane-mute Settings keys. Cold bootstrap restores the old
value. The equivalent individual-lane action does persist. Session boot
synchronization also omits lane-mute keys, leaving the previous session's values.

## Existing ownership

Keep native admission and remembered intent in LooperRepository. Keep Settings
access at the application boundary. Native admission is immediate; durability
completes asynchronously and must not be inferred from that admission. Reuse the existing persistence owner and
its Session/shutdown barriers; do not add another queue, mutable mute cache,
storage format, migration, native API or Foot Mixer destination.

1. Validate lane identity and publish intent only after native admission. Preserve the existing whole-track
   result aggregation, which already retains any lane failure. Reuse
   remembered intent when composing rapid toggles rather than a stale polled
   snapshot. Accept valid stopped-engine intent explicitly and verify restart replay.
   Check startup replay, bootstrap lane restore and imported Session lane-mute
   results, using their existing stop/failure paths rather than discarding refusal.
2. Persist accepted lane values through the existing lane-address save path and
   existing `lane_mute` keys. Serialize and verify scalar writes using existing
   Settings facilities. Reuse retained failure and explicit flush/retry behavior.
3. Share the small application operation between Looper and Control; neither
   state owner may call the other. Preserve transport decisions in Control.
   Extract only an immediately used operation, with no new timer or state owner.
   Before any ordinary native write, honor the existing Session transition guard.
   Report non-success native results at Looper and Control callers. Observe the
   existing `saveConfirmed` Future for asynchronous write errors through their
   existing error paths; scheduling a save alone is not evidence of durability.
   Retain the same failed write for flush/shutdown retry, without another stream.
4. Include each accepted lane's mute in the existing immutable Session boot
   image. Reset omitted lane slots so stale mute cannot return after restart.
   Keep the existing load barrier until storage and read-back succeed.

## Caller behavior

- Ordinary whole-track, individual-lane, and mapped mute actions persist actual
  accepted lane state.
- Mute/Rec transport gestures keep their current park, play and recording rules.
  A failed prerequisite mute cannot advance a dependent transport action.
- Clear resets mute durably through the shared path. Fresh takes and Redo from
  empty also clear remembered mute; their existing lane persistence notification
  must save that accepted reset. Session import keeps its separate boot image.
  Parking membership alone remains a transport fact, with no invented mute write.
- Bootstrap reads saved intent. Session import uses the existing Session boot
  transaction, not ordinary user-toggle persistence.

Native lane mute is not an atomic all-lane command. If some lanes accept and
another refuses, keep and persist the accepted lane values, report failure for
the group, and allow deliberate retry. Do not claim rollback or save a rejected
requested value. Whole-track mute continues to reflect all active lanes.

## Bounded paths

Production candidates: LooperRepository, SettingsRepository scalar lane-mute
write, FxChainPersistence lane/Session image, LooperBloc and ControlCubit callers,
and one small immediately used application operation if it avoids duplication.
Change AppRuntime only if that operation requires composition. No native or
firmware changes. Review scope before building; avoid an ownership rewrite.

## Verification

Use real application/repository owners and the existing AudioEngine seam.
Keep the original ordinary-mute regression and passing lane control. Verify
actual stored values and cold bootstrap, not just method calls.

- Accepted whole-track and lane changes survive cold bootstrap and Session load.
  Include existing `test/app/audio_bootstrap_test.dart` and
  `packages/settings_repository/test/settings_repository_test.dart` suites for
  the changed storage and restart boundaries.
- Multi-lane refusal preserves each actual accepted value; explicit retry works.
- Ordinary mute during a Session transition reaches neither native nor storage.
  Startup, bootstrap and Session lane-mute refusal stop or fail through existing
  mechanisms instead of reporting a successful restore.
- Rapid mute/unmute with blocked first storage ends unmuted after flush/restart.
- Mutation-then-error storage keeps recovery pending and prevents a successful
  shutdown until retry. Session replacement excludes stale writes.
- Pending FX plus lane mute settles through the existing shared boundary without
  deadlock or a lost update. A delayed controller FX save cannot overwrite a
  newer mute; both use the same lane-address drain. No premature durability claim.
  Preserve already-admitted controller saves through owner close, including
  their actual receipt and storage failures; do not retry failed work on close.
- Clear and Mute-mode transport keep their accepted behavior.

Run focused behavioral tests, then full affected package/application coverage,
strict analysis, explicit formatting and positively scanned Bloc lint on frozen
source. Independent VGV, architecture, test-quality, simplicity, readiness and
bug-focused reviews are required. Additional Claude and device evidence remain
separate from local test claims. No merge or deployment is authorized here.

## Success Criteria

```success-criteria
GOAL: Track mute represents accepted audio state and survives restart through the existing persistence boundary.

SUCCESS CRITERIA:
- Partial and complete native admission remain truthful. | verify: flutter test packages/looper_repository/test/looper_repository_test.dart
- Ordinary and mapped mute preserve transport and persist accepted values. | verify: flutter test test/looper/bloc/looper_bloc_test.dart test/control/control_cubit_test.dart
- Saved Session and shutdown retain or report lane-mute storage failures. | verify: flutter test test/app/fx_chain_persistence_test.dart test/app/application/app_runtime_test.dart test/session/cubit/session_cubit_test.dart
- Edited code passes the project static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages

NON-GOALS:
- Foot Mixer UI, new persistence owners, schemas, DSP, protocols, migrations, deployment or merging.
```

Use the documented SDK and worktree lint wrapper. These are planned obligations,
not executed proof. Review the plan before implementation.
