Model: Claude Opus (subagent), in-session

# Review of PR #1204 (origin/claude/instruments-plan-1197 @ 805ef0199): docs(plan): instruments plan

## Scope

- `docs/plan/2026-10-06-feat-instruments-plan.md` at PR head `805ef0199`
  (the first fetch was `3c6db331e`; the later commit only adds the engine
  number ledger, a corrected drum oracle and the existing error codes
  `LE_ERR_CAPACITY` / `LE_ERR_NOT_READY`, and this review covers both).
- Reviewed against: the plan's stated baseline `5c163d11f`, the current trunk
  `origin/claude/segno-integration` @ `56033baf0` (three usb-storage merges
  later, touching `segno_engine_api.h`, `perf_drain.c`, `test_engine_core.c`),
  AGENTS.md, `docs/handoff/segno-app/accepted-behavior.md`, issue #1196, the
  pitch/time plan and spike findings, the prototype in the main checkout's
  untracked `docs/design/` (`instrument-runtime.js`, `instrument-catalogue.js`),
  and `segno-ui.pen` sections 54 (`teX79`) and 21 (`O51ZiH`), read through the
  pencil MCP only and never saved.

## Runs

- This is a docs-only PR, so there were no suites to run against it. Every
  claim below was traced in the code at `5c163d11f` and `56033baf0`
  (`git show <rev>:<path> | sed -n`).
- PR CI at the time of reading: native-tests, native-tests-tsan,
  native-tests-telemetry-off, native-bench-arm64, build-linux-arm64 and
  semantic-pull-request passed; the build, ASAN and package jobs were still
  pending.
- Pen: listed the children of `teX79` and `O51ZiH` and dumped the text of every
  section-54 screen and of each section-21 screen, searching for instrument
  sources.
- Prototype: checked the 19 patch rows, the family controls, `busFor`, the
  attack formula, `noteOff`, the repeated-strike rule and the drum timing. The
  corrected kick oracle in the plan is right: decay 40 gives
  0.15 + 1.04 × 0.55 = 0.722 s, and the sweep ends at 0.361 s.

## Verified correct (traced)

- Engine facts:
  - `LE_MAX_CHANNELS 32` (`segno_engine_api.h:24`) and
    `LE_MAX_MONITORED_INPUTS LE_MAX_CHANNELS` (`:670`);
  - `LE_CMD_REVERSE = 83` is the highest command;
  - snapshot per-channel arrays at `:1329-1332`, filled at
    `engine_snapshot.c:488-496`;
  - `le_engine_process` at `:6338`, with the denormal flush at `:6340` and the
    drain at `:6356-6360`;
  - conditioning at `:6437-6469`, with fallback counting, and the clip detector
    on raw input at `:6482-6517`;
  - the sound trigger skips `>= ch_in || >= 32` (`:5326-5327`);
  - capture guard `:5986-5992`, `mix_monitors_frame` `:5395-5430`,
    `perf_tap_monitor_frame` `:4288`, `perf.input_mask` (`uint32_t`) at
    `engine_private.h:1338`;
  - `LE_CMD_SET_LANE_INPUT` maps an out-of-range or excluded channel to -1
    (`:3628-3643`), and `LE_CMD_SET_MONITOR_INPUT` at `:3699-3709`;
  - `handle_cut_sound` at `:2201`, `LE_RING_CAPACITY 256`, `le_request_admit`
    at `engine_commands.c:2759`;
  - the CLAP host queues parameter events only (`host_clap.cpp:401-414`);
  - `fx_filter` is the TPT SVF (`engine_fx.c:55`);
  - CMake, `run_native_tests.sh` and `build_test_lib.sh` list the restore TUs
    explicitly, and `test_engine_read_head.h` is included at
    `test_engine_core.c:33545`;
  - the bench defaults to 96 kHz / 64 (`bench_pitch_time.c:665`), and the CI
    jobs sit at `main.yaml:181`, `:239`.
- The dev baseline of 8 × 8 lanes at p99 11.9 % matches the spike findings
  table.
- MIDI:
  - the parser drops 0xD0/0xE0 (`midi.c:58-96`);
  - `le_midi_ring_push` filters before the ring;
  - the Linux backend converts only NOTEON/NOTEOFF/CONTROLLER/PGMCHANGE
    (`midi_backend_linux.c:136-171`);
  - `MidiControllerSource.open` closes first (`:43-56`), and `_parse` maps
    0x90/0x80/0xB0/0xC0;
  - `messages` is never gated (`midi_device_repository.dart:66-69`);
  - the session filter is at `control_midi.dart:372`, and `_midiCanDispatch`
    at `:459-468`.
