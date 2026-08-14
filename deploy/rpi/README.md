# Segno floor-console kiosk deployment (Raspberry Pi 5)

Boots the Pi straight into Segno full-screen across both displays — 16″ main UI,
7″ waveform — under the **labwc** Wayland compositor chosen in Part 1. No
keyboard or mouse.

> **Status: unverified on hardware.** These units and scripts are written from
> the Part 5 plan but have not been brought up on a real Pi 5 + panels. The real
> acceptance gates — cold boot to the right panels, display pinning stable across
> ≥5 reboots, and usable per-panel scale — must be checked on hardware. See
> [`docs/RUNNING_ON_RPI.md`](../../docs/RUNNING_ON_RPI.md).

## Files

| File | Goes to | Purpose |
|---|---|---|
| `segno-kiosk.service` | `/etc/systemd/system/` | Boots the kiosk on tty1, respawns on crash |
| `boot-integrity-check.sh` | (unit `ExecStartPre=+`, root) | fsck + mount the writable data partition |
| `start-kiosk.sh` | (unit `ExecStart`) | Execs labwc, or shows the "needs attention" screen |
| `compositor/labwc/autostart` | `~/.config/labwc/autostart` | Pins displays, then launches the app |
| `compositor/labwc/rc.xml` | `~/.config/labwc/rc.xml` | Chromeless, maximized, no kill chord |
| `pin-displays.sh` | (run from autostart) | Deterministic output pinning by name |
| `profile-on-device.sh` | (run from your workstation) | Runs a profile bundle + tunnels the VM service for DevTools |
| `overlayfs/README.md` | — | Read-only root + writable data partition setup |

## Install

1. Build the release bundle with **console/kiosk mode** on:
   ```bash
   flutter build linux --release --target lib/main_production.dart --dart-define=SEGNO_CONSOLE=true
   ```
   `SEGNO_CONSOLE=true` hides the on-screen tracks toolbar (the foot pedals
   drive transport/mode/clear) and tightens the layout for the fixed 16″ panel
   — see [`lib/common/console_mode.dart`](../../lib/common/console_mode.dart). Omit
   the define for a normal desktop build. (The `build-linux-arm64` CI job guards
   that this compiles for arm64.)

   From a Mac (which cannot build a Linux bundle natively), run the containerized
   arm64 build instead — it wraps the exact command above and can `rsync` the
   result to the Pi:
   ```bash
   deploy/rpi/build/build-arm64-bundle.sh --deploy pi@<host>
   ```
   See [`build/build-arm64-bundle.sh`](build/build-arm64-bundle.sh) and
   [`build/Dockerfile.arm64`](build/Dockerfile.arm64).
2. Enable the labwc Wayland compositor (Pi OS default on Pi 5; confirm with
   `wlr-randr`, which must list outputs — see `docs/RUNNING_ON_RPI.md`).
3. Install the kiosk (systemd unit + labwc config) with the one-command installer,
   which sets it up for **your** user — no `pi` user required:
   ```bash
   deploy/rpi/install-kiosk.sh
   ```
   It substitutes your user/home/uid into the unit, copies the compositor config
   to `~/.config/labwc/`, sets the Pi to boot to console (so the kiosk owns the
   display), and enables the service. The boot integrity check is **opt-in** — a
   stock single-partition SD card boots straight to the app; set `SEGNO_DATA_DEV`
   only if you follow the read-only-root + writable-data-partition setup in
   [`overlayfs/README.md`](overlayfs/README.md).
4. **Edit `pin-displays.sh`** for your wiring: run `wlr-randr` to get the real
   connector names (e.g. `HDMI-A-1`, `HDMI-A-2`, or `DSI-1`) and set
   `SEGNO_MAIN_OUTPUT` / `SEGNO_WAVE_OUTPUT` and the per-panel scales.
5. Reboot. The unit starts labwc, which pins the displays and launches Segno.

## Display mapping & fallbacks

- **Pinning** is by connector name in `pin-displays.sh`, so the 16″ and 7″ never
  swap. The app's waveform second window lands on the secondary output; verify
  the actual window→output placement on hardware and adjust positions if needed.
- **Second-window failure is surfaced**, not silent: if the waveform window does
  not become ready, the app shows an operator-visible banner
  (`app_waveformWindowFailed_banner`).
- **Single display**: if only one display is connected, the app skips the
  waveform window and shows a notice (`app_singleDisplay_banner`) instead of a
  half-blank console. The Pi entrypoint wires the real display count
  ([`run_segno.dart`](../../lib/app/run_segno.dart)).
- **Per-display scale** is set with `wlr-randr --scale` in `pin-displays.sh`.
  Final values depend on the Part-6 HDMI-vs-DSI panel choice; tune on hardware.

## Profiling the UI on real hardware

The shipped bundle is **release-mode AOT** — no `kernel_blob.bin`, no Dart VM
service — so DevTools cannot attach to it, and the Yocto image is a pure runtime
with no `flutter`/`dart`/`gcc`/`ninja` so it cannot build a profile bundle
itself. macOS cannot cross-compile a Linux arm64 bundle either.

The containerized builder above (`build/build-arm64-bundle.sh`) is **release-only
today** — `segno-build.sh` hardcodes `flutter build linux --release`. Teaching it
a profile mode is the better long-term answer and would drop the CI round-trip;
until then the arm64 CI runner is the path that needs no local Docker.

1. Get a profile bundle from the `appliance-profile-bundle` workflow
   ([`.github/workflows/appliance-profile.yaml`](../../.github/workflows/appliance-profile.yaml)),
   which runs on demand or on any push to a `perf/**` branch:
   ```bash
   gh run download <run-id> -n segno-linux-arm64-profile -D /tmp/segno-profile
   ```
2. Run it on the device and tunnel the VM service to your workstation:
   ```bash
   deploy/rpi/profile-on-device.sh /tmp/segno-profile
   ```
   The script stops `segno.service` for the duration and restarts it on exit
   however the run ends, stages the bundle under `/data/profile` so the release
   install at `/opt/segno` and the ~1 GB rootfs are both left alone, and
   forwards the VM service to `127.0.0.1:8181` for DevTools.

**Read the result as a split, not a score.** UI thread over budget points at the
snapshot poll cadence and `context.watch` fan-out; raster thread over budget
points at missing `RepaintBoundary`s, the per-sample waveform rects, and card
elevation. Which half is over budget decides the work — see #638.

**Check the appliance is in a sane state first.** A full `/data`, a capture left
running, or a stale bundle all make the numbers measure something other than the
UI. `df -h /data` before you start.
