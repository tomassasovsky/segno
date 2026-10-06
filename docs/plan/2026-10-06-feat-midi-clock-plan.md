# MIDI clock: receive, Follow Play/Stop, clock loss, per-output send and the MIDI Sync page

<!-- cspell:ignore retime retimes SCHED RTPRIO bootfs sched seqlock seqlocked rawmidi TSAN Adriaensen PPQN termios BOTHER ttyAMA SONGPOS PGMCHANGE NOTEON NOTEOFF CHANPRESS nanosleep ABSTIME eventfd setschedparam Kaehn fkLOU yMhnp ipK6w OeIN1 PMu8D bXxAY YPTg6 nfcC2 IEttC FrsRF JQpGt Lqfa3 rmWqV dRiy6 PddSM -->

Tracking: #1228 (gap inventory E8-1 to E8-5), `autonomy:merge-gate` on every
build part. Related: #1069 (DIN MIDI reaches the app; this plan answers its
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
`2026-10-06-feat-pitch-time-core-plan.md` (its Part 4a is a dependency here)
and the instruments plan (`origin/claude/instruments-plan-1197:docs/plan/2026-10-06-feat-instruments-plan.md`).

## Engine numbering (from the ledger; nothing outside this range)

| Kind | Range | Use in this plan |
|---|---|---|
| Commands | 124-131 | 124 `LE_CMD_SET_CLOCK_SYNC` (Part 2). 125-131 stay reserved to this epic. |
| Facts (perf log) | 348-351 | 348 `LE_PLOG_CLOCK_TRANSPORT` (Part 4), 350 `LE_PLOG_CLOCK_LOST` (Part 5). 349 and 351 reserved. |
| `LE_ERR` | -20, -21 | -20 `LE_ERR_EXTERNAL_CLOCK` (tempo is owned by an external source), -21 `LE_ERR_SYNC_LOCKED` (sync source change while capturing, armed or counting in). |

`LE_CMD_SET_CLOCK_MODE` (48) is retired by Part 2 and its number is never
reused (the code already has retired gaps: 18, 51, 52, 60,
`segno_engine_api.h:203-520`). The events.log version bump for facts 348 and
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
| 27/01 Internal tempo (Clock & sync page, Internal source, Send sync, offsets, MIDI Thru) | `fkLOU` | 9a |
| 27/02 Waiting for clock (BPM `—`, "Start the clock on your other device.", offsets disabled with "Received sync keeps its incoming timing.") | `yMhnp` | 9a |
| 27/03 Following MIDI clock (Synced, Follow Play/Stop On, If clock is lost) | `ipK6w` | 9a |
| 27/04 Clock lost · Keep playing ("Last tempo retained.", Use internal tempo) | `q85IK` | 9a |
| 27/05 Clock lost · Stop loops ("Loops stopped. Reconnect, then press Play.") | `OeIN1` | 9a |
| 27/06 Sync on the main view (top-bar "MIDI synced" chip) | `PMu8D` | 9b |
| PARITY Clock / Sender offset (DIN offset -7 ms) | `bXxAY` | 9a |
| PARITY Clock / DIN Thru ("Segno sync on MIDI Out is paused while Thru is on.") | `YPTg6` | 9a |
| 26 MIDI controls headers (the Controls / Sync tab pair) | section `rmWqV` | 9a |
| 05/08 Tempo from MIDI clock (banner "Tempo follows MIDI clock.", Clock & sync button, slider and Tap disabled, four beat dots) | `nfcC2` / `dRiy6` | 9b |
| 06/04 Length under MIDI clock (lengths stay editable and local) | `IEttC` / `PddSM` | 9b |
| 06/09 Track settings under MIDI clock (per-track overrides unchanged) | `FrsRF` | 9b |
| 07/07 Audio follows MIDI tempo (note "Recorded audio follows MIDI clock.") | `JQpGt` | 9b |
| 51 Clock loss · Partial take preserved (track cue "Clock lost · Captured / audio kept") | `Lqfa3` | 9b |

Every 27 and PARITY screen carries the prototype footer "Timing simulation ·
no MIDI messages are sent to hardware." It is not shipped (AB authority:
no simulated content) and is on the pen write-back list (section 8).

## What the code does today (file:line)

### Clock send exists natively and reaches nothing

- `le_clock_mode` is a tri-state (`segno_engine_api.h:149-165`) set through
  `le_engine_set_clock_mode`, which rejects `LE_CLOCK_RECEIVE`
  (`engine_commands.c:3291-3297`); the audio-thread handler re-validates and
  drops it (`engine_process.c:3418-3428`). The reason is plain: no follower was
  ever built ("Phase E", `segno_engine_api.h:2212-2216`), and
  `LE_TEMPO_SOURCE_EXTERNAL` is reserved but unused (`:76-85`).
- Send: `le_midi_clock_advance` (`src/midi/le_midi_clock.c:17-70`) is a pure
  24-PPQN generator. It emits Start on the idle-to-active edge, Stop on the
  reverse, and ticks counted from an absolute epoch. It is called once per
  block at the end of `le_engine_process` (`engine_process.c:6882-6911`) and
  gated on `clock_mode == SEND` and Multi/Sync/Band (`:585-597`; Song and Free
  stay silent per the manual, `le_midi_clock.h:18-26`).
- Every tick of a block is pushed with no intra-block time into
  `midi_clock_ring` (`engine_private.h:105-116`, `:1834-1845`), which **has
  no consumer**: "a native test's direct le_ring_pop today"
  (`engine_private.h:106-108`; the tests pop it at `test_engine_core.c:26802-26814`).
  `le_midi_out_send` (`src/midi/midi.c:311-318`) and the Dart
  `MidiOutClient` (`packages/midi_client/lib/src/midi_out_client.dart:11-24`)
  exist, but nothing outside the package constructs `MidiOutClient`.
- `a_clock_mode` is seeded OFF at create (`engine.c:1190`) and the generator
  reset per configure (`engine.c:760-762`). No Dart code reads or sets clock
  mode (the only "midiClock" in `lib/` is a Learn stopwatch,
  `control_cubit.dart:178-223`).

### MIDI input drops every clock message, and runs through Dart

- `le_midi_ring_push` filters out everything that is not Note or CC before
  the ring (`midi.c:100-119`); the parser maps 0xF0-0xFF to
  `LE_MIDI_IGNORE` (`:87-91`). One port per handle; `le_midi_drain` calls one
  Dart callback (`:121-134`).
- ALSA: the read thread converts only NOTEON, NOTEOFF, CONTROLLER and
  PGMCHANGE (`midi_backend_linux.c:136-167`) and stamps arrival with
  `CLOCK_MONOTONIC` at read (`:49-53`, `:169`). The thread is created at
  default priority (`:246`). CoreMIDI skips every 0xF1-0xFF byte
  (`midi_backend_apple.c:128-131`) and converts packet host time
  (`:98-105`).
- Dart: `MidiControllerSource._parse` maps only 0x90/0x80/0xB0/0xC0
  (`packages/midi_client/lib/src/midi_controller_source.dart:85-101`);
  `MidiDeviceRepository` pins one device (`midi.input_device`,
  `settings_repository.dart:487-533`).