- Dart:
  - `formatVersion = 11` (`session.dart:847`), strict equality at `:756`, lane
    parse `-1..31` at `:825`;
  - `SessionMonitor` at `:420` and `SessionInputSetup` at `:518`;
  - every "Input lists" site (`recording_inputs_tab.dart:104-106`,
    `output_routing_tab.dart:56/302`, `fx_cubit.dart:83`, `fx_page.dart:908`,
    `foot_mixer.dart:228`, `control_value_resolver.dart:89/163`,
    `tuner_cubit.dart:117`);
  - `inputName` (`localized.dart:109-112`), `cutSound` (`:5098`, `:209`),
    `SlotIds`, the `InputMonitor` default mask `0x3`, the catalogue at
    `control_action.dart:452`, and `_runAction` at `control_cubit.dart:2496`.
- Accepted-behaviour line references (section 5 `:357-410`, `:228`, `:330`,
  `:335`, `:461`, `:568`, `:31-34`) are all accurate.
- Pen section 54 has exactly eight screens and the plan maps all eight:
  `gGTXF`, `hSy26`, `hRKQL`, `B5PEqI` (Part 7a), `kole9`, `Uv25f`, `t00H3H`
  (Part 7b) and `J2uTq` (Part 8). The default 13 rows A W S E D F T G Y H U J K
  → C3..C4 match `Uv25f`. Hear live On at 75 % matches `gGTXF`.
- The tuner keeps device channels only (E8-14), so there is no collision with
  the 18-input tuner.
- Instrument sources 32-39 do not collide with the existing numbering: physical
  inputs are clamped to `LE_MAX_CHANNELS` at the device
  (`engine_miniaudio.c:224`, `:351`).
- The plan already admits that `1u << c` is undefined at 32 and above and
  confines the excluded and clip masks to physical sources.

## Findings

### High

**H1. The mix transaction and the Dart source bounds are missing, so instrument routes, levels and pans cannot reach the engine.**

D3 says instrument sources work "through the code that already exists". The
real routing and level path is the atomic mix transaction
(`LooperRepository._sendMix` → `setMix` → `le_engine_set_mix`), and it is
hard-bounded at 32 everywhere. The plan names only `LE_CMD_SET_LANE_INPUT` and
`le_apply_routing`.

Native bounds:
- `le_mix_settings` has a `uint32_t monitor_mask` and
  `monitor_gain` / `monitor_pan` / `input_trim[LE_MAX_CHANNELS]`
  (`segno_engine_api.h:713-735`).
- `le_mix_valid` refuses `lane_input >= LE_MAX_CHANNELS` and walks monitors
  `< LE_MAX_CHANNELS` with `1u << i` (`engine_commands.c:1426-1444`).

Dart bounds:
- `EngineMixSettings.isValid` requires lane inputs and monitors `< 32`
  (`mix_settings.dart:97`, `:124`, `:129`).
- `MixSettingsSnapshot` has the same bounds (`mix_settings_snapshot.dart:113`,
  `:139`).
- `_mixPayload` only sends monitors `< kMaxChannels` (`looper_repository.dart:733`).
- `_sourceAvailable` requires `input < device.inputChannels` (`:4641-4645`).
- The assign guard checks `input >= kMaxChannels` (`:4705`).
- The sound-start check requires `lane.inputChannel < applied.inputChannels`
  (`:2983-2988`).
- Session restore throws on `m.input >= kMaxChannels` (`:3817`).
- Monitor pan comes only from `InputSetup.pan`
  (`monitorMix`, `:8046-8049`), which is bounded `< 32`
  (`input_setup.dart:46`), and Part 6 explicitly keeps Input setup physical.

Failure: after Parts 2a–6, choosing an instrument card in Recording inputs is
refused by `_sourceAvailable`. The new instrument's "Level 75 %" is never sent.
A sound-armed take on source 32 returns "recording input required". Instrument
pan has no owner. No part is assigned this work.

Fix:
- Add the native widening to Part 2a: monitor mask to `uint64_t`, arrays to
  `LE_MAX_SOURCES`, and the `le_mix_valid` bound.
- Add the Dart widening to Part 3b through one `isSource(int)` predicate in
  `LooperRepository`, listing every site above with a test each.
- Decide where instrument pan lives, since D3 asserts "Pan places it".
- Re-estimate both parts.

**H2. The MIDI sink has no producer-quiescence protocol (use-after-free and two producers on one SPSC ring).**

Part 2b installs an `_Atomic` function pointer and context on `le_midi`, called
from the OS MIDI thread. Today's safety rests on the backend join inside
`le_midi_close`:
- the callback is nulled, then `backend->close` runs `pthread_join`
  (`midi.c:183-198`, `midi_backend_linux.c:179-191`).

A detach that keeps the capture open has no such join.

Failure:
- During an engine reopen, Dart detaches and destroys the old engine while the
  ALSA or CoreMIDI thread has already loaded the old sink and context. That
  thread then writes into the freed port ring.
