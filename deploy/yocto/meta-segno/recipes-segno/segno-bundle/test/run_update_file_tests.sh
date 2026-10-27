#!/usr/bin/env bash
# Tests for `segno-update-ctl install-file <path>` (#1270 Part 8): a bundle the
# app copied from a USB drive into the staging directory.
#
#   - a signed, compatible, newer bundle installs exactly as `install` does:
#     the same PROGRESS sequence ending on 100, the staged and pending
#     markers, no attempt marker left, and the staging copy removed;
#   - a version that is not newer, a bundle `rauc info` cannot verify, a
#     bundle for another compatible, and a path outside staging are each
#     refused with their JSON line and exit 4, with no markers and without
#     `rauc install` ever running; a refused copy in staging is removed too;
#   - a read-only /boot exits 3 before anything is checked or written.
#
# The appliance's /bin/sh is busybox ash; the script under test is run via
# TEST_SHELL (default `sh`) so CI can prove it under bash AND dash.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-update-ctl"
SHELL_UNDER_TEST="${TEST_SHELL:-sh}"

pass=0
fail=0

# Stubs: a rauc whose `info` answers from $work/info.json (or fails with
# RAUC_INFO=fail) and whose `install` logs that it ran and reports progress.
setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/update-file-test.XXXXXX")
    mkdir -p "$work/state" "$work/bin" "$work/tmp" "$work/staging" "$work/usb"
    echo "boot-a" > "$work/boot_id"
    echo "0.6.0" > "$work/state/build-version"
    printf '[system]\ncompatible=segno-rpi5\nbootloader=custom\n' \
        > "$work/system.conf"
    printf '{"compatible":"segno-rpi5","version":"0.7.0"}\n' > "$work/info.json"
    cat > "$work/bin/rauc" <<STUB
#!/bin/sh
case "\$1" in
    info)
        [ "\${RAUC_INFO:-ok}" = fail ] && { echo "signature invalid" >&2; exit 1; }
        cat "$work/info.json" ;;
    install)
        echo "\$2" > "$work/rauc-installed"
        echo "  0% Installing"
        echo " 50% Copying image"
        echo "100% Installing done." ;;
esac
exit 0
STUB
    chmod +x "$work/bin/rauc"
    printf 'bundle-bytes\n' > "$work/staging/segno-0.7.0.raucb"
}

teardown() { rm -rf "$work"; }

ctl_env() {
    export SEGNO_UPDATE_STAGING_DIR="$work/staging" \
        SEGNO_RAUC_SYSTEM_CONF="$work/system.conf" \
        SEGNO_VERSION_FILE="$work/state/build-version" \
        SEGNO_STAGED_FILE="$work/state/ota-staged-version" \
        SEGNO_STAGED_BOOT_ID_FILE="$work/state/ota-staged-boot-id" \
        SEGNO_BOOT_ID_FILE="$work/boot_id" \
        SEGNO_PENDING_FLAG="$work/state/update-pending" \
        SEGNO_UPDATE_ATTEMPT_FILE="$work/state/segno/update-attempt" \
        SEGNO_MOUNTS_FILE="$work/mounts" \
        TMPDIR="$work/tmp" \
        PATH="$work/bin:$PATH"
}

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

