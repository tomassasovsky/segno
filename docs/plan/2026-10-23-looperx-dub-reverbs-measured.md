# Looper X Dub Rack reverbs, measured (#891 Phase 0, for #1430)

Measured on the owner's emulated Looper X 1.0.2 (HG08) in the #891 rig on
2026-10-23. This file holds numbers and formulas only: no vendor code,
disassembly, QML or audio. The captures stay on the rig machine.

## Method

One gated pass per setting through Track 1 PRE, Dub Rack loaded with no
preset, only the pedals named on, Master Vol 0.0 dB. Stimulus (48 kHz):

1. 0.5 s silence, then a single-sample impulse of 0.5, then 10 s of silence.
2. 1 s of white Gaussian noise at -18 dBFS RMS, then 10 s of silence.

Read-outs:
- The dry term is the output sample at lag 0 divided by 0.5. The wet IR is
  the impulse response with that lag-0 term removed.
- Decay: Schroeder backward integral of the wet IR, T30 (fit from -5 to
  -35 dB, scaled to 60 dB), broadband and in octave bands (4th-order
  Butterworth, 125 Hz to 8 kHz). The noise-burst decay gives the same
  numbers to within 0.1 s (checked on every pass).
- Echo density: Abel-Huang normalized echo density over 20 ms windows.
- About 75 passes in two rigs. A repeated pass at identical settings
  reproduces the output to -176 dB: both reverbs are time-invariant (no
  modulation, no randomization).

## Structure

**The rack is two parallel paths, each carrying its own dry, and Amb-Dub
Mix crossfades them. The Doubler, Dub Delay and Dub-Verb sit on the Dub
path; Amb-Verb alone is on the Amb path.**

    out      = A(m) * AmbPath(x) + D(m) * DubPath(x)    -> Comp -> Para EQ -> Master Vol
    AmbPath  = AmbVerb(x)                                (x when Amb-Verb is off)
    DubPath  = DubVerb(DubDelay(Doubler(x)))             (each stage is x -> x when off)
    AmbVerb(u) = dA(volA) * u + WetA(volA, decA) * u
    DubVerb(u) = dD(volD) * u + WetD(volD, decD) * u
    DubDelay(u) = echoes of u only: no dry passes the Dub Delay when it is on

with m = Amb-Dub Mix (0..1) and

    D(m) = (2m)^2        for m <= 0.5,   1 above
    A(m) = 1             for m <= 0.5,   1 - (2m - 1)^2 above

Evidence:
- Dub Delay alone (general-stimulus impulse): lag-0 gain 1.000 at m = 0, 0.4 and
  0.5 and 0.000 at m = 1; first echo 0 at m = 0, 0.409 at m = 0.4 and 0.639
  at m = 0.5 and 1 (0.409 = 0.64 x 0.639). So the delay replaces the Dub
  path's signal with its echoes, and only the Amb path's dry is left.
- Doubler alone: at m = 0 the output is exactly the dry (1.000, no voice);
  at m = 1 it is the Doubler alone (dry 0.31, voice 0.9-1.0). So the
  Doubler is on the Dub path too.
- Parallel, not series: the output with both on equals Dub-alone +
  Amb-alone - (A(m) + D(m)) x, to -98.5 dB at m = 0.5 (A = D = 1, so 2x),
  -99.8 dB at m = 0 and -99.0 dB at m = 1 (A + D = 1, so x). A series pair would leave a
  Dub*Amb cross term; there is none.
- Dub-Verb alone: no wet at all at m = 0; wet at m = 0.4 is 3.87 dB below
  m = 0.5 (0.64 = 0.8^2); m = 0.5 and m = 1 give the same wet.
- Amb-Verb alone: the same wet at m = 0, 0.4 and 0.5; none at m = 1.
- All pedals off, dry gain against m (bar positions read back from the
  screen fill):

  | m | 0 | 0.055 | 0.106 | 0.206 | 0.303 | 0.403 | 0.502 | 0.600 | 0.701 | 0.797 | 0.898 | 0.947 | 1 |
  |---|---|---|---|---|---|---|---|---|---|---|---|---|---|
  | measured | 1.0000 | 1.0125 | 1.0458 | 1.1714 | 1.3697 | 1.6529 | 2.0000 | 1.9576 | 1.8368 | 1.6400 | 1.3600 | 1.1900 | 1.0000 |
  | A + D | 1 | 1.012 | 1.045 | 1.170 | 1.367 | 1.650 | 2.000 | 1.960 | 1.838 | 1.647 | 1.366 | 1.201 | 1 |

  Every point matches to within 0.011; the mix positions are read off the
  screen fill (about 0.003 coarse), and the largest gaps (0.898, 0.947) sit
  where the law is steepest.

