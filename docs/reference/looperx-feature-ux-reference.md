# Sheeran Looper X (HG08) — feature and UX reference

A description of what the device does and how it puts it in front of the
player. Written to be compared against segno feature by feature (#911); it
deliberately makes no recommendations.

## Provenance, and how to read it

Everything here comes from the extracted 1.0.2 firmware (#887). Three sources,
which have to be read together because the app splits itself across them:

| source | what it gives |
|---|---|
| 243 uncompiled `.qml` files from the app's Qt resources | screen layout, controls, gestures, state bindings, exact pixel sizes |
| the stripped binary's string tables | labels, enum values, setting names — **most user-visible text is in C++, not QML** |
| 306 UI images, 159 presets, the MIDI assignment files | affordances, DSP surface, pedal wire behaviour |

Claims are marked **[observed]** when read directly out of QML, a string table
or an asset, and **[inferred]** when reasoned from surrounding evidence. The
DSP itself was never recovered, so nothing here describes how anything
*sounds*.

---

## 1. Platform and hardware surface

- **Panel:** 800×1280 portrait, displayed rotated to 1280×800 landscape. The
  QML applies the rotation itself — `touchWrapper` carries a
  `Translate{x:-1280}` + `Rotation{angle:-90}` transform when running on the
  device, and no transform otherwise **[observed,
  `main.qml`]**. Root geometry is `800×1280` on hardware, `1280×800`
  off it.
- **The same QML runs on a desktop.** `main.qml`'s root is an `Item`, not a
  `Window`, hosted by a C++ view, and it embeds an `HWEmul` hardware emulator
  shown only when *not* on the device **[observed]**. The product was built to
  be developed without hardware.
- **Two products share the codebase**: HG08 (Looper X) and HG03, branched at
  runtime via `Looper.isHG08()` / `hwInfo.isRadxa`. HG08 drops the separate
  Input Monitor page and renames "Customize Footswitch" to "Customize Pedal
  Menu" **[observed, `Pages/IO.qml`, `Pages/LoopSettings.qml`]**.
- **Controls:** 12 footswitches, one encoder with press, an external
  expression pedal input, and the touchscreen **[observed, the internal MIDI
  assignment map]**.
- **Brightness** is written to
  `/sys/devices/platform/mipi-backlight/.../brightness` **[observed]**.
- Board revision is read from
  `/sys/firmware/devicetree/base/inmusic,az01-pcb-rev` **[observed]**.

## 2. Information architecture

### 2.1 Navigation model

A **page manager** (`airPageManager`) owns a stack of pages; the top bar's
single button is either **menu** or **back** depending on page state
**[observed, `Pages/Common/TopBar.qml`]**. Pages are registered in C++ against
a `Page_*` enum; the full set is:

`Timeline · Track · Mixer · FxAssignment · FxEdit · FxListSelector ·
FSAssignment · FSPages · Functions · Fn · Modes · LoopModes · ClearTrackMode ·
PeelMode · CustomPedalMenu · BackingTracks · Tuner · IO · LoopSettings ·
GlobalSettings · SaveLoad · Save · Load · QuickSave · SaveSession · New ·
Storage · USBTransfer · FirmwareUpdate · BounceProgress · ClearAll ·
LockScreen · ModalDialog · Popup · DevSettings · Exit` **[observed]**

### 2.2 The menu

Three groups, headed **PERFORM**, **SETUP**, **SYSTEM**, laid out as a grid of
200×152 buttons **[observed, `Pages/Menu.qml`]**. Destinations, from the icon
set: New Loop, Load Loop, Save, Timeline, Track, Mixer, FX, Backing Track,
Tuner, Audio Routing, Loop Settings, Settings, Storage, Transfer, Function,
Memory, Firmware Update **[observed, `img/Menu/*.png`]**.

**Menu entries are guarded, not disabled.** Selecting one runs a check first
and may interrupt with a dialog **[observed, `menuItemClick()`]**:

- `UsbAudioCheck` — if USB Audio is active, storage and USB Transfer are
  unreachable. The dialog explains *why* and offers to turn USB Audio off and
  continue.
- `EmptyCheck` — if a loop is in progress, entering a destructive destination
  asks "Would you like to start a new loop? All unsaved changes will be lost",
  and **suppresses the Save option while recording** (`forbidSaving`).

This is a recurring pattern: the device explains the conflict and offers the
resolution inline rather than greying the control out.

### 2.3 Persistent chrome

**Top bar** **[observed, `Pages/Common/TopBar.qml`]** — title, which shows the
page name on sub-pages and otherwise the **current loop name**, tappable to
rename in place; menu/back button; CPU meter (conditional); lock button; save
button; a separate save-FX button; and free/used disk space.

**Bottom bar** **[observed, `Pages/Common/BottomBar.qml`]** — tempo with a BPM
label; a `+48V` indicator shown only when phantom power is on; elapsed and
total loop time, **hidden in Free and Sync modes** where they are meaningless;
and the active loop mode.

Both bars are state displays, not just navigation: phantom power, CPU load and
disk space are always in view.

---

## 3. Performance surfaces

There are two, and they are different views of the same four tracks.

### 3.1 Track page — vertical channel strips

Each track is a 312 px column **[observed, `Pages/Track/TrackColumn.qml`]**
containing, top to bottom:

- **Track name**, 46 px bold, centred, elided, tappable to rename.
- **`FX` badge**, shown only when the track has effects; it turns cyan
  (`#3ACFFC`) when that track is the record-monitored one, white otherwise —
  so one glyph carries two facts.
- **Bars & layers count**, optional (a global setting).
- **A glow image** behind the strip: yellow when soloed, otherwise the track
  colour; hidden when empty or muted.
- **Position indicator** — a 40 px lane with a caret at `track.normPosition`
  and a gradient that fades in toward the playhead, coloured by the track's own
  waveform colour.
- **Mute icon** overlaid when muted.
- **Level meter** — a vertical bar against a labelled dB scale.
- **Volume fader**.

**The meter has a real dB scale**, not a normalized bar: ticks at
`-∞, -40, -35, -30, -25, -20, -15, -10, -5, 0, +10 dB`, labelled
`-∞, -40, "", -30, "", -20, -15, -10, -5, 0, +10` — every 5 dB, labelled every
10 in the crowded region and every 5 near unity **[observed,
`Pages/Track/ScaleGrid.qml`]**. There is a distinct **overload** region above
0 dB.

Meter and fader colours de-saturate to `#383A3F` when the track is muted or
neither playing, recording nor selected — so inactive tracks recede without
disappearing **[observed]**.

### 3.2 Timeline page — horizontal waveforms

The same four tracks as stacked horizontal lanes with waveforms, a shared
caret, and per-lane headers carrying the same name / `FX` badge / bars-and-
layers / level segments, plus left-edge glow images for solo and record state
**[observed, `Pages/Timeline/*.qml`]**.

The pairing is deliberate: **Track** is the mixing view (vertical faders,
dB scale), **Timeline** is the arrangement view (horizontal time, waveforms).

---

## 4. Looping model

### 4.1 Loop modes

`Serial · Sync · SerialSync · Free · Multi` **[observed]**, with
`Multiply · Insert · Replace` as recording behaviors **[observed]**.

Mode changes the meaning of the whole surface: the bottom bar hides loop times
in Free and Sync, and several settings are gated with the message *"This
feature is only available in {Sync} and {SerialSync} modes"* **[observed,
`Pages/LoopSettings.qml`]**. Mode availability is computed per track
(`engineUI.modePossible`), so illegal modes cannot be selected rather than
failing later.

### 4.2 Loop Settings — six sub-pages

A left side-menu with icon + label **[observed]**:

| sub-page | contents |
|---|---|
| **Tempo & Click** | Tempo (BPM, integer/fractional), Time Signature, Click, Count-In |
| **Looper Mode** | the loop-mode picker |
| **Track Length & Quantize** | All Tracks Measures, Quantize, per-track length, auto-length |
| **One Shot & Decay** | one-shot per track, feedback/decay 1–4 |
| **Time Stretch** | Sync Audio to Tempo, Time Stretch |
| **Customize Pedal Menu** | per-pedal function assignment (see §6.3) |

Supporting vocabulary **[observed]**: time signatures `2/4 3/4 4/4 5/4 6/4 7/4
5/8 6/8 7/8 8/8 9/8 10/8 11/8 12/8 13/8 14/8 15/8`; count-in `1–4 Bar`; click
modes `Rec`, `Rec (1st Layer)`, `Rec+Play`, `Muted`; track start `Aligned` /
`Immediate`; track stop `Now` / `Fade` / `End`.

**Track Stop is conditionally explained**: when Track Start is not "Aligned",
the setting shows *"This setting is only available when Track Start is
\"Aligned\""* rather than vanishing **[observed]**.

### 4.3 Per-track state

Volume, pan, mute, solo, name, colour, waveform colour, one-shot, feedback,
track length, quantization, position, peak and level **[observed, the
`trans*` property vocabulary]**. Pan is per-channel (`transPanLeft` /
`transPanRight`) with separate `transGainLeft` / `transGainRight`.

---

## 5. FX system

### 5.1 Racks

Nine factory racks — Ed's, Vocal, Guitar, Lo-Fi, Drum, Dub, Studio, Rhythmic,
Vocal Tuner — each a **fixed chain of DSP blocks with a fixed parameter
schema**, carrying 10–36 presets **[observed]**. A rack is not a user-built
chain: every preset within a rack shares its schema exactly.

Each rack has four artwork variants — `selector/`, `strip/`, `footswitch/` and
the stomp tiles — so the same rack is recognizable in the picker, on the slot
strip, on a pedal and in the editor **[observed, `img/Effects/`]**.

### 5.2 FX assignment page

Four **slots**, one per track, laid out as a row **[observed,
`Pages/FxAssignment.qml`]**. Each slot shows **[observed,
`FxAssignment/Slot.qml`]**: rack name and colour, rack icon, the loaded preset
name, the target track name, a stereo indicator, a pre/post position flag,
bypass state, and **live L/R + peak meters for that slot**. Empty slots show a
`+` affordance.

Slot actions: tap to open, bypass, change FX, delete FX, select track,
toggle pre/post.

Two buttons sit below: **`PEDAL ASSIGN`** and **`EXPRESSION PEDAL ASSIGN`**.

### 5.3 FX editor

Header shows the rack title, an on/off switch, and a bypass control; the body
is a parameter grid **[observed, `Pages/FxEdit.qml`, `FxEdit/ParamsPanel.qml`]**:

- Parameters are laid out **two per row**, and **paginated into up to four
  sub-pages** with `1 2 3 4` tabs shown only when more than one page is needed.
- Each parameter belongs to a sub-effect and is hidden unless that sub-effect
  is selected — the editor is a stomp-strip of blocks, each with its own
  parameters, not one flat list.
- Each block's on/off is a *separate* "bypass parameter", excluded from the
  parameter count.
- Parameters carry per-parameter colour (`fxParamColorModel`).

Parameter readout is `name: value unit` through a translator object, so every
control shows engineering units, not 0–100 **[observed,
`FxEdit/Parameter.qml`]**. Pan parameters get bespoke formatting — `12.3 L`,
`12.3 R`, or `C` at centre. Unit formats recovered from the binary include
`%.1f Hz`, `%.2f ms`, `%.1f : 1`, `%.0f dB`, `%.2f s`, `100 : %.0f`.

Discrete parameters are enumerated with real names, e.g. cabinets
`D.I. | Brit | 1x8" | 1x12" | 2x10" | 2x12" | 4x10" | 4x12" | 1x15" Bass |
4x10" Bass | Radio`; delay modes `DIGI | DIGI L/R | DIGI GRV | DAMPED | …`;
reverb rooms `Off | Booth | Club | Room | … | Concert Hall | Church | Opera
House | Vintage 1 | Vintage 2`; LFO shapes `Sine | Tri | Saw | Square | Morse |
S&H | Random`; 18 slicer patterns including fade variants **[observed]**.

### 5.4 Presets

A `.fxpreset` is `{content, id, name, type}`, where `content` is a flat
`parameter name → 0..1` map plus a `_version` **[observed]**. Presets are plain
JSON on the USB-visible filesystem, unpacked to `FX Presets/<Rack>/<Name>.fxpreset`.

There is a **preset dialog** with save workflow and an unlock gesture — the FX
page counts taps and calls `unlockPreset(unlock > 11)` **[observed,
`Pages/FxEdit.qml`]**, i.e. factory presets are protected behind a deliberate
12-tap gesture.

### 5.5 Expression pedal

Two tabs — **Assign** and **Range** **[observed,
`FxAssignment/Expression.qml`]**. Assignable destinations are any FX parameter
in any slot, plus per-track **Volume** and **Pan**. Each assignment has a
**min and max**, set by selecting the range endpoints, and can be unassigned.
Prompts read *"Assign parameters to expression"* and *"Select parameter for
expression"*.

---

## 6. Footswitches and pedal

### 6.1 Wire behaviour

The control surface is an internal MIDI device. Footswitches are **notes 0–11
on channel 0**; each carries three outputs — press, **hold** (timed) and
**double-press** — routed to `/Hardware/FootswitchN`, `…_Hold`, `…_Double`
**[observed, `HG08_Control_Surface_MIDI_1_Assignments.qml`]**. The encoder,
encoder press, encoder timer and external pedal are separate targets. Transport
targets include `/Engine/Looper/{Record, Play, Undo, Insert, Mute, HalfSpeed,
DoubleSpeed, HalfLen, DoubleLen}` and `/Engine/TempoCtrl/Tap`.

LED feedback is a first-class output type (`ColorOutputAssignment`), and the
firmware has named animations — *"Started RECORD animation"*, *"DUB"*,
*"PLAY"* — plus a tempo blinker **[observed]**.

### 6.2 Footswitch pages

The pedals are modal. Dedicated pages exist for **Modes, FS Pages, Functions,
Loop Select, Transpose, Speed, Reverse, Length, Fade, Extend, Peel Tracks,
Clear Tracks, Bounce** **[observed]**. Assignable functions include
`Play · Stop · Undo · Redo · Mute · Solo · Clear · Peel · Reverse · Transpose ·
Bounce · Tuner · Mode · Function` **[observed]**.

Each pedal renders as a graphic button with a silkscreen legend, a drop shadow,
a hue-saturation tint, an arrow affordance for paging, and a **tappable label**
— the on-screen pedal is itself the editing control **[observed,
`FootswitchGraphicButton.qml`]**. `Fade` offers a **Fade All** action and an
`Exit`; `Length` shows **Loop Length**; `Speed` shows **Current**.

### 6.3 Custom pedal menu

Reachable from Loop Settings. Each pedal gets a dropdown of functions; the top
bar swaps its buttons for **SAVE / CANCEL / CLEAR**, where CLEAR calls
`resetAssignments()` **[observed, `Pages/CustomPedalMenu.qml`]**. A separate
setting, **Reset on New Loop**, controls whether custom assignments survive a
new session **[observed]**.

### 6.4 Global pedal behaviour

Settings that change what every pedal means **[observed, `GlobalSettings`]**:
**Pedal Logic**; **Hold REC+Play Pedal**; **Hold Track Pedal**; **Record / Dub**
with orders `Rec/Dub/Play` and `Rec/Play/Dub`; **Fixed Mode Recording**; and
hold actions `Overdub Arm`, `Clear Track`, `Undo REC`, triggered `On press` or
`On release`.

---

## 7. Mixer

Four track strips, optionally plus **backing track** and **click** strips — the
background art itself swaps between `Background4.png` and `Background6.png`
depending on the `Show Mixer Click & B.Track` setting **[observed,
`Pages/Mixer.qml`]**. Each strip carries volume, pan, and its FX.

Pan uses a **magnified overlay**: tapping a pan control opens a large slider
over a blurred snapshot of the page, titled with the track name, dismissed by
tapping outside **[observed]**. The same pattern is used on the I/O page — a
consistent "small control, big editor" idiom for fiddly values on a touchscreen.

---

## 8. Audio I/O and routing

Three sub-pages on HG08 — **Input Setup**, **Track Setup**, **Output Setup**
(HG03 adds a fourth, Input Monitor) **[observed, `Pages/IO.qml`]**. The routing
model exposes inputs, outputs, per-channel gains and pans, stereo link, direct
monitor, input monitor and record-monitor mode **[observed, the routing
property vocabulary]**.

Hardware audio settings live in Global Settings → **AUDIO**: Phantom Power
(+48V), XLR Ground Lift, 1/4" `Line`/`Amp`, Tuner Output, and input level
**[observed]**. Sample rates `44.1 / 88.2` appear alongside USB Audio's own
rate and input-level settings **[observed]**.

---

## 9. Tuner

Full-page. Shows cents deviation over a **±50 cent** range with a three-state
verdict: in-tune within **±3 cents**, otherwise flat or sharp **[observed,
`Pages/Tuner.qml`]**. Two controls: **PITCH REFERENCE** (A4 calibration) and
**INPUT SELECT**. A global **Tuner Output** setting decides whether audio is
muted while tuning **[inferred from the setting name and its placement in the
AUDIO group]**.

---

## 10. Backing tracks

A dedicated page with a **LEVEL** control and a `LOADING...` state
**[observed]**, transport buttons, and a track browser. Backing tracks are
selected via `SELECT BACKING TRACK` and can appear as their own mixer strip.
Audio import supports `.wav` and other formats via ffmpeg (the binary links
`libavcodec`/`libavformat`), with an **Import Audio** dialog that includes a
**Number of Bars** step and a progress screen **[observed]**.

---

## 11. Storage, save/load, transfer

- **Save/Load** is a two-panel browser: a **STORAGE** panel listing partitions
  (internal and attached), and a folder/loop list **[observed,
  `Pages/SaveLoad.qml`]**. It has an on-screen keyboard, folder navigation,
  name-collision and free-space checks (`saveLoopWithSpaceCheck`), and
  footswitch control of the list — pedals drive the browser, not just the
  touchscreen.
- **Storage** page manages devices and enforces safe removal: *"You must use
  the eject button before removing a storage device"* **[observed]**.
- **USB Transfer** puts the device into mass-storage mode. The copy is
  explicit and instructional: *"Ready for Transfer"*, *"Please connect Looper X
  to your computer via the USB Type-B port on the rear panel"*, then
  drag-and-drop guidance, *"tap DISCONNECT below to apply your changes"*, an
  eject warning *"to avoid potential data loss"*, and *"Do not power off Looper
  X during the USB Transfer process"* **[observed]**.
- **Firmware update** has its own page and a modal warning: *"Updating… This
  may take up to 2 minutes. Do not turn off the device until this process is
  complete."* **[observed]**. The app also checks a pedal-firmware version
  (`firmware.json`, `*.rbin`) and schedules a DFU update if it differs
  **[observed]**.
- **Bounce** renders tracks to a file with its own progress page **[observed]**,
  and an **After Bounce** setting decides what happens next.

---

## 12. Settings inventory

**Global Settings**, five sub-pages: `GENERAL · AUDIO · USB AUDIO · MIDI ·
INFO` **[observed]**.

| group | settings |
|---|---|
| GENERAL | Pedal Logic; Hold REC+Play Pedal; Hold Track Pedal; After Bounce; LCD Brightness; Bars & Layers Count; Show Mixer Click & B.Track; Record / Dub; Fixed Mode Recording |
| AUDIO (HARDWARE) | Phantom Power (+48V); XLR Ground Lift; 1/4"; Tuner Output |
| USB AUDIO | Enable; Sample Rate; Input Level; Mode |
| MIDI | MIDI Clock Receive; MIDI Clock Source; MIDI Clock Send; MIDI Clock Offset; MIDI Clock Destination; MIDI Thru; External MIDI Control; External MIDI Channel |
| INFO | FIRMWARE version; License (full text viewable in-app) |

**Loop Settings** are per-loop, and separated from global ones — the split is
"settings that travel with the song" versus "settings that belong to the rig".

---

## 13. MIDI

Two roles **[observed]**. As a **control surface host**, it loads assignment
files by device name (`<Device>_Assignments.qml` + `<Device>_Device.qml`, with
`DefaultAssignment.qml` fallback), so controllers are described declaratively
in QML rather than compiled in. As a **clock peer**, it sends or receives MIDI
clock with a configurable source, destination and **offset in milliseconds**,
and can act as slave (`isBeatClockSlave`, surfaced in the bottom bar).

There is a **MIDI learn** system with an advanced mode: it analyses the
incoming message, detects encoder type, handles velocity, aftertouch,
double-precision (LSB) and inversion, and reports progress through stages
**[observed]**. External control is channel-selectable including `Omni`.

---

## 14. Visual design language

- **Palette:** near-black surfaces (`#13131C` page, `#222226` slot, `#252733`
  parameter), white text, `#3ACFFC` cyan accent for the record-monitored
  track, yellow for solo, `#747A86` for bypassed text, `#383A3F` for inactive
  meters **[observed]**.
- **Type:** Nunito Sans throughout — Regular, Bold and Black — at large sizes
  (46 px track names, 30 px page titles, 21 px badges) **[observed]**. It is a
  stage instrument, and the type sizes say so.
- **Colour as identity:** tracks, racks and pedals all carry a user-visible
  colour, with a colour-picker affordance (a 90 px circle) in the pedal
  assignment header **[observed]**.
- **Depth:** drop shadows and blur are used functionally — modal overlays blur
  a live `ShaderEffectSource` snapshot of the page beneath **[observed]**.
- **State on the surface:** phantom power, CPU, disk space, tempo, slave state
  and loop mode are permanently visible in the chrome rather than buried.
- **Explain, don't disable:** conflicting actions produce a dialog that names
  the conflict and offers the fix; unavailable settings state their
  precondition in words.

---

## 15. Index for comparison

Feature areas to line up against segno, in rough order of how much of the
product they define:

1. Loop modes and the per-track legality of each
2. Quantize / track length / count-in / time signature
3. One-shot and decay per track
4. Time stretch and sync-audio-to-tempo
5. The two performance views (channel strips vs waveform lanes)
6. dB-scaled metering with an overload region
7. Rack model: fixed chains with fixed schemas, versus user-built chains
8. FX editor: sub-page pagination, per-block bypass, engineering-unit readouts
9. Preset model and the factory-preset lock gesture
10. Per-slot metering and pre/post placement
11. Expression-pedal assignment with per-assignment min/max
12. Footswitch model: press / hold / double, modal pages, custom assignment
13. LED feedback and animations
14. Mixer with optional click and backing-track strips
15. I/O routing surface
16. Tuner
17. Backing tracks and audio import
18. Save/load browser driven by pedals as well as touch
19. USB transfer and storage safety
20. MIDI clock peer + declarative controller assignment + MIDI learn
21. Global-versus-loop settings split
22. Chrome as permanent state display
23. "Explain, don't disable" as an interaction principle