- Instruments plan D4 (`origin/claude/instruments-plan-1197`, plan lines
  458-525) designs the replacement: a per-port SPSC ring inside the engine,
  fed by the OS MIDI thread through a quiescent sink, drained by the audio
  thread, with generation, lost and overflow flags (plan §2.2, lines 687-693,
  Part 2c at 901-955), and a one-capture-per-device registry (Part 4, lines
  1059-1090). Its ring entry is `{u32 gen; u8 status, d1, d2}` with no time.

### Tempo, the master loop and the transport

- Tempo is an atomic with a source (`a_tempo_bpm_bits`, `a_tempo_source`).
  `LE_CMD_SET_TEMPO`, `TAP_TEMPO` and `SET_TIME_SIGNATURE` are ignored while
  `le_tempo_locked` (`engine_process.c:458-470`, `:3174-3209`): any content
  plus a grid locks tempo. `RESTORE_TEMPO` needs a stopped rig (`:3160-3172`).
- Once a loop exists the loop is the grid: `sync_grid_to_loop` rounds the bar
  count to the existing tempo and never alters audio length
  (`engine_process.c:634-670`); quantize uses the loop-locked grid
  (`tempo_grid.h:95-111`, `:132-171`). `le_loop_clock` is `{length,
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
  (`:2201-2240`).
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
  (`lib/looper/view/settings_page.dart:334-337`, `lib/app/segno_navigator.dart:149-161`);
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
  (`settings_repository.dart:535-575`).

### DIN MIDI on the appliance

- The console board's DIN sockets are wired to the Pi's UART0 (GPIO14/15).
  Bench-proven 48/48 bytes in both directions at 31250 baud through
  `/dev/ttyAMA0` with raw `termios2` and `BOTHER`
  (`hardware/bench/midi_din_test.py:12-13`, `:56-105`; `hardware/bench/README.md:8-30`; #1007).
- The image enables UART3 for the pedal link with
  `RPI_EXTRA_CONFIG:append = "\ndtoverlay=uart3-pi5..."`
  (`deploy/yocto/kas-segno-rpi5.yml:132-137`, #984), and overlays reach the
  boot slot through `segno-bootfs` (`deploy/yocto/meta-segno/recipes-core/bootfs/segno-bootfs.bb:1-11`).
  #1069's "no overlays directory" predates #984; UART0 is still not enabled.
- Nothing routes the UART into the app: the app's MIDI input is ALSA only
  (#1069 §2). The pedal link already owns `/dev/ttyAMA3` with its own Dart
  transport (`packages/pedal_repository/lib/src/uart_pedal_io.dart:15-83`).

## 1. Decisions

### D1. One MIDI input path: real-time bytes join the instruments' per-port sink, with a timestamp

Clock never passes through Dart: the `NativeCallable.listener` hop adds an
event-loop wait that depends on UI load, and a 24-PPQN clock at 300 BPM has
an 8.3 ms pulse period. The instruments plan already designs the native path
(D4: per-port SPSC ring, quiescent sink, generation, lost and overflow flags,
one capture per device). Rule 4: this plan uses that path, adding two things
to it:

1. **Kinds.** The parser keeps Timing Clock (0xF8), Start (0xFA), Continue
   (0xFB), Stop (0xFC) and Song Position (0xF2 + two data bytes) for the sink.
   They stay out of the Dart ring, so Learn and the controller decoders never
   see them (AB 7.3: Song Position is not a Learn target), exactly as
   `le_midi_ring_push` filters today (`midi.c:103-105`).
2. **A producer timestamp.** The port-ring entry grows to
   `{u64 t_ns; u32 gen; u8 status, d1, d2}` (16 bytes). ALSA stamps with
   `le_now_ns()` at `snd_seq_event_input` return (the read already stamps
   there, `midi_backend_linux.c:169`); CoreMIDI converts the packet host time
   (`midi_backend_apple.c:98-105`) to ns; the serial DIN reader (D8) stamps at
   `read()` return. All three share `CLOCK_MONOTONIC`, the base of
   `le_now_ns`.

The MIDI input threads (ALSA, serial) are raised to `SCHED_FIFO` 70, below the
audio thread's 80 (`engine_linux.c:838`), so a busy UI cannot delay a
timestamp. A refused raise (no `RTPRIO`) is reported once in the snapshot
(`midi_rt_denied`) and shown in the Sync page's device row, never silent.

Whichever of instruments Part 2c and this plan's Part 1 lands first builds
the sink; the other rebases onto it. Part 1 below is written as the full sink
so it does not wait on the instruments CPU gate (that plan's Part 1 owner run
gates its Part 2a, plan lines 772-795).

### D2. The follower runs on the audio thread, against a monotonic time base

The audio thread owns the transport, so it owns the follower: start, stop,
loss and phase decisions must not race a second thread. At block start it
reads `t_block = e->now_ns()` (default `le_now_ns`; a test hook
`le_engine_set_time_source_for_test` substitutes a fake clock, the same
pattern the reopen plan's test seam used), drains the source port's ring, and
places each pulse on the frame timeline as
`frame(t) = frame_clock - (t_block - t) × sr / 1e9`. Pulses always lie in the
past relative to `t_block`; that drain delay (at most one block plus the MIDI
thread wake) is removed exactly by the timestamp, not averaged.

The telemetry note against clock reads inside `le_engine_process`
(`engine_miniaudio.c:35-44`) is about its gap detector mixing test and device
timelines; the follower's reads go through the substitutable `now_ns`, so the
native harness keeps one timeline.

The follower is a pure-value module, `src/midi/le_clock_follow.{h,c}`, in the
shape of `le_midi_clock.h` (no atomics, no allocation): the engine and the
unit tests drive the same function with the same inputs.

### D3. Jitter filtering and the tempo estimate

Established practice for filtering timestamped periodic events is a
second-order delay-locked loop (F. Adriaensen, "Using a DLL to filter time",
LAC 2005), the filter JACK uses for its period timing. It tracks a constant
tempo with zero steady-state error and a tempo ramp with a constant small
lag, and needs three multiplies per pulse.

- **Valid interval.** `[60/(300·24)·0.98, 60/(30·24)·1.02]` s, the engine's
  30-300 BPM clamp (`tempo_grid.h:27-28`) with 2 % margin. A pulse whose
  interval falls outside resets acquisition; an overflow flag on the port
  (D1) drops the last timestamp, so no interval spans a gap.
- **Acquisition.** The median of six consecutive valid intervals (the
  prototype's rule, `midi-sync-study.js:48`, which the owner approved)
  initialises the DLL period `P` and phase. Waiting becomes Synced on that
  seventh pulse (0.29 of a beat).
- **Tracking.** Per pulse, `e = t_pulse - t_pred`, `t_pred += P + b·e`,
  `P += c·e`, with `ω = 2π·B·P`, `b = √2·ω`, `c = ω²` and `B = 0.5 Hz`.
  At 120 BPM that averages USB-MIDI's 1 ms frame jitter to well under 0.1 ms
  of phase while settling a tempo change in about two seconds.
- **Step changes.** Three consecutive pulses with `|e| > max(1.5 ms, 0.1·P)`
  and the same sign re-acquire from the last six intervals. A tempo jump on
  the master (a DAW tempo change) is followed within about ten pulses rather
  than a slow ramp; USB jitter alone never trips it.
- **Published values.** The engine tempo is `60e9 / (24·P)` BPM, unrounded,
  for the grid and steering (D4). The display value is rounded to 0.1 BPM
  with a 0.05 BPM hysteresis, so the readout (`ipK6w` shows `120`, the main
  view `120.0`) does not flicker.
- **Loss.** No pulse for `max(6·P, 250 ms)` while Synced, or the port's lost
  flag (device unplugged, instruments D4 L7), is Clock lost. After a received
  Stop (0xFC), silence is Waiting, not loss: many masters stop sending clock
  when stopped (the prototype's `intentionalStop`, `midi-sync-study.js:59`).
  The prototype's one second was a browser choice; 250 ms bounds how much
  silence a lost take accrues.

### D4. Phase alignment of the master loop

- **Anchor.** Follow Play/Stop On: the first Timing Clock after Start is the
  downbeat (MIDI 1.0: a receiver starts on the clock that follows Start).
  Continue resumes from the received Song Position, or from where Stop left
  the stopped set. Follow Play/Stop Off: the external bar is unknown (the UX
  doc says the pulse indicator "does not claim bar alignment", `:11-13`), so
  the local transport start sets the anchor at the interpolated pulse phase
  of that frame.
- **Start inside a block.** A Start whose downbeat pulse is `d` frames in the
  past at block start sets the shared clock position to `d` (Continue: the
  resume position plus `d`). The musical phase then equals the external phase
  at the moment the block is processed; the remaining offset is the device
  output latency plus the MIDI transport, both constant (measured on hardware,
  section 9). A capture armed for that Start begins at the same frame and
  loses those `d` frames of input, which is the Stop/Start precedent of
  `finalize_new_track` keeping musical position over captured seconds
  (AB 2.7).
- **Drift lock.** Tempo alone is not enough: crystal tolerances of tens of
  ppm drift a loop by milliseconds per minute. Each beat (24 pulses) the
  follower compares the shared clock's position with the anchor's pulse
  count and publishes a corrected tempo `T = T_dll × (1 + k·φ)` (`φ` the phase
  error in beats, `k = 0.1` per beat, the correction clamped to ±0.1 %). The
  correction goes through pitch/time Part 4a's retime, the single owner of
  length rescaling: length and position scale together, following tracks
  re-read through the varispeed head, non-following tracks keep their
  recorded speed and detach (AB 2.6). Corrections are ppm-sized, far under
  4a's 0.5 % re-render tolerance, so no Unchanged-pitch track re-renders for
  drift. At most one retime per beat keeps the perf log at two entries a
  second at 120 BPM, logged with 4a's tempo fact (rule 4; fact 349 stays
  reserved).
- **Empty rig.** With no content, nothing is locked: the follower writes
  `a_tempo_bpm_bits` with `LE_TEMPO_SOURCE_EXTERNAL` each beat, and the first
  take's bar count is rounded against that tempo by `sync_grid_to_loop`
  (`engine_process.c:658-666`).
- **Free and Song.** Private clocks follow tempo through 4a's scaling;
  drift lock applies to the shared clock (Multi, Sync, Band) only, where a
  grid exists.

### D5. Recording when clock is lost mid-take

At detection, on the audio thread, in this order:

1. Every RECORDING or OVERDUBBING track goes through `handle_stop`
   (`engine_process.c:2131-2149`): the defining take finalizes through
   `request_master_finalize`, a later take through `finalize_new_track`,
   which keeps the measured material at its musical position and pads the lap
   with silence (AB 2.7). The take ends STOPPED and playable
   (timing completion `:82-85`). It contains the audio up to the detection
   frame (at most `max(6·P, 250 ms)` after the last pulse); trimming back to
   the last pulse would rewrite frames already in the take, so it is not done.
2. Every pending arm, sound arm, quantized punch, the launch cohort and the
   count-in are cancelled by the pending-gesture loop that `handle_cut_sound`
   uses today (`:2207-2219`), extracted into `le_cancel_pending_gestures` and
   called by both (rule 4). Tails are not cleared: this is a stop, not a cut.
3. Keep playing: playing tracks continue at the last DLL tempo, steering off,
   state Clock lost ("Last tempo retained.", `q85IK`). Stop loops: every
   playing track goes through `handle_stop` with a synthetic `LE_CMD_STOP` in
   the perf log (the Cut precedent, `:2221-2229`), positions retained as for
   a received Stop (D7), state Clock lost ("Loops stopped. Reconnect, then
   press Play.", `OeIN1`).
4. `LE_PLOG_CLOCK_LOST` (350) records the policy and the detection frame.

Reconnect reacquires (Waiting, then Synced) and resumes tempo following and
drift lock, but starts nothing: arms were cancelled, and a stopped set waits
for Continue or a press (AB 7.3). Use internal tempo (`q85IK`) is
`LE_CMD_SET_CLOCK_SYNC` with the internal source: the tempo stays at the last
estimate with source MANUAL. A failed-publication held take (E4-5) is not
built yet; when it is, clock loss feeds it the same way a Stop does.

### D6. Echo prevention

- **No send to the source.** A port's identity is its backend id: the ALSA
  client name (the id both enumerations already use, `midi_backend_linux.c:82`,
  `:312`), the CoreMIDI endpoint id, and `din:<path>` for serial (D8). An
  output whose id equals the selected source input's id is never sent clock or
  transport, natively enforced in the sender (D7), and the page shows it as
  "Receiving clock" with its switches disabled (`yMhnp`).
- **Relay excludes the source** for the same reason.
- **Thru is physical-only.** DIN Thru forwards bytes read from the UART's RX,
  which can only be physical input; generated and relayed sync never go to DIN
  Out while Thru is on (AB 7.4, `YPTg6`).
- **Internal source ignores incoming clock** entirely: with Internal selected,
  received real-time bytes reach neither the follower nor the relay. An
  external cable loop between two devices is a wiring matter the app cannot
  see; it is listed for hardware verification and documented on the page note,
  not detected.

### D7. Sending: one scheduler thread, offsets measured from the audible output

The C1 generator decides ticks per block and has no intra-block time and no
consumer. The send side becomes one native MIDI-out scheduler per engine
(`src/midi/le_clock_send.{h,c}` pure scheduling plus a thread in
`midi_out_sched.c`), the single writer of every attached output:

- **Anchor.** The audio thread publishes, per block, a seqlocked anchor:
  `{t_block, active, start_pending, frames_since_start, frames_per_tick, sr}`.
  `frames_since_start` and the Start/Stop edges come from the existing
  `le_midi_clock_gen` logic (`le_midi_clock.c:28-66`), which keeps its gate
  (transport active and Multi/Sync/Band, rule 1) and loses its byte output.
- **Due times.** Tick `k` of a run is due at
  `t_block + ((k·frames_per_tick - frames_since_start)/sr)·1e9 + L_out + offset_port`,
  where `L_out = playback period frames × periods / sr` from the negotiated
  device (`engine_miniaudio.c:356-357`), and `offset_port` is -10..+10 ms in
  1 ms steps. Positive is later. The clock describes the audio the listener
  hears, so `L_out` aligns it with the output; the user offset absorbs codec,
  USB and DIN differences the driver does not report (AB 7.1: buffer time is
  not measured latency).
- **Negative offsets need lookahead.** The scheduler extrapolates from the
  latest anchor up to a 12 ms horizon (10 ms plus a block), so a tick can be
  sent before the audio thread processes its frame. A tempo change rebases the
  ticks not yet sent; sent ticks stand. Start and Stop are known only when the
  audio thread processes them: Start is sent at once, and the first ticks
  whose due time is already past (offset more negative than `-L_out`) go out
  immediately. Only the first ticks after a Start are late; the schedule is on
  time from there. Stop goes out at its due time or at once if past.
- **Thread.** `SCHED_FIFO` 70, `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)`
  to the next due time or 1 ms, whichever is sooner (the audio thread cannot
  wake it; Thru wakes it through an eventfd from the DIN reader). On
  PREEMPT_RT wake latency is tens of microseconds, under USB-MIDI's 1 ms frame
  and DIN's 320 µs per byte.
- **Why not the OS schedulers.** ALSA sequencer queues and CoreMIDI timestamps
  can schedule events, but the serial DIN port (D8) has no scheduler, and two
  timing paths would need two measurements. One userspace scheduler covers all
  three backends.
- **Relay.** With an external source, the source's input thread pushes the
  real-time bytes it receives into a per-output SPSC relay ring; the scheduler
  sends them on the next wake with no offset (AB 7.4: relay keeps received
  timing; offsets are disabled in the page, `yMhnp`).
- **Per-output switches.** Clock and Play/Stop per output; Play/Stop requires
  Clock (the page enforces it, the scheduler re-checks). With Play/Stop off an
  output gets ticks only while the transport runs.
- **Retired.** `midi_clock_ring`, its storage and overrun counter
  (`engine_private.h:1834-1845`), the per-block push (`engine_process.c:6882-6911`)
  and the byte output of `le_midi_clock_advance`.

### D8. DIN reaches the app as a native serial MIDI port (answers #1069 §2)

#1069 lists three options: a kernel bridge, a userspace bridge, or reading the
UART directly. Reading it directly in the native MIDI layer wins:

- It is the only option that keeps D1's single input path and D7's single
  writer, with timestamps taken at `read()` on an RT thread.
- `termios2` with `BOTHER` at 31250 is proven on this exact UART
  (`midi_din_test.py:56-105`).
- A Dart bridge (the pedal link's shape) would put clock through the UI
  isolate. A kernel rawmidi bridge would need a driver whose availability for
  the Pi 5's RP1 UART this plan could not confirm; the bench evidence is for
  raw termios.

`src/midi/midi_backend_serial.c` (Linux) opens a configured path
(`/dev/ttyAMA0` on the appliance, from the engine config, so desktop builds
list nothing), parses the byte stream with running status, SysEx skipping and
interleaved real-time, and pushes complete messages into the sink. It
enumerates as input "MIDI In" and output "MIDI Out" with id `din:/dev/ttyAMA0`,
the names the pen uses (`fkLOU`). `le_midi_open` dispatches `din:` ids to it,
so Controls, Learn and instruments see DIN like any device.

Thru: the reader also copies raw RX bytes into DIN's Thru ring for the
scheduler (D7), which is DIN Out's only writer. Raw bytes keep SysEx and
real-time interleaving intact (parity correction `:144`).

UART0 is enabled in the image the way UART3 is: `dtoverlay=uart0-pi5` appended
at `kas-segno-rpi5.yml:137`, plus a udev rule giving the `segno` user the
device. That closes #1069's acceptance list (cold boot `/dev/ttyAMA0`, the
bench script without a manual overlay, notes reach Learn, DIN Out sends, pedal
link unaffected).

### D9. Follow Play/Stop semantics

Native, applied on the audio thread only when Follow Play/Stop is On and the
source is external:

- **Start**: every recorded track (not EMPTY) plays from the top at the
  downbeat (D4), mute preserved (the `le_unpark_stopped` rule); a pending
  record arm survives and fires at that downbeat (UX doc `:24`); no count-in
  (AB 2.4). The resume set and any held position are cleared.
- **Stop**: every capture ends through `handle_stop` (D5 step 1); every
  playing track stops; the set that was playing becomes the resume set; the
  shared clock and Free/Song private clocks keep their positions (the idle
  park at `engine_process.c:4834-4841` is skipped while a resume position is
  held). Pending starts are cancelled (UX doc `:25`). A repeated Stop leaves
  the set as it is.
- **Continue**: the resume set plays from the held position (or the Song
  Position), plus the in-block offset `d` (D4).
- **Song Position**: accepted only while stopped with no capture, arm,
  count-in or queued action: it replaces the held position
  (`value / 4` quarter notes, folded into the loop). Otherwise it is refused,
  counted in the snapshot, and the page shows "Song Position ignored while
  playing" as a toast (the popup severity rule: low stakes).
- **Local presses** while a resume position is held: a local Play or Record
  clears the held position and resume set and behaves as today. Follow
  Play/Stop Off: Start, Stop and Continue are only relayed; Song Position is
  ignored.
- `LE_PLOG_CLOCK_TRANSPORT` (348) records each applied Start, Stop and
  Continue with the resume mask and position; `perf_render` replays it so a
  stem renders the resumed phase (the `LE_PLOG_SOURCE_TRANSPORT` precedent,
  `perf_log_ring.h:147`).

### D10. Waiting for clock

With an external source not Synced, a record press on an empty track becomes
an arm with trigger `CLOCK` (cue "Waiting for clock" on its track, UX doc
`:31-33`). A Sound start cannot fire it. It fires at the first quantize
boundary after Synced (Follow Off) or at the next Start's downbeat
(Follow On). Stop and clock loss cancel it (D5, D9).

### D11. Settings, sessions and ownership

- Sync settings are appliance settings (AB 7: "Appliance settings and external
  sync"): source id and name, Follow Play/Stop, loss policy, per-output
  `{clock, playStop, offsetMs}`, and Thru, in one envelope `midi.sync`, saved
  with exact-bytes confirmation and a restored checkpoint, the
  `saveMidiConfiguration` precedent (`settings_repository.dart:535-575`). A
  failed write keeps the previous settings and shows
  "Could not save. The previous setting is retained." (prototype copy).
- Defaults preserve today (rule 1): Internal, Follow Play/Stop Off, Keep
  playing, every output Clock Off, Thru Off. Nothing sends clock today, so
  nothing starts sending after the update.
- A saved source that is absent at boot stays selected and reads Waiting with
  "Reconnect the selected device." (`midi-sync-study.js` body); an unreadable
  envelope falls back to the defaults with a notice (rule 5).
- Sessions keep their own tempo: capture maps `TempoSource.external` to
  MANUAL at the current estimate rounded to 0.01 BPM
  (`session_mapping.dart:120`), so a session saved under clock reopens (today
  it would be rejected, `session_repository.dart:1261`). Reopening under an
  external source applies the session tempo, then the clock owns tempo again.
- `LE_ERR_EXTERNAL_CLOCK` (-20): `set_tempo`, `tap_tempo` and
  `restore_tempo` with a non-NONE source are refused while the source is
  external, at the call and again in the callback. The Loop settings tempo
  page shows the clock variant instead (`nfcC2`), so the refusal is a guard,
  not a user path.
- `LE_ERR_SYNC_LOCKED` (-21): changing the source while any track records,
  overdubs, is armed or counting in ("Finish recording to change source.",
  prototype copy).

### D12. The clock-mode tri-state goes

`le_clock_mode`, `le_engine_set_clock_mode`, `LE_CMD_SET_CLOCK_MODE` (48),
`a_clock_mode`, `le_snapshot.clock_mode` and their Dart bindings are removed
(AGENTS.md: no compatibility layers). Their roles split: the source is
`LE_CMD_SET_CLOCK_SYNC` (receive), sending is per output in the scheduler.
The send gate keeps Multi/Sync/Band and "transport active" (rule 1).

## 2. Native model

- `le_engine.midi_ports[LE_MAX_MIDI_PORTS = 8]` (shared with instruments):
  `_Atomic u32 a_gen`, `a_lost`, `a_overflow`, SPSC ring of 256
  `le_midi_port_event {u64 t_ns; u32 gen; u8 status, d1, d2}`.
- `le_engine.clock_sync` (audio thread): source slot and generation, follow,
  loss policy, receipt sequence (`LE_CMD_SET_CLOCK_SYNC` payload, one complete
  vector like `LE_CMD_SET_RECORD_TIMING`); the `le_clock_follow` state;
  `resume_mask`, `held_position`, held free-clock positions, `anchor`.
- Snapshot (appended): `clock_source_slot`, `clock_state`
  (0 internal, 1 waiting, 2 synced, 3 lost), `clock_bpm_display`,
  `clock_beat` (pulse count / 24, for the beat dots), `clock_follow`,
  `clock_loss_policy`, `clock_receipt`, `clock_resume_mask`,
  `clock_spp_refused`, `clock_losses`, `clock_send_late_ticks`,
  `midi_thru_overruns`, `midi_rt_denied`.
- Outputs: `le_engine_attach_midi_out(engine, slot, le_midi_out*, id)` and
  `detach`, under a mutex shared only with the scheduler thread (never the
  audio thread); a two-slot output table `{clock, play_stop, offset_ms}` per
  slot plus `thru` flag, published by the control thread and read by the
  scheduler.

## 3. Dart model

- `segno_engine`: a `ClockSync` role interface on `AudioEngine`
  (`setClockSync`, `setClockOutputs`, `attachMidiOutput`/`detach`), snapshot
  projection `ClockSyncSnapshot`, and the mock.
- `MidiDeviceRepository` (the instruments Part 4 registry): the clock source
  becomes a capture consumer next to the control device and instrument
  devices; outputs with Clock on, and DIN Out while Thru is on, are opened as
  `MidiOutClient`s and attached to the engine. Disconnected outputs stay
  configured with their state visible (UX doc `:37-38`).
- `SettingsRepository`: `loadMidiSync` / `saveMidiSync` (`midi.sync`).
- `LooperRepository`: applies the envelope to the engine with a receipt, maps
  -20 and -21, and projects clock state into `TransportSnapshot`.
- `MidiSyncCubit` (`lib/control/cubit/midi_sync_cubit.dart`): one owner of
  the page draft (offset edit with encoder draft, commit and Back cancel),
  write failures and the toast for refused Song Position.
- `TempoCubit` gains nothing: tempo and Tap are not offered under clock.

## 4. Parts

Production line counts exclude tests, generated bindings and docs. Every
native part runs the normal, ASAN and telemetry-off suites; parts touching
threads also run the TSAN races binary.

### Part 1. The shared MIDI input sink with real-time and timestamps (about 450 production lines; 200 if instruments Part 2c landed first)

`midi.c`: the quiescent engine sink (instruments D4: `_Atomic` sink and
context, in-flight counter, detach-and-spin, generation bump on close), the
real-time and Song Position kinds kept for the sink and filtered from the Dart
ring, the 16-byte timestamped entry. ALSA: SND_SEQ_EVENT_CLOCK, START,
CONTINUE, STOP, SONGPOS and PORT_EXIT converted (`midi_backend_linux.c:141-167`);
CoreMIDI: 0xF2 and 0xF8-0xFC routed to the sink (`midi_backend_apple.c:128-131`);
input threads at `SCHED_FIFO` 70 with the denial flag. Engine:
`midi_ports[8]`, `le_engine_attach_midi_in` / `detach`, the block-start drain
with overflow and lost handling (no consumer yet beyond counters, Part 2
adds the follower).

Tests (`src/test/test_midi_core.c`, `test_engine_core.c`, `test_engine_races.c`):
0xF8 at `t_ns = 1_000_000_000` reaches the port ring with that stamp and never
the Dart callback; F2 `0x10 0x00` decodes to 16; 300 pushes into 256 slots set
overflow and the audio thread counts it; a producer thread racing detach,
re-attach and destroy under TSAN never writes into a reused slot.

```success-criteria
GOAL: Every MIDI input backend delivers clock, transport and Song Position bytes with a monotonic timestamp into an engine port ring, through the same quiescent sink instruments use, while Learn and controls see exactly what they see today.
SUCCESS CRITERIA:
- Real-time and Song Position bytes reach the port ring with their producer timestamps (literal oracles: 0xF8 at 1_000_000_000 ns; F2 0x10 0x00 = 16) and never the Dart callback; Note/CC/Program still reach Dart unchanged. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Overflow sets the port flag and is counted; a lost port bumps its generation; normal, ASAN and telemetry-off suites pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Detach, re-attach and destroy race a producer without a data race. | verify: NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings regenerate and format; symbol parity holds; the C++ shim repro passes. | verify: packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && dart analyze --fatal-infos lib test packages
- HARDWARE: on the appliance, a USB-MIDI clock source's pulses arrive with interval jitter under 1.5 ms (p99) as logged by a test build. | verify: manual, appliance with a USB clock source; record the p50/p99 interval error in the PR.
NON-GOALS:
- The follower, note routing (instruments 2c), DIN serial (Part 7), Dart.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2. Clock follower, source command and tempo ownership (about 550 production lines)

