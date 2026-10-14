#!/usr/bin/env bash
# Run a PROFILE-mode Segno bundle on the appliance and expose its Dart VM service
# to a DevTools session on your workstation. See #638.
#
# Why this exists: the installed appliance bundle is release-mode AOT on the
# release engine, with no VM service, so DevTools has nothing to attach to, and
# the Yocto image is a pure runtime with no toolchain, so it cannot build a
# profile bundle itself. Get one from the `appliance-profile-bundle` workflow:
#
#   gh run download <run-id> -n segno-appliance-profile -D /tmp/segno-profile
#   deploy/rpi/profile-on-device.sh /tmp/segno-profile
#
# or build it locally with deploy/rpi/build/build-arm64-bundle.sh --profile and
# pass build/appliance/profile-bundle.
#
# The release install at /opt/segno is never touched: the profile bundle goes to
# /data/profile (the persistent partition OTA preserves, and the only one with
# room to spare). It carries its own profile engine, lib/libflutter_engine.so,
# which LD_LIBRARY_PATH puts ahead of the release engine the image ships; a
# profile snapshot runs only on a profile engine.
#
# The profile build runs through the shipped launcher, /usr/bin/segno-kiosk-launch,
# with SEGNO_ENGINE_LIB and SEGNO_HOMESCREEN_CONFIG pointed at /data/profile and
# LD_LIBRARY_PATH at its lib/ (which every process the app starts inherits), so
# it gets the same HOME, ALSA and RT settings as the appliance. It runs as a
# transient systemd unit, segno-devtools, with segno.service's limits and stop
# handling; segno.service is stopped for the duration, because
# both screens and the audio device belong to one process at a time, and is
# started again on exit however this script ends.
#
# Its homescreen.toml is the installed one with the bundle path changed and two
# engine switches added: a fixed VM service port and no auth code. ivi-homescreen
# passes `engine` switches to the Flutter engine as they are. Both views share
# one Dart VM, so DevTools sees the main and the readout isolates on the one
# port.
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

if [ -z "$BUNDLE" ] || [ ! -f "$BUNDLE/lib/libapp.so" ] \
  || [ ! -f "$BUNDLE/lib/libflutter_engine.so" ]; then
  cat >&2 <<USAGE
usage: $0 <profile-bundle-dir> [user@host]

  <profile-bundle-dir>  the profile bundle: data/ and lib/, with
                        lib/libflutter_engine.so -- the unpacked
                        segno-appliance-profile CI artifact, or
                        build/appliance/profile-bundle.

  SEGNO_VM_PORT         VM service port, on both ends (default 8181).
USAGE
  exit 2
fi

remote() { ssh -o BatchMode=yes "$HOST" "$@"; }

echo "==> checking $HOST"
remote 'command -v tar >/dev/null && command -v systemd-run >/dev/null' \
  || { echo "no tar or systemd-run on the device" >&2; exit 1; }

# The rootfs is A/B-swapped by OTA and has little room; /data has it and
# survives updates. Bail rather than half-copy if it is tight.
avail=$(remote "df -k /data | awk 'NR==2{print \$4}'")
if [ "$avail" -lt 524288 ]; then
  echo "/data has less than 512MB free (${avail}K) -- free space first" >&2
  exit 1
fi

# A session whose workstation went away can leave its unit behind; it holds the
# screens and runs from the directory about to be replaced.
remote 'systemctl stop segno-devtools.service 2>/dev/null; systemctl reset-failed segno-devtools.service 2>/dev/null; true'

echo "==> copying bundle to $REMOTE_DIR"
remote "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR/bundle"
tar -C "$BUNDLE" -cf - . | remote "tar -C $REMOTE_DIR/bundle -xf -"
remote "sed \
  -e \"s#^bundle = '/opt/segno'#bundle = '$REMOTE_DIR/bundle'#\" \
  -e \"s#engine = \\['--enable-impeller=false'\\]#engine = ['--enable-impeller=false', '--vm-service-port=$PORT', '--disable-service-auth-codes']#\" \
  /etc/segno/homescreen.toml > $REMOTE_DIR/homescreen.toml"
