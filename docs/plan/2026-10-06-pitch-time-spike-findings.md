# Pitch/time core, Part 1: the measured CPU spike

<!-- cspell:ignore varispeed Neoverse signalsmith fmod SCHED -->

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
  by CMake (C++17 now enabled unconditionally), by `run_native_tests.sh` and
  `tool/build_test_lib.sh` with `$CXX`, and by the macOS SPM/CocoaPods
  forwarders (`macos/segno_engine/Sources/segno_engine/le_stretch.cpp`,
  `macos/Classes/le_stretch.cpp`). The vendored header is included relatively
  from the TU, so no build gained an include path.
- `packages/segno_engine/src/core/engine_read_head.h`: the pure fractional
  read coordinate (`le_read_head {reversed, origin, rate}`, `le_head_index`,
  `le_head_origin`, `le_head_sample`, `le_head_sample_decimated`,
  `le_head_turn_mix` with the equal-gain and equal-power laws,
  `le_head_wrapped`, the Q32.32 helpers). No libm, no `_Atomic`; the PROGRESS
  C++17 shim repro compiles with it and with `le_stretch.h`.
- Tests: `src/test/test_engine_read_head.h` (identity exactness over 10⁶
  positions, ½× visiting every index twice with `i + 0.5` on odd frames,
  2×/4×/8× visiting `r·i` with the box oracle, tempo ratios against an `fmod`
  reference, re-origin continuity for rate and direction changes, wrap
  detection in both directions, the two crossfade laws, Q32) and
  `src/test/test_engine_stretch.h` (preset geometries, streaming at 64 frames
  per call, +12 st doubles a 220 Hz sine's spectral peak to 440 Hz at the
  exact length and level, −12 st halves it, stretches at 0.75 and 4/3 keep the
  pitch and fill the requested length, stereo and the default preset,
  same-seed determinism byte-for-byte, argument guards), both run by
  `run_native_tests.sh` in the plain, ASAN and telemetry-off configurations.
- `src/test/bench/bench_pitch_time.{c,sh}`: the harness (scenarios below),
  `--smoke` in the `native-tests` CI job, `--assert --proxy` in the new
  `native-bench-arm64` job on `ubuntu-24.04-arm`, which uploads the binary and
  its report as the artifact `bench-pitch-time-arm64`.
- `tool/test/run_macos_rnnoise_wiring_tests.sh` also checks the stretch
  forwarders and that the shim compiles with no search path.

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
| `head` | the `engine_read_head.h` kernel over 8 and 64 lanes in a loop shaped like the mixer's lane loop, at the identity head (control) and at ½×, 2×, 4×, 8× and the tempo ratios 0.75 and 4/3; ≥ 2× uses the box decimation | the same, plus the worst ADDED cost (rate minus identity) |
| `render` | `le_stretch_render_offline` on one 30 s mono lane, both presets, ±12 st at ratio 1 and stretches at 0.75 and 4/3; idle, then under load (a second engine paced at the period on a thread that asks for SCHED_FIFO 80 while the renderer runs at nice +10) | × real time |
| `inline` | streaming `le_stretch_process` at 64 output frames per call for 1 / 8 / 64 streams, hop-aligned and hop-staggered, plus one `seek` re-prime | per-period stats (informational) |
| `memory` | current-RSS growth per stretcher instance, bytes per rendered entry, peak RSS | KiB / MiB |

