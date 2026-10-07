Model: Claude Opus (subagent), in-session

# Review of PR #1259 (origin/claude/midi-clock-1228-p2 @ e9e7fb509): feat(engine): follow an external MIDI clock

## Scope

- The single commit `e9e7fb509`, stacked on Part 1 (`8c2f43d48`, PR #1246). It adds:
  - `src/midi/le_clock_follow.{h,c}`, the follower with its readout band;
  - `LE_CMD_SET_CLOCK_SYNC` (124) with a receipt;
  - `LE_ERR_EXTERNAL_CLOCK` (-20) and `LE_ERR_SYNC_LOCKED` (-21) at the call and in the callback;
  - the per-beat session tempo write;
  - the backlog filter;
  - dispatch from the ordered sink drain;
  - the send switch renamed (`LE_CMD_SET_CLOCK_SEND` = 48) and the clock-mode tri-state removed;
  - the time-source hook;
  - CMake, SwiftPM, CocoaPods, bench and test-lib wiring;
  - `test_clock_follow.h` and `test_engine_clock.h`.
- Checked against:
  - the plan at `820c54a1f` (D1, D3, D11, D12 and Part 2);
  - AGENTS.md and the owner rules.
- There is no UI in this part.

## Runs

Each run has its own `TMPDIR`.

| Run | Result |
|---|---|
| Native suite, plain × 3 | green |
| ASAN | green |
| Telemetry-off | green |
| TSAN races × 3 | green, no warnings |
| `packages/segno_engine` Dart tests against the P2 test library | 376 passed |
| `dart analyze --fatal-infos` (segno_engine) | clean |
| C++ shim repro on `engine_private.h`, with and without `-U__clang__` | compiles |
| `git grep` for `clock_mode`, `LE_CLOCK_RECEIVE`, `set_clock_mode` and `a_clock_mode` outside docs | none left |
| CI on #1259 at `e9e7fb509` | all jobs green, including `build-linux`, `build-linux-arm64`, `native-tests` (ASAN, TSAN, telemetry-off), `vst3-plugins-linux` and `fuzz`. This run also covers Part 1's ALSA change. |

### Follower probe re-run against the built code

`p2probe.c` drives `le_clock_follow.c` in the engine's order: each block (128 frames at 48 kHz) feeds every pulse stamped up to the block time, then runs `le_clock_follow_check`. The runs last 60 s each. The error and the readout changes are counted after 5 s, outside the 4 s after a step. The full output is in `p2probe-output.txt`.

| Model | Steady 90 / 120 / 124.9 / 174 | 120→100 | 120→60 | 150→50 | 174→87 | 60→120 | One dropped pulse (at #600) |
|---|---|---|---|---|---|---|---|
| uniform ±1 ms | error ≤ 0.037, 0 changes, count exact | 1 reacq, 1.02 s, exact | 1, 0.81 s, exact | 1, 0.62 s, exact | 1, 0.61 s, exact | 1, 0.98 s | exact, 0.025 |
| USB 1 ms | ≤ 0.024, 0 changes, exact | 1, 0.17 s | 1, 0.69 s | 1, 0.12 s | 1, 0.83 s | 1, 0.90 s | exact |
| block 512 @ 44.1 kHz | ≤ 0.184, ≤ 1 change, exact | 1, 1.28 s, **count 1 short** | 1, 0.91 s, exact | 1, 1.28 s | 1, 1.19 s | 1, 1.13 s | **count 1 short, 1.48 BPM error, 6 changes** |
| block + noise | ≤ 0.186, ≤ 1 change, exact | 1, 1.26 s, **1 short** | 1, 0.99 s | 1, 1.28 s | 1, 1.21 s | 1, 1.09 s | **1 short, 1.49 BPM** |

The DH1 integer-division rule works on every model, and steady readouts hold. The failures sit on the block-edge sources. Three focused probes:

- **`p2acq.c`, acquisition on block edges over 200 start phases.** The worst tempo at the moment of Synced is off by 17.67 (90), 12.33 (120), 17.23 (124.9) and 41.33 BPM (174). It takes up to 1.0-2.0 s to come within 0.1 BPM.
- **`p2drop.c`, one unmarked dropped pulse over 200 positions.** The pulse count is wrong in 43 positions at 90, 82 at 120 and 200 at 174. In the 20 beats after the drop, the worst tempo error is 4.1, 12.3 and 1.5 BPM.
  - `p2drop2.c` traces the worst case (drop at #604, 120 BPM): six same-sign outliers; a re-seed on the sixth to 107.67 BPM; then about 2 s to climb back. The readout shows 107.7, 108.0 … 116.3 along the way.
- **`p2_engine_probe.c`, through the engine with the fake clock.**
  - On a block-edge source at 120 BPM, the first session tempo written to an empty rig is 107.67, and it stays up to 12.33 BPM off during the first two beats.
  - Device exit then close: SYNCED, then LOST (losses 1), then **WAITING with `clock_bpm` 0** once the app closes the capture.
  - Closing a Synced source: **WAITING, losses 0**.
- **`p2edge.c`.**
  - A pulse 251 ms after the last, fed in the same block as the 250 ms deadline, is counted as 11 missed pulses. There is no Lost.
  - Two pulses with one timestamp count as one.
  - During a 120 → 130 ramp over 8 s, the estimate trails by 1.43 BPM. It settles 1.4 s after the ramp ends.

### Mutations

I used a focused driver (`p2_clock_driver.c`, `p2mut.sh` and `p2mut.py`) over `test_engine_midi_in.h`, `test_engine_clock.h` and the MIDI test binary with `test_clock_follow.h`.

Killed:
- no integer-division rule;
- no take-back on a division;
- no take-back on an outlier re-seed;
- no missed-pulse count;
- gap ignored by the follower;
- no fast 0.5 Hz stage;
- no σ band;
- no one-beat hold;
- silence after Stop not read as Waiting;
- loss floor at 150 ms;
- denominator ignored;
- out-of-range never set;
- the callback letting `set_tempo` through;
- no callback sync lock;
- no control sync lock;
- no backlog filter;
- send gate open under an external source;
- REBOUND ignored;
- the source gap not passed on;
- the effective-source check reading only the applied source.

Survived (L3):
- the callback-side `restore_tempo` guard removed (`engine_process.c:3170`);
- the callback-side tap guard removed (`:3218`);
- the control-side `armed[]`/`a_pending` lock check removed (`engine_commands.c:3343`);
- **the follower writing the session tempo while content locks it** (`engine_process.c:6420`, the `le_tempo_locked` check removed).

## Verified correct (traced)

**Units.**
- The window is the 30-300 clamp converted by `ts_den/4`, ±2 %.
- The engine BPM is the quarter-note BPM × `ts_den/4`.
- In 6/8, 120 → 240, and 160 is out of range. Both are tested, and the den-ignored mutation is killed.

**Missed pulses and integer divisions (DH1).**
- An isolated whole-multiple interval adds `k-1` periods to the prediction.
- A second interval in a row takes the count back and re-seeds from the pair.
- An outlier re-seed takes back a whole-multiple count made within the run.
- A gap mark counts what it hid (`le_clock_follow.c:202-235`).

**Tempo ownership.**
- The control-side -20 uses the requested source while a sync command is queued (`le_clock_source_effective`), so no setter slips in before the receipt. The callback rechecks.
- -21 is checked at the call and again in the callback, against the applied source. Re-selecting the same source with another policy is allowed.
- Selecting Internal turns an EXTERNAL tempo into MANUAL.
- The send gate closes under an external source.

**Real-time safety.**
- The follower is O(1) per pulse.
- The worst case is an insertion-sort median over at most 64 doubles, and only at a re-seed.
- There is no allocation and no lock. `now_ns` is read once per drain, and only while a source is selected.

**Lifetimes.**
- `le_engine_reset_runtime` resets the follower and keeps the source.
- The follower state is touched only by the audio thread, except configure, which runs with the callback stopped.

**Build wiring.**
- The new TU is in CMake, the SwiftPM and CocoaPods forwarders, `run_native_tests.sh` (engine and MIDI binaries), `build_test_lib.sh` and both bench scripts.
- No other engine source list in the repo names `le_midi_clock.c` (checked with `git grep`).

**The tri-state is gone.** Receive moved to `LE_CMD_SET_CLOCK_SYNC`, and the send switch is a 0/1 as the revised D12 says.

## Findings

### High

None.

### Medium

**M1. The median-of-six seed makes acquisition and outlier re-seeds wrong by up to 41 BPM on block-quantised sources, and an unmarked dropped pulse there loses a count.**

Where: `le_clock_follow.c:155` (acquisition), `:260` (re-seed), `:207` (the σ < P/6 gate); `engine_process.c:6420-6431` and `:6467` (the tempo write at the Synced edge).

- On a source whose pulses land on 512-frame / 44.1 kHz edges, intervals are one or two blocks: 11.6 or 23.2 ms. That is bimodal, so the median of six is one of the modes, not the period. The plan lists this model as one the follower must handle.
- **At Synced.** The tempo is off by up to 12.3 BPM at 120 and 41.3 at 174. The engine writes it as the session tempo at once on an empty rig: 107.67 for a 120 clock in the engine probe. The Sync page shows it, and the click runs at it, for 1-2 s.
- **After a dropped pulse.** σ ≥ P/6 switches off the missed-pulse count (always at 174, often at 120). The drop therefore becomes six same-sign outliers, which re-seed from six block-quantised intervals. At 120 this gives 107.67 BPM and about 2 s of wrong tempo, and the pulse count stays one short for good. Parts 3a and 4 build bar anchors and Song Position on that count.
- A 120 → 100 step on block edges also ends one count short.
- The tests run dropped pulses and steps only on the uniform and USB models (`test_clock_follow.h:113-121`, `:192-200`), and the jitter test measures only after 5 s. None of this is caught.
- Fix:
  - Seed from the span of the timestamps (a least-squares fit, or `(t_last - t_first)/n`), not the median.
  - When the six intervals spread by more than about 20 % of P, keep acquiring for one beat before Synced.
  - On an outlier re-seed, infer the pulses the run hid from its span and the new period, and add them to the count.
  - Do not write the session tempo at the Synced edge until the loop has run its first beat. Writing at the next beat boundary is enough.
  - Add block-edge oracles: tempo at Synced within 0.5 BPM; one dropped pulse counted; a step keeping the count.

**M2. REBOUND resets the follower to Waiting, which hides a loss and erases "Clock lost".**

Where: `engine_process.c:6501-6508`; plan D1 ("starts over on REBOUND").
- **A vanished device.** On a USB unplug, PORT_EXIT gives LOST and the state is Clock lost, keeping 120. About 2 s later the app's poll closes the vanished capture (generation bump), and REBOUND resets the follower: the state becomes WAITING, with `clock_bpm` 0. The same happens on macOS after a silence loss.
  - The page then reads "Start the clock on your other device." instead of "Last tempo retained." / "Use internal tempo" (27/04 and 27/05).
  - AB 7.3 says Clock lost stays visible, and the API comment says the last value is kept while LOST.
- **Closing a Synced source.** For example the app re-opening the device, or a re-attach. The state goes WAITING with `clock_losses` 0, and no LOST event is raised. Part 5's loss sequence keys on that event, so the takes in progress would not be closed and the loss policy would not run.
- `test_clock_sync_rebind_and_gap` asserts this Waiting outcome, so the test and the plan agree with the code. All three are wrong against AB 7.3.
- Fix:
  - On REBOUND of the source port, a Synced follower goes Lost and returns `LE_CLOCK_EVENT_LOST`, which counts a loss.
  - A Lost follower stays Lost and keeps its period and display.
  - Only acquisition state (`have_last`, `n_acq`, outlier runs) restarts. A re-acquisition then moves Lost → Synced as after a cable fault.
  - Change the test, and add "exit, then close: still LOST with 120".

### Low

**L1. Whether a dropout is a loss depends on block phase.**
- `le_clock_follow_check` runs after the drain has fed the block's pulses.
- If the first pulse after a silence of just over 250 ms arrives in the block that crosses the deadline, it is fed first. It is counted as about 11 missed pulses (`whole` = 12, isolated, previous error small), and no Lost is raised (`p2edge.c`). The same dropout one block later is a loss.
- Once Part 5 acts on loss, the outcome of a 250-260 ms dropout depends on block phase.
- Fix: in `le_clock_follow_pulse`, when Synced and the interval is at or above `max(6P, 250 ms)`, apply the same Lost (or Waiting-after-Stop) transition before treating the pulse as the first of a new run.

**L2. A pulse with the same timestamp as the previous one is dropped from the count** (`le_clock_follow.c:181`).
- `le_midi_split` stamps every message of a CoreMIDI packet with the packet time, so two 0xF8 in one packet count as one.
- Part 7's DIN reader will stamp at `read()`, so a reader delay that batches pulses does the same.
- The pulse count then drifts.
- Fix: for `t_ns == last_t`, count the pulse and skip only the interval and DLL update. For `t_ns < last_t`, keep ignoring it.

**L3. Four guards have no test.**
- Mutations removing each of these survive:
  - the callback-side `restore_tempo` and tap refusals;
  - the control-side armed/pending part of the -21 lock (only RECORDING is tested);
  - the `le_tempo_locked` check that stops the follower from writing the session tempo over a rig with content.
- The last one is the guard that keeps Part 2 from retiming a loop.
- Fix:
  - a raw queued `RESTORE_TEMPO` and `TAP_TEMPO` under external, checking the tempo is unchanged;
  - `set_clock_sync` with a quantized arm pending, expecting -21;
  - a rig with a recorded loop at 120 and a 126 clock: the session tempo stays 120 and `clock_bpm` reads 126.

**L4. The backlog filter drops only old pulses** (`engine_process.c:6435-6450`).
- Start, Continue and Stop older than the deadline are still applied, so an old 0xFC can leave `stopped` = 1. A later silence then reads Waiting rather than Lost.
- Fix: apply the same age test to transport bytes.

## Notes

- **Ramp lag.** The 0.2 Hz loop trails an accelerando by about 1.4 BPM at 1.25 BPM/s. That is intended smoothing, but Part 3b's retime threshold should be designed against it.
- **CI on the stack.** #1259 targets `claude/midi-clock-1228-p1`. CI ran on it here, but per the stacked-squash precedent, re-check after #1246 squashes.
- **Plan departures.** The three listed in the plan's Part 2 header are reasonable and documented:
  - the anchor and re-anchor moved to 3a;
  - "no count-in for external starts" moved to Part 4;
  - the send switch was kept.

Verdict: Request changes (M1 and M2; L1-L4 are small).

## Delta review (8040d3c95)

### Scope

- Commit `8040d3c95`, on top of `e9e7fb509`. Part 1 is unchanged at `8c2f43d48`.
- What it contains:
  - least-squares acquisition, with at least one beat and at most four, and a cut of the fit at a tempo change;
  - a single 0.2 Hz loop;
  - the run classifier, which decides whether a run of late pulses is dropped pulses or a tempo step;
  - tempo written only once the follower reports it ready;
  - REBOUND treated as a loss;
  - a pulse that arrives after the loss deadline is now reported as a loss;
  - equal timestamps counted;
  - old Start, Continue and Stop bytes in the backlog dropped;
  - LOST dispatched before a REBOUND in the same drain (Part 1's DL1);
  - new tests.
- Probes, outputs and the mutation log are in `delta-8040d3c95/` beside this review.

### Runs

Each run has its own `TMPDIR`.

| Run | Result |
|---|---|
| Native suite, plain × 3 | green |
| ASAN | green |
| Telemetry-off | green |
| TSAN races × 3 | green, no warnings |
| CI on #1259 at `8040d3c95` | success |

**Probes as oracles, against the built follower.**

| Probe | e9e7fb509 | 8040d3c95 |
|---|---|---|
| `p2acq`, seed error at Synced, block edges, 200 start phases | up to 17.7 / 12.3 / 17.2 / 41.3 BPM | **≤ 0.15 BPM** at 90 / 120 / 124.9 / 174; within 0.1 BPM in 0.04-0.36 s |
| `p2drop`, unmarked drop at 200 positions, block edges | count wrong 43 / 82 / 200; up to 12.3 BPM error | **count wrong 0 / 0 / 0**; worst error 0.53 BPM |
| Engine probe, first session tempo written (block edges, 120) | 107.67 | **119.99**, a beat after Synced; within 0.02 BPM |
| Engine probe, device exit then the app's close | Lost becomes Waiting, BPM 0 | **stays LOST, 120.0, losses 1** |
| Engine probe, a Synced source closed | Waiting, losses 0 | **LOST, losses 1** |
| `p2edge`, a pulse 251 ms late in the same block as the deadline | 11 pulses counted as missed, no loss | **LOST** (event 4); re-acquired; count right |
| `p2edge`, two pulses with one timestamp | counted 1 | **counted 2** |
| `p2probe`, steady, all models | ≤ 1 readout change | 0 changes; error ≤ 0.056 BPM; counts exact |
| `p2probe`, integer divisions and steps, all models | followed | followed, each settles in 0.12-0.72 s (60→120 on block edges 2.2 s) |

**Correction to my first review.** M1 said "a 120 → 100 step on block edges also ends one count short". That came from my probe: the last pulse, quantised past the 60 s run end, was never fed. A scan that feeds every pulse shows 0 of 100 wrong for this step on both `e9e7fb509` and `8040d3c95`. I withdraw it.

**Mutations** (`mutations.txt`): 13 of 14 killed.
- Killed, among others:
  - the four previously untested guards: restore, tap, armed or pending, and the content lock;
  - Lost dropping the tempo;
  - old transport bytes applied from the backlog;
  - no loss on a pulse past the deadline;
  - equal stamps ignored;
  - a dropped pulse not counted;
  - pulses missed during a re-fit not counted;
  - a six-interval acquisition minimum;
  - no kink cut;
  - LOST not dispatched before the REBOUND.
- Survived: replacing `le_clock_follow_tempo_ready` with a plain Synced check. The engine already delays the first write by a beat, so the only uncovered case is a write while a re-fit is running.

### Prior findings

| Finding | Status |
|---|---|
| M1 seed, block-edge drops | **Met** (oracles above) |
| M2 REBOUND | **Met** |
| L1 deadline | **Met** |
| L2 equal stamps | **Met** |
| L3 untested guards | **Met** |
| L4 old transport bytes | **Met** |
| Part 1 DL1 | **Met** (`2E90 2L 2R 2E80`) |

### New findings

**DH1 (High, a regression in this delta). Pulses delivered late in a burst corrupt the pulse count and swing the tempo by up to 60 BPM.**

Where: `le_clock_follow.c:516-536` (the whole-multiple rule), `:582-594` with `:373-449` (the run classifier and re-fit), and `:343-362` (counting hidden pulses during a re-fit).

- **The model.** Pulses that fall in a stall of length `s` are delivered together at its end, each stamped microseconds apart. That is what the ALSA reader does when the rawmidi or sequencer kworker, which runs at normal priority, is held up. The plan names this kernel path as a known risk. Results are over 100 phases at 120 BPM (`scan.c`).

| Stall | Uniform: count wrong | USB: count wrong | Block edges: count wrong | Worst tempo error 4 s after |
|---|---|---|---|---|
| 10 ms | 0 | 0 | 0 | ≤ 0.06 |
| 25 ms | 39 | 38 | 15 | 0.10 |
| 45 ms | 45 | 43 | 51 | 0.18 |
| 70 ms | 49 | 49 | 44 | 1.9 BPM |
| 100 ms | 55 | 54 | 56 | 5.2 BPM |
| 200 ms | 100 | 100 | 100 | 5.2 BPM |

- **The same scan on `e9e7fb509`** (`scan-e9e7fb509.txt`): uniform and USB are wrong in 0-2 of 100 at every stall length. Block edges are wrong only at 25-45 ms (11-26 of 100). The tempo error stays ≤ 0.18 BPM throughout. So this commit made stall handling worse.
- **Mechanism, traced for a clean clock and a 100 ms stall** (`trace-100ms-stall.txt`):
  1. The first late interval is about 5 periods, so the whole-multiple rule counts four missed pulses. They were not missed, only late, and the burst then delivers them as well.
  2. The burst opens a run. The classifier calls it a step, and the re-fit starts from the burst's own timestamps, which are microseconds apart. The fitted period becomes 182 BPM.
  3. `le_cf_refit_pulse` then reads every on-time pulse as "whole periods late" against that slope and counts phantom hidden pulses: one more every second pulse.
  4. The next re-fit gives 65 BPM, and the readout shows 157.9 along the way.
  5. The count finishes 45 pulses high, permanently.
- **Failure.** A tempo-ready window can fall on a wrong fit, and the session tempo of an empty rig is then written from it. More importantly, Parts 3a and 4 place bar anchors, Song Position and slips from `clock_pulses`. A single 25-45 ms delivery stall moves the bar by one or more pulses in about 40 % of cases, and nothing corrects it.
- **The tests miss it.** The only stall test is 4 ms (`test_clock_follow_stall_is_not_a_step`).
- **Fix:**
  - Treat a burst as late delivery, not as tempo evidence. When a whole-multiple interval is followed by an interval under P/4, take its extra count back, as the equal-stamp rule already does for identical stamps.
  - Exclude points less than P/4 apart from run classification and from the re-fit line. Place them by index on the old line.
  - Count hidden pulses in `le_cf_refit_pulse` only once the fit's standard error is below a fraction of the period, never from a fit seeded by a burst.
  - Add oracles for stalls of 25, 45, 100 and 200 ms on every model: count exact, and within 0.2 BPM 2 s after.

**DL1 (Low). Re-classifying a tempo change from 90 to 174 on block edges miscounts in 21-29 of 100 phases**, with two re-fits and 0.33-0.38 BPM error 4 s after. On `e9e7fb509` it was 0 of 100. The likely cause is the same: a re-fit counting hidden pulses from an early, coarse fit. The fix above should cover it. Add this step to the block-edge step oracles.

**DL2 (Low). A ramp produces several re-fits.**
- During the 120 → 130 accelerando over 8 s, `p2probe` shows 5 re-fits on the uniform and USB models (0 on block edges). The plan's table says 0-2.
- Each re-fit stops tempo writes for its length, at least one beat.
- The count stays exact. But Part 3b's "one retime per bar during a ramp" needs to know whether re-fits interrupt it.
- Fix: correct the table, and specify how 3b treats `refit`.

**DL3 (Low). The classifier's cost per pulse grows with the square of the run length** (`le_clock_follow.c:403-416`).
- While a run is armed but undecided, each pulse costs 3 × m × m operations, which is about 12 000 at m = 64.
- That is tens of microseconds per pulse on a Pi, on the audio thread, in a backlog burst of up to 12 pulses.
- Fix: with running sums, the best hidden count for each split point is O(m).

### Notes

- **Part 8 and REBOUND.** A REBOUND of a Synced source is now a loss with an event. Part 8's attachment replay must not re-attach an unchanged capture to the source port: the reattach would count a loss, and from Part 5 it would end takes.

Verdict (delta): Request changes (DH1).

## Delta review (422f819dd)

PARTIAL - stopped for cloud migration

### Verified

- **Native suites.** Plain ×3, ASAN, telemetry-off and TSAN races ×3 are all green, with no TSAN warnings. CI on #1259 at 422f819dd: success.
- **Static checks and Dart.**
  - The `segno_engine` Dart tests pass (376) against the 422f819dd test library.
  - `dart analyze --fatal-infos lib test packages` is clean, once `flutter pub get` has run in every package. The 389 issues from a first run were all in `storage_repository`, which had not been resolved in the worktree.
  - `bloc lint lib test packages`: 0 issues, 880 files.
- **My probes, re-run as oracles** (outputs in `delta-422f819dd/`).
  - `scan.c`: every stall row (10-200 ms, four models) and every step row, 90→174 included, has **0 of 100 wrong**. The worst tempo error 4 s after is 0.073 BPM. **The DH1 claim holds.**
  - The 100 ms trace ends with the count exact and no re-fit.
  - `p2acq`: seed ≤ 0.15 BPM.
  - `p2drop`: 0 wrong at 90, 120 and 174; worst error 0.53 BPM.
  - `p2edge`: a 251 ms gap is LOST; equal timestamps count 2.
  - `p2probe` ramp: 2 re-fits on the uniform and USB models, 0 on block edges. This is consistent with the plan's corrected 0-6.
- **Mutations** (`mutations.txt`): 16 of 16 killed. These include:
  - burst rule removed;
  - burst pulse not counted;
  - no late-pulse hold, in tracking and in acquisition;
  - the back-on-line check never true, and always true;
  - no 1 % re-fit gate;
  - no jitter seed;
  - the suffix-sum classifier off by one hidden pulse;
  - the previous survivor, the tempo-ready gate.

### Probing the new hold (`adv.c`, 100 phases, four models)

Clean:
- a drop next to a stall on the uniform and USB models;
- a 25 ms stall at a 120→100 step (uniform: 2 of 100 wrong);
- a stall just after a step;
- a drop, two adjacent drops, and a 45 ms stall at 174 BPM, on every model.

Not clean:
- On block edges, these combinations miscount:
  - a drop followed by a 45 ms stall at the next pulse: 36-46 of 100, +2;
  - a drop right after a burst: 9-10 of 100;
  - a 45 ms stall just after a 120→100 step: 14 of 100.
- Step-ups of about 4.7× or more are never followed on the uniform and USB models (60→300, 50→250, 30→140). The burst rule treats every new pulse, which is less than P_old/4 after the last, as a burst. `e9e7fb509` also failed some of these.

### New findings (provisional)

**DM1 (Medium). Steady block-edge sources at fast tempos miscount** (`hi2.c`, 50 phases, 20 s).

| Source | e9e7fb509 | 8040d3c95 | 422f819dd |
|---|---|---|---|
| Clean block edges, 160 BPM | clean | wrong in 2-3 of 50 | wrong in 2-3 of 50 (+3) |
| Clean block edges, 190 BPM | clean | wrong | wrong in 15 of 50 |
| Clean block edges, 200 BPM | clean | wrong | wrong in 50 of 50 (+20) |
| Clean block edges, 210 BPM | clean | wrong | wrong in 50 of 50 (+28), 5.3 BPM off |
| Block + 0.5 ms noise, 220-300 BPM | wrong | wrong | wrong in all phases, tens to hundreds of pulses, 4-53 BPM off |

- Clean block edges at 220-300 BPM are now fixed.
- **Mechanism** (`trace-200bpm-block.txt`): acquisition counts a pulse more than 0.5 P off the line as hidden pulses. At 200 BPM, block quantisation alone exceeds that, so the count gains one about every 13 pulses, and the seed reads 213.9 BPM.
- **Fix:** count hidden pulses during acquisition only when the offset exceeds 0.5 P by several residual σ, or hold the pulse as tracking does. Add 160-300 BPM block-edge oracles, or state the supported tempo range for coarse sources.

**DL1 (Low).** Step-ups of 4.7× or more are not followed (above). Fix: a long run of consecutive "bursts" with no late pulse before it is a tempo step.

**DL2 (Low).** The block-edge drop-and-stall combinations above.

### Not done

- the full delta write-up and verdict;
- the plan delta (#1236 at 6971de523);
- worktree cleanup confirmation.
