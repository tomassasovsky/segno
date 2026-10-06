# Instruments: native synthesis voices as routable inputs, MIDI note input and the Instruments page

<!-- cspell:ignore polyBLEP xorshift Neoverse SCHED denormal Clavinet tonewheel Vibraphone CHANPRESS PITCHBEND rawmidi uinput ADSR SVF Launchkey GTXF RKQL oegcz kole NOTEON NOTEOFF PGMCHANGE halfband clav -->

Status: plan, awaiting the human plan review (`autonomy:merge-gate` on the
build parts). Part 1 is a measured CPU spike whose numbers fix the voice pool
and gate the first user-visible part.
Tracking: #1197 (gap inventory E8-7 to E8-14, and the instrument share of
E7-6 recall ownership and E6-12 shared targets), `autonomy:merge-gate`.
Related: #1040 (one captured MIDI input; Part 4 builds the per-device capture
registry #1040 needs, without deciding its control-path question), #1196
(saved-session migration chain; Part 5 adds a step to it).
Source baseline: `origin/claude/segno-integration` at `5c163d11f`. Every
`file:line` below is on that head unless another file is named.
Precedents: the pitch/time core plan (`2026-10-06-feat-pitch-time-core-plan.md`,
its measured spike and `2026-10-06-pitch-time-spike-findings.md`), the engine
reopen plan (`2026-10-05-feat-engine-reopen-plan.md`), and the settings
transaction owner plan (`2026-10-05-refactor-settings-transaction-owner-plan.md`).

## Accepted behaviour

From `docs/handoff/segno-app/accepted-behavior.md` section 5 (`:357-410`), with
the rows of the other sections that name instruments:

- `:359-362` Settings → Audio routing → Instruments edits sound, controllers and
  live monitoring. There is no separate instrument recorder: add an
  instrument, choose it in Recording inputs, record with normal Tracks
  Record/Play. "Sound-armed recording responds to that source even with Hear
  live Off."
- `:363-367` Persistent identities, own voices and audio buses, fixed
  controller routes. Selecting an editor never redirects notes, releases
  another instrument or changes playback. Simultaneous instruments, channel
  splits and deliberate layers work. New instruments start with their
  controller enables Off.
- `:368-372` MIDI and Computer keys are enabled independently. MIDI uses the
  shared device inventory, All or one channel, an optional range, all 128
  notes with incoming pitch and velocity, and explicit pad remaps. Touch
  keyboard octave paging never restricts a controller.
- `:373-376` Computer mappings are explicit editable rows, defaults included;
  Computer and MIDI editors are separate; Learn a source, then choose notes or
  a chord by playing MIDI, numeric entry or the touch keyboard; parent Cancel
  discards nested edits; numeric fields take encoder entry.
- `:377-381` Pedals & controls shows the actual shared bindings and links to
  built-in, External and MIDI setup. Notes/chords, Sustain and family
  parameters go through the shared owners, with one range and default from
  every surface.
- `:382-387` Sustain Held and Latch from independent contributors; released
  notes ring until every relevant contributor releases; repeated strikes stay
  distinct voices; an explicit CC64 remap does not also sustain; pitch bend,
  modulation and channel pressure reach synthesis; device loss or disable,
  mapping retirement and Cut all sound release the right voices; reconnect
  never resumes stale notes.
- `:388-394` Nineteen Segno synthesis patches in Keys, Organs, Synths, Bass,
  Strings, Drums and Percussion, distinct art, three family parameters each.
  Audition previews without changing the saved sound; Apply commits, Cancel
  restores. Unavailable sounds offer install/retry/another sound and failure
  preserves the setup.
- `:395-398` Display active notes, sustain, controller state and why live sound
  is silent (Hear live, Auto, Mixer mute, no output, missing sound,
  audio-start failure). Parameter drafts stay audible but out of unrelated
  saves.
- `:399-403` Remove asks for confirmation and is blocked during capture from
  that instrument; it removes the live instrument and future routes and FX and
  keeps recorded audio. Last removal leaves Add instrument. Session recall
  restores definitions, mappings and routes; New Loop retains them; recovery
  never asks for a jack for an internal instrument.
- `:228-229` Recording inputs: "Instruments appear alongside physical inputs."
- `:326-331`, `:332-337` Instrument note input is independent of Remote control
  enable; reconnect requires fresh input; held instrument Press requires
  Hold=None; held MIDI notes require a momentary Note/CC on Press.
- `:338-343` Shared targets cover instrument parameters.
- `:461-466` Recall restores instruments; it preserves global MIDI enable,
  real connections and appliance preferences.
- `:568` (section 8 gate) "CPU/polyphony budgets … and packaged/licensed
  playable content" are measured, not assumed; "The 19-patch instrument
  design is accepted."

The executable reference is the prototype in the main checkout's untracked
`docs/design/` (not in git): `instrument-catalogue.js` (family controls `:8-16`, the 19 patches `:17-37`, art `:59-87`), `instrument-runtime.js` (voice synthesis `:60-163`, note, sustain,
expression, release and audition rules `:166-384`),
`2026-09-09-instrument-ux-review.md` and `2026-09-09-virtual-instruments-ux.md`.

### Pen screens this work must match

`segno-ui.pen` (main checkout, 107 MB), group `01 CURRENT UX`, section
`54  Virtual instruments · accepted UX` (`teX79`):

| Screen | Node | Part |
|---|---|---|
| Instruments · independent inputs | `gGTXF` | 7a |
| Instruments · Sound library and audition | `hSy26` | 7a |
| Instruments · Unavailable sound recovery | `hRKQL` | 7a |
| Instruments · Live monitoring feedback | `B5PEqI` | 7a |
| Instruments · MIDI input and keyboard range | `kole9` | 7b |
| Instruments · Computer key mappings | `Uv25f` | 7b |
| Instruments · Learn notes and chords | `t00H3H` | 7b |
| Instruments · Shared pedal and control assignments | `J2uTq` | 8 |

Section `21  Audio routing` (`O51ZiH`): `01 / Recording inputs` (`s0zlm`) and
`02 / Live output routing` (`oegcz`) gain instrument sources (Part 6). The
section has no Instruments screen of its own; the prototype reaches the page
from a quiet "Instruments" header button beside "Input names"
(`audio-routing-study.js:19`, `:23`), and the page's breadcrumb in `gGTXF` is
"SETTINGS / Audio routing".

## What the code does today (file:line)

### Engine inputs

- An input is a bare device channel index `c` in `[0, in_channels)`;
  `LE_MAX_CHANNELS 32` (`segno_engine_api.h:24`),
  `LE_MAX_MONITORED_INPUTS LE_MAX_CHANNELS` (`:670`). There is no input
  identity struct.
- `le_engine_process` (`engine_process.c:6338`) drains the command ring once
  per block (`:6356-6360`), builds the conditioned copy `in_c` in
  `cond_buf` (`:6437-6469`, scratch `LE_COND_SCRATCH_FRAMES 8192`,
  `engine_private.h:660`; oversize blocks fall back and count
  `a_cond_fallback_blocks`), runs the clip detector on raw `in`
  (`:6482-6517`), then a per-frame loop (`:6680`) of `process_input_frame`
  (`:5292`), `mix_tracks_frame` and `mix_monitors_frame`.
- Capture: each lane records one channel, `le_lane.a_input_channel`
  (`engine_private.h:465`); `insample = in[f*ch_in+ic] * in_trim[ic]` guarded
  by `ic < ch_in` and the loopback mask (`engine_process.c:5986-5992`).
- Monitor ("Hear live"): `le_monitor_input` (`engine_private.h:617-646`),
  `monitors[LE_MAX_MONITORED_INPUTS]` (`:1542`), mixed in
  `mix_monitors_frame` (`engine_process.c:5395-5430`) through its FX chain,
  volume, pan gains and output mask, with the performance tap
  `perf_tap_monitor_frame` (`:4288`) when `perf.input_mask` (`uint32_t`,
  `engine_private.h:1338`) has bit `c`; the drain writes `input-%d.pcm`
  (`perf_drain.c:1545`).
- Hear live Off/Auto/On is Dart-only: `MonitorMode`
  (`packages/looper_repository/lib/src/models/input_monitor.dart:15`),
  resolved in `monitorResolved`/`_autoArms`
  (`looper_repository.dart:4598-4623`), pushed as `LE_CMD_SET_MONITOR_INPUT`
  (handler `engine_process.c:3699-3711`, bound `input < LE_MAX_MONITORED_INPUTS`).
- Sound-armed recording already exists: `LE_CMD_ARM` with trigger 1 sets
  `pending_trigger` (`engine_private.h:1172-1175`); the detector takes the max
  of `|in_c|` over the track's lane sources and starts the take frame-exactly
  above `LE_AUTO_RECORD_THRESHOLD` (`engine_process.c:5316-5337`). Sources
  `>= ch_in` or `>= 32` are skipped (`:5326-5327`).
