Model: Claude Opus (subagent), in-session

# Review of PR #1236 (origin/claude/midi-clock-plan-1228 @ cfa8725f5): docs(plan): MIDI clock receive, send and the MIDI Sync page

## Scope

- Plan: `docs/plan/2026-10-06-feat-midi-clock-plan.md` (992 lines, the only file in the PR).
- Baseline: trunk `097e1ef68` (origin/claude/segno-integration).
- Checked against:
  - AGENTS.md and the owner rules;
  - accepted-behavior.md sections 2.4, 2.6-2.9, 2.12, 7.1, 7.3 and 7.4;
  - the four untracked design docs in the main checkout (`2026-09-07-midi-sync-ux.md`, `midi-sync-study.js`, `2026-09-09-timing-completion.md`, `2026-09-08-appliance-parity-correction.md`);
  - the pitch/time plan on trunk (Part 4a, sections 2.5 and 4.2-4.3);
  - the instruments plan at origin/claude/instruments-plan-1197 `27fa7d945` (PR #1204);
  - the instruments plan review, `1197-plan-review/review.md` (H2 and the delta findings D2 and D5);
  - segno-ui.pen, group "01 CURRENT UX", read only through the pencil MCP and never saved: section 27, the PARITY Clock screens, section 26, section 53, and screens 05/08, 06/04, 06/09, 07/07 and 51;
  - the Yocto image config (`kas-segno-*.yml`, `segno.service`, `segno-bundle.bb`), #1069, and the DIN bench README and research note.
- Every file:line citation in the plan was opened on trunk. Results are under L1.

## Runs

- **Probe 1: the existing clock generator** (`first_tick.c`, kept beside this review).
  - It drives `le_midi_clock_advance` at 120 BPM, 48 kHz, in 128-frame blocks.
  - Result: Start (0xFA) goes out in the block at frame 0. The first 0xF8 goes out in the block at frame 896, which contains frame 1000, so it is one pulse after Start. See H3.
- **Probe 2: the plan's D3 follower** (`dll.c`). This is a literal transcription of D3:
  - median-of-six acquisition;
  - a second-order DLL with B = 0.5 Hz;
  - re-acquisition after three same-sign pulses with |e| > max(1.5 ms, 0.1·P).
  - Each run lasts 60 s at 90, 120, 124.9 and 174 BPM.

  Results at 120 BPM:

  | Jitter model | Re-acquisitions | Max tempo error (after 5 s) |
  |---|---|---|
  | the plan's alternating ±1 ms | 0 | 0.013 BPM |
  | uniform random ±1 ms | 0 | 0.117 BPM |
  | 1 ms USB-frame quantisation | 0 | 0.013 BPM (0.094 at 124.9 BPM) |
  | pulses quantised to a 512-sample / 44.1 kHz block edge | 590 | 12.3 BPM (41-48 BPM at 174 BPM) |
  | the same block-edge model with re-acquisition disabled | 0 | 0.30 BPM |

  See M1.
- No suites were run. The PR changes only a document, and no code path changes.

## Verified correct (traced)

- **The send side reaches nothing today.**
  - `midi_clock_ring` has no consumer: the only pop is the test's `clock_drain`, `test_engine_core.c:26809`.
  - Nothing outside `packages/midi_client` constructs `MidiOutClient`.
  - `le_engine_set_clock_mode` rejects RECEIVE (`engine_commands.c:3292`).
- **Input filtering.**
  - The ALSA read loop converts only NOTEON, NOTEOFF, CONTROLLER and PGMCHANGE (`midi_backend_linux.c:141-167`).
  - It stamps `CLOCK_MONOTONIC` in µs and runs on a default-priority thread (`:246`).
  - CoreMIDI drops 0xF1-0xFF.
  - The device id is the ALSA client name (`:82`, `:312`).
- **Numbering.**
  - Commands 124-131, facts 348-351 and errors -20 and -21 are free on trunk and on every branch checked. The highest values in use are command 83, fact 325 and error -9.
  - The retired command gaps are exactly 18, 51, 52 and 60.
  - There is no ledger document in the repo to check the ranges against. Other plans cite the same "main session" ledger.
- **Accepted behaviour.** The paraphrases of AB 7.3, 7.4 and 2.12 are faithful. Nothing is omitted or contradicted. 2.12's held-take sentences are correctly deferred to E4-5.
- **Arithmetic.** Every worked number checks:
  - the 8.3 ms pulse at 300 BPM and 7/24 = 0.29 beat;
  - 384000 and 768000 frames;
  - SPP 16 = 96000 frames;
  - 30 ms of drift from 50 ppm over 600 s;
  - 60000 = 48000 + 250 ms;
  - all six Part 6 due-time oracles, to the nanosecond.
- **The DLL equations** match Adriaensen's form: `t1 += b·e + P; P += c·e` with `ω = 2πB·P`. They are stable over 30-300 BPM, with ω between 0.026 and 0.26.
- **The pen.**
  - Every node id in the table resolves to the screen the plan means.
  - The "Timing simulation" footer is on five of the six section-27 screens and on both PARITY Clock screens. 27/06 `PMu8D` does not carry it.
  - "Waiting for clock" and the Song Position toast are drawn nowhere, as the plan says.
- **The loss sequence works with Cut's code.** `request_master_finalize` defers through `xfade_capture`, not through a pending field. So calling `handle_stop` before the pending-gesture clear (the reverse of Cut's order) does not cancel the deferred finalize. The launch cohort is cleared by `le_count_in_reset` (`engine_process.c:346-368`), which Cut calls at `:2234`.
- **The sessions defect is real.** `session_mapping.dart:120` copies the live source verbatim. `session_repository.dart:1261` and `looper_repository.dart:3790` reject `external`.
- **The pedal link and UART0 do not overlap.** The pedal link is UART3 on GPIO8/9 (`kas-segno-rpi5.yml:137`). UART0 is GPIO14/15. #1069 and the bench README confirm the image already carries the `uart0-pi5` overlay file.

## Findings

### High

**H1. Drift correction through pitch/time Part 4a cannot work as specified, and it gates the whole feature.**

D4 corrects drift with one 4a retime per beat (`plan:335-347`). The 4a text on trunk forbids or breaks this in four ways.

1. **No retime during capture.**
   - 4a refuses a tempo change "while any track is RECORDING, OVERDUBBING, armed ... or in a count-in" (`pitch-time-core-plan.md:391-394`). Section 4.2 repeats this: "the lock still holds during a count-in and while any track captures or is armed" (`:603-604`).
   - Failure: a three-minute overdub against a drum machine gets no drift correction and does not follow a DAW tempo change. When the pass ends, a large retime lands all at once.
   - D4 does not mention this guard.
