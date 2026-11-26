# Ableton Live device presets on the pedal — brainstorm

<!-- cspell:words adv adg Ghidra devicekit Lfo Vec analyzeHeadless gpr Wavetable wavetables ADSR BLEP BLAMP wavefolder crossfading prewarp Modwheel detuned unnormalised Clob Sallen linearised transconductance retriggered isolations Bellatine Keystrike Numan uncentred dfit Grimer Floot Halfstep -->

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
   the sum is clipped at a fixed limit **[code]**, 0.35 in Segno's scale
   (a third of the filter path's unity level) **[measured]**: saws at Gain
   2 and two at Gain 2 into either filter at resonance 0.7 (round 19) peak
   at the same flat-topped level in Live at C2 and C4; with the clip their
   harmonics 1 to 24 come within 1.7 dB rms of Live's (4.3 to 8.4 without
   it, the resonant peak too strong and the top harmonics 5 to 8 dB low).
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
- Key tracking uses the voice's key value (note − 69)/120 **[code]**. With
  `Filter_Tracking` t the cutoff is scaled by (1 − t) + t · f / 440, a blend
  in hertz of 1 and the note's frequency over A4's **[measured]**: filter
  II's resonant peak at t = 0.3 on C3, C4 and C5 and at t = 1 on C3, within
  5 cents (an octave-scaled form put C3 at 0.3 190 cents low, and Bloom
  Pad's peak 40 cents low).
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
  filter I renders. The cubic's input is the band state × 1.7
  **[measured]**: self-oscillation on noise at resonance 1 within 0.2 dB
  of Live's level (× 1.4 gave 0.64 dB loud), and two saws at Gain 2 into
  resonance 0.7 (round 19) tf 2.0 to 1.8.
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
  Live's from resonance 0.5 to 1. A fresh voice's filter II starts from
  the state its offsets settle to with no input, not from zero: from zero
  the offsets step through the output coupling, a -43 dB transient that
  Live's notes do not have (it moved the onset of every filter II render).
  A note on a voice that ran silent starts from its filters' running
  state instead (Voices).
- Path gains **[measured]**: a sine and a saw at every gain through filter
  I within 0.1 dB and through filter II within 0.05 dB of Live's after
  the output gains 2.915 and 3.69 (they were 0.15 and 0.37 dB high); noise
  reaches filter I 2.2 dB and filter II 2.0 dB quieter than the bypass.
  Filter I's output saturates softly, y / sqrt(1 + 2 y^2) before the gain
  **[measured]**: through an open filter I a sine at Gain 0.25 matched
  Live's level while one at Gain 1 was 0.28 dB loud (a saw 0.22, every
  oscillator at Gain 1 on the fit renders 0.2 to 0.35), and filter II
  matched at every gain; with it, sines at Gain 0.25 to 1 and the
  oscillators at Gain 1 within 0.07 dB, the sine at Gain 1 tf 1.15 to
  0.35, the Saturated oscillator 0.70 to 0.09, two saws at Gain 2 into
  resonance 0.7 (`drv-f1-g4-r07`) 1.8 to 1.2. Applied to the input
  instead, the hot-input renders came out worse (1.6).
