#!/usr/bin/env bash
# Tests for the Network page's helper verbs (#1270 Part 11): a failed join
# brings the previous network back (D13), a password change never travels in
# argv, Connect automatically maps to connection.autoconnect, status reports
# each saved network's autoconnect and the last one used, and the connectivity
# check is one bounded HEAD request.
#
# nmcli and curl are stubbed; no radio involved. The stub's nmcli writes every
# argv to nmcli-args and its stdin, when it reads one, to nmcli-stdin.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-wifi-ctl"
TEST_SHELL="${TEST_SHELL:-sh}"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-manage-test.XXXXXX")
    mkdir -p "$work/bin"
    : > "$work/nmcli-args"
    : > "$work/nmcli-stdin"
    : > "$work/ctl-args"
    : > "$work/passwd-file"
    : > "$work/added"
    : > "$work/used-keys"
    : > "$work/busctl-args"
    mkdir -p "$work/stored" "$work/mem" "$work/run/system-connections"
    # Saved profiles come from SAVED (space-separated names). Their UUIDs are
    # uuid-<name> with ':' made '_', so, like real UUIDs, they carry no colon,
    # while the names may. A profile the helper adds is remembered by the UUID
    # it was given.
    #
    # Each profile's key is NetworkManager's: stored/<uuid> once something has
    # saved one (STORED_PSK until then), and mem/<uuid> while a copy of the
    # profile is held in memory (modify --temporary), whose file is then
    # run/system-connections/<uuid>.nmconnection. ClearSecrets empties the key
    # of the copy, or of the stored profile when there is none. An activation
    # uses the profile's key, and asks the agent (the passwd-file) only when
    # it has none, saving the agent's key into a held copy. With GOOD_KEY set,
    # an activation on any other key fails.
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
uuid_of() { printf 'uuid-%s' "\$(printf '%s' "\$1" | tr ':' '_')"; }
name_of() {
    added=\$(awk -F'\t' -v u="\$1" '\$1 == u { print \$2; exit }' "$work/added")
    [ -n "\$added" ] && { printf '%s\n' "\$added"; return; }
    for n in \${SAVED:-}; do
        [ "\$(uuid_of "\$n")" = "\$1" ] && { printf '%s\n' "\$n"; return; }
    done
    printf '%s\n' "\${1#uuid-}"
}
all_uuids() {
    for n in \${SAVED:-}; do uuid_of "\$n"; echo; done
    cut -f1 "$work/added"
}
key_of() {
    if [ -f "$work/mem/\$1" ]; then cat "$work/mem/\$1"
    elif [ -f "$work/stored/\$1" ]; then cat "$work/stored/\$1"
    else printf '%s' "\${STORED_PSK:-}"
    fi
}
run_file() { printf '%s' "$work/run/system-connections/\$1.nmconnection"; }
last=\$(eval "printf '%s' \"\\\${\$#}\"")
case "\$*" in
    *"connection edit"*)
        target=\$(printf '%s' "\$*" | sed 's/.*connection edit uuid //')
        input=\$(cat)
        printf '%s\n' "\$input" >> "$work/nmcli-stdin"
        if printf '%s\n' "\$input" | grep -qx 'save persistent'; then
            printf '%s\n' "\$input" \
                | sed -n 's/^set 802-11-wireless-security\.psk //p' | tr -d '\n' \
                > "$work/stored/\$target"
            rm -f "$work/mem/\$target" "\$(run_file "\$target")"
        fi
        ;;
    *"connection modify --temporary uuid "*)
        target=\$(printf '%s' "\$*" | sed 's/.*connection modify --temporary uuid \([^ ]*\) .*/\1/')
        [ -f "$work/mem/\$target" ] || key_of "\$target" > "$work/mem/\$target"
        : > "\$(run_file "\$target")"
        ;;
    *"connection modify uuid "*)
        # Saved to disk: a copy held in memory becomes the stored profile.
        target=\$(printf '%s' "\$*" | sed 's/.*connection modify uuid \([^ ]*\) .*/\1/')
        if [ -f "$work/mem/\$target" ]; then
            mv "$work/mem/\$target" "$work/stored/\$target"
            rm -f "\$(run_file "\$target")"
        fi
        ;;
    *"connection load "*)
        # A held copy whose file is gone: the stored profile is back.
        for u in \$(all_uuids); do
            [ "\$last" = "\$(run_file "\$u")" ] && [ ! -f "\$last" ] && rm -f "$work/mem/\$u"
        done
        ;;
    *"UUID,FILENAME connection show"*)
        [ -n "\${NO_FILE:-}" ] && exit 0
        for u in \$(all_uuids); do
            if [ -f "$work/mem/\$u" ]; then
                printf '%s:%s\n' "\$u" "\$(run_file "\$u")"
            else
                printf '%s:/data/NetworkManager/system-connections/%s.nmconnection\n' "\$u" "\$u"
            fi
        done
        ;;
    *"UUID,DBUS-PATH connection show"*)
        for u in \$(all_uuids); do
            printf '%s:/org/freedesktop/NetworkManager/Settings/%s\n' "\$u" "\$u"
        done
        ;;
    *"connection add"*)
        printf '%s\n' "\$*" \
            | sed 's/.*con-name \(.*\) connection\.uuid \([^ ]*\) .*/\2\t\1/' >> "$work/added"
        ;;
    *"UUID,TYPE,DEVICE connection show --active"*)
        [ -s "$work/active" ] && printf '%s:802-11-wireless:wlan0\n' "\$(cat "$work/active")"
        ;;
    *"UUID,TYPE,AUTOCONNECT,TIMESTAMP connection show"*)
        printf '%s\n' "\${LISTING:-}"
        ;;
    *"-t -f UUID,TYPE connection show"*)
        for n in \${SAVED:-}; do printf '%s:802-11-wireless\n' "\$(uuid_of "\$n")"; done
        ;;
    *"-g 802-11-wireless-security.psk connection show"*)
        printf '%s\n' "\$(key_of "\$last")"
        ;;
    *"-g connection.autoconnect connection show"*)
        printf '%s\n' "\${PRIOR_AC:-yes}"
        ;;
    *"-g connection.autoconnect-priority connection show"*) printf '0\n' ;;
    *"-g 802-11-wireless.hidden connection show"*) printf '%s\n' "\${HIDDEN:-no}" ;;
    *"-g connection.interface-name connection show"*) printf '%s\n' "\${PINNED:-wlan0}" ;;
    *"-f SSID device wifi list"*) [ -n "\${LIST:-}" ] && printf '%s\n' "\$LIST" ;;
    *"-g connection.id connection show"*|*"-g 802-11-wireless.ssid connection show"*)
        name_of "\$last"
        ;;
    *"connection up"*)
        target=\$(printf '%s' "\$*" | sed 's/.*connection up //; s/^uuid //; s/ passwd-file.*//')
        key=\$(key_of "\$target")
        case "\$*" in
            *passwd-file*)
                cp "\$last" "$work/passwd-file"
                if [ -z "\$key" ]; then
                    key=\$(sed 's/^802-11-wireless-security\.psk://; s/\\\\\\(.\\)/\\1/g' "\$last")
                    [ -f "$work/mem/\$target" ] && printf '%s' "\$key" > "$work/mem/\$target"
                fi
                ;;
        esac
        printf '%s [%s]\n' "\$target" "\$key" >> "$work/used-keys"
        # One radio: any activation drops the link that was up.
        : > "$work/active"
        case "\$* \$(name_of "\$target")" in
            *"\${FAIL_UP:-<none>}"*)
                echo "Error: Connection activation failed: (7) Secrets were required, but not provided" >&2
                exit 4
                ;;
        esac
        if [ -n "\${GOOD_KEY:-}" ] && [ "\$key" != "\$GOOD_KEY" ]; then
            echo "Error: Connection activation failed: (7) Secrets were required, but not provided" >&2
            exit 4
        fi
        printf '%s' "\$target" > "$work/active"
        ;;
    *"WIFI radio"*) printf 'enabled\n' ;;
    *"GENERAL.STATE device show"*) printf 'GENERAL.STATE:%s\n' "\${GENERAL_STATE:-30 (disconnected)}" ;;
    *"GENERAL.AUTOCONNECT device show"*) printf '%s\n' "\${DEV_AC:-yes}" ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
    cat > "$work/bin/busctl" <<STUB
