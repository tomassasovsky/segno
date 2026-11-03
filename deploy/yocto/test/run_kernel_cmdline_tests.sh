#!/usr/bin/env bash
# Wiring tests for the kernel's HDMI force-on (#821, #1318, #1591).
#
# The `D` in `video=HDMI-A-*:...D` keeps both connectors enabled whatever the
# hotplug line says. A panel that drops HPD for a moment (a sleeping TV, a
# loose cable) then stays a connector the embedder drives, and a 7" that is
# absent at boot does not make ivi-homescreen exit for want of the connector
# homescreen.toml pins.
#
# The mode is each panel's native one: 1920x1080 for the 15.6" main screen on
# HDMI-A-2, 1024x600 for the 7" readout on HDMI-A-1 (#1591). Both connectors
# read an empty EDID on the console, so the forced mode is what puts the
# native mode in each connector's list. The main view takes the first listed
# mode; the readout's view pins 1024x600@60 in homescreen.toml, because its
# connector lists the kernel's 1024x768 fallback first. Every way of breaking
# this is silent on the device:
#
#   - drop the `D` and the image follows HPD again.
#   - leave a `video=HDMI-A-*:...` (no D) next to the D spec and which one
#     wins is kernel-version-dependent (#741).
#   - force the readout to 1920x1080 and its panel scales the signal down,
#     the readout drawn at 1200x675 logical.
#   - drop the readout's pin and it runs at 1024x768, squeezed to 1024x600.
#   - pin a mode the command line does not force and ivi-homescreen exits at
#     start for want of it.
#
# So this asserts the kas cmdline and homescreen.toml statically.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KAS="$here/../kas-segno-common.yml"
TOML="$here/../meta-segno/recipes-segno/segno-bundle/files/homescreen.toml"

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
check "HDMI-A-1 (the 7in readout) is 1024x600@60D" yes \
    "$(cmdline | grep -qF 'video=HDMI-A-1:1024x600@60D' && echo yes || echo no)"
check "HDMI-A-2 (the main screen) is 1920x1080@60D" yes \
    "$(cmdline | grep -qF 'video=HDMI-A-2:1920x1080@60D' && echo yes || echo no)"
check "one video= for HDMI-A-1" 1 \
    "$(cmdline | grep -oE 'video=HDMI-A-1:[^ "]*' | wc -l | tr -d ' ')"
check "one video= for HDMI-A-2" 1 \
    "$(cmdline | grep -oE 'video=HDMI-A-2:[^ "]*' | wc -l | tr -d ' ')"

# The `mode` of the [[view]] whose drm_connector is $1 (empty when unpinned).
# A view's own tables ([view.*]) belong to it; any other table header ends it.
# Values lose their quotes, an inline comment and surrounding blanks.
view_mode() {
    awk -v want="$1" '
        function value(line) {
            sub(/^[^=]*=[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*$/, "", line)
            gsub(/["\047]/, "", line)
            sub(/[[:space:]]+$/, "", line)
            return line
        }
        /^[[:space:]]*\[\[view\]\]/ { n++; inview = 1; next }
        /^[[:space:]]*\[view\./ { inview = n > 0; next }
        /^[[:space:]]*\[/ { inview = 0; next }
        inview && /^[[:space:]]*drm_connector[[:space:]]*=/ { conn[n] = value($0) }
        inview && /^[[:space:]]*mode[[:space:]]*=/ { mode[n] = value($0) }
        END { for (i = 1; i <= n; i++) if (conn[i] == want) print mode[i] }
    ' "$TOML"
}

# The pixel area of a `WxH` mode.
area() {
    echo $(( ${1%x*} * ${1#*x} ))
}

echo
echo "homescreen.toml pins the readout to the mode the kernel forces"
check "homescreen.toml is where the test expects" yes \
    "$([ -f "$TOML" ] && echo yes || echo no)"
readout_pin=$(view_mode HDMI-A-1)
check "the HDMI-A-1 view pins a mode" yes \
    "$([ -n "$readout_pin" ] && echo yes || echo no)"
check "the HDMI-A-1 pin is the mode the kernel forces" yes \
    "$([ -n "$readout_pin" ] && cmdline | grep -qF "video=HDMI-A-1:${readout_pin}D" && echo yes || echo no)"
check "the HDMI-A-2 view takes the first listed mode" "" "$(view_mode HDMI-A-2)"
# Unpinned, the main view runs the first mode its connector lists. With no
# EDID the kernel sorts the list by size, so the forced mode must be larger
# than its 1024x768 fallback, or the main screen runs at that.
main_mode=$(cmdline | grep -oE 'video=HDMI-A-2:[0-9]+x[0-9]+' | head -1)
main_mode=${main_mode#video=HDMI-A-2:}
check "HDMI-A-2's forced mode is larger than the 1024x768 fallback" yes \
    "$([ -n "$main_mode" ] && [ "$(area "$main_mode")" -gt $((1024 * 768)) ] && echo yes || echo no)"

echo
echo "kernel-cmdline: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