`le_clock_follow.{h,c}` (D3), the time-source hook (D2), `LE_CMD_SET_CLOCK_SYNC`
(124) with receipt and `LE_ERR_SYNC_LOCKED` (-21), states and snapshot
fields, empty-rig tempo writes with `LE_TEMPO_SOURCE_EXTERNAL` (D4),
`LE_ERR_EXTERNAL_CLOCK` (-20) on set/tap/restore tempo, count-in skipped for
external starts (`le_count_in_begin`, `engine_process.c:374`), internal source
ignores incoming clock (D6), D12's removals (the existing clock-mode tests at
`test_engine_core.c:26802-27000` are rewritten to the new gate).

Tests (`src/test/test_clock_follow.h`): pulses every 20_833_333 ns
(120 BPM) with ±1 ms alternating jitter: Waiting until the seventh pulse, then
Synced; after two seconds `|bpm - 120| < 0.02` and the display reads `120.0`;
a step to 100 BPM (25_000_000 ns) reacquires within 10 pulses; an interval of
90 ms resets acquisition; silence for 250 ms at 120 BPM is Lost at the first
block past the deadline, but after 0xFC the same silence is Waiting; the lost
flag is Lost at once; set tempo returns -20 under external and applies under
internal; a source change while recording returns -21.

```success-criteria
GOAL: Selecting an external MIDI source makes it own the session tempo through a filtered estimate with visible Waiting, Synced and Clock lost states, and local tempo and Tap are refused while it does.
SUCCESS CRITERIA:
- The DLL meets the literal oracles above (acquisition on the 7th pulse, ±0.02 BPM after 2 s, reacquire within 10 pulses, invalid interval reset, 250 ms loss, Stop-then-silence is Waiting). | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Tempo ownership: -20 for tempo/tap/restore under external, -21 for a source change while capturing, armed or counting in; external starts add no count-in; internal ignores clock bytes. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The clock-mode tri-state is gone from header, engine, bindings and Dart; sanitizer and telemetry-off suites pass. | verify: ! grep -rn "le_clock_mode\|a_clock_mode\|set_clock_mode\|setClockMode" packages/segno_engine/src/core packages/segno_engine/lib && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: against a hardware drum machine and a DAW at 90, 120 and 174 BPM over USB, the displayed tempo is within 0.1 BPM of the master and stays still. | verify: manual, appliance; note master, displayed value and settle time per tempo in the PR.
NON-GOALS:
- Drift lock (Part 3), Follow Play/Stop (Part 4), loss handling of captures (Part 5), sending, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3. Phase anchor and drift lock (about 300 production lines; needs pitch/time Part 4a)

D4: the anchor (Start downbeat, Continue, local start with Follow Off), the
in-block offset `d`, and once-per-beat steering through 4a's retime with the
±0.1 % clamp; steering off while Lost; Free/Song left to 4a's scaling.

Tests (`test_clock_follow.h`): Multi, 4 bars at 120 BPM, sr 48000
(`clock.length = 384000`); the source runs at 120.006 BPM (50 ppm fast).
Without steering the phase error after 600 s of pulses would be 30 ms; with
steering it stays under 0.5 ms (24 frames) at every beat after the first 10 s,
and every retime moves `clock.length` by at most 0.1 %. A Start pulse 96 frames
before block start puts the clock at position 96. Follow Off: a local start
mid-beat anchors at the interpolated phase, and steering holds that offset.

```success-criteria
GOAL: Under an external clock the shared loop stays phase-locked to the master over a long performance, with every correction made through the single tempo-retime owner.
SUCCESS CRITERIA:
- Literal drift oracle: 50 ppm source over 600 s stays within 24 frames per beat after 10 s; retimes are at most one per beat and within ±0.1 %; Start offset d = 96 lands at position 96. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Following tracks keep identity at constant tempo; non-following tracks keep their recorded speed (4a detach); the perf log carries one tempo fact per correction and renderer parity holds. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: 10 minutes against a hardware drum machine over USB and over DIN, a recorded loop's onsets stay within 2 ms of the drum machine's in a two-track recording of both. | verify: manual, appliance + interface recording; attach the onset-offset plot to the PR.
NON-GOALS:
- Receive offset compensation (not in the accepted design), Follow Play/Stop, sending.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 4. Follow Play/Stop and Song Position (about 450 production lines)