#!/bin/sh
echo "\$@" >> "$work/busctl-args"
case "\$*" in
    *" ClearSecrets")
        u=\$(basename "\$3")
        [ "\${BUSCTL_RC:-0}" -eq 0 ] || { echo "Call failed: Access denied" >&2; exit "\$BUSCTL_RC"; }
        if [ -f "$work/mem/\$u" ]; then : > "$work/mem/\$u"; else : > "$work/stored/\$u"; fi
        ;;
esac
exit 0
STUB
    chmod +x "$work/bin/busctl"
    cat > "$work/bin/journalctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$work/bin/journalctl"
    cat > "$work/bin/curl" <<STUB
#!/bin/sh
echo "\$@" >> "$work/curl-args"
printf '%s' "\${HTTP_CODE:-200}"
exit \${CURL_RC:-0}
STUB
    chmod +x "$work/bin/curl"
}

teardown() { rm -rf "$work"; }

# Runs the helper the way the app does, with [stdin] on its standard input.
run_with_stdin() {
    local stdin=$1
    shift
    if [ -n "${ACTIVE:-}" ]; then
        printf 'uuid-%s' "$(printf '%s' "$ACTIVE" | tr ':' '_')" > "$work/active"
    else
        : > "$work/active"
    fi
    printf '%s\n' "$*" >> "$work/ctl-args"
    printf '%s' "$stdin" | PATH="$work/bin:$PATH" SEGNO_JOURNALCTL="$work/bin/journalctl" \
        SAVED="${SAVED:-}" ACTIVE="${ACTIVE:-}" FAIL_UP="${FAIL_UP:-<none>}" \
        LISTING="${LISTING:-}" PRIOR_AC="${PRIOR_AC:-yes}" \
        GENERAL_STATE="${GENERAL_STATE:-30 (disconnected)}" \
        HIDDEN="${HIDDEN:-no}" LIST="${LIST:-}" SEGNO_JOIN_EVIDENCE_WAIT=0 \
        STORED_PSK="${STORED_PSK:-}" DEV_AC="${DEV_AC:-yes}" GOOD_KEY="${GOOD_KEY:-}" BUSCTL_RC="${BUSCTL_RC:-0}" NO_FILE="${NO_FILE:-}" \
        SEGNO_NM_RUN_DIR="$work/run" SEGNO_SYS_CLASS_NET="$work/sys" PINNED="${PINNED:-wlan0}" \
        HTTP_CODE="${HTTP_CODE:-200}" CURL_RC="${CURL_RC:-0}" \
        "$TEST_SHELL" "$CTL" "$@" >"$work/stdout" 2>"$work/stderr"
    rc=$?
}