- Filter input: both types clip their input: linear to about +0.70 and
  -0.98, a soft knee, and a hard edge at +0.79 on the positive side. A sine
  at Gain 1 gets Live's harmonics 2 to 41 within 3 dB (the hard edge gives
  the slowly falling tail); at Gain 0.5 it stays clean. Past the knee the
  negative side rises again with slope 1 to a hard edge at -1.6 (the
  code's ±1.6 clip of the sum) **[measured]**: a saw at Gain 2 and two at
  Gain 2 into filter II at resonance 0 (round 19), harmonics within 1 dB
  rms (held at the knee, harmonics 2 to 5 were 2 to 5 dB low). Round 24
  then showed that the negative side has no knee at all: it stays linear
  to the hard edge at -1.6 **[measured]**. With the knee at -0.98, a
  rectangle at Gain 1.5 and two rectangles summed to 1.5 into filter II
  (`sq1-f2`, `sq2-f2*`) came out 0.8 dB quiet. Without it they are within
  0.05 dB, round 19's hot saws go from tf 0.7 to 0.05, and Majestic FM
  Bells and Slip Sliding go from 0.6 and 0.8 dB quiet to within 0.2 dB. The path around
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
  not the oscillators' own Transpose. A Mono lane's Ratio LFO follows that
  lane's octave (an octave or two below the note) and the per-key drift
  offset, while Unison's detune and the per-voice drift offset do not
  move it **[measured]**: round 19's Ratio LFO on a pitch slot in Mono,
  Unison and Stereo at Drift Depth 1 (tf 0.3 to 0.9 dB; following the
  per-voice offset too gave 3.4 to 5.3) and Crunch Arcade's Mono LFO at
  Ratio 12 (its pitch an octave off before). Sync divisions 0..21 run slowest
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
  vibrato. **[code]**, fitted (sidebands within 0.1 dB of Live's). The
  cycling envelope in Ratio mode does the same, centred on its middle:
  phase modulation by (level - 0.5) × amount × 2 cycles, half the slot's
  4-octave range as the LFO's depth is half of its 2 **[measured]**: round
  19's sine at Ratio 2 and 3, amounts 0.1 to 0.25, two envelope shapes,
  sidebands within 0.8 dB rms (3 to 10 uncentred); Bellatine's at Ratio
  14 (as vibrato Segno's note sat 336 cents sharp).
- LFO shapes 0..8: Sine,
  Triangle, two saws (rising and falling; which one is "Saw Up" is
  **[open]**), Square, Sample & Hold (two steps per cycle), Wander (smoothed
  random), Linear Env and Exponential Env (one-shot, 0..1). Output × Amount
  × the gain from its own mod source. **[code]** Sample & Hold and Wander
  (rng-01-drift-meld.md, Drift section) **[code]**: each lane has its own
  two-word xorshift (shifts 10, 13, 10; a value from its top 23 bits,
  uniform in -1..1), and the four lanes of a block differ while every
  block starts from the same words. Live seeds them from the system's
  entropy once per instance, so its values differ in every instance;
  Segno seeds from a fixed seed of its own **[Segno]**. Every lane steps
  once per voice tick while the shape is one of the two, whether or not a
  boundary falls; a boundary is the half-cycle phase frac(2p) wrapping.
  There Sample & Hold holds the step's value, and Wander moves its base to
  the old target and aims at the new one, gliding along 2q² then
  1 - 2(1 - q)² over the half cycle. A block reset steps every lane twice
  (the first value held, the second setting Wander's delta); a
  retriggered note start steps every lane of its block twice and the
  starting lane takes lane 0's two values, then holds lane 0's first
  value for half a cycle.
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
- A silent voice in a running block runs its whole chain, not only its
  oscillators: they feed its filters, its envelopes keep falling, and its
  output is summed **[measured]**. So a voice freed by its release (Env 1
  below 0.001) keeps sounding, falling on, until its block stops, and a
  new note on a silent voice starts from the filter state that run left
  (a voice never played runs as A4 with its own drift); with Reset
  Oscillator Phase on, the note starts both filters from rest. A block
  with no voice sounding stops with its state held, running only its
  LFOs. Measured on the held-out presets: notes on silent voices start
  from their filters' running state (Toy Helicopter's triad after its D2
  tf 3.0 to 0.5, Transistor Reeds 2.5 to 0.2, Wave Pad 3.1 to 0.6, Echo
  Bells 2.4 to 0.8), a free voice's Envelope 2 keeps releasing
  (Transistor Reeds 0.34 to 0.17), a voice released early in a 9 s
  attack keeps its tail below 0.001 while the triad holds its block
  (Darkened Strings 2.5 to 0.5, Slow Roll Strings 2.3 to 0.5); round 19's
  filter II notes with Reset on start from rest (`drv-f2-*-r0`, tf 0.02
  either way only with the reset). Round 24 confirmed this on isolations:
  a never-played voice's filter state, a voice restruck after 0.05 to
  2.5 s with its block stopped, the same with the block running, filter
  I, Reset on and the release tail below 0.001 all pass (`fs-*`). A
  stopped block holds its state: letting the filters ring down with no
  input changed none of those renders and took `fs-idle-g030-hp` from
  tf 2.3 to 11. That render (high-pass at 200 Hz, restruck after 0.3 s)
  is the one still failing: Live's restart jumps to +0.30 with a sharp
  step, Segno's rises from +0.12. Clearing the high-pass at the note
  made it worse (4.1). Airfare Bass, Floot Bass and Vanguard Brass stay
  open.
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
    thirds; mode gain about −1 dB. Each lower voice plays as the note it
    sounds (12 or 24 below) for key tracking, the Key source and the
    per-key drift **[measured]**: Live's Mono presets (Rogue tf 3.0 to
    1.7, Seventy Two Bass 3.9 to 3.2, Sol Bass's level 0.9 to 0.1 dB:
    its noise through filter II peaks where the sub lanes' key tracking
    puts it). Round 21's Mono handoffs (releases of 0.1 to 2 s, gaps of 0
    and 0.3 s, Thickness 0 to 1, chords, held notes, Legato) all match
    already, so the handoff itself is right.
  - Stereo: two voices per note (16 notes at most); Spread's law is
    **[open]**.
  - Unison: four voices per note (8 notes at most), the left side sharp:
    +42 and +21 cents panned −1 and −0.5, −21 and −42 at +0.5 and +1 at
    full Strength (lane 0 the sharpest, as the code orders them:
    measured, with each voice's drift on its lane, Live's Unison renders at
    Drift Depth 0.63 only line up that way), both scaled
    linearly by Strength; mode gain about −6.5 dB. The pan law is
    **[open]**.
- Voice counts (0..4): 4, 8, 16, 24 and 32 voices; Stereo plays half as
  many notes, Unison a quarter. **[code]**
- Drift Depth: a fixed tuning offset per key plus one per voice, linear
  in w = depth / 0.58. The same key on the same voice always gets the same
  offset, in every instance (three Live renders of one patch, each a fresh
  device, are identical). **[measured]** Segno uses the measured values
  (the owner's decision, 2026-11-25, on values measured from Live's
  rendered audio), in cents per unit of w, from round 17 at Drift Depth 1
  with a sine: per voice (32) from round 17's `dv-stereo`, each lane of 16
  Stereo pairs alone on its channel at notes 84..99 (pair p is voices 2p,
  2p + 1; cross-checked against `dv-poly` voices 0..18, half depth in
  `dv-poly-d05` and round 18's `dv-poly-hi2` voices 16..31, all within
  0.01 cent); per key (C1..B5) minus the voice's offset, from round 18:
  C1..D#1 from `dk-lo2` (voice 0, the oscillator two octaves up so the
  window holds 30 cycles), E1..G2 from `dv-st-lo` and C3..D#4 from
  `dv-st-mid` (every voice at once, 3 s windows), G#2..B2 from
  `dk-trans`, and E4..B5 from round 17's `dk-c`. Round 17's `dk-a` held
  too few cycles at the lowest keys: C1..F#1 were 0.5 to 6.5 cents off.
  Round 18 also settled: the per-voice offset does not depend on the key
  (every pair's split at E1..G2 and C3..D#4 within 0.06 cent of the
  table); the per-key offset follows the key played, not Transpose
  (`dk-trans`); depth is linear (`dv-st-mid-d05` within 0.06 cent); and
  keys outside C1..B5 have none (`dk-lo`, C-1..B0, and `dk-hi`, C6..G9,
  within 0.07 cent). Statistics of the values: per key a mean of
  +1.18, a spread of 3.63, neighbours correlated 0.53; per voice a mean of
  +2.26 and a spread of 7.2, independent from voice to voice; Stereo pairs
  and Unison groups are consecutive voices. The measurement script is the
  fit tooling's `dfit/drift_tables.py`. Osc 2 adds one more offset per
  voice (32 values, -0.82 to +0.83 cent per unit of w), the same at every
  key, octave, Detune and Transpose **[measured]**: round 19's
  `o2-stereo` (Osc 2 alone, a sine, Stereo pairs at 84..99), within 0.14
  cent on `o2-st-a..d` (keys 24..83), `o2-st-out`, Osc 2 at -1 octave,
  Detune +7 and Transpose +24; with it tape-chord's stereo goes from 1.87
  to 0.04 dB. Transpose +24 leaves both oscillators' tables as they are
  (`o1-st-t24`, `o2-st-t24` within 0.02 cent).
