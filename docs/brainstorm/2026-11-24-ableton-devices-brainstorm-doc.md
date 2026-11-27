# Ableton Live device presets on the pedal — brainstorm

<!-- cspell:words adv adg Ghidra devicekit Lfo Vec analyzeHeadless gpr Wavetable wavetables ADSR BLEP BLAMP wavefolder crossfading prewarp Modwheel detuned unnormalised Clob Sallen linearised transconductance kModBy kCarriers Celesta transconductances Bandpass Bitgrunge Csound Drivetime Extratone Filther Lofi Lowpass Megatripolis Minnaert Sawstyle Starchestra polyBLEP Metalic Formant formants Barney Asym quintic Perc retrigger retriggers unsynced Quantizer autocorrelation tfz unmeasured retriggered isolations penv Unisono pul meldfit Geigerzaehler Bellatine Keystrike Numan uncentred dfit Grimer Tesseract Tesseract's auxenv fdrive fltkey keyscale lfofree minatt noteoff penvd rndpan Bassic Bitgrunge's Catchem Filther's Kaneda Werkstuecktraeger Whley Whley's filt nloop avel fleg unmodulated Basscycle spr prewarping Floot Halfstep Gametal Plucks Neurotimbre sqperc unnormalized fenv restruck fmdrive oscvol unsmoothed colfm circ nornd retunes Detuned Cardano baselined prewarped -->

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
  silence. Input gain about 1.67. **[code]** A closer reading of the
  filter's process and coefficient functions (round 25) gives the
  structure **[code]**: the two integrators are trapezoidal one-poles
  with coefficients g / sqrt(3.3) and g sqrt(3.3) (g the prewarped
  cutoff); the resonance is fed back from the output node v, subtracted
  at the first integrator's input and added at the second's, through
  v - v³/3 with v held at ±1; the loop is zero-delay, v solving the cubic
  v = m + K (v - v³/3) each sample (m the output without feedback, K the
  loop gain through both integrators). The feedback gain r (1 + 1/3.3)
  cancels the base damping (1.18) at resonance 1; above 1 it is pulled
  back by r / (1 + 3 (f - 0.075)₊ (r - 1)₊) for f = fc/fs; the output is
  clamped at ±1. The injected noise is about 2e-5 at the output plus a
  rumble term 0.6 fc / (fc + 10)² at the input (a tenth of it at the
  second integrator). Segno solves the cubic in closed form and uses
  uniform noise of the same variance **[Segno]**. Segno's earlier fit
  put the cubic on the band state of a state-variable filter (× 1.7),
  which rang at the cutoff with a loud saw at resonance 1: 14 to 22 dB
  above Live's broad plateau at harmonics 30 to 32 (`f1s-*`, Seventy Two
  Bass). With the output node shaped, every `f1s-*` render, `f1-1k-r1`
  (self-oscillation on noise), the hot saws of round 19 and Seventy Two
  Bass pass; held-out 68 to 70 of 89 with Gentle Pulse Pad.
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
  instead, the hot-input renders came out worse (1.6). The reading of
  filter I's code (round 25) does not show this stage (the filter itself
  is linear at resonance 0), yet it stays needed with the rebuilt filter:
  without it the `f1s-*` renders and Seventy Two Bass come out 0.2 to 0.5
  dB loud and fail.
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
  LFOs; when it starts again its voices' low-pass filters start from
  rest, while their high-pass keeps the state it held **[measured]**
  (round 24, below). Measured on the held-out presets: notes on silent voices start
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
  I, Reset on and the release tail below 0.001 all pass (`fs-*`), all
  but `fs-idle-g030-hp` (high-pass at 200 Hz, restruck after 0.3 s on a
  stopped block): Live's restart jumps to +0.30 and falls, Segno's
  rose from +0.12. The waveforms settle it: every restrike on a stopped
  block (gaps 0.05 to 2.5 s, either filter) starts in Live from zero and
  grows like a two-pole step response, where Segno's held low-pass state
  gave a jump (-0.17 at C3), and Live's +0.30 with the high-pass is that
  filter's held state against a low-pass at rest. So a restarting block
  starts its low-passes from rest and keeps its high-passes
  **[measured]**: every `fs-*` render passes (`fs-idle-g030-hp` tf 2.3
  to pass), and Floot Bass, Airfare Bass, Vanguard Brass and Sol Bass
  pass on the held-out round (Grimer Bass 2.22 to 1.91). Letting the
  low-pass ring down with no input while the block is stopped scores
  the same; resetting it is cheaper. The earlier ring-down candidate
  also let the high-pass decay, which removed its jump.
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
per track, unnormalized, 48 kHz) against Segno's render of the same
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
- Round 25 (2026-11-26, no new renders; scorer round 8, ten seeds for
  random renders): re-baselined at 408 of 440 fit and 70 of 89
  held-out. Two changes, both above: filter I rebuilt from a closer
  reading of its code (the shaper on the output node, solved in the
  zero-delay loop; Filters), and a stopped block that starts again
  starts its low-passes from rest and keeps its high-passes (Voices).
  Strict score 416 of 440 fit (every `f1s-*` render, Seventy Two Bass
  and Gentle Pulse Pad's copies, `fs-idle-g030-hp`; none lost) and 77
  of 89 held-out (Seventy Two Bass, Gentle Pulse Pad, Floot Bass,
  Airfare Bass, Vanguard Brass, Sol Bass, Arcade Split). Tried and not
  kept:
  - The LFO read after its phase advances, as the oscillators read
    theirs. On `am-sq-*` Live's cutoff rises two samples before each saw
    reset, which Segno's square (read one increment behind the
    oscillator) misses; reading it after the advance takes `am-sq-f1`'s
    attack from 0.95 to 0.06 and its level error from 0.46 to 0.04 dB
    (`am-sq-f2` 0.26 to 0.07). Both still fail on tf (2.1, in the bands
    below the note), and over every render the change loses Grimer
    Bass's copy (1.53) and the held-out Kentucky Lead and gains only
    Chirp Pluck's random renders, so the order stays as it was **[open]**.
  - Smoothing the cutoff's modulation (a one-pole on the exponent) made
    `am-sq-f1` worse at every time constant; Live's cutoff switches in
    one sample.
  Still failing: Metallic Strings (`ms-held` 5.2) and Numan Keystrike
  (`nk-held` 4.7, 1.8 dB quiet across the spectrum, with time-varying
  error in every band); both use the Saturated oscillator in Unison
  with its shape modulated at audio rate, which no isolation covers
  yet. Crunch Arcade (3.1), Lo-Fi Metal Hit, Grimer Bass (1.9), Dub
  Techno Bass and AG Bass (1.8 to 1.9) on the held-out round; the
  random presets Sweet Tooth (onset) and Star Dust Strings (pitch and
  onset), where Segno's seeds spread more than Live's copies, and Chirp
  Pluck's fit renders on pitch.
- Round 16 settled two questions. Live's drift is the same in every
  instance: three Live renders of one Drift Depth patch, each a fresh
  device, correlate 1.0000. And Bloom Pad's filter peak came from key
  tracking (now a blend in hertz, above); its Env 2 modulation matched.

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
- Each sample the phase advances first and the table is read at the new
  phase, so a note's first sample reads its start plus one increment.
  **[code]** (op-05 4.2) **[measured: Live's sine at C6 lies −92 dB from a
  sine one sample ahead of the note and −17 dB from one starting at it]**
- Lookup truncates unless Interpolation is on (linear). Antialias runs the
  whole operator engine at twice the rate, reads band-limited copies of the
  tables, and decimates with a polyphase allpass half-band. **[code]**
- One mono filter and the shaper per voice, then the voice's gain pair
  (volume and pan) into the stereo sum. With the filter off, the shaper is
  bypassed too. **[code]** **[measured]**
- Parameters apply per 16-sample chunk, ramped across it; the operators,
  envelopes, filter and shaper run every sample. **[measured]** Nebulae
  Keys, whose 509 Hz sample-and-hold LFO moves operator A's volume, misses
  12 dB at 1.6 kHz with 32-sample chunks and matches with 16 (round 8 and
  11's copies 2.9 dB to 1.2; 8 samples 2.2, 4 samples 2.8, every sample
  or held steps worse). The voice end keeps a 32-sample grid (below).
  Round 12 confirms it per destination: a 1.1 kHz sine LFO into Volume,
  an operator's volume, Pan and FM Drive puts its images around 3 kHz and
  6 kHz (one block of 16 samples), Live's and Segno's matching to the dB
  (tf 0.01 to 0.35), and into the pitch it acts every sample (0.02).
  **[measured: round 12 cr-vol, -oscvol, -pan, -fmdrive, -pitch]**

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
  **[measured]** Noise Looped's table is fixed: the generator
  s ← 1664525 s + 1013904223 (mod 2³²) seeded with 0x275B6ACF and stepped
  once before each of its 4096 samples, each sample (s mod 2²³)/2²² − 1
  from the low 23 bits, built once per process and shared by every
  instance and voice; no filter and no band-limited copies, peak-normalised
  with the peak (0.99973) kept as its gain. It is read like any periodic
  table, 64 table samples a period, the phase modulation at 2 whole loops
  per unit. **[code]** (op-05) **[measured: Live's wave-20 render correlates
  1.000 with it sample by sample, its first samples within 3·10⁻⁸; tf 2.33
  to 0.09]** The reading describes Noise White as the same kind of table
  read one sample a step, but Live's White does not repeat at 4096 samples
  (autocorrelation −0.002 there in wave-21), so Segno keeps its fresh value
  per sample. **[measured]**
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
  **[measured: the sidebands of every FM render within 0.6 dB]** The
  low-pass acts on the input's change, b0 (x[n] − x[n−2]) − a1 w[n−1],
  and the carrier's phase accumulates it: with Tone fixed that is the
  low-passed input, but a Tone that moves leaves its offset behind instead
  of filtering the input afresh. **[code]** (op-01 4.3) **[measured: round
  12 cr-tone, a 1.1 kHz LFO on Tone, every carrier line and sideband within
  0.8 dB (12.8 dB rms to 0.3), the coefficient held per 16-sample block;
  filtering the input itself, smoothed or not, puts Live's low sidebands
  10 to 18 dB too weak and its high ones 11 to 18 too strong]**
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
  seconds without it). A release that starts before its attack or decay
  arrives runs from where it is. **[measured: round 9 rel-in-attack,
  rel-in-decay, within 0.34 dB]** The pitch envelope's one-pole keeps one
  shape whatever its span: it reaches 10^−3.95 of the span as the time
  runs out (the curve's constant). Falls and rises of 2 to 24 semitones
  at amounts 0.5 to 1 each want that one rate (the span-based rule needs
  0.44 to 0.66 of a ratio unit on every one of them); with it all ten
  pitch envelope renders score 0.01 to 0.04 dB and Chorus Strings Sweep
  Pad 5.7 to 1.4. **[measured: round 9's penvd renders]**
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
  RepeatTime, 1/48 to 4 bars), Trigger (note-off ignored, decay runs into
  release). **[code]** Beat counts from the note; Sync's first retrigger
  comes a period after the note, moved on to the next sixteenth of the
  song, the rest a period apart (a note 0.1 s in retriggers at 0.25,
  0.375 ..). Segno's grid is the device's own clock, samples rendered
  since init (the fit harness starts it with the export). Sync and Beat
  retrigger a modulator's envelope as a carrier's. **[measured: round 7's
  sync and beat renders]** A Beat retrigger due after the note-off does
  not restart the release, and a retrigger falls a whole period after its
  start, so one due at the very sample of the note-off finds the release
  begun (Segno had fired a sample early: round 7's sync and beat renders
  0.69 dB to 0.14; held out, Pure Bell 8ths, whose triad's 12 s release
  had started from a fresh peak, 6.0 to 0.1). **[measured: round 8's
  beat-noteoff, round 7]** A
  Loop's restart runs even a minimal attack (the note's own start skips
  it), and each segment lasts its time rounded up to whole samples: a
  0.1 + 13 + 50 ms loop repeats every 3029 samples, the first 3024
  (Segno lost a sample to rounding in two segments). **[measured: round 8
  Geigerzaehler Bleep, 3.0 dB to 1.3; round 9 loop-minatt, 7.6 to
  0.8]**
- Times scale by 2^(−8 TimeVel (vel − 70)/127) per envelope and by
  2^(3 EnvTime − 6 EnvTimeKey (key − 70)/127) for all, attack included
  whatever EnvTimeIncludeAttack says (Live scales the attack either way).
  **[code]** **[measured]**
