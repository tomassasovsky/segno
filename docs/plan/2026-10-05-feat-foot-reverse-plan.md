# Foot Reverse: per-track direction toggle at the current position

<!-- cspell:ignore lbuf wdub -->

Status: plan for owner review (merging this plan approves its direction); implementation not started.
Tracking: #1162 (parent #1026, M4 operations), `autonomy:merge-gate`.
Source baseline: `origin/claude/fade-duration-targets-1148` (PR #1156),
`c9b420d41cd7312f66ea5f15b0e4ed096d4a87f4`. Precedent: Foot Fade
([plan](2026-10-04-feat-foot-fade-plan.md), parts [1](2026-10-04-feat-foot-fade-part-1-plan.md),
[2](2026-10-04-feat-foot-fade-part-2-plan.md), [3](2026-10-04-feat-foot-fade-part-3-plan.md);
[duration settings](2026-10-05-feat-fade-duration-settings-plan.md),
[Session levels](2026-10-05-feat-session-fade-levels-plan.md),
[Clear history](2026-10-05-feat-fade-clear-history-plan.md)).

## Accepted behaviour

- `docs/handoff/segno-app/accepted-behavior.md:301`: "Each track pedal immediately
  toggles direction at its current position. Speed/pitch stay unchanged; stopped
  stays stopped. LED shows reverse; a small normal-Tracks marker remains after Exit."
- `:145-146`: Sync/Band capture follows the primary cycle "independent of that
  track's audible Speed, Reverse, Once or Follow setting".
- `:418-419`: New Loop "resets track performance transforms such as
  mute/fade/reverse/transpose/global Speed".
- `:160-166` (§2.10): the audio-edit history holds recording, overdub passes,
  length edits, Peel and Clear; "Mixer/FX configuration changes stay outside this
  history". Reverse is a performance transform, not an audio edit.
- `docs/handoff/segno-app/implementation-map.md:39`: Reverse has no named engine
  entry point; "establish each operation's native contract rather than treating a
  UI mode as audio implementation". `:51`: one complete native operation at a time.
- `docs/design/2026-09-10-whole-track-pre-render.md:155-158`: Speed/Reverse do not
  exist in the engine; the accepted direction for Speed is to stream from originals.

## What the engine does today (file:line)

- The mixer reads every lane at one shared coordinate: `loopsample =
  lbuf[seg_base[t] + trk_pos[t]]` (`engine_process.c:5593`). `seg_base` is the
  multiple's segment (`:5312-5323`), `trk_pos` the master phase, overridden per
  track for Free/Song (`free_track_positions_frame`, `:5088-5097`) and Sync
  divisions (`sync_division_positions_frame`, `:5142-5158`).
- A per-track read origin already exists: `le_track.playback_offset`
  (`engine_private.h:1258`), consumed by `le_shared_track_position`
  (`engine_process.c:123-134`) and re-applied to the `(seg_base, trk_pos)` pair for
  PLAYING/OVERDUBBING tracks at `:5353-5361` so "live/cached PCM, metering and
  overdub writes all use the same shifted position". It is set only by Once's
  relaunch (`le_restart_once`, `:138-149`), reset by `le_reset_track_playback`
  (`:114-119`), by the transport hold (`:4480-4484`) and by configure
  (`engine.c:482`). In Free/Song it is never read (`:124-126` return 0 when
  `clock.length <= 0`).
- Per-block publication of the track playhead: `trk_play_pos[t] = seg_base + trk_pos`
  (`:5365-5368`) -> `a_play_pos` (`:6419-6422`) -> `le_track_snapshot.position_frames`
  (`segno_engine_api.h:903`).
- Loop-top edges: whole-track print engages at `trk_rp == 0` (`:5522-5535`), lane
  print at `rp == 0` (`:5673-5680`), Once lap end at `le_shared_track_position == 0`
  (`:4295-4299`), Free/Song Once at the private clock wrap (`:4243-4251`).
- The seam crossfade is baked into PCM at finalize (`le_seam_fold`, `:995-1019`;
  `seam_xfade_frames = sr/100`, `:971-974`), so the wrap `len-1 -> 0` is
  continuous in both read directions. No runtime seam work exists.
- Overdub writes use a forward, latency-compensated head (`wdub`, `:5484`) and a
  forward-contiguous per-pass shadow trajectory (`dub_*`, `engine_private.h:
  929-955`; drain walk `engine_process.c:1600-1640`).
- Fade is the precedent for a callback-owned per-track transform with receipts:
  `le_fade` (`engine_fade.h`), fields on `le_track` (`engine_private.h:836-842`),
  command `LE_CMD_FADE` (`segno_engine_api.h:515`), admission + receipt table
  `le_fade_admit` / `fade_receipts[LE_RING_CAPACITY]` (`engine_commands.c:2281-2306`,
  `engine_private.h:1640-1644`), callback application (`engine_process.c:2990-3012`),
  snapshot read (`engine_snapshot.c:49-72`), perf fact `LE_PLOG_FADE = 321`
  (`perf_log_ring.h:141`) replayed in `perf_render.c:1343-1345,1388`, resets at
  every material transition (`le_fade_reset` at `engine_process.c:1318, 1751, 1768,
  1857, 2135`; `LE_CMD_RESET_FADE` at `engine_session.c:136,292`).
- Dart seam: `AudioEngine.toggleFade/installFade/readFadeResult`
  (`packages/segno_engine/lib/src/audio_engine.dart:206-212`), repository receipt
  observation `_requestFade` (`looper_repository.dart:2134-2183`), `Track.fade`
  (`models/track.dart:81`), projection `fade: s.tracks[i].fade`
  (`looper_repository.dart:2419`), Session `SessionTrack.fadeAmount` (schema 11,
  `session.dart:189-197,249`), captured at `session_repository.dart:710`, installed
  at import before commit (`looper_repository.dart:4414-4449`).
- Surface precedent: `InteractionMode.fade` (`lib/looper/model/interaction_mode.dart:46`),
  `FootFadeProjection.pedalRoles` (`lib/control/model/foot_fade.dart:154-193`),
  `_FootFadeControl` part (`lib/control/cubit/control_foot_fade.dart`), stateless
  `FootFadeActions` (`lib/control/foot_fade_actions.dart`), `FootFadeView` over
  `PerformancePedal` (`lib/looper/view/foot_fade_view.dart`,
  `performance_pedal.dart:14-30`), LED (`lib/control/control_projection.dart:97-101,
  255-258`), `TrackOperation.fade` (`lib/control/binding/control_action.dart:166`),
  Tracks composition (`lib/looper/view/tracks_view.dart:209-212`), failure toast
  (`:139-146`), FX marker in the track meta row (`track_column.dart:106-108, 593-700`).

## 1. Native contract

### 1.1 State and the read coordinate

Add to `le_track` next to `playback_offset` (`engine_private.h:1258`):

- `int32_t reversed;` audio-thread-owned direction (0 forward, 1 reversed).
- `int32_t turn_left, turn_reversed, turn_offset;` the turn crossfade: frames left,
  and the pre-turn direction/origin so the old head can be read for those frames.
- `_Atomic int32_t a_reversed;` published direction for snapshots (like `a_one_shot`,
  `engine_private.h:1235`; one int needs no sequence lock).

`playback_offset` is reused as the read origin in both directions; no second origin
field. The read coordinate is one pure helper in a new C++17-clean header
`packages/segno_engine/src/core/engine_direction.h` (same role as `engine_fade.h`:
shared by the callback and the offline renderer; positional initializers only,
no `_Atomic`, no designated initializers; see the PROGRESS C++ blast-radius note at
`docs/PROGRESS.md:437-466`):

```c
/* Read index for shared/private clock position `pos` on a track of `len` frames. */
static inline int32_t le_direction_index(int reversed, int32_t origin, int64_t pos, int32_t len);
  /* forward: (pos + origin) mod len; reversed: (origin - pos) mod len */
/* Re-origins so the read index equals `index` at `pos` under `reversed`. */
static inline int32_t le_direction_origin(int reversed, int32_t index, int64_t pos, int32_t len);
/* First index of a lap: 0 forward, len-1 reversed. */
static inline int32_t le_direction_lap_start(int reversed, int32_t len);
/* Equal-gain weight of the new head during a turn of F frames, i frames in. */
static inline float le_direction_turn_mix(int32_t i, int32_t F);
```

Toggle at position `pos`: `cur = index(reversed, offset, pos, len)`; save
`turn_* = {F, reversed, offset}`; `reversed ^= 1`; `offset = origin(reversed, cur,
pos, len)`. The read index is continuous at the turn, which is the accepted "at its
current position". Toggling back does not re-lock phase; the phase offset persists
exactly as Once's relaunch offset does today, until the shared transport hold
(`engine_process.c:4480-4484`) or `le_reset_track_playback` resets it.

Refactor `le_shared_track_position` (`:123-134`) into `le_track_base_position(e, t,
&len)` (shared clock + segment, or `free_clock.position`/`free_clock.length` in
Free/Song) and `le_track_read_index(e, t)` = `le_direction_index(t->reversed,
t->playback_offset, base, len)`. Honouring `playback_offset` in Free/Song is
behaviour-neutral: nothing sets it there today (`le_restart_once` resets the private
clock instead, `:145-147`).

### 1.2 Mixer application

Replace the block at `engine_process.c:5353-5361` with: for every PLAYING or
OVERDUBBING track with `len > 0` and (`reversed || playback_offset != 0`), compute
`idx = le_track_read_index(e, t)` and rewrite the pair `seg_base[t] = idx - idx %
trk_len[t]; trk_pos[t] = idx % trk_len[t]`. Forward tracks with zero offset keep the
byte-identical master path. Every downstream consumer then follows the direction
without further edits: the dry read (`:5593`), lane/track print reads (`:5673-5680,
5522`), metering, `trk_play_pos` (`:5367`) and so `position_frames`.

Turn crossfade: while `turn_left > 0`, also compute `old = le_direction_index(turn_
reversed, turn_offset, base, len)` and read `loopsample = lbuf[idx]*x + lbuf[old]*(1-x)`
with `x = le_direction_turn_mix(F - turn_left, F)`, `F = seam_xfade_frames(e)`
(~10 ms, `:971-974`), decremented once per frame per track after the lane loop
(beside the seam countdown, `:5841-5857`). Equal-gain, like `le_seam_fold`
(`:995-1004`): the two reads are the same material. Loops shorter than `2*F` snap
without a crossfade, mirroring the punch-fade rule (`:5397-5405`). A toggle back to
the pre-turn direction while `turn_left > 0` cancels the turn: restore
`playback_offset = turn_offset`, set `turn_left = 0`, and log the restored head's
index with no turn. The old head never stopped advancing, so it plays on alone. Every
park of the origin (transport hold, `le_reset_track_playback`, Session commit) also
zeroes `turn_left`.

Caches and Reverse: a reversed track never engages a printed Pre render, and a
toggle clears `a_cache_active` on every lane and `a_track_cache_active`
(`:5525, 5676`; audio thread is their writer) so the live chains take over through
the existing settled-bypass re-enable path (`:5534-5535` comment, `[B7]`). Add
`!tr->reversed` to both engage conditions and replace `== 0` with
`le_direction_lap_start` so a forward track with an offset still engages at its own
lap boundary. Reversing a loop reverses the recording, not its effects: the dry
PCM is read backward and the Pre/Post chains run forward, and the audible result
does not depend on whether a print happened to be engaged.

Other direction-aware edges:

- `le_shared_clock_one_shots` (`:4295`): lap end when `le_track_read_index == lap_start`
  and `sounding_frames >= len`, unchanged otherwise. `advance_track_clock_frame`
  (`:4243-4251`): stop on the read index reaching lap start rather than the private
  clock wrap (identical for a forward track with zero offset).
- `le_restart_once` (`:138-149`): `playback_offset = le_direction_origin(reversed,
  lap_start, base, len)` so a relaunch after automatic end starts at the lap start in
  either direction; drop the Free-mode `free_clock.position = 0` special case in
  favour of the same origin rule.
- Perf restoration phase tracking (`:5371-5389`): `perf_restore_next_pos` must step
  `-1 mod len` while reversed, or `LE_PLOG_RESTORE_TRANSPORT` floods the log every frame.
- `a_play_pos`/`trk_play_pos` need no change (they publish the pair).

### 1.3 Command, receipts, snapshot

- `LE_CMD_REVERSE = 83` (`segno_engine_api.h:515-516` enum tail), payload arm
  `struct { int32_t channel, slot, install, target; } reverse;` in `le_command`
  (`lockfree_ring.h:99-103` beside `fade`). `install = 0` toggles; `install = 1`
  sets `target` (Session recall, Part 2). Checked, never raw-posted: add it to the
  `le_push` refusal list (`engine.c:1299-1300`).
- Public API next to Fade (`segno_engine_api.h:3091-3103`):
  `le_engine_toggle_reverse(engine, channel, uint64_t* request)`,
  `le_engine_install_reverse(engine, channel, int32_t reversed, uint64_t* request)`,
  and rename `le_engine_read_fade_result` to `le_engine_read_request_result`
  (same body, `engine_commands.c:2324-2334`). The receipt table is already
  command-agnostic (request id, posting ticket, result); Reverse reuses it rather
  than growing a twin. Factor `le_fade_admit`'s slot/receipt bookkeeping
  (`:2290-2306`) into `le_request_admit(e, cmd, slot_out)` used by both.
- Control-side admission (`le_engine_toggle_reverse`): `LE_ERR_INVALID` for a bad
  channel, or when `le_effective_state` (`engine_core.h:99-107`) is EMPTY,
  RECORDING or OVERDUBBING; `LE_ERR_NOT_READY` while the track has a pending arm or
  launch (`a_pending`, `pending_record`, `engine->armed[channel]`,
  `a_pending_launch`) because that arm may fire into OVERDUBBING before the toggle
  lands; `LE_ERR_NOT_RUNNING` when not configured; `LE_ERR_NOT_READY` when no receipt
  slot is free (as Fade, `:2292`).
- Callback application (new `case LE_CMD_REVERSE` beside `:2990`): accepted only
  when `a_len > 0`, state is PLAYING or STOPPED, `od_gain == 0` (no punch tail is
  still writing, `:5461-5463`) and `xfade_capture == 0`. Accepted: toggle/install
  per 1.1, clear cache engagement, publish `a_reversed`, push the perf fact; write
  the receipt result either way. A `seam_capture > 0` window is allowed: the trailing
  fold writes at `seam_w`, independent of the read pair (`:5479-5481`).
- `le_effective_reversed(t)` in `engine_core.h` beside `le_effective_state`:
  `a_reversed ^ (parity of toggle commands posted and not yet published)`, tracked
  by a control-only counter and the receipt tickets. Used by the Record guard below
  and by the snapshot's `pending` reasoning; the callback remains the authority.
- Snapshot: trailing `int32_t reversed;` on `le_track_snapshot`
  (`segno_engine_api.h:932`), filled in `le_fill_track_snapshot`
  (`engine_snapshot.c:109-123`) from `a_reversed`.
- Material resets: fold `le_fade_reset` and the new direction reset into one
  `le_transform_reset(e, t, frame)` at every existing site (`engine_process.c:1318,
  1751, 1768, 1857, 2135`, restore-clear `:2891-2900` keeps Fade's restored amount
  and sets direction forward), plus `LE_CMD_RESET_FADE` (`:2987`) which becomes the
  import-time transform reset (rename to `LE_CMD_RESET_TRANSFORMS`, value 82
  unchanged). Direction reset also zeroes `playback_offset` and the turn window and
  publishes `a_reversed = 0` with a perf fact. Configure: add the fields to the
  per-track init (`engine.c:417-426`), in the material column once #1158 lands.

### 1.4 Multi-lane, multiples, Sync divisions, Free/Song

- Lanes share the track transport; the pair rewrite is per track, so every lane
  reads the same mirrored index (`:5593` loops lanes over one pair).
- Multiples: `len = a_len = k * base`, base position includes the segment
  (`:127-132`), so a 2x track mirrors across both segments.
- Sync divisions: `len = base / n`, base position `pos % len` (`:5156`); a division
  reversed still completes exactly `n` laps per primary cycle and its lap start
  (`len-1`) coincides with the primary's loop top while the origin is 0.
- Free/Song: base position is the private clock; the clock keeps ticking forward,
  the read index runs backward.

### 1.5 Interaction with capture, Fade, Once, Speed

- Sync/Band capture of a new track is untouched: recording writes at `record_pos`
  on the musical clock (`:5466-5476`) and never reads the pair; the primary's
  Reverse cannot move the capture grid.
- Overdubbing into a reversed track is refused. Decision: follow the Boss RC-300/
  RC-505 rule that overdub is unavailable while Reverse is on (established-product
  pattern, AGENTS.md). The write head, the latency compensation, the per-pass shadow
  trajectory and the drain walk are forward-only (`:5484-5492, 1600-1640`); teaching
  them a reversed trajectory is a second capture engine for a rare gesture. Guards:
  `le_record_impl` (`engine_commands.c:1400-1470`, after `st` at `:1425`) returns a
  new `LE_ERR_REVERSED = -9` (`segno_engine_api.h:38-51`) for a punch-in on a track
  whose `le_effective_reversed` is set (RECORDING/OVERDUBBING presses and arm
  cancellations are unaffected); `handle_record`'s PLAYING/STOPPED branch
  (`engine_process.c:1799-1806`) drops a punch-in on a reversed track so a grid or
  sound arm that fires after the toggle cannot start writing. A count-in launch
  member with action Overdub on a reversed track is refused at launch admission the
  same way. Stop, Play, Mute, Fade, Clear, Undo/Redo stay available.
- Fade multiplies at the gain boundary (`:5721-5724`) and is independent of the read
  index; a reversed track fades normally and a fade keeps running through a toggle.
- Once: see 1.2; "finishes the current pass" means the read lap in either direction.
- Speed (future) owns a fractional read head streamed from originals; direction then
  becomes the sign of its increment and `le_direction_index` generalises to it. Do
  not pre-build a fractional head here.

### 1.6 Performance log and offline render

- `LE_PLOG_REVERSE = 324` (`perf_log_ring.h:139-143`), payload
  `struct { int32_t channel, reversed, read_index, turn_frames; } reverse_log;`
  in both `le_command` and `le_log_command` (`perf_log_ring.h:195`), pushed at every
  accepted toggle/install and at every transform reset (like `le_fade_log`,
  `engine_process.c:175-179`). Add `LE_CMD_REVERSE` to the `le_log_extract` exclusion
  list (`perf_log_ring.h:206`) so only the primitive fact is logged. Bump the
  events.log version 5 to 6 (`perf_drain.c:803-813`).
- `perf_render.c` stem loop (`:1053-1062`): keep per-channel direction state from the
  facts; the dry index becomes `le_direction_index(reversed, anchor, f - fact_frame,
  len)` where `anchor` is the logged `read_index`, and the turn applies the same
  `le_direction_turn_mix` over the old head. The logged exact index also corrects
  the renderer's phase after a Once relaunch, a pre-existing approximation that is
  otherwise out of scope.

### 1.7 Click-free toggling

The value is continuous at the turn (same sample) but its slope flips, which clicks
on low material. The 10 ms equal-gain turn crossfade in 1.2 removes it at the cost of
one extra dry read per lane per frame for F frames. A toggle during a printed lap
falls back to live chains mid-lap; that cold-start bump is the already-documented
same-buffer fallback (`:5534-5535`), accepted.

## 2. History and Session semantics

- Undo: not undoable and no history entry. `accepted-behavior.md:160-166` lists the
  audio edits; Fade set the same precedent (parent plan "Fade/time edits are not
  audio-history steps"). Toggling never retires Redo.
- Material transitions: direction and origin reset to forward on Clear, Undo to
  empty, a new capture, Session import and configure (1.3). Undo of Clear restores
  the material forward; direction is not added to the Clear mailbox
  (`engine_private.h:807-808, 984-990`) or `LE_CMD_RESTORE_CLEAR`
  (`lockfree_ring.h:121-130`). Rule 5: the direction at the Clear boundary is
  performance intent of a different moment; the LED and the Tracks marker show the
  restored track forward, so nothing is silent. Fade's restoration exists because a
  faded-out track restored at unity is a level surprise.
- Session: `SessionTrack.reversed` (bool, required, schema 12 -> 13 after Peel
  takes 12; see "Part 2 as built",
  `session.dart:184-262`), captured at `session_repository.dart:710` from the same
  detached `EngineSnapshot` track as `fadeAmount`, carried through
  `session_mapping.dart:365-400` and `SessionRigTrack` (`session_rig.dart:72-86`),
  installed with `installReverse` after the Fade installs and before
  `commitSession` (`looper_repository.dart:4428-4458`); every receipt confirmed
  before publication, a refused install fails the load like Fade's. Mute and Fade
  are both saved, and a reversed track is part of the arrangement; recalling it
  forward would be a silent change of what the player saved. The origin is not
  saved: recall publishes STOPPED at the loop head (`LE_CMD_COMMIT_SESSION`), and a
  reversed track then starts from its lap start `len-1`. No legacy decode (AGENTS.md).
- New Loop: not implemented yet (no `newLoop` symbol in `lib` or the repositories).
  It inherits the reset because direction dies with the material on every path
  above; the plan adds no New Loop code.
- Reopen (#1158): direction is material. Add `reversed`/`a_reversed` to
  `le_engine_reset_material` beside `fade` (PR #1158 `engine.c` hunk, `tr->fade =
  ...` lines) so a same-rate retained reopen keeps a reversed track reversed; the
  settle's head park already runs `le_reset_track_playback` (zeroing
  `playback_offset`) and republishes, so the origin is parked and the relaunched
  track starts at its lap start. Dropped takes (`RECORDING`, `seam_capture > 0`)
  reset direction with the take. A pending Reverse receipt at loss is retired with
  the Fade receipts (`looper_repository.dart:869-878`, `engine.c:395-396`).
- #1159: Reverse is not an owned setting family. It is callback-owned per-track
  runtime with receipts, like the Fade toggle, with no durable key outside the
  Session image; it needs no `SettingsOwner`, flush or storage repair. The only
  shared surface is the `TrackOperation` dispatch switch (`control_cubit.dart:
  2905-2917`) that #1159 Part 3 intends to collapse; Part 3 here adds one arm there
  and rebases on whichever lands first.

## 3. Surface

- `InteractionMode.reverse` (`interaction_mode.dart:46`), token `reverse`, excluded
  from `bootDefaults` (`:56`); `toggleMode` returns to `record` from it (`control_
  cubit.dart:1645-1652`); `ModeAction` token `'reverse'` (`control_action.dart:
  344-349`); labels `actionModeReverse` (`control_action_labels.dart:77-78`).
- `lib/control/model/foot_reverse.dart`: `FootReverseAction {recordPlay, stop, exit,
  toggleTrack, nextBank}`, `FootReversePedal`, `FootReverseTrack {channel,
  recorded, busy, reversed}` with `recorded = hasContent` and `busy = isCapturing
  || pending`,
  `FootReverseProjection {bank, tracks}` and `pedalRoles`: track1-4 `toggleTrack`
  immediate (the spec says "immediately"), bank `nextBank`, recPlay/stop/mode as in
  Fade (`foot_fade.dart:154-193`), undo and clear inert (no accepted meaning; the FX
  mode precedent). No transient selection, so `ControlState` gains only
  `footReverseFailure` (`control_state.dart:23-24` pattern).
- `lib/control/foot_reverse_actions.dart`: stateless `toggle(channel)` over
  `LooperRepository.toggleReverse`. An empty track is refused as `invalid`
  without a notice (it has no direction to change); a recorded track that is
  writing or pending is refused as `notReady` with the toggle-failure notice,
  per decision 1. Neither posts. Shared by the surface and assigned actions
  (`foot_fade_actions.dart:51-63`).
- `lib/control/cubit/control_foot_reverse.dart` part: `_reverseEditable`,
  `_onReversePress`, `_dispatchReverseAction`, `_reportReverseFailure`, mirroring
  `control_foot_fade.dart`; public `footReversePressed/Released/Cancelled`,
  `activateFootReversePedal`, `toggleFootReverseTrack(slot)` beside `:2400-2433`;
  `_onPress` routing (`:2618-2625`); `recPlay`/`stop`/`trackPressed`/`_onPress
  recPlay` arms (`:1918-1924, 2046-2052, 2108-2118, 2672-2677`); projection refresh
  (`:1616-1630`, no selection to normalise, only `_surfaceVisit`).
- `TrackOperation.reverse('reverse')` (`control_action.dart:151-167`,
  `allowsAllTracks` true), label `actionOperationReverse`, dispatch arm at
  `control_cubit.dart:2914-2916` through `FootReverseActions.toggle`.
- LED (`control_projection.dart:85-110`): in `reverse` mode a track LED is blue when
  `track.hasContent && track.reversed`, off otherwise; physical mask (`:255-258`)
  generalised to `mode == fade || mode == reverse` for slot-less buttons; `PedalMode
  .custom` wire mapping (`:203-204`, `invariants.dart:157-158`); `pedal_plate.dart:
  625-626, 1051`; themes (`looper_theme.dart:129`, `surface_theme.dart:240`).
- `lib/looper/view/foot_reverse_view.dart`: `PerformancePedal` layout as the Fade
  view's front row and Bank, a title, and an eight-track overview cell showing
  name and `Forward`/`Reversed`/`Empty` (a busy recorded track keeps its real
  word, dimmed); selected bar lit on reversed tracks, Exit
  and Bank B (`foot_fade_view.dart:405-410`). Tracks composition
  (`tracks_view.dart:209-212`), failure toast (`:139-146`, `AppToastId.
  footReverseFailure`), a11y and switch arms in `track_column.dart:364-376,
  383-405`, `wave_track_row.dart:96, 111`, `tracks_commands.dart:122, 225, 313`.
- Normal-Tracks marker: a `_ReverseMarker` beside the FX marker in `_TrackMeta`
  (`track_column.dart:593-700`): `stageReverseMarker` ("REV"), laid out only
  while reversed (see "Part 3 as built"), a11y `a11yStageReversed`. It reads
  `track.reversed` from the repository projection, so it remains after Exit.
- Localization: English and Spanish strings for the mode, operation, pedal
  captions, overview words, marker and failure (`lib/l10n/arb/app_en.arb:5901-6001`
  pattern), generated with the existing l10n tooling.
- Record refusal: `EngineResult.reversed` (from `LE_ERR_REVERSED`) surfaces through
  the existing record-start refusal notice path with the copy "Overdub is unavailable
  while the track is reversed"; the Reverse surface keeps Rec/Play on the normal
  cursor and shows that notice when the cursor track is reversed.

## 4. Parts

Each part is independently mergeable, keeps the public app working, and exposes no
unfinished destination. Parts 1 and 2 are unadvertised (no mode entry); Part 3
exposes the complete journey. Sequence Part 1 after #1158 and #1161 merge into the
stack's base: #1158 moves the per-track configure init that Part 1 extends, and
#1161 edits `le_record_impl`, where Part 1 adds the punch-in guard.

### Part 1. Native direction and engine seam (about 500 production lines)

Native (`engine_private.h`, `engine_direction.h`, `engine_core.h`,
`engine_process.c`, `engine_commands.c`, `engine.c`, `engine_snapshot.c`,
`engine_session.c`, `segno_engine_api.h`, `lockfree_ring.h`, `perf_log_ring.h`,
`perf_drain.c`, `perf_render.c`): sections 1.1-1.7 complete, including the receipt
reader rename, `LE_ERR_REVERSED`, the transform-reset consolidation and the
renderer. Dart seam: `AudioEngine.toggleReverse/installReverse/readRequestResult`
(`audio_engine.dart:206-212`), `TrackSnapshot.reversed` (`engine_snapshot.dart:
600-710`), `NativeAudioEngine` (`native_audio_engine.dart:739-785`),
`MockAudioEngine` (`mock_audio_engine.dart:596-610`), the four fakes
(`test/helpers/fake_audio_engine.dart`, `packages/looper_repository/test/helpers/
fake_audio_engine.dart`, `packages/performance_repository/test/helpers/
fake_performance_engine.dart`, `packages/session_repository/test/helpers/
fake_session_engine.dart`), `EngineResult.reversed`, regenerated and formatted
bindings (`ffigen.yaml`), `LooperRepository.toggleReverse/installReverse` through
`_requestFade`'s observation (renamed `_requestReceipt`, `looper_repository.dart:
2134-2183`), `Track.reversed` (`models/track.dart`) and its projection (`:2419`).

Tests (`src/test/test_engine_reverse.h`, included like `test_engine_fade.h` at
`test_engine_core.c:32969`; literal PCM through `le_engine_process`):
ramp PCM `pcm[i] = i` so the read index is the sample; toggle at index 37 yields
37, 36, 35 after the turn window and the equal-gain mix inside it at 44.1/48 kHz
and blocks 1/127/512; wrap `0 -> len-1`; toggle back continues from the current
index and the resulting offset persists until a transport hold re-locks it;
STOPPED toggle leaves silence, Play starts reversed from the re-entry coordinate;
multiple 2 across both segments; Sync division 2 and 4 against a primary;
Free/Song private clock; Once stops at lap start in both directions and relaunches
at `len-1` when reversed; two lanes read the same index; Fade continues through a
toggle; punch-in refused with `LE_ERR_REVERSED` and dropped on the callback when
armed before the toggle; toggle refused while RECORDING/OVERDUBBING, during the
punch tail, and while an arm is pending; receipts for rapid double toggles; Clear,
undo-to-empty, new capture and import reset direction and log the fact; printed
lap disengages on toggle and never re-engages while reversed, with live/cached
parity preserved for forward tracks; the renderer reproduces the live reversed
stem sample-exactly including the turn; `a_play_pos` runs backward. One
actual-native repository case in a new `packages/looper_repository/test/
reverse_native_test.dart` (fixture of `fade_native_test.dart:13-45`) confirms the
receipt, `Track.reversed` and the record refusal.

```success-criteria
GOAL: A checked native Reverse toggle reads recorded material backward from the current position, click-free, across modes and caches, with confirmed receipts and exact offline replay, while the public app is unchanged.
SUCCESS CRITERIA:
- Literal PCM proves continuity at the turn, the equal-gain turn window, wrap, multiples, divisions, Free/Song, Once, STOPPED toggles and two-lane parity at two rates and three block sizes. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Refusals (writing, pending arm, empty) and punch-in rejection return the specified codes, leave PCM and history untouched and never write on a reversed pair; material resets publish forward. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The offline stem matches the live reversed output sample-exactly, events.log carries version 6, and sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings, symbol parity and the Dart seam are complete; the repository confirms a toggle and projects direction. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- The C++17 shim repro from docs/PROGRESS.md compiles with the new header and the ELF symbol check passes on CI. | verify: manual run the PROGRESS shim repro and packages/segno_engine/tool/check_ffi_symbols.sh on the built library.
NON-GOALS:
- Reversed overdubbing, Speed, Session/reopen persistence, mode entry, UI, mappings or compatibility shims.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 2. Session, reopen and lifetime composition (about 300 production lines)

- `SessionTrack.reversed`, schema 13 (Peel Part 2 takes 12), strict decode
  (`session.dart:184-262`);
  capture at `session_repository.dart:710`; `SessionRigTrack.reversed`
  (`session_rig.dart:72-86`); mapping and preflight (`session_mapping.dart:365-400`);
  install after Fade installs and before commit (`looper_repository.dart:4428-4458`)
  with receipts confirmed, cleanup on refusal, Session revision rechecked.
- Reopen (#1158 merged): `reversed` in `le_engine_reset_material`; a native test in
  `test_engine_reopen.h` proves a reversed track reopens reversed, STOPPED, and plays
  from `len-1`; receipts retired with the Fade ones.
- Repository: `Track.reversed` consumers for record admission messaging
  (`EngineResult.reversed` notice through the existing record refusal path) and
  the Clear/undo/import lifetime tests: undo-to-empty, Redo from empty, Clear and
  Clear Undo read forward; Session round trip of two tracks (one reversed) recalls
  stopped with exact first samples `pcm[len-1]` on Play.

```success-criteria
GOAL: Direction survives Session save and recall and a retained reopen, resets with material, and a refused overdub on a reversed track is reported, with no new owner.
SUCCESS CRITERIA:
- Schema 12 round-trips strictly, rejects malformed data before side effects, and recall installs direction before the stopped commit with every receipt confirmed. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session
- A reversed track reopens reversed and stopped and plays from its lap start; a dropped take comes back forward. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- Clear, Undo to empty, Redo from empty and Clear Undo publish forward; the record refusal reaches the existing notice. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB=<built lib> /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test
- Static gates stay clean. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
NON-GOALS:
- Origin persistence, Clear-history direction restoration, UI, mappings, legacy schema decode.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

#### Part 2 as built

Status: built (branch `claude/reverse-1162-p2`, on the trunk `68ed3f957`).

- Session schema 13: `SessionTrack.reversed` is a required bool, decoded
  strictly (missing or non-bool is a `FormatException`), serialized and part
  of value identity. Peel Part 2 (#1194) takes 12; whichever lands second
  takes the next free number.
- Capture: `SessionRepository` saves `TrackSnapshot.reversed` from the same
  detached snapshot as `fadeAmount`. `rigFromBundle` carries it to
  `SessionRigTrack.reversed`.
- Recall: `LooperRepository.applySession` installs direction with
  `installReverse` after the Fade installs and before `commitSession`, only
  for reversed tracks (the imported material is already forward). Each
  receipt is awaited, a refusal fails the load like Fade's, and the Session
  revision is rechecked around it. The commit check also requires every
  track's published direction to match the rig.
- Reopen: direction is already material in `le_engine_reset_material`
  (Part 1); a native test now proves a retained reopen keeps a reversed
  track reversed and STOPPED, and Play reads it from `len-1`. Its second
  half reverses a later take inside its trailing seam fold, which the reopen
  drops: the track comes back EMPTY and forward (it fails against a drop
  path that keeps the direction).
- `SessionRigTrack.reversed` is required, like `fadeAmount`: a rig builder
  that forgets direction does not compile.
- Tests: schema round trip and strict decode; capture; mapping; an
  actual-native recall of a reversed and a forward track (stopped, then
  Play reads `pcm[len-1]` downward and the forward track from 0); an
  actual-native lifetime test (undo to empty, redo from empty, Clear and
  Clear Undo all read forward). Each fails with its fix reverted (the
  lifetime test against a native mutation of the direction reset).
- Recall failures (review lows), against the actual native engine: a
  refused install clears the partially installed vector and the next loads
  read forward; an engine stop during the install, a load superseded during
  it, and a timed-out receipt all leave the next material forward; and a
  track whose OK receipt still publishes forward fails the commit check
  (the test fails with the check's direction clause removed). The fake
  engine in `looper_repository` now accepts `installReverse` and publishes
  the direction at commit, so fake-engine recall tests can carry a
  reversed track. The fence after the install receipt is not killed on its
  own: the commit wait's own fence catches the same superseded and stopped
  loads in these tests.
- Not here: the record-refusal notice for a reversed track is
  `LooperRepository.overdubRefusals`, built with Part 3 (#1162 P3).

### Part 3. Foot Reverse surface, mappings and marker (about 600 production lines)

Section 3 complete: mode, model, actions, cubit part, view, `TrackOperation.reverse`,
labels EN/ES, LED projection and physical mask, Tracks composition, toast, marker,
pickers, themes, a11y arms. Tests: `test/control/foot_reverse_dispatch_test.dart`
(pattern `foot_fade_dispatch_test.dart:1-60`: immediate contact dispatch, bank
following, stale release, refusal toast once per visit, Exit keeps direction,
Rec/Play on a reversed cursor reports the refusal), `test/control/foot_reverse_
projection_test.dart` (LED truthfulness: lit only on recorded reversed tracks),
`test/looper/view/foot_reverse_view_test.dart` with goldens like
`test/screenshots/goldens/foot_fade_*.png`, and `track_column` tests for the
marker's presence after Exit and width-holding while forward. Custom/CTRL/MIDI
selected/fixed/all actions exercised through the real ingress.

```success-criteria
GOAL: The accepted Reverse surface toggles direction immediately by foot or assignment, shows truthful LEDs and a persistent normal-Tracks marker, and never exposes a half-wired action.
SUCCESS CRITERIA:
- Track pedals toggle on contact against the current bank, Bank pages, Exit returns to Tracks with directions kept, Undo/Clear are inert, and a refused toggle shows one notice. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- LED and marker light only for recorded reversed tracks; the marker remains after Exit, a forward meta row is the pen's row, and REV never overlaps the counts (en/es, 128 bars, 12 layers); goldens match in English and Spanish. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Selected, fixed and all-tracks Reverse actions reach the same adapter from pedal, CTRL and MIDI ingress. | verify: /Users/Tomas/development/flutter/bin/flutter test
- Static gates and the whole app suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- Physical footswitch, LED and listening proof on the appliance: toggle during playback, while stopped, on a division, with a running fade, and overdub refusal. | verify: manual appliance session per docs/PROGRESS.md hardware evidence rules.
NON-GOALS:
- Reversed overdubbing, Speed, hold gestures, new owners, native changes beyond label plumbing.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

#### Part 3 as built

Status: built (branch `claude/reverse-1162-p3`, rebased on the trunk
`31aab2fdc`, which carries #1189's owned-value dispatch; the Reverse arm is
one case in its `TrackOperation` switch).

- Mode and vocabulary: `InteractionMode.reverse` (not a boot default; the
  mode chip and `toggleMode` return to Tracks), `ModeAction` token
  `reverse`, `TrackOperation.reverse` (`allowsAllTracks` true; an all-tracks
  stomp toggles every recorded track in parallel, like Fade), labels in
  English and Spanish.
- Model and actions: `lib/control/model/foot_reverse.dart` (role table:
  every role fires on contact, Undo and Clear are `none`; a track is
  `recorded` when it has content and `busy` while it captures or has an arm
  or launch pending) and the stateless `FootReverseActions.toggle`, shared
  by the surface and every assigned action.
- Busy tracks (review Medium 2, decision 1): a recorded track that is
  overdubbing or pending shows its real direction word and chevron, dimmed,
  in the overview and on its pedal, and its pedal still takes the stomp.
  The stomp is refused before posting (`notReady`) and shows the
  toggle-failure notice once. Only an empty track is silent. Section 3 used
  to say every unavailable track was refused "without a notice", which
  contradicted decision 1; section 3 now follows decision 1.
- `trackPressed` in Reverse mode is inert, like Fade: no production path
  reaches it (track pedals route through `_onReversePress`, and the Tracks
  columns are replaced by the Reverse view), so a future on-screen caller
  cannot turn a track around by accident.
- Cubit part `control_foot_reverse.dart`: contact dispatch, Exit, Bank,
  Stop, Rec/Play on the normal cursor, and one toggle-refusal report per
  visit (`ControlState.footReverseFailure`).
- Overdub refusal, every mode: `LooperRepository.record` reports an
  `EngineResult.reversed` refusal on `overdubRefusals`, and the app shows it
  with the existing record-refusal toast, titled "Overdub is unavailable
  while the track is reversed". Pedal, MIDI, External and on-screen presses
  all pass through `record`, so Tracks and Reverse report the same way.
- LED: blue for a recorded reversed track, off otherwise. The physical mask
  treats slot-less pedals on Fade and Reverse alike (lit only for an
  accepted contact). The wire mode is `PedalMode.custom`.
- `FootReverseView` mirrors the Fade view (same canvas, positions and
  `PerformancePedal`), which gained an optional detail glyph and a
  highlighted detail for the direction line.
- Tracks marker (review Medium 1): "REV" takes a real slot before the FX
  marker, but only while the track plays reversed. A forward meta row is
  the pen's row exactly (the forward Tracks goldens are byte-identical to
  the trunk's); reversing a track reflows that track's own row so REV
  always has room. The earlier version painted REV into the gap without
  layout space, and it overlapped the layers figure in Spanish and with
  long counts. The row also has a 12 px spacing floor: with room to spare
  `spaceBetween` lays it out as before, and when it is tight its parts
  never touch. Tests: an Ahem geometry test for en and es at 128 bars and
  12 layers, and real-font screenshot tests for en and es at 16 and 128
  bars, asserting REV clears the layers figure and the FX marker. The
  marker reads `Track.hasContent && Track.reversed`; the meta row's
  screen-reader label adds "Track plays reversed".
<!-- cspell:disable -->
- Spanish (owner's Argentine usage): the mode and operation are "Reversa",
  the forward state word is "Normal", the reversed one "Reversa", the
  overview heading "Sentido de reproducción", the overdub refusal "No se
  puede sobregrabar mientras la pista suena al revés", the screen-reader
  label "La pista se reproduce al revés", and the failure "No se pudo
  cambiar el sentido de la pista." ("invertir" reads as polarity to audio
  users).
<!-- cspell:enable -->
- Pen departures (segno-ui.pen, 13 Performance · Reverse):
  - the Tracks indicator is the meta-row "REV" marker, as this plan states,
    not the pen's "‹ Reverse" caption under a Tracks pedal (the app's Tracks
    view is the column view, which has no pedal captions);
  - track names render in the app's display case ("TRACK 2"), and the top
    bar has no STAGE breadcrumb, as on the Fade surface;
  - the direction detail is 24 px (the shared pedal detail size), not 26.
- Size: production +901 / -62 Dart (plus 51 strings), past the 700-line
  review ceiling: the view alone is 342 lines, mirroring the Fade view.

## 5. Decisions taken under the standing rules

1. Toggle while the track writes (RECORDING, OVERDUBBING, punch tail, pending arm or
   launch): refused with a notice. The app refuses it before posting while the
   projection shows the track busy; one that races the projection is refused by
   the callback with a receipt, which shows the same notice. A track with no
   material yet has no direction, so a stomp on it is silent. Rule 2 and 5: a write on a
   reversed pair would corrupt the per-pass shadow; the refusal is visible.
2. Overdub into a reversed track: refused with `LE_ERR_REVERSED` and a notice; Play,
   Stop, Mute, Fade and history stay available. Rule 2 and 4: one capture engine;
   the RC-300/RC-505 rule is the proven pattern.
3. Turn click: a 10 ms equal-gain crossfade between the old and new heads, reusing
   the seam length. Rule 4: one crossfade law in the engine.
4. Printed Pre renders never play reversed; a toggle disengages the print. Rule 3 and
   4: the audible result cannot depend on cache state, and reversing the recording
   does not reverse its effects.
5. Direction resets with the material (Clear, Undo to empty, new capture, import,
   configure, New Loop when it exists); Clear Undo restores forward. Rule 5.
6. The reverse-then-forward phase offset persists until the transport hold or a
   relaunch, exactly as Once's offset does. Rule 4: one origin field, one reset.
7. Session saves `reversed` (schema 13), not the origin; recall is stopped at the
   lap start. Rule 3: what the player saved comes back. Rule 1 is unaffected: the
   project accepts only the current schema (`session.dart:688`).
8. Reopen keeps direction (material column) and parks the origin (runtime), composing
   with #1158's table. Rule 2.
9. Not undoable, no history entry, not an owned setting family (#1159). Rule 4.
10. Receipts reuse the Fade table and the reader is renamed to its honest neutral
    name; `LE_CMD_RESET_FADE` becomes the transform reset at the same value. Rule 4.
11. Free/Song honour `playback_offset` through the shared helper. Rule 1: the field
    is always zero there today, so existing installs behave identically.
12. LED blue (the Fade/Custom toggle colour), marker "REV", Undo/Clear inert in the
    mode. Rule 3 and 4.

Genuine product-direction questions, flagged separately (defaults above stand
until the owner says otherwise):

- Should Undo of Clear restore a track's direction, for parity with Fade and Mute?
- Should the Reverse mode give Undo/Clear a meaning (for example "all tracks
  forward"), or stay inert as planned?
- Should recall of a reversed track start at `len-1` (planned) or at index 0 reading
  backward into the tail?

## Collisions and sequencing

- #1158 (`le_engine_reopen`): Part 1 adds `reversed` to the configure init that
  #1158 moves into `le_engine_reset_material`; Part 2 adds the reopen test. Rebase
  after it merges.
- #1161 (capture-prep guard): both edit `le_record_impl` (`engine_commands.c:1400`).
  Land Part 1 after #1161; the Reverse guard sits after the effective-state read.
- #1159 (settings owner): no shared owner; only the `TrackOperation` switch arm.
- #1156/#1149 (Fade surface, this stack's top): Part 3 edits the same switch arms
  the Fade mode added; no semantic overlap.
- Review ceiling per part: 700 production lines; generated bindings, tests and
  docs counted separately. Stop for review on any second origin field, a reversed
  capture path, a new Dart owner or a mailbox change.
