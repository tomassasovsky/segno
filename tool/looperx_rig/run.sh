#!/bin/sh
# Boots the Sheeran Looper X (HG08) userland under ARM emulation.
#
# Usage: ROOTFS=/path/to/extracted/rootfs ./run.sh [seconds]
#
# See README.md for why each substitution below is needed. Everything here was
# established empirically -- none of it is guesswork.
set -eu
: "${ROOTFS:?set ROOTFS to the extracted Looper X rootfs}"
SECS="${1:-60}"
HERE=$(cd "$(dirname "$0")" && pwd)

docker build --platform linux/arm/v7 -t looperx-rig:mesa -f "$HERE/Dockerfile" "$HERE" >/dev/null

# eglfs_mali opens /dev/fb0 only to size the screen; a regular file opens fine
# and the failed ioctl is non-fatal once the geometry is supplied by env.
[ -f "$HERE/fakefb" ] || dd if=/dev/zero of="$HERE/fakefb" bs=1024 count=4096 2>/dev/null

exec docker run --rm --platform linux/arm/v7 \
  -v "$ROOTFS:/rootfs:ro" -v "$HERE:/rig:ro" -v "$HERE/fakefb:/dev/fb0" \
  --tmpfs /media --tmpfs /run --tmpfs /shim \
  looperx-rig:mesa /rig/boot.sh "$SECS"
