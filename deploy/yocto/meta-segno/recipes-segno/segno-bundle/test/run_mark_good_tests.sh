#!/usr/bin/env bash
# Tests for `segno-mark-good` (#307, #976).
#
# This script decides whether an OS update is kept or thrown away. Both
# mistakes are silent and expensive: refuse to mark a healthy slot and the user
# loses an update they watched install (observed live — updated, set up Wi-Fi,
# rebooted, came back on the old version); mark a broken one and A/B rollback,
# the entire reason the appliance has two slots, stops protecting anything
# (#976: a crash-looping build was committed).
#
# `systemctl`, `rauc` and `fdtget` are stubbed and the health window is
# compressed to keep the suite fast, so what is asserted is the decision, which
# is the part with consequences. TEST_SHELL picks the shell the script runs
# under (CI runs bash and dash).
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FILES="$here/../files"
SCRIPT="$FILES/segno-mark-good"

pass=0
fail=0

# Stub systemctl. Each answer comes from its own file, one line per call,
# reused once exhausted: $work/active for is-active, and $work/MainPID,
# $work/NRestarts and $work/StatusText for `show -p <property>`. A stub that
# answered every property from one file would let a test pass for the wrong
# reason (a MainPID change hidden behind a constant NRestarts).
setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/mark-good-test.XXXXXX")
    mkdir -p "$work/bin"
    printf 'yes\n' > "$work/active"
    printf '100\n' > "$work/MainPID"
    printf '0\n' > "$work/NRestarts"
    printf 'alive 1 readout 1 audio ok\nalive 10 readout 9 audio ok\n' \
        > "$work/StatusText"
    printf '1\n' > "$work/tryboot"

    cat > "$work/bin/systemctl" <<STUB
#!/bin/sh
next() {
    file=\$1
    line=\$(head -n1 "\$file")
    remaining=\$(tail -n +2 "\$file")
    [ -n "\$remaining" ] && printf '%s\n' "\$remaining" > "\$file"
    printf '%s' "\$line"
}
case "\$1" in
    is-active) [ "\$(next "$work/active")" = yes ] ;;
    show)
        [ "\$2" = -p ] || exit 2
        [ -f "$work/\$3" ] || exit 1
        next "$work/\$3"; echo ;;
    reboot) echo reboot >> "$work/reboots" ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$work/bin/systemctl"

    cat > "$work/bin/rauc" <<STUB
#!/bin/sh
echo "\$@" > "$work/rauc-args"
exit \${RAUC_EXIT:-0}
STUB
    chmod +x "$work/bin/rauc"

    # fdtget <fdt> <node> <property>; fails when there is no flag file.
    cat > "$work/bin/fdtget" <<STUB
#!/bin/sh
[ "\$1" = "$work/fdt" ] && [ "\$2" = /chosen/bootloader ] && [ "\$3" = tryboot ] || exit 2
[ -f "$work/tryboot" ] || exit 1
cat "$work/tryboot"
STUB
    chmod +x "$work/bin/fdtget"
}

teardown() { rm -rf "$work"; }

