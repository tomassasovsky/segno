<!-- cspell:words heatsinks Omron lofi powf aubio Ghidra BLEP BLAMP unnormalised Clob Sallen linearised transconductance unmodulated Bandpass Lowpass Metalic Wurli MKII Perc halvings retrigger retriggers unsynced Quantizer autocorrelation tfz unmeasured retriggered isolations penv Unisono pul meldfit Geigerzaehler Bellatine Keystrike Numan uncentred dfit Grimer Tesseract Tesseract's auxenv fdrive fltkey keyscale lfofree minatt noteoff penvd rndpan Bassic Bitgrunge's Catchem Filther's Kaneda Werkstuecktraeger Whley Whley's filt nloop avel fleg unmodulated Basscycle spr prewarping prewarp Floot Halfstep Gametal Plucks Neurotimbre sqperc -->
# Segno — Progress & Roadmap

<!-- cspell:words hashlib manufacturability unassembled Axicom Mbps raucs multicore smarttune -->

Living status doc for Segno, the live looping appliance (a Raspberry Pi 5
console). It began as a Flutter desktop loopstation; the original plan is
`docs/plan/2026-06-08-feat-flutter-desktop-loopstation-plan.md`. macOS and
Windows were dropped as targets in #920, so desktop-era entries below are
history.
Update this as work lands so any session (human or agent) can resume cold.

Repo: https://github.com/tomassasovsky/segno · branch `master`.
Sibling repos (#1496): [segno-design](https://github.com/tomassasovsky/segno-design)
(design snapshots, the frozen `segno-ui.pen` and the design studies, cloned
at `../segno-design`) and
[segno-hardware](https://github.com/tomassasovsky/segno-hardware) (boards,
enclosure, printed parts). See **Sibling repos** in `AGENTS.md`. Entries
below that name paths under `hardware/` or `docs/design/` predate the split
and refer to those repositories now.

Design source (#1503): the Penpot file **segno-ui** (project **Segno**) on the
self-hosted Penpot at http://192.168.50.122:9001, home network only. It was
converted from `segno-ui.pen` at segno-design 7c77cc4 on 2026-10-28; the pen
is frozen since then and kept for history. Entries below that name pen
frames (`AREA / name`, `c/` notes) refer to the same frames in the Penpot
file, where each area is a page. Workflow, MCP preconditions and snapshots:
**Design source** in `AGENTS.md`.

---

## Active threads

Issues with a live branch. Agents add a row when a thread starts, update it
when its stage changes, and remove it in the PR that closes the issue or when
the work is parked (rules in `AGENTS.md`). Stage and gate are copied from the
Jira issue (project `SEG`), which is authoritative; if a row disagrees, fix the row.

| Issue | Thread | Stage | Gate | Branch |
|-------|--------|-------|----------|--------|
| SEG-61 | NVMe drive drops off the bus mid-recording: the Pi 5 cmdline turns off APST and PCIe ASPM on every link | in-review | needs-hardware | `claude/nvme-power-1795` |
| SEG-62 | A finished export to a FAT stick is on the device: copies and the export end with a volume sync | in-review | needs-hardware | `claude/usb-export-durable-1797` |
| SEG-8 | Start helper programs with posix_spawn, never fork the app | in-review | needs-merge | `claude/no-fork-1367` |
| SEG-81 | Retry Wi-Fi after a runtime drop, holding off while performing | in-review | needs-hardware | `claude/wifi-runtime-retry-1337` |
| SEG-46 | Song queue completion | in-review | needs-hardware | `claude/song-queue-comet-1077` |
| SEG-80 | Song and Band: one section at a time | in-review | needs-merge | `claude/song-one-section-1323` |
| SEG-50 | Replay audio-history changes in performance stems | build | needs-merge | `claude/stem-history-replay-1143` |
| SEG-53 | Appliance USB storage service | build | needs-merge | `claude/usb-storage-1177-*` |
| SEG-56 | Pitch and time DSP core | build | needs-merge | `claude/pitch-time-1179-*` |
| SEG-57 | Instruments | plan | needs-merge | `claude/instruments-1197-*` |
| SEG-58, SEG-47 | Recording to USB and long recordings: Parts 1-5 and 11 on master; durability and bounded recovery (Part 8's finalize and recovery, fixes #1078) in build | build | needs-merge | `claude/recording-durability-1198-p*` |
| SEG-60 | Backing player | plan | needs-merge | `claude/backing-1200-*` |
| SEG-64 | Shared render recipe, Bounce, Save selected | plan | needs-merge | `claude/render-1202-*` |
| SEG-66 | MIDI clock | plan | needs-merge | `claude/midi-clock-1228-*` |
| SEG-74 | Device and appliance pages (Parts 6, 7, 9, 11, 12 shipped; plan approved 2026-10-26 and refreshed; Q5 answered: refuse an Apply over the effects budget; P1, P2, P3a, P3b, P4 and P5 merged; P8 update from USB in review; all parts built; on-device checks listed on the issue) | build | needs-merge | `claude/device-pages-*1270*` |
| SEG-30, SEG-43 | Screen audits: every fix is on master; the Penpot writeback listed under each PR's Design writeback is owed (no Penpot tab with the MCP plugin on 2026-11-19) | build | agent-merges | none |
| SEG-24 | Drive pedals' aliasing at 48 kHz: four kinds oversampled (#1552); the owner's blind pairs decide whether the built-in Drive is oversampled too | build | needs-plan-approval | `claude/drive-alias-1540` |
| SEG-49 | Every effect cheaper without changing its sound: pitch (#1764, #1770), drives (#1759), reverbs/delays/filters (#1762) and the Vinyl (#1904, part 4) bit-identical; part 5, the Degrade at 96 kHz, is next (scope on the issue) | build | agent-merges | `claude/fx-opt-part5-1755` |
| SEG-90 | The app's audio callback runs late on screen changes and take starts: it waits on memory (Ed's Racks overflow the caches). Parts 1-4 and 6 merged (#1925, #1926, #1932, #1933, #1935); part 5 in review (Mesa keeps a page transition's render target, made at startup). Steady playback and take starts are clean on the console; the rare xruns were the bench's own reads of the app's memory | in-review | needs-plan-approval | `claude/cb-overhead-1914-p5` |
| SEG-48 | Effects budget from the app's measured headroom: 10-minute untraced in-app ladder at 48 kHz / 32 (build 279); track job 200 → 300 ns, chains on the callback charged 2.5× (`kFxSerialFactor`); 4 inputs + 7 tracks or + 1 output rack fit | in-review | agent-merges | `claude/fx-headroom-1724-p3` |
| SEG-22 | Effects on more than one core: plan merged (#1517); part 1 merged (#1521); effects that do not fit switch off at record and when the rig comes up (owner's R1, R2) in review; part 2 (track and lane chains) is #1729 | build | needs-plan-approval | `claude/fx-multicore-1515-p1b` |
| SEG-107 | Save As failed with Out of Memory: the mixdown asked for the LCM of two Song-mode tracks (24.7 GB); it now spans the longest lane past 600 s, and the save refuses a length no loop can hold | in-review | needs-hardware | `claude/save-oom-SEG-107` |
| SEG-63 | Console WiFi against an ASUS RT-AX89X with 802.11ax on: firmware already matches Pi OS; brcmfmac options aligned with Pi OS and a troubleshooting note; failure not reproduced, issue stays open until it recurs | in-review | agent-merges | `claude/wifi-firmware-1816` |
| SEG-109 | Ableton Live device presets on the pedal, Drift first: presets read from the user's own copy; Drift's behavior learned with rea + Ghidra from Live 12.2.7 and reimplemented, no Ableton code or presets in the repo. Plan approved 2026-11-25 (P1-P6); P1 stereo buses, P2 preset reader, P3 the Drift device and P4 its fit in review; the Operator (P7), Meld (P8), Analog (P9) and Electric (P10) devices in review | in-review | needs-merge | `claude/ableton-devices-SEG-109`, `claude/ableton-operator-SEG-109-p7`, `claude/ableton-meld-SEG-109-p8`, `claude/ableton-analog-SEG-109-p9`, `claude/ableton-electric-SEG-109-p10` |

---

## November 2026 The Electric device plays on an instrument slot (SEG-109 P10)

- Live 12.2.7's Electric read with rea + Ghidra from its AAS engine and
  written as "Electric: behavior" in the Ableton devices brainstorm;
  `electric_voice.c` is written from it. `LE_INST_DEVICE_ELECTRIC` takes an
  Electric preset's 33 values (`le_electric_param`), one more entry in the
  device table.
- Per voice a mallet pulse and a damper burst ring a fork of four
  resonators (tone bar, tine, tine partial, a fixed-pitch "mallet noise"),
  heard through the electromagnetic or the electrostatic pickup, in 1 ms
  blocks as Live runs it.
- Fitted against 69 Live renders: total 1.09 dB rms. Measured where the
  reading was silent: the tine at 7.349 times the note, Tine Color and
  Tine < Key the other way round from their names, the output level.
- The 17 factory presets, at C4 and six of them also two octaves down or
  up: 19 of 23 within 1.0 dB, twelve within 0.2; Vibes Soft 1.4 to 3.9.
- Strict score (50 ms cells, attack, level, onset, pitch): 65 of 69
  renders and 21 of 23 presets pass, from 63 and 22. New: Live's output
  soft clip (linear to 2.8, toward 4 at Segno's scale), the exact midpoint
  of the neutral-centred controls, and the fit harness releasing on
  Live's block. Still failing: four renders where the damper's noise
  rings a resonance by a random amount per strike.
- A voice costs 1.4 us per millisecond on the dev machine with the R
  pickup, 0.9 with W. A device holds 40 voices (10 KB).

## November 2026 The Analog device plays on an instrument slot (SEG-109 P9)

- Live 12.2.7's Analog read with rea + Ghidra from its AAS engine (the
  device, then its formant filter) and written as "Analog: behavior" in the
  Ableton devices brainstorm; `analog_voice.c` is written from it.
  `LE_INST_DEVICE_ANALOG` takes an Analog preset's 171 values
  (`le_analog_param`: the device's own, then two chain blocks of 67).
- Two chains per voice, each an oscillator (sine, saw, rectangle, noise,
  sub or sync), a filter (all ten types, the formants among them) with its
  drive, an amp, an LFO and two looping envelopes, plus noise, glide with
  key priority, vibrato and unison of 2 or 4 copies.
- The slots reach every device through one table of functions
  (`instrument_devices.c`), so a device is one entry; each keeps its own
  instances, so a device change still fades the old voices out under the
  new ones.
- Fitted against 178 Live renders: levels, routing, pan, envelopes and
  loops, the LFO waves, glide, the filters and drive within 0.1 to 2.5 dB
  rms (round totals 1.9, 1.4, 1.9). Measured where the reading was silent:
  the balance's direction, the sustain stage and loops, the glide time's
  curve, the unison offsets' pattern, the LFO triangle's start and the
  noise ramp; the unison detune is ExpZ(0.001, 1) octaves (Tension's
  reading of the shared unison: copies an octave apart at full detune);
  the filter envelope's depth is 16 u^4 octaves (Tension's reading of the
  shared filter), which brought the factory presets from 13.5 to 5.3 dB.
- 23 factory presets, octave bands rms: 13 within 2.2 dB; Kick Complex
  Perc (26.5) is the open one.
- The strict score (third-octave x 50 ms cells, the attack, stereo, f0,
  level, onset) passes 171 of 201 renders (from 91), 5 of the 23 factory
  presets (from 0): the oscillators start and band-limit as Live's do,
  13 samples late, the rectangle without its DC offset (most of the
  presets' 2 to 6 dB excess), the amp envelope per sample with a start
  ramp, the tempo divisions and LFO depths on the amp, the mono
  retrigger. Round 4 added Keyboard Stretch and Error, the pan's knob law
  and free LFO starts: 206 of 266 fit renders, 14 of 41 presets, 10 of 58
  on the held-out round (from 8). Left: Live's early note-ons (most of the
  held-out failures), the unison delay, the pitch envelope at full depth;
  segno-analog-fit5 isolates event timing, velocity, chords, range and
  Live's own spread on the random sources. Round 5: the amps' start ramp
  is the device's, the free LFO runs from the device's start, Keyboard
  Error is uniform: 240 of 307 fit renders, 13 of 58 held out. Live's
  later note events land 8 to 68 samples early, beyond any in-block snap.
  After round 6 (scored with per-note alignment, from 239 of 345 and 10 of
  58 held out): the oscillator's 40-sample pitch tick with its period
  ramp and the pitch envelope 3.5 % longer (Kick Complex Perc from 26 to
  0.4 dB), the cubic 2^x on the keyboard pitch, Free Run ignoring the
  release (Zap 25 to 9), a free LFO and a Legato filter envelope kept per
  device voice (Rhythmic Octaves Bass 17 to 10), no glide between a
  chord's keys in Const mode: 246 of 345 fit renders, 17 of 79 factory
  presets, 10 of 58 held out (median 3.89 dB). Left: Live's onset hump on
  fast upward sweeps, the LFO rate's dips, the random sources;
  segno-analog-fit7 (39 renders) isolates the first two and the per-voice
  state.
  Round 7 (segno-analog-fit7): the pitch envelope's length per time knob
  and a 0.1 s run-on of a Legato filter envelope after its voice goes
  quiet: 248 of the 345 earlier fit renders (281 of 384 with round 7), 18 of 79 factory presets; round 7 itself 33 of 39 (the free LFO's run-on between
  notes is left), 10 of 58 (median 3.89 dB) held out. Analog keeps velocity / 127 (its
  renders fit it better than the other AAS devices' (velocity - 1) / 126),
  and its release tails end at the release's end, with no early cut.
  Judged against Live's own copies (segno-analog-val3, val4): 11 of 58
  held out; the unison delay is behind four of the deterministic failures.
  Copy k of a unison voice now starts k delays in, as uni4-dly-100 shows
  (fit 286 of 384 before and after); segno-analog-fit8 (40 renders) reads
  the delay itself, the free LFO's run-on, the steal order and the Kick's
  and Saw Pure Muted Bass's higher notes. Seven shared causes found by sorting
  the held-out failures and fitted on fit renders (a free S&H holds 0 for
  its first cycle, a fresh voice's free LFO runs from the device's start,
  a mono key change restarts retriggered LFOs, no floor on Q, a mono
  vibrato runs on through silence, no sub in Sync mode, an unclamped pan
  angle): fit 290 of 384, factory presets 22 of 79, held out 15 of 58.
  segno-analog-fit9 (41 renders) reads the vibrato and LFOs across notes,
  a reused voice's oscillators, Live's event timing and mono stretch.
- A voice of two saw chains through LP24 costs 0.9 us per millisecond on
  the dev machine, four unison copies 3.7, the formant filter 1.0. A
  device holds 40 copies (229 KB).

## November 2026 The Meld device plays on an instrument slot (SEG-109 P8)

- Live 12.2.7's Meld read with rea + Ghidra (seven readers: the oscillators
  in three passes, the filters in two, the modulation, the voices) and
  written as "Meld: behavior" in the Ableton devices brainstorm;
  `meld_voice.c`, `meld_osc.c` and `meld_filter.c` are written from it.
  `LE_INST_DEVICE_MELD` takes a Meld preset's 1082 values (`le_meld_param`:
  two engine blocks of 60, the device's own, then the 50 x 19 modulation
  matrix) through the same slot API as Drift and Operator.
- Two engines per voice, each one of 25 oscillators (all built) and 17
  filters (all built), an Amp and a Mod envelope, LFO 1 with six generators
  and 19 transformers, LFO 2; the matrix's sums and gain products; unison
  up to three copies with Spread; Mono, legato and glide; the per-copy
  drive and limiter.
- Shared with Operator: its OSR circuit, now `osr_section.h`, is Meld's
  Bandpass (Operator's renders bit-identical). Meld's Lowpass is the
  shared MS-20 section with its second integrator saturating too.
- Fitted against 282 Live renders: the output chain, levels, pan, tone,
  drive, limiter, tuning, unison, envelopes, both LFOs and every matrix
  target within 0.1 dB rms; most oscillators within 0.6 and 13 of 17
  filters within 0.5. Measured where the reading was silent: the matrix
  targets' scales, the times' and rates' cubic knob positions, where the
  limiter listens, Sub's clip, the comb's loop length.
- 21 factory presets, octave bands rms: 14 within 1 dB, Sugar Bass among
  them once a third round measured the note's key tracking of Filter Freq;
  that round also settled Chord's fourth voice and Square Sync's second
  slave. The Highpass is Segno's model of the MS-20 high-pass circuit
  (within 2.6 dB short of full drive); Lively Ringer is 9 dB off.
- The strict score (50 ms third-octave cells, the attack in 5 ms frames,
  stereo, pitch) passes 261 of 339 renders and 10 of 21 presets (from 245
  and 8): linked envelopes carry the matrix, Chord's tones start in phase,
  the Mod envelope's tick timing, Note into Tone, the free rate curve, the
  Quantizer, Tarp's sweep and the membrane's modes. Most of the rest is
  random (Pulsate, Swarm, Rand, S&H). With the scoring's three seeds and
  the random sources reaching LE_SEED: 309 of 385 renders and 16 of 21
  presets after a fourth round (the Bandpass's drive ends) and the
  held-out round's lesson (stealing counts fading voices and drops a note
  with no victim): 13 of 84 held-out presets, from 8. A fifth round
  confirmed the stealing on five fit renders and showed the LFOs' random
  draws repeat on every note and instance. Measured from Live's renders
  (rounds 7 and 8, allowed by the owner): the Pulsate, Wander and S&H
  sequences, Fold FM's eight intervals at position 7 M1^2, the times'
  fourth-power law, the triad's octave doubling, a 4.8 ms gain smoothing
  and the Mod envelope's legato restart: 484 of 559 fit renders and 13 of
  21 presets (from 333 of the same 559). Round 9 settled the Filther's
  settled start and, with the training phrase, Mono's LFO hand-over: 493
  of 573 fit renders, 13 of 21 presets, 15 of 84 held-out (tf mean 5.07
  to 4.32 dB). Round 10 measured free LFOs running from their voice's
  first note through silences, a silent voice's oscillator starting as
  Reset does, and Bitgrunge's skips (now a table): 503 of 594 fit
  renders, 13 of 21 presets, 17 of 84 held-out (tf mean 4.2 dB). Live's
  Noise Loop is a fixed noise sequence, not yet measured. With Live's
  spread from five instances: 19 of 84 held-out. Round 11 measured the
  Vowel filter's formants and resonance: 522 of 618 fit renders, 13 of 21
  presets, 24 of 84 held-out (tf mean 4.05 dB). Noise Loop is now Live's
  generator, written from the reader's description: 528 of 618 fit
  renders, 27 of 84 held-out. The held-out failures sorted by kind gave
  four details, each fixed on fit renders: the voice end measured to the
  sample (every Noise Loop note after the first now matches Live's), a
  legato restart lets the oscillator run on, a single copy's voice
  offset follows its Spread source, Harmonic FM's modulators go by
  parity: 537 of 618 fit renders, 14 of 21 presets, 32 of 84 held-out
  (tf mean 3.88 dB). Round 12 (the Sub's aliasing, Note into an Amp
  attack, Tarp's legato restart, two presets' engines alone) is built.
- A voice with both engines on a Basic Shapes saw and SVF 12 costs 1.8 us
  per millisecond on the dev machine; MS2 6.8, a Swarm 3.7, three unison
  copies 5.6.

## November 2026 The Operator device plays on an instrument slot (SEG-109 P7)

- Live 12.2.7's Operator read with rea + Ghidra (four readers: operators and
  FM, envelopes, filter and shaper, LFO, routing and voices) and written as
  "Operator: behavior" in the Ableton devices brainstorm; `operator_voice.c`
  is written from it. `LE_INST_DEVICE_OPERATOR` takes an Operator preset's
  507 values (`le_operator_param`: four operator blocks of 98, then the
  device's own) through the same slot API as Drift.
- Four table-lookup operators in the eleven algorithms, 23 waveforms (User
  waves rebuilt on the audio thread, one operator a render call),
  Antialias at 2x with band-limited tables, Tone, feedback on the
  unmodulated operators, the shared envelope engine with its loop modes and
  time scaling, the LFO and pitch envelope, the modulation routes, Spread,
  glide, Retrigger Mode and the voice table up to 48.
- Fitted against 255 Live renders: waveforms, FM, feedback, envelopes, LFO,
  glide, Spread, pan, Tone and the routes within 0.5 dB rms each. Measured
  where the reading was silent: an operator envelope's slopes other than 0
  and 1 hold and jump (as Live renders them; the filter and pitch
  envelopes curve), EnvTimeIncludeAttack changes nothing, the routes'
  sources and units (gain destinations only attenuate).
- The filters: Clean and Morph (Live's own noise through Segno's filter
  within 0.5 dB), MS2 on the section Drift's filter II uses (now shared,
  `ms2_section.h`; Drift renders bit-identical), and Segno's own models of
  PRD (a four-stage ladder) and OSR (a state-variable loop with a diode
  bounding its resonance), each fitted to Live's renders; SMP runs on
  MS2's section with its own constants. MS2's and SMP's high-passes are
  fitted shapes (damping fitted at resonance 0 to 1); PRD's is not read
  yet: Clean's high-pass stands in.
- The routes, measured in a fifth and sixth round: sources bipolar or
  resting at 0, gain destinations attenuating by 1 - a+ + a u, the LFO's
  and pitch envelope's routes scaled by their own amounts, the pitch
  envelope moving in ratio and its route in semitones.
- Ten factory presets, octave bands rms: seven within 1.6 dB (Sub Sine Bass
  0.0 to Bells Brushed Hits 1.6), Metallic FM 2.3, OP Bass 3.1 within
  40 dB of its loudest, Celesta 4.2 (its partials match).
- The strict score: 277 of 298 renders and 6 of 10 factory presets pass
  (from 248 and 4): curved filter and pitch envelope slopes, the
  one-poles measured in scaled levels (an operator's amplitude, the pitch
  envelope's ratios), the envelope floor as silence, random white noise,
  continuous LFO shapes, MIDI routes slowing the LFO rate, the filter
  envelope's amount as a gain destination, Spread in whole percent, no
  glide into a stolen voice, the MS2 and SMP high-passes, SMP's and PRD's
  resonance. Celesta, Bells Brushed Hits and Metallic FM are held by
  Live's random pan and phases; round 7 (52 renders) isolates the rest.
- Round 7 and the held-out round (scorer round 2): Sync on the song's
  sixteenths, LFO Rate and the crossfades taking controllers as bipolar
  (Analog Bouquet Brass now passes), the MS2 high-pass's damping, legato
  keeping the first note's key scaling. 324 of 349 fit renders, 9 of 10
  presets; held out 32 of 67 (from 29). Live's random pan and phases
  differ between instances, so Segno draws its own. Round 8 (81 renders)
  plays the failing held-out kinds with another phrase.
- Round 8: the pitch envelope moves the LFO rate in ratio, the Volume
  route scales the voice's output (not the modulators, after the
  shaper), Res takes controllers as bipolar, a loop's restart runs a
  minimal attack. 335 of 390 fit renders (round 8 13 of 41, from 9), 8 of
  10 presets; held out 35 of 67 (from 32).
- Round 9: the pitch envelope's one-pole keeps one shape whatever its
  span, Res, Filter Drive and Aux Env are gain destinations, OSR's
  self-oscillation refitted, envelope segments last whole samples. 363 of
  419 fit renders (round 9 23 of 29), 8 of 10 presets; held out 36 of 67.
- Held-out pass: Beat and Sync retrigger a whole period after their start,
  a releasing envelope ends at 10^-3 and its voice a block later, a chord
  joining a voice that took a sounding one's place does not glide. 365 of
  419 fit renders, 8 of 10 presets; held out 38 of 67.
- Round 10: each of Spread's two voices draws its own random pan (a fixed
  pan scales them by one law). 371 of 427 fit renders, 8 of 10 presets;
  held out 39 of 67 (five Live copies per random preset).
- Round 11: OSR damped at resonance 1 (no self-oscillation there) and
  without drive in Morph mode; Spread draws nothing per voice beyond its
  pans, the truncated table read and the sample-and-hold LFO match Live.
  387 of 452 fit renders, 8 of 10 presets; held out 39 of 67.
- Held-out pass 2: a note that takes a sounding voice's place waits for
  its 1 ms fade (Live's pending queue), and parameters apply per 16
  samples (Nebulae Keys' audio-rate sample-and-hold), the voice end kept on
  a 32-sample grid. 391 of 452 fit renders, 8 of 10 presets; held out 41
  of 67. Most random held-out failures come from Segno's three seeds
  drawing the first note's pan near the sides. Round 12 (23 renders) asks
  Live for each destination's control rate, the steal wait, the pitch
  multiplier through zero and the first random pan.
- A voice costs 2.7 us per period at 48 kHz on the dev machine, 4.5 with
  Antialias (a Drift voice 7.1).

## November 2026 Drift against Live's strict score (SEG-109 P4, round 5)

- A stricter score (third-octave x 50 ms cells, the attack, stereo width,
  pitch) showed what still differed. Fixed from Live's renders: a free
  LFO starts at its shape's start phase when the voice blocks reset and
  runs while idle; Reset Oscillator Phase makes a note on a sounding voice
  wait 1 ms while it falls silent, then restart (Mono legato too); glide
  moves in hertz (0.144 x Glide); filter II starts at rest (no -43 dB
  transient at note start) with its diode slope at 2.21; the filter path
  gains (0.15 and 0.37 dB high); Sample & Hold starts on a drawn step;
  Shark Tooth runs backwards in time, with narrower top widths.
- Strict score: 164 of 224 fit renders before, 171 of 200 after (the
  scorer's round 2 sets aside renders named `-r<n>`); factory presets 0
  to 1 of 5 (Euphoria Lead).
- What still fails is Drift Depth (Segno's tuning values are its own by
  rule; with Live's table in a scratch check the drift renders passed) and
  random sources (noise, Sample & Hold) that no render can match draw for
  draw. Round 16: key tracking is a blend in hertz ((1 - t) + t f / 440,
  which fixed Bloom Pad's filter peak), and Live's drift is the same in
  every instance. Strict score 207 of 244 with round 16; held-out 8 of 89.
- Round 17: Drift Depth now uses Segno's own tables with the statistics
  measured on Live (per key: mean +1.18, spread 3.63 cents per unit,
  neighbours correlated 0.53; per voice: mean +2.26, spread 7.2,
  independent), and Unison's lanes run sharpest first as the code orders
  them. Strict score 204 of 263 (presets 0 of 5); with measured values in
  a scratch build 245 of 263: 41 renders fail only on the exact drift
  values, pending the owner's decision on measured per-key values.
  Held-out: 8 of 89 (14 of 89 with the measured values).
- The owner allowed values measured from Live's rendered audio: Drift
  Depth uses the measured per-key and per-voice tables (round 17). Strict
  score 247 of 263, factory presets 3 of 5 (Bloom Pad, Euphoria Lead,
  80s Tape).
- Round 18 (51 renders): keys outside C1..B5 carry no drift offset, the
  per-voice offset does not depend on the key, the per-key offset follows
  the key played, and C1..F#1 are remeasured (round 17's windows were too
  short there). A Ratio-mode LFO follows a Mono lane's octave (Crunch
  Arcade: pitch an octave off before, tf 11.8 to 3.1), and the cycling
  envelope in Ratio mode on a pitch slot is phase modulation (Bellatine:
  336 cents sharp before, tf 15.7 to 2.9). Strict score 252 of 296 before
  and after with round 18 included, factory presets 3 of 5; held-out 14 of
  89 (Bellatine and Crunch Arcade much closer, still failing).
- Round 19 (39 renders): Osc 2 has its own per-voice drift offset on top
  of Osc 1's (tape-chord's stereo 1.87 to 0.04 dB); the voice's output
  clip is 0.35 and the filter input's negative side runs on to -1.6 (hot
  inputs into either filter within 1.7 dB rms, from up to 8.4); the
  cycling envelope's phase modulation is centred on its middle; the Ratio
  rates follow the per-key drift. The Key source, Pulse's shape clamp and
  when a releasing voice is free already matched. Strict score 300 of 335
  (round 19 included; 264 of the 296 scored before, from 252), factory
  presets 3 of 5; held-out 45 of 89, from 14.
- Round 20 (16 renders): Drift Depth's per-voice tables follow the
  preset's SerialNumber (clamped to 0..8388607; each serial its own
  values, the per-key table shared). Segno carries the measured tables of
  the factory presets' serials (0, 2217915, 8388607) and serial 0's for
  any other; SerialNumber is a new device parameter
  (`LE_DRIFT_SERIAL_NUMBER`), which the preset reader must pass. Monday
  Morning, Synth on Screen, Grimer Bass and Game Console now pass. Strict
  score 318 of 351 (rounds 19 and 20 included), factory presets 3 of 5;
  held-out 47 of 89.
- Filter I's resonance shaper drive fitted (self-oscillation level within
  0.2 dB, the long-open f1-1k-r1): 319 of 351; held-out 49 of 89 with
  five Live copies per random preset (17 of its 40 failures random, 23
  deterministic, most in time structure: beating, Stereo side, release
  tails, Mono). Round 21 is built for Mono note handoff.
- Round 21 (19 renders): Mono's handoff already matched (every synthetic
  render passes); a Mono lane an octave or two down keys as the note it
  plays (key tracking, Key source, per-key drift): Rogue tf 3.2 to 1.8,
  Sol Bass 4.5 to 4.2, held-out Gear Shift passes, AG Bass, Rogue and
  Sol Bass close. Strict score 335 of 370 (round 21 included), factory
  presets 3 of 5; held-out 50 of 89.
- Round 22: the oscillators' start phases already match Live's. Sample &
  Hold and Wander now follow the reader's description of Live's
  generator and its stepping (every voice tick, two steps at a block
  reset and at a retriggered note, the starting lane taking lane 0's
  values). Strict score 354 of 390 (round 22 included); round 23 is
  built for Stereo voice pairing.
- A silent voice in a running block runs its whole chain: its filters
  keep the state its turning oscillators give them, a note on it starts
  from that state (from rest with Reset Oscillator Phase on), and a
  released voice keeps sounding below its threshold until the block
  stops. Toy Helicopter, Transistor Reeds, Wave Pad, Echo Bells, 80s
  Tape, Darkened and Slow Roll Strings and others now pass. Strict score
  363 of 390, factory presets 4 of 5 (Clob Bass); held-out 61 of 89,
  from 48. Round 24 is built: the filter state of a stopped block,
  audio-rate cutoff modulation, Metallic Swell Pad.

## November 2026 Drift's filter II as an MS-20 circuit model (SEG-109 P4, round 4)

- A second reading of Live's filter II found each section to be a
  component-level Sallen-Key model of the later MS-20 low-pass: two
  integrators, a saturating transconductance, clipping buffers, DC-blocked
  ends and a diode curve in the resonance path. Segno builds that model
  itself (its own diode curve) in place of the fitted MS-20 style loop.
  Filter renders and presets: 1.7 dB rms on average (from 2.0); the
  resonant peaks 1.3 dB (from 1.5).
- Five presets, octave bands Segno minus Live: Euphoria Lead, Chirp Pluck
  and Clob Bass within about 1 dB, 80s Tape within 1.2 everywhere, Bloom
  Pad within 1.1 up to 2 kHz (+2.4 before). Levels within 0.7 dB.
- Costs more: a filter II voice takes 7 us per period at 96 kHz on the dev
  machine (filter I 3.2); the engine's voice budget fades the excess. The
  console benchmark (hardware) sets the device's voice limit.
- The voices run at the host rate: Live 12.2.7's renders are bit-identical
  with HiQuality on and off and match Segno without oversampling, so the
  2x path and its decimator are gone (half the cost at 48 kHz) and
  HiQuality is stored without effect. Every filter and oscillator test
  0.93 dB rms (from 1.28); Euphoria Lead's top octave within 0.2 dB.

## November 2026 Drift fitted against Live renders (SEG-109 P4, round 3)

- Rounds 10 to 13 of Live renders, a scoring harness over every filter
  test and a reading of Live's voice allocation. Filter II is now two
  MS-20 style sections with the resonance split 1.15 / 0.75 between them
  (Live's narrow peaks); filter I follows the code reading (base damping
  cancelled by the resonance, a cubic in the feedback); the filters' input
  clip has Live's hard edge; Shark Tooth plays inverted, which only the
  asymmetric clip reveals; voices run in blocks of four (idle voices in a
  running block keep turning, idle LFOs run), and each block's noise
  generators start alike, so chords share their noise across blocks as
  Live's do. Voice counts are 4, 8, 16, 24, 32.
- Five factory presets, octave bands Segno minus Live: Euphoria Lead and
  Chirp Pluck within 0.5 dB, Clob Bass within 1.6 dB (width -10.3 against
  -8.4 dB, from -16), 80s Tape within 1.2 dB up to 2 kHz and -2 dB above
  4 kHz, Bloom Pad within 1 dB up to 1 kHz and +2.4 dB at 2 to 4 kHz.
  Levels within 0.7 dB. A Drift voice costs 3.2 us per period at 96 kHz.
- Still open: Bloom Pad's unison beats (Segno's drift values are its own),
  both filters' open top octave, Clob Bass's width.

## November 2026 Drift fitted against Live renders (SEG-109 P4, round 2)

- Six more rounds of Live renders and a second reading of Live's LFO and
  oscillator code. Fixed: the LFO and cycling envelope's Mode order (Time
  and Ratio were swapped) and the Sync table (slowest first); Ratio mode
  follows the transposed note and, routed to pitch, phase-modulates both
  oscillators; the LFO keeps a phase per voice and restarts at the shape's
  peak; Shark Tooth's width by shape (it was inverted, and its window did
  not wrap, which left a DC offset); the filters' input clip and the
  bypass gain; filter II's open top octave; Glide; Drift Depth as a fixed
  offset per key plus one per voice; a note reuses the voice allocated last
  and, with Reset Oscillator Phase off, the phase that voice left.
- Five factory presets, octave bands Segno minus Live: Euphoria Lead,
  Chirp Pluck and 80s Tape within about 1 dB; Clob Bass within 1.5 dB up to
  4 kHz; Bloom Pad within 1.5 dB up to 1 kHz. Every level test within
  0.1 dB.
- Still open: filter II near a strong resonant peak (Bloom Pad +4.5 dB at
  2 to 4 kHz), Clob Bass's phrase width (narrower than Live's; one note
  matches), the voice-count table.

## November 2026 Drift fitted against Live renders (SEG-109 P4, round 1)

- Live 12.2.7 renders of controlled patches (one setting changed per render
  from a plain saw or white noise, exported unnormalised) against Segno's
  renders of the same patches settled most of P3's provisional values. The
  brainstorm's "Open items and the fits" lists each with its measurement.
  Fitted: the Volume curve (linear), the noise level and both filters'
  path gains (every level test within 0.2 dB), Stereo's pan law (no
  detune), Unison's equal-power pan, filter I (one section; damping from a
  soft knee at resonance 0 to a +29 dB peak at 1), filter II's resonance
  curve (interpolated through five measured points), and Drift Depth (a
  fixed offset per key and per lane, so a Stereo pair is decorrelated).
  Confirmed as P3 had them: the envelope mapping, filter modulation depth,
  key tracking about A4, the high-pass, the voices' starting phase.
- Five factory presets, Segno minus Live: levels -1.9 to +0.3 dB (were
  -8.7 to -0.8), Euphoria Lead's spectrum within about 1 dB per octave, 80s
  Tape's stereo width within 0.7 dB.
- Still open: the Saturated oscillator under shape modulation and the
  LFO's Time mode and per-voice phase (Clob Bass dark and narrow), filter
  II close to resonance 1 with bright sources (Bloom Pad), Glide, the
  voice-count and Sync tables.
- Resonance at 1 rings without oscillating, as Live's does; modulated past
  1 both filters self-oscillate (filter II now injects the same tiny noise
  as filter I to start).

## November 2026 The Drift device plays on an instrument slot (SEG-109 P3)

- `drift_voice.c` implements the brainstorm's "Drift: behavior" section:
  seven oscillator types with polyBLEP / polyBLAMP band-limiting (Sine and
  Triangle folders, Shark Tooth, Saturated, hard-synced Saw, Pulse,
  Rectangle), Gaussian noise, the mixer and filter routing, low-pass I (a
  two-integrator zero-delay loop with unequal integrators and a soft clip)
  and II (two nonlinear sections), the high-pass, two envelopes, the
  cycling envelope, the LFO's nine shapes, the three-slot matrix and the
  fixed pitch, filter and shape modulation, Poly / Mono / Stereo / Unison
  with Live's lane gains, pans and detunes, round-robin allocation that
  steals the oldest, glide and legato, Segno's own per-key tuning table and
  the ISO 226 note gain. Parameters land on a 32-frame grid, so a render is
  the same at any block size; everything else runs every sample.
