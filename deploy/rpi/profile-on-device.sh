#!/usr/bin/env bash
# Run a PROFILE-mode Segno bundle on the appliance and expose its Dart VM service
# to a DevTools session on your workstation. See #638.
#
# Why this exists: the installed appliance bundle is release-mode AOT with no VM
# service, so DevTools has nothing to attach to, and the Yocto image is a pure
# runtime with no toolchain so it cannot build a profile bundle itself. Get one
# from the `appliance-profile-bundle` workflow:
#
#   gh run download <run-id> -n segno-linux-arm64-profile -D /tmp/segno-profile
#   deploy/rpi/profile-on-device.sh /tmp/segno-profile
#
# The release install at /opt/segno is never touched: the profile bundle goes to
# /data/profile (the persistent partition OTA preserves, and the only one with
# room to spare — the rootfs runs ~1GB). segno.service is stopped for the
# duration so weston's kiosk-shell has a single client and the audio device is
# not held, then restarted on exit however this script ends.
#
# UNVERIFIED on hardware: the VM service flag names below are the engine's
# documented switches but have not yet been confirmed against a profile bundle on
# this image. If no listening URL appears, check the captured log the script
# prints the path to before assuming the deploy failed.
set -euo pipefail

BUNDLE="${1:-}"
HOST="${2:-root@raspberrypi4-64.local}"
PORT="${SEGNO_VM_PORT:-8181}"
REMOTE_DIR=/data/profile

if [ -z "$BUNDLE" ] || [ ! -x "$BUNDLE/segno" ]; then
  cat >&2 <<USAGE
usage: $0 <profile-bundle-dir> [user@host]

  <profile-bundle-dir>  directory containing the 'segno' binary plus data/ and
                        lib/ -- i.e. build/linux/arm64/profile/bundle, or the
                        unpacked segno-linux-arm64-profile CI artifact.

  SEGNO_VM_PORT         VM service port to use on both ends (default 8181).
USAGE
  exit 2
fi

echo "==> checking $HOST"
ssh -o BatchMode=yes "$HOST" 'command -v tar >/dev/null' \
  || { echo "no tar on device" >&2; exit 1; }

# The rootfs has ~1GB free and is A/B-swapped by OTA; /data has the room and
# survives updates. Bail rather than half-copy if it is tight.
avail=$(ssh -o BatchMode=yes "$HOST" "df -k /data | awk 'NR==2{print \$4}'")
if [ "$avail" -lt 524288 ]; then
  echo "/data has less than 512MB free (${avail}K) -- free space first" >&2
  exit 1
fi

echo "==> stopping segno.service"
ssh -o BatchMode=yes "$HOST" 'systemctl stop segno.service'

# Whatever happens next -- success, failure, Ctrl-C -- the appliance goes back to
# running its release build. Leaving a floor unit dark is not an acceptable exit.
restore() {
  echo
  echo "==> restoring segno.service"
  ssh -o BatchMode=yes "$HOST" 'systemctl start segno.service' || true
}
trap restore EXIT INT TERM

echo "==> copying bundle to $REMOTE_DIR"
ssh -o BatchMode=yes "$HOST" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
tar -C "$BUNDLE" -cf - . | ssh -o BatchMode=yes "$HOST" "tar -C $REMOTE_DIR -xf -"
ssh -o BatchMode=yes "$HOST" "chmod +x $REMOTE_DIR/segno"

echo "==> starting profile build"
# The environment mirrors /usr/bin/segno-kiosk-launch exactly. It has to: the
# ALSA/RT/HOME variables change how the engine and path_provider behave, and a
# profile run under a different environment would not be measuring the appliance.
# Kept in sync by hand -- if that launcher changes, change this too.
ssh -o BatchMode=yes -f "$HOST" "
  export GDK_BACKEND=wayland
  export XDG_RUNTIME_DIR=/run/user/1000
  export WAYLAND_DISPLAY=wayland-1
  export HOME=/data
  export XDG_DATA_HOME=\$HOME/.local/share
  export XDG_CONFIG_HOME=\$HOME/.config
  export SEGNO_ALSA_ONLY=1
  export SEGNO_RT_AUDIO=1
  export SEGNO_ALSA_PERIODS=3
  $REMOTE_DIR/segno \
    --vm-service-port=$PORT \
    --disable-service-auth-codes \
    >$REMOTE_DIR/profile.log 2>&1 &
"

echo "==> waiting for the VM service"
url=""
for _ in $(seq 1 30); do
  sleep 1
  url=$(ssh -o BatchMode=yes "$HOST" \
    "grep -oE 'http://[0-9.]+:[0-9]+/[A-Za-z0-9_=-]*' $REMOTE_DIR/profile.log 2>/dev/null | head -1" \
    || true)
  [ -n "$url" ] && break
done

if [ -z "$url" ]; then
  echo "no VM service URL after 30s. Device-side log:" >&2
  ssh -o BatchMode=yes "$HOST" "tail -30 $REMOTE_DIR/profile.log" >&2 || true
  exit 1
fi

echo "==> VM service up on device: $url"
echo "==> forwarding localhost:$PORT -> device:$PORT (Ctrl-C to stop and restore)"
echo
echo "    Attach DevTools to: ${url/:$PORT//:$PORT}"
echo "    (open it against http://127.0.0.1:$PORT once the tunnel is up)"
echo
echo "    Measure, in this order:"
echo "      1. idle console          -- the floor for everything else"
echo "      2. a record/overdub pass -- the 16ms snapshot poll under load"
echo "      3. tray open/close       -- implicit animations + layout"
echo "      4. waveform window open  -- two engines on one V3D"
echo
echo "    What decides the work: UI thread over budget -> the poll timer and"
echo "    context.watch fan-out. Raster over budget -> RepaintBoundary, the"
echo "    per-sample waveform rects, card elevation."
echo

exec ssh -o BatchMode=yes -N -L "$PORT:127.0.0.1:$PORT" "$HOST"
