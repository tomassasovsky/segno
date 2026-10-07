Model: Claude Fable (subagent), in-session

# PR #1161 adversarial review — fix(engine): refuse fresh capture while a callback may hold its buffers

Branch `claude/capture-prep-guard-1146` @ ce6b178c6, base `codex/fade-clear-history` @ 270209fbc. Issue #1146. All file:line references are to the PR head.

## Verified correct (traced)

- **Hazard model.** `mix_tracks_frame` caches `pool[live]` per frame for every non-idle track (engine_process.c:5283-5299, hook stage 5 at :5302 fires after the cache and before the dereference at :5579-5614). The command drain runs at the top of `le_engine_process` (:5929-5932) and `a_commands_published` is the release store at the very end of the block (:6515). So "ticket <= published (acquire)" does establish that the block which applied the emptying command, and every earlier block, has completed. `a_state` alone is a relaxed load/store pair (engine_private.h:1982-1987), so it carries no happens-before edge; the ticket is what makes the argument formally sound, and the PR's "ack is not proof" claim is right on those grounds.
- **Ordering of counters.** `commands_posted` is control-only and incremented after `le_ring_push` (engine.c:1326-1333); `commands_applied` counts every pop including rejected/no-op commands (:5931); publication copies it with release (:6515); every guard load is acquire (engine_commands.c:1573). The batch path in `le_post_record_image` bumps `commands_posted` by the exact number of ring entries written before the tail release (:1352-1355), so posted and published converge.
- **Stamp is after a successful push on every stamped path.** `le_apply_queued_undo` :518-522, `le_engine_undo` cancel-take :2202-2206 and undo-to-empty :2246-2254, `le_clear_track` -> `le_finish_clear` :1893-1915 -> :1297, launch-grace RECORD :1457-1464 (stamped only on `LE_OK`). The image-path internal clear stamps before the batch exists (:1630 -> :1297) and is re-stamped to the batch's last entry at :1354; that is over-strict by at most two commands in the same drain, and the batch always follows (`armed[]` is zeroed by `le_finish_clear` :1310, so neither the sound/quantize cancel branch nor the trigger-2 refusal can return between :1630 and :1676/:1727/:1766). No path leaves a ticket that cannot publish; `le_engine_configure` resets ticket and counters together (engine.c:511, :552-556). No permanent NOT_READY traced.
- **Preview matches the real preparation.**
  - Image: `track_select_slot(t, 0, 0, outstanding_count)` at :1555 is the same call `le_prepare_image_capture` makes at :1041; `outstanding_count` is not mutated between :1555 and :1590. Live replaced iff non-NULL and `cap < max` (:1050-1052) = `le_capture_prep_touches_pcm` with `zero == 0` (:1439-1440); shadow replaced iff `cap < max` (:1051) = `:1441-1442` with `shadow_frames == max_loop_frames`.
  - Primitive immediate: `le_post_dub_shadows(…, 1)` at :1781 runs `track_acquire_slot` with `redo_count == 0` and `outstanding_count == 0` (both reset in `le_begin_empty_capture` :969/:993) and `undo_count` reduced to 0 exactly when `le_drop_clear_history` fires (:973 — `clear_restore_pending` or `le_history_is_cleared`) or the grid-redefining clear resets the stack (:1620-1636 -> `le_finish_clear` :1284-1286). The preview's `history` expression at :1562-1566 reproduces that. `want` (:211) equals the previewed `shadow_frames` (:1568) for an EMPTY track (control-side `le_track_set_len(t, 0)` on undo/clear; `a_state` RECORDING on a pending cancel/freeze returns 0 -> cap).
  - Zeroing: `le_prepare_new_capture` runs for every sound arm (:1675), every quantized arm (:1723) and the immediate path iff `has_master` after the internal clear (:1753); `zero = sound_arm || quantized_arm || capture_has_master` (:1548) matches, because `has_master` becomes 0 exactly when `redefine_grid && (has_master || cancel_pending)` and the clear posts (:1632/:1634) — the ring-full exception is the one #1160 already lists.
  - Deferred primitive arms post no shadow now (:1556 guard) and allocate later through the RECORDING drain path, when the track is no longer EMPTY — consistent.
