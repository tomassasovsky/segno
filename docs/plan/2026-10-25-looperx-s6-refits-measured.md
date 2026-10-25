# Looper X values the s6 captures settled (#891, #1472)

Measured on the owner's emulated Looper X 1.0.2 in the rebuilt #891 rig on
2026-10-24 and 2026-10-25 (session s6: the passes are indexed at the end).
Numbers and formulas only: no vendor code, disassembly or audio. Captures
stay on the rig machine. Each item replaces a value an earlier part
inferred or read with a biased estimator; levels are read with a Hann
window at the tone's own frequency (its peak, found to 0.25 Hz), the same
way on the capture and on the kernel.

## Dual Octaver (Ed's Rack, #1464)

1 kHz at -12 dBFS, Mix 100 %, against the dry:

| setting | capture | kernel before | kernel now |
|---|---|---|---|
| High off, Octave 1 (505 Hz) | -0.26 dB | -1.54 | -0.26 |
| High off, Octave 2 alone (256 Hz) | -0.16 dB | -1.50 | -0.16 |
| High off, Octave 2 at 50 % | -6.18 dB | -7.52 | -6.18 |
| High on, Octave 1 (2 kHz) | -0.04 dB | -0.60 | -0.04 |
| High on, both: 2 kHz, 4 kHz | -0.04, -0.15 dB | -0.60, -0.69 | -0.04, -0.15 |
| High on, both, Mix 50 %: 1, 2, 4 kHz | -3.02, -3.05, -3.16 dB | -3.0, -3.6, -3.7 | -3.01, -3.05, -3.16 |

- Octave 2 down is two octaves down, as inferred, and its control is
  linear (-6.2 dB at 50 %).
- The trims become 1.159 (Octave 1 down), 1.042 (up), 0.982 (Octave 2
  down) and 1.485 (Octave 2 up).
- The Looper X's down voices sit sharp: 505 Hz and 255.75 Hz for 1 kHz
  (+17 and +39 cents), where the up voices are exact. The kernel keeps
  exact octaves, as the Pitch Shift keeps the display's ratio.

## Mode delay (#1459)

- **The composed modes.** DAMPED L/R, DAMPED GRV, RES LO L/R and RES LO GRV
  (s6v 9-16, Feedback 50 and 0 %, Mix 30 %) were composed from the DIGI and
  RES HI timings and the DAMPED and RESO LO voicings. Every echo through
  the fourth repeat, both sides, at 150-400 Hz, 1 kHz and 3 kHz, matches the
  kernel within 0.3 dB. Nothing changes.
- **DIGI at 100 % Feedback** (s6v 18). From the impulse, the second echo is
  0.996 of the first: the loop loses nothing per repeat, as the kernel has
  it. Under the sweep, though, the Looper X settles 7 to 9 dB lower than
  the kernel did, and at Feedback 0 % a hot echo saturates (s6v 17):

  | tone (1 kHz) | -6 dBFS | -3 dBFS | 0 dBFS |
  |---|---|---|---|
  | its echo, against its own level | 0.0 dB | -0.2 dB | -3.1 dB |

  Two limits fit all three passes (with s4/4, DIGI at 50 %):
  - the voiced echo, from 0.55 toward a ceiling of 0.60 (tanh);
  - what feeds back, from 0.20 toward 0.40.

  With them the kernel reads 0.0, -0.7 and -2.95 dB above, tracks the 100 %
  pass's level within 0.6 dB over 9 s (the old knee at 0.8, ceiling 1, was
  off by 5 dB rms), and the 50 % ladder within 0.3 dB.

## Slicer (#1461)

AB__dd and AA__dd at 1/16 and 1/8 (s6v 21-24) rest one step, not two: the
cycle is four steps (A, B or A again, a step of rest, then d live and d
replayed half a step later). In these patterns each _ is half a step,
the length of the lower-case d beside it; in A_C_ (s4/23) a lone _ rests a
full step. The kernel now takes _ as half a step in any pattern that holds
a lower-case letter. The other patterns with _ have none.

## Amp+Cab: the second-harmonic gap (#1468)

At drive 100 % and 0 dBFS the kernel's second harmonic is -6 dBc against
the capture's -26. Two trials, scored against s6amp 0, 3 and 4 (drive 50,
75 and 100 %):

- Moving the clipper's two limits toward their geometric mean as drive
  rises (up to fully symmetric at 100 %) leaves the second harmonic where
  it was: 13.2 to 13.4 dB rms off over the top four ladder steps.
