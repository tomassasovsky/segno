#!/usr/bin/env bash
# Tests for segno-touch-ctl: per-screen touch calibration (#1330).
#
# Whether a matrix lines up a finger with the screen needs the panel, so
# udevadm is stubbed and the input tree is a fake. What that leaves is the part
# that decides WHICH touchscreen a matrix reaches: the readout's controller is
# the one homescreen.toml names, every other touchscreen is the main screen's,
# and a live change re-adds only the touchscreen it is for.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-touch-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/touch-ctl-test.XXXXXX")
    mkdir -p "$work/bin" "$work/input/event4/device" "$work/input/event6/device" \
        "$work/input/event1/device" "$work/data" "$work/rules"
    echo "wch.cn USB2IIC_CTP_CONTROL" > "$work/input/event4/device/name"
    echo "SiS HID Touch Controller" > "$work/input/event6/device/name"
    echo "Keyboard" > "$work/input/event1/device/name"
    cat > "$work/homescreen.toml" <<'TOML'
[[view]]
  [view.output]
  drm_connector = 'HDMI-A-2'
  # The 7"'s controller.
  touch_device = 'USB2IIC_CTP_CONTROL'
TOML
    : > "$work/udevadm-calls"
    cat > "$work/bin/udevadm" <<STUB
#!/bin/sh
case "\$*" in
    info*event1*) echo "ID_INPUT_KEYBOARD=1" ;;
    info*) echo "ID_INPUT=1"; echo "ID_INPUT_TOUCHSCREEN=1" ;;
    *) echo "\$*" >> "$work/udevadm-calls" ;;
esac
exit 0
STUB
    chmod +x "$work/bin/udevadm"
}

teardown() { rm -rf "$work"; }

