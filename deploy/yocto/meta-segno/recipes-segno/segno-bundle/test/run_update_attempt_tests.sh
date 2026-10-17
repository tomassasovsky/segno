#!/usr/bin/env bash
# Tests for the install attempt marker of `segno-update-ctl install`, and its
# `attempt` / `clear-attempt` verbs (#1270 Part 7).
#
# An install cut off by a power loss or a stopped service used to leave no
# trace: nothing staged, nothing said, and the Updates page simply offered the
# build again. The helper now records the version it is installing at
# /data/segno/update-attempt before the download, and the app reads it back
# at the next start to show "Update paused". What is asserted here is the
# marker's whole life:
#
#   - a successful install removes it (the staged marker speaks instead);
#   - a failed install removes it (a failure is reported there and then);
#   - a SIGTERM during the download LEAVES it, removes the work dir, and stops
#     the download at once rather than after a 30-minute curl;
#   - `attempt` prints it as JSON, and `clear-attempt` forgets it.
#
# The appliance's /bin/sh is busybox ash; the script under test is run via
# TEST_SHELL (default `sh`) so CI can prove it under bash AND dash.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-update-ctl"
SHELL_UNDER_TEST="${TEST_SHELL:-sh}"

pass=0
fail=0

# Stubs: a rauc that "installs", and a curl that copies file:// URLs — or,
# with CURL_MODE=fail, fails the bundle download, or with CURL_MODE=hang,
# announces itself and blocks on the bundle so the test can kill the helper.
setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/update-attempt-test.XXXXXX")
    mkdir -p "$work/state" "$work/bin" "$work/tmp" "$work/channel/production"
    echo "boot-a" > "$work/boot_id"
    echo "0.6.0" > "$work/state/build-version"

    cat > "$work/bin/rauc" <<'STUB'
#!/bin/sh
echo "100% installing done."
exit 0
STUB
    chmod +x "$work/bin/rauc"

    cat > "$work/bin/curl" <<STUB
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out=\$2; shift 2 ;;
        --max-time) shift 2 ;;
        -*) shift ;;
        *) url=\$1; shift ;;
    esac
done
case "\$url" in
    *.raucb)
        case "\${CURL_MODE:-ok}" in
            fail) exit 22 ;;
            hang) echo \$\$ > "$work/curl-started"; exec sleep 30 ;;
        esac
        ;;
esac
cp "\${url#file://}" "\$out"
STUB
    chmod +x "$work/bin/curl"

    printf 'bundle-bytes\n' > "$work/channel/production/segno-0.7.0.raucb"
    bundle_sha=$(sha256sum "$work/channel/production/segno-0.7.0.raucb" | cut -d' ' -f1)
    cat > "$work/channel/production/manifest.json" <<JSON
{ "version": "0.7.0", "bundle": "segno-0.7.0.raucb",
  "sha256": "$bundle_sha", "channel": "production" }
JSON
}

teardown() { rm -rf "$work"; }

# Exports every path the helper reads, pointed into the fixture.
ctl_env() {
    export SEGNO_UPDATE_BASE="file://$work/channel" \
        SEGNO_CHANNEL_FILE="/nonexistent" \
        SEGNO_CHANNEL_OVERRIDE_FILE="/nonexistent" \
        SEGNO_VERSION_FILE="$work/state/build-version" \
        SEGNO_STAGED_FILE="$work/state/ota-staged-version" \
        SEGNO_STAGED_BOOT_ID_FILE="$work/state/ota-staged-boot-id" \
        SEGNO_BOOT_ID_FILE="$work/boot_id" \
        SEGNO_PENDING_FLAG="$work/state/update-pending" \
        SEGNO_UPDATE_ATTEMPT_FILE="$work/state/segno/update-attempt" \
        TMPDIR="$work/tmp" \
        PATH="$work/bin:$PATH"
}

# Runs the helper; "$@" is the verb and its args. A subshell that execs the
# helper, so a backgrounded call's $! is the helper itself.
ctl() ( ctl_env; exec "$SHELL_UNDER_TEST" "$CTL" "$@" )

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

