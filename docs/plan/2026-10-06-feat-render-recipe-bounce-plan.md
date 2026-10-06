# Shared render recipe, foot Bounce and Save selected audio

<!-- cspell:ignore lbuf trk seg plog lanei evt wce tce rp gl gr fx_cap trk_rp iter milli permille reclock preselection unwritable -->

Status: plan for owner review (merging this plan approves its direction);
implementation not started.
Tracking: #1202 (inventory E5-1, E6-6, E7-10; parent #1026 part 4m, #926),
`autonomy:merge-gate`.
Base: `origin/claude/segno-integration` at `56033baf0`. Unless a branch is named,
every `file:line` below is on that head.
Precedents: [Multiply/Divide](https://github.com/tomassasovsky/segno/blob/claude/multiply-divide-plan-1168/docs/plan/2026-10-05-feat-foot-multiply-divide-plan.md)
(PR #1171, history kind and ring-applied image swap),
[Peel](2026-10-05-feat-foot-peel-plan.md) (PR #1166, history kinds),
[stem history replay](2026-10-05-feat-stem-history-replay-plan.md) (#1143,
provenance of applied images), [pitch/time core](2026-10-06-feat-pitch-time-core-plan.md)
(#1179, read head and the one render owner), and the Library plan on
`origin/claude/library-plan-1178` (`docs/plan/2026-10-06-feat-library-sessions-plan.md`).

Pen screens the work must match (`segno-ui.pen`, group `01 CURRENT UX`, read
through the pencil MCP from the 107 MB main-checkout file):

| Section | Screen | Node |
|---|---|---|
| 17 Performance · Bounce | 01 Select sources | `vBT13` |
| | 02 Sources across banks | `K2Ui7` |
| | 03 Choose destination | `YPpOv` |
| | 04 Replace destination | `y5o1vy` |
| | 05 Clear source tracks | `DhyM0` |
| | 06 Result and recovery | `y5k8v` |
| 18 Audio library | 03 Save audio / Tracks and destination | `M9kyGb` |
| | 04 Save audio / Name | `o32NQJ` |
| 49 Save audio and Bounce · Accepted | Save audio · Shared cycle | `op31E` |
| | Bounce · Shared cycle and Mix FX | `meZ1X` |

Section 49 is the later accepted composite. It adds the Length row (Common
cycle, −, `N bars`, +), Mix FX (Off/On, "All tracks effects") and Tails
(Wrap/Cut) to both flows. Save audio therefore takes its layout and name
keyboard from 18/03-04 and its render controls from 49.

## 1. Accepted behavior

- `docs/handoff/segno-app/accepted-behavior.md:243-249` (§3.11): "Bounce and
  Save selected audio share a finite common-cycle/chosen-length rendering
  recipe. Include selected recorded material regardless of stopped, mute or
  Solo status, its levels and runnable Post processing; do not reapply printed
  Pre. All tracks FX is optional. Live inputs, backing, click and output FX are
  excluded. Once contributes once then silence. Wrap/Cut controls the render
  boundary. The result resets destination processing so it is not printed
  twice. USB export copies a finished file; it does not rerender the session."
- `:167-172` (§2.11): "Clear All and Bounce are grouped edits: one Undo
  restores every touched track, its content/length/layers and the applicable
  previous playing/stopped states. [...] Newer dependent audio edits must be
  undone before an older group, rather than overwritten. Audio, history and
  relevant timing metadata publish together."
- `:306` (§4, Bounce row): "Select sources across banks, then destination, then
  explicit Bounce/Replace & bounce. Keep/Clear sources and tail choice are
  visible; selection alone does nothing. One Undo restores the whole operation."
- `:443-448` (§6.6): "Save selected audio uses the shared render contract, not
  the performance recorder."
- `:210-222` (§3.5, §3.6): Pre is part of the take's playable representation;
  "never process the old wet audio again"; Post processes downstream playback.
- `docs/design/2026-09-07-bounce-performance-ux.md` (main checkout, untracked):
  the pedal table (sources / destination / completed), "Keep sources and Wrap
  tails are the defaults", "Keep sources [...] creates a stopped destination",
  "Clear sources starts the destination if any selected source was playing",
  "A destination starts with neutral track gain, pan, pitch, reverse and fade,
  and without its previous track racks", "Global processing such as output FX
  and whole-loop Speed still applies once outside the bounce", "Tracks
  recording or overdubbing cannot be selected as sources or destinations;
  commit rechecks every involved track. Empty tracks cannot be sources but can
  be destinations." It leaves "the exact rendering algorithm, tail budget,
  nonlinear/stateful FX, clipping and external plugin handling" to
  implementation.
- `docs/design/selected-render-policy.js` (main checkout): the executable
  contract. `commonCycle` is the exact rational LCM of the sources' lengths,
  refused above 1024 beats ("Choose a length up to 256 bars. These tracks have
  no short common cycle."); `recipe()` drops `playing`, `muted` and `solo` from
  each source and keeps its `mix`, `fx`, `pitch`, `reverse` and `fade`;
  `globalSpeedPrinted: false`; `destination: {level: 1, pan: .5, mono: false,
  pitch: 0, reverse: false, fade: null, fx: []}`; chosen length steps by whole
  bars; tails default `wrap`.
- `docs/design/bounce-performance-study.js`: the commit snapshots every changed
  track whole (`before`), Undo restores it, the destination is `muted: false`,
  cleared sources become empty and stopped, and the destination plays only for
  Clear sources with a playing source.

## 2. What exists today (file:line)

### 2.1 Renderers

- **Performance-capture renderer** (`perf_render.c`). It reconstructs a
  finished capture from disk: `performance.json`, `events.log` and the staged
  images (`perf_render.h:1-28`). It is lane-0 only and mono per track
  (`le_pr_render_wet_track` `perf_render.c:1291-1555`, "only L is kept"
  `:1279-1283`), and it gates by the logged mute and solo (`:1512`). It
  has its own per-render thread and slot, `le_perf_render_begin/poll/cancel`
  (`segno_engine_api.h:3015-3070`), and refuses a second render
  `LE_ERR_ALREADY_RUNNING`. It knows nothing of Pre/Post, track chains or the
  All tracks chain. It is a replay of elapsed time, not a render of the
  present rig.
- **Loop-stage wet cache** (`engine_cache.c`). This is the Pre printer
  (slice 3e). A single background worker (`le_ca_worker_main` `:1307-1328`)
  renders a lane's Pre prefix, or a whole track's Pre run, from a
  copy-at-enqueue of `pool[a_live]` (`:9-23`, chunked by
  `le_cache_copy_step` `:1136-1191`). It uses the engine's own `fx_apply_chain`
  on a heap `le_fx_state` (`le_cache_render` `:1216-1305`). It aborts on an
  `a_audio_rev` bump (`:1265-1271`). Its tail rule is
  **RENDER-TWICE-KEEP-SECOND** (`:1208-1214`, `:1262-1295`): "delay/reverb
  tails that wrap the loop boundary are baked in". The chain snapshot is
  frozen into the job (`le_cache_job` `:171-200`, filled by
  `le_cache_schedule_lane` `:633-863`). Workers pick playing lanes first
  (`le_cache_pick` `:1193-1206`).
- **Loop-close restoration worker** (`engine_restore.c:1-40`). It is a second
  worker under the same [R2] contract.
- **Legacy Dart exports.** `SessionRepository.exportMixdown`
  (`packages/session_repository/lib/src/session_repository.dart:593-604`) and
  `exportStems` (`:610-628`) work as follows:
  - They read only playing and stopped tracks (`_capture` `:638-714`).
  - `_mixdown` (`:802-833`) sums unmuted lanes' live buffers in Dart at
    `volume * balance * trackLevel` over the LCM of the lane lengths. It has
    no FX, no pan and a mono output.
  - Output is written by `WavCodec.encodeFloat32` (`packages/wav_codec/lib/src/wav.dart:56`).
  - `save()` writes the same `_mixdown` into each bundle as `mixdown.wav`
    (`:495-504`).
  - The only callers, `SessionCubit.exportMixdown/exportStems`
    (`lib/session/cubit/session_cubit.dart:102-115`), have no UI caller.
  - Library P1 (`origin/claude/library-1178-p1`, PR #1185) re-bases both to
    copy saved-bundle files and removes the app callers.

### 2.2 The live mix the recipe must reproduce (`engine_process.c`)

Per lane, in `mix_tracks_frame` (`:5524`):

1. `loopsample = lbuf[seg_base[t] + trk_pos[t]]` (`:6011`), through the
   direction helper (`le_direction_index` `:155`; `engine_read_head.h`
   replaces it in pitch/time P2a, PR #1201).
2. The gate: `gate_ok = !mut && (!any_solo || solo[t])` (`:6054`).
3. Either the printed Pre (`wce`, `:6096-6123`) or `loopsample * vol`
   (`:6125`). `vol` is `live_level * image_gain` (`le_publish_lane_mix`
   `:2485-2500`).
4. One pass over the whole lane chain, Pre then Post (`:6136`).
5. Lane pan gains (`:6143`).
6. Without a track chain: `a_gain_bits * fade_sample` (`:6146`), then route.
   With a track chain: sum onto the track bus, then
   `fx_apply_chain_with_gain(&tr->bus.fx, …, trk_fx_pre_count, gain*fade)`
   (`:6232`). The whole-track Pre print is `tce` (`:5935`).
7. The All tracks chain runs per output bus over the recorded contribution
   (`:6311`). Output buses, monitors, click and the master follow
   (`output_bus_frame` `:4192`, `master_bus_frame` `:4232`).

Recordings are always dry. Effects colour playback only
(`segno_engine_api.h:524-528`).

### 2.3 History, grouping and the destination's state

- **History kinds** are `LE_HIST_LAYER=0`, `CLEAR=1`, `PEEL=2` and
  `PROCESSED=3` (`engine_private.h:783-794`).
- **`le_hist_entry`** (`:801-820`). A CLEAR point carries `len`, `multiple`,
  `state`, `master_len`, `muted_mask`, `clear_generation`, `fade_amount` and
  `fade_ready`.
- **Stacks:** `undo_stack`/`redo_stack` (`:920-923`).
- **Undoable Clear:** `le_clear_track(…, push_restore)`
  (`engine_commands.c:2156-2207`), restored by `le_restore_clear`
  (`:2375-2433`) through `LE_CMD_RESTORE_CLEAR` (`engine_process.c:3104`).
- **Undo and Redo:** `le_engine_undo` (`engine_commands.c:2449-2546`) and
  `le_engine_redo` (`:2572`).
- **Mode gate:** `le_engine_history_mode_gate(mask)` (`:2230`) projects
  restored spans against `le_mode_span_fits` (`engine_private.h:2199`).
- **Image publication:** images publish through `le_publish_live_image`
  (`engine_commands.c:374`, `:400`, `:2409`), which stages the image for a
  running capture (`le_stage_source_image` `:334`/`:782`, #1143).
- **Receipts:** `le_request_admit` (`:2759`) admits Fade, Reverse and Speed.
- **Clear All has no native group.** The group is a Dart ledger in
  `packages/looper_repository/lib/src/looper_repository.dart`:
  - The ledger sets are `_clearAllGroup`, `_clearAllPending` and
    `_clearAllRedoGroup` (`:3363-3380`).
  - `clearAll` (`:3332-3360`) records the group, and `_intactClearAllGroup`
    (`:3420-3445`) dissolves it once a member's point is retired.
  - `_undoClearGroup` (`:3566-3591`) runs `_historyModeGate` over all members,
    then calls `_undoTrack` per member. The `redo` group arm is at
    `:3664-3680`.
  - Each member is a separate ring command, so members can publish one block
    apart.
  - The FX, mute and chain of each cleared track are snapshotted in
    `_clearRestore` (`_snapshotForClearRestore` `:3520-3545`).
- **Image pans.** A lane's recorded image pan is frozen per track in
  `_laneBasePan` (`:1513`). An overdub keeps it: `record` skips lanes that
  already have one (`:3020`). The image travels with the capture
  (`le_apply_capture_image` `engine_process.c:2503-2516`, applied at every
  capture start `:272`).
- **Session save** drops Clear restore points. It captures only playing and
  stopped tracks (`session_repository.dart:647-649`), and Peel P2's
  `le_engine_finalize_history` rejects a CLEAR entry on the undo side
  (`origin/claude/peel-1164-p2:packages/segno_engine/src/core/engine_session.c:294`).
- **Import.** `le_engine_import_track_lane` (`engine_session.c:64-140`)
  requires an EMPTY track and grows lanes (`:109-114`).

### 2.4 Surface precedent

- `InteractionMode` (`lib/looper/model/interaction_mode.dart:8-56`).
- `ModeAction.token` (`lib/control/binding/control_action.dart:343-350`). The
  catalogue comment `:15-20` names Bounce as an operation left out until its
  engine exists.
- The Fade part files: `control_foot_fade.dart:4-74`,
  `lib/control/model/foot_fade.dart:154-193`, `lib/looper/view/foot_fade_view.dart`.
- `ControlCubit` sites:
  - `toggleMode` `:1303-1310`, `setMode` `:1422-1458`;
  - `recPlay` `:1577-1590`, `stop` `:1716-1730`, `trackPressed` `:1778-1795`;
  - `_onPress` `:2281-2310`, `_runAction` `:2496-2538`.
- `PerformancePedal` (`lib/looper/view/performance_pedal.dart:13-77`).
- LED projection (`lib/control/control_projection.dart:75-124`, `:198-205`,
  `:235-286`), duplicated in `lib/control/invariants.dart` around `:155`.
- `tracks_view.dart`: toasts `:138-148`, body swap `:209-213`.
- Reverse P3 (`origin/claude/reverse-1162-p3`) is the closest template: a
  134-line model and a 342-line view.
- **Library.** `origin/claude/library-1178-p3` has the Library shell with a
  single Sessions tab (`lib/library/view/library_page.dart:103-124`) and the
  `RemovableVolumes` port (`lib/library/application/removable_volumes.dart:19-54`;
  `withWriteLease` `:36-40`, `copyFile` `:48-53`, `ConflictPolicy` `:207`).
  The Library plan's P7 builds the Audio tab (`:817-886`). Save audio is out of
  its scope (`:115-118`, `:884`).
- **USB.** On `origin/claude/usb-storage-1177-p4`, `StorageRepository`
  provides `withWriteLease` (`storage_repository.dart:192-207`), `space`
  (`:314`) and `copyFile` (`:388-422`).

## 3. Numbering

### 3.1 Taken across the trunk and open branches (central numbering ledger kept by the coordinating session)

| Kind | Taken |
|---|---|
| Commands | ≤ 83 on trunk (`LE_CMD_REVERSE = 83`, `segno_engine_api.h:520`); 84 Multiply/Divide (`LE_CMD_SET_LENGTH`, PR #1171); 85 Speed (`LE_CMD_SET_SPEED`, PR #1201); 86-87 pitch/time Transpose and Audio & tempo; 88-95 backing (#1200); 96-111 instruments (#1197); 116-119 recording/recovery (#1198). Events 100-101 (`LE_EVT_*`) |
| Perf facts | 300-325 on trunk (321 Fade, 322/323 source applied/transport, 324 Reverse, 325 Peel); 326 Multiply/Divide; 327 Speed (PR #1201); 328-331 pitch/time; 336-339 instruments; 340-343 backing; 344-347 recording/recovery |
| `LE_ERR` | -1..-9 on trunk (`segno_engine_api.h:39-52`); -10 `TRANSFORMED` (Speed); -11 pitch/time; -12/-13 backing; -14/-15 instruments; -18/-19 recording/recovery |
| events.log version | 7 on trunk (`perf_drain.c:827`); 8 = pitch/time P2a; later bumps in landing order |
| Session schema | 11 on trunk (`session.dart:847`); 12 Peel P2 (PR #1194); 13 Reverse P2; Multiply/Divide P2, pitch/time P5 and instruments take the next free number at landing, each with its #1196 migration step |
| History kinds (`le_hist_kind`) | 0-3 on trunk; 4 `LE_HIST_LENGTH` (Multiply/Divide plan `:371`) |

### 3.2 This plan's numbers (assigned range 112-115 / 332-335 / -16, -17)

| Number | Name | Part |
|---|---|---|
| 112 | `LE_CMD_RENDER_FREEZE` | 1 |
| 113 | `LE_CMD_BOUNCE` | 4a |
| 114 | `LE_CMD_BOUNCE_RECOVER` | 4a |
| 115 | held, unused | – |
| 332 | `LE_PLOG_BOUNCE` | 4b |
| 333-335 | held, unused | – |
| -16 | `LE_ERR_NO_COMMON_CYCLE` | 1 |
| -17 | `LE_ERR_TRACKS_CHANGED` | 1 (render), 4a (commit and group recovery) |
| kind 5 | `LE_HIST_BOUNCE` | 4a. Not in the ledger yet; the main session should record it |

No session schema bump and no events.log bump in this plan (see 5.6 and 6.5).

## 4. The render recipe (design questions 1, 3 and 4)

### 4.1 Decision R1 (rule 4): one new executor on the existing render worker, built from the shared offline parts

The recipe neither reuses `perf_render.c` nor adds a third offline DSP path.

- **Why not `perf_render.c`.** It answers a different question: what did the
  rig play over elapsed time, reconstructed from a log on disk. The recipe
  answers what the selected tracks sound like now, over one cycle. Reusing it
  would mean writing a synthetic capture directory and teaching a lane-0,
  mono, mute-gated replay about lanes, Pre/Post, track chains and the All
  tracks chain. That would widen a reconstruction whose golden-parity
  protocol is deliberately narrow (`perf_render.c:1269-1283`).
- **What it reuses instead.** The recipe is a new job kind on the
  **wet-cache worker**, the engine's one render owner for live material.
  Pitch/time reached the same conclusion for Transpose: "A second worker would
  duplicate every one of those (rule 4)" (pitch/time plan §2.2, item 3).
- **What it shares with the cache:**
  - copy-at-enqueue staging with the `a_audio_rev` abort;
  - the frozen chain snapshot;
  - heap `le_fx_state` preparation and teardown (`le_fx_state_free_buffers`
    `engine_fx.c:714`);
  - the two-pass tail rule;
  - the thread, the shutdown join and the playing-first pick.
- **Code change.** The chain snapshot and the `le_fx_state` seeding are
  factored out of `le_cache_schedule_lane` (`:633-863`) and `le_cache_render`
  (`:1228-1257`) into `le_fx_frozen_chain` and `le_fx_frozen_chain_capture/_init`.
  They are declared in `engine_cache.h`, which only engine TUs include, so no
  new header reaches the C++ shim (`docs/PROGRESS.md`, "Adding a header to
  `src/core/`"). Cache jobs, the recipe and `perf_render.c`'s
  `le_pr_fx_chain` (`:1218-1259`) use the one struct; the perf renderer keeps
  its own log-driven mutations.
- **Slicing.** A recipe job renders in slices of `LE_RENDER_SLICE_FRAMES`
  (48 000 frames). The worker returns to `le_cache_pick` between slices, so a
  long render never holds back a Pre print or Transpose render for a playing
  lane by more than one slice.

### 4.2 What is rendered

For each selected track, the executor runs the live order of 2.2 offline. The
only differences are:

- **No gates.** Mute, part mute, Solo and transport state are ignored (§3.11
  "regardless of stopped, mute or Solo"; the policy deletes
  `playing/muted/solo`).
- **No routing.** Every source is summed into one stereo pair. Output masks,
  output buses, Mono, Balance, output FX, master gain and limiter are not
  applied (§3.11 excludes output FX; one file or one track has no outputs).
- **Lanes:** for each active lane, `source × (live_level × image_gain)`, then
  the whole lane chain (Pre then Post) on a heap state, then lane pan gains.
- **Track:** the sum of its lanes. With a track chain, the chain runs with
  `a_gain_bits × fade` inside it at the pre/post boundary, exactly as
  `fx_apply_chain_with_gain` (`engine_process.c:6232`). Without one, the sum
  is scaled by the same gain.
- **Mix FX** (All tracks chain, optional, default Off). One heap state over
  the stereo sum of all sources (`:6311` runs one state per output bus over
  that bus's contribution; a render has one destination).
- **Excluded:** live inputs and monitors, click, backing (#1200), output FX,
  master. Nothing from `output_bus_frame`/`master_bus_frame` runs.
- **Plugins.** Hosted plugin slots render as dry passthrough. A plugin
  instance belongs to the audio thread, and the offline state's
  `plugin[slot]` is NULL, which `fx_apply_chain` already renders dry
  (`perf_render.c:30-37`). §3.11 says "runnable Post processing", so this is
  the accepted boundary. It is reported, not silent (rule 3):
  `le_render_plan.plugin_bypassed_mask` drives a notice, "Plugin effects are
  not included in saved audio."
- **Clipping.** The sum is not limited. The master limiter is an output stage.
  Output is float, so a sum above 0 dBFS survives into the file or the
  destination track unchanged. The destination's own playback goes through the
  live master as any track does.

### 4.3 "Never re-apply printed Pre" (decision R2)

Pools are always dry. A lane's Pre material is either the cache's print or,
when no print is engaged, the live Pre over dry. Both apply Pre to dry exactly
once.

The recipe streams dry × level through the whole chain on a fresh state, so
Pre runs exactly once over dry. It never reads a published print (`a_wet`) and
never feeds printed audio into a chain.

This is simpler than key-matching a print. It is also exact against live
unprinted playback. With a print engaged, live playback differs from
unprinted playback only in the first lap of a lane's own Pre tail (the
documented [R5] periodic-render note, `engine_process.c:6080-6094`). The
recipe's two-pass Wrap removes that difference for loops (4.5).

The destination reset (5.3) is the other half of the rule: the result never
plays through the processing it already contains.

### 4.4 Length, origin and Once

- **Spans.** A source's span is its full track length `a_len`
  (`engine_private.h:490`). A multiple-`k` track's length is already `k ×
  base`; a Sync division's is `base / n`. Free/Song tracks use their own
  length. The span is measured in output frames at the source's audible rate
  with Speed removed (4.6). At rate 1, which is the trunk today, the span is
  `a_len`.
- **Common cycle.** The exact LCM of the spans in integer frames, computed in
  `uint64_t` with an overflow guard. It is accepted when it is at most
  `cap = round(1024 × 60 × sr / tempo)` frames: the policy's 1024 beats, at the
  tempo grid's BPM (`a_tempo_bpm_bits`, `engine_private.h:1635`).
  - When the cycle exceeds the cap, or the spans are not commensurate in
    frames, the result is `LE_ERR_NO_COMMON_CYCLE` (-16), the policy's
    `commonCycle → null`.
  - Integer frames are the engine's own units, so this is exact by
    construction. It matches the policy's rational arithmetic for any tempo
    whose beat is a whole number of frames, and refuses rather than rounds
    otherwise (rule 2).
- **Chosen length.** `length_bars > 0` renders
  `bars × beats_per_bar × 60 × sr / tempo` frames, rounded to the nearest frame
  using the tempo grid's time signature (`tempo_grid.c`). It is refused above
  the cap with `LE_ERR_CAPACITY` (-6). With tempo unset (0), chosen length is
  refused `LE_ERR_INVALID` and the surface disables −/+. Without a tempo there
  are no bars, and inventing a BPM is forbidden (§6.5 "never an invented BPM").
- **Bounce capacity.** The render length must also be at most
  `max_loop_frames` (`engine.c:352`; Settings default 30 s), else
  `LE_ERR_CAPACITY` at measure time. The prototype's "Loop exceeds length
  limit" hint appears before any render.
- **Origin (decision R3).** Render frame 0 is a master loop top, and every
  shared-clock source sits at its live phase relative to that top. Without
  this, two `k = 2` tracks started one loop apart would be rendered on top of
  each other's first halves, which is not what plays.
  - `start_iter`, `playback_offset` and `loop_iteration` are audio-thread state
    (`engine_private.h:1181`, `:1286`, `:1856`). The job therefore posts
    `LE_CMD_RENDER_FREEZE` (112).
  - Its callback handler records, for each selected source at the next
    master top: `I_ref = loop_iteration`; the source's segment origin
    `((I_ref - start_iter) mod k) × base`; its direction (`reversed`); its
    `a_live` slot per lane and `a_audio_rev`.
  - The control tick then stages PCM from exactly those slots
    (copy-at-enqueue). It aborts with `LE_ERR_TRACKS_CHANGED` (-17) if a
    source's `a_audio_rev` moves before the copy completes.
  - Free/Song sources have independent clocks and start at their own index 0.
  - The freeze handler reads only, applies at a master top (or immediately
    when the clock is held), and stores its result in the job's freeze record
    with release. The control side reads it with acquire. No audio-thread
    allocation.
- **Once.** A Once source (`a_one_shot`, `engine_private.h:1263`) reads its
  span once from its origin, then silence, in each pass (the policy's
  `play-once-then-silence`).
- **Sparse material** is copied as it lies (§2.7). Nothing is trimmed or
  re-anchored.

### 4.5 Tails (design question 3, decision R4)

- **Wrap** (default; the bounce study and policy default) renders the window
  twice back-to-back on the same chain states and keeps the second pass. This
  is the cache's RENDER-TWICE-KEEP-SECOND (`engine_cache.c:1208-1214`):
  - The tail leaving the window's end is folded into its start, exactly as
    it will be when the destination loops or the file loops.
  - The content of each pass is identical (Once included), so the kept pass
    is the steady-state loop.
  - There is no tail budget. A tail longer than one window carries one window
    of accumulation, the documented [R5] behavior of every cached loop. It is
    the same rule, so not a new approximation.
- **Cut** renders the window once from settled-cold states. The window starts
  with no tail and its last tail is truncated at the boundary ("ends them at
  the boundary").
- **Both** seed effects as the cache does: enabled slots settled wet,
  disabled ones bypassed (`engine_cache.c:1233-1243`), and
  `le_fx_entry_reset` before prepare (`:1246-1257`). `le_fx_prepare` OOM
  fails the job; a render never silently drops an effect (perf_render
  posture, `perf_render.c:1338-1346`).

### 4.6 Speed, Transpose, Reverse and Fade (design question 4, decision R5)

| Transform | In the render | On the Bounce destination | Why |
|---|---|---|---|
| Speed (global, `speed_global`, PR #1201) | Not printed: sources read at 1× | Unchanged; it keeps applying to every track, the destination included | Policy `globalSpeedPrinted: false`; bounce study "whole-loop Speed still applies once outside the bounce". Printing it would apply it twice |
| Tempo follow (pitch/time Part 4) | Printed: each source at its tempo term, as heard at the song tempo, with its pitch mode | The destination's recorded tempo is the current song tempo | The render is what plays now. The tempo term is not Speed |
| Transpose (per track, pitch/time Part 3) | Printed at the effective value: a non-bypassed `transpose_st`, rendered through the same offline transposition function the kind-1 cache job uses | Reset to 0 | Policy keeps `pitch` on the source and resets it on the destination. With global bypass on, sources are heard at true pitch and render that way |
| Reverse (per track, trunk) | Printed: read through `le_direction_index` (`le_head_index` after P2a) with the frozen direction from the source's origin | Reset to forward | Policy keeps `reverse` on the source; destination `reverse: false` |
| Fade (per track, trunk) | Printed as a constant gain: the source's fade amount at the freeze frame (`le_track.fade`, `engine_private.h:847`) | Reset (`le_transform_reset`, `engine_process.c:241`) | Policy keeps `fade` on the source and resets it on the destination. A fade in motion is frozen, not animated, because the render has no elapsed time (flagged in §9) |

Until P2a and the later pitch/time parts land, the head is the identity apart
from direction. The executor builds its per-source read head from the same
helpers as the mixer, so no second index law exists. When P2a merges, Part 1's
test "Speed 2× renders identically to 1×" joins the suite.

### 4.7 Native API (Part 1)

- **`le_render_request`** (public, `segno_engine_api.h`):
  - `uint32_t source_mask`;
  - `int32_t length_bars` (0 = common cycle);
  - `int32_t tails` (`LE_RENDER_WRAP = 0`, `LE_RENDER_CUT = 1`);
  - `int32_t mix_fx`;
  - `int32_t target` (`LE_RENDER_TARGET_MEMORY` for Bounce, `LE_RENDER_TARGET_FILE`);
  - `const char* path`;
  - `int32_t destination` (-1 for a file; the Bounce destination for the
    capacity check).
- **`le_engine_render_measure(engine, req, le_render_plan* out)`** is
  synchronous and admission-only, with no job.
  - Output: `frames`, `method` (common/chosen), `beats_milli`,
    `plugin_bypassed_mask`.
  - Results: `LE_OK`, `LE_ERR_NO_COMMON_CYCLE`, `LE_ERR_CAPACITY`,
    `LE_ERR_INVALID` (no sources, an EMPTY source, chosen length without a
    tempo), or `LE_ERR_NOT_READY` (a source is RECORDING or OVERDUBBING, has
    a layer in flight, has a pending arm or launch, or has an unacked state
    command; the M/D refusal list, M/D plan §1.3).
  - It is the engine's verdict the surfaces show as "12 bars" or as the
    error. The Dart side never re-derives the cycle (rule 4).
- **`le_engine_render_begin(engine, req, uint32_t* job)`** re-measures, posts
  112, and returns `LE_ERR_ALREADY_RUNNING` while a recipe job exists (one
  engine-wide recipe slot, separate from `perf.render`).
  - It returns `LE_ERR_UNSUPPORTED` when the cache worker failed to start
    (`le_cache_init` leaves `engine->cache` NULL, `engine_cache.h` comment).
  - The job holds frozen chain snapshots for every lane, track and Mix FX
    chain. Staging bytes plus output bytes are charged against a fixed
    `LE_RENDER_MAX_BYTES` (512 MiB) at admission, refused `LE_ERR_CAPACITY`.
- **`le_engine_render_poll(engine, job, int32_t* state, int32_t* permille,
  int32_t* result)`** reports one of the states `FREEZING`, `STAGING`,
  `RENDERING`, `DONE`, `FAILED` or `CANCELLED`. `result` carries the failure
  code (`TRACKS_CHANGED`, `CAPACITY`, `INVALID` on prepare OOM, or `DEVICE`
  when a configure or stop joined the worker; `le_cache_shutdown` aborts the
  job, rule 2).
- **`le_engine_render_cancel(engine, job)`.**
- **File target.**
  - The worker streams a stereo float32 WAV to `path + ".part"`: format 3,
    2 channels, the engine rate. It is the same format as every file the app
    and the perf renderer write (`wav.dart:73-78`, `perf_render.c:254-288`).
    It is float because the sum is unlimited (4.2).
  - On completion the worker fsyncs and renames `.part` to `path`. Failure
    unlinks the `.part`.
  - `perf_render.c`'s `le_pr_write_wav`/`_mono` become calls to the same
    streaming writer (rule 4).
- **Memory target.** The stereo result stays in the job until
  `le_engine_bounce` consumes it or the job is cancelled.
- **No audio-thread allocation or blocking.** 112 is checked and never
  raw-posted: it joins the `le_push` refusal list (`engine.c:1523`) and the
  `le_log_extract` exclusion list.

## 5. Bounce (design question 2)

### 5.1 Decision B1: one ring command publishes the whole bounce; the group lives natively

AB §2.11 requires that "Audio, history and relevant timing metadata publish
together". Clear All's Dart ledger posts one command per member
(`looper_repository.dart:3584-3586`), and the callback can drain between two
pushes.

For Clear All that gap is between silences. For Bounce with Clear sources
while playing, the destination would start one block before or after the
sources stop: one block of doubled audio (+6 dB) or of silence, which is an
audible click on the 64-frame appliance period.

Bounce therefore applies in one command:

- **Forward:** `LE_CMD_BOUNCE` (113). In one drain, the callback installs the
  destination and clears every cleared source, then stores the receipt.
- **Undo and Redo of the group:** `LE_CMD_BOUNCE_RECOVER` (114). In one drain,
  it swaps the destination back or forward and restores or re-clears every
  member.

Because the callback must know the members, the group is recorded in native
history:

- The destination's `LE_HIST_BOUNCE` entry carries `group_id` and
  `cleared_mask`.
- Each cleared source's CLEAR entry gains `group_id`. This is a new field in
  `le_hist_entry`, 0 for every existing entry, so existing Clear points are
  unchanged (rule 1).

Clear All keeps its Dart ledger for now. Moving it onto the same native group
is a follow-up issue, filed at Part 4b, rather than a silent change to Clear
All's behavior inside this plan (rules 3 and 4).

### 5.2 Admission (`le_engine_bounce`, Part 4a/4b)

`le_engine_bounce(engine, const le_bounce_request* req, uint64_t* request)`
takes `{job, destination, keep_sources, prepared fx bundle}`, calls
`le_engine_drain_events`, then checks, in order:

1. **The job.** It must be DONE with a memory result: `LE_ERR_NOT_READY`
   otherwise. Its frozen `a_audio_rev` must still hold for every source and
   for the destination: `LE_ERR_TRACKS_CHANGED` otherwise ("Tracks changed",
   the prototype hint).
2. **Busy tracks.** If the destination or any member is RECORDING,
   OVERDUBBING, has a layer in flight, has a pending arm or launch, has an
   unacked state command or pending clock command, or has a clear or cancel
   pending, the result is `LE_ERR_NOT_READY`. This is the M/D list; the bounce
   study requires "commit rechecks every involved track".
3. **History capacity.** `undo_count < LE_POOL_SLOTS` on the destination and
   on each cleared source, else `LE_ERR_NOT_READY` (the `le_clear_track` rule,
   `engine_commands.c:2166-2167`).
4. **Mode fit, with `L` the render length.** The base is
   `le_mode_base_channel` (`engine_private.h:2224`, given an exclusion mask) over the tracks that will still hold content after
   the bounce.
   - With no such track, the destination becomes the base: `reclock = L`, as
     M/D's sole-content rule (M/D plan §1.1 item 4).
   - Free/Song: any `L` fits (`le_mode_span_fits`, `engine_private.h:2199`).
   - Otherwise `le_mode_span_fits(mode, base, L)` must hold, else
     `LE_ERR_MODE_MISMATCH` ("Track lengths do not fit this loop mode", the
     prototype's refusal). The common cycle always fits a shared-clock rig;
     a chosen length may not.
   - `k' = L / base` or `n' = base / L` by `le_restore_multiple_or_divisor`'s
     arithmetic (`engine_process.c:1268`).
5. **Lanes.** The destination needs two active lanes, L and R. If it has one,
   admission posts the lane growth (the import path's helper,
   `engine_session.c:109-114`) and returns `LE_ERR_NOT_READY` until the growth
   is published. Dart retries on its settle loop (M/D lists
   `lane_growth_command` the same way).
6. **Image.** Acquire one slot through `track_acquire_slot`
   (`engine_commands.c:189`) and `le_lane_ensure_slot` (`engine.c:84`) at
   `le_layer_slot_frames(L)` (`engine_commands.c:227`) on every active lane. Copy L and R into lanes 0
   and 1, and zero-fill lanes 2 and up. Lanes share slot indices in lockstep
   (`engine_private.h:458-459`), so every lane must hold the new length. OOM
   gives `LE_ERR_CAPACITY` with the slot unreferenced.
7. **Receipt.** `le_request_admit` with `LE_CMD_BOUNCE`. The payload is
   `{destination, slot, len, multiple, divisor, reclock, start_playing,
   cleared_mask, group_id, image_id, struct le_prepared_fx* fx}`.
   - `start_playing = !keep && any selected source's le_effective_state is
     PLAYING`.
   - `cleared_mask = keep ? 0 : source_mask & ~(1u << destination)`. A source
     may be the destination; it is replaced, never cleared.
   - The control side files each cleared source's CLEAR restore point through
     `le_clear_track`'s bookkeeping with the push deferred into 113. One
     source of truth for what a Clear stores.
   - The destination's `LE_HIST_BOUNCE` entry and `le_clear_redo` are also
     filed control-side.
   - On a refused push nothing is filed and the slot is released.
   - `image_id` comes from `le_stage_source_image`, so a running performance
     capture gets the destination image (#1143).

### 5.3 The callback (`case LE_CMD_BOUNCE`)

The callback first rechecks the states of the destination and of every member.
On refusal it stores `LE_ERR_NOT_READY` in the receipt and pushes an event, and
the control side unfiles everything when it files that event. On acceptance,
in this order:

1. **Cleared sources.** `handle_clear(e, ch, 0, frame)` for each one
   (`engine_process.c:2309`), the same path as `LE_CMD_CLEAR`. Post tails
   drain (§3.6).
2. **Destination image.**
   - `le_publish_live_image(…, slot, image_id)` on every lane.
   - `le_track_set_len(t, L)`, `a_multiple`/`a_sync_divisor`, and the re-clock
     if asked (`le_restore_track_clock`, `engine_process.c:1284`; M/D plan §1.4).
   - `start_iter = I_ref` from the freeze, so the destination's segment 0 is
     the render's frame 0 and the bounce continues the music in phase.
   - Free/Song: its own clock at length `L`, position 0.
3. **Destination processing reset (decision B2).** This is the policy's
   `destination` object made concrete. Callback-owned state is set here; the
   FX chains travel as the prepared recipe bundle `fx` (empty chains for every
   active lane and the track chain), applied by `le_fx_recipe_apply`. That is
   the same mechanism `LE_CMD_RECORD_IMAGE` uses to land an image and its
   chains in one drain (`le_apply_capture_image` `engine_process.c:2503-2516`).
   - `a_gain_bits = 1`.
   - Each lane: `live_level = 1`, `live_pan = 0`, `image_gain = 1`;
     `image_pan` −1 and +1 on lanes 0 and 1, 0 elsewhere; mute off; then
     `le_publish_lane_mix`.
   - `le_transform_reset` (Fade and direction, and Transpose once pitch/time
     adds it there).
   - A newly activated lane 1 copies lane 0's output mask.
   - Unchanged: Solo, routes, recording inputs and Loop/Once. These are
     configuration, not processing (§2.10 keeps configuration outside audio
     history; the prototype touches none of them).
4. **State.** PLAYING if `start_playing`, else STOPPED at index 0.
   `le_audio_rev_bump`. `reset_track_viz` (`engine_process.c:923`).
5. **Finish.** Receipt `LE_OK`, then `a_state_acks++` for every touched track.

### 5.4 Undo and Redo of the group (`LE_CMD_BOUNCE_RECOVER`, decision B3)

`le_engine_bounce_recover(engine, destination, redo, fx bundle, request)`
checks that the group is intact. On undo:

- the destination's undo top is `BOUNCE(group_id)`;
- every source in `cleared_mask` has `CLEAR(group_id)` on its undo top and is
  EMPTY;
- nothing is busy.

Redo mirrors this on the redo stacks. A broken group returns
`LE_ERR_TRACKS_CHANGED`. AB §2.11 "Newer dependent audio edits must be undone
before an older group, rather than overwritten". The surface shows "Tracks
changed", the prototype's hint.

Undo, in one drain:

- The destination swaps back to the entry's slot.
- Restored from the entry: `len`, `multiple`, `divisor`, `master_len` (if it
  re-clocked), `state`, and the callback-owned mix it replaced: gain, the four
  per-lane floats, mute mask, fade amount, direction.
- Its chains come back from the bundle Dart builds from its snapshot (5.5).
- Each cleared source restores through the `LE_CMD_RESTORE_CLEAR` body.
- History motion is filed control-side at the event, as for Clear restores.

Redo re-applies the image, the reset and the clears.

A single-member Undo (Tracks view Undo on a cleared source, or on the
destination) is routed to the group by Dart. Native refuses a plain
`le_engine_undo`/`redo` whose top entry carries a nonzero `group_id`
(`LE_ERR_INVALID`), so no path splits a group.

The history mode gate (`le_engine_history_mode_gate`) projects the BOUNCE
entry's restored span like a CLEAR point.

Persistence (decision B4, rules 5 and 3):

- `le_engine_export_history` and `le_layer_slot_for_ordinal`
  (`engine_session.c:154-201`) stop below the newest BOUNCE entry. A saved
  session keeps the bounced take as its base, with any layers recorded on top.
- The replaced material and the group's Undo are not saved, which is the rule
  Clear points already follow (2.3).
- Part 5 shows a notice on save when this drops something ("Bounce Undo is not
  kept in saved sessions"). No schema change.

### 5.5 Repository orchestration (Part 5)

`LooperRepository.bounce(BounceRequest)`:

1. `measureRender`, then `startRender(memory)`; the job is polled (2.1
   pattern, `performance_recorder_cubit.dart:497-525`).
2. Snapshot the destination and every member into the existing
   `_clearRestore` shape (`_snapshotForClearRestore` `:3520-3545`), extended
   with gain, lane levels and pans and `_laneBasePan`.
3. Build the empty-chain recipe bundle.
4. `bounce`, through `_requestReceipt` (the Fade/Reverse admission path).
5. On `LE_OK`:
   - Commit the same values into the mix owner's intent, so the Mixer and
     settings owners match the callback without posting a second
     `SET_MIX`. These are the destination track level 1, part levels 1 and
     pans 0, and mutes off.
   - Set `_laneBasePan[(dest, 0)] = -1`, `[(dest, 1)] = +1`, so a later
     overdub keeps the bounce's stereo image (`:3020`).
   - Record the group for the surface.
6. `undoBounce`/`redoBounce` build the bundle from the snapshot or the empty
   one, and restore or re-apply the Dart-side intents at the receipt.
7. Refusals map to `RecoveryRefusal` (`:60-69`) and to the surface notices.

Tracks-view Undo on a group member calls the same methods (`undo()` routing
like `_undoClearGroup`'s `group.contains`, `:3555-3564`).

Exit or cancel before commit cancels the job and changes nothing.

### 5.6 Composition with open work

- **Stems (#1143).** The destination image is staged and becomes 322 at its
  first mixed frame. Cleared sources log the raw clear. `LE_PLOG_BOUNCE`
  (332, Part 4b) is the admission record `{destination, op
  (apply/undo/redo), cleared_mask, image_id}`, like Peel's 325. The renderer
  needs no new arm.
- **Stem limitation.** The perf renderer is lane-0 only, so a bounced
  destination's R lane is missing from its stem. This is the existing limit
  for every stereo pair, not new.
- **events.log version.** No bump: 332 is a new code the readers skip
  (`le_pr_load_log`, `perf_render.c:552-566`, checks only the magic). If the main session's
  rule requires a bump for any new code, Part 4b takes the next version at
  landing.
- **Reopen (#1158).** The BOUNCE entry and its slot are material. A 113 or 114
  unapplied at device loss is a state command: those tracks drop with the mask
  and a notice (the reopen rule). The recipe job aborts with `DEVICE`.
- **Multiply/Divide (#1168).** Kind 4 `LENGTH` entries beneath a BOUNCE entry
  are untouched. A length edit on a member is a newer edit that breaks the
  group (refused `TRACKS_CHANGED`). Images of different lengths on one stack
  are already handled by `le_hist_len_at` once M/D lands. A BOUNCE entry
  carries its own `len`.
- **Peel (#1164).** `le_peel_depth` (`engine_commands.c:91`) excludes BOUNCE, so Peel is blocked above
  a BOUNCE entry as M/D blocks it above LENGTH (Peel plan §1.1, non-overdub
  kinds block).
- **Reverse P2 / Speed.** The destination reset uses `le_transform_reset`, so
  any transform pitch/time adds there resets with it.
- **Backing (#1200).** Excluded from every render by construction: the recipe
  reads track pools only.

## 6. Save selected audio (E7-10, Part 3)

- **Surface.** Pen 18/03 (`M9kyGb`) and 18/04 (`o32NQJ`) for layout, with
  section 49 (`op31E`) for the render rows.
  - A full-screen page under Library > Audio: Sessions | Audio tabs, Stage,
    Cancel.
  - A Tracks grid of eight cells with Select all; empty tracks are disabled.
    The caption reads "One audio file, with the selected tracks and their
    effects."
  - The Save to section: Internal / USB drive; folder "Saved audio".
  - The render rows: Length (Common cycle / − / `N bars` / +), Mix FX
    (Off / On, "All tracks effects"), Tails (Wrap / Cut).
  - File name with a `.wav` suffix; the 18/04 naming sheet reuses Library P3's
    name keyboard.
  - The Save audio button.
- **Readouts.** The length readout and the length errors come from
  `measureRender` on every selection or option change.
- **Defaults.** No tracks are selected. Common cycle, Mix FX Off, Wrap,
  Internal. The automatic name follows Library's naming rule. The policy and
  pen say nothing on preselection, so the default is the least surprising: the
  player chooses.
- **Write.**
  - Internal: render to `<documents>/audio/<name>.wav` (the root E7-7's Audio
    library browses). The `.part`/rename publication is native (4.7).
  - USB: render to the internal location, then `copyFile` to
    `Segno/Audio/<name>.wav` under a write lease (`RemovableVolumes` on
    Library P3, backed by `StorageRepository` once USB P4/P6 land). The
    internal original is kept. This follows §3.11 "USB export copies a finished
    file; it does not rerender" and §6.8. The drive layout follows Library's
    `Segno/Performances`, `Segno/Sessions` (Library plan `:414-418`).
  - Name conflicts use `ConflictPolicy` (Keep both / Replace). Low space is
    checked before the render, using `space()` and the planned byte count.
- **Progress and cancel.**
  - While rendering, the Save audio button reads "Saving… N%", and Cancel
    cancels the job. Navigation away cancels too.
  - Capture start does not cancel. The job works from its frozen copy, so
    performing during a save cannot change the file.
  - This progress state is not drawn in the pen. It is listed in §8 for
    write-back.
- **Listing.** The Audio tab gains a "Saved audio" group listing
  `<documents>/audio/*.wav` (name, duration, date), with Library P7's Export
  to USB row action. Without it a saved file would be invisible on the device
  (rule 3). Browsing, preview and Use as backing remain E7-7's.
- **Legacy (decision S1).** The trunk's unreachable `exportMixdown/exportStems`
  are already re-based by Library P1 (2.1), so this plan does not touch them.
  - The bundle `mixdown.wav` written by `save()` (`:495-504`) is a second,
    divergent render (no FX, no pan, mono, mute-gated). Rule 4 says it should
    come from this recipe.
  - It is not changed here. Its consumers (Library P7's Sessions group, P6b
    audition) are #1178's, and making save wait on a render needs that plan's
    agreement.
  - Part 3 files a follow-up issue linking both plans, rather than silently
    changing what saved sessions contain (rule 3).

## 7. Foot Bounce surface (Part 6)

### 7.1 Mode and actions

- `InteractionMode.bounce` (label "Bounce"), excluded from `bootDefaults`.
- `ModeAction` token `'bounce'`. There is no `TrackOperation`: Bounce is a
  flow, not a per-track action.
- `toggleMode` returns to `record`, and entering the mode starts the sources
  step with an empty selection.
- New files on the Reverse P3 / Fade pattern:
  - `lib/control/model/foot_bounce.dart`: `FootBounceStep {sources,
    destination, rendering, done}`, `FootBounceAction`, `pedalRoles`,
    `FootBounceProjection {step, bank, sources, destination, keep, wrap,
    plan, canUndo, canRedo, progress}`;
  - `lib/control/foot_bounce_actions.dart`;
  - `lib/control/cubit/control_foot_bounce.dart`;
  - `lib/looper/view/foot_bounce_view.dart`.

### 7.2 Pedal roles

These follow the accepted table (bounce UX doc), the pen 17 screens and the
`assignments()` function in `bounce-performance-study.js`.

| Pedal | Sources (`vBT13`, `K2Ui7`, `meZ1X`) | Destination (`YPpOv`, `y5o1vy`, `DhyM0`) | Done (`y5k8v`) |
|---|---|---|---|
| Track 1-4 | Toggle source; Empty is inert | Select destination; occupied shows "Replace audio" | Readout; destination lit |
| Rec/Play | Next → Choose destination (enabled when the plan is OK) | Bounce, or Replace & bounce when occupied | Unavailable, "Bounce complete" |
| Stop | Unavailable | Back → Sources (keeps the selection) | Unavailable |
| Undo | Undo the last bounce; hold = Redo ("Nothing to undo" / "Whole bounce" / "Tracks changed") | Same | Undo whole bounce; hold = Redo |
| Clear | Wrap tails / Cut tails ("Across loop edge" / "At loop edge") | Keep sources / Clear sources ("After bounce") | New bounce |
| Bank | Tracks 5-8 / 1-4; the selection persists across banks | Same | Unavailable |
| Mode | Exit | Exit without applying | Exit, result kept |

- **During `rendering`:**
  - Rec/Play reads "Bouncing N%" and is inert; Stop, Undo and Clear are inert.
  - Mode exits and cancels the job; nothing changes.
  - This state is not in the pen and is listed in §8.
- **Gestures.** Holding Undo invokes only Redo, and every gesture resolves
  once (`_armGesture` as Fade `control_foot_fade.dart:11-37`). Capturing
  tracks are unavailable in both steps.
- **Render controls.** The Length, Mix FX and plan readout on `meZ1X` sit in
  the route panel on the sources step and are touch/encoder controls. They
  share the `SelectedRender` model with Save audio. The route diagram is not
  an encoder focus target (bounce UX doc).
- **LEDs.** Selected sources, then the destination, are lit in the track
  colour. The slot-less pedals follow accepted contact like Fade
  (`control_projection.dart:255-258`). The mode maps to `PedalMode.custom` in
  the projection and in `invariants.dart`.
- **Notices.** No common cycle, over the length limit, Tracks changed, busy,
  mode mismatch, plugin effects not included, and render failed. One toast per
  visit (`tracks_view.dart:138-148`).
- **Localization.** English and Spanish strings.
- **Wiring.** Tracks composition (`tracks_view.dart:209-213`), a11y and
  switch arms as Reverse P3.

## 8. Pen deviations to write back (a shipped departure from the pen is a design change)

The pen is read-only for this plan. Both items need owner write-back when
built:

1. A transient "Bouncing N%" caption on Rec/Play during the render (17, any
   step after commit) and "Saving… N%" on the Save audio button (18/03, 49).
   The prototype commits instantly; a real render of up to 1024 beats does
   not.
2. The "Saved audio" group in Library > Audio (18/01 draws Prepared audio
   only).

## 9. Parts

Every part keeps the app working end to end and exposes no unfinished
destination. Parts 1, 2, 4a, 4b and 5 add no entry point. Parts 3 and 6 are the
first to show anything. Sizes are production lines, excluding generated
bindings, tests and docs.

```
Part 1 native recipe ──► Part 2 Dart render seam ──► Part 3 Save selected audio (also needs Library P2 + P7)
      │                          │
      └──► Part 4a native Bounce (keep sources) ──► Part 4b grouped clear sources + fact
                                 │                          │
                                 └──────────► Part 5 Bounce repository ◄┘ ──► Part 6 foot Bounce surface
```

### Part 1. Native shared render recipe (about 640 production lines)

**Files and changes:**
- New `packages/segno_engine/src/core/engine_render.c`: request validation,
  span/LCM/cap math, the 112 freeze handler body (called from
  `apply_command`), staging on the cache tick, the sliced renderer, Wrap/Cut,
  Once, direction, frozen fade, Mix FX, the memory and file targets, the
  streaming WAV writer, and measure/begin/poll/cancel.
- `engine_cache.c`/`.h`: `le_fx_frozen_chain` factoring, the recipe job kind,
  slicing in the pick loop, and abort on shutdown.
- `engine_process.c`: the 112 case.
- `engine_private.h`: the job slot pointer and the freeze record.
- `segno_engine_api.h`: the API of 4.7, `LE_CMD_RENDER_FREEZE = 112`,
  `LE_ERR_NO_COMMON_CYCLE = -16`, `LE_ERR_TRACKS_CHANGED = -17`.
- `engine.c:1523` (refusal list), `perf_log_ring.h` (`le_log_extract`
  exclusion), `perf_render.c` (shared WAV writer), and the build lists that
  enumerate core TUs: CMake, podspec forwarders under `Classes/`, the SPM
  target and `run_native_tests.sh`.

**Tests** (new `src/test/test_engine_render.h`, included after
`test_engine_peel.h` at `test_engine_core.c:33568`). They use literal PCM
through production entry points, with `sr = 8` and `tempo = 60` (1 beat = 8
frames) unless noted:
- `test_render_common_cycle_literal`: A = `1..16` (2 beats), B = `100,200,…`
  over 24 frames (3 beats). Measure gives 48 frames and `beats_milli 6000`.
  Output `L[f] = R[f] = A[f%16] + B[f%24]` for f in 0..47, all lanes centred
  at unity.
- `test_render_ignores_transport_mute_solo`: the same rig with A stopped, B
  muted and another track soloed renders identically, bit for bit.
- `test_render_levels_pans_gain`: lane level 0.5, pan +1 and track gain 2.
  Literal products through `le_pan_gains` at ±1 and 0.
- `test_render_once_then_silence`: A Once over a 48-frame window gives A for
  f < 16, then 0.
- `test_render_reverse_frozen_direction`: a reversed A reads `16..1`
  repeating from the origin.
- `test_render_fade_frozen_amount`: fade amount 0.25 at freeze gives ×0.25;
  a fade moving during staging leaves the output unchanged.
- `test_render_origin_phase`: Multi, base 8, A `k = 2` started at iteration
  0, B `k = 2` started at iteration 1, freeze at an iteration with
  `I_ref = 2`. Frame 0 reads A segment 0 and B segment 1 (literal values).
  Free sources start at index 0.
- `test_render_chosen_length`: 3 bars of 4/4 at sr 8 gives 96 frames; −1 bar
  without a tempo is `LE_ERR_INVALID`; above 1024 beats is `LE_ERR_CAPACITY`.
- `test_render_no_common_cycle`: spans 16 and 17 frames with a cap below 272
  give `LE_ERR_NO_COMMON_CYCLE`.
- `test_render_pre_applied_once`: a lane with one stateless Pre built-in at a
  fixed setting. With the cache's print published (pumped past
  `LE_CACHE_SETTLE_MS`), the output is bit-identical to the same render with
  caching disabled, and equals one application of the effect to `dry × level`.
  The oracle is computed once by the test through `fx_apply_chain`; a double
  application differs.
- `test_render_wrap_vs_cut_tail`: a lane with a Post delay. Cut's first
  `delay` frames equal the dry samples exactly. Wrap's first frames carry the
  tail of the window's end. Wrap equals pass 2 of a two-window reference run;
  Cut equals pass 1.
- `test_render_mix_fx_optional`: an All tracks chain present gives output
  equal to the plain sum with `mix_fx = 0` and the processed sum with
  `mix_fx = 1`.
- `test_render_excludes_buses`: input signal, monitors on, click on, an
  output FX entry, master gain 0.5 and the limiter on. The render equals the
  render with all of them off.
- `test_render_live_parity`: one PLAYING source routed to outputs 0/1 with
  no gates and a Post chain started cold from a fresh engine. N frames of
  live output from the master top equal the Cut render of N frames,
  sample-exactly (the perf renderer's golden-parity pattern).
- `test_render_refusals`: capturing source `NOT_READY`, EMPTY source
  `INVALID`, second begin `ALREADY_RUNNING`, memory target over
  `max_loop_frames` `CAPACITY`, and the byte ceiling `CAPACITY`.
- `test_render_staging_tracks_changed`: an overdub admitted while staging
  makes the job `FAILED/TRACKS_CHANGED`. An overdub after staging completes
  leaves the output equal to the frozen material.
- `test_render_cancel_and_shutdown`: cancel mid-render frees everything.
  `le_engine_configure` during a render gives `FAILED/DEVICE` with no leak
  under ASAN.
- `test_render_file_target_wav`: the header bytes are literal (`RIFF`,
  format 3, 2 channels, rate, `bits 32`), the data length is `frames × 8`,
  the `.part` file is gone and the final name exists. A write failure (an
  unwritable directory) leaves no file and reports `FAILED`.
- `test_render_slices_interleave`: a long recipe job and a queued Pre print
  for a PLAYING lane. The print publishes before the recipe finishes.
- `test_render_plugin_bypass_reported`: a plugin slot in a source chain
  renders dry and sets `plugin_bypassed_mask`.
- After PR #1201 merges, `test_render_ignores_speed`: Speed 2× renders
  identically to 1×.

```success-criteria
GOAL: One native executor renders the selected tracks' recorded material over the exact common cycle or a chosen bar length, with levels, pans, gain, frozen Fade, direction, Pre applied once and Post, optional Mix FX and Wrap or Cut tails, regardless of transport, mute and Solo, without live inputs, click, outputs or master, on the existing render worker.
SUCCESS CRITERIA:
- Literal oracles hold for the common cycle, transport/mute/Solo independence, levels and pans, Once, Reverse, frozen Fade, phase origin, chosen length, Pre-once, Wrap and Cut, Mix FX and bus exclusion; live parity is sample-exact. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Every refusal (no common cycle, capacity, capturing, empty, busy, tracks changed, already running, unsupported) returns its code and mutates nothing; cancel and configure abort cleanly; the file target publishes atomically with a literal header. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- No callback allocation or blocking; sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- The cache's existing suite is unchanged by the factoring, and the C++17 shim repro from docs/PROGRESS.md compiles. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && manual: run the PROGRESS shim repro
- A long render on the appliance during a playing performance causes no xrun and finishes; worker CPU and time for 256 bars of eight tracks with chains are recorded on the issue. | verify: manual appliance run (HARDWARE)
NON-GOALS:
- Dart seam, surfaces, Bounce commit, plugin rendering, Transpose/tempo-follow sources (added by pitch/time parts through the same head), session mixdown.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2. Dart render seam and `SelectedRender` (about 380 production lines)

**Changes:**
- **Bindings.** Regenerated and formatted (`ffigen.yaml`, then `dart format`).
- **Engine seam.** New `packages/segno_engine/lib/src/selected_render.dart`
  with `RenderRequest`, `RenderPlan`, `RenderTails`, `RenderTarget` and
  `RenderJobStatus`. A role interface `EngineSelectedRender`
  (`measureRender`, `beginRender`, `pollRender`, `cancelRender`) is composed
  into `AudioEngine` like `EnginePerformanceCapture`
  (`audio_engine.dart:1421`, `:1516-1530`).
- **Implementations.** `NativeAudioEngine` (the `renderBegin/Poll` FFI pattern,
  `native_audio_engine.dart:2330-2407`), `MockAudioEngine` and the four fakes.
  `EngineResult` gains `noCommonCycle` (-16) and `tracksChanged` (-17)
  (`audio_engine.dart:20-69`).
- **Repository.** `packages/looper_repository`:
  - `SelectedRender {sources, lengthBars?, tails, mixFx}`;
  - `LooperRepository.measureRender`;
  - `renderToFile(SelectedRender, path)` and `renderToMemory(SelectedRender,
    destination)`, both returning a `RenderJob` with `Stream<RenderProgress>`
    and `cancel()`. Polling follows the recorder cubit's timer pattern;
    `close()` cancels.
  - `notReady` while `_sessionAudioReserved`.
  - The plan readout as bars and beats from the tempo grid.

**Tests:** repository unit tests against the fake (measure mapping, progress
stream, cancel, refusal mapping), plus one actual-native case
`packages/looper_repository/test/render_native_test.dart` (fixture of
`fade_native_test.dart:12-47`): record two literal loops, render to a temp
file, and decode it with `WavCodec` to the literal sum.

```success-criteria
GOAL: The app can measure and run the shared recipe to a file or to memory, observe progress, cancel, and receive each refusal as its own result, with no surface yet.
SUCCESS CRITERIA:
- Bindings, symbol parity and the seam are complete; fakes and mock implement it. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && /Users/Tomas/development/flutter/bin/flutter test)
- Repository measure, progress, cancel and refusals behave; the native case decodes the literal sum. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && SEGNO_ENGINE_LIB=$(bash packages/segno_engine/tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository/test/render_native_test.dart
- Static gates stay clean. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
NON-GOALS:
- Surfaces, Bounce, USB copy.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3. Save selected audio (about 600 production lines)

**Depends on:** Part 2, Library P2 (shell) and Library P7 (Audio tab).

**Changes:**
- New `lib/library/save_audio/` with `SaveAudioCubit` and state (the
  selection, `SelectedRender` options, the plan from `measureRender`, name,
  destination, progress, outcome) and the page view.
- The Audio tab's "Save audio" entry, which is the sub-nav row's Save audio
  item (Library plan deviation 3).
- The "Saved audio" group.
- Internal and USB writes per section 6, through the `RemovableVolumes`
  port's `withWriteLease`/`copyFile`/`space`, with `ConflictPolicy`.
- Notices: plugin bypass, no common cycle, capacity, tracks changed, drive
  lost, no space, failed.
- l10n EN/ES.
- The follow-up issue for the bundle mixdown (decision S1).

**Tests:**
- `test/library/save_audio/save_audio_cubit_test.dart` covers:
  - selection and Select all (empty tracks disabled);
  - plan readout and errors on change;
  - chosen length −/+ in whole bars, disabled without a tempo;
  - Save builds the request (defaults Common cycle, Wrap, Mix FX Off);
  - progress, cancel on Cancel and on close;
  - USB copies the finished internal file and never re-renders (the fake
    engine counts `beginRender` calls);
  - Keep both/Replace, drive lost, no space;
  - capture start does not cancel.
- `save_audio_page_test.dart` with goldens matching `M9kyGb`, `o32NQJ` and
  `op31E` in English and Spanish.
- An Audio tab listing test.

```success-criteria
GOAL: From Library > Audio, the player saves the selected tracks as one WAV to Internal or USB with the shared recipe's length, Mix FX and tails, names it, sees progress, can cancel, and finds the file under Saved audio.
SUCCESS CRITERIA:
- Cubit behavior for selection, plan, defaults, progress, cancel, conflict, space and drive loss matches section 6; USB is a copy of the finished file. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Page goldens match pen 18/03, 18/04 and 49 Save audio in English and Spanish. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library/save_audio
- Static gates and the whole suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- On the appliance, a saved file plays back in the Audio list and on a computer from the USB drive; unplugging mid-copy keeps the internal file and reports the drive. | verify: manual appliance run with a USB drive (HARDWARE)
NON-GOALS:
- Audio library browse/preview/backing (E7-7), session mixdown, DAW export (Library P7).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 4a. Native Bounce with Keep sources: install, reset, Undo/Redo (about 560 production lines)

**Changes:**
- `LE_HIST_BOUNCE = 5` and the `group_id`/`cleared_mask` fields in
  `le_hist_entry` (`engine_private.h:783-820`).
- `le_engine_bounce` admission of 5.2 for `cleared_mask = 0`.
- The 113 handler of 5.3.
- `le_engine_bounce_recover` with 114, for the destination alone.
- The export cut of 5.4, the mode-gate projection, and the refusal of plain
  undo/redo on grouped entries.
- Peel depth exclusion, and Bounce as a `le_push` refusal.
- Staged image ids for #1143.
- `LE_CMD_BOUNCE = 113`, `LE_CMD_BOUNCE_RECOVER = 114`.

**Tests** (`test_engine_bounce.h`; literal PCM; the render result injected
through a real Part 1 job):
- Empty destination: Bounce installs `L`/`R` literal into lanes 0/1, STOPPED
  at index 0, `len`, `multiple` and divisor correct.
- Occupied destination: replaces it. Undo restores the exact previous
  samples, length, multiple, lane count behaviour, image pans, gain, levels,
  mutes, fade amount, direction and state. Redo re-applies.
- Destination equals a source: replaced.
- Reset: gain 1, levels 1, pans 0, image pans ∓1, fade 1, forward, chains
  empty through the bundle in the same drain as the image. A probe at the
  apply frame shows no block where the image plays through old chains.
- Mode: Multi chosen length not a multiple is `MODE_MISMATCH`; sole content
  re-clocks (`LE_PLOG_LOOP_LENGTH_LOCKED`, bars); Sync division result;
  Free/Song own clock.
- `start_iter = I_ref`: a destination later set PLAYING is in phase with a
  kept source (literal).
- Refusals: busy, tracks changed (overdub after render), capacity,
  undo-stack full, lane growth `NOT_READY` then success. Each releases its
  slot and mutates nothing.
- History: a layer overdubbed on top of the destination then Undo undoes the
  layer first; Bounce Undo with a newer edit on top is refused
  `TRACKS_CHANGED`; plain undo of a grouped top is `INVALID`.
- Export: `export_history` stops below BOUNCE; a save and recall round trip
  keeps the bounced take as the base.
- Capture: during an armed capture, a 322 names the staged destination image.
- Reopen: an unapplied 113 drops the track with the mask.
- Both new commands are refused on raw post.

```success-criteria
GOAL: A rendered result replaces or fills one destination track in one callback drain with its processing reset, and one Undo or Redo restores or re-applies exactly that destination.
SUCCESS CRITERIA:
- Literal install, replace, Undo and Redo restore samples, length, multiple, lanes, image pans, mix, fade, direction, chains and state exactly; the reset lands in the same drain as the image. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Mode fit, re-clock, phase origin, refusals, history order, export cut, provenance and reopen behave as specified. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer, telemetry-off and the C++ shim repro pass; bindings regenerated. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test)
NON-GOALS:
- Clear sources, the group across tracks, Dart orchestration, surface.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 4b. Clear sources as one native group, and the Bounce fact (about 380 production lines)

**Changes:**
- `cleared_mask` admission: CLEAR points filed with `group_id` and the push
  deferred into 113.
- `handle_clear` for each member in the 113 handler.
- `start_playing`.
- The intact check and all-member application in 114.
- The redo-side mirror.
- `LE_PLOG_BOUNCE = 332` with its format-doc row
  (`docs/design/performance-event-log-format.md`).
- The follow-up issue: Clear All onto the native group.

**Tests:**
- Clear sources with two playing sources. Over the commit block the output
  continues sample-exactly from the sources into the destination. There is no
  frame where both sound or neither sounds (literal: the output equals the
  render buffer at the mapped phase from the apply frame). The destination is
  PLAYING. With no source playing, the destination is STOPPED.
- One Undo restores every source's layers, length and playing or stopped
  state, and the destination, in one drain (probe frame). Redo re-clears.
- A newer edit on any member (record on a cleared source, overdub on the
  destination, Peel, a length edit after M/D) refuses the group with
  `TRACKS_CHANGED` and changes nothing. Undoing that edit makes the group
  undoable again.
- Busy member refusal.
- `undo_count` full on one member refuses the whole bounce.
- Capture: the 332 record, the clears logged raw and the destination 322.
  Stems pass parity for lane 0.
- Reopen with an unapplied 114.

```success-criteria
GOAL: Bounce with Clear sources publishes the destination and every source clear together, and one Undo or Redo of the whole operation publishes together, refusing rather than overwriting newer dependent edits.
SUCCESS CRITERIA:
- The commit and the group recovery each land in one drain with sample-exact continuity; destination playing state follows the accepted rule. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Newer edits on any member refuse the group with TRACKS_CHANGED and mutate nothing; capacity and busy refusals are whole-operation. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The 332 record and the format doc row are present; sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
NON-GOALS:
- Moving Clear All onto the group (follow-up), surface.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 5. Bounce repository and engine seam (about 480 production lines)

**Changes:**
- `AudioEngine.bounce/bounceRecover` (`RequestAdmission`) on native, mock
  and the fakes; bindings.
- `LooperRepository.bounce(BounceRequest {render: SelectedRender, destination,
  keepSources})`, `undoBounce`, `redoBounce`, `lastBounce` (the group the
  surface shows) and `BounceOutcome`.
- The orchestration of 5.5: snapshot extension, empty and restore recipe
  bundles, mix-intent and `_laneBasePan` commits, `undo()`/`redo()` routing
  for members, refusal mapping, cancel on Exit.
- The save-time drop notice (5.4).

**Tests:**
- Repository against the fake:
  - request sequence (measure → begin → poll → bounce);
  - snapshot contents;
  - mix intent after the receipt (Mixer shows unity);
  - `_laneBasePan` set and restored, and a following overdub's image keeps
    ∓1;
  - member Undo routes to the group;
  - refusals map to `RecoveryRefusal`;
  - Exit before commit leaves the engine untouched;
  - save drop notice.
- Actual-native `bounce_native_test.dart`: two literal loops are bounced with
  Clear sources, then Undo and Redo, with exact first samples through
  `exportLayer`.

```success-criteria
GOAL: The repository bounces through the shared recipe with one admission, keeps Mixer, part pans and future overdubs consistent with the reset, and exposes one grouped Undo/Redo that every track entry point honors.
SUCCESS CRITERIA:
- Fake-engine sequences, snapshots, intents, base pans, routing and refusals behave as specified. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test)
- The actual-native round trip restores and re-applies exact samples. | verify: SEGNO_ENGINE_LIB=$(bash packages/segno_engine/tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository/test/bounce_native_test.dart
- Static gates and the whole suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
NON-GOALS:
- Surface, mappings.
VERIFICATION COMMAND: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 6. Foot Bounce surface (about 650 production lines)

**Changes:** section 7: mode, model, actions, cubit part, view with the route
panel and render controls, LEDs and the physical mask, invariants, Tracks
composition, notices, l10n EN/ES, a11y and switch arms, and the
`control_action.dart:15-20` comment updated.

**Tests:**
- `test/control/foot_bounce_dispatch_test.dart`:
  - track pedals toggle sources across both banks;
  - Next is enabled only with a valid plan;
  - destination select changes nothing until commit;
  - Replace & bounce wording on an occupied destination;
  - Back keeps sources;
  - Clear toggles Wrap/Cut, then Keep/Clear, then New bounce;
  - Undo, and hold for Redo only;
  - Exit before commit cancels the job and changes nothing;
  - capturing tracks inert;
  - each refusal shows its notice once;
  - rendering state inert except Mode.
- `foot_bounce_projection_test.dart` for the LEDs.
- `test/looper/view/foot_bounce_view_test.dart` with goldens for the six pen
  17 screens and `meZ1X`.
- The journey: select sources across banks, Replace & bounce, Clear sources,
  then Undo and Redo, as a repository sequence test.

```success-criteria
GOAL: The accepted foot Bounce flow selects sources across banks, then a destination, then commits Bounce or Replace & bounce with visible Keep/Clear sources and Wrap/Cut tails, shows progress, and undoes or redoes the whole operation by foot.
SUCCESS CRITERIA:
- Pedal roles per step match the accepted table; selection alone changes nothing; Exit before commit changes nothing; holds resolve once. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- LEDs and the face are truthful; goldens match pen 17/01-06 and 49 Bounce in English and Spanish. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Static gates and the whole suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- On the appliance by foot only: bounce three tracks across banks into an occupied track with Clear sources while playing, with no audible gap or doubling, Undo and Redo, and LEDs per step; repeat with Keep sources (destination stopped) and Cut tails on a delay. | verify: manual appliance session per docs/PROGRESS.md hardware evidence rules (HARDWARE)
NON-GOALS:
- Assignable single-action Bounce outside the mode, Clear All migration, pen edits.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

Each part runs the normal, ASAN and telemetry-off native suites where native
code changes, `dart analyze --fatal-infos` and `bloc lint`, and gets
independent architecture, test and adversarial review before the human merge
gate. Stop for review on:

- any audio-thread allocation;
- a second index or seam law;
- a print fed into a chain;
- a group member published in a separate drain;
- a new Dart owner beyond `SaveAudioCubit` and the foot model.

## 10. Decisions taken under the standing rules

- **R1 (rule 4).** The recipe is a new job kind on the wet-cache worker,
  sharing the frozen-chain snapshot, heap FX state, staging discipline and
  two-pass tail rule; `perf_render.c` is not reused (a log replay of elapsed
  time, lane-0, gated), and its chain struct and WAV writer are consolidated
  with the new code.
- **R2 (rule 2).** Pre is applied exactly once, by streaming dry × level
  through the whole chain on a fresh state; the recipe never reads a print.
- **R3 (rules 2, 3).** Render frame 0 is a master loop top frozen by a
  callback command, so shared-clock sources keep their live relative phase,
  and the destination's `start_iter` continues it. Free/Song sources start at
  their own index 0.
- **R4.** Tails: Wrap (default) renders the window twice and keeps the
  second; Cut renders once from cold states. No tail budget (the cache's rule
  and its documented [R5] limit).
- **R5.** Speed is not printed (global, applied once after); tempo follow,
  Transpose, Reverse and Fade are printed as heard, with Fade frozen at its
  amount, and the destination resets Transpose, Reverse and Fade.
- **R6 (rule 3).** Plugins render dry and are reported; sums are not limited;
  output is float32 stereo WAV at the engine rate.
- **R7 (rule 2).** The cycle is the exact integer-frame LCM within 1024
  beats; it refuses rather than rounds. Chosen length is in whole bars and is
  unavailable without a tempo.
- **B1 (rules 2, 4).** Bounce and its group Undo/Redo each apply in one ring
  command, with the group recorded natively. Clear All's Dart ledger moves
  onto it in a follow-up, not silently here.
- **B2.** The destination reset is gain, levels and pans (unity, centre,
  stereo image ∓1), mute off, Fade, direction, Transpose and all chains,
  landed in the same drain as the image. Solo, routes, recording inputs and
  Loop/Once are kept; Undo restores everything the reset changed.
- **B3 (§2.11).** A group whose member has a newer edit is refused, never
  overwritten; single-member undo is routed to the group.
- **B4 (rules 5, 3).** Saved sessions keep the bounced take as the base and
  drop the replaced material and the group Undo, as Clear points are dropped,
  with a notice. No schema bump.
- **B5.** The destination is always stereo (two lanes, L/R image pans);
  overdubs keep that image through `_laneBasePan`. Lanes 2 and up hold
  silence in the new image.
- **S1 (rules 3, 4).** Save audio writes internal first and copies to USB.
  The bundle mixdown's move onto the recipe is a follow-up shared with #1178.
- **N1.** Numbers come from the central ledger (112-114 used, 115 and 333-335
  held unused); history kind 5 is claimed here and needs a ledger entry.

## 11. Genuine product-direction questions (defaults above stand until the owner says otherwise)

1. **Fade in the render.** A selected track that is faded out (Fade amount 0)
   renders silent under the default, because the policy carries `fade` on the
   source like a level. Should Fade instead be treated like Mute, ignored by
   the render?
2. **Plugin effects.** Should Save audio and Bounce render hosted plugin
   effects, which needs a second, offline instance of each plugin? The default
   renders them dry with a notice.
3. **Mono destination.** Should a bounce whose sources are all mono and
   centred land as a single mono lane instead of a stereo pair? The default is
   always stereo, which keeps one rule and lets Mix FX widen the image.
