# Looper X dynamics, measured (#891 Phase 0)

Measured on the owner's emulated Looper X 1.0.2 (HG08) in the #891 rig on
2026-10-23. This file holds numbers and formulas only: no vendor code,
disassembly, QML or audio. The captures stay on the rig machine.

## Method

One gated pass per setting through Track 1 PRE, with only the module under
test on and Master Vol at 0.0 dB. The stimulus is 27.9 s at 48 kHz:

1. A 0.05 impulse.
2. A 1 kHz ladder, -60 to 0 dBFS peak in 3 dB steps of 0.4 s, going up.
3. The same ladder going down.
4. A 1 kHz burst: -40 dBFS for 1 s, -10 dBFS for 1 s, -40 dBFS for 1.5 s.
5. A 1 kHz burst: -80 dBFS for 1 s, -20 dBFS for 1 s, -80 dBFS for 1.5 s.
6. Four drum-like hits, 0.5 s apart: a 150 Hz sine decaying with tau 60 ms
   plus a 2 ms noise click, -6 dBFS peak.

How the passes were read:
- Static gain: measured over the last 100 ms of each ladder step.
- Gain against time: read at every sine crest, so the resolution is 0.5 ms.
- Levels: dBFS peak of the sine.
- The high-pass curves come from separate passes with the EQ stimulus
  (impulse plus a -30 dBFS sweep), using the sweep estimate, because the gate
  chops a lone impulse.
- 69 dynamics passes: Ed's compressor 13; Drum compressor 10; Dub
  compressor 5; Vocal compressor 3; Studio and Vocal Tuner compressors 1
  each; Transient 18; HP/Gate 9 in Vocal; high-pass sweeps 4 in Vocal and 5
  in Vocal Tuner.

## Compressor

### Static curve (every rack)

The gain computer is a quadratic soft knee, the Giannoulis form, with knee
width W = 15.0 dB. For an envelope level L (dB), threshold T and ratio R:

    d = L - T
    GR = 0                              when 2d < -W
    GR = (1 - 1/R) * d                  when 2d >  W
    GR = (1 - 1/R) * (d + W/2)^2 / (2W) otherwise

How well it fits:
- RMS error is 0.0000 dB per pass on all 21 ladder points, in all 13 Ed's
  passes.
- The fitted ratios are exactly 2.000, 4.000 and 99.94 for displays of 2, 4
  and 100.
- The knee is 15.00 dB at thresholds of -10.4, -21, -30.2 and -40.1.
- T is the displayed threshold.

The level L is a peak envelope with attack and release, so on a steady sine
it sits below the sine's peak. The amount depends only on attack and
release:

