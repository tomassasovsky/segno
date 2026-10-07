Model: Claude Opus (subagent), in-session

# Review of PR #1246 (origin/claude/midi-clock-1228-p1 @ 69e18c403): feat(engine): add the shared native MIDI input sink with timestamps

## Scope

- The single commit `69e18c403` on top of trunk `dff0915c2`: `src/midi/le_midi_port.h` (new), `midi.c`, `midi_backend_linux.c`, `midi_backend_apple.c`, `le_midi_backend.h`, `le_midi_internal.h`, `engine.c`, `engine_commands.c`, `engine_private.h`, `engine_process.c`, `engine_snapshot.c`, `segno_engine_api.h`, the regenerated bindings, `run_native_tests.sh`, `test_midi_core.c`, `test_engine_midi_in.h` and `test_midi_sink_races.c`.
- The PR head has since moved to `5616a9bb4`, which only adds the SwiftPM forwarder `Sources/segno_engine/include/le_midi_port.h`. Nothing below depends on it.
- Checked against:
  - the MIDI clock plan at `6fc551396` (D1 and Part 1);
  - the instruments plan at origin/claude/instruments-plan-1197 `74e55eab4` (D4, its "shared sink, final layout" bullet, §2.2 and Part 2c);
  - AGENTS.md and the owner rules.
- The pen is not relevant: this part has no UI.

## Runs

All runs used `TMPDIR` directories under the scratchpad, one per run.

| Run | Result |
|---|---|
| Native suite, plain, 4 runs | 3 green. One run failed `test_fade_restore_staging_and_manifest_capacity` (`test_engine_fade.h:898`, a 5 s wait for the perf drain thread). That run shared the machine with three other suites and the sanitizer mutation builds. The test is not touched by this PR, and the fourth plain run, alone on the machine, was green. |
| Native suite, ASAN | green |
| Native suite, `-DLE_CALLBACK_TELEMETRY=0` | green |
| `NATIVE_TESTS_ONLY=races` with `-fsanitize=thread`, 3 runs | green, no TSAN warnings |
| `packages/midi_client` (`flutter test`) | 41 passed |
| `packages/midi_device_repository` (`flutter test`) | 35 passed |
| `dart analyze --fatal-infos` on segno_engine, midi_client and midi_device_repository | no issues |
| C++ shim repro (PROGRESS.md) on `engine_private.h` and `le_midi_port.h`, with and without `-U__clang__` | both compile |

**ALSA backend.** No Linux toolchain or ALSA headers are available on this Mac, and the Docker daemon is not running. `midi_backend_linux.c` was therefore read line by line against the alsa-lib API, not compiled. CI's `native-tests` and `build-linux` jobs compile it with `libasound2-dev`. On the PR head `5616a9bb4` they passed: `build-linux`, `build-linux-arm64`, and `native-tests` in its plain, ASAN, telemetry-off and TSAN variants. So the Linux build is confirmed by CI, not locally.

**Mutations.** I copied the engine sources and built a focused driver (`midi_in_driver.c`, `mutation-build.sh` and `mutations.py`, all saved beside this review). Each mutation was run against `test_engine_midi_in.h`, `test_midi_sink_races.c` and `test_midi_core.c`.

Killed:
- drain without the stale check;
- lost counted as a level;
- gap never cleared;
- destroy without detach;
- close without unbind;
- close without the lost mark;
- bind without a generation bump;
- unbind without a generation bump;
- gap mark without the +1;
- `ts_us` not divided by 1000;
- clock reaching Dart;
- no drain.

Survived:
- **Gap reported at the first popped event** (`gap != 0` in place of `index + 1u >= gap`), and **gap reported after every event**. Part 1 has no dispatch, so nothing observes where the gap lands. See L2.
- **Unbind without the quiescence wait.** It is not caught in the plain or ASAN runs (0 of 3 ASAN runs). Under TSAN it is caught 1 time in 3, as a SEGV in `le_midi_sink_push` during `test_destroy_against_producer`. The plan says it is caught by "TSAN and the destroy test", but in practice the catch is probabilistic. See L3.
- **Relaxed enter, and a relaxed leave decrement.** Neither is caught by any run, TSAN included. The plan says this, and the order is checked by reasoning below.

