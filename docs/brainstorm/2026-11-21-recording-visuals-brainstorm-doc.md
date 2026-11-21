---
{}
---

# A recording take shows its input, its waveform, its progress and its bars

<!-- cspell:words aubio BTrack Essentia Quantiloop Tzanetakis Percival madmom libtempo libsamplerate retimes retiming -->

Tracking: [#1936](https://github.com/tomassasovsky/segno/issues/1936),
`autonomy:plan-gate`.

## What We're Building

While a track waits to record or records, its meter, its waveform and its
progress bar show what is happening:

- **Input level on the track meter.** An empty track's meter shows the level
  of the input it will record from. A recording or overdubbing track's meter
  shows the input it is capturing, in the record colour.
- **Recording waveform.** The Wave view and the 7-inch readout draw the take
  as it records. When the take closes, the loop's shape is already drawn; it
  no longer takes one lap of playback to appear.
- **Progress and bars while recording.** When the take's length is known in
  advance (a length preset with a tempo, or a fixed multiple of the master
  loop), the progress bar fills toward it and the bars figure counts up.
- **Free take.** With no tempo and no target, the track shows the elapsed time
  and a waveform that grows with the take.
- **Tempo detection.** The engine listens to the take for its beat. It shows a
  tentative bar count while recording once the estimate is stable, and uses
  the same analysis to choose the bar count when the take closes.

The owner set this scope on 2026-11-21, with the Sheeran Looper X and Ed
Sheeran's stage screen as references (answers recorded on #1936).

## Where it stands

- **Meter.** `TrackPeakMeter` (`lib/looper/view/track_meters.dart`) reads
  `TrackLevels.peak`, the sum of the track's lane playback samples
  (`engine_process.c`, `trk_mix`). A recording track plays nothing back, so
  `loopsample`, and with it the peak, is 0 for the whole take. The accepted
  **First recording** tile (Penpot page 25) draws the recording track's meter
  as a red bar at the input level, so the app departs from an accepted frame
  today. `MeterLevels.inputPeaks` already carries each hardware input's raw
  peak, and each lane names its `inputChannel`.
- **Waveform.** `track_viz_tap_frame` fills a track's 512 buckets
  (`LE_VIZ_POINTS`) only while it plays or overdubs, indexed by the play
  position over the loop length. The first take writes nothing. On finalize
  the buckets are still zero, and the shape draws in over the first lap.
  The Dart side already re-reads the buckets on every poll while a track
  captures (`LooperRepository.readTrackWaveform`); the buckets are empty.
- **Progress.** `Playhead.track` is forced to 0 while a track records
  (`_progressOf`). The engine publishes the growing write head as both length
  and position then.
- **Target length.** The engine knows it in two cases: a length preset armed
  on a defining take (`length_preset_target_frames`) and a fixed multiple on a
  later take (auto-finalize at `record_pos - record_start >= eff * base`).
  Neither the target nor `record_start` is in the snapshot. Auto, Sync and
  free takes have no target until the press that ends them.
- **Elapsed time.** No surface shows how long the current take has run. The
  footer clock is the session's running time; the top bar's `mm:ss` is the
  performance capture's.
- **Tempo.** A free first take derives its tempo when it closes:
  `le_grid_derive_bpm` picks the whole bar count whose tempo is nearest
  120 BPM (`tempo_grid.c`). Nothing in the engine detects onsets or beats.
  The tuner is the only analysis on the callback (decimated YIN under a work
  budget); `fft.h` has a real FFT and a Hann window.

## How other loopers do it

- **Sheeran Looper X** (user guide 1.0.0): while recording, the track's level
  and loop progress indicators turn red and the Track view meter shows the
  incoming level. With Track Length on Auto and the click off, it detects the
  first track's tempo and bar count when the take ends. Two time counters sit
  in the bottom bar.
- **Ableton Live**: an armed track's meter shows the input. The Looper device
  turns red while recording and guesses the tempo only when the take ends,
  warning that the guess may be half or double. Live's Tempo Follower tracks
  an input continuously and takes a couple of seconds to pick up a clear
  4/4 beat.
- **Loopy Pro**: the first loop sets the tempo within a detection range
  (about 80 to 220 BPM), with a ÷2 / ×2 correction and rounding. Its
  automatic loop detection analyses the take while it records, assuming
  power-of-two bar counts and percussive material.
- **Boss RC-505mkII / RC-600**: a ring indicator per track can show the loop
  position; while recording with no length yet, it cycles once per bar at the
  memory's tempo.

Every one of them shows the input on an armed or recording track, and a
recording colour. None shows a firm bar count during a free first take; the
tempo and bars are settled when it ends.

## Why This Approach

**Input level.** Read in the app from `MeterLevels.inputPeaks` over the
track's lane inputs, scaled by each input's trim. It needs no engine change,
and the levels already reach the app on every poll. Rejected: a new per-track
capture peak in the engine, which would only add instrument lanes, and
instruments are not built (#1197).

**Recording waveform.** The engine writes the take's peaks while it records,
from the input sample it already writes to the lane buffer (`insample`, after
the capture trim), into the same 512 buckets:

- with a target length, each bucket covers `target / 512` frames and the
  shape fills left to right;
- with no target, each bucket starts at a fixed width; when the take fills
  all 512, neighbouring pairs merge and the width doubles, so the shape always
  spans the row and compresses as the take grows. A merge touches 512 floats
  once per doubling.

At finalize the buckets are mapped onto the finished loop, so the first lap
already has its shape. The cost on the callback is one compare per lane per
frame and a store per bucket. Rejected:

- building the shape in the app from polled input peaks: the poll is 16 ms
  and each reading is one block's peak, so most of the signal between polls
  never reaches the shape;
- a scrolling window of the last seconds: it does not show the take as one
  loop, and the owner described the shape of what is being recorded.

**Progress, bars and elapsed time.** The engine publishes, per track, the
frames captured so far and the target length (0 when none). The app derives
the progress, the live bar count from the tempo grid, and the elapsed time
from these. Rejected: recomputing the target in the app from the preset, the
multiple and the click mode; it would duplicate the engine's arming rules and
drift from them.

**Tempo detection.** In two layers, because the research is consistent that a
causal tracker needs 6 to 11 seconds of a clear beat before it is stable, and
a 4 to 8 bar take of guitar or voice often gives less than that:

1. **At the take's end**: an onset-strength analysis of the take scores the
   power-of-two bar counts whose tempos fall in a range, and picks the best
   one. This replaces "nearest 120 BPM". The tempo stays exact to the frame
   because it still comes from the take's length; the analysis only chooses
   between half, normal and double.
2. **During the take**: the same onset signal runs a causal tempo estimate.
   The track shows a tentative bar count ("≈ 4 bars") once the estimate is
   confident and stable, and nothing when it is not. It never ends or trims
   the take.

The analysis runs on a worker thread fed by a lock-free ring from the
callback, the pattern `audio_ring.h` and the performance capture use. The
callback only copies the capturing input. Library: aubio (GPL-3.0-or-later, C,
no allocation in its process calls) for the onset function and the causal
tempo, which fits the project's GPL-3.0. Rejected:

- BTrack: GPL-3.0 and causal, but 44.1 kHz is hard-coded in its beat-period
  arithmetic and it needs C++, libsamplerate and an FFT library;
- Essentia: AGPL-3.0 and heavy, and its rhythm extractor works on whole
  tracks at 44.1 kHz;
- madmom: Python, neural models under a non-commercial licence;
- an in-house estimator from Percival and Tzanetakis (2014): small, but the
  project prefers an established library where one fits.

## Key Decisions

- **Meter source by state**: an empty track shows its input; a recording or
  overdubbing track shows its input in the state colour; a playing or stopped
  track shows playback as today. Overdub shows the input because that is what
  the player is adding; the loop's own level is on the Mixer.
- **One bucket buffer**: the recording waveform reuses the 512 buckets and the
  existing read path, so the Wave view, the readout and the screen link get it
  without new plumbing beyond a filled-bucket count.
- **The engine owns the target**: the app never recomputes when a take will
  end.
- **Detection never changes the loop during the take.** It shows an estimate
  while recording and chooses between bar counts at the end. A set or tapped
  tempo always wins over it.
- **A wrong octave needs a correction**: every product that guesses a tempo
  offers one. Segno has none today: the readout's tempo keypad and steps
  (#1654) set a new tempo, which retimes the loop. See Open Questions.
- **Layers**: input meter, then progress and elapsed time, then the recording
  waveform, then the end-of-take analysis, then the estimate during the take.
  Each ships on its own.

## Open Questions

- **Empty tracks**: does every empty track show its input, or only the
  selected one (the one Record/Play will record)? Every empty track sharing an
  input moves together.
- **aubio in the image**: is there a Yocto recipe the console can use, or does
  the engine vendor the onset and tempo sources it needs?
- **Detection range and signature**: which tempo range does the end-of-take
  choice search (Loopy Pro uses about 80 to 220 BPM), and does it consider
  only the session's time signature?
- **Takes over a master loop**: a take recorded against an existing loop
  starts mid-cycle. Its buckets must line up with the finished loop's index;
  the plan works out the mapping from `record_start`.
- **Octave correction**: a "÷2 / ×2 bars" control after a derived tempo that
  reinterprets the loop (same audio, half or twice the bar count and tempo)
  instead of retiming it. Where does it live, and is it in this issue?
- **CPU**: the onset function and the causal estimate must be measured on the
  console with the effects budget of #1724 in place.
