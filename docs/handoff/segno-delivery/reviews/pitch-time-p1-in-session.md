Model: Claude Opus (subagent), in-session

# Review: PR #1183, pitch/time core Part 1 (the measured CPU spike)

- Branch `claude/pitch-time-1179-p1`, head `ba9fc9954`; base `claude/segno-integration` (`c3714abc2`).
- Read: the full diff; the PR body; Part 1 and sections 2.1 to 2.3 of `docs/plan/2026-10-06-feat-pitch-time-core-plan.md`; `docs/plan/2026-10-06-pitch-time-spike-findings.md`; the Reverse plan's `le_direction_index` definition (for parity); the Yocto `segno-bundle.bb` and `deploy/rpi/build` Dockerfiles; the deleted D0 harness.

## What I ran

| Run | Result |
| --- | --- |
| `run_native_tests.sh`, plain (own `mkdir`'d TMPDIR, macOS, Apple clang) | ALL PASSED, all 5 binaries; the 7 new tests ran |
| `EXTRA_CFLAGS="-fsanitize=address -g" run_native_tests.sh` (own TMPDIR) | ALL PASSED. macOS ASAN has no LeakSanitizer; see finding 12 for Linux |
| `bench_pitch_time.sh --smoke` | exit 0; every scenario ran |
| PROGRESS C++17 shim repro (`clang++ -std=c++17 -U__clang__`, `extern "C"` wrapper, `std::min` in scope) with `engine_fx.h`, `engine_read_head.h` and `le_stretch.h` | Compiles. The only warning is pre-existing (`engine_private.h:823`, missing-field-initializers) |
| Probe: the bench's baseline rig | All 8 tracks are in state 3 (PLAYING) with non-zero output at 1 and 8 lanes, so `baseline` measures a playing engine |
| Probe: `le_stretch_create(INT32_MAX, ...)` | Aborts with `libc++abi: terminating due to uncaught exception of type std::length_error`, exit 134 (finding 2) |
| Mutation: `discard = 0` in `le_stretch_render_offline` | All 3 stretch tests still pass; a click at input 24000 moves to output 28800 (finding 6) |
| Probe: integer read path compared with the identity-head control | M4 Pro, 8 lanes: 0.2 µs vs 1.0 µs p50. 64 lanes: 4.7 µs vs 6.6 µs (finding 7) |
| `build_test_lib.sh` | Builds and links the shim. `check_ffi_symbols.sh` is ELF-only (exit 1 on a Mach-O dylib, also on base); `build-linux` and `build-linux-arm64` pass it in CI |
| `gh pr checks 1183` | All green except `native-tests-asan`, which fails on a pre-existing base leak (finding 12) |

## Verified correct

- **Read-head math, E1.**
  - `le_head_index` matches the plan: `(origin ± rate·pos) mod len` over an unbounded int64 `pos`.
  - At rate 1, forward and reversed equal the Reverse plan's `le_direction_index`: `(pos + origin) mod len` and `(origin − pos) mod len`.
  - `le_head_wrap` is exact for any `|x| < 2^53`. `q·l` is an exact integer, and `x − q·l` is exact by Sterbenz because `x` and `q·l` are within a factor of two. The two corrections keep the result in `[0, len)`, including `−tiny + l` rounding up to `l`.
  - The index precision limit is therefore the `rate·pos` product alone. At `rate·pos < 2^37` its ulp is 2^-15 frames, which matches the plan's precision note.
  - The identity head is bit-exact: rate 1 and an integral origin give a zero fraction, so `le_head_sample` returns `buf[i]`.
  - Equal-power `le_head_turn_mix` is the 7th-order Taylor sine; its error at π/2 is 1.6e-4, inside the claimed 2e-4. The old weight `turn_mix(F − i)` is cos, so the pair is power-complementary.
  - The Q32.32 round trip is exact for indices of 2^21 frames and above, and within 2^-32 frames below that. `index · 2^32 < 2^63` for any `len ≤ 2^31`.
- **Pure-header constraints.** The header includes only `<stdint.h>`. It has no libm, no `_Atomic` and no designated initializers, and it compiles under the C++17 shim repro.
- **`le_stretch_render_offline` alignment and bounds.** I checked the latency arithmetic against the library README ("Seeking and starting"):
  - After a seek of W frames, the processing time sits `in_lat` frames before `in[0]`, so `discard = out_lat + in_lat·ratio` is right. A click at input frame 24000 comes out at 24000 (ratio 1) and at 18055 (ratio 0.75).
  - Feeding `n_out/ratio` input frames per chunk, with carry, keeps the time ratio.
  - The cyclic pre-roll and run-out wrap correctly even when the lap is shorter than W.
  - All `pad` and `acc` accesses stay in bounds: `in_pos` is clamped to `in_end`, and the flush ends at exactly `total_out` inside a `total_out + 1024` buffer.
- **Build wiring.**
  - CMake `LANGUAGES C CXX` with C++17 on the target, which also keeps the VST3 block working.
  - The SPM forwarder (`../../../../src/stretch/le_stretch.cpp`) and the CocoaPods forwarder (`../../src/...`) both resolve. SPM (`cxxLanguageStandard: .cxx17`) and the podspec (`CLANG_CXX_LANGUAGE_STANDARD c++17`) were already C++17.
  - `run_native_tests.sh` and `build_test_lib.sh` compile the shim with `$CXX` and link `-lstdc++` (Linux and Windows) or `-lc++` (macOS).
  - CI is green for `build-linux`, `build-linux-arm64`, `vst3-plugins-linux`, `native-tests`, `native-tests-tsan` and `native-tests-telemetry-off`.
- **C++ runtime on the appliance.**
  - libstdc++ is linked dynamically, through the CMake CXX linker driver.
  - The bundle is built in an `ubuntu:24.04` container (GCC 13). `segno-bundle.bb` already lists `libstdc++` in its RDEPENDS, and the GTK runner already loads it, so the appliance gains no new runtime dependency.
  - The artifact binary needs glibc 2.38 or later (`__isoc23_strtoul` under `_GNU_SOURCE`) and `mallinfo2`. Every Yocto release the layer supports (scarthgap, styhead, walnascar) ships glibc 2.39 or later.
- **License compatibility.** Signalsmith Stretch is MIT, which is compatible with GPLv3. The `third_party/README.md` vendoring note is accurate: tag 1.1.0, commit `44c8f865`, `web/` and `cmd/` stripped. The rename is a pure move (100% similarity).
- **CPU-part detection.** The harness parses `/proc/cpuinfo` `CPU part` with `strtoul(..., 16)`. The CI job reported part 0xd49 (Neoverse-N2). The Pi 5's 0xd0b is matched exactly, and plain `--assert` is refused anywhere else, as the plan requires.
- **Assert logic.** The `--proxy` assertions match the plan: p50 head-added ≤ 5 % at 8 lanes and ≤ 17 % at 64 lanes, and cheaper render under load ≥ 40×. "Worst added" takes the maximum over every factor and ratio, clamped at zero.
- **Artifact upload.** It produced `bench-pitch-time-arm64` (1.5 MB) containing the binary and the `.md` report, rooted at the repo (artifact 11392432219).

## Findings

### 1. High: the proxy gate cannot fail in CI

- **Where:** `.github/workflows/main.yaml`, `native-bench-arm64`, step "Build + run the pitch/time bench": `bench_pitch_time.sh ... --assert --proxy --seconds 20 | tee bench-pitch-time-arm64.md`.
- **Trigger:** any threshold failure (the harness exits 1) or any build failure (the script's own `set -euo pipefail` exits non-zero).
- **Impact:**
  - The step has no `shell:` and the workflow has no `defaults.run.shell`. The job log confirms `shell: /usr/bin/bash -e {0}`, which is `-e` without `pipefail`, so the pipeline's status is `tee`'s, which is always 0.
  - The plan calls this job "the gate Part 1 and Part 2 close on", and it is green regardless of the numbers.
  - A build failure is also hidden: `if-no-files-found: error` only fires when none of the paths match, and the `.md` will exist.
- **Fix:** add `shell: bash` to the step (GitHub then runs `bash --noprofile --norc -eo pipefail`), or prefix the command with `set -o pipefail;`. Prove the fix with a deliberately failing threshold once, for example `--budget-us 1`.

### 2. Medium: C++ exceptions escape the `extern "C"` boundary

- **Where:**
  - `src/stretch/le_stretch.cpp`, `le_stretch_create`. `new (std::nothrow)` covers only the struct; `presetCheaper`/`presetDefault` then call `configure()`, which resizes several `std::vector`s.
  - `le_stretch_render_offline`. `pad`, `acc`, `pad_ptr` and `acc_ptr` are constructed outside the `try`, and the nested `le_stretch_create` can throw too.
- **Trigger:** an allocation failure, or an absurd channel count. `le_stretch_create(INT32_MAX, 48000, 1, 1)` aborts the process with an uncaught `std::length_error` (reproduced, exit 134).
- **Impact:** `le_stretch.h` promises "NULL on bad arguments or allocation failure" and `LE_STRETCH_ERR_ALLOC`. Instead an exception unwinds into C frames and ends in `std::terminate`. In Part 3a this code runs on the cache worker, so an OOM render would kill the app instead of failing the entry.
- **Fix:**
  - Wrap each exported body in `try { ... } catch (...) { return NULL / LE_STRETCH_ERR_ALLOC; }` and mark the functions `noexcept`.
  - Bound `channels` (for example to `LE_MAX_LANES` × 2, or a documented maximum).
  - Add a guard test with an oversized channel count.

### 3. Medium: render scratch is two whole laps, and the plan's memory criterion is neither met nor measured

- **Where:**
  - `le_stretch_render_offline`: `pad[c].assign(in_frames + 2W)` and `acc[c].assign(total_out + 1024)` for every channel.
  - `bench_pitch_time.c`, memory section: "rendered entry: frames × 4" is arithmetic, not a measurement, and the only memory assertion is "stretcher heap ≤ 4 MiB".
- **Trigger:** any render. A 30 s mono lap at 96 kHz needs about 11.6 MB of `pad` plus 11.6 MB of `acc`, on top of the 11 MB output and the 1.1 MiB stretcher.
- **Impact:**
  - The plan's Part 1 memory threshold ("a kind-1 entry costs `out_len × 4` bytes plus under 1 MiB of worker scratch") is exceeded by about 20× per channel.
  - The harness cannot see this, so the stated memory gate passes on a number the plan never set.
  - On the Pi with the app running, an 8-lane stereo track rendered lane by lane holds about 46 MB of transient scratch per lane.
- **Fix:**
  - Stream from `in[]` with modular indexing for the W-frame pre-roll and run-out, so only W frames of scratch are needed.
  - Write output straight into `out[]` once `discard` frames are skipped, using a small discard sink.
  - In the harness, measure the peak heap delta across `le_stretch_render_offline` (`mallinfo2`/`malloc_zone_statistics` around the call, or a counting allocator) and assert it against `out_len × 4 + 1 MiB`.

### 4. Medium: on the Pi, the "renderer at nice +10" measurement runs at SCHED_FIFO 80

- **Where:** `bench_pitch_time.c`. `main()` calls `try_realtime()` once (about line 557), so the main thread stays SCHED_FIFO 80 for every scenario. `setpriority(PRIO_PROCESS, 0, 10)` (line 649) does nothing for a SCHED_FIFO thread, yet the report prints "renderer nice +10 applied" whenever the call returns 0.
- **Trigger:** running as root on the appliance, which is exactly the Pi-gate run.
- **Impact:**
  - The idle and loaded `render` figures measure an RT-priority renderer, not the nice +10 cache worker the 20× threshold is about.
  - The report misstates the scheduling it obtained.
  - The baseline and head loops run back to back, CPU-bound, at FIFO 80 for 60 s each. That is the same priority as the app's audio callback (`engine_linux.c:838`), and FIFO does not time-slice equal priorities. "With the app running" can therefore starve the app's callback whenever both land on one core, and it trips RT throttling.
- **Fix:**
  - Raise to FIFO only around the timed `baseline`/`head` loops.
  - Run the render on its own SCHED_OTHER thread at nice 10.
  - Report the policy read back with `sched_getscheduler`/`getpriority`.
  - Use a FIFO priority below the app's 80, or document stopping the transport during the run.

### 5. Medium: no MIT notice ships with the binary that now contains Signalsmith

- **Where:** plan Part 1 step 1 ("add the MIT notice where RNNoise's lives in the About license notices"). Nothing in `lib/` registers a native license: there is no `LicenseRegistry.addLicense` anywhere. `segno-bundle.bb` installs no notice either.
- **Trigger:** every shipped build, because `le_stretch.cpp` is now compiled into `libsegno_engine.so` and the macOS framework, not just the bench.
- **Impact:**
  - MIT requires the copyright and permission notice in every copy, including binary distributions. The appliance image and the app now carry Signalsmith without it.
  - The plan's premise is also wrong: RNNoise (BSD-3), VST3/CLAP (MIT) and miniaudio have no About notice either. That part is pre-existing.
  - The PR body states no Dart change and does not mention dropping this step.
- **Fix:** register the native vendored licenses (Signalsmith and its `dsp/` at least, ideally RNNoise, miniaudio, VST3 and CLAP) from bundled `LICENSE` assets with `LicenseRegistry.addLicense`. Or record the deferral explicitly on #1179 with its own issue.

### 6. Medium: the stretch tests would not catch a wrong latency compensation or seam

- **Where:** `src/test/test_engine_stretch.h`.
- **Trigger:** any regression in `discard`, the seek pre-roll or the cyclic run-out.
- **Impact:**
  - The sine tests check only pitch, level, finiteness and "signal in the last 2048 frames". The cyclic run-out supplies that last signal regardless of alignment.
  - With `discard = 0` (a 4800-frame, 100 ms shift) all three tests pass.
  - Alignment is what makes a rendered lap tile the clock, and the cyclic seam is what makes it loop. Both are the contract Part 3a relies on, and both are untested.
- **Fix:**
  - Add an onset test: a click at a known frame lands within ±2 ms of `frame·ratio` at ratios 1, 0.75 and 4/3, cyclic and non-cyclic.
  - Add a cyclic seam test: no step at `out[out_frames−1] → out[0]` larger than the signal's own maximum per-sample step.
  - Add the plan's 30 s input case (the success criterion says 30 s; the tests use 2 s).

### 7. Low: head "added" cost is measured against the wrong control

- **Where:** `scenario_head` with rate 1.0 is the control. It still calls `le_head_index` (a double division and an int64 conversion) and `le_head_sample` on every frame.
- **Trigger:** every run.
- **Impact:**
  - Part 2a keeps the integer path `lbuf[seg_base + trk_pos]` for identity heads, so the mixer's real added cost is head minus integer, not head minus identity-head.
  - On the M4 Pro the identity control costs 1.0 µs against 0.2 µs for the integer path at 8 lanes, and 6.6 µs against 4.7 µs at 64 lanes. The "worst ADDED" figure is therefore understated by about 1 to 2 µs here, and by more on the A76.
  - The thresholds still hold by a wide margin.
- **Fix:** use an integer-index loop shaped like the mixer as the control, and keep the identity head as an extra row.

### 8. Low: `le_head_sample_decimated` ignores the fraction and always boxes forward

- **Where:** `engine_read_head.h:82-96`.
- **Trigger:**
  - Non-integer rates of 2 or more, for example Speed 2× combined with a tempo factor of 1.05 (rate 2.1). The box starts at `floor(index)`, so position is quantised to whole samples, which is nearest-neighbour jitter.
  - Reversed heads: the box averages `i .. i+n−1`, the samples the head is moving away from, instead of `i−n+1 .. i`.
- **Impact:** extra distortion at non-integer high rates, and an (n−1)-sample skew for reversed fast heads. Neither case is tested; the bench's tempo ratios are below 2.
- **Fix:** interpolate `box(i)·(1−frac) + box(i+1)·frac` (one extra tap), box backward when reversed (or pass `reversed`), and add tests at 2.5× and reversed 4×.

### 9. Low: deleting the D0 harness removed the only no-allocation check

- **Where:** the deleted `src/test/bench/bench_stretch.cpp`, which counted global `new`/`delete` during `process()` and had `--wav` dumps for listening. Compare `le_stretch.h`'s header comment: "allocates in configure only; measured in the July spike and re-measured by the bench".
- **Trigger:** n/a; this is a claim with no check behind it.
- **Impact:**
  - The new harness does not re-measure allocations, so the real-time-safety claim for `le_stretch_process`/`_seek`/`_flush` is no longer backed.
  - The listening dumps that Part 2a's and 3a's listening checks will want are gone.
  - `docs/plan/2026-07-22-time-stretch-spike-findings.md` and `2026-08-25-feat-tempo-epic-remainder-plan.md` still point at the deleted paths.
- **Fix:** port the allocation counter (a small C++ TU in the bench overriding `operator new`) and assert zero allocations in the `inline` scenario. Restore a `--wav DIR` option. Add a "moved/superseded" note to the two older docs.

### 10. Low: harness and CI details

- **CPU label:** without a "model name" line the label reads `unknownNeoverse-N2 (part 0xd49)` (seen in the CI log). `have_name` gates only the separator, not the "unknown" prefix.
- **CI scenario length:** CI runs `--seconds 20`; the plan says at least 60 s per scenario.
- **Smoke settings:** `--smoke` runs 96 kHz/64 frames; the plan says 48 kHz/128.
- **Pi verdict and baseline:** the Pi verdict fails when `baseline` alone exceeds 50 %. The plan carves that case out as a separate pre-existing finding, so judge `baseline` separately.
- **Executable bit:** `upload-artifact@v4` does not keep file permissions, so the appliance step needs `chmod +x`. Add that to the findings doc and the workflow comment.
- **Wiring test:** `run_macos_rnnoise_wiring_tests.sh` has a dead `resolve_include` block (`if ...; then : ; fi`).
- **Wrap test:** the wrap test accepts `wraps == 4 || wraps == 3`. For the chosen rates the count is exactly 4 in both directions, and the slack would hide an off-by-one at the boundary.

### 11. Low (informational): the determinism contract holds only within one standard library

- **Where:** `SignalsmithStretch<float>` uses `std::default_random_engine` and `std::uniform_real_distribution`. Both are implementation-defined: libc++ uses `minstd_rand`, libstdc++ uses `minstd_rand0`.
- **Trigger:** comparing renders across macOS and the appliance. The RNG is used only above the clean-stretch limit.
- **Impact:** "same seed → identical output" is true on one platform, not across platforms. That matters if a later part compares hashes or goldens across hosts.
- **Fix:** document the contract as per-platform, or instantiate the template with a fully specified engine.

### 12. Info: CI is not green (pre-existing), and the Linux ASAN result for the new tests cannot be seen

- **Where:** `native-tests-asan`. LeakSanitizer reports 512 B leaked from `le_stage_retired_layer` (`engine_commands.c:650`) via `test_history_staging_refusal_fails_stem_keeps_undo`.
- **Evidence it is pre-existing:** the same failure is on base run 37408235667 (`c3714abc2`).
- **Impact:**
  - LSan exits without flushing the piped stdout, so the log stops before the new tests' lines and "ALL PASSED". Their Linux ASAN outcome cannot be seen; macOS ASAN passes.
  - The PR body's "ASAN passes" holds only on macOS.
  - Under the tracking contract the PR cannot reach `ready-to-merge` until this job is green.
- **Fix:** fix the leak on the trunk in its own issue/PR, or set `setvbuf(stdout, NULL, _IOLBF, 0)` in the test main so a sanitizer exit keeps the log. Then re-run.

### 13. Low (not verified on Linux): default symbol visibility for the C++ TU

- **Where:** `src/CMakeLists.txt` compiles the vendored RNNoise TUs with `-fvisibility=hidden` to stop dlopen'd plugins interposing its internals. `stretch/le_stretch.cpp` does not get the same treatment.
- **Impact:**
  - Any out-of-line Signalsmith or `std::vector` instantiations become default-visibility weak exports of `libsegno_engine.so` on Linux. Signalsmith is a common plugin dependency.
  - On macOS `nm -gU` shows no C++ symbols exported from the test dylib, so the risk is Linux-only and probably small.
- **Fix:** give `stretch/le_stretch.cpp` `-fvisibility=hidden -fvisibility-inlines-hidden`. Nothing outside the engine calls `le_stretch_*`.

## Proxy numbers (CI `native-bench-arm64`, run 37419702835, job 112126091880)

CPU: Neoverse-N2 (part 0xd49), labelled "unknownNeoverse-N2". Scheduling: SCHED_OTHER (SCHED_FIFO refused: EPERM). 96 kHz, 64 frames, budget 667 µs, 20 s per scenario, 30 s loops.

| Measurement | p50 µs | p99 µs | % of period (p50 / p99) |
| --- | --- | --- | --- |
| baseline, 8 tracks × 1 lane | 27.2 | 29.5 | 4.1 / 4.4 |
| baseline, 8 tracks × 8 lanes | 90.0 | 95.4 | 13.5 / 14.3 |
| head, 8 lanes, identity control | 3.0 | 3.1 | 0.5 / 0.5 |
| head, 8 lanes, 8× (worst) | 6.3 | 6.5 | 0.9 / 1.0 |
| head, 8 lanes, worst ADDED | 3.3 | 3.4 | 0.5 / 0.5 |
| head, 64 lanes, identity control | 7.8 | 8.7 | 1.2 / 1.3 |
| head, 64 lanes, 8× (worst) | 31.8 | 47.1 | 4.8 / 7.1 |
| head, 64 lanes, worst ADDED | 24.0 | 38.4 | 3.6 / 5.8 |
| inline, 1 stream | 0.3 | 455.8 | 0.0 / 68.3 |
| inline, 8 staggered | 2.4 | 474.7 | 0.4 / 71.2 |
| inline, 8 aligned | 2.3 | 3689.0 | 0.3 / 553 |
| inline, 64 staggered | 512.0 | 1008.6 | 76.8 / 151 |

| Render, 30 s mono | idle | loaded |
| --- | --- | --- |
| cheaper +12 st, ratio 1 | 83.7× | 83.6× |
| cheaper −12 st, ratio 1 | 84.5× | 84.4× |
| cheaper stretch 0.75 | 107.1× | 107.0× |
| cheaper stretch 4/3 | 60.7× | 60.7× |
| default +12 st, ratio 1 | 63.9× | 63.9× |
| default stretch 0.75 | 80.9× | 80.9× |

Other figures:

- Seek re-prime: 13.0 µs (2.0 %).
- Stretcher heap: 1105 KiB per instance (both presets).
- Peak RSS: 819 MiB.

Verdicts as printed:

- head added p50: 0.49 % at 8 lanes (limit 5 %) and 3.60 % at 64 lanes (limit 17 %).
- Cheaper render under load: 60.73× (limit 40×).
- Stretcher heap: 1.08 MiB (limit 4 MiB).
- Overall: "ALL THRESHOLDS MET".

Finding 1 means a FAIL would also have left the job green. The 40× render threshold has a margin of 1.5×. The head-added figures are slightly understated (finding 7), and the memory gate measures a different quantity from the plan's (finding 3). The inline numbers support the plan's D2 decision: a single stream's STFT hop is 456 µs at p99, 68 % of the period, even on the proxy.

## Verdict

**Request changes.**

- The read-head header is correct: exact where it claims to be, and parity-true to the Reverse plan.
- The shim's latency and seam arithmetic is right.
- The build wiring is sound across CMake, SPM, CocoaPods, the native runner and the Linux CI jobs.
- Before merge:
  - **Fix the CI gate:** the proxy gate cannot fail (1).
  - **Catch exceptions in the shim:** it can terminate the process across the C boundary (2).
  - **Measure render memory:** the plan's memory criterion is unmeasured, and the shim misses it by about 20× (3).
  - **Fix the Pi run's scheduling:** it measures the renderer at the wrong priority and can starve the app's callback (4).
  - **Ship the license notice:** the MIT notice the plan requires is not shipped (5).
  - **Add alignment and seam tests:** the stretch tests miss the properties Part 3a depends on (6).
- Each fix is small.
- `native-tests-asan` must also go green; that failure is a pre-existing trunk leak, not this PR's (12).
- Findings 7 to 11 and 13 can be follow-ups.

---

# Delta review (ba3ba6108)

Reviewed `git diff 50d9cb3d5..origin/claude/pitch-time-1179-p1`, which is the fix commit `ba3ba6108` on top of Part 1 rebased onto `cd9089c2d`. I worked in my own worktree, detached at `ba3ba6108`.

## What I ran

| Run | Result |
| --- | --- |
| `run_native_tests.sh`, plain (own `mkdir`'d TMPDIR) | ALL PASSED, all 5 binaries, including `test_stretch_offline_click_alignment` and `test_stretch_offline_cyclic_seam` |
| `EXTRA_CFLAGS="-fsanitize=address -g" run_native_tests.sh` (own TMPDIR, run after the plain run) | ALL PASSED, no ASAN reports |
| `leaks --atExit` on the plain `segno_core_tests.exe` | "0 leaks for 0 total leaked bytes" (the trunk's #1173 fix is in) |
| `bench_pitch_time.sh --smoke` | exit 0. Render scratch is 71 KiB (cheaper) and 79 KiB (default); the renderer reads back "SCHED_OTHER, nice 10" |
| `flutter test test/app` (after `flutter gen-l10n`, which a fresh worktree needs) | All 360 tests passed, including `vendored_licenses_test.dart` |
| `dart analyze --fatal-infos lib test packages/segno_engine packages/looper_repository` | No issues found |
| `flutter build bundle` | `build/flutter_assets/packages/segno_engine/...` contains all six licence files |
| `gh pr checks 1183` | Only GitGuardian ran. No `segno` workflow run exists for `ba3ba6108` (see D1) |

## Findings 1 to 6: fixed

1. **Fixed.** The bench step now has `shell: bash`, so it runs under `-eo pipefail`. This is correct by construction, but no CI run has exercised it yet (D1).
2. **Fixed.**
   - The exception probe, `le_stretch_create(INT32_MAX, ...)`, now returns NULL and the process continues; before, it aborted with exit 134.
   - Every exported function is `noexcept` and catches internally.
   - Channels, sample rate and ratio are bounded before any allocation, and the new guard tests cover INT32_MAX channels and sample rate and ratios of 1e-12 and 1e12.
3. **Fixed.**
   - The render streams from `in[]` and writes into `out[]`. Its scratch is W frames per channel plus one output step, measured at 71 to 79 KiB (formerly about 23 MB).
   - `bench_alloc.cpp` counts every `operator new` the shim and the library make, and the harness now asserts "render worker scratch under 1 MiB".
4. **Fixed.**
   - SCHED_FIFO is held only around the timed loops of baseline, head and inline, at priority 70, below the app's 80.
   - Renders run on their own SCHED_OTHER thread. On Linux the thread is reniced through `setpriority(PRIO_PROCESS, gettid, 10)`, which is per-thread, and the thread inherits SCHED_OTHER because `main` has called `rt_leave` by then.
   - The report reads policy and nice back from the thread itself.
   - On macOS nice is process-wide, which is why the renders run last; the run is informational there.
5. **Fixed.**
   - `registerVendoredLicenses()` registers clap, miniaudio, rnnoise, signalsmith-dsp, signalsmith-stretch and vst3sdk from package assets.
   - `flutter build bundle` and the test asset bundle both contain the files.
   - The console licences sheet (`readConsoleLicencePackages`) walks `LicenseRegistry.licenses`, so the entries appear.
   - It is called once, in `runSegno` right after `ensureInitialized` and before the window branch. That is early enough, because the registry is only walked when About opens. Each Flutter engine is its own isolate with its own registry, so the waveform window adds no duplicates.
6. **Fixed.**
   - My mutant with `discard = 0` now fails 25 checks; before, it passed every test.
   - A second mutant, with the cyclic run-out replaced by silence, fails the seam test at 0.75 and 4/3.
   - The alignment test uses the plan's 30 s input.

Lows also fixed:

- **7:** the control is now the integer read; the identity head is kept as its own row.
- **10:** the CPU label; the chmod note; the exact `wraps == 4`.
- **13:** `-fvisibility=hidden -fvisibility-inlines-hidden` on `le_stretch.cpp` for Linux. No CI run has built it on Linux yet (D1).

The `le_stretch.h` comment now says the bench does not repeat the allocation check (9).

## Regression hunt

- **Streaming render at chunk boundaries.** I compared the new render with the pre-fix materialising render (symbols renamed, both built with ASAN) across:
  - 8 lap lengths: 300, 511, 512, 513, 6719, 6720, 6721 and 48017 frames, which covers laps shorter than W = 6720 and every chunk edge;
  - 9 ratios: 1, 0.75, 4/3, 0.5, 2, 1/16, 16, 1/3 and 10;
  - cyclic and padded renders, mono and stereo;
  - at both the nominal `out_frames` and the largest `out_frames` the guard admits.

  Results:
  - The return codes agree everywhere, ASAN reports nothing, and no output frame is left unwritten (outputs were pre-filled with NaN).
  - Where both chunkings give whole-number per-call frame counts (ratios 1, 0.5, 2, 4/3, 1/16 and 16), the outputs match within 1e-3 relative RMS. That confirms the direct-write and scratch bookkeeping, `keep_output`, and the cyclic wrap for laps shorter than W.
  - Differences at 0.75, 1/3 and 10 have known causes. One implementation or the other rounds a per-call frame count (the old one rounded the input count, the new one rounds the output count). Above the library's clean-stretch limit, the RNG is also consumed in a different order.
  - The exact output length is preserved: the guard formula is unchanged and agrees with the old one at the boundary.
- **Ratio bound.**
  - [1/16, 16] covers the plan. Speed (½ to 8×) goes through the read head, not the stretcher.
  - The stretcher's ratio is the tempo ratio, and with BPM limited to 30–300 (`segno_engine_api.h:214`) it never exceeds 10.
  - Import Adapt falls in the same range.
  - 16 channels covers `LE_MAX_LANES` (8) stereo lanes, and the 384 kHz bound is above every supported sample rate.
- **Licence test.** It checks that each package is registered and that the text matches the file on disk exactly. It also pins miniaudio's licence to the vendored header and the VST3 subtrees to each other. It does not cover the `runSegno` call: removing that line would still pass. That is a Low gap (D3).
- **CI job.** `shell: bash` is the right fix. The artifact paths, `if-no-files-found` and the chmod note are correct.

## New findings

### D1. Blocking: no CI has run on `ba3ba6108`, so there are no new proxy numbers

- **Where:** PR #1183 shows `mergeable: CONFLICTING` / `mergeStateStatus: DIRTY`. The trunk moved to `51e6b45dc` after the rebase (Reverse #1162 and Peel #1164 landed), and GitHub does not run `pull_request` workflows without a merge ref.
- **Trigger:** `git merge-tree` reports one conflict, in the test list of `src/test/test_engine_core.c`:
  - the trunk adds `test_engine_reverse.h` and `test_engine_peel.h`;
  - this branch adds `test_engine_read_head.h` and `test_engine_stretch.h`.

  Keeping both resolves it. The two new headers do not collide with `engine_direction.h`.
- **Impact:**
  - The pipefail fix (1) has not run in CI.
  - The Linux-only visibility flags (13) have not been built by `build-linux` or `build-linux-arm64`.
  - The `native-bench-arm64` proxy numbers for the new harness do not exist.

  Under the tracking contract the PR is not mergeable.
- **Fix:** rebase onto `51e6b45dc` (or merge it), resolve by keeping all four includes and all test calls in `main`, push, and wait for green CI. Then record the new proxy table in the findings doc. That doc still says the proxy is "pending", although the pre-fix run 37419702835 already produced a table.

### D2. Low: an in-place render now gives a different result

- **Where:** `render_offline` reads `in[]` directly while writing `out[]`. The cyclic run-out reads the lap's head after `out[]` has overwritten it.
- **Trigger:** `out[c] == in[c]`.
- **Impact:** a 2 s +12 st cyclic render done in place differs from the out-of-place render by 3.5 % relative RMS. The pre-fix version copied the lap first, so in-place calls were safe. No caller does this yet.
- **Fix:** document that `in` and `out` must not overlap in `le_stretch.h`, or check for overlap and refuse it.

### D3. Low: one missing licence asset hides all licences, and the wiring is untested

- **Where:** `_vendoredLicenseEntries` has no per-entry error handling around `rootBundle.loadString`.
- **Trigger:** one missing asset, for example a partial checkout or a pubspec edit.
- **Impact:**
  - The stream errors, and the error propagates through `LicenseRegistry.licenses` to `readConsoleLicencePackages`. The About sheet then loses every licence, including all the Dart packages', not just the vendored ones.
  - No test covers the `runSegno` call.
- **Fix:** catch per entry (skip it and log it), and add a test that runs the app entry wiring, or `runSegno` with mocks, and finds `signalsmith-stretch` in the registry.

### D4. Low: Lows still open

- CI runs `--seconds 20` where the plan says at least 60 s.
- `--smoke` runs 96 kHz/64 frames where the plan says 48 kHz/128.
- The Pi verdict still fails when `baseline` alone exceeds 50 %, against the plan's carve-out.
- The dead `resolve_include` block is still in `run_macos_rnnoise_wiring_tests.sh`.
- 8 (`le_head_sample_decimated` fraction and reverse direction) and 11 (determinism per standard library) are untouched. They belong to Part 2a's listening check and to the determinism note.
- At FIFO 70 the timed loops still outrank the kernel's default IRQ threads (FIFO 50) on the appliance, up to RT throttling. This is fine if the audio IRQs are raised by `segno-rtirq`; it is worth one line in the findings doc.

## Proxy numbers

None for `ba3ba6108`; no workflow run exists (D1). The only proxy run is the pre-fix one on `ba9fc9954` (run 37419702835), tabled above. It used the old identity-head control, which understates the added cost (finding 7).

## Verdict (delta)

**Findings 1 to 6 are fixed and verified locally, and I found no blocking regression.**

The streaming render matches the materialising render wherever the two can match, and it is ASAN-clean across lengths, ratios and modes. The ratio and channel bounds cover the plan. The licences are bundled and shown.

**The PR is still not mergeable** (D1):

- It conflicts with the current trunk, so CI has not run on `ba3ba6108`.
- Neither the new CI gate, the Linux visibility build nor the new proxy numbers have been observed.

Rebase onto `51e6b45dc`, keep both sides of the `test_engine_core.c` include and test list, and get green CI, including `native-bench-arm64` with "ALL THRESHOLDS MET". After that I have no objection to merging. D2 and D3 are small follow-ups that can be done before or after merge.
