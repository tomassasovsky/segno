Model: Claude Opus (subagent), in-session

# Review of PR #1268 (origin/claude/instruments-1197-p3a @ e44e74064, stacked on #1262): feat(engine): add the Dart instrument seam

## Scope

- One commit on `69f6c4cdf`, 20 files, +2368/−9: 1,624 lines added
  outside tests, about 1,200 of them code.
  - `audio_engine.dart`: the `InstrumentHost` and `MidiInputSink` roles,
    composed into `AudioEngine`, and two new `EngineResult` codes.
  - `instruments.dart`: `InstrumentRoute`, `InstrumentRemap`,
    `MidiCaptureHandle`, `InstrumentsSnapshot`, `MidiInputSnapshot` and the
    constants.
  - `synth_catalogue.dart`: `SynthCatalogue`, `SynthPatch`, `SynthParamInfo`
    with `valueAt`.
  - `native_audio_engine.dart`: the FFI implementation, `readSynthCatalogue`
    and `writeInstrumentRoutes`.
  - `simulated_instruments.dart`: the `SimulatedInstruments` mixin, used by
    `MockAudioEngine` and the four fakes, plus `referenceSynthCatalogue`.
  - `engine_snapshot.dart`: `instruments` and `midiInput` groups.
  - `MidiClient.captureHandle`.
  - Tests: native-library tests, unit tests and simulation tests.
- No C changes.
- Reviewed against:
  - Part 3a of the plan at `5e36d2666` ("about 300 production lines"), and
    its stop list (line 1455: "a Dart-side copy of the patch table");
  - the native behaviour of Parts 2a-2c;
  - AGENTS.md (role interfaces, layering) and the owner rules.

## Runs

Each run used a fresh TMPDIR, in a scratch worktree at `e44e74064`.

- `packages/segno_engine` with `SEGNO_ENGINE_LIB`: 408 passed, 0 skipped.
  The four native instrument tests ran.
- `packages/midi_client`: 42 passed.
- `packages/looper_repository`: 754 passed, 52 skipped.
- `packages/performance_repository`: 130 passed.
- `packages/session_repository`: 189 passed. (These hold the changed
  fakes.)
- After `flutter gen-l10n`:
  `dart analyze --fatal-infos lib test packages/segno_engine packages/midi_client packages/looper_repository packages/performance_repository packages/session_repository`
  found no issues.
- No native code changed, so the native suites, TSAN races and bench smoke
  are the Part 2c runs (see that review).
- CI runs the native-backed package tests in the `fuzz` job
  (`main.yaml`, "Run the segno_engine package tests", with the library
  built). The reference-catalogue pin therefore runs in CI and does not
  self-skip.