run_mark_good() {
    SEGNO_SYSTEMCTL="$work/bin/systemctl" \
    SEGNO_RAUC="$work/bin/rauc" \
    SEGNO_FDTGET="$work/bin/fdtget" \
    SEGNO_FDT="$work/fdt" \
    SEGNO_MARK_GOOD_WAIT_SECS="${WAIT_OVERRIDE:-4}" \
    SEGNO_MARK_GOOD_STABLE_SECS="${STABLE_OVERRIDE:-0}" \
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

marked() { [ -f "$work/rauc-args" ] && echo yes || echo no; }
reboots() { [ -f "$work/reboots" ] && wc -l < "$work/reboots" | tr -d ' ' || echo 0; }
said() { grep -q "$1" "$work/stderr" && echo yes || echo no; }

# A refusal: exit 1, nothing committed, the reason in the log, and one reboot
# on a trial boot.
expect_refused() {
    local why=$1
    run_mark_good; rc=$?
    check "refuses" 1 "$rc"
    check "does NOT commit" no "$(marked)"
    check "says why" yes "$(said "$why")"
    check "reboots into the committed slot" 1 "$(reboots)"
}

echo "app up, drawing, heartbeat and readout advancing"
setup
run_mark_good; rc=$?
check "exits 0" 0 "$rc"
check "commits the booted slot" yes "$(marked)"
check "uses mark-good booted" "status mark-good booted" \
    "$(cat "$work/rauc-args" 2>/dev/null)"
check "no reboot" 0 "$(reboots)"
teardown

echo "app takes a moment to become ready"
setup
# Not ready for the first two polls, then ready: a slow first boot is normal,
# not a reason to throw the update away.
printf 'no\nno\nyes\n' > "$work/active"
run_mark_good; rc=$?
check "waits rather than refusing" 0 "$rc"
check "commits" yes "$(marked)"
teardown

echo "app never becomes ready, trial boot"
setup
printf 'no\n' > "$work/active"
expect_refused 'never became ready'
teardown

echo "app never becomes ready, committed boot"
setup
printf 'no\n' > "$work/active"
printf '0\n' > "$work/tryboot"
run_mark_good; rc=$?
check "refuses" 1 "$rc"
check "does NOT commit" no "$(marked)"
check "never reboots a committed slot (no loop)" 0 "$(reboots)"
teardown

echo "tryboot flag unreadable"
setup
printf 'no\n' > "$work/active"
rm -f "$work/tryboot"
run_mark_good; rc=$?
check "refuses" 1 "$rc"
check "does not reboot when it cannot tell" 0 "$(reboots)"
teardown

echo "app dies during the health window"
setup
printf 'yes\nno\n' > "$work/active"
expect_refused 'stopped during'
teardown

echo "MainPID changes while NRestarts stays (#976)"
setup
# The case #976 hit: NRestarts read 0 through a crash loop. Only the pid
# gives it away, which a stub answering every property alike would hide.
printf '100\n230\n' > "$work/MainPID"
expect_refused 'MainPID 100 -> 230'
teardown

echo "NRestarts changes"
setup
printf '0\n3\n' > "$work/NRestarts"
expect_refused 'NRestarts 0 -> 3'
teardown

echo "heartbeat frozen (a hung UI isolate)"
setup
printf 'alive 7 readout 7 audio ok\nalive 7 readout 9 audio ok\n' > "$work/StatusText"
expect_refused 'heartbeat did not advance'
teardown

echo "no heartbeat at all (a build that never sends STATUS)"
setup
printf '\n' > "$work/StatusText"
expect_refused 'heartbeat did not advance'
teardown

echo "garbled heartbeat"
setup
printf 'alive x readout 1 audio ok\nalive 9 readout 2 audio ok\n' > "$work/StatusText"
expect_refused 'heartbeat did not advance'
teardown

echo "readout stops answering while connected"
setup
printf 'alive 1 readout 4 audio ok\nalive 10 readout 4 audio ok\n' > "$work/StatusText"
expect_refused 'readout stopped answering'
teardown

echo "readout not connected"
setup
printf 'alive 1 readout none audio ok\nalive 10 readout none audio ok\n' > "$work/StatusText"
run_mark_good; rc=$?
check "commits without a readout" 0 "$rc"
check "commits" yes "$(marked)"
teardown

echo "readout plugged in during the window"
setup
printf 'alive 1 readout none audio ok\nalive 10 readout 2 audio ok\n' > "$work/StatusText"
run_mark_good; rc=$?
check "one counted sample proves nothing either way" 0 "$rc"
teardown

echo "readout pulled out during the window"
setup
printf 'alive 1 readout 5 audio ok\nalive 10 readout none audio ok\n' > "$work/StatusText"
run_mark_good; rc=$?
check "commits" 0 "$rc"
teardown

echo "interface present, engine refused through the window"
setup
printf 'alive 1 readout 1 audio refused\nalive 10 readout 9 audio refused\n' > "$work/StatusText"
expect_refused 'not running on the interface'
teardown

echo "audio refused for a moment (an Apply, a reconnect)"
setup
printf 'alive 1 readout 1 audio refused\nalive 10 readout 9 audio ok\n' > "$work/StatusText"
run_mark_good; rc=$?
check "one refused sample does not throw the build away" 0 "$rc"
teardown
setup
printf 'alive 1 readout 1 audio ok\nalive 10 readout 9 audio refused\n' > "$work/StatusText"
run_mark_good; rc=$?
check "nor at the end of the window" 0 "$rc"
teardown

echo "interface absent"
setup
printf 'alive 1 readout 1 audio absent\nalive 10 readout 9 audio absent\n' > "$work/StatusText"
run_mark_good; rc=$?
check "an unplugged interface is not the build's fault" 0 "$rc"
check "commits" yes "$(marked)"
teardown

echo "rauc itself refuses after a healthy window"
setup
RAUC_EXIT=1 run_mark_good; rc=$?
check "surfaces the failure" 1 "$rc"
check "says so" yes "$(said 'refused to mark')"
check "never reboots a healthy app (#1397: read-only /boot)" 0 "$(reboots)"
teardown

echo "the units carry the readiness contract"
work=$(mktemp -d "${TMPDIR:-/tmp}/mark-good-test.XXXXXX")
unit="$FILES/segno.service"
gate="$FILES/segno-mark-good.service"
launch="$FILES/segno-kiosk-launch"
recipe="$here/../segno-bundle.bb"
check "segno.service is Type=notify" yes \
    "$(grep -qx 'Type=notify' "$unit" && echo yes || echo no)"
check "only the app's own pid may notify" yes \
    "$(grep -qx 'NotifyAccess=main' "$unit" && echo yes || echo no)"
check "a build that never draws is killed after 180 s" yes \
    "$(grep -qx 'TimeoutStartSec=180' "$unit" && echo yes || echo no)"
wait_default=$(sed -n 's/^WAIT_SECS="\${SEGNO_MARK_GOOD_WAIT_SECS:-\([0-9]*\)}"$/\1/p' "$SCRIPT")
start_timeout=$(sed -n 's/^TimeoutStartSec=\([0-9]*\)$/\1/p' "$unit")
check "the gate outwaits segno's start timeout" yes \
    "$([ -n "$wait_default" ] && [ -n "$start_timeout" ] &&
        [ "$wait_default" -gt "$start_timeout" ] && echo yes || echo no)"
check "no service watchdog (never kill a working app mid-set)" no \
    "$(grep -q '^WatchdogSec=' "$unit" && echo yes || echo no)"
check "the gate does not wait for segno's start job" no \
    "$(grep -q '^After=.*segno\.service' "$gate" && echo yes || echo no)"
check "the gate still pulls the app in" yes \
    "$(grep -qx 'Wants=segno.service' "$gate" && echo yes || echo no)"
check "the launcher execs the app (it is MainPID)" yes \
    "$(grep -q '^exec /usr/bin/segno ' "$launch" && echo yes || echo no)"
check "the launcher keeps NOTIFY_SOCKET" no \
    "$(grep -qE 'env -i|unset .*NOTIFY_SOCKET|NOTIFY_SOCKET=' "$launch" && echo yes || echo no)"
check "fdtget is a named runtime dependency" yes \
    "$(grep -qE '^RDEPENDS:\$\{PN\} = ".* dtc( |\\)' "$recipe" && echo yes || echo no)"
rm -rf "$work"

echo
echo "mark-good: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
