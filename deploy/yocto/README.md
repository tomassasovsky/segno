# Segno appliance — Yocto/weston image

The image the floor console boots: a lean Yocto build running the **prebuilt**
aarch64 Flutter GTK bundle under weston, with RAUC A/B updates over the Raspberry
Pi firmware's `tryboot`.

Two boards, one layer:

| kas project | MACHINE | Boots from | `SEGNO_BOOT_DISK` |
|---|---|---|---|
| `kas-segno-rpi4.yml` | `raspberrypi4-64` | SD card | `mmcblk0` |
| `kas-segno-rpi5.yml` | `raspberrypi5` | NVMe in the M.2 slot | `nvme0n1` |

Everything the two share lives in **`kas-segno-common.yml`** — put changes there
unless they are genuinely board-specific. The boot device is a single variable
threaded through the WIC layout, the RAUC slot table and the per-slot
`cmdline.txt`, so those three cannot drift apart.

Origin: the Tier 3a spike ([#284](https://github.com/tomassasovsky/segno/issues/284),
child of #271). Pi 5 + NVMe: [#799](https://github.com/tomassasovsky/segno/issues/799).
Plan: [`docs/plan/2026-07-23-spike-tier3a-yocto-gtk-plan.md`](../../docs/plan/2026-07-23-spike-tier3a-yocto-gtk-plan.md).

## What's here

```
kas-segno-common.yml        shared: poky + meta-openembedded + meta-raspberrypi + meta-rauc (walnascar, commit-pinned)
kas-segno-rpi4.yml          raspberrypi4-64, SD
kas-segno-rpi5.yml          raspberrypi5, NVMe (+ dtparam=pciex1)
meta-segno/
  conf/layer.conf
  classes/tryboot-cmdline.bbclass                    rewrites root= per boot slot inside the .wic
  wic/segno-tryboot.wks.in                           A/B layout template (${SEGNO_BOOT_DISK})
  recipes-core/images/segno-kiosk-image.bb           core-image-weston + our bundle + GTK3/Mesa/ALSA
  recipes-core/images/segno-update-bundle.bb         the signed .raucb
  recipes-core/rauc/                                 slot table (templated) + keyring
  recipes-bsp/rauc-rpi-backend/                      tryboot bootloader backend
  recipes-segno/segno-bundle/                        installs the PREBUILT bundle + launcher + units
  recipes-graphics/weston-init/weston-init.bbappend  weston.ini: kiosk-shell + dual outputs
```

**No meta-flutter** — it has no GTK embedder (that's what 3b/ivi-homescreen is for).
This is a stock weston image plus our prebuilt bundle. **ALSA-only** (no
PipeWire/JACK → no `pw-jack`; the engine drives ALSA directly).

## Getting an image

### The easy way — CI

`appliance-release.yml` builds both the `.raucb` and the flashable `.wic`.
Dispatch it, pick the board, and download the image artifact:

```bash
gh workflow run appliance-release.yml -f channel=experimental -f runner=self-hosted -f board=rpi5
```

The run publishes a `segno-image-<board>-<version>` artifact holding
`*.wic.gz`, its `.bmap` and `SHA256SUMS`. `board` defaults to **rpi5** on
dispatch; push/tag triggers stay on rpi4 so the published OTA channels keep
serving the board that is already deployed.

### The local way — kas-container

Needs Docker Desktop (or colima/podman) with **≥120 GB disk, ≥16 GB RAM, 4–6
cores**. First build is **~2–5 h**.

1. **Build the aarch64 bundle** and stage it where the container can see it
   (under the repo, so kas's mount picks it up):
   ```bash
   deploy/rpi/build/build-arm64-bundle.sh
   mkdir -p deploy/yocto/prebuilt
   cp -a build/linux/arm64/release/bundle deploy/yocto/prebuilt/bundle
   ```
   (`deploy/yocto/prebuilt/` is gitignored — it's a 26 MB binary artifact.)

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

## Iterating

App-only changes don't need a reflash — `rsync` the bundle to `/opt/segno` on the
running unit. OS changes go out as a `.raucb` through the normal update flow.

## When to bail to a cloud builder

The local container route usually works, but two things can make it painful:
**arm64-host recipe breakage** (any vendor layer shipping prebuilt x86_64 host
binaries) and the **Docker-on-macOS filesystem tax**. If either costs more than it
saves, build on the self-hosted Proxmox runner (`-f runner=self-hosted`) or a
native x86_64 Linux host — the reference arch Yocto/meta-raspberrypi CI validate
against.
