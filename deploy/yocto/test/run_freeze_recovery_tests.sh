#!/usr/bin/env bash
# Wiring tests for freeze recovery (#1437): the hardware watchdog, pstore,
# the journal's sync interval and the lockup policy.
#
# Every one of these breaks silently. Drop the watchdog value and a hung PID 1
# leaves the console frozen until someone pulls the power, as on 2026-10-23.
# Drop the overlay or the dtbo and pstore has no RAM to write into. Turn on the
# hung-task panic and a slow USB stick reboots the console mid-set. None of it
# shows until the day it is needed, so this asserts the configuration
# statically. The behaviour itself was checked on the console (see the PR).
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
YOCTO="$here/.."
LAYER="$YOCTO/meta-segno"
FRAGMENT="$LAYER/recipes-kernel/linux/files/freeze-recovery.cfg"
KERNEL_BBAPPEND="$LAYER/recipes-kernel/linux/linux-raspberrypi_%.bbappend"
SYSTEMD_BBAPPEND="$LAYER/recipes-core/systemd/systemd_%.bbappend"
JOURNALD="$LAYER/recipes-segno/segno-bundle/files/journald-segno.conf"
KAS_COMMON="$YOCTO/kas-segno-common.yml"
KAS_RPI5="$YOCTO/kas-segno-rpi5.yml"

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

has_line() { grep -qx -- "$2" "$1" && echo yes || echo no; }

# Seconds from a systemd time span written as "<n>s" or "<n>min".
seconds() {
    case $1 in
        *min) echo $(( ${1%min} * 60 )) ;;
        *s) echo "${1%s}" ;;
        *) echo "unparsed($1)" ;;
    esac
}

# A bitbake assignment's value: VAR = "value".
bb_value() {
    sed -n "s/^$2 = \"\\(.*\\)\"\$/\\1/p" "$1" | tail -n1
}

echo "the kernel fragment is applied"
check "fragment exists" yes "$([ -f "$FRAGMENT" ] && echo yes || echo no)"
check "fragment is in the kernel SRC_URI" yes \
    "$(grep -E '^SRC_URI \+= "file://freeze-recovery.cfg"$' "$KERNEL_BBAPPEND" > /dev/null && echo yes || echo no)"

echo "pstore has a RAM backend and a console copy"
for opt in CONFIG_PSTORE=y CONFIG_PSTORE_RAM=y CONFIG_PSTORE_CONSOLE=y; do
    check "$opt" yes "$(has_line "$FRAGMENT" "$opt")"
done

echo "a panic reboots instead of halting"
timeout=$(sed -n 's/^CONFIG_PANIC_TIMEOUT=//p' "$FRAGMENT")
check "CONFIG_PANIC_TIMEOUT is set" yes "$([ -n "$timeout" ] && echo yes || echo no)"
check "CONFIG_PANIC_TIMEOUT is positive (0 halts forever, <0 skips the wait)" yes \
    "$([ "${timeout:-0}" -gt 0 ] 2>/dev/null && echo yes || echo no)"

echo "lockups panic, hung tasks only log"
for opt in CONFIG_SOFTLOCKUP_DETECTOR=y CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y \
    CONFIG_HARDLOCKUP_DETECTOR=y CONFIG_BOOTPARAM_HARDLOCKUP_PANIC=y \
    CONFIG_DETECT_HUNG_TASK=y; do
    check "$opt" yes "$(has_line "$FRAGMENT" "$opt")"
done
check "hung-task panic is explicitly off" yes \
    "$(has_line "$FRAGMENT" '# CONFIG_BOOTPARAM_HUNG_TASK_PANIC is not set')"
check "nothing turns hung-task panic on" no \
    "$(grep -q '^CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y' "$FRAGMENT" && echo yes || echo no)"

echo "systemd drives the BCM2835 watchdog"
runtime=$(bb_value "$SYSTEMD_BBAPPEND" WATCHDOG_RUNTIME_SEC)
reboot=$(bb_value "$SYSTEMD_BBAPPEND" WATCHDOG_TIMEOUT)
check "WATCHDOG_RUNTIME_SEC is set" yes "$([ -n "$runtime" ] && echo yes || echo no)"
# bcm2835_wdt counts 20 bits of 1/65536 s: 15.99 s is all the hardware holds.
# Above that the kernel has to feed it on systemd's behalf, which is not what
# this value was chosen for.
check "RuntimeWatchdogSec fits the hardware (1-15 s)" yes \
    "$(s=$(seconds "$runtime"); [ "$s" -ge 1 ] 2>/dev/null && [ "$s" -le 15 ] && echo yes || echo no)"
check "WATCHDOG_TIMEOUT (RebootWatchdogSec) is set" yes \
    "$([ -n "$reboot" ] && echo yes || echo no)"
check "systemd builds systemd-pstore" yes \
    "$(grep -E '^PACKAGECONFIG:append = ".* pstore( |")' "$SYSTEMD_BBAPPEND" > /dev/null && echo yes || echo no)"

echo "the journal reaches the disk within seconds"
check "journald drop-in sets SyncIntervalSec=10s" yes \
    "$(has_line "$JOURNALD" 'SyncIntervalSec=10s')"

echo "the Pi 5 reserves the ramoops region"
check "ramoops overlays are built and shipped" yes \
    "$(grep -F 'RPI_KERNEL_DEVICETREE_OVERLAYS:append' "$KAS_RPI5" | grep -F 'overlays/ramoops.dtbo' | grep -qF 'overlays/ramoops-pi4.dtbo' && echo yes || echo no)"
check "config.txt loads the ramoops overlay with a console copy" yes \
    "$(grep -F 'RPI_EXTRA_CONFIG:append' "$KAS_RPI5" | grep -F 'dtoverlay=ramoops,' | grep -q 'console-size=0x[0-9a-f]*[1-9a-f]' && echo yes || echo no)"

echo "kernel errors reach the pstore console copy"
cmdline=$(grep -E '^[[:space:]]*CMDLINE:append' "$KAS_COMMON")
check "loglevel=4 (errors and worse reach the consoles)" yes \
    "$(printf '%s\n' "$cmdline" | grep -qE '(^| |")loglevel=4( |"|$)' && echo yes || echo no)"
check "exactly one loglevel=" 1 \
    "$(printf '%s\n' "$cmdline" | grep -oE 'loglevel=[0-9]+' | wc -l | tr -d ' ')"

echo
echo "freeze-recovery: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
