#!/usr/bin/env bash
# Tests for segno-freeze-watchdog (#1527).
#
# 1. The unit tests (test_freeze_watchdog.c): the decision, the prober with fake
#    probes (passing, failing, stuck), the real probes, the recovery sequence
#    and the systemd notification.
# 2. The daemon itself, end to end, with files standing in for /dev/kmsg and
#    /proc/sysrq-trigger and timings cut to milliseconds: healthy, exec going
#    away, exec getting stuck, and refusing to start (or to arm on a probe
#    that fails from the start).
# 3. The wiring: the unit's priority against the audio threads and the USB IRQ
#    thread, the image installing it, and the kernel's sysrq.
#
# Linux only (O_DIRECT, posix_spawn's exec errors, CPU affinity). What it
# cannot show is the reboot and the pstore record; the PR lists the device
# steps for those.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
files="$here/../files"
recipe="$here/../segno-freeze-watchdog.bb"
LAYER="$here/../../.."
FRAGMENT="$LAYER/recipes-kernel/linux/files/freeze-recovery.cfg"
IMAGE="$LAYER/recipes-core/images/segno-kiosk-image.bb"
RTIRQ="$LAYER/recipes-segno/segno-bundle/files/segno-rtirq"
ENGINE="$LAYER/../../../packages/segno_engine/src"

pass=0
fail=0
check() {
    local name=$1 cond=$2
    if eval "$cond"; then
        echo "  ok   $name"
        pass=$((pass + 1))
    else
        echo "  FAIL $name"
        echo "       condition: $cond"
        [ -f "${work:-/nonexistent}/kmsg" ] && sed 's/^/       kmsg: /' "$work/kmsg"
        fail=$((fail + 1))
    fi
}

build=$(mktemp -d "${TMPDIR:-/tmp}/freeze-watchdog-build.XXXXXX")
trap 'rm -rf "$build"' EXIT
cc=${CC:-cc}
flags=(-std=gnu11 -Wall -Wextra -Werror -O1 -pthread -I "$files")
"$cc" "${flags[@]}" -o "$build/test_freeze_watchdog" \
    "$here/test_freeze_watchdog.c" "$files/freeze_watchdog.c" || exit 1
"$cc" "${flags[@]}" -o "$build/segno-freeze-watchdog" \
    "$files/segno-freeze-watchdog.c" "$files/freeze_watchdog.c" || exit 1

echo "unit tests"
TMPDIR="$build" "$build/test_freeze_watchdog"; rc=$?
check "the unit tests pass" '[ "$rc" = 0 ]'

setup() {
    work=$(mktemp -d "$build/run.XXXXXX")
    : > "$work/kmsg"
    : > "$work/sysrq"
    mkdir "$work/data"
}

# run_daemon [VAR=value ...]: the daemon with test paths and fast timings,
# stopped after $limit seconds (20 by default) if it has not exited by itself.
run_daemon() {
    env SEGNO_WATCHDOG_KMSG="$work/kmsg" SEGNO_WATCHDOG_SYSRQ="$work/sysrq" \
        SEGNO_WATCHDOG_ROOT_FILE="$build/segno-freeze-watchdog" \
        SEGNO_WATCHDOG_DATA_FILE="$work/data/segno/probe" \
        SEGNO_WATCHDOG_EXEC=/bin/true \
        SEGNO_WATCHDOG_INTERVAL_MS=50 SEGNO_WATCHDOG_DEADLINE_MS=200 \
        SEGNO_WATCHDOG_FAIL_AFTER_MS=400 SEGNO_WATCHDOG_MIN_FAILURES=3 \
        SEGNO_WATCHDOG_DUMP_WAIT_MS=20 SEGNO_WATCHDOG_SYNC_WAIT_MS=10 \
        "$@" timeout "${limit:-20}" "$build/segno-freeze-watchdog" 2>"$work/stderr"
}

echo "healthy: the probes pass, and nothing is triggered"
setup
limit=1.5 run_daemon
rc=$?
check "still running when stopped" '[ "$rc" = 124 ]'
check "says what it watches" 'grep -q "^<6>segno-freeze-watchdog: watching read .*segno-freeze-watchdog, read $work/data/segno/probe and exec /bin/true every 50 ms" "$work/kmsg"'
check "no probe failed" '! grep -q "probe failed" "$work/kmsg"'
check "triggered nothing" '[ ! -s "$work/sysrq" ]'
check "created the /data probe file" '[ "$(wc -c < "$work/data/segno/probe")" -eq 4096 ]'

# start_daemon [VAR=value ...]: run_daemon in the background; `wait $daemon`.
start_daemon() {
    run_daemon "$@" &
    daemon=$!
    for _ in $(seq 100); do grep -q "watching" "$work/kmsg" && return; sleep 0.05; done
}

echo "exec dead: the freeze of 2026-11-01"
# The program is there when the daemon starts and goes away, as /bin/sleep did.
setup
mkdir "$work/bin"
ln -s /bin/true "$work/bin/true"
start_daemon SEGNO_WATCHDOG_EXEC="$work/bin/true"
check "armed" 'grep -q "watching" "$work/kmsg"'
rm "$work/bin/true"
start=$(date +%s)
wait "$daemon"; rc=$?
check "asks for the reboot (exit 3)" '[ "$rc" = 3 ]'
check "within seconds" '[ $(( $(date +%s) - start )) -le 5 ]'
check "logs each failed round" 'grep -q "^<4>segno-freeze-watchdog: probe failed (1 in a row, 0 s since the last pass): exec $work/bin/true: No such file or directory" "$work/kmsg"'
check "waits for enough failures" '[ "$(grep -c "probe failed" "$work/kmsg")" -ge 3 ]'
check "says why before the dump" 'grep -q "^<2>segno-freeze-watchdog: rebooting: exec or storage dead: .* probe rounds failed over 0 s, the last: exec $work/bin/true: No such file or directory. Dumping" "$work/kmsg"'
check "and as the last line" 'tail -n 1 "$work/kmsg" | grep -q "^<2>segno-freeze-watchdog: rebooting now: exec or storage dead: "'
check "dumps, syncs and crashes, in that order" '[ "$(cat "$work/sysrq")" = wlsc ]'

