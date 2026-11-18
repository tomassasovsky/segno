#!/usr/bin/env bash
# Tests for how `segno-wifi-ctl connect` explains a failed join (#466, #1817,
# #1843).
#
# This is not cosmetic. The console has no keyboard-and-mouse escape hatch:
# what the Network page says about a failure is the whole diagnosis the owner
# gets. On 2026-11-17 a WiFi 6 router timed out the 802.11 authentication
# (status 16), NetworkManager ended the join as `no-secrets`, the page said
# "Incorrect password", and the owner forgot two networks whose keys were
# right.
#
# NetworkManager ends many failures that never tested the key as
# `no-secrets` on a console with no secret agent, so the assertions here are
# about the code the helper prints on stdout ({"error":<code>}) given what
# wpa_supplicant logged during the attempt. nmcli and journalctl are stubbed;
# no radio involved.
#
# The journal lines are the shapes `journalctl -o cat -t wpa_supplicant -t
# NetworkManager` prints, taken from the format strings of the versions the
# image runs: wpa_supplicant 2.11 (events.c, wpa_supplicant.c; the interface
# name prefixes each line) and NetworkManager 1.50.0 (nm-device-wifi.c,
# nm-device.c; each line starts with its level and a timestamp). The
# on-device check in tool/appliance/verify-network.sh captures the real ones.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-wifi-ctl"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-join-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/nmcli-args"
    : > "$work/journalctl-args"

    # nmcli that creates the profile and then fails activation with $UP_ERROR,
    # NM's wording for this case. `device wifi list` answers $LIST.
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
case "\$*" in
    *"device wifi list"*) [ -n "\${LIST:-}" ] && printf '%s\n' "\$LIST" ;;
    *"connection up"*)
        echo "\${UP_ERROR:-Error: Connection activation failed: Secrets were required, but not provided}" >&2
        exit 4 ;;
    *"-t -f GENERAL.STATE device show"*)
        echo "GENERAL.STATE:30 (disconnected)" ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
    : > "$work/journal"
    # The journal answers $work/journal, or $work/journal-late from read
    # number $LATE_FROM on (2 unless set) when that exists: journald storing
    # a line late.
    cat > "$work/bin/journalctl" <<STUB
#!/bin/sh
case "\$*" in
    *--show-cursor*)
        echo '-- No entries --'
        echo '-- cursor: s=1817;i=42'
        exit 0 ;;
esac
echo "\$@" >> "$work/journalctl-args"
if [ -f "$work/journal-late" ] \
    && [ "\$(wc -l < "$work/journalctl-args")" -ge "\${LATE_FROM:-2}" ]; then
    cat "$work/journal-late"
else
    cat "$work/journal"
fi
STUB
    chmod +x "$work/bin/journalctl"
    # The helper's waits for the journal, counted rather than slept.
    : > "$work/sleeps"
    cat > "$work/bin/sleep" <<STUB
#!/bin/sh
echo "\$1" >> "$work/sleeps"
STUB
    chmod +x "$work/bin/sleep"
}

teardown() { rm -rf "$work"; }

logged() { cat > "$work/journal"; }

# Joins SomeNetwork, with a typed key unless KEY is set empty.
run_connect() {
    printf '%s\n' "${KEY-hunter2000}" | \
    SEGNO_WIFI_IFACE=wlan0 \
    SEGNO_JOURNALCTL="$work/bin/journalctl" \
    SEGNO_WIFI_NM_CONNECT_TIMEOUT=1 \
    SEGNO_JOIN_EVIDENCE_WAIT="${WAIT-0}" LATE_FROM="${LATE_FROM:-2}" \
    LIST="${LIST:-}" UP_ERROR="${UP_ERROR:-}" \
    PATH="$work/bin:$PATH" \
        sh "$CTL" connect "SomeNetwork" 2>"$work/stderr" >"$work/stdout"
    rc=$?
}

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        [ -s "$work/stdout" ] && sed 's/^/       > /' "$work/stdout"
        [ -s "$work/stderr" ] && sed 's/^/       | /' "$work/stderr"
        fail=$((fail + 1))
    fi
}

# The code the helper printed, or empty.
code() {
    sed -n 's/.*"error":"\([a-z-]*\)".*/\1/p' "$work/stdout" | head -n1
}

called_with() { grep -qF -- "$1" "$work/nmcli-args" && echo yes || echo no; }

has() { grep -qF -- "$1" "$2" && echo yes || echo no; }

# --- what the owner hit on 2026-11-17 ---------------------------------------

