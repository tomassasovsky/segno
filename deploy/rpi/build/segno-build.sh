#!/usr/bin/env bash
# Builds the appliance bundle, the files ivi-homescreen runs from /opt/segno:
#
#   build/appliance/bundle/data/flutter_assets/   the app's assets
#   build/appliance/bundle/lib/libapp.so          the AOT snapshot
#   build/appliance/bundle/lib/libsegno_engine.so the audio engine
#   build/appliance/bundle/flutter-version.json   the Flutter that built it
#
# There is no Flutter desktop runner. `flutter assemble` runs the same target
# `flutter build linux` would have run for these files
# (release_bundle_linux-arm64_assets), and the engine builds from its own CMake
# project (packages/segno_engine/src), as the FFI plugin build did. The
# embedder, its engine library and icudtl.dat come from the image.
#
#   --keep-dart-symbols   keep the AOT snapshot's symbol table (gen_snapshot
#                         --no-strip), so segno-prof can name Dart frames on
#                         the device. Experimental builds pass it.
set -euo pipefail

out=build/appliance/bundle
work=build/appliance/work
defines=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-dart-symbols) defines+=(-dExtraGenSnapshotOptions=--no-strip); shift ;;
    *) echo "segno-build: unknown argument: $1" >&2; exit 2 ;;
  esac
done

rm -rf "$out" "$work"
mkdir -p "$out/data" "$out/lib"

flutter pub get

echo "==> App: flutter assemble (main_production, linux-arm64, release)"
flutter assemble --no-version-check --output="$work/app" \
  -dTargetPlatform=linux-arm64 -dBuildMode=release \
  -dTargetFile=lib/main_production.dart -dTreeShakeIcons=true \
  ${defines[@]+"${defines[@]}"} \
  release_bundle_linux-arm64_assets
cp -R "$work/app/flutter_assets" "$out/data/"
cp "$work/app/lib/libapp.so" "$out/lib/"

echo "==> Audio engine: packages/segno_engine/src (Release, clang)"
CC=clang CXX=clang++ cmake -S packages/segno_engine/src -B "$work/engine" \
  -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja -C "$work/engine" segno_engine
cp "$work/engine/libsegno_engine.so" "$out/lib/"

# The Flutter release that built the snapshot. segno-bundle.bb compares its
# engine revision with the one the image ships and refuses a mismatch, which
# would otherwise build, install and boot, then die before the first frame.
flutter --version --machine > "$out/flutter-version.json"

# Hand the generated files back to the invoking host user, or the bind-mounted
# output is root-owned on the host. `flutter pub get` in this monorepo also
# touches packages/*/pubspec.lock, so the whole mounted tree is handed back.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "$HOST_UID:$HOST_GID" /workspace 2>/dev/null || true
fi