The harness prints the CPU model (`/proc/cpuinfo` "CPU part"; 0xd0b is the
Pi 5's Cortex-A76) and the scheduling it obtained. `--assert` carries the Pi 5
thresholds and is refused on anything but a Cortex-A76 unless `--proxy`, which
asserts the arm64 CI proxy set (p50 and throughput only, at half the Pi
figures). Thresholds are the plan's Part 1 table.

## Dev machine (informational)

Apple M4 Pro (macOS, Apple clang 21), `bench_pitch_time.sh` with the defaults: 96 kHz, 64-frame period (667 µs budget), 60 s per scenario, 30 s loops, no real-time scheduling available, no assertions (this machine is neither the Pi nor the proxy).

- CPU: Apple M4 Pro
- scheduling: no real-time scheduling on this platform
- rate 96000 Hz, period 64 frames, budget 666.7 us, 60 s per scenario, 30 s loops

## baseline (le_engine_process, 8 tracks PLAYING)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 8 tracks x 1 lane                  |     23.7 |     31.6 |    107.5 |     24.6 |    3.6% |    4.7% |
| 8 tracks x 8 lanes                 |     51.5 |     65.4 |    208.5 |     51.7 |    7.7% |    9.8% |

## head (engine_read_head.h kernel; 'added' = minus the identity loop)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 8 lanes identity (control)         |      1.0 |      1.3 |     39.9 |      1.1 |    0.2% |    0.2% |
| 8 lanes 1/2x                       |      1.1 |      1.5 |     21.2 |      1.2 |    0.2% |    0.2% |
| 8 lanes 2x                         |      1.3 |      1.7 |     19.0 |      1.3 |    0.2% |    0.3% |
| 8 lanes 4x                         |      1.7 |      2.2 |     22.7 |      1.7 |    0.3% |    0.3% |
| 8 lanes 8x                         |      2.6 |      3.3 |     43.4 |      2.6 |    0.4% |    0.5% |
| 8 lanes ratio 0.75                 |      1.1 |      1.4 |     22.2 |      1.1 |    0.2% |    0.2% |
| 8 lanes ratio 4/3                  |      1.1 |      1.4 |     33.6 |      1.1 |    0.2% |    0.2% |
| 8 lanes worst ADDED                |      1.6 |      2.0 |          |          |    0.2% |    0.3% |
| 64 lanes identity (control)        |      6.8 |     11.2 |     39.8 |      7.1 |    1.0% |    1.7% |
| 64 lanes 1/2x                      |      7.0 |      9.7 |     41.0 |      7.1 |    1.0% |    1.5% |
| 64 lanes 2x                        |      8.4 |     11.4 |     43.9 |      8.5 |    1.3% |    1.7% |
| 64 lanes 4x                        |     11.6 |     17.1 |     95.4 |     12.1 |    1.7% |    2.6% |
| 64 lanes 8x                        |     19.0 |     23.9 |     89.2 |     19.5 |    2.9% |    3.6% |
| 64 lanes ratio 0.75                |      7.4 |     11.1 |     50.5 |      7.6 |    1.1% |    1.7% |
| 64 lanes ratio 4/3                 |      7.8 |     11.1 |  40839.4 |      8.4 |    1.2% |    1.7% |
| 64 lanes worst ADDED               |     12.2 |     12.7 |          |          |    1.8% |    1.9% |

## render (le_stretch_render_offline, 30 s mono, x real time)

| configuration              |   idle |   loaded |
|----------------------------|--------|----------|
| cheaper +12 st ratio 1     |  154.0x |   150.5x |
| cheaper -12 st ratio 1     |  165.0x |   158.2x |
| cheaper stretch 0.75       |  205.9x |   218.5x |
| cheaper stretch 4/3        |  119.8x |   121.2x |
| default +12 st ratio 1     |  120.0x |   125.3x |
| default stretch 0.75       |  170.7x |   177.4x |

load thread: no real-time scheduling on this platform; renderer nice +10 applied

## inline (streaming le_stretch_process, 64 frames per call; informational)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 1 streams aligned                  |      0.2 |    252.9 |    330.8 |      4.4 |    0.0% |   37.9% |
| 1 streams staggered                |      0.2 |    253.0 |    328.3 |      4.4 |    0.0% |   38.0% |
| 8 streams aligned                  |      1.7 |   1998.1 |   2415.0 |     34.7 |    0.3% |  299.7% |
| 8 streams staggered                |      1.7 |    266.4 |   1811.8 |     34.2 |    0.3% |   40.0% |
| 64 streams aligned                 |     13.5 |  15452.8 |  66352.1 |    278.3 |    2.0% | 2317.9% |
| 64 streams staggered               |    258.2 |    538.7 |  43480.3 |    279.3 |   38.7% |   80.8% |

seek re-prime (block + interval frames): 13.6 us (2.0% of the period)

## memory

- stretcher live heap per instance: cheaper 1141 KiB, default 1141 KiB (re-measured with malloc accounting after the full run; at 96 kHz both presets round to the same FFT size)
- rendered entry: 2880000 frames x 4 = 11.0 MiB per mono lane
- peak RSS: 802 MiB


## arm64 proxy (CI, `native-bench-arm64`)

Filled from the first green run of the job on the PR head; the report is the
job's `bench-pitch-time-arm64.md` artifact. Until then: pending.

## Pi 5 (hardware; gates Part 3a)

Pending the owner's run of the `bench-pitch-time-arm64` artifact on the
appliance (`bench_pitch_time --budget-us 667 --assert`). When both this and
the proxy table exist, the proxy/Pi ratio is recorded here and becomes the
scaling note for later runs.

## Reading the dev-machine numbers

- `baseline`: today's engine spends 3.6 % of the period at p50 (4.7 % p99) with
  eight single-lane tracks playing, 7.7 % (9.8 %) with sixty-four lanes. The
  max columns (108 and 209 µs) are scheduler preemption on a non-RT thread,
  as the D0 spike also saw; judge against p99.
- `head`: the fractional read costs almost nothing where it matters. The worst
  ADDED cost over the identity loop is 2.0 µs at p99 for 8 lanes (0.3 % of the
  period) and 12.7 µs for 64 lanes (1.9 %), at 8× with the box decimation, which
  is the most expensive factor (eight reads per lane per frame). ½× and the two
  tempo ratios add under 1 µs at 8 lanes. The Pi thresholds (10 % / 35 %) leave
  a factor of 30 and 18 for a Cortex-A76 that is several times slower; the
  proxy thresholds (5 % / 17 % at p50) a factor of 20 and 9. The one 40.8 ms max
  in "64 lanes ratio 4/3" is a single preemption event, not the kernel.
- `render`: `presetCheaper` renders a 30 s mono lap at 120–218× real time
  (0.14–0.25 s), `presetDefault` at 120–177×; the +12 st shift and the 4/3
  stretch are the slowest recipes. Running at nice +10 beside a second engine
  paced at the period changed nothing measurable here, because this machine
  has cores to spare; the Pi's four cores are why the loaded figure is the one
  the thresholds read. Against the Pi threshold of 20× this leaves a factor
  of 6 for the A76's slowdown; against the proxy's 40× a factor of 3.
- `inline` (informational, the D2 decision's evidence): streaming the
  stretcher at 64 output frames per call puts one STFT hop every 30 periods,
  and that hop costs 253 µs on this machine: p99 for a SINGLE stream is 38 % of
  the 667 µs period, 8 hop-aligned streams are 2.0 ms (300 %), 8 staggered
  streams 266 µs (40 %), 64 staggered 539 µs (81 %). The July spike's "GO
  inline" was measured at 10 ms blocks, where the same hop is 2.5 % of the
  block; at the appliance's period it is a burst the audio thread cannot carry
  even on an M4 Pro, before the Pi's slowdown. A `seek` re-prime of block +
  interval frames costs 13.6 µs here (2 % of the period), cheap in itself; the
  rest of the inline cost is the hop, which a worker pays off-thread.
- `memory`: a stretcher instance is 1.1 MiB of live heap at 96 kHz (both
  presets reach the same FFT size there), a rendered 30 s mono entry is 11 MiB,
  and the harness peaked at 802 MiB resident with its 64 full-length lane
  buffers plus the 8 × 8-lane rig; the engine's own pools are the bulk of that.

Dev-machine verdict: nothing here is a gate, but every Pi and proxy threshold
holds with a wide margin on this machine, the head kernel is within noise of
the integer path, and the inline figures document why pitch-preserving work is
pre-rendered.
