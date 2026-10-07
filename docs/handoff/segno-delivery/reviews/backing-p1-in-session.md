Model: Claude Opus (subagent), in-session

# Review of PR #1222: feat(engine): native backing voice, handoff, budget, click pan (#1200 Part 1)

## Scope

- **Branch:** `origin/claude/backing-1200-p1` at `75b7e84c7`, three commits on trunk `097e1ef68` (`28517aafc`, `7e28fc768`, `75b7e84c7`). Merges cleanly into trunk (`git merge-tree`).
- **Code reviewed:**
  - `src/core/engine_backing.c` (new: buffers, registry, control API);
  - the backing voice and handlers in `engine_process.c` (`:2198-2370`, `backing_frame` `:4677`, the block hooks `:6881`, `:7018-7031`, `:7047-7056`);
  - the lifetimes in `engine.c` (`reset_material`, `reset_runtime`, `destroy`, the raw-post refusal);
  - the arm reset in `engine_commands.c:4638`;
  - the sidecar marker in `perf_drain.c:1290-1298`;
  - `lockfree_ring.h`, `engine_private.h`, and the header contract (`segno_engine_api.h`);
  - `test_engine_backing.h` and `test_backing_races.c`.
- **Reviewed against:**
  - the plan at `c05ba9f45` (sections 4.1, D4, D5, D6, D10, D11 and Part 1);
  - AGENTS.md;
  - the owner rules.
- **Pen:** Part 1 has no UI, so it was not read.

## Runs

All runs were on the PR head, each with its own `TMPDIR`.

**Native suite.**
- I ran the plain, ASan and telemetry-off configurations, plus the TSAN races-only job, which builds `segno_backing_race_tests.exe` with `-fsanitize=thread`.
- The first pass ran all eight jobs for P1 and P2 at once. Plain and telemetry-off then failed one check, `test_fade_restore_staging_and_manifest_capacity` (`test_engine_fade.h:898`). That check waits at most 5 s for the drain thread. It is a load-sensitive fade test, not backing code.
- Rerun serially, every configuration passes:

| Configuration | Result |
|---|---|
| plain | ALL PASSED |
| ASan | ALL PASSED |
| telemetry-off | ALL PASSED |
| TSAN races | ALL PASSED, no report. 19,064 accepted, 936 refused, 7,911 buffer handoffs, 302 advances seen, max owned 4 |

**Dart.**
- `segno_engine` suite against a freshly built test library: 376 tests, all passed.
- `dart analyze --fatal-infos packages/segno_engine`: clean (checked on the P2 head, which contains P1).

**Symbol parity.**
- `check_ffi_symbols.sh` needs GNU `nm -D` and exits 1 silently on macOS, so I checked by hand.
- Every `'le_…'` name in the bindings (214) is exported by the test dylib. The only exceptions are the MIDI entry points, which the test library does not link, as on trunk.

**Mutations.** Each was applied singly to a scratch worktree, then I ran a backing-only driver (`run_backing_tests()`) and the race test, both under ASan.

| Mutation | Caught by |
|---|---|
| `le_backing_drop_cur` returns the buffer even while the fade voice reads it | the race test only (heap-use-after-free in `backing_frame`) |
| `le_backing_end_fade` returns a shared buffer | unit tests and the race test (UAF) |
| `le_backing_release` frees the kept buffers on a retained reopen | `test_backing_lifetimes` (UAF) |
| marker counts without the captured-pair mask | `test_backing_marks_capture` |
| `le_backing_release` no longer clears the fade voice | **not caught** (L2) |
| the arm-time reset of `a_perf_backing_blocks` removed | **not caught** (L2) |

## Verified correct (traced)

### Buffer lifetime against every interleaving

I enumerated where a buffer can be. Each place is listed in `backing_owned`, which is control-thread only:
- in the ring;
- `backing_cur`;
- `backing_next`;
- `backing_fade` with `owns`;
- a dead slot.

Removal from the registry happens in only two places:
- `le_backing_collect`, after an acquire exchange of a dead slot;
- `le_backing_release`, with the callback stopped.

