# Running Segno on the console (Raspberry Pi 5)

The floor console is a Raspberry Pi 5 booting the Yocto image in
[`deploy/yocto`](../deploy/yocto/README.md) from NVMe. It runs one program:
[ivi-homescreen](https://github.com/toyota-connected/ivi-homescreen), installed
as `/usr/bin/segno`, which draws both panels straight over DRM/KMS with one
Flutter engine per screen. There is no compositor, no GTK and no Linux desktop
build; macOS is the development host. The app bundle is built in a container
([`deploy/rpi/README.md`](../deploy/rpi/README.md)), and the image installs it
at `/opt/segno`.

Why ivi-homescreen: after the #1318 bench it replaced the GTK runner under
Weston, with lower idle CPU and memory and no per-frame CPU copy (owner's
call, #1330). The numbers and the scope are in
[`docs/plan/2026-10-14-ivi-only-appliance-plan.md`](plan/2026-10-14-ivi-only-appliance-plan.md).

## How the app starts

`segno.service` runs `segno-kiosk-launch`, which sets `HOME=/data`, the ALSA
settings and the RT environment, and starts `/usr/bin/segno` with
`/etc/segno/homescreen.toml`. That file has one `[[view]]` per panel:

| Screen | Panel | Connector | Notes |
|---|---|---|---|
| `main` | 15.6″ 1080p touch | `HDMI-A-1` | the stage and every page |
| `readout` | 7″ 1024×600 touch | `HDMI-A-2` | `pixel_ratio = 1.6`; the selected-track readout |

- **Roles.** Each engine learns its role from `--segno-screen=`. The two talk
  through the Dart VM they share (`lib/visualizer/screen_link.dart`), and the
  readout stays blank until the main screen shows it.
- **Renderer.** Both views pass `--enable-impeller=false`: Impeller draws the
  Material icon font as empty boxes on this stack (#897), so the engines use
  Skia.
- **Touch.** The readout's view names its touch controller with
  `touch_device`; touch that matches no view goes to the main screen.
- **No seat.** Both views set `no_seat = true` and open the DRM master and the
  input devices themselves. `seatd` is installed with ivi-homescreen's libseat
  but not enabled.
- **A unit wired the other way round.** Swap the two `drm_connector` values in
  `/etc/segno/homescreen.toml` and restart `segno.service`. The Displays page
  reads the connectors from the same file, so brightness follows.

`segno.service` restarts the app 3 s after it exits, and gives a stop 15 s
before it aborts the process for a core dump.

## Logs

The app writes a rotating logfile under the persistent data partition
(`HOME=/data` → **`/data/log/segno.log`**). Stderr goes to the journal:

```bash
tail -f /data/log/segno.log
journalctl -u segno.service -b --no-pager
journalctl -u segno.service -f
```

## Profiling

For DevTools on the console, see
[`deploy/rpi/README.md`](../deploy/rpi/README.md#profiling-the-ui-on-real-hardware).

Every image also ships `segno-prof`, which samples a thread's stack from
outside without stopping the app:

```bash
# Folded stacks, busiest first: 1000 samples, 10 ms apart. Pass the tid of
# the thread to sample; the default is the main thread, which is idle under
# ivi-homescreen. Each engine runs its Dart UI isolate on an io.flutter.ui
# thread, the main screen's first.
segno-prof stack $(pidof segno) <tid>
```

Only that thread is paused, for microseconds per sample, and it is attached
only while a sample is taken.

Experimental images also run `segno-profile.service`, which writes a CSV row
of CPU per thread role (main, UI, raster, real-time), memory and load every
minute to `/data/perf/metrics-<date>.csv`, and a stack profile of the main
screen's UI thread every 15 minutes to `/data/perf/stacks-<time>.folded`. The
CSV columns are explained at the top of `/usr/bin/segno-profile-recorder`.
Experimental builds keep the Dart symbol table in `libapp.so`, so stack frames
inside Dart code carry their function names; production builds are stripped.

## Persistent `/data` size

The flashable WIC image seeds the `data` partition at **2 GiB** so the image
stays small. On first boot (and after an OTA that includes it) the
`segno-data-grow` oneshot expands that partition — and its MBR extended
container — to fill the rest of the drive, then runs `resize2fs`. No reflash
is required to claim a larger drive: install the update, reboot, and check:

```bash
df -h /data
journalctl -u segno-data-grow.service -b --no-pager
```

Sessions and exports live under `/data/Documents/{sessions,exports}/` and survive
both OTA and the grow (the grow never wipes the filesystem).

## Power button

The rear button is the Pi 5's own J2 PWR pads (console J8 → J9). It is not a
GPIO and not `dtoverlay=gpio-shutdown`. The kernel exposes it as `gpio-keys`
`KEY_POWER` on the input device named `pwr_button`.

- **Short press.** The app grabs that node (`EVIOCGRAB`), so the embedder's
  own input handling does not also receive the key. Every press opens Power
  options (the same card as Settings' Power row): "Playback will stop and your
  session will be saved", the session name, and Cancel / Restart / Shut down.
  Both actions run one path: stop the transport, flush settings, save the
  session (Save As first if it has no name), wait for storage leases, then
  `segno-update-ctl reboot` or `poweroff` (`systemctl start poweroff.target` —
  this image has no logind), showing "Restarting" or "Safe to switch off" and
  darkening the pedal. A failed save keeps Segno on ("Segno is staying on":
  Stay on / Retry); there is no way to halt without saving. With an update
  staged, the card says it installs during the restart, and Updates' Install
  and restart goes through the same path. A take or transfer in flight
  (record, overdub, count-in, punch-tail, performance capture, USB copy or
  eject): Keep playing only — stop the take, then press again. A second press
  while that UI is up is ignored.
- **Long press (~5 s).** The PMIC's uninterceptable force-off. Use it if the
  UI is wedged. It does not flush, save, or show goodbye.

A missing `pwr_button` node (dev image without the DT overlay): the app runs
and the listener stays idle; long-press still force-offs.

## Control Center (WiFi / brightness)

Swipe down the settings tray on the main touchscreen. On the appliance these
tiles talk to host helpers (same pattern as OTA's `segno-update-ctl`):

| Helper | Role |
|--------|------|
| `/usr/bin/segno-wifi-ctl` | scan / join / disconnect / forget (`nmcli` / NetworkManager) |
| `/usr/bin/segno-brightness-ctl` | DDC/CI brightness via `ddcutil` VCP 0x10 |
| `/usr/bin/segno-touch-ctl` | per-screen touchscreen calibration matrix (`get` / `try` / `set` / `reset` / `restore` / `apply`) |

WiFi is owned by **NetworkManager** (eth0 + wlan*). `systemd-networkd` is
masked on the appliance image so the two managers do not fight. The unit
announces itself as **`segno`** on the router/AP client list and the SSH
prompt (the image hostname, set in `deploy/yocto/kas-segno-common.yml`; older
images announced the board name, `raspberrypi5`).

**On-device checklist** (after flashing an image that includes the helpers):

```bash
# WiFi
segno-wifi-ctl status
segno-wifi-ctl scan
printf '%s\n' 'your-psk' | segno-wifi-ctl connect 'YourSSID'   # key on stdin, never argv
ip -4 addr show wlan0
segno-wifi-ctl disconnect

# Brightness (needs a DDC/CI-capable HDMI panel)
segno-brightness-ctl supported
segno-brightness-ctl get
segno-brightness-ctl set 40
segno-brightness-ctl set 80
```

In the app: Settings → Network (join a network) → Displays (drag brightness
and confirm the panel dims). Bluetooth is retired (#1199): the image ships no
BlueZ. If `supported` is false for brightness, the slider still persists but
does not change the panel — note that for a gamma follow-up.

## Touchscreen calibration

The app measures it: Settings → Displays → Calibrate touch, once per screen.
Tap each target; the app then applies the new calibration without storing it
(`segno-touch-ctl try`) and starts a test with a countdown. Keep stores it
(`set`); anything else puts the stored one back (`restore`). A calibration that
was never kept is also gone after a power cycle, since only stored matrices
are applied at boot.

`segno-touch-ctl` stores one libinput matrix per screen at
**`/data/touch/main`** and **`/data/touch/readout`**, on the persistent
partition, because a RAUC A/B update replaces the whole rootfs and a matrix
written into `/etc` is lost on the next OTA. From those files it writes
`/etc/udev/rules.d/98-segno-touch-calibration.rules`, which matches each
touchscreen by name: the readout's is the one whose name contains its
`touch_device` in `homescreen.toml`, and every other touchscreen belongs to the
main screen.

libinput reads the matrix only when a device is added, so `try`, `set`,
`reset` and `restore` remove and re-add that screen's touchscreen, and the app's libinput picks the
new matrix up. At boot, `segno-touch-persist.service` runs `segno-touch-ctl
apply` before `segno.service`, so the app opens its input devices already
calibrated.

```bash
segno-touch-ctl get main
segno-touch-ctl get readout
segno-touch-ctl reset readout    # undo a bad calibration
```

## Audio interface

The image has no PipeWire, JACK or PulseAudio. The launcher sets
`SEGNO_ALSA_ONLY=1`, so the engine opens the interface directly through ALSA
and owns it while the app runs; its audio thread runs at real-time priority
80.

- **Select the interface as both input and output** in Settings → Audio.
- **Latency calibration is per (device, sample rate, buffer).** Measure
  round-trip latency *after* choosing the buffer, and measure again after
  changing it. The measurement needs a physical out→in loopback cable.
- **Channel count can depend on the sample rate.** USB interfaces switch
  their USB alternate setting by rate: a Clarett+ 8Pre has 18 in / 20 out at 44.1/48 kHz, 14/16 at
  88.2/96 kHz and 10/10 at 176.4/192 kHz.

### Focusrite (Scarlett/Clarett) and the `scarlett2` driver

There is no Focusrite Control on Linux. The `snd-usb-audio` **`scarlett2`**
mixer controls routing instead, and the interface keeps that routing in its
own flash, so a reset or another unit brings different defaults with it.
Signal on the wrong output, or none, is usually this routing, not Segno: read
it first.

```bash
amixer -c USB controls | grep -E 'Analogue Output|Mixer Input|PCM .* Capture'
amixer -c USB get 'Analogue Output 01'
```

- **Outputs** may be fed from an internal **Mix** rather than USB playback
  (`Analogue Output 01 ← Mix A`), so app audio is missing until the output is
  set to the PCM channel: `amixer -c USB cset numid=<n> "PCM 1"`.
- **Capture** defaults are usually right (`PCM 01 ← Analogue 1`, …); check the
  `PCM NN Capture Enum` controls.
- **Monitor level, input gain and 48 V phantom power** are hardware controls on
  most models. A weak input that the gain knob barely changes is the classic
  sign of a condenser mic with 48 V off.

To check the input level without Segno, stop the app first, since it holds the
device:

```bash
systemctl stop segno
arecord -D hw:USB -c <channels> -r 48000 -f S32_LE -d 4 /data/in.wav
systemctl start segno
```

## Hardware (enclosure, protection, power, BOM)

The console's hardware design lives under [`hardware/`](../hardware):

- **BOM / shopping list:** [`hardware/segno_console_shopping_list.md`](../hardware/segno_console_shopping_list.md)
  (Amazon-sourced, decision 2026-08-17) — Pi 5 + active cooler, main
  touchscreen, **7″ HDMI** display, USB interface, footswitches, EC11 encoder,
  WS2812 ring + indicator pills, the 20 V PD power chain, and the console board
  v2's generated BOM (`hardware/kicad/fab/segno_console_board_bom.csv`).
- **Power/thermal budget + enclosure intent:**
  [`hardware/console/README.md`](../hardware/console/README.md) — the per-rail
  power budget and the active-cooling requirement.

**7″ display decision: HDMI (not DSI).** Both screens are HDMI, so they
enumerate as `HDMI-A-1` / `HDMI-A-2` and `homescreen.toml` names each view's
connector. DSI's only gain, freeing an HDMI port, is moot here.

## On-device checklist

These cannot be verified in CI (no display, no audio). Tick them on a
console:

- [ ] Cold boot lands on the app with **15.6″ = main UI, 7″ = readout**, with no
      keyboard or mouse.
- [ ] Material icons render correctly (not empty boxes) on both screens.
- [ ] Touch on each panel lands on its own screen; both panels calibrate from
      Settings → Displays, and the calibration survives a reboot.
- [ ] The screen mapping is stable across **≥5 reboots**.
- [ ] With the 7″ unplugged, the Displays page shows it as "Not connected".
- [ ] Killing the app: `segno.service` restarts it and both screens come back.
- [ ] **Hard power-cut ×20 mid-session:** the console boots back to the app
      each time and `/data` mounts clean; record results here.
- [ ] **≤10 ms round-trip audio latency** measured on the chosen USB interface
      with a loopback cable; record the figure, rate and buffer here.
- [ ] **≥2 h thermal soak** (audio + both screens + GPU, closed enclosure):
      `vcgencmd get_throttled` stays `0x0`, no xrun-rate regression; record
      results here.
- [ ] **Re-run the ≥2 h audio soak on an image with the persistent journal**
      (#438 / PR #810): journald now writes to the same ext4 + jbd2 journal on
      `/data` as the recorder's takes, so the soak must show no new xruns or
      write-latency spikes with logging active. Until this passes on hardware,
      the persistent-journal change is wired but **not verified**
      (`autonomy:blocked-verify`).
- [ ] Stompable footswitch panel survives stage-abuse testing.