- The per-voice tables follow the preset's SerialNumber; the per-key
  table is the same for every serial **[measured]** (round 20): Live
  clamps the serial to 0..8388607 (8388608 plays 8388607's values,
  -2147483648 serial 0's), and every serial measured has values of its
  own (1 and 12345: 17 and 20 cents rms from serial 0's). The factory
  presets hold 0, -2147483648, 2217915 and 8388607, so Segno carries the
  measured per-voice and Osc 2 tables for serials 0, 2217915 and 8388607
  (each from its Stereo pairs at 84..99, cross-checked within 0.2 cent on
  pairs at 24..83) and uses serial 0's for any other serial **[Segno]**.
  The presets that were off pitch on serial 0's tables (Monday Morning
  12 cents, Synth on Screen, Grimer Bass, Game Console) now sit within
  0.4 cent. Script: `dfit/drift_tables_serial.py`.
- SerialNumber: a random number per instance, saved in the preset; it
  selects Drift Depth's per-voice tables (see above) **[measured]**. The
  preset reader must pass `Global_SerialNumber` as the device parameter
  `LE_DRIFT_SERIAL_NUMBER` (integer, 0..8388607).
- Glide starts from the pitch the voice holds: a sounding voice (legato,
  a restrike, notes struck in the same sample), and in Mono also a voice
  whose last note has ended **[measured]**. Round 24's Mono chord after a
  note that ended 0.5 s before (`gl-mono-chord`, `-leg`) went from tf 3.0
  to 0.2; gliding only between the chord's own notes gave 1.8. A free
  Poly voice still starts on its note (`gl-poly-chord`). Held-out Rogue
  went from 1.88 to 1.37.
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
- Round 17 (2026-11-25): the Drift Depth statistics above, and the
  held-out phrase (a quiet C2, a loud C4 triad, a hard C5) on twelve
  isolation patches: velocity to volume and to the filter, release during
  a long attack, one Unison slot, two Stereo slots, four Poly voices with
  long releases, Mono, the cycling envelope in Sync and Freq. All twelve
  pass, so none of those paths explains the held-out failures. With the
  statistics-matched tables the strict score is 204 of 263 (factory
  presets 0 of 5); a scratch build with the measured per-key and per-voice
  values instead (not kept) passes 245 of 263 (presets 2 of 5): 41
  renders fail only because of the exact drift values (the list is kept
  with the fit tooling, `dfit/drift_only_list.txt`). With the measured tables
  in the product (the owner allowed values measured from renders): 247 of
  263, factory presets 3 of 5, and every one of those 41 passes. Still open in
  the tables: a Stereo pair's split inside the key range looks larger than
  at the notes 84..99 it was measured on (80s Tape's G2 pair: 0.68 against
  0.29 cents per unit of w; Bloom Pad's lanes 2 and 3 within 0.9 cent), so
  the per-voice offset may depend on the key; and the keys outside C1..B5.
  Round 18 measured both (every voice at C3..D#4 and E1..G2, at two depths,
  and voice 0 from C-1 to B0 and C6 to G9): neither holds, see Voices; the
  80s Tape difference is Osc 2's own offset (round 19).
- Round 19 (2026-11-26): Osc 2's own per-voice drift offset, the voice
  clip and the filter input past the knee, the cycling envelope's centred
  phase modulation and the Ratio reference's per-key drift (each above).
  Settled as already right: the Key source's scale (`key-lp`,
  `key-shape`), Pulse's shape clamped at 0 (`pulse-neg05`, `pulse-neg1`),
  and when a releasing voice counts as free (`free-tie-*`: the voice Live
  picks, read from its drift, matches Segno's for every gap). Strict score
  300 of 335 (264 of the 296 scored before round 19, from 252), factory
  presets 3 of 5; held-out 45 of 89, from 14. Round 20 then measured the
  SerialNumber tables (see Voices): 318 of 351, held-out 47 of 89. Still
  failing: Chirp Pluck and Clob Bass, the Mono presets Sol Bass, Seventy Two Bass, Rogue
  and Crunch Arcade (tf 3 to 4.5), Metallic Strings (random Sample & Hold),
  and filter I at a hot input with resonance (`drv-f1-g4-r07`, 2.0).
- Held-out breakdown (2026-11-26, 49 of 89 passing, five Live copies of
  each random preset): of the 40 failures 17 are random (noise or Sample
  & Hold) and 23 deterministic; 21 are Stereo, 7 Mono, 7 Unison, 5 Poly.
  The worst third-octave segment is the C3 in 12, the triad in 15 and
  the C5 in 13; averaged over a segment the spectra mostly agree within
  2 dB, so most failures sit in the time structure: beating between
  lanes and oscillators (Echo Bells, Transistor Reeds), low-frequency
  side signal in Stereo (Toy Helicopter's triad), release tails (Darkened
  and Slow Roll Strings: a 100 Hz component in Live's tails that Segno
  lacks, 30 dB down) and the Mono presets (Seventy Two Bass, Rogue,
  Crunch Arcade, Gear Shift, Sol Bass, AG Bass). Round 21 isolates Mono
  note handoff.
- Round 22 (2026-11-26): the oscillators' starting phases match Live's
  within 0.01 cycle on every note **[measured]**: sines around the
  filters, Osc 1, Osc 2 and both, a fresh voice, the same voice after 0.5
  and 2 s, Reset Oscillator Phase on and off, Poly and Stereo, with the
  voice's block idle or running, at Drift Depth 0 and 1. So the beating
  differences in Echo Bells and Transistor Reeds do not come from the
  start phases. Toy Helicopter's triad alone (and with each oscillator
  alone) matches; its failure appears only after the D2, and is not the
  idle voices turning nor the synced LFO's restart. Clob Bass's stereo
  error is the noise in quiet bands (its noise-only isolation fails only
  in bands 15 to 35 dB down, where the noise's own fluctuation rules).
  (Corrected: Metallic Strings' LFO is the Square shape, and Numan
  Keystrike's Sample & Hold LFO is routed nowhere, so neither depends on
  random draws. Their Live copies are the same sample for sample (Numan
  Keystrike's three renders in round 18 and its held-out copy: rms
  difference 0; Metallic Strings' within 1 % from its quiet noise), which
  fits a per-instance seed that nothing audible reads. Metallic Strings
  switches filter II's cutoff by ±4.2 octaves with that square at the
  note's frequency, so its sound rests on the LFO's phase against the
  oscillators: still failing, cause open.)
- Held-out diagnosis by kind (2026-11-26, 48 of 89 passing): the
  largest shared cause was the note on a silent voice. Of the
  deterministic failures most had their error at the triad's or the
  C5's onset (Floot Bass's triad: Live jumps to -0.42 within the 0.5 ms
  attack, Segno started from rest), which pointed at the filters'
  state: in Live a silent voice in a running block runs its whole chain
  and keeps sounding below its release threshold (Voices). With that,
  48 to 61 of 89 held-out, fit renders 354 to 363 of 390 (presets 3 to
  4 of 5, Clob Bass now passing), no fit render lost. Sweet Tooth's
  onset error is not its note start: Live's copies draw different Wander
  values there as Segno's seeds do (the pitch in the first 20 ms spans
  about 40 cents over Live's copies and Segno's seeds alike); the onset is the first sample above -60 dB of the
  render's peak, and the peak (the triad's, 0.3 s in) varies 1.8 dB over
  Segno's three seeds against 0.5 dB over Live's five copies, which
  moves the onset by 3.6 ms through a flat stretch of the attack. So the
  onset metric samples the peak's spread; no note-start rule is
  missing. What still fails: the Mono presets (Crunch Arcade, Seventy
  Two Bass, Sol Bass, Rogue, AG Bass, FM Halfstep Sticks), whose notes
  start on voices whose state differs (Sol Bass's A5 after the C5: the
  first 25 ms differ below 150 Hz), and audio-rate cutoff modulation of
  filter II (Metallic Strings' Square LFO, Numan Keystrike's cycling
  envelope in Ratio mode: Numan 3 dB quiet across the spectrum). Round
  24 isolates both, and the filter state of a stopped block.
