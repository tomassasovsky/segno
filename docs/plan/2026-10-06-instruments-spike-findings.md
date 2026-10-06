# Instruments, Part 1: the measured synthesis spike

<!-- cspell:ignore Neoverse SCHED polyBLEP xorshift glibc GTXF clav expf libdl libpthread powf tanf -->

Tracking: #1197, Part 1 of the instruments plan
(`docs/plan/2026-10-06-feat-instruments-plan.md`, PR #1204). Status: the voice
pool, the patch table, the catalogue reads and the bench are built; the
dev-machine run is recorded below as information; the arm64 proxy run is the
CI job `native-bench-arm64` on the PR head; the Pi 5 table is appended when
the owner has run the uploaded binary on the appliance (the steps are under
"Pi 5"). The Pi verdicts gate Part 6's merge, not this part.

## What was built

- `packages/segno_engine/src/core/synth_voice.{h,c}`: the instrument voice
  pool. Pure C (no engine types, no atomics), allocation-, lock- and
  syscall-free after `le_synth_init`. Up to 8 instruments, a pool of 1 to 64
  voices (default 32) plus 8 fade slots, mono output per instrument.
  - Melodic voices: the patch wave plus a second partial at the patch ratio
    (organs add 4x, bells 5.4x), a TPT state-variable low-pass, a linear
    attack and an exponential fall to the patch's sustain level, a 5 Hz LFO
    (5.8 Hz on organs) for vibrato and tremolo; polyBLEP saw and square,
    table sine, naive triangle; partials at or above 0.45 of the sample rate
    fall silent.
  - Drums: GM 35/36 kick (135 to 47 Hz, electronic 180 to 38 Hz), 38/40
    snare, 39 clap, 42/44 hat; xorshift noise seeded per voice from the
    synth seed; any other note plays nothing; note-off is ignored.
  - Release is an exponential with a time constant of release / 5 aimed just
    below zero, so it reaches exactly zero at the release time and the voice
    ends there.
  - Stealing: the oldest released voice of the same instrument, then of any,
    then the oldest held of the same instrument, then of any; the victim fades
    over 3 ms in a fade slot and the new note starts in the same block. A
    repeated strike from one origin and a patch change fade the same way.
  - Control-rate values update every 32 frames on a grid counted from init,
    not per call, so the same events at the same frames give the same samples
    at any block size.
- `packages/segno_engine/src/core/synth_patch.c`: the 19 patches and the 21
  family parameters in catalogue order, and the three public reads in
  `segno_engine_api.h`: `le_synth_patch_count`, `le_synth_patch_info`
  (`le_synth_patch_desc`: id, family, defaults) and `le_synth_param_info`
  (`le_synth_param_desc`: key, unit, value at 0 and 100, linear or
  exponential), with the `le_synth_family` and `le_synth_param_unit` enums.
  Bindings regenerated.
- Wiring: `src/CMakeLists.txt`, `src/test/run_native_tests.sh`,
  `tool/build_test_lib.sh`, the SPM and CocoaPods forwarders
  (`macos/segno_engine/Sources/segno_engine/synth_*.c`,
  `macos/Classes/synth_*.c`), and a new block in
  `tool/test/run_macos_rnnoise_wiring_tests.sh` that fails if any of them
  stops listing or forwarding either TU.
- Tests: `src/test/test_engine_synth.h`, run first by `test_engine_core.c`
  (`SEGNO_SYNTH_TESTS_ONLY=1` runs only these). See "Oracles" below.
- Bench: `src/test/bench/bench_instruments.{c,sh}`. The helpers it shares
  with the pitch/time bench (options, timing and percentiles, CPU detection,
  the SCHED_FIFO window, the 8-track rig and its baseline, report rows,
  verdicts) moved verbatim from `bench_pitch_time.c` into
  `src/test/bench/bench_common.h`; the pitch/time smoke run is unchanged.
- CI: `native-tests` smoke-runs the new bench; `native-bench-arm64` runs it
  with `--budget-us 667 --assert --proxy --seconds 20` under `shell: bash`
  (pipefail, so a failed threshold or build fails the job) and uploads the
  binary and its report as the artifact `bench-instruments-arm64`.

## Departures from the plan text

- **Drum level.** The prototype's drum gain puts one electronic snare at 1.15
  of full scale. The voice scales every drum hit by 0.85
  (`LE_SYNTH_DRUM_HEADROOM`), so the loudest single hit peaks at 0.98 and the
  pieces keep their balance. Different sound is permitted
  (`implementation-map.md`); clipping a single hit is not acceptable.
- **The kick oracle.** The plan said "135 ± 10 Hz in the first 10 ms and
  47 ± 5 Hz in 100-150 ms"; with the default decay the sweep lasts 0.361 s,
  so at 125 ms the kick is still near 94 Hz. The test instead checks that the
  second period's frequency equals the sweep law at its midpoint within 2 Hz
  (about 130.5 Hz at 11.5 ms) and that 0.40-0.70 s measures 47 ± 2 Hz. The
  plan's text was corrected on the plan branch.
- **libm in control code.** The plan said no libm call in render. Render calls
  `tanf`, `powf` and `exp2f` once per voice per 32-frame control block and
  `powf`/`expf` once per note event, never per sample; these are pure
  functions with no allocation or locking, and the existing per-sample
  `fx_filter` already calls `powf` and `tanf` (`engine_fx.c:57-60`).
- **The SVF is not shared with `fx_filter`.** Both use the same TPT
  state-variable form, but `fx_filter` keeps its state in the FX slot arrays
  and computes coefficients per sample; sharing it would change that path's
  numerics for no gain in this part.
- **Bench scenarios.** Pool scenarios report the higher of the costliest
  patch and an eight-instrument mixed set, and the bench also prints the
  engine baseline with 32 voices in the same period (informational; it is
  Part 2a's threshold once the voices run inside the callback).

## Oracles (all in the plain, ASAN and telemetry-off native runs)

| Test | Literal oracle |
|---|---|
| `test_synth_patch_table` | 19 patches, ids, families and all 57 defaults exactly the catalogue's; the 21 parameter keys; decay 0.08..2.48 s linear, cutoff 180..12600 Hz exponential (50 → 1505.99 Hz), attack 0.008..0.908 s, punch 0..100; Electric keys decay 60 reads 1.52 s (the pen's `gGTXF`); invalid indexes refused |
| `test_synth_arg_guards` | pool 0 and 65 refused; notes on an empty instrument, note 128, velocity 0 and 128 refused; parameters clamp to 100 |
| `test_synth_pitch_and_exact_release` | `sub` note 69: 880 ± 2 sign changes in 1 s, note 81: 1760 ± 2; release 30 (0.80 s = 38400 frames): sounding at T − 10 ms, ended 8 frames after T, then 4800 samples exactly 0 |
| `test_synth_velocity_scales` | velocity 64 peak / velocity 127 peak = 64/127 within 1 % |
| `test_synth_drum_kick_and_note_off` | kick second period within 2 Hz of 135·(47/135)^(t/0.361); 47 ± 2 Hz over 0.40-0.70 s; the hit ends by itself (silent from 0.74 s); a note-off leaves the samples byte-identical; note 60 plays nothing |
| `test_synth_steal_prefers_same_instrument` | B's note oldest, A fills a 32 pool: A's next note takes A's oldest, B survives and B's bus is byte-identical to B alone; released before held; another instrument's released voice before this one's held |
| `test_synth_steal_fades_to_exact_zero` | pool of one: from 145 frames (3 ms) after the steal the bus is byte-identical to the new note alone; a repeated strike and a patch change fade; same patch keeps the voice; new defaults load |
| `test_synth_cutoff_parameter` | `lead` note 96: RMS at cutoff 0 under 10 % of RMS at cutoff 100 |
| `test_synth_deterministic_and_bounded` | two synths with seed 7: every patch and every drum piece byte-identical, finite, at most 1.0, and audible; seed 8 gives a different snare |
| `test_synth_top_note_bounded` | note 127 on every melodic patch with the filter open: finite, at most 1.0, audible, phases in [0, 1) |
| `test_synth_block_size_independent` | a scripted sequence (four instruments, LFO patches, events at frames 0, 3000, 7001, 9000, 15000) renders byte-identically at 1, 64, 127 and 512 frames per call |

### Mutation proof

Each behaviour's test fails with the behaviour removed (a driver compiling
`test_engine_synth.h` alone against a mutated copy of the TU; every mutation
was run and the sources left untouched):

