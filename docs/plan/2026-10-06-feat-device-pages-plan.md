# Device and appliance pages: Device, interface loss, Displays, Power, Updates, Network, About

<!-- cspell:ignore dpwx yyqr Ulrb orpd pbdiy OZOP JEHXY Cksr Xyzrn devicetree EDID edid setvcp Licences tmpfiles libsystemd raucb statvfs fdtget prefault -->

Tracking: #1270, `stage:build`. This plan covers the Device, Network, Displays and Updates
tiles of the Settings home, the About page and the Power button. They replace the interim
pages that `docs/plan/2026-10-06-feat-settings-destinations-plan.md` (#1199) put under
`lib/settings/view` (that plan's §2 tile map, rows 6, 7, 8 and 10).

## 0. Status (revised 2026-10-19)

The plan was written on 2026-10-06 against `c4b5cf909` and refreshed on 2026-10-19 against
`99b8027c2`. This revision follows the owner's answers to Q1–Q3 (recorded on #1270 on
2026-10-19) and four adversarial reviews of the refresh: claims against code, failure
modes, design and scope, and UX against the pen. Every finding is either adopted or turned
down with a reason in §7.

File and line references are to `origin/claude/segno-integration` at `a37926236`. Between
`99b8027c2` (the tree the reviews read) and `a37926236` only docs, agent hooks and the
#1367 spike changed, so the reviews' references still hold.

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

**Replaced.** Part 10 (touch calibration) was built under #1330 instead, as #1335.

**Owner answers (2026-10-19).**

- **Q1, interface loss:** keep today's behaviour: automatic reconnect when the interface
  returns, and the persistent red banner meanwhile (the 2026-08-26 decision). Pen section
  28's amber chip and explicit Reconnect audio are not accepted. Part 5 shrinks to fixes
  within today's behaviour.
- **Q2, automatic measurement:** no. Measure is the loopback cable test only. The
  automatic path, `loopbackIsolated` and the automatic dialog (pen 28/02) are dropped.
- **Q3, rate change with recordings:** the sample rate is locked while any track holds
  material. No resampling part.

**What changed in this revision.**

- A new trunk-based **Part 3a** fixes the live bugs first, with no native change: chip taps
  that wipe the loops, a refused configuration saved for the next boot, the 0.9 burst on
  every output, and the automatic measurement on the Scarlett loop channels.
- The old Part 3 is now **Part 3b**: the cable measurement, on top of Part 2.
- Part 2 drops device-rate enumeration and deletes the dead ASIO fields instead of adding
  a parallel pair.
- Part 1 uses `Type=notify` with `sd_notify` through FFI instead of a marker file, adds a
  heartbeat and a readout check, and reboots after refusing an uncommitted tryboot.
- Part 5 keeps automatic reconnect (Q1) and fixes the banners, the readout text and the
  case where a failed Apply cannot reopen the previous configuration.
- Part 8 holds the stick with a read hold, copies through a part file with a free-space
  check, and waits for the posix_spawn launcher (#1367).

**Open.** The owner approved this revision on 2026-10-26 ("refresh, then build"; #1272
merged). Parts 1, 2, 3a, 3b, 4, 5 and 8 are open. None has started.

## 0a. Refresh of 2026-10-26

Every claim, path and dependency below was re-checked against
`origin/claude/segno-integration` at `a3f6bc805`, 446 commits after `a37926236`. Almost all
of them are the Looper X effects work. The audio-settings app code (`lib/audio_setup`,
`lib/app/audio_bootstrap.dart`, `lib/settings`, the banners, `AudioRecoveryCubit`, the
readout) has not changed since `a37926236`, so its line references hold. What changed:

- **#1367 launcher merged** (#1373, 2026-10-20). `packages/spawn_process` has
  `startProcess` and `runProcess`; `lib/update/appliance/system_appliance_env.dart`
  already uses them; the `no-dart-process` CI job (`tool/check_no_dart_process.sh`) fails
  on `Process.run`/`Process.start`/`Process.runSync` anywhere in `lib/` and
  `packages/*/lib`. Part 8 is no longer waiting on anything. #1367 itself stays open for
  its on-device fork trace.
- **Freeze recovery merged** (#1438, closes #1437, 2026-10-23). It arms the hardware
  watchdog for PID 1 (`RuntimeWatchdogSec=60s`), reboots on panic and lockups, keeps
  pstore records on `/data`, and makes the slot commit durable (`set_primary_persistent`
  fsyncs `autoboot.txt` and syncs `/boot`). It also verified on the console that the
  tryboot flag is one-shot: a reset during a trial boot comes back on the committed slot.
  Part 1 relies on that for its rollback reboot. Part 1's "no watchdog" still holds: it
  means no `WatchdogSec=` on `segno.service`, which would kill a slow app mid-set; the
  PID 1 watchdog from #1438 is a different thing and stays.
- **#1398 (open, being brought up to date by another thread)** moves RAUC's status to
  `/data/rauc`, fscks `/boot` before mounting it, and makes `segno-update-ctl install`
  exit 3 on a read-only `/boot`. Part 1 is built on top of it (D7, Part 1 below):
  - `segno-mark-good` still commits with `rauc status mark-good booted`, which #1398
    keeps.
  - Part 1 tells a trial boot from a committed one by the firmware's own flag,
    `/chosen/bootloader/tryboot` in the device tree, read with `fdtget` exactly as the
    RAUC backend's `get-state` reads it. It does not parse `rauc status`: that would
    depend on RAUC's status file (which #1398 moves and starts empty) and on reading
    `/boot/autoboot.txt` (which #1398's fsck exists to protect).
  - Only a health refusal reboots. A `rauc` failure on a healthy app (for example a
    read-only `/boot`) exits 1 without a reboot: the app works, the musician may be
    playing, and the next reboot rolls back anyway.
  - Part 8's `install_bundle` shares #1398's read-only `/boot` check.
- **`run_mark_good_tests.sh` is already in CI** (`appliance-shell-tests`, "Run mark-good
  tests"). It runs the script with `sh`, which is dash on the runner. Part 1 adds a bash
  run next to it rather than wiring the suite in.
- **ivi-homescreen is built with `-DBUILD_SYSTEMD_WATCHDOG=OFF`**
  (`recipes-graphics/ivi-homescreen/ivi-homescreen_git.bb`), so the embedder sends no
  `sd_notify` of its own. The app's `READY=1` is the only one.
- **First boot without an interface.** `Type=notify` with `TimeoutStartSec=180` kills an
  app that never sends `READY=1`. The plan counted a refused start as ready only when the
  *pinned* interface is absent; a console with no saved config and no interface plugged
  in (first run, `recoveryConfig` null) would then be killed every 180 s on a committed
  slot. Part 1 also counts a refused start as ready when nothing is pinned and
  `pickConsoleAudioDevices` finds no interface to pin. A refusal with an interface
  present still never counts.
- **ASIO paths are all still there** (`audio_setup_cubit.dart:83, 162-205`,
  `audio_setup_state.dart:224-232`, `le_device_info.asio_*` at
  `segno_engine_api.h:923-931`, `le_enumerate_asio_drivers` at `engine_devices.c:482`).
  #925 (`stage:plan`, `autonomy:auto`) asks for the Dart half of the same removal but
  keeps `LE_BACKEND_ASIO` and `le_enumerate_asio_drivers` as stubs so an old stored
  backend still parses. That conflicts with AGENTS.md (no compatibility layers) and with
  D18; Parts 3a and 2 do the whole removal and say `Refs #925`, and the part that
  removes the last of it says `Closes #925`.
- **Engine line references moved** with the effects work: command 1 is handled at
  `engine_process.c:4388`, the burst amplitude is `LE_LATENCY_PULSE_AMP 0.9f`
  (`engine_core.h:34`), the loopback-or-max input pick is at 7641-7689 and the pulse
  block at 7691-7725. The highest command is still `LE_CMD_AUDITION_STOP = 137`.
  `looper_repository.dart` moved by 3 lines: `_superviseDevice` 2289,
  `_attemptReconnect` 2346, `_reopenEngine` 2637, `_replayRig` 2682, the `> 0` gate 2724.
  `audio_bootstrap.dart`'s restore and automatic measurement are at 310-321.
- **The effects budget (new, needs the owner): Q5.** Admission control (#887,
  `fx_cost.dart`, `LooperRepository.fxRoomNs`) refuses an effects edit that would not fit
  80 % of a block at the running rate and buffer. The budget shrinks when the rate goes up
  (48 to 96 kHz halves the time per frame) and when the buffer drops below 64 frames. An
  Apply in Part 3a or Part 4 can therefore put chains that fit today over the budget, and
  nothing refuses or warns. This plan does not decide it; see §6 Q5. It affects Parts 3a
  and 4 only.
- **Nothing in the effects work touched the open path** beyond a stack prefault at device
  start (`engine_miniaudio.c`, `rt_stack_ready`). `le_config`, `le_engine_start`,
  `le_engine_reopen` and the latency harness are unchanged in behaviour.

Pen sources (`segno-ui.pen`, group `p0dpwx` "01 CURRENT UX"):

| Section | Frame | Status in the pen |
|---|---|---|
| 28 Audio device & recovery | `yeG6A` | "Revised proposal"; 01, 03 and 04 are built here, 02 and 05–07 are declined (Q1, Q2) |
| 29 Wi-Fi | `p33ymC` | Accepted |
| 30 Displays | `OdZ7n` | Accepted |
| 32 Power | `Z4KAJ` | Accepted |
| 33 Updates | `b0n5kk` | Accepted |
| PARITY REVIEW / About, controller and MIDI sync | `nBA56` | parity review; About, notices and Controller screens only |

The written rationale is in the design docs in the main checkout:

- `docs/design/2026-09-07-audio-device-ux.md` (status: "Awaiting explicit acceptance";
  Q1–Q3 now settle the parts of it this plan builds).
- `docs/design/2026-09-07-display-settings-ux.md` (owner accepted 2026-09-07).
- `docs/design/2026-09-08-appliance-parity-correction.md`.

Engine numbers: Part 2 takes the next two free command numbers when it is built. On
`a37926236` the highest command is `LE_CMD_AUDITION_STOP = 137`, so they would be 140 and
141 if 138 and 139 stay reserved by the plans that hold them. The earlier claim that the
implementation ledger reserves 140–143 and facts 356–359 is withdrawn: the ledger
(`docs/plan/2026-09-09-segno-implementation-ledger.md`) has no such entry. Nothing in this
plan adds a perf-log fact.

Standing owner decisions that apply:

- The settings tray is retired (#1199 Parts 5–6). Done on the trunk.
- Computer-facing USB gadget mode is out of scope.
- Every Session schema bump adds a #1196 migration step. Nothing in this plan bumps the
  Session schema: every setting here is appliance state, which session recall and New
  loop do not touch.
- The app never forks (#1367). A part that starts a helper program uses the posix_spawn
  launcher from #1367 (`docs/brainstorm/2026-10-19-no-fork-helpers-brainstorm-doc.md` §5).
  Only Part 8 starts a helper.
- One surface per cause (owner, #860): a toast for low stakes, a persistent banner for a
  condition that needs action, never two bars for one cause.

## 1. Current state (verified on `a37926236`, re-checked on `a3f6bc805`; §0a)

### Settings pages

- `SettingsDestination.open()` (`lib/settings/settings_destination.dart:61-72`) opens the
  ten tiles of the Settings home. Network, Displays and Updates are the accepted pages from
  Parts 11, 9 and 7. About is not a tile: it opens from its own row (Part 12).
- `DeviceSettingsPage` (`lib/settings/view/device_settings_page.dart`) is still interim:
  it hosts `DeviceAudioTab` (`lib/audio_setup/view/console/device_audio_tab.dart`), which
  still has the ASIO group (93-167, 477 on), the loopback note (153-156) and the latency
  row (422-475).
- Routes: `lib/app/segno_navigator.dart`. `openDeviceSettings` (195) is also called from
  `connectivity_banners.dart:75`, `tracks_chrome.dart:24` and `app.dart:1194`.

### Device and latency

- **Every Device chip applies at once and clears the loops.**
  - `setSampleRate` (`lib/audio_setup/cubit/audio_setup_cubit.dart:142`),
    `setBufferFrames` (151), `setMaxLoopMinutes` (207) and `setDevice` (229-244) call
    `_persistAndApply` (273).
  - `_persistAndApply` saves first (274), then calls `stopEngine()` and
    `startEngine(_engineConfig())` (296-298).
  - `le_engine_start` opens the device fresh and clears the recorded material; the
    `le_engine_reopen` comment says so (`packages/segno_engine/src/core/segno_engine_api.h:2166-2215`).
  - There is no draft, no confirmation and no take check. `GuardKind.deviceChange` and
    `GuardKind.calibration` (`packages/operation_guards/lib/src/guard_registry.dart:24,27`)
    are never entered. `GuardKind.capture` is entered only by a performance recording
    (`packages/performance_repository/lib/src/performance_repository.dart:455`); a loop
    take holds no guard.
- **Dead ASIO paths.** `setBackend` and `setAsioDriver` (`audio_setup_cubit.dart:162-184`),
  `_snapRateAndBuffer` and the ASIO branch of `sampleRateChoices`
  (`audio_setup_state.dart:226-232`) remain, and `le_enumerate_asio_drivers` is always
  empty (`engine_devices.c:482`). `le_device_info` still carries `asio_buffer_sizes`,
  `asio_sample_rates` and their counts (`segno_engine_api.h:928-931`), surfaced as
  `AudioDevice.bufferSizes` and `.sampleRates`.
- **A refused configuration comes back at boot.** The config is saved before the open,
  so a refused request stays on disk (274) while the screen shows the live values.
- **`le_engine_reopen` (#1140) keeps the material.** It keeps loops, history and Fade,
  and brings tracks back STOPPED. It clears the whole engine when the negotiated sample
  rate or the loop cap differs (`LE_REOPEN_CLEARED_RATE`, `_CAP`), and reports
  `LE_REOPEN_RETAINED_PARTIAL` with a dropped-track mask. The repository reaches it only
  from the private `_reopenEngine` (`packages/looper_repository/lib/src/looper_repository.dart:2637`).
- **The replay re-applies the old record offset.** `_replayRig` (2682) pushes
  `_recordOffset` when it is above 0 (2724), whatever the new device, rate or buffer, and
  `_syncLatencyPersistence` (`audio_setup_cubit.dart:592`) then saves any offset above 0
  under the new device|rate|buffer key as if it had been measured.
- **The latency test is loud and plays on every output.**
  - `LE_CMD_MEASURE_LATENCY` (`engine_process.c:4388`) starts a 10 ms, 1 kHz burst
    at amplitude 0.9 (`engine_core.h:34`).
  - The pulse block in `process_input_frame` (`engine_process.c:7691-7725`) writes it to
    every output channel.
  - While the harness owns a frame, `le_engine_process` skips the transport advance and
    the mix (`engine_process.c:9663-9670`): the loops go silent and the playhead stops for
    the whole window.
  - It reads the return from the loopback channels when `excluded_input_mask != 0`,
    otherwise from the maximum of all real inputs (7641-7689).
  - A completed state stays `DONE` in the snapshot, with no request id, so a caller cannot
    tell a new result from the previous one.
  - `le_engine_begin_latency_for_test` (`engine.c:1894`, `engine_internal.h:259`) drives
    command 1 in eight native tests, including the loopback oracle.
- **The app measures without asking.**
  - At boot (`lib/app/audio_bootstrap.dart:310-321`) and after every apply
    (`_autoMeasureIfLoopback`, `audio_setup_cubit.dart:415-420`), the app measures
    whenever a loopback is detected. On the appliance, the Scarlett loop channels set
    `excluded_input_mask`, so this sends the 0.9 burst to every output. The manual
    Measure button takes the same path, so on the appliance it never measures a cable.
  - The miniaudio loopback kinds (`LE_LOOPBACK_BACKEND`, `_MONITOR`) are never reported on
    ALSA (`engine_devices.c:110`).
- **Rate and buffer choices are fixed lists** (`audio_setup_state.dart:235-238`): 44.1,
  48 and 96 kHz; 64 to 512 frames.
- **Health counters have no UI.** `EngineStatus.xrunCount`
  (`packages/looper_repository/lib/src/models/engine_status.dart:73`) is shown nowhere.

### Interface loss

- The Stage shows a persistent red `_LostBanner` (`lib/looper/view/connectivity_banners.dart:68-75`)
  with "No audio device — nothing is heard" and "Open setup". The same strip draws the
  `restoredCleared` notice (77-92). This was the 2026-08-26 owner decision
  (`c/device-lost` in "02 EARLIER APPLICATION"), confirmed by Q1.
- The 7" readout echoes the lost condition with the same sentence
  (`lib/visualizer/console_readout_view.dart:68-74, 309`).
- The supervisor reopens automatically when the pinned device returns:
  `_superviseDevice` (`looper_repository.dart:2289`), `_attemptReconnect` (2346),
  `_reopenEngine` (2637).
- At boot, `AudioRecoveryCubit` (`lib/looper/cubit/audio_recovery_cubit.dart:21`) starts
  the engine on the absent→present edge. While it waits, `app.dart:1181-1198` shows a
  warning toast that does not close on its own, and the Stage also shows the generic
  `AudioNotRunningBanner`: two surfaces for one cause.
- A reopen that the replay refuses rolls back through `stopEngine`, which clears the
  repository's running intent; the supervisor then never reopens.

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
  has `restart` (80) and `shutDown` (86).
- **Updates** (shipped by Part 7): `segno-update-ctl` records the attempt marker, has the
  `attempt` and `clear-attempt` verbs, and passes the reconcile reason through. It is
  network only: `do_install` (164-238) fetches the manifest, downloads to a work dir,
  checks sha256, and runs `rauc install` through a fifo.
- **The boot health gate.** `segno-mark-good` checks `is-active` and `NRestarts` on
  `segno.service` (`Type=simple`, `Restart=always`) over a 45 s window, and nothing else.
  A refusal leaves the slot uncommitted but does not reboot, so the console keeps running
  the bad slot until someone power-cycles it. #976 (`stage:plan-review`, P0) reports a
  real crash loop that read `NRestarts` 0. `segno-kiosk-launch` now ends in
  `exec /usr/bin/segno`, so `MainPID` is the app.
- `run_mark_good_tests.sh` runs in CI's `appliance-shell-tests` job, with `sh` (dash on
  the runner); the 2026-10-19 claim that CI skipped it was wrong by 2026-10-26 (§0a). Its
  `systemctl` stub answers every `show` with the next `NRestarts` line, whatever property
  is asked.

### Storage and helpers

- USB storage (#1177 code on the trunk; the issue is still open for its remaining parts):
  `StorageRepository.acquire` (`packages/storage_repository/lib/src/storage_repository.dart:276`)
  checks that the volume is writable (`_checkWritable`, 327-343) and enters
  `GuardKind.transfer`; a read-only stick is refused. `eject` refuses while any lease is
  held (391-393). The Storage page names lease holders by purpose
  (`lib/storage/view/storage_page.dart:313-318`).
- Library exports and backups hold what they read with a plain `GuardKind.transfer`
  guard on the source (`lib/library/cubit/library_cubit.dart:458-475`), which the Storage
  page does not show.
- `copyFile` (634) writes a hidden part file, fsyncs and renames, sweeps stale parts once
  per directory, and maps ENOSPC to `StorageFailure.full`.
- The app starts helpers through `packages/spawn_process` (posix_spawn, #1373), and CI
  bans `dart:io` process calls (§0a).

### Network and About (shipped by Parts 11 and 12)

- `WifiCubit` and `segno-wifi-ctl` have the autoconnect, change-password and
  connectivity operations and the lost and no-internet states.
- `LocalConsoleFactsClient` reads the serial, `/etc/segno/build-version`, the EDID
  panel names and `/data/segno/console-board/last-flashed`.

## 2. Decisions taken under the standing rules

Each item names the rule it follows. Decisions for shipped parts are kept as the record
and marked with the PR that carried them out.

- **D1. Apply reopens; it does not restart** (rules 1, 2). Parts 3a and 4.
  - Apply goes through a new public `LooperRepository.applyAudioConfig`, which stops the
    engine and calls `le_engine_reopen`.
  - A buffer change, or a device change at the same rate, keeps the loops (stopped). That
    matches the pen 28/04 copy "Your recordings stay intact."
  - The config is saved only after the open succeeds. A refused request reopens the
    previous config and leaves it on disk and on screen, with the existing
    `audioRefusedConfig` line ("The device could not open at {asked}. Running at
    {actual}.").
- **D2. While any track holds material, the sample rate and the maximum loop length are
  locked** (rules 2, 3; Q3). Parts 3a and 4. The chips stay visible and disabled, with the
  reason under them. Both would clear the engine (`LE_REOPEN_CLEARED_RATE`, `_CAP`). The
  lock is checked when the change is made and again at confirm, because a take can land
  while the confirm dialog is open. A device change that would make the engine clear is
  refused before it clears (Part 2's keep-material flag, used from Part 3b).
- **D3. No take is ever cut by Apply or Measure** (rule 2). Parts 3a and 3b. Both are
  refused while any track records or overdubs, while a record waits on a count-in or a
  quantized start, or while a performance capture is armed. The loop-take part is checked
  on `LooperState`; the performance part through the guard table (`deviceChange` and
  `calibration` both refuse under `capture`). The refusal reuses `operationBusy` (capture:
  "A recording is running. Stop it first.").
- **D4. Measurement never plays on an output nobody chose** (design doc §Latency; rule 2;
  Q2). Parts 2, 3a, 3b.
  - Measure is the cable test only: one chosen output, one chosen input, -12 dBFS
    (amplitude 0.25).
  - The boot-time and apply-time automatic measurements, `loopbackIsolated`, the automatic
    dialog and the loopback notes are removed. A saved offset for the same
    device|rate|buffer is still restored (rule 1).
  - The burst takes over the output, so Start test stops the transport and the backing
    track first, and the cable dialog says so when either is running.
- **D5. Restart and Install and restart use the shutdown flow** (rule 4). Shipped in
  #1284.
- **D6. Power follows the accepted pen 32**: a failed save offers only Stay on and Retry.
  Shipped in #1284.
- **D7. #976 uses systemd's own readiness and status.** Part 1.
  - `segno.service` becomes `Type=notify`. The app calls `sd_notify` from
    `libsystemd.so.0` through `dart:ffi`; it is a no-op when `NOTIFY_SOCKET` is unset.
  - `READY=1` is sent once, when the main screen has rasterized its first frame, the
    readout has reported its first raster over the screen link (when its connector reads
    connected), and the first engine start has returned OK, or was refused while the
    pinned interface is absent (or, with nothing pinned, while no interface is there to
    pin; §0a).
  - Every 5 s the main isolate sends `STATUS=alive <n> readout <m>`: `n` counts its own
    timer, `m` the readout's last answer to a screen-link ping. `segno-mark-good` requires
    both to advance during the window.
  - This replaces the marker file: systemd accepts notifications only from `MainPID`
    (`NotifyAccess=main`), so there is no pid to compare and nothing in `/run` to clean.
- **D8. Update failures are visible.** Shipped in #1287.
- **D9. USB packages are RAUC bundles (`*.raucb`)**, read from the volume root and from
  `segno-updates/`. Part 8.
  - The stick is held with a read hold for the copy: it needs the volume mounted (a
    read-only stick is fine), refuses Eject, keeps shutdown waiting, and is named on the
    Storage page. It is not a write lease, because `acquire` refuses a read-only volume.
  - The copy goes to `/data/segno/update-staging/` through a part file, after a
    free-space check, and stale parts are swept at startup. RAUC verifies the copy, so the
    stick is not needed during the install.
  - Packages that are not newer are refused with their version, the same rule as the
    network path.
  - The helper is started through the #1367 launcher.
- **D10. Brightness per display.** Shipped in #1286.
- **D11. Idle dimming.** Shipped in #1286; corrected by #1355.
- **D12. Touch calibration runs in the app.** Replaced by #1335.
- **D13. A failed Wi-Fi join reactivates the previous connection.** Shipped in #1285.
- **D14. "Connected · No internet" checks on demand.** Shipped in #1285.
- **D15. About shows only facts that are read.** Shipped in #1283.
- **D16. Recovery from a disconnected or failing state never needs touch alone.**
  Encoder focus reaches Cancel, Stop audio and apply, Start test, Retry and Open setup on
  every page here (rule 2).
- **D17. Interface loss keeps today's behaviour** (Q1). Part 5. The supervisor reopens on
  its own when the pinned interface returns, keeping the #1140 take rules (a take in
  progress is dropped, committed layers stay, tracks come back stopped). The red banner
  holds the Stage meanwhile. A failed Apply whose rollback also fails is treated the same
  way: the previous config stays pinned and supervised.
- **D18. No device-rate enumeration** (rule 4: simplest). Part 2. The rate chips stay the
  fixed list 44.1, 48 and 96 kHz. A rate the interface refuses is reported by the open, as
  today, through `audioRefusedConfig`. Enumeration was turned down because on the
  appliance it would probe the Scarlett's ALSA hw device while the engine holds it
  (EBUSY), the open already reports the negotiated rate, and the Scarlett 4i4 supports all
  three listed rates. The dead `asio_*` fields are deleted, not renamed.

## 3. Parts

Sizes count production lines; tests are extra. No stack is more than two deep: a part
either starts from the trunk or stacks on one open part whose own base is the trunk.

```
order  part                          base                          size   state
1      P3a live audio-settings fixes trunk (after Q5)             ~350   open
1      P1  boot health gate (#976)   trunk after #1398 (or #1398's  ~200   open
                                     branch while it is open)
2      P5  interface-loss fixes      trunk, after P3a merges        ~200   open
2      P2  native measurement path   trunk, after P3a merges        ~300   open
3      P3b cable measurement         stacked on P2                  ~400   open
4      P4  Device page               trunk after P3b merges         ~600   open
                                     (or stacked on P3b once P2 has merged)
any    P8  USB packages              trunk (the #1367 launcher      ~450   open
                                     merged in #1373)
-      P6 Power + Restart                                                  shipped #1284
-      P7 Updates page                                                     shipped #1287
-      P9 Displays brightness + dim                                        shipped #1286
-      P10 touch calibration                                               replaced by #1335
-      P11 Network                                                         shipped #1285
-      P12 About + Controller                                              shipped #1283
```

P2 waits for P3a only because it deletes command 1 and the engine side of the ASIO
paths, and P3a removes their last callers in the app. P5 waits for P3a because its
rollback case is about `applyAudioConfig`.

### Part 3a: live audio-settings fixes (about 350 lines; `looper_repository`, `lib/audio_setup`, `lib/app`)

Trunk-based, no native change. It keeps the immediate-apply chips of today's Device tab
and makes them safe. Part 4 later puts the same path behind a draft and an Apply row.

**Repository**

- `applyAudioConfig(EngineConfig) -> AudioApplyResult` makes the `_reopenEngine` path
  public. On a started engine it stops and reopens; on a cold engine it calls
  `startEngine`. When the new config's open is refused, it reopens the previous config
  and returns `refused` with the previous negotiated values. Otherwise it returns the
  outcome (`retained`, `retainedPartial` with its dropped tracks, `clearedRate`,
  `clearedCap`) and the negotiated rate and buffer.
- `_replayRig` always pushes the remembered record offset, 0 included. The `> 0` gate
  existed only so the replay would not overwrite the automatic boot measurement, which
  this part removes.
- The repository's `measureLatency()` (command 1) has no caller after this part; Part 2
  deletes the command.

**`AudioSetupCubit`** (all methods return void, for Bloc lint)

- `setSampleRate`, `setBufferFrames`, `setMaxLoopMinutes` and `setDevice` go through one
  `_requestApply(next)`:
  1. Take check (D3). Refused with `operationBusy` (capture); nothing changes.
  2. Lock (D2). A rate or max-loop change while `LooperState.hasContent` is ignored; the
     chips are disabled with "Clear the tracks to change the sample rate." or "Clear the
     tracks to change the maximum loop length."
  3. Transport or backing running: `ApplyPhase.confirming`, which shows pen 28/04's
     "Apply audio settings?" with Cancel and "Stop audio and apply". Encoder focus starts
     on Cancel.
  4. `confirmApply()` repeats steps 1 and 2 against the current state, stops the
     transport and the backing track, enters `GuardKind.deviceChange` for the duration,
     and calls `applyAudioConfig`.
- On success the requested config is saved (D1). Then the record offset is set from the
  saved value for the new device|rate|buffer, or to 0, and the latency row shows the
  value or "Not measured".
- A `clearedRate` outcome (a device change that negotiated another rate while tracks held
  material) is reported through the existing `restoredCleared` notice, not hidden. Part 3b
  refuses it before it clears.
- On `refused` nothing is saved, the chips show the previous config, and the row shows
  `audioRefusedConfig`.
- `_syncLatencyPersistence` stops saving offsets. It only restores the saved one. Part 3b
  saves an offset only when its own measurement completes.

**Removed**

- `_autoMeasureIfLoopback`, the automatic branch in `lib/app/audio_bootstrap.dart:318-321`
  (the restore at 310-317 stays), the cubit's `measureLatency()`, the Measure button and
  the loopback notes (`loopbackDetectedNote`, `loopbackAvailableNote`) in
  `DeviceAudioTab`. On the appliance this button only ever measured the Scarlett loop
  channels, which Q2 rules out. The latency row keeps showing the restored value. Part 3b
  brings Measure back as the cable test.
- The ASIO paths in the app: `setBackend`, `setAsioDriver`, `_asioSelectable`, the
  cached driver list, `_snapRateAndBuffer`, the ASIO branch of `sampleRateChoices`, and the
  ASIO group in `device_audio_tab.dart` (93-167, 477 on).

```success-criteria
GOAL: No Device chip can clear the loops, cut a take, save a refused config or play a test burst.
SUCCESS CRITERIA:
- A buffer tap 128 -> 256 while stopped calls applyAudioConfig once and never startEngine; the mock reports retained and every track keeps its lengthFrames. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup
- The same tap while a track plays emits ApplyPhase.confirming and calls nothing; confirmApply stops transport and backing, then applies; Cancel leaves playback untouched. | verify: same
- With a track recording, overdubbing or waiting on a count-in, every setter is refused with operationBusy(capture) and applyAudioConfig is never called; the same when a take starts while the confirm dialog is open and confirmApply runs. | verify: same
- With material on track 2, setSampleRate and setMaxLoopMinutes are ignored, the chips are disabled (not hidden) and expose the lock reason to a screen reader; with every track empty they apply. | verify: same
- Refused by the device: saveAudioConfig is never called, the engine is reopened on the previous config, the chips show it, and the row shows "The device could not open at 96 kHz. Running at 48 kHz." | verify: same
- After a successful buffer change with no saved offset for the new key, setRecordOffset(0) is called and the row shows "Not measured"; with a saved one, that value is set. saveLatencyOffsetFrames is never called in either case. | verify: same
- Repository: applyAudioConfig on a started engine calls reopen, not start; clearedRate and retainedPartial are returned, not hidden; _replayRig pushes an offset of 0. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- Boot with a saved offset restores it; boot without one sends no measurement command, with or without excluded loop channels. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app
- No Measure button and no ASIO code remain in the app. | verify: ! grep -rn "setAsioDriver\|setBackend\|_autoMeasureIfLoopback\|loopbackDetectedNote\|measureLatency()" lib
- Analyzer and Bloc lint clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: with loops playing on the appliance, tap 256; the dialog appears; confirm; the loops stop, are still there, and play at the same pitch; nothing is heard from any output during the change; after a reboot the console comes up at 256. | verify: manual on device
```

### Part 1: boot health gate keyed on the app (#976) (about 200 lines; image, `lib/appliance`, `lib/visualizer`)

This part lands under #976 (`Closes #976`, `Refs #1270`).

**Why it is still needed.** `segno-kiosk-launch` now ends in `exec /usr/bin/segno`, so
systemd watches the app itself. But the gate still sees only process state. A process
that stays alive and never draws, never reaches the engine start, or hangs after a good
start passes it: for example a Dart exception before `runApp`, a hang during startup, an
engine that fails to load while the embedder stays up, or a readout that never draws. #976
also reports a crash loop that read `NRestarts` 0, so the restart count alone is not
trusted.

**Readiness and heartbeat (D7)**

- `lib/appliance/systemd_notify.dart`: `sd_notify(0, text)` through `dart:ffi` from
  `libsystemd.so.0`. When `NOTIFY_SOCKET` is unset or the library is missing, every call
  is a no-op (desktop builds and tests).
- `lib/appliance/boot_readiness.dart`, on the main screen only:
  - waits for `WidgetsBinding.instance.waitUntilFirstFrameRasterized`;
  - waits for the readout's first-raster message over the screen link, when the readout
    connector reads connected in `/sys/class/drm`; the readout sends it after its own
    `waitUntilFirstFrameRasterized`;
  - waits for the first engine start to return OK, or a refusal while the pinned
    interface is absent, or a refusal with nothing pinned while `pickConsoleAudioDevices`
    finds no interface; a refusal with the interface present never counts as ready;
  - then sends `READY=1`, once.
  - After that, a 5 s timer sends `STATUS=alive <n> readout <m>` and a ping to the
    readout; `m` is the sequence of the readout's last answer.
- `segno.service`: `Type=notify`, `NotifyAccess=main`, `TimeoutStartSec=180`. A build that
  never becomes ready is killed at 180 s and restarted, which the gate sees. No watchdog:
  a systemd watchdog would kill a slow but working app in the middle of a performance.
- `segno-kiosk-launch` keeps `NOTIFY_SOCKET` across its `exec` (it does not clear the
  environment; the test checks this).

**`segno-mark-good`**

- Wait up to `WAIT_SECS` for `is-active` (which `Type=notify` reaches only after
  `READY=1`).
- Record `MainPID`, `NRestarts` and `StatusText`. Wait `STABLE_SECS`. Require the same
  `MainPID`, the same `NRestarts`, `is-active`, and a `StatusText` whose main counter
  advanced, and whose readout counter advanced when the readout connector is connected.
- On a health refusal, when the boot is a trial boot (`fdtget /sys/firmware/fdt
  /chosen/bootloader tryboot` reads 1, the flag the RAUC backend's `get-state` reads),
  reboot with plain `systemctl reboot`. The tryboot flag is one-shot, so the firmware
  boots the committed slot (verified on the console under #1438). A refusal on a
  committed boot, or when the flag cannot be read, never reboots, so a bad committed slot
  cannot loop.
- A `rauc status mark-good booted` failure after a healthy window exits 1 and never
  reboots (§0a: #1398's read-only `/boot`).
- Built on #1398: it lands after #1398, or is based on #1398's branch while #1398 is
  open.
- The test stub answers each `show -p <property>` from its own file (`MainPID`,
  `NRestarts`, `StatusText`, `ActiveState`) and records `reboot` calls; an `fdtget` stub
  answers the tryboot flag.
- CI already runs `run_mark_good_tests.sh` with `sh` (dash); Part 1 adds a bash run.

```success-criteria
GOAL: A build whose app never renders, never reaches the engine, hangs, or restarts during the window is never committed, and an uncommitted bad slot rolls back without anyone touching the console.
SUCCESS CRITERIA:
- Active, same MainPID and NRestarts, both StatusText counters advancing: commits (rauc mock called with "status mark-good booted"), no reboot. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_mark_good_tests.sh
- Never active within WAIT_SECS; MainPID changes; NRestarts changes; main counter frozen; readout counter frozen with the readout connected: each exits 1 with no rauc call. A frozen readout counter with the readout disconnected still commits. | verify: same
- Each health refusal on a trial boot (fdtget stub reads 1) calls "reboot" once; the same refusal on a committed boot (0) or with fdtget failing calls no reboot; a rauc mark-good failure after a healthy window calls no reboot. | verify: same
- The stub distinguishes properties: a test where NRestarts is constant but MainPID changes is refused. | verify: same
- CI runs the suite under bash and dash. | verify: grep -n "run_mark_good_tests" .github/workflows/main.yaml
- READY=1 is sent once, only after the first raster, the readout's first raster (when connected) and an OK start; a refused start with the interface present never sends it; a refused start with the pinned interface absent, or with nothing pinned and no interface found, does; with NOTIFY_SOCKET unset nothing is called. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance/boot_readiness_test.dart
- Analyzer and Bloc lint clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: install a bundle whose app throws before runApp; the console reboots by itself into the previous slot with no SSH. Install a bundle that crash-loops after its first frame; same result. Install a good bundle; it is committed after the window. | verify: manual on device
```

### Part 5: interface-loss fixes within today's behaviour (about 200 lines; `looper_repository`, `lib/looper/view`, `lib/visualizer`, `lib/app`)

Q1 keeps automatic reconnect and the persistent red banner. Pen 28/05–07 (`i1uSR`,
`orpdZ`, `LGQmc`) are not built. This part fixes the surfaces and one recovery gap.

**One surface per cause**

- While the boot-time recovery waits for the pinned interface, the Stage shows the red
  strip with the existing `audioRecoveryWaitingBanner` text and "Open setup". The warning
  toast from `app.dart:1181-1198` is removed, and `AudioNotRunningBanner` is suppressed
  while it waits, as it already is while the device is lost.
- The lost banner's text says what happens next. Proposed copy for the pen write-back:
  "{device} disconnected — nothing is heard. Audio restarts when it is back." It falls
  back to the existing `deviceLostBanner` when no name is known.
- The 7" readout echo reads the same string as the main banner, so the two screens never
  disagree. It keeps one line; a widget test on the 1024-wide readout checks it does not
  ellipsize.
- The `restoredCleared` notice keeps replacing the lost banner on the same strip (never
  both), and the reconnect toasts are unchanged.

**Rollback failure (D17)**

- When `applyAudioConfig` cannot open the new config and the reopen of the previous one
  also fails, the repository keeps the previous config pinned and its running intent
  set, and arms the supervisor exactly as after an interface loss. The Stage shows the
  lost banner, and the supervisor reopens the previous config when the device answers.
- The Device tab shows `audioRefusedConfig` with the previous values and the status pill
  "Disconnected".

```success-criteria
GOAL: Every audio-interface condition shows one surface that says what happens next, and no failure path leaves the supervisor disarmed.
SUCCESS CRITERIA:
- Boot waiting for the interface: the red strip with the waiting text shows, no warning toast and no AudioNotRunningBanner. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view test/app
- Device lost with a known name: the banner text names it and says audio restarts; the readout echo shows the same text on one line without ellipsis. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view test/visualizer
- restoredCleared after a reconnect: one strip, the cleared text, never the lost text beside it. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Apply refused and the previous config's reopen refused: the supervisor stays armed; when the mock device answers, reopen is called with the previous config and tracks come back stopped. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/looper_repository
- Never-started boot with the pinned device appearing still starts automatically (AudioRecoveryCubit tests unchanged). | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/cubit/audio_recovery_cubit_test.dart
- Open setup is reachable by encoder focus on the strip. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Analyzer and Bloc lint clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: pull the Scarlett USB cable mid-loop; one red strip on the 15.6" and the same text on the 7"; replug; audio restarts on its own and the loops are present and stopped. | verify: manual on device
```

### Part 2: native measurement path, keep-material reopen, ASIO removal (about 300 lines; engine and bindings)

Trunk-based, after Part 3a merges.

**Contract (`segno_engine_api.h`)**

```c
LE_CMD_MEASURE_LATENCY_PATH = 140, /* latency.output, latency.input (0xFFFF = the
                                    * interface loopback channels), latency.amplitude,
                                    * latency.request */
LE_CMD_CANCEL_LATENCY = 141,       /* latency.request */
/* le_latency_state gains */ LE_LATENCY_CANCELLED = 4,
/* le_snapshot gains */ uint32_t latency_request; /* request of the latest state */
/* le_config gains */ int32_t keep_material; /* reopen refuses to clear */
LE_EXPORT int32_t le_engine_measure_latency_path(le_engine*, int32_t output,
                                                 int32_t input, float amplitude,
                                                 uint32_t request);
LE_EXPORT int32_t le_engine_cancel_latency(le_engine*, uint32_t request);
```

The command uses its own union member in `le_command`, like `click` and `record_start`.

**Control side** (`le_engine_measure_latency_path`)

- Returns `LE_ERR_INVALID_ARG` when the output is not below the device's output count,
  the input is neither below the input count nor 0xFFFF, the input is 0xFFFF but
  `excluded_input_mask == 0`, or the amplitude is outside (0, 0.5]. The app sends 0.25.

**Audio side**

- Command 140 sets `lat_out`, `lat_in`, `lat_amp` and `lat_request`, and publishes
  MEASURING with that request.
- The pulse block writes the burst to `lat_out` only. Every other output is 0.0f while
  measuring.
- The return magnitude is `|in[lat_in]|`, or `loop_mag` for 0xFFFF.
- The command is ignored, and CANCELLED is published with its request, when any track is
  recording or overdubbing.
- Command 141 with the current request, or `le_engine_mark_device_lost` during a
  measurement, clears `lat_active` and publishes CANCELLED. `a_record_offset` is left
  unchanged. A 141 with another request is ignored.
- Every published latency state carries `latency_request`, so a caller waits for its own
  request and never reads a previous DONE.
- Command 1 (`LE_CMD_MEASURE_LATENCY`) and `le_engine_measure_latency` are deleted; Part
  3a removed their last caller. `le_engine_begin_latency_for_test` takes the path
  arguments, the eight tests that use it pass them (the loopback oracle with 0xFFFF), and
  the comments at `engine_process.c:3643` and `7721` name the new command.

**Keep-material reopen**

- With `keep_material` set, `le_engine_reopen` that negotiates another rate or loop cap
  closes the device again, keeps the material untouched and stopped, and returns a new
  `LE_ERR_WOULD_CLEAR`. The repository then reopens the previous config. Without the flag
  the behaviour is unchanged.

**ASIO removal (D18)**

- `le_enumerate_asio_drivers`, the four `asio_*` fields of `le_device_info`,
  `le_audio_backend`, `le_config.backend`, `AudioDevice.bufferSizes` and `.sampleRates`,
  the repository's `asioDrivers()`, `EngineStatus.activeBackend`, and the three
  `AudioBackend` enums with the persisted backend key. A stored backend value is ignored on load (no compatibility layer,
  AGENTS.md).
- After the header change: `dart run ffigen --config ffigen.yaml` and `dart format`.

```success-criteria
GOAL: The latency pulse plays on one chosen output at -12 dBFS, returns on one chosen input, carries its request id, and can be cancelled; a reopen can refuse instead of clearing; no ASIO code remains.
SUCCESS CRITERIA:
- 2 in / 2 out at 48000, path (output 1, input 0, 0.25, request 7), harness feeds out ch1 back into in ch0 delayed 150 frames: out ch0 is exactly 0.0f for the whole window; out ch1 frame 1 equals 0.25f*sinf(2*pi*1000/48000) (compared with the engine's own float expression); state DONE with latency_request 7; record_offset_frames in [150, 152]. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A completed request 7 followed by request 8: until request 8 completes, the snapshot never reports DONE with request 8. | verify: same
- Same path, the echo fed into in ch1 instead: TIMEOUT with request 7, record offset unchanged from a prior LE_CMD_SET_RECORD_OFFSET of 77. | verify: same
- Input 0xFFFF with excluded mask 0x2 resolves from ch1 (the loopback oracle, RET 150); with mask 0 the call returns LE_ERR_INVALID_ARG and the state stays IDLE. | verify: same
- Output 2 on a 2-out device, input 5 on 2-in, amplitude 0 and 0.6: each returns LE_ERR_INVALID_ARG and posts nothing. | verify: same
- Cancel with request 7 after 1000 frames: CANCELLED, offset still 77, every output sample after the cancel frame is 0.0f with no monitors enabled; cancel with request 6 is ignored. Device lost mid-window: CANCELLED, offset 77. | verify: same
- Track 0 recording when 140 arrives: CANCELLED, out ch1 never carries the burst, the take's captured PCM equals its input samples exactly. | verify: same
- Reopen with keep_material at another negotiated rate: LE_ERR_WOULD_CLEAR, lane PCM and history byte-identical, tracks stopped; without the flag, LE_REOPEN_CLEARED_RATE as before. | verify: same
- Command 1, le_engine_measure_latency and every ASIO symbol are gone. | verify: ! grep -rn "LE_CMD_MEASURE_LATENCY\b\|le_engine_measure_latency\b\|asio_\|AudioBackend\|asioDrivers" packages lib --include='*.c' --include='*.h' --include='*.dart'
- Dart wrappers and the mock: measureLatencyPath forwards (1, 0, 0.25, 7); cancelLatency publishes cancelled with its request. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/segno_engine packages/looper_repository
- ASAN suite and bindings regenerated with no format churn. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && git diff --stat packages/segno_engine/lib/src/generated
```

### Part 3b: cable measurement (about 400 lines; `looper_repository`, `lib/audio_setup`)

Stacked on Part 2. Brings Measure back to the existing Device tab as the cable test (pen
28/03, `viOWI`/`C2o3h`); Part 4 moves the row onto the new page and reuses the dialog.

**Repository**

- `measureLatency({required int output, required int input}) -> Future<LatencyResult>`
  takes the next request id, posts command 140, and completes on the first snapshot whose
  `latencyRequest` equals it with DONE, TIMEOUT or CANCELLED. After 2 s it posts 141 and
  completes with `timedOut`.
- `cancelLatency()` posts 141 with the current request.
- `applyAudioConfig` sets `keep_material` while any track holds material. On
  `LE_ERR_WOULD_CLEAR` it reopens the previous config and returns `refused` with the
  negotiated rate of the new device.

**`AudioSetupCubit`**

- `MeasurePhase {idle, cable, running, done, noReturn, cancelled}`.
- `openCableTest()` goes to `cable`. Refused under D3's take check with `operationBusy`
  (capture), and unavailable while the device is disconnected.
- `startCableTest(output, input)`:
  1. repeats the take check;
  2. stops the transport and the backing track (D4);
  3. enters `GuardKind.calibration` for the run, so Apply, a device change and a capture
     are refused meanwhile and Restart cancels it;
  4. calls `measureLatency`.
- DONE saves the offset under the current device|rate|buffer key and closes the dialog;
  the latency row shows the new value. noReturn and cancelled keep the previous value.
- `cancelMeasure()`; leaving the page also cancels.
- A device change refused with `LE_ERR_WOULD_CLEAR` shows `audioRefusedConfig` with the
  new device's rate and the previous config.

**Device tab**

- The latency row regains Measure. Its states: enabled; disabled with the reason while
  disconnected; "Measuring…" with Cancel while running.
- The cable dialog: output and input pickers (the encoder steps through them), "Playback
  stops while measuring." when the transport or the backing track runs, Cancel and Start
  test. No-return keeps the dialog open with "No pulse came back. Check the cable and the
  input gain." and Retry.

```success-criteria
GOAL: Latency is measured only on a path the musician chose, never during a take, never over a stale result, and a device change never clears loops.
SUCCESS CRITERIA:
- startCableTest(3, 2) while stopped posts 140 with (2, 1, 0.25) and a new request; a DONE snapshot with the previous request does not complete it; DONE with its own request saves the offset under device|rate|buffer and closes the dialog. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup packages/looper_repository
- With a track recording, overdubbing or counting in: openCableTest and startCableTest are refused with operationBusy(capture) and post nothing. | verify: same
- While the transport plays: the dialog shows the stop line; Start test stops transport and backing before posting 140. | verify: same
- During the run, an Apply is refused with operationBusy(calibration); after it, the guard is released. | verify: same
- noReturn and cancel keep the saved offset; leaving the page posts 141. | verify: same
- Device change with material, mock returning LE_ERR_WOULD_CLEAR: reopen with the previous config, material kept, row shows audioRefusedConfig, nothing saved. | verify: same
- Encoder alone: focus starts on the output picker, steps to input, Start test and Cancel. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup/view
- Analyzer and Bloc lint clean. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: on the appliance with a cable from output 3 to input 2, the measurement completes, nothing is heard on outputs 1-2, and a recording overdubbed afterwards lines up with the loop. | verify: manual on device
```

### Part 4: Device page (about 600 lines; `lib/audio_setup/view`, `lib/settings/view`)

Pen 28: `Q3YCDg`/`hWDHw` (01 Audio settings), `viOWI`/`C2o3h` (03 cable dialog, from
Part 3b) and `btTbs`/`jUlrb` (04 Apply). 02 is not built (Q2); 05–07 are not built (Q1).

**Draft**

- `AudioDraft {deviceId, sampleRate, bufferFrames, maxLoopMinutes}` with `editRate`,
  `editBuffer`, `editDevice`, `editMaxLoop` and `discardDraft`. Editing calls nothing.
- Apply runs Part 3a's path on the whole draft: take check, lock, confirm when the
  transport or the backing track runs, re-check at confirm, one `applyAudioConfig`.
- The immediate-apply setters are deleted once the page is the only caller.

**Page body**

- `DevicePage` replaces `DeviceSettingsPage`.
- Header: the interface name, "N inputs · M outputs", a status pill (Connected /
  Disconnected) and "Change interface", which opens the existing chooser as a dialog; a
  choice there edits the draft.
- Left column: sample rate chips (disabled, never hidden, with the D2 reason under them
  while locked); buffer chips with "Lower latency" / "More headroom"; the period readout
  (`buffer / rate` in ms, two decimals, "per buffer").
- Right column: "Round-trip latency" with the value or "Not measured" and the record
  offset subtitle (`audioRecordOffsetSub`); Measure, disabled with "Apply audio settings
  before measuring." while a draft is pending, and with Part 3b's other states; health
  rows "Audio dropouts" (`xrunCount` since the last open) and "Audio engine" (Running /
  Stopped / Offline).
- Under the columns: Max loop length (in the draft, under the same lock) and Audio
  routing (a link). Neither is in pen 28/01; both are written back (§5).
- Apply row, shown only while the draft differs: "Changes apply together. Your recordings
  stay intact.", Cancel and Apply.
- Strings come from the existing ARB entries where one exists (`roundTripLatencyLabel`,
  `notMeasured`, `latencyMs`, `audioMeasure`, `audioRecordOffsetSub`,
  `audioRefusedConfig`, `operationBusy`); new ones are the pen's copy.

**Removed**

- `DeviceAudioTab`, apart from the pieces moved here.

```success-criteria
GOAL: Settings > Device matches pen 28 screens 01, 03 and 04 and drives Part 3a's apply and Part 3b's measurement from a draft.
SUCCESS CRITERIA:
- Tapping 256 shows the Apply row and period 5.33 ms (48 kHz) without calling applyAudioConfig; Cancel restores 128 and hides the row. | verify: /Users/Tomas/development/flutter/bin/flutter test test/audio_setup/view test/settings
- Rate 96 and buffer 256 drafted together: one applyAudioConfig call with both. | verify: same
- Apply while playing shows "Apply audio settings?"; "Stop audio and apply" calls confirmApply; encoder focus starts on Cancel. | verify: same
- Max loop length is drafted and applied with the rest, and locked with its reason while a track holds material. | verify: same
- Measure is disabled with "Apply audio settings before measuring." while a draft is pending; with no draft it opens Part 3b's cable dialog. | verify: same
- Locked rate chips are visible, disabled and announce the reason to a screen reader. | verify: same
- Health rows show the snapshot's xrun count and engine state. | verify: same
- DeviceAudioTab and the immediate setters are gone; the device-lost banner, the engine-stopped banner and the recovery path still open this page. | verify: ! grep -rn "DeviceAudioTab\|void setBufferFrames" lib test && /Users/Tomas/development/flutter/bin/flutter test test/settings test/looper/view
- Goldens for screens 01, 03 and 04 regenerated on the author's machine and compared against the pen. | verify: /Users/Tomas/development/flutter/bin/flutter test test/screenshots --update-goldens (author machine)
- Analyzer, Bloc lint, coverage. | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
- HARDWARE: on the 15.6" with the encoder only, change the buffer, apply, measure with a cable, and return to Stage. | verify: manual on device
```

### Part 8: update from USB (about 450 lines; helper, `lib/update`, `storage_repository`)

Pen 33: `w3lUKE`/`xlAif` (Load a USB package). Trunk-based. The helper is started with
`spawn_process`'s `startProcess` (#1373), as `install` already is in
`system_appliance_env.dart`. `install_bundle` keeps #1398's read-only `/boot` check (exit
3) for both verbs.

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

**Storage**

- A read hold on the source volume (D9): it requires the volume mounted (read-only is
  allowed), enters `GuardKind.transfer` on that volume, is counted by `leasesOn` so Eject
  refuses with `EjectRefused`, keeps shutdown waiting, and is named on the Storage page as
  "reading an update". Whether it is a new lease purpose that skips the writability check
  or a separate read-lease type is settled in the build; `acquire`'s write path is
  unchanged.
- The staging write also enters `GuardKind.transfer` on Internal, so a take recording to
  Internal refuses the copy and the copy refuses such a take (the guard table's same-volume
  rule).

**App**

- `UsbUpdateSource` lists `*.raucb` on each mounted volume (the root and
  `segno-updates/`) with Dart directory reads.
- Choosing a package:
  1. Refused under D3's take check.
  2. Checks free space on `/data` with `volumeSpace`: the bundle size plus 64 MB, or
     refuses with the space needed.
  3. Takes the read hold.
  4. Copies to `.<name>.<id>.part` in staging with `fsync`, then renames; the same
     part-file, classify and full-disk handling as `copyFile`.
  5. Releases the hold.
  6. Runs `install-file` through the #1367 launcher.
- `UpdateRepository.recover()` sweeps stale `.part` files and leftover bundles from
  staging at startup.
- Updates gains "Load from USB". Its list states: no drive ("Insert a USB drive with a
  Segno update."), reading the drive, no packages on the drive ("No update packages on
  {drive}."), and the package rows with a subtitle of version, size and file name. During
  the copy: progress with Cancel. Errors:
  - "This package could not be verified. Nothing was changed."
  - "Segno 0.9.0 is not newer than the installed 1.0.0."
  - "The USB drive was removed before the package was copied."
  - "Not enough space for this package. It needs {size} free."
- Success lands in Ready to install (Part 7).

```success-criteria
GOAL: A signed bundle on a USB stick, read-only or not, installs to the inactive slot exactly as an online update does; anything else is refused with nothing changed and no file left behind.
SUCCESS CRITERIA:
- install-file with a mock rauc reporting a newer version: same PROGRESS sequence and markers as install; staging emptied. | verify: bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_update_file_tests.sh
- Not newer, signature failure, and a path outside staging: the JSON errors above, no markers, rauc install never called. | verify: same
- Listing finds a.raucb at the root and segno-updates/b.raucb, ignores c.txt; each list state renders its text. | verify: /Users/Tomas/development/flutter/bin/flutter test test/update
- A read-only stick: the read hold is taken and the copy proceeds. | verify: /Users/Tomas/development/flutter/bin/flutter test packages/storage_repository test/update
- Eject during the copy is refused and the Storage page names "reading an update"; volume loss during the copy shows the removed-drive message and leaves no part file. | verify: same
- volumeSpace below size + 64 MB: refused with the space message before any byte is written. ENOSPC mid-copy: the part is deleted and the full message shows. | verify: same
- A stale .part and a leftover bundle in staging are deleted by recover() at startup. | verify: /Users/Tomas/development/flutter/bin/flutter test test/update
- A take recording to Internal refuses the copy with operationBusy(capture). | verify: same
- The helper is started through the #1367 launcher; no Process.start in lib/update. | verify: ! grep -rn "Process\.\(start\|run\)" lib/update
- New helper suite wired into the CI shell-tests step. | verify: grep -n run_update_file_tests .github/workflows/main.yaml
- Analyzer, Bloc lint. | verify: dart analyze --fatal-infos && bloc lint lib test packages
- HARDWARE: a stick holding a signed release bundle and an edited copy of it: the first installs and commits after reboot; the second is refused as unverified; the stick cannot be ejected during the copy. | verify: manual on device
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
- Known edge, recorded in #1284: a Save As that succeeds followed by a refused restart
  guard makes Retry run Save As again under the same name.
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
- It does not enter `GuardKind.calibration`. That is #1335's code and is left to its
  thread (§7, C10).

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

- **P3a:** loops kept through a buffer change, nothing heard during it, and the change
  kept after a reboot.
- **P1:** a build that throws before `runApp` and a build that crash-loops after its
  first frame each roll back by themselves; a good build is committed.
- **P5:** USB pull and replug: one strip on each screen, automatic restart.
- **P2 and P3b:** a cable measurement on chosen jacks, with silence on the other outputs,
  and an overdub that lines up afterwards.
- **P8:** a signed bundle and a tampered bundle on a stick; Eject refused during the copy.

Shipped parts, still unchecked on hardware according to their PRs:

- **P6 (#1284):** a Restart round trip, and a Restart into a staged slot.
- **P7 (#1287):** power pulled during an install.
- **P9 (#1286):** brightness on each panel; DDC/CI support per panel; idle dimming.
- **P11 (#1285):** recovery after a wrong password, and the no-internet state.
- **P12 (#1283):** serial and EDID facts, and the flasher record.

## 5. Pen write-back list

A shipped departure from the pen updates the pen (geometry and a `c/` note). Planning did
not edit the pen. Each item lands with the part that ships it.

For the open parts:

- 28: a `c/` note that Q1 declined 05–07 (amber chip, Reconnect audio) and Q2 declined 02
  (automatic measurement), pointing to `c/device-lost` in "02 EARLIER APPLICATION",
  which stays the rule. With Part 3a.
- 28/01: the locked sample-rate and max-loop reasons (D2), the chips drawn disabled; the
  Max loop length and Audio routing rows under the two columns; Measure's disabled and
  "Measuring…" states. With Parts 3a and 4.
- 28/03: the "Playback stops while measuring." line and the no-return state with Retry.
  With Part 3b.
- `STAGE / device-lost`: the banner text that names the device and says audio restarts,
  the boot-wait variant on the same strip, and the 7" echo with the same text. With Part
  5.
- 33: the `.raucb` names, the list states, the package subtitle, and the error rows for
  unverified, not-newer, removed and no-space. With Part 8.

For the shipped parts:

- 29/03: "If this fails, Segno reconnects to The Studio" (D13).
- 30: the Track display calibration targets drawn on the 7"; #1335 says it added this
  note. The "Display options" row (Q4).
- 32: the staged-update line on the Power card (D5).
- 33: the rollback notice (D8).

Whether the shipped parts' items other than #1335's were written back was not checked:
the pen is not in the worktree, and the PRs say the frames were not in the repo's copy.

## 6. Owner questions

Q1 to Q4 are answered. Q5 is open (2026-10-26 refresh) and holds Parts 3a and 4; it
does not hold Parts 1, 2, 5 or 8.

1. **Q1. Section 28's amber chip and explicit reconnect.** Answered 2026-10-19: not
   accepted; keep automatic reconnect and the red banner (D17, Part 5).
2. **Q2. Automatic measurement on the Scarlett loop channels.** Answered 2026-10-19: no;
   Measure is the cable test only (D4, Parts 3a and 3b).
3. **Q3. A sample-rate change while loops are recorded.** Answered 2026-10-19: lock the
   rate while any track holds material; no resampling (D2).
4. **Q4. The accepted Displays screen has no place for four existing controls.** Answered
   by default in #1286: they are in a "Display options" row under Dim while idle.
5. **Q5. An Apply that puts the effects over the budget.** The effects budget
   (`fxBudgetNs`) is 80 % of a frame's time at the running rate, less the engine's own
   cost per frame, which grows below 64-frame blocks. Raising the rate (48 to 96 kHz
   halves the time per frame) or dropping the buffer under 64 frames can leave chains
   that fit today over it, and today nothing refuses or warns. Options:
   - (a) Refuse the Apply inline, with the chips staying on the old value and a reason
     such as "Your effects need more processing than 96 kHz leaves. Remove some effects
     first." This extends the owner's admission rule (#887: refuse inline when a chain
     would not fit) to the audio settings.
   - (b) Apply, and say under the Apply row that the effects are over the budget and may
     click.
   - (c) Apply, and leave it to the effects screens' existing over-budget state.
   Default if unanswered: none; Parts 3a and 4 wait.

## 7. Review findings and what this revision does with them

Four reviews of the 2026-10-19 refresh. C = claims against code, F = failure modes,
G = design and scope, U = UX against the pen. Each was re-checked against `a37926236`.

| # | Finding | Decision | Where |
|---|---|---|---|
| C1 | Only a performance recording enters `GuardKind.capture`; a loop take holds no guard | Adopted: a loop-take check on `LooperState` for Apply and Measure | D3, P3a, P3b |
| C2 | `setMaxLoopMinutes` wipes loops; ASIO setters are dead | Adopted: max loop length through the same apply and lock; ASIO paths deleted | D2, P3a, P4, P2 |
| C3 | `AudioDevice.sampleRates` already exists from the `asio_*` fields | Adopted in the form G5 asks: no enumeration, the `asio_*` fields deleted | D18, P2 |
| C4 | `acquire` refuses a read-only stick | Adopted: a read hold that allows read-only volumes | D9, P8 |
| C5 | Deleting command 1 misses `le_engine_begin_latency_for_test` and two comments | Adopted | P2 |
| C6 | The `systemctl` stub answers any property with the next `NRestarts` line | Adopted: per-property stub, and a test that relies on it | P1 |
| C7 | #976 saw `NRestarts` 0 during a real crash loop | Adopted: `MainPID` compared too, heartbeat, crash-loop hardware check | P1 |
| C8 | The automatic measurement kinds are never reported on ALSA | Adopted: the automatic path is removed (Q2) | D4, P3a |
| C9 | `AudioLink.waitingForDevice` would clash with `AudioRecoveryStatus.waitingForDevice` | Withdrawn: Part 5 no longer adds `AudioLink` states (Q1) | P5 |
| C10 | `GuardKind.calibration` is never entered | Adopted for latency measurement. Declined for touch calibration here: that is #1335's code, outside this plan | P3b, P10 |
| C11 | About is not in `open()`; the ledger has no 140–143 entry; #1177 is still open; Part 6 omits the Save As edge | Adopted: all four corrected | §1, §0, §1 Storage, P6 |
| F1 | Max loop length wipes loops with no guard | Adopted (as C2) | P3a, P4 |
| F2 | The rate lock is checked only at edit; the negotiated rate can still clear | Adopted: re-check at confirm; keep-material reopen refuses before clearing | D2, P3a, P2, P3b |
| F3 | The harness skips transport and mix, so measuring silences playing loops | Adopted: Start test stops transport and backing, and the dialog says so | D4, P3b |
| F4 | The old record offset is replayed and then saved under the new key | Adopted: set the new key's offset or 0 after Apply; no saving outside a measurement | P3a |
| F5 | A stale DONE completes a new measurement | Adopted: a request id in command 140, echoed in the snapshot | P2, P3b |
| F6 | Part 8's copy has no free-space check, part file or sweep, and runs during a take | Adopted | P8 |
| F7 | A refused tryboot never reboots | Adopted: reboot after refusing an uncommitted tryboot only | P1 |
| F8 | The readiness check can pass for the wrong reason: refusal with the interface present, `endOfFrame` is not a raster, no readout check, one-shot | Adopted: all four | D7, P1 |
| F9 | `install-file` would fork | Adopted: Part 8 waits for and uses the #1367 launcher | D9, P8 |
| F10 | Rate enumeration on ALSA hits EBUSY on the open Scarlett | Adopted by dropping enumeration (G5) | D18, P2 |
| F11 | A failed Apply whose rollback fails disarms the supervisor | Adopted: the previous config stays pinned and supervised | D17, P5 |
| F12 | Explicit reconnect mid-performance needs two screen actions | Declined: Q1 keeps automatic reconnect, so no action is needed | P5 |
| G1 | Split a trunk-based part that fixes the live bugs without Part 2 | Adopted | P3a |
| G2 | Max loop length through the draft; delete the ASIO code | Adopted | P3a, P4, P2 |
| G3 | Part 8: no write lease, or a read hold; after #1367 | Adopted: read hold | D9, P8 |
| G4 | Consider `Type=notify` and `sd_notify` through FFI | Adopted: replaces the marker; no watchdog, so a slow app is never killed mid-performance | D7, P1 |
| G5 | Drop device-rate enumeration | Adopted | D18, P2 |
| G6 | Ask the owner about automatic measurement before Part 3 | Answered (Q2) | §0, D4 |
| G7 | Part 5 reverses the 2026-08-26 banner decision; ask the owner | Answered (Q1); Part 5 keeps the decision | §0, D17, P5 |
| G8 | Stacks at most two deep | Adopted | §3 |
| U1 | Part 5: one bar per cause; the readout text | Adopted: the boot wait on the red strip, no toast beside it, the same text on the 7" | P5 |
| U2 | Write the `c/device-lost` decision back to section 28 | Adopted | §5 |
| U3 | Part 4: Measure stops the transport; the result goes in the latency row | Adopted | D4, P3b, P4 |
| U4 | Reuse `audioRefusedConfig` for a failed Apply | Adopted | D1, P3a, P3b |
| U5 | Locked rate chips disabled, not hidden | Adopted | D2, P3a, P4 |
| U6 | Max loop length and Audio routing rows are not in the pen | Adopted: written back | P4, §5 |
| U7 | Reconnect and Measure states | Adopted for Measure; Reconnect is not built (Q1) | P3b, P4 |
| U8 | Part 8: list states, package subtitle, Storage page purpose | Adopted | P8 |
| U9 | Reuse existing strings | Adopted: the ARB entries listed in Part 4; `operationBusy` for refusals | P3a, P4 |
