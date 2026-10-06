# Device and appliance pages: Device, interface loss, Displays, Power, Updates, Network, About

<!-- cspell:ignore dpwx yyqr Ulrb orpd pbdiy OZOP JEHXY Cksr Xyzrn devicetree EDID edid setvcp Licences -->

Tracking: #1270, `stage:plan`. This plan covers the Device, Network, Displays and Updates
tiles of the Settings home, the About page and the Power button. They replace the interim
pages that `docs/plan/2026-10-06-feat-settings-destinations-plan.md` (#1199) put under
`lib/settings/view` (that plan's §2 tile map, rows 6, 7, 8 and 10).

Base: `origin/claude/segno-integration` at `c4b5cf909`. File and line references are to
that tree.

Pen sources (`segno-ui.pen`, group `p0dpwx` "01 CURRENT UX"):

| Section | Frame | Status in the pen |
|---|---|---|
| 28 Audio device & recovery | `yeG6A` | "Revised proposal" (not Accepted) |
| 29 Wi-Fi | `p33ymC` | Accepted |
| 30 Displays | `OdZ7n` | Accepted |
| 32 Power | `Z4KAJ` | Accepted |
| 33 Updates | `b0n5kk` | Accepted |
| PARITY REVIEW / About, controller and MIDI sync | `nBA56` | parity review; About, notices and Controller screens only |

None of these frames has a `c/` rationale note. The written rationale is in the design
docs in the main checkout:

- `docs/design/2026-09-07-audio-device-ux.md` (status: "Awaiting explicit acceptance").
- `docs/design/2026-09-07-display-settings-ux.md` (owner accepted 2026-09-07).
- `docs/design/2026-09-08-appliance-parity-correction.md`.

Engine numbers (ledger): commands 140–143 and perf-log facts 356–359. This plan uses 140
and 141. 142, 143 and the facts 356–359 go back to the ledger, because nothing here
changes recorded material.

Standing owner decisions that apply:

- The settings tray is retired (#1199 Parts 5–6).
- Computer-facing USB gadget mode is out of scope.
- Every Session schema bump adds a #1196 migration step. Nothing in this plan bumps the
  Session schema: every setting here is appliance state, which session recall and New
  loop do not touch.

## 1. Current state (verified)

### Interim pages and the tray

- `SettingsDestination.open()` (`lib/settings/settings_destination.dart:61-72`) maps
  Device, Network, Displays and Updates to interim pages. Those pages host tray bodies:
  - `DeviceSettingsPage` (`lib/settings/view/device_settings_page.dart:15-62`):
    `PillTabs<AudioTab>` over `DeviceAudioTab` and `RecordingAudioTab`.
  - `NetworkSettingsPage` (`network_settings_page.dart:13-31`): `WifiTrayBody`.
  - `DisplaysSettingsPage` (`displays_settings_page.dart:17-32`): one
    `DisplayBrightnessRow` (42-119) plus `DisplaySystemTab`.
  - `UpdatesSettingsPage` (`updates_settings_page.dart:16-45`): `UpdatesSystemTab` plus
    an About row (31-37).
  - `AboutSettingsPage` (`about_settings_page.dart:8-17`): `AboutSystemTab`.
- The tray mounts the same bodies: `AudioTrayPanel` (`lib/looper/view/tray/tray_panel.dart:141`),
  `SystemTrayPanel` and `NetworkTrayPanel`. #1199 Part 5 deletes those faces, the
  Recording tab and `AudioTab`. Every page part below that deletes a tray body
  therefore depends on #1199 Part 5.
- Routes: `lib/app/segno_navigator.dart`. `openDeviceSettings` (179) is also called from
  `connectivity_banners.dart:75`, `tracks_chrome.dart:24` and `app.dart:1040`.

### Device and latency

- **Every Device chip applies at once and clears the loops.**
  - `setSampleRate` (`lib/audio_setup/cubit/audio_setup_cubit.dart:142`),
    `setBufferFrames` (151) and `setDevice` (229-244) call `_persistAndApply` (273-382).
  - `_persistAndApply` saves first (274), then calls `stopEngine()` and
    `startEngine(_engineConfig())` (295-298).
  - `le_engine_start` clears all recorded material
    (`packages/segno_engine/src/core/segno_engine_api.h:1646-1649`).
  - There is no draft, no confirmation and no capture guard. `GuardKind.deviceChange`
    (`packages/operation_guards/lib/src/guard_registry.dart:24`) is never entered.
- **A refused configuration comes back at boot.** The config is saved before the open,
  so a refused request stays on disk (274) while the screen shows the live values
  (299-329).
- **`le_engine_reopen` (`segno_engine_api.h:1665-1697`, #1140) keeps the material.** It
  keeps loops, history and Fade, and brings tracks back STOPPED. It still clears the
  whole engine when the sample rate or the loop cap changes (`LE_REOPEN_CLEARED_RATE`,
  `_CAP`). The repository reaches it only from the private `_reopenEngine`
  (`packages/looper_repository/lib/src/looper_repository.dart:2454-2492`).
- **The latency test is loud and plays on every output.**
  - `LE_CMD_MEASURE_LATENCY` (`engine_process.c:2788-2805`) starts a 10 ms, 1 kHz burst
    at amplitude 0.9 (`engine_core.h:34-38`).
  - The pulse block (`engine_process.c:5520-5565`) writes it to every output channel.
  - It reads the return from the loopback channels when `excluded_input_mask != 0`,
    otherwise from the maximum of all real inputs (5482-5493, 5525).
  - `le_latency_resolve` (4099-4139) cross-correlates and writes `a_record_offset`.
  - No API selects an output, an input or a level.
- **The app measures without asking.**
  - At boot (`lib/app/audio_bootstrap.dart:289-301`) and after every apply
    (`_autoMeasureIfLoopback`, `audio_setup_cubit.dart:415-420`), the app measures
    whenever a loopback is detected. On the appliance, the Scarlett loop channels set
    `excluded_input_mask`, so this sends the 0.9 burst to every output.
  - `measureLatency()` (478) does not wait for or evaluate the result.
  - Offsets persist per device|rate|buffer (`_syncLatencyPersistence`, 592-625;
    `SettingsRepository.loadLatencyOffsetFrames` 365, `saveLatencyOffsetFrames` 383).
- **Rate and buffer choices are fixed lists** (`audio_setup_state.dart:235-238`).
  `le_device_info` (`segno_engine_api.h:609-630`) carries rate arrays only for ASIO, and
  ASIO enumeration always returns 0 (1462).
- **Health counters have no UI.** `EngineStatus.xrunCount`
  (`packages/looper_repository/lib/src/models/engine_status.dart:73`) is shown nowhere.

### Interface loss

- The Stage shows a persistent red `_LostBanner` with "Open setup"
  (`lib/looper/view/connectivity_banners.dart:48-106`). This was the 2026-08-26 owner
  decision (`c/device-lost` in "02 EARLIER APPLICATION").
- The supervisor reopens automatically when the pinned device returns:
  `_superviseDevice` (`looper_repository.dart:2113-2120`), `_attemptReconnect`
  (2170-2201), `_reopenEngine`.
- At boot, `AudioRecoveryCubit` (`lib/looper/cubit/audio_recovery_cubit.dart:21-116`)
  starts the engine on the absent→present edge.

### Displays

- There is one brightness value: `DisplayBrightnessCubit`
  (`lib/appliance/display_brightness_cubit.dart:11-53`) and the key `ui.brightness`
  (`settings_repository.dart:698-708`).
- It is applied two ways:
  - In software, to the main window only: `SoftwareBrightness`
    (`lib/appliance/software_brightness.dart`, minimum 0.1, default 1.0), used at
    `lib/app/view/app.dart:1183`.
  - In hardware, through `segno-brightness-ctl`, which runs `ddcutil` VCP 0x10 against
    the first display it finds, with no display selector.
- There is no idle dimming. `weston.ini:6` sets `idle-time=0`.
- **Touch calibration is one matrix for one device.**
  - `segno-touch-ctl` stores one matrix at `/data/touch/calibration` and applies it to
    the first touchscreen it finds.
  - The measuring is done by `weston-touch-calibrator` (`weston.ini:124-126`).
  - `97-segno-touch-output.rules` binds `1a86:e5e3` to HDMI-A-2. On the bench unit the
    panels are crossed (memory: 7" on HDMI-A-1).
- The two app windows are pinned by app-id. The main window is on `HDMI-A-1`
  (`weston.ini:30-40`). The Track display window (`dev.aquiles.segno.waveform`,
  `lib/visualizer/waveform_window.dart`) is on `HDMI-A-2` (42-108).

### Power and updates

- **Power off.**
  - `PowerOffCubit` (`lib/appliance/power_off/power_off_cubit.dart:18-162`) has: `press`
    37, `keepPlaying` 50, `saveAndPowerOff` 57, `powerOffWithoutSaving` 74,
    `retryPowerOff` 80, `powerOffAnyway` 88 and `_halt` 127-157.
  - `powerOffGate` (`power_off_gate.dart:83-89`) refuses during a take.
  - There is no user Restart. `ApplianceEnv.reboot` (`lib/update/appliance/appliance_env.dart:41`)
    is reached only from the update flow.
- **The update restart skips the safety flow.** `UpdatesSystemTab._confirmRestart`
  (`lib/system/view/updates_system_tab.dart:262-272`) calls `UpdateCubit.applyAndRestart`,
  which calls `env.reboot()` directly. That bypasses the take refusal, the settings flush
  and the session save.
- **The update helper is network only.** `segno-update-ctl`
  (`deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-update-ctl`):
  - `do_install` (123-187) fetches the manifest, downloads the bundle to `/tmp`, checks
    sha256, runs `rauc install`, then writes the staged marker and the boot id (182-184).
  - `reboot` (239-252) passes the tryboot argument only when a marker is staged.
  - `do_reconcile_staged` (196-234) returns a reason (`tryboot-not-taken`).
    `AppliancePlatformBackend.stagedVersion` (`lib/update/appliance/appliance_platform_backend.dart:78-83`)
    drops that reason silently.
- **The boot health gate can commit a crash-looping build (#976, P0).**
  - `segno-mark-good` checks `is-active` and `NRestarts` on `segno.service`.
  - `segno.service` (`ExecStart=/usr/bin/segno-kiosk-launch`, `Restart=always`) runs a
    wrapper that stays up while the app dies under it.
  - #976 is labelled `stage:build`; its first listed option is an app readiness marker.

### Network and About

- **Wi-Fi.**
  - `WifiCubit` (`lib/wifi/wifi_cubit.dart:9-293`) has: `load`, `scan`, `connect` with
    retries, `cancelConnect`, `disconnect`, `forget` and `setEnabled`.
  - `WifiClient` (`packages/wifi_client/lib/src/wifi_client.dart:4-24`) runs
    `segno-wifi-ctl` per call (`system_wifi_client.dart:67`).
  - There is no connectivity check, no autoconnect control and no password change.
- **Console facts.**
  - `LocalConsoleFactsClient.facts()` returns `ConsoleFacts.unknown`
    (`packages/console_facts_client/lib/src/local_console_facts_client.dart:119`), so
    About shows no serial, no system image and no panel.
  - The controller's firmware is known only from HELLO (`PedalState.firmwareVersion`,
    `lib/pedal/cubit/pedal_state.dart:12`).
  - The boot-time SWD flasher (`recipes-segno/segno-console-board/files/segno-console-flash`)
    records nothing the app can read.

## 2. Decisions taken under the standing rules

Each item names the rule it follows.

- **D1. Apply reopens; it does not restart** (rules 1, 2).
  - Apply goes through a new public `LooperRepository.applyAudioConfig`, which stops the
    engine and calls `le_engine_reopen`.
  - A buffer change, or a device change at the same rate, keeps the loops (stopped). That
    matches the pen 28/04 copy "Your recordings stay intact."
  - The config is saved only after the open succeeds. A refused request leaves the
    previous config on disk and on screen. This fixes the refused-config-at-boot bug.
- **D2. While any track holds material, the sample-rate chips are unavailable**, with the
  reason "Clear the tracks to change the sample rate" (rules 2, 3). The engine would
  clear the loops (`LE_REOPEN_CLEARED_RATE`), and the pen's copy promises they stay.
  Resampling recorded material is open question Q3.
- **D3. Measurement never plays on an output nobody chose** (design doc §Latency; rule
  2).
  - Command 140 measures on exactly one output and one input (or the interface loopback
    channels), at -12 dBFS (amplitude 0.25).
  - Command 141 cancels.
  - The boot-time and apply-time automatic measurements are removed. A saved offset for
    the same device|rate|buffer is still restored at boot, so installs that already have
    one keep it (rule 1). Installs without one show "Not measured".
  - The automatic attempt (pen 28/02) inspects capabilities only. It completes without a
    cable only when the engine reports a loopback that sends nothing to a physical output
    (`LE_LOOPBACK_BACKEND`, `_MONITOR`, `_VIRTUAL`). The Scarlett loop channels are not
    treated as isolated until Q2 is answered. On the appliance, Measure therefore goes on
    to the cable dialog (pen 28/03).
- **D4. Interface loss keeps the #1140 take rules.** A take in progress is dropped,
  committed layers stay, and tracks come back stopped. The design doc's "finishes the
  available partial loop take" predates the binding #1140 decisions.
- **D5. Restart and Install and restart use the shutdown flow** (rule 4). Both go through
  the same `PowerOffCubit` path: take refusal, flush, session save, storage leases, then
  `reboot` instead of `powerOff`.
  - With an update staged, the Power card says "Segno 1.1.0 installs during the restart."
    The helper's `reboot` verb boots the staged slot whenever a marker is staged (rule 3).
- **D6. Power follows the accepted pen 32**, so a failed save offers only Stay on and
  Retry. `powerOffWithoutSaving` and `powerOffAnyway` are removed. Staying on keeps the
  audio and the work, and the physical switch remains available (rule 2). The existing
  take refusal stays (rule 1).
- **D7. #976 uses the readiness marker.**
  - After the first frame and the first engine-start attempt, the app writes
    `/run/segno/app-ready` containing the boot id and its own pid.
  - `segno-mark-good` commits only if the marker belongs to this boot and the same pid is
    alive at both ends of the window.
  - This is #976's first listed option, and the only one that observes the app itself.
- **D8. Update failures are visible.**
  - A rolled-back update shows a persistent notice on Updates, "Segno 1.1.0 did not
    start, so the console went back to 1.0.0", until it is dismissed.
  - An install interrupted by a crash or power loss shows pen 33 "Update paused" after
    the restart. The marker is `/data/segno/update-attempt` (rule 3).
- **D9. USB packages are RAUC bundles (`*.raucb`)**, read from the volume root and from
  `segno-updates/`.
  - The bundle is copied to `/data/segno/update-staging/` under a storage lease on the
    source volume, so Eject waits. RAUC verifies the copy, so the stick is not needed
    during the install.
  - Packages that are not newer are refused with their version, the same rule as the
    network path.
  - The pen's ".update" names are mockups; the write-back list records the extension.
- **D10. Brightness per display.**
  - The range is 20–100% and the default 80% (accepted doc).
  - An existing `ui.brightness` value migrates to both displays, clamped to 20% at the
    bottom (rule 1: same value where it is in range).
  - Hardware is used where `segno-brightness-ctl supported <connector>` says DDC/CI
    works; otherwise a software filter is applied to that display's window.
- **D11. Idle dimming.**
  - Dimmed means 30% of each display's set brightness, with a 10% floor.
  - Playing, backing playback, capture and performance recording keep both displays
    awake.
  - Touch, encoder, pedal and MIDI activity wake them. The touch that wakes a screen is
    consumed, so it does not press a control.
  - Neither display blanks. The default is Never (pen 30, and today's behaviour).
- **D12. Touch calibration runs in the app, with one matrix per output.**
  - Targets are drawn on the panel being calibrated. Calibrating the Track display draws
    the targets in the waveform window on the 7". The main display shows the instruction,
    the counter and Cancel, which the encoder can reach.
  - The fit is an affine least-squares fit composed with the current matrix, because
    Flutter sees coordinates the current matrix has already transformed.
  - Matrices are stored per output at `/data/touch/<connector>.matrix`.
  - The old single matrix migrates to the output its touchscreen is bound to now (rule 1).
  - `weston-touch-calibrator` remains as the service fallback (rule 2).
- **D13. Wi-Fi with one radio cannot hold the old link while it joins.** Pen 29/03 says
  "Your current connection stays available until this one is ready." NetworkManager
  drops the active link when a new one is activated on the same device. Instead, a
  failed join reactivates the previous connection, and the copy says "If this fails,
  Segno reconnects to The Studio" (rule 2).
- **D14. "Connected · No internet" checks on demand.**
  - A HEAD request to the configured update host (the same host the update check already
    contacts) runs only while the Network page is open, at most once per 30 s.
  - NetworkManager's periodic connectivity check is not enabled, so no new host or
    background traffic is added.
- **D15. About shows only facts that are read** (parity doc).
  - Serial comes from `/sys/firmware/devicetree/base/serial-number`, the system image
    from `/etc/segno/build-version`, and panel names from the EDID under
    `/sys/class/drm/*/edid`. These are file reads, with no fork (#806).
  - Controller firmware: HELLO when connected. Otherwise the flasher's new record
    `/data/segno/console-board/last-flashed`, labelled "Last flashed by this console".
    Otherwise "Not reported".
  - The Controller firmware page is the pen's Unsupported state. In-app RP2350 updating
    is not built (hardware gate, parity doc §176).
- **D16. Recovery from a disconnected or failing state never needs touch alone.**
  Encoder focus reaches Cancel, Reconnect audio, Stay on and Retry on every page here
  (rule 2).

## 3. Parts

Sizes count production lines; tests are extra.

```
P1 boot gate (#976)        independent
P2 native latency + caps   independent
P3 audio apply + measure   needs P2
P4 Device page             needs P3, #1199 P5
P5 interface loss          needs P4                (Q1)
P6 Power + Restart         independent
P7 Updates page            needs P6 (P1 recommended first)
P8 USB packages            needs P7, USB storage P5
P9 Displays brightness+dim needs #1199 P5
P10 touch calibration      needs P9
P11 Network                needs #1199 P5
P12 About + Controller     independent (P7 links to it)
```

### Part 1: boot health gate keyed on the app (#976) (about 120 lines; image and `lib/app`)

This part lands under #976 (`Closes #976`, `Refs #1270`).

- `lib/appliance/app_ready_marker.dart`:
  - After the first frame (`WidgetsBinding.instance.endOfFrame`) and after the first
    `startEngine` attempt has returned (success or refusal), the app writes
    `/run/segno/app-ready` once, containing `<boot_id> <pid>`.
  - The write is atomic: temp file plus rename.
  - It happens only when `isAppliance()` is true. A failed write is logged and ignored.
- `segno-mark-good`:
  - Wait up to `WAIT_SECS` for a marker whose boot id matches
    `/proc/sys/kernel/random/boot_id`.
  - Read its pid, wait `STABLE_SECS`, then require the same marker, the same pid and
    `/proc/<pid>` present.
  - The `is-active` and `NRestarts` checks stay as additional conditions.
  - Paths are overridable through `SEGNO_APP_READY_FILE` and `SEGNO_PROC_ROOT`, following
    the existing test pattern.
- `segno.service`: add `RuntimeDirectory=segno` so `/run/segno` exists.

```success-criteria
GOAL: A build whose app never renders, or that restarts during the window, is never committed.
SUCCESS CRITERIA:
- Marker for this boot and the same live pid at both ends of the window: commits (rauc mock called with "status mark-good booted"). | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_mark_good_tests.sh
- No marker within WAIT_SECS, a marker from another boot id, a pid that changes during the window, or a pid whose /proc entry is gone: exits 1 with no rauc call (four cases, wrapper reported active with NRestarts 0 in each, which is the #976 shape). | verify: same
- The app writes "<boot_id> <pid>" once, only on the appliance, after the first frame and the first start attempt; a write failure does not throw. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance/app_ready_marker_test.dart
- Analyzer and Bloc lint clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: install a bundle whose app exits at startup; after two boots the console is back on the previous slot with no SSH. Then install a good bundle; it is committed after the window. | verify: manual on device
```

### Part 2: native measurement path and device rates (about 260 lines; engine and bindings)

**Contract (`segno_engine_api.h`)**

```c
LE_CMD_MEASURE_LATENCY_PATH = 140, /* arg_i = output | (input << 16); input 0xFFFF =
                                    * the interface loopback channels; arg_f = amplitude */
LE_CMD_CANCEL_LATENCY = 141,
/* le_latency_state gains */ LE_LATENCY_CANCELLED = 4,
LE_EXPORT int32_t le_engine_measure_latency_path(le_engine*, int32_t output,
                                                 int32_t input, float amplitude);
LE_EXPORT int32_t le_engine_cancel_latency(le_engine*);
```

**Control side** (`le_engine_measure_latency_path`)

- Returns `LE_ERR_INVALID_ARG` when:
  - the output is not below the device's output count, or
  - the input is neither below the input count nor 0xFFFF, or
  - the input is 0xFFFF but `excluded_input_mask == 0`, or
  - the amplitude is outside (0, 0.5].
- 0.5 is the ceiling. The app sends 0.25.

**Audio side**

- Command 140 sets `lat_out`, `lat_in` and `lat_amp`.
- The pulse block writes the burst to `lat_out` only. Every other output is 0.0f while
  measuring.
- The return magnitude is `|in[lat_in]|`, or `loop_mag` for 0xFFFF.
- The command is ignored, and the state becomes CANCELLED, when any track is recording
  or overdubbing.
- Command 141, or `le_engine_mark_device_lost` during a measurement, clears
  `lat_active` and publishes CANCELLED. `a_record_offset` is left unchanged.
- `LE_CMD_MEASURE_LATENCY` (1) is untouched here. Part 3 removes its last caller and
  then deletes it.

**Device rates**

- `le_device_info` gets `sample_rates[]`/`sample_rate_count` filled for every backend
  from `ma_context_get_device_info` native formats, through a pure helper
  `le_rates_from_native`. The helper sorts, removes duplicates and treats rate 0 as
  "any", which is reported as count -1.
- Dart: `AudioDevice.sampleRates`, `AudioEngine.measureLatencyPath`, `cancelLatency`,
  `LatencyState.cancelled`, and the mock engine twins.
- After the header change: `dart run ffigen --config ffigen.yaml` and `dart format`.

```success-criteria
GOAL: The latency pulse plays on one chosen output at -12 dBFS, returns on one chosen input, and can be cancelled without changing the stored offset.
SUCCESS CRITERIA:
- 2 in / 2 out at 48000, path (output 1, input 0, 0.25), harness feeds out ch1 back into in ch0 delayed 150 frames: out ch0 is exactly 0.0f for the whole window; out ch1 frame 1 equals 0.25f*sinf(2*pi*1000/48000) (0.0326...f, compared with the engine's own float expression); state DONE; record_offset_frames in [150, 152]; measured_latency_ms == 150*1000.0/48000 = 3.125 at best_lag 150. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Same path, the echo fed into in ch1 instead: state TIMEOUT, record offset unchanged from a prior LE_CMD_SET_RECORD_OFFSET of 77. | verify: same
- Input 0xFFFF with excluded mask 0x2 resolves from ch1 (the existing loopback oracle, RET 150); with mask 0 the call returns LE_ERR_INVALID_ARG and the state stays IDLE. | verify: same
- Output 2 on a 2-out device, input 5 on 2-in, amplitude 0 and 0.6: each returns LE_ERR_INVALID_ARG and posts nothing. | verify: same
- Cancel after 1000 frames: state CANCELLED, record offset still 77, every output sample after the cancel frame is 0.0f with no monitors enabled. Device lost mid-window: CANCELLED, offset 77. | verify: same
- Track 0 recording when 140 arrives: state CANCELLED, out ch1 never carries the burst, the take's captured PCM equals its input samples exactly. | verify: same
- le_rates_from_native on {48000, 44100, 96000, 48000} gives {44100, 48000, 96000}; on {0} gives count -1. | verify: same
- Dart wrappers and the mock: measureLatencyPath forwards (1, 0, 0.25); cancelLatency publishes cancelled. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/segno_engine
- ASAN suite and bindings regenerated with no format churn. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && git diff --stat packages/segno_engine/lib/src/generated
- HARDWARE: on the appliance with a cable from output 3 to input 2, the measured value differs from the previous broadcast measurement by under 0.5 ms, and nothing is heard on outputs 1-2. | verify: manual on device
```

### Part 3: apply through reopen; explicit measurement (about 600 lines; `looper_repository` and `lib/audio_setup`)

**Repository**

- `applyAudioConfig(AudioConfig) -> Future<AudioApplyResult>` makes the existing
  `_reopenEngine` path public. It stops, reopens, replays the rig and returns the outcome
  plus the negotiated values. A cold engine falls back to `startEngine`.
- `measureLatency({required int output, required int input}) -> Future<LatencyResult>`
  posts command 140 and completes on the first snapshot with DONE, TIMEOUT or CANCELLED,
  bounded at 2 s.
- `cancelLatency()`.
- `loopbackIsolated` returns true only for the kinds in D3.

**`AudioSetupCubit`** (all methods return void, for Bloc lint)

- Draft state: `AudioDraft {deviceId, sampleRate, bufferFrames}`, with `editRate`,
  `editBuffer`, `editDevice` and `discardDraft`.
- `apply()`:
  - enters `GuardKind.deviceChange`, which is refused under capture with "Finish
    recording first";
  - goes to `ApplyPhase.confirming` when transport or backing is running;
  - `confirmApply()` stops transport, then calls `applyAudioConfig`;
  - persists only on success (D1);
  - on failure keeps the prior config and playing state, sets `ApplyPhase.failed`, and
    exposes Retry.
- Rate availability: `rateLocked` is true while `LooperState` reports any track with
  material (D2).
- Capabilities: the chips show the device's rates from the canonical list
  [44100, 48000, 88200, 96000]. When the device reports "any", or the rates are unknown,
  the chips are 44.1, 48 and 96. Buffers stay 64–512.
- Measurement: `MeasurePhase {idle, automatic, cable, running, done, noReturn, cancelled}`.
  - `measure()` runs the capability check (D3), then goes to `done` or to `cable`.
  - `startCableTest(output, input)` and `cancelMeasure()`; leaving the page also cancels.
  - A result is saved under the existing device|rate|buffer key. noReturn keeps the
    previous value.
- Removed: `_autoMeasureIfLoopback`, the auto-measure branch in
  `lib/app/audio_bootstrap.dart:289-301` (the restore stays), `measureLatency()` and the
  immediate-apply setters once Part 4 drops their last caller.
- Native: delete `LE_CMD_MEASURE_LATENCY` (1) and `le_engine_measure_latency`, and
  update `test_engine_core.c` to use the path call.

```success-criteria
GOAL: Device changes are a draft committed by Apply through reopen, saved only on success, guarded against capture, and latency is measured only on a path the user chose.
SUCCESS CRITERIA:
- Editing rate, buffer or device emits a draft and calls neither stopEngine nor startEngine nor applyAudioConfig. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup
- Apply while stopped calls applyAudioConfig once with the draft; on success saveAudioConfig is called after it, with the negotiated values. | verify: same
- Apply refused by the device: saveAudioConfig is never called, the state shows the previous config, ApplyPhase.failed, and the engine is reopened on the previous config. | verify: same
- Apply while a track is capturing: refused with GuardKind.capture as the blocker, nothing applied. | verify: same
- Apply while playing: confirming; confirmApply stops transport, then applies; cancel leaves playback untouched. | verify: same
- With material on track 2, editRate is ignored and rateLocked is true; with every track empty it edits. | verify: same
- Repository: applyAudioConfig on a started engine calls reopen (not start) and returns retained with tracks STOPPED; mock outcome clearedRate is reported, not hidden. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- measure() with a backend loopback ends done with the engine's value; with Scarlett-style excluded channels it ends in cable without posting command 140. Cable test: noReturn keeps the saved offset; cancel posts 141 and keeps it. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup
- Boot with a saved offset restores it and never measures; boot without one measures nothing. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app
- Command 1 and le_engine_measure_latency are gone. | verify: ! grep -rn "LE_CMD_MEASURE_LATENCY\b\|le_engine_measure_latency\b" packages/segno_engine/src packages/segno_engine/lib && bash packages/segno_engine/src/test/run_native_tests.sh
- Analyzer, Bloc lint. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: with loops playing on the appliance, change the buffer 128 to 256 and apply; loops stop, are still there, and play at the same pitch; a USB stick device swap at 48 kHz keeps them too. | verify: manual on device
```

### Part 4: Device page (about 650 lines; `lib/audio_setup/view`, `lib/settings/view`)

Pen 28: `Q3YCDg`/`hWDHw` (01 Audio settings), `NtHav`/`yyqrZ` (02), `viOWI`/`C2o3h` (03)
and `btTbs`/`jUlrb` (04).

**Page body**

- `DevicePage` replaces `DeviceSettingsPage`, which no longer has tabs (#1199 Part 5
  removes the Recording tab).
- Header (`device-connected`): the interface name, "N inputs · M outputs", a status pill
  (Connected / Disconnected / Ready to reconnect) and "Change interface". The latter
  opens the existing chooser as a dialog, and a choice there edits the draft.
- Left column:
  - Sample rate chips, with the D2 reason shown under them while locked.
  - Buffer chips with "Lower latency" / "More headroom" labels.
  - The period readout: `buffer / rate` in ms with two decimals, labelled "per buffer".
- Right column:
  - "Round-trip latency", the value or "Not measured", and the note ("Measure to align
    new recordings." / "Apply audio settings before measuring.").
  - Measure, disabled while a draft is pending.
  - Health rows: "Audio dropouts" (`xrunCount` since the last open) and "Audio engine"
    (Running / Stopped / Offline).
- Apply row: "Changes apply together. Your recordings stay intact.", Cancel and Apply.
  It is shown only while the draft differs.

**Dialogs**

- "Apply audio settings?" with "Stop audio and apply".
- "Measure latency": the automatic progress dialog, then the cable dialog with output
  and input port pickers (the encoder steps through them) and Start test.
- Results and the no-return message ("No pulse came back. Check the cable and the input
  gain."), with Retry.

**Removed**

- `DeviceAudioTab`, apart from pieces moved elsewhere.
- The inert ASIO group.
- The loopback note.
- `MaxLoopLengthCard` and `AudioRoutingCard` stay as rows under the two columns.
  Max loop length has no other home; routing links to Audio routing.

```success-criteria
GOAL: Settings > Device matches pen 28 screens 01-04 and drives Part 3's draft, apply and measurement.
SUCCESS CRITERIA:
- Tapping 256 shows the Apply row and period 5.33 ms (48 kHz) without calling apply; Cancel restores 128 and hides the row. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup/view test/settings
- Apply while playing shows "Apply audio settings?"; "Stop audio and apply" calls confirmApply; encoder focus starts on Cancel. | verify: same
- Measure shows the automatic dialog, then the cable dialog with Output 1 and Input 1; changing ports with the encoder and Start test calls startCableTest(output, input); Cancel calls cancelMeasure. | verify: same
- Locked rate chips are disabled and announce the reason to a screen reader. | verify: same
- Health rows show the snapshot's xrun count and engine state. | verify: same
- DeviceAudioTab and AudioTab are gone; the device-lost banner, engine-stopped banner and recovery toast still open this page. | verify: ! grep -rn "DeviceAudioTab\|enum AudioTab" lib test && /Users/Tomas/development/flutter/bin/flutter test test/settings test/looper/view
- Goldens for screens 01, 02, 03 and 04 regenerated on the author's machine and compared against the pen. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots --update-goldens (author machine)
- Analyzer, Bloc lint, coverage. | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
- HARDWARE: on the 15.6" with the encoder only, change the buffer, apply, measure with a cable, and return to Stage. | verify: manual on device
```

### Part 5: interface loss and explicit reconnect (about 450 lines; repository, Device page, Stage)

Pen 28: `i1uSR`/`kfd3i` (05), `orpdZ`/`i8LwPO` (06) and `LGQmc`/`pbdiy` (07). This part
follows the drawn proposal; Q1 asks whether to keep it.

**Repository**

- After a loss on an engine that has run, the supervisor no longer reopens on its own.
  It moves to `AudioLink.waitingForDevice`, and to `AudioLink.readyToReconnect` when the
  pinned device is present again.
- `reconnectAudio()` calls `_reopenEngine` and returns the `EngineReopened` outcome.
- Boot-time `AudioRecoveryCubit` stays automatic: no material exists before the first
  open (rule 1).
- Another interface is never substituted.

**Device page**

- 05: pill "Disconnected"; health "—" / "Offline"; Apply row "Not connected" with
  "Reconnect audio", which is disabled until the device is present.
- 06: "Ready to reconnect"; "Reconnect audio when you are ready. Loops stay stopped."
- A measurement in progress is cancelled on loss (Part 2).

**Stage**

- The amber top-bar chip "Audio disconnected" (accessible name "Audio disconnected: open
  audio interface") replaces `_LostBanner`. It opens Device, and Back returns to the same
  Stage view.
- The `restoredCleared` banner and toast are unchanged.

```success-criteria
GOAL: After an interface loss nothing restarts audio until the musician presses Reconnect audio, and the Stage chip leads to the page that does it.
SUCCESS CRITERIA:
- Running engine, device lost, device returns: no reopen is called; status readyToReconnect. reconnectAudio() calls reopen once and returns retained with tracks stopped. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- Never-started boot with the pinned device appearing still starts automatically (AudioRecoveryCubit tests unchanged). | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/cubit/audio_recovery_cubit_test.dart
- Device page in waitingForDevice shows Disconnected with Reconnect audio disabled; in readyToReconnect enabled, and pressing it calls reconnectAudio. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup/view
- Stage shows the chip and no red banner while lost; activating it pushes segno/settings/device; Back restores the Stage selection. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Analyzer, Bloc lint. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: pull the Scarlett USB cable mid-loop; the chip appears; replug; nothing is heard (monitoring included) until Reconnect audio; then loops are present and stopped. | verify: manual on device
```

### Part 6: Power options and Restart (about 450 lines; `lib/appliance/power_off`, `lib/update`)

Pen 32: `QWWba`/`z3tkX` (Power options), `xD6Px`/`tUqCV` (Saving), `tBAZf`/`MFCYv`
(Save failed), `Cu7cd`/`DHsYQ` (Safe to switch off) and `iR4p7`/`V7XVe` (Restarting).

**`PowerOffCubit`** becomes `PowerCubit`; the file is renamed, with a re-export for one
release of callers.

- `press()` opens Power options. The card shows "Playback will stop and your session
  will be saved.", the session name, and Cancel / Restart / Shut down.
- `restart()` and `shutDown()` share `_halt(PowerAction)`. It enters `GuardKind.restart`
  (refused under capture, with the existing refuse body), then stops transport, flushes
  settings, saves the session and waits for storage leases. Finally it calls
  `env.reboot()` or `env.powerOff()`.
- Save failure: "Segno is staying on", with Stay on and Retry (D6).
- Terminal faces: "Safe to switch off" and "Restarting".
- Staged update: the card adds the D5 line.

**Updates**

- `UpdatesSystemTab._confirmRestart` and `UpdateCubit.applyAndRestart` call
  `PowerCubit.restart()`. `applyAndRestart` no longer calls `env.reboot()` itself.

```success-criteria
GOAL: Restart exists, and every restart (user or update) saves first through one guarded path.
SUCCESS CRITERIA:
- Restart: transport stopped, flush, session save, then env.reboot exactly once; Shut down: same order then env.powerOff. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance/power_off
- Save failure: phase saveFailed, neither reboot nor powerOff called; Retry repeats the save; Stay on returns to idle with audio running. | verify: same
- Restart during a take: refused with the take reason; no save, no reboot. | verify: same
- With a storage lease held, reboot waits until it is released (fake StorageRepository). | verify: same
- Staged update: the card shows "Segno 1.1.0 installs during the restart."; without one it does not. | verify: same
- Install and restart on Updates calls PowerCubit.restart and never env.reboot directly. | verify: /Users/Tomas/development/flutter/bin/flutter test test/update test/system
- powerOffWithoutSaving and powerOffAnyway are gone. | verify: ! grep -rn "powerOffWithoutSaving\|powerOffAnyway" lib test
- Goldens for the five pen 32 screens. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots --update-goldens (author machine)
- Analyzer, Bloc lint. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: Restart from Settings with a saved session reboots and reopens the session stopped; with an update staged, it boots the new slot. | verify: manual on device
```

### Part 7: Updates page (about 550 lines; helper, `lib/update`, `lib/settings/view`)

Pen 33: `kGlWv`/`T1igr`, `rWqZT`/`rHa2d`, `d4elG`/`tn7CZ`, `w4f0uG`/`g6y2R` and
`Fv2zf`/`ic1C5`.

**Helper**

- `do_install` writes `/data/segno/update-attempt` (the version) before the download and
  removes it after the marker is written or on any failure.
- A killed install is handled by `_on_terminate`, which leaves the marker for D8.
- New verb `attempt`, which prints `{"version":..}` or `{}`.
- `reconcile-staged` is unchanged; the backend now passes its `reason` through.

**Backend and cubit**

- `UpdateInfo.sizeBytes` comes from the manifest's `size` field when present (the
  release script adds it). Without it, the meta shows only the version.
- `UpdateCubit.cancelDownload()` sends SIGTERM to the helper process.
- `UpdatePhase.interrupted` (from the attempt marker at load) and the `rolledBack`
  notice (from the reconcile reason) are new.

**Page**

- "Installed Segno x.y.z" with "Load from USB" (Part 8; hidden until then) and "Check for
  updates".
- Panel states: Software updates / Update available / Downloading (bar and Cancel) /
  Ready to install ("Install and restart", which goes to Part 6) / Update paused (Retry,
  Cancel).
- The "Check automatically" toggle.
- The rollback notice (D8).
- The About and Controller links move here from the interim About row.

```success-criteria
GOAL: Settings > Updates matches pen 33, cancels downloads, and reports interrupted and rolled-back updates instead of hiding them.
SUCCESS CRITERIA:
- Helper: a successful install leaves no attempt marker; a curl failure removes it; SIGTERM during download leaves it and removes the work dir; `attempt` prints it. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_update_attempt_tests.sh
- Load with an attempt marker and nothing staged: phase interrupted with "Download interrupted. The current software is unchanged."; Retry starts a download. | verify: /Users/Tomas/development/flutter/bin/flutter test test/update
- reconcile reason tryboot-not-taken: a persistent notice naming the staged and installed versions until dismissed; reason already-running: none. | verify: same
- Cancel during download kills the helper and returns to available with nothing staged. | verify: same
- Page states match the five pen screens; encoder focus lands where the pen draws it. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings test/system
- New helper test suite wired into the CI shell-tests step. | verify: grep -n run_update_attempt_tests .github/workflows/main.yaml
- Analyzer, Bloc lint, goldens on the author machine. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: pull power during an online install; after boot the page shows Update paused on the old version; Retry completes and the update commits after Part 1's gate. | verify: manual on device
```

### Part 8: update from USB (about 420 lines; helper, `lib/update`)

Pen 33: `w3lUKE`/`xlAif` (Load a USB package). Depends on Part 7 and on USB storage
Parts 4–5 (`StorageRepository.volumes`, leases and the Eject guard).

**Helper**

- New verb `install-file <path>`:
  - Refuses a path outside `/data/segno/update-staging/`.
  - `rauc info --output-format=json` checks the signature and the compatible string, and
    reads the version.
  - Refuses a version that is not newer, with `{"error":"not-newer","version":..}`.
  - Refuses an unverified bundle with `{"error":"unverified"}`.
  - Otherwise runs the same fifo install, markers and progress as `do_install`. The
    shared part becomes `install_bundle`.
  - The staging copy is removed on exit.

**App**

- `UsbUpdateSource` lists `*.raucb` on each mounted volume (the root and `segno-updates/`)
  with Dart directory reads; there is no fork.
- Choosing a package:
  1. Acquire a lease on the source volume (purpose `update`).
  2. Copy the file to staging with `fsync`.
  3. Release the lease.
  4. Run `install-file`.
- Errors:
  - "This package could not be verified. Nothing was changed."
  - "Segno 0.9.0 is not newer than the installed 1.0.0."
  - "The USB drive was removed before the package was copied."
- Success lands in Ready to install (Part 7).

```success-criteria
GOAL: A signed bundle on a USB stick installs to the inactive slot exactly as an online update does; anything else is refused with nothing changed.
SUCCESS CRITERIA:
- install-file with a mock rauc reporting a newer version: same PROGRESS sequence and markers as install; staging emptied. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_update_file_tests.sh
- Not newer, signature failure, and a path outside staging: the JSON errors above, no markers, rauc install never called. | verify: same
- Listing finds a.raucb at the root and segno-updates/b.raucb, ignores c.txt. | verify: /Users/Tomas/development/flutter/bin/flutter test test/update
- Eject during the copy waits for the lease; volume loss during the copy shows the removed-drive message and leaves staging empty. | verify: same
- Analyzer, Bloc lint. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: a stick holding a signed release bundle and an edited copy of it: the first installs and commits after reboot; the second is refused as unverified. | verify: manual on device
```

### Part 9: Displays, brightness per display and idle dimming (about 650 lines; helper, `lib/appliance`, `lib/settings/view`)

Pen 30: `hrXyj`/`UXiWk` (Display settings), `a7zTq`/`cWuvA` (Disconnected display) and
`ppCdS`/`CXU4c` (Idle dimming).

**Identity**

- `DisplayRole {track, main}`. The role maps to a connector by reading the `[output]`
  `app-ids` pins in `/etc/xdg/weston/weston.ini`, which is a file read.
- Presence comes from `/sys/class/drm/card*-<connector>/status`.

**Helper**

- `segno-brightness-ctl supported|get|set` take `--connector <name>`. The connector maps
  to `ddcutil --bus N` through `/sys/class/drm/card*-<connector>/ddc`.
- Without the flag the old behaviour stays, for compatibility.

**Settings**

- Keys `ui.brightness.track` and `ui.brightness.main`, migrated from `ui.brightness`
  (D10).
- `ui.idle_dim_seconds`, with values 0, 120, 300 and 600.

**Cubits**

- `DisplayBrightnessCubit` holds `Map<DisplayRole, double>`.
- `IdleDimCubit` takes activity from:
  - the pointer router,
  - the encoder and pedal action streams,
  - MIDI input,
  - `LooperBloc` transport and capture, backing, and the performance recorder.

  It emits `dimmed`. While dimmed, the first pointer down is consumed.
- `SoftwareBrightness` is applied in both windows' roots (the waveform window through its
  channel).

**Page**

- Two cards, Track display first: preview, role, brightness slider (20–100%; double tap
  resets to 80%) and Calibrate touch (Part 10).
- Dim while idle: Never / 2 / 5 / 10 min.
- A disconnected display shows "Not connected" and disables Calibrate.
- The existing waveform window, high contrast, refresh rate and shortcut controls move
  to a "Display options" row below (Q4).

```success-criteria
GOAL: Each display has its own brightness, idle dimming follows the accepted rules, and the page matches pen 30's settings screens.
SUCCESS CRITERIA:
- Migration: ui.brightness 0.6 gives track 0.6 and main 0.6; 0.1 gives 0.2 each; absent gives 0.8 each; the old key is left in place for downgrade. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/settings_repository test/appliance
- Setting main to 0.5 calls the client with connector HDMI-A-1 only and leaves track unchanged. | verify: same
- Helper: --connector HDMI-A-2 with a fake sysfs ddc link to i2c-7 runs ddcutil --bus 7 setvcp 10 50. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_brightness_tests.sh
- Idle 120 s with fake time: dimmed after 120 s of no activity; never while transport plays or a capture runs; the idle period restarts when playback stops; the touch that wakes it does not reach the control under it. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance
- Page: Track display card first; slider steps by 5% with the encoder, Back cancels the edit; disconnected track display disables its Calibrate button. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings
- Analyzer, Bloc lint, goldens on the author machine. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: each slider changes only its own panel; DDC/CI or the software filter (whichever the panel supports) visibly applies; after 2 min idle both dim and a touch wakes without pressing anything. | verify: manual on device
```

### Part 10: touch calibration (about 650 lines; helper, `lib/appliance/touch`, both windows)

Pen 30: `ESLal`/`q4OZOP` (Track display calibration), `ARj5B`/`c00LeS` (Main display
calibration) and `hmuQG`/`xpmFC` (Test before keeping).

**Helper**

- `segno-touch-ctl` keys matrices by output:
  - `set <connector> <6 floats>` and `reset <connector>`;
  - `status` lists every touchscreen with its `WL_OUTPUT`.
  - `apply` writes one rule per output into `98-segno-touch-calibration.rules`
    (`ENV{WL_OUTPUT}=="<c>", ENV{LIBINPUT_CALIBRATION_MATRIX}="..."`) and re-triggers
    the input devices.
  - Migration: the single `/data/touch/calibration` moves to the output its touchscreen
    is bound to now (D12).
- Weston's helper path keeps working; it writes the matrix for the device it calibrated.

**Math** (`touch_fit.dart`, pure)

- A least-squares affine fit from 5 observed points to 5 targets, in the output's
  normalized coordinates.
- Contacts are degenerate when they are collinear or when the determinant is below 1e-3;
  the flow then offers Restart.
- The new matrix is the fit composed with the current one.

**Flow**

- `TouchCalibrationCubit`:
  - enters `GuardKind.calibration` (unavailable during capture or for a disconnected
    display);
  - asks to stop loops when playing ("Stop loops and calibrate");
  - takes 5 targets with a 60 s timeout per touch;
  - then 3 test targets with a 30 s total timeout. A test passes within 3% of the
    output's diagonal;
  - "Keep calibration" calls the helper;
  - Cancel, timeouts, disconnect and failed saves leave the previous matrix in place;
  - a new transport or capture command cancels the calibration and keeps the music
    running.
- Targets are drawn on the display being calibrated. The 15.6" shows the instruction
  page with Cancel focused for the encoder (D12). Test targets ignore the encoder.

```success-criteria
GOAL: Each panel's touch can be calibrated from Settings, verified before it is kept, and never left worse than before.
SUCCESS CRITERIA:
- Fit oracle: observed points equal to targets scaled by 0.9 and shifted by (+0.02, -0.01) yield the matrix "1.1111 0 -0.0222 0 1.1111 0.0111" to 1e-4; composed with current "1 0 0 0 1 0" gives the same; three collinear contacts report degenerate. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance/touch
- Flow: 5 touches then 3 tests in tolerance enables Keep; a test 5% off keeps Keep disabled and offers Restart; 60 s without a touch cancels with the previous matrix kept; Keep failure keeps the previous matrix and shows the error. | verify: same
- Starting playback during calibration cancels it and playback continues. | verify: same
- Helper: two touchscreens on HDMI-A-1 and HDMI-A-2 get two rules; reset of one leaves the other; the legacy single file migrates to the bound output and is removed. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_touch_ctl_tests.sh
- Analyzer, Bloc lint, goldens of the three pen screens on the author machine. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: on the 7", tap targets drawn on the 7" itself; after Keep, taps land on controls across the panel; repeat on the 15.6" when its touch panel is fitted; encoder Cancel works with touch deliberately misaligned. | verify: manual on device
```

### Part 11: Network page (about 650 lines; helper, `wifi_client`, `wifi_repository`, `lib/wifi`, `lib/settings/view`)

Pen 29: `wse91`/`cnZr7`, `O7zN9`/`X1daqW`, `brPO6`/`KSPNp`, `YU3gq`/`BqXq1`,
`JEHXY`/`N2AGeo`, `EXgOI`/`qAxVl`, `m0cYo`/`m4Xh5` and `yL9W8`/`hu9Bf`.

**Helper (`segno-wifi-ctl`)**

- New verbs:
  - `autoconnect <ssid> on|off` (`nmcli connection modify ... connection.autoconnect`);
  - `set-password <ssid>`, which reads the password from stdin and never from argv;
  - `connectivity`, a single HEAD request to the update host with a 3 s limit (D14).
- `connect` records the active connection first. On failure it reactivates that
  connection and reports `{"restored":"<ssid>"}` (D13).
- `status` adds `autoconnect` per saved network.

**Client, repository and cubit**

- Matching methods: `setAutoConnect`, `changePassword` and `checkConnectivity`. The
  connectivity check runs only while the page is open, with a 30 s minimum interval.
- State gains `lost`, which means the previous SSID is saved but not connected and the
  radio is on, and `noInternet`.

**Page**

- The switch in the title row and the connection card (name, status, IP chip, Manage or
  Reconnect).
- Networks with Scan; saved networks first.
- The join sheet with the existing on-screen keyboard and Show; "Incorrect password. Try
  again." on an auth failure.
- The Connecting dialog with Cancel.
- Network details: Connect automatically, Change password, Forget (with confirmation,
  per `c/wifi-forget`) and Disconnect.
- Off and empty states.

`WifiTrayBody` and `showWifiJoinSheet` are deleted once the page no longer uses them.

```success-criteria
GOAL: Settings > Network matches pen 29, and a failed join never leaves the console with less connectivity than before.
SUCCESS CRITERIA:
- Helper: connect to a bad password while connected to "The Studio" reactivates The Studio and prints restored; set-password reads stdin (argv never contains it); autoconnect off sets connection.autoconnect no. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_wifi_manage_tests.sh
- Existing Wi-Fi shell suites still pass. | verify: for t in deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_wifi_*_tests.sh; do bash "$t" || exit 1; done
- Cubit: connectivity false while connected gives "Connected · No internet"; the check is not called when the page is closed or more often than every 30 s. | verify: /Users/Tomas/development/flutter/bin/flutter test test/wifi packages/wifi_client packages/wifi_repository
- Page states match the eight pen screens; Forget asks to confirm, Disconnect does not; Change password reopens the sheet for that network. | verify: /Users/Tomas/development/flutter/bin/flutter test test/settings test/wifi
- WifiTrayBody is gone. | verify: ! grep -rn "WifiTrayBody\|showWifiJoinSheet" lib test
- Analyzer, Bloc lint, goldens on the author machine. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: join a network with a wrong password while connected; the console returns to the old network within 30 s; pull the router's uplink and see "Connected · No internet". | verify: manual on device
```

### Part 12: About and Controller firmware (about 420 lines; `console_facts_client`, flasher, `lib/system`)

PARITY frame `nBA56`: About `g5owAP`, Reference notices `hpvGh` and Controller /
Unsupported `IxFkH`. Controller / Updating `u5Cksr` and Recovery `Xyzrn` are not built
(D15).

**Facts**

- `LocalConsoleFactsClient.facts()` reads the serial, the system image and the panel
  EDID names (D15). Unreadable facts stay null and are omitted.

**Flasher**

- After a verified program, `segno-console-flash` writes
  `/data/segno/console-board/last-flashed` containing `firmware=<v> protocol=<n>`.
  The write is best-effort, and the exit status stays 0 (`segno-console-flash:14-16`).

**`ControllerFacts`**

- Firmware and protocol come from the live HELLO when connected (source `reported`).
- Otherwise they come from the record (source `lastFlashed`, captioned "Last flashed by
  this console").
- Otherwise "Not reported", captioned "No device version was read".
- `updateSupported` is false.

**Pages**

- About has three panels: This console (Name with rename, Segno version, System image,
  Serial, Audio interface), Controller (Connection, Firmware, Wire protocol, "Controller
  firmware") and Licenses ("Open-source notices", using the existing
  `showConsoleLicences` registry).
- Controller firmware: the Installed facts plus "Controller update support has not been
  established for this hardware." and a "Software updates" button.
- The preview line in the pen ("Appliance preview · ... simulated") is not shipped.

```success-criteria
GOAL: About shows only facts the console actually read, and the Controller page states plainly that in-app controller updates are not supported.
SUCCESS CRITERIA:
- Facts from a fake root: serial "10000000abcd1234", image "1.2.3", panel names from two EDID fixtures; a missing file omits that row. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/console_facts_client
- Flasher: a successful program writes "firmware=1.4 protocol=3"; a failed one writes nothing; exit status 0 in both. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-console-board/test/run_flash_record_tests.sh
- Controller facts: HELLO present gives the reported version with no caption; absent with a record gives the record with "Last flashed by this console"; neither gives "Not reported". | verify: /Users/Tomas/development/flutter/bin/flutter test test/system
- About and Controller pages render the pen's rows and actions; no "simulated" text appears. | verify: /Users/Tomas/development/flutter/bin/flutter test test/system test/settings && ! grep -rn "simulated" lib/system
- Analyzer, Bloc lint, goldens on the author machine. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: About on the appliance shows the board serial matching `cat /sys/firmware/devicetree/base/serial-number`, the installed build-version, both panel names, and the controller firmware after a boot that flashed it. | verify: manual on device
```

## 4. Hardware-only checks

These checks need the appliance: Pi 5, Scarlett 4i4, the 7" and 15.6" panels, and the
console board.

- **P1:** rollback of a crashing build.
- **P2:** a cable measurement on chosen jacks, with silence on the other outputs.
- **P3:** loops kept through a buffer change.
- **P5:** USB pull and replug with no sound before Reconnect audio.
- **P6:** a Restart round trip, and a Restart into a staged slot.
- **P7:** power pulled during an install.
- **P8:** a signed bundle and a tampered bundle on a stick.
- **P9:** brightness on each panel; DDC/CI support per panel is unknown until tried.
- **P10:** calibration on each panel. The 15.6" touch panel is not fitted yet; the 7" and
  15.6" connectors are crossed on the bench unit.
- **P11:** recovery after a wrong password, and the no-internet state.
- **P12:** serial and EDID facts, and the flasher record.

## 5. Pen write-back list

This list follows the memory rule that a shipped departure updates the pen. Planning did
not edit the pen.

- 28/04: the locked sample-rate reason (D2).
- 28/02: on the appliance, the automatic attempt goes on to the cable dialog (D3).
- 29/03: "If this fails, Segno reconnects to The Studio" (D13).
- 30: the Track display calibration targets are drawn on the 7" (D12); the "Display
  options" row (Q4).
- 32: the staged-update line on the Power card (D5).
- 33: the rollback notice (D8), the `.raucb` names and the error rows for unverified and
  not-newer packages (D9).

## 6. Open owner questions (each part proceeds on the default)

1. **Q1. Section 28 is a revised proposal, not accepted.** As drawn, it replaces two
   things:
   - automatic reconnect after an interface loss, with an explicit Reconnect audio;
   - the 2026-08-26 persistent red banner, with an amber Stage chip.

   Its design doc is "awaiting explicit acceptance". Default: Part 5 builds it as drawn.
   Part 5 is separate, so declining it keeps today's automatic reconnect and banner.
2. **Q2. May automatic measurement use the Scarlett loop channels?** That means sending a
   -12 dBFS pulse to an output that Audio routing leaves unassigned. The design doc
   forbids probing "arbitrary audible outputs", and the 4i4's own routing can still send
   that output to a jack. Default: no. On the appliance, Measure goes on to the cable
   test.
3. **Q3. A sample-rate change while loops are recorded.** The engine clears them, and
   the design doc lists "rate changes without changing recorded timing/pitch" as
   production work. Default: the rate is locked while any track holds material (D2).
   Resampling every lane on reopen would be a separate native part, of about 400 lines,
   if wanted.
4. **Q4. The accepted Displays screen has no place for four existing controls:** the
   waveform window on/off switch, high contrast, refresh rate and the shortcuts legend.
   Default: keep them in a "Display options" row under Dim while idle, and add them to
   the pen write-back list.
