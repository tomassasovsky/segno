#!/usr/bin/env bash
# Tests that segno-wifi-ctl owns the radio through NetworkManager and nothing
# else (#468, #1843).
#
# The bug these exist to prevent was not a crash, it was a takeover. The helper
# used to fall back to its own wpa_supplicant when an NM join failed, which
# meant setting wlan0 `managed no`, and because the backend was then chosen by
# reading that same state, every later call picked the fallback again. A
# console ended up running our supplicant and NetworkManager's dbus-owned one
# at the same time, on one interface, forever. The access point saw it
# reconnect every few seconds and nothing in any log said why.
#
# NetworkManager runs wpa_supplicant itself now, as on Raspberry Pi OS
# (#1843), so these assert absence as much as behaviour: no second
# supplicant, no `managed no`.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-wifi-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-backend-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/nmcli-args"

    # nmcli stub: records every invocation and answers the two reads the
    # helper makes. NM_STATE drives what `device show` reports.
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
case "\$*" in
    *"GENERAL.STATE device show"*)
        printf 'GENERAL.STATE:%s\n' "\${NM_STATE:-100 (connected)}"
        ;;
    *"-f WIFI radio"*) printf 'enabled\n' ;;
    *"GENERAL.CONNECTION device show"*) printf 'GENERAL.CONNECTION:Studio\n' ;;
    *"IP4.ADDRESS device show"*) printf 'IP4.ADDRESS[1]:10.0.0.5/24\n' ;;
    monitor)
        # nmcli monitor's banner, then a join's device lines, then an end.
        printf 'NetworkManager is running\n'
        printf 'wlan0: connecting (prepare)\n'
        printf "wlan0: using connection 'Studio \\"5G\\"'\n"
        printf 'wlan0: connected\n'
        ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
}

teardown() { rm -rf "$work"; }

run_ctl() {
    PATH="$work/bin:$PATH" \
    SEGNO_WIFI_IFACE=wlan0 \
    NM_STATE="${NM_STATE:-100 (connected)}" \
        sh "$CTL" "$@" >"$work/stdout" 2>"$work/stderr"
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

called_with() { grep -qF "$1" "$work/nmcli-args" && echo yes || echo no; }

# --- the radio is never handed away ----------------------------------------

echo "no verb ever unmanages the interface"
setup
for verb in status scan disconnect; do run_ctl "$verb"; done
run_ctl forget Studio
run_ctl radio on
check "never sets managed no" no "$(called_with 'device set wlan0 managed no')"
teardown

echo "read-only verbs never drop the link"
setup
# Disconnecting is correct for `disconnect` and wrong for everything else: a
# status poll that bounced the radio is how a UI ends up fighting its own user.
run_ctl status
run_ctl scan
run_ctl radio on
check "status/scan/radio leave the connection up" no \
    "$(called_with 'device disconnect wlan0')"
run_ctl disconnect
check "disconnect still disconnects" yes \
    "$(called_with 'device disconnect wlan0')"
teardown

echo "the helper spawns no supplicant of its own"
setup
# A wpa_supplicant on PATH would be used if any code path still wanted one.
cat > "$work/bin/wpa_supplicant" <<STUB
#!/bin/sh
echo "spawned" > "$work/supplicant-spawned"
exit 0
STUB
cat > "$work/bin/wpa_cli" <<'STUB'
#!/bin/sh
echo "OK"
exit 0
STUB
chmod +x "$work/bin/wpa_supplicant" "$work/bin/wpa_cli"
for verb in status scan disconnect; do run_ctl "$verb"; done
check "never starts wpa_supplicant" no \
    "$([ -f "$work/supplicant-spawned" ] && echo yes || echo no)"
teardown

echo "a scan never switches the radio on"
setup
# The page scans every few seconds while it is open (#1817); one landing just
# after the Wi-Fi switch went off must not undo it.
run_ctl scan
check "no radio call" no "$(called_with 'radio wifi on')"
teardown

echo "status says connected and not connecting"
setup
run_ctl status
check "connected" yes \
    "$(grep -qF '"connected":true,"connecting":false,"ssid":"Studio"' "$work/stdout" && echo yes || echo no)"
teardown

echo "status names the network an activation is joining"
setup
NM_STATE="50 (connecting (configuring))" run_ctl status
check "connecting to Studio" yes \
    "$(grep -qF '"connected":false,"connecting":true,"ssid":"Studio"' "$work/stdout" && echo yes || echo no)"
teardown

echo "monitor streams one JSON event per NetworkManager change"
setup
run_ctl monitor
check "skips the banner, keeps each change, escapes quotes" \
    "$(printf '%s\n' '{"event":"wlan0: connecting (prepare)"}' '{"event":"wlan0: using connection '"'"'Studio \"5G\"'"'"'"}' '{"event":"wlan0: connected"}')" \
    "$(cat "$work/stdout")"
teardown

echo "no verb hands the interface back and forth"
setup
NM_STATE="10 (unmanaged)" run_ctl status
# A console whose wlan0 NetworkManager does not manage is a fault to see in
# status, not one the helper papers over by changing who owns the radio.
check "never sets managed either way" no \
    "$(grep -qF 'managed' "$work/nmcli-args" && echo yes || echo no)"
teardown

# --- no nmcli is honest, not a fallback ------------------------------------

echo "NetworkManager absent"
setup
rm -f "$work/bin/nmcli"
PATH="$work/bin:/usr/bin:/bin" sh "$CTL" status >"$work/stdout" 2>"$work/stderr"
check "status reports unsupported rather than improvising" yes \
    "$(grep -q '"supported":false' "$work/stdout" && echo yes || echo no)"
printf 'pw\n' | PATH="$work/bin:/usr/bin:/bin" sh "$CTL" connect Studio \
    >"$work/stdout" 2>"$work/stderr"; rc=$?
check "connect fails loudly" 1 "$rc"
check "names the missing piece" yes \
    "$(grep -q 'nmcli' "$work/stderr" && echo yes || echo no)"
teardown

echo
echo "wifi-backend: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
