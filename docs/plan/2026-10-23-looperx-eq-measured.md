# Looper X EQ, measured (#891 Phase 0)

Measured on the owner's emulated Looper X 1.0.2 (HG08) in the #891 rig on
2026-10-23. This file holds numbers and formulas only: no vendor code,
disassembly, QML or audio. The captures stay on the rig machine.

## Method

- Stimulus (48 kHz content): an impulse of 0.05 followed by a -30 dBFS log
  sweep from 20 Hz to 20 kHz. Each setting got one gated pass through Track 1
  PRE, with only the EQ pedal on and Master Vol at 0.0 dB.
- H(f) = FFT(output) / FFT(input), on a 1 Hz grid. The impulse and sweep
  estimates agree to within 0.01 dB from 30 Hz to 16 kHz in every pass, so
  the module is linear and time-invariant at these levels. The rack's
  all-pedals-off pass is bit-exact dry, with 2 samples of latency.
- Settings were changed by dragging the on-screen bar. The stored value v
  (0..1) was read back from the bar fill, and the readout was checked in a
  screenshot.
- Each band was fitted against the pass before it or a flat reference, so
  everything else cancels. Every band shape below fits its capture with an RMS
  error of 0.0000 to 0.02 dB over 20 Hz to 20 kHz (3000 log-spaced points).
- 130 EQ passes: Ed's 41, Drum 17, Vocal 16, Studio 7, Vocal Tuner 12
  (5 of them high-pass passes for the dynamics notes), Dub 19, Lo-Fi 9,
  Rhythmic 9.

## Filter forms (sample rate fs = 48 kHz, w0 = 2*pi*f0/fs)

### Bell: every peaking band in every rack

This is a fixed-pole (Regalia-Mitra / Zolzer) bell, not the RBJ constant-Q
bell. With k = sin(w0/2)/Q and V = 10^(|g|/20):

    boost (g >= 0):  b = [1 + V*k, -2*cos w0, 1 - V*k]
                     a = [1 + k,   -2*cos w0, 1 - k  ]
    cut   (g <  0):  the same b and a, swapped (exact inverse of the boost)

Normalise by a0. Equivalently, it is the RBJ peaking biquad with
Q_rbj = Q*cos(w0/2)/A, where A = 10^(|g|/40). The bell therefore widens as
the gain rises: at +18 dB, Q_rbj = Q/2.82, and at +9 dB, Q_rbj = Q/1.68.

Checks:
- The fitted Q stays constant across gains of +18, +9, +0.1 and -18 dB.
- It also stays constant across 20 Hz to 16 kHz. The cos(w0/2) factor was
  confirmed at 8 kHz (0.866) and 16 kHz (0.500).

### Shelves: Drum Rack only

These are RBJ low and high shelves with a fixed Q. The applied gain is 2/3 of
the displayed gain, so the -18..+18 dB control gives -12..+12 dB.

### Low cut and high cut

These are RBJ 2nd-order high-pass and low-pass filters, Q = 1/sqrt(2)
(12 dB/oct), at the displayed frequency. Neither is ever bypassed:
- at v = 0 the low cut is a 20 Hz high-pass: -3.01 dB at 20 Hz, -0.63 dB at
  31.5 Hz;
- at v = 1 the high cut is a 20 kHz low-pass: -0.20 dB at 16 kHz,
  -3.01 dB at 20 kHz.

## What each rack runs

The display taper is from looperx-derived.md. The DSP value is what was
measured. "=" means the two agree.

### Ed's Rack (EQ 4-Band)

| control | display | DSP (measured) |
|---|---|---|
| EQ Low (gain) | -18..+18 linear | = |
| EQ Low Freq | 20..1000 Hz log | = (bell, not a shelf) |
| EQ Low Q | 0.4..2 log | 0.4..10 log: Q = 0.4*25^v |
| EQ Lo Mid Freq | 100..8000 Hz log | 40..8000 Hz log: f = 40*200^v (default v .17574 = 101.5 Hz; screen says 216 Hz) |
| EQ Lo Mid Q | 0.4..10 log | = |
| EQ Hi Mid Freq | 100..8000 Hz log | 120..16000 Hz log: f = 120*(400/3)^v (default v .66061 = 3040 Hz; screen says 1808 Hz) |
| EQ Hi Mid Q | 0.4..10 log | = |
| EQ High Freq | 2000..16000 Hz log | 1200..20000 Hz log: f = 1200*(50/3)^v (default v .5278 = 5298 Hz; screen says 5994 Hz) |
| EQ High Q | 0.4..2 log | 0.4..10 log (bell, not a shelf) |
| EQ Low Cut | 20..8000 Hz log | = (HP2, default 70 Hz) |
| EQ High Cut | 120..20000 Hz log | = (LP2) |