- **Probe** (`chord_probe.c` on this branch's engine): three
  `le_engine_instrument_note_on` calls with one origin (60, 64, 67).
  Result: 1 voice sounding, 2 fading.

## Verified correct (traced)

- **Role interfaces.**
  - `InstrumentHost` and `MidiInputSink` are composed into `AudioEngine`
    like the other roles (interface segregation).
  - Every implementer gains them: `NativeAudioEngine` directly, and
    `MockAudioEngine` plus the four fakes through the one mixin, so there is
    one model rather than four.
- **Results.** `EngineResult.fromCode` maps −14 and −15, and everything else
  still maps to invalid.
- **NativeAudioEngine.**
  - Every call checks it is alive and maps the native code.
  - `setInstrument` allocates the three params with `calloc` only when they
    are given, and frees them in `finally`.
  - `setInstrumentRoutes` writes a calloc'd `le_inst_routes`. It writes
    out-of-range counts as given, so the engine refuses them; no silent
    clamp.
  - The catalogue is read once, through the pure exports.
- **Snapshots.**
  - `InstrumentsSnapshot.fromNative` reads patches, voices, peaks,
    `monitor_peaks[32+k]`, the limit, the steal counts, the epoch and the
    refused counts.
  - `MidiInputSnapshot` keeps edges and totals but leaves out the
    per-message counters, so a MIDI clock cannot defeat the snapshot dedupe.
  - Both groups take part in `EngineSnapshot` equality and copy.
- **Capture handle.** `MidiCaptureHandle` compares by pointer.
  `MidiClient.captureHandle` checks the client is alive, and the sink
  (#1246) detaches on close and dispose.
- **The reference catalogue pin.** The native test compares all 19 ids,
  families and defaults, and every family's key, unit, exponential flag and
  range.

## Findings

### Medium

**M1. The simulated model disagrees with the engine on the same origin, so repository tests built on it (Part 3b) will encode behaviour the engine does not have (`simulated_instruments.dart`, `instrumentNoteOn`).**

The simulation's repeated-strike rule removes a voice only when slot,
origin *and note* match, and it removes sustained voices too. The engine
(`synth_voice.c`, the `note_on` restrike loop) fades every HELD voice of the
same slot and origin, whatever the note, and keeps SUSTAINED ones ringing.
Two consequences:

- **A chord from one origin.** The probe shows that the engine plays only
  the last of three notes posted with one origin (1 sounding, 2 fading). The
  simulation plays all three.
  - Part 8 plans chords with "the binding's id as the origin token"
    (plan line 1400), so those chords will pass every
    `MockAudioEngine` test and play one note on the device.
  - Only MIDI remaps have a chord entry point
    (`le_synth_note_on_chord`). The control API has none, and
    `InstrumentHost.instrumentNoteOn`'s doc does not say that one origin
    means one note.
- **A re-strike under sustain.** The simulation drops the sustained voice of
  the same note and origin. The engine keeps it ringing (accepted
  `:382-387`: "repeated strikes stay distinct voices").

Fix:
- Match the simulation to the engine's rule: same slot and origin, HELD
  only.
- Then either document "one origin, one sounding note" on `instrumentNoteOn`
  (Part 8 then mints one origin per chord note), or add a chord note-on to
  the native control API (an event flag that skips the restrike rule) and
  to the role.
- Add a parity test that runs one scripted sequence through `MockAudioEngine`
  and `PumpedNativeEngine` and compares voice counts per slot. That covers
  a chord, a re-strike, sustain and a limit. It would have caught both
  differences.

**M2. A Dart copy of the patch table ships in the app's mock flavour, which the plan lists as a stop condition (`simulated_instruments.dart:351-354`, `referenceSynthCatalogue`).**

The plan's stop list (line 1455) includes "a Dart-side copy of the patch
table", and Part 3a's text describes `MockAudioEngine` as a fake voice
model with no catalogue copy. `referenceSynthCatalogue` is exported from
`segno_engine.dart`. `MockAudioEngine` reaches production through
`createMockEngine` (the mock flavour,
`packages/looper_repository/lib/src/looper_repository.dart:109`).

The native pin test runs in CI, so the copy cannot drift silently. What
remains:
- the plan's rule is broken without a recorded decision;
- any later presentation code can import the copy instead of
  `synthCatalogue()`.

Fix: record the decision in the plan, as a mock-only copy pinned by the
native test. Then keep it out of the public barrel, or mark it
`@visibleForTesting` and have `MockAudioEngine` reach it through `src/`, so
app code can only read the catalogue from an engine.

### Low

**L1. The part is about four times its estimate and over the 700-line ceiling.**

Plan: about 300 production lines. Built: about 1,200 code lines (1,624
added outside tests). The overrun is the simulation (559 code lines with the
reference table) and the snapshot groups. Nothing in the findings document
or the plan records it.

**My judgement: split it**, at a seam that keeps each half mergeable.
- **(i) The seam.**
  - The two roles, declared but not yet composed into `AudioEngine`.
  - The value types and snapshot groups, the `EngineResult` codes.
  - `NativeAudioEngine`'s implementation (it can implement the roles
    directly), `captureHandle`, and the native-library tests.
  - About 650 lines. Nothing else has to change, because no fake implements
    the new roles yet.
- **(ii) Composition and simulation.**
  - Compose the roles into `AudioEngine`, add `SimulatedInstruments` and the
    reference catalogue (with M1 and M2 settled), wire the mock and the four
    fakes, and add the parity test.
  - About 600 lines.

If the owner prefers one PR, record the overrun and its reason as Part 1
did.

**L2. `kMaxVoiceLimit = 64` is typed by hand (`instruments.dart`).**

Every other constant in the file references the C (`LE_MAX_INSTRUMENTS`,
`LE_INST_MAX_REMAPS` …). `LE_SYNTH_MAX_VOICES` lives in the internal
`synth_voice.h`, not in the public API. Export it, or derive this constant
from an existing public one, so it cannot drift from the engine's
`le_engine_set_voice_limit` bound.

## Notes

- `readSynthCatalogue` skips any patch or family whose native read fails
  rather than failing loudly. With the pin test in CI that cannot happen
  unnoticed today, but a short catalogue would show fewer sounds without a
  notice (rule 5).
- `InstrumentsSnapshot` includes per-block peaks, so `EngineSnapshot`
  equality changes every block while an instrument sounds. Input peaks
  already behave this way, so this is not a new dedupe cost.

Verdict: Request changes (M1; M2 needs a recorded decision; the split is my recommendation, not a blocker).