| Mutation | Result |
|---|---|
| same-instrument held voice not preferred | killed (5 checks) |
| released voices not preferred | killed (4) |
| another instrument's released voice not preferred over own held | killed (2) |
| release aims at zero instead of below it (never ends) | killed (4801) |
| fade never ends | killed (3) |
| control grid reset on every render call | killed (6) |
| drums honour note-off | killed (1) |
| repeated strike does not replace | killed (3) |
| patch change does not fade | killed (2) |
| cutoff parameter ignored | killed (1) |
| velocity ignored | killed (1) |
| kick sweep removed | killed (2) |
| undefined drum notes play a snare | killed (4802) |
| seed not used by the noise | killed (1) |
| a patch default changed (piano 68 → 67) | killed (2) |
| drum headroom removed | killed (1) |
| attack mapping changed to the decay mapping | killed (1) |
| cutoff mapping made linear | killed (2) |
| note frequencies off by a semitone | killed (2) |
| partials above Nyquist not silenced | killed (1) |

## Method

`bench_instruments.sh [--smoke] [--seconds N] [--patch-seconds N]
[--loop-seconds N] [--rate HZ] [--period FRAMES] [--budget-us N] [--assert]
[--proxy]` builds the harness against the real engine sources and the voice
TUs (pure C, no C++ runtime) and runs at `--rate` / `--period` (defaults
96 kHz, 64 frames, so the budget is the appliance's 667 µs period):

| scenario | what is timed | over |
|---|---|---|
| `patches` | one `le_synth_render` of a period with 8 voices of each patch (drum voices re-struck every period to keep 8 sounding) | `--patch-seconds` (5) each |
| `voices` | the costliest patch, then a mixed set (piano, organ, lead, synth-bass, strings, drums, vibes, pad), at 8, 16, 32 and 64 voices of a 64-voice pool | `--seconds` (60) each |
| `burst` | 32 note-ons on an idle 32-voice pool plus the block they land in | `--seconds` × rate / period / 8 repetitions (200 to 20000) |
| `engine` | `le_engine_process` with 8 tracks × 8 lanes PLAYING, then the same with 32 voices rendered in the period (informational) | `--seconds` each |

Thresholds (`--assert`), on the higher of the costliest-patch and mixed-set
figures:

| criterion | Pi 5 (p99) | arm64 proxy (p50) |
|---|---|---|
| 32 voices | ≤ 15 % of the period | ≤ 7.5 % |
| 64 voices | ≤ 30 % | ≤ 15 % |
| 32-note burst | ≤ 20 % | ≤ 10 % |

`--assert` without `--proxy` is refused on anything but a Cortex-A76.

## Dev machine (information only)

Apple M4 Pro, macOS, 2026-10-06, `bench_instruments --budget-us 667
--assert --proxy --seconds 20` (no real-time scheduling on this platform, so
the p99 and max columns carry desktop scheduling noise; an M4 Pro core is
several times a Cortex-A76's, so none of this stands in for the appliance).
The per-voice cost is about 0.4 µs per 64-frame period (0.06 % of the
budget), nearly the same for every patch because the per-sample oscillator,
filter and envelope loop dominates; bells is the costliest by a hair (its
third partial).

- CPU: Apple M4 Pro
- timed loops: SCHED_OTHER, nice 0 (no real-time scheduling on this platform), held only for the loop
- rate 96000 Hz, period 64 frames, budget 667.0 us, 20 s per pool scenario, 5.00 s per patch
- le_synth state: 25576 bytes; default pool 32 voices, 8 fade slots

### patches (8 voices each, one le_synth_render per period)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| piano                              |      3.0 |      3.2 |     12.4 |      3.0 |    0.4% |    0.5% |
| keys                               |      3.0 |      3.2 |     21.2 |      3.0 |    0.5% |    0.5% |
| clav                               |      3.3 |      5.6 |     30.5 |      3.3 |    0.5% |    0.8% |
| organ                              |      3.5 |      3.6 |      6.6 |      3.4 |    0.5% |    0.5% |
| reed                               |      3.5 |      3.6 |     12.5 |      3.5 |    0.5% |    0.5% |
| lead                               |      3.2 |      3.4 |      6.8 |      3.2 |    0.5% |    0.5% |
| pad                                |      3.3 |      3.5 |      5.8 |      3.3 |    0.5% |    0.5% |
| pluck                              |      3.5 |      3.7 |     31.6 |      3.5 |    0.5% |    0.6% |
| bass                               |      3.1 |      3.3 |     15.3 |      3.1 |    0.5% |    0.5% |
| synth-bass                         |      3.2 |      3.3 |     18.0 |      3.1 |    0.5% |    0.5% |
| sub                                |      3.1 |      3.2 |      6.5 |      3.1 |    0.5% |    0.5% |
| strings                            |      3.2 |      3.3 |      5.9 |      3.1 |    0.5% |    0.5% |
| violin                             |      3.2 |      3.4 |      5.4 |      3.2 |    0.5% |    0.5% |
| cello                              |      3.0 |      3.1 |      5.0 |      3.0 |    0.4% |    0.5% |
| drums                              |      3.1 |      5.5 |     30.4 |      3.1 |    0.5% |    0.8% |
| electronic-drums                   |      3.0 |      3.3 |     17.4 |      3.0 |    0.4% |    0.5% |
| marimba                            |      3.2 |      5.7 |     24.6 |      3.1 |    0.5% |    0.9% |
| vibes                              |      3.2 |      3.4 |     12.5 |      3.2 |    0.5% |    0.5% |
| bells                              |      3.5 |      3.8 |      6.8 |      3.6 |    0.5% |    0.6% |

costliest patch: bells

### voices (64-voice pool)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| bells x 8                          |      3.3 |      3.9 |     20.2 |      3.3 |    0.5% |    0.6% |
| bells x 16                         |      6.5 |      7.6 |     56.9 |      6.4 |    1.0% |    1.1% |
| bells x 32                         |     13.7 |     25.2 |    120.1 |     13.8 |    2.0% |    3.8% |
| bells x 64                         |     26.3 |     51.7 |    341.2 |     27.0 |    3.9% |    7.8% |
| mixed set x 8                      |      3.3 |      3.7 |     39.3 |      3.4 |    0.5% |    0.5% |
| mixed set x 16                     |      6.5 |      7.3 |     95.0 |      6.6 |    1.0% |    1.1% |
| mixed set x 32                     |     13.7 |     23.9 |    391.4 |     14.0 |    2.0% |    3.6% |
| mixed set x 64                     |     25.5 |     29.7 |   6477.1 |     25.9 |    3.8% |    4.5% |

### burst (32 note-ons + the block they land in)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 32-note burst                      |     15.2 |     16.0 |     26.9 |     15.4 |    2.3% |    2.4% |

### engine (le_engine_process, 8 tracks x 8 lanes PLAYING; informational)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 8 x 8 lanes                        |     61.6 |    100.0 |  27603.7 |     65.8 |    9.2% |   15.0% |
| 8 x 8 lanes + 32 voices            |     76.3 |     86.5 |    888.8 |     77.0 |   11.4% |   13.0% |

- peak RSS: 731 MiB

### verdict (arm64 proxy thresholds)

- PASS: 32 voices p50 <= 7.5% of period (2.05 vs 7.50)
- PASS: 64 voices p50 <= 15% of period (3.95 vs 15.00)
- PASS: 32-note burst p50 <= 10% of period (2.29 vs 10.00)

ALL THRESHOLDS MET

## arm64 proxy (CI, `native-bench-arm64`)

The job runs `bench_instruments.sh --budget-us 667 --assert --proxy --seconds
20` on `ubuntu-24.04-arm` and fails on any proxy threshold. Its report is the
artifact `bench-instruments-arm64` (`bench-instruments-arm64.md`) of the PR
head's run.

## Pi 5 (hardware; gates Part 6)

Not yet run. What the owner runs, exactly:

1. Download the binary from the PR head's CI run:
   `gh run download <run-id> -R tomassasovsky/segno -n bench-instruments-arm64`
   (it contains `packages/segno_engine/build/bench/bench_instruments` and the
   proxy report). It is built on Ubuntu 24.04 (glibc 2.39) and needs only
   libc, libm, libpthread and libdl, which the Yocto image's newer glibc
   provides.
2. Copy it to the appliance: `scp bench_instruments root@<appliance>:/data/`.
3. On the appliance, with the app running normally (`segno.service` active,
   both displays attached, no recording in progress), as root so SCHED_FIFO
   is granted:
   ```sh
   chmod +x /data/bench_instruments
   /data/bench_instruments --budget-us 667 --assert | tee /data/bench-instruments-pi5.md
   ```
   It takes about 12 minutes and allocates about 730 MiB (731 MiB peak on the dev machine) for the engine
   scenario's 8 × 8 lanes of 30 s content. Check that the report's "timed
   loops" line reads `SCHED_FIFO 70`; if it shows `SCHED_FIFO refused`, it
   was not run as root and the p99 figures do not count.
4. Copy `/data/bench-instruments-pi5.md` back and paste its tables and
   verdict here, with the date and the build version
   (`cat /etc/segno/build-version`). Exit status 0 means every Pi threshold
   held. The line "voice pool: N" is the pool size the plan's D2 takes
   (64 when the 64-voice threshold passed, else 32).
5. If a threshold fails, the plan returns to the owner before Part 6 with the
   measured fallbacks (cheaper oscillators, or synthesis at 48 kHz through
   the existing half-band resampler).

When both the proxy and the Pi tables exist, record the proxy/Pi ratio here
for later runs.