run() { run_with_stdin '' "$@"; }

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"; pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        [ -s "$work/stdout" ] && sed 's/^/       > /' "$work/stdout"
        [ -s "$work/stderr" ] && sed 's/^/       ! /' "$work/stderr"
        fail=$((fail + 1))
    fi
}

has() { grep -qF -- "$1" "$2" && echo yes || echo no; }

echo "a wrong password while on The Studio brings The Studio back"
setup
ACTIVE="The Studio" FAIL_UP="Rehearsal" run_with_stdin 'wrongpass' connect Rehearsal
check "the join fails" 1 "$rc"
check "reactivates the previous connection" yes \
    "$(has 'connection up uuid uuid-The Studio' "$work/nmcli-args")"
check "prints why, then restored" '{"error":"no-connection"}
{"restored":"The Studio"}' "$(cat "$work/stdout")"
check "still explains the failure" yes \
    "$(has 'segno-wifi-ctl:' "$work/stderr")"
created=$(sed -n 's/.*connection\.uuid \([^ ]*\) .*/\1/p' "$work/nmcli-args" | head -n1)
check "the profile is created with a UUID of its own" yes \
    "$([ -n "$created" ] && echo yes || echo no)"
check "and activated by it" yes "$(has "connection up uuid $created" "$work/nmcli-args")"
check "the failed profile is removed by that UUID" yes \
    "$(has "connection delete uuid $created" "$work/nmcli-args")"
check "never by a name another profile may share" no \
    "$(has 'connection delete id' "$work/nmcli-args")"
teardown

echo "a failed join with nothing active before restores nothing"
setup
FAIL_UP="Rehearsal" run_with_stdin 'wrongpass' connect Rehearsal
check "the join fails" 1 "$rc"
check "prints only why" '{"error":"no-connection"}' "$(cat "$work/stdout")"
check "only the one activation" 1 \
    "$(grep -c 'connection up' "$work/nmcli-args" | tr -d ' ')"
teardown

echo "a successful join restores nothing"
setup
ACTIVE="The Studio" run_with_stdin 'goodpass' connect Rehearsal
check "the join succeeds" 0 "$rc"
check "prints {}" '{}' "$(cat "$work/stdout")"
check "the previous network is not reactivated" no \
    "$(has 'connection up uuid uuid-The Studio' "$work/nmcli-args")"
teardown

echo "a wrong new password on a saved network keeps its autoconnect"
setup
SAVED="Rehearsal" ACTIVE="The Studio" FAIL_UP="uuid-Rehearsal" PRIOR_AC=no \
    run_with_stdin 'wrongpass' connect Rehearsal
check "autoconnect is turned off in memory only" yes \
    "$(has 'connection modify --temporary uuid uuid-Rehearsal connection.autoconnect no' "$work/nmcli-args")"
check "nothing is saved to the stored profile" no \
    "$(has 'connection modify uuid uuid-Rehearsal' "$work/nmcli-args")"
check "the copy in memory is dropped" no \
    "$([ -e "$work/mem/uuid-Rehearsal" ] || [ -e "$work/run/system-connections/uuid-Rehearsal.nmconnection" ] && echo yes || echo no)"
check "and NetworkManager loads the stored profile again" yes \
    "$(has "connection load $work/run/system-connections/uuid-Rehearsal.nmconnection" "$work/nmcli-args")"
check "the saved profile is kept" no \
    "$(has 'connection delete' "$work/nmcli-args")"
teardown

# A typed key for a saved network used to be handed only to an agent, and
# NetworkManager asks none while it holds a key: the join went up on the
# stored key and then stored the typed one over it, wrong or not (#1872).
echo "a wrong key typed for a saved network whose stored key is right"
setup
SAVED="Studio" ACTIVE="Studio" STORED_PSK='right-key' GOOD_KEY='right-key' \
    run_with_stdin 'notthekey' connect Studio
check "the join fails" 1 "$rc"
check "the activation tried the typed key" yes \
    "$(has 'uuid-Studio [notthekey]' "$work/used-keys")"
