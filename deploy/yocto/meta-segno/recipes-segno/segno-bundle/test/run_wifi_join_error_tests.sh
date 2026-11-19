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
# image runs: wpa_supplicant 2.11 (events.c, sme.c, wpa_supplicant.c; the
# interface name prefixes each line) and NetworkManager 1.50.0 (nm-device-wifi.c,
# nm-device.c; each line starts with its level and a timestamp). The
# on-device check in deploy/rpi/verify-network-on-device.sh captures the real
# ones.
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
    : > "$work/journalctl-watch"

    # nmcli that creates the profile and then fails activation with $UP_ERROR,
    # NM's wording for this case. `device wifi list` answers $LIST. With
    # SAVED_TS set, SomeNetwork is already saved: its connection.timestamp is
    # SAVED_TS (0 until it has connected) and its stored key SAVED_PSK. With
    # STORED_RIGHT set that stored key is right: an activation that still
    # holds it (no ClearSecrets through busctl) goes up on it, as
    # NetworkManager's does without asking an agent for the typed key.
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
saved=\${SAVED_TS:+5a7ed000-0000-4000-8000-000000001859}
case "\$*" in
    *"-t -f UUID,TYPE connection show") [ -n "\$saved" ] && echo "\$saved:802-11-wireless" ;;
    *"UUID,FILENAME connection show") [ -n "\$saved" ] && echo "\$saved:/data/NetworkManager/system-connections/SomeNetwork.nmconnection" ;;
    *"-g connection.id connection show uuid "*|*"-g 802-11-wireless.ssid connection show uuid "*)
        echo SomeNetwork ;;
    *"-g connection.timestamp connection show uuid "*) echo "\$SAVED_TS" ;;
    *"-g 802-11-wireless-security.psk connection show uuid "*) echo "\${SAVED_PSK:-}" ;;
    *"-g connection.autoconnect connection show uuid "*) echo yes ;;
    *"device wifi list"*) [ -n "\${LIST:-}" ] && printf '%s\n' "\$LIST" ;;
    *"connection up"*)
        if [ -n "\${STORED_RIGHT:-}" ] && [ ! -f "$work/cleared" ]; then
            exit 0
        fi
        # UP_HOLD: the activation runs until it is taken down, as
        # NetworkManager's does while wpa_supplicant retries a refused key,
        # and fails as NM reports a deactivated one. Bounded, so a helper
        # that never takes it down fails the test instead of hanging it.
        if [ -n "\${UP_HOLD:-}" ]; then
            i=0
            while [ ! -f "$work/down" ] && [ \$i -lt 50 ]; do /bin/sleep 0.1; i=\$((i + 1)); done
            [ -f "$work/down" ] || { echo "Error: Timeout expired (45 seconds)" >&2; exit 3; }
            echo "Error: Connection activation failed: The device was disconnected by user or client" >&2
            exit 4
        fi
        echo "\${UP_ERROR:-Error: Connection activation failed: Secrets were required, but not provided}" >&2
        exit 4 ;;
    *"connection down"*) : > "$work/down" ;;
    *"-t -f GENERAL.STATE device show"*)
        echo "GENERAL.STATE:30 (disconnected)" ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
    cat > "$work/bin/busctl" <<STUB
#!/bin/sh
case "\$*" in *" ClearSecrets") : > "$work/cleared" ;; esac
exit 0
STUB
    chmod +x "$work/bin/busctl"
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
# The join's watch reads wpa_supplicant alone; it is counted apart, so the
# counts below are the classifier's reads.
case "\$*" in
    *NetworkManager*) echo "\$@" >> "$work/journalctl-args" ;;
    *) echo "\$@" >> "$work/journalctl-watch" ;;
esac
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
    SEGNO_JOIN_WATCH_INTERVAL=0.5 \
    LIST="${LIST:-}" UP_ERROR="${UP_ERROR:-}" UP_HOLD="${UP_HOLD:-}" \
    SAVED_TS="${SAVED_TS:-}" SAVED_PSK="${SAVED_PSK:-}" STORED_RIGHT="${STORED_RIGHT:-}" \
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

# The classifier's one-second waits for the journal; the join's watch sleeps
# SEGNO_JOIN_WATCH_INTERVAL (0.5 here) and is not counted.
waits() { grep -cx 1 "$work/sleeps"; }

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
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=15
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
WAIT= run_connect
check "is a failed connection" no-connection "$(code)"
check "two reads: the line ends the attempt once it holds" 2 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
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
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=15
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
WAIT= run_connect
check "the journal is read again" 2 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "after one second" 1 "$(waits)"
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
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=15
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
check "three waits of a second" 3 "$(waits)"
check "four reads" 4 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "then no-connection" no-connection "$(code)"
teardown

