# The Dual Octaver's down voices on bass (#891, #1467)

Measured on the owner's emulated Looper X 1.0.2 in the #891 rig on
2026-10-26 (session s15bass, stimulus `bassstim`), with the s7oct pass of
2026-10-25 for 110 Hz to 4 kHz. Numbers and formulas only: no vendor code,
disassembly or audio. Captures stay on the rig machine.

The capture's engine runs at 48 kHz behind a 2x converter (the rig's
output is 96 kHz), so these are the Looper X's 48 kHz figures. Levels are
read with a Hann window over the steady part of each tone, at the voice's
own frequency, in dB against the input's fundamental.

## The Looper X

Ed's Rack, Dual Octaver, High Mode off, Mix 100 %, each voice alone at
100 %. Tones at -12 dBFS peak: a sine, and a harmonic bass (harmonics 1 to
10 at 1/k).

| input | Octave 1 (f0/2): sine | bass | Octave 2 (f0/4): sine | bass |
|---|---|---|---|---|
| 41 Hz | none (-99.5) | none (-107.3) | none (-125.4) | -23.6 |
| 55 Hz | none (-105.1) | -30.3 | none (-117.4) | -46.7 |
| 82 Hz | -1.3 | -1.3 | -3.0 | -3.0 |
| 110 Hz | 0.0 | 0.0 | 0.0 | 0.0 |
| 220 Hz to 4 kHz (sine, s7oct) | 0.0 | | 0.0 to -0.1 | |

- At 41 and 55 Hz it shifts nothing: it plays the input as it is (0.2 to
  0.3 dB down at f0). On the 41 Hz bass the 23.6 dB line at f0/4 sits among
  others at 3f0/4 and 5f0/4 of the same size; on the 55 Hz bass the output
  is a mix of lines with no steady pitch.
- On a sine its down voice is a clean sine: 110 Hz down an octave puts 55
  Hz at 0.0 dB and 110 Hz at -72 dB.
- On the bass its down voice carries the whole harmonic series down: at
  110 Hz the voice's harmonics 1 to 8 sit at 0.0, -6.0, -9.6, -12.1,
  -14.1, -15.7, -17.1 and -18.3 dB (1/k is 0, -6.0, -9.5, -12.0, ...). At
  82 Hz they fall faster: -1.3, -11.3, -22.9, -45.0.

## The kernel before (#1467)

The vocoder alone, the same tones, Octave 1 (Octave 2):

| input | 48 kHz sine | 48 kHz bass | 96 kHz sine | 96 kHz bass |
|---|---|---|---|---|
| 82 Hz | -0.1 (-2.6) | +0.3 (-2.3) | -45.4 (none) | -31.7 (-74.9) |
| 110 Hz | +0.9 (-2.9) | +2.1 (-1.6) | -0.9 (none) | -32.6 (-59.2) |

## The kernel now

The low band (engine_fx.h, "The Dual Octaver's low band"): below a 250 Hz
Linkwitz-Riley crossover the down voices come from the time domain, a tap
read at the voice's ratio that jumps one detected period at a time. It
starts at 60 Hz and comes in over a smoothstep to 89 Hz, which puts
Octave 1 at the capture's -1.3 dB at 82 Hz; below 60 Hz the vocoder plays
as before, since the Looper X shifts nothing there.

| input | 48 kHz sine | 48 kHz bass | 96 kHz sine | 96 kHz bass |
|---|---|---|---|---|
| 82 Hz | -1.4 (-1.4) | -1.4 (-1.4) | -1.4 (-1.4) | -1.3 (-1.4) |
| 110 Hz | 0.0 (0.0) | -0.4 (0.0) | 0.0 (0.0) | 0.0 (0.0) |

- Octave 2 at 82 Hz sits 1.6 dB above the capture: the floor's ramp is fit
  to Octave 1's point and is shared by both voices.
- The crossover: the voice's second harmonic on the bass, against the
  capture's -11.3 dB (82 Hz) and -6.0 dB (110 Hz), was -9.0 and -13.2 at
  200 Hz, -7.4 and -9.9 at 250 Hz, and -6.7 and -8.1 at 300 Hz (96 kHz).
  250 Hz splits the error evenly.
- On a sine the voice is clean, as the Looper X's: 110 Hz puts 55 Hz at
  0.0 dB and 110 Hz at -66 dB.
- Below 60 Hz and above 1.15 x the crossover, and on anything the band
  hears no pitch in, the Dual Octaver is the vocoder alone, sample for
  sample.
- The latency stays 1216 frames: the band's taps centre on it less the
  crossover's group delay (173 samples at 96 kHz), and a tone's swell comes
  out of the band within a millisecond of where the vocoder alone puts it,
  at 48 and 96 kHz. The band's weight is applied as late as the vocoder's
  frames apply theirs (704 samples after the analysis), so the two still
  sum to one voice while a note starts or stops.
- A new note takes one detection to settle: the period is read over the
  newest 43 ms of the band, which at 96 kHz is centred about 8 ms before
  the audio the taps play, so the first few jumps of a new note can land
  off its period, each covered by its fade.

## Passes

| session | pass | setting |
|---|---|---|
| s15bass | 0 | High Mode off, Octave 1 100 %, Octave 2 0 %, Mix 100 % |
| s15bass | 1 | High Mode off, Octave 1 0 %, Octave 2 100 %, Mix 100 % |
| s7oct | 0 to 2 | the same two, then High Mode on, on tones from 110 Hz to 4 kHz |
