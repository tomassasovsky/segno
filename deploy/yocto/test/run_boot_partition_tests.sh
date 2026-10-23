#!/usr/bin/env bash
# Wiring tests for the FAT boot partition's hardening (#1397).
#
# A power cut left a broken cluster chain in RAUC's status file on the FAT
# tryboot selector (/boot). The kernel then remounted /boot read-only and every
# install failed. Three pieces keep that from recurring, and breaking any one of
# them is silent until the next power cut:
#
#   - RAUC's data directory lives on the ext4 /data partition, and rauc.service
#     waits for /data and /boot and creates the directory, which RAUC does not.
#   - boot.mount pulls in the fsck unit for its own device, so the name must
#     be the systemd-escaped What= path, and the image must carry the fsck
#     wrapper and fsck.vfat. Without them systemd-fsck skips the check without
#     an error.
#   - the helper's read-only exit status matches the one the app maps.
#
# So this asserts the files statically.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root="$here/../../.."
layer="$here/../meta-segno"
SYSTEM_CONF="$layer/recipes-core/rauc/files/system.conf"
DROP_IN="$layer/recipes-core/rauc/files/10-segno-data.conf"
RAUC_CONF="$layer/recipes-core/rauc/rauc-conf.bbappend"
BOOT_MOUNT="$layer/recipes-segno/segno-bundle/files/boot.mount"
BUNDLE="$layer/recipes-segno/segno-bundle/segno-bundle.bb"
CTL="$layer/recipes-segno/segno-bundle/files/segno-update-ctl"
APP_ENV="$root/lib/update/appliance/appliance_env.dart"

pass=0
fail=0

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

yes_if() { "$@" && echo yes || echo no; }

# The value of KEY= in an INI-style file, comments skipped.
value() { grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2-; }

# systemd-escape --path: drop the leading /, escape '-' as \x2d, then '/' as '-'.
escape_path() {
    local p=${1#/}
    p=${p//-/\\x2d}
    printf '%s' "${p//\//-}"
}

echo "RAUC keeps its data on /data"
check "data-directory is /data/rauc" "/data/rauc" "$(value "$SYSTEM_CONF" data-directory)"
check "no deprecated statusfile= override" no \
    "$(yes_if grep -qE '^statusfile=' "$SYSTEM_CONF")"
check "no system.conf path is on /boot" no \
    "$(yes_if grep -qE '^[^#]*=/boot(/|$)' "$SYSTEM_CONF")"

echo "rauc.service waits for its mounts and creates the directory"
check "requires the /data/rauc and /boot mounts" "/data/rauc /boot" \
    "$(value "$DROP_IN" RequiresMountsFor)"
check "creates /data/rauc before starting" "/bin/mkdir -p /data/rauc" \
    "$(value "$DROP_IN" ExecStartPre)"
check "rauc-conf ships the drop-in" yes \
    "$(yes_if grep -qF 'file://10-segno-data.conf' "$RAUC_CONF")"
check "rauc-conf installs it into rauc.service.d" yes \
    "$(yes_if grep -qF '${D}${systemd_system_unitdir}/rauc.service.d/10-segno-data.conf' "$RAUC_CONF")"
check "rauc-conf packages it" yes \
    "$(yes_if grep -qF '${systemd_system_unitdir}/rauc.service.d/10-segno-data.conf"' "$RAUC_CONF")"

echo "boot.mount is checked before it mounts"
what=$(value "$BOOT_MOUNT" What)
fsck_unit="systemd-fsck@$(escape_path "$what").service"
check "the fsck unit name is the escaped What= path" \
    'systemd-fsck@dev-disk-by\x2dlabel-tryboot.service' "$fsck_unit"
if command -v systemd-escape >/dev/null 2>&1; then
    check "systemd-escape agrees" "$fsck_unit" \
        "systemd-fsck@$(systemd-escape --path "$what").service"
fi
check "Wants= the fsck unit" "$fsck_unit" "$(value "$BOOT_MOUNT" Wants)"
check "After= the fsck unit" "$fsck_unit" "$(value "$BOOT_MOUNT" After)"
check "does not Require it (a failed check still mounts)" no \
    "$(yes_if grep -qE '^Requires=' "$BOOT_MOUNT")"
# The RDEPENDS:${PN} block, from its first line to the closing quote.
rdepends=$(sed -n '/^RDEPENDS:\${PN} = "/,/"$/p' "$BUNDLE")
check "the image carries fsck.vfat" yes \
    "$(yes_if grep -qw dosfstools <<<"$rdepends")"
check "the image carries the fsck wrapper" yes \
    "$(yes_if grep -qw util-linux-fsck <<<"$rdepends")"

echo "the helper and the app agree on the read-only exit status"
helper_code=$(value "$CTL" EXIT_BOOT_READ_ONLY)
app_code=$(sed -n 's/^const kBootReadOnlyExitCode = \([0-9]*\);$/\1/p' "$APP_ENV")
check "the helper defines it" 3 "$helper_code"
check "the app maps the same status" "$helper_code" "$app_code"

echo
echo "boot-partition: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