echo "the access point timed out the 802.11 authentication (status 16)"
setup
logged <<'LOG'
<info>  [1794972307.2795] device (wlan0): state change: disconnected -> prepare (reason 'none', managed-type: 'full')
<info>  [1794972307.3001] device (wlan0): supplicant interface state: disconnected -> associating
wlan0: Trying to associate with SSID 'SomeNetwork'
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
<info>  [1794972307.4112] device (wlan0): supplicant interface state: associating -> disconnected
<warn>  [1794972327.3010] device (wlan0): Activation: (wifi) association took too long
<warn>  [1794972327.3011] device (wlan0): Activation: (wifi) asking for new secrets
<warn>  [1794972327.3022] device (wlan0): no secrets: No agents were available for this request.
<info>  [1794972327.3023] device (wlan0): state change: need-auth -> failed (reason 'no-secrets', managed-type: 'full')
LOG
run_connect
# NM said `no-secrets` about a key the access point never tested.
check "fails" 1 "$rc"
check "is a failed connection, not a password" no-connection "$(code)"
check "names the 802.11 status for the bench" yes "$(has 'status_code=16' "$work/stderr")"
teardown

echo "the access point never started the handshake (#470)"
setup
logged <<'LOG'
wlan0: Trying to associate with SSID 'SomeNetwork'
wlan0: Associated with 58:11:22:34:39:18
<info>  [1794972307.5100] device (wlan0): supplicant interface state: associating -> associated
wlan0: Authentication with 58:11:22:34:39:18 timed out.
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:18 reason=3 locally_generated=1
<info>  [1794972317.5200] device (wlan0): supplicant interface state: associated -> disconnected
<info>  [1794972327.6000] device (wlan0): state change: need-auth -> failed (reason 'no-secrets', managed-type: 'full')
LOG
run_connect
# Associated, then no EAPOL message 1 ever came: the key was not tested.
check "is a failed connection" no-connection "$(code)"
check "names the timeout" yes "$(has 'Authentication with 58:11:22:34:39:18 timed out.' "$work/stderr")"
teardown

echo "an open network that failed"
setup
logged <<'LOG'
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=58:11:22:34:39:18 status_code=1
LOG
KEY='' run_connect
check "is a failed connection" no-connection "$(code)"
teardown

echo "the key really is wrong"
setup
logged <<'LOG'
wlan0: Trying to associate with SSID 'SomeNetwork'
wlan0: Associated with 58:11:22:34:39:1c
<info>  [1794972307.5100] device (wlan0): supplicant interface state: associated -> 4way_handshake
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=15
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="SomeNetwork" auth_failures=1 duration=10 reason=WRONG_KEY
<info>  [1794972308.6200] device (wlan0): supplicant interface state: 4way_handshake -> disconnected
<info>  [1794972308.6210] device (wlan0): Activation: (wifi) disconnected during association, asking for new key
<info>  [1794972308.6300] device (wlan0): state change: need-auth -> failed (reason 'no-secrets', managed-type: 'full')
LOG
run_connect
# The access point sent message 1 and did not accept the key. That IS the key.
check "is a wrong password" wrong-password "$(code)"
check "names wpa_supplicant's line" yes \
    "$(has '4-Way Handshake failed - pre-shared key may be incorrect' "$work/stderr")"
teardown

echo "a handshake failure and a later timeout"
setup
logged <<'LOG'
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="SomeNetwork" auth_failures=2 duration=20 reason=WRONG_KEY
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
LOG
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "the key failure is the specific fact" wrong-password "$(code)"
check "and it is the line named" yes \
    "$(has '4-Way Handshake failed' "$work/stderr")"
teardown

echo "wpa_supplicant set the network aside for something else"
setup
logged <<'LOG'
wlan0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="SomeNetwork" auth_failures=1 duration=10 reason=CONN_FAILED
LOG
run_connect
check "is a failed connection" no-connection "$(code)"
check "one read: the line ends the attempt" 1 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
teardown

echo "no evidence at all"
setup
run_connect
# Absent proof that the access point tested the key, the honest answer is
# that the join did not finish. NM's `no-secrets` is not that proof.
check "is a failed connection" no-connection "$(code)"
check "says there was no evidence" yes "$(has 'no wpa_supplicant evidence' "$work/stderr")"
teardown

echo "only this attempt's evidence is read"
setup
run_connect
# A window of the last 90 s once let another network's handshake failure
# (the phone hotspot's, moments earlier) name this join a wrong password.
check "the journal is read from the attempt's start" yes \
    "$(grep -qF -- '--after-cursor s=1817;i=42 ' "$work/journalctl-args" && echo yes || echo no)"
check "and only wpa_supplicant and NetworkManager" yes \
    "$(grep -qF -- '-t wpa_supplicant -t NetworkManager' "$work/journalctl-args" && echo yes || echo no)"
teardown