D9 complete: Start, Stop with the resume set and held positions (the park
bypass at `engine_process.c:4834-4841`), Continue, repeated Stop, Song
Position with the stopped-and-idle guard and refusal counter, local presses
clearing the held position, Follow Off ignoring transport,
`LE_PLOG_CLOCK_TRANSPORT` (348) and its `perf_render.c` replay.

Tests (`test_clock_follow.h`): Multi, 8 bars at 120 BPM, sr 48000
(`clock.length = 768000`). Tracks 1 and 3 playing, 2 stopped by hand. Stop at
position 300000: tracks 1 and 3 STOPPED, resume mask `0b101`, held 300000 for
any number of blocks; a second Stop keeps `0b101`. Continue: 1 and 3 play from
300000 + d, track 2 stays stopped. Song Position 16 while stopped: held
96000 (one 4/4 bar); while playing: unchanged and `clock_spp_refused == 1`.
Start: tracks 1, 2 and 3 from 0 + d; an arm on track 4 starts recording at
the same frame; no count-in. A local Play while held clears the mask. Follow
Off: 0xFA/0xFC change nothing. A stem render of the session reproduces the
Continue phase byte for byte.

```success-criteria
GOAL: With Follow Play/Stop on, an external Start, Stop, Continue and Song Position drive Segno's loops exactly as accepted, and a performance capture replays them.
SUCCESS CRITERIA:
- The literal transport oracles above pass (resume mask 0b101, held 300000, SPP 16 -> 96000, refusal counted, Start plays all recorded tracks and fires the pending arm without count-in). | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Follow Off ignores transport bytes; local presses clear the held position; renderer parity for a Continue mid-loop. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: a DAW's Start, Stop, Continue and locate-then-Continue move the loops as above over USB and DIN. | verify: manual, appliance + DAW; list each step and the observed position.
NON-GOALS:
- Clock loss (Part 5), sending Song Position, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 5. Clock loss and Waiting-for-clock arms (about 350 production lines)

D5 and D10: detection actions in order, `le_cancel_pending_gestures` extracted
from `handle_cut_sound` and used by both, Keep and Stop policies,
`LE_PLOG_CLOCK_LOST` (350), reconnect that starts nothing, the `CLOCK` arm
trigger that Sound cannot fire, and `clock_losses` in the snapshot.

Tests (`test_clock_follow.h`): Multi, master 4 bars at 120 BPM, sr 48000
(384000). Track 2 starts recording at position 0; pulses stop at frame 48000;
loss is detected at frame 60000 (250 ms later). Track 2 is STOPPED with
length 384000, frames `[0, 60000)` equal to the input ramp and
`[60000, 384000)` zero. An arm on track 3 and a count-in are cancelled. Keep:
track 1 still PLAYING. Stop: track 1 STOPPED, resume mask `0b1`. Pulses
return: Waiting then Synced, and track 3 never records. Overdub at loss:
the pass closes as a Stop and is undoable with exact Redo. A defining take at
loss finalizes through the crossfade path with its measured length. A `CLOCK`
arm ignores a loud input and fires at the first boundary after Synced. Cut all
sound keeps its tail clearing (regression).

```success-criteria
GOAL: Losing an external clock mid-performance closes every take with its measured audio, cancels queued starts, obeys Keep playing or Stop loops, and a reconnect never records or starts music by itself.
SUCCESS CRITERIA:
- The literal loss oracle above passes (track 2: 384000 frames, [0,60000) = input, rest silent, STOPPED; arm and count-in cancelled; Keep vs Stop; reconnect records nothing). | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Overdub and defining-take loss, CLOCK arms immune to sound, Cut all sound unchanged; sanitizer and telemetry-off suites pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: unplug the USB clock source mid-overdub and pull the DIN cable mid-take; both takes are kept, playable and undoable. | verify: manual, appliance; record which policy was set and what played.
NON-GOALS:
- Held-take publication failure (E4-5), UI cues (Part 9b).
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 6. The MIDI-out scheduler: per-output send, offsets and relay (about 600 production lines)

