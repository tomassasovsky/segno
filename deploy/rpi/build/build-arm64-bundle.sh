#!/usr/bin/env bash
#
# Build the Segno appliance bundle from a Mac (or any Docker host).
#
# The build runs in the arm64 container defined by deploy/rpi/build/Dockerfile,
# the same image and script the release workflow uses, on the Flutter release
# whose engine the appliance image ships (FLUTTER_ENGINE_VERSION in
# flutter-engine-version.inc). CI's `appliance-bundle` job is the compile gate;
# this is the local producer.
#
# Usage:
#   deploy/rpi/build/build-arm64-bundle.sh [--keep-dart-symbols] [--profile]
#
#   --keep-dart-symbols  keep the AOT symbol table, as experimental builds do,
#                        so segno-prof can name Dart frames on the device.
#   --profile            build the profile bundle for DevTools instead, with
#                        the profile engine, into build/appliance/profile-bundle;
#                        run it with deploy/rpi/profile-on-device.sh.
#
# Output: build/appliance/bundle/ (data/flutter_assets, lib/libapp.so,
# lib/libsegno_engine.so, flutter-version.json). Point the Yocto build at it
# with SEGNO_BUNDLE_DIR (deploy/yocto/README.md).
set -euo pipefail

readonly IMAGE="segno-bundle-build"
bundle_rel="build/appliance/bundle"
readonly PIN="deploy/yocto/meta-segno/recipes-graphics/flutter-engine/flutter-engine-version.inc"

# Print the leading comment block (everything from line 2 to the first code line).
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; }

forward=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-dart-symbols) forward+=("$1"); shift ;;
    --profile)           forward+=("$1"); bundle_rel="build/appliance/profile-bundle"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

flutter_version=$(sed -n 's/^FLUTTER_ENGINE_VERSION = "\(.*\)"$/\1/p' "$PIN")
[ -n "$flutter_version" ] || { echo "error: no FLUTTER_ENGINE_VERSION in $PIN" >&2; exit 1; }

echo "==> Building $IMAGE (arm64, Flutter $flutter_version)"
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 \
  --build-arg "FLUTTER_VERSION=$flutter_version" -t "$IMAGE" deploy/rpi/build

echo "==> Building the appliance bundle"
docker run --rm --platform linux/arm64 \
  -v "$repo_root":/workspace -w /workspace \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" ${forward[@]+"${forward[@]}"}

expected="lib/libapp.so lib/libsegno_engine.so data/flutter_assets flutter-version.json"
[ "$bundle_rel" = build/appliance/bundle ] \
  || expected="$expected lib/libflutter_engine.so data/icudtl.dat"
for f in $expected; do
  [ -e "$bundle_rel/$f" ] || { echo "error: the bundle has no $f" >&2; exit 1; }
done
file "$bundle_rel/lib/libsegno_engine.so" | grep -q 'ARM aarch64' \
  || { echo "error: libsegno_engine.so is not aarch64: $(file -b "$bundle_rel/lib/libsegno_engine.so")" >&2; exit 1; }

# The bundle's Dart half (libapp.so) and native half (libsegno_engine.so) meet
# only through dlsym, which resolves lazily at first call. A .so that is stale
# relative to the bindings therefore builds, installs and launches, then throws
# on the device -- as it did on 2026-08-25, 137 times off a periodic timer.
echo "==> Checking FFI symbol parity"
packages/segno_engine/tool/check_ffi_symbols.sh "$bundle_rel/lib/libsegno_engine.so"

echo "==> Built $bundle_rel"
