# Ableton Live device presets on the pedal — brainstorm

<!-- cspell:words adv adg Ghidra devicekit Lfo Vec analyzeHeadless gpr Wavetable wavetables ADSR BLEP BLAMP wavefolder crossfading prewarp Modwheel detuned unnormalised Clob Sallen linearised transconductance kModBy kCarriers Celesta transconductances Bandpass Bitgrunge Csound Drivetime Extratone Filther Lofi Lowpass Megatripolis Minnaert Sawstyle Starchestra polyBLEP Metalic Formant formants Barney Asym quintic Wurli MKII -->

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
  decimator. **[code]** Measured (round 4): Live 12.2.7's exported renders
  are bit-identical with HiQuality on and off, and match Segno running
  the voices at the host rate (the Saturated oscillator's aliasing, the
  open filters' top octave), not at 2×. Segno runs every voice at the host
  rate and stores HiQuality without effect.
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
  - Shark Tooth: a ramp with a triangular dip. Fitted: the dip spans about
    90 % of the cycle at shape 0 (close to a triangle) and narrows to 16 %
    at shape 1 (close to a saw); no DC at any shape; shape modulation past
    0..1 keeps changing it. Its polarity shows only through the filters'
    asymmetric input clip: Live's is a rising ramp with the dip on top
    (the inverse of the falling form above), which brought Live's Shark
    renders at six shapes within 1.5 dB per sixth-octave band.
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
  ±10, no colouring. **[code]** Fitted: each block of four voices runs
  its generators only while the block runs, and every block starts from
  the same state, so notes struck together in different blocks share
  their noise voice for voice (Stereo, 3 / 4 / 6 notes: +2.1 / +2.9 /
  +4.7 dB over independent voices; Poly from the 5th note). Noise reaches
  either filter 2.4 dB quieter than the bypass, at every level.

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
  silence. Input gain about 1.67. **[code]** Fitted: the two poles give a
  base damping ratio near 1.18 (1.12 fits best) and the resonance
  feedback, r × (1 + 1/3.3), cancels it at resonance 1, so the section is
  a state-variable low-pass with damping 1.12 (1 − r) plus the cubic in
  the resonance path; sixth-octave levels within 1.4 dB rms on Live's
  filter I renders.
- Type II: two nonlinear sections in series with a diode-style shaper in
  each feedback path, two fixed iterations per sample, input gain × 3,
  resonance curve q = 4r/(3r + 1) + 4·max(r − 1, 0)² with a limiter at high
  cutoffs. **[code]** The limiter constants, the per-section scales and the
  slope (Live's manual says 24 dB/oct) are **[open]**; the shaper is
  designed fresh for Segno and fitted to Live's output. A second reading
  (round 4) found each section to be a component-level Sallen-Key model of
  the later MS-20 low-pass: a DC-blocked input (1.6 Hz) drives a first
  integrator through a saturating transconductance z (1 - z^2/4 +
  |z|^3/16); that capacitor's lower plate is the feedback node; a unity
  buffer follows each of the two integrators and hard-clips at about
  -4.99 / +4.81 circuit volts; the second buffer's output, DC-blocked, is
  the section's output and feeds back through a diode curve (slope 2.21 at
  0, a sharp knee near 1, slope 0.62 beyond: a compressor, not a clipper).
  Small-signal Q = 1 / (2 - k), unity DC gain at every resonance. Section
  1's feedback is 0.91351 q, section 2's 0.91351 q (0.5 + 0.2 r); both run
  at 1.02 x the cutoff; the voice signal enters at x 3 x 2.69 circuit
  volts; the two nonlinear elements are linearised at the last estimate
  and the loop solved in closed form, twice per sample. **[code]** Segno
  builds this model itself (its own diode curve, a fitted closed form) and
  fits only its path gain and the noise level.
- Filter input: both types clip their input: linear to about +0.70 and
  -0.98, a soft knee, and a hard edge at +0.79 on the positive side. A sine
  at Gain 1 gets Live's harmonics 2 to 41 within 3 dB (the hard edge gives
  the slowly falling tail); at Gain 0.5 it stays clean. The path around
  the filters is about 1.8 dB louder for the oscillators than for the
  noise. **[fitted]**
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
  clips at 1, flattening the top. Rate by Mode: 0 Hz, 1 time per cycle,
  2 ratio to the note, 3 tempo sync. **[code]**, and fitted (Time 0.5 s
  gives 2 Hz).
- Ratio follows the note's frequency after glide, Transpose and pitch bend,
  not the oscillators' own Transpose. Sync divisions 0..21 run slowest
  first, 8 bars to 1/64; the default is 15 (1/8). **[code]**, fitted.
- LFO: a phase per voice, increment clamped below Nyquist, rate modes as
  the cycling envelope. Retrigger restarts it at the shape's peak (0.25
  for Sine and Triangle, 0.5 for the saws, 0 otherwise); without it a note
  continues the phase the voice's LFO stopped at. **[code]**, fitted.