- Second pass (2026-11-26): the held-out level errors split by filter
  type (filter I presets mostly 0.1 to 0.6 dB loud, filter II ones 0 to
  0.8 dB quiet), which led to filter I's output saturation (Filters):
  66 of 89 held-out, 364 of 390 fit (`lfo-ratio-shape`'s attack 1.93 to
  2.22 the one fit render lost); with the scorer's five seeds 67 of 89
  and 366 of 390. Sweet Tooth still fails on onset at five seeds (2.2
  ms). Settled from existing renders: a voice
  never played runs at A4 with velocity 0 and Envelope 2 at 0 (velocity
  1 or 0.5, C4, Envelope 2 at 1 all made Floot Bass, Transistor Reeds and
  Wave Pad worse). Candidates held for round 24, not in the product:
  letting a stopped block's filters ring down with no input passes
  Airfare Bass (1.54 to 0.99) and Vanguard Brass (1.61 to 1.03) and
  helps Sol Bass (1.89 to 1.73), but makes Floot Bass worse (1.61 to 2.4),
  so the held state is not simply decaying (`fs-idle-*` settle it); and
  gliding between notes struck in the same sample on a voice that was
  free (Segno jumps to the last note) passes Rogue (1.88 to 1.38), with
  no fit render that exercises it (`gl-*`). Majestic FM Bells and Slip
  Sliding share one stage: two rectangle-type oscillators summed to a
  peak near 1.5 into filter II, 0.7 dB quiet across the spectrum (their
  fit copies `tr-*` too); `drv-f2-g4-r07-sq` (a saw and a rectangle hot
  into filter II) has its second harmonic 14 dB too strong. Neither a
  symmetric positive clip nor an inverted rectangle fits (both far
  worse), so the input clip's shape for square sums is open (`sq*`).
