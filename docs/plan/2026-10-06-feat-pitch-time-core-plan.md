# Pitch and time core: Speed, Transpose, Audio & tempo follow, import Adapt

<!-- cspell:ignore varispeed lerp lbuf wdub Signalsmith signalsmith -->

Status: plan for owner review (merging this plan approves its direction);
implementation not started. Part 1 is a measured CPU spike whose numbers gate
the rest.
Tracking: #1179 (parent #1026; gap inventory E4-1, serving E6-4 Speed, E6-5
Transpose, E4-2 Audio & tempo, E7-9 import Adapt), `autonomy:merge-gate`.
Source baseline: `origin/claude/segno-integration` at `c3714abc2`. Every
`file:line` below is on that head unless a branch is named.
Precedents: Foot Fade ([plan](2026-10-04-feat-foot-fade-plan.md)), Foot
Reverse (`origin/claude/reverse-plan-1162:docs/plan/2026-10-05-feat-foot-reverse-plan.md`),
the whole-track render boundary
(`docs/design/2026-09-10-whole-track-pre-render.md`), the stem provenance plan
(`2026-10-05-feat-stem-history-replay-plan.md`), the engine reopen plan
(`2026-10-05-feat-engine-reopen-plan.md`), and the July stretch spike
(`2026-07-22-time-stretch-spike-findings.md`).

## Accepted behaviour

- `docs/handoff/segno-app/accepted-behavior.md:303` Speed: "Whole recorded loop
  uses absolute ½×, 1×, 2×, 4× or 8×; speed couples pitch. Repeated 2× stays
  2×. Normal restores only that factor. Live inputs/backing/click are
  unaffected."
- `:299` Transpose: "Select tracks across banks; Undo/Clear lower/raise one
  semitone; hold either resets selection. Range ±12; timing unchanged. Global
  bypass preserves stored pitches and selection. Exit retains changes."
- `:135-139` (§2.6): "Audio & tempo independently owns Follow tempo and pitch
  preservation. Following On changes playback with song tempo and offers
  Unchanged pitch or Follows speed. Following Off preserves original-time
  playback and shows unchanged pitch; the stored pitch-follow preference
  returns when reenabled. Manual Speed and Transpose are independent
  contributions, not resets of these preferences."
- `:145-146` (§2.8): Sync/Band capture follows the primary cycle "independent of
  that track's audible Speed, Reverse, Once or Follow setting".
- `:436-442` (§6.5): import offers "Use file tempo, Adapt to loop tempo and Leave
  unchanged"; unknown tempo needs confirmed bars; "External clock requires Adapt
  and usable clock"; the imported track starts stopped.
- `:418-419`: New Loop "resets track performance transforms such as
  mute/fade/reverse/transpose/global Speed".
- `:160-166` (§2.10): the audio-edit history holds recording, overdub passes,
  length edits, Peel and Clear; Speed and Transpose are performance transforms,
  not audio edits.
- `:568` (§8 gate): "Actual codec/stretch/render limits, CPU/polyphony
  budgets" are a genuine gate: "Implement and measure against the accepted UX;
  simulation bounds are not automatically production limits."
- `docs/handoff/segno-app/implementation-map.md` ("Material mismatches"): Speed
  and Transpose "do not have corresponding named engine entry points";
  "establish each operation's native contract rather than treating a UI mode
  as audio implementation"; slice 4: "one complete native operation at a time".
- `docs/design/2026-09-10-whole-track-pre-render.md` ("Playback transforms"):
  "The accepted direction for Speed is to stream from originals inline, which
  composes with a render from originals: both read the same recordings."

Pen screens the work must match (`segno-ui.pen`, group `01 CURRENT UX`):

