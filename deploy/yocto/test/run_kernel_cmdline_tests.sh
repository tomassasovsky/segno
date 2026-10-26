#!/usr/bin/env bash
# Wiring tests for the kernel's HDMI force-on (#821, #1318).
#
# The `D` in `video=HDMI-A-*:...D` keeps both connectors enabled whatever the
# hotplug line says. A panel that drops HPD for a moment (a sleeping TV, a
# loose cable) then stays a connector the embedder drives, and a 7" that is
# absent at boot does not make ivi-homescreen exit for want of the connector
# homescreen.toml pins. Every way of breaking that is silent on the device:
#
#   - drop the `D` and the image follows HPD again.
#   - leave a `video=HDMI-A-*:...@60` (no D) next to the D spec and which one
#     wins is kernel-version-dependent (#741).
#
# So this asserts the kas cmdline statically.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KAS="$here/../kas-segno-common.yml"

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

# The kiosk-console CMDLINE:append line (not comments).
cmdline() {
    grep -E '^[[:space:]]*CMDLINE:append' "$KAS"
}

echo "the kernel cmdline force-enables both HDMI connectors"
check "kas file is where the test expects" yes \
    "$([ -f "$KAS" ] && echo yes || echo no)"
check "HDMI-A-1 is 1920x1080@60D" yes \
    "$(cmdline | grep -qF 'video=HDMI-A-1:1920x1080@60D' && echo yes || echo no)"
check "HDMI-A-2 is 1920x1080@60D" yes \
    "$(cmdline | grep -qF 'video=HDMI-A-2:1920x1080@60D' && echo yes || echo no)"
check "no HDMI-A-1 video= without D" yes \
    "$(cmdline | grep -qE 'video=HDMI-A-1:1920x1080@60([^D]|$)' && echo no || echo yes)"
check "no HDMI-A-2 video= without D" yes \
    "$(cmdline | grep -qE 'video=HDMI-A-2:1920x1080@60([^D]|$)' && echo no || echo yes)"

echo
echo "kernel-cmdline: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