- **Arm-cancellation exemption** (:1543-1545) is exact: every exempted combination returns `LE_ERR_INVALID` or pushes `DISARM` before any preparation (sound: :1657-1671; quantized: :1703-1713; trigger 2: :1588-1589 and :1748-1750), and the non-exempt stale-arm combinations (`armed && a_pending` with neither `sound_arm` nor `quantized_arm` and trigger 0/1) do prepare and are guarded. The `test_record_refuses_zeroing_callback_held_live` quantized leg exercises the exemption.
- **`track_acquire_slot` refactor** preserves behaviour: identical `used` scan, identical first-evictable-non-CLEAR eviction, same shift/decrement/publish (:115-158 vs the removed body). `le_prepare_image_capture` previously excluded live + outstanding via a local `used[]`; `track_select_slot(t, 0, 0, outstanding)` is the same set and the eviction loop is a no-op for `undo_count == 0`.
- **Tests.** Native suite passes normal and `EXTRA_CFLAGS="-fsanitize=address -g"` (4 new tests ran in both). With the base engine sources and the PR's test file, `test_record_refuses_regrowing_callback_held_live` fails at line 16994 (`rc == LE_ERR_NOT_READY`) and the harness exits by design; the other three assert a refusal a guard-less base cannot produce. The stage-5 hook seam is the right place: cache taken, no dereference yet.
- **Scope notes in #1160** (cross-channel `close_active_capture` :1682-1686; ring-full internal clear) are consistent with my trace.

## Findings

### 1. Medium — same-channel emptyings that are not ticketed admit a capture in the acked-but-unpublished block (reproduced)

**Where.** engine_commands.c:1543-1576 (guard) relies on `empty_command`, but these paths empty the track with no stamp:
- `LE_CMD_DISARM` during launch grace: engine_process.c:2732 -> `handle_record` :1717-1726 -> `apply_undo_to_empty`. Posted by `le_engine_cancel_arm` (engine_commands.c:2492-2501) and `le_engine_play`'s grace branch (:1813-1817). The Dart host uses exactly this for a Record or Play press during `countInCancelGrace` (packages/looper_repository/lib/src/looper_repository.dart:3027-3028 and :3315-3318 call `cancelArm`, never `record`), so the PR's stamp at :1461-1463 covers an engine entry point the host does not take for that press.
- `LE_CMD_CANCEL_COUNT_IN` and `LE_CMD_STOP_RECORD_CONTROL` -> `le_cancel_count_in` (engine_process.c:1823-1832, :2600-2604) -> `handle_record` on every grace track, including the addressed channel.
- Void-take emptyings decided on the audio thread: `finalize_new_track` with `record_pos <= 0` (engine_process.c:1311-1317) reached from `handle_stop` (:1908-1913) and a RECORD finish, and `apply_undo_to_empty` from the same site in the cancel-take handler (:2781-2789). `le_engine_stop_track` is a bare push (engine_commands.c:1810-1812).

**Trigger (reproduced, probe patch and log beside this file).** Parked master on track 1; count-in Record on track 0; after the commit block, cancel within grace and press Record at the stage-5 seam of the block that applies the cancellation:
```
PROBE via_disarm=0 ticket=9 posted=9 rc=-8 settled_at_press=0 live_zeroed=0   (LE_CMD_RECORD cancel: refused)
PROBE via_disarm=1 ticket=0 posted=9 rc=0  settled_at_press=0 live_zeroed=1   (LE_CMD_DISARM cancel: admitted)
```
With DISARM the stale ticket (0) is <= published, `a_state` already reads EMPTY, and `le_prepare_new_capture` zeroes `pool[live]` while the block that emptied the track has not published — the state `test_record_waits_for_block_publication_not_state_ack` defines as unsafe.

