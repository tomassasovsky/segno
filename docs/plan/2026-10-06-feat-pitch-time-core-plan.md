# Pitch and time core: Speed, Transpose, Audio & tempo follow, import Adapt

<!-- cspell:ignore varispeed lerp lbuf wdub Signalsmith signalsmith numer SCHED untransposed sidelobe retiming Retiming retimes retimed retime regrid halfband Neoverse milli fmod crossfades hujm YMPRG Bmpo -->

Status: approved with required review edits E1-E15, which are applied in this
text (the review is kept at the owner's evidence store,
`claude-published-review/1179-plan-review/review.md`). Part 1 is a measured
CPU spike whose numbers gate the rest.
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
| 15 Performance · Speed | `01 / Speed / Normal` (SO34L), `02 / Half speed` (Q29ROp), `03 / Eight times` (jY5NQ), `04 / Empty loop` (YMPRG), `05 / Tracks / Speed indicator` (usAz6) | Parts 2a, 6a |
| 11 Performance · Transpose | `01 / Transpose` (k5GTy), `02 / across banks` (yBmpo), `03 / with no selection` (JTxQq), `04 / at pitch limit` (lpGO0), `Transpose bypass · pitches retained / Tile` (FJ8Ys) | Parts 3a, 6b |
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
  int32_t reversed; /* direction (Reverse plan) */
  double origin;    /* source-frame origin; re-set so the index is continuous at a change */
  double rate;      /* source frames per song frame = speed * (len_src / play_len) */
} le_read_head;
/* Source index for the UNBOUNDED song position `pos` (see 2.3) on a track whose
 * source holds `len_src` frames: forward (origin + rate*pos) mod len_src,
 * reversed (origin - rate*pos) mod len_src. No libm: the modulus is an int64
 * quotient, never fmod/floor. */
static inline double le_head_index(const le_read_head*, int64_t pos, int32_t len_src);
/* Re-origins so le_head_index == index at `pos`. */
static inline double le_head_origin(const le_read_head*, double index, int64_t pos, int32_t len_src);
/* Linear interpolation with wrap. frac == 0 returns buf[i] exactly. */
static inline float le_head_sample(const float* buf, int32_t len, double index);
/* Box of floor(rate) source samples from floor(index), wrapped: the
 * first-order anti-alias for rate >= 2 (first sidelobe -13 dB). */
static inline float le_head_sample_decimated(const float* buf, int32_t len, double index, double rate);
/* Weight of the new head i frames into a window of F: equal-gain (i/F) for a
 * rate or direction turn (same material, continuous at the turn), equal-power
 * (sin(i/F * pi/2), polynomial, no libm) for a swap between source kinds. */
