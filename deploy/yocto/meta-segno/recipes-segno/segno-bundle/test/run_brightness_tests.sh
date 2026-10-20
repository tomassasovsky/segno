#!/usr/bin/env bash
# Tests for `segno-brightness-ctl --connector` (#1270 Part 9).
#
# Whether a panel actually dims needs the panel, so `ddcutil` is stubbed and
# the DRM tree is a fake. What that leaves is the part that decides WHICH
# panel a slider reaches: a connector resolves to the I2C bus its DRM
# connector exposes, and nothing else is addressed.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-brightness-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/brightness-test.XXXXXX")
    mkdir -p "$work/bin" "$work/drm/card1-HDMI-A-1" "$work/drm/card1-HDMI-A-2" \
        "$work/devices/i2c-7" "$work/devices/i2c-4"
    ln -s "$work/devices/i2c-7" "$work/drm/card1-HDMI-A-2/ddc"
    ln -s "$work/devices/i2c-4" "$work/drm/card1-HDMI-A-1/ddc"
    : > "$work/ddcutil-calls"

    cat > "$work/bin/ddcutil" <<STUB
#!/bin/sh
echo "\$*" >> "$work/ddcutil-calls"
case "\$*" in
    *"--bus 9"*) exit 1 ;;
    *detect*) echo "Display 1" ;;
    *getvcp*) echo "VCP code 0x10 (Brightness): current value =    40, max value =   100" ;;
esac
exit 0
STUB
    chmod +x "$work/bin/ddcutil"
}

teardown() { rm -rf "$work"; }

run_ctl() {
    PATH="$work/bin:$PATH" SEGNO_DRM_ROOT="$work/drm" \
        "${TEST_SHELL:-sh}" "$SCRIPT" "$@" 2>"$work/stderr"
}

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        [ -s "$work/stderr" ] && sed 's/^/       | /' "$work/stderr"
        fail=$((fail + 1))
    fi
}

calls() { cat "$work/ddcutil-calls"; }
last_call() { tail -n1 "$work/ddcutil-calls"; }

echo "set on one connector"
setup
out=$(run_ctl set 50 --connector HDMI-A-2); rc=$?
check "exits 0" 0 "$rc"
check "reports the percent" '{"supported":true,"percent":50}' "$out"
check "sets that panel's bus only" "--bus 7 setvcp 10 50" "$(last_call)"
check "never addresses the other panel" "0" "$(grep -c -- '--bus 4' "$work/ddcutil-calls")"
teardown

echo "the flag may come first"
setup
run_ctl set --connector HDMI-A-1 30 >/dev/null
check "sets the main panel's bus" "--bus 4 setvcp 10 30" "$(last_call)"
teardown

echo "supported per connector"
setup
check "a panel that answers on its bus" '{"supported":true}' "$(run_ctl supported --connector HDMI-A-2)"
check "asked on that bus" "--bus 7 getvcp 10" "$(last_call)"
teardown

echo "a connector with no DDC bus"
setup
rm "$work/drm/card1-HDMI-A-2/ddc"
check "is unsupported" '{"supported":false}' "$(run_ctl supported --connector HDMI-A-2)"
run_ctl set 50 --connector HDMI-A-2 >/dev/null; rc=$?
check "set fails, so the app falls back" 1 "$rc"
check "and never runs ddcutil" "" "$(calls)"
teardown

echo "a panel that does not answer on its bus"
setup
rm "$work/drm/card1-HDMI-A-2/ddc"
mkdir -p "$work/devices/i2c-9"
ln -s "$work/devices/i2c-9" "$work/drm/card1-HDMI-A-2/ddc"
check "is unsupported" '{"supported":false}' "$(run_ctl supported --connector HDMI-A-2)"
run_ctl set 50 --connector HDMI-A-2 >/dev/null; rc=$?
check "set fails rather than reporting success" 1 "$rc"
teardown

echo "set never reads before writing"
setup
run_ctl set 50 --connector HDMI-A-2 >/dev/null
check "one call, the write" "--bus 7 setvcp 10 50" "$(calls)"
teardown

echo "an empty connector name"
setup
run_ctl set 50 --connector "" >/dev/null; rc=$?
check "is refused" 2 "$rc"
check "with no ddcutil call" "" "$(calls)"
teardown

echo "get on one connector"
setup
check "reads that panel" '{"supported":true,"percent":40}' "$(run_ctl get --connector HDMI-A-1)"
check "on its bus" "--bus 4 getvcp 10" "$(last_call)"
teardown

echo "without the flag"
setup
run_ctl set 60 >/dev/null
check "the old behaviour: no bus" "setvcp 10 60" "$(last_call)"
teardown

echo "a connector name that is a path"
setup
run_ctl set 50 --connector ../x >/dev/null; rc=$?
check "is refused" 2 "$rc"
check "with no ddcutil call" "" "$(calls)"
teardown

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
