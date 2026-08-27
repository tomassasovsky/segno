# Reproducing the Sheeran Looper X racks in segno (#887)

Status: **programme plan, direction approved.** The owner has authorization to
reuse the HG08 factory content and has chosen full sound reproduction — all
nine racks, all twenty-one missing modules — over a content-only import. The
`rack` naming collision with #535 is deliberately deferred.

This document establishes what the engine has today, what the target needs,
the three blockers between them, and a phase order that puts the two
critical-path refactors first.

## What is already extracted

`~/Downloads/LooperX_1.0.2_extracted/` (README documents the `AZ0x` container
and re-extraction steps). The parts that matter here:

- **159 presets in 9 racks**, each a flat `parameter name -> normalized
  0..1 float` map plus a `_version`. Every preset in a rack shares one fixed
  schema, so each rack's DSP surface is exactly known.
- **DSP parameter metadata** — names, printf unit formats (`%.1f : 1`,
  `%.2f ms`, `%.0f dB`), and the enum label tables (11 cabinets, 12 delay
  modes, 16 reverb rooms, 18 slicer patterns, scale types).
- **243 QML + 306 PNG** of the shipped UI, including 27 stomp-box tiles.

The DSP itself is compiled ARM in a stripped binary and is **not** recovered.
See B3 for why that is survivable.

## Current state (verified)

- **Seven built-in effect types.** `le_fx_type` —
  `packages/segno_engine/src/core/segno_engine_api.h:479-494` — is DRIVE,
  FILTER, DELAY, TREMOLO, OCTAVER, ECHO, REVERB, plus PLUGIN. Mirrored in
  Dart at `packages/segno_engine/lib/src/track_effect.dart:24`.
- **Chain shape is `LE_FX_MAX 8` x `LE_FX_PARAMS 4`**
  (`segno_engine_api.h:460-461`). The four-float width is deliberate: the
  audio thread reads "a fixed-size, allocation-free array"
  (`track_effect.dart:12-14`, `engine_private.h:351`).
- **Three chain owners**, each carrying `a_fx_type[LE_FX_MAX]` and
  `a_fx_param[LE_FX_MAX][LE_FX_PARAMS]` atomics: `le_lane`
  (`engine_private.h:316`), `le_monitor_input` (`:440`), `le_fx_bus` (`:544`).
- **`le_fx_state` inlines every type's per-slot DSP state**
  (`engine_private.h:224-264`): `svf_ic1/svf_ic2`, `lfo`, `delay`,
  `fx_lp`, `oct`, and the reverb comb/allpass banks — all sized
  `[LE_FX_MAX]`. **Every slot pays for every effect type.**
- **Blast radius of the two constants:** 78 references to `LE_FX_PARAMS`
  across `packages/segno_engine/src`, and 57 references to
  `kTrackEffectParams`/`kTrackEffectMax` across 13 Dart files including
  `looper_repository`, `daw_export` (`als_builder`, `segno_vst3_plugins`),
  `looper_bloc`, and `fx_scope`.

### What already exists that the target needs

This is better than it looks. Three of the hardest kernels are built:

- **Pitch machinery.** A phase-vocoder *and* a PSOLA shifter with YIN pitch
  detection already ship in the octaver (`engine_fx.h:29-40`,
  `le_octaver_state` at `engine_private.h:197-214`). Pitch Shift, Whammy,
  Harmonizer and Smart Tune are all applications of this, not new DSP.
- **Reverb.** A Schroeder/Freeverb comb-allpass network with per-bank state.
  Dub Reverb and Ambient Reverb are topology variants of it.
- **Biquad conditioning.** `le_cond_biquad` (`engine_private.h:482-485`) is
  the kernel the whole EQ / HP-Gate / Wah / cab family needs.
- **The heap-state precedent.** `LE_FX_PLUGIN` already carries "no fixed
  params and no DSP state in `le_fx_state` — its `process` forwards to a
  plugin host owned by an `le_plugin_slot`, loaded on the control thread"
  (`segno_engine_api.h:488-493`). The octaver's PV buffers follow the same
  pattern, allocated in `le_fx_prepare_entry`. **B2 below is generalising a
  pattern this codebase already uses twice, not inventing one.**

## What the target requires

Twenty-seven modules across the nine racks. Six exist; twenty-one do not.

