# Ableton Live device presets on the pedal — brainstorm

<!-- cspell:words adv adg Ghidra devicekit Lfo Vec analyzeHeadless gpr Wavetable wavetables ADSR BLEP BLAMP wavefolder crossfading prewarp Modwheel detuned unnormalised Clob -->

**Date:** 2026-11-24
**Issue:** SEG-109 (related: SEG-57, Segno's own instrument voices)
**Status:** decisions locked with the owner (2026-11-24); Drift's behavior
described from the analysis (2026-11-25), with the open items listed;
ready for `/plan`.

## Problem / motivation

The owner has Live 12 Suite's device library
(`~/Documents/Ableton Live Devices`: 2,214 presets) and wants to play those
instruments and effects on the Segno pedal. A preset holds only parameter
values. The sound comes from Live's devices, so Segno needs its own devices
that behave like Live's, plus a reader that turns a preset into settings for
them. Instruments come first, starting with Drift.

## What a preset is

- `.adv` (one device) and `.adg` (a rack) are gzip-compressed XML, schema
  `MajorVersion="5" MinorVersion="12.0_12203"`, written by Live 12.2.
- The root holds one element named for the device (`<Drift>`, `<Pedal>`,
  `<Operator>` ...). Each parameter is an element with a `<Manual Value=...>`
  (the stored value in the parameter's own unit: Hz, seconds, 0..1, an enum
  index or a boolean) and usually a `<MidiControllerRange>` with its min and
  max. Enums are stored as bare indices; their names live in Live.
- The library by folder: 11 instruments with presets (Operator 331, Wavetable
  270, Tension 107, Drift 89, Meld 84, Sampler 76, Analog 58, Simpler 38,
  Collision 33, Electric 17, Impulse 13), 45 audio effect folders and 11 MIDI
  effect folders. Sampler, Simpler and Impulse presets reference sample files
  that are not in this folder.

### Drift's parameters (all 89 presets)

80 parameters in ten groups: `Oscillator1_*` (Type 0..6, Shape, ShapeMod,
ShapeModSource, Transpose -2..3 octaves), `Oscillator2_*` (Type 0..4, Detune
-7..7, Transpose -3..2), `Mixer_*` (two oscillator gains and noise, 0..+6 dB
as 0..1.995 linear, on switches), `Filter_*` (low-pass Type 0..1, Frequency
20 Hz..20 kHz, Resonance 0..1.01, high-pass 10 Hz..20.5 kHz, key Tracking,
two mod sources and amounts, per-source filter routing), `Envelope1_*` and
`Envelope2_*` (ADSR, attack 0..60 s, decay 5 ms..60 s, release 10 ms..60 s),
`CyclingEnvelope_*` (Mode 0..3, Rate 0.17..1700 Hz, Ratio, Time, SyncedRate
0..21, MidPoint, Hold), `Lfo_*` (Mode 0..3, Shape 0..8, Rate, Ratio, Time,
SyncedRate, Amount, mod source and amount, Retrigger), `PitchModulation_*`
and `ModulationMatrix_*` (three slots of source 0..7, target 0..11 (presets use up to 10), amount
-1..1), and `Global_*` (VoiceMode Poly / Mono / Stereo / Unison, VoiceCount
0..4, depth per mode, DriftDepth, Glide 0..2 s, Legato, PitchBendRange,
VolVelMod, Volume, Transpose -48..48, Envelope2Mode, ResetOscillatorPhase,
HiQuality).

The full table, with every range and the values the presets use, comes from
a script that reads the presets; it is reproduced in the plan, not committed
with preset data.

## How the behavior is learned

Live 12.2.7's arm64 executable exports C++ symbols, so each device's code can
be found by name. Drift is built on Ableton's DeviceKit framework:
`ODeviceKitBufferRateProcessor<ableton::devices::drift::DriftDevice>::CalcMain`
renders it; the voice code is `ableton::blocks::drift::DriftVoiceBlock` under
a 32-voice `DriftVoiceManager`, with `MonoVoiceModeHandler`,
`UnisonVoiceModeHandler`, `computeNoteGain` and `cyclingEnvelopeQuartic`
named, and named enums (`FilterTypes`, `LfoShapes`, `LfoModes`,
`ModulationSources`, `ModMatrixModulationTarget`, `VoiceCounts`,
`OscillatorType1/2`). Most of the DSP is inlined into `CalcMain`.

Tooling: [rea](https://github.com/morluto/rea) 6.10.1 with Ghidra 12.2 and
JDK 25 (Homebrew), Node 24 for rea. Ghidra analyzes the arm64 slice once into
a persistent project outside the repo (`~/development/ableton-re/`), and rea
reads it through `REA_GHIDRA_PROJECT_PATH`.

### Boundary (owner's call, recorded on SEG-109)

Decompiled code is read to learn behavior: parameter units and curves, signal
order, filter and oscillator kinds, modulation routing, voice allocation.
Segno's code is written from scratch from that description. No Ableton code
is copied or transliterated, and no Ableton presets or data tables are
committed or shipped; Segno reads presets from the user's own copy.
Decompiling Live is against Ableton's EULA; the owner chose this approach
knowing that.

Each device's findings are written as a behavior description (this doc and
the plan) before any Segno code for it, and the code cites the description,
never addresses or decompiled listings.

## Drift: behavior

Learned 2026-11-25 from Live 12.2.7 (four parallel reads of the voice
render, the modulation stage, the voice manager and the parameter
handlers). Tags: **[code]** read from the compiled code, **[inferred]**
deduced from structure, names, ranges or presets, **[open]** to settle by
rendering Live with known settings and comparing (section "Open items").
This is a description of behavior in Segno's words; the implementation is
written from it.

### Rates and structure

- 32 voices, rendered four at a time (one SIMD lane per voice), one sample
  per call. **[code]**
- The host buffer is cut into chunks of at most 32 samples. Parameter
  values are applied once per chunk; every change ramps linearly from its
  current value over the event's ramp length. MIDI notes start and stop at
  their exact sample. **[code]**
- Inside a voice, modulation sources, envelopes, the LFO, the matrix,
  oscillators and filters (including the filter coefficients) all run every
  sample. **[code]**
- HiQuality (on in every factory preset) runs all voices at 2× the host
  rate and decimates with a polyphase allpass halfband. Off: host rate, no
  decimator. Segno uses its own halfband (`halfband.c`). **[code]**
- Stored preset values are in the parameter's display unit (Hz, seconds,
  linear gain, octaves, semitones, −1..1 amounts, enum indices) and reach
  the DSP through a fixed linear map per parameter, two Global parameters
  through a power curve. **[code]** for the shape; the constants **[open]**.