echo "an attempt that already ended is read once more, a second later"
setup
logged <<'LOG'
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
LOG
WAIT= run_connect
check "two reads" 2 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "one wait" 1 "$(waits)"
check "a failed connection" no-connection "$(code)"
teardown

echo "a handshake failure is read at once"
setup
logged <<'LOG'
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=15
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
WAIT= run_connect
check "one read" 1 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "no wait" 0 "$(waits)"
teardown

echo "a rejected attempt, then a wrong key whose line comes late"
setup
# One join, two attempts: the access point rejects the first association
# (status 16, #1816) and accepts the second, and then the key is refused.
# The rejection is in the journal before the handshake line is.
logged <<'LOG'
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
LOG
cat > "$work/journal-late" <<'LOG'
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
wlan0: Associated with 58:11:22:34:39:1c
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=15
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
WAIT= run_connect
check "is a wrong password" wrong-password "$(code)"
teardown

echo "NetworkManager's attempt at another profile says nothing about this join"
setup
# A saved hidden network out of range: NM tried it by itself just before.
logged <<'LOG'
<info>  [1794972300.1000] device (wlan0): Activation: starting connection 'Hidden' (5d1e0f3a-2b4c-4d6e-8f10-111213141516)
<info>  [1794972305.2000] device (wlan0): state change: config -> failed (reason 'ssid-not-found', managed-type: 'full')
<info>  [1794972307.2794] device (wlan0): Activation: starting connection 'SomeNetwork' (0a3c55e2-9b1f-4c7e-8d2a-6f4b1e0c9d11)
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
LOG
run_connect
check "is a failed connection, not not-found" no-connection "$(code)"
teardown

echo "wpa_supplicant's own timeout during the handshake is not the key"
setup
# could_be_psk_mismatch() writes the handshake line for any drop in the
# handshake, the station's own deauth included.
logged <<'LOG'
wlan0: Associated with 58:11:22:34:39:1c
wlan0: Authentication with 58:11:22:34:39:1c timed out.
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=3 locally_generated=1
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
run_connect
check "is a failed connection" no-connection "$(code)"
teardown

echo "a router that restarts mid-handshake is not the key"
setup
logged <<'LOG'
wlan0: Associated with 58:11:22:34:39:1c
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=3
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
run_connect
check "is a failed connection" no-connection "$(code)"
teardown

echo "an access point that reports a MIC failure refused the key"
setup
logged <<'LOG'
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=14
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
run_connect
check "is a wrong password" wrong-password "$(code)"
check "names the disconnect and the handshake" yes \
    "$(has 'reason=14 / wlan0: WPA: 4-Way Handshake failed' "$work/stderr")"
teardown

# What an ASUS RT-AX89X logged for a wrong key on 2026-11-18 (#1859): it
# ends the handshake with reason 2, "previous authentication no longer
# valid", and wpa_supplicant tries again every 3 s.
refused_twice() {
    logged <<'LOG'
wlan0: Trying to associate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=5200 MHz)
wlan0: Associated with 58:11:22:34:39:1c
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=2
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="SomeNetwork" auth_failures=1 duration=10 reason=WRONG_KEY
wlan0: Trying to associate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=5200 MHz)
wlan0: Associated with 58:11:22:34:39:1c
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=2
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="SomeNetwork" auth_failures=2 duration=20 reason=WRONG_KEY
LOG
}

echo "an access point that refuses the key twice with reason 2"
setup
refused_twice
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is a wrong password" wrong-password "$(code)"
check "names the refusal" yes \
    "$(has 'reason=2 / wlan0: WPA: 4-Way Handshake failed' "$work/stderr")"
teardown

echo "one reason-2 drop in the handshake is not the key"
setup
logged <<'LOG'
wlan0: Associated with 58:11:22:34:39:1c
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=2
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=58:11:22:34:39:1c status_code=16
LOG
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is a failed connection" no-connection "$(code)"
teardown

echo "two drops of wpa_supplicant's own are not the key"
setup
logged <<'LOG'
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=3 locally_generated=1
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=3 locally_generated=1
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
run_connect
check "is a failed connection" no-connection "$(code)"
teardown

echo "the join ends at the second refusal, not at NetworkManager's timeout"
setup
refused_twice
UP_HOLD=1 run_connect
check "fails" 1 "$rc"
check "takes the activation down" yes "$(called_with 'connection down uuid')"
check "is a wrong password" wrong-password "$(code)"
check "says why it ended the join" yes "$(has 'the access point refused the key; ending the join' "$work/stderr")"
check "the watch reads wpa_supplicant from the join's start" yes \
    "$(grep -qF -- '--after-cursor s=1817;i=42 --no-pager -o cat -t wpa_supplicant' "$work/journalctl-watch" && echo yes || echo no)"
teardown

echo "a join the access point has not refused runs to NetworkManager's end"
setup
logged <<'LOG'
wlan0: Associated with 58:11:22:34:39:1c
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=2
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
UP_HOLD=1 run_connect
check "does not take it down" no "$(called_with 'connection down uuid')"
check "is a failed connection" no-connection "$(code)"
teardown

# --- a WPA3-SAE network (#1822) ----------------------------------------------
#
# SAE tests the key in the 802.11 authentication, before any 4-way
# handshake. The lines are wpa_supplicant 2.11's SME (sme.c:
# sme_send_authentication, sme_sae_auth), which runs SAE on the console's
# brcmfmac. A hostapd access point answers a confirm it cannot verify with
# status 15 (ieee802_11.c, handle_auth_sae); wpa_supplicant tries again
# after a back-off of 0.1 s to 5 s (wpas_connection_failed), and after its
# fourth failure in a row sets the network aside.

sae_refused() {
    logged <<'LOG'
<info>  [1795100000.1000] device (wlan0): supplicant interface state: disconnected -> authenticating
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
wlan0: CTRL-EVENT-AUTH-REJECT 58:11:22:34:39:1c auth_type=3 auth_transaction=2 status_code=15
<info>  [1795100000.1500] device (wlan0): supplicant interface state: authenticating -> disconnected
LOG
}

echo "a WPA3-SAE access point refuses the key"
setup
sae_refused
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is a wrong password" wrong-password "$(code)"
check "names the SAE refusal" yes \
    "$(has 'auth_type=3 auth_transaction=2 status_code=15' "$work/stderr")"
check "one read: the refusal is the answer" 1 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
teardown

echo "the join ends at the first SAE refusal"
setup
sae_refused
UP_HOLD=1 run_connect
check "fails" 1 "$rc"
check "takes the activation down" yes "$(called_with 'connection down uuid')"
check "is a wrong password" wrong-password "$(code)"
teardown

echo "an SAE refusal stored a moment late is still found"
setup
logged <<'LOG'
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
LOG
sae_refused
mv "$work/journal" "$work/journal-late"
logged <<'LOG'
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
LOG
WAIT=3 run_connect
check "read again" 2 "$(wc -l < "$work/journalctl-args" | tr -d ' ')"
check "is a wrong password" wrong-password "$(code)"
teardown

echo "an SAE access point that refuses the commit has not tested the key"
setup
# Status 77: the access point does not support the station's group. The
# commit exchange never finished, so no key was compared.
logged <<'LOG'
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
wlan0: CTRL-EVENT-AUTH-REJECT 58:11:22:34:39:1c auth_type=3 auth_transaction=1 status_code=77
LOG
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is a failed connection" no-connection "$(code)"
teardown

echo "an SAE access point that answers nothing"
setup
# Out of range, or an access point that drops a bad confirm silently: the
# SME's timeout logs nothing at syslog level, and wpa_supplicant sets the
# network aside after four failures.
logged <<'LOG'
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
wlan0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="SomeNetwork" auth_failures=1 duration=10 reason=CONN_FAILED
LOG
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is a failed connection" no-connection "$(code)"
teardown

echo "an SAE join that connected after a refusal is not taken down"
setup
logged <<'LOG'
wlan0: CTRL-EVENT-AUTH-REJECT 58:11:22:34:39:1c auth_type=3 auth_transaction=2 status_code=15
wlan0: SME: Trying to authenticate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
wlan0: Trying to associate with 58:11:22:34:39:1c (SSID='SomeNetwork' freq=2437 MHz)
wlan0: Associated with 58:11:22:34:39:1c
wlan0: CTRL-EVENT-CONNECTED - Connection to 58:11:22:34:39:1c completed [id=0 id_str=]
LOG
UP_HOLD=1 run_connect
check "is not taken down" no "$(called_with 'connection down uuid')"
check "is not a wrong password" no-connection "$(code)"
teardown

echo "a saved SAE network refuses the key it has connected with"
setup
sae_refused
KEY= SAVED_TS=1795051833 SAVED_PSK=hunter2000 UP_HOLD=1 run_connect
check "is not taken down" no "$(called_with 'connection down uuid')"
check "is a failed connection, not a password" no-connection "$(code)"
teardown

