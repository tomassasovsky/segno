# Ableton Live device presets on the pedal — brainstorm

<!-- cspell:words adv adg Ghidra devicekit Lfo Vec analyzeHeadless gpr Wavetable wavetables ADSR BLEP BLAMP wavefolder crossfading prewarp Modwheel detuned unnormalised Clob Sallen linearised transconductance kModBy kCarriers Celesta transconductances Bandpass Bitgrunge Csound Drivetime Extratone Filther Lofi Lowpass Megatripolis Minnaert Sawstyle Starchestra Quantizer autocorrelation tfz unmeasured retriggered isolations pul meldfit -->

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
    90 % of the cycle at shape 0 (close to a triangle) and narrows to 6 %
    at shape 1 (close to a saw); no DC at any shape; shape modulation past
    0..1 keeps changing it. **[measured]** Live plays it backwards in time:
    at shape 1 a falling ramp that rises back fast. Static renders cannot
    tell the direction (the spectrum is the same); Live's waveform under an
    LFO sweeping the shape from -1 to 1 can: each period matches Segno's
    with correlation 0.99 up to shape 0.5, and -1 the other way round. The
    widths at 0.75 and 1 (0.24, 0.06) are fitted on that sweep and on the
    static renders, which both improved (sixth-octave levels within 0.4
    dB rms).
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
  fits only its path gain and the noise level. **[measured]** The diode's
  slope at 0 sets the small-signal resonance: at 2.21 (the reading's
  value; Segno had 2.19) the resonant peaks on noise sit within 0.3 dB of
  Live's from resonance 0.5 to 1. A voice's filter II starts from the
  state its offsets settle to with no input, not from zero: from zero the
  offsets step through the output coupling, a -43 dB transient that Live's
  notes do not have (it moved the onset of every filter II render).
- Path gains **[measured]**: a sine and a saw at every gain through filter
  I within 0.1 dB and through filter II within 0.05 dB of Live's after
  the output gains 2.90 and 3.69 (they were 0.15 and 0.37 dB high); noise
  reaches filter I 2.2 dB and filter II 2.0 dB quieter than the bypass.
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
  continues the phase the voice's LFO stopped at. **[code]**, fitted. The
  voice blocks reset at the first chunk and at a voice-mode change, every
  voice's LFO to its shape's start phase **[code]**, and idle blocks run
  only their LFOs; a voice never played runs a Ratio-mode LFO at Ratio x
  A4 **[measured]**. Live's renders start about 5126 samples (0.107 s)
  after that reset: a free LFO's phase at the first note fits that at 2
  and 0.63 Hz and in Ratio mode at 2.375 **[measured]**. The scratch
  harness renders that time before the notes; it is a property of how
  Live's renders were made, not of the device.
- An LFO in Ratio mode routed to a pitch slot becomes phase modulation of
  both oscillators (LFO × amount cycles, below one cycle) instead of
  vibrato. **[code]**, fitted (sidebands within 0.1 dB of Live's).
- LFO shapes 0..8: Sine,
  Triangle, two saws (rising and falling; which one is "Saw Up" is
  **[open]**), Square, Sample & Hold (two steps per cycle), Wander (smoothed
  random), Linear Env and Exponential Env (one-shot, 0..1). Output × Amount
  × the gain from its own mod source. **[code]** Sample & Hold and Wander
  share one draw per half cycle (Wander glides from the last draw to it
  along a quadratic S-curve, 2q² then 1 - 2(1 - q)²), and a restart or a
  block reset draws a value at once, so a retriggered Sample & Hold starts
  on a random step, not on 0. **[code]**
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
  once and the envelope continues from its level. **[code]** Measured: the
  fade-out is exponential, from full level to -60 dB in 1 ms (0.866 per
  sample at 48 kHz), the waiting note then starts from silence (a new
  attack, phases at 0), and a legato note in Mono waits the same way, its
  glide running on; Live's legato and Reset renders match within 0.1 dB
  per sample after this. With it off, a voice
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
- Glide: a one-pole in hertz (not in pitch) with time constant 0.144 x
  Glide **[measured]**: on Live's octave glides at 0.5, 1 and 2 s the
  distance to the new note in hertz falls by the same ratio every 50 ms,
  while in cents it slows down. Legato, Pitch Bend Range, Note Pitch Bend
  and Transpose: stored and passed on; their exact use in the voice is
  **[open]**.

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

Round 5 (2026-11-25), against the strict score (third-octave x 50 ms
cells, a 150 ms attack window, side/mid per band, median pitch; see
SEG-109): the free LFO's start phase, the Reset Oscillator Phase restart,
glide in hertz, filter II at rest and its diode slope, the filter path
gains, Sample & Hold's first draw, and Shark Tooth's direction and top
widths, each above. 164 of 224 fit renders passed before, factory presets
0 of 5; after, with the scorer's round 2 (three seeds, Live's own spread,
the renders named `-r<n>` set aside as repeats), 171 of 200, presets 1 of
5 (Euphoria Lead). Glide, Mono legato, the free-LFO, Ratio-LFO, Clob
isolations and filter II noise renders now pass.

What the strict score still fails, and why **[measured]**:
- Drift Depth. Live's tuning is a fixed 60-key table blended by depth plus
  an offset per voice (voice 0 +2.5 cents per unit of w = depth / 0.58);
  Segno's values are its own by rule, so pitch differs by a few cents per
  note, and pairs or unison lanes beat at other rates. Swapping Live's
  table and voice 0's offset in for a scratch check (not kept) made the
  drift renders pass with pitch errors of 0.02 to 0.04 cents. This covers
  every remaining failure with Drift Depth above 0: 80s Tape (pitch,
  stereo), Clob Bass (stereo), Bloom Pad and its isolations (unison
  beating and the level of lanes that land on one pitch in Live), the
  drift, alloc, idle-stereo and unison-drift renders.
- Random sources. Live's noise, Sample & Hold and Wander differ on every
  render (two Live noise renders of one patch correlate 0.007). The
  Sample & Hold and Wander renders and Chirp Pluck's pitch (its Sample &
  Hold moves pitch by up to 8 cents) cannot match draw for draw; Live
  copies (`-r2`, `-r3`) settle how far Live is from itself.
- Bloom Pad's filter II peak sits 37 cents below Live's with its key
  tracking and Env 2 modulation; the same filter without them is within 5
  cents. Which of the two differs needs the renders requested for round 16.

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
  table repeating at f/64); 21 Noise White; 22 User. **[code]**
  **[measured: every waveform's harmonics]** Noise White is a fresh
  uniform random value every engine sample: Live's never repeats (its
  autocorrelation stays under 0.02 at every lag to 32768), so a stepped
  4096-sample table, which repeats 12 times a second, is not it.
  **[measured]**
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
  A minimal attack (0.1 ms) starts at the peak. **[code]** An operator's
  or the LFO's level at its −70 dB floor (0.000316) is silence: an attack
  from the floor starts at 0 and a release to it ends at 0. **[measured:
  the EnvTime renders, 3·10⁻⁴ below Segno's old start; the onset within
  0.02 ms]**
- Slope 0 is linear; slope 1 a one-pole that comes within 10^−4.2 of its
  target as the time runs out (its rate is ln(|span|/ε) over the
  segment). **[code]** **[measured: within 0.02 at every point]** The
  span is measured in the envelope's scaled output: an operator's
  envelope runs on its level times the operator's amplitude (Volume,
  velocity and key scaling), so a quiet operator's one-pole is slower
  (Buzz Release Keys: a 4.5 s release at 0.1 volume, 8 dB apart after two
  seconds without it). The pitch envelope's runs on its frequency ratios
  (a 12-semitone fall spans a ratio of 1, not 12). **[code]**
  **[measured]**
- Every other slope (−1, −0.95 .. 0.5 measured) holds the segment's start
  and jumps to its target at the end on an operator's envelope: that is
  what Live 12.2.7 renders, whatever the reading suggests, so Segno does
  the same; the LFO's envelope does the same (Segno's choice, unmeasured).
  **[measured]** The filter and pitch envelopes follow the reading's
  curve: (1 − |s|) of the straight line plus |s| of an exponential shape
  reaching 10^−3.95, fast first for s > 0. **[code]** **[measured:
  Analog Bouquet Brass, whose filter attack at slope 0.48 is 20 dB off
  with hold-and-jump and within 3 with the curve]**
