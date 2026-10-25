# The Looper X's Mod pedal, measured (#891 sessions s6trem and s6mod)

Measured on the owner's emulated Looper X 1.0.2 in the rebuilt #891 rig on
2026-10-24 and 2026-10-25. Numbers and formulas only: no vendor code,
disassembly or audio. Captures stay on the rig machine. The kind built from
these is `LE_FX_MOD` (#1470).

## Method

Gated passes through Track 1 PRE, one pedal on, Master Vol 0.0 dB, the
Guitar Rack (CHORUS, PHASER, FLANGER) or the Studio Rack (Chorus,
Tremolo) with no preset loaded. Stimulus `tremstim` (48 kHz): an impulse,
12 s of a steady 1 kHz sine at -12 dBFS, then 6 s of white noise. The
Looper X's output reaches the capture 2 samples after its input; every
delay below has that removed. Both outputs are identical for the mono
input in every Guitar pass.

- Delays: a short-window impulse response over the noise (21 or 11 ms
  windows, 1 ms hop), its strongest tap tracked and fitted with a
  triangle.
- Gains: the impulse, against the capture chain's own impulse at Mix 0 %
  (unity).
- The phaser's corners: per window, four allpass stages fitted to the
  noise's response; the sweep then fitted over time.
- Rates: the tracks above, or the Doppler sidebands of the 1 kHz sine.
- The tremolo: the 1 kHz sine's gain at 1 ms resolution, fitted with a
  square wave through a rise and a fall time constant.

## Passes

s6trem: 0-7 CHORUS, 8-15 PHASER, 16-23 FLANGER (each at Rate, Depth, Mix
50 %, then Rate 0, 100, 25 %, Depth 0, 100 %, Mix 0, 100 %); 24-29 Studio
chorus (24-27 with Doubler Mix 100 %, 28-29 at 0 %); 30-40 Studio tremolo
(30-34 Rate 25 % at Depth 0, 25, 50, 75, 100 %; 35-38 Depth 100 % at Rate
0, 50, 75, 100 %; 39-40 with Doubler Mix 100 %).

s6mod (the settings s6trem left between): 0-3 CHORUS (50 % again, Depth
25, 75 %, Rate 75 %); 4-9 PHASER (50 % again, Depth 25, 75 %, Rate 75 %,
Mix 25, 75 %); 10-17 FLANGER (50 % again, Depth 25, 75, 10, 90 %, Rate
75 %, Mix 25, 75 %). The repeated 50 % passes match the first ones.

## CHORUS (the Guitar Rack's; the Studio Rack's is the same voice)

| | 0 % | 25 % | 50 % | 75 % | 100 % |
|---|---|---|---|---|---|
| Rate, Hz | 0.4005 | 1.1107 | 1.7998 | 2.50 | 3.1994 |
| Depth: the delay's swing, ms | 0 | 0.638 | 2.444 | 5.361 | 9.72 |
| Mix: dry, voice | 1.000, 0 | | 0.855, 0.431 | | 0.710, 0.821 |

- One voice, its delay a triangle from 1.767 ms (Depth 0 %) up; the swing
  is 9.78 ms times Depth squared (the s3 capture's 0.141 ms at 12 % fits
  too). The kernel holds the base at 85 samples at 48 kHz (1.771 ms).
- The rate is a line, 0.4005 + 2.799 x Rate Hz, within 1 % of every pass
  and of s3's 1.313 Hz at 32.6 % and 2.638 Hz at 79.7 %.
- The voice is low-passed: -1.8 dB at 4 kHz, -10.5 dB at 8 kHz, -21 dB at
  12 kHz (the earlier two 2nd-order sections at 6.7 kHz, Q 0.65, at the
  Looper X's 96 kHz).
- Dry 1 - 0.29 x Mix, voice 0.83 x Mix (as s3 found).
- Studio: at Doubler Mix 0 % the voice is 0.51 of the dry, the Guitar
  Rack's ratio at Mix 50 % (0.49); its Rate 0, 50 and 100 % and Depth
  100 % give the Guitar Rack's Doppler sidebands. Its overall level moves
  with the Doubler, which is that module's own.

## PHASER

| | 0 % | 25 % | 50 % | 75 % | 100 % |
|---|---|---|---|---|---|
| Rate, Hz | 0.0997 | 0.3222 | 1.0092 | 3.1623 | 10.000 |
| Depth: the sweep, octaves | 0 | 1.483 | 2.930 | 4.389 | 5.882 |
| Mix: dry, wet | 1.000, 0 | 0.963, 0.470 | 0.789, 0.798 | 0.481, 0.993 | 0.043, 1.048 |

- Four first-order allpass stages, their corners 1.426 apart (the outer
  two 1.426^3 apart), the geometric centre at 654 Hz when still: notches
  at 258 and 1652 Hz at Depth 0 %, below -40 dB at Mix 50 %.
- The rate is 0.1 x 100^Rate Hz, within 2 % (exact at 75 and 100 %).
- The sweep is 5.87 x Depth octaves. The corners move along
  u^0.87, u = (1 + sin) / 2, centred so the shaped sine's mean (0.467)
  sits at 654 Hz: within 0.02 octave of every tracked window (a plain sine
  in octaves misses by 0.05-0.08).
- Mix: dry and wet fitted to the 1 kHz tone over whole sweeps (the table
  above). The 1 kHz gain peaks at +3.99 dB at Mix 50 % and is notched
  below -35 dB.
- Not modelled: the wet signal is not quite an allpass. Between the
  notches it is up to 1.2 dB louder, at them 0.5 dB quieter. No feedback
  topology tried (around one, two, three or all four stages) fits both the
  still and the swept passes, so the kernel stays an allpass.

## FLANGER

| Depth | 0 % | 10 % | 25 % | 50 % | 75 % | 90 % | 100 % |
|---|---|---|---|---|---|---|---|
| shortest delay, ms | 0.805 | 0.662 | 0.494 | 0.279 | 0.151 | 0.116 | 0.109 |
| longest delay, ms | 0.805 | 2.062 | 3.515 | 5.361 | 6.467 | 6.775 | 6.836 |

- One voice on a triangle delay, straight in milliseconds (0.005 ms rms;
  a triangle in log delay or in frequency misses by 0.018 ms). Both ends
  follow 1 - (1 - Depth)^2 within 0.1 ms; the kernel interpolates the
  table.
- Rate, Hz: 0.0172, 0.0822, 0.4056, 2.0 and 10.0 at 0, 25, 50, 75 and
  100 %: 0.0166 x 604^Rate within 4 %.
- Mix: dry 1 - Mix (0.749, 0.500, 0.251, 0 at 25-100 %), the first copy
  0.88 x Mix (0.223, 0.442, 0.656, 0.87).
- The repeats: each is the last one through a first-order high-pass near
  1.5 kHz and a first-order low-pass near 6-8 kHz, at a passband gain of
  1.03-1.09: from one repeat to the next, -23 dB at 100 Hz, -9.7 dB at
  500 Hz, -4.8 dB at 1 kHz, -1.3 dB at 4 kHz, -7 dB at 12 kHz. The first
  copy is not filtered (-1.0 dB flat against the dry to 4 kHz). Fits over
  pairs of repeats split between 1.09 / 1.56 kHz / 6.15 kHz and 1.035 /
  1.41 kHz / 7.9 kHz; the 1 kHz tone at Mix 100 % (-5.07 to +5.38 dB)
  wants a loop gain there of 0.52-0.54, so the kernel uses 1.03 with
  1.56 kHz and 6.15 kHz (0.55 at 1 kHz: the tone at -4.9 to +5.8 dB).

## Tremolo (the Studio Rack's)

| | 0 % | 25 % | 50 % | 75 % | 100 % |
|---|---|---|---|---|---|
| Rate, Hz | about 0.25 | 0.6816 | 1.8169 | 4.8413 | 13.0005 |
| Depth: the gain of the off part | 1 | 0.880 | 0.564 | 0.194 | 0 |

- A square wave, on for 0.58 of each cycle (0.565-0.589 over every pass),
  through a gain that rises with a 13 ms time constant (11.4-14.5 ms) and
  falls with 30.5 ms (30.2-32.6 ms; 270-290 dB a second at Depth 100 %).
- The rate is 0.2551 x 50.97^Rate Hz (each 25 % step x 2.66-2.69).
- The passes ran with Doubler Mix 0 %, whose copy still moves the level
  by +2 to +4.4 dB (the Doubler's own Mix-0 behaviour); the gains above
  are the steps at the tremolo's edges, which that drift does not reach.

## Not measured

- The Studio Rack's tremolo with Mix: its panel has no Mix.
- The PHASER's and FLANGER's response to a Mode change mid-note: the kernel
  crossfades over 1024 frames.
