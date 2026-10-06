# Instruments: native synthesis voices as routable inputs, MIDI note input and the Instruments page

<!-- cspell:ignore polyBLEP xorshift Neoverse SCHED denormal Clavinet tonewheel Vibraphone CHANPRESS PITCHBEND rawmidi uinput ADSR SVF Launchkey GTXF RKQL oegcz kole NOTEON NOTEOFF PGMCHANGE halfband clav PITCHBEND CHANPRESS UNSUBSCRIBED Mori TYRr tombstoned TSAN tsan tanf powf expf -->

Status: plan, revised after the plan review of PR #1204
(`claude-published-review/1197-plan-review/review.md`, request changes) and
the owner's answers of 2026-10-06; §7 maps every finding to where it is met.
`autonomy:merge-gate` on the build parts. Part 1, the measured CPU spike, is
built (PR #1224); the owner's appliance run of it gates Part 2a.
Tracking: #1197 (gap inventory E8-7 to E8-14, and the instrument share of
E7-6 recall ownership and E6-12 shared targets), `autonomy:merge-gate`.
Related: #1040 (one captured MIDI input; Part 4 builds the per-device capture
registry #1040 needs, without deciding its control-path question), #1196
(saved-session migration chain; Part 5 adds a step to it).
Owner answers (2026-10-06), which override earlier defaults and the review's
suggestions: sound packs may come later, so "Install sound pack" stays hidden
until a pack mechanism exists, patch ids stay strings and Retry is offered
only for an audio-start failure; playing instruments from a computer keyboard
is a desktop-build feature, hidden on the appliance.
Source baseline: `origin/claude/segno-integration` at `56033baf0`. Every
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
`02 / Live output routing` (`oegcz`), and their variants `MoriR`, `sTYRr`,
`r47I8` and `mf0fR`, gain instrument sources (Part 6). The
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
  `le_apply_routing` (`:2647`) refuses the whole batch through `le_mix_valid`
  (`engine_commands.c:1400-1446`), which bounds lane inputs and monitors at
  `LE_MAX_CHANNELS` with `uint32_t` masks.
- The mix transaction is the routing and level path:
  `LooperRepository._sendMix` → `setMix` → `le_engine_set_mix`, carrying
  `le_mix_settings` (`segno_engine_api.h:713-735`: `uint32_t monitor_mask`,
  `monitor_gain`, `monitor_pan` and `input_trim` `[LE_MAX_CHANNELS]`,
  `lane_input[LE_MAX_TRACKS * LE_MAX_LANES]`).
- The performance arm captures the device's inputs only (`le_perf_arm`,
  `engine_commands.c:4588-4650`, clamped to `in_channels`), with a `uint32_t`
  mask also in `le_perf_free_unpublished` (`:4579-4584`).
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
  (`midi_backend_linux.c:136-171`); macOS parses raw packets
  (`midi_backend_apple.c:110-150`). Parser tests live in
  `src/test/test_midi_core.c`. `le_midi_close` nulls the callback and then
  joins the backend thread (`midi.c:174-188`, `midi_backend_linux.c:189`):
  that join is today's only producer-quiescence guarantee.
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
  `:85-165`), resolved through `control_availability.dart:19-64`. Monitor
  targets are keyed by the source number,
  `{"ctl":"monitorVolume","index":N}` (`:277-289`), and monitor preferences
  persist per number (`monitor_input_mode.N`,
  `settings_repository.dart:1057`).
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
  (`lib/looper/view/tracks_commands.dart:175-360`), a `Focus.onKeyEvent`
  handler wired at `tracks_view.dart:195` that reads modifier state from
  `HardwareKeyboard`; A, S, W, D, E, F, T, G, Y, H, U, J, K are partly taken
  there (A arms performance recording, `:288`; U undo; S settings; G signal;
  F fullscreen). Appliance builds are detected by `isAppliance()`
  (`lib/update/appliance/appliance_env.dart:10`).

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
  #1159 family table is `2026-10-05-refactor-settings-transaction-owner-plan.md:175-199`,
  and each family is written through `SettingsOwner`
  (`lib/looper/application/settings_owner.dart:112`).
- Dart bounds every source at 32: `EngineMixSettings.isValid`
  (`packages/segno_engine/lib/src/mix_settings.dart:97`, `:124`, `:129`),
  `MixSettingsSnapshot` (`mix_settings_snapshot.dart:113`, `:139`),
  `_mixPayload` (`looper_repository.dart:733`), `_sourceAvailable`
  (`:4640`), the assign and pair guards (`:4705`, `:4726`, `:4768`), the
  trim and pan setters (`:5106`, `:5116`), the monitor-chain guard
  (`:5228`), the sound-start check (`:2983-2988`), monitor restore
  (`:3817`) and `InputSetup` (`input_setup.dart:38`, `:46`); monitor pan
  comes only from `InputSetup.pan` (`monitorMix`, `:8046`). The physical
  loops over `kMaxMonitoredInputs` are `monitor_cubit.dart:177-181`,
  `input_conditioning_cubit.dart:164`, `monitor_migration.dart:56-136` and
  `fx_chain_persistence.dart:168`.
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
- No per-take source label is stored: every `inputName` call site above
  names a route or a live source, and an unknown source falls back to its
  ordinal ("Input 33", `localized.dart:111`).
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
If the Pi numbers fail even at 16 voices, the plan returns to the owner
(escalation to `plan-gate`) with the measured fallbacks: cheaper oscillators,
or an internal 48 kHz synthesis rate with the engine's existing 2:1 half-band
(`restore_halfband.c`).

Real-time rules for the synth TU, enforced by review and tests: no
allocation, lock or syscall inside render; libm math (`tanf`, `powf`,
`exp2f`, `expf`) only once per voice per 32-frame control block or once per
note event, never per sample (as built in Part 1; the existing `fx_filter`
calls `powf` and `tanf` per sample, `engine_fx.c:57-60`); every loop bounded
by the voice pool, the block and a per-block event cap; denormals are already
flushed per callback (`engine_process.c:6340`).

### D2. Polyphony, the joint CPU budget and the overload policy

- One global voice pool, compiled in at `LE_SYNTH_MAX_VOICES = 64` slots;
  the default limit is 32 and the Pi run raises it to 64 when the 64-voice
  threshold passes.
- Up to `LE_MAX_INSTRUMENTS = 8` instruments. The accepted text rules out a
  three-instrument limit (`:390`), not every limit; eight matches the eight
  tracks and keeps every per-instrument array fixed. Add instrument shows the
  reason when eight exist.
- Stealing, in order: the oldest released (or sustained) voice of the same
  instrument, the oldest released voice of any instrument, the oldest held
  voice of the same instrument, the oldest held voice anywhere. A stolen voice
  moves to one of `LE_SYNTH_FADE_SLOTS` fade slots, one per pool voice
  (review M2), and ramps to zero over 3 ms, so a steal never clicks and the
  new note starts in the same block; a full pool stolen in one burst still
  fades every victim. Only more steals than slots within 3 ms overwrite the
  most finished fade, counted as `stolen_hard`. Cut and a patch change fade
  voices in place and need no slot; a note struck while every slot is fading
  in place takes the most finished one, also counted.
- **The joint budget (review M3).** Pitch/time already claims `baseline +
  read head ≤ 50 %` of the period and this plan claims voices and monitors on
  top of the same baseline, so the two are measured together. Part 1's bench
  has a `joint` scenario: the 8 × 8 lane baseline, eight live inputs
  monitored through one reverb each, the pitch/time read head at 8x over the
  64 lanes, and 32 voices of the costliest patch, in one period. On the
  appliance (96 kHz, 64-frame periods, 667 µs, SCHED_FIFO, the app running)
  the thresholds are judged on the tail, p99.9, because at 1500 periods a
  second p99 over a minute tolerates about 900 late periods and one late
  64-frame period is an audible click:
  - the costliest patch and a mixed set at 32 voices: p99.9 ≤ 15 % of the
    period; at 64 voices ≤ 30 %;
  - a 32-note burst, on an idle pool and on a full one (32 steals): the
    block's p99.9 ≤ 20 %;
  - the joint worst case: p99.9 ≤ 75 % and no period over the budget in the
    run.
  The arm64 CI proxy asserts p50 at half of each percentage. Part 2a re-runs
  the joint scenario with the voices inside `le_engine_process`; Part 2c adds
  the event-routing cost (8 ports × 256 events plus 256 control events,
  scanned against 8 instruments × 32 remaps) to it.
- **The Pi gate moves to Part 2a (review M4).** The owner runs this plan's
  bench and the pitch/time bench in one appliance session (the steps are in
  `2026-10-06-instruments-spike-findings.md`, "Pi 5"); the instrument
  verdicts gate Part 2a's merge, so a fallback can still rework Parts 1 and
  2a before anything builds on them.
- **The overload policy.** A runtime voice limit (`le_synth_set_voice_limit`,
  built in Part 1; `LE_CMD_SET_VOICE_LIMIT` in Part 2a) lowers polyphony
  without reallocating: lowering it fades the excess in stealing order and
  later notes steal at the limit. `InstrumentRepository` watches the callback
  telemetry's `late_periods` (`segno_engine_api.h:1076-1093`) while any
  instrument voice sounds: on a new late period it lowers the limit to three
  quarters of its value (never below 8) and shows a toast, "Polyphony reduced
  to N to keep audio running" (the popup severity principle: no immediate
  action is needed). The Instruments page shows the reduced limit with
  Restore; a new session or an engine reopen restores the default. In a
  `LE_CALLBACK_TELEMETRY=0` build there is no late-period signal and the
  limit stays at its default (stated, not silent: the page shows no
  reduction because none can be measured).

### D3. Instruments are fixed extra sources in the engine's input index space

Every input-keyed structure in the engine and in Dart is indexed by an int
(`a_input_channel`, `monitors[]`, `le_mix_settings`, `InputMonitor.input`,
`trimDb`, `SessionLane.inputChannel`, `SessionMonitor.input`). Instruments
join that space at fixed indices instead of getting a parallel set of routes:

- source `s < LE_MAX_CHANNELS` (32) is a device channel, as today;
- source `LE_INSTRUMENT_SOURCE_BASE + k` (32 + k, k < 8) is instrument slot
  `k`; `LE_MAX_SOURCES = 40`.