### Voice signal path, per sample

1. Pitch: note frequency (equal temperament, A4 = 440 Hz) → glide →
   per-key tuning → per-oscillator ratio (transpose, detune) → pitch
   modulation.
2. Oscillator 1, oscillator 2 and noise.
3. Mixer: each source × its gain (× its gain modulation), 0 when its switch
   is off.
4. Routing: each source goes into the filter sum or around the filters, by
   its own switch (stored `Through = true` means filtered **[inferred from
   presets]**).
5. Filter sum: hard clip at ±1.6, × 0.25 → low-pass (type I or II) → −10 dB
   → high-pass.
6. The bypassed sum × about −17.8 dB (roughly the filter path's pass-band
   gain, so a routing switch keeps the level) is added after the high-pass;
   the sum is clipped at a fixed limit **[open: its value]**.
7. Amplitude: × Envelope 1 × (1 − VolVel + VolVel · velocity) × Main
   Volume gain (matrix target 11) × note gain × voice-mode gain and pan.

### Oscillators

- Stored type order (the UI's) differs from the DSP's; the reader maps by
  name. Osc 1: Sine, Triangle, Shark Tooth, Saturated, Saw, Pulse,
  Rectangle. Osc 2: Sine, Triangle, Saturated, Saw, Rectangle, each its
  Shape = 0 form. **[code]**
- Phase accumulator per oscillator, increment f / fs clamped below Nyquist;
  a phase-offset input moves the read point. Jumps are band-limited with
  2-sample polyBLEP, slope corners with polyBLAMP. No wavetables.
  **[code]** What drives the phase offset is **[open]**.
- What Shape (0..1, plus shape modulation) does per type **[code]**:
  - Sine: a parabolic sine through a wavefolder, gain 1 + 4·shape.
  - Triangle: gain 1 + 7·shape, then an asymmetric fold (different
    thresholds above and below zero, so even harmonics appear).
  - Shark Tooth: a falling ramp with a triangular dip whose width runs from
    10 % of the cycle (shape 0) to the whole cycle (shape 1, a triangle).
  - Saturated: a scaled, clipped triangle through a parabola; asymmetric, so
    it carries a DC offset (about −0.33 at shape 0). Not band-limited.
  - Saw: hard sync, slave ratio 1 + 10·shape; the master-reset edge is not
    band-limited.
  - Pulse: a pulse whose duty runs 20 %..99 %, crossfading with shape into a
    train of half-sine bumps that decay to the floor across the cycle.
  - Rectangle: pulse width 50 %..99 %; negative shape modulation narrows it.
- Transpose: whole octaves (Osc 1 −2..+3, Osc 2 −3..+2). Osc 2 Detune:
  semitones, −7..+7, fractional. **[inferred from ranges and labels]**
- Noise: Gaussian white, per voice (xorshift + Box–Muller), clipped at
  ±10, no colouring. **[code]**

### Filters

- Low-pass cutoff = Frequency × key tracking × 2^(10 · S), clamped to
  10 Hz..20 kHz, where S = Σ (filter mod source × amount) + matrix slots
  targeting LP Frequency: 10 octaves per unit. Resonance = stored 0..1.01 +
  matrix slots targeting LP Resonance, clamped to 0..1.3. **[code]**
- Key tracking uses the voice's key value (note − 69)/120 **[code]**; the
  formula with `Filter_Tracking` is **[open]**.
- Type I: a two-pole zero-delay filter with two unequal one-pole
  integrators (capacitor ratio 3.3, so a 12 dB/oct slope with a soft knee),
  trapezoidal prewarp, a cubic soft clip in the feedback solved in closed
  form each sample, resonance pulled back above resonance 1 at high
  cutoffs, and a tiny injected noise that lets self-oscillation start from
  silence. Input gain about 1.67. **[code]**
- Type II: two nonlinear sections in series with a diode-style shaper in
  each feedback path, two fixed iterations per sample, input gain × 3,
  resonance curve q = 4r/(3r + 1) + 4·max(r − 1, 0)² with a limiter at high
  cutoffs. **[code]** The limiter constants, the per-section scales and the
  slope (Live's manual says 24 dB/oct) are **[open]**; the shaper is
  designed fresh for Segno and fitted to Live's output.
- High-pass: a linear 2-pole state-variable filter, Q about 1.47 (a small
  bump at the corner), 20 Hz..20 kHz, modulated by matrix slots targeting
  HP Frequency at 10 octaves per unit. **[code]**

### Modulation

- Sources 0..7: Env 1, Env 2 / Cyc, LFO, Key, Velocity, Modwheel (one
  value per device), Pressure, Slide (MPE, per voice). **[code]**
  Destinations read them raw, bipolar (velocity centred at 64) or unipolar
  (LFO mapped to 0..1, Key clamped at 0). **[code]**
- Matrix: three slots (source, target, amount −1..1). Targets 0..11: None,
  Osc 1 Gain, Osc 1 Shape, Osc 2 Gain, Osc 2 Detune (±1 octave), Noise Gain,
  LP Frequency, LP Resonance, HP Frequency, LFO Rate (±4 octaves), Cyc Env
  Rate (±4 octaves), Main Volume. Gain targets use
  g = (1 − |a|) + |a| · (u, or 1 − u for negative a), and slots on the same
  gain multiply. **[code]**
- Pitch modulation (two fixed slots): pitch × 2^(source · amount · range);
  range ±4 octaves for Env 1, Env 2 and Velocity, ±2 for LFO, Modwheel,
  Pressure and Slide, 10 octaves per unit of Key (amount 1 tracks the
  keyboard 1:1). **[code]**
- Envelopes 1 and 2: attack rises linearly from the current level to 1;
  decay approaches Sustain and release approaches 0 exponentially; a voice
  ends below 0.001. **[code]** Time → coefficient mapping **[open]**.
  `Envelope2Mode` 1 makes Envelope 2 the cycling envelope. **[inferred]**
- Cycling envelope: a phase per voice; a triangle whose peak moves with
  MidPoint over the middle 60 % of the knob, crossfading over the outer 20 %
  into a fourth-power spike; Hold multiplies it by 1/(1 − 0.95·Hold) and
  clips at 1, flattening the top. Rate by Mode: Hz, ratio to the note,
  time per cycle, or tempo sync. **[code]** for the curve; the Mode order
  **[inferred]**.
- LFO: a phase per voice (Retrigger resets it on a note), increment clamped
  below Nyquist, rate modes as the cycling envelope. Shapes 0..8: Sine,
  Triangle, two saws (rising and falling; which one is "Saw Up" is
  **[open]**), Square, Sample & Hold (two steps per cycle), Wander (smoothed
  random), Linear Env and Exponential Env (one-shot, 0..1). Output × Amount
  × the gain from its own mod source. **[code]**
- Note gain: a pitch-dependent gain from 1 % of the ISO 226 40-phon
  equal-loudness contour, at most about −0.64 dB. Segno computes it from
  the standard. **[code]**

### Voices

- Poly allocation: a repeated note reuses its voice; otherwise the next
  free voice round-robin among the first n; with none free, the oldest is
  stolen. **[code]**
- With ResetOscillatorPhase on, a note on a sounding voice waits for a fast
  fade-out, then starts with reset phases; with it off, the note starts at
  once and the envelope continues from its level. **[code]**
- Modes (0..3): **[code]**
  - Poly: one voice per note. PolyVoiceDepth has no effect.
  - Mono: four voices on one note at 0, −12, −12 and −24 semitones; Thickness
    fades the three lower voices in one after another across the knob's
    thirds; mode gain about −1 dB.
  - Stereo: two voices per note (16 notes at most); Spread's law is
    **[open]**.
  - Unison: four voices per note (8 notes at most), panned −1, −0.5, +0.5,
    +1 and detuned +42, +21, −21, −42 cents at full Strength, both scaled
    linearly by Strength; mode gain about −6.5 dB. The pan law is
    **[open]**.
- Voice counts (0..4) → the voice limit; the table is **[open]** (Live's UI
  offers 8, 12, 16, 24 and 32 as far as known).
- Per-key tuning: notes C1..B5 are blended toward a fixed table of small
  per-key deviations (rms about 4 cents, −5 to +14 cents), with a weight up
  to 1.72; the weight's parameter is most likely DriftDepth **[inferred]**.
  Segno builds its own table with a similar spread; Live's table is not
  copied.
- SerialNumber: a random number per instance, saved in the preset,
  probably the seed for per-instance randomness. **[inferred]**
- Glide (0..2 s), Legato, Pitch Bend Range, Note Pitch Bend and Transpose:
  stored and passed on; their exact use in the voice is **[open]**.

### Open items and the fits (P4)

Settled by rendering Live 12.2.7 (a Live Set built by script, exported
per track, unnormalised, 48 kHz) against Segno's render of the same
patch and notes, one setting changed per render from a plain saw or white
noise. Fitted 2026-11-25, three rounds:

- Envelopes: the stage-time mapping matches (attack 50 / 90 % points,
  sustain, release to -20 / -40 / -60 dB within 5 ms).
- Volume: linear, +6 dB per doubling; with the noise level and both
  filters' path gains, every level test is within 0.2 dB.
- Voice modes: Mono and Unison as described; Unison's pan is equal-power
  (1 on the side it is panned to, 0.707 in the middle). Stereo pans its
  two lanes 0.5 (1 -+ pan) and does not detune: at Drift 0 the pair is
  mono, whatever Spread.
- Filter I: one 12 dB/oct section, damping ratio 1.33 at resonance 0 (a
  soft knee, -8 dB at the cutoff) falling linearly to a +29 dB peak at 1.
  Filter II: two sections, 24 dB/oct, damping per section interpolated
  through the points measured at 0 / 0.5 / 0.75 / 0.9 / 1.
- Filter modulation: 10 octaves per unit (Live and Segno both move 0.99 /
  2.5 octaves at 0.1 / 0.3). Key tracking about A4: within 0.08 octave at
  C2, C4 and C6. High-pass at 300 Hz: within 1.5 dB.
- Drift Depth: a fixed offset per key and lane (it neither moves over time
  nor changes between strikes), linear in depth; a Stereo note's two lanes
  sit at different offsets, which is what makes a Drift preset wide.
  Segno's table is its own, so individual offsets differ from Live's.

Still open, with what showed it (five factory presets, Segno minus Live):
the Saturated oscillator under shape modulation and the LFO's Time mode
and per-voice phase (Clob Bass: 6 to 10 dB dark from 250 Hz to 4 kHz,
narrower); filter II between 0.9 and 1 with a bright source (Bloom Pad:
+8 dB at 2 to 4 kHz); 80s Tape +9 dB near 1 kHz; Chirp Pluck +10 dB at
63 Hz; Glide, the voice-count and Sync tables, LFO shapes 2 and 3, the
voice clip and the phase-offset source.

## Decisions

| Decision | Proposal | State |
| --- | --- | --- |
| Where Drift renders | A new engine module beside `synth_voice.c`, with its own voice pool, behind the same instrument slots, note rings and MIDI routing (SEG-57 Part 2). An instrument is either a Segno patch or a device. | open |
| Mono or stereo | Instrument buses become stereo now, for every instrument (Segno patches fill both channels with the same signal). Drift's Stereo mode and unison spread render as Live does. | owner, 2026-11-24 |
| Preset reader | A pure Dart package (`packages/ableton_preset`): gunzip (`dart:io`), XML (`package:xml`), device kind plus a typed parameter map, and a list of what it could not read. | proposed |
| What a session stores | The parameter values Segno uses, not the `.adv` file, so a session never depends on the preset staying on the drive. | proposed |
| Where presets come from | The user's own copy: a USB drive or a folder copied to Internal. Nothing from Ableton ships in the image. | proposed |
| UI: where presets appear | A separate Ableton section of the Instruments sound library, by device and then Live's folder names, apart from the 19 Segno patches. Needs a Penpot change (pen section 54). | owner, 2026-11-24 |
| UI: editing | Drift's parameters are editable on the console, starting from the loaded preset; an edited sound is saved with the session. Needs a Drift editor screen in Penpot. | owner, 2026-11-24 |
| Order after Drift | Operator, Wavetable, Analog, Meld, Tension, Collision, Electric; Simpler, Sampler and Impulse need the preset's sample files. | proposed |
| CPU | Measured with `bench_instruments` at 96 kHz / 64 frames against the 667 µs period, as SEG-57 Part 1 did. A Drift voice costs more than a Segno patch voice; the voice limit follows the measurement. | proposed |

## Stereo buses and recording

Today an instrument slot is one mono source in the same index space as the
interface's input channels (`LE_INSTRUMENT_SOURCE_BASE + k`,
`le_instrument_source_sample`), and a take is a clean mono take plus the
heard image: the input chain's output in stereo (`LE_HEARD_PLANES`,
`engine_heard.c`). Effect chains are stereo in and stereo out.

Proposed shape for the plan: an instrument bus is a stereo pair; it feeds
its input chain in stereo, so the heard image records Drift's stereo as
played; the clean take records the mono sum. Re-running effects from the
clean take after an edit (SEG-50's replay) then loses the instrument's own
stereo spread, which the plan states as a known limit unless the owner
wants a stereo clean take for instrument lanes (a larger change to the
layer pool, sessions and mixdown).

## Owner's answers (2026-11-24)

1. Stereo instrument buses now.
2. Ableton presets get their own section of the sound library.
3. Drift's parameters are editable on the console.
