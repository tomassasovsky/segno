# Ableton Live device presets on the pedal — brainstorm

<!-- cspell:words adv adg Ghidra devicekit Lfo Vec analyzeHeadless gpr Wavetable wavetables ADSR BLEP BLAMP wavefolder crossfading prewarp Modwheel detuned unnormalised Clob Sallen linearised transconductance kModBy kCarriers Celesta transconductances autocorrelation tfz unmeasured retriggered isolations Geigerzaehler Bellatine Keystrike Numan uncentred dfit Grimer Perc Tesseract Tesseract's auxenv fdrive fltkey keyscale lfofree minatt noteoff penv penvd rndpan Basscycle -->

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
  amplitude), and the voice stops a block later: a 50 ms release from
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
  saturating, damping 2 (1 − q) − 0.01 and a diode across the band node
  (a 0.5 V knee, conductance 0.85 above it), so it rings at a bounded
  level from resonance 1; the input stage barely saturates. The
  transconductances' curve takes the node voltages at 0.145 per volt.
  **[code]** **[fit: round 9's self-oscillation at resonance 1.25, 30 Hz
  to 1 kHz, within 0.6 dB in level and 6 cents at 100 Hz and 1 kHz
  (17 at 300 Hz, where the 262 Hz input pulls it); Tesseract 4.7 to 3.6]**
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
- Random pan and the random start phases do not repeat from one Live
  instance to the next: two identical tracks draw different pans, and
  every held-out preset's Live copies differ (Live against itself 0.8 to
  13 dB over time). Segno draws its own: uniform over ±2 × Rnd, clipped
  to the sides, as Live's draws are (48 at small amounts, standard
  deviation 1.12 of Rnd; at 100 %, 56 % of 36 hard to a side, 50 %
  expected). **[measured: rndpan-a, -b; the held-out copies; round 9
  rndpan-100 and its copies]**
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
than Segno's (round 10 repeats it three times). Basscycle Aftertouch's
pitch error is the tracker on a 23 Hz fundamental beating with Spread
(rounding its velocity Coarse down instead is 2.6 dB worse); Wobbly Flag
Bass is MS2 driven at a 30 Hz cutoff, the open drive case.

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