All four bands are bells, and all gains are -18..+18 dB linear in v. Fits:

| pass (v) | f0 | Q | gain |
|---|---|---|---|
| Low Q, v 0 / .503 / 1 | 90.0 Hz | 0.400 / 2.025 / 10.000 | +18.000 |
| Low Freq, v 0 / 1 | 19.9 / 1000.0 Hz | | |
| LoMid Freq, v 0 / .176 / .503 / 1 | 40.0 / 101.5 / 576.1 / 8000 Hz | | |
| LoMid Q, v 0 / .174 / .503 / 1 | | 0.400 / 0.700 / 2.020 / 9.999 | |
| HiMid Freq, v 0 / .661 / 1 | 120.0 / 3040.4 / 16000 Hz | | |
| HiMid Q, v 0 / .155 / .5 / 1 | | 0.400 / 0.660 / 2.020 / 10.000 | |
| High Freq, v 0 / .528 / 1 | 1200 / 5298 / 20000 Hz | | |
| High Q, v 0 / .503 / 1 | | 0.400 / 2.025 / 10.000 | |
| gain v .75 (any band) | | | +9.000 |

### Drum Rack (EQ)

| band | form | f0 | Q | gain |
|---|---|---|---|---|
| EQ Low | RBJ low shelf | 200 Hz | 0.50 | 2/3 of display (+18 gives +12.0) |
| EQ Mid | bell | EQ Mid Freq, 40..8000 log (=) | 0.90 | display, -18..+18 |
| EQ High | RBJ high shelf | 4000 Hz | 0.70 | 2/3 of display |

- No cuts.
- The rack's own default is EQ High v .6 (+3.6 on screen), which applies
  +2.4 dB.

### Vocal, Studio and Vocal Tuner racks (EQ)

The three racks measured identically: four bells and no cuts.

| band | f0 | Q | gain |
|---|---|---|---|
| EQ Low | 300 Hz | 3.6 | -18..+18 |
| EQ Mid | 900 Hz | 1.2 | -18..+18 |
| EQ High | 2700 Hz | 1.2 | -18..+18 |
| EQ Air | 8100 Hz | 3.6 | -18..+18 |

- The centres are 300 Hz times 3^n.
- Air is a narrow bell, not a shelf, and it falls back to 0 dB above
  about 16 kHz.
- Air defaults to +7.2 dB (v .7) in Vocal and Studio, and to 0 dB in Vocal
  Tuner.

### Parametric EQ: Lo-Fi (Para EQ)

| control | DSP |
|---|---|
| EQ Mid Freq | bell f0 = display, 120..16000 log (=) |
| EQ Mid Q | Q = display, 0.4..10 log (=) |
| EQ Mid Gain | -18..+18 (=) |
| EQ Low Cut / High Cut | HP2 / LP2 at the display value, always on |

### Parametric EQ: Dub (Para EQ)

The Dub rack's binding is broken:
- EQ Mid Freq drives the bell's gain as -18 + 36*v; the frequency does not
  move.
- EQ Mid Gain also drives that gain; the last control touched wins.
- The centre stays at 2000 Hz, whatever EQ Mid Freq or the presets say.

Measured: Mid Freq at v 0 gives -18.0 dB, v .254 gives -8.8 dB, v 1 gives
+18.0 dB, all at 1999.96 Hz. Q and both cuts work as in Lo-Fi.

Also seen: the Dub rack with every pedal off is +4.30 dB louder than dry
(broadband). This comes from outside the EQ and the compressor.

### Rhythmic Rack (EQ)

- The bell follows Lo-Fi (f0 = display, 120..16000), with the hidden Q fixed
  at 0.998, i.e. Q = 1.
- Gains: +18 / +9 / -18 measured exactly. Cuts as in Lo-Fi.

## Against the derived tapers

Display tapers that match the DSP:
- every gain;
- every cut;
- the Drum Mid Freq;
- the Lo-Fi and Rhythmic Mid Freq;
- the Mid Q of Lo-Fi and Dub;
- Ed's Low Freq, Lo Mid Q and Hi Mid Q.

The Para EQ default Mid Q of 0.8 (v .2153) gives Q 0.800.