# --- a key that has connected before (#1816) --------------------------------

echo "a saved network refuses the key it has connected with"
setup
# After a radio restart the RT-AX89X refused the right key with reason 2
# for 44 minutes (2026-11-18). Android counts a refusal as a wrong password
# only on a network that has never connected.
refused_twice
KEY= SAVED_TS=1795051833 SAVED_PSK=hunter2000 UP_HOLD=1 run_connect
check "fails" 1 "$rc"
check "is not watched" 0 "$(wc -l < "$work/journalctl-watch" | tr -d ' ')"
check "is not taken down" no "$(called_with 'connection down uuid')"
check "is a failed connection, not a password" no-connection "$(code)"
teardown

echo "a saved network refuses the stored key typed again"
setup
refused_twice
SAVED_TS=1795051833 SAVED_PSK=hunter2000 UP_HOLD=1 run_connect
check "is not taken down" no "$(called_with 'connection down uuid')"
check "is a failed connection" no-connection "$(code)"
teardown

echo "a saved network refuses a new key"
setup
refused_twice
SAVED_TS=1795051833 SAVED_PSK=the-old-key UP_HOLD=1 run_connect
check "takes the activation down" yes "$(called_with 'connection down uuid')"
check "is a wrong password" wrong-password "$(code)"
teardown

# On 2026-11-19 a wrong key typed for the console's own network, whose stored
# key was right, joined on the stored key in 7.5 s and was then stored over it
# (#1872): the typed key was never tried.
echo "a wrong key typed for a saved network whose stored key is right"
setup
refused_twice
SAVED_TS=1795051833 SAVED_PSK=right-key STORED_RIGHT=1 UP_HOLD=1 run_connect
check "fails" 1 "$rc"
check "is a wrong password" wrong-password "$(code)"
check "takes the activation down" yes "$(called_with 'connection down uuid')"
check "stores no key" no "$(called_with 'connection edit')"
check "saves nothing to the stored profile" no "$(called_with 'connection modify uuid')"
teardown

echo "a saved network that never connected refuses its stored key"
setup
refused_twice
KEY= SAVED_TS=0 SAVED_PSK=hunter2000 UP_HOLD=1 run_connect
check "takes the activation down" yes "$(called_with 'connection down uuid')"
check "is a wrong password" wrong-password "$(code)"
teardown

echo "a join whose handshake completed is not taken down"
setup
# 23:14:13 on 2026-11-18: one refusal, then the same key connected, and the
# watch took the connection down 0.2 s later.
logged <<'LOG'
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=2
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: Associated with 58:11:22:34:39:1c
wlan0: CTRL-EVENT-CONNECTED - Connection to 58:11:22:34:39:1c completed [id=0 id_str=]
wlan0: CTRL-EVENT-DISCONNECTED bssid=58:11:22:34:39:1c reason=2
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
LOG
UP_HOLD=1 run_connect
check "is not taken down" no "$(called_with 'connection down uuid')"
check "is not a wrong password" no-connection "$(code)"
teardown

echo "an open network's join is not watched"
setup
refused_twice
KEY= run_connect
check "no watch reads" 0 "$(wc -l < "$work/journalctl-watch" | tr -d ' ')"
teardown

echo "another interface's failure says nothing about this join"
setup
logged <<'LOG'
<info>  [1794972330.0500] device (eth0): state change: ip-config -> failed (reason 'ip-config-unavailable', managed-type: 'full')
wlan0: CTRL-EVENT-ASSOC-REJECT bssid=00:00:00:00:00:00 status_code=16
LOG
run_connect
check "is a failed connection, not no-address" no-connection "$(code)"
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
<info>  [1794972307.2794] device (wlan0): Activation: starting connection 'SomeNetwork' (0a3c55e2-9b1f-4c7e-8d2a-6f4b1e0c9d11)
<warn>  [1794972327.3010] device (wlan0): Activation: (wifi) association took too long, failing activation
<info>  [1794972327.3023] device (wlan0): state change: config -> failed (reason 'ssid-not-found', managed-type: 'full')
LOG
UP_ERROR='Error: Timeout expired (45 seconds)' run_connect
check "is not found" not-found "$(code)"
teardown

echo "NetworkManager logged that no address came"
setup
logged <<'LOG'
<info>  [1794972307.2794] device (wlan0): Activation: starting connection 'SomeNetwork' (0a3c55e2-9b1f-4c7e-8d2a-6f4b1e0c9d11)
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