The index does not depend on the interface's channel count, so a session
records the same number on a 2-in and an 18-in device, and recovery never
looks for a jack (`:402-403`). The loopback-excluded mask, the clip detector,
input conditioning, trim and stereo pairing stay physical-only, behind one
`le_source_is_physical(s)` guard (the shifts `1u << c` are undefined at 32
and above).

**The widening is explicit work, not free (review H1).** The routing and
level path is the mix transaction (`LooperRepository._sendMix` → `setMix` →
`le_engine_set_mix`), and it is bounded at 32 on both sides:
- native: `le_mix_settings.monitor_mask` is `uint32_t`, `monitor_gain`,
  `monitor_pan` and `input_trim` are `[LE_MAX_CHANNELS]`
  (`segno_engine_api.h:713-735`), and `le_mix_valid` refuses
  `lane_input >= LE_MAX_CHANNELS` and walks monitors with `1u << i`
  (`engine_commands.c:1400-1446`). Part 2b widens the monitor mask to
  `uint64_t` and the monitor arrays to `LE_MAX_SOURCES` (trim stays
  `LE_MAX_CHANNELS`, physical) and moves the bound to `LE_MAX_SOURCES`.
- Dart: `EngineMixSettings.isValid` (`packages/segno_engine/lib/src/mix_settings.dart:97`,
  `:124`, `:129`), `MixSettingsSnapshot` (`mix_settings_snapshot.dart:113`,
  `:139`), `_mixPayload` (`looper_repository.dart:733`), `_sourceAvailable`
  (`:4640`), the assign guard (`:4705`), the pair guards (`:4726`, `:4768`),
  the trim and pan setters (`:5106`, `:5116`), the monitor-chain guard
  (`:5228`), the sound-start check (`:2983-2988`), session restore
  (`:3817`), and `InputSetup` (`input_setup.dart:38`, `:46`). Part 3c routes
  every one of them through one `LooperRepository.isSource(int)` predicate
  (a device channel below `inputChannels`, a stray physical route the rig
  already holds, or an instrument slot), with a test per site.
- **Instrument pan** lives where every live input's pan lives, in
  `InputSetup.pan` keyed by source (`monitorMix`, `looper_repository.dart:8046`);
  Part 3c widens that one map to `LE_MAX_SOURCES` while trim and pairs stay
  physical. Its editor is the instrument's own page (delta review D1): the
  Mixer has no live-input strip (`mixer_column.dart` is one strip per track)
  and a jack's pan is edited only in Input setup, which stays physical, so
  Part 7a puts **Level and Pan** together in the Live sound panel. The pen's
  `gGTXF` shows Level only; the Pan control is a departure listed in §6.
  The `InputPanTarget` value binding is instrument-keyed like
  `monitorVolume` (D7).

**The mix path accepts every source and refuses nothing per slot (review
H4).** `le_apply_routing` validates the whole `le_mix_settings` and refuses
the batch on one bad entry (`engine_process.c:2647`, through `le_mix_valid`).
So the mix path accepts any source in `[0, LE_MAX_SOURCES)` and an
instrument slot without a patch renders exact silence. It adds no
`in_channels` check either: today a stray physical route (a session moved to
a smaller interface) is accepted and shown (`recording_inputs_tab.dart:106`),
and that stays (rule 1). Refusals for new routes live in the repository and
the UI (`isSource`), and `LE_ERR_NO_INSTRUMENT` (-14) is confined to the
single-command event API (`le_engine_instrument_note_on` and
`le_engine_set_instrument_param` on an empty slot).

Instrument buses are **mono**. The accepted synthesis renders mono voices into
one gain node per instrument (`instrument-runtime.js:35-48`, `busFor`), so a
take uses one lane of eight, Pan places it, and no stereo-pair rules apply.

### D4. Notes are routed natively; Dart sends only what Dart owns

- **MIDI notes never pass through Dart.** The OS MIDI thread of each capture
  pushes raw messages into a per-port SPSC ring inside the engine, and the
  audio thread routes them at the next block start. A Dart round trip (the
  `NativeCallable.listener` hop, `midi_controller_source.dart:47-50`, then an
  FFI call back) adds a Flutter event-loop wait that depends on UI load; a
  played keyboard cannot take that.
- **Routing tables are published from Dart** (one immutable table per
  instrument set: MIDI enable, port, channel, range, remaps) through a
  two-slot publish with an audio-thread acknowledgement. Publishes coalesce
  latest-wins in the repository: a newer table replaces an unsent one. While
  the engine is not running (no callback after `le_engine_stop` joined it,
  `engine_commands.c:4821-4824`) the control thread flips directly (review
  L8).
- **Computer keys, the touch keyboard and shared actions** (pedal, external,
  MIDI-mapped note/chord/sustain actions) are resolved in Dart, which owns
  those mappings, and sent as note events with an origin token through the
  control-to-audio event ring.
- **Origins.** A voice records its origin. MIDI origins carry the tag bit 31
  clear: `port (3 bits) << 24 | channel (4) << 16 | kind (1) << 8 | number
  (7)`. Dart tokens carry bit 31 set and a 31-bit counter from the
  repository. Sustain contributors use the same values; per instrument the
  engine keeps a fixed table of up to 16 active contributor origins (review
  L3), and a seventeenth is refused and counted, never silently merged.
- **Note-off first, by origin, across every instrument (review M1).** The
  audio thread handles every Note Off (and CC64 below 64) before any table
  lookup: it releases every voice and removes every sustain contribution
  with that origin, whatever the instrument's current enable, port, channel,
  range or remaps say. So turning MIDI off, changing the channel, removing a
  remap or moving the range while a note is held can never strand it
  (the prototype's `noteOff(token)` walks every voice,
  `instrument-runtime.js:200-207`). Only Note On and CC64 on consult the
  tables.
- **Never drop a release (review H3).**
  - Port rings: when a push finds the ring full, the producer drops the
    message and records an overflow mark carrying the ring's tail at that
    moment (delta review D2). The audio thread first drains every event that
    was queued before the mark (they precede the dropped one), and only once
    its head has passed the marked tail releases (normal release, not a cut)
    every voice whose origin names that port, removes that port's sustain
    contributors and counts the overflow. So a Note On queued before a
    dropped Note Off is played and then released, never left held; a later
    overflow while one is pending moves the mark forward. A note-on lost to
    the overflow is simply not played.
  - The control event ring has a reserved release lane: a second SPSC ring of
    1024 entries carrying only note-off, sustain-off and retire events, so
    note-ons can never crowd releases out. `InstrumentRepository` keeps every
    release it could not push in a pending queue and retries it on the next
    snapshot until accepted, never dropping one; a refused note-on is
    dropped and its later note-off is a harmless no-op.
  - **One consistent cut over both rings (delta review D3, PR #1234 M1,
    built).** The control thread stamps one posting sequence across both
    rings and publishes the highest one (release) after each push; the
    callback loads that high-water mark (acquire) before peeking and merges
    by sequence only up to it. Every event at or below the mark is visible in
    both rings, so a note-off can never be applied before its own note-on
    (a two-thread race test: 0 stuck notes in 300k pairs; 56 without the
    mark).
  - **Room for patch changes (delta review D4, built).** Patch changes ride
    the note-on ring, which refuses note-ons while fewer than
    `LE_MAX_INSTRUMENTS` slots would stay free, so an audition Apply or
    Cancel always fits. A patch change can still be refused only when eight
    are already queued, and the repository retries it like a release.