2. **No overdub after a correction.**
   - 4a refuses overdub on a track whose `len_src != play_len` (`:386`).
   - After the first ppm correction, every following track has `play_len != len_src`.
   - Failure: within a beat of reaching Synced, Overdub is refused with `LE_ERR_TRANSFORMED` on every recorded track, and stays refused while the clock owns tempo.
3. **Follow tempo Off is undefined.**
   - 4a ships `a_follow_tempo` defaulting to 0 (`:587-589`). It keeps per-track Off overrides, and the pen draws "Recorded audio follows MIDI clock." only under Follow tempo On (07/07, screen `BFfDT`).
   - With Follow Off, 4a does not retime, so the lock cannot act.
     - The loop keeps its recorded length.
     - The external tempo owns the click and the quantize grid.
     - The two diverge. A human-timed defining take is typically about 0.5 % off whole bars, which is far beyond D4's ±0.1 % clamp.
   - With a per-track Off, the track detaches at the first ppm correction (`:606-613`). It then runs at the interface clock and drifts by the error the lock removes from the other tracks. At 50 ppm that is 30 ms after 10 minutes.
   - The plan states no behaviour for any of these cases. It also says it has "no genuine product-direction questions" (section 9), but this is one.
4. **Identity is lost at constant tempo.**
   - Part 3 requires "Following tracks keep identity at constant tempo".
   - With the master's crystal tens of ppm from the interface's, the corrected tempo never equals the recorded one. Every following track is therefore read through the varispeed head permanently.
   - The 4-frame length quantum (`:592-595`) also makes `clock.length` alternate between values once per beat or so.

The sequencing makes this worse:
- Part 9a, the only screen that can select a source and also the only screen for Send sync, Thru and offsets, lands after Part 3.
- Part 3 waits on 4a and its Pi render gate (`plan:925-928`).
- So DIN Thru and sending clock, which do not depend on 4a, are blocked behind it.

Fix:
- Correct ppm drift with a follower-owned phase correction that needs no resampling. For example, at each master wrap, slip or repeat the measured |Δ| frames under the existing seam crossfade. This keeps every track, including Follow Off and detached ones, on the shared position. It works during overdubs, and it adds no `len_src`/`play_len` mismatch.
- Use 4a only for real tempo changes above a threshold.
- State what happens to tempo following while capturing.
- Ask the owner what external clock means under Follow tempo Off. Either refuse an external source with content while Follow is Off, or keep the length and phase-correct only.
- Split 9a: ship send, Thru and offsets with the Internal source first, and add source selection after Part 3.

**H2. The follower's tempo ignores the time-signature denominator.**

- The engine's tempo unit is the denominator note: "BPM counts denominator notes per minute" (`tempo_grid.h:11-13`, `:48-50`). `le_midi_clock.h` says the same, which is why the sender converts through `LE_GRID_DIV_QUARTER`.
- MIDI clock is 24 pulses per quarter note.
- D3 publishes "The engine tempo is `60e9 / (24·P)` BPM" (`plan:306`). That is quarter-note BPM.
- Failure:
  - In 6/8 or 7/8 the engine grid, click and quantize run at half the master's tempo. In x/2 meters they run at double.
  - The valid-interval window (`plan:290-293`) is derived from the engine's 30-300 clamp, so a 160-BPM quarter clock in 6/8 (320 engine BPM) would be clamped or rejected.
  - The same unit error reaches the SPP conversion ("value / 4 quarter notes" folded into the loop), `clock_beat` ("pulse count / 24") and the display.
- The UX doc keeps time signature local under clock (`:15-17`), so this configuration is accepted.
- The plan's oracles all use 4/4, so none of them catches it.
- Fix:
  - Engine BPM = `60e9/(24·P) × ts_den/4`.
  - The clamp window scales by `4/ts_den`.
  - SPP and `clock_beat` convert through quarter-note frames.
  - Add a 6/8 oracle to Parts 2 and 4.

**H3. Sent clock puts the downbeat one pulse late, and the offset range cannot correct it.**

- D4's receive rule is that "the first Timing Clock after Start is the downbeat" (`plan:319-321`).
- The generator D7 keeps emits Start at the transport edge and the first 0xF8 one interval later. Its own comment says "the first tick lands exactly one PPQN interval after THIS Start" (`le_midi_clock.c:30-33`). Probe 1 confirms this.
- Part 6's oracle encodes the same schedule: tick 1 is due at `t_block + P + L_out + offset`.
- Failure:
  - A slaved DAW or drum machine, or Segno receiving from Segno, plays its bar one pulse after Segno's: 20.8 ms at 120 BPM, 31 ms at 80 BPM.
  - The −10…+10 ms sender offset (AB 7.4) cannot absorb that below 250 BPM.
  - Part 6's hardware criterion measures only that the offsets move the DAW. It does not check absolute alignment.
- Fix:
  - Emit tick 0 at the Start frame, with Start at least 1 ms before it per MIDI 1.0. Schedule Start at the tick-0 due time minus 1 ms.
  - Change the Part 6 oracles to tick k at `k·P`, k ≥ 0.
  - Add a loopback oracle: Segno-to-Segno lands on the same frame.

**H4. Reopening a session under an external clock fails, which contradicts D11's own fix.**

- D11 says "Reopening under an external source applies the session tempo, then the clock owns tempo again" (`plan:542-543`).
- D11 also refuses `restore_tempo` with a non-NONE source while the source is external, with -20 (`plan:544-546`).
- Session open restores tempo through `_requireSessionSetting(_engine.restoreTempo(...))` (`looper_repository.dart:4007-4009`). `_requireSessionSetting` throws on any non-OK result (`:7899-7903`).
- Failure: with a USB clock source selected, opening any session that has a tempo (now including the MANUAL ones this plan writes) throws "session setting could not be restored", and the session does not open.
- The device-restart replay at `:2549` has the same conflict. It ignores the result, so the call fails without any report.
- Fix: choose one rule and test it in Part 8.
  - (a) Under an external source, session restore skips the tempo apply. The loop's bars and length restore, and the follower's tempo owns the grid.
  - (b) Or `restore_tempo` is exempt from -20 and the follower overwrites it at the next beat.
  - Add a looper_repository test: "open a session while the source is external".

### Medium

**M1. The re-acquisition rule trips continuously on real clock sources, and the jitter oracle is too easy.**

- **The test jitter.** Part 2's ±1 ms *alternating* jitter is a Nyquist-rate signal, which any loop filter removes.
- **Uniform random jitter.** Uniform ±1 ms gives 0.10-0.14 BPM of estimate wander (Probe 2). The Part 2 oracle (`< 0.02 BPM`) then fails, and the 0.05 BPM display hysteresis lets the readout flicker. That contradicts "stays still".
- **Coarsely quantised sources.** Some sources emit clock only at block or control-rate edges: software that sends clock per audio buffer without sub-buffer timestamps, or hardware with a few-ms control loop.
  - The rule "three same-sign pulses beyond max(1.5 ms, 0.1·P)" then re-acquires 500-990 times a minute.
  - The tempo jumps by 12-48 BPM.
  - With re-acquisition disabled, the same DLL holds within 0.3 BPM.