| module | max params | racks | status |
|---|---|---|---|
| EQ (4-band / para / air) | 15 | 8/9 | **new** |
| Compressor | 6 | 5/9 | **new** |
| Delay | 6 | 9/9 | widen (has 3) |
| Reverb | 7 | 6/9 | widen (has 3) |
| Harmonizer | 15 | 1/9 | **new** (reuses PV) |
| Smart Tune | 13 | 1/9 | **new** (reuses YIN) |
| Amp+Cab | 6 | 2/9 | **new** (open design) |
| Octaver | 5 | 1/9 | widen (has 4) |
| Mod (cho/pha/fla) | 5 | 2/9 | **new** |
| LPF | 5 | 2/9 | widen (has 2) |
| Vinyl | 5 | 1/9 | **new** |
| Chorus, Degrade, Slicer, Transient, Ambient Reverb, Dub Delay | 4 | 1-2/9 | **new** |
| Doubler, Overdrive, Spring, Whammy, Distort, Pumper, Pitch Shift, HP/Gate | 3 | 1-3/9 | 2 exist, 6 **new** |
| Wah | 2 | 2/9 | **new** |

## The three blockers

### B1 — the chain shape, revised

**Correction to the first draft of this plan.** Each Looper X module carries an
on/off parameter (`Delay: 1.0`, `Reverb: 1.0`). Those are not parameters in
segno's sense — they map onto the **per-slot enable bit** the chain already
has (`a_fx_enabled`, `engine_private.h:368`). Discounting them, **19 of 26
modules fit inside today's `LE_FX_PARAMS = 4`**:

| fits today (19) | needs widening (7) |
|---|---|
| LPF (4), Vinyl (4), Mod (4), Ambient Reverb (3), Chorus (3), Slicer (3), Degrade (3), Transient (3), Doubler (2), Dub Delay (2), Overdrive (2), Pumper (2), Distort (2), Pitch Shift (2), Spring (2), HP/Gate (2), Octaver (1), Wah (1), Output (1) | EQ (up to 15 per rack), Harmonizer (12), Delay (8), Reverb (8), Smart Tune (8), Compressor (5), Amp+Cab (5) |

`LE_FX_MAX = 8` binds only on Ed's Rack (9 modules), which is a Phase 4
concern, not a Phase 1 one.

So the widen is **real but deferrable**, and doing it first would be building
against a requirement no shipped code has yet — precisely the speculative
work AGENTS.md rules out. It lands when the first module that needs it does.

### B2 — per-slot DSP state does not scale to 27 types

`le_fx_state` inlines every type's state per slot. Adding twenty-one modules
to that struct multiplies EQ biquad banks, compressor envelopes, chorus delay
lines and harmonizer voices across all sixteen slots, whether used or not.

**Correction: the vtable already exists.** `le_fx_vtable`
(`engine_fx.c:981-994`) dispatches `process` / `latency` / `prepare` /
`defaults` per type, and its own comment says "adding an effect is adding its
kernels above + one row here". `LE_FX_PLUGIN` already keeps all its state off
`le_fx_state`, and the octaver's PV buffers are heap-allocated in
`fx_octaver_prepare`.

What is missing is only a **generic per-slot state pointer** so a new type can
own an arbitrary struct without adding a field to `le_fx_state`. That is a
small addition, and — per AGENTS.md — it should land with the **first module
that needs it**, not before. The existing types stay where they are: migrating
them buys nothing and risks a working product.

### B3 — the preset values are normalized against unknown tapers

`Rev Length = 0.42` has no known value in seconds. There is no descriptor
table to lift: string references are PC-relative under PIE and the ranges are
code immediates.

**But the tapers are measurable on the device.** The FX parameter widget
renders `name + ": " + valuestring + " " + unitString` through a translator
object (`AppUI/Pages/FxEdit/Parameter.qml:29-31`), so the screen shows the
engineering value for any normalized input. Presets are plain JSON on a
USB-visible path — `unpack_new_presets` writes them to
`$mnt_path/FX Presets/`, i.e. `/media/az01-internal/Looper/usb_mnt`
(`Scripts/def_vars`). And the rootfs ships `az01-ssh-login` and `telnet`.

So: author probe presets that walk one parameter across a known ladder of
normalized values, load them, read the rendered value back. That turns
"re-voice 159 presets by ear" into "sample 161 curves", which is the
difference between reproduction and guesswork.

**Correction (2026-08-27, verified): a physical Looper X is not needed.**
The device runs under emulation on a developer Mac.

#### What was verified

- The binary disassembles cleanly (`arm-none-eabi-objdump`, ELF32 ARM). Its
  own C++ symbols are NOT exported — `.dynsym` holds only libc/ALSA imports —
  so static reverse engineering means reading anonymous assembly.
- **Every shared library it needs resolves from the extracted rootfs, with
  zero missing**, checked with the rootfs's own
  `ld-linux-armhf.so.3 --library-path ... --list`.