echo "wpa_supplicant's line reaches the journal a moment late"
setup
cat > "$work/journal-late" <<'LOG'
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
WAIT= run_connect
check "the journal is read again" 2 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "after one second" 1 "$(wc -l < "$work/sleeps" | tr -d ' ')"
check "and the wrong key is found" wrong-password "$(code)"
teardown

echo "a disconnect alone does not end the wait"
setup
# CTRL-EVENT-DISCONNECTED comes before the handshake line in the same event
# (wpa_supplicant_event_disassoc), so stopping at it could miss the key.
logged <<'LOG'
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=15
LOG
cat > "$work/journal-late" <<'LOG'
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=15
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
WAIT= run_connect
check "read again" 2 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "the wrong key is found" wrong-password "$(code)"
teardown

echo "wpa_supplicant's line reaches the journal two seconds late"
setup
cat > "$work/journal-late" <<'LOG'
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="SomeNetwork" auth_failures=1 duration=10 reason=WRONG_KEY
LOG
WAIT= LATE_FROM=3 run_connect
# The default wait is 3 s, read again once a second.
check "read three times" 3 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "still a wrong password" wrong-password "$(code)"
teardown

echo "a failure wpa_supplicant never logs waits 3 s at most"
setup
UP_ERROR='Error: Timeout expired (45 seconds)' WAIT= run_connect
check "three waits of a second" 3 "$(wc -l < "$work/sleeps" | tr -d ' ')"
check "four reads" 4 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "then no-connection" no-connection "$(code)"
teardown

echo "wpa_supplicant's lines already there are read once"
setup
logged <<'LOG'
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
LOG
run_connect
check "one read" 1 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "no wait" 0 "$(wc -l < "$work/sleeps" | tr -d ' ')"
teardown

echo "a journal with no cursor is read from the attempt's second"
setup
cat > "$work/bin/journalctl" <<STUB
#!/bin/sh
case "\$*" in *--show-cursor*) exit 0 ;; esac
echo "\$@" >> "$work/journalctl-args"
STUB
run_connect
check "since the second" yes \
    "$(grep -qE -- '--since @[0-9]+ ' "$work/journalctl-args" && echo yes || echo no)"
teardown

echo "NetworkManager logged that the network was not found"
setup
logged <<'LOG'
<warn>  [1794972327.3010] device (wlan0): Activation: (wifi) association took too long, failing activation
<info>  [1794972327.3023] device (wlan0): state change: config -> failed (reason 'ssid-not-found', managed-type: 'full')
LOG
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is not found" not-found "$(code)"
teardown

echo "NetworkManager logged that no address came"
setup
logged <<'LOG'
<info>  [1794972330.1000] device (wlan0): state change: ip-config -> failed (reason 'ip-config-unavailable', managed-type: 'full')
LOG
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is no address" no-address "$(code)"
teardown

echo "the join timed out"
setup
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is a failed connection" no-connection "$(code)"
teardown

echo "no address came"
setup
UP_ERROR='Error: Connection activation failed: IP configuration could not be reserved (no available address, timeout, etc.)' \
    run_connect
check "is no address" no-address "$(code)"
teardown

echo "NetworkManager could not find the network"
setup
UP_ERROR='Error: Connection activation failed: The Wi-Fi network could not be found' \
    run_connect
check "is not found" not-found "$(code)"
teardown

# --- a network that is not in range -----------------------------------------

echo "a network the scan does not see"
setup
LIST=$'Studio\nCafe' run_connect
check "fails" 1 "$rc"
check "is not found" not-found "$(code)"
check "looked again with a fresh scan" yes "$(called_with '--rescan yes')"
# Nothing changed, so the network that was up stays up.
check "creates no profile" no "$(called_with 'connection add')"
check "activates nothing" no "$(called_with 'connection up')"
teardown

echo "a network the scan sees"
setup
LIST=$'Studio\nSomeNetwork' run_connect
check "goes on to join it" yes "$(called_with 'connection add')"
check "needs no fresh scan" no "$(called_with '--rescan yes')"
teardown

echo "a network whose name starts with a dash"
setup
# grep would read "-guest" as an option without --.
printf '%s\n' hunter2000 | SEGNO_WIFI_IFACE=wlan0 SEGNO_JOURNALCTL="$work/bin/journalctl" \
    SEGNO_WIFI_NM_CONNECT_TIMEOUT=1 SEGNO_JOIN_EVIDENCE_WAIT=0 \
    LIST=$'Studio\n-guest' UP_ERROR= \
    PATH="$work/bin:$PATH" sh "$CTL" connect '-guest' 2>"$work/stderr" >"$work/stdout"
check "is found in the scan" yes "$(called_with 'connection add')"
teardown

echo "an empty scan proves nothing"
setup
run_connect
check "goes on to join" yes "$(called_with 'connection add')"
teardown

echo
echo "wifi-join-errors: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