- **Re-acquiring after a real tempo step.** The window is "the last six intervals", which then holds three old and three new intervals. A 120-to-100 step therefore re-seeds P at the mean of the two periods (22.9 ms), not at 25 ms.
- Fix:
  - Scale the step threshold to a running estimate of |e| (for example 4σ, with at least 2 ms).
  - Require more consecutive outliers.
  - Re-seed from the intervals since the first outlier.
  - Use a seeded uniform-jitter oracle and a block-quantised oracle.
  - Run Part 1's hardware jitter measurement with the UI under load, not idle.

**M2. Missed pulses shift the bar phase permanently.**

- D3 handles an overflow by "dropping the last timestamp, so no interval spans a gap" (`plan:292-293`).
- That does not prevent the gap interval:
  - the flag is handled at block start;
  - the queued pre-overflow pulses then drain;
  - the next real pulse produces a 2P interval.
- At 120 BPM, 2P (41.7 ms) is inside the valid window (upper bound 85 ms), so the pulse is accepted as one pulse.
- The same happens for any single 0xF8 lost on USB or to a DIN framing error.
- The follower counts pulses for the anchor, drift lock, `clock_beat` and SPP. Failure: the count falls one behind, and the drift lock then steers the loop toward a phase one pulse wrong, at the ±0.1 % clamp, for about 20 s.
- This is the same ordering hole as the instruments delta review's D2.
- Fix:
  - Count `k = round(Δt / P)` pulses per interval once Synced.
  - Feed the DLL the per-pulse error.
  - Have the producer record the ring position of the overflow, as the instruments D2 fix proposes.
  - Test with one pulse dropped from a 120 BPM stream.

**M3. There is no re-anchor rule after Waiting or Lost returns to Synced.**

- The anchor is set at Start (Follow On) or at the local transport start (Follow Off) (`plan:319-325`).
- After a gap, the anchor's pulse count does not cover the pulses that were missed. This happens after a Stop-then-silence Waiting, a cable pull, or a master that stops sending while stopped.
- Failure, with Follow Off: when clock returns, φ is arbitrary (up to half a beat). The ±0.1 % clamped lock then bends the loop's speed for up to 250 s to reach a target that means nothing.
- Fix:
  - On every transition into Synced without a Start, re-anchor at the current interpolated phase. That holds the existing offset.
  - Only a Start or Continue (Follow On) re-anchors to the master's bar.
  - Add a test for each case.

**M4. The scheduler's wake mechanism does not work as written, and the relay adds jitter.**

- **The wake.** D7 sleeps in `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)` and has "Thru wake it through an eventfd" (`plan:433-435`). `clock_nanosleep` returns early only on a signal. An eventfd write cannot wake it, so Thru waits for the next 1 ms poll.
- **The relay.** It has no wake at all ("sends them on the next wake", `:442-445`). It therefore adds 0-1 ms of uniform jitter, against AB 7.4's "relay preserves received timing".
- **macOS.** The Darwin dev host and native test build compile the engine, and neither `clock_nanosleep` nor `eventfd` exists there.
- **The anchor time.** The anchor is the raw callback start time. Callback wake jitter therefore goes straight into every extrapolated due time. The Adriaensen DLL the plan cites for MIDI is exactly what JACK uses to filter period times.
- Fix:
  - Block in `ppoll`/`epoll_pwait2` on an eventfd plus an absolute `timerfd`. Have both the relay and Thru producers signal it.
  - Give Darwin a shape: a condition variable with an absolute time, or CoreMIDI timestamped sends.
  - Filter `t_block` against `frames_since_start` with a DLL before extrapolating.

**M5. The sent tick phase is wrong after any retime.**

- D7 derives ticks from `frames_since_start` (`plan:414-418`).
- 4a's retime scales `clock.position` to keep musical phase (`pitch-time-core-plan.md:596`). `frames_since_start` is not scaled.
- After a tempo change while running, the tick index `frames/fpt_new` jumps. Probe 1 at 120→121 BPM after 10 s: the index goes from 480 to 484.
- Emission then sits a fraction of a pulse off the loop's beats, anywhere in [0, 1) pulse. That is up to 20.8 ms at 120 BPM, again beyond the offset range.
- The Part 6 "rebase" oracle (tempo change at frame 2500) cannot detect this, because it never checks the loop's beat positions.
- Fix: publish the musical tick phase in the anchor (`ticks_at_block_start` as a fraction, and `frames_per_tick`), and schedule from that.

**M6. Clock loss through `handle_stop` can discard measured audio in Sync and Band.**

- D5 says `finalize_new_track` "keeps the measured material ... and pads the lap with silence" (`plan:362-365`). That is true only on the Multi/auto path.
- With `le_sync_quantize_active`, `finalize_new_track` calls `le_sync_choose_ratio`, which rounds to the *nearest* ratio, and can round down. The engine comment says so: "it can round DOWN a take that ran long, truncating" (`engine_process.c:1167-1172`, `:1389-1403`).
- Failure: a Sync-mode take at 1.4× the primary when clock is lost finalizes at 1×, and 0.4× of captured audio is gone. AB 2.12 and timing-completion `:82-84` require the measured partial material to be kept.
- Part 5's oracle tests only Multi.
- Fix:
  - On loss, finalize Sync/Band takes with round-up, or keep the captured length as a held take.
  - Add a Sync-mode loss oracle.

**M7. The DIN/UART0 design does not address the console UART or the kernel's latency path.**

- **The console UART.** The plan does not check that nothing else claims GPIO14/15.
  - Check that the image puts no kernel console or getty on `ttyAMA0`. The cmdline is `console=tty3` (`kas-segno-common.yml:111`). `serial-getty@ttyS0` already had to be masked for a 90 s boot hang (`segno-bundle.bb:337-340`). `SERIAL_CONSOLES` and the firmware's serial alias are not pinned.
  - Check that boot firmware or `earlycon` sends nothing out of GPIO14. Bytes on DIN OUT at boot reach whatever synth is connected.
  - Add to Part 7: `/proc/consoles` has no ttyAMA0; `systemctl status serial-getty@ttyAMA0` is masked or absent; a MIDI monitor on DIN OUT sees no bytes from power-on to app start.
- **Timestamp latency.** D1 and D8 claim a `SCHED_FIFO` 70 reader means "a busy UI cannot delay a timestamp". The bytes pass through kernel stages that are not at that priority:
  - the PL011 RX FIFO, whose receive-timeout interrupt fires after about 32 bit periods, about 1 ms at 31250 baud;
  - the tty flip-buffer work;
  - for USB, the rawmidi event work that feeds the sequencer.

  Both work items run on normal-priority kworkers.

  Fix:
  - Part 7 needs a hardware DIN interval-jitter measurement with the UI loaded. Today only USB is measured (Part 1).
  - Consider the kernel-stamped rawmidi framing mode for USB inputs.