- A voice ends when every sounding carrier's envelope has ended; a stolen
  voice fades in 1 ms. **[code]** In its release an envelope has ended
  once it falls below 10^−3 of full level (before the operator's own
  amplitude), and the voice stops a block later, the check and the block on
  a 32-sample grid whatever the chunk: a 50 ms release from
  full level ends 1760 samples after the note-off, from 0.25 at 1648,
  from full level at volume 0.1 at 2296 (Segno within 1 to 17 samples
  now; it ran each release out). **[measured: sine, env-loop-1, round 9's
  rel-in-* and osr-self renders]**

### LFO and pitch envelope

- Types 0 Sine, 1 Square, 2 Triangle (from −1, rising), 3 Saw Up, 4 Saw
  Down, continuous (Live's slow LFOs rise smoothly, without the 512 steps
  the reading's table suggested: 5 cents at rate 2) and smoothed by a
  one-pole at max(16 f, 200 Hz); 5 Sample & Hold (a new value twice a
  cycle); 6 Noise (white noise through a one-octave band-pass at max(f,
  5 Hz)). **[code]** **[measured: the triangle's start, the smooth
  shapes]** The saws ramp exactly and turn back over the last 1/256 of a
  cycle, linearly, as an interpolated table whose last step holds the
  wrap would: Live's Saw Up on the pitch at 8.7 Hz starts its fall about
  20 samples before a hard wrap and averages 1/256 low over a cycle, while
  the slow saws of round 2 ramp exactly; with it the multiplier through
  zero needs no other law (1 + L, from −1 to 3 at amount 1). **[measured:
  round 12 lfo-zero-a60, -a80, -a100, 0.72, 1.44 and 1.55 dB to 0.39,
  0.63 and 0.61; Live's carrier phase followed sample by sample within
  0.014 of a cycle over six LFO cycles]** The Saw Down's mirror image is
  Segno's choice (round 13's lz-sd-a100 asks).
- Rate: a note number, f = 440 × 2^((n − 69)/12), Low 104 semitones below
  High, key scaling about C4; Sync: 1/48 to 4 bars. Retrigger off starts
  each note from one free-running phase. **[code]** **[measured]** In
  Live's renders that phase counts from the export's start (the fit
  harness sets it so): a note 0.5 s in matches within 1°. Notes in the
  very first block do not: 0.30 of a cycle off at 1.9 Hz, 0.17 at 6.5 Hz,
  Bells Brushed Hits' first chord 0.39. The offset does not repeat from
  one Live instance to the next: three copies of one render put the
  same note at −111°, −39° and −1° (the last on the export clock), so it
  is Live's own per-instance draw, judged against Live's spread.
  **[measured: lfofree-single and its round 8 copies]**
- Amount: 2 Amount² × A%, × 4(0.5 + VelScale (v − 0.5))², × the LFO
  envelope. Destination A multiplies an operator's phase increment by
  (1 + L) (linear pitch) and adds 24 semitones per unit to the cutoff
  through a smoother. **[code]** **[measured: pitch within 0.003]** The
  LFO's route into Filter Freq passes the same smoother, so an audio-rate
  LFO leaves the cutoff still (Live's 1.1 kHz LFO there makes no
  sidebands: 9.8 dB to passing). Its route into Tone is not smoothed: the
  difference Live shows there is how Tone's low-pass sits in the phase
  (above, Algorithms and FM). **[measured: round 12 cr-filter, cr-tone]**
- Pitch envelope: its levels in semitones × Amount × A%, as frequency
  ratios, multiply the increments of the operators that take it. **[code]**
  **[measured]** With LFO PitchEnv on, the same ratio (linear in ratio
  across a segment) multiplies the LFO's rate: Wobbly Flag Bass's LFO
  speeds up through its decay from 29 to −45 semitones as Live's does
  (14.6 dB to 5.4, pitch 6.8 cents to 1.4). **[measured: round 8,
  Wobbly Flag Bass and lfo-penv-rate]**

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
- LFO Rate (8 octaves per unit) and the A/C and B/D crossfades take a ×
  (2u − 1): aftertouch and the mod wheel at rest count as −1 there. +20 %
  at rest slows the LFO 1.6 octaves (OP Bass, 1.3 to 0.43 Hz), −20 %
  speeds it 1.6; the mod wheel's +58 % on the A/C crossfade gives C 0.42
  and A 1.58 at rest (Analog Bouquet Brass, its C and D alone 7.5 dB too
  loud without it). **[measured]**
- A gain destination only attenuates, by 1 − a⁺ + a u (a⁺ the amount's
  positive part): the operators' volumes, FM Drive, LFO Amount, the
  filter envelope's amount (velocity +50 % leaves it whole at 127), Volume
  and Tone (which scales the Tone value). +100 % from aftertouch at rest
  silences, −100 % leaves full level; velocity −50 % gives 0.5 at 127 and
  0.75 at 64; the pitch envelope at 0 semitones gives 0.5, at +24 0.75.
  Volume scales the voice's output, after the filter and the shaper, and
  leaves the modulators whole: Creep Bass (velocity on Volume) drives its
  shaper as hard at velocity 64 as at 127 and keeps its FM sidebands
  (4.4 dB to 1.4), Bells Classic Basic 2.1 to 0.05, Smack Kick 2.4 to
  2.0 (FM Piano Classic, its LFO on Volume, 2.4 to 1.1). **[measured:
  round 8; round 9's vel-vol-shaper and vel-vol-fm, 0.39 and 0.06 dB]**
  Filter Res, Filter Drive and Aux Env (the pitch envelope's amount) are
  gain destinations too: the mod wheel at rest with +50 % halves the
  resonance, −50 % leaves it, +100 % opens none (Harsh FM Bass 4.7 to
  1.9), takes all of a 6 dB drive and silences the pitch envelope.
  **[measured: round 9 mw-res-p50, -m50, mw-fdrive (5.1 to 0.1),
  mw-auxenv (0.8, attack 19.6, to 0.02); Wobbly Flag Bass, its pitch
  envelope on Drive, 5.4 to 4.3]**
- Feedback, Filter Morph and Shaper Drive move nothing with the mod wheel
  at rest at +100 %, nor Shaper Drive with velocity 64 at +100 %, as
  adding destinations would not; Segno does not route them (their units
  are unmeasured), nor Filter Q (legacy). **[measured: round 9]**
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
  0.37 + 1.26 (1 − q)^1.32 with q at most 1 (it does not self-oscillate),
  the 24 dB second section at the low-pass's share of q. **[fit: the HP
  renders at resonance 0, 0.5 and 1, third-octave bands within 1.3 to
  1.6 dB of that shape]**
- PRD: Segno's model of a four-stage ladder, each stage's input and output
  through z (1 − z²/4 + |z|³/16) with a small offset of its own, feedback
  0.8 × 4.04 q (the reading says 4.04 q; Live's resonance renders want
  less, and below self-oscillation 10 % × (1 − q) more), the pass band
  made up by (1 + k), the input at 0.5 × drive; 12 dB the second stage, 24
  the fourth. **[code]** **[fit]**
- OSR: Segno's model of a state-variable loop with both transconductances
  saturating, damping 2 (1 − q) + 0.05 and a diode across the band node
  (a 0.5 V knee, conductance 0.75 above it), so it rings at a bounded
  level above resonance 1; the input stage barely saturates. The
  transconductances' curve takes the node voltages at 0.145 per volt.
  **[code]** **[fit: round 9's self-oscillation at resonance 1.25, 30 Hz
  to 1 kHz, within 0.6 dB in level and 9 cents at 100 Hz and 1 kHz
  (15 at 300 Hz, where the 262 Hz input pulls it); Tesseract 4.7 to 3.6]**
  The damping is 2 (1 − q) + 0.05: at resonance 1 the circuit rings but
  does not self-oscillate (Live's 30 Hz ring on Tesseract's triad is
  20 dB under the self-oscillation the old −0.01 gave). In Morph mode
  OSR takes no drive, as Clean takes none in any mode. **[measured: round
  11 tess-res1 6.9 dB to 5.0, morph-osr-drive12 11.0 to 0.4, morph-drive0,
  -12, -24 and clean-lp-drive12 all within 0.4]** Live's OSR adds even
  harmonics Segno's does not (Tesseract's C2 at resonance 1, 6 dB short
  at 147 and 292 Hz), and a loud input pulls its self-oscillation flat
  less than Segno's (30.9 Hz for a 32 Hz cutoff under a triad, Segno
  30.2). **[open]**
- SMP: MS2's section with SMP's input constant and a feedback of 0.85 per
  unit of q (the reading's 0.904 rings 1 to 2 dB too loud at resonance 0.5
  to 1) (no factory preset uses it). **[fit]** PRD's high-pass is a core
  of its own (not read, **[code]** only that it exists): Segno's model is a
  ladder of four one-pole high-passes with feedback k from the fourth
  around all four, 12 dB from the second stage and 24 dB from the fourth,
  the pass band made up by (1 + k), the feedback through the stages' curve
  so it rings at a bounded level from k = 4. At resonance 0 that is two
  one-poles; with resonance its stop band rises by (1 + k), which is what
  Live's does (6 to 7 dB more below the cutoff at 0.5 than a plain
  resonant high-pass). k is 0.95 of the reading's 4.04 q for 12 dB and
  1.37 of it for 24 dB, the cutoff 2 % up. **[fit: round 7's hp-prd-r0,
  -r1, -f300, -24 and round 4's circ4-hp, third-octave bands of Live's
  noise within 0.4 to 0.6 dB (1.5 at resonance 1), from 0.5 to 7.5 with
  Clean's high-pass]** (no factory preset uses it)
- Each circuit's renders within the noise renders' own spread (about 2 dB
  rms per third-octave band, Live's white noise being its own draw); the drive
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
  **[measured]** A legato glide keeps the first note's key for every key
  scaling (operator level, filter, envelope times, LFO rate, the key
  route). **[measured: diagnosed on a held-out preset, Electric FM Wow
  Bass; round 8's legato-keyscale, legato-fltkey and legato-triad
  confirm it, 0.1 to 0.75 dB]** A mono voice that has just taken a
  sounding voice's place, and so starts at its own pitch, takes the same
  instant's later chord notes at their pitch too, without gliding (Harsh
  FM Bass, round 8 1.9 dB to 1.1, held out 2.2 to 1.2; neutral on Wobbly
  Flag Bass). **[measured]**
- A note that takes a sounding voice's place (the voice budget, or
  Retrigger Mode's repeated note) waits until that voice has faded (1 ms),
  then starts; a note taken before it sounded is dropped. A mono chord
  plays its first note through the fade and its last 48 samples late, as
  Live's pending queue does; Sync's retriggers stay on the song's grid
  meanwhile. **[code]** (the queue, op-04) **[measured: Rhythmic Pong
  Bass's triad, held out, 47 samples late in Live; its waveform error
  -3 dB to -19, the round 8 copy 2.6 dB to 0.4; Smack Kick 1.8 to 1.6;
  round 12's mono and two-voice triads and a Retrigger Mode repeat match
  Live to the sample, -80 dB waveform error]**
- Random pan and the random start phases do not repeat from one Live
  instance to the next: two identical tracks draw different pans, and
  every held-out preset's Live copies differ (Live against itself 0.8 to
  13 dB over time). Segno draws its own: uniform over ±2 × Rnd, clipped
  to the sides, as Live's draws are (48 at small amounts, standard
  deviation 1.12 of Rnd; at 100 %, 56 % of 36 hard to a side, 50 %
  expected). **[measured: rndpan-a, -b; the held-out copies; round 9
  rndpan-100 and its copies]**
- Pan is equal-power, unity at the centre (√2 cos and √2 sin); key and
  random pan are latched at the note. **[code]** **[measured]** With
  Spread, a fixed pan scales each one-channel voice by the same law
  (+0.5: left −5.3 dB, right +2.3; ±1 silences a side), but each of the
  two voices draws its own random pan: Live's per-note power over both
  channels moves from −7.7 to +3 dB (a shared pan would hold it), and no
  channel goes silent in 36 notes at 50 %. Fizzling Pad goes from 10.3 to
  6.6 dB, Warble Rhythm Noise Pad from 6.5 to 4.8. **[measured: round 10
  spr-pan-p05, -p1, -m1, spr-rndpan-50 and its copies]**

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
- The circuits' drive renders (MS2 and SMP drive the shared MS-20 section
  into its clipping: Live's spectra notch individual harmonics Segno does
  not), PRD's high-pass and 24 dB slope, and the first 150 ms of MS2 at
  resonance 0.5.

