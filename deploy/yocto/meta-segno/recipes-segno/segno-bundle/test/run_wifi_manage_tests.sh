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
    # Saved profiles come from SAVED (space-separated names). Their UUIDs are
    # uuid-<name> with ':' made '_', so, like real UUIDs, they carry no colon,
    # while the names may. A profile the helper adds is remembered by the UUID
    # it was given.
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
last=\$(eval "printf '%s' \"\\\${\$#}\"")
case "\$*" in
    *"connection edit"*) cat >> "$work/nmcli-stdin" ;;
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
        printf '%s\n' "\${STORED_PSK:-}"
        ;;
    *"-g connection.autoconnect connection show"*)
        printf '%s\n' "\${PRIOR_AC:-yes}"
        ;;
    *"-g connection.autoconnect-priority connection show"*) printf '0\n' ;;
    *"-g connection.id connection show"*|*"-g 802-11-wireless.ssid connection show"*)
        name_of "\$last"
        ;;
    *"connection up"*)
        case "\$*" in
            *passwd-file*) cp "\$last" "$work/passwd-file" ;;
        esac
        # One radio: any activation drops the link that was up.
        : > "$work/active"
        target=\$(printf '%s' "\$*" | sed 's/.*connection up //; s/^uuid //; s/ passwd-file.*//')
        case "\$* \$(name_of "\$target")" in
            *"\${FAIL_UP:-<none>}"*)
                echo "Error: Connection activation failed: (7) Secrets were required, but not provided" >&2
                exit 4
                ;;
        esac
        printf '%s' "\$target" > "$work/active"
        ;;
    *"WIFI radio"*) printf 'enabled\n' ;;
    *"GENERAL.STATE device show"*) printf 'GENERAL.STATE:30 (disconnected)\n' ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$work/bin/nmcli"
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
        STORED_PSK="${STORED_PSK:-}" \
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
check "prints restored" '{"restored":"The Studio"}' "$(cat "$work/stdout")"
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
check "prints nothing" "" "$(cat "$work/stdout")"
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
check "autoconnect goes back to what it was" yes \
    "$(has 'connection modify uuid uuid-Rehearsal connection.autoconnect no' "$work/nmcli-args")"
check "the saved profile is kept" no \
    "$(has 'connection delete' "$work/nmcli-args")"
teardown

echo "a wrong new password for the network that is up brings it back on its old key"
setup
SAVED="Studio" ACTIVE="Studio" FAIL_UP="passwd-file" run_with_stdin 'wrongpass' connect Studio
check "the join fails" 1 "$rc"
check "reactivates it without the new key" yes \
    "$(grep -qxF 'connection up uuid uuid-Studio' <(sed 's/^--wait [0-9]* //' "$work/nmcli-args") && echo yes || echo no)"
check "prints restored" '{"restored":"Studio"}' "$(cat "$work/stdout")"
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
check "the key is stored" yes \
    "$(has 'set 802-11-wireless-security.psk n3w-s3cret' "$work/nmcli-stdin")"
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

echo
echo "wifi-manage: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
