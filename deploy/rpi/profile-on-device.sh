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
# VERIFIED end-to-end on the Yocto Pi 4B: bundle deploys, app starts under
# weston, audio opens (`audio auto-start: started ok pinned=true`), and the VM
# service answers HTTP JSON-RPC through the tunnel.
#
# One caveat this script cannot remove: the appliance renders ZERO frames while
# nothing is moving, so a profile session with no one touching the console
# measures an idle isolate and nothing else. Someone has to drive the console --
# transport, tray, waveform -- for the numbers to mean anything. See #638.
set -euo pipefail

BUNDLE="${1:-}"
# The appliance's hostname is "segno" (#496). The image ships no mDNS, so this
# default only resolves if the router serves DHCP hostnames — pass user@<ip>
# otherwise.
HOST="${2:-root@segno}"
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
  echo "==> stopping the profile build"
  # Kill the profile instance FIRST and by recorded PID. It holds the ALSA
  # device; starting the release build while it is still alive makes the release
  # build fail with `audio auto-start: open failed result=device` and look, from
  # the console, like the appliance came back broken.
  #
  # By PID, not `pkill -f /data/profile/segno`: that pattern also matches the
  # ssh-spawned shell running it, so pkill kills its own session and the rest of
  # the restore never runs. Learned the hard way.
  ssh -o BatchMode=yes "$HOST" "
    [ -f $REMOTE_DIR/segno.pid ] && kill -9 \$(cat $REMOTE_DIR/segno.pid) 2>/dev/null
    rm -f $REMOTE_DIR/segno.pid
    true
  " || true
  echo "==> restoring segno.service"
  ssh -o BatchMode=yes "$HOST" 'systemctl restart segno.service' || true
}
trap restore EXIT INT TERM

echo "==> copying bundle to $REMOTE_DIR"
ssh -o BatchMode=yes "$HOST" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
tar -C "$BUNDLE" -cf - . | ssh -o BatchMode=yes "$HOST" "tar -C $REMOTE_DIR -xf -"
ssh -o BatchMode=yes "$HOST" "chmod +x $REMOTE_DIR/segno"

# Resolve the ALSA depth the unit will ACTUALLY run at before launching under
# it. Since #818 the launcher takes SEGNO_ALSA_PERIODS as an overridable
# default, so a drop-in (Environment=) or `systemctl set-environment` is how a
# re-derivation gets applied -- and neither reaches an ssh-spawned process.
# Ask the unit rather than restating a number here. Set SEGNO_ALSA_PERIODS in
# this script's environment to profile a candidate depth instead. Every lookup
# is best-effort: on a unit without the service (or without systemd) this must
# fall through to the launcher's shipped default, not abort the run.
if [ -z "${SEGNO_ALSA_PERIODS:-}" ]; then
  SEGNO_ALSA_PERIODS="$(ssh -o BatchMode=yes "$HOST" '
    { systemctl show segno.service -p Environment --value 2>/dev/null || true
      systemctl show-environment 2>/dev/null || true
    } | tr " " "\n" | sed -n "s/^SEGNO_ALSA_PERIODS=//p" | tail -1
  ' || true)"
fi
# The launcher's shipped default (segno-kiosk-launch), used when the unit
# names no override of its own.
: "${SEGNO_ALSA_PERIODS:=4}"
echo "==> SEGNO_ALSA_PERIODS=$SEGNO_ALSA_PERIODS"

