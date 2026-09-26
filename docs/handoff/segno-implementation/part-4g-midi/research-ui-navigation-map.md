# Existing MIDI UI, Settings navigation and reusable widgets for the MIDI controls page

Worktree `wt-4fe`; every path below is relative to it. I read the pen through pencil MCP only and changed no files.

## 1. Control tray (`control_tray_panel.dart`, `midi_tray_body.dart`)

### How the tray is opened
- The stage header gear `stage_settings` calls `SettingsTrayCubit.open()` (`lib/looper/view/stage_top_bar.dart:69-72`). On the console this tray is "Settings".
- Rail row `TrayRailEntry.control` (`lib/looper/view/tray/tray_navigation_rail.dart:33-34`) maps to `SettingsTrayDestination.control` (`:57`).
- `control` is also the landing destination:
  - default in `settings_tray_state.dart:82`
  - `closeTray` resets to it (`settings_tray_cubit.dart:92-97`)
  - `showLanding` sets it (`:142-143`)
- The face switch is at `lib/looper/view/tray/tray_panel.dart:136-137`.

### `ControlTrayPanel` (`lib/control/view/control_tray_panel.dart:16-47`)
- It is a `ConsoleDomainPanel<ControlTab>` with two `PillTab`s: `ControlTab.pedal` (`:34`) and `ControlTab.midi` (`:35`). The body switch is at `:40-43`.
- The tab state lives in several places:
  - enum `lib/control/control_tab.dart:6-12`
  - state field `settings_tray_state.dart:84,115,129,137,148`
  - `showControlTab` at `settings_tray_cubit.dart:129`
  - doc mentions in `lib/audio_setup/audio_tab.dart:3`, `lib/system/system_tab.dart:3`, `settings_tray_state.dart:15-22`
- If `midi` is removed, one tab is left. `ConsoleDomainPanel` hides the strip only when `tabs.isEmpty` (`lib/common/console_surface.dart:1370-1379`), so a single pill would still draw. Removing `ControlTab`, `controlTab` and `showControlTab` is the consistent option.

### `MidiTrayBody` (`midi_tray_body.dart:26-967`), section by section

| Lines | Content | Mapping editor? | Action |
|---|---|---|---|
| 145-147, 151-157 | Watches `MidiSetupCubit.connection`; listener on `activityTick` drives `_sawTraffic` (1500 ms quiet window, `:74`) | No | Logic can move to the new page |
| 158-166, 96-137 | Listener on `controllerLearn` / `controllerBindings` (`_followRelearn`) | Yes (old model) | Remove |
| 197-272 `_deviceCard` | "MIDI FOOT CONTROLLER" device row; opens a `ConsolePickRow` chooser in place; keeps an unplugged pinned device dimmed (`:212-225`); calls `MidiSetupCubit.select(id)` (`:262`) | **No** | **This is the only MIDI device picker in the app** (see §2) |
| 284-386 `_statusCard` | Status banner mapping `MidiConnectionStatus` → l10n + tone (`:311-332`); traffic banner receiving/waiting (`:344-363`) | **No** | Status mapping can be reused |
| 290-306, 364-383 | Global "Simulate input" → `simulateStatusRow` | Yes (old) | Remove |
| 181, 388-412 `_transportMap` | Fixed CC transport prose built from `ControllerMapping.defaults()` | Old fixed scheme | Remove |
| 183-187, 414-635 | Learn group, `_mappingsCard`, Add sweep/switch chips, `_addChooser` (`learnControllerBinding`), `_learnBanner` | Yes | Remove |
| 638-952 `_MappingRow` | LO/HI/threshold `ConsoleValueBar`s, `ConsoleSegmented<BindingBehavior>`, Simulate/Relearn/Remove | Yes | Remove |
| 954-967 `_bindingResolves` | Old binding resolve check | Yes | Remove |

### `PedalTrayBody` (`pedal_tray_body.dart:32-519`)
- It is not MIDI and should stay.
- It holds FX-mode footswitch `PedalBinding` assignments.
- It has the "Pedals setup" row `pedal_open_setup`, which calls `openPedalSetup()` (`:96-106`).

