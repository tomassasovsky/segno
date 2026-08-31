#!/usr/bin/env bash
# Tests for segno-wifi-retry (#824, #963).
#
# The boot backstop used to fire `connection up` into an empty iwd scan cache
# (DisablePeriodicScan) and burn three attempts in ten seconds, all failing at
# prepare. These assert it rescans first, and that the obvious no-ops still
# no-op. nmcli is stubbed; no radio involved. Sleeps are env-forced to zero.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RETRY="$here/../files/segno-wifi-retry"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-retry-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/nmcli-args"
    : > "$work/events"
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
case "\$*" in
    *"radio wifi"*) printf '%s\n' "\${RADIO:-enabled}" ;;
    *"-f DEVICE,TYPE,STATE device"*)
        printf 'wlan0:wifi:%s\n' "\${WIFI_STATE:-disconnected}"
        ;;
    *"-f UUID,TYPE,TIMESTAMP connection show"*)
        printf '%s\n' "\${LISTING:-uuid-Cafe:802-11-wireless:100}"
        ;;
    *"802-11-wireless.ssid"*)
        printf '%s\n' "\${SSID:-Cafe}"
        ;;
    *"device wifi rescan"*) ;;
    *"-f SSID device wifi list"*)
        n=0
        [ -f "$work/list-count" ] && n=\$(cat "$work/list-count")
        n=\$((n + 1))
        echo "\$n" > "$work/list-count"
        if [ "\$n" -le "\${LIST_MISS:-0}" ]; then
            seen=OtherNet
        else
            seen=\${SCAN_SSID:-Cafe}
        fi
        echo "list \$seen" >> "$work/events"
        printf '%s\n' "\$seen"
        ;;
    *"connection up"*)
        echo up >> "$work/events"
        exit \${UP_RC:-0}
        ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
}

teardown() { rm -rf "$work"; }

run_retry() {
    PATH="$work/bin:$PATH" \
    SEGNO_WIFI_RETRY_SETTLE=0 \
    SEGNO_WIFI_RETRY_ATTEMPTS="${ATTEMPTS:-1}" \
    SEGNO_WIFI_RETRY_BETWEEN=0 \
    SEGNO_WIFI_RETRY_SCAN_WAIT="${SCAN_WAIT:-0}" \
    RADIO="${RADIO:-enabled}" \
    WIFI_STATE="${WIFI_STATE:-disconnected}" \
    LISTING="${LISTING:-uuid-Cafe:802-11-wireless:100}" \
    SSID="${SSID:-Cafe}" \
    SCAN_SSID="${SCAN_SSID:-Cafe}" \
    LIST_MISS="${LIST_MISS:-0}" \
    UP_RC="${UP_RC:-0}" \
        sh "$RETRY" >"$work/stdout" 2>"$work/stderr"
}

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"; pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        [ -s "$work/stdout" ] && sed 's/^/       > /' "$work/stdout"
        [ -s "$work/stderr" ] && sed 's/^/       | /' "$work/stderr"
        fail=$((fail + 1))
    fi
}

called_with() { grep -qF "$1" "$work/nmcli-args" && echo yes || echo no; }

before() {
    local first=$1 second=$2
    local a b
    a=$(grep -n -F "$first" "$work/nmcli-args" | head -1 | cut -d: -f1)
    b=$(grep -n -F "$second" "$work/nmcli-args" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && echo yes || echo no
}

after() {
    local first=$1 second=$2
    local a b
    a=$(grep -n -F "$first" "$work/nmcli-args" | head -1 | cut -d: -f1)
    b=$(grep -n -F "$second" "$work/nmcli-args" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -gt "$b" ] && echo yes || echo no
}

echo "already connected is a no-op"
setup
WIFI_STATE=connected run_retry
check "exit 0" 0 "$?"
check "does not activate" no "$(called_with 'connection up')"
check "does not rescan" no "$(called_with 'device wifi rescan')"
teardown

echo "radio off is a no-op"
setup
RADIO=disabled run_retry
check "exit 0" 0 "$?"
check "does not activate" no "$(called_with 'connection up')"
teardown

echo "no saved wifi profile is a no-op"
setup
LISTING="lo:loopback:0" run_retry
check "exit 0" 0 "$?"
check "does not activate" no "$(called_with 'connection up')"
teardown

echo "waits for the saved ssid before activating"
setup
LIST_MISS=2 SCAN_WAIT=3 run_retry
check "exit 0" 0 "$?"
check "rescans" yes "$(called_with 'device wifi rescan')"
check "activates the saved uuid" yes "$(called_with 'connection up uuid uuid-Cafe')"
check "ssid appeared before up" yes \
    "$(grep -q '^list Cafe$' "$work/events" && grep -q '^up$' "$work/events" && \
      [ "$(grep -n '^list Cafe$' "$work/events" | head -1 | cut -d: -f1)" -lt "$(grep -n '^up$' "$work/events" | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
teardown

echo "still activates if the ssid is not in the scan yet"
setup
LIST_MISS=99 SCAN_WAIT=0 run_retry
check "exit 0" 0 "$?"
check "activates anyway" yes "$(called_with 'connection up uuid uuid-Cafe')"
check "says so" yes \
    "$(grep -q 'not in scan yet' "$work/stdout" && echo yes || echo no)"
teardown

echo "a failed up is a failed unit"
setup
UP_RC=1 run_retry
check "exit 1" 1 "$?"
check "gave up" yes "$(grep -q 'gave up' "$work/stdout" && echo yes || echo no)"
teardown

echo
echo "wifi-retry: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
