# MIDI controls page: accepted design spec (pen sections 26 and 53, design docs, prototype)

## Sources
- Pen: `/Users/Tomas/Documents/Work/opensource/loopy/segno-ui.pen`. Section 26 `rmWqV` ("26  MIDI controls and Learn", status text `s91q5n`: "Reviewed direction · controller → message → controls"). Section 53 `RQX1Y` ("53  Expanded MIDI Learn", `ziTA5`: "Implemented prototype · September 9, 2026 · Recorded walkthrough available"). Both sit under `p0dpwx` "01 CURRENT UX".
- PNGs: `/private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy/1a736a10-cdfb-4daa-ad93-3176a9204d1d/scratchpad/midi-pen/*.png`. I exported `vsyj4.png` and `p7yOFK.png` into that folder at scale 0.5, matching the existing files. All 12 PNGs match my node reading.
- Docs (main checkout):
  - `docs/design/2026-09-07-midi-controls-ux.md` (MCU)
  - `docs/design/2026-09-09-optional-controls.md` (OC)
  - `docs/handoff/segno-app/accepted-behavior.md` (AB)
  - `docs/handoff/segno-app/implementation-map.md` (IM)
- Prototype (main checkout, `docs/design/`):
  - `midi-controls-study.js` (MCS)
  - `midi-protocol-study.js` (MPS)
  - `midi-controls-study.css` (CSS1)
  - `optional-controls-study.css` (CSS2)
  - `fx-ux-prototype.html` (HOST)
  - `pedal-action-catalogue.js` (PAC)
  - `midi-controls-previews/manifest.json`

## 0. Pen facts that apply to every screen
- **Display size.** Every MIDI screen is drawn only at **1920x1080** (15.6 inch). The manifest records canvas `[1920,1080]` for every frame.
  - There is **no 7 inch variant**. The document's only frame of 1280x720 or smaller at screen depth is `wJlxa` "Selected track · crown" in tile `M1RhZ` "Selected track · 7-inch" (section 25), the selected-track display.
  - A search of all of 01 CURRENT UX for frames between 600 and 1900 px wide found only that one.
- **No rationale notes.** There are no `c/` notes in sections 26 or 53. A document-wide search found five `c/ Implementation` notes in 01 CURRENT UX (sections 05, 08, 10, 21, 25), none about MIDI.
  - The MIDI `c/` notes that exist (`Un5I6` c/midi-switch, `Ya8gK` c/midi-stale, `qwASN` c/midi-listening, `lFtfO` c/midi-replace, `hT84d` c/midi-no-device, `CTjXL` c/midi-gone, `E0JH7P` c/midi-open-failed, `vtMt1` c/control-midi, `g23gw6` c/midi-sweep, `D3cKxP` c/midi-lost-toast) are all under `X5FjMW` "02 EARLIER APPLICATION". They describe the superseded app, not this design.
- **Captured from HTML.** The screens are captures of the HTML prototype. Every node carries `metadata.type:"prototype-element"` and a `context` such as "Prototype control: midi:save".
  - Fills are **raw hex, not token names**. Fonts are **Arimo** (text) and **JetBrains Mono** (numeric readouts; CSS name `SegnoMono`).
- **Recurring colors:**

| Use | Values |
|---|---|
| Screen background | `#111215` |
| Surface | fill `#202735`, stroke `#556881` |
| Selected surface | fill `#2c3c52`, stroke `#91abcd`, text `#edf3fc` |
| Primary button | fill and stroke `#c4d4eb`, text `#162132`, weight 700 |
| Disabled button | opacity 0.4 (CSS1 `.midi-study button:disabled{opacity:.4}`) |
| Text / muted text | `#e7edf6` / `#aebbd0` |
| Warning text | `#e3c08e`, 22px |
| Encoder focus | rectangle, stroke `#f2bf70` 3px inner, radius 8 |

- **Icons** are 28x28 paths, stroke 2.33, viewBox 24:
  - Back = left chevron (`icon('left')`, HOST:1161)
  - Mapping enable = power (`icon('power')`, MCS:24)
  - Remove = close X (`icon('close')`, MCS:26)

### Shared chrome (topbar, identical on every screen; e.g. `qoLuU`, `j9Mb6`)