- Loop modes: Loop (back to the initial level over LoopTime, then attack
  again), Beat and Sync (the attack restarts from the current value every
  RepeatTime, 1/48 to 4 bars; Segno counts both from the note), Trigger
  (note-off ignored, decay runs into release). **[code]** Bells Brushed
  Hits, whose modulator C loops in Sync at 1/16, shows no retrigger in
  Live's render at all. **[open]** (round 7 isolates it)
- Times scale by 2^(−8 TimeVel (vel − 70)/127) per envelope and by
  2^(3 EnvTime − 6 EnvTimeKey (key − 70)/127) for all, attack included
  whatever EnvTimeIncludeAttack says (Live scales the attack either way).
  **[code]** **[measured]**
- A voice ends when every sounding carrier's envelope has ended; a stolen
  voice fades in 1 ms. **[code]**

### LFO and pitch envelope

- Types 0 Sine, 1 Square, 2 Triangle (from −1, rising), 3 Saw Up, 4 Saw
  Down, continuous (Live's slow LFOs rise smoothly, without the 512 steps
  the reading's table suggested: 5 cents at rate 2) and smoothed by a
  one-pole at max(16 f, 200 Hz); 5 Sample & Hold (a new value twice a
  cycle); 6 Noise (white noise through a one-octave band-pass at max(f,
  5 Hz)). **[code]** **[measured: the triangle's start, the smooth
  shapes]**
- Rate: a note number, f = 440 × 2^((n − 69)/12), Low 104 semitones below
  High, key scaling about C4; Sync: 1/48 to 4 bars. Retrigger off starts
  each note from one free-running phase. **[code]** **[measured]** In
  Live's renders that phase counts from the export's start (the fit
  harness sets it so); Bells Brushed Hits' first chord sits 0.39 of a
  cycle away from it while its later notes do not. **[open]**
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
  one unit, Time 3 octaves of envelope time, Fixed Frequency 63 semitones.
  Aftertouch at rest moves no filter and no envelope time (Buzz Release
  Keys, mod wheel +100 % on Time); velocity 64 and the neutral key move
  nothing.
- LFO Rate, 8 octaves per unit, takes the gain sum a u − a⁺ of its MIDI
  routes (aftertouch at rest with +20 % slows OP Bass's LFO 1.6 octaves,
  from 1.3 to 0.43 Hz), and the LFO's own route adding (a × s).
  **[measured]**
- A gain destination only attenuates, by 1 − a⁺ + a u (a⁺ the amount's
  positive part): the operators' volumes, FM Drive, LFO Amount, the
  filter envelope's amount (velocity +50 % leaves it whole at 127), Volume
  and Tone (which scales the Tone value). +100 % from aftertouch at rest
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
  12 dB and two for 24, the second at (0.4 + 0.2 r) of the loop gain, the
  signal entering at 0.6 of Drift's level, drive on the input. **[code]**
  **[fit]** Its high-pass (and SMP's) falls 12 dB an octave just below the
  cutoff and 6 below c × cutoff: a linear state-variable section's high
  output plus c × its band output, c 0.43 (SMP 0.49), damped by
  2 (1 − feedback × q). **[fit: the HP renders, third-octave bands within
  1.6 to 1.9 dB of that shape]**
- PRD: Segno's model of a four-stage ladder, each stage's input and output
  through z (1 − z²/4 + |z|³/16) with a small offset of its own, feedback
  0.8 × 4.04 q (the reading says 4.04 q; Live's resonance renders want
  less, and below self-oscillation 10 % × (1 − q) more), the pass band
  made up by (1 + k), the input at 0.5 × drive; 12 dB the second stage, 24
  the fourth. **[code]** **[fit]**
- OSR: Segno's model of a state-variable loop with both transconductances
  saturating, damping 2 (1 − q) − 0.01 and a diode across the band node
  (a 0.5 V knee, unit conductance), so it rings at a bounded level from
  resonance 1; the input stage barely saturates. **[code]** **[fit]**
- SMP: MS2's section with SMP's input constant and a feedback of 0.85 per
  unit of q (the reading's 0.904 rings 1 to 2 dB too loud at resonance 0.5
  to 1) (no factory preset uses it). **[fit]** PRD's high-pass is a core
  of its own, not read: Clean's high-pass stands in; Live's has a peak at
  1.25 kHz for a 1 kHz cutoff and 6 dB more below 300 Hz. **[open]**
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
  voice's level, Spread in whole percent (0.5 % plays one voice, 1 % two).
  **[code]** **[measured]**
- Stealing: the oldest released note, then sustained, then held; Retrigger
  Mode gives a repeated note its own voice back. With one voice and
  Portamento on, a held voice glides to the new note without retriggering;
  otherwise glide is constant-time and linear in semitones, from the last
  note while a voice sounds, but not for a note that takes a sounding
  voice's place (it waits for that voice in Live): OP Bass's mono notes
  start at their own pitch over the release of the last. **[code]**
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
50 dB down), Celesta 4.2 (its partials match to the hertz). A voice costs
2.7 µs per period at 48 kHz, 4.5 with Antialias.

The strict score (third-octave × 50 ms cells, the first 150 ms in 5 ms
cells, stereo, pitch, level and onset, against Segno's own spread between
two noise seeds) passed 248 of the 298 renders and 4 of the 10 presets
before these fits, and passes 277 and 6 after them (OP Bass and Buzz
Release Keys added). What is left:

- Randomness the score cannot match. Celesta, Bells Brushed Hits and
  Metallic FM use random pan: Live's per-note pans (measured from its
  renders) are a different draw from Segno's, and with Live's pans forced
  Celesta passes over time (0.99 dB) and in its attack. Bells' free LFO
  starts its first chord 0.39 of a cycle away from the export clock, its
  later notes on it (with both forced, its attack passes). Analog Bouquet
  Brass and Metallic FM start operators at random phases; the S&H and
  noise LFO renders draw random pitches. Live's random pan does not repeat
  from one Operator to the next (Celesta's and Bells' first draws differ).