- **Producer quiescence (review H2).** Today `le_midi_close` nulls the
  callback and then joins the backend thread (`midi.c:174-188`,
  `midi_backend_linux.c:189`). The engine sink gets the same guarantee
  without closing the capture: `le_midi` gains an `_Atomic` in-flight counter
  that the backend thread increments around the sink call (wait-free for the
  producer). Detach stores NULL to the sink and spins until the counter reads
  zero; only then may the engine's port slot be reused or the engine be
  destroyed. The handshake is Dekker-style, so its order is fixed (delta
  review D5): the producer increments the counter (`seq_cst`), then loads
  the sink (`seq_cst`), calls it if non-NULL, then decrements (release);
  detach stores NULL (`seq_cst`), then loads the counter (`seq_cst`) until it
  reads zero. With acquire/release alone both sides can miss each other on
  arm64. **The sink itself is shared with the MIDI clock plan (#1236) and is
  built there first** (`claude/midi-clock-1228-p1`, following this D4 and
  the H2 design); Part 2c builds the instrument routing on top of it and
  adds no second sink. `le_midi_close` performs the same quiescent detach, bumps the
  port generation and marks the port lost, so a capture closed or destroyed
  first can never write into an engine port again. `le_engine_destroy`
  detaches every attached port first. A TSAN test in `native-tests-tsan`
  races a producer thread against detach, reattach and destroy.
- **The shared sink, final layout (one design with the MIDI clock plan
  #1236, M8; built in `claude/midi-clock-1228-p1`,
  `src/midi/le_midi_port.h`).**
  - Ring entry, 16 bytes: `le_midi_port_event {u64 t_ns; u32 gen; u8 status,
    data1, data2, reserved}`. `t_ns` is `CLOCK_MONOTONIC` at arrival (the
    base of `le_now_ns`); `gen` is the port generation it was pushed under.
  - Port, `le_midi_port` (engine-owned, `LE_MAX_MIDI_PORTS = 8`):
    `_Atomic u32 a_gen` (bumped by every bind and unbind), `_Atomic i32
    a_lost`, `_Atomic size_t a_gap` (0, or the ring tail at the latest loss
    plus one; moved forward by the producer, cleared by the consumer once
    its head has passed it: the overflow mark above), the owning sink, SPSC
    `head`/`tail`, and 256 entries.
  - Sink, `le_midi_sink {port, gen, in_flight}`, the first member of
    `struct le_midi` (pinned by a static assertion), so the engine binds a
    capture by casting `le_midi*` and links no MIDI backend.
  - Quiescence: every producer write into engine memory sits between
    `le_midi_sink_enter` (counter `seq_cst` increment, then `seq_cst` load
    of the port) and `le_midi_sink_leave` (release decrement); unbind is a
    `seq_cst` exchange of the port to NULL, then `seq_cst` loads of the
    counter until zero. The ring push and the lost mark are bracketed
    today; the MIDI clock relay and DIN Thru rings (#1236 Parts 6 and 7)
    are written inside the same bracket, never outside it.
  - Kinds: the sink carries Note On/Off, CC, channel pressure (0xD0),
    pitch bend (0xE0), Song Position (0xF2), Timing Clock, Start, Continue
    and Stop; the Dart ring keeps Note, CC and Program only, so `_parse` is
    unchanged.
  - One consumer: `le_midi_ports_drain`, right after the command drain, is
    the only code that clears `a_gap` and observes `a_lost` and generation
    edges. It calls `le_midi_port_dispatch` per port in stream order
    (PR #1246 review M1, built): REBOUND when the generation moved since the
    last drain (detach, rebind, or a close followed at once by an attach),
    then the current binding's events with GAP at its exact position (and
    REBOUND again at the first event of a binding made during the drain),
    then LOST, read before the pops but dispatched after them, so the
    events read before the device went away come first. Stale-generation
    events are dropped and counted. This plan releases a port's voices on
    GAP, LOST and REBOUND; the clock follower (#1236) uses the same calls.
    An OS overrun (ALSA `-ENOSPC`) marks a gap through
    `le_midi_sink_mark_gap`, inside the bracket.
  - API, direct calls, no commands: `le_engine_attach_midi_input(e, m,
    port)` and `le_engine_detach_midi_input(e, port)` (the former commands
    100 and 101 are not needed: generations make a rebind safe without the
    audio thread's acknowledgement; 100 and 101 return to the spare range).
- **Device loss (review L7).** Built in the shared sink (#1246): the ALSA
  reader subscribes to the announce port and marks its port lost on the
  source's `PORT_EXIT`, `CLIENT_EXIT` or `PORT_UNSUBSCRIBED`; the drain
  dispatches LOST and this plan releases the port's voices at the next
  block. Held notes from an unplugged keyboard therefore stop within a
  block, not after the 2 s Dart poll; the poll still drives reconnect. The
  CoreMIDI backend does not mark loss: CoreMIDI delivers notify callbacks on
  the creating thread's run loop, which the Dart thread does not run, and
  macOS is a development host only, so there the Dart poll's close (LOST
  plus REBOUND) releases the notes.
- MIDI note input ignores Remote control enable (`:330`); the native path does
  not read it.

### D5. The 19 patches are a C table; Dart owns only presentation

- `synth_patch.c` (built in Part 1) holds the 19 patches in catalogue order
  (`instrument-catalogue.js:17-37`) and the seven families' parameters
  (`:8-16`) with the numeric mapping the voice actually uses.
- The engine exports `le_synth_patch_count`, `le_synth_patch_info` and
  `le_synth_param_info`. Dart reads the catalogue from the engine once and
  formats values from the returned unit and range, so the readout cannot
  drift from the sound. A Dart test compares the patch ids with the l10n keys
  and the art manifest.
- Names, descriptions and family labels are l10n strings keyed by the patch
  id; art is 19 PNGs in a new data-only package `packages/instrument_art`
  laid out like `fx_catalogue` (manifest with sha256, empty-on-missing
  loader), rasterized once from the accepted `art()` drawings
  (`instrument-catalogue.js:59-87`); the app gains no SVG dependency.
- Sessions and the working copy store the patch **id string**, never an
  index (owner, 2026-10-06), and parameters as `0..100` numbers by family
  key, as the catalogue does. A later sound-pack mechanism can add ids
  without a schema change.
- Where the prototype's display formula and its synthesis disagree (attack is
  shown as `0.08 + v/100 × 2.4 s` but synthesized as `0.008 + v/100 × 0.9 s`,
  `instrument-runtime.js:112`), the native mapping is the one both use.
  Decay and release keep the prototype's display mapping, so `gGTXF`'s
  "Decay 1.52 s" (Electric keys at 60) is unchanged; only attack readouts
  differ from the prototype.

### D6. Unavailable sounds (owner, 2026-10-06; review M7)

All 19 patches are compiled into the engine. A sound is unavailable when a
definition names a patch id this build does not define. The cases that can
actually happen (newer sessions are refused by the strict version check,
`session.dart:756`, and by #1196):
- the persisted `instruments` working copy after an appliance A/B (RAUC)
  rollback to a build with fewer patches;
- a same-schema session written by a build with a different patch table.

Then the instrument keeps its definition, routes and mappings (H4), its slot
renders silence, and the page shows "Sound not available in this version"
with **Choose another sound** only. Retry is not offered for it: the
catalogue is compiled in, so a Retry could never succeed. **"Install sound
pack" stays hidden** until a pack mechanism exists (owner). Retry is offered
only for an audio-start failure (accepted 5.8: "A successful retry clears
the failure"). Part 3b tests the rollback case.

### D7. Recall ownership (E7-6, instrument share) and source identity

| Field | Owner | Recall | New Loop (when built) |
|---|---|---|---|
| Instrument list: id, slot, name, patch id, 3 parameters | `InstrumentRepository`, through a `SettingsOwner` family `instruments` from Part 3b on | restored | kept |
| MIDI enable, device id, channel, range, remaps | `InstrumentRepository` | restored | kept |
| Computer keys enable and mappings (desktop builds) | `InstrumentRepository` | restored | kept |
| Instrument source routes: lane inputs, Hear live mode, live level, pan, mute, outputs, input FX | existing `LooperRepository` source families (keyed by source int) | restored, as for physical inputs | kept |
| Shared assignments that name an instrument (pedal, external, MIDI) | their existing owners, keyed by instrument id | restored with them ("musical MIDI assignments", `:461-466`) | kept |
| Removed-instrument labels (tombstones) | `InstrumentRepository` | restored | kept |
| MIDI device inventory, control device, Remote control enable, device names | appliance (`SettingsRepository`) | preserved | preserved |
| Held notes, latches, sustain, expression, audition drafts, the reduced voice limit | runtime only | never restored | released |

- The working copy is written through the #1159 `SettingsOwner`
  (`lib/looper/application/settings_owner.dart:112`) from Part 3b, so Part 5
  only registers the family with `SessionSettingsCoordinator` rather than
  re-homing a direct writer (rule 4).
- **Per-slot outcomes, never a rolled-back recall (review H4).** Recall
  applies each instrument slot on its own: an unknown patch id leaves that
  slot silent with its definition and routes, and the recall continues and
  reports which instrument needs a sound (rule 3). Only a failed write of
  the working copy rolls back, as every #1159 family does.
- **Targets name the instrument, not the slot (review M5).** Value targets
  and actions that address an instrument source store its instrument id
  (`{"ctl":"monitorVolume","instrument":"<id>"}` beside today's
  `{"ctl":"monitorVolume","index":N}`, `control_value_target.dart:277-289`),
  and the resolver maps the id to its current slot. A removed instrument's
  bindings resolve to unavailable with Change control and Remove
  (accepted 4.11, "never silently bind").
- **Removed instruments keep their recorded labels (review M6).** Remove
  clears the instrument's monitor preferences and its routes on tracks with
  no material, keeps the routes on tracks whose lanes hold material from it,
  and leaves a tombstone `{slot, name}`. `inputName` resolves a tombstoned
  source to "Removed instrument (Electric keys)", the slot renders silence,
  and the slot is not reused while any lane still routes to it, so no later
  instrument can be recorded through an old route by accident. When all
  eight slots are in use or tombstoned, Add instrument names the tracks that
  still route a removed instrument and offers to clear those routes.
- **The synth epoch is the one reset trigger (review M9, delta review D6).**
  The engine bumps `synth_epoch` in the snapshot whenever the synth is
  re-initialised: every configure and every reopen (`le_engine_reset_runtime`
  calls `le_instruments_reset`), which clears the patches, returns the voice
  limit to 32 and empties both rings. When `InstrumentRepository` sees the
  epoch change it does both halves at once: it clears every latch, sustain
  contributor token and pending release (the pedal LEDs that show a latch go
  dark), and it replays every slot's patch and parameters, the voice limit
  and the routing table. A Dart engine-lifetime event is not used for this:
  the native reset is the fact, the epoch reports it.

### D8. Device captures: one per device, shared by both consumers

Instruments need their devices captured at the same time as the control
device. Opening a second capture of the same port for instruments would
duplicate what #1040 needs anyway, so Part 4 turns `MidiDeviceRepository` into
a registry with one `MidiClient` per captured device: the selected control
device, plus every device an enabled instrument names. The control path keeps
reading only the selected device's session (`control_midi.dart:372`), so
pedal and Learn behaviour does not change (rule 1); deciding whether other
devices may also feed controls stays with #1040.

### D9. New instruments and computer keys (owner, 2026-10-06; review M8)

- Controller enables start Off (`:366-367`). Hear live starts **On** at 75 %
  (the pen's ready state, `gGTXF`), to outputs 1-2 (the `InputMonitor`
  default mask `0x3`, `input_monitor.dart:55`).
- **Computer keys are a desktop-build feature.** On the appliance
  (`isAppliance()`, `lib/update/appliance/appliance_env.dart:10`) the
  "Computer keys" row, its editor and the key handler are hidden and the
  working copy's computer mappings are kept untouched (a session moved to a
  desktop build still has them). This departs from the pen's `gGTXF` and
  `Uv25f` on the appliance only and is in the write-back list.
- On desktop builds the default mapping is the 13 rows A W S E D F T G Y H U
  J K → C3..C4 (`Uv25f`). The key handler is a `Focus.onKeyEvent` handler
  like `TracksCommands.handleKey` (`tracks_view.dart:195`), not a
  `HardwareKeyboard` one, so it sits above `TracksCommands` in the focus
  chain and the claim is checked there: a key an instrument claims is not
  also a Tracks shortcut, and the first time a claimed key is pressed on
  Tracks a toast says which instrument has it.
- Stuck-key rules (review M8): only key-down is gated (Computer keys On and
  no text field focused); a key-up is always routed for a token that is
  sounding; `KeyRepeatEvent` is ignored; focus loss, window deactivation and
  app pause release every computer-key token. Each has a test.

### D10. Drums and the controllers they ignore

Drum patches play the defined GM notes only (35/36 kick, 38/40 snare, 39
clap, 42/44 closed hat); other notes are shown as received and produce
nothing. Drums ignore sustain, and a note-off leaves the hit's sound alone
but takes it out of the held set, as the reference does
(`instrument-runtime.js:146`, `:200-207`, `:213`): a released pad struck
again overlaps the earlier hit, and only a strike while the pad is still
down replaces it (the repeated-strike rule). (Built in Part 1; the
re-strike rule fixed after the PR #1224 review.)

### D11. Note names

Segno names MIDI note 60 C3 (the pen's convention: `t00H3H` labels 60 as C3,
and `gGTXF`'s touch keyboard spans C3 to C5). The prototype's `noteName`
called 60 C4; the pen wins. Numeric entry stays in MIDI numbers 0-127.

## 2. Native model

### 2.1 Synth (built in Part 1: `synth_voice.h`, pure, no engine types)

`le_synth` holds the pool (`voices[64]` plus `fades[64]`), per instrument
`{patch, params[3]}`, the voice limit and the counters. API:
`le_synth_init`, `le_synth_set_instrument` (a change fades that instrument in
place), `le_synth_set_param`, `le_synth_note_on`, `le_synth_note_off`,
`le_synth_cut` (in place, one instrument or all), `le_synth_set_voice_limit`,
`le_synth_render`, and the counts. Part 2c adds per-instrument sustain
contributor tables and expression (bend, modulation, pressure) to the same
TU, with their own tests.

### 2.2 Engine state (Parts 2a and 2b)

- Patch changes ride the ordered note ring as a `SET_PATCH` event, applied
  at block start in posting order, and the snapshot reports the applied
  patch (review L4: one mechanism). They are not commands: the command ring
  is drained separately and gives no order against the note ring, so a note
  posted right after its instrument was set could meet the previous patch
  (found while building Part 2a). The three parameters are continuous
  controls, `_Atomic uint32_t a_inst_param_bits[3]` stamped with the patch
  they belong to and a revision, read once per block and applied only to
  that patch; a patch change applies the current stamped values at once, so
  custom parameters given with the patch reach the first note.
- `LE_CMD_SET_VOICE_LIMIT` (96) and `LE_CMD_INSTRUMENT_RESET` (97, fade one
  slot's voices when its definition is removed); 98 and 99 spare.
- `inst_bus`: `LE_MAX_INSTRUMENTS × LE_COND_SCRATCH_FRAMES` floats allocated
  with `cond_buf` at configure; a larger block renders silence and counts
  `a_inst_fallback_blocks` (the conditioning precedent, `:6460-6467`).
- `inst_ring` (256: note-on, patch change, and from Part 2c expression) and
  `inst_release_ring` (1024: note-off, and from Part 2c sustain-off): SPSC
  `le_inst_event {u32 seq, origin; u8 kind, slot, note, velocity}`. The
  control thread stamps one posting sequence across both, and the callback
  merges them by it (at most 512 events per block, the rest wait in order),
  so a note-on and its note-off posted before one block apply in that order
  while note-ons can never crowd out a release.
- `midi_ports[LE_MAX_MIDI_PORTS = 8]` (the shared sink, built by #1236
  Part 1 before Part 2c): the 16-byte timestamped entry and the port layout
  of D4's "shared sink, final layout". Producer: that port's OS MIDI thread
  through the quiescent sink; consumer: the audio thread's
  `le_midi_ports_drain`.
- `routes[2]` plus `_Atomic int32_t a_routes_live`, `a_routes_seen`
  (Part 2c): per instrument `{midi_enabled, port, channel (0 = All), low,
  high, remap_count, remaps[32] {port, channel, kind (note | cc), number,
  count, notes[8]}}` (about 3 KB per slot).
- Per block, after the command drain: apply the voice limit and parameter
  revisions, drain the control rings in posting order up to the high-water
  mark (patch changes included, at most 512 events), drain each port ring
  (at most 256 events) and act on a port's lost flag or overflow mark only
  after its queued events (D4), render the buses, publish per-instrument
  peaks and `synth_epoch`.
- `le_source_sample(in_c, ch_in, inst_bus, f, s)` (Part 2b) is the one
  accessor used by capture (`:5986-5992`), the monitors (`:5395-5430`, loop
  bound widened to `LE_MAX_SOURCES`), the sound trigger (`:5316-5337`) and
  the performance tap. The tuner keeps device channels only (E8-14).

### 2.3 MIDI routing on the audio thread (Part 2c)

For each port event (status, d1, d2):
1. Note Off, and CC64 below 64: by origin, across every instrument, before
   any lookup (D4, M1).
2. A remap matches when its port, channel (or All), kind and number match;
   matched remaps play their notes with the event's origin and suppress the
   ordinary handling of that message for that instrument (an explicit CC64
   remap does not also sustain, `:384`).
3. Otherwise, for each instrument with MIDI enabled whose port and channel
   match: Note On within `[low, high]` plays the incoming note and velocity;
   CC64 ≥ 64 adds the contributor; CC1 sets modulation; pitch bend sets bend
   (±2 semitones); channel pressure sets pressure.
4. Several instruments may match one message: that is a layer; channels and
   ranges make splits.

A port detach, loss or overflow releases that port's voices and contributors
as D4 describes; reconnect gets a new generation, so nothing old replays
(`:386-387`).

## 3. Dart model

- `packages/instrument_repository` (new, layered like the other repositories,
  depends on `segno_engine`, `controller_repository`, `settings_repository`):
  - `Instrument {id (SlotIds.mint), slot, name, soundId, params (key → 0..100),
    midi: MidiNoteInput {enabled, deviceId, channel (null = All), low, high,
    remaps}, keys: ComputerKeys {enabled, mappings}}`, plus tombstones
    `{slot, name}` (D7).
  - `InstrumentRepository`: add (first free, non-tombstoned slot; default name
    from the sound), rename, choose sound (Listen auditions a candidate;
    Apply or Add commits, Cancel restores), set parameter (draft or
    committed), set MIDI input, set computer mappings, remove; compiles and
    publishes the routing table (coalesced); resolves computer keys, touch
    keys and action tokens to note events and keeps latch state per token;
    keeps the pending-release queue (D4, H3); attaches captures to ports;
    observes `synth_epoch`, the one trigger that clears latches and replays
    slots, parameters, the voice limit and routes (D7), and the callback
    telemetry (D2 overload); retries refused releases and patch changes;
    projects `InstrumentsState` (definitions, activity, port online state,
    the voice limit); writes the `instruments` family through a
    `SettingsOwner`.
- `LooperRepository` stays the owner of everything keyed by source: it gains
  `isSource(int)` (D3), `liveSources` on `LooperState` (device channels, then
  instrument sources with their names, then tombstones as unavailable), and
  `retireSource(int, {keepMaterialRoutes})`, which refuses while a track fed
  by the source is pending or capturing.
- Removal is an app-layer sequence (`lib/instruments/application/`): guard
  through `LooperRepository`, `retireSource`, then `InstrumentRepository.remove`
  (which leaves the tombstone); a failed step leaves the instrument in place
  and reports why (rule 2).

## 4. Parts

Each part is independently mergeable, keeps the app working and shows no
unfinished destination: nothing reaches the UI before Part 6. Production-line
estimates exclude tests, bench tooling, generated bindings, assets and docs.
Engine numbers come from the central ledger (main session, 2026-10-06):
instruments own commands 96-111, perf-log facts 336-339 and result codes -14
and -15. Part 2a takes commands 96-97 (98-99 spare); Part 2c takes none
(attach and detach are the shared sink's direct calls, D4), so 98-111 stay
reserved. `LE_ERR_NO_INSTRUMENT = -14` is returned only by the
single-command event API on an empty slot (H4); `LE_ERR_UNKNOWN_PATCH = -15`
refuses a patch index the build does not define. Facts 336-339 are reserved
for instrument note provenance in performance stems, which no part here
logs. The Session schema number is assigned at landing (Part 5).

### Part 1. Measured synthesis spike (built: PR #1224, branch `claude/instruments-1197-p1`)

The pure voice pool and patch table, the three catalogue exports, the
`bench_instruments` harness with the `joint` scenario, the CI smoke and arm64
proxy steps, and `docs/plan/2026-10-06-instruments-spike-findings.md`. Revised
for review M2 (one fade slot per pool voice, Cut in place, defined
exhaustion), M3 (joint scenario, p99.9, late periods, the voice limit) and M4
(the Pi run gates Part 2a). About 800 production lines, above the 700
ceiling; the overrun is the review's additions to the pure TU and is
recorded in the findings document.

```success-criteria
GOAL: The 19 Segno patches render as specified in a pure, allocation-free C voice TU, and the cost of 8 to 64 voices, a full-pool burst and the joint worst case with pitch/time is measured at 96 kHz / 64-frame periods on the arm64 proxy and, when the owner runs the artifact, on the appliance Pi 5.
SUCCESS CRITERIA:
- The patch table, frequencies, release-to-exact-silence, velocity, drum sweep, stealing order, full-pool burst fades, Cut in place, voice limit, cross-instrument isolation, determinism, Nyquist and block-size oracles pass in the plain, ASAN and telemetry-off builds, and each behaviour's test fails with that behaviour mutated out. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- The bench builds and its smoke run passes; the pitch/time bench still does; the wiring script and the C++17 shim repro pass. | verify: bash packages/segno_engine/src/test/bench/bench_instruments.sh --smoke && bash packages/segno_engine/src/test/bench/bench_pitch_time.sh --smoke && bash packages/segno_engine/tool/test/run_macos_rnnoise_wiring_tests.sh && manual: the docs/PROGRESS.md shim repro with synth_voice.h included
- The arm64 proxy run passes every p50 threshold (half of the Pi set) and publishes the artifact. | verify: CI job native-bench-arm64 green on the PR head (bench_instruments.sh --budget-us 667 --assert --proxy --seconds 20 on ubuntu-24.04-arm)
- HARDWARE (gates Part 2a's merge): on the appliance Pi 5, app running, SCHED_FIFO, p99.9 at 32 voices ≤ 15 %, at 64 voices ≤ 30 %, both bursts ≤ 20 %, the joint worst case ≤ 75 % with no late period; run in the same session as the pitch/time bench. | verify: manual: the "Pi 5" steps of docs/plan/2026-10-06-instruments-spike-findings.md
NON-GOALS:
- Any engine-state, command, snapshot, Dart or UI change beyond the three pure catalogue exports.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && bash packages/segno_engine/src/test/bench/bench_instruments.sh --smoke
```

### Part 2a. Native instrument slots, buses and the synth in the callback (about 550 production lines)

`engine_instruments.{h,c}` (inside the `engine*.c` glob): the synth and
`inst_bus` allocated at create, the synth inside `le_engine_process` after
the command drain, the ordered `inst_ring` with patch changes and the
reserved `inst_release_ring` (§2.2, D4, H3), the stamped parameter atomics,
`LE_CMD_SET_VOICE_LIMIT` (96), `LE_CMD_INSTRUMENT_RESET` (97),
`handle_cut_sound` (`:2201`) calling `le_synth_cut(-1)`, the synth
re-initialised on configure and reopen with `synth_epoch` bumped (M9), and
the snapshot's `instrument_patch`, `instrument_voices`, `instrument_peaks`,
`voice_limit`, `voices_stolen`, `voices_stolen_hard`, `synth_epoch`,
`instrument_events_refused`, `instrument_fallback_blocks`. API:
`le_engine_set_instrument(e, slot, patch or -1, params or NULL)`
(`LE_ERR_UNKNOWN_PATCH`; `LE_ERR_CAPACITY` with nothing changed when the
note ring is full), `le_engine_set_instrument_param`,
`le_engine_set_voice_limit`, `le_engine_reset_instrument`,
`le_engine_instrument_note_on` (`LE_ERR_CAPACITY` when full, keeping eight
slots for patch changes, counted;
`LE_ERR_NO_INSTRUMENT` on an empty slot) and `le_engine_instrument_note_off`
(the release lane; `LE_ERR_CAPACITY` only when 1023 releases are queued,
which the repository retries). Part 2c adds the expression and sustain
events to the same rings. No source routing
yet: the buses are observable to native tests through the engine internals
(`test_engine_core.c` already reads `engine_private.h`).

Tests (`src/test/test_engine_instruments.h`, literal PCM through
`le_engine_process`):
- slot 0 `sub`, a note through the event API at frame 0 of a block: the bus
  equals an offline `le_synth_render` of the same events sample for sample,
  at 48 kHz and blocks 1, 64, 127, 512;
- a release pushed with the event ring full is applied at the next block
  (release lane), and 300 note-ons into a 256-entry ring return
  `LE_ERR_CAPACITY` for the excess while every queued release still lands;
- Cut all sound: every bus exactly zero from 144 frames after the cut block,
  (sustain contributors arrive in Part 2c, which adds them to Cut);
- voice limit 8 with 16 held: 8 sounding after one block, the oldest faded;
- a patch change fades only that slot; slot 1's bus equals its solo render;
- `LE_ERR_UNKNOWN_PATCH` for patch 19, `LE_ERR_NO_INSTRUMENT` for an event
  to an empty slot;
- configure at a new rate: voices gone, `synth_epoch` incremented;
- a block above `LE_COND_SCRATCH_FRAMES` renders silence and counts one
  fallback;
- the existing suite stays byte-identical.
The bench's `joint` scenario switches to the integrated path.

```success-criteria
GOAL: Up to eight native instruments render inside the callback into mono buses, driven by checked commands and a release lane that never loses a release, with Cut, a voice limit and a synth epoch, before any routing exists.
SUCCESS CRITERIA:
- Literal PCM proves the bus equals the offline render at four block sizes, releases survive a full event ring, Cut silences in 144 frames, the voice limit, patch-change isolation, the refusals, the configure epoch and the fallback counter; every pre-existing test is byte-identical. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and telemetry-off builds pass; the C++17 shim repro compiles with every changed core header. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && manual: the docs/PROGRESS.md shim repro
- Bindings regenerate and format cleanly, the symbol check passes, the Dart suites pass, and the proxy bench's joint scenario passes through the integrated path. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && /Users/Tomas/development/flutter/bin/flutter test && CI job native-bench-arm64 green
- HARDWARE (merge gate, review M4): the Part 1 Pi verdicts all pass, recorded in the findings document. | verify: manual: the findings document's Pi 5 table shows every verdict passing
NON-GOALS:
- Source routing, the mix transaction, MIDI ports, Dart seam, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2b. Native source space: routing, monitors, the mix transaction, perf and snapshot (about 600 production lines)

D3's native half (review H1, H4, L2). `LE_MAX_SOURCES = 40` and
`le_source_is_physical`; `le_source_sample` at capture, monitors, the sound
trigger and the performance tap; `LE_MAX_MONITORED_INPUTS = LE_MAX_SOURCES`
(`segno_engine_api.h:670`) with the conditioning (`cond[]`) and clip arrays
kept at `LE_MAX_CHANNELS`; `LE_CMD_SET_LANE_INPUT` (`:3628-3643`) and
`LE_CMD_SET_MONITOR_INPUT` (`:3699-3709`) accepting `[32, 40)` whatever the
slot holds (an empty slot is silence); the mix transaction: `monitor_mask` to
`uint64_t`, `monitor_gain` and `monitor_pan` to `[LE_MAX_SOURCES]`,
`input_trim` and `trim_mask` unchanged (physical), `le_mix_valid`'s lane and
monitor bounds to `LE_MAX_SOURCES` (`engine_commands.c:1400-1446`), no
per-slot or `in_channels` refusal (H4); the performance tap: `perf.input_mask`
to `uint64_t` (`engine_private.h:1338`), `le_perf_arm` capturing every
monitored instrument source with a patch as well as the device's inputs
(`engine_commands.c:4588-4650`), `le_perf_free_unpublished`'s
`monitors_done` mask to `uint64_t` (`:4579-4584`), and the drain's
`input-%d.pcm` naming (`perf_drain.c:1545`) unchanged; the snapshot's
`input_peaks`, `monitor_peaks` and `input_trim` to `LE_MAX_SOURCES`
(`segno_engine_api.h:1329-1332`; instrument entries are the bus peak and
trim 1), `output_peaks` unchanged. The Dart consumers of
`kMaxMonitoredInputs` that mean physical inputs move to `kMaxChannels` so
behaviour is unchanged: `monitor_cubit.dart:177-181`,
`input_conditioning_cubit.dart:164`, `monitor_migration.dart:56-136`,
`fx_chain_persistence.dart:168` (review L2).

Tests (`test_engine_instruments.h`), each failing without the change:
- lane input 32 on track 1 records the bus sample for sample (sound-armed
  with Hear live Off: monitor 32 off, output exactly zero, capture still
  equal);
- monitor 32 at volume 0.5, pan 0: each output is bus × 0.5 × the pan-law
  gain;
- an armed track (trigger 1) on source 32 starts at the first frame whose
  bus sample exceeds `LE_AUTO_RECORD_THRESHOLD`, with the note-on mid-block;
- a mix transaction with lane input 33 (empty slot) and a monitor on 39 is
  accepted whole and renders silence for 33 (H4); one with 40 is refused;
  a stray physical route beyond `in_channels` is still accepted (rule 1);
- `le_perf_arm` with source 32 monitored writes `input-32.pcm` with the
  monitored signal; a source-32 entry in the free path under ASAN;
- the tuner never reads source 32; the clip and conditioning masks never
  carry bits at or above 32;
- the snapshot's `input_peaks[32]` is the bus peak and `input_trim[32]` 1;
- the existing suite stays byte-identical.

```success-criteria
GOAL: Instrument slots are ordinary sources 32 to 39 for capture, sound-armed recording, Hear live, the mix transaction, the performance stems and the snapshot, accepted whole in batches (an empty slot is silence), with physical-only stages unchanged.
SUCCESS CRITERIA:
- Literal PCM proves capture, monitor gains, the frame-exact sound trigger, whole-batch acceptance with silence for empty slots, the stray-route rule, the instrument stem, tuner and mask exclusion and the snapshot entries; every pre-existing test is byte-identical. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and telemetry-off builds pass; shim repro. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && manual: the docs/PROGRESS.md shim repro
- Bindings, symbols, and the Dart suites unchanged in behaviour (the physical loops now use kMaxChannels). | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages
NON-GOALS:
- MIDI ports, the Dart source predicate, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2c. Native MIDI note routing, sustain and expression (built: branch `claude/instruments-1197-p2c`; about 600 production lines)

§2.3 and D4's MIDI rules, **built on the shared native MIDI input sink from
the MIDI clock plan (#1236, `claude/midi-clock-1228-p1`)**: that branch adds
the quiescent sink on `le_midi` (in-flight counter, detach-and-spin in the
`seq_cst` order of D4, `le_midi_close` performing it with a generation bump
and the lost mark, its TSAN test); this part adds the instrument port rings
behind it and no second sink.
The shared sink also already carries pitch bend and channel pressure (parser
kinds `LE_MIDI_PITCH_BEND`, `LE_MIDI_CHANNEL_PRESSURE`, kept out of the Dart
ring), the ALSA conversions of PITCHBEND and CHANPRESS, and the ALSA source
PORT_EXIT / CLIENT_EXIT / PORT_UNSUBSCRIBED lost mark. The CoreMIDI
removed-source notification is not built there: CoreMIDI delivers notify
callbacks on the creating thread's run loop, which the Dart thread does not
run, and macOS is a development host only; the 2 s Dart poll covers it.
This part adds: routing inside `le_midi_port_dispatch`, releases on GAP,
LOST and REBOUND (H3), routes with the coalesced
two-slot publish (L8), note-off and CC64-off
first by origin (M1), origin encoding with the tag bit and the contributor
table (L3), expression and sustain in the synth TU. API (attach and detach
are the shared sink's direct calls, no commands):
`le_engine_set_instrument_routes(e, const le_inst_routes*)` (returns
`LE_ERR_NOT_READY` until the audio thread acknowledged the previous flip;
flips directly while the engine is stopped). The bench's joint scenario gains
the routing cost: 8 ports × 256 events and 256 control events per block
against 8 instruments × 32 remaps.

Tests (`test_engine_instruments.h`, `test_midi_core.c`, and the shared
sink's `src/test/test_midi_sink_races.c`, already in the TSAN job and extended
here with routing running on the audio thread), each failing
without the change:
- split, layer, range, remap (a chord with one origin, released together,
  the ordinary note not also played), an explicit CC64 remap not sustaining;
- note-off by origin after each of: MIDI disabled, channel changed, remap
  removed, range moved, all while the note is held (M1);
- sustain from two contributors: a released voice rings until both are off;
  repeated strikes under sustain stay two voices; a seventeenth contributor
  is refused and counted;
- pitch bend 16383 on `sub` 69: 880 × 2^(2/12) ± 2 crossings per second;
  pressure 127 raises the peak by 25 % ± 1 %; drums ignore CC64 and note-off;
- overflow: a Note On X queued, then 254 more messages, then X's Note Off
  dropped because the ring is full: the next block plays the queued events
  first, then releases every voice from that port (X included, reaching
  exact zero by its release time) and counts one overflow; voices from other
  ports and tokens are untouched (H3, delta review D2);
- detach and loss: the port's voices released, a token's voice ringing, an
  old-generation event dropped, a fresh note after re-attach played;
- the races test, under `-fsanitize=thread`: a producer thread pushing
  through the sink while the main thread detaches, re-attaches to another
  port slot and destroys the engine, 10⁵ iterations, no report and no event
  in the wrong ring (H2);
- the routes publish: a second publish before the acknowledgement returns
  `LE_ERR_NOT_READY`; a publish while stopped flips at once; under ASAN a
  publish racing the callback for 10⁵ blocks never reads a half-written
  table.

As built (differences from the text above):
- **Dispatch.** Routing runs inside the sink's `le_midi_port_dispatch`:
  EVENT routes the message; GAP, LOST and REBOUND all call one "port gone"
  step. `le_instruments_midi_begin` at the top of the drain switches in the
  published route table and acknowledges it. The part keeps no generation
  state of its own; REBOUND carries it.
- **Port gone, precisely.** The port's sustain contributors are removed;
  its held notes are let go as by a Note Off (so a note still sustained by
  another contributor, for example a pedal posted from the control thread,
  rings on); sustained voices that nothing sustains any more release; the
  bend, modulation and pressure that port set are reset to zero. A first
  draft released every voice from the port, sustained or not; the
  "gone ends sustain and expression" test pins the corrected rule.
- **Control-thread sustain.** `le_engine_instrument_sustain(e, slot, origin,
  on)` adds or removes a contributor through the ordered rings (on through
  the note ring, off through the release lane), for tokens, touch keys and
  the pedals Part 3b resolves. Its origin carries the control tag, so a
  port going away never removes it.
- **Remap index.** Each route table carries, per port, kind and number, the
  channels any remap covers (a 16-bit mask), built on the control thread
  with the table. A message no remap can match skips all 256 remap
  comparisons; the held-switch check (a remapped CC already held does not
  strike again) runs only for remapped controllers. Without the index the
  routing load below added about 170 µs per 128-frame period on the
  development Mac (joint p50 from 16 % to 41 % of the period); with it,
  about 40-50 µs (to about 22 %).
- **Bench.** The joint scenario carries the routing load before every
  period: 255 events on each of the 8 ports (a full ring; 256 cannot be
  queued) and 256 control note-offs, against 8 instruments with 32 remaps
  each. The port events are Note Ons above every range, Note Offs and CC 7,
  so each scans the remaps and the voice pool without changing the voice
  load, and the run fails if the 32 voices or the overflow count move.
- **Tests.** The gap position is pinned with `le_midi_sink_mark_gap`
  between two notes (the one before the gap released, the one after it
  sounding); the overflow case above checks that X is released and nothing
  is left sounding after the release time, rather than the exact-zero
  sample. The routing race is the second scenario of
  `src/test/test_instrument_races.c` (built before the races-only exit, so
  the TSAN job runs it): a MIDI thread pushing note pairs, the audio thread
  in `le_engine_process`, the control thread republishing tables 40 000
  times (2 000 under TSAN) with a rebind every 500 attempts; no MIDI voice
  may stay held. The sink's own race test is unchanged. A publish racing
  the callback is checked by TSAN on the table handover (release on the
  flip, acquire at the switch, and the reverse on the acknowledgement)
  rather than by an ASAN content check.

```success-criteria
GOAL: MIDI from any attached capture reaches instrument voices on the audio thread without Dart, with splits, layers, ranges, chord remaps, sustain from independent contributors, bend, modulation and pressure; releases are never lost to overflow, edits or detach, and a capture can never write into a detached or destroyed engine.
SUCCESS CRITERIA:
- The routing, release-by-origin, contributor, expression, overflow, detach and publish oracles pass in the plain, ASAN and telemetry-off builds. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- The sink race test passes under ThreadSanitizer. | verify: NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh && CI job native-tests-tsan green
- The Dart MIDI path is unchanged: midi_client and controller tests pass without edits. | verify: (cd packages/midi_client && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test
- Bindings and symbols; the proxy bench's joint scenario with routing passes. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart) && packages/segno_engine/tool/check_ffi_symbols.sh "$(bash packages/segno_engine/tool/build_test_lib.sh)" && CI job native-bench-arm64 green
NON-GOALS:
- Dart seam, device registry, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g' bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3a. Dart engine seam (about 300 production lines)

A new role `InstrumentHost` in `packages/segno_engine/lib/src/audio_engine.dart`
beside `MonitorControl` (`:1125`) and composed into `AudioEngine` (`:1513`):
`synthCatalogue()`, `setInstrument`, `setInstrumentParam`, `setVoiceLimit`,
`instrumentEvent`, `instrumentRelease`, `setInstrumentRoutes`, and
`attachMidiInput(MidiCaptureHandle, port)` / `detachMidiInput(port)`, where
`MidiCaptureHandle` wraps `Pointer<le_midi>` and is exposed by `MidiClient`
(`midi_client` already depends on `segno_engine`). `EngineSnapshot` gains the
instrument, pool, epoch and widened per-source fields. `NativeAudioEngine`,
`MockAudioEngine` (a deterministic fake voice model: it records events and
reports voices, no audio) and the four fakes
(`test/helpers/fake_audio_engine.dart` and the package fakes).

```success-criteria
GOAL: Repositories can read the synthesis catalogue, configure instrument slots and the voice limit, send note events and releases, publish routes, attach captures and observe instrument activity and the synth epoch through one role interface, with the native and mock engines and every fake implementing it.
SUCCESS CRITERIA:
- A native-library test reads 19 patches and their parameter info, sets a slot, sends a note, sees one active voice, releases it, and attaches and detaches a capture handle. | verify: (cd packages/segno_engine && SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test)
- Mock and fakes compile and pass; the app suite is unchanged. | verify: /Users/Tomas/development/flutter/bin/flutter test
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Instrument domain, persistence, UI.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3b. Instrument domain and repository (about 650 production lines)

`packages/instrument_repository` (§3): models with JSON, the desktop default
A–K mapping, slot allocation with tombstones, the routing-table compiler
(definitions plus port assignments → `le_inst_routes`, coalesced), the
computer-key, touch-key and action-token note dispatch with latch state, the
pending-release queue (H3), audition drafts, the activity projection, the
`instruments` family written through a `SettingsOwner` from the start, the
synth-epoch observer as the one reset trigger (M9, D7: clear latches and
replay slots, parameters, the voice limit and routes), retries of refused
releases and patch changes, the overload policy (D2), unknown sound ids kept
as unavailable (D6), and the removal
sequence. The working copy is written only after the engine acknowledged the
change; a failed write restores the previous definition and reports it.

Tests against `MockAudioEngine` and a fake `SettingsRepository`: add fills
the first free non-tombstoned slot with both controller enables off and Hear
live On; the ninth add is refused with the reason; Cancel after Listen sends
the saved patch; a parameter draft is not written to the store; a release
refused by a full lane is retried until accepted and never dropped, and so
is a refused patch change; an epoch change clears latches and contributor
tokens and replays every slot, parameter, the voice limit and the routes, and
an engine-lifetime event alone does not; a late period lowers the voice
limit to three quarters (not below 8) and raises the toast; the persisted
working copy naming a patch id the build lacks (the A/B rollback case, M7)
loads as unavailable, sends no patch and keeps routes and mappings; the
compiler builds splits, layers and
remaps and reports truncation to the native caps as a problem rather than
silently. One actual-native case
(`packages/instrument_repository/test/instrument_native_test.dart`) plays a
note through the repository and sees it on the snapshot.

```success-criteria
GOAL: Instruments exist as persistent definitions with stable identities and slots, drive the engine through one repository that never loses a release, survive restart, engine reopen and an A/B rollback, and react to overload and resets, still with no UI.
SUCCESS CRITERIA:
- Repository, compiler, overload, epoch, rollback and native cases pass. | verify: (cd packages/instrument_repository && SEGNO_ENGINE_LIB="$(bash ../segno_engine/tool/build_test_lib.sh)" /Users/Tomas/development/flutter/bin/flutter test)
- App suite and static gates. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- The source predicate (Part 3c), device captures, session schema, UI, shared actions.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3c. Dart source space, instrument-keyed targets and removal labels (about 550 production lines)

D3's Dart half (H1) and D7's identity rules (M5, M6):
`LooperRepository.isSource(int)` replacing the 32-bounded checks at every
site listed in D3 (`mix_settings.dart`, `mix_settings_snapshot.dart`,
`_mixPayload`, `_sourceAvailable`, the assign, pair, trim, pan and
monitor-chain guards, the sound-start check, session restore of monitors),
with trim and pairs still physical; `InputSetup.pan` widened to
`LE_MAX_SOURCES`; `liveSources`; `retireSource` keeping routes on tracks with
material; tombstone labels through `inputName`; instrument-keyed value
targets and actions in `control_value_target.dart` and their resolver, with
a removed instrument's bindings unavailable (Change control, Remove).

Tests: one per guard site (source 32 with an instrument accepted, 32 empty
refused for a new route, 31 still bounded by the device, a stray physical
route still accepted); the instrument's 75 % level reaches the mix payload; a
sound-armed take on source 32 is admitted; pan on 32 round-trips; removing an
instrument whose take is on track 2 keeps that route and names it "Removed
instrument (Electric keys)", clears the route on empty track 3, and a new
instrument does not get slot 0 while track 2 routes it; a binding on the
removed instrument's level is unavailable, and one on a re-added instrument
of the same sound is not silently rebound.

```success-criteria
GOAL: Every Dart bound on sources admits instrument slots through one predicate, instrument pan has an owner, targets follow the instrument rather than the slot, and removing an instrument keeps the labels of what was recorded from it without ever retargeting a route or binding.
SUCCESS CRITERIA:
- The per-site, payload, sound-armed, pan, removal-label, tombstone and binding cases pass. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/control
- Full suites and static gates. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Screens (Part 6), session schema (Part 5).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 4. One capture per device (about 350 production lines)

D8. `MidiDeviceRepository` keeps a map of device id → `MidiControllerSource`
(one `MidiClient` each) for the selected control device plus every device an
enabled instrument names (`InstrumentRepository` supplies that set). The
hotplug poll (`midi_device_repository.dart:296-346`) opens and closes each;
connection state becomes per device; `messages` carries the device id it
already has in `MidiInputSession`. `InstrumentRepository` attaches each open
capture to a port slot and detaches on loss, close and engine lifetime
change. `ControlCubit` still filters to the selected device's session
(`control_midi.dart:372`). Refs #1040.

Tests: two fake devices, A selected for control, B named by an instrument:
both captured; B's messages never reach the decoders or Learn; A's do; B
unplugged closes only B, detaches its port and marks the instrument
disconnected; B back reopens and re-attaches with a new generation; selecting
B for control does not open a second capture of B. The existing
`midi_device_repository` suite passes unchanged in its single-device cases.
(The physical two-device check moves to Part 7b, review M10: no UI can bind
an instrument to a device before then.)

```success-criteria
GOAL: Every device an instrument uses is captured at the same time as the control device, with one capture per device, independent loss and reconnect, and no change to what reaches pedal control and Learn.
SUCCESS CRITERIA:
- The two-device registry, isolation, loss and reconnect cases pass, and the existing single-device cases pass unchanged. | verify: (cd packages/midi_device_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/instrument_repository && /Users/Tomas/development/flutter/bin/flutter test)
- ControlCubit's MIDI suite is unchanged and green. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- Letting non-selected devices feed controls (#1040's question), UI, hardware checks (Part 7b).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages
```

### Part 5. Session recall (about 500 production lines; before Parts 6 and 7a, review H5)

D7. `Session.instruments` (definitions and tombstones as in §3); lane routes
and monitors accept sources up to 39 (`session.dart:825` and the monitor
parse; `looper_repository.dart:3817` through `isSource`); the schema version
is assigned at landing, and its step is added to the #1196 chain (an absent
list becomes empty and is recorded as defaulted). `session_mapping.dart` maps
the list both ways; `SessionCubit.loadNamed` applies instruments before
`applySession` routes lanes (`session_cubit.dart:231-385`), each slot on its
own (H4); `SessionSettingsCoordinator.capture` registers the `instruments`
family. A recalled device id that is not present shows disconnected; a
recalled unknown sound is unavailable (D6). This part waits for #1196's
chain, and Parts 6 and 7a wait for this part, so no build can save a route to
an instrument that the schema cannot read back.

Tests: round trip of every instrument and tombstone field; a session without
instruments from the previous version migrates through the chain with the
field listed as defaulted; a lane and a monitor on source 33 round-trip;
recall of a session with two instruments into a rig with three leaves two;
recall of a session naming an unknown patch completes, leaves that slot
silent with its routes and reports it (H4); a failed working-copy write
during recall restores the previous instruments; no note event follows a
recall (the mock engine sees none); the existing fixture round trips stay
byte-identical apart from the version and the new field.

```success-criteria
GOAL: Saved sessions restore instrument definitions, tombstones, mappings and routes slot by slot, accept sources 32-39 everywhere a route is stored, migrate older sessions through the chain, and never roll back a whole recall for one unavailable sound.
SUCCESS CRITERIA:
- Session round trips, the migration step, per-slot recall, rollback and no-replay cases pass. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session
- Full suites and static gates. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
NON-GOALS:
- New Loop (not built; D7 states its rule), UI.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 6. Instrument sources in routing, FX and Mixer; Tuner exclusion (about 400 production lines)

E8-14 and the screen half of E8-7, matching `s0zlm` and `oegcz`, and the
variants `MoriR` (18 recording inputs), `sTYRr` (18 live inputs), `r47I8`
(Recording locked) and `mf0fR` (Auto monitoring), whose goldens gain
instrument cards: every input list reads `LooperState.liveSources`; instrument
cards show "Instrument" where a port number shows
(`audio-routing-study.js:16-17`); tombstones show as unavailable and
removable; `inputName` resolves sources 32-39; Input setup lists device
channels only; the Tuner keeps device channels only; recording a source is
locked while armed or capturing exactly as for jacks. With no instrument,
every screen is as today.

Tests: widget and cubit tests for each site with one instrument present and
absent and with a tombstone; goldens for the six routing screens, including
the 18-input layouts with eight instruments at console size; the Tuner list
unchanged with an instrument present.

```success-criteria
GOAL: Instruments appear beside physical inputs wherever a live source is chosen, routed, monitored, mixed or given FX, never in Input setup or the Tuner, and every screen is unchanged when no instrument exists.
SUCCESS CRITERIA:
- The site tests, goldens (including 18 inputs plus 8 instruments) and the unchanged-without-instruments cases pass. | verify: /Users/Tomas/development/flutter/bin/flutter test
- Static gates. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages
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
reason on refusal, the tombstone notice when recorded material keeps its
label, the empty Add instrument state after the last), the touch keyboard or
pads (octave paging changes the view only; C3 = 60, D11), the "Played by"
summary rows (MIDI, and Computer keys on desktop builds only, D9), the Live
sound panel (Hear live, Level and Pan, Outputs, Effects, Recording inputs;
Pan is a departure from `gGTXF`, D3), the
reduced-polyphony line with Restore (D2), and the feedback line: active
notes, Sustain, and the silent reasons in the reference's order
(`virtual-instruments.js`, `feedback`): audio start failure (with **Retry**,
the only Retry on the page, D6), sound not available in this version, Live
monitoring off, Muted in Mixer, No audible output, Live monitoring waiting
(Auto), No controller assigned, device disconnected. The sound dialog
(`hSy26`) lists the seven families and their patches with art; selecting a
sound only selects it, the **Listen** button auditions it (the pen's control,
review L6), and Apply or Add instrument commits, Cancel restores. The
unavailable state (`hRKQL`) offers Choose another sound only; "Install sound
pack" stays hidden (owner). Art comes from `packages/instrument_art`. l10n in
every ARB.

Tests: cubit sequences (add, Listen, Cancel restores, Apply commits, a draft
parameter not saved, remove refused while capturing, removal with a
tombstone, last removal, Retry after an audio-start failure clears it, no
Retry on an unavailable sound, Restore of a reduced limit); widget and golden
tests for the four screens at console size; the Computer keys row absent when
`isAppliance()` is true; the silent-reason ordering for each cause.

```success-criteria
GOAL: A player can add, audition with Listen, choose, adjust, rename and remove instruments, play them by touch, see why one is silent, and reach its live routing and effects, matching pen screens gGTXF, hSy26, hRKQL and B5PEqI with the recorded departures.
SUCCESS CRITERIA:
- Cubit, widget and golden tests for the four screens, the appliance variant and the reason order pass. | verify: /Users/Tomas/development/flutter/bin/flutter test test/instruments
- Full suites, static gates and the ARB coverage. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- HARDWARE: on the appliance, an instrument recorded through normal Tracks Record/Play with Hear live Off captures audio, and the 19 patches are checked by ear at 96 kHz / 64 frames from the touch keyboard. | verify: manual: appliance session per docs/PROGRESS.md, recorded in the PR
NON-GOALS:
- MIDI and computer-key editors, Learn, shared assignments, MIDI hardware checks (Part 7b).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 7b. Controller editors: MIDI input, computer keys, Learn (about 650 production lines)

Matching `kole9`, `Uv25f` and `t00H3H`: the MIDI input sheet (device from the
shared inventory with online state, channel All or 1-16, lowest and highest
note, encoder entry on each field, "Incoming pitch and velocity pass through
the full selected range", Note & pad remapping list with Learn source and
target notes), the Computer key mappings sheet and the mapping editor
(desktop builds only, D9), with Learn of the key and notes by playing MIDI,
numeric entry or the touch keyboard, View C3–C5 paging. Outer Done/Cancel is
atomic and Cancel discards nested edits (`:373-376`). Learn reads the
device's messages from the registry (Part 4). The computer-key handler and
its stuck-key rules (D9, M8).

Tests: sheet cubits (Cancel discards a remap added inside, Done publishes one
compiled table, out-of-range fields clamp with the encoder); Learn of a pad
note and of a three-note chord; the default 13 rows; the key-claim rule
against `TracksCommands` and its toast; key-down gating, key-up always
routed, repeat ignored, release on focus loss and app pause; the editors
absent on the appliance; goldens for the three screens.

```success-criteria
GOAL: Each instrument's MIDI device, channel, range and pad remaps, and on desktop builds its computer key mappings, can be edited, learned and cancelled as one draft, matching pen screens kole9, Uv25f and t00H3H, with no stuck computer-key notes.
SUCCESS CRITERIA:
- Sheet, Learn, default-mapping, key-claim, stuck-key and golden tests pass. | verify: /Users/Tomas/development/flutter/bin/flutter test test/instruments
- Full suites and static gates. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages
- HARDWARE (review M10, moved here from Parts 4 and 7a): on the appliance, a 61-key controller with pads plays all its keys on one instrument while its pads play a remapped drum instrument on another channel, a 32-note chord plays with no late period in the callback telemetry, sustain is Held, bend, modulation and pressure are audible; with the console board connected too, its footswitches still drive the pedal path; unplugging the keyboard stops its notes within a block and silences only its instruments; plugging it back needs a fresh key press. | verify: manual: appliance session with a USB keyboard controller with pads plus the console board, callback telemetry read through le_engine_get_callback_telemetry, recorded in the PR
NON-GOALS:
- Shared pedal, external and MIDI assignments.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages
```

### Part 8. Shared note, chord, sustain and parameter assignments (about 600 production lines)

E8-13 and the instrument share of E6-12, matching `J2uTq`:
`InstrumentNoteAction` (`instrument:<id>:notes:<n,n,…>:<held|latch>`) and
`InstrumentSustainAction` (`instrument:<id>:sustain:<held|latch>`) in the
action catalogue (`control_action.dart:452-484`, parsed without throwing,
unknown instrument → `UnavailableAction` with Change control and Remove);
`InstrumentParamTarget` (`{"ctl":"instrument","id":…,"param":…}`) mapping
0..1 to the patch range with one default for every surface; dispatch from
`ControlCubit._runAction` to `InstrumentRepository` with the binding's id as
the origin token, so retiring or changing a binding retires its latch and its
voices; validation that a held instrument Press requires Hold=None and a held
MIDI action requires a momentary Note or CC on Press, with the conflict
explained and Save disabled (`:335-337`); the picker groups gain
"Instruments"; the page's Pedals & controls panel lists the actual bindings
that name this instrument and links to Built-in pedals, External pedals and
MIDI controls; Cut all sound and a synth epoch change clear latches and
their LEDs.

Tests: parse and round trip of the keys and target; the two validation rules
on each editor; a latched note from a pedal held across a selection change; a
binding removed while latched releases its voices; an epoch change turns a
latch LED off; an expression pedal on `cutoff` and the slider share range and
default; the panel lists exactly the bindings naming the instrument; Cut
clears latches.

```success-criteria
GOAL: Notes, chords, sustain and family parameters of a chosen instrument are assignable from built-in pedals, external pedals and MIDI controls through the shared catalogue, with Held/Latch semantics, the two validation rules, missing-target repair and one parameter range everywhere, matching pen screen J2uTq.
SUCCESS CRITERIA:
- Catalogue, validation, latch, retirement, epoch, shared-range and panel tests pass. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/instruments
- Full suites, Bloc lint and analysis. | verify: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- Pedal link contract unchanged. | verify: bash firmware/test/run_tests.sh
- HARDWARE: a built-in pedal latches a chord and an external dual switch holds sustain on the appliance; the LEDs follow the latch. | verify: manual: appliance session, recorded in the PR
NON-GOALS:
- Instrument actions in the Custom face (section 10) beyond what the shared picker already offers.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Dependencies and sequencing

```
Part 1 (built; proxy gate in CI; the owner's Pi run gates Part 2a)
 └─ Part 2a slots, buses, synth in the callback
      └─ Part 2b source space, mix transaction, perf, snapshot
           └─ Part 2c MIDI routing
                └─ Part 3a Dart seam
                     └─ Part 3b domain + repository
                          ├─ Part 3c Dart source space + targets + labels
                          │    └─ Part 5 session recall (after #1196's chain)
                          │         └─ Part 6 routing/FX/Mixer/Tuner screens
                          │              └─ Part 7a Instruments page
                          │                   ├─ Part 7b editors (after Part 4)
                          │                   └─ Part 8 shared assignments
                          └─ Part 4 per-device captures
```

Part 2b edits `mix_tracks_frame`'s capture read, `process_input_frame`,
`le_mix_settings` and the perf arm, so it rebases after whichever of the
pitch/time, Peel, Reverse and Multiply/Divide parts that touch those have
landed. Each part runs the normal, ASAN and telemetry-off native suites where
native code changes, `dart analyze --fatal-infos`, Bloc lint, and independent
architecture, test-quality and adversarial reviews before the human merge
gate. Stop for review on: a second real-time thread, any allocation or lock
in render, MIDI through Dart on the note path, a second routing model for
instrument sources, a second capture of one device, a Dart-side copy of the
patch table, a dropped release, or a per-slot refusal in a batch.

## 5. Decisions taken under the standing rules

1. C voices inside the callback (D1); measured before integration. Rule 2:
   one RT thread, no added latency.
2. A pool of 64 slots with a default limit of 32 (64 if the Pi allows),
   eight instruments, same-instrument-first stealing with one fade slot per
   pool voice; Cut and patch changes fade in place (D2). Rule 2.
3. A joint budget with pitch/time on p99.9 and no late period, a runtime
   voice limit lowered on measured late periods with a toast, and the Pi
   gate on Part 2a (D2). Rules 2 and 3.
4. Instruments are fixed sources 32-39 in the existing input space, mono,
   with the mix transaction, the Dart bounds and the perf tap widened
   explicitly; pan lives in `InputSetup.pan` (D3). Rule 4.
5. Batches accept any source and render silence for an empty slot; refusals
   live in the repository and the UI (D3, H4). Rules 1 and 2.
6. MIDI notes are routed on the audio thread; note-offs are handled first by
   origin; releases are never dropped (an overflow releases its port, a
   reserved release lane carries Dart's); a quiescent sink protects detach
   and destroy; native loss detection (D4). Rule 2.
7. The patch table is C; Dart reads it and owns names and art; sessions store
   ids (D5). Rule 4.
8. Unavailable sounds: Choose another sound only; Install hidden; Retry only
   for audio-start failure (D6, owner). Rule 3.
9. Recall ownership as tabled in D7, through a `SettingsOwner` from Part 3b;
   per-slot outcomes; instrument-keyed targets; tombstones keep recorded
   labels and block slot reuse; a synth epoch resets latches (D7). Rules 1,
   3 and 5.
10. One capture per device, control path unchanged (D8). Rules 1 and 4.
11. New instruments: controllers Off, Hear live On at 75 %; computer keys on
    desktop builds only, with the stuck-key rules (D9, owner). Rule 3.
12. Drums play GM 35-44 and ignore note-off and sustain (D10); C3 = 60 (D11).
13. Engine reopen and reconfigure drop held notes, latches and sustain and
    replay definitions and routes; nothing held is restored. Rule 5.

## 6. Pen write-back list (for the owner; this plan never edits the pen)

- `gGTXF`, `Uv25f`, `t00H3H`: the Computer keys row and its editors are
  hidden on the appliance (owner, 2026-10-06); desktop builds match the pen.
- `hRKQL`: "Install sound pack" hidden until a pack mechanism exists (owner);
  the unavailable state offers Choose another sound only, with the reason
  "Sound not available in this version".
- `gGTXF`, `B5PEqI`: the reduced-polyphony line with Restore (D2) and the
  audio-start Retry (D6) are additions the pen does not draw.
- `gGTXF`: the Live sound panel gains Pan beside Level (delta review D1): an
  instrument's pan has no other editor, since Input setup stays physical and
  the Mixer has no live-input strip.
- Section 21 (`s0zlm`, `oegcz`, `MoriR`, `sTYRr`, `r47I8`, `mf0fR`): the
  screens show no instrument sources; the built screens add instrument cards
  and removed-instrument tombstones (Part 6).
- Attack readouts (Synths, Strings) show the synthesized 0.008-0.908 s, not
  the prototype's display formula (D5); `gGTXF`'s "Decay 1.52 s" is
  unchanged.
- D11's C3 = 60 matches the pen; it departs only from the prototype.

## 7. Plan review disposition (PR #1204)

| Finding | Where it is met |
|---|---|
| H1 mix transaction and Dart bounds | D3; Part 2b (native), Part 3c (Dart, one predicate, a test per site); pan in `InputSetup.pan` |
| H2 sink quiescence | D4; Part 2c, with the TSAN race test |
| H3 dropped releases | D4; port overflow flag (Part 2c), release lane (Part 2a), pending-release retry (Part 3b) |
| H4 per-slot refusal | D3, D7; Parts 2b and 5 |
| H5 sequencing | Part 5 now precedes Parts 6 and 7a |
| M1 note-off routing | D4, §2.3; Part 2c tests for four edits |
| M2 fade exhaustion | D2; Part 1 revised (one fade slot per voice, Cut in place, tested) |
| M3 joint budget and overload | D2; Part 1 joint scenario, p99.9, late periods, voice limit; Part 2c adds routing cost |
| M4 Pi gate | D2; the Part 1 Pi run gates Part 2a |
| M5 slot-keyed targets | D7; Part 3c |
| M6 source labels | D7 tombstones; Part 3c, Part 6 |
| M7 D6 trigger and Retry | D6 (owner): triggers named, Retry only for audio start, rollback test in Part 3b |
| M8 stuck computer keys | D9; Part 7b (desktop only, owner) |
| M9 latch sync | D7 synth epoch; Parts 2a, 3b, 8 |
| M10 hardware gates | moved to Part 7b |
| L1 line references | re-checked on `56033baf0` |
| L2 monitored-input consumers | Part 2b lists them |
| L3 origin space | D4 tag bit and contributor table |
| L4 patch application | §2.2: patch changes ride the ordered note ring (not commands); the snapshot reports the applied patch |
| L5 note names | D11 |
| L6 Listen button | Part 7a matches the pen |
| L7 device loss | D4: native port-exit and CoreMIDI notify |
| L8 publish coalescing | D4: latest-wins, direct flip while stopped |
| L9 pen departures | §6 |
| Delta D1 pan editor | D3; Part 7a Live sound panel (Level and Pan); §6 |
| Delta D2 overflow order | D4 overflow mark; Part 2c test |
| Delta D3 consistent cut | D4; built in Part 2a (high-water mark) |
| Delta D4 patch room | D4; built in Part 2a; Part 3b retries |
| Delta D5 memory order | D4 (seq_cst handshake); the shared sink (#1236) |
| Delta D6 epoch trigger | D7; Part 3b |
| Delta D7 stale text | §7 L4 row, Part 2a tests, D10 re-strike rule |
| Planner question 1 | owner: Install hidden, ids as strings, Retry only for audio start |
| Planner question 2 | owner: computer keys hidden on the appliance; M8 applies on desktop |

## 8. Genuine product-direction questions

None open. Both earlier questions were answered by the owner on 2026-10-06
(D6, D9).

## 9. Hardware-only evidence

- The Part 1 Pi verdicts, including the joint worst case, run in one session
  with the pitch/time bench (gates Part 2a).
- Note-to-sound latency with a USB MIDI keyboard on the appliance, compared
  with a physical input's round trip (Part 7b).
- Two simultaneous USB MIDI devices with the console board, unplug and
  replug (Part 7b).
- A 61-key controller with pads, sustain, bend, modulation, pressure and a
  32-note chord without late periods (Part 7b).
- Built-in and external pedal latches and LEDs (Part 8).
- The 19 patches by ear at 96 kHz (Part 7a); different sound from the
  prototype is permitted (`implementation-map.md`, "Exact rack/effect/parameter
  parity is required; different sound is permitted").
