---
title: "Control the interface's input settings from the console"
type: feat
date: 2026-11-04
issue: 1646
---

# Control the interface's input settings from the console

<!-- cspell:words scarlett2 Clarett Vocaster amixer Autogain libasound dlopen Penpot MSD dBFS ctl uid ioctls syms pthread cget -->

Tracking: [#1646](https://github.com/tomassasovsky/segno/issues/1646),
`stage:plan`, `autonomy:plan-gate`. Brainstorm:
[`docs/brainstorm/2026-11-04-interface-input-controls.md`](../brainstorm/2026-11-04-interface-input-controls.md).
Builds on #1046 / PR #1601. Every `file:line` is on
`claude/segno-integration` at `2c1c561dc`.

This is a plan. Merging it approves the direction; the build follows under
#1646 once the owner has answered the questions in section 7. Each question
has a recommendation, which the build takes if the plan merges unanswered.

## 1. Goal

A player at the console can see and change, for each input of the
interface, what the interface's own switches set: Inst or Line, Pad, Air and
48 V phantom power. The page shows what the hardware holds, including changes
made with the interface's front-panel buttons. An interface without these
controls says to use its own switches. The input meter shows where the
loudest playing should peak, so the player can set the hardware gain knob.

Not in scope: direct monitoring (#1046 keeps it off), startup settings
(phantom power persistence, Standalone), software gain on Gen 4 units, other
kernel drivers than `scarlett2`, a stage-screen 48 V indicator.

## 2. Decisions this plan takes

From the brainstorm, each subject to section 7:

1. **Reflect the hardware.** Segno stores nothing. It reads the interface's
   controls and writes the player's change straight to them; the unit saves
   its own configuration (`mixer_scarlett2.c:2985`). Nothing is applied at
   device open.
2. **Controls:** `Line In N Level Capture Enum`, `Line In N Pad Capture
   Switch`, `Line In N Air Capture Switch` or `Line In N Air Capture Enum`
   (Off / Presence / Presence + Drive), and `Line In N Phantom Power Capture
   Switch` or `Line In a-b Phantom Power Capture Switch`. `Line In N` is
   Segno input `N` (true under #1046's pass-through capture routing).
3. **Where:** the Input setup tab (`lib/looper/view/audio_routing/input_setup_tab.dart`),
   a row for the selected input, plus a tag on each input card.
4. **Phantom power:** asks before turning on, naming every input the switch
   powers; turns off without asking; never set by Segno on its own and not in
   the action catalogue.
5. **Lock:** the row is read-only while a track fed by the input (or by any
   input of its 48 V group) is armed or recording, the same rule as the
   stereo format lock (`input_setup_tab.dart:40-52`).
6. **No controls:** a one-line note. A unit in MSD mode gets its own note.
7. **Engine seam:** the `le_mixer` abstraction in `engine_devices.c`; Dart
   calls it off the UI isolate.
8. **Front-panel changes:** the page re-reads while it is open.

## 3. Engine API (sketch; the build settles the exact shape)

In `packages/segno_engine/src/core/segno_engine_api.h`:

```c
/* One input's interface switches; -1 where the interface has none. */
typedef struct le_interface_input {
  int32_t level;          /* 0 Line, 1 Inst */
  int32_t pad;            /* 0 off, 1 on */
  int32_t air;            /* 0 off, 1 on or Presence, 2 Presence + Drive */
  int32_t air_choices;    /* 0 none, 2 switch, 3 Off/Presence/Presence + Drive */
  int32_t phantom_group;  /* index into phantom[], or -1 */
} le_interface_input;

typedef struct le_interface_inputs {
  int32_t state;          /* LE_INTERFACE_NO_CONTROLS, _CONTROLS, _SETUP_MODE */
  int32_t input_count;    /* hardware inputs described below */
  le_interface_input inputs[LE_INTERFACE_MAX_INPUTS];
  int32_t phantom_count;
  struct { int32_t first, last, on; } phantom[LE_INTERFACE_MAX_PHANTOM];
} le_interface_inputs;

/* Reads the switches of the card behind capture id `uid`. */
LE_EXPORT int32_t le_interface_inputs_read(const char* uid,
                                           le_interface_inputs* out);
/* Sets one switch (LE_INTERFACE_LEVEL, _PAD, _AIR, _PHANTOM) of input or
 * phantom group `index`, then reads it back. LE_OK, or an error when the
 * card refuses or the value does not stick. */
LE_EXPORT int32_t le_interface_input_set(const char* uid, int32_t control,
                                         int32_t index, int32_t value);
```

The rules (`le_scarlett2_inputs_read`, `le_scarlett2_input_set`) live in
`engine_devices.c` next to `le_own_scarlett2_routing` and take an
`le_mixer`. They find controls by the driver's names, so a model's counts come
from the card, not from a model table. `engine_linux.c` opens the card with
`le_alsa_mixer_open` (`engine_linux.c:1287-1309`); `le_alsa_ctl_syms_get`
(`:1164-1168`) resolves through `pthread_once`, since these calls arrive from
a Dart worker isolate while device open runs on another thread. macOS returns
`LE_INTERFACE_NO_CONTROLS`.

The Dart side passes the capture id it opened the device with
(`AudioConfig.captureDeviceId`, `packages/looper_repository/lib/src/models/audio_config.dart:125`).

## 4. Parts

Each part is one PR on its own branch (`claude/interface-inputs-1646-p<K>`),
stacked on the previous one. Parts 1 and 3 can run in parallel.

### Part 1: engine rules, FFI and tests

- `le_scarlett2_inputs_read` / `le_scarlett2_input_set` in
  `engine_devices.c`; the Linux seam; the FFI functions and structs; the
  ffigen regeneration (then `dart format` on the bindings, per
  `ffigen.yaml`).
- MSD detection: a card with `MSD Mode Switch` on and no `Line In` controls
  reports `LE_INTERFACE_SETUP_MODE`. If question 7 is answered "button", a
  `LE_INTERFACE_SETUP_MODE_OFF` write sets `MSD Mode Switch` off.
- Native tests in a new `test_engine_interface_inputs.h`, run from
  `test_engine_core.c`, against the 4i4 fixture and built cards.

Acceptance:

- On the 4i4 fixture: inputs 1-2 report level, pad, air (switch) and
  phantom group 0 (`first` 1, `last` 2, on); inputs 3-4 report -1 for every
  switch.
- Built cards: a Gen 3 Solo (`Line In 2 Level`, `Line In 1 Air`,
  `Line In 1 Phantom Power`), a Gen 3 18i20 (two phantom groups of four, pad
  and air on 1-8), a Gen 4 4i4 (three-way Air, one phantom switch per input)
  each report the right input for every control.
- A write changes only the named control, is read back, and a refused write
  or one that does not stick returns an error and leaves the others alone.
- A card with no `Line In` controls reports `NO_CONTROLS`; an MSD card
  reports `SETUP_MODE`.
- The routing tests from #1601 still pass; `run_native_tests.sh` passes,
  including the ASan configuration.

### Part 2: repository and cubit

- `AudioEngine` gains `readInterfaceInputs(captureId)` and
  `setInterfaceInput(...)`; `NativeAudioEngine` runs them through its
  `offIsolate` runner (`native_audio_engine.dart:2765-2768`).
  `MockAudioEngine` (`packages/segno_engine/lib/src/mock_audio_engine.dart:33`)
  simulates a 4i4 Gen 3, so the mock app and the screenshots have the row.
- `LooperRepository` exposes them for the open capture device as an
  `InterfaceInputs` model (immutable, `Equatable`).
- `InterfaceInputsCubit` in `lib/audio_setup/cubit/`, following the open
  device as `InputsCubit` does (`lib/audio_setup/cubit/inputs_cubit.dart`):
  reads at each device open, after each write, and on a timer (2 Hz) only
  while the Input setup tab is showing. A refused write emits a failure the
  view shows as a toast (the popup-severity rule: low stakes, transient).
  Methods return `void` (`bloc lint`).

Acceptance:

- `bloc_test`: device open reads; a write updates state from the read-back;
  a refused write keeps the old value and reports the failure; the timer runs
  only between `start` and `stop`; a device change drops the old state.
- `dart analyze` and `bloc lint lib test packages` are clean.

### Part 3: design

- Penpot frames on the Audio routing page: the Input setup tab with the
  interface row for a 4i4 input 1, the 48 V confirmation dialog, the card
  tags, the locked row, the no-controls note, the MSD note, and the meter's
  target band and gain note (section 5). Each with a `c/` note.
- A segno-design PR with the refreshed snapshot, linked to the part 4 PR.

Acceptance: the owner approves the frames (this part is the UI's taste
gate).

### Part 4: the Input setup row

- An "Interface" row for the selected input, built from what the cubit
  reports: Inst/Line as a two-way choice (`LoopChoiceRow`,
  `lib/looper/view/loop_settings/loop_settings_widgets.dart:317`), Pad and a
  two-way Air as switches (`LoopSwitch`, `:209`), a three-way Air as a choice,
  48 V as a switch labelled with its group ("48 V, inputs 1-2").
- Turning 48 V on opens a confirmation dialog in the style of "Apply audio
  settings?" (`lib/audio_setup/view/device_page.dart:115-130`), focus on the
  dismissive answer, text naming the inputs and the warning (condenser
  microphones only; plug and unplug with it off). Off needs no dialog.
- Input cards carry tags for Inst and 48 V when set.
- The lock (section 2, decision 5), with the existing lock note's pattern.
- No controls: one note in the row's place. MSD: its note (and the button,
  if question 7 says so).
- l10n strings in `lib/l10n/arb/app_en.arb` and the other ARB files.
- The 48 V control is not added to the action catalogue.

Acceptance:

- Widget tests: the row shows exactly the controls the state has for the
  selected input; a shared 48 V switch shows on both inputs and names both;
  confirming the dialog writes once, cancelling writes nothing; turning off
  writes without a dialog; the row is disabled while the input's track is
  armed; the no-controls and MSD notes show for those states.
- Screenshot suites rendered and compared against the Penpot frames.
- `flutter test`, `dart analyze`, `bloc lint` clean.

### Part 5: the gain-knob meter

- A target band on `RoutingInputMeter`
  (`lib/looper/view/audio_routing/audio_routing_widgets.dart:247`) at the
  range question 9 settles, and a note under it when the interface's gain is a
  hardware knob (every `scarlett2` model without `Line In N Gain Capture
  Volume`, and every interface without controls): turn the gain knob on the
  interface until the loudest playing reaches the band.
- The meter already reads the raw input before trim
  (`engine_process.c:8193-8194`); no engine change.

Acceptance: widget tests for the band's position at the chosen dBFS values
and for the note's presence; screenshots compared against Penpot.

### Closing the issue

The last part's PR says `Closes #1646`; the others say `Refs #1646`. The
**Active threads** row in `docs/PROGRESS.md` is added with part 1 and removed
in the closing PR, which also adds a PROGRESS section and updates
`docs/RUNNING_ON_RPI.md` where it describes the interface.

## 5. Device checks (the console's 4i4; owed after the build)

Run with the owner's go-ahead, since the console is in use:

1. Input 1 on Line: the row shows Line; choosing Inst changes the hardware
   (`amixer -c 2 cget name='Line In 1 Level Capture Enum'` reads `Inst`) and
   the guitar's level rises on the meter.
2. Press the unit's front-panel INST button: the page shows the change
   within a second.
3. 48 V: the dialog names inputs 1 and 2; confirming turns the unit's 48V
   light on; turning it off needs no dialog.
4. Unplug and replug the 4i4: the page shows what the unit kept.
5. Arm a track on input 1: the row locks.

## 6. Risks

- **Writes while the device opens.** Device open writes routing on the
  control thread while a page read may arrive from a worker isolate. The
  kernel serializes control access; the shared user-space state is the symbol
  table, resolved once under `pthread_once`.
- **A switch clicks into a running monitor.** Inst, Pad and 48 V change the
  level by 10 dB or more. The lock covers recording; a monitored input still
  jumps, as it does with the front-panel button.
- **The `Line In N` to Segno input mapping** depends on #1046's capture
  routing. If that routing fails on a card (logged by #1046), the row may
  describe a different jack than the card shows. The build reports
  `NO_CONTROLS` when the capture routing is not pass-through, rather than
  guess.
- **Only the 4i4 Gen 3 can be verified.** Other models are covered by built
  cards from the kernel's control names.

## 7. Questions for the owner

The build takes the recommendation if this plan merges unanswered.

1. **Reflect the hardware, or store and re-apply per interface at every
   open?** Recommended: reflect. The unit saves its own settings and its
   front-panel buttons change the same values; re-applying would fight them
   and would re-enable 48 V without the player.
2. **Which controls first?** Recommended: Inst/Line, Pad, Air (switch, or
   three-way on Gen 4) and 48 V. Not direct monitor (#1046 keeps it off), not
   Standalone, not phantom power persistence.
3. **Where?** Recommended: the Input setup tab, a row for the selected input
   next to its name and meter, plus Inst and 48 V tags on the input cards.
   Not the Device page, whose settings are drafted and applied together.
4. **Phantom power safety?** Recommended: confirm before on, naming every
   input the switch powers; off without asking; never turned on by Segno
   itself, never from a pedal or MIDI action; no stage-screen indicator in
   the first version (the interface's own 48V light shows it).
5. **Phantom power persistence?** Recommended: leave it as the unit has it
   (on, on the console) and do not show it. It decides what the unit does at
   power-on, which is not an input setting.
6. **Lock while recording?** Recommended: yes, the row is read-only while a
   track fed by the input, or by any input sharing its 48 V switch, is armed
   or recording.
7. **A unit in MSD (setup) mode?** Recommended: a note plus a "Turn off setup
   mode" button, with the instruction to power-cycle the interface. A new
   Scarlett ships in this mode and then gets neither these controls nor
   #1046's routing, and the appliance has no other software to turn it off.
8. **Gen 4 software gain, Autogain and Safe?** Recommended: a follow-up
   issue, built when a Gen 4 2i2 or 4i4 is on a bench.
9. **The meter's target band?** Recommended: peaks between -18 and -6 dBFS,
   drawn on the existing meter, with the gain-knob note. This leaves headroom
   for the loudest playing at 32-bit capture.

## 8. Sources

See the brainstorm's Sources section.
