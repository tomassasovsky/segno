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

**Measuring needs a physical Looper X, and there is not one available.**
Phase 0 is therefore **cut**. What follows is what survives without it.

#### What is recoverable with no hardware at all

Quantization analysis over all 159 presets — for each parameter, the smallest
`D` such that every observed value is exactly `k/D` — finds **47 of 160
parameters are discrete**, and they are the musically decisive ones:

| parameter | D | reading |
|---|---|---|
| `Pitch Shift` | 24 | 25 steps over +/-12 semitones; the values used decode to -12, unison, +7, +12 |
| `Del Time` | 19 | the 20-entry note-division table (`1/32 ... 8/4`) — delays are tempo-synced |
| `Voice 1/2 Delay` | 22 | 23-entry division table |
| `Slic Step Len` | 8 | 9 divisions |
| `LPF LFO Rate` | 15 | 16 divisions |
| `Pumper Rate` | 10 | 11 divisions |
| `Cab` | 11 | indices land exactly on the 11-cabinet list |
| `Del Mode` | 11 | 12 modes |
| `Mod Mode` | 2 | CHORUS / PHASER / FLANGER |
| `Rev Mode`, `Slic Patt`, `Key`, `Voice 1/2 Pitch`, `Gate Thresh` | various | exact |
| 26 module on/off switches | 1 | exact |

So **every mode selection, note division, cabinet choice and pitch interval
transfers exactly**, with no device. Only the **113 continuous** parameters
(gains, ms, Hz, mixes) carry unknown tapers.

#### What that leaves

For the continuous parameters, import the normalized value at face value
against **a range segno defines and documents per parameter**, constrained by
the unit format strings we did recover (`%.1f : 1` bounds a ratio, `%.2f s` a
spring time, `%.0f dB` a threshold). The relative intent — which module is
on, roughly where each control sits in its travel — is preserved regardless
of taper, and that is what a preset actually encodes.

Phase 4 therefore ships **decoded-exact discrete values plus voiced-by-ear
continuous values**, and should say so in its own docs rather than implying
a faithful numeric port.

## Phase order

Revised against the two corrections above: the vtable exists, and 19 of 26
modules fit the current parameter width. So the programme is not
"two refactors then modules" — it is **modules first, widening when a module
demands it.**

| # | phase | gate | depends on |
|---|---|---|---|
| 1 | First module end to end: **Chorus** | `merge-gate` | — |
| 2 | Remaining ≤4-param modules, grouped by shared kernel | `merge-gate` | 1 |
| 3 | Widen `LE_FX_PARAMS` 4 → 16, landing with **Compressor** (first module that needs it) | `merge-gate` | 1 |
| 4 | Wide modules: EQ, Reverb widen, Delay widen, Amp+Cab, Smart Tune, Harmonizer | `merge-gate` | 3 |
| 5 | Widen `LE_FX_MAX` 8 → 16, landing with the Ed's Rack import | `merge-gate` | 4 |
| 6 | Preset import + voicing | `merge-gate` | 2, 4 |
| 7 | Content layer: icons, enum vocabularies, taxonomy | `merge-gate` | naming call |

Phase 1 is deliberately a *small* module rather than a high-coverage one. Its
job is to prove the whole path — native kernel, vtable row, Dart enum,
parameter labels, FX editor UI, persistence, DAW export — on a capability
that is useful on its own. Chorus is three parameters (rate, depth, mix),
reuses the existing stereo delay ring (`fx_stereo_ring_prepare`), and is a
plain win for a looper independent of whether a single factory preset ever
imports.

Phase 2 then adds modules on a path that is already proven, grouped so each
PR shares a kernel: modulated delay (Mod, Doubler, Spring, Dub Delay),
degradation (Vinyl, Degrade, Slicer, Pumper), dynamics-lite (Transient,
HP/Gate), and filter (Wah, LPF widen).

Phase 0 (taper measurement) is **cut** — no physical Looper X is available;
see B3 for what survives without it.

### Why 3g carries a `plan-gate`

Amp+Cab is the one module with open design risk. The update image ships **no
impulse responses** — `metronome.wav` is the only audio file in the entire
rootfs — so their cab simulation is algorithmic, not convolution. That is
good news (a filter-based cab is cheaper than an IR loader) but it means the
eleven cabinet voicings are ours to author, not to copy. Deciding how they
are modeled and measured is a direction call, not a taste one.

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

## Risks

- **Phase 2's blast radius reaches `daw_export`.** Widening the parameter
  array changes the VST3 parameter mapping in `segno_vst3_plugins.dart` and
  the ALS builder. A session exported before Phase 2 must still open after
  it; that is a persistence-compatibility problem, not just a constant.
- **Phase 4 ships mixed-fidelity presets.** Discrete parameters decode
  exactly; continuous ones are voiced by ear against ranges we choose. That
  is a documentation obligation, not a defect — but a preset labelled
  "Ed's Rack / Vocal Chorus" must not imply a numeric port of one.
- **Twenty-one modules is a multi-quarter programme.** The phase table exists
  so it delivers value continuously — every 3x phase is usable on its own,
  independent of whether the factory presets ever import.

## Next step

Phase 1 — Chorus, end to end.
