#!/usr/bin/env bash
# Tests for segno-wifi-retry (#824, #963, #1326).
#
# The boot backstop used to fire `connection up` into an empty iwd scan cache
# (#963), then gave up after three plain `connection up` calls that could
# never work: after one failure NetworkManager's iwd backend asks secret
# agents for a new key, and the console runs none (#1326). These assert it
# rescans first, activates on the stored key through passwd-file, leaves an
# activation NM already has in flight alone, keeps retrying until connected
# within its budget, and that the obvious no-ops still no-op. nmcli is
# stubbed; no radio involved. Sleeps are env-forced to zero.
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
    # STATES and UP_RCS are consumed one word per call; the last word sticks.
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
next() {
    list=\$1 counter="$work/\$2"
    n=0
    [ -f "\$counter" ] && n=\$(cat "\$counter")
    n=\$((n + 1))
    echo "\$n" > "\$counter"
    set -- \$list
    [ "\$n" -le "\$#" ] || n=\$#
    eval "printf '%s' \"\\\${\$n}\""
}
case "\$*" in
    *"radio wifi"*) printf '%s\n' "\${RADIO:-enabled}" ;;
    *"-f DEVICE,TYPE,STATE device"*)
        state=\$(next "\${STATES:-disconnected}" state-count)
        printf 'eth0:ethernet:unavailable\n'
        printf 'wlan0:wifi:%s\n' "\$state"
        ;;
    *"-f UUID,TYPE,TIMESTAMP connection show"*)
        printf '%s\n' "\${LISTING:-uuid-Cafe:802-11-wireless:100}"
        ;;
    *"802-11-wireless-security.psk"*)
        printf '%s\n' "\$PSK"
        ;;
    *"802-11-wireless.ssid"*)
        printf '%s\n' "\${SSID:-Cafe}"
        ;;
    *"device wifi rescan"*) echo rescan >> "$work/events" ;;
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
        case "\$*" in
            *"passwd-file "*)
                f=\$(printf '%s' "\$*" | sed 's/.*passwd-file //')
                cp "\$f" "$work/passwd-file"
                echo "\$f" > "$work/passwd-file-path"
                ;;
        esac
        exit \$(next "\${UP_RCS:-0}" up-count)
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
    SEGNO_WIFI_RETRY_FOR="${RETRY_FOR:-0}" \
    SEGNO_WIFI_RETRY_BACKOFF=0 \
    SEGNO_WIFI_RETRY_POLL=0 \
    SEGNO_WIFI_RETRY_SCAN_WAIT="${SCAN_WAIT:-0}" \
    RADIO="${RADIO:-enabled}" \
    STATES="${STATES:-disconnected}" \
    LISTING="${LISTING:-uuid-Cafe:802-11-wireless:100}" \
    SSID="${SSID:-Cafe}" \
    PSK="${PSK-secret}" \
    SCAN_SSID="${SCAN_SSID:-Cafe}" \
    LIST_MISS="${LIST_MISS:-0}" \
    UP_RCS="${UP_RCS:-0}" \
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

called_with() { grep -qF -- "$1" "$work/nmcli-args" && echo yes || echo no; }
ups() { grep -c '^up$' "$work/events" | tr -d ' '; }

echo "already connected is a no-op"
setup
STATES=connected run_retry
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
    "$(f=$(cat "$work/passwd-file-path" 2>/dev/null); [ -z "$f" ] || [ -e "$f" ] && echo yes || echo no)"
check "the key is never in argv" no "$(called_with 'pass word')"
teardown

echo "an open network goes up without a passwd-file"
setup
PSK='' run_retry
check "exit 0" 0 "$?"
check "activates" yes "$(called_with 'connection up uuid uuid-Cafe')"
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

echo "backs off when its own rescan lets NM auto-activate"
setup
STATES="disconnected connecting connected" RETRY_FOR=60 run_retry
check "exit 0" 0 "$?"
check "rescanned" yes "$(called_with 'device wifi rescan')"
check "does not step on NM's activation" 0 "$(ups)"
teardown

echo "keeps retrying until connected"
setup
UP_RCS="1 1 0" RETRY_FOR=60 run_retry
check "exit 0" 0 "$?"
check "three activations" 3 "$(ups)"
check "rescans before each" 3 "$(grep -c '^rescan$' "$work/events" | tr -d ' ')"
teardown

echo "gives up when the budget runs out"
setup
UP_RCS=1 RETRY_FOR=0 run_retry
check "exit 1" 1 "$?"
check "one activation" 1 "$(ups)"
check "gave up" yes "$(grep -q 'gave up' "$work/stdout" && echo yes || echo no)"
teardown

echo
echo "wifi-retry: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
