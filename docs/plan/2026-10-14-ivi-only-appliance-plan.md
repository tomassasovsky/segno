# ivi-homescreen as the only appliance embedder (#1330)

**Decision (owner, 2026-10-14).** After the #1318 bench, ivi-homescreen becomes
the only embedder on the appliance: Flutter straight to DRM/KMS, one engine per
screen, no compositor. What the GTK/Weston path provided is ported first, and
then everything GTK, Weston and Wayland is removed. This settles the
display-stack question in #897.

The bench numbers are on #1318:
- **CPU:** idle at 96 kHz/64 is 12.5% of one core, against a median of 13.7% on GTK.
- **Memory:** idle RSS is 287 MB, against 402 MB.
- **Rendering:** no per-frame CPU copy (#1302).
- **Boot:** the same as GTK.
- **Stops:** clean after the two spike fixes: 0 core dumps in 211 stops.

## Scope calls (owner, 2026-10-14)

- **macOS dev host:** the 7" readout window goes. It ran on
  `desktop_multi_window`, the plugin GTK used, and `window_manager` and
  `screen_retriever` go with it. macOS dev runs the main screen only, and the
  readout is developed on the console.
- **`linux/` is deleted**, so there is no Linux desktop build.
  - The appliance bundle comes from `flutter assemble` (target
    `release_bundle_linux-arm64_assets`, the same one `flutter build linux` ran
    for these files) plus the engine's own CMake project
    (`packages/segno_engine/src`).
  - It was verified in an arm64 container on Flutter 3.47.5 with no `linux/`
    present. The output was `lib/libapp.so` (11 MB), `flutter_assets/`
    (16 MB) and an empty native-assets manifest.
- **On-device DevTools profiling is ported**, not dropped.
- **The Pi 4 image goes.** ivi is Pi 5 only.

## What the GTK path provided, and where it lands

| Capability | GTK path | ivi | Part |
|---|---|---|---|
| Two screens, readout placement, scale | `desktop_multi_window`, weston.ini app-ids, `scale=3` | `homescreen.toml`, screen link, `pixel_ratio = 1.6` | done (#1318) |
| Readout touch, off/on, cursor hidden, Skia | channel, window close, Flutter + weston patch, `main.cc` | screen link, `hide`/`show`, `disable_cursor`, `--enable-impeller=false` | done |
| Touch → screen mapping | `97-segno-touch-output.rules` (`WL_OUTPUT`) | `touch_device` + first-view fallback | done |
| DRM master after plymouth | weston drop-in | `segno.service` ordering | P1 |
| USB runtime dirs (`/run/segno/usb`, `/run/media/segno`) | `segno-runtime.conf`, GTK-only install | always installed | P1 (live bug on the spike image) |
| **Per-panel DDC brightness, "Not connected"** | `DisplayOutputs` reads the connector map from `weston.ini` | reads it from `homescreen.toml` | P2 |
| **Touch calibrator** | `weston-touch-calibrator` + helper | in-app, pen section 30 | P3 |
| **On-device DevTools** | profile GTK bundle under weston | profile engine + profile bundle on ivi | P4 |
| Startup spacing, wait-wayland, timeout guard, GPU present, GLib census (#970, #1299, #1302) | runner and launcher workarounds | not applicable | removed (P1, P5) |

## Parts

Stacked PRs into `claude/segno-integration`, each green and review-clean
before the next merges.

### P0: land the spike (#1331, closes #1318)
The bench-verified spike and its fixes, merged into the trunk.

### P1: the image and the build
- **Bundle build:** one container (`deploy/rpi/build/Dockerfile`, no GTK) and
  one script (`segno-build.sh`).
  - It runs `flutter assemble` for the app and CMake for the engine, and
    writes `build/appliance/bundle`.
  - `FLUTTER_VERSION` has no default; it comes from
    `flutter-engine-version.inc` everywhere.
  - `Dockerfile.arm64` and its inline copy of the script are deleted, and
    `build-arm64-bundle.sh` uses the shared image.
- **CI:**
  - `build-linux` and `build-linux-arm64`, which built the GTK runner and
    checked its interposers, become one `appliance-bundle` job. It builds the
    real bundle on arm64 and runs FFI parity on it.
  - `appliance-release.yml` loses its `embedder` and `board` inputs.
- **Image:**
  - `segno-kiosk-image` inherits `core-image` instead of `core-image-weston`.
    The latter requires the `wayland` distro feature.
  - `DISTRO_FEATURES` drops `x11` and `wayland`. Expect a near-full rebuild
    the first time.
  - `seatd` is no longer enabled. It stays a build dependency of
    ivi-homescreen, for libseat.
- **Layer:**
  - The `SEGNO_EMBEDDER` switch goes. The launcher and `segno.service` take
    what the ivi tail and drop-in held.
  - The weston recipes and their patches, `weston.ini`, the plymouth weston
    drop-in, `segno-wait-wayland`, the `WL_OUTPUT` rules and the weston
    calibration hand-off (helper, `segno-touch-apply.*`, the weston chown) all
    go.
  - `segno-runtime.conf` keeps only its `/run/segno` lines and is always
    installed.
  - `kas-segno-rpi4.yml` and `kas-segno-rpi5-ivi.yml` go.
- **Tests:**
  - The kas cmdline assertions from `run_hdmi_hpd_tests.sh` move to
    `deploy/yocto/test/run_kernel_cmdline_tests.sh`. The `D` force-on also
    stops a missing 7" from making ivi-homescreen exit at boot.
  - The weston and Wayland tests go.
- **`linux/` is deleted.**

### P2: Dart
- **Readout:** remove the GTK/macOS readout path. That is
  `DesktopMultiWindowWaveformService`, `runWaveformWindow` and its placement,
  `waveform_window_args`/`_channel`, `SEGNO_WAVEFORM_OPEN_DELAY_MS` and the
  `displayCount` plumbing.
  - The appliance always passes `--segno-screen`. With no screen named (the
    macOS dev host) the app runs the main screen with
    `NoopWaveformWindowService`.
- **Window chrome:** `window_chrome.dart` goes whole, with the `F` key. Its
  cursor auto-hide is the embedder's job on the appliance
  (`disable_cursor = true` in `homescreen.toml`), and the macOS dev host is an
  ordinary window.
- **Dependencies:** drop `desktop_multi_window`, `window_manager` and
  `screen_retriever` from `pubspec.yaml`, and regenerate the macOS plugin
  registrant.
- **`DisplayOutputs`:** read the role→connector map from
  `/etc/segno/homescreen.toml`: each view's `--segno-screen=` and its
  `drm_connector`. `weston.ini` parsing goes.
  - With that, `DisplayBrightnessCubit` probes per-panel DDC/CI again, and
    `DisplayPresenceCubit` reports an unplugged panel.

### P3: the touch calibrator (pen section 30, "Displays & touch calibration")
- **Flow,** from Settings > Displays > "Calibrate touch", per screen:
  1. 5 targets ("Tap the center of each target", "1 of 5").
  2. A test step with 3 targets and a 30 s countdown that reverts on timeout.
  3. Restart / Keep calibration. "Previous calibration stays available."
- **The 7":** its targets are drawn on the 7" itself, through the screen
  link. The main screen shows the page and progress.
- **The matrix:**
  - The app sees touches already transformed by the current matrix C. It
    fits the affine A that takes the observed points to the targets, in
    normalized screen coordinates, and stores A·C.
  - `segno-touch-ctl` becomes per device, keyed by the libinput device name
    in `homescreen.toml`'s `touch_device`, with a catch-all for the main
    panel. Today one matrix applies to every touchscreen, and the console now
    has two.
- **Applying it:** libinput reads `LIBINPUT_CALIBRATION_MATRIX` when a device
  is added, so applying means re-adding the device, not a udev `change`.
  Proving that ivi-homescreen's libinput backend picks up a remove/add is the
  first task of P3. If it doesn't, the app restarts itself after Keep.

### P4: DevTools profiling on ivi
- **Engine:** the meta-flutter profile engine SDK, matching
  `FLUTTER_ENGINE_COMMIT`, fetched to `/data/profile` rather than shipped in
  the image.
- **Bundle:** a profile bundle from `segno-build.sh` (a profile-mode
  `flutter assemble`).
- **Launch:** `profile-on-device.sh` stops `segno.service` and runs
  `/usr/bin/segno` with a profile `homescreen.toml` (`bundle=/data/profile`,
  VM service enabled) and `LD_LIBRARY_PATH` set to the profile engine.
- **Workflow:** `appliance-profile.yaml` builds the profile bundle with the
  shared container.

### P5: the rest
- **Profiler:** `segno-prof gsources`, `/run/segno/main-context` and the
  recorder's GLib columns go. The recorder header names the columns per
  thread role.
- **Pi OS kit:** the `deploy/rpi` Pi OS kiosk files (labwc, wlr-randr) go.
- **Docs:** `RUNNING_ON_RPI.md`, `APPLIANCE_INTEGRATION.md`,
  `HARDWARE_VALIDATION.md` and `RUNNING_ON_LINUX.md` are rewritten or removed,
  plus the stale code comments that name weston or GTK.
- **Issues:** close #1302 and #970 as obsolete, and the weston parts of #853
  and #821.

## Risks

- **The first image build after P1 is near-full,** because `DISTRO_FEATURES`
  changes. The self-hosted runner's 40 GB pre-flight applies.
- **Mesa without x11 and wayland** still has to provide GBM/EGL for DRM. That
  is the platform ivi-homescreen uses, and P1's image build is what proves it.
- **The live calibration apply** is the unknown in P3, with a stated fallback.

## Verification

- **Every part:** `flutter test`, `dart analyze` and `bloc lint`, plus the
  appliance shell tests and the `appliance-bundle` CI job.
- **P1:**
  - the bundle built locally with `build-arm64-bundle.sh`;
  - an image built and installed on the console;
  - both screens drawn;
  - USB runtime dirs present;
  - touch calibration restored from `/data` at boot;
  - 15 restarts with no core dumps.
- **P2:** brightness probed per panel, and "Not connected" shown when the 7"
  is unplugged.
- **P3:** both panels calibrated on the console, the test step's revert
  exercised, and the calibration surviving a reboot.
- **P4:** DevTools attached to the main screen's engine on the console.
