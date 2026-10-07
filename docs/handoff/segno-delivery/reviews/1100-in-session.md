Model: Claude Fable 5.1 (subagent, extra-high effort), in-session
Base: 505fbcad19303b78396035c807409ee5a706f132 (codex/shared-hear-click)  Head: 92a35f7a30272c330e39250cf28e21ea74d36b99 (codex/record-start-pair, PR #1100)

# PR #1100 review: confirm count-in and sound start together

Read-only. Read AGENTS.md, the delivery plan and the part-1 plan at head, the full native diff and head copies of engine_commands.c / engine_process.c / engine.c / lockfree_ring.h, the repository, Settings, TempoCubit, bootstrap, App and Session changes, and the new native/Dart tests. Prior reports #1093-#1096 and #1120 were read to avoid repeats. Nothing was built or run.

## Introduced defects

### 1. A contradictory stored pair is a permanent dead end: no audio at boot, no Save, no clean power-off (medium; high consequence)
- `lib/app/audio_bootstrap.dart:39-59`: `RecordStartSettings.fromCheckpoint` rethrows the Settings `FormatException` (`settings_repository.dart:873`), auto-start is skipped with `recoveryConfig: null`, so the recovery supervisor never opens the device.
- `lib/looper/cubit/tempo_cubit.dart:624-690`: the same read fails in `_restoreRecordStart`; `_startInitialized` stays false. `recoverRecordStart` (833-890) only restores `_startStoreRecovery`, which is null here, then re-runs `_restoreRecordStart` (885) and fails identically. Nothing in the app can rewrite the keys.
- Consequences: all four surfaces show "unavailable" forever; `runTempoExclusive` (970-977) throws, so Session Save and Load fail; `flushRecordStart` (807-830) reports `recoveryRequired`, so power-off Retry (`app.dart:942`) throws every time and the only exit is "Keep playing" or pulling power.
- Trigger is real for installed units: the pre-PR writers persisted the two keys concurrently (`Future.wait([saveAutoRecord, saveCountInBars(0)])` and the mirror in TempoCubit). A power cut between the two writes leaves `count_in_bars > 0` with `auto_record = true`, which this PR now classifies as malformed. `record_start_transaction_test.dart:251` ("raw data survives retry") encodes the dead end rather than a repair.
- The plan says invalid storage must "require recovery", not that recovery must be impossible. AGENTS.md: never trade a working product.
- Smallest fix: make Retry the explicit repair. In `recoverRecordStart`, when `fromCheckpoint` throws, write an explicit valid pair (`(0,false)`, or the app default) through `restoreRecordStartCheckpoint`, then re-run the restore. In bootstrap, start the engine with the fresh-engine Off pair and leave only the pair unavailable, as the plan's "fresh native engine starts Off" already allows.

### 2. Native side holds up (no defect found)
Traced and consistent: single-flight reservation (`engine_commands.c:2654-2690`) released only by `a_commands_published`; the callback re-checks capture and publishes a result on refusal (`engine_process.c:3031-3058`); the revision is stored before the `a_commands_published` release (6329-6333) and the repository reads `commandsSettled` before `snapshot()` (`looper_repository.dart:7169-7173`); configure resets receipt counters and keeps the confirmed pair (`engine.c:401-405`); raw posts are refused (1276). The `cancel_count_in` flag (`lockfree_ring.h:90`, `engine_commands.c:1370-1380`, `engine_process.c:2501-2508`) correctly prevents a cancel press that lands after a queued pair edit from becoming a fresh countdown (covered by `test_record_start_owned_cancel_survives_queued_pair`), and the grace-channel case still reaches `handle_record`'s cancel-wins branch. `le_classify_record` returns CANCEL whenever `a_counting_in` is set, so cancellation is never blocked by the new ACQUIRE fences. The no-source guard is enforced on both sides (`engine_commands.c:1345-1359`, `looper_repository.dart:2951-2963`) and the per-frame trigger loop (`engine_process.c:4811-4826`) reads only selected, non-excluded lanes with no allocation.

## Inherited-pattern repeats

### 3. Pair edit while the device is unplugged stops the engine, ends reconnect and blocks restart (repeat of #1094 F1, #1096 F6)
- `looper_repository.dart:7198-7207`: a 500 ms receipt timeout calls `stopEngine()` (which stops reconnect polling) and sets `_recordStartRecovery`; `startEngine` then returns `notReady` (2466-2473) until the toast Retry runs `recoverRecordStartSettings`.
- Trigger: interface unplugged (engine configured, callback stopped), user toggles Sound or Count-in. Before this PR the edit was a plain push that the reconnect replayed.
- Fix: while the device is absent, treat the edit like a stopped edit (stage, return ok, replay on restart); at minimum do not record recovery for a timeout during reconnect.

### 4. Storage rolled back after the repository accepted the receipt (repeat of #1096 F2)
- `tempo_cubit.dart:758-760, 774`: `settleRecordStartSettings()` returns ok (the repository has adopted the pair and will replay it), then `current()` fails because a device restart or session bump landed in between, and the catch block restores the old checkpoint. Engine and screen show the new pair; the next boot reverts it.
- Fix: once settle returns ok, report `superseded` without the storage rollback.

## Low

### 5. Play is refused for the whole recovery lifetime, not just the pending window
- `looper_repository.dart:3208-3211` fences `play()` on `recordStartRecoveryRequired`. The native fence (`engine_commands.c:1669-1671`) covers only the one-block pending window. The one running-engine recovery case is a receipt stall during capture (7205 keeps the engine up), where Retry is also refused (7233), so Play on every track is dead for the rest of the take. Fence on `!recordStartSettingsSettled` only.

### 6. Deterministic session refusal detected only after the rig is cleared (same shape as #1096 F3)
- `applySession` validates mix, grid and tempo before `_awaitCleared` but not the pair; `setRecordStartSettings` returns `invalid` for `countInBars` outside {0,1,2,4} or count > 0 with Sound (3900-3908), and `_requireSessionSetting` throws after the clear. `session.dart:778` decodes without a range check. Validate the pair at the top of `applySession` or at decode.

### 7. Double report on timeout
- `tempo_cubit.dart:195-209` emits `recoveryRequired` from the failure stream when `recordStartRecoveryRequired` is already true, and the `_writeRecordStart` catch (785-800) emits it again for the same failure. Same toast id, so cosmetic.

## Preexisting debt (noted, not introduced)
- `_cancelRecordStart` (7095-7103) leaves `_lastRecordStartResult = notReady`, as `_cancelOneShot` does; here `flushRecordStart` checks `wasSettled` and the stopped path resets it, so it does not poison flush. Good.
- The startup vector is applied twice (bootstrap stage + cubit restore), as with Once/Decay.

## Optional tests
- Contradictory storage, then Retry: assert audio starts and Retry repairs (fails today by design of test 251).
- Pair edit with publishing off while `_intendRunning` is true and the device marked lost: assert reconnect stays armed and `startEngine` is not blocked.
- Session JSON with `countInBars: 3`: assert the rig is not cleared.
- Oracles: native tests use literal snapshot checks with a publication hook; repository tests drive a fake engine with explicit `nextSnapshot` receipts; TempoCubit tests enumerate literal saved/expected pairs. None derive expectations from `fromCheckpoint`. Independent enough.

## Nits
- `engine_commands.c:1418-1419`: the lane-growth block's `if (a_counting_in) return le_push(...)` is unreachable after the new branch at 1370.
- `cancel_count_in` lies beyond the generic `{arg_i, arg_f}` arm; generic RECORD pushes (`engine.c:1316-1319`) rely on the compiler zero-filling the union tail. Set `.clock.cancel_count_in = 0` explicitly or memset.
- `looper_repository.dart:7164-7166`: `_pendingRecordStart == null ? ... : ok` is a dead branch right after assignment.
- `looper_repository.dart:2961`: `_recordingInputRequired.add` has no `isClosed` guard, unlike `_reportRecordStart`.
- `looper_repository.dart:7136`: `prior` is read without first acquiring `commandsSettled`, although the API doc (`segno_engine_api.h` setter comment) asks for that order; the pending fence makes it practically safe.
- `_startReady` (599) includes `!_startApplying`, so every edit flips the subtitle to "unavailable" and drops taps during the write instead of coalescing them (#1094 F2 inverted).

## Verdict
Request changes: one reachable dead end with no repair path (finding 1), two inherited defects re-introduced for a new setting (3, 4).

- F1 medium: contradictory stored pair blocks audio start, Save and power-off with no repair path (bootstrap:39-59, tempo_cubit:624-690, 833-890).
- F2 none: native receipt, cancellation, no-source and RT paths hold up as traced.
- F3 repeat: edit during device loss stops the engine, ends reconnect, blocks restart (looper_repository:7198-7207, 2466-2473).
- F4 repeat: storage rolled back after accepted receipt on lifetime bump (tempo_cubit:758-774).
- F5 low: Play fenced through recovery, dead during a capture-time stall (looper_repository:3208, 7233).
- F6 low: invalid session pair refused after the rig is cleared (looper_repository:3900-3908, session.dart:778).
- F7 cosmetic: duplicate recoveryRequired report on timeout (tempo_cubit:195-209, 785-800).