- Lane routing validation: `LE_CMD_SET_LANE_INPUT` maps any channel
  `>= in_channels` or excluded to `-1` (`:3628-3643`); batch routing
  `le_apply_routing` (`:2650-2689`).
- Snapshot per-input arrays are `LE_MAX_CHANNELS` long: `input_peaks`,
  `monitor_peaks`, `output_peaks`, `input_trim` (`segno_engine_api.h:1329-1332`),
  filled at `engine_snapshot.c:488-496`.
- Commands: `le_ring` SPSC of `le_command` (`lockfree_ring.h:33-168`, a union
  that embeds `le_mix_settings`, so a slot is about 2.2 KB),
  `ring_storage[LE_RING_CAPACITY=256]` (`engine_private.h:1818-1824`); the
  highest code is `LE_CMD_REVERSE = 83` (`segno_engine_api.h:520`); receipts
  through `le_request_admit` (`engine_commands.c:2759-2778`).
- Cut all sound exists end to end: `LE_CMD_CUT_SOUND = 73`,
  `handle_cut_sound` (`engine_process.c:2201-2250`),
  `LooperRepository.cutSound` (`looper_repository.dart:5098`),
  `ControlCommand.cutSound` (`lib/control/binding/control_action.dart:209`).
- The appliance runs 96 kHz with 64-frame periods, a 667 µs deadline
  (pitch/time plan, "What the engine does today"); miniaudio periods at
  `engine_miniaudio.c:227-259`; desktop default 48 kHz / 128
  (`lib/audio_setup/cubit/audio_setup_state.dart:75-76`).
- Bench: `src/test/bench/bench_pitch_time.{c,sh}` drives `le_engine_process`
  at 96 kHz / 64 (`bench_pitch_time.c:665`), with `--smoke`, `--assert`,
  `--proxy`, CPU-part detection (`:147-173`) and SCHED_FIFO 70 timing loops;
  CI runs the smoke in `native-tests` (`.github/workflows/main.yaml:239`) and
  the proxy in `native-bench-arm64` (`:181-204`). The dev-machine baseline is
  8 tracks × 8 lanes at p99 11.9 % of the period
  (`2026-10-06-pitch-time-spike-findings.md`, baseline table). No Pi 5 numbers
  exist yet.
- No synthesis code exists anywhere in the engine. The only native DSP that a
  voice can reuse is the TPT state-variable low-pass in `fx_filter`
  (`engine_fx.c:55-75`).

### MIDI

- Native capture (`src/midi/midi.c`): one port per `le_midi` handle;
  `le_midi_open` closes the current port first (`:204-225`); the parser keeps
  Note On/Off, CC and Program and drops pitch bend and channel pressure
  (`:58-96`, `le_midi_internal.h:22-28`); `le_midi_ring_push` filters before
  the ring (`:100-119`) and `le_midi_drain` calls one Dart callback
  (`:121-134`). Linux uses the ALSA sequencer and converts only
  NOTEON/NOTEOFF/CONTROLLER/PGMCHANGE back to bytes
  (`midi_backend_linux.c:136-171`); macOS passes raw packets
  (`midi_backend_apple.c:183-192`). Parser tests live in
  `src/test/test_midi_core.c`.
- Dart: `MidiClient` owns one handle (`packages/midi_client/lib/src/midi_client_base.dart:30-117`);
  `MidiControllerSource.open` closes before opening (`midi_controller_source.dart:43-56`)
  and `_parse` maps only 0x90/0x80/0xB0/0xC0 (`:85-101`).
  `MidiDeviceRepository` pins one selected device, persisted as
  `midi.input_device` (`settings_repository.dart:487-533`), with a 2 s hotplug
  poll (`midi_device_repository.dart:296-346`) and `messages` documented as
  "never gated" by enable or Learn (`:66-69`).
- `ControlCubit` reads `midiDevices.messages` (`lib/control/cubit/control_cubit.dart:219`),
  rejects other sessions (`control_midi.dart:372`), feeds Learn and the
  decoders, and gates dispatch on Remote control enable
  (`_midiCanDispatch`, `:459-468`). Mappings are already keyed by device
  (`MidiSource.device`, `packages/controller_repository/lib/src/midi_protocol.dart:43-56`).
- There is no engine-side note input: the native MIDI ring never reaches the
  audio thread.

### Shared actions and targets (slice 4)

- Actions are stable string keys (`control_action.dart:22-28`), parsed without
  throwing (`:249-281`), unknown keys kept as `UnavailableAction`
  (`:308-320`), grouped in `controlActionCatalogue()` (`:452-484`), run by
  `ControlCubit._runAction` (`control_cubit.dart:2496-2537`).
- Value targets are normalized 0..1 with canonical JSON identity
  (`lib/control/binding/control_value_target.dart:22-33`, `tryParse`
  `:85-165`), resolved through `control_availability.dart:19-64`.
- Pickers: `showControlActionPicker` (`pedal_choice_picker.dart:256-288`),
  External pedals (`external_pedal_page.dart:1411`), MIDI controls
  (`midi_controls_page.dart:885-930`), value pickers
  (`expression_target_picker.dart:15,168`). Missing targets render Change
  control and Remove (`midi_control_cards.dart:261-275`,
  `expression_controls_panel.dart:198,246`).
- MIDI behavior kinds momentary/toggle/trigger/continuous and edges
  (`midi_mapping.dart:6-44`); external conditions held/released
  (`external_controls.dart:13-37`); pedal Press/Hold pairs
  (`pedal_setup.dart:59-120`).
- The computer keyboard has one handler, `TracksCommands.handleKey`
  (`lib/looper/view/tracks_commands.dart:175-360`) on `HardwareKeyboard`,
  wired at `tracks_view.dart:195`; A, S, W, D, E, F, T, G, Y, H, U, J, K are
  partly taken there (A arms performance recording, `:288`; U undo; S
  settings; G signal; F fullscreen).

### Sessions, settings and the app

- Session schema `formatVersion = 11` (`packages/session_repository/lib/src/models/session.dart:847`),
  strict equality on read (`:752-760`). Lane routes parse inputs `-1..31`
  (`:825`). Monitors are `SessionMonitor{input, mode, outputMask, volume,
  muted, chain}` (`:420-505`); input setup `:518-560`.
- The #1196 migration chain does not exist yet on this head (the issue is
  open); Peel and Reverse claim versions 12 and 13.
- Mapping: `lib/session/session_mapping.dart` (`chainsFromLooper` `:27-101`,
  `settingsFromLooper` `:104-168`, `rigFromBundle` `:269-339`). Load:
  `SessionCubit.loadNamed` (`lib/session/cubit/session_cubit.dart:231-385`);
  `applySession` resets what the session does not define
  (`looper_repository.dart:3735-3760`).
- The recalled families are captured by `SessionSettingsCoordinator.capture`
  (`lib/session/application/session_settings_coordinator.dart:61-96`); the
  #1159 family table is `2026-10-05-refactor-settings-transaction-owner-plan.md:175-199`.
- Appliance preferences are flat keys in `SettingsRepository`
  (`packages/settings_repository/lib/src/settings_repository.dart:195-210`);
  input aliases `input_name.<device>.<n>` (`:1804-1828`).
- New Loop is not built (accepted text `:415-419` only).
- Input lists that would need instrument sources all enumerate
  `0..status.inputChannels`: Recording inputs
  (`lib/looper/view/audio_routing/recording_inputs_tab.dart:102-106`), Output
  routing live sources (`output_routing_tab.dart:56`, `:302`), FX live inputs
  (`lib/looper/cubit/fx_cubit.dart:83`, `lib/looper/view/fx/fx_page.dart:908`),
  foot Mixer (`lib/control/model/foot_mixer.dart:228`), monitor value targets
  (`lib/control/binding/control_value_resolver.dart:89`, `:163`), Tuner
  (`lib/tuner/cubit/tuner_cubit.dart:117`). Names go through one resolver,
  `inputName` (`lib/l10n/localized.dart:109-112`), used at every one of
  those sites.
- Audio routing has four tasks (`audio_routing_page.dart:17-29`) and a header
  action for names (`:105-109`); `openAudioRouting`
  (`lib/app/segno_navigator.dart:89`).
- No per-take source label is shown anywhere: every `inputName` call site
  above names a route or a live source, not recorded material.
- Ids: `SlotIds.mint()` (`packages/looper_repository/lib/src/models/fx_slot_ids.dart:23-33`)
  is the established persistent id minter (random prefix plus counter).
- The FX catalogue precedent for shipped art is the data-only package
  `packages/fx_catalogue` (manifest with sha256 per file, PNGs,
  empty-on-missing loader `fx_catalogue_loader.dart:63-113`).