## Verified correct (traced)

**The Dekker handshake.** `le_midi_port.h:132-139`, `:214-240`.
- The four operations that matter are all `seq_cst`, so they sit in one total order S:
  - the producer's `fetch_add(in_flight)` and then its `load(port)`;
  - unbind's `exchange(port, NULL)` and then its `load(in_flight)`.
- **Case 1: the producer's load returns the old port p.** That load must precede the exchange in S. Otherwise it would read NULL, or a later bind's port. Then:
  - S runs `fetch_add < load(port) < exchange < load(in_flight)`;
  - the counter load cannot return a value older in modification order than the `seq_cst` increment. The only older value it could see is an earlier decrement by the same thread, and that decrement happens before the increment;
  - so unbind sees the counter at 1 or more, or it reads the producer's release decrement. Reading the decrement synchronises with it, so every ring write happens before unbind returns.
- **Case 2: the producer reads NULL.** It writes nothing.
- On arm64 this compiles to `ldaddal`/`ldar` (or `ldaxr`/`stlxr` then `ldar`), which keep the order.
- The rebind path is also ordered. The producer's `seq_cst` load of the new port synchronises with bind's `seq_cst` store, so the relaxed `s->gen` store made before it is visible.
- So the argument in the header comment is correct. Every write into engine memory sits inside the bracket: the event fields, `tail`, `a_gap` (`:149-163`) and `a_lost` (`:173-179`). The Dart ring writes go to `le_midi`'s own memory, not to engine memory.

**SPSC handoff between two producers.** When b takes a port from a (`test_sink_rebind_moves_and_evicts`):
- a's last `tail` store happens before unbind returns (quiescence);
- bind's `seq_cst` store of the port then publishes the slot to b;
- so b's relaxed load of `tail` reads a's final value. The single-producer rule holds across the handoff.

**Unbind racing a producer, and destroy.**
- `le_engine_destroy` unbinds all eight ports before tearing down the device (`engine.c:1211-1215`).
- `le_midi_destroy` closes first, and close unbinds with the lost mark (`midi.c:263`, `:279-283`). So whichever is destroyed first, the other never dereferences freed memory: `a_owner` is cleared by the CAS in unbind.
- No Dart `Finalizer` frees either handle (`midi_client_base.dart:111` and `native_audio_engine.dart:2464` are explicit), so the one-control-thread rule holds today.

**Gap arithmetic.**
- The producer stores `tail + 1` when the ring holds 255 entries.
- Events below the mark precede the loss. At most 255 of them can be queued when the mark is read, and the drain pops up to 256 per block, so it always reaches the mark in the same block.
- A loss after the consumer read the mark (later tail) survives the CAS clear (`le_midi_port_clear_gap`) and is reported in the next block.

**Real-time safety of the drain** (`engine_process.c:6354-6399`, called at `:6425`).
- Per port, it does three acquire loads and at most 256 pops of 16 bytes, then four relaxed adds per block.
- There is no allocation, no lock and no syscall. Its cost is bounded by 8 × 256.

**Parser and kinds.**
- 0xD0, 0xE0, 0xF2, 0xF8, 0xFA, 0xFB and 0xFC go only to the sink.
- Program goes only to Dart. Note and CC go to both, with `ts_us = t_ns / 1000`.
- Active Sensing, MTC, Song Select, Tune Request and Reset are ignored.
- `MidiControllerSource._parse` is untouched, and its suites pass.

