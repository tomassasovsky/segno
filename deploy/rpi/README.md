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

1. Build the release bundle:
   ```bash
   flutter build linux --release --target lib/main_production.dart
   ```
   segno builds only for the console now: no on-screen tracks toolbar (the
   foot pedals drive transport/mode/clear) and a layout fixed to the 16″
   panel. (The `build-linux-arm64` CI job guards that this compiles for
   arm64.)

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

The shipped bundle is **release-mode AOT** on the release Flutter engine, with no
Dart VM service, so DevTools cannot attach to it, and the Yocto image is a pure
runtime with no `flutter`/`dart`/`gcc`/`ninja`, so it cannot build a profile
bundle itself.

1. Build a profile bundle. It carries the profile engine
   (`lib/libflutter_engine.so`) for the Flutter release the image ships, because
   a profile snapshot runs only on a profile engine. Either locally:
   ```bash
   deploy/rpi/build/build-arm64-bundle.sh --profile
   ```
   which writes `build/appliance/profile-bundle`, or from the
   `appliance-profile-bundle` workflow
   ([`.github/workflows/appliance-profile.yaml`](../../.github/workflows/appliance-profile.yaml)),
   which runs on demand or on any push to a `perf/**` branch:
   ```bash
   gh run download <run-id> -n segno-appliance-profile -D /tmp/segno-profile
   ```
2. Run it on the device and tunnel the VM service to your workstation:
   ```bash
   deploy/rpi/profile-on-device.sh /tmp/segno-profile
   ```
   The script stages the bundle under `/data/profile`, so the release install at
   `/opt/segno` is left alone, and runs it through the shipped launcher as the
   transient unit `segno-profile`, with the same environment and RT limits as
   `segno.service`. It stops `segno.service` for the duration and starts it
   again on exit however the run ends, and forwards the VM service to
   `127.0.0.1:8181` for DevTools. Both screens' isolates are on that one port.

**Read the result as a split, not a score.** UI thread over budget points at the
snapshot poll cadence and `context.watch` fan-out; raster thread over budget
points at missing `RepaintBoundary`s, the per-sample waveform rects, and card
elevation. Which half is over budget decides the work — see #638.

**Check the appliance is in a sane state first.** A full `/data`, a capture left
running, or a stale bundle all make the numbers measure something other than the
UI. `df -h /data` before you start.