- The native FX parameter schema is duplicated by hand in C and Dart
  (`engine_fx.c:943-1043` against `packages/segno_engine/lib/src/track_effect.dart:334-395`).

## 1. Decisions

### D1. Synthesis runs as native C voices inside the engine callback

Three architectures were considered.

| | A. C voices in `le_engine_process` | B. A separate synthesis thread feeding a ring | C. Hosted synth (FluidSynth, a CLAP/VST3 instrument) |
|---|---|---|---|
| Note-to-sound latency | events applied at the next block start: at most one period (0.67 ms on the appliance) plus the device's own latency | at least one extra period of lookahead plus scheduling jitter of a second RT thread; under load the ring must be primed deeper | as A for an in-process plugin; FluidSynth adds its own block |
| Real-time safety | one RT thread, fixed pools, no locks; the same rules every engine stage follows | two RT threads on four cores that also carry the UI, the cache and restore workers; underrun handling and a second clock domain to test | plugin code is not ours to audit; the existing host has no note-event input (`host/host_clap.cpp:401-414` sends only parameter events) |
| Sound | the accepted 19 synthesis patches | same | needs sampled content (SF2) or third-party plugins; the accepted catalogue is synthesis and factory sample content is explicitly not delivered (`accepted-behavior.md:388-394`, `:568`) |
| Tests | deterministic, sample-exact through `le_engine_process` like every other native test | timing-dependent | outside our test harness |

Decision: **A**. Voices are rendered once per block, before the per-frame
loop, into one preallocated mono bus per instrument; the per-frame readers
take bus samples exactly where they take device samples today. Reasons, in
order: the lowest possible latency for a played instrument; one real-time
thread and one set of RT rules (rule 2); deterministic literal-PCM tests; no
dependency that cannot deliver the accepted sound. B would only pay off if A
does not fit the period, and Part 1 measures that before any engine change.
If Part 1's Pi numbers fail even at 16 voices, the plan returns to the owner
(escalation to `plan-gate`) with the measured fallbacks: cheaper oscillators,
or an internal 48 kHz synthesis rate with the engine's existing 2:1 half-band
(`restore_halfband.c`).

Real-time rules for the synth TU, enforced by review and tests: no
allocation, lock, syscall or libm call inside render (coefficients and the
2048-point sine table are computed at `le_synth_init` on the control thread;
the per-block filter coefficient uses a rational `tan` approximation); every
loop bounded by the voice pool, the block and a per-block event cap; denormals
are already flushed per callback (`engine_process.c:6340`).

### D2. Polyphony and the CPU budget

- One global voice pool, `LE_SYNTH_VOICES`, compiled in. Default 32; Part 1's
  Pi measurement raises it to 64 if the 64-voice threshold passes.
- Up to `LE_MAX_INSTRUMENTS = 8` instruments. The accepted text rules out a
  three-instrument limit (`:390`), not every limit; eight matches the eight
  tracks and keeps every per-instrument array fixed. Add instrument shows the
  reason when eight exist.
- Stealing, in order: the oldest released (or sustained) voice of the same
  instrument, the oldest released voice of any instrument, the oldest held
  voice of the same instrument, the oldest held voice anywhere. A stolen voice
  moves to one of `LE_SYNTH_FADE_SLOTS = 8` fade slots and ramps to zero over
  3 ms, so a steal never clicks and the new note starts in the same block.
  Same-instrument first keeps a layer from silencing an unrelated instrument
  where it can.
- Budget, measured in Part 1 at 96 kHz / 64-frame periods (667 µs), on the
  appliance with SCHED_FIFO and the app running:
  - the costliest patch at 32 voices: added p99 at most 15 % of the period
    (100 µs);
  - 64 voices: at most 30 %;
  - a burst of 32 note-ons inside one block: that block at most 20 %;
  - Part 2a re-measures through `le_engine_process`: the pitch/time baseline
    (8 tracks × 8 lanes) plus 32 voices and eight instrument monitors, p99 at
    most 50 % of the period.
  The arm64 CI proxy asserts p50 at half of each threshold, as the pitch/time
  harness does for the Neoverse runner.

### D3. Instruments are fixed extra sources in the engine's input index space

Every input-keyed structure in the engine and in Dart is indexed by an int
(`a_input_channel`, `monitors[]`, `InputMonitor.input`, `trimDb`,
`SessionLane.inputChannel`, `SessionMonitor.input`). Instruments join that
space at fixed indices instead of getting a parallel set of routes:

- source `s < LE_MAX_CHANNELS` (32) is a device channel, as today;
- source `LE_INSTRUMENT_SOURCE_BASE + k` (32 + k, k < 8) is instrument slot
  `k`; `LE_MAX_SOURCES = 40`.

The index does not depend on the interface's channel count, so a session
records the same number on a 2-in and an 18-in device, and recovery never
looks for a jack (`:402-403`). Recording inputs, Hear live and its Auto
resolution, live level, mute, pan, outputs, input FX with Pre/Post, the
performance capture tap and sound-armed recording all work on instrument
sources through the code that already exists (rule 4: one routing model). The
loopback-excluded mask and the clip detector stay physical-only, behind one
`le_source_is_physical(s)` guard (the shifts `1u << c` are undefined at 32 and
above).

Instrument buses are **mono**. The accepted synthesis renders mono voices into
one gain node per instrument (`instrument-runtime.js:35-48`, `busFor`), so a
take uses one lane of eight, Pan places it, and no stereo-pair rules apply
(the accepted text says instruments cannot be paired as hardware ports,
`2026-09-09-virtual-instruments-ux.md`).

### D4. Notes are routed natively; Dart sends only what Dart owns

- **MIDI notes never pass through Dart.** The OS MIDI thread of each capture
  pushes raw messages into a per-port SPSC ring inside the engine, and the
  audio thread routes them at the next block start. A Dart round trip (the
  `NativeCallable.listener` hop, `midi_controller_source.dart:47-50`, then an
  FFI call back) adds a Flutter event-loop wait that depends on UI load; a
  played keyboard cannot take that.
- **Routing tables are published from Dart** (one immutable table per
  instrument set: MIDI enable, port, channel, range, remaps) through a
  two-slot publish with an audio-thread acknowledgement, so the audio thread
  never reads a table the control thread is writing and never allocates.
- **Computer keys, the touch keyboard and shared actions** (pedal, external,
  MIDI-mapped note/chord/sustain actions) are resolved in Dart, which owns
  those mappings, and sent as note events with an origin token through one
  control-to-audio event ring.
- **Release reaches the original voice** because every voice records its
  origin: `(port, channel, kind, number)` for MIDI, the token for Dart
  sources. A note-off releases voices by origin across every instrument, so
  layers and remapped chords release together and a changed route or
  selection cannot strand a note.
- MIDI note input ignores Remote control enable (`:330`); the native path does
  not read it.

### D5. The 19 patches are a C table; Dart owns only presentation

- `synth_patch.c` holds the 19 patches in catalogue order
  (`instrument-catalogue.js:17-37`): string id, family, oscillator shape,
  partial ratio, sustain level, filter resonance and the three family
  defaults. The seven families' parameter keys and display mappings
  (`:8-16`) are a second C table: key, kind (percent, seconds, hertz) and the
  numeric mapping the voice actually uses.
- The engine exports `le_synth_patch_count`, `le_synth_patch_info` and
  `le_synth_param_info`. Dart reads the catalogue from the engine once and
  formats values from the returned kind and range, so the readout cannot drift
  from the sound (the duplication between `engine_fx.c` and
  `track_effect.dart` that D5 avoids). A Dart test compares the patch ids with
  the l10n keys and art manifest.
- Names, descriptions and family labels are l10n strings keyed by the patch
  id; art is 19 PNGs in a new data-only package `packages/instrument_art`
  laid out like `fx_catalogue` (manifest with sha256, empty-on-missing
  loader). The PNGs are rasterized once from the accepted `art()` drawings
  (`instrument-catalogue.js:59-87`) and committed with the source file's hash
  in the manifest; the app gains no SVG dependency.
- Sessions store the patch **id string**, never an index, and parameters as
  `0..100` numbers by family key, as the catalogue does.
- Where the prototype's display formula and its synthesis disagree (attack is
  shown as `0.08 + v/100 × 2.4 s` but synthesized as `0.008 + v/100 × 0.9 s`,
  `instrument-runtime.js:112`), the native mapping is the one both use.

### D6. "Unavailable sound" without sound packs

All 19 patches are compiled into the engine, so nothing can be partly
installed. A sound is unavailable only when a recalled session names a patch
id this build does not define (a session from a newer version). Then the
instrument keeps its definition, plays nothing, shows "Sound not in this
version", and offers Choose another sound and Retry (Retry re-reads the
catalogue). The pen's `hRKQL` shows "Install sound pack"; that control cannot
be built honestly (`accepted-behavior.md:31-34`: no "placeholder sound packs", unknown capability stays unavailable). This is
listed as question 1; the default stands until the owner answers, and the pen
note must then be updated by the owner, since this plan never edits the pen.