- **The serial path.** It comes "from the engine config" (`plan:467-469`), but `le_midi_enumerate`/`le_midi_open` are engine-independent. Name the module-level setter and the Dart call that sets it on the appliance.
- **Permissions.** See L4.

**M8. The two plans do not yet describe one sink.**

- **Ring entry layout.**
  - This plan: a 16-byte `{u64 t_ns; u32 gen; u8 status, d1, d2}` (`plan:243-244`).
  - The instruments plan, current head `27fa7d945`, §2.2: still `{u32 gen; u8 status, d1, d2}`, with no timestamp and no real-time kinds.
  - Whichever lands first, by its own text, builds a ring the other must change. "The other rebases" (`plan:256-259`) is two designs, not one (rule 4).
- **H2 quiescence.**
  - Part 1 names the in-flight counter, detach-and-spin, generation bump and TSAN race test, which matches instruments D4.
  - It does not state the memory order the instruments delta review asked for (D5): increment before loading the sink, and seq_cst on both store-load pairs. Without that, arm64 can let both sides miss each other.
- **New producer writes.** This plan adds two writes from MIDI threads into engine-owned memory: the per-output relay rings (D7) and the DIN Thru ring (D8). Neither is placed inside the in-flight bracket. Failure: a source change or engine destroy while the old source thread pushes a relayed 0xF8 is the same use-after-free H2 described.
- **Shared consumer state.** The overflow and lost flags now have two consumers (voice release and the follower). The plan does not say that one drain loop owns clearing them.
- **Stale citations.** The instruments-plan line numbers match `0bf8820e8`, not the current head (L1).
- Fix:
  - Put the 16-byte entry, the real-time kinds, the memory order, and "relay and Thru pushes happen inside the sink call" into both plans' D4 now.
  - Make the TSAN test in Part 1 also race a relay push against detach.

**M9. Engine reopen and reconfigure do not replay sync state.**

- `LE_CMD_SET_CLOCK_SYNC`, `le_engine_attach_midi_in`/`out` and the output table live on the engine (section 2).
- The reopen plan destroys and recreates the engine, and configure resets the generator (`engine.c:760-762`).
- Part 8 covers "source capture and output attach on hotplug" only.
- Failure: after an engine reopen or an audio-device change, the engine is back on Internal with no outputs attached, while settings and the page still say "Synced via USB". That is a silent behaviour change (rule 3).
- Fix: replay the sync vector and every attachment on each engine lifetime, following the `_intendRunning` restart precedent (`looper_repository.dart:2535-2555`). Add a repository test for it.

**M10. Output latency is compensated when sending but not when receiving, and Part 3's hardware criterion cannot pass.**

- D7 shifts sent clock by `L_out` because "the clock describes the audio the listener hears".
- D4 does not do the same on receive. Section 9 states that Segno's audio lags the master by the device output latency plus MIDI transport.
- Part 3 HARDWARE then requires onsets "within 2 ms of the drum machine's". With `L_out` of 2.7-8 ms plus the codec, that fails by construction unless the criterion means variation only.
- Compensating the known `L_out` on receive is the same principle as sending, not a new user offset, so it needs no owner call.
- Fix: anchor the received downbeat `L_out` frames ahead (the same `d` mechanism). Word Part 3's criterion as a constant offset (reported) plus drift ≤ 2 ms.

**M11. The pen coverage has gaps, and the write-back list is incomplete.**

Checked through the pencil MCP.
- **Main-view chip.** Part 9b's "Waiting" and "Clock lost" chips are not drawn. 27/06 `PMu8D` draws only "MIDI synced". The clock-loss main view (51, screen `gCTKx`) has no chip at all. Either add these to the write-back list or follow the pen.
- **Zero reset.** AB 7.4's zero reset has no drawn control: `bXxAY` shows only the slider and "-7 ms".
- **Undrawn copy.** None of these is drawn or on the write-back list: "Finish recording to change source.", "Reconnect the selected device." and its selected-but-disconnected state, "Could not save. The previous setting is retained.", and any `midi_rt_denied` text.
- **Internal-state content the plan omits.**
  - The hint "Segno sets the tempo" / "Other devices can follow it below."
  - The "Tempo & click" button (`fkLOU`, `bXxAY`, `YPTg6`).
  - The Follow hint "Start restarts loops. Continue resumes them."
  - The second offset note ("Sender offsets apply with Internal tempo.") and the Internal note ("−10 ms earlier · +10 ms later ...").
  - The Thru-on DIN card: its sublabel becomes "MIDI In → MIDI Out", and its Clock, Play/Stop and offset are dimmed but keep their values.
- **07/07.** The "Recorded audio follows MIDI clock." note sits under Follow tempo **On** (`BFfDT`). The plan's condition is only "under an external source". This ties to H1's Follow-Off question.
- **Section 53.** Section 53's four MIDI editor screens (`T7urI`, `SCQt4`, `jRkHr`, `jWDJD`) also carry the Controls / Sync tabs. The plan cites only section 26.
- **Node ids.** For 06/09, 07/07 and 51 the plan gives the tile ids (`FrsRF`, `JQpGt`, `Lqfa3`). The screens are `XLSOr`, `BFfDT` and `gCTKx`. Goldens should target the screens.
- **Fractional tempo.** The page shows whole BPM ("120", "84"). The plan publishes 0.1 BPM. Say what the page shows for a fractional tempo.

### Low

**L1. Wrong or stale citations** (all other citations verified):

- `segno_navigator.dart:149-161` is `openExternalPedals`. `openMidiControls` is at `:172-187`.
- UX doc lines:
  - `:24` and `:25` should be `:22-23`;
  - `:31-33` should be `:29-30`;
  - `:37-38` should be `:34-35`.
- Instruments plan: D4 is at 459-526, the port ring at 700-703, Part 2c at 916-977, Part 4 at 1074-1105, and the Part 1 gate at 799. The plan's numbers are from `0bf8820e8`.
- `tempo_grid.h`:
  - `:95-111` is `le_grid_derive_bpm`/`le_grid_beat_at`. The loop-locked rule is `:80-86` and `:124-167`.
  - `:132-171` should be `:124-167`.
  - `:27-28` should be `:28-29`.