| Element | Geometry and style | Text / action |
|---|---|---|
| topbar | 0,0 1920x96, bottom stroke 1px `#3d3d3d` | |
| "Back" | 36,16 64x64, radius 8, stroke `#515d6e`, chevron `#e7edf6` | action `back` |
| Tab nav "MIDI sections" | at 124,16 | |
| Tab `midi:open` | 180x64, radius 7, fill `#253041`, stroke `#8496b0` (selected) | "Controls", 24px `#e7ecf5` |
| Tab `sync:open` | at x=192, 180x64, radius 7, stroke `#424955`, no fill | "Sync", 24px `#bec7d6` |
| "Stage" | 1771,16 113x64, radius 8, fill `#202735`, stroke `#515d6e` | "Stage", 24px |

- The tabs come from HOST:1161: `nav.library-tabs aria-label="MIDI sections"`.
- Main area: 0,96 1920x984, padding 36/60, gap 32 (CSS1 `.main.midi-study`).
- Title bar: 60,36 (main-local) 1800x72.
  - h1: 42px Arimo, letter-spacing -1.1, `#e7edf6`.
  - Actions are right-aligned with gap 16. Buttons are 64 high, radius 8, padding 16/24, 24px text.

### Entry point
- Settings grid: section 05 tile "01 / Settings" `ixImV`, screen `v7Ekz`, menu `v8v6EP`.
- Five by two tiles, each 325x244, 32px labels, order: Effects, Loop settings, Pedals, **MIDI** (`gVIpz`, action `midi:open`, at 1046,152), Audio routing / Device, Network, Displays, Storage, Updates.
- Tile artwork is component `E6hyU` "Segno menu · MIDI".
- HOST:1121 renders the menu; HOST:1208 routes `midi:open` to the Controls tab (`midiUI.enter()`, focus `midi:add`).

## 1. Screen: Controller mappings (list); tile `RIrL3`, root `vxmoz`
**Trigger:** Settings → MIDI, or the Controls tab. `enter()` resets view, draft, learn, conflict and notice (MCS:21).

- **h1** "MIDI controls" (`zl9cQ`).
- **Title actions** (`n6xQ2t`, at 1375,4):
  - `midi:global-enabled` 219x64, selected style (fill `#2c3c52`, stroke `#91abcd`), text **"MIDI control On"**. When off it reads "MIDI control Off" with unselected style (MCS:31).
  - `midi:add` 192x64, text **"Add mapping"**. The encoder focus rectangle `Hh2S0` sits on it.
- **Device cards** (`JTim0`, 60,140, 1800x100, gap 18). Each card is 320x100 with radius 12 (CSS1: min-width 320, padding 20/26, grid of 16px then auto).
  - Light: 9x9 radius 4.5, `#e3e4ea` online / `#555555` offline.
  - Name: 25px `#e7edf6` at 59,21.
  - Connection line: 18px `#aebbd0` at 59,58. Format: connection plus " · Disconnected" when offline (MCS:31).
  - Selected card: fill `#2c3c52`, stroke `#91abcd`. Others: `#202735` / `#556881`.
  - Drawn cards:
    - "USB controller" / "USB" (selected, online)
    - "MIDI In" / "DIN" (online)
    - "Keyboard" / "USB · Disconnected" (offline)
  - Prototype port list is fixed and simulated (MCS:3).
  - Tapping a card (`midi:device:<id>`) selects that device, clears the notice, and **filters the rows to that device** (MCS:39, MCS:24).
- **Mapping rows** (`o3II1f`, y=272, gap 14). One row `TjwIM` is 1800x106, radius 12, padding 14/24, gap 28.
  - Row edit button `midi:edit:<id>` (1510x76):
    - Line 1: source name **"CC 21 · Ch 1"**, 26px `#e7edf6`.
    - Line 2: target labels joined with " · ", 20px `#aebbd0`, e.g. "Input 1 · Acoustic guitar / Clean Rhythm · Delay · Mix".
  - Signal meter `nwRP9`: 120x7, radius 3, fill `#31343a`. The bar fills to `level*100%` in `#d7dce6`. Aria label "Last received value N", where N = round(level * protocol maximum) (MCS:24, CSS1 `.midi-signal`).
  - Warning (22px `#e3c08e`): "Missing control" if any parameter target is gone, otherwise "Disconnected" if the selected port is offline (MCS:24).
  - Enable button `O5QYa`: 64x64, radius 8, power icon. When enabled it uses the selected style (fill `#2c3c52`) with aria label "Disable CC 21 · Ch 1" and aria-pressed. When disabled the aria label is "Enable …" and the **whole row renders at opacity 0.5** (CSS1 `.midi-row.disabled`).
  - Toggling enable **saves immediately** (not a draft) and releases that mapping's held momentary values (MCS:55).
