#!/usr/bin/env bash
# Wiring tests for the weston journal drop-in (#947).
#
# Whether compositor lines actually appear in journalctl -u weston needs a
# device. What CANNOT be shown on a device once and then trusted is the
# wiring, because every way of breaking it is silent:
#
#   - drop the file from SRC_URI / do_install / FILES and the image ships
#     the stock ExecStart, so journalctl -u weston stays two systemd lines
#     and #825 is debugged blind again.
#   - append a second ExecStart= without the clearing ExecStart= and systemd
#     runs both, or ignores the override.
#   - lose systemd-notify.so and Type=notify hangs until timeout — a dark
#     screen, not a missing log.
#   - pass `-d drm-backend` (not a weston 14 flag) and weston refuses to start.
#
# So this asserts the drop-in and the recipe inventory statically.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BB="$here/../weston-init.bbappend"
DROPIN="$here/../files/20-segno-weston-journal.conf"

pass=0
fail=0

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

has() { grep -qF -- "$1" "$2" && echo yes || echo no; }

echo "the drop-in replaces ExecStart and keeps notify"
check "clears stock ExecStart first" yes \
    "$(awk '
        $0 == "ExecStart=" { empty = 1; next }
        empty && $0 ~ /^ExecStart=/ { print "yes"; exit }
        END { if (!empty) print "no" }
    ' "$DROPIN")"
check "keeps systemd-notify.so (Type=notify)" yes \
    "$(has '--modules=systemd-notify.so' "$DROPIN")"
check "pins the compositor log to stderr" yes \
    "$(has '--log=/dev/stderr' "$DROPIN")"
check "subscribes the drm-backend log scope" yes \
    "$(has '--logger-scopes=drm-backend' "$DROPIN")"
check "does not use -d drm-backend (not a weston 14 flag)" yes \
    "$(grep -qE -- '(^|[[:space:]])-d[[:space:]]+drm-backend' "$DROPIN" && echo no || echo yes)"

echo "the recipe ships the drop-in"
check "SRC_URI names the drop-in" yes \
    "$(has 'file://20-segno-weston-journal.conf' "$BB")"
check "do_install writes it under weston.service.d" yes \
    "$(has 'weston.service.d/20-segno-weston-journal.conf' "$BB")"
check "FILES names the drop-in (else it is installed-but-not-shipped)" yes \
    "$(has '${systemd_system_unitdir}/weston.service.d/20-segno-weston-journal.conf' "$BB")"

echo
echo "weston-journal: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
