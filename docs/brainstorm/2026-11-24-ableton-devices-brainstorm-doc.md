# Ableton Live device presets on the pedal — brainstorm

<!-- cspell:words adv adg Ghidra devicekit Lfo Vec analyzeHeadless gpr Wavetable wavetables ADSR BLEP BLAMP wavefolder crossfading prewarp Modwheel detuned unnormalised Clob Sallen linearised transconductance kModBy kCarriers Celesta transconductances Bandpass Bitgrunge Csound Drivetime Extratone Filther Lofi Lowpass Megatripolis Minnaert Sawstyle Starchestra polyBLEP Metalic Formant formants Barney Asym quintic Wurli MKII Schroeder Fretless Perc halvings Inharmonicity travelled retrigger retriggers unsynced Quantizer autocorrelation tfz unmeasured retriggered isolations atan filt voicecut penv Unisono pul meldfit Geigerzaehler Bellatine Keystrike Numan uncentred dfit Grimer Tesseract Tesseract's auxenv fdrive fltkey keyscale lfofree minatt noteoff penvd rndpan Bassic Bitgrunge's Catchem Filther's Kaneda Werkstuecktraeger Whley Whley's filt nloop avel fleg unmodulated Basscycle spr ccg Clav restruck restrikes restrike prewarping Floot Halfstep Gametal Plucks Neurotimbre sqperc -->

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
  the output gains 2.90 and 3.69 (they were 0.15 and 0.37 dB high); noise
  reaches filter I 2.2 dB and filter II 2.0 dB quieter than the bypass.