attempt() { cat "$work/state/segno/update-attempt" 2>/dev/null; }
has_attempt() { [ -f "$work/state/segno/update-attempt" ] && echo yes || echo no; }
work_dirs() { find "$work/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }

echo "a successful install leaves no attempt marker"
setup
ctl install >"$work/stdout" 2>"$work/stderr"; rc=$?
check "exits 0" 0 "$rc"
check "stages the version" "0.7.0" "$(cat "$work/state/ota-staged-version" 2>/dev/null)"
check "removes the attempt marker" no "$(has_attempt)"
check "removes its work dir" 0 "$(work_dirs)"
check "ends on PROGRESS 100" "PROGRESS 100" "$(tail -n1 "$work/stdout")"
teardown

echo "a failed download removes the attempt marker"
setup
CURL_MODE=fail ctl install >/dev/null 2>"$work/stderr"; rc=$?
check "exits non-zero" 1 "$rc"
check "removes the attempt marker" no "$(has_attempt)"
check "stages nothing" no "$([ -f "$work/state/ota-staged-version" ] && echo yes || echo no)"
check "removes its work dir" 0 "$(work_dirs)"
teardown

echo "a failed rauc install removes the attempt marker"
setup
printf '#!/bin/sh\necho "rauc: refused"\nexit 1\n' > "$work/bin/rauc"
ctl install >/dev/null 2>"$work/stderr"; rc=$?
check "exits non-zero" 1 "$rc"
check "removes the attempt marker" no "$(has_attempt)"
check "stages nothing" no "$([ -f "$work/state/ota-staged-version" ] && echo yes || echo no)"
teardown

echo "nothing newer: no attempt is recorded at all"
setup
echo "0.7.0" > "$work/state/build-version"
ctl install >/dev/null 2>"$work/stderr"; rc=$?
check "exits non-zero" 1 "$rc"
check "writes no attempt marker" no "$(has_attempt)"
teardown

echo "SIGTERM during the download leaves the marker and sweeps the work dir"
setup
( ctl_env; export CURL_MODE=hang; exec "$SHELL_UNDER_TEST" "$CTL" install ) \
    >/dev/null 2>"$work/stderr" &
helper=$!
for _ in $(seq 1 100); do
    [ -f "$work/curl-started" ] && break
    sleep 0.05
done
check "the download started" yes "$([ -f "$work/curl-started" ] && echo yes || echo no)"
check "the attempt is recorded while it runs" "0.7.0" "$(attempt)"
started=$(date +%s)
kill -TERM "$helper"
wait "$helper"; rc=$?
elapsed=$(( $(date +%s) - started ))
check "exits 143" 143 "$rc"
check "stops at once, not after the download" yes \
    "$([ "$elapsed" -lt 10 ] && echo yes || echo no)"
check "leaves the attempt marker" "0.7.0" "$(attempt)"
check "removes its work dir" 0 "$(work_dirs)"
check "stages nothing" no "$([ -f "$work/state/ota-staged-version" ] && echo yes || echo no)"
curl_pid=$(cat "$work/curl-started")
for _ in $(seq 1 20); do
    kill -0 "$curl_pid" 2>/dev/null || break
    sleep 0.05
done
check "the download itself is stopped" no \
    "$(kill -0 "$curl_pid" 2>/dev/null && echo yes || echo no)"
# The cut-off install is what `attempt` reports to the app.
out=$(ctl attempt 2>"$work/stderr"); rc=$?
check "attempt exits 0" 0 "$rc"
check "attempt prints the version" '{"version":"0.7.0"}' "$out"
ctl clear-attempt 2>"$work/stderr"; rc=$?
check "clear-attempt exits 0" 0 "$rc"
check "clear-attempt forgets it" no "$(has_attempt)"
check "attempt then prints {}" '{}' "$(ctl attempt 2>/dev/null)"
teardown

echo "attempt with no marker"
setup
out=$(ctl attempt 2>"$work/stderr"); rc=$?
check "exits 0" 0 "$rc"
check "prints {}" '{}' "$out"
ctl clear-attempt 2>"$work/stderr"; rc=$?
check "clear-attempt with nothing to clear exits 0" 0 "$rc"
teardown

echo
echo "update-attempt ($SHELL_UNDER_TEST): $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