- Port slot k is reused for device B while device A's thread is still inside
  the sink. Two producers then write one SPSC ring. The generation tag filters
  stale events but cannot repair a corrupted head or tail.

Fix:
- Put an in-flight counter on `le_midi` around the sink call (wait-free for
  the producer); detach stores NULL and spins until the counter is zero.
  Alternatively, specify detach as close plus reopen of the capture.
- Bump the generation natively in `le_midi_close`.
- Add a TSAN test (the `native-tests-tsan` job exists) with a producer thread
  racing detach and destroy.

**H3. Ring overflow drops note-offs and leaves stuck notes, and the overflow oracle cannot happen.**

Both new rings drop when full:
- each port ring is 256 slots, with "drop newest", as `le_midi_ring_push`
  does;
- `le_engine_instrument_event` returns `LE_ERR_CAPACITY`.

A dropped note-off or sustain-off leaves a voice held forever. Nothing in the
plan releases it.

Separately, the Part 2b oracle ("300 events in one block play the first 256
now, the rest in the next block, 44 deferred") cannot happen. A 256-slot ring
(255 usable under the existing convention) cannot hold 300 queued events, so
the producer drops the excess rather than deferring it.

Fix:
- On a producer-side overflow, set a per-port flag. The audio thread then
  releases every voice whose origin names that port and clears its sustain
  contributors, and counts it.
- Dart must keep pending releases and retry them until accepted, never
  dropping them.
- Rewrite the oracle as an overflow test that proves the release.

**H4. Refusing an empty instrument slot inside the batch would roll back whole recalls.**

Part 2a makes `le_apply_routing` accept "an instrument slot with a patch" and
adds `LE_ERR_NO_INSTRUMENT`. But `le_apply_routing` validates the whole
`le_mix_settings` and refuses the entire batch on any bad entry
(`engine_process.c:2649`, `:2669`).

D6 says an instrument with an unknown sound "keeps its definition, plays
nothing", so its native slot has no patch.

Failure: recalling a session that has such an instrument sends a mix
transaction containing lane input 32. The engine refuses all of it, and the
recall fails or rolls back. That contradicts D6 and accepted 5.7 ("failure
preserves the prior setup").

The plan also proposes checking `in_channels` in the mix path. Today that path
deliberately accepts a stray physical route (Recording inputs shows it via
`strayInputs`, `recording_inputs_tab.dart:106`). Adding the check changes
recall behaviour for a session moved onto a smaller interface (rule 3).

Fix: in the mix path, accept any source in `[0, LE_MAX_SOURCES)` and let an
empty slot render exact silence. Keep refusals at the repository and UI layer,
and confine `LE_ERR_NO_INSTRUMENT` to single-command APIs or drop it.

**H5. The sequencing lets instrument creation ship before the session schema accepts sources 32+.**

The dependency tree makes Part 5 (session recall, which waits on #1196) a
sibling of Part 6 → 7a. Once 7a ships, a player can route a lane to source 32
and save.
- `Session.fromJson` then throws `FormatException('invalid lane address')` on
  `laneInputs` 32 (`session.dart:825`, `:1285-1287`).
- A monitor on 32 throws at `looper_repository.dart:3817`.

The result is a saved session that will not open (rule 2). It becomes real as
soon as H1 is fixed.

Fix: make Part 5 a prerequisite of Part 7a, or of Part 6, in the dependency
tree.

### Medium

**M1. Note-off routing contradicts itself.**

- §2.3 step 2 releases a note "for each instrument … whose port and channel
  match".
- D4 says a note-off releases by origin "across every instrument".
- The prototype's `noteOff(token)` walks all voices (`instrument-runtime.js:200-207`).

Under §2.3, turning the instrument's MIDI off, changing its channel, or
removing a remap while a note is held strands that note. Only the range-edit
case is tested.

Fix: handle note-off (and the CC64-off contributor removal) first, globally by
origin, before any table lookup. Add tests for each of those three edits made
while a note is held.

**M2. Fade-slot exhaustion is undefined.**

There are `LE_SYNTH_FADE_SLOTS = 8`.
- A 32-note burst into a full pool (one of D2's own scenarios) needs 32 fades.
- Cut all sound "moves every voice to a 3 ms fade", which means 32 to 64
  voices.

Fix: specify that Cut fades voices in place, say what happens when no fade
slot is free, and test a 32-steal burst.

**M3. The CPU budgets are not combined and there is no overload policy.**

Pitch/time already claims `baseline + head ≤ 50 %` of the period. This plan
claims `baseline + 32 voices + 8 monitors ≤ 50 %`. Run together, the two can
use the whole period, and no scenario measures them together.

Other gaps:
- The eight monitors' FX chains are unspecified.
- The per-block event-routing cost has no bench: up to 8 × 256 + 256 events,
  each scanned against 8 instruments × 32 remaps.
- p99 over 60 s tolerates about 900 late blocks. A miss at 64 frames is an
  audible click.

Fix:
- Add a composite bench scenario: pitch/time at 8 lanes, 32 voices, and eight
  monitors with one reverb each.
- Gate on p99.9 plus `late_periods == 0` over a long appliance run.
- State the overload behaviour, for example a runtime voice cap that Dart can
  lower.

**M4. The Pi gate comes too late.**

The Pi numbers gate only Part 6's merge, so about 2,950 lines (Parts 2a–5) land
first. The plan's own fallbacks (cheaper oscillators, or 48 kHz internal plus
the half-band) would rework Parts 1 and 2a.

Fix: the Part 1 artifact's Pi run gates Part 2a's merge.

**M5. Shared value targets keyed by source number silently retarget when a slot is reused.**

`MonitorVolumeTarget` serialises as `{"ctl":"monitorVolume","index":32}`
(`control_value_target.dart:276-289`), and monitor preferences persist as
`monitor_input_mode.N`.

Remove the instrument in slot 0, then Add (which takes the first free slot): a
pedal or expression binding on 32 now drives the new instrument. That breaks
accepted §4.11 ("never silently bind") and rule 3. `retireSource` resets the
monitor but not the bindings.

Fix: mark bindings that name the retired source unavailable, with Change
control / Remove, or key instrument-source targets by instrument id. Add a
test.

**M6. Accepted 5.9 "source labels" is dismissed rather than met.**

Decision 12 says there is no label to keep. But `retireSource` clears lane
routes on every non-capturing track, including tracks whose recorded audio came
from the instrument. A stale 32 would render as "Input 33" through the
`inputName` fallback (`localized.dart:111`).

Fix: keep routes on tracks that hold material and resolve a removed source to
"Removed instrument (<name>)", or have the owner waive 5.9 in writing.

**M7. The D6 trigger is misidentified, and its Retry can never succeed.**

The plan says a sound becomes unavailable when a session comes from a newer
version. But newer sessions are refused by the strict version check
(`session.dart:756`) and by #1196 ("A session newer than the app … is
refused").

The cases that can actually happen are:
- the persisted `instruments` working copy after an appliance A/B (RAUC)
  rollback;
- a same-schema session written by a build with a different patch table.

"Retry re-reads the catalogue", but the catalogue is compiled in, so Retry can
never succeed. That is a control that cannot work (accepted `:31-34`, rule 3).

Fix:
- Name the real triggers and test the rollback case in Part 3b.
- Drop Retry from the sound-unavailable state.
- Keep Retry for audio-start failure, where accepted 5.8 wants it ("A
  successful retry clears the failure"). Part 7a lists that reason but no
  Retry for it.

**M8. Computer keys can leave stuck notes.**

D9 routes keys only while the Instruments page shows or no text field has
focus. If a key is held when focus moves to a text field, or the window loses
focus, its key-up is not routed and the note sticks.

Two further points:
- `TracksCommands.handleKey` is a `Focus.onKeyEvent` handler
  (`tracks_view.dart:195`), not a `HardwareKeyboard` one, as the plan states.
- When a global `HardwareKeyboard` handler claims a key, Flutter still
  delivers the event to the focus chain. The claim must therefore be checked
  inside `TracksCommands`; handler order will not enforce it.

Fix:
- Gate only key-down.
- Always route the key-up for a token that is sounding.
- Release every computer-key token on focus loss or app inactive.
- Ignore `KeyRepeatEvent`.
- Test each of these.

**M9. Latches go out of sync after a reconfigure or sample-rate change.**

The engine re-initialises the synth on configure and cuts every voice. Dart's
latch and contributor state is told only about engine lifetime changes, so
after a sample-rate change a latched pedal's LED stays lit while silent, and
the next press only "releases".

Fix: report a synth epoch in the snapshot, or have `InstrumentRepository`
observe configure; clear latches and LEDs on it. Add a test.

**M10. Two hardware gates cannot be run in their own parts.**

- Part 4's "USB keyboard plays an instrument" needs an instrument bound to a
  device, and no UI does that before Part 7a/7b.
- Part 7a's "32-note chord" needs MIDI input, which arrives in Part 7b.

Fix: move both checks to Part 7b.

### Low

**L1. Some line references have drifted.**
- Raw-packet parsing is at `midi_backend_apple.c:110-150` (`le_core_push_bytes`
  and the read proc), not `:183-192`, which is port creation.
- `le_apply_routing` starts at `:2647`, and its 32 bound lives in `le_mix_valid`.
- Re-check every reference after rebasing onto `56033baf0`.

**L2. Several `LE_MAX_MONITORED_INPUTS` consumers are unlisted.**

Widening `LE_MAX_MONITORED_INPUTS` silently changes these:
- `le_perf_arm` clamps capture to `in_channels` (`engine_commands.c:4636-4648`),
  which would exclude instruments from the performance tap;
- `le_perf_free_unpublished` uses a `uint32_t` `monitors_done` mask;
- the `cond[]` and clip arrays grow;
- the Dart consumers of `kMaxMonitoredInputs` change, so "no Dart change" in
  Part 2a is not true: the `monitor_cubit` restore loop,
  `input_conditioning_cubit` and `monitor_migration`.

List them in Part 2a.

**L3. MIDI origins and Dart tokens share one `u32` space.**

Reserve a tag bit. Also specify how Dart maps tokens to the 32-bit contributor
mask.

**L4. Patch application is described two ways.**

§2.2 has `_Atomic a_patch`, while Part 2a calls `le_engine_set_instrument` "a
command". Pick one.

**L5. State the note-name convention.**

Pen `t00H3H` shows C3 as 60, so it should be written down.

**L6. `hSy26` shows an explicit "Listen" button.**

The plan auditions on selection instead. Match the pen or record the deviation.

**L7. Device loss waits for the Dart poll.**

Detach relies on the 2 s poll, so held voices from an unplugged keyboard keep
sounding for up to 2 s. ALSA `PORT_EXIT` or a CoreMIDI notification could
detach natively. State the behaviour either way.

**L8. Route publishes need coalescing while the device is stopped.**

While the device is stopped the audio thread never acknowledges a flip.
Specify latest-wins coalescing, and whether the zero-frame pump
(`engine_commands.c:4824`) acknowledges.

**L9. Several departures from the pen are not listed.**

- The section-21 screens (`s0zlm`, `oegcz`, `MoriR`, `sTYRr`) show no
  instrument sources.
- `hRKQL`'s "Install sound pack" is dropped.
- `gGTXF`'s "Decay 1.52 s" display would change under D5's native mapping.

Each needs a pen write-back by the owner, and the plan should list all of them,
not only D6.

## Notes

- Pen section 21 coverage: Part 6 targets `s0zlm` and `oegcz`. The "18
  recording inputs" (`MoriR`), "18 live inputs" (`sTYRr`), "Recording locked"
  (`r47I8`) and "Auto monitoring" (`mf0fR`) variants also gain instrument cards
  once Part 6 lands. Their goldens should be updated, and the 18 + 8 card layout
  checked at console size.
- Part sizes:
  - Part 2a's ~650 lines omits H1's native half, so it should become about 800
    or be split into (i) slots, buses and synth, and (ii) source-space widening,
    with the mix transaction, perf and snapshot.
  - Part 3b grows with H1's Dart half.
  - Part 7a (~700) is at the limit.
  - Apart from H5, each part is mergeable on its own as described.
- Part 1's FFI symbol check only verifies symbols that the bindings look up, so
  the three new exports pass it trivially unless the bindings are regenerated.
- Persistence: the `instruments` family under the #1159 owner is the right
  home. Part 3b should write it through the same `SettingsOwner` type from the
  start, so that Part 5 does not have to re-home a direct `SettingsRepository`
  writer (rule 4). The #1196 dependency for Part 5 is correct. The migration
  step ("absent list → empty, recorded as defaulted") matches #1196's contract.
- Real-time design otherwise sound:
  - one RT thread;
  - voices rendered once per block into fixed buses;
  - fixed pools;
  - no libm in render (stricter than `fx_filter`, which already calls `powf`
    per sample);
  - the per-port generation tag;
  - notes kept out of Dart.

  Choosing native routing over a Dart round trip is right.

## The planner's questions

1. **"Install sound pack" with synthesis compiled in.** Agree with dropping it.
   - Accepted `:31-34` forbids placeholder sound packs.
   - Nothing installable exists, so the action can only be faked.
   - Keep storing the patch id as a string, so that a real content system can
     add Install later without a schema change. The pen should drop the button
     now.
   - Also drop Retry for sounds (M7). Keep "Choose another sound", and keep the
     instrument's definition (and its routes, per H4).
   - The state can only be reached after an OTA rollback or from a session
     written with a different patch table, so the owner may also decide it
     does not warrant a dedicated screen.
2. **Computer keys on the appliance.** Keep the feature on every build, default
   Off as the accepted text requires. Do not hide it on the appliance.
   - Accepted 5.3 makes MIDI and Computer keys independent inputs.
   - A USB keyboard is a real appliance input; the bench already drives the
     appliance through a uinput keyboard, where A arms.
   - The collision only exists after the player turns Computer keys On, which
     is an explicit choice. So the default (claimed keys go to the instrument)
     is acceptable under rule 3, provided the notice appears where the lost
     shortcut is pressed (the Tracks view), not only on the Instruments page.
   - Keep the pen's A–K defaults; changing them would be a pen deviation.
   - Fix M8 first: stuck notes are the bigger risk than the shortcuts.

Verdict: Request changes

## Delta review (27fa7d945)

Model: Claude Opus (subagent), in-session.

### Scope

- `docs/plan/2026-10-06-feat-instruments-plan.md` at `27fa7d945` (two commits
  since `805ef0199`: `0bf8820e8` "revise the instruments plan for review and
  owner answers" and `27fa7d945` "record Part 2a as built").
- Checked against every finding above, the owner answers of 2026-10-06, the
  built Part 1 (`980ccafc1`, PR #1224) and Part 2a (`7f266d598`, PR #1234),
  the code on `56033baf0`, and the pen (`gGTXF`, `B5PEqI`, `s0zlm`, `oegcz`,
  read through the pencil MCP only, never saved).

### Runs

- Docs only. Claims about the built parts were checked by running their
  suites; see the two part reviews
  (`instruments-p1-in-session/review.md`, `instruments-p2a-in-session/review.md`).

### Owner answers

- "Install sound pack" hidden until a pack mechanism exists: honoured in D6,
  Part 7a (`hRKQL` offers Choose another sound only) and the §6 write-back list.
- Patch ids stay strings: D5 ("Sessions and the working copy store the patch
  id string, never an index") and D7.
- Retry only for an audio-start failure: D6 and Part 7a ("the only Retry on
  the page").
- Computer-key playing is desktop-only: D9 hides the row, its editors and the
  key handler when `isAppliance()` is true and keeps the stored mappings;
  Part 7a and Part 7b test the appliance variant; §6 lists `gGTXF`, `Uv25f`
  and `t00H3H` as appliance-only departures. My earlier answer to question 2
  (keep it on the appliance) is superseded by the owner and is not held
  against the plan.

### Disposition of the earlier findings

| Finding | Status | Where |
|---|---|---|
| H1 mix transaction and Dart bounds | Met, except pan's editor (D1 below) | D3, Part 2b native, Part 3c Dart with one `isSource` predicate and a test per site |
| H2 sink quiescence | Met in design; memory order unspecified (D5 below) | D4, Part 2c, TSAN race test |
| H3 dropped releases | Release lane met (built in 2a); port-overflow ordering hole (D2 below) | D4, §2.2, Parts 2a, 2c, 3b |
| H4 per-slot refusal | Met | D3 ("accepts any source in [0, 40)"), D7 per-slot recall, Part 2b test, Part 5 test |
| H5 sequencing | Met | dependency tree: 3c → 5 → 6 → 7a |
| M1 note-off routing | Met | D4 "note-off first, by origin", §2.3 step 1, four Part 2c tests |
| M2 fade exhaustion | Met (built and tested in Part 1) | D2 |
| M3 joint budget and overload | Met | D2 joint scenario, p99.9, `late`, voice limit and policy |
| M4 Pi gate | Met | Part 1 HARDWARE gates Part 2a's merge |
| M5 slot-keyed targets | Met | D7 instrument-keyed targets, Part 3c |
| M6 source labels | Met | D7 tombstones, Part 3c, Part 6 |
| M7 D6 trigger and Retry | Met | D6, Part 3b rollback test |
| M8 stuck computer keys | Met (desktop builds) | D9 stuck-key rules, Part 7b tests |
| M9 latch sync | Met (built in 2a); replay trigger unclear (D6 below) | D7 synth epoch |
| M10 hardware gates | Met | Part 7b |
| L1-L3, L5-L9 | Met | §7 rows |
| L4 patch application | Met in §2.2, but the §7 row is stale (D7 below) | §2.2 |

### Findings

#### Medium

**D1. Instrument pan has storage but no editor; the plan names an editor that does not exist.**
D3 says instrument pan "is edited from the Mixer's live-input strip, as for
jacks". There is no live-input strip in the Mixer:
- `lib/looper/view/mixer_column.dart` is one strip per track (its doc
  comment, `:25-27`);
- a jack's pan is edited only in Audio routing → Input setup
  (`input_setup_tab.dart:219`, `:259`, dispatching `LooperInputPanChanged`),
  and through the `InputPanTarget` value binding
  (`control_value_target.dart:47`, `:132`).

Part 6 keeps Input setup physical, and the pen's Instruments page has Level
but no Pan (`gGTXF` and `B5PEqI` texts: "Hear live", "Level"; checked through
the pencil MCP). So no part gives instrument pan an on-screen control. The
only way to move it would be a pedal or MIDI binding on `inputPan` index 32+,
which is the slot-keyed target form that D7 is replacing.

Fix: choose one and write it into D3 and a part:
- list instrument sources in Input setup's pan column only (no trim or pair);
- add Pan to the Instruments page's Live sound panel (a pen departure for §6);
- or state that instruments are centred, with no pan.

Also list `InputPanTarget` beside `monitorVolume` in D7's instrument-keyed
targets.

**D2. Port-ring overflow can still leave stuck notes, because the release runs before the queued events.**
§2.2 orders each block as "handle port overflow and lost flags, drain the
release lane, then the port rings". When a port ring overflows, its 255
queued events are still in the ring. Suppose a Note On for key X sits in the
queue and X's Note Off is the event that found the ring full:
1. the next block releases every voice from the port;
2. it then drains the ring and plays the queued Note On X;
3. X's Note Off was dropped, so X is held forever.

The Part 2c oracle ("the next block releases every voice from that port") is
written so that it can pass while this happens, if it inspects voices before
the ring drains.

Fix: act on the overflow only once the consumer has drained the events that
were queued before it. One way is for the producer to store the ring's tail
in the flag, and for the consumer to release the port's voices after its
head passes that tail. Another is to drop queued Note Ons for a port in
overflow. Test it with a Note On queued before the overflowing Note Off.

#### Low

**D3. Part 2a's ordered-merge guarantee is not achievable as specified.**
§2.2 says the callback merges the two rings by the posting sequence, so that
"a note-on and its note-off posted before one block apply in that order". A
two-ring merge that peeks each ring separately has no consistent snapshot of
both. The built code shows this: stuck notes reproduce (Part 2a review, M1).
The plan should say how the consumer gets a consistent cut. One way is a
producer-published high-water sequence: the consumer loads it first and
applies only events up to it. Another is one ring with capacity reserved for
releases.

**D4. Refused patch changes have no owner.**
Since patch changes ride the 256-entry note ring, `le_engine_set_instrument`
returns `LE_ERR_CAPACITY` while Dart note-ons fill that ring (§2.2, Part 2a).
Part 3b retries only releases. An audition Cancel or Apply refused this way
would leave the candidate sound playing, with nothing reported (rule 3).

Fix: either Part 3b retries patch changes as it retries releases, or the ring
refuses note-ons while fewer than `LE_MAX_INSTRUMENTS` + 1 slots are free, so
that a patch change always fits.

**D5. The sink quiescence protocol needs its memory order stated.**
D4's in-flight counter is a Dekker-style handshake. The producer increments
the counter and then loads the sink; detach stores NULL and then loads the
counter. This is safe only if:
- the producer increments the counter before it loads the sink, not after;
- both store-to-load pairs are `seq_cst`.

With acquire/release alone, both sides can miss each other on arm64. Write
the exact sequence into D4, so that Part 2c does not rely on TSAN to find a
use-after-free that only shows under a rare interleaving.

**D6. The replay trigger should be the synth epoch.**
The native reset runs on every configure and every reopen
(`engine.c:883`, `:967` on the Part 2a branch): patches are cleared, the
voice limit returns to 32, and the rings are emptied. D7 and §5 item 13 say
definitions are replayed, but Part 3b's tests say "an engine reopen replays
slots" and "an epoch change clears latches".

Make the epoch change the one trigger that clears latches *and* replays
slots, parameters, the voice limit and routes. A Dart lifetime event is not
the same signal as the native reset.

**D7. Stale text.**
- §7 row L4 still reads "§2.2: a command, the snapshot reports it", but
  §2.2 now says patch changes "are not commands".
- Part 2a's test list includes "sustain contributors cleared", which is a
  Part 2c feature; Part 2a has no contributors.
- D10 says drums "ignore note-off … as the reference does". The reference
  does let a drum hit ring, but it also drops the voice from its token map on
  note-off, so a repeated strike of the same pad overlaps the earlier hit. The
  built voice chokes it instead (Part 1 review, M1). State the re-strike rule
  for drums.

### Notes

- The overload policy (D2) lowers polyphony on any late period while a voice
  sounds, whatever caused the period to be late (a stretch render, a plugin).
  Consider gating it on the instrument share of the callback, which Part 2a
  could time. As written it is acceptable, since a toast announces each
  reduction and the page offers Restore.
- D9's focus wording ("sits above TracksCommands … the claim is checked
  there") is right only if "there" means inside `TracksCommands`, which must
  return ignored for claimed keys so the ancestor handler sees them. Say so
  explicitly.
- Part 2a cannot merge until the Part 1 Pi table is filled in (its own
  HARDWARE criterion).

Verdict: Request changes (D1 and D2; the rest are wording or small additions).

## Delta review (5e36d2666)

Model: Claude Opus (subagent), in-session.

### Scope

- Four commits since `27fa7d945`:
  - `03fa82c5e` (delta review D1-D7);
  - `74e55eab4` (the shared MIDI sink's final layout);
  - `1537c8f96` (aligned with the sink's dispatch order, the MIDI planner's
    edits from the PR #1246 review);
  - `5e36d2666` (Part 2c recorded as built).
- I checked these against the built parts: Part 2a `46327b5ed`, Part 2b
  `e71f8d2ce`, Part 2c `69f6c4cdf` (on #1246 `8c2f43d48`), and Part 3a
  `e44e74064`.

### Disposition of D1-D7

| Finding | Status | Where |
|---|---|---|
| D1 pan editor | Met | D3: Pan beside Level in the Live sound panel (Part 7a), listed in §6 as a `gGTXF` departure; `InputPanTarget` is instrument-keyed (D7) |
| D2 overflow order | Met, and built | D4: the overflow mark carries the ring tail; queued events play first, then the port releases. Built as the sink's `a_gap` with GAP dispatched at its position (Part 2c `test_midi_routing_overflow_releases_after_queue`, `..._gap_releases_at_its_position`) |
| D3 consistent cut | Met, and built | D4 high-water mark; Part 2a `46327b5ed`, whose race test fails three runs out of three against the old code |
| D4 patch room | Met, and built | D4; eight reserved slots in Part 2a; Part 3b retries refused patch changes |
| D5 memory order | Met | D4 states the `seq_cst` sequence on both sides; the sink (#1246) brackets every producer write |
| D6 epoch trigger | Met | D7: the epoch alone clears latches and replays slots, parameters, the voice limit and routes; Part 3b tests that a lifetime event alone does not |
| D7 stale text | Met | §7 L4 row, Part 2a test list, and D10's re-strike rule (built in Part 1 `302452170`) |

### The MIDI planner's dispatch-order edits

- D4's "shared sink, final layout" matches what is built in `le_midi_port.h`
  and `le_midi_ports_drain`:
  - REBOUND on a generation move;
  - GAP at its position;
  - LOST after the pops;
  - stale generations dropped.
- Attach and detach become direct calls, so commands 100 and 101 return to
  the spare range.
- I traced the stream order in `engine_process.c` (`le_midi_ports_drain`)
  and found it consistent with the text.
- The CoreMIDI exception (no native loss on macOS, a development host; the
  Dart poll's close produces LOST plus REBOUND) is stated, not silent.

### New findings

#### High

**D8. Part 2c's own CI gate fails: the arm64 proxy joint scenario with the routing load is over its threshold.**

The Part 2c success criterion (plan line 1114) requires "the proxy bench's
joint scenario with routing passes … CI job native-bench-arm64 green". On
PR #1262 that job fails: "joint worst case p50 <= 37.5% of period (42.72 vs
37.50)" (run 37531063193, job 112500272057).

Without the routing load, the same joint is already close to the limit:
36.3 % on #1234 and 35.3 % on #1261. The load the plan specifies (8 ports ×
255 events plus 256 control events in every period) adds about 7 points.

Fix: decide which way to go and write it into D2:
- keep the full synthetic load and move its threshold;
- or bench a realistic MIDI rate in the joint scenario, and measure the
  ring-full burst as its own scenario with its own threshold.

The Pi set (p99.9 ≤ 75 %) needs the same decision before the owner's
appliance run.

#### Medium

**D9. A route edit leaves the port's expression on the instrument.**

§2.3 and the Part 2c text reset bend, modulation and pressure only when a
port is gone (GAP, LOST or REBOUND). The reference resets them whenever an
instrument's MIDI configuration changes or MIDI is turned off
(`instrument-runtime.js:221-227` `silenceController`, called at `:351`).

Built behaviour (Part 2c review, M1): after MIDI off, or a channel or port
change, a bend or modulation left non-zero keeps bending every later note on
that instrument, touch and control notes included.

Fix: state in §2.3 that a table switch resets, on each instrument, the
expression set by a port or channel that no longer routes to it. Also state
whether held MIDI notes are cut at once (the reference) or end at their key
release (the built rule, which comes from M1).

#### Low

**D10. The block order in §2.2 is not the built order.**

§2.2 (lines 794-797) says the callback drains the control rings, patch
changes included, and *then* each port ring. Part 2c drains the ports first
(`le_midi_ports_drain` at `engine_process.c:6525`, before
`le_instruments_block` at `:6529`). A MIDI note in the same block as a patch
change therefore plays the old patch and is faded 3 ms later (Part 2c
review, L2). Either fix the build, or fix the text and accept the
behaviour.

### Notes

- Part 3a carries a Dart copy of the patch table (`referenceSynthCatalogue`)
  for the mock and the fakes. The plan's stop list names "a Dart-side copy of
  the patch table" (line 1455), and Part 3a's text does not mention one.
  That PR's review covers it; the plan should record the decision either
  way.

Verdict: Request changes (D8: Part 2c's stated CI gate fails; D9).