D7: the per-block anchor (seqlock), `le_clock_send.{h,c}` pure due-time
computation, the scheduler thread, output attach and detach, the output table,
`L_out`, lookahead and rebase, Start/Stop/Continue bytes, per-output Clock and
Play/Stop, relay rings from the source input thread, echo exclusion (D6), the
late-tick counter; removal of `midi_clock_ring` and the block push.

Tests (`src/test/test_clock_send.h`, scheduler driven by `le_clock_send_due`
with a fake clock; a fake output backend records `(t_ns, bytes)`): 120 BPM, sr
48000 (1000 frames per tick, `P = 20_833_333.3` ns), `L_out = 128/48000 s`
(2_666_667 ns), anchor `t_block = 1_000_000_000` at `frames_since_start = 0`.
Offset 0: tick 3 due at `1_062_500_000 + 2_666_667 = 1_065_166_667`; offset
-7 ms: `1_058_166_667`; offset +10 ms: `1_075_166_667`; ±1 ns rounding. With
-7 ms the Start byte (due 995_666_667, before the anchor) goes out at once and
tick 1 (due 1_016_500_000) and every later tick on time; with -10 ms and a
4096-frame desktop period (`L_out` 85.3 ms) nothing is late. A tempo change to 60 BPM at frame 2500
rebases ticks 3 and up; ticks 1 and 2 stand. Play/Stop off: no 0xFA/0xFC, ticks only while
running. Song and Free modes: nothing. An output with the source's id gets
nothing, and relay forwards 0xF8 to every other Clock output with offset 0 at
the arrival wake. 10 000 ticks under ASAN leave no growth; a detach while the
thread sends is clean under TSAN.