- Chaotic or table-bound sources: full feedback (fb-d-100) and Noise
  Looped (Live's table is its own) match in their statistics (tfz 1.0)
  but not cell by cell.
- Analog Bouquet Brass plays 0.9 dB louder than Live throughout and 3 dB
  in its first 40 ms; round 7 takes it apart.
- The circuits' drive renders (MS2 and SMP drive the shared MS-20 section
  into its clipping: Live's spectra notch individual harmonics Segno does
  not), PRD's high-pass and 24 dB slope, and the first 150 ms of MS2 at
  resonance 0.5.

Round 7 (52 renders, `segno-op-fit7`) isolates the curved slopes of the
filter, pitch and LFO envelopes, the one-pole spans, Sync on a
modulator, the free LFO phase, whether random pan repeats, the four
random presets taken apart, the circuits' high-passes, controller routes
at rest and glide into a releasing voice.


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
  1 + 2 M2. **[code]** **[measured]** (the parabolic sine) Its modulator
  list is its own: the equal-tempered intervals 2, 3, 5, 7, 11, 12, 15
  and 19 semitones, M1^2 crossing them evenly (position 7 M1^2) with
  neighbours crossfaded. **[measured]** (round 8's fold128-000..127, Macro
  1 at each of its 128 steps, scratchpad `meldfit/meas/fold_law.py`: with
  this law every step's lines sit within 0.05 to 1.1 dB, mean, of Live's,
  and the best crossfade at each step is the law's within 0.05)
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
  f/8 (Extratone), then a biased tanh. **[code]** Tarp's sweep takes its
  time and curve from the note's own macros, not the last note's.
  **[measured]** (every Tarp render within the strict score)
- Noise Loop: two refreshing taps, each looping two periods of noise
  low-passed at 2.5 kHz with a click-free pair of read heads, refreshed
  0.12..60 times a second, windowed by Macro 2 from full crossfades to hard
  switches with random levels; a high-pass at f/2. **[code]** Segno
  regenerates each stretch from a seeded hash instead of recording it
  (Live's three 100 ms buffers start full of unfiltered noise, which Segno
  plays until a tap's first refresh). **[measured]**
- The Filther's DC blocker starts settled on its saturator's bias, so a
  note through it rises from silence (woozy-a: Live's Square 5th through
  the Filther rises over its attack; unsettled, the blocker stepped to
  0.08 at the first sample). **[measured]**
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
  lowest tone an octave up, at the others' level. **[code]** **[measured]**
  (the fourth voice, from each line of the triad renders as the saws'
  harmonics sum: at inversion 0 C4, C5 and C6 at -29, -26 and -32 dB as
  in Live, and halfway to inversion 1 E4 cancels, E3's second harmonic
  against the doubled E4, -64 dB in Live; scratchpad
  `meldfit/meas/chord_lines.py`) A note's tones start in phase at the
  note's own frequencies and macros, so a tone both chords share sums at
  full level. **[measured]**
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
  its band tap, leaving at 0.55. **[code]** **[measured]** Its drive runs
  from 5.3 to 19.3 dB in: at Drive 0 Live's renders sit 5.3 dB above a
  0..24 dB law in every band, at full drive a 24 dB range is 5 dB loud.
  **[measured]** Short of the ends its band shape is still 2..4 dB off.
  **[open]**
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
  0.45 (0.1 + 19.9 M1^3) s. **[code]** The membrane's are the lowest 32
  zeros of J_0 to J_8: Live's render rings at J_4's fourth zero (7.325 x)
  and not at J_9's or J_10's first. **[measured]**

### Envelopes and LFOs

- Each segment ramps x from 0 to 1 over its time and follows (e^(kx) - 1) /
  (e^k - 1), k = -7.5 slope. A note restarts the attack from the initial
  level. Loop modes: None, Trigger (ignores note-off), Loop (the tail, then
  again), AD Loop. The Mod envelope holds its loop through note-off unless
  LegacyEnvLoopBehaviour. Link Envelopes gives engine B engine A's.
  **[code]** **[measured]**
- Linked, engine B's envelopes take engine A's times and sustains as the
  matrix moves them (Vertical Bass: B's release follows A's
  velocity-stretched one). **[measured]**
- The Mod envelope runs once per tick and the matrix reads its value from
  the tick before, 0 at a note's first tick; each segment ends a step
  early. Plate Kick's 48-semitone pitch drop crosses zero where Live's
  does to 0.1 ms, and an AD Loop of 0.1 + 0.2 s repeats every 0.29933 s,
  as Live's does. **[measured]**
- LFO 1: six generators (Basic Shapes, Ramp, Wander, Alternate, Euclid,
  Pulsate) and two of 19 transformers in series; LFO 2: six plain waves.
  Their random draws restart with the phase, the same on every note and
  in every instance: Pulsate's heights and the rolls its chances are
  compared with, per quarter cycle (120 quarters), Wander's targets (30
  cycles) and S&H's steps (60 cycles) are tables measured from Live's
  renders, read as pitch (round 8: pul-c100/080/050/020, wander-step,
  sh-8hz with sh-2hz the same; scratchpad `meldfit/meas/lfo_tables.py`).
  **[measured]** A roll is the middle of the bracket its four chances
  leave, a sequence past its measured length starts over, and the Wander
  walk steps by its target's sign. **[Segno]** Free rates in Hz, Tempo divisions as Drift's; Retrigger restarts the
  phase. **[code]** **[measured]** (rates, phase offset, shapes) The
  Quantizer rounds to steps of 1/(n - 1), symmetric about 0 (at 0.8 it
  plays 0, +-0.5 and +-1). **[measured]**

### Modulation matrix **[measured]**

- 25 targets per engine, 19 sources each. A target takes the sum of amount
  x the bipolar source, and the gain targets (Volume, Amp Sustain, Mod
  Sustain) the product of max(0, 1 + a u - a+). **[code]** **[measured]**
- Sources: the two engines' Amp and Mod envelopes, LFO 1 before and after
  its transformers, LFO 2; velocity (2v - 1 | v), the note ((n - 60)/12 |
  n/120), pitch bend, per-note bend, pressure, slide, the mod wheel, a
  random value per copy, and Spread (the copy's position x Spread).
  **[code]** (the note's octaves from C3)
- Scales, each measured on a render: Detune 1 semitone per unit, Pitch Mod
  48, Pitch Quant 48 rounded to whole semitones, the macros 1, Filter Freq
  10 octaves, Tone and Pan 2 (their knobs' ranges), the times and free LFO
  rates through their knobs' position (a time is 40 s x pos^4, a rate
  79.5 Hz x pos^3.036: +0.1 at 2 Hz is 2.4122 times, -0.1 0.2879 times),
  Tempo rates 22 divisions. The times' law is measured on the Amp
  Release: velocity at 0.109 into 0.05 s gives 0.12 and 0.26 s at 90 and
  120 in Live (pos^4 0.119 and 0.265, a cube 0.144 and 0.345), 0.25 into
  1 s at 127 7.2 s (pos^4 7.04, a cube 6.38); the Attack and Decay renders
  at 0.5 s + 0.25 ramp 4 % slower than a cube's, as pos^4 does.
- The engines' output gains (volume, the Volume target, pan) follow the
  matrix through a one-pole of 4.8 ms. **[measured]** (Detuned String
  Machine's LFO 1, gated into Volume: strict tf 2.51 dB with a 16-sample
  ramp, 0.17 with 4.8 ms, 1.0 at 2.7 ms, 0.6 at 6.3 ms)
- The semitone targets track the key a semitone per semitone at an amount
  of 1: Detune reads the note source as it is, Pitch Mod and Pitch Quant a
  quarter of it (the C6 render). Into Filter Freq the note source is the
  engine's own pitch, octave transpose included, tracking the same way.
  Into Tone it is the plain source: 0.5 of it at C1 is Tone -1, Live's
  render to the sample. **[measured]**

### Voices

- Poly 2, 3, 4, 5, 6, 8 or 12 voices, or Mono; the oldest released voice is
  stolen first, fading over 1 ms. Mono legato moves the voice without
  restarting it, and a note-off returns to the newest key still held.
  **[code]**
- Stealing counts every voice not free, fading ones too, and never steals
  one already fading: the new note starts when its victim's fade is over,
  and without a victim it is dropped. So in Mono without legato a three-key
  chord plays its second key, or its first when the key before still
  rings in its release; Mono legato restarts a voice still ringing after
  its key was let go in place, without a fade, its envelopes' attacks
  starting from where the envelopes are. **[code]** **[measured]** (the
  Mod envelope: mono-leg-after-rel's filter sweep starts from the
  released level, Live's to the hertz; the Amp envelope alike **[Segno]**)
  (the held-out round: Fatal Bass plays C4, Acid Kick, Bassic and Happy
  Chords E4)
  Glide: portamento in semitones over Glide Time, Glissando by whole steps,
  from the newest key held. **[code]**
- Mono plays one voice: a note that steals it takes over its LFOs, so an
  LFO that does not retrigger runs on from the note before. **[measured]**
  (the training phrase: Death Kicks, LFO 2 into Pan, passes with it,
  stereo 5.7 dB without; Chords R Us tf 5.83 to 2.65, its held-out phrase
  9.2 to 2.9) A Poly note on a voice that never played starts its free
  LFO at phase 0 (Detuned String Machine's training phrase: tf 1.12 dB
  that way, 2.33 with the LFO running since the device was built).
  **[measured]** Round 10 asks whether a free LFO runs on while no voice
  sounds.
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

The strict score (third-octave x 50 ms cells, the first 150 ms in 5 ms
frames, side/mid per band, pitch, level, onset; scored against Segno's own
second seed where a render is random) passes 261 of 339 renders and 10 of
21 presets, from 245 and 8. What moved them: linked envelopes carrying the
matrix (Vertical Bass, Drivetime Sine), Chord's tones starting in phase
(Happy Chords, M2 0.5), the Mod envelope's timing (Acid Kick's attack 1.9
to 0.3 dB, the AD Loop), the Note source into Tone, the free rate curve,
the symmetric Quantizer, Tarp's sweep and the membrane's modes (Plate
Kick's attack 5.7 to 2.1 dB). What is left is mostly random: Live's
Pulsate, Swarm, Rand and S&H draws cannot be matched sample by sample, and
six presets (Detuned String Machine, Flab, Lively Ringer, Megatripolis,
Sawstyle, Starchestra) fail the over-time check against Segno's own second
seed as well. Granny State turns on LFO 1's first Pulsate draw: Live's
burst is far brighter than any of eight Segno seeds give. Open, each with
a Live render requested: Fold FM's ratios, the Chord crossfade's signs,
Spread's pan in Mono (Woozy Bass's side 1.7 dB high), the membrane's
damping, Pulsate's heights.

A fourth round settled the Bandpass's drive ends, showed that Spread's pan
and Square 5th's Macro 2 match on their own (Woozy Bass's extra side comes
from elsewhere), and that a retriggered LFO 1 draws the same values on
every note: Live's Pulsate plays +0.97, -0.49, -0.12, -0.24 at the starts
of each note's cycles, every note alike, and a second instance plays the
same; Detuned String Machine (Pulsate and LFO 2's S&H) renders identically
in three instances. **[measured]** The per-copy Random source and the
Swarm's phases and drift differ from instance to instance in Live too.
The held-out round (84 presets, three phrases each) found the voice
stealing above. With the random sources now read through LE_SEED (a
scratch seed patch), the strict score passes 16 of 21 factory presets.

The owner allowed values measured from Live's renders (2026-11-25), and
rounds 7 and 8 measured them: Pulsate's, Wander's and S&H's sequences and
Fold FM's interval list (above), the times' fourth-power law and the Mod
envelope's legato restart. Pulsate into pitch, LFO 2's S&H and the
retriggered LFOs now play Live's values to the sample in pitch
(pul-c100, sh-8hz), and with the triad's octave doubling, the 4.8 ms
gain smoothing and these, the strict score passes 484 of 559 fit renders
(from 333 with the same rounds) and 13 of 21 presets: every Fold FM step
(128 renders, tf 1.6 to 12.9 dB down to 0.3 at most), the chord crossfades,
the velocity-stretched releases (Vertical Bass's case), the legato
restart, Detuned String Machine (tf 2.51 to 0.17); Happy Chords drops out
on level alone (0.54 dB, every band alike, with tf 1.24 to 0.82). The
held-out round stays at 13 of 84 (Vertical Bass passes, Glitter's stereo
goes 0.85 to 1.25), its tf mean 5.07 to 4.53 dB. Open, with round 9
requested: whether Bitgrunge's glitches repeat on every note (Live's come
at about 1.2 % of the counts, Segno's 0.7 %), the Swarm's lanes resolved
on C6 at three Macro 1 values in three instances (Plastic Lead's Swarm
level varies 5 dB across Segno's seeds against 1.4 in Live), Vertical
Bass's A5 sidebands at +-360, 520 and 720 Hz, Woozy Bass's 1.7 dB of
extra side, and Happy Chords' and Chords R Us's engines alone (both
0.5 to 0.7 dB loud in Segno at every band).

Round 9 answered: Bitgrunge's glitches are the same on every note and in
every instance, at the same counts at C3 and C4 (161 in 3 s at Macro 2 1,
1.28 % of the counts; scratchpad `meldfit/meas/grunge.py`), not yet a
table in Segno. The Swarm's lanes spread as Live's (0.09, 0.8 and 6.2 %
of the note at Macro 1 0, 0.34 and 1, levels moving alike), so its
randomness is Live's kind. Woozy Bass's engines pass alone (A once the
Filther starts settled); together its stereo stays 1.7 dB off. Happy
Chords' engines are each 0.55 dB loud alone, both through the Filther at
20 kHz, which isolated renders do not cover (round 10). Vertical Bass's
A5 lines at +-160 and +-360 Hz about each harmonic come from engine B's
Sub alone: a 40 Hz pattern Segno's Sub lacks. With the Filther and the
mono LFO hand-over the strict score passes 493 of 573 fit renders (13 of
21 presets) and 15 of 84 held-out (tf mean 4.32 dB). Of the held-out
failures, the four presets with Noise Loop (Elizabethan Gloom, Gotta
Catchem, The Rhythm, PolyPlucks) render identically in Live's three
instances while Segno's Noise Loop draws per instance: Live's noise
buffers are deterministic. **[measured]**

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
