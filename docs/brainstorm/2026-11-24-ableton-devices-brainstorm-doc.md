# Ableton Live device presets on the pedal — brainstorm

<!-- cspell:words adv adg Ghidra devicekit Lfo Vec analyzeHeadless gpr Wavetable wavetables ADSR BLEP BLAMP wavefolder crossfading prewarp Modwheel detuned unnormalised Clob Sallen linearised transconductance kModBy kCarriers Celesta transconductances Bandpass Bitgrunge Csound Drivetime Extratone Filther Lofi Lowpass Megatripolis Minnaert Sawstyle Starchestra polyBLEP Metalic Formant formants Barney Asym quintic Wurli MKII Schroeder Fretless Balafon Glockenspiel Perc halvings Inharmonicity travelled Inharmonics atan Freq bilinearly penv mvol retrigger retriggers unsynced Quantizer autocorrelation tfz unmeasured retriggered isolations rvol mnoise lr -->

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
  1 + 2 M2. **[code]** **[measured]** (the parabolic sine) The ratio list
  is not Harmonic FM's: Live's renders at Macro 1 0.25, 0.5 and 0.75 hold
  modulators at 2^(2/12) and 2^(3/12), 2^(5/12), and 2^(11/12) of the
  note, semitone intervals, which Segno's list does not have. **[measured]**
  **[open]** (the list and its position law)
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
  voice; four-tone chords match Live's renders exactly) A note's tones
  start in phase at the note's own frequencies and macros, so a tone both
  chords share sums at full level. **[measured]** Between two inversions
  Live's octave-related tones of the two chords combine with signs Segno's
  saws do not reproduce (a shared tone's second harmonic cancels where
  Segno's adds); M2 0.25 and 0.75 stay 2 and 6 dB rms off. **[open]**
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
  Free rates in Hz, Tempo divisions as Drift's; Retrigger restarts the
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
  rates through their knobs' position (a time is 40 s x pos^3, a rate
  79.5 Hz x pos^3.036: +0.1 at 2 Hz is 2.4122 times, -0.1 0.2879 times),
  Tempo rates 22 divisions.
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
- C4 sits 0.98 cent below equal temperament at every note the renders
  play. **[measured]**
- Sub: a square an octave down, Exp(0.01, 1). Sync: a master at the note
  and a slave at Exp(1, 20) times it (the sine does not sync); at a ratio
  of 1 the master still resets the slave, which moves the saw half a
  period against an unsynced one (Saw Pure Brass's chains beat in Live's
  phase only so). **[code]** **[measured]**
- Octave, semitone and Detune (+-1/4 octave as a square), a pitch
  envelope of Exp(0.01, 6) octaves falling to 0 over Exp(0.01, 10) s, LFO
  to pitch and to pulse width. Key tracking (Mod 1) at 0.5 is 1.
  **[code]**

### Filters

