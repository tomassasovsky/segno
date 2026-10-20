# Device and appliance pages: Device, interface loss, Displays, Power, Updates, Network, About

<!-- cspell:ignore dpwx yyqr Ulrb orpd pbdiy OZOP JEHXY Cksr Xyzrn devicetree EDID edid setvcp Licences tmpfiles -->

Tracking: #1270, `stage:build`. This plan covers the Device, Network, Displays and Updates
tiles of the Settings home, the About page and the Power button. They replace the interim
pages that `docs/plan/2026-10-06-feat-settings-destinations-plan.md` (#1199) put under
`lib/settings/view` (that plan's §2 tile map, rows 6, 7, 8 and 10).

## 0. Status (refreshed 2026-10-19)

The plan was written on 2026-10-06 against `c4b5cf909`. This refresh checks it against
`origin/claude/segno-integration` at `99b8027c2`. File and line references in the sections
for the open parts (1–5 and 8) are to that tree.

**Shipped.** Five parts merged into `claude/segno-integration` on 2026-10-07. Their specs
are replaced below by a short record of what shipped and where it differs from the plan;
the original specs are in commit `43e4443ef`.

| Part | PR | What shipped |
|---|---|---|
| 6 Power and Restart | #1284 | Power options with Restart and Shut down on one guarded path |
| 7 Updates page | #1287 | Pen 33 page, cancellable download, interrupted and rolled-back notices |
| 9 Displays | #1286 | Per-display brightness, idle dimming, Display options row |
| 11 Network | #1285 | Pen 29 page, failed join restores the previous network |
| 12 About and Controller | #1283 | Read facts only, Controller firmware page, flash record |

**Replaced.** Part 10 (touch calibration) was built under #1330 instead, as #1335. See
Part 10 below.

**System changes since the plan was written:**

- **The appliance runs ivi-homescreen only** (#1330: #1331, #1332, #1334). There is no
  Weston, no GTK runner, no `weston.ini`, no `weston-touch-calibrator`, no
  `97-segno-touch-output.rules`, no `WL_OUTPUT` rules and no desktop waveform window.
  `segno-kiosk-launch` sets up the environment and then runs
  `exec /usr/bin/segno --config /etc/segno/homescreen.toml`, so the app process is the
  service's main process. One process runs two Flutter engines, one per screen
  (`--segno-screen=main` and `--segno-screen=readout`), and the readout is fed over the
  screen link.
- **Screen roles and connectors come from `/etc/segno/homescreen.toml`.**
  `parseHomescreenScreenConnectors` (`packages/brightness_client/lib/src/display_outputs.dart:98`)
  reads each view's `--segno-screen` and `drm_connector`. The shipped file
  (`deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/homescreen.toml`, since
  #1346) puts the main UI (15.6") on HDMI-A-2 and the readout (7") on HDMI-A-1, which is
  how the assembled console is cabled. The panels are no longer crossed against the
  shipped config.
- **Touch calibration is in the app** (#1335): Settings > Displays > Calibrate touch.
  `segno-touch-ctl` takes `get`, `try`, `set`, `reset` and `restore` per screen (`main` or
  `readout`), plus `apply` at boot. The readout's touchscreen is matched by the
  `touch_device` name in `homescreen.toml`; every other touchscreen is main.
- **Idle dimming exists.** `IdleDimCubit` (`lib/appliance/idle_dim_cubit.dart`) shipped
  with Part 9. #1350 dims the console's ring and pills with the screens (pedal link
  protocol 11). #1355 stopped treating the open audio device as music, so dimming now
  fires on the appliance; only a playing or recording track, the backing track or a
  performance recording keeps the screens awake.
- **The settings tray is gone** (#1199 Part 5). `DeviceSettingsPage` now hosts
  `DeviceAudioTab` alone; `AudioTab`, `RecordingAudioTab` and `AudioTrayPanel` are
  deleted. Parts 4, 9 and 11 no longer wait on #1199.

**Open.** Parts 1–5 and 8 are still the plan and await the owner's review. None of them
has started. Their direction is unchanged. Part 1's premise changed with the ivi launcher
and is restated in its section; Part 4 and Part 8 have small corrections noted where they
apply.

Pen sources (`segno-ui.pen`, group `p0dpwx` "01 CURRENT UX"):

| Section | Frame | Status in the pen |
|---|---|---|
| 28 Audio device & recovery | `yeG6A` | "Revised proposal" (not Accepted) |
| 29 Wi-Fi | `p33ymC` | Accepted |
| 30 Displays | `OdZ7n` | Accepted |
| 32 Power | `Z4KAJ` | Accepted |
| 33 Updates | `b0n5kk` | Accepted |
| PARITY REVIEW / About, controller and MIDI sync | `nBA56` | parity review; About, notices and Controller screens only |

When the plan was written none of these frames had a `c/` rationale note. #1335 added one
to section 30 for the Track display calibration. The written rationale is in the design
docs in the main checkout:

- `docs/design/2026-09-07-audio-device-ux.md` (status: "Awaiting explicit acceptance").
- `docs/design/2026-09-07-display-settings-ux.md` (owner accepted 2026-09-07).
- `docs/design/2026-09-08-appliance-parity-correction.md`.

Engine numbers (ledger): commands 140–143 and perf-log facts 356–359. This plan uses 140
and 141. 142, 143 and the facts 356–359 go back to the ledger, because nothing here
changes recorded material. On `99b8027c2` the highest command is 137, so 140 and 141 are
still free.

Standing owner decisions that apply:

- The settings tray is retired (#1199 Parts 5–6). Done on the trunk.
- Computer-facing USB gadget mode is out of scope.
- Every Session schema bump adds a #1196 migration step. Nothing in this plan bumps the
  Session schema: every setting here is appliance state, which session recall and New
  loop do not touch.

## 1. Current state (verified on `99b8027c2`)

### Settings pages

- `SettingsDestination.open()` (`lib/settings/settings_destination.dart:61-72`) opens
  each page. Network, Displays, Updates and About are the accepted pages from Parts 9,
  11, 7 and 12.
- `DeviceSettingsPage` (`lib/settings/view/device_settings_page.dart`) is still interim:
  it hosts `DeviceAudioTab` (`lib/audio_setup/view/console/device_audio_tab.dart`), which
  still has the ASIO group (93-167, 477 on), the loopback note (153-156) and the latency
  row (422-475).
- Routes: `lib/app/segno_navigator.dart`. `openDeviceSettings` (195) is also called from
  `connectivity_banners.dart:75`, `tracks_chrome.dart:24` and `app.dart:1194`.

### Device and latency

- **Every Device chip applies at once and clears the loops.**
  - `setSampleRate` (`lib/audio_setup/cubit/audio_setup_cubit.dart:142`),
    `setBufferFrames` (151) and `setDevice` (229-244) call `_persistAndApply` (273).
  - `_persistAndApply` saves first (274), then calls `stopEngine()` and
    `startEngine(_engineConfig())` (296-298).
  - `le_engine_start` opens the device fresh and clears the recorded material; the
    `le_engine_reopen` comment says so (`packages/segno_engine/src/core/segno_engine_api.h:1925-1928`).
  - There is no draft, no confirmation and no capture guard. `GuardKind.deviceChange`
    (`packages/operation_guards/lib/src/guard_registry.dart:24`) is never entered.
- **A refused configuration comes back at boot.** The config is saved before the open,
  so a refused request stays on disk (274) while the screen shows the live values.
- **`le_engine_reopen` (`segno_engine_api.h:1897-1940`, #1140) keeps the material.** It
  keeps loops, history and Fade, and brings tracks back STOPPED. It still clears the
  whole engine when the sample rate or the loop cap changes (`LE_REOPEN_CLEARED_RATE`,
  `_CAP`), and it now also reports `LE_REOPEN_RETAINED_PARTIAL` with a dropped-track
  mask. The repository reaches it only from the private `_reopenEngine`
  (`packages/looper_repository/lib/src/looper_repository.dart:2634`).
- **The latency test is loud and plays on every output.**
  - `LE_CMD_MEASURE_LATENCY` (`engine_process.c:4085-4102`) starts a 10 ms, 1 kHz burst
    at amplitude 0.9 (`engine_core.h:34-38`).
  - The pulse block in `process_input_frame` (`engine_process.c:7276-7307`) writes it to
    every output channel.
  - It reads the return from the loopback channels when `excluded_input_mask != 0`,
    otherwise from the maximum of all real inputs (7219-7226, 7267).
  - `le_latency_resolve` (5648-5683) cross-correlates and writes `a_record_offset`.
  - No API selects an output, an input or a level.
- **The app measures without asking.**
  - At boot (`lib/app/audio_bootstrap.dart:306-321`) and after every apply
    (`_autoMeasureIfLoopback`, `audio_setup_cubit.dart:415-420`), the app measures
    whenever a loopback is detected. On the appliance, the Scarlett loop channels set
    `excluded_input_mask`, so this sends the 0.9 burst to every output.
  - `measureLatency()` (478) does not wait for or evaluate the result.
  - Offsets persist per device|rate|buffer (`_syncLatencyPersistence`, 592;
    `SettingsRepository.loadLatencyOffsetFrames` 388, `saveLatencyOffsetFrames` 406).
- **Rate and buffer choices are fixed lists** (`audio_setup_state.dart:235-238`).
  `le_device_info` (`segno_engine_api.h:683-704`) carries rate arrays only for ASIO. No
  ASIO backend is built any more, and its enumeration is always empty
  (`engine_devices.c:464-479`).
- **Health counters have no UI.** `EngineStatus.xrunCount`
  (`packages/looper_repository/lib/src/models/engine_status.dart:73`) is shown nowhere.

### Interface loss

- The Stage shows a persistent red `_LostBanner` (`lib/looper/view/connectivity_banners.dart:112`)
  with "Open setup" (75). This was the 2026-08-26 owner decision (`c/device-lost` in
  "02 EARLIER APPLICATION").
- The supervisor reopens automatically when the pinned device returns:
  `_superviseDevice` (`looper_repository.dart:2286`), `_attemptReconnect` (2343),
  `_reopenEngine` (2634).
- At boot, `AudioRecoveryCubit` (`lib/looper/cubit/audio_recovery_cubit.dart:21`) starts
  the engine on the absent→present edge.

### Displays (shipped by Part 9 and #1335)

- Brightness is per display: `DisplayBrightnessCubit`, keys `ui.brightness.track` and
  `ui.brightness.main` (`settings_repository.dart:784-787`), migrated from `ui.brightness`.
  `segno-brightness-ctl` takes `--connector`; a panel without a DDC bus is dimmed in
  software over its own screen.
- `DisplayRole` maps to `SegnoScreen` (`lib/appliance/display_role.dart`). The connector
  comes from `homescreen.toml` and presence from `/sys/class/drm/card*-<connector>/status`.
- Idle dimming: `IdleDimCubit` and `ui.idle_dim_seconds` (`settings_repository.dart:817`).
- Touch calibration: `TouchCalibrationCubit` and `TouchCalibrationPage`
  (`lib/settings/touch_calibration/`), `packages/touch_calibration_client`, and
  `segno-touch-ctl` with one matrix per screen in `/data/touch/{main,readout}`.

### Power and updates

- **Power** (shipped by Part 6): `PowerCubit` (`lib/appliance/power_off/power_cubit.dart`)
  has `restart` (80) and `shutDown` (86). Install and restart on Updates goes through
  `restart`. `applyAndRestart`, `powerOffWithoutSaving` and `powerOffAnyway` are gone.
- **Updates** (shipped by Part 7): `segno-update-ctl`
  (`deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/segno-update-ctl`) records
  the attempt marker, has the `attempt` and `clear-attempt` verbs, and passes the
  reconcile reason through. It is still network only: `do_install` (164-238) fetches the
  manifest, downloads to a work dir, checks sha256, and runs `rauc install` through a
  fifo.
- **The boot health gate.** `segno-mark-good` checks `is-active` and `NRestarts` on
  `segno.service` over a 45 s window, and nothing else. #976 is open
  (`stage:plan-review`, P0). Its failure, a wrapper that stayed up while the app died
  under it, came from the GTK-era launcher. Today `segno-kiosk-launch` ends in `exec`, so
  `segno.service`'s main process is `/usr/bin/segno` itself. Part 1 restates what is
  still missing.

### Network and About (shipped by Parts 11 and 12)

- `WifiCubit` and `segno-wifi-ctl` have the autoconnect, change-password and
  connectivity operations and the lost and no-internet states.
- `LocalConsoleFactsClient` reads the serial, `/etc/segno/build-version`, the EDID
  panel names and `/data/segno/console-board/last-flashed`.

## 2. Decisions taken under the standing rules

Each item names the rule it follows. Decisions for shipped parts are kept as the record
and marked with the PR that carried them out.

- **D1. Apply reopens; it does not restart** (rules 1, 2). Open (Part 3).
  - Apply goes through a new public `LooperRepository.applyAudioConfig`, which stops the
    engine and calls `le_engine_reopen`.
  - A buffer change, or a device change at the same rate, keeps the loops (stopped). That
    matches the pen 28/04 copy "Your recordings stay intact."
  - The config is saved only after the open succeeds. A refused request leaves the
    previous config on disk and on screen. This fixes the refused-config-at-boot bug.
- **D2. While any track holds material, the sample-rate chips are unavailable**, with the
  reason "Clear the tracks to change the sample rate" (rules 2, 3). Open (Parts 3, 4).
  The engine would clear the loops (`LE_REOPEN_CLEARED_RATE`), and the pen's copy promises
  they stay. Resampling recorded material is open question Q3.
- **D3. Measurement never plays on an output nobody chose** (design doc §Latency; rule
  2). Open (Parts 2, 3).
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
- **D4. Interface loss keeps the #1140 take rules.** Open (Part 5). A take in progress is
  dropped, committed layers stay, and tracks come back stopped. The design doc's "finishes
  the available partial loop take" predates the binding #1140 decisions.
- **D5. Restart and Install and restart use the shutdown flow** (rule 4). Shipped in
  #1284.
- **D6. Power follows the accepted pen 32**: a failed save offers only Stay on and Retry.
  Shipped in #1284.
- **D7. #976 uses a readiness marker written by the app.** Open (Part 1). Restated for the
  ivi launcher:
  - After the main screen's first frame and the first engine-start attempt, the app
    writes `/run/segno/app-ready` containing the boot id and its own pid.
  - `segno-mark-good` commits only if the marker belongs to this boot and its pid is
    `segno.service`'s `MainPID` at both ends of the window.
  - This is #976's first listed option, and the only one that observes the app itself.
    #976's other two options were ways to see the app's own process behind the
    launcher. `exec` in the launcher now gives that, so neither needs building.
- **D8. Update failures are visible.** Shipped in #1287.
- **D9. USB packages are RAUC bundles (`*.raucb`)**, read from the volume root and from
  `segno-updates/`. Open (Part 8).
  - The bundle is copied to `/data/segno/update-staging/` under a lease on the source
    volume. While the lease is held, Eject is refused (`StorageRepository.eject` throws
    `EjectRefused`) and shutdown waits. RAUC verifies the copy, so the stick is not needed
    during the install.
  - Packages that are not newer are refused with their version, the same rule as the
    network path.
  - The pen's ".update" names are mockups; the write-back list records the extension.
- **D10. Brightness per display.** Shipped in #1286.
- **D11. Idle dimming.** Shipped in #1286; corrected by #1355 (see Part 9).
- **D12. Touch calibration runs in the app.** Replaced by #1335 (see Part 10).
- **D13. A failed Wi-Fi join reactivates the previous connection.** Shipped in #1285.
- **D14. "Connected · No internet" checks on demand.** Shipped in #1285.
- **D15. About shows only facts that are read.** Shipped in #1283.
- **D16. Recovery from a disconnected or failing state never needs touch alone.**
  Encoder focus reaches Cancel, Reconnect audio, Stay on and Retry on every page here
  (rule 2). Still applies to Parts 4 and 5.

## 3. Parts

Sizes count production lines; tests are extra.

```
P1 boot gate (#976)        independent                       open
P2 native latency + caps   independent                       open
P3 audio apply + measure   needs P2                          open
P4 Device page             needs P3                          open
P5 interface loss          needs P4                (Q1)      open
P6 Power + Restart                                           shipped #1284
P7 Updates page                                              shipped #1287
P8 USB packages            needs USB storage (#1177)         open
P9 Displays brightness+dim                                   shipped #1286
P10 touch calibration                                        replaced by #1335 (#1330)
P11 Network                                                  shipped #1285
P12 About + Controller                                       shipped #1283
```

### Part 1: boot health gate keyed on the app (#976) (about 100 lines; image and `lib/app`)

This part lands under #976 (`Closes #976`, `Refs #1270`).

**What changed since the plan was written.** #976's failure was a launcher that stayed
up while the app died under it, so `is-active` stayed true and `NRestarts` stayed 0.
`segno-kiosk-launch` now ends in `exec /usr/bin/segno`, so the process systemd watches is
the app. A crash loop now changes `MainPID` and `NRestarts`, and the existing checks
should refuse it. That has not been tested on hardware.

**What Part 1 still solves.** The gate still only sees process state. A build whose
process stays alive but never draws, or never reaches the engine start, passes it: for
example a Dart exception before `runApp`, a hang during startup, or an engine that fails
to load the bundle while the embedder stays up. Whether ivi-homescreen exits in each of
those cases has not been checked. The readiness marker covers them all, because only an
app that rendered writes it.

- `lib/appliance/app_ready_marker.dart`:
  - After the first frame (`WidgetsBinding.instance.endOfFrame`) and after the first
    `startEngine` attempt has returned (success or refusal), the app writes
    `/run/segno/app-ready` once, containing `<boot_id> <pid>`.
  - Only the main screen's engine writes it. The readout engine runs in the same process
    and writes nothing.
  - The write is atomic: temp file plus rename.
  - It happens only when `isAppliance()` is true. A failed write is logged and ignored.
- `segno-mark-good`:
  - Wait up to `WAIT_SECS` for a marker whose boot id matches
    `/proc/sys/kernel/random/boot_id`.
  - Read its pid, and require it to equal `systemctl show -p MainPID --value
    segno.service`. Wait `STABLE_SECS`, then require the same marker and the same
    `MainPID` again.
  - The `is-active` and `NRestarts` checks stay as additional conditions.
  - Paths are overridable through `SEGNO_APP_READY_FILE` and `SEGNO_BOOT_ID_FILE`; the
    existing `SEGNO_SYSTEMCTL` stub answers `MainPID`.
- No unit change. `/run/segno` already exists: `segno-runtime.conf` creates it through
  tmpfiles on every image. The plan's earlier `RuntimeDirectory=segno` is dropped,
  because systemd would delete `/run/segno` (and with it `/run/segno/usb`) whenever
  `segno.service` stops.

```success-criteria
GOAL: A build whose app never renders, or that restarts during the window, is never committed.
SUCCESS CRITERIA:
- Marker for this boot whose pid equals MainPID at both ends of the window: commits (rauc mock called with "status mark-good booted"). | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_mark_good_tests.sh
- No marker within WAIT_SECS, a marker from another boot id, a marker pid that differs from MainPID, or a MainPID that changes during the window: exits 1 with no rauc call (four cases, unit reported active with NRestarts 0 in each). | verify: same
- The app writes "<boot_id> <pid>" once, only on the appliance and only from the main screen, after the first frame and the first start attempt; a write failure does not throw. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance/app_ready_marker_test.dart
- Analyzer and Bloc lint clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: install a bundle whose app throws before runApp; after two boots the console is back on the previous slot with no SSH. Then install a good bundle; it is committed after the window. | verify: manual on device
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
  (including `RETAINED_PARTIAL` with its dropped tracks) plus the negotiated values. A
  cold engine falls back to `startEngine`.
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
  `lib/app/audio_bootstrap.dart:319-321` (the restore at 312 stays), `measureLatency()`
  and the immediate-apply setters once Part 4 drops their last caller.
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
- Repository: applyAudioConfig on a started engine calls reopen (not start) and returns retained with tracks STOPPED; mock outcomes clearedRate and retainedPartial are reported, not hidden. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- measure() with a backend loopback ends done with the engine's value; with Scarlett-style excluded channels it ends in cable without posting command 140. Cable test: noReturn keeps the saved offset; cancel posts 141 and keeps it. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup
- Boot with a saved offset restores it and never measures; boot without one measures nothing. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app
- Command 1 and le_engine_measure_latency are gone. | verify: ! grep -rn "LE_CMD_MEASURE_LATENCY\b\|le_engine_measure_latency\b" packages/segno_engine/src packages/segno_engine/lib && bash packages/segno_engine/src/test/run_native_tests.sh
- Analyzer, Bloc lint. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: with loops playing on the appliance, change the buffer 128 to 256 and apply; loops stop, are still there, and play at the same pitch; a USB stick device swap at 48 kHz keeps them too. | verify: manual on device
```

### Part 4: Device page (about 650 lines; `lib/audio_setup/view`, `lib/settings/view`)

Pen 28: `Q3YCDg`/`hWDHw` (01 Audio settings), `NtHav`/`yyqrZ` (02), `viOWI`/`C2o3h` (03)
and `btTbs`/`jUlrb` (04).

The plan's dependency on #1199 Part 5 is met: the tray, `AudioTab` and the Recording tab
are already gone, and `DeviceSettingsPage` hosts only `DeviceAudioTab`.

**Page body**

- `DevicePage` replaces `DeviceSettingsPage`.
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
- The inert ASIO group (`device_audio_tab.dart:93-167`, 477 on). No ASIO backend is
  built.
- The loopback note (153-156).
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
- DeviceAudioTab is gone; the device-lost banner, engine-stopped banner and recovery toast still open this page. | verify: ! grep -rn "DeviceAudioTab" lib test && /Users/Tomas/development/flutter/bin/flutter test test/settings test/looper/view
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

### Part 6: Power options and Restart: shipped in #1284

Shipped on 2026-10-07 as planned: Power options with Cancel, Restart and Shut down; one
guarded path that stops transport, flushes settings, saves the session and waits for
storage leases; "Segno is staying on" with Stay on and Retry; the staged-update line; and
Install and restart through `PowerCubit.restart`.

Where it differs from the plan:

- No compatibility re-export for `PowerOffCubit` (AGENTS.md); `applyAndRestart`,
  `confirmEmpty` and `confirmPowerOff` were removed as well.
- The restart guard is entered after the save, because the guard table refuses a session
  write while a restart is active.
- An unnamed session is named first, through Save As.
- A flush failure and a save failure share one "staying on" state.
- Install and restart keeps its own confirm dialog instead of opening Power options.
- Pen 32 goldens and the hardware restart checks were left for the author machine and
  the device.

### Part 7: Updates page: shipped in #1287

Shipped on 2026-10-07 as planned: the pen 33 states, the attempt marker and `attempt`
verb, the rollback notice from the reconcile reason, `UpdatePhase.interrupted`,
`cancelDownload()`, the manifest size, and the About and Controller rows.

Where it differs from the plan:

- The helper also gained `clear-attempt`. The download runs in the background so SIGTERM
  stops it at once; the cubit clears the attempt file that the kill leaves.
- `UpdateRepository.recover()` reads the reconcile reason and the attempt once at
  startup.
- The page also has the channel control.
- "Load from USB" is not on the page; Part 8 adds it.
- Not verified on hardware: power loss mid-install, cancel during `rauc install`, a real
  tryboot-not-taken notice.

### Part 8: update from USB (about 420 lines; helper, `lib/update`, `storage_repository`)

Pen 33: `w3lUKE`/`xlAif` (Load a USB package). Part 7 has shipped. The USB storage service
(#1177) is on the trunk: `StorageRepository.volumes`, `acquire`/`HeldLease`, and `eject`,
which refuses while any lease on the volume is held.

**Helper**

- New verb `install-file <path>`:
  - Refuses a path outside `/data/segno/update-staging/`.
  - `rauc info --output-format=json` checks the signature and the compatible string, and
    reads the version.
  - Refuses a version that is not newer, with `{"error":"not-newer","version":..}`.
  - Refuses an unverified bundle with `{"error":"unverified"}`.
  - Otherwise runs the same fifo install, attempt and staged markers, and progress as
    `do_install`. The shared part becomes `install_bundle`.
  - The staging copy is removed on exit.

**App**

- `UsbUpdateSource` lists `*.raucb` on each mounted volume (the root and `segno-updates/`)
  with Dart directory reads; there is no fork.
- Leases on the trunk are write leases: `WritePurpose` is a closed enum (recording, copy,
  export, backup), and `copyFile` leases the destination. This part adds
  `WritePurpose.update`, with its word on the Storage page, to hold the source volume
  while the bundle is read.
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
- Updates gains the "Load from USB" button that Part 7 left out.

```success-criteria
GOAL: A signed bundle on a USB stick installs to the inactive slot exactly as an online update does; anything else is refused with nothing changed.
SUCCESS CRITERIA:
- install-file with a mock rauc reporting a newer version: same PROGRESS sequence and markers as install; staging emptied. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_update_file_tests.sh
- Not newer, signature failure, and a path outside staging: the JSON errors above, no markers, rauc install never called. | verify: same
- Listing finds a.raucb at the root and segno-updates/b.raucb, ignores c.txt. | verify: /Users/Tomas/development/flutter/bin/flutter test test/update
- Eject during the copy is refused with the update lease named; volume loss during the copy shows the removed-drive message and leaves staging empty. | verify: same
- New helper suite wired into the CI shell-tests step. | verify: grep -n run_update_file_tests .github/workflows/main.yaml
- Analyzer, Bloc lint. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: a stick holding a signed release bundle and an edited copy of it: the first installs and commits after reboot; the second is refused as unverified. | verify: manual on device
```

### Part 9: Displays, brightness per display and idle dimming: shipped in #1286

Shipped on 2026-10-07 as planned: two cards with the Track display first, per-display
brightness 20–100% (5 points per encoder detent, double tap to 80%), the `ui.brightness`
migration, Dim while idle (Never / 2 / 5 / 10 min, 30% with a 10% floor, the wake touch
consumed), `segno-brightness-ctl --connector`, and the Display options row (the default
answer to Q4).

Where it differs from the plan, including changes after it merged:

- The role→connector map first read `weston.ini`. #1334 moved it to
  `/etc/segno/homescreen.toml` when Weston was removed, and `DisplayRole` now maps to
  `SegnoScreen`.
- The Track display has no window of its own any more: it is the readout engine, and
  its software dim reaches it over the screen link (`WaveformDisplayController.brightness`).
- `SoftwareBrightness` no longer rebuilds the navigator when its filter appears (a fix
  made in the same PR).
- #1355: idle dimming counted the open audio device as music and so never fired on the
  appliance. It now counts a playing or recording track, the backing track or a
  performance recording.
- #1350: the console's ring and pills dim with the screens.
- Not verified on hardware: per-panel DDC/CI, the software dim, the wake touch, "Not
  connected" on unplug (#1334 later saw "Not connected" on unplug of the 7").

### Part 10: touch calibration: replaced by #1335

Weston's calibrator went with Weston, so the in-app calibrator was built under #1330 as
#1335 rather than from this part. It follows pen section 30 and keeps this part's goals:
targets on the panel being calibrated, a test before keeping, and never leaving a panel
worse than before.

How it differs from this part's spec:

- Matrices are kept per screen (`/data/touch/main`, `/data/touch/readout`), not per
  connector. The readout's touchscreen is matched by the `touch_device` name in
  `homescreen.toml`, the same match ivi-homescreen uses; every other touchscreen is main.
- Verbs: `get`, `try` (apply without storing), `set`, `reset`, `restore` and `apply`. A
  fit is applied with `try` and stored only on Keep calibration within 30 s, so a power
  cycle drops an unkept calibration.
- Test targets pass within 4% of the screen, not 3% of the diagonal.
- No `weston-touch-calibrator` fallback and no migration of a single legacy matrix.
- The 7" targets are drawn on the 7" through two screen-link messages; the main screen
  mirrors the target with the instruction, countdown and buttons. Section 30 of the pen
  has a `c/` note for this.

### Part 11: Network page: shipped in #1285

Shipped on 2026-10-07 as planned: the connection card and its eight states, the networks
list, the join sheet with Show, the Connecting dialog with Cancel, Network details
(Connect automatically, Change password, Forget with confirmation, Disconnect), and the
helper verbs `autoconnect`, `set-password` (stdin) and `connectivity`.

Where it differs from the plan:

- `status` also reports the last network used.
- The Connecting dialog names the network it will return to.
- A new shared `LoopSwitch` widget.
- Copy and sizes came from the accepted network HTML study, because section 29 was not
  in the local pen copy.
- Not verified on hardware: the wrong-password recovery, the no-internet state, and the
  sheets by encoder alone.

### Part 12: About and Controller firmware: shipped in #1283

Shipped on 2026-10-07 as planned: About with This console, Controller and Licenses; the
Controller firmware page in the Unsupported state; file-read facts; and the flasher's
`last-flashed` record.

Where it differs from the plan:

- A Displays row was added to This console, for the two panel names.
- The Name row shows only when a serial was read.
- An incompatible board counts as reported, with Connection showing "Different link
  protocol".
- Not verified on hardware: the serial against devicetree, the EDID names, the flash
  record after a real flash.

## 4. Hardware-only checks

These checks need the appliance: Pi 5, Scarlett 4i4, the 7" and 15.6" panels, and the
console board.

Open parts:

- **P1:** rollback of a build whose app never renders.
- **P2:** a cable measurement on chosen jacks, with silence on the other outputs.
- **P3:** loops kept through a buffer change.
- **P5:** USB pull and replug with no sound before Reconnect audio.
- **P8:** a signed bundle and a tampered bundle on a stick.

Shipped parts, still unchecked on hardware according to their PRs:

- **P6 (#1284):** a Restart round trip, and a Restart into a staged slot.
- **P7 (#1287):** power pulled during an install.
- **P9 (#1286):** brightness on each panel; DDC/CI support per panel; idle dimming.
- **P11 (#1285):** recovery after a wrong password, and the no-internet state.
- **P12 (#1283):** serial and EDID facts, and the flasher record.

## 5. Pen write-back list

This list follows the memory rule that a shipped departure updates the pen. Planning did
not edit the pen.

For the open parts:

- 28/04: the locked sample-rate reason (D2).
- 28/02: on the appliance, the automatic attempt goes on to the cable dialog (D3).
- 33: the `.raucb` names and the error rows for unverified and not-newer packages (D9).

For the shipped parts:

- 29/03: "If this fails, Segno reconnects to The Studio" (D13).
- 30: the Track display calibration targets drawn on the 7"; #1335 says it added this
  note. The "Display options" row (Q4).
- 32: the staged-update line on the Power card (D5).
- 33: the rollback notice (D8).

Whether the shipped parts' items other than #1335's were written back was not checked in
this refresh: the pen is not in the worktree, and the PRs say the frames were not in the
repo's copy.

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
4. **Q4. The accepted Displays screen has no place for four existing controls.** Answered
   by default in #1286: they are in a "Display options" row under Dim while idle.
