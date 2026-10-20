# Looper X factory racks: build plan (#887)

Status: **build plan, direction approved 2026-08-27** (full sound reproduction,
naming deferred). This replaces the unmerged
`docs/plan/2026-08-27-feat-looperx-rack-reproduction-plan.md`, which is kept
on the branch `claude/sheeran-looper-extract-bd5cc9`. That plan was written
against a trunk with 8 chain slots and no catalogue. This one is written
against `claude/segno-integration` at `a37926236` (2026-10-19).

The owner has authorization to reuse the Sheeran Looper X (HG08) factory
content. The factory presets, parameter schemas and enum tables may be
committed; the Looper X executable and libraries may not.

## What the trunk has today

- **64 chain slots** (`LE_FX_MAX`, slice 3f), **4 parameters per slot**
  (`LE_FX_PARAMS`). Chain owners: 64 lanes, 8 track buses, 40 monitored
  sources (32 inputs and 8 instruments), the all-tracks bus and 16 output
  buses.
- **Seven built-in types** (`le_fx_type`: drive, filter, delay, tremolo,
  octaver, echo, reverb) plus hosted plugins (`LE_FX_PLUGIN = 8`). The
  octaver carries a phase vocoder, a PSOLA shifter and a resumable YIN
  detector (`le_yin_*`).
- **The factory catalogue ships** (`packages/fx_catalogue`): all 159 presets,
  the rack artwork and 26 module definitions (power keys, parameter
  prefixes, stomp art). Adding a rack builds one chain entry per module
  (`fxModuleEntry`, `packages/looper_repository/lib/src/models/fx_module_build.dart`).
- **Six modules are mapped** to a built-in (Delay, Reverb, Overdrive,
  Distortion, Low-pass filter, Octaver), all partially: each drops controls
  the built-in has no parameter for. The other twenty become passthrough
  entries that keep their module name.
- **The editor shows raw 0..1 values** (`FxParamControl`,
  `value.toStringAsFixed(2)`) under English labels from a Dart table, with
  "Scale unverified" on every parameter. The accepted design (segno-ui.pen,
  `DS / 06 FX parameter — spec`) gives built-ins the same tile grid as
  plugins and shows each value as one string with its unit.
- **Offline renders** (`perf_render.c`, `engine_cache.c`) run the engine's own
  `fx_apply_chain` on a heap `le_fx_state`. The wet cache renders a loop twice
  and keeps the second pass.

## What the racks need

Nine racks, 26 modules. A module is a pedal inside a rack with its own power
key. The same module appears with different parameter sets in different
racks, for example five EQs:

| EQ in | parameters |
|---|---|
| Ed's | 14: Low Cut, Low, Low Freq, Low Q, Lo Mid, Lo Mid Freq, Lo Mid Q, Hi Mid, Hi Mid Freq, Hi Mid Q, High, High Freq, High Q, High Cut |
| Dub, Lo-Fi (Para EQ) | 5: Low Cut, High Cut, Mid Freq, Mid Gain, Mid Q |
| Rhythmic | 4: Low Cut, High Cut, Mid Freq, Mid Gain |
| Drum | 4: Low, Mid, Mid Freq, High |
| Studio, Vocal, Vocal Tuner | 4: Low, Mid, High, Air |

The binary's own parameter strings show why: one generic DSP module per kind
(the EQ's internal names are `LowCutFreq`, `LowGain`, `LowType`,
`LowMidFreq`, ..., `HighCutType`) with each rack exposing a subset and fixing
the rest. Delay, Reverb and Compressor follow the same pattern.

Per-rack modules (module: exposed parameter count, power key excluded):

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
| Vocal Tuner | HP/Gate 2, Compressor 2, EQ 4, Smart Tune 11, Harmonizer 21, Doubler 1, Delay 4, Reverb 4 |

Every rack also carries `Master Vol`, the rack's output level.

Discrete parameters can be read off the preset values, which sit on a grid of
`1/(n-1)`: Del Time and Slic Patt have 20 steps (Del Time is a note
division, so the delay is tempo-synced), Del Mode and Cab 12, Rev Mode 4,
Drum Rev ER 15.

## What exists, what is missing