| Section | Screen (id) | Serves |
|---|---|---|
| 15 Performance · Speed | `01 / Speed / Normal` (SO34L), `02 / Half speed` (Q29ROp), `03 / Eight times` (jY5NQ), `04 / Empty loop` (YMPRG), `05 / Tracks / Speed indicator` (usAz6) | Parts 2, 6a |
| 11 Performance · Transpose | `01 / Transpose` (k5GTy), `02 / across banks` (yBmpo), `03 / with no selection` (JTxQq), `04 / at pitch limit` (lpGO0), `Transpose bypass · pitches retained / Tile` (FJ8Ys) | Parts 3, 6b |
| 07 Playback, decay & audio tempo | `04 / Audio tempo defaults` (reN7g), `05 / Pitch follows speed` (MfjIH), `06 / Keep recorded speed` (hujmY); `07 / Audio follows MIDI tempo` (JQpGt) is E8-1's and only consumes this plan's seam | Part 4 |
| 18 Audio library, backing & import | `12 / Track import / Choose destination` (taRWd), `13 / Ready to load` (c6CBav), `14 / No empty tracks` (akxOj), `15 / USB source` (HaVqw): the "Adapt to loop tempo · 84 BPM · keep original pitch" choice | Part 5 (seam only; the flow is #1178 / E7-9) |

Facts the screens fix: Speed is one factor for "All recorded tracks"; the
Speed face shows the derived pitch ("½× … Pitch −12 st … Loop duration 2×";
"8× … +36 st … 1/8"); the Tracks face carries a "Loop speed 2×" marker;
Transpose shows per-track semitones, a "Hold · Bypass" / "Hold · Enable" state
and "Track 1 · Stored +2 st" while bypassed; Audio & tempo is a Loop-settings
page with the Tracks/Defaults/1–8 scope selector, Follow tempo Off/On and Pitch
Unchanged/Follows speed with the Default/Custom/Use default inheritance grammar.

## What the engine does today (file:line)

- The mixer reads every lane of a track at one shared integer coordinate:
  `loopsample = lbuf[seg_base[t] + trk_pos[t]]` (`engine_process.c:5833`).
  `seg_base` is the multiple's segment from `loop_iteration` and `a_multiple`
  (`:5523-5534`), `trk_pos`/`trk_len` default to the master position/length
  (`:5548-5552`), overridden per track for Free/Song
  (`free_track_positions_frame`, `:5295-5304`) and Sync divisions
  (`sync_division_positions_frame`, `:5349-5372`, `trk_len = base / n`,
  `trk_pos = pos % len`).
- One per-track read origin exists, `le_track.playback_offset`
  (`engine_private.h:1272`), consumed by `le_shared_track_position`
  (`engine_process.c:121-134`) and re-applied to the `(seg_base, trk_pos)`
  pair for PLAYING/OVERDUBBING tracks at `:5569-5578`. Set by Once's relaunch
  (`le_restart_once`, `:136-149`), reset by `le_reset_track_playback`
  (`:114-119`).
- Playhead publication: `trk_play_pos[t] = seg_base + trk_pos` (`:5582-5585`)
  -> `a_play_pos` (`:6656-6662`) -> `le_track_snapshot.position_frames`
  (`segno_engine_api.h:903`).
- Lap-top edges: whole-track print engages at `trk_rp == 0` (`:5762-5775`),
  lane print at `rp == 0` (`:5913-5918`), Once lap end at
  `le_shared_track_position == 0` (`:4486-4510`), Free/Song Once at the private
  clock wrap (`advance_track_clock_frame`, `:4454-4463`).
- The seam crossfade is baked at finalize (`le_seam_fold`, `:1016`;
  `seam_xfade_frames = sr/100`, `:982`), so `len-1 -> 0` is continuous and a
  wrapping interpolated read needs no runtime seam work.
- Capture writes are integer and forward: the record head `rec_w`
  (`:5698-5715`), the overdub head `wdub = seg_base + comp_pos(trk_pos,
  dub_offset, trk_len)` (`:5716-5728`) with backup-on-write into the shadow
  (`:5840-5853`), latency compensation `a_record_offset` (`:5518`).
- The gain stage multiplies the lane pair by `a_gain_bits * fade_sample`
  (`:5960-5964`, `:6051`); Fade ticks per device frame (`le_fade_tick`,
  `engine_fade.h`; `:6492-6495`).
- The transport advances one musical frame per device frame:
  `mix_tracks_frame(...)` at `:6542` then `advance_transport_frame` at `:6594`,
  inside `le_engine_process`'s per-frame loop (`:6150`). The shared clock is
  `le_loop_clock {int32_t length, position}` (`loop_clock.h:17-20`).
- Tempo is LOCKED while content exists and a grid is live (`le_tempo_locked`,
  `:411-423`; API doc `segno_engine_api.h:2003-2008`): `LE_CMD_SET_TEMPO` is a
  no-op then (`:3119-3133`), otherwise it stores the BPM and re-derives the bar
  count for the fixed master length (`regrid_surviving_master`, `:826-838`).
  The recorded tempo is nowhere latched: `a_tempo_bpm_bits`
  (`engine_private.h:1603`) is the current song tempo.
- Playback-source renders exist for FX only: the wet cache renders a lane's Pre
  prefix from the dry pool into `le_wet_entry {audio_rev, chain_fp, vol_bits,
  len, pcm (2*len stereo)}` (`engine_private.h:427-434`), with ONE key predicate
  (`le_wet_entry_key_matches`, `:443-449`), one render worker, one memory cap
  (`LE_CACHE_DEFAULT_CAP_BYTES` 64 MiB, `segno_engine_api.h:2730-2734`;
  `le_engine_set_cache_budget`, `:2793`), one settle debounce
  (`LE_CACHE_SETTLE_MS` 250, `engine_cache.h`), scheduled from
  `le_cache_tick` (`engine_cache.c:1406`), collected by `le_cache_collect`
  (`:537`), verified per buffer by `snapshot_lane_cache` /
  `snapshot_track_cache` (`engine_process.c:4939-5009`), and played at the
  integer read index (`:5929-5937`).
- Offline DSP already runs on a control-side worker with pure TUs
  (`restore_declip.c`, `restore_halfband.c`: a 2:1 half-band resampler;
  `engine_restore.c`), listed explicitly in CMake (`src/CMakeLists.txt:84-85`)
  and `run_native_tests.sh:70-73`.
- Session import fills an EMPTY track's lane directly on the control thread
  (`le_engine_import_track_lane`, `engine_session.c:64-140`; `import_track`
  `:142-145`; Dart `AudioEngine.importTrack/importTrackLane`,
  `audio_engine.dart:1227-1236`), rejecting frames above the cap (`:99`).
- Signalsmith Stretch 1.1.0 (MIT, commit `44c8f865`) is vendored under the
  bench only (`packages/segno_engine/src/test/bench/third_party/signalsmith-stretch/`,
  header-only C++), with the D0 harness `bench_stretch.cpp` (`StretchStream`
  `:125-170`, `VarispeedStream` `:172-196`) built by `bench.sh` outside the
  test gate. The D0 findings (dev machine, 48 kHz, 10 ms blocks):
  `presetCheaper` 579 KiB and 100 ms latency per stream, zero allocations in
  `process()`, 8 staggered streams p99 0.3 ms, 64 streams p99 2.3 ms;
  linear-interp varispeed about 100× cheaper. The remainder plan made those
  facts normative for the old D2 design
  (`2026-08-25-feat-tempo-epic-remainder-plan.md:125-160`).
- The appliance runs the engine at 96 kHz with 64-frame periods (a 667 µs
  deadline; `engine_miniaudio.c:43`), ALSA ring `SEGNO_ALSA_PERIODS=8`
  (`segno-kiosk-launch:173`), audio thread SCHED_FIFO 80 (`segno.service:24`).
  The desktop default is 128 frames (`audio_setup_state.dart:76`). The D0
  numbers were taken at 480-frame blocks on an M4 Pro, so nothing today says
  what a stretcher hop costs inside a 667 µs period on the Pi 5. The callback
  telemetry (`le_callback_telemetry`, `segno_engine_api.h:1076-1093`;
  `le_cb_window_snapshot` `:1016-1075`: `late_periods`, `max_us`, `mean_us`,
  histogram) is the instrument.
- Fade is the precedent for a callback-owned per-track transform with
  receipts: `LE_CMD_FADE = 81`, `LE_CMD_RESET_FADE = 82`
  (`segno_engine_api.h:515-516`), `le_fade_admit` and the receipt table
  (`engine_commands.c:2568-2602`), API `le_engine_toggle_fade / install_fade /
  read_fade_result` (`:3162-3169`), Dart `AudioEngine.toggleFade/installFade/
  readFadeResult` (`audio_engine.dart:280-286`), repository `_requestFade`
  (`looper_repository.dart:1972-2018`), `Track.fade` (`models/track.dart:81`),
  Session `SessionTrack.fadeAmount` installed before `commitSession`
  (`looper_repository.dart:4359-4376`; `session.dart:180-262`;
  `session_repository.dart:706-710`). Settings with inherit (Loop settings) ride
  `SettingsReceipt` (`looper_repository.dart:293-382, 1160`).
- The app: `loop_audio_tempo_page.dart:9-14` is a disabled readout ("Tempo
  following is not available yet", `app_en.arb:3697-3729`); the control
  catalogue deliberately omits Speed and Transpose until an engine exists
  (`control_action.dart:10-20`; `TrackOperation`, `:140-170`).

## 1. The decision: stream the varispeed, pre-render the pitch-preserving work

Two different kinds of processing hide behind the four features:

| Feature | Timing | Pitch | DSP class |
|---|---|---|---|
| Speed ½×–8× | scaled by the factor | coupled (12·log₂ s semitones) | varispeed: a resampled read |
| Audio & tempo, Pitch "Follows speed" | song tempo / recorded tempo | coupled | varispeed |
| Audio & tempo, Pitch "Unchanged" | song tempo / recorded tempo | preserved | time-stretch |
| Transpose ±12 st | unchanged | shifted | pitch-shift (stretch at ratio 1) |
| Import Adapt | file tempo -> loop tempo | preserved | time-stretch, offline |

Decision D1. **Varispeed streams inline from the original takes** through one
fractional read head per track: a pure function of the song position, no
accumulator, no buffering, no latency, two taps per lane per frame. It is the
accepted direction for Speed, it is near-free (D0: 64 streams at 0.07 ms per
10 ms block), and it is exact over time because the index is derived from the
shared clock rather than integrated.

Decision D2. **Pitch-preserving processing is pre-rendered from the original
takes on the existing cache worker**, published as a second entry kind of the
wet cache, and read through the same head. Reasons, in order:

1. Exact lengths. A stretched lap must be exactly `k × clock.length` frames so
   it tiles the shared clock without drift. The library has no ratio parameter
   (`process(in, nIn, out, nOut)`); streaming it needs a fractional input
   accumulator whose rounding must be reconciled at every loop top. The offline
   `seek` + `process` + `flush` form produces an exact output length by
   construction (library README, "Ending").
2. No real-time burst. The STFT hop (`presetCheaper`: interval 1920 output
   samples, block 4800) is a 0.12 ms spike on an M4 Pro, several times that on a
   Cortex-A76. At 64-frame periods a hop lands whole inside one 667 µs period;
   eight streams aligned by a quantized Speed/tempo change hop together.
   `seek()` after a Stop/Play, Reverse toggle or history swap re-primes one
   block plus one interval of input in one call, which is milliseconds. A
   worker pays all of it off the audio thread.
3. One render owner. The wet cache already has the worker, the memory cap, the
   LRU, the settle debounce, the key predicate, the publish/retract discipline
   and the per-buffer verdict with same-buffer fallback. A second worker would
   duplicate every one of those (rule 4).
4. Composition. The whole-track render doc fixed "build the playable result from
   those sources and the applicable processing recipe, never by processing the
   previous wet result again"; a source render keyed on the content revision
   satisfies it, and a Transpose render consumed by a later Pre print is the
   same recipe idea one stage earlier (not built here; see §3.5).

The July spike's "GO, inline, no worker" was taken at 10 ms blocks on a fast
desktop for a continuous tempo follower. Part 1 re-measures on the appliance at
its real period, and records the inline figure so the decision rests on
numbers rather than on this argument. The inline figure is informational: D2
stands on exactness and the re-seek burst even where the steady-state CPU
would fit.

Decision D3. **Speed and tempo follow are read-head transforms; the song clock,
the click, quantize boundaries and capture are untouched.** The accepted text
says the click is unaffected, and the Speed face shows "Loop duration 2×" for
½×: a half-speed track takes two song laps, an 8× track laps eight times per
song lap, like a multiple or a division. The shared `le_loop_clock` keeps
counting device frames; only what each track reads at a given song position
changes. The alternative, scaling the clock itself, would halve the click and
the sent MIDI clock, make 8× a 960 BPM click, and touch every consumer of
`clock.position`.

## 2. The read head: generalizing the Reverse coordinate

### 2.1 Definition

Per track, audio-thread-owned, in a new C++17-clean header
`packages/segno_engine/src/core/engine_read_head.h` (role of `engine_fade.h`:
shared by the callback, the offline renderer and the bench; positional
initializers only, no `_Atomic`; the PROGRESS C++ blast-radius rule applies):

```c
typedef struct le_read_head {
  int reversed;   /* direction (Reverse plan) */
  double origin;  /* source-frame origin; re-set so the index is continuous at a change */
  double rate;    /* source frames per song frame = speed * (len_src / play_len) */
} le_read_head;
/* Source index for song position `pos` on a track whose source holds `len_src`
 * frames: forward (origin + rate*pos) mod len_src, reversed (origin - rate*pos) mod len_src. */
static inline double le_head_index(const le_read_head*, int64_t pos, int32_t len_src);
/* Re-origins so le_head_index == index at `pos`. */
static inline double le_head_origin(const le_read_head*, double index, int64_t pos, int32_t len_src);
/* Linear interpolation with wrap. frac == 0 returns buf[i] exactly. */
static inline float le_head_sample(const float* buf, int32_t len, double index);
/* Box average of the source samples a rate >= 2 head steps over (first-order anti-alias). */
static inline float le_head_sample_decimated(const float* buf, int32_t len, double index, double rate);
/* Equal-gain weight of the new head during a swap/turn of F frames, i frames in. */
static inline float le_head_turn_mix(int32_t i, int32_t F);
/* A lap wrap between two consecutive indices, in the head's direction. */
static inline int le_head_wrapped(double prev, double next, int reversed, int32_t len);
```

`rate == 1` and `origin ∈ ℤ` reproduces today's integer path bit-for-bit
(`le_head_sample` returns `buf[i]` when the fraction is zero); `rate == 1`,
`reversed == 1` reproduces the Reverse plan's `le_direction_index`. The Reverse
plan says Speed's head is where "`le_direction_index` generalises" (its §1.5);
this header is that generalization. Sequencing: whichever Part 1 lands first
(Reverse's or this plan's Part 2) introduces the header; the other rebases onto
it and keeps the first's tests green. Reverse's `turn_left / turn_reversed /
turn_offset` become a `le_read_head prev_head; int32_t turn_left;` pair that
also serves rate steps and source swaps below: one crossfade law.

### 2.2 Rate

`rate_t = speed_global × (len_src_t / play_len_t)` where `len_src_t` is lane 0's
`a_len` (the source the track recorded) and `play_len_t` is the span the track
occupies on the song clock: `k × trk_len[t]` for multiples, `trk_len[t]` for a
division or a Free/Song track. Today `play_len_t == len_src_t` always, so the
tempo term is 1 and `rate_t == speed_global`. Part 4 makes `play_len_t` differ
from `len_src_t` when the song tempo moves away from the recorded tempo.

### 2.3 Mixer application

Replace the pair rewrite at `engine_process.c:5569-5578` with: for every
PLAYING or OVERDUBBING track with `len > 0` and a non-identity head
(`reversed || origin != 0 || rate != 1 || source != dry`), compute
`idx = le_head_index(&tr->head, song_pos, len_src)` where `song_pos =
seg_base + trk_pos` (the per-frame musical position within `play_len`). Keep
`(seg_base, trk_pos)` integer for the write paths (they only run at rate 1,
§2.5). The dry read at `:5833` becomes `loopsample = le_head_sample(lbuf,
len, idx)` (`_decimated` when `rate >= 2`), with the identity fast path
`lbuf[seg_base + trk_pos]` kept verbatim for the default head so the existing
suite stays bit-identical. Metering reads the same `loopsample`.
`trk_play_pos[t]` (`:5584`) publishes `floor(idx)` in source frames, so
`position_frames / length_frames` stays the track's progress.

Turn window: while `turn_left > 0`, also read `old = le_head_sample(lbuf,
len, le_head_index(&tr->prev_head, …))` and mix with `le_head_turn_mix`,
`F = seam_xfade_frames(e)` (about 10 ms), decremented once per frame per
track after the lane loop beside the seam countdown (`:6086-6098`). A rate
step (Speed press), a direction toggle (Reverse) and a source swap (§3) all
start the same window; loops shorter than `2F` snap, mirroring the punch-fade
rule (`:5645-5650`).

Lap edges follow the head: Once's lap end (`:4486-4510`) and Free/Song's
(`:4454-4463`) use `le_head_wrapped` on the track's consecutive indices instead
of `position == 0`; `le_restart_once` (`:136-149`) re-origins through
`le_head_origin`. The Pre print engage conditions (`:5764`, `:5915`) gain
`head_is_identity(tr)`: a track with a non-identity head never engages a print
and a change clears `a_cache_active` / `a_track_cache_active` so the live chains
take over through the settled-bypass re-enable path (`:5881-5905` comment), as
the Reverse plan rules. Speeding or transposing a loop processes the recording,
not its effects: the chains run forward over the transformed source.

### 2.4 Shared clock, multiples, divisions, Free/Song

Nothing in `advance_transport_frame`, the grid, the click, quantize arms,
count-in, MIDI clock send or the perf frame stamps changes: the song clock is
device time. A multiple-2 track at ½× completes its two segments over four song
laps (`seg_base` already cycles `loop_iteration - start_iter` modulo `k`; the
head's `rate × pos` with `pos` spanning `k × base` covers it). A Sync division at
2× laps `2n` times per primary cycle. A Free/Song track's `pos` is its private
clock. The head is the only place the rate enters.

### 2.5 Capture

Record and overdub heads stay integer and forward (`:5698-5728`). Guards
(decision under rules 2 and 5, flagged in §8):

- Record or overdub is refused while `speed_global != 1` (new
  `LE_ERR_TRANSFORMED = -10`, `segno_engine_api.h:38-51`), control-side in
  `le_record_impl` (`engine_commands.c:1585`, after the Reverse guard when that
  lands) and dropped in `handle_record`'s PLAYING/STOPPED branch
  (`engine_process.c:1885`) so an arm that fires after the change cannot write.
  A count-in launch member with action Record/Overdub is refused at launch
  admission the same way.
- Overdub is refused on a track whose `len_src != play_len` (Part 4: recorded
  at another tempo), with the same code. A NEW take records at the current
  song tempo against the current clock, so its `len_src == play_len` and it
  plays at rate 1: recording at a changed tempo works without per-layer tempo
  tables (the ratio is derived from lengths, not stored).
- A Speed or tempo change is refused (`LE_ERR_NOT_READY`) while any track is
  RECORDING, OVERDUBBING, armed (`a_pending`, `pending_record`, `armed[]`,
  `a_pending_launch`) or in a count-in, and dropped on the callback if a
  capture started in the same block.

Sync/Band capture of a new track is untouched: recording writes at `record_pos`
on the musical clock and never reads the head (§2.8 of the accepted text holds
by construction).

### 2.6 Commands, receipts, snapshot, facts

- `LE_CMD_SET_SPEED = 84` (after Reverse's 83; renumber if Peel/Multiply land
  first), payload `struct { int32_t numer, denom; } speed;` with the five
  factors as `{1,2} {1,1} {2,1} {4,1} {8,1}`; checked, never raw-posted (add to
  the `le_push` refusal list, `engine.c:1299-1300` per the Reverse plan). Public
  `le_engine_set_speed(engine, numer, denom, uint64_t* request)` next to Fade,
  through the shared receipt table (`le_request_admit` from the Reverse plan,
  or factored here from `le_fade_admit` `:2568-2602` if this lands first; the
  reader becomes `le_engine_read_request_result`).
- Callback application: `speed_global` is one engine field; the handler
  re-origins every content track's head so the index is continuous, starts
  their turn windows, publishes `a_speed_numer/denom`, pushes the fact, writes
  the receipt. Normal (`{1,1}`) restores only this factor (`rate_t` keeps its
  tempo term).
- Snapshot: trailing `int32_t speed_numer, speed_denom;` on `le_snapshot`
  (global) and `int32_t head_rate_milli;` on `le_track_snapshot`
  (`segno_engine_api.h:932`, the effective per-track rate ×1000 so the UI can
  show the derived pitch and progress without re-deriving).
- Perf fact `LE_PLOG_SPEED = 327` (Reverse 324, Peel/Multiply 325–326 per the
  gap inventory's sequencing note), payload `{numer, denom, song_frame}`;
  pushed at every accepted change and at every material reset. events.log
  version: whichever of the 324–328 plans lands next takes the next version
  (`perf_drain.c:819` reads 6 today; the stem plan's rule). The renderer
  (`perf_render.c:829`, segment read `:1099`) applies the same
  `le_head_index`/`le_head_sample` with the logged `(numer, denom)` and
  anchors from the logged frame, so a stem at ½× is sample-exact against the
  live mix.
- Material resets (`le_fade_reset` sites, `:184-199` and callers; Reverse's
  `le_transform_reset`) reset the head to identity. Speed itself is global and
  survives a single track's Clear; New Loop resets it (§4).

## 3. Transpose: a rendered source read through the head

### 3.1 Source render entries

Extend `le_wet_entry` (`engine_private.h:427-434`) with `int32_t kind;`
(0 = Pre print, 1 = source render), `int32_t semitones;` and `int32_t out_len;`,
and the key predicate (`:443-449`) with those three fields; every comparison
site moves together, as its comment demands. A source render is mono (`pcm` of
`out_len` floats: lanes are mono before the chain), rendered from the lane's
live dry slot at content revision `audio_rev`, by the stretcher at ratio
`out_len / len` (1 for Transpose) and `setTransposeSemitones(semitones,
8000/sr)` (the tonality limit the README recommends; the listening check may
drop it). The lap is rendered as a cyclic signal: the worker feeds the last
`W = block + interval` source frames, the lap, then the first `W`, and keeps
the central `out_len` output frames, so the render loops as seamlessly as the
seam-folded dry does. The stretcher is constructed on the worker with a fixed
seed (D0 note 5) so a re-render of the same key is byte-identical, which is
also what makes the offline stem (§3.4) exact.

Jobs are per TRACK: one job renders every active lane of the track at the
same key and publishes the entries together, so a track never plays two lanes
at two pitches. Publication, retraction, LRU and the quiescent handshake are
the cache's existing ones; the memory cap is shared. Default cap: Part 3 raises
`LE_CACHE_DEFAULT_CAP_BYTES` from 64 MiB to 384 MiB (a 30 s mono lane at
96 kHz is 11.5 MiB; eight transposed single-lane tracks are 92 MiB; the Pi 5
has 8 GiB and the bench records peak RSS). A job that does not fit is refused
and the track stays dry with the reason in `le_lane_cache_info` (the Pre
print's existing rule).

### 3.2 State and application

Per track: `int32_t transpose_st;` (stored, −12..12), audio-thread-owned, with
published `a_transpose_st`; engine-global `a_transpose_bypass`. The
per-buffer verdict (`snapshot_lane_cache`, `:4939-4967`) selects the track's
source: a kind-1 entry whose key matches `{audio_rev, semitones = transpose_st,
out_len = len}` when `transpose_st != 0 && !bypass`, else the dry pool. The
selected buffer is what `le_head_sample` reads (§2.3); the head's `rate` for a
Transpose render is unchanged (same length). A source change (render landed,
semitone step, bypass toggle, content change) starts the turn window: the
crossfade runs between the old and the new source at the same index, immediate
rather than at the lap top, because the new pitch is what the player asked for
and a lap-top wait would make a foot step wait up to a whole loop.

Pending policy (decision under rule 3, flagged in §8): while a track's render
is not ready (semitone changed, content changed, cache evicted, after reopen)
it plays the DRY source at true pitch, and the snapshot reports
`transpose_effective_st` (0 while dry) beside `transpose_st` (stored), so the
Transpose face and the Tracks marker can show "pending" rather than claim a
pitch that is not sounding. Timing is never wrong; pitch may be temporarily
wrong and is reported. Undo/Redo to a previously rendered slot is instant when
its entry is still cached: entries key on `audio_rev`, and the cache holds
several per lane under the cap.

Settle debounce for kind-1 jobs: 100 ms (foot steps are discrete; the 250 ms
Pre-print debounce exists for parameter sweeps), as a second constant beside
`LE_CACHE_SETTLE_MS`.

### 3.3 Commands

- `LE_CMD_TRANSPOSE = 85`, payload `struct { int32_t channel, install,
  semitones; } transpose;` (`install = 0` steps by `semitones` ±1 and clamps
  at ±12 with the result in the receipt, so "at pitch limit" is reportable;
  `install = 1` sets, for Session recall) and `LE_CMD_TRANSPOSE_BYPASS = 86`
  (`arg_i` 0/1). Public `le_engine_transpose_step(engine, channel, delta,
  request)`, `le_engine_install_transpose(engine, channel, semitones, request)`,
  `le_engine_set_transpose_bypass(engine, on, request)`, all through the receipt
  table. Admission refuses EMPTY, RECORDING and OVERDUBBING tracks and pending
  arms exactly as Fade/Reverse do; bypass is admitted whenever configured.
- Record/overdub into a track with `transpose_st != 0 && !bypass` is refused
  with `LE_ERR_TRANSFORMED` (the Reverse rule: a new layer would be recorded at
  true pitch under transposed playback and then transposed with the rest, which
  is not what the player heard themselves play). Stop, Play, Mute, Fade,
  Clear, Undo/Redo stay available.
- Snapshot: trailing `int32_t transpose_st, transpose_effective_st;` on
  `le_track_snapshot`; `int32_t transpose_bypass;` on `le_snapshot`.
- Facts: `LE_PLOG_TRANSPOSE = 328` `{channel, stored, effective, source_kind}`
  at every effective change (render engaged, dry fallback, bypass), so the
  renderer knows exactly which frames played which source.

### 3.4 Offline renderer

`perf_render.c` links the stretch TU and, on a 328 fact naming a rendered
source, renders the referenced image through the same function, seed and
cyclic padding, then reads it through the logged head. Byte-identical input,
deterministic FFT and identical code give a sample-exact wet stem. A fact
naming the dry fallback renders dry. No new provenance mechanism: the image
identity is the stem plan's (`322/323`, `slot_image`).

### 3.5 What Transpose does not do

Transposed and stretched tracks run their Pre chains live (no print; §2.3). A
Pre print rendered from a transposed source is a chained render recipe the
cache does not express yet; it is not needed for correctness (the live path
computes the same function) and is left for a follow-up. Transpose is not an
audio edit: no history entry, never retires Redo (§2.10 of the accepted text).
Pitches survive Clear Undo as Fade's amount does? No: direction, speed and
pitch reset with the material (rule 5, the Reverse plan's decision 5); a Clear
then Undo restores the take untransposed with the marker showing 0 st.

## 4. Audio & tempo follow

### 4.1 Recorded tempo

Latch `e->recorded_tempo_bpm` (`_Atomic` float bits, published in
`le_snapshot.recorded_tempo_bpm`) at the defining finalize
(`finalize_master`, `engine_process.c:884`, after `sync_grid_to_loop` `:591`
has settled the derived or existing tempo). It is the tempo the master's
`clock.length` corresponds to. It clears when the last take clears (with the
master) and is restored by `commitSession` (new argument) on recall. Tracks
recorded later at another song tempo carry their own ratio implicitly through
`len_src / play_len` (§2.2), so one recorded tempo per master suffices.

### 4.2 Retiming on a tempo change

With Follow tempo on (`a_follow_tempo`, default 1, per-track override
`a_follow_tempo_override` −1/0/1 like `a_quantize_div_override`,
`engine_private.h:1254`), `le_tempo_locked` (`:411-423`) no longer locks a rig
with content and a bar grid; `LE_CMD_SET_TEMPO` (`:3119-3133`), tap and
`restore_tempo` compute `L_new = round(bars × frames_per_bar(new))`
(`le_grid_frames_per_bar`, `tempo_grid.h:66`) rounded up to a multiple of the
largest active divisor (2 or 4, so `base / n` stays exact as
`sync_division_positions_frame` requires), scale `clock.position` by
`L_new / L_old` (phase preserved), keep `loop_iteration`, `grid_total_beats`
and `a_loop_bars`, publish `a_master_len`, and scale every established
`free_clock` the same way. Every following track's `play_len` moves with the
clock; `rate_t` follows from §2.2. `regrid_surviving_master` (`:826-838`)
remains the rule for the no-follow case (bars re-derived for a fixed length)
and for rigs without a bar grid (`a_loop_bars == 0`: nothing to follow; the
snapshot says why). The lock still holds during a count-in and while any
track captures or is armed (§2.5).

A track with Follow Off while `L_new != L_old`: "keeps its recorded speed"
means its lap is `len_src` device frames, which no longer divides the song
lap. Its head detaches: `rate = speed_global`, origin re-set for continuity,
and its `pos` is a private counter (`free_clock`-shaped, advanced once per
device frame while PLAYING/OVERDUBBING) rather than the shared position; it
re-attaches to the shared position at its next Stop/Play or at the transport
hold (`:4480-4484` in the Reverse plan's numbering), exactly as Once's offset
persists until then. In Free/Song mode its private clock simply stops being
scaled.

### 4.3 Pitch

`a_pitch_follows_speed` (default 0 = Unchanged) with per-track override. With
"Follows speed" the varispeed head alone does the work (pitch moves by the
tempo ratio: "Faster raises the pitch. Slower lowers it.", screen 05). With
"Unchanged" the track's source is a kind-1 render with `semitones =
transpose_st` and `out_len = play_len` (a time-stretch, or a combined stretch
and shift when the track is also transposed: one render, one recipe), read at
`rate = speed_global` (the render already has the play length). While that
render is pending the dry source plays through the varispeed head at the full
ratio, so timing is exact at every moment and only the pitch is temporarily
off, reported as `pitch_effective` in the track snapshot. A later MIDI-clock
follower (E8-1) that moves the tempo continuously will re-render only when the
ratio drifts past a tolerance (0.5 %, 9 cents) after the debounce; between
renders the head absorbs the residual. That tolerance is a Part 4 constant,
not an owner question.

### 4.4 Settings, Session, app

Follow tempo and Pitch are Loop settings: Defaults plus per-track overrides
with the inherit grammar (`SettingsReceipt`, `looper_repository.dart:293-382,
1160`; the quantize override precedent). Engine commands
`LE_CMD_SET_FOLLOW_TEMPO = 87` / `LE_CMD_SET_PITCH_MODE = 88` each carry
`{channel (-1 = default), value (-1 inherit)}` and a receipt. Session (schema
bump, strict decode, no legacy path per AGENTS.md): `recordedTempoBpm` on the
session, `followTempo` and `pitchFollowsSpeed` defaults, per-track overrides on
`SessionTrack` (`session.dart:180-262`), captured at
`session_repository.dart:706-710`, installed before `commitSession`
(`looper_repository.dart:4359-4376`). The page `loop_audio_tempo_page.dart`
becomes live against the owner: screens 07/04–06, including the "Default /
Custom / Use default" badges and the two note lines; the "not available yet"
line and `loop_audio_unavailable` key are removed.

## 5. Import Adapt, Session, reopen, New Loop, stems

- Import Adapt: export `le_stretch_render_offline(const float* in, int32_t
  in_frames, int32_t channels, int32_t sample_rate, double ratio, int32_t
  semitones, float* out, int32_t out_frames)` from the stretch TU (no engine
  handle; control thread; exact length via seek/flush; cyclic padding is the
  caller's choice through a flag, off for a non-looping file). Dart:
  `StretchRenderer.adapt(Float32List pcm, {required double fromBpm, required
  double toBpm, required int sampleRate})` in `segno_engine`, returning the
  stretched PCM whose length equals the whole-bar count at the loop tempo; the
  Library flow (#1178 / E7-9) then calls the existing `importTrackLane`. "Use
  file tempo" is `setTempo`; "Leave unchanged" is the import as it exists.
  Unknown tempo requires confirmed bars (`fromBpm` derives from bars and
  duration); the seam does not guess.
- Session: `speed` `{numer, denom}` on the session and `transposeSemitones`
  per track plus `transposeBypass` on the session (decision under rule 3: what
  the player saved comes back; the Reverse plan saved direction for the same
  reason). Recall installs transpose before `commitSession` and speed after
  it, every receipt confirmed; a refused install fails the load as Fade's
  does. The head origin is not saved: recall publishes STOPPED at the head.
- Reopen (#1140, built): `speed`, `transpose_st`, `transpose_bypass`,
  `recorded_tempo_bpm` and the follow/pitch settings go in the material column
  of `le_engine_reset_material` (`engine.c:422`); renders are cache and are
  rebuilt after `le_cache_init` (the track returns STOPPED, so the render is
  ordinarily ready before Play; otherwise the pending policy applies and is
  reported). Dropped takes reset their transpose with the take.
- New Loop (not yet implemented; `grep newLoop` finds nothing): it inherits the
  resets because speed, transpose and the head die with the material through
  `le_transform_reset`; a global Speed reset is added at the one New Loop site
  when #1178's Part lands.
- Stems (#1173 provenance): the facts 327/328 plus the logged head make every
  transformed frame reproducible from the staged image; a swap to a slot
  without a staged image still ends the stem with `323/0` exactly as today.
  Capture (`perf.armed`) is independent of the head: the master is the mix the
  listener heard, the stems replay it.

## 6. Parts

Each part is independently mergeable, keeps the public app working and exposes
no unfinished destination. Production-line estimates exclude tests, bench
tooling, generated bindings and docs.

### Part 1. Measured CPU spike: bench harness, stretch shim, read-head header (about 250 production lines)

Goal: numbers from the appliance, and the two pure pieces every later part
reads, before any mixer edit.

1. Vendor the library into the real build: move
   `src/test/bench/third_party/signalsmith-stretch/` to
   `packages/segno_engine/third_party/signalsmith-stretch/` beside `rnnoise/`
   with `README.upstream.md` (tag 1.1.0, commit `44c8f865`, MIT, the stripped
   `web/`, `cmd/` noted) and add the MIT notice where RNNoise's lives in the
   About licences. Add `src/stretch/le_stretch.h` (plain C: opaque
   `le_stretch`, `le_stretch_create(channels, sample_rate, cheaper, seed)`,
   `le_stretch_destroy`, `le_stretch_render_offline` as in §5, and the
   streaming `le_stretch_process(in, n_in, out, n_out)` / `_seek` / `_flush` /
   `_latency` the bench needs) and `src/stretch/le_stretch.cpp` (the only TU
   that includes the template). Wire it: `src/CMakeLists.txt:60-105` (with
   `enable_language(CXX)` unconditional, `:269-303` keeps it only under
   plugins today), the podspec (`segno_engine.podspec:24` compiles
   `Classes/**/*`; add a `Classes/le_stretch.cpp` forwarder like
   `host_clap.cpp`), `Package.swift` (the rnnoise include pattern, `:48-49`),
   and `run_native_tests.sh:70-91` (explicit listing, like rnnoise). Apply
   PROGRESS's shim repro to the new header.
2. `engine_read_head.h` (§2.1) with its unit tests in a new
   `src/test/test_engine_read_head.h`, included like `test_engine_fade.h`
   (`test_engine_core.c:33540-33542`): identity exactness (frac 0 returns the
   sample; rate 1 reproduces `(pos + origin) mod len` for 10⁶ positions), ½×
   over 2 laps and 8× over 1/8 lap visit the expected indices, reversed
   parity with the Reverse plan's definition, re-origin continuity, wrap
   detection in both directions, decimated average at 2/4/8, turn-mix
   equal-gain sums.
3. `src/test/bench/bench_pitch_time.cpp` + `bench_pitch_time.sh`, linking the
   real engine sources exactly as `bench_devices.sh:12-30` does, built with
   `-O2 -DNDEBUG` and the same flags as the shipped build. Scenarios, each over
   at least 60 s of simulated audio at the configured rate and period, with
   the harness thread at SCHED_FIFO 80 when it can (it reports whether it
   could), timings per period as p50 / p99 / max in µs and as a percentage of
   `budget_us`:
   - `baseline`: `le_engine_configure(96000, 2, 2, cap)` (`segno_engine_api.h:1661`),
     eight tracks × one lane with 30 s content imported through
     `le_engine_import_track`, PLAYING, driven by `le_engine_process` in
     64-frame blocks; then 8 × 8 lanes. The control everything else is added to.
   - `head`: the read-head kernel over 8 and 64 lanes at ½, 2, 4, 8 and at
     rates 0.75 and 1.333, per period, in a loop shaped like the lane loop
     (two taps plus the decimated average). Reported as added cost on top of
     `baseline`.
   - `render`: `le_stretch_render_offline` throughput in seconds of audio per
     second, `presetCheaper` and `presetDefault`, 30 s mono at 96 kHz, ratios
     1 (±12 st), 0.75 and 1.333, measured idle and while `baseline` runs on
     the RT thread (the worker contends with the UI and the callback on the
     Pi 5's four cores).
   - `inline` (informational): streaming `le_stretch_process` at 64 output
     frames per call, 1 / 8 / 64 streams, aligned and hop-staggered, p99 per
     period, plus the cost of one `seek` re-prime; the figure the decision
     documents.
   - `memory`: heap per stretcher, per render entry, peak RSS of the process.
   - `--smoke` runs every scenario for one second at 48 kHz / 128 frames with
     no thresholds; the `native-tests` CI job runs it so the harness cannot
     rot (`.github/workflows/main.yaml:183`).
   Acceptance thresholds, asserted by the harness (`--budget-us 667 --assert`,
   non-zero exit on failure), on the appliance Pi 5 (Yocto image, SCHED_FIFO,
   both displays attached, app running):
   - `head` added p99 ≤ 10 % of the period at 8 lanes and ≤ 35 % at 64 lanes
     for every factor and ratio;
   - `baseline` p99 + `head` p99 ≤ 50 % of the period at 8 lanes (if
     `baseline` alone exceeds that, it is a pre-existing finding to report on
     its own issue, not this plan's gate);
   - `render` ≥ 20× real time per mono lane under load with `presetCheaper`
     (a 30 s lap in ≤ 1.5 s; an eight-lane track in ≤ 12 s);
   - `memory`: a kind-1 entry costs `out_len × 4` bytes plus under 1 MiB of
     worker scratch; stretcher heap per instance recorded;
   - `inline` has no threshold; its p99 relative to the period is recorded.
4. `docs/plan/2026-10-xx-pitch-time-spike-findings.md`: the tables from the
   Pi 5 and from the dev machine (the latter for ratios only), the reproduce
   command, and the gate verdict. If `render` fails its threshold on the Pi 5
   the plan returns to the owner before Part 3 (escalation to `plan-gate`):
   the fallback candidates are `presetCheaper` with a smaller block, or a
   lower-cost shifter for Transpose, both measured by the same harness.

Build note: the shim's C header must stay plain C (`_Atomic`-free) because it
reaches the VST3 C++ TUs through nothing today but will the moment a core
header includes it; the repro in `docs/PROGRESS.md` is part of the verify list.

```success-criteria
GOAL: The appliance's per-period cost of the fractional read head and the worker throughput of the stretcher are measured on the Pi 5 at 96 kHz / 64 frames, the vendored library and its C shim compile in every build the engine ships in, and the read-head header is proven exact.
SUCCESS CRITERIA:
- The read-head header reproduces the integer path bit-exactly at rate 1 and visits the expected indices at the five factors, both directions and the two tempo ratios; the stretch shim renders an exact-length output for a 30 s input at ratio 1, 0.75 and 1.333. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- The harness builds and its smoke run passes on macOS and Linux x64; the C++17 shim repro compiles with the new header; the FFI symbol check passes against the built library. | verify: bash packages/segno_engine/src/test/bench/bench_pitch_time.sh --smoke && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && manual: the docs/PROGRESS.md shim repro with engine_read_head.h and le_stretch.h included
- Dart analysis, Bloc lint and the Dart suites stay clean (no Dart production change expected beyond the licence notice). | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- HARDWARE: on the appliance Pi 5 at 96 kHz / 64 frames with the app running, every threshold above holds and the findings document carries the tables and the verdict. | verify: manual: scp the arm64 harness (built on the build-linux-arm64 runner or the bench Pi) to the appliance and run bench_pitch_time.sh --budget-us 667 --assert; record the output in the findings document
NON-GOALS:
- Any mixer, command, snapshot, Session or UI change; a decision on inline streaming beyond recording its cost.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && bash packages/segno_engine/src/test/bench/bench_pitch_time.sh --smoke && dart analyze --fatal-infos lib test packages
```

### Part 2. Native Speed and the head in the mixer (about 550 production lines)

Sections 2.2–2.6 complete: the head on `le_track` (beside `playback_offset`,
`engine_private.h:1272`), the mixer rewrite at `engine_process.c:5569-5578` and
`:5833`, the turn window, lap edges, print-engage conditions,
`LE_CMD_SET_SPEED`, `LE_ERR_TRANSFORMED` guards, receipts (sharing or
factoring `le_request_admit`), snapshot fields, fact 327, renderer parity,
material resets. Dart seam: `AudioEngine.setSpeed(SpeedFactor) ->
RequestAdmission` and `readRequestResult`, `EngineSnapshot.speed`,
`TrackSnapshot.headRate`, `EngineResult.transformed`, the four fakes
(`test/helpers/fake_audio_engine.dart`, the three package fakes), regenerated
and formatted bindings; `LooperRepository.setSpeed` through `_requestReceipt`
(the renamed `_requestFade`, `looper_repository.dart:1972`), `LooperState.speed`
projection. No mode entry, no UI.

Tests (`src/test/test_engine_speed.h`, literal PCM through
`le_engine_process`; ramp PCM so the index is the sample): identity
bit-exactness for the whole existing suite (unchanged tests); ½× reads indices
0, 0.5, 1 … (interpolated values `i + 0.5`) and takes two song laps per lap at
44.1/48/96 kHz and blocks 1/64/127/512; 2×/4×/8× visit `2i`/`4i`/`8i` with the
decimated average oracle; a step 1× -> 2× at index 37 is continuous (37, 39,
41 …) with the equal-gain mix inside the turn window; Normal after 4× keeps
the index continuous; multiple 2 at ½× cycles both segments over four song
laps; a Sync division at 2× laps `2n` times per primary cycle; Free/Song
private clock; Once lap end at the head wrap in both directions; two lanes read
the same index; Fade continues through a step; the Pre print disengages on a
step and never engages at a non-identity head; record and overdub refused with
`LE_ERR_TRANSFORMED` and dropped on the callback when armed before the change;
a change refused while RECORDING/OVERDUBBING/armed/count-in; receipts for rapid
double presses; Clear/undo-to-empty/new capture/import reset the head and log
the fact; the renderer reproduces a ½× and an 8× stem sample-exactly including
the turn; `position_frames` runs at the head's rate. One actual-native
repository case (`packages/looper_repository/test/speed_native_test.dart`,
fixture of `fade_native_test.dart:13-45`) confirms the receipt, the projection
and the record refusal.

```success-criteria
GOAL: A checked native global Speed reads every recorded track at ½×, 1×, 2×, 4× or 8× through one fractional head, click-free and exact over time, with the song clock, click, quantize and capture untouched, confirmed receipts and exact offline replay, while the public app is unchanged.
SUCCESS CRITERIA:
- Literal PCM proves the five factors, continuity at steps, multiples, divisions, Free/Song, Once, two-lane parity and Fade independence at three rates and four block sizes; the default head keeps every pre-existing test byte-identical. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Capture refusals and drops return LE_ERR_TRANSFORMED, never write through a non-identity head, and a change during capture is refused; material resets publish identity and log the fact. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Offline stems at ½× and 8× match the live mix sample-exactly; sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings, symbol parity and the Dart seam are complete; the repository confirms a Speed change and projects it. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: the Part 1 harness re-run on the appliance with the real mixer path at 8× and ½× stays within the Part 1 thresholds. | verify: manual: bench_pitch_time.sh --budget-us 667 --assert on the appliance after Part 2
NON-GOALS:
- Transpose, tempo follow, Session persistence, mode entry, UI, mappings, anti-alias beyond the box average.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3. Native Transpose: source renders on the cache worker (about 650 production lines)

Section 3 complete: `le_wet_entry.kind/semitones/out_len` and the key
predicate, the kind-1 job on the cache worker (`engine_cache.c`: enqueue copy of
every active lane's live slot at `audio_rev`, render through `le_stretch`
with cyclic padding, publish per track), the 100 ms debounce, cap raise, the
verdict's source selection in `snapshot_lane_cache`, the source swap through
the turn window, `LE_CMD_TRANSPOSE`/`_BYPASS`, admission, the record guard,
snapshot fields, fact 328, renderer parity (the stretch TU linked into
`perf_render.c`), material resets. Dart seam:
`AudioEngine.transposeStep/installTranspose/setTransposeBypass`,
`TrackSnapshot.transpose` (stored, effective), `EngineSnapshot.transposeBypass`,
fakes, bindings; repository `transposeTrack(channel, delta)`,
`installTranspose`, `setTransposeBypass`, `Track.transpose` projection.

Tests (`src/test/test_engine_transpose.h`): a +12 st render of a sine at
220 Hz peaks within 1 % of 440 Hz in its spectrum and keeps the exact length;
the render loops without a discontinuity at the wrap (cyclic padding: the
first and last 1024 output frames of two consecutive laps are identical); a
+2 st step on a playing track plays dry until the render lands, then crossfades
to the render at the same index with the equal-gain mix and reports
`effective == stored` only after the swap; a second step while the first
render is pending re-keys the job and lands once; bypass swaps to dry and back
with pitches kept; an overdub completing on a transposed track is impossible
(refused), while Undo to a previously rendered slot re-engages its cached entry
within one block; Clear resets to 0 st; a job over the cap leaves the track
dry with the reason; the renderer's stem matches the live transposed mix
sample-exactly; two rapid presses produce two receipts; render identity under a
fixed seed (two renders of the same key compare equal). Actual-native
repository case in `transpose_native_test.dart`.

```success-criteria
GOAL: A checked per-track Transpose plays a pitch-shifted render of the track's own takes at unchanged timing, built off the audio thread by the one cache worker, swapped click-free, truthful about what is sounding, with a global bypass that keeps stored pitches, and exact offline replay.
SUCCESS CRITERIA:
- Render length, loop continuity, pitch, determinism and the dry-until-ready then crossfade behaviour are proven with literal and spectral oracles; `effective` never claims a pitch the mix is not playing. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Bypass, limit (±12 reported in the receipt), capture refusal, Undo re-engagement, cap refusal and material resets behave as specified; sanitizer and telemetry-off pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- The offline stem of a transposed track matches the live mix sample-exactly across the swap. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings, symbol parity, the Dart seam and the repository projection are complete; static gates clean. | verify: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test) && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: on the appliance, eight transposed single-lane 30 s tracks render within the Part 1 render threshold while playing, with no late period (telemetry late_periods unchanged over the run) and the listening check passes at ±12 st with and without the tonality limit. | verify: manual: appliance session per docs/PROGRESS.md hardware evidence rules, reading le_engine_get_callback_telemetry before and after
NON-GOALS:
- Transposed overdubbing, Pre prints over a transposed source, tempo follow, Session, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 4a. Native Audio & tempo follow (about 450 production lines)

Sections 4.1–4.3 complete: `recorded_tempo_bpm`, the lock relaxation, retiming
in the SET_TEMPO/tap/restore handlers with divisor rounding and position
scaling, `play_len` in the head's rate, the detached private head for a
non-following track, kind-1 renders with `out_len = play_len` for Unchanged
pitch and the dry-through-varispeed pending rule, the 0.5 % re-render
tolerance, the follow and pitch settings with inherit and receipts,
`commitSession`'s recorded tempo, snapshot fields (`recorded_tempo_bpm`,
`follow_tempo`, `pitch_mode`, per-track overrides and `pitch_effective`), the
overdub guard for `len_src != play_len`, perf facts (tempo is already locked
out of the audited table because it could not change; the relaxation logs
`LE_PLOG_SET_TEMPO` with the new length, which #279's export plan consumes).
Dart seam and repository through `SettingsReceipt`.

Tests (`src/test/test_engine_tempo_follow.h`): a 4-bar loop at 120 BPM
recorded, tempo set to 90 with follow on: `clock.length` scales to the bar
count's frames, phase preserved, the click lands on the new beats, the track
reads at ratio 0.75 (ramp oracle), and a NEW track recorded at 90 reads at
rate 1 while the first keeps 0.75; back to 120 restores identity exactly;
divisor rounding keeps `base % n == 0`; follow Off on one track detaches and
re-attaches at Stop/Play; pitch Unchanged plays dry-through-varispeed until the
stretched render lands and then at the render with `pitch_effective` truthful;
the lock still holds during count-in and capture; a rig without bars reports
"no grid" and does not retime; Free/Song private clocks scale; Speed composes
(`rate = speed × ratio`); renderer parity for a retimed stem.

```success-criteria
GOAL: With Follow tempo on, a song-tempo change retimes the shared clock and every following track plays the new tempo from its original take, pitch coupled or preserved as set per track, with recording at the new tempo still possible and the whole rig exact on the grid.
SUCCESS CRITERIA:
- Retiming scales length and phase, keeps bars and divisors exact, moves the click, and the head ratio follows for existing takes while new takes play at rate 1; identity returns exactly at the recorded tempo. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Per-track Follow Off detaches and re-attaches as specified; Unchanged pitch is truthful through the pending window; guards hold during count-in and capture; sanitizer and telemetry-off pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Dart seam, settings receipts and the repository's inherit grammar are complete; static gates clean. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- MIDI clock receive (E8-1), Session fields and the page (4b), UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages
```

### Part 4b. Audio & tempo page and Session fields (about 300 production lines)

Section 4.4: schema bump with `recordedTempoBpm`, follow/pitch defaults and
per-track overrides, strict decode, capture and install before commit;
`loop_audio_tempo_page.dart` live against the owner for screens 07/04–06 with
the inheritance badges, the two note lines and the scope selector, the
"unavailable" line removed; EN/ES strings; the Loop settings hub status.
Tests: `packages/session_repository` round trip and malformed rejection;
`test/looper/view/loop_settings` widget tests and goldens for the three
screens; repository tests for inherit/override/use-default.

```success-criteria
GOAL: Follow tempo and Pitch are editable Loop settings with the accepted inheritance grammar, saved and recalled with the Session, and the page shows what the engine holds.
SUCCESS CRITERIA:
- Schema round-trips strictly and rejects malformed values before side effects; recall restores recorded tempo, defaults and overrides with receipts confirmed. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session
- The page renders screens 07/04–06 (goldens EN/ES), edits through the owner, and shows Default/Custom/Use default truthfully. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/loop_settings
- Static gates and the whole app suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
NON-GOALS:
- Screen 07/07 (MIDI tempo), new owners, legacy schema decode.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 5. Session for Speed and Transpose, reopen, import Adapt seam (about 300 production lines)

Section 5: Session fields `speed`, `transposeSemitones`, `transposeBypass`
(schema bump shared with 4b if they land together), install order, reopen
material columns and `test_engine_reopen.h` cases (a transposed track reopens
transposed and stopped, dry until its render lands, reported; a ½× rig reopens
at ½×), `le_stretch_render_offline` exported, `StretchRenderer.adapt` with a
pure-Dart-visible contract and its FFI test (a 2-bar file at 84 BPM adapted to
120 BPM has exactly the frame count of 2 bars at 120, pitch unchanged by
spectral oracle), the four fakes, bindings, `check_ffi_symbols`.

```success-criteria
GOAL: Speed and Transpose survive save, recall and a retained reopen; a file can be adapted to the loop tempo at unchanged pitch to an exact length for the Library's import flow.
SUCCESS CRITERIA:
- Session round trip of a ½× rig with two transposed tracks recalls stopped with the factors installed and receipts confirmed; malformed data is rejected before side effects. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test)
- Reopen keeps speed, pitches and bypass in the material column and reports a pending render truthfully. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- Adapt returns the exact bar-aligned length at unchanged pitch through the FFI; symbol parity holds. | verify: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)"
- Static gates clean. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- The import flow and its screens (#1178), New Loop, legacy decode.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages
```

### Part 6a. Foot Speed surface and Tracks marker (about 550 production lines)

Pattern: the Reverse plan's Part 3 over the Fade surface files
(`interaction_mode.dart:46`, `foot_fade.dart:154-193`,
`control_foot_fade.dart`, `foot_fade_actions.dart`, `foot_fade_view.dart`,
`control_projection.dart`, `track_column.dart` marker). `InteractionMode.speed`;
`FootSpeedProjection` with pedal roles from screen 15/01: track pedals 1–4 =
½× / 1× / 2× / 4×, Bank = 8× (the pen's five captions "Half speed, Normal
speed, Double speed, 4 times speed, 8 times speed" on the five positions),
Mode = Exit, Rec/Play and Stop as in Fade, Undo/Clear inert; `TrackOperation`
gains `speedHalf/Normal/Double/Quad/Octuple` as direct actions (the catalogue
rule at `control_action.dart:10-20`: an entry exists only once the engine does);
the face shows the factor, the derived pitch ("−12 st", "+36 st") and the loop
duration ("2×", "1/8"), "No recorded audio" when every track is empty (15/04);
the Tracks marker "Loop speed 2×" (15/05) reads `LooperState.speed` and holds
its width at 1×; LEDs: the lit position is the current factor; refusal toast
once per visit; EN/ES strings. Tests as the Reverse Part 3 lists: dispatch,
projection truthfulness, view goldens, marker, ingress parity.

```success-criteria
GOAL: The accepted Speed face sets the global factor by foot or assignment, shows the derived pitch and duration, and leaves a truthful marker on Tracks.
SUCCESS CRITERIA:
- Pedals set the five factors against the real receipt, Exit keeps the factor, Normal restores only the factor, a refused change shows one notice. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Face and marker goldens match screens 15/01–05 in EN and ES; the marker holds width at 1×. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Direct Speed actions reach the same adapter from pedal, CTRL and MIDI ingress; static gates and the suite pass. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: footswitch and LED proof on the appliance at each factor during playback and stopped, with a running Fade and with a record refusal. | verify: manual appliance session per docs/PROGRESS.md hardware evidence rules
NON-GOALS:
- Transpose face, hold gestures, native changes.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 6b. Foot Transpose surface and marker (about 650 production lines)

`InteractionMode.transpose`; `FootTransposeProjection` from screens 11/01–04
and the bypass tile: track pedals toggle selection across banks, Undo = −1 st
and Clear = +1 st on the selection ("Select tracks with their pedals." when
none, 11/03), hold Undo/Clear = reset the selection's pitches, hold Rec/Play =
Bypass/Enable (the pen's "Hold · Bypass" / "Hold · Enable"), "Limit · Hold
reset" at ±12 (11/04), Bank pages, Exit retains changes; the face lists every
track's stored semitones and "Stored" while bypassed (FJ8Ys); a Tracks marker
("+2 st") per track reading `Track.transpose.effective` with the pending state
distinguishable; `TrackOperation.transposeUp/Down` direct actions;
`pitch_effective`-aware LEDs; EN/ES. Tests as 6a.

```success-criteria
GOAL: The accepted Transpose face steps selected tracks by semitone with hold-reset and a global bypass that keeps stored pitches, and Tracks shows what is sounding.
SUCCESS CRITERIA:
- Selection across banks, ±1 steps, limit reporting, hold resets, bypass/enable and Exit behave against the real receipts; a refused step shows one notice. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Face, bypass tile and marker goldens match screens 11/01–04 and the bypass tile in EN and ES; the marker distinguishes stored from effective. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Static gates and the suite pass. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: footswitch, hold timing and LED proof on the appliance including the pending window after a step and the overdub refusal. | verify: manual appliance session per docs/PROGRESS.md hardware evidence rules
NON-GOALS:
- Native changes, hold-duration settings, new owners.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Dependencies and sequencing

```
Part 1 (spike; gate)
 └─ Part 2 Speed ── Part 3 Transpose ── Part 4a Follow ── Part 4b page + Session
       │                 │                                      │
       └─ Part 6a face   └─ Part 6b face        Part 5 Session/reopen/Adapt (after 3; schema with 4b)
```

Part 2 shares `engine_read_head.h`, the turn window, `le_request_admit` and
`le_transform_reset` with the Reverse plan's Part 1 (#1162) and the record
guard site in `le_record_impl` with #1161: land after whichever of them is in
the base and rebase the other. Part 3 edits `le_wet_entry`, the key predicate
and `engine_cache.c`, which no open plan touches. Part 4a relaxes
`le_tempo_locked`, which the MIDI clock plan (E8-1) will build on. Part 5's
schema bump is shared with Part 4b and with Reverse Part 2 (schema 12):
whichever lands later takes the next number. Each part runs normal, ASAN and
telemetry-off native suites, `dart analyze --fatal-infos`, Bloc lint, and the
independent architecture, test-quality and adversarial reviews before the human
merge gate. Review ceiling 700 production lines per part; stop for review on
any second read coordinate, a second render worker, a capture path through a
non-identity head, a new Dart owner, or a change to the song clock's advance.

## 7. Decisions taken under the standing rules

1. Varispeed streams inline from originals; pitch-preserving work is
   pre-rendered on the one cache worker (D1, D2). Rule 4: one render owner,
   one memory cap, one verdict; rule 2: no real-time burst on the audio thread.
2. Speed and tempo follow transform the read head only; the song clock, click,
   quantize, MIDI clock send and capture are untouched (D3). Rule 1 and the
   accepted text ("click unaffected", "Loop duration 2×").
3. One head, one crossfade law: Reverse's direction, Speed's rate, source swaps
   and bypass share `le_read_head`, the turn window and the seam length. Rule 4.
4. Record and overdub are refused while Speed ≠ 1×, into a transposed track,
   and into a track recorded at another tempo; a Speed or tempo change is
   refused during capture, arm or count-in; new takes at a changed tempo
   record normally. Rules 2 and 5: one forward integer capture engine; the
   refusals are visible (the Reverse plan's rule for overdub).
5. Pending renders play dry at true pitch and are reported (`effective` beside
   stored); timing is never wrong. Rule 3 (no silent change) and rule 2
   (audio keeps running).
6. Source swaps crossfade immediately rather than at the lap top, because the
   new sound is the request; prints keep their lap-top engage because they are
   the same sound. Rule 3.
7. Transposed or stretched tracks never engage Pre prints; the live chains run
   over the transformed source. Rules 3 and 4 (the Reverse plan's decision 4).
8. Speed, pitches and bypass are saved in the Session and kept across a
   retained reopen; the head origin is not saved. Rule 3; the Reverse plan's
   decisions 7 and 8.
9. Speed, pitches and the head reset with the material (Clear, undo to empty,
   new capture, import, configure, New Loop when it exists); Clear Undo
   restores the take untransposed. Rule 5.
10. Not undoable, no history entry, not an owned setting family for Speed and
    Transpose; Follow tempo and Pitch ARE Loop settings on the shared owner
    with inherit. Rule 4.
11. The cache cap default rises to 384 MiB on the strength of the Part 1 memory
    figures, and a render that does not fit leaves the track dry with the
    reason. Rule 2.
12. One recorded tempo per master; later takes' ratios derive from lengths.
    Rule 4 (no per-layer tempo table) without losing recording at a new tempo.
13. The library is vendored once, into the real build, from the bench snapshot
    (tag 1.1.0, `44c8f865`); the bench copy is removed. Rule 4.
14. `presetCheaper` with the 8 kHz tonality limit is the starting recipe; the
    listening check on the appliance may swap either without an API change.

## 8. Genuine product-direction questions (defaults above stand until the owner says otherwise)

1. Recording or overdubbing while Speed ≠ 1×: refused with a notice (taken), or
   allowed with the new material playing at the factor like everything else?
   Looper X and the RC-series differ here and the manual is not at hand; the
   engine design does not preclude either.
2. Overdubbing into a take recorded at a different song tempo under Follow
   tempo: refused (taken), or resampled into the take's rate? The latter is a
   second capture path (an input resampler at the write head).
3. While a Transpose render is pending: dry at true pitch with the marker
   showing pending (taken), or silence, or the stale previous render?
4. Should a Transpose pitch and the global Speed be saved with the Session
   (taken, following Reverse) or treated as performance-only state that
   recall resets?

## 9. Hardware-only evidence

The Part 1 thresholds, the per-part appliance re-runs, late-period counts from
`le_engine_get_callback_telemetry` during eight concurrent renders, the
listening checks (½× and 8× artefacts, ±12 st with and without the tonality
limit, the 10 ms turn on sustained material), footswitch and LED proof for
Parts 6a and 6b, and the behaviour of a retained reopen with pending renders
on the real ALSA loss path.