### MIDI wiring outside the tray (stays)
- `MidiSetupCubit` is created at `lib/app/view/app.dart:491`.
- Lost/restored toast: `app.dart:1122-1150`; its listener: `app.dart:1355-1360`.
- `MidiSetupCubit` (`lib/audio_setup/cubit/midi_setup_cubit.dart:18-56`) offers `select`, `selectNone` and `refresh`. `activityTick` is at `midi_setup_state.dart:19`.

### Tests
- **`test/control/control_face_test.dart`**
  - Harness `:120-200` builds a real `ControllerRepository` over a fake source plus `SimulatedControllerSource`, and passes `ControlCubit(controller:, midiDevices:, simulatedSource:)` (`:147-158`). The MIDI repository mock is at `:103-113`.
  - Group "Control face" `:210-229` reads the MIDI tab label; adjust it.
  - Group "Pedal tab" `:231-462` stays.
  - Group "MIDI tab" `:464-1040` is entirely old model; delete.
  - `showMidi` helper `:205-208`: delete.
- **`test/screenshots/control_center_preview_test.dart`**
  - `'control domain, midi tab on a live link'` `:897-944` uses `setControllerBindings` / `ControllerBindingSet`.
  - `'control domain, midi device chooser open'` `:946-977`.
  - Goldens to delete: `goldens/control_center_control_midi.png`, `goldens/control_center_control_midi_device.png`.
  - The `controller_repository` import (`:10`) and the `ControlTab` import (`:27`) are used by these tests. The MIDI mock rig at `:455-480` feeds `controlProviders`.

## 2. `midi_learn_section.dart` and `audio_settings_section.dart`

### `MidiLearnSection` (`lib/audio_setup/view/midi_learn_section.dart:27-501`)
Everything in it is the old model:
- `SetupGroupLabel` "EXTERNAL MIDI CONTROL" plus hint (`:49-51`)
- device-missing notice (`:52-59`)
- empty notice (`:61-62`)
- one `_MappingRow` per `ControllerBinding` (`:151-299`): trigger label, target, Learn/Relearn, Remove, stale detail
- `_RangeControls` LO/HI using `SignalKnob` (`:303-343`)
- `_SwitchControls` threshold knob plus Material `SegmentedButton<BindingBehavior>` (`:346-415`)
- `_LearnStatus` (`:419-457`)
- `_AddRow` with two `PopupMenuButton`s (`:86-147`)

It is embedded only at `audio_settings_section.dart:111-113` (import `:10`) and exported from `lib/audio_setup/audio_setup.dart:14`.

### `AudioSettingsSection` (`audio_settings_section.dart:27-322`)
- Mounted only by the legacy `SettingsPage._audioSection` (`lib/looper/view/settings_page.dart:231-233`).
- **It has no MIDI device picker.** The comment at `:104-107` says so, and `test/audio_setup/view/audio_settings_section_test.dart:425-432` asserts the key `midiSettings_section` is absent. No code emits that key.
- `PedalSettingsSection` (`:109`) stays.
- Consequence: once the tray MIDI tab is gone, device selection and connection status exist nowhere unless the new page provides them. The pen's MIDI screen has a `midi-ports` frame for this (§3).

### Tests
- `test/audio_setup/view/midi_learn_section_test.dart` (group `:195-497`): delete.
- `audio_settings_section_test.dart`: the `_MockControlCubit` (`:25-26`, field `:37-39`, setup `:89-94`, provider `:140`) exists only for `MidiLearnSection`, as the comment at `:37` says.
- The `_MockMidiSetupCubit` (`:18-19,32,50-56,135`) is also watched only by `MidiLearnSection` (`midi_learn_section.dart:42`) in this subtree. Neither remaining sibling needs it: `PedalSettingsSection` watches only `PedalCubit` (`pedal_settings_section.dart:34`), and `ClickVolumeSection` watches `TempoCubit` (`click_volume_section.dart:27`).
- Both mock providers can therefore go.

## 3. Settings navigation

### Pen (read via pencil)
- **Settings screen** `v7Ekz` (tile `ixImV` "01 / Settings") is a grid of **10 tiles** in `menu` `v8v6EP`:
  - Effects `teuMj`
  - Loop settings `fzZjW`
  - Pedals `Fmk9g`
  - **MIDI `gVIpz` (name `midi:open`)**
  - Audio routing `y920Og`
  - Device `G5wxu`
  - Network `s6GvaD`
  - Displays `s3ZUlc`
  - Storage `MwoCC`
  - Updates `IEbE8`