## The Dub Rack's +4.31 dB (EQ and dynamics fits)

It is the Amb-Dub Mix law, not a gain stage. At the default m = 0.40 the
two parallel paths both pass the dry signal: A = 1 plus D = 0.8^2 = 0.64,
total 1.64 = +4.30 dB (+4.36 dB at 40.4 %, the value a drag left in one
rig). The gain is flat (identical on the impulse and the noise burst to
0.01 dB) and has no tail.

Isolation, one change at a time, Amb-Dub Mix 40 %:

| state | lag-0 gain |
|---|---|
| FX 1 (whole rack) off | 1.0000 |
| all pedals off | 1.6400 (1.6529 at 40.4 %) |
| all pedals off, mix 0 % or 100 % | 1.0000 |
| Comp alone (Thresh 0, Make-Up 0) | 1.6549 |
| Dub Delay alone | 1.0000 (its path carries echoes only, so only A = 1 is left) |
| Doubler alone, Doubler Mix 100 % | 1.2017 (at 40.4 %: 1 + 0.6529 x 0.31 = 1.202) |
| Para EQ alone | not a pure gain (its default low cut at 36 Hz); flat above it |

It comes from the path mix, so it is ahead of the compressor: that is why
the dynamics fit saw the thresholds offset by 4.3 dB. It is only a plain
boost while the Dub path carries the dry, i.e. with the Dub Delay off. All
11 factory Dub presets have the Dub Delay on, so in them the Dub path
carries echoes only and the dry is A(m) x dA(volA): unity for Amb-Dub Mix
up to 50 % (the presets use 21.7 % to 58.9 %), times the Amb-Verb's dry
gain when it is on. A segno Dub Rack therefore needs the path structure,
not a fixed +4.3 dB trim.

Real signal order (processor slots as in chain_order.csv, read with the
path structure above):

    x -+-> Amb-Verb ----------------------------------------> * A(m) -+
       |                                                              +-> Comp -> Para EQ -> Master Vol
       +-> Doubler -> Dub Delay (wet only) -> Dub-Verb -------> * D(m) -+

## Vol (Dub-Verb Vol, Amb-verb Vol): dry and wet laws

Vol v moves both the path's dry gain and its wet gain. Measured at
Amb-Dub Mix 0.40 and divided out by the mix law:

| v | 0 | 0.1 | 0.2 | 0.3 | 0.4 | 0.5 | 0.7 | 0.85 | 1 |
|---|---|---|---|---|---|---|---|---|---|
| Dub dry dD | 1 | 0.9908 | 0.9767 | 0.9550 | | 0.8959 | 0.8159 | 0.7438 | 0.6616 |
| Amb dry dA | 1 | 0.9962 | | 0.9702 | 0.9488 | 0.9204 | 0.8492 | | 0.7062 |
| wet re v = 1, both | -inf | -18.2 dB | | -9.3 dB | | -5.2 dB | -2.55 dB | -1.13 dB | 0 dB |

Fits (max error 0.004):

    dD(v) = 1 - 0.3384 * v^1.70
    dA(v) = 1 - 0.2938 * v^1.90
    wet gain (both) ~ v^0.9 (0.1225, 0.342, 0.551, 0.746, 0.878 at 0.1, 0.3, 0.5, 0.7, 0.85)

So Vol is a partial crossfade: at 100 % the dry is still 0.66 (Dub) and
0.71 (Amb) of the input.

## Dec: decay against setting

Display (both): (v + 0.45) / (1 - v) s. Measured T30 of the wet IR, at
Vol 100 % (Vol does not change the decay):

**Dub-Verb**