- Round 24 (50 renders, 2026-11-26): 32 of 50 passed as built; with the
  two changes it confirmed, 39. Confirmed: the silent-voice model
  (`fs-*`, all passing but `fs-idle-g030-hp`); a stopped block holds its
  filter state (the ring-down candidate rejected); Mono glides from its
  last note after it ended (`gl-*`, adopted); the negative side of the
  filter input has no knee (`sq*`, adopted; see Filters). Strict score
  with five seeds: 408 of 440 fit (366 to 369 of the 390 scored before,
  none lost; round 24 32 to 39), factory presets 4 of 5; held-out 67 to
  69 of 89 (Rogue, Majestic FM Bells and Slip Sliding pass; Echo Pulse,
  a random preset, went from 2.04 to 2.06 against its limit). Still
  open:
  - Filter I at resonance 1 with a loud saw (`f1s-*`, Seventy Two Bass):
    Live shows no ringing peak at the cutoff, only a broad plateau, where
    Segno peaks 14 to 22 dB above it at harmonics 30 to 32 (2 kHz). A
    stronger resonance shaper (drive 1.7 to 2.5) halves the peak and
    passes Seventy Two Bass (2.24 to 1.48), but drops the self-oscillation
    on noise (`f1-1k-r1`) 1.8 dB, so the limiting has another shape.
  - Audio-rate cutoff modulation: the cycling envelope in Ratio mode on
    either filter passes (`am-cyc-*`), and so does a slow Square LFO
    (`am-sqs-*`); a Square LFO at the note's frequency fails (`am-sq-f2`
    tf 2.6, `am-sq-f1` 4.0) with its harmonics within 0.5 dB, the error
    in bands below the note, where a slow beat sits. Inverting the square
    or moving its start phase made it far worse. Metallic Strings
    (`ms-held` 5.2) and Numan Keystrike (`nk-held` 4.7, 1.8 dB quiet)
    stay open.
  - Metallic Swell Pad: the triad and its version with velocity to
    cutoff off pass (`msp-tri*`); one note at four velocities fails on
    stereo and onset (`msp-vel`).
- Round 16 settled two questions. Live's drift is the same in every
  instance: three Live renders of one Drift Depth patch, each a fresh
  device, correlate 1.0000. And Bloom Pad's filter peak came from key
  tracking (now a blend in hertz, above); its Env 2 modulation matched.

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
