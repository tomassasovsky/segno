Model: Claude Opus (subagent), in-session

# Review of PR #1256: #1198 Part 3, stop at whole frames on the reserve and on slow storage

## Scope

- **Branch:** `claude/recording-1198-p3` at 09c4f6168, one commit (38 files, +1321/−306).
- **PR:** #1256, open, base `claude/recording-1198-p2`, stacked on P2's head 51696d5f3.
- **Reviewed against** plan Part 3 and D2 on `claude/recording-recovery-plan-1198` (3223c726e), AGENTS.md and the owner rules.
- **What the part contains:**
  - the drain's reserve budget;
  - first-drop slow-storage stops;
  - the public `le_perf_stop_reason` enum;
  - the snapshot fields `perf_stop_reason`, `perf_bytes_written`, `perf_first_drop_frame` and `perf_overs`;
  - `PerfTarget.reserveBytes`;
  - `PerformanceRepository.minimumFreeBytesToArm`;
  - the recorder cubit dropping `stopFloorFor` and `finalizeHeadroomBytes`.

## Runs

| Suite | Result |
| --- | --- |
| Native, plain ×3 (own TMPDIR each) | green |
| Native TSAN races | green |
| Native ASan | green |
| Native, telemetry off | green |
| `segno_engine` with `SEGNO_ENGINE_LIB` | 383/383 |
| `performance_repository` | 132/132 |
| `session_repository` | 189/189 |
| `wav_codec` | 7/7 |
| App suite with the library | 3475 passed, 56 skipped, 0 failed |
| `dart analyze --fatal-infos lib test` plus the touched packages and `storage_repository` | no issues |
| `bloc lint lib test packages` | 0 issues in 882 files |

**Concurrent probe** (`scratchpad/rvp2/p3-race_probe.c`; public API only):

- **Setup:** a real audio thread calls `le_engine_process` paced near the drain's throughput (255,000 to 262,000 frames/s) against a 1 s ring, while the production drain thread runs. One monitored input, so two streams.
- **Unmodified P3:** 4 of 12 runs end with streams of different lengths, no `stopped_early`, and stop reason DISARM (Finding 1).
- **With pops capped at `elapsed`:** 12 of 12 end at `slow_storage` with both streams exactly at the first drop. That includes drops after the first cycle (frames 81407, 86015, 110079, 130303, 157439 and 185855).
- **Reserve variant** (a `LE_NATIVE_TESTS` build using the volume-free hook, a paced 48 kHz producer, budget for 72,000 frames): 8 of 8 end at `reserve_reached` with both streams at 71,984 frames. The 16 frames short are the events.log bytes.

**Mutations:**

- **Native:** 4 tried.
  - **Killed (2):** the first drop overwritten instead of kept at its minimum; events.log bytes left out of the budget.
  - **Survived (2):** layer-file bytes left out of the budget; the 20-cycle free-space re-read removed (Finding 4).
- **Dart:** 5 tried, all killed:
  - reserve mapped to `diskFull`;
  - the old 500 MB arm floor;
  - `minimumFreeBytesToArm` without the reserve;
  - the reserve not passed to `PerfTarget`;
  - the warning without its headroom.

## Verified correct (traced)

1. **The audio thread records the first drop safely.** `perf_note_drop` (`engine_process.c:4137`) runs only when a ring push fails. It does one relaxed load and, when the frame is earlier, one relaxed store of `a_perf_first_drop_frame`.
   - The audio thread is the only writer, so the compare-then-store needs no compare-and-swap.
   - `e->perf.tap_frame = perf_frame_base + f` is a plain store of an audio-thread-local field. It is set at the top of the per-frame loop (`:6694`), and both tap sites run inside that loop: `mix_monitors_frame` at `:6760` and `output_bus_frame` at `:6788`.
   - No lock, no allocation, nothing unbounded. `_Atomic uint64_t` is lock-free on aarch64, the same type as the existing `a_perf_frames`.
   - The store is sequenced before the block's RELEASE add of `a_perf_frames` (`:6893`), so a drain that acquire-loads `elapsed` and then reads the drop (`perf_drain.c:1822`) sees every drop in a counted block. The ordering argument is correct; Finding 1 is about what the drain pops after that load, not about memory order.
   - Arm resets the drop, the reason, the bytes and the overs before `LE_CMD_PERF_ARM` is pushed. `le_engine_create` seeds `UINT64_MAX`.
2. **The budget counts what the drain writes:**
   - part headers (in `le_pd_open_part`, after a free-space reading taken before the first header);
   - samples, including zero-fill (landed bytes only);
   - events.log (the 12-byte header, then 28 bytes per entry);
   - layer files (frames × lanes × 4, which is their whole content).

   The sidecar (tmp, then rename) is left to the 1 MiB allowance, as D2 says. Every byte the drain writes goes through stdio and is flushed at the end of each cycle (layer files are closed), so the next statvfs sees it.