- **Notices** below the list: `p.midi-warning` (MCS:31).

## 2. Screen: No mappings; tile `vsyj4`, root `aQHXq`
- **Trigger:** the selected device has no mappings (MCS:24).
- Same header and device cards as §1. The list is replaced by `midi-empty`: centered h2 **"No mappings"**, 32px `#bbbbbb`, at 866,584 main-local (CSS1 `.midi-empty{margin:auto}`).
- No other text and no call-to-action beyond the title-bar "Add mapping".

## 3. Screen: Disconnected controller; tile `sSpdN`, root `MMzPS`
- **Trigger:** `connect(id,false)` (MCS:91).
- USB card stays selected, dark light, "USB · Disconnected".
- Row: the edit button narrows to 1349 wide; meter at x=1402; warning **"Disconnected"** (`p5LwZt`, 22px `#e3c08e`) at 1550,38; enable button unchanged.
- Page notice under the list: **"Controller disconnected"** (`c8jlnl`, 22px `#e3c08e`, at 60,432 main-local).
- Prototype behavior (not drawn):
  - Disconnect releases every mapping on that device, resets the decoder, and leaves assignments in place.
  - Reconnect clears the notice (MCS:91).
  - Add mapping still opens the editor, but Learn is disabled while the port is offline (MCS:23, MCS:26).

## 4. Mapping editor: common layout (roots `nnKUG`, `l2iAy6`, `bJXN8`, `JqcUT`, `T7urI`, `SCQt4`, `jRkHr`, `jWDJD`)
- **h1** is always **"Mapping"** (MCS:31).
- **Title actions** (right-aligned):
  - **"Delete"** 120x64: only when editing a saved mapping.
  - **"Cancel"** 125x64.
  - **"Save"** 107x64, primary. Disabled (opacity 0.4) when there is no source, no controls, a conflict, Learn is active, or the held-instrument rule fails (MCS:31).
- **Delete** saves immediately (no confirmation), returns to the list, releases the mapping, and shows notice "Mapping removed" (MCS:56).
- **Cancel** returns to the list and discards the draft (MCS:57).
- **Save:**
  - Re-checks the source for overlap. On collision it sets the conflict, shows "This source now overlaps another mapping.", and focuses "Edit existing mapping".
  - On success: returns to the list, shows notice **"Saved"**, releases the previous version.
  - On write failure the draft stays open with notice **"Could not save. Your changes are still here."** (MCS:58, MCS:20).
