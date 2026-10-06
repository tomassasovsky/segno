# MIDI clock: receive, Follow Play/Stop, clock loss, per-output send and the MIDI Sync page

<!-- cspell:ignore retimed pthread timedwait condvar PITCHBEND sublabels sublabel XLSOr BFfDT gCTKx T7urI SCQt4 jRkHr jWDJD timerfd ppoll epoll pwait earlycon kworkers getty condattr setclock retime retimes SCHED RTPRIO bootfs sched seqlock seqlocked rawmidi TSAN Adriaensen PPQN termios BOTHER ttyAMA SONGPOS PGMCHANGE NOTEON NOTEOFF CHANPRESS nanosleep ABSTIME eventfd setschedparam Kaehn fkLOU yMhnp ipK6w OeIN1 PMu8D bXxAY YPTg6 nfcC2 IEttC FrsRF JQpGt Lqfa3 rmWqV dRiy6 PddSM -->

Tracking: #1228 (gap inventory E8-1 to E8-5), `autonomy:merge-gate` on every
build part.
Status: revision 2, after the plan review of PR #1236
(`claude-published-review/1228-plan-review/review.md`, request changes:
H1-H4, M1-M11, L1-L10); section 10 maps every finding to where it is met.
Part 1 (the shared MIDI input sink) is built on `claude/midi-clock-1228-p1`
(`69e18c403`).
Related: #1069 (DIN MIDI reaches the app; this plan answers its
routing question in D8 and closes it with Part 7), #1040 (multi-device MIDI
input), #1197 / PR #1204 (instruments: the shared MIDI input path, D1).
Source baseline: `origin/claude/segno-integration` at `097e1ef68`. Every
`file:line` below is on that head unless another file or branch is named.
Design sources: the 107 MB `segno-ui.pen` (group `01 CURRENT UX`), read through
the pencil MCP; `docs/handoff/segno-app/accepted-behavior.md` (AB);
`docs/design/2026-09-07-midi-sync-ux.md`, `docs/design/midi-sync-study.js`,
`docs/design/2026-09-09-timing-completion.md` and
`docs/design/2026-09-08-appliance-parity-correction.md`. The last four are
untracked files in the main checkout (`/Users/Tomas/Documents/Work/opensource/loopy/docs/design/`),
not in git.
Precedents: `2026-10-05-feat-engine-reopen-plan.md`,
`2026-10-05-feat-stem-history-replay-plan.md`,
`2026-10-06-feat-pitch-time-core-plan.md` (its Part 4a is a dependency of
Part 3b only) and the instruments plan
(`origin/claude/instruments-plan-1197:docs/plan/2026-10-06-feat-instruments-plan.md`
at `74e55eab4`, whose D4 now carries the same shared-sink layout as D1 here).

## Engine numbering (from the ledger; nothing outside this range)

| Kind | Range | Use in this plan |
|---|---|---|
| Commands | 124-131 | 124 `LE_CMD_SET_CLOCK_SYNC` (Part 2). 125-131 stay reserved to this epic. |
| Facts (perf log) | 348-351 | 348 `LE_PLOG_CLOCK_TRANSPORT` (Part 4), 349 `LE_PLOG_CLOCK_SLIP` (Part 3a), 350 `LE_PLOG_CLOCK_LOST` (Part 5). 351 reserved. |
| `LE_ERR` | -20, -21 | -20 `LE_ERR_EXTERNAL_CLOCK` (tempo is owned by an external source), -21 `LE_ERR_SYNC_LOCKED` (sync source change while capturing, armed or counting in). |

Code 48 changes twice (plan delta review PDL1). Part 2 renames
`LE_CMD_SET_CLOCK_MODE` (48) to `LE_CMD_SET_CLOCK_SEND`, a plain send switch
(D12). Part 6 retires it, and the number is never reused (the code already
has retired gaps: 18, 51, 52, 60, `segno_engine_api.h:203-520`). The events.log version bump for facts 348 and
350 takes the next free number at merge, per the ledger rule. No Session
schema bump: sync settings are appliance settings (D11).

## Accepted behaviour

- AB 7.3 (`accepted-behavior.md:510-517`): MIDI Sync shares device inventory
  with Controls. Internal or a selected external source owns tempo; local
  tempo and Tap cannot fight external clock. Waiting, Synced and Clock lost
  stay visible. Follow Play/Stop is independent and defaults Off. Start
  resets, Stop retains resume positions and safely ends capture, Continue
  resumes the stopped set, repeated Stop retains that set. Loss offers Keep
  playing at the last tempo or Stop loops; reconnect follows clock but does
  not start stopped music. Song Position is accepted only while stopped with
  no capture or queues, belongs to Sync and is not a Learn target.
- AB 7.4 (`:518-522`): Send Clock and Play/Stop per output with no echo to the
  selected clock input. Internally generated clock has a -10 to +10 ms sender
  offset with a zero reset. External relay preserves received timing. DIN Thru
  forwards physical input once, excludes its own forwarded and output traffic,
  and suspends duplicate generated or relayed DIN clock. Control filtering is
  separate from Thru.
- AB 2.12 (`:173-178`): clock loss closes measured partial material and
  cancels queued starts; playback obeys the keep/stop policy.
- AB 2.4 (`:121-128`): external clock adds no extra local count-in.
- Timing completion (`2026-09-09-timing-completion.md:82-87`): loss finishes
  active capture at detection, the partial take keeps its measured seconds and
  sparse musical window and ends stopped and playable; queued arms are
  cancelled so a reconnect cannot record. `:107-112`: Song Position is
  `value / 4` quarter notes, accepted only with Follow Play/Stop on, a stopped
  transport and no capture or queued action; Continue resumes from it, Start
  resets to zero; a playing transport refuses with a visible reason.
- Sync UX (`2026-09-07-midi-sync-ux.md:22-35`): a record request before the
  first usable clock shows Waiting for clock on its track and input sound
  cannot satisfy that wait; a pending recording survives Start; Stop cancels
  pending starts; Use internal tempo is an explicit recovery action; source
  changes are locked during recording and overdubbing; Play/Stop on an output
  requires Clock on that output; a port receiving clock cannot send it back.
  The same doc (`:15-17`) keeps time signature, count-in and fixed length
  local. Read with AB 2.4, count-in applies to local launches only and never
  to an external Start.
- Parity correction (`2026-09-08-appliance-parity-correction.md:28-47`, `:143-144`):
  1 ms offset steps, positive is later; offsets apply to generated clock
  only; Thru forwards the raw message once at its received time; generated or
  relayed sync on DIN Out is suspended while Thru is on.

### Pen screens this work must match