- LP12/24, BP6/12, Notch 2/4 and HP12/24: bilinear 2-pole sections,
  linear, at Exp(30, 22000) Hz and Q Exp(0.1, 120) (each stage's Q at
  most 100, LP24 at full Q 1.2 dB louder than a clamp before the sqrt
  gives); the 4-pole types cascade two, LP24's and HP24's stages each at
  sqrt(Q),
  BP12's and Notch4's at the full Q. The band-pass is the band node itself,
  peaking at Q. **[code]** **[measured]** (BP's level, BP12's and
  Notch4's Q)
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
- The tempo divisions 0..23 run 16 beats down to an eighth of a beat,
  each dotted, straight and triplet (division 4 is 8 beats, 3 is 12): the
  brass presets' LFO pan cycles in 4 and 6 s at 120 BPM. **[measured]**
- Amp: Exp(0.01, 2) times the envelope, (1 + depth x LFO) and the key;
  key, envelope and LFO move the pan. The LFO's depths on the level and
  the pan are linear in the knob (Tremolo Tines' pan swing and the lfo-amp
  render). **[code]** **[measured]**
- A mono key change (a new key, or a released key handing the voice to a
  held one) retriggers each envelope whose Legato is off: a straight fall
  to 0 over 0.7 ms, then the attack from 0; the oscillators keep their
  phase. **[measured]** (the glide renders dip to silence at the key
  change)

### Voices

- Mono or 2 to 32 voices; the oldest released voice is stolen first,
  fading over 1 ms. Mono follows Keyboard Priority (high, low, last):
  with Low, a higher key waits for the lower one's release, and a
  released key hands the voice to the held key the priority picks.
  **[code]** **[measured]** (the glide renders)
- Glide: a one-pole on the pitch with time constant T / 2 pi, T =
  Exp(3 ms, 9 s), times sqrt of the interval in Prop mode; Legato limits
  it to overlapping notes. **[code]** **[measured]** (T's curve)
- Unison: the copies sit 0, +1, -1, +2 steps from the note, a step of
  ExpZ(0.001, 1) octaves on 127 times the stored value (0.379 semitone at
  0.5, an octave at 1); they start ExpZ(0.002, 0.1) s apart. A copy's
  offset goes through the engine's cubic 2^x (exact at whole octaves, up
  to 1.3 cents sharp between), which puts the lower copy 0.3 cent sharp
  as the renders show. Vibrato: Lin(0.25, 10) Hz, each cycle's rate off by
  a random fraction up to Error = Lin(0, 0.2), its depth and the mod
  wheel's up to 2 semitones, with delay and fade-in. **[code]** (Tension's
  reading of the shared unison; the vibrato error) **[measured]** (the
  offsets' pattern; 0.374 semitone at 0.5; the cubic on the offsets)

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
  vibrato change the string's length. **[code]** (Segno takes the exact
  phase delay of its own filters) **[measured]** (the reference at C6)