echo "==> starting profile build"
# The ENVIRONMENT VARIABLES below mirror /usr/bin/segno-kiosk-launch. They have
# to: the ALSA/RT/HOME variables change how the engine and path_provider behave,
# and a profile run under a different environment would not be measuring the
# appliance. Kept in sync by hand -- if that launcher changes, change this too.
# That includes SEGNO_ALSA_PERIODS: it tracks the value the unit ACTUALLY runs
# at rather than pinning one of its own, because the whole point of this script
# is to profile the configuration that ships. It is read off the unit below,
# not restated here -- since #818 the launcher takes it as an overridable
# default, and a drop-in (Environment=) or `systemctl set-environment` is
# exactly how a re-derivation is meant to be applied. Neither reaches an
# ssh-spawned process, so a hardcoded value here would silently profile a
# depth the unit is not running. To profile a candidate depth, set
# SEGNO_ALSA_PERIODS in this script's own environment for that one run.
#
# What is NOT mirrored, so nobody reads "mirrors the launcher" as "is the
# launcher". Both are benign today; the second has a tripwire.
#
#   1. Filesystem setup. segno-kiosk-launch:15-20 falls back to HOME=/root when
#      /data is unmounted, and seeds user-dirs.dirs plus $HOME/log (:25, :33-45).
#      This script skips all of it and just exports HOME. Fine while /data is
#      mounted, which is the case a profile run cares about.
#   2. Process limits. segno.service:29-30 sets LimitRTPRIO=95 and
#      LimitMEMLOCK=infinity; an ssh-spawned process is not in that unit and
#      gets neither. This is moot ONLY because the profile runs as root, where
#      CAP_SYS_NICE and CAP_IPC_LOCK bypass both limits. The day the appliance
#      stops running as root, SEGNO_RT_AUDIO=1 below silently stops taking
#      effect here: setschedparam EPERMs, the audio thread stays SCHED_OTHER,
#      and every profile run measures a non-RT thread while still claiming to
#      measure the appliance. Add explicit ulimits here before that happens.
#
# setsid + nohup + </dev/null, NOT `ssh -f ... &`: with a bare trailing `&` the
# remote shell exits immediately and SIGHUPs the app before it ever opens its
# log. Detaching it from the session is what makes it survive the ssh close.
#
# No --vm-service-port / --disable-service-auth-codes: VERIFIED on device that
# the Linux GTK embedder ignores both. It always picks a random port and always
# mints an auth code, so the port is discovered from the log below rather than
# dictated here. SEGNO_VM_PORT therefore only selects the LOCAL end of the
# tunnel.
ssh -o BatchMode=yes "$HOST" "
  export GDK_BACKEND=wayland
  export XDG_RUNTIME_DIR=/run/user/1000
  export WAYLAND_DISPLAY=wayland-1
  export HOME=/data
  export XDG_DATA_HOME=\$HOME/.local/share
  export XDG_CONFIG_HOME=\$HOME/.config
  export SEGNO_ALSA_ONLY=1
  export SEGNO_RT_AUDIO=1
  export SEGNO_ALSA_PERIODS=$SEGNO_ALSA_PERIODS
  setsid nohup $REMOTE_DIR/segno >$REMOTE_DIR/profile.log 2>&1 </dev/null &
  echo \$! > $REMOTE_DIR/segno.pid
"

echo "==> waiting for the VM service"
url=""
for _ in $(seq 1 30); do
  sleep 1
  # The full URL including the auth-code path segment -- DevTools needs it.
  url=$(ssh -o BatchMode=yes "$HOST" \
    "grep -oE 'http://127\.0\.0\.1:[0-9]+/[A-Za-z0-9_=-]*/' $REMOTE_DIR/profile.log 2>/dev/null | head -1" \
    || true)
  [ -n "$url" ] && break
done

if [ -z "$url" ]; then
  echo "no VM service URL after 30s. Device-side log:" >&2
  ssh -o BatchMode=yes "$HOST" "tail -30 $REMOTE_DIR/profile.log" >&2 || true
  exit 1
fi

remote_port=$(printf '%s' "$url" | sed -E 's#^http://127\.0\.0\.1:([0-9]+)/.*#\1#')
local_url=${url/127.0.0.1:$remote_port/127.0.0.1:$PORT}

echo "==> VM service up on device: $url"
echo "==> forwarding localhost:$PORT -> device:$remote_port (Ctrl-C to stop and restore)"
echo
echo "    Attach DevTools to:"
echo "      $local_url"
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

exec ssh -o BatchMode=yes -N -L "$PORT:127.0.0.1:$remote_port" "$HOST"