- Fading the square-law stage at heavy drive (to 0.4 of it at 75 and
  100 %) brings the third harmonic at 100 % from 15.6 to 2.2 dB rms off
  and the fundamental from 0.5 to 0.2 dB, but the second harmonic at
  0 dBFS stays 14 dB high, and at 75 % the quiet steps' second harmonic
  moves further off.

Neither closes the gap, so the kernel is unchanged and the gap stays
documented here.

## Not in this part

- The Drum Rack delay's Freq and the Dub Rack delay's Damp, L/R Ratio,
  Reso and Res-Freq (s6rev 22-37) need their own voicings in the Mode
  delay: a separate part.
- The Drum Reverb rooms and Ed's and Studio's mode reverbs (s6rev 0-21,
  38-53): a separate part.

## The s6 passes

### `s6v`: Guitar rack (amp, cabinets, Mode delay), Rhythmic (Slicer), Ed's (Dual Octaver) (stimulus `stim_full`)

| seg | setting |
|---|---|
| 0 | verify 4x12 amp all 50 (= s4/16) |
| 1 | verify D.I. amp all 50 (= s4/17) |
| 2 | cab index 2 (amp all 50) |
| 3 | cab index 4 (amp all 50) |
| 4 | cab index 5 (amp all 50) |
| 5 | cab index 6 (amp all 50) |
| 6 | cab index 8 (amp all 50) |
| 7 | cab index 10 (amp all 50) |
| 8 | cab index 0 D.I. again |
| 9 | delay mode 7 fb 50 mix 30 |
| 10 | delay mode 4 fb 50 mix 30 |
| 11 | delay mode 5 fb 50 mix 30 |
| 12 | delay mode 8 fb 50 mix 30 |
| 13 | delay mode 7 fb 0 mix 30 |
| 14 | delay mode 4 fb 0 mix 30 |
| 15 | delay mode 5 fb 0 mix 30 |
| 16 | delay mode 8 fb 0 mix 30 |
| 17 | delay mode 0 fb 0 mix 30 |
| 18 | delay mode 0 fb 100 mix 30 |
| 19 | cab index 11 RADIO (amp all 50) |
| 20 | cab index 6 4x10 again, longer settle |
| 21 | slicer AB__dd step 1/16 mix 100 |
| 22 | slicer AA__dd step 1/16 mix 100 |
| 23 | slicer AA__dd step 1/8 mix 100 |
| 24 | slicer AB__dd step 1/8 mix 100 |
| 25 | oct high off, oct1 100, oct2 100, mix 100 |
| 26 | oct high off, oct1 0, oct2 100, mix 100 |
| 27 | oct high off, oct1 0, oct2 50, mix 100 |
| 28 | oct high on, oct1 0, oct2 100, mix 100 |

### `s6amp`: Guitar rack Amp, D.I.: drive and tone (stimulus `ampstim`)

| seg | setting |
|---|---|
| 0 | drive 50 tone 50 DI |
| 1 | drive 0 tone 50 DI |
| 2 | drive 0.25 tone 50 DI |
| 3 | drive 0.75 tone 50 DI |
| 4 | drive 1 tone 50 DI |
| 5 | drive 0 bass 0 |
| 6 | drive 0 bass 0.25 |
| 7 | drive 0 bass 0.75 |
| 8 | drive 0 bass 1 |
| 9 | drive 0 treble 0 |
| 10 | drive 0 treble 0.25 |
| 11 | drive 0 treble 0.75 |
| 12 | drive 0 treble 1 |
| 13 | drive 0 modern 0 |
| 14 | drive 0 modern 0.25 |
| 15 | drive 0 modern 0.75 |
| 16 | drive 0 modern 1 |
| 17 | drive 0 bass 1 treble 1 |
| 18 | drive 0 bass 0 treble 0 |
| 19 | drive 0 bass 1 modern 1 |
| 20 | drive 0 treble 1 modern 0 |
| 21 | drive 0.5 bass 0 |
| 22 | drive 0.5 bass 1 |
| 23 | drive 0.5 treble 0 |
| 24 | drive 0.5 treble 1 |
| 25 | drive 0.5 modern 0 |
| 26 | drive 0.5 modern 1 |

### `s6rev`: Drum Reverb, Drum delay, Dub Delay, Ed's and Studio reverbs (stimulus `revstim`)