Round 7 (52 renders, `segno-op-fit7`) confirmed the curved filter,
pitch and LFO envelope slopes, the one-pole spans, glide into a releasing
voice and the routes at rest into Time and the filter envelope, and
showed Sync's grid, the bipolar LFO Rate and crossfade routes (Analog
Bouquet Brass's 0.9 dB was its C at full level) and the MS2 high-pass's
damping. With the scorer's round 2 (three seeds, Live's own spread where
copies exist): 324 of 349 fit renders and 9 of 10 presets pass (from 314
and 8), the held-out round 32 of 67 (from 29), before any held-out
render was fitted. Still open: the free LFO's phase for notes in the
first block, Metallic FM with its random sources off (3.8 dB: a fixed
0 Hz carrier shaping a fixed 0.01 Hz modulator, Spread's side 6 dB too
strong), PRD's high-pass, MS2's 24 dB high-pass.

Round 8 (81 renders, `segno-op-fit8`) plays the 36 failing held-out
preset kinds with another phrase (D2 at 64, an F4 triad at 90, A5 at
120), with two Live copies of the 19 random ones, and isolates legato key
scaling, a Beat retrigger at note-off, the pitch envelope on the LFO rate
and copies of the first-block free LFO. It confirmed legato key scaling,
the Beat note-off and a constant pitch envelope on the LFO rate, showed
the free LFO's first-block offset to be Live's own per-instance draw,
and through the presets: the pitch envelope's ratio on the LFO rate, the
Volume route on the voice's output, Res taking controllers as bipolar and
a loop's restart through a minimal attack. Round 8 then passed 13 of its
41 renders (from 9), the fit rounds 335 of 390 with 8 of 10 presets, the
held-out round 35 of 67 (from 32).

Round 9 (31 renders, `segno-op-fit9`) settled what round 8 left: the
pitch envelope's one-pole keeps one shape (all ten pitch envelope
renders 0.01 to 0.04 dB, Chorus Strings Sweep Pad 5.7 to 1.4), Res,
Filter Drive and Aux Env are gain destinations, Feedback, Morph and
Shaper Drive do not move at rest, OSR's self-oscillation level and pitch
(Tesseract 4.7 to 3.6), envelope segments in whole samples (loop-minatt
7.6 to 0.8), and it confirmed the Volume route's place, releases that
start inside an attack or decay, and Segno's random pan distribution.
The fit rounds pass 363 of 419 (round 8 16 of 41, round 9 23 of 29), 8
of 10 presets; the held-out round 36 of 67.

Still open:

After round 9, a pass over the held-out failures (14 deterministic, 17
random) found the Beat and Sync retrigger a sample early (Pure Bell 8ths),
the voice end at 10^−3, and the snap of a chord joining a taken voice
(Harsh FM Bass): the fit rounds pass 365 of 419, the held-out round 38 of
67. Of the random held-out failures, most fail on the attack, which
scores only the first note, against Live's three copies: Live's own
first-note pans differ from copy to copy (Bells Fifths +0.52, −0.32,
+0.03), so a small Live spread there (Pitchy Release Pluck +0.55, +0.49,
+0.59) is chance in three draws, which Segno's three seeds cannot match.

With five Live copies of each random held-out preset (39 of 67 pass), the
random failures split in two. Where Segno varies far more than Live
(Fizzling Pad: Segno's seeds 12.5 dB apart, Live's copies 4.8; Warble
Rhythm Noise Pad's attack 11.5 against 1.6), the cause is random pan
with Spread: Segno pans each of Spread's two one-channel voices, so a
draw near a side silences a channel (Segno's first Fizzling note −125 dB
on the right), while Live's copies are never more than 13 dB apart.
Placing each voice at ∓1 plus the pan brings Fizzling Pad to 3.6 dB with
its seeds 2.5 apart, but leaves its stereo width 3.8 dB off, so neither
law is Live's; round 10 (`segno-op-fit10`, 12 renders) pans Spread
fixed, by key and at random. Where the spreads agree and the score does
not (Nebulae Keys 2.6 against 0.9, Glass Wah Pad's stereo), the cause is
deterministic. The deterministic Spread presets that fail on stereo
(Major 3rd Lead, Full Perc Pluck, Tesseract) do so below 160 Hz only, in
bands 40 to 60 dB under the loudest: onset and release transients, and
Tesseract's self-oscillation, where Live's two voices ring less in phase
than Segno's; round 10's three copies of it are identical, so Live's
self-oscillation is not random. Basscycle Aftertouch's
pitch error is the tracker on a 23 Hz fundamental beating with Spread
(rounding its velocity Coarse down instead is 2.6 dB worse); Wobbly Flag
Bass is MS2 driven at a 30 Hz cutoff, the open drive case.

Round 11 (`segno-op-fit11`, 45 renders) settled the rest of the held-out
questions. With random pan off, Fizzling Pad and Glass Wah Pad repeat
exactly in Live's copies, so Spread draws nothing per voice beyond its
pans; the variance left on the random presets is Segno's three seeds,
whose first draws (0.77, −0.83, −0.98) all land near a side. The 509 Hz
sample-and-hold LFO matches Live into pitch and into a filter; Nebulae
Keys still misses 12 dB at 1.6 kHz with its LFO on (and matches with it
off), where the LFO also moves operator A's volume at audio rate, which
Segno evaluates per 32-sample chunk. Interpolation off: Live's truncated
table read matches Segno's (saw at C4 and C6, sine at C6, FM, all within
0.4 dB). Warble Rhythm Noise Pad with random pan off is deterministic in
Live and misses 2.4 dB on its Noise Looped operator (Live's table is its
own).

A pass over the 28 failing held-out presets by kind found 17 random
(random pan, random phases, sample-and-hold or noise) and 11 not. Of the
random ones, eight fail only on the attack or on Segno's own spread, from
the first note's pan: Segno's three seeds draw it at +0.77, -0.83 and
-0.98 of the range, Live's five copies anywhere (Bells Fifths +0.93,
-0.38, +0.16, +0.24, +0.12; FM Piano Simple +0.88, -0.69, +0.08, -0.54,
-0.31), and a chord's notes draw apart in Live as in Segno. Two fixes came
from the deterministic ones: a stolen voice's note waits for the fade
(Rhythmic Pong Bass 1.72 dB to 0.4, its round 8 copy 2.6 to 0.4; Smack
Kick 1.80 to 1.59, its copy 2.13 to 1.71), and
the 16-sample control rate (Nebulae Keys 2.6 to 1.0, round 8 and 11's
copies 2.9 to 1.2); the fit rounds pass 391 of 452 (from 387), the
held-out round 41 of 67 (from 39); with the scorer's five seeds the fit
rounds pass 399 and the held-out round 48.
Release Bass, whose C5 opens a Clean
filter from closed through 108 semitones of envelope, matches Live's
onset better with the old 32-sample first block (1.1 dB against 1.5), so
the filter's own control rate may differ from the gains'. **[open]**
The fit rounds do not settle it: holding the filter's targets on a
32-sample grid (the gains at 16) moves none of the 63 fit renders with a
filter envelope or the filter LFO by more than 0.1 dB, and brings
Release Bass to 1.2; round 12's fenv-onset renders isolate it.

Sweep Wobble's pitch multiplier: the fit renders rule out a cap at 2.5,
the value that holds the held-out render's match past the wrap. Noise
Slow Sweep Pad's round 8 copies reach a multiplier of 3 at audio rate
and match Live uncapped (a cap at 2.5 takes their pitch from 18 cents to
115), and Synth Reso Sweep 16ths fails with it (1.50); a cap at 3 is
neutral there, cannot reach the held-out render (its multiplier peaks at
2.74) and brings the round 8 copy only from 2.16 to 1.92. So the wrap
mismatch is not a plain limit; round 12's lfo-zero renders take the
amount through 0.6, 0.8 and 1. **[open]**

MS2 under a loud input (Wobbly Flag Bass, the circ2-saw renders; the fix
belongs in `ms2_section.h`, shared with Drift). The section's linear
response matches Live: white noise through it at resonance 0.25, 0.75 and
24 dB stays within 0.4 dB per half-octave up to 11 kHz. A full-level Saw
D at C3 through it at 1 kHz, resonance 0.5 and no drive (circ2-saw-r05)
does not: the unfiltered wave matches to 0.1 dB at every harmonic
(wave-10), while through the filter Segno's harmonics from 1.3 kHz up are
too strong, +0.6 dB at the 10th, +2.1 at the 16th, +3.9 at the 20th, +5
at the 22nd to 24th. Wobbly Flag Bass shows the same thing driven, 2 to 8
dB too bright above 1 kHz on every note. So Live's section loses more of
a loud waveform's top above the cutoff than Segno's does, while small
signals pass alike. What was tried, on a copy: a linear transconductance
(worse, +7.5 dB at the 24th), a linear diode (worse), wider buffer clips,
six solver passes and 2x oversampling (no change, so it is not aliasing
or convergence), a larger KAPPA (0.6 passes circ2-saw-r05 but takes
circ2-r075 from passing to 3.1 dB) and a tanh transconductance (circ2-saw-d12
4.8 to 3.1, the noise renders worse). What would need to change is the
large-signal shape of the first integrator's transconductance, or what
feeds it, without changing its small-signal slope: it has to compress
the saw's edges (normalized input near 1.3) harder than the present
z (1 - z^2/4 + |z|^3/16) does, while noise (normalized rms near 0.4)
passes as now. Drift's filter II renders would have to confirm the same
shape. **[open]**

Round 12 (`segno-op-fit12`, 23 renders) asks Live: a 1.1 kHz sine LFO
into Volume, an operator's volume, Pan, FM Drive, Filter Freq, Tone and
the pitch (the images around multiples of the block rate give each
destination's control rate); the 509 Hz sample-and-hold into operator A's
volume alone, three copies; a mono and a two-voice triad and a Retrigger
Mode repeat (the steal wait); a slow Saw Up on the pitch at amounts 0.6,
0.8 and 1 (Sweep Wobble: Segno matches Live's first LFO cycle at -20 dB
and loses it at the wrap, where the pitch multiplier reaches 2.7; capping
it at 2.5 holds the match, so Live limits it somewhere); a closed filter
opened by its envelope at a note's start, with and without the Hard
shaper; five copies of random pan at 100 % (in round 9 all three copies
put the first note hard right).

What round 12 settled: the control rate per destination, the steal wait
and the two filter routes (above). The 509 Hz sample-and-hold into
operator A's volume alone passes within Live's own spread. The filter
envelope's first block does not explain Release Bass: a closed Clean
low-pass opened by its envelope at a C5's onset, with and without the
Hard shaper, passes at 16 samples (0.46 and 0.69 dB) and holding the
filter's targets for 32 changes it by under 0.1 dB. The five copies of
random pan at 100 % start at +0.02, +1.00, -1.00, -0.05 and +0.90, so the
first draw is not special (round 9's three hard-right starts were
chance). The pitch multiplier through zero passes at amounts 0.6 and 0.8
(multipliers up to 2.28) and misses at 1 (lfo-zero-a100, 1.55 dB, -1 to
3): no limit fits (a cap at 2.5 gives 3.5 dB, a floor at 0 or -0.5 3.5
and 2.5), the first 60 ms match best with the LFO 0.6 % faster (-29 dB
waveform error against -12), and the match is lost at the saw's wrap
whatever its smoother's cutoff or order. Sweep Wobble stays open with
it. **[open]**
With round 12 and five seeds the fit rounds pass 413 of 469 (the
earlier rounds still 399 of 452, round 12 14 of 17: cr-tone, lfo-zero-a100
and rndpan1st's attack fail), the held-out round 48 of 67.

A pass over round 12's open questions. The LFO into Tone was never a
smoother: Tone's low-pass acts on the modulator's change and the carrier's
phase accumulates it (op-01 4.3), so a moving Tone leaves its offset
behind; with that and no smoother, every carrier line and sideband of
cr-tone lands within 0.8 dB (12.8 dB rms to 0.3; strict tf 5.9 to 1.5).
The pitch through zero is the plain 1 + L: Live's carrier phase, followed
sample by sample, matches it everywhere but at the saw's wraps, where
Live's fall starts about 20 samples early and its cycles average 1/256
low, as a saw whose last 1/256 of a cycle turns back linearly does; the
reading's 200 Hz smoother stays (lfo-zero-a100 1.55 dB to 0.61, -a80 1.44
to 0.63, -a60 0.72 to 0.39; t-sweep-wobble 2.16 to 1.88, still failing).
PRD's high-pass is now a ladder of high-passes (Filter and shaper), from
3.7, 5.9, 2.4 and 3.8 dB on circ4-hp, hp-prd-r1, -24 and -f300 to 1.8,
2.2, 1.5 and 2.5. Warble Rhythm Noise Pad's Noise Looped table repeats
from one Live Set to the next (the fine spectrum of round 11's
warble-nornd correlates 0.99 with round 8's copies, Segno's 0.93), so a
reader could describe Live's loop generator under the owner's rule for
deterministic random generators. With the scorer's round 8 (ten
seeds for random renders) the fit rounds pass 419 of 469 (from 415
re-scored: cr-tone, lfo-zero-a100, circ4-hp and hp-prd-24 added, none
lost), 9 of 10 presets; held out 50 of 67 (from 49: Sweep Wobble, 1.87 to
1.43).