| v | display | 125 | 250 | 500 | 1k | 2k | 4k | 8k | broadband |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 0.45 | 0.39 | 0.28 | 0.30 | 0.38 | 0.34 | 0.36 | 0.36 | 0.36 |
| 0.02 | 0.48 | 0.46 | 0.45 | 0.47 | 0.46 | 0.44 | 0.44 | 0.40 | 0.43 |
| 0.05 | 0.53 | 0.77 | 0.77 | 0.86 | 0.79 | 0.76 | 0.77 | 0.68 | 0.74 |
| 0.1 | 0.61 | 0.99 | 1.02 | 1.08 | 1.05 | 1.00 | 1.02 | 0.95 | 1.00 |
| 0.3 | 1.07 | 1.64 | 1.60 | 1.60 | 1.63 | 1.59 | 1.56 | 1.45 | 1.55 |
| 0.5 | 1.90 | 2.53 | 2.46 | 2.49 | 2.51 | 2.51 | 2.32 | 2.03 | 2.37 |
| 0.6 | 2.62 | 3.38 | 3.41 | 3.38 | 3.32 | 3.23 | 2.92 | 2.44 | 3.08 |
| 0.7 (default) | 3.83 | 4.64 | 4.82 | 4.70 | 4.69 | 4.47 | 3.86 | 3.02 | 4.29 |
| 0.8 | 6.25 | 7.37 | 7.52 | 7.44 | 7.29 | 6.74 | 5.54 | 3.94 | 6.66 |
| 0.9 | 13.5 | 14.43 | 14.67 | 14.40 | 13.94 | 12.35 | 9.12 | 5.50 | 13.17 |

- Not a true RT60 of the display: the mid-band (500 Hz-1 kHz) T60 is
  1.05 to 1.74 x the display for v >= 0.1. Best fit over v >= 0.1:
  T_mid = 1.531 * display^0.845 s (max error 5.5 %), or
  T_mid = 1.085 * display + 0.43 s (6 %).
- Below v = 0.1 it collapses fast: 1.0 s at 0.1, 0.36 s at 0.
- Low and mid bands decay together. Highs decay faster as Dec grows:
  T(8 kHz) / T(1 kHz) = 0.90, 0.89, 0.81, 0.73, 0.64, 0.54, 0.39 at
  v = 0.1, 0.3, 0.5, 0.6, 0.7, 0.8, 0.9. A roughly fixed high-frequency
  loss per pass fits this: the 8 kHz decay rate exceeds the 1 kHz rate by
  4.6 to 7.1 dB/s (6.0, 4.6, 5.7, 6.5, 7.1, 7.0, 6.6 at those settings).

**Amb-Verb**

| v | display | 125 | 250 | 500 | 1k | 2k | 4k | 8k | broadband |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 0.45 | 0.27 | 0.32 | 0.40 | 0.39 | 0.34 | 0.42 | 0.44 | 0.42 |
| 0.1 | 0.61 | 0.29 | 0.42 | 0.46 | 0.48 | 0.45 | 0.50 | 0.51 | 0.51 |
| 0.2 (default) | 0.81 | 0.36 | 0.58 | 0.60 | 0.63 | 0.64 | 0.66 | 0.67 | 0.66 |
| 0.3 | 1.07 | 0.49 | 0.72 | 0.75 | 0.77 | 0.82 | 0.83 | 0.85 | 0.83 |
| 0.5 | 1.90 | 0.71 | 1.10 | 1.21 | 1.24 | 1.33 | 1.32 | 1.33 | 1.32 |
| 0.6 | 2.62 | 0.85 | 1.32 | 1.55 | 1.64 | 1.72 | 1.71 | 1.73 | 1.70 |
| 0.8 | 6.25 | 1.26 | 2.04 | 2.96 | 3.47 | 3.71 | 3.76 | 3.76 | 3.72 |
| 0.9 | 13.5 | 1.51 | 2.91 | 5.08 | 6.56 | 7.36 | 7.58 | 7.60 | 7.49 |

- Shorter than its display: the high-band (2-8 kHz) T60 is 0.55 to 0.88 x
  the display. Fit of the 500 Hz-1 kHz mean: T_mid = 0.719 * display^0.811
  s (max error 2.5 % for v >= 0.1; 4.7 % at v = 0).
- The opposite tilt to Dub-Verb: lows die first. T(125 Hz) / T(2 kHz) is
  0.2 to 0.8 and falls as Dec grows (1.51 s against 7.36 s at v = 0.9);
  2-8 kHz decay together.

## Pre-delay, early pattern, echo density

| | Dub-Verb | Amb-Verb |
|---|---|---|
| first wet sample | lag 1: a short negative tail right after the dry (-0.067, -0.028, -0.011, ... at Vol 100 %), 3 % of the wet energy | none before 24.6 ms |
| first strong arrival | 10.19 ms L, 10.65 ms R | 24.58 ms both (R doubled at 24.67) |
| next arrivals (ms, > -26 dB re the largest) | L 13.77, 15.02, 20.27, 20.35, 22.31, 25.19, 27.52, 29.90; R 15.44, 15.90, 21.27, 22.81, 23.44, 26.52, 30.85 | L 32.79-35.31 cluster, then 76.7, 79.0, 84.3, 88.0; R 34.7-40.9 cluster, then 81.2, 89.2, 93.0 |
| echo density (NED) at 50 / 100 / 200 / 300 ms | 0.24 / 0.40 / 0.59 / 0.90 | 0.36 / 0.40 / 0.87-0.95 / 0.95 |
| NED reaches 0.9 | about 280 ms (330 ms at v = 0) | about 200-220 ms |
| the pattern against Dec | identical arrival times at every Dec; only the gains change | same |