| attack / release (Ed's, as shown) | L minus sine peak |
|---|---|
| 0.01 ms / 993 ms | -0.02 dB |
| 0.01 ms / 5 ms | -0.59 dB |
| 1.73 ms / 141 ms (default) | -0.86 dB |
| 29.68 ms / 993 ms | -1.18 dB |
| 29.68 ms / 141 ms | -3.00 dB |

### Detector and timing (Ed's, all controls shown)

| model | fit to the ladders and bursts of 6 passes |
|---|---|
| A: one-pole envelope on \|x\| in the linear domain, branching (attack coefficient while \|x\| > env); static curve applied to 20 log10(env) | attack tau about 0.96 x display, release tau about 0.47 x display; residual 0.23 dB RMS |
| B: gain reduction smoothed in dB, segno's current form | 0.52 dB RMS |
| C: RMS (x^2) detector | 0.94 dB RMS |

Model A is the closest. The residual is largest on the fastest release
(5 ms).

Step metrics. The burst goes from -40 to -10 dBFS and back, at threshold
-30.2, ratio 4 and make-up 0. t50 and t90 are the times to 50 % and 90 % of
the gain change.

| attack / release | GR at -10 | attack t50 / t90 | release t50 / t90 |
|---|---|---|---|
| 1.73 / 141 ms | 14.5 dB | 1.75 / 7.25 ms | 96.8 / 191.8 ms |
| 29.68 / 141 ms | 12.9 dB | 10.75 / 42.75 ms | 86.2 / 174.8 ms |
| 29.68 / 993 ms | 14.3 dB | 12.25 / 60.25 ms | 546 / 1089 ms |
| 0.01 / 993 ms | 15.1 dB | < 0.25 / < 0.25 ms | 579 / 1142 ms |
| 0.01 / 5 ms | 14.9 dB | < 0.25 / < 0.25 ms | 5.2 / 9.8 ms |

At the defaults with threshold -21 (GR 7.6 dB): attack 3.25 / 10.75 ms,
release 53.2 / 121.2 ms.

### Make-up gain

Make-up does not follow its display. The applied gain was read as the
low-level gain; it is the same at every threshold and in every rack. Its
display is 0..30 dB, linear in v.

| v | display | applied dB |
|---|---|---|
| 0 | 0.0 | 0.0 |
| 0.06 | 1.8 | 3.25 |
| 0.106 | 3.2 | 6.16 |
| 0.20 | 6.0 | 10.08 |
| 0.303 | 9.1 | 12.86 |
| 0.40 | 12.0 | 14.80 |
| 0.50 | 15.0 | 16.32 |
| 0.60 | 18.0 | 17.53 |
| 0.75 | 22.4 | 19.08 |
| 0.80 | 24.0 | 19.52 |
| 0.90 | 27.0 | 20.34 |
| 1.0 | 30.0 | 21.07 |

For v >= 0.2 the applied gain is about 21.07 + 6.85 * ln(v) dB, to within
0.1 dB. Below 0.2 it rises faster than that and reaches 0 at v = 0. No
closed form fitted every point to better than 0.2 dB, so use the table with
interpolation.

### Racks that hide controls

| rack | shown | ratio (measured) | knee | timing (same metrics) |
|---|---|---|---|---|
| Ed's | all five | as shown | 15 dB | as above |
| Drum | Thresh, Attack (0.1..300 ms), Make-Up | 4.000 | 15 dB | see note 1 |
| Vocal | Thresh, Make-Up | 4.000 | 15 dB | see note 2 |
| Dub | Thresh, Make-Up | **6.0** | 15 dB | see note 3 |
| Studio | Thresh, Make-Up | 4.000 | 15 dB | identical to Vocal: the default pass matches it to 0.01 dB on every ladder step and in timing |
| Vocal Tuner | Thresh, Make-Up | 4.000 | 15 dB | default (T -30, make-up v .4 = 14.8 dB), GR 14.1 dB at -10: attack 1.25 / 5.25 ms, release 37.8 / 75.2 ms; Ed's 1.73 / 141 at the same depth gives 1.75 / 7.25 and 96.8 / 191.8 |

1. **Drum.**
   - Attack follows its control: 0.1 / 0.5 ms give t50 < 0.25 ms; 30 ms
     gives t50 11.75 ms.
   - The hidden release is faster than Ed's default. At threshold -21 (GR
     8 dB), release t50 / t90 is 14.2 / 32 ms; Ed's 141 ms gives
     53.2 / 121.2 ms at the same depth.
   - Fitted with model A, the release tau is 22 ms, which is the
     model-equivalent of a release control near 45 ms.
2. **Vocal.**
   - At threshold -21 (GR 7.6 dB): attack 2.25 / 7.25 ms, release
     21.2 / 48.2 ms.
   - Ed's 1.73 / 141 ms gives 3.25 / 10.75 and 53.2 / 121.2 ms at the same
     depth. So the hidden attack is somewhat faster (about 1.2 ms) and the
     release is about 55 to 65 ms, not 141 ms. Model A gives attack tau 2.1 to 3.0 ms and release tau
     30 to 32 ms.
3. **Dub.**
   - The rack adds +4.31 dB of broadband gain ahead of the compressor. It is
     there with every pedal off.
   - Fitted thresholds at the compressor input (they include the detector's
     bias):
     - display -48: -47.26;
     - display -21: -20.56.
   - Attack is fast (t50 <= 0.75 ms). Release t50 / t90 is 37 / 79 ms at
     12.4 dB of reduction.
   - At 0 dBFS input the curve drops a further 0.7 to 1.2 dB, probably
     because, after the +4.31 dB, the signal is above full scale inside the
     rack.

## Transient shaper (Drum Rack)

- Attack 50 % with Sustain 50 % (Length 50 %) is transparent (0.00 dB on
  every measure).
- Attack Length changes only the attack behaviour. Sustain changes only the
  decay behaviour.

