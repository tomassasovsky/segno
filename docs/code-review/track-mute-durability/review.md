# Track mute durability review

Issue #1127. Base `05900dfcc911fb6491ce9c26cec83c0c5217c8da`
(monitor mute correction #1128). Working revision identified by the 18 exact
source hashes below. Human merge gate.

## Result

Independent VGV, architecture, test-quality, simplicity and readiness reviews
report no unresolved actionable findings on the frozen source. The bug-focused
review covered the complete diff, removed behavior, callers, concurrency,
shutdown, Session and failure paths. Corrections were independently rechecked.

Actual Claude Opus 5 review completed on published head
`5704e2fed795274368ff5bad2fcbba22c8d73d6e`. It found the two additional cases
below, both reproduced before repair. The corrected three-file production delta
has an independent bug/architecture review with no actionable findings; its independent test review is also clean. Claude re-review and remote CI on the next published head
remain pending, so retain `review:pending` and do not mark ready to merge.

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

### Additional adversarial corrections

- TM-2: After failed startup, muting a track rewrote its unrestored lane FX
  envelope. The mute operation now requests only its own saved scalar through
  the same address queue. Coalescing preserves any pending complete FX save,
  regardless of request order. A real failed-bootstrap regression checks saved
  bytes and fresh restart, including effect parameters, bypass and provenance.
- TM-3: A later native mute refusal could follow an earlier track's playback
  start. All required mutes now precede any play call; refusal retains the
  selected resume membership for retry. Parked and running multi-track cases,
  plus a deselected parked-track refusal, preserve that prerequisite boundary.

## Validation

The corrected source passed 3,041 full app tests with 49 conditional skips and
92.31% coverage (90% required), strict analysis of `lib test packages`, explicit
formatting, positive Bloc lint of 795 files and diff whitespace checks. Source
and native-library hashes stayed unchanged throughout this run. The six added
regressions/control cases are included in that total; three failed before repair.

The unchanged repository source retains the published prerequisite evidence:
740 LooperRepository tests, zero skips, 95.7950% coverage; 194 SettingsRepository
tests, zero skips, 91.5986% coverage. None of the 612 native/build/binding inputs
changed. No redundant native rebuild was used to imply new hardware evidence.

Conditional skips are not visual proof. Command admission and device-free
persistence tests do not prove physical appliance audio. Additional Claude
re-review and remote CI remain separate gates.

## Diff size

- Production: 305 added, 115 removed, net 190 lines.
- Tests: 955 added, 15 removed, net 940 lines.

Tests include real owner/bootstrap, Session, failure and shutdown journeys.
The new persistence integration test is intentionally counted separately from
production changes. No accepted UI or Pen geometry changes are in this slice.

## Source hashes

| Path | SHA-256 |
| --- | --- |
| `lib/app/audio_bootstrap.dart` | `5e5b58f9efb48834d1b0f7fa0403f1160c7acad81502ac0ad6e67f7585fd4fa6` |
| `lib/app/fx_chain_persistence.dart` | `6982dc0751fae51252e6613bd384f5eb8fe6e5a3237a9bb9190687266307d385` |
| `lib/control/cubit/control_cubit.dart` | `843007fd33aaf1c95c9b4dcd5a12626f21967c525aec4365e00e91072e582e63` |
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
| `test/control/control_cubit_test.dart` | `03e2263fbb9e3dafb1f2c9a83b475eec27bc8611739700e8c619633a0f4a06a9` |
| `test/looper/bloc/looper_bloc_test.dart` | `b014b3ebf168bd6e93b09cc13ebe30c4d178209283764a839eaa6edf536d9086` |
| `test/session/cubit/session_cubit_test.dart` | `69662deaecbc8f8333672c38d71a3004c6a4e04a6360445ad8587eda6dfe5a8a` |
| `lib/app/track_mute.dart` | `ec0b376c345b7d08bd6a77cca286bd4c75a74ca07c8c4e7b66163f7e51c871f4` |
| `test/looper/bloc/track_mute_persistence_test.dart` | `927eb5678a6d90b57f3b8f3534c87d67152d2b45bf197d59ed00c1ba31989894` |