Five Ed's registrations do not match what the DSP does. The app shows the
wrong number for them:
- Lo Mid Freq: 100..8000 shown, 40..8000 applied;
- Hi Mid Freq: 100..8000 shown, 120..16000 applied;
- High Freq: 2000..16000 shown, 1200..20000 applied;
- Low Q: 0.4..2 shown, 0.4..10 applied;
- High Q: 0.4..2 shown, 0.4..10 applied.

The stored v is the same in both cases. Only the mapping from v differs.

## Against segno (origin/claude/segno-integration, PR #1404)

The table gives the Looper X response minus segno's, in dB at each
frequency, for the same stored values.

| case | 30 | 60 | 100 | 150 | 200 | 300 | 500 | 900 | 1.5k | 2.7k | 4k | 6k | 8.1k | 12k | 16k | 20k |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Vocal Low +18 | -17.5 | -14.2 | -6.8 | +0.9 | +6.9 | +17.6 | +6.9 | +2.2 | +0.8 | +0.3 | +0.1 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 |
| Vocal Mid +18 | +0.1 | +0.5 | +1.2 | +2.2 | +2.9 | +3.9 | +4.5 | +0.7 | +1.5 | +2.4 | +2.0 | +1.3 | +0.8 | +0.3 | +0.1 | +0.0 |
| Vocal High +18 | +0.0 | +0.1 | +0.3 | +0.6 | +0.9 | +1.9 | +4.1 | +8.1 | +12.8 | +16.0 | +9.2 | -1.1 | -7.8 | -13.6 | -16.2 | -17.6 |
| Vocal Air +18 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.1 | +0.3 | +0.8 | +2.3 | +4.7 | +9.8 | +15.2 | -1.4 | -12.5 | -17.2 |
| Vocal Air default (+7.2) | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.1 | +0.2 | +0.5 | +2.1 | +6.4 | -2.4 | -6.2 | -7.1 |
| Drum Low +18 | -6.0 | -4.0 | +0.5 | +3.6 | +4.3 | +3.4 | +1.7 | +0.6 | +0.2 | +0.1 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 |
| Drum High +18 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.1 | +0.3 | +0.1 | -1.8 | -4.0 | -5.7 | -6.0 | -6.0 |
| Drum Mid +18 @565.7 | +0.7 | +2.0 | +3.6 | +4.7 | +5.2 | +4.9 | +0.7 | +4.1 | +5.2 | +4.1 | +2.8 | +1.6 | +0.9 | +0.3 | +0.1 | +0.0 |
| Drum Mid +9 @565.7 | +0.0 | +0.2 | +0.4 | +0.7 | +1.0 | +1.1 | +0.1 | +0.9 | +1.0 | +0.5 | +0.3 | +0.1 | +0.1 | +0.0 | +0.0 | +0.0 |
| Ed's Low +18 (default v, Q v 0) | -0.0 | +6.2 | +9.6 | +11.2 | +11.7 | +11.4 | +9.6 | +6.3 | +3.6 | +1.5 | +0.7 | +0.3 | +0.2 | +0.1 | +0.0 | +0.0 |
| Ed's Low +18 (Q v 1) | -19.9 | -18.2 | +5.1 | +6.8 | +5.1 | +2.1 | +0.7 | +0.2 | +0.1 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 | +0.0 |
| Ed's LoMid +18 (defaults) | +9.6 | +12.2 | +10.2 | +3.7 | -2.7 | -1.9 | +0.8 | +1.1 | +0.7 | +0.3 | +0.1 | +0.1 | +0.0 | +0.0 | +0.0 | +0.0 |
| Ed's HiMid +18 (defaults) | +0.0 | +0.2 | +0.4 | +0.8 | +1.2 | +2.0 | +2.8 | +2.2 | -1.3 | +5.1 | +9.6 | +10.7 | +9.9 | +7.4 | +4.4 | +1.5 |
| Ed's High +18 (defaults) | +0.1 | +0.2 | +0.6 | +1.2 | +1.9 | +3.5 | +6.2 | +9.7 | +11.9 | +12.4 | +11.3 | +8.9 | +6.4 | +1.6 | -3.8 | -10.6 |
| Ed's Low Cut v 0 | -0.8 | -0.1 | -0.0 | ... | | | | | | | | | | | | (-3.0 at 20 Hz) |
| Ed's High Cut v 1 | | | | | | | | | | | | | | | -0.2 | -3.0 |
| Para +18 @1386 Q .8 | +0.2 | +0.6 | +1.5 | +2.7 | +3.8 | +5.4 | +6.7 | +5.0 | +0.4 | +6.4 | +6.6 | +5.5 | +4.1 | +2.2 | +0.9 | +0.2 |
| Para +9 @1386 Q .8 | +0.0 | +0.1 | +0.2 | +0.3 | +0.6 | +1.1 | +1.9 | +1.6 | +0.1 | +2.1 | +1.8 | +1.1 | +0.6 | +0.2 | +0.1 | +0.0 |
| Para -9 @1386 Q .8 | -0.0 | -0.1 | -0.2 | -0.3 | -0.6 | -1.1 | -1.9 | -1.6 | -0.1 | -2.1 | -1.8 | -1.1 | -0.6 | -0.2 | -0.1 | -0.0 |
| Rhythmic +18 @1386 | +0.1 | +0.4 | +0.9 | +1.8 | +2.6 | +3.8 | +5.0 | +4.0 | +0.4 | +4.9 | +4.9 | +3.9 | +2.8 | +1.4 | +0.5 | +0.1 |
| Dub +18 (Mid Freq at default) | +0.1 | +0.3 | +0.7 | +1.3 | +2.0 | +3.0 | +3.8 | +2.1 | -0.3 | +9.1 | +9.7 | +8.4 | +6.7 | +3.9 | +1.8 | +0.5 |