```success-criteria
GOAL: Internally generated clock goes out to each chosen output with its own offset measured from the audible output, external clock is relayed with its received timing, and nothing is ever sent back to the clock source.
SUCCESS CRITERIA:
- Due-time oracles: tick 3 at 1_065_166_667 / 1_058_166_667 / 1_075_166_667 ns for 0 / -7 / +10 ms; a past-due Start byte goes out at once and the ticks after it are on time; rebase on tempo change keeps sent ticks. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Per-output Clock and Play/Stop, Song/Free silence, echo exclusion, relay with offset 0, bounded queues and no allocation on the audio thread. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- Attach/detach races the scheduler without a data race. | verify: NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
- The retired ring and block push are gone; symbol parity holds. | verify: ! grep -rn "midi_clock_ring" packages/segno_engine/src && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)"
- HARDWARE: a DAW slaved to Segno over USB and over DIN; a loopback recording of the click against the DAW's metronome shows tick jitter under 1 ms p99 and offsets of -10, 0, +10 ms moving the DAW by that amount within 0.5 ms. | verify: manual, appliance; attach the measurement.
NON-GOALS:
- DIN serial and Thru (Part 7), Dart, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 7. DIN serial port, Thru and UART0 in the image (about 450 production lines; closes #1069)

D8: `midi_backend_serial.c` (termios2 31250 8N1 raw, running-status parser,
SysEx skip, real-time interleave, reader at `SCHED_FIFO` 70, timestamps,
`din:` dispatch in `le_midi_open`/enumerate, output writes through the Part 6
scheduler), the Thru ring and eventfd wake, Thru suspending generated and
relayed sync on DIN Out, the engine config's serial path; Yocto
`dtoverlay=uart0-pi5` at `kas-segno-rpi5.yml:137` and the udev permission.

Tests (`test_midi_core.c`, against a pseudo-terminal pair): `90 3C 64 3C 00`
(running status) yields Note On 60/100 then Note Off 60; `90 F8 3C 64` yields
a timestamped 0xF8 then Note On 60/100; `F0 7E 01 F7 B0 07 7F` skips the SysEx
and yields CC 7 = 127; a dangling data byte after reset is dropped. Thru:
those bytes come out of the output side unchanged and once; with Thru on, the
scheduler sends no generated or relayed 0xF8 to DIN, and does to other
outputs.

```success-criteria
GOAL: The console's DIN MIDI In and Out are ordinary MIDI ports to the app, carrying controls, notes, clock and Thru, from a cold boot, without touching the pedal link.
SUCCESS CRITERIA:
- Parser oracles above (running status, interleaved real-time, SysEx skip, dangling data) and Thru byte equality with no duplicate sync pass on a pty. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and race suites pass with the reader and scheduler threads. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
- HARDWARE: on a freshly built image, /dev/ttyAMA0 exists after a cold boot with no manual step; hardware/bench/midi_din_test.py passes without loading an overlay; notes into DIN IN reach MIDI Learn; Segno clock leaves DIN OUT; the pedal link on /dev/ttyAMA3 still drives pedals and LEDs. | verify: manual, appliance; the #1069 acceptance list ticked in the PR.
- HARDWARE: DIN Thru from a keyboard to a synth plays every note once, with added latency under 1 ms, and with Thru on the synth receives no Segno clock. | verify: manual, appliance + keyboard + synth.
NON-GOALS:
- MIDI Learn changes, a second DIN port, USB gadget MIDI (out of scope by owner decision).
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 8. Dart seam, repositories and settings (about 650 production lines)