- The tiles use the components `Segno menu · <X>`; MIDI's is `E6hyU`. The handoff requires this: "Settings retains ten direct illustrated destinations" (`docs/handoff/segno-app/accepted-behavior.md`, section 1 item 7).
- **Section `rmWqV` "26 MIDI controls and Learn"** has 8 screens:
  - `vxmoz` Controller mappings
  - `nnKUG` Learn a control
  - `l2iAy6` Knob or fader
  - `bJXN8` Button and multiple controls
  - `L8j66W` Choose a parameter
  - `JqcUT` Already mapped
  - `MMzPS` Disconnected controller
  - `aQHXq` No mappings
- In `vxmoz`, the top bar has a **"Controls" / "Sync" tab pair** (`kqkor`, `tgft7`) where other pages have a crumb. The title is "MIDI controls"; the body frames are `midi-ports` and `midi-list`.

### Code: there is no 10-tile Settings home and no MIDI placeholder
- There is no enum value, route, or l10n string "MIDI controls". The closest l10n keys are `midiLearnGroup` (`app_en.arb:1685`) and `controlMidiTab` (`:2240`).
- The `SettingsTrayDestination` doc (`settings_tray_state.dart:10-13`) forbids placeholder values.
- Three structures exist today:

**a. Tray rail (what the header gear opens)**
- `enum TrayRailEntry { effects, control, loop, tracks, audio, tuner, network, system }` (`tray_navigation_rail.dart:23-52`); `destination` getter `:55-64`. Rows are built at `:254-275`.
- Route rows (destination `null`) rely on wildcards that fall through to Loop:
  - `_routeGlyph` `:154-161`
  - `_routeLabel` `:164-168`
  - `_openRoute` `:171-174`
- **Trap:** a new route entry that does not update these three switches silently gets Loop's icon, label and route.
- Test: `test/looper/view/settings_tray_test.dart:520-536` checks every destination has a row and that Loop follows Control.

**b. Legacy `SettingsPage`** (`lib/looper/view/settings_page.dart`)
- `enum SettingsSection { view, audio, tracks, updates }` (`:22-34`).
- Route rows after Audio: `settings_tab_loop` (`:307-312`), `settings_tab_routing` (`:314-319`), `settings_tab_fx` (`:321-326`).
- Opened by `openSegnoSettings` (`segno_navigator.dart:196-220`). Callers: `app.dart:1167,1206`, S key `tracks_commands.dart:229`, right-click `tracks_view.dart:195`, `tracks_chrome.dart:24`.
- Test: `test/looper/view/settings_page_test.dart:401-418`.

**c. Routes** (`lib/app/segno_navigator.dart`)
- Route names `:18-34`; guard bools `:36-40`.
- `openFx` `:59-75`, `openAudioRouting` `:80-96`, `openPedalSetup` `:100-115` (its `finally` also clears `_externalPedalsOpen`, `:113`), `openExternalPedals` `:123-137`, `openLoopSettings` `:142-158`.
- `resetSegnoNavigatorForTest` `:168-177`; every new guard must be added here.

### How External pedals is reached
Header gear → tray Control face, Pedal tab → row `pedal_open_setup` (`pedal_tray_body.dart:96-106`) → `PedalSetupPage` → `LoopChoiceButton` `pedal_setup_external` (`pedal_setup_page.dart:277-284`) → `openExternalPedals()` → `desktopPageRoute(... ExternalPedalPage(), RouteSettings(name: segnoExternalPedalsRouteName))`. No test targets `pedal_open_setup` or `pedal_setup_external`.

### Wiring the MIDI controls page the same way
- Add `segnoMidiControlsRouteName`, a `_midiControlsOpen` guard, `openMidiControls()` modelled on `:123-137`, and the reset at `:168-177`.
- Entry-point candidates, since no tile grid exists:
  - a `TrayRailEntry` route row (fix the three wildcards)
  - a `SettingsPage` rail route row next to `:307-326`
  - a row replacing the tray MIDI tab
