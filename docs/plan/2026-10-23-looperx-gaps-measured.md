# Looper X kinds segno built without references, measured (#891 Phase 0)

Measured on the owner's emulated Looper X 1.0.2 (HG08) in the #891 rig on
2026-10-23. Numbers and formulas only: no vendor code, disassembly, QML or
audio. Captures stay on the rig machine. segno is compared at
origin/claude/segno-integration @ 4952e9b0b (`engine_fx.c`); the "segno"
notes describe that commit. Since then the Pitch Shift has landed on the
octaver (#1441) with its formants following the pitch (#1446).

## Method

Gated passes through Track 1 PRE, one pedal on, Master Vol 0.0 dB, 120 BPM.
General stimulus (48 kHz): impulse 0.25; 20 Hz-20 kHz log sweep, 4 s,
-18 dBFS; 1 kHz sine, 4 s, -12 dBFS; 1 kHz ladder -48..0 dBFS in 6 dB
steps; 2 s white noise at -24 dBFS RMS; 2 s silence. Linear responses come
from the noise cross-spectrum (coherence-checked) or the sweep; envelopes
from the 1 kHz sine at 1 ms resolution; time maps (slicer) from the sweep's
instantaneous frequency. Pitch kinds used a separate vowel stimulus (below).
The Dub Doubler and Ed's Wah were measured with the reverb stimulus
(impulse + 1 s noise burst).

## LPF (Lo-Fi and Rhythmic, identical with the LFO at 0)

- A 4-pole (24 dB/octave) resonant low-pass, plus a fixed one-pole high-pass
  near 25 Hz that is always in (-3.9 dB at 20 Hz, -0.9 dB at 50 Hz).
- Passband stays at unity at any resonance (compensated).
- The cutoff is the display: at Reso 100 % it self-oscillates at the display
  frequency (644.5 Hz for 632 Hz shown, 3575.5 Hz for 3557 Hz), a steady
  sine at about -12 dBFS peak that keeps sounding in silence.
- Fit (noise cross-spectrum, 15 Hz-16 kHz, to -60 dB): a 4-pole ladder,
  H = (1 + k) P^4 / (1 + k P^4) with P a bilinear one-pole at fc.
  - Reso 0 %: k = 0.20, fc = 1.04-1.05 x display at 112 and 632 Hz (max
    error 0.25-0.6 dB); at 3557 Hz shown the fit wants 1.13 x display at a
    2x-oversampled rate (max error 0.6 dB).
  - Reso 50 %: k = 2.1 (fc 1.03 x display, max error 0.5 dB).
  - Reso 100 %: oscillates, so k reaches the ladder limit of 4:
    k ~ 0.2 + 3.8 x Reso.
- At 20 kHz (the default) the filter is effectively off: -0.2 dB at 10 kHz.
- Rhythmic LPF LFO (Rate 1/2 = 1.0 s at 120 BPM, a sine in log frequency):
  Depth 50 % swings the cutoff about +-1.4 octaves (the -12 dB point from
  430 Hz to 2.9-3.4 kHz around 1.2 kHz); Depth 100 % about +-4 octaves or
  more (below 60 Hz to above 12.8 kHz). Two points fit a swing of
  0.5 x Depth^2 in the stored cutoff value (+-1.25 and +-5 octaves).

segno `LE_FX_LPF`: 12 dB/octave SVF, Q 0.71..3 (+9.5 dB peak at 100 %), no
self-oscillation, no high-pass, Rhythmic LFO unmapped. Needs: 4-pole ladder,
k ~ 0.2 + 3.8 Reso with self-oscillation at 100 % (both racks' presets
default to Reso 100 % with the cutoff at 20 kHz, where it is inaudible),
the 25 Hz high-pass, and the LFO.

## Vinyl (Lo-Fi)

Linear part (sweep, -18 dBFS), dB:

| setting | 50 | 100 | 200 | 300 | 500 | 1k | 2k | 5k | 8k | 12k | 16k |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Drive 0 %, Freq 251 Hz | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 |
| Drive 40 % (default), 251 Hz | -6.0 | -6.0 | -6.0 | -5.7 | -3.0 | -3.0 | -3.5 | -3.7 | -3.5 | -3.2 | -2.9 |
| Drive 100 %, 251 Hz | -5.8 | -5.8 | -5.2 | -1.0 | +5.2 | +4.8 | +4.6 | +4.6 | +5.0 | +5.7 | +6.3 |
| Drive 40 %, Freq 50 Hz | -6.1 | -2.7 | -3.0 | -3.4 | -3.6 | -3.7 | -3.7 | -3.7 | -3.5 | -3.2 | -2.9 |
| Drive 40 %, Freq 1256 Hz | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -4.7 | -2.4 | -2.8 | -2.5 | -2.3 |
| Drive 40 %, Freq 5000 Hz | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -6.0 | -5.9 | -4.0 | 0.0 | +1.9 |

- The whole signal is passed at 0.5 (-6.0 dB). Above a split at about 1.6 x
  the Freq display, a driven copy is added on top: its fundamental adds
  0 (Drive 0), +0.21 (40 %) and +1.2 (100 %) of the input.
- The driven copy is a full-wave rectifier, |x|, not a saturator: only even
  harmonics and DC, at a level that does not depend on the input from -48 to
  -12 dBFS. Relative to the fundamental: H2 -5, H4 -20, H6 -27, H8 -32 dB at
  Drive 40 % (the |sin| series is -14, -21, -26 dB below H2); H2 +11 dB at
  100 %. THD is -5 dB at 40 % and +11 dB at 100 % from -48 dBFS up. Above
  -12 dBFS it also clips (H3 -40 dB at 0 dBFS).
- Noise (silence, octave bands, dBFS): Noise 100 %, Tone 90 %: -8 (63 Hz),
  -21 (250), -26 (500-1k), -19 (4k), -11 (16k); crackle peaks to -7 dBFS at
  about 14 clicks/s; L/R correlation 0.90. Tone 0 %: highs cut (-30 at 8k,
  -38 at 16k), about 7.5 clicks/s. Noise 50 %: about 20 dB lower than 100 %.
  The noise has a strong low end (63 Hz loudest), unlike white hiss.
- Drive 40 %, Noise 0 % still leaves a -81 dBFS floor with sparse clicks
  (0.5/s); Drive 0 % is clean (-137).

segno `LE_FX_VINYL`: 12 dB/oct high-pass at Freq, 7 kHz low-pass, tanh drive
1..10, hiss -34 dBFS + 8 clicks/s through a 0.5-12 kHz tone low-pass, no
dry level change. Needs: the 0.5 dry gain, the band split at ~1.6 x Freq,
a rectified (even-harmonic) drive added above it with fundamental gain
0 / 0.21 / 1.2 at 0 / 40 / 100 %, and a bass-heavy noise bed.

## Degrade (Lo-Fi)

- Sample-and-hold at about the display rate: images at hold - 1 kHz and
  hold + 1 kHz put the hold at 1621 Hz (display 1581), 5076 Hz (5000) and
  15 897 Hz (15 811).
- Filter 100 % (default) means no filter: images at -12 to -17 dBc (the
  hold's sinc only). Filter 0 % is the strongest: a very steep low-pass at
  about 0.25 x the hold rate (5000 Hz hold: -3 dB at 1.24 kHz, -12 dB at
  1.40 kHz, -26 dB at 2 kHz, -44 dB at 3 kHz; 1581 Hz hold: -3 dB at 410 Hz,
  -12 dB at 463 Hz), with a +3 to +7 dB rise just below it; images fall to
  -68 to -79 dBc. Filter 50 %: corner moves up (images -9 to -26 dBc).
- Mix: 0 % is bit-exact dry; 50 % is a sum of dry and held (1 kHz -3.7 dB,
  comb ripple between).
- Display 50 kHz (default) holds every sample: transparent (1 kHz -0.1 dB).

segno `LE_FX_DEGRADE`: Filter 0 % = open (20 kHz), 100 % = 2-pole low-pass
at half the hold rate. The Looper X runs the other way: 0 % = steep filter
at ~0.25 x the hold rate, 100 % = none. segno's control is inverted and its
filter is far shallower.

## Wah (Guitar and Ed's are the same filter)

Band-pass with skirts falling about 6 dB/octave; peak gain, centre and
-3 dB bandwidth against Wah Pedal (Guitar and Ed's agree to 0.5 dB and 1 %):

| Pedal | 0 | 0.25 | 0.5 | 0.619 (Ed's default) | 0.75 | 1 |
|---|---|---|---|---|---|---|
| peak | 439 Hz | 459 Hz | 536 Hz | 749 Hz | 1208 Hz | 2313 Hz |
| gain | +13.1 dB | +13.8 | +11.2 | +12.5 | +10.9 | +13.1 |
| -3 dB band | 419-458 | 438-480 | 501-573 | 686-817 | 1057-1379 | 1832-2920 |
| Q (f/BW) | 11.3 | 10.9 | 7.4 | 5.7 | 3.8 | 2.1 |
| 50 Hz / 10 kHz | -17 / -34 dB | -17 / -32 | -18 / -29 | -16 / -23 | -17 / -17 | -22 / -5 |

- The sweep is not log-linear: most of it happens in the top half of the
  pedal (439 to 536 Hz over 0-0.5, then 536 to 2313 Hz over 0.5-1).
- Neither constant-Q nor constant-bandwidth: the bandwidth grows from 39 Hz
  to 1.1 kHz as the peak rises, and Q falls from 11 to 2.

segno `LE_WAH`: 350-2500 Hz log sweep, Q 4, +6 dB peak. Needs: 439-2313 Hz
with the curved taper above, Q 11 at the heel falling to 2 at the toe, peak
+11 to +14 dB.

## Doubler (Dub, Studio, Vocal)

All three are a random-delay voice, not an LFO-swept delay: each output side
holds one delay for about 125-175 ms, crossfades over about 25 ms to a new
random delay, and left and right draw independently (time-varying: two passes
at the same setting never match). No pitch wander was found on a steady
1 kHz tone apart from the crossfades.

| rack, setting | lag-0 (dry) gain | voice gain | voice delays seen |
|---|---|---|---|
| Studio, Mix 100 % (default) | 0.31 | 0.9-1.0 | 5.8-48.6 ms |
| Studio, Mix 50 % | 0.31 | 0.9-1.0 | 0.7-41.5 ms |
| Vocal, Mix 100 % (default) | 0.31 | 0.9-1.0 | 9.0-49.2 ms |
| Vocal, Mix 50 % | 0.31 | 0.9-1.0 | 9.4-45.5 ms |
| Vocal, Mix 0 % | 1.26-1.65, fluctuating every ~50 ms | voice at about 0-1 ms, summing with the dry | |
| Dub, Sep 0 %, Mix 100 % | 0.31 | 0.9 | 0.2-1.0 ms |
| Dub, Sep 50 %, Mix 100 % | 0.31 | 0.9 | 4.0-51.2 ms |
| Dub, Sep 100 %, Mix 100 % or 50 % | 0.31 | 0.9-1.0 | 1.0-100.8 ms |
| Dub, Sep 100 %, Mix 0 % | 1.26-1.63, fluctuating | voice collapses to about 0 ms | |

(The Doubler sits on the Dub path, so Dub values are (output - A(m)) /
D(m) with the mix law in 2026-10-23-looperx-dub-reverbs-measured.md; checked directly at
Amb-Dub Mix 100 %, where the Dub path is all that is heard.)

- Mix 50 % and 100 % sound the same; Mix 0 % does not remove the voice, it
  collapses its delay to about zero, so the dry gets louder with a
  comb-filtered flutter (+2 to +4.4 dB on a 1 kHz tone in Studio).
- Dub Sep sets the random delay range: up to about 1 ms at 0 %, 51 ms at
  50 %, 100 ms at 100 %.

segno `LE_FX_DOUBLER`: two LFO-drifting voices at 11 and 17 ms (+-0.6 ms),
-3 dB each, panned by separation, dry untouched, mix scales the voices.
Needs: random-delay voices (hold ~150 ms, ~25 ms crossfade, independent
L/R), the ranges above, dry cut to 0.31 in all three racks at Mix 50 % and
above, voice at 0.9-1.0, and the Mix-0 % collapse.

## Studio Mod: Tremolo (Mod Mode = Tremolo)

Partly characterized; the Mod pedal also carries the Doubler (Doubler Mix
on the same panel), and its Mix-0 % flutter (above) stays in every pass.
- Depth 100 %, Rate 25 %: a hard chop, not a sine. Each cycle (1.47 s,
  0.68 Hz) the gain falls as a straight line in dB to below -150 dB over
  about 600 ms, then snaps back to full level.
- Depth 0 %: no tremolo (only the Doubler flutter, +2.0 to +4.4 dB).
- Depth 50 % at Rate 25 % produced silence through the whole 4 s tone, and
  Rate 0, 50 and 100 % at Depth 50 % gave periods that do not order with
  the rate (the doubler flutter dominates). These need a longer stimulus
  with the doubler isolated before a fit; not fitted here.

segno `LE_FX_TREMOLO`: sine LFO 0.1-12 Hz, linear depth. The one clean
measurement (Depth 100 %) is a decaying chop, so the shape differs.

## Delay mode RES HI GRV (Guitar, 1/8D at 120 BPM = 375 ms)

| mode, Feedback 0 %, Mix 30 % | left first echo | right first echo | first-echo spectrum re 1 kHz |
|---|---|---|---|
| RESO HI | 375.0 ms, 0.274 | 375.0 ms, 0.256 | 100 Hz -2.4, 2 kHz +3.7, 3 kHz +3.8, 8 kHz -3.1 |
| RES HI L/R | 375.0 ms, 0.064 | 187.5 ms, 0.256 | 2 kHz +6.1, 4 kHz +4.1 |
| RES HI GRV | 375.0 ms, 0.219 (and 0.031 at 313.8 ms) | 313.8 ms, 0.256 (and 0.037 at 375 ms) | 100 Hz -1.8, 2 kHz +2.2, 3 kHz +3.8, 8 kHz -1.6 |
| RESO LO (ref., Feedback 50 %) | 375.0 ms, 0.252 | 375.0 ms, 0.240 | 100 Hz -7.0, 500 Hz -3.7, 2 kHz -3.9, 8 kHz -8.5 |

- RES HI GRV = the RESO HI voicing with the GRV timing: the right side's
  first echo at 0.837 of the period (313.8 ms), the left at the period, and
  about -17 dB of each side leaking into the other.
- With Feedback 50 % the repeats keep the offset: left 750 ms, right
  688.8 ms (313.8 + 375), each about 0.24 of the one before.
- Dry stays at unity; Mix 30 % gives a first echo of about 0.22-0.27.

## Slicer step length and Pumper rate (Rhythmic, 120 BPM)

- Slicer step = the note value: 1/4 500 ms, 1/8 250 ms, 1/16 125 ms, 1/32
  62.5 ms, 1/64 31.25 ms (each measured as the replay offset in AABB, where
  the second step replays the first). The slicer replays buffered audio
  (letters are slices, not gates); a slice ends with a ~4 ms fade and starts
  without one.
- Pumper period = the note value: Bar 2000 ms, 1/2 1000, 1/4 500, 1/8 250,
  1/16 125. The shape is the same at every rate and depth:
  gain = 1 - a(Depth) x e(phase), with a = 0.50 (30 %), 0.901 (70 %),
  0.990 (100 %), i.e. dips of 6, 20 and 40 dB. e(phase), phase 0 at the
  beat, every 1/20 of the period:
  1.000 0.994 0.984 0.970 0.948 0.918 0.876 0.820 0.746 0.654 0.544 0.418
  0.284 0.153 0.045 0, then 0 for the last quarter (phase >= 0.75).

segno has no Slicer or Pumper kind (`unavailable`, waiting on part 10).

## Pitch: formants against pitch (for Part 9)

Stimulus: a band-limited sawtooth at 110 Hz and at 220 Hz (3 s each) through
three formant resonators at 700, 1200 and 2600 Hz (bandwidths 80, 90,
120 Hz), -12 dBFS peak. For each pass the output's harmonic amplitudes were
compared with the input's spectral envelope (read from the 110 Hz input,
harmonics every 110 Hz), testing out_env(f) = in_env(f / s) over s = 0.45 to
2.2.

| kind, setting | f0 out (110 / 220 in) | pitch ratio | semitones | envelope shift s | error at s = 1 / s = ratio |
|---|---|---|---|---|---|
| Whammy, pedal 0 (either range) | 110.0 / 220.0 | 1.000 | 0 | 1.001 | 0.1 / 0.1 dB (transparent) |
| Whammy -12, pedal 50 % | 84.5 / 169.5 | 0.768 / 0.770 | -4.57 / -4.52 | 0.767 / 0.773 | 9.3 / 0.7 dB |
| Whammy -12, pedal 100 % | 55.0 / 110.0 | 0.500 | -12.00 | 0.499 | 8.1 / 0.6 dB |
| Whammy +12, pedal 50 % | 143.5 / 286.5 | 1.305 / 1.302 | +4.61 / +4.57 | 1.307 | 10.7 / 0.6 dB |
| Whammy +12, pedal 100 % | 221.0 / 442.5 | 2.009 / 2.011 | +12.08 / +12.10 | 2.008 | 8.7 / 0.4 dB |
| Studio Pitch, shift 0 (v 0.5) | 110.0 / 220.0 | 1.000 | 0 | 1.001 | 0.1 / 0.1 dB |
| Studio Pitch, -6 (v 0.25) | 78.0 / 156.5 | 0.709 / 0.711 | -5.95 / -5.91 | 0.708 / 0.711 | 9.4 / 0.6 dB |
| Studio Pitch, -12 (v 0) | 55.0 / 110.0 | 0.500 | -12.00 | 0.499 | 8.1 / 0.6 dB |
| Studio Pitch, +6 (v 0.75) | 156.0 / 312.0 | 1.418 | +6.05 | 1.420 / 1.426 | 10.9 / 0.6 dB |
| Studio Pitch, +12 (v 1) | 221.0 / 442.5 | 2.009 / 2.011 | +12.08 / +12.10 | 2.008 | 8.7 / 0.4 dB |

**The spectral envelope moves with the pitch, fully.** In every shifted pass
the formants move by the pitch ratio (best envelope shift = the pitch ratio
to within 1 %, i.e. 99-102 % of the shift in log frequency). Keeping the
formants in place fits 7-11 dB RMS worse. A 700/1200/2600 Hz vowel shifted
-12 comes out with formants at about 350/600/1300 Hz, and +12 at about
1400/2400/5200 Hz: neither the Whammy nor the Studio Pitch pedal preserves
formants (a resampling-type shifter, the "chipmunk" character).

- Whammy pedal taper: 50 % gives 4.6 semitones of the 12 (38 %), not 6.
- Studio Pitch is exactly its display, -12 + 24 v semitones, except +12,
  which lands 8 cents sharp (ratio 2.009); the Whammy's +12 does the same.
- The Vocal Tuner Harmonizer was not captured with the vowel stimulus this
  session (its voices are set from scale and interval selectors; not
  reached in time).

segno: no Whammy or Pitch Shift kind yet (both `unavailable`). The nearest
kernel, `LE_FX_OCTAVER`, is formant-preserving in both modes (the phase
vocoder re-applies a cepstral envelope; PSOLA keeps the grain spectrum).
The Looper X does the opposite: for Part 9 a Whammy / Pitch Shift that
matches must let the formants move with the pitch.

## Re-read for the fit (#1445)

Corrections and additions from the same captures, read while fitting
segno's kernels to them. Where these differ from the sections above, these
hold.

- **LPF.** The noise responses fit a ladder with k = 0.2 + 4.2 Reso^1.15
  (0.20 at 0 %, 2.06 at 50 %) and the corner at 1.04 x the display at 0 %;
  the oscillation sits at 1.02 x (632 Hz) and 1.005 x (3557 Hz) the
  display. The self-oscillation peaks at 0.251 (632 Hz) and 0.279
  (3557 Hz). A 1 kHz tone at 632 Hz, Reso 50 %, comes out at -9.7 dB from
  -48 dBFS and -17.1 dB at 0 dBFS. The output carries a second harmonic
  that grows with level (-23 dBc for a -12 dBFS tone above the corner,
  -28 dBc at 3557 Hz, Reso 0 %), and no DC.
- **Vinyl, drive.** On the 1 kHz ladders the fundamental is 0.500 x the
  input at every drive and frequency until the output nears 0.5; the
  driven copy adds only DC and even harmonics. Per unit input amplitude A
  (below the limit): H4 = 0.0849 c1, DC = 0.637 c1 + c2 A / 2,
  H2 = 0.424 c1 + c2 A / 2, the full-wave rectifier's series plus a square
  law. c1 = 0.621, 0.600, 0.471 and 0.024 at Freq 251, 50, 1256 and
  5000 Hz (Drive 40 %), 3.88 at Drive 100 % (Freq 251); c2 / c1 = 4.4 at
  40 % and 4.5 at 100 %. c1 against frequency (from the sweep's 4th
  harmonic) rises 12 dB/octave below Freq with a small peak just above it:
  a 2nd-order high-pass at Freq, Q about 1.1. The "+0.21 / +1.2"
  fundamental in the sweep table above is the copy's products, not a
  linear gain.
- **Vinyl, limit.** Past an output peak of 0.5, everything (fundamental,
  DC, harmonics) scales down together: H1 / A = 0.201 at -6 dBFS and 0.065
  at 0 dBFS (Drive 40 %), 0.114 at -12 dBFS (Drive 100 %). After a loud
  tone stops the gain recovers 0.229, 0.458 (100 ms), 0.700 (200 ms),
  0.842 (280 ms), 1.0 (580 ms).
- **Vinyl, noise.** The octave-band numbers above are not dBFS. In dBFS
  (12 dB/octave band edges, mean power over 2 s of silence), Noise 100 %,
  Tone 90 %: -58.0 (63 Hz), -65.6 (250), -70.7 (1k), -64.3 (4k), -57.6
  (16k); these means are set by a few large clicks. Between the clicks
  (median 20 ms frame): -63.5, -69.7, -79.3, -74.7, -69.5; Tone 0 %:
  -64.6, -72.7, -80.4, -74.1, -90.1; Tone 50 %: -64.4, -71.1, -80.6,
  -73.1, -77.6; Noise 50 %, Tone 50 %: -84.0, -91.8, -101.4, -95.0, -99.5;
  Noise 30 %, Tone 90 %: -95.8, -104.5, -112.9, -107.6, -102.8. The tone
  does not lift the bed below its corner. Peaks over 0.1: 1.6 a second
  (Tone 90 %), 1.1 (0 %), 1.6 (50 %); largest 0.43, 0.12, 0.50. With the
  noise at 0 % the silence is clean (-137 dBFS) at any drive; the -81 dBFS
  floor with sparse clicks noted in the Vinyl section above did not show in
  these passes.
- **Degrade.** The 1 kHz tone: +3.1 dB at Filter 0 % (5000 Hz), +0.8 dB
  at 50 %, +0.1 dB at 100 %; -47.6 dB at Filter 0 % (1581 Hz) and -3.1 dB
  at 100 %. The Filter 0 % responses fit two 2nd-order low-pass sections
  (Q 0.91 and 1.83) at 0.194 x the hold (2.4 dB rms below 0.8 x the hold);
  Filter 50 % fits the same at 0.89 x (3.0 dB rms). The held path lags the dry by about
  10 samples (8-sample impulse peak at 50 kHz, 17 samples of group delay at
  5000 Hz), and Mix 50 % gives -4.2 dB on the 1 kHz tone.
- **Wah.** Each pedal position fits one state-variable filter with mixed
  outputs, H(s) = (hp s^2 + bp s / Q + lp) / (s^2 + s / Q + 1), within
  0.06 dB rms (30 Hz-15 kHz):

  | Pedal | f0 | Q | bp | lp | hp |
  |---|---|---|---|---|---|
  | 0 | 438.6 Hz | 11.43 | 4.325 | 0.130 | 0.0153 |
  | 0.25 | 459.0 Hz | 11.23 | 4.703 | 0.140 | 0.0184 |
  | 0.5 | 536.1 Hz | 7.49 | 3.551 | 0.127 | 0.0267 |
  | 0.619 (Ed's) | 748.8 Hz | 5.74 | 4.177 | 0.161 | 0.0546 |
  | 0.75 | 1208.5 Hz | 3.75 | 3.514 | 0.159 | 0.1023 |
  | 1 | 2311.5 Hz | 2.10 | 4.517 | 0.140 | 0.3717 |

  The lp term is the floor below 100 Hz (about -17 dB) a pure band-pass
  misses.
- **Doubler.** The Studio and Vocal racks' copies reach 49 ms, as the Dub
  Rack's do at Sep 50 % (51 ms).