check "the stored key is unchanged" 'right-key' "$(cat "$work/stored/uuid-Studio" 2>/dev/null || printf '%s' 'right-key')"
check "the typed key is not stored" no "$(has 'notthekey' "$work/nmcli-stdin")"
check "no copy is left in memory" no \
    "$([ -e "$work/mem/uuid-Studio" ] && echo yes || echo no)"
check "the network comes back on its stored key" yes \
    "$(sed -n '$p' "$work/used-keys" | grep -qxF 'uuid-Studio [right-key]' && echo yes || echo no)"
check "prints why, then restored" '{"error":"no-connection"}
{"restored":"Studio"}' "$(cat "$work/stdout")"
teardown

echo "the right new key typed for a saved network joins on it and is stored"
setup
SAVED="Studio" ACTIVE="Studio" STORED_PSK='old-key' GOOD_KEY='new-key' \
    run_with_stdin 'new-key' connect Studio
check "the join succeeds" 0 "$rc"
check "the activation used the typed key" yes \
    "$(has 'uuid-Studio [new-key]' "$work/used-keys")"
check "the stored key is the new one" 'new-key' "$(cat "$work/stored/uuid-Studio" 2>/dev/null)"
check "no copy is left in memory" no \
    "$([ -e "$work/mem/uuid-Studio" ] && echo yes || echo no)"
check "autoconnect comes on with it" yes \
    "$(has 'connection modify uuid uuid-Studio wifi-sec.psk-flags 0 connection.autoconnect yes' "$work/nmcli-args")"
check "the key is cleared on the copy, not on the stored profile" \
    'call org.freedesktop.NetworkManager /org/freedesktop/NetworkManager/Settings/uuid-Studio org.freedesktop.NetworkManager.Settings.Connection ClearSecrets' \
    "$(cat "$work/busctl-args")"
teardown

echo "a new key with a space at either end for a saved network is used and stored as typed"
setup
SAVED="Studio" STORED_PSK='old-key' GOOD_KEY=' edge ' run_with_stdin ' edge ' connect Studio
check "the join succeeds" 0 "$rc"
check "the activation used the key as typed" yes "$(has 'uuid-Studio [ edge ]' "$work/used-keys")"
check "and it is stored as typed" ' edge ' "$(cat "$work/stored/uuid-Studio" 2>/dev/null)"
check "without the editor" no "$(has 'connection edit' "$work/nmcli-args")"
teardown

echo "a saved profile whose key cannot be cleared is not joined on its stored key"
setup
SAVED="Studio" STORED_PSK='right-key' GOOD_KEY='right-key' BUSCTL_RC=1 \
    run_with_stdin 'notthekey' connect Studio
check "the join fails" 1 "$rc"
check "nothing is activated with the typed key" no "$(has 'passwd-file' "$work/nmcli-args")"
check "the stored key is unchanged" no "$(has 'notthekey' "$work/nmcli-stdin")"
check "no copy is left in memory" no \
    "$([ -e "$work/mem/uuid-Studio" ] && echo yes || echo no)"
teardown

# Only Forget deletes a saved network (#1817): the owner forgot two good
# networks after the page blamed their keys, and a join that deleted one on
# failure would do the same without asking.
# The copy is told from the stored profile by the stored file's path, so a
# join whose profile has no path it can read is not tried.
echo "a saved profile whose stored file cannot be found is not set aside"
setup
SAVED="Studio" STORED_PSK='right-key' GOOD_KEY='right-key' NO_FILE=1 \
    run_with_stdin 'notthekey' connect Studio
check "the join fails" 1 "$rc"
check "the profile is not changed in memory" no "$(has 'modify --temporary' "$work/nmcli-args")"
check "nothing is activated with the typed key" no "$(has 'passwd-file' "$work/nmcli-args")"
check "no file is loaded" no "$(has 'connection load' "$work/nmcli-args")"
check "and says why" yes "$(has 'could not find where the saved network is stored' "$work/stderr")"
teardown

echo "a failed join never deletes a saved network"
setup
SAVED="Rehearsal" FAIL_UP="uuid-Rehearsal" STORED_PSK='s3cret' run connect Rehearsal
check "the join on its stored key fails" 1 "$rc"
check "the saved profile is kept" no "$(has 'connection delete' "$work/nmcli-args")"
check "and no second one is made" no "$(has 'connection add' "$work/nmcli-args")"
teardown
setup
SAVED="Rehearsal" FAIL_UP="uuid-Rehearsal" run_with_stdin 'n3w-key' connect Rehearsal
check "the join with a new key fails" 1 "$rc"
check "the saved profile is still kept" no "$(has 'connection delete' "$work/nmcli-args")"
teardown

# A hidden network never shows in a scan under its name; segno-wifi-retry
# allows for saved ones, and so must a join.
echo "a saved hidden network is joined without the scan check"
setup
SAVED="Backstage" HIDDEN=yes LIST="Studio" run connect Backstage
check "goes up" yes "$(has 'connection up uuid uuid-Backstage' "$work/nmcli-args")"
teardown

echo "a saved network that is not hidden and not in the scan is not found"
setup
SAVED="Backstage" LIST="Studio" run connect Backstage
check "fails" 1 "$rc"
check "as not found" '{"error":"not-found"}' "$(cat "$work/stdout")"
check "activates nothing" no "$(has 'connection up' "$work/nmcli-args")"
teardown

