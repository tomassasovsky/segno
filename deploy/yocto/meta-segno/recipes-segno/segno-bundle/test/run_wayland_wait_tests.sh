#!/usr/bin/env bash
# Tests for segno-wait-wayland (#970).
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WAIT="$here/../files/segno-wait-wayland"

pass=0
fail=0

assert_eq() {
  local want=$1
  local got=$2
  local msg=$3
  if [ "$want" = "$got" ]; then
    pass=$((pass + 1))
    echo "ok: $msg"
  else
    fail=$((fail + 1))
    echo "FAIL: $msg (want=$want got=$got)"
  fi
}

# Short sock path — macOS sun_path is ~104 bytes; mktemp under /var/folders is long.
runtime=$(mktemp -d /tmp/segno-wl.XXXXXX)

err=$(mktemp)
set +e
SEGNO_WAYLAND_WAIT_ATTEMPTS=3 SEGNO_WAYLAND_SETTLE_SECS=0.05 SEGNO_WAYLAND_EGL_SECS=0 \
  XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=wayland-1 \
  "$WAIT" >/dev/null 2>"$err"
rc=$?
set -e
assert_eq 1 "$rc" "missing socket exits 1"
if grep -q "not ready" "$err"; then
  pass=$((pass + 1))
  echo "ok: missing socket logs not ready"
else
  fail=$((fail + 1))
  echo "FAIL: expected not-ready message"
fi
rm -f "$err"

# Stable socket → exit 0
python3 - "$runtime" wayland-1 <<'PY' &
import os, socket, time, sys
runtime, display = sys.argv[1], sys.argv[2]
path = os.path.join(runtime, display)
try:
    os.unlink(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(1)
time.sleep(30)
PY
holder=$!
sleep 0.2
set +e
SEGNO_WAYLAND_WAIT_ATTEMPTS=20 SEGNO_WAYLAND_SETTLE_SECS=0.05 SEGNO_WAYLAND_EGL_SECS=0 \
  XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=wayland-1 \
  "$WAIT" >/dev/null 2>&1
rc=$?
set -e
assert_eq 0 "$rc" "stable socket exits 0"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
rm -rf "$runtime"

echo "pass=$pass fail=$fail"
exit "$fail"