- **Editor grid** (`midi-editor`, 60,140, 1800x808): a 480 px source column, gap 60, then the controls column (CSS1 `.midi-editor`).
- **Source panel** (`midi-source`): 480x808, fill `#202735`, radius 16, padding 36, gap 22 (CSS1 overrides 28 to 22). Children in code order (MCS:26):
  1. Eyebrow: device name, 22px `#aebbd0` ("USB controller").
  2. h2: source name, 32px `#e7edf6`, line-height 1.35, balanced wrap. Reads "No control selected" when there is no source (MPS:23).
  3. **Message format picker** `midi:protocol-picker`: 408x64 button showing the current format label (21px per CSS2, drawn at 24). **Only in section 53 screens; section 26 screens predate it.**
  4. **Received readout** `midi-received`: 22px JetBrains Mono `#c3d6f0`. Shown only after a successful Learn in this session. `learnValue` is cleared on Learn start and on opening an existing mapping (MCS:23, MCS:42).
  5. **Channel picker** `midi:channel-picker` 408x64: "Receive · Channel N" or "Receive · Omni". Only when a source exists.
  6. **Learn:**
     - Not learning: primary button **"Learn"** (no source) or **"Learn another control"** (source exists), disabled when the port is offline.
     - Learning: a listening box (408x155, dashed 1px `#747b87`, radius 12) containing a light bar (90x6, `#c4d4eb`, radius 4) and **"Move a control"** (25px), or **"Reconnect controller"** if offline, followed by button **"Cancel Learn"** 408x64.
  7. **Conflict block** (if conflict): p **"This control overlaps an existing channel mapping."** (22px `#e3c08e`), then button **"Edit existing mapping"** (279x68).
  8. **"Control behavior" segmented** (aria label), 408x74, stroke `#556881`, radius 10, padding 4. Two 197x64 buttons, 21px: **"Knob / fader"** (`midi:behavior:continuous`) | **"Button"** (`midi:behavior:momentary`). Shown **only for a standard-format CC source** (MCS:26).
  9. **"Button behavior" segmented**: **"Momentary"** | **"Toggle"**. Shown when a source exists, behavior is not continuous, and the source is not a Program.
  10. Notice `p.midi-warning` (role=status).
- **Controls column** (`midi-controls`, x=540, 1260 wide):
  - Heading row, 64 high: h2 **"Controls"** (30px), button **"Add control"** (`midi:choose`, 172x64).
  - List at y=88, gap 20, padding 5, scrolls.
  - Empty list placeholder: **"Choose what this control changes."** (25px `#969da8`, margin 46 vertical).
- **Control card** (`midi-control` article): 1250 wide, fill `#202735`, stroke `#556881`, radius 12, padding 22/28.
  - Heading row, gap 18:
    - h3 label, 25px `#e7edf6`.
    - Parameter controls only, when the repair hook is present: button **"Change control"** (213x64), or **"Repair control"** if the target is missing (MCS:26, MCS:52). Drawn in section 53, absent in section 26.
    - Remove button 54x54, no border, close icon, aria label "Remove <label>".
  - Parameter label = target detail + " · " + target label, e.g. "Track 1 · Volume" or "Input 1 · Acoustic guitar / Clean Rhythm · Delay · Mix". Otherwise the stored label, **"Missing control"**, or for a missing action **"Unavailable action"** (MCS:16).
  - **Parameter body** (`midi-ranges`): two columns 578 wide, gap 36. Each range has:
    - Caption row (27 high): caption 21px `#aebbd0` left, output 21px JetBrains Mono `#e7edf6` right.
    - Slider 578x56, radius 12, fill `#14161b`, stroke `#ffffff12`, filled part `#303c52`, 2px edge `#bacce6`.
    - Output = `target.format(v)` or `round(v*100)%`.
    - Slider disabled when the target is missing (MCS:25).
  - **Caption rule** (MCS:25):

    | Draft | Low slider | High slider |
    |---|---|---|
    | Program source | not shown | **"Value"** |
    | continuous | **"From"** | **"To"** |
    | toggle | **"Off"** | **"On"** |
    | momentary | **"Released"** | **"Held"** |

  - **Action body** (`midi-trigger`, gap 28): **"When"** (21px `#e7edf6`), then a segmented control (stroke `#556881`, radius 10) with **"Pressed"** (`midi:trigger:i:press`) | **"Released"** (`midi:trigger:i:release`), 58 high, radius 7, 21px. Selected: fill `#2c3c52`, text `#edf3fc`; unselected text `#aebbd0`. A Program source shows only "Pressed" (MCS:26).

## 5. Screen: Learn a control; tile `Rzp8l`, root `nnKUG`
- **Trigger:** "Add mapping". `add` creates the draft `{device, source:null, behavior:'continuous', enabled:true, controls:[]}` and **immediately starts Learn** (MCS:40).
- Starting Learn (MCS:23):
  - Requires the port online.
  - Resets that device's decoder state and clears `learnValue`.
  - **Pauses the device**: releases every mapping on it and calls `onSuspend`.
  - Starts the timeout clock.
