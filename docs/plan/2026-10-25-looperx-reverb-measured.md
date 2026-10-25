# The Looper X Reverb, measured (#891, #1476)

These measurements come from the owner's emulated Looper X 1.0.2 in the #891 rig, sessions s6rev, s8 and s14 (2026-10-24 and 2026-10-25). This page holds numbers only. The captures stay on the rig machine.

Every pass used the same stimulus, revstim: an impulse of 0.5, then 10 s of silence, then a 1 s noise burst and 10 s more. The rig plays the device's 48 kHz output linearly upsampled to 96 kHz, so the even samples are the device's own. Every reading below comes from those even samples.

## One network behind every room

**The racks show the module two ways.**
- **Drum Rack.** An ER room list, plus Length, Lo/Hi, Tail/ER, Density and Mix.
- **Every other rack.** A mode (HALL, STADIUM, ROOM or BOX), plus Length, Bright (not on Studio or Rhythmic) and Mix.

**One tail network serves all of it, and it is the Dub-Verb's.** The Drum tail's arrivals at 10 to 50 ms fall on the same samples as the Dub-Verb's. The modes' tails are that same network scaled in time:

| room | delays, times the Drum tail's | tail starts at | Drum arrivals matched |
|---|---|---|---|
| HALL | 0.841 | 29 samples | 23 of 23 |
| STADIUM | 1.000 | 3466 samples (72.2 ms) | 23 of 23 |
| ROOM | about 0.43 | 866 samples | 12 of 23; its own early taps mask the rest |
| BOX | about 0.2 | from 15 ms | none placed, because its early taps dominate |

At one Length, each mode's T30 scales with its size: ROOM is 0.50 x HALL, BOX 0.24 x and STADIUM 1.19 x.

**The network's first diffusers are three all-pass filters** at 488, 660 and 720 samples (left) and 510, 740 and 762 (right).
- Density scales their gain.
- The tail's immediate tap goes as Density cubed: 0.017, 0.127 and 0.42 of its full value at 25, 50 and 75 %, and nothing at 0.

**The first 30 to 50 ms do not depend on Length.** Between Length 0 and 0.5 or 0.9, the first part of each room differs by:

| room | span checked | difference |
|---|---|---|
| HALL | 50 ms | -40 dB or less |
| STADIUM | 50 ms | -49 dB or less |
| ROOM | 50 ms | -51 dB or less |
| BOX | 30 ms | -58 dB or less |
| Drum tail | 50 ms | -37 dB or less |

So the kernel plays each room's first 40 to 50 ms as that room's measured taps, and fits a network behind them for the rest.

## The rooms

**Drum ER rooms.** Each was captured alone, at Tail/ER 100 % and Mix 100 % (s8drm and s6rev 15). Each room is 16 taps a side through the tone filter, within -23 to -33 dB of the capture. All rooms land between 11 and 57 ms.

LARGE STUDIO's ER is the Amb-Verb's early pattern: 24.58 ms, then 32.79 ms on the left and 40.48 ms on the right.

**Drum rooms 12-14 can't be reached.** These are OPERA HOUSE, VINTAGE 1 and VINTAGE 2. The Looper X's list shows rows 0-11 and does not scroll. No factory preset uses them. Our Drum Rack lists the 12 measured rooms, and a stored 12-14 plays CHURCH. This is on #1459 as a decision for the owner.

**Which racks apply the mode.** Each rack's reverb was switched between two modes, and the two outputs differ by:

| rack | modes compared | difference | applies the mode? |
|---|---|---|---|
| Studio | four, at five Lengths each | several dB | yes |
| Vocal | HALL against STADIUM | 2.5 dB | yes |
| Vocal-Tuner | ROOM against HALL | 3.0 dB | yes |
| Rhythmic | HALL against STADIUM | 2.5 dB | yes |
| Ed's | HALL against the other three, chosen live | none, to -139 dB | no |
| Ed's | presets loaded with ROOM and STADIUM stored, against the same presets set to HALL | none, to -182 and -175 dB | no |

