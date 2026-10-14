#!/usr/bin/env bash
# Tests for segno-wifi-retry (#824, #963, #1326).
#
# The boot backstop used to fire `connection up` into an empty iwd scan cache
# (#963), then gave up after three plain `connection up` calls that could
# never work: after one failure NetworkManager's iwd backend asks secret
# agents for a new key, and the console runs none (#1326). These assert it
# rescans first, activates on the stored key (through segno-wifi-ctl
# activate and a passwd-file), leaves an activation NM already has in flight
# alone, keeps retrying until connected within its budget, honours the
# owner's auto-join and Disconnect choices, prefers a saved network in range,
# and that the obvious no-ops still no-op.
#
# nmcli is stubbed; no radio involved. The real segno-wifi-ctl runs against
# the same stub. Sleeps are env-forced to zero.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RETRY="$here/../files/segno-wifi-retry"
CTL="$here/../files/segno-wifi-ctl"
TEST_SHELL="${TEST_SHELL:-sh}"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-retry-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/nmcli-args"
    : > "$work/events"
    # STATES, RADIOS, UP_RCS and LISTINGS are consumed one entry per call; the
    # last entry sticks. LISTINGS entries are separated by '|', the profiles
    # inside one by spaces. UUIDs are uuid-<ssid>.
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
next() {
    list=\$1 counter="$work/\$2"
    n=0
    [ -f "\$counter" ] && n=\$(cat "\$counter")
    n=\$((n + 1))
    echo "\$n" > "\$counter"
    printf '%s\n' "\$list" | tr '|' '\n' | awk -v n="\$n" '{ l = \$0 } NR == n { print; f = 1; exit } END { if (!f) print l }'
}
last=\$(eval "printf '%s' \"\\\${\$#}\"")
case "\$*" in
    *"radio wifi"*) next "\${RADIOS:-enabled}" radio-count ;;
    *"GENERAL.AUTOCONNECT device show"*) printf '%s\n' "\${DEV_AC:-yes}" ;;
    *"-f DEVICE,TYPE,STATE device"*)
        state=\$(next "\$(printf '%s' "\${STATES:-disconnected}" | tr ' ' '|')" state-count)
        printf 'eth0:ethernet:unavailable\n'
        printf 'wlan0:wifi:%s\n' "\$state"
        ;;
    *"-f UUID,TYPE,AUTOCONNECT,TIMESTAMP connection show"*)
        next "\${LISTINGS-uuid-Cafe:802-11-wireless:yes:100}" listing-count | tr ' ' '\n'
        ;;
    *"802-11-wireless-security.psk"*) printf '%s\n' "\$PSK" ;;
    *"802-11-wireless.ssid"*) printf '%s\n' "\${last#uuid-}" ;;
    *"device wifi rescan"*) echo rescan >> "$work/events" ;;
    *"device wifi list"*)
        n=0
        [ -f "$work/list-count" ] && n=\$(cat "$work/list-count")
        n=\$((n + 1))
        echo "\$n" > "$work/list-count"
        if [ "\$n" -le "\${LIST_MISS:-0}" ]; then
            seen=OtherNet
        else
            seen=\${SCAN_SSIDS:-Cafe}
        fi
        echo "list \$seen" >> "$work/events"
        printf '%s\n' \$seen
        ;;
    *"connection up"*)
        echo "up \$(printf '%s' "\$*" | sed 's/.*connection up uuid //; s/ passwd-file.*//')" >> "$work/events"
        case "\$*" in
            *"passwd-file "*)
                cp "\$last" "$work/passwd-file"
                echo "\$last" > "$work/passwd-file-path"
                ;;
        esac
        rc=\$(next "\$(printf '%s' "\${UP_RCS:-0}" | tr ' ' '|')" up-count)
        [ "\$rc" -eq 0 ] || echo "Error: Connection activation failed: (53) stub failure" >&2
        exit "\$rc"
        ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
    cat > "$work/bin/segno-wifi-ctl" <<STUB
#!/bin/sh
exec $TEST_SHELL "$CTL" "\$@"
STUB
    chmod +x "$work/bin/segno-wifi-ctl"
    cat > "$work/bin/journalctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$work/bin/journalctl"
}

teardown() { rm -rf "$work"; }