### D7. Recall ownership (E7-6, instrument share)

| Field | Owner | Recall | New Loop (when built) |
|---|---|---|---|
| Instrument list: id, slot, name, patch id, 3 parameters | `InstrumentRepository` | restored | kept |
| MIDI enable, device id, channel, range, remaps | `InstrumentRepository` | restored | kept |
| Computer keys enable and mappings | `InstrumentRepository` | restored | kept |
| Instrument source routes: lane inputs, Hear live mode, live level, mute, outputs, input FX | existing `LooperRepository` source families (keyed by source int) | restored, as for physical inputs | kept |
| Shared assignments that name an instrument (pedal, external, MIDI) | their existing owners | restored with them ("musical MIDI assignments", `:461-466`) | kept |
| MIDI device inventory, control device, Remote control enable, device names | appliance (`SettingsRepository`) | preserved | preserved |
| Held notes, latches, sustain, expression, audition drafts | runtime only | never restored | released |

The working copy persists through a new settings family `instruments` (one
JSON key) registered with `SessionSettingsCoordinator`, so save, recall and
rollback go through the #1159 transaction owner (rule 4). A recalled device
that is not connected shows as disconnected; nothing asks for a port.

### D8. Device captures: one per device, shared by both consumers

Instruments need their devices captured at the same time as the control
device. Opening a second capture of the same port for instruments would
duplicate what #1040 needs anyway, so Part 4 turns `MidiDeviceRepository` into
a registry with one `MidiClient` per captured device: the selected control
device, plus every device an enabled instrument names. The control path keeps
reading only the selected device's session (`control_midi.dart:372`), so
pedal and Learn behaviour does not change (rule 1); deciding whether other
devices may also feed controls stays with #1040.

### D9. New instruments