**ALSA conversions, checked against alsa-lib.**
- CHANPRESS and PITCHBEND read `data.control.value`. PITCHBEND is offset by +8192, because ALSA centres it on 0.
- SONGPOS reads `data.control.value`, split into 7-bit halves.
- CLOCK, START, CONTINUE and STOP become 0xF8, 0xFA, 0xFB and 0xFC.
- PORT_EXIT and CLIENT_EXIT read `data.addr`. PORT_UNSUBSCRIBED reads `data.connect.sender`.
- `snd_seq_connect_from(seq, my_port, SND_SEQ_CLIENT_SYSTEM, SND_SEQ_PORT_SYSTEM_ANNOUNCE)` is valid on a `CAP_WRITE|SUBS_WRITE` port.
- `pthread_setschedparam(SCHED_FIFO, 70)` on the started thread reports EPERM as -1. The service grants `LimitRTPRIO=95`, and the app runs as root.
- Every symbol used is declared in an included header: `<sched.h>` and `<string.h>` for `memset`. I found no compile error.
- As I read the kernel's `snd_seq_client_notify_subscription`, it sends PORT_UNSUBSCRIBED directly to the user client that owns one end of the subscription, not to every announce subscriber. So the sender-only match should not fire for another client's subscription. I did not confirm this on hardware.

**CoreMIDI timestamps.** Host time is moved onto `CLOCK_MONOTONIC` with an offset taken at delivery (`midi_backend_apple.c:116-122`). This fixes the earlier review's L2. A future timestamp is clamped to now.

**Agreement with instruments D4 (`74e55eab4`).** The code matches the "shared sink, final layout" bullet field for field:
- the 16-byte entry;
- `_Atomic u32 a_gen`, `_Atomic i32 a_lost` and `_Atomic size_t a_gap` = tail + 1;
- the owner, `head`/`tail` and 256 entries;
- the sink as the first member, with a static assertion;
- enter, leave and unbind in the stated orders;
- the kinds;
- `le_midi_ports_drain` as the one consumer;
- attach and detach as direct calls.

## Findings

### High

None.

### Medium

**M1. The drain reports a lost port before the events queued ahead of it, and no edge marks a detach or rebind.**

Where: `engine_process.c:6358-6361` against the pop loop at `:6368-6382`; `le_midi_port.h:247` and `:257`; `engine_commands.c:3306`.

Part 1 only counts, but this loop is the dispatch skeleton that Part 2 (follower) and instruments Part 2c will fill. D1 of both plans says the loss is reported "at its exact position in the stream". Three gaps:

1. **Order.**
   - `a_lost` is read and its edge counted before any event is popped.
   - A device exit (`le_midi_input_lost`) is marked by the same reader thread after the events it read before the exit. So when both arrive between two blocks, the loss comes first.
   - Scenario (Part 2c): a Note On arrives, then the source's PORT_EXIT, within one block. The drain releases the port's voices on the lost edge, then pops the Note On. The Note On is not stale (an exit marks lost but does not bump the generation), so it plays a voice that no Note Off will ever release.
   - Scenario (Part 2): the follower goes Lost, then consumes pulses that predate the loss.
2. **Detach is silent.**
   - `le_engine_detach_midi_input` unbinds with `lost = 0` (`le_midi_port.h:247`), so the consumer sees nothing.
   - The old binding's queued events are dropped as stale, including any Note Off still in the ring.
3. **A fast rebind erases the loss.**
   - `le_midi_open` closes first (unbind, lost = 1). Dart then reattaches at once, and bind stores `a_lost = 0` (`:257`).
   - That whole sequence runs on the control thread in microseconds, so the audio thread never sees the edge. The generation moved by 2, but the drain keeps no per-port `gen_seen`, so it cannot tell.
   - Instruments D4 says "a port detach, loss or overflow releases that port's voices". The skeleton provides only the overflow at its true position.

Fix:
- Load `a_lost` (acquire) before the pop loop, but dispatch the lost edge after it. The release store in `le_midi_sink_mark_lost` follows the producer's pushes, so every event before the mark is visible to the loop.
- Keep `int32_t`/`uint32_t midi_port_gen_seen[LE_MAX_MIDI_PORTS]`. When the loaded generation differs from it, dispatch a "binding ended" edge, which covers detach and the close-then-attach sequence, and count it in the snapshot.
- Add a test seam that records the dispatch sequence, for example a test-only callback array. Then test that an event pushed before `le_midi_sink_mark_lost` is dispatched before the loss, and that close → attach within one block yields one binding edge.

### Low

