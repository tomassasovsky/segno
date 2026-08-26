#!/usr/bin/env bash
# Tests for `segno-update-ctl reconcile-staged` and the boot-id record that
# feeds it (#458).
#
# The staged marker survives an A/B rollback unless something notices the
# tryboot did not take. RAUC's boot_status cannot be that something: the #307
# health gate rolls back a slot that boots FINE and simply never gets
# committed, and RAUC never calls such a slot bad. So staging records the
# current boot id next to the marker, and reconcile clears the marker when a
# reboot has happened (boot id differs) and the staged version is still not
# the one running. What is asserted here is that decision table — every
# kept/cleared cell — plus that BOTH staging paths (segno-update-ctl install
# and segno-ota-check) actually record the boot id: a marker staged without
# one looks stale and would be cleared before the applying reboot happens.
#
# The appliance's /bin/sh is busybox ash; the scripts under test are run via
# TEST_SHELL (default `sh`) so CI can prove them under bash AND dash.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-update-ctl"
OTA="$here/../files/segno-ota-check"
SHELL_UNDER_TEST="${TEST_SHELL:-sh}"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/reconcile-staged-test.XXXXXX")
    mkdir -p "$work/state" "$work/bin" "$work/channel/production"
    # The boot ids: what /proc reports now, and what was recorded at staging.
    echo "boot-b" > "$work/boot_id"
}

teardown() { rm -rf "$work"; }