**Impact.** By the PR's own standard this is the defect of #1146 on another entry point. Concretely traced: the applying block's frames do not dereference an EMPTY track's live buffer (idle skip :5279-5281; with lane FX, `lbuf` is only read in the RECORDING/PLAYING/OVERDUBBING branches and `seam_capture` is reset by `apply_undo_to_empty` :1847), and earlier blocks are complete in program order, so I did not find a live use-after-free; what is missing is the happens-before edge the relaxed `a_state` cannot provide. The window is one callback block.

**Smallest fix.** Stamp on the control side wherever a successful push can empty the addressed channel: in `le_engine_cancel_arm` (and thereby `le_engine_play`'s grace branch) when `a_launch_grace`/`a_pending_launch` is set; in `le_engine_stop_track`, `le_engine_stop_record_control` and the RECORD finish path when the effective state is RECORDING; in `le_engine_cancel_count_in` / `le_engine_stop_record_control` for every channel whose `a_launch_grace` or `a_pending_launch` reads set. Over-ticketing costs at most one block of NOT_READY on a track that is not EMPTY anyway, so a conservative "stamp any command addressed to a RECORDING or grace track" helper is acceptable. Add the DISARM leg of the probe as a regression test.

### 2. Medium (host) — a refused Record press is silently dropped

**Where.**
- lib/looper/bloc/looper_bloc.dart:50-53: `on<LooperRecordPressed>` calls `_repository.record(channel: …)` and discards the `EngineResult`. This is the on-screen Record button path (wave_track_row.dart:103, track_column.dart:383, tracks_commands.dart:325).
- lib/control/cubit/control_cubit.dart:1918-1931 `_recAdvance` returns `isOk`, and its callers only feed `_acceptedContacts` (:2553-2559, :2718, :2745) — pedal contact bookkeeping, no retry, no message. `recPlay()` :1885-1890 discards it outright. `_recTrackPressed` :2093-2104 discards both results of the hand-off.
- packages/looper_repository/lib/src/looper_repository.dart:3013-3214 `record()` returns the engine result unchanged; no retry on `notReady`. `grep notReady lib/` finds no handler.

**Trigger.** Clear, Undo-to-empty or take cancel on a track, then Record on the same track within one callback block (~1.3–5 ms at 64–256 frames) when preparation would touch PCM (live slot below the cap after an undo swap, or any start over a surviving master). A fast double-stomp or a scripted sequence hits it; before this PR the press started a take.

**Impact.** The PR's behaviour note says "the host already handles NOT_READY from the record-start, timing and routing gates"; for Record it handles it by doing nothing. That is a new silent no-op on a footswitch press (rule 3, no silent changes).

**Smallest fix.** In `LooperRepository.record`, on `EngineResult.notReady` from a fresh capture (`state == TrackState.empty`), schedule one retry after the next snapshot poll (the condition clears within a block), or surface the result from the bloc/cubit (toast, per the popup-severity principle) so the press is not lost. Add a widget/bloc test asserting the retry or the message.

### 3. Low — comment overstates the trigger-2 path

engine_commands.c:1541-1542 says "the trigger-2 immediate case is refused below without preparing"; the grid-redefinition block (:1603-1637, history drop on every track and the internal CLEAR) runs before the refusal at :1748-1750. No PCM is touched there, so the guard's claim holds for buffers, but the comment should say "without touching PCM". Pre-existing ordering, not introduced here.

## Verdict

Correct and formally sound on the paths it ticketed; not mergeable yet — the DISARM/PLAY/STOP/void-take emptyings leave a stale ticket (reproduced: admitted and zeroed while unpublished), and the host turns the new NOT_READY into a silently dropped Record press.

---

# Delta review (8f280ff8e)

Model: Claude Fable (subagent), in-session. Delta `ce6b178c6..8f280ff8e` (68bc435d9 native, 8f280ff8e Dart). File:line references are to 8f280ff8e.

## Verified correct (traced)

- **Finding 1 fixed.** Every same-track emptying I listed now tickets after a successful push: DISARM via `le_cancel_arm` (engine_commands.c:933-935) and `le_engine_cancel_arm` (:2555-2559), both through `le_ticket_launch_cancel` (:458-468), which also covers `le_engine_play`'s grace branch (:1870-1873 -> cancel_arm); the grace cohort for `LE_CMD_CANCEL_COUNT_IN` (:2567-2572) and `LE_CMD_STOP_RECORD_CONTROL` (:2600-2605, plus the addressed channel); `le_engine_stop_track` (:1865-1868); `le_engine_finalize_take` (:2641-2643); `le_engine_toggle_section` on a RECORDING take (:2922-2927, :2944-2947); RECORD/ARM starts and finishes on EMPTY/RECORDING (:1712-1714, :1771-1773, :1811-1821). The PR's new native test covers RECORD, DISARM, STOP_RECORD_CONTROL and CANCEL_COUNT_IN cancellations inside grace plus a void-take Stop (test_engine_core.c:17245-17364). My re-run of the original DISARM probe is now `rc=-8`, buffer intact, and the additional probe (patch and log beside this file) for Play-during-grace and a toggle-section + cancel pair both ticket (`before=8 after=9 posted=9`) and refuse (`rc=-8 zeroed=0`).
- **Conditional DISARM ticket is sound for every reachable case I traced.** A DISARM only empties through `handle_record`'s grace branch (engine_process.c:1717-1726), reached when the audio side's `launch_grace[ch]` is set when it drains. Control sees `a_launch_grace == 1` from the commit block until the next block's post-drain clear (:5939-5942), and `a_pending_launch == 1` from `le_launch_defer` (:368) until the commit; both windows ticket. A DISARM pushed after the post-drain clear drains with `launch_grace == 0` and empties nothing. An ordinary arm cancellation stays unticketed, so a cancel + re-arm in one block is not refused; the only re-arm refusal left is when the ARM itself is in the unpublished block, and that one is retried by the host.
- **Ticketing starts does not starve an ordinary record.** Tickets are per track and consulted only while the track reads EMPTY with the ticketed block unpublished (:1601-1605); a finish on a RECORDING/PLAYING track never consults it; a start on another track is unaffected. Second press inside the start block (test :17351-17364): with a master it is NOT_READY, the host schedules its retry, the next poll sees RECORDING and drops it silently (looper_repository.dart:7472-7479). What the user hears and sees: the take keeps recording (the input was monitored anyway), the track shows RECORDING, the pedal contact is lit for the hold (`_recordAccepted`, control_cubit.dart:1936-1941) and no toast. Before the delta that second press became a void finish and the track read EMPTY. Within one callback block (1.3-5 ms on the appliance) only switch bounce can produce two presses — the firmware debounce is longer than a block — so this is a bounce rejection, not a dropped stomp. It belongs in the PR's behaviour note; without a master the second press is still admitted and still becomes the void finish (pre-existing asymmetry, no PCM touched).
- **Dart retry, traced against the asked cases.**
  - Finishes a take: the poll-snapshot pre-check (:7472-7479) refuses a track that is not EMPTY, pending, launching or in grace; see finding D2 for the residual window inside `record()`.
  - Toast noise: `recordRefusals` fires only on the second refusal (:7487-7489); the bounce case above is superseded silently; the toast is a 5 s warning with the track name (app.dart:395-415), suppressed while the power-off UI is up, the same gate as `_showRecordingInputRequired` (:376).
  - LED consistency: a press whose retry is owed is accepted (`_recordAccepted`), so the contact stays lit for the hold; a later second refusal leaves it lit until release and the toast explains the lost press. `test/control/control_cubit_test.dart:1924-1956` pins both branches.
  - Leaks: `record_retry_test.dart` closes the ticker in tearDown and disposes the repository and both listeners via `addTearDown`; `_recordRefusals` is closed in `dispose` (:8291). All 5 retry tests, the 2 cubit tests, `flutter test test/control test/app` (1098) and `packages/looper_repository` (721) pass.
- **Layering and lint.** The retry lives in the repository; the app listens to a stream; the cubit asks `recordRetryPending`. `dart analyze --fatal-infos lib test packages` is clean. `bloc lint` cannot be run from a worktree (known gotcha, "No files found"); the new `_recordAccepted` has the same shape as the existing private `_recAdvance`, so it introduces no new lint class. No analysis_options churn (pub get changed nothing tracked).
- **Native suites.** Plain and `-fsanitize=address -g` pass at 8f280ff8e, including the three new tests.

## Findings

### D1. Low — an owed retry survives an engine lifetime change

**Where.** `_retireEngineLifetime` (looper_repository.dart:880-898) cancels every other pending intent but not `_recordRetry`; it runs on `stopEngine` (:2982), reconnect (:2352), `startEngine` (:2566) and `_applySession` (:3920). Polling never stops while the engine is down (`_stopPolling` only in `dispose`, :8274).

**Trigger.** A fresh-capture press refused, then within the retry's window (up to 4 polls, ~66 ms at 60 Hz) a device loss/reconnect, a restart, or a Session load.

**Impact.** Across a restart or Session load the first poll sees `framesProcessed` differ (new lifetime), the track EMPTY, and fires `record()` on the new rig — a recording the user did not press for on that session. While the engine is merely stopped the forced retry fails and raises the "Recording did not start" toast for a press that belongs to the previous lifetime. Rare (the window is tens of milliseconds) but the fix is one line.

**Smallest fix.** `_recordRetry = null;` in `_retireEngineLifetime`.

### D2. Low — the retry can still finish a take: the pre-check uses the poll's snapshot, `record()` re-snapshots

**Where.** `_retryRefusedRecord` checks `snapshot.tracks[channel].state` from the poll (:7472-7479), then calls `record()` (:7483), which takes its own `_engine.snapshot()` (:3016) and, for a track that now reads RECORDING, posts the plain `_engine.record` finish (:3030-3034).

**Trigger.** Refused press; the user's own second press is posted before the retry poll; the callback applies that start between the poll's snapshot and `record()`'s snapshot (microseconds against a 1-5 ms block).

**Impact.** The retry finishes the take the user just started: a void or one-block loop. Very narrow, but the comment claims the case is dropped.

**Smallest fix.** In `record()`, when `_retryingRecord` is set and `state != TrackState.empty`, return without posting (or pass the admitted state into the engine call and compare).

### D3. Low — "one further block published" is one block short when the emptying was posted after the in-flight block's drain

**Where.** `_retryRefusedRecord` treats `framesProcessed != retry.framesProcessed` as publication (:7470-7472). The refused press's `framesProcessed` comes from `record()`'s own snapshot (:3016, :3214) taken while block N is in flight. If the emptying command was posted after N's drain it applies in N+1 and the guard needs N+1's end; the end of N already advances `framesProcessed`.

**Trigger.** Buffer period longer than the poll interval: at 1024 frames / 48 kHz (21 ms) a 16 ms poll can observe only N's end, retry once too early, get refused again, and raise the toast with the press lost. At the appliance's 64-256 frame buffers the poll always spans two block ends, so this is a desktop-only path.

**Smallest fix.** Treat `_engine.commandsSettled` as the publication signal (the emptying was posted before the refused press, so settled implies its ticket published), or require two frame advances; keep the poll limit as the fallback.

### D4. Low — a residual unticketed DISARM window at the count-in commit

**Where.** `le_count_in_commit` clears `a_pending_launch` for every member in `le_count_in_reset` (engine_process.c:4022 -> :300) and stores `a_launch_grace` only after `handle_record` returns (:4043-4044). A DISARM pushed by control between those two stores (control reads pending 0, grace 0) is not ticketed by `le_ticket_launch_cancel`, drains in the next block with `launch_grace == 1`, and empties the take.

**Impact.** The same formal class as the autonomous residuals the PR documents at engine_commands.c:1575-1580; the window is the body of one function inside one frame. Report for completeness; no reproduction attempted.

**Smallest fix.** Store `a_launch_grace` before the member's `a_pending_launch` is cleared (or ticket DISARM while `a_counting_in` reads set), or add the case to the residual note.

## Verdict

Findings 1-3 are fixed and pinned by tests (DISARM/Play/STOP_RECORD_CONTROL/CANCEL_COUNT_IN/void-take refusals reproduced as NOT_READY with the buffer intact; the host retries once and reports a second refusal). The remaining items are low-severity retry-lifetime and timing edges (D1-D3, each a one- or two-line fix) and one formal commit-window residual (D4); none blocks merge on its own, but D1 should land before this ships.

---

# Delta review (11af0b411)

Model: Claude Fable (subagent), in-session. Delta `8f280ff8e..11af0b411` (9c9f9e1a5 native D4, 11af0b411 Dart D1-D3). File:line references are to 11af0b411.

## Verified correct (traced)

- **D4 pairing is sufficient for `le_ticket_launch_cancel`.** `le_count_in_commit` now sets `launch_committing` before `le_count_in_reset` (engine_process.c:4030-4031), the reset keeps every `a_pending_launch` while committing (:304), each launched member stores `a_launch_grace` (release) then clears `a_pending_launch` (release) (:4055-4058), and a sweep clears the rest (:4062-4065). `le_ticket_launch_cancel` loads pending then grace, both acquire (engine_commands.c:467-468). Interleavings: pending reads 1 -> ticket. Pending reads 0 from the commit's clear -> that release store synchronizes with the acquire load, the grace store is sequenced before it, so grace reads 1 (coherence) unless a later store overwrote it; the only later store is the post-drain clear of the next block (:5960-5961, after that block's `le_ring_pop` loop), and a DISARM pushed after control observed that clear cannot be popped by that drain (its tail store is sequenced after the grace load, and a pop that saw it would put the grace load before the clear store, which it read), so it drains against `launch_grace == 0` and empties nothing. Pending reads 0 because there never was a launch -> grace is 0 and nothing empties. `le_cancel_count_in` (:1827-1835) only acts on `launch_grace[c]`, which control tickets through the cohort sweep for the same two flags. **Probe** (patch and log beside this file): hooks placed at three instants inside the commit (after the reset; grace stored, pending not yet cleared; pending cleared) each observe a cancellable launch (`6: pending=1 grace=0`, `7: pending=1 grace=1`, `8: pending=0 grace=1`), `le_engine_cancel_arm` / `le_engine_play` ticket at every one (`ticketed=1`), the DISARM empties the take in the next block, and the Record at that block's seam is refused with the buffer intact.
- **Every reader of `a_pending_launch` and `launch_committing`, enumerated.** `launch_committing`: `le_unpark_stopped` :160 (skips stopped-mask tracks), `le_count_in_reset` :304 (new), `le_launch_defer` :362, `close_active_capture` :1686, `handle_record` :1720-1721, `handle_play` :2027-2028, set/cleared :4030/:4076, reset in `le_engine_configure` (engine.c:657). Between the flag's old and new position the only code is the reset (the intended change), the stopped-mask restore and the section computation; none reads the flag. `a_pending_launch` control readers: `le_ticket_launch_cancel` :467; `le_prepare_routing` :1265 (refuses lane growth INVALID); `le_classify_record` :1406 and `le_record_impl` :1485 (-> RECORD cancel, ticketed); the FX-edit gate :1546; `le_engine_play` :1884; `le_engine_undo` :2240 (-> cancel_arm); `le_snapshot` (engine_snapshot.c:117, Dart `pendingLaunch`, read at looper_repository.dart:1200/:2450/:3047/:3344/:7487). Audio-side writers: :300-304, :346, :372, :4057, :4063, engine.c:437.
- **No stale pending launch.** The sweep (:4062-4065) runs unconditionally after the member loop, with no return or continue between `launch_committing = 1` and `launch_committing = 0`; no launch can be created inside a commit (`le_launch_defer` :362 returns 0, `handle_record`/`handle_play` skip `le_launch_remove` under the flag), so the sweep cannot wipe a fresh one. A skipped (non-launchable) member leaves the commit with pending 0, grace 0, `launch_action` 0, `pending_image.revision` 0 — the same end state as before, reached a few microseconds later. Its only observable difference is inside the commit body: a Record/Play/Undo/lane-growth on it in that window reads a pending launch and takes the cancellation branch (RECORD with `cancel_count_in` on a track with no action and no grace is a no-op at :2600-2606; DISARM is a no-op), where before it could start a take or grow lanes mid-commit. Harmless.
- **No count-in behaviour change** for members or non-members: clicks, order, section exclusion, `launch_stopped_mask` handling and the unpark rule are untouched; the release stores replace relaxed ones for the same values.
- **D1-D3 confirmed.** `_recordRetry = null` in `_retireEngineLifetime` (looper_repository.dart:901); the retry's fresh-snapshot guard in `record()` (:3041-3044) returns quietly and `_retrySuperseded` suppresses the toast (:7492-7500); publication is `commandsSettled` with the 4-poll fallback (:7476-7478). Tests pin a frame advance alone (not publication), stop/restart within the window, and the start-between-snapshots case; 8 retry tests, 724 repository tests pass. The `afterSnapshot` hook is a nullable field on a `FakeAudioEngine` created per test in `setUp`, set only inside the one test and nulled after the poll; it cannot reach another test.
- **Suites at 11af0b411.** Native plain, `-fsanitize=address -g` and `-DLE_CALLBACK_TELEMETRY=0` all pass; `dart analyze --fatal-infos lib test packages` clean.