- Crumb options: `loopSettingsCrumb` "SETTINGS" (`app_en.arb:3268`, used by `audio_routing_page.dart:80`) or `pedalSetupCrumb` "SETTINGS / Pedals" (`:4770`).
- `LoopSettingsFrame.crumb` is a plain `String` (`loop_settings_frame.dart:55,105-116`). There is no slot for the pen's Controls/Sync top-bar tabs.
- Template parts of `ExternalPedalPage`:
  - `Scaffold` + `LoopSettingsFrame` (`external_pedal_page.dart:171-197`)
  - draft that stays `null` until the first edit (`:85,168`)
  - an in-page `_view` enum for subviews, with Back stepping through them (`:65-77, 574-592`)
  - Save/Cancel/"Saved" actions (`:598-653`)
  - `dispose` undoes a cubit side effect: `setCalibrating(null)` (`:156-161`). The MIDI equivalent is `endMidiEdit` (`control_cubit.dart:2645`).

## 4. Reusable widgets

The MIDI controls page is a pen-canvas page: 1920×1080, scaled by `LoopPenCanvas`. Widgets named `Console*` are sized for the tray and would be much too small there.

| Widget / function | File:line and signature | Example call |
|---|---|---|
| `LoopSettingsFrame` | `loop_settings_frame.dart:43-52` `({crumb, title, onBack, onStage, children, titleLeft=36, actions})`; `kLoopPenSize` `:8`; `LoopPenCanvas` `:16-33`; children are positioned in the 1920×984 main area | `external_pedal_page.dart:172-197` |
| `ControlRowTile` | `control_row_list.dart:15-27` `({destination, name, onTap, value, valueKey, art, artSize=Size(68,68), selected=false, available=true, taken=false})`; `height` 96 (`:65`) | `expression_controls_panel.dart:175-191`; `external_controls_editor.dart:193-210, 513-520` |
| `ControlRowList` | `control_row_list.dart:180-185` `({itemCount, itemBuilder, selectedIndex})`; gap 12, padding 4; wraps `ScrollMoreHint` (`scroll_more_hint.dart:14-18`) | `expression_controls_panel.dart:170-193` |
| `ExpressionDestinationPicker` | `expression_target_picker.dart:18-25` `({destinations, kind, onKind, onOpen, columns=2})`; keys `expression_kind_<kind>`, `expression_destination_<id>` | `external_pedal_page.dart:262-270, 1050-1064` |
| `ExpressionControlPicker` | `expression_target_picker.dart:162-167` `({destination, taken: Set<ControlValueTarget>, onPick})`; key `expression_target_<canonical>` | `external_pedal_page.dart:279-295` |
| `ExternalControlTargetList` | `external_controls_editor.dart:449-455` `({destination, taken: Set<Object>, onActivation, onParameter})`. It mixes `FxBindingTarget` activations; a MIDI control key is only a `ControlValueTarget` or a `ControlAction` (`control_cubit.dart:2553-2561`) | `external_pedal_page.dart:1012-1049` |
| `expressionTargetName` | `expression_catalogue.dart:135-158`, returns `(destination, group, control)`. Covers only `TrackVolumeTarget`, `MasterGainTarget` and `FxParamTarget`; no pan or balance target exists, although the design lists mixer volume/pan/balance | `external_pedal_page.dart:444-449` |
| `expressionRowName` | `expression_catalogue.dart:163-173` | `external_pedal_page.dart:450` |
| `expressionDestinations` | `expression_catalogue.dart:186-251` `(l10n, trackNames, looper, {withActivations=false})` | `external_pedal_page.dart:457-462` |
| `expressionTargetArt` | `expression_catalogue.dart:266-282` `(looper, Object target)` | `external_pedal_page.dart:452` |
| `expressionActivationName`, `expressionKindLabel` | `expression_catalogue.dart:297-304`, `:392-397` | `external_pedal_page.dart:861`; `expression_target_picker.dart:68` |
| `ExpressionControlsPanel` + `ExpressionRow` | `expression_controls_panel.dart:42-52` `({rows, selected, position, onSelect, onAdd, onChange, onRemove, onEndpoint})`, row `:13-19`. Its two endpoint sliders (`:251-307`, `LoopSlider` 625 wide) are labelled Heel/Toe | `external_pedal_page.dart:344-360` |
| `ExternalControlsEditor` + `ExternalControlRow` | `external_controls_editor.dart:62-73` `({rows, selected, latching, onSelect, onAdd, onRemove, onCondition, onValueCondition, onValue})`; row constructors `.activation` / `.parameter` `:15-30`. Parameter rule `:308-364`: condition choice row plus two 500-wide sliders (Off/On or Released/Held). Closest match to a MIDI button mapping. Helpers `conditionLabel` `:437-443`, `externalControlKey` `:430-434` | `external_pedal_page.dart:898-946` |
| Action catalogue picker | `showControlActionPicker(context, {title, current, trackNames})` returns `PedalChoiceResult<ControlAction?>?` (`pedal_choice_picker.dart:246-278`); generic `showPedalChoicePicker` `:70-86`; `PedalChoice` / `PedalChoiceGroup` / `PedalChoiceResult` `:11-62`. Catalogue: `controlActionCatalogue` `control_action.dart:425`, `controlActionsIn` `:439`, `controlActionGroups` `:444`, `ControlAction.tryParse` `:242`, `.key` `:277`. Labels: `controlActionLabel` `control_action_labels.dart:14-32`, `controlActionNone` `:34`, `controlActionGroupLabel` `:37-52` | `external_pedal_page.dart:1229-1234` |
| `PedalSetupField` (action field) | `pedal_setup_editor.dart:13-22` `({label, value, onTap, width=680, height=140, buttonHeight=96, valueFontSize=30})` | `external_pedal_page.dart:1208-1219` |
| `LoopSlider` (From/To) | `loop_settings_widgets.dart:744-753` `({value, onChanged, width, semanticLabel, onChangeEnd, enabled=true, height=56})`. **No double-tap reset.** That exists only in the `ConsoleResetTap` mixin (`console_surface.dart:1921`, used by `ConsoleValueBar` `:2059`) and in `onDoubleTap` handlers in `mixer_column.dart:640,822` | `expression_controls_panel.dart:293-303`; `external_controls_editor.dart:409-419`; `output_setup_tab.dart:266-274` (with `onChangeEnd`) |
| `LoopChoiceButton` / `LoopChoiceRow` | `loop_settings_widgets.dart:13-23` `({label, selected, onTap, width, height=96, icon, enabled=true, fontSize=24})`; row `:111-124` | Pen-page tab rows: `external_pedal_page.dart:659-699` |
| `LoopOutlinedButton` | `:327-341` `({width, onTap, label, icon, leadingIcon, trailingIcon, semanticLabel, semanticValue, tone, height=64, fontSize=24, radius=7})`; `LoopButtonTone` `:309-321` | Save/Cancel `external_pedal_page.dart:622-635`; Add `expression_controls_panel.dart:122-128` |
| Section label / notes / banner / hub row | `LoopSectionLabel` `:190`; `LoopNote` `:470` with `LoopNoteTone` `:496-502`; `LoopLockBanner({text, width})` `:508` (68 high, warning edge); `LoopHubRow({title, summary, onTap})` `:873-878` (1848×100 with chevron) | `loop_length_page.dart:126`; `output_routing_tab.dart:244` |
| Pen top-bar tab bar | `AudioRoutingTabBar({selected, onSelected})` `audio_routing_tabs.dart:11-15` (1720×93, per-pill pen widths) | `audio_routing_page.dart:92-95` |
| `PillTabs` / `PillTab` | `lib/common/pill_tabs.dart:34-39` `({tabs, selected, onChanged})`; `PillTab({value, label, tooltip})` `:8`. Tray size (16 px label) | `control_tray_panel.dart:28-36` |
| Toggles | **No pen-size toggle exists in `lib`.** `ConsoleSwitch({value, onChanged, semanticLabel, small})` `console_surface.dart:1571-1577` has a 53×31 track (`wifi_tray_body.dart:94`). `SetupToggleRow` `setup_surface.dart:69` (`settings_page.dart:167-174`). Pen components: `Toggle` `QfxPn`, `ToggleSm` `AMRfw` | — |
| Empty states | Pen pages use centred `AppText` in `textSecondary` 26/1.3 (`expression_controls_panel.dart:153-164` key `expression_empty`; `external_controls_editor.dart:174-185`). `ConsoleEmptyCard({message})` `console_surface.dart:1854` is tray size | — |
| Disconnected banners | `ConsoleBanner({message, tone, actions, progress})` `console_surface.dart:1684-1690`, `ConsoleBannerTone` `:1665` (tray size; used by the MIDI tray status). Pen pages: `ExpressionPositionPanel` status text `expressionNotConnected` (`expression_position_panel.dart:57,87`); `LoopLockBanner`. Stage `_LostBanner` is private (`connectivity_banners.dart:71`) | — |
| Pen-size modal | `showPedalClearDialog` / `_PedalClearDialog` inside a `kLoopPenSize` `FittedBox` (`pedal_setup_page.dart:703-794`) | — |
| Theme | `context.surface` (`surface_theme.dart:626-629`). Tokens `:72-277`: `background`, `surface`, `card`, `cardHigh`, `line`, `control(Strong)`, `scrim`, `borderHairline/Subtle/Strong`, `accent`, `onAccent`, `accentSurface`, `warning`, `success`, `rec`, `textPrimary/Secondary/Tertiary/Muted`, `disabledOpacity` (`:277`); fonts `displayFont` `:287`, `monoFont` `:299`. `LooperTheme` (`looper_theme.dart:66`) holds only track-grid and waveform tokens; settings pages do not use it | — |