Section 3 complete without UI: the `ClockSync` role interface and mock,
`ClockSyncSnapshot`, `midi.sync` load/save with checkpoint restore and the
defaults (D11), the registry's clock-source capture and output attachment
(instruments Part 4), `LooperRepository` applying the envelope with a receipt
and mapping -20/-21, session capture mapping external to MANUAL
(`session_mapping.dart:120`), `TransportSnapshot` clock fields, and
`MidiSyncCubit` (state, draft offset edit, commit, cancel, write failure,
Song Position toast event).

Tests: `packages/settings_repository` round trip, malformed envelope falls back
with a notice, a refused write restores the checkpoint;
`packages/looper_repository` against the native library: selecting a source
publishes the receipt, a source change while recording surfaces `syncLocked`,
the snapshot projects every state; session capture under external writes
MANUAL 120.00 and reopens; `MidiSyncCubit` bloc tests for each transition, the
offset clamp at ±10 and the zero reset.

```success-criteria
GOAL: The app persists and applies MIDI sync settings through one owner, attaches the right input and outputs natively, and sessions saved under an external clock reopen.
SUCCESS CRITERIA:
- Settings envelope round trip, defaults equal today's behaviour (Internal, Follow Off, Keep, all outputs off, Thru off), refused writes restore the checkpoint. | verify: (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Repository against the native engine: receipts, -20/-21 mapping, snapshot projection, source capture and output attach on hotplug. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/midi_device_repository && /Users/Tomas/development/flutter/bin/flutter test)
- External tempo saves as MANUAL and reopens; MidiSyncCubit transitions, clamp and reset. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session test/control
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Screens (Part 9a/9b).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 9a. The Clock & sync page and the Controls / Sync tabs (about 550 production lines)

`lib/control/view/midi_sync/midi_sync_page.dart` in a `LoopSettingsFrame`,
matching `fkLOU`, `yMhnp`, `ipK6w`, `q85IK`, `OeIN1`, `bXxAY`, `YPTg6`: the
Tempo source row (Internal plus devices, "Disconnected" sublabel, locked with
"Finish recording to change source."), the readout (BPM or `—`, state, hint,
beat pulse from `clock_beat`), Follow Play/Stop and If clock is lost (external
only), Use internal tempo (lost only), Send sync cards per output (Clock,
Play/Stop requiring Clock, offset with touch and encoder draft, zero reset;
"Receiving clock" on the source's output; offsets disabled with the external
note), MIDI Thru with its two notes. The Controls / Sync tab pair is added to
both MIDI pages (section 26 headers); Back and Stage behave as in
`MidiControlsPage` (`midi_controls_page.dart:157-180`). EN and ES strings.
The simulation footer is not drawn.

Tests: widget tests for each of the seven states from a seeded cubit, the
locked source row while recording, the offset draft (encoder turn, commit,
Back cancel), Play/Stop disabled until Clock, the source's output disabled,
Thru note; goldens for the seven screens at 1920 x 1080.

```success-criteria
GOAL: The Clock & sync page shows and edits exactly what the engine and settings hold, in the seven accepted states, reachable from the MIDI Controls header.
SUCCESS CRITERIA:
- Seven states render as in the pen (fkLOU, yMhnp, ipK6w, q85IK, OeIN1, bXxAY, YPTg6) without the simulation footer; goldens updated and eyeballed on the author's machine. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/view/midi_sync && /Users/Tomas/development/flutter/bin/flutter test test/screenshots --update-goldens
- Locks, offset draft and cancel, Play/Stop requiring Clock, echo-disabled output, tab navigation and Stage return. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: on the appliance, edit an offset with the encoder and cancel with Back; select a disconnected device; pull the source cable and see Clock lost within half a second. | verify: manual, appliance.
NON-GOALS:
- Main-view chip, Loop settings variants, track cues (9b).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 9b. Main-view sync status, Loop settings under MIDI clock and track cues (about 400 production lines)