## Findings

### E1. Low — `le_engine_play`'s own branch still reads the pair relaxed, and its fall-through command is not ticketed

**Where.** engine_commands.c:1884-1886: `load_i32(&a_pending_launch) || load_i32(&a_launch_grace)` (relaxed) decides between `le_engine_cancel_arm` and `le_push(LE_CMD_PLAY)`. `le_classify_record` :1406 and `le_record_impl` :1485 read the same pair relaxed, but their fall-through posts RECORD, which :1811-1821 tickets on an EMPTY/RECORDING track, so they are covered. PLAY is not: `handle_play` :2027-2028 routes a grace track to `handle_record` -> `apply_undo_to_empty`.

**Trigger.** Relaxed loads of two different objects may be satisfied out of order on weak hardware: the grace load returns the pre-commit 0, the pending load returns the commit's 0 -> neither -> PLAY posted, drains in the next block against `launch_grace == 1`, empties the take unticketed. Same formal micro-window class as D4; not reproducible sequentially (my probe shows the values are ordered).

**Smallest fix.** Factor the acquire pair from `le_ticket_launch_cancel` into a helper (`le_launch_cancellable(t)`) and use it in `le_engine_play` (and in :1406/:1485 for uniformity); as belt-and-braces, call `le_ticket_launch_cancel` after a successful PLAY push.