Noise Looped from the reader's description of Live's generator (op-05):
the table, its seed and its low-bit mapping, and the read at the advanced
phase, which every operator shares (Live's sines read one increment ahead
of the note too). wave-20 2.33 dB to 0.09, fm-b03 5.28 to 0.01, Acid
Bass 1.19 to 0.71; held out Soft Warm Brass 1.07 to 0.57, Geigerzaehler
Bleep 1.13 to 0.97, Rhythmic Pong Bass 0.44 to 0.28. Warble Rhythm Noise
Pad does not move: its Noise Looped operator sits behind a 71 Hz Morph
filter, 70 to 90 dB under the rest above 1.2 kHz, and its misses are in
the low bands of the later notes. The fit rounds pass 423 of 470 (fm-b03-r2
now scored on its own), held out 50 of 67.

Round 13 (`segno-op-fit13`, 26 renders) asks Live: a square, a saw down,
a smaller amount, two other rates, a sine and a triangle and a High-range
saw on the pitch (the smoother alone, the saw's turn on both slopes and
how it scales); Release Bass with random pan off and taken apart (its
LFO, filter, pitch envelope, shaper); OSR at 300 Hz under a C2 sine at two
levels and resonance 0, 0.5 and 1 (which stage adds the even harmonics);
MS2's loud saw at half and quarter level and at resonance 0 (whether the
diode's feedback brightens it).

- OSR self-oscillating near its input's pitch (17 cents at a 300 Hz
  cutoff on a 262 Hz sine; the input level moves the pull little and the
  ringing level much).
- Beat and Sync retrigger detail (Rhythmic Pong, Sweep Wobble, Noisy
  Triple Beat, Full Perc Pluck), the free LFO's first-block chords, the
  circuit drive renders, PRD's and MS2's high-passes.
- Random renders whose seeds Segno draws differently: Pitchy Release
  Pluck and Fizzling Pad put their first notes at the sides, so Segno's
  spread exceeds 1.5 times Live's; rndpan-100's first note is hard right
  in all three Live copies.
- Wobbly Flag Bass (4.1 to 4.3 dB), Tesseract's stereo, Full Perc Pluck,
  Creep Bass's release tail.

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
  law, -3 dB a side at centre). **[code]** **[measured]** (Live over
  Segno 1.0000 in every round; an earlier note here had it 0.0206 dB
  lower, a measurement against a build with the wrong output gain)
- The Mod envelopes, both LFOs and the matrix run once per 16 samples; the
  oscillators, filters and Amp envelopes every sample. Macros and gains
  glide over 5 ms. **[code]**
- Engine B starts (pitch, phase, envelopes) after Engine B Delay, floored to
  16 samples. A voice ends when every Amp envelope is idle and its output
  has stayed at or below 0.0002 for 10 ms. **[code]** Measured on
  nloop-55-notes, where one voice plays five notes and its Noise Loop
  generator runs on from note to note, so each note's noise shows how many
  samples the note before ran: the count starts on the Amp envelope's last
  release step, the level is 0.0001 x Volume on the output's |L + R| (the
  reading's 0.0002 before the device's 0.5), and the oscillators stop on
  the sample the 480th quiet sample ends, not at the end of a 16-sample
  tick. Live's notes ran 26878, 26998, 26878, 26878 and 26878 samples (the
  second's tail crosses the level 120 samples late); Segno's now do, and
  every note matches Live's to the sample. **[measured]** Round 12's
  nloop-55-vol05 (Volume 0.5) ends each note on the same samples, so the
  level scales with Volume, and nloop-55-u2 (two copies) ends each note on
  Live's sample too. **[measured]**

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
- Sub: two coupled-form ("magic circle") sines, one an octave down and one
  two octaves down, with no table and no phase. At every control tick
  (the note's first sample, then every 16 samples) the frequency is sent
  again and both states are rescaled to x^2 + y^2 = 1. The recursion keeps
  x^2 + y^2 - e x y instead, so each rescale steps the amplitude by up to
  about e/4: lines at |n f/2 - 3000 Hz| on high notes. Macro 1 drives K =
  1 + 64 (M1/3)^2 into a saturator on K (sine + 0.3), sign(v) 0.92167 a
  (2 - a) with a = min(0.625 |v|, 1), flat beyond 1.6, and mixes it in at
  M1 through a 5 Hz bilinear high-pass whose state runs on from note to
  note. Macro 2 adds the lower sine at 2 M2^2.5 (Meld's fast pow) after
  both. The macros ramp over 5 ms in N - 1 steps; the saturator takes the
  value from before each step, so a ramp ends a step short. A note starts
  both sines at (cos, sin) of its phase. **[code]**
  (segno-re-findings/md-08-sub.md) The A6 renders (sub-m032, -m064 and
  -m100-n93) now match Live's to the sample, tf 8 to 20 dB to 0.00.
  **[measured]**
- Swarm Sine/Triangle/Saw/Square: 2 x 12 voices at the ratios of 9 voicing
  stacks crossfaded by Macro 2, each drifting in pitch by up to 0.13 M1^2 +
  0.002 over 0.32..0.65 s segments, random phases at each note, x 1/sqrt 12.
  **[code]** The stacks follow the reading's counts of unison, octave,
  fifth, fourth and third entries. **[Segno]**
- Harmonic FM (and Fold FM's core): an entry's modulator is the oscillator
  of its parity, so when Macro 2 crosses an entry the ratio it keeps runs
  on and the one it brings in takes the phase of the one it drops.
  **[measured]** (tr-rich-n-reich, an LFO moving the ratio across an
  entry: Live runs on without a kink, every 50 ms in phase with Segno
  after the change; per-entry phases from the note start or new entries
  from 0 part from Live at the crossing)
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
- Noise Loop: Live's generator, written from the reader's description
  (`segno-re-findings/rng-01-drift-meld.md`, section 2). A two-word
  xorshift from a fixed seed fills three ring buffers of a tenth of a
  second with raw noise, backwards, when the oscillator is built, so the
  noise is the same in every voice and every instance. Every sample it
  records one more draw, low-passed at 2.5 kHz, into the writer buffer;
  two refresh taps half a cycle apart, at (119.76 M1^3 + 0.24)/2 Hz, hand
  the writer's buffer to a reader when they wrap, with a new random level;
  each reader plays its buffer backwards through two heads half a loop
  apart, mixed through x(2 - x) windows set by Macro 2, then a high-pass at
  f/2 and a gain of (2 - M2) 1.25 sqrt(rate/44100). A note resets only the
  phases and the filter. **[code]** Segno keeps the buffers outside the
  oscillator's per-type state (57.6 kB per oscillator at 48 kHz). The note
  frequency it reads follows the same fast 2^x as the description's pow:
  with it, the round 11 renders at C0, C1, C2 and C4, nloop-00-notes and
  every Noise Loop fit render pass, and the first note of a phrase matches
  Live to the sample. **[measured]** Every later note matches too once the
  voice ends as Live's does (Structure, above). With it the strict score passes 528 of 618 fit renders (13 of
  21 presets) and 27 of 84 held-out; the four Noise Loop presets are now
  as deterministic as Live's (Elizabethan Gloom tf 4.12 to 2.15, The
  Rhythm 3.97 to 3.44, PolyPlucks 2.43 to 1.90 dB).
- The Filther's DC blocker starts settled on its saturator's bias, so a
  note through it rises from silence (woozy-a: Live's Square 5th through
  the Filther rises over its attack; unsettled, the blocker stepped to
  0.08 at the first sample). **[measured]**
- Filtered Noise: white noise through a low-pass and a high-pass around
  f 2^(4 M1 - 2), 6 octaves wide down to coincident, then resonant, with a
  level that compensates. **[code]**
- Bitgrunge: the parity of counter bits a..b, a square or a Walsh pattern
  whose counter skips a count at fixed counts, the same on every note and
  in every instance: a table of the 161 skips Live makes in 3 s at Macro 2
  1 (osc-20-1010 at C3 and grunge-notes at C4 give the same counts;
  scratchpad `meldfit/meas/grunge.py`). **[measured]** Past those 12550
  counts the table starts over, and below Macro 2 1 a share 2 M2 - 1 of
  the skips is kept, picked by a golden-ratio sequence. **[Segno]**
  (osc-20-1010 strict tf 4.61 to 2.05 dB) Crackle: Poisson noise bursts,
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
- Vowel: four parallel band-passes of one resonance, 1/k = 5.5 + 16.5 M1,
  at five vowels Macro 2 crosses (0, 0.25, 0.5, 0.75, 1), formants moving
  linearly in hertz between them and 0.4 octave per octave of Frequency
  (640 Hz plays the table as it is). The table (Hz, dB re the first): 800,
  1148 -4.3, 2791 -20.9, 3481 -41.5; 400, 1595 -24.4, 2692 -30.7, 3287
  -38.7; 350, 1695 -20.2, 2691 -31.0, 3686 -38.1; 450, 799 -9.2, 2819 -16.2,
  3487 -30.0; 325 (-0.6), 699 -12.8, 2521 -31.5, 3487 -43.3. **[measured]**
  (round 11's vowel-* renders, a C1 saw's harmonics through the filter,
  fitted within 0.54 to 0.58 dB rms from 60 Hz to 9 kHz; scratchpad
  `meldfit/meas/vowel_fit.py`; filt-12 strict tf 7.47 to 0.26 dB, every
  vowel render passes)
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
  level. x runs in double precision: in float its steps drift a tenth of a
  sample over a release, and Live's release over Segno's then rises to
  1.006 at its end, where in double it stays 1.0000 to the last sample
  (nloop-55-notes). **[measured]** A note's Amp attack takes the time the
  matrix sets at its first tick: an attack of 0 the matrix lengthens is
  played, not skipped (round 12's aat-note-n67, -n72 and -n81, Note into
  an attack of 0 at 0.44, match Live's to the sample; aat-note-a01-n72
  from 0.1 s likewise). Engine B's first tick takes B's own attack, before
  the matrix moves it: round 13's aat-note-b-n81 and -b-oct-n81 (4.6e-5 s,
  Note into it at 0.28) are at full level at once in Live and match to
  the sample that way, tf 8.5 dB to 0, while the same route on engine A
  lengthens the attack (aat-note-a*). **[measured]** Loop modes: None, Trigger (ignores note-off), Loop (the tail, then
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
  9.2 to 2.9)
- An LFO that does not retrigger runs from its voice's first note on, at
  its free rate while the voice is silent: free1- and free2-mono and -poly
  (a 2 Hz LFO into pitch, notes at 0, 1.25 and 2.6 s with silence between)
  start the notes at phases 0, 0.5 and 0.2, Mono and Poly, LFO 1 and LFO 2
  alike; a voice that never played starts at 0, so Poly's fresh voices
  start there. **[measured]** Its phase at a note is the free rate times
  the voice's age: Key Ups (Mod envelope into LFO 2's rate) is tf 2.22 dB
  that way, 5.23 when the modulated rate carries over from the voice's
  earlier notes. **[measured]** (training phrase: Werkstuecktraeger 6.56 to
  2.82, Rich N Reich 6.13 to 2.75, Key Ups 3.95 to 2.22; held-out Dusty
  Chords, Death Kicks, Whley, Rich N Reich each 1 to 2.5 dB down) Its
  draws count one per cycle of that age. **[Segno]**