- Drawn: Cancel + Save (disabled); eyebrow "USB controller"; h2 "No control selected"; listening box with light bar and "Move a control"; "Cancel Learn"; Controls heading, "Add control", placeholder "Choose what this control changes."
- **Not drawn:** the Message format picker, which current code renders above the listening box (MCS:26). Section 53 has no Learn-in-progress screen.
- Learn filtering (MCS:63):
  - The decoder must return an event.
  - Note with value 0 (note-off) is ignored.
  - Relative delta 0 is ignored.
- On capture (MCS:64-67):
  - Store source and `learnValue`.
  - Behavior:
    - Program → `trigger`.
    - CC with no action controls → `continuous`, otherwise `momentary`.
    - Any non-standard CC format → `continuous`.
  - A Program source forces every action trigger to `press`.
  - Compute the conflict against same-device mappings excluding the one being edited.
  - End Learn.
- **Timeout** at 15000 ms ends Learn with notice **"No message received. Try Learn again."**, or **"Reconnect the controller to continue."** if offline (MCS:96).
- "Cancel Learn" ends Learn and keeps the draft (MCS:43).

## 6. Screen: Knob or fader; tile `P5dWId`, root `l2iAy6`
- **Trigger:** editing a saved mapping (`midi:edit:<id>`). Edit pauses the device, clones the mapping into the draft, sets the format to the mapping's, and clears `learnValue` (MCS:42).
- Drawn:
  - Title actions: Delete, Cancel, Save (enabled).
  - Source panel: "USB controller", h2 "CC 21 · Ch 1", "Receive · Channel 1", primary "Learn another control", "Control behavior" segmented with "Knob / fader" selected and "Button".
  - One card: "Input 1 · Acoustic guitar / Clean Rhythm · Delay · Mix", ranges **From "Source 0"** / **To "Source 0.65"**. The To slider is filled to 374 of 578.
  - Encoder focus on Back.

## 7. Screen: Button and multiple controls; tile `l9iwlZ`, root `bJXN8`
- Source: h2 **"Note 60 · Ch 1"**. Segmented **"Button behavior"**: "Momentary" (selected) | "Toggle". No Knob/Button group because the source is a Note.
- Card 1: the Delay · Mix parameter, **Released "Source 0.2"** / **Held "Source 0.65"**.
- Card 2: **"Track 5 pedal"** (action `track:4`), "When" with "Pressed" (selected) | "Released".
- Section 53 formats show **"0%"** / **"200%"**: Track volume `format` = `round(v*scale*100)%` with scale 2 for tracks (HOST:704).

## 8. Screen: Choose a parameter; tile `l3ouX`, root `L8j66W`
- **Trigger:** Add control → destination.
- **h1** = destination label, e.g. **"Input 1 · Acoustic guitar"**. Falls back to "Choose a control" (MCS:31).
- The only title action is **"Back"** (`midi:picker-back`, 104x64).
- Grid `midi-targets`: 2 columns, 893x100 cards, gap 14, radius 10, fill `#202735`, stroke `#556881`, scrolls (CSS1: min-height 100, padding 18/26).
  - Each card: label 24px `#e7edf6`, then `small` detail 18px `#aebbd0` (CSS2: 19px `#aeb7c5`, margin-top 8).
- Drawn rows (the pen clips after row 7; the node tree continues to y=6384):
  - "Volume" / "Input 1 · Acoustic guitar"
  - "Pan" / same detail
  - Then FX parameters shown as "<Module> · <Parameter>" with detail "Input 1 · Acoustic guitar / <preset>": Amp · Enable, Amp · Amp Bass, Amp · Amp Drive, Amp · Amp Modern, Amp · Amp Treble, Amp · Cab, Delay · Feedback, Delay · Mix, Delay · Mode, Delay · Time, Delay · Enable, Master · Level, Modulation · Enable/Mod Depth/Mod Mix/Mod Mode/Mod Rate, Overdrive · OD Drive/OD Tone/Enable, Spring Reverb · Enable/Spring Mix/Spring Time, Wah · Enable/Wah Pedal, Whammy · Enable/Whammy Pedal/Whammy Range. The same list repeats for presets Full Drive, Rhythm Chorus and Funk Wah (Funk Wah adds Parametric EQ, Low-pass Filter, Pumper, Reverb, Slicer).
