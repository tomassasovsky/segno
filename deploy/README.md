# Deploy

How the Segno app gets onto the console. The console is a Raspberry Pi 5
booting from NVMe into a Yocto Linux image. The image runs the Flutter app on
[ivi-homescreen](https://github.com/toyota-connected/ivi-homescreen), which
draws both screens directly over DRM/KMS with no compositor. Updates are
signed RAUC bundles installed to an A/B pair of root filesystem slots.

| Folder | Contents |
| --- | --- |
| [`yocto`](yocto/README.md) | The appliance image. `kas-segno-rpi5.yml` and `kas-segno-common.yml` are the [kas](https://kas.readthedocs.io/) project files that pin the upstream layers (poky, meta-openembedded, meta-raspberrypi, meta-rauc). `meta-segno/` is the project's own layer: the image and update-bundle recipes, the A/B partition layout and boot-slot handling, the RAUC configuration, the ivi-homescreen and Flutter engine recipes, the recipe that installs the app bundle, and the recipe that ships and flashes the console firmware. `test/` holds shell tests for the kernel command line. |
| [`rpi`](rpi/README.md) | Builds the arm64 app bundle the image installs at `/opt/segno`, in a Docker container (`build/`), and runs a profile build on a console for Flutter DevTools (`profile-on-device.sh`). |
| `spike-1367` | `fork_bench.c`, a standalone benchmark written for #1367. It measures how much starting a child process with `fork`, `posix_spawn` and related calls delays a real-time thread in a large process. It is not part of the image. The findings are in [the brainstorm for #1367](../docs/brainstorm/2026-10-19-no-fork-helpers-brainstorm-doc.md). |

## How a release is built

The [`appliance-release`](../.github/workflows/appliance-release.yml) workflow
builds and publishes the image:

1. It builds the app bundle on a native arm64 GitHub runner with the
   `deploy/rpi/build` scripts, and compiles the console board and ring
   carrier firmware.
2. It runs the Yocto build with kas, on a GitHub runner or a self-hosted one,
   to produce both a flashable `.wic` image and a signed `.raucb` update
   bundle, and checks that the image carries that run's firmware.
3. It publishes the `.raucb` and a channel manifest as a GitHub Release, then
   asks the update mirror that the consoles poll to sync.

A push to the `experimental` branch publishes to the experimental channel, and
a `v*` tag publishes to production. A manual run can choose the channel and
whether to publish at all; with publishing off it only produces the image
artifacts.

To flash a new console, set its EEPROM boot order and write the `.wic` to the
NVMe drive as described in [`yocto/README.md`](yocto/README.md#flashing). A
console that is already running receives later versions as `.raucb` updates.
For running and operating a console, see
[`docs/RUNNING_ON_RPI.md`](../docs/RUNNING_ON_RPI.md).
[`docs/APPLIANCE_INTEGRATION.md`](../docs/APPLIANCE_INTEGRATION.md) records how
the console link and the update delivery were integrated in September 2026 and
what the release pipeline checks before a bundle ships.