- `sync_grid_to_loop` is at `:638-666`, not `634-670`.
- `midi_backend_apple.c`: `:128-131` should be `:125-128`, and `:98-105` should be `:99-106`.
- `handle_cut_sound` runs to `:2249`. The pending-field clear is `:2209-2215` inside the per-track loop. The synthetic STOP is at `:2219-2227`.
- `test_engine_core.c:26802-27000` should be `:26792-27012`. `test_midi_core.c:302+` also holds `le_midi_clock_advance` byte tests that D7 retires.
- `midi.c:100-119`: Program Change also reaches Dart, not only Note and CC.
- `le_midi_clock.c:17-70` should be `:19-70`.
- `saveMidiConfiguration` is at `:535-591`.
- `le_tempo_locked` also locks during a count-in.
- The DIN 48/48-in-both-directions evidence is in `docs/research/2026-09-05-din-midi-bench.md`. `README.md:8-30` records IN only.
- `/dev/ttyAMA3` is set in `uart_pedal_link.dart:10`.

**L2.** D1 says "All three share `CLOCK_MONOTONIC`". On macOS, CoreMIDI host time is `mach_absolute_time` (uptime, stops in sleep), while `le_now_ns` uses `CLOCK_MONOTONIC`, which keeps counting through sleep. They diverge after a sleep. Convert with `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` for a fixed offset, or stamp at callback entry. This does not matter on the appliance.

**L3.** D5 step 3 says positions are retained "as for a received Stop (D7)". It should say D9.

**L4.** The plan's "udev rule giving the `segno` user the device" (`plan:480-481`) assumes a `segno` user. `segno.service` has no `User=`, so the app runs as root, and the pedal link on `ttyAMA3` works without a rule. Drop the rule, or state the user change it assumes.

**L5. Undefined Follow On transport cases.**
- An external Start or Continue while a track is RECORDING or OVERDUBBING. Does it finalize like Stop, or is it ignored?
- A Start during a local count-in.
- When internal sending ever emits Continue. Part 6 lists "Continue bytes", but D7 never says when Segno sends one.

**L6.** A capture armed for an external Start "loses those `d` frames" (`plan:331-334`). That clips the downbeat transient of every take armed for Start, by up to a block plus the MIDI latency. Start the write `d` frames back through the record-offset path if an input history exists. Otherwise state the loss.

**L7.** A seqlocked anchor with plain payload fields is a data race under TSAN, and Part 6 runs TSAN. Specify relaxed-atomic payload fields with fences.

**L8.** An offset change while running moves due times by up to 20 ms at once, which can burst or reorder ticks. Apply offset changes at the next Start, or slew them.

**L9. `clock_beat` and the quantize boundary.**
- `clock_beat` = pulses / 24 drives the 05/08 beat strip, whose first cell is the downbeat. With Follow Off there is no external bar, so take the strip from the grid's `a_current_beat`.
- D10's "first quantize boundary after Synced" in an empty rig with Follow Off has no anchor to measure from. Define it.

**L10. ALSA identity.**
- The id is the client name, and `le_alsa_find_source` picks the first matching port.
- A two-port interface can only ever select port 0. Echo exclusion then covers all of its ports, which is safe but blunt.
- Two identical devices collide.
- This is pre-existing; note it in D6.

## Notes

- **The DLL itself is sound.** B = 0.5 Hz gives about 0.08 ms of phase noise for 1 ms-frame USB jitter. With re-acquisition disabled, it holds a block-quantised source within 0.3 BPM. The weak part is the re-acquisition rule (M1).
- **Real-time safety of the follower** (O(1) per pulse, a six-element median, a vDSO clock read, no allocation) is fine. What is not settled is the once-per-beat 4a retime under capture (H1).
- **The negative-offset lookahead is sound in principle.**
  - Ticks for frames not yet processed are predictable while tempo and transport hold.
  - The cost is up to |offset| − `L_out` of extra ticks before a Stop, which is harmless because Segno never sends Continue after it.
  - It depends on M4 (wake) and M5 (phase).
- **Clock loss through the Stop path** is the right reuse for Multi, with the M6 exception for Sync and Band. Step order against Cut's code was traced and is safe.
- **Echo prevention by id,** Thru as RX-only bytes, and DIN Out with a single writer all match AB 7.4.
- **D9's "Start plays every recorded track"** also restarts a track the performer had stopped by hand. The plan records this as decision 9. It is a reading of "Start restarts recorded tracks", which the owner may want to confirm.
- **The Pen write-back list** should grow by the items in M11.

Verdict: Request changes (H1-H4; M1-M11 are design corrections the build parts depend on).

## Delta review (6fc551396)

### Scope

- Revision 2 of `docs/plan/2026-10-06-feat-midi-clock-plan.md` (1315 lines), compared with `cfa8725f5`, plus the new `docs/plan/2026-10-06-midi-clock-follower-probe.c`.
- Every finding above was checked against the section 10 map and the text it points to.
- I opened the new trunk citations (`097e1ef68`): `engine_process.c` `:1029`, `:3265-3292`, `:5733-5742`, `:704-735`, `:1167-1172`, `:1226`, `:374` and `:4834-4841`. All are correct.
- Pitch/time 4a §2.5 and §4.2 were re-read for the Follow-tempo interaction.
- The pen was not re-read. The delta changes only copy that the plan places on the write-back list.

### Runs

- **The plan's own probe.** It builds, and it reproduces the plan's D3 table exactly. The plan omits two of its rows:
  - the readout flips (2 a minute at 90 BPM on block edges, 3 a minute with noise);
  - the block-edge step (0.270 BPM error after the step and 10 flips).
- **An extended copy of the probe**, `follower-probe-delta.c`, kept beside this review. It adds a pulse-count check and integer-ratio tempo steps.
  - **One pulse dropped at 120 BPM:** the count is exact (2872 counted against 2872 true, and 2873 against 2873 on the USB model). The plan's "pulse count exact" row holds, but the probe as committed never prints it.
  - **Tempo halved (120 → 60) or cut to a third (150 → 50):** the follower never notices. It reports 120.00 (or 150.00) after 30 s at the new tempo, with 0 re-acquisitions, and counts 2 or 3 pulses for every real one. 174 → 87 behaves the same way. See DH1.
- PR #1236's CI on `6fc551396` is green, spell-check included. Six Dart package jobs were still pending.

### Prior findings: disposition