echo "a wrong new password for the network that is up brings it back on its old key"
setup
SAVED="Studio" ACTIVE="Studio" FAIL_UP="passwd-file" run_with_stdin 'wrongpass' connect Studio
check "the join fails" 1 "$rc"
check "reactivates it without the new key" yes \
    "$(grep -qxF 'connection up uuid uuid-Studio' <(sed 's/^--wait [0-9]* //' "$work/nmcli-args") && echo yes || echo no)"
check "prints why, then restored" '{"error":"no-connection"}
{"restored":"Studio"}' "$(cat "$work/stdout")"
teardown

# After a failure that ended as `no-secrets` NetworkManager asks secret agents
# for a NEW key and the console runs none, so the restore hands the stored key
# over itself (#1326).
echo "a failed join restores the previous network on its stored key"
setup
SAVED="The Studio" ACTIVE="The Studio" FAIL_UP="Rehearsal" STORED_PSK='old key' \
    run_with_stdin 'wrongpass' connect Rehearsal
check "the join fails" 1 "$rc"
check "restores through a passwd-file" yes \
    "$(grep 'connection up uuid uuid-The Studio' "$work/nmcli-args" | grep -q passwd-file && echo yes || echo no)"
check "on the stored key, escaped" '802-11-wireless-security.psk:old\ key' "$(cat "$work/passwd-file")"
check "prints why, then restored" '{"error":"no-connection"}
{"restored":"The Studio"}' "$(cat "$work/stdout")"
teardown

echo "activate brings a saved profile up on its stored key"
setup
SAVED="Studio" STORED_PSK='s3cret' run activate uuid-Studio 20
check "succeeds" 0 "$rc"
check "prints {}" '{}' "$(cat "$work/stdout")"
check "activates that uuid within the given wait" yes \
    "$(has '--wait 20 connection up uuid uuid-Studio passwd-file' "$work/nmcli-args")"
check "hands the stored key over" '802-11-wireless-security.psk:s3cret' "$(cat "$work/passwd-file")"
check "the key is never in argv" no "$(has 's3cret' "$work/nmcli-args")"
check "the key file is gone afterwards" 0 \
    "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -newer "$work/ctl-args" -type f -exec grep -l 's3cret' {} + 2>/dev/null | wc -l | tr -d ' ')"
teardown

# nmcli registers its agent before asking for the activation, and NM answers
# a new agent by auto-activating a profile it had blocked for missing
# secrets. Two activations on wlan0 at once left the bench console stuck in
# "getting IP configuration" (#1326).
echo "activate pauses device autoconnect around the activation"
setup
SAVED="Studio" STORED_PSK='s3cret' run activate uuid-Studio
line() { grep -n -F -- "$1" "$work/nmcli-args" | head -1 | cut -d: -f1; }
check "pauses before the up" yes \
    "$([ -n "$(line 'device set wlan0 autoconnect no')" ] && [ "$(line 'device set wlan0 autoconnect no')" -lt "$(line 'connection up')" ] && echo yes || echo no)"
check "resumes after the up" yes \
    "$([ -n "$(line 'device set wlan0 autoconnect yes')" ] && [ "$(line 'device set wlan0 autoconnect yes')" -gt "$(line 'connection up')" ] && echo yes || echo no)"
teardown

echo "a join with a password pauses device autoconnect around its activation too"
setup
run_with_stdin 'n3w-pass' connect Rehearsal
check "the join succeeds" 0 "$rc"
check "pauses before the up" yes \
    "$([ -n "$(line 'device set wlan0 autoconnect no')" ] && [ "$(line 'device set wlan0 autoconnect no')" -lt "$(line 'connection up')" ] && echo yes || echo no)"
check "resumes after the up" yes \
    "$([ -n "$(line 'device set wlan0 autoconnect yes')" ] && [ "$(line 'device set wlan0 autoconnect yes')" -gt "$(line 'connection up')" ] && echo yes || echo no)"
teardown

echo "activate resumes device autoconnect after a failed activation too"
setup
SAVED="Studio" STORED_PSK='s3cret' FAIL_UP="uuid-Studio" run activate uuid-Studio
check "fails" 1 "$rc"
check "resumes" yes "$(has 'device set wlan0 autoconnect yes' "$work/nmcli-args")"
teardown

echo "activate leaves a device the owner disconnected alone"
setup
SAVED="Studio" STORED_PSK='s3cret' DEV_AC=no run activate uuid-Studio
check "succeeds" 0 "$rc"
check "does not touch device autoconnect" no "$(has 'device set wlan0 autoconnect' "$work/nmcli-args")"
teardown

echo "activate on an open network goes up without a key file"
setup
SAVED="Cafe" run activate uuid-Cafe
check "succeeds" 0 "$rc"
check "no passwd-file" no "$(has 'passwd-file' "$work/nmcli-args")"
teardown