- **The application executes.** Under
  `docker run --platform linux/arm/v7` with `QT_QPA_PLATFORM=offscreen`, given
  a writable `/media/az01-internal/Looper`, it starts, clears initialization,
  spawns three threads, settles at ~35 MB RSS and parks idle in
  `rt_sigsuspend`. It does not crash — the only thing it originally complained
  about was that missing directory.

#### What that unlocks

1. **Taper recovery without hardware.** The parameter widget renders
   `name: valuestring unitString` through a translator object
   (`AppUI/Pages/FxEdit/Parameter.qml:29-31`). Drive the emulated app across a
   known ladder of normalized values and read the rendered value back, exactly
   as the hardware plan intended — on a laptop instead.
2. **Reference audio, which is the bigger prize.** Point the emulated app's
   ALSA at a file plugin, push a test signal through a factory rack, and
   capture what their DSP actually produces. That is ground truth to A/B every
   re-implementation against, and it is the thing whose absence forced
   "voiced by ear".

#### What remains genuinely out of scope

Transliterating the DSP out of machine code. Twenty-seven effects of anonymous
ARM VFP assembly is enormous, and it produces a mechanical copy of their object
code rather than an implementation. Emulation gives us the *behavior* far more
cheaply than reading the *code*, and behavior is what a re-implementation needs
to match.

#### Still unproven — what the spike must establish

- Audio in/out under emulation: an `asoundrc` pointing at ALSA's `file`/`null`
  plugins, and whether the app insists on its real hardware.
- Driving the UI headless: `offscreen` was accepted, but QML actually loading
  and being drivable is unconfirmed. The app ships `HWEmul.qml`, `DevSettings`
  and a screenshot facility gated on `Looper.screenshotsEnabled()`.
- Whether startup gates on the HG08 control surface being present.
- Throughput: emulated ARM is roughly an order of magnitude slower than
  native, which is irrelevant for offline capture.

Until that spike lands, Phase 6 still plans for mixed fidelity (discrete exact,
continuous voiced). If it lands, Phase 6 becomes a measured port and the
fidelity ceiling moves a long way up.

## How a .fxpreset actually lands (and what Chorus is)

A `.fxpreset` is a **whole rack**, not an effect. `Ed's Rack / Vocal Chorus`
carries 52 parameters spanning compressor, 4-band EQ, wah, overdrive, amp+cab,
chorus, octaver, delay and reverb. So a preset imports as a segno **chain** — an
ordered list of `TrackEffect` entries — never as a single entry.

Chorus is one *block* inside that chain. Its slice of the preset is four keys:

```
Chor       = 1.0     -> the chain entry's `enabled` bit
Chor Rate  = 0.127   -> params[0]
Chor Depth = 0.443   -> params[1]
Chor Mix   = 0.401   -> params[2]
```

The module on/off key becomes the per-slot enable bit, not a parameter — which
is why 19 of 26 modules fit the current 4-wide parameter row (B1).

### Nothing imports until a rack is fully covered

An importer that silently drops the blocks segno lacks would produce a chain
labelled "Vocal Chorus" that sounds nothing like it. So the import gate is
per-rack: a rack becomes importable when **every** block in its schema exists.

Coverage today, after Chorus (segno can express Overdrive/Distort → drive,
LPF → filter, Delay → delay, Dub Delay → echo, the three reverbs → reverb,
Octaver → octaver, Pumper → tremolo, Chorus → chorus):

| rack | expressible | still missing |
|---|---|---|
| Rhythmic | 4 / 6 | **EQ, Slicer** |
| Ed's | 5 / 9 | Amp+Cab, Compressor, EQ, Wah |
| Dub | 3 / 6 | Compressor, Doubler, EQ |
| Lo-Fi | 3 / 6 | Degrade, EQ, Vinyl |
| Studio | 3 / 7 | Compressor, EQ, Mod, Pitch Shift |
| Drum | 2 / 5 | Compressor, EQ, Transient |
| Guitar | 2 / 7 | Amp+Cab, Mod, Spring, Wah, Whammy |
| Vocal | 2 / 7 | Compressor, Doubler, EQ, HP/Gate, Pitch Shift |
| Vocal Tuner | 2 / 8 | Compressor, Doubler, EQ, HP/Gate, Harmonizer, Smart Tune |

### Build order, by how many racks each block unblocks

EQ (8 racks), Compressor (6), Doubler (3), then Amp+Cab / Wah / Mod /
Pitch Shift / HP/Gate (2 each), then Slicer, Degrade, Vinyl, Transient,
Spring, Whammy, Harmonizer, Smart Tune (1 each).

### The near-term target: make Rhythmic Rack importable