Measured on a 1 kHz step of +30 dB (-40 to -10 dBFS), a step of +60 dB, a
step of -30 dB, and the first drum hit. Columns:
- "onset": the peak gain change at the step.
- "half": the time for that change to halve.
- "drop peak": the largest gain change after the -30 dB step, and when it
  happens.
- "back": the time until the gain is within 1 dB of 0 again.
- "hit onset" / "hit tail": the hit's level change in its first 5 ms and
  over 50-300 ms.

| Attack / Length / Sustain | onset +30 | half | onset +60 | drop peak (at ms) | back | hit onset | hit tail |
|---|---|---|---|---|---|---|---|
| 60/50/60 (default) | +4.7 | 9.8 ms | +5.7 | +7.8 (286) | 638 ms | +4.0 | +0.3 |
| 100/0/50 | +10.0 | 5.8 ms | +13.6 | 0 | | +8.0 | 0.0 |
| 100/50/50 | +10.0 | 14.8 ms | +15.0 | 0 | | +9.4 | 0.0 |
| 100/100/50 | +10.0 | 38.2 ms | +16.0 | 0 | | +9.7 | +0.4 |
| 90/50/50 | +10.0 | 12.8 ms | +13.4 | 0 | | +9.0 | 0.0 |
| 75/50/50 | +9.0 | 10.8 ms | +10.4 | 0 | | +7.6 | 0.0 |
| 75/100/50 | +9.4 | 26.2 ms | +11.3 | 0 | | +8.5 | +0.2 |
| 25/50/50 | -9.2 | 10.2 ms | -11.0 | 0 | | -4.1 | 0.0 |
| 0/50/50 | -14.7 | 10.8 ms | -17.3 | 0 | | -4.6 | 0.0 |
| 50/50/100 | 0 | | 0 | +18.3 (286) | 784 ms | 0.0 | +2.4 |
| 50/50/90 | 0 | | 0 | +16.6 (286) | 764 ms | 0.0 | +1.8 |
| 50/50/75 | 0 | | 0 | +13.3 (286) | 721 ms | 0.0 | +1.0 |
| 50/50/25 | 0 | | 0 | -13.0 (287) | 718 ms | 0.0 | -0.3 |
| 50/50/0 | 0 | | 0 | -18.3 (287) | 784 ms | 0.0 | -0.4 |
| 50/0/100 and 50/100/100 | 0 | | 0 | +18.3 (286) | 784 ms | 0.0 | +2.4 |

Read-outs:
- **Attack.**
  - The boost saturates near +10 dB on a 30 dB step, and near +15 dB on a
    60 dB step.
  - The cut is deeper: -14.7 dB at 0 %.
  - Against the amount a = 2*Attack - 1, the boost reaches about 0.47 of its
    maximum at a = 0.2, 0.9 at a = 0.5, and 1.0 at a >= 0.8.
- **Attack Length.** The half-decay time of the boost is
  5.8 ms x 6.5^Length (5.8 / 14.8 / 38.2 ms at 0 / 50 / 100 %).
- **Sustain.**
  - After a 30 dB drop, the gain change peaks at 286 ms whatever the
    setting. The size is 18.3 dB x f(s), with s = 2*Sustain - 1 and
    f(0.5) = 0.73 and f(0.8) = 0.91, close to sqrt(|s|).
  - It is back within 1 dB of 0 at 720 to 785 ms.
  - On a hit that decays with tau 60 ms, 100 % lifts the 50-300 ms tail by
    only +2.4 dB.

## HP/Gate (Vocal and Vocal Tuner racks)

### High-pass

High-pass at Highpass v = 0, .5, .75 and 1 (1, 31.6, 177.8 and 1000 Hz on
screen). Each is a 2nd-order high-pass (12 dB/oct).

| rack | display 31.6 Hz | 177.8 Hz | 1000 Hz |
|---|---|---|---|
| Vocal Tuner | f0 16.1 Hz, Q 0.667 | 89.9 Hz, Q 0.664 | 512 Hz, Q 0.651 |
| Vocal | f0 16.1 Hz, Q 0.667 | 89.9 Hz, Q 0.664 | 512 Hz, Q 0.651 |

Vocal and Vocal Tuner give the same numbers to 0.01 Hz. The corner sits at
0.51 x the displayed frequency (16.06/31.62, 89.9/177.8, 512.4/1000), with
Q 0.65 to 0.67 and unity passband. RMS fit error is 0.005 to 0.014 dB.
Steady 1 kHz at display 1000 Hz: -0.22 dB. 150 Hz in the hits: -21.1 dB.