**L1. The generation is read once per port before popping** (`engine_process.c:6362`).
- If the control thread binds a capture to a port while the audio thread drains it, events that the new binding pushes during that drain carry the new generation. They are dropped and counted as stale.
- Consequence: the first few messages after an attach can be lost, such as a clock pulse or a Note On. This is harmless, but it is a silent drop that `midi_in_stale` reports as if it came from an old binding.
- Fix: on a mismatch, reload `a_gen` before declaring the event stale. Generations only increase.

**L2. No test observes where the gap is reported.**
- Both position mutations survive (see Runs). Today the gap position is only proven at the ring level (`test_sink_unbound_and_overflow`).
- Fix: with the dispatch seam from M1, push 255 events, lose some, push more, and check the order: the queued events, then the gap, then the later events.

**L3. The destroy race does not reliably catch a missing quiescence wait.**
- With the wait removed, the race binary passed 3 of 3 plain runs and 3 of 3 ASAN runs, and failed 1 of 3 TSAN runs (SEGV at `le_midi_port.h:156`).
- Cause: the producer's push is a few nanoseconds long, and `le_engine_destroy` spends microseconds closing the device before `free`.
- A CI run therefore has about a one-in-three chance of catching the regression the PR describes as caught.
- Fix: add a test-only park point inside the bracket. For example, a `LE_MIDI_SINK_TEST_PARK()` macro that compiles to nothing outside `LE_NATIVE_TESTS`, placed between `enter` and the ring write. Park the producer there, call unbind on another thread, check that it has not returned after a few milliseconds, release the producer, and check that it returns. That kills the no-wait mutation every time.

**L4. ALSA input overrun drops events without a gap mark** (`midi_backend_linux.c:153`).
- `snd_seq_event_input` returns `-ENOSPC` when the client's kernel input pool overflowed. The loop ends there, and the dropped events leave no mark.
- The gap exists so that "a release is never dropped silently" (instruments H3), and this is the one drop path the sink does not see.
- The reader now runs at `SCHED_FIFO` 70, so this is unlikely, but it can happen during a SysEx flood.
- Fix: add `le_midi_sink_mark_gap` (bracketed; it stores the current `tail + 1`), and call it on `-ENOSPC`.

**L5. The CoreMIDI splitter consumes an interleaved real-time byte** (`midi_backend_apple.c:147-163`).
- An 0xF8 inside a three-byte message is taken as data: `0x90 0xF8 0x3C` becomes Note On 0x78 velocity 0x3C, and the clock pulse is skipped.
- An 0xF8 inside a SysEx is skipped by the SysEx scan.
- This affects macOS only, which is a development host. The follower's missed-pulse rule covers a single loss.
- Fix: in the data-byte scan, dispatch any byte at 0xF8 or above at once and skip over it.

**L6. Nits.**
- The header comment at `midi_backend_apple.c:9` still says the backend "feeds Note/CC bytes through le_midi_ring_push".
- Nothing pins `sizeof(le_midi_port_event) == 16`. A `_Static_assert` would keep the layout both plans cite.
- The API comment (`segno_engine_api.h`, snapshot block) says `midi_in_overflows` counts "blocks that found an overflow flag". It counts gaps.

## Notes

- **Stale backlog when the engine starts.** While the audio device is stopped, nothing drains the rings. A capture attached before `le_engine_start` fills its ring to the gap, and the first block then delivers up to 255 old timestamps. Part 2 should discard pulses older than its loss deadline, and Part 2c should not play old Note Ons. Neither plan says so yet.
- **Timestamps are taken per event at `snd_seq_event_input` return.** A batch read after a reader delay is stamped at read time, not at arrival. The plan's loaded-UI hardware criterion is the right check. ALSA queue timestamping (`snd_seq_port_info_set_timestamping` with a real-time queue) would stamp in the kernel at delivery if that criterion fails.
- **Instruments plan text.** D4's "Device loss (review L7)" bullet still says the CoreMIDI backend marks loss "from its notify callback for a removed source". Its own Part 2c and the clock plan's D1 say this is not built. This is an inconsistency between the plan texts, not between the code and the plans.
- **Unrelated test.** The flaky `test_fade_restore_staging_and_manifest_capacity` wait under heavy load is not from this PR.