- HiQuality ran the voices at 2x with a 31-tap half-band FIR below
  88.2 kHz and at the host rate above it (the appliance), as approved. P4
  round 4 removed it: Live's renders are bit-identical with HiQuality on
  and off and match the voices at the host rate.
- A slot plays a patch or a device: `le_engine_set_instrument_device` and
  `le_engine_set_instrument_device_param` take the values in the units a
  Live preset stores (`le_drift_param`). Notes, chords, sustain, the MIDI
  routes, expression, Cut, Reset and the voice limit reach a device slot as
  they reach a patch slot; the snapshot's `instrument_device` names it. The
  Dart bindings carry the calls and `le_drift_param`.
- Provisional until P4 fits them against Live renders, each in one marked
  block of `drift_voice.c`: the envelope time mapping, the Volume and
  Glide curves, filter key tracking, filter II's damping, the Stereo
  mode's spread, the voice-count and Sync tables, and the voice clip.
- `bench_instruments` gains an informational Drift section. On an M4 Pro
  a Drift voice costs about 2.4 us per 64-frame period at 96 kHz (32
  voices: 11 % of the period), about six times a Segno patch voice. The
  console's run sets the device's default voice limit (a hardware gate).

## November 2026 Instrument buses are stereo (SEG-109 P1)

- An instrument slot's bus is a stereo pair now, so Drift's Stereo and
  Unison modes can reach the rig as Live plays them (plan:
  `docs/plan/2026-11-25-feat-ableton-drift-plan.md`). The 19 Segno patches
  are mono: the synth renders the left plane and the right plane carries
  the same samples, so every patch sounds and records exactly as before.
- What feeds a chain or an output takes both channels: the input chain
  (`le_fx_monitor_job`), a monitor with no chain, the heard image where
  there is no chain, and the heard tail's ring, which keeps an instrument's
  right channel in a second buffer so a take's rendered tail starts from
  both channels. That buffer is as large as the ring (2^21 floats, 8 MB at
  96 kHz) and is mapped only for an instrument source a lane holding an
  image records. A sound-start take arms on the louder channel.
