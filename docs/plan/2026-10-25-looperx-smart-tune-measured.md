# The Looper X Smart Tune, measured (#891, #1480)

These measurements come from the owner's emulated Looper X 1.0.2 in the #891 rig, sessions s5 and s6pitch (2026-10-24 and 2026-10-25). This page holds numbers only. The captures stay on the rig machine.

## The stimuli

- **s6pitch 0-22.** 0.5 s of silence, then 25 sines, each 0.45 s long with 50 ms between them. They step from 440 to 880 Hz, 50 cents at a time. After them come a 2 s saw at 220 Hz and a glide from 220 to 440 Hz over 3 s.
- **s5/8-11.** 1 kHz bursts of 0.5 s at eight levels.

The rig plays the device's 48 kHz output linearly upsampled to 96 kHz, so the even samples are the device's own. Every reading below comes from those samples.

## The controls

Smart Tune's screen shows Speed, Tracking, Scale Root, Scale Type, Audio Type and Reference. The Harmonizer's screen shows Mode, Auto Source, Key, Scale, Stereo and Tightness. The captures confirm the split: with Smart Tune's Scale Root at C and the Harmonizer's Key at A, the output followed C.

| control | range | read |
|---|---|---|
| Speed | 1 to 1000 ms, exponential | 6, 32, 179 and 994 ms on screen at 25, 50, 75 and 100 % |
| Scale Root | C to B | |
| Scale Type | 14 types | Major, Minor, Harm Min, Melo Min, Dorian, Phrygian, Lydian, Mixo, Locrian, Chromatic, Penta, Maj Triad, Min Triad, Root |
| Reference | 420 to 460 Hz, linear | 440.0 at 50 %, 459.9 at 99.6 % |
| Tracking | Unworried, Default, Selective, Picky, Blind | |
| Audio Type | Very Low, Low, Mid, High, Very High | |

## What it does

**The output goes to the nearest note of the scale.**
- At Unworried tracking, all 25 steps of the C major staircase land on the nearest C major note.
- The other captured types give the same picture on every step they do not tip. Section "Not modelled" lists the tipped steps.
- A step exactly between two notes of the scale can land on either. The detector decides, and which way it goes changes with Tracking.

**The scale types are the usual sets, with two exceptions.**
- Locrian plays Phrygian's notes: G, not Gb. The two captures are identical.
- Penta is the minor pentatonic: C, Eb, F, G and Bb.
- Min Triad and Root sit below the list's twelfth row, which the screen does not scroll to, so neither was captured. Ours builds their notes from the names: root, minor third and fifth, and the root alone. These are on #1459 for the owner to check by ear, since the device's names are not always literal (its Locrian).

**The correction glides in cents, exponentially.** The time constant is about half the Speed.

| Speed | time constant | from |
|---|---|---|
| 6 ms | under 2 ms | s6pitch 13, four steps |
| 32 ms | 17 ms | s6pitch 0, four steps, 1 to 3 cents rms off the fit |
| 179 ms | 78 ms | s6pitch 14, four steps |
| 1000 ms | about 500 ms | s5/10: 1 kHz is still 8.7 of its 21 cents from B5 0.45 s into the burst |

- The correction starts 6 to 25 ms after the note does.
- Each note after silence starts from the input's pitch.

**On a glide, the note changes at the midpoint between two notes.** For a whole tone the switch comes 0 to 3 cents past the midpoint. For a semitone it comes 10 to 12 cents past.

**Reference moves the whole scale.** At 460 Hz, 1 kHz goes to 1032 Hz, which is B5 with A at 460.

**The level is unity.** The output is fully wet, -0.06 dB on every step and on the saw. The latency is about 21 ms.

## The kernel

- **Pitch shifting.** It uses the octaver's PSOLA, fully wet. The PSOLA's detection gives the period. The correction, in cents, glides one pole toward the nearest note with a time constant of Speed / 2.
- **Ties and warble.** A note held while the input sits within 0.1 semitone of as near to another stays held, so a voice between two notes does not warble.
- **Start of a note.** A note starts correcting once the detector is settled, at the PSOLA's third detection, about 10 ms in.
- **PSOLA marks keep their fractions.** The PSOLA's synthesis and analysis marks used to be whole samples. Rounded that way, the output landed up to 16 cents off the ratio for an 880 Hz voice at 48 kHz.

## How well the kernel matches

**The scales.**
- Every captured scale lands on the capture's note at every step not exactly between two notes and not tipped: 13 captures and 216 steps.
- Our kernel lands within 0.1 cent of the note. The Looper X lands up to 8 cents off.

**Speed.**

| Speed | ours | capture |
|---|---|---|
| 32 ms | 16.9 ms | 17 ms |
| 179 ms | 88.7 ms | 78 ms |
| 1000 ms | 500.7 ms | about 500 ms |

**The rest.**
- Speed 1 ms is on B5 60 ms into a 1 kHz tone.
- Reference 460 Hz gives 1032.7 Hz. The capture reads 1032.
- The level is -0.03 dB.
- The 220 Hz saw stays on A3 within 0.5 cent.

## Not modelled

**Tracking and Audio Type.** On the captures' sine tones these only change how the device's detector tips some notes:
- **Default, Selective, Picky and Blind tracking.** Around 620 to 740 Hz, a few steps land on a note outside the scale: Major's F# at Default, and F to F# at Selective.
- **Picky and Blind.** These leave several steps uncorrected.
- **Audio Type.** Changing it moves which steps tip.

No rule in these captures explains them, so ours leaves both controls unmapped and the module reads partial.

**The device's landing error.** The device lands up to 8 cents off the note. Ours lands on it.

**The device's latency.** It is about 21 ms. Ours is the octaver's: 25 ms at 48 kHz and 12.7 ms at 96 kHz.