exists() { [ -e "$1" ] && echo yes || echo no; }
work_dirs() { find "$work/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }

# Asserts that nothing was written: no markers, rauc install never ran.
nothing_written() {
    check "rauc install never ran" no "$(exists "$work/rauc-installed")"
    check "stages nothing" no "$(exists "$work/state/ota-staged-version")"
    check "no pending flag" no "$(exists "$work/state/update-pending")"
    check "no attempt marker" no "$(exists "$work/state/segno/update-attempt")"
}

echo "a newer, verified bundle installs like an online update"
setup
ctl install-file "$work/staging/segno-0.7.0.raucb" >"$work/stdout" 2>"$work/stderr"; rc=$?
check "exits 0" 0 "$rc"
# Resolved (readlink -f), so compare it resolved too.
check "rauc installs the staged copy" \
    "$(cd "$work/staging" && pwd -P)/segno-0.7.0.raucb" \
    "$(cat "$work/rauc-installed" 2>/dev/null)"
check "PROGRESS sequence" "PROGRESS 0 PROGRESS 5 PROGRESS 5 PROGRESS 52 PROGRESS 100 PROGRESS 100" \
    "$(grep '^PROGRESS' "$work/stdout" | tr '\n' ' ' | sed 's/ $//')"
check "stages the version" "0.7.0" "$(cat "$work/state/ota-staged-version" 2>/dev/null)"
check "records the boot id" "boot-a" "$(cat "$work/state/ota-staged-boot-id" 2>/dev/null)"
check "sets the pending flag" yes "$(exists "$work/state/update-pending")"
check "removes the attempt marker" no "$(exists "$work/state/segno/update-attempt")"
check "removes the staging copy" no "$(exists "$work/staging/segno-0.7.0.raucb")"
check "removes its work dir" 0 "$(work_dirs)"
teardown

echo "a version that is not newer is refused"
setup
echo "0.7.0" > "$work/state/build-version"
out=$(ctl install-file "$work/staging/segno-0.7.0.raucb" 2>"$work/stderr"); rc=$?
check "exits 4" 4 "$rc"
check "says not-newer" '{"error":"not-newer","version":"0.7.0"}' "$(echo "$out" | grep '^{')"
nothing_written
check "removes the staging copy" no "$(exists "$work/staging/segno-0.7.0.raucb")"
teardown

echo "a bundle rauc cannot verify is refused"
setup
out=$(RAUC_INFO=fail ctl install-file "$work/staging/segno-0.7.0.raucb" 2>"$work/stderr"); rc=$?
check "exits 4" 4 "$rc"
check "says unverified" '{"error":"unverified"}' "$(echo "$out" | grep '^{')"
nothing_written
check "removes the staging copy" no "$(exists "$work/staging/segno-0.7.0.raucb")"
teardown

echo "a bundle for another compatible is refused as unverified"
setup
printf '{"compatible":"some-other-board","version":"0.7.0"}\n' > "$work/info.json"
out=$(ctl install-file "$work/staging/segno-0.7.0.raucb" 2>"$work/stderr"); rc=$?
check "exits 4" 4 "$rc"
check "says unverified" '{"error":"unverified"}' "$(echo "$out" | grep '^{')"
nothing_written
teardown

echo "a path outside staging is refused and left alone"
setup
printf 'bundle-bytes\n' > "$work/usb/segno-0.7.0.raucb"
out=$(ctl install-file "$work/usb/segno-0.7.0.raucb" 2>"$work/stderr"); rc=$?
check "exits 4" 4 "$rc"
check "says outside-staging" '{"error":"outside-staging"}' "$(echo "$out" | grep '^{')"
nothing_written
check "leaves the file outside staging" yes "$(exists "$work/usb/segno-0.7.0.raucb")"
out=$(ctl install-file "$work/staging/../usb/segno-0.7.0.raucb" 2>"$work/stderr"); rc=$?
check "a .. path is refused too" '{"error":"outside-staging"}' "$(echo "$out" | grep '^{')"
check "and still left alone" yes "$(exists "$work/usb/segno-0.7.0.raucb")"
out=$(ctl install-file 2>"$work/stderr"); rc=$?
check "no path at all exits 4" 4 "$rc"
teardown

echo "a read-only /boot exits 3 before anything is checked"
setup
printf '/dev/mmcblk0p1 /boot vfat ro,relatime 0 0\n' > "$work/mounts"
ctl install-file "$work/staging/segno-0.7.0.raucb" >/dev/null 2>"$work/stderr"; rc=$?
check "exits 3" 3 "$rc"
nothing_written
check "removes the staging copy" no "$(exists "$work/staging/segno-0.7.0.raucb")"
teardown

echo
echo "update-file ($SHELL_UNDER_TEST): $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
