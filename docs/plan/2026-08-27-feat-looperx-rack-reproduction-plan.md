# Reproducing the Sheeran Looper X racks in segno (#887)

Status: **programme plan, direction approved.** The owner has authorisation to
reuse the HG08 factory content and has chosen full sound reproduction — all
nine racks, all twenty-one missing modules — over a content-only import. The
`rack` naming collision with #535 is deliberately deferred.

This document establishes what the engine has today, what the target needs,
the three blockers between them, and a phase order that puts the two
critical-path refactors first.

## What is already extracted

`~/Downloads/LooperX_1.0.2_extracted/` (README documents the `AZ0x` container
and re-extraction steps). The parts that matter here:

- **159 presets in 9 racks**, each a flat `parameter name -> normalised
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

### B1 — the chain shape cannot hold a rack

`LE_FX_PARAMS = 4` is the binding constraint: eleven modules exceed it, with
EQ and the Harmonizer at fifteen. `LE_FX_MAX = 8` binds too — Ed's Rack is
nine modules.

**Proposal: `LE_FX_PARAMS` 4 -> 16, `LE_FX_MAX` 8 -> 16.** Sixteen covers
the widest module exactly. Cost is `16 * 16 * 4 B = 1 KiB` of atomics per
chain across three owner types — negligible, and it *preserves* the
fixed-size allocation-free snapshot property rather than trading it away for
variable-width params.

The work is not the constants; it is the 135 call sites, the persistence
format, `daw_export`'s VST3 parameter mapping, and every UI surface that
assumes four sliders.

### B2 — per-slot DSP state does not scale to 27 types

`le_fx_state` inlines every type's state per slot. Adding twenty-one modules
to that struct multiplies EQ biquad banks, compressor envelopes, chorus delay
lines and harmonizer voices across all sixteen slots, whether used or not.

**Proposal: one `void* state` per slot plus a per-type vtable**
(`prepare` / `reset` / `free` / `process`), allocated and freed on the control
thread in `le_fx_prepare_entry`, exactly as the plugin slot and the octaver's
PV buffers already do. Behaviour-preserving; provable by the existing suite.

**This is the highest-leverage item in the programme.** Everything in
Phase 3 stacks on it, and it is the one piece that gets harder the longer it
waits.

### B3 — the preset values are normalised against unknown tapers

`Rev Length = 0.42` has no known value in seconds. There is no descriptor
table to lift: string references are PC-relative under PIE and the ranges are
code immediates.

**But the tapers are measurable on the device.** The FX parameter widget
renders `name + ": " + valuestring + " " + unitString` through a translator
object (`AppUI/Pages/FxEdit/Parameter.qml:29-31`), so the screen shows the
engineering value for any normalised input. Presets are plain JSON on a
USB-visible path — `unpack_new_presets` writes them to
`$mnt_path/FX Presets/`, i.e. `/media/az01-internal/Looper/usb_mnt`
(`Scripts/def_vars`). And the rootfs ships `az01-ssh-login` and `telnet`.

So: author probe presets that walk one parameter across a known ladder of
normalised values, load them, read the rendered value back. That turns
"re-voice 159 presets by ear" into "sample 161 curves", which is the
difference between reproduction and guesswork.

**Measuring needs a physical Looper X, and there is not one available.**
Phase 0 is therefore **cut**. What follows is what survives without it.

#### What is recoverable with no hardware at all

Quantisation analysis over all 159 presets — for each parameter, the smallest
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

For the continuous parameters, import the normalised value at face value
against **a range segno defines and documents per parameter**, constrained by
the unit format strings we did recover (`%.1f : 1` bounds a ratio, `%.2f s` a
spring time, `%.0f dB` a threshold). The relative intent — which module is
on, roughly where each control sits in its travel — is preserved regardless
of taper, and that is what a preset actually encodes.

Phase 4 therefore ships **decoded-exact discrete values plus voiced-by-ear
continuous values**, and should say so in its own docs rather than implying
a faithful numeric port.

## Phase order

Each phase is one or more independently mergeable PRs.

| # | phase | gate | depends on |
|---|---|---|---|
| 1 | B2: type-tagged slot state (pure refactor) | `merge-gate` | — |
| 2 | B1: widen to 16 x 16 | `merge-gate` | 1 |
| 3a | Biquad family: EQ, HP/Gate, Wah, LPF widen | `merge-gate` | 2 |
| 3b | Dynamics: Compressor, Transient | `merge-gate` | 2 |
| 3c | Modulated delay: Chorus, Mod, Doubler, Spring, Dub Delay | `merge-gate` | 2 |
| 3d | Reverb family: Reverb widen, Dub Reverb, Ambient Reverb | `merge-gate` | 2 |
| 3e | Degradation: Vinyl, Degrade, Slicer, Pumper, Distort widen | `merge-gate` | 2 |
| 3f | Pitch family: Pitch Shift, Whammy, Harmonizer, Smart Tune | `merge-gate` | 2 |
| 3g | Amp+Cab | `plan-gate` | 2 |
| 4 | Preset import + voicing | `merge-gate` | 3a-3g |
| 5 | Content layer: icons, enum vocabularies, taxonomy | `merge-gate` | naming call |

Phases 1 and 2 are the only ones on the critical path; 3a-3g parallelise, and
5 can land any time the naming question is answered. Phase 0 (taper
measurement) is **cut** — no physical Looper X is available; see B3 for what
survives without it.

### Why 3g carries a `plan-gate`

Amp+Cab is the one module with open design risk. The update image ships **no
impulse responses** — `metronome.wav` is the only audio file in the entire
rootfs — so their cab simulation is algorithmic, not convolution. That is
good news (a filter-based cab is cheaper than an IR loader) but it means the
eleven cabinet voicings are ours to author, not to copy. Deciding how they
are modelled and measured is a direction call, not a taste one.

### Ordering rationale

3a first because EQ appears in eight of nine racks; nothing else moves the
needle as far. 3f last of the module phases despite being conceptually
hardest, because it is the one group that reuses machinery that already
works — the risk is integration, not DSP.

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

Phase 1. It is behaviour-preserving, provable by the existing native and Dart
suites, unblocks everything downstream, and is the only item that gets more
expensive with delay.
