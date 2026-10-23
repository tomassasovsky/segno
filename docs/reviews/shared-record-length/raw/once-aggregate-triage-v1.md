# M3.14 aggregate Once failure triage

Read-only; no test execution or product/fixture edits. Observed aggregate error: app-tests.jsonl test 844, `one_shot_transaction_test.dart:238`, expected `oneShotRecoveryRequired == true`, actual false. The test is “autonomous reconnect times out without another owner write or flush.”

## Classification

The fixture stalls the global command fence before startup, so it now stalls both Length and Once. M3.14 adds a correctly guarded autonomous Length replay deadline registered before Once. When that deadline fires, `_failLength` → `stopEngine` → `_cancelMix` → `_cancelOneShot` cancels the pending Once receipt and timer. The active failure belongs to Length, so Once-specific recovery need not be true. A later original assertion would also be invalid if it expected Once-only recovery to clear Length's restart block.

This is an isolation gap exposed by the new sibling receipt, not evidence of incorrect Once acceptance or missing engine stop. No product regression has been established. Preserve the failure log. Do not replace the test's specific recovery expectation with any-recovery if the intended behavior remains Once-specific.

There is an additional inherited real-time timing weakness: a 550 ms sleep does not guarantee 50 periodic 10 ms callbacks occurred. The installed Dart timer contract explicitly permits delayed/missed callbacks. Once's callback-count deadline is unchanged from base; the observed false has a stronger concrete sibling-cancellation explanation, so scheduler lateness is not needed to explain it.

## Base comparison

The failing test, PlaybackOptionsCubit and shared fake engine are byte-identical to base `2cf6c3adfc19b0e229717fe4b6d1748267b0c17a`:

- test: `47e52b1165775530cc9c57fcf8ca21e078e10be347c375eb49acf0addb081ab8`
- Playback owner: `8c3c4c8b355eac94cf6a2225708015946be6c1ba57053126f265674873fdd2e5`
- fake engine: `943430c294e96a66b3e2984609091251354f32eadbe679ecd3cc07170f8c4d54`

Repository observed: `bf8d4203942cc2e2427474c9d768fbc8c042b88c3d5f0ef28b628bca021e5c22`. Relevant final locations: startup Length registration around 2191, Once registration around 2212; `_failLength` 1203; `stopEngine` 2506; `_cancelMix` 754; `_cancelOneShot` 7153. Base already had Once's 50 callback counter and cancellation through `_cancelMix`; the new autonomous Length timer supplies the earlier failure.

## Bounded fixture correction recommended to root

Before the specifically stalled Once mask enqueue, allow the already-published healthy Length vector to settle through the actual repository receipt method while the fake fence remains true. A narrow `beforeStalledOnce` engine hook can capture `repository.settleLengthSettings()`; its immediate successful path settles synchronously before its first await. Assert `lengthSettingsSettled`, no Length recovery and the captured result `EngineResult.ok`. Then enqueue the Once mask and lower the command fence. This represents a legitimate native callback between sibling enqueues; it does not replace a receipt result or alter production.

Subscribe to `owner.oneShotFailures.first` before starting, use a bounded timeout, and make no owner write/flush until that autonomous event. Retain true recovery, stopped engine, explicit repair, restart and confirmed final state assertions. A hook that only lowers the fence inside setOneShotMask is insufficient: startup Length suppresses immediate projection and can still be pending. Root owns the patch and focused execution. If pre-stall settlement cannot be demonstrated, reject that fixture rather than weakening the assertions.

For the separate legacy Length timeout fixture, a refused restart before explicit recoverLengthSettings followed by confirmed replay of 4 is the intended new safety behavior; this note did not execute or fully review that separate case.
