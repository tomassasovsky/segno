# Shared render recipe, foot Bounce and Save selected audio

<!-- cspell:ignore lbuf trk seg plog lanei evt wce tce rp gl gr fx_cap trk_rp iter milli permille reclock preselection unwritable sgno coprime unopenable -->

Status: plan for owner review (merging this plan approves its direction),
revised for the PR #1225 review (H1-H6, M1-M8, L1-L9) and the owner's answers
of 2026-10-06. Part 1 is built on `claude/render-1202-p1` (build record at the
end).
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
  (`origin/claude/peel-1164-p2:packages/segno_engine/src/core/engine_session.c:304`).
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
  single Sessions tab (`lib/library/view/library_page.dart:155`) and the
  `RemovableVolumes` port (`lib/library/application/removable_volumes.dart:19-54`;
  `withWriteLease` `:36-40`, `copyFile` `:48-53`, `ConflictPolicy` `:207`).
  The Library plan's P7 builds the Audio tab (`:817-886`). Save audio is out of
  its scope (`:115-118`, `:884`).
- **USB.** On `origin/claude/usb-storage-1177-p4`, `StorageRepository`
  provides `withWriteLease` (`storage_repository.dart:232`), `space`
  (`:394`) and `copyFile` (`:484`), at `a10cd2387`.

## 3. Numbering

### 3.1 Taken across the trunk and open branches (central numbering ledger kept by the coordinating session)