3. **Exact frames for the reserve.**
   - `le_pd_frames_within` (`:1710`) binary-searches the last absolute frame every stream can reach.
   - `le_pd_cost_to` charges each stream its samples plus one header per part it would open. Tests: 700 frames mono, 500 frames for mono + stereo, 301 frames across a part boundary.
   - Zero-fill is clamped to `min(elapsed, cap)`.
   - The sidecar's `capture_frames` is `min(elapsed, stop_frame)`.
4. **Stop reasons.**
   - The drain's own reason is set before the sidecar that names it is written, and published (`a_perf_stop_reason` compare-and-swap from NONE, then `self_stopped` with release) after it.
   - Disarm and reconfigure compare-and-swap their reason in after the join, so a drop that landed just before a disarm still reads SLOW_STORAGE.
   - The sidecar strings `disk_full` and `device_changed` keep their spelling.
   - The snapshot fields are appended at the end of `le_snapshot`, so earlier offsets do not move.
   - Dart `PerfStopReason.fromNative` maps by ordinal and falls back to `none` for an unknown value.
5. **The recorder.**
   - `_finishSelfStopped` maps the engine's reason, and the completion sheet shows one banner (the stopped-early reason outranks the glitch banner).
   - `_volumeTooFullToArm` uses `minimumFreeBytesToArm`, and the warning uses that minimum plus 500 MB.
   - The `df`-walking `stopFloorFor` is gone, as D2 (L3) asks.
   - The production entrypoints (`run_segno.dart`, `main_mock.dart`) pass `StorageRepository.internalReserveBytes`.

## Findings

### 1. High: a drop the drain has not seen yet lets streams pass the stop frame, and then the take never stops

- **Where:** `le_pd_drain_cycle` reads `a_perf_first_drop_frame` once, at `perf_drain.c:1822`, before it pops any ring. `le_pd_drain_ring` (`:1304`) then pops everything the ring offers up to that cycle's `cap`.
  - Frames in the rings can belong to a block not yet counted in `elapsed`, because the tail stores come before the block's add.
  - While the drain is popping, the audio thread keeps running. It can drop a frame F in one ring after the drain's load, while another ring still accepts F, F+1, …, and the drain then pops and writes those frames.
- **What happens next:**
  - On the next cycle `cap = F`. But a stream already holds more than F frames, and the drain cannot unwrite them, so `le_pd_all_streams_at(d, cap)` (`:1743`, used at `:1911`) is never true.
  - `stop_reason` stays NONE. Every stream is now capped at F, so nothing more is written, yet `perf_stopped` stays 0 and the recorder keeps showing Armed with an elapsed time that keeps counting.
  - At the disarm, the stop reason becomes DISARM, `stopped_early` is absent, and the streams have different lengths.
- **Probe results** (unmodified P3, 2 s paced runs, rings of 1 s):

  ```
  255000: reason=1 first_drop=65535  master_frames=66559  input0_frames=88575  no stopped_early
  255000: reason=1 first_drop=126719 master_frames=131839 input0_frames=127231 no stopped_early
  262000: reason=1 first_drop=86015  master_frames=86015  input0_frames=96027  no stopped_early
  255000: reason=1 first_drop=65535  master_frames=65792  input0_frames=70143  no stopped_early
  ```

  That is 4 of 12. An earlier run at 250k gave 76,288 master frames for a drop at 65,535 after 3 s of "recording". `while running: perf_stopped=0 reason=0` confirms the UI never learns.
- **Why it matters.** It breaks:
  - the plan's core promise ("Streams stop at `limit` together", "no frame pumped after the drop appears");
  - rule 3: the player sees Armed and a running clock while nothing is written, and the take ends with no reason;
  - rule 2: there is no recovery path, because nothing reports the loss.

  The trigger is exactly the situation this part exists for: storage that falls behind while the audio thread runs.