run_ctl() {
    PATH="$work/bin:$PATH" SEGNO_TOUCH_DIR="$work/data" \
        SEGNO_TOUCH_RULE="$work/rules/98-segno-touch-calibration.rules" \
        SEGNO_HOMESCREEN_CONFIG="$work/homescreen.toml" \
        SEGNO_INPUT_ROOT="$work/input" \
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

rule() { cat "$work/rules/98-segno-touch-calibration.rules" 2>/dev/null; }
calls() { cat "$work/udevadm-calls"; }
has() { grep -qF -- "$1" && echo yes || echo no; }

echo "get before any calibration"
setup
check "readout is uncalibrated" '{"calibrated":false,"matrix":""}' "$(run_ctl get readout)"
teardown

echo "set the readout"
setup
out=$(run_ctl set readout 1.1 0 -0.05 0 0.9 0.02)
check "prints the matrix" '{"calibrated":true,"matrix":"1.1 0 -0.05 0 0.9 0.02"}' "$out"
check "stored per screen" "1.1 0 -0.05 0 0.9 0.02" "$(cat "$work/data/readout")"
check "the rule matches the readout's controller by name" yes \
    "$(rule | has 'ATTRS{name}=="*USB2IIC_CTP_CONTROL*", ENV{LIBINPUT_CALIBRATION_MATRIX}="1.1 0 -0.05 0 0.9 0.02"')"
check "no rule for the uncalibrated main screen" no "$(rule | has 'ATTRS{name}!=')"
check "rules reloaded" yes "$(calls | has 'control --reload-rules')"
check "the readout's touchscreen is removed" yes "$(calls | has "trigger --action=remove $work/input/event4")"
check "and added back" yes "$(calls | has "trigger --action=add $work/input/event4")"
check "the main touchscreen is left alone" no "$(calls | has "$work/input/event6")"
check "a keyboard is never cycled" no "$(calls | has "$work/input/event1")"
teardown

echo "set the main screen next to the readout"
setup
run_ctl set readout 1 0 0 0 1 0 >/dev/null
: > "$work/udevadm-calls"
run_ctl set main 0.98 0 0.01 0 1.02 -0.01 >/dev/null
check "both screens have a rule" "2" "$(rule | grep -c 'LIBINPUT_CALIBRATION_MATRIX')"
check "the main rule comes first and matches every touchscreen" \
    'ACTION=="add|change", SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="0.98 0 0.01 0 1.02 -0.01"' \
    "$(rule | grep LIBINPUT | head -n1)"
check "the readout's rule comes after it, so it wins for the 7\"" yes \
    "$(rule | grep LIBINPUT | tail -n1 | has 'ATTRS{name}=="*USB2IIC_CTP_CONTROL*", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"')"
check "only the main touchscreen is re-added" yes "$(calls | has "trigger --action=add $work/input/event6")"
check "the readout's is not" no "$(calls | has "$work/input/event4")"
teardown

echo "rejects a malformed matrix or screen"
setup
run_ctl set readout 1 0 0 0 1 >/dev/null
check "five values exit 2" "2" "$?"
run_ctl set readout 1 0 0 0 1 1.2.3 >/dev/null
check "a non-number exits 2" "2" "$?"
check "nothing stored" no "$([ -e "$work/data/readout" ] && echo yes || echo no)"
run_ctl get both >/dev/null
check "an unknown screen exits 2" "2" "$?"
teardown

echo "reset"
setup
run_ctl set readout 1 0 0 0 1 0 >/dev/null
run_ctl set main 1 0 0 0 1 0 >/dev/null
: > "$work/udevadm-calls"
check "prints uncalibrated" '{"calibrated":false,"matrix":""}' "$(run_ctl reset readout)"
check "the 7\" falls back to the identity, not the main matrix" yes \
    "$(rule | grep LIBINPUT | tail -n1 | has 'ATTRS{name}=="*USB2IIC_CTP_CONTROL*", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"')"
check "the readout's touchscreen is re-added" yes "$(calls | has "trigger --action=add $work/input/event4")"
run_ctl reset main >/dev/null
check "no calibration, no rule file" no "$([ -e "$work/rules/98-segno-touch-calibration.rules" ] && echo yes || echo no)"
teardown

echo "apply at boot"
setup
run_ctl set main 1 0 0 0 1 0 >/dev/null
rm "$work/rules/98-segno-touch-calibration.rules"
: > "$work/udevadm-calls"
run_ctl apply >/dev/null
check "rebuilds the rule from /data" yes "$(rule | has 'ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"')"
check "refreshes the properties with a change" yes "$(calls | has 'trigger --subsystem-match=input --action=change')"
check "removes nothing: nothing has the devices open yet" no "$(calls | has 'action=remove')"
teardown

echo "try, then restore"
setup
run_ctl set main 1 0 0 0 1 0 >/dev/null
: > "$work/udevadm-calls"
out=$(run_ctl try main 1.2 0 -0.1 0 1 0)
check "prints the tried matrix" '{"calibrated":true,"matrix":"1.2 0 -0.1 0 1 0"}' "$out"
check "the rule carries it" yes "$(rule | has 'ENV{LIBINPUT_CALIBRATION_MATRIX}="1.2 0 -0.1 0 1 0"')"
check "/data does not" "1 0 0 0 1 0" "$(cat "$work/data/main")"
check "only the main touchscreen is re-added" yes "$(calls | has "trigger --action=add $work/input/event6")"
check "get reports what is kept" '{"calibrated":true,"matrix":"1 0 0 0 1 0"}' "$(run_ctl get main)"
check "restore prints what is kept" '{"calibrated":true,"matrix":"1 0 0 0 1 0"}' "$(run_ctl restore main)"
check "and the rule carries it again" no "$(rule | has '1.2 0 -0.1')"
run_ctl apply >/dev/null
run_ctl try readout 1 0 0.05 0 1 0 >/dev/null
run_ctl apply >/dev/null
check "a boot drops a try" no "$(rule | has '1 0 0.05 0 1 0')"
teardown

echo "no touch_device in the configuration"
setup
printf '[[view]]\n' > "$work/homescreen.toml"
run_ctl set main 1 0 0 0 1 0 >/dev/null
check "the readout cannot be calibrated: set exits 3" "3" "$(run_ctl set readout 1 0 0 0 1 0 >/dev/null; echo $?)"
check "nor tried" "3" "$(run_ctl try readout 1 0 0 0 1 0 >/dev/null; echo $?)"
check "nothing stored for it" no "$([ -e "$work/data/readout" ] && echo yes || echo no)"
check "no readout rule" no "$(rule | has 'ATTRS{name}==')"
check "the main rule covers every touchscreen" yes \
    "$(rule | has 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"')"
teardown

echo "a touch_device udev would read as a pattern"
setup
sed -i.bak "s/USB2IIC_CTP_CONTROL/USB2IIC*/" "$work/homescreen.toml"
check "is refused" "3" "$(run_ctl set readout 1 0 0 0 1 0 >/dev/null; echo $?)"
teardown

echo
echo "touch-ctl: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