# A sed that matched nothing would run the release bundle, or one with no VM
# service, and look like a working profile session.
remote "[ \$(grep -c \"^bundle = '$REMOTE_DIR/bundle'\" $REMOTE_DIR/homescreen.toml) -eq 2 ] \
  && [ \$(grep -c -- '--vm-service-port=$PORT' $REMOTE_DIR/homescreen.toml) -eq 2 ]" \
  || { echo "the installed homescreen.toml no longer has the lines this script rewrites" >&2; exit 1; }

# Whatever happens next -- success, failure, Ctrl-C -- the appliance goes back to
# running its release build. Leaving a floor unit dark is not an acceptable exit.
# Set before segno.service stops, so an interrupt during the stop restores too;
# INT and TERM exit, so the EXIT trap runs once and the script goes no further.
restore() {
  echo
  echo "==> stopping the profile build"
  remote 'systemctl stop segno-devtools.service 2>/dev/null; systemctl reset-failed segno-devtools.service 2>/dev/null; true' || true
  echo "==> restoring segno.service"
  remote 'systemctl start segno.service' || true
}
trap restore EXIT
trap 'exit 130' INT TERM

echo "==> stopping segno.service"
remote 'systemctl stop segno.service'

echo "==> starting the profile build"
# segno.service's limits and stop handling. ExecStopPost brings the release
# build back from the device itself whenever this unit stops: the profile build
# crashing, or this workstation dropping off the network, must not leave the
# floor dark until someone reconnects.
remote "systemd-run --unit=segno-devtools --collect \
  --property=LimitRTPRIO=95 --property=LimitMEMLOCK=infinity \
  --property=LimitCORE=infinity --property=TimeoutStopSec=15s \
  --property=TimeoutStopFailureMode=abort --property=TimeoutAbortSec=120s \
  --property='ExecStopPost=/usr/bin/systemctl --no-block start segno.service' \
  --setenv=LD_LIBRARY_PATH=$REMOTE_DIR/bundle/lib \
  --setenv=SEGNO_ENGINE_LIB=$REMOTE_DIR/bundle/lib/libsegno_engine.so \
  --setenv=SEGNO_HOMESCREEN_CONFIG=$REMOTE_DIR/homescreen.toml \
  /usr/bin/segno-kiosk-launch"

# This run's log only: an earlier session this boot logged the same line.
invocation=$(remote 'systemctl show -p InvocationID --value segno-devtools.service')
log="journalctl _SYSTEMD_INVOCATION_ID=$invocation --no-pager -o cat"

echo "==> waiting for the VM service"
up=""
for _ in $(seq 1 30); do
  sleep 1
  if remote "$log | grep -q 'http://127\.0\.0\.1:$PORT/'"; then
    up=1
    break
  fi
done

if [ -z "$up" ]; then
  echo "no VM service on port $PORT after 30s. Device-side log:" >&2
  remote "$log | tail -30" >&2 || true
  exit 1
fi

echo "==> VM service up on device port $PORT"
echo "==> forwarding localhost:$PORT -> device:$PORT (Ctrl-C to stop and restore)"
echo
echo "    Attach DevTools to:"
echo "      http://127.0.0.1:$PORT/"
echo
echo "    Measure, in this order:"
echo "      1. idle console          -- the floor for everything else"
echo "      2. a record/overdub pass -- the 16ms snapshot poll under load"
echo "      3. tray open/close       -- implicit animations + layout"
echo "      4. the Track display     -- two engines on one V3D"
echo
echo "    What decides the work: UI thread over budget -> the poll timer and"
echo "    context.watch fan-out. Raster over budget -> RepaintBoundary, the"
echo "    per-sample waveform rects, card elevation."
echo

# ExitOnForwardFailure: a port already taken here would otherwise leave DevTools
# attached to whatever holds it. ServerAlive: notice a dead link and exit, so
# the restore runs.
ssh -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -N -L "$PORT:127.0.0.1:$PORT" "$HOST"