# A join that tests a typed key holds the profile with autoconnect off and no
# key; segno-wifi-retry may have listed it just before.
echo "activate leaves a profile that may not auto-join alone"
setup
SAVED="Studio" PRIOR_AC=no STORED_PSK='s3cret' run activate uuid-Studio
check "fails" 1 "$rc"
check "activates nothing" no "$(has 'connection up' "$work/nmcli-args")"
check "and says why" yes "$(has 'may not auto-join now' "$work/stderr")"
teardown

echo "activate reports a failed activation"
setup
SAVED="Studio" STORED_PSK='s3cret' FAIL_UP="uuid-Studio" run activate uuid-Studio
check "fails" 1 "$rc"
check "prints nothing" "" "$(cat "$work/stdout")"
teardown

echo "connect reads the key from stdin and no argv ever holds it"
setup
ACTIVE="The Studio" run_with_stdin "$(printf 'n3w-s3cret\n')" connect Rehearsal
check "succeeds" 0 "$rc"
check "the helper's argv never holds the key" no "$(has 'n3w-s3cret' "$work/ctl-args")"
check "nmcli's argv never holds the key" no "$(has 'n3w-s3cret' "$work/nmcli-args")"
check "the key reaches nmcli in the passwd-file" \
    '802-11-wireless-security.psk:n3w-s3cret' "$(cat "$work/passwd-file")"
check "and is stored through the editor's stdin" yes \
    "$(has 'set 802-11-wireless-security.psk n3w-s3cret' "$work/nmcli-stdin")"
check "autoconnect comes on with it" yes \
    "$(has 'wifi-sec.psk-flags 0 connection.autoconnect yes' "$work/nmcli-args")"
teardown

echo "a new key for a saved network never reaches any argv either"
setup
SAVED="Rehearsal" run_with_stdin 'n3w-s3cret' connect Rehearsal
check "succeeds" 0 "$rc"
check "nmcli's argv never holds the key" no "$(has 'n3w-s3cret' "$work/nmcli-args")"
check "nor busctl's" no "$(has 'n3w-s3cret' "$work/busctl-args")"
check "the key is stored" 'n3w-s3cret' "$(cat "$work/stored/uuid-Rehearsal" 2>/dev/null)"
teardown

echo "a failed join never puts the key in any argv"
setup
ACTIVE="The Studio" FAIL_UP="Rehearsal" run_with_stdin 'n3w-s3cret' connect Rehearsal
check "fails" 1 "$rc"
check "nmcli's argv never holds the key" no "$(has 'n3w-s3cret' "$work/nmcli-args")"
check "nor does the error" no "$(has 'n3w-s3cret' "$work/stderr")"
check "nothing is stored" no "$(has 'n3w-s3cret' "$work/nmcli-stdin")"
teardown

echo "a key NetworkManager already saved from the passwd-file is not written again"
setup
STORED_PSK='n3w-s3cret' run_with_stdin 'n3w-s3cret' connect Rehearsal
check "succeeds" 0 "$rc"
check "the editor is not used" no "$(has 'connection edit' "$work/nmcli-args")"
teardown

echo "a key in argv is refused, not ignored"
setup
run connect Rehearsal n3w-s3cret
check "usage" 2 "$rc"
check "nothing reaches nmcli" no "$(has 'connection' "$work/nmcli-args")"
teardown

echo "the passwd-file carries the key byte for byte"
setup
STORED_PSK=' back\slash and spaces ' \
    run_with_stdin ' back\slash and spaces ' connect Rehearsal
check "succeeds" 0 "$rc"
check "spaces and backslashes escaped, so nmcli strips and unescapes nothing" \
    '802-11-wireless-security.psk:\ back\\slash\ and\ spaces\ ' "$(cat "$work/passwd-file")"
teardown

echo "a key with a space at either end is not cut down by the editor"
setup
run_with_stdin ' edge ' connect Rehearsal
check "the join still succeeds" 0 "$rc"
check "the editor never stores a stripped key" no "$(has 'connection edit' "$work/nmcli-args")"
check "and says why" yes "$(has 'starts or ends with a space' "$work/stderr")"
SAVED="Rehearsal" run_with_stdin ' edge ' set-password Rehearsal
check "set-password refuses it" 2 "$rc"
check "and stores nothing" no "$(has 'edge' "$work/nmcli-stdin")"
teardown

echo "a network whose name has a colon in it can be managed"
setup
SAVED="Cafe:Bar" run autoconnect Cafe:Bar off
check "autoconnect finds it" 0 "$rc"
check "by its UUID" yes \
    "$(has 'connection modify uuid uuid-Cafe_Bar connection.autoconnect no' "$work/nmcli-args")"
SAVED="Cafe:Bar" run_with_stdin '' connect Cafe:Bar
check "joining reuses the saved profile" no "$(has 'connection add' "$work/nmcli-args")"
check "and activates it" yes "$(has 'connection up uuid uuid-Cafe_Bar' "$work/nmcli-args")"
SAVED="Cafe:Bar" run forget Cafe:Bar
check "forget deletes it" yes "$(has 'connection delete uuid uuid-Cafe_Bar' "$work/nmcli-args")"
teardown

