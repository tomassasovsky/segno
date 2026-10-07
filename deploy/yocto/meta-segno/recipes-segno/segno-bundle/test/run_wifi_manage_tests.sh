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
    cat > "$work/bin/nmcli" <<STUB
#!/bin/sh
echo "\$@" >> "$work/nmcli-args"
case "\$*" in
    *"connection edit"*) cat >> "$work/nmcli-stdin" ;;
    *"UUID,TYPE,DEVICE connection show --active"*)
        [ -s "$work/active" ] && printf '%s:802-11-wireless:wlan0\n' "\$(cat "$work/active")"
        ;;
    *"UUID,TYPE,AUTOCONNECT,TIMESTAMP connection show"*)
        printf '%s\n' "\${LISTING:-}"
        ;;
    *"-g connection.autoconnect connection show"*)
        printf '%s\n' "\${PRIOR_AC:-yes}"
        ;;
    *"802-11-wireless.ssid connection show"*)
        name=\$(printf '%s' "\$*" | sed 's/.*uuid-//')
        case "\$*" in
            *-t*) printf '802-11-wireless.ssid:%s\n' "\$name" ;;
            *) printf '%s\n' "\$name" ;;
        esac
        ;;
    *"UUID,NAME,TYPE connection show"*)
        for n in \${SAVED:-}; do printf 'uuid-%s:%s:802-11-wireless\n' "\$n" "\$n"; done
        ;;
    *"connection show"*)
        for n in \${SAVED:-}; do printf '%s:802-11-wireless\n' "\$n"; done
        ;;
    *"connection up"*)
        # One radio: any activation drops the link that was up.
        : > "$work/active"
        case "\$*" in
            *"\${FAIL_UP:-<none>}"*)
                echo "Error: Connection activation failed: (7) Secrets were required, but not provided" >&2
                exit 4
                ;;
        esac
        target=\$(printf '%s' "\$*" | sed 's/.*connection up //; s/^uuid //; s/ passwd-file.*//')
        case "\$target" in uuid-*) ;; *) target="uuid-\$target" ;; esac
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
        printf 'uuid-%s' "$ACTIVE" > "$work/active"
    else
        : > "$work/active"
    fi
    printf '%s\n' "$*" >> "$work/ctl-args"
    printf '%s' "$stdin" | PATH="$work/bin:$PATH" SEGNO_JOURNALCTL="$work/bin/journalctl" \
        SAVED="${SAVED:-}" ACTIVE="${ACTIVE:-}" FAIL_UP="${FAIL_UP:-<none>}" \
        LISTING="${LISTING:-}" PRIOR_AC="${PRIOR_AC:-yes}" \
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
ACTIVE="The Studio" FAIL_UP="Rehearsal" run connect Rehearsal wrongpass
check "the join fails" 1 "$rc"
check "reactivates the previous connection" yes \
    "$(has 'connection up uuid uuid-The Studio' "$work/nmcli-args")"
check "prints restored" '{"restored":"The Studio"}' "$(cat "$work/stdout")"
check "still explains the failure" yes \
    "$(has 'segno-wifi-ctl:' "$work/stderr")"
check "the failed profile is removed" yes \
    "$(has 'connection delete id Rehearsal' "$work/nmcli-args")"
teardown

echo "a failed join with nothing active before restores nothing"
setup
FAIL_UP="Rehearsal" run connect Rehearsal wrongpass
check "the join fails" 1 "$rc"
check "prints nothing" "" "$(cat "$work/stdout")"
check "only the one activation" 1 \
    "$(grep -c 'connection up' "$work/nmcli-args" | tr -d ' ')"
teardown

echo "a successful join restores nothing"
setup
ACTIVE="The Studio" run connect Rehearsal goodpass
check "the join succeeds" 0 "$rc"
check "prints {}" '{}' "$(cat "$work/stdout")"
check "the previous network is not reactivated" no \
    "$(has 'connection up uuid uuid-The Studio' "$work/nmcli-args")"
teardown

echo "a wrong new password on a saved network keeps its autoconnect"
setup
SAVED="Rehearsal" ACTIVE="The Studio" FAIL_UP="uuid-Rehearsal" PRIOR_AC=no \
    run connect Rehearsal wrongpass
check "autoconnect goes back to what it was" yes \
    "$(has 'connection modify uuid uuid-Rehearsal connection.autoconnect no' "$work/nmcli-args")"
check "the saved profile is kept" no \
    "$(has 'connection delete' "$work/nmcli-args")"
teardown

echo "a wrong new password for the network that is up brings it back on its old key"
setup
SAVED="Studio" ACTIVE="Studio" FAIL_UP="passwd-file" run connect Studio wrongpass
check "the join fails" 1 "$rc"
check "reactivates it without the new key" yes \
    "$(grep -qxF 'connection up uuid uuid-Studio' <(sed 's/^--wait [0-9]* //' "$work/nmcli-args") && echo yes || echo no)"
check "prints restored" '{"restored":"Studio"}' "$(cat "$work/stdout")"
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