- An LFO in Ratio mode routed to a pitch slot becomes phase modulation of
  both oscillators (LFO × amount cycles, below one cycle) instead of
  vibrato. **[code]**, fitted (sidebands within 0.1 dB of Live's).
- LFO shapes 0..8: Sine,
  Triangle, two saws (rising and falling; which one is "Saw Up" is
  **[open]**), Square, Sample & Hold (two steps per cycle), Wander (smoothed
  random), Linear Env and Exponential Env (one-shot, 0..1). Output × Amount
  × the gain from its own mod source. **[code]**
- Note gain: a pitch-dependent gain from 1 % of the ISO 226 40-phon
  equal-loudness contour, at most about −0.64 dB. Segno computes it from
  the standard. **[code]**

### Voices

- Poly allocation: a repeated note reuses its voice; otherwise the first
  free (silent) voice round-robin among the first n, starting at the voice
  allocated last, so notes that do not overlap stay on one voice; with
  none free, the oldest is stolen. A same-note reuse does not move the
  search's start. **[code]**, fitted.
- Voices run in blocks of four. While any voice in a block sounds, the
  silent ones keep turning their oscillators at the rate they last had,
  so a Stereo note on a fresh pair starts its lanes together only when
  that pair's block was idle; every silent voice's LFO keeps running.
  **[code]**, fitted on Live's 16-note Stereo sequence.
- With ResetOscillatorPhase on, a note on a sounding voice waits for a fast
  fade-out, then starts with reset phases; with it off, the note starts at
  once and the envelope continues from its level. With it off, a voice
  keeps the oscillator phase its last note left (it does not run while
  silent), so a Stereo note on reused voices starts its lanes apart.
  **[code]**, fitted.
- Modes (0..3): **[code]**
  - Poly: one voice per note. PolyVoiceDepth has no effect.
  - Mono: four voices on one note at 0, −12, −12 and −24 semitones; Thickness
    fades the three lower voices in one after another across the knob's
    thirds; mode gain about −1 dB.
  - Stereo: two voices per note (16 notes at most); Spread's law is
    **[open]**.
  - Unison: four voices per note (8 notes at most), the left side sharp:
    +42 and +21 cents panned −1 and −0.5, −21 and −42 at +0.5 and +1 at
    full Strength (Segno orders the lanes flattest first), both scaled
    linearly by Strength; mode gain about −6.5 dB. The pan law is
    **[open]**.
- Voice counts (0..4): 4, 8, 16, 24 and 32 voices; Stereo plays half as
  many notes, Unison a quarter. **[code]**
- Drift Depth: a fixed tuning offset per key plus one per voice, linear
  in depth. Fitted at Depth 1: the per-key part has an rms near 7 cents,
  the two voices of a Stereo pair sit 11.6 cents apart at every key, and
  voices of other pairs up to about 11 cents away. The same key on the
  same voice always gets the same offset. Segno builds its own values with
  these statistics; Live's table is not copied.
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
- Drift Depth: a fixed offset per key and voice (see Voices), linear in
  depth; a Stereo note's two lanes sit at different offsets, which is
  what makes a Drift preset wide. Segno's values are its own, so
  individual offsets differ from Live's.

Round 2 (rounds 4 to 9 of renders, 2026-11-25) settled: the LFO and
cycling envelope's Mode order, the Sync table, Ratio mode and its phase
modulation, the LFO's restart phases and per-voice phase; Shark Tooth's
width by shape; the filters' input clip and the bypass gain; filter II's
open top octave (the high-cutoff damping applies to strong resonance
only); Glide (time constant 0.117 × Glide, no glide on a fresh Poly
voice); Drift Depth per key and voice; voice reuse and the oscillator
phase a voice keeps. Every level test is within 0.1 dB of Live.

The five factory presets now (Segno minus Live, octave bands relative to
each render's own level): Euphoria Lead, Chirp Pluck and 80s Tape within
about 1 dB everywhere; Clob Bass within 1.5 dB up to 4 kHz (+3 dB at
8 kHz); Bloom Pad within 1.5 dB up to 1 kHz, +4.5 dB at 2 to 4 kHz and
-9 dB above 8 kHz (filter II's resonant peak near 4 kHz).

Round 3 (rounds 10 to 13, 2026-11-25) settled: filter II as MS-20 style
sections, filter I from the code reading, the input clip's hard edge,
voice blocks (idle voices turning, idle LFOs running), the shared block
noise, the voice-count table, and the noise's level into each filter.
The five presets then: Euphoria Lead within 0.4 dB per octave band,
Chirp Pluck within 1.2, Clob Bass within 1.9 (width -10.3 against -8.4
dB side to mid, from -16), 80s Tape within 1 dB up to 2 kHz and -2 dB
above 4 kHz, Bloom Pad within 1 dB up to 1 kHz and +3.3 dB at 2 to 4 kHz.

Then the filter II section split, the Shark Tooth's polarity and widths
through the chain: Chirp Pluck within 0.5 dB per octave band, Bloom Pad
+2.4 dB at 2 to 4 kHz (from +3.3).

Round 4 (2026-11-25): filter II rebuilt as the MS-20 Sallen-Key model of
the second reading, which replaced the fitted MS-20 style loop (filter
renders and presets 1.7 dB rms on average, from 2.0; the resonant peaks
1.3 dB, from 1.5). The five presets: Euphoria Lead, Chirp Pluck and Clob
Bass within about 1 dB per octave band, 80s Tape within 1.2 everywhere,
Bloom Pad within 1.1 dB up to 2 kHz, -1.8 at 4 kHz and -4.7 above 8 kHz.
Unison's lanes match Live's at Drift 0 exactly (detune and pan at every
strength). A filter II voice costs 7 us per period at 96 kHz (filter I
3.2).

Then the voices at the host rate (HiQuality changes nothing in Live's
renders): every filter and oscillator test 0.93 dB rms (from 1.28), the
presets 1.67 (from 1.90); Euphoria Lead's top octave within 0.2 dB.

Still open: Bloom Pad's unison beats dip deeper in Segno (its per-voice
drift values are its own, so beats cannot line up with Live's); a quiet
layer above 10 kHz in Bloom Pad's full phrase, 12 dB above Segno's yet
about 55 dB under its loudness, that no single source shows; Clob Bass's
phrase is about 2 dB narrower; Sample & Hold and Wander draw different
random values, by design.

## Operator: behavior

Learned 2026-11-25 from Live 12.2.7 (four parallel reads: the operators and
FM, the envelopes, the filter and shaper, the LFO, routing and voices), then
measured against 255 Live renders of single-change patches and ten factory
presets. Tags as for Drift; **[measured]** marks what the renders settled
where the reading was silent or disagreed. Segno's implementation is
`operator_voice.c`.

### Structure

- Four operators A..D, each a single-cycle table of 4096 samples read by a
  phase accumulator in table indices; a voice computes D, C, B, A in that
  order each sample, and an operator's input is the sum of its modulators'
  outputs of the same sample. **[code]**
- Lookup truncates unless Interpolation is on (linear). Antialias runs the
  whole operator engine at twice the rate, reads band-limited copies of the
  tables, and decimates with a polyphase allpass half-band. **[code]**
- One mono filter and the shaper per voice, then the voice's gain pair
  (volume and pan) into the stereo sum. With the filter off, the shaper is
  bypassed too. **[code]** **[measured]**
- Parameters apply per 32-sample chunk; the operators, envelopes, filter
  and shaper run every sample (Segno's choice, as for Drift).

### Waveforms

- 0 Sine; 1 and 2 Sine 4 and 8 Bit (the sine truncated to 8 or 128 steps a
  unit); 3..9 Saw 3, 4, 6, 8, 16, 32, 64 (the first N harmonics at 2/(πk));
  10 Saw D (a drawn ramp from +1 to -1); 11..17 Square 3..64 (the first N
  odd harmonics at 4/(πk)); 18 Square D (drawn); 19 Triangle (the first 8
  odd harmonics, alternating, 8/(π²k²)); 20 Noise Looped (a fixed noise
  table repeating at f/64); 21 Noise White (the table stepped one sample per
  output sample, from a random place each note); 22 User. **[code]**
  **[measured: every waveform's harmonics]**
- An additive table is scaled to a peak of 1 and played with its old
  peak as its gain, so its level is the plain sum (Saw 3 peaks at 0.92,
  Square 3 at 1.19, exactly as Live's renders). **[code]** **[measured]**
- User: 16, 32 or 64 drawn harmonics, a slider v giving 10^((48v − 48)/20)
  (−48..0 dB, 0 is silent); expansion modes repeat the drawing across the
  spectrum with a 1/(1 + c(k − 1)) roll-off (c 0.25, 0.5, 1, 3, 4);
  Normalize sets the peak to 1. **[code]**
- Band-limited copies keep 1024, 512 ... 1 harmonics (only those below the
  wave's own top harmonic); the richest copy whose top harmonic times the
  whole part of the phase increment stays under half the table is read.
  **[code]**

### Tuning, phase, level

- Ratio: Coarse (0 is 0.5) × (1 + Fine/1000); velocity adds
  16 × VelCoarse × velocity, rounded when quantized (Live rounds: a ratio of
  4 at velocity 40 with 50 %). **[code]** **[measured]**
- Fixed: Frequency × 0, 0.001, 0.01, 0.1, 1 or 10; it follows Spread's
  detune but not the note, transpose or bend. **[code]** **[measured]**
- Voice pitch: note (or glide) + Spread's detune + Transpose + bend × range,
  in semitones from A4 = 440 Hz. **[code]**
- Phase: Retrigger on starts at Phase % of a cycle; off, at a random phase
  each note. **[code]**
- Level: Volume (linear) × 4((v − 0.5)s + 0.5)² for VelScale s ×
  2^(k(note − 60)/12) for KeyScale k, × the waveform's gain. One sine at
  0 dB with the global Volume at 0 dB peaks at 1.0 per channel at the
  centre. **[code]** **[measured: within 0.1 dB]**

### Algorithms and FM

- The eleven algorithms (Segno's table, `kModBy` and `kCarriers`): 0 a
  four-operator stack D→C→B→A; 1 (C + D)→B→A; 2 C→B, (B + D)→A; 3 D→B and C,
  (B + C)→A; 4 D→C→A and B; 5 D→C→B and A alone; 6 (B + C + D)→A; 7 B→A and
  D→C; 8 D→A, B and C; 9 D→C, with B and A alone; 10 all four alone.
  Carriers are summed, not averaged. **[code]**
- A modulator's output m moves its carrier's phase by −2 cycles per unit
  after a one-pole low-pass set by Tone: 30 × (22000/30)^Tone Hz. **[code]**
  **[measured: the sidebands of every FM render within 0.6 dB]**
- Feedback exists only on operators nothing modulates: −2 × fb × (0.75
  y[n−1] + 0.25 y[n−2]) cycles, fb = Feedback % / 300, without Tone's
  low-pass. On a modulated operator the knob does nothing. **[code]**
  **[measured]**

### Envelopes

- One engine for every envelope (each operator's, the filter's, the pitch
  envelope's, the LFO's): initial level → attack → peak → decay → sustain,
  release from the current value to the end level; times in ms, levels
  linear (pitch levels in semitones, turned into frequency ratios first).
  A minimal attack (0.1 ms) starts at the peak. **[code]**
- Slope 0 is linear; slope 1 a one-pole that comes within 10^−4.2 of its
  target as the time runs out (its rate is ln(|span|/ε) over the
  segment). **[code]** **[measured: within 0.02 at every point]** Every
  other slope (−1, −0.95 .. 0.5 measured) holds the segment's start and
  jumps to its target at the end: that is what Live 12.2.7 renders,
  whatever the reading suggests (a crossfade with a curved shape), so
  Segno does the same. **[measured]**
- Loop modes: Loop (back to the initial level over LoopTime, then attack
  again), Beat and Sync (the attack restarts from the current value every
  RepeatTime, 1/48 to 4 bars; Segno counts both from the note), Trigger
  (note-off ignored, decay runs into release). **[code]**
- Times scale by 2^(−8 TimeVel (vel − 70)/127) per envelope and by
  2^(3 EnvTime − 6 EnvTimeKey (key − 70)/127) for all, attack included
  whatever EnvTimeIncludeAttack says (Live scales the attack either way).
  **[code]** **[measured]**
- A voice ends when every sounding carrier's envelope has ended; a stolen
  voice fades in 1 ms. **[code]**

### LFO and pitch envelope

- Types 0 Sine, 1 Square, 2 Triangle (from −1, rising), 3 Saw Up, 4 Saw
  Down, read as from 512-step tables and smoothed by a one-pole at
  max(16 f, 200 Hz); 5 Sample & Hold (a new value twice a cycle); 6 Noise
  (white noise through a one-octave band-pass at max(f, 5 Hz)). **[code]**
  **[measured: the triangle's start]**
- Rate: a note number, f = 440 × 2^((n − 69)/12), Low 104 semitones below
  High, key scaling about C4; Sync: 1/48 to 4 bars. Retrigger off starts
  each note from one free-running phase. **[code]** **[measured]**
- Amount: 2 Amount² × A%, × 4(0.5 + VelScale (v − 0.5))², × the LFO
  envelope. Destination A multiplies an operator's phase increment by
  (1 + L) (linear pitch) and adds 24 semitones per unit to the cutoff
  through a smoother. **[code]** **[measured: pitch within 0.003]**
- Pitch envelope: its levels in semitones × Amount × A%, as frequency
  ratios, multiply the increments of the operators that take it. **[code]**
  **[measured]**

### Modulation routes **[measured]**

- Each source has a bipolar value s and a unipolar one u = (s + 1)/2:
  velocity s = 2v − 1, the key s = (key − neutral)/63.5 (exact at neutral
  48 and 60), pitch bend its value, the LFO its output, the pitch envelope
  its level / 48 semitones. Aftertouch and the mod wheel have s = u = their
  value, resting at 0.
- An adding destination takes a × s: Filter Freq 48 semitones per unit, Pan
  one unit, Time 3 octaves of envelope time, Fixed Frequency 63 semitones,
  LFO Rate 8 octaves. Aftertouch at rest moves no filter; velocity 64 and
  the neutral key move nothing.
- A gain destination only attenuates, by 1 − a⁺ + a u (a⁺ the amount's
  positive part): the operators' volumes, FM Drive, LFO Amount, Volume and
  Tone (which scales the Tone value). +100 % from aftertouch at rest
  silences, −100 % leaves full level; velocity −50 % gives 0.5 at 127 and
  0.75 at 64; the pitch envelope at 0 semitones gives 0.5, at +24 0.75.
- The LFO's route is scaled by LFO Amount (linear: 0.5 gives half the
  depth) and the pitch envelope's by its Amount; both are silent while
  their LFO or envelope is off. The LFO Amount route scales both of the
  LFO's destinations. The pitch envelope's route output moves linearly in
  semitones, while the pitch it gives moves linearly in frequency ratio.
- Velocity into Coarse, quantized, adds round(16 × amount × v) steps.
- Every route test within 0.2 dB rms of Live.

### Filter and shaper

- Clean (every factory preset but 21): a linear trapezoidal state-variable
  filter, q = 4r/(3r + 1) with resonance clamped at 0.9 (Q 18.5), 24 dB two
  sections (the second at half the resonance); Morph sweeps LP → BP → HP →
  Notch → LP. The cutoff: Frequency × 2^(S/12), S = key and velocity about
  70, the filter envelope × 1.08 × Amount, the LFO and the routes; clamped
  to 30 Hz .. min(0.48 fs, 18.5 kHz). **[code]** **[measured: Live's own
  noise through Segno's Clean filter within 0.5 dB per third-octave]**
- MS2: the section of Drift's filter II (`ms2_section.h`, shared), one for
  12 dB and two for 24, the second at (0.5 + 0.2 r) of the loop gain, the
  signal entering at 0.6 of Drift's level, drive on the input. **[code]**
  **[fit]**
- PRD: Segno's model of a four-stage ladder, each stage's input and output
  through z (1 − z²/4 + |z|³/16) with a small offset of its own, feedback
  0.8 × 4.04 q (the reading says 4.04 q; Live's resonance renders want
  less), the pass band made up by (1 + k), the input at 0.5 × drive; 12 dB
  the second stage, 24 the fourth. **[code]** **[fit]**
- OSR: Segno's model of a state-variable loop with both transconductances
  saturating, damping 2 (1 − q) − 0.01 and a diode across the band node
  (a 0.5 V knee, unit conductance), so it rings at a bounded level from
  resonance 1; the input stage barely saturates. **[code]** **[fit]**
- SMP: MS2's section with SMP's feedback and input constants (no factory
  preset uses it). The MS2 and PRD high-passes are cores of their own, not
  read: Clean's high-pass stands in (three factory presets). **[open]**
- Each circuit's renders within the noise renders' own spread (about 2 dB
  rms per third-octave band, Live's noise table being its own); the drive
  renders within 3 to 5.
- The shaper: (1 − w)x + w 10^(−D/40) T(10^(D/20) x) at twice the rate:
  Soft (linear to −3 dB, then a knee to 1), Hard (0.68 atan 10x), Sine (a
  fold), 4-Bit (a triangle fold quantized to eighths). **[code]**
  **[measured: within 0.5 dB, 4-Bit dry 1.8]**

### Voices

- Voices 1..8, 10, 12, 14, 16, 20, 24, 32 or 48; Spread plays each note
  twice, ∓0.1 × Spread semitones, one voice on each channel at a single
  voice's level. **[code]** **[measured]**
- Stealing: the oldest released note, then sustained, then held; Retrigger
  Mode gives a repeated note its own voice back. With one voice and
  Portamento on, a held voice glides to the new note without retriggering;
  otherwise glide is constant-time and linear in semitones. **[code]**
  **[measured]**
- Pan is equal-power, unity at the centre (√2 cos and √2 sin); key and
  random pan are latched at the note. **[code]** **[measured]**

### The fits so far

Six rounds, 298 single-change renders (third-octave bands within 60 dB of
each render's loudest): waveforms, tuning, FM, feedback, envelopes, LFO,
glide, Spread, pan, Tone and the routes within 0.5 dB rms each, most within
0.2; the filter circuits at the noise renders' spread. Ten factory presets
(octave bands): Sub Sine Bass 0.0, Bells & Thin Pad 0.2, Acid Bass 0.4,
Buzz Release Keys 0.5, Three Op Bass 0.6, Analog Bouquet Brass 1.4, Bells
Brushed Hits 1.6, Metallic FM 2.3, OP Bass 3.1 within 40 dB of its loudest
(+7 dB at 1.3 kHz as its filter LFO opens MS2, 7.5 counting the octave
50 dB down), Celesta 4.2 (its partials match to the hertz; two octaves
around its morph filter differ by 7 to 8 dB). A voice costs 2.7 µs per
period at 48 kHz, 4.5 with Antialias.

## Meld: behavior

Learned 2026-11-25 from Live 12.2.7 (seven reads: the oscillators in three
passes, the filters in two, the modulation, the voices), then measured
against 316 Live renders of single-change patches and 21 factory presets.
Tags as for Drift; **[measured]** marks what the renders settled where the
reading was silent or disagreed, **[Segno]** a table the reading gave only
the shape of, rebuilt by Segno's own rule. Segno's implementation is
`meld_voice.c`, `meld_osc.c` and `meld_filter.c`.

### Structure

- A note takes one voice of 1 to 3 unison copies; each copy runs two
  engines, A and B. An engine is an oscillator, its Amp envelope (applied
  before the filter), a filter, and a tone filter, volume and pan; the
  copy sums both engines, then the voice's drive and limiter. **[code]**
- The device's output is 0.5 x Volume (linear) x the sum of the voices;
  copies sum at 1/sqrt(N). Engine volume is dB, pan constant power (sine
  law, -3 dB a side at centre). **[code]** **[measured]**
- The Mod envelopes, both LFOs and the matrix run once per 16 samples; the
  oscillators, filters and Amp envelopes every sample. Macros and gains
  glide over 5 ms. **[code]**
- Engine B starts (pitch, phase, envelopes) after Engine B Delay, floored to
  16 samples. A voice ends when every Amp envelope is idle and its output
  has stayed at or below 0.0002 for 10 ms. **[code]**

### Oscillators

All 25 types are built. Each takes the frequency and two macros; the FM
types, Noisy Shapes, Squelch, Tarp and Extratone run at min(rate, 44.1 kHz),
Chip at min(rate, 10.05 kHz), all read back through a 4-point Hermite.
**[code]**

- Basic Shapes: sine, triangle, saw, pulse crossfaded by Macro 1; Macro 2
  folds the sine (a sine of a sine, its mean taken out) and the triangle,
  adds a second saw half a cycle along, narrows the pulse to 0.05 %.
  polyBLEP/BLAMP edges. **[code]** **[measured]**
- Dual Basic Shapes: two of the plain shapes, the second up to an octave
  above (2^M2), fading out between rate/8 and rate/4. **[code]**
- Noisy Shapes: two triangle-saw-square oscillators beating up to +-2 Hz,
  each with a high-passed noise burst in its first tenth, locked together
  below Macro 2 = 0.5, then driven into an anti-aliased sine.
- Square Sync: two squares hard-synced to the note, the first 2 kHz M1^2
  above, the second 2 kHz (M1^2 + M2^2). **[code]** **[measured]** (the
  second slave's law)
- Square 5th: a pulse with two notches that morph a square at f into one at
  3f, then 3f into 9f; Macro 2 skews the width and notches. **[code]**
- Sub: a sine an octave down through a biased parabolic clip that holds at
  its peak, a 5 Hz DC blocker, plus a sine two octaves down at 2 M2^2.5.
  **[code]** **[measured]** (the clip's hold)
- Swarm Sine/Triangle/Saw/Square: 2 x 12 voices at the ratios of 9 voicing
  stacks crossfaded by Macro 2, each drifting in pitch by up to 0.13 M1^2 +
  0.002 over 0.32..0.65 s segments, random phases at each note, x 1/sqrt 12.
  **[code]** The stacks follow the reading's counts of unison, octave,
  fifth, fourth and third entries. **[Segno]**
- Harmonic FM: two FM pairs at neighbouring ratios of an 18-entry list,
  crossfaded; the index is M1 cycles, capped so carrier, modulator and
  deviation stay below 0.4 of the rate. **[code]** The list is Segno's
  (simple fractions, unity, the ratios to 2, the integers to 10) and
  matches Live's renders exactly. **[Segno]** **[measured]**
- Fold FM: the Harmonic FM core at position M1^2 and amount 4 M1, through
  tanh at 1 + 7.7 M2, phase-modulating a parabolic sine that is folded at
  1 + 2 M2. **[code]** **[measured]** (the parabolic sine)
- Squelch: an FM bass two octaves down with a self-modulated triangle and a
  triangle 32 times higher as modulators. Simple FM: one sine pair, index
  0.01..4 cycles, ratio 8 M2^2. **[code]**
- Chip: an 8-bit polyBLEP pulse (50 % .. 12.5 %) trilling at 50 M2^2 Hz to
  f 2^(2 M1), a fifth of each step silent, with a hiss 45 dB down. **[code]**
- Shepard's Pi: eight parabolic sines an octave apart gliding at (2 M1 -
  1)^3 cycles of 8 octaves a second under a trapezoid window of 2 + 5.5 M2
  octaves. **[code]**
- Tarp and Extratone: a sine whose pitch and a noise low-pass sweep down
  over a time set by Macro 1 (Tarp, per note) or 100..20 ms restarted at
  f/8 (Extratone), then a biased tanh. **[code]**
- Noise Loop: two refreshing taps, each looping two periods of noise
  low-passed at 2.5 kHz with a click-free pair of read heads, refreshed
  0.12..60 times a second, windowed by Macro 2 from full crossfades to hard
  switches with random levels; a high-pass at f/2. **[code]** Segno
  regenerates each stretch from a seeded hash instead of recording it
  (Live's three 100 ms buffers start full of unfiltered noise, which Segno
  plays until a tap's first refresh). **[measured]**
- Filtered Noise: white noise through a low-pass and a high-pass around
  f 2^(4 M1 - 2), 6 octaves wide down to coincident, then resonant, with a
  level that compensates. **[code]**
- Bitgrunge: the parity of counter bits a..b, a square or a Walsh pattern
  with 1 % glitches, the same on every note. Crackle: Poisson noise bursts,
  20..2000 a second, band-passed around the note, driven and clipped below.
  Rain: eight lanes of Poisson drops into resonant band-passes scattered
  about the note, over pink noise swelling at 0.1 Hz. Bubble: 64 decaying,
  rising sines (Minnaert's pitch for a random radius). **[code]**
- Chord: 8 saws, two chords of up to 4 tones built by scale degree on the
  note's major scale (13 types: triad, seventh, add9, the sixth, sus4 and
  sus2 families, add10, by Macro 1), at two inversions crossfaded equal
  power by Macro 2, x 0.3; a three-tone chord's fourth voice doubles its
  lowest tone two octaves up at 0.8. **[code]** **[measured]** (the fourth
  voice; four-tone chords match Live's renders exactly)
- Use Scale has nothing to quantize to: Segno sends no scale, as Live with
  no clip or Set scale. **[code]**

### Filters

All 17 types are built; 13 match Live's renders within 0.5 dB rms per
third-octave band, the MS2 pair within 2.6 short of full drive. **[measured]**

- SVF 12 and 24: a trapezoidal state-variable filter, resonance m1 clamped
  to 0.9 through q = 4r/(3r + 1), morphing low, band, high and notch by
  Macro 2; 24 dB adds a second stage at damping 2 - q. **[code]**
- Lowpass: one section of the MS-20 model Drift's filter II uses
  (`ms2_section.h`), with the second integrator's transconductance
  saturating like the first's; drive -18..+24 dB in, made up by 18 dB
  falling to 0 at 0.7. **[code]** **[measured]** (1.4 dB rms; full drive 6)
- Highpass: Segno's model of the same parts as a Sallen-Key high-pass: the
  capacitors in series in the signal path, the first transconductance to
  the feedback node, the second to ground, the output fed back through the
  diode curve; the same drive. **[code]** **[measured]** (0.2..2.6 dB rms;
  full drive 7)
- Bandpass: the OSR circuit Operator uses (`osr_section.h`, now shared) at
  its band tap, leaving at 0.55. **[code]** **[measured]**
- DFM: a two-pole Sallen-Key with unequal capacitors and a cubic soft clip
  in its feedback, solved in closed form. Filther: a diode clipper, the SVF
  low-pass, a fixed 6.76 kHz low-pass and a sine saturator. **[code]**
- SRF: the SVF low-pass at twice the rate with its integrators switched by a
  160 Hz .. 41 kHz clock for the share of each period that gives the cutoff.
  **[code]** **[measured]** (1.2 dB rms)
- EqPeak and EqNotch: bells of up to 24 dB with Q 0.4..18 and 2..24 and an
  output trim. Phaser: six all-pass stages at one frequency with negative
  feedback to 0.98 solved without delay. Redux: resampling at the
  Frequency in Hz, 8..1 bits, cubic to held by Lofi. **[code]**
- Vowel: five band-passes A, E, I, O, U; Segno's formants are the published
  bass-voice averages Csound documents (the reading gave the table's shape
  only: four formants, a fifth at 4950 Hz, levels relative to the first, -10
  dB). **[Segno]**
- Comb and Comb Inverted: a feedback delay of c rate/f samples (c = 1, 0.5),
  decaying 60 dB in 0.001 + 15 M1^4 s, with a tilt filter in the loop.
  **[code]** **[measured]** (the loop length)
- Plate and Membrane: 32 band-pass modes x 0.0125, at the plate's grid
  ratios or the membrane's Bessel-zero ratios (computed), decaying in
  0.45 (0.1 + 19.9 M1^3) s. **[code]**

### Envelopes and LFOs

- Each segment ramps x from 0 to 1 over its time and follows (e^(kx) - 1) /
  (e^k - 1), k = -7.5 slope. A note restarts the attack from the initial
  level. Loop modes: None, Trigger (ignores note-off), Loop (the tail, then
  again), AD Loop. The Mod envelope holds its loop through note-off unless
  LegacyEnvLoopBehaviour. Link Envelopes gives engine B engine A's.
  **[code]** **[measured]**
- LFO 1: six generators (Basic Shapes, Ramp, Wander, Alternate, Euclid,
  Pulsate) and two of 19 transformers in series; LFO 2: six plain waves.
  Free rates in Hz, Tempo divisions as Drift's; Retrigger restarts the
  phase. **[code]** **[measured]** (rates, phase offset, shapes)

### Modulation matrix **[measured]**

- 25 targets per engine, 19 sources each. A target takes the sum of amount
  x the bipolar source, and the gain targets (Volume, Amp Sustain, Mod
  Sustain) the product of max(0, 1 + a u - a+). **[code]** **[measured]**
- Sources: the two engines' Amp and Mod envelopes, LFO 1 before and after
  its transformers, LFO 2; velocity (2v - 1 | v), the note ((n - 60)/48 |
  n/120), pitch bend, per-note bend, pressure, slide, the mod wheel, a
  random value per copy, and Spread (the copy's position x Spread).
- Scales, each measured on a render: Detune 1 semitone per unit, Pitch Mod
  48, Pitch Quant 48 rounded to whole semitones, the macros 1, Filter Freq
  10 octaves, Tone and Pan 2 (their knobs' ranges), the times and free LFO
  rates through their knobs' cubic position (a time is 40 s x pos^3, a rate
  78.7 Hz x pos^3), Tempo rates 22 divisions.
- Into Filter Freq the note source is the engine's own pitch, octave
  transpose included, an amount of 1 tracking the key a semitone per
  semitone. **[measured]** Into Tone it scales otherwise. **[open]**

### Voices

- Poly 2, 3, 4, 5, 6, 8 or 12 voices, or Mono; the oldest released voice is
  stolen first, fading over 1 ms. Mono legato moves the voice without
  restarting it, and a note-off returns to the newest key still held.
  Glide: portamento in semitones over Glide Time, Glissando by whole steps,
  from the newest key held. **[code]**
- Spread positions: copies at symmetric positions in [-1, 1]; a single
  copy takes its note's arrival slot among the voice count.
  ResetToVoiceOffset starts the phase at frac(6 x the position), unscaled
  by Spread. **[code]** **[measured]**
- The drive (two tanh stages after up to 18 dB in) and the limiter (4:1
  above -6 dBFS, 10 ms attack, 100 ms release, at the device's level) run
  per copy. **[code]** **[measured]** (where the limiter listens)

### The fits so far

Two rounds, 282 single-change renders (third-octave bands within 60 dB of
each render's loudest): the output chain, levels, pan, tone, drive,
limiter, tuning, unison, envelopes, both LFOs and every matrix target
within 0.1 dB rms; Basic Shapes, Dual Basic, Square 5th, Sub, Harmonic
FM, Squelch, Simple FM, Tarp at its lower macros, Chip and Filtered Noise
within 0.6, Shepard's Pi, Extratone and Bitgrunge within 2; the random
ones (Swarm, Rain, Crackle, Bubble, Noise Loop) at their own spread. 21
factory presets (octave bands): 13 within 1 dB (Carbon String 0.0,
Vertical Bass 0.1, Acid Kick, Key Ups and Drivetime Sine 0.2, Fatal Bass,
Bully Bass, Woozy Bass and Old School Raver 0.3, Plastic Lead and FM Organ
0.4, Detuned String Machine 0.7, Flab 0.9); Starchestra 2.0, Plate Kick
2.3, Happy Chords 2.7, Megatripolis 3.7, Sawstyle 6.3, Granny State 7.5,
Lively Ringer 10.0 (its Bandpass at 20 kHz and Highpass at 940 Hz keep
more of the fundamentals in Live), Sugar Bass 0.0 once the note's tracking
of Filter Freq was measured, Happy Chords 1.9 once the chords' fourth voice
was.

## Analog: behavior

Learned 2026-11-25 from Live 12.2.7's Analog engine (an AAS bundle; one
reader for the device, one for the formant filter, and Tension's reader for
the shared filter's modulation curves), then measured against 178 Live
renders of single-change patches in three rounds and 23 factory presets.
Tags as for Meld. Segno's implementation is `analog_voice.c`.

### Structure

- A note takes one voice of 1, 2 or 4 unison copies. Each copy runs two
  chains; a chain is an oscillator, a filter with its drive, an amplifier,
  an LFO, and a filter and an amp envelope. A noise source feeds both
  filters. **[code]**
- Each oscillator and the noise has a level and a balance: the stored
  balance runs from filter 2 (0) to filter 1 (1) at equal power, so the
  factory presets store oscillator 1 at 1 and oscillator 2 at 0. Filter 1
  can also feed filter 2 (Filter 1 > 2, 2u^2). Amp 1 hears filter 1, amp 2
  filter 2. **[code]** **[measured]** (the balance's direction)
- The device's output is 2u^2 x Volume (no further gain) x the sum of the
  amps; pan is constant power, centred exactly at the stored 0.5.
  **[code]** **[measured]**
- Pitch, cutoffs, levels and the LFOs are recomputed every 32 samples;
  the oscillators, filters and envelopes run every sample, the amp gains
  ramped across each tick. **[Segno]**
- Knob positions follow the engine's 0..127 scale (0.5 is exactly 64).
  The curves: Exp(lo, hi), Lin, Sq (u^2) and, for the filter envelope's
  depth, u^4; a bipolar amount takes its magnitude through the curve and
  then its sign. **[code]**

### Oscillators

- Sine (a quintic of the phase, at 0.7), saw and rectangle (peak to peak
  1, polyBLEP edges, pulse width 3.65 % to 50 %), and noise. **[code]**
  **[measured]** (the sine's level)
- Sub: a square an octave down, Exp(0.01, 1). Sync: a master at the note
  and a slave at Exp(1, 20) times it (the sine does not sync). **[code]**
- Octave, semitone and Detune (+-1/4 octave as a square), a pitch
  envelope of Exp(0.01, 6) octaves falling to 0 over Exp(0.01, 10) s, LFO
  to pitch and to pulse width. Key tracking (Mod 1) at 0.5 is 1.
  **[code]**

### Filters

- LP12/24, BP6/12, Notch 2/4 and HP12/24: bilinear 2-pole sections,
  linear, at Exp(30, 22000) Hz and Q Exp(0.1, 120) (at most 100); the
  4-pole types cascade two, each at sqrt(Q), except BP12, whose stages
  each take the full Q. The band-pass is the band node itself, peaking at
  Q. **[code]** **[measured]** (BP's level, BP12's Q)
- Formant 6 and 12: three band-passes in parallel at a vowel's formants,
  the middle one inverted, each at Q 20 (Formant 6) or 45 (Formant 12) and
  8/sqrt(Q) times its level. The Q knob picks the vowel, 0..9 across its
  positions (plus its modulation at 64 steps an octave); the cutoff knob
  moves all three an octave either way of 270 Hz by its whole steps, and
  the cutoff modulation moves them smoothly. The vowels are Peterson and
  Barney's adult-male averages (i, I, E, ae, a, open o, U, u, ^, the
  r-coloured vowel), with a's F1 at 660 Hz where the renders put it.
  **[code]** **[Segno]** (the vowel table) **[measured]** (a's F1)
- Modulation, in octaves: key and LFO into the cutoff Sq(0, 4), the
  filter envelope 16 u^4, key, LFO and envelope into Q Sq(0, 4) octaves of
  Q. Filter 2 can follow filter 1's modulated cutoff, its own knob then a
  ratio of +-2 octaves. **[code]** **[measured]** (the envelope's u^4)
- Drive after the filter: unchanged up to 1, then bending toward a
  ceiling (Sym 1..3: 8, 4, 2 at gains 1, sqrt 2, 2; Asym with a lower
  positive ceiling). **[code]**

### Envelopes and LFOs

- ADSR with an attack of Exp(5 ms, 15 s), exponential or linear segments,
  velocity on the levels and the attack time. The sustain stage falls from
  S to 0 over Sustain Time (its top holds). Loop 1 runs decay to attack
  while held; loop 2 decay, release, attack; loop 3 waits at 0 after the
  sustain falls, then rises over the attack time at note-off before it
  releases. Legato and Free Run as Live's switches. **[code]**
  **[measured]** (the sustain stage and the loops)
- LFO: sine, triangle (starting at its top, the pulse width setting its
  symmetry), rectangle, sample and hold, and noise (a ramp from one cycle's
  random value to the next), at Exp(3, 1000) cycles a minute or a tempo
  division, with delay, fade-in, phase and retrigger. **[code]**
  **[measured]** (the triangle's start, the noise ramp, the random
  waves' random start)
- Amp: Exp(0.01, 2) times the envelope, LFO and key; key, envelope and
  LFO move the pan. **[code]**

### Voices

- Mono or 2 to 32 voices; the oldest released voice is stolen first,
  fading over 1 ms. Mono follows Keyboard Priority (high, low, last):
  with Low, a higher key waits for the lower one's release, and a
  released key hands the voice to the held key the priority picks.
  **[code]** **[measured]** (the glide renders)
- Glide: a one-pole on the pitch with time constant T / 2 pi, T =
  Exp(3 ms, 9 s), times sqrt of the interval in Prop mode; Legato limits
  it to overlapping notes. **[code]** **[measured]** (T's curve)
- Unison: the copies sit 0, +1, -1, +2 steps from the note, a step 0.374
  semitone at Detune 0.5, taken as Sq(0, 1.47) semitones; they start up to
  20 ms apart. Vibrato: Lin(0.25, 10) Hz, its depth and the mod wheel's up
  to 2 semitones, with delay and fade-in. **[code]** **[measured]** (the
  unison offsets at 0.5)

### The fits so far

Three rounds (third-octave bands within 60 dB of each render's loudest):
the levels, routing, pan, envelopes and loops, LFO waves, glide, filters
(the formants included) and drive within 0.1 to 2.5 dB rms, the totals 1.9,
1.4 and 1.9 dB. 23 factory presets (octave bands): 12 within 2.2 dB
(Square Pure Bass 0.2, Saw Sub Complex Bass 0.3, Fifth Pad 0.8, Saw Detune
Sync Lead 1.0, Noise Hit Perc 1.1, Metalic Lead 1.2, Strings Detuned Pad
1.7, Dual OSC Rubber Bass and Tremolo Tines 1.9, Bright Thin Sweep Pad and
Square Sync Lead 2.0, Nasal Mod Lead 2.2); Saw Pure Brass 3.2, Soft
Morning Keys 3.3, Saw Filter Bass 3.9, Thick Chord Pad 4.3, 80s VCO Brass
4.5, Muted Wow Bass 7.4, E-Piano Muted Pure 7.8, Dual OSC Sample & Hold
Bass 12.6, Kick Complex Perc 26.5, Organ Vibrato 36.8; Zap is silent on
its one note in both.

Still open: the unison detune's law past 0.5 (Organ Vibrato, at Detune 1,
shows no spread in Live), the pitch envelope's shape (Kick Complex Perc),
Organ Vibrato's even harmonics, the unison delay's law, Keyboard Stretch
and Error, and the MPE destinations (stored, not played).

## Electric: behavior

Learned 2026-11-25 from Live 12.2.7's Electric engine (an AAS bundle, one
reader), then measured against 69 Live renders: single-change patches
around a centred reference, and all 17 factory presets, six of them also
two octaves down or up. Tags as for Meld. Segno's implementation is
`electric_voice.c`.

### Structure

- Per voice: a mallet pulse and a damper's noise burst excite a fork of
  four resonators, whose sum goes through a pickup. The voices sum, then
  Volume (2u^2, nothing after it), copied to both channels. **[code]**
  **[measured]** (no further gain)
- The engine moves in 1 ms blocks: a note strikes at the start of the
  block after the one it arrives in. A key struck again while its voice
  still rings fades that voice out across the block, then the fork and
  pickup restart from rest. **[code]**
- Knob positions follow the engine's 0..127 scale, as in Analog.
  **[code]**

### Mallet

- Four one-pole stages, all the strike's energy put in at once: two at
  the cutoff S 2^(k_key K - k_vel v), two 27 times higher. S =
  Exp(10, 7593) Hz; the key and velocity amounts (4^(m/64) - 1)/3, so 1 at
  the centre; velocity lowers the cutoff. **[code]**
- The strike's size: Force (m/128 + 1/64) times 2^(2 (g_k P + g_v v)),
  g_k = Lin(-0.5, 0.9) per octave of pitch, g_v = Lin(0, 3.5) per unit of
  velocity. **[code]** (the 2 is the patch's fixed value)

### Fork

- Four constant-Q band-passes, reset at each strike: the tone bar at the
  note (261.62 Hz at C4), the tine at 7.349 times the note, its partial
  2.8169 times the tine, and the "mallet noise" at 367.31 Hz 2^N, which
  does not follow the key. Their decay rates scale with the pitch.
  **[code]** **[measured]** (the tine's ratio)
- Levels and decays: Tone Bar Volume 10^(0.0109375 m - 1.1), Tine and
  Noise 10^(0.021875 m - 2.5); the decays as halvings per second,
  1024 e^(-(m/2 + 64)/14) for the tone bar, e^(-(m/2 + 32)/14) for the
  tines (the partial at 0.7 of it), e^(-m/28) for the noise.
  **[code]**
- Tine Color is the tines' key exponent (m/32 - 1, 1 at the centre: no
  key scaling) and Tine < Key their balance (cos and sin of a quarter
  turn), the other way round from the controls' names. **[measured]**
- Releasing the key switches the three tuned resonators to decay rates of
  52.8, 38.3 and 26.8 per second over Release Time R = 2 x
  10^(0.01171875 m - 1), at the pitch's scale, raising their tuning so
  the damped ring stays at pitch. **[code]**

### Damper and pickup

- The damper fires at the strike and at the key's release, split between
  them by Balance: a two-stage envelope at the Damper Tone (Exp(4, 3490)
  Hz, following the key) over low-passed noise, into the fork only.
  **[code]**
- The pickup, latched at the strike. R (electromagnetic): the motion,
  through a leaky integrator, sets a point on a softly saturating flux
  profile; the output is the derivative of motion times flux. W
  (electrostatic): the derivative of the motion times a profile peaking
  near the rest point. Symmetry offsets the rest point (even harmonics),
  Distance scales it; Amp In, Amp Out and Amp < Key set the levels.
  **[code]**

### Voices

- 2 to 32 voices (Voices + 2); the oldest released voice is stolen first,
  fading over 1 ms. A released voice ends after 10 ms below -100 dBFS.
  Semitone and Detune shift the key by (S + D)/12 - 1.0417 octaves;
  Keyboard Stretch only offsets every note by up to 7 cents (its scaling
  input is unconnected in Live). **[code]** **[Segno]** (the voice end)

### The fits so far

69 renders (third-octave bands within 60 dB of each render's loudest,
from the strike): total 1.09 dB rms; the reference at 0.5, every single
change within 1.6 dB but six. The factory presets (octave bands): 19 of
23 renders within 1.0 dB, twelve within 0.2 (E-Piano MKII Old, Short
Sharp, Short Soft, Organ Soft, Wurli Classic, Wurli Short at 0.0); Vibes
Soft 1.4 to 3.9 across its three octaves.

Still open: at full Force < Velocity (20.4 dB) and full Tone Bar Volume
(8.3 dB) Live's output carries more above 10 kHz in the first 0.3 s;
Stiffness at 0 (5.9 dB); Live strikes about 16 samples later in its
block than Segno.

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