run_reconcile() {
    SEGNO_VERSION_FILE="$work/state/build-version" \
    SEGNO_STAGED_FILE="$work/state/ota-staged-version" \
    SEGNO_STAGED_BOOT_ID_FILE="$work/state/ota-staged-boot-id" \
    SEGNO_BOOT_ID_FILE="$work/boot_id" \
        "$SHELL_UNDER_TEST" "$CTL" reconcile-staged 2>"$work/stderr"
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

marker() { cat "$work/state/ota-staged-version" 2>/dev/null; }
boot_record() { cat "$work/state/ota-staged-boot-id" 2>/dev/null; }
has_marker() { [ -f "$work/state/ota-staged-version" ] && echo yes || echo no; }
has_boot_record() { [ -f "$work/state/ota-staged-boot-id" ] && echo yes || echo no; }

# --- the cell #458 exists for -----------------------------------------------

echo "uncommitted tryboot rolled back: marker staged in a previous boot"
setup
echo "0.6.0" > "$work/state/build-version"
echo "0.7.0" > "$work/state/ota-staged-version"
echo "boot-a" > "$work/state/ota-staged-boot-id"   # staged before the reboot
echo "boot-b" > "$work/boot_id"                    # ...and we rebooted since
# No rauc anywhere on PATH on purpose: the health-gate rollback leaves the
# inactive slot NOT bad, and the decision must not need RAUC at all.
out=$(run_reconcile); rc=$?
check "exits 0" 0 "$rc"
check "clears the stale marker" no "$(has_marker)"
check "clears the boot-id record with it" no "$(has_boot_record)"
check "names the reason" '{"cleared":true,"reason":"tryboot-not-taken"}' "$out"
teardown

# --- kept: the tryboot took, or has not happened yet ------------------------

echo "same boot as staging: the applying reboot is still pending"
setup
echo "0.6.0" > "$work/state/build-version"
echo "0.7.0" > "$work/state/ota-staged-version"
echo "boot-b" > "$work/state/ota-staged-boot-id"
echo "boot-b" > "$work/boot_id"
out=$(run_reconcile); rc=$?
check "exits 0" 0 "$rc"
check "keeps the marker" yes "$(has_marker)"
check "keeps the boot-id record" yes "$(has_boot_record)"
check "reports not cleared" '{"cleared":false}' "$out"
teardown

echo "tryboot took: running the staged version"
setup
echo "0.7.0" > "$work/state/build-version"
echo "0.7.0" > "$work/state/ota-staged-version"
echo "boot-a" > "$work/state/ota-staged-boot-id"
echo "boot-b" > "$work/boot_id"
out=$(run_reconcile); rc=$?
check "exits 0" 0 "$rc"
check "clears the applied marker" no "$(has_marker)"
check "clears the boot-id record with it" no "$(has_boot_record)"
check "names the reason" '{"cleared":true,"reason":"already-running"}' "$out"
teardown

# --- the upgrade case: markers written by a pre-boot-id image ---------------

echo "legacy marker with no boot-id record"
setup
echo "0.6.0" > "$work/state/build-version"
echo "0.7.0" > "$work/state/ota-staged-version"
# No boot-id record at all: only an image older than this one writes that,
# and an older image's write is by definition from before this boot — the
# same "staged in a previous boot" rule clears it, no special case.
echo "boot-b" > "$work/boot_id"
out=$(run_reconcile); rc=$?
check "exits 0" 0 "$rc"
check "clears the legacy marker" no "$(has_marker)"
check "names the same reason" '{"cleared":true,"reason":"tryboot-not-taken"}' "$out"
teardown

# --- degenerate cells -------------------------------------------------------

echo "no marker at all"
setup
echo "0.6.0" > "$work/state/build-version"
# A boot-id record without its marker is residue an old image's clear left
# behind; reconcile sweeps it rather than letting it confuse a later stage.
echo "boot-a" > "$work/state/ota-staged-boot-id"
echo "boot-b" > "$work/boot_id"
out=$(run_reconcile); rc=$?
check "exits 0" 0 "$rc"
check "reports not cleared" '{"cleared":false}' "$out"
check "sweeps the orphaned boot-id record" no "$(has_boot_record)"
teardown

echo "empty (torn) marker"
setup
echo "0.6.0" > "$work/state/build-version"
: > "$work/state/ota-staged-version"
echo "boot-a" > "$work/state/ota-staged-boot-id"
echo "boot-b" > "$work/boot_id"
out=$(run_reconcile); rc=$?
check "exits 0" 0 "$rc"
check "clears the empty marker" no "$(has_marker)"
check "clears the boot-id record with it" no "$(has_boot_record)"
check "names the reason" '{"cleared":true,"reason":"empty"}' "$out"
teardown

echo "boot id unreadable: keep the marker rather than guess"
setup
echo "0.6.0" > "$work/state/build-version"
echo "0.7.0" > "$work/state/ota-staged-version"
echo "boot-a" > "$work/state/ota-staged-boot-id"
rm -f "$work/boot_id"
# Cannot tell "previous boot" from "this boot" with no current boot id (never
# the case on the appliance — /proc is always there). Clearing on a guess
# would drop a possibly still-pending stage; keeping is recoverable.
out=$(run_reconcile); rc=$?
check "exits 0" 0 "$rc"
check "keeps the marker" yes "$(has_marker)"
check "reports not cleared" '{"cleared":false}' "$out"
teardown

# --- both staging paths must record the boot id -----------------------------
#
# Load-bearing, not bookkeeping: a marker staged THIS boot with no (or a
# wrong) boot id next to it reads as "staged in a previous boot" and the very
# next reconcile clears it while its reboot is still pending.

# Stubs shared by the two staging tests: a rauc that "installs" (progress line
# included — install parses it) and a manifest served over file://.
write_stage_fixture() {
    cat > "$work/bin/rauc" <<STUB
#!/bin/sh
echo "100% installing done."
exit 0
STUB
    chmod +x "$work/bin/rauc"
    printf 'bundle-bytes\n' > "$work/channel/production/segno-0.7.0.raucb"
    bundle_sha=$(sha256sum "$work/channel/production/segno-0.7.0.raucb" | cut -d' ' -f1)
    cat > "$work/channel/production/manifest.json" <<JSON
{ "version": "0.7.0", "bundle": "segno-0.7.0.raucb",
  "sha256": "$bundle_sha", "channel": "production" }
JSON
    echo "0.6.0" > "$work/state/build-version"
}

echo "install records the staging boot id next to the marker"
setup
write_stage_fixture
SEGNO_UPDATE_BASE="file://$work/channel" \
SEGNO_CHANNEL_FILE="/nonexistent" \
SEGNO_CHANNEL_OVERRIDE_FILE="/nonexistent" \
SEGNO_VERSION_FILE="$work/state/build-version" \
SEGNO_STAGED_FILE="$work/state/ota-staged-version" \
SEGNO_STAGED_BOOT_ID_FILE="$work/state/ota-staged-boot-id" \
SEGNO_BOOT_ID_FILE="$work/boot_id" \
SEGNO_PENDING_FLAG="$work/state/update-pending" \
PATH="$work/bin:$PATH" \
    "$SHELL_UNDER_TEST" "$CTL" install >/dev/null 2>"$work/stderr"; rc=$?
check "stages" 0 "$rc"
check "writes the marker" "0.7.0" "$(marker)"
check "records this boot's id" "boot-b" "$(boot_record)"
# The freshly staged marker must survive the reconcile that follows it.
out=$(run_reconcile)
check "the marker survives an immediate reconcile" yes "$(has_marker)"
check "which reports not cleared" '{"cleared":false}' "$out"
teardown

echo "segno-ota-check records the staging boot id too"
setup
write_stage_fixture
SEGNO_UPDATE_BASE="file://$work/channel" \
SEGNO_CHANNEL_FILE="/nonexistent" \
SEGNO_CHANNEL_OVERRIDE_FILE="/nonexistent" \
SEGNO_VERSION_FILE="$work/state/build-version" \
SEGNO_STAGED_FILE="$work/state/ota-staged-version" \
SEGNO_STAGED_BOOT_ID_FILE="$work/state/ota-staged-boot-id" \
SEGNO_BOOT_ID_FILE="$work/boot_id" \
SEGNO_PENDING_FLAG="$work/state/update-pending" \
PATH="$work/bin:$PATH" \
    "$SHELL_UNDER_TEST" "$OTA" >/dev/null 2>"$work/stderr"; rc=$?
check "stages" 0 "$rc"
check "writes the marker" "0.7.0" "$(marker)"
check "records this boot's id" "boot-b" "$(boot_record)"
teardown

echo
echo "reconcile-staged ($SHELL_UNDER_TEST): $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