| seg | setting |
|---|---|
| 0 | drum reverb defaults, LARGE STUDIO (7) |
| 1 | drum reverb ER 0 |
| 2 | drum reverb ER 1 |
| 3 | drum reverb ER 2 |
| 4 | drum reverb ER 3 |
| 5 | drum reverb ER 4 |
| 6 | drum reverb ER 5 |
| 7 | drum reverb ER 6 |
| 8 | drum reverb ER 8 |
| 9 | drum reverb ER 9 |
| 10 | drum reverb ER 10 |
| 11 | drum reverb mix 100 |
| 12 | mix 100 lo/hi 0 |
| 13 | mix 100 lo/hi 100 |
| 14 | mix 100 tail/er 0 |
| 15 | mix 100 tail/er 100 |
| 16 | mix 100 density 0 |
| 17 | mix 100 density 50 |
| 18 | mix 100 length 0 |
| 19 | mix 100 length 0.5 |
| 20 | mix 100 length 1 |
| 21 | drum reverb ER 11 (CHURCH); Length 0.74 s, Lo/Hi 50.2, Tail/ER 30.3, Mix 30.3 after the restores |
| 22 | drum delay fb 0 mix 100 freq 0 |
| 23 | drum delay fb 0 mix 100 freq 0.25 |
| 24 | drum delay fb 0 mix 100 freq 0.5 |
| 25 | drum delay fb 0 mix 100 freq 0.75 |
| 26 | drum delay fb 0 mix 100 freq 1 |
| 27 | drum delay fb 50 mix 100 freq 0.25 |
| 28 | dub delay defaults, amb-dub 100, fb 50 |
| 29 | dub delay damp 0 |
| 30 | dub delay damp 100 |
| 31 | dub delay l/r ratio 0 |
| 32 | dub delay l/r ratio 50 |
| 33 | dub delay reso 0 |
| 34 | dub delay reso 100 |
| 35 | dub delay reso 100 res-freq 0 |
| 36 | dub delay reso 100 res-freq 100 |
| 37 | dub delay reso 100 res-freq 50 |
| 38 | eds reverb HALL mix 100 (len 1.29 s, bright 80) |
| 39 | eds reverb mode 1 mix 100 |
| 40 | eds reverb mode 2 mix 100 |
| 41 | eds reverb mode 3 mix 100 |
| 42 | eds reverb HALL bright 0 |
| 43 | eds reverb HALL bright 50 |
| 44 | eds reverb HALL bright 100 |
| 45 | eds reverb HALL length 0 |
| 46 | eds reverb HALL length 0.5 |
| 47 | eds reverb HALL length 1 |
| 48 | studio reverb HALL mix 100 (len 1.42 s) |
| 49 | studio reverb mode 1 (STADIUM) mix 100 |
| 50 | studio reverb mode 2 mix 100 |
| 51 | studio reverb mode 3 mix 100 |
| 52 | studio reverb HALL length 0 |
| 53 | studio reverb HALL length 1 |

### `s6trem`: Guitar Mod; Studio Mod (Chorus, Tremolo) with the Doubler (stimulus `tremstim`)

| seg | setting |
|---|---|
| 0 | mod mode 0 rate 50 depth 50 mix 50 |
| 1 | mod mode 0 rate 0 |
| 2 | mod mode 0 rate 100 |
| 3 | mod mode 0 rate 25 |
| 4 | mod mode 0 depth 0 |
| 5 | mod mode 0 depth 100 |
| 6 | mod mode 0 mix 0 |
| 7 | mod mode 0 mix 100 |
| 8 | mod mode 1 rate 50 depth 50 mix 50 |
| 9 | mod mode 1 rate 0 |
| 10 | mod mode 1 rate 100 |
| 11 | mod mode 1 rate 25 |
| 12 | mod mode 1 depth 0 |
| 13 | mod mode 1 depth 100 |
| 14 | mod mode 1 mix 0 |
| 15 | mod mode 1 mix 100 |
| 16 | mod mode 2 rate 50 depth 50 mix 50 |
| 17 | mod mode 2 rate 0 |
| 18 | mod mode 2 rate 100 |
| 19 | mod mode 2 rate 25 |
| 20 | mod mode 2 depth 0 |
| 21 | mod mode 2 depth 100 |
| 22 | mod mode 2 mix 0 |
| 23 | mod mode 2 mix 100 |
| 24 | studio chorus defaults (rate 50 depth 50, doubler mix 100) |
| 25 | studio chorus rate 0 |
| 26 | studio chorus rate 100 |
| 27 | studio chorus depth 0 (doubler alone, mix 100) |
| 28 | studio chorus depth 0, doubler mix 0 |
| 29 | studio chorus depth 100, doubler mix 0 |
| 30 | studio tremolo rate 25 depth 0 doubler mix 0 |
| 31 | studio tremolo rate 25 depth 0.25 doubler mix 0 |
| 32 | studio tremolo rate 25 depth 0.5 doubler mix 0 |
| 33 | studio tremolo rate 25 depth 0.75 doubler mix 0 |
| 34 | studio tremolo rate 25 depth 1 doubler mix 0 |
| 35 | studio tremolo depth 100 rate 0 doubler mix 0 |
| 36 | studio tremolo depth 100 rate 0.5 doubler mix 0 |
| 37 | studio tremolo depth 100 rate 0.75 doubler mix 0 |
| 38 | studio tremolo depth 100 rate 1 doubler mix 0 |
| 39 | studio tremolo depth 100 rate 25 doubler mix 100 |
| 40 | studio tremolo depth 50 rate 25 doubler mix 100 |