- Pan label is "Balance" for stereo-input balance and for outputs (HOST:704).
- Tapping a target adds `{kind:'parameter', key, label, detail, low:0, high:1}`. Duplicates are ignored. Returns to the editor with focus on "Add control" (MCS:51).
- **Picker levels the pen does not draw** (MCS:29, MCS:31, MCS:32):
  - **"Choose a destination"** (h1), title action "Back". Grid of 3 columns (CSS1: gap 18, buttons 90 min-height, padding 20/30, 25px):
    - First button **"Performance actions"**. It reads **"Performance actions · use a button"** and is disabled when the learned format is 14-bit, NRPN or Relative.
    - Then one button per destination (HOST:703): live inputs; each track and each recorded part ("Track N · <input>"); **"All tracks"** (Master); output mixes; mapping-parameter destinations; instrument destinations "<name> · Sound".
  - **"Performance actions"** (h1):
    - Wrapping group tabs (20px, padding 14/20, radius 8, selected style), from `SegnoMappingActionGroups` (PAC:55): "Modes & functions", "Loop transport", "Loop modes", "Selected track", "Fixed tracks", "All tracks", "Track pedals & bank", "FX pedals", "Instruments", "Backing", "Sessions".
    - Then a 2-column grid of label + detail from `SegnoAssignableActions` (PAC:1-54), e.g. "Cut all sound" / "Stop tracks and backing, and end existing effect tails".
    - Adding an action gives `trigger:'press'` and switches a continuous draft to momentary (MCS:51).
  - **"Receive channel"** (h1): buttons **"Omni · All channels"**, then **"Channel 1"** to **"Channel 16"**. Choosing one recomputes the conflict (MCS:29, MCS:38).
  - **"Message format"** (h1): 5 buttons, label with `small` detail (MPS:4):

    | Label | Detail |
    |---|---|
    | "CC, Note or Program" | "Ordinary 7-bit messages" |
    | "14-bit CC" | "Fresh MSB + LSB pairs" |
    | "NRPN" | "Parameter selection + 14-bit Data Entry" |
    | "Bank + Program" | "Bank MSB + LSB, then Program Change" |
    | "Relative CC" | "Two’s complement · 1 up, 127 down" (U+2019 apostrophe) |

    - Choosing a format returns to the editor and **starts Learn immediately** (MCS:36).
    - Picking 14-bit, NRPN or Relative while the draft has action controls is refused with notice **"Remove action targets before learning a high-resolution or relative control."**

## 9. Screen: Already mapped; tile `F3HLl`, root `JqcUT`
- **Trigger:** a learned source (or a channel change) overlaps a same-device mapping (MCS:38, MCS:67).
- Drawn:
  - Cancel + Save (disabled, opacity 0.4).
  - Source panel: h2 "CC 21 · Ch 1", "Receive · Channel 1", "Learn another control".
  - Conflict text as two lines, "This control overlaps an existing channel" / "mapping." (one sentence wrapped).
  - "Edit existing mapping" button; "Control behavior" segmented (Knob / fader selected).
  - Controls placeholder.
- **"Edit existing mapping"** replaces the draft with the saved conflicting mapping, which keeps its targets. The new draft's learned source and controls are discarded; editing now targets that mapping id (MCS:44; MCU:15-16).
- **Overlap rule** (MPS:16-22; AB:328-329, 334-335):
  - Same device; channels equal or either side Omni.
  - Same format: same kind and number, plus the same NRPN parameter or the same bank.
  - Different formats: the raw CC footprints intersect. NRPN = CC 6/38/98/99; 14-bit = CC n and n+32; Bank+Program = CC 0/32 plus Program n.
  - A disabled mapping still conflicts.

## 10. Section 53 screens (Learn formats); all Mapping editors with Cancel + Save enabled, no Delete, encoder focus on "Add control" (1689,236 171x64)

