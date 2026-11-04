---
date: 2026-11-04
topic: interface-input-controls
---

<!-- cspell:words scarlett2 Clarett Vocaster alsamixer amixer Autogain autogain hwdep ioctl ioctls libasound dlopen dlopen'd Helix Sheeran Babyface PreSonus Tascam MOTU Audient UMC s1810c bbfpro quirks Forte Hi-Z MSD dBu dBFS kΩ RC-600 ctl uid FCP fcp ctls EPERM Behringer syms pthread -->

# Control the interface's input settings from the console

Tracking: [#1646](https://github.com/tomassasovsky/segno/issues/1646),
`stage:plan`, `autonomy:plan-gate`. Builds on
[#1046](https://github.com/tomassasovsky/segno/issues/1046) /
[PR #1601](https://github.com/tomassasovsky/segno/pull/1601) (Segno sets the
interface's routing at every device open). Plan:
[`docs/plan/2026-11-04-feat-interface-input-controls-plan.md`](../plan/2026-11-04-feat-interface-input-controls-plan.md).

Every `file:line` below is on `claude/segno-integration` at `2c1c561dc`.
Kernel citations are `sound/usb/mixer_scarlett2.c` on torvalds/linux master,
fetched 2026-11-04.

## Summary

- The hiss on build 228 came from the console's 4i4 recording a guitar on
  Line instead of Inst. The interface holds that setting itself, and nothing
  in Segno shows it or changes it. On the appliance there is no other software
  that can.
- The kernel's `scarlett2` driver exposes the input settings as plain ALSA
  controls, with fixed names and per-model counts. The engine already opens
  that card's controls through the `le_mixer` seam #1046 added, so reading and
  writing them is a small extension of existing, tested code.
- The interface stores these settings in its own memory: the driver saves the
  unit's configuration 2 s after any write (`scarlett2_usb_set_config`,
  `mixer_scarlett2.c:2985`). Its front-panel buttons change the same
  settings and the driver reports the change. So, unlike routing, Segno does
  not need to re-apply anything at open.
- Recommendation: show and change Inst/Line, Pad, Air and 48 V on the Input
  setup tab, for the selected input, writing straight to the hardware and
  reading back what it holds. 48 V asks for confirmation. Interfaces without
  these controls get one line saying to use the interface's own switches. The
  existing input meter, which already reads the raw converter level, gains a
  target band so the player can set the hardware gain knob.

## 1. What the console's interface exposes

`amixer -c 2 contents` on `root@192.168.50.124`, build
0.1.0-experimental.228, kernel 6.12.25, firmware 1605, read 2026-11-04
(read-only). The same controls are in the #1046 fixture
`packages/segno_engine/src/test/fixtures/alsa/scarlett_4i4_gen3.txt:150-172`
and `:583-590`.

| Control | Type | Now |
|---|---|---|
| `Line In 1 Level Capture Enum` | `Line`, `Inst` | `Inst` (set by hand after the hiss) |
| `Line In 2 Level Capture Enum` | `Line`, `Inst` | `Line` |
| `Line In 1 Pad Capture Switch`, `Line In 2 Pad Capture Switch` | boolean | off |
| `Line In 1 Air Capture Switch`, `Line In 2 Air Capture Switch` | boolean | off |
| `Line In 1-2 Phantom Power Capture Switch` | boolean, one for both inputs | **on** |
| `Phantom Power Persistence Capture Switch` | boolean | on |
| `Standalone Switch` | boolean | on |
| `Level Meter` (PCM interface, read-only) | 18 integers, 0-4095 | the unit's own meters |

Inputs 3-4 of the 4i4 are rear line inputs with no switches, so they have no
controls. There is no direct-monitor control on this model; #1046 already
switches it off on the models that have one (`engine_devices.c:231-239`).

Phantom power is on right now, with persistence on, so it survives a power
cycle. The guitar is on a jack cable, which phantom power does not reach, so
nothing is harmed, but nothing in Segno would tell the player.

## 2. What the scarlett2 driver creates on other models

From each model's `scarlett2_device_info` and
`scarlett2_add_line_in_ctls` (`mixer_scarlett2.c:6822-6990`). Names are
`Line In N <Kind> Capture <Switch|Enum|Volume>`, and phantom power is
`Line In a-b Phantom Power Capture Switch` when one switch feeds several
inputs.

| Model | Inst/Line | Pad | Air | 48 V | Software gain |
|---|---|---|---|---|---|
| Scarlett 6i6 Gen 2 | 1-2 | 1-2 | - | (hardware button only) | - |
| Scarlett 18i8 Gen 2 | 1-2 | 1-4 | - | (hardware) | - |
| Scarlett 18i20 Gen 2 | - | - | - | (hardware) | - |
| Solo Gen 3 | 2 (the jack input) | - | 1 | 1 | - |
| 2i2 Gen 3 | 1-2 | - | 1-2 | 1-2 shared | - |
| **4i4 Gen 3** | 1-2 | 1-2 | 1-2 | 1-2 shared | - |
| 8i6 Gen 3 | 1-2 | 1-2 | 1-2 | 1-2 shared | - |
| 18i8 Gen 3 | 1-2 | 1-4 | 1-4 | 1-2, 3-4 | - |
| 18i20 Gen 3 | 1-2 | 1-8 | 1-8 | 1-4, 5-8 | - |
| Solo Gen 4 | 1 | - | 2, three-way | 2 | - |
| 2i2 Gen 4 | 1-2 | - | 1-2, three-way | 1-2 shared | 1-2, with Autogain and Safe |
| 4i4 Gen 4 | 1-2 | - | 1-2, three-way | 1, 2 separately | 1-2, with Autogain and Safe |
| Vocaster One / Two | - | - | - | 1 / 1, 2 | 1 / 1-2 |
| Clarett 2Pre/4Pre/8Pre USB and + | 1-2 | - | 1-2 / 1-4 / 1-8 | (hardware) | - |
| Gen 4 16i16, 18i16, 18i20 | FCP driver: no kernel controls, only a hwdep device for the `fcp-server` user-space daemon | | | | |

"Three-way" Air is `Line In N Air Capture Enum` with `Off`, `Presence`,
`Presence + Drive` (`mixer_scarlett2.c:5279`). Writes can be refused: with
`-EPERM` while Autogain runs or while phantom power is changing state, and
with `-EBUSY` in other driver states (`mixer_scarlett2.c:3834-3930`).

Two facts the design depends on:

- **The number in `Line In N` is the hardware input.** Segno's input `k`
  records hardware input `k` only because #1046 sets the capture routing to
  pass-through on the capture card (`le_own_scarlett2_inputs`,
  `engine_devices.c:242-275`). That holds on the console, so `Line In N`
  belongs to Segno input `N`. A Gen 4 input recorded through its DSP is still
  hardware input `N`.
- **A Gen 3 or Gen 4 unit in mass-storage (MSD) mode creates none of these
  controls**, and none of the routing controls either (`mixer_scarlett2.c:8981`,
  `:9217`). A new unit ships in MSD mode. Only `MSD Mode Switch` exists then;
  turning it off takes effect after a power cycle (or the unit can be started
  with its 48V button held for five seconds, `mixer_scarlett2.c:149-155`).
  Today such a unit gets no routing from #1046 and silently stays as it
  shipped.

Front-panel buttons on Gen 3 send a notification
(`scarlett2_notify_input_other`, `mixer_scarlett2.c:465`), and the driver
re-reads the settings and raises an ALSA control event. A reader sees the new
value either by subscribing to control events or by reading again.

## 3. Other interfaces

| Interface family | What ALSA exposes for inputs |
|---|---|
| Scarlett Gen 1 (`mixer_scarlett.c`) | `Input N Impedance Switch` (`Line`/`Hi-Z`), `Input N Pad Switch`, `Input N Gain Switch` on some inputs (`mixer_scarlett.c:1195-1235`) |
| Focusrite Forte (`mixer_scarlett.c`) | gain, source (`Mic`/`Line`/`Inst`), high-pass, 48 V, phase, pad per input (`:1236-1290`) |
| PreSonus Studio 1810c / 1824c (`mixer_s1810c.c`) | `Line 1/2 Source Type` (preamp on or off), `48V Phantom Power On Mic Inputs Switch` (`:570-615`) |
| RME Babyface Pro (`mixer_quirks.c`) | `Mic-AN1 48V`, `Mic-AN1 PAD`, `Line-IN3 Sens.`, and the same for the second pair (`:3415-3450`) |
| Class-compliant interfaces (Behringer UMC, MOTU M, Audient iD, SSL 2, most others) | Nothing for Inst, Pad or 48 V: these are hardware switches. At most a USB Audio Class feature-unit volume, which is a digital trim after the converter, not the preamp gain |

Only `scarlett2` has a bench unit (the console's 4i4). Rules for the others
can follow the same shape when such hardware is on a bench, as #1601 left its
other routing drivers.

## 4. How established products handle it

**Focusrite Control and Focusrite Control 2** show a strip per analogue
input with its buttons: Inst, Pad (where the model has it), Air (a switch, or
Presence / Presence + Drive on Gen 4), 48 V, and on Gen 4 2i2/4i4 a gain
control with Auto Gain and Clip Safe. Changes apply at once; there is no
Apply. The software and the front-panel buttons control the same settings,
and the unit keeps them.

**alsa-scarlett-gui** (the Linux tool, reading the same kernel controls)
groups "Analogue Input Controls" per input in a fixed order: Inst, Air, Pad,
48 V. Phantom power
persistence, MSD mode and Standalone are in a separate Startup window, not
next to the inputs. Its docs say most of these are "nothing that you can't
access from the front panel anyway", warn that 48 V damages some
microphones (vintage ribbons), and note that on Gen 3 phantom power is off at
power-on unless persistence is set. It listens for ALSA control events, so a
front-panel press shows up in the window.

**Boss RC-600**: phantom power is a system setting under MENU > INPUT >
SETUP, set per mic input (MIC1, MIC2). When it is on, the play screen shows a
phantom-power icon. The owner's manual says to turn it off whenever anything
other than a condenser microphone that needs it is connected. The
specifications list the instrument inputs' maximum level (+7 / +20 dBu) and
impedance (1 MΩ / 25 kΩ) as selectable. The MIXER screen
shows each input's meter with a peak indicator and a scale mark, and the
manual says to set the levels so the peak meets the mark.

**Line 6 Helix** (fixed inputs): Global Settings > Ins/Outs has the
instrument input pad (on for active or high-output pickups, or "No Offset"
to let each preset set it), Mic In Gain, and Mic In Phantom with the
warning never to plug or unplug a mic while it is on. Impedance (Guitar In-Z)
is a per-preset input-block setting, with Auto.

**Sheeran Looper X** (fixed inputs): four combo inputs with hardware gain
knobs. Phantom power is one global switch for all four inputs, under Global
Settings > Audio, with the same warning. The guide describes no Inst/Line
switch. The
input level is shown in the Track, Mixer and Audio Routing views, and the
Input Setup page says to turn the input's gain knob.

What to adopt:

- The input's switches belong to the input, next to its name and its meter
  (Focusrite, alsa-scarlett-gui, Looper X's Input Setup).
- Changes apply immediately and the hardware keeps them (Focusrite). No
  draft, no Apply.
- A shared 48 V switch is one control that names every input it powers, as
  the driver names it (`Line In 1-2 Phantom Power`).
- Every product warns about phantom power; on the console the screen is the
  only place to say it, so Segno asks before turning it on. The device's own
  power-on default is left alone (Gen 3 behaviour, alsa-scarlett-gui).
- Startup settings (persistence, MSD, Standalone) are not input settings and
  stay off the input page (alsa-scarlett-gui).
- Hardware gain is set against a meter with a target mark (RC-600, Looper X,
  Focusrite Gen 4's gain halo).

## 5. Options

### 5.1 Which controls

| Control | Show? | Why |
|---|---|---|
| Inst/Line (`Level`) | Yes | The bug that started this. |
| Pad | Yes, where the model has it | Hot sources (active pickups, line gear). |
| Air (switch, or three-way enum) | Yes | Part of the same strip in every product; harmless. |
| 48 V | Yes, with confirmation | Needed for a condenser mic; on the appliance there is no other way except the front button. |
| Direct monitor | No | #1046 owns it and keeps it off; Segno does the monitoring. |
| Phantom power persistence | No (open question 5) | A startup setting; changing it changes what the unit does at power-on. |
| Standalone, MSD mode | MSD only as a notice (open question 7) | Not input settings. |
| Gen 4 gain, Autogain, Safe | Later (open question 8) | No Gen 4 unit to verify on. |
| Unit's `Level Meter` control | No | The engine already meters the raw input (section 5.6). |

### 5.2 Where it lives

- **(a) Input setup tab, for the selected input.** The tab already picks one
  input by its card, shows its name, its format, its trim and a meter of its
  raw level (`input_setup_tab.dart:57-60`, `:146-178`, `:563-705`). A row of
  the interface's switches for that input fits the task: plug in, choose
  Inst, watch the meter, turn the knob. Each input card can carry a short tag
  (`Inst`, `48 V`) so the state of every input is visible without selecting
  it.
- **(b) Device page, an "Inputs" section.** Puts all interface hardware in one
  place, but away from the input's name and meter. The Device page drafts its
  settings and applies them with one Apply (`device_page.dart:21-27`); input
  switches apply at once, and mixing the two models on one page invites the
  wrong expectation.
- **(c) A fifth routing tab, "Interface".** A separate task the player has
  to know about, and the tab bar is laid out for four pills
  (`audio_routing_tabs.dart:27-41`).

Recommended: (a), with the tags on the cards.

### 5.3 Who owns the settings

- **(a) Reflect the hardware.** The page reads what the unit holds and
  writes the player's change straight to it. The unit saves it. The
  front-panel buttons and the page always agree, because both act on the
  same value.
- **(b) Store per interface, apply at every open (like #1046).** Segno keeps
  the player's choices keyed by interface and writes them at open. A reset or
  replacement unit comes up as the player had it. But a front-panel press is
  reverted at the next open unless Segno also listens and stores it, so
  there are two sources of truth. Re-applying 48 V at open would defeat the
  unit's power-on safety default. The routing is different: it is
  infrastructure the player never chooses, and a wrong value breaks Segno.
  Input switches are the player's per-source choice.
- **(c) Per session or per song recall** (the Helix's per-preset pad). Useful
  only if players move sources between songs; nothing asks for it yet.

Recommended: (a). (b) costs a stored model, an apply path through device
open, and a conflict rule with the front panel, to fix a case (a reset unit)
the player fixes once by looking at the page.

### 5.4 Phantom power

Risks: 48 V damages some ribbon microphones and some unbalanced gear on an
XLR; plugging or unplugging an XLR while it is on makes a loud pop and can
harm equipment; switching it makes a thump on the input.

- Turning it on asks first, naming every input the switch powers ("48 V on
  inputs 1 and 2"), with the warning. Turning it off does not ask.
- Segno never turns it on by itself: not at open, not from a stored value,
  not from a pedal, MIDI or foot action (the control is not in the action
  catalogue).
- Phantom power persistence stays as the unit has it.
- While 48 V is on, the input card says so. A stage-screen indicator (the
  RC-600's icon) needs the state outside the page; the interface's own red
  48V light already shows it on the console. Not in the first version.

### 5.5 While recording

Switching Inst, Pad or 48 V changes the level by 10 dB or more and clicks. The
tab already locks the stereo format while a track fed by either member of
the pair is armed or capturing (`input_setup_tab.dart:40-52`,
`routing_facts.dart:9`). Recommended: the same lock for the interface row,
for the input (and every input of a shared 48 V switch).

### 5.6 Interfaces that expose nothing

- **(a) Nothing.** The row is absent and the player wonders where it went.
- **(b) One note in the row's place:** "Set Inst, Pad and 48 V on the
  interface." Plus, for a unit in MSD mode, a note that it is in setup mode
  and Segno cannot reach its controls or its routing (and, if the owner
  wants it, a button that turns setup mode off, after which the unit needs
  a power cycle).
- **(c) A generic ALSA mixer page** (alsamixer's approach): list every capture
  control the card has. The names do not say which input a control belongs
  to or which one is phantom power, so the safety rule cannot be applied,
  and the class-compliant volumes it would mostly show duplicate Segno's
  trim.

Recommended: (b).

### 5.7 Hardware gain knobs

On every model above except Gen 4 2i2/4i4 and Vocaster, gain is an analogue
knob. The tab already has what the player needs to set it: the meter reads
each input's peak on the raw device buffer, before trim
(`process_input_frame`, `engine_process.c:8193-8194`), and the clip latch is
also on the raw buffer (`engine_process.c:10070-10113`). What it lacks is a
target and an instruction:

- a band on the meter where the loudest playing should peak, as the RC-600's
  scale mark and Focusrite's halo do;
- a note: turn the gain knob on the interface until the loudest playing
  reaches the band. The trim below only changes what is recorded, and
  cannot undo clipping at the converter (the existing clip note already says
  to lower the source).

The meter stays on the selected input only. Meters on every input card would
cost a meter per card per tick; the Looper X shows them on its Mixer page,
which Segno already has.

### 5.8 How the engine reads and writes

- **(a) The engine's `le_mixer` seam.** Rules in `engine_devices.c`, next to
  the routing rules, find the input controls by name and report them per
  input; a write goes through the same `le_mixer` and is read back. The Linux
  side already `dlopen`s libasound and opens a card's controls
  (`engine_linux.c:1119-1316`). The tests run against the 4i4 fixture and
  built cards, as #1601's do.
- **(b) A separate Dart package binding libasound.** A second owner of the
  same card's controls, a second `dlopen`, and the fixture tests rebuilt in
  Dart.
- **(c) `amixer` as a subprocess.** Text parsing, and a child process from the
  app, which #1367 removes.

Recommended: (a). The calls make ioctls that can reach the USB device, so the
Dart side runs them off the UI isolate, as the engine's file decoding already
does (`native_audio_engine.dart:2765-2768`). The symbol table
`le_alsa_ctl_syms_get` resolves once with no locking because only device open
calls it today (`engine_linux.c:1164-1168`); a second calling thread needs a
`pthread_once`.

### 5.9 Seeing front-panel changes

- **(a) Read while the page is open**, a few times a second, and after every
  write and every device open. The driver answers reads from its cache and
  goes to USB only after the unit reported a change, so this is cheap.
- **(b) Subscribe to ALSA control events** on a thread (alsamixer,
  alsa-scarlett-gui). Instant, and it would let state show outside the page,
  but it is a new long-lived native thread for one page.

Recommended: (a). (b) is the upgrade if a stage-screen 48 V indicator is
wanted later.

## 6. Open questions

These are repeated with recommendations in the plan's section 7.

1. Reflect the hardware, or store and re-apply per interface?
2. Which controls in the first version?
3. Input setup tab row, Device page section, or a new tab?
4. Phantom power: confirmation on, never automatic, no stage indicator?
5. Phantom power persistence: leave it alone and keep it off the page?
6. Lock the row while an input's track is armed or recording?
7. MSD mode: a notice only, or a notice with a button that turns it off?
8. Gen 4 software gain, Autogain and Safe: now or a follow-up?
9. The meter's target band: where?

## Sources

- Linux kernel, `sound/usb/mixer_scarlett2.c`, `mixer_scarlett.c`,
  `mixer_s1810c.c`, `mixer_quirks.c`:
  https://github.com/torvalds/linux/tree/master/sound/usb
- alsa-scarlett-gui docs (`iface-small.md`, `iface-large.md`,
  `iface-4th-gen-small.md`, `configuration.md`):
  https://github.com/geoffreybennett/alsa-scarlett-gui/tree/master/docs
- Focusrite user guides, Scarlett 4th Gen and Focusrite Control 2:
  https://userguides.focusrite.com/
- Boss RC-600 Owner's Manual:
  https://static.roland.com/assets/media/pdf/RC-600_eng03_W.pdf
- Line 6 Helix Stadium manual, Global Settings:
  https://manuals.line6.com/en/helix-stadium/live/global-settings, and the
  Line 6 knowledge base on Helix XLR inputs and 48 V phantom power:
  https://kb.line6.com/kb/live/helix-xlr-inputs-outputs-and-48v-phantom-power
- Sheeran Looper X User Guide v1.0.0:
  https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf
