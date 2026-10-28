#!/usr/bin/env bash
# Tests for `segno-update-ctl reboot` — the verb behind "Restart to apply" (#974)
# — and for the check that `reboot` and `poweroff` share: neither resets while
# RAUC reports an install in progress (#1498), and `install-state` reports it.
#
# Staging an update arms the Raspberry Pi one-shot tryboot flag (RAUC's custom
# backend calls `vcmailbox 0x00038064 4 0 1`). That flag alone is not enough:
# the reset itself has to carry the tryboot argument, or the firmware comes
# back on the [all] boot_partition and the staged slot is never tried. Observed
# live on the Pi 5 console: three consecutive installs of experimental.106 each
# reported success, and slot B's ext4 superblock still showed mount count 0 —
# it had never been booted once.
#
# So what is asserted here is the shape of the reset, not just that we rebooted:
#
#   - the tryboot argument is passed at all, and
#   - it is passed as `--reboot-argument=`, NOT as a positional arg.
#
# The second half matters and is easy to regress. `systemctl reboot "0 tryboot"`
# is what the Raspberry Pi docs and the RAUC backend's own comments describe,
# and it is what older systemd accepted — but failed build 106 used systemd 259,
# where the positional form was dropped. The named option works on walnascar. A
# dropped argument is invisible: the unit reboots, comes up on the old build,
# and every layer above reports success.
#
# The appliance's /bin/sh is busybox ash; the script under test is run via
# TEST_SHELL (default `sh`) so CI can prove it under bash AND dash.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-update-ctl"
TEST_SHELL="${TEST_SHELL:-sh}"

pass=0
fail=0

# Stub systemctl so the test records the reset it was asked for instead of
# performing one. The script `exec`s systemctl, so a stub earlier on PATH is
# all that is needed. busctl is stubbed too: it answers RAUC's Operation
# property with whatever "$work/operation" holds (idle unless a test says
# otherwise), records its arguments, and fails when the file is missing, as
# busctl does when the daemon does not answer.
setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/update-ctl-reboot-test.XXXXXX")
    mkdir -p "$work/bin"
    # The verb branches on the staged marker: tryboot only when one exists.
    staged="$work/staged-version"
    echo idle > "$work/operation"

    cat > "$work/bin/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$work/systemctl-args"
exit 0
STUB
    chmod +x "$work/bin/systemctl"

    cat > "$work/bin/busctl" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$work/busctl-args"
[ -f "$work/operation" ] || exit 1
printf 's "%s"\n' "\$(cat "$work/operation")"
STUB
    chmod +x "$work/bin/busctl"
}

teardown() { rm -rf "$work"; }

run_verb() {
    PATH="$work/bin:$PATH" \
    SEGNO_STAGED_FILE="$staged" \
    SEGNO_TRYBOOT_REQUESTED_FILE="$work/tryboot-requested" \
        "$TEST_SHELL" "$SCRIPT" "$@" 2>"$work/stderr"
}

run_reboot() { run_verb reboot; }

check() {
    label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        [ -s "$work/stderr" ] && sed 's/^/       | /' "$work/stderr"
        fail=$((fail + 1))
    fi
}

echo "reboot with an update staged: asks systemd for a tryboot reset"
setup
echo "0.1.0-experimental.99" > "$staged"
run_reboot
args=$(tr '\n' ' ' < "$work/systemctl-args" | sed 's/ *$//')
check "invokes systemctl reboot" yes \
    "$(head -n1 "$work/systemctl-args" | grep -qx 'reboot' && echo yes || echo no)"
check "passes the tryboot argument" yes \
    "$(grep -q '0 tryboot' "$work/systemctl-args" && echo yes || echo no)"
# The whole point: systemd 259 dropped the positional form, so the argument
# must arrive attached to --reboot-argument= or it is silently discarded.
check "uses --reboot-argument= (not a positional arg)" yes \
    "$(grep -qx -- '--reboot-argument=0 tryboot' "$work/systemctl-args" && echo yes || echo no)"
check "full argv" "reboot --reboot-argument=0 tryboot" "$args"
check "records that the staged slot was asked for" yes \
    "$([ -e "$work/tryboot-requested" ] && echo yes || echo no)"
teardown

# The guard the tryboot argument makes necessary: passed unconditionally, a
# plain "just restart it" invocation would boot the OTHER slot (autoboot.txt
# statically maps [tryboot] to it), and mark-good would commit a healthy old
# build — a silent permanent downgrade. No staged update => plain reboot.
echo
echo "reboot with nothing staged: plain reboot, no tryboot argument"
setup
run_reboot
args=$(tr '\n' ' ' < "$work/systemctl-args" | sed 's/ *$//')
check "full argv is a bare reboot" "reboot" "$args"
check "says why" yes \
    "$(grep -q 'no update staged' "$work/stderr" && echo yes || echo no)"
teardown

echo
echo "reboot while RAUC is installing: refuses, resets nothing"
setup
echo "0.1.0-experimental.99" > "$staged"
echo installing > "$work/operation"
run_reboot
status=$?
check "exits 5" 5 "$status"
check "never calls systemctl" no \
    "$([ -e "$work/systemctl-args" ] && echo yes || echo no)"
check "does not record a tryboot request" no \
    "$([ -e "$work/tryboot-requested" ] && echo yes || echo no)"
check "keeps the staged marker" yes \
    "$([ -s "$staged" ] && echo yes || echo no)"
check "says why" yes \
    "$(grep -q 'RAUC is installing' "$work/stderr" && echo yes || echo no)"
check "asks RAUC's Installer for its Operation" \
    "get-property de.pengutronix.rauc / de.pengutronix.rauc.Installer Operation" \
    "$(tr '\n' ' ' < "$work/busctl-args" | sed 's/ *$//')"
teardown

echo
echo "poweroff while RAUC is installing: refuses, halts nothing"
setup
echo installing > "$work/operation"
run_verb poweroff
status=$?
check "exits 5" 5 "$status"
check "never calls systemctl" no \
    "$([ -e "$work/systemctl-args" ] && echo yes || echo no)"
check "says why" yes \
    "$(grep -q 'refusing to power off' "$work/stderr" && echo yes || echo no)"
teardown

echo
echo "poweroff while RAUC is idle: halts"
setup
run_verb poweroff
status=$?
check "exits 0" 0 "$status"
check "full argv" "start poweroff.target" \
    "$(tr '\n' ' ' < "$work/systemctl-args" | sed 's/ *$//')"
teardown

# A daemon or bus that does not answer is not writing a slot, and refusing
# then would leave no way to restart from the console at all.
echo
echo "reboot when RAUC's state cannot be read: reboots"
setup
rm -f "$work/operation"
run_reboot
status=$?
check "exits 0" 0 "$status"
check "full argv is a bare reboot" "reboot" \
    "$(tr '\n' ' ' < "$work/systemctl-args" | sed 's/ *$//')"
check "logs that it could not tell" yes \
    "$(grep -q "could not read RAUC's operation" "$work/stderr" && echo yes || echo no)"
teardown

echo
echo "install-state: reports RAUC's own operation"
setup
echo installing > "$work/operation"
check "installing" '{"installing":true}' "$(run_verb install-state)"
echo idle > "$work/operation"
check "idle" '{"installing":false}' "$(run_verb install-state)"
rm -f "$work/operation"
check "unreadable reads as not installing" '{"installing":false}' \
    "$(run_verb install-state)"
check "unreadable still exits 0" 0 "$(run_verb install-state >/dev/null; echo $?)"
teardown

echo
echo "the helper and the app agree on the installing exit status"
work=$(mktemp -d "${TMPDIR:-/tmp}/update-ctl-reboot-test.XXXXXX")
app_env="$here/../../../../../../lib/update/appliance/appliance_env.dart"
helper_code=$(sed -n 's/^EXIT_INSTALLING=\([0-9]*\)$/\1/p' "$SCRIPT")
app_code=$(sed -n 's/^const kUpdateInstallingExitCode = \([0-9]*\);$/\1/p' "$app_env")
check "the helper defines it" 5 "$helper_code"
check "the app maps the same status" "$helper_code" "$app_code"
teardown

echo
echo "update-ctl reboot: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
