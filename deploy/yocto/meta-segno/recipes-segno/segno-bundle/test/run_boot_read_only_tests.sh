#!/usr/bin/env bash
# Tests for how `segno-update-ctl install` reports a read-only /boot (#1397).
#
# After a power cut the kernel's FAT driver can find a broken cluster chain
# on the tryboot selector partition and remount /boot read-only. RAUC then
# cannot commit a new slot. The Updates page used to call the result a failed
# download. The helper now exits 3 in that case, and the app maps exit 3 to
# its own message. What is asserted here:
#
#   - a read-only /boot is refused before the download, leaving no attempt
#     marker, no staged marker and no work dir behind;
#   - only a real `ro` option counts. The FAT mount carries
#     `errors=remount-ro` while it is still writable;
#   - the last mount-table entry for /boot decides, as in the kernel;
#   - a rauc failure stays exit 1;
#   - an unreadable mount table does not block an install.
#
# The appliance's /bin/sh is busybox ash; the script under test is run via
# TEST_SHELL (default `sh`) so CI can prove it under bash AND dash.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CTL="$here/../files/segno-update-ctl"
SHELL_UNDER_TEST="${TEST_SHELL:-sh}"

pass=0
fail=0

RW="/dev/nvme0n1p1 /boot vfat rw,noatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 0"
RO="/dev/nvme0n1p1 /boot vfat ro,noatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,errors=remount-ro 0 0"
DATA="/dev/nvme0n1p7 /data ext4 rw,noatime 0 0"

# Stubs: a rauc that "installs" (or, with RAUC_MODE=fail, fails), and a curl
# that copies file:// URLs and records that it fetched the bundle.
setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/boot-read-only-test.XXXXXX")
    mkdir -p "$work/state" "$work/bin" "$work/tmp" "$work/channel/production"
    echo "boot-a" > "$work/boot_id"
    echo "0.6.0" > "$work/state/build-version"
    printf '%s\n%s\n' "$DATA" "$RW" > "$work/mounts"

    cat > "$work/bin/rauc" <<STUB
#!/bin/sh
[ "\${RAUC_MODE:-ok}" = fail ] && { echo "rauc: refused"; exit 1; }
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
case "\$url" in *.raucb) : > "$work/bundle-fetched" ;; esac
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

# Runs `install` with every path the helper reads pointed into the fixture.
# MOUNTS overrides the mount table's path.
install() (
    export SEGNO_UPDATE_BASE="file://$work/channel" \
        SEGNO_CHANNEL_FILE="/nonexistent" \
        SEGNO_CHANNEL_OVERRIDE_FILE="/nonexistent" \
        SEGNO_VERSION_FILE="$work/state/build-version" \
        SEGNO_STAGED_FILE="$work/state/ota-staged-version" \
        SEGNO_STAGED_BOOT_ID_FILE="$work/state/ota-staged-boot-id" \
        SEGNO_BOOT_ID_FILE="$work/boot_id" \
        SEGNO_PENDING_FLAG="$work/state/update-pending" \
        SEGNO_UPDATE_ATTEMPT_FILE="$work/state/segno/update-attempt" \
        SEGNO_MOUNTS_FILE="${MOUNTS:-$work/mounts}" \
        TMPDIR="$work/tmp" \
        PATH="$work/bin:$PATH"
    exec "$SHELL_UNDER_TEST" "$CTL" install >"$work/stdout" 2>"$work/stderr"
)

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
says_read_only() {
    grep -q "the boot partition is read-only" "$work/stderr" && echo yes || echo no
}

echo "a read-only /boot is refused before the download"
setup
printf '%s\n%s\n' "$DATA" "$RO" > "$work/mounts"
install; rc=$?
check "exits 3" 3 "$rc"
check "says the boot partition is read-only" yes "$(says_read_only)"
check "fetches no bundle" no "$(exists "$work/bundle-fetched")"
check "prints no progress" "" "$(cat "$work/stdout")"
check "records no attempt" no "$(exists "$work/state/segno/update-attempt")"
check "stages nothing" no "$(exists "$work/state/ota-staged-version")"
check "leaves no work dir" 0 "$(work_dirs)"
teardown

echo "a writable /boot mounted with errors=remount-ro installs"
setup
install; rc=$?
check "exits 0" 0 "$rc"
check "stages the version" "0.7.0" "$(cat "$work/state/ota-staged-version" 2>/dev/null)"
check "does not say read-only" no "$(says_read_only)"
teardown

echo "the last entry for /boot decides"
setup
printf '%s\n%s\n' "$RW" "$RO" > "$work/mounts"
install; rc=$?
check "rw then ro exits 3" 3 "$rc"
printf '%s\n%s\n' "$RO" "$RW" > "$work/mounts"
install; rc=$?
check "ro then rw exits 0" 0 "$rc"
teardown

echo "another read-only mount does not count"
setup
printf '%s\n%s\n' "/dev/sda1 /run/media/segno/USB vfat ro,noatime 0 0" "$RW" > "$work/mounts"
install; rc=$?
check "exits 0" 0 "$rc"
teardown

echo "a rauc failure stays a plain failure"
setup
RAUC_MODE=fail install; rc=$?
check "exits 1" 1 "$rc"
check "does not say read-only" no "$(says_read_only)"
teardown

echo "an unreadable mount table does not block the install"
setup
MOUNTS="$work/missing" install; rc=$?
check "exits 0" 0 "$rc"
teardown

echo
echo "boot-read-only ($SHELL_UNDER_TEST): $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