**Every audio-thread transition** moves a pointer from exactly one place to exactly one other place:
- **LOAD:** `fade_out_cur` returns the old fade's buffer if it owned it, then shares cur's buffer. `drop_cur` then transfers ownership to the fade when the buffers are shared, or returns it.
- **STAGE_NEXT:** returns the old staged buffer.
- **CLEAR:** returns cur and next.
- **The End = Next advance:** `drop_cur`, then `next` becomes `cur`.
- **Cut:** `end_fade`.

The control side cannot race any of this:
- It never touches `cur`, `next` or `fade`. It only pushes them (release) and collects them (acquire).
- `le_backing_post_buffer` refuses a pointer that is already registered, so one buffer can never be in two places.

**Return slots never run out.**
- Buffers in slots are distinct and owned, and at most four are owned. So when the callback returns a buffer it still held, at most three slots are taken.
- The advance's `can_return` guard is therefore belt-and-braces. `test_backing_advance_refused_when_returns_full` proves it refuses and stops rather than dropping a buffer.

**Releases with the callback stopped:**
- **Configure:** `reset_material` releases all, then `reset_runtime` releases with keep. Only the epoch bump repeats.
- **Retained reopen:** `quiesce`, then `reset_runtime`, which collects first, frees everything except `cur` and `next` (including a LOAD still queued in the ring, before `le_ring_init` drops it), and clears the fade.
- **Destroy:** releases after the device and the workers are gone.
- `le_engine_reopen_configured` refuses while `a_running` is set, so these releases never meet a live callback.
- Every engine control call is made from the main isolate (`Isolate.run` appears only in `storage_io.dart`), so the registry has a single writer.

### Real-time safety

- The audio-thread code allocates nothing, frees nothing, takes no locks and makes no system calls.
- Per frame:
  - idle cost is one compare (`if (backing_live)`);
  - live cost is two voice reads and one `le_fx_route_frame`;
  - each end event costs four relaxed loads (`can_return`).
- Per block: two `le_pan_gains` calls, the publish stores, and one relaxed increment for the marker.
- Commands are drained at the block top (`engine_process.c:6596`) before `backing_live` is sampled, so a LOAD with `play=1` sounds in the same block.

### Mix point

- `backing_frame` sums after `click_frame` and before the output-bus loop, with `backing_mask & out_enabled`. The bus loop then applies chain, tap, level, Mono, balance and mute, then master gain, the limiter and the meters. This matches D5 and AB 3.1. Evidence:
  - `test_backing_output_bus_processes_it`: bus level, mute and master gain;
  - `test_backing_in_master_capture`: master tap sample-exact;
  - my P2 NaN probe: the backing reached an output reverb.
- **Stems and the offline master:** no backing code is perf-logged (`apply_command_image` routes 88-92 to `le_backing_apply` with no `le_plog_push`). `test_backing_excluded_from_stems` asserts both that no 88-92 code appears in `events.log` and that render parity holds while the backing sounds on output 1.
- **Loop takes** read inputs only. I found no output-to-input path in `engine_process.c`; "loopback" there means hardware loopback inputs, which are excluded.
- **Capture marker:** counted only while armed (`perf_bus >= 0`) and only when the mask reaches the captured pair.

### Click pan

- `le_fx_route_frame(…, s·gl, s·gr)` at centre writes `0.5f·(s+s) == s` exactly to a lone channel and `s` to every channel of a pair, so existing click output is bit-identical.
- `test_click_pan`: hard left leaves the right jack at exactly 0.

### Declick arithmetic

- `fade_out_cur` starts the fade from `ramp_n/ramp_len`, which is the gain of the frame just played, so a pause or seek during a fade-in has no step.
- A Play from Stopped at 0, the Repeat wrap and the Next continuation are unfaded and sample-exact, as the tests assert.

### Raw posts

Raw posts of 88-92 are refused in `le_engine_post_command`, and that is tested.

## Findings

### High

None in Part 1's own code.

