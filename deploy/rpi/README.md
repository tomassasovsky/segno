# Segno appliance bundle and profiling

The console runs the Yocto image in [`deploy/yocto`](../yocto/README.md):
ivi-homescreen, installed as `/usr/bin/segno`, draws both panels over DRM/KMS
with one Flutter engine per screen. This directory builds the app bundle that
image installs at `/opt/segno`, and runs a profile build on the console for
DevTools.

## Files

| File | Purpose |
|---|---|
| `build/Dockerfile` | The arm64 build container: Flutter and the engine's CMake toolchain, no GTK |
| `build/segno-build.sh` | Runs inside the container: `flutter assemble` for the app, CMake for the engine |
| `build/build-arm64-bundle.sh` | Builds the container and runs it from a Mac or any Docker host |
| `profile-on-device.sh` | Runs a profile bundle on the console and tunnels the VM service for DevTools |

## Building the bundle

```bash
deploy/rpi/build/build-arm64-bundle.sh
```

This writes `build/appliance/bundle`: `data/flutter_assets`, `lib/libapp.so`,
`lib/libsegno_engine.so` and `flutter-version.json`. The build uses the Flutter
release whose engine the image ships (`FLUTTER_ENGINE_VERSION` in
`deploy/yocto/meta-segno/recipes-graphics/flutter-engine/flutter-engine-version.inc`),
and the `segno-bundle` recipe refuses a bundle from any other release. There
is no Flutter desktop runner: the embedder, its engine library and the ICU
data file come from the image.

`--keep-dart-symbols` keeps the AOT symbol table, as experimental builds do,
so `segno-prof` can name Dart frames on the console.

CI's `appliance-bundle` job builds the same bundle in the same container on
every PR. To put a bundle on a running console without a new image, or to
stage it for a local Yocto build, see "Iterating" and "The local way" in
[`deploy/yocto/README.md`](../yocto/README.md).

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
   transient unit `segno-devtools`, with `segno.service`'s environment, limits
   and stop handling, plus `LD_LIBRARY_PATH` pointing at the profile engine.
   It stops `segno.service` for the duration and starts it again on exit
   however the run ends, and forwards the VM service to `127.0.0.1:8181` for
   DevTools. Both screens' isolates are on that one port.

**Read the result as a split, not a score.** UI thread over budget points at the
snapshot poll cadence and `context.watch` fan-out; raster thread over budget
points at missing `RepaintBoundary`s, the per-sample waveform rects, and card
elevation. Which half is over budget decides the work — see #638.

**Check the appliance is in a sane state first.** A full `/data`, a capture left
running, or a stale bundle all make the numbers measure something other than the
UI. `df -h /data` before you start.

For profiling that does not stop the app (`segno-prof` and the recorder on
experimental images), see
[`docs/RUNNING_ON_RPI.md`](../../docs/RUNNING_ON_RPI.md#profiling).