| Screen | h2 (source name) | Format button | Received line | Controls |
|---|---|---|---|---|
| `E82cGb` / `T7urI` "14-bit CC · Track volume" | "CC 21 / 53 · 14-bit · Ch 1" | "14-bit CC" | "Received 8193 / 16383" | "Track 1 · Volume", "Change control", From "0%" / To "200%" |
| `p7yOFK` / `SCQt4` "NRPN · Track volume" | "NRPN 259 · Ch 1" | "NRPN" | "Received 8199 / 16383" | same |
| `Plope` / `jRkHr` "Bank and Program · Cut sound" | "Bank 260 ·" / "Program 8 · Ch 1" (wraps to 2 lines; picker pushed to y=192) | "Bank + Program" | "Received 127 / 127" | "Cut all sound", When: "Pressed" only |
| `gRRhj` / `jWDJD` "Relative CC · Track volume" | "CC 22 · Relative · Ch 1" | "Relative CC" | "Received -1 step" (ASCII hyphen, U+002D) | "Track 1 · Volume", "Change control", From "0%" / To "200%" |

- **Source-name formats** (MPS:23):
  - "CC n", "Note n", "Program n"
  - "CC n / n+32 · 14-bit"
  - "NRPN p"
  - "CC n · Relative"
  - "Bank b · Program n"
  - Each followed by " · Ch N" or " · Omni".
- **Received formats** (MCS:26):
  - Absolute: `Received <value> / <maximum>`, maximum 127 or 16383.
  - Relative: `Received ` + (`+` if delta > 0) + delta + (` step` if |delta| = 1, otherwise ` steps`). Examples: "Received +3 steps", "Received -1 step".
  - OC:56 writes "−1 step" with U+2212, but the pen and the code use a hyphen.
- **Decoder values** (MPS:30-50; OC:50-67):
  - 14-bit: fresh MSB CC 0-31 + LSB CC 32-63 within 100 ms → `high*128+low`.
  - NRPN: CC 99/98 select (16383 = null), then CC 6/38 → value. RPN CC 100/101 and CC 96/97 cancel.
  - Bank+Program: CC 0 + CC 32 pair, then Program → value 127/127.
  - Relative: value < 64 → +value, else value−128.
- **Channel range:** the Learned message channel is 1-16. The mapping channel may be `omni`. AB:326 says "channel 1–16 or All"; the UI string is "Omni · All channels".
- **Behavior segmented groups** are hidden for all four formats: they force continuous or trigger (MCS:26, MCS:65).
- **Parameters only:** 14-bit, NRPN and Relative accept parameter controls only; Bank+Program and standard Program accept actions (OC:74-76; MCS:12, MCS:29).
- **Program parameter controls** show only the "Value" slider; low is kept unused and high is applied (OC:76-77; MCS:25).

## 11. Behavior and error rules not visible in the pen
- **Held-instrument rule.** Banner above the editor: **"While held needs a momentary Note or CC button, triggered on Press. Use Latch for Program Change."** Save stays disabled until fixed (MCS:27-28, MCS:31; AB:336-337).
- **Choosing "Knob / fader"** with action controls present keeps Button and shows notice **"Actions need a button."** (MCS:45).
- **Global switch** (MCS:34):
  - Writes the setting and releases all mappings.
  - Notice **"MIDI controls enabled"** / **"MIDI controls paused"**; on failure **"Could not save MIDI control setting"**.
  - Instrument note input keeps working when switched off (MCS:69-73; AB:330).
- **Repair notice:** **"Repair ready · Save to keep"** (MCS:52). The repair spec passes labels From/To, Released/Held, Off/On or Value.
- **Dispatch suspension.** While the editor or any picker is open, dispatch from the **selected device** is suspended (MCS:71). Learn and edit pause the device and release its momentary values (MCS:22; MCU:43-44).
- **Encoder:**
  - Press on a slider starts a range edit (focus outline 3px `#f2bf70`, CSS1 `input.editing`).
  - Turning steps by the target's encoder step.
  - Press finishes; Back/Escape restores the value from before the edit (MCS:41, MCS:93-94, MCS:32; HOST:1271-1272; MCU:38-41).
- **Double-tap on a slider** restores the endpoint to its default (low → 0, high → 1) (MCS:95; HOST:1288).
- **Back order** (MCS:32; HOST:637):
  1. Cancel any range edit.
  2. Channel or format picker → editor.
  3. Actions or targets → destinations.
  4. Destinations → editor.
  5. Editor → list (draft discarded).
  6. List → leave the page.
