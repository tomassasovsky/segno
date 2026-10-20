# Segno appliance — Yocto image

The image the floor console boots: a lean Yocto build running the **prebuilt**
aarch64 app bundle on [ivi-homescreen](https://github.com/toyota-connected/ivi-homescreen),
which drives both HDMI outputs straight over DRM/KMS with no compositor, one
Flutter engine per screen. RAUC A/B updates go over the Raspberry Pi firmware's
`tryboot`. There is no GTK, no Weston and no Wayland (#1318, #1330).

The board is the **Raspberry Pi 5**, booting from NVMe. The Pi 4 image is gone.

| kas project | MACHINE | Boots from | `SEGNO_BOOT_DISK` |
|---|---|---|---|
| `kas-segno-rpi5.yml` | `raspberrypi5` | NVMe in the M.2 slot | `nvme0n1` |

What is not specific to the board lives in **`kas-segno-common.yml`**. The boot
device is a single variable threaded through the WIC layout, the RAUC slot
table and the per-slot
`cmdline.txt`, so those three cannot drift apart.

Origin: the Tier 3a spike ([#284](https://github.com/tomassasovsky/segno/issues/284),
child of #271). Pi 5 + NVMe: [#799](https://github.com/tomassasovsky/segno/issues/799).
Plans: [`docs/plan/2026-07-23-spike-tier3a-yocto-gtk-plan.md`](../../docs/plan/2026-07-23-spike-tier3a-yocto-gtk-plan.md)
(the original GTK/Weston image),
[`docs/plan/2026-10-13-spike-ivi-homescreen-plan.md`](../../docs/plan/2026-10-13-spike-ivi-homescreen-plan.md)
and [`docs/plan/2026-10-14-ivi-only-appliance-plan.md`](../../docs/plan/2026-10-14-ivi-only-appliance-plan.md)
(ivi-homescreen, now the only image).

## What's here

```
kas-segno-common.yml        shared: poky + meta-openembedded + meta-raspberrypi + meta-rauc (walnascar, commit-pinned)
kas-segno-rpi5.yml          raspberrypi5, NVMe (+ dtparam=pciex1)
meta-segno/
  conf/layer.conf
  classes/tryboot-cmdline.bbclass                    rewrites root= per boot slot inside the .wic
  wic/segno-tryboot.wks.in                           A/B layout template (${SEGNO_BOOT_DISK})
  recipes-core/images/segno-kiosk-image.bb           core-image + our bundle + Mesa/ALSA, no compositor
  recipes-core/images/segno-update-bundle.bb         the signed .raucb
  recipes-core/rauc/                                 slot table (templated) + keyring
  recipes-core/seatd/                                seatd comes with ivi-homescreen's libseat; installed, not enabled
  recipes-bsp/rauc-rpi-backend/                      tryboot bootloader backend
  recipes-segno/segno-bundle/                        installs the PREBUILT bundle + launcher + units + homescreen.toml (which screen goes where)
  recipes-graphics/ivi-homescreen/                   the DRM/KMS embedder (pinned, two patches), installed as /usr/bin/segno
  recipes-graphics/flutter-engine/                   meta-flutter's prebuilt engine + its pin
```

### The engine and the app bundle

- The engine is meta-flutter's prebuilt release build, not a source build, and
  this layer does not include meta-flutter: it has no recipe for walnascar,
  and its engine recipe needs a 14 GB+ checkout.
- The app bundle must come from the Flutter release named in
  `recipes-graphics/flutter-engine/flutter-engine-version.inc`, and
  `segno-bundle` refuses any other. `deploy/rpi/build` builds it with
  `flutter assemble` and the engine's own CMake project; there is no Flutter
  desktop runner.

**ALSA-only** (no PipeWire/JACK → no `pw-jack`; the engine drives ALSA
directly).

## Getting an image

### The easy way — CI

`appliance-release.yml` builds both the `.raucb` and the flashable `.wic`.
Dispatch it and download the image artifact:

```bash
gh workflow run appliance-release.yml -f channel=experimental -f runner=self-hosted -f publish=no
```

The run publishes a `segno-image-rpi5-<version>` artifact holding `*.wic.gz`,
its `.bmap`, the `.raucb` and `SHA256SUMS`. On dispatch `publish` defaults to
**no**, so a bench build cannot move the OTA channel. Push to `experimental`
and `v*` tags still publish — that is what they are for.

### The local way — kas-container

Needs Docker Desktop (or colima/podman) with **≥120 GB disk, ≥16 GB RAM, 4–6
cores**. First build is **~2–5 h**.

1. **Build the aarch64 bundle** and stage it where the container can see it
   (under the repo, so kas's mount picks it up):
   ```bash
   deploy/rpi/build/build-arm64-bundle.sh
   mkdir -p deploy/yocto/prebuilt
   cp -a build/appliance/bundle deploy/yocto/prebuilt/bundle
   ```
   (`deploy/yocto/prebuilt/` is gitignored — it's a ~30 MB binary artifact.)

2. **Get `kas-container`** (Siemens' image runs **native arm64** on Apple Silicon —
   do **not** use crops/poky, which is amd64-only):
   ```bash
   curl -O https://raw.githubusercontent.com/siemens/kas/master/kas-container
   chmod +x kas-container
   ```

3. **Build:**
   ```bash
   ./kas-container build deploy/yocto/kas-segno-rpi5.yml
   ```
   Keep BitBake's `tmp/`/`sstate`/`downloads` **off** any `/Users` bind mount
   (VirtioFS is a perf cliff); kas-container's default in-container build dir is fine.

## Flashing

The image is ~8.4 GiB whatever the target size — two 3 GiB rootfs slots, two boot
slots, a 2 GiB `/data` seed. `segno-data-grow` expands `/data` to fill the media
on first boot, so a 1 TB NVMe ends up with ~990 GiB of user space.

Decompress **first**: Etcher has a bug where a compressed image yields an
unbootable card.

```bash
gunzip -k segno-appliance-*.wic.gz
diskutil list                      # find the target, e.g. /dev/disk5
diskutil unmountDisk /dev/disk5
sudo dd if=segno-appliance-*.wic of=/dev/rdisk5 bs=4m status=progress
sync
```

(or `bmaptool copy --bmap segno-appliance-*.wic.bmap segno-appliance-*.wic.gz /dev/rdisk5`,
which skips the unwritten blocks.)

### Pi 5: the EEPROM settings no image can carry

The bootloader EEPROM lives on the **board**, not on the drive. Nothing in the
`.wic` can set it, and reflashing never changes it. Do this once per board, from
whatever OS is on it now:

```bash
sudo rpi-eeprom-config --edit
```

```
BOOT_ORDER=0xf416
PSU_MAX_CURRENT=5000
```

- **`BOOT_ORDER=0xf416`** — right-to-left: `6`=NVMe, `1`=SD, `4`=USB,
  `f`=restart the loop. Without it the firmware never looks at the NVMe, and a
  perfectly good image is indistinguishable from a broken one.
- **`PSU_MAX_CURRENT=5000`** — declares a 5 A supply. A Pi 5 that can't confirm
  one budgets **600 mA across all USB ports combined**, which this console blows
  through with a hub, a touch controller, the pedal and the Scarlett. See
  [#740](https://github.com/tomassasovsky/segno/issues/740). Only set this behind
  a real 5 V/5 A supply — on a 3 A brick a loaded bus browns the board out.

The image side of the same two concerns is already baked into
`kas-segno-rpi5.yml`: `usb_max_current_enable=1` (stops the firmware capping USB
when it can't identify the supply — the EEPROM value above is the stronger half)
and `dtparam=pciex1`, without which the kernel never enumerates the NVMe
controller even though the firmware booted from it.

One mechanical trap while you're in there: the M.2 carrier's PCIe ribbon latches
at **both** ends, and a half-seated one enumerates intermittently rather than
failing outright.

### Hostname: the unit is `segno`

The appliance announces itself as **`segno`** (#496) — that is the name on the
router/AP client list (NetworkManager sends it in DHCP requests) and the SSH
prompt. Set as image policy in `kas-segno-common.yml`
(`hostname:pn-base-files`); older images announced the `MACHINE` name
(`raspberrypi5`, and before the Pi 5 `raspberrypi4-64`).

No mDNS ships (no avahi), so the name does **not** buy `segno.local` — connect
by IP unless your router resolves DHCP hostnames.

After updating a unit from an old-name image: `known_hosts` entries keyed by
the old name go stale (`ssh-keygen -R raspberrypi5`), but the dropbear host
keys live on `/data` and do not move — expect a re-learn under the new name,
never a key-change warning. IP-keyed entries are untouched.

## Iterating

App-only changes don't need a reflash. Build the bundle, copy its three parts
over the running unit's `/opt/segno`, and restart the app. The unit has no
`rsync` or sftp server (dropbear), so copy with `scp -O` or `ssh ... cat`:

```bash
deploy/rpi/build/build-arm64-bundle.sh --keep-dart-symbols
tar -C build/appliance/bundle -cf - data lib | ssh root@<unit> 'tar -C /opt/segno -xf - && systemctl restart segno'
```

The bundle must come from the Flutter release the image's engine is
(`flutter-engine-version.inc`); the build script uses it. OS changes go out as
a `.raucb` through the normal update flow.

## When to bail to a cloud builder

The local container route usually works, but two things can make it painful:
**arm64-host recipe breakage** (any vendor layer shipping prebuilt x86_64 host
binaries) and the **Docker-on-macOS filesystem tax**. If either costs more than it
saves, build on the self-hosted Proxmox runner (`-f runner=self-hosted`) or a
native x86_64 Linux host — the reference arch Yocto/meta-raspberrypi CI validate
against.