**Rhythmic is two blocks from the finish line — EQ and Slicer.** Landing those
makes it the first fully importable rack and lets the preset importer be built
and proven end to end against 10 real presets, instead of waiting on all
twenty-one modules. EQ is the right next module on both counts: it unblocks
eight racks, and it is half of the shortest path to a working import.

Note EQ is also the first module that needs B1's widen, so that lands with it.

## Phase order

**This is the important revision.** The goal is not "import the presets" — it
is "get each effect as close to the original as possible". That makes the
presets *test vectors*, not the deliverable, and it changes the critical path.

Without a reference, every effect is written to a recovered spec and judged by
ear. With one, each becomes **system identification** — the standard way
outboard gear is cloned: excite the original with known signals, measure the
response, fit an implementation, verify numerically. That is exactly the gap
between "similar" and "as close as possible", so the rig comes first.

| # | phase | gate | depends on |
|---|---|---|---|
| 0 | **Measurement rig** — drive the emulated device, capture reference audio (#891) | `merge-gate` | — |
| 1 | **Fidelity harness** — render our effect, score it against the reference | `merge-gate` | 0 |
| 2 | Widen `LE_FX_PARAMS` 4 → 16, landing with EQ | `merge-gate` | — |
| 3 | Effects, each fitted and verified: EQ, Compressor, Doubler, Amp+Cab, Wah, Mod, Pitch Shift, HP/Gate, then the singles | `merge-gate` | 0, 1, 2 |
| 4 | Widen `LE_FX_MAX` 8 → 16 (Ed's Rack is 9 blocks) | `merge-gate` | 3 |
| 5 | Preset import — near-mechanical once the DSP matches | `merge-gate` | 3 |
| 6 | Content layer: icons, enum vocabularies, taxonomy | `merge-gate` | naming call |

Phase 2 does not depend on the rig and can run alongside it. Chorus (#888)
shipped before the rig existed and is spec-based; it gets a fidelity pass in
Phase 3 like everything else — a small, deliberate cost of having started
before measuring.

### Why the rig is file-driven, not device-driven

Two unknowns made the rig look risky — getting audio in, and driving a
touchscreen UI headless. Both have file-shaped answers:

- **Parameters never go through the UI.** A `.fxpreset` is plain JSON on the
  USB-visible filesystem (`unpack_new_presets` writes to
  `$mnt_path/FX Presets/`), so probe presets are authored directly.
- **Preset selection and transport** are reachable over the device's own MIDI
  control surface: `/Engine/PresetCtrl/Rigs/SendPresetIndex` selects a preset
  and footswitches are plain notes on channel 0
  (`MidiAssignments/HG08_Control_Surface_MIDI_1_Assignments.qml`). Bounce is a
  footswitch page (`Pages/Footswitches/Bounce.qml`), so render-to-file is
  reachable.
- **Audio out is therefore a bounce**, not an audio device.

Note what the MIDI surface does *not* reach: individual FX parameters. That is
why probe presets, not MIDI, carry the parameter sweep.

The residual unknown is getting a stimulus *in* — audio import is a
touchscreen dialog. Fallbacks in order: import via the USB image the app
already mounts; construct a loop on disk directly (the layer-stream writer is
named in the binary); or ALSA with a file plugin.

### What identification can and cannot reach

- **Linear — EQ, filters, delay, spring, chorus/mod timing:** an impulse plus
  a sine sweep recover magnitude, phase and tap times essentially exactly.
  Expect a near-null match.
- **Dynamics — compressor, gate, transient, pumper:** steps and level-swept
  tones recover threshold, ratio, knee, attack and release directly.
- **Nonlinear — amp, cab, overdrive, distort, degrade:** multi-level sweeps
  recover the static curve plus its surrounding filters. Very close, not
  exact, and the most work.
- **Stochastic — vinyl noise:** cannot null-test; match statistically.
- **Pitch-tracking — Smart Tune, Harmonizer, Whammy:** depends on their
  detector's internals. Match the musical envelope (scale handling, latency,
  formant treatment); do not promise sample accuracy.

## Risks

- **The rig is a spike and may not land.** If stimulus audio cannot be got in,
  the fallback is today's position: spec-based re-implementation voiced by
  ear. Give it a fixed budget rather than letting it block Phase 2.
- **Phase 2's blast radius reaches `daw_export`.** Widening the parameter array
  changes the VST3 parameter mapping in `segno_vst3_plugins.dart` and the ALS
  builder. A session exported before Phase 2 must still open after it.
- **Twenty-one effects is a multi-quarter programme.** The phase table exists
  so it delivers continuously — every effect in Phase 3 is usable on its own,
  independent of whether a factory preset ever imports.

## Next step

Phase 0 — the measurement rig (#891). Everything else is guesswork until it
exists, and guesswork is what "as close as possible" rules out.