## What segno must change to match

1. **Bell design.** Replace the RBJ constant-Q peaking design with the
   fixed-pole bell above (k = sin(w0/2)/Q; boost scales the numerator by V;
   cut is the inverse). This alone accounts for the Para and Rhythmic rows
   and part of every other bell row: up to +6.7 dB at +18 dB, +2 dB at
   +/-9 dB.
2. **Ed's variant.**
   - Low and High are bells, not shelves.
   - Ranges by v:
     - Low: 20..1000 Hz, Q 0.4..10;
     - Lo Mid: 40..8000 Hz;
     - Hi Mid: 120..16000 Hz;
     - High: 1200..20000 Hz, Q 0.4..10.
   - In segno terms:
     - the scales for parameters 5 and 8 become log(40, 8000) and
       log(120, 16000);
     - high_freq becomes 1200..20000;
     - low_q and high_q become 0.4..10.
   - The default band centres are then 90, 101.5, 3040 and 5298 Hz.
3. **Vocal, Studio and Vocal Tuner variant.**
   - Four bells: 300 Hz Q 3.6, 900 Hz Q 1.2, 2700 Hz Q 1.2, 8100 Hz Q 3.6.
   - No shelves, no 12 kHz air shelf, no cuts.
4. **Drum variant.**
   - Low: RBJ low shelf at 200 Hz, Q 0.5, gain x 2/3.
   - High: RBJ high shelf at 4000 Hz, Q 0.7, gain x 2/3.
   - Mid: bell Q 0.9 (40..8000 is already right).
5. **Rhythmic.** Hidden Q 1.0, not 0.7616.
6. **Cuts.** Keep the low cut and the high cut running at the ends of their
   ranges: a 20 Hz high-pass at v 0, a 20 kHz low-pass at v 1. Both are RBJ,
   Q 0.7071, which matches segno's design.
7. **Dub.** The Looper X ignores EQ Mid Freq as a frequency: the bell sits at
   2000 Hz and the Mid Freq control sets the gain. Matching this means
   copying a defect, so it is an owner call. Lo-Fi's identical-looking Para
   EQ works properly.

## What segno runs (#1429)

- Every bell is the fixed-pole bell above, and each control shows the value
  the EQ applies (owner decision, 2026-10-23): Ed's Lo Mid reads
  40..8000 Hz, Hi Mid 120..16000 Hz, High 1200..20000 Hz, Low and High Q
  0.4..10; the Drum shelves read -12..+12 dB.
- The layout setting picks four bells and both cuts (Ed's, Dub, Lo-Fi,
  Rhythmic), low and high shelves and no cuts (Drum), or four bells and no
  cuts (Vocal, Studio, Vocal Tuner). The cuts never switch off.
- Dub's Para EQ works as labelled: Mid Freq moves the frequency (owner
  decision), as in Lo-Fi.
- The bands run in double precision: in float, the rounding of the 20 Hz
  cut's coefficients alone moved its response by 0.1 dB.
- Against the captures, the native tests' probes land within 0.05 dB for
  Ed's, the Drum Rack and the Vocal Low band, and within 0.11 dB for the
  nominal Vocal Mid, High and Air centres and the Lo-Fi and Rhythmic fits.
