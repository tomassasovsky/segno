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
#   --profile             build a profile-mode bundle into
#                         build/appliance/profile-bundle instead, with the
#                         profile engine (lib/libflutter_engine.so) and its
#                         icudtl.dat, for DevTools on the device
#                         (deploy/rpi/profile-on-device.sh). The image ships
#                         only the release engine, and a profile snapshot runs
#                         only on a profile engine.
set -euo pipefail

mode=release
defines=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-dart-symbols) defines+=(-dExtraGenSnapshotOptions=--no-strip); shift ;;
    --profile) mode=profile; shift ;;
    *) echo "segno-build: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$mode" = profile ]; then
  out=build/appliance/profile-bundle
  work=build/appliance/profile-work
else
  out=build/appliance/bundle
  work=build/appliance/work
fi

# Hand the generated files back to the invoking host user, however the build
# ends, or the bind-mounted output is root-owned on the host. `flutter pub get`
# in this monorepo also touches packages/*/pubspec.lock, so the whole mounted
# tree is handed back.
hand_back() {
  if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    chown -R "$HOST_UID:$HOST_GID" /workspace 2>/dev/null || true
  fi
}
trap hand_back EXIT

rm -rf "$out" "$work"
mkdir -p "$out/data" "$out/lib"

flutter pub get

echo "==> App: flutter assemble (main_production, linux-arm64, $mode)"
flutter assemble --no-version-check --output="$work/app" \
  -dTargetPlatform=linux-arm64 -dBuildMode="$mode" \
  -dTargetFile=lib/main_production.dart -dTreeShakeIcons=true \
  ${defines[@]+"${defines[@]}"} \
  "${mode}_bundle_linux-arm64_assets"
cp -R "$work/app/flutter_assets" "$out/data/"
cp "$work/app/lib/libapp.so" "$out/lib/"
# The Flutter tool still writes its desktop-runner scaffolding (the plugin
# registrant and the GTK engine) under linux/flutter for a linux target. The
# repo has no Linux runner, and nothing here reads it.
rm -rf linux

echo "==> Audio engine: packages/segno_engine/src (Release, clang)"
CC=clang CXX=clang++ cmake -S packages/segno_engine/src -B "$work/engine" \
  -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja -C "$work/engine" segno_engine
cp "$work/engine/libsegno_engine.so" "$out/lib/"

if [ "$mode" = profile ]; then
  pin=deploy/yocto/meta-segno/recipes-graphics/flutter-engine/flutter-engine-version.inc
  commit=$(sed -n 's/^FLUTTER_ENGINE_COMMIT = "\(.*\)"$/\1/p' "$pin")
  digest=$(sed -n 's/^FLUTTER_ENGINE_PROFILE_SHA256 = "\(.*\)"$/\1/p' "$pin")
  # segno-bundle.bb makes this check for the release bundle at image build;
  # the profile bundle never reaches it.
  revision=$(flutter --version --machine | sed -n 's/.*"engineRevision": *"\([0-9a-f]*\)".*/\1/p')
  if [ "$revision" != "$commit" ]; then
    echo "segno-build: Flutter's engine is $revision, the pin is $commit" >&2
    exit 1
  fi
  sdk="linux-engine-sdk-profile-arm64-$commit"
  echo "==> Profile engine: $sdk"
  curl -fsSL -o "$work/$sdk.tar.gz" \
    "https://github.com/meta-flutter/flutter-engine/releases/download/$sdk/$sdk.tar.gz"
  echo "$digest  $work/$sdk.tar.gz" | sha256sum -c -
  tar -C "$work" -xzf "$work/$sdk.tar.gz" --wildcards \
    '*/engine-sdk/lib/libflutter_engine.so' '*/engine-sdk/data/icudtl.dat'
  sdk_dir=$(dirname "$(find "$work" -path '*/engine-sdk/lib/libflutter_engine.so')")/..
  cp "$sdk_dir/lib/libflutter_engine.so" "$out/lib/"
  cp "$sdk_dir/data/icudtl.dat" "$out/data/"
fi

# The Flutter release that built the snapshot. segno-bundle.bb compares its
# engine revision with the one the image ships and refuses a mismatch, which
# would otherwise build, install and boot, then die before the first frame.
flutter --version --machine > "$out/flutter-version.json"