- What records one channel takes the mono sum (L + R) / 2: the clean take
  and the raw performance tap (#1805). Equal channels give that channel
  exactly, so a patch's clean take is bit-identical to the mono bus's.
- Known limit: re-running effects from the clean take (an edit, SEG-50's
  replay) starts from the mono sum, so it loses an instrument's own stereo
  spread. The heard image, which plays by default, keeps it.

## November 2026 A save of loops with unrelated lengths no longer runs out of memory (SEG-107)

- On the console (build 293), Save As from Power options failed with `Out of
  Memory`, and so, without a word, did the pedal's two session saves after
  it. The rig was in Song mode, with tracks of 453,792 and 435,680 frames.
  The mixdown sums every lane over the LCM of their lengths, and those two
  share only 32: 6,178,378,080 frames, a 24.7 GB `Float32List`. The layers
  and the manifest are written before the mixdown, so each bundle looked
  complete but has no `mixdown.wav`.
- When the LCM is longer than any loop can be (`kMaxLoopSeconds`, 600 s at
  the session's rate), the mixdown now spans the longest lane and the shorter
  ones repeat within it. Rigs on one clock keep their LCM.
- The capture refuses a track length or layer image longer than 600 s at
  the session's rate, naming it, before anything is written.
- `SessionCubit` logs a save's own error and stack at E level before it
  wraps them as `saveFailed`.

## November 2026 A Retry after a failed Save As saves under its name (SEG-106)

- On the console (build 293), a Save As from the power flow failed with
  Out of Memory (SEG-107) after its manifest had landed, and every Retry
  was refused with `a session named "e4t4eg4g" already exists`: the failed
  attempt's own bundle held the name.
- A new bundle's save is all or nothing now, as a Duplicate's copy is:
  when any step after the reservation fails (the write, the mixdown, the
  catalog re-list), `releaseSessionId` removes the reserved directory with
  whatever that save wrote. The live rig still holds it all, the banner's
  "Nothing was changed" is true, and a Retry under the same name saves.
  This covers Save As, an automatic-name save and an Open's preservation of
  an unnamed rig. The sheet still refuses another session's name.

## November 2026 The power panel closes showing what it showed (SEG-100)

- On the console (build 291), Keep playing on the update refusal showed
  Power options for the half second the panel took to close. The panel
  drew Power options for every phase but the refusal and Segno is staying
  on, including `idle`, the phase the host closes it on.
- The panel's body now follows only the phases it shows
  (`PowerState.shownInPanel`: refuse, options, save failed). A refusal
  closes as the refusal, and Segno is staying on closes as itself on Stay
  on and on a Retry whose save runs. The panel's own pointer guard went
  with it: a closing route already ignores pointers.

## November 2026 A note sung from silence no longer clicks through PSOLA (SEG-98)

- The owner heard clicks singing through Smart Tune on the console (48 kHz /
  32). The Scarlett stayed on the bus and `bench_rt_faults` was clean, so it
  was the effect itself.
- PSOLA plays the delay-matched dry until it hears a pitch, then crossfades
  to its grains. The crossfade's weight came from the voicing, which moves
  only when a detection finishes, so it could go from dry to most of the
  grains in one sample. The grains are not in phase with the dry, and the
  output stepped by up to half the voice's peak 35-45 ms into the note.
- The crossfade now follows the voicing's gate in 10 ms a sample
  (`le_psola_tick`, `le_octaver_state.gate`), as the Dual Octaver's low
  band already did. Only what runs PSOLA changes: Smart Tune, and the
  Octaver kind with its mode at PSOLA. Pitch Shift and the Whammy run the
  phase vocoder and render bit for bit as before. Held notes, vibrato and
  slides render as before; only the first tens of milliseconds of a note
  change.
- `test_smart_tune_onset_from_silence_no_step` pins it: six voice-like notes
  from silence, each note's largest second difference in its first 100 ms
  under twice the input's (0.010-0.012 against 0.012 now; 0.041-0.148 before).
- The pitch oracle's frozen kernels (`pitch_ref.c`) take the same change,
  and `smarttune` is in `bench_fx_equiv.c`'s `k_moved`.
- On the console (build 293, 2026-11-24) a note from silence no longer
  clicks: Chromatic at 1 ms by ear, and none of the five onsets of a sung
  Min Triad take at 1 ms has a burst. Min Triad at 1 ms still clicks where
  the target note changes and on a held note sung off its target; that is
  another cause, tracked in SEG-103.

## November 2026 September takes ship their captured master (SEG-76, #1855)

- A take armed before capture destinations (#1853, the console's September
  takes) was captured after the master gain and limiter, and its lanes'
  output routes are in no take file (a lane routed to no output on 13
  September was set before the arm). No master rebuilt from its lanes can
  match the captured one.
- The renderer (`perf_render.c`) writes no `stems/wet/master.wav` for such a
  take, and sums no lane into a master; its lane stems and index are
  rendered as before, and a re-render removes a rebuilt master an earlier
  build wrote. The DAW package and Segno Transfer, which copy every WAV in a
  take, carry the captured `master.wav` alone.
- A September take a build with #1854 already rendered keeps its stems and
  is not rendered again, so its wrong `stems/wet/master.wav` stays on disk
  until it is deleted by hand (no startup migration, per the engineering
  principles).
- Not checked on the console: a September take's DAW package after the
  update.

## November 2026 A lane added after a take has the track's length (SEG-69, #1825)

- A lane added to a track that holds a take (`le_engine_set_lane_count`
  while it plays) kept a length of 0: a pass wrote it and the callback
  played it, but `le_engine_export_track_lane` returned no frames, so the
  performance snapshots skipped it and what its last pass added was not in a
  capture's stems. The callback now gives each lane it activates on such a
  track lane 0's length when it publishes the count (`le_apply_routing`), as
  every lane of a track has it. An empty track's lanes keep 0.
- The renderer no longer keeps what an unlisted lane played before the last
  pass: every lane with a take is in the disarm snapshot, and an unlisted
  lane reads as silence. `test_added_lane_takes_track_length` and the lane
  stems test, whose last pass now writes the added lane, prove it.
- The trailing-lane trim reads `a_recoverable`, not the length, so it still
  removes an added lane that holds nothing. A session save exports the added
  lane's live image now, but still drops the lane when the track's history
  was made partly before the lane joined: some history slots have no buffer
  for the lane, so `exportLayer` returns nothing for them and the save drops
  the lane as torn. Undo into those images has the same gap. Left for a
  follow-up.

## November 2026 CI fails a firmware change that keeps the board's version (#1969)

- The boot flashers flash a board only when its version differs from the
  image's, so #1967's pill fix shipped in build .289 under 2.7 and stayed
  off the board until #1968 raised it to 2.8.
- `tool/check_firmware_version_bump.dart`, in the `analyze` job on every
  pull request and master push: a change under
  `firmware/console_board` or `firmware/ring_board` must raise that board's
  `FW_MAJOR.FW_MINOR`, and one under `firmware/libraries` both. Markdown,
  the console's `pi5-swd.cfg` and C/C++ edits to comments or whitespace
  only are exempt. Rule and exemptions: `firmware/console_board/README.md`,
  "Firmware versions"; tests: `test/tool/check_firmware_version_bump_test.dart`.
- Run over master's first-parent commits that touch the board sources, it
  flags #1967 (195b9d463) and three earlier changes that kept the version
  (15e0db4f1, be5712811, the #1534 merge e995e79de), and passes #1968 and
  the README-only commits. History has no comment-only C/C++ commit; the
  comment exemption is covered by the unit tests only.
- On a pull request it compares the merge commit with HEAD^1; on a push to
  master, with the commit master was on before the push. Arduino core and
  library pin changes are outside `firmware/` and need a manual bump.

## November 2026 A recording take shows its input, waveform, progress and bars (#1936)

- Plan: `docs/plan/2026-11-21-feat-recording-visuals-plan.md` (decisions
  D1 to D6 approved as recommended on 2026-11-21; "As built" lists the
  departures). Five stacked PRs, #1938 to the one closing #1936, each with
  its design half on Penpot pages 05 and 25 (segno-design #28 to #32).
- A track meters its input while it records, and while it is the empty
  track Record/Play records next; the input bar of an empty track is grey
  (`TrackLevels.input`, the lanes' inputs after trim). An overdubbing track
  meters the louder of its playback and its input (`MeterSource.both`), and
  its waveform draws each bucket from the sample the overdub writes, the
  loop and the new layer together, on the pass it records (#1955,
  segno-design#35).
- The engine publishes each recording take's captured frames and its
  target (`capture_frames`, `capture_target_frames`): the progress bar
  fills toward a known end, and the bars slot reads `2 / 4` bars, `3` bars,
  or `0:07` with no grid, in the Tracks and Wave views and on the readout.
- A recording take draws its waveform as it records (`le_capture_viz_tap`:
  per block, toward the target or compressing as a free take grows) and is
  mapped onto the loop when it closes, so the first lap has its shape.
- A free first take's bar count comes from its beat: aubio 0.4.9 (vendored,
  `third_party/aubio`) computes spectral flux on an analysis worker
  (`engine_analysis.c`); at the take's end the power-of-two bar count (1 to
  64) with a tempo in 60 to 200 BPM whose beat the onsets clearly repeat at
  wins. Without a clear beat, the length's reading stands: the power of two
  nearest 120 in that window (`le_grid_derive_bpm`, which no longer picks
  any whole count first), else any whole count nearest 120. The app shows
  no tempo for the few milliseconds the analysis takes. ÷2 / ×2
  (`LE_CMD_SCALE_LOOP_BARS`, 146) read a derived loop as half or twice its
  bars, on Tempo & click and the readout's Loop panel.
- While a free take records, `≈ N bars` follows the time once the analysis
  has been sure of a steady tempo for two seconds.
- Not checked on the console: the worker's CPU, the callback's added copy,
  and the bar choice on real guitar and voice takes.

## November 2026 Custom controls start with a default map (#1908)

- A console that has never saved a pedal setup loads `PedalSetup.fresh`: the
  accepted Track controls and `PedalSetup.defaultCustom`, the map Penpot
  page 10 draws with the actions this build lacks replaced. Bank A: Record /
  Play; Stop; Undo, Hold Redo; Clear as Mute, Hold Clear all; 1 Reverse; 2
  FX, Hold Tuner; 3 Fade, Hold Peel; 4 Mixer, Hold Record performance. Bank
  B changes the track switches: 1 Tap tempo; 2 FX, Hold Fade; 3 Multiply,
  Hold Divide; 4 Peel, Hold Undo.
- Record / Play and Stop carry no Hold, so both act on contact: a Custom
  switch with a Hold moves its Press to the release.
- That first boot stores the setup (the owner's call, 2026-11-20), so a
  later build with another default does not change the map a console
  already plays; `Use default assignments` gives the build's current
  default. If the write is refused the default still plays, and the next
  boot stores it. The fresh install's FX Stop notice decision (#1229) is
  stored in the same boot, no longer at its first FX entry or save.
- A stored setup is taken as it is, an empty Custom map included.
  `PedalSetup()` stays the setup with nothing on Custom.
- Settings > Pedals > Custom controls: the Clear custom assignments dialog
  has a second action, `Use default assignments`. It replaces the draft's
  Custom map; Restore puts back the map from before the latest Clear or
  default; nothing reaches the rig until Save. The titlebar button is
  always available in Custom controls, and each dialog action dims when it
  has nothing to do.
- The one-time `Hold · Tuner` seed on Custom pedal 2 (#1229, D11) is
  removed with its settings flag, state field and notice: the default map
  carries that Hold.
- An install that already saved a setup keeps its map until the owner uses
  `Use default assignments`.
- Design: Penpot pages 08 and 10. The snapshot is on segno-design's main
  (`c17df0c8c`): the Sessions exports were taken after these edits and
  carry them, so segno-design#24 was closed with nothing left to merge.
- Not checked on the console: the foot feel of each default assignment.
- When Transpose and Speed ship (#1179), pedal 1 in bank A returns to
  Transpose, Hold Reverse and the Hold on pedal 4 to Speed. Sessions by
  foot (#1910) are not in the default map.

## November 2026 Page transitions without the allocation burst (#1914 part 5)

- The screen changes' late periods were the page transition's first frames,
  on the transitions to and from the stage. The fade (`FadeTransition` over
  the page) needs an offscreen pass. Impeller on GLES gives one explicit 4x
  MSAA (the V3D in Mesa 25.1.6 has no `GL_EXT_multisampled_render_to_texture`):
  about 73 MB at 1080p, in `bo_stats` of the v3d debugfs.
- Impeller drops the target 4 frames after the fade, and Mesa's v3d BO cache
  frees it 2 s later, so each transition after a pause allocated it again.
  The kernel zeroing its pages stalls the memory bus. In the app, transitions
  that reused it had no late period (14 of 14); transitions that re-created
  it had 0 to 9 each (30 in 16).
- The owner keeps the transition as it looks. Mesa's v3d BO cache now keeps
  BOs of 4 MB or more until the large ones cached pass 256 MB, the oldest
  going first, instead of for 2 s (`recipes-graphics/mesa`). With the
  patched driver on the console (a 300 s version, measured), only the first
  transition after the app starts allocated (2 late periods). The 15 after
  it reused the target and had none, and the screen changes past 77 % of the
  deadline went from 242-272 a run to 48-71.
- The first one too: right after its first frame the main screen draws one
  invisible full-screen offscreen pass (`OffscreenPassWarmup`), so the
  target is made at startup and every transition finds it cached.
- Measured alternatives, for the record: the same fade at 100 ms (no
  better), drawn from snapshots (worse: they allocate too), scale only and
  scale under a fading scrim (as cheap as instant, but the owner keeps the
  dissolve).
## November 2026 A heard lane nothing reaches goes to its target at once (#1914 part 6)

- Part 4 started a recording take's heard lane on its image, but in the
  app the 2-lane take still spent 254-260 us of its start block, and 60-180
  us a block for 10 ms after, in `le_heard_lane_wet`. The rig follows
  tempo, so a new take plays through a stretch render that lands a few
  blocks after it starts. Until it does, the lane's target is its clean
  take, and the lane faded 1 to 0 and back, running its whole chain on the
  callback frame by frame.
- A heard lane nothing of reaches the outputs (`audible` false: a
  recording track plays nothing, a stopped one has rung out, a muted one is
  gated) now goes to its target at once. An audible lane still fades
  (`test_heard_inaudible_lane_snaps`).
- Console, profiled, two runs of four takes: the 2-lane take's start block
  went from 870-892 us to 551-658 us, the heard lanes' time in it from
  254-260 us to 12-14 us. No take start had a period past the deadline in
  its 40 ms (1 to 3 a run before); the worst there was 573-658 us.

## November 2026 A recording take's heard lane starts on its image (#1914 part 4)

- A lane that got its first heard image (#1713) faded to it over 10 ms
  from its clean take. That ran the lane's whole rack, Pre and Post, on
  the callback, frame by frame, from cold, in the blocks a take starts in.
  On the console it cost 105 to 344 us in the start block and 65 to 180 us
  in each block after.
- Nothing of a recording track plays (its play gain is 0), so the fade
  blended silence with the Pre run of silence. The one thing it could
  reach the route with was a Pre-run noise kind's 10 ms through the Post
  entries.
- The owner chose to start such a lane on its image, as the performance
  render's take already did (`test_heard_take_starts_on_its_image`). A
  lane that gets an image while its track plays still fades.
- In the app (master's app, three runs each), take-start late periods went
  from 2, 3, 2 a run to 1, 1, 2. The callbacks over 513 us in a take's
  window went from 963-1124 to 166-218.

## November 2026 What is left of the callback's late periods (#1914 part 3)

- The bar from the engine's own counters (`le_cb_timing`, no profiler):
  Ed's Rack on 4 inputs + 6 tracks, four takes, 60 s, the screen changes,
  60 s. On master's engine steady playback has no late period (30 runs).
  The take starts give 2 to 4 a run, and the screen changes 0 to 5 on
  master's app (34 to 57 on build 279's).
- The screen changes' are the page transition: with it off, 0 late periods
  in 6 runs and a tenth of the near-misses. Painting the incoming page from
  a snapshot does not help (the stage under it still draws every frame),
  and neither does the UI on core 0 alone. Turning the transition off is
  the owner's call.
- A take start pays for its heard lanes (#1713): their frozen racks land
  (the recipe apply), their oversamplers design, the octaver compares its
  channels, and for the 8 to 10 ms of the lane's crossfade to its image
  the callback runs the lane's whole rack, Pre and Post, frame by frame
  and cold: 105 to 344 us in the start block, 65 to 180 us a block after.
  A 2-lane take pays it twice.
- The oversamplers' designs are now made once a rate (a lock-free memo of
  `le_os_coefs`, bit-identical; `test_drive_design_made_once`): 22 to 54 us
  of libm at each take start down to 1 to 5.
- The crossfade at a take start blends silence (a recording track's play
  gain is 0) with the Pre run of silence. The owner chose to start a
  recording take's lane on its image, as the performance render already
  does (part 4, above).
- Part 2's narrowed octaver clear read a ring's pointer before checking
  that the ring was readable, a race with the control thread allocating
  one for a coming retype (#1522) that TSan's workers race test caught.
  The check comes first again.

## November 2026 Sessions by foot (#1910, #1921)

- **Sessions** is a performance function (`InteractionMode.sessions`,
  `mode:sessions`), assignable to a Custom switch, an external pedal or a
  MIDI control. The owner chose it over `Load previous session` and `Load
  next session`, which are not built (plan
  `docs/plan/2026-11-19-feat-foot-session-actions-plan.md`).
- **The face lists every saved session** the player did not hide, whatever
  folder it is in, four to a page, in name order: ignoring case, with
  digits compared as numbers (`compareSessionNames`, `footSessionsListed`,
  `lib/control/model/foot_sessions.dart`). The Library still lists newest
  first: that order moves each time an Open saves the session it leaves.
  The owner chose this list over a map of sessions to switches, which was
  built and withdrawn before it was committed (plan
  `docs/plan/2026-11-20-feat-sessions-face-map-preview-hold-plan.md`,
  "Owner decisions on the list"). An order set by hand is not built.
- **A press shows a session and a Hold opens it** (#1921). The press shows
  it at once in a readout above the track switches, drawn like the Mixer's:
  its loop mode, tempo, loop length, recorded tracks and effects, read from
  the manifest by `SessionPreviewCubit` with no audio. The Hold fills the
  switch's LED left to right in the `selected` colour, through the `STATE`
  frame's `queuedButton` and `queuedProgress`, so the firmware and the link
  did not change. One Hold at a time. The open session's switch shows it
  and has no Hold.
- **The other switches.** Clear is Previous page and Bank is Next page,
  both on contact, both wrapping. Undo saves on its release and starts a
  new session on a Hold, with the clearing Hold's fill. Rec/Play and Stop
  keep the transport. MODE goes back to the mode the face was entered
  from.
- The face says what an Open would end (`Opening a session stops
  playback`, `... ends the take`, `... ends the recording`) before any
  press. There is no second press: the Hold is the confirmation. A failed
  Open keeps the face, marks its switch and is named in the stage notice.
- **A session can be hidden from the pedal.** Each row of the Library's
  list has a three-dot button; its sheet says `Hide from pedal` or `Show on
  pedal`. The ids are in `sessions-face.json` beside the bundles
  (`SessionRepository.readHiddenFromFace`), in `SessionState.hiddenFromFace`
  and set with `SessionCubit.setShownOnFace`. A hidden session is on no
  switch; when it is the open one the face's readout names it.
- `New session` (`command:new-loop`, #1229 Part 7; renamed from `New loop`
  in #1927) and `Save session` (`session:save`) are commands in the
  Sessions group of the catalogue.
- `ControlCubit` owns the face and never reads `SessionCubit`. Four
  injected functions reach the session layer (`startNewLoop`,
  `saveSession`, `openSession`, `refreshSessions`, wired in `AppRuntime`),
  and the catalogue comes back through `ControlCubit.setSessionCatalogue`,
  which a listener in `app.dart` calls on every session state change. A
  hidden session is handed over too, marked `onFace: false`.
- A performance recording that an Open or a New session ends is finalized
  through `PerformanceRepository.disarmForSessionChange()`. The stage says
  `Recording saved` and opens no completion sheet over the new session; a
  take that did not come out whole, or dropped frames, still opens it.
- An Open and a New session end a Library Listen preview themselves,
  whoever asked (`SessionCubit._endListen`).
- The stage notices name the session: `<name> opened`, and `Could not open
  <name>` with the reason.
- The mode is `PedalMode.custom` on the pedal link, like the Tuner, so the
  firmware did not change. It is not stored, so it is never a boot mode.
- Adding an `InteractionMode` member needs a case in about twenty
  switches; the analyzer lists them.
- `bloc lint` finds no files when run inside `.claude/worktrees/`: run it
  on a copy outside a hidden folder.
- The design is Penpot page `19 Sessions · New session & recall`
  (tomassasovsky/segno-design#25, #26 and #27 there).
- Owed: the console checks (#1918): how long an Open takes, how long the
  readout's list takes to appear after a press, whether the fill reads from
  standing height, and the missing end-to-end test of an Open from the
  face.

## November 2026 Take starts lighter on the memory bus (#1914 part 2)

- What a take start does, measured in the app (Ed's Rack on 4 inputs + 6
  tracks, the profiled engine, every thread sampled each millisecond): the
  press faults the take's first second in, then the prefaulter raced 4 s
  ahead at gigabytes a second; the callback's first block applied the
  lanes' frozen recipes, zeroing the Dual Octaver's two 1 s rings (375 KB)
  and starting the lanes' racks cold; the main view's UI thread ran 20-30 ms
  at about 80 %. The engine alone (`bench_take_start`, no sound card) pays
  about 180 us in that block, and nothing a block afterwards.
- The prefaulter now paces itself (64 MB/s, more with many follow jobs, so
  each still runs 8x its write head), and while a take's follow job is
  behind only the follow jobs run (`test_prefaulter_paces_and_follows_first`).
  The octaver family clears only the `LE_OCT_REACH` of its rings it can read
  (14 KB a channel instead of 188); the next kind on the slot clears the
  rings it reads as it lands.
- In the app, four takes a run, three A/B pairs on one boot each: periods
  past the deadline in the 60 ms after each record press 12 a run (mean of
  six master runs) to 5, the worst there 1027-1359 us to 948-1005.
- Screen changes (Settings, the Device page, back) each give a few late
  periods, with every section of the callback slower: the UI's bursts while
  a page changes, not the Device page's polling and not engine work.

## November 2026 The octaver family on a mono pair (#1914 part 1)

- Where the app's callback time goes, measured with a section profiler
  built into the engine (`src/core/engine_prof.h`, only with
  `-DLE_PROFILE_SECTIONS=1`; read with `tool/engine_prof/proftel.py` and
  `profan.py`, no tracing). The callback takes no page faults and is almost
  never preempted. It waits on memory: ten of Ed's Racks hold more state than
  the Pi 5's caches (512 KB L2 a core, 2 MB L3), so the effects read about
  0.5 MB a period from DRAM, and every other user of the memory bus slows
  them (one thread streaming memory on core 0 made the bench's callback 1.8x
  slower). The UI's Flutter threads are around 97 % of the slow periods; the
  displays' scanout costs nothing measurable.
- The Dual Octaver is 92 % of those misses (10 racks, two workers: 350 MB/s
  with it, 30 without). On a mono pair (a monitored input; a track whose
  lanes are mono and centred) the octaver family now runs its left channel
  alone and copies it to the right (`le_oct_run_pair`, `le_fx_state.oct_mono`):
  its kernel treats the channels alike, so the output is the stereo path's
  bit for bit (`test_octaver_mono_pair_matches_stereo`). It tries once a
  landing, only when the two channels' states are equal; a stereo sample
  brings the right's state up to the left's. Not Smart Tune (its tick reads
  both channels), nor away from 48 kHz.
- Console, 10 of Ed's Racks in `bench_fx_parallel`: DRAM misses 295-322 to
  127-140 MB/s, p50 312 to 275 us, p99 327 to 284. In the app (Ed's Rack on
  4 inputs + 6 tracks, four takes recorded and the Device page opened three
  times in each window, A/B on one boot): effects jobs 74 to 68 us, service
  p50 420 to 398, p99 552 to 524, periods past the 77 % share 70 % fewer,
  periods past the deadline 126 to 97. The four tracks playing takes stay
  stereo (their heard image is the rack's stereo output).
- Still late: the take start (the press prefaults the take's first seconds)
  and the screen change. Next parts of #1914.

## November 2026 The effects budget from the app (#1724)

- The bar (the owner's): no dropout over ten minutes in the app, nothing
  traced, four takes playing on the stage, a take recorded at 2 and 7.5
  minutes and a screen change (Settings, the Device page, back) at 5; the
  budget admits one rig fewer than the heaviest that passes. Dropouts and
  late periods are the engine's own counters, read from the app's memory.
- Tracing `sched_switch` on every core made periods late (Ed's Racks on 4
  inputs and 6 tracks: 7 traced, 0 untraced), and so does opening a screen:
  the Device page added 14 late periods at 4 + 6.
- Build 279, 48 kHz / 32, two workers, Ed's Rack on the four inputs and:
  7 tracks, no dropout (40 late); 8 tracks, none (144 late); 3 racks in
  series on output pair 0, 1 dropout at the screen change (318 late);
  6 tracks and 1 output rack, 1 at the screen change (309 late); 2 output
  racks, none (11 late).
- `kFxTrackJobNs` 200 → 300 ns (7 tracks admitted, 8 refused) and
  `kFxSerialFactor` 2.5 on All tracks and the outputs (1 output rack
  admitted, 2 refused). The share stays 77 %. Only 48 kHz / 32 was run;
  96 kHz / 64 is next, and #1914 (the app's extra time on the callback)
  should raise both figures, after which the ladder runs again.

## November 2026 The track-job charge from clean console runs (#1724)

- #1724's and #1729's console runs sampled the sound card's status from
  `/proc/asound` once a second while they measured, which takes the lock the
  callback's ALSA calls need (a sleeping lock on PREEMPT_RT), and resized the
  trace ring as each window began. The callback's long services lined up
  with both. Measured without either (ftrace set up before the bench starts,
  only `tracing_on` flipped), the rigs those runs failed ran clean.
- Console (build 278, 48 kHz / 32, two workers, `bench_rt_faults` from
  master 6115156ad, 120 s each): Ed's Racks on 4 inputs and 6, 7 or 8
  tracks, no late period and no xrun (worst 542, 531, 579 us of 666);
  4 inputs, 6 tracks and 1 on the output, clean (632 us); 4, 8 and 1, 2 late.
  On the output beside the four inputs: 3 racks clean (636 us), 4 with 17
  late, 5 with 3046.
- `kFxTrackJobNs` 500 → 200 ns a frame. At 48 kHz / 32 with two workers,
  racks fit on all 4 inputs and all 8 tracks (6 before), and 6 tracks beside
  an output rack (4 before). The share (77 %) and the serial charges stand.
- In the app (4 inputs and 6 tracks racked, four takes playing): per-period
  p99.9 579 us against the bench's 452 for the same rig; no dropout in six
  untraced minutes on the stage. The app at the new 8-track limit is not
  measured: build 278 holds what today's rule refuses.

## November 2026 The stage's CPU figure reads the real load (#1868)

- An idle console read 0-2% on the stage with jumps to 10-16% every 4.4 s;
  its real idle load is a steady 9-10% (audio callback 15% of core 3, the
  USB interrupt thread 10% of core 0, each effects worker 4%, the UI 3%).
- Cause: `CpuLoadRepository` took busy over total from `/proc/stat`. The
  kernel (6.12 PREEMPT_RT, NO_HZ idle) samples the busy fields at the tick,
  which misses the audio callback and credits the USB interrupt thread's
  time to core 0 in one lump every 4.43 s.
- Now: load = 1 - (idle + iowait) / (elapsed x online cores), with idle and
  iowait from `/proc/stat` (measured as each core enters and leaves idle)
  and elapsed time from `/proc/uptime`. Checked side by side on the console
  in shell before the change; the built app is not yet checked on the
  console.

## November 2026 Lane chains sleep on empty tracks (#1870)

- A lane chain on an EMPTY track stops running once its output has stayed
  under `LE_FX_DRAIN_FLOOR` for its whole tail (`le_lane_chain_sleeps` in
  `engine_process.c`, `le_fx_chain_quiet_frames` in `engine_fx.c`): 50 ms
  plus the drain horizon of every entry that holds a tail, summed. The track
  then takes the idle skip and needs no job. Counted only while the track is
  EMPTY, so a Clear's Post tail drains first. A chain with a hosted plugin
  never sleeps.
- It runs again, from its own state, when the track leaves EMPTY or the
  chain is edited (`a_fx_gen`). A take recorded after a sleep plays exactly
  as one through a chain kept awake (`test_engine_lane_chain_sleep.h`).
  `le_fx_state.out_loud`, set by `le_fx_note_output` where a lane's chain
  runs (the mixer, the track job, the lane flush) on a frame at or over the
  floor, is what the snapshot reads; the horizon is computed once per chain
  edit.
- Monitor chains are untouched, so the first note played is never clipped.
- Why the engine and not the app: the app keeps an inherited chain on a
  track undone back to empty for Redo, and a Clear's Post tail drains
  through the chain.
- Console (Pi 5, 48 kHz / 32, idle stage, four empty tracks, the rig's
  three inherited lane chains): `segno-audio` 99.3 → 75.5 µs a period, each
  fx worker 26 → 10.5 µs and woken every other period; total 150.8 → 96.6.

## November 2026 The network stack is Raspberry Pi OS's (#1843)

- NetworkManager drives the radio through wpa_supplicant, as on Raspberry Pi
  OS, instead of iwd (#470). docs/NETWORK_PARITY.md lists every network
  piece of Pi OS trixie against the image, with sources, and the reason for
  each difference; `run_network_config_tests.sh` checks the layer against
  it, and `deploy/rpi/verify-network-on-device.sh` checks a console.
- From Pi OS, word for word: Debian's `NetworkManager.conf`,
  `wpa_supplicant.service` (`-u -s -O "DIR=/run/wpa_supplicant
  GROUP=netdev"`, enabled), its D-Bus activation file and policy, the
  `netdev` group, `no-mac-addr-change.conf`, raspberrypi-net-mods'
  `rpi-no-scan-rand-mac-address.conf`, raspberrypi-sys-mods'
  `rfkill_default.conf`, and the regulatory domain as raspi-config sets it,
  `cfg80211.ieee80211_regdom=AR` on the kernel command line. wpa_supplicant
  is built with Debian's options except PCSC (and the SIM EAP methods),
  readline and eapol_test. dnsmasq.service is not enabled (Pi OS ships only the
  program) and Avahi publishes the workstation, as pi-gen sets it.
- Removed: the iwd backend and everything only iwd needed
  (`iwd-main.conf`, `segno-iwd-tame`, `wifi.iwd.autoconnect`, the
  wpa_supplicant mask), `segno-wifi-regdom` and `/etc/segno/wifi-country`,
  the old `99-segno-wifi.conf`, `segno-wifi-ctl`'s repair of pre-#468
  consoles and its `iw` power-save call. `PACKAGE_EXCLUDE += "iwd"`.
- Kept, as deviations: saved networks on `/data` (`keyfile.path`, the same
  directory as before, so they carry over), NetworkManager's state bound
  from `/data/NetworkManager/state`, power save off (raspi-config's own
  "disabled" file), and `segno-wifi-retry`, because a headless console has
  no secret agent to answer NetworkManager after a failure it ends as
  `no-secrets`.
- `segno-wifi-ctl connect` reads wpa_supplicant's lines for the attempt:
  `wrong-password` only after "WPA: 4-Way Handshake failed - pre-shared key
  may be incorrect", and only for a key that has not connected on that
  profile (#1816); `CTRL-EVENT-ASSOC-REJECT status_code=16` (#1816) and
  "Authentication with ... timed out." (#470) are `no-connection`.
- Still different: systemd-resolved instead of NetworkManager writing
  `/etc/resolv.conf` (#1849, which needs a test image).
- Not built in CI: the image needs an appliance-release run, then
  `verify-network-on-device.sh` on the console.

## November 2026 Effect switching and setting changes as Live automation (#1836)

Part 6 of #1806 (decisions D4 to D6): the Live set replays what changed in
a take's chains, where it used to hold each effect as it stood at arm.

- `ChainTimeline` (`packages/daw_export/lib/src/chain_timeline.dart`) reads
  `events.log` for each lane's chain and each input's monitor chain and
  replays it as the offline render replays the lane's wet stem
  (`le_pr_wet_render`): an entry's switch (310, 312) and the chain's (311,
  313), each setting (306, 307), each type (20, 31: an actual change puts
  the new effect at its defaults and on, as the setter does unlogged) and
  the chain's length (21, 32: a slot past it is not run, one entering it
  comes on). Entries at one frame all apply before it plays; the two log
  streams are merged in frame order, ties in file order
  (`EventLogReader.sortedByFrame`, as `le_pr_frame_cmp`).
- Every change is a step in a device envelope, two events at the beat of
  its frame, the value before and the value after, as Live draws a step.
  Nothing is thinned: the console logs a setting at most once a block, when
  it moves, and an entry's switch once a press. A switch is automation of
  the plugin's Enabled; a setting of its parameter, normalized, as Live
  keeps a setting that is not a list (in steps only for the input, the
  output and Enabled). A rack switch or an A/B press is its entries'
  switches (D5), so racks stay on. A slot whose effect changed holds one
  plugin per effect, side by side, each on while the slot held it (D6). A
  Dub Rack's Amb / Dub section is on while any entry of the rack runs (the
  engine fades the section to its input when none does). Every envelope
  sits on its track, a device in a rack included; the track shows its
  volume lane or its first device envelope.
- The plugin's 1100 is now **Enabled**, an ordinary automatable parameter
  (Off / On, default On), not the VST3 bypass: Live lists no bypass
  parameter, and its Device On stops the plugin, cutting a delay's echoes
  and freezing its line until it comes back on (the owner's check of
  `test/corpus/plugin_automation.als`, Live 12.2.7). Enabled runs the
  engine's switch for every kind: the 5 ms ramp, a delay's or a reverb's
  drain, a fresh start on a re-enable from a settled switch-off, and for a
  kind that delays its output its warm-up and, while off, its input
  without the delay. The plugin used
  to switch such a kind to its input delayed by its latency. The pedal's
  footswitch and LED drive Enabled; an exported device stays on in Live.
- Every plugin reports no latency (owner call, reversing #1804 part 2's
  reported latency and its padding to the largest at any rate). The console
  compensates no effect's latency: a kind that delays its output plays
  late by it while on and on time while off. The Octaver, Dual octaver,
  Whammy and Smart Tune delay theirs by 1188 to 2568 frames from 44.1 to
  96 kHz (about 25 ms); the Amp, Overdrive, Distortion, Vinyl, LPF and
  Degrade by 2 to 27 frames at some rates (the null test prints each). Unreported, Live plays each lane exactly as the console
  did in both states, and a render nulls against "as heard" at offset 0
  for every chain. A plugin added by hand in Live behaves the same: the
  octaver family sounds about 25 ms late while on, uncompensated. The
  tail a plugin reports is still its delay, the largest at any of those
  rates, since a host may not ask again when it renders at another.
- When the host starts playing, the values it sets at the block's first
  frame land before the plugin starts again as at arm, so a plugin
  automated off at the start starts settled off.
- The null test (`vst3/test/null_test.cpp`) switches through Enabled on a
  block boundary and inside a block, off and on again 1 ms apart (inside
  the ramp), and from an entry off at arm that the host turns on; at 44.1,
  48, 88.2 and 96 kHz, every kind is bit-identical to the engine's offline
  render at lag 0, the latency-bearing kinds included, and reports no
  latency: checked at 37-, 128- and 512-frame blocks here; CI runs
  128-frame blocks.
- `test/corpus/plugin_automation.als` is the reference Live saved (see the
  corpus README); `test/device_automation_test.dart` checks the writer
  against it and `test/fx_automation_end_to_end_test.dart` runs a synthetic
  capture with presses, an A/B switch, a replaced effect, knob moves and a
  monitor switch through to the set.
- Not reproduced: a switch's frame is the control thread's stamp, within a
  block of the one the console applied it at (the offline render and so the
  "as heard" stem use the same stamp; the block-tail observer of #1806 Part
  3 would make it exact); a type change crossfades over the ramp in Live
  and lets the old effect's tail drain, where the console swaps at once; a
  type set again to the same effect resets its state on the console only;
  a slot the chain's length leaves out stops at once on the console and
  comes back where it stopped, where in Live its Enabled goes off, so it
  ramps out and drains, and comes back fresh once settled;
  a Dub Rack switched off as a whole stops its section in Live, cutting the
  paths' tails, and a change of its Amb-Dub Mix is not replayed in the
  chains' volumes; chains published by a recipe and the Track and All
  tracks stages are not logged yet (#1806 Part 2).

## November 2026 Each Segno plugin draws its pedal (#1815)

- Each plugin's editor is the console's single-effect page in a plugin
  window: the pedal the Effects page draws for its kind, and beside it the
  settings the face has no knob for and every choice, drawn as the effect
  page draws them (sliders, a row of buttons, or a select), then the
  entry's input, output and balance or pan as the effect page's footer
  draws them, and its level as an effect page slider (the console shows a
  single effect's level nowhere). The panel takes a second column past
  seven controls. Every parameter but the bypass has exactly one control:
  a choice the face has a knob for is set by its selector, the knob only
  shows it. The kinds the
  console runs only in racks wear the look of the first catalogue module
  that runs on them; Distortion, which no factory rack builds, has no face
  and keeps the host's own controls.
- The art cannot drift from the console's: `test/vst3_faces` lays out and
  renders the faces with the console's own widgets
  (`lib/looper/view/fx/stomp`, `FxBuiltInParamControl`). The committed
  layout, `packages/segno_engine/vst3/faces/faces.json`, says where each
  control is, how it works and which parameter it drives;
  `vst3_faces_test.dart` fails when it no longer matches the drawing code
  (`--update-goldens` rewrites it). `install.sh` renders the pictures (a
  background, the LED lit, and each control at each of its settings, at 1x
  and 2x) with the `vst3_faces_render_<k>_test.dart` suites, a third of the
  faces each, side by side (#1771), and the build bundles them in
  `Contents/Resources/faces`; the pictures are build output, not tracked.
- The editor (`editor_mac.mm`) is an IPlugView holding an NSView, macOS
  only: it draws the pictures at the parameters' values, edits through the
  controller (beginEdit, performEdit, endEdit) so a host records
  automation, and redraws when the host changes a value. Knobs drag up and
  down (Shift for finer), sliders follow the pointer, a select opens a menu
  of the console's position names, the footswitch is the bypass and the LED
  shows it. Every value is printed all the time, in the effect page's mono
  face and colours (the manifest's theme, the font bundled with the
  pictures): a slider's at its readout, at the exact value; a knob's in a
  chip under its label (nudged, or beside the label, where under it does
  not fit) where every knob of the face has room clear of the knobs,
  labels, title, LED and footswitch (the chip may cover the face's
  painting, the owner's call), and otherwise as read-only rows at the top
  of the panel. The entry's level is "Output level" in the editor and the
  host: the console's name for it, Level, is also many effects' own
  setting. Selects and button
  rows show their position, the LED the bypass. Linux, and a bundle built
  without the pictures, open no editor.
- Every plugin's parameter text is the console's (`value_text.cpp`, a
  port of `fxParamValueText` and the footer's readouts), so a host's own
  parameter list reads "348 ms" and "1/8D". `vst3/test/value_texts.json`,
  which `vst3_faces_test.dart` writes from the Dart, holds the console's
  text for every parameter of every kind at 41 settings and each position.
- `test/binding_test.cpp` loads the bundle and checks every control of the
  layout against its plugin's parameters, that every parameter but the
  bypass has exactly one control, and every value text against
  `value_texts.json` (CI, in `run_null_test.sh`); after an install, also
  that every plugin with a face opens an editor of the layout's size.

## November 2026 Every lane of a track has its own stems (#1824)

- The performance render rendered lane 0 of each looper track only: what
  lanes 1 and up played during a take reached the Live set only as their
  last loop, a Session clip, though the master held it. `perf_render.c` now
  renders every lane to `stems/dry/track<c>-lane<l>.wav` and
  `stems/wet/track<c>-lane<l>.wav`, and the master from all of them. The
  track-level `track<c>.wav` stems are gone: the DAW export was their only
  reader. `stems/stems.json` lists the lane stems a render published
  (docs/formats/performance-manifest-format.md).
- The lanes share the track's transport, so each lane is rebuilt from the
  same facts (takes, overdub passes placed as #1813 places them, history
  images, fades, Reverse, Speed, Transpose) with its own images: lane `l` of
  each layer file and snapshot, silence where the lane held nothing of a
  take. Each lane's wet stem runs its own volume, pan, mute, output routing,
  chain, heard image and hop seed; the track gain, fade, solo and Cut apply
  to every lane, and the track-addressed mute and output mask to lane 0, as
  in the callback. The Track stage chain is still not replayed.
- Lanes added or removed during a take: the engine logs the lane count
  (`LE_CMD_SET_LANE_COUNT`, events.log version 17) for every track at the
  arm and whenever it applies, on the command path, and the renderer
  silences a lane at or past it. A version-16 capture has no count and
  renders every lane as mixed throughout. The engine removes only a lane
  that holds nothing, so the count matters for a lane's effect tail. A lane
  added after its track's take has the track's length (#1825, below), so
  the disarm snapshot exports what its last pass added.
- The Live set gives each looper track a Group track holding `<track> L<n>`
  (the lane's dry stem and clean loop through the lane's chain as Segno's
  plugins, playing, with its volume and mute as automation) and
  `<track> L<n> (as heard)` (its wet stem and loop as it played, off) for
  each lane. The Group carries the Track stage chain as plugins, where Live
  sums the lanes as the callback's track bus does. Lane loops sit in the
  first scene. Group tracks are copied from
  `test/corpus/group.als`, built from `automation.als` and the Group track of
  Live 12.2's own Podcast & Radio template; opening and saving it in Live is
  owed (the corpus README says how).
- A take with no stem index (rendered before this, or whose render failed)
  renders its stems first when the Library writes its DAW project or DAW
  package (`PerformanceRepository.renderStems`, with the export's progress
  and cancel), and `writeDawProject` never replaces a `project.als` with a
  set that has no stems: a failed render leaves it as it was. A lane whose
  wet render failed keeps its `L<n>` track with its plugins, and the take's
  render reports the track failed.
- A live-engine golden test (`test_engine_lane_stems.h`) records one track
  with four lanes, a delay and mute on one, two lanes added while it plays
  and one removed, and four overdub passes, then plays the take again with
  one input at a time: each lane's wet stem equals what that lane alone sent
  to the master, and the rendered master the captured one, within 1e-5.

## November 2026 A take records each input raw (#1805)

- A performance take recorded only the inputs monitored at arm, and only as
  their monitor played them (`mix_monitors_frame`): after its effects,
  volume and pan, and as silence while monitoring was off or muted, so an
  input played with monitoring off came out silent or not at all. Now every
  input the interface has (loopback channels aside) and every instrument
  with a patch at arm is also recorded raw, monitored or not: its clean
  sample, before the monitor's gate, chain, volume and pan, every frame
  while armed. The monitored inputs are still recorded as heard too.
- The audio thread pushes the raw samples once per block, out of the frame
  loop, in a cold function (`perf_tap_raw_block`), into one mono ring per
  input (`le_engine.perf_raw_ring`, `perf_raw_mask`, at the end of the
  struct so no field the mixer reads moves). A full ring drops the frame and
  counts an overrun, as the other taps do. A block with no input buffer
  records silence.
- The drain writes them as `input-raw-<n>-NNN.wav` parts, mono float,
  stream `100 + n` (`LE_PERF_RAW_STREAM_BASE`, a format constant). The
  sidecar lists them under `channel_layout.raw_inputs`, the parts in
  `parts`; the checkpoint lists the streams. Recovery, the Library's parts,
  the DAW package, Segno Transfer and the FAT32 cap test cover them. A raw
  input over the activity level counts as playing for the idle stop
  (#1767). `le_snapshot.perf_capture_frame_bytes` counts 4 bytes a frame
  per raw input. A monitor left on a loopback channel is not captured.
- The Live set gives each input `<name> raw`, switched on, and, when the
  input was monitored, `<name> (as heard)` beside it, switched off. A take
  from before #1805 keeps one input track as heard, switched on. The raw
  track is where a later layer of #1806 puts the monitor chain as plugins
  and the monitor volume, pan and mute as automation.

## November 2026 The Network page follows the console (#1817)

- On 2026-11-17 a WiFi 6 router timed out the 802.11 authentication (iwd
  `connect-failed, status: 16`, #1816), NetworkManager ended the join as
  `no-secrets`, and the page said "Incorrect password" for a key the access
  point never tested; the owner forgot two good networks over it.
- `segno-wifi-ctl connect` now prints why a join failed, `{"error":<code>}`:
  `wrong-password` only when iwd logged "4-Way handshake failed" during this
  attempt (the journal is read from the attempt's start, never a window that
  can hold another network's failure), `not-found`, `no-address`, and
  `no-connection` for everything else. NM's own reason is not read: on a
  console with no secret agent it ends every failed activation that asked
  for secrets as `no-secrets`. The app shows the code's words, names the
  network, and offers Try again (with the key that was typed) for everything
  but a wrong password, which goes back to the sheet.
- A join is checked against the scan first (the cached list, then one fresh
  scan), so a network out of range fails as `not-found` without dropping the
  one that is up.
- A failed join never deletes a saved network; only Forget does. A profile
  the helper made for a new network is removed when its join fails.
- Live state: `segno-wifi-ctl monitor` wraps `nmcli monitor` and prints one
  line per NetworkManager change. The app starts it once, with posix_spawn,
  when the page opens and kills it when the page closes, and re-reads
  `status` 300 ms after each burst. `status` says `connecting` while an
  activation is in flight, so a rejoin NetworkManager or `segno-wifi-retry`
  makes by itself shows as Connecting on the card. A long-lived nmcli
  rather than a D-Bus client in the app keeps NetworkManager behind the
  helper, like every other Wi-Fi call.
- While the page is open it scans every 10 s (quietly: no Scanning label,
  a failure stays on screen), skipping while the radio is off, a join runs
  or NM is joining; the list keeps its order between scans (saved, in range,
  signal bars, name). `scan` no longer switches the radio on.

## November 2026 The Live set plays the take through Segno's plugins (#1804 part 2)

- A looper track whose take recorded its chains (#1803 on) exports as its
  dry stem through those chains as Segno's plugins, under the track's
  name, with lane 0's clean loop as a Session clip, and the wet stem beside
  it as `<name> (as heard)`, off, with the heard loops and the other lanes'
  loops (they ran other chains). Takes without
  chains, or whose chains hold nothing Segno runs (only hosted plugins),
  keep the earlier layout.
- `devicesOfChain` (`packages/daw_export/lib/src/device_chain.dart`): lane
  0's chain, which the wet stem renders, then the track's Track stage. Each
  built-in effect becomes its plugin with the plugin's own state
  (`SegnoPluginState`, the bytes `segno_fx_state.h` reads): settings,
  channel handling, enable bit (the entry's, and off with its chain), chain
  slot, the owner's hop seed (`le_fx_lane_hop_seed`, `le_fx_bus_hop_seed`),
  and the take's PERF_ARMED FX clock and arm beat from `events.log`. A rack
  becomes an Audio Effect Rack named as the rack, off when it was; a Dub
  Rack's parallel Amb and Dub paths become a rack of two chains at the
  gains `fx_path_targets` gives the section's Amb-Dub Mix. Hosted plugins
  are left out, as the offline render passes them dry.
- The devices are copied from a set Live saved with Segno's plugins
  (`test/corpus/segno_vst3.als`, built in Live, through
  `lib/src/live_device_template.dart`): a plugin device and a rack with one
  chain. Each plugin gets its own parameter list, as Live writes one for a
  plugin loaded fresh (`SegnoPlugin.parameters`, checked against every
  plugin by the null test), so Live shows and automates its parameters. An
  entry that was off is the device switched off; the plugin's own switch
  stays on. A volume lane picks the Mixer after the devices and chain mixers
  in Live's lane chooser.
- The plugins start again as at arm whenever the host starts playing
  (`segno_fx_slot_rearm`; a jump while playing, such as a loop wrap, keeps
  the tails), so a render from the start of the set is
  the console's: without it, LFOs, noise and octaver hops run on while
  Live's transport stands.
- A plugin reports one latency at every rate, its kind's largest at 44.1,
  48, 88.2 and 96 kHz (`segno_fx_reported_latency`; more at a host rate
  whose own is larger), and delays its output by the rest: Live asks for
  the latency at its device's rate and not again when it exports at
  another, so a rate-dependent latency (the octavers, the Amp) was
  compensated wrongly. Superseded by #1836: every plugin reports no
  latency, so a lane plays as late as the console played it.
- Checked in Live 12.2.7: an export of `perf-20261112-130713` with a chain
  written in (Compressor, a Dub Rack with its Amb and Dub paths, an Echo
  Rack, an Octaver off) renders the dry track through the plugins within
  -139.6 dBFS of its "as heard" stem over 150 s.
- An input recorded raw (#1805) plays its raw recording through its
  monitor chain at arm, as plugins, on `<input> raw` (the hop seed is
  `le_fx_monitor_hop_seed`); the input as heard already has the chain in
  its audio. The monitor's volume, pan and on/off are not replayed yet.
- Not reproduced: the lane volume, which the engine applies before the
  lane chain, and the track gain, which it applies inside the Track stage
  (after its Pre entries), where Live applies both after the devices (the
  same at unity); a switched-off rack's modules' own switches, which the
  arm snapshot does not record (they are exported on, in a rack that is
  off); a rack's input choice and output side when its first or last
  entry is off or on a parallel path (each plugin carries its own); the
  Track stage, which the offline render does not apply, so a take with one
  differs from its "as heard" stem by it. Switching during the take is the control-events layer of #1806.
- `packages/segno_engine/vst3/test/render_capture.c` renders a capture's
  stems on the Mac as the console does, for checking an export.

## November 2026 Segno's effects as VST3 plugins (#1804 part 1)

- The owner's call of 2026-11-12 reverses Q13 (#940): the effects come back
  as VST3 plugins, built and installed on the owner's Mac only (no signing,
  no installer), so an exported performance can be edited in Live with the
  effects the console ran.
- `packages/segno_engine/vst3/` builds one bundle, `Segno.vst3`, with one
  class per built-in kind (31: every `le_fx_type` but none and plugin),
  named as the console names them ("Segno Delay", "Segno Room reverb").
  The class ids in `segno_fx_kinds.h` are new (the seven removed plugins'
  ids are not reused) and never change.
- Each plugin runs the engine's effects island (`engine_fx.c`, with the
  console's `tanhf` and `powf`) on one chain slot (`fx_slot.c`), set up and
  clocked as the offline render (`perf_render.c`) sets up a slot that holds
  an effect at arm. Its state (`segno_fx_state.h`) carries the settings, the
  entry's channel handling and enable bit, the chain slot it held, and the
  take's hop seed, FX clock and beat at the host's sample 0. The plugin runs
  the kind on that slot, so clock LFOs, octaver hops, update cadences, noise
  seeds and beat-locked kinds fall where the console's did.
- Parameter ids are the engine's parameter indexes (id p is `params[p]`,
  the normalized value is the engine's 0..1 setting); the channel handling
  is 1000 to 1003 and the bypass (the engine's enable bit) 1100
  (`params.h`). A host's bypass runs the engine's switch (delays and reverbs
  drain, the rest crossfade), except for a kind that delays its output (the
  octaver family, 1216 frames; the oversampled drives and the vinyl, 3 or
  4): it reports that latency on and off, and its bypass crossfades to its
  input delayed as much, so a host's delay compensation holds either way.
  The engine's settled bypass passes such a kind's input without the
  delay, so the two agree while it is on and differ by the latency while it
  is off. Superseded by #1836: 1100 is Enabled, the engine's switch for
  every kind, and no plugin reports a latency.
- The null test (`vst3/test/null_test.cpp`) writes a one-track capture per
  kind and case (defaults; other settings with a mono output, balance and
  level on chain slot 5; a setting change, a switch off and on again
  mid-take), has the
  engine's `le_perf_render_begin` render its wet stem, plays the dry stem
  through the plugin loaded from the built bundle, and compares: every kind
  and case is bit-identical, at 128-, 37- and 512-frame blocks, on macOS and
  Linux. CI builds the bundle and runs the test in `native-tests`.

## November 2026 The Live set carries the whole capture (#1799)

- A take's arm records the rig again: the app had stopped handing
  `PerformanceRecorderCubit` and `ControlCubit` the rig's chains (#375's
  wiring was lost), so every arm recorded no effects, `fx-chains.txt` came
  out empty and the wet stems were rendered without effects. Both now get
  `performanceChainsFromLooper`, and a `PerformanceNames` of what the player
  calls each track and input (`armSnapshot.tracks[].name`,
  `armSnapshot.inputs`). `InputsCubit` moved into `AppRuntime` beside
  `TracksCubit`, so the pedal path reads both.
- The Live set holds every looper track's wet stem, its dry stem on a
  switched-off `<name> dry` track (with the volume and mute as volume
  automation), each captured input, and `Master (as heard)` switched off,
  each named, with its effect chains in the track's info text.
- Captured inputs are recorded after their monitor chain, volume and pan
  (`mix_monitors_frame`), so they already are the inputs as heard, and play
  in the set. No dry input is recorded: re-processing an input would need a
  second tap before the monitor chain.
- The DAW package now copies `loops/`: without it the Session clips were
  missing media on the drive.
## November 2026 A take on a FAT stick keeps its renamed files (#1801)

- On vfat a rename writes the new directory entry with size 0 and first
  cluster 0 (`vfat_rename`, then `vfat_build_slots`); when it replaces a
  file, the entry it reuses still holds the old file's. Only the renamed
  file's inode, written back about 30 s later, fills it in, and a sync of
  the directory does not write it. A take recorded to a stick (#1198) and
  pulled within that window kept 0-byte stems, `performance.json` and
  `project.als`; a renamed take's folder read as empty.
- A sync of the file itself writes that inode at the entry's new place
  (`fat_file_fsync`), so every publish by rename into a take now syncs the
  file under its new name, then its directory: `le_wav_publish` (stems, the
  master reconstruction, a file render) through the new
  `le_fs_sync_file_errno`, and in Dart `StorageIo.syncFile` for
  `performance.json`, the arm snapshot and the DAW project
  (`PerformanceRepository.writeTakeFile`, which `writeDawProject` now writes
  through). A renamed or salvaged take's folder is synced under its new name
  and in its parent, and the render syncs `stems/` and the take folder once
  it creates the stem folders. No volume sync (#1797's export runs one at
  its end): nothing here needs a volume-wide flush, and none of it runs on
  the audio thread.
- Not renames, the same window: the lane WAVs written into `loops/` at arm
  and disarm are now flushed (their own sync writes their size), and
  `loops/` and the take folder are synced after them; arm syncs the parent
  of each folder it creates, the take's own first, so a short take pulled
  right after "Completed" keeps its folder.
- Not changed: the checkpoint slots are written in place and fsynced, which
  already writes their entries; the drain's live `performance.json` is
  rewritten four times a second while capturing and finalize replaces it,
  so it stays unsynced.
- Tests: an engine seam records what `le_fs_sync_dir` and
  `le_fs_sync_file_errno` synced, in order (`le_fs_trace_syncs_for_test`);
  the repository's `FakeStorageIo` records file and directory syncs in
  order.

## November 2026 Exported Live sets open in Live (#1791)

- Ableton Live 12.2.7 refused every `project.als` Segno exported: "corrupt
  and cannot be loaded (Not all list members have Ids)", because automation
  events carried no `Id`. The XML had been written from public knowledge of
  the format and never opened in Live.
- `buildAls` now generates from a set Live saved
  (`packages/daw_export/lib/src/live_set_template.dart`, generated from
  `test/corpus/automation.als` by `tool/generate_live_set_template.dart`):
  its audio track is copied once per channel with fresh pointee ids, and its
  clip and envelope are the prototypes for every clip and envelope. The
  corpus (`test/corpus/README.md`) holds six sets saved by Live 12.2.7
  (empty, clips, automation, tempo, a looping warped Session clip, a VST3
  effect), and the tests compare the generated XML with them.
- Fixed with it: clip lengths (unwarped clips' loop markers are seconds,
  not beats; lengths and rates come from the WAV headers, and a lane loop is
  as long as its file instead of the whole capture), `FileRef` type 2,
  looping Session clips (warped in Re-Pitch at the set's tempo), volume as
  the track gain times lane 0's level, envelopes that start from the arm-time
  values, no set for a capture with no tracks (Live refuses one), and the set
  opening in the Arrangement zoomed to the capture with automation lanes
  shown.
- Checked by opening exports of console captures in Live (screenshots in the
  PR). Envelopes are still written only over a dry stem, since the wet render
  already applies them (#1622).

## November 2026 Exports to a FAT32 stick (#1794)

- FAT32 holds no file of 4 GiB or more, and most sticks come formatted
  with it. The longest take (3 h, #1767) was held to what a WAV's RIFF size
  allows, which is 8 bytes past FAT32's limit with the header: a stereo
  master at 88.2 or 96 kHz that ran to its cap rendered at 4 GiB + 4 bytes.
  `le_wav_max_frames` now counts the 44-byte header against FAT32's
  largest file (`LE_WAV_MAX_FILE_BYTES`), one frame less; the drain takes
  the longest take from `le_perf_longest_take_frames`. 3 h at 48 kHz and
  93 min for a stereo master at 96 kHz are unchanged. The render still
  writes a master up to what `le_wav_seal` accepts
  (`le_wav_sealable_frames`), so re-rendering a take an earlier build
  stopped at the RIFF limit keeps its master.
  `test_perf_longest_take_fits_one_fat32_file` renders a take with a mono
  and a stereo master, reads every stem's header, and fails if any could
  pass 4 GiB less one byte at the longest take, for any cap and rate.
- Before an export or a backup touches the drive, `AudioExporter` checks
  every file against the largest file the drive's filesystem holds
  (`StorageRepository.checkFileSizes`, `RemovableVolume.maxFileBytes`:
  4 GiB less one byte on `vfat`, no limit on exFAT, NTFS or ext4) and
  refuses with `StorageFileTooLarge`; `copyFile` checks its source the same
  way. The Library's card line, and the backup's interrupted dialog, say
  "FAT32 drives can't hold files over 4 GB. Use an exFAT drive." A take
  this build records renders no file that reaches the limit (recording
  parts are 2 GB, session files are loops of 10 minutes at most); the check
  covers a master rendered at 4 GiB + 4 bytes for a take an earlier build
  stopped at the RIFF limit, and any later writer.

## November 2026 The Library writes to USB through the storage repository (#1790)

- Export to USB, Back up to USB and the Library's USB location never saw a
  drive on the appliance. The Library read drives through its own
  `RemovableVolumes` port, and the app never replaced its no-drive default
  (`InternalOnlyVolumes`) with #1177's `StorageRepository` once that landed,
  so every export asked for a drive with a stick mounted.
- The port, its copies of the storage models and `InternalOnlyVolumes` are
  gone. `LibraryCubit`, `LibraryAudioCubit` and `AudioExporter` take the
  app's `StorageRepository`, as the Storage page and the recorder do. The
  drive's lease names `WritePurpose.export` or `WritePurpose.backup`; the
  translated purpose stays on the guards, where a take's disabled Delete
  shows it. A `StorageBusy` from the lease reads as busy, like a
  `GuardRefused`.
- Two exporter faults the stand-in hid, now that a real drive reaches
  `AudioExporter`: an export's recovery of its folder deleted every
  `.segno-export-*` directory there, including the staging of a backup or
  export still running into the same folder (a backup and a mixdown export
  both write `Segno/Sessions`); exports into one folder now run one after
  the other, across the Library's exporters. And
  the swap's renames were never synced, so "Exported to USB" could show
  before a pulled stick would keep the export.
- A directory sync was not enough either (#1797). On vfat a rename writes
  the new entry with size 0 and cluster 0 (`vfat_rename`, then
  `vfat_build_slots`), and only the file's inode, written back about 30 s
  later, fills it in. A stick pulled after "Exported to USB" showed the
  late files at 0 bytes. `StorageRepository.copyFile` now syncs the whole
  volume after its rename (`StorageIo.syncVolume`: the engine's
  `le_fs_sync_volume_errno`, which runs `syncfs(2)` and then an fsync of
  the root to flush the device cache, since FAT has no `sync_fs`). The
  exporter runs `StorageRepository.syncVolume` once more after the swap
  and its clean-up, before it reports. `StorageRepository.syncDirectory`
  is gone. Once "Exported to USB" shows, the stick can be pulled without
  Eject.
- Tests fake the repository (`FakeDrive`, `NoDrive` in
  `test/library/helpers/fake_drive.dart`). One cubit test exports through a
  real `StorageRepository` over the console's own records (an `iso9660`
  whole-disk record the helper refused beside the mounted FAT partition),
  and one app test opens the Library and reads the repository's drive.

## November 2026 Flutter 3.50 and Dart 3.14 (#1777)

- CI, the app and every package build on Flutter 3.50.0 (Dart 3.14.0):
  `flutter_version: "3.50.x"`, `sdk: ^3.14.0`, `flutter: ^3.50.0`. Locally
  the 3.50 SDK is `/Users/Tomas/development/flutter-3.50` until the shared
  `/Users/Tomas/development/flutter` moves to it (How to build / test). The
  appliance's engine moves with them (`flutter-engine-version.inc`, below):
  the bundle's AOT snapshot loads only on its own engine.
- Material comes from `package:material_ui` (the SDK's
  `package:flutter/material.dart` is deprecated in 3.50). Import
  `package:material_ui/material_ui.dart`, never the SDK library. Use
  `appLocalizationsDelegates` (`lib/l10n/l10n.dart`), not
  `AppLocalizations.localizationsDelegates`: gen-l10n still lists
  flutter_localizations' delegates there, whose `MaterialLocalizations` type
  is not the one material_ui reads: under `es`, `MaterialLocalizations.of`
  finds none. `test/l10n/app_localizations_test.dart` checks both, and
  `test/tool/bloc_imports_test.dart` keeps material_ui and cupertino_ui out
  of blocs and cubits (bloc_lint's `avoid_flutter_imports` sees only
  `package:flutter/`).
- The lint set is very_good_analysis 11 as shipped: the app's and every
  package's `analysis_options.yaml` include
  `package:very_good_analysis/analysis_options.yaml` directly and override
  none of its rules or its formatter. So `dart format` automates trailing
  commas, a constructor named after its class is declared `new(...)`
  (`unnecessary_type_name_in_constructor`), and an empty class body is `;`
  (`empty_container_bodies`). #1784 applied this, and its description lists
  the commands. Code from a branch cut before it needs them again after the
  merge, in order, on the 3.50 SDK: `flutter pub get` in the app and every
  package, `dart fix --apply --code=unnecessary_type_name_in_constructor .`,
  `dart fix --apply --code=empty_container_bodies .`,
  `dart run tool/ffigen.dart` in `packages/segno_engine` if the engine
  header changed, `dart format .`, then `dart analyze` for lines the
  formatter leaves over 80 columns.
- Private named parameters (`required this._x`, Dart 3.12) replace
  `_x = x` initializer lists; `async` functions `return await` a future.
- The engine bindings are generated by `packages/segno_engine/tool/ffigen.dart`
  (ffigen 23's Dart configuration; the YAML file is gone).
- The image ships meta-flutter's prebuilt engine for Flutter 3.50.0 (engine
  `371f77202a73e8dff57a8b3bff75bca55c090aee`), the release the app bundle is
  built on. The embedder API only gained members between 3.47 and 3.50
  (Vulkan external textures, frozen-struct notes), and
  `MakeRenderTargetFromBackingStoreImpeller` is unchanged, so ivi-homescreen
  needed no change for it. ivi-homescreen is now pinned at upstream v3.0
  `9eeee89`, which has the pixel-ratio and shutdown fixes (#1834); the MSAA
  framebuffer (#1687) is the one patch left. Since 2026-11-23 it is pinned at
  `35e04ad`, the merge of toyota-connected/ivi-homescreen#861, which carries
  the MSAA framebuffer upstream. Upstream leaves it off on drm-kms-egl, so
  `homescreen.toml` sets `msaa_samples = 4`, and no patches are left.
- 3.50 adds `--impeller-use-sdfs`: rects, rounded rects, circles, ovals and
  lines drawn from signed distance fields and anti-aliased in the shader.
  Flutter's GTK, macOS and Windows embedders always pass it; the embedder API
  does not, and the console does not either. Measured on the console at
  48 kHz / 32 with a loop playing, release mode, 30 s windows: on the stage
  the V3D render queue was 27% busy without SDF and 63-66% with it (7.8 ms a
  render job against 3.1), the profile build drew about 10% fewer frames on
  the main screen, and the readout's raster time went from 5.9 to 10.4 ms
  (p50). Paths (the pen icons and the stomp art) still alias
  without MSAA, so SDF cannot replace it.
- Against build 243 (3.47.5), 3.50 without SDF is level: app CPU 11.4% of the
  machine on the stage against 11.8-11.9%, GPU 26% against 27%, build p50
  0.2-0.4 ms on both screens in profile mode.
- Scanout dumps read through KMS for every combination: MSAA 4x / 2x / off,
  with and without SDF, against build 243, are in PR #1781.

---

## November 2026 A capture left running stops on its own (#1767)

- The owner's call on the #1747 recommendation. The drain (`perf_drain.c`)
  ends a take, keeping everything recorded, once 20 minutes pass with
  nothing happening (`LE_PERF_STOP_IDLE`, sidecar `stopped_early: "idle"`),
  and at 3 hours (`LE_PERF_STOP_LENGTH_LIMIT`, `"length_limit"`), never past
  what a 32-bit WAV of the rendered master holds (a stereo master at
  96 kHz: 93 minutes). The times come from the repository
  (`PerformanceRepository.idleStopAfter`, `longestTake`) on
  `le_perf_target.idle_stop_seconds` and `max_seconds`.
- Something happening is a logged event a player's action leaves (a
  press, a transport change, an edit; not the facts the engine logs on its
  own, such as a loop top's tempo anchor or an overdub pass retiring) or a
  captured input sample over the engine's activity level (-40 dBFS)
  through the sound trigger's 100 Hz high-pass, measured in the drain, not
  the callback. Entries the engine logs past the idle end wait for the
  cycle's decision, so the log ends where the take does (#1549). The paused
  #1747 capture's idle 18 minutes peaked at -46 dBFS. An input whose noise
  stays over the level keeps the take going until the 3-hour stop.
- Only high-passed input counts (#1772 caught it): the drain also read the
  device's raw input meter once a cycle, at the same -40 dBFS, so mains hum
  over that level counted as playing whenever a cycle happened to read it,
  and on a console with hum a take would never idle-stop. The meter read is
  gone. Playing the captured streams do not carry (a monitor turned down or
  muted, the player on the interface's direct monitoring, an input not
  monitored at arm) does not keep a take going; high-passing the meter
  would need work in the callback.
- Nobody is there, so the capture dialog does not open for such a take
  (`PerformanceRecorderRendering.stoppedOnItsOwn`); `PerformanceAutoStopNotice`
  says it as a passing warning at the player's next touch, key, encoder,
  pedal or MIDI message (`IdleDimCubit.activities`). A stem that failed to
  render is the news instead: the take completes as partial and the dialog
  opens.

## November 2026 Cheaper effects, the same sound: the Vinyl (#1755 part 4)

- The Vinyl was the costliest kind no earlier part had touched (375 ns a
  frame at 48 kHz / 32). It ran its 4x oversampling (2x at 88.2 kHz and
  up) one channel at a time, and its dry share went down through a second
  copy of it. It now runs both channels in lanes (`le_os4`, as the
  Overdrive and the Distortion do), and the dry share's way down runs beside
  the copy's on the same design (`le_os4_downs`, two streams), so the two
  chains overlap. Bit-identical to master: `bench_fx_equiv --kind vinyl`
  (and the Overdrive and the Distortion, which share the lane code) on
  macOS clang -O2, GCC 14.2 and clang 18 -O3 on arm64.
- On the console (`bench_fx_cpu --paced --cpu 3 --table --only vinyl`,
  twice at each of the eight settings, master's binary and the new one on
  the same day): 4x settings about 362 -> 283 ns a frame, 2x about 190 ->
  166. The moving run costs no more than the table. The charges
  (`kFxSettingCostNs`): 381, 374, 375, 374, 201, 200, 192, 203 -> 297,
  296, 292, 293, 173, 177, 168, 179 (each the larger of its largest new
  reading and its old charge times its setting's after-to-before ratio).
  Raw tables in the console's `/data/bench/fx-opt-vinyl/out`.

## November 2026 Cheaper effects, the same sound: reverbs, delays, filters (#1755)

<!-- cspell:words Freeverb ulp tanhf exp2f log2f NEON equiv diffusers -->
- The owner's rule: no loss of quality. Every change here is bit-identical
  to the trunk it started from (65f85a3b4), on every factory setting, at
  44.1, 48, 88.2 and 96 kHz, in 32- and 64-frame blocks, tails included:
  `bench_fx_equiv` (How to build / test) proves it, with macOS clang -O2,
  GCC 13 and 14 and clang 18 -O3 (the appliance's) on arm64; CI runs its
  subset on x86 and arm64.
- The reverbs' network (Dub, Amb and Room): its eight lines run as two
  four-lane vectors (`engine_fx_simd.h`, GCC and clang vector extensions,
  NEON on the console), the two sides' diffusers in step, and a redesign
  while Length or Dec glides computes the lines four at a time. The sums
  that mix the lines still run in line order.
- Mode delay: the Drum and Dub voicings design each section once for both
  sides and only what a gliding setting moves; the time in frames is kept
  until the tempo or note value changes. EQ: both channels as one double
  vector. Freeverb: each bank's combs four at a time. Filter, Echo,
  Tremolo: one design, read position or gain a sample for both channels.
  Mod: the phaser's stage spreads once a rate.
- One instance on the console (Pi 5, GCC build, offline, core 3, ns a
  frame at 48 kHz): Room reverb 377 -> 309 still and 644 -> 426 with
  Length moving; Dub and Amb 198 -> 142 still, 351 -> 224 moving; Filter
  132 -> 82; Freeverb 128 -> 116; EQ 77 -> 63; Mode delay 80 -> 71 (the
  Dub voicing gliding 120 -> 104); Echo 117 -> 110; Mod 98 -> 92. The
  others are unchanged.
- The charges (`kFxKindCostNs`): the table at 44.1, 48 and 96 kHz, 32 and
  64 frames, and the moving runs at 48 kHz / 32, before and after on the
  same day; each kind charges the larger of its largest new reading and
  its old charge scaled by the median after-to-before ratio of the
  scenario that set it, so a worst case an earlier run caught keeps its
  margin. Room 735 -> 552, Amb 272 -> 225, Dub 221 -> 197, Reverb 234 ->
  223, Mode delay 179 -> 171, Filter 166 -> 99, EQ 88 -> 71, Echo 144 ->
  141, Mod 113 -> 110, Tremolo 52 -> 50. Ed's Rack 3407 -> 3199 at 96 kHz
  / 64 (2, 3, 4 and 5 racks with 0 to 3 workers, was 2, 2, 3 and 4) and
  4640 -> 4432 at 48 kHz / 32 (four inputs leave room for two track racks,
  was one).
- What was left: the Room reverb's early taps (up to 64 a side, about
  140 ns a frame) keep the trunk's loop character for character. The
  compilers decide per loop shape whether to fuse each tap's multiply-add
  (clang -O3 interleaves the trunk's loop and splits them), and a Drum
  room's low cut, a float biquad at 8 to 65 Hz, carries a one-ulp change
  to about -62 dBFS: the trunk's own clang -O2 and -O3 builds differ by
  that. So any non-identical change ahead of it fails the -120 dBFS rule;
  conditioning that filter is an owner's call (#1761). The
  dynamics, the Spring, the LPF and the modulation kinds spend their time
  in serial filter chains and per-sample `tanhf`, `log2f`, `exp2f` and
  `sinf` that an identical result cannot avoid.

## November 2026 A long capture recovers in bounded memory (#1747)

- Cause: the performance render (`perf_render.c`) held whole-length
  buffers, 33 bytes a capture frame for a track with a heard image (dry,
  wet, both heard sides, the heard marks, the routed pair) plus 8 for the
  master. The 1 h 36 min capture (277M frames) needed 8.7 GB; the console
  has 8 GB and no swap, so boot recovery was OOM-killed on every start.
  The per-track segment table (#1717) is a fixed 0.6 MB and not a cause.
- The render now runs every channel together a block of 65536 frames at a
  time and writes its stems as it goes (`le_wav_open`/`append`/`seal`):
  peak 7.5 MB above the process for 3 min, 1 h 36 min or 3 h on the console
  (under a 256 MB address-space limit), byte-identical stems and master to
  the whole-buffer render (all 160 native fixtures, the real capture at
  full length on the Mac, and the console's own build-238 stems). A cancel
  is seen at the next block and removes the stems it began; a stem that
  fails after some of its audio is in the master leaves no master.
- A device reconfigure (the audio warm-up, seconds after start) no longer
  cancels a running render: it used to join a worker that was rendering a
  whole stem, which held "Audio is starting" until the OOM, and dropped the
  recovery's stems.
- A salvage the app does not survive is not run again by every start: the
  bundle carries `.boot-recovery-attempt` (a count) while its salvage runs,
  a render that outlives the wait included. One interrupted salvage is run
  again (a restart or a power cut also stops one); at the second the bundle
  is marked `.boot-recovery-failed`, kept, and counted as not recovered.
  The not-recovered notice (a passing warning, said at every start) has Try
  again (`PerformanceRecorderCubit.retryRecovery`), which gives the take one
  more salvage.
- Stems are written as `<stem>.wav.part`, synced and published on sealing,
  so a cancelled re-render keeps an earlier render's stems; a render that
  runs to its end removes any stem it did not publish, so a bundle never
  mixes two renders. The render handle is its own engine field
  (`perf_render`), outside the capture state a reconfigure resets.
- A master past the 32-bit WAV sizes (stereo over 3 h 6 min at 48 kHz) is
  not rendered and the stems stand; a master that could not be written is
  left out without failing the tracks, as before.

## November 2026 The Studio Dist and the Overdrive's polarity (#1743)

- The Studio Rack's Dist is the Looper X's amp simulator without a cabinet
  (#891 rig, s19std). Its variant now builds the Amp+Cab on the D.I.
  cabinet, Bass and Modern 50 %, Treble 35 %, each Dist Drive read as the
  Amp's drive with the same 1 kHz small-signal gain (a table: 10 % is 5 %,
  50 % is 54 %, 66.5 % is 82 %, 80 % and up is 100 %). The 19 Studio presets
  against the captures at their settings: response 63 Hz to 8 kHz within
  1.9 to 2.6 dB (7.4 to 11.9 before), rms 0.8 to 2.4 dB, sample residual
  -2.8 to -12.9 dB. At 5 to 10 % the Looper X clips inputs above -12 dBFS
  harder than the Amp does (8.6 dB at 0 dBFS; Bass Di, Crunchy Tremolo,
  Oct Up Atmos). The Distortion kind is no longer built by any factory rack;
  chains saved with it keep it.
- The Overdrive no longer inverts. s20pol (stim_full, each rack against its
  own all-off pass) shows the OvDrive's onset positive and 2 samples late,
  as the dry path's, ringing to a larger negative swing 23 to 30 samples
  later, which Phase 0 read as an inverted output. The residual against the
  captures went from +4 dB to -10 to -13 dB (Ed's, Guitar and Lo-Fi).

## November 2026 The Lo-Fi Rack's Distort is the overdrive (#1737)

- The Looper X's Lo-Fi Distort is its overdrive: the Guitar Rack's OvDrive
  times 1.6 (+4.08 dB) to a residual of -73 dB at Drive 0, 53.5 and 100 %
  and Tone 0, 50 and 100 % (#891 rig, session s19lofi). The Lo-Fi variant
  (`_loFiDistortion`) now builds the Overdrive kind, Dist Drive and Dist
  Tone on its drive and tone (both 0 to 100 % on the Looper X), with the
  Overdrive's new level (0 to +12 dB, 0 dB by default) fixed at +4.08 dB.
  The module is still the catalogue's Distortion; the Studio Rack's Dist
  stays on the Distortion kind.
- Each Lo-Fi preset's Distort against the capture at its settings: the
  response from 63 Hz to 8 kHz within 1.7 dB, the 1 kHz ladder within
  2.1 dB, the level 0.6 to 1.4 dB under (the Overdrive kind's own fit error
  against the OvDrive, to the hundredth); the Distortion kind it replaced was
  17 to 25 dB off in response. Every other rack builds the same entries, and
  the Ed's and Guitar overdrives render the same samples (level 0 dB is a
  gain of exactly 1). A Lo-Fi rack charges the Overdrive's cost now.

## November 2026 Every FX control reads in units (#1731)

- "Scale unverified" is gone, with `FxParamInfo.taperUnverified` and the
  native `LE_FX_PARAM_TAPER_UNVERIFIED` flag. Every built-in parameter prints
  its value in its descriptor's unit (`fxParamValueText`), a factory module
  on one of the seven built-ins included (that case is reached only by a
  chain saved before #887 moved those modules to Looper X kinds; it plays its
  values on the built-in's scale, so those units are what it plays).
- Measured on the #891 rig (sessions s19std, s19lofi, s19oct; rig check:
  s6amp seg 0 repeats bit for bit, s7oct seg 0 within 0.01 dB):
  the Dual Octaver's Octave 1 Vol is linear in amplitude as the kernel has it
  (-2.50, -6.02, -12.04 dB at 75, 50, 25 %); the Studio Rack's Dist follows
  the Distortion's drive law (1 kHz small-signal gain within 3.1 dB from 0
  to 100 %). Dist Drive and Dist Tone are 0 to 100 % linear on the Looper X
  in both racks, and read as that percent here; the tone plays our own 2 kHz
  shelf. The settings and the sound are unchanged.
- Found: the Lo-Fi Rack's Distort is the Looper X's overdrive (the Guitar
  Rack's OvDrive at +4.08 dB, to -73 dB residual), not the amp simulator the
  Distortion kind models. Rebuilding it on the overdrive kind changes the
  Lo-Fi presets' sound, so it waits for the owner (#1737).

## November 2026 A switched-off tail keeps its charge until it drains (#1733)

- The snapshot reports which chain slots still drain a tail: `le_snapshot`
  carries the masks by chain (`fx_draining_monitor`, `_lane`, `_track`,
  `_all_tracks`, `_output`), and `EngineSnapshot.fxDraining` (`FxDraining`)
  reads them; no new polling. The chain's thread stores each slot's
  `enable_drain` flag whole with a relaxed atomic store (`LE_FX_DRAIN_STORE`,
  a plain store on arm64 and x86), and `le_engine_get_snapshot` reads the
  chain's own slots (up to `a_fx_count`) with relaxed loads. A first version
  kept an atomic mask in `le_fx_state` and set it from the pinned
  `fx_apply_chain_with_gain`: that grew the struct (changing the mixer's own
  code) and the driver (moving every hot function after it), and CI's arm64
  64-lane mixer went from 24.2 % to 24.95 % of its budget. This one leaves
  the struct and every hot function but the driver byte-identical, at the
  same addresses (the driver grows 32 bytes inside its last line), and CI
  reads 24.20 % (#1745).
- The repository reads the masks against its chains at each snapshot (a
  chain whose recipe the engine has not adopted keeps its last reading) and
  charges an effect of a draining kind while its slot drains, however it was
  switched off: the screen, a chain switch, a rack, or a hold. A held chain
  charges the tails it already drains, not the effects it was running, so
  R2 can still hold a running chain of reverbs; a chain whose hold would
  free nothing is not held, and a hold the engine has not taken yet charges
  the chain in full. Every snapshot (each poll and each write's
  re-projection) notes the draining-kind effects that stopped running, and
  one counts as draining until the engine has run two blocks past that
  snapshot (two snapshots if it processes nothing), so a switch-off the
  engine has not yet seen still counts. Once the engine reports the tail
  quiet, the room comes back with the next snapshot.
- `test/looper/cubit/fx_drain_budget_test.dart`: a Room reverb switched off
  at the limit refuses an Overdrive switched on until its tail drains, then
  admits it; a kind without a tail frees its room at once.

## November 2026 The effects budget reserves room only for what a switch can turn on (#1723)

- An effect is charged when it runs or a control can make it run: its own
  switch, its rack's (`FxRack.bypassed`) and its chain's are each on, or a
  control reaches that switch. An effect that is off and that no control
  reaches charges nothing. The rule lives in the repository's load
  (`LooperRepository._fxLoadAt`), so every admission (adds, loads, takes,
  rate and buffer changes, the rig coming up) and every readout follows it.
- What the controls reach is worked out from the binding set by
  `fxReachOf(ControlState)` (`lib/control/binding/fx_assignments.dart`,
  beside `fxAssignmentsTo`, which walks the same stores) and handed to
  `LooperRepository.setFxReach` on every change. It counts the console
  bindings in force (press and hold, a selected-scope binding on every
  track), every Track-stage chain (an unbound track switch in FX mode, the
  digit keys and the Track effects on command), each enabled MIDI mapping's
  effect switches and each external switch's activations under its jack's
  type.
- Switches one control alternates and no other control reaches (an
  external switch's On rows against its Off rows, Held against Released, a
  MIDI button's top against its bottom) charge their larger side
  (`FxReach.states`): the load is the largest over each side of each
  alternation, plus the state the screen left them in. An external or MIDI
  press weighs all the chains it writes as landed together
  (`LooperRepository.fxPress`), so the side it switches on is never admitted
  on top of the side it switches off.
- The screen weighs switching on an effect, a rack or a chain
  (`FxCubit.setEffectEnabled`, `setGroupEnabled`, `setChainEnabled`) and
  refuses it with the over-budget notice when it does not fit. A press never
  is: what it can turn on is already charged. The per-effect enable paths no
  view used (`MonitorCubit.setEffectEnabled`, LooperBloc's
  `Looper*EffectEnabledToggled`) are gone, so `FxCubit` is the screen's only
  writer of an effect's switch.
- A binding that would put the reservation over budget is refused at save
  (`ControlCubit.setGlobalBindings`, the pedal setup's save and the MIDI
  save throw `FxReachOverBudget` or return `MidiSaveResult.overBudget()`),
  and the screen says "Not enough processing left for what this switch can
  turn on". Those three saves share one queue (`ControlCubit._serializeReach`),
  so a check and its commit are one step and two pages cannot both pass. A
  change that only takes reach away (`fxReachShrinks`) is never refused; if
  the charge rises anyway (an alternation moving past the cap of 6), chains
  are held off as R2 does and come back once it fits. A session's bindings that come in over budget are admitted as a
  restore is (R2): chains are held off until the rest fits, and a reach that
  shrinks brings them back. R2 never holds a chain that charges nothing.
- A switched-off delay, echo, Mode delay or reverb keeps running until its
  tail drains (`le_fx_type_drains`; `kFxDrainingKinds` mirrors it and a test
  reads the engine's table). The side a press turns off is still charged for
  those, so an alternation charges the larger of each side plus the other
  side's draining effects (a console stress test switching an A/B pair every
  second at the limit showed the xruns without this). One switched off from
  the screen keeps its charge until the engine says its tail is quiet
  (#1733, above).

## November 2026 A take plays back what was heard (#1713)

- Plan and the owner's decisions: the comment on #1713. Engine part 1
  (`engine_heard.c`): a lane pool slot can hold a heard image, two more
  planes (left, right) beside the clean take, in lockstep with it (same slot,
  same capacity, the same allocation, retire, standby and zero-spare rules),
  so Undo, Redo, Peel and Clear's restore carry it with no code of their own.
- Capture: `le_record_image.heard_mask` gives a fresh take an image. The
  first frame loop logs where it wrote the clean take and the content
  operations it made mid-block (seam folds, #730 tapers and fades, the stop
  tail copy); after the monitor jobs the post-pass writes the input chain's
  output (times the capture trim) at the same places and replays the
  operations in order. Block-start operations (the punch-out drain,
  truncation) apply to the planes at once. A layer with heard images is
  announced to control only after its post-pass. The input chain runs while
  a lane captures through it even if its monitor is muted or off.
- Playback: a lane with source HEARD (the default) whose live slot holds an
  image reads its planes through the same head as the clean take and does
  not run its chain; `le_engine_set_lane_source` switches to the clean take
  through the chain with a 10 ms crossfade (the chain re-enters through its
  re-enable ramp). The wet cache does not print such a lane.
  `le_engine_heard_attach` gives a dry take an
  image copied from its clean take, for an overdub through effects.
- Part 2a: Double and the halves build the edited image's heard image with
  the clean take's arithmetic (and their Undo shrinks both). The render
  recipe (Bounce, Save selected) plays a heard lane as its image at level
  with no chain, read backward on a reversed track. A whole-track print
  assembles a heard part from its image (its key folds whether the part
  plays its image). Sessions: `le_engine_export_layer_heard`,
  `le_engine_import_layer_heard` and `le_engine_export_track_lane_heard`
  carry each image's heard image as interleaved stereo.
- Part 2b: a lane's Transpose and stretch renders carry its image (one
  stereo-linked stretch of the two planes, `le_stretch_render_loop_planar`),
  and the pitch bridge reads the image with the clean take's grains. Until a
  render with the image lands the lane plays its clean take at the track's
  pitch.
- Part 2c: a performance capture stages each layer's and restore image's
  heard images (after the clean lanes in its file, `heard_mask` in the
  manifest), logs each heard lane's source (`LE_PLOG_HEARD_SOURCE`,
  events.log version 16), and the wet stem plays lane 0's heard image where
  it sounded, with a crossfade at a switch as the callback does. The arm and
  disarm snapshots' `heardPcmRef` is read when the app writes it (part 4).
- CPU: a block where no lane holds an image runs the trunk's mixer
  (`mix_tracks_frame`, the heard copy is `mix_tracks_frame_heard`), checked
  under Valgrind against the trunk's instruction count.
- Part 3 (`engine_heard_tail.c`): when a capture pass on a lane holding an
  image ends (a take closing into play, a punch-out), the cache worker
  renders the input chain's tail from the last 12 s of that input (kept in a
  16 s ring per input a heard lane records, mapped by the control poll) and
  the callback adds it into the image after the pass's last written
  position, one frame per frame of time since the end, wrapping at the loop:
  always behind the read head, so the live ring-out on the first repeat is
  not doubled and the tail plays from the second. A take running straight
  into overdub renders none (the overdub records the ring-out). A new
  capture, Stop, a slot or length change, Reverse or Speed drop what is not
  added yet; Undo of the pass takes its tail with it.
- Part 4 (the app, dormant): `AudioEngine` reads and writes heard images
  (`exportLayerHeard`, `exportTrackLaneHeard`, `importLayerHeard`), sets a
  lane's source and attaches an image (`setLaneSource`, `heardAttach`), and
  arms a take with `RecordImage.heardLanes`. Sessions are schema 19: each
  layer names its heard image (`heard`, a stereo WAV beside the layer; the
  18 to 19 step fills in nothing), a recall imports it right after its
  layer, and the stem export writes it beside the clean stem. A performance
  capture writes `heardPcmRef` for the arm and disarm snapshots, and the
  Ableton export's session clip uses it.
- Part 5 (the switch-over, looper_repository): a take records heard on
  every lane whose input chain it inherits (`RecordImage.heardLanes`), keeps
  that chain on the lane by value, and remembers it as what the take was
  printed with (`_lanePrinted`). The lane plays its image while its chain is
  that one (compared as the chains persist) and its clean take through the
  chain once the chain is edited or switched off (a re-amp,
  `setLaneSource`); editing back plays the image again. A lane playing its
  image charges nothing in `_fxLoadAt`, so a re-amp is weighed like any
  edit, and R2 never holds one (holding it frees nothing). When R2 holds an
  edited chain, the lane plays its image. Takes are never switched off for
  the budget: `_takeOverBudget`, `fxTakeHeld`, its toast and strings are
  gone. A take
  the engine could not give an image plays its chain live and is weighed by
  R2. An overdub over a take recorded dry, on a lane with no chain of its
  own, attaches an image first (`heardAttach`) and records through the
  input's effects. The printed chain persists in the lane envelope's meta
  (`FxChainMeta.printed`) only while it differs from the lane's chain;
  absent, it is the lane's chain. The saved mixdown sums a lane playing its
  image as that image, its sides averaged.
- #1741: a take records its input chain's Pre run only (the input
  recipe now carries its split, `heard_mon_pre`; the monitor job notes the
  signal after the run, `heard_tap_*`, where a heard lane records a chain
  with Post entries). The Post entries are copied onto the take's lane as
  before #1713 and run live over the image (`le_heard_lane_wet`,
  `fx_apply_chain_from`), so they ring out past a Stop, and the render
  recipe and the performance stems run them too. The lane plays its image
  while its chain's Pre run is the one recorded, so an edit of a Post entry
  is not a re-amp; a heard lane charges its Post entries. An input chain
  with no Pre entry records clean. The rendered tail is the Pre run's. A
  re-amp the Effects page did not weigh that does not fit is held and named
  by the standing notice.
- Post entries that do not fit (the owner's option A, 2026-11-19): at the
  press, a take whose input Post entries would not fit beside the rest of
  the rig (and the takes pressed before it that have not landed,
  `_takeChargesPending`) copies them onto its lane at Pre. Its lane then
  carries no Post entry, so the engine records the input chain's whole
  output into the image (the tap point is the lane's own split, as for an
  overdub over a dry take), and the take sounds as heard; those effects stop
  with it on Stop. Its track says so (`fxTakePrinted`, "Effects recorded").
  Post entries that fit still run live. A lane playing its image is never
  held: not when its take lands (`_holdUnheardTake`), not by R2
  (`_fitRig`). An input chain that is all Post and does not fit is recorded
  heard, where before it recorded clean and could be held dry.
- Local tool: `SEGNO_HEARD_FORCE=1` runs the whole native core suite with
  every take recording an image of an input with no chain, which must equal
  the clean take after every callback.

## November 2026 A pedal switches a rack, so one switch alternates two racks (#1711)

- Each rack INSTANCE in a chain is a binding target of its own,
  `FxRackTarget` (`{stage, index, lane?, rack}`), keyed by `FxRack.id`. That
  id is already an instance id: every addition mints one (`SlotIds.mint`), it
  is saved with the chain, and a rename or reorder never rewrites it, so a
  second copy of the same sound in one chain is a different rack. A rack
  that is removed makes its bindings show as missing (R25); they never fall
  back to the chain or the other rack. Re-adding a factory rack asks first,
  counting bindings to the rack with those to its pedals in its one
  question, and removes them on confirm.
- A rack's switch is `FxRack.bypassed`, on every module of the rack and
  saved with the chain (session file, settings and performance snapshot
  alike). Off and on change only that flag, so each pedal's own `enabled`
  is as it was, and a round trip (a hold, a Released value) is exact.
  `TrackEffect.effectiveEnabled` is the pedal's own switch with its rack's
  applied. The engine has no rack switch: the repository hands it the
  effective state through the existing per-entry atomic stores and recipe
  slots (`LooperRepository.setRackEnabled`), so the callback, wet cache,
  fingerprints and performance log see it without knowing racks, and nothing
  native changed.
- Offered in External pedals Controls, MIDI controls and FX pedal
  assignments, each rack after its chain and before its own effects. A chain
  that is one rack end to end (`fxSoleRack`) offers that rack in place of
  its "Every effect" row, so the pedal switches what the rack's card
  switches; an older binding to such a chain still works. Custom controls
  carry actions, not activations, so they offer none.
- The Effects page's rack power is the same switch: its button reads
  `FxChainGroup.isOn` (the rack's switch), the card lights when
  `FxChainGroup.audible` (switch on and a pedal on), and a bypassed rack's
  editor dims its pedals, which keep their own switches.
- A pedal LED follows what the Effects page shows (`bindingLit`): a chain or
  rack binding lights with its own switch, an effect binding only while the
  effect sounds (its own switch, its rack's and its chain's on, the chain not
  held off for room). Pressing still flips the effect's own switch.
- A console binding's toggle now saves the chain it changed, so a rack (or a
  chain or an effect) switched from the pedal survives a reload. A momentary
  returns to what is saved, and an empty chain switched off is not saved.
- The performance arm snapshot carries each entry's effective state, since
  its native reader knows no racks.
- One external switch with Rack A active while On and Rack B active while
  Off alternates them on every press (the Line 6 Helix pattern);
  `test/control/rack_activation_dispatch_test.dart` drives exactly that
  through the control path.

## November 2026 Undo after a track clear (#1707)

- Undo right after a track clear restores the cleared track, whichever track
  is selected. A Track Hold clear in Mute leaves the selection where it was
  (#1671), so on build 234 the Undo pedal undid the selected track instead.
  The clear from the screen, a Custom Clear track and the Track Hold all go
  through `LooperRepository.clear`, which now records the clear as the last
  undoable clear, the same group a Clear all forms (#1634).
- `LooperState.undoRestoresClear(channel)` is the one rule: a clear can be
  undone, and the asked track has no record arm or Count-in launch and is
  either empty or not capturing and not edited since the clear
  (`editedSinceClear`).
- "Edited since the clear" reads the engine's history order: every undo
  entry (a layer, a Peel, a length edit, a Bounce, a Clear restore point)
  is numbered as it is filed, and numbered again when a Redo files it back,
  and `le_track_snapshot.history_seq` publishes the number of the entry the
  next Undo takes back. A track is edited since the clear when that number
  is newer than the newest one at the clear, when it was empty or recording
  its first take at the clear and has a take now, or when a Clear all was
  refused on it. So Undo works
  newest first across tracks: after an overdub on the selected track since
  the clear, the first Undo takes the overdub back and the next restores
  the clear.
- The clear stops being "the last thing" as with Clear all: a later clear
  replaces it, a fresh take on the cleared track retires it, its Undo spends
  it, and a newer edit on the asked track, or a running capture, is that
  track's own Undo. An edit on a third track does not stop it. A clear of an
  empty track, which leaves nothing to restore, keeps the clear before it
  (as an empty Clear all does, #1642), and leaves an undone Clear all's
  grouped Redo alone, and so does undoing it. A Redo of a restored track
  clear on that track makes it the last clear again; a Redo on another
  track is that track's own, as after Clear all (#1634).
- The cleared notice still offers only a Clear all: `clearAllUndoable` is
  `undoableClear == UndoableClear.all`, so a later track clear ends it.

## November 2026 Clear track Hold also clears in Mute mode (#1671)

- With Track Hold set to Clear track, holding a track pedal in Mute mode
  clears the held track as in Record: the 350 ms pause, the pill fill and
  the flash (#1534, #1652). Bank-following, take locks and mode changes end
  it as before.
- With Clear track set, Mute's track press acts on release, and a hold that
  fires cancels it (the owner's option B on #1671), the rule Custom pairs
  follow. So nothing unmutes, rejoins the mix or parks the loop before a
  clear, and Undo brings the track back as it was. With Arm overdub or None
  set, Mute keeps its press on contact.
- Arm overdub still runs only in Record (`ControlCubit._armTrackHold`). A
  Song section that is capturing is not cleared from Mute, as Mute's press
  leaves it alone. The Looper X's Hold Track Pedal is one setting with no
  mode limit; the RC-600 has no Mute mode but puts Clear on the long press
  of its Play/Stop and Stop track functions.

## November 2026 Readout palette (#1674)

- The 7in readout draws with `AppTheme.readout`: `AppTheme.neon` with
  `SurfaceTheme.readout`, which lifts only the two dimmest tiers of
  `SurfaceTheme.dark` (owner decision 3 on #1674). Muted text takes the
  `textTertiary` grey 8A8A92 (5.9:1 on the readout's background, 3.8:1
  before), and `borderSubtle` is an opaque 4A4A50 (2.05:1 against the card,
  1.41:1 before). The ink tiers stay translucent. The main screen keeps
  `SurfaceTheme.dark`.
- Everything muted on the readout lifts together: "Empty", the BPM unit, the
  Loop panel's section labels, lock icons and dotted rule, the keypad title
  and the waveform's bar numbers; so do the footer strip's border, the tempo
  card's border and the plain buttons' edges.

## November 2026 Clear tempo on the 7in readout (#1654)

- The owner changed decision 6 after build 229: the readout's Loop panel
  has Clear tempo beside Tap, offered whenever a tempo is set, as on the
  main screen's Tempo page.
- It sends `tempo.clear`; `ReadoutCommands` calls
  `TempoSettings.clearTempo()` (#1653), so the engine's tempo lock decides.
  A refusal is the screen link's one reply (`ScreenLinkOp.refused`, a
  `ReadoutRefusal`), and the panel shows the main screen's notice, title and
  reason, in the tempo note's place for 6 s. While it shows, it replaces the
  recording band.

## November 2026 Tempo, length and start on the 7in readout (#1654)

- The readout's footer is a strip that names the tempo, signature, length
  and start of the next take; touching it opens the Loop panel
  (`lib/visualizer/readout_panel/`, layout B in
  `docs/plan/2026-11-04-feat-readout-controls-plan.md`). The rest of the
  readout is unchanged. Done or 10 s without a touch closes the panel.
- The panel: the tempo in hundredths with -1, -0.1, +0.1, +1 (hold to
  repeat) and Tap (sent on touch); the figure opens the #1653 keypad's rules
  and pad, laid out for the 7"; the time signature (all 17 behind More); the
  default length (1 to 64 bars or Auto) and record timing. A selected
  track's own length or timing is named, and stays a main-screen edit.
- Commands cross the screen link as `ReadoutCommand` (`op: command`) and
  `ReadoutCommands` applies them through `TempoSettings`, `RecordSettings`
  and `RecordTimingSettings`; the readout sees the result in its next push,
  which now carries `tempoFollow`, `clockOwnsTempo`, the loop settings with
  their capture lock, and the idle dim (a barrier eats the waking touch).
- Locks follow `LooperState.tempoFollow`: a tempo change that stretches
  the recorded loops is allowed and said first; the signature changes only
  before the first take; length and start lock while a take records.
- The design is in Penpot, page 25 (Main views and selected-track display),
  section "25  Readout controls": the strip, the panel in its states and the
  keypad at 640x375 logical (tomassasovsky/segno-design#21).
- Device checks owed (#1906): tap-tempo latency from the readout against the
  main screen (within 0.5 BPM at 120), and reach at the panel's edges after
  touch calibration.

## November 2026 Loop settings as four tabs (#1659)

- Settings → Loop settings has four tabs on its title row in place of the
  hub and its six pages: **Loop mode**, **Tempo & click**, **Recording** and
  **Playback**. The next visit opens on the tab last open (kept for the run,
  `openLoopSettings` in `segno_navigator.dart`); the stage footer's tempo and
  mode open their tabs directly. Brainstorm with the owner's six answers:
  `docs/brainstorm/2026-11-04-loop-settings-structure.md`.
- **Recording** (`loop_recording_page.dart`) is everything about when a take
  starts and ends: Start recording and Second pedal press side by side, the
  track selector, Loop length with Later tracks directly under it (Defaults
  only), then Record timing. A take recording locks the whole tab behind one
  banner.
- **Playback** (`loop_playback_page.dart`) is everything a loop does as it
  repeats: Loop/Once, overdub decay, then Follow tempo and Pitch side by side.
  Nothing on it locks. The name "Audio & tempo" is gone.
- One track selection for the visit, owned by `LoopSettingsPage`: it opens
  at Defaults, Recording and Playback share it, and Back or Stage ends it.
- Count-in stays on Tempo & click and says, while Start is Sound, that a
  count-in switches the start to Pedal. The loop-length capacity refusal
  names Settings, Device instead of the old Audio setup.
- No setting was added or removed; the engine and the settings owners are
  untouched. Owed: the Penpot frames (geometry in the PR's "Design
  writeback").

## November 2026 Exact tempo entry, Clear tempo, and footer shortcuts to Tempo and Loop mode (#1653)

- The Tempo page's big BPM is a button: it opens the console keypad
  (`showTempoEntrySheet`, the numeric layout of `OnScreenKeyboard` in the
  rename sheet's frame) for 30.00 to 300.00 BPM with two decimals. A tempo
  outside the range keeps the sheet up and says the range.
- Clear tempo returns the rig to no tempo, so the next defining loop sets
  one. The engine decides with its D6 lock: `le_engine_clear_tempo` (command
  142) answers `LE_ERR_NOT_READY` while material sits under the tempo or on a
  grid, a take records or a count-in runs, and while a record is posted,
  waiting or launching; the callback rechecks `le_tempo_locked` and a waiting
  record, and raw posts of 142 are refused. A refusal raises the
  `tempoClearRefused` notice, saying why. The repository refuses with
  `notRunning` while the engine is stopped. Not perf-logged (the effect chains' tempo anchor
  logs the change). Native test: `test_clear_tempo_follows_the_tempo_lock`.
- Stage footer: the tempo block opens Loop settings at Tempo and the loop
  mode pill at Loop mode (`openLoopSettings`), each a 44-high tap target with
  the ink pressed state.

## November 2026 Clear track hold pauses before its fill (#1652)

- With Track Hold set to Clear track, a held track pedal waits 350 ms
  (`ControlCubit._clearTrackPause`) before its pill starts to fill. During
  the pause the pill reads pressed and no `CLEAR_HOLD` is sent, so a release
  in it is an ordinary press (the track is selected and nothing else
  happens). After the pause the fill runs from 0 over the long-press
  threshold (800 ms by default) and the track clears when it completes, at
  1150 ms from the press.
- Only the Clear track hold changes. Undo's redo, Bank, Clear all, custom
  Holds (including a Custom Clear or Clear all) and every other hold keep
  the long-press threshold, and a custom clear's fill still starts at the
  press. No screen draws the track fill, so nothing on screen changes.
  Firmware is unchanged.
- Device check owed: the pause and the fill's feel on the console.

## November 2026 The interface's input switches (#1646)

- Settings → Audio routing → Input setup has an **Interface** row for the
  selected input: Inst or Line, Pad, Air (a switch, or Off / Presence /
  Presence + Drive) and 48 V with the inputs its switch powers. Segno stores
  nothing: `InterfaceInputsCubit` reads the interface at each device open,
  after each change and twice a second while the tab shows, and each change
  is written straight to the hardware and read back. 48 V asks first
  (`showDeviceConfirmDialog`, naming the inputs) and never turns on by
  itself; the row locks with a recording on the input or its 48 V group;
  input cards carry `Inst` and `48 V` tags; a refused change is a passing
  notice. Plan: `docs/plan/2026-11-04-feat-interface-input-controls-plan.md`.
- Engine (`src/core/engine_interface.c`, `engine_interface_inputs.c` until
  #1648 moved the routing tables in): a capability model
  (`le_interface_inputs`) filled by per-family adapters chosen by the card's
  USB vendor and control names: `scarlett2` (with the setup-mode and
  pass-through checks), `scarlett` (1st Gen, with its own routing check) and
  a generic keyword fallback that keeps only controls naming one input.
  `le_mixer` gained the card's identity and control list; both libasound
  symbol tables resolve under `pthread_once`, since the calls run on a Dart
  worker isolate (`NativeAudioEngine.offIsolate`).
- Tests: `test_engine_interface_inputs.h` against real public dumps in
  `src/test/fixtures/alsa/` (Scarlett Gen 1/3/4 models, Vocaster Two,
  Behringer UMC204HD, MOTU M2 and M4, Audient iD4, an HD-Audio codec), each
  citing its source; the repository, cubit and widget suites; the
  `audio_routing_input_setup*` screenshots.
- The input meter carries the gain band (-18 to -6 dBFS,
  `kInputGainTargetDb`) and a note to set the hardware gain knob against it.
- Owed: the Penpot frames (plan part 3, #1658; geometry in PR #1651's
  "Design writeback"), the device checks listed on PR #1655, and #1648 (the
  routing rules into the same adapters).

## November 2026 Takes remember the input they were recorded from (#1678)

- A lane's take keeps the input it was captured from (`Lane.recordedInput`),
  fixed when the take starts, the same way the lane's image pan and balance
  are fixed (`_laneSource` in `LooperRepository`, filled from the pending
  image when the take publishes). Changing the lane's input afterwards only
  changes where the next take comes from.
- A Session saves it per lane (`recordedInput`, schema 18). Older bundles
  convert by taking the lane's saved `inputChannel`. A recall restores it.
- Effects → Recorded tracks lists the inputs a track is set to record
  (`laneCounts`, `laneInputs`), whether or not anything is recorded yet, and
  names a part that holds audio by its recorded input.

## November 2026 Takes keep the lap they were played on (#854)

- A take of several base loops reads segment
  `(loop_iteration - start_iter) mod multiple`. Every reset used to zero
  `start_iter`, so Stop-all, a reopen, a Session recall and the undo of a
  Clear or of an undone take moved each take's first loop to lap 0. Each
  reset now keeps the take's anchor, `start_iter` modulo its multiple
  (`le_track_anchor` / `le_track_anchor_set` in `engine_private.h`), with
  `start_iter` moved to the same residue at or below lap 0.
- The anchor is published as `le_track_snapshot.anchor_lap`. A Session saves
  it per track (`anchorLap`, schema 17; older bundles convert to 0) and a
  recall gives it back with `le_engine_import_anchor` before the commit. A
  Clear carries it in its restore point through the Clear mailbox; an undo to
  empty files it on the redo entry from the published value, and
  `LE_CMD_REDO_FROM_EMPTY` / `LE_EVT_TAKE_CANCELLED` carry it in the
  `restore` payload; an undo behind a queued restore files the lap that
  restore carries (`pending_anchor`). A mode switch keeps it between
  shared-clock modes, counted again in the take's new multiple when the
  base changes. At another Speed a restart (the hold, a reopen, a commit, a
  restore or redo into a held rig) parks the head so the take starts on the
  image frame it reads at 1x (`le_track_park_head`), so the offset holds at
  1/2x too. A Once take is launched, not placed: a restart starts it at its
  first bar, as a relaunch does. A Session save keeps the lap within the
  multiple it pairs with.
- Not placed: a restore or redo into a running rig at a Speed other than
  1x reads from origin 0, as before; the takes around it carry origins from
  the Speed change, and there is no common reference to place it against.
- The DAW export places an arm-time image at its anchor: the performance
  manifest's arm `tracks[]` carry `anchorLap` when nonzero.
- Native test: `test_engine_anchor.h` (a 4-bar take on bar 1 and one on bar
  3 keep their two-bar offset through Stop-all, Session save and recall, a
  retained reopen, Clear undo and redo of an undone take).
- By-ear check owed on the console: record a 1-bar loop, a 4-bar take from
  bar 1 and a 4-bar take from bar 3, then Stop-all and Play, and save and
  reopen the Session; the two takes keep their offset.

## November 2026 The octaver's kinds play live (#1624)

- The owner's decision on #1624: the Octaver, Dual Octaver, Whammy and Smart
  Tune are never printed and always play live (the multicore workers, #1515,
  carry live chains), because a print cannot be made exact.
- The cause: their phase vocoder carries running synthesis phases, which a
  loop of most material advances by a fraction of a cycle each lap, so the
  live voice is phased differently every lap. A print equals the lap it was
  rendered for (the old parity sweep, on a constant loop, could not see the
  rest) and steps at every loop top after: on a 220 Hz sine loop of 55
  whole hops, the live octaver's second lap differs from its first by 0.8,
  however the chain went in.
- They carry the free-running flag (`LE_FX_F_FREE_RUNNING`), heard when the
  voice is: the octaver's mix above 0, the Dual Octaver's mix with a voice
  up, the Whammy's pedal off 0; Smart Tune always
  (`le_fx_entry_free_running`). An unheard voice repeats every lap and
  prints. With no print holding a heard octaver, the hop-position key (#941)
  is gone: the fingerprint fold, `le_wet_entry::hop_tag`,
  `LE_CACHE_REASON_HOP` (FREE_RUNNING is now 5),
  `le_fx_hop_period`/`le_fx_hop_position` and `le_engine::fx_hop_period`.
  The octaver's clock-anchored hop and its per-owner seed stay: the render
  recipe and the stems still reproduce it.
- Tests: `test_cache_pitch_kinds_play_live` (each kind gives up, and the
  octaver's laps differ on a sine), `test_cache_bypassed_octaver_prints`,
  and `test_cache_clock_lfo_relaunch_rerenders` (the relaunch re-render,
  now on a lap-locked tremolo).

## November 2026 The sound trigger ignores hum (#1623)

- The sound-activated record trigger reads each input through a fixed
  fourth-order Butterworth high-pass at 100 Hz (`LE_TRIGGER_HP_HZ`,
  `le_trigger_hp`), on its detection path only: 50 and 60 Hz hum come out
  24 and 18 dB down, rumble more, while a pick's attack still crosses the
  -34 dBFS threshold on the frame it arrives. The take records the raw
  input. It replaces the conditioning stage the trigger read before #697.
- The filter runs on every real input every frame (two biquads each), so an
  arm never starts on a cold filter. Test: `test_sound_trigger_ignores_hum`.

## November 2026 Prints swap in after a complete lap, LFOs on the clock (#1620)

- The owner's decision on #1620: (1) time-based modulation takes its phase
  from the engine clock, (2) a print swaps in only over a live chain that has
  played at least one complete lap since its last key change. The run rule
  (`le_run_matches_print`) is now: begun on a loop top, the next top; begun
  part way through a lap, the second top after it. Anything else stays live.
- Clock LFOs (`le_clock_lfo`, engine_fx.c): the tremolo and the echo's wow
  take frac(rate x frame / sr) from `le_fx_now`. A rate move keeps the
  phase continuous through an offset that slides back to 0 at 0.25 cycles a
  second, or half the LFO rate when slower (`LE_LFO_RELOCK_CPS`); while it
  slides, the lane's run waits (`le_fx_lfo_relocking`). A state nobody
  clocks (the VST3 processors) counts its own frames, as before.
- Such an LFO prints only on a loop it fits a whole number of times (within
  3e-5 cycles for the tremolo, 5e-7 for the echo's wow, what keeps the step
  at each loop top under 1e-4): otherwise each lap sounds different and it
  plays live, reported FREE_RUNNING (`le_fx_entry_lfo_drifts`). Its print is
  keyed on the top's place on the lap grid (`le_fx_lap_position`, folded
  into the fingerprint, `le_wet_entry::lap_tag` at the lap top).
- What a chain plays reversed or at another rate is not a lap of the loop,
  so every run on the track begins again where the head is back at forward
  1x (and at any jump of the read index there, which Play on a playing track
  does not make today). A lane back at Normal after a reverse or speed turn
  therefore prints again after a complete lap, where #939 left it live
  until its next edit.
- Remaining step at the swap per kind (`test_cache_midlap_edit_steps`, a sine
  loop): 0 for the memoryless and short-state kinds; a delay or reverb
  differs by the part of its tail older than a lap; the octaver's kinds play
  live (#1624).

## November 2026 Wet cache swaps in only over a matching run (#939)

- The owner's decision on #939 (Q11): the loop-stage wet cache stays off
  where it cannot swap in exactly. A print reproduces a chain that began one
  lap before the loop top it swaps in at (render twice, keep the second).
  The audio thread now follows each live chain's run, the stretch it has
  played one unchanged key over (`le_chain_run` on each lane and track bus,
  counted in laps by `le_track::laps`), and swaps a print in only where that
  run matches the print (`le_run_matches_print`; tightened by #1620 above).
  An older run keeps playing live: it carries history the print does not
  (an echo built up over more passes, an LFO further on), which used to step
  at the loop top.
- In practice: a print is ready about 250 ms (`LE_CACHE_SETTLE_MS`) plus a
  few 16 ms scheduler ticks plus its render after the edit, so on a loop
  shorter than that the cache stays off; longer loops print as before. The
  same rule holds the whole-track print.
- Tests: the every-kind parity sweep adds a 2560-frame loop per kind (the
  print is ready five laps after the chain went in) and
  `test_whole_track_print_stays_live_on_a_short_loop` covers the track
  print; the whole-track tests run on a 16384-frame loop.

## November 2026 Segno owns the interface's routing (#1046)

- At every device open, before the loopback mask is read and the callback
  starts, the engine sets the interface's routing matrix to plain
  pass-through (`le_platform_own_interface_routing`, from
  `le_engine_publish_and_start`, so start and reopen both run it). Linux
  sets the inputs of the card behind the capture id and the outputs of the
  card behind the playback id (both, when they are one card), through the
  `dlopen`'d libasound control API. Inputs only on the capture card, so the
  loopback slots it sets are the ones the mask excludes.
- The rules are per kernel driver, matched on control names. Only
  `scarlett2` has rules (Scarlett Gen 2 and 3, Gen 4 Solo, 2i2 and 4i4,
  Clarett USB/+, Vocaster; the big Gen 4 units use the FCP driver and are
  left alone): since #1648 the `scarlett2` adapter's routing table in
  `engine_interface.c`, applied by `le_own_interface_routing`, which picks
  the table as the input switches pick their adapter (USB vendor, then
  control names). Hardware outputs
  (`Analogue Output NN`, then `S/PDIF Output N`, then `ADAT Output N`
  `Playback Enum`) play `PCM 1`, `PCM 2`, ... in order. `PCM NN Capture
  Enum` records the hardware inputs in order, and the slots past them
  return `PCM 1`, `PCM 2`, ... (the loopback #1541 times on, excluded from
  recording; `Off` on a card Segno only records from). A hardware input recorded through the unit's input DSP
  (`DSP n` fed by that input, Gen 4 and Vocaster) is kept. Direct
  monitoring goes off. The mixer is left alone, since
  nothing selects a `Mix` afterwards. Only controls that differ are
  written, then read back. A card without these controls is left alone.
- Logs `segno/audio: hw:N routing set to pass-through (N of M controls
  changed)`, or `routing not pass-through` with the first control that
  failed. Nothing is reported to the UI yet.
- Tests: `test_engine_interface_routing.h` runs the rules against a fake
  card read from the console's `amixer contents` dump
  (`src/test/fixtures/alsa/scarlett_4i4_gen3.txt`) and against built cards
  (S/PDIF ordering, direct monitor).
- Verified on the console's 4i4 on 2026-11-03 with a test engine library:
  outputs set to `Mix A`-`Mix D` and stray capture sources came back as
  pass-through at app start (7 of 10 controls changed), and the loopback
  mask read 0x30. Device check owed: a replug after scrambling the routing
  in `amixer`.

## November 2026 One notice system (#1562)

- The owner's decision on #1562: direction 1 (the top bar's centre says a
  passing message in place of the session name; a must-act message turns the
  whole bar into a banner) plus direction 3's per-track messages on the track
  cards, and the same message as a band across the readout's top margin.
- One cubit, `NoticesCubit` (`lib/notices/`), provided at the app root:
  `show` (top bar, goes by itself), `showOnTrack` (that track's card),
  `raise` / `clear` (must-act, until the condition clears) and `setHeld`
  (the Power screen holds them). One message at a time, the newest replacing
  the last; a passing message with a standing must-act message's id is
  dropped. Durations: 4 s, 6 s for a warning, 8 s with an action, 10 s for a
  one-time explanation.
- Surfaces: `NoticeBar` + `NoticeBarMessage` in every top bar (the stage's,
  the performance views' `FootTopBar`, the settings frame), laid out by the
  shared `TopBarLayout`, so the side controls never move and the message sits
  on the session name's baseline at its size; `TrackNotice` in the Track and
  Wave cards (a Mixer strip is all controls: it rings and the bar says it);
  the readout's band (`ReadoutNotice` over the screen link).
- Sizes and type ramp in the `NoticeTheme` extension, gaps from the new
  `SpacingTheme` scale, colours from `SurfaceTheme` (new `warningTint`,
  `warningLine`). Screenshots: `notice_*` in the tracks and notices suites.
- Every message the app says goes through it (part 2): the settings
  owners' and the mix's recoveries, the session boot and monitor restores
  and the power-cycle prompt are must-act messages with their fix; the
  lost interface, the cleared loops, the stopped engine, audio starting and
  the effects held off are raised by `StandingNotices`
  (`lib/app/view/standing_notices.dart`) on every screen; a press a track
  refused is said on its card; the rest pass through the top bar. Ids live
  in `AppNoticeId` (`lib/app/app_notices.dart`). `toastification`,
  `ControlSettingsNotices` and every `SnackBar` are gone; the rename sheets
  say a bad name under the field.
- Rules beyond the decision, settled while building it: a body is shown
  whole or not at all; a bar too narrow for the buttons (a desktop window)
  drops them before the words; one-time explanations queue behind each
  other instead of replacing each other; the Mixer's own top-bar buttons
  step aside while a must-act message stands. `test/notices/
  notice_copy_fit_test.dart` renders every message in English and Spanish
  in the stage bar and fails on any cut title or dropped body or button.
- Tests: a press that settles runs a passing message's time out, so tests
  ask `NoticeLog` (`test/helpers/notice_log.dart`) what was said.
- Part 3: the page bands (the Effects pages' "effects are off", Loop
  settings' lock, the Updates page's rollback) are one `InlineNotice` on the
  notice tones and type, with no inline alpha wash (the token test now
  covers `warning` too); a ConsoleBanner that needs no action is amber, not
  red (the device running at other settings, a storage action that did
  nothing, the Library's refused open and listen). The Storage and MIDI
  pages' one-line amber notes stay the pen's.
- Polish (`claude/notices-polish-1562`): the audio interface's own MIDI
  ports are said once, with it (`midiIsInterfacesOwn`: the same name, or
  within 5 s of the interface going or coming back); the lost interface is
  named from the host's catalog ("Scarlett 4i4 USB"), never the engine's
  generic ALSA "Playback Device", else "Audio interface"; a sentence the
  top bar has no room for is said whole on the readout, whose band grows
  over the readout for it, and a `detailed` message (a converted session's
  changes) stays 10 s.

## November 2026 Automatic LED brightness from a light sensor (#1564)

- An optional Vishay TEPT5600 on J22 (GP28), with 100 Ω in its collector
  lead, its load resistor (2.2 kΩ) and 100 nF in the lead's J22 end; wiring, resistor choice and saturation in
  segno-hardware's `hardware/segno_wiring.md`. The enclosure part (hole,
  holder, lead route) is a separate thread.
- Console firmware 2.7 smooths the reading (readings at random 7-13 ms so
  mains flicker averages out, one-second means, a five-second median, a 3 s
  average, a quarter-doubling hysteresis), tells a fitted sensor
  from an open pin with the pad's pulls every 2 s, and reports it after every
  hello as `AMBIENT` (`0x07`): the raw ADC reading on a log scale, not lux.
  The app answers with `LED_LEVEL` (`0x14`), which scales the pills and, via
  the ring link's new `LEVEL`, the ring (ring firmware 1.2), with a fade.
  Both optional, so still protocol 12; with no `LED_LEVEL` the board shows
  what 2.6 did.
- The app: Settings > Displays > Console LEDs (`ConsoleLedsCubit`,
  `ConsoleLedSettings` in settings_repository). Manual brightness (default
  100 %, today's) or Automatic, which maps the reading between two points the
  owner captures (Dark room, Bright room) on a log-linear curve from about a
  third to full, plus a brighter/darker offset; the board's level is that
  brightness to the power 2.2. Automatic is unavailable without a reported
  sensor and says why. `AmbientBrightnessCurve` is the seam for the screens.
- Not done: the screens' own automatic brightness; a bench of the console's
  reflected light against the hysteresis once a sensor is fitted.

## November 2026 The UI thread's CPU (#1563)

- The 15% "UI thread at idle" was the audio thread. The engine's threads
  kept the name of the thread that started them, a Dart UI isolate, so a
  per-thread sum by name counted the audio thread (14% idle, 16% playing)
  as `io.flutter.ui`. Each engine thread now names itself
  (`le_platform_name_thread`: segno-audio, segno-midi, segno-cache,
  segno-restore, segno-prefault, segno-render, segno-drain, segno-checkpt,
  segno-fx-N), so `top -H`, `segno-prof` and `/data/bench/load.sh` read
  true. The main screen's Dart UI thread is 1.4% of a core at idle, most of
  it the 16 ms snapshot poll.
- While a loop played, every poll republished `LooperState` because the
  playhead was in it, and every listener of the state ran again. The
  playhead is now `LooperRepository.playheads` (`Playhead`), apart from the
  state as the levels are (#1301); `TransportState.masterPositionFrames`
  and `Track.positionFrames` are gone.
- Meters and playheads follow their stream through `LiveValue`
  (`LiveCubit`): each paints in its own layer, and each stops following
  while its route is covered (`TickerMode`), so the Effects page no longer
  keeps the stage under it drawing frames. The waveform's playhead paints
  over the wave in a layer of its own.
- Console, build 213 against this branch, 30 s windows, % of one core,
  Skia / Impeller: the main screen's UI thread playing 9.5 -> 4.1 /
  10.1 -> 4.6, on the Effects page 7.1 -> 2.1 / 7.7 -> 2.3; the readout's
  UI thread playing 2.1 -> 1.2 on both. On the Effects page the main
  screen's raster thread fell 7.3 -> 1.0 / 13.0 -> 2.1. Under Skia the GPU
  is busier while the stage plays (11% -> 15%): the stage's page is now a
  stable layer, which Skia's raster cache keeps and draws as an image every
  frame; Impeller has no raster cache and stays at 10%.

## November 2026 Screen capture on the console (#1555)

- `segno-capture` (segno-bundle) sends SIGUSR1 to `segno.service`'s process
  and prints one new `/data/capture/<screen>-<UTC time>.png` per screen,
  exiting 1 when a screen writes none within 5 s.
- Each engine's root sits in `ScreenCapture` (`lib/appliance/screen_capture.dart`),
  a `RepaintBoundary` rendered with `toImage` at the view's pixel ratio. The
  Dart VM hands a watched signal to every isolate group that watches it, so one
  SIGUSR1 reaches both engines (checked with two isolate groups under JIT and
  AOT on Linux arm64). Only the console watches the signal (`isAppliance()`).
- The helper reads `SigCgt` first and sends nothing while the app does not
  catch SIGUSR1, whose default action would end it. The app keeps five
  captures per screen.
- Device check owed: run it on the console under both renderers.

## November 2026 Updates page after an app restart mid-install (SEG-18, #1507)

- While RAUC writes an install whose helper is gone (`raucInstalling`), the
  Updates status panel says Installing, with the attempt's version and no
  actions, instead of a dimmed Update paused.
- The helper's `attempt` first stages an install RAUC finished on its own:
  in the boot that recorded the attempt (`update-attempt-boot-id` next to
  the marker), with RAUC idle, every inactive slot's `rauc status` entry is
  `ok` for the attempt's version and was written after the attempt began.
  The cubit asks it once RAUC goes idle, so the page lands in Ready to
  install and Restart tries the new slot. Anything else stays Update paused.
- The app asks RAUC before `recover()` at startup; Retry, Cancel, Check and
  the channel never drop the attempt while RAUC still writes it.
- `segno-ota-check` hands its install to `segno-update-ctl install`, so it
  has the busy check, the attempt marker and the staged-marker handling too.
- Device check owed: restart the app past 40 % of an install and watch the
  page go from Installing to Ready to install.

## November 2026 Power screens only when they say something (#1553)

- Saving shows only once the save has run 500 ms (`PowerCubit.slowSave`,
  `PowerState.slow`); a faster save goes straight to the goodbye. Every save
  logs `power: saved in N ms` to tune the threshold.
- Restarting shows only while a staged update installs. A plain restart is
  the bare Plymouth field on both screens (`ReadoutGoodbye.blank`), on its
  way to the boot splash.
- The Track display keeps the track display through Power options, Save As,
  a refusal, a failed save and a fast save; the pointer face and its string
  are gone.
- `segno-update-ctl poweroff` queues the halt with `--no-block` and exits 0,
  as `systemctl reboot` does, so an accepted shutdown no longer logs
  `power: helper failed`. Real failures still log.
- The power panel closes as the save starts; a fast save shows nothing but
  still takes no touch.
- Design: Penpot page 32 still shows the #1543 states; its update waits on
  the Penpot connection.

## November 2026 Power screens on both displays (#1543)

- Power options, the refusals and "Segno is staying on" rise as a 760 px
  panel anchored bottom-centre, 48 px above the edge, instead of the centred
  dialog (`PowerDialog`, `PowerPanelButton`, 84 px buttons).
- `PowerCubit` reports the save's stages as `PowerState.step` (`PowerStep`:
  playback stopped, settings saved, writing the session, finishing on disk),
  with the session it writes and the local time the write landed. An empty
  unnamed session has no session step. Save As hands the cubit its name.
- The main screen's Saving face lists the steps with a check, a spinner or a
  muted ring and a bar; Safe to switch off and Restarting name the session
  and the time, and Restarting has no icon. The Track display mirrors them
  through `PerformanceReadout` (`ReadoutGoodbye`, `savingStep`,
  `savingProgress`) in `ReadoutGoodbyeFace`, points to the main screen while
  the panel is up, and shows no Segno logo. The bundled lockup asset is gone.
- Design: Penpot page 32 (segno-design PR linked from the app PR).

## November 2026 Audio warm-up at start (#1533)

- Every start the console makes on its own opens the device as a warm-up:
  the player's rate with a 512-frame buffer (`kWarmUpBufferFrames`). This
  covers the boot auto-start, the boot-time recovery (`AudioRecoveryCubit`)
  and every reconnect by the in-repo supervisor. A first run opens as it is,
  so each try in its fallback order (48 kHz / 32, then the device's own rate
  and period, then the system default) can fail over. `LooperRepository`
  keeps the player's config as the warm-up target, so `lastEngineConfig` and
  the audio setup never show or save 512. A player's config already at 512
  skips the warm-up and owes its record offset at start (#1541).
- While warming up, the engine's master gain is held at 0. It is applied
  after everything is summed, so nothing is heard, and the remembered gain
  and the saved mix are untouched.
- Also during the warm-up: transport presses return `notReady` (as during a
  Session apply), the cable test is refused, `AppRuntime.takeLocked` holds
  (performance takes from the page and the pedal), and the stage shows
  "Audio is starting…" where the engine-stopped banner sits. The effects
  budget uses the target's buffer.
- `AudioWarmUpCubit` ticks every 500 ms while a warm-up runs. Ticks count as
  quiet only after the first rasterized frame. When the sum of the session
  window's late periods, gaps and xruns has been still for 3 s, or 20 s after
  load, it calls `finishWarmUp()`. That reopens at the player's config with
  the loops kept, under the device-change guard. What opens then owes its
  record offset (#1541, below).
- If the device refuses the player's config, the 512 config runs and is
  heard. The device page shows the existing refused banner (asked, running),
  nothing is saved, and the next replug warms up for the player's config
  again.
- Device checks owed: a cold boot and a Scarlett replug at 48 kHz / 32, with
  no xrun during or after the switch and no sound before it.

## November 2026 Record offset measured through the loopback (#1541)

- The repository owes the record offset of what it opens after the warm-up
  switch (whatever buffer the device rounded to, or the warm-up config a
  refused switch leaves running), after a start with `warmUp` that needed
  none, and after an `applyAudioConfig` that opened a config.
  `EngineStatus.recordOffsetOwed` says so; until `setRecordOffset` the master
  gain is 0 and the transport closed, and the stage shows "Audio is
  starting…" (`EngineStatus.starting`).
- `AudioSetupCubit` is the one owner of the offset. When it is owed, it sets
  the offset saved for that device, rate and buffer. With none saved and a
  loopback channel on the interface (`excludedInputMask`), it first measures
  through it under the calibration guard and saves the result under the
  `.p8` key. Otherwise it sets 0. The burst is 1e-4 (-80 dBFS) on output 1,
  timed on the loopback channels. A failure (timeout, no return, refused,
  guard busy) leaves 0, saves nothing, is logged, and the latency row says
  "Loopback measurement failed. Measure with a cable." The next owed offset
  of that profile tries again. A saved offset is never measured over, so a
  cable result always wins. `AudioWarmUpCubit` no longer touches offsets.
- Engine: Linux reads the loopback channels from the `scarlett2` routing
  (`PCM NN Capture Enum` = `PCM <n>`, through a `dlopen`'d libasound control
  handle), so the console's capture 5 (`PCM 1`) is a loopback channel and is
  excluded from recording, monitoring and routing, as on macOS. The
  detector's silence floor is now `4e-4 x amplitude` (1e-4 at the cable
  test's 0.25, as before).
- Device checks owed: delete the 48 kHz / 32 offset and reboot. That should
  measure about 292 frames with nothing audible, and a buffer change in
  Settings > Audio should measure the new profile once.

## November 2026 clear-track hold fills the pill (#1534)

- A hold that clears (Track Hold set to Clear track in Record mode, or a
  Custom pedal whose Hold is Clear or Clear all) fills the held pedal's pill
  red from both ends toward the centre over the long-press threshold (a
  Clear track hold first waits 350 ms, #1652);
  releasing early, or a hold that can no longer fire, ends the fill at once.
  When it fires the track clears and the board flashes the full red pill 3
  times (120 ms on, 120 ms off) on its own clock, then shows the empty-track
  state. A pill already red dims to about a third under a full-brightness
  fill. The newest pending clear hold fills;
  an older one fills again when the newer one settles. `ControlCubit._startClearFill` streams
  `PedalRepository.showClearHold` every 20 ms (`clearHoldProgress`).
- Wire: optional `CLEAR_HOLD` (`0x13`, two bytes), console firmware 2.6. The
  protocol stays 12, so firmware 2.5 and older keep working and show no fill.
  The board drops a fill not refreshed for 500 ms.
- No screen mirrors the LED pill: Record mode draws no pedals, and the Custom
  face's Pending Hold bar already times the same hold.
- While a clear hold's fill runs, the held pill's base is its own state
  colour (green playing, red recording) instead of the pressed colour
  (`projectPedalLights(clearFilling:)`), so a recording track gets the
  dimmed red. Other holds and plain presses keep the pressed colour.
- Device check owed: the fill's and the flash's look and timing on the
  console.

## October 2026 Ed's setup loop template (#1513)

- Library > New loop asks **Start with: Empty tracks | Ed's setup**. Ed's
  setup starts the new loop as Empty tracks does, then puts one Ed's Rack
  sound on tracks 1 to 4 (Acoustic Rhythm 1, Boom Dry, Bass Octave 1, Vocal
  Close), drops their lane chains, and names them Guitar, Boom, RC20 and Vox.
  Plan: `docs/plan/2026-10-29-feat-eds-setup-loop-template-plan.md`.
- Each rack holds only the pedals its preset turns on, so all four fit the
  96 kHz effects budget (`fxRackEntries(onlyEnabled:)`, `fxFactoryRack`, the
  one rack builder the Effects library also uses). The sheet checks the
  budget and `SessionCubit.newLoop(template:)` checks it again on the chains
  as they are once the take has ended (`SessionError.templateDoesNotFit`).
- Track names stay global settings: the sheet says so and names the custom
  names it replaces. `TracksCubit` is owned by `AppRuntime` so New loop can
  write them; a failed write is `SessionState.trackNamesNotSaved`.
- The racks are Post, heard on playback only, like every track rack. No
  footswitch is bound. Penpot page 19, cards 07 and 08.

## October 2026 RAUC status off the FAT boot partition (#1397)

An unclean power-off twice left a broken cluster chain in RAUC's
`/boot/rauc/central.raucs`. The kernel remounted the FAT `/boot` read-only and
every install failed. RAUC's `data-directory` is now `/data/rauc` on ext4, and a
`rauc.service` drop-in requires the `/data` mount. RAUC creates the directory
itself when it starts.
`boot.mount` pulls in `systemd-fsck@` for its device, so `fsck.vfat -a` repairs
the partition before it mounts and logs what it changed to the journal.
`segno-update-ctl install` exits 3 when `/boot` is read-only, and the Updates
page then tells the player to restart, with a Restart button through the power
flow, instead of reporting a failed download.

Shell tests cover the helper under bash and dash, and a static test covers the
RAUC and fsck wiring. Dart tests cover the env, cubit and page. Device checks
are owed: `rauc status` reads the new file, the boot journal shows the fsck
unit, and an install followed by mark-good succeeds. Existing units start with
an empty status file. The old `/boot/rauc` directory stays: a rollback to a
build older than this change still keeps its status there.

## October 2026 Clear history and Fade (#1142)

Clear and grouped Clear now retain the Fade amount applied at the audio boundary;
Undo restores stationary levels before playback, with ordinary mute and frozen
history preserved. Performance capture records exact restored material through
its existing staging and renderer owners. Invalid source transitions fail their
derived stems while the independently recorded master remains usable.

The [review](code-review/fade-clear-history/review.md) records the native safety
matrix, six actual-native repository tests, all 187 FFI symbols, package coverage
and independent source reviews. Production adds 323 lines and removes 108, with
no additional state owner. General history replay (#1143), whole-render manifest
errors (#1144), reopen (#1140) and Fade controls remain separate work. Actual
Claude, published-head CI and human merge gates remain pending independently.

## October 2026 stationary Session Fade (#1139)

Sessions now save recorded tracks' current Fade amounts and restore them as
stationary levels before publishing stopped playback. Material finalization and
all Fade confirmations complete first; rejected or retired imports are cleaned up.
The implementation extends five existing production files without another owner
or native API. Exact Session schema 11 requires the saved amounts.

The [review](code-review/session-fade-levels/review.md) records 3,166 passing app
tests, 716 ordinary Looper tests and 116 Session tests, plus 21 actual-native
focused checks. Coverage floors, analysis, formatting and positive Bloc lint pass.
Independent review repaired two test issues without production changes. Claude,
published-head CI and human merge remain separate gates. Full-engine reopen
retention (#1140), Clear/history and public Fade controls are separate follow-ups.

## October 2026 Fade duration persistence (#1137)

Fade defaults and explicit per-track durations now survive startup and Session
save/recall through one settings writer. Failed writes restore the previous
record or require explicit recovery. Incoming Session settings finish before
the existing boot barrier releases; an active fade keeps its original rate.

The [review](code-review/fade-duration-settings/review.md) records 3,162 passing
app tests (49 conditional skips), 198 settings tests and 114 Session tests, with
all applicable coverage floors met. Analysis, formatting and 811-file Bloc lint
pass. Independent reviews are clean after bounded fixes. Actual Claude,
published-head CI and human merge approval remain separate gates. Coefficient
recall/reconnect, Clear/history and Fade controls are still separate follow-ups.

## October 2026 stopped Session recall (#1134)

Session recall now publishes recorded tracks stopped, with timing and crown
preserved, and keeps ordinary transport edits blocked until saved settings finish
applying. Explicit Play starts the recalled material. Unavailable audio devices
are rejected before destructive work; settings-only empty loads still work.

The [review](code-review/stopped-session-recall/review.md) records the local gates:
3,142 app tests, 715 ordinary Looper tests, 112 Session tests and 356 Engine tests
pass; coverage meets every affected floor. Native safety configurations, FFI,
analysis, formatting and positive Bloc lint pass. Independent reviews are clean;
Claude review, published-head CI and human merge approval remain separate gates.
This prerequisite does not complete Fade duration or Session persistence.

## October 2026 native track Fade (#1131)

The native Fade capability now has independent per-track envelopes, confirmed
callback results and matching performance-log rendering. It changes neither
saved Mixer gain nor recorded PCM. Existing playback remains at full Fade level;
user-facing control and durable Session/reconnect composition are separate parts.

The [review](code-review/foot-fade-native/review.md) binds the candidate and its
checks: native standard, sanitizer, telemetry-disabled and C++17 pass, as do all
187 FFI symbol lookups. App tests pass 3,137 cases at 92.634% coverage; ordinary
Looper coverage is 95.136%, with four additional actual-native Fade tests.
Analyzer, formatter and 806-file Bloc lint pass. Independent reviews repaired a
Session-retirement receipt leak and have no remaining actionable finding.
Actual Claude review, published-head CI and human merge remain separate gates;
no appliance validation or deployment is claimed.

## October 2026 recording-start pair (#1026)

Count-in and Sound-start now share one confirmed setting across Recording,
Tempo, both Audio setup surfaces, startup and Session save/recall. Count-in
above zero disables Sound; enabling Sound turns Count-in off. Explicit Off
remains Off, while a new setup defaults to one bar. Capture refuses edits;
unknown or failed acceptance stays visibly unavailable until recovery.

Storage writes preserve exact prior keys on failure, and native callback
receipts confirm changes before publication. Fresh recordings wait for a
confirmed pair; cancellation and finishing remain available. Sound-start
requires a usable selected input before arming and reports the affected track
when one is missing. Session save and shutdown wait for settlement.

The [part-one plan](plan/2026-10-03-feat-count-in-part-1-plan.md) defines this
boundary. Native standard, sanitizer, telemetry-disabled and C++ checks pass.
Independent tests caught and repaired a countdown-cancellation ordering defect.
The saved Pen section contains five checked native captures. The full app
passes 2,789 tests at 91.927% coverage; all five affected package suites meet
their required gates. Static checks cover 763 Dart files, and independent review
has no unresolved finding. A bound native desktop build passes the paired
Count-in/Sound interaction and all 182 FFI symbol lookups. Exact-head CI and
human merge remain separate. Shared launch countdowns and mapped
Count-in are the next two parts; they are not implemented by this part.

## October 2026 shared Hear click (#1026)

Touch, encoder, MIDI and External controls now share Off, First recording,
Recording and Play & record. New setups default to First recording; explicit
Off is preserved. Native callback receipts confirm changes before publication.
Recording and overdubbing refuse edits without stopping audio. Session Save and
restart retain Released values while Held remains audible, and safe shutdown
waits for owed releases or presents recovery.

`docs/reviews/shared-hear-click/` binds the candidate and independent evidence.
The app passes 2,611 tests at 91.069% coverage; Looper passes 691 at 95.261%.
Engine passes 352 against the repaired native library. Native configurations,
affected package suites and 757-file static checks pass. Independent review
closed callback publication, command counter width, obsolete initialization,
recovery readout and compensated-flush defects. Author renders include the
repaired expression choice layout. The saved Pen section has passed its final
composite visual check. Native desktop interaction still needs verification
against a bound build. Published-head CI and human merge remain separate.

Count-in and its Sound-start interlock are next. The future capture journal must
extend the capture lock before stopped failed-finalization takes ship; no such
producer is implemented by this slice. M5 full live-Control Session Load and
physical appliance checks remain open.

## October 2026 shared Record timing (#1026)

Touch, MIDI and External controls share the seven recording-timing choices for
Loop defaults and fixed Tracks 1–8. Explicit Immediately remains Custom; null
restores inheritance. Waiting requests can be rescheduled or cancelled without
changing unrelated arms. Capture refuses edits without stopping audio. One
native vector and coherent receipt replace the split timing writers; record
acquisition is fenced before plugin, layer or history preparation.

Held timing stays live while Save/restart retain Released intent and remembered
division. Exact rollback preserves absent settings. Shutdown refuses unfinished
release cleanup; Retry and Keep playing retain their distinct recovery behavior.
The shared owner composes startup, session capture and the existing settings UI.

`docs/reviews/shared-record-timing/` binds the implementation, independent review,
tests and saved Pen references. Full app: 2,552 passed at 90.989% coverage; Looper:
675 passed at 95.344%. Native variants, snapshot/preparation negative controls,
affected independent replay, Engine/Settings/Session/Performance packages and
748-file static checks pass. Author-only renders and native desktop interaction
are recorded separately. Published-head CI, human merge, appliance verification
and M5 full live-Control Session Load remain separate gates. Hear click is the
next bounded shared-control slice.

## October 2026 shared Record length (#1026)

Touch, MIDI and External controls now share Auto/1–64-bar choices for Loop
defaults and fixed Tracks 1–8. Explicit Auto stays Custom; Multi retains latent
track overrides. Capture blocks edits without stopping audio. Held values stay
live while Save/restart preserve Released choices, and refused cleanup retries
when safe. Startup and shutdown require confirmed state or explicit recovery.

`docs/reviews/shared-record-length/` binds 88 source/test/render paths and saved
Pen references. Ordinary app checks pass 2,729 results at 91.0011% coverage;
Looper repository passes 693 at 95.5842%, Settings 171 at 90.3498%. The 44-case
independent matrix and receipt-bypass negative control pass their expectations.
Native configurations, native-backed fuzz and 741-file static checks pass.
Review repaired startup Retry, raw endpoint cancellation and a clipped lock
label. Published-head CI, human merge, physical proof and M5 live-Control full
Session Load remain separate. Shared Record timing is the next bounded slice.

## October 2026 shared Playback Loop or Once (#1026)

Touch, MIDI and External controls now share confirmed Loop/Once choices for
Loop defaults and fixed Tracks 1–8, including empty tracks and all five modes.
Explicit false remains Custom. Use default supersedes older held cleanup;
Save and reconnect preserve authored Released values. Startup validates all
nine stored choices and verifies the eight native bits. Shutdown drains pending
changes and offers recovery instead of losing them.

`docs/reviews/shared-playback-choice/` binds source and saved Pen references.
The final app suite passes 2,666 results at 90.7948% coverage; Looper repository
passes 686 at 95.7472%. Settings and Controller results are reused only for
unchanged sources. The independent 50-case matrix covers all native modes, and
an isolated receipt bypass fails the expected pending assertion. Strict static
checks cover 733 Dart files. Review caught and fixed startup-validation Retry
and reconnect-readiness defects. Exact-head CI and human merge approval remain
separate; hardware proof and M5 live-controller full Session Load remain open.

## October 2026 shared overdub decay (#1026)

MIDI and External button/expression controls now share the Playback owner for
Loop defaults and fixed Tracks 1–8. Explicit zero remains Custom; Use default
removes only that field and supersedes older held cleanup. Storage is verified
before acceptance. Sessions/restarts retain Released intent, and shutdown waits
for pending changes and refuses on unresolved recovery.

`docs/reviews/shared-overdub-decay/` binds the source, saved Pen references and
local evidence: 2,617 ordinary app results at 90.7010% coverage, three affected
package suites, 51 independent probes, a native-sample negative control, eight
native session cases, standard native suites and clean strict static gates.
Startup replay and stale-error defects found during review are repaired. CI on
the published head and human merge approval remain separate. Hardware and the
inherited complete session-load defect with a live controller owner remain
explicit follow-up work.

## October 2026 shared Click volume (#1026)

Click volume now shares one confirmed owner across touch, MIDI and External
buttons/expression. The same linear range appears as 0–200%, with unity at
100%. Temporary held values do not enter saved sessions or engine restart
intent. Settings and native acceptance are checked; explicit recovery keeps
old failures separate from replacement sessions. Shutdown retires controls,
waits for settings and stays on after a failure with Retry or Keep playing.

The [verification record](reviews/shared-click-volume/verification.md) binds
83 intended files, 55 independent native-backed probes, ordinary app coverage
of 90.4296%, affected package gates and strict static checks across 714 Dart
files. Four native references are saved in Pen. Earlier failures and repairs
remain documented. No native/FFI or firmware source changed. Published-head
CI, human merge and physical device validation remain separate. Shared decay
and the remaining loop targets follow; the M5 live-owner session-load issue
is still open.

## October 2026 shared Mixer controls (#1026)

MIDI and External assignments now share eight typed Mixer control families,
actual-unit endpoint readouts and one confirmed durable transaction. Input
monitor level remains separate from recording trim. Missing targets retain
their identity; source retirement and topology replacement preserve newer
accepted changes. Session capture saves Released values while a control is
held. Four new native references are saved in Pen.

The [verification record](reviews/shared-mixer-controls/verification.md)
records 2,525 ordinary app tests at 90.0054% coverage, 30 controller tests at
83.2237%, static checks across 706 files and 52 independent native-backed
adversarial probes. Failed prior cases and repairs remain documented. No
native API or firmware changed. Click/loop targets follow next. Broader live
session-load publication remains tracked for M5; physical controllers,
published-head CI and human merge are separate gates.

## October 2026 MIDI reconstruction (#1026)

MIDI setup now selects explicit message formats, learns stable sources and
edits multiple action or value targets through the shared control owner.
Save/Cancel, source overlap, missing-target repair, pause/retry and session
replacement preserve confirmed state. Pending effect writes and momentary
restoration join the session/shutdown persistence barrier. Obsolete MIDI
bindings and the old editor are removed.

The [verification record](reviews/design-midi-controls-restack/README.md)
records 2,433 passing application tests, nine package suites, native checks,
coverage, independent review and adversarial probes. Native renders are saved
in Pen. The broader shared target catalogue remains the next M3 slice;
physical MIDI validation, published-head CI and human merge stay separate.

The first MIDI publication passed tests but failed ordinary CI coverage at
89.07%. A reviewed test-only correction adds 23 editor journeys. The matching
local run excludes author screenshots and supplies no native library: 2,306
tests pass at 90.0039% coverage, with static gates clean. All 20 workflow jobs
and GitGuardian subsequently passed on PR #1047 head
`06633b2b537efba4c59108e38764e58c0b2c542e` (run 36935129976). The current-head
review is clean; human merge and physical MIDI validation remain separate.

## October 2026 external pedal reconstruction (#1026)

Single, Dual and Expression now share a confirmed External setup and the
existing UART CTRL ingress. Multiple actions, FX activation, parameter ranges,
directed calibration, unavailable-target repair and independent jack profiles
are implemented. Source retirement and refused release cleanup preserve newer
accepted controller contributions; the old generic console editor is removed.

The [verification record](reviews/design-external-controls-restack/README.md)
binds the final source, 2,467 passing app tests, five package suites, coverage,
firmware and 54 independent adversarial probes. Source and five quality-role
reviews have no unresolved actionable finding. Native render references are
saved in Pen. Published-head CI and human merge remain separate gates; physical
pedal validation is not established by the desktop checks. The MIDI slice above
builds on this verified dispatch foundation.

## September 2026 design-stack reconstruction (#1058)

The accepted Tracks, selected-track display and crown slice (#1010 / #1011)
is reconstructed on current master, retaining its UART console and appliance
lifecycle. Review corrected full-track waveform coordinates, stopped-waveform
retention, divided/independent bar counts, and compact desktop Wave layout.
See the [slice ledger](plan/2026-09-09-segno-implementation-ledger.md) and
[validation record](reviews/design-tracks-restack/validation.md). The remaining
stack is still pending reconstruction; no appliance deployment is implied.

## October 2026 Loop settings reconstruction (#1012)

The Loop settings slice is reconstructed on the verified recording-timing
stack. Default and per-track choices retain field-level inheritance, including
explicit Auto and Loop overrides. Length and mode requests submit one bounded
engine command and publish or save only the callback-confirmed result. Startup,
recall, timeout and device reconnect use the same confirmed state boundary.
Touch and keyboard focus cover edit, commit and Cancel; obsolete Loop and
coarse timing controls are removed. See the
[validation record](reviews/design-loop-settings-restack/README.md).

Follow-tempo/pitch processing remains explicitly unavailable until its engine
slice. Physical encoder routing remains in the controller slice; desktop focus
checks do not establish UART or appliance behavior. No deployment is implied.

## October 2026 FX surface reconstruction (#1016)

Effects now uses the accepted destination/library/editor flow on the verified
mix, routing and Pre/Post stack. Adding a single or rack opens its confirmed
new instance directly. Structural edits retain stable identities, reject full
destinations and cannot complete against a replacement session. Saved presets
retain rack identity and create independent instances. The obsolete Signal
surface and its unused cache controls are removed.

Native, package and app checks plus independent source and visual reviews are
recorded in the [verification record](reviews/design-fx-surfaces-restack/README.md).
Exact factory parameter/DSP completion remains M6 work; physical appliance
validation and the human merge gate remain separate. No deployment is implied.

## October 2026 pedal gesture reconstruction (#1026)

FX assignments now carry separate Press/Hold targets and explicit fixed or
selected-track scope, using the existing UART control owner. Holds resolve
selection when they fire and retain that target until release. The accepted
800 ms default is shared with Settings; normal Record/Play and Stop remain
immediate. Session changes, take locks and disconnects invalidate pending
work without applying it to a replacement session.

Refused momentary restoration waits for callback readiness, removed effects
do not strand a pedal, and LEDs follow the successfully dispatched action in
the correct bank. The
[verification record](reviews/design-assignments-restack/README.md) separates
independent behavioral checks from physical pedal validation. Layout A setup,
Custom mode and external/MIDI assignment surfaces are the next dependent
slices. No appliance deployment or human merge approval is implied.

## October 2026 Custom pedal runtime (#1026)

Layout A now edits and runs Custom Press/Hold assignments. Mode exits and Bank
pages; fresh Mode defaults to Mute/Custom. Gesture lifetime follows accepted
selection, session and connection rules. Grouped Solo shares the app-wide mix
coordinator, and Clear/Restore preserves unrelated setup edits. See the
[verification record](reviews/design-custom-runtime-restack/README.md).

Application and independent behavioral checks pass. Configurable physical LED
colors and all-ten activity transport are the next slices; no appliance
installation or human merge approval is implied.

## September 2026 PCB routing completion

**September 28 Revision P completed: H1 ground-contour cleanup.**
Claude removed two obsolete front-ground exclusions beside H1 that caused
notches in the rounded copper boundary. All traces, vias, pads and placements
remain unchanged. Strict checks pass: zero ERC/DRC findings, 123 fault controls,
415 screen fabrication comparisons and 175 unchanged console/ring comparisons.
The conservative copper-loss model is 15.93 mV, below the retained 20 mV
allowance. Independent source/export review is clean, with earlier full circuit
reviews retained for unchanged scope. The owner confirmed
that the available cables physically reach; conductor gauge, insulation,
shielding and assembled USB performance remain separate. A fresh full Mouser
quote shows all 55 lines / 192 units available at the check, with $69.81 parts
and $9.94 estimated tariffs. The matching shared cart adds $8.49 selected
UPS Ground shipping, totaling $88.24 before tax; final address and tax are
not entered and no purchase was made. See the
[Revision P review](reviews/screen-power-ground-cleanup-1072/review.md).

**September 28 Revision O completed: fully removable USB shields.**
The four screen-board USB headers now use XH5, with pin 5 carrying the shield
to GND and no separate soldered tether. Local placement and rounded power
routes clear the longer headers; the two-layer outline, power circuit and
292 USB copper items are retained. Fresh checks pass: zero ERC/DRC findings,
123 deliberate faults, 415 screen manufacturing comparisons and 175 unchanged
console/ring comparisons. Conservative copper loss is 15.93 mV below its
20 mV allowance. The final populated review also corrected a hidden CTRL label.
Five independent local roles and the bounded model review completed without
unresolved findings. Claude helped author the change, then reached its limit;
there is no new Claude approval of Revision O. See the
[current review](reviews/screen-power-xh5-1072/review.md) and
[manufacturing identities](reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
The combined Mouser import is 55 lines / 192 units, estimated $88.22 before
tax with only changed connector/contact prices freshly checked. Current-head
CI and assembled USB/enclosure qualification remain separate; no order,
merge, flash or deployment occurred.

**September 28 Revision N all-three-board adversarial review completed.**
Claude's console continuation returned a successful final verdict after the
reset, closing the last outstanding review. All three Claude and DeepSeek
passes are now complete, with no unresolved actionable PCB finding. The
console pass verified unchanged production identities, reviewed the committed
assembly/wiring corrections and closed the screen-side GPIO17 default-off
coverage gap. Unchanged prior full-review evidence is explicitly retained;
no claim is made that every model reread every unchanged file. See the
[completed coverage and disposition](reviews/pcb-revn-adversarial-1072/review.md).

The audit corrected the obsolete Rev M order selection, external-fuse and
negative-gate-driver instructions, and old wiring budget. Ring USB programming
keeps AUX and the separate strip feed off until USB is removed and J1 restored.
No native board, BOM, circuit or Gerber ZIP changed during this closeout.
The exact files retain their passing native/CAM evidence and are accepted
for bare-board fabrication. The final review hold is lifted; current-head CI,
assembled qualification, enclosure mounts and runtime installation remain
separate. Nothing was ordered, merged, flashed or deployed. Earlier review
entries below are historical.

**September 28 Revision N and copper-finish review.** The screen board now
uses a stocked Omron power relay and coil driver, one removable 8 A input
fuse in a PCB holder, and four soldered branch fuses. The consolidated Mouser
US quote is $86.56 estimated before tax including tariffs and shipping;
all 53 lines / 168 requested units were available at the final recheck.
The screen copper audit removes the AUX stub, redundant via extension and
pointed ground ends; two ring front-ground dead ends are removed. Console
copper, ring tracks/pads/rear ground and all 292 USB copper items/18 anchors
are retained. All three boards remain two layers and hand-soldered.

Final DRC is zero/zero on all three boards; screen ERC is zero and all 103
screen fault controls pass. Exact final filled-copper calculation gives
12.760–13.158 mV nominal loss and 15.366 mV in the thinner-material sensitivity
against the retained 20 mV allowance. Independent native/CAM comparison
passes 175 console/ring and 415 screen assertions. See the
[Revision N review](reviews/screen-power-stock-cost-1072/review.md),
[bug-focused gate](code-review/pcb-stock-cost-1072/review.md), and
[current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
Claude's September 27 verdicts below cover the preceding design; no new
Claude approval is claimed for N after its service failures. Independent
local roles and bounded DeepSeek component review cover the new work.
The planning AUX load is 7.818 A with normal pills and the full-white 40-pixel
strip using its direct harness. Assembled qualification, full current-head CI
and runtime/enclosure integration remain separate. Nothing was ordered,
merged, flashed or deployed. Earlier entries below are historical.

**September 27 final Claude review completed.** All three saved sessions now
returned completed final verdicts on design revision
`60ff3a637a400deb1ce846f6cb76979c94250a32`, with no open actionable board defect.
The screen's additional manufacturer-source follow-up also completed, closing
its two direct-read gaps. See the [completed verdicts](code-review/pcb-claude-followup-1072/claude-review-status.md).
No further design, routing, BOM or executable firmware changes were required.
The stale auxiliary console DRC report was rerun: zero violations/unconnected
pads, date-only report change. All 97 production inputs and the three native/ZIP
identities are preserved. The documentation release adds the final review
records and their hashes to the manufacturing manifest. Assembly qualification,
runtime/enclosure integration and current-head CI remain separate; nothing was
ordered, merged, flashed or deployed. The earlier interruption below is history.

**September 27 Claude follow-up: verified circuit and assembly corrections.**
The [current correction review](code-review/pcb-claude-followup-1072/review.md)
resumes all three saved Claude reviews and independently adjudicates their
findings. Screen R2 is 4.7 kΩ, 1%; ring C2/C3/C4 are 10 nF, with hand-soldering
thermal relief and a separately specified 1000 µF strip-entry capacitor.
Console R11/R12 now use Pico 3.3 V, and CTRL pin 4 uses the jack's RN contact.
Claude authored the native changes. Independent review caught and closed a
new 0.3 mm console supply segment; the final connection is uniformly 0.6 mm
with a native rounded bend. No component placement or outline changed.

Fresh final native DRC is zero/zero on all three boards. All 77 screen self-test
checks, 24 console circuit controls, 15 layout controls and the retained
power guards pass; ring source/encoder controls pass 8/13 cases respectively.
Independent current CAM comparison passes 175 console/ring and 412 screen
assertions. All boards remain two layers. Current runtime is #1082 at
`53828fc4eae1c18af45abfc3ea7c31f19f9799d7`; its latest three documentation changes
match RN wiring without changing behavior, and all eight firmware suites pass.

Claude completed its initial reviews and applied the final CAD correction,
but its usage limit interrupted the last follow-up verdict; no final Claude
approval is claimed. See the [exact review coverage](code-review/pcb-claude-followup-1072/claude-review-status.md).
Only the [current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json)
identifies order files. Bare-PCB acceptance does not complete runtime/enclosure
integration, assembled qualification or current-head CI. No order, merge,
flashing or deployment occurred. Earlier paragraphs below are historical.

**September 26 repeat production review: encoder and UART corrections.**
The [fresh all-three-board review](code-review/pcb-final-repeat-1072/review.md)
found and closed the ring encoder part/footprint mismatch and the console A2
UART resistor margin. The selected encoder is Same Sky ACZ11BR1E-20FD1-20C,
with its exact threaded-part footprint and separately sourced mounting nut.
Console R18 is now 6.8 kΩ, 1%; console copper is unchanged. The former ring ZIP
is withdrawn. Screen Revision M copper is unchanged, with freshly regenerated
exports and input hashes. All three boards pass native ERC/DRC, and independent
CAM comparison passes 175 console/ring and 412 screen assertions. Independent
correction reviews and the completed DeepSeek follow-up close the findings.
The new-board encoder direction/bounce fix is separately pushed in runtime
#1082 at `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`; nothing was flashed.
Use only the [current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
This supersedes the earlier statement that console/ring inputs were unchanged.
Bare-board CAD/CAM acceptance does not establish assembled USB, enclosure or
runtime qualification; full CI remains unavailable on the stacked feature base.
No order or merge occurred.

**September 26 USB correction: Revision M CAD and manufacturing files pass.**
[Revision M](reviews/screen-power-usb-revision-1072/review.md) replaces the
host-powered relay coils with AUX-powered coils and per-host low-current
presence detectors. Claude authored the placement/routing correction, with
local native KiCad checks closing the remaining copper and silkscreen faults.
The complete rebuilt board has zero DRC, unconnected or ERC findings; all
75 fault-detection controls, 50 component models and 6,264 USB ground-reference
samples pass. Independent comparison passes 412 manufacturing assertions.
Four shield-drain pads retain the XH4 cable interfaces, with documented local
cable construction. The 0.78/0.23 mm USB pairs retain matched paths; the
coated-field estimate is about 90.8 ohms, while ordinary two-layer fabrication
still has no impedance guarantee. The corrected AUX planning budget is
7.708 A with a full-white 40-pixel ring and normal pills.
Use the [current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
Revision L screen Gerbers remain withdrawn; console/ring files are unchanged.
This closes bare-board CAD/CAM correction, not assembled USB qualification,
whole-PR CI or a merge. No order or device deployment has occurred. Earlier
screen completion text below is historical.


The [final production review](reviews/production-final-1072/review.md) supersedes
the earlier release checks below. It reviews the complete circuits, all three
native boards, wiring, current budgets, thermal estimates, mechanical envelopes
and exact manufacturing exports. It corrects sub-minimum silkscreen dimensions,
selects the actual 40-LED strip in the purchasing BOM, removes old ring wiring
instructions and names the separate v3 runtime needed for A2 presence inputs.
Console and ring USB-programming isolation is now explicit. The screen's
proposed enclosure location still needs its floor holes incorporated in the
enclosure release; this does not change the fixed PCB outline. No order, merge
or deployment is part of this review.


The September 26 final PCB review additionally replaces the selected 40-pixel
ring's straight-through power harness with a direct AUX star feed near the strip.
Only DIN uses carrier J2; console J6 carries only the two UART wires. This closes
the hot-wire/aged-contact voltage-margin gap without changing PCB copper. See
`docs/reviews/production-final-1072/ring-voltage-margin.md` and the current wiring.

The September 26 [all-three-board audit](reviews/pcb-finish-all-three-1072/audit.md)
records the current native boards and replacement manufacturing archives.
The final pass rounds the remaining exposed signal/control bends as well as
the power routes, closes the console's 0.05 mm slot beside J24, retains the
ring's two straight vertical taps and moves C20 beside its supply pin.
Screen C4 is aligned with the charge-pump pin. A subsequent
[U1/U2 alignment correction](reviews/screen-u2-alignment-1072/verification.md)
puts both packages on common pin rows while preserving their stock courtyards.
USB pairs use mirrored rounded bends with their widths, gap and ground
reference verified independently.
The Q3/Q4 source bridge and drain feeder remain uniformly 2.5 mm wide and
the AUX input remains 2.0 mm. All boards retain two copper layers.
Work follows the owner's one-order requirement, with no pre-PCB prototype
or new owner measurement campaign. The
[gate-drive assessment](reviews/screen-power-rev-l-1072/gate-drive.md) supports
an LMC7660/TLP627M negative gate supply and lower-voltage TN0702 relay drivers;
the [startup assessment](reviews/screen-power-rev-l-1072/startup.md) does not
establish a need for active current limiting. Claude Cloud authored placement
and explicit routing changes; independently reviewed local corrections finished
the remaining geometry after its session became inaccessible. Final native
DRC is zero/zero on all three boards, and screen ERC is clean. All 56 screen,
11 console-power and 7 ring-power fault controls pass, along with 13 native
rounding regression cases. Fresh export comparison passes 409 screen and
175 console/ring assertions. DeepSeek's completed source review has no
unresolved verified finding. The [current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json)
supersedes earlier Revision L artwork and exports. This is bare-board CAD
and manufacturing-file acceptance; assembled operation, whole-PR review and
CI remain separate gates. Earlier Revision K evidence below is historical
and does not qualify the changed circuit.

September 25 screen-power correction: **Revision I screen Gerbers are withdrawn**.
The [independent Claude review and assessment](reviews/screen-power-claude-1072/assessment.md)
confirmed that relay commons 3/6 were floating: upstream data used normally
closed contacts 2/7, so neither USB touch path could conduct in either state.
Revision J corrects that pinout, retains normally open contacts 4/5, and adds an
independent contact-state regression guard. It also widens MOSFET necks to 1.9 mm
and the C2 feed to 1.5 mm, with three dedicated shared-power stitching vias.
Checks and replacement exports are recorded in the
[Revision J verification](reviews/screen-power-rev-j-1072/verification.md).
Revision K retained that correction and superseded J.
It introduced short 1.9 mm MOSFET approaches, a full 3 mm central bridge and gradual
transitions into the 4.5 mm distribution rail. Correct BOM-sized capacitor
models replace undersized previews, and C1 moves 1.5 mm to clear the mated
power plug. The system wiring diagram now routes both screens through this
board, specifies the main-power leads and accounts for the full AUX/PD budget.
The [Revision K verification](reviews/screen-power-rev-k-1072/verification.md)
records that historical package; the current revision status is above.
No additional owner measurements are prerequisites for bare-board fabrication.
Earlier screen-board readiness claims below are historical and superseded.

The [completed Claude cloud review](reviews/screen-power-rev-k-1072/claude-cloud-assessment.md)
found no verified K circuit/artwork defect and recommended first-prototype
fabrication. The [implemented follow-up](reviews/screen-power-claude-fixes-1072/verification.md)
specifies an exact external screen-branch fuse/holder, includes its voltage
drop in the conditional gate-drive calculation and replaces R8's approximate
assembly model. Circuit values and manufacturing artwork remain unchanged.
The fuse adds harness protection, not guaranteed MOSFET fault survival;
assembled operation still needs the documented qualification.
That historical package's OpenCode Go reviews were incomplete after provider
limits. The completed Revision L DeepSeek review is recorded separately in the
[current external review](reviews/screen-power-rev-l-1072/external-model-review.md).

Revision L retires the historical 6 A expansion allowance. Its screen planning
load is 4.25 A including both main outputs, both touch outputs and the bleeder;
the 3 A main and 500 mA touch branch ceilings are not additive guarantees.
The separate full-white ring, normal pills and console bring the AUX budget
to 7.608 A. Expected screen loads support upright Q3/Q4 without heatsinks under
the documented thermal estimates. Connector positions, the 68 × 76 mm outline,
purple mask and two copper layers remain unchanged. The
[screen-board notes](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/kicad/screen_power/README.md) give the current
parts, wiring and post-assembly acceptance checks.

September 25 update: the owner requested unrestricted full-white operation for
one 40-pixel ring strip. The console and ring carrier now have dedicated wider
power paths, sized independently of firmware brightness. Board outlines,
placements, two layers, 1 oz copper and purple-console/white-ring colours remain.
That full-white change left the screen-power board unchanged. The
[full-white fabrication review](reviews/ring40-full-white-1072/verification.md)
supersedes the earlier 24-pixel/current-limited power assessment and order ZIPs.
It preserves first-assembly validation and the separate 10 A whole-system limit.

Publication is split by hardware generation. This branch includes the screen
power PCB, console connectors and power-domain corrections, white XIAO ring carrier (module footprints or external strip), and GPIO17 lifecycle service. The current old-console
ten-pill/40-LED-strip firmware is tracked separately under #1076 and #1077.
New-v3 console/ring firmware and PD diagnostics are published separately in
PR #1082 at `92af127d`; they remain an integration draft and are not code
included in this hardware publication. See the [publication record](reviews/hardware-publication-1072/verification.md).

The populated screen-power board has a proposed position behind CLEAR, left of
the buck pair, on 15 mm standoffs. Four floor mounts still need to be integrated
and actual harness/assembly fit checked; the CAD placement is not a physical
fit test. See the [placement study](reviews/pcb-completion-1072/screen-power-placement.md).

The historical September 24 order package included all three designs: console,
screen power and ring; its Revision I screen Gerbers are now withdrawn. The ring
carrier now uses white solder mask and black
silkscreen, with larger J1 and module-support holes. Its routes and placement
are retained; refilled-zone DRC has zero violations or unconnected items, and
all 63 connected pads match the circuit. See the
[ring order verification](reviews/ring-order-ready-1072/verification.md).

The console and ring boards for #1062 / PR #1066 now carry the wider power
rails in their routed files and manufacturing exports. Both pass full-severity
KiCad checks with zero violations and zero unconnected items, and exact circuit
netlist parity. See the [routing verification](reviews/routing-1062-2026-09-21/verification.md).
The PR remains open and hardware validation is still required. Screen power
switching has completed prototype CAD under [issue #1072](https://github.com/tomassasovsky/segno/issues/1072).
Revision E retains **hand-soldered assembly only** and removes the factory
variant. The new 64 × 76 mm board uses 19.6% less area than revision D's
72 × 84 mm hand board, with the same 37 populated through-hole parts and
four M3 mounting holes. All populated parts have portable STEP models.
Revision F added 3 mm rounded corners and a complete component cost estimate.
Revision G implements the requested two-layer board with purple solder mask.
Its 68 × 76 mm outline gives the power rail space beyond the USB connectors;
the two right-hand mounting holes move 4 mm with that edge.
Revision H aligns all eight keyed connector housings and vertical pin rows,
rotating the four two-pin headers and rerouting their connections.

Four-pin JST XH data connectors retain the selected direct USB-A / USB-C /
Micro-USB leads and pin map: 1 = VBUS, 2 = D−, 3 = D+, 4 = GND. Separate
screen-power leads retain two-pin JST VH connectors. The 28 AWG data leads
are not specified for the screens' full power loads; suitable main-power
leads and their final termination remain to be selected.

The control section is more compact, power enters at the upper-right edge,
and the two USB paths stay straight. Main power uses a wide
front-side rail at the right edge; USB stays on bottom copper without data
vias, with filled front-side ground underneath. Both outer faces have ground
pours; the board has no inner copper layers. The existing Pi-to-console ribbon remains direct; console
J25 carries GPIO17 and GND to screen J2. Console PD connector J23 now aligns
with RING J6 and screen-control J25 on one row. Its 0.8 mm move updates the
local PD/ground connections and clears two adjacent switch traces. PI PWR J9
now sits beside the ribbon on that same row, with PWR BTN J8 kept in place.
R2 turns horizontally below the buffer and R18 shifts 0.15 mm to clear the
existing PI PWR label. The floating button pair and affected signal routes
are complete; KiCad reports zero violations and zero unconnected items.
The underside screen pinout text is replaced by a top-side `SCREEN` label.
At that earlier placement review, ring routing was unchanged and the LED budget
was 1.44 A plus controller; the full-white review above supersedes that budget.
Its 3 A JST XH rating still requires 22 AWG power and ground leads.
See the [console placement verification](reviews/console-pi-power-placement-1072/verification.md)
and the [interface pinout](reviews/console-screen-connector-1072/verification.md).

Live USB inspection identified APROTII touch at 12 Mbps and UPERFECT touch
at 12 Mbps behind a 480 Mbps hub. Both connect directly to the Pi, so the
UPERFECT path still needs 480 Mbps qualification through the IM02TS relay
and selected cables. The relay footprint and default-off intent are retained;
Revision J corrects the contact wiring described above. The
4.5 V IM02TS relay now improves pickup margin on the 5 V host supply.

See [revision H verification](reviews/screen-power-rev-h-1072/verification.md)
and the [connector map and assembly notes](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/kicad/screen_power/README.md).
Revision I superseded those exports, but is itself withdrawn following the
September 25 relay finding. The historical September 24
[first-fabrication review](reviews/pcb-completion-1072/first-fabrication.md)
removed the blanket pre-order measurement requirement; that decision remains,
subject to completing the Revision J correction and checks. Assembled hardware
remains unverified. The pre-order
audit corrected finished-hole allowances, added metal-fastener copper
clearance on the screen board, and moved console CTRL analogue pull-ups to
the Pico supply so Pi power cannot feed its unpowered ADC inputs. See the
[completion and pre-order status](reviews/pcb-completion-1072/verification.md) for final checks and
remaining physical and firmware acceptance items.

The board remains an unassembled prototype. Cable mating, polarity, shielding,
USB-C source configuration, USB operation/suspend, hot relay restart, inrush,
fuse coordination, voltage drop, temperature, impedance and enclosure fit
need physical checks. The owner confirmed on 2026-09-22 that both screens go
fully dark with power/touch USB disconnected and HDMI retained, following the
Pi-on test. The HDMI-only visual check therefore passes; GPIO cutoff and
discharge timing remain unverified. The included GPIO17 lifecycle service
passes its host tests; the five-second wait remains provisional. Local new-v3
firmware/PD work described in the historical completion report is outside
this publication. Issue #1072 remains `autonomy:blocked-verify` for assembled
validation and merge.

## Solid second-row enclosure platforms - 2026-09-15 (#1037)

Integrated the existing solid CLEAR/BANK collar revision into the active
manufacturing generator and print STEP/STL/archive. Both Fusion models are
saved and reopened at sheet metal 160 / populated 388. The four driver bores,
short-screw mounting patterns and all external interfaces are verified; other
native geometry and all 42 / 434 positions are preserved. Metal outputs did
not change. All 134 enclosure tests pass, plus the seven focused mounting
tests after strengthening the solid-material check. The #1019 physical load
hold remains. See [evidence](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/enclosure/reference/solid_mid_platform_verification.json).

## Enclosure corner preparation - 2026-09-15

Prepared the welder's example on the existing #1025 branch while Dinacut's
confirmation is pending. Four angular reliefs now provide a nominal 0.50 mm
gap and 1.00 mm overlap. The rear upper return and all control/support mounting
geometry remain intact. The weld scope includes all four corners, lower relief
openings and the two upper rear joints, with the separately agreed 5356 filler
and smooth exterior finish. No files were sent and no fabrication was authorized.

Generator, native Fusion models (sheet metal 159 / populated 387), STEP, DXF and
individual drawings are synchronized. Both saved models were reopened; all
42 / 434 placements and unrelated body geometry/health are preserved. The full
generator and 133 tests across 15 modules pass. Cross-kernel mass integration was
qualified independently before changing its numerical consistency limit to
50 ppm; dimensional, forming, source-hash and full-flat gates remain unchanged.

The separate #1019 structural/load hold remains. Dinacut still needs to confirm
the relief/tooling assumptions; post-weld fit and front drilling are completed
before paint. See [current evidence](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/enclosure/reference/welder_corner_preparation_verification.json)
and [release review](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/enclosure/RELEASE_REVIEW.md).

## September 14 enclosure revision - historical digital evidence

The owner authorized #1025's welded rear-corner direction and manufacturing
tolerance revision from `43c94a27` on
`claude/sheet-metal-enclosure-analysis-6c2aa4`. This supersedes the older riveted
process below. It is implementation approval, not fabrication release; **#1019
remains an independent structural/load hold**, including the changed corner
restraint and welding effects.

The new metal handoff has five parts, one each: base, faceplate and ring disc
in 2.0 mm 1100-H14 aluminium, a **1.2 mm aluminium rear panel**, and a 1.6 mm
cold-rolled steel beam. Rear-panel alloy/temper and steel grade remain to be
confirmed. One metal archive carries exactly 15 STEP/DXF/individual-PDF
files with material, thickness and quantity in their names; no assembly,
hardware, printed parts, drafts, removed brackets or posts.

Dinacut cuts/folds/deburrs; a separate welder joins both rear corners. The two
brackets and ten base rivet holes are removed. The nine front lid/body stations
are laser-piloted and drilled out by Dinacut **after folding and before
welding** (#1090). No electronics trial or second manufacture is requested. A separate
painter coats all faces and clearance passages smooth matte black RAL 9005,
0.06–0.10 mm locally per face, protecting identified electrical-bond contacts.
The owner then cleans Ø2.5 pilots and taps **32 M3 threads** (18 lid, 14 screen
supports), and fits shims/felt. No new holes or enlarged screw passages are
planned after paint.

The current fit candidate is rear **10 mm depth ×6 mm wide CUT slots / OD12
washers**, front **Ø4.5 / OD7**, and **1.1 mm nominal bare front clearance**
with **0.70–1.50 mm acceptance inclusive of forming/fixture errors**. Coating
alone projects **0.357–1.488 mm** painted clearance. The slot passage calculation
does not qualify washer seating, wedge contact or the welded assembly;
final fit, washer selection and shim bearing remain pending.

Fusion was saved and reopened as **VAMP sheet metal 158 / populated 386**.
All changed features are healthy; all 42 / 434 final occurrence placements
survive reopening. Both bases have the ten rivet holes removed and both bracket
pairs are gone; each base measures **945.325929644 cm³**. The revised lids,
discs, washers and nominal shims are present in both models. Reopened native
solids match the verified exports; the populated lid flat comparison is exact
and each base differs by less than 0.000619 mm². All **126 tests across 14
modules** and the full generator pass. Five individual metal PDFs were visually
reviewed; the exact 15-file metal archive was verified after removing only
proven timestamp noise. The historical riveted guide was corrected.
All five independent implementation reviews are complete with no unresolved
findings; see the [consolidated review](reviews/dinacut-welded-revision/review.md).
Physical fit and strength qualification still block fabrication; no supplier message
or cutting authorization was sent. See the
[current plan](plan/2026-09-14-fix-dinacut-manufacturing-tolerances-plan.md),
[release review](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/enclosure/RELEASE_REVIEW.md) and
[internal supplier drafts](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/enclosure/SHOP_REVIEW.md).

## Enclosure release corrections — local, 2026-09-05

The following dated evidence records earlier revisions. Its riveted-corner
process, fit dimensions, quantities and saved versions are historical; the
September 14 status above governs the current revision.

Prepared from `fix/drawing-legibility-1001` at `1d14d701` on
`codex/sheetmetal-release-fixes`. Earlier converter, monitor support, post,
rear-panel gauge and corner corrections remain in place. The owner confirmed
no shop work has started, separate metal/painting suppliers, short text messages,
and **smooth matte black RAL 9005**, with no texture.

A full review corrected intersecting corner cutting paths, USB corner geometry,
an encoder bushing-root clash, coating-sensitive drilling/bore requirements,
hardware quantities and unsafe partial/failed archive publication. A repeat
review then found and corrected the installed Ring24 pin-strip stack's clash
with its printed holder, the disc's finished outer-diameter allowance, lid
centering before drilling, stale bend/post-gap notes and acceptance of retraced
laser slits hidden by CAD healing.

Fusion is saved and reopened as **sheet metal 131 / populated 344**. The repeat
pass changed only the existing ring holder with two cuts and eight support ribs;
all 414 other populated occurrences and all 18 sheet-metal occurrences retain
identity, geometry, placement, visibility and appearance. There are no empty
leaf components. The selected Ø80 board/pin strip and visible encoder positions
remain fixed. Its 73-body interface and bottom-up insertion clear the new
one-piece holder; nominal PCB axial clearance is 0.1346 mm and still needs the
actual print-fit check. Align the holder to the board before gluing.

The complete generator and **26 regressions pass**. All six metal laser profiles
pass topology checks; native base/bracket flats have zero missing/extra area,
and lid difference remains 0.008358 mm² each way within the 0.01 mm² gate. The
expanded printed-part sweep completes 1,056 candidate pairs without Boolean
failures; residual physical contacts are measured 0.000139–0.007803 mm
seat/compliant-rubber fits. The five changed PDFs / ten pages were rendered and
inspected. Final archive hashes and independent repeat-review results are in
[the repeat-pass evidence](reviews/sheetmetal-release-fixes/round2-verification.json).
The selected Ø80 ring-board revision must not be confused with this checkout's
Ø68 Gerber package.

**Seam corrections completed locally; Fusion saved and reopened at132/345.** The base side profile now follows the
lid ridge at 0.30 mm nominal clearance; fit to 0.30–0.40 mm before coating. Two
handed rear brackets back the upper straight seam with approximately 0.22–0.30 mm
vertical relief, fitted to 0.20–0.40 mm. Nine purchased stainless shim packs
support the front M3 stations; their actual thickness is fitted before painting
between hidden bearing lands, subsequently masked (September 6 sequence correction). Nominal 0.50 mm CAD packs are reference only.
The selected electronics, ring stack and all visible controls remain in place.

The seven fabricated stems make eight pieces, plus nine purchased reference
solids in the assembly. All 28 manufacturing regressions pass and six final
archives contain 90 matching members. Base and both handed bracket flats match
source exactly in both Fusion documents; unchanged lid parity remains within
0.01 mm². See [current seam evidence](reviews/sheetmetal-release-fixes/seam-fix-verification.json)
and [the correction review](reviews/sheetmetal-release-fixes/seam-review.md).
Earlier 131/344 and 26-test records above are historical.

**September 6 sled/screen corrections completed locally.** Populated Fusion
is saved and reopened at **346**; the separate mini console is synchronized to
the current source and saved/reopened at **13**. Each mini sled has two underside
retention fixings at 60 mm pitch, with matching tray access. Both sleds now
appear in the assembly STEP. A toe relief and revised rear lid bosses/locating
tabs remove the closed-lid and LED-insert clashes found during integration.
All 27 native mini interface checks are clear. The seven-inch module and four
mounting bosses move 0.50 mm toward the front along the faceplate; its six floor
anchors and aperture stay fixed. All 50 screen-area native checks succeed,
with only the unchanged tab-seat contact. **33 manufacturing regressions pass.**
Printed mini/tower/jig files are current; the console print ZIP carries the new
tower. Metal DXFs, PDFs and the five other supplier ZIPs are byte-identical to
the preceding reviewed package. No new PDF was authored. See
[the sled/screen evidence](reviews/sheetmetal-release-fixes/sled-screen-verification.json).

**Not released for fabrication.** Shop stock/tooling, rivet choice and final
pre-coating fitting and the coated fit coupon must be accepted; purchased-part fit, insert/screw lengths,
knob relief and coating sample still require physical checks. First-piece dry
and finished assembly and load/retention qualification remain necessary. See
[the release review](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/enclosure/RELEASE_REVIEW.md),
[verification](reviews/sheetmetal-release-fixes/full-review-verification.json)
and [short supplier drafts](https://github.com/tomassasovsky/segno-hardware/blob/main/hardware/enclosure/SHOP_REVIEW.md).
No package or supplier message was sent; no commit, push or remote issue/PR state
was changed by this review.

The subsequent rear-joint correction removes the remaining 0.610842 mm straight
seam opening: both rear/side joints now measure 0.050001 mm in both native
models. Source, actual native flat, formed STEP and shop packages were regenerated.
The owner retained rivets and a visible fine joint, with 0.00–0.10 mm dry fit
before riveting/coating. All 34 enclosure regressions pass; independent geometry
and preservation checks found no new interference or unrelated movement.
Final saves **sheet metal135 / populated348** reopened with unchanged geometry.
The source base was rebuilt from its DXF to repair an unreadable derived flat;
all five source flat products now load. See
[the rear-joint verification](reviews/sheetmetal-release-fixes/rear-closure-review.md).


**September 6 coating-scope correction — local checks complete.** The owner
retired the full-face overlay; labels remain on individual pedal tiles. Extra
machining PDF pages are removed in favor of text instructions. All metalwork
remains before the separate painting shop. All enclosure surfaces and clearance
bores are coated smooth matte black RAL 9005, without texture; only threads and
identified ground contacts are protected. Source/native clearances, printed
supports, screen setback and lid washers account for the stated coating range.
All 40 enclosure tests pass, the full generator reports ALL PASS, and the five
archives contain 88 verified members. Eight changed PDFs (11 pages) were
rendered and visually reviewed. Earlier masked-seat/prepaint evidence is
superseded for this coating process. Final native save versions are recorded
in [the current verification](reviews/sheetmetal-release-fixes/full-coat-verification.json).
The standalone mini geometry remains unchanged. Nothing has been sent to either
supplier. Physical shop/tooling, coated-coupon and assembled retention checks
remain open; local CAD checks do not grant production release.

**September 7 owner finishing decision.** The owner will install the ten corner
rivets before painting, retaining the existing Ø3.3 rivet holes, and manually
tap the eighteen M3 body holes after painting. The shop delivers matched parts
with Ø2.5 body pilots untapped and Ø4.5 lid clearances finished. Paint-narrowed
body pilots are cleaned back to Ø2.5 before tapping; no other post-paint hole
changes are planned. This supersedes the earlier all-machining-before-paint
sequence and protection of already-cut body threads. Ground contacts remain
protected. Only process notes change; native geometry and poses are unchanged.
The base drawing and painting notes were refreshed, all five pages visually
checked, and changed archive members verified. The proposed straight Ø8.5 disc
hole clears the modeled encoder root with paint allowance, but is not applied:
actual retaining nut/washer coverage must be checked before removing the chamfer.

**September 7 straight encoder-disc hole completed.** Owner measurements are
washer ID7.25/OD11.85. The disc now has a laser-cut straight Ø8.50±0.05 bore,
without chamfer; the outer diameter, thickness and all placements stay fixed.
Finished bore8.25–8.43 clears the modeled root when centered; conservative
opposing clearances leave0.87 mm minimum washer coverage. Both native documents
were saved/reopened (sheet-metal138/populated351), with no unrelated changes
or new warnings. All40 enclosure tests pass; five changed output files and
matching archive members were updated; two PDFs/five pages were visually checked.
See [the current disc verification](reviews/sheetmetal-release-fixes/straight-disc-verification.json).
No supplier message or package was sent. Physical fit/retention acceptance remains.

**September 8 thread-count and structural-comment correction.** The current
source and the supplied base DXF contain 32 M3 tap pilots: 18 lid fixings plus
14 screen-support anchors (six for the 7-inch tower and four per 15.6-inch
stand). The earlier September 7 process note counted only the lid fixings.
The owner cleans any paint-narrowed Ø2.5 pilots and manually taps all 32 after
painting; the shop delivers them untapped. The 18 lid clearance holes and
18 head washers retain their existing quantities. Current process prose and
the generated base note now distinguish those counts. Unsupported fixed
1050 strength, fold-stiffness and dent-load claims were removed from source
comments: actual temper, assembled support conditions and physical loading
remain to be qualified. These prose corrections do not establish structural
capacity or change the joint hardware. Historical verification records remain
unchanged.

**September 8 floor support update completed locally.** Four original rubber
feet are retained and eleven are added: four front, four rear and three
staggered near CLEAR/BANK and the steel posts. Both native bases were rebuilt
from the generated flat and saved/reopened as sheet-metal139/populated352.
The populated group has15 real feet; no unrelated components moved and no
warnings were added. All45 enclosure regressions pass, both final flats agree
with source contours, and the current sheet-metal-only archive has14 verified
STEP/DXF members. Base drawing inspected; older supplier packs are not the
current handoff. [Evidence](reviews/extra-feet/verification.json).

The owner's sustained scale reading was15–20kg and displayed maximum35kg; body
mass70kg. The provisional200N/700N static cases are not impact ratings. A
published-temper comparison and bare-sheet-strip sensitivity screen leave
assembled bending unresolved. Actual foot contact and printed-support load
spreading must be assessed before physical load qualification or cutting
release. [Temper analysis](reviews/extra-feet/temper-screening.json).

**September 9 console collar print correction completed locally.** Front/rear
light-baffle walls grow from 0.85 to 2.4 mm, increasing collar depth to 118.47 mm.
The bore, sleds, insert pockets, screw axes and pedal heights are unchanged.
Both native documents are saved/reopened at sheet-metal 140/populated 353 and
their collar solids match source exactly by bidirectional volume comparison.
The sheet-metal document's older collar references also receive the current
source geometry and mirrored populated-model placement. All 442 unrelated
populated occurrences and 35 unrelated sheet-metal occurrences are unchanged.
All 49 enclosure tests pass, including four new collar regressions. The two
collars' STEP/STL files and 36-member printing archive are current; all other
output files, including the metal-shop archive and sled files, are byte-identical.
[Evidence](reviews/collar-thickness/verification.json). First-print insert fit
and assembled structural qualification remain physical checks.

September 9 cable-opening follow-up completed locally: both console collars
now have an 8.6 mm centred open-top exit, with its bottom 6.95 mm above the
bare pedal underside. This clears the measured 7.6 ×11.45 mm feature with
0.5 mm side clearance and covers the 1.05 mm vertical measurement discrepancy.
All 50 enclosure tests pass. Native sheet-metal 141/populated 355 were saved,
reopened and matched to source; other geometry and placements remain fixed.
The user's three visibility changes during inspection are preserved. Updated
collar STEP/STL pairs and the printing archive agree; other outputs, including
the metal-shop archive, are unchanged. [Evidence](reviews/cable-opening/verification.json).

Closed stadium update, September 9: the console cable opening is now
8.6 ×13.5 mm with R4.3 ends and 4.9 mm straight sides, closed at the top.
Thread the cable before seating the pedal/sled. This supersedes the prior
open-top version. The 0.5 mm fitting allowance assumes the reported cable
feature has a stadium profile. Both models are saved/reopened at sheet-metal
143/populated 358, with exact native/source parity and 50 passing tests.
Other geometry/placements and the user's visibility choices are preserved.
The two print pairs and printing archive are updated; the metal-shop archive
and all other outputs are unchanged. [Evidence](reviews/cable-hole/verification.json).

Short-screw CLEAR/BANK mounting, September 9: the two tall collars now anchor
independently to the bottom base with M3×6 screws and M3 Ø5 ×5 inserts. Their
new dedicated sleds attach through the 8 mm deck with four M3×12 screws per
module. Front sled/collar, all metal geometry, mini-console and cable stadium
are preserved. Bench-assemble and remove the complete module for service.
Both native documents are saved/reopened at sheet-metal v144 and populated
v360; native/source differences are zero, with 448 other populated and 43 other
sheet-metal occurrences unchanged. The first-print ZIP now contains four STLs
(one collar and matching sled for each row). All 56 enclosure tests pass.
Physical insert fit and loaded PETG
performance remain unqualified. [Evidence](reviews/mid-platform-mount/final-verification.json).

September 9 material certificate received: Dinacut corrected the offered stock
from 1050 to 1100-H14. The Alcast certificate covers 2.00 mm lot 26E0269, with
127 MPa reported yield against a 95 MPa specified minimum. Use the minimum as
a material reference with separate design margins; the lot result is not a
universal allowance. Job-stock traceability and the 1.2 mm rear-panel material
remain unconfirmed. The previous strip screen still does not qualify assembled
stomp strength. Generator/drawing material callouts await controlled reissue;
no output/CAD geometry changed for this evidence review.
[Certificate assessment](reviews/material-certificate/review.md).

## September 2026 Mac recording companion

The standalone [Segno Transfer app](../apps/segno_transfer/README.md) implements
the owner-requested Mac workflow in #1056: connect using existing SSH access,
browse and select performance audio, name downloaded copies, verify transfers,
and stream recording previews with seeking. Its Swift package is independent
of the instrument runtime. The helper uses the appliance's minimal Python with
jq and sha256sum; Python json/hashlib modules are not required.

The streaming update uses bounded SSH range reads through the native player,
replacing full-file preview preparation. Local acceptance includes a real two-file download, custom filenames, matching
source hashes, and Finder reveal. Automated checks cover the transfer failure
paths, selection state and playback. Source review and product approval remain
separate from this local app delivery; #1056 retains its merge gate.

The owner approved free GitHub distribution with local signing and no paid
Apple signing or notarization. Companion tags use `transfer-vVERSION`; their
workflow tests and builds the Apple Silicon disk image, includes installation
instructions and the license, and publishes a checksum alongside the download.
Release review also corrected preview shutdown: quitting waits for cancelled
reads to finish their connection and temporary-file cleanup, including previews
closed or replaced just before quitting. Closing previews remains responsive.

## September 2026 appliance integration

The console link, CTRL jacks, and appliance delivery stack (#984, #986, #990)
integrates with the newer master changes. See
[the integration record](APPLIANCE_INTEGRATION.md) for release 137's verified
source commit, retained v2 behavior, pending v3 firmware, and the separate
software and device validation boundaries. Merging source does not publish or
install an appliance update.

The update helper now requests tryboot explicitly when an update is staged
(#977); an ordinary restart keeps the active slot. Isolated shell tests cover
both paths. This source correction does not validate a new installed image or
resolve the separate crash-loop health-gate issue (#976).

## September 2026 click timing

With Sync tempo off, later recordings now take their click timing from the
existing loop (#1051), including loop-top downbeats for loops shorter than one
beat. Native regression and sanitizer checks pass. The appliance listening
check remains pending; this source change does not install an update.

## Startup readiness and bundle inspection (#980 / #982)

The startup mitigations from #982 for #970 (the launcher's wait for a stable
Wayland socket and the 750 ms delay before the second window opened) were
removed with the GTK runner (#1330): ivi-homescreen opens both screens itself,
with no compositor to wait for. Restarts still pause for three seconds
(`segno.service`).

The bundle build inspects the actual RAUC artifact for the selected board and
version, its rootfs and boot archive, and the firmware install hook. The boot
archive producer and installer from #990 stay authoritative. See the
[integration record](APPLIANCE_INTEGRATION.md#startup-readiness-and-release-inspection)
for checks and the remaining device boundary.

Builds 138 and 139 compiled successfully but failed collection: the release
host lacked an archive extractor, then its RAUC version could not read verity
bundles. Inspection now runs before bundle deployment using the pinned
Yocto-native RAUC with JSON support, archive tools and jq. The checker matches
the existing boot archive filename ending in `.tar.img`; the producer and
install hook remain unchanged. A failed inspection stops the release build.


## September 2026 pill housing and simulator (#1074)

`hardware/pill_light_mask/` contains the eight-LED visual simulator, the flush
bench/panel lens and solid carrier, and the current angled friction-fit cradle
housing. Fit revision 2 adds 0.30 mm across the housing ribs and narrows the
platform throat by 0.30 mm after the measured loose fit. The current sample
parts and full STEP/STL exports are checked against pinned front/mid cradles.
The deeper grip, supported diffuser and open wire slots retain the accepted
12 mm strip and 12.5-degree face angle. Earlier snap variants remain historical
local artifacts and are excluded from this release. Physical fit, wear, pedal
travel and diffuser bridge anchoring still require validation; #1074 stays
`autonomy:blocked-verify`. The simulator is illustrative, with no device link.

## How to build / test (environment gotchas — read first)

- **Dart/Flutter tests:** the very_good_cli MCP `test` tool is broken in this
  env (exit 69, machine-output parser vs Flutter 3.44). Use the Flutter 3.50
  SDK: `/Users/Tomas/development/flutter-3.50/bin/flutter test`
  (`/Users/Tomas/development/flutter` is still 3.47, which cannot resolve
  `sdk: ^3.14.0`; once it moves to 3.50 this path goes back). Codex does not
  install the former Claude hook that blocked bare CLI test commands.
- **Screenshot suites** (`test/screenshots/`, tag `screenshots`): no goldens
  are committed. They render only with `--update-goldens`, into
  `test/screenshots/goldens/` (ignored), using the SDK's Roboto and every font
  in the font manifest (`loadScreenshotFonts`, one call per suite), so they
  render on Linux CI as well as on a Mac. CI's
  `design` job uploads them as the `screenshots` artifact (a suite that fails
  to render fails the job) and runs `test/control/external_pedal_art_test.dart`
  against a segno-design clone next to the main checkout; without that clone
  the study checks skip. CI clones only segno-design's `docs/design/` (sparse,
  blobless), at the commit in `.github/segno-design.sha`. Compare the PNGs
  against the Penpot file.
- **Scaffolding:** prefer the Very Good CLI templates for normal packages.
  The Very Good MCP `create` tool only makes federated method-channel plugins.
- **The engine is a code asset (#1783).** `segno_engine` is a plain package
  with a build hook, not a Flutter FFI plugin. `packages/segno_engine/hook/build.dart`
  runs CMake on `src/CMakeLists.txt` (the one description of the shipped
  library) whenever Dart code that uses the package is built: `flutter run`,
  `flutter build`, `flutter test` in the app or any package that depends on
  it, and the appliance's `flutter assemble`. The bindings are `@Native`
  externals (`tool/ffigen.dart`), so nothing opens the library, in any
  isolate. Building needs CMake, clang (or Xcode's compiler) and, on Linux,
  `libasound2-dev`. The hook sees only the environment variables
  `hooks_runner` passes (PATH, HOME, TMPDIR, `CCACHE_*` and a few others):
  `CC`, `CXX`, `CFLAGS` and `SEGNO_ENABLE_PLUGINS` do not reach CMake, so the
  hook names the compiler and the plugin option itself. The build tree is
  under `.dart_tool/hooks_runner/shared/segno_engine/build/`.
  - **macOS:** plugin hosting on; Flutter bundles the library as
    `segno_engine.framework`.
  - **Appliance:** plugin hosting off, clang, `Release`; the manifest
    (`flutter_assets/NativeAssetsManifest.json`) names the library
    `libsegno_engine.so`, which the Flutter engine `dlopen`s through the
    loader's path, so `segno-kiosk-launch` puts `/opt/segno/lib` on
    `LD_LIBRARY_PATH` (ivi-homescreen's run path does not include it).
- **Segno.vst3** (#1804), the effects as VST3 plugins for a DAW on the dev
  Mac: `FLUTTER=/Users/Tomas/development/flutter-3.50/bin/flutter bash
  packages/segno_engine/vst3/install.sh` runs `build.sh`, which renders the
  editors' pedal faces (#1815, about a minute) and builds it (Release, into
  `packages/segno_engine/build/vst3`), then installs it in
  `~/Library/Audio/Plug-Ins/VST3`; `--test` also runs the null test and the
  binding test against the installed bundle (`test/run_bundle_tests.sh`).
  Its `CFBundleVersion` is the commit time of the checkout's HEAD, which
  Segno Transfer compares with the copy it carries (#1829). After a change
  to the pedal faces, `/Users/Tomas/development/flutter-3.50/bin/flutter test
  --update-goldens test/vst3_faces/vst3_faces_test.dart` rewrites the layout
  the editors read. Live finds it on its next plugin scan (start, or
  Settings > Plug-Ins > Rescan) under Plug-Ins > Segno. Signed ad hoc;
  Segno Transfer's `build-app.sh` builds it the same way and ships it in
  the app's `Contents/PlugIns`, to install on request (#1829).
  `bash packages/segno_engine/vst3/test/run_null_test.sh` builds a separate
  tree and runs the null test, as CI does on Linux (clang, CMake,
  `libasound2-dev`).
- **Native engine tests** (deterministic, no device — the real safety net since
  the audio thread can't be runtime-tested here):
  ```sh
  bash packages/segno_engine/src/test/run_native_tests.sh
  ```
  Concurrent native configurations need separate `TMPDIR` directories: the
  script uses fixed executable names there, so sharing a directory can make
  builds overwrite another run's binaries.

  The script self-locates (no preceding `cd` needed) and builds/runs the
  engine core test suite and the MIDI test suite on every desktop OS
  (`gcc`/`gnu11` by default, overridable via `CC`), plus macOS-only plugin
  scan/slot native tests against the vendored VST3/CLAP SDKs. Each suite
  prints "ALL PASSED"; the script exits non-zero on any compile or test
  failure.

  Since #1771 it compiles each engine TU once per flag set, in parallel and
  through `ccache` when installed, then runs the test binaries side by side,
  each in a `TMPDIR` of its own, and prints each one's output when all are
  done (the failed ones last). `BUILD_JOBS` sets how many run at once (one
  per CPU). The core suite runs as `SEGNO_CORE_SHARDS` processes (16, on
  every machine, so every run splits it the same way): each takes every
  n-th entry of `test_engine_core.c`'s
  `main` (`SEGNO_TEST_TOTAL_SHARDS`, `SEGNO_TEST_SHARD_INDEX`), so every
  entry there goes through `SHARD(...)` (the script refuses a bare call)
  and every test must pass without the ones before it. The engine source
  list for this script, the benches, the pitch oracle and the test library
  is `ENGINE_SRC` in `src/test/engine_build.sh`. `NATIVE_TESTS_ONLY` takes
  a comma-separated list of `races`, `core` and `rest`, and
  `SEGNO_CORE_PART=k/n` a share of the core shards; CI's ASan job runs as
  three such parts.

  CI runs the same script in **two more configurations**, both of which must
  stay green and both of which are worth running locally after touching the
  engine:
  ```sh
  EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh
  EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
  ```
  The second is the callback-telemetry gate (#722) — the escape hatch if the
  instrument ever perturbs the appliance, so it has to *pass*, not merely
  compile. Assertions that can only hold with the instrument compiled in are
  wrapped in `CHECK_TIMING` in `test_engine_core.c`; everything else is asserted
  in both builds.
- **Effects matrix (#1547):** every effect kind at 44.1, 48 and 96 kHz and at
  blocks of 32 to 512 frames, at every factory preset's settings: block
  invariance (bit-exact), response and envelope against 48 kHz, aliasing and
  blow-ups. The full run is a bench,
  `bash packages/segno_engine/src/test/bench/bench_fx_matrix.sh` (about 2.5
  minutes on an M4 Pro, `--kind NAME` for one kind, `--detail` for every
  setting's figures); `run_native_tests.sh` runs its `--ci` subset, one
  setting a kind. At 96 kHz the kinds' filter sections run their 48 kHz
  designs on alternate samples (`le_rs_phases` in `engine_fx.c`), exact
  below 24 kHz; at 44.1 kHz they take fitted corrections from
  `src/core/engine_fx_eq_rate.inc` (the EQ, `tool/eq_rate_fit.py`) and
  `src/core/engine_fx_rate.inc` (the rest, `tool/rate_fit.py`; one table
  at a time with `python3 rate_fit.py SHAPE 44100`, numpy and scipy, a
  few minutes each). The pitch kinds (Octaver, Dual Octaver, Whammy, Smart
  Tune) instead run their kernel at 48 kHz at every rate, between two
  Kaiser-windowed sinc resamplers (`fx_octaver_run`). The Transient
  reads its level's true peak between samples and smooths its gain over
  0.1 ms, which keeps its folds under -69 dB. What fails today is the
  `k_known` list in `bench_fx_matrix.c` (the Dual Octaver's envelope and
  12.8 kHz response at 96 kHz with Octave 2 up, #1884; the Overdrive's
  alias at 44.1 kHz), each entry with a ceiling: a new failure, or a
  listed one past its ceiling, fails the run, and in the full run so does a
  listed one that now passes. The settings come from
  `src/test/bench/fx_factory_settings.inc`, generated from the catalogue;
  after a catalogue or module-build change, regenerate it with
  `/Users/Tomas/development/flutter-3.50/bin/flutter test
  tool/generate_fx_factory_settings.dart` in `packages/looper_repository`
  (its test fails until then).
- **Effects against the reference engine (#1755):**
  `bash packages/segno_engine/src/test/bench/bench_fx_equiv.sh` builds the
  effects island twice, from the commit pinned in the script (`REF`) and
  from the working tree, and runs every kind through both at every factory
  setting, 44.1 to 96 kHz, 32 and 64 frames, tails included: bit-identical
  but for the kinds in `k_reordered` (`bench_fx_equiv.c`), which must stay
  under -120 dBFS. About 4 minutes on an M4 Pro; `--kind NAME`, `--detail`
  (the first frame that differs), `--ci` (one setting a kind, which
  `run_native_tests.sh` runs). `FX_EQUIV_OPT=-O3 CC=clang` checks the
  appliance library's build. A change meant to alter a kind's sound moves
  `REF` to the commit that makes it, in the same PR. Bit-identity depends on
  each compiler forming the same fused multiply-adds: a loop of taps
  rewritten in another shape can make clang split them (#1755), and GCC
  fuses the other product of `b x - a y` in vector code (`LE_ROUNDED`,
  `engine_fx_simd.h`).
- **Regenerate FFI bindings** after touching `src/core/segno_engine_api.h`:
  ```sh
  cd packages/segno_engine
  dart run tool/ffigen.dart
  ```
  The configuration is `tool/ffigen.dart` (ffigen's Dart API; its YAML format
  is deprecated since ffigen 23). ffigen formats the file with the package's
  own formatter settings, so a regen needs no `dart format` pass and its diff
  is only what the header changed. Declarations come out sorted by name.
- **FFI symbol parity — the skew a clean build will not catch.** The `@Native`
  bindings resolve through `dlsym` at *first call*. A bundle
  whose bindings name an entry point its `libsegno_engine.so` does not export
  therefore compiles, packages, installs and launches — then throws
  `Failed to lookup symbol '...'` on the device, on whatever path reaches it
  first. That is not theoretical: the appliance threw 137 such exceptions on
  2026-08-25, across six app starts, off a *periodic* timer -- so it repeated
  for as long as each run lasted -- from a bundle whose halves came from
  different trees. Compare the two lists against a built library with:
  ```sh
  packages/segno_engine/tool/check_ffi_symbols.sh <path-to-libsegno_engine.so>
  ```
  CI's `appliance-bundle` job and the release build run it against the bundle
  they just built, and `build-arm64-bundle.sh` runs it before the bundle can be
  deployed or staged for Yocto, so ordinary work should never see it fail. It is worth running by
  hand after a regen if you are about to hand-stage a bundle. The check is
  itself tested (`bash packages/segno_engine/tool/test/run_check_ffi_symbols_tests.sh`),
  including that it **fails closed**: if ffigen's emitted call shape ever drifts
  out from under the extractor, it aborts rather than quietly checking a subset.
- **macOS app run/build:** flavor schemes required.
  `flutter build macos --debug --flavor development -t lib/main_development.dart`
  Run: `flutter run -d macos --flavor development -t lib/main_development.dart`
- **Appliance bundle:** `deploy/rpi/build/build-arm64-bundle.sh` builds what
  the console runs (`build/appliance/bundle`) in an arm64 container, on the
  Flutter release the image's engine is (`FLUTTER_ENGINE_VERSION` in
  `deploy/yocto/meta-segno/recipes-graphics/flutter-engine/flutter-engine-version.inc`).
  There is no `linux/` and no Linux desktop build: the app is built with
  `flutter assemble` and the engine with its own CMake project, and the
  console runs it on ivi-homescreen (#1330). macOS is the dev host.
- **Driving the Network page off the appliance:** Wi-Fi is a Linux-only
  helper (`segno-wifi-ctl`), so on macOS every path past "no WiFi on this
  build" is unreachable — including the ones with the most
  behaviour in them. Add `--dart-define=SEGNO_FAKE_RADIOS=true` to swap in
  an in-memory stack:
  ```sh
  flutter run -d macos --flavor development -t lib/main_development.dart \
    --dart-define=SEGNO_FAKE_RADIOS=true
  ```
  The define is read inside `createWifiClient` **before** its platform test,
  so every entry point picks it up with no app wiring change. The fake is
  opinionated rather than empty — it exists to reach the states the mockups
  draw, with deliberate delays so in-flight spinners and banners are visible.
  Failure is reachable on purpose: `segno123` is the only passphrase that
  joins. **Off by default**, so a shipped build can never
  present invented networks as real ones; the factory tests assert the flag
  from both sides, so the branch is covered by the ordinary CI run.
- **Seeing what the pedal shows:** every change of the pedal's lights is a
  `pedal frame:` line in the app's journal (`ssh root@<console> journalctl
  -u segno.service | grep 'pedal frame'`): the mode, the ring colour and each
  lit switch with its colour, at most 20 lines a second (#1957).
- **Seeing what the console's screens draw:** `ssh root@<console>
  segno-capture` prints one PNG path per screen under `/data/capture`; copy
  them with `scp 'root@<console>:/data/capture/*.png' .`. It is Flutter's
  rendered frame, not the HDMI scanout. Details in
  [`docs/RUNNING_ON_RPI.md`](RUNNING_ON_RPI.md#screen-capture) (#1555).
- **Appliance helper suites** (shell, no device): every
  `deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_*_tests.sh`,
  as the `appliance-shell-tests` CI job runs them. Bluetooth was retired (#1199): the
  image ships no BlueZ, and the pairings an earlier image kept stay on
  `/data/bluetooth` for a fallback to the previous slot.

---

## Architecture (VGV layered monorepo)

```
packages/
  segno_engine/        DATA  — FFI plugin over a hand-written miniaudio engine (C)
  controller_repository/ REPO — hardware-agnostic MIDI → looper actions
  looper_repository/   REPO  — owns the engine; EngineSnapshot → LooperState
  settings_repository/ REPO  — persistent settings over KeyValueStore
  local_storage_client/ DATA — KeyValueStore (shared_preferences)
  session_repository/  REPO  — save/restore .segno session bundles (manifest + WAV stems)
  performance_repository/ REPO — performance-recording capture lifecycle (arm/finalize/recover)
  wav_codec/           DATA  — 32-bit-float WAV encode/decode (pure Dart, no Flutter dep)
  daw_export/          DATA  — pure-Dart Ableton Live 12 (.als) exporter for a performance capture
  midi_client/         DATA  — native USB-MIDI device client (ControllerSource) over the FFI seam
  midi_device_repository/ REPO — MIDI device enumeration/selection + hotplug (audio-independent)
  pedal_repository/    REPO  — console pedal-board link (footswitch/encoder in, LED frames out) over UART
  routing_graph/       UI KIT — reusable routing-graph canvas/wires/cards + theme (Signal, FX editor)
lib/
  app/        App + MultiRepositoryProvider (looper, controller, settings)
  looper/     LooperBloc + Chewie-2 track grid (home)
  audio_setup/ device/sr/buffer, engine start/stop, latency, loopback note
```

Strict layering: presentation → bloc → repository → data. The engine's typed
`AudioEngine` interface is the test seam (fakes everywhere).

### Native engine model (`packages/segno_engine/src/engine.c`)
- One **master loop clock** (`le_loop_clock`: length + position). First finalized
  track sets the length; all tracks index the same `position` → phase-locked.
- **Multi-lane tracks** (PR 1 of the multi-lane/dual-route rework). A `le_track`
  is a container that owns the **transport** (state / multiple / pending-arm),
  one **shared latency-compensated write head** (`record_pos`), and **one undo
  span** (`undo_stack`/`redo_stack`, the same slot index in every lane). Each
  `le_lane` (`lanes[LE_MAX_LANES]`, `LE_MAX_LANES == 8`) records
  **one** hardware input (`a_input_channel`, -1 = none) into its **own clean mono
  buffer** — sibling lanes are **never merged/averaged** — with per-lane output
  mask / volume / mute / effects. Recording is **track-addressed** and fans out
  to every active lane; playback **sums** all lanes; undo swaps every lane's
  `a_live` in lockstep. **Lazy lane allocation**: only lane 0 of each track is
  allocated at configure; `le_engine_set_lane_count` allocates added lanes on the
  control thread, and a **real-time null-guard** keeps the audio thread from
  dereferencing an unallocated lane buffer. Track-addressed setters (volume /
  mute / input / output / fx) map to **lane 0** for backward compatibility.
- Lane buffer pools + undo/redo stacks are owned by the **control thread** (sole
  writer of each lane's atomic `a_live`). The **audio thread only reads
  `lane.pool[a_live]`** — no allocation/locks/stack-access on the callback.
- **Effects are per-lane** (one **stageless**, non-destructive chain on each
  lane's own `fx` state — the pre/post `stage` and the per-lane `mon_fx` are
  gone): `le_engine_set_lane_fx(channel,lane,index,type)` / `…_fx_count` /
  `…_fx_param`. Track-addressed FX setters map to **lane 0** for back-compat.
- **Live monitoring is per hardware input**
  (`le_monitor_input monitors[LE_MAX_MONITORED_INPUTS]`, one slot per input,
  ≤ `LE_MAX_MONITORED_INPUTS`=8; a higher-numbered channel is still recordable,
  just not monitorable): each enabled input is summed live
  through **its own** stageless chain into its output mask, **never recorded**,
  independent of all track state — replacing the old global monitor-FX bus,
  monitor-follow-track, and monitor masks. `le_engine_set_monitor_input(input,
  enabled,output)` / `…_fx` / `…_fx_count` / `…_fx_param`. A loopback
  measurement clears all monitor enables (cable-feedback safety); `passthrough`
  enables input 0 at start.
- **Dry + wet monitoring (independent routing).** Each monitor input also has a
  **parallel dry send** (`a_dry_output_mask`, `LE_CMD_SET_MONITOR_INPUT_DRY=33`,
  `le_engine_set_monitor_input_dry(input,dry_mask)`): the CLEAN (pre-FX) sample
  is summed to its own outputs alongside the effected route, so an input can be
  heard clean on one set of outputs and effected on another at once (`0` = off,
  the default; never recorded). Threaded through `InputMonitor.dryOutputMask`,
  `LooperRepository.setMonitorDry` (remembered + reapplied on restart),
  `MonitorCubit.setDryOutputMask`, and the `monitor_input_dry.$input` key.
- **Monitor routing graph** (`monitor_graph_view.dart`, replacing the per-input
  chip tiles that didn't scale on big interfaces): inputs left, each *monitored*
  input a node + its effect chain in the middle, outputs right, on a zoom/pan
  canvas. Two colour-coded sends per input — **wet** (blue, through the chain)
  and **dry** (amber, dashed). Tap an input to monitor + focus it; an Effected/
  Dry toggle picks which send an output tap wires. Only monitored inputs show as
  nodes; unused ports dim. `monitor_fx_editor.dart` (the old chip editor) is
  removed.
- **Dart domain layer (PR 4) is landed.** `looper_repository` exposes per-lane
  setters (`setLane{Input,Output,Volume,Mute,Count}`, `setLaneEffects`/`…Param`)
  with **lane-0 convenience wrappers** (`setVolume`/`setMute`/`setInputMask`/
  `setOutputMask`/`setTrackEffects` map to lane 0; a selection mask collapses to
  its lowest input via `maskToInputChannel`) and **per-input monitor** methods
  (`setMonitorInput`, `setMonitorEffects`/`…Param`). New domain models `Lane`,
  `InputMonitor`, and `Track.lanes`; `_project()` fills lanes from the snapshot.
  `MonitorCubit` is now a **per-input** list (`Map<int, InputMonitor>`) —
  `MonitorMode`/follow-track and the global monitor-FX bus are gone. Persistence
  moved to `lane_*` / `monitor_input*` keys (old `track_*mask`/`track_effects`/
  `monitor.*` keys dropped, drop-and-default — no migration). Session export
  stays **lane-0 only** (documented follow-up).
- **Multi-lane routing UI (PR 5) is landed.** *(Superseded by the unified Signal
  surface below — `lane_graph_view.dart` and the per-track routing page were
  removed; the lane-addressed `LooperBloc` events described here remain in use.)*
  The per-track routing page is one
  **unified wiring graph** (`lane_graph_view.dart`): hardware inputs on the left,
  the track's lanes stacked in the middle (each a node + its own effect chain),
  hardware outputs on the right, with bezier edges showing every lane's wiring on
  a zoom/pan canvas. Tap a lane node to *focus* it, then tap input/output nodes to
  (re)wire that lane; effects drag-to-reorder and tap-to-edit in a docked panel
  that also holds the focused lane's mix and add/remove-lane (lanes are a stack —
  only the last is removable, capped at `kMaxLanes`). New **lane-addressed**
  `LooperBloc` events (`LooperLane{Count,Input,Output,Volume,Mute,Effects,
  EffectParam}Changed`) replace the lane-0-only mask/track-effect events; each
  forwards to the matching `setLane*` repo method and persists the per-lane
  `lane_*` key. The per-input live-monitor section (audio settings) and the
  stageless chain were already in place from PR 4.
- RT contract: no malloc/lock/syscall/unbounded-loop in `le_engine_process`.
  Commands arrive via an SPSC ring; state published via per-field atomics.
- `le_engine_process` / `le_engine_configure` are exposed for **device-free
  deterministic tests** (`src/test/test_engine_core.c`); per-lane state is read
  with `le_engine_get_lane` (legacy per-track view mirrors lane 0).

---

## Done

Phases 1–3 of the plan plus several sync refinements. See `git log` for detail.

- **Accepted design, slice 3e (#1016, epic #1009):** the October
  reconstruction applies complete FX recipes at an audio boundary and persists
  only their confirmed application. Whole-track Pre combines original parts
  once while keeping the Mixer gain separate. Capture inheritance, Clear/Undo,
  restart, plugin ownership and channel refusal have independent sample and
  persistence checks. All relevant local Dart/native suites, coverage floors,
  static checks and source reviews pass; publication and current-head CI are
  separate gates. FX screens follow in 3f; complete offline rendering, exact
  DSP parity and in-flight cross-session storage ordering retain their later
  owners. See `docs/reviews/design-fx-placement-restack/README.md`.
- **Accepted design, slice 3b (#1016, epic #1009):** output destinations
  have level, mute, Stereo/Mono, retained balance and a post-sum effect chain.
  October reconstruction joins output setup to the shared atomic mix and durable
  rollback path. Performance recording freezes the actual destination and its
  effect chain at callback acknowledgment. Default capture excludes final level
  and mute; Follow applies their later changes. Both policies exclude hardware
  Mono/Balance/master gain/limiter. Cut stops current sources and clears old
  tails and the current click pulse, while preserving monitoring preferences.
  Failed arm publication retains ownership for Stop; malformed destination
  metadata is refused. Track-wide routing surfaces are slice 3c. Offline
  reconstruction still lacks full multi-lane, live-input/click and track-bus
  replay; these are later integration work, not proof of complete parity.
  Ledger: `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Accepted design, slice 3a (#1016, epic #1009):** the mix model: per-lane
  pan with a unity-centre balance law, per-track Solo beside mute, a capture
  trim per input on the recorded branch only, monitoring for every hardware
  input, a recorded image fixed per lane from its input's setup (stereo
  pairs as two lanes with a shared balance), the Mixer's meters (post-fader
  stereo peaks per track, per-input, per-monitor and per-output peaks) and
  typed mix targets; persisted in settings and the session manifest. The
  October reconstruction adds one durable mix coordinator, exact rollback
  and stopped recovery, capture lifetime fencing and atomic recording/Undo
  admission. Verified scope and remaining integration boundaries are recorded
  in `docs/reviews/design-mix-model-restack/README.md`.
  Ledger: `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Accepted design, slice 2c (#1012, epic #1009):** the Loop settings
  pages at the pen's size (hub, Loop mode cards with reasons and the stop
  dialog, Recording, Tempo & click with the signature grid, Length &
  quantize and Playback & overdub with the Tracks / Defaults / 1-8 selector
  and field-level inheritance, Audio & tempo as a readout), opened from the
  tray's Loop entry and the Settings rail; the tray's Loop tabs and Tracks
  Lengths tab, the desktop Tempo and Mode sections and per-track rows, the
  boolean quantize cubit and the sync switch are gone; the session manifest
  carries per-track length and Once overrides; the click output and level
  sit on the Audio tray's Device tab until the Mixer. Ledger:
  `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Accepted design, slice 2b (#1012, epic #1009):** timing ownership: one
  record timing setting (Immediately, Loop start, bar to 1/16) by default and
  per track (a per-track division joins the per-track gate in the engine),
  overdub decay by default and per track with a ramped live change, Once in
  all five modes (a track's lap ends on the shared clock in Multi/Sync/Band),
  count-in and Sound start exclusive through native commands, repository and cubits,
  and the overrides in settings and the session manifest. Ledger:
  `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Timing reconstruction (#1061):** explicit per-track inheritance survives
  empty-track/session recall, Immediate retains the remembered musical grid,
  and queue refusal leaves Count-in, Sound start and armed tracks unchanged.
  Native snapshots publish the applied start choice as one coherent state.
  Current validation and independent review are recorded in
  `docs/reviews/design-timing-restack/README.md`; hardware proof stays separate.
- **Accepted design, slice 2a (#1012, epic #1009):** mode changes with
  recorded audio follow the accepted contract (the engine measures the gate:
  compatible spans switch on a stopped rig, playing loops are stopped first,
  captures and queued arms refuse; nothing is cleared or resized); undo during
  an overdub removes the pass, undo during a take cancels it with an
  immediate-playback redo, a clear on a capturing track freezes the take
  restorable, and Clear All is one grouped edit. Ledger:
  `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Accepted design, slice 1 (#1010, epic #1009):** the Tracks view is the
  accepted stage (four columns per bank with name/crown, number · bars ·
  layers · FX, one dB-linear whole-track meter with a clip cap, queued cue,
  bottom progress, shared dBFS scales, footer, Library/bank/view/Settings
  top bar, Wave view) and the 7" follows the selected track. The engine
  crowns the first completed take and clears the crown of an empty session;
  the snapshot
  carries a per-track playhead and the master-bus peak. The volume overlay,
  status bar and readiness strip are gone. Ledger:
  `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Phase 1:** monorepo, miniaudio FFI plugin, duplex passthrough, round-trip
  latency harness, "hello duplex" smoke app.
- **Phase 2:** single-track looper (record → master length → overdub → mix →
  vol/mute → clear), `looper_repository` + `LooperBloc` + channel-strip view,
  `audio_setup`.
- **Phase 3 core:** N-track engine (LE_MAX_TRACKS=4) + grid UI;
  `controller_repository` (MIDI-learn-ready) wired into the bloc.
- **Loopback latency auto-detect** (PulseAudio monitor / WASAPI / virtual
  driver) + cable-free auto-measure (digital-path estimate; cable for true
  analog).
- **Latency compensation (record offset):** overdub/new-track input written at
  `pos − offset`; monitoring is **live** (not folded); offset auto-set by a
  measurement, overridable.
- **Persist latency:** per-device (device + sr + buffer) via
  `settings_repository` / `local_storage_client`.
- **Single-capturer recording** (chained hand-off): record on a new track
  finalizes the current one and starts the new from the loop top.
- **Multi-level undo/redo** per track (control-thread buffer pool; undo = overdub
  layers, clear = remove track).
- **Fully free mode** (no tempo): all BPM/metronome/click/count-in/tap-tempo,
  loop↔tempo sync (#2), and quantize-start (#3) logic was **removed** from the
  native engine, FFI, repository, bloc, and UI. The looper has **one master loop
  length**, set by the first finalized recording; there is no beat grid, no
  click, and no quantization — captures start and stop immediately. Per-track
  loop multiples (#4, below) are retained, as is latency compensation, the loop
  waveform visualizer, Big Picture / two-window mode, and theming.
- **Loop multiples** (#4): a non-defining track can span an integer multiple of
  the base loop. A free-running `loop_iteration` counts base-loop wraps; each
  track plays `((iteration − start_iter) % multiple)·baseLen + position`, so the
  master still wraps at the base length while a k-loop track cycles its k
  segments. New tracks record freely from the loop top across base loops and are
  **auto-rounded up** to whole base loops on stop (buffer zeroed on the control
  thread so a rounded-up tail is silent). Per-track `multiple` in the snapshot;
  `×N` chip in the UI.
- **Theming + Big Picture mode** (Phase 4 slice): Material 3 theming via a
  `LooperTheme` `ThemeExtension` (neon-on-black **Big Picture**). _(The
  dark-neutral Desktop theme, the desktop `LooperView`, and the `UiMode`
  toggle were later removed — Big Picture is the single UI mode.)_ Big Picture
  is a
  Chewie-Monsta-style row of tall colored track columns (per-track number,
  loop-waveform thumbnail, editable persisted name via `BigPictureCubit`,
  selection highlight, per-track accent / red recording) **plus a second OS
  window** (`desktop_multi_window`) showing the whole-loop output waveform with
  a white playhead bar. Fed by a new RT-safe native **loop-indexed viz tap**
  (`le_engine_read_visual` + `read_track_visual`: peak per loop bucket, master
  + per-track, refreshed as the playhead sweeps). `KeyValueStore` now stores
  string/bool/double. _(The second window and `desktop_multi_window` were
  later removed: the readout is the console's 7″ screen, a second engine
  under ivi-homescreen, #1330.)_
- **Auto-start audio + first-run flow:** the last-used audio config (sample
  rate / buffer / monitor) is persisted on a successful start
  (`SettingsRepository.save/loadAudioConfig`). On launch, `tryAutoStartEngine`
  loads it and starts the engine; if none is saved (first run) the **Audio Setup
  page is the start screen** until the engine connects, then it hands off to the
  looper.
- **Big Picture is the only look** (the `UiMode` toggle was removed).
  A dedicated, minimal **Big Picture settings page** (rename tracks, reach audio
  setup, toggle the waveform window) is reachable from the
  performance view by **right-click** or the **`S` key**, and from the **macOS
  system menu bar** (`PlatformMenuBar`, ⌘,). A persisted `WaveformWindowCubit`
  gates the secondary window. The chromeless big-picture exit button was removed
  (exit lives in settings now).
- **Record immediately, even mid-loop** — a new track over an existing master
  starts capturing at the current loop phase (no waiting for the loop top);
  `record_pos` seeds to the master position so writes stay phase-locked and the
  pre-press slice stays silent. Start-at-top is unchanged (multiples preserved).
- **Transport reset-to-zero** — the master clock no longer free-runs in silence:
  when no track is playing/recording/overdubbing it holds at position 0 (and
  resets each track's loop phase), so play after a full stop starts from the top.
  While any track is active the clock advances as before.
- **8 tracks as two banks of four** — `LE_MAX_TRACKS = 8` (FFI regenerated). A
  persisted **bank-enable** toggle (default off = one bank of four); when on, the
  eight tracks show as two banks of four (A / B), one bank visible at a time.
  `BankCubit` (app-wide) holds enabled + active bank; Big Picture shows an A|B
  switch.
- **Performance keyboard + Record/Mute modes** — handled in the Big Picture
  `Focus` (plain keys consumed so macOS does not beep). `M` switches mode (a
  REC/MUTE indicator shows it); `1`–`8` select a track (auto-revealing its bank);
  Record mode adds `R` record/overdub and `P` play/pause the selection; Mute mode
  makes `1`–`8` select + mute/unmute; both modes: `Space` play/pause all, `C`
  clear all, `⌘/Ctrl+Z` undo, `⌘/Ctrl+Y`/`Shift+Z` redo. `PerformanceMode` +
  `toggleMode` on `BigPictureCubit`; new `LooperClearAllPressed` event.
- **Code-review pass** — removed a debug `settings.clear()`; app composes the
  engine via `LooperRepository.withNativeEngine()` (no `segno_engine` import in
  `lib/`); deleted dead Big-Picture waveform polling and made the level meter a
  stateless widget (no per-tile timers); extracted a shared rename dialog;
  `AudioSetupPage` reads its repositories from context; added the missing test
  coverage. The Big Picture per-track thumbnail is a **level meter**, not a
  waveform.
- **Functional settings surfaced** — the settings/routing UI now exposes the
  engine's real knobs: **quantized recording** (snap start/stop to the loop
  grid, global + per-track override), **configurable input monitoring**
  (input/output channel masks, or follow-the-selected-track), **rec/dub**
  second-press mode, **sound-activated** recording, **loop multiples** (global
  default + per-track `×N`), and **max-loop cap** / **UI refresh rate**. Each
  is remembered in `LooperRepository` and re-applied on every (re)start, and
  persisted via `SettingsRepository`. "Default" chips/labels name the resolved
  global value. The per-track routing dialog reuses the signal-flow graph
  scoped to one track.
- **Effects chain** — *(engine reworked: the chain is now **per-lane** and
  **stageless** — one non-destructive chain per lane via
  `le_engine_set_lane_fx*`; the pre/post `stage` and the global monitor-FX bus
  are gone, replaced by per-input live monitors, see the multi-lane section
  above. The Dart `TrackEffect.stage` model + the card-strip UI below still
  describe the pre-rework PR #11 shape and are reworked in the Dart/UI PRs.)*
  Each chain carries up to
  `LE_FX_MAX = 8` effects (the cap is for a fixed, allocation-free audio-thread
  array, not a CPU limit), each with `LE_FX_PARAMS = 3` normalized params:
  **Drive** (tanh saturation), **Filter** (TPT state-variable low-pass),
  **Delay** (feedback + wet mix, lazily allocated 1 s ring per entry on the
  control thread), **Tremolo** (sine-LFO). All DSP is allocation-free in the
  callback; the pre chain runs on `insample` before the buffer write, the post
  chain on the playback sample before routing. Structural edits (type/stage)
  route through the command ring so the audio thread resets that entry's DSP in
  lockstep; a published `a_fx_count` gates active entries; params are plain
  atoms read once per buffer (a live tweak never resets DSP). Setters
  `le_engine_set_track_fx(index,type,stage)` / `set_track_fx_count` /
  `set_track_fx_param`. `TrackEffect {type, stage, params}` + `TrackEffectType`
  carry native codes, labels and musical defaults; the chain is JSON-encoded for
  persistence. Configured from each track's routing dialog as a **signal-flow
  card strip** — `In ▸ [pre cards] ▸ Track ▸ [post cards] ▸ Out`, add per lane,
  reorder within a lane, move across the track (flips the stage), tap a card to
  edit type + sliders. `LooperRepository` remembers the chain and re-applies on
  (re)start (structural vs. granular-param paths); persisted per channel.
  Designed plugin-ready — a hosted VST3/CLAP plugin is just another effect type.
  **VST3 SDK went MIT (VST 3.8, Oct 2025)**, clearing the licence/GPL block, and
  **the host has since shipped**: vendored VST3 + CLAP SDKs, plugin
  discovery/scan/catalog, slot lifecycle + sealed `TrackEffect` topology guard,
  dynamic parameter UI, native editor windows (NSWindow on macOS, HWND on
  Windows) with two-way param sync, and state persistence with missing-plugin
  resilience. A plugin browser ("+" → Add effect/Add plugin…) replaced the old
  debug seam. **macOS and Windows hosting are feature-complete; Linux (X11)
  hosting is the one remaining gap**, deferred to on-platform work.
- **Windows + Linux native — portable foundation (PR1).** Generated the Linux GTK
  app scaffold (`linux/`); `flutter build linux --debug -t lib/main_development.dart`
  compiles + bundles `libsegno_engine.so` (miniaudio dlopen()s the audio backend at
  runtime). Desktop flavors are **entrypoint-only** (`--target lib/main_<flavor>.dart`;
  `--flavor` only namespaces build output). CI now fires on PRs (trigger fixed
  **`main` → `master`**) and adds compile-only `windows-latest` / `ubuntu-latest`
  build jobs. Per-channel label exclusion is **unchanged** (`return 0` off macOS;
  ASIO/PipeWire are PR2/PR3). *Hardware-gated, not yet run on real interfaces:
  end-to-end record/loop/play/monitor/FX, the `desktop_multi_window` waveform window
  on GTK, device-name classification, and the latency harness.* _(`linux/` and
  the Linux desktop build were later deleted; the appliance bundle is built
  with `flutter assemble`, #1330.)_
- **Windows bring-up fixes (real-hardware run).** Two blockers found running the
  app on a real Windows interface, both fixed + verified (build + app launch +
  native tests green via MSVC):
  - **MSVC C11 atomics:** CMake's `C_STANDARD 11` only emits `/std:c11`, which is
    not enough for MSVC to accept `_Atomic` / `<stdatomic.h>` (the lock-free ring)
    — it needs `/experimental:c11atomics` too. Without it the whole Windows engine
    failed to compile. Added under `if(MSVC)` in `src/CMakeLists.txt` (+ quieted
    C4996 `strncpy` warnings via `_CRT_SECURE_NO_WARNINGS`).
  - **WASAPI device ids collapsed to `"{"`:** `device_id_to_str` read the WASAPI
    *wchar* id as a narrow `char*`, truncating every id to its first byte, so all
    devices shared one id → the device-picker `DropdownButton` crashed and pinning
    was broken. Fixed behind the platform seam (`le_platform_device_id_to_str`):
    Windows converts wchar→UTF-8, macOS/Linux keep the verbatim copy. Regression
    test `test_device_id_to_str`.
- **Windows per-channel labels — ASIO scaffolding (PR2).** `SEGNO_ENABLE_ASIO`
  CMake option. _(The Steinberg ASIO SDK was later **vendored** under
  `packages/segno_engine/third_party/asiosdk` and the repo relicensed to GPLv3,
  so ASIO now builds **on by default on Windows** — see docs/WINDOWS_ASIO.md.)_
  `win_asio_labels.cpp` probe reads `ASIOGetChannelInfo().name`
  and reuses the portable, unit-tested `le_excluded_mask_from_names` /
  `le_label_is_loopback`; dispatched from `engine_windows.c` under the flag,
  degrading to `0` on any failure/ambiguity. Docs: `docs/WINDOWS_ASIO.md`.
  *Still gated on the user's 30-min hardware spike* (does `ASIOChannelInfo.name`
  carry "Loopback" on the interface, and does the WASAPI↔ASIO device match hold?).
- **WASAPI exclusive mode — full device control on Windows.** Opens the duplex
  device in `ma_share_mode_exclusive` + `wasapi.noAutoConvertSRC` so audio bypasses
  the Windows mixer (native format, low latency). Surfaced as a Windows-only
  audio-setup toggle, **default ON on Windows** / hidden + off on macOS/Linux,
  persisted (`audio.exclusive`). One *intent* bool (`le_config.exclusive`) flows
  down; one *reality* bool (`le_snapshot.exclusive_active`) flows back up the
  snapshot so the UI shows a "Shared — device refused exclusive" note only on a
  fallback. **Graceful fallback**: a pure `le_decide_share_fallback` helper retries
  shared once if exclusive init fails, so audio never dies; the platform default is
  resolved in the presentation layer (`defaultTargetPlatform`), never in storage.
  Verified on a real interface: exclusive engaged with the requested 128-frame
  buffer honored (shared would clamp to the OS period). macOS/Linux unchanged
  (no hog mode). See `docs/WINDOWS_ASIO.md`.
- **Device-backend seam (ASIO Part 1 — foundation, behavior-preserving).** An
  internal vtable (`le_device_backend.h`: `open`/`start`/`stop`/`close` +
  `le_device_open_result`) that `le_engine_start`/`stop`/`destroy` drive instead
  of calling `ma_device_*` directly. The existing miniaudio device lifecycle
  (config build, context init, pin/loopback resolution, the exclusive-mode
  fallback, `ma_device_init`/`start`/`uninit`, data + notification callbacks)
  moved verbatim behind it into **`engine_miniaudio.c`** (compiled
  unconditionally like the per-OS TUs); `le_engine_process`, the ring, the
  snapshot, and the looper/lane/FX DSP stay in `engine.c` and are reused
  unchanged. `le_select_backend(backend)` returns `&le_miniaudio_backend` for
  every choice in this build — the default build links **no** ASIO symbol
  (link-time guarantee; the `#if SEGNO_ENABLE_ASIO` branch lands in Part 2).
  This is **distinct from** the per-OS `engine_platform.h` seam (capabilities
  over one shared device, not swappable backends). The FFI structs grew their
  final Part-2 shape, **inert** today: `le_config.backend`/`asio_driver`,
  `le_device_info.input_channels`/`output_channels` (`0`/unknown on WASAPI;
  `device_info_copy` zero-inits them to avoid a stack-garbage read),
  `le_snapshot.active_backend` (always WASAPI). Threaded through Dart with
  inert defaults (`AudioBackend` enum, `EngineConfig`/`AudioDevice`/
  `EngineSnapshot` new fields + hand-written equality). **Acceptance gate:
  invisibility** — all existing native + Dart tests pass unchanged. New tests:
  `test_select_backend_defaults_to_miniaudio`, `test_backend_struct_defaults`,
  enumeration asserts `input_channels == 0`, and Dart round-trip/equality for
  the new fields.
- **ASIO duplex backend (ASIO Part 2 — opt-in, off by default).** The real ASIO
  capture/playback backend behind Part 1's seam, so a pro interface runs at its
  **full channel count** (e.g. 18 in / 20 out) that WASAPI never exposes. New
  **`win_asio_device.cpp`** (`#if SEGNO_ENABLE_ASIO`) exposes
  `le_asio_backend`: load the driver → negotiate rate/buffer → run its real-time
  `bufferSwitch` feeding the **unchanged** `le_engine_process`. ASIO's
  per-channel native-format buffers are bridged to the engine's interleaved f32
  by the pure, unit-tested `le_deinterleave_in`/`le_interleave_out` (Int16/24/32,
  Float32 LSB) + `le_asio_pick_buffer` (snap-to-allowed-size); scratch is
  pre-allocated at open so the RT contract holds. `le_select_backend` returns
  `&le_asio_backend` under the `#if` (default build still links no ASIO symbol);
  `le_engine_start` **falls back to WASAPI** once on any ASIO open failure, and
  `le_snapshot.active_backend` reports the negotiated reality. New
  `le_enumerate_asio_drivers` FFI symbol (real probe in the `#if`, stub returning
  0 in `engine.c` otherwise) — **regen ffigen** (`dart run ffigen` + `dart
  format`; diff is just the one function). **R1 re-entrancy**: enumeration never
  probes while ASIO is the running backend (native reports the open driver; the
  cubit refuses to enumerate while `activeBackend == asio`); teardown clears the
  callback's engine pointer only after `ASIOStop` returns. Dart/UI: a **backend
  selector** + ASIO **driver picker** in audio setup, `AudioBackend`/`asioDriver`
  persistence (forward-compat name read), auto-start relaunch-into-ASIO, and a
  fallback status row. New tests: native bridge round-trips / `le_asio_pick_buffer`
  granularity / enumerate stub; Dart `enumerateAsioDrivers` duplex tagging,
  `StoredAudioConfig` round-trip + unknown-name guard, cubit
  `setBackend`/`setAsioDriver`/hydration/no-reprobe-while-asio, and audio-setup
  widget selector/driver-swap/fallback. **Hardware spike still required before
  merge** (real Focusrite: full count, audio integrity, fallback, persistence).
- **Sessions + WAV export** (Phase 4 slice): `session_repository` saves/restores
  `.segno` bundles (a JSON manifest + 32-bit-float stem WAVs + a mixdown) and
  exports mixdown / per-track stems. Native `le_engine_export_track` /
  `import_track` / `commit_session` move loop PCM in and out (control-thread copy
  into EMPTY tracks; a ring command flips them to PLAYING at their multiple, so
  the audio thread's RT contract is preserved). `SessionCubit` + a session menu
  (the `folder` `PopupMenuButton` in the Big Picture top bar — kept there, not in
  the settings route, because settings is pushed *above* the `LooperPage`
  providers so the cubit isn't reachable from it) drive it; the engine is shared
  (looper owns dispose). Load refuses a sample-rate mismatch (no resampling) or a
  newer manifest version — both are typed (`SessionSampleRateMismatch` /
  `SessionUnsupportedVersion`), classified by the cubit into `SessionError`, and
  rendered as localized human-readable text. Outcomes (success + error) surface
  in a `Semantics(liveRegion: true)` SnackBar (WCAG 4.1.3).
- **Unified input FX & routing** (plan
  `docs/plan/2026-06-22-feat-unified-input-fx-routing-plan.md`). Collapses the
  two FX surfaces into one: each hardware input now has a **single** live-monitor
  chain (output mask + volume + mute + effects), and that chain is **snapshot-
  copied onto a track lane at record** — the take plays back through the chain
  you monitored, while the recorded buffer stays clean (non-destructive; playback
  re-applies the snapshot). The copy is by value on the **control thread** (in
  `le_engine_record`, asserted RT-safe by a control-thread copy counter), so
  editing the input chain afterwards never alters an earlier take (D3). Native:
  `le_monitor_input` folded from N lanes to one chain;
  `LE_CMD_SET_MONITOR_LANE_*` retired for single-chain
  `LE_CMD_SET_MONITOR_INPUT_FX`/`…_FX_COUNT`/`…_OUTPUT`/`…_VOLUME`/`…_MUTE`. New
  **structural output gate** (`LE_CMD_SET_OUTPUT_ENABLED` + snapshot
  `output_enabled_mask`): a disabled output is skipped in the mix fan-out while
  its lane/monitor masks are preserved (re-enabling restores them) — distinct
  from a level mute, RT-safe mid-record, default-on, beyond-channel-count gates
  ignored. Dart: `InputMonitor` reshaped to a single chain (`MonitorLane`
  dropped), `MonitorCubit` single-chain API, `LooperRepository` single-chain
  monitor setters + `setOutputEnabled` + record-time lane-FX mirroring,
  `LooperState.outputEnabledMask`, `LooperOutputEnabledToggled` bloc event, and a
  **v2→v3 migration** (`monitor.migrated_v3`, after v2) that folds multi-lane
  monitor keys per **D9** (first non-empty chain — lane 0 preferred, NOT merged —
  OR-union of output masks, lane 0 vol/mute) and clears the dead keys. UI: the
  monitor graph folds to one node per input (no lane stack), recorded lanes show
  an FX-snapshot badge, and the routing graph renders gated-off outputs greyed +
  non-targetable (reusing `RoutingNode.excluded`) with a tap-to-toggle and a
  non-blocking "no active outputs" notice; accessibility labels on the gate
  toggle and disabled outputs. FFI regenerated (`dart format`, no churn).
- **Signal surface → three routing lists** (plan
  `docs/plan/2026-06-22-refactor-signal-three-list-surface-plan.md`, brainstorm
  `docs/brainstorm/2026-06-22-signal-list-surface-brainstorm-doc.md`, mockup
  `docs/design/signal-list-surface-mockup.html`). The node-and-wire Signal graph
  (below) tangled into unreadable spaghetti at ~16×16 and rendered per-track
  lanes as ambiguous duplicate "Lane 1"s, so its **presentation** was replaced
  by **three side-by-side scrolling lists** — Inputs | Tracks | Outputs — with
  **no wires**. `SignalRows` (pure, unit-tested) flattens `MonitorState` +
  `LooperState` into rows, **collapsing single-lane tracks to the track itself**
  (kills "Lane 1 ×8") and nesting multi-lane takes, tagging each row for trace.
  Routing is **output-hued chips** (`SignalRoutingChips`: lit = routed, "+"
  opens an output picker) → `setOutputMask` / `LooperLaneOutputChanged`.
  "What connects to what" comes from per-output colour + **tap-to-trace** (tap a
  row → its connections light across all panes, the rest dim; view-local
  `TraceState` recomputed from current rows each build, **no new cubit**). A
  take's `rec In N` badge re-assigns its captured input (`LooperLaneInputChanged`).
  Outputs show the structural gate + a derived "fed by" summary + the
  `liveRegion` no-active-outputs notice (now a `SurfaceTheme.warning` token for
  high-contrast a11y). Responsive: stacks to one column below
  `kSignalStackBreakpoint` (960px). **Keeps** the engine state + the
  instrument-panel dock/knob/style layer (`SignalInputDock` gained an additive
  FX-chip row to match `SignalLaneDock`, via a shared `_FxChipRow`); **retires**
  `SignalGraphLayout`, the node widgets, `SignalView`, and all canvas/wire usage.
  Old graph/layout/node tests removed; coverage migrated onto `signal_rows` /
  `signal_list_view` / `signal_routing_chips` tests. The bundled fonts + tokens
  from the prior pass carry over. `package:routing_graph` stays (still used by
  other surfaces; the Signal surface now uses only `FocusableTapTarget`).
- **Unified Signal surface — node graph** *(superseded by the three-list surface
  above; the engine wiring + dock/knob/style layer remain in use, the
  canvas/wires were removed)* (plan
  `docs/plan/2026-06-22-feat-unified-signal-surface-plan.md`, brainstorm +
  mockup in `docs/{brainstorm,design}/`). Replaced the three old node-and-wire
  surfaces (Audio Setup monitor graph, Big Picture settings Routing tab,
  per-track lane dialog) with ONE full-screen **Signal** canvas: hardware
  **inputs** on the left (rich node =
  on/off gate + the single live FX chain that records + level, reusing the kit's
  `EffectChainCard`s), every track's **lanes** in the middle (FX-snapshot badge
  per recorded lane), hardware **outputs** on the right (structural on/off gate,
  greyed when off, edges still drawn). One contextual bottom **dock** swaps by
  focus — the input's tone editor (`SignalInputDock`) or a lane's "this take"
  snapshot editor (`SignalLaneDock`). Bezier edges: capture (input→lane),
  playback (lane→output, fanned at a rail), and the focused input's live-monitor
  send (dashed + faded, focused-only for a calm canvas). Geometry is a pure,
  tested `SignalGraphLayout` composing `package:routing_graph` helpers; focus +
  selection are view-local. Capture-on-tap (D2b): focus a lane, tap an input to
  record it (`LooperLaneInputChanged`; re-tap un-captures). Reached from the
  performance view by a visible chrome button **and** the `G` shortcut;
  `showSignalPage` re-provides `LooperBloc` + `MonitorCubit` + `AudioSetupCubit`
  into the pushed route. Audio Setup keeps only device/SR/buffer/latency; the
  `LaneNode` moved into `signal_graph/`.
  **Superseded (#533):** Signal is a tray rail destination now — cards, a
  detail panel, an FX editor and an add dialog under
  `lib/looper/view/signal/`. `signal_graph/` and the FX dock were deleted
  whole; the chrome button and `G` open the tray at Signal. Built in 3 stacked phases (scaffold →
  rich node + dock → deletions); ~1.3k lines of old-surface tests removed with
  their load-bearing coverage migrated onto the `signal_*` tests.
- **Segno FX plugins (removed, #940).** Segno's own effects were also built
  as desktop VST3 plugins (`packages/segno_engine/vst3/`, seven plugins, a
  golden-parity CTest suite and per-OS CI jobs). They went with the desktop
  targets (#920): the owner's call on 2026-11-03 deleted the build, its tests,
  the `vst3-plugins-linux` job, the `segno_dsp_core` library that existed only
  to share `engine_fx.c` with it, and the C++ atomics shim in
  `engine_private.h` that only the plugins needed. Hosting third-party
  VST3/CLAP plugins (`src/host/`) is unaffected. The `.als` export's
  device chains, which named these plugins, went in #1587.
- **Performance recording** (12-part plan). Captures a full live performance
  to disk, sample-accurately: RT-safe audio-thread taps write into lock-free
  rings, a control-thread drain thread streams them to a per-run event log
  (`wav_codec` for the WAV side, new `performance_repository` for capture
  lifecycle — arm/finalize/recover-unfinalized/rename/discard), surfaced by a
  recorder UI + app state (record/play toolbar affordance).
- **Performance recording — pedal firmware parity.** The console's pedal board
  has no spare footswitch, so arm/disarm rides the existing MODE button via a
  tap-vs-long-press split (tap still toggles Rec/Play; a ≥500 ms hold
  arms/disarms). The armed state rides the wire but is **not** rendered on the
  pedal board: it once blinked the MODE LED red, dropped in #693 because armed
  already shows on the screens and blink-vs-solid was too fine a distinction on
  one LED at stage distance. The MODE LED now reports the interaction mode
  only — rec red / play green / FX blue, solid in every state — in
  `firmware/console_board` and on the on-screen `PedalFaceplate` simulator.
- **DAW export.** New `daw_export` package (pure Dart, no Flutter/engine
  dependency) turns a completed performance capture into a real **Ableton
  Live 12 `.als`** project: one audio track per non-empty track/live-input
  stem, arrangement-view clips at capture start, session-view loop clips per
  lane, and volume/mute **automation envelopes** thinned from the event log.
  Effects reach Live only as audio: every track uses its wet stem (dry when
  the wet render is missing), and `fx-chains.txt` records each lane's chain
  as text. The device-chain export that once wrote Segno VST3 devices, and
  the capture dialog's EXPORT card that reported on it, were removed in
  #1587 with the plugins (#940). **Note:** the presentation
  layer (`PerformanceRecorderCubit`, `PerformanceCompletionSheet`)
  currently imports `daw_export` and does its own file I/O directly rather
  than going through `performance_repository` — an accepted, documented
  layering shortcut, not yet folded into the repository.

---

## Locked design decisions (don't re-litigate)

- **Record is exclusive** — one input stream, one capturer; chained hand-off.
- **Latency compensation** — comp write + live monitoring + auto-offset from the
  loopback measurement, persisted per device.
- **Undo/redo** — multi-level, per track, overdub layers only. A **user clear
  is undoable**: it leaves a per-track restore point (take + layers + FX chains
  + mutes) that undo brings back; a post-clear-all toast and `⌘⇧C` restore the
  whole rig at once (undo-clear-all, derived from live restore points). The
  last clear, a Clear all or one track's (#1634, #1707), is restored by an
  Undo on any track with nothing newer of its own: no arm, and either empty
  or not capturing and not edited since the clear. So the Undo pedal, the
  keyboard and MIDI or CTRL bindings restore it from track 1 after Clear all
  and from whatever track a Track Hold clear left selected.
  Session-load clears stay destructive. Immediate swap (tiny click on undo
  accepted).
- **#4 loop multiples** — **auto-round on stop** (record freely from the loop
  top; round track length up to the nearest whole multiple of the base loop).
  Free-running `loop_iteration`; track reads its `(iter-start_iter) % k` segment.
  New-track first pass always begins at the loop top (phase-locked multiples);
  per-track multi-loop phase is relative to each track's own start, and
  each take keeps that lap through Stop-all, reopen, Session recall and undo
  (#854, owner 2026-11-03; #201's bar-1 option is dropped).
- **Fully free mode (no tempo)** — the looper is tempo-free: one master loop
  length set by the first recording, no metronome/click/count-in/tap-tempo, no
  loop↔tempo sync, no quantization. Captures start/stop immediately. BPM logic
  was deleted (not hidden) from engine → FFI → repo → bloc → UI. Loop multiples
  (#4), latency compensation, the waveform visualizer, Big Picture / two-window,
  and theming are retained. (Supersedes the earlier #2 loop↔tempo and #3
  quantize-start decisions, which were removed.) **Superseded in turn** by the
  tempo-aware engine (#263, #1179): tempo, click, count-in, quantization and
  the five looper modes are back, as `docs/handoff/segno-app/accepted-behavior.md`
  specifies.
- **Transport holds at the top when idle** — the master clock advances only
  while a track is active; otherwise it sits at 0. Play always resumes from the
  beginning, never mid-loop in silence.
- **8 slots, two banks of four** — the engine always carries 8 tracks; the bank
  toggle is **app-side presentation** (show 4 = bank A, or two banks of 4). The
  engine processes all 8 (empty ones are silent).
- **Keyboard map lives in the Big Picture `Focus`** — plain keys are consumed
  (no macOS beep); number keys map to the visible bank, auto-switching banks when
  a digit targets the other four.

---

## Roadmap (path forward)

**Full multichannel per-track I/O routing — SHIPPED.** The "last big feature" is
done in code: it landed as the multi-lane / dual-route rework (per-lane
input/output masks through the native engine `LE_CMD_SET_LANE_INPUT/OUTPUT` +
`le_lane_snapshot`, the `Lane` domain model + `setLaneInput/Output` repo methods,
`LooperLaneInput/OutputChanged` bloc events, and the `lane_graph_view.dart`
wiring UI). Plan: `docs/plan/2026-06-09-feat-multichannel-routing-plan.md`. Only
the **on-hardware end-to-end validation** (full-count interface plugged in)
remains open — see "On-hardware validations" below.

### Possible next steps (no hard dependency)
- **Accessibility pass** — no `Semantics` coverage yet (theming + golden tests
  are done). Screen-reader labels, focus order, keyboard-nav a11y tests.

### Deferred (need hardware / 2nd display)
- `midi_client` — real USB-MIDI binding **SHIPPED** (PRs #39/#40/#42): native
  `le_midi_*` capture seam → one `MidiControllerSource` per plugged-in device,
  owned by `MidiDeviceRepository`, so every connected controller feeds the
  mappings learned from it (#1040). Hardware-gated only for a live DIN-MIDI
  smoke test and a two-controller check.
- **VST3/CLAP plugin hosting on Linux.** Hosting is on by default only on
  macOS; the build hook (`packages/segno_engine/hook/build.dart`) passes
  `SEGNO_ENABLE_PLUGINS=OFF` for Linux, since third-party plugins rarely ship
  for aarch64 Linux. Turning it on is a change to the hook.
- **Readout screen** — the console's 7″ runs as the second Flutter engine under
  ivi-homescreen, fed over the screen link (`lib/visualizer/screen_link.dart`,
  #1318, #1330); the on-device check is in `docs/HARDWARE_VALIDATION.md`.
- **Device hot-plug / reconnect — SHIPPED** (PR #41-era `feat/audio-device-a2`):
  `LooperRepository` reconnect supervisor (`_intendRunning` guard,
  `_attemptReconnect`, `_pinnedDevicesPresent`) + `devicePresent` UI banner.
- **Phase 4:** sessions save/load + WAV export ✅, theming ✅, golden tests ✅.
  Remaining: accessibility (see above).
- **Raspberry Pi GPIO backend — DROPPED** (2026-07-22): won't be built. No
  `gpio_client` / libgpiod package is planned, and `ControllerSourceKind` is
  MIDI-only (the once-planned `gpio` variant was never added).

### On-hardware validations still open
- Phase-1 **latency gate** (≤10 ms round-trip) — needs a class-compliant
  interface + a loopback cable; see `docs/HARDWARE_VALIDATION.md`.
- Audible tightness of latency compensation and undo/redo clicks.

---

## Test counts (last green)
native (all C tests: incl. mid-loop record, transport reset single- &
multi-track, loop multiples, loop-viz, per-track effects DSP, session
export/import roundtrip, **single-chain monitor + record-FX snapshot +
RT-safety + structural output gate**) ·
segno_engine (dart, the FFI/plugin layer — was labeled "plugin") 138 (~7
skipped) · controller_repository 18 · looper_repository 184 (~6 skipped) ·
settings_repository 65 · session_repository 57 · local_storage_client 1 ·
performance_repository 56 · pedal_repository 116 · midi_device_repository 22 ·
routing_graph 45 · wav_codec 5 · daw_export 79 · app 737 (~13 skipped) excl.
author-only `screenshots`-tagged goldens (auto-start/first-run, big-picture
settings + access, banks + A/B, performance keyboard, functional-settings,
**Signal three-list surface: SignalRows flatten + single-lane collapse +
tags, routing-chip toggle + picker, capture re-assign, tap-to-trace
dim/clear, output gate + a11y, no-active-outputs notice, responsive
stacking, contextual dock**, session menu, **performance recorder UI +
pedal arm/disarm**, **DAW export**). `flutter analyze` clean;
macOS app builds end-to-end. `LE_MAX_TRACKS = 8`, `LE_MAX_CHANNELS = 32`,
`LE_FX_MAX = 8`, `kMaxOutputs = 8`.

### 2026-09-07 — Supplier handoff packaging

Prepared `hardware/enclosure/out/segno_dinacut_2026-09-07.zip` with 22 unchanged,
previously reviewed CAD/drawing files plus Spanish text instructions and a hash
manifest. Eight fabricated pieces use seven distinct designs; the assembly STEP
is reference only. Added the request to qualify laser cutting of the lid
fastener holes; DRILL geometry and its current post-bend meaning are unchanged.
The complete enclosure stack is grouped separately by supplier in
`segno_archivos_completos_2026-09-07.zip`. Verified all five original archive
hashes and all 88 members against loose files, then checked the new packages.
Nothing was sent; supplier and physical acceptance remain open. Evidence:
`docs/reviews/sheetmetal-release-fixes/dinacut-handoff-verification.json`.

## Reversible-edits reconstruction (2026-09-15)

The accepted mode-rules and reversible-edits slice is reconstructed on the
reviewed Tracks/UART base (`09c8e9c2`), retaining original slice parent
`6cdfb9fb`. Tracking: #1060, part of #1012 and integration #1058.

The user approved refusing recovery of a completed recording that does not
fit the current loop mode. Audio, history, effects and transport stay intact;
the app explains how to select Free and retry. A pending clock or unfinished
capture asks for a retry instead. No automatic mode change is made. Partial
takes inside an established Multi cycle still retain the whole loop span,
with silence outside the recorded fragment.

Frozen-clear ownership/reset, grouped Undo/Redo metadata, confirmed-mode
persistence and callback mode-fit races are repaired. Final validation passed:
2,255 app tests, 1,610 package tests, native safety configurations, 150 FFI
symbols, analysis, Bloc lint and formatting. Five review roles have no
unresolved findings. The stacked PR still needs remote CI and its human merge
gate; recording timing and later implementation slices remain in progress.
Details and validation boundaries are in
`docs/reviews/design-edits-restack/review.md` and `validation.md`.

## Physical pedal state integration — October 1, 2026

PR #1031 now uses one authoritative ten-pedal activity/color frame through the
app, setup map and current Pico 2 renderer. UART v8 / STATE51 avoids the separate
published v6/v7 hardware formats; intermediate #1029/#1030 must not be installed
alone. Ten eight-pixel indicators and the forty-pixel ring preserve the sourced
optical/current limits. No legacy protocol fallback or device flash.

Full app: 2,346 passing, six existing skips, 91.126% coverage. Pedal package:
213 passing, 97.743%. Firmware fixtures, actual sketch tests and Pico 2 compile
pass. Independent source/five-role review and a separate adversary are clean.
[Validation and limits](reviews/design-pedal-led-restack/README.md) bind the exact
candidate. Palette editing is the next slice; hardware acceptance remains open.

## Reusable LED palette — October 1, 2026

PR #1032 adds the accepted LED colors editor to Layout A. All ten physical
indicators have saved hues, including fixed controls. Reusable custom colors
keep stable identities; Hue/Saturation/Brightness edit exact RGB. Draft
preview stays local until durable Save, and Cancel preserves the live setup.
Color-only saves preserve held actions, pending gestures and delayed native
receipts. Actual assignment changes still retire those gestures.

The palette is app-owned configuration on the existing protocol 8 frame; no
firmware, native engine or package changes are introduced. Malformed explicit
settings are refused through the existing recovery path. Clear and Restore
retain later palette edits. The saved Pen note and setup images record the
color context and non-overlapping placement beside the raised pedal row.

Verification and review are recorded in
[the palette report](reviews/design-led-palette-restack/README.md). Physical
color appearance and brightness remain appliance checks.

## Pedal artwork reconciliation — October 1, 2026

PR #1034 restores measured geometry in the existing pedal widget, preserving
its enclosing hit areas, labels and state-driven indicators. The source and
independent render reviews are clean; the app suite passes 2,374 tests with
90.069% coverage. See `docs/reviews/design-pedal-art-restack/` for the source
binding, saved Pen reference, author visuals and separate review evidence.
Published-head CI and the human merge gate remain required.