- Filter input: both types clip their input: linear to about +0.70 and
  -0.98, a soft knee, and a hard edge at +0.79 on the positive side. A sine
  at Gain 1 gets Live's harmonics 2 to 41 within 3 dB (the hard edge gives
  the slowly falling tail); at Gain 0.5 it stays clean. Past the knee the
  negative side rises again with slope 1 to a hard edge at -1.6 (the
  code's ±1.6 clip of the sum) **[measured]**: a saw at Gain 2 and two at
  Gain 2 into filter II at resonance 0 (round 19), harmonics within 1 dB
  rms (held at the knee, harmonics 2 to 5 were 2 to 5 dB low). The path around
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
  either way only with the reset). Not yet settled (round 24): whether a
  stopped block's filter state decays while it waits (Airfare Bass's
  triad starts between the held state and rest: tf 1.0 from rest, 1.5
  held) and what a voice never played feeds its filter with (Floot Bass's
  triad starts about half as hot as Live's).
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
  shapes]**
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
  through a smoother. **[code]** **[measured: pitch within 0.003]**
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
  -3 dB to -19, the round 8 copy 2.6 dB to 0.4; Smack Kick 1.8 to 1.6]**
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
held-out round 41 of 67 (from 39). Release Bass, whose C5 opens a Clean
filter from closed through 108 semitones of envelope, matches Live's
onset better with the old 32-sample first block (1.1 dB against 1.5), so
the filter's own control rate may differ from the gains'. **[open]**

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
  law, -3 dB a side at centre). **[code]** **[measured]** Live's output
  sits a further 0.0206 dB down: Live over Segno is 0.99763 in every
  render, plain shapes, hard pan, unison and drive alike. **[measured]**
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
  every note matches Live's to the sample. **[measured]**

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
- The saw's and rectangle's edges are band-limited steps: the running sum
  of a sinc under a raised-cosine window, 13 zero crossings each side,
  centred on the edge, so every oscillator (and the noise) comes out 13
  samples late. **[code]** **[measured]** (the phase against the
  envelope; the saw's top octave, which polyBLEP left 2 to 8 dB low)
- Where they start: the saw halfway up its ramp (its first reset half a
  period in, a sync slave too), the rectangle at the start of its low
  part, high for the last w of the cycle, with no DC offset from the first
  cycle (Live's integrator starts at its steady state: the rectangle
  renders are DC-free, which took 1.6 dB off the square's level), the sub
  square low. **[measured]**
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
- The oscillator sets its pitch on its own tick of 40 samples: each tick
  takes the period the control values and the pitch envelope's value at
  the tick's end ask for, and the period ramps there linearly across the
  tick; a copy's first tick ramps from the period without the envelope.
  **[code]** (the 40-sample tick and the period ramp) **[measured]** (the
  envelope's value at the tick's end, the first ramp's start: penv-1-t015's
  zero crossings fall within 3 samples of Live's, from 102 to 839, and its
  8 Hz tail lands in Live's phase). The envelope falls over Exp(0.01, 10)
  s times a factor of the time knob: 0.99 at 0.05, 1.04 at 0.1, 1.035 at
  0.15, 1.0275 at 0.2, 1.025 at 0.25, 1.0205 at 0.3, 1.025 at 0.4, 1.0243
  at 0.5 and 1.0245 at 0.6, linear between and flat beyond. Each is the
  best fit of one full-depth sweep of a C-1 sine (segno-analog-fit7
  penv7-t005 to t060, penv-1-t015, Kick Complex Perc), whose 8 Hz tail
  pins the length to 0.1 % on the long sweeps; no smooth law in the knob
  fits them all. **[measured]** A mono retrigger restarts the pitch
  envelope with the amp's. **[code]**

### Filters

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
  stolen voice, or the lowest idle one. A free LFO runs from the device's
  start, three quarters of Phase into its cycle there, until its voice's
  first note, and from then on while the voice plays and for 52 ms after
  it goes quiet (segno-analog-fit6 Nasal Mod Lead's triad on fresh voices
  from 8.6 to 3.8 dB, Glass High Strings Pad from 7.5 to 5.9, Organ
  Octaves Slow's stereo from 4.2 to 1.4; lfo-free's second voice enters
  within 0.013 cycle of that phase); a free random wave's held values stay
  with the voice too. A Legato filter envelope
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
  the note (uni4-dly-100's copies enter at 0.1, 0.2 and 0.3 s). A copy's
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

## Electric: behavior

Learned 2026-11-25 from Live 12.2.7's Electric engine (an AAS bundle, one
reader), then measured against 69 Live renders: single-change patches
around a centred reference, and all 17 factory presets, six of them also
two octaves down or up. Tags as for Meld. Segno's implementation is
`electric_voice.c`.

### Structure

- Per voice: a mallet pulse and a damper's noise burst excite a fork of
  four resonators, whose sum goes through a pickup. The voices sum, then
  Volume (2u^2) and the output stage, copied to both channels. **[code]**
- The output stage is a soft clip: linear up to 0.7 of full scale, then
  1 - 0.3 / (1 + (|x| - 0.7) / 0.9)^3, which meets the line in value and
  slope at the knee and tends to full scale; Live multiplies by 4 after
  it. Segno's voice levels already carry that 4, so Segno clips at 2.8
  toward 4. **[code]** **[measured]** (the scale: a loud strike peaks at
  3.85 in Live, where the unclipped voice reaches 6.4)
- The engine moves in 1 ms blocks: a note strikes at the start of the
  block after the one it arrives in. A key struck again while its voice
  still rings fades that voice out across the block, then the fork and
  pickup restart from rest. **[code]**
- Knob positions follow the engine's 0..127 scale, as in Analog. The
  linear controls whose centre is neutral (Noise Pitch, Tine < Key,
  Damper Balance, Pickup Amp < Key, Keyboard Stretch) give exactly their
  midpoint at 64, not 64/127 of the way: a centred Noise Pitch is
  519.5 Hz, not 533.7. Force < Key and Force < Vel are plain lines.
  **[code]** **[measured]** (the noise renders; whole knob steps fit the
  presets worse than the stored fractions)

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
from the strike): total 1.09 dB rms after the first fit.

The strict score (third-octave x 50 ms cells, the attack in 5 ms frames,
level, onset, pitch; `strict.py`): 65 of 69 renders and 21 of the 23
factory presets pass, from 63 and 22 before this round. The output
stage brought full Force < Velocity from 7.1 dB to 0.03 and full Tone
Bar Volume from 2.4 to 0.02; the midpoint rule brought the mallet noise
render at full decay from 3.9 to 0.7 and the pitch error everywhere to
0.00 cents. Live hands a note-off to the device at the start of the 1 ms
block that holds it, and a note's end a hair before its time, so a note
ending on a block boundary releases one block early: the fit harness
does the same, which brought Organ Soft from 0.42 to 0.02, E-Piano MKII
Old from 0.35 to 0.03 and Damper Balance 1 from 1.22 to 0.51.
**[measured]**

Live's whole output sits 16 samples later than Segno's (every render,
strike and release alike, sample for sample once shifted): a fixed
latency outside the device, which Segno does not copy. **[measured]**

Still open, all where the damper's noise rings a resonance: Stiffness 0,
Damper Balance 0, E-Piano MKII Bright (which passed before the release
change: its release burst rings the tine partial and the 10.7 kHz mallet
noise 3 and 6 dB weaker on average than Live's) and Vibes Soft two
octaves up (its 4.2 kHz mallet noise 7 dB over Live's, at C6 only).
A noise burst gives each resonance a random size per strike, so these
renders differ between two Segno renders with different noise too: over
eight noise seeds, Segno against Segno reaches tfz 3 to 8 on them, and
the attack score 3 to 5. Stiffness 0 stands out: Live's tine there is
20 dB below the mean of Segno's eight seeds. Repeated Live renders would
settle whether that is chance. The E-Piano
MKII presets lean 1 dB darker above 1 kHz. **[measured]**



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


## Tension: behavior

Learned 2026-11-25 from Live 12.2.7's Tension engine (an AAS bundle, one
reader), then measured against 75 Live renders: single changes around a
plain hammer reference and 17 factory presets, three of them also at a
second octave. Tags as for Meld. Segno's implementation is
`tension_voice.c`; the filter, its envelope and LFO, the knob curves and
the unison law are the ones Analog uses (`aas_parts.h`), as both engines
are built from the same modules.

### The string

- A two-rail waveguide: the bridge end reflects rail B, read at L plus a
  fractional extra delay e through a 5-tap Lagrange read, a dispersion
  all-pass and a damping low-pass, times -g; the nut end reflects rail A
  at L, times -g. Rail B's read sits 1.5 samples past L + e. L is fixed
  at the strike from the half period less the loop filters' phase delay
  and those 1.5 samples; e follows the pitch every tick, so glide and
  vibrato change the string's length. The length is taken from C4 =
  261.62 Hz, and the damping filter's share of the phase delay is the
  engine's estimate, an analog one-pole's atan(w / wc) / w, not the
  filter's exact delay. **[code]** **[measured]** (the reference at C6;
  with both, the references at C2, C4 and C6 keep Live's pitch to within
  1 % of the signal for 2 s, where they drifted 1.1 to 2.7 samples a
  second)
- The Lagrange read takes the five taps from L plus the whole part of e
  (toward zero), so the read point sits 1.5 plus e's fraction into them,
  about their middle, where the interpolator loses least. **[code]**
  **[measured]** (Segno's taps one sample earlier, off the middle, lost up
  to 1.2 dB a round trip at 14 kHz: on loud high notes the plucked
  presets' highs fell 10 to 30 dB short of Live's within half a second;
  Clav Bright's phrase now matches to 0.05 dB rms, the C4 bow to 0.00)
- The keyboard: Stretch scales the key about A4 (0.992 to 1.008 times,
  so C2 sits 15 cents flat at a preset's usual 0.8), Fine Tune spans half
  a semitone either way, and Error adds a random rise of up to 0.02 octave
  at each strike. **[code]** **[measured]** (the bass and guitar presets'
  pitch at C2, C4 and C6)
- The engine's 2^x, used for the string's pitch and every key and
  velocity scaling: whole octaves exactly, the fraction f by the cubic
  1 + t + t^2 / 2 + 0.200064 t^3, t = f ln 2 (exact at both ends of the
  octave, up to 0.05 % high near 0.85 of it). **[code]** **[measured]**
  (Sitar Far's parts at D2 come to Live's sample for sample with it)
- The knobs reach the curves as whole steps of the engine's 0..127 scale,
  cut to the step below in single precision. **[code]** **[measured]**
  (term-soft and the plucked presets, which a rounded step loses)
- Damping: a one-pole low-pass at Exp(200, 200000) Hz moved by its key
  amount; Inharmonicity: a first-order all-pass from Lin(0.02, 20),
  weaker on high notes. **[code]** **[measured]** (the damping knob is not
  inverted)
- Decay: the loss per reflection is 10^(-0.03 / (2 T F)), T =
  Exp(0.1, 100), so T60 is about 0.38 T; at the release it ramps over 8 ms
  to Ratio (ExpZ(1, 1000)) times faster, or no loss at all at Ratio 0.
  **[code]**
- Above the struck pitch (a bend up) the string stays at its strike's
  length and a pitch-synchronous two-tap shifter on its output takes the
  rest, crossfaded over 100 ms. The pitch handler that decides it takes the
  key with bend, before glide and vibrato, which then move the string's
  length from the held pitch and never reach the shifter. Vibrato, glide
  and the LFO take their knobs' positions as they stand, where the
  string's own knobs take whole steps. **[code]** **[measured]** (Wood
  Bass's and Upright Basic Bass's vibrato depth; the vibrato renders'
  rate and depth)
- The output: the pickup's point on the string, or the wave arriving at
  the bridge; then a 10 Hz high-pass. **[code]** (the gain: **[measured]**
  1.4373, 2.9 dB under the reading's 2, the median level of the 95
  hammer, plectrum and bow fit renders that pass at the default Body
  Level, which is unity; a plain plectrum then matches Live's to
  -108 dB)
- Positions along the string: Exp(0.05, 0.5) of the half period (its
  fraction, not its whole samples), the exciter from the bridge, the
  damper and pickup from the nut, each within the string's first half;
  the pickup steps off the damper's sample. **[code]**
- The device's output bends softly toward its full scale of 4: linear to
  0.7 of it, then 1 - 0.3 / u^3 with u = (10 x + 2) / 9. **[code]**
  **[measured]** (Hammer Velocity at full)

### Exciters, damper, finger

- Hammer, bouncing hammer and plectrum: a mass, or a constant-speed
  plectrum, on a felt contact with F = K delta^2. Segno solves each
  sample's implicit contact exactly (delta falls linearly with F through
  the body's, the felt's and the string's give, so the quadratic has a
  closed root). The felt's surface yields under the force and follows the
  body only through the felt, so the body's own give under the force in a
  sample comes off the felt's compression. The hammer flies off under
  gravity; the bouncing hammer falls back and re-strikes until it rests
  on the string; the plectrum pushes only while it overlaps the string by
  less than its protrusion, and past that it has slipped by. Each starts
  0.1 mm behind the string as it stands. A hammer is parked once 1 m
  behind its start while gravity takes it away (a bouncing hammer still
  held falls back from any height and strikes again), the plectrum 1 m
  past it; a hammer driven on into the string stays on it. Mass, stiffness and speed are not held to any
  range (velocity amounts take them 16 octaves either way). **[code]**
  **[measured]** (the bouncing hammer's re-strikes in round 4, the
  lightest hammer's level, the muted guitar preset, Nice Harp and the held-out
  Slap Bass's hard C5 and Moving String Pad's chord release)
- The bow: a stick-slip junction, sticking within a zone around the bow's
  speed and released along a straight line (slope 10) back to the string's
  own velocity beyond it, lifted at the release. Its speed takes the
  strike's key and velocity scaling only from the engine's next block and
  keeps the one it took last until then (none on a string never bowed):
  Live's block falls anywhere against a note, Segno holds the old speed a
  fixed 48 samples so its output keeps to any block size. **[code]**
  **[Segno]** (the fixed hold) **[measured]** (48: a note at the start of
  a Live render, after which the C2 bow renders' first 100 samples match
  Live's to -57 dB)
- The key and velocity amounts scale each exciter's three knobs, the
  positions, the damping, the decay and the damper by 2^(amount x pitch
  or velocity), Exp(0.1, 16) each. An amount at zero keeps its resting
  0.1 (the engine moves a value only when its step changes, and 0.1 sits
  on step 0), so a reference string still scales with pitch: decay and
  damping 2^(0.1 p), the hammer's speed and stiffness too. Four amounts
  rest higher and do go to 0: Force < Key, Stiffness < Vel, Velocity <
  Vel and Finger Force < Vel. **[code]** **[measured]** (the reference's
  decay and level at C2 and C6)
- The damper rests on the string (always, or only after the release when
  gated) through the same contact, from the exciter's side. A string
  started again with the damper on starts bent under its weight: rail A
  holds a / (1 + g) from the damper to the nut and -a g / (1 + g) from the
  bridge to it, rail B the same from the damper to the bridge and from the
  nut, a = m g / 2, each rail's own tap at the damper still holding the
  wave before the damper's push; the bridge's filters and the output's high-pass start
  settled on that, and the finger starts on the fret under its weight and
  the bent string's push. The damper itself starts resting on the string,
  its weight against the felt and the contact, and a gated one is thrown
  off from there at each strike, so it pushes the string while it parts
  from it; a string struck again keeps its damper where it is. **[code]**
  **[measured]** (the resting damper; the plucked presets' onsets and
  level; Wood Bass and Clean Basic Guitar, 2 to 3 dB loud before; with
  rail B's tap at the damper holding the wave after the push, the string
  started with a jolt of half the weight's push, which a heavy damper
  turned into Soft Buzz Bass's 6.4 kHz excess: its B3 now matches to
  0.04 dB rms, from 3.9, and Clav Celesta's first sample is Live's)
- The finger presses the string onto a
  fret at the nut, the two contacts solved together by Newton; the wave
  leaving the nut is the arriving wave plus the contacts' push, times the
  loss. The fret lies on the side the exciters push toward. The finger,
  the fret and every contact's motion are worked in double precision, as
  the engine's are: a heavy finger on a stiff fret pushes with hundreds of
  newtons where the wave is their small difference, and a heavy damper's
  felt holds centimetres where its contact holds microns; single precision
  left a noise floor 80 dB down. **[code]** **[measured]** (Sitar Far's
  buzz, Banjo and the upright and fretless basses: 3 to 12 dB off with the
  fret on the other side; the held-out Kalimba Big's highs, now Live's to
  the dB)

### Filter, body, voices

- Analog's filter, all ten types (each stage clamping its own Q), its key
  tracking from the key with bend (no glide or vibrato); the filter
  envelope (attack, decay, sustain, release, velocity) in straight
  segments, its module's default; the LFO as Analog's. A string struck
  again drops its envelope from where it stands to 0 over 0.7 ms before
  the attack, the shared retrigger. **[code]** **[measured]** (filt-env,
  the pad presets; the retrigger: Soft Buzz Bass's legato line, 0.34 to
  0.14 dB rms. A mono string struck again after its release passes a
  short burst in Live that this drop does not reproduce: round 8)
- The body: four recirculating lines, each a delay and a Schroeder
  all-pass, through a low cut and an absorption low-pass whose highs decay
  High Cut times as fast; Body Level is the device's volume, Sq(0, 2) on
  the knob's 0..127 value as it stands, not its whole step (the default
  0.7048 is unity) **[measured]** (the first milliseconds of every
  preset with the body on, which then match Live's within 0.03 %), the
  mix a constant-power sweep with the wet at 0.35. Each line's length
  is the prime at or below size x rate / 44.1 kHz x its length in samples
  at 44.1 kHz, a set per type (type 0: 239, 288, 334, 411; 1: 105, 126,
  238, 441; 2: 55, 81, 107, 150; 3: 286, 345, 386, 507), the all-pass
  taps the same in every type (44, 48, 61, 71).
  The diffusion is -0.29 x the square root of the size; the absorption's
  coefficient is set for 44.1 kHz and taken as it stands at the host
  rate. **[code]** (the structure, the diffusion's -0.29)
  **[measured]** (the lengths: each wet-only render fitted sample by
  sample against Live's dry reference, which leaves an error under 0.2 %
  of the wet signal; every type at all five sizes, each length the one,
  or the lowest of the few, that gives all twenty renders. The
  diffusion's growth with size; High Cut's direction: up shortens the
  highs)
- Mono or 2 to 32 voices, unison of 2 or 4 strings (the shared unison
  law), glide, vibrato. The voices count strings, so a unison note takes
  two or four of them (two voices with unison play one note of a chord).
  Each unison string starts a whole delay behind the one before, the
  delay (ExpZ(0.002, 0.1) s) counted in whole milliseconds, the engine's
  1 ms blocks, and each lets go the same delay after the key, so a copy
  plays the note delayed, its end too. Velocity reaches the device as (velocity - 1) / 126, the
  engines' shared MIDI front end. **[code]** (the velocity) **[measured]**
  (round 5: the voice count on unison chords; the reference's second and
  fourth strings at delays 0.25 to 1 land on Live's sample; with the
  velocity the hammer references match Live's to -100 dB, from -80; the
  copies' release: ccg-tri 1.6 to 1.3 dB rms, 12 String Chorus Guitar's
  release 40 dB under Live's signal, from 15. Round 8: on a later note a
  copy sometimes starts one 1 ms block later against the first string
  than Segno's, and sometimes not, as Live's host timing predicts. Live
  starts a note's first string on its block before the note, while the
  copies' delay runs from the note's own time and ends on a block too.
  That is the host's placement: an event on a block start, as Segno's
  engine delivers every event, gives Live's copies the delay in whole
  milliseconds from the note, which is what Segno does. The fit harness
  now adds the host's 32 samples to each later note's copies (it reaches
  the device's voices after the note-on), so uni8-three, s12-8-two and
  12 String Chorus Guitar's phrase match; round 9 checks notes off the
  1 ms grid)
  Vibrato's rate is off by up to Error = Lin(0, 0.2) of it, a new random
  draw each cycle, as Analog's. **[code]** (Live's own copies of the
  presets with Error up differ from each other, those with it at zero
  do not; Ice Ballad Keys and New Age String then pass on the held-out
  round)
  Keys that arrive with a key that did not glide do not glide either
  (Const mode), as Analog's triads showed: a chord's later notes would
  otherwise glide from its first under Legato. **[measured]** (round 8:
  Electric Basic Bass's and Meow Keys' chords, 4.5 and 3.3 dB rms to
  0.07 and 0.06)
  A key struck again strikes its ringing string
  without resetting it. A released string ends after 84 one-millisecond
  blocks in a row, counted from the release, in which its own sound
  (before the filter, which an LFO can close for a while) peaks below
  -101.1 dBFS, but not while its gated damper is still in the air (for
  at most 2 s of flight): the damper lands again and the string sounds.
  Live cuts to silence on those 1 ms boundaries and never sooner than 84
  blocks; a resting damper, a terminated string or a landed gated damper
  makes it cut sooner than a silent string would, by a condition the
  renders have not shown.
  **[code]** **[Segno]** (the voice end) **[measured]** (Wurli Mellow's
  phrase: a low thump 190 ms after a release, as in Live; Moving Space
  Alarm, whose LFO closes its filter after a release while Live's string
  rings on; round 7: the cut at 84 blocks for a silent string, and at
  2094 for one held at -88 dBFS with no release loss)

### The fits so far

Strict score (third-octave x 50 ms cells within 1.5 dB rms, the attack,
level within 0.5 dB, pitch within 3 cents; three noise seeds): 87 of 110
renders pass over two rounds, 7 of the 20 factory presets (Saw Bass,
Slap Bass, Harp Soft, Electric Basic Bass, Wire Noise, Nylon Basic
Guitar, Clean Basic Guitar at C2). The held-out round (every factory
preset, three notes over 8 s, never fitted against) passes 32 of 107, up
from 8. All 25 body renders pass, as do the plectrum, bow, finger,
resting damper and vibrato away from C4 and the LP24, BP6 and Notch4
filters. Failing: the bouncing hammer (six renders: its re-strikes move
by 2 to 3 dB with a hammer speed 0.01 % off, so they follow every
rounding), the bow with more force or two octaves down (its stick zone
starts 2.5 % faster than Live's, then the motion turns chaotic), the
lightest hammer (1.2 dB loud).

Still open, by preset (third-octave rms): Chord Bouncing 17 (the
bouncing hammer), Slow String Pad 7.5 and Attack Pad 5.4 (the bow),
Tiny Tonal Drums 16, Banjo 5.8, Upright Basic Bass 4.0 and 4.4 and
Fretless Bass 3.8 (their partials' levels), Tuned Noise 3.4 (its release
2 to 4 dB slow), Wood Bass 2.7 (2 to 5 dB loud from 160 to 320 Hz early
on), Clean Basic Guitar 2.0 at C6 and Hard Picked Guitar 1.8 (level).
On the held-out round the bowed presets pass 0 of 15 and the bouncing
hammer's 0 of 6.

Round 3 (50 renders) settles three things. Live repeats itself exactly:
its copies of the bounce renders and Chord Bouncing are identical to the
sample, so the bouncing hammer is deterministic there; Segno's second
strike at C5 comes 8 ms early (its rebound about 7 % slow), and neither
double precision nor Live's own force iteration (Newton from 0, stopping
under 0.01 N) moves it: the contact's equations read the same, so the
gap is in a value the renders have not isolated. The bow's first stick
pulse is 2.5 % larger than Live's at C4 at every force, speed, friction
width and velocity swept, and falls 2^-0.1 an octave below C4: with the
speed's key amount at zero the pulse ratio holds at 1.025 at every pitch,
but the sustained motion then drifts further from Live's, so neither is
adopted. Velocity enters the amounts linearly (a curved velocity loses
every phrase render). Overall with round 3: 98 of 148 renders, 8 of the
38 factory-preset renders; held-out 32 of 107. The phrase renders' third
note lands about 51 samples early in Live (a harness effect common to
the AAS devices, left to the harness). Error draws Segno's own random rise, so Hard Picked Guitar and Tiny
Tonal Drums cannot match Live's pitch sample for sample. The MPE
destinations are stored, not played.

Round 4 (37 renders: the bouncing hammer's mass, felt damping and
stiffness one at a time at C3, C4 and C5; Sitar Far's parts on their
own; Wood Bass and Banjo without their filter, body or finger; the bow
and plectrum read at the string) and a closer reading of the contact
settle most of what was open. Overall now 143 of 185 renders pass (from
106), 23 of the 38 factory-preset renders (from 8); held-out 54 of 107
(from 32): hammer presets 15 of 26, plucked 37 of 60, bouncing 1 of 6,
bowed 1 of 15. What moved them, each against Live's renders:

- The felt follows the hammer's body only through the felt (the body's
  give in a sample comes off the compression): the lightest hammer's
  1.2 dB, and the bouncing hammer's second strike now lands on Live's
  (C4 130 ms, 0.25 samples apart).
- The output gain 1.4634 (all exciters had been 0.21 dB loud once the felt
  was right; the bow's "2.5 % larger first pulse" was this).
- The fret on the exciters' side: Sitar Far's parts, Banjo, the upright
  and fretless basses pass (Sitar Far's 30 to 46 dB at 2.5 to 4 kHz was
  the string lifting off the fret instead of striking it).
- The engine's 2^x: Sitar Far's D2 renders match to 0.03 dB.
- C4 = 261.62 Hz and the damping's estimated phase delay: the references
  keep Live's pitch for the whole render.
- The gated damper starts resting and is thrown off from there: Wood Bass
  (3.6 dB loud) and Clean Basic Guitar at C6 pass.
- No ranges on the exciters' and damper's values: the muted guitar preset and
  Nice Harp pass; a hammer driven into the string stays on it (the
  held-out Slap Bass's hard C5 was 16 to 24 dB loud).
- The bow's release line and its first block's speed: the attack passes
  on most bow renders; the sustained motion is still chaotic.

The fit harness now places a note at 0 s 16 samples in and every later
event 32 samples early, as Live's exports do (measured on the phrase and
held-out renders), on a grid of 64-sample blocks.

Still failing: the bouncing hammer after its second or third strike (16
renders; to the first strikes it matches Live's to -78 dB, and double
precision or Live's own force iteration do not keep it longer), the bow's
sustained motion (18 renders and the bowed presets), Tiny Tonal Drums
and Hard Picked Guitar (Live's Error draws differ between its own copies),
Tuned Noise (bowed), Wire Noise (random), Chord Bouncing, and Wurli
Mellow's phrase (3.4, its later notes).

Then: the bowed string and the bouncing hammer are chaotic. A change of
1e-6 in the bow's or the hammer's speed at the strike moves Segno from
itself, for 20 fit renders and 9 held-out bowed presets, at least two
thirds as far as it is from Live (Tuned Noise 3.42 against Live, 3.41
against itself; the bouncing hammer at C4 3.06 and 3.62), so those
renders are scored against Segno's own spread under that change (the
fit tooling's chaos list); the bow and hammer renders where Segno keeps
to itself (bow-48, bow-w30-60, bounce-k25-48 and others) still count
against Live. Wurli Mellow's phrase passes with the damper's flight
keeping its voice, Kalimba Big's highs with the finger in double
precision. Overall 154 of 185 fit renders pass, 25 of the 38
factory-preset renders; held-out 59 of 107 (most chaotic renders still
fail their attack, level or pitch, which Segno's own spread does not
reach). Open, waiting on round 5 (34 renders:
the unison's delay and detune laws, unison strings against the voices,
the mono voice given a chord or a legato line, and Soft Buzz Bass,
Kalimba Big, Wurli Mellow, Tuned Noise and Clean Chorus Guitar on notes
of their own): the held-out unison presets (their second string comes
about 1.8 % early in Live, and a two-voice unison preset seems to play
one note, not two), and Soft Buzz Bass's mono chord, which rings about
10 dB too long with a 120 Hz component, the heavy damper's own bounce
on the string.

Round 5 (34 renders) settles the unison and the mono voice: the voices
count strings, the delay counts whole milliseconds, each further string a
whole delay later, and the mono voice given a chord or a legato line
matches Live's to the sample on the reference (Live plays the chord's
last note alone, as Segno does). Soft Buzz Bass on its own E3 passes; its
chord at B3 is 5 dB off at 2.5 kHz and 17 dB at 6.4 kHz in the first
250 ms, a note-dependent difference the round does not isolate. Live
ends a released voice by a rule Segno does not have yet: a quiet voice
with its damper resting is cut to silence 84 ms (4032 samples) after
the release (sbb-nobody-52, the terminated and resting-damper
references), others later; Segno's ends only below -100 dBFS. With round 5 and the velocity:
186 of 219 fit renders pass, 28 of the 38 factory-preset renders;
held-out 60 of 107 (hammer 16 of 26, plucked 38 of 60, bouncing 3 of 6,
bowed 3 of 15).

Round 6 (49 renders). Soft Buzz Bass's B3 fails alone as its chord does
(the chord is not the cause) and passes with the damper off; its damper
sits on the right sample, so the difference is in how the heavy resting
damper treats B3's partials (2.5 kHz decays 1 to 4 dB fast, 6.4 kHz 3 to
4 dB strong), still open. Live's voice cut, read to the sample from its
exact zeros (`tools/tension_voicecut.py`): a released voice is cut only
on a 1 ms block boundary after the note-off, never sooner than 84 blocks
(4032 samples at 48 kHz) after it; a voice whose string is silent or held
still at the release (decayed, resting damper, finger on the fret) is cut
exactly 84 blocks after it; a string still ringing (-46 dBFS and louder)
is not cut; the others are cut later (a terminated string released loud
at 132 blocks, a gated damper at 139 to 143, presets up to 400 and more).
No threshold on the output level fits every render, so the countdown
watches something inside the voice; Segno does not cut. The short notes
of the failing bowed and bouncing presets: where a 1e-6 change leaves
Segno's attack in place (Cello and Ensemble Strings at D3, Strings Quartet
at A4, Wow Pad and Moving Space Alarm at D3) the first 150 ms differ from
Live's for a reason of the model's, not chaos.

Then, from the held-out round sorted by kind (bowed, bouncing, plucked,
hammer; random or not; which of the three notes fails), four causes shared
by many renders, each confirmed on fit renders. The bridge's Lagrange read
sat one tap off its middle whenever e's fraction was under a half, a
high-frequency loss of up to 1.2 dB a round trip, which ate the highs of
every loud high note (the plucked presets' hard C5 10 to 30 dB short above
9 kHz); the string bent under a resting damper started with rail B's tap
at the damper one sample on the wrong side, a jolt at the first sample
(Soft Buzz Bass's B3, the open question of rounds 5 and 6, and Clav
Celesta's highs); a string struck again restarted its filter envelope from
0 where the shared module drops it over 0.7 ms; a unison copy let go with
the key instead of its delay after it. Fit renders 248 of 285 pass (from
233), 44 of the 67 factory-preset renders (from 41); held-out 75 of 107
(from 62). Round 8 (37 renders,
`segno-tension-fit8`) asks: the unison copies' timing on a note that is
not the song's first; a mono string struck again after its release, with
a filter envelope and as Soft Buzz Bass; Upright Ambient Bass's heavy,
fast, soft, fully damped hammer at a quiet C2, whose highs come 6 to
14 dB short; the bow with and without the speed's velocity amount, to
test the speed switch after the first block that still moves Strings
Quartet off Live's at sample 70; Meow Keys' chord, 6 dB short at 180 Hz;
Electric Basic Bass's chord after a voice Live has cut.

Round 8 (37 renders): 27 passed as they came, the mono restrikes after a
release, Upright Ambient Bass's hammer at C1 and C4 and every reference
bow among them. The chords of Electric Basic Bass and Meow Keys failed
because their later notes glided from the first (Glide on, Legato); with
the rule above every chord of theirs matches. The bow's speed switch
after its first block matches the reference to -120 dB with a velocity
amount of 0.6, so Strings Quartet's departure at sample 70 comes from
something else of that preset's (its finger, its gated damper or its
positions), not from the switch. Still open: a mono string struck by a
chord while it still rings (sbb8-rel-tri) shows a 6 ms burst in Live
that Segno lacks; a single key matches. Two chaotic renders went from
passing to failing with the damper tap fix (Moving String Pad's bouncing
hammer at A4, Wire Noise's bow): a 1e-6 change of the exciter's speed
moves Segno from itself by 5.7 and 5.6 dB, close to their distance from
Live, and before the first 0.1 s the two taps give the same signal.
With round 8: 279 of 322 fit renders pass (rounds 1 to 7 unchanged at 248,
round 8 31 of 37), 44 of the 67 factory-preset renders; held-out 77 of 107
(Electric Basic Bass and Meow Keys now pass).

Then: the vibrato's Error (above), and the host's offset on later notes'
unison copies moved into the fit harness. Round 9 (57 renders,
`segno-tension-fit9`) asks: Strings Quartet's bow with its finger, its
gated damper, its positions and inharmonicity taken out one at a time,
its exciter on the reference string with each part added back, and
Ensemble Strings and Wow Pad, whose first block already differs; Upright
Ambient Bass at C2, the held-out note (round 8 tried C1 and C4), and its
hammer on the reference; a mono string struck by a chord while it still
rings, varied (damper, filter, envelope, body, held, order, priority,
exciter, a dyad and one key); unison copies on notes off the 1 ms grid;
vibrato's phase on notes after the first.
With both: 281 of 322 fit renders pass, 44 of the 67 factory-preset
renders; held-out 80 of 107 (12 String Chorus Guitar, Ice Ballad Keys and
New Age String now pass).
The held-out near misses that need no round, looked at one by one:
Reverse Guitar fails on two cells (the bright electric guitar preset
with the same damper shows the same)
where Live, about 230 ms after a release with a gated damper, starts a
fast decay (about 480 dB/s, as at the voice cut of round 6's gated
reference, 139 blocks after its release) that Segno lacks: the voice
cut's open rule again. Wood Bass, Robot Voice and String Delay Pad
match their first note to -30 dB and their later notes only in level:
their vibrato's phase on a later note leads Segno's by 60 to 100 degrees
(Wood Bass's phrase, both rounds), neither a reset nor a free-running
phase; round 9's vibrato renders ask. Clean Chorus Guitar is within
0.04 dB of its limit, its spread Segno's own (its resting damper makes
a 1e-6 change show).


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