The decoder-side High H3 in the P2 review lands here at run time: a NaN or Inf sample in a buffer permanently poisons an output-bus reverb or filter, because `backing_frame` sums whatever the buffer holds before the buses. The fix belongs in the decoder (P2 H3). If Part 1 is to defend itself, `le_backing_buffer_from_pcm` could refuse non-finite input. That is a one-pass check on the control thread, never on the audio thread.

### Medium

None.

### Low

**L1. A transient condition is reported as permanent `LE_ERR_CAPACITY`.**
- **Where:** `engine_backing.c:168-174`. The code (and the header's own definition at `segno_engine_api.h`) returns `NOT_READY` only when more than two buffers are owned.
- **Why it misfires:** the two owned buffers can themselves include one in transit. Right after a replace, the outgoing buffer is in its 5 ms fade or waiting in a dead slot, and the new one is loaded.
- **Scenario:** at 96 kHz with files over about 11.6 minutes (three buffers exceed 1.5 GiB), the owner replaces A with B and stages C for B within a few milliseconds. The stage returns `CAPACITY` ("too large") although B plus C fits once A is collected.
- **Likelihood:** low in the planned flows, where a decode of several hundred milliseconds sits between the two calls. But Part 3's retry rule ("retry once on notReady") will not retry `CAPACITY`.
- **Fix:** report `NOT_READY` whenever a dead slot is occupied or the fade voice owns a buffer. Simplest: keep a count of buffers handed to the ring or to the fade voice that have not yet come back. Alternatively, have the registry compare against the budget without the outgoing buffer when the post is a LOAD.

**L2. Two load-bearing lines have no test (mutations survived).**
- **`engine_backing.c:138`** (`e->backing_fade = {0}` in `le_backing_release`).
  - **Scenario:** Pause, then the device stops mid-fade, then a configure. Without the line, the fade voice keeps a pointer to the buffer that was just freed, and the next block reads freed memory.
  - **Fix:** add a case to `test_backing_lifetimes`: pause, process fewer than 240 frames, configure, process.
- **`engine_commands.c:4638`** (the arm-time reset of `a_perf_backing_blocks`).
  - **Scenario:** without it, a second capture after one with backing says `backing_in_master: true` although nothing was routed during it. The export would then show a false "Backing audio is in the recording" line, contrary to rule 3.
  - **Fix:** in `test_backing_marks_capture`, arm, disarm and arm again on the same engine with the backing unrouted the second time.

**L3. A build artefact is committed: `packages/segno_engine/stretch.o`.**
- It is a 67 KB Mach-O arm64 object, added in `7e28fc768`.
- Nothing references it, and `.gitignore` does not cover `*.o`.
- **Fix:** remove it and add `*.o` to the package's `.gitignore`. It carries no source and would ride every later merge.

**L4. The header has two inconsistencies.**
- The `le_engine_backing_load` doc lists `LE_ERR_NOT_READY` as "LE_BACKING_MAX_BUFFERS already owned" and omits `LE_ERR_CAPACITY`. The block comment above it states the real rule.
- The sidecar marker counts blocks while the captured bus is muted or the backing level is 0. "In the recording" then over-claims. This is harmless, but the doc could say "routed to the captured bus".

## Notes

- **The stress test is meaningful but bounded.** It races load, stage, clear, seek and transport against advances, with 1-61-frame blocks and 1-200-frame buffers. Of the voice-lifetime mutations, it is the only test that catches `drop_cur` ignoring a shared fade. It never exercises a reopen or a configure, but those are stopped-callback paths by contract and are covered by the unit tests.
- **Resuming during a pause's fade overlaps.** A Play within 5 ms of a Pause starts the loaded voice fading in from the paused position while the fade voice is still fading out from a few frames later, so a few milliseconds are briefly doubled. This is inaudible in practice.
- **A pause, stop or clear can cut an old fade abruptly.** One arriving within 5 ms of a replace ends the old fade at once (`end_fade`). That is a possible tiny click in a corner case, with no ownership impact.
- **The plan's Part 1 text is stale in places** (see the plan delta): it still mentions `engine_voice.h`, the block-end ack and "a second replace before the ack returns NOT_READY". The code and section 4.1 are the truth.
- **Hardware (owed by the plan):** audible routing and a backing in a real capture.

Verdict: Approve (L1-L4 are follow-ups; P2's H3 is the decoder's to fix).

## Delta review (6cca20754)

Model: Claude Opus (subagent), in-session

### Scope

- **The delta:** one commit on `75b7e84c7` (`6cca20754`, 109 insertions, 20 deletions).
- **What it changes:**
  - L1, the transit test that picks `NOT_READY` or `CAPACITY`:
    - a callback-side counter, `a_backing_applied`, against the control-side `backing_posted`;
    - an `a_backing_fade_owns` flag;
  - L2, tests for the fade reset at configure and for the arm-time marker reset;
  - L3, `stretch.o` removed and a `.gitignore` with `*.o` added;
  - L4, the header comments;
  - non-finite samples are now refused in `le_backing_buffer_from_pcm`. This defends against P2's H3 at the buffer boundary as well.

### Runs

**Native suite** on `6cca20754`, each configuration in its own `TMPDIR` and run two at a time:
- plain: ALL PASSED;
- ASan: ALL PASSED;
- telemetry-off: ALL PASSED;
- TSAN races only: ALL PASSED. The handoff stress test reported 18,915 accepted, 7,762 handoffs, 253 advances and no report.

**Mutations,** each applied singly in a scratch worktree on the P2 head, which contains this delta. Each was run through a backing-only ASan driver plus the race test. Every one is now caught:

| Mutation | Caught by |
|---|---|
| `le_backing_release` keeps the fade voice | ASan heap-use-after-free in the new configure-while-fading case. Not caught before |
| No reset of `a_perf_backing_blocks` at arm | The new routed-then-unrouted capture case. Not caught before |
| The transit answer forced to `CAPACITY` | The byte-budget case and the race test |
| `a_backing_fade_owns` never set | The byte-budget case |
| `le_backing_buffer_from_pcm` accepts NaN | `test_backing_buffer_and_refusals` |

### Verified correct (traced)

- **The transit rule.**
  - `in_transit` is true in two cases:
    - a buffer-carrying post the callback has not applied (`applied != posted`);
    - the fade voice owns a replaced buffer.
  - In every other state, the replaced buffer is either already in a dead slot, which `le_backing_collect` frees in the same call, or it is owned nowhere.
  - LOAD while stopped or paused returns the old buffer straight to a slot and leaves `fade_owns` at 0, which is correct.
  - CLEAR posts no buffer, so `posted` is not bumped.
  - The End = Next advance, while a seek's fade still shares the old buffer, sets `fade_owns` through `drop_cur`.
  - `le_backing_release` re-bases `posted` on `applied` when the ring is re-initialised.
- **Ordering at the end of a fade:**
  - The callback stores the buffer in its slot (release), then clears `fade_owns` (release).
  - The control side reads `fade_owns` (acquire) and then collects.
  - So a cleared flag always finds the buffer in its slot.
- **The other review items:**
  - The new tests reproduce exactly the scenarios the first review gave for L1 and L2.
  - `stretch.o` is gone, and `*.o` is ignored package-wide.
  - The comment on `le_engine_backing_load` now states both codes.
  - The sidecar comment says that a muted bus still counts.

### Findings

#### Low

**L5. A narrow window can still answer `CAPACITY` for a buffer in transit.**
- **Where:** `engine_backing.c:172-178`. The `||` evaluates `a_backing_fade_owns` before `a_backing_applied`.
- **Scenario:** the callback applies a LOAD between those two loads. It sets `fade_owns` (relaxed), then `applied++` (release). The control side then sees `fade_owns == 0` from before the apply and `applied == posted` from after it, so it answers `CAPACITY` while the old buffer is fading.
- **Likelihood:** the window is two adjacent loads, nanoseconds wide. The original L1 was 5 ms or more.
- **Fix:** read `a_backing_applied` first (acquire), then `a_backing_fade_owns`. The release on `applied++` then publishes the `fade_owns` store that precedes it.

### Notes

- Refusing non-finite samples in `le_backing_buffer_from_pcm` makes the voice safe whatever produced the buffer. That complements the decoder's own refusal (P2 delta).

Verdict: Approve.