### `s6mod`: Guitar Mod: the in-between Depth, Rate and Mix (stimulus `tremstim`)

| seg | setting |
|---|---|
| 0 | mod mode 0 rate 50 depth 50 mix 50 |
| 1 | mod mode 0 depth 25 |
| 2 | mod mode 0 depth 75 |
| 3 | mod mode 0 rate 75 |
| 4 | mod mode 1 rate 50 depth 50 mix 50 |
| 5 | mod mode 1 depth 25 |
| 6 | mod mode 1 depth 75 |
| 7 | mod mode 1 rate 75 |
| 8 | mod mode 1 mix 25 |
| 9 | mod mode 1 mix 75 |
| 10 | mod mode 2 rate 50 depth 50 mix 50 |
| 11 | mod mode 2 depth 25 |
| 12 | mod mode 2 depth 75 |
| 13 | mod mode 2 depth 10 |
| 14 | mod mode 2 depth 90 |
| 15 | mod mode 2 rate 75 |
| 16 | mod mode 2 mix 25 |
| 17 | mod mode 2 mix 75 |

### `s6pitch`: Vocal Tuner: Smart Tune and Harmonizer (stimulus `pitchstim`)

| seg | setting |
|---|---|
| 0 | smart tune defaults: C Major, speed 32 ms, Mid, Default, 440 |
| 1 | smart tune scale type 1 (Minor) |
| 2 | smart tune scale type 2 |
| 3 | smart tune scale type 3 |
| 4 | smart tune scale type 4 |
| 5 | smart tune scale type 5 |
| 6 | smart tune scale type 6 |
| 7 | smart tune scale type 7 |
| 8 | smart tune scale type 8 |
| 9 | smart tune scale type 9 |
| 10 | smart tune scale type 10 |
| 11 | smart tune scale type 11 (12th row) |
| 12 | smart tune root A major |
| 13 | smart tune speed 25 % (C major) |
| 14 | smart tune speed 75 % |
| 15 | smart tune tracking Unworried |
| 16 | smart tune tracking 2 |
| 17 | smart tune tracking 3 |
| 18 | smart tune tracking 4 |
| 19 | smart tune audio type Very Low |
| 20 | smart tune audio type 1 |
| 21 | smart tune audio type 3 |
| 22 | smart tune audio type 4 |
| 23 | harmonizer defaults: Scale, A major, V1 +5th, V2 +3rd, stereo, tightness 70 |
| 24 | harmonizer v1 pitch +Oct |
| 25 | harmonizer v1 pitch item 1 |
| 26 | harmonizer v1 pitch item 2 |
| 27 | harmonizer v1 pitch item 4 |
| 28 | harmonizer v1 pitch item 6 |
| 29 | harmonizer v1 pitch item 7 |
| 30 | harmonizer v1 pitch item 8 |
| 31 | harmonizer v1 pitch item 9 |
| 32 | harmonizer v1 pitch item 10 |
| 33 | harmonizer v1 pitch item 11 (sliver row) |
| 34 | harmonizer v1 gender min |
| 35 | harmonizer v1 gender max |
| 36 | harmonizer v1 vol bar 50 % |
| 37 | harmonizer v1 delay 1/32 |
| 38 | harmonizer v1 delay 1/16 (sliver row) |
| 39 | harmonizer tightness 0 |
| 40 | harmonizer tightness 100 |
| 41 | harmonizer stereo off |
| 42 | harmonizer voice 2 off (voice 1 alone) |
| 43 | harmonizer mode auto |
| 44 | harmonizer scale minor |