## 5. l10n keys (`lib/l10n/arb/app_en.arb`)

| Group | Keys (arb line) | Used by |
|---|---|---|
| Stay | `midiLostToastTitle` 97, `midiLostToastBody` 101, `midiReconnectedSnackbar` 1115 | `app.dart:1133,1134,1144` |
| Already unused | `midiInputGroup` 1075, `midiNoDevicesFound` 1076, `midiNone` 1077, `midiDeviceNotFound` 1078, `midiRequiredCcsHint` 1112, `midiActivityActive` 1113, `midiActivityIdle` 1114 | nothing |
| Tray MIDI tab only | `midiStatusNone` 1086, `midiStatusConnecting` 1087, `midiStatusConnected` 1088, `midiStatusDeviceGone` 1096, `midiStatusOpenFailed` 1104 | `midi_tray_body.dart:313-329`; could be reused for device status |
| Tray MIDI tab only | `midiDeviceGroup` 2319, `midiDeviceRow` 2323, `midiDeviceNone` 2327, `midiStatusWaiting` 2331, `midiStatusReceiving` 2335, `midiDeviceUnplugged` 2400 | device and status cards |
| Tray MIDI tab only | `midiSimulate` 1696, `midiSimulateGlobal` 1700, `midiTransportMap` 2339, `midiActionRecord…midiActionCancelArm` 2348-2384 (10 keys), `midiStateSweep` 2388, `midiStateSwitch` 2392, `midiMappingsEmpty` 2396, `controlMidiTab` 2240 | Remove (`controlPedalTab` is used only by `control_tray_panel.dart:34`) |
| Both removed surfaces | `midiLearnGroup` 1685, `midiLearnHint` 1689, `midiLearnAddSweep` 1691, `midiLearnAddSwitch` 1692, `midiLearnRelearn` 1694, `midiLearnClear` 1695, `midiLearnCancel` 1704, `midiLearnListening` 1705, `midiLearnReplacePrompt` 1706, `midiLearnReplace` 1714, `midiLearnKeep` 1715, `midiLearnLo` 1716, `midiLearnHi` 1717, `midiLearnThreshold` 1718, `midiLearnBehavior` 1719, `midiLearnStale` 1720, `midiLearnStaleDetail` 1721, `midiLearnDeviceMissing` 1722, `a11yMidiLearnLo` 1782, `a11yMidiLearnHi` 1783, `a11yMidiLearnThreshold` 1784 | Remove |
| `midi_learn_section` only | `midiLearnEmpty` 1690, `midiLearnLearn` 1693, `a11yMidiLearnRow` 1770 | Remove |
| Via `binding_labels.dart` | `midiLearnCcControl` 1723, `midiLearnNoteControl` 1735, `midiLearnProgramControl` 5228 | Only through `controlLabel(MappingTrigger)` (`binding_labels.dart:110-126`), whose only `lib` callers are removed UI (`midi_learn_section.dart:181,437`; `midi_tray_body.dart:619,682,737`). A new `MidiSource` label would reuse these strings |
| Via `binding_labels.dart` | `midiLearnTargetVolume` 1746, `midiLearnTargetMaster` 1754, `midiLearnTargetParam` 1755 | Only through `valueTargetLabel` (`:71-86`), whose only `lib` callers are removed UI (`midi_learn_section.dart:121,292`; `midi_tray_body.dart:562,940`). Tests: `test/control/binding/binding_labels_test.dart` |
| Shared, keep | `pedalAssignToggle`, `pedalAssignMomentary`, `pedalAssignToggleHint`, `pedalAssignMomentaryHint` | Also used by `lib/pedal/view/pedal_assignment_page.dart:445-451` |

