# Ableton device presets on the pedal, Drift first — plan

<!-- cspell:words adv adg polyBLEP polyBLAMP halfband xorshift Box Muller -->

**Issue:** SEG-109 (`needs-plan-approval`). Related: SEG-57 (Segno's
instrument voices), SEG-50 (stem history replay).
**Brainstorm:** `docs/brainstorm/2026-11-24-ableton-devices-brainstorm-doc.md`
(decisions, the owner's answers, and Drift's behavior, which is the
specification every part below implements).
**Status:** awaiting the owner's approval. No code before it.

## Goal

A user copies Live device presets to a USB drive or Internal, opens the
Ableton section of the Instruments sound library, picks a Drift preset, plays
it from MIDI or the pedal, edits its parameters on the console, records it in
stereo and gets it back with the session. Other Live instruments follow on
the same path, one issue each.

## Constraints

- The boundary in the brainstorm: Segno's code is written from the behavior
  description; no Ableton code, presets or data tables in the repo, the
  image or test fixtures. Test fixtures are XML that Segno's tests write
  themselves.
- The appliance runs 96 kHz with 64-frame periods (667 µs). CPU is
  measured, not assumed (SEG-57 Part 1's bench).
- The design source is Penpot: UI parts land with a Penpot change and a
  linked segno-design PR.
- Layers: every part ships something that works end to end on what is
  already on master.

## Parts

Each part is one PR on `claude/ableton-devices-SEG-109-p<N>`, `Refs SEG-109`
except the last, which says `Closes SEG-109`.

### P1. Stereo instrument buses (engine)

- `inst_bus` becomes LE_MAX_INSTRUMENTS stereo pairs.
  `le_synth_render` writes the Segno patch voice to both channels (no sound
  change for the 19 patches).
- An instrument source feeds its input chain in stereo
  (`LE_FX_CHAN_IN_STEREO` takes left and right as they arrive). The heard
  image (`engine_heard.c`) then holds the instrument's stereo as played.
- The clean take records (L + R) / 2. Known limit, documented in
  PROGRESS.md: re-running effects from the clean take (SEG-50) loses an
  instrument's own stereo spread.
- Peaks, the input meters and `le_instrument_source_sample` callers read
  the pair; every physical-only stage is unchanged.
- Tests (native): a stereo test voice panned hard left reaches the input
  chain's left only; the heard image keeps it; the clean take is the mono
  sum; the 19 patches render bit-identical per channel to today's mono bus.
- Gate: `agent-merges` is too wide here (recording path): `needs-merge`.

### P2. Preset reader (Dart package `packages/ableton_preset`)

- Reads `.adv` and `.adg`: gunzip (`dart:io`), XML (`package:xml` ^7.1.0,
  which `packages/daw_export` already uses), schema check (`MajorVersion` 5), the
  device element and every parameter's `Manual` value with its
  `MidiControllerRange`.
- `AbletonPreset { device, name, folderPath, values, unread }`; a per-device
  schema (`DriftSchema`) types the values, maps enum indices by name (the
  stored oscillator order is the UI's, see the brainstorm), clamps to the
  stored ranges and lists what it could not map.
- A library scanner walks a folder (USB or Internal) and lists presets by
  device and Live's folder names, without opening each file twice.
- Tests: fixtures written by the tests (minimal XML gzipped in the test),
  covering every Drift parameter group, a wrong schema, a truncated gzip, an
  unknown device (listed, not playable) and a rack (`.adg`, listed as
  unsupported for now).
- Gate: `agent-merges`.

### P3. Drift engine module (C, `drift_voice.c` / `drift_voice.h`)

Implements the brainstorm's "Drift: behavior" section, pure and real-time
safe like `synth_voice.c` (no allocation, locks or syscalls after init).

- 32 voices in blocks of four (NEON on the Pi through the existing
  `engine_fx_simd.h` helpers), per-sample modulation, parameters applied
  per 32-frame chunk with linear ramps.
- Oscillators (seven types, polyBLEP/polyBLAMP), Gaussian noise, mixer and
  routing, low-pass I and II, high-pass, both envelopes, the cycling
  envelope, the LFO, the matrix and the fixed modulation, voice modes and
  stealing, per-key tuning (Segno's own table), note gain (ISO 226 computed
  from the standard).
- HiQuality: Live runs Drift at 2× the host rate; at 48 kHz that is 96 kHz.
  Proposal: at a host rate of 88.2 kHz or more (the appliance) Drift runs at
  the host rate and HiQuality is a no-op; below it, 2× with Segno's
  `halfband.c`. This halves the CPU on the appliance and keeps Live's
  internal rate. Owner to confirm.
- An instrument slot holds a Segno patch or a device (`LE_INST_KIND_PATCH`,
  `LE_INST_KIND_DRIFT`); the note rings, sustain, expression and MIDI
  routing of SEG-57 drive both. Parameter changes go through the same
  command ring as `le_engine_set_instrument_param`, keyed by a Drift
  parameter id.
- Tests (native): deterministic renders at fixed seeds; band-limiting
  (alias energy of each oscillator type under a threshold at 48 kHz);
  envelope and LFO shapes against the formulas; filter responses
  (type I slope, high-pass Q); voice allocation, stealing and each voice
  mode's voice count, pan and detune; parameter ramps; render identity
  across block sizes.
- CPU: `bench_instruments` gains Drift scenarios (1, 8, 16, 32 voices, each
  mode) at 96 kHz / 64. The default voice limit is set from the console's
  numbers (`needs-hardware` for the measurement, as SEG-57 Part 1).
- Gate: `needs-merge`.

### P4. Fit against Live (the brainstorm's open items)

- A render list: a reference patch and one parameter swept at a time (the
  open items 1-5), each rendered in Live 12 (exported audio kept outside
  the repo, under `~/development/ableton-re/renders/`) and by Segno's
  offline render of the same settings.
- A comparison tool (`tool/drift_compare.dart` or a native test helper):
  envelope times from the attack and decay curves, filter responses from
  swept noise, pan and detune from unison renders, spectra for the
  oscillators.
- The fitted constants go into `drift_voice.c` with a comment naming the
  measurement, and the brainstorm's open items are closed one by one.
- Live renders need Live's UI: the owner exports them, or a session drives
  Live with computer use after the owner grants it.
- Gate: `needs-merge` (taste: the owner A/Bs Segno against Live by ear on
  the reference presets).

### P5. Instruments domain and sessions (Dart)

- An instrument's sound is a Segno patch or an Ableton device sound
  (`AbletonSound { device: drift, presetName, values }`).
- A session stores the values Segno uses, not the preset file, so a session
  opens with the drive removed.
- Loading a preset sends every parameter; an edit sends one.
- The library repository lists the Ableton section from the scanner (P2)
  over Internal and the mounted USB drives (SEG-53's storage service).
- Tests: repository, cubit and session round-trip tests.
- Gate: `needs-merge`.

### P6. UI: the Ableton section and the Drift editor

- Penpot first: pen section 54's sound library gains the Ableton section
  (device → Live folder → preset); a new Drift editor screen, grouped as
  Drift's own panels (Oscillators, Mixer, Filter, Envelopes, LFO, Mod
  matrix, Voice), using Segno's existing knob, selector and readout
  controls. A `c/` note per screen. segno-design PR with the snapshot,
  linked both ways.
- Flutter: the section and the editor, widgets as classes, l10n strings,
  golden screenshots compared against the Penpot frames.
- Gate: `needs-merge`.

## Order and dependencies

P1 and P2 are independent and can run in parallel. P3 needs P1 (stereo
buses). P4 needs P3. P5 needs P2 and P3. P6 needs P5. Each part is
playable on its own: after P3 a native test or the bench plays Drift; after
P5 a session plays a Drift preset with a default editor-less UI entry; P6
finishes the console experience.

## Verification

Per part, the repo's verify loop (AGENTS.md): Flutter tests for touched
paths while iterating, the full suites once before pushing, native engine
tests, `dart analyze`, `bloc lint`, `check_no_widget_methods`, goldens for
UI parts, `/code-review` once at the end of each PR (two rounds at most).

## Questions for the owner

1. Approve the parts and their order.
2. HiQuality at 96 kHz: run Drift at the host rate (proposed), or always
   2× (twice the CPU)?
3. P4's renders: you export them from Live, or a session drives Live with
   computer use?