### E2. Low — the retry's guard covers a started take but not a started count-in

**Where.** looper_repository.dart:3041-3044 returns quietly when `_retryingRecord && state != TrackState.empty`, but the next branch (:3047-3050) sends `cancelArm` when the fresh snapshot shows `pendingLaunch`/`countInCancelGrace` — which `_retryRefusedRecord`'s pre-check excluded only on the poll's snapshot (:7485-7489).

**Trigger.** Refused press; the player's own second press is deferred into a count-in by the callback between the poll's snapshot and `record()`'s snapshot (the D2 window with count-in enabled).

**Impact.** The owed retry cancels the count-in the player just started, silently (`cancelArm` returns ok, so no toast). Same microsecond window as D2.

**Smallest fix.** Extend the guard: `if (_retryingRecord && (state != TrackState.empty || track.pendingLaunch != null || track.countInCancelGrace))` return quietly.

## Verdict

D1-D4 are fixed as described and verified (D4 by trace of every interleaving and by a three-instant probe; D1-D3 by the new tests); the delta introduces no regression I could trace in the count-in path, the pending-launch readers or the Dart retry. Two residual edges of the same microsecond class remain (E1: `le_engine_play`'s relaxed pair and unticketed PLAY; E2: the retry guard missing the count-in branch), each a few lines; neither blocks merge.