- **The reserve has the same failure.** If a stream already stands past the frame the budget can pay for, `all_streams_at` never holds. Streams can stand up to a block apart at a cycle's start for the same reason (frames of an uncounted block popped). I did not reproduce it in 8 paced runs (it needs the budget to run out inside that gap), but the code path is the same.
- **The suite misses it.** `test_perf_slow_storage_stops_at_first_drop` (`test_engine_core.c:11397`) makes the drop while the drain is held in the mid-cycle hook, after its pops, so the drop is always visible before the next pop. `test_perf_drain_races.c` paces its producer so the drain keeps up, so it never drops.
- **Fix:** pop no frame past `elapsed` this cycle: `cap = min(cap, elapsed)` for the ring drains.
  - Every frame at or below `elapsed` belongs to a block whose drop is visible to the load at `:1822`.
  - Frames above it stay in the ring for the next cycle.
  - Every stream ends each cycle at exactly `elapsed` (catch-up pads to it), so the streams never stand apart and both the drop and the reserve stop become exact.
  - I applied exactly that to a copy, and the probe went from 4/12 failing to 12/12 correct. It cannot pad over real audio, because a frame counted in `elapsed` is already in its ring (the tail store comes before the add).
  - Then turn the probe into a test in `test_perf_drain_races.c`: a paced producer near the drain's throughput, asserting equal stream lengths, `slow_storage` and `perf_stopped` while armed. Add a defensive assertion (or a stop) when any stream is found past `cap`, rather than waiting forever.

### 2. Medium: after a self-stop the audio thread keeps tapping, so the snapshot shows a drop and overruns the take never had

- **Where:**
  - After the drain stops itself (reserve or write failure), `perf.armed` stays set until the app's disarm, so the audio thread keeps pushing into rings nobody drains.
  - Once a ring fills, `perf_note_drop` records a first drop and counts overruns.
- **Probe (reserve):** stop reason 4 and 71,984 frames on disk, but `perf_first_drop_frame` reads 137,519.
- **Risk:** the snapshot documents `perf_first_drop_frame` as "A take that drops a frame ends there (LE_PERF_STOP_SLOW_STORAGE)", which is false for these takes.
  - Today the recorder checks `selfStopped` before it latches `overrun`, and the stop reaches it within one 250 ms tick against a ring of at least 2 s, so the banner is right.
  - But any later reader of these fields (Part 9's recorder state, telemetry, Part 13's indicator) will see a slow-storage drop on a reserve stop.
- **Fix:** stop recording drops once `a_perf_stop_reason` is not NONE. Either the audio thread checks it relaxed (one load on the failure path only), or the drain publishes a "stopped" flag the audio thread reads before `perf_note_drop`. Document that `perf_overruns` after a self-stop is not part of the take, and test that a reserve stop leaves `perf_first_drop_frame == UINT64_MAX`.

### 3. Low: the arm floor counts a stereo master only

- **Where:** `minimumFreeBytesToArm` (`performance_repository.dart:70`) is reserve + allowance + one header + 10 s of a stereo master.
- **The gap:** D2 (L3) says the destination must hold "at least 10 s of every stream above its reserve, the allowance and one header per stream". With four captured inputs at 96 kHz, a take arms with room for about 2 s and stops on the reserve at once.
- **Fix:** compute the floor from the captured stream set at arm (the monitors enabled now), as the drain will, or note the deviation in the plan until Part 5's `remainingFramesTogether` exists.

### 4. Low: two budget behaviours are untested

- **Mutations that survived:**
  - leaving the layer-file bytes out of `le_pd_count_bytes`;
  - removing the 20-cycle free-space re-read.

  No reserve test retires a layer or runs past 20 cycles with the free-space reading changing.
- **Fix:**
  - add a reserve test that stages one retired layer and asserts the stop frame drops by its size;
  - add one that changes the volume-free hook mid-take (for example, another writer takes space) and asserts the next re-read moves the stop.

### 5. Low: layer files and events are written before the budget, with no limit

- **Where:** events and retired layers are drained first in each cycle, then the audio gets what is left (by design).
- **Risk:** a long retired layer (for example 60 s of stereo at 96 kHz, 46 MB) staged when the budget is nearly spent is written whole. On Internal the 1 GB reserve absorbs it. On a removable volume (16 MiB reserve, Parts 6 and 10) it can run the volume out and end the take as `disk_full` instead of `reserve_reached`.
- **Fix:** before writing a staged layer, compare its size with the budget. If it does not fit, stop as `reserve_reached` and leave the layer unpersisted, the way an overrun already does. Or record this as a removable-volume item for Part 10.

## Notes

- **Silent fallback.** `reserveBytes` is optional on `PerformanceRepository`, and null means no budget. Both production entrypoints pass it, but a future entrypoint that forgets would record with no reserve stop and no error, the same failure mode the guard registry fixed by making `guards` required.
- **Behaviour change at arm.** Arming now needs about 1.005 GB free on Internal (1 GB reserve + 1 MiB + 10 s of stereo, 3.8 MB at 48 kHz), where trunk needed 500 MB. Plan D2 (L3) asks for this, and the refusal still shows its toast. The toast says "Free some space and try again", which still fits.
- **The free-space reading covers only the drain's own writes.** Between readings (5 s), the budget does not see other writers on the volume (a session save, the previous take's stem render). The plan accepts that.
- **Cluster rounding.** On FAT and exFAT, each open file holds up to one partly used cluster (up to 128 KiB). With 33 streams that is up to about 4 MiB the budget does not count. That is inside Internal's 1 GB reserve; Part 10 should check it against the 16 MiB removable reserve.
- **Landing.** This part is stacked on P2 and inherits P2's landing work (rebase onto #1238, trunk merge). `performance_repository.dart` will need the same `guards` resolution.