- Rhythmic's HALL equals Studio's to the sample.
- Ed's plays HALL whatever its mode, and its Rev Mode is unmapped. This is on #1459 as a decision for the owner.

## The controls

- **Mix** is equal-power at every captured point.
  - **Modes:** a half turn. The dry is 0.885, 0.703 and 0.456 at 30, 50 and 70 %, which is cos(Mix x pi/2), and none at 100 %.
  - **Drum:** a quarter turn. The dry is cos(Mix x pi/4), which leaves 0.707 at 100 %. The wet follows sin within 3 % at 30, 50, 70 and 100 %.
- **Tail/ER** (Drum) is equal-power over a quarter turn. The ER goes as cos((1 - Tail/ER) x pi/4), and the tail as the matching sine, both within 1 % at 0, 30, 50, 70 and 100 %. At 0 % the ER still plays, at 0.707.
- **Bright** is a first-order low-pass on the whole wet, with the zero near Nyquist. Its corner is 1010 x 20.5^Bright Hz.

  | Bright | 0 | 25 % | 50 % | 65 % | 80 % | 90 % | 100 % |
  |---|---|---|---|---|---|---|---|
  | measured corner, kHz | 1.01 | 2.17 | 4.58 | 7.31 | 11.3 | 15.1 | 20.4 |

  The formula matches every point within 0.2 kHz. Studio and Rhythmic fix Bright at 75 %, which their first tap reads (9.7 kHz).
- **Lo/Hi** (Drum) uses the same low-pass, from its own corners:

  | Lo/Hi | 0 | 25 % | 50 % | 75 % | 100 % |
  |---|---|---|---|---|---|
  | corner, kHz | 1.35 | 2.48 | 4.49 | 9.43 | open |

  At 100 % it also cuts the lows like a 12 dB/octave high-pass at 65 Hz: -12.4 dB at 31.5 Hz against 50 %. At 75 % there is no cut (under 1 dB at 12 Hz). The kernel moves the cut's corner 11 times lower per quarter below 100 %.
- **Length** follows each room's own decay table.
  - The wet's energy stays nearly level across Length: HALL's moves 5 dB from Length 0 to 0.9, while a fixed injection would move it 14 dB.
  - The HALL's 8 kHz decays faster at long Lengths. The ROOM's and BOX's do not.

## How well the kernel matches (scratch fit, 48 kHz)

Measured against each capture as recorded:

| | first 50 ms | whole wet | octave spectrum | T30 |
|---|---|---|---|---|
| modes, Lengths 0.25 to 0.75 | within 0.4 dB | within 0.4 dB | within 0.6 dB | within 6 % |
| Drum, Length 0.1 to 0.7 | within 0.7 dB | within 0.3 dB | within 0.6 dB | within 14 % |
| ER rooms alone, to 60 ms | within 0.1 dB | | | |

- Windows of 20 ms or more after the taps are within 2 to 4 dB at those Lengths.
- First arrivals land on the captured sample on both sides.
- Bright's 8 kHz-to-1 kHz tilt is within 0.2 dB at every captured setting.
- At 96 kHz each room keeps its 48 kHz band levels within 0.4 dB, and its T30 within 1 %.

## Known differences

- **The shortest and longest Lengths fit less well.**
  - At Length 0, HALL's level from 160 to 520 ms is up to 9 dB under the capture: the network can't hold the Looper X's 250 ms plateau. STADIUM is up to 5 dB under there.
  - At 0.9, HALL and STADIUM decay 15 to 30 % fast at 125 Hz to 1 kHz.
  - At Length 0.25, BOX is up to 8 dB off in single windows past 100 ms.
- **Low Density's late part is smooth.** Below 50 %, the Looper X's tail past 50 ms breaks into separate echoes. The kernel's is a smooth decay at the right level, up to 16 dB off in single windows at 0 %. Factory presets use Density 57 to 100 %.
- **A room change restarts the tail.** The old room fades out over the smoothing time, and the new room starts empty with its input fading in.
- **Cost.** Each room plays up to 64 taps a side plus 16 ER taps on the Drum. That is about three times the Dub-Verb's cost.