`StageTopBar` chip "MIDI synced" / "Waiting" / "Clock lost" opening the Sync
page (`PMu8D`); `loop_tempo_page.dart` clock variant (banner "Tempo follows
MIDI clock.", Clock & sync button, readout labelled MIDI clock with four beat
dots, slider and Tap disabled, time signature, Hear click and Count-in
unchanged, `nfcC2`); Audio & tempo note "Recorded audio follows MIDI clock."
under an external source (`JQpGt`); length pages unchanged and verified under
clock (`IEttC`, `FrsRF`); track cues "Waiting for clock" (D10) and
"Clock lost · Captured / audio kept" (`Lqfa3`); the Song Position refusal
toast. EN and ES.

Tests: widget tests for the chip per state and its navigation, the tempo page
clock variant (Tap and slider not interactive, banner button opens Sync), the
audio-tempo note, the two cues from seeded snapshots; goldens for `PMu8D`,
`nfcC2`, `JQpGt`, `Lqfa3`.

```success-criteria
GOAL: Wherever tempo or recording is shown, the performer sees that an external clock owns it, and what happened when it was lost.
SUCCESS CRITERIA:
- Chip, tempo-page variant, audio-tempo note, length pages and both track cues match the pen screens named above; goldens updated and eyeballed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper && /Users/Tomas/development/flutter/bin/flutter test test/screenshots --update-goldens
- Tap and the slider cannot change tempo under clock; the Song Position toast appears once per refusal. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/loop_settings
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: with a drum machine as source, the chip reads MIDI synced, the tempo page follows the drum machine, and a take cut by pulling the cable shows the Clock lost cue on both displays. | verify: manual, appliance.
NON-GOALS:
- New settings beyond the accepted screens.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Dependencies and sequencing

```
Part 1 sink (or instruments 2c)
  ├─ Part 2 follower ─┬─ Part 3 drift lock  (also needs pitch/time Part 4a)
  │                   ├─ Part 4 Follow Play/Stop + SPP
  │                   └─ Part 5 loss + CLOCK arms
  └─ Part 6 scheduler (relay needs Part 2's source) ── Part 7 DIN serial + Thru + UART0
Parts 2-7 + instruments Part 4 registry ── Part 8 Dart ── Part 9a page ── Part 9b main view
```

- Parts 4, 5 and 6 are independent of each other after Part 2 and can be
  built in parallel; Part 5 lands after Part 4 if both touch the held-park
  bypass (Part 5's Stop loops reuses it).
- Part 3 waits on pitch/time Part 4a, which waits on its Pi render gate. Part
  9a lands after Part 3: selecting an external source with recorded loops is
  only offered once the loops stay locked. Until then no screen can select a
  source, so no user-visible state is unfinished.
- Part 8 needs the instruments Part 4 registry; if that slips, Part 8 builds
  the registry to that plan's text and instruments rebases (rule 4).
- Native parts rebase onto Reverse and pitch/time where they touch
  `advance_transport_frame` and `le_tempo_locked`; facts and commands keep the
  ledger numbers above.

## 5. Decisions taken under the standing rules

1. One input path for notes, controls and clock: the instruments sink plus a
   timestamp (rule 4).
2. DLL tracking after a median acquisition, B = 0.5 Hz, reacquire on a
   three-pulse step (D3).
3. Drift lock through pitch/time 4a's retime, once per beat, clamped ±0.1 %
   (rule 4: one owner of length rescaling).
4. Loss closes takes at detection through `handle_stop` and cancels queued
   starts through the helper shared with Cut (rules 2 and 4).
5. One scheduler thread is the only writer of every MIDI output; offsets are
   measured from the audible output (`L_out`) (rule 4).
6. DIN is a native serial port (answers #1069) (rule 4).
7. Defaults keep today's behaviour: nothing sends, Internal source (rule 1).
8. An unreadable `midi.sync` falls back to defaults with a notice (rule 5).
9. Start plays every recorded track; local presses clear a held MIDI
   position; Follow Off relays transport but does not act on it (D9).
10. The clock-mode tri-state is removed, not kept beside the new commands
    (AGENTS.md).
11. Sessions saved under external clock store a MANUAL tempo (rule 2: they
    must reopen).

## 6. Risks

- The relay and Thru paths add a userspace hop; the hardware criteria in
  Parts 6 and 7 measure it. If DIN Thru latency exceeds 1 ms, the follow-up is
  a reader-side direct write with the scheduler suspended for DIN, not a
  second writer.
- `L_out` from the driver ignores codec and converter delay; the offset
  absorbs it, and Part 6's hardware measurement records the remainder.
- Part 3 depends on 4a's retime staying cheap at one call per beat; Part 3's
  native test measures the retime path's block time with telemetry on.

## 7. Hardware-only evidence

Collected in one appliance session per part (USB clock source, DIN cable,
hardware drum machine, DAW, synth): interval jitter (Part 1), tempo settle
(Part 2), 10-minute lock (Part 3), DAW transport (Part 4), unplug mid-take
(Part 5), sent-clock jitter and offsets (Part 6), cold-boot DIN and Thru
(Part 7), encoder and loss on the page (Part 9a), chip and cues on both
displays (Part 9b). "Green in CI" does not close these.

## 8. Pen write-back list (for the owner; this plan never edits the pen)

- Remove "Timing simulation · no MIDI messages are sent to hardware." from
  the 27 and PARITY Clock screens.
- Add the "Song Position ignored while playing" toast and the "Waiting for
  clock" track cue, which the UX doc specifies but no screen draws.
- Note on 27/01 that DIN appears only on the appliance (desktop builds list no
  serial port).

## 9. Genuine product-direction questions

None. Every open point above is decided under the standing rules or by the
accepted documents. The receive-side alignment (D4) leaves the device output
latency uncompensated, because the accepted design defines only a sender
offset; Part 3's hardware run measures that residual, and a receive offset
would be a new owner decision only if the measurement shows it is audible.
