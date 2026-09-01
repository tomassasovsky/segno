#!/usr/bin/env bash
# Tests for `segno-update-ctl reboot` — the verb behind "Restart to apply" (#974).
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
# and it is what older systemd accepted — but the appliance ships systemd 259,
# where the positional form is gone and the string is silently dropped. A
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
# all that is needed.
setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/update-ctl-reboot-test.XXXXXX")
    mkdir -p "$work/bin"

    cat > "$work/bin/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > "$work/systemctl-args"
exit 0
STUB
    chmod +x "$work/bin/systemctl"
}

teardown() { rm -rf "$work"; }

run_reboot() {
    PATH="$work/bin:$PATH" \
        "$TEST_SHELL" "$SCRIPT" reboot 2>"$work/stderr"
}

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

echo "reboot: asks systemd for a tryboot reset"
setup
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
teardown

echo
echo "update-ctl reboot: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