echo "exec stuck: a probe that stops returning"
setup
# Passes the arming round, then hangs on every later one.
printf '#!/bin/sh
[ -e %s/armed ] && exec /bin/sleep 3
: > %s/armed
' "$work" "$work" > "$work/hang"
chmod +x "$work/hang"
start_daemon SEGNO_WATCHDOG_EXEC="$work/hang"
wait "$daemon"; rc=$?
check "asks for the reboot (exit 3)" '[ "$rc" = 3 ]'
check "the round fails at its deadline" 'grep -q "probe failed (1 in a row, 0 s since the last pass): exec $work/hang did not return within 200 ms" "$work/kmsg"'
check "later rounds say it is still stuck" 'grep -q "exec $work/hang has not returned for" "$work/kmsg"'
check "dumps, syncs and crashes" '[ "$(cat "$work/sysrq")" = wlsc ]'

echo "a probe broken from the start never arms"
setup
run_daemon SEGNO_WATCHDOG_EXEC="$work/gone/true"; rc=$?
check "exit 1" '[ "$rc" = 1 ]'
check "says why" 'grep -q "^<3>segno-freeze-watchdog: cannot start: the first probe round failed: exec $work/gone/true: No such file or directory" "$work/kmsg"'
check "triggers nothing" '[ ! -s "$work/sysrq" ]'

echo "refuses to start without what it needs"
setup
run_daemon SEGNO_WATCHDOG_ROOT_FILE="$work/missing"; rc=$?
check "a missing root file: exit 1" '[ "$rc" = 1 ]'
check "says why" 'grep -q "^<3>segno-freeze-watchdog: cannot start: open $work/missing: No such file or directory" "$work/kmsg"'
setup
run_daemon SEGNO_WATCHDOG_SYSRQ="$work/no/sysrq"; rc=$?
check "no sysrq trigger: exit 1" '[ "$rc" = 1 ]'
check "says why" 'grep -q "cannot start: open $work/no/sysrq" "$work/kmsg"'
setup
run_daemon SEGNO_WATCHDOG_KMSG="$work/no/kmsg"; rc=$?
check "no kernel log: exit 1" '[ "$rc" = 1 ]'
check "says why on stderr" 'grep -q "cannot open $work/no/kmsg" "$work/stderr"'

echo "wiring"
unit="$files/segno-freeze-watchdog.service"
value() { sed -n "s/^$1=//p" "$unit" | tail -n 1; }
prio=$(value CPUSchedulingPriority)
callback=$(sed -n 's/^  sp.sched_priority = \([0-9]*\);$/\1/p' "$ENGINE/platform/engine_linux.c" | head -n 1)
workers=$(sed -n 's/^#define LE_FX_WORKER_PRIO \([0-9]*\)$/\1/p' "$ENGINE/core/engine_workers.h")
usb_irq=$(sed -n 's/^PRIO=\([0-9]*\)$/\1/p' "$RTIRQ")
check "read the audio and IRQ priorities" '[ -n "$callback" ] && [ -n "$workers" ] && [ -n "$usb_irq" ]'
check "SCHED_FIFO" '[ "$(value CPUSchedulingPolicy)" = fifo ]'
check "above the audio callback ($callback) and workers ($workers)" '[ "$prio" -gt "$callback" ] && [ "$prio" -gt "$workers" ]'
check "below the USB sound-card IRQ thread ($usb_irq)" '[ "$prio" -lt "$usb_irq" ]'
check "on core 0, away from the audio cores" '[ "$(value CPUAffinity)" = 0 ]'
check "may lock its memory" '[ "$(value LimitMEMLOCK)" = infinity ]'
check "Type=notify with a watchdog" '[ "$(value Type)" = notify ] && [ -n "$(value WatchdogSec)" ]'
check "stops before /data is unmounted" '[ "$(value RequiresMountsFor)" = /data ]'
check "starts at boot" '[ "$(value WantedBy)" = multi-user.target ]'
check "the recipe enables the unit" 'grep -qx "SYSTEMD_SERVICE:\${PN} = \"segno-freeze-watchdog.service\"" "$recipe"'
check "the recipe builds both sources" 'grep -q "segno-freeze-watchdog.c \${S}/freeze_watchdog.c" "$recipe"'
check "the image installs it" 'sed -n "/^IMAGE_INSTALL:append/,/^    \"/p" "$IMAGE" | grep -qx "    segno-freeze-watchdog \\\\"'
check "the kernel has sysrq" 'grep -qx "CONFIG_MAGIC_SYSRQ=y" "$FRAGMENT"'
check "panics reboot by themselves" 'grep -qE "^CONFIG_PANIC_TIMEOUT=[1-9][0-9]*$" "$FRAGMENT"'
# A reboot argument is the only way to ask for the tryboot slot, and only
# reboot(2)'s RESTART2 command carries one.
check "never passes a reboot argument" '! grep -q "RESTART2" "$files"/*.c'

echo "segno-freeze-watchdog: $pass passed, $fail failed"
[ "$fail" = 0 ]