- The keyboard: Stretch scales the key about A4 (0.992 to 1.008 times,
  so C2 sits 15 cents flat at a preset's usual 0.8), Fine Tune spans half
  a semitone either way, and Error adds a random rise of up to 0.02 octave
  at each strike. **[code]** **[measured]** (the bass and guitar presets'
  pitch at C2, C4 and C6)
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
  length from the held pitch and never reach the shifter. **[code]**
  **[measured]** (Wood Bass's and Upright Basic Bass's vibrato depth)
- The output: the pickup's point on the string, or the wave arriving at
  the bridge; then a 10 Hz high-pass. **[code]** (fit: a gain of 1.5,
  2.4 dB under the reading's 2)
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
  closed root). The hammer flies off under gravity; the bouncing hammer
  falls back and re-strikes until it rests on the string; the plectrum
  pushes only while it overlaps the string by less than its protrusion,
  and past that it has slipped by. **[code]**
- The bow: a stick-slip junction, sticking within a zone around the bow's
  speed, released over a short ramp, lifted at the release. **[code]**
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
  nut, a = m g / 2; the bridge's filters and the output's high-pass start
  settled on that, and the finger starts on the fret under its weight and
  the bent string's push. Lifting a gated damper at the strike lets the
  string spring back at once. **[code]** **[measured]** (the resting
  damper; the plucked presets' onsets and level)
- The finger presses the string onto a
  fret at the nut, the two contacts solved together by Newton; the wave
  leaving the nut is the arriving wave plus the contacts' push, times the
  loss. **[code]**

### Filter, body, voices

- Analog's filter, all ten types (each stage clamping its own Q), its key
  tracking from the key with bend (no glide or vibrato); the filter
  envelope (attack, decay, sustain, release, velocity) in straight
  segments, its module's default; the LFO as Analog's. **[code]**
  **[measured]** (filt-env, the pad presets)
- The body: four recirculating lines, each a delay and a Schroeder
  all-pass, through a low cut and an absorption low-pass whose highs decay
  High Cut times as fast; Body Level is the device's volume (Sq(0, 2)),
  the mix a constant-power sweep with the wet at 0.35. Each line's length
  is the prime at or below size x rate x its length at size 1, a set per
  type (type 0: 5.391, 6.547, 7.604, 9.297 ms; 1: 2.5, 2.875, 5.417,
  10.062; 2: 1.25, 1.792, 2.5, 3.438; 3: 6.5, 7.833, 8.75, 11.5), the
  all-pass taps the same in every type (0.995, 1.089, 1.38, 1.616 ms).
  The diffusion is -0.29 x the square root of the size; the absorption's
  coefficient is set for 44.1 kHz and taken as it stands at the host
  rate. **[code]** (the structure, the diffusion's -0.29)
  **[measured]** (the lengths: each wet-only render fitted sample by
  sample against Live's dry reference, which leaves an error under 0.2 %
  of the wet signal; type 0 at sizes 0.3, 1 and 2, the others at 1; each
  length the middle of the range every render allows. The diffusion's
  growth with size; High Cut's direction: up shortens the highs)
- Mono or 2 to 32 voices, unison of 2 or 4 strings (the shared unison
  law), glide, vibrato. A key struck again strikes its ringing string
  without resetting it. A released string ends after 50 ms below
  -100 dBFS. **[code]** **[Segno]** (the voice end)

### The fits so far

Strict score (third-octave x 50 ms cells within 1.5 dB rms, the attack,
level within 0.5 dB, pitch within 3 cents; three noise seeds): 57 of 75
renders pass, 6 of the 20 factory presets (Saw Bass, Slap Bass, Harp
Soft, Electric Basic Bass, Wire Noise, Clean Basic Guitar at C2), up from
25 and 0. The held-out round (every factory preset, three notes over 8 s,
never fitted against) passes 21 of 107, up from 8. Every single change
around the reference passes but the bouncing hammer, the bow an octave
down and with full force; all eleven body renders pass.

Still open, by preset (third-octave rms): Chord Bouncing 12 to 17 and
the bounce render 6 (the bouncing hammer's re-strikes, which move with
any small change), Slow String Pad 7.5, Attack Pad 5.7 (the bow), Tiny
Tonal Drums 16, Banjo 5.2, Upright Basic Bass 4.0 and 4.4 and Fretless
Bass 3.8 (their partials' levels: the exciter's comb), Tuned Noise 3.6,
Wood Bass 2.7, Clean Basic Guitar 1.0 and 2.0 at C4 and C6, Nylon Basic
Guitar 1.9 and Hard Picked Guitar 1.8 (level and onset, within a dB and a
ms). Error draws Segno's own random rise, so Hard Picked Guitar and Tiny
Tonal Drums cannot match Live's pitch sample for sample. The MPE
destinations are stored, not played.

## Collision: behavior

Learned 2026-11-25 from Live 12.2.7's Collision engine (an AAS bundle, one
reader), then measured against 92 Live renders: single changes around a
plain mallet-on-beam reference, and all 33 factory presets. Tags as for
Meld. Segno's implementation is `collision_voice.c`.

### Values and the matrix

- Presets store each value in its own unit (semitones, cents, degrees,
  -5..5 amounts); a knob reaches the engine as one of 128 steps (a 0..1
  knob by the 128 / 126 rule, Filter Q by 127 / 126, a ranged one by its
  range; Fine Tune and the bipolar knobs with 0 at step 64, 63 steps up
  and 63.5 down; Radius inverted), a matrix amount as is. The linear,
  square and cube curves put step 64 at exactly their middle, the
  exponential curve does not. **[code]** The master Volume, the LFOs'
  free Rate and the Pitch Env. Time are not taken down to their step.
  **[measured]** (Vibes Basic's level; lfo-pitch's rate, 0.641 Hz against
  0.624 for the step; penv-t75's sweep, 1.3 to 0.3 dB)
- A per-voice matrix sums amount x source into each destination: key
  ((note - 60) / 12 with bend), velocity ((vel - 64) / 63), bend, mod
  wheel, pressure, both LFOs. The "< Vel" and "< Key" knobs are fixed
  routes; the LFO, bend, wheel and pressure choosers pick from 17
  destinations, each in its own unit (an octave of cutoff, a doubling of
  a gain, a rate or a depth, a unit of pan or hit). **[code]** A chooser's
  amount moves a resonator's pitch by an eighth of an octave a unit.
  **[measured]** (lfo-pitch: 0.25 swings 37.7 cents; Music Box Slide;
  amounts 0.5, 1, 2.5 and -1, half depth and resonator 2 in round 2)

### Exciters

- The mallet: one impulse through a critically damped low-pass at
  Exp(2, 5000) Hz (moved by its routes), scaled so the pulse's peak holds
  whatever the stiffness; its noise, high-passed at Noise Color, multiplies
  the pulse by (1 - w) + w noise, w = (atan(a)/pi + 1/2)^3, a =
  Lin(-4, 4). **[code]**
- The noise source: white noise through a low-pass, high-pass, band-pass
  (of constant skirt: its peak gain is Q) or a low-pass and high-pass pair
  a width apart, under a linear ADSR, its cutoff moved by the envelope
  (Freq < Env octaves) and the routes. The filters are set at the strike
  and when a knob moves; when the envelope or a route moves the cutoff,
  they step to the new cutoff every 10 ms. **[code]** **[measured]** (Toy
  Piano Bells 14.5 to 7.7 dB, noise-env 12.2 to 10.3, against a ramp
  every 10 ms)

### Resonators

- Modal types: string (harmonic), beam (free-free, from cos b cosh b =
  1), marimba (a tuned bar, 1 : 3.96 : 10.67 : 19.17 : 27, then sqrt 2
  (k + 3/2) pi over the beam's first root), membrane and plate
  (rectangular, side ratio Exp(1, 20), the lowest modes of a grid of m up
  to floor(sqrt(N a)) + 1 and n up to floor(sqrt(N / a)) + 1). Quality
  keeps 4, 16, 30 or 70 modes; Inharmonics raises each ratio to 1 + chi,
  chi = clamp(I^3, -1, 1); modes above 0.4167 of the sample rate drop.
  **[code]** **[measured]** (the marimba's 10.67, 19.17 and its sixth
  partial at 37.3; type-3-r1)
- A mode's shape at the hit and the two listening points is read off the
  grid the engine samples it on: sin(k pi x) on N + 2 points along a bar
  of N modes, read linearly; sin(m pi x) sin(n pi y) on G x G points for a
  membrane or plate, G = floor(sqrt N) + 3, read bilinearly. High modes
  of a coarse grid come out weaker or stronger than the exact sine.
  **[code]** **[measured]** (q-0 1.0 to 0.02 dB, the membranes and plates
  at every ratio)
- Each mode decays as e^(-alpha t), alpha = (8/T) 2^e, where Material
  tilts e towards long highs (metal) or long lows (wood); its two-pole
  filter takes the exciter times the shape at the hit point and is heard
  through the shapes at the two listening points, its level tilted by
  Brightness about the mode at ratio 4. A heavily damped high-pass
  resonance at the top mode stands in for the modes left out (Bleed).
  **[code]** Its amount is Exp(0.001, 1) of the knob. **[measured]** (the
  reading's Exp(0.01, 1) left the dense membrane's highs above 10 kHz 3
  to 10 dB too strong at knob 0.5, dn-hp and dn-mnoise-0; Music Box Basic,
  Noisy Pad and Marimba Classic move with it; a bright mallet on the dense
  membrane passes at knob 0, 0.25, 0.75 and 1, bl-*) No mode rings longer than the knob's 35 s, and the decay
  routes keep T 2^d within 10 ms and 35 s. **[Segno]** (a bound the
  reading does not show; the metal presets with long highs fit it)
- A pitch move retunes the modes at most every 200 samples (Segno: every
  6 ticks of 32) and keeps their amplitude: each mode's newer state
  scales by the old frequency over the new, its step from the older
  state stays. **[code]**
- Pipe and tube: two waveguide lines with Lagrange reads, the far end a
  first-order reflection set by radius and opening; the pipe keeps every
  harmonic, the tube (its reflection negated) the odd ones. Decay is e^-4
  a round trip per T. Each line delays sr / (K f0) + 0.75 samples: the
  sr / (K f0) - 0.75 the engine computes plus the 1.5 samples its 5-tap
  read sits behind that point. **[code]** **[measured]** (Live's tube is
  odd-only; the pipes were 27 cents flat without the 1.5 samples, the
  tube at note 60 53 cents) The lines hold 4096 samples and a delay of at
  least 3.5: note 0 at 48 kHz, about note 6 at 96 kHz, and the highest
  pipe and tube notes share the top pitch. **[Segno]**
- Decay Exp(0.05, 35) s; after the release T becomes 0.05 + (T - 0.05)
  (1 - u)^3, u the Off Decay knob: 0 keeps the decay, 1 cuts it to 50 ms.
  **[code]** **[measured]** (decay-1: Live's note falls 28 dB in 20 ms
  after the release at Off Decay 1; the presets at 0 ring on) Pitch from
  Tune, Fine and the key, with a pitch envelope that falls exponentially:
  A (1.0314 e^(-3.49 t / T) - 0.0314), reaching 0 at its time T.
  **[code]** **[measured]** (penv-1's pitch track) Pan by a balance law,
  volume Sq(0, 2). In series resonator 2 hears resonator 1's outputs
  summed, the bleed's included; in parallel the exciter. The hit position
  is the knob plus the Hit destination, held to the knob's window, plus
  the strike's random offset. **[code]**

### Voices and level

- 2p voices (p = 0: mono); Retrigger strikes a sounding key's own voice
  again, the modes ringing on at the same pitch. Two LFOs per voice, seven
  shapes, free or synced; the synced lengths follow Live's menu, its note
  values from the longest down: 8, 6, 4, 3, 2, 1.5, 1, 3/4, 1/2, 3/8, 1/3,
  5/16, 1/4, 3/16, 1/6, 1/8, 1/12, 1/16, 1/24, 1/32, 1/48, 1/64 whole
  notes. A strike reads each LFO at its start phase. A released voice
  ends after 50 ms below -100 dBFS, counted once the mallet's pulse and
  both waveguides' round trips have passed; any voice, held or not, ends
  at the first 512-sample block in which its resonators' outputs (before
  their volumes) stay below 6e-6 with its exciters spent. **[code]**
  **[measured]** (Bells Attack's synced pan, 21.7 to 3.9 dB; Live's held
  notes stop at about -94 dBFS, at 512-sample steps, 6 dB higher with a
  resonator or master volume of 1; a metal note, mat-1, stops about 12 dB
  higher, which the output level does not explain) **[Segno]** (the
  released voice's 50 ms)
- The output is the voices' sum times Volume (Sq(0, 2)), then times 4.
  The engine's output stage soft-clips above 0.7 of its scale (0.7 to 1,
  then x4), as Analog's, Electric's and Tension's do. **[code]** In Live
  that stage never acts on Collision: a peak limiter holds the output at
  1, a quarter of the stage's ceiling, before it. The limiter looks 1 ms
  ahead: the gain a sample needs (1 over its peak, at most 1) is taken as
  the least over the next 1 ms and the last 1/3 ms; a released gain falls
  at once to it and rises back towards 1 with a 5.3 ms time constant, and
  is smoothed with a 0.225 ms one; a slow gain falls at once to the need
  but never below -0.79 dB, and rises back with a 197 ms time constant;
  the lower of the two applies. So a loud strike
  recovers to within 0.8 dB in about 20 ms, then over a few hundred ms,
  whether the overload lasted 7 ms or 2 s. The output lags the strike by
  16 samples, and the limiter adds its 1 ms, which Live compensates and a
  host can (`le_collision_latency`). **[measured]** (sample by sample
  against the device without its limiter on lim-d0, lim-d1, lim-48,
  lim-72, lim-rep, lim-rvol, mvol-08, mvol-09, serial-m03 and serial-m04:
  the gain starts falling 1 ms before each peak, tracks every peak to
  exactly 1, and keeps 0.6 to 0.8 dB of reduction after every overload; a
  waveform error of -39 dB against -22 for the earlier 17-sample limiter;
  the soft clip would bend the waveform, which Live's does not) Both
  channels share one gain. **[measured]** (lim-lr, heard from two points:
  its channels peak at 8.3 and 6.0 before the limiter and take the same
  gain within 0.1 dB)
- Each resonator's volume and pan ramp to their values over 2 ms, from
  where the voice's last note left them; a voice never played starts at
  the knobs' own volume and pan, without the key's or the matrix's pan. A
  full device restarts its oldest note's own voice, its states cleared;
  only a cut of the engine's slot limit fades a voice. **[code]**
  **[measured]** (the ramp is read; Bell Plate Long's phrase, whose hard
  C5 takes over the C3's hard-left voice, and Marimba Glassy's Pan < Key,
  whose first notes start centred)

### The fits so far

Five rounds of Live renders (single changes around a plain
mallet-on-beam reference, the 33 factory presets, the matrix units, the
pitch envelope, Off Decay, pipes across the keyboard, Live copies of the
random renders, the noise excitation through a dense 70-mode membrane,
presets playing a held-out-like phrase with copies, the limiter's
release, and round 5 below), scored by the strict score with three Segno
seeds and Live's own spread where copies exist: 130 of 174 pass, 20 of the
33 factory presets (104 of 152 before the measured limiter and bleed). The
held-out round (every preset, a quiet C3, a loud C4 triad and a hard C5,
with Live's copies) passes 11 of 33.

Left: the noise source's high-pass passes 7 to 18 dB less than Live's
between 125 and 250 Hz on the dense membrane (below its lowest mode), and
neither the input minus the low-pass nor a constant leak fits it; an
upward pitch sweep from an octave above leaves the beam's third mode 9 dB
too strong and its fourth 9 dB too weak, the difference arising at the
first retune 4 ms after the strike (no state rescaling of six tried
fixes it; few presets sweep that far). The noise-excited beams
(noise-lp, noise-env) now meet Live's copies on level, noise-env aside
(Segno's eight seeds of noise-lp: mean -51.6 dB, spread 4.5; Live's four
renders -51.5), but their pitch tracks wander more between Segno's seeds
(24 to 47 cents) than between Live's renders (9 to 13). Still open
besides: the MPE destinations.

Round 5 (Live copies of the random presets, the bleed at four values,
the limiter on two channels, the noise high-pass at two cutoffs and two
Qs, failing held-out presets on other notes) settled the bleed and the
limiter's link. Every random source in Live's engine draws from the C
library's `rand()`, seeded from the clock when the bundle loads **[code]**,
so Live's copies are independent draws and Segno's seeds stand for them.
Below its cutoff Live's high-pass has a floor of its own: about -16 dB at
a 970 Hz cutoff and Q 0.78, -31 dB at 3.1 kHz, -23 dB at Q 0.2, against
RBJ's 12 dB per octave (dn-hp-f07, dn-hp-q0, dn-hp-q1; near the cutoff
at 290 Hz, dn-hp-f03, it follows the high-pass); no form tried fits all
five, and only Glockenspiel Detuned and Marimba Classic use the
high-pass. The scratch harness places events as Live's host does: an
event after 0 s that falls on a whole beat of the set's 120 bpm 48
samples early against the device's 16-sample lag, one off the beat on
time **[measured]** (2.0 s, 1.5 s and 3.5 s on every phrase and held-out
render, 0.8 s on time); it moves no score by more than 0.02. The
held-out stereo failures sit in bands 25 to 40 dB below the loudest
(Bell Plate Long's 2 kHz side 4 dB high, Marimba Glassy's 5 and 13 kHz
2 dB off).

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