run_retry() {
    PATH="$work/bin:$PATH" \
    SEGNO_WIFI_CTL="$work/bin/segno-wifi-ctl" \
    SEGNO_JOURNALCTL="$work/bin/journalctl" \
    SEGNO_WIFI_RETRY_SETTLE=0 \
    SEGNO_WIFI_RETRY_FOR="${RETRY_FOR:-0}" \
    SEGNO_WIFI_RETRY_BACKOFF=0 \
    SEGNO_WIFI_RETRY_POLL=0 \
    SEGNO_WIFI_RETRY_SCAN_WAIT="${SCAN_WAIT:-0}" \
    RADIOS="${RADIOS:-enabled}" \
    DEV_AC="${DEV_AC:-yes}" \
    STATES="${STATES:-disconnected}" \
    LISTINGS="${LISTINGS-uuid-Cafe:802-11-wireless:yes:100}" \
    PSK="${PSK-secret}" \
    SCAN_SSIDS="${SCAN_SSIDS:-Cafe}" \
    LIST_MISS="${LIST_MISS:-0}" \
    UP_RCS="${UP_RCS:-0}" \
        "$TEST_SHELL" "$RETRY" >"$work/stdout" 2>"$work/stderr"
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

called_with() { grep -qF -- "$1" "$work/nmcli-args" && echo yes || echo no; }
ups() { grep -c '^up ' "$work/events" | tr -d ' '; }
said() { grep -qF -- "$1" "$work/stdout" "$work/stderr" && echo yes || echo no; }

echo "already connected is a no-op"
setup
STATES=connected run_retry
check "exit 0" 0 "$?"
check "does not activate" 0 "$(ups)"
check "does not rescan" no "$(called_with 'device wifi rescan')"
teardown

echo "radio off is a no-op"
setup
RADIOS=disabled run_retry
check "exit 0" 0 "$?"
check "does not activate" 0 "$(ups)"
teardown

echo "no saved wifi profile is a no-op"
setup
LISTINGS="uuid-lo:loopback:no:0" run_retry
check "exit 0" 0 "$?"
check "does not activate" 0 "$(ups)"
teardown

# The Network page's per-network auto-join switch is connection.autoconnect.
echo "a network with auto-join off is never activated"
setup
LISTINGS="uuid-Home:802-11-wireless:no:200 uuid-Cafe:802-11-wireless:yes:100" \
    SCAN_SSIDS="Home Cafe" run_retry
check "exit 0" 0 "$?"
check "activates the one that may auto-join" "up uuid-Cafe" "$(grep '^up ' "$work/events")"
teardown

echo "nothing that may auto-join is a no-op"
setup
LISTINGS="uuid-Home:802-11-wireless:no:200" SCAN_SSIDS=Home run_retry
check "exit 0" 0 "$?"
check "does not activate" 0 "$(ups)"
teardown

# `nmcli device disconnect` turns the device's autoconnect off until the next
# activation; reconnecting would undo the owner's Disconnect.
echo "a Disconnect by hand is respected"
setup
DEV_AC=no run_retry
check "exit 0" 0 "$?"
check "does not activate" 0 "$(ups)"
check "says why" yes "$(said 'disconnected by hand')"
teardown

echo "waits for the saved ssid before activating"
setup
LIST_MISS=2 SCAN_WAIT=3 run_retry
check "exit 0" 0 "$?"
check "rescans" yes "$(called_with 'device wifi rescan')"
check "activates the saved uuid" "up uuid-Cafe" "$(grep '^up ' "$work/events")"
check "ssid appeared before up" yes \
    "$([ "$(grep -n '^list Cafe$' "$work/events" | head -1 | cut -d: -f1)" -lt \
         "$(grep -n '^up ' "$work/events" | head -1 | cut -d: -f1)" ] 2>/dev/null && echo yes || echo no)"
teardown

echo "prefers the newest saved network that is in range"
setup
LISTINGS="uuid-Home:802-11-wireless:yes:200 uuid-Venue:802-11-wireless:yes:100" \
    SCAN_SSIDS="Neighbour Venue" run_retry
check "exit 0" 0 "$?"
check "activates the one in range" "up uuid-Venue" "$(grep '^up ' "$work/events")"
teardown

echo "falls back to the newest when none is in range"
setup
LISTINGS="uuid-Home:802-11-wireless:yes:200 uuid-Venue:802-11-wireless:yes:100" \
    SCAN_SSIDS=Neighbour SCAN_WAIT=0 run_retry
check "exit 0" 0 "$?"
check "activates the newest" "up uuid-Home" "$(grep '^up ' "$work/events")"
check "says so" yes "$(said 'trying the newest anyway')"
teardown

# After one failure NM asks agents for a NEW key and the console has none: a
# plain up fails in milliseconds with the key sitting in the keyfile (#1326).
echo "activates on the stored key through passwd-file"
setup
PSK='pass word\x' run_retry
check "exit 0" 0 "$?"
check "uses passwd-file" yes "$(called_with 'passwd-file')"
check "file holds the stored key, escaped" \
    '802-11-wireless-security.psk:pass\ word\\x' "$(cat "$work/passwd-file" 2>/dev/null)"
check "file is removed afterwards" no \
    "$(f=$(cat "$work/passwd-file-path" 2>/dev/null); { [ -z "$f" ] || [ -e "$f" ]; } && echo yes || echo no)"
check "the key is never in argv" no "$(called_with 'pass word')"
teardown

echo "pauses device autoconnect around its activation"
setup
run_retry
check "exit 0" 0 "$?"
check "pause, up, resume in that order" "no up yes" \
    "$(grep -oE 'device set wlan0 autoconnect (no|yes)|connection up' "$work/nmcli-args" \
        | sed 's/device set wlan0 autoconnect //; s/connection up/up/' | tr '\n' ' ' | sed 's/ $//')"
teardown

echo "an open network goes up without a passwd-file"
setup
PSK='' run_retry
check "exit 0" 0 "$?"
check "activates" "up uuid-Cafe" "$(grep '^up ' "$work/events")"
check "no passwd-file" no "$(called_with 'passwd-file')"
teardown

# The retry's `connection up` on top of NM's own auto-activation aborted it
# (net.connman.iwd.Aborted) and threw away the attempt that would have worked.
echo "leaves an activation already in flight alone"
setup
STATES="connecting connecting connected" RETRY_FOR=60 run_retry
check "exit 0" 0 "$?"
check "does not activate" 0 "$(ups)"
teardown

echo "waits out a deactivation too"
setup
STATES="deactivating connected" RETRY_FOR=60 run_retry
check "exit 0" 0 "$?"
check "does not activate" 0 "$(ups)"
teardown

echo "backs off when its own rescan lets NM auto-activate"
setup
STATES="disconnected connecting connected" RETRY_FOR=60 run_retry
check "exit 0" 0 "$?"
check "rescanned" yes "$(called_with 'device wifi rescan')"
check "does not step on NM's activation" 0 "$(ups)"
check "does not claim it was already connected" no "$(said 'no retry needed')"
teardown

echo "NetworkManager not answering is retried, not taken for nothing saved"
setup
LISTINGS="|uuid-Cafe:802-11-wireless:yes:100" RETRY_FOR=60 run_retry
check "exit 0" 0 "$?"
check "said so" yes "$(said 'not answering')"
check "then activated" "up uuid-Cafe" "$(grep '^up ' "$work/events")"
teardown

echo "keeps retrying until connected"
setup
UP_RCS="1 1 0" RETRY_FOR=60 run_retry
check "exit 0" 0 "$?"
check "three activations" 3 "$(ups)"
check "rescans before each" 3 "$(grep -c '^rescan$' "$work/events" | tr -d ' ')"
teardown

echo "stops when the radio is turned off mid-retry"
setup
RADIOS="enabled|disabled" UP_RCS=1 RETRY_FOR=60 run_retry
check "exit 0" 0 "$?"
check "one activation" 1 "$(ups)"
check "says why" yes "$(said 'radio is off')"
teardown

echo "gives up when the budget runs out"
setup
UP_RCS=1 RETRY_FOR=0 run_retry
check "exit 1" 1 "$?"
check "one activation" 1 "$(ups)"
check "gave up" yes "$(said 'gave up')"
check "nmcli's failure reason reaches the log" yes "$(said 'stub failure')"
teardown

echo
echo "wifi-retry: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