`bindingTargetLabel` (still used by `pedal_tray_body.dart` and `pedal_assignment_page.dart`) and `fxStageLabel` (used by `expression_catalogue.dart`) stay.

## 6. Screenshot / golden rigs

- **No suite renders two display sizes.** Every pen-canvas suite pumps 1920×1080 at device pixel ratio 1:
  - `external_pedal_screenshots_test.dart:132-136`
  - `audio_routing_screenshots_test.dart:117`
  - `fx_screenshots_test.dart:251`
  - `loop_settings_screenshots_test.dart:159`
  - `control_center_preview_test.dart:370-376`
  - `tracks_screenshots_test.dart:180`
- `settings_screenshots_test.dart:211` (legacy `SettingsPage`) uses 1980×1480.
- The 7" panel is the waveform/readout window (`lib/visualizer/performance_readout.dart:3`, `waveform_window.dart:245`). The handoff (`accepted-behavior.md` section 1 item 2) says the small display follows the selected track while settings are open on the main screen. Settings pages therefore have one pen size, and `LoopPenCanvas` scales it down (`loop_settings_frame.dart:24-32`).
- Test names don't match the requested pattern: pen-page suites are `*_screenshots_test.dart`. The only `*_preview_test.dart` is `control_center_preview_test.dart`, which covers the tray.

