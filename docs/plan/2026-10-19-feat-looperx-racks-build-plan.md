# Looper X factory racks: build plan (#887)

Status: **build plan, revision 2.** Direction approved 2026-08-27 (full sound
reproduction, naming deferred). Revised 2026-10-20 after four reviews of PR
#1372 (claims, real time and CPU, design and scope, fidelity and UX) and the
owner's decisions of 2026-10-19, recorded on #887 and #891. This replaces the
unmerged `docs/plan/2026-08-27-feat-looperx-rack-reproduction-plan.md`, kept on
`claude/sheeran-looper-extract-bd5cc9`. Written against `claude/segno-integration`.

The owner has authorization to reuse the Sheeran Looper X (HG08) factory
content. Presets, parameter schemas and enum tables may be committed; the
Looper X executable and libraries may not.

## Owner decisions this plan follows

1. **The bar for "reproduced".** Each part passes objective checks first:
   discrete steps exact, kernel response within the tolerances the part
   states, offline render equal to live, console worst-block CPU under the
   part's budget. Then the owner A/Bs named presets by ear and the sign-off is
   recorded on the part's issue. Null tests against reference audio are added
   wherever the emulation capture (#891) works.
2. **Phase 0 is pursued, not time-boxed.** Modules whose per-step sound cannot
   come from the preset data (the 12 cabinets, 15 drum rooms, 12 delay modes,
   the slicer and pumper patterns, any other per-step voicing) wait for
   reference audio. Modules that the presets and the binary's parameter
   names fully define proceed.

## What the trunk has today

- 64 chain slots (`LE_FX_MAX`), 4 normalized parameters per slot
  (`LE_FX_PARAMS`), 129 chain owners (64 lanes, 8 track buses, 40 monitored
  sources, the all-tracks bus, 16 output buses; the all-tracks config runs on
  16 per-bus states).
- Seven built-ins (`le_fx_type` drive .. reverb) plus hosted plugins at code 8.
  Per-slot DSP state is inlined in `le_fx_state` at `[LE_FX_MAX]`; delay rings
  are one second per channel (`fx_delay_frames = sample_rate`), allocated with
  plain `calloc`.
- The catalogue (`packages/fx_catalogue`) ships all 159 presets, the rack art
  and a 26-row module table. Adding a rack builds one entry per module
  (`fxModuleEntry`); six modules map to a built-in, partially.
- The editor shows raw values (`toStringAsFixed(2)`) under English labels
  from the Dart table `TrackEffectType.params`, with "Scale unverified" on
  every parameter except the rack level.
- Offline renders (`perf_render.c`, `engine_cache.c`, `engine_render.c`) run
  `fx_apply_chain` on heap states. The perf log carries tempo only inside
  `LE_PLOG_RETIME`; `LE_CMD_SET_TEMPO` is not logged.

## What the racks need

Per rack, the modules and their exposed parameter counts (power key excluded):

| rack | modules |
|---|---|
| Drum | Compressor 3, EQ 4, Delay 4, Reverb 6, Transient 3 |
| Dub | Compressor 2, Para EQ 5, Dub Delay 6, Doubler 2, Dub-Verb 2, Amb-Verb 3 |
| Ed's | Octaver 4, Wah 1, Compressor 5, Overdrive 2, Amp+Cab 5, Chorus 3, EQ 14, Delay 4, Reverb 4 |
| Guitar | Whammy 2, Wah 1, Overdrive 2, Amp+Cab 5, Mod 4, Delay 4, Spring 2 |
| Lo-Fi | Para EQ 5, LPF 2, Vinyl 4, Degrade 3, Distortion 2, Delay 4 |
| Rhythmic | EQ 4, LPF 4, Slicer 3, Pumper 2, Delay 4, Reverb 3 |
| Studio | Compressor 2, EQ 4, Pitch Shift 2, Distortion 1, Doubler 1, Mod 3, Delay 4, Reverb 3 |
| Vocal | HP/Gate 2, Compressor 2, EQ 4, Pitch Shift 2, Doubler 1, Delay 4, Reverb 4 |
| Vocal Tuner | HP/Gate 2, Compressor 2, EQ 4, Smart Tune, Harmonizer, Doubler 1, Delay 4, Reverb 4 |

Every rack also carries `Master Vol`. Compressor appears in 6 racks, a reverb
of some kind in 8, Delay in all 9. Discrete parameters sit on a `1/(n-1)` grid
in the presets: Del Time and Slic Patt have 20 steps (Del Time is a note
division), Del Mode and Cab 12, Rev Mode 4, Drum Rev ER 15, Pitch Shift 25
(-12 .. +12 semitones).

The binary's internal parameter names describe one generic DSP module per
kind, with each rack exposing a subset: the EQ (`LowCutFreq`, `LowGain`,
`LowMidFreq`, ..., `HighCutType`), the delay (`Delay Time`, `Delay Sync`,
`Ratio`, `FdbkFilterFreq`, `FdbkFilterReso`, `FdbkResoFreq`), the reverb
(`Lowcut`, `Pre-Delay`, `ERGain`, `ER/Tail Mix`, `RoomSize`, `RTimeMain`,
`RTimeHigh`, `RTFreqHigh`, `ERType`, `ERSpread`, ...), the amp and cabinet
(`Knee`, `SoftClip`, `TopBoost`, `Bias`, `CabModel`, `LowF`, `MidF`, `MidQ`,
`MidShelf`, `Comb1`, `Comb2`, `CombMix`, `HighF`), the gate (`DenoiseFilter`).

### Two schema facts the shipped catalogue gets wrong

- The **Vocal Tuner shares parameters between two modules.** Presets with
  Smart Tune off still set Mode, Auto Source, Key and Scale Type for the
  Harmonizer ("Midi Harm": Auto Source = 1; "Scale Harm": Mode = 1, Key 3/11),
  and Smart Tune reads Key and the scale too. The binary runs a
  `ChordDetectorThread`, and Auto Source chooses Input 1-4 or MIDI.
- **`fx_module.dart` misfiles three keys**: `Dub Delay` is captured by
  "Dub reverb" through its `Dub` prefix group, so the Dub delay builds as the
  plain Delay; `Para EQ` (the EQ power key in Dub and Lo-Fi) is in
  `kFxUnclaimedGroups`; Smart Tune's power key is listed as `Mode` instead of
  `Smart Tune`.

## Engine kinds

One engine type per **kind**, carrying the generic module's whole parameter
set. A rack variant is the kind plus which parameters it exposes and the fixed
values of the rest, recorded in `kFxModuleBuilds`. This is the Looper X
binary's own design (one module per kind, racks expose subsets). The existing
seven built-ins stay unchanged; new kinds take codes from 9.

| kind | parameters (superset) | rack variants | status |
|---|---|---|---|
| EQ | low cut, low g/f/Q, lo-mid g/f/Q, hi-mid g/f/Q, high g/f/Q, high cut, air | Ed's 4-band; Para (Dub, Lo-Fi); Rhythmic (Para without Q); Drum (low, mid, mid f, high); Vocal (Studio, Vocal, Vocal Tuner: low, mid, high, air) | proceed |
| Compressor | threshold, ratio, attack, release, make-up | Ed's (all 5); Drum (attack, make-up, threshold); 2-param (Dub, Studio, Vocal, Vocal Tuner) | proceed |
| Transient | attack, attack length, sustain | Drum | proceed |
| HP/Gate | high-pass frequency, gate threshold | Vocal, Vocal Tuner | proceed |
| Doubler | mix, separation | Dub (2), Studio/Vocal/Vocal Tuner (mix only) | proceed |
| Chorus | rate, depth, mix | Ed's | proceed |
| Wah | pedal | Ed's, Guitar | proceed |
| Overdrive | drive, tone | Ed's, Guitar | proceed |
| Distortion | drive, tone | Lo-Fi (2); Studio (drive only) | proceed |
| Vinyl | drive, frequency, noise, noise tone | Lo-Fi | proceed |
| Degrade | frequency, filter, mix | Lo-Fi | proceed |
| LPF | cutoff, resonance, LFO rate, LFO depth | Lo-Fi (cutoff, reso); Rhythmic (all 4; LFO rate is a division) | proceed (LFO with the division table) |
| Spring | time, mix | Guitar | proceed |
| Dub-Verb | decay, level | Dub | proceed |
| Amb-Verb | decay, level, mix | Dub | proceed |
| Pitch Shift | shift (25 steps), mix | Studio, Vocal | proceed |
| Delay | division, feedback, mix, mode, damping, L/R ratio, resonance, resonance frequency, feedback filter frequency | Mode delay (7 racks: 12 modes); Drum (with Del Freq); Dub (damp, ratio, reso, reso freq) | Drum and Dub proceed once the division table is decoded; Mode delay waits for reference |
| Reverb | length, mix, brightness, mode, density, ER type, ER level, tail/ER, low/high | Mode reverb with brightness (Ed's, Vocal, Vocal Tuner); without (Rhythmic, Studio); Drum (15 rooms) | waits for reference |
| Amp+Cab | drive, bass, treble, modern, cabinet | Ed's, Guitar | waits (12 cabinets) |
| Mod | mode, rate, depth, mix | Guitar (4), Studio (without mix) | waits (3 modes) |
| Slicer | pattern, step length, mix | Rhythmic | waits (20 patterns) |
| Pumper | rate, depth | Rhythmic | waits (pump shapes) |
| Whammy | pedal, range | Guitar | waits for the range table |
| Dual Octaver | high mode, octave 1 level, octave 2 level, mix | Ed's | proceed for high mode 0 (every preset); mode 1 waits |
| Smart Tune | mode, auto source, key, scale root, scale type, speed, tightness, tracking, audio type, reference, stereo | Vocal Tuner | waits (tracking and audio-type steps) and needs owner input on sources |
| Harmonizer | lead and harmony levels, voice EQ (3 bands), two voices x (on, pitch, gender, pan, delay, level), shared mode, auto source, key, scale | Vocal Tuner | as Smart Tune |

"Proceed" kinds still choose their continuous tapers; each such parameter
carries a taper-unverified flag that the editor shows until reference audio
confirms it. Some tapers can be read from the presets (Spring Time values are
exactly `log10` of 2..7, a one-decade log taper); each part lists the ones it
recovered that way. Kinds marked "waits" are built only when #891 produces
their reference audio, or when the owner rules otherwise.

The pen's "Add an effect to a rack" screen (frame `Rv04K`, 26 entries) lists
kinds a player can add to a rack one at a time. Each entry maps to a kind and
a default variant: Four-band EQ to Ed's 4-band, Parametric EQ to Para, Dub
Delay to Dub, Delay to Mode delay, Reverb to Mode reverb with brightness,
Spring Reverb to Spring, and the rest to their only variant. Dub-Verb and
Amb-Verb are not on that screen; adding them to it is a pen write-back for
the owner. The singles library keeps the existing seven built-ins only.

## Architecture

1. **Parameter descriptors, type-keyed and static**, modelled on
   `le_synth_param_info`: `le_fx_param_count(type)` and
   `le_fx_param_info(type, index, out)` return a stable descriptor key, step
   count, unit kind, range and default from the same table the kernel maps
   with. Text is formatted in Dart through the ARB files, so English and
   Spanish both stay localized; tile names follow the pen ("Octave 1 Level",
   "Step length") and note divisions use the pen's spelling ("1/4 dotted").
   A Dart registry loads the descriptors at startup and replaces every
   synchronous reader of `TrackEffectType.params`: `fxParamName`
   (`binding_labels.dart`), `_midiParamDivisions` (`control_midi.dart`),
   `expression_catalogue.dart`, `control_value_resolver.dart`, the mock
   engine, and the unused `effectParamLabel` / `octaverModeLabel` /
   `formatLocalizedPitchShift` in `localized.dart`.
2. **The seven segno VST3 plugins keep a 4-float state, explicitly.** Their
   `getState`/`setState` and the controllers' `setComponentState` size the
   state from `LE_FX_PARAMS` and reject any other size, as do the wrapper
   tests. They switch to a named 4-float constant before any widening, so
   exported Ableton projects still load.
3. **`LE_FX_PARAMS` grows to 32**, landing with the first kind that needs more
   than 4 (EQ), after the #907 / #914 trunk rework. The Harmonizer needs about
   25 with its shared parameters. Memory, stated rather than estimated away:
   parameter atomics grow from about 130 KB to about 1.06 MB across the 129
   owners, the per-buffer snapshot scratch from about 130 KB to about 0.93 MB,
   plus per-edit recipe copies (8 KB per chain) on the heap. The engine
   struct is allocated through #914's fork-shielded path, so this memory is
   locked and never copied on fork. The snapshot copies only each active
   slot's descriptor count, so per-buffer cost does not grow with the width.
4. **Kind state on the heap, fork-shielded, sized per kind.** Every FX buffer,
   new and existing (delay rings, octaver buffers, kind state), is allocated on
   the control thread through the `le_audio_ring_alloc` rule from #804 / #914:
   anonymous mapping, `MADV_DONTFORK`, prefaulted. Each kind owns a state
   pointer per slot sized for that kind only; a slot keeps one block per kind
   it has held, freed only at owner reset or destroy, so a retype never frees
   memory the audio thread may still read. No block is sized for the largest
   kind.
5. **Explicit per-kind behaviour in the vtable.** Each row states whether
   bypass drains (only linear tail-owning kinds) or crossfades, which buffers
   a settled re-enable clears, an `init` run on retype so no kind reads
   another's bytes, and an `update(params, sr)` hook run once per buffer that
   recomputes coefficients only when parameters changed and interpolates them
   per sub-block. Discrete parameters (modes, cabinets, patterns) switch with
   a crossfade.
6. **Cheap publishes.** A recipe slot carries the chain entry's stable
   instance id; a publish resets only slots whose id or type changed, and the
   large clears are spaced with `LE_FX_ENABLE_CLEAR_SPACING`. Parameter-only
   edits use a parameter-only recipe that resets nothing. New types are no
   longer prepared by writing the new type's defaults ahead of the type
   command, so the old kernel never runs on the new kind's parameters.
7. **Tempo for synced kinds.** Synced kinds read the engine tempo (manual,
   tapped, derived or external clock); 120 BPM applies only while the tempo
   source is NONE, and the editor says so inline. A tempo change under a
   running synced delay crossfades from the old tap to the new over 20 ms.
   Delay rings are sized for the longest division at the slowest tempo and
   decoupled from the sample rate; if that exceeds 4 s, the cap is put to the
   owner with the Delay part.
8. **Offline renders match live.** A new perf-log event records the tempo at
   the frame the audio thread applied it (events.log version 13) and
   `perf_render` reads it. Parameter changes are logged at the frame the
   audio thread first applied them. An output-bus recipe logs only each
   slot's described parameters and only those that changed, so a 64-slot
   publish cannot fill the 4096-entry log ring. Render and cache workers set
   flush-to-zero as the audio thread does. Chains holding a free-running
   modulator or noise source (Chorus, Mod, Vinyl, Degrade, Doubler, the dub
   delay's wow) or a bar-locked one (Slicer, Pumper, synced LFO) are not
   wet-cached: their output does not repeat each lap, so a print cannot equal
   live. Noise generators are seeded per owner like the hop phase.
9. **Pitch kinds.** One stereo phase-vocoder hop costs about 315 us on the
   console, all in one block of four. Before any new pitch kind: measure the
   vendored signalsmith-stretch (#1179) against PSOLA for Pitch Shift,
   Whammy and the Harmonizer; split each hop's frame work across the blocks
   of its hop; run one mono analysis and one YIN pass shared by all voices of
   a module; slice YIN (#913) and decimate by two before detection so a low
   voice is still in range at 96 kHz. Chord detection for the Harmonizer runs
   off the audio thread, like the binary's own `ChordDetectorThread`.
10. **Admission control.** The control thread keeps a per-kind worst-block
    cost table (from the console benches) and refuses an edit that would put
    the engine's worst block over budget, with an inline notice like
    `fxRackTooLong`.
11. **Persistence.** From the catalogue part on, a rack entry persists its
    preset id and every source value, so a later part can build what an
    earlier one could not. Racks saved before that part stay as they were (no
    migration). Re-adding a rack gives its entries new identities, so MIDI and
    pedal bindings to the old entries are lost; the notice says so. Readiness
    comes from the entry's type, not its module name.

## Acceptance per part

- Discrete parameters: every step's index and label exact against the
  binary's tables.
- Kernel response, with tolerances stated in the part: EQ magnitude within
  0.1 dB of the design curve; delay time equal to the division within one
  sample at three tempos; dynamics static curve within 0.5 dB and attack and
  release within 10 percent of the design.
- Offline equals live: wet cache, render recipe and stem render, on a
  non-zero lane, within 1e-4 (bit-exact where the kind has no float-order
  difference).
- Console worst block (static aarch64 bench, SCHED_FIFO 70, off the audio
  core): one, four and eight instances of each new kind, plus the full-rig
  scenario (8 playing tracks, 2 monitored inputs, the heaviest buildable
  racks), all under budget. A part that misses its budget does not merge.
- Then the owner's A/B sign-off on named presets, recorded on the part's
  issue; reference null tests where #891 has captured the kind.

## CPU budget (worst block, 96 kHz / 64 frames, 667 us)

Measured on the console with `bench_fx_cpu` (part 1): an 8-track playing rig
with one monitored input and no effects costs 60 us per block at p50 and 73
us at worst. One stereo phase-vocoder octaver adds about 320 us to one block
in four; with part 1, two to four octavers stay at 400 to 430 us worst, and
eight need about 740 us in every block, so eight do not fit whatever the
stagger. The full rig must stay under 533 us (80 percent) in its worst block. Per rack, on
one monitored input, worst-block increments:

| rack | target |
|---|---|
| Drum, Dub, Lo-Fi, Rhythmic | 60 us |
| Ed's, Guitar, Studio, Vocal | 200 us (needs the pitch hop split) |
| Vocal Tuner | 300 us |

## Parts

Each part is its own issue (area:fx) and PR against `claude/segno-integration`.
"After" means merged first; no part stacks on an open PR more than two deep.

| # | part | after | notes |
|---|---|---|---|
| 0 | Phase 0 emulation capture (#891) | none | continuous; feeds the waiting kinds |
| 1 | Octaver hop stagger (#915, replaces PR #917) | none | in progress on `claude/octaver-stagger-915`; a dependency of every pitch part |
| 2 | Descriptors and tiles for the existing seven, Dart registry with ARB keys (en, es), taper-unverified flag, VST3 4-float state pinned | none | pen write-backs: Connected pedal editor, Hidden parameters, Save a preset, Replace a saved preset, Rack options, Track Solo while editing FX |
| 3 | Catalogue: module-table fixes, shared Vocal Tuner parameters, chain order, Master Vol as Rack level, `Rv04K` mapping, preset id persistence, readiness from type | 2 | Dart only |
| 4 | Engine room + EQ: width 32, fork-shielded per-kind state, vtable flags and update hook, instance-id resets, parameter-only recipes, worker FTZ, applied-frame parameter logging | 2, #907, #914 | first engine change |
| 5 | Compressor, Transient, HP/Gate | 4 | |
| 6 | Doubler, Chorus, Wah | 4 | not wet-cached (Doubler, Chorus) |
| 7 | Overdrive, Distortion, Vinyl, Degrade, LPF without LFO | 4 | |
| 8 | Spring, Dub-Verb, Amb-Verb | 4 | Amb-Dub Mix may balance the two Dub reverbs in parallel; decided with reference |
| 9 | Pitch groundwork + Pitch Shift: stretch-vs-PSOLA measurement, hop split, shared mono analysis, #913, admission control | 1, 4 | |
| 10 | Transport context, tempo log event, ring sizing; Drum and Dub delay; LPF synced LFO | 4, division table from #891 | |
| 11 | Dual Octaver (Ed's), mode 0 | 9 | |
| W | Waiting kinds: Mode delay, Reverb (mode and Drum), Amp+Cab, Mod, Slicer and Pumper, Whammy, Dual Octaver mode 1, Smart Tune and Harmonizer | reference audio, 9, 10 | each becomes a part when its reference exists |

Slicer and Pumper gain steps are ramped (the #813 lesson: a gain step is a
click), whatever pattern the reference shows.

Rack completeness is a milestone, not a part: a rack is complete when every
kind it uses has landed. Dub completes first (after parts 5, 6, 8 and 10),
then the racks that only lack the waiting kinds.

## Notices

- CPU or pitch-instance limit: inline refusal at the add, worded like
  `fxRackTooLong`.
- No tempo: inline note on a synced module's tile ("follows 120 BPM until a
  tempo is set").
- Smart Tune or Harmonizer MIDI source lost: the existing MIDI-lost toast.
- A partial or unavailable module: the existing `fxModulePartial` and
  `fxModuleUnavailable` lines, now actually shown.

## Decisions still for the owner

- **Vocal Tuner sources** (before its part): Auto Source offers Input 1-4 or
  MIDI. Which segno inputs and which MIDI source those become.
- **Delay length cap**, if the longest division at 30 BPM exceeds 4 s.
- **Admission control** refusing an edit on CPU grounds (default: refuse
  with an inline notice).

## Risks

- **Phase 0 may not produce audio.** Then the waiting kinds stay not built and
  no rack that uses them completes; that is the owner's ruling, not a slip.
- **Pitch CPU.** Two voices per module and three pitch modules per rack only
  fit with the hop split and shared analysis.
- **VST3 export.** New kinds have no segno VST3 plugin; an Ableton export
  renders them through the existing unrepresented-type fallback.