static inline float le_head_turn_mix(int32_t i, int32_t F, int32_t equal_power);
/* A lap wrap between two consecutive indices, in the head's direction. */
static inline int le_head_wrapped(double prev, double next, int32_t reversed, int32_t len);
```

`rate == 1` and `origin ∈ ℤ` reproduces today's integer path bit-for-bit
(`le_head_sample` returns `buf[i]` when the fraction is zero); `rate == 1`,
`reversed == 1` reproduces the Reverse plan's `le_direction_index`. The Reverse
plan says Speed's head is where "`le_direction_index` generalises" (its §1.5);
this header is that generalization. Sequencing (E12): Reverse Part 1 is being
built now with `engine_direction.h`. Part 1 of this plan ships
`engine_read_head.h` as the pure header the bench and its unit tests need;
Part 2a then rebases onto Reverse's header and generalizes it IN PLACE: the
two files become one `engine_read_head.h`, `le_direction_index` becomes
`le_head_index` at rate 1 (bit-exact, Reverse's tests unchanged),
`le_direction_origin` / `le_direction_lap_start` become `le_head_origin` /
`le_head_wrapped`, and Reverse's `turn_left / turn_reversed / turn_offset`
become `le_read_head prev_head; int32_t turn_left;`, the pair that also serves
rate steps and source swaps below: one crossfade mechanism, two named laws.

Precision: `pos < 2^31 × k`, `rate × pos < 2^37`, the double mantissa has 53
bits; the index is derived from the clock each frame, never integrated, so
nothing drifts.

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
`idx = le_head_index(&tr->head, song_pos, len_src)`.

`song_pos` is UNBOUNDED (E1), never the wrapped per-frame position: with
`rate = ½` a bounded `seg_base + trk_pos` would span only half the take and
snap back at every wrap. On the shared clock `song_pos = (loop_iteration -
start_iter) × clock.length + clock.position` (an int64 count of song frames
since the track's start; at rate 1 it reproduces `seg_base + trk_pos` for
multiples, and for a division because `L % (L/n) == 0`); in Free/Song
`song_pos = free_iteration × free_clock.length + free_clock.position`. The head
is re-set (`le_head_origin`, continuity at the current index) at every
discontinuity of that count: the transport hold (`:4480-4484` in the Reverse
plan's numbering), Stop/Play of the track, `le_restart_once`, and Part 4a's
position scaling. Keep `(seg_base, trk_pos)` integer for the write paths (they
only run at rate 1, §2.5). The dry read at `:5833` becomes `loopsample =
le_head_sample(lbuf, len, idx)` (`_decimated` when `rate >= 2`), with the
identity fast path `lbuf[seg_base + trk_pos]` kept verbatim for the default
head so the existing suite stays bit-identical. Metering reads the same
`loopsample`. `trk_play_pos[t]` (`:5584`) publishes `floor(idx)` in source
frames, so `position_frames / length_frames` stays the track's progress.

Decimation (E5): `le_head_sample_decimated` is a box of `floor(rate)` samples,
a first-order anti-alias (first sidelobe −13 dB), acceptable for a
pitch-coupled performance effect at 2×. The Part 2a listening check at 4× and
8× is its gate. The named fallback, if that check fails: worker-rendered
half-band-decimated sources (`restore_halfband.c` already provides the 2:1
stage; 4× and 8× are two and three stages) as a kind-2 cache entry read at
rate 1, measured by the Part 1 harness's `render` scenario before it is built.
8× is not left without a fallback.

Turn window: while `turn_left > 0`, also read `old = le_head_sample(src_prev,
len_prev, le_head_index(&tr->prev_head, …))` and mix with `le_head_turn_mix`,
`F = seam_xfade_frames(e)` (about 10 ms), decremented once per frame per
track after the lane loop beside the seam countdown (`:6086-6098`). A rate
step (Speed press), a direction toggle (Reverse) and a source swap (§3) all
start the same window; loops shorter than `2F` snap, mirroring the punch-fade
rule (`:5645-5650`). Two laws, one helper with a flag (E5): equal-gain for a
rate or direction turn (the two heads read the same material and are
continuous at the turn), equal-power for a swap between source kinds (dry to
render, render to render, bypass: uncorrelated signals, where equal-gain dips
6 dB at mid-fade).

Turn-window memory safety (E4): `F = sr/100` is 960 frames at 96 kHz, fifteen
64-frame periods, while the cache frees a retracted entry after two
processed-buffer boundaries. So, while `turn_left > 0`, the audio thread
publishes the previous source per track (`a_turn_source`, a pointer, plus its
lane's slot or entry identity); the collector (`engine_cache.c:537`) defers
freeing any graveyard entry a track's `a_turn_source` still names; and any
control-side pool free or slot reuse (undo slot recycling, lane shrink,
import) that would hit a track's turn source snaps that track's window
(`turn_left = 0`) before the free, through the existing quiescent handshake. A
Part 2a ASAN test steps a rate, retracts and frees inside the window.

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

- `LE_CMD_SET_SPEED` takes the next free command code at rebase (E13: this
  text assigns no numbers; Reverse holds 83 and Multiply/Divide's plan holds
  `LE_CMD_SET_LENGTH = 84`; the audited table row in
  `docs/design/performance-event-log-format.md` and the `le_log_extract`
  exclusion list are the collision check), payload `struct { int32_t numer,
  denom; } speed;` with the five factors as `{1,2} {1,1} {2,1} {4,1} {8,1}`;
  checked, never raw-posted (add to the `le_push` refusal list,
  `engine.c:1299-1300` per the Reverse plan). Public
  `le_engine_set_speed(engine, numer, denom, uint64_t* request)` next to Fade,
  through the shared receipt table (`le_request_admit` from the Reverse plan;
  the reader is `le_engine_read_request_result`).
- Callback application: `speed_global` is one engine field; the handler
  re-origins every content track's head so the index is continuous, starts
  their turn windows (equal-gain), publishes `a_speed_numer/denom`, pushes the
  fact, writes the receipt. Normal (`{1,1}`) restores only this factor
  (`rate_t` keeps its tempo term). "Repeated 2× stays 2×" (E6): a request
  equal to the current factor is receipt-only: no re-origin, no turn window,
  no fact, no change to the mix; tested as such.
- Snapshot: trailing `int32_t speed_numer, speed_denom;` on `le_snapshot`
  (global) and `int32_t head_rate_milli;` on `le_track_snapshot`
  (`segno_engine_api.h:932`, the effective per-track rate ×1000 so the UI can
  show the derived pitch and progress without re-deriving).
- Perf fact `LE_PLOG_SPEED = 327` (Reverse 324, Peel/Multiply 325–326 per the
  gap inventory's sequencing note), payload `{int32_t numer, denom; uint64_t
  index_q32;}` (E3): the exact `le_head_index` at the change in Q32.32, the
  frame being the record header's, mirroring Reverse's logged `read_index`.
  Pushed at every accepted change, at every re-origin (hold, Stop/Play,
  relaunch, retiming) and at every material reset, so the renderer anchors
  from a logged index rather than integrating from capture start. events.log
  version: whichever of the 324–328 plans lands next takes the next version
  (`perf_drain.c:819` reads 6 today; the stem plan's rule). The renderer
  (`perf_render.c:829`, segment read `:1099`) applies the same
  `le_head_index`/`le_head_sample` from the logged index and `(numer, denom)`,
  so a stem at ½× is sample-exact against the live mix.
- Provenance tracker (E2): the 322/323 tracker (`engine_process.c:5586-5634`)
  expects `perf_source_next_pos == phase` with `phase = trk_play_pos % len`,
  which a non-identity head breaks every frame. Decision: `phase` is logged
  in SONG-position space (`song_pos mod play_len`), unchanged at rate 1, and
  the renderer derives the source index through the logged head. This keeps
  322/323 integer and exact under Part 4a, where a source-space phase could
  exceed the image length and fail `perf_render.c:924`. A Part 2a test asserts
  zero 323 facts over a two-lap ½× run and an 8× run.
- Material resets (`le_fade_reset` sites, `:184-199` and callers; Reverse's
  `le_transform_reset`, whose import-time command is `LE_CMD_RESET_TRANSFORMS`
  at the value of today's `LE_CMD_RESET_FADE` 82) reset the head to identity.
  The stem plan's E8 holds: that command is pushed only on EMPTY tracks and a
  non-EMPTY caller must not reset provenance through it. Speed itself is global
  and survives a single track's Clear; New Loop resets it (§4).

## 3. Transpose: a rendered source read through the head

### 3.1 Source render entries

Extend `le_wet_entry` (`engine_private.h:427-434`) with `int32_t kind;`
(0 = Pre print, 1 = source render), `int32_t semitones;` and `int32_t out_len;`,
and the key predicate (`:443-449`) with those three fields; every comparison
site moves together, as its comment demands. The kind-1 key (E8) is
`{audio_rev, kind, semitones, out_len}` with `chain_fp = 0` and `vol_bits = 0`
fixed, inside the one predicate: a source render is pre-chain and pre-volume,
so a volume move or a chain edit never re-renders it. A source render is mono
(`pcm` of `out_len` floats: lanes are mono before the chain), rendered from
the lane's live dry slot at content revision `audio_rev`, by the stretcher at
ratio `out_len / len` (1 for Transpose) and `setTransposeSemitones(semitones,
8000/sr)` (the tonality limit the README recommends; the listening check may
drop it). The lap is rendered as a cyclic signal: the worker feeds the last
`W = block + interval` source frames, the lap, then the first `W`, and keeps
the central `out_len` output frames, so the render loops as seamlessly as the
seam-folded dry does. Determinism: the stretcher is constructed on the worker
with a fixed seed (D0 note 5), and the sample rate and preset change only
through configure / `le_cache_init`, so a re-render of the same key in the
same configuration is byte-identical, which is also what makes the offline
stem (§3.4) exact.

Jobs are per TRACK: one job renders every active lane of the track at the
same key and publishes the entries together, so a track never plays two lanes
at two pitches. Publication, retraction, LRU and the quiescent handshake are
the cache's existing ones; the memory cap is shared. Eviction (E7): a kind-1
entry that matches a PLAYING track's current key is never evicted (evicting it
would play dry, a silent pitch change, rule 3); Pre prints are evicted first
(optional: the live chain computes the same function); a kind-1 job that
still does not fit is refused with the reason in `le_lane_cache_info` (the Pre
print's existing rule) and the track stays dry, reported. Default cap: Part 3a
raises `LE_CACHE_DEFAULT_CAP_BYTES` from 64 MiB to 384 MiB (a 30 s mono lane
at 96 kHz is 11.5 MiB; eight transposed single-lane tracks are 92 MiB; the Pi
5 has 8 GiB and the bench records peak RSS). A fully populated 8-track ×
8-lane 30 s rig at 96 kHz would need 737 MiB of kind-1 entries and is refused
per track, so the Transpose face must expect "pending / refused" on dense
rigs. Worker priority (E9): the cache worker runs `SCHED_OTHER` at nice +10 on
Linux so a twelve-second eight-lane render yields to the Flutter UI thread;
the audio thread is already SCHED_FIFO 80. The Part 1 `render` scenario
measures with that nice applied.

Latency fact for the face: a semitone step lands after the debounce plus the
render (about 1.6 s for a single 30 s lane on the Pi 5 at the Part 1
threshold, about 12 s for eight lanes); the face shows stored and effective so
the wait is visible, never silent.

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

- `LE_CMD_TRANSPOSE` and `LE_CMD_TRANSPOSE_BYPASS` take the next free command
  codes at rebase (E13), payload `struct { int32_t channel, install,
  semitones; } transpose;` (`install = 0` steps by `semitones` ±1 and clamps
  at ±12 with the result in the receipt, so "at pitch limit" is reportable;
  `install = 1` sets, for Session recall) and `arg_i` 0/1 for the bypass.
  Public `le_engine_transpose_step(engine, channel, delta, request)`,
  `le_engine_install_transpose(engine, channel, semitones, request)`,
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
- Facts: `LE_PLOG_TRANSPOSE = 328` `{int32_t channel, stored, effective,
  source_kind; uint64_t index_q32;}` at every effective change (render
  engaged, dry fallback, bypass), the index being the head's exact
  `le_head_index` at the swap frame (E3) so the renderer places the
  equal-power turn exactly and knows which frames played which source.

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

With Follow tempo on (`a_follow_tempo`, default 0 in Part 4a so an existing
rig behaves exactly as today until the page exists; Part 4b flips the default
to 1 together with the page that can turn it off, E15; per-track override
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
`LE_CMD_SET_FOLLOW_TEMPO` / `LE_CMD_SET_PITCH_MODE` (next free codes at
rebase, E13) each carry `{channel (-1 = default), value (-1 inherit)}` and a
receipt. Session (schema
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
   About license notices. Add `src/stretch/le_stretch.h` (plain C: opaque
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
   The harness prints the CPU model (`/proc/cpuinfo` "CPU part": 0xd0b is the
   Pi 5's Cortex-A76) and the scheduling it obtained, and refuses `--assert`
   without `--proxy` on anything but a Cortex-A76.
   Acceptance thresholds, asserted by the harness (non-zero exit on failure):
   - **Proxy (E10), the gate Part 1 and Part 2 close on.** A new CI job
     `native-bench-arm64` on `ubuntu-24.04-arm` (the runner `build-linux-arm64`
     already uses, `.github/workflows/main.yaml:148`) runs
     `bench_pitch_time.sh --budget-us 667 --assert --proxy` and uploads the
     arm64 harness binary as an artifact for the owner to copy to the
     appliance. `--proxy` asserts p50 and throughput only (a shared Neoverse
     VM without SCHED_FIFO has no meaningful p99), at half the Pi thresholds
     (Neoverse N2/V2 is roughly 1.5-2.5× an A76 single-thread, so this keeps a
     2× margin): `head` added p50 ≤ 5 % of the period at 8 lanes and ≤ 17 % at
     64 lanes for every factor and ratio; `render` ≥ 40× real time per mono
     lane with `presetCheaper`; `memory` as below.
   - **Pi 5 (E11), the measurement D2 rests on.** On the appliance (Yocto
     image, SCHED_FIFO, both displays attached, app running), with
     `--budget-us 667 --assert`: `head` added p99 ≤ 10 % of the period at 8
     lanes and ≤ 35 % at 64 lanes for every factor and ratio; `baseline` p99 +
     `head` p99 ≤ 50 % of the period at 8 lanes (if `baseline` alone exceeds
     that, it is a pre-existing finding to report on its own issue, not this
     plan's gate); `render` ≥ 20× real time per mono lane under load with
     `presetCheaper` (a 30 s lap in ≤ 1.5 s; an eight-lane track in ≤ 12 s).
     This measurement gates **Part 3a's merge** and Part 2a's listening check,
     not Part 1 or Part 2, because the Pi cannot be driven unattended.
   - `memory` (both): a kind-1 entry costs `out_len × 4` bytes plus under 1 MiB
     of worker scratch; stretcher heap per instance recorded.
   - `inline` has no threshold; its p99 relative to the period is recorded.
4. `docs/plan/2026-10-06-pitch-time-spike-findings.md`: the tables from the
   arm64 proxy, from the dev machine (informational, ratios only) and, when
   the owner has run the artifact, from the Pi 5; the reproduce commands; the
   gate verdicts. The first time both proxy and Pi numbers exist the document
   records the proxy/Pi ratio, which is the scaling note every later run uses.
   If `render` fails its Pi threshold the plan returns to the owner before
   Part 3a (escalation to `plan-gate`): the fallback candidates are
   `presetCheaper` with a smaller block, or a lower-cost shifter for
   Transpose, both measured by the same harness.

Build note: the shim's C header must stay plain C (`_Atomic`-free) because it
reaches the VST3 C++ TUs through nothing today but will the moment a core
header includes it; the repro in `docs/PROGRESS.md` is part of the verify list.

```success-criteria
GOAL: The appliance's per-period cost of the fractional read head and the worker throughput of the stretcher are measured on the Pi 5 at 96 kHz / 64 frames, the vendored library and its C shim compile in every build the engine ships in, and the read-head header is proven exact.
SUCCESS CRITERIA:
- The read-head header reproduces the integer path bit-exactly at rate 1 and visits the expected indices at the five factors, both directions and the two tempo ratios; the stretch shim renders an exact-length output for a 30 s input at ratio 1, 0.75 and 1.333. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- The harness builds and its smoke run passes on macOS and Linux x64; the C++17 shim repro compiles with the new header; the FFI symbol check passes against the built library. | verify: bash packages/segno_engine/src/test/bench/bench_pitch_time.sh --smoke && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && manual: the docs/PROGRESS.md shim repro with engine_read_head.h and le_stretch.h included
- Dart analysis, Bloc lint and the Dart suites stay clean (no Dart production change expected beyond the licence notice). | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- The arm64 proxy job passes its p50 and throughput assertions and publishes the harness artifact; the findings document carries the proxy and dev-machine tables with the CPU model and scheduling each run obtained. | verify: CI job native-bench-arm64 green on the PR head (bash packages/segno_engine/src/test/bench/bench_pitch_time.sh --budget-us 667 --assert --proxy on ubuntu-24.04-arm)
- HARDWARE (informational for Part 1; gates Part 3a): the artifact run on the appliance Pi 5 at 96 kHz / 64 frames with the app running meets the Pi thresholds; its table and the proxy/Pi ratio are added to the findings document when it exists. | verify: manual: copy the native-bench-arm64 artifact to the appliance and run bench_pitch_time.sh --budget-us 667 --assert; record the output in the findings document
- HARDWARE: on the appliance Pi 5 at 96 kHz / 64 frames with the app running, every threshold above holds and the findings document carries the tables and the verdict. | verify: manual: scp the arm64 harness (built on the build-linux-arm64 runner or the bench Pi) to the appliance and run bench_pitch_time.sh --budget-us 667 --assert; record the output in the findings document
NON-GOALS:
- Any mixer, command, snapshot, Session or UI change; a decision on inline streaming beyond recording its cost.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && bash packages/segno_engine/src/test/bench/bench_pitch_time.sh --smoke && dart analyze --fatal-infos lib test packages
```

### Part 2a. Native Speed and the head in the mixer (about 400 production lines)

Sections 2.2–2.6 complete, native only: the head on `le_track` (beside
`playback_offset`, `engine_private.h:1272`), the in-place generalization of
Reverse's `engine_direction.h` into `engine_read_head.h` (E12), the unbounded
`song_pos` and its re-origin sites, the mixer rewrite at
`engine_process.c:5569-5578` and `:5833`, the turn window with `a_turn_source`
and the collector's deferral, lap edges, print-engage conditions,
`LE_CMD_SET_SPEED` (next free code), `LE_ERR_TRANSFORMED` guards, receipts
through `le_request_admit`, snapshot fields, fact 327 with `index_q32`, the
song-space provenance phase, renderer parity, material resets. No Dart change
beyond the regenerated bindings for the new API, which Part 2b consumes; no
mode entry, no UI.

Tests (`src/test/test_engine_speed.h`, literal PCM through
`le_engine_process`; ramp PCM so the index is the sample), each failing
without the change: ½× over two song laps reads indices `0 .. len-1` once
(E1) with interpolated values `i + 0.5` on odd frames, at 44.1/48/96 kHz and
blocks 1/64/127/512; a Sync division at ½× (E1); 2×/4×/8× visit `2i`/`4i`/`8i`
with the decimated box oracle; a step 1× -> 2× at index 37 is continuous (37,
39, 41 …) with the equal-gain mix inside the turn window; a repeated 2×
request produces a receipt, no fact and no mix change (E6); Normal after 4×
keeps the index continuous; multiple 2 at ½× cycles both segments over four
song laps; a Sync division at 2× laps `2n` times per primary cycle; Free/Song
private clock; Once lap end at the head wrap in both directions; two lanes
read the same index; Fade continues through a step; the Pre print disengages
on a step and never engages at a non-identity head; record and overdub
refused with `LE_ERR_TRANSFORMED` and dropped on the callback when armed
before the change; a change refused while RECORDING/OVERDUBBING/armed/count-in;
receipts for rapid double presses; Clear/undo-to-empty/new capture/import reset
the head and log the fact; zero 323 facts over a two-lap ½× run and an 8× run
(E2); the renderer reproduces a ½× and an 8× stem sample-exactly including the
turn, anchored from the logged `index_q32` (E3); a rate step followed by a
retract and free inside the turn window under ASAN (E4); `position_frames`
runs at the head's rate. The existing suite stays byte-identical (a regression
guard, not counted as a failing test).

```success-criteria
GOAL: A checked native global Speed reads every recorded track at ½×, 1×, 2×, 4× or 8× through one fractional head over an unbounded song position, click-free and exact over time, with the song clock, click, quantize and capture untouched, confirmed receipts and exact offline replay.
SUCCESS CRITERIA:
- Literal PCM proves the five factors over whole takes, continuity at steps, the repeated-factor no-op, multiples, divisions, Free/Song, Once, two-lane parity and Fade independence at three rates and four block sizes; the default head keeps every pre-existing test byte-identical. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Capture refusals and drops return LE_ERR_TRANSFORMED, never write through a non-identity head, and a change during capture is refused; material resets publish identity and log the fact; no 323 fact is emitted by a non-identity head alone. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Offline stems at ½× and 8× match the live mix sample-exactly from the logged index; the turn window never reads freed memory; sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings regenerate and format cleanly, the symbol check passes, and the proxy bench stays within its thresholds with the real mixer path. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && CI job native-bench-arm64 green
- HARDWARE (gates this part's listening check, not its merge): the Part 1 artifact re-run on the appliance with the real mixer path at ½×, 4× and 8× stays within the Pi thresholds and the box decimation passes the listening check at 4× and 8×, else the kind-2 half-band fallback is scheduled. | verify: manual: bench_pitch_time.sh --budget-us 667 --assert on the appliance after Part 2a, plus the listening session per docs/PROGRESS.md
NON-GOALS:
- Dart seam beyond bindings, Transpose, tempo follow, Session persistence, mode entry, UI, mappings, anti-alias beyond the box average.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2b. Speed Dart seam and repository (about 250 production lines)

`AudioEngine.setSpeed(SpeedFactor) -> RequestAdmission` and
`readRequestResult` (`audio_engine.dart:280-286` pattern),
`EngineSnapshot.speed`, `TrackSnapshot.headRate`, `EngineResult.transformed`,
`NativeAudioEngine`, `MockAudioEngine`, the four fakes
(`test/helpers/fake_audio_engine.dart`, the three package fakes),
`LooperRepository.setSpeed` through `_requestReceipt` (the renamed
`_requestFade`, `looper_repository.dart:1972-2018`), `LooperState.speed`
projection, the record-refusal notice path for `transformed`. One
actual-native repository case (`packages/looper_repository/test/
speed_native_test.dart`, fixture of `fade_native_test.dart:13-45`) confirms
the receipt, the projection and the record refusal; mock and fake cases cover
the admission and result mapping.

```success-criteria
GOAL: The repository can set and observe the global Speed through confirmed receipts and projects it, with the refused record reported, while the public app is unchanged.
SUCCESS CRITERIA:
- The actual-native repository case confirms a receipt, projects the factor and surfaces the record refusal. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test)
- Mock, fakes and result mapping are complete; the package and app suites pass. | verify: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test
- Static gates clean. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Mode entry, UI, mappings, Session persistence.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3a. Native Transpose: source renders on the cache worker (about 450 production lines)

Section 3 complete, native only: `le_wet_entry.kind/semitones/out_len` and the
one key predicate with the kind-1 key rule (E8), the kind-1 job on the cache
worker (`engine_cache.c`: enqueue copy of every active lane's live slot at
`audio_rev`, render through `le_stretch` with cyclic padding, publish per
track), the no-eviction rule for engaged kind-1 entries and Pre-prints-first
eviction (E7), the worker's nice level (E9), the 100 ms debounce, the cap
raise, the verdict's source selection in `snapshot_lane_cache`, the
equal-power source swap through the turn window with `a_turn_source`,
`LE_CMD_TRANSPOSE`/`_BYPASS` (next free codes), admission, the record guard,
snapshot fields, fact 328 with `index_q32`, renderer parity (the stretch TU
linked into `perf_render.c`), material resets. Its merge is gated by the Pi 5
`render` measurement (E11).

Tests (`src/test/test_engine_transpose.h`), each failing without the change:
a +12 st render of a sine at 220 Hz peaks within 1 % of 440 Hz in its spectrum
and keeps the exact length; the render loops without a discontinuity at the
wrap (cyclic padding: the first and last 1024 output frames of two
consecutive laps are identical); a +2 st step on a playing track plays dry
until the render lands, then crossfades to the render at the same index with
the equal-power mix and reports `effective == stored` only after the swap; a
second step while the first render is pending re-keys the job and lands once;
a volume move and a chain edit do not re-render (E8); an engaged kind-1 entry
survives cap pressure that evicts a Pre print, and a job that cannot fit is
refused with the reason (E7); bypass swaps to dry and back with pitches kept;
an overdub on a transposed track is refused, while Undo to a previously
rendered slot re-engages its cached entry within one block; Clear resets to
0 st; the renderer's stem matches the live transposed mix sample-exactly from
the logged index; two rapid presses produce two receipts; render identity
under a fixed seed (two renders of the same key compare equal); a swap whose
old source is retracted and freed inside the turn window under ASAN (E4).

```success-criteria
GOAL: A checked per-track Transpose plays a pitch-shifted render of the track's own takes at unchanged timing, built off the audio thread by the one cache worker at a priority below the UI, never evicted while it plays, swapped click-free, truthful about what is sounding, with a global bypass that keeps stored pitches, and exact offline replay.
SUCCESS CRITERIA:
- Render length, loop continuity, pitch, determinism and the dry-until-ready then equal-power crossfade behaviour are proven with literal and spectral oracles; `effective` never claims a pitch the mix is not playing. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Bypass, limit (±12 reported in the receipt), capture refusal, Undo re-engagement, the kind-1 key's independence from volume and chain, the no-eviction rule, cap refusal and material resets behave as specified; the turn window never reads freed memory; sanitizer and telemetry-off pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- The offline stem of a transposed track matches the live mix sample-exactly across the swap. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings regenerate and format cleanly and the symbol check passes. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)"
- HARDWARE (gates this part's merge): the Part 1 Pi 5 `render` threshold holds (≥ 20× real time per mono lane under load), eight transposed single-lane 30 s tracks render while playing with no late period (telemetry late_periods unchanged over the run), and the listening check passes at ±12 st with and without the tonality limit. | verify: manual: appliance session per docs/PROGRESS.md hardware evidence rules, reading le_engine_get_callback_telemetry before and after; the Pi table in the findings document
NON-GOALS:
- Dart seam beyond bindings, transposed overdubbing, Pre prints over a transposed source, tempo follow, Session, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3b. Transpose Dart seam and repository (about 250 production lines)

`AudioEngine.transposeStep/installTranspose/setTransposeBypass`,
`TrackSnapshot.transpose` (stored, effective), `EngineSnapshot.transposeBypass`,
`NativeAudioEngine`, `MockAudioEngine`, the four fakes; repository
`transposeTrack(channel, delta)`, `installTranspose`, `setTransposeBypass`,
`Track.transpose` projection with stored and effective, the record-refusal
notice. Actual-native repository case in `transpose_native_test.dart`
(a step, the dry-pending projection, the landed render's `effective`, the
bypass, the record refusal); mock and fake cases for admission, the ±12 limit
result and the mapping.

```success-criteria
GOAL: The repository can step, install and bypass Transpose through confirmed receipts and projects stored and effective pitches truthfully, while the public app is unchanged.
SUCCESS CRITERIA:
- The actual-native repository case confirms receipts, projects stored and effective through the pending window and the swap, and surfaces the record refusal. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test)
- Mock, fakes, the limit result and the mapping are complete; the package and app suites pass. | verify: (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test
- Static gates clean. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Mode entry, UI, mappings, Session persistence.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 4a. Native Audio & tempo follow (about 450 production lines)

Sections 4.1–4.3 complete with Follow tempo DEFAULT OFF (E15, today's
behaviour until the page can turn it off): `recorded_tempo_bpm`, the lock relaxation, retiming
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

Section 4.4: the Follow tempo default flips to On together with the page
that can turn it off (E15); schema bump with `recordedTempoBpm`, follow/pitch defaults and
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
Part 1 (spike; proxy gate on CI, Pi artifact for the owner)
 └─ Part 2a Speed native ── Part 2b Speed seam
        │                       └─ Part 6a face
        └─ Part 3a Transpose native (merge gated by the Pi render number)
               ├─ Part 3b Transpose seam ── Part 6b face
               ├─ Part 4a Follow native (default Off) ── Part 4b page + Session (default On)
               └─ Part 5 Session/reopen/Adapt (schema bump shared with 4b)
```

Part 2a rebases onto Reverse Part 1 (#1162) and generalizes its
`engine_direction.h` in place (E12); it also shares `le_request_admit`,
`le_transform_reset` and the record-guard site in `le_record_impl` with
Reverse and #1161, so it lands after both. Part 3a edits `le_wet_entry`, the
key predicate and `engine_cache.c`, which no open plan touches. Part 4a
relaxes `le_tempo_locked`, which the MIDI clock plan (E8-1) will build on.
Part 5's schema bump is shared with Part 4b and follows Reverse Part 2 and
Multiply/Divide: whichever lands later takes the next number. Command codes
and fact codes are assigned at rebase, never in this text (E13). Each part
runs normal, ASAN and telemetry-off native suites, `dart analyze
--fatal-infos`, Bloc lint, and the independent architecture, test-quality and
adversarial reviews before the human merge gate. Review ceiling 700 production
lines per part; stop for review on any second read coordinate, a bounded song
position, a second render worker, a capture path through a non-identity head,
a new Dart owner, an eviction of an engaged source render, or a change to the
song clock's advance.

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
15. The head's song position is unbounded and re-set at every clock
    discontinuity (E1); provenance phases are logged in song space (E2); every
    head change logs its exact index (E3). Rule 3: the stem is exact or it fails.
16. The turn window pins its previous source until it ends (E4). Rule 2.
17. Two crossfade laws by cause, equal-gain for turns and equal-power for
    source-kind swaps (E5); the box decimation has a named, measured fallback.
18. A repeated factor is receipt-only (E6).
19. An engaged source render is never evicted; a source render never keys on
    volume or chain (E7, E8). Rule 3.
20. The Pi 5 measurement is a hardware gate on Part 3a's merge; Parts 1 and 2
    close on the arm64 proxy (E10, E11). Rule 2: the number D2 rests on is
    measured where it matters, without making a part impossible to close.
21. Follow tempo ships Off until its page exists (E15). Rule 1.
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
listening checks (½× and 8× artifacts, ±12 st with and without the tonality
limit, the 10 ms turn on sustained material), footswitch and LED proof for
Parts 6a and 6b, and the behaviour of a retained reopen with pending renders
on the real ALSA loss path.