### Template to copy: `test/screenshots/external_pedal_screenshots_test.dart`
- **Tag and skip:** `@Tags(['screenshots'])` (`:1`); `fontDir` / `hasScreenshotFonts` (`:36-40`); each test has `skip: !hasScreenshotFonts` (e.g. `:237`). The tag is declared in `dart_test.yaml`.
- **Fonts:** loaded in `setUpAll` (`:42-63`) for Roboto, Inter, JetBrains Mono and `packages/lucide_icons_flutter/Lucide`, via `loadScreenshotFont` / `packageAssetPath` (`test/helpers/screenshot_fonts.dart:11-17,31-51`).
- **Mocks and cubit:** `LooperRepository` stubs (`:69-122`). A real `ControlCubit` over `PerformanceRepository(FakeAudioEngine)` and `PedalRepository(FakePedalTransport)` (`:138-156`), then `control.load()` (`:156`) and a setup seed (`:157-166`).
- **App shell:** `MaterialApp` with `ThemeData(fontFamily: SurfaceTheme.displayFont, extensions: [SurfaceTheme.dark, routingGraphThemeFromSurface(...)])` (`:168-179`). `MultiRepositoryProvider` (Looper + Pedal), `MultiBlocProvider` (control + tracks), and `home: const ExternalPedalPage()` directly, with no navigator push (`:180-194`).
- **Precache:** `pumpAndSettle`, then `tester.runAsync` with `precacheImage` for `ExternalPedalArt.artwork`, `ExpressionPositionPanel.asset`, and `fxModuleArt(...)` / `fxFootswitchAsset(...)` with `package: FxCatalogueLoader.package`, then `pumpAndSettle` (`:197-221`). The rationale comment is at `:198-200`: images decode off the fake clock.
- **Naming:** a `shot` helper writes `matchesGoldenFile('goldens/external_pedals_$name.png')` (`:224-227`). The 11 existing `external_pedals_*.png` goldens are in `test/screenshots/goldens/`.
- **Extra setup for a MIDI page:**
  - `MidiDeviceRepository` mock stubbing `connections`, `messages`, `activity`, `connection` and `select` (pattern at `control_face_test.dart:103-113` and `control_center_preview_test.dart:455-480`)
  - `ControlCubit(midiDevices: ...)` (constructor param `control_cubit.dart:196`)
  - `MidiSetupCubit` if the page reads connection or traffic
  - The old `controller:` and `simulatedSource:` params (`:195,197`) belong to the removed learn/simulate paths.
- **Non-golden widget-test harness to copy:** `test/control/external_pedal_page_test.dart:54-111`.