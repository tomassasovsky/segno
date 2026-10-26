# The Drum and Dub racks' delays, and the s7 passes (#891, #1473, #1472)

Measured on the owner's emulated Looper X 1.0.2 in the #891 rig (sessions
s6 and s7, 2026-10-24 and 2026-10-25). Numbers and formulas only: no
vendor code, disassembly or audio. Captures stay on the rig machine.
Levels are read from the impulse response's echoes (200 frames before to
4000 after, a 10 % Tukey window), or from the 1 kHz ladder with a Hann
window at the tone's own frequency, the same way on the capture and on the
kernel.

## Drum Rack delay (s6rev 22-27; 1/8 at 120 BPM, Mix 100 %)

First echo against the impulse, dB:

| Del Freq | 50 Hz | 100 Hz | 316 Hz | 1 kHz | 2 kHz | 3.16 kHz | 5 kHz | 8 kHz |
|---|---|---|---|---|---|---|---|---|
| 0 % | -1.7 | +1.3 | +0.1 | -0.7 | -2.2 | -4.3 | -7.2 | |
| 25 % | -2.4 | -0.5 | +1.9 | -0.4 | -2.2 | -4.2 | -7.2 | |
| 50 % | -2.5 | -0.8 | +0.1 | +1.4 | -1.4 | -3.9 | -7.1 | |
| 100 % | -2.5 | -0.8 | -0.2 | -0.7 | -2.1 | -4.0 | -6.5 | -9.1 |

- A bell of +2.25 dB, Q 1.0, at Del Freq (fitted centre 98 Hz to 10.6 kHz;
  the control's 100 Hz to 10 kHz, within 6 %, is what the kernel uses),
  a one-pole low-pass at 3.3 kHz, and on the echoes only a one-pole
  high-pass at 19 Hz, at 0.964. Fit within 0.6 dB rms, 40 Hz to 12 kHz.
- At Feedback 50 % each repeat passes the low-pass and bell again and
  loses 1.83 dB more than Feedback's (-6.3, -5.6, -7.9 and -11.7 dB at
  200 Hz, 316 Hz, 1 kHz and 3.16 kHz). The high-pass is not in the loop.

## Dub Rack delay (s6rev 28-37; 1/8D, Feedback 50 %, Amb-Dub Mix 100 %)

- **Damp** sets a low-pass, a table (corner and Q) at 0, 35 % (the
  default) and 100 %: 11.9 kHz Q 1.0, 21.6 kHz Q 0.14, 10.8 kHz Q 0.10. At
  Reso 80 % the first echo is -3.2, -6.1 and -21.2 dB at 10 kHz for
  Damp 0, 35 and 100 %.
- **Reso / Res-Freq**: a peak at Res-Freq (100 Hz to 10 kHz, logarithmic),
  Q 0.69 + 0.05 Reso, of 6.0 dB at Reso 80 % and 11.0 dB at 100 % (none at
  0 %): 11.0 x Reso^2.72.
- On the echoes only, a 14 Hz high-pass (Q 0.2). Fit within 0.6 dB rms
  (0.9 dB at Damp 100 %), 40 Hz to 12 kHz.
- The loop repeats the low-pass and the peak and loses 4.45 dB more than
  Feedback's (-6.6, -4.8 and -9.5 dB at 316 Hz, 500 Hz and 2 kHz).
- **L/R Ratio** puts the right echo at 1 - Ratio / 2 of the time (281 ms at
  50 %, 188 ms at 100 %, of 375 ms), each side carrying -16.9 dB (0.143)
  of the other. Side gains, against the voicing:

  | Ratio | left (on time) | right (early) |
  |---|---|---|
  | 0 % | 0.751 | 0.750 |
  | 50 % | 0.659 | 0.754 |
  | 100 % | 0.533 | 0.852 |

  Captured at Feedback 50 % only. The Mode delay's L/R left gain moves
  with Feedback (0.219 + 0.666 x Feedback); whether the Dub's does is not
  measured.

## Where the Mode delay's echo limit sits (s7dly)

The 1 kHz ladder's echo at Feedback 0 %, Mix 30 %, against the tone, dB
(the steps at -48 to -12 dBFS read the same as -12):

| mode, side | -12 | -6 | -3 | 0 dBFS |
|---|---|---|---|---|
| RESO LO (capture / kernel) | -2.6 / -2.8 | -6.0 / -5.8 | -8.9 / -8.5 | -11.9 / -11.4 |
| DIGI L/R left, on time | -23.3 / -23.3 | -23.3 / -23.3 | -23.5 / -23.9 | -26.3 / -26.2 |
| DIGI L/R right, early | -4.2 / -4.2 | -4.2 / -4.2 | -4.1 / -4.0 | -3.2 / -3.2 |
| RESO HI | -7.3 / -7.3 | -7.3 / -7.4 | -9.0 / -9.1 | -11.9 / -11.6 |
| DIGI GRV left | -11.4 / -11.0 | -11.4 / -11.0 | -11.5 / -11.6 | -14.4 / -13.9 |
| DIGI GRV right | -9.6 / -8.9 | -9.6 / -8.9 | -9.8 / -9.4 | -12.4 / -11.4 |

- RESO LO's voiced echo saturates from -6 dBFS in, 3 dB earlier than
  DIGI's: the limit is after the voicing.
- DIGI L/R's left echo, carried at 0.219, still saturates at 0 dBFS: the
  limit is before the side gains. Both as the kernel has them.
- GRV's absolute levels are 0.4-1.0 dB off in the kernel at every step;
  that is its side gains, not the limit.
- RESO LO at Feedback 100 % under the sweep: the kernel matches second by
  second to 4 s, then runs 0.6 to 2.1 dB louder (5-9 s).

## The Dual Octaver's pitch (s7oct, steady tones at -12 dBFS)

| input | 110 Hz | 220 Hz | 440 Hz | 1 kHz | 2 kHz | 4 kHz |
|---|---|---|---|---|---|---|
| Octave 1 down, cents off | 0 | 0 | 0 | +35 | +8 | +76 |
| Octave 2 down, cents off | +2 | +2 | +2 | (-41 dB) | -23 | +66 |
| Octave 1 up, cents off | +9 | +9 | +9 | 0 | 0 | 0 |

The down octaves are exact below 500 Hz and scattered above 1 kHz (the
1 kHz point read +17 cents in s5 and s6v and +35 here), and Octave 2 down
drops out entirely on a 1 kHz tone. That reads as the Looper X's
analysis grid, not a constant offset. The kernel keeps exact octaves.