### Gate (Vocal, levels as sine peak)

| property | measured |
|---|---|
| detector | peak: a sine whose peak is at T opens it (T = -42 opened at -42; T = -41 stayed shut at -42) |
| open threshold | peak >= T |
| close threshold | peak < T - 6 dB; the hysteresis is between 6 and 7 dB across T = -20, -30, -40, -41, -42 |
| attack | fully open by the first crest after the step, under 0.25 ms; a step that lands exactly at T opens over about 0.5 ms |
| hold | about 250 ms after the level falls below T - 6 (gain still within 1 dB at 249.8 to 250.2 ms) |
| release | a straight ramp in dB of 2.7 dB/ms after the hold (an exponential gain decay with tau about 3.2 ms): -60 dB at 272 ms, -100 dB at 286 ms |
| closed gain | -120.6 dB (1e-6); the output is exactly 0 when that falls below the 32-bit floor |
| Gate Thresh -120 (v 0) | never closes on any signal in the stimulus |

## Against segno (origin/claude/segno-integration, PR #1423)

### Compressor

Each row is the measured output minus segno's kernel, run on the same
stimulus, in dB at input levels -36 to 0 dBFS in 3 dB steps.

| Ed's setting | -36 | -33 | -30 | -27 | -24 | -21 | -18 | -15 | -12 | -9 | -6 | -3 | 0 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T -21, 4:1, 1.73 / 141 | 0 | 0 | 0 | 0 | -0.3 | -1.1 | -0.2 | +0.3 | +0.4 | +0.4 | +0.3 | +0.3 | +0.3 |
| T -30.2, 4:1, 1.73 / 141 | 0 | -0.4 | -1.0 | -0.2 | +0.3 | +0.4 | +0.4 | +0.3 | +0.3 | +0.3 | +0.3 | +0.3 | +0.3 |
| T -30.2, 4:1, 29.68 / 141 | 0 | -0.1 | -0.5 | +0.1 | +0.5 | +0.7 | +0.6 | +0.5 | +0.4 | +0.4 | +0.3 | +0.3 | +0.3 |
| T -30.2, 4:1, 0.01 / 993 | 0 | -0.5 | -1.3 | -0.4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Timing, as t50 / t90 in ms:

| Ed's setting | measured attack | segno attack | measured release | segno release |
|---|---|---|---|---|
| T -21, 1.73 / 141 | 3.25 / 10.75 | 2.25 / 9.75 | 53.2 / 121.2 | 98.2 / 325.8 |
| T -30.2, 29.68 / 141 | 10.75 / 42.75 | 26.25 / 97.25 | 86.2 / 174.8 | 98.2 / 325.8 |
| T -30.2, 29.68 / 993 | 12.25 / 60.25 | 29.75 / 126.25 | 546 / 1089 | 687 / over 1490 |

The hidden values in the other racks are measured above. Ed's defaults are
4:1, 1.73 ms and 141 ms, which is what segno assumes for every rack.

Make-up: segno applies the display value in dB. The Looper X applies the
table above. The gap is +1.4 dB at 1.8, +4.1 dB at 6, +1.3 dB at 15, -0.5 dB
at 18, -4.5 dB at 24 and -8.9 dB at 30.

### What segno must change (compressor)

1. **Knee.** Replace the hard knee with the quadratic soft knee of
   W = 15 dB. Hard and soft differ by up to 1.4 dB at the threshold for 4:1
   (s*W/8).
2. **Detector.** Run a branching one-pole on the linear |x| (the max of both
   channels), and feed 20 log10(env) to the gain computer. Do not smooth the
   gain reduction in dB. Take attack tau = the attack setting and release
   tau = about 0.47 x the release setting. This reproduces the step timing above. It
   reads the steady-sine bias 0.3 to 0.4 dB low (for example 0.51 dB
   against the measured 0.86 dB at the defaults).
3. **Make-up.** Map make-up through the measured table, not the display dB.
4. **Hidden settings.**
   - Dub: 6:1, not 4:1. Separately, the Dub rack's +4.31 dB ahead of the
     compressor.
   - Drum: release about 45 ms, not 141 ms.
   - Vocal: release about 55 to 65 ms, not 141 ms.
   - Vocal: attack about 1.2 ms. 4:1 is right for Drum and Vocal.
   - Studio and Vocal Tuner: 4:1 is right. Release about 55 to 65 ms, not
     141 ms; attack about 1.2 to 1.7 ms.