Verdict: Request changes (M1 is cheap to fix now and shapes the dispatch that both consumers build on; L1-L6 are optional).

## Delta review (8c2f43d48)

### Scope

- Commit `8c2f43d48` on top of `5616a9bb4`:
  - the ordered dispatch, with REBOUND, GAP and LOST and a per-port `gen_seen`;
  - the generation reload for a binding made during a drain;
  - the dispatch test hook and order tests;
  - the park point;
  - `le_midi_sink_mark_gap` and the ALSA `-ENOSPC` gap;
  - the splitter moved into `midi.c` as `le_midi_split`;
  - the 16-byte static assertion and the comment fixes.
- **ALSA.** The `-ENOSPC` loop was read against alsa-lib and kernel behaviour. On overflow, the kernel's `snd_seq_read` clears the client FIFO and returns `-ENOSPC` once. The next nonblocking read returns `-EAGAIN`, and the loop breaks, so the `continue` cannot spin.
  - The loop structure, the includes (`ENOSPC` comes from `<errno.h>`) and the new declaration in `le_midi_backend.h` are consistent.
  - The first Linux compile of this code is CI on the stacked P2 PR #1259 at `e9e7fb509`, which contains `8c2f43d48`. That run is green: `build-linux`, `build-linux-arm64`, and `native-tests` with ASAN, TSAN and telemetry-off. #1246 itself has no run on `8c2f43d48`.

### Runs

Each run has its own `TMPDIR`.

| Run | Result |
|---|---|
| Native suite, plain × 3 | green |
| ASAN | green |
| Telemetry-off | green |
| TSAN races × 3 | green, no warnings |
| C++ shim repro on `engine_private.h`, with and without `-U__clang__` | compiles |

**Mutations.** I used a focused driver over `test_engine_midi_in.h` (built with `-DLE_NATIVE_TESTS`), `test_midi_sink_races.c` and `test_midi_core.c`.

Every mutation in this round was killed:
- gap reported at the first event (survived before; L2);
- unbind without the quiescence wait, now killed in the plain run by the park test (L3);
- no `gen_seen` edge;
- a mid-drain rebind dropped as stale (L1);
- LOST dispatched before the events (M1);
- `mark_gap` doing nothing (L4);
- the splitter dropping an interleaved real-time byte (L5);
- no stale check.

### Prior findings

| Finding | Status |
|---|---|
| M1 order and binding edges | Met: REBOUND, events with GAP in place, then LOST (`engine_process.c` drain); the order tests `1E90 1L`, `1R 1E90` and a single `1R` on detach |
| L1 generation read once | Met (reload on mismatch; `2E90 2R 2E80`) |
| L2 gap position untested | Met (`0EF8 0EF8 0G 0EFA 0EFC`) |
| L3 probabilistic quiescence test | Met (the park test is deterministic) |
| L4 ENOSPC | Met |
| L5 CoreMIDI interleaving | Met; `le_midi_split` is tested with a real-time byte inside a message and inside a SysEx, and with a cut-short message |
| L6 nits | Met |

### New findings

**DL1 (Low). A LOST read before a rebind made during the drain is dispatched after the new binding's events.**
- `is_lost` is read before the pops.
- Scenario: a capture is closed (lost = 1, generation G+1) just before the drain. The drain reads `is_lost = 1` and dispatches REBOUND. Then, while it is popping, the app attaches the reopened capture (generation G+2, lost = 0), which pushes a Note On. The drain dispatches REBOUND, the new Note On, and then LOST.
- Consequence: instruments Part 2c releases the new binding's voices, cutting the note just played.
- It needs an attach inside the microseconds of one drain, so it is unlikely.
- Fix: when a mid-drain REBOUND fires, dispatch any pending LOST of the old binding before it, or drop that LOST.

### Notes

- Truncated messages are now dropped rather than completed with zeros, which is safer than before.
- REBOUND is dispatched for the first attach (generation 0 → 1), as the dispatch-order test expects. Consumers should treat it as "start over", not as a loss.

Verdict (delta): Approve.
