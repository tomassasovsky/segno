# Track mute durability review

Issue #1127. Base `05900dfcc911fb6491ce9c26cec83c0c5217c8da`
(monitor mute correction #1128). Working revision identified by the 18 exact
source hashes below. Human merge gate.

## Result

Independent VGV, architecture, test-quality, simplicity and readiness reviews
report no unresolved actionable findings on the frozen source. The bug-focused
review covered the complete diff, removed behavior, callers, concurrency,
shutdown, Session and failure paths. Corrections were independently rechecked.

The additional requested Claude review remains pending its usage-limit reset.
The combined review gate is therefore incomplete: keep `review:pending` and do
not mark ready to merge. Remote CI must also pass on the published head.

## Scope and behavior

Ordinary track and lane mute save accepted intent through the existing lane
persistence owner. Refused native commands cannot publish the requested value;
a partial whole-track result preserves each actual lane value. Repeated toggles
read admitted intent instead of a delayed snapshot. Control keeps its transport
decisions and stops dependent playback actions after mute refusal.

Settings serializes and verifies lane-mute writes. Session boot images include
all lane-mute keys, clearing omitted slots. Startup and imported Session replay
check native results. Clear, fresh takes and Redo from empty persist accepted
mute resets through the existing lane notification. Session import retains its
own boot transaction. Ordinary commands honor its reservation before mutation.

One stateless operation is shared by Looper and Control. No new state owner,
queue, storage format, dependency, native API or firmware change is introduced.
Controller FX saves join the existing lane-address drain. Its existing pending
item records whether an admitted controller save must finish during close;
failed work remains observable without creating a new disposal retry.

## Review corrections

- TM-1: A delayed controller FX save bypassed the address queue and could write
  its earlier mute snapshot after a newer mute. The regression failed before
  routing that helper through the existing drain. The direct save path and its
  redundant repository argument were removed.
- That correction initially dropped already-admitted saves during close.
  Existing receipt and parallel-failure tests caught it. The existing work item
  now carries the close obligation until completion or failure, preserving
  actual receipts and reported errors. Later ordinary retries do not inherit
  a finished obligation.
- Fresh recording and Redo reset mute in the engine but could leave a stale
  saved value. Removed true intents now use the existing lane save notification;
  destructive Session clear suppresses ordinary notifications.

## Validation

- Full app: 3,035 passed, 49 conditional skips, zero failures. Coverage
  27,283 / 29,558 (92.3033%, required 90%), using the actual CI exclusions.
- Full LooperRepository: 740 passed, zero skipped; coverage 4,579 / 4,780
  (95.7950%, required 95%).
- Full SettingsRepository: 194 passed, zero skipped; coverage 785 / 857
  (91.5986%; no separate threshold in the current workflow).
- The final focused persistence/lifetime suite passed all 52 cases. The 54
  native caller cases also passed without skips using the existing immutable
  test library. These overlap the aggregate and are not added to its totals.
- Strict analysis of `lib test packages`: clean. Formatting: 18 files unchanged.
  Bloc lint positively scanned 795 files, zero issues. Diff whitespace: clean.
- All 18 source hashes stayed unchanged throughout aggregate verification.
  All 612 native/build/binding inputs match the prior verified revision; existing
  native evidence was reused instead of rebuilding unchanged native code.

Conditional skips are not visual proof. Command admission and device-free
persistence tests do not prove physical appliance audio. Additional Claude
review and remote CI remain separate gates.

## Diff size

- Production: 260 added, 114 removed, net 146 lines.
- Tests: 823 added, 15 removed, net 808 lines.

Tests include real owner/bootstrap, Session, failure and shutdown journeys.
The new persistence integration test is intentionally counted separately from
production changes. No accepted UI or Pen geometry changes are in this slice.

## Source hashes

| Path | SHA-256 |
| --- | --- |
| `lib/app/audio_bootstrap.dart` | `5e5b58f9efb48834d1b0f7fa0403f1160c7acad81502ac0ad6e67f7585fd4fa6` |
| `lib/app/fx_chain_persistence.dart` | `ffc0b5058cdee772052e89b55c4e824f3681587461f7e0563b95417d8196d259` |
| `lib/control/cubit/control_cubit.dart` | `9f0414560819499c155c7ed8e35ba1d0150212ea920331d43e998e1b4e1553ce` |
| `lib/control/cubit/control_midi.dart` | `5e56743f1e6e583988691e67996182579eccf433a090b8b00e35b554e8e2e64c` |
| `lib/looper/bloc/looper_bloc.dart` | `e036b6d9991454223f2308545677a29d9ec26771b23eaa751b83d495c22af531` |
| `packages/looper_repository/lib/src/looper_repository.dart` | `ab555f29c2465c9917410dc5a71c59341c60e45e0493aa02de7d6305406a3e31` |
| `packages/looper_repository/test/looper_repository_test.dart` | `b399a2c37b194224b366a2d809b487133f0d7e5ef4e5ca9c48c4143278b41222` |
| `packages/settings_repository/lib/src/settings_repository.dart` | `9c3743c6971f6a83d87a7b871a9d57a32d09747e77971b870e800563497616f9` |
| `packages/settings_repository/test/settings_repository_test.dart` | `eeb4982da5a01c2e09f2e2b85372df32c631e37771efd0383202a87b77f75940` |
| `test/app/application/app_runtime_test.dart` | `3d3f01113e014ce62e9d2d11228db404fc66bf8d81f89a2ac2620681449e429c` |
| `test/app/audio_bootstrap_test.dart` | `5686c9c491ace9dff09d0f11b379274258b62670626137a7d3923b41554a9cb9` |
| `test/app/fx_chain_persistence_test.dart` | `c9dfb68444b231af26337cf52d50445b55c5226210d9c06057d742e801851b28` |
| `test/common/fx_chain_persistence_test.dart` | `73a243f18ff3a1722c366f0b6d37171db018565d293079b7c7712273f4aa8eb8` |
| `test/control/control_cubit_test.dart` | `b724ed25ed783b551b5fdb057a29f9852da049b285e8d4baf89a3d6a62082423` |
| `test/looper/bloc/looper_bloc_test.dart` | `b014b3ebf168bd6e93b09cc13ebe30c4d178209283764a839eaa6edf536d9086` |
| `test/session/cubit/session_cubit_test.dart` | `69662deaecbc8f8333672c38d71a3004c6a4e04a6360445ad8587eda6dfe5a8a` |
| `lib/app/track_mute.dart` | `fab6d00b588507bec9b69898d2bb783d0bdb175f6ec6ae7e9fe4ef1504779913` |
| `test/looper/bloc/track_mute_persistence_test.dart` | `9c23c0bfea9c58a77402164c34d0669e7953c706e3aa68e02e2bd9bbf6ad4681` |
