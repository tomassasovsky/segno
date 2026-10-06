# Settings as ten illustrated destinations; retire the settings tray and Bluetooth

<!-- cspell:words bluetoothd psplash RGBA BqolV rgoek kzxk -->

Tracking: #1199, `stage:plan`, `autonomy:merge-gate`, `area:console`. Covers
gap inventory E3-4 (Settings tiles), E3-5 (retire the tray and earlier surfaces)
and the parts of E3-9 (design-system debt) that this change touches.
Supersedes the direction of #494 ("fold Settings and Routing into the tray").
Base: `origin/claude/segno-integration` at `5c163d11f`. Every `file:line` below
is on that head unless a branch is named. USB storage P1 to P3 (#1177) are
merged into the local trunk at `56033baf0` but not yet pushed; they touch no
file this plan cites.

Owner decisions applied (2026-10-06): the settings tray and the Bluetooth page
are retired; DAW export is kept and re-homed under Library > Audio (#1178
Part 7, not here); computer-facing USB gadget mode is out of scope. Standing
rules 1 to 5 are cited by number where they decide something.

Design source: the 107 MB `segno-ui.pen`, group `01 CURRENT UX`, read through
the pencil MCP only:

- `05 Loop setup / 01 Settings` (frame `v7Ekz`, 1920 x 1080) is the screen
  Part 2 must match.
- `03 DESIGN SYSTEM / 02 Original Segno Settings artwork` (frame `BqolV`) holds
  the ten reusable `Segno menu · <name>` components (`EzLgq`, `w9CnWM`,
  `d4tCt`, `E6hyU`, `a295G`, `uG9xz`, `FOZvB`, `O1E4Q`, `zjaII`, `JHYbI`).
- The destination pages each tile will eventually open are sections 01
  (Effects), 05/02 (Loop settings), 08 (Pedals), 26 and 27 (MIDI), 21
  (Audio routing), 28 (Device), 29 (Network), 30 (Displays), 31 (Storage),
  33 (Updates), and the PARITY About screen `g5owAP`.
- The tray faces being retired are drawn only in `02 EARLIER APPLICATION`
  (`03 Control` `tPvC3`, `05 Tracks` `cUnCC`, `06 Audio` `l6clI4`, `07 Tuner`
  `ww2oc`, `08 Network` `e0cAH`, `09 System` `WzOcR`). No `01 CURRENT UX`
  screen draws a tray, a brightness capsule or a Bluetooth page.

## 1. Current state (verified)

### 1.1 Entry points

| Entry | Today | Code |
|---|---|---|
| Header Settings icon | opens the tray | `lib/looper/view/stage_top_bar.dart:69-79` |
| Foot Mixer and foot Fade "Settings" buttons | open the tray | `lib/looper/view/foot_mixer_view.dart:123`, `lib/looper/view/foot_fade_view.dart:135` |
| Tray pull handle | always pinned at the top edge | `lib/looper/view/settings_tray.dart:15-37`, `:218` (`_TrayHandle`) |
| `S` key, right-click on the stage, macOS menu `Cmd+,` | push the old `SettingsPage` | `lib/looper/view/tracks_commands.dart:245-247`, `lib/looper/view/tracks_view.dart:199`, `lib/app/view/app.dart:1084-1090` |
| Engine-stopped banner, audio-recovery toast | push the old `SettingsPage` on its View section, where no device control is shown | `lib/looper/view/tracks_chrome.dart:24`, `lib/app/view/app.dart:1004-1007` |
| Update toast "Update…" | pushes `SettingsPage` on Updates; `isSegnoUpdatesSettingsOpen` suppresses the toast | `lib/app/view/app.dart:1021`, `:1044`; `lib/app/segno_navigator.dart:207-218` |
| Device-lost banner "Open setup" | opens the tray on Audio > Device | `lib/looper/view/connectivity_banners.dart:76`; `lib/looper/cubit/settings_tray_cubit.dart:66-73` |

`SettingsTrayCubit` is created per stage (`tracks_view.dart:186-187`) and
`SettingsTray` is a `Stack` sibling of the stage (`tracks_view.dart:429`).

### 1.2 The tray

- Rail: `TrayRailEntry` = Effects (route), Control, Loop (route), Tracks,
  Audio, Tuner, Network, System, plus the brightness button pinned below
  (`lib/looper/view/tray/tray_navigation_rail.dart:23-64`, `:171-181`).
- Faces (`lib/looper/view/tray/tray_panel.dart:135-148`):
  - Control: tabs Pedal | Controllers (`lib/control/view/control_tray_panel.dart:28-46`).
    `PedalTrayBody` is the per-bank FX-mode pedal binding editor
    (`lib/control/view/pedal_tray_body.dart:17-33`, writes
    `ControlCubit.setGlobalBindings` at `:280`) plus an "Open setup" row
    (`:96-108`). `ControllersTrayBody` is one row that opens MIDI controls
    (`lib/control/view/controllers_tray_body.dart:25-38`).
  - Tracks: `NamesTracksTab` renames tracks (`lib/looper/view/tracks/tracks_tray_panel.dart:27-33`).
  - Audio: tabs Device | Recording (`lib/audio_setup/view/console/audio_tray_panel.dart:35-47`).
  - Tuner: `TunerTrayPanel`, a working detector that arms on mount and by
    design does not mute (`lib/tuner/view/tuner_tray_panel.dart:11-49`).
  - Network: tabs Wi-Fi | Bluetooth (`lib/network/network_tray_panel.dart:41-59`).
    The tray creates and loads `WifiCubit` and `BluetoothCubit` for the stage's
    lifetime (`settings_tray.dart:67-110`, `:162-166`).
  - System: tabs Display | Updates | Storage | About (`lib/system/view/system_tray_panel.dart:32-48`).
- Brightness: `BrightnessCapsule` in `TrayBrightnessPopover`
  (`lib/looper/view/tray/brightness_capsule.dart`, `tray_brightness_popover.dart:107-111`)
  over the app-wide `DisplayBrightnessCubit` (`lib/app/view/app.dart:476`).

### 1.3 The old `SettingsPage`

`lib/looper/view/settings_page.dart` is a left rail of View, Audio, Tracks and
Updates sections (`:22-34`) plus rows that push Loop, Routing, Effects, Pedals
and MIDI routes (`:303-339`). Content and where each item already lives
elsewhere:

| Item | Code | Also editable at |
|---|---|---|
| Waveform window, high contrast, refresh rate | `settings_page.dart:167-227` | tray System > Display (`lib/system/view/display_system_tab.dart:74-136`) |
| Boot default mode (Record or Mute) | `settings_page.dart:185-206`; applied at `lib/control/cubit/control_cubit.dart:1179-1205` | nowhere |
| Device, rate, buffer, latency, ASIO | `lib/audio_setup/view/audio_settings_section.dart` | tray Audio > Device (`lib/audio_setup/view/console/device_audio_tab.dart`) |
| Click level | `audio_settings_section.dart:108` (`ClickVolumeSection`) | nowhere on touch (the doc at `lib/audio_setup/view/click_volume_section.dart:11-17` says a fresh unit needs it) |
| Record offset text field (desktop) | `audio_settings_section.dart:274`, `:452-` | Device tab shows the measured offset read-only (`device_audio_tab.dart:428`) |
| Pedal section → `PedalAssignmentPage` → `PedalPlate` | `audio_settings_section.dart:112`, `lib/pedal/view/pedal_settings_section.dart`, `pedal_assignment_page.dart:244` | tray Control > Pedal (same `setGlobalBindings`) |
| Track names | `settings_page.dart:235-258` | track column and Mixer column names (`lib/looper/view/track_column.dart:538-546`, `lib/looper/view/mixer_column.dart:228-236`) |
| Updates | `lib/update/view/updates_settings_section.dart` | tray System > Updates (`lib/system/view/updates_system_tab.dart`) |

### 1.4 Tray Audio > Recording tab

`lib/audio_setup/view/console/recording_audio_tab.dart`: Maximum loop length
(`:72-99`), Quantize switch (`:104-121`), Rec/Dub (`:125-134`), Auto record
(`:138-161`), Default length as a loop multiple (`:166-203`). Rec/Dub and Auto
record are on Loop settings > Recording (`lib/looper/view/loop_settings/loop_recording_page.dart`);
quantize is Loop settings > Length & quantize, where "Immediately" is off
(`loop_length_page.dart:103-112`, `:303-304`; AB 2 item 3). Maximum loop length
(`AudioSetupCubit.setMaxLoopMinutes`, applied at engine start
`lib/app/audio_bootstrap.dart:153-155`) and the default multiple
(`le_engine_set_default_multiple`, `segno_engine_api.h:2262-2265`) have no
other control and no screen in `01 CURRENT UX`.

### 1.5 Bluetooth

- App: `lib/bluetooth/` (cubit, state, tray body, page),
  `packages/bluetooth_client` (system client shells out to `/usr/bin/segno-bt-ctl`,
  `system_bluetooth_client.dart:9-12`), `packages/bluetooth_repository`,
  wiring at `lib/app/run_segno.dart:153`, `:222`, `lib/app/view/app.dart:79-98`,
  `:449`, `pubspec.yaml:13-14`, `:74-75`.
- Image: `bluez5` in `deploy/yocto/meta-segno/recipes-core/images/segno-kiosk-image.bb:39`
  and `recipes-segno/segno-bundle/segno-bundle.bb:114`; helper `files/segno-bt-ctl`
  (power, discoverable, advertise, pair, connect, forget; `:1-20`); `segno-bt-persist`
  and its unit bind-mount `/data/bluetooth` over `/var/lib/bluetooth` before
  `bluetooth.service` so pairings survive OTA (`files/segno-bt-persist:1-55`,
  `segno-bundle.bb:44-49`, `:126`, `:138-141`, `:160`, `:253-256`, `:321-325`).
- Tests and CI: `test/run_bt_ctl_tests.sh`, `test/run_bt_persist_tests.sh`,
  `.github/workflows/main.yaml:453-456`; `bluetoothctl` in `.github/cspell.json:92`;
  `docs/PROGRESS.md:536-558`.
- The app has no Bluetooth profile of its own. What a paired device does
  today is whatever BlueZ gives it, most plausibly an HID keyboard reaching the
  app through weston. The app runs as root (`files/segno.service` has no
  `User=`), so it can read `/data/bluetooth`.
- `BluetoothPage` (`lib/bluetooth/bluetooth_page.dart`) and `WifiPage`
  (`lib/wifi/wifi_page.dart`) are already unreachable: their barrels
  (`lib/bluetooth/bluetooth.dart`, `lib/wifi/wifi.dart`) are imported by
  nothing, and `showBluetoothPage`/`showWifiPage` have no caller. They are the
  only users of `lib/appliance/host_page_chrome.dart`.

### 1.6 Existing destination routes

`lib/app/segno_navigator.dart` already pushes five of the ten destinations,
each with its own duplicate guard flag (`:40-46`, `:62-185`): `openFx`,
`openLoopSettings`, `openPedalSetup`, `openMidiControls`, `openAudioRouting`.
All five draw `LoopSettingsFrame` (`lib/looper/view/loop_settings/loop_settings_frame.dart:41-75`)
inside `LoopPenCanvas` (`:16-33`), pop to the stage with
`popUntil(isFirst)` (`loop_settings_page.dart:66`, `audio_routing_page.dart:69`,
`fx_page.dart:767`, `pedal_setup_page.dart:229`, `midi_controls_page.dart:175`),
and take an `onStage` callback whose only job is closing the tray.

The FX page already draws the pen's "Pedal assignments" button, wired to
nothing (`lib/looper/view/fx/fx_page.dart:786-794`).

## 2. Tile map

| # | Tile (pen node) | Opens now | Accepted page | Owner of the redesign |
|---|---|---|---|---|
| 1 | Effects (`teuMj`) | `openFx()` | section 01, 02 | built |
| 2 | Loop settings (`fzZjW`) | `openLoopSettings()` | 05/02 to 05/11 | built |
| 3 | Pedals (`Fmk9g`) | `openPedalSetup()` | section 08 | built |
| 4 | MIDI (`gVIpz`) | `openMidiControls()` | 26 (Controls) and 27 (Sync) | Controls built; the Sync tab is E8-5, which adds it to this page |
| 5 | Audio routing (`y920Og`) | `openAudioRouting()` | section 21 | built |
| 6 | Device (`G5wxu`) | interim Device page (Part 1) | 28 `Audio settings` `Q3YCDg` | E9-1, E9-2 |
| 7 | Network (`s6GvaD`) | interim Network page (Part 1) | 29 `Connected network` `wse91` | E9-9 |
| 8 | Displays (`s3ZUlc`) | interim Displays page (Part 1) | 30 `Display settings` `hrXyj` | E9-4 |
| 9 | Storage (`MwoCC`) | interim Storage page (Part 1) | 31 `Storage overview` `BQc2H` | #1177 Part 5 (replaces the body of `StorageSystemTab`, which the interim page hosts) |
| 10 | Updates (`IEbE8`) | interim Updates page (Part 1) | 33 `Installed software` `kGlWv`; About `g5owAP` | E9-7, E9-8 |

An interim page is the existing tray body moved into the shared
`LoopSettingsFrame`, with breadcrumb `SETTINGS / <name>`. It does not match its
pen section, and its redesign replaces the body without touching the tile or
the route.

## 3. Artwork

The art is already in the repository, so nothing needs exporting from the pen.
Each pen tile fills its 128 x 128 `settings-art` frame with
`docs/design/settings-art/<key>.png` (for example `uEmTh` →
`docs/design/settings-art/effects.png`); the DS components crop
`docs/design/settings-art/menu-atlas.png`. The ten per-tile files are 480 x 480
opaque RGBA on `#202735`, committed at `56410d148` on
`origin/docs/design-program-2026-09` and byte-identical to the untracked copies
in the main checkout:

| key | blob |
|---|---|
| effects | `ed59d5d7` |
| loop | `18d7ff90` |
| pedals | `152c7d67` |
| midi | `4e495dc3` |
| routing | `707e233c` |
| device | `ff14a2df` |
| network | `77baa317` |
| displays | `d1d72d5e` |
| storage | `acd5fe61` |
| updates | `aedef87f` |

Part 2 copies them with `git show 56410d148:docs/design/settings-art/<key>.png >
assets/settings/<key>.png` and registers `assets/settings/` in `pubspec.yaml`
(beside `:96-103`). No art is generated; `manifest.json` records these as the
owner-accepted Segno menu set. The atlas, `my-presets.png` and `rendered/` are
not shipped.

## 4. Decisions taken

D1. **Interim destinations are the existing tray bodies, not new designs.**
Rule 4 and AGENTS "grow in layers": each epic in the tile map replaces a body
later, and nothing here guesses at pen 28 to 33.

D2. **Click level moves to the interim Device page** as one row (`LoopSlider`
over `TempoCubit.setClickVolume`, double tap resets the default). It is the
only touch control for click level (§1.3), and the accepted home, the Mixer
"Backing & click" strip (E3-3, pen `Mixer · Backing & click / Tile`), is not
built. E3-3 deletes this row when its strip lands (rule 4).

D3. **Maximum loop length and the default loop multiple stay on the interim
Device page's Recording tab**, which keeps only those two rows; the Rec/Dub,
Auto record and Quantize duplicates are removed (rule 4, §1.4). Stored values
keep applying (rule 1). Their final home is question Q1.

D4. **The boot-default mode preference is retired.** The console starts in
Record mode, as AB 1.1 has normal startup open Tracks. An install that stored
`mute` gets one notice on its next start, "Segno now starts in Tracks. Press
Mode to switch to Mute.", and the key is removed (rule 3). The alternative is
question Q2.

D5. **The record-offset text field (desktop only) is retired.** The stored
offset keeps applying (rule 1); Measure on the Device page replaces it, as it
does on the appliance today.

D6. **The FX-mode pedal binding editor moves behind the FX page's Pedal
assignments button.** `PedalTrayBody` is the only editor of
`ControlCubit.globalBindings` once the tray goes (§1.2, §1.3). The button
already exists and does nothing (`fx_page.dart:786-794`); pen 04 `Pedal banks`
(`yF4kh`, crumb `EFFECTS / PEDAL ASSIGNMENTS`) puts this task there. E5-8
redesigns the body later. Its "Open setup" row is dropped, since the Pedals tile
opens the same route.

D7. **The tuner keeps the tray handle until the foot Tuner exists.** E6-7 (the
foot Tuner function, pen 23) has no issue yet. Part 5 removes every other tray
face, the rail and the brightness capsule, and the handle then opens the tuner
face directly. Part 6 deletes the tray once E6-7 ships its surface. This keeps
an existing feature reachable (rule 1) without inventing a Settings tile or a
header button the pen does not draw.

D8. **About is a row at the foot of the interim Updates page** opening
`AboutSystemTab` in the frame. AB 7.9 places About with Updates; the PARITY
About screen `g5owAP` has no entry point in `01 CURRENT UX`. E9-8 settles it.

D9. **Updates is always one of the ten tiles.** The old page hid Updates on
unsupported builds (`settings_page.dart:295-296`). The pen always draws ten,
and `UpdatesSystemTab` already shows an honest unsupported banner with no
action (`updates_system_tab.dart:136-145`).

D10. **The Settings Power button opens the existing shutdown flow.**
`05/01` draws Power in the title bar (`mGxF1`). It calls the same
`PowerOffCubit.press(powerOffSnapshotOf(...))` the rear button does
(`lib/appliance/power_off/power_off_host.dart:49-63`), shown only when
`isAppliance()` (`lib/update/appliance/appliance_env.dart:10`). Pen 32
`Power options` with Restart is E9-6.

D11. **Bluetooth retirement: remove the stack and drop the pairings with a
notice, but keep the pairing files for rollback** (rules 1, 2, 5).
- The OTA bundle carries app and image together, so the BT UI and BlueZ leave in the
  same release. Hand-staged app-only deploys onto an older image are a
  development path and are not handled.
- The image drops `bluez5`, `segno-bt-ctl`, `segno-bt-persist` and its unit.
  `bluetoothd` no longer runs, so nothing powers the controller, advertises, or
  reconnects a paired device. The image adds `PACKAGE_EXCLUDE += "bluez5"`, as it
  does for psplash (`segno-kiosk-image.bb`), so a hard dependency fails the
  build instead of silently pulling BlueZ back. If the build fails, the
  fallback is `DISTRO_FEATURES:remove = "bluetooth"` in `kas-segno-common.yml`.
- `/data/bluetooth` is left untouched. A RAUC fallback to the previous slot
  re-binds it and the pairings work again, which is the recovery path.
- On the first start with paired devices on record (a device directory under
  any adapter directory of `/data/bluetooth`), the app shows one toast:
  "Bluetooth is no longer supported. {count} paired devices will not
  reconnect." The acknowledgement is stored in `settings_repository` so the
  toast never repeats. This is a toast, not a banner, because there is
  nothing to act on (popup severity principle, #860).

D12. **No session schema change.** Nothing here is recalled with a session, so
#1196's migration chain is untouched.

## 5. Verified-unused deletion list

Each entry was checked with `grep -rn` over `lib test packages` on the base.
"Dead now" means unreachable on the base. "Dead after Pn" means the named part
removes its last caller.

| Path | Status | Deleted in |
|---|---|---|
| `lib/wifi/wifi_page.dart` (+ `test/wifi/wifi_page_test.dart`) | dead now: barrel unimported, `showWifiPage` has no caller | P3 |
| `lib/bluetooth/bluetooth_page.dart` (+ test) | dead now, same | P3 |
| `lib/appliance/host_page_chrome.dart` | used only by the two pages above | P3 |
| `lib/looper/view/signal_graph/signal_knob.dart` (+ test) | dead now: only its test constructs `SignalKnob` | P3 |
| `lib/looper/view/settings_page.dart` (+ `test/looper/view/settings_page_test.dart`, `looper.dart:18` export) | dead after P2 | P3 |
| `lib/audio_setup/view/audio_settings_section.dart` (+ test) | used only by `SettingsPage` | P3 |
| `lib/audio_setup/view/click_volume_section.dart` | used only by the above; replaced by D2's row | P3 |
| `lib/update/view/updates_settings_section.dart` (+ test) | used only by `SettingsPage` | P3 |
| `lib/pedal/view/pedal_settings_section.dart`, `pedal_assignment_page.dart`, `pedal_plate.dart` (+ tests; `lib/pedal/pedal.dart` keeps only the cubit export) | reachable only through the Audio section | P3 |
| `lib/setup/setup_surface.dart` (+ `test/setup/setup_surface_test.dart`) | imported only by files deleted in P3 | P3 |
| `SettingsSection`, `isSegnoUpdatesSettingsOpen`, `_onSettingsSectionChanged` (`segno_navigator.dart:187-248`) | dead after P2 | P3 |
| `ControlCubit.setDefaultMode`, `ControlState.defaultMode`, `InteractionMode.bootDefaults`/`bootDefaultFromToken`, `SettingsRepository.save/loadDefaultInteractionMode` | dead after D4 | P3 |
| `lib/bluetooth/` (cubit, state, tray body, barrel), `packages/bluetooth_client`, `packages/bluetooth_repository`, `createBluetoothClient` and the BT half of `SEGNO_FAKE_RADIOS` | retired by owner decision | P4 |
| `segno-bt-ctl`, `segno-bt-persist`, `segno-bt-persist.service`, `run_bt_ctl_tests.sh`, `run_bt_persist_tests.sh`, CI steps `main.yaml:453-456` | retired with the app side | P4 |
| `SettingsTrayCubit.openAudioDevice` | its one caller moves to the Device page in P1 | P1 |
| `lib/looper/view/tray/tray_navigation_rail.dart`, `brightness_capsule.dart`, `tray_brightness_popover.dart` | dead after P5 | P5 |
| `ControlTrayPanel`, `ControllersTrayBody`, `TracksTrayPanel`, `NamesTracksTab`, `tracks_face.dart`, `AudioTrayPanel`, `NetworkTrayPanel`, `SystemTrayPanel`, enums `ControlTab`, `NetworkTab`, `SystemTab` | dead after P5 | P5 |
| `lib/looper/view/settings_tray.dart`, `tray/tray_panel.dart`, `tray_metrics.dart`, `tray.dart`, `SettingsTrayCubit`/`State` | dead after P6 | P6 |
| `lib/session/view/sessions_manager_dialog.dart` | not here: #1178 Part 2 replaces it | #1178 |

Kept, though E3-5 listed them: `lib/looper/view/fx_editor/fx_block_chip.dart` is
imported by `track_column.dart:11`, `fx_effect_editor.dart:7`,
`fx_chain_strip.dart:6` and `fx_rack_editor.dart:8`.
`lib/looper/view/signal_graph/signal_style.dart` is imported by
`mixer_column.dart:18`, `control_value_readout.dart:6` and the chip.
`AudioRoutingCard` is used by `device_audio_tab.dart`. `AudioTab` survives as the
Device page's tab enum.

## 6. Removal order

```
P1 interim pages ─┬─> P2 Settings home ──> P3 retire SettingsPage + dead pages ─┐
                  └─> P4 retire Bluetooth (app + image) ─────────────────────────┼─> P5 tray → tuner drawer ──> P6 delete tray (needs E6-7)
                                                                                └─> P7 geometry tokens (after P3 and P5)
```

No point in the order leaves a reachable dead end or loses a control:

- After P1, every tray and old-page control is still reachable, and the device
  and update notices land on a page that can act on them (today the
  engine-stopped banner opens a View section with no device control).
- After P2, the old page is unreachable, but nothing on it is lost: D2 and D3
  moved its unique controls in P1, the boot default keeps applying until P3
  (rule 1), and the tray stays behind its handle.
- P4 removes the Bluetooth tab from the tray's Network face in the same
  change that stops BlueZ, so no release has BT running without its UI.
- P5 needs P2 (Effects and Loop leave the rail for tiles), P4 (no Bluetooth
  face left to host) and P1 (brightness lives on Displays). After P5 the handle
  reaches only the tuner (D7).
- P6 waits for E6-7.

## 7. Parts

### Part 1: interim Device, Network, Displays, Storage and Updates pages (about 520 production lines)

Files:
- `lib/settings/view/device_settings_page.dart`: frame, PillTabs Device |
  Recording from `audio_tray_panel.dart:35-47` without its own title, bodies
  `DeviceAudioTab` and a trimmed `RecordingAudioTab`, and the Click level row
  (D2).
- `lib/settings/view/network_settings_page.dart`: creates and loads a
  `WifiCubit` from the `WifiRepository` provider and hosts `WifiTrayBody`.
- `lib/settings/view/displays_settings_page.dart`: a Brightness row
  (`LoopSlider` over `DisplayBrightnessCubit.setBrightness`, range
  `kMinDisplayBrightness..1`, double tap → `kDefaultDisplayBrightness`,
  `lib/appliance/software_brightness.dart:7-12`), then `DisplaySystemTab`.
- `lib/settings/view/storage_settings_page.dart`: hosts `StorageSystemTab`.
- `lib/settings/view/updates_settings_page.dart`: hosts `UpdatesSystemTab`
  and the About row (D8); `about_settings_page.dart` hosts `AboutSystemTab`.
- `lib/app/segno_navigator.dart`: one `_pushOnce(name, builder)` guarded by a
  `Set<String>` replaces the seven flags (`:40-46`, `:187`, `:195-205`).
  `openDeviceSettings`, `openNetworkSettings`, `openDisplaySettings`,
  `openStorageSettings`, `openUpdateSettings`, `openAboutSettings`;
  `isUpdateSettingsOpen` replaces `isSegnoUpdatesSettingsOpen` (route name
  `segno/settings/updates`).
- Reroutes: `connectivity_banners.dart:76` and `tracks_chrome.dart:24` →
  `openDeviceSettings`; `app.dart:1004-1007` → `openDeviceSettings`;
  `app.dart:1021`, `:1044` → `isUpdateSettingsOpen` / `openUpdateSettings`.
  Delete `SettingsTrayCubit.openAudioDevice` (`settings_tray_cubit.dart:66-73`).
- `recording_audio_tab.dart`: delete the Quantize, Rec/Dub and Auto record
  rows (`:104-161`); this also changes the tray's Recording tab, which is
  intended (rule 4).
- l10n: `settingsDeviceTitle`, `settingsNetworkTitle`, `settingsDisplaysTitle`,
  `settingsStorageTitle`, `settingsUpdatesTitle`, their `SETTINGS / …` crumbs,
  `settingsAboutRow`, `settingsClickLevel`, `settingsBrightness` in
  `app_en.arb` (the template; `app_es.arb` is partial and optional).

Tests: one widget test file per page under `test/settings/view/`, plus a navigator
test (duplicate taps push once; Back returns; Stage pops to the first route),
and updates to `test/looper/view/connectivity_banners_test.dart`,
`test/app/view/app_test.dart` and `test/audio_setup/view/audio_faces_test.dart`.

```success-criteria
GOAL: Device, Network, Displays, Storage and Updates each open as a full-screen page in the shared Settings frame with the controls the tray already had, and every device or update notice lands on the page that can act on it.
SUCCESS CRITERIA:
- Each of openDeviceSettings, openNetworkSettings, openDisplaySettings, openStorageSettings and openUpdateSettings pushes exactly one route even when called twice in one frame; Back pops to the opener and Stage pops to the first route. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings test/app/segno_navigator_test.dart (new)
- Device page: tabs Device and Recording; Recording shows exactly two rows (Maximum loop length, Default length) and no Quantize, Rec/Dub or Auto record row; dragging Click level to 0.5 calls TempoCubit.setClickVolume(0.5) once on release, and a double tap restores the TempoCubit default. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings/view/device_settings_page_test.dart test/audio_setup/view/audio_faces_test.dart
- Displays page: the Brightness row reads DisplayBrightnessCubit.state, a drag to the left end sets 0.1, and a double tap sets 1.0; the waveform, high-contrast, refresh-rate and shortcut rows behave as in the tray (existing system_faces cases moved, not rewritten). | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings/view/displays_settings_page_test.dart test/system/view/system_faces_test.dart
- Network page: opening it calls WifiRepository status once and closing it closes its WifiCubit; with the unsupported client it shows the existing unsupported body. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings/view/network_settings_page_test.dart
- The device-lost banner action, the engine-stopped banner and the audio-recovery toast action each push segno/settings/device; the update toast action pushes segno/settings/updates, and the update toast is suppressed while that route is open. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/connectivity_banners_test.dart test/app/view/app_test.dart test/looper/view/tracks_view_test.dart
- openAudioDevice no longer exists. | verify: ! grep -rn "openAudioDevice" lib test
- Analyzer, Bloc lint, spelling and the root coverage floor hold. | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
- HARDWARE: on the appliance, the Displays slider dims and restores both panels; joining a saved network from the Network page works; pulling the interface shows the device-lost banner and Open setup lands on the Device page with the device chooser visible. | verify: manual on device
NON-GOALS:
- Redesigning any of the five pages to pens 28-33; the tile home (Part 2); deleting tray faces (Part 5).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 2: the Settings home with ten illustrated tiles (about 360 production lines; depends on Part 1)

Match `05 Loop setup / 01 Settings` (`v7Ekz`):
- Top bar from `LoopSettingsFrame`: Back `b1TQeR`, crumb `SETTINGS`, Stage
  `rgoek`.
- Title "Settings" with `titleLeft: 100` (`TWjgX` at x 100), and Power
  (`mGxF1`, 64 x 64, radius 7, stroke `#5f5f5f`) in the frame's `actions` slot
  (D10).
- Grid of 2 x 5 tiles, 325 x 244, radius 8, fill `#202735`, 1 px inner stroke
  `#556881`. Tile x is 100 + {0, 349, 698, 1046, 1395}; tile y is 272 and 540 in
  the frame's main-local coordinates (menu `v8v6EP` at (100, 120) plus tile y
  152 and 420; LoopSettingsFrame children are main-local).
- In each tile, the art at (98, 32), 128 x 128, and the name 32 px centred
  with its top at y 174, colour `#e7edf6`.
- Encoder focus is the existing amber outline (`e7kzxk`, `#f2bf70`, 3 px).
  Colours come from `SurfaceTheme` tokens, not literals
  (`test/theme/token_adoption_test.dart`).

Files:
- `assets/settings/*.png` (§3) and `pubspec.yaml`.
- `lib/settings/settings_destination.dart`: an enum of the ten destinations,
  each with its art path, label and open function. The tile order is the pen
  order.
- `lib/settings/view/settings_home_page.dart`: `_SettingsTile` is a
  `FocusableTapTarget` with a semantic label equal to the tile name.
- `lib/appliance/power_off/power_off_host.dart`: extract
  `requestPowerOff(BuildContext)` from `:49-63` and use it from both callers.
- `segno_navigator.dart`: `openSegnoSettings()` pushes the home on
  `segno/settings` and loses its `section` parameter. Callers:
  `stage_top_bar.dart:73`, `foot_mixer_view.dart:123`, `foot_fade_view.dart:135`,
  `tracks_commands.dart:246`, `tracks_view.dart:199` and `app.dart:1089`.
  The first three stop reading `SettingsTrayCubit`.
- Pass no `onStage` from the tiles; the routes already pop to the stage
  themselves (§1.6).
- l10n: `settingsHomeTitle`, `settingsTileLoop`, `settingsTileMidi`,
  `settingsPower`. Reuse `fxTitle`, `routingTitle`, `pedalSetupTitle` and Part
  1's titles.

Accessibility (the #198 slice for these surfaces): the tiles traverse in pen
order with arrow keys, Enter opens, and Back from a destination returns focus
to the tile that opened it. Each tile is a button whose label is its name.
Power is a button labelled "Power".

```success-criteria
GOAL: The header Settings icon, the foot Mixer and Fade Settings buttons, S, right-click and the macOS menu all open one Settings page that matches pen 05/01, whose ten tiles open the ten destinations.
SUCCESS CRITERIA:
- Tapping each tile pushes, in order, segno/fx, segno/loop-settings, segno/pedal-setup, segno/midi-controls, segno/audio-routing, segno/settings/device, segno/settings/network, segno/settings/displays, segno/settings/storage, segno/settings/updates; ten tiles exist with Updates present when UpdateCubit.state.supported is false. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings/view/settings_home_page_test.dart
- Geometry at 1920 x 1080: the first tile's rect is (100, 368, 325, 244) in screen coordinates, the tenth is (1495, 636, 325, 244), each art image is 128 x 128 at tile offset (98, 32), and the ten Image widgets resolve to assets/settings/<key>.png. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings/view/settings_home_page_test.dart
- The header icon (stage_settings), the foot Mixer and foot Fade Settings buttons, the S key, a secondary tap on the stage and the macOS menu item each push segno/settings; none of them opens the tray (the scrim stays at opacity 0). | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/tracks_view_test.dart test/app/view/app_test.dart
- Arrow-key traversal visits the tiles in pen order, Enter on Displays opens it, and Back returns focus to the Displays tile; every tile exposes a button semantics node labelled with its name. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings/view/settings_home_page_test.dart
- Power is absent when isAppliance() is false; with a fake appliance flag, tapping it calls PowerOffCubit.press with the snapshot the rear button would send (same PowerOffSnapshot value). | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings test/appliance
- The ten asset files are byte-identical to the design blobs. | verify: for k in effects loop pedals midi routing device network displays storage updates; do test "$(git hash-object assets/settings/$k.png)" = "$(git rev-parse 56410d148:docs/design/settings-art/$k.png)" || exit 1; done
- Screenshot golden for the home regenerated on the author's machine and compared against a TakeScreenshot of v7Ekz. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots/settings_screenshots_test.dart --update-goldens (author machine only) and eyeball
- Analyzer, Bloc lint and coverage floor hold. | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
- HARDWARE: on the appliance, the encoder or arrow keys move the amber focus across all ten tiles and Back returns it; Power runs the existing save-then-halt flow. | verify: manual on device
NON-GOALS:
- Restart in Power (E9-6); MIDI Sync tab (E8-5); deleting the old page (Part 3).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 3: retire the old SettingsPage and the dead earlier pages (about 90 production lines added, about 5,000 removed; depends on Part 2)

Delete the P3 rows of §5 and their tests. D4: `ControlCubit._restore`
(`control_cubit.dart:1179-1205`) stops reading a boot default and keeps the
initial Record mode. A one-shot
`SettingsRepository.takeRetiredDefaultInteractionMode()` returns the stored
token and removes the key (`settings_repository.dart:716-722`). When the
token was `mute`, `ControlState` carries `retiredBootMode` once, and `app.dart`
shows the toast. D5: no code beyond the deletion. Remove l10n keys whose only
readers were deleted (a script lists `l10n.<key>` readers before removal).
Update `test/theme/token_adoption_test.dart`'s path list.

```success-criteria
GOAL: The earlier Settings page, its sections and the already-unreachable Wi-Fi and Bluetooth pages are gone, and the one setting with no new home (boot default mode) is retired with a notice.
SUCCESS CRITERIA:
- No symbol from the P3 rows of the deletion list remains. | verify: ! grep -rnE "SettingsSection|class SettingsPage|AudioSettingsSection|ClickVolumeSection|UpdatesSettingsSection|PedalSettingsSection|PedalAssignmentPage|PedalPlate|SignalKnob|WifiPage|BluetoothPage|HostChromeBar|SetupToggleRow|isSegnoUpdatesSettingsOpen|bootDefaultFromToken|setDefaultMode" lib test packages
- Stored default mode "mute": the app starts in InteractionMode.record, shows the retirement toast once, and the key is gone afterwards; a second start shows nothing. Stored "record" or nothing: no toast. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control test/app/view/app_test.dart && (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A saved record offset still reaches the engine at boot (audio_bootstrap unchanged); a saved click volume still applies. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app/audio_bootstrap_test.dart
- Every removed ARB key has no reader, and every remaining l10n getter is generated. | verify: /Users/Tomas/development/flutter/bin/flutter gen-l10n && dart analyze --fatal-infos
- Bloc lint, coverage floor. | verify: bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
NON-GOALS:
- Tray faces (Part 5), Bluetooth services (Part 4), the Sessions dialog (#1178).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 4: retire Bluetooth in the app and the image (about 120 production lines added, about 2,000 removed; depends on Part 1)

App: delete `lib/bluetooth/`, both packages and their `pubspec.yaml` and
`run_segno.dart`/`app.dart` wiring. Remove the Bluetooth tab from
`NetworkTrayPanel` (`network_tray_panel.dart:45-59`; Wi-Fi becomes its only body
until Part 5 deletes the panel) and the `BluetoothCubit` from
`settings_tray.dart:68`, `:79-102`, `:165`. Remove `createBluetoothClient` from
the `SEGNO_FAKE_RADIOS` path and update `docs/PROGRESS.md:536-558`.
D11 notice:
- `ConsoleFactsClient.retiredBluetoothPairings()` returns the number of
  device directories (a MAC-shaped name holding an `info` file) under any
  adapter directory of `/data/bluetooth`. The unsupported client returns 0
  and the fake is settable.
- `SettingsRepository.load/saveBluetoothRetiredNoticeShown`.
- An app start check beside the update notice shows one toast
  (`AppToastId.bluetoothRetired`).

Image: delete the three helper files and their two test scripts. Remove
`bluez5` from `segno-kiosk-image.bb:39` and `segno-bundle.bb:114`, and the bt
entries at `segno-bundle.bb:44-49`, `:104`, `:126`, `:138-141`, `:160`, `:253-256`,
`:321-325`. Add `PACKAGE_EXCLUDE += "bluez5"` beside the psplash exclusion.
Delete the CI steps `main.yaml:453-456` and `bluetoothctl` from
`cspell.json:92` if no other reader remains.

```success-criteria
GOAL: No Bluetooth code, helper or BlueZ package ships; an install that had pairings is told once, and a fallback to the previous slot gets its pairings back.
SUCCESS CRITERIA:
- Fixture /data/bluetooth with adapter AA:BB:CC:DD:EE:FF holding device dirs 11:22:33:44:55:66/info and 22:33:44:55:66:77/info plus a cache/ dir: retiredBluetoothPairings() == 2; an empty dir or a missing dir == 0; an adapter dir with a device dir lacking info == 0. | verify: (cd packages/console_facts_client && /Users/Tomas/development/flutter/bin/flutter test)
- With count 2 and no acknowledgement the app shows one toast whose text contains "2", saves the acknowledgement, and on the next start shows nothing; with count 0 it shows nothing and saves nothing. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app/view/app_test.dart && (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test)
- No Bluetooth code or recipe line remains. | verify: ! grep -rniE "bluetooth_(client|repository)|BluetoothCubit|segno-bt-" lib test packages pubspec.yaml deploy/yocto .github/workflows && test "$(grep -rn bluez5 deploy/yocto | grep -vc PACKAGE_EXCLUDE)" -eq 0 && grep -q 'PACKAGE_EXCLUDE.*bluez5' deploy/yocto/meta-segno/recipes-core/images/segno-kiosk-image.bb
- Remaining appliance helper suites and bundle tests pass. | verify: for t in deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_*_tests.sh deploy/yocto/meta-segno/recipes-core/images/test/run_*_tests.sh; do bash "$t" || exit 1; done
- The tray's Network face shows only Wi-Fi with no tab strip. | verify: /Users/Tomas/development/flutter/bin/flutter test test/network
- Yocto build host (not CI): the image manifest lists no bluez5 package and the build does not trip PACKAGE_EXCLUDE. | verify: grep -c bluez5 tmp/deploy/images/*/segno-kiosk-image-*.manifest | grep -qx 0 (on the runner after kas build)
- HARDWARE: on a console with one paired device and Bluetooth advertising on, install the bundle over OTA. Expected: one toast naming 1 device; `pidof bluetoothd` empty; a phone scanning for 60 s at 1 m does not list Segno; `ls /data/bluetooth` unchanged. Then trigger a RAUC fallback to the other slot: the device reconnects. | verify: manual on device
NON-GOALS:
- Deleting /data/bluetooth; Bluetooth MIDI or audio; dtoverlay changes.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 5: retire the tray faces, rail and brightness capsule; the handle keeps only the tuner (about 180 production lines added, about 2,900 removed; depends on Parts 2 and 4)

- FX pedal assignments (D6): `lib/looper/view/fx/fx_pedal_assignments_page.dart`
  frames the body of `PedalTrayBody` (moved and renamed
  `FxPedalAssignmentsBody`, without `:96-108`) under crumb `EFFECTS / PEDAL
  ASSIGNMENTS`. `openFxPedalAssignments()` is wired to `fx_page.dart:789-794`.
- Delete the P5 rows of §5. `TrayPanel` (`tray_panel.dart:115-165`) keeps the
  sheet and shows `TunerTrayPanel` with no rail.
- `SettingsTrayCubit` keeps `dragTo`, `settleFromDrag`, `open`, `closeTray`
  and `toggle`. The state keeps only `dragProgress`.
- `SettingsTray` no longer creates `WifiCubit` (`settings_tray.dart:67-110`,
  `:162-166`).
- Device page tabs keep `AudioTab`.
- Pen write-back (memory rule: a shipped departure updates the pen). The owner,
  or an agent the owner authorizes to edit the pen, adds one
  `c/ Interim · Settings destinations` note to section 05 listing D2, D3, D6,
  D7 and D8 and the interim pages. Planning did not edit the pen.

```success-criteria
GOAL: The tray holds only the tuner; every former tray control is reachable from a Settings destination or the FX page, and brightness lives on Displays.
SUCCESS CRITERIA:
- FX page Pedal assignments pushes segno/fx/pedal-assignments; assigning bank B pedal 2 to a chain there writes the same PedalBindingSet as the tray did (existing control_face cases moved, oracle unchanged). | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/fx test/control/control_face_test.dart
- Tapping or dragging the handle opens the tuner face directly and arms TunerCubit; closing disarms it; no rail, brightness button or other face exists. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/settings_tray_test.dart test/tuner
- No symbol from the P5 rows of the deletion list remains. | verify: ! grep -rnE "TrayNavigationRail|TrayRailEntry|BrightnessCapsule|TrayBrightnessPopover|ControlTrayPanel|ControllersTrayBody|TracksTrayPanel|NamesTracksTab|AudioTrayPanel|NetworkTrayPanel|SystemTrayPanel|enum (ControlTab|NetworkTab|SystemTab)|SettingsTrayDestination" lib test
- Analyzer, Bloc lint, coverage floor; screenshot goldens regenerated on the author's machine (control_center_preview_test retired with the faces it draws). | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
- HARDWARE: on the appliance, pull the handle with a guitar on input 1: the tuner reads the string; brightness set on Displays survives a restart. | verify: manual on device
NON-GOALS:
- The foot Tuner (E6-7), the pen 04 Pedal banks redesign (E5-8).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 6: delete the tray (about 10 production lines added, about 800 removed; depends on Part 5 and E6-7)

E6-7 must provide the foot-entered Tuner surface (pen 23, AB 4 Tuner row) over
the app-wide `TunerCubit` (`app.dart:554`), taking `TunerTrayPanel`'s face or
replacing it. Then delete the P6 rows of §5, `tracks_view.dart:186-187` and
`:429`.

```success-criteria
GOAL: No settings tray exists; the tuner is reached only by its foot function.
SUCCESS CRITERIA:
- No tray symbol remains. | verify: ! grep -rnE "SettingsTray|TrayPanel|_TrayHandle|kTray" lib test
- The stage has no pull handle and no scrim; the E6-7 tuner tests still pass. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view/tracks_view_test.dart test/tuner
- Analyzer, Bloc lint, coverage floor. | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
NON-GOALS:
- Anything in E6-7 itself.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 7: E3-9 geometry tokens on the surviving surfaces (about 250 production lines; after Parts 3 and 5)

E3-9 is four issues. This part does the one that is still open work, on the
code that survives Parts 3 and 5:

- **#504 (geometry tokens).** Add the ten DS radius tokens (`radius-2`,
  `-7`, `-8`, `-9`, `-10`, `-11`, `-12`, `-14`, `-17`, `-pill`) and the
  recurring spacing clusters to `SurfaceTheme` and its high-contrast
  constructor. Sweep `BorderRadius.circular(<literal>)`: 156 call sites on the
  base, fewer after the deletions. The snaps #504 lists for files this plan
  deletes no longer apply. Every other value maps 1:1, so goldens may change
  only at sites snapped to a different radius, and each such diff is listed in
  the PR.
- **#768:** already resolved on the base. The duplicated mode pills
  (`ModeIndicator`, `_ModePill`) and `LooperTheme.fxColor` no longer exist
  (grep), and `token_adoption_test.dart:70` already rejects state washes. This
  part only cites that evidence in its PR; the issue can be closed by its
  owner.
- **#198:** the Settings slice is in Part 2.
- **#506 and #507** (DS component reconciliation and new components) are not
  done here. They are whole-app component inventories with their own plan
  stage and are unaffected by this change.

```success-criteria
GOAL: Radius on the console is drawn from named SurfaceTheme tokens, with goldens moving only where a radius was deliberately snapped.
SUCCESS CRITERIA:
- No numeric literal is passed to BorderRadius.circular in lib/. | verify: ! grep -rnE "BorderRadius\.circular\([0-9]" lib
- Both theme flavors define every token, and a test pins each token's value. | verify: /Users/Tomas/development/flutter/bin/flutter test test/theme
- Goldens regenerated on the author's machine differ only at the sites listed in the PR. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots --update-goldens (author machine) and git diff --stat test/screenshots/goldens
- Analyzer, Bloc lint, coverage floor. | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
NON-GOALS:
- #506, #507, #663 (pen geometry conformance of other surfaces).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

## 8. Native work

None. No part touches `packages/segno_engine`, so
`bash packages/segno_engine/src/test/run_native_tests.sh` only needs to stay
green as a regression check on each PR. The image change in Part 4 is
verified by the shell suites, the Yocto manifest and the device.

## 9. Hardware-only

- Part 1: brightness on both panels; Wi-Fi join from the page; device-lost
  banner to Device page.
- Part 2: encoder focus traversal and return; Power save-then-halt.
- Part 4: OTA over a paired, advertising console; phone scan; RAUC fallback
  restores pairing.
- Part 5: tuner via the handle with a real input; brightness persistence.

## 10. Questions for the owner (defaults taken; override on #1199)

Q1. **Maximum loop length and the default loop multiple have no screen in
`01 CURRENT UX`** (§1.4). Default taken (D3): they stay on the interim Device
page's Recording tab. Should they move into Device (memory sizing), into Loop
settings > Length & quantize, or should the default multiple be retired in
favour of the Length & quantize default?

Q2. **Boot default mode.** Default taken (D4): retired, with a one-time notice
for installs that stored Mute. The alternative is to keep it as a setting.
The pen draws no place for it.

## 11. Build record

### Part 1 (branch `claude/settings-1199-p1`, `179e72bb3`)

Built as planned, with these departures:

- **D2 needed no new row.** The Device tab already carries the click level:
  `DeviceAudioTab` includes `AudioRoutingCard`
  (`lib/audio_setup/view/console/audio_routing_card.dart`), whose
  `ConsoleValueBar` writes `TempoCubit.setClickVolume`. The Device page hosts
  that tab unchanged. E3-3 still removes the bar when the Mixer strip lands.
- **Brightness is a `ConsoleValueBar`, not a `LoopSlider`.** It sits in the
  tray bodies' card style, beside the click bar it matches, with
  `resetValue: kDefaultDisplayBrightness` for the double tap and the
  existing `trayBrightnessPercent` readout. The cubit's floor (0.1) clamps a
  drag to the left end. The tray popover and the page share one helper,
  `editDisplayBrightness` (`lib/appliance/display_brightness_edit.dart`), so
  the save-failure toast is defined once.
- **Interim bodies sit on a card-toned panel** (`SettingsDestinationPage`).
  The tray bodies' pinned captions paint `SurfaceTheme.card`; on the page
  background each caption would draw a band.
- The Network page owns its `WifiCubit`. The body loads and scans on mount,
  so the radio is read only while the page is open (the tray read it for the
  stage's whole lifetime).
- About opens as its own route, `segno/settings/about`.
- `openUpdateSettings` dismisses the update toast itself. The audio-recovery
  toast keeps its "Settings…" label and now opens Device.
- Goldens: `control_center_audio_recording.png` and
  `control_center_audio_max_loop.png` regenerated (the three rows left); five
  new `settings_<page>.png` goldens, all checked by eye.

### Part 2 (branch `claude/settings-1199-p2`, `86bedb152`, on Part 1)

Built as planned, with these departures:

- **Tile fill is a new token, `SurfaceTheme.menuArtGround` (#202735 in both
  flavours).** The ten pictures are opaque on that colour; on `cardHigh`
  each would show as a lighter square. The pen's tile stroke (#556881) has no
  token, so the border is `borderStrong`, painted in front (the pen strokes
  inside, and a decoration border would inset the art by 1 px).
- Encoder focus uses `surface.warning`, as the pedal setup map does.
- The title reuses `stageSettings` ("Settings") and the crumb reuses
  `loopSettingsCrumb`. New strings: `settingsMidiTitle`, `settingsPower`.
- Power shows only when `isAppliance()`. `SettingsHomePage.powerAvailable`
  overrides that for tests. `requestPowerOff` and
  `currentPowerOffSnapshot` are extracted from `PowerOffHost`, so the
  button and the rear key send the same snapshot.
- The art ships as the ten PNGs, byte-identical to `56410d148` (1.3 MB), not
  re-encoded.
- `openSegnoSettings` lost its `section` parameter. The old `SettingsPage` is
  unreachable from here until Part 3 deletes it.
- New golden `settings_home.png`, checked by eye against `v7Ekz`.

### Pen write-back list (for the owner; this build did not edit the pen)

- Section 05: a `c/ Interim · Settings destinations` note listing the five
  interim pages and what each hosts (Device: Device and Recording tabs with
  the click bar; Displays: brightness bar first; Updates: About row).
- `01 Settings`: tile fill mapped to `menuArtGround`, stroke to
  `borderStrong`, focus to `warning`.
