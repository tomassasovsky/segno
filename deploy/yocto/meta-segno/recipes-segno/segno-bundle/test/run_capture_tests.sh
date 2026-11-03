#!/usr/bin/env bash
# Tests for segno-capture: ask the app for a PNG of each screen (#1555).
#
# The app is a stand-in shell process that catches SIGUSR1 and writes a PNG
# per screen it is told to draw, the way each Flutter engine does: under a
# .part name first, then renamed. systemctl is stubbed to name its pid, and
# /proc is a fake, so the signal-mask check can be driven both ways.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-capture"

pass=0
fail=0
app=

# SIGUSR1 caught (bit 9 set), as the app reports it once a screen is up.
CATCHES_USR1=0000000000004a02
# The same mask without SIGUSR1: an app that is still starting.
NO_USR1=0000000000004802

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/capture-test.XXXXXX")
    mkdir -p "$work/bin" "$work/capture" "$work/proc"
    : > "$work/signals"
}

# Starts the stand-in app. It draws the screens in $1 ("main readout",
# "main", or "") on each SIGUSR1, and its status reports the mask $2.
start_app() {
    local screens=$1 mask=$2
    cat > "$work/app.sh" <<APP
#!/bin/sh
n=0
draw() {
    n=\$((n + 1))
    echo usr1 >> "$work/signals"
    for s in $screens; do
        f="$work/capture/\$s-20261103T1200\$(printf '%02d' \$n).000Z.png"
        echo png > "\$f.part"
        sleep 0.2
        mv "\$f.part" "\$f"
    done
}
trap draw USR1
: > "$work/ready"
while :; do sleep 0.05; done
APP
    sh "$work/app.sh" &
    app=$!
    while [ ! -e "$work/ready" ]; do sleep 0.02; done
    mkdir -p "$work/proc/$app"
    printf 'Name:\tsegno\nSigCgt:\t%s\n' "$mask" > "$work/proc/$app/status"
    stub_systemctl "$app"
}

stub_systemctl() {
    cat > "$work/bin/systemctl" <<STUB
#!/bin/sh
echo "$1"
STUB
    chmod +x "$work/bin/systemctl"
}

teardown() {
    if [ -n "$app" ]; then
        kill "$app" 2>/dev/null
        wait "$app" 2>/dev/null
        app=
    fi
    rm -rf "$work"
}

run_capture() {
    PATH="$work/bin:$PATH" SEGNO_CAPTURE_DIR="$work/capture" \
        SEGNO_PROC_ROOT="$work/proc" SEGNO_CAPTURE_TIMEOUT=2 \
        "${TEST_SHELL:-sh}" "$SCRIPT" 2>"$work/stderr"
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

signals() { wc -l < "$work/signals" | tr -d ' '; }

echo "both screens draw"
setup
start_app "main readout" "$CATCHES_USR1"
echo old > "$work/capture/main-20261102T000000.000Z.png"
out=$(run_capture)
check "exits 0" 0 $?
check "prints the new main capture, then the readout's" \
    "$work/capture/main-20261103T120001.000Z.png
$work/capture/readout-20261103T120001.000Z.png" "$out"
check "one signal sent" 1 "$(signals)"
teardown

echo "a second capture reports only the new files"
setup
start_app "main readout" "$CATCHES_USR1"
run_capture >/dev/null
out=$(run_capture)
check "exits 0" 0 $?
check "prints the second pair" \
    "$work/capture/main-20261103T120002.000Z.png
$work/capture/readout-20261103T120002.000Z.png" "$out"
teardown

echo "the readout draws nothing"
setup
start_app "main" "$CATCHES_USR1"
out=$(run_capture)
check "exits 1" 1 $?
check "still prints the main capture" "$work/capture/main-20261103T120001.000Z.png" "$out"
check "names the screen that wrote nothing" yes \
    "$(grep -q 'no capture from: readout' "$work/stderr" && echo yes || echo no)"
teardown

echo "an app that does not catch SIGUSR1 yet is not signalled"
setup
start_app "main readout" "$NO_USR1"
out=$(run_capture)
check "exits 2" 2 $?
check "prints nothing" "" "$out"
check "no signal sent" 0 "$(signals)"
check "the app is still running" yes "$(kill -0 "$app" 2>/dev/null && echo yes || echo no)"
teardown

echo "the app is not running"
setup
stub_systemctl 0
out=$(run_capture)
check "exits 2" 2 $?
check "says so" yes "$(grep -q 'not running' "$work/stderr" && echo yes || echo no)"
teardown

echo "the app's status cannot be read"
setup
stub_systemctl 99999999
out=$(run_capture)
check "exits 2" 2 $?
teardown

echo
echo "segno-capture: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