| Kind | Taken |
|---|---|
| Commands | ≤ 83 on trunk (`LE_CMD_REVERSE = 83`, `segno_engine_api.h:520`); 84 Multiply/Divide (`LE_CMD_SET_LENGTH`, PR #1171); 85 Speed (`LE_CMD_SET_SPEED`, PR #1201); 86-87 pitch/time Transpose and Audio & tempo; 88-95 backing (#1200); 96-111 instruments (#1197); 116-119 recording/recovery (#1198). Events 100-101 (`LE_EVT_*`) |
| Perf facts | 300-325 on trunk (321 Fade, 322/323 source applied/transport, 324 Reverse, 325 Peel); 326 Multiply/Divide; 327 Speed (PR #1201); 328-331 pitch/time; 336-339 instruments; 340-343 backing; 344-347 recording/recovery |
| `LE_ERR` | -1..-9 on trunk (`segno_engine_api.h:39-52`); -10 `TRANSFORMED` (Speed); -11 pitch/time; -12/-13 backing; -14/-15 instruments; -18/-19 recording/recovery |
| events.log version | 7 on trunk (`perf_drain.c:827`); 8 = pitch/time P2a; later bumps in landing order |
| Session schema | 11 on trunk (`session.dart:847`); 12 Peel P2 (PR #1194); 13 Reverse P2; Multiply/Divide P2, pitch/time P5 and instruments take the next free number at landing, each with its #1196 migration step |
| History kinds (`le_hist_kind`) | 0-3 on trunk; 4 `LE_HIST_LENGTH` (Multiply/Divide, PR #1212); 5 this plan; 6-7 reserved |

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
| kind 5 | `LE_HIST_BOUNCE` | 4a (ledger: history kinds) |

No session schema bump (5.4). Part 4b bumps the events.log version to the next
free number at landing, for code 332 (5.6).

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
- **Slicing.** A recipe job renders its window in slices of
  `LE_RENDER_SLICE_FRAMES` (48 000 frames), and each Pre print (4.3) is one
  setup unit of its own: two passes over that source's length. The worker
  returns to `le_cache_pick` between units, so a long render holds back a Pre
  print or Transpose render for a playing lane by at most one slice or one
  source-length print (review D-L1). One print of that size is what the cache
  itself spends on one lane, so the bound is the cache's own.

### 4.2 What is rendered

For each selected track, the executor runs the live order of 2.2 offline. The
only differences are:

- **No gates.** Mute, part mute, Solo and transport state are ignored (§3.11
  "regardless of stopped, mute or Solo"; the policy deletes
  `playing/muted/solo`). Active recordings cannot be sources
  (`2026-09-07-audio-library-ux.md`, "Empty tracks and active recordings
  cannot be selected").
- **No routing.** Every source is summed into one stereo pair. Output masks,
  output buses, Mono, Balance, output FX, master gain and limiter are not
  applied (§3.11 excludes output FX; one file or one track has no outputs). A
  lane routed to a pair receives exactly `(wl, wr)` (`le_fx_route_frame`,
  `engine_process.c:2547-2561`), so the summed pair is what each output pair
  carries.
- **Lanes.** For each active lane, the lane's take material (4.3) runs through
  the lane's Post entries `[pre_count, count)` on a heap state, then the lane
  pan gains.
- **Track.** The sum of its lanes. With a track chain, the chain runs with
  `a_gain_bits × fade` inside it at the pre/post boundary, exactly as
  `fx_apply_chain_with_gain` (`engine_process.c:6232`). Without one, the sum
  is scaled by the same gain.
- **Mix FX** (All tracks chain, optional, default Off). One heap state over
  the stereo sum of all sources. Live, `:6311` runs one state per output bus
  over that bus's contribution; a render has one destination. Save audio
  only: Bounce never includes it (owner, §11).
- **Excluded:** live inputs and monitors, click, backing (#1200), output FX,
  master. Nothing from `output_bus_frame`/`master_bus_frame` runs.
- **Plugins.** Hosted plugin slots render as dry passthrough. A plugin
  instance belongs to the audio thread, and the offline state's
  `plugin[slot]` is NULL, which `fx_apply_chain` already renders dry
  (`perf_render.c:30-37`). §3.11 says "runnable Post processing", so this is
  the accepted boundary (owner, 2026-10-06: keep the default).
  - `le_render_plan.plugin_mask` names the tracks with a plugin entry.
  - The surfaces show a notice before rendering that names them: "Plugin
    effects on Track 2 and Track 5 are not included."
- **Fade warning.** `le_render_plan.faded_mask` names the sources whose Fade
  amount is below unity at measure time. The surfaces warn before rendering:
  "Track 3 is faded out and will be quiet or silent" (owner, 2026-10-06: keep
  the default, plus a warning).
- **Clipping.** The sum is not limited. The master limiter is an output stage.
  Output is float, so a sum above 0 dBFS survives into the file or the
  destination track unchanged. The destination's own playback goes through the
  live master as any track does.

### 4.3 Pre is the take; Post and later stages are the render (decision R2)

AB §3.5 makes Pre "part of the take's playable representation", and the cache
prints it wrapped at the lane's own length (`engine_cache.c:1208-1214`). The
recipe treats each stage the way the live rig does:

- **Lane Pre.** For a lane with `pre_count > 0`, the executor produces the
  lane's print with the cache's own lane-print function: dry × level through
  `[0, pre_count)`, two passes over the lane's own length, keep the second.
  For a forward source this is the same function, input and frozen chain the
  cache uses, so the material is byte-identical to the published print
  whether or not the print is engaged.
  - **A reversed source (review D-H1).** The live rig never plays a print on a
    reversed track: a print engages only on a forward track, and a Reverse
    toggle disengages it (`engine_process.c:5980`, `:6137`, `:3330-3337`). The
    live Pre is a forward chain running over the backward read. Its steady
    state is the print of the dry *in read order*: the recipe lays the staged
    dry reversed, prints it with the same function (two passes, keep the
    second, wrapped at `len`), and reads that print forward at the lap phase.
    An echo then follows its note, as heard, instead of preceding it.
  - The recipe never feeds a print into a Pre entry, so Pre is applied exactly
    once.
  - A lane without Pre contributes `dry × level`.
- **Track Pre.** When every part of the track is wholly Pre (no lane Post), the
  live rig plays the whole-track print (`engine_process.c:5935-5970`). The
  recipe then produces the track's print with the cache's track-print
  function, wrapped at the track's length. A reversed track's print is made
  over its reversed lap, as for a lane.
  - Otherwise the track chain runs live, like a Post stage, and the recipe runs
    it over the window too.
- **Window stages.** Lane Post, a live track chain, and Mix FX are governed by
  the window and by Wrap/Cut (4.5).

A Cut render therefore keeps a Pre reverb's wash at the start of the file or
bounce, because the wash is part of the take, and cuts only the Post tails at
the window edge.

The destination reset (5.3) is the other half of the rule: the result never
plays through the processing it already contains.

### 4.4 Length, origin and Once

- **Spans.** A source's span is its full track length, lane 0's `a_len`
  (`engine_private.h:491`).
  - A multiple-`k` track's length is already `k × base`, and a Sync
    division's is `base / n`. Free/Song tracks use their own length.
  - The span is measured in output frames at the source's audible rate with
    Speed removed (4.6). At rate 1, which is the trunk today, the span is
    `a_len`.
- **Common cycle.** The exact LCM of the spans in integer frames, computed in
  `uint64_t` with an overflow guard.
  - **Cap with a tempo.** `cap = floor(1024 × 60 × sr / tempo)` frames: the
    policy's 1024 beats at the tempo grid's BPM (`a_tempo_bpm_bits`,
    `engine_private.h:1635`).
  - **Cap without a tempo** (bits 0, a valid restored state,
    `le_restored_tempo_valid`, `engine_private.h:2208`). The cap is `512 × sr` frames:
    1024 beats at the engine's default 120 BPM. This keeps the cap in frames
    with no invented musical meaning. Common cycle stays available; chosen
    length does not (below). The measure result reports `tempo_set = 0` so
    the surfaces show the length in seconds instead of bars.
  - **Refusal.** A cycle above the cap, or spans that are not commensurate in
    frames below it, return `LE_ERR_NO_COMMON_CYCLE` (-16), the policy's
    `commonCycle → null`. The notice is "These tracks have no short common
    cycle. Choose a length" with a tempo, and "These tracks have no short
    common cycle. Set a tempo to choose a length" without one. Most Free-mode
    sets of unequal length take this path, which is acceptable only because the
    notice says why and what to do.
  - **Exactness.** Integer frames are the engine's own units, so this is
    exact. It matches the policy's rational arithmetic for any tempo whose
    beat is a whole number of frames, and refuses rather than rounds
    otherwise (rule 2).
- **Chosen length.** `length_bars > 0` renders
  `round(bars × beats_per_bar × 60 × sr / tempo)` frames, using the tempo
  grid's time signature (`tempo_grid.c`). It is clamped to
  `floor(1024 / beats_per_bar)` bars, the policy's `adjust()` rule.
  - Without a tempo it returns `LE_ERR_INVALID`, and the surface disables −/+
    with "Set a tempo to choose a length in bars". Inventing a BPM is
    forbidden (§6.5).
- **Bounce capacity.** The render length must also be at most
  `max_loop_frames` (`engine.c:352`; Settings default 30 s), else
  `LE_ERR_CAPACITY` at measure time. The prototype's "Loop exceeds length
  limit" hint appears before any render.
- **Origin and read law (decision R3).** `LE_CMD_RENDER_FREEZE` (112) is
  applied in the next callback drain, without waiting for a loop top. Its
  handler records, for each source, the complete read law at that frame:
  - `I_ref = loop_iteration` (`engine_private.h:1856`);
  - the source's base position at the top of iteration `I_ref`. For a shared
    clock this is `le_track_base_position(e, t, &len) − clock.position`
    (`engine_process.c:129-148`): the segment origin for a multiple, 0 for a
    Sync division. For Free/Song it is 0, the start of the source's own lap;
  - `reversed` and `playback_offset` (`engine_private.h:1286-1296`);
  - `a_one_shot`, `once_ended`, the Fade amount, `a_live` and `a_len` per lane,
    and `a_audio_rev`;
  - after pitch/time P2a, the read-head phase and rate in place of
    `playback_offset`.

  Render frame `f` reads index
  `le_direction_index(reversed, playback_offset, base0 + f, len)`. This is
  exactly the live law (`le_track_read_index`, `engine_process.c:151-156`) run
  forward from the top of `I_ref`, so a mid-loop Reverse toggle or a Once
  relaunch keeps its live phase.
  - Render frame 0 is the top of the current iteration. The freeze needs no
    wait for the next top (review M4), so a render starts within one callback
    block.
  - The handler only reads audio-thread fields, stores the record, and
    publishes it with release. The control side reads it with acquire. There
    is no audio-thread allocation.
  - The control tick then stages PCM from exactly the recorded slots
    (copy-at-enqueue). It aborts with `LE_ERR_TRACKS_CHANGED` (-17) if a
    source's `a_audio_rev` moves before the copy completes.
- **Once (review D-M1).** A Once source (`a_one_shot`,
  `engine_private.h:1263`) plays one pass, from the first render frame
  `d ≥ 0` at which its read index equals its lap start
  (`le_direction_lap_start`). With `playback_offset = 0` and the source at
  segment 0, `d = 0`. Let `W` be the window length and `len` the span. Each
  window frame `f` has the pass phase `p`:
  - **On a common cycle the pass wraps.** `W` is a multiple of `len` and the
    window is itself a loop, so `p = (f − d) mod W`. A pass that runs past the
    window end continues at the window start, every sample of the pass sounds
    exactly once, and it stays in phase with the other sources.
  - **On a chosen length with `W ≥ len` the wrapped part continues the pass**
    from the same phase, `p = (f − d) mod W`. It does not jump back to the
    live law's index, which a `W` that is not a multiple of `len` would make
    differ.
  - **On a chosen length with `W < len`** the pass cannot fit. The render
    plays one pass from `d`, `p = f − d`, cut at the window end.
  - The source sounds when `0 ≤ p < len`, reading the lap index `p` steps from
    the lap start in its direction. It is silent elsewhere (the policy's
    `play-once-then-silence`).
- **Sparse material** is copied as it lies (§2.7). Nothing is trimmed or
  re-anchored.

### 4.5 Tails (design question 3, decision R4)

Wrap and Cut govern the window stages only (4.3).

- **Wrap** (default; the bounce study and policy default) renders the window
  twice back-to-back on the same chain states and keeps the second pass. This
  is the cache's RENDER-TWICE-KEEP-SECOND (`engine_cache.c:1208-1214`):
  - The tail leaving the window's end is folded into its start, exactly as it
    will be when the destination loops or the file loops.
  - The content of each pass is identical (Once included), so the kept pass is
    the steady-state loop.
  - There is no tail budget. A tail longer than one window carries one window
    of accumulation, the documented [R5] behavior of every cached loop
    (`engine_process.c:6080-6094`). It is the same rule, so not a new
    approximation.
- **Cut** renders the window once from settled-cold window stages. The window
  starts with no Post tail, and its last Post tail is truncated at the
  boundary ("ends them at the boundary"). Pre material is the take and is not
  cut.
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
| Transpose (per track, pitch/time Part 3) | Printed as heard. When the source plays its key-matched SOURCE entry (`transpose_effective_st == transpose_st`), the job stages that published entry's PCM in place of the dry pool. When it plays dry (render pending, bypass on), the job renders dry and `le_render_plan.pending_mask` reports it so the surfaces can say so | Reset to 0 | Policy keeps `pitch` on the source and resets it on the destination. Staging the published entry avoids repeating an unsliced stretch inside the recipe (review M7) |
| Reverse (per track, trunk) | Printed: read through the frozen law of 4.4 (`le_direction_index`; `le_head_index` after P2a); Pre printed over the reversed lap (4.3) | Reset to forward | Policy keeps `reverse` on the source; destination `reverse: false` |
| Fade (per track, trunk) | Printed as a constant gain: the source's Fade amount at the freeze frame (`le_track.fade`, `engine_private.h:847`), with the 4.2 warning | Reset (`le_transform_reset`, `engine_process.c:241`) | Policy keeps `fade` on the source and resets it on the destination. A fade in motion is frozen, not animated, because the render has no elapsed time |

Until P2a and the later pitch/time parts land, the head is the identity apart
from direction. The executor reads through the same helpers as the mixer, so
no second index law exists. When P2a merges, a test "Speed 2× renders
identically to 1×" joins the suite.

When Track Mono (inventory E5-4) lands, the render applies the source's Mono
as heard, and the destination reset table in 5.3 gains "Mono off" (the policy's
`mono: false`; review L9).

### 4.7 Native API (Part 1)

- **`le_render_request`** (public, `segno_engine_api.h`):
  - `uint32_t source_mask`;
  - `int32_t length_bars` (0 = common cycle);
  - `int32_t tails` (`LE_RENDER_WRAP = 0`, `LE_RENDER_CUT = 1`);
  - `int32_t mix_fx`;
  - `int32_t target` (`LE_RENDER_TARGET_MEMORY` for Bounce,
    `LE_RENDER_TARGET_FILE`);
  - `const char* path` (file target);
  - `int32_t max_frames` (0 = the 1024-beat cap; Bounce passes
    `max_loop_frames`).
- **`le_engine_render_measure(engine, req, le_render_plan* out)`** is
  synchronous and admission-only, with no job.
  - Output: `frames`, `method` (common/chosen), `beats_milli`, `tempo_set`,
    `plugin_mask`, `faded_mask`, `pending_mask`.
  - Results:
    - `LE_OK`;
    - `LE_ERR_NO_COMMON_CYCLE`;
    - `LE_ERR_CAPACITY`;
    - `LE_ERR_INVALID`: no sources, an EMPTY source, or a chosen length
      without a tempo;
    - `LE_ERR_NOT_READY`: a source is RECORDING or OVERDUBBING, is counting a
      posted command that will make it so (`le_effective_state` reads the
      pending target), or has a layer in flight. A posted state command that
      is not a capture does not refuse the measure; staging waits for it
      (review L2).
  - It is the engine's verdict, which the surfaces show as "12 bars" or as
    the error. The Dart side never re-derives the cycle (rule 4).
- **`le_engine_render_begin(engine, req, uint32_t* job)`** re-measures, posts
  112, and returns `LE_ERR_ALREADY_RUNNING` while a recipe job exists. There is
  one engine-wide recipe slot, separate from `perf.render`.
  - It returns `LE_ERR_UNSUPPORTED` when the cache worker failed to start
    (`le_cache_init` leaves `engine->cache` NULL).
  - The job holds frozen chain snapshots for every lane, track and Mix FX
    chain.
  - **Its own budget (review D-M2).** The job counts against
    `LE_RENDER_BUDGET_BYTES` (256 MiB), apart from the wet cache's cap. It
    never evicts a cache entry. Sharing the cache's cap, the first build's
    choice, let a Save audio started mid-performance evict the engaged Pre
    print of a playing track: that lane fell back to its live Pre through the
    re-enable path, an audible restart of the wash (rule 3).
  - The size: eight stereo 30 s tracks at 96 kHz stage about 176 MiB of dry
    audio, and a Bounce's 30 s stereo result adds about 22 MiB. The cache's
    64 MiB cap on this trunk (192 MiB after pitch/time 3a) would refuse such a
    set (review L6). The worst case the engine holds is the cache cap plus
    this budget, and the recipe's part is held only while a job runs.
  - What is charged: staged source frames, the Pre material, every effect
    state the job prepares (one per print, per lane Post, per live track chain
    and per Mix FX chain, with its delay rings; review L5), and the output.
    For a memory target the output is the stereo window. For a file target it
    is one slice buffer (review M6), so a 256-bar file at a slow tempo is
    bounded by its sources, not by its length.
  - Over the budget, the result is `LE_ERR_CAPACITY`.
  - **Release.** When a job finishes, the control tick frees everything the
    worker no longer needs. A FAILED job and a DONE file job keep nothing; a
    DONE memory job keeps only its stereo output until it is copied, consumed
    by Bounce, cancelled or replaced.
- **`le_engine_render_poll(engine, job, int32_t* state, int32_t* permille,
  int32_t* result)`** reports one of the states `FREEZING`, `STAGING`,
  `RENDERING`, `DONE` or `FAILED`. There is no cancelled state: cancel retires
  the id, and a poll of it returns `LE_ERR_INVALID`. `result` carries the
  failure code:
  - `TRACKS_CHANGED`;
  - `CAPACITY`;
  - `INVALID` on prepare OOM;
  - `DEVICE` when a write fails or a configure or stop joined the worker
    (`le_cache_shutdown` aborts the job, rule 2). The recipe's abort check
    reads the cache's shutdown flag as well as its own cancel flag, so a
    configure never waits for a whole print to finish (review M2).
  - A file whose rename succeeded but whose directory sync failed is
    published, and reads `DONE`: the file is in place and has replaced any
    earlier file at that path, though its directory entry may not survive a
    power cut (review L3).
- **`le_engine_render_copy(engine, job, float* out, int32_t max_frames)`**
  copies a DONE memory result as interleaved stereo. Part 4a's
  `le_engine_bounce` consumes the job in place.
- **`le_engine_render_cancel(engine, job)`** cancels and frees the job.
- **Worker scheduling (review M7).**
  - A recipe job runs in slices of `LE_RENDER_SLICE_FRAMES` (48 000 frames).
  - `le_cache_pick` ranks work in this order: queued prints for PLAYING or
    OVERDUBBING lanes (and pitch/time's SOURCE renders for playing tracks), then
    one recipe slice, then stopped-lane prints.
  - Aging: after `LE_RENDER_MAX_YIELDS` (8) consecutive cache jobs chosen ahead
    of a waiting recipe, the next pick is a recipe slice. Continuous re-keys
    therefore cannot starve it, and a slice never holds a playing print back by
    more than one slice.
- **File target and the one WAV writer (decision R6, review M6).**
  - A new internal module, `engine_wav.c` with `engine_wav.h`, is included
    only by engine TUs, never by `engine_private.h`.
  - It is the native streaming float WAV writer, in the layout of the
    recording/recovery plan's Part 2 (#1198, `docs/plan/2026-10-06-feat-recording-recovery-plan.md`
    on `origin/claude/recording-recovery-plan-1198`, "Layout" and
    "Lifecycle"):
    - `RIFF`/`WAVE`, a 16-byte `fmt ` with tag 3, 32 bits and block align
      `4 × channels`;
    - an optional caller chunk (#1198's `sgno`), then `data`;
    - the header is written with zero sizes, data is appended, and `seal`
      patches the RIFF and `data` sizes, then flushes and fsyncs;
    - `publish` renames `<name>.part` to `<name>` and syncs the directory with
      `le_fs_sync_dir` (#1198 Part 1, PR #1220).
  - Users:
    - the recipe's file target (stereo, no extra chunk);
    - `perf_render.c`'s stems and master (`le_pr_write_wav`/`_mono`
      `:254-310` become calls into it);
    - #1198 Part 2's part streams, which add their `sgno` chunk and their
      incremental digest through the same open/append/seal calls, flush each
      drain cycle with `le_wav_flush`, and repair parts on recovery with
      `le_wav_patch_sizes`.
  - **Landing order.** Whichever of #1198 Part 2 and this Part 1 lands first
    creates the module, and the other adopts it.
    - Until #1220 is on the trunk, `publish` fsyncs the file and renames
      without the directory sync.
    - The directory sync is one call added when #1220 lands. It is listed in
      the Part 1 build record.
  - Failure (open, write, seal, rename) unlinks the `.part` and reports
    `DEVICE`.
- **No audio-thread allocation or blocking.** 112 is checked and never
  raw-posted: it joins the `le_push` refusal list (`engine.c:1523`) and the
  `le_log_extract` exclusion list.

## 5. Bounce (design question 2)

### 5.1 Decision B1: one ring command publishes the whole bounce; the group lives natively

AB §2.11 requires that "Audio, history and relevant timing metadata publish
together". Clear All's Dart ledger posts one command per member
(`looper_repository.dart:3584-3586`), and the callback can drain between two
pushes.

For Clear All that gap is between silences. For Bounce with Clear sources while
playing, the destination would start one block before or after the sources
stop: one block of doubled audio (+6 dB) or of silence, which is an audible
click on the 64-frame appliance period.

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
- Multiply/Divide P1 (PR #1212) adds a `start` field beside it. That is a
  textual merge only.

Clear All keeps its Dart ledger for now. Moving it onto the same native group
is a follow-up issue, filed at Part 4b, rather than a silent change to Clear
All's behavior inside this plan (rules 3 and 4).

### 5.2 Admission (`le_engine_bounce`, Part 4a/4b)

`le_engine_bounce(engine, const le_bounce_request* req, uint64_t* request)`
takes `{job, destination, keep_sources, const le_mix_settings* topology,
prepared fx bundle}`. It calls `le_engine_drain_events`, then checks, in order:

1. **The job.** It must be DONE with a memory result, else `LE_ERR_NOT_READY`.
   Its frozen `a_audio_rev` must still hold for every source and for the
   destination, else `LE_ERR_TRACKS_CHANGED` ("Tracks changed", the prototype
   hint).
2. **Busy tracks.** If the destination or any member is RECORDING or
   OVERDUBBING, has a layer in flight, a pending arm or launch, an unacked
   state or clock command, a pending lane-count change
   (`lane_growth_command`), or a pending clear or cancel, the result is
   `LE_ERR_NOT_READY`. This is the M/D list; the bounce study requires that
   "commit rechecks every involved track".
3. **History capacity.** `undo_count < LE_POOL_SLOTS` on the destination and
   on each cleared source, else `LE_ERR_NOT_READY` (the `le_clear_track` rule,
   `engine_commands.c:2166-2167`).
4. **Mode fit, with `L` the render length.**
   - The base comes from a new variant
     `le_mode_base_channel_excluding(e, mode, cleared_mask)`. The existing
     `le_mode_base_channel(e, mode)` (`engine_private.h:2224`) takes no
     exclusion; the variant shares its body.
   - If the destination is the only track left with content after the bounce,
     and the rig has a running clock, the master length is kept whenever `L`
     is a whole multiple of it (`k' = L / base`). The clock keeps running, and
     `loop_iteration` and the grid are untouched.
   - Only an `L` that does not fit the kept base re-clocks the rig. The
     re-clock sets `clock.length = L` and position `(I_cur − I_ref) × base +
     clock.position) mod L`, which is the destination's live phase. It keeps
     `loop_iteration`, sets `start_iter = loop_iteration`, and logs
     `LE_PLOG_LOOP_LENGTH_LOCKED`. It never passes through the all-empty reset
     (5.3).
   - Free/Song: any `L` fits (`le_mode_span_fits`, `engine_private.h:2199`).
   - Otherwise `le_mode_span_fits(mode, base, L)` must hold, else
     `LE_ERR_MODE_MISMATCH` ("Track lengths do not fit this loop mode", the
     prototype's refusal). The common cycle always fits a shared-clock rig; a
     chosen length may not.
   - `k' = L / base` or `n' = base / L`, by `le_restore_multiple_or_divisor`'s
     arithmetic (`engine_process.c:1268`).
5. **Lane topology (review H4).** `topology` is an ordinary `le_mix_settings`
   for the destination, built by Dart (5.5) and validated and prepared by the
   same `le_mix_valid`/`le_prepare_routing` that `SET_MIX` and
   `le_engine_set_lane_count` use (`engine_commands.c:1400`, `:1462`,
   `:4358-4378`). It covers:
   - the lane count, at least 2;
   - lane levels, pans, image gains and image pans;
   - lane inputs and outputs.

   The prepared routing rides in the 113 payload and is applied by
   `le_apply_routing` (`engine_process.c:2647`) inside the 113 drain, so the
   lanes grow on the structural path with its buffer-lifetime fences, never by
   writing `lane_count` directly. The import path's direct write
   (`engine_session.c:109-114`) is legal only on an EMPTY track and is not
   used.
6. **Image.** Acquire one slot through `track_acquire_slot`
   (`engine_commands.c:189`) and size it with `le_lane_ensure_slot`
   (`engine.c:84`) at `le_layer_slot_frames(L)` (`engine_commands.c:227`) on
   every lane active after the bounce.
   - Copy L and R into lanes 0 and 1, and zero-fill lanes 2 and up. Lanes
     share slot indices in lockstep (`engine_private.h:458-459`), so every
     lane must hold the new length.
   - OOM gives `LE_ERR_CAPACITY` with the slot unreferenced.
7. **Receipt.** `le_request_admit` with `LE_CMD_BOUNCE`. The payload is
   `{destination, slot, len, multiple, divisor, reclock, start_playing,
   cleared_mask, group_id, image_id, tails, routing, struct le_prepared_fx*
   fx}`.
   - `start_playing = !keep && any selected source's le_effective_state is
     PLAYING`.
   - `cleared_mask = keep ? 0 : source_mask & ~(1u << destination)`. A source
     may be the destination; it is replaced, never cleared.
   - The control side files each cleared source's CLEAR restore point through
     `le_clear_track`'s bookkeeping, with the push deferred into 113. This
     keeps one source of truth for what a Clear stores.
   - The destination's `LE_HIST_BOUNCE` entry, which saves the replaced lane
     count and routing, and `le_clear_redo` are also filed control-side.
   - On a refused push nothing is filed and the slot is released.
   - `image_id` comes from `le_stage_source_image`, so a running performance
     capture gets the destination image (#1143).

### 5.3 The callback (`case LE_CMD_BOUNCE`)

It rechecks the states of the destination and every member. On refusal it
stores `LE_ERR_NOT_READY` in the receipt and pushes an event; the control side
unfiles everything when it files that event. On acceptance, in this order:

1. **Destination transforms (review L3).** `le_transform_reset(e, dest,
   frame)` (`engine_process.c:241`) resets Fade and direction, and Transpose
   once pitch/time adds it there. It also resets the destination's capture
   provenance, which the `:236-240` comment allows here because the next step
   publishes a staged image at once and names it (#1143). The reset therefore
   comes before the publish.
2. **Destination image (review H2: install before any clear).**
   - `le_publish_live_image(…, slot, image_id)` on every lane.
   - `le_track_set_len(t, L)`, `a_multiple`/`a_sync_divisor`, and the re-clock
     only if 5.2 asked for it.
   - `start_iter = I_ref`, so the destination's segment 0 is the render's
     frame 0 and the bounce continues the music in phase against the preserved
     `loop_iteration`.
   - Free/Song: its own clock at length `L`, position 0. This is a jump against
     sources at arbitrary phase, which is inherent to independent clocks
     (review L5).
3. **Destination processing reset (decision B2).** `le_apply_routing` applies
   the prepared topology:
   - `live_level = 1`, `live_pan = 0` and `image_gain = 1` on every lane;
   - image pans −1 and +1 on lanes 0 and 1. Lanes 2 and up keep theirs;
   - mute off;
   - inputs and outputs per 5.5 (H5).

   Then `a_gain_bits = 1`, and the FX recipe bundle `fx` (empty lane and track
   chains) through `le_fx_recipe_apply`. That is the same mechanism
   `LE_CMD_RECORD_IMAGE` uses to land an image and its chains in one drain
   (`le_apply_capture_image`, `engine_process.c:2503-2516`). Solo, Loop/Once
   and the track's output routes are kept.
4. **Cleared sources.** `handle_clear(e, ch, 0, frame)` for each one
   (`engine_process.c:2309`). The destination already holds content, so the
   all-empty master reset (`:2405-2420`) cannot fire inside a bounce.
   - **Wrap (review H3).** The destination's first lap already carries the
     sources' Post tails, folded from the window's end. The handler therefore
     clears each cleared source's lane Post and track-chain tails in the same
     drain, with `le_fx_state_clear_tails_range` over `[pre_count, count)` and
     over the track bus. One tail sounds, not two.
   - **Cut.** The destination starts without a tail, so the sources' Post
     tails drain as for any Clear (§3.6).
   - Shared All tracks and output tails are not touched. They are live stages
     the destination also feeds.
5. **State.** The destination becomes PLAYING if `start_playing`. Otherwise it
   is STOPPED, holding the index its law reads at this frame. Then
   `le_audio_rev_bump` and `reset_track_viz` (`engine_process.c:923`).
6. **Finish.** Store receipt `LE_OK` and increment `a_state_acks` for every
   touched track.

### 5.4 Undo and Redo of the group (`LE_CMD_BOUNCE_RECOVER`, decision B3)

**The group check.** `le_engine_bounce_recover(engine, destination, redo,
const le_mix_settings* topology, fx bundle, request)` checks that the group is
intact. On undo:

- the destination's undo top is `BOUNCE(group_id)`;
- every source in `cleared_mask` has `CLEAR(group_id)` on its undo top and is
  EMPTY;
- nothing is busy.

Redo mirrors this on the redo stacks. A broken group returns
`LE_ERR_TRACKS_CHANGED`; AB §2.11 says "Newer dependent audio edits must be
undone before an older group, rather than overwritten", and the surface shows
"Tracks changed".

**Undo, in one drain.** The order is again destination first, then the
sources:

- The destination swaps back to the entry's slot.
- From the entry it restores `len`, `multiple`, `divisor`, `master_len` (if it
  re-clocked), `state`, the gain, mute mask, Fade amount and direction.
- `topology` (Dart's snapshot, 5.5) restores lane levels, pans, image gains,
  image pans, inputs and outputs through `le_apply_routing`. The chains return
  through the bundle.
- **Lane count (review H4).** The count returns to its old value when the
  lanes the bounce added are not recoverable. While the Redo branch still holds
  the bounce, its added lane is recoverable, and the shrink rule refuses to
  drop it (`le_mix_valid`'s `a_recoverable` check, `engine_commands.c:1416-1422`;
  the #595 rule that stops a shrink-then-regrow from eating a take).
  - Undo then leaves that lane active but unrouted (outputs 0, input −1). Its
    slot in the restored image is silent, so it plays and records nothing.
  - The existing trailing-lane reclaim (`le_trim_trailing_lanes`,
    `engine_commands.c:4397-4419`) shrinks it as soon as the Redo branch is
    retired.
  - Audible and recorded behavior after Undo equals the pre-bounce rig exactly.
    Only the reported lane count lags, and Dart's mix intent records the true
    count, so a replay never fights the engine.
- Each cleared source restores through the `LE_CMD_RESTORE_CLEAR` body.
- History motion is filed control-side at the event, as for Clear restores.

**Redo** re-applies the image, the reset, the topology and the clears, in the
5.3 order.

**Members cannot split the group.**

- A single-member Undo (Tracks view Undo on a cleared source, or on the
  destination) is routed to the group by Dart.
- Native refuses a plain `le_engine_undo`/`redo` whose top entry carries a
  nonzero `group_id` (`LE_ERR_INVALID`), so no path splits a group.
- The history mode gate (`le_engine_history_mode_gate`) projects the BOUNCE
  entry's restored span like a CLEAR point.

**Dissolving a stale redo group (review M8).** When `le_clear_redo` retires
the redo branch of any track whose redo stack holds an entry with a nonzero
`group_id`, it retires that group's redo entries on every member in the same
call. A Bounce, then Undo, then a new edit on the destination therefore leaves
no source with a stuck grouped Redo. Each affected member's `a_redo_depth`
republishes.

**Persistence (decision B4, review H6).** This is written against Peel P2's
`le_engine_export_history`, which exports both stacks with `undo_count`
(`origin/claude/peel-1164-p2:packages/segno_engine/src/core/engine_session.c:167-192`),
and its strict `le_engine_finalize_history`, which accepts kinds 0-3 and
rejects an undo-side CLEAR (`:293-304`):

- **Undo side.** Export stops below the newest BOUNCE entry. A saved session
  keeps the bounced take as its base, with any layers recorded on top.
- **Redo side.** Export drops a BOUNCE entry, and every entry with a nonzero
  `group_id`, on every member. The redo branch is cut at the first such entry.
- **Consistency.** `undo_count` and `le_layer_slot_for_ordinal`
  (`engine_session.c:154-201`) follow the same cut, so a saved session never
  carries kind 5 or a grouped CLEAR, and recall never splits a group into a
  plain Redo.
- **Notice.** When the cut drops anything, Part 5 shows "Bounce Undo and Redo
  are not kept in saved sessions" (rule 5). The replaced material and the
  group's Undo are not saved, which is the rule Clear points already follow
  (2.3).
- **No schema bump.**

### 5.5 Repository orchestration (Part 5)

`LooperRepository.bounce(BounceRequest)`:

1. **Render.** `measureRender`, then `startRender(memory)`. The job is polled
   with the 2.1 pattern (`performance_recorder_cubit.dart:497-525`).
2. **Snapshot.** Snapshot the destination and every member into the existing
   `_clearRestore` shape (`_snapshotForClearRestore` `:3520-3545`), extended
   with the destination's full `_MixIntent` rows (`looper_repository.dart:629-642`):
   gain, `counts`, `balances`, `inputs`, `routes`, part levels and pans, and
   `_laneBasePan`.
3. **Topology (review H4, H5).** Build `topology` and the empty-chain bundle.
   Recording routing, chosen so an overdub records what the player expects:
   - **Destination had two or more lanes** (a stereo pair, or several parts):
     every lane keeps its input. Lanes 0 and 1 already record the pair's left
     and right.
   - **Destination had one lane** (a mono input `i`, or no input): the grown
     lane 1 records the same input as lane 0. A mono overdub then lands in
     both lanes, hard left and hard right at equal gain, which plays exactly
     as a centred mono part does. Nothing new is recorded, and no
     unrelated hardware input is armed (the `le_lane_reset` default
     `input == lane`, `engine_session.c:100-110`, is overridden).
   - The track's set of recording sources is unchanged in both cases.
   - The grown lane routes to lane 0's outputs.
   - Lanes 2 and up keep their inputs, outputs and base pans.
4. **Commit.** `bounce` through `_requestReceipt` (the Fade/Reverse admission
   path).
5. **On `LE_OK`, commit to the Dart owners what the callback applied**, so
   every mix replay (device reopen, configure, recall, `replay ||`,
   `:704-731`) re-sends the bounced rig rather than the old one:
   - `_MixIntent` gets `counts[dest]` (the new count), `balances = 1` and
     `levels = 1` on every lane, `pans = 0`, the 3) inputs and routes, track
     level 1, mutes off;
   - `_laneBasePan[(dest, 0)] = −1`, `[(dest, 1)] = +1`, so a later overdub
     keeps the bounce's stereo image (`:3020`);
   - the group record for the surface.
6. **Undo and Redo.** `undoBounce`/`redoBounce` build the topology and bundle
   from the snapshot or from the bounce state. At the receipt they restore or
   re-apply the same `_MixIntent` rows and `_laneBasePan`. After Undo, the
   intent records the engine's true lane count with the added lane unrouted
   (5.4).
7. **Refusals** map to `RecoveryRefusal` (`:60-69`) and to the surface
   notices.

Tracks-view Undo on a group member calls the same methods (`undo()` routing
like `_undoClearGroup`'s `group.contains`, `:3555-3564`).

Exit or cancel before commit cancels the job and changes nothing.

### 5.6 Composition with open work

- **Stems (#1143).**
  - The destination image is staged and becomes 322 at its first mixed frame.
  - Cleared sources log the raw clear.
  - `LE_PLOG_BOUNCE` (332, Part 4b) is the admission record
    `{destination, op (apply/undo/redo), cleared_mask, image_id}`, like
    Peel's 325.
  - The renderer needs no new arm.
  - The perf renderer is lane-0 only, so a bounced destination's R lane is
    missing from its stem. This is the existing limit for every stereo pair,
    not a new one.
- **events.log version (review L4).** The format doc says the version "covers
  the code vocabulary" (`docs/design/performance-event-log-format.md:36-39`), so
  Part 4b bumps `perf_drain.c`'s version to the next free number at landing
  and adds its row to the format doc. Pitch/time P2a holds 8.
- **Reopen (#1158).**
  - The BOUNCE entry and its slot are material.
  - A 113 or 114 unapplied at device loss is a state command: those tracks
    drop with the mask and a notice (the reopen rule).
  - A recipe job aborts with `DEVICE`.
- **Multiply/Divide (#1168, P1 PR #1212).**
  - Kind 4 `LENGTH` entries beneath a BOUNCE entry are untouched.
  - A length edit on a member is a newer edit that breaks the group (refused
    `TRACKS_CHANGED`).
  - A BOUNCE entry carries its own `len`, so `le_hist_len_at` reads it like a
    LENGTH entry.
- **Peel (#1164).** `le_peel_depth` (`engine_commands.c:91-99`) already stops
  at any kind other than LAYER and PEEL, so Peel is blocked above a BOUNCE
  entry with no code change. Part 4a adds only a test (review L2).
- **Reverse P2 / Speed.** The destination reset uses `le_transform_reset`, so
  any transform pitch/time adds there resets with it.
- **Backing (#1200).** Excluded from every render by construction: the recipe
  reads track pools only.

## 6. Save selected audio (E7-10, Part 3)

**Surface.** Pen 18/03 (`M9kyGb`) and 18/04 (`o32NQJ`) for layout, with
section 49 (`op31E`) for the render rows.

- A full-screen page under Library > Audio: Sessions | Audio tabs, Stage,
  Cancel.
- A Tracks grid of eight cells with Select all; empty tracks and active
  recordings are disabled. The caption reads "One audio file, with the
  selected tracks and their effects."
- Save to: Internal / USB drive. The folder line reads "Saved audio".
- The render rows: Length (Common cycle / − / `N bars` / +), Mix FX
  (Off / On, "All tracks effects"), Tails (Wrap / Cut).
- File name with a `.wav` suffix. The 18/04 naming sheet reuses Library P3's
  name keyboard; Cancel preserves the draft, and an empty name disables Done.
- The Save audio button.

**Defaults (review M5).** As the pen draws them:

- every recorded track is preselected (`M9kyGb` and `op31E` show Tracks 1-3
  selected, with the empty 4-8 dimmed);
- Common cycle, Mix FX Off, Wrap, Internal;
- the automatic name follows Library's naming rule.

**Readouts.** The length readout, the length errors, and the plugin and fade
warnings (4.2) come from `measureRender` on every selection or option change.

**Write.**

- Internal: render to `<documents>/audio/Saved audio/<name>.wav`, a folder of
  the root that E7-7's Audio library browses (`bx7vK` is a folder browser).
  The `.part`/rename publication is native (4.7).
- USB: render to the internal location, then `copyFile` to
  `Segno/Audio/Saved audio/<name>.wav` under a write lease. That goes through
  `RemovableVolumes` on Library P3, backed by `StorageRepository` once USB P4/P6
  land: `withWriteLease` `storage_repository.dart:232`, `space` `:394`,
  `copyFile` `:484` on `origin/claude/usb-storage-1177-p4` at `a10cd2387`.
  - The internal original is kept. This follows §3.11 "USB export copies a
    finished file; it does not rerender" and §6.8.
  - The drive layout follows Library's `Segno/Performances`, `Segno/Sessions`
    (Library plan `:414-418`).
- **Space (review L8).** Before the render, `space()` is checked on Internal
  for the planned bytes, and for USB also on the drive.
- **Name conflict (review L8).** The audio-library UX doc's choices are
  "Cancel, Rename or Replace file" (`2026-09-07-audio-library-ux.md:39-40`).
  - Rename returns to the naming sheet with the name kept; Replace uses
    `ConflictPolicy.replace`; Cancel keeps the file unsaved.
  - Library's Keep both is not offered here, because the UX doc names Rename
    instead.
- **Success.** The view offers Show in library. Use as backing appears only
  once #1200's backing player exists (it is that issue's action).

**Progress and cancel.**

- While rendering, the Save audio button reads "Saving… N%", and Cancel
  cancels the job. Navigation away cancels too.
- Capture start does not cancel. The job works from its frozen copy, so
  performing during a save cannot change the file.
- This progress state is not drawn in the pen and is listed in §8.

**Listing.** "Saved audio" is a folder in the Audio library browser, not a new
group. It lists name, duration and date, with Library P7's Export to USB row
action.

- Duration comes from `wav_codec`'s header read (#1198 Part 5's bounded reader,
  the one Dart WAV reader).
- Preview and Use as backing are E7-7's and #1200's, through
  `le_backing_decode_file` (PR #1223).
- No new reader appears (review L8).

**Legacy (decision S1).** The trunk's unreachable `exportMixdown/exportStems`
are already re-based by Library P1 (2.1), so this plan does not touch them.

- The bundle `mixdown.wav` written by `save()` (`:495-504`) is a second,
  divergent render: no FX, no pan, mono, mute-gated. Its LCM is also
  uncapped (`session_repository.dart:818-822`), so coprime Free lengths can
  allocate an unbounded buffer (review L7).
- Rule 4 says it should come from this recipe. It is not changed here: its
  consumers (Library P7's Sessions group, P6b audition) are #1178's, and making
  save wait on a render needs that plan's agreement.
- Part 3 files a follow-up issue linking both plans and naming the unbounded
  LCM, rather than silently changing what saved sessions contain (rule 3).

## 7. Foot Bounce surface (Part 6)

### 7.1 Mode and actions

- `InteractionMode.bounce` (label "Bounce"), excluded from `bootDefaults`.
- `ModeAction` token `'bounce'`. There is no `TrackOperation`: Bounce is a
  flow, not a per-track action.
- `toggleMode` returns to `record`, and entering the mode starts the sources
  step with an empty selection (`vBT13`, "Choose tracks below").
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
`assignments()` function in `bounce-performance-study.js`. Captions are given
title / detail exactly as the pen draws them, so the goldens can match (review
L6).

| Pedal | Sources (`vBT13`, `K2Ui7`, `meZ1X`) | Destination (`YPpOv`, `y5o1vy`, `DhyM0`) | Done (`y5k8v`) |
|---|---|---|---|
| Track 1-4 | Track N / "Selected" when selected, "Empty" (dimmed) when empty | Track N / "Replace audio" when occupied, "Empty" otherwise | Track N; the destination reads "Destination" |
| Rec/Play | "Next" / "Choose destination" when the plan is OK, else "Select sources" (dimmed) | "Bounce" or "Replace & bounce" / the destination's name | "Bounce complete" (dimmed) |
| Stop | "Back" / "Sources" (dimmed) | "Back" / "Sources": back to sources, keeping the selection | "Back" / "Sources" (dimmed) |
| Undo | "Undo" / "Nothing to undo", "Whole bounce" or "Tracks changed"; hold = Redo | Same | "Undo" / "Whole bounce"; hold = Redo |
| Clear | "Wrap tails" / "Across loop edge", or "Cut tails" / "At loop edge" | "Keep sources" or "Clear sources" / "After bounce" | "New bounce" |
| Bank | "Bank B" / "Tracks 5–8" (or A / 1–4); the selection persists across banks | Same | "Bank A" / "Tracks 1–4" (dimmed) |
| Mode | "Exit" | "Exit": leaves without applying | "Exit": leaves with the result kept |

- **During `rendering`** (not in the pen; listed in §8):
  - Rec/Play reads "Bouncing" / "N%" and is inert; Stop, Undo and Clear are
    inert.
  - Mode exits and cancels the job; nothing changes.
- **Gestures.** Holding Undo invokes only Redo, and every gesture resolves
  once (`_armGesture` as Fade, `control_foot_fade.dart:11-37`). Capturing
  tracks are unavailable in both steps.
- **Render controls.** The Length row and the plan readout on `meZ1X` sit in
  the route panel on the sources step. They are touch/encoder controls, and
  Tails stays on the Clear pedal. They share the `SelectedRender` model with
  Save audio. The Mix FX row is not shown, and Bounce always renders without
  Mix FX (owner, §11; pen deviation, §8 item 2). The route diagram is not an encoder
  focus target (bounce UX doc).
- **LEDs.** Selected sources, then the destination, are lit in the track
  colour. The slot-less pedals follow accepted contact like Fade
  (`control_projection.dart:255-258`). The mode maps to `PedalMode.custom` in
  the projection and in `invariants.dart`.
- **Notices**, one toast per visit (`tracks_view.dart:138-148`):
  - no common cycle (with or without a tempo);
  - over the length limit;
  - Tracks changed;
  - busy;
  - mode mismatch;
  - plugin effects not included, naming the tracks;
  - a faded-out source;
  - render failed;
  - "Bounce Undo and Redo are not kept in saved sessions" on save.
- **Localization.** English and Spanish strings.
- **Wiring.** Tracks composition (`tracks_view.dart:209-213`), a11y and switch
  arms as Reverse P3.

## 8. Pen deviations to write back (a shipped departure from the pen is a design change)

The pen is read-only for this plan. This item needs owner write-back when it is
built:

1. A transient progress state:
   - "Bouncing" / "N%" on Rec/Play during the render (17, after commit);
   - "Saving… N%" on the Save audio button (18/03, 49).

   The prototype commits instantly; a real render of up to 1024 beats does not.

The "Saved audio" location is drawn (18/03's folder line, and 18/01 is a folder
browser), so it is not a deviation.

2. Bounce has no Mix FX row: remove "Mix FX / Off / All tracks effects" from
   `meZ1X`'s route panel (owner, §11). Save audio (`op31E`) keeps its row.

## 9. Parts

Every part keeps the app working end to end and exposes no unfinished
destination. Parts 1, 2, 4a, 4b and 5 add no entry point; Parts 3 and 6 are the
first to show anything. Sizes are production lines, excluding generated
bindings, tests and docs.

```
Part 1 native recipe ──► Part 2 Dart render seam ──► Part 3 Save selected audio (also needs Library P2 + P7)
      │                          │
      └──► Part 4a native Bounce (keep sources) ──► Part 4b grouped clear sources + fact
                                 │                          │
                                 └──────────► Part 5 Bounce repository ◄┘ ──► Part 6 foot Bounce surface
```

### Part 1. Native shared render recipe (about 700 production lines)

**Files:**

- New `packages/segno_engine/src/core/engine_render.c`:
  - request validation and the span/LCM/cap math;
  - the 112 freeze handler body (called from `apply_command`);
  - staging on the cache tick;
  - the sliced renderer, Pre material (4.3), Wrap/Cut, Once, the frozen read
    law, the frozen Fade, Mix FX;
  - the memory and file targets;
  - measure, begin, poll, copy and cancel.
- New `engine_wav.c` and `engine_wav.h` (4.7, R6), with `perf_render.c`'s two
  writers moved onto it.
- `engine_cache.c`/`.h`:
  - `le_fx_frozen_chain` factoring;
  - the lane-print and track-print functions exposed to the recipe;
  - the recipe job in the pick loop with priority and aging;
  - the shutdown flag readable by the recipe's abort check.
- `engine_process.c`: the 112 case.
- `engine_private.h`: the recipe slot pointer and the freeze record.
- `segno_engine_api.h`: the API of 4.7, `LE_CMD_RENDER_FREEZE = 112`,
  `LE_ERR_NO_COMMON_CYCLE = -16`, `LE_ERR_TRACKS_CHANGED = -17`.
- `engine.c:1523` (refusal list) and `perf_log_ring.h` (`le_log_extract`
  exclusion).
- Every build list that enumerates core TUs: CMake, the podspec forwarders
  under `Classes/`, the SPM target and `run_native_tests.sh`.

**Tests** (new `src/test/test_engine_render.h`, included after
`test_engine_peel.h` at `test_engine_core.c:33568`). Literal PCM through
production entry points, at `sr = 8` and `tempo = 60` (1 beat = 8 frames)
unless noted:

- `test_render_common_cycle_literal`: A = `1..16` (2 beats), and B =
  `100, 200, …` over 24 frames (3 beats). Measure gives 48 frames and
  `beats_milli 6000`. The output is `L[f] = R[f] = A[f%16] + B[f%24]` for f in
  0..47, with all lanes centred at unity.
- `test_render_ignores_transport_mute_solo`: the same rig with A stopped, B
  muted and another track soloed renders identically, bit for bit.
- `test_render_levels_pans_gain`: lane level 0.5, pan +1, track gain 2.
  Literal products through `le_pan_gains` at ±1 and 0.
- `test_render_once_then_silence`: A Once over a 48-frame window gives A for
  f < 16, then 0. A Once relaunched mid-loop (non-zero `playback_offset`)
  plays its single pass from the frame its law reaches index 0.
- `test_render_once_chosen_length` (review D-M1): a span of 30 000 frames on a
  base of 15 000 frames, started at segment 1, rendered for one bar of 38 400
  frames: the pass starts at frame 15 000, runs to the end, and continues at
  frame 0 with the next sample of the pass. A span of 60 000 frames in the
  same bar plays one pass from its start, cut at the window end.
- `test_render_reverse_mid_loop_offset` (review H1): A reversed at a toggle
  mid-loop, with `playback_offset ≠ 0`. Render frame f equals
  `A[le_direction_index(1, offset, f, 16)]` literally, and differs from the
  offset-0 reading.
- `test_render_fade_frozen_amount`: a Fade amount of 0.25 at freeze gives
  ×0.25, and `faded_mask` names the track. A fade moving during staging leaves
  the output unchanged.
- `test_render_origin_phase`: Multi, base 8, A at `k = 2` started at iteration
  0, B at `k = 2` started at iteration 1. A freeze at `I_ref = 2` mid-loop
  reads A segment 0 and B segment 1 at frame 0 (literal values), and the
  freeze applies in the next drain, not at the next top. Free sources start at
  their own lap start.
- `test_render_chosen_length`: 3 bars of 4/4 at sr 8 gives 96 frames. Without
  a tempo the result is `LE_ERR_INVALID`; above `floor(1024/4)` bars it clamps.
- `test_render_no_common_cycle`: spans of 16 and 17 frames with a cap below 272
  give `LE_ERR_NO_COMMON_CYCLE`.
- `test_render_no_tempo_cap` (review M1): tempo bits 0. Equal spans measure
  with `tempo_set = 0`, and spans whose LCM exceeds `512 × sr` give
  `LE_ERR_NO_COMMON_CYCLE`.
- `test_render_pre_is_take` (review M2): a lane with a Pre delay. The Pre
  material equals the cache's published print, byte for byte. Cut keeps the
  Pre echo at frame 0 (it is wrapped at the lane length) and cuts the Post
  delay's.
- `test_render_wrap_vs_cut_tail`: a lane with a Post delay. Cut's first
  `delay` frames equal the dry samples exactly. Wrap's first frames carry the
  tail of the window's end, and Wrap equals pass 2 of a two-window reference
  run.
- `test_render_mix_fx_optional`: with an All tracks chain present, the output
  equals the plain sum with `mix_fx = 0` and the processed sum with
  `mix_fx = 1`.
- `test_render_excludes_buses`: with input signal, monitors on, click on, an
  output FX entry, master gain 0.5 and the limiter on, the render equals the
  render with all of them off.
- `test_render_live_parity`: one PLAYING source routed to outputs 0/1, with no
  gates and a Post chain started cold from a fresh engine. N frames of live
  output from the master top equal the Cut render of N frames,
  sample-exactly.
- `test_render_refusals`:
  - capturing source `NOT_READY`;
  - EMPTY source `INVALID`;
  - second begin `ALREADY_RUNNING`;
  - memory target over `max_frames` `CAPACITY`;
  - over the recipe's own budget `CAPACITY`;
  - no cache worker `UNSUPPORTED`.
- `test_render_staging_tracks_changed`: an overdub admitted while staging
  makes the job `FAILED/TRACKS_CHANGED`. An overdub after staging completes
  leaves the output equal to the frozen material.
- `test_render_cancel_and_shutdown`: cancel mid-render frees everything.
  `le_engine_configure` during a render gives `FAILED/DEVICE` with no leak
  under ASAN.
- `test_render_file_target_wav`: the header bytes are literal (`RIFF`, format
  3, 2 channels, rate, `bits 32`) and the data length is `frames × 8`. The
  `.part` file is gone and the final name exists. A write failure (an
  unwritable directory) leaves no file and reports `FAILED/DEVICE`.
- `test_render_priority_and_aging` (review M7): a long recipe job and a queued
  Pre print for a PLAYING lane. The print publishes before the recipe
  finishes. Continuous re-keyed print jobs cannot hold off a recipe slice past
  the aging limit.
- `test_render_plugin_mask`: a plugin slot in a source chain renders dry and
  sets `plugin_mask` for that track.
- `test_render_reversed_pre_live_parity` (review D-H1): a reversed source with
  a Pre delay. The live output and the Cut render agree, and the echo follows
  the impulse.
- `test_render_whole_track_print`: a track Pre delay with lane pans. The
  render equals the cache's track print of the panned lane sum.
- `test_render_track_post_gain_live_parity`: a track Post delay and track gain
  0.5. The live output and the render agree.
- `test_render_freeze_and_completion_checks`: a source whose length changes
  between begin and freeze, and a revision bumped after the last staged chunk,
  each give `FAILED/TRACKS_CHANGED`.
- `test_render_keeps_published_prints` (review D-M2): a playing lane's engaged
  Pre print survives a recipe begin with the cache at its cap.
- The perf renderer's existing stem tests pass byte-identically on the shared
  writer.
- After PR #1201 merges, `test_render_ignores_speed`: Speed 2× renders
  identically to 1×.

```success-criteria
GOAL: One native executor renders the selected tracks' recorded material over the exact common cycle or a chosen bar length, with levels, pans, gain, frozen Fade, the full live read law, Pre as the take and Post per Wrap or Cut, optional Mix FX, regardless of transport, mute and Solo, without live inputs, click, outputs or master, on the existing render worker, through the one native WAV writer.
SUCCESS CRITERIA:
- Literal oracles hold for the common cycle, the no-tempo cap, transport/mute/Solo independence, levels and pans, Once (including a relaunch), Reverse with a non-zero offset, frozen Fade, phase origin without waiting for a top, chosen length, Pre-as-take, Wrap and Cut, Mix FX and bus exclusion; live parity is sample-exact. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Every refusal (no common cycle, capacity, capturing, empty, busy, tracks changed, already running, unsupported) returns its code and mutates nothing; cancel and configure abort cleanly; the file target publishes atomically with a literal header; perf stems are byte-identical on the shared writer. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Playing-lane prints keep priority and a recipe slice is never starved past the aging limit. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- No callback allocation or blocking; sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- The cache's existing suite is unchanged by the factoring, and the C++17 shim repro from docs/PROGRESS.md compiles. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && manual: run the PROGRESS shim repro
- A long render on the appliance during a playing performance causes no xrun and finishes; worker CPU, wall time and peak bytes against the cache cap for 256 bars of eight tracks with chains are recorded on the issue. | verify: manual appliance run (HARDWARE)
NON-GOALS:
- Dart seam, surfaces, Bounce commit, plugin rendering, Transpose/tempo-follow staging (added by pitch/time parts through the same head and the published SOURCE entry), session mixdown.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2. Dart render seam and `SelectedRender` (about 380 production lines)

**Changes:**

- Bindings regenerated and formatted (`ffigen.yaml`, then `dart format`).
- New `packages/segno_engine/lib/src/selected_render.dart`: `RenderRequest`,
  `RenderPlan` (with the track masks), `RenderTails`, `RenderTarget`,
  `RenderJobStatus`.
- A role interface, `EngineSelectedRender` (`measureRender`, `beginRender`,
  `pollRender`, `copyRender`, `cancelRender`), composed into `AudioEngine` like
  `EnginePerformanceCapture` (`audio_engine.dart:1421`, `:1516-1530`).
- Implementations in `NativeAudioEngine` (the `renderBegin/Poll` FFI pattern,
  `native_audio_engine.dart:2330-2407`), `MockAudioEngine` and the four fakes.
- `EngineResult` gains `noCommonCycle` (-16) and `tracksChanged` (-17)
  (`audio_engine.dart:20-69`).
- In `packages/looper_repository`:
  - `SelectedRender {sources, lengthBars?, tails, mixFx}`;
  - `LooperRepository.measureRender`;
  - `renderToFile(SelectedRender, path)` and
    `renderToMemory(SelectedRender, maxFrames)`, both returning a `RenderJob`
    with `Stream<RenderProgress>` and `cancel()`. Polling follows the recorder
    cubit's timer pattern, and `close()` cancels;
  - `notReady` while `_sessionAudioReserved`;
  - the plan readout as bars and beats from the tempo grid, or seconds without
    a tempo;
  - the plugin, fade and pending track lists.

**Tests:** repository unit tests against the fake (measure mapping, progress
stream, cancel, refusal mapping), plus one actual-native case,
`packages/looper_repository/test/render_native_test.dart` (fixture of
`fade_native_test.dart:12-47`): record two literal loops, render to a temp
file, and decode it with `WavCodec` to the literal sum.

```success-criteria
GOAL: The app can measure and run the shared recipe to a file or to memory, observe progress, cancel, and receive each refusal and warning as its own result, with no surface yet.
SUCCESS CRITERIA:
- Bindings, symbol parity and the seam are complete; fakes and mock implement it. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && /Users/Tomas/development/flutter/bin/flutter test)
- Repository measure, progress, cancel, warnings and refusals behave; the native case decodes the literal sum. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && SEGNO_ENGINE_LIB=$(bash packages/segno_engine/tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository/test/render_native_test.dart
- Static gates stay clean. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
NON-GOALS:
- Surfaces, Bounce, USB copy.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3. Save selected audio (about 600 production lines)

**Depends on:** Part 2, Library P2 (shell) and Library P7 (Audio tab).

**Changes:**

- New `lib/library/save_audio/` with `SaveAudioCubit` and its state: the
  selection, `SelectedRender` options, the plan from `measureRender`, name,
  destination, progress and outcome. Plus the page view.
- The Audio tab's "Save audio" entry: the sub-nav row's Save audio item
  (Library plan deviation 3).
- The "Saved audio" folder.
- Internal and USB writes per section 6, through the `RemovableVolumes`
  port's `withWriteLease`/`copyFile`/`space`.
- Rename/Replace/Cancel conflicts.
- Notices: plugin tracks, faded tracks, no common cycle (with or without a
  tempo), capacity, tracks changed, drive lost, no space, failed.
- l10n EN/ES.
- The follow-up issue for the bundle mixdown (decision S1).

**Tests:**

- `test/library/save_audio/save_audio_cubit_test.dart` covers:
  - recorded tracks preselected, Select all, empty and capturing tracks
    disabled;
  - the plan readout and its errors on change;
  - chosen length −/+ in whole bars, disabled without a tempo;
  - the request Save builds (defaults Common cycle, Wrap, Mix FX Off,
    Internal);
  - progress, and cancel on Cancel and on close;
  - USB copies the finished internal file and never re-renders (the fake
    engine counts `beginRender` calls);
  - space checked on both volumes;
  - Rename/Replace/Cancel;
  - drive lost;
  - capture start does not cancel;
  - plugin and fade warnings name the tracks.
- `save_audio_page_test.dart`, with goldens matching `M9kyGb`, `o32NQJ` and
  `op31E` in English and Spanish.
- A listing test for the Saved audio folder.

```success-criteria
GOAL: From Library > Audio, the player saves the selected tracks as one WAV in Saved audio on Internal or USB with the shared recipe's length, Mix FX and tails, names it, sees progress and warnings, can cancel, and finds the file under Saved audio.
SUCCESS CRITERIA:
- Cubit behavior for preselection, plan, defaults, warnings, progress, cancel, conflict, space and drive loss matches section 6; USB is a copy of the finished file. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Page goldens match pen 18/03, 18/04 and 49 Save audio in English and Spanish. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library/save_audio
- Static gates and the whole suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- On the appliance, a saved file plays back in the Audio list and on a computer from the USB drive; unplugging mid-copy keeps the internal file and reports the drive. | verify: manual appliance run with a USB drive (HARDWARE)
NON-GOALS:
- Audio library browse/preview/backing (E7-7, #1200), session mixdown, DAW export (Library P7).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 4a. Native Bounce with Keep sources: install, reset, topology, Undo/Redo (about 620 production lines)

**Changes:**

- `LE_HIST_BOUNCE = 5` and the `group_id`/`cleared_mask` fields in
  `le_hist_entry` (`engine_private.h:783-820`).
- `le_mode_base_channel_excluding`.
- `le_engine_bounce` admission (5.2) for `cleared_mask = 0`, including the
  prepared topology.
- The 113 handler (5.3, steps 1-3, 5 and 6).
- `le_engine_bounce_recover` with 114, for the destination alone.
- The export cut, undo and redo sides (5.4).
- The mode-gate projection, and refusal of plain undo/redo on grouped entries.
- Bounce added to the `le_push` refusal list.
- Staged image ids for #1143.
- `LE_CMD_BOUNCE = 113`, `LE_CMD_BOUNCE_RECOVER = 114`.

**Tests** (`test_engine_bounce.h`; literal PCM; the render result comes from a
real Part 1 job):

- **Install.**
  - Empty destination: Bounce installs `L`/`R` literal into lanes 0/1,
    STOPPED, with `len`, `multiple` and divisor correct.
  - Occupied destination: Bounce replaces it.
  - Destination equals a source: replaced.
- **Undo.** Undo restores the exact previous samples, length, multiple, image
  pans, gain, levels, mutes, inputs, outputs, Fade amount, direction and
  state. The added lane plays and records nothing while Redo holds it, and the
  lane count returns once Redo retires. Redo re-applies everything.
- **Topology through the structural path (review H4).**
  - A one-lane PLAYING destination grows to two lanes in the 113 drain with no
    out-of-bounds read under ASAN.
  - A pending lane-count change refuses `NOT_READY`.
- **Reset.**
  - Gain 1, levels 1, pans 0, image pans ∓1, Fade 1, forward, chains empty,
    all through the bundle in the same drain as the image.
  - A probe at the apply frame shows no block where the image plays through
    the old chains.
  - `le_transform_reset` precedes the publish, and 322 names the new image for
    a destination that was occupied at arm (review L3).
- **Mode.**
  - Multi with a chosen length that is not a multiple gives `MODE_MISMATCH`.
  - A sole-content destination with `L` a multiple of the base keeps the
    master and the running clock (`loop_iteration` unchanged); an `L` that
    does not fit re-clocks at the mapped phase with `loop_iteration` kept.
  - A Sync division result.
  - Free/Song: own clock.
- **Phase.** With `start_iter = I_ref`, a destination later set PLAYING is in
  phase with a kept source (literal).
- **Refusals.** Busy, tracks changed (overdub after render), capacity,
  undo-stack full. Each releases its slot and mutates nothing.
- **History.**
  - A layer overdubbed on top of the destination is undone first by Undo.
  - Bounce Undo with a newer edit on top is refused `TRACKS_CHANGED`.
  - Plain undo of a grouped top is `INVALID`.
  - Peel is blocked above BOUNCE (test only, review L2).
- **Export and recall (review H6).**
  - `export_history` stops below the undo-side BOUNCE.
  - Bounce, Undo, export: no kind 5 and no grouped entry on the redo side.
  - Both round trips recall through Peel P2's `finalize_history` and play the
    expected base.
- **Reopen.** An unapplied 113 drops the track with the mask.
- **Raw posts.** Both new commands are refused.

```success-criteria
GOAL: A rendered result replaces or fills one destination track in one callback drain with its processing and lane topology reset through the structural path, one Undo or Redo restores or re-applies exactly that destination, and no saved session can carry an unopenable or split entry.
SUCCESS CRITERIA:
- Literal install, replace, Undo and Redo restore samples, length, multiple, lanes, routing, image pans, mix, fade, direction, chains and state exactly; the reset lands in the same drain as the image. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Mode fit, kept clock, re-clock, phase origin, refusals, history order, both export cuts with a recall round trip, provenance and reopen behave as specified. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer, telemetry-off and the C++ shim repro pass; bindings regenerated. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test)
NON-GOALS:
- Clear sources, the group across tracks, Dart orchestration, surface.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 4b. Clear sources as one native group, the Bounce fact and the log version (about 420 production lines)

**Changes:**

- `cleared_mask` admission: CLEAR points filed with `group_id`, with the push
  deferred into 113.
- `handle_clear` for each member after the destination install, with the Wrap
  tail flush (5.3 step 4).
- `start_playing`.
- The intact check and all-member application in 114.
- The redo-side mirror, and group-wide redo retirement (M8).
- `LE_PLOG_BOUNCE = 332`, the events.log version bump to the next free number,
  and the format-doc row (`docs/design/performance-event-log-format.md`).
- The follow-up issue: Clear All onto the native group.

**Tests:**

- **Clear sources, two playing sources** (shared-clock modes; review L5). Over
  the commit block the output continues sample-exactly from the sources into
  the destination. No frame has both sounding or neither sounding (literal:
  the output equals the render buffer at the mapped phase from the apply
  frame). The destination is PLAYING. With no source playing, it is STOPPED.
- **Every content track into an empty track (review H2).** All recorded tracks
  are bounced into an empty track with Clear sources while playing. The master
  is kept, `loop_iteration` and the click grid continue, and there is no phase
  jump.
- **Tails (review H3).**
  - Wrap with a Post delay on a source: after commit, only the destination's
    baked tail sounds (literal).
  - Cut: the source's live tail drains, and the destination starts dry.
- **One Undo** restores every source's layers, length and playing or stopped
  state, and the destination, in one drain (probe frame). Redo re-clears.
- **Newer edits.** A newer edit on any member (record on a cleared source,
  overdub on the destination, Peel, a length edit after M/D) refuses the group
  with `TRACKS_CHANGED` and changes nothing. Undoing that edit makes the group
  undoable again.
- **Stale redo (review M8).** Bounce, Undo, a new edit on the destination:
  every source's grouped Redo is retired, and its `a_redo_depth` republishes.
- **Whole-operation refusals.** A busy member, or `undo_count` full on one
  member, refuses the whole bounce.
- **Saving a source (review H6).** Bounce, Undo, save a source: no grouped
  CLEAR is exported, and the recall round trip plays the restored source.
- **Capture.** The 332 record and its version, the clears logged raw, and the
  destination 322. Stems pass parity for lane 0.
- **Reopen** with an unapplied 114.

```success-criteria
GOAL: Bounce with Clear sources publishes the destination and every source clear together, with one tail and no master reset, and one Undo or Redo of the whole operation publishes together, refusing rather than overwriting newer dependent edits and retiring stale group redo everywhere.
SUCCESS CRITERIA:
- The commit and the group recovery each land in one drain with sample-exact continuity in shared-clock modes, including the every-track-into-empty case; destination playing state follows the accepted rule. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Wrap leaves one tail and Cut lets source tails drain; newer edits refuse the group with TRACKS_CHANGED and mutate nothing; stale group redo retires on every member; capacity and busy refusals are whole-operation. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The 332 record, the version bump and the format-doc row are present; sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
NON-GOALS:
- Moving Clear All onto the group (follow-up), surface.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 5. Bounce repository and engine seam (about 520 production lines)

**Changes:**

- `AudioEngine.bounce/bounceRecover` (`RequestAdmission`, carrying a
  `MixSettings` topology) in native, mock and the fakes; bindings.
- `LooperRepository.bounce(BounceRequest {render: SelectedRender,
  destination, keepSources})`, `undoBounce`, `redoBounce`, `lastBounce` (the
  group the surface shows) and `BounceOutcome`.
- The orchestration of 5.5:
  - the snapshot of the full `_MixIntent` rows;
  - the topology with the H5 input rule;
  - the empty and restore recipe bundles;
  - the commits to `_MixIntent` and `_laneBasePan`;
  - `undo()`/`redo()` routing for members;
  - refusal mapping;
  - cancel on Exit.
- The save-time drop notice (5.4).

**Tests:**

- **Repository, against the fake:**
  - the request sequence (measure → begin → poll → bounce);
  - snapshot contents;
  - the mix intent after the receipt: Mixer shows unity; `counts`,
    `balances`, `inputs` and `routes` hold the bounce;
  - a replayed mix (reopen or configure) re-sends the bounced topology, not
    the old one (review H4);
  - `_laneBasePan` set and restored;
  - after a bounce into a one-lane mono track, an overdub records input `i`
    into both lanes and plays centred, with no other input armed (review H5);
  - member Undo routes to the group;
  - refusals map to `RecoveryRefusal`;
  - Exit before commit leaves the engine untouched;
  - the save drop notice.
- **Actual-native, `bounce_native_test.dart`:**
  - two literal loops bounced with Clear sources, then Undo and Redo, with
    exact first samples through `exportLayer`;
  - Bounce, Undo, save, recall for the destination and for a source.

```success-criteria
GOAL: The repository bounces through the shared recipe with one admission, keeps the Mixer, the mix intent, lane topology, recording routing and future overdubs consistent with the reset across replays, and exposes one grouped Undo/Redo that every track entry point honors.
SUCCESS CRITERIA:
- Fake-engine sequences, snapshots, intents, replay, base pans, the overdub-after-bounce rule, routing and refusals behave as specified. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test)
- The actual-native round trips restore and re-apply exact samples and recall after Undo. | verify: SEGNO_ENGINE_LIB=$(bash packages/segno_engine/tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository/test/bounce_native_test.dart
- Static gates and the whole suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
NON-GOALS:
- Surface, mappings.
VERIFICATION COMMAND: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 6. Foot Bounce surface (about 650 production lines)

**Changes:** everything in section 7:

- mode, model, actions, cubit part;
- the view, with the route panel and render controls;
- LEDs and the physical mask, invariants;
- Tracks composition, notices;
- l10n EN/ES;
- a11y and switch arms;
- the `control_action.dart:15-20` comment updated.

**Tests:**

- `test/control/foot_bounce_dispatch_test.dart`:
  - track pedals toggle sources across both banks;
  - Next is enabled only with a valid plan;
  - selecting a destination changes nothing until commit;
  - "Replace & bounce" on an occupied destination;
  - Back keeps sources;
  - Clear toggles Wrap/Cut, then Keep/Clear, then New bounce;
  - Undo, with hold for Redo only;
  - Exit before commit cancels the job and changes nothing;
  - capturing tracks are inert;
  - each refusal and warning shows its notice once;
  - the rendering state is inert except Mode.
- `foot_bounce_projection_test.dart` for the LEDs.
- `test/looper/view/foot_bounce_view_test.dart`, with goldens for the six pen
  17 screens and `meZ1X`, using the captions of 7.2.
- The journey (select sources across banks, Replace & bounce, Clear sources,
  Undo, Redo) as a repository sequence test.

```success-criteria
GOAL: The accepted foot Bounce flow selects sources across banks, then a destination, then commits Bounce or Replace & bounce with visible Keep/Clear sources and Wrap/Cut tails, shows progress, and undoes or redoes the whole operation by foot.
SUCCESS CRITERIA:
- Pedal roles and captions per step match the accepted table and the pen; selection alone changes nothing; Exit before commit changes nothing; holds resolve once. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- LEDs and the face are truthful; goldens match pen 17/01-06 and 49 Bounce (without its Mix FX row, §8 item 2) in English and Spanish. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Static gates and the whole suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- On the appliance, by foot only: bounce three tracks across banks into an occupied track with Clear sources while playing, with no audible gap, doubling or doubled tail, then Undo and Redo, with LEDs correct per step; repeat with Keep sources (the destination stays stopped) and with Cut tails on a delay; overdub on the bounced track with a mono mic and hear it centred. | verify: manual appliance session per docs/PROGRESS.md hardware evidence rules (HARDWARE)
NON-GOALS:
- Assignable single-action Bounce outside the mode, Clear All migration, pen edits.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

Each part runs the normal, ASAN and telemetry-off native suites where native
code changes, `dart analyze --fatal-infos` and `bloc lint`, and gets
independent architecture, test and adversarial review before the human merge
gate. Stop for review on any of these:

- an audio-thread allocation;
- a second index or seam law;
- a print fed into a Pre entry;
- a group member published in a separate drain;
- a lane count written outside the structural path;
- a new Dart owner beyond `SaveAudioCubit` and the foot model.

## 10. Decisions taken under the standing rules

- **R1 (rule 4).** The recipe is a new job kind on the wet-cache worker. It
  shares the frozen-chain snapshot, the lane and track print functions, heap
  FX state, staging and the two-pass rule, and has an explicit priority with
  aging. It keeps its own byte budget so it never evicts a live print
  (4.7). `perf_render.c` is not reused: it is a log replay of
  elapsed time, lane-0 and gated.
- **R2 (§3.5).** Pre is the take: each lane's Pre material is its print,
  wrapped at its own length, made by the cache's function. A track's Pre is
  printed only where the live rig prints it. Pre is never applied twice.
- **R3 (rules 2, 3).**
  - The freeze applies in the next drain and records each source's complete
    read law (segment, direction, `playback_offset`, Once state, and the
    read-head phase after P2a).
  - Render frame 0 is the top of the current iteration, so a render starts at
    once and every source keeps its live phase.
  - The Bounce destination continues that phase against the preserved
    `loop_iteration`.
- **R4.** Tails apply to window stages only. Wrap (default) renders the window
  twice and keeps the second pass; Cut renders once from cold Post states and
  keeps the Pre wash.
- **R5.** Speed is not printed (it is global and applied once after). Tempo
  follow, Transpose (from the published SOURCE entry when that is what plays),
  Reverse and Fade are printed as heard, with Fade frozen. The destination
  resets them.
- **R6 (rules 3, 4).**
  - Plugins render dry, with a notice naming the tracks.
  - Faded sources render at their amount, with a warning naming them.
  - Sums are not limited.
  - The output is float32 stereo through one native WAV writer shared with
    `perf_render.c` and #1198's part streams.
- **R7 (rule 2).**
  - The cycle is the exact integer-frame LCM within 1024 beats, or within 512
    seconds without a tempo. It refuses rather than rounds, with a notice that
    says what to do.
  - Chosen length is in whole bars and is unavailable without a tempo.
- **B1 (rules 2, 4).** Bounce and its group Undo/Redo each apply in one ring
  command, with the group recorded natively. Clear All moves onto it in a
  follow-up, not silently here.
- **B2.**
  - **Order:** transforms reset, then the destination installed, then the
    sources cleared. The rig never reads all-empty inside a bounce, and the
    clock keeps running unless `L` does not fit the kept base.
  - **What resets:** gain, levels and pans (unity, centre, stereo image ∓1),
    mute, Fade, direction, Transpose and all chains, landing in the same drain
    as the image.
  - **Lane topology** changes through the structural path, inside the drain.
  - **What stays:** Solo, track routes and Loop/Once.
  - **Undo** restores everything the reset changed; an added lane stays silent
    and unrouted until Redo retires.
- **B3 (§2.11).** A group whose member has a newer edit is refused, never
  overwritten. A single-member undo is routed to the group, and a retired Redo
  retires the whole group's Redo.
- **B4 (rules 1, 5).** Saved sessions keep the bounced take as the base. Both
  export sides drop BOUNCE and grouped entries, with a notice, so no session
  becomes unopenable or splits a group. No schema bump.
- **B5 (rules 1, 3; review H5).** The destination is always stereo, two lanes
  with L/R image pans.
  - Recording routing keeps what the player records: a multi-lane destination
    keeps its inputs; a one-lane destination's new lane mirrors lane 0's input,
    so a mono overdub lands centred.
  - No new hardware input is armed.
  - `_laneBasePan` keeps the image on later overdubs, and every mix replay
    re-sends the bounced topology.
- **B6 (review H3).** With Wrap and Clear sources, the cleared sources' lane
  and track Post tails are cleared in the commit drain, because the destination
  carries them. With Cut they drain.
- **S1 (rules 3, 4).**
  - Save audio preselects the recorded tracks and writes to the "Saved audio"
    folder, as the pen draws it.
  - It writes to Internal first and copies to USB.
  - Name conflicts offer Cancel, Rename or Replace (UX doc).
  - The bundle mixdown's move onto the recipe is a follow-up shared with #1178.
- **N1.** Numbers come from the central ledger:
  - used: 112-114, 332, −16, −17 and history kind 5;
  - held unused: 115 and 333-335;
  - the events.log version is the next free number at landing.

## 11. Owner decisions

**Mix FX in Bounce (review M3; owner, 2026-10-06).** Bounce renders without
Mix FX and does not show the row. Save audio keeps it.

- With Mix FX on, a bounce would bake the All tracks chain into the
  destination, and the live chain would then process the destination again,
  breaking AB §3.11's "not printed twice".
- With Mix FX off, the destination plays through the live chain once, as its
  sources did.
- A file has no live chain after it, so Save audio offers the choice.
- This is a pen deviation for `meZ1X` (§8 item 2) and adds no engine state.
  The native request keeps `mix_fx`; Bounce always passes 0, and Part 5's
  `BounceRequest` has no Mix FX field.

Fade, plugins and the mono destination were answered by the owner on the same
day (4.2, 5.5 and 10 B5).

## Build record

### Part 1 (`claude/render-1202-p1`, on trunk `097e1ef68`)

The part is two commits, to keep review manageable:

1. `refactor(engine)`: the shared WAV writer and the cache's offline chain
   factoring, with no behaviour change. It was verified on its own: the plain
   native suite passes at that commit.
2. `feat(engine)`: the recipe.

Where the build departs from the text above, and why:

- **File names.** The writer is `engine_wav.c`/`engine_wav.h` and the recipe
  is `engine_render.c`/`engine_render.h`. Both match the `engine*.c` globs in
  `run_native_tests.sh` and `build_test_lib.sh`, so no test list changed. The
  macOS forwarders (CocoaPods and SPM) and `src/CMakeLists.txt` list them.
- **Directory sync.** #1198 Part 1 (#1220) merged before the build, so
  `le_wav_publish` already syncs the directory with `le_fs_sync_dir`.
- **The freeze record is engine-owned**, not a per-job record:
  `le_engine.render_freeze`, keyed by job id. A stale command for a cancelled
  job can then never write into freed memory, and a newer job's record is
  never touched.
- **Staging checks the content first.** It checks the revision, slot and
  state before the readable gate, so a cleared or recording source fails with
  `TRACKS_CHANGED` at once instead of waiting on a gate that never opens.
- **One chain struct, not three.** `perf_render.c`'s `le_pr_fx_chain` is not
  converted to `le_fx_frozen_chain`: it is mutated by the log replay entry by
  entry. The cache and the recipe share the frozen chain, the state seeding
  and the print. The perf renderer shares the writer.
- **Aging is tested as a pure function.** The worker's priority and aging
  rule is `le_render_worker_choice`, unit-tested directly instead of through a
  timing race.
- **Plan tests not built as listed (review D-L2).** The first build record
  named only the first two of these:
  - `test_render_ignores_speed` waits for pitch/time P2a.
  - The Once relaunch is covered through the shared read law, by the
    non-zero-offset Reverse test, and the wrap by
    `test_render_once_chosen_length`.
  - `test_render_excludes_buses` adds one output FX entry and one input
    block. Monitors, the click, master gain 0.5 and the limiter are not in
    it.
  - `test_render_pre_is_take_and_tails` checks the Wrap/Cut difference by
    energy, not by equality with pass 2 of a two-window run.
  - `test_render_fade_frozen_amount` does not move the fade during staging.
  - `test_render_origin_phase_multiples` has no Free source.
  - `test_render_staging_tracks_changed` uses a Clear while staging, not an
    overdub admitted while staging.
- **Memory.** The first build charged the job to the cache's byte cap. The
  review round replaced that with the recipe's own budget (4.7).
- **Size.** About 1,300 production lines (code, headers, API and build
  lists), against the plan's 700:
  - commit 1, about 300;
  - `engine_render.c`, about 800 code lines.

  The recipe does not split further without leaving a half-wired API.

Verification:

- **Native suite.** Plain, ASAN and telemetry-off runs pass, each in its own
  `TMPDIR`. 19 new `test_render_*` cases are included.
- **Mutations.** Each failed its test:
  - freeze offset forced to 0;
  - print reduced to one pass;
  - aging removed;
  - Wrap forced to one pass.
- **Dart and lint.**
  - `segno_engine` package suite passes (376) with `SEGNO_ENGINE_LIB`.
  - The full app suite passes (3,469).
  - `dart analyze --fatal-infos lib test packages` is clean.
  - `bloc lint` is clean.
- **Bindings.** Regenerated and formatted.
- **C++ shim.** The `-U__clang__` repro compiles.
- **Symbol parity.** `check_ffi_symbols.sh` is ELF-only. A manual `nm`
  comparison on macOS shows every new binding exported. Linux CI runs the real
  check.
- **Not run.** The appliance criterion (no xrun, worker CPU and peak bytes) is
  hardware and still open.

### Part 1 review round (PR #1238 review and plan delta review)

A third commit (`fix(engine)`) answers both reviews:

- **H1 / D-H1, reversed Pre.** A first setup unit lays each reversed source's
  staged dry in read order. Lane and whole-track prints are made from it, and
  the window reads them forward at the lap phase (4.3). New test:
  `test_render_reversed_pre_live_parity`.
- **M1 / D-M2, prints never evicted.** The recipe has its own budget,
  `LE_RENDER_BUDGET_BYTES` (256 MiB); `le_cache_reserve` and
  `le_cache_release` are gone. When a job finishes, the tick frees its staged
  dry, prints, states and slice buffer; a DONE memory job keeps only `out`.
  New test: `test_render_keeps_published_prints`.
- **M2, shutdown.** The recipe's abort check also reads the cache's shutdown
  flag (`le_cache_shutting_down`). New test:
  `test_render_configure_mid_print`.
- **M3 / D-M1, Once.** The pass phase rule of 4.4. New test:
  `test_render_once_chosen_length` (a window not a multiple of the span, and
  one shorter than it).
- **M4, coverage.** New tests: `test_render_whole_track_print`,
  `test_render_track_post_gain_live_parity` and
  `test_render_freeze_and_completion_checks`.
- **L2.** The measure comment now says what is refused (4.7).
- **L3.** `le_wav_publish` returns 2 when the rename succeeded and only the
  directory sync failed; the job reads DONE.
- **L4.** The writer takes #1198 Part 2's (PR #1245) extensions as built
  there: the close-on-exec open through a descriptor and `le_wav_note_frames`.
  It adds the two calls the capture drain and its recovery need, so #1245
  rebases onto this part without reaching into the writer:
  - `le_wav_flush` hands every appended sample to the OS each drain cycle,
    leaving the file open and unsealed;
  - `le_wav_patch_sizes` repairs a part that was never sealed, or cuts it
    back to a checkpoint's frames: it keeps the whole frames (a torn last
    frame is dropped), truncates the rest, patches both sizes and fsyncs.

  The existing calls keep their signatures. An odd caller chunk size is
  refused. New test: `test_wav_flush_and_patch_sizes`.
- **L5.** The job charges its effect states, and `le_fx_print` prepares only
  the entries it runs.
- **L6.** Answered by the own budget: an eight-track set of 30 s loops fits.

### Part 2 (`claude/render-1202-p2`, stacked on Part 1)

One commit (`feat(looper)`). Where the build departs from the text above:

- **Measure ignores the target.** `measureRender` sends a memory-target
  request because the native measure refuses a file target without a path.
  The plan does not depend on the target.
- **Memory jobs.** A memory job keeps its result in the engine after it
  finishes, so Part 4a's Bounce can consume it in place by job id. The caller
  releases it, or the next render replaces it. `RenderJob.copySamples` reads
  it for previews and tests.
- **File jobs.** A file job is released as soon as its file is published.
- **The mock engine** (UI development without hardware) models no PCM, so
  every render call answers `unsupported` rather than inventing audio.
- **Size.** About 900 library lines including documentation and value
  equality: the `segno_engine` seam and the `looper_repository` model, job and
  methods.

Verification:

- **Tests.**
  - New `segno_engine` unit and native tests: the literal common cycle into
    memory, a stereo float file, and the refusal and `tracksChanged` mapping.
  - New `looper_repository` fake-engine tests: the plan readout, refusals, the
    Session gate, progress, file release, memory keep and release, failure,
    an unknown job, cancel, and dispose.
  - A native repository test: two literal loops render to a WAV that decodes
    to their sum.
- **Mutations.** Each failed its test:
  - the Session gate removed;
  - the file release removed;
  - the dispose cancel removed;
  - the -17 mapping removed.
- **Suites and analysis.**
  - `segno_engine` 388, `looper_repository` 819, `performance_repository`,
    `session_repository` and the app (3,469) pass with `SEGNO_ENGINE_LIB`.
  - `dart analyze --fatal-infos lib test packages` is clean.
  - `dart format` changes nothing.
  - `bloc lint` is clean.
