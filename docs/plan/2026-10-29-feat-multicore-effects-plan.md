---
title: "Effects on more than one core"
type: feat
date: 2026-10-29
issue: 1515
---

# Effects on more than one core

<!-- cspell:words Tracktion tracktion Sushi sushi Bitwig Ardour graphnode semutils renderaheadlen jackdmp Fober Orlarey Letz Rowland nohz isolcpus irqaffinity threadirqs kthreads cyclictest futex futexes FUTEX EPERM mlock prefault pthread setstack rtirq xhci multicore parallelises makespan FPCR mlockall CPUTIME ppoll -->

Tracking: [#1515](https://github.com/tomassasovsky/segno/issues/1515),
`stage:plan`, `autonomy:plan-gate`. Branch `claude/fx-multicore-1515`, cut
from the integration trunk (`claude/segno-integration`, `14a45f3e0`). Every
`file:line` below is on that commit.

This is a plan. Merging it approves the direction; the build follows under
#1515 once the owner has answered the questions in section 10. Each question
has a recommendation, which the build takes if the owner merges without
answering. The spike in section 8 is the only code here: a bench,
`packages/segno_engine/src/test/bench/bench_fx_parallel.{c,sh}`, that is not
part of the test gate.

CPU is given as a share of the whole machine throughout: 100 % means all four
of the Pi 5's cores busy, so one core is 25 %.

## 1. The problem

Every effect runs inside the engine's one real-time callback, on one core.
The admission model gives effects 7,192 ns per frame at 96 kHz
(`packages/looper_repository/lib/src/models/fx_cost.dart:132`): the worst
block may fill 80 % of the 10,417 ns frame (`kFxBudgetShare`, `:108`), less
the engine's own 1,141 ns (73 us a 64-frame block, `kFxBaseCostUs`, `:101`).
That is 69 % of one core, **17 % of the machine**. The other three cores carry
the UI, the display and the OS. With the app idle on build .205 they sat at
0.5 %, 11.5 % and 2 % busy (sampled over 10 s on 2026-10-30; a fourth core was
busy with an unrelated `grep`), and the audio thread itself used 6 % of the
machine.

The room is already short:

- Four full Ed's Racks are charged 10,660 ns per frame and do not fit
  (#1514). On the console they run 603 us in the worst block at 96 kHz / 64
  frames: 90 % of the period. No block was late, but that is over the 80 %
  budget (coordinator bench, 2026-10-30, `/data/bench/r48/eds4.txt`).
- #1508: 15 kinds are charged less than they cost on the console, which
  takes more room away once fixed.

## 2. What the engine does today (verified)

| What | Where |
|---|---|
| The callback: drain commands, condition the input, then one loop over the block's frames | `le_engine_process`, `packages/segno_engine/src/core/engine_process.c:9652`; frame loop `:10054` |
| The conditioned input is computed for the whole block before the frame loop | `in_c`, `engine_process.c:9792-9820` |
| Instruments render the whole block before the frame loop | `le_instruments_render`, `engine_process.c:9690` |
| Per frame: the FX tempo tick, input metering, the track mix (lane chains, track chains, All tracks), the monitors, the click, the backing, the output buses, the master bus, the viz taps, then the transport advances | `engine_process.c:10054-10200` |
| Lane chain, one stereo sample a call | `fx_apply_chain`, `engine_process.c:9138` |
| Track chain (the bus of a track's lanes) | `fx_apply_chain_with_gain`, `engine_process.c:9241` |
| All tracks chain, one instance per output pair, after every track | `engine_process.c:9325` |
| Monitor chain per input, reads `in_c` and instrument sources | `mix_monitors_frame`, `engine_process.c:8139`, chain at `:8165` |
| Output bus chain per pair, over everything summed so far | `output_bus_frame`, `engine_process.c:6465`, chain at `:6474` |
| A chain's kernels are per sample and keep all state in the chain's own `le_fx_state` | `fx_apply_chain`, `engine_fx.h`; `le_fx_state`, `engine_private.h:632-755` |
| A live chain reads the engine frame through a pointer the callback advances every frame, and the engine's tempo, which the callback re-anchors every frame | `clock_src`, `tempo`, `engine_private.h:651`, `:656`; `le_fx_tempo_tick`, `engine_process.c:1055`, called at `:10056` |
| Offline renders run the same kernels on other threads with their own state, clock and tempo | wet cache, `engine_cache.c:1-50`; stems, `perf_render.c:1763-1790` |
| The kernels' shared tables (Hann window, FFT plan, cabinet banks) are built once and read-only afterwards | `engine_fx.c:42-61`, `:5285` |
| Hosted plugins are not built on Linux | `SEGNO_ENABLE_PLUGINS` off, `src/CMakeLists.txt:310` |
| Denormals are flushed per thread (FPCR.FZ on arm64) | `le_flush_denormals`, `engine_fx.h:39` |
| The callback thread is SCHED_FIFO 80, not pinned to a core | `le_alsa_set_rt_priority`, `platform/engine_linux.c:847-862` |
| The ALSA MIDI thread is SCHED_FIFO 70 | `LE_ALSA_MIDI_RT_PRIORITY`, `midi/midi_backend_linux.c:60` |
| The USB sound card's IRQ thread is raised to SCHED_FIFO 90 | `segno-rtirq`, `deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-rtirq` |
| No `isolcpus`, `nohz_full` or `irqaffinity` on the kernel command line; `threadirqs` and the performance governor only | `deploy/yocto/kas-segno-common.yml:118` |
| Audio memory is locked and fork-shielded (`MADV_DONTFORK`, `mlock2`), code is prefaulted, the callback's stack is locked | `rt_alloc.c:107-121`; `engine_linux.c:868-878` |
| A TSAN CI job runs dedicated race tests | `.github/workflows/main.yaml:548`; `src/test/test_engine_races.c` |
| `a_frames` advances once per block, after everything; the control thread frees retired chain memory only after seeing it move twice | `engine_process.c:10283`; `engine_cache.c` header, clause (c) |

On the console (read on 2026-10-30, build .205): 96 kHz, 64-frame periods, 8
periods; kernel `6.12.25-v8-16k` with PREEMPT_RT; every hardware interrupt
lands on CPU 0 (`/proc/interrupts`; the Scarlett is `xhci-hcd:usb1`, IRQ 139,
412 million interrupts, all on CPU 0) except the NVMe queues, which are spread
one per core; the threaded handlers float over all four cores.

## 3. How established engines do it

Sources are listed in section 11.

| Engine | How work is split | Who waits, and how | A late worker | Latency added |
|---|---|---|---|---|
| **Ardour** | One node per route (a track or bus with its whole processor chain). Each node counts its feeders and is queued when the count reaches zero. `max(cores - 1, 2)` process threads, SCHED_FIFO. | The backend thread posts a semaphore and blocks on another; workers sleep on a semaphore. The backend thread does no DSP. | Nothing special: the backend blocks; an overrun is an xrun. | None |
| **JUCE** `AudioProcessorGraph` | Single-threaded. | | | |
| **Tracktion Graph** | Nodes with an atomic count of unprocessed inputs, in a lock-free queue. A thread that finishes a node keeps running its single successor, so a serial chain stays on one thread. | The audio thread processes nodes too, then spins (`yield`/`pause`) for the last one. Workers spin briefly, then yield, then sleep on a semaphore (the default "lightweight semaphore hybrid"). | The audio thread keeps spinning and stealing ready nodes. | None |
| **Reaper** anticipative FX | Tracks that are not live-monitored are rendered ahead on worker threads, out of order; 200 ms ahead by default. Live-monitored inputs use a separate synchronous path. | Workers render into a buffer the audio thread reads. | The render-ahead buffer absorbs it. | The render-ahead length, on anything that changes the anticipated audio |
| **Ableton Live / Bitwig** | Independent signal paths run on separate cores; a serial path (one track's chain) runs in order on one core; the longest path limits capacity. | Not documented. | Not documented. | None |
| **Elk Audio OS: Sushi / twine** | Tracks, each pinned to one worker or assigned round-robin; plain fork-join with no dependencies between tracks. Workers SCHED_FIFO (default 75), each pinned to one core. | The audio thread posts the workers' semaphores and blocks on a condition variable until all arrive; it does no DSP. | The audio thread blocks; an overrun is an xrun. | None |
| **PipeWire** | Nodes with pending counters; a finishing node decrements its targets and wakes them through an eventfd. Several data loops can run nodes in parallel (1.2+). | The driver never waits for followers. | Reported as an xrun at the next cycle; the cycle goes on without it. | None for synchronous nodes |
| **JACK2** (jackdmp) | Clients with activation counters; the last input to finish resumes a client. | Default asynchronous mode: the server does not wait; it plays the previous cycle's output. | The client's output is missing that cycle (an xrun for that client). | One period |

What to take from them:

1. **One chain is one unit of work.** Every engine that parallelises keeps a
   serial chain on one core (Tracktion runs single successors on the same
   thread; Ableton documents it; Sushi parallelises whole tracks). A chain's
   effects cannot run in parallel with each other: each needs the previous
   one's output for the same sample.
2. **Fork-join inside the period adds no latency.** Ardour, Tracktion and
   Sushi all finish the graph inside the callback's own period.
3. **Do not put a sleep-and-wake on the critical path twice.** Ardour and
   Sushi make the audio thread sleep while workers run, so every period pays a
   wake to the workers and a wake back. Tracktion's audio thread works and
   then spins, so only the workers' wake is on the path, and that can overlap
   the audio thread's own work.
4. **Render-ahead and one-period pipelining trade latency for slack.** They
   suit a DAW playing a timeline. Section 4.3 measures what they would cost
   here.

**Adopted:** fork-join inside the period, one job per chain owner (a monitor
input, later a whole track), SCHED_FIFO workers pinned one per core, the
callback claiming jobs alongside the workers and spinning for the last one
(Tracktion), workers sleeping on a private futex between periods and woken at
the top of the period, before the callback's own serial work (so the wake
overlaps it).

**Rejected:**

- Ardour's and Sushi's blocking audio thread: two cross-core wakes per period
  on the critical path, and the callback core sits idle while it waits.
- Sushi's static round-robin assignment: equal tracks are rare here (one track
  holds a rack, another holds nothing), and work stealing balances unequal
  jobs without a placement table in the engine.
- Reaper's render-ahead, JACK2's asynchronous mode and PipeWire's
  never-wait driver: section 4.3.
- A process graph with dependency counters (Ardour, Tracktion, PipeWire): the
  engine's graph is a fixed three-stage shape (section 4.1), so two fork-join
  waves at most cover it. A general graph scheduler would be code with no
  current use.

## 4. What can run in parallel

### 4.1 The dependency graph

```
                    serial on the callback (phase A)
  commands, conditioning, instruments, transport, record, playback reads
        |                |                         |
   monitor chain c   track t: lane chains -> track chain     (one job each;
   (input c, or an   (lane l's playback, its print, its      independent of
   instrument)        gain and gates)                         each other)
        |                |
        +------+---------+
               |   serial on the callback (phase B)
    All tracks chain (one instance per output pair, over every track's sum)
    + monitors + click + backing  ->  output bus chain per pair  ->  master
```

- **Monitor chains** depend only on the conditioned input and the instrument
  buses, which are known for the whole block before the frame loop starts.
  Nothing reads a monitor chain's output except the routing sum, the
  performance capture's monitor tap and the meters. A monitor's output is
  never recorded.
- **A track's lane chains and its track chain** form one serial unit: the
  track chain's input is the sum of its lanes' chain outputs. Their input is
  the lanes' playback (or a print), with per-frame gains, gates and routing
  that the transport decides. Different tracks are independent.
- **All tracks** needs every track's routed sum, so it waits for every track
  job. Its instances (one per output pair) are independent of each other.
- **Output bus chains** need everything summed into their pair, so they come
  last. Their instances are independent of each other.
- Effects are never recorded (the lane records the conditioned input; Pre and
  Post decide only what a print covers), so no chain output feeds back into
  a recording in the same block.

### 4.2 What the per-frame loop gets in the way of

The callback runs everything frame by frame. A job that runs a chain over the
whole block on another core needs the per-frame facts the chain reads today
from shared engine state:

- **The FX clock.** Live chains read `a_fx_frame`, which the callback moves
  every frame (`engine_private.h:651`). A job must instead set its state's
  `clock` per frame, as the offline renders do (`perf_render.c:2102`).
- **The tempo.** Live chains read `e->fx_tempo`, which the callback
  re-anchors as the frame loop runs (at a loop's wrap, at a recorded loop's
  finalize). A job gets the block's anchors as a short list of `(frame,
  anchor)` events that phase A recorded, and replays them, as the stem render
  replays the tempo log (`perf_render.c:2106`).
- **Mid-block changes to a chain's view.** A print engaging at a lane's loop
  top force-bypasses its Pre slots for the rest of the block
  (`engine_process.c:9096`), and a deferred capture image re-snapshots
  lane chains mid-block (`:10085`). Phase A records these as events at
  their frame.

Monitor chains need none of the mid-block events, only the clock and the
tempo events, and their input is ready before the frame loop starts. Moving
them needs no change inside the track mix, which is why they come first
(section 9).

### 4.3 Rendering ahead (Reaper's anticipative FX)

A recorded track's playback is known ahead of time, so a track chain placed
Post could be rendered ahead on a worker. What it costs:

- **Latency on every change.** A footswitch that toggles a pedal, a parameter
  move, a Stop, a Mute, an Undo, a Reverse, a Speed change or a fade changes
  audio that was already rendered. Either the change waits out the render-ahead
  horizon H, or the horizon is thrown away and re-rendered at once. At 96 kHz /
  64 frames one block is 0.667 ms:

  | Horizon | Change latency at 96 kHz / 64 | at 48 kHz / 32 |
  |---|---|---|
  | 1 block | 0.67 ms | 0.67 ms |
  | 4 blocks | 2.7 ms | 2.7 ms |
  | 16 blocks | 10.7 ms | 10.7 ms |
  | Reaper's default, 200 ms | 200 ms | 200 ms |

  The console's round trip through the interface is 6.05 ms at 96 kHz / 64
  (581 frames, digital loopback, coordinator bench `/data/bench/r48/latency.txt`).
  Even four blocks would add 44 % to what a footswitch toggle on a track takes
  to be heard.
- **No help in the worst case.** Admission must budget the block where the
  horizon is thrown away (a Stop on every track at once), and that block runs
  synchronously. The worst block is what the admission model sizes, so
  render-ahead buys no room it can promise.
- **It already exists where it is safe.** The wet cache renders a lane's or
  a track's stable Pre stage for a whole loop on a worker and plays the print
  (`engine_cache.c`). Post chains run live because a tail must drain past a
  Stop. Extending the print to Post would print the tail problem with it.

Rejected for the live engine. One-period pipelining (JACK2's asynchronous
mode: workers render block n+1 while block n plays) has the same shape with
H = 1. It would put the track section one period behind the live inputs, so
the record offset and every latency compensation path would move. It is kept
as the fallback if the spike had shown the wake latency eating the budget;
section 8 shows it does not.

## 5. Decisions

**D1. Fork-join inside the callback's period.** Each period: the callback
wakes the workers, runs phase A, releases the period's jobs, claims jobs
itself until none is left, spins until every job is done, then runs phase B.
No latency is added anywhere.

**D2. A job is one chain owner's whole serial work for the block.** Part 1:
one monitor input's chain. Part 2: one track's lane chains and track chain
together. Part 3: one All tracks instance or one output bus chain (a second,
smaller wave). A job writes only its own output block and its own chain
states.

**D3. Work stealing, no placement table.** Jobs sit in a fixed array. Each
thread claims the next index with a compare-and-swap on a word that carries
the period's epoch and the next index together, so a thread can never claim a
job of another period or one whose inputs are not written yet. The spike
implements exactly this (`claim_jobs`, `bench_fx_parallel.c`).

**D4. Deterministic output.** Phase B adds the job outputs in job order, not
in the order they finish, so the engine's output with workers is bit-identical
to its output without them. Each job's chain sees the same clock, tempo and
events it sees today. The wet cache's and the stem render's parity with live
holds unchanged.

**D5. Workers: two, SCHED_FIFO 79, one per core, on cores 1 and 2.** The
callback is pinned to core 3, and core 0 stays with the interrupts, the UI and
the OS. 79 puts the workers below the callback (80), above the MIDI thread
(70) and the threaded IRQs (50), and below the sound card's IRQ thread (90).
The worker count is an engine setting, 0 on the desktop and in the tests,
fixed while the device runs (changing it restarts the audio engine, like a
device change). Section 10 asks the owner about a third worker.

**D6. A late worker is waited for.** There is no fallback to dry or to
silence. A job a worker has not started yet is stolen by the callback, so a
worker that never wakes costs only time. A job a worker has started cannot be
taken over (its chain state is half advanced), so the callback waits for it.
Section 6.4 explains why the fallbacks were rejected. Telemetry counts every
period whose join waited past the budget share.

**D7. Admission charges the critical path, per core (section 7).** Every
pedal is still charged whether it is on or off, so switching a pedal on is
never refused.

## 6. Real-time safety on PREEMPT_RT

### 6.1 Scheduling and placement

- Workers are created when the device opens (`le_platform_after_device_open`,
  `engine_linux.c:865`), never on the audio path, and joined after the device
  stops. A worker that cannot get SCHED_FIFO or its core (EPERM, a missing
  core) is not started; the engine reports how many workers it runs, and
  admission uses that count.
- The callback, today unpinned, is pinned to core 3, and each worker to its
  own core, so a worker never queues behind the callback or another worker.
- `segno-rtirq` also pins the sound card's IRQ thread (FIFO 90) to core 0,
  where its hardware interrupt already arrives. Unpinned, it can land on a
  worker's core and preempt a job in the middle of the period.
- No `isolcpus` or `nohz_full`. Workers sleep between periods (in the spike,
  two workers with no chains to run used 5.3 % of the machine together, all of
  it the wake and the wait for phase A), and isolation would keep the UI off
  those cores for the rest of each period. The scheduler already gives a
  SCHED_FIFO 79 thread its core over any SCHED_OTHER thread.

### 6.2 The handoff

- **Wake:** the callback bumps a 32-bit generation word and calls
  `FUTEX_WAKE_PRIVATE` once, at the top of the period, before its own phase A.
  Workers wait in `FUTEX_WAIT_PRIVATE` on that word.
- **Release:** after phase A, a release store publishes the epoch and index
  0 in the claim word (D3). Workers that woke early spin on it for at most
  phase A's length.
- **Join:** the callback spins on the done count with the `yield` hint. No
  syscall.
- **Ordering:** the release store and each job's release increment of the done
  count, paired with acquire loads, order every job's writes before phase B
  reads them, and every command applied in the next period's drain after the
  jobs' last reads. `a_frames` keeps moving only after the join, so the
  control thread's "two block boundaries" rule for freeing chain memory still
  holds: no worker can hold retired memory across a boundary.

### 6.3 Hazards, each with what the build does about it

| Hazard | Why it stalls audio | What the build does |
|---|---|---|
| **The mm lock (#710).** A page fault takes `mmap_lock`; a fork in the process holds it for write while it copies page tables. | A worker that faults waits for the fork, and the callback waits for the worker. #710 was exactly this on the callback. | Everything a job touches is engine memory that is already fork-shielded and locked (`rt_alloc.c`), or new memory allocated the same way: the job array, the job output blocks, the event lists and the futex word. |
| **A fault inside the futex call.** `futex_wait` and `futex_wake` fault the word in with `fault_in_user_writeable`, which takes `mmap_lock`. | Same as above, inside a syscall. | The word lives in locked, `MADV_DONTFORK` memory, touched before the first period. |
| **Shared futexes.** A shared futex's key is found through the page tables. | `mmap_lock` again. | Private futexes only (`FUTEX_*_PRIVATE`). |
| **The futex hash bucket lock.** On PREEMPT_RT it is a sleeping lock with priority inheritance. On 6.12 the hash table is global, so another thread whose futex hashes to the same bucket (the Dart VM uses many) can hold it. | The callback's one wake per period can wait for that holder, bounded by the lock's short hold time and boosted by inheritance. | Measured by the spike: waking two workers added 2.5 us to the callback's median period and nothing to its p99.9, and a worker was running 3 to 5 us after the wake at p99 (26 us at most) over the 885,000 periods run without the memory load (section 8). If it ever shows in part 1's telemetry, the fallback is a worker that wakes itself on a timer just before the period, so the callback makes no syscall. Spinning workers instead of sleeping ones were measured and are worse (section 8). |
| **Worker stacks.** `pthread_create` maps a stack; a fault on an untouched page takes `mmap_lock`. | A fault on the first deep call (the octaver's FFT scratch is on the stack). | Stacks are allocated with `rt_alloc` (locked, `MADV_DONTFORK`) and passed with `pthread_attr_setstack`, so they are better shielded than the callback's own stack. |
| **Code pages.** A worker running a kernel for the first time faults its code in. | A fault, and `mmap_lock`. | `le_platform_prefault_audio_code` already locks the engine's, libc's and libm's code. |
| **Allocation and locks.** | Unbounded. | None on the worker path: jobs are fixed at configure; the claim, done and generation words are atomics. |
| **Denormals.** FPCR is per thread. | A slow tail. | Each worker calls `le_flush_denormals` at start and at each wake (twine's equivalent is a no-op on ARM, section 11). |
| **Priority inversion between workers and the callback.** | The callback spins on the join while a worker's job is pending. | Workers are one priority below the callback on other cores; nothing they need is held by a lower priority. |
| **The ALSA MIDI thread and threaded IRQs.** | Preempt a worker. | Workers run above them (79 against 70 and 50). |
| **Thermal throttling.** Three busy cores heat the Pi 5 more than one. | The clock drops and every cost rises. | In the spike the SoC went from 58 to 66 °C over the 150 s soak with six racks on three cores, well below the Pi 5's 80 °C throttle point. Part 1 adds the temperature to the appliance profiler and repeats the soak for 30 minutes. |
| **Memory traffic from other cores.** The four cores share one memory bus and a 2 MB L3. | Every core's chains slow down when another core streams memory, and more so when three cores run chains at once (section 8). | Part 1 measures the slowdown with the app's own UI on core 0 and sets the per-core margin from it (section 10, risks). |

### 6.4 Why a late worker is waited for

The fallbacks the other engines use were considered:

- **Play the chain dry or silent for the late block** (PipeWire's driver
  carries on; JACK2 asynchronous plays the old output). The late worker still
  holds the chain's state. The next period's command drain may reset or
  retype that chain (`le_fx_entry_reset` and `le_fx_entry_renew` run on the
  callback), so the drain would have to skip chains whose job is still
  running. That is a new class of race, and the gap is audible either way: a
  rack dropping out for 0.67 ms clicks as hard as an xrun.
- **Run the job inline.** That works only for jobs nobody has started, and
  the callback already does it (D3).

An xrun drops the capture as well as the output, so the recording gets a gap.
The admission margin (20 % of every period) is what keeps a worker from being
late, as it keeps the callback from being late today.

## 7. Admission per core

Today (`fxBudgetNs`, `fx_cost.dart:132`):

```
base + sum(chains) <= 0.8 x frame
```

With C cores (the callback and W workers), let A and B be phase A's and phase
B's per-frame cost (together today's base, 1,141 ns at 96 kHz), J the summed
charge of the parallel jobs, p the largest single job, S the chains still on
the callback (track chains until part 2, All tracks and output chains until
part 3) and h the handoff's own per-frame cost. Any greedy claiming, in any
order, finishes the parallel section by J/C + (1 - 1/C) * p after the release
(Graham's bound for list scheduling; it holds for any order and for actual
costs at or below their charges). So:

```
A + B + S + h + J/C + (1 - 1/C) * p  <=  0.8 x frame
```

- C = 1 gives today's rule exactly (h = 0, J + S = every chain).
- The `(1 - 1/C) * p` term is Ableton's critical-path limit: one chain
  owner's work never splits across cores. No separate check is needed: since
  J >= p, the rule's left side is at least A + B + S + h + p, so any rig it
  admits already fits its largest job on one core.
- The repository computes it from the charges it already has
  (`LooperRepository.fxRoomNs`, `looper_repository.dart:8004`), grouped by
  job: per monitor input in part 1, per track in part 2. It needs the engine's
  worker count (D5) and nothing else. Which job runs where is decided at run
  time and never needs to be known in Dart.
- **Switching a pedal on is never refused:** every pedal is still charged
  whether it is on or off, and a toggle changes neither J nor p.
- h is the measured cost of the handoff (section 8), charged per block and
  spread over its frames like the base.
- `fx_cost.dart` keeps its per-kind table. #1508 replaces the table's numbers
  with the console's; this plan changes only how they are summed.

What the rule gives at 96 kHz / 64 frames with Ed's Rack at today's charge
(2,665 ns a frame) and h = 39 ns a frame (2.5 us a block, section 8). The
room is C x 8,333 ns (80 % of each core's 10,417 ns frame) less the base and h; it is
the most the effects can use when no single job is large. The racks column
applies the rule, critical path included:

| Cores (C) | Room for effects, ns a frame | Room, whole machine | Ed's Racks the rule admits | Ed's Racks the spike ran with no period over budget |
|---|---|---|---|---|
| 1 (today) | 7,192 | 17 % | 2 | 2 |
| 2 (one worker) | 15,486 | 37 % | 4 | 4 |
| 3 (two workers, D5) | 23,819 | 57 % | 6 | 6 |
| 4 (three workers) | 32,152 | 77 % | 7 | 8 |

With the spike's own measured cost of one rack (158 us a block, 2,469 ns a
frame) and base (78 us, 1,219 ns a frame) in place of the charges, the rule
predicts 2, 4, 6 and 8 racks: exactly what the spike ran. The rule is
conservative at C = 4 because Graham's bound assumes the worst order, and
work stealing over equal jobs does better.

## 8. The spike

The question: do N cores give close to N times the room for effects, with no
period over its budget and no xrun?

### 8.1 Method

`packages/segno_engine/src/test/bench/bench_fx_parallel.{c,sh}`, new in this
PR, links the real engine sources, as `bench_fx_cpu` does. Once per period,
paced to the period like a device:

1. The callback thread wakes the workers (`FUTEX_WAKE_PRIVATE`), then runs
   the engine's own work: `bench_common.h`'s playing 8-track rig with no
   effects (the console's base, 69 us median).
2. It releases the period's jobs, and it and the workers claim them through
   the epoch-and-index word (D3) until none is left.
3. It spins until every job is done.

A job is one full Ed's Rack (Dual Octaver, Wah, Compressor, Overdrive,
Amp+Cab, Chorus, Room reverb, Mode delay, EQ, all on, at `bench_fx_cpu
--racks`'s heavy settings) run for one period exactly as the engine runs a
lane's chain: `fx_apply_chain` once per frame on the job's own `le_fx_state`,
its clock set per frame as the offline renders set it, fed a harmonic bass
line so the Dual Octaver's low band works. Job i takes track i's hop-stagger
seed, as four tracks do live. This is the job Part 2 runs; Part 1's monitor
job is the same chain on a different input.

The handoff was checked under ThreadSanitizer on the Mac
(`EXTRA_CFLAGS="-fsanitize=thread -g"`, three workers): no report.

On the console, 2026-10-30 01:27 to 01:42 UTC, build .205, segno.service
stopped, 96 kHz / 64 frames (period 666.7 us, budget 533.3 us). The callback
thread is pinned to core 3 at SCHED_FIFO 70, the workers to cores 2, 1 and 0
in that order at 69 (below the app's 80, as every bench on the console runs).
`mlockall` as the engine's locked memory stands in for `rt_alloc`. Raw output:
`/data/bench/mc/spike1.txt` and `soak.txt` on the console.

### 8.2 The handoff and one rack

| Run (20 s, 30,000 periods each) | Median us | p99.9 us | Max us | Worker wake p99 / max us |
|---|---|---|---|---|
| The base alone, no workers | 69.1 | 78.0 | 192.1 | |
| The base, two workers woken, no jobs | 71.6 | 76.6 | 200.5 | 3.4 / 11.1 |
| The base and one Ed's Rack, no workers | 190.0 | 236.0 | 477.6 | |
| The same, the rack on a whole chain-host engine | 235.2 | 279.4 | 369.0 | |

- The handoff costs 2.5 us of the callback's median period: h = 39 ns a
  frame.
- One Ed's Rack adds 158 us at p99.9 (2,469 ns a frame); its charge today is
  170 us (2,665 ns). The coordinator's `bench_fx_cpu --racks` measured 143 us
  on the shared source.
- A job must be the chain alone: a whole engine per chain adds 43 us a
  block, a third of a rack.

### 8.3 The room per core count

Racks were added one at a time until a period went over the budget. Every row
below had 0 late periods and 0 page faults on every thread.

| Cores | Racks | Median us | p99.9 us | Max us | Over budget | Wake p99 / max us | Callback + workers CPU, whole machine |
|---|---|---|---|---|---|---|---|
| 1 | 2 | 337.4 | 359.5 | 468.2 | 0 | | 12.4 % |
| 1 | 3 | 467.6 | 488.6 | 590.3 | 9 | | |
| 2 | 4 | 351.0 | 369.3 | 478.1 | 0 | 3.0 / 18.4 | 25.4 % |
| 2 | 5 | 438.5 | 495.5 | 583.2 | 7 | | |
| 3 | 6 | 356.6 | 405.9 | 489.5 | 0 | 3.7 / 16.2 | 39.2 % |
| 3 | 7 | 444.0 | 499.7 | 634.5 | 8 | | |
| 4 | 8 | 374.0 | 420.1 | 519.3 | 0 | 4.9 / 15.5 | 53.9 % |
| 4 | 9 | 464.1 | 520.4 | 608.8 | 11 | | |

**N cores give N times the room: 2, 4, 6 and 8 racks.** One rack's worst
block is 5.9 % of the machine (158 us of a 667 us period on one of four cores),
so the effects that fit grow from 12 % of the machine on one core to 36 % on
three and 47 % on four. The CPU column is what the bench's threads used,
measured with `CLOCK_THREAD_CPUTIME_ID`; it includes the callback's spin on
the join and the workers' wait for phase A.

### 8.4 Soaks

| Run | Periods | Median us | p99.9 us | Max us | Over budget | Late | Wake p99 / max us |
|---|---|---|---|---|---|---|---|
| 6 racks, 3 cores, futex, 150 s | 225,000 | 358.4 | 408.0 | 608.8 | 1 | 0 | 3.8 / 23.0 |
| 6 racks, 3 cores, workers spinning instead of sleeping, 30 s | 45,000 | 354.6 | 403.3 | 878.7 | 12 | 7 | 0.3 / 357.1 |
| 6 racks, 3 cores, memory load on core 0, 60 s | 90,000 | 575.6 | 654.9 | 1217.1 | 89,734 | 36 | 20.1 / 65.4 |
| 2 racks, 1 core (today's layout), memory load on core 0, 30 s | 45,000 | 392.0 | 597.5 | 697.1 | 112 | 15 | |

The SoC went from 58 to 66 °C over the 150 s soak.

- **Sleeping workers.** One period in 225,000 went over the budget (91 % of
  the period, not late). The handoff held up over the soak.
- **Spinning workers are worse.** Two cores spent all their time spinning
  (50 % of the machine against 25 %), and a spinning worker was sometimes
  held off its core for up to 357 us, so seven periods were late. The cause
  was not isolated (the kernel's real-time throttling,
  `sched_rt_runtime_us` = 950,000 of 1,000,000, applies to a FIFO thread that
  never sleeps). Rejected.
- **Memory traffic from another core is the real limit.** The memory load is
  a thread on core 0 copying 32 MB buffers in a loop, far more traffic than
  the UI makes. It slowed three cores' chains by 61 % at the median and
  pushed nearly every period over the budget. It also slowed today's
  one-core layout by 16 % and made 15 periods late with only the two racks
  today's budget admits. This is a limit the admission model does not see
  today either. Part 1 measures the slowdown with the app's own UI (section 9)
  before the per-core margin is set.

### 8.5 What the spike does not show

- The app's own UI and display load beside the chains (the bench ran with
  segno.service stopped). Part 1's console test covers it.
- The cost of phase A and phase B once the frame loop is split (parts 1 and
  2). The bench's base stands in for both.
- ALSA's own period handling: the bench is paced by a timer, not the sound
  card. `bench_rt_faults` covers that in part 1.

## 9. Staging

Each part ships on its own, works end to end on the console, and leaves the
engine bit-identical to the part before it when the worker count is 0.

### Part 1: monitor chains on workers

The smallest step that runs effects on another core. A monitor chain's input
is known before the frame loop (section 4.1), so nothing inside the track mix
changes.

- Engine: the worker pool (D5, section 6), the job array, and the claim,
  done and generation words. The frame loop splits in two:
  - Loop A, per frame as today: the tempo tick (now also recording the
    block's tempo events), input metering, `mix_tracks_frame`, the grid and
    the click gate, the viz inputs, and the transport advance. It writes the
    tracks into `out` and keeps the few per-frame facts loop B needs (the
    click gate, the playhead, the track states, the frames the latency harness
    owns).
  - The monitor jobs: each runs its input's chain over the block into the
    monitor's output block, with its own clock and loop A's tempo events.
  - Loop B, per frame: the monitors' samples added to `out`, then the click,
    the backing, the output buses, the audition, the master bus and the viz
    taps, in today's order, so every sum into `out` happens in the same
    order and the output stays bit-identical. Routing, the capture's monitor
    tap and the meters stay on the callback.

  An engine call sets the worker count and the cores (0 by default, which
  runs the monitor jobs inline on the callback).
- App: the appliance asks for two workers; `fxRoomNs` uses section 7's rule
  with jobs per monitor input. Track and output chains stay serial (S).
- Telemetry: per worker, wake latency and job time; per period, the join's
  wait; the count of periods whose service passed the budget share. The CPU
  indicator (#1307) reports the audio cores' sum as a share of the machine.
- `segno-rtirq` pins the sound card's IRQ thread to core 0.

Acceptance and tests:

- Native: with 0, 1, 2 and 3 workers the engine's output is bit-identical
  over a scripted session (monitor chains with every kind, synced kinds over a
  loop wrap, chain edits, stomps and retypes mid-run).
- Native: a worker that is never scheduled (a test hook holds it) still lets
  every period finish, with its jobs run by the callback.
- TSAN (`test_engine_races.c`, the existing CI job): the callback with two
  workers for 10,000 periods while a control thread posts recipe edits,
  stomps and retypes to the monitor chains and the UI's snapshot poll runs.
  No report.
- Dart: `fxRoomNs` and `fxBudgetNs` with W = 0 match today's numbers; with
  W = 2, the cases of section 7's table.
- Console (`bench_rt_faults` with workers on): 0 page faults on the callback
  and the workers, 0 late periods and 0 xruns over 10 minutes of playing, with
  Ed's Racks on four inputs.

### Part 2: track chains on workers

- Engine: `mix_tracks_frame` splits into phase A (per frame: transport,
  record, playback reads, prints, gains, gates, routing masks, events), the
  track job (lane chains, pan, gain, track chain, gate, into the track's
  output block with its routing mask per frame), and the routing sum in phase
  B, in track order. The meters that read chain output move into the job and
  are published after the join.
- App: jobs per track in `fxRoomNs`; S loses the track chains.
- Tests: Part 1's set, with track chains, prints engaging and falling back,
  Stop and Mute tails, Undo and the capture-image path inside a block; the
  wet cache's and the stem render's parity tests unchanged and green.

### Part 3: the output side

All tracks instances and output bus chains as a second fork-join wave after
the track jobs. Only worth building if racks on outputs or on All tracks
become common; it is planned so that the shape of parts 1 and 2 does not
block it.

### Possible later layers (not planned)

- The input conditioning per channel (`le_cond_process_block`, already a
  block pass) as jobs in the first wave.
- A third worker on core 0 (section 10, question 1).

## 10. Risks and questions for the owner

### Questions (the build takes the recommendation if this merges unanswered)

1. **How many cores for audio?** Recommended: **two workers** (cores 1 and 2,
   the callback on 3, core 0 left to the UI and the interrupts). A third
   worker on core 0 adds a third more room (8 Ed's Racks against 6 in the
   spike) but shares the core that takes every interrupt and runs the UI's
   threads, and the spike shows another core's memory traffic is what slows
   the chains most (section 8.4). Alternative: three workers, with part 1's
   telemetry deciding.
2. **96 kHz or 48 kHz.** Not part of this plan, but it changes the numbers.
   The coordinator's bench shows four full Ed's Racks at 51 % of the period at
   48 kHz / 32 frames against 90 % at 96 kHz / 64, with the round trip 6.19
   against 6.05 ms. At 48 kHz every core has about twice the room, and the
   gains from the lower rate and from more cores multiply. Recommended: decide the rate on its own issue; this
   plan works at either rate.
3. **Which parts to build.** Recommended: build parts 1 and 2 now and part 3
   only when racks on outputs or All tracks need it.
4. **A late worker.** Recommended: wait for it (D6), never play a chain dry.
   Alternative: play a late chain silent for one block, which needs the
   command drain to skip chains still in flight.

### Risks

| Risk | Recommendation |
|---|---|
| **A missed deadline can currently kill audio (#1516).** In the app at 48 kHz / 32, four full Ed's Racks on the monitored inputs while recording four loops pushed blocks past the 667 us period, and one playback underrun left playback stuck in PREPARED with the audio thread asleep in `ppoll`, silent until a restart (reproduced twice). The bench's 51 % for the same racks understates the app's load. Workers add one more way for a block to be late (a worker preempted mid-job, section 6.4). | Part 1 ships only after #1516's recovery is fixed, so an overrun costs one glitch and not the rest of the performance. Admission keeps the 20 % margin per core, and part 1's console test plays and records with the racks on, not only the bench. |
| **Memory traffic from the other cores slows every chain** (section 8.4: a streaming copy on core 0 slowed three cores' chains by 61 % and today's one-core layout by 16 %, with late periods in both). Spreading chains over more cores adds traffic of their own. | Part 1 measures the slowdown with the app's UI at its busiest (the library, the stage with every meter moving) beside the racks, and sets the per-core budget share from it: below 80 % if the UI's traffic costs more than the margin. The same measurement tells whether today's one-core budget is already too generous, which would belong with #1508. |
| The futex bucket lock under PREEMPT_RT stalls the wake. | Not seen in the spike (the wake added 2.5 us at the median and nothing at p99.9), but the spike ran without the app's own threads. Part 1's telemetry records the wake per period; the timer-and-spin wake is the fallback (section 6.3). |
| Part 2's split of `mix_tracks_frame` is the largest change to the callback since slice 3. | Part 1 lands the pool, the handoff and the telemetry first, on the chains with the fewest per-frame facts. Part 2's tests pin bit-identity with the serial path. |
| Thermal throttling under three busy cores. | The spike's 150 s soak went from 58 to 66 °C. Part 1 adds the temperature and throttle flags to the appliance profiler and soaks for 30 minutes. |
| A rig admitted with workers no longer fits when the workers fail to start (EPERM, an older image). | The engine reports its worker count; the app shows the rig as over budget and refuses additions, as it does for a rate change, and never drops effects on its own. |

## 11. Sources

- Ardour: `libs/ardour/graph.cc`, `graphnode.cc`, `utils.cc`
  (`how_many_dsp_threads`), `libs/pbd/pthread_utils.cc`, `libs/pbd/pbd/semutils.h`,
  <https://github.com/Ardour/ardour>.
- JUCE `AudioProcessorGraph::perform`:
  <https://github.com/juce-framework/JUCE/blob/master/modules/juce_audio_processors_headless/processors/juce_AudioProcessorGraph.cpp>.
- Tracktion Graph: `tracktion_LockFreeMultiThreadedNodePlayer.{h,cpp}`,
  `tracktion_NodePlayerThreadPools.cpp`,
  <https://github.com/Tracktion/tracktion_engine/tree/develop/modules/tracktion_graph/tracktion_graph>;
  Dave Rowland on wake strategies,
  <https://forum.juce.com/t/real-time-multi-threading-in-an-audio-application/44268>
  and <https://forum.juce.com/t/adc-tracktion-graph-talk/43052>.
- Reaper: `renderaheadlen` (default 200 ms) and the multiprocessing
  settings, <https://mespotin.uber.space/Ultraschall/Reaper_Config_Variables.html>
  (third-party reference built from `reaper.ini`); Sound On Sound, July 2011,
  <https://www.soundonsound.com/techniques/running-multiple-plug-ins>.
- Ableton: "Multi-core performance in Ableton Live FAQ",
  <https://help.ableton.com/hc/en-us/articles/209067649-Multi-core-performance-in-Ableton-Live-FAQ>.
  Bitwig publishes no equivalent; its per-track behaviour is reported only by
  users.
- Elk Audio: Sushi's `audio_graph.cpp`, `audio_engine.cpp` and options,
  <https://github.com/elk-audio/sushi>; the overview,
  <https://github.com/elk-audio/elk-docs/blob/master/sushi/sushi_overview.rst>;
  twine's `WorkerPool` and its denormal setting,
  <https://github.com/elk-audio/twine>.
- PipeWire: <https://docs.pipewire.org/page_scheduling.html>,
  `src/pipewire/impl-node.c`, `context.num-data-loops` in
  <https://docs.pipewire.org/page_man_pipewire_conf_5.html>.
- JACK2: S. Letz, D. Fober, Y. Orlarey, "jackdmp: Jack server for
  multi-processor machines", LAC 2005,
  <https://archive2010.grame.fr/ressources/publications/Jackdmp-lac2005.pdf>;
  `common/JackAudioDriver.cpp`, <https://github.com/jackaudio/jack2>.
- PREEMPT_RT: rt-mutex and priority inheritance,
  <https://docs.kernel.org/locking/rt-mutex.html>; per-CPU kthreads and
  isolation, <https://docs.kernel.org/admin-guide/kernel-per-CPU-kthreads.html>;
  Pi 5 cyclictest under load (max 124 us on PREEMPT_RT),
  <https://antonio.paolillo.be/publications/workshops/ecrtsOspert2024_dewit_rtlinux_paper.pdf>.