### Transient

segno's kernel (its own constants, run on the same stimulus):
- reaches +/-24 dB at 100 % / 0 % attack, against the measured +10 / -14.7
  dB on a 30 dB step;
- decays the onset boost with a half time of 2.2 to 2.8 ms at 50 % length,
  against 14.8 ms;
- lifts the hit tail by +10.1 dB at 100 % sustain, against +2.4 dB;
- peaks its sustain lift at 176 to 223 ms, against 286 ms, then falls back
  at once instead of over about 500 ms.

Measured targets for a rebuild:
- onset boost capped at about +10 dB, with the cut reaching about -15 dB;
- boost half-life 5.8 ms x 6.5^length;
- sustain lift peaking about 286 ms after a decay starts, back by about
  750 ms;
- sustain lift at 100 % = 0.61 x the level drop it follows (18.3 dB for a
  30 dB drop).

### HP/Gate

| property | Looper X | segno | change |
|---|---|---|---|
| high-pass corner | 0.51 x display, Q about 0.66 | display, Q 0.7071 | f0 = 0.51 x display, Q 0.66: an octave lower. At the displayed frequency the measured filter is down 0.2 to 0.6 dB and segno 3 dB; an octave below, about 4 dB against 12 dB |
| detector | peak | peak, 10 ms release | keep |
| hysteresis | 6 dB | 6 dB | keep |
| attack | < 0.25 ms | tau 0.5 ms | about the same |
| hold | about 250 ms | 20 ms | 250 ms |
| release | -2.7 dB/ms (tau about 3.2 ms on gain) | tau 50 ms on gain | tau about 3.2 ms |
| closed gain | -120 dB | 0 (below 1e-6) | equivalent |

## What segno runs (#1429)

Each control shows the value the module applies (owner decision,
2026-10-23).

- Compressor: the 15 dB quadratic soft knee on model A, with attack time
  constant = attack and release time constant = 0.47 x release. Make-up
  reads the applied gain, through the measured table. Every ladder step
  of Ed's passes lands within 0.36 dB, and the whole passes are 0.25 dB
  RMS. Step times to half the change: within 1.45x on the attacks (slow on
  the 29.68 ms one) and 1.85x on the releases (fast on the 5 ms one).
- Hidden settings, fitted with the same model:

  | rack | ratio | attack | release |
  |---|---|---|---|
  | Drum | 4 | as shown | 45 ms |
  | Vocal, Studio, Vocal Tuner | 4 | 1.5 ms | 65 ms |
  | Dub | 6 | 1 ms | 80 ms |

  The Dub Rack's +4.31 dB ahead of the compressor is not modelled.
- Transient: the "cap" near +10 dB on a 30 dB step is the 0 dBFS ceiling of
  the capture (-10 dBFS plus 10 dB); on the 60 dB step the boost reaches
  +15 dB. Gains act in the linear domain: attack 1 + a * 4.72 * ra, sustain
  1 + s * lift, each inverted for a cut, where ra and the sustain lift come
  from a peak envelope (90 ms release) and two followers (attack follower
  3.12 ms x 7.12^length; sustain follower 95 ms rise, 80 ms fall; lift up
  to 13.4 * rs, rising over 38 ms). Against the 16 passes: 0.4 dB RMS or
  better on the onsets, under 1 dB on the decays; the worst capture point
  is 1.5 dB off on an onset and 1.7 dB on a decay.
- High-pass: the high-pass output of a Chamberlin state-variable filter
  at half the display value, Q 2/3. It fits the three captured settings to
  0.02 dB RMS, the slight lift above the corner included (the 0.51 x, Q
  0.66 fit above misses that lift by up to 0.44 dB). At its lowest setting
  (shown as 1 Hz) the Looper X runs no high-pass: a 60 dB drop there
  leaves no low-frequency tail, which any filter at 0.5 Hz would. segno
  shows that setting as Off.
- Gate: the level is the instantaneous peak; hold 250 ms; open time
  constant 0.05 ms; close time constant 3.2 ms. The close curve lands
  within 0.3 dB of the captures down to -60 dB, at every threshold.