| Screen | Node | Part |
|---|---|---|
| 27/01 Internal tempo: tempo source row, "Segno sets the tempo" / "Other devices can follow it below.", the Tempo & click button, Send sync cards, offsets, the note "−10 ms earlier · +10 ms later. Offset adjusts sent clock, without changing loop tempo.", MIDI Thru | `fkLOU` | 9a (Internal only), 9b (source row) |
| 27/02 Waiting for clock (BPM `—`, "Start the clock on your other device.", the source's output "Receiving clock", offsets disabled with "Received sync keeps its incoming timing. Sender offsets apply with Internal tempo.") | `yMhnp` | 9b |
| 27/03 Following MIDI clock (Synced, Follow Play/Stop with "Start restarts loops. Continue resumes them.", If clock is lost) | `ipK6w` | 9b |
| 27/04 Clock lost · Keep playing ("Last tempo retained.", Use internal tempo) | `q85IK` | 9b |
| 27/05 Clock lost · Stop loops ("Loops stopped. Reconnect, then press Play.") | `OeIN1` | 9b |
| 27/06 Sync on the main view (top-bar "MIDI synced" chip) | `PMu8D` | 9c |
| PARITY Clock / Sender offset (DIN offset -7 ms) | `bXxAY` | 9a |
| PARITY Clock / DIN Thru (DIN card sublabel "MIDI In → MIDI Out", its Clock, Play/Stop and offset dimmed but keeping their values; "Segno sync on MIDI Out is paused while Thru is on.") | `YPTg6` | 9a |
| 26 MIDI controls headers and 53's four MIDI editor screens (`T7urI`, `SCQt4`, `jRkHr`, `jWDJD`): the Controls / Sync tab pair | section `rmWqV`, section 53 | 9a |
| 05/08 Tempo from MIDI clock (banner "Tempo follows MIDI clock.", Clock & sync button, slider and Tap disabled, four beat dots) | `dRiy6` (tile `nfcC2`) | 9c |
| 06/04 Length under MIDI clock (lengths stay editable and local) | `PddSM` (tile `IEttC`) | 9c |
| 06/09 Track settings under MIDI clock (per-track overrides unchanged) | `XLSOr` (tile `FrsRF`) | 9c |
| 07/07 Audio follows MIDI tempo (note "Recorded audio follows MIDI clock." under Follow tempo On) | `BFfDT` (tile `JQpGt`) | 9c |
| 51 Clock loss · Partial take preserved (track cue "Clock lost · Captured / audio kept"; no top-bar chip drawn) | `gCTKx` (tile `Lqfa3`) | 9c |

Five of the six section-27 screens (not `PMu8D`) and both PARITY Clock
screens carry the prototype footer "Timing simulation · no MIDI messages are
sent to hardware." It is not shipped (AB authority: no simulated content)
and is on the pen write-back list (section 8), with the undrawn states the
build needs. Goldens target the screen nodes, not the tiles.

## What the code does today (file:line)

### Clock send exists natively and reaches nothing

- `le_clock_mode` is a tri-state (`segno_engine_api.h:149-165`) set through
  `le_engine_set_clock_mode`, which rejects `LE_CLOCK_RECEIVE`
  (`engine_commands.c:3291-3297`); the audio-thread handler re-validates and
  drops it (`engine_process.c:3418-3428`). The reason is plain: no follower was
  ever built ("Phase E", `segno_engine_api.h:2212-2216`), and
  `LE_TEMPO_SOURCE_EXTERNAL` is reserved but unused (`:76-85`).
- Send: `le_midi_clock_advance` (`src/midi/le_midi_clock.c:19-70`) is a pure
  24-PPQN generator. It emits Start on the idle-to-active edge, Stop on the
  reverse, and ticks counted from an absolute epoch. It is called once per
  block at the end of `le_engine_process` (`engine_process.c:6882-6911`) and
  gated on `clock_mode == SEND` and Multi/Sync/Band (`:585-597`; Song and Free
  stay silent per the manual, `le_midi_clock.h:18-26`).
- Every tick of a block is pushed with no intra-block time into
  `midi_clock_ring` (`engine_private.h:105-116`, `:1834-1845`), which **has
  no consumer**: "a native test's direct le_ring_pop today"
  (`engine_private.h:106-108`; the tests pop it at `test_engine_core.c:26809`; the
  clock-mode tests span `:26792-27012`, and `test_midi_core.c:318+` holds the
  `le_midi_clock_advance` byte tests).
  `le_midi_out_send` (`src/midi/midi.c:311-318`) and the Dart
  `MidiOutClient` (`packages/midi_client/lib/src/midi_out_client.dart:11-24`)
  exist, but nothing outside the package constructs `MidiOutClient`.
- `a_clock_mode` is seeded OFF at create (`engine.c:1190`) and the generator
  reset per configure (`engine.c:760-762`). No Dart code reads or sets clock
  mode (the only "midiClock" in `lib/` is a Learn stopwatch,
  `control_cubit.dart:178-223`).

### MIDI input drops every clock message, and runs through Dart

- `le_midi_ring_push` filters out everything that is not Note, CC or Program
  before the ring (`midi.c:100-119`); the parser maps 0xF0-0xFF to
  `LE_MIDI_IGNORE` (`:87-91`). One port per handle; `le_midi_drain` calls one
  Dart callback (`:121-134`).
- ALSA: the read thread converts only NOTEON, NOTEOFF, CONTROLLER and
  PGMCHANGE (`midi_backend_linux.c:136-167`) and stamps arrival with
  `CLOCK_MONOTONIC` at read (`:49-53`, `:169`). The thread is created at
  default priority (`:246`). CoreMIDI skips every 0xF1-0xFF byte
  (`midi_backend_apple.c:125-128`) and converts packet host time
  (`:99-106`).
- Dart: `MidiControllerSource._parse` maps only 0x90/0x80/0xB0/0xC0
  (`packages/midi_client/lib/src/midi_controller_source.dart:85-101`);
  `MidiDeviceRepository` pins one device (`midi.input_device`,
  `settings_repository.dart:487-533`).
- Instruments plan D4 (`origin/claude/instruments-plan-1197` at `74e55eab4`,
  the D4 section and its "shared sink, final layout" bullet) designs the
  replacement this plan's Part 1 has built: a per-port SPSC ring inside the
  engine, fed by the OS MIDI thread through a quiescent sink, drained by the
  audio thread, with generation, lost and overflow marks; and a
  one-capture-per-device registry (its Part 4).

### Tempo, the master loop and the transport

- Tempo is an atomic with a source (`a_tempo_bpm_bits`, `a_tempo_source`).
  `LE_CMD_SET_TEMPO`, `TAP_TEMPO` and `SET_TIME_SIGNATURE` are ignored while
  `le_tempo_locked` (`engine_process.c:458-470`, `:3174-3209`): a count-in,
  or any content plus a grid, locks tempo. `RESTORE_TEMPO` needs a stopped rig (`:3160-3172`).
- Once a loop exists the loop is the grid: `sync_grid_to_loop` rounds the bar
  count to the existing tempo and never alters audio length
  (`engine_process.c:638-666`); quantize uses the loop-locked grid
  (`tempo_grid.h:80-86`, `:124-167`). Tempo is in denominator notes per
  minute (`tempo_grid.h:11-13`, `:48-50`), while MIDI clock is 24 pulses per
  quarter note. `le_loop_clock` is `{length,
  position}` in frames (`loop_clock.h:17-20`).
- The pitch/time plan's Part 4a relaxes the lock with Follow tempo on and
  retimes on a tempo change: new length `round(bars × frames_per_bar)`,
  position scaled, following tracks re-read at the new ratio, non-following
  tracks detached (`2026-10-06-feat-pitch-time-core-plan.md:585-613`). It
  names this plan as its consumer and gives a 0.5 % re-render tolerance for a
  continuously moving clock tempo (`:627-631`, `:1111`).
- Held transport: when no track plays or captures, the idle branch of
  `advance_transport_frame` parks the clock at the top and logs
  `LE_PLOG_TRANSPORT_HELD` (`engine_process.c:4820-4842`). Starting anything
  from held unparks every manually stopped track (`le_unpark_stopped`,
  `:174-189`).
- `handle_stop` on a RECORDING track finalizes it: the defining take through
  `request_master_finalize`, a later take through `finalize_new_track`, which
  rounds up to whole loops (`engine_process.c:2131-2149`). `handle_cut_sound`
  cancels every pending gesture, stops tracks through `handle_stop`, logs a
  synthetic `LE_CMD_STOP` per track, resets the count-in and clears all tails
  (`:2201-2249`; the pending-field clear `:2209-2215`, the synthetic STOP
  `:2219-2227`).
- In Sync and Band, `finalize_new_track` picks the nearest whole ratio
  through `le_sync_choose_ratio`, which "can round DOWN a take that ran long,
  truncating" (`engine_process.c:1167-1172`, `:1226`).
- Reverse built a two-head turn crossfade: the old head keeps reading for one
  seam window (`seam_xfade_frames`, about 10 ms, `engine_process.c:1029`)
  while the new head takes over (`:3265-3292`, mixed at `:5733-5742`).
- Count-in starts in `le_count_in_begin` (`engine_process.c:374`).
- Audio runs at `SCHED_FIFO` 80 on Linux (`src/platform/engine_linux.c:830-847`);
  the service grants `LimitRTPRIO=95`
  (`deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno.service:25-29`).
  `le_now_ns` is `CLOCK_MONOTONIC` (`engine_telemetry.h:146-170`).
- The negotiated playback period is published (`engine_miniaudio.c:356-357`);
  the period count is on the same `ma_device`.

### Sessions and the app

- A Session with `TempoSource.external` is rejected at decode
  (`packages/session_repository/lib/src/session_repository.dart:1256-1265`) and at
  restore (`packages/looper_repository/lib/src/looper_repository.dart:3784-3795`),
  but capture copies the live source verbatim (`lib/session/session_mapping.dart:120`).
  Saving under an external clock would write a session that cannot reopen.
- `TempoSource.external` exists in Dart and is documented unused
  (`packages/segno_engine/lib/src/engine_snapshot.dart:124-155`).
- MIDI settings: the Settings MIDI row opens `MidiControlsPage`
  (`lib/looper/view/settings_page.dart:334-337`, `lib/app/segno_navigator.dart:172-187`);
  the page is a `LoopSettingsFrame` with its own view enum
  (`lib/control/view/midi_controls/midi_controls_page.dart:53-70`, `:157-200`).
  There is no Controls / Sync tab pair.
- Loop settings: Tap is `loop_tempo_page.dart:187-192`; Audio & tempo still
  shows "not available yet" (`loop_audio_tempo_page.dart:10-12`, `:50-51`);
  `TempoCubit.setTempo` / `tapTempo` (`lib/looper/cubit/tempo_cubit.dart:20`, `:40`).
- Main view: `StageTopBar` (`lib/looper/view/stage_top_bar.dart:20-87`); the
  footer prints BPM to one decimal and `—` without a tempo
  (`stage_footer.dart:60-83`).
- Settings persistence precedent for one atomic, confirmed envelope with a
  restored checkpoint on refusal: `saveMidiConfiguration`
  (`settings_repository.dart:535-591`).
- Session open restores tempo through
  `_requireSessionSetting(_engine.restoreTempo(...))`
  (`looper_repository.dart:4007-4009`), which throws on any non-OK result;
  the device-restart replay `_replayRig` repeats `restoreTempo` and ignores
  the result (`:2548-2550`).

### DIN MIDI on the appliance

- The console board's DIN sockets are wired to the Pi's UART0 (GPIO14/15).
  Bench-proven 48/48 bytes in both directions at 31250 baud through
  `/dev/ttyAMA0` with raw `termios2` and `BOTHER`
  (`hardware/bench/midi_din_test.py:12-13`, `:56-105`; the both-directions
  result in `docs/research/2026-09-05-din-midi-bench.md`; #1007).
- The image enables UART3 for the pedal link with
  `RPI_EXTRA_CONFIG:append = "\ndtoverlay=uart3-pi5..."`
  (`deploy/yocto/kas-segno-rpi5.yml:132-137`, #984), and overlays reach the
  boot slot through `segno-bootfs` (`deploy/yocto/meta-segno/recipes-core/bootfs/segno-bootfs.bb:1-11`).
  #1069's "no overlays directory" predates #984; UART0 is still not enabled.
- Nothing routes the UART into the app: the app's MIDI input is ALSA only
  (#1069 §2). The pedal link already owns `/dev/ttyAMA3`
  (`packages/pedal_repository/lib/src/uart_pedal_link.dart:10`) with its own
  Dart transport (`uart_pedal_io.dart:15-83`).
- Console: the kernel command line is `console=tty3`
  (`deploy/yocto/kas-segno-common.yml:111`); `serial-getty@ttyS0` is masked
  for a boot hang (`segno-bundle.bb:337-340`); nothing pins the firmware's
  serial alias or rules out a getty or `earlycon` on `ttyAMA0`. The app runs
  as root (`segno.service` has no `User=`).

## 1. Decisions

### D1. One MIDI input path: the shared sink (built in Part 1)

Clock never passes through Dart: the `NativeCallable.listener` hop adds an
event-loop wait that depends on UI load, and a 24-PPQN clock at 300 BPM has
an 8.3 ms pulse period. The instruments plan and this plan use one sink
(rule 4), now built (`claude/midi-clock-1228-p1`, `src/midi/le_midi_port.h`)
and written identically into the instruments plan's D4 (review M8):

- **Ring entry, 16 bytes**: `le_midi_port_event {u64 t_ns; u32 gen; u8
  status, data1, data2, reserved}`. `t_ns` is `CLOCK_MONOTONIC` at arrival,
  the base of `le_now_ns`; `gen` is the port generation it was pushed under.
- **Port** (`le_midi_port`, engine-owned, `LE_MAX_MIDI_PORTS = 8`): `a_gen`
  (bumped by every bind and unbind), `a_lost`, `a_gap` (0, or the ring tail
  at the latest loss plus one, moved forward by the producer and cleared by
  the consumer once its head has passed it), the owning sink, SPSC
  `head`/`tail`, 256 entries.
- **Sink** (`le_midi_sink {port, gen, in_flight}`) is the first member of
  `struct le_midi`, pinned by a static assertion, so the engine binds a
  capture by casting `le_midi*` and never links an OS MIDI backend.
- **Quiescence (instruments review H2, delta D5).** Every producer write into
  engine memory sits between `le_midi_sink_enter` (a `seq_cst` increment of
  the in-flight counter, then a `seq_cst` load of the port) and
  `le_midi_sink_leave` (a release decrement). Unbind is a `seq_cst` exchange
  of the port to NULL, then `seq_cst` loads of the counter until zero: a
  Dekker handshake neither side can miss on arm64. The ring push and the lost
  mark are bracketed today; **the relay rings (D7) and the DIN Thru ring (D8)
  are written inside the same bracket**, never outside it, and the Part 6
  and 7 race tests extend Part 1's.
- **Kinds.** The sink carries Note On/Off, CC, channel pressure, pitch bend,
  Song Position (0xF2), Timing Clock, Start, Continue and Stop. The Dart ring
  keeps Note, CC and Program only, so Learn never sees clock (AB 7.3: Song
  Position is not a Learn target) and `_parse` is unchanged.
- **One consumer.** `le_midi_ports_drain`, run right after the command drain
  (`engine_process.c`, before `le_engine_process`), is the only code that
  clears a gap or observes a lost or generation edge. It calls
  `le_midi_port_dispatch` per port in stream order (PR #1246 review M1,
  built): REBOUND when the generation moved since the last drain (a detach,
  a rebind, or a close followed at once by an attach), then the current
  binding's events with GAP at its exact position (and REBOUND again at the
  first event of a binding made during the drain, review L1), then LOST,
  which is read before the pops but dispatched after them so the events
  read before the device went away come first. Stale events are dropped and
  counted. A loss read at the start of a drain belongs to the binding that
  was current then: when the binding changes in the same drain, LOST is
  dispatched just before that REBOUND, never after the new binding's events
  (PR #1246 review DL1, built in Part 2). Instruments release a port's
  voices on GAP, LOST and REBOUND. The clock follower counts pulses across a
  GAP. On LOST, and on REBOUND of the source port (the app closing the
  vanished capture, or another capture taking the port), a Synced follower
  goes Lost with the event and the loss counted, and a Lost follower stays
  Lost with its last tempo and readout; only the acquisition in progress
  restarts, so no fit spans two bindings (plan delta review PDM2, PR #1259
  review M2; AB 7.3 keeps Clock lost visible). An ALSA input overrun
  (`-ENOSPC`) marks a gap through `le_midi_sink_mark_gap`, inside the
  bracket (review L4).
- **Backlog at engine start** (PR #1246 review note). While the device is
  stopped nothing drains the rings, so the first block can deliver up to 255
  old messages. The clock follower drops pulses, and Start, Continue and
  Stop bytes, older than its loss deadline (built in Part 2; PR #1259 review
  L4: an old Stop would otherwise turn a later loss into Waiting);
  instruments Part 2c must not sound old Note Ons.
- **API**: `le_engine_attach_midi_input(e, m, port)` and
  `le_engine_detach_midi_input(e, port)`, direct calls (generations make a
  rebind safe without an audio-thread acknowledgement), and
  `le_midi_priority_state(m)`. `le_midi_close` detaches first (generation
  bump, lost mark); `le_engine_destroy` detaches every port first.
- **Threads and timestamps.** ALSA stamps `CLOCK_MONOTONIC` at
  `snd_seq_event_input` return and runs its reader at `SCHED_FIFO` 70, below
  the audio callback's 80 (`engine_linux.c:838`); a refusal is reported by
  `le_midi_priority_state`. CoreMIDI converts packet host time onto
  `CLOCK_MONOTONIC` with an offset taken at delivery, because macOS
  `CLOCK_MONOTONIC` keeps counting through sleep and `mach_absolute_time`
  does not (review L2); macOS is a development host only. The ALSA reader
  marks its port lost on the source's PORT_EXIT, CLIENT_EXIT or
  PORT_UNSUBSCRIBED (it subscribes to the announce port for this). The
  CoreMIDI removed-source notification is not built: CoreMIDI calls notify
  callbacks on the creating thread's run loop, which the Dart thread does not
  run; the 2 s Dart poll covers macOS.
- **What the priority does not cover** (review M7): before the reader, bytes
  pass the PL011 receive FIFO (its timeout interrupt fires about 32 bit
  periods, roughly 1 ms, after the last byte at 31250 baud), the tty flip
  buffer, or for USB the rawmidi work feeding the sequencer, on
  normal-priority kworkers. The hardware criteria therefore measure interval
  jitter with the UI loaded (Parts 1, 2 and 7), not idle; the follower (D3)
  is tuned to sources far coarser than that.

### D2. The follower runs on the audio thread, against a monotonic time base

The audio thread owns the transport, so it owns the follower: start, stop,
loss and phase decisions must not race a second thread. At block start it
reads `t_block = e->now_ns()` (default `le_now_ns`; a test hook
`le_engine_set_time_source_for_test` substitutes a fake clock), dispatches
the source port's pulses from `le_midi_ports_drain`, and places each on the
frame timeline as `frame(t) = frame_clock - (t_block - t) × sr / 1e9`. The
drain delay (at most a block plus the reader's wake) is removed exactly by
the timestamp. The telemetry note against clock reads inside
`le_engine_process` (`engine_miniaudio.c:35-44`) concerns its gap detector
mixing test and device timelines; the follower reads the substitutable
`now_ns`, so the native harness keeps one timeline.

The follower is a pure-value module, `src/midi/le_clock_follow.{h,c}`, in the
shape of `le_midi_clock.h` (no atomics, no allocation): the engine and the
unit tests drive the same function with the same inputs.

### D3. Tempo estimate, jitter filtering, units and missed pulses

Established practice for filtering timestamped periodic events is a
second-order delay-locked loop (F. Adriaensen, "Using a DLL to filter time",
LAC 2005), the filter JACK uses for its period timing. The first review's
probe showed the DLL is sound and the first draft's re-acquisition rule was
not (M1); the second delta review showed the median-of-six seed was not
either on block-edge sources (PDM1, PR #1259 review M1). The rules below are
built in Part 2 and measured by its native tests
(`src/test/test_clock_follow.h`, the review's jitter models, seeded, and the
review's `p2acq` / `p2drop` / `p2edge` probes as oracles). Over 60 s at 90,
120, 124.9 and 174 BPM, fed in 128-frame blocks:

| Source model | Re-acquisitions | Synced after | Seed error at Synced (200 start phases) | Max tempo error after 5 s | Readout changes after 5 s | Pulse count |
|---|---|---|---|---|---|---|
| uniform random ±1 ms | 0 | 1-2 beats (25-45 pulses) | — | 0.032 BPM | 0 | exact |
| 1 ms USB-frame quantization | 0 | 1-2 beats (25-51 pulses) | — | 0.021 BPM | 0 | exact |
| clean | 0 | 1 beat (25 pulses) | 0 | 0.000 BPM | 0 | exact |
| pulses at 512-frame / 44.1 kHz block edges | 0 | 1.7 beats (90) to 4 beats (174), 0.9-1.4 s | ≤ 0.15 BPM (was up to 41.3) | 0.047 BPM | 0 | exact |
| block edges plus 0.5 ms noise | 0 | as above | — | 0.056 BPM | 0 | exact |
| step 120 → 100 (each model) | 1 | — | — | settles in 0.20-0.43 s; 0.057 BPM after 4 s | 0 | exact (block edges: was one short) |
| step 120 → 60, 150 → 50, 174 → 87, 60 → 120 (each model) | 1 | — | — | settles in 0.12-2.25 s; 0.054 BPM after 4 s | 0 | exact |
| one unmarked dropped pulse, 200 positions, block edges at 90 / 120 / 174 | 0 | — | — | 0.53 BPM in the 20 beats after | — | exact at every position (was wrong in 43 / 82 / 200) |
| a 4 ms bus stall over four pulses | 0 | — | — | under 0.03 BPM | 0 | exact |
| a DAW accelerando 120 → 130 over 8 s | 0-2 | — | — | trails by about 1.4-1.5 BPM during it; within 0.1 BPM 1.4 s after it ends | — | exact |

- **Units (review H2).** MIDI clock is 24 pulses per quarter note; the
  engine's tempo is denominator notes per minute (`tempo_grid.h:11-13`). The
  engine tempo is `60e9 / (24·P) × ts_den / 4`: in 6/8 a 120 quarter-note
  clock is 240 BPM in Segno's unit, as the tempo page and the footer already
  read for 6/8. Every tempo Segno shows, the Sync page included, is in that
  unit (rule 4: one tempo unit). The valid interval window is the engine's
  30-300 clamp converted to quarter-note pulse periods with the same
  `ts_den / 4` factor, ±2 %. Song Position (sixteenth notes) and the beat
  pulse convert through quarter-note frames (`le_grid_div_frames(...,
  LE_GRID_DIV_QUARTER)`), never through the beat unit.
- **Acquisition (PDM1).** A least-squares line through the pulse times
  seeds the period and phase: the span of the timestamps, not a median of
  intervals, so a source that stamps pulses on audio-block edges (intervals
  of one or two blocks, never the period) is seeded correctly. Waiting
  becomes Synced once the fitted tempo's standard error is under 0.15 BPM,
  after at least one beat of intervals and at most four. One beat, not six
  intervals: six equal block-edge intervals can alias 100 BPM to 107.67 with
  no residual to warn of it. A fit whose newest half has a slope more than
  three of its own standard errors from the whole fit spans a tempo change
  and is cut back to that half. Once the line spans a beat, a pulse it puts
  whole periods late counts the pulses dropped before it; before that, and
  for a stray early pulse, pulses are taken in order.
- **Tracking.** Per pulse, `e = t_pulse - t_pred`, `t_pred += P + b·e`,
  `P += c·e`, with `ω = 2π·B·P`, `b = √2·ω`, `c = ω²`, `B = 0.2 Hz`. The
  least-squares seed is within 0.15 BPM, so no 0.5 Hz opening phase is
  needed (it moved a block-edge estimate by 0.2 BPM for seconds after
  Synced).
- **Jitter estimate.** `σ²` is an exponential mean of `e²` over about 48
  pulses, updated only by errors within the outlier bar, so a tempo ramp or
  a step cannot inflate it.
- **Runs: drops or steps (PDM1).** An outlier is `|e| > max(2 ms, 2.5σ)`.
  A run is the errors of one sign beyond `max(2 ms, σ)`; it is judged once
  its last six average past the outlier bar (an average, because block-edge
  jitter is a sawtooth that dips under any single bar every few pulses). A
  line fitted freely through the run's times either keeps the old period
  and sits whole periods late, which is pulses dropped without a mark (count
  them, keep the period, put the phase back on the old line), or has a
  slope more than four standard errors from the old period, which is a
  tempo step (re-fit a line over the run and the pulses that follow, as at
  acquisition, counting by index). Between the two the run keeps
  collecting, since a longer run has a smaller error. The hidden pulses may fall anywhere in the run
  (a run can open with a pulse that was merely late before the drop).
- **Missed pulses (review M2) and integer divisions (delta review DH1).**
  Once Synced, an isolated interval counts `k ≥ 2` pulses when it is within
  0.25 P of a whole multiple, the previous pulse was not an outlier and
  `σ < P/6`; the DLL then advances `k-1` periods before taking the error.
  That is a dropped 0xF8 on USB or a DIN framing error. Two such intervals
  in a row are not drops but a master that moved to half, a third (...) of
  its tempo: the first interval's extra count is taken back and the period
  is re-fitted from the two intervals. A step's re-fit also takes back a
  whole-multiple count made just before its run (that interval was the
  step's first). Where `σ ≥ P/6` (block-edge sources) a drop is left to the
  run rule above. A ring or OS loss is known exactly from the port's gap mark
  (D1) and counts what it hid. Two pulses with one timestamp (one packet,
  one read) are two pulses (PR #1259 review L2); the second of them, right
  after an interval counted as a missed pulse, is that pulse delivered late
  and is not counted again. The pulse count therefore stays exact for
  anchors, Song Position and the beat pulse.
- **Tempo writes.** With an empty rig the follower writes its tempo as the
  session tempo once per beat, starting one beat after Synced or after a
  step's re-fit hands back to the loop, never the seed itself (PR #1259
  review M1: a block-edge seed was written as 107.67 for a 120 clock). With
  content the tempo is locked (D6 of the tempo grid) and only the readout
  follows (Part 3b retimes).
- **Published values.** The engine tempo is the unrounded DLL value. The
  display value is rounded to 0.1 BPM and moves once the estimate is more
  than max(0.08 BPM, 2.5 σ) from it, where σ is the estimate's own wander
  over the last eight beats (delta review DL1). 0.08 is the 0.05 rounding
  half-step plus 0.03, so a steady source shows the right tenth (a fixed
  0.15 left a 126.0 clock reading 125.9); the σ term (wander around a
  one-beat mean, over eight beats) holds a block-edge source still (2-3
  flips a minute before, at most one settling change after). A rounded value
  that differs from the readout for a whole beat is shown anyway, so a wide
  band never leaves the readout on a wrong tenth and a ramp is shown within
  two seconds of its end. A re-seed after a tempo step shows the new value at
  once. The Sync
  page prints whole values without a decimal ("120", as `ipK6w` draws) and
  a fractional tempo with one decimal ("124.9"); the footer keeps its one
  decimal (review M11).
- **Loss.** No pulse for `max(6·P, 250 ms)` while Synced, or the port's lost
  edge, or the end of the source port's binding (D1), is Clock lost. It is
  decided at the deadline: a pulse that arrives in the same block as the
  check, after the deadline, still reports the loss and starts acquisition
  again (PR #1259 review L1). After a received Stop (0xFC), silence is Waiting, not
  loss (the prototype's `intentionalStop`, `midi-sync-study.js:59`).

### D4. Phase: anchors, receive latency, drift and real tempo changes

- **Anchors.**
  - Follow Play/Stop On: the first Timing Clock after Start is the downbeat
    (MIDI 1.0). Continue resumes from the received Song Position, or from
    where Stop left the stopped set.
  - Follow Play/Stop Off: the external bar is unknown (the UX doc: the pulse
    "does not claim bar alignment", `:11-13`), so the local transport start
    anchors at the interpolated pulse phase of that frame.
  - **Re-anchor (review M3).** Every transition into Synced that is not a
    Start or Continue (after Waiting, Lost, or a master that stopped sending
    while stopped) re-anchors at the current interpolated phase, keeping the
    existing offset; only a Start or Continue (Follow On) moves the anchor
    to the master's bar. Drift correction never chases a phase error carried
    across a gap.
- **Receive latency (review M10).** Segno's audio leaves the converter
  `L_out` after the block that renders it (`L_out` = negotiated playback
  period × periods / rate, the same value D7 uses). A Start whose downbeat
  pulse is `d` frames in the past at block start sets the shared clock to
  position `d + L_out` (Continue: the resume position plus that), so
  Segno's output, not its block, lands on the master's downbeat. What
  remains is the MIDI transport and the codec delay the driver does not
  report; Part 3's hardware run reports it as a constant offset.
- **Takes armed for an external Start (review L6).** A capture begins at the
  downbeat frame. Its first `d` frames (at most one block plus the reader's
  wake, under 1 ms on the appliance) are silent: the engine keeps no input
  history to write them from. Stated, not hidden.
- **Drift: a slip at the master wrap (review H1).** Crystals tens of ppm
  apart drift a loop by milliseconds per minute. At each master wrap the
  follower compares the wrap frame with the frame the anchor's pulse count
  says the bar line falls on. When `|φ| ≥ 2` frames it moves the shared
  position by `φ` (clamped to ±2 ms per wrap) under Reverse's two-head turn
  crossfade (`engine_process.c:3265-3292`): the old head keeps reading for one
  seam window while the new head starts at the corrected position. No track
  is resampled, so following, Follow-Off and detached tracks all stay on the
  shared position, nothing changes `len_src` or `play_len`, and Overdub
  stays available. Slips are deferred while any track records, overdubs, is
  armed or counts in (a skipped or repeated region would drop or double
  input); the accumulated error is worked off, clamped per wrap, from the
  first wrap after the capture ends. The bound is the crystal error times
  the capture length: 50 ppm over a three-minute overdub is 9 ms. Free and
  Song have no shared position and get no slips. A track detached by the
  owner decision below reads its private counter: slips do not move it, so
  it drifts by the crystal error until its next Stop/Play re-attaches it
  (delta review DM1.4). That is the decision's intent: it keeps its
  recorded speed.
- **Slip target (delta review DM3).** φ is measured against the loop's own
  phase offset to the external grid, captured when the defining take
  starts (the interpolated pulse phase of that frame), not against the
  external bar line. A take pressed 1.5 beats into a bar keeps that offset
  for ever; slips only remove drift. Start, Continue and Song Position
  (Follow On) set the offset to the master's bar, as D4's anchors say.
- **Slips are logged (delta review DM2).** Every slip pushes
  `LE_PLOG_CLOCK_SLIP` (349) `{frame, φ}`, and `perf_render.c` applies it
  through the same turn crossfade as `LE_PLOG_REVERSE`'s turn
  (`perf_log_ring.h:182`), so a stem rendered from a performance with slips
  matches what was heard.
- **Real tempo changes.** When the DLL tempo differs from the session tempo
  by more than 0.05 BPM (about 400 ppm at 120, ten times any crystal error)
  for a whole beat, and the rig has content, the follower requests pitch/time
  Part 4a's retime, the single owner of length rescaling (rule 4). 4a refuses
  a retime while a track captures, is armed or counts in
  (`pitch-time-core-plan.md:391-394`, `:603-604`): the request then waits,
  the session keeps its tempo and click until the capture ends, and the page
  shows "Tempo change waits for the take to finish." With no content the
  follower writes the tempo directly (`LE_TEMPO_SOURCE_EXTERNAL`). Before 4a
  exists (Part 3b not built) a real change with content holds the session
  tempo and the page says "Loops keep 120 BPM; the clock is at 124." (rule 3:
  no silent divergence).
- **Defining take under an external clock.** A loop that is not a whole
  number of bars at the master's tempo cannot stay in time with it; a
  human-timed take is typically 0.5 % off, far more than slips correct. So
  under an external source an Auto defining take's end is queued to the next
  whole bar counted from the take's own start at the external tempo (delta
  review DM3: not the external bar line, which a take pressed mid-bar never
  meets), the precedent of AB 2.8 ("finish queues the end of a whole primary
  cycle"), through the existing auto-finalize target
  (`length_preset_target_frames`, `engine_process.c:704-735`). Nothing is
  truncated: the take records up to that point. Fixed lengths stay local
  (UX doc `:15-17`).
- **Follow tempo Off (owner decision, 2026-10-06, decided).** Slips keep
  Follow-Off tracks phase-locked through crystal drift. On a real master
  tempo change, the song tempo (shared clock, click, quantize grid) follows
  the master, and each track's Follow tempo decides: a following track is
  retimed; a track with Follow tempo Off keeps its recorded speed (AB 2.6)
  and detaches from the shared position until its next Stop/Play,
  pitch/time 4a's rule (`pitch-time-core-plan.md:606-613`). Nothing is
  refused. The 07/07 page under Follow tempo Off says "Keeps its recorded
  speed. The MIDI clock changed the song tempo." once that has happened.
- **The global Follow tempo value under a clock (delta review DM1.2).** 4a
  ships the global default Off until 4b, and with it Off `le_tempo_locked`
  still locks a rig with content, so 4a's own tempo setter cannot retime.
  The follower does not go through that setter: Part 3b calls 4a's retime
  entry directly, which the external source owns, and the global value acts
  only as each track's inherited Follow tempo. With the global value Off,
  a real master tempo change therefore retimes the shared clock and every
  inheriting track detaches at its recorded speed, the owner's decision
  applied to every track.
- **Detach notice (plan delta review PDL2).** The 07/07 line is on a settings
  page, so the first real master tempo change that detaches a track shows a
  toast on the main view: "Loops keep their recorded speed; the clock
  changed the tempo." Once per source selection: a toast, not a banner, as
  nothing needs doing (the popup-severity rule). The engine counts detaches
  in `clock_detaches` (section 2); the app shows the toast when it moves
  from zero.

### D5. Recording when clock is lost mid-take

At detection, on the audio thread, in this order:

1. Every RECORDING or OVERDUBBING track ends as a Stop would, keeping all
   measured audio (AB 2.12, review M6). In Multi the defining take finalizes
   through `request_master_finalize` and a later take through
   `finalize_new_track`, which keeps the material at its musical position
   and pads the lap with silence (AB 2.7). In Sync and Band,
   `le_sync_choose_ratio` can round a take down (`engine_process.c:1167-1172`),
   so a loss finalize passes a round-up flag that picks the next whole ratio
   above the captured length. Past the largest ratio (4×) or the loop
   capacity there is no ratio to round up to (delta review DL3): the take is
   finalized at that limit, as a performer's Stop already does today, the
   frames beyond it are counted in `LE_PLOG_CLOCK_LOST`, and a notice says
   "Clock lost: the take ran past 4 times the timing track and its end was
   cut." (rule 5) until the held take of E4-5 can keep them. The take ends STOPPED and playable
   (timing completion `:82-85`) and contains the audio up to the detection
   frame; trimming back to the last pulse would remove measured frames, so
   it is not done.
2. Every pending arm, sound arm, quantized punch, the launch cohort and the
   count-in are cancelled by the pending-gesture loop `handle_cut_sound`
   uses (`:2209-2215`, with `le_count_in_reset`), extracted into
   `le_cancel_pending_gestures` and called by both (rule 4). Tails are not
   cleared: this is a stop, not a cut.
3. Keep playing: playing tracks continue at the last DLL tempo, slips off,
   state Clock lost ("Last tempo retained.", `q85IK`). Stop loops: every
   playing track goes through `handle_stop` with a synthetic `LE_CMD_STOP`
   in the perf log (the Cut precedent, `:2219-2227`), positions retained as
   for a received Stop (D9), state Clock lost ("Loops stopped. Reconnect,
   then press Play.", `OeIN1`).
4. `LE_PLOG_CLOCK_LOST` (350) records the policy and the detection frame.

Reconnect re-acquires (Waiting, then Synced, re-anchored per D4) and starts
nothing: arms were cancelled and a stopped set waits for Continue or a
press (AB 7.3). Use internal tempo (`q85IK`) is `LE_CMD_SET_CLOCK_SYNC` with
the internal source: the tempo stays at the last estimate with source
MANUAL. A failed-publication held take (E4-5) is not built yet; when it is,
clock loss feeds it the same way a Stop does.

### D6. Echo prevention

- **No send to the source.** A port's identity is its backend id: the ALSA
  client name (the id both enumerations use, `midi_backend_linux.c:82`,
  `:312`), the CoreMIDI endpoint id, and `din:<path>` for serial (D8). An
  output whose id equals the selected source's id is never sent clock or
  transport, natively enforced in the scheduler (D7); the page shows
  "Receiving clock" with its switches disabled (`yMhnp`).
- **Relay excludes the source** for the same reason.
- **Thru is physical-only.** DIN Thru forwards bytes read from the UART's RX;
  generated and relayed sync never go to DIN Out while Thru is on (AB 7.4,
  `YPTg6`).
- **Internal source ignores incoming clock** entirely.
- **ALSA identity is coarse (review L10, pre-existing).** The id is the
  client name and `le_alsa_find_source` takes the first matching port, so a
  two-port interface exposes only its first port, echo exclusion covers all
  of a client's ports (safe, blunt), and two identical devices collide.
  This plan does not change device identity; #1040 owns it.
- An external cable loop between two devices is invisible to the app; it is
  on the page note and the hardware list, not detected.

### D7. Sending: one scheduler thread, the first clock is the downbeat

The C1 generator decides ticks per block, has no intra-block time and no
consumer, and emits its first 0xF8 one pulse after Start (`le_midi_clock.c:30-33`;
the review's probe confirmed it), which D4's own receive rule reads as a bar
one pulse late (20.8 ms at 120 BPM, outside the ±10 ms offset, review H3).
Sending becomes one native MIDI-out scheduler per engine
(`src/midi/le_clock_send.{h,c}`, pure due-time computation, plus the thread
in `midi_out_sched.c`), the single writer of every attached output:

- **Downbeat.** Tick 0 is the downbeat and is due at the Start frame; Start
  (0xFA) is due 1 ms before it, as MIDI 1.0 recommends. Tick `k` is due `k`
  pulse periods after tick 0. A Segno receiving a Segno therefore lands on
  the same musical frame (a loopback oracle in Part 6).
- **Anchor (review M5, M4, L7).** The audio thread publishes per block a
  seqlocked anchor whose payload fields are relaxed atomics with acquire and
  release fences: `{seq, t_block_filtered, active, ticks_at_block_start (a
  fraction), frames_per_tick, sr}`. The tick phase comes from the shared
  clock's musical position (quarter-note frames through
  `le_grid_div_frames(..., LE_GRID_DIV_QUARTER)`), not from frames since
  Start, so a retime or a slip keeps sent ticks on the loop's beats.
  `t_block_filtered` is the callback time passed through a DLL against the
  frame count, the JACK practice, so callback wake jitter does not reach the
  due times.
- **Due times.** Tick `k` is due at
  `t_block_filtered + ((k - ticks_at_block_start) × frames_per_tick / sr) × 1e9 + L_out + offset_port`,
  `L_out` as in D4, `offset_port` −10..+10 ms in 1 ms steps, positive later.
  The user offset absorbs what the driver does not report (AB 7.1: buffer
  time is not measured latency).
- **Lookahead.** The scheduler extrapolates from the latest anchor up to a
  12 ms horizon, so a negative offset sends a tick before its frame is
  rendered. A tempo change, slip or Stop rebases the ticks not yet sent;
  sent ticks stand. Start and the first ticks that are already due when the
  audio thread reveals the Start (offset more negative than `-L_out`) go out
  at once; every later tick is on time.
- **Offset edits (review L8)** apply at the next Start, or slew while running
  by at most 1 ms per beat, so a change never bursts or reorders ticks.
- **Continue (review L5).** Generated sync never sends Continue: Segno's own
  transport restarts from the top. Relay forwards what it receives.
- **Wake (review M4), portable.** Linux: the thread blocks in `ppoll` on an
  `eventfd` (written by the relay and Thru producers inside the sink bracket,
  D1) and an absolute `timerfd` set to the next due time, at
  `SCHED_FIFO` 70. Darwin (development host): a condition variable with
  `pthread_cond_timedwait_relative_np`, signalled by the same producers.
  Windows builds compile the scheduler out and report sending unavailable
  (the shipping target is the appliance). On PREEMPT_RT the wake latency is
  tens of microseconds, under USB-MIDI's 1 ms frame and DIN's 320 µs per byte.
- **Why not the OS schedulers.** ALSA queues and CoreMIDI timestamps can
  schedule events, but the serial DIN port (D8) has none, and two timing
  paths would need two measurements.
- **Relay.** With an external source, the source's reader pushes the
  real-time bytes it receives into a per-output SPSC relay ring inside the
  sink bracket and signals the scheduler, which sends them at once with no
  offset (AB 7.4; offsets are disabled in the page, `yMhnp`).
- **Per-output switches.** Clock and Play/Stop per output; Play/Stop requires
  Clock. With Play/Stop off an output gets ticks only while the transport
  runs. Song and Free stay silent (rule 1, the manual's gate,
  `le_midi_clock.h:18-26`).
- **Retired.** `midi_clock_ring`, its storage and overrun counter, the
  per-block push (`engine_process.c:6882-6911`) and the byte output of
  `le_midi_clock_advance`, whose tests (`test_midi_core.c:318+`) move to the
  scheduler's.

### D8. DIN reaches the app as a native serial MIDI port (answers #1069 §2)

#1069 lists three options: a kernel bridge, a userspace bridge, or reading the
UART directly. Reading it directly in the native MIDI layer wins:

- It is the only option that keeps D1's single input path and D7's single
  writer, with timestamps taken at `read()` on an RT thread.
- `termios2` with `BOTHER` at 31250 is proven on this exact UART
  (`midi_din_test.py:56-105`).
- A Dart bridge (the pedal link's shape) would put clock through the UI
  isolate; a kernel rawmidi bridge needs a driver this plan could not confirm
  for the Pi 5's RP1 UART.

`src/midi/midi_backend_serial.c` (Linux) opens the path set by a module-level
`le_midi_set_serial_port(const char* path)` (review M7: enumeration and open
are engine-independent, so the path is not engine config). The Dart
`MidiDeviceRepository` calls it once at start on the appliance
(`isAppliance()`) with `/dev/ttyAMA0`; desktop builds never call it and list
no serial port. It parses with running status, SysEx skipping and interleaved
real-time, reads at `SCHED_FIFO` 70, and pushes complete messages through
the sink. It enumerates as input "MIDI In" and output "MIDI Out" with id
`din:/dev/ttyAMA0` (the pen's names, `fkLOU`); `le_midi_open` dispatches
`din:` ids to it, so Controls, Learn and instruments see DIN like any device.

Thru: the reader copies raw RX bytes into DIN's Thru ring inside the sink
bracket and signals the scheduler, DIN Out's only writer. Raw bytes keep
SysEx and real-time interleaving intact (parity correction `:144`).

Image (review M7, L4): `dtoverlay=uart0-pi5` appended beside UART3 at
`kas-segno-rpi5.yml:137`. The app runs as root (`segno.service` has no
`User=`), as the pedal link on `ttyAMA3` already does, so no udev rule.
UART0 must carry nothing else: the image keeps `console=tty3`, Part 7 masks
`serial-getty@ttyAMA0`, pins the firmware serial alias away from UART0, and
adds no `earlycon`; Part 7's hardware checks prove `/proc/consoles` has no
`ttyAMA0` and that a MIDI monitor on DIN OUT sees no byte from power-on to
the app's start.

### D9. Follow Play/Stop semantics

Native, applied on the audio thread only when Follow Play/Stop is On and the
source is external:

- **Start**: every capture in progress first ends as a Stop would (D5 step
  1), then every recorded track (not EMPTY) plays from the top at the
  downbeat (D4), mute preserved (the `le_unpark_stopped` rule); a pending
  record arm survives and fires at that downbeat (UX doc `:22-23`); a local
  count-in is cancelled and adds nothing (AB 2.4). The resume set and any
  held position are cleared. That Start restarts tracks the performer had
  stopped by hand is this plan's reading of "Start restarts recorded tracks"
  (UX doc), recorded as decision 9.
- **Stop**: every capture ends as a Stop would; every playing track stops;
  the set that was playing becomes the resume set; the shared clock and
  Free/Song private clocks keep their positions (the idle park at
  `engine_process.c:4834-4841` is skipped while a resume position is held).
  Pending starts are cancelled (UX doc `:22-23`). A repeated Stop leaves the
  set as it is.
- **Continue**: captures end first, as for Start; the resume set plays from
  the held position (or the Song Position), plus `d + L_out` (D4). A track
  detached by the owner decision (D4) that was in the resume set re-attaches
  on Continue exactly as on a local Play (4a's re-attach at Stop/Play): it
  plays from the shared held position at its recorded speed (delta review
  DL4).
- **Song Position**: accepted only while stopped with no capture, arm,
  count-in or queued action: it replaces the held position, converted
  through quarter-note frames (`value / 4` quarter notes, D3 units) and
  folded into the loop. Otherwise it is refused, counted in the snapshot,
  and the page shows "Song Position ignored while playing" as a toast (the
  popup severity rule: low stakes).
- **Local presses** while a resume position is held: a local Play or Record
  clears the held position and resume set and behaves as today. Follow
  Play/Stop Off: Start, Stop and Continue are only relayed; Song Position is
  ignored.
- `LE_PLOG_CLOCK_TRANSPORT` (348) records each applied Start, Stop and
  Continue with the resume mask and position; `perf_render` replays it so a
  stem renders the resumed phase (the `LE_PLOG_SOURCE_TRANSPORT` precedent,
  `perf_log_ring.h:147`).

### D10. Waiting for clock, and the beat pulse

With an external source not Synced, a record press on an empty track becomes
an arm with trigger `CLOCK` (cue "Waiting for clock" on its track, UX doc
`:29-30`); a Sound start cannot fire it. Follow On: it fires at the next
Start's downbeat. Follow Off: it fires at the Synced edge, which is also the
anchor (D4); with no external bar there is no earlier boundary to wait for
(review L9). Stop and clock loss cancel it (D5, D9).

The tempo page's four beat dots (`dRiy6`) come from the grid's
`a_current_beat` when Follow Off (no external bar exists) and from the pulse
count since the downbeat when Follow On (review L9).

### D11. Settings, sessions, engine lifetimes and ownership

- Sync settings are appliance settings (AB 7: "Appliance settings and
  external sync"): source id and name, Follow Play/Stop, loss policy,
  per-output `{clock, playStop, offsetMs}`, and Thru, in one envelope
  `midi.sync`, saved with exact-bytes confirmation and a restored checkpoint
  (the `saveMidiConfiguration` precedent, `settings_repository.dart:535-591`).
  A failed write keeps the previous settings and shows "Could not save. The
  previous setting is retained." (prototype copy, on the write-back list).
- Defaults preserve today (rule 1): Internal, Follow Play/Stop Off, Keep
  playing, every output Clock Off, Thru Off. Nothing sends clock today, so
  nothing starts sending after the update.
- A saved source that is absent at boot stays selected and reads Waiting with
  "Reconnect the selected device." (`midi-sync-study.js` body); an unreadable
  envelope falls back to the defaults with a notice (rule 5).
- **Saving.** Capture maps `TempoSource.external` to MANUAL at the current
  estimate rounded to 0.01 BPM (`session_mapping.dart:120`), so a session
  saved under clock reopens (today it would be rejected,
  `session_repository.dart:1261`).
- **Opening under an external source (review H4).** Session open applies the
  loop's bars, length and signature but skips `restoreTempo` while the
  source is external, and shows once "Tempo follows MIDI clock. The session's
  saved 96.00 BPM was not applied." (a toast). With content and Follow tempo
  On, D4's real-tempo-change path then retimes to the master once nothing
  captures. `_replayRig`'s `restoreTempo` (`looper_repository.dart:2548-2550`)
  follows the same rule. The engine keeps refusing `restore_tempo` under an
  external source (-20), so one owner decides.
- **Engine lifetimes (review M9).** Every engine start, reopen and device
  change replays the sync vector, every input attachment and every output
  attachment from the repository's remembered state, in `_replayRig`
  beside the tempo replay (`looper_repository.dart:2493-2556`, the
  `_intendRunning` precedent). The page never reads "Synced via USB" while
  the engine is on Internal.
- `LE_ERR_EXTERNAL_CLOCK` (-20): `set_tempo`, `tap_tempo` and
  `restore_tempo` with a non-NONE source are refused while the source is
  external, at the call and again in the callback. The Loop settings tempo
  page shows the clock variant instead (`dRiy6`), so the refusal is a
  guard, not a user path.
- `LE_ERR_SYNC_LOCKED` (-21): changing the source while any track records,
  overdubs, is armed or counting in ("Finish recording to change source.",
  prototype copy, on the write-back list).

### D12. The clock-mode tri-state goes

`le_clock_mode`, `le_engine_set_clock_mode`, `LE_CMD_SET_CLOCK_MODE` (48),
`a_clock_mode`, `le_snapshot.clock_mode` and their Dart bindings are removed
(AGENTS.md: no compatibility layers). Their roles split: the source is
`LE_CMD_SET_CLOCK_SYNC` (receive), sending is per output in the scheduler.
The send gate keeps Multi/Sync/Band and "transport active" (rule 1).
As built in Part 2: receive left the tri-state, and the send half stays a
plain switch (`le_engine_set_clock_send`, code 48 renamed
`LE_CMD_SET_CLOCK_SEND`, `le_snapshot.clock_send`) that also closes under
an external source, so the engine's C1 send tests keep running until Part 6
replaces the switch and the ring with the per-output table and retires
code 48.

## 2. Native model

- The shared sink (D1), built: `le_engine.midi_ports[8]`, the drain, the
  snapshot totals `midi_in_events`, `midi_in_stale`, `midi_in_overflows`,
  `midi_in_lost` and `midi_in_attached_mask`.
- `le_engine.clock_sync` (audio thread): source port and generation, follow,
  loss policy, receipt sequence (`LE_CMD_SET_CLOCK_SYNC` payload, one
  complete vector like `LE_CMD_SET_RECORD_TIMING`); the `le_clock_follow`
  state; the anchor; the deferred slip; the pending real-tempo request;
  `resume_mask`, `held_position`, held free-clock positions.
- Snapshot (appended): `clock_source_port`, `clock_state` (0 internal,
  1 waiting, 2 synced, 3 lost), `clock_bpm_display`, `clock_beat`,
  `clock_follow`, `clock_loss_policy`, `clock_receipt`, `clock_resume_mask`,
  `clock_spp_refused`, `clock_losses`, `clock_tempo_held` (D4's waiting or
  pre-4a held state), `clock_detaches` (tracks detached by a real master
  tempo change since the source was selected, D4), `clock_send_late_ticks`, `midi_thru_overruns`.
- Outputs: `le_engine_attach_midi_out(engine, slot, le_midi_out*, id)` and
  `detach`, with the same enter/leave quiescence as inputs (the scheduler is
  the producer that must leave before a detach returns); a two-slot output
  table `{clock, play_stop, offset_ms}` per slot plus the `thru` flag,
  published by the control thread and read by the scheduler.

## 3. Dart model

- `segno_engine`: a `ClockSync` role interface on `AudioEngine`
  (`setClockSync`, `setClockOutputs`, `attachMidiOutput`/`detach`), snapshot
  projection `ClockSyncSnapshot`, the mock. Attaching and detaching the
  clock source's capture uses the `MidiInputSink` role that instruments
  Part 3a adds to `AudioEngine` (`attachMidiInput(MidiCaptureHandle,
  port:)`, `detachMidiInput(port)`; `claude/instruments-1197-p3a`), not a
  second pair on `ClockSync` (rule 4: one Dart seam for the one native sink).
- `MidiDeviceRepository` (the instruments Part 4 registry): the clock source
  becomes a capture consumer next to the control device and instrument
  devices; outputs with Clock on, and DIN Out while Thru is on, are opened as
  `MidiOutClient`s and attached. It sets the serial path on the appliance
  (D8). Disconnected outputs stay configured with their state visible
  (UX doc `:34-35`).
- `SettingsRepository`: `loadMidiSync` / `saveMidiSync` (`midi.sync`).
- `LooperRepository`: applies the envelope with a receipt, replays it per
  engine lifetime (D11), maps -20 and -21, applies the session-open rule
  (D11), and projects clock state into `TransportSnapshot`.
- `MidiSyncCubit` (`lib/control/cubit/midi_sync_cubit.dart`): one owner of
  the page draft (offset edit with encoder draft, commit and Back cancel, the
  zero reset), write failures, and the toasts.
- `TempoCubit` gains nothing: tempo and Tap are not offered under clock.

## 4. Parts

Production line counts exclude tests, generated bindings and docs. Every
native part runs the normal, ASAN and telemetry-off suites, each in its own
`TMPDIR`; parts with threads also run the TSAN races binary.

### Part 1. The shared MIDI input sink (built: PR #1246, `claude/midi-clock-1228-p1` at `8c2f43d48`)

Review fixes (PR #1246 review, `8c2f43d48`): the ordered dispatch with
REBOUND and a per-port `gen_seen` (M1), the generation reload for a binding
made during the drain (L1), a native-test dispatch hook with order oracles
(L2), a park point that makes the quiescence test deterministic (L3), the
ALSA `-ENOSPC` gap mark (L4), the shared byte splitter `le_midi_split` that
keeps interleaved real-time bytes (L5), the 16-byte static assertion and
comment fixes (L6). The SwiftPM `include/` forwarder for `le_midi_port.h`
was added in `5616a9bb4`.

Built as D1 describes: `src/midi/le_midi_port.h` (port, sink, enter/leave,
push, lost mark, gap mark, pop, bind/unbind); `midi.c` with the sink as the
first member of `le_midi`, `le_midi_input` (sink, then the Dart ring), the
new parser kinds (pressure, bend, Song Position, Clock, Start, Continue,
Stop), `le_midi_close` detaching first, `le_midi_priority_state`; ALSA
conversions of CHANPRESS, PITCHBEND, SONGPOS, CLOCK, START, CONTINUE, STOP,
the announce subscription and lost mark, `CLOCK_MONOTONIC` ns stamps and the
`SCHED_FIFO` 70 reader; CoreMIDI real-time and Song Position splitting with
host time moved onto `CLOCK_MONOTONIC`; engine `midi_ports[8]`,
`le_engine_attach_midi_input` / `detach` (in `engine_commands.c`, no
commands), detach-all in `le_engine_destroy`, `le_midi_ports_drain` after the
command drain, and the snapshot totals.

Tests: `test_midi_core.c` (parser kinds incl. Song Position 16 and 16383;
0xF8 at `1_000_000_000` ns reaches the port with that stamp and generation 1
and never Dart; Note On reaches both with `t_ns` and `ts_us = t_ns/1000`;
Program reaches only Dart; 300 pushes keep 255 and mark the gap at 256; a
second loss moves the mark from 512 to 513 and a stale clear keeps it;
close detaches, bumps the generation to 2 and marks lost; rebind, move and
evict), `test_engine_midi_in.h` (attach masks, three events drained in one
block, stale events after a reattach dropped and counted, one overflow per
gap, lost counted per edge, destroy detaches), and
`test_midi_sink_races.c` in the races job (a producer pushing and marking
lost, an audio thread running `le_engine_process`, and 100 000 attaches,
re-attaches, moves and detaches with exact accounting
`events + stale == successful pushes`; 2 000 create/attach/destroy cycles
against a live producer). Mutations each fail a test: close without unbind,
clock reaching Dart, no gap mark, no timestamp, bind without a generation
bump, drain without the stale check, destroy without detach, no drain, lost
counted as a level, and unbind without the quiescence wait (TSAN and the
destroy test abort). The memory-order mutation (relaxed enter) is not caught
by TSAN, which does not model weak ordering; the order is fixed by review.

```success-criteria
GOAL: Every MIDI input backend delivers notes, controls, clock, transport and Song Position with a monotonic timestamp into an engine port ring through one quiescent sink shared with instruments, while Learn and controls see exactly what they see today.
SUCCESS CRITERIA:
- The parser, sink, gap, generation and close oracles above pass; Note/CC/Program reach Dart unchanged. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- ASAN and telemetry-off suites pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Attach, move, detach and destroy race a producer and the audio thread without a data race and with exact accounting. | verify: NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings regenerate and format; analysis is clean; the C++ shim repro (PROGRESS.md) passes with and without `-U__clang__`; symbol parity holds in CI. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart) && dart analyze --fatal-infos lib test packages
- HARDWARE: on the appliance with the UI under load, a USB clock source's pulse-interval error has p99 under 1.5 ms, logged by a test build; the ALSA reader reports real-time priority granted. | verify: manual, appliance; record p50/p99 and `le_midi_priority_state` in the PR.
NON-GOALS:
- The follower, note routing (instruments 2c), DIN serial (Part 7), Dart.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2. Clock follower, source command and tempo ownership (built: `claude/midi-clock-1228-p2`, stacked on Part 1)

As built, with three departures from the text below: the anchor and its
re-anchor rule moved to Part 3a, the first part that uses an anchor; "no
count-in for external starts" moved to Part 4, where external starts exist;
and the send switch stays as D12 now describes. The follower's pulse count
(`clock_pulses`) is in place for both. Built after the delta review: the
integer-division rule (DH1) with the 120 → 60, 150 → 50 and 174 → 87
oracles on all four source models, the readout band and one-beat hold
(DL1) with glide and ramp lag oracles, the follower fed from the ordered
dispatch (GAP, LOST and REBOUND of the source port), and the backlog filter
for pulses older than the loss deadline.

Built after the PR #1259 review (M1, M2, L1-L4, and PR #1246 DL1): the
least-squares acquisition with the one-beat minimum and the kink cut, the
single 0.2 Hz loop seeded from the fit's line, the run classifier for drops and
steps, tempo writes from a beat after Synced, REBOUND as a loss, the loss
decided at the deadline, equal timestamps counted, the backlog filter for
transport bytes, LOST dispatched before a same-drain REBOUND, and tests for
the four guards the review found untested (the callback restore and tap
refusals, the armed and pending part of -21, no tempo write over a rig with
content).

`le_clock_follow.{h,c}` (D3: units, acquisition, the DLL, jitter
estimate, step rule, missed pulses, display, loss), the time-source hook
(D2), dispatch from `le_midi_ports_drain`, `LE_CMD_SET_CLOCK_SYNC` (124) with
receipt and `LE_ERR_SYNC_LOCKED` (-21), states, re-anchor on every Synced
edge (D4), the out-of-range reason, snapshot fields, empty-rig tempo writes
with `LE_TEMPO_SOURCE_EXTERNAL`, `LE_ERR_EXTERNAL_CLOCK` (-20) on
set/tap/restore tempo, no count-in for external starts (`le_count_in_begin`,
`engine_process.c:374`), internal source ignoring incoming clock, D12's
removals (the clock-mode tests at `test_engine_core.c:26792-27012` move to
the new gate).

Tests (`src/test/test_clock_follow.h`; jitter from a seeded generator, the
probe's models): uniform ±1 ms at 90/120/124.9/174 BPM: no re-acquisition,
error under 0.06 BPM after 5 s; USB 1 ms quantization: under 0.04 BPM;
512-frame / 44.1 kHz block edges with and without 0.5 ms noise: no
re-acquisition, under 0.25 BPM; a step 120 → 100: one re-acquisition, within
0.1 BPM in under 1.5 s, seeded at 25 ms ± 0.5 ms; one dropped pulse: the
pulse count stays exact; 6/8 with a 120 quarter-note clock: engine tempo
240.00; 6/8 with a 160 clock: out of range, Waiting with the reason; an
interval of 90 ms resets acquisition at 120 BPM; 250 ms of silence while
Synced is Lost at the first block past the deadline, but after 0xFC it is
Waiting; a lost edge is Lost at once; Waiting → Synced re-anchors with the
offset kept; set tempo returns -20 under external and applies under
internal; a source change while recording returns -21. Added for the PR
#1259 review: the seed at Synced within 0.2 BPM over 200 start phases on
block edges at 90, 100, 120, 124.9 and 174 BPM; an unmarked dropped pulse
counted at each of 200 positions on block edges at 90, 120 and 174, with
no re-acquisition; tempo steps 120 → 100, 100 → 120, 174 → 140, 90 → 93
and 120 → 126 on block edges keep the count over 50 phases; the session
tempo unchanged at Synced and written a beat later; a loss at the deadline
when the late pulse shares the block, and Waiting instead after a Stop; two
pulses with one stamp counted twice in acquisition and tracking; a rebind
of a Synced source is LOST with the loss counted and the tempo kept, and a
close after a device loss stays LOST with one loss; an old Stop in the
backlog leaves a later silence Lost; raw RESTORE_TEMPO and two raw taps
change nothing under external; an arm or a pending start returns -21; a
rig with a loop at 120 under a 126 clock keeps 120 and shows 126; LOST
before REBOUND in a same-drain rebind.

```success-criteria
GOAL: Selecting an external MIDI source makes it own the session tempo, in Segno's denominator-note unit, through a filtered estimate that is stable on real-world sources, with visible Waiting, Synced and Clock lost states, and local tempo and Tap refused while it does.
SUCCESS CRITERIA:
- The follower meets the jitter, step, dropped-pulse, 6/8, out-of-range, loss and re-anchor oracles above. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Tempo ownership: -20 for tempo/tap/restore under external, -21 for a source change while capturing, armed or counting in; external starts add no count-in; internal ignores clock bytes. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The clock-mode tri-state is gone from header, engine, bindings and Dart; sanitizer and telemetry-off suites pass. | verify: ! grep -rn "le_clock_mode\|a_clock_mode\|set_clock_mode\|setClockMode" packages/segno_engine/src/core packages/segno_engine/lib && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: against a hardware drum machine and a DAW at 90, 120 and 174 BPM over USB, with the UI under load, the displayed tempo matches the master (in Segno's unit) and does not change over a minute. | verify: manual, appliance; record master, display and settle time per tempo.
NON-GOALS:
- Drift (Part 3a), real tempo changes with content (3b), Follow Play/Stop (4), loss of captures (5), sending, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3a. Phase lock without resampling: anchor, receive latency, slips and whole-bar takes (about 400 production lines)

D4's anchors with `d + L_out`, the take-start phase offset, the per-wrap slip
under the Reverse turn crossfade with its ±2 ms clamp and capture deferral,
`LE_PLOG_CLOCK_SLIP` (349) and its `perf_render.c` replay, the whole-bar end
for an Auto defining take, the held state before 3b.

Tests (`test_clock_follow.h`): Multi, 4 bars at 120 BPM, sr 48000
(`clock.length = 384000`, 8 s), source 50 ppm fast (19.2 frames per lap):
every wrap slips 19 or 20 frames; the bar-line error after each slip is at
most 2 frames and never exceeds 21 frames within a lap; over 600 s the slips
total 1440 ± 75 frames. An overdub over three laps defers them; the first
wrap after it slips 58 frames. A sine loop through a slip has no step larger
than the turn crossfade allows (the Reverse precedent's oracle). A Follow-Off
track and a following track keep the same shared position. A Start pulse
96 frames before block start with `L_out` 256 frames puts the clock at 352.
An Auto defining take under clock at 120 BPM stopped at frame 380000 ends at
384000; stopped at 390000, at 480000. A take started 1.5 beats (36000
frames) after an external bar line, 4 bars long: slips keep the 36000-frame
offset and never pull it toward the bar line, and its Auto end is whole
bars from its own start. A stem render over three slipped laps equals the
live output sample for sample. A real tempo change with content and no 3b
sets `clock_tempo_held` and leaves the tempo alone.

```success-criteria
GOAL: Under an external clock the shared loop stays phase-locked to the master through crystal drift, without resampling, with Overdub available and every track on the shared position.
SUCCESS CRITERIA:
- The slip, deferral, crossfade, Start-latency and whole-bar oracles above pass. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- No `len_src`/`play_len` change and no retime results from slips; every slip is logged as fact 349 and a stem render over three slipped laps matches the live output exactly. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: 10 minutes against a hardware drum machine over USB and over DIN; a two-track recording of both shows a constant offset (reported) with drift within 2 ms. | verify: manual, appliance + interface recording; attach the onset plot.
NON-GOALS:
- Real master tempo changes with content (3b), Follow Play/Stop, sending.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3b. Real master tempo changes through pitch/time 4a (about 150 production lines; needs pitch/time Part 4a)

D4's real-change rule: the 0.05 BPM for one beat threshold, the request to
4a's retime, waiting while a track captures, is armed or counts in, the
"Tempo change waits for the take to finish." state, removal of the held
state once 4a exists, the `clock_detaches` count for the detach notice.

**Ramps keep following (plan delta review note).** During a DAW accelerando
the estimate trails the master: at 1.25 BPM/s (120 → 130 over 8 s) by about
1.4 BPM, settling within 0.1 BPM 1.4 s after the ramp ends (Part 2's
measurement, D3 table). The threshold therefore fires during a ramp, and
3b keeps following instead of making one retime at the end: a loop held at
120 for eight seconds while the master reaches 130 would drift half a beat
out. Retimes are limited to one per bar, each to the current estimate, and
each re-places the shared position from the anchor's pulse count under the
turn crossfade, unclamped, so the phase error the lag builds (about 1.2 %
of the tempo, some 20 ms per bar at 120) is removed at every retime instead
of being worked off by 2 ms slips. The last retime lands when the estimate
settles after the ramp. Oracle: the 8 s accelerando with content gives one
retime per bar during it and one after it, and the bar-line error after the
ramp is under 2 ms.

Tests: content at 120, master steps to 124: one retime after one beat; slips
continue at the new tempo; with an overdub running the retime waits and
lands at the overdub's end; a 0.01 BPM change is left to slips (no retime).
The owner decision (delta review DM1.3): a Follow-Off track on a 120 → 124
change keeps `rate = speed_global` and its `len_src` lap on its private
counter while a following track is retimed; it re-attaches at its next
Stop/Play; with the global Follow tempo Off, every inheriting track
detaches, the shared clock still retimes and `clock_detaches` moves once
per track.

```success-criteria
GOAL: A real tempo change on the master retimes the loops through the single retime owner, never during a capture.
SUCCESS CRITERIA:
- The step, capture-wait and threshold oracles pass, and the Follow-Off, re-attach and global-Off oracles of the owner decision. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: a DAW tempo change from 120 to 100 while loops play; the loops follow within two beats. | verify: manual, appliance + DAW.
NON-GOALS:
- Anything 3a covers.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 4. Follow Play/Stop and Song Position (about 450 production lines)

D9 complete, with the units of D3 and the latency of D4.

Tests (`test_clock_follow.h`): Multi, 8 bars at 120 BPM, sr 48000
(`clock.length = 768000`). Tracks 1 and 3 playing, 2 stopped by hand. Stop at
position 300000: 1 and 3 STOPPED, resume mask `0b101`, held 300000 for any
number of blocks; a second Stop keeps `0b101`. Continue: 1 and 3 play from
300000 + d + `L_out`, 2 stays stopped. Song Position 16 while stopped: held
96000 (one 4/4 bar); in 6/8 Song Position 12 holds 72000 (one 6/8 bar);
while playing: unchanged and `clock_spp_refused == 1`. Start: tracks 1-3
from the downbeat; an arm on 4 records from the same frame; a count-in in
progress is cancelled. Start while track 2 overdubs: the pass closes, then
the restart. A local Play while held clears the mask. Follow Off: 0xFA/0xFC
change nothing. A stem render reproduces a Continue's phase byte for byte.

```success-criteria
GOAL: With Follow Play/Stop on, an external Start, Stop, Continue and Song Position drive Segno's loops exactly as accepted, in any meter, and a performance capture replays them.
SUCCESS CRITERIA:
- The transport oracles above pass (resume mask 0b101, held 300000, SPP 16 -> 96000 and 6/8 SPP 12 -> 72000, refusal counted, Start and Continue close captures first). | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Follow Off ignores transport bytes; local presses clear the held position; renderer parity for a Continue mid-loop. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: a DAW's Start, Stop, Continue and locate-then-Continue move the loops as above over USB and DIN. | verify: manual, appliance + DAW.
NON-GOALS:
- Clock loss (Part 5), sending Song Position, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 5. Clock loss and Waiting-for-clock arms (about 380 production lines)

D5 and D10: the detection sequence, the Sync/Band round-up finalize,
`le_cancel_pending_gestures` shared with Cut, Keep and Stop policies,
`LE_PLOG_CLOCK_LOST` (350), reconnect that starts nothing, the `CLOCK` arm
that Sound cannot fire, `clock_losses`.

Tests (`test_clock_follow.h`): Multi, master 4 bars at 120 BPM (384000).
Track 2 records from position 0; pulses stop at frame 48000; loss is
detected at frame 60000. Track 2 is STOPPED with length 384000, frames
`[0, 60000)` equal to the input ramp and the rest zero. An arm on track 3 and
a count-in are cancelled. Keep: track 1 still PLAYING. Stop: track 1
STOPPED, resume mask `0b1`. Pulses return: Waiting, then Synced, and track 3
never records. Sync mode, primary 384000: a take started at the primary top
and lost at frame 537600 (1.4×) ends at 2× (768000) with `[0, 537600)` equal
to the input; it never ends at 1×. An overdub at loss closes as a Stop with
exact Redo. A defining take at loss finalizes through the crossfade path with
its measured length. Past the largest ratio (delta review DL3): a take lost
at 4.6× the primary ends at 4× with the cut frame count in fact 350 and the
notice raised. A `CLOCK` arm ignores a loud input and fires at the Synced
edge (Follow Off). Cut all sound keeps its tail clearing.

```success-criteria
GOAL: Losing an external clock mid-performance closes every take with all its measured audio in every mode, cancels queued starts, obeys Keep playing or Stop loops, and a reconnect never records or starts music by itself.
SUCCESS CRITERIA:
- The Multi and Sync loss oracles above pass (no measured frame lost, Sync rounds up), arms and count-in cancelled, Keep vs Stop, reconnect records nothing. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Overdub and defining-take loss, CLOCK arms immune to sound, Cut unchanged; sanitizer and telemetry-off suites pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: unplug the USB clock source mid-overdub and pull the DIN cable mid-take in Sync mode; both takes are kept whole, playable and undoable. | verify: manual, appliance.
NON-GOALS:
- Held-take publication failure (E4-5), UI cues (Part 9c).
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 6. The MIDI-out scheduler: per-output send, downbeat, offsets and relay (about 650 production lines)

D7 complete: the anchor with musical tick phase and filtered time, the pure
`le_clock_send_due`, the thread with the portable wake, output attach and
detach with quiescence, the output table, `L_out`, lookahead and rebase, the
downbeat rule and Start 1 ms before tick 0, Play/Stop per output, offset
slew, relay rings inside the sink bracket, echo exclusion, the late-tick
counter; the generator's first tick moved to the Start frame; removal of
`midi_clock_ring` and the block push.

Tests (`src/test/test_clock_send.h`, scheduler driven through
`le_clock_send_due` with a fake clock; a fake output records `(t_ns,
bytes)`): 120 BPM 4/4, sr 48000 (1000 frames per tick, `P = 20_833_333.3`
ns), `L_out = 128/48000 s` (2_666_667 ns), anchor `t_block = 1_000_000_000`
at the Start frame. Offset 0: Start at `1_001_666_667`, tick 0 at
`1_002_666_667`, tick 3 at `1_065_166_667`; offset +10 ms: tick 3 at
`1_075_166_667`; offset −7 ms: Start and tick 0 are past due and go out at
once, 1 ms apart, and tick 1 (`1_016_500_000`) and later are on time; ±1 ns
rounding. A 4a retime from 120 to 121 BPM at 10 s keeps every following tick
on the loop's beat frames (the review's probe failure). A slip moves the
following ticks by the slipped frames. Play/Stop off: no 0xFA/0xFC. Song and
Free: nothing. An output with the source's id gets nothing; relay forwards
0xF8 to every other Clock output within one scheduler wake of its arrival.
Segno-to-Segno loopback: a second engine following the first lands its
downbeat on the same musical frame. An offset change while running moves due
times by at most 1 ms per beat. TSAN: relay pushes and detach race cleanly;
a detach while the thread sends is clean. 10 000 ticks under ASAN leave no
growth.

```success-criteria
GOAL: Internally generated clock goes out to each chosen output with the downbeat on the first clock, its own offset measured from the audible output, on the loop's beats through retimes and slips; external clock is relayed with its received timing; nothing is ever sent back to the clock source.
SUCCESS CRITERIA:
- Due-time oracles (Start 1_001_666_667, tick 0 1_002_666_667, tick 3 1_065_166_667 / 1_075_166_667), the −7 ms catch-up, retime and slip phase, loopback downbeat. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Per-output Clock and Play/Stop, Song/Free silence, echo exclusion, relay, offset slew, bounded queues and no allocation on the audio thread. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- Relay pushes, attach and detach race the scheduler without a data race. | verify: NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
- The retired ring and block push are gone; symbol parity holds in CI. | verify: ! grep -rn "midi_clock_ring" packages/segno_engine/src
- HARDWARE: a DAW slaved to Segno over USB and over DIN; a loopback recording of Segno's output against the DAW's metronome shows the bars aligned within the reported constant, tick jitter under 1 ms p99, and −10, 0, +10 ms offsets moving the DAW by that amount within 0.5 ms. | verify: manual, appliance; attach the measurement.
NON-GOALS:
- DIN serial and Thru (Part 7), Dart, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 7. DIN serial port, Thru and UART0 in the image (about 450 production lines; closes #1069)

D8: `midi_backend_serial.c` (termios2 31250 8N1 raw, running-status parser,
SysEx skip, real-time interleave, reader at `SCHED_FIFO` 70, timestamps,
`le_midi_set_serial_port`, `din:` dispatch in `le_midi_open`/enumerate,
output writes through the Part 6 scheduler), the Thru ring and wake inside
the sink bracket, Thru suspending generated and relayed sync on DIN Out;
Yocto `dtoverlay=uart0-pi5` at `kas-segno-rpi5.yml:137`, `serial-getty@ttyAMA0`
masked, the firmware serial alias kept off UART0.

Tests (`test_midi_core.c`, against a pseudo-terminal pair): `90 3C 64 3C 00`
(running status) yields Note On 60/100 then Note Off 60; `90 F8 3C 64` yields
a timestamped 0xF8 then Note On 60/100; `F0 7E 01 F7 B0 07 7F` skips the SysEx
and yields CC 7 = 127; a dangling data byte after reset is dropped; with no
serial port set, enumeration lists none. Thru: those bytes come out of the
output side unchanged and once; with Thru on the scheduler sends no
generated or relayed 0xF8 to DIN and does to other outputs; a Thru push races
detach cleanly under TSAN.

```success-criteria
GOAL: The console's DIN MIDI In and Out are ordinary MIDI ports to the app, carrying controls, notes, clock and Thru, from a cold boot, with nothing else on the UART and the pedal link untouched.
SUCCESS CRITERIA:
- Parser, enumeration and Thru oracles above pass on a pty. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and race suites pass with the reader and scheduler threads. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: on a freshly built image, /dev/ttyAMA0 exists after a cold boot with no manual step; /proc/consoles has no ttyAMA0; serial-getty@ttyAMA0 is masked; a MIDI monitor on DIN OUT sees no byte from power-on to the app's start; hardware/bench/midi_din_test.py passes without loading an overlay; notes into DIN IN reach MIDI Learn; Segno clock leaves DIN OUT; the pedal link on /dev/ttyAMA3 still drives pedals and LEDs. | verify: manual, appliance; the #1069 acceptance list ticked in the PR.
- HARDWARE: with the UI under load, DIN clock interval jitter p99 (logged by a test build); DIN Thru from a keyboard to a synth plays every note once with added latency under 1 ms, and with Thru on the synth receives no Segno clock. | verify: manual, appliance + keyboard + synth.
NON-GOALS:
- MIDI Learn changes, a second DIN port, USB gadget MIDI (out of scope by owner decision).
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 8. Dart seam, repositories, settings, sessions and replay (about 650 production lines)

Section 3 complete without screens: the `ClockSync` role interface and mock
(input captures through instruments Part 3a's `MidiInputSink` role),
`ClockSyncSnapshot`, `midi.sync` with checkpoint restore and the defaults
(D11), the registry's clock-source capture, output attachment and serial
path, `LooperRepository` applying the envelope with a receipt, replaying it
and every attachment per engine lifetime (M9), the session-open rule under an
external source (H4) with its toast, session capture mapping external to
MANUAL, `TransportSnapshot` clock fields, and `MidiSyncCubit`.

Tests: `packages/settings_repository` round trip, malformed envelope falls back
with a notice, a refused write restores the checkpoint;
`packages/looper_repository` against the native library: a source publishes
its receipt; a source change while recording surfaces `syncLocked`; the
snapshot projects every state; **opening a session (MANUAL 96 BPM) while the
source is external succeeds, leaves the tempo to the clock and emits the
toast once**, and under Internal restores 96 as today; an engine reopen and a
device change replay the sync vector and attachments (the engine reads the
same source afterwards); session capture under external writes MANUAL 120.00
and reopens; `MidiSyncCubit` bloc tests for each transition, the offset
clamp at ±10, the zero reset and Back cancel.

```success-criteria
GOAL: The app persists and applies MIDI sync through one owner, keeps it across engine lifetimes, attaches the right input and outputs natively, and sessions open and save under an external clock.
SUCCESS CRITERIA:
- Settings envelope round trip, defaults equal today's behaviour, refused writes restore the checkpoint. | verify: (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Repository against the native engine: receipts, -20/-21 mapping, projection, session open under external, replay after reopen and device change, attachments on hotplug. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/midi_device_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Session capture and reopen under external; MidiSyncCubit transitions. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session test/control
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Screens (Parts 9a-9c).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 9a. Clock & sync page, Internal source: Send sync, offsets, Thru and the tabs (about 450 production lines)

Ships after Parts 6, 7 and 8, without waiting on any receive part or 4a
(review H1). `lib/control/view/midi_sync/midi_sync_page.dart` in a
`LoopSettingsFrame`, matching `fkLOU`, `bXxAY` and `YPTg6`: the readout
with "Segno sets the tempo" / "Other devices can follow it below." and the
Tempo & click button; Send sync cards per output (Clock, Play/Stop requiring
Clock, offset with touch and encoder draft and the zero reset, the
"−10 ms earlier · +10 ms later ..." note, disconnected outputs kept with
their state); MIDI Thru with both notes, the DIN card's "MIDI In → MIDI Out"
sublabel and its dimmed controls keeping their values. The tempo source row
shows Internal only until Part 9b adds the devices. The Controls / Sync tab
pair goes on both MIDI pages (section 26 and the section 53 editors); Back
and Stage as in `MidiControlsPage` (`midi_controls_page.dart:157-180`). EN
and ES. No simulation footer.

Tests: widget tests for the Internal states from a seeded cubit, offset draft
(encoder turn, commit, Back cancel, zero reset), Play/Stop disabled until
Clock, Thru dimming, tab navigation and Stage return; goldens for `fkLOU`,
`bXxAY`, `YPTg6` at 1920 x 1080.

```success-criteria
GOAL: A performer can send Segno's clock and transport to chosen outputs with per-output offsets and turn on DIN Thru, from the MIDI settings, before any receive work ships.
SUCCESS CRITERIA:
- The three screens render as in the pen without the footer; goldens updated and eyeballed on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/view/midi_sync
- Offset draft and cancel, zero reset, Play/Stop requiring Clock, Thru dimming, tabs. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: on the appliance, enable Clock to DIN, set −7 ms with the encoder, cancel with Back, enable Thru and confirm the synth follows. | verify: manual, appliance.
NON-GOALS:
- External sources (9b), main view and Loop settings (9c).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 9b. External sources on the Clock & sync page (about 350 production lines)

Ships after Parts 2, 3a, 4 and 5 (not 3b). The source row with devices,
"Disconnected" sublabels and the lock while recording ("Finish recording to
change source."); the readout states of `yMhnp`, `ipK6w`, `q85IK`, `OeIN1`
(BPM or `—`, the hints, the beat pulse); Follow Play/Stop with its hint; If
clock is lost; Use internal tempo; the source's output "Receiving clock" and
the external offset note; the out-of-range and tempo-held lines; the Song
Position toast. EN and ES.

Tests: widget tests for the four states, the lock, the echo-disabled output,
Use internal tempo, the held line; goldens for `yMhnp`, `ipK6w`, `q85IK`,
`OeIN1`.

```success-criteria
GOAL: The page selects an external clock source and shows exactly what the follower holds, in the accepted states.
SUCCESS CRITERIA:
- Four states render as in the pen; goldens updated and eyeballed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/view/midi_sync
- Source lock, echo-disabled output, Use internal tempo, toasts. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: select a drum machine as source, pull its cable and see Clock lost within half a second on the page. | verify: manual, appliance.
NON-GOALS:
- Main view and Loop settings (9c).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 9c. Main-view sync status, Loop settings under MIDI clock and track cues (about 400 production lines)

`StageTopBar` chip "MIDI synced" opening the Sync page (`PMu8D`), and the
undrawn "Waiting" and "Clock lost" chips from the write-back list;
`loop_tempo_page.dart` clock variant (`dRiy6`: banner, Clock & sync button,
readout labelled MIDI clock with the D10 beat dots, slider and Tap disabled,
signature, Hear click and Count-in unchanged); Audio & tempo note "Recorded
audio follows MIDI clock." under Follow tempo On with an external source
(`BFfDT`), and the Follow-Off line of D4's owner decision; the one-time
detach toast (D4, PDL2) on the main view; length pages verified
unchanged under clock (`PddSM`, `XLSOr`); track cues "Waiting for clock" and
"Clock lost · Captured / audio kept" (`gCTKx`). EN and ES.

Tests: widget tests for the chip per state and its navigation, the tempo-page
variant (Tap and slider inert, banner button opens Sync), the audio-tempo
note per Follow value, the two cues, the detach toast once per source
selection; goldens for `PMu8D`, `dRiy6`, `BFfDT`,
`gCTKx`.

```success-criteria
GOAL: Wherever tempo or recording is shown, the performer sees that an external clock owns it, and what happened when it was lost.
SUCCESS CRITERIA:
- Chip, tempo-page variant, audio-tempo note, length pages and both cues match the screens named above; goldens updated and eyeballed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper
- Tap and the slider cannot change tempo under clock. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/loop_settings
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: with a drum machine as source the chip reads MIDI synced and the tempo page follows it; a take cut by pulling the cable shows the cue on both displays. | verify: manual, appliance.
NON-GOALS:
- New settings beyond the accepted screens.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Dependencies and sequencing

```
Part 1 sink (built; instruments 2c builds on it)
  ├─ Part 2 follower ─┬─ Part 3a phase lock (slips, latency, whole-bar takes)
  │                   │     └─ Part 3b real tempo changes (needs pitch/time 4a)
  │                   ├─ Part 4 Follow Play/Stop + SPP
  │                   └─ Part 5 loss + CLOCK arms
  └─ Part 6 scheduler (relay needs Part 2's source) ── Part 7 DIN serial + Thru + UART0
Parts 6, 7 + instruments Part 4 registry ── Part 8 Dart ── Part 9a send page (Internal)
Parts 2, 3a, 4, 5, 8 ── Part 9b external sources ── Part 9c main view + Loop settings
```

- No user-facing part waits on pitch/time 4a: 3b adds real tempo changes
  when 4a exists; until then the held state says so.
- Parts 4, 5 and 6 are independent after Part 2; Part 5 lands after 4 if
  both touch the held-park bypass.
- Part 8 needs the instruments Part 4 registry; if that slips, Part 8 builds
  it to that plan's text and instruments rebases (rule 4). Part 8's
  send-only subset (outputs, settings, replay) is enough for 9a.
- Native parts rebase onto Reverse and pitch/time where they touch
  `advance_transport_frame` and `le_tempo_locked`; facts and commands keep
  the ledger numbers.

## 5. Decisions taken under the standing rules

1. One input path for notes, controls and clock: the shared sink, one layout
   in both plans (rule 4).
2. Two-stage DLL (0.5 Hz then 0.2 Hz), outliers against a jitter estimate,
   six-pulse step rule, gated missed-pulse counting (D3).
3. Segno's tempo unit everywhere, the Sync page included, is the
   denominator note (rule 4: one unit).
4. Crystal drift is corrected by slips at the master wrap under the existing
   turn crossfade, deferred during captures; only real tempo changes go
   through 4a's retime (rule 4: one owner of rescaling).
5. Under an external source an Auto defining take ends on whole bars from
   its own start (AB 2.8's precedent), never truncated; slips keep the
   loop's own offset to the master's grid.
5a. Owner decision (2026-10-06): under an external clock a track with Follow
   tempo Off keeps its recorded speed and detaches until its next
   Stop/Play; the song tempo still follows the master (D4).
6. Receive aligns Segno's output, not its block, to the master (`L_out`), the
   same principle as sending.
7. Loss closes takes at detection keeping every measured frame (Sync and
   Band round up) and cancels queued starts through the helper shared with
   Cut (rules 2 and 4).
8. One scheduler thread is the only writer of every MIDI output; the first
   clock is the downbeat; offsets are measured from the audible output; the
   wake is portable (rule 4).
9. Start plays every recorded track and closes captures first; local presses
   clear a held MIDI position; Follow Off relays transport but does not act
   on it (D9).
10. DIN is a native serial port with nothing else on UART0 (answers #1069).
11. Defaults keep today's behaviour: nothing sends, Internal source (rule 1);
    an unreadable `midi.sync` falls back to defaults with a notice (rule 5).
12. Sessions save a MANUAL tempo and open under an external source without
    applying it, with a notice (rules 2 and 3); sync state is replayed on
    every engine lifetime (rule 3).
13. The clock-mode tri-state is removed, not kept beside the new commands
    (AGENTS.md).

## 6. Risks

- The relay and Thru paths add a userspace hop; Parts 6 and 7 measure it. If
  DIN Thru latency exceeds 1 ms, the follow-up is a reader-side direct write
  with the scheduler suspended for DIN, not a second writer.
- `L_out` from the driver ignores codec and converter delay; the user offset
  absorbs it on send, and Part 3a's hardware run reports the receive
  residual.
- A slip, even crossfaded, is a small discontinuity once per lap; at 50 ppm
  it is about 20 frames. Part 3a's crossfade oracle bounds it and the
  hardware run listens for it on sustained material.
- Kernel-side MIDI timing (PL011 receive timeout, tty and rawmidi work on
  normal kworkers) is outside the app; the follower's tuning covers sources
  far coarser, and the loaded-UI measurements decide whether threaded IRQ
  priorities need raising in the image.

## 7. Hardware-only evidence

Collected with the UI under load, per part: USB pulse jitter and RT priority
(1), tempo display stability (2), 10-minute lock over USB and DIN with the
constant offset reported (3a), DAW tempo change (3b), DAW transport (4),
unplug mid-take in Multi and Sync (5), sent-clock alignment, jitter and
offsets (6), cold-boot DIN with no console bytes, Thru, DIN jitter, pedal link
(7), the send page (9a), loss on the page (9b), chip and cues on both
displays (9c). "Green in CI" does not close these.

## 8. Pen write-back list (for the owner; this plan never edits the pen)

- Remove "Timing simulation · no MIDI messages are sent to hardware." from
  five section-27 screens and both PARITY Clock screens.
- Draw the zero reset for the sender offset (AB 7.4; `bXxAY` shows only the
  slider and value).
- Draw the main-view "Waiting" and "Clock lost" chips (only "MIDI synced" is
  drawn, `PMu8D`; the loss screen `gCTKx` has none).
- Draw the undrawn copy: "Waiting for clock" track cue; "Song Position
  ignored while playing"; "Finish recording to change source."; "Reconnect
  the selected device." with a selected-but-disconnected source; "Could not
  save. The previous setting is retained."; the out-of-range line ("The clock
  is outside Segno's 30-300 BPM in 6/8."); "Tempo change waits for the take
  to finish."; the pre-3b held line; the real-time-priority warning.
- The page's interim Internal-only source row in Part 9a (until 9b).
- Note on 27/01 that DIN appears only on the appliance.
- The 07/07 note under Follow tempo Off ("Keeps its recorded speed. The MIDI
  clock changed the song tempo.", D4's owner decision).

## 9. Genuine product-direction questions

None open. Answered by the owner on 2026-10-06: under an external clock, a
track with Follow tempo Off keeps its recorded speed and detaches until its
next Stop/Play (option (a) of the question; D4 records it). The options not
taken were refusing an external source unless every recorded track follows
tempo, and forcing Follow tempo On while an external source is selected.

The receive-side alignment no longer needs an owner call: D4 compensates the
known output latency the way sending does (review M10).

## 10. Plan review disposition (PR #1236)

| Finding | Where it is met |
|---|---|
| H1 drift through 4a | D4 (slips at the wrap, real changes only through 4a, capture wait, whole-bar defining take), Parts 3a/3b, 9a/9b split, section 9 |
| H2 tempo units | D3 units, Part 2 6/8 oracles, Part 4 6/8 SPP |
| H3 first clock late | D7 downbeat rule, Part 6 oracles and loopback |
| H4 session open under clock | D11, Part 8 test |
| M1 re-acquisition | D3 (probe table), Part 2 jitter models |
| M2 missed pulses | D3, gap mark in Part 1, Part 2 dropped-pulse oracle |
| M3 re-anchor | D4 anchors, Part 2 test |
| M4 wake and anchor time | D7 (ppoll/eventfd/timerfd, Darwin condvar, filtered `t_block`) |
| M5 tick phase after retime | D7 anchor, Part 6 retime oracle |
| M6 loss truncation | D5 step 1, Part 5 Sync oracle |
| M7 UART0, kernel latency, serial path | D1, D8, Part 7 checks |
| M8 one sink | D1 = instruments D4 (`74e55eab4`), Part 1 built |
| M9 reopen replay | D11, Part 8 test |
| M10 receive latency | D4, Part 3a oracle and hardware wording |
| M11 pen coverage | pen table, Parts 9a-9c, section 8 |
| L1 citations | corrected throughout |
| L2 macOS clock base | D1 |
| L3 D9 reference | D5 step 3 |
| L4 udev rule | D8 (dropped: the app runs as root) |
| L5 transport edge cases | D7 (Continue), D9 (captures, count-in) |
| L6 Start-armed take | D4 |
| L7 anchor data race | D7 |
| L8 offset edits | D7 |
| L9 beat pulse and quantize anchor | D10 |
| L10 ALSA identity | D6 |

Delta review (`6fc551396`):

| Finding | Where it is met |
|---|---|
| DH1 integer tempo divisions | D3 missed pulses; built in Part 2 with the 120 → 60, 150 → 50 and 174 → 87 oracles |
| DM1 owner decision, global Follow Off, oracles, detached wording | D4 (decided; the global value under a clock; detached tracks and slips), section 5 item 5a, section 9, Part 3b oracles |
| DM2 slip fact | numbering table (349), D4, Part 3a scope and parity oracle |
| DM3 slip target and Auto end | D4 (take-start offset; whole bars from the take's start), Part 3a 1.5-beat oracle |
| DL1 readout flicker | D3 published values; built in Part 2 (band, hold, lag oracles) |
| DL2 probe flaws | the probe is retired; Part 2's native tests are the measurement |
| DL3 past the largest ratio | D5 step 1, Part 5 oracle |
| DL4 detached track and Continue | D9 Continue |
| DL5 instruments D4 on CoreMIDI loss | instruments plan D4 (`1537c8f96`) |

PR #1246 review (Part 1): M1 and L1-L6 are met in Part 1 (`8c2f43d48`); D1
here and instruments D4 describe the dispatch order; the backlog note is
met in Part 2.

PR #1259 review (Part 2) and the second plan delta review:

| Finding | Where it is met |
|---|---|
| P2 M1 / PDM1 seed and drops on block edges | D3 (least-squares acquisition, one-beat minimum, kink cut, run classifier, table with block-edge rows), built in Part 2 with the review's probes as oracles |
| P2 M2 / PDM2 REBOUND hides a loss | D1, D3 loss; built: REBOUND makes Synced Lost with the event and keeps Lost; rebind and close tests |
| P2 L1 deadline | D3 loss; built with its oracle |
| P2 L2 equal timestamps | D3 missed pulses; built with its oracle |
| P2 L3 untested guards | Part 2 tests (restore, tap, arm and pending, content lock) |
| P2 L4 old transport bytes | D1 backlog; built with its oracle |
| P1 DL1 LOST after a rebind | D1; built in Part 2 with an order oracle |
| PDL1 code 48 | numbering section and D12 agree |
| PDL2 detach notice | D4 detach notice, section 2 `clock_detaches`, Parts 3b and 9c |
| Ramp lag note | Part 3b: keeps following, one retime per bar, phase re-placed at each |
| Coordinator note: one Dart input seam | Section 3 and Part 8 use instruments Part 3a's `MidiInputSink` |
