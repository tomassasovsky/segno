Model: Claude Opus (subagent), in-session
Base: 2cf6c3adfc19b0e229717fe4b6d1748267b0c17a (codex/shared-playback-choice)
Head: 8749688c51912f808c3f36d4eb5bca665ede3ade (codex/shared-record-length)

# PR #1097 review: shared Record length

Read-only. I read AGENTS.md and the plan at the head and traced the production diff. Nothing was built or run. The conversion, the nine identities, explicit-Auto membership, Released into the restart vector, durable session capture and the lock order match the plan.

## Introduced defects

**1. [High] Capture that starts after a vector was applied is treated as unexplained, which stops the engine mid-take.** `looper_repository.dart:1178-1198`, `_failLength` at `:1203-1212`.
- Trigger: a length or mode request is applied by the callback, then a track starts recording before the next 10 ms poll. Examples: a MIDI preset sending a length CC then a Record note; a length pedal still moving when Record is stomped; a count-in ending in that window.
- Impact: `capturing` is true and the vector differs from `priorBars`, so `_failLength` runs `stopEngine()`. That kills the take and blocks restart. The plan says "Never stop recording…", and the native guard already proves the vector landed before capture.
- Fix: accept a match on `pending.bars`. Refuse cleanly only when `pending.bars == priorBars` while capturing. Untested.

**2. [Medium] Entering Multi does not supersede claims on tracks that had an override.** `record_options_cubit.dart:455-460` emits non-null `bars`, and `control_cubit.dart:235-239` supersedes only when `bars` is null.
- Trigger: a latched or held MIDI/External track-length mapping is active, then the mode changes to Multi.
- Impact:
  - The later release is refused by `_editable` (`:399`, `:424`): a toast, `_last = rejected` and an owed retry.
  - Power-off fails. Retry sets applied, but `retireControls` replays the cleanup, which is refused again, so power-off stays blocked until the user leaves Multi.
  - The test at `record_length_dispatch_test.dart:350` misses this because its Released value equals the retired override.
- Fix: on Multi entry, supersede every track target's claims, as the plan says.

**3. [Low-Med] The capture lock stays on while audio is stopped.** `looper_repository.dart:413` reads the native snapshot unconditionally, and `le_engine_stop` (`engine.c:1167`) does not reset `a_state`.
- Trigger: audio stops during a take (including findings 1 and 5).
- Impact: `_editable` (`record_options_cubit.dart:356-359`) refuses every length and mode edit while stopped, with the message "Finish recording". The repository would accept these edits as deferred intent.
- Fix: return `_intendRunning && …`.

**4. [Low, silent behaviour change] Mode persistence changed.**
- `looper_bloc.dart:44-46` no longer persists the settled mode. A mode applied by session load used to survive a reboot; it now reverts to the stored preference.
- Mode changes now go through the length owner. When that owner is uninitialized or recovering, a mode change is refused with the toast "Record length change was not applied", after `requestLooperModeChange` has already closed the chooser.
- State both changes for owner acceptance.

## Inherited-pattern repeats

**5. [High exposure] A timeout stops the engine and ends reconnect supervision, and now also blocks start.**
- Where: the timer at `looper_repository.dart:1146-1156` calls `_failLength`, which calls `stopEngine()`. `startEngine` is then refused at `:2120-2121`.
- Trigger: while a pinned device is unplugged, `_intendRunning` stays true, so any length or mode write is pushed but never drained.
- Impact: after 500 ms the engine stops, reconnect polling ends, and start is blocked until Retry plus a manual start. The timer fires even with no waiter. Repeats #1094-1.
- Fix: while the device is absent or reconnecting, treat the write as a stopped-engine (deferred) edit.

**6. [Medium] Flush reports the last historical outcome.** `record_options_cubit.dart:514-527`, `app.dart:757`.
- Trigger: the resolver offers length targets while capture is locked, so every CC moved during a take is `rejected`.
- Impact: the first power-off after any such refusal fails, and the refusal toast keeps reappearing during performance.
- Fix: report current state, not history.