| module | engine today | status |
|---|---|---|
| EQ (5 variants) | none | new |
| Compressor (3 variants) | none | new |
| Delay (mode delay, drum delay, dub delay) | `delay` (time, feedback, mix; free time) | new types: synced time, 12 modes, feedback filter, L/R ratio, resonance |
| Reverb (mode reverb, drum reverb) | `reverb` (Freeverb, 3 params) | new types: 4 room modes, brightness, ER/tail, density |
| Spring, Dub-Verb, Amb-Verb | none | new |
| Doubler | none | new |
| HP/Gate | none | new |
| Overdrive, Distortion | `drive` (tanh, no tone) | new types with tone |
| Amp+Cab | none | new (12 cabinets; the image ships no impulse responses, so the cabinets are filters) |
| Chorus, Mod (chorus/phaser/flanger), Wah | none | new |
| LPF (plain, with LFO) | `filter` (SVF, 2 params) | new type with synced LFO |
| Vinyl, Degrade | none | new |
| Pumper, Slicer | none (`tremolo` is free-running) | new, tempo-synced |
| Transient | none | new |
| Pitch Shift, Whammy | octaver kernels | new types on the existing PSOLA / phase vocoder |
| Octaver (Ed's: two octave voices) | `octaver` (one shifted voice) | new type on the existing kernels |
| Harmonizer, Smart Tune | YIN + PSOLA | new |

The existing seven built-ins stay as they are. Changing their parameter
meaning would change the sound of every saved session that uses them; the
rack modules get their own types instead.

## Architecture decisions

These follow from the approved direction and the engineering rules in
`AGENTS.md`. None changes what a user sees outside a factory rack.

1. **One engine type per (module, parameter set).** `LE_FX_EQ_4BAND`,
   `LE_FX_EQ_PARA`, `LE_FX_EQ_CUT`, `LE_FX_EQ_DRUM`, `LE_FX_EQ_VOCAL` share one
   EQ kernel and differ in which parameters they expose and which they fix.
   A preset imports by copying its normalized values in the type's parameter
   order. Each type's parameter table is the one place its names, steps,
   tapers and fixed values live. New codes start at 9 (8 is the persisted
   plugin code).
2. **`LE_FX_PARAMS` grows from 4 to 24.** The largest module is the
   Harmonizer at 21. The per-buffer snapshot copies only active slots, so the
   cost is in memory (a chain owner's parameter atomics grow from 1 KB to
   6 KB). Saved chains already pad short parameter lists with the type's
   defaults on decode. The segno VST3 plugins keep their own four-float state
   format, so saved plugin state still loads.
3. **Per-slot module state lives on the heap.** `le_fx_state` inlines every
   type's state at `[LE_FX_MAX]`; adding twenty types that way multiplies it
   for every owner. New types instead get one per-slot block of a fixed size
   (the largest new module state), allocated on the control thread by
   `le_fx_prepare` on first use and kept across retypes, exactly like the
   delay rings today. Because every new type uses the same block size, a
   retype never has to free a block the audio thread may still read. Long
   delay lines use the existing per-slot rings.
4. **Built-in parameter descriptors in C, shown through the plugin path.**
   `le_fx_param_count`, `le_fx_param_info` and `le_fx_param_value_text` return
   the same `le_plugin_param_info` and value string a hosted plugin returns,
   from the table the kernel itself uses to map normalized values. The editor
   then draws built-ins with the accepted tile grid (switch, named steps,
   continuous) and one value string per tile ("-6.0 dB", "1/8 D", "BOX"),
   and "Scale unverified" goes away. The Dart per-type label table goes away
   with it.
5. **A transport context for tempo-synced modules.** Del Time, LPF LFO Rate,
   Pumper Rate, Slicer step and the Harmonizer voice delay are note
   divisions. `fx_apply_chain` gets the engine tempo and the bar phase once
   per buffer; offline renders get the same values from the performance log
   (stems) and from the render key (wet cache). A chain holding a
   bar-locked module (Slicer, Pumper, synced LFO) is not wet-cached and plays
   live: the cache can only be exact for state that is a function of tempo,
   not of the bar position.
6. **Offline renders match live for every new type.** Each part adds the
   type to the wet-cache parity sweep over every built-in and to a perf_render
   stem parity test, on a non-zero lane, with state seeded the way the live
   lane seeds it.
7. **No audio-thread allocation, locking or forking.** Coefficients are
   recomputed only when a parameter changes, and smoothed. Each part reports
   CPU per module from a native benchmark and, for the heavy modules, from a
   static aarch64 build run on the console under the agreed rules.
8. **Rack chain order.** The presets store keys alphabetically and the editor
   lists modules from the binary's own table, so the processing order is not
   in the data files. The order in which each rack's power-key strings first
   appear in `.rodata` is used, since it follows the rack definitions in the
   source (Ed's: Octaver, Wah, Compressor, Overdrive, Amp, Chorus, EQ, Delay,
   Reverb). It is marked as inferred, and Phase 0 replaces it with the real
   order if the UI ever renders.

## Fidelity

Without reference audio (Phase 0, #891), each module is built from its
recovered parameter set, the enum labels and units in the binary, the
internal parameter names of the generic modules, and the standard designs
those names describe (RBJ biquads, feed-forward RMS compressor, multi-mode
delay with filtered feedback, FDN reverb, spring allpass chain, TPT filters,
PSOLA pitch). Discrete parameters (modes, divisions, cabinets, patterns,
scales) are exact. Continuous tapers are chosen from the unit formats and
the preset values, and each part records its tapers in its table so a later
measurement replaces numbers, not code. If Phase 0 produces reference audio,
a fidelity pass per module follows; it is not a blocker for any part.

## Parts

Each part is its own issue (area:fx, stage, autonomy) and PR against
`claude/segno-integration`, with native tests, render-parity tests, CPU
numbers and the catalogue mapping. Racks become fully mapped as their modules
land; the readiness label on each module stays truthful in between.

| # | part | unblocks | depends on |
|---|---|---|---|
| 0 | Phase 0 emulation capture (#891), time-boxed, in parallel | fidelity pass | none |
| 1 | Port octaver hop stagger (#915, replaces PR #917): seeds for 64 slots and 144 owners, stagger survives a recipe publish, offline renders copy the lane seed | every pitch module | none |
| 2 | Engine room: `LE_FX_PARAMS` 24, per-slot module block, built-in parameter descriptors and value text over FFI, editor tiles read them | every module | none |
| 3 | EQ, five variants | EQ in 8 racks | 2 |
| 4 | Compressor, three variants | 7 racks | 2 |
| 5 | Transport context + Delay (mode, drum, dub) | all 9 racks | 2 |
| 6 | Reverbs: mode reverb, drum reverb, Spring, Dub-Verb, Amb-Verb | 7 racks | 2 |
| 7 | Doubler, HP/Gate | Dub, Studio, Vocal, Vocal Tuner | 2 |
| 8 | Overdrive, Distortion, Amp+Cab | Ed's, Guitar, Lo-Fi, Studio | 2 |
| 9 | Chorus, Mod, Wah | Ed's, Guitar, Studio | 2 |
| 10 | LPF (with synced LFO), Vinyl, Degrade | Lo-Fi, Rhythmic | 5 |
| 11 | Pumper, Slicer, Transient | Rhythmic, Drum | 5 |
| 12 | Pitch Shift, Whammy, Ed's Octaver (+ #913 YIN slicing if the count needs it) | Studio, Vocal, Guitar, Ed's | 1, 2 |
| 13 | Smart Tune, Harmonizer | Vocal Tuner | 12 |
| 14 | Rack completion: chain order, Master Vol, every module full, per-rack CPU on the console, pen write-backs | all racks | 3-13 |

Stacks stay at most two deep: parts 3, 4, 6-9 each sit directly on part 2,
and 10-11 on part 5.

## CPU budget

The console runs one SCHED_FIFO audio thread at 96 kHz / 64 frames: 667 us
per block. Measured on the console for #915: the engine with no effects takes
about 36 us per block, and one stereo phase-vocoder octaver about 315 us per
hop (79 us per block averaged, all of it in one block of four until #915 is
ported). Per-sample filters, dynamics and delays should cost a few
microseconds per block each; reverbs and pitch modules dominate. Targets, to
be replaced by measurements as parts land:

| rack | heaviest modules | target per block |
|---|---|---|
| Drum, Dub, Lo-Fi, Rhythmic | reverbs, delays | < 60 us |
| Ed's, Guitar | amp, reverb, octaver or whammy | < 150 us |
| Studio, Vocal | pitch shift, reverb | < 150 us |
| Vocal Tuner | smart tune + two harmonizer voices | < 300 us |

## Decisions for the owner (defaults used until answered)

- **Tempo when none is set.** Synced modules need a tempo before a loop
  defines one. Default: 120 BPM, the usual Looper X starting tempo.
- **Rack module types in the singles library.** The library lists every
  built-in as a single effect. Listing about forty rack-variant types there
  would flood it. Default: the new types appear only inside factory racks;
  the singles list keeps the existing seven.

## Risks

- **Voicing without reference.** Continuous tapers and fixed values are
  chosen, not measured, until Phase 0 lands. Each choice is in one table.
- **Pitch CPU.** Vocal Tuner runs up to three pitch instances in one rack.
  Part 12 measures and pulls in #913 (sliced YIN) if four or more instances
  are needed at once.
- **VST3 export.** The new types have no segno VST3 plugin, so an Ableton
  export renders them through the existing unrepresented-type fallback.
  Plugins for them are out of scope here.
