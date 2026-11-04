---
title: "Control the interface's input settings from the console"
type: feat
date: 2026-11-04
issue: 1646
---

# Control the interface's input settings from the console

<!-- cspell:words scarlett2 Clarett Vocaster amixer Autogain libasound dlopen Penpot MSD dBFS ctl uid ioctls syms pthread cget alsactl Behringer Audient PreSonus vvvv pppp Hi-Z hiz ALC1220 SPDIF -->

Tracking: [#1646](https://github.com/tomassasovsky/segno/issues/1646),
`stage:plan`, `autonomy:plan-gate`. Brainstorm:
[`docs/brainstorm/2026-11-04-interface-input-controls.md`](../brainstorm/2026-11-04-interface-input-controls.md).
Builds on #1046 / PR #1601. Every `file:line` is on
`claude/segno-integration` at `2c1c561dc`.

This is a plan. Merging it approves the direction; the build follows under
#1646 once the owner has answered the questions in section 7. Each question
has a recommendation, which the build takes if the plan merges unanswered.

**Owner decisions, 2026-11-04.** All nine questions in section 7 are answered
as recommended, and #1646 is `autonomy:auto`. The owner then added a
requirement: players use many brands and models, so the engine reports a
capability model per input and `scarlett2` is the first adapter, not the
design. Section 2a describes it and replaces the `scarlett2`-only parts of
sections 1, 3 and 4.

## 1. Goal

A player at the console can see and change, for each input of the
interface, what the interface's own switches set: Inst or Line, Pad, Air and
48 V phantom power. The page shows what the hardware holds, including changes
made with the interface's front-panel buttons. An interface without these
controls says to use its own switches. The input meter shows where the
loudest playing should peak, so the player can set the hardware gain knob.

The page works on every interface: one that exposes no switches (most
class-compliant units: Behringer UMC, MOTU M2/M4, Audient iD) says so
plainly, and still shows the input meter and the gain-band guidance.

Not in scope: direct monitoring (#1046 keeps it off), startup settings
(phantom power persistence, Standalone), software gain on Gen 4 units, a
stage-screen 48 V indicator, and moving #1046's routing rules into the
adapters (#1648).

## 2. Decisions this plan takes

From the brainstorm, each subject to section 7:

1. **Reflect the hardware.** Segno stores nothing. It reads the interface's
   controls and writes the player's change straight to them; the unit saves
   its own configuration (`mixer_scarlett2.c:2985`). Nothing is applied at
   device open.
2. **Controls:** per input, the level (Line or Inst, which some drivers call
   Hi-Z), Pad, Air (a switch, or Off / Presence / Presence + Drive) and 48 V
   phantom power with the inputs each switch powers. Which of these an input
   has comes from the interface's adapter (section 2a). On a `scarlett2`
   unit they are `Line In N Level Capture Enum`, `Line In N Pad Capture
   Switch`, `Line In N Air Capture Switch` or `Line In N Air Capture Enum`,
   and `Line In N Phantom Power Capture Switch` or `Line In a-b Phantom Power
   Capture Switch`; `Line In N` is Segno input `N` (true under #1046's
   pass-through capture routing).
3. **Where:** the Input setup tab (`lib/looper/view/audio_routing/input_setup_tab.dart`),
   a row for the selected input, plus a tag on each input card.
4. **Phantom power:** asks before turning on, naming every input the switch
   powers; turns off without asking; never set by Segno on its own and not in
   the action catalogue.
5. **Lock:** the row is read-only while a track fed by the input (or by any
   input of its 48 V group) is armed or recording, the same rule as the
   stereo format lock (`input_setup_tab.dart:40-52`).
6. **No controls:** a one-line note. A unit in MSD mode gets its own note.
7. **Engine seam:** the `le_mixer` abstraction #1046 added, with the
   adapters of section 2a on top; Dart calls it off the UI isolate.
8. **Front-panel changes:** the page re-reads while it is open.

## 2a. Many interfaces: capabilities and adapters

Owner requirement, 2026-11-04: players use many brands and models, not only
Focusrite, so the design starts from that.

**A capability model.** The engine reports, per input, which of the four
kinds (level, pad, air, phantom power) the connected interface exposes, the
current value of each, and for phantom power the inputs each switch covers.
The UI draws only what is reported. A new kind (a high-pass filter, say) is
one more enumerator and the rules that find it.

**Adapters, chosen by what the device is.** An adapter is a small table of
control-name patterns, each naming a kind and, for an enumerated control, the
item names in value order. The engine picks the first adapter that claims the
card, from:

- the card's USB vendor and product (`snd_ctl_card_info` components, which
  `snd-usb-audio` sets to `USBvvvv:pppp`), and its driver and long name;
- the control names the card has (`snd_ctl_elem_list`).

The adapters in the first version:

| Adapter | Claims | Table |
|---|---|---|
| `scarlett2` | Focusrite (`USB1235`) with `Line In N ...` controls: Scarlett Gen 2, 3 and 4 (Solo, 2i2, 4i4), Clarett USB and +, Vocaster One and Two | `Line In # Level Capture Enum` (Line, Inst), `Line In # Pad Capture Switch`, `Line In # Air Capture Switch`, `Line In # Air Capture Enum` (Off, Presence, Presence + Drive), `Line In # Phantom Power Capture Switch`, `Line In #-# Phantom Power Capture Switch` |
| `scarlett` (Gen 1) | Focusrite with `Input N ...` controls (`mixer_scarlett.c`) | `Input # Impedance Switch` (Line, Hi-Z), `Input # Pad Switch` (0dB, -10dB) |
| `generic` | any other card | the keyword rules below |

Vocaster uses the `scarlett2` table: the same kernel driver names its
controls the same way, so a separate table would repeat it entry for entry.
`scarlett2` also carries the two checks that belong to its driver: a unit in
MSD (setup) mode, and a capture routing that is not pass-through (then the
card reports no controls rather than describe the wrong jack).

**The generic fallback** reads every mixer control's name, case-insensitively:
`phantom` or `48v` is phantom power, `pad` is a pad, `hi-z`, `hiz`, `inst` or
`impedance` is the level, `air` is air. It keeps a control only when the
mapping is unambiguous: a switch, or a two-item enumeration whose items read
as off and on (`Off`/`On`, `Line`/`Inst` or `Hi-Z`, `0dB`/`-10dB`); exactly
one kind keyword; exactly one input number in the name once `48V` is removed
(or a range `a-b`, for phantom power); and no second control of the same kind
for that input. `48V Phantom Power On Mic Inputs Switch` (PreSonus 1810c)
names no input, so it is not used.

**Interfaces that expose nothing.** Most class-compliant interfaces (Behringer
UMC, MOTU M2/M4, Audient iD and EVO) have hardware-only switches. Their cards
report no controls; the page says to use the interface's own switches, and
still shows the input meter and the gain band (part 5), so it is useful on
every interface.

**Fixtures.** Real dumps from public sources, each cited in a comment in the
fixture, beside the console's 4i4:

| Fixture | Source | Expected |
|---|---|---|
| Scarlett 2i2 Gen 3, Solo Gen 3, 18i20 Gen 3, Solo Gen 4, 2i2 Gen 4, 4i4 Gen 4, Vocaster Two, 6i6 Gen 1 | `alsactl` state files in alsa-scarlett-gui's `demo/` (GPL-3.0-or-later) | each model's controls on the right inputs |
| Behringer UMC204HD | `amixer controls` and `amixer contents` (strace) in alsa-ucm-conf issue #177 | none |
| MOTU M2, MOTU M4 | `alsa-info.sh` uploads in alsa-ucm-conf issues #190 and #212 | none |
| Audient iD4 | `alsactl` state in alsa-ucm-conf issue #170 | none |
| HD-Audio Generic (ALC1220, a desktop codec) | the same #190 upload | none: its `SPDIF Phantom Jack` is a jack sense control, not phantom power |

**Routing later.** #1046's routing rules (`le_own_scarlett2_routing`) should
move into the same adapter structure; that is #1648, not this issue.

### Adding an interface

1. Get the card's controls: `alsactl -f - store <card>` (or `alsa-info.sh
   --no-upload`) on a machine with the interface, or a public dump.
2. Add it as a fixture under `packages/segno_engine/src/test/fixtures/alsa/`,
   with a comment line naming the model and the source.
3. If the generic rules already describe it correctly, add a test that says
   so. If its driver names its controls in a family pattern, add the
   patterns to that family's table, or a new table with the vendor (and the
   product, when a vendor's models differ) that claims it.
4. Add a native test asserting the capabilities the fixture yields, including
   "none".

## 3. Engine API (sketch; the build settles the exact shape)

In `packages/segno_engine/src/core/segno_engine_api.h`:

```c
/* One input's interface switches; -1 where the interface has none. */
typedef struct le_interface_input {
  int32_t level;          /* 0 Line, 1 Inst (or Hi-Z) */
  int32_t pad;            /* 0 off, 1 on */
  int32_t air;            /* 0 off, 1 on or Presence, 2 Presence + Drive */
  int32_t air_choices;    /* 0 none, 2 switch, 3 Off/Presence/Presence + Drive */
  int32_t phantom_group;  /* index into phantom[], or -1 */
} le_interface_input;

typedef struct le_interface_phantom {
  int32_t first, last;    /* the 1-based inputs the switch powers */
  int32_t on;
} le_interface_phantom;

typedef struct le_interface_inputs {
  int32_t state;          /* LE_INTERFACE_NO_CONTROLS, _CONTROLS, _SETUP_MODE,
                           * _SETUP_MODE_RESTART */
  int32_t input_count;    /* inputs described below */
  le_interface_input inputs[LE_INTERFACE_MAX_INPUTS];
  int32_t phantom_count;
  le_interface_phantom phantom[LE_INTERFACE_MAX_PHANTOM];
  char adapter[16];       /* "scarlett2", "scarlett", "generic", or "" */
} le_interface_inputs;

/* Reads the switches of the card behind capture id `uid`. */
LE_EXPORT int32_t le_interface_inputs_read(const char* uid,
                                           le_interface_inputs* out);
/* Sets one switch (LE_INTERFACE_LEVEL, _PAD, _AIR, _PHANTOM) of input or
 * phantom group `index`, or turns setup mode off (_SETUP_MODE_OFF), then
 * reads it back. LE_OK, or an error when the card refuses or the value does
 * not stick. */
LE_EXPORT int32_t le_interface_input_set(const char* uid, int32_t control,
                                         int32_t index, int32_t value);
```

`_SETUP_MODE_RESTART` is a unit whose setup mode was turned off and that has
not been power-cycled since: `MSD Mode Switch` is off and the driver has not
created the other controls yet.

The adapters and their tables live in a new `engine_interface_inputs.c` and
take an `le_mixer`, which gains the card's identity and a way to list its
control names. `engine_linux.c` opens the card with `le_alsa_mixer_open`
(`engine_linux.c:1287-1309`); `le_alsa_ctl_syms_get` (`:1164-1168`) resolves
through `pthread_once`, since these calls arrive from a Dart worker isolate
while device open runs on another thread. macOS returns
`LE_INTERFACE_NO_CONTROLS`.

The Dart side passes the capture id it opened the device with
(`AudioConfig.captureDeviceId`, `packages/looper_repository/lib/src/models/audio_config.dart:125`).

## 4. Parts

Each part is one PR on its own branch (`claude/input-controls-1646-p<K>`),
stacked on the previous one. Parts 1 and 3 can run in parallel.

### Part 1: engine adapters, FFI and tests

- The capability model, the adapter tables and the generic rules of section
  2a in `engine_interface_inputs.c`; the `le_mixer` additions (card
  identity, control list) and the Linux seam; the FFI functions and structs;
  the ffigen regeneration (then `dart format` on the bindings, per
  `ffigen.yaml`).
- MSD detection in the `scarlett2` adapter: `MSD Mode Switch` on and no
  routing controls reports `LE_INTERFACE_SETUP_MODE`; off and no routing
  controls reports `LE_INTERFACE_SETUP_MODE_RESTART`. A
  `LE_INTERFACE_SETUP_MODE_OFF` write sets `MSD Mode Switch` off (question 7).
- The fixtures of section 2a, and native tests in a new
  `test_engine_interface_inputs.h`, run from `test_engine_core.c`. The test
  card reads both `amixer contents` and `alsactl` state dumps.

Acceptance:

- On the 4i4 fixture: inputs 1-2 report level, pad, air (switch) and
  phantom group 0 (`first` 1, `last` 2, on); inputs 3-4 report -1 for every
  switch.
- Each scarlett2 fixture reports its model's controls on the right inputs:
  Solo Gen 3 (level on 2, air and phantom on 1), 18i20 Gen 3 (two phantom
  groups of four, pad and air on 1-8), Solo Gen 4 (level on 1, three-way air
  and phantom on 2), 2i2 Gen 4 (three-way air, one shared phantom switch),
  4i4 Gen 4 (one phantom switch per input), Vocaster Two (phantom on 1 and
  2, nothing else). The 6i6 Gen 1 reports level and pad on 1-2 through the
  `scarlett` table, and the same through the generic rules.
- The UMC204HD, MOTU M2 and M4, Audient iD4 and HD-Audio fixtures report
  `NO_CONTROLS`.
- Generic rules on built cards: a `Mic 1 48V Switch` is phantom power on
  input 1; a name with no input number, or two numbers, or two controls of
  one kind for one input, is not used; an enumeration whose items do not
  read as off and on is not used.
- A write changes only the named control, is read back, and a refused write
  or one that does not stick returns an error and leaves the others alone.
- A card whose capture routing is not pass-through reports `NO_CONTROLS`; an
  MSD card reports `SETUP_MODE`, and after the setup-mode-off write,
  `SETUP_MODE_RESTART`.
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
- No controls: one note in the row's place, saying to use the interface's
  own switches; the meter and the gain band stay. MSD: its note and the
  "Turn off setup mode" button; after it, a note to power-cycle the
  interface (`SETUP_MODE_RESTART`).
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
- **Only the 4i4 Gen 3 can be verified.** Other models are covered by real
  dumps from public sources (section 2a) and by built cards.
- **The generic rules guess the input from the control's name.** A driver
  whose input numbers do not follow the capture channels would show a switch
  on the wrong input. The rules use only names that map to one input, and a
  family whose names mislead gets its own table.

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
