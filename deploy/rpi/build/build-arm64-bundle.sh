#!/usr/bin/env bash
#
# Build the Segno aarch64 Linux release bundle from a Mac (or any Docker host).
#
# The dev machine cannot produce a Linux bundle natively, so the build runs in
# the arm64 container defined by deploy/rpi/build/Dockerfile.arm64. The image
# mirrors the CI arm64 recipe and, before the release build, re-runs the exact
# CI debug command as a parity smoke. This is a LOCAL-DEV producer, not a CI
# gate; CI's `build-linux-arm64` job remains the compile guard.
#
# Usage:
#   deploy/rpi/build/build-arm64-bundle.sh [--deploy user@host] [flutter args...]
#
#   (no args)                      Console kiosk release bundle.
#   --deploy pi@raspberrypi.local  After building, rsync the bundle to the Pi.
#
# Any extra args are forwarded to `flutter build` verbatim.
#
# Output: build/linux/arm64/release/bundle/ (segno + libsegno_engine.so + lib/ + data/).
set -euo pipefail

readonly IMAGE="segno-arm64-build"
readonly BUNDLE_REL="build/linux/arm64/release/bundle"

# Print the leading comment block (everything from line 2 to the first code line).
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; }

# --- Parse args: pull out --deploy, forward the rest to flutter build ---------
deploy_target=""
forward=()
while [ $# -gt 0 ]; do
  case "$1" in
    --deploy)   deploy_target="${2:?--deploy needs a user@host target}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          forward+=("$1"); shift ;;
  esac
done
# Re-seat the forwarded args as "$@" (empty-array-safe under `set -u`).
set -- ${forward[@]+"${forward[@]}"}

# --- Locate the repo root so the script works from any CWD --------------------
command -v docker >/dev/null 2>&1 || { echo "error: docker not found on PATH" >&2; exit 1; }
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

# --- Build the image, then run the build inside it ----------------------------
echo "==> Building $IMAGE (arm64)"
DOCKER_BUILDKIT=1 docker build --platform linux/arm64 \
  -f deploy/rpi/build/Dockerfile.arm64 -t "$IMAGE" deploy/rpi/build

echo "==> Building the aarch64 bundle: flutter build linux --release $*"
docker run --rm --platform linux/arm64 \
  -v "$repo_root":/workspace -w /workspace \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" "$@"

# --- Verify the bundle looks like an aarch64 ELF ------------------------------
bin="$BUNDLE_REL/segno"
[ -x "$bin" ] || { echo "error: expected bundle binary missing: $bin" >&2; exit 1; }
echo "==> Built $bin"
file "$bin" | grep -q 'ARM aarch64' \
  && echo "==> Confirmed aarch64: $(file -b "$bin")" \
  || echo "warning: $bin is not reported as ARM aarch64 -- check the host platform" >&2

# --- Verify the two halves of the bundle agree on the FFI boundary ------------
# The bundle ships a Dart half (libapp.so) and a native half
# (libsegno_engine.so) that meet only through dlsym, which resolves lazily at
# first call. A .so that is stale relative to the bindings therefore produces a
# bundle that builds, installs and launches, then throws on the device -- as it
# did on 2026-08-25, 137 times off a periodic timer. Gate it here, before the
# bundle can reach the rsync below or the Yocto staging dir, because after this
# point nothing else looks.
echo "==> Checking FFI symbol parity"
packages/segno_engine/tool/check_ffi_symbols.sh "$BUNDLE_REL/lib/libsegno_engine.so"

# --- Optional deploy to the Pi ------------------------------------------------
if [ -n "$deploy_target" ]; then
  command -v rsync >/dev/null 2>&1 || { echo "error: rsync not found on PATH" >&2; exit 1; }
  echo "==> Deploying to $deploy_target"
  # rsync only creates the final path component, so make the parent tree first —
  # a fresh Pi has no ~/segno/build/linux/... yet.
  ssh "$deploy_target" "mkdir -p ~/segno/$BUNDLE_REL"
  rsync -avz "$BUNDLE_REL/" "$deploy_target:~/segno/$BUNDLE_REL/"
  echo "==> Deployed to $deploy_target:~/segno/$BUNDLE_REL/"
fi
