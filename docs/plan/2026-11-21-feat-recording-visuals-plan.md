---
title: "A recording take shows its input, waveform, progress and bars"
type: feat
date: 2026-11-21
issue: 1936
---

# A recording take shows its input, waveform, progress and bars

<!-- cspell:words aubio specflux Ooura reinterprets retimed libaubio lbuf compases -->

Tracking: [#1936](https://github.com/tomassasovsky/segno/issues/1936),
`autonomy:plan-gate`. Brainstorm:
`docs/brainstorm/2026-11-21-recording-visuals-brainstorm-doc.md`, which has
the current behaviour, the research on other loopers and beat trackers, and
the alternatives rejected. The owner approved the six recommendations below
as written on 2026-11-21.

## Overview

Five parts, each shippable on its own, in this order:

1. **Input on the meter** (app only): an empty, recording or overdubbing
   track's meter shows its input.
2. **Progress, bars and elapsed time while recording** (engine snapshot and
   app): the progress bar and the bars figure count toward a known target; a
   free take shows its elapsed time.
3. **Recording waveform** (engine and app): the take's shape draws as it
   records, and is already there when the take closes.
4. **Tempo choice at the take's end** (engine, new dependency): onset
   analysis of the take picks the bar count, replacing "nearest 120 BPM", and
   a ÷2 / ×2 control corrects a wrong octave.
5. **Tempo estimate during the take** (engine and app): a tentative bar count
   while a free take records, shown only once it is stable.

## Decisions for the owner

### D1. Which empty tracks show their input

Recommended: **the selected track and any track with a record arm waiting**
(`Track.pending` with a record action). These are the tracks Record/Play will
record next. Every other empty track stays dark, so tracks that share an
input do not all move together.

Alternative: every empty track shows its input (what an armed track in a DAW
does when all are armed).

### D2. What an overdubbing track's meter shows

Recommended: **its input**, in the overdub colour, like a recording track:
the meter shows what the player is adding. The loop's own level stays on the
Mixer meters.

Alternative: playback as today, with the input only on recording tracks.

### D3. What a free take shows in the bars slot

Recommended: **elapsed time** (`0:07`) in the tile's bars slot and the Wave
row's count, replaced by the bar count when the take closes. Once part 5
lands, a stable estimate adds `≈ 4 bars` beside it.

### D4. The octave correction

Recommended: **÷2 and ×2 buttons beside the tempo** on the readout's Loop
panel (#1654) and on Loop settings > Tempo, shown while the tempo source is
`derived` and the loop has not been retimed since. They keep the audio and
halve or double the bar count, which halves or doubles the tempo. Nothing is
stretched.

### D5. How the beat analysis gets into the engine

Recommended: **vendor aubio's onset and tempo sources** (GPL-3.0-or-later,
plain C, with its own Ooura FFT) under `packages/segno_engine/src/third_party/aubio/`,
built by the engine's existing CMake. The engine builds the same way on the
Mac, in CI and in the appliance image, with no Yocto recipe or Homebrew step.

Alternative: link a system `libaubio`, which needs a Yocto recipe (or one from
meta-openembedded, if its version fits) and a Homebrew install on the Mac.

### D6. Which bar counts the end-of-take choice considers

Recommended: **1, 2, 4, 8 and 16 bars in the session's time signature, whose
tempo falls between 60 and 200 BPM**. The onset analysis scores those
candidates; with no clear winner (a flat score, a take with no onsets) the
engine keeps today's nearest-120 choice.

**Revised by the owner, 2026-11-21:** the analysis decides, and the length's
reading only stands in for it. A free take's tempo can't always be found
from its audio (a pad or a drone has no beat, and a clear beat is still
ambiguous between half and double), so the fallback is a better guess
rather than a refusal:

- The candidates run to 64 bars (1, 2, 4, 8, 16, 32, 64), the Looper X's
  longest preset, so a long take is not forced to a slow tempo.
- The derivation itself (`le_grid_derive_bpm`, D7) now takes the power of
  two nearest 120 within 60 to 200 BPM first, and any whole count nearest 120
  only when no power of two fits. Any whole count let a 4-bar take at 140
  read as 3 bars at 105; real loops are almost always 1, 2, 4 or 8 bars.
- The analysis overrules that reading only with a clear winner, a few
  milliseconds after the take closes. Meanwhile the app reports no tempo and
  no bars, so the figures go from none to the answer and never flip.
- A wrong octave is one tap away (÷2 / ×2, D4), and a player who wants
  certainty sets a length preset or taps the tempo first.

## Part 0: design

The Penpot file gets the recording states on page **25 Main views and
selected-track display**, next to the accepted **First recording** tile, each
with a `c/` note. Each part's frames land in Penpot with that part, in the
same pair of PRs:

- Tracks view, recording toward a target: red meter at the input level,
  progress bar filling, bars slot `2 / 4`.
- Tracks view, free take: elapsed time in the bars slot; the same with
  `≈ 4 bars` (part 5).
- Tracks view, the selected empty track showing its input (D1).
- Wave view, recording toward a target: the shape filling left to right,
  with the bar ruler of the target.
- Wave view, free take: the shape spanning the row and compressing as the
  take grows, with elapsed time.
- Readout (7-inch), selected track recording, both cases.
- The ÷2 / ×2 control (D4) on the readout's Loop panel and on Loop settings >
  Tempo (page 07 or 38).

A segno-design PR refreshes the snapshot and links the app PRs.

## Part 1: input on the meter

App only. The levels already reach the app on every poll.

- `packages/looper_repository/lib/src/models/meter_levels.dart`: `TrackLevels`
  gains `input`, the loudest of the track's lane inputs after each input's
  trim, `0..1`.
- `packages/looper_repository/lib/src/looper_repository.dart`,
  `_publishMeters`: computes `TrackLevels.input` from `inputPeaks`, each
  lane's `inputChannel` and the input setup's `trimDb`. A lane with input
  `-1` contributes nothing.
- `lib/looper/view/track_meters.dart`: `TrackPeakMeter` takes a
  `source` (`playback` or `input`) and selects `peak` or `input`. With
  `input`, the bar shows even when the track has no content, and never
  freezes.
- `lib/looper/view/track_column.dart`: picks the source from the state (D1,
  D2). The clip cap works on the input as it does on playback.

Tests:

- `packages/looper_repository/test/...`: `TrackLevels.input` follows the
  lane's input and trim, ignores other inputs, reads 0 with no input.
- `test/looper/view/track_meters_test.dart` and the track column tests: an
  empty selected track draws a bar from its input; a recording track draws
  its input in the record colour; a playing track still draws playback.
- Screenshot suites rendered and compared with the new Penpot frames.

## Part 2: progress, bars and elapsed time while recording

The engine publishes what it knows about the take; the app never recomputes
when a take ends.

Engine (`packages/segno_engine/src/core/`):

- `segno_engine_api.h`, `le_track_snapshot`: two fields.
  - `capture_frames`: frames captured in the take in flight, from the press
    (`record_pos - record_start`); 0 when the track is not recording a take.
  - `capture_target_frames`: where the take will end by itself:
    `length_preset_target_frames` for an armed preset, `eff * base` for a
    fixed multiple; 0 when nothing ends it (Auto, Sync, free).
- `engine_process.c`: publishes both at block end beside `a_len` and
  `a_play_pos`, as atomics per track.
- `engine_snapshot.c`: copies them into the snapshot.
- Native tests (`test_engine_length.h` or a new
  `test_engine_capture_progress.h`): a preset take reports its target and
  counts up to it; a fixed-multiple take over a master reports `eff * base`
  and counts from the press, not from the master's phase; a free take
  reports target 0; both fields read 0 once the take closes.

Dart:

- `packages/segno_engine/lib/src/engine_snapshot.dart` and the ffigen
  bindings: the two fields.
- `packages/looper_repository/lib/src/models/playhead.dart`: `Playhead`
  gains each track's capture (`frames`, `targetFrames`). It changes every
  poll, so it belongs with the playheads, not in `LooperState` (#1563).
- `looper_repository.dart`, `_progressOf`: a recording track with a target
  reports `frames / targetFrames` as its progress. `TrackProgressBar` and the
  readout's progress then move with no widget change.
- A new leaf widget, `TrackCaptureCount` (`lib/looper/view/`), follows the
  playhead like `TrackProgressBar` and fills the bars slot while the track
  records: `2 / 4` with a target and a tempo grid, `0:07` (D3) without.
  `TrackColumn`'s meta row and `WaveTrackRow`'s count use it.
- Readout (`lib/visualizer/performance_readout.dart` and the Loop panel): the
  same count for the selected track.
- Strings in `app_en.arb` and `app_es.arb`, with accessible labels.

Tests: repository projection of the fields; `_progressOf` while recording
with and without a target; widget tests for the count in each case; the
screenshot suites.

## Part 3: recording waveform

Engine:

- `engine_process.c`: a capture tap beside `track_viz_tap_frame`. For each
  RECORDING track, take the peak of the `insample` values its lanes write
  (after the capture trim) into the track's bucket accumulator.
  - With `capture_target_frames > 0`, a bucket covers `target / 512` frames,
    indexed from the press; the shape fills left to right.
  - With no target, a bucket starts at 256 frames (about 5 ms at 48 kHz).
    When the take fills 512 buckets, pairs merge into the first 256 and the
    width doubles. The shape always spans the row.
  - Publishes the filled bucket count per track (`viz_filled`, snapshot) and
    the buckets through `a_track_viz` as today.
- At finalize, the capture buckets are mapped onto the finished loop's 512
  buckets by taking the maximum over each loop bucket's span, so the first
  lap draws the shape at once. A take recorded over a master is shifted by
  its start phase (`record_start` modulo the loop) so bucket 0 is the loop's
  start.
- Cost on the callback: one compare per lane per frame while recording, a
  store per bucket, and a 512-float merge once per doubling.
- Native tests (a new `test_engine_track_viz.h`; the playback tap's tests
  are in `test_engine_core.c`): buckets fill
  while recording, in both modes; a merge keeps each pair's maximum; after
  finalize, the loop buckets match a reference built from the recorded
  buffer, for a defining take and for a take over a master; a playing
  track's sweep is unchanged.

Dart:

- `readTrackWaveform`: while a track records, returns the filled buckets
  (with a target: all 512, zeros beyond the fill; without: the first
  `viz_filled`, which the painter spreads across the row).
- `TrackWaveform` (`lib/looper/view/wave_track_row.dart`): draws the shape
  while recording, with the bar ruler of the target when there is one and
  none otherwise.
- `WaveformDisplayController` (readout and screen link): forwards the same.

Tests: widget tests for the Wave row in both modes; the repository's reads
while recording; the screenshot suites.

## Part 4: tempo choice at the take's end, and ÷2 / ×2

Engine:

- `third_party/aubio/` (D5): the onset detection function (`specflux` at
  hop 512, window 1024) and the tempo module, with only the sources they
  need, built into the engine library.
- An analysis worker thread (`engine_analysis.c`, new). The callback copies
  the defining take's input (the mono sum of its lanes' `insample`) into an
  SPSC ring (`audio_ring.h`); the worker drains it, computes the onset
  function per hop and keeps it for the take. The ring is prefaulted at
  engine start; the callback never allocates or waits.
- At finalize of a defining take whose tempo the engine derives (source
  `none`, sync on, no preset), the callback posts the take's length to the
  worker. The worker scores the D6 candidates by the onset function's
  autocorrelation at each candidate's beat period and replies with the bar
  count. The engine applies it as a reinterpretation (same length, new bar
  count and tempo). Until the reply arrives, the snapshot reports
  `tempo_settling`; the first-take tempo notice (page 38) waits for it. With
  no reply within 200 ms, the nearest-120 choice stands.
- A command that reinterprets the defining loop's bar count (×2 or ÷2) with
  the audio untouched, for D4. It refuses when the tempo was set or tapped,
  or when the result leaves the tempo range.
- Native tests: a synthetic click track at known tempos (70, 95, 140, 180
  BPM) recorded as a free take picks the right bar count; a take with no
  onsets keeps the nearest-120 choice; the reinterpretation keeps every
  sample and halves or doubles the bars; the ring is written without
  allocating or locking on the callback.

App:

- The ÷2 / ×2 control (D4) on the readout's Loop panel and Loop settings >
  Tempo, through `LooperRepository` and the loop settings cubit.
- The first-take tempo notice waits for `tempo_settling` to clear.

Measured on the console, with the method of #1724: callback time with the
copy into the ring, and the worker's CPU during a take.

## Part 5: tempo estimate during the take

- The worker runs aubio's causal tempo on the same onset function and
  publishes an estimate (BPM and confidence) per track as atomics.
- The snapshot carries `tempo_estimate_bpm` and `tempo_estimate_confidence`
  for a track recording a free defining take.
- The app shows `≈ N bars` beside the elapsed time when the confidence has
  stayed above a threshold for two seconds. N is `capture_frames` over the
  estimate's bar length, rounded down.
- The estimate never ends, trims or quantizes the take.
- Native tests: the estimate converges on a click track and stays at 0
  confidence on silence and on a sustained tone. Widget tests: the estimate
  shows only while confident and stable.
- Measured on the console beside part 4.

## Technical Considerations

- **Callback headroom (#1914, #1724).** Parts 1 and 2 add nothing to the
  callback beyond two stores per track per block. Part 3 adds a compare per
  lane per frame while recording. Parts 4 and 5 add one copy per frame into
  a ring while a defining take records; the analysis runs on its own thread.
- **Rebuilds (#646, #1563).** The capture fields change every poll, so they
  travel with the playheads and are read only by leaf widgets.
- **Thread placement.** The analysis worker runs below the audio thread's
  priority and off the audio core.
- **Licence.** aubio is GPL-3.0-or-later; the project is GPL-3.0. Its
  bundled Ooura FFT is under its own permissive licence. The vendored sources
  keep their headers and a `LICENSE` beside them.

## Success Criteria

```success-criteria
GOAL: A track that waits to record or records shows its input on the meter, draws its take as it records, counts toward a known end or shows elapsed time, and a free first take gets its bar count from what was played.

SUCCESS CRITERIA:
- The engine reports each recording track's captured frames and target, its recording buckets, and the analysis's bar choice, as the native tests specify | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The repository projects input levels, capture progress and recording waveforms, and the tiles, Wave rows and readout draw them | verify: /Users/Tomas/development/flutter-3.50/bin/flutter test
- Analysis is clean | verify: dart analyze && bloc lint lib test packages && dart run tool/check_no_widget_methods.dart
- On the console, playing guitar into the selected empty track moves its meter; recording a 4-bar preset take fills the progress bar and counts 1 / 4 to 4 / 4; the Wave view and the readout draw the shape as it records | verify: manual 1. Select an empty track with an input connected and play. 2. Set a tempo and a 4-bar length preset, record, watch the tile, the Wave row and the readout. 3. Compare with the Penpot frames.
- On the console, a free take of 4 bars of strummed guitar at about 90 BPM closes as 4 bars near 90 BPM, and ÷2 / ×2 correct a wrong choice without changing the audio | verify: manual 1. Clear the session, tempo unset, no preset. 2. Record 4 bars of strumming and close the take. 3. Read the tempo notice. 4. Press ×2 and ÷2 and listen.
- Callback time with parts 3 to 5 on stays within the budget #1724 measured | verify: manual 1. Run the #1724 in-app ladder on the console with a take recording. 2. Compare the late periods with the baseline.

NON-GOALS:
- Changing the loop's length or ending a take from the live estimate.
- Tempo detection while playing back, or following a live tempo (Ableton's Tempo Follower).
- Input levels for instrument lanes (#1197).
- Meters on the 7-inch readout beyond the selected track's count and waveform.

VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter-3.50/bin/flutter test && dart analyze && bloc lint lib test packages && dart run tool/check_no_widget_methods.dart
```

## Success Metrics

- The first take's shape is on screen when the take closes, with no blank
  lap.
- On the owner's own free takes, the bar count chosen at the end matches
  what was played more often than nearest-120 does. The owner keeps a short
  list of takes (instrument, intended bars) and compares both choices.

## Dependencies & Risks

- **Penpot**: part 0 needs the Penpot tab open with the MCP plugin.
- **Detection on sparse material**: sustained chords and voice give a weak
  onset function. The end-of-take choice falls back to nearest-120 when the
  score is flat, and the estimate does not show. Both are covered by tests
  on a sustained tone.
- **aubio size and build**: the vendored subset must build with the
  appliance's clang 18 and GCC, and with the Mac's clang, without warnings
  under the engine's flags.
- **Takes over a master**: the bucket mapping depends on the start phase and
  the latency offset (`rec_w = record_pos - offset`); the native test against
  the recorded buffer guards it.
- **#1914 is still open**: parts 4 and 5 are measured on the console before
  they merge.

## References & Research

- Track meter: `lib/looper/view/track_meters.dart`, `TrackPeakMeter`.
- Track sum: `packages/segno_engine/src/core/engine_process.c`, `trk_mix`
  near the lane meters.
- Playback tap: `engine_process.c`, `track_viz_tap_frame`.
- Capture write: `engine_process.c`, `insample` and `lbuf[rec_w]` in
  `mix_tracks_frame`.
- Finalize: `finalize_master`, `sync_grid_to_loop`, `le_grid_derive_bpm`
  (`tempo_grid.c`), `finalize_new_track`, `request_master_finalize`.
- Repository: `readTrackWaveform`, `_progressOf`, `_publishMeters` in
  `packages/looper_repository/lib/src/looper_repository.dart`.
- Readout: `lib/visualizer/application/waveform_display_controller.dart`.
- SPSC ring: `packages/segno_engine/src/core/audio_ring.h`, drained in
  `perf_drain.c`.
- Accepted frames: Penpot page 25 **First recording**, page 38
  **First-take tempo**.
- Sheeran Looper X user guide 1.0.0:
  https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf
- Ableton Live 12 manual, Looper and Tempo Follower:
  https://www.ableton.com/en/live-manual/12/live-audio-effect-reference/ ,
  https://www.ableton.com/en/live-manual/12/synchronizing-with-link-tempo-follower-and-midi
- Loopy Pro, first clip and tempo detection: https://wiki.loopypro.com/First_Clip
- aubio: https://aubio.org , tempo source
  https://github.com/aubio/aubio/blob/master/src/tempo/tempo.c
- BTrack (rejected): https://github.com/adamstark/BTrack

## As built

Five stacked PRs, each with its design half in segno-design:

1. Input on the meter: #1938 (design #28).
2. Progress, bars and elapsed time: #1939 (design #29).
3. Recording waveform, and the readout's count: #1940 (design #30).
4. Bar choice at the take's end, ÷2 / ×2: #1941 (design #31).
5. Live estimate: the PR that closes #1936 (design #32).

Where the build departs from this plan:

- **D6, revised by the owner on 2026-11-21:** the analysis decides, and the
  length only stands in for it. `le_grid_derive_bpm` itself prefers the
  power of two nearest 120 in 60 to 200 BPM, the candidates run to 64 bars,
  and the app shows no tempo while the analysis settles, so the bars never
  flip. See D6 above.
- **D1's colour.** An empty track's input bar uses the meter's empty tone,
  raised from an invisible #2E2E31 to #6E6E73 (4.1:1 on the tile).
- **The readout's count** (part 2) shipped with part 3, which reworked the
  same `WaveformDisplayController`.
- **A recording take draws no playhead** in the Wave row or on the readout:
  the progress shows on the count and the progress bar.
- **aubio** lives in `packages/segno_engine/third_party/aubio`, beside the
  other vendored code, with its includes rewritten to relative paths, and
  compiles as one TU, `src/core/le_aubio.c`.
- **The first-take tempo notice** (part 4) does not exist in the app. The
  repository uses `tempo_settling` instead: it reports no tempo and no bars
  until the analysis answers.
- **÷2 / ×2 on the readout** sit beside the tempo figure, not in the step
  row: six touch targets do not fit the card.
- **The live estimate** shows only after aubio's confidence has reached 0.2
  with the tempo steady within 3% for two seconds: aubio's tempo alone reads
  about 122 BPM on silence, a held tone and noise.
- **The estimate replaces the time** (D3 said beside it): `≈ 2` bars in the
  count's usual form. The Tracks view's bars slot has no room for both: in
  Spanish `0:07 ≈ 3 compases` truncated. Only the take the analysis hears
  shows it (`tempo_estimate_track`).
- **Not measured on the console yet:** the analysis worker's CPU and the
  callback's added copy.

