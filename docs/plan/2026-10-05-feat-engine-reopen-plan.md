# Preserve recorded material across a full audio-engine reopen

Tracking: #1140, `stage:build`, `autonomy:merge-gate`. Parent: Foot Fade
[plan](2026-10-04-feat-foot-fade-plan.md) / [Part 2](2026-10-04-feat-foot-fade-part-2-plan.md).
Owner decisions (2026-10-05, recorded on #1140) are binding and repeated inline.
Base: `origin/codex/fade-clear-history` (top of the Fade stack, PR #1145).

This document was written against the native tree before the work and edited
afterwards to describe what was actually built: Part 1 (PR #1158), including
the two review findings on it (a second complete pass lost; the whole-rig
CLEARED_PENDING blast radius), and Part 2 (the repository and app wiring, with
its deviations and decisions recorded in its own section).

## Current behaviour (verified, pre-change)

- `le_engine_start` opens the backend, then calls `le_engine_configure`,
  publishes the negotiated parameters and starts the callback. Configure was the
  only path that freed lane PCM, emptied history, reset transport, the clock,
  take ids and Fade.
- `le_engine_stop` releases the device and joins the cache/restore workers but
  leaves pools, stacks and `a_configured` intact. Commands posted while stopped
  still enter the ring (`le_push_cmd` is configured-gated, not running-gated).
- The repository's supervisor `_attemptReconnect` raw-stops, retires the engine
  lifetime and calls `startEngine(config)`, which replays settings, mix, lane
  mutes, FX, monitors, conditioning and output gates but no material. Known
  bug: it checks only `_applyingSessionRevision`, not the `startEngine`
  admission predicate, and records `_lastAttemptSignature` before the start can
  be refused, so a `notReady` refusal suppresses every later attempt until the
  device list changes. (Part 2.)
- Overdub writes back up the pre-value of every visited position into the armed
  shadow slot `dub_slot`; `dub_count` frames from `(dub_start_vpos,
  dub_start_vseg)` are covered. The punch-out drain walks the uncovered
  remainder; a complete pass parks in `dub_retire_slot` until the event ring has
  room. A shadow that was never armed leaves the pass merged into the base.
- Session recall already establishes "material present, STOPPED" in one place:
  `LE_CMD_COMMIT_SESSION` sets the clock, `a_master_len`, `a_multiple`,
  `start_iter = 0`, `a_state = STOPPED`, then `le_primary_reconcile`.
- Routes to inputs beyond the device are inert on the audio thread, and
  `le_fx_route_frame` only writes output bits below `ch_out`; `le_mix_valid`
  bounds lane inputs by `LE_MAX_CHANNELS`, so a replay with fewer channels is
  admitted.

## Part 1 (built). Native: `le_engine_reopen`

### Contract (`segno_engine_api.h`)

```c
typedef enum le_reopen_outcome { LE_REOPEN_RETAINED = 0, LE_REOPEN_CLEARED_RATE = 1,
  LE_REOPEN_CLEARED_CAP = 2, LE_REOPEN_RETAINED_PARTIAL = 3 } le_reopen_outcome;
/* dropped_track_mask: bit t = track t dropped (RETAINED_PARTIAL); NULL to not ask */
LE_EXPORT int32_t le_engine_reopen(le_engine*, const le_config*, int32_t* outcome,
    int32_t* dropped_track_mask);
/* device-free twin, next to le_engine_configure */
LE_EXPORT int32_t le_engine_reopen_configured(le_engine*, int32_t sample_rate,
    int32_t in, int32_t out, int32_t max_loop_frames, int32_t* outcome,
    int32_t* dropped_track_mask);
/* the device-lost flag flip, now public so a host can rehearse its reconnect */
LE_EXPORT void le_engine_mark_device_lost(le_engine*);
```

Preconditions: `a_running == 0` else `LE_ERR_ALREADY_RUNNING`; `a_configured ==
1` else `LE_ERR_NOT_RUNNING` (a cold engine uses `le_engine_start`). Control
thread only; the callback is gone, so every field below is owned.

`le_engine_reopen`, in order:

1. `be->open` as in start. Failure returns the backend error and **nothing else
   changes** (material still held, still stopped, `*outcome` untouched), so the
   supervisor can retry.
2. `le_engine_reopen_configured` with the negotiated shape (below).
3. `le_engine_publish_and_start` — the tail of `le_engine_start`, factored out
   and shared: publishes negotiated parameters, callback budget, latency state,
   device name, excluded mask, then `be->start`. A start failure closes the
   device and returns `LE_ERR_DEVICE` with the material **already settled** per
   `*outcome` (retained and stopped on RETAINED), so the next attempt can still
   retain.

`le_engine_reopen_configured`:

1. Clamp the shape with `le_clamp_shape` (the one place configure's defaults
   live, so the comparison is like for like).
2. Decide (`le_engine_reopen_outcome`): negotiated `sample_rate !=
   engine->sample_rate` → `CLEARED_RATE`; clamped `max_loop_frames !=
   engine->max_loop_frames` → `CLEARED_CAP`; these two run the existing
   `le_engine_configure` unchanged and are the ONLY whole-engine clears.
   Otherwise each track with `state_cmds_posted > a_state_acks`,
   `cancel_pending`, `clear_restore_pending`, or EMPTY with `a_len > 0` (a
   Session import whose commit never applied) goes into the drop mask;
   a non-zero mask reads `RETAINED_PARTIAL`, else `RETAINED`.
3. Retained (both): `le_engine_quiesce_workers` (cache/restore join, perf
   drain stop with `DEVICE_CHANGED`, render cancel, rings released,
   `perf = {0}`) → `le_engine_reopen_file_retired(mask)` →
   `le_engine_reopen_settle(mask)` → `le_engine_reset_runtime` (which ends
   with `a_configured = 1`).

### The configure split (`engine.c`)

`le_engine_configure` is now `quiesce_workers` + `reset_material` +
`reset_runtime`, and the retained reopen is `quiesce_workers` + the two settle
halves + `reset_runtime`. The boundary is the audit:

| `le_engine_reset_material` (configure only) | `le_engine_reset_runtime` (both) |
|---|---|
| lane `pool[]`/`pool_cap[]` freed, lane 0 slot 0 reallocated at the cap | rings re-initialised, `commands_*`, `a_commands_published`, `lane_growth_command`, `input_routing_command`, `clock_commands_*` |
| `a_live`, `a_len`, `a_recoverable`, `image_gain`/`image_pan` (the recorded source image travels with the take) | `le_lane_reset_settings` per lane: routing, live mix (published mix recomposed as `live * image`), mute, FX, plugin slots, meters, cache fields |
| `lane_count`, `undo_count`/`redo_count`, `a_undo_depth`, `a_clear_restore`, `a_redo_depth`, `empty_len`, `clear_restore_slot` | per-track pending/launch/count-in/seam/xfade/dub bookkeeping, `state_cmds_posted`, `a_state_acks`, `pending_target`, `cancel_pending`, `clear_restore_pending`, `dub_generation` |
| `a_state`, `a_multiple`, `a_sync_divisor`, `take_seq`, `a_settled_take_id` | per-track settings the repository replays: `a_gain_bits`, presets, one-shot, quantize/decay overrides, solo, images, `target_multiple`, bus/output/all-tracks/monitor chains, trims, conditioning, clip, tuner, output gate, limiter, master gain, overdub feedback |
| Fade: `fade`, `fade_sample`, `fade_generation`, `a_fade_*`, `fade_cache` | `fade_lifetime++`, receipts cleared, `fade_cache.lifetime` refreshed |
| `clock.length`, `free_clock.length`, `a_master_len`, `a_primary_track`, `grid_total_beats`, `a_loop_bars` | `clock.position`, `loop_iteration`, `a_master_pos`, `free_clock.position`, `free_iteration`, `transport_held`, viz rings, `frame_clock`/tap, `grid_prev_beat`, `a_current_beat`, MIDI clock, `a_record_offset`, callback budget |
| | device fields `sample_rate`/`in`/`out`/`max_loop_frames`/`fx_delay_frames`, `lat_buf`, `cond_buf`, `le_cache_init`, `le_restore_init`, `a_configured = 1` |

`le_lane_reset` is now `image = unity` + `le_lane_reset_settings` + zero
`a_live`/`a_len`/`a_recoverable`; its two other callers (session import) are
unchanged.

### `le_engine_reopen_file_retired` (`engine_commands.c`, control side)

Runs while the event ring and the audio thread's dub bookkeeping are intact:
pops every retired-layer / cancel event with **no replenish**; skips tracks in
the drop mask; runs `le_collect_clear` per track so a Clear that applied in its
last block but was never collected gets its restore point's Fade amount
(`clear_cmd_ack` is zeroed by the runtime reset, which would otherwise strand
`fade_ready = 0`); files a parked `dub_retire_slot` AND a shadow frozen complete
in `dub_slot` (`dub_count >= dub_len`) — both can exist when the event ring was
full across two pass boundaries, since `le_dub_boundary` returns early while a
retire is stuck — oldest first, through `le_handle_retired` with
`dub_gen_audio`, as committed layers (review finding 1: the first build filed
only one of them); then drops `outstanding_count`, `queued_undo`,
`dub_punch_out_posted`, `depth_republish`, `pending_lane_trim` and republishes
the undo depth.

### `le_engine_reopen_settle` (`engine_process.c`, audio side)

Owner decisions applied, per track:

1. Partial pass (`dub_slot >= 0 && 0 < dub_count < dub_len`, draining or not):
   walk the covered trajectory from `(dub_start_vpos, dub_start_vseg)` shadow →
   live on every active lane and bump `a_audio_rev`. The walk is
   `le_dub_run_copy`, factored out of the punch-out drain so the two cannot
   drift (the drain now calls the same helper live → shadow). A pass without an
   armed shadow stays merged, as today at spare starvation.
2. `RECORDING`, or `seam_capture > 0` (a just-finalized later track whose
   trailing fold has not landed; `xfade_capture > 0` is RECORDING), or a track
   in the drop mask: drop the track (`le_reopen_drop_track`) — EMPTY, length 0,
   multiple 1, stacks and depths zeroed, `a_recoverable` 0 on every lane, Fade
   reset to unity with a new generation, `free_clock` reset. A defining take
   leaves the clock unset. Recording never resumes. A drop that leaves every
   track EMPTY resets the master, loop bars and grid total exactly as
   `handle_clear` does (a rig that was already all-EMPTY — undone to empty with
   its redo pending — keeps its master: nothing was dropped).
3. `PLAYING`/`OVERDUBBING`/`STOPPED` with content → `STOPPED`; `fade.frames = 0`
   so `le_fade_tick` re-origins at the frozen amount and resumes toward the
   unchanged target at the unchanged full-travel seconds (no wall-clock
   catch-up). EMPTY tracks (a cleared history) are untouched.
4. Head park for every track: `le_reset_track_playback`, `start_iter = 0`,
   `record_pos = 0`, `od_gain = 0`, `le_dub_drop_armed`, `a_layer_in_flight = 0`,
   `a_play_pos = 0`, `le_fade_publish`; then `clock.position = 0`,
   `loop_iteration = 0`, `a_master_pos = 0`, free clocks' positions 0, and
   `le_primary_reconcile` (mirrors the commit-session park; a later Play goes
   through the ordinary `handle_play` / unpark path from frame 0).
5. Fewer channels: nothing to do natively. Lane routing resets to defaults with
   the other settings (the repository replays them); the audio thread already
   treats an input `>= ch_in` as silence and `le_fx_route_frame` never writes
   an output bit `>= ch_out` — proven under ASAN by the test below rather than
   assumed.

### Decision record: the pending rule is per track (review finding 2)

The first build made any unapplied Clear/Undo/Redo/cancel clear the WHOLE rig
(`CLEARED_PENDING` → `le_engine_configure`). The review's probe showed what
that costs: a device loss stops the callbacks but `le_push_cmd` is
configured-gated, so a single Undo press on an empty track during the outage
was accepted and the reopen then wiped every other track's retained loop. The
state command was never half-applied — acks are bumped inside the apply
handlers and the stop is synchronous, so an unacked command is still unpopped
in the ring; only that one track's control-side pre-mutation (`le_track_set_len
(t, 0)`, the redo push, `a_multiple = 1`) is out of step.

Decision, under the owner's standing delivery rules (rule 2: preserve recorded
material; rule 5: drop uncertain native state, with a notice): the pending rule
is scoped to the track it concerns. That track is dropped exactly like a take
still capturing (EMPTY, length 0, history and shadows gone, Fade reset) and
named in `dropped_track_mask`; every other track takes the normal retained
path; the outcome reads `RETAINED_PARTIAL`. Whole-engine clears remain only
`CLEARED_RATE` / `CLEARED_CAP`. This narrows the owner-accepted edge (b) — "a
loss within one block of an unapplied Clear/Undo/Redo/cancel clears loops
with a notice" — to its intent: the uncertain material is still dropped and
still reported, but the loops the press never touched are kept. Part 2 turns
the mask into the notice.

### Edge-case defaults taken in Part 1 (not covered by an owner decision)

- A queued undo tap (`queued_undo > 0`, deferred behind an in-flight layer) is
  control-side intent, not a half-applied audio-thread command, so it does NOT
  drop its track; the retained path drops the tap with the pass it was waiting
  on. A pending `lane_growth_command` is likewise not pending state: the
  repository re-posts its routing.
- A Session import without its commit (EMPTY track with `a_len > 0`) IS
  dropped (and reported): turning it into a STOPPED track with no master clock
  would invent transport state.
- The recorded source image (`image_gain`/`image_pan`) is material: a take
  captured at image gain 0.5 plays back at 0.5 after a retained reopen, with the
  live fader reset to unity like every other setting.
- A shadow frozen complete but not yet at its pass boundary is filed as a layer
  (a complete pre-pass image is a state that existed); un-backed writes after it
  stay in live, the same merge the engine produces today.

### Test seam

`engine_devices.c` gains `le_test_backend_override` (under `LE_NATIVE_TESTS`
only), so `le_engine_start`/`le_engine_reopen` run through a fake
`le_device_backend` with controllable open/start results and negotiated rate.

### Dart seam (`segno_engine` only; no repository/app caller)

`EngineLifecycle.reopen(EngineConfig) -> ReopenResult` (a record of
`EngineResult`, `ReopenOutcome {retained, clearedRate, clearedCap,
retainedPartial}` and `droppedTracks`, the bitmask; `keepsMaterial` is true
for the two retained values; an unknown code reads `clearedCap`, never a
retained value).
`NativeAudioEngine.reopen` → `le_engine_reopen`; `PumpedNativeEngine.reopen` →
`le_engine_reopen_configured` with the config's shape, plus
`simulateDeviceLoss()` (flips the published device-present flag through
`le_engine_mark_device_lost` and makes the pumped snapshot read absent until
the next reopen); `MockAudioEngine.reopen` retains at the same sample rate and
reports `clearedRate` otherwise; the four test fakes return a configurable
result. Bindings regenerated and formatted; `le_reopen_outcome` added to the
ffigen enum list.

### Tests (literal-PCM oracles)

`src/test/test_engine_reopen.h`, 16 tests: same-rate retention (exact PCM per
lane and per layer, depths, multiple 2, take ids, crown, STOPPED at head 0,
silent until Play, Play sums both heads from frame 0, undo/redo/overdub keep
working); partial first take dropped (defining and later track); partial
overdub pass reverted exactly on two lanes including a pass starting mid-loop;
a multiple-2 pass straddling the segment boundary; a punched-out pass mid-drain
(loop longer than `LE_DRAIN_CHUNK`, compared byte-for-byte against the pre-pass
image); parked retire filed; seam crossfade take and trailing-fold take
dropped; Fade frozen at 0.75 and resuming at the original rate, stale
admissions refused, fresh admission accepted; cleared history kept (collected
and uncollected); rate/cap mismatch outcomes and default-cap retention; the
review's repro (an Undo pressed on track 1 while the device was away leaves
track 0's loop byte-exact, track 1 dropped and reported); the five pending
shapes each dropping only their track (with the rig-empty master reset) plus
the committed Session counter-example and a pending press that does not widen
a rate clear; two complete passes at the loss both filed, oldest first; fewer
channels
(output buffer sized exactly to the device, ASAN); the fake-backend lifecycle
(preconditions, open failure untouched, start failure retained+stopped, retry,
rate change through negotiation); performance capture ends with
`device_changed`. Dart: `reopen_outcome_test.dart` (codes, `keepsMaterial`,
mock), three real-FFI tests in `pumped_native_engine_test.dart` (retained,
rate-cleared, and the per-track drop with its mask).

```success-criteria
GOAL: A stopped, configured engine can reopen a same-rate device with its recorded material, history, clock and Fade envelopes intact, and refuses retention explicitly otherwise.
SUCCESS CRITERIA:
- Same-rate reopen preserves every layer's PCM, undo/redo depth, multiples, master length, crown and take ids; content tracks read STOPPED, produce silence until Play, then play from the loop head. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A partial first take reads EMPTY after reopen; a partial overdub pass is reverted sample-exactly while the previously retired layer remains undoable; a parked retired slot is filed. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Fade resumes from the frozen amount at the original full-travel rate under the new lifetime; pre-loss admissions cannot apply. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Rate or cap mismatch report the matching CLEARED outcome and leave the engine exactly as le_engine_configure does; a state command unapplied at the loss drops only its own track, reported in the mask, with every other loop byte-exact; fewer input/output channels retain material with silent out-of-range routes and no out-of-bounds write. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings, symbol parity and the C++ shim repro stay clean; stale ring commands never fire after reopen. | verify: dart analyze --fatal-infos lib test packages && packages/segno_engine/tool/check_ffi_symbols.sh <built lib>
NON-GOALS:
- Resampling, resuming recording, replaying pending commands, repository wiring, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

## Part 2 (built). Repository and app wiring

1. `startEngine`'s post-open replay is `_replayRig(config, {replayedPriorEngine,
   foldedHistory})`, shared with the new `_reopenEngine(config)`. Both sit
   behind one `_startRefused` predicate (the former inline list in
   `startEngine`). `_reopenEngine` reads the stopped engine's sample rate
   (the rate the loops were recorded at), retires the lifetime — settings
   waiters complete `notReady`, `_mixGeneration++` once — calls
   `_engine.reopen`, records the verdict, folds Dart-side history per the
   outcome, clears a staged import the engine dropped, replays the rig, and
   on a retained outcome runs `_drainHistoryFx` so the surviving tracks'
   queued Clear/Undo recipes republish on top of the replayed chains.
   `_sessionRevision` is untouched; `fxReplayConfirmed` fires after the
   replayed recipes confirm, as after any restart.
2. Outcome handling: `retained` folds nothing; `retainedPartial` folds only
   the dropped channels through the new `_foldHistoryFxForChannels` (the
   per-key fold is now `_foldHistoryFxKey`, shared with
   `_foldHistoryFxAtQuiescence`); `cleared*` folds exactly as a start does.
3. Supervisor fix: `_attemptReconnect` checks `_startRefused` BEFORE
   enumerating, never touches `_lastAttemptSignature` or raw-stops the engine
   on a refusal, and records the signature only when `_reopenEngine` is
   actually invoked; `_engine.stop(); _retireEngineLifetime(); startEngine`
   became `_engine.stop(); _reopenEngine(config)`.
4. Fade: no Dart image replay, no new owner (unchanged from the plan).
5. Notice: `AudioSetupCubit._detectConnectivity` keeps raising one notice per
   return. `DeviceConnectivity` gains `restoredPartial` and `restoredCleared`;
   the restored transition picks among `restored` / `restoredPartial` /
   `restoredCleared` from the verdict, so the plain restored snack is replaced,
   never doubled (#860). `restoredCleared` is a standing banner in
   `ConnectivityBanners` (`connectivity_banner_material`) naming both rates
   (or the loop-cap case), with the **Sessions…** action (`sessionManage`),
   which opens the Sessions manager and ends the notice through the new
   `AudioSetupCubit.dismissReopenNotice`; a re-apply of the audio settings
   ends it too. `restoredPartial` is one transient warning toast
   (`AppToastId.deviceRestoredPartial`, 10 s) titled with the reconnected
   device and naming the dropped tracks (1-based), shown by
   `_showDeviceRestoredToast` in place of the snack. New EN/ES keys:
   `deviceRestoredClearedBanner`, `deviceRestoredClearedCapBanner`,
   `deviceRestoredPartialToastBody`.
6. Tests: `packages/looper_repository/test/reopen_native_test.dart`
   (actual-native, ticker-driven supervisor through `simulatedDevices` and
   `simulateDeviceLoss`): loops back stopped with content and depth, PCM
   byte-exact, Fade frozen at 0.75 with the new lifetime, lane mute replayed,
   one `mixGeneration` step, `fxReplayConfirmed` under the unchanged
   `sessionRevision`, a pending `toggleFade` completing `notReady`, the
   supervisor standing down; an Undo pressed while away → `retainedPartial`
   naming track 1 with track 0 byte-exact; `simulatedSampleRate = 44100` →
   `clearedRate` naming both rates, recording works on the new clock; a device
   still absent reopens nothing. `looper_repository_test`: the reconnect
   group now asserts `reopen` (not a second `start`); new tests for the
   suppression fix (a boot-fenced attempt neither reopens, raw-stops nor
   consumes the device list; the same list reopens once the fence lifts), the
   verdict riding `EngineStatus.reopen` until the next deliberate start, and
   a refused reopen leaving no verdict. `audio_setup_cubit_test`: retained →
   `restored`, partial → `restoredPartial` with no `restored` in between,
   cleared → standing `restoredCleared` until `dismissReopenNotice`, which
   leaves a `lost` condition alone. `connectivity_banners_test`: the cleared
   banner's text (both rates / the cap variant), Sessions action and record-red
   tokens; a partial retention renders no bar. `app_test`: a reconnect that
   dropped a track registers the partial warning toast, not the restored
   snack, and raises no bar.

### Deviations from the plan, and decisions taken under the standing rules

- **The verdict rides `EngineStatus.reopen`, not a separate
  `Stream<EngineReopened>`.** Every consumer of a device transition already
  reads `looperState.status`, and the restored transition is the one moment
  the notice is decided; a second stream would have had to be stubbed in every
  mock-repository test and read in lockstep with the status anyway. `null`
  from a deliberate start on; set by the reconnect; survives a failed replay
  (so a reopen that stopped the engine still reports what happened to the
  loops once the device reads present).
- **`clearedCap` is unreachable through the supervisor** (it reopens with the
  last config, so the cap never changes) but is handled with its own banner
  text rather than mislabelling it a rate change.
- **Partial retention is a toast, cleared is a banner** (popup-severity
  principle): a dropped track is an event the player should know about but
  cannot act on — the rig plays on — while a cleared rig has one action worth
  taking (reload the Session) and stands until it is taken.
- **The cleared banner has a single action** (the pen's banner shape):
  **Sessions…** opens the manager and ends the notice. There is no separate
  dismiss; re-applying the audio settings also ends it, as it ends every
  connectivity condition.
- **No pinned-device hook beyond the pump.** `PumpedNativeEngine.simulatedDevices`
  (what `enumerateDevices` reports) and `simulatedSampleRate` (what the
  simulated device negotiates on `start`/`reopen`) are the two seams the
  actual-native supervisor test needed; nothing was added to the repository.
- **A refused reconnect does not raw-stop the dead device.** The old order
  stopped first and refused second, leaving the engine stopped with
  `_intendRunning` still true; the new order leaves the running-but-lost
  engine alone until an admissible tick.
- Found while writing the app test: a snapshot fixture with no tracks makes
  the startup one-shot replay time out against the fake and sets a recovery
  intent, which the admission predicate honours. The pre-existing banner test
  never reconnected for that reason either; the new test gives the fixture
  its eight tracks.

```success-criteria
GOAL: A reconnected pinned device brings back the recorded loops stopped, with settings, FX and Fade coherent, and the player is told plainly when a rate change cleared them or a pending press dropped a track.
SUCCESS CRITERIA:
- Through the real supervisor and a real native engine, loops return stopped with history, fades and remembered rig; waiters retire once and FX replay confirms under the unchanged session revision. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB=<built lib> /Users/Tomas/development/flutter/bin/flutter test)
- A boot-blocked or otherwise refused attempt neither reopens nor consumes the device-list signature; the next admissible tick reopens. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test test/looper_repository_test.dart)
- A cleared reopen surfaces one banner naming both rates with the Sessions action; a partial reopen one toast naming the dropped tracks; a retained reopen only the existing restored snack. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup test/looper/view/connectivity_banners_test.dart test/app/view/app_test.dart
- Analyzer, Bloc lint and formatting stay clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- Appliance: unplug/replug the pinned interface mid-performance; switch its rate and replug. | verify: manual 1. Loops present and stopped after replug, Play resumes from the head. 2. A mid-fade track continues from its frozen level. 3. Rate switch shows the cleared banner and Session reload restores the take.
NON-GOALS:
- New Fade owner, resampling, resuming recording, Session schema, generic recovery framework.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

## Hardware-only

Audible continuity at the reopen edge, the real miniaudio/ALSA loss path
(`engine_miniaudio.c`), a device renegotiating fewer channels (a different
device id is never auto-reopened), and the Fade listening check.

## Open owner questions (Part 1 took the defaults above; confirm or override)

1. Queued undo tap at the loss: dropped with the pass (taken) vs dropping the
   track.
2. Recorded source image kept with the material (taken) vs reset to unity with
   the live faders.
3. Un-committed Session import at the loss: that track dropped and reported
   (taken) vs keeping the imported lengths for a later commit.
4. The per-track pending rule above was decided under the standing delivery
   rules rather than by an explicit owner call; confirm it reads as the intent
   of edge (b).