Controller enables start Off (`:366-367`). Hear live starts **On** at 75 %
(the pen's ready state, `gGTXF` "Hear live … On", "Level 75%"), to outputs
1-2 (the `InputMonitor` default mask `0x3`, `input_monitor.dart:55`): with Off
a newly enabled keyboard is silent until the player finds a second control.
The default computer mapping is the 13 rows A W S E D F T G Y H U J K →
C3..C4 (`Uv25f`). Those keys are only routed to instruments while the
Instruments page is showing, or while Computer keys is On and no text field
has focus; when an instrument has Computer keys On, the Tracks shortcuts that
collide (`tracks_commands.dart:175-360`) are not dispatched for those keys,
and the page says so (rule 3).

### D10. Drums and the controllers they ignore

Drum patches play the defined GM notes only (36 kick, 38 snare, 42 closed
hat, 39 clap, plus 35, 40, 44 as aliases); other notes are shown as received
and produce nothing. Drums ignore note-off and sustain, as the reference does
(`instrument-runtime.js:146`, `:204`, `:213`).

## 2. Native model

### 2.1 Synth state (`synth_voice.h`, pure, no engine types)

- `le_synth`: `sr`, the sine table, `voices[LE_SYNTH_VOICES + LE_SYNTH_FADE_SLOTS]`,
  a monotonically increasing start serial, per instrument `{patch, params[3],
  sustain contributors, expression}`, counters `stolen`, `dropped`.
- `le_synth_voice`: `instrument`, `origin` (u32), `note`, `velocity`, `state`
  (free, held, released, sustained, fading), `serial`, oscillator phases,
  filter state, envelope stage and level, LFO phase, noise seed.
- `le_synth_note_on(s, inst, origin, note, vel)`: a held voice with the same
  origin and instrument that is not sustained is cut first (the reference's
  repeated-strike rule, `instrument-runtime.js:170`); sustained voices
  keep ringing.
- `le_synth_note_off(s, origin)`: every voice with that origin; sustained
  instead of released while its instrument has a contributor.
- `le_synth_render(s, float* const bus[], frames)`: zero, then each active
  voice adds into its instrument's bus; per-voice coefficients once per block.
- Family voice models follow `instrument-runtime.js:60-163`: Keys (two
  partials, transient decay, brightness → cutoff, character → second partial),
  Organs (three partials, rotary LFO at 5.8 Hz, release), Synths (attack,
  release, cutoff with resonance 2.8 for lead), Bass (cutoff, punch → filter
  resonance, release), Strings (bow attack, brightness, vibrato), Drums (kick
  sine sweep 135→47 Hz or 180→38 Hz electronic; snare/hat/clap noise plus
  tone, body → level), Percussion (hardness, decay, tremolo, the 5.4× partial
  for bells). Oscillators: polyBLEP saw and square, triangle, table sine;
  xorshift32 noise seeded from the start serial (deterministic).

### 2.2 Engine state (Part 2a and 2b)

- `le_engine.inst[LE_MAX_INSTRUMENTS]`: `_Atomic int32_t a_patch` (-1 = no
  instrument), `_Atomic uint32_t a_param_bits[3]`; the audio thread applies a
  changed patch at block start and cuts that instrument's voices (an audition
  or Apply never mixes two patches' voices).
- `inst_bus`: `LE_MAX_INSTRUMENTS × LE_COND_SCRATCH_FRAMES` floats allocated
  with `cond_buf` at configure; a larger block renders silence and counts
  `a_inst_fallback_blocks` (the conditioning precedent, `:6460-6467`).
- `inst_ring`: SPSC `le_inst_event {u8 kind, slot, note, velocity; u32
  origin; f32 value}`, 256 entries; kinds note-on, note-off, sustain-on,
  sustain-off (origin = contributor token), retire (release voices and
  sustain of one origin), expression.
- `ports[LE_MAX_MIDI_PORTS = 8]`: `_Atomic uint32_t a_gen` and an SPSC ring of
  `{u32 gen; u8 status, d1, d2}` (256). Producer: that port's OS MIDI thread;
  consumer: the audio thread. Events whose `gen` is not the current one are
  dropped.
- `routes[2]` plus `_Atomic int32_t a_routes_live`, `a_routes_seen`: per
  instrument `{midi_enabled, port, channel (0 = All), low, high, remap_count,
  remaps[32] {port, channel, kind (note | cc), number, count, notes[8]}}`
  (about 3 KB per slot).
- Per block, after the command drain: apply patch changes, drain `inst_ring`
  and each port ring (at most 256 events per ring per block; the rest wait one
  block and are counted), render the buses, publish per-instrument peaks.
- `le_source_sample(in_c, ch_in, inst_bus, f, s)` is the one accessor used by
  capture (`:5986-5992`), the monitors (`:5395-5430`, loop bound widened to
  `LE_MAX_SOURCES`), the sound trigger (`:5316-5337`) and the performance tap.
  The tuner keeps device channels only (E8-14).

### 2.3 MIDI routing on the audio thread

For each port event (status, d1, d2):
1. A remap matches when its port, channel (or All), kind and number match;
   matched remaps play their notes with origin `(port, ch, kind, number)` and
   suppress the ordinary handling of that message for that instrument (an
   explicit CC64 remap does not also sustain, `:384`).
2. Otherwise, for each instrument with MIDI enabled whose port and channel
   match: Note On within `[low, high]` plays the incoming note and velocity;
   Note Off releases by origin (always, even out of range, so a range edit
   cannot strand a note); CC64 ≥ 64 adds the contributor `(port, ch)` and < 64
   removes it; CC1 sets modulation; pitch bend sets bend (±2 semitones); channel
   pressure sets pressure.
3. Several instruments may match one message: that is a layer; channels and
   ranges make splits.

Port detach (device lost, capture closed, engine reconfigure) bumps the
port's generation and posts a reset: voices whose origin names that port are
cut, its sustain and expression contributions are removed, and queued events
from the old generation are dropped. Reconnect gets a new generation, so
nothing old replays (`:386-387`).

## 3. Dart model

- `packages/instrument_repository` (new, layered like the other repositories,
  depends on `segno_engine`, `controller_repository`, `settings_repository`):
  - `Instrument {id (SlotIds.mint), slot, name, soundId, params (key → 0..100),
    midi: MidiNoteInput {enabled, deviceId, channel (null = All), low, high,
    remaps}, keys: ComputerKeys {enabled, mappings}}`.
  - `InstrumentSound` and `InstrumentParameter` read from the engine catalogue
    (`le_synth_patch_info` / `le_synth_param_info`).
  - `InstrumentRepository`: add (first free slot, default name from the
    sound), rename, choose sound (audition draft → Apply/Cancel), set
    parameter (draft or committed), set MIDI input, set computer mappings,
    remove; compiles and publishes the routing table; resolves computer keys,
    touch keys and action tokens to note events; keeps latch state per token;
    attaches captures to ports; projects `InstrumentsState` (definitions,
    per-instrument activity from the snapshot, port online state); persists
    the `instruments` family; re-publishes everything after an engine
    lifetime change (the reopen plan's replay path).
- `LooperRepository` stays the owner of everything keyed by source: it gains
  `liveSources` on `LooperState` (device channels then instrument sources with
  their names) and `retireSource(int)`, which clears that source's lane routes
  on non-capturing tracks and resets its monitor, and refuses while a track
  fed by it is pending or capturing.
- Removal is an app-layer sequence (`lib/instruments/application/`): guard
  through `LooperRepository`, then `retireSource`, then
  `InstrumentRepository.remove`; a failed step leaves the instrument in place
  and reports why (rule 2).

## 4. Parts

Each part is independently mergeable, keeps the app working and shows no
unfinished destination: nothing reaches the UI before Part 6. Production-line
estimates exclude tests, bench tooling, generated bindings, assets and docs.
Engine numbers come from the central ledger (main session, 2026-10-06):
instruments own commands 96-111, perf-log facts 336-339 and result codes -14
and -15. Part 2a takes commands 96-99 (`LE_CMD_SET_INSTRUMENT`,
`LE_CMD_INSTRUMENT_CUT_SLOT` if a separate cut proves necessary, two spare),
Part 2b takes 100-103 (port reset and route-flip acknowledgement); 104-111
stay reserved. `LE_ERR_NO_INSTRUMENT = -14` refuses a route or monitor on an
empty instrument slot; `LE_ERR_UNKNOWN_PATCH = -15` refuses a patch index the
build does not define. Facts 336-339 are reserved for instrument note
provenance in performance stems, which no part here logs yet. The Session
schema number is assigned at landing (Part 5).

### Part 1. Measured synthesis spike: voice TU, patch table, bench (about 550 production lines)

Goal: the 19 patches render correctly and deterministically in a pure TU, and
the appliance cost of the voice pool is measured before any engine change.

1. `src/core/synth_voice.{h,c}` (§2.1) and `src/core/synth_patch.c` (§D5),
   pure C, no `_Atomic`, no engine types. Wire them where every explicitly
   listed TU is wired: `src/CMakeLists.txt` (beside `restore_halfband.c`,
   `:84-88`), `run_native_tests.sh:70-76`, `tool/build_test_lib.sh:40-45`, the
   bench script, and the macOS forwarders in
   `macos/segno_engine/Sources/segno_engine/` and `macos/Classes/`. Export
   `le_synth_patch_count`, `le_synth_patch_info`, `le_synth_param_info` in
   `segno_engine_api.h` (pure reads; they are the only API this part adds).
   Run the PROGRESS C++17 shim repro with `synth_voice.h`.
2. `src/test/test_engine_synth.h`, included from `test_engine_core.c` beside
   `test_engine_read_head.h` (`:33545`). Literal oracles, each failing without
   the code:
   - the table: count 19; ids in order `piano, keys, clav, organ, reed, lead,
     pad, pluck, bass, synth-bass, sub, strings, violin, cello, drums,
     electronic-drums, marimba, vibes, bells`; families; defaults exactly the
     catalogue's (`piano` 68/72/22 … `bells` 80/90/0);
   - `sub`, note 69, velocity 127, 48 kHz, one second held: 880 ± 2 zero
     crossings (440 Hz); note 81: 1760 ± 2;
   - after note-off, the voice's release time from `le_synth_param_info`
     (`sub` release 30 → 0.08 + 0.30 × 2.4 = 0.80 s) plus one block later every
     sample of the bus is exactly `0.0f` and the active count is 0;
   - velocity 64 peak within 1 % of 64/127 of the velocity-127 peak (`sub`);
   - `drums` note 36: the first period measures 135 ± 4 Hz and the
     zero crossings over 0.40-0.70 s measure 47 ± 2 Hz (default decay 40 gives
     a 0.722 s hit whose 135 to 47 Hz sweep ends at half of it); a note-off changes nothing;
     note 60 renders exact silence;
   - pool: 33 note-ons on one instrument with a 32 pool leave 32 active and 1
     fading; the oldest origin is the one stolen; after 3 ms that voice adds
     exactly 0; with instrument A at 31 voices and B at 1, A's next note
     steals A's oldest, and B's voice is untouched (its samples equal a solo
     render of B);
   - determinism: two `le_synth_init(…, seed)` instances render byte-identical
     10 s of all 19 patches; every sample finite and |x| ≤ 1;
   - parameters: `lead` at cutoff 0 rendering note 96 has under 10 % of the
     RMS it has at cutoff 100;
   - render at 1, 64, 127 and 512 frames per block produces the same samples
     for the same events (block-size independence).
3. `src/test/bench/bench_instruments.{c,sh}` on the `bench_pitch_time`
   pattern (same flags, CPU-part detection, SCHED_FIFO 70 timing loops,
   `--smoke`, `--assert`, `--proxy`, the Cortex-A76 refusal). Scenarios at 96
   kHz / 64 frames over 60 s: every patch at 8 voices (to find the costliest);
   the costliest patch and a mixed set at 8, 16, 32 and 64 voices; a 32-note
   burst in one block; `baseline` (`le_engine_process`, 8 × 8 lanes, the
   pitch/time scenario) for the sum. Reports p50 / p99 / max / mean in µs and
   as % of the period, plus `sizeof(le_synth)`.
4. CI: `native-tests` runs `bench_instruments.sh --smoke`; `native-bench-arm64`
   also runs `bench_instruments.sh --budget-us 667 --assert --proxy` with
   `shell: bash` (the pitch/time pipefail lesson) and uploads the binary.
5. `docs/plan/2026-10-06-instruments-spike-findings.md`: tables, CPU model,
   scheduling obtained, verdicts, and the chosen `LE_SYNTH_VOICES`.

```success-criteria
GOAL: The 19 Segno patches render as specified in a pure, allocation-free C voice TU, and the cost of 8 to 64 voices is measured at 96 kHz / 64-frame periods on the arm64 proxy and, when the owner runs the artifact, on the appliance Pi 5.
SUCCESS CRITERIA:
- The patch table, frequencies, release-to-exact-silence, velocity, drum sweep, stealing order, fade-to-zero, cross-instrument isolation, determinism and block-size independence oracles pass in the plain, ASAN and telemetry-off builds. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- The bench builds and its smoke run passes; the FFI symbol check passes with the three catalogue exports; the C++17 shim repro compiles with synth_voice.h. | verify: bash packages/segno_engine/src/test/bench/bench_instruments.sh --smoke && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && manual: the docs/PROGRESS.md shim repro with synth_voice.h included
- The arm64 proxy run passes the p50 thresholds (half of the Pi set) and publishes the artifact; the findings document records the tables. | verify: CI job native-bench-arm64 green on the PR head (bash packages/segno_engine/src/test/bench/bench_instruments.sh --budget-us 667 --assert --proxy on ubuntu-24.04-arm)
- Dart gates unchanged. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- HARDWARE (does not gate this part; gates Part 6's merge): on the appliance Pi 5, app running, SCHED_FIFO, the 32-voice costliest-patch p99 is at most 15 % of the period, 64 voices at most 30 %, the 32-note burst block at most 20 %; LE_SYNTH_VOICES is set from the result. | verify: manual: copy the native-bench-arm64 artifact to the appliance and run bench_instruments.sh --budget-us 667 --assert; record the output in the findings document
NON-GOALS:
- Any engine-state, command, snapshot, Dart or UI change beyond the three pure catalogue exports.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && bash packages/segno_engine/src/test/bench/bench_instruments.sh --smoke
```

### Part 2a. Native instrument sources: slots, buses, the source space (about 650 production lines)

§D3 and §2.2 without MIDI ports: `inst[]`, `inst_bus`, the synth inside
`le_engine_process`, `le_source_sample` at capture, monitors, trigger and the
performance tap; `LE_MAX_MONITORED_INPUTS = LE_MAX_SOURCES` (`segno_engine_api.h:670`);
the snapshot arrays `input_peaks`, `monitor_peaks`, `input_trim` widened to
`LE_MAX_SOURCES` (`:1329-1332`, instrument entries are the bus peak and trim
1); `perf.input_mask` to `uint64_t` (`engine_private.h:1338`) with the arm
config and the drain; validation at `LE_CMD_SET_LANE_INPUT` (`:3628-3643`),
`le_apply_routing` (`:2650-2689`) and `LE_CMD_SET_MONITOR_INPUT`
(`:3699-3711`) accepting a source when it is a device channel below
`in_channels` or an instrument slot with a patch; the physical-only guard for
the excluded and clip masks. API: `le_engine_set_instrument(e, slot,
patch_index or -1, params[3])` (a command; the snapshot reports the applied
patch), `le_engine_set_instrument_param(e, slot, index, value)` (atomic
store, read once per block), `le_engine_instrument_event(e, const
le_inst_event*)` (pushes `inst_ring`, returns the existing `LE_ERR_CAPACITY` when
full and counts it). `handle_cut_sound` (`:2201`) moves every voice to a 3 ms fade and
clears sustain and expression. Configure re-initializes the synth for the new
rate. Snapshot: per instrument `{patch, active_voices, sustained, active_notes
[4 × u32], bend, mod, pressure, peak, events_dropped}` and pool counters.

Tests (`src/test/test_engine_instruments.h`, literal PCM through
`le_engine_process`):
- a `sub` instrument in slot 0, lane input 32, a 48 kHz one-second note
  recorded on track 1: the lane PCM equals an offline `le_synth_render` of the
  same events sample for sample;
- monitor 32 off: output exactly zero while the capture above still matches
  (sound-armed with Hear live Off, `:361-362`); monitor on at volume 0.5 and
  pan 0: each output equals bus × 0.5 × the pan-law gain;
- an armed track with trigger 1 and lane input 32 starts recording at the
  first frame whose bus sample exceeds `LE_AUTO_RECORD_THRESHOLD`, frame-exact,
  with a note-on in the middle of a block;
- a slot with no patch: lane input 32 is refused (`-1`), monitor 32 refused;
- Cut all sound: the bus is exactly zero from 3 ms after the cut block;
- a patch change cuts that slot's voices and leaves slot 1's samples equal to
  its solo render;
- the existing suite stays byte-identical (sources below 32 unchanged);
- the tuner never reads source 32;
- a block above `LE_COND_SCRATCH_FRAMES` renders silence and counts one
  fallback;
- the performance tap writes `input-32.pcm` with the monitored signal.
The bench gains `engine_instruments`: baseline 8 × 8 plus 32 voices and eight
instrument monitors.

```success-criteria
GOAL: Up to eight native instruments render inside the callback into mono buses that are ordinary sources 32 to 39 for capture, sound-armed recording, Hear live, FX, outputs and the performance tap, with Cut all sound releasing them and sources below 32 unchanged.
SUCCESS CRITERIA:
- Literal PCM proves capture equals the offline render, monitor gating and gains, the frame-exact sound trigger, refusal of empty slots, Cut, patch-change isolation, tuner exclusion, the fallback counter and the performance stem, and every pre-existing test is byte-identical. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and telemetry-off builds pass; the C++17 shim repro compiles with every changed core header. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && manual: the docs/PROGRESS.md shim repro
- Bindings regenerate and format cleanly, the symbol check passes, the Dart suites still pass with the widened snapshot arrays, and the proxy bench meets its engine_instruments threshold. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && /Users/Tomas/development/flutter/bin/flutter test && CI job native-bench-arm64 green
- HARDWARE (gates Part 6's merge): on the Pi 5 the engine_instruments p99 is at most 50 % of the period. | verify: manual: bench_instruments.sh --budget-us 667 --assert on the appliance; record it in the findings document
NON-GOALS:
- MIDI ports, routing tables, sustain contributors, Dart seam, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2b. Native MIDI note routing, sustain and expression (about 550 production lines)

§2.2 ports and routes, §2.3. `midi.c`: an engine sink on `le_midi`
(`_Atomic` function pointer, context, port, generation) called from
`le_midi_ring_push` before the Dart filter, wait-free; the parser gains
`LE_MIDI_PITCH_BEND` (0xE0, 14-bit value) and `LE_MIDI_CHANNEL_PRESSURE`
(0xD0), still filtered out of the Dart ring so `_parse` is unchanged; the
Linux backend converts `SND_SEQ_EVENT_PITCHBEND` and `SND_SEQ_EVENT_CHANPRESS`
(`midi_backend_linux.c:136-171`). API: `le_engine_attach_midi_input(e, m,
port)`, `le_engine_detach_midi_input(e, port)`,
`le_engine_set_instrument_routes(e, const le_inst_routes*)` (copies into the
inactive slot once the audio thread acknowledged the previous flip; returns
the existing `LE_ERR_NOT_READY` otherwise and the caller retries on the next snapshot).
Sustain contributors in the synth: per instrument a 16-bit channel mask per
port and a 32-bit token mask for Dart contributors; latch versus held is a
Dart concern (Part 3b), the engine only sees contributor on and off.

Tests (`test_engine_instruments.h` and `test_midi_core.c`), each failing
without the change:
- split: instrument A on channel 1, B on channel 10; note 60 on channel 1
  sounds only A (B's bus exactly zero), note 36 on channel 10 only B;
- layer: A and B both on All: one note-on gives one voice in each; one
  note-off releases both;
- range: A with low 48, high 72: notes 47 and 73 produce nothing, 48 and 72
  sound; a note-off for 60 after the range moves to 61..72 still releases it;
- remap: port 0, channel 10, note 36 → chord 48, 52, 55 on A: three voices
  with that origin, one note-off releases all three; the ordinary note 36 is
  not also played on A;
- CC64 remapped to a chord does not sustain; unmapped CC64 does;
- sustain from two contributors (CC64 on port 0 and a token): a released
  voice keeps rendering until both are off, then releases; a repeated strike
  under sustain gives two distinct voices;
- pitch bend 16383 on a `sub` note 69: 880 × 2^(2/12) ± 2 zero crossings per
  second; pressure 127 raises the peak by 25 % ± 1 %;
- drums ignore CC64 and note-off;
- detach port 0 with A held from port 0 and B held from a token: A's voice is
  cut (exact zero 3 ms later), B rings; an event queued under the old
  generation is dropped; a fresh note after re-attach plays;
- the parser: 0xE0 and 0xD0 classify, and still do not reach the Dart ring;
- ring overflow: 300 events in one block play the first 256 now, the rest in
  the next block, and the counter reports 44 deferred;
- routes publish: a second publish before the acknowledgement returns
  `LE_ERR_NOT_READY`; under ASAN a publish racing the callback for 10⁵ blocks
  never reads a half-written table (`test_engine_races.c` pattern).

```success-criteria
GOAL: MIDI from any attached capture reaches instrument voices on the audio thread without Dart, with channel splits, layers, ranges, chord remaps, sustain from independent contributors, bend, modulation and pressure, and a detach that silences only that device and never replays old events.
SUCCESS CRITERIA:
- The split, layer, range, remap, CC64, contributor, bend, pressure, drum, detach and generation, overflow and publish oracles pass, including the race test under ASAN. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- The Dart MIDI path is unchanged: midi_client and controller tests pass without edits. | verify: (cd packages/midi_client && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test
- Bindings and symbols. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)"
NON-GOALS:
- Dart seam, device registry, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3a. Dart engine seam (about 300 production lines)

A new role `InstrumentHost` in `packages/segno_engine/lib/src/audio_engine.dart`
beside `MonitorControl` (`:1125`) and composed into `AudioEngine` (`:1513`):
`synthCatalogue()`, `setInstrument`, `setInstrumentParam`,
`instrumentEvent`, `setInstrumentRoutes` (with the busy retry), and
`attachMidiInput(MidiCaptureHandle, port)` / `detachMidiInput(port)`, where
`MidiCaptureHandle` wraps `Pointer<le_midi>` and is exposed by `MidiClient`
(`midi_client` already depends on `segno_engine`). `EngineSnapshot` gains the
instrument and pool fields and the widened per-source arrays.
`NativeAudioEngine`, `MockAudioEngine` (a deterministic fake voice model: it
records events and reports voices, no audio) and the four fakes
(`test/helpers/fake_audio_engine.dart` and the package fakes).

```success-criteria
GOAL: Repositories can read the synthesis catalogue, configure instrument slots, send note events, publish routes, attach captures and observe instrument activity through one role interface, with the native and mock engines and every fake implementing it.
SUCCESS CRITERIA:
- A native-library test reads 19 patches and their parameter info, sets a slot, sends a note and sees one active voice in the snapshot, then attaches and detaches a capture handle. | verify: (cd packages/segno_engine && SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test)
- Mock and fakes compile and pass; the app suite is unchanged. | verify: /Users/Tomas/development/flutter/bin/flutter test
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Instrument domain, persistence, UI.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3b. Instrument domain and repository (about 650 production lines)

`packages/instrument_repository` (§3): models with JSON, the default A–K
mapping, slot allocation, the routing-table compiler (definitions plus port
assignments → `le_inst_routes`), the computer-key, touch-key and action-token
note dispatch with latch state, audition drafts, the activity projection, the
`instruments` settings key (JSON, through `SettingsRepository`), replay after
an engine lifetime change, unknown sound ids kept as unavailable (D6), and
`LooperRepository.liveSources` / `retireSource` with the removal guard. No
UI, no shared assignments, no session schema yet. The working copy is written
only after the engine acknowledged the change; a failed write restores the
previous definition and reports it.

Tests: repository tests against `MockAudioEngine` and a fake
`SettingsRepository` (add fills the first free slot and starts with both
controller enables off and Hear live On; the ninth add is refused; Cancel
after an audition sends the saved patch; a parameter draft is not written to
the store; removal is refused while a track fed by source 32 is pending or
capturing and clears its routes otherwise; an unknown sound id loads as
unavailable and sends no patch; a latch token press-press releases; an engine
reopen replays slots and routes), the compiler (splits, layers, remaps
truncated to the native caps with a reported problem rather than silently),
and one actual-native case (`packages/instrument_repository/test/instrument_native_test.dart`)
that plays a note through the repository and sees it on the snapshot.

```success-criteria
GOAL: Instruments exist as persistent definitions with stable identities and slots, drive the engine through one repository, persist across restart, survive engine reopen, and can be removed only when no capture depends on them, still with no UI.
SUCCESS CRITERIA:
- Repository, compiler and native cases pass. | verify: (cd packages/instrument_repository && SEGNO_ENGINE_LIB="$(bash ../segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test)
- LooperRepository's liveSources and retireSource cases pass with the package suite. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test)
- App suite and static gates. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Device captures, session schema, UI, shared actions.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 4. One capture per device (about 350 production lines)

§D8. `MidiDeviceRepository` keeps a map of device id → `MidiControllerSource`
(one `MidiClient` each) for the selected control device plus every device an
enabled instrument names (`InstrumentRepository` supplies that set). The
hotplug poll (`midi_device_repository.dart:296-346`) opens and closes each;
connection state becomes per device; `messages` carries the device id it
already has in `MidiInputSession`. `InstrumentRepository` attaches each open
capture to a port slot and detaches on loss, close and engine lifetime
change. `ControlCubit` still filters to the selected device's session
(`control_midi.dart:372`); its behaviour is unchanged. Refs #1040.

Tests: two fake devices, A selected for control, B named by an instrument:
both captured; B's messages never reach the decoders or Learn; A's do; B
unplugged closes only B, detaches its port and marks the instrument
disconnected; B back reopens and re-attaches with a new generation; selecting
B for control does not open a second capture of B. The existing
`midi_device_repository` suite passes unchanged in its single-device cases.

```success-criteria
GOAL: Every device an instrument uses is captured at the same time as the control device, with one capture per device, independent loss and reconnect, and no change to what reaches pedal control and Learn.
SUCCESS CRITERIA:
- The two-device registry, isolation, loss and reconnect cases pass, and the existing single-device cases pass unchanged. | verify: (cd packages/midi_device_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/instrument_repository && /Users/Tomas/development/flutter/bin/flutter test)
- ControlCubit's MIDI suite is unchanged and green. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: on the appliance, a USB keyboard and the console board connected together: the board's footswitches still drive the pedal path while the keyboard plays an instrument; unplugging the keyboard silences only that instrument; plugging it back in needs a fresh key press. | verify: manual: appliance session with two USB MIDI devices, recorded in the PR
NON-GOALS:
- Letting non-selected devices feed controls (#1040's question), UI.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages
```

### Part 5. Session recall and the settings family (about 450 production lines)

§D7. `Session.instruments` (definitions as in §3); lane routes and monitors
accept sources up to 39 (`session.dart:825` and the monitor parse); the
schema version is the next free number at rebase, and its step is added to
the #1196 chain (an absent list becomes empty and is recorded as defaulted).
`session_mapping.dart` maps the list both ways; `SessionCubit.loadNamed`
applies instruments before `applySession` routes lanes to their sources
(`session_cubit.dart:231-385`), so a lane routed to 32 never meets an empty
slot; `SessionSettingsCoordinator.capture` gains the family; recall replaces
the working copy through the owner, with rollback on failure. A recalled
device id that is not present shows disconnected; a recalled unknown sound is
unavailable (D6). This part waits for #1196's chain to land (the owner's
2026-10-06 rule that every schema bump adds its step).

Tests: round trip of every instrument field; a session without instruments
from the previous version migrates through the chain with the field listed as
defaulted; a lane on source 33 and a monitor on 33 round-trip; recall of a
session with two instruments into a rig with three leaves two and their
routes; a failed write during recall leaves the previous instruments and
reports it; held notes are never restored (the mock engine sees no note
event after recall); the existing fixture round trips stay byte-identical
apart from the version and the new field.

```success-criteria
GOAL: Saved sessions restore instrument definitions, mappings and routes, appliance-level MIDI state is untouched by recall, older sessions migrate through the chain, and a failed recall leaves the previous setup.
SUCCESS CRITERIA:
- Session round trips, the migration step, recall with fewer instruments, rollback and no-replay cases pass. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session
- Full suites and static gates. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- New Loop (not built; §D7 states its rule), UI.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 6. Instrument sources in routing, FX and Mixer; Tuner exclusion (about 400 production lines)

E8-14 and the routing half of E8-7, matching `s0zlm` and `oegcz`: every site
in "Input lists" above reads `LooperState.liveSources` instead of
`0..inputChannels`; instrument cards show "Instrument" where a port number
shows (`audio-routing-study.js:16-17`); `inputName` resolves sources 32-39 to
the instrument's name; Input setup lists device channels only (trim and
pairing do not apply); the Tuner keeps device channels only. Recording a
source is locked while armed or capturing exactly as for jacks. Instruments
are not reachable from here until Part 7a adds the page, so in this part
sources appear only for instruments created by a recalled session or the
working copy (both from Parts 3b and 5); with none, every screen is as today.

Tests: widget and cubit tests for each of the eight sites with one instrument
present and absent; golden updates for the routing tabs with an instrument;
the Tuner list unchanged with an instrument present.

```success-criteria
GOAL: Instruments appear beside physical inputs wherever a live source is chosen, routed, monitored, mixed or given FX, never in Input setup or the Tuner, and every screen is unchanged when no instrument exists.
SUCCESS CRITERIA:
- The site tests, goldens and the unchanged-without-instruments cases pass. | verify: /Users/Tomas/development/flutter/bin/flutter test
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE (merge gate for this part, the first that can expose instruments): the Part 1 and Part 2a Pi thresholds have been met and recorded in the findings document. | verify: manual: the findings document's Pi 5 table shows both verdicts passing
NON-GOALS:
- The Instruments page, controller editors, shared actions.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 7a. The Instruments page, sound library and live feedback (about 700 production lines)

`lib/instruments/` (cubit plus views) matching `gGTXF`, `hSy26`, `hRKQL` and
`B5PEqI`: the Audio routing header gains the quiet "Instruments" action
beside the names action (`audio_routing_page.dart:105-109`); the page has the
instrument strip, Add instrument, the selected instrument's sound card with
its three parameter sliders (double tap resets to the patch default,
`accepted-behavior.md:87`), rename, remove (confirmation, the capture guard's
reason on refusal, last removal leaves the empty Add instrument state), the
touch keyboard or pads (octave paging changes the view only), "Played by"
summary rows (toggles; the MIDI and Computer rows open Part 7b's editors, so
in this part they show the summary only), the Live sound panel (Hear live,
Level, Outputs, Effects, Recording inputs links into the existing routing and
FX pages for source `32 + slot`), and the feedback line: active notes,
Sustain, and the silent reasons in the reference's order
(`virtual-instruments.js`, `feedback`): audio start failure, sound
unavailable, Live monitoring off, Muted in Mixer, No audible output, Live
monitoring waiting (Auto), No controller assigned, device disconnected. The
sound dialog (`hSy26`) lists the seven families and their patches with art,
auditions on selection, and commits on Apply or Add instrument; Cancel
restores. The unavailable state (`hRKQL`) offers Retry and Choose another
sound (D6). Art comes from `packages/instrument_art` (assets only, not
counted). l10n strings for names, descriptions, families and parameter labels
in every ARB.

Tests: cubit sequences (add, audition, Cancel restores, Apply commits, draft
parameter not saved, remove refused while capturing, last removal) and
widget/golden tests for the four screens at the console size, plus the
silent-reason ordering for each cause.

```success-criteria
GOAL: A player can add, audition, choose, adjust, rename and remove instruments, play them by touch, see why one is silent, and reach its live routing and effects, matching pen screens gGTXF, hSy26, hRKQL and B5PEqI.
SUCCESS CRITERIA:
- Cubit, widget and golden tests for the four screens and the reason order pass. | verify: /Users/Tomas/development/flutter/bin/flutter test test/instruments
- Full suites, static gates and the ARB coverage. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: on the appliance, an instrument recorded through normal Tracks Record/Play with Hear live Off captures audio; touch-keyboard latency and the 19 patches are checked by ear at 96 kHz / 64 frames with no late periods in the callback telemetry during a 32-note chord. | verify: manual: appliance session per docs/PROGRESS.md, callback telemetry read through le_engine_get_callback_telemetry, recorded in the PR
NON-GOALS:
- MIDI and computer-key editors, Learn, shared assignments.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 7b. Controller editors: MIDI input, computer keys, Learn (about 650 production lines)

Matching `kole9`, `Uv25f` and `t00H3H`: the MIDI input sheet (device from the
shared inventory with online state, channel All or 1-16, lowest and highest
note, encoder entry on each field, "Incoming pitch and velocity pass through
the full selected range", Note & pad remapping list with Learn source and
target notes), the Computer key mappings sheet (editable and removable rows,
Add mapping), the mapping editor (Learn the key, choose notes by playing MIDI,
numeric entry or the touch keyboard, View C3–C5 paging). Outer Done/Cancel is
atomic and Cancel discards nested edits (`:373-376`). Learn reads the
device's messages from the registry (Part 4). Computer keys reach
`InstrumentRepository` from one app-level `HardwareKeyboard` handler under
the D9 rule; while it claims a key, `TracksCommands` does not dispatch it.

Tests: sheet cubits (Cancel discards a remap added inside, Done publishes one
compiled table, out-of-range fields clamp with the encoder), Learn of a pad
note and of a three-note chord, the default 13 rows, the key-claim rule
against `TracksCommands`, goldens for the three screens.

```success-criteria
GOAL: Each instrument's MIDI device, channel, range and pad remaps and its computer key mappings can be edited, learned and cancelled as one draft, matching pen screens kole9, Uv25f and t00H3H.
SUCCESS CRITERIA:
- Sheet, Learn, default-mapping, key-claim and golden tests pass. | verify: /Users/Tomas/development/flutter/bin/flutter test test/instruments
- Full suites and static gates. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: a 61-key controller plays all its keys at full pitch range on one instrument while its pads play a remapped drum instrument on another channel; sustain pedal Held; bend, modulation and pressure audible; unplug and replug never resumes a held note. | verify: manual: appliance session with a USB keyboard controller with pads, recorded in the PR
NON-GOALS:
- Shared pedal, external and MIDI assignments.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages
```

### Part 8. Shared note, chord, sustain and parameter assignments (about 600 production lines)

E8-13 and the instrument share of E6-12, matching `J2uTq`: `InstrumentNoteAction`
(`instrument:<id>:notes:<n,n,…>:<held|latch>`) and `InstrumentSustainAction`
(`instrument:<id>:sustain:<held|latch>`) in the action catalogue
(`control_action.dart:452-484`, parsed without throwing, unknown instrument →
`UnavailableAction` with Change control and Remove); `InstrumentParamTarget`
(`{"ctl":"instrument","id":…,"param":…}`) in `control_value_target.dart`
mapping 0..1 to the patch range, one default for every surface; dispatch from
`ControlCubit._runAction` to `InstrumentRepository` with the binding's id as
the origin token, so retiring or changing a binding retires its latch and its
voices; validation that a held instrument Press requires Hold=None and a held
MIDI action requires a momentary Note or CC on Press, with the conflict
explained and Save disabled (`:335-337`); the picker groups gain
"Instruments"; the page's Pedals & controls panel lists the actual bindings
that name this instrument and links to Built-in pedals, External pedals and
MIDI controls; Cut all sound also clears latches.

Tests: parse and round trip of the keys and target; the two validation rules
on each editor; a latched note from a pedal held across a selection change; a
binding removed while latched releases its voices; an expression pedal on
`cutoff` and the slider share range and default; the panel lists exactly the
bindings naming the instrument; Cut clears latches.

```success-criteria
GOAL: Notes, chords, sustain and family parameters of a chosen instrument are assignable from built-in pedals, external pedals and MIDI controls through the shared catalogue, with Held/Latch semantics, the two validation rules, missing-target repair and one parameter range everywhere, matching pen screen J2uTq.
SUCCESS CRITERIA:
- Catalogue, validation, latch, retirement, shared-range and panel tests pass. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/instruments
- Full suites, Bloc lint and analysis. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- Pedal link contract unchanged. | verify: bash firmware/test/run_tests.sh
- HARDWARE: a built-in pedal latches a chord and an external dual switch holds sustain on the appliance; the LEDs follow the latch. | verify: manual: appliance session, recorded in the PR
NON-GOALS:
- Instrument actions in the Custom face (section 10) beyond what the shared picker already offers.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Dependencies and sequencing

```
Part 1 (spike; proxy gate in CI, Pi artifact for the owner)
 └─ Part 2a sources and buses ── Part 2b MIDI routing
                                    └─ Part 3a Dart seam
                                          └─ Part 3b domain + repository
                                                ├─ Part 4 per-device captures
                                                ├─ Part 5 session recall (after #1196's chain)
                                                ├─ Part 6 routing/FX/Mixer/Tuner (merge gated by the Pi numbers)
                                                │     └─ Part 7a Instruments page
                                                │           ├─ Part 7b controller editors (after Part 4)
                                                │           └─ Part 8 shared assignments
```

Part 2a widens arrays that the pitch/time, Peel, Reverse and Multiply/Divide
parts do not touch, but it edits `mix_tracks_frame`'s capture read and
`process_input_frame`, so it rebases after whichever of those has landed.
Part 5's schema number is the next free one at rebase (after Peel 12 and
Reverse 13 if they land first). Each part runs the normal, ASAN and
telemetry-off native suites where native code changes, `dart analyze
--fatal-infos`, Bloc lint, and independent architecture, test-quality and
adversarial reviews before the human merge gate. Stop for review on: a second
real-time thread, any allocation or lock in render, MIDI through Dart on the
note path, a second routing model for instrument sources, a second capture of
one device, or a Dart-side copy of the patch table.

## 5. Decisions taken under the standing rules

1. C voices inside the callback (D1); measured before integration. Rule 2:
   one RT thread, no added latency.
2. A global voice pool of 32 (64 if the Pi allows), eight instruments,
   same-instrument-first stealing with a 3 ms fade (D2). Rule 2.
3. Instruments are fixed sources 32-39 in the existing input space, mono (D3).
   Rule 4: one routing, monitoring, FX and capture model.
4. MIDI notes are routed on the audio thread from per-port rings; Dart sends
   only computer keys, touch keys and actions; releases follow the voice's
   origin (D4). Rules 2 and 3.
5. The patch table is C; Dart reads it and owns names and art; sessions store
   ids (D5). Rule 4.
6. No sound packs: unavailable means "not in this version", with Retry and
   Choose another (D6, question 1). Rules 2 and 3.
7. Recall ownership as tabled in D7; the working copy is a #1159 family.
   Rule 4.
8. One capture per device, control path unchanged (D8). Rules 1 and 4.
9. New instruments: controllers Off, Hear live On at 75 %, default A–K rows;
   claimed keys are not also Tracks shortcuts (D9). Rule 3.
10. Drums play GM 35-44 and ignore note-off and sustain (D10).
11. Engine reopen and reconfigure drop held notes, latches and sustain and
    replay definitions and routes; nothing held is restored. Rule 5.
12. Removal keeps recorded audio and clears future routes; there is no
    per-take source label to keep because none is shown today. Rule 3.

## 6. Genuine product-direction questions (defaults above stand until the owner says otherwise)

1. **Sound packs.** The pen's unavailable-sound screen (`hRKQL`) offers
   "Install sound pack", and the prototype splits the catalogue into
   `segno-core` and `segno-mallets` packs. With synthesis compiled into the
   engine nothing can be installed. Default taken: Retry and Choose another
   sound, with the reason "not in this version". Should there be installable
   sound content later (for example sampled sounds), or should the pen drop
   the Install action?
2. **Computer keys on the appliance.** The console has no computer keyboard
   unless one is plugged into USB, and several default keys collide with
   Tracks shortcuts on the desktop build. Default taken: claimed keys go to
   instruments when Computer keys is On (D9). Keep Computer keys as a
   desktop and USB-keyboard feature, or hide it on the appliance?

## 7. Hardware-only evidence

- Part 1 and Part 2a Pi 5 thresholds (gate Part 6's merge).
- Note-to-sound latency with a USB MIDI keyboard on the appliance, compared
  with a physical input's round trip (Parts 7a and 7b).
- Two simultaneous USB MIDI devices with the console board (Part 4).
- A 61-key controller with pads, sustain, bend, modulation and pressure
  (Part 7b).
- Built-in and external pedal latches and LEDs (Part 8).
- The 19 patches by ear at 96 kHz (Part 7a); different sound from the
  prototype is permitted (`implementation-map.md`, "Exact rack/effect/parameter
  parity is required; different sound is permitted").
