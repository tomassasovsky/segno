# Foot Multiply and Divide: double a track or keep one half, with recovery through history

<!-- cspell:ignore lbuf trk seg plog lanei evt hist xfade reclock acks lens maxk idempotently -->

Status: plan for owner review (merging this plan approves its direction); implementation not started.
Tracking: #1168 (parent #1026, M4 operations), `autonomy:merge-gate`.
Source baseline: `origin/claude/fade-duration-targets-1148` (PR #1156),
`c9b420d41cd7312f66ea5f15b0e4ed096d4a87f4`. Precedents: Foot Fade
([plan](2026-10-04-feat-foot-fade-plan.md), parts [1](2026-10-04-feat-foot-fade-part-1-plan.md),
[2](2026-10-04-feat-foot-fade-part-2-plan.md), [3](2026-10-04-feat-foot-fade-part-3-plan.md);
[Clear history](2026-10-05-feat-fade-clear-history-plan.md)), Foot Reverse
([plan](2026-10-05-feat-foot-reverse-plan.md), PR #1163) and Foot Peel
([plan](2026-10-05-feat-foot-peel-plan.md), PR #1166), whose surface pattern,
decision style and part structure this plan reuses. Peel's history kinds and its
Session history persistence are assumed to land first (see Collisions).

## Accepted behavior

- `docs/handoff/segno-app/accepted-behavior.md:304`: "Separately assignable. One
  selected track: Double repeats its material; direct First half or Last half retains
  that region. No intermediate chooser. Pitch/speed unchanged; omitted material is
  recoverable through history. Reject incompatible mode lengths rather than alter
  other tracks."
- `:140-144` (§2.7): loop span and material are separate; sparse material "stays at
  its actual position"; "Never repeat it four times, resize it or switch the session
  to Free."
- `:145-151` (§2.8): Sync/Band capture follows the primary cycle; `:152-159` (§2.9):
  "Multi requires equal spans; Sync/Band require integer primary relationships;
  Song/Free retain independent spans. No implicit trim, repetition, stretch or
  deletion makes a mode fit."
- `:160-166` (§2.10): "One audio-edit history per track includes recording, each
  overdub pass, length edits, Peel and Clear. [...] A new audio edit retires its
  Redo branch." `:167-172` (§2.11): grouped Clear All; "Newer dependent audio
  edits must be undone before an older group."
- `:461-467` (§6.9) recall restores "audio/layers/history"; `:468-471` (§6.10)
  recovery accepts audio "including Undo/Redo dependencies" and must "Preserve
  sparse regions and established spans."
- `:591`: verification journey "Record -> overdub passes -> Divide -> Peel ->
  Undo/Redo" with "Empty/populated, A/B bank, shared sparse timeline,
  stopped/playing/capturing, storage failure, reload".
- `docs/design/2026-09-07-loop-mode-transitions-ux.md:27-29`: a mode switch never
  repeats, trims or pads; "Length editing remains in the accepted Multiply and
  Divide flows." `:33-39` is the compatibility table this plan reuses.
- `docs/handoff/segno-app/implementation-map.md:39`: Divide has no named engine
  entry point; "establish each operation's native contract". `:51`: one complete
  native operation at a time.

## What the engine does today (file:line)

- A track's length is `le_lane.a_len` on every active lane (`engine_private.h:490`),
  published by `le_track_set_len` (`engine.c:74-77`). It changes only at a finalize
  (`finalize_master` `engine_process.c:925`, `finalize_new_track` `:1344-1366`), on an
  EMPTY track (`LE_CMD_REDO_FROM_EMPTY` `:2860`, `LE_CMD_RESTORE_CLEAR` `:2889`,
  session import `engine_session.c:129, 231`) or to zero. No path changes a
  playing track's length.
- Shared-clock read model: `seg_base[t] = ((loop_iteration - start_iter) % k) *
  clock.length` with `k = a_multiple` (`:5312-5323`), `trk_pos/trk_len` default to
  the master (`:5334-5339`), Free/Song override from `free_clock`
  (`free_track_positions_frame` `:5088-5097`), Sync divisions override with
  `trk_len = base / n`, `trk_pos = pos % trk_len` (`sync_division_positions_frame`
  `:5142-5158`, per track, not mode gated), the Once relaunch origin rewrites the
  pair through `le_shared_track_position` (`:123-134`, applied `:5353-5361`), the
  read is `lbuf[seg_base[t] + trk_pos[t]]` (`:5593`), and `trk_play_pos` publishes
  the index (`:5365-5368`). The buffer and its capacity are snapshotted once per
  block from `a_live`/`pool_cap` (`:5287-5299`) and the command ring is drained
  before any frame is mixed (`:5928-5932`, `:6302`), so a change applied inside
  `apply_command` is coherent for the whole block.
- Multiples and divisions: `a_multiple` (`engine_private.h:1114`), `a_sync_divisor`
  (`:1115-1123`), chosen at finalize by `le_sync_choose_ratio` (exact divisions
  only, `engine_process.c:1168-1194`) or the round-up rule with the cap clamp
  `maxk = max_loop_frames / base` (`:1359-1366`), re-derived from a length by
  `le_restore_multiple_or_divisor` (`:1210-1222`) and `le_restore_track_clock`
  (`:1226-1251`, which also re-establishes a dead master). The span rule is one
  helper, `le_mode_span_fits` (`engine_private.h:2140-2146`): whole multiples of
  the base, plus 1/2 and 1/4 divisions in Sync/Band; the base channel is
  `le_mode_base_channel` (`:2165-2188`, shortest take in Multi, crowned primary in
  Sync/Band) with the control-side twin `le_ctl_mode_base` measuring
  `le_effective_len` (`engine_commands.c:2538-2571`). `le_sync_quantize_active`
  requires the primary at exactly `a_multiple == 1` and no divisor
  (`engine_private.h:2062-2071`).
- The seam crossfade is one equal-gain fold baked into PCM: `seam_xfade_frames =
  sr/100` (`engine_process.c:971-974`), `seam_room` requires `len >= 2F` and
  capacity (`:982-993`), `le_seam_fold` morphs the head `[0,F)` from the captured
  continuation `[len, len+F)` (`:1005-1016`); the dub-shadow twin repeats the
  arithmetic (`:1054-1086`).
- Undo layers are sized `le_layer_slot_frames(len)` (quantum `LE_LAYER_QUANTUM`,
  `engine_commands.c:166-171`; `engine_private.h:142-149`); the live slot of a
  recording is cap-sized; `le_lane_ensure_slot` grows by replacing
  (`engine.c:84-91`), `le_lane_shrink_slot` keeps leading frames (`:99-106`).
  `track_acquire_slot` picks a slot outside live, both stacks and `outstanding`
  and evicts the lowest non-CLEAR entry when full (`engine_commands.c:101-140`;
  #1161 splits out the pure `track_select_slot`). `LE_POOL_SLOTS = 256`
  (`engine_private.h:130`), `max_loop_frames` default 30 s (`engine.c:383`).
- History: kinds `LE_HIST_LAYER`/`LE_HIST_CLEAR` (`engine_private.h:782-787`), the
  tagged `le_hist_entry` whose `len`, `multiple`, `master_len` payload is used by
  CLEAR only (`:794-809`), stacks (`:909-912`). In-track Undo/Redo are
  control-thread swaps (`le_undo_swap` `engine_commands.c:268-274`, redo `:2242-2249`);
  the paths that change state or length ride the ring as state commands
  acknowledged through `le_mark_state_cmd`/`a_state_acks` (`:407-412`), with
  `le_effective_state`/`le_effective_len`/`le_effective_master_len` reporting the
  pending outcome (`engine_core.h:99-107`; `engine_commands.c:417-457`). The
  history mode gate projects restored spans against `le_mode_span_fits`
  (`:1829-1930`). `le_restore_commit_layer` is the precedent for building a new
  image on the control thread from the live buffer of a non-writing track
  (`:344-404`). The event ring files audio-thread outcomes on the control thread
  (`le_handle_event` `:666-678`; `le_engine_drain_events` `:734-802`).
- Receipts: `le_fade_admit` and `fade_receipts[LE_RING_CAPACITY]`
  (`:2281-2306`, `engine_private.h:1641-1644`), read by `le_engine_read_fade_result`
  (`:2324-2335`), applied with the result stored by the callback
  (`engine_process.c:2990-3012`). The Reverse plan generalizes these to
  `le_request_admit`/`le_engine_read_request_result`.
- Session layers: export reads every ordinal at the track's current `a_len`
  (`engine_session.c:162-182`, `:176`), import publishes `a_len = frames` on every
  ordinal idempotently (`:231`), finalize requires every slot's capacity to hold
  that one length (`:262-272`) and files every ordinal as LAYER (`:277-282`); the
  commit handler derives `k = len / base` and zeroes the divisor, so a saved
  division (`len < base`) would reload as `k = 1` with a shorter buffer than the
  master reads (`engine_process.c:3729-3737`, a documented B5c gap).
- Dart seam: `AudioEngine.undo/redo` synchronous, `toggleFade` admission + receipt
  (`audio_engine.dart:73, 206-212`), repository `_requestFade` observation
  (`looper_repository.dart:2151-2169`), `_historyModeGate` and the
  `RecoveryRefusal` notice stream (`:1934-1961`), `undo`/`_undoTrack`
  (`:3612-3683`), `redo`/`_redoTrack` (`:3706-3760`), projection (`:2412-2440`),
  `Track.lengthFrames/undoDepth/multiple/layers/wholeBars`
  (`track.dart:101-114, 146-147, 242, 251-275`), `TrackSnapshot`
  (`engine_snapshot.dart:599-634, 686-712`; `sync_divisor` is not mapped),
  Session capture (`session_repository.dart:645-714`), model (`session.dart:49-79,
  183-261`, schema 11 `:688`), mapping (`session_mapping.dart:365-403`), import
  replay and commit (`looper_repository.dart:4362-4414, 4451-4459`).
- Surface precedent: `InteractionMode` (`interaction_mode.dart:8-56`),
  `TrackOperation` and `allowsAllTracks` (`control_action.dart:151-189`, parse
  `:268-277`, catalogue `:452-462`), `ModeAction.token` (`:343-350`), dispatch arm
  (`control_cubit.dart:2906-2917`), `_FootFadeControl` part
  (`control_foot_fade.dart:1-75`), `FootFadeActions` (`foot_fade_actions.dart`),
  `FootFadeProjection.pedalRoles` (`foot_fade.dart:154-193`), selection-driven
  Mixer LEDs (`control_projection.dart:248-253`), Fade LED and mask (`:97-102,
  255-258`), `ControlState.footFadeFailure` (`control_state.dart:23-24, 115-116`),
  toast and composition (`tracks_view.dart:138-148, 209-212`), a11y and tap arms
  (`track_column.dart:364-404`), layer badge (`:661-667`).

## 1. Native contract

### 1.1 The three edits and the length plan (design question 1)

One operation, `le_length_edit {LE_LENGTH_DOUBLE, LE_LENGTH_FIRST_HALF,
LE_LENGTH_LAST_HALF}`. With `L = a_len` and `half = (L + 1) / 2`:

- Double: new image `[old | old]`, `L' = 2L`.
- First half: new image `old[0, half)`, `L' = half`.
- Last half: new image `old[L - half, L)`, `L' = half`.

Odd `L`: both halves are `half` frames and share the middle frame (one frame,
about 20 microseconds). Odd lengths only reach this rule in Free/Song and in the
sole-content case below; in the shared modes every accepted edit tiles exactly.

A pure helper `le_length_plan(mode, base, is_base_channel, others_have_content,
L, edit, max_loop_frames, &plan)` decides, and is shared by the control-side
admission and the audio-thread recheck (the mode gate's "control validates, the
audio thread rechecks" rule, `engine_commands.c:2515-2518`). `plan` carries `L'`,
`k'`, `n'` and `reclock` (0, or the new master length). The verdict, in order:

1. `LE_ERR_INVALID`: `L <= 0`, or `L < 2` for a halving.
2. `LE_ERR_CAPACITY` (`segno_engine_api.h:46-49`): `L' > max_loop_frames` (Double
   at or above half the cap).
3. Free/Song (`le_mode_span_fits` returns 1 for any span, `engine_private.h:2141`):
   `k' = 1`, `n' = 0`, no re-clock; the track's own clock follows.
4. Shared modes, this track is the only track with content (every other track's
   `le_effective_state` is EMPTY, a RECORDING sibling counts as content): the base
   follows the track, `reclock = L'`, `k' = 1`, `n' = 0`. Nothing else is altered,
   so the accepted sentence is satisfied; this is what makes "record two bars,
   keep the first" work on a one-track session. The Sync primary stays exactly one
   base loop, so `le_sync_quantize_active` keeps holding (`:2062-2071`).
5. Shared modes, siblings hold content, and this track is the crowned Sync/Band
   primary: `LE_ERR_MODE_MISMATCH`. Doubling it to `k = 2` would silently
   un-establish Sync quantization for every later take (the BUG 4 discussion at
   `engine_process.c:1253-1281`); halving it would re-clock every dependent.
6. Shared modes otherwise: `L'` must satisfy `le_mode_span_fits(mode, base, L')`
   (`engine_private.h:2140-2146`), else `LE_ERR_MODE_MISMATCH`. Accepted results:
   Multi `k -> 2k` and `k -> k/2` for even `k`; Sync/Band additionally `1 -> n 2`,
   `n 2 -> n 4`, `n 2 -> 1`, `n 4 -> n 2`; refused: Multi `k = 1` halved (a half
   base is not a Multi span), Sync `n 4` halved, odd base halved (no exact
   division, the rule `le_sync_choose_ratio` already enforces, `:1181-1187`).
   `k' = L' / base` when `L' >= base`, else `n' = base / L'`
   (`le_restore_multiple_or_divisor`'s arithmetic, `:1210-1222`).

The multiple is therefore never "plain length": a Double of a `k` track in a
shared mode is `k' = 2k` on the unchanged master; a halving is `k/2` or a
division. Nothing re-rounds, pads or trims another track, and the master only
moves in the sole-content case, exactly where no other track exists to alter.

### 1.2 Image, seam and sparse material

The control thread builds the image, as `le_restore_commit_layer` does
(`engine_commands.c:366-389`): acquire a slot (`track_acquire_slot`, after #1161
through `track_select_slot`), `le_lane_ensure_slot(slot, le_layer_slot_frames(L'))`
on every active lane (OOM -> `LE_ERR_INVALID`, the slot stays unreferenced), copy
from `pool[live]` (NULL reads as silence), then fold the new wrap:

- Double: no fold. The join `old[L-1] -> old[0]` and the new wrap are the already
  folded original wrap.
- First half: the continuation of `new[half-1]` is `old[half, half+F)`, which the
  omitted half supplies: `new[i] = old[half+i]*(1-x) + new[i]*x` for `i < F`.
- Last half: the continuation of `old[L-1]` is the folded head `old[0, F)`:
  `new[i] = old[i]*(1-x) + new[i]*x`.

Both use `F = seam_xfade_frames` and the `seam_room` threshold (`half >= 2F`,
`engine_process.c:971-993`), through one shared body `le_seam_fold_head(float*
head, const float* continuation, int32_t F)` factored out of `le_seam_fold` and
`le_seam_fold_dub_shadow` (`:1011-1014`, `:1081-1084`) and declared in
`engine_core.h` beside `le_track_set_len` (`:127`). One crossfade law (rule 4).

Sparse material is copied as it lies: one bar of sound in a four-bar Multi loop
doubles to sound in bars 1 and 5 of 8, First half keeps bars 1-2 (sound in bar
1), Last half keeps bars 3-4 (silence). No trimming, no re-anchoring; "omitted
material is recoverable through history" (§2.7, `accepted-behavior.md:140-144`).

### 1.3 Why the edit rides the ring: `LE_CMD_SET_LENGTH`

A playing track's `a_live`, `a_len` and `a_multiple` are read as separate atomics
every frame (`:5312-5323`, `:5593`), so a control-thread swap to a half-length
slot would read past its capacity for up to one block, and a Double would play
the new buffer with the old segment math. The only coherent point is the command
drain before the block's mix (`:5928-5932`). Precedent: every path that changes a
length today applies it on the audio thread (`LE_CMD_REDO_FROM_EMPTY`,
`LE_CMD_RESTORE_CLEAR`, `:2846-2910`).

- `LE_CMD_SET_LENGTH = 84` (`segno_engine_api.h:511-517`; 83 is Reverse), payload
  arm `struct { int32_t channel, slot, pool_slot, len, multiple, divisor, reclock,
  edit; } length;` in `le_command` (`lockfree_ring.h:99-131`). Checked, never
  raw-posted (`le_push` refusal list, as Fade/Reverse).
- Control admission, `le_engine_edit_length(engine, channel, edit, uint64_t*
  request)`, after `le_engine_drain_events`: `LE_ERR_NOT_RUNNING` when not configured;
  `LE_ERR_INVALID` bad channel/edit or `le_effective_state` not PLAYING/STOPPED;
  `LE_ERR_NOT_READY` while `state_cmds_posted > a_state_acks`, `a_layer_in_flight`,
  `clear_restore_pending`, `cancel_pending`, `queued_undo`, `dub_punch_out_posted`,
  `outstanding_count > 0`, `engine->armed[ch]`, `a_pending`, `a_pending_launch`,
  `a_launch_grace`, `clock_commands_posted != a_clock_commands_applied` (a mode or
  crown change in flight, `:1853-1855`) or `lane_growth_command` unpublished
  (`engine_session.c:76-77`); then the plan verdict (1.1); then slot and image
  (1.2); then `le_request_admit` (receipt). Push-then-mutate: on `LE_OK` pin the
  slot (`outstanding_slots[outstanding_count++] = pool_slot`, set
  `t->length_pending = pool_slot + 1`), `le_mark_state_cmd(t, st)` with
  `pending_len = L'` and `pending_master_len = reclock ? L' :
  le_effective_master_len` (so `le_effective_len`, the clear restore point and the
  history gate measure the post-edit rig, `engine_commands.c:417-457, 1725-1739`).
- Callback (`case LE_CMD_SET_LENGTH`): recheck `a_state` PLAYING/STOPPED, `od_gain
  == 0`, `seam_capture == 0`, `xfade_capture == 0`, `dub_slot < 0`, and recompute
  the plan against the actual rig (`a_looper_mode`, `a_primary_track`, sibling
  `a_state`/`a_len`, `clock.length`); the payload must match. Refusal stores
  `LE_ERR_NOT_READY` in the receipt and pushes `LE_EVT_LENGTH_RESULT {channel,
  lane = -1, value = 0}`. Acceptance, in this order: `le_dub_drop_armed(t)`
  (`:1513-1525`, defensive), compute the playhead mapping (1.4), store
  `a_live = pool_slot` on every active lane, `le_track_set_len(t, L')`,
  `a_multiple = k'`, `a_sync_divisor = n'`, re-clock if asked, `reset_track_viz`
  (`:865-871`), `le_audio_rev_bump` (as `finalize_master` `:928`; the wet caches
  and printed renders key on `{audio_rev, len}` and fall back to live reads,
  `engine_private.h:443-449`), push `LE_PLOG_LENGTH` (1.6), push
  `LE_EVT_LENGTH_RESULT {channel, lane = previous live slot, value = L}`, store the
  receipt `LE_OK` (release, after the event so a reader that sees the receipt and
  drains sees the event), `a_state_acks++`.
- The audio thread writing `a_live` is the one exception to "sole writer is the
  control thread" (`engine_private.h:457-459`). The invariant's purpose, no
  history motion racing the callback, is kept by `length_pending`: Undo, Redo,
  Peel, Clear, Record, restore commit, import and finalize on that track return
  `LE_ERR_NOT_READY` until the event is filed. Existing windows are untouched;
  the flag is new state and only this command sets it (rule 3).
- Control filing (new `le_handle_length_result` in `le_handle_event`, `:666-678`):
  clear the pin and the flag; on refusal nothing else. On acceptance of a fresh
  edit: `undo_stack[undo_count++] = {LE_HIST_LENGTH, slot = previous live, len =
  L, master_len = reclock ? previous master : 0}`, `le_clear_redo(t)` (a new edit
  retires Redo, §2.10), shrink the previous slot to `le_layer_slot_frames(L)`
  (`le_lane_shrink_slot`, the `le_handle_retired` argument at `:610-628`: the
  audio thread no longer names it), `le_publish_undo_depth`, stage the new image
  for the performance capture (1.6). Undo/Redo filing: 2.1.

### 1.4 Playhead mapping and transport

With `cur` the current full-track read index (`le_shared_track_position` in the
shared modes, `pos % L` for a division, `free_clock.position` in Free/Song;
`trk_play_pos[t]` for a STOPPED track, which holds its index, `:5368`):

- Double: `cur' = cur`. The current segment keeps playing the same material and
  the copy follows it.
- Halving: `cur' = (cur - start) mod half` with `start = 0` (first) or `L - half`
  (last). A playhead in the omitted half lands at the same phase of the kept half
  (bar 3 of 4 becomes bar 1 of 2), so the groove never stalls.
- Free/Song: `le_loop_clock_set_length(&free_clock, L')` then `position = cur'`
  (`loop_clock.h:25-26`).
- Shared multiple: `start_iter' = loop_iteration - (seg mod k')`, and
  `playback_offset' = (cur' - (seg' * base + clock.position)) mod L'`, which is
  zero whenever the offset was zero (the ubiquitous case). With Reverse merged the
  origin goes through `le_direction_origin` so a reversed track stays reversed at
  the mapped index (Reverse plan 1.1).
- Shared division: `pos % L'` already equals `cur'`; nothing to set.
- Re-clock (sole content): `le_loop_clock_set_length(&clock, L')`, `position =
  cur'`, `loop_iteration = 0`, `start_iter = 0`, `a_master_len = L'`,
  `sync_grid_to_loop(e, L')` (bars halve or double at the unchanged tempo,
  `:580-608`), `loop_viz_bucket = -1`, `LE_PLOG_LOOP_LENGTH_LOCKED` (as
  `le_restore_track_clock` `:1239-1246`).
- `trk_play_pos[t] = cur'` so a STOPPED track publishes the mapped index; a PLAYING
  track recomputes next frame. `sounding_frames`, Once flags, mute, solo, Fade and
  lane chains are untouched. Stopped stays stopped; Play then plays the new image.

### 1.5 Interaction with capture, Fade, Reverse, #1161, #1158, #1143

- Capture: refused while RECORDING, OVERDUBBING, during the punch tail and the
  drain, and while an arm or launch is pending (1.3). An armed punch-in's shadows
  are sized to the old length (`le_post_dub_shadows` `:187-212`) and a dub session
  latches `dub_len` from `a_len` (`engine_process.c:1476`), so an arm firing into a
  resized track would write past its shadow; refusing the edit is the fail-safe
  (rule 2). The 10 ms trailing seam capture after a new take (`seam_capture`,
  audio-thread-local) is caught by the callback recheck and reported
  `LE_ERR_NOT_READY`.
- Fade: the envelope lives on `le_track.fade`, independent of the image; it keeps
  running through an edit (Clear-history oracles "layer Undo/Redo keeps live Fade").
- Reverse: direction is preserved and re-originated (1.4). Reverse's own overdub
  refusal is orthogonal.
- #1161: the edit acquires its slot through the shared selector and never empties
  a track, so `empty_command` is untouched; a fresh capture after Undo to empty
  regrows the live slot as today.
- #1158 reopen: history entries and `a_live`/`a_len`/`a_multiple` are material and
  retained; a length edit unapplied at device loss is a state command, so that
  track is dropped and reported in the mask with a notice, exactly the reopen
  plan's rule (rule 5); its receipt retires with the Fade receipts. Part 2 adds the
  tests; no reopen code changes.
- #1143: a length edit changes the live image without a state change, the class
  that plan names. The fact (1.6) carries full identity and the image is staged
  with a restore id; the renderer is unchanged here. The live perf-restore source
  ends truthfully when the buffer pointer changes (`:5375-5378`).

### 1.6 Performance log and offline render

- `LE_PLOG_LENGTH = 326` (`perf_log_ring.h:49-165`; Reverse 324, Peel 325), payload
  `struct { int32_t channel, slot, len; uint32_t image_id; } length_log;` in
  `le_command` and `le_log_command` (16 bytes, `:184-201`), pushed at every applied
  edit, undo and redo of a LENGTH entry. `LE_CMD_SET_LENGTH` joins the
  `le_log_extract` exclusion list (`:205-211`). Bump the events.log version
  (`perf_drain.c:812-816`) and add the row to
  `docs/design/performance-event-log-format.md:195-215`.
- Staging: at filing time, when `perf.drain` is armed, `le_stage_retired_layer(ch,
  pool_slot, 0, L', ++perf.next_restore_id)` (`engine_commands.c:535-586`, the
  restore-id shape, which takes an explicit length): one capture-local immutable
  image namespace for Clear restorations and length edits. The id is written into
  the fact by the control side's `le_plog_push_ctrl`? No: the audio thread pushes
  the fact at apply, so control reserves the id at post (as `le_restore_clear`
  `:1995-2001`) and passes it in the payload. The renderer binds later (#1143).

### 1.7 Worked example (the native oracle)

Positional PCM `pcm[i] = i + 1` over `L = 8` frames on track 1 under a silent
8-frame master (fixture `test_loop_multiple_records_two_loops`,
`test_engine_core.c:4085-4127`; `make_configured_engine` `:481-485`):

1. Double at index 5 while playing: output continues `6, 7, 8` then `1..8, 1..8`;
   `length_frames 16`, `multiple 2`, `position_frames` runs to 15; undo stack
   `[LEN(slot0, 8)]`, `undo_depth 1`, `redo_depth 0`.
2. First half: output `1..4` repeating, `length 4`, `multiple 1`, `redo` empty,
   stack `[LEN(8), LEN(16)]`.
3. Undo: `1..8, 1..8` again; redo `[LEN(4)]`. Undo: `1..8`; redo `[LEN(4), LEN(16)]`.
   Redo twice returns to `1..4`.
4. Overdub `+0.5` over the half, then Peel: refused `LE_ERR_INVALID` once the
   LAYER above the LENGTH is consumed (Peel plan 1.1: non-overdub kinds block).
5. Last half of a 1-track rig at 48 kHz, `L = 48000`, pattern with a step at the
   middle: the first `F = 480` frames of the result equal the equal-gain fold of
   `old[0..F)` into `old[24000..24480)`; frame `F` onward is bit-exact `old[half+i]`.

## 2. History and Session semantics (design question 2)

### 2.1 One kind, symmetric motions

`LE_HIST_LENGTH = 4` (`engine_private.h:782-787`; Peel claims 2 and 3). On either
stack the entry means "the image in `slot` has `len` frames; `master_len` is the
master to restore when this track is the sole content, else 0". Every length edit
is one entry; Divide keeps the full old image untouched in its old slot (no copy),
Double keeps the half image. "Omitted material is recoverable through history" is
therefore structural.

- Undo of a LENGTH top (`le_engine_undo`, after the clear check at
  `engine_commands.c:2115`): `le_engine_history_mode_gate` extended to project
  `restored = entry.len`, `saved_base = entry.master_len` for a LENGTH top
  (`:1886-1928`, the same `le_mode_span_fits` loop that already guards Clear
  restores); then post `LE_CMD_SET_LENGTH {pool_slot = entry.slot, len =
  entry.len, k/n from le_restore_multiple_or_divisor, reclock = sole content ?
  entry.len : 0}` with the pin and flag; the synchronous result is `LE_OK`
  (posted), as for undo-to-empty and restore-clear. At the event: pop the undo
  entry, push `{LENGTH, slot = previous live, len = L, master_len}` onto redo,
  `le_publish_undo_depth`, `a_redo_depth`, `le_plog_push_ctrl(LE_PLOG_UNDO)`.
- Redo of a LENGTH redo top (`le_engine_redo`, before the swap at `:2242`): mirror;
  no `le_clear_redo`; `LE_PLOG_REDO` at the event.
- Queued undo (`le_apply_queued_undo` `:476-506`) and the plain swap paths treat a
  LENGTH top by returning the queued taps unapplied (`break`) so a queued tap
  never posts a ring command from the drain; the next explicit tap undoes it.
- `le_engine_history_mode_gate` keeps `LE_ERR_NOT_READY` while a length edit is
  pending on a selected track.
- Peel (Peel plan 1.1): LENGTH entries block Peel above the topmost LAYER, and
  `le_peel_depth` already excludes them, so `Track.layers` stays truthful (a Double
  is not a layer). Pool eviction may evict a LENGTH entry (never CLEAR): eviction
  removes the lowest entry, so the remaining entries always share one length
  lineage with the next LENGTH above; the cost is one lost recovery step, never
  audible material (rule 2).
- Clear over a length edit keeps LENGTH entries beneath the CLEAR point; Undo of
  the Clear restores the current length (`restore.len`), and the next Undo then
  undoes the length edit. Clear All groups: a length edit on a member is a newer
  dependent edit; `_intactClearAllGroup` already drops such members (§2.11,
  `looper_repository.dart:3617-3619`).
- Memory at the cap: Divide adds `le_layer_slot_frames(half)` per lane and shrinks
  the old live slot to its quantized length; Double requires `2L <= max_loop_frames`
  and adds `le_layer_slot_frames(2L)`, so a track is at most `3L` per lane after a
  Double. Both images stay referenced until Undo/Redo lineage or eviction frees
  one.

### 2.2 Per-entry lengths in export and Session

Images now differ in length within one lane. `le_hist_len_at(t, stack, count, i,
live_len)` gives the length of any image: on the undo stack, the `len` of the
lowest LENGTH entry above `i`, else the live length; on the redo stack, the `len`
of the nearest LENGTH entry at or deeper than `i`, else the live length.

- Part 1: `le_engine_export_layer` returns the entry's own length instead of
  `a_len` (`engine_session.c:176`) and checks `pool_cap[slot] >= n` (today
  unchecked). Identical for every existing Session, where lengths never differed.
- Part 2 (composing with Peel's Part 2): `le_engine_export_history(channel,
  kinds[], skipped[], lens[], max)` adds `lens[]`; `le_engine_finalize_history`
  gains `lens[]` and `live_len`, validates `pool_cap[s] >= lens[s]` per slot,
  files LENGTH entries with `len = lens[s]` (and `master_len = 0`: a recalled
  Session has one saved base, so an undo that would re-clock measures `restored`
  against the current rig through the gate), publishes `a_len = live_len`;
  `le_engine_import_layer` stops publishing `a_len` (`:231`). Dart: each layer's
  frame count is its WAV's length (`laneStems`), so `SessionLane.history` entries
  stay `{kind, skipped}`; the strict decoder derives each entry's expected length
  with the same rule and rejects a bundle whose WAV lengths disagree with its
  kinds (`SessionCorruptLayers`), before any side effect. Schema bump to the next
  number after Peel's (lengths may now differ within a lane; current-schema decode
  only, AGENTS.md). `exportLayer` allocates per entry from `exportHistory`'s
  `lens[]` (`native_audio_engine.dart:1120-1141`); capture at
  `session_repository.dart:652-695`; replay at `looper_repository.dart:4362-4414`.
- Division recall: `LE_CMD_COMMIT_SESSION` calls `le_restore_multiple_or_divisor`
  instead of `k = len / base; if (k < 1) k = 1` (`engine_process.c:3729-3737`), so a
  saved `base/2` or `base/4` track reloads as the division it was. This closes the
  B5c gap that Divide would otherwise expose on every save (rule 2); a saved
  multiple reloads byte-identically.
- `SessionTrack.multiple`/`lengthFrames` and `baseLengthFrames` already carry the
  live values (`session.dart:242-246`, `:859`); a re-clocked sole track saves its
  new master.

## 3. Surface (design question 4)

The accepted row describes actions, not a pedal layout; the owner asks how a foot
mode exposes the three edits. Default under rules 3 and 4, flagged below:

- `InteractionMode.length` (`interaction_mode.dart:46`), label "Multiply / Divide",
  excluded from `bootDefaults` (`:56`); `toggleMode` returns to `record` from it
  (`control_cubit.dart:1645-1652`); `ModeAction` token `'length'`
  (`control_action.dart:343-350`); label `actionModeLength`.
- "One selected track" is the shared cursor (`ControlState.cursor`,
  `control_state.dart:118-120`): track pedals select on contact (`selectTrack`),
  as in Record mode, so Rec/Play, Undo and Redo elsewhere agree on the same track
  (rule 4: no second selection). `ControlState` gains only `footLengthFailure`.
- `lib/control/model/foot_length.dart`: `FootLengthAction {doubleTrack, firstHalf,
  lastHalf, selectTrack, stop, exit, nextBank}`, `FootLengthPedal`,
  `FootLengthTrack {channel, available, lengthFrames, multiple, syncDivisor,
  selected}` with `available = hasContent && !isCapturing && !layerInFlight &&
  !pending && pendingLaunch == null`, `FootLengthProjection {bank, cursor, tracks}`
  and `pedalRoles`: track1-4 `selectTrack` immediate; recPlay `doubleTrack`;
  undo `firstHalf`; clear `lastHalf`; stop `stop`; bank `nextBank`; mode `exit`;
  no holds. Rec/Play as Double follows the EDP/Boomerang convention that Multiply
  belongs to the record family; in FX mode Rec/Play is already inert, so the
  pedal's meaning is per mode (`interaction_mode.dart:21-25`).
- `lib/control/foot_length_actions.dart`: stateless `edit(channel, LengthEdit)`
  over `LooperRepository.editLength`, returning `invalid` for an unavailable
  track without a notice; shared by the surface and assigned actions
  (`foot_fade_actions.dart:51-63`).
- `lib/control/cubit/control_foot_length.dart` part: `_lengthEditable`,
  `_onLengthPress`, `_dispatchLengthAction`, `_reportLengthFailure(result)`
  mirroring `control_foot_fade.dart:1-75`; public `footLengthPressed/Released/
  Cancelled`, `activateFootLengthPedal`, `editFootLengthTrack(edit)`; `_onPress`
  routing (`control_cubit.dart:2618-2625`); `recPlay`/`stop`/track arms
  (`:2670-2679`).
- Refusals are distinct notices, since "reject incompatible mode lengths" must be
  visible by foot: `footLengthIncompatible` (`modeMismatch`), `footLengthCapacity`
  (`capacity`), `footLengthBusy` (`notReady`), `footLengthFailure` (other). One
  toast per visit (`tracks_view.dart:138-148`). No pre-query of compatibility:
  the verdict is the engine's, computed once at admission (rule 4).
- `TrackOperation.multiply('multiply')`, `.divideFirstHalf('divide-first')`,
  `.divideLastHalf('divide-last')` (`control_action.dart:151-189`), labels
  `actionOperationMultiply`, `actionOperationDivideFirstHalf`,
  `actionOperationDivideLastHalf`, dispatch arms (`control_cubit.dart:2906-2917`)
  through `FootLengthActions.edit`. Selected and fixed scopes only:
  `allowsAllTracks` excludes all three like `clear` (`:183-188`), since eight
  length edits behind one stomp leave eight undo steps and most rigs would refuse
  several members. "Separately assignable" is satisfied: Multiply, Divide first
  half and Divide last half are three catalogue entries, and the mode is a fourth.
- LEDs: in `length` mode a track LED is red for the cursor (the Record-mode cursor
  convention, `control_projection.dart:91-94`), off otherwise; slot-less buttons
  follow `acceptedContacts` like Fade (`:255-258`); `PedalMode.custom` wire mapping
  (`:198-205`; `invariants.dart:152-159`); `pedal_plate.dart:625-626, 1051`; themes.
- `lib/looper/view/foot_length_view.dart`: `PerformancePedal` layout as the Fade
  view (`foot_fade_view.dart:141-157`; `performance_pedal.dart:13-31`), a title,
  captions "Double", "First half", "Last half", and an eight-track overview cell
  with name, `wholeBars` or seconds, and `x2`/`x4`/`1/2`/`1/4`/`Empty`; the
  selected bar lit on the cursor, Exit and Bank B. Tracks composition
  (`tracks_view.dart:209-212`), a11y and switch arms (`track_column.dart:364-404`,
  `wave_track_row.dart`, `tracks_commands.dart:118-123, 225-229, 312-314`). The
  existing bars figure (`track_column.dart:655-660`) already follows
  `lengthFrames`.
- Dart facts: `TrackSnapshot.syncDivisor` from `sync_divisor`
  (`segno_engine_api.h:874`; `engine_snapshot.dart:686-712`) and `Track.syncDivisor`.
- Localization: English and Spanish strings for the mode, operations, captions,
  overview words and the four notices (`app_en.arb:5901-5987` pattern).

## 4. Session (design question 5)

Covered in 2.2: kinds persist through Peel's `history` list; lengths are the WAV
lengths; the decoder validates the lineage; `finalize_history` takes `lens[]`;
`export_layer` returns per-entry lengths; the commit handler restores divisions;
schema bumps once. Recall publishes STOPPED at the loop head
(`LE_CMD_COMMIT_SESSION`), so a Doubled track starts at segment 0 and a division at
the primary's top.

## 5. Parts

Each part is independently mergeable, keeps the public app working and exposes no
unfinished destination. Parts 1 and 2 are unadvertised (no mode entry, no
assignment, so no install can create LENGTH entries before Part 2 persists them);
Part 3 exposes the journey. Sequence Part 1 after Peel Part 1 (#1164: kinds 2-3,
`le_peel_depth`, `Track.layers`), #1161 (`track_select_slot`) and #1158 (per-track
init moved into `le_engine_reset_material`); Part 2 after Peel Part 2
(`le_engine_finalize_history`, `SessionLane.history`).

### Part 1. Native length edit, history kind and engine seam (about 680 production lines)

Native (`engine_private.h`, `engine_core.h`, `engine_process.c`,
`engine_commands.c`, `engine_session.c`, `segno_engine_api.h`, `lockfree_ring.h`,
`perf_log_ring.h`, `perf_drain.c`): sections 1.1-1.7 and 2.1: `LE_HIST_LENGTH`,
`le_length_plan`, `le_seam_fold_head`, the image builder, `le_engine_edit_length`
with `le_request_admit` (factor it here if Reverse has not merged), `length_pending`
and its refusals, `LE_CMD_SET_LENGTH` handler with the mapping and re-clock,
`LE_EVT_LENGTH_RESULT` filing, LENGTH undo/redo through the command, the mode gate
extension, `le_hist_len_at`, `export_layer`'s per-entry length and capacity check,
`LE_PLOG_LENGTH`, staging, version bump and doc row. Dart seam:
`AudioEngine.editLength({channel, edit}) -> RequestAdmission` (the renamed
`FadeAdmission`, `audio_engine.dart:73`), `LengthEdit` enum, `TrackSnapshot.
syncDivisor`, `NativeAudioEngine`, `MockAudioEngine` (`mock_audio_engine.dart:
599-610`), the four fakes (`test/helpers/fake_audio_engine.dart`,
`packages/looper_repository/test/helpers/fake_audio_engine.dart`,
`packages/performance_repository/test/helpers/fake_performance_engine.dart`,
`packages/session_repository/test/helpers/fake_session_engine.dart`), regenerated
and formatted bindings (`ffigen.yaml`), `LooperRepository.editLength` through
`_requestReceipt` (`looper_repository.dart:2151-2169`; `notReady` while
`_sessionAudioReserved`), `Track.syncDivisor`, projection (`:2412-2440`). If the
seam pushes the part over 700 lines, it moves to the head of Part 2 unchanged.

Notes (Part 1 build, on the trunk with Reverse and Peel merged):
- Codes from the numbering ledger: command 84 and fact 326. events.log
  version 9 (8 is assigned to pitch/time Speed); version numbers are assigned
  in landing order, so this one is renumbered if another bump lands first.
- No `LE_EVT_LENGTH_RESULT`: the callback publishes its verdict in
  `a_length_result` before the state acknowledgement it already owes, and the
  control drain files the entry once that ack lands (`le_length_collect`). An
  event push can fail on a full ring; the ack cannot.
- A LENGTH entry carries `len` and `start`, the playhead map into its image
  (index `(i - start) mod len`), instead of `master_len`: a track that is the
  rig's only content always has `k = 1` and master = length, so its Undo and
  Redo re-clock to the entry's length through the same verdict as an edit.
  `le_engine_history_mode_gate` asks that verdict for a LENGTH top instead of
  projecting a span.
- Outstanding dub shadows are not a refusal: a finished dub session leaves its
  spare armed, so an accepted edit drops the idle shadows on the callback and
  the drain releases them, while a refused one releases only the edit's pin.
- `le_engine_finalize_history` and the Session decoder refuse the LENGTH kind
  until Part 2 carries per-image lengths.

Tests (`src/test/test_engine_length.h`, included like `test_engine_fade.h` at
`test_engine_core.c:32969`; literal PCM through `le_engine_process`, positional
patterns): the worked example of 1.7 at 48 kHz, blocks 1/127/512; Double of a
`k = 2` track (`:4085-4127` fixture) keeps the segment; First and Last half of a
Sync division 2 (`:24951-24994` fixture) phase-lock as division 4 over two primary
cycles; Double of a division 2 reads as `k = 1`; Multi `k = 1` halving refused
`LE_ERR_MODE_MISMATCH` with a sibling, accepted as a re-clock without one (master,
bars, `LE_PLOG_LOOP_LENGTH_LOCKED`); Sync primary with a dependent refused, sole
primary re-clocks and keeps `le_sync_quantize_active`; odd Free length halves to
`ceil` sharing the middle frame; Double over the cap refused `LE_ERR_CAPACITY`;
seam fold of both halves bit-exact against `le_seam_fold_head` and absent under
`2F`; STOPPED edit stays silent and `position_frames` maps; playhead mapping in
the omitted half; `playback_offset` after a Once relaunch; refusals while
RECORDING, OVERDUBBING, during the drain, with an arm, launch, pending state
command, pending clock command, and the callback refusal during `seam_capture`
(receipt `LE_ERR_NOT_READY`, pin released, PCM and history untouched); Undo, Redo,
Clear, Record and Peel refused `LE_ERR_NOT_READY` while pending; Undo/Redo of
LENGTH entries across a sibling recorded after the edit (gate refusal, then
success after the sibling is cleared); Clear above LENGTH entries and its Undo;
pool eviction with LENGTH entries keeps slot references unique; `export_layer`
returns each image's own length and refuses a short slot; two lanes resize
together; Fade and Reverse (if merged) continue through an edit; the 326 fact and
a staged image with an id; sanitizer and telemetry-off builds; the C++17 shim
compiles with the new fields. One actual-native repository case in
`packages/looper_repository/test/length_native_test.dart` (fixture of
`fade_native_test.dart:12-47`) confirms the receipt, `Track.lengthFrames`,
`multiple`, `undoDepth` and that `undo()` restores the length.

```success-criteria
GOAL: A checked native Double, First half and Last half resizes one track's image coherently on the audio thread, refuses incompatible mode lengths and capacity without touching other tracks, records one recoverable history entry per edit, and leaves the public app unchanged.
SUCCESS CRITERIA:
- Literal PCM proves the worked example, segment and division phase lock, re-clock of a sole track, odd halves, both seam folds, STOPPED edits and playhead mapping at two rates and three block sizes. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Every refusal (capturing, armed, pending, incompatible, capacity, callback recheck) returns the specified code, releases its slot and mutates nothing; Undo/Redo of LENGTH entries pass through the history gate and restore exact images and lengths. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The 326 fact, the staged image, the events.log version bump and per-entry export lengths are correct, and sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings, symbol parity and the Dart seam are complete; the repository confirms an edit and projects length, multiple and divisor. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- The C++17 shim repro from docs/PROGRESS.md compiles and the ELF symbol check passes on CI. | verify: manual run the PROGRESS shim repro and packages/segno_engine/tool/check_ffi_symbols.sh on the built library.
NON-GOALS:
- Session persistence of lengths and kinds, renderer replay (#1143), mode entry, UI, mappings, edits during capture, all-tracks edits, compatibility shims.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 2. History lengths in the Session, division recall and reopen (about 350 production lines)

- Native: `le_engine_export_history` and `le_engine_finalize_history` gain `lens[]`
  and `live_len` (`engine_session.c:236-294` as reshaped by Peel), strict per-slot
  capacity, `import_layer` no longer publishes `a_len`; `LE_CMD_COMMIT_SESSION`
  restores divisions through `le_restore_multiple_or_divisor`
  (`engine_process.c:3729-3737`); bindings regenerated.
- Dart seam: `AudioEngine.exportHistory/finalizeHistory` signatures, native, mock,
  fakes; `exportLayer` sized per entry.
- Session: schema bump, lineage validation in `SessionTrack.fromJson`
  (`session.dart:194-237`) and the mapping preflight (`session_mapping.dart:365-403`);
  capture and import carry the lengths; a division's `lengthFrames < base`
  round-trips.
- Reopen (#1158 merged): native tests in `test_engine_reopen.h` prove a retained
  track keeps LENGTH entries and that a length edit unapplied at loss drops only
  that track with the mask set; the pinned slot is freed with the material.
- Repository: `length_native_test.dart` gains the round trip: Double, First half,
  Undo, save, recall stopped, Redo re-applies and Undo restores with exact first
  samples; a saved division recalls as a division.

```success-criteria
GOAL: Length-edit history, including images of differing lengths and divisions, survives Session save and recall and a retained reopen with the same Undo/Redo sequence, with no new owner.
SUCCESS CRITERIA:
- The new schema round-trips kinds and per-image lengths strictly, rejects a bundle whose WAV lengths disagree with its lineage before side effects, and recall rebuilds the stacks so Undo and Redo reproduce the live engine's images and lengths. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session
- A saved Sync division reloads as that division and plays phase-locked; a retained reopen keeps LENGTH entries; an unapplied edit at loss drops only its track. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- The actual-native round trip restores the pre-edit image after recall with exact first samples. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB=<built lib> /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test
- Static gates stay clean. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
NON-GOALS:
- Renderer replay, UI, mappings, legacy schema decode, Free/Song session import (existing gap), a second history ledger.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3. Foot Multiply / Divide surface and mappings (about 650 production lines)

Section 3 complete: mode, model, actions, cubit part, view, the three
`TrackOperation` entries, labels EN/ES, LED projection and physical mask, Tracks
composition, four notices, pickers, themes, a11y arms. Tests:
`test/control/foot_length_dispatch_test.dart` (pattern
`foot_fade_dispatch_test.dart:1-60`: track pedals move the cursor on contact
against the current bank, Rec/Play doubles the cursor track, Undo and Clear halve
it, Bank pages, Exit returns to Tracks keeping lengths, an unavailable track is
inert without a notice, `modeMismatch`/`capacity`/`notReady` show their own notice
once per visit), `test/control/foot_length_projection_test.dart` (LED red on the
cursor only), `test/looper/view/foot_length_view_test.dart` with goldens like
`test/screenshots/goldens/foot_fade_*.png`, and `track_column` tests for the bars
figure after a Double. Selected and fixed actions exercised through the real
Custom, CTRL and MIDI ingress; all-tracks refused by the model. The journey of
`accepted-behavior.md:591` (Record, overdub passes, Divide, Peel, Undo/Redo) runs
as a repository sequence test against the fake engine and as the actual-native case.

```success-criteria
GOAL: The accepted Multiply / Divide surface edits the selected track by foot or assignment with no chooser, reports incompatible lengths, capacity and busy states distinctly, and never exposes a half-wired action.
SUCCESS CRITERIA:
- Track pedals select on contact against the current bank; Rec/Play, Undo and Clear apply Double, First half and Last half to the cursor; Bank pages; Exit returns to Tracks; refusals show the matching notice once. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- The cursor LED and overview are truthful; the bars figure follows the new length; goldens match in English and Spanish. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Multiply, Divide first half and Divide last half reach the same adapter from pedal, CTRL and MIDI ingress for selected and fixed scopes; all-tracks is not offered. | verify: /Users/Tomas/development/flutter/bin/flutter test
- Static gates and the whole app suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- Physical footswitch, LED and listening proof on the appliance: Double and both halves while playing and stopped, on a Sync division, a refused primary edit, Undo and Redo of an edit, and the §591 journey. | verify: manual appliance session per docs/PROGRESS.md hardware evidence rules.
NON-GOALS:
- Hold gestures, a second selection, new owners, native changes beyond label plumbing.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

## 6. Decisions taken under the standing rules

1. The edit, and Undo/Redo of it, apply on the audio thread through
   `LE_CMD_SET_LENGTH` with a receipt and an event; the control thread builds the
   image and files history at the event. Rule 2: the buffer, length and multiple
   change in one drain, never a torn frame. The audio thread's `a_live` store is
   the documented exception, fenced by `length_pending`.
2. Compatibility is `le_mode_span_fits` on the current base, plus two rules: the
   sole content track re-clocks the rig (nothing else exists to alter), and a
   crowned Sync/Band primary with dependents is refused. Rules 3 and 4: one span
   rule shared with mode switches and the history gate.
3. Odd lengths halve to `ceil(L/2)` with a shared middle frame rather than refusing.
   Rule 2: a freely recorded loop is odd half the time.
4. Both halves get the equal-gain seam fold with the true continuation, through
   the one fold body also used at finalize; Double needs none. Rule 4.
5. Sparse material is copied in place; no trimming or re-anchoring. §2.7, rule 3.
6. Playhead maps to the same phase of the kept region; a Once relaunch offset is
   re-originated, Reverse direction preserved. Rule 1 for the common zero-offset
   path, which is byte-identical in segment math.
7. Refused while writing, during the drain, with any arm, launch or pending state
   or clock command, and by the callback during the trailing seam window; never
   queued. Rules 2 and 5: an arm firing into a resized shadow would write out of
   bounds; every refusal is a notice.
8. Divide keeps the full image as its undo entry in place (no copy) and shrinks it
   to its quantized size; Double requires `2L` within the cap, else
   `LE_ERR_CAPACITY`. Rule 2.
9. Pool eviction may evict LENGTH entries; lineage stays consistent because
   eviction is bottom-up. Rule 2.
10. Per-image lengths are exported and persisted; the commit handler restores
    divisions. Rule 3 (existing Sessions export identically) and the B5c gap closed
    once rather than worked around in Dart (rule 4).
11. The §1143 fact carries slot, length and a staged image id in the Clear
    restoration's identity namespace; no renderer change here. Rule 4.
12. The surface uses the shared cursor as "one selected track", Rec/Play as Double,
    Undo and Clear as the halves, no holds, cursor LED red; three assignable
    operations plus the mode; all-tracks excluded. Rules 3 and 4.
13. Refusal notices are distinct for incompatible, capacity and busy. Rule 3.
14. Not an owned setting family (#1159); only the `TrackOperation` switch arms.
    Rule 4.

Genuine product-direction questions, flagged separately (defaults above stand
until the owner says otherwise):

- Pedal assignment inside the mode: Rec/Play as Double (planned) versus keeping
  Rec/Play as transport and placing Double on a hold of Undo or Clear.
- Should a sole track's halving re-clock the rig (bars halve at the same tempo,
  planned) or be refused like a track with siblings?
- Should a crowned Sync/Band primary with dependents be allowed to Double by
  re-clocking everyone (which changes every sibling's multiple), or stay refused?
- Should an odd-length halving be refused instead of sharing the middle frame?

## Collisions and sequencing

- #1164 Peel (PR #1166): claims kinds 2-3, fact 325, `le_peel_depth`,
  `Track.layers`, `le_engine_finalize_history`/`export_history` and
  `SessionLane.history`. Part 1 lands after Peel Part 1 and takes kind 4 and fact
  326; Part 2 lands after Peel Part 2 and extends its signatures. If Peel is
  reordered, Part 1 adds the kind and the blocking rule itself and Peel rebases.
- #1162 Reverse (PR #1163): `le_request_admit`, `le_engine_read_request_result`,
  `RequestAdmission`, command 83, fact 324, the direction origin helper. Whichever
  lands first owns the factoring; the other rebases.
- #1161 (`track_select_slot`) and #1158 (`le_engine_reset_material`, reopen drop
  rule): Part 1 lands after both; Part 2 adds the reopen tests.
- #1143 (history replay): the fact and staged image are designed for it.
- #1159 (settings owner): only the `TrackOperation` switch arms.
- Review ceiling per part: 700 production lines; generated bindings, tests and
  docs counted separately. Stop for review on any control-thread `a_live` swap of
  a playing track, a second seam law, a re-clock that touches a sibling, a new
  Dart owner or a renderer change.