echo "set-password reads the key from stdin, never from argv"
setup
SAVED="Rehearsal" run_with_stdin 'n3w-s3cret' set-password Rehearsal
check "succeeds" 0 "$rc"
check "the helper's argv never holds the key" no "$(has 'n3w-s3cret' "$work/ctl-args")"
check "nmcli's argv never holds the key" no "$(has 'n3w-s3cret' "$work/nmcli-args")"
check "the key reaches nmcli on stdin" yes \
    "$(has 'set 802-11-wireless-security.psk n3w-s3cret' "$work/nmcli-stdin")"
check "and is saved" yes "$(has 'save persistent' "$work/nmcli-stdin")"
check "edits the saved profile" yes \
    "$(has 'connection edit uuid uuid-Rehearsal' "$work/nmcli-args")"
check "does not activate it" no "$(has 'connection up' "$work/nmcli-args")"
teardown

echo "set-password with no key or no saved network fails"
setup
SAVED="Rehearsal" run_with_stdin '' set-password Rehearsal
check "an empty key is refused" 2 "$rc"
SAVED="" run_with_stdin 'n3w-s3cret' set-password Rehearsal
check "an unknown network is refused" 1 "$rc"
check "nothing was edited" no "$(has 'connection edit' "$work/nmcli-args")"
teardown

echo "autoconnect maps to connection.autoconnect"
setup
SAVED="Rehearsal" run autoconnect Rehearsal off
check "off succeeds" 0 "$rc"
check "off sets no" yes \
    "$(has 'connection modify uuid uuid-Rehearsal connection.autoconnect no' "$work/nmcli-args")"
SAVED="Rehearsal" run autoconnect Rehearsal on
check "on sets yes" yes \
    "$(has 'connection modify uuid uuid-Rehearsal connection.autoconnect yes' "$work/nmcli-args")"
SAVED="Rehearsal" run autoconnect Rehearsal maybe
check "anything else is refused" 2 "$rc"
teardown

echo "status lists each saved network's autoconnect and the last one used"
setup
LISTING="$(printf 'uuid-Cafe:802-11-wireless:no:100\nuuid-The Studio:802-11-wireless:yes:900\nuuid-eth:802-3-ethernet:yes:950\nuuid-New:802-11-wireless:yes:0')" \
    run status
check "succeeds" 0 "$rc"
check "the saved list" yes \
    "$(has '"saved":[{"ssid":"The Studio","autoconnect":true},{"ssid":"Cafe","autoconnect":false},{"ssid":"New","autoconnect":true}]' "$work/stdout")"
check "last is the most recent activation" yes \
    "$(has '"last":"The Studio"' "$work/stdout")"
teardown

echo "status says when an activation is in flight"
setup
GENERAL_STATE='70 (connecting (getting IP configuration))' run status
check "connecting" yes "$(has '"connected":false,"connecting":true' "$work/stdout")"
teardown

echo "status with nothing saved"
setup
run status
check "an empty list and no last" yes \
    "$(has '"saved":[],"last":""' "$work/stdout")"
teardown

echo "connectivity is one HEAD request to the update host, bounded at 3 s"
setup
HTTP_CODE=404 run connectivity
check "any HTTP answer is internet" '{"internet":true}' "$(cat "$work/stdout")"
check "a HEAD request" yes "$(has '-I' "$work/curl-args")"
check "bounded at 3 s" yes "$(has '--max-time 3' "$work/curl-args")"
check "to the update host" yes \
    "$(has 'https://segno.aquiles.dev/updates/appliance' "$work/curl-args")"
check "over Wi-Fi, so a wired link cannot answer for it" yes \
    "$(has '--interface wlan0' "$work/curl-args")"
check "exactly one request" 1 "$(wc -l < "$work/curl-args" | tr -d ' ')"
teardown

echo "no answer is no internet"
setup
HTTP_CODE=000 CURL_RC=28 run connectivity
check "succeeds" 0 "$rc"
check "reports no internet" '{"internet":false}' "$(cat "$work/stdout")"
teardown

# The device the console manages (#1963): a USB Wi-Fi adapter when one is
# plugged in, else wlan0. The fake /sys/class/net holds what each case puts
# in it: a Wi-Fi device has a phy80211 link, and its device's subsystem is
# the bus it sits on.
wifi_dev() {
    mkdir -p "$work/sys/$1/device"
    : > "$work/sys/$1/phy80211"
    ln -s "../../../../bus/$2" "$work/sys/$1/device/subsystem"
}
wired_dev() {
    mkdir -p "$work/sys/$1/device"
    ln -s "../../../../bus/$2" "$work/sys/$1/device/subsystem"
}
args_line() { grep -n -F -- "$1" "$work/nmcli-args" | head -1 | cut -d: -f1; }

echo "the built-in radio alone is the device"
setup
wifi_dev wlan0 sdio
wired_dev eth0 platform
run iface
check "iface is wlan0" wlan0 "$(cat "$work/stdout")"
teardown

echo "no Wi-Fi device at all still answers wlan0"
setup
run iface
check "iface is wlan0" wlan0 "$(cat "$work/stdout")"
teardown

