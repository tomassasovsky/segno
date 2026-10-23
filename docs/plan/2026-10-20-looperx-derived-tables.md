# Looper X derived parameter data (#891 Phase 0)

Tracking: #1386. Reference tables for the factory-rack parts of #887 (plan
PR #1372), from the #891 Phase 0 measurements
([comment](https://github.com/tomassasovsky/segno/issues/891#issuecomment-6299550525)).
`packages/fx_catalogue` applies the chain orders below as `kFxRackOrders`.

Derived from the owner's emulated Looper X 1.0.2 (HG08) in the #891 rig,
2026-10-20. Everything here is numbers, formulas, on-screen labels and chain
orders measured or read from the running app. No vendor code, disassembly,
QML or audio is included. Racks are named as the FX RACKS screen shows them
(Studio = the rack whose presets live under "Studio Rack").

## How the numbers were obtained

- **Ranges, steps, defaults, tapers:** the app registers every continuous
  rack parameter at startup with (default, display min, display max, display
  step, format, taper id). The rig logged those registrations with gdb and
  resolved names and formats offline.
- **Taper formulas:** read from the app's normaliser for each taper id, then
  checked two ways:
  - Factory presets: a parameter snaps to its display step, so preset values
    must land on the step grid of the right taper. All 187 parameters with
    preset values pass.
  - On screen: see the Master Vol and Spring Time checks below.
- **Chain order:** each rack's processor runs a fixed array of slots in index
  order, in series. Slot contents come from how the processor builds each rack.
- **Captures:** gated stimulus passes through Track 1 PRE, one pedal on at a
  time unless noted, Master Vol 0.0 dB. The stimulus is impulse, 20 Hz to
  20 kHz log sweep at -12 dBFS, 1 kHz ladder from -48 to 0 dBFS, and plucks.
  The WAVs stay on the rig machine.

## Stored value

Every parameter is stored as v in 0..1 (the preset JSON values). Stepped
controls store index/(count-1). The bar on screen fills to v.

## Tapers

| taper | display(v) | inverse v(display) | used by |
|---|---|---|---|
| linear | min + v·(max − min) | (d − min)/(max − min) | %, dB gains, Master Vol, Comp Thresh (0 to -60), Pitch Shift, Voice Vol, Reference |
| log | min·(max/min)^v | ln(d/min)/ln(max/min) | frequencies, Q, Comp Attack/Release, Spring Time, Speed |
| reverb time | (v + 0.45)/(1 − v) s, capped at 144 | (d − 0.45)/(d + 1) | Rev Length, Dub-Verb Dec, Amb-Verb Dec (0.45 to 144 s) |
| ratio | 1/(1 − v/1.0101) | 1.0101·(1 − 1/d) | Ed's Comp Ratio, 1 to 100 : 1 |
| cube dB | max + 60·log10(v); v = 0 is off (-200) | (10^((d − max)/20))^(1/3) | one Vocal Tuner level, -200 to +6 dB, 0 dB at v = 0.794 |

The ratio taper has only one parameter with preset values, too few to tell
it from linear; it rests on the normaliser alone.

The app's normaliser has more tapers that no rack parameter uses. They are
listed so nothing is mistaken for one of the five above:

- bipolar linear and bipolar square root about a centre of 0.5
- dB to linear gain, v = 10^(d/20)
- square law
- log1p
- square root of linear gain

### Master Vol (all racks)

display dB = -12 + 24·v, step 0.1 dB, default 0.5 = 0.0 dB (unity), linear
gain = 10^((24v − 12)/20).

- All 159 factory Master Vol values land on the 0.1 dB grid of this mapping.
- On screen: v = 0.5 shows 0.0 dB; v = 0.675 (Lead Crunch) shows 4.2 dB;
  v = 0.254 shows -5.9 dB.

### Other on-screen checks

- Spring Time v = 0.30103 shows 2.00 s (log taper; linear would give 3.71 s).
- Bar fills match the stored value to about 0.003.
- Rev Length default v = 0.16 shows 0.73 s, matching the reverb-time taper
  ((0.16 + 0.45)/0.84 = 0.726).
- Vocal Tuner defaults: Highpass v = 0.2 shows 4 Hz (log, 1 to 1000 Hz);
  Speed v = 0.5 shows 32 ms (log, 1 to 1000 ms); Gate Thresh v = 0.4 shows
  -72 dB (linear, -120 to 0).
- Voice 1 Vol v = 0.909 shows 0.0 dB (linear, -60 to +6).

## Stepped controls (order confirmed on screen)

- Del Mode (12): DIGI, DIGI L/R, DIGI GRV, DAMPED, DAMPED L/R, DAMPED GRV,
  RESO LO, RES LO L/R, RES LO GRV, RESO HI, RES HI L/R, RES HI GRV. Default
  RESO LO.
  - L/R modes put the right side half a period later; at 1/8D and 120 BPM
    that is left 375 ms, right 187.5 ms.
  - GRV modes put the right echo at 0.837 of the period (313.8 ms against
    375 ms).
- Mod Mode (Guitar): CHORUS, PHASER, FLANGER.
- Cab (Guitar): D.I., BRIT, 1x8", 1x12", 2x10", 2x12", 4x10", 4x12"
  (default), 1x15", BASS, 4x10"; the 12th row is off screen.
- Rev ER (Drum): BOOTH, CLUB, ROOM, SMALL CHAMBER, Med CHAMBER,
  LARGE CHAMBER, SMALL STUDIO, LARGE STUDIO (default), SCORING STAGE,
  PHILHARMONIC, CONCERT HALL, CHURCH, OPERA HOUSE, VINTAGE 1, VINTAGE 2.
- Slicer pattern (first 11): AABB (default), ABCC, AACD, ABC_, A_C_, A_CC,
  A._C._, ABcccc, AAccdd, AB_dd, AA_dd.
- Del Time divisions follow the enum table from the earlier session. The
  default 1/8D gives 375 ms at 120 BPM.
- Smart Tune at C Major pulls a 1 kHz tone to 988 Hz (B5). With
  Reference 460 Hz it pulls it to 1032 Hz.
- Dual Octaver: High Mode Off is one octave down; High Mode On ("mode 1")
  is one octave up.


## Parameter ranges and steps

Display range, display step, taper (see Tapers), default stored value (0..1) and the on-screen unit. One row per rack and parameter, in the order the rack registers them. Stepped controls are listed under Stepped controls.

| rack | parameter | min | max | step | taper | default | unit |
|---|---|---|---|---|---|---|---|
| Ed's | Octave 1 Vol | 0 | 100 | 1 | linear | 1 | % |
| Ed's | Octave 2 Vol | 0 | 100 | 1 | linear | 0 | % |
| Ed's | Octave Mix | 0 | 100 | 1 | linear | 1 | % |
| Ed's | Wah Pedal | 0 | 100 | 0.1 | linear | 0.619 | % |
| Ed's | Comp Thresh | 0 | -60 | 0.1 | linear | 0.35 | dB |
| Ed's | Comp Ratio | 1 | 100 | 0.1 | ratio | 0.76 | : 1 |
| Ed's | Comp Attack | 0.01 | 300 | 0.01 | log | 0.5 | ms |
| Ed's | Comp Release | 5 | 4000 | 1 | log | 0.5 | ms |
| Ed's | Comp Make-Up | 0 | 30 | 0.1 | linear | 0.06 | dB |
| Ed's | OD Drive | 0 | 100 | 0.1 | linear | 0.09 | % |
| Ed's | OD Tone | 0 | 100 | 0.1 | linear | 0.5 | % |
| Ed's | Amp Drive | 0 | 100 | 0.1 | linear | 0.18 | % |
| Ed's | Amp Modern | 0 | 100 | 0.1 | linear | 0.5 | % |
| Ed's | Amp Bass | 0 | 100 | 0.1 | linear | 0.55 | % |
| Ed's | Amp Treble | 0 | 100 | 0.1 | linear | 0.47 | % |
| Ed's | Chor Rate | 0 | 100 | 0.1 | linear | 0.45 | % |
| Ed's | Chor Depth | 0 | 100 | 0.1 | linear | 0.21 | % |
| Ed's | Chor Mix | 0 | 100 | 0.1 | linear | 0.5 | % |
| Ed's | Del Feedback | 0 | 100 | 1 | linear | 0.35 | % |
| Ed's | Del Mix | 0 | 100 | 0.1 | linear | 0.25 | % |
| Ed's | Rev Length | 0.45 | 144 | 0.01 | reverb time | 0.3668 | sec |
| Ed's | Rev Bright | 0 | 100 | 0.1 | linear | 0.8 | % |
| Ed's | Rev Mix | 0 | 100 | 0.1 | linear | 0.05 | % |
| Ed's | EQ Low Cut | 20 | 8000 | 1 | log | 0.21 | Hz |
| Ed's | EQ Low | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Ed's | EQ Low Freq | 20 | 1000 | 1 | log | 0.384476 | Hz |
| Ed's | EQ Low Q | 0.4 | 2 | 0.01 | log | 0 | - |
| Ed's | EQ Lo Mid | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Ed's | EQ Lo Mid Freq | 100 | 8000 | 1 | log | 0.17574 | Hz |
| Ed's | EQ Lo Mid Q | 0.4 | 10 | 0.01 | log | 0.174 | - |
| Ed's | EQ Hi Mid | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Ed's | EQ Hi Mid Freq | 100 | 8000 | 1 | log | 0.66061 | Hz |
| Ed's | EQ Hi Mid Q | 0.4 | 10 | 0.01 | log | 0.15557 | - |
| Ed's | EQ High | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Ed's | EQ High Freq | 2000 | 16000 | 1 | log | 0.5278 | Hz |
| Ed's | EQ High Q | 0.4 | 2 | 0.01 | log | 0 | - |
| Ed's | EQ High Cut | 120 | 20000 | 1 | log | 1 | Hz |
| Ed's | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Vocal | Highpass | 1 | 1000 | 1 | log | 0 | Hz |
| Vocal | Gate Thresh | -120 | 0 | 1 | linear | 0 | dB |
| Vocal | Pitch Shift | -12 | 12 | 0.1 | linear | 0.5 | - |
| Vocal | Pitch Mix | 0 | 100 | 0.1 | linear | 1 | % |
| Vocal | Doubler Mix | 0 | 100 | 0.1 | linear | 1 | % |
| Vocal | Del Feedback | 0 | 100 | 1 | linear | 0.5 | % |
| Vocal | Del Mix | 0 | 100 | 0.1 | linear | 0.2 | % |
| Vocal | Rev Length | 0.45 | 144 | 0.01 | reverb time | 0.4 | sec |
| Vocal | Rev Bright | 0 | 100 | 0.1 | linear | 0.8 | % |
| Vocal | Rev Mix | 0 | 100 | 0.1 | linear | 0.15 | % |
| Vocal | Comp Thresh | 0 | -60 | 0.1 | linear | 0.8 | dB |
| Vocal | Comp Make-Up | 0 | 30 | 0.1 | linear | 0.6 | dB |
| Vocal | EQ Low | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Vocal | EQ Mid | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Vocal | EQ High | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Vocal | EQ Air | -18 | 18 | 0.1 | linear | 0.7 | dB |
| Vocal | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Guitar | Wham Pedal | 0 | 100 | 0.1 | linear | 0 | % |
| Guitar | Wah Pedal | 0 | 100 | 0.1 | linear | 0 | % |
| Guitar | OD Drive | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | OD Tone | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Amp Drive | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Amp Modern | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Amp Bass | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Amp Treble | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Mod Rate | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Mod Depth | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Mod Mix | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Spring Time | 1 | 10 | 1 | log | 0.3 | s |
| Guitar | Spring Mix | 0 | 100 | 0.1 | linear | 0.5 | % |
| Guitar | Del Feedback | 0 | 100 | 1 | linear | 0.5 | % |
| Guitar | Del Mix | 0 | 100 | 0.1 | linear | 0.2 | % |
| Guitar | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Lo-Fi | LPF Cutoff | 20 | 20000 | 1 | log | 1 | Hz |
| Lo-Fi | LPF Reso | 0 | 100 | 0.1 | linear | 1 | % |
| Lo-Fi | Vinyl Drive | 0 | 100 | 0.1 | linear | 0.4 | % |
| Lo-Fi | Vinyl Freq | 50 | 5000 | 1 | log | 0.35 | Hz |
| Lo-Fi | Vinyl Noise | 0 | 100 | 0.1 | linear | 0.3 | % |
| Lo-Fi | Vinyl Noise-Tone | 0 | 100 | 0.1 | linear | 0.9 | % |
| Lo-Fi | Degrade Freq | 500 | 50000 | 1 | log | 1 | Hz |
| Lo-Fi | Degrade Filter | 0 | 100 | 0.1 | linear | 1 | % |
| Lo-Fi | Degrade Mix | 0 | 100 | 0.1 | linear | 1 | % |
| Lo-Fi | Dist Drive | 0 | 100 | 0.1 | linear | 0.2 | % |
| Lo-Fi | Dist Tone | 0 | 100 | 0.1 | linear | 0.5 | % |
| Lo-Fi | EQ Low Cut | 20 | 8000 | 1 | log | 0 | Hz |
| Lo-Fi | EQ High Cut | 120 | 20000 | 1 | log | 1 | Hz |
| Lo-Fi | EQ Mid Freq | 120 | 16000 | 1 | log | 0.5 | Hz |
| Lo-Fi | EQ Mid Q | 0.4 | 10 | 0.1 | log | 0.2 | - |
| Lo-Fi | EQ Mid Gain | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Lo-Fi | Del Feedback | 0 | 100 | 1 | linear | 0.5 | % |
| Lo-Fi | Del Mix | 0 | 100 | 0.1 | linear | 0.2 | % |
| Lo-Fi | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Dub | Doubler Sep | 0 | 100 | 0.1 | linear | 1 | % |
| Dub | Doubler Mix | 0 | 100 | 0.1 | linear | 1 | % |
| Dub | Del L/R Ratio | 100 | 50 | 1 | linear | 0 | 100 : |
| Dub | Del Feedback | 0 | 100 | 1 | linear | 0.6 | % |
| Dub | Del Damp | 0 | 100 | 1 | linear | 0.7 | % |
| Dub | Del Reso | 0 | 100 | 1 | linear | 0.8 | % |
| Dub | Del Res-Freq | 100 | 10000 | 1 | log | 0.35 | Hz |
| Dub | Dub-Verb Dec | 0.45 | 144 | 0.01 | reverb time | 0.7 | sec |
| Dub | Dub-Verb Vol | 0 | 100 | 0.1 | linear | 0.2 | % |
| Dub | Amb-Verb Dec | 0.45 | 144 | 0.01 | reverb time | 0.2 | sec |
| Dub | Amb-verb Vol | 0 | 100 | 0.1 | linear | 0.4 | % |
| Dub | Amb-Dub Mix | 0 | 100 | 0.1 | linear | 0.4 | % |
| Dub | Comp Thresh | 0 | -60 | 0.1 | linear | 0.8 | dB |
| Dub | Comp Make-Up | 0 | 30 | 0.1 | linear | 0.8 | dB |
| Dub | EQ Low Cut | 20 | 8000 | 1 | log | 0.1 | Hz |
| Dub | EQ High Cut | 120 | 20000 | 1 | log | 1 | Hz |
| Dub | EQ Mid Freq | 120 | 16000 | 1 | log | 0.5 | Hz |
| Dub | EQ Mid Q | 0.4 | 10 | 0.1 | log | 0.2 | - |
| Dub | EQ Mid Gain | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Dub | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Drum | Attack | 0 | 100 | 1 | linear | 0.5 | % |
| Drum | Attack Length | 0 | 100 | 1 | linear | 0.5 | % |
| Drum | Sustain | 0 | 100 | 1 | linear | 0.5 | % |
| Drum | Del Feedback | 0 | 100 | 1 | linear | 0 | % |
| Drum | Del Freq | 100 | 10000 | 1 | log | 0.25 | Hz |
| Drum | Del Mix | 0 | 100 | 0.1 | linear | 0.1 | % |
| Drum | Rev Length | 0.45 | 144 | 0.01 | reverb time | 0.16 | sec |
| Drum | Rev Lo/Hi | 0 | 100 | 0.1 | linear | 0.5 | % |
| Drum | Rev Tail/ER | 0 | 100 | 0.1 | linear | 0.3 | % |
| Drum | Rev Density | 0 | 100 | 0.1 | linear | 1 | % |
| Drum | Rev Mix | 0 | 100 | 0.1 | linear | 0.5 | % |
| Drum | EQ Low | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Drum | EQ Mid Freq | 40 | 8000 | 0.1 | log | 0.5 | Hz |
| Drum | EQ Mid | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Drum | EQ High | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Drum | Comp Attack | 0.1 | 300 | 0.1 | log | 0.2 | ms |
| Drum | Comp Thresh | 0 | -60 | 0.1 | linear | 0.7 | dB |
| Drum | Comp Make-Up | 0 | 30 | 0.1 | linear | 0.2 | dB |
| Drum | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Studio | Pitch Shift | -12 | 12 | 0.1 | linear | 0.5 | - |
| Studio | Pitch Mix | 0 | 100 | 0.1 | linear | 1 | % |
| Studio | Dist Drive | 0 | 100 | 0.1 | linear | 0.5 | % |
| Studio | Mod Rate | 0 | 100 | 0.1 | linear | 0.5 | % |
| Studio | Mod Depth | 0 | 100 | 0.1 | linear | 0.5 | % |
| Studio | Doubler Mix | 0 | 100 | 0.1 | linear | 1 | % |
| Studio | Del Feedback | 0 | 100 | 1 | linear | 0.5 | % |
| Studio | Del Mix | 0 | 100 | 0.1 | linear | 0.2 | % |
| Studio | Rev Length | 0.45 | 144 | 0.01 | reverb time | 0.4 | sec |
| Studio | Rev Mix | 0 | 100 | 0.1 | linear | 0.15 | % |
| Studio | Comp Thresh | 0 | -60 | 0.1 | linear | 0.8 | dB |
| Studio | Comp Make-Up | 0 | 30 | 0.1 | linear | 0.6 | dB |
| Studio | EQ Low | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Studio | EQ Mid | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Studio | EQ High | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Studio | EQ Air | -18 | 18 | 0.1 | linear | 0.7 | dB |
| Studio | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Rhythmic | LPF Cutoff | 20 | 20000 | 1 | log | 1 | Hz |
| Rhythmic | LPF Reso | 0 | 100 | 0.1 | linear | 1 | % |
| Rhythmic | LPF LFO Depth | 0 | 100 | 0.1 | linear | 1 | % |
| Rhythmic | Slic Mix | 0 | 100 | 0.1 | linear | 1 | % |
| Rhythmic | Pumper Depth | 0 | 100 | 0.1 | linear | 0.7 | % |
| Rhythmic | EQ Low Cut | 20 | 8000 | 1 | log | 0 | Hz |
| Rhythmic | EQ High Cut | 120 | 20000 | 1 | log | 1 | Hz |
| Rhythmic | EQ Mid Freq | 120 | 16000 | 1 | log | 0.5 | Hz |
| Rhythmic | EQ Mid Gain | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Rhythmic | Del Feedback | 0 | 100 | 1 | linear | 0.5 | % |
| Rhythmic | Del Mix | 0 | 100 | 0.1 | linear | 0.2 | % |
| Rhythmic | Rev Length | 0.45 | 144 | 0.01 | reverb time | 0.4 | sec |
| Rhythmic | Rev Mix | 0 | 100 | 0.1 | linear | 0.15 | % |
| Rhythmic | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Vocal Tuner | Highpass | 1 | 1000 | 1 | log | 0.2 | Hz |
| Vocal Tuner | Gate Thresh | -120 | 0 | 1 | linear | 0.4 | dB |
| Vocal Tuner | Speed | 1 | 1000 | 1 | log | 0.5 | ms |
| Vocal Tuner | Reference | 420 | 460 | 0.1 | linear | 0.5 | Hz |
| Vocal Tuner | Tightness | 0 | 100 | 1 | linear | 0.7 | % |
| Vocal Tuner | Voice 1 Pan | -100 | 100 | 1 | linear | 0.5 | % |
| Vocal Tuner | Voice 2 Pan | -100 | 100 | 1 | linear | 0.5 | % |
| Vocal Tuner | High EQ | -12 | 12 | 0.1 | linear | 0.5 | db |
| Vocal Tuner | High EQ Freq | 1000 | 20000 | 1 | linear | 0.5 | Hz |
| Vocal Tuner | Mid EQ | -12 | 12 | 0.1 | linear | 0.5 | db |
| Vocal Tuner | Mid EQ Freq | 200 | 4000 | 1 | linear | 0.5 | Hz |
| Vocal Tuner | Low EQ | -12 | 12 | 0.1 | linear | 0.5 | db |
| Vocal Tuner | Low EQ Freq | 20 | 800 | 0.01 | linear | 0.5 | Hz |
| Vocal Tuner | Voice 1 Vol | -60 | 6 | 0.1 | linear | 0.909091 | dB |
| Vocal Tuner | Voice 2 Vol | -60 | 6 | 0.1 | linear | 0.909091 | dB |
| Vocal Tuner | Doubler Mix | 0 | 100 | 0.1 | linear | 1 | % |
| Vocal Tuner | Del Feedback | 0 | 100 | 1 | linear | 0.5 | % |
| Vocal Tuner | Del Mix | 0 | 100 | 0.1 | linear | 0.2 | % |
| Vocal Tuner | Rev Length | 0.45 | 144 | 0.01 | reverb time | 0.1 | sec |
| Vocal Tuner | Rev Bright | 0 | 100 | 0.1 | linear | 0.8 | % |
| Vocal Tuner | Rev Mix | 0 | 100 | 0.1 | linear | 0.1 | % |
| Vocal Tuner | Comp Thresh | 0 | -60 | 0.1 | linear | 0.5 | dB |
| Vocal Tuner | Comp Make-Up | 0 | 30 | 0.1 | linear | 0.4 | dB |
| Vocal Tuner | EQ Low | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Vocal Tuner | EQ Mid | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Vocal Tuner | EQ High | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Vocal Tuner | EQ Air | -18 | 18 | 0.1 | linear | 0.5 | dB |
| Vocal Tuner | Master Vol | -12 | 12 | 0.1 | linear | 0.5 | dB |
| Vocal Tuner | Voice Gender (each voice) | -50 | 50 | 1 | linear | 0.5 | - |
| Vocal Tuner | (harmony level, unnamed; cube dB) | -200 | 6 | 0.1 | cube dB | 0.793701 | dB |

## Chain order

Signal order inside each rack, first to last. All slots run in series.

- Mod in Guitar is three slots in series: Chorus, then Phaser, then Flanger.
  Mod Mode picks which of the three runs.
- Studio's Mod is two slots: Chorus, then Tremolo.
- "(?)" marks the one slot recorded at medium confidence, Vocal Tuner's
  Master Vol. Every other slot is recorded at high confidence.
- The editor's pedal order is recorded for two racks only, Ed's and Dub.
  In Ed's Rack the editor draws Delay before Reverb, but the processor runs
  Reverb then Delay. Both are linear, so in series the order does not change
  the sound.
- Dub-Verb before Amb-Verb comes from the Dub editor order only; the
  processor shows two reverb slots and no names. Again both are linear.
- The Vocal and Vocal Tuner presets power the highpass and gate slots with
  one key, HP/Gate.

- **Drum Rack**: Transient -> Delay -> Reverb -> EQ -> Comp -> Master Vol
- **Vocal Rack**: Highpass -> Gate -> Pitch -> Doubler -> Delay -> Reverb -> Comp -> EQ -> Master Vol
- **Guitar Rack**: Wham -> OvDrive -> Wah -> Amp -> Chorus -> Phaser -> Flanger -> Spring -> Delay -> Master Vol
- **Rhythmic Rack**: LPF -> Slicer -> Pumper -> EQ -> Delay -> Reverb -> Master Vol
- **Studio Rack**: Pitch -> Dist -> Doubler -> Chorus -> Tremolo -> Delay -> Reverb -> Comp -> EQ -> Master Vol
- **Ed's Rack**: Octave -> Wah -> Comp -> OvDrive -> Amp -> Chorus -> Reverb -> Delay -> EQ -> Master Vol
- **Vocal Tuner Rack**: Highpass -> Gate -> Smart Tune -> Harmonizer -> Doubler -> Delay -> Reverb -> Comp -> EQ -> Master Vol (?)
- **Dub Rack**: Doubler -> Del -> Dub-Verb -> Amb-Verb -> Comp -> EQ -> Master Vol
- **Lo-Fi Rack**: LPF -> Vinyl -> Degrade -> Dist -> EQ -> Delay -> Master Vol

## Reference captures

Kinds #1372 marks as waiting on reference audio, with the settings captured.
"s3", "s4" and "s5" are rig sessions; seg is the pass index in that session.

| session/seg | kind | rack | setting on screen | quick check |
|---|---|---|---|---|
| s3/1 | Amp+Cab | Guitar / Lead Crunch | Amp only: Drive 22.7 % Modern 66.7 % Bass 60 % Treble 50 % Cab 4x12 | 1 kHz gain -1.3 dB small signal, saturates near -17.5 dBFS out, THD -11.9 dB at -12 dBFS in |
| s3/2 | Amp+Cab | Guitar / Lead Crunch | Amp Drive 80 % (bar 0.799) | +19.8 dB small signal, THD -5.7 dB at -24 dBFS in |
| s3/3 | Amp+Cab | Guitar / Lead Crunch | Amp Drive ~10 % (drag target; shot taken before redraw) | -3.1 dB small signal |
| s3/4 | Mod (chorus) | Guitar / Lead Crunch | Mod only: CHORUS Rate 32.6 % Depth 12 % Mix 33.2 % | residual vs dry -13.7 dB |
| s3/5 | Mod (chorus) | Guitar / Lead Crunch | Mod Rate 79.7 % | residual -13.6 dB |
| s3/6 | Reverb (spring) | Guitar / Lead Crunch | Spring only: Time 2.00 s Mix 28.9 % | residual -4.1 dB |
| s3/7 | Reverb (spring) | Guitar / Lead Crunch | Spring Time bar 0.90 (= 7.9 s by the log taper) | residual -3.6 dB |
| s3/8 | Mode delay | Guitar / Lead Crunch | Delay only: Time 2/4 Mode RES HI L/R Feedback 29 % Mix 9 % | residual -37.4 dB |
| s3/9 | Whammy | Guitar / Lead Crunch | Whammy only: Range -12 Pedal 0 % | 1 kHz stays 1000 Hz |
| s3/10 | Whammy | Guitar / Lead Crunch | Wham Pedal 99.8 % | 1 kHz -> 506 Hz (-11.8 semitones) |
| s4/0 | Mod (phaser) | Guitar / no preset | PHASER Rate 50 % Depth 50 % Mix 50 % |  |
| s4/1 | Mod (phaser) | Guitar / no preset | PHASER Rate 10.6 % |  |
| s4/2 | Mod (flanger) | Guitar / no preset | FLANGER Rate 10.6 % Depth 50 % |  |
| s4/3 | Mod (flanger) | Guitar / no preset | FLANGER Rate 10.6 % Depth 90 % |  |
| s4/4 | Mode delay | Guitar / no preset | DIGI; Del Time 1/8D (120 BPM) Feedback 50 % Mix 30 % | echoes 375, 750 ms both sides |
| s4/10 | Mode delay | Guitar / no preset | DIGI L/R | right side offset half a period: 187.5, 562.5 ms |
| s4/11 | Mode delay | Guitar / no preset | DIGI GRV | right echo at 313.8 ms (left 375 ms) |
| s4/12 | Mode delay | Guitar / no preset | DAMPED | echoes 375 ms |
| s4/13 | Mode delay | Guitar / no preset | RESO LO | echoes 375 ms |
| s4/14 | Mode delay | Guitar / no preset | RESO HI | echoes 375 ms |
| s4/15 | Mode delay | Guitar / no preset | RES HI L/R | right 187.5, 562.5 ms |
| s4/16 | Amp+Cab | Guitar / no preset | Amp all 50 %; Cab 4x12" (default) | sweep level 8 kHz -20 dB re 1 kHz -6 dB |
| s4/17 | Amp+Cab | Guitar / no preset | Cab D.I. | flat sweep (no cab roll-off) |
| s4/18 | Amp+Cab | Guitar / no preset | Cab BRIT | 8 kHz -25.5 dB |
| s4/19 | Amp+Cab | Guitar / no preset | Cab 1x12" | 3 kHz peak |
| s4/20 | Amp+Cab | Guitar / no preset | Cab BASS | 100 Hz +3.4 dB; 3 kHz -15 dB |
| s4/21 | Slicer | Rhythmic / no preset | Pattern AABB Step 1/16 Mix 100 % (120 BPM) |  |
| s4/22 | Slicer | Rhythmic / no preset | Mix 50.3 % |  |
| s4/23 | Slicer | Rhythmic / no preset | Pattern A_C_ Mix 99.6 % | 1 kHz tone gated 54 dB deep |
| s4/24 | Slicer | Rhythmic / no preset | Pattern ABcccc Mix 99.6 % |  |
| s4/25 | Pumper | Rhythmic / no preset | Depth 70 % Rate 1/4 | 1 kHz tone envelope 20 dB deep |
| s4/26 | Pumper | Rhythmic / no preset | Depth 99.6 % | 40 dB deep |
| s4/27 | Pumper | Rhythmic / no preset | Depth 30.3 % | 6 dB deep |
| s4/28 | Reverb | Drum / no preset | ER LARGE STUDIO, Length 0.73 s, Lo/Hi 50 %, Tail/ER 30 %, Density 100 %, Mix 30 % | Length 0.73 s on screen = reverb-time taper at v 0.16 |
| s4/29 | Reverb | Drum / no preset | Rev Length bar 0.60 (2.63 s by the taper) |  |
| s5/0 | Reverb | Drum / no preset | ER BOOTH, Length 0.73 s, Density 100 %, Mix 30 % |  |
| s5/1 | Reverb | Drum / no preset | ER Med CHAMBER |  |
| s5/2 | Reverb | Drum / no preset | ER CONCERT HALL |  |
| s5/3 | Reverb | Drum / no preset | ER CONCERT HALL, Density 30.4 % |  |
| s5/4 | Dual Octaver | Ed's / no preset | Oct High Mode Off, Octave 1 Vol 100 %, Octave 2 Vol 0 %, Mix 100 % | 1 kHz -> 504 Hz (octave down) |
| s5/5 | Dual Octaver (mode 1) | Ed's / no preset | Oct High Mode On | 1 kHz -> 2 kHz (octave up) |
| s5/6 | Dual Octaver (mode 1) | Ed's / no preset | High Mode On, Octave 2 Vol 100 % |  |
| s5/7 | Dual Octaver (mode 1) | Ed's / no preset | High Mode On, Octave 2 Vol 100 %, Mix 50 % | 1 kHz and 2 kHz equal |
| s5/8 | Smart Tune | Vocal Tuner / no preset | Speed 32 ms, Scale Root C, Major, Audio Type Mid, Tracking Default, Reference 440 Hz | 1 kHz -> 988 Hz (B5) |
| s5/9 | Smart Tune | Vocal Tuner / no preset | Speed 1 ms | 988 Hz |
| s5/10 | Smart Tune | Vocal Tuner / no preset | Speed 1000 ms | still gliding (996 Hz in the 0.5 s tone) |
| s5/11 | Smart Tune | Vocal Tuner / no preset | Speed 32 ms, Reference 460 Hz | 1 kHz -> 1032 Hz (B5 at A = 460) |
| s5/12 | Harmonizer | Vocal Tuner / no preset | Mode Scale, Auto Source Input 1, Key A, Major, Voice 1 on (+5th), Voice 2 on (+3rd), Stereo on, Tightness 70 % | voices split left/right |
| s5/13 | Harmonizer | Vocal Tuner / no preset | Voice 2 Off |  |
| s5/14 | Harmonizer | Vocal Tuner / no preset | Voice 2 Off, Stereo Off | both sides identical |
| s5/15 | Harmonizer | Vocal Tuner / no preset | Voice 2 Off, Stereo Off, Voice 1 Gender +49 |  |