**7. [Low likelihood, high consequence] Fail-closed decoding with no repair.**
- Where: `settings_repository.dart:889,920` throw on an out-of-range value. `audio_bootstrap.dart:113-123` then skips auto-start with `recoveryConfig: null`.
- Impact:
  - `recoverRecordLength` reruns `_restoreLength`, which throws again.
  - `runRecordExclusive` throws, so Session Save and Load fail.
  - Power-off Retry can never succeed.
- This repeats #1095-2.

**8. [Low-Med] Storage is rolled back after the repository has already accepted the write.**
- Where: `record_options_cubit.dart:447-450` throws superseded when `!current()` becomes true after the settle returned ok. The catch at `:475-477` then restores the old checkpoint.
- Trigger: a device restart bumps `mixGeneration` between the receipt and the cubit resuming.
- Impact: the repository already installed the new vectors, so Settings disagrees and the value reverts on next launch. Repeats #1096-2.
- Fix: once the settle returns ok, treat the write as committed.

**9. Copy-paste and ownership.**
- `_supersedeRecordLengthClaims` (`control_midi.dart:1187`) is identical to the OneShot (`:1164`) and Decay (`:1141`) versions.
- A sixth `|| target is RecordLengthValueTarget` was added at `control_cubit.dart:617,728,809` and `control_midi.dart:722`.
- The dispatch blocks at `control_cubit.dart:1027-1053` and `control_midi.dart:908-938` copy the OneShot ones.
- ControlCubit and LooperBloc now also depend on RecordOptionsCubit, which additionally owns the looper-mode transaction.
- Fix: one owned-target helper (as #1095-4/#1096-4).

## Preexisting debt / nits
- `LooperTrackLengthPresetChanged` (`looper_bloc.dart:765`) has no dispatcher left in `lib/`.
- Bootstrap and `_restoreLength` both apply the startup vector.
- `_write` does not settle the startup receipt first, so an edit within about 20 ms of a start is refused (`looper_repository.dart:1105`).

## Optional tests
- In the fake engine, flip a track to recording after the vector publishes but before the poll. Expect ok and zero stops (finding 1).
- Latch a track hold with Released different from the retired value, enter Multi, release, then power-off flush. Expect ok (finding 2).
- Stop during a take, then call `setDefaultLengthBars` while stopped. Expect a deferred apply (finding 3).
- With the device absent and commands never settling, run a length write. Expect reconnect to stay armed (finding 5).
- Oracles: dispatch and receipt tests use literal values against the real cubit and repository over a fake engine, so they are independent.

Verdict: request changes. Finding 1 can interrupt a live take, finding 2 can block power-off, and finding 5 disables auto-reconnect.

- F1 High: post-apply capture at receipt -> stopEngine mid-take (looper_repository.dart:1178-1198)
- F2 Medium: Multi entry keeps override-track claims; refused release blocks power-off in Multi (record_options_cubit.dart:455-460, control_cubit.dart:235-239)
- F3 Low-Med: capture lock read from stale snapshot while stopped (looper_repository.dart:413)
- F4 Low: session mode no longer persisted; mode refusals mislabelled as Record length (looper_bloc.dart:44)
- F5 High exposure (inherited): timeout stops engine, kills reconnect, blocks start (looper_repository.dart:1146-1212, 2120)
- F6 Medium (inherited): flush returns historical rejected (record_options_cubit.dart:514-527)
- F7 Low/High-consequence (inherited): strict decode blocks start/session/power-off with no repair (settings_repository.dart:889,920; audio_bootstrap.dart:113)
- F8 Low-Med (inherited): storage rollback after accepted receipt (record_options_cubit.dart:447-450)
- F9 Maintainability (inherited): copied blocks, is-chains, Cubit-to-Cubit ports