- **Sync tab** and **Stage** call `midiUI.leave()`, which discards the draft (HOST:1208, HOST:1211).
- **Runtime** (MCS:77-86; MCU:28-30, 43-50):
  - Pickup: a continuous control takes over only when it reaches or crosses the current value.
  - Relative: moves from the current value by the target's step, clamped to the range, sign follows range direction.
  - Momentary: Held/Released values.
  - Toggle: latch.
  - Program: acts on every message.
  - Action release functions run on release.
- **Session save** stores held momentary values as Released (HOST:872, MCS:103). Session switch or appliance busy calls `resetRuntime` (HOST:916, HOST:1063).
- **Ownership** (AB:463-465): session recall restores "musical MIDI assignments" but preserves "global MIDI enable/sync settings". In the prototype, `rig.midiMappings` and `rig.midiControlSettings` both live in the rig (HOST:823).
  - **Open question:** #1049 stores `midi.mappings` in app settings, but AB treats mappings as session-owned.
- **Related rules:**
  - Missing targets stay unavailable, with Change control/Remove; there is no label-based rebinding (AB:338-343; MCU:21-22).
  - MIDI Sync shares the device inventory with Controls (AB:510).
  - Touch lock leaves MIDI working (AB:344-345).
  - There is no reserved CC command scheme (OC:68-69).

## 12. Differences between prototype and pen
1. **Format picker:** absent from all section 26 screens (`nnKUG`, `l2iAy6`, `bJXN8`, `JqcUT`). Code renders it on every editor state (MCS:26), placed as in section 53.
   - No screen shows a standard CC with the format picker and the "Knob / fader | Button" group together.
   - No screen shows the Learn-in-progress state with the picker.
2. **"Change control" / "Repair control"** appear only in section 53. Section 26 cards have only the remove X.
3. **Not drawn at all:**
   - Pickers: Choose a destination, Performance actions (group tabs), Receive channel, Message format.
   - States: MIDI control Off; disabled row (opacity 0.5); "Missing control" row warning; Toggle captions Off/On; Program "Value"-only slider.
   - Messages: Learn timeout notices, "Reconnect controller" in Learn, Save failure, "Saved", "Mapping removed", the held-instrument banner, "Actions need a button.", the high-resolution refusal notice, "This source now overlaps another mapping.".
   - Behavior: signal meter filled (all drawn at level 0), encoder range-edit outline.
4. **Section 26 slider outputs** read "Source 0", "Source 0.2", "Source 0.65": the preview's FX parameter formatter. Section 53 shows "0%" / "200%". Output text = `target.format(value)`.
5. **Conflict text** wraps at 408 px as one sentence: "This control overlaps an existing channel mapping."
6. **Listening box border** is a solid 1px stroke in the pen; CSS1 `.midi-listening` specifies dashed.
7. **Encoder focus:** Add mapping on list screens, Back on section 26 editor screens, Add control on section 53. Code focuses "Edit existing mapping" after a conflict (MCS:67), not Back as drawn.
8. **Device list** in the prototype is a fixed simulated list of three (MCS:3). The pen draws three cards in one row at 320 wide.
   - More devices: the CSS flex row (`.midi-ports{display:flex;gap:18px}`) has no wrap or scroll rule.
   - MCU:20 requires USB/DIN distinction and keeping disconnected devices visible.

## 13. Model name mapping (for the implementer; worktree `packages/controller_repository/lib/src/`)
- `MidiBehavior` `continuous` / `momentary` / `toggle` / `trigger` (`midi_mapping.dart:6-19`) matches the prototype behaviors (MCS:26, MCS:64).
- `MidiEdge` `press` / `release` (`midi_mapping.dart:31-36`) matches "Pressed" / "Released".
- `MidiProtocol` `standard` / `cc14` / `nrpn` / `bankProgram` / `relative` (`midi_protocol.dart:10-24`) matches the five Message format rows (MPS:4).
- `MidiMappingProblem` `noSource` / `noControls` / `actionNeedsButton` / `behaviorDoesNotFit` / `programHasNoRelease` (`midi_mapping.dart:147-165`) covers the Save-disabled reasons except conflict, active Learn, and the held-instrument rule, which the cubit or UI must supply.