| Finding | Status at 6fc551396 |
|---|---|
| H1 drift through 4a | Met in design: slips at the wrap, 4a only for real changes, capture wait, 9a/9b split. Open points are DM1-DM3. |
| H2 units | Met (`ts_den/4`, window scaled, quarter-note SPP, 6/8 oracles; arithmetic checked) |
| H3 first clock late | Met (tick 0 at the Start frame, Start 1 ms before; Part 6 oracles re-derived, all correct) |
| H4 session open | Met (skip `restoreTempo` under external, toast, Part 8 test) |
| M1 re-acquisition | Met for the review's jitter models. The missed-pulse rule added for M2 opens DH1. |
| M2 missed pulses | Met for isolated losses; see DH1 |
| M3 re-anchor | Met |
| M4 wake | Met (ppoll/eventfd/timerfd, Darwin condvar, filtered `t_block`) |
| M5 tick phase | Met (musical tick phase in the anchor, retime oracle) |
| M6 loss truncation | Met (round-up flag, Sync oracle 1.4× → 2×); edge in DL3 |
| M7 UART0 / kernel path | Met |
| M8 one sink | Met: Part 1 is built and the instruments D4 bullet is field-for-field identical. Part 1's drain does not yet report a loss at its position, which D1 claims (midi-p1-in-session M1). |
| M9 reopen replay | Met |
| M10 receive latency | Met (`d + L_out`; Part 3a oracle 96 + 256 = 352) |
| M11 pen coverage | Met (pen table, write-back list) |
| L1-L10 | Met; the spot-checked citations are correct |

**Owner decision.** The owner's call is that under an external clock, a Follow-tempo-Off track keeps its recorded speed and detaches until its next Stop/Play. The plan builds exactly that as option (a) in section 9 and in D4. But it still presents the choice as an open question ("Recommended default, built unless the owner says otherwise"). Section 8 and Part 9c still wait for "once section 9 is answered", and Part 3b has no oracle for it. See DM1.

### Findings

#### High

**DH1. The missed-pulse rule follows an integer tempo division forever.**

Where: D3 "Missed pulses", `plan:387-393`.

- The rule counts an interval as `k ≥ 2` pulses when it is within 0.25 P of a whole multiple, the previous pulse was not an outlier, and σ < P/6. A dropped 0xF8 meets those conditions, and so does a master whose tempo drops to exactly 1/2 or 1/3.
- From the second pulse after such a step, every interval is ≈ 2P, the per-pulse error is ≈ 0, and no outlier is ever raised.
- Probe: at 120 → 60, 150 → 50 and 174 → 87, the estimate stays at the old tempo indefinitely, with no re-acquisition.
- Failure: a DAW or drum machine that changes to half time is not followed. The tempo page, the click and the Sync page keep the old tempo. Segno's loops play at twice the master's speed with every master pulse counted as two, so the beat pulse and bar anchors run twice as fast. Nothing recovers it short of a Stop/Start. This silently contradicts the plan's own claim that "a tempo step ... never matches" (rule 3).
- Fix:
  - Count `k ≥ 2` only for an isolated interval. Hold the count for one pulse. If the next interval is again ≈ k·P (two multi-pulse intervals in a row, or any two within a beat), treat it as a step and re-acquire from those intervals.
  - Add 120 → 60 and 174 → 87 oracles to Part 2 next to the dropped-pulse oracle.
  - Make the probe print the pulse count, so the table's "pulse count exact" row is produced rather than asserted.

#### Medium

**DM1. The owner decision is recorded as an open question, and with the global Follow tempo Off, 4a's retime cannot run.**

Where: D4 "Follow tempo Off" (`plan:466-470`), section 9 (`:1267-1282`), section 8 (`:1265`), Part 9c (`:1144-1145`), Part 3b (`:892-911`), D4 (`:437`).

1. **Record the decision.** Move the decision into section 5 and D4 as decided by the owner. State the 07/07 copy ("Keeps its recorded speed. The MIDI clock changed the song tempo.") as final on the write-back list, and drop "once section 9 is answered" from section 8 and Part 9c.
2. **The global default.** Pitch/time 4a ships `a_follow_tempo` = 0 until 4b. With it Off, `le_tempo_locked` still locks a rig with content (`pitch-time-core-plan.md` §4.2: "With Follow tempo on ... no longer locks").
   - D4 sends a real master tempo change to "4a's retime", which is not reachable while the global setting is Off.
   - So the default rig either holds the old tempo forever (the pre-3b held state) or needs the follower to bypass the global gate. The plan says neither.
   - The owner's decision implies the second: the song tempo (shared clock, click, grid) follows the master, and per-track Follow decides between following and detaching.
   - Say so, and say what the global value means under clock.
3. **No oracles.** Part 3b's tests cover only following tracks. Add:
   - a Follow-Off track on a 120 → 124 change keeps `rate = speed_global` and its `len_src` lap, and runs on its private counter;
   - it re-attaches at its next Stop/Play;
   - a following track is retimed;
   - the same with the global Follow tempo Off.
4. **A wrong claim in D4.** D4 says "following, Follow-Off and detached tracks all stay on the shared position". Under 4a §4.2 a detached track reads a private counter. Slips do not move it, and it drifts by the crystal error until it re-attaches. Under the owner's decision that is intended, but the sentence should say it.

**DM2. Slips have no perf-log fact, yet Part 3a claims renderer parity for a slipped lap.**

Where: D4 drift (`plan:430-444`); Part 3a criteria (`:885`); numbering table (`:36`).

- A slip moves the shared read position by φ frames, and φ depends on live MIDI timing.
- `perf_render.c` rebuilds read positions from logged facts. `LE_PLOG_REVERSE` (`perf_log_ring.h:182`) is the precedent for the turn crossfade that slips reuse.
- The plan reserves 349 and 351 but assigns no fact to a slip. The renderer cannot reproduce one, so a stem rendered from a performance with slips drifts from what was heard by the sum of the slips (about 20 frames a lap at 50 ppm).
- The Part 3a criterion "perf log and renderer parity hold for a slipped lap" cannot pass as specified.
- Fix: assign 349 `LE_PLOG_CLOCK_SLIP {frame, φ}`, apply it in `perf_render`, and add a render-parity oracle over three slipped laps.

**DM3. The slip target and the Auto end assume the loop starts on an external bar line.**

Where: D4 drift, which compares the wrap with "the frame the anchor's pulse count says the bar line falls on" (`plan:431-434`); D4 defining take (`:457-465`); Part 3a oracle (`:876-878`).

- With Follow Play/Stop On and the clock Synced, nothing quantizes the start of a defining take. D10 covers only the not-Synced arm. A take pressed mid-bar gives a loop whose wrap is never on an external bar line.
- Failure 1: every wrap shows a phase error of up to half a bar. Slips then pull the performer's loop toward the master's bar at 2 ms per lap. At 120 BPM in 4/4, half a bar is 1 s, so the shift runs for up to 500 laps, about an hour at 8 s a lap. It is a slow, silent move of the loop against what was played (rule 3).
- Failure 2: "queued to the next bar line of the external grid" then gives a loop that is not a whole number of bars from its start.
- With Follow Off this is consistent, because the anchor is the local start. The Part 3a oracle only starts the take at frame 0.
- Fix (either):
  - (a) Measure φ against the loop's phase offset captured when the loop is defined, as the re-anchor rule already "keeps the existing offset", and define the Auto end as whole bars from the take start.
  - (b) Under Follow On, start a defining take at the next external bar line.
- Add an oracle with a start at 1.5 beats.