**Verdict:** Request changes for Finding 1. A slow-storage drop the drain has not yet seen leaves the take unstopped and silent, and leaves its streams unequal. The fix is a one-line cap at `elapsed`, plus a race test. Finding 2 should be fixed in the same pass. The rest are low.

## Delta review (a74bde1d8)

Model: Claude Opus (subagent), in-session

**Scope:**

- **30762f218** is 09c4f6168 rebased onto P2's c79ac53bd. The tree diff is only P2's README link.
- **a74bde1d8** is the fix commit: 16 files, +533/−23.

**Runs:**

| Suite | Result |
| --- | --- |
| Native, plain ×3 (own TMPDIR each) | green |
| Native TSAN races, including the new paced drop race | green |
| Native ASan | green |
| `segno_engine` with `SEGNO_ENGINE_LIB` | 383/383 |
| `performance_repository` | 132/132 |
| `session_repository` | all passed |
| `wav_codec` | all passed |
| App suite | 3474 passed, 1 failed |
| Scoped `dart analyze` | clean |

- **The one app failure is a timing flake.** `one_shot_persistence_test.dart` ("Save As and Save capture Released…") failed under parallel load and passed 4/4 in isolation. P4's run of the same tree passed it.
- **My concurrent race probe, against a74bde1d8:** 12/12 runs end `slow_storage` while still armed (`perf_stopped=1` before the disarm), with both streams exactly at the first drop. That includes drops after the first cycle (120319, 129279, 129535, 129791). Before the fix it was 4/12 wrong.
- **Mutations, all three killed:**
  - pops not capped at `elapsed` (killed by `test_perf_unseen_drop_still_stops_exactly`);
  - drops recorded after a stop (killed by `test_perf_no_drop_recorded_after_a_stop`);
  - an over-budget layer written anyway (killed by `test_perf_layer_past_the_budget_stops_the_take`).

### Earlier findings

| # | Now |
| --- | --- |
| 1 High: an unseen drop leaves the take unstopped and the streams uneven | **Fixed.** |
| 2 Medium: drops recorded after a self-stop | **Fixed.** |
| 3 Low: the arm floor counts a stereo master only | **Fixed.** |
| 4 Low: layer bytes and the 5 s re-read untested | **Fixed.** |
| 5 Low: layers written past the budget | **Fixed.** |

**How each was checked:**

- **1.** `pop_to = min(elapsed, cap)` for every ring drain, as suggested. A frame read always belongs to a counted block, whose drop the earlier load has seen, and catch-up pads to the same frame, so every stream ends each cycle at the same count. `le_pd_all_streams_reached` now uses `>=`, so a stream that somehow stands past the stop frame can no longer hold the take open. The deterministic test and the TSAN paced race (`drop_race` in `test_perf_drain_races.c`) both assert equal streams, `slow_storage` and `perf_stopped` while armed.
- **2.** `perf_note_drop` returns at once when `a_perf_stop_reason` is set: one relaxed load, on the failure path only, so the audio thread stays real-time safe. The snapshot comment now says neither field moves after a stop. One small window remains: the drain decides its stop before it publishes it, so a drop can still be recorded in the cycle between the two. The take's files are unaffected.
- **3.** `minimumFreeBytesToArm` now counts:
  - the reserve and the allowance;
  - one header per stream;
  - 10 s of every stream, from the new snapshot facts `perf_capture_streams` and `perf_capture_frame_bytes`.

  When not armed, those facts are computed exactly as `le_perf_arm` would: the first enabled pair, plus the monitored inputs present on the device.
- **4.** `test_perf_reserve_counts_layer_files`, and `test_perf_reserve_rereads_the_volume` through a new free-space cadence test hook.
- **5.** A staged layer larger than the remaining budget is not written. It counts as `layers_dropped` (the renderer already treats that as missing material), and the take stops at the reserve at the lowest stream's frame.

### New findings

None in the delta. For the disk-full case this part shares with P2 and P4, see the P4 review's Finding 1: a sealed part is listed with frames that never reached the file.

**Verdict:** Approve. Every finding is fixed and pinned, the race no longer reproduces, and all three mutations against the fixes are killed.