echo "a USB Wi-Fi adapter is the device while it is plugged in"
setup
wifi_dev wlan0 sdio
wifi_dev wlan1 usb
wired_dev eth0 platform
run iface
check "iface is wlan1" wlan1 "$(cat "$work/stdout")"
teardown

echo "a USB wired adapter is not a Wi-Fi device"
setup
wifi_dev wlan0 sdio
wired_dev eth1 usb
run iface
check "iface is wlan0" wlan0 "$(cat "$work/stdout")"
teardown

echo "two USB Wi-Fi adapters go by name"
setup
wifi_dev wlan0 sdio
wifi_dev wlan2 usb
wifi_dev wlan1 usb
run iface
check "iface is wlan1" wlan1 "$(cat "$work/stdout")"
teardown

echo "SEGNO_WIFI_IFACE still names the device by hand"
setup
wifi_dev wlan1 usb
SEGNO_WIFI_IFACE=wlan0 run iface
check "iface is wlan0" wlan0 "$(cat "$work/stdout")"
teardown

echo "a new network joined with an adapter plugged in is pinned to the adapter"
setup
wifi_dev wlan0 sdio
wifi_dev wlan1 usb
run_with_stdin 'goodpass' connect Rehearsal
check "the join succeeds" 0 "$rc"
check "the profile is made for wlan1" yes \
    "$(has 'connection add type wifi ifname wlan1 con-name Rehearsal' "$work/nmcli-args")"
check "not for wlan0" no "$(has 'ifname wlan0' "$work/nmcli-args")"
teardown

echo "a saved network pinned to wlan0 moves to the adapter when it is joined"
setup
wifi_dev wlan0 sdio
wifi_dev wlan1 usb
SAVED="Studio" STORED_PSK='right-key' run connect Studio
check "the join succeeds" 0 "$rc"
check "the stored profile is pinned to wlan1" yes \
    "$(has 'connection modify uuid uuid-Studio connection.interface-name wlan1' "$work/nmcli-args")"
check "before it goes up" yes \
    "$([ "$(args_line 'connection.interface-name wlan1')" -lt "$(args_line 'connection up')" ] 2>/dev/null && echo yes || echo no)"
teardown

echo "a key typed for a saved network pinned to wlan0 pins the stored profile first"
setup
wifi_dev wlan0 sdio
wifi_dev wlan1 usb
SAVED="Studio" STORED_PSK='old-key' GOOD_KEY='new-key' run_with_stdin 'new-key' connect Studio
check "the join succeeds" 0 "$rc"
check "the stored profile is pinned to wlan1 before the copy is made" yes \
    "$([ "$(args_line 'connection modify uuid uuid-Studio connection.interface-name wlan1')" -lt "$(args_line 'connection modify --temporary uuid uuid-Studio')" ] 2>/dev/null && echo yes || echo no)"
teardown

echo "activate pins a saved profile to the adapter; the retry brings it up there"
setup
wifi_dev wlan0 sdio
wifi_dev wlan1 usb
SAVED="Studio" STORED_PSK='right-key' run activate uuid-Studio 20
check "succeeds" 0 "$rc"
check "pinned to wlan1" yes \
    "$(has 'connection modify uuid uuid-Studio connection.interface-name wlan1' "$work/nmcli-args")"
check "and says so" yes "$(has 'pinned uuid-Studio to wlan1' "$work/stderr")"
check "pauses wlan1's autoconnect, not wlan0's" yes \
    "$(has 'device set wlan1 autoconnect no' "$work/nmcli-args")"
teardown

echo "the adapter pulled out: a profile pinned to it moves back to wlan0"
setup
wifi_dev wlan0 sdio
SAVED="Studio" STORED_PSK='right-key' PINNED=wlan1 run activate uuid-Studio 20
check "succeeds" 0 "$rc"
check "pinned to wlan0" yes \
    "$(has 'connection modify uuid uuid-Studio connection.interface-name wlan0' "$work/nmcli-args")"
teardown

echo "a profile already pinned to the device is not written"
setup
wifi_dev wlan0 sdio
wifi_dev wlan1 usb
SAVED="Studio" STORED_PSK='right-key' PINNED=wlan1 run activate uuid-Studio 20
check "succeeds" 0 "$rc"
check "nothing modified on the stored profile" no \
    "$(grep -F 'connection modify uuid uuid-Studio' "$work/nmcli-args" | grep -qF interface-name && echo yes || echo no)"
teardown

echo "status, scan and connectivity look at the adapter"
setup
wifi_dev wlan0 sdio
wifi_dev wlan1 usb
run status
check "status reads wlan1" yes "$(has 'GENERAL.STATE device show wlan1' "$work/nmcli-args")"
check "and never wlan0" no "$(has 'wlan0' "$work/nmcli-args")"
: > "$work/nmcli-args"
run scan
check "scan lists wlan1's networks" yes "$(has 'device wifi list ifname wlan1' "$work/nmcli-args")"
run connectivity
check "the internet check goes over wlan1" yes "$(has '--interface wlan1' "$work/curl-args")"
teardown

echo
echo "wifi-manage: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