Both build density slowly: sparse discrete echoes for the first 100-200 ms,
a "dub" grain rather than a smooth plate.

## Tone (wet spectrum) and stereo

Wet energy per octave, relative to 1 kHz (whole IR; the first 80 ms gives
the same shape to within 1 dB):

| | 125 | 250 | 500 | 1k | 2k | 4k | 8k |
|---|---|---|---|---|---|---|---|
| Dub-Verb (Dec 0.5-0.8) | -8.5 | -6.0 | -2.5 | 0 | +2.5 | +3.3 to +4.0 | +2.2 to +3.8 |
| Amb-Verb (Dec 0.2-0.8) | -8.7 to -10.0 | -7.2 to -7.8 | -3.0 to -3.3 | 0 | +2.3 to +2.5 | +5.5 to +5.6 | +7.8 to +8.1 |

- Both wet paths are bright: about +3 dB per octave from 125 Hz to 2 kHz.
  Amb-Verb keeps rising to 8 kHz; Dub-Verb flattens above 4 kHz and its
  long settings lose top through the decay.
- Neither rack has a tone or damping control; this tilt is fixed.
- Stereo: mono in, two decorrelated outputs. Wet L/R correlation 0.00-0.04
  (Dub), -0.20 to 0.08 per band (Amb). Left and right carry equal wet
  energy to 0.4 dB.

## Against segno (origin/claude/segno-integration @ 4952e9b0b)

segno has no Dub-Verb or Amb-Verb kind: `kFxModuleBuilds` and
`kFxModuleVariants` have no entry for "Dub reverb" or "Ambience", so both
pedals are `unavailable`, and Amb-Dub Mix (grouped under Ambience) reaches
nothing. The nearest kernel is the generic `LE_FX_REVERB` (Freeverb: 8
combs + 4 all-passes per side, room 0.70 + 0.28 * size, damping 0.4 *
damping, out = x (1 - mix) + wet * mix). Run on the same impulse:

| property | Looper X Dub-Verb | Looper X Amb-Verb | segno LE_FX_REVERB |
|---|---|---|---|
| decay range | 0.36-14.4 s mid (v 0-0.9); 1.0 s at v 0.1 | 0.40-6.6 s mid | 0.53-11.2 s (size 0-1) |
| decay vs display | 1.53 * D^0.845 | 0.72 * D^0.81 | not tied to a display time |
| band decay | highs shorter (8k/1k 0.39 at long settings) | lows shorter (125/2k 0.2-0.8) | highs shorter with damping only; lows never |
| first arrival | lag 1 tail + 10.2 / 10.65 ms | 24.6 ms | 25.3 ms (shortest comb) |
| echo density | NED 0.9 at ~280 ms | ~210 ms | ~240 ms at damping 0.5 |
| wet spectrum | +3 dB/oct tilt to 2 kHz | +3 dB/oct to 8 kHz | flat (damping only cuts highs) |
| dry/wet | dry 1 - 0.338 v^1.7, wet ~v^0.9 | dry 1 - 0.294 v^1.9 | dry 1 - mix, wet mix |
| stereo | decorrelated, equal level | decorrelated | two banks offset 23 samples |
| two-reverb mix | parallel, A(m)/D(m) laws above, +4.3 dB at 40 % | | none |

What Part 8 (#1430) must reproduce:
1. Two parallel paths, each carrying its own dry, mixed by A(m) and D(m)
   above, with the Doubler and a wet-only Dub Delay ahead of Dub-Verb on
   the Dub path. This alone accounts for the Dub Rack's +4.31 dB at the 40 %
   default, so segno's EQ and dynamics fits for the Dub Rack should stop
   treating it as an unexplained trim.
2. Per-reverb Vol laws (dD, dA, shared wet law).
3. Dec to decay: the tables above (or the power-law fits), per band.
4. Dub-Verb: a sparse early pattern starting at 10.2 / 10.65 ms plus the
   tiny immediate tail; Amb-Verb: 24.6 ms pre-delay. Time-invariant.
5. The fixed bright wet tilt and the per-band decay tilts (Dub: HF loss
   grows with Dec; Amb: LF loss).