- Spread positions: copies at symmetric positions in [-1, 1]; a single
  copy takes its note's arrival slot among the voice count.
  ResetToVoiceOffset starts a unison copy's phase at frac(6 x the
  position), unscaled by Spread. **[code]** **[measured]** (the unison
  renders, Happy Chords' engine B) A single copy's starts at frac(6 x its
  Spread source), the position times Spread. **[measured]**
  (tr-detuned-string-machine, a Poly patch at Spread 0.85, plays every
  note in phase with Live's that way, attack 2.94 to 0.14 dB;
  tr-gametal's first note likewise)
- A note on a silent voice starts the oscillator as Reset does, Reset on
  or off: reset-off's two notes start at the sine render's phase in Live.
  **[measured]** A legato restart of a ringing voice lets the oscillator
  run on, Reset on or off: the held-out The Rhythm's Noise Loop and Plate
  Kick's FM run on through it in Live (tr-gotta-catchem tf 8.20 to 7.24 dB and level
  2.01 to 0.54, tr-comb-bass and tr-bully-bass pass). Tarp, whose phase
  comes with its sweep, restarts as Reset says (the Thunder Kick renders
  pass that way only). **[measured]**
- The drive (two tanh stages after up to 18 dB in) and the limiter (4:1
  above -6 dBFS, 10 ms attack, 100 ms release, at the device's level) run
  per copy. **[code]** **[measured]** (where the limiter listens) The
  limiter hears a peak envelope (an instant rise, the release's fall), not
  each sample's level: round 13's saw 12 dB up holds its peak at 0.712 in
  Live, which the sample's level lets through at 1.04 (lim-u1, -u2, -u3
  and -u2-vol05, tf 3.30 to 0.54 dB, level 3.27 to -0.05 dB). **[measured]**

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

Round 10: free LFOs run through silences (above). Live's Noise Loop
plays the same samples on every note and in every instance at Macro 1 0
(no refresh within a note), and the same per instance but not per note
at Macro 1 0.5 (refreshes carry on from note to note): its noise is a
fixed sequence, which would have to be measured sample by sample through
the loop's crossfading heads and high-pass; not done. The Filther at 20
kHz under a loud chord matches at three input levels, so Happy Chords'
0.55 dB is not the Filther. Bitgrunge's skips are a table (above).

Traced, not yet fixed: Comb Bass's and Whley's errors sit in the bands
their Vowel filter shapes (Comb Bass 2 to 4 dB low at 1.4 and 2.8 kHz,
2 to 3 dB high at 5.6 kHz), and the Vowel's formants are Segno's own;
Bad Maths Arp is 4 to 5 dB low below 300 Hz, where engine B's Bandpass
sweeps ten octaves with LFO 2. Happy Chords' 0.55 dB stays with one copy
instead of two, without Spread's offsets and in Poly, and amp modulation
before the filter does not remove it. Round 11 asks for Noise Loop read
back (C0 to C4, Macro 1 0 and 0.5), Chord halfway between chord types,
Happy Chords' engine B at velocity 100 and 127 with and without its
Filther, and the Vowel filter at each vowel, three frequencies and two
Macro 1 values. With Live's spread from five instances the held-out
round passes 19 of 84.

Round 11: the Vowel filter is measured (above); Chord switches its type
at each twelfth of Macro 1 as Segno does (the four halfway renders pass);
Happy Chords' engine B is 0.54 dB loud at velocity 100 and 127 alike and
0.59 without its Filther, so neither velocity nor the Filther; its
envelopes are linked to engine A's (sustain 0.546, gain-modulated by both
LFO 1s), where the level parts from Live after the first 0.1 s (Segno
0.4 to 0.7 dB above). Noise Loop: Live's output at every note is
periodic at the note's period within 0.92 to 0.99 correlation, its level
steady for 4 s at Macro 1 0; least squares under Segno's read-head
model (two heads half a loop apart, triangular weights, linear
interpolation, its high-pass) leaves 8.5 % (C4) to 20 % (C2) of the
signal unexplained, so the read-head law is not Segno's and the buffer
is not recovered yet (scratchpad `meldfit/meas/nloop_fit*.py`). With the Vowel
table the strict score passes 522 of 618 fit renders (13 of 21 presets) and
24 of 84 held-out (Comb Bass, Whley, Kaneda Sunrise, Exquisite
Wasteland, Stellar Saws join; tf mean 4.05 dB).

The held-out round sorted by kind (2026-11-26): of its 57 failures, 25
render the same in every Live instance (12 of them Mono), the rest are
random (Swarm, Pulsate, Rain, Crackle). Four model details showed across
many presets and were fixed on fit renders: the voice end (Structure:
the Noise Loop notes after the first, and which slot a later Poly note
finds free, Gametal's A5), the legato restart that lets the oscillator
run on (Voices), a single copy's voice offset from its Spread source
(Voices), and Harmonic FM's modulators by parity (Oscillators). With them
the strict score passes 537 of 618 fit renders (14 of 21 presets; nloop-55-notes, osc-17-00, Old
School Raver and six training phrases join, none drops out) and 32 of 84 held-out (from 27; tf mean 4.02 to 3.88 dB)
(Bully Bass, Detuned String Machine, Elizabethan Gloom, Gametal, Key
Ups, The Rhythm, Rich N Reich join; Plate Kick and Whley drop out by
under 0.15 dB of tf; Granny State, failing either way, goes 8.8 to
12.1 with the FM parity). Open, with round 12 requested: Live's Sub at high
notes carries lines on a 40 Hz grid about each harmonic (aliases of a
clip Segno's is smoother than), which Vertical Bass's and Woozy Bass's
A5 show 20 to 28 dB above Segno between the harmonics; the Note source
into an Amp attack of 0 (Neurotimbre: Segno skips the attack the matrix
sets, but playing it leaves the A5 short of Live's harmonics); Tarp's
legato restart (Thunder Kick's chord); Club Kick 2 dB loud; and Poly
Plucks, whose Noise Loop follows Live's at 0.99 correlation while its
level wanders 2.5 dB as an LFO moves Macro 2 across 0.5, where the
refresh levels switch on.

Round 12 answered: the voice end's level scales with Volume and holds in
unison (nloop-55-vol05, nloop-55-u2 end each note on Live's sample once
the envelope runs in double precision); Note into an Amp attack of 0 is
played (aat-note-*, every one to the sample); Harmonic and Fold FM
crossing entries under an LFO pass as they are (hfm-cross, ffm-cross), so
Granny State's trouble is elsewhere; Tarp's Mono legato restart passes
alone (tarp-leg-single, -chord), so Thunder Kick's is elsewhere too.
Neurotimbre's engine A alone now matches (tf 8.2 to 0.07 dB); its engine
B, whose attack of 4.6e-5 s Note lengthens to about 3 s by the law, is
nearly as fast in Live as with no route at all (tf 14.8 dB, 3.5 without
the route), which the attacks of 0 and 0.1 s do not explain: round 13
asks for tiny attacks. The Sub passes at A4 and A5 at every Macro 1 and
fails at A6 only (tf 8 to 20 dB), where Live's has lines at 880k +- 360
and 520 Hz, on a 40 Hz grid, 41 dB down at Macro 1 0.32: the shape of a
table or rate artefact in Live's sine, for a reader to describe. Club
Kick's engines alone are each 1.6 to 1.9 dB loud with the limiter on in
unison; a limiter hearing the copies' sum brings the level within 0.2 to
0.9 dB but leaves tf at 3 and 7 dB, so round 13 isolates the limiter
against copies and Volume. With these the strict score passes 34 of 84
held-out at five seeds (from 33).

Round 13 and the Sub reading answered three of these. The Sub is now
written from the reader's description (two rescaled recursions); it
matches Live's A6 renders to the sample, and Vertical Bass passes (tf 3.0
to 0.34 dB). Woozy Bass is at 3.3 dB though each of its engines passes
alone. The limiter hears a peak envelope; with it, Club Kick's engine A is
0.3 dB loud instead of 1.6, but both of its engines still fail with the
limiter off (tf 2.9 and 6.9 dB), so the rest of Club Kick is in the
engines. Engine B's first tick takes B's own attack, as Neurotimbre's
engine B showed (tf 14.8 to 3.5 dB). Gotta Catchem's chopped bursts come
from engine B (its Noise Loop through a DFM) and drift late in Segno by
12 to 18 ms a second, resetting at every note. It is one of two factory
presets, with Don't Laugh, whose looping Mod envelope (loop mode 2) has
its times moved by the matrix: engine B's LFO 1 into the Mod decay. Both
fail, and the presets that loop that envelope with fixed times pass
(Drivetime Sine, Stellar Saws). Its engine A's LFO 1 Ramp with the rising
slew transformer is shared only by Balkan Kid and colfm2, which fail too.
Round 14 (11 renders) isolates the looping envelope under a moved decay,
by Velocity and by a slow and a 0.5 Hz LFO, and Gotta Catchem's engines
alone. Fit: 572 of 657 renders (561 of round 12's 644, from 554), 13 of
21 presets; held-out 34 of 84 at five seeds (tf mean 3.89 dB).

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
  amps; pan is constant power, at the knob's 0..127 position (0.5 is
  64/127).
  **[code]** **[measured]**
- Pitch, cutoffs, levels and the LFOs are recomputed every 32 samples;
  the oscillators, filters and envelopes run every sample, the amp gains
  ramped across each tick. **[Segno]** The amp envelope multiplies every
  sample, and a fresh copy's amps rise from 0 over their first control
  period, rate / 441 samples (108 at 48 kHz): the attack renders' gain is
  the envelope times that ramp to within 0.004. **[measured]**
- Knob positions follow the engine's 0..127 scale (0.5 is exactly 64).
  The curves: Exp(lo, hi), Lin, Sq (u^2) and, for the filter envelope's
  depth, u^4; a bipolar amount takes its magnitude through the curve and
  then its sign. **[code]**

### Oscillators

- Sine (a quintic of the phase, at 0.7), saw and rectangle (peak to peak
  1, pulse width 3.65 % to 50 %), and noise. **[code]** **[measured]**
  (the sine's level)
- The saw and the rectangle are leaky integrators of band-limited
  impulses (a sinc under a raised-cosine window, 13 zero crossings each
  side; leaks 0.9995 for the saw, 0.999995 for a sync saw and the
  rectangle). The saw rises 1/P a sample and each reset is placed as soon
  as it is under 13 samples ahead, centred on it, so the saw has no
  latency; the rectangle's edges, and a sync master's resets, are placed
  when they happen and centred 13 samples later. The sine steps its phase
  by 1/P before its output; the noise oscillator has no state. **[code:
  an-03]** **[measured]** (each oscillator's phase against its amp
  envelope on single notes, segno-analog-fit1 sine, sine-c2, saw, rect,
  rect-pw0, rect-sub1, saw-sub05 and fit5 saw-n024 to n096: all within
  0.05 sample of Live's, where the earlier model had every oscillator 13
  samples late; the noise source stays 13 samples late, as measured
  before)
- A voice's oscillators keep their state from one note to the next:
  nothing resets a phase at a note. Selecting a Waveform (or Sync mode)
  sets where they start: the sine at phase 0, the saw halfway up its ramp
  with its integrator at 0 (with a sub it starts s/2 off centre and leaks
  back), the rectangle at the start of its low part with its integrator at
  w + s/2, its mean for the pulse width it was selected with (a sync
  rectangle plays no sub, so it starts s/2 low), the next sample a pitch
  tick. A new Waveform or Sync mode restarts that oscillator in every
  voice. Any parameter change sends an idle voice's period back to the
  oscillator's own pitch, its phase kept. **[code: an-03]** **[Segno]**
  (every idle voice at once; Live resets one voice a processing block)
- C4 sits 0.98 cent below equal temperament at every C the renders play.
  The keyboard pitch (with the unison offsets, the vibrato and the pitch
  envelope) goes through the engine's cubic 2^x, exact at whole octaves
  and up to 1.3 cents sharp between: a mono G4 sits 1.16 cents sharp, the
  poly chord's E4 and G4 as the cubic puts them. The oscillator's own
  octave, semitone and detune, and the LFO, go through exact ones (the LFO
  renders fit closer so). **[measured]**
- Sub: a square an octave down, Exp(0.01, 1). Sync: a master at the note
  and a slave at Exp(1, 20) times it (the sine does not sync, and set to
  Sync it has no sub either: segno-analog-fit4 Soft Morning Keys with amp 1
  off from 3.9 to 0.2 dB); at a ratio
  of 1 the master still resets the slave, which moves the saw half a
  period against an unsynced one (Saw Pure Brass's chains beat in Live's
  phase only so). **[code]** **[measured]**
- Octave, semitone and Detune (+-1/4 octave as a square), a pitch
  envelope of Exp(0.01, 6) octaves falling to 0 over Exp(0.01, 10) s, LFO
  to pitch and to pulse width. Key tracking (Mod 1) at 0.5 is 1.
  **[code]**
- The pitch reaches the oscillator only on its tick: the counter reloads
  with 40 and the tick falls on the sample that finds it at 0, so ticks
  are 41 samples apart. A tick steps the pitch envelope down, takes the
  period the pitch input of that sample asks for (keyboard, unison offset,
  vibrato, LFO, pitch envelope) and ramps the period there linearly over
  the next 40 samples; the tick's own sample still runs at the old period.
  The pitch envelope starts at 1 at the gate and falls 1/N a tick for N =
  int(T rate / 40) ticks, T = Exp(0.01, 10) s, so it lasts T 41/40. A
  fresh voice's period starts at the oscillator's own pitch (C4 at its
  octave, semitone and detune, no keyboard), and its first tick, on the
  note's sample, ramps it to the note: a C2 note runs 35.5 samples ahead
  of a C2 begun at its pitch, a C5 12.5 behind. **[code: an-03 0.1, 1.1]**
  **[measured]** (sine-c2 35.4 samples, the fit5 saws from C1 to C7 within
  0.05 sample; penv-1-t015's, penv-m1's and penv7-t005 to t060's zero
  crossings within 0.5 sample of Live's over 1.2 s, which retires the
  measured factor table on the envelope's length that stood in for 41/40
  and the tick grid). A mono retrigger restarts the pitch envelope with
  the amp's. **[code]**
- Sync: the master's period ramps as the slave's does. A master reset's
  impulse lands 13 samples after it; there the slave drops to the start of
  its ramp and starts its cycle, its own resets up to there still falling
  and later ones taken back (a sync saw), or falls if it is high and
  starts its low part (a sync rectangle). **[code: an-03 1.3]**
  **[measured]** (the saw's restart at the landing, not at the reset:
  saw-sync07 from 5.5 dB to 0.42, saw-sync03 2.2 to 0.16, Saw Pure Brass
  3.0 to 1.8). A fresh sync slave starts at the oscillator's own pitch too,
  the ratio arriving with the first tick. **[measured]** (saw-sync03 and
  -07's first master cycle, attack 0.26 and 0.29 dB with the slave at the
  ratio from the start, 0.16 and 0.27 so)

### Filters### Filters

- LP12/24, BP6/12, Notch 2/4 and HP12/24: bilinear 2-pole sections,
  linear, at Exp(30, 22000) Hz and Q Exp(0.1, 120) (each stage's Q at
  most 100, LP24 at full Q 1.2 dB louder than a clamp before the sqrt
  gives); the 4-pole types cascade two, LP24's and HP24's stages each at
  sqrt(Q),
  BP12's and Notch4's at the full Q. The band-pass is the band node itself,
  peaking at Q. Below, a stage takes the Q its modulation asks for, with no
  floor: a negative envelope on Q damps it to near silence (Rhythmic Iron's
  chain 2 at a hard note reaches Q 1e-5). **[code]** **[measured]** (BP's
  level, BP12's and Notch4's Q, no floor: segno-analog-fit6 Rhythmic
  Iron's A5, 16 to 39 dB too bright at 2 to 10 kHz with a floor of 0.01)
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
  releases. Legato and Free Run as Live's switches; a free-running
  envelope ignores the key's release and runs its attack and decay, then
  releases (Zap's mono triad: its keys' release hands the voice on and
  retriggers it, and the free envelopes then play out). **[code]**
  **[measured]** (the sustain stage and the loops, Free Run)
- LFO: sine, triangle (starting at its top, the pulse width setting its
  symmetry), rectangle, sample and hold, and noise (a ramp from one cycle's
  random value to the next), at Exp(3, 1000) cycles a minute or a tempo
  division, with delay, fade-in, phase and retrigger. A retriggered random
  wave starts from a random value; a free one holds 0 until its first
  cycle ends (Live's copies of the free S&H and noise presets agree to the
  sample until then, and differ after). **[code]** **[measured]** (the
  triangle's start, the noise ramp, the random starts: segno-analog-fit5
  lfo-wave3 and its copies; segno-analog-fit6 Dual OSC Sample & Hold
  Bass's first 0.35 s from 17.9 to 0.45 dB, Overtones' from 6.8 to 0.7)
- The tempo divisions 0..23 run 16 beats down to an eighth of a beat,
  each dotted, straight and triplet (division 4 is 8 beats, 3 is 12): the
  brass presets' LFO pan cycles in 4 and 6 s at 120 BPM. **[measured]**
- Amp: Exp(0.01, 2) times the envelope, (1 + depth x LFO) and the key;
  key, envelope and LFO move the pan. The LFO's depths on the level and
  the pan are linear in the knob (Tremolo Tines' pan swing and the lfo-amp
  render). The modulated pan is not clamped: past an edge its angle runs
  on and the far channel's gain turns negative (Soft Morning Keys, whose
  envelope and LFO pans add to 1.35: Live's left channel stays 27 dB down
  where a clamp silences it, and folding the position back gives the
  levels but not the side signal; with amp 1 off from 3.7 to 0.4 dB, its
  attack from 16.1 to 0.9 dB). **[code]** **[measured]**
- A mono key change (a new key, or a released key handing the voice to a
  held one) retriggers each envelope whose Legato is off: a straight fall
  to 0 over 0.7 ms, then the attack from 0; the oscillators keep their
  phase. Each LFO with Retrigger on starts again with it, at its Phase,
  with a fresh random value, its delay and its fade-in. **[measured]**
  (the glide renders dip to silence at the key change; segno-analog-fit6
  Rhythmic Iron, whose A5 retakes the releasing mono voice: its S&H on the
  cutoff fading in again takes it from 10.4 to 5.8 dB)

### Voices

- Mono or 2 to 32 voices; the oldest released voice is stolen first,
  fading over 1 ms. Mono follows Keyboard Priority (high, low, last):
  with Low, a higher key waits for the lower one's release, and a
  released key hands the voice to the held key the priority picks.
  **[code]** **[measured]** (the glide renders)
- The device has as many voices as the Voices setting, and some state
  stays with a voice from one note to the next: a free LFO (one that does
  not retrigger) and a filter envelope with Legato on. A note takes the
  stolen voice, else one that went quiet less than 0.06 s ago, else the
  lowest idle one: a voice quiet for less than 0.1125 s is not idle, so a
  mono or poly note 0.1 s after the last takes the next device voice and
  one 0.15 s or more after takes the first back. A free LFO runs from the
  device's first note (wherever that falls), 0.07 + 0.648 Phase cycles in
  there, until its voice's first note, and from then on while the voice
  plays, for 0.1125 s after it goes quiet, and whenever another voice of
  the device sounds. (segno-analog-fit8 lvr-gap: one mono voice's LFO
  advances by the note and 0.1125 s whatever the gap from 0.15 to 0.8 s,
  by the note, the release and 0.1125 s with a 0.4 release; lvr-gap100
  alternates two voices, the first running through the second's note;
  segno-analog-fit9 lfo9-late's one note at 1.3 s starts where a note at
  0 s does. The lvr renders from 10 to 1.2 to 2.3 dB, lv-overlap4 from 13
  to 0.9, lv-steal from 10 to 1.3, Nasal Mod Lead from 3.8 to 1.5.) A
  free random wave's held values stay with the voice too. A Legato filter
  envelope
  carries its value into the voice's next note, its release run on for
  0.1 s after the voice went quiet and then held (fleg-on, fleg-on-mono,
  fleg-on-pos fit best between 0.08 and 0.12 s; running the release
  through the whole gap leaves the later notes 2 to 5 dB too bright), and
  rises from there; without Legato it starts from 0.
  **[measured]** (the free LFO renders; Rhythmic Octaves Bass's triad on
  two voices, from 127 cents median pitch error to 21; Square Pure Bass's
  triad, whose onset cells go from 11 dB too bright to within 0.1 dB;
  Muted Dark Bass and Accordion Unisono Pad, without Legato, worse with
  the carry-on)
- A voice's oscillators run on, silent, for 0.101 s after its amp
  envelopes end, then stand still until the voice's next note, which they
  start from where they stopped; a note starts them at its own sample.
  **[code: an-03 0.2]** (a voice stays on 0.1 s after its amp envelopes
  finish and is processed only while on) **[measured]** (segno-analog-
  fit9's osc9 sine, saw and rectangle gap renders, notes reused after 0.6
  s: within 2 to 4 samples of Live's phase at every note with 4848
  samples, 7 to 20 off two samples either way, with the events placed where
  Live put them). A poly note runs the oscillators of an idle voice that
  last played its key, else a voice's that never played, else the one idle
  longest; a mono device runs one. **[measured]** (osc9-rect-poly-gap's G3
  after two C3s starts as a fresh oscillator and the C3 after it where the
  first voice stopped, within 2 and 3 samples, against 61 and 89 on one
  voice; fit7 poly-saw-2notes' and fit9 st9-poly's second notes fresh,
  within 5 and 3 samples, from 284 and 226) The free LFOs keep the voice
  choice above, which their renders fit and this one does not (lv-idle2
  from 3.0 to 10.9 dB with it), so one of the two models stands in for
  something not yet known. **[Segno]**
- Glide: a one-pole on the pitch with time constant T / 2 pi, T =
  Exp(3 ms, 9 s), times sqrt of the interval in Prop mode; Legato limits
  it to overlapping notes. In Const mode the keys that arrive with the key
  that started a mono voice, or took it back from its release, do not
  glide when that key did not: a chord lands on the key the priority picks
  at once (Muted Dark Bass's triads, on a fresh and on a releasing voice);
  in Prop mode they glide (Dual OSC Buzz Octaves Bass's triad). Two
  presets inform this; the mechanism behind the difference is not known.
  **[code]** **[measured]** (T's curve, the chords)
- Unison: the copies sit 0, +1, -1, +2 steps from the note, a step of
  ExpZ(0.001, 1) octaves on 127 times the stored value (0.379 semitone at
  0.5, an octave at 1); copy k starts k times ExpZ(0.002, 0.1) s after
  the note (uni4-dly-100's copies enter at 0.1, 0.2 and 0.3 s), the delay
  int(delay rate) samples times k, and releases as many samples after the
  gate's end. Each copy is a voice of its own, switched on with the note:
  its oscillators run from then on, silent, at the device voice's last
  pitch (C4's for a fresh one), until the copy's own note retunes them at
  the next pitch tick and starts its pitch envelope. **[code: an-03 3]**
  This replaces the measured lead of 4 (kD + 13) / P cycles: the 4 (and
  the round-4 saws' 2) is the note's period over C4's, two octaves (one)
  below it, and the 13 the first tick's ramp. **[measured]** (segno-
  analog-fit8's ud8 sines, saws and rectangles, all within 0.8 dB). A copy's
  offset goes through the engine's cubic 2^x (exact at whole octaves, up
  to 1.3 cents sharp between), which puts the lower copy 0.3 cent sharp
  as the renders show. Vibrato: Lin(0.25, 10) Hz, each cycle's rate off by
  a random fraction up to Error = Lin(0, 0.2), its depth and the mod
  wheel's up to 2 semitones, with delay and fade-in. A poly voice's
  vibrato starts at 0 with each note; a mono voice's runs on through the
  silence between its notes, from the device's start. **[code]**
  (Tension's reading of the shared unison; the vibrato error)
  **[measured]** (the offsets' pattern; 0.374 semitone at 0.5; the cubic
  on the offsets; the mono run-on: segno-analog-fit6 Square Pure Bass's
  median pitch error from 0.38 to 0.04 cent, Saw Detune Sync Lead's from
  12.0 to 2.8, while running on puts Strings Detuned Pad's poly triad 5.5
  cents off)

### The fits so far

Three rounds (third-octave bands within 60 dB of each render's loudest):
the levels, routing, pan, envelopes and loops, LFO waves, glide, filters
(the formants included) and drive within 0.1 to 2.5 dB rms, the totals 1.9,
1.4 and 1.9 dB. 23 factory presets (octave bands): 13 within 2.2 dB
(Square Pure Bass 0.2, Saw Sub Complex Bass 0.3, Fifth Pad 0.8, Organ
Vibrato 0.9, Dual OSC Rubber Bass and Saw Detune Sync Lead 1.0, Noise Hit
Perc 1.1, Metalic Lead 1.2, Strings Detuned Pad 1.3, Tremolo Tines 1.9,
Bright Thin Sweep Pad and Square Sync Lead 2.0, Nasal Mod Lead 2.2); Thick
Chord Pad 2.9, Saw Pure Brass 3.2, Soft Morning Keys 3.3, Saw Filter Bass
4.3, 80s VCO Brass 4.8, Muted Wow Bass 7.4, E-Piano Muted Pure 7.8, Dual
OSC Sample & Hold Bass 12.9, Kick Complex Perc 26.5; Zap is silent on its
one note in both.

Still open: Kick Complex Perc (its pitch envelope, or filter 1 into
filter 2), Keyboard Stretch and Error, and the MPE destinations (stored,
not played).

### The strict score

The stricter score (third-octave x 50 ms cells, the first 150 ms in 5 ms
frames, side/mid per band, f0 in cents, level, onset; 201 renders) went
from 91 to 171 passing, the factory presets from 0 to 5 (Metalic Lead,
Organ Vibrato, Saw Sub Complex Bass, Square Pure Bass, Tremolo Tines),
with the oscillator starts, the band-limited steps and their latency, the
DC-free rectangle (most of the presets' 2 to 6 dB excess), the amp's
per-sample envelope and start ramp, the tempo divisions, the linear LFO
depths on the amp, sync at ratio 1, Notch4's Q, the cubic on the unison
offsets, the per-stage Q clamp, the mono retrigger and the vibrato
error. What the renders show
and Segno cannot do:

- Live's note events take effect up to 107 samples early: a note-off at
  1 s, 3 s or a glide's key change starts its release 36 to 48 samples
  before the event, as if each were applied at the start of the 108-sample
  control period it falls in (3 s is 36 samples past one, 1 s 48). Segno
  applies an event when it arrives; the release tails differ by that much.
  **[measured]**
- Random sources: the S&H and noise LFOs (Live's values differ between two
  renders of one patch), Keyboard Error (a per-note detune: the presets
  that set it sit 1.4 to 6.6 cents off where Segno plays them, both chains
  alike) and the vibrato error. Segno's draws cannot be Live's; the
  pitch metric has no noise floor, so these fail it whatever the model.
- The LFO's rate at 0.5 runs 0.4 % slow and its depth on pitch at 0.25
  0.6 % small against the curves, while the rate at 0.75 matches exactly;
  the Live round segno-analog-fit4 sweeps both.



Round 4 (segno-analog-fit4, 65 renders) settled:

- Keyboard Stretch widens the scale about A4: 0.8 cent a semitone at
  either end of the knob, linear in between (C2 26 cents flat, C7 22
  sharp at full). **[measured]**
- Keyboard Error sharpens each copy of each note by a random amount, never
  flat: up to 24 cents times the knob, u^2 of it for a uniform u (eight
  strikes at 1 and 0.5 average 7.6 and 3.6 cents, the largest 23).
  **[measured]**
- The pan is the knob position like the other knobs (0.5 sits at 64/127):
  the near-centre pans of three presets need it, and the pan renders
  cannot tell 64/127 from 0.5 (side/mid below -40 dB). **[measured]**
- Without Retrigger an LFO runs on from a random point up to Phase into
  its cycle. **[code]**
- The sine runs to 16 kHz and beyond where the saw and rectangle stop at a
  quarter of the rate. **[measured]**
- The LFO's rate follows Exp(3, 1000) per minute to within 0.4 % across the
  knob, its depth on pitch Sq(0, 4) octaves less 0.4 %; neither deviation
  is a smooth law, and both stay below the pitch metric's reach on all but
  the 0.5 and 0.55 rates.

Still open after round 4: the unison delay (a delayed copy is not the
first one shifted in time: no single delay law fits the five delay
renders' comb spectra), the pitch envelope's fall at full depth (Live's
falls about 13 % slower at 0.15 and its 6 octaves at 0.4 hold the shape),
the note events' timing (Live's note-ons land up to 85 samples before the
note, after its first note; the held-out round's deterministic presets
fail on the cells at those onsets), Kick Complex Perc (each oscillator
alone fits, the two together do not).

Round 5 (segno-analog-fit5, 49 renders, Live copies of the random ones):

- The note events' timing, settled as far as the renders go. Live's
  event renders are identical between two instances to the sample. Every
  note-off takes effect on a 16-sample grid, 8 to 43 samples before the
  note-off, and every later note-on 34 to 68 samples before the note-on,
  while the first note at time 0 starts 15 samples after it. The shift
  repeats with the event's position in its 1 ms (48-sample) chunk but is
  not a quantizer: no snap to a tick (host blocks of 16 to 1024 samples,
  ticks of 8 to 108, floor, ceiling or nearest, any offset) reproduces it,
  and a snap within the current block can only move an event later or
  less than one tick earlier. Live moves them earlier than that, which a
  device can only do with lookahead. It is a host effect, not Analog's:
  Live plays a sequence back with delay compensation, so its later events
  land early, and the first note at the song's start cannot move.
  **[measured]** A pedal plays MIDI as it arrives and never starts a note
  early, so Segno applies events when they arrive **[Segno]**; emulating
  the effect in the scratch harness moved the held-out scores by less than
  0.1 dB.
- The amps' start ramp belongs to the device's start, not to each note: a
  note at the very start rises with it, a later note does not (the event
  renders and the held-out round's mono basses). **[measured]**
- A free-running LFO (Retrigger off) is not random: two Live instances
  render it alike. A slot's LFO starts three quarters of Phase into its
  cycle (a sine at Phase 1 starts at its bottom) and then runs while the
  slot plays and for 52 ms after it goes quiet: within each strike it runs
  at the free rate, and across eight strikes 0.4 s apart it loses the
  rest of each gap. **[measured]**
- Keyboard Error over 24 strikes in three Live instances: uniform from 0
  to 22 cents at Error 1, never flat; 7.8 cents at most at 0.5 (Error^1.5).
  **[measured]**
- Velocity into the levels, the filter envelope and the attack time, the
  poly chord and the mono chords (priority high and last), the saw from C1
  to C7, key tracking at C2 and C6, key volume at C2, and drive pushed to
  full level all match Live. **[measured]**

Open after round 5, with what the renders show:

- Kick Complex Perc: starting chain 2's sine half a cycle on takes its
  over-time error from 26 to 1.0 dB, but breaks Dual OSC Rubber Bass, so
  the two pitch-swept sines' phase relation goes wrong elsewhere, most
  likely in the pitch envelope's fall (Live's at full depth and 0.15 takes
  about 1500 samples where Exp(0.01, 10) gives 1330, while 0.3 and 0.5
  fit; a longer time at all settings breaks those).
- The vibrato error: Live's mean rate across a note moves by up to 11 %
  between instances, but a per-note deviation fits worse than the
  per-cycle one; neither width helps.
- The unison delay, as after round 4.

Round 6 (segno-analog-fit6: 38 presets that fail the held-out round, on a D2
at 64, an F4 triad at 90 and an A5 at 120, with Live copies of the random
ones) shows what separates them on unfitted notes:

- The deterministic mono basses (Muted Dark Bass, Square Pure Bass, Saw
  Sub Complex Bass) match Live's level within 0.3 dB while each note
  sounds; they fail on the cells at the later notes' onsets, where Live's
  note starts abruptly (a broadband click from the first sample) and
  Segno's rises smoothly. Moving Segno's onsets by up to 60 samples does
  not change those cells; letting a mono slot's oscillator run on through
  silence helps Dual OSC Rubber Bass and hurts Muted Dark Bass. Open.
- Square Pure Bass's A5 decays 6 dB faster in Live than in Segno, its D2
  not at all: a key or velocity dependence of its filter envelope's
  closing that no fit round has isolated. (Its triad's onset was the
  Legato filter envelope carried from the D2; see below. The A5 still
  starts 10 dB too bright at 2.5 to 10 kHz.)
- Organ Church Slow's triad has 12 dB more at 10 to 16 kHz in Live, where
  chain 2's key-tracked high-pass at Q 100 rings near its cutoff.
- Dual OSC Buzz Lead plays in Live's level here (0.9 dB, its pitch
  matched); its held-out loud notes (+7.6 dB) do not come back on these
  notes. Starting a mono voice once for a chord's keys, without a
  retrigger between them, made the other mono presets worse.

After round 6 (no new renders; strict score with per-note alignment of
+-1.5 ms; base a5fcb20d4 scored the same way: 239 of 345 fit renders, 17
of 79 factory-preset renders, 10 of 58 held out, median held-out tf 3.90
dB; now 246 of 345 and 17 of 79, 10 of 58 held out at a median of 3.89 dB):

- The pitch envelope: Live's oscillator updates its period every 40
  samples and ramps to it, the first ramp from the unmodulated period, and
  the envelope falls 2 to 4 % slower than Exp(0.01, 10). Kick Complex Perc
  from 26.3 to 0.4 dB (its noise-off variant 26.7 to 0.4, passing),
  penv-1-t015 0.8 to 0.3, penv-1-t04 0.8 to 0.5; round 7 settled the
  factor per time knob (above).
- The cubic 2^x on the keyboard pitch: the mono chords' G4 from 1.17
  cents off to 0.01, the poly chord from 1.5 to 0.5 dB.
- Free Run ignores the key's release: Zap from 24.9 to 9.2 dB (held out
  24.8 to 8.8); what is left is Live's onset hump (below).
- State per device voice: Rhythmic Octaves Bass from 16.8 to 10.3 dB
  (held out 14.4 to 9.5), Square Pure Bass's triad onset within 0.1 dB;
  the chord glide rule: Muted Dark Bass held out from 7.1 to 4.9 dB.

What still differs, with what the renders show:

- Round 7 (segno-analog-fit7) passes 27 of 39 as it came in and all its
  pitch-envelope renders (time, depth, saw, rectangle) once the factor
  per time knob is in; Free Run, the second notes (but the mono sine's
  onset cell, 1.9 dB, and Live's host offset on later notes), the Legato
  carry-on and the LFO rates (but 0.35, 3.2 cents) pass.
- The free LFO's run-on after a voice goes quiet is not one time. lv-idle2
  and lv-idle4 (notes 0.3 s long every 0.6 s, on 2 and 4 voices) render
  alike in Live, so the voice a note takes is the same, the lowest idle one
  as Segno picks; between notes Live's LFO advances 0.695 cycle where
  0.418 s of running would give it (0.113 s after the voice is quiet),
  while lfo-free (0.3 s notes every 0.4 s) alternates between running
  through the 0.1 s gap and stopping 12 to 17 ms after quiet. No single
  run-on reproduces both (0.052 s keeps lfo-free, 0.13 s helps lv-idle2 and
  breaks lfo-free); Segno keeps 52 ms. The lv renders fail on pitch (120 to
  170 cents median).
- Velocity: the shared front end of Live's other AAS devices sends
  (velocity - 1) / 126; Analog's velocity renders fit velocity / 127
  better (avel-v001's level -0.01 dB against -0.21, the pv-* presets at 30
  and 64 0.05 dB closer), so Segno keeps velocity / 127.
- Release tails: every Analog render's tail ends at its release
  segment's end, within one 32-sample tick (282 ms for a release of
  282.6, 641 for 641.4, 25.1 for 25.8, 49 single-note renders); none is
  cut to silence early, unlike the 84 ms cut Tension's renders show.
- On 9 of the 17 deterministic held-out failures the phrase's quiet C3
  fits (within 1.5 dB) and the error sits on the triad and the hard C5
  (Square Pure Bass, Fourths Lead, Saw Pure Muted Bass, Muted Dark Bass,
  Saw Sub Complex Bass, Square Percussive Bass, Organ Church Slow, Kick
  Complex Perc, Glass Low Strings Pad); on the other 8 the C3 fails too. Square Pure Bass
  and Fourths Lead are mono with a Legato filter envelope: the 0.1 s
  run-on takes Square Pure Bass from 2.65 to 1.68 dB; Fourths Lead's error
  is a 5 Hz alternation at 160 to 640 Hz (its vibrato's phase against
  Live's: resetting or free-running the vibrato moves the presets by 0.1
  dB, neither fits). Saw Pure Muted Bass's hard C5 is 2.5 dB low at 160 to
  640 Hz alone (its fundamental), open.
- A saw or rectangle swept up fast starts in Live with a hump: the
  output rises over about 12 samples to twice the saw's swing, then falls
  back within 5 (Zap's later notes, peak 2.1 where Segno's is 0.6;
  penv-saw-1-t03 at the end of the first oscillator tick). It reads like
  the integrated impulse train's slope and its delayed impulses parting
  while the period falls; Segno's saw is a naive ramp with band-limited
  steps and has no such transient. Zap's tf and level and the Kick's
  attack metric (2.6, limit 2.0) come from it. segno-analog-fit7 has a
  saw, a rectangle and a half-depth sweep to model it.
- The LFO's rate is up to 0.85 % slow at some knob positions (0.3: 0.9915,
  0.45: 0.9983, 0.5: 0.9960, 0.55: 0.9962) and exact at others (0.4, 0.6,
  0.65, 0.9); no smooth law, a float phase accumulator or a truncated
  per-tick increment fits it. The lfo-pitch renders' pitch metric sits at
  2.8 to 3.3 cents from it. segno-analog-fit7 samples the knob finely.
- Square Sync Lead's held-out pitch metric (3.5 cents) is the f0 tracker's
  frame-to-frame jitter from the two rectangles a fifth apart, whose beat
  falls differently from Live's; the pitch itself matches.
- Kick Complex Perc held out (a C2, a C4 triad and a C5) went from 4.6
  to 5.2 dB while its fit renders at C2 came to 0.4: the sweep's length
  or its start differs on the higher notes, or the triad's two voices
  interfere differently (Live's voice allocation for a third note).
- Random sources (S&H, noise LFOs, Keyboard Error, vibrato error) as
  before.

segno-analog-fit7 (39 renders, exported and scored as above): the pitch
envelope's time law (a C-1 sine swept 6 octaves at eight times) and depth
law (four depths), the fast-sweep hump (saw and rectangle at C2, a saw at
half depth), a mono and a poly voice's second note, Free Run on the amp
and on the filter envelope with an early release, a Legato filter
envelope carried into a voice's next notes (negative and positive depth,
poly and mono, and Legato off), the LFO rate at eleven more knob
positions, and which device voice a note takes (a free LFO on pitch with
steals, idle voices and overlapping notes on 2 and 4 voices).

The held-out round with Live's own copies (segno-analog-val3, val4):

- Of the held-out presets random on Segno's side, Bright Thin Sweep Pad,
  Charry Pad, Dual OSC
  Plastic Bass, E-Piano Muted Pure, Fifth Pad, Movie Pad, Organ Octaves
  Slow, Overtones, Rhythmic Iron, Dual OSC Sample & Hold Bass, the three
  S&H presets and Synth Organ Long Release now pass tf within Live's
  spread; they fail on attack,
  stereo, pitch or level, where Live's copies agree with each other more
  than Segno's seeds do. Kick Complex Perc, Saw Complex Bass and Dual OSC
  Rubber Bass are deterministic in Live (tf spread 0.2 to 0.4).
- The unison delay is the shared cause of four of the eight held-out
  presets that already fail on the quiet C3 (Saw Filter Bass, Dual OSC
  Muted Sweep Lead, Accordion Unisono Pad, Strings Detuned Pad). With 4
  copies Live starts copy k at k delays (uni4-dly-100); Segno now does.
  The delay itself is not read yet: separating uni2-dly-050-sine's two
  sines puts copy 2 110 samples (mod a 734-sample period) behind copy 1,
  where Segno's ExpZ(0.002, 0.1) gives 679; the saw renders' combs fit a
  copy delay of 843 samples with a saw phase offset of -0.19 cycle, but
  the 0.75 and 1.0 renders do not fit that law. segno-analog-fit8 reads
  it directly.
- Kick Complex Perc's triad on two voices: stealing the newest held voice
  instead of the oldest takes its round-6 render from 3.4 to 2.9 dB but
  Rhythmic Octaves Bass from 10.2 to 12.9; segno-analog-fit8 plays the
  steal cases alone.
- Organ Church Slow's triad lacks 12.6 dB above 10 kHz, where chain 2's
  key-tracked high-pass at Q 100 sits at 12 to 18 kHz; neither a cutoff
  without prewarping (worse, 4.7 dB) nor a higher Q clamp moves it. Open.

segno-analog-fit8 (40 renders, built, to be exported): the unison delay
on a C-1 sine with 2 copies at ten delay settings and 4 copies at three
(each copy readable by subtracting the ones before it), a saw and a
rectangle at three and two settings (their phase against the sine's); the
free LFO's run-on on one mono voice with gaps of 50 ms to 0.8 s, with a
long release, on two voices, and a sine LFO; a third note's steal (three
keys together, in sequence, one released); Kick Complex Perc on a C4, a
C5, a triad and a dyad; Saw Pure Muted Bass on a C3, a C5, and a soft C5.

Before round 8's export, the held-out failures sorted by kind (source,
random or not, metric, phrase segment) showed seven shared causes, each
fitted on fit renders: a free random wave holds 0 until its first cycle
ends; a fresh device voice's free LFO has run since the device started;
a mono key change restarts each retriggered LFO; a stage's Q has no floor;
a mono voice's vibrato runs on through silence; a sine set to Sync has no
sub; the modulated pan's angle is not clamped (all above). Fit renders 286
to 290 of 384, factory presets 18 to 22 of 79; held out 11 to 15 of 58
(Overtones, Rhythmic Iron, Square Pure Bass, Soft Morning Keys). What the
renders show and is still open:

- Dual OSC Buzz Lead: every later note that starts a fresh voice carries
  a DC offset in Live (-0.39 at the triad, -0.24 at the C5, in all five
  copies), from the first sample and decaying with the amp; the first
  note has none. Its chain 2 is a synced rectangle with its pulse width on
  an LFO into Asym 3 drive. The offset decays with the rectangle
  integrator's 4 s leak, so it sits in that integrator, about two pulse
  heights deep. Round 6's fresh A5 (2.3 s, after the triad's release) has
  none beyond the slow swing the pulse-width LFO gives, which Segno
  already matches (+0.05 to -0.05 in both); carrying a reused voice's
  integrator value or its leak state into the new note gives at most
  +-0.16 at the held-out triad, and breaks the round-6 A5 when it carries
  the output's value with either sign. What sets the offset (the chord's
  three keys gliding on a fresh mono voice is the held-out triad's
  difference from round 6's) needs segno-analog-fit9's p9-buzz and its
  reused-voice rectangle renders.
- The oscillators' start phase: on single notes at the song's start,
  after Live's 15-sample first-note offset, Live's sine and saw lead
  Segno's by about 16 log2(P / 109) samples (P the period; C1 69, C2 46,
  C3 27, C4 12 samples), as a first oscillator tick ramping from A4's
  period would give, while the rectangle matches. Such a ramp breaks the
  pitch-envelope sweeps (penv7 attack from 0.3 to 8 dB), so it is not in.
  It sets the phase between two chains at one pitch: Dual OSC Rubber
  Bass's C5 fundamental is 13 dB low in Segno, its rectangle and sine
  cancelling where Live's add.
- Square Percussive Bass (mono, Stretch 0.825) sits 5.8 cents flat of
  Live on the held-out C3. It is not the stretch law: round 6's D2 at the
  full law fits to 0.1 cent, and its C5 and A5 sit within Keyboard
  Error's 0 to 3.6 cents above Segno's chain 1 alone. Its chains are
  detuned +11.6 and -12.0 cents and Segno's mix pulls the tracked pitch
  about 2 cents below chain 1's at every note, where Live's stays at or
  above it; the held-out C3 sits 3.6 to 4.5 cents above chain 1's in all
  three Live copies, more than Keyboard Error gives. Either the chains'
  balance or the detune law near the centre (fitted only at 0 and 0.75)
  differs; segno-analog-fit9's p9-sqperc (with a copy) and its stretch
  renders separate them.
- Live's later note events land early (16 to 64 samples at the phrases'
  times); a fixed lead in the harness moves Muted Dark Bass by up to 2
  dB but no single lead fits, and its tf is in the onset cells.

segno-analog-fit9 (41 renders, built, to be exported): vibrato across
notes on mono and poly voices and its rate; a free LFO's phase on a note
that is the device's first but not at 0 s, and on a second voice; a mono
key change against a retriggered LFO's fade, delay and phase; a reused
voice's rectangle, saw and sine (and the synced, PW-modulated rectangle
through drive, Buzz Lead's chain); Dual OSC Buzz Lead, Fourths Lead,
Square Pure Bass, Muted Dark Bass, Nasal Mod Lead, Rhythmic Iron and
Square Percussive Bass on a phrase of their own (with Live copies of the
random ones); a sine at the held-out, round-6 and that phrase's note
times (Live's event timing); Q driven below 0.01; Keyboard Stretch on mono
and poly voices.

Rounds 8 and 9, exported and scored with five seeds: fit 312 to 325 of
461 (rounds 8 and 9 alone 19 to 29 of 77), factory presets 24 to 25 of
79; held out 16 of 58 (15 at three seeds before; Nasal Mod Lead now
passes). Strings Detuned Pad gets worse with the copies' lead (round 6
from 4.2 to 5.2 dB), the one preset where it does:

- The unison delay length is ExpZ(0.002, 0.1) as read: separating the ud8
  sines' copies puts each where it says. What was wrong is the copy's
  start, 4 (kD + 13) / P cycles on, and its release, k delays late (both
  above). The round-4 saws at C3 fit 2 D / P, so the factor is settled
  only at the oscillator octave of -3.
- The steal order is the oldest first, as Segno has it: steal-tri-2v,
  steal-seq-2v and steal-rel-2v lose the key Segno drops. Their pitch
  metric reads 570 cents on the remaining dyad's subharmonic while tf is
  0.4 and 0.95. Kick Complex Perc's C4, C5, dyad and triad fail on the
  phase between its two swept sines, which is the oscillator start phase
  question above, not the steal.
- The free LFO's run-on, the device voice a note takes, and the clock from
  the device's first note: above. lvr-gap100's and lfo-free's alternation
  is two device voices, the first one's LFO running through the second's
  note.
- Vibrato across notes: a poly voice's vibrato in vib9-poly-gap and
  vib9-poly-reuse is neither restarted at each note nor free; it moves by
  0.006 and 0.1 cycle between notes 1 s apart. A mono voice's runs for
  about 0.1 s after each note (vib9-mono-gap: 0.602 s of every second),
  but modelling that breaks Fourths Lead's phrase (1.95 to 2.7 dB), so
  the mono vibrato stays free from the device's first note.
- A mono key change restarts a retriggered LFO at its Phase (lfo9-mono-
  phase: 0.500 at the hand-over); what fails there is the hand-over's
  click, in Live's earlier note-off.
- A reused voice's rectangle, saw and sine (osc9) carry no DC in Live,
  and the synced, pulse-width-modulated rectangle through Asym 3 drive
  carries the same DC in both. Dual OSC Buzz Lead's DC (p9-buzz, -0.23
  from the first sample of its 1.4 s note at 100, in both copies) is not
  that; open.
- Square Percussive Bass: chain levels within 0.5 dB per band and side to
  mid within 1 dB on p9-sqperc, so not the chains' balance; Live's
  tracked pitch sits at chain 1's plus Keyboard Error, Segno's mix about
  1.5 cents below. Keyboard Stretch is the poly law on a mono voice too
  (st9-mono, st9-mono-rect: within 0.03 cent).
- Live's event timing (ev9): the first note lands 4 samples late, every
  later note-on 12, 28 or 44 samples early (a 16-sample grid), at the
  same times in every render, and ev-offs puts 1.0 s at 44 where ev9-fit6
  puts it at 28, so the offset depends on the sequence, not the time.
  No fixed harness lead fits every render (see round 10 for the one
  that helps most).
- Q below 0.01: q9-neg-saw-v127 passes at 0.17 dB with no floor.

Round 10 (no new renders): the oscillators rewritten from the reader's
description of how Live starts them (`segno-re-findings/an-03-oscillator-
start.md`), every claim checked on the fit renders above: the 41-sample
pitch tick and its 40-sample ramp, the pitch envelope's N ticks, no phase
reset at a note, a fresh voice starting at C4, the saw without latency and
the rectangle 13 samples late, a voice's oscillators running on 0.101 s
and then standing still, delayed unison copies running at the last pitch.
The empirical forms they replace: the copies' 4 (kD + 13) / P lead, the
envelope-length factor table, the 13-sample latency on every oscillator.
Two measured additions: which voice's oscillators a poly note takes, and
the sync saw's restart at its master impulse. The scratch harness now
places events as Live's export does, as Tension's harness does: the first
note on time, every later event 48 samples earlier (Live puts the first
16 samples late and the later ones 32 early; some land 16 or 32 off
that), and a unison copy's note at the start of Live's 1 ms block it falls
in. On round 4 to 9's 116 multi-note renders that alone takes mean tf
from 2.82 dB to 2.66 and the renders within 1.5 dB from 38 to 50 (Kick
Complex Perc's phrase 2.2 to 0.3, Strings Detuned Pad's 5.8 to 0.4, the
uni2 delays 4.5 to 0.1 to 0.3). Under the round-7 rule: fit 333 to 366
of 461, factory presets 25 to 37 of 79. Under the round-8 rule (ten seeds
for random renders): fit 326 to 364 of 461, factory presets 26 to 36 of
79, held out 16 to 18 of 58. Left:

- Dual OSC Buzz Lead (p9-buzz): from its second note Live's oscillator 2,
  a sync rectangle at ratio 1 with its pulse width on a free LFO at full
  depth, falls silent and leaves its low level as DC (-0.22 to -0.33 at
  the output); Segno's keeps playing (160 and 320 Hz cells 13 dB loud).
  Its Sub/Sync knob is 0, so the reader's -s/2 is only -0.005: not that.
  A pulse width modulated below 0, which would hold the slave low, is the
  next guess; open.
- Square Percussive Bass and the other Keyboard Error presets: the per-
  note error is random, and the pitch metric has no noise floor.
- The LFO renders that reuse a voice after a gap (lvr-gap150 to 800)
  lose 0.4 to 0.6 dB, where Live put those notes 16 or 32 samples off its
  usual -32. The stretch renders (five different keys 0.1 s apart) lose
  0.6 dB: their second note starts 80 samples off a fresh oscillator's
  phase, so the voice choice for a note 0.1 s after another's release is
  not settled (taking over the voice still running on is worse, 1.6 to
  2.1 dB).
- Free LFOs and oscillators keep separate voice choices (Voices, above).


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