#### Low

**DL1. The display hysteresis does not hold block-edge sources still.**
- At 90 BPM with 512-frame / 44.1 kHz edges, the probe's error is 0.184 BPM, above the 0.15 BPM hysteresis. The readout flips 2-3 times a minute.
- After a block-edge step the error is 0.270 BPM, above Part 2's 0.25 criterion for block edges, with 10 flips.
- Part 2's hardware criterion "does not change over a minute" can fail on such a source.
- Fix: put the flip count in the D3 table and the oracle, and raise the hysteresis to 0.25 BPM, or hold the display while |Δ| stays below 2σ of the estimate.

**DL2. The probe has two flaws.**
- `eprev` is a function-level `static`, so it carries over between runs.
- The table row "one pulse dropped ... pulse count exact" is not printed by the probe (see DH1's fix).

**DL3. The round-up on loss has no defined result past the largest ratio.**
- The Sync/Band round-up picks "the next whole ratio above the captured length". The set ends at 4×.
- A take longer than 4× the primary at the moment of loss (or past `max_loop_frames`) has no ratio to round up to.
- State whether it truncates at 4× (and so drops measured audio, against D5's "every measured frame") or is kept as a held take, and add the edge case to Part 5's oracles.

**DL4. A detached track under Follow Play/Stop is not covered.**
- D9's Stop and Continue describe the shared held position.
- For a track detached under DM1, which is on a private counter, say whether Continue resumes its private position or re-attaches it.
- 4a's "re-attaches at its next Stop/Play" suggests the latter, but the result is a track at its recorded speed reading the shared position.

**DL5. Instruments D4 contradicts this plan on CoreMIDI loss.**
- Instruments D4's "Device loss (review L7)" bullet (`74e55eab4`) still says the CoreMIDI backend marks loss from its notify callback.
- This plan's D1 and the instruments plan's own Part 2c say it is not built.
- One of the plans should change so they describe one sink (rule 4).

### Notes

- **What the revision gets right.** It removes every 4a dependency from the user-facing path. The slip design reuses the existing two-head turn crossfade (`engine_process.c:3265-3292`, mixed at `:5733-5742`) rather than adding a second one.
- **Arithmetic checked:**
  - the Part 3a numbers: 19.2 frames a lap; 1440 frames over 600 s; 58 frames after a three-lap overdub, assuming the overdub ends at a wrap; 352; 384000 and 480000;
  - Part 4's 6/8 Song Position (12 → 72000);
  - Part 5's 60000 = 48000 + 250 ms;
  - all Part 6 due times, including −7 ms (tick 1 at 1_016_500_000).
- **Long overdubs.** Deferring slips during capture bounds the error at the crystal error times the capture length. A performer who overdubs continuously for ten minutes accumulates 30 ms at 50 ppm before the first slip. It is then worked off at 2 ms a lap, about 15 laps. That is acceptable, but Part 3a's hardware run should include a long overdub.

Verdict (delta): Request changes (DH1 is a silent wrong tempo on a common musical change; DM1-DM3 leave the owner decision, renderer parity and the slip reference undefined).

## Delta review (820c54a1f)

### Scope

- Revision 3 of the plan, compared with `6fc551396`. The standalone probe file is removed in this revision.
- Every claim about built behaviour was checked against Part 2 at `e9e7fb509` (PR #1259). I drove the built `le_clock_follow.c` with the review's jitter models (`p2probe.c`, `p2drop.c`, `p2acq.c` and `p2_engine_probe.c`, beside the P2 review).
- I checked instruments plan D4 at `1537c8f96`.

### Prior findings: disposition

| Finding | Status at 820c54a1f |
|---|---|
| DH1 integer divisions | **Met and verified on the built follower.** 120→60, 150→50, 174→87 and 60→120 are each followed with one re-acquisition, settle in 0.12-1.28 s, and keep the pulse count exact on the uniform, USB, block-edge and block+noise models. |
| DM1 owner decision | Met. It is recorded as decided (D4, section 5 item 5a, section 9). The global value under a clock is defined: Part 3b calls 4a's retime directly, and the global value acts only as each track's inherited Follow tempo. The detached-track wording is corrected, and Part 3b has the Follow-Off, re-attach and global-Off oracles. |
| DM2 slip fact | Met (349 `LE_PLOG_CLOCK_SLIP {frame, φ}`, `perf_render` replay, a three-lap parity oracle) |
| DM3 slip target | Met. φ is measured against the take's own phase offset, captured at the defining take's start. The Auto end is whole bars from the take's own start. There is a 1.5-beat oracle. |
| DL1 readout | Met for steady sources. The built band plus one-beat hold gives at most 1 readout change a minute on every model I ran, against 2-3 before. |
| DL2 probe | Met (retired in favour of native tests; see PDM1 for what those tests omit) |
| DL3 past 4× | Met (truncated at the limit, the frames counted in fact 350, and a notice) |
| DL4 detached and Continue | Met |
| DL5 instruments CoreMIDI | Met in D4 (`1537c8f96:597`). Its disposition table still says "D4: native port-exit and CoreMIDI notify" (`:1491`). |

### New findings

**PDM1 (Medium). The D3 table overstates block-edge behaviour, and the acquisition rule is the cause.**

Where: D3 acquisition and table, `plan:362-380` and the "Acquisition" bullet.

The table's figures are measured from 5 s after the start. The rule itself, the median of six intervals, misbehaves on the block-edge model the table lists. Measured on the built follower:

1. **Acquisition seed, over 200 start phases.**
   - The tempo at the moment of Synced is off by up to 17.7 BPM at 90, 12.3 at 120, 17.2 at 124.9 and 41.3 at 174.
   - It converges within about 1-2 s.
   - The engine writes that seed into an empty rig's session tempo at the Synced edge. In the engine probe, a 120 BPM block-edge source wrote 107.67.
   - The Sync page shows the seed at once.
2. **One unmarked dropped pulse.**
   - When σ ≥ P/6, which is always true at 174 BPM on this model and often true at 120, the missed-pulse rule is off.
   - The dropped pulse then becomes six same-sign outliers. Those re-seed from six block-quantised intervals, giving 107.7 BPM at 120, and the pulse count stays one short.
   - Over 200 drop positions the count is wrong in 43 at 90, 82 at 120 and 200 at 174.
   - The row "one pulse dropped at 120: exact" holds only for the uniform and USB models.
3. **A 120 → 100 step on block edges.** The count also ends one short (2640 against 2641).

The rule is the plan's, and P2 builds it faithfully, so the plan should change with the code. See the P2 review, M1.

Fix:
- Seed from the span of the timestamps (a least-squares fit, or `(t_last - t_first) / n`) rather than the median. When the interval spread is large relative to P, extend acquisition to at least one beat before Synced.
- On an outlier re-seed, infer the pulses the run hid from its span and the new period.
- Add block-edge rows for acquisition and for a dropped pulse.

**PDM2 (Medium). "Starts over on REBOUND" (D1) turns Clock lost into Waiting and hides a loss.**

Where: D1, `plan:294-310`. See the P2 review, M2.
- A Synced source whose capture is closed or rebound produces no LOST.
- A Lost source becomes Waiting, with the readout cleared, as soon as the app closes the vanished capture (about 2 s after the loss).
- AB 7.3 requires Clock lost to stay visible.
- Fix: on REBOUND of the source port, a Synced follower goes Lost (with the event) and a Lost follower stays Lost, keeping its last tempo. Only acquisition state restarts.

**PDL1 (Low). Code 48 is described two ways.**
- The numbering section still says `LE_CMD_SET_CLOCK_MODE` (48) "is retired by Part 2 and its number is never reused" (`plan:39`).
- D12 (`:797-801`) now keeps 48 as `LE_CMD_SET_CLOCK_SEND` until Part 6.

**PDL2 (Low). No notice when tracks detach.**
- Under 4a's global default (Off), the first real master tempo change detaches every track, per the owner's decision.
- The only visible trace is the 07/07 line, on a settings page.
- Rule 3 suggests a one-time toast on the main view ("Loops keep their recorded speed; the clock changed the tempo."). This is not a decision against the owner's call; it only concerns how the change is shown.

### Notes

- **Ramp lag.** During a DAW accelerando of 1.25 BPM/s (120 → 130 over 8 s), the 0.2 Hz loop trails the master by about 1.4 BPM, then settles 1.4 s after the ramp ends. Part 3b's "0.05 BPM for one beat" threshold will retime repeatedly during such a ramp. Part 3b should say whether it retimes once at the ramp's end (when the change stops) or keeps following.

Verdict (delta): Request changes (PDM1 and PDM2 are short text changes that P2 needs too; everything from the previous delta is met).

## Delta review (751ae144c)

### Scope

- Revision 4 of the plan, compared with `820c54a1f`.
- Its D3 claims were checked against Part 2 at `8040d3c95` with the probes in `midi-p2-in-session/delta-8040d3c95/`.
- I checked the `MidiInputSink` role on `origin/claude/instruments-1197-p3a` (`c11aba0ff`).

### Prior findings: disposition

| Finding | Status at 751ae144c |
|---|---|
| PDM1 seed on block edges | **Met.** D3 now specifies least-squares acquisition, a one-beat minimum, the kink cut and the run classifier. The block-edge rows are confirmed by the probes: seed ≤ 0.15 BPM over 200 phases; unmarked drops counted at every one of 200 positions. |
| PDM2 REBOUND | **Met** (D1: Synced becomes Lost with the event; Lost stays Lost with its tempo and readout). Built and confirmed by the engine probe. |
| PDL1 code 48 | **Met** (the numbering section and D12 agree: renamed in Part 2, retired in Part 6) |
| PDL2 detach notice | **Met** (a toast once per source selection, `clock_detaches`, Parts 3b and 9c) |
| Ramp lag | **Addressed.** Part 3b keeps following, with at most one retime per bar, and re-places the phase from the anchor's pulse count at each retime. Its oracle requires a bar-line error under 2 ms after the ramp. |
| One Dart input seam | **Met.** Part 8 and section 3 use instruments Part 3a's `MidiInputSink` (`attachMidiInput(MidiCaptureHandle, {port})` and `detachMidiInput(port)`, `audio_engine.dart:1635-1643` on that branch). Small wording point: Part 3a adds `MidiInputSink` as its own role interface, which `NativeAudioEngine` implements beside `AudioEngine`, not as members of `AudioEngine`. |

**Correction.** PDM1 point 3 ("a 120 → 100 step on block edges ends one count short") came from my probe dropping the last pulse of the run. I withdraw it; the plan's "(block edges: was one short)" can go.

### New findings

**PDH1 (High). D3 has no rule for pulses delivered late in a burst, and the built rules miscount them.**

Where: D3 "Missed pulses" and "Runs".
- The whole-multiple rule counts a late pulse as missed.
- The run classifier then reads the burst as a tempo step.
- The re-fit counts hidden pulses against the burst's slope.
- Measured on Part 2 (`midi-p2-in-session` delta, DH1): a stall of 25-100 ms leaves the count wrong in about 40-55 % of phases. Stalls of 70 ms or more leave 1.9-5.2 BPM of error 4 s later, with swings to 182 and 65 BPM.
- The table's "4 ms bus stall" row is accurate, but it is the only stall the plan specifies.
- Parts 3a and 4 build anchors and Song Position on the count, and Part 3b now re-places the phase from it at every retime. So a miscount moves the loop.
- Fix: add a burst rule to D3. A pulse less than P/4 after a late one was delivered late, not missed, so it is excluded from runs and re-fits, and any extra count is taken back. Add table rows for stalls of 25, 45, 100 and 200 ms on each model.

**PDL3 (Low). The ramp row understates re-fits.**
- The D3 table says 0-2 re-fits during the 8 s accelerando. On the uniform and USB models, `p2probe` measures 5.
- Each re-fit stops tempo writes for at least a beat.
- Part 3b's one-retime-per-bar rule should say how it treats `refit`.

**PDL4 (Low). An unclamped re-place during a ramp may be audible.**
- Part 3b re-places the shared position "unclamped" at each retime: about 20 ms per bar at 1.25 BPM/s, under the 10 ms turn crossfade.
- The Part 3a hardware run listens for slips of 2 ms. Add a ramp to the listening test, or bound each re-place.

### Notes

- **Part 8 and replays.** A REBOUND of a Synced source is now a loss. Part 8's replay of attachments must leave an unchanged source binding alone; otherwise an app-side re-attach reads as Clock lost.

Verdict (delta): Request changes (PDH1; the earlier findings are all met).

## Delta review (6971de523)

PARTIAL - stopped for cloud migration

### Checked from the diff

- **The D3 "Late delivery" rule.** It matches the code at 422f819dd. My probes confirm its stall rows: 0 of 100 wrong at 10-200 ms on every model.
- **PDL3.** The ramp row is corrected to 0-6, and Part 3b skips the bars a re-fit covers. Consistent with `p2probe`.
- **PDL4.** The ramp listening test and the clamp fallback are added to Part 3b's hardware criteria.
- **The nit.** `MidiInputSink` is now described as its own role interface.
- **The D11 replay note.** The replay leaves an unchanged source binding alone and re-attaches only a changed capture.

### Provisional new points (not yet written up)

- The D3 table should state the tempo range for block-edge sources, or add 160-300 BPM rows (P2 DM1).
- The burst rule needs a clause for real step-ups of about 4× or more (P2 DL1).

### Not done

- the full check;
- the verdict.
