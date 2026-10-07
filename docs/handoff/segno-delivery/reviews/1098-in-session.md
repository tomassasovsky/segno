Model: Claude Opus (subagent), in-session
Base: 8749688c51912f808c3f36d4eb5bca665ede3ade (codex/shared-record-length)
Head: 3025840dd212a86ee1b23c21b6980f0ac4866e20 (codex/shared-record-timing)

# PR #1098 review: shared Record timing

Read-only. I read AGENTS.md and the plan at head and traced the production diff. Nothing was built or run.

Traced and correct:
- Native: single in-flight vector, producer and callback capture refusal, scoped trigger-0 cleanup, the seq_cst odd/even tuple with its control-thread cache, and the flat override array in the Dart snapshot. The NOT_READY fence runs before `le_fx_prepare_capture` on both entrypoints, and preflight classification matches `le_record_impl`.
- Held/Released split: live and restart intents, remembered division, and the durable Session capture.
- Two #1094–#1096 patterns are not repeated. A cancel's `notReady` never reaches flush, because a settled flush ignores `_lastTimingResult` and `_restore` overwrites it. A failed startup restore stays unready, because `_initialized` gates `_onLooperState`.

## Introduced defects

### 1. A timing recovery obligation disables the whole Mixer (Medium, silent)
- `packages/looper_repository/lib/src/looper_repository.dart:751` adds `if (recordTimingRecoveryRequired) return EngineResult.notReady;` to `_requestMix`. This applies even while stopped, and the refusal bypasses `_mixFailure`.
- **Trigger:** any timing receipt timeout (see #2).
- **Impact:** until timing Retry, the coordinator rolls back every Mixer edit (touch, MIDI, expression) and shows a Mixer refusal. Held Mixer releases become owed cleanup.
- Not in the plan and untested. `startEngine` is already gated (2406-2411), and `applySession` clears the obligation before its `_requestMix`, so the line protects nothing.
- **Fix:** delete line 751.

### 2. Retry stops audio and does not restart it (Low)
- `looper_repository.dart:1315`: `recoverRecordTimingSettings` calls `stopEngine()` while running. `recoverLengthSettings` (1522) refuses in the same situation.
- **Trigger:** `_failTiming` skips the stop because capture was locked (1286). The user finishes the take and taps the toast's Retry.
- **Impact:** playback halts, reconnect supervision ends, and nothing restarts the engine.
- **Fix:** return `notReady` while running, or restart through `startEngine` after accepting the recovery intent.

### 3. Ordinary edits are refused during a replay receipt; the Record fence lasts one poll longer than native (Low)
- `lib/looper/cubit/record_timing_cubit.dart:337-351`: `_write` calls `_requestTiming` without settling first, unlike `_restore` (176) and `runRecordTimingExclusive` (504).
- **Trigger:** a touch or MIDI edit within one poll (about 10 ms) of a startup or reconnect replay. `_pendingTiming != null` returns `notReady` (repo 1163), and the user sees a refusal toast.
- **Duplicate report:** `_reportTiming` delivers through an async broadcast after `_applying` resets, so the listener (cubit 44-55) adds a second failure event.
- **Record fence:** `record()` (2865) returns `notReady` until the Dart timer observes the receipt, not until native publication. A Record press arriving up to about 10 ms later is dropped.
- **Fix:** `await _repository.settleRecordTimingSettings()` at the start of the queued `_write`. In `record()`, call `_settleTiming()` before refusing.

## Inherited-pattern repeats

### 4. A timeout stops the engine and ends reconnect supervision (Medium; same as #1094-1 and #1096-6)
- `_failTiming` (1276-1288) calls `stopEngine()`, and `recordTimingRecoveryRequired` then blocks `startEngine` (2410).
- **Trigger:** unplug the pinned interface, then tap the quantize toggle (still enabled) or move a timing-mapped MIDI control. `le_push_cmd` accepts the command while the engine is configured, and the receipt times out after 500 ms.
- The same happens when a reconnect's startup replay misses 500 ms: `_attemptReconnect` has already stopped polling.
- Before this PR the gate was a plain store, and reconnect replayed it.
- **Why the block is unnecessary:** configure discards queued commands (the comment at 2196-2203), so no old vector can be replayed. Restart can therefore safely replay `_timingRestart`.
- **Fix:** while the device is absent, accept the edit as deferred intent with no pending receipt. On timeout, adopt the recovery intent without blocking restart.

### 5. Fail-closed decoding with no repair, now blocking audio start (Medium; same as #1095-2)
- `settings_repository.dart:1807` throws on any out-of-range scalar.
- `lib/app/audio_bootstrap.dart:125-155` then stops the engine and returns `recoveryConfig: null`, so audio never auto-starts.
- `_restore` fails. Retry (cubit 494-496) re-reads the same scalar and fails again.
- `flushRecordTiming` returns `recoveryRequired`, so power-off cannot complete, and `runRecordTimingExclusive` blocks Session Save and Load.
- **Fix:** scope the failure to timing and let audio start. Retry should rewrite the offending scalar through `restoreRecordTimingCheckpoint` (an absent track key means Use default).

### 6. Copy-pasted `is` chains and dispatch blocks (Maintainability)
- `|| target is RecordTimingValueTarget` is added at `control_cubit.dart:642, 754, 848, 1127` and `control_midi.dart:762`. The `relativeStep` (513) and normalization (1066) arms repeat as well.
- Copied blocks:
  - The External dispatch block (`control_cubit.dart:1093-1119`) and the MIDI block (`control_midi.dart:979-1009`) repeat the Record-length blocks.
  - `_supersedeRecordTimingClaims` (`control_midi.dart:1301`) is identical to `_supersedeRecordLengthClaims` (1278).
  - `recordTimingReadout` (`control_value_readout.dart:52`) duplicates `recordTimingLabels`.
- **Fix:** add one owned-value-target abstraction with `relativeStep`, `hasReleasedEndpoint` and a write helper.

### 7. Cubit-to-Cubit and Bloc-to-Cubit edges (same as #1095-3)
- ControlCubit depends on RecordTimingCubit.
- LooperBloc forwards `LooperTrackRecordTimingChanged` and tracks `_recordTimingWrites` for PersistFlush (`looper_bloc.dart:746-757, 893`). `flushRecordTiming` already covers that wait.
- **Fix:** have LoopLengthPage call the owner directly. This is a direction call for the owner.

## Preexisting debt
- When a timing change makes a track effectively Immediately, the callback cleanup (`engine_process.c:2896`) also cancels Sync/Band defining-take force-arms (trigger 0), which timing does not own. Base `le_engine_set_quantize` did the same.
- `recordTimingCaptureLocked` takes a full FFI snapshot per call; `_publish` and `_releaseEligibility` call it on every looper-state event.
- `flushMidiConfiguration` now throws `ControlCleanupPending` (`control_midi.dart:41`) on the first halt for any family's owed release, not only timing. The plan sanctions this for timing; note it for the other families.

## Optional tests
- With timing recovery pending, `setTrackVolume` should be accepted. This would catch #1.
- Device lost (publishing off, still configured), then a timing edit: reconnect should stay armed and start should stay unblocked. This covers #4.
- Boot with `track_record_timing.3 = 9`: audio should start, and Retry should repair the key (#5).

Oracles: boundary tests use literals (0.249 → loopStart, 0.25 → bar), and the receipt tests compare published tuples. Both are independent of the production mapping.

## Nits
- `record_timing_publish_revision` is not reset in configure; this is harmless.
- The bootstrap and `_restore` both apply the startup vector (two receipts).

Verdict: request changes. #1 is an unplanned audible coupling that disables the Mixer, and #4 and #5 repeat known high-consequence patterns. Each fix is local.

- #1 Medium, introduced: timing recovery refuses all Mixer edits (looper_repository.dart:751).
- #2 Low, introduced: timing Retry stops the running engine (looper_repository.dart:1315).
- #3 Low, introduced: no settle before an ordinary write, a duplicate failure event, and a Record fence that outlives native publication (record_timing_cubit.dart:337; looper_repository.dart:2865).
- #4 Medium, repeat: a receipt timeout stops the engine and blocks restart and reconnect (looper_repository.dart:1286, 2410).
- #5 Medium, repeat: a malformed timing scalar blocks audio start, Save and power-off with no repair (audio_bootstrap.dart:125-155).
- #6 Maintainability, repeat: copied type chains and dispatch blocks (control_cubit.dart, control_midi.dart).
- #7 Design, repeat: Bloc/Cubit-to-Cubit edges (looper_bloc.dart:746).
