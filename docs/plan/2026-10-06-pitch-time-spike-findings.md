# Pitch/time core, Part 1: the measured CPU spike

<!-- cspell:ignore varispeed Neoverse signalsmith fmod SCHED rnnoise noexcept lbuf -->

Tracking: #1179, Part 1 of
[the plan](2026-10-06-feat-pitch-time-core-plan.md). Status: the harness, the
vendored library and its C shim, and the read-head header are built; the
dev-machine run is recorded below as information; the arm64 proxy run is the
CI job `native-bench-arm64` on the PR head; the Pi 5 table is appended when the
owner has run the uploaded artifact on the appliance.

## What was built

- `packages/segno_engine/third_party/signalsmith-stretch/` (tag 1.1.0, commit
  `44c8f865`, MIT), moved from under the bench into the real build; the July
  D0 harness (`bench_stretch.cpp`, `bench.sh`) is removed, superseded by the
  harness below. `third_party/README.md` carries the vendoring note.
- `packages/segno_engine/src/stretch/le_stretch.{h,cpp}`: the C ABI over the
  library (create/destroy, latency and geometry getters, semitones, streaming
  process/seek/flush, and `le_stretch_render_offline`, the exact-length
  cyclic-or-padded render). The only C++ TU of the portable engine; compiled
  by CMake (C++17 now enabled unconditionally; `-fvisibility=hidden` on Linux,
  as the RNNoise TUs are), by `run_native_tests.sh` and
  `tool/build_test_lib.sh` with `$CXX`, and by the macOS SPM/CocoaPods
  forwarders (`macos/segno_engine/Sources/segno_engine/le_stretch.cpp`,
  `macos/Classes/le_stretch.cpp`). The vendored header is included relatively
  from the TU, so no build gained an include path.
  - No C++ exception crosses the C boundary: every exported function is
    `noexcept` and catches inside, so an allocation failure is `NULL` or
    `LE_STRETCH_ERR_ALLOC`, never `std::terminate`. Channels are capped at
    `LE_STRETCH_MAX_CHANNELS` (16, a track's eight stereo lanes), the sample
    rate at `LE_STRETCH_MAX_SAMPLE_RATE` (384 kHz) and a render's time ratio
    to [1/16, 16] (`LE_STRETCH_MAX_RATIO`, so no frame count derived from it
    can overflow); `le_stretch_create(INT32_MAX, ...)`, which used to abort
    the process with an uncaught `std::length_error`, now returns `NULL`.
  - The offline render streams. The lap is fed straight from `in[]` and
    written straight into `out[]`; only the pre-roll and run-out chunks (the
    lap's own tail and head when cyclic) are assembled, in block + interval
    frames of scratch per channel, and the discarded latency frames and the
    tail go to a sink of the same order. The first version copied the whole
    lap into a padded buffer and buffered the whole output, about 26 MiB of
    scratch for a 30 s mono lap at 96 kHz; see the memory figures below.
- `packages/segno_engine/src/core/engine_read_head.h`: the pure fractional
  read coordinate (`le_read_head {reversed, origin, rate}`, `le_head_index`,
  `le_head_origin`, `le_head_sample`, `le_head_sample_decimated`,
  `le_head_turn_mix` with the equal-gain and equal-power laws,
  `le_head_wrapped`, the Q32.32 helpers). No libm, no `_Atomic`; the PROGRESS
  C++17 shim repro compiles with it and with `le_stretch.h`.
- Tests: `src/test/test_engine_read_head.h` (identity exactness over 10⁶
  positions, ½× visiting every index twice with `i + 0.5` on odd frames,
  2×/4×/8× visiting `r·i` with the box oracle, tempo ratios against an `fmod`
  reference, re-origin continuity for rate and direction changes, exactly four
  wraps over four laps in both directions, the two crossfade laws, Q32) and
  `src/test/test_engine_stretch.h`:
  - preset geometries, streaming at 64 frames per call, the argument guards
    (including `INT32_MAX` channels and sample rate, for create and render);
  - +12 st doubles a 220 Hz sine's spectral peak to 440 Hz at the exact length
    and level, −12 st halves it, stretches at 0.75 and 4/3 keep the pitch and
    fill the requested length, stereo and the default preset, same-seed
    determinism byte-for-byte;
  - **alignment**: over the plan's 30 s input, clicks at 1 s, 15 s and 29 s
    come out within 2 ms of `frame × ratio` at ratios 1, 0.75 and 4/3, cyclic
    and padded (measured: exact at 1 and 0.75, 2 to 14 frames early at 4/3);
  - **the cyclic seam**: a 3 s lap of a sine with a whole number of cycles at
    every ratio renders a loop whose wrap step `out[n−1] → out[0]` is within
    the render's own largest neighbour step (+25 %), and clicks 20 ms before
    the lap's end and 20 ms after its start come out 20 ms × ratio either side
    of the loop point.

  Mutation proof: with the latency compensation dropped (`discard = 0`) both
  new tests fail (25 failed checks: every click lands one stretcher block
  late, about 100 ms at 48 kHz, and the shifted render no longer meets the
  seam); with the cyclic run-out or pre-roll replaced by silence the seam
  continuity check fails at 0.75 and 4/3 (wrap steps of 0.08 to 0.62 against
  a largest neighbour step of about 0.02). All of it runs in
  `run_native_tests.sh` in the plain, ASAN and telemetry-off configurations.
- `src/test/bench/bench_pitch_time.{c,sh}` and `bench_alloc.cpp` (a counting
  global `operator new`, linked into the bench only): the harness (scenarios
  below), `--smoke` in the `native-tests` CI job, `--assert --proxy` in the
  `native-bench-arm64` job on `ubuntu-24.04-arm`, which uploads the binary and
  its report as the artifact `bench-pitch-time-arm64`. That step runs with
  `shell: bash` (`bash -eo pipefail`): under the default `bash -e` the
  `| tee` made the step's status tee's, so a failed threshold or a failed build
  left the job green. Proof, the step's own pipe run locally with a
  deliberately failing `--budget-us 1`: exit 0 under `set -e`, exit 1 under
  `set -eo pipefail`.
- `tool/test/run_macos_rnnoise_wiring_tests.sh` also checks the stretch
  forwarders and that the shim compiles with no search path.
- Licenses: the app's open source notices (System > About, read from
  `LicenseRegistry`) listed no vendored native code at all; Flutter only
  collects Dart packages' `LICENSE` files. `segno_engine` now ships each
  vendored library's license file as a package asset and registers it
  (`registerVendoredLicenses`, called once in `runSegno`): Signalsmith Stretch
  and its `dsp/` (MIT), RNNoise (BSD-3-Clause), miniaudio (Unlicense or
  MIT-0; `src/miniaudio/LICENSE` is the header's license block, copied
  verbatim), the VST3 SDK (MIT) and CLAP (MIT). A Dart test reads the registry
  back and compares each entry with the file on disk.

## Method

`bench_pitch_time.sh [--smoke] [--seconds N] [--loop-seconds N] [--rate HZ]
[--period FRAMES] [--budget-us N] [--assert] [--proxy]` builds the harness
against the real engine sources and runs, each over `--seconds` of simulated
audio at `--rate` / `--period` (defaults 60 s, 96 kHz, 64 frames, so the
budget is the appliance's 667 µs period; loops of `--loop-seconds`, default
30 s):

| scenario | what is timed | reported |
|---|---|---|
| `baseline` | `le_engine_process` per 64-frame period, 8 tracks × 1 and × 8 lanes of 30 s content PLAYING, snapshot polled every 64 periods | p50 / p99 / max / mean µs and % of budget |
| `baseline` at a Speed (Part 2a) | the same mixer with every track read through its head after `le_engine_set_speed` at 1/2, 4/1 and 8/1, past the turn window — the real mixer path the Part 2a gate names; asserted at 8 tracks × 1 lane and × 8 lanes: p50 ≤ 25 % (proxy), p99 ≤ 50 % (Pi 5) | the same |
| `baseline` with Pre chains (Part 2a review) | 8 tracks × 8 lanes, a two-entry Pre chain (filter, drive) on every lane, at 8/1: off 1x no print engages, so every chain runs live on the callback, the appliance's worst case for this part | the same; judged on the Pi only, p99 ≤ 50 % |
| `head` | the `engine_read_head.h` kernel over 8 and 64 lanes in a loop shaped like the mixer's lane loop, at ½×, 2×, 4×, 8× and the tempo ratios 0.75 and 4/3; ≥ 2× uses the box decimation. The control is the mixer's integer read (`position % len` per track, one `lbuf[seg_base + trk_pos]` load per lane), which Part 2a keeps for identity heads; the identity head is timed as a row of its own | the same, plus the worst ADDED cost (rate minus the integer control) |
| `render` | `le_stretch_render_offline` on one 30 s mono lane, both presets, ±12 st at ratio 1 and stretches at 0.75 and 4/3; idle, then under load (a second engine paced at the period on a real-time thread). The renders run on their own SCHED_OTHER thread at nice +10, the cache worker's priority | × real time, the peak C++ heap during the render, and the render's scratch (that peak minus one stretcher) |
| `inline` | streaming `le_stretch_process` at 64 output frames per call for 1 / 8 / 64 streams, hop-aligned and hop-staggered, plus one `seek` re-prime | per-period stats (informational) |
| `memory` | live C++ heap per mono stretcher instance and the worst render scratch, both counted exactly by `bench_alloc.cpp`; bytes per rendered entry; peak RSS | KiB / MiB |

Scheduling: the timed loops of `baseline`, `head` and `inline` raise the
harness thread to SCHED_FIFO 70 where the kernel allows it, below the app's
audio thread at 80, so a run beside the app is preempted by the app's callback
instead of starving it; the thread drops back to SCHED_OTHER between loops.
The renders never run real-time. The report prints the CPU model
(`/proc/cpuinfo` "CPU part"; 0xd0b is the Pi 5's Cortex-A76; the part alone
when there is no model-name line) and the scheduling of the timed loops, the
renderer thread and the load thread, each read back from the kernel on that
thread (policy, priority, nice) rather than inferred from a call's return.
Nice is per thread on Linux; elsewhere it is process-wide, which is why the
renders run last.

`--assert` carries the Pi 5 thresholds and is refused on anything but a
Cortex-A76 unless `--proxy`, which asserts the arm64 CI proxy set (p50 and
throughput only, at half the Pi figures). Thresholds are the plan's Part 1
table; both sets also assert the plan's memory criterion, render scratch under
1 MiB.

## Dev machine (informational)

Apple M4 Pro (macOS, Apple clang 21), `bench_pitch_time.sh --budget-us 667
--assert --proxy --seconds 20`: 96 kHz, 64-frame period (667 µs budget), 20 s
per scenario (the CI setting), 30 s loops, no real-time scheduling available.
The proxy verdicts are printed because the harness asserts them anywhere with
`--proxy`; this machine is neither the Pi nor the proxy, so they gate nothing.

- CPU: Apple M4 Pro
- timed loops (baseline, head, inline): SCHED_OTHER, nice 0 (no real-time scheduling on this platform), held only for the loop
- rate 96000 Hz, period 64 frames, budget 667.0 us, 20 s per scenario, 30 s loops

### baseline (le_engine_process, 8 tracks PLAYING)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 8 tracks x 1 lane                  |     23.5 |     30.4 |    180.3 |     23.7 |    3.5% |    4.6% |
| 8 tracks x 8 lanes                 |     46.9 |     79.6 |   9065.5 |     49.8 |    7.0% |   11.9% |

### head (engine_read_head.h kernel; 'added' = minus the mixer's integer read)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 8 lanes integer read (control)     |      0.2 |      0.4 |     19.7 |      0.3 |    0.0% |    0.1% |
| 8 lanes identity head              |      1.0 |      1.3 |     11.0 |      1.0 |    0.1% |    0.2% |
| 8 lanes 1/2x                       |      1.1 |      1.5 |     10.9 |      1.1 |    0.2% |    0.2% |
| 8 lanes 2x                         |      1.3 |      1.7 |     14.1 |      1.4 |    0.2% |    0.3% |
| 8 lanes 4x                         |      1.7 |      2.2 |     15.8 |      1.7 |    0.2% |    0.3% |
| 8 lanes 8x                         |      2.5 |      3.3 |     12.2 |      2.6 |    0.4% |    0.5% |
| 8 lanes ratio 0.75                 |      1.0 |      1.4 |      3.0 |      1.1 |    0.2% |    0.2% |
| 8 lanes ratio 4/3                  |      1.0 |      1.4 |     19.1 |      1.1 |    0.2% |    0.2% |
| 8 lanes worst ADDED                |      2.3 |      2.9 |          |          |    0.3% |    0.4% |
| 64 lanes integer read (control)    |      4.3 |      6.2 |     19.6 |      4.4 |    0.6% |    0.9% |
| 64 lanes identity head             |      6.4 |      8.5 |     24.3 |      6.5 |    1.0% |    1.3% |
| 64 lanes 1/2x                      |      6.6 |      8.8 |     24.5 |      6.7 |    1.0% |    1.3% |
| 64 lanes 2x                        |      8.3 |     10.8 |     27.5 |      8.4 |    1.2% |    1.6% |
| 64 lanes 4x                        |     11.4 |     14.4 |     49.5 |     11.5 |    1.7% |    2.2% |
| 64 lanes 8x                        |     17.9 |     22.8 |     47.0 |     18.1 |    2.7% |    3.4% |
| 64 lanes ratio 0.75                |      6.9 |      8.4 |     29.2 |      7.0 |    1.0% |    1.3% |
| 64 lanes ratio 4/3                 |      7.2 |      9.8 |     90.7 |      7.3 |    1.1% |    1.5% |
| 64 lanes worst ADDED               |     13.6 |     16.7 |          |          |    2.0% |    2.5% |

### inline (streaming le_stretch_process, 64 frames per call; informational)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 1 streams aligned                  |      0.2 |    225.5 |    293.6 |      4.0 |    0.0% |   33.8% |
| 1 streams staggered                |      0.2 |    225.1 |    311.4 |      4.0 |    0.0% |   33.8% |
| 8 streams aligned                  |      1.6 |   1799.1 |   2177.8 |     31.7 |    0.2% |  269.7% |
| 8 streams staggered                |      1.7 |    241.7 |    386.8 |     32.5 |    0.2% |   36.2% |
| 64 streams aligned                 |     13.6 |  15583.8 |  96564.5 |    277.1 |    2.0% | 2336.4% |
| 64 streams staggered               |    249.7 |    508.4 |    704.4 |    267.8 |   37.4% |   76.2% |

seek re-prime (block + interval frames): 12.3 us (1.8% of the period)

### render (le_stretch_render_offline, 30 s mono, x real time)

| configuration              |   idle |   loaded | peak heap KiB | scratch KiB |
|----------------------------|--------|----------|---------------|-------------|
| cheaper +12 st ratio 1     |  165.8x |   164.5x |          1176 |          71 |
| cheaper -12 st ratio 1     |  169.6x |   168.8x |          1176 |          71 |
| cheaper stretch 0.75       |  228.3x |   227.0x |          1176 |          71 |
| cheaper stretch 4/3        |  128.8x |   129.0x |          1176 |          71 |
| default +12 st ratio 1     |  132.9x |   129.3x |          1184 |          79 |
| default stretch 0.75       |  188.9x |   144.2x |          1184 |          79 |

renderer thread (read back): SCHED_OTHER, nice 10; load thread (read back): SCHED_OTHER, nice 10

### memory

- stretcher live heap per mono instance: cheaper 1105 KiB, default 1105 KiB
- render worker scratch (peak C++ heap during a render minus one stretcher), worst recipe: 79 KiB
- rendered entry: 2880000 frames x 4 = 11.0 MiB per mono lane (the caller's buffer, outside the scratch)
- peak RSS: 870 MiB

### verdict (arm64 proxy thresholds, informational here)

- PASS: head added p50 at 8 lanes <= 5% of period (0.34 vs 5.00)
- PASS: head added p50 at 64 lanes <= 17% of period (2.04 vs 17.00)
- PASS: render cheaper under load >= 40x real time (128.98 vs 40.00)
- PASS: render worker scratch under 1 MiB (0.08 vs 1.00)
- PASS: stretcher heap per instance (cheaper) <= 4 MiB (1.08 vs 4.00)

The same harness linked against the first version of the shim (the whole lap
copied and the whole output buffered) measures 19,855 to 26,448 KiB of render
scratch and fails that criterion (25.83 MiB against 1 MiB).

## arm64 proxy (CI, `native-bench-arm64`)

Filled from the first green run of the job on the PR head; the report is the
job's `bench-pitch-time-arm64.md` artifact. Until then: pending.

## Pi 5 (hardware; gates Part 3a)

Pending the owner's run of the `bench-pitch-time-arm64` artifact on the
appliance. `upload-artifact` does not keep file modes, so the binary arrives
without its executable bit:

```sh
chmod +x bench_pitch_time
./bench_pitch_time --budget-us 667 --assert
```

When both this and the proxy table exist, the proxy/Pi ratio is recorded here
and becomes the scaling note for later runs.

What the owner measures on the appliance before Part 3a (Transpose) merges
(plan E11; none of it can run here):

1. `./bench_pitch_time --budget-us 667 --assert` with the app running: the
   `render` rows must stay >= 20x real time per mono lane under load with
   `presetCheaper` (a 30 s lap in <= 1.5 s), and the mixer rows at 1/2x, 4x
   and 8x within 50 % of the period at p99. That includes the two rows the
   Part 3a review added (M3): 8 x 8 with a Pre chain on every lane at 8x,
   and the same rig with every track transposed +7 st, timed once all
   eight sound it (a transposed track never engages a print, decision 7, so
   every chain runs live on the callback). The bench prints how many tracks
   sounded the pitch, how long the 64 renders took, and the peak RSS after
   them; record all three here.
2. Eight single-lane 30 s tracks, each transposed (+7 st) while playing:
   `le_engine_get_callback_telemetry` read before and after the eight renders
   land shows `late_periods` unchanged (the worker runs at nice +10 on Linux
   and must not disturb the callback).
3. A listening check at +12 and -12 st on a sustained and a percussive take,
   with the 8 kHz tonality limit (as shipped) and without it, and at the
   loop point (the 20 ms fold) on a sustained chord, recorded here with the
   verdict. The fold's level now follows the two signals' local
   correlation (review L1; within 1.5 dB of their blended level in the
   native test, against -5.2 to +4.6 dB with the fixed equal-power law), so
   the check listens for a swell or dip once per lap.
4. The app's peak RSS (`VmHWM` in `/proc/self/status`) during eight 30 s
   renders at 96 kHz with the eight tracks playing, against the memory
   table below.
5. The joint CPU scenario below, in the same session as the instruments
   bench (#1197), once its Part 1 exists.

### Joint budgets with backing (#1200) and instruments (#1197)

**Memory.** The appliance budget is #1200's D11 table (8 GB, no swap, one
process). Part 3a's review asked whether the wet-cache cap still fits it.
It did not at 384 MiB: that table already lists 1.5 GiB of backing buffers,
a 1 GB decode, 264 MiB of capture rings and loops that grow with use, and
counts the wet cache at 64 MiB. The cap is now 192 MiB:

- 64 MiB is the Pre prints' old share, kept;
- 128 MiB is Transpose's: eight transposed single-lane 30 s tracks at
  96 kHz (8 x 11.5 MiB = 92 MiB) plus the one source job in flight (its
  dry copy and render, 2 x 11.5 MiB);
- a denser rig (more lanes per transposed track) is refused per track with
  `LE_CACHE_REASON_BUDGET` and plays dry, reported, as the plan says.

#1200's D11 row "Loop-stage wet cache: 64 MiB" becomes 192 MiB.

**CPU.** #1197's D2 defines the joint worst case on the Pi 5 (96 kHz,
64-frame period, 667 µs, SCHED_FIFO, the app running), judged on p99.9 with
no late period over the run: the 8 x 8 baseline, eight monitored inputs
through one reverb each, the read head at 8x over the 64 lanes, and 32
voices of the costliest patch, p99.9 at most 75 %. Pitch/time's share of
that scenario is now the worst row above, not the chain-free baseline: 8 x 8
with a Pre chain on every lane, every track transposed, at 8x. The
instruments bench's `joint` scenario should build its pitch/time part the
same way (chains on, prints off, renders engaged), and this document records
the pitch/time rows from the same appliance session so the two add up on
one machine.

## Reading the dev-machine numbers

- `baseline`: today's engine spends 3.5 % of the period at p50 (4.6 % p99) with
  eight single-lane tracks playing, 7.0 % (11.9 %) with sixty-four lanes. The
  max columns (180 µs, and one 9.1 ms) are scheduler preemption on a non-RT
  thread, as the D0 spike also saw; judge against p99.
- `head`: the fractional read costs almost nothing where it matters. Measured
  against the mixer's integer read, the worst ADDED cost is 2.9 µs at p99 for
  8 lanes (0.4 % of the period) and 16.7 µs for 64 lanes (2.5 %), at 8× with
  the box decimation, which is the most expensive factor (eight reads per lane
  per frame). Against the identity head, as the first version measured, those
  figures were about 1 µs and 4 µs lower: the identity head itself costs 0.8 µs
  (8 lanes) and 2.1 µs (64 lanes) more than the integer read. The Pi
  thresholds (10 % / 35 %) leave a factor of 25 and 14 for a Cortex-A76 that is
  several times slower; the proxy thresholds (5 % / 17 % at p50) a factor of 15
  and 8.
- `render`: `presetCheaper` renders a 30 s mono lap at 129–228× real time
  (0.13–0.23 s), `presetDefault` at 129–189×; the +12 st shift and the 4/3
  stretch are the slowest recipes. Streaming the render did not cost
  throughput (the first version measured 120–206× on the same machine).
  Running beside a second engine paced at the period changed little here,
  because this machine has cores to spare; the Pi's four cores are why the
  loaded figure is the one the thresholds read. Against the Pi threshold of
  20× this leaves a factor of 6 for the A76's slowdown; against the proxy's 40×
  a factor of 3.
- `inline` (informational, the D2 decision's evidence): streaming the
  stretcher at 64 output frames per call puts one STFT hop every 30 periods,
  and that hop costs about 225 µs on this machine: p99 for a SINGLE stream is
  34 % of the 667 µs period, 8 hop-aligned streams are 1.8 ms (270 %), 8
  staggered streams 242 µs (36 %), 64 staggered 508 µs (76 %). The July
  spike's "GO inline" was measured at 10 ms blocks, where the same hop is
  2.5 % of the block; at the appliance's period it is a burst the audio thread
  cannot carry even on an M4 Pro, before the Pi's slowdown. A `seek` re-prime
  of block + interval frames costs 12.3 µs here (1.8 % of the period), cheap in
  itself; the rest of the inline cost is the hop, which a worker pays
  off-thread.
- `memory`: a mono stretcher instance is 1105 KiB of C++ heap at 96 kHz (both
  presets reach the same FFT size there). A render holds that plus 71 KiB
  (cheaper) or 79 KiB (default) of scratch, against the plan's 1 MiB; the
  rendered 30 s mono entry is the caller's 11 MiB. The harness peaked at
  870 MiB resident with its 64 full-length lane buffers plus the 8 × 8-lane
  rig; the engine's own pools are the bulk of that.

Dev-machine verdict: nothing here is a gate, but every Pi and proxy threshold
holds with a wide margin on this machine, the head kernel adds at most 2.5 %
of the period over the integer path at 64 lanes, the render's scratch is under
a tenth of its budget, and the inline figures document why pitch-preserving
work is pre-rendered.
