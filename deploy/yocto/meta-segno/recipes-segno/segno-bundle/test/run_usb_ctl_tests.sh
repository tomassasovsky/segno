#!/usr/bin/env bash
# Tests for `segno-usb-ctl`, the removable USB storage helper (#1177).
#
# What the kernel does with a mount needs a drive; what the helper ASKS for,
# what it writes for the app to read, and how it behaves when the OS says no
# do not. So mount/umount/udevadm/sync/dd are stubbed into a transcript, sysfs
# and /proc/uptime are directories and files under a temp dir, and the JSON
# the app will watch is asserted byte for byte. The parts with consequences:
#
#   * the mount option strings (a wrong vfat charset turns every accented file
#     name into `?`; a missing `flush` leaves a yanked FAT stick inconsistent);
#   * a read-only fallback that must not be mistaken for a healthy mount;
#   * the JSON appearing BEFORE the write probe, so a slow stick still shows
#     up promptly;
#   * detach exiting 0 after an eject, or the device unit lands in
#     `systemctl --failed` on every unplug;
#   * eject refusing, truthfully, when the kernel says busy.
#
# The appliance's /bin/sh is busybox ash; the helper is run via TEST_SHELL
# (default `sh`) so CI proves it under bash AND dash.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$here/../files/segno-usb-ctl"
FILES="$here/../files"
SHELL_UNDER_TEST="${TEST_SHELL:-sh}"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/usb-ctl-test.XXXXXX")
    mkdir -p "$work/bin" "$work/run" "$work/media" "$work/sys" "$work/dev" "$work/props"
    : > "$work/calls"
    printf '100.00 400.00\n' > "$work/uptime"
    # What dd moves the clock to (see the dd stub).
    printf '101.00 400.00\n' > "$work/uptime_after"
    # mount/umount exit codes are queues, one line per call, the last line
    # reused once exhausted; stderr text alongside.
    printf '0\n' > "$work/mount_rc"
    printf '0\n' > "$work/umount_rc"
    : > "$work/mount_err"
    : > "$work/umount_err"
    printf '0\n' > "$work/dd_rc"

    cat > "$work/bin/next" <<STUB
#!/bin/sh
file=\$1
line=\$(head -n1 "\$file")
remaining=\$(tail -n +2 "\$file")
[ -n "\$remaining" ] && printf '%s\n' "\$remaining" > "\$file"
printf '%s' "\$line"
STUB
    chmod +x "$work/bin/next"

    cat > "$work/bin/udevadm" <<STUB
#!/bin/sh
# udevadm info --query=property --name=/dev/<kname>: the properties file for
# that kernel name, verbatim.
dev=\$(printf '%s\n' "\$*" | sed -n 's/.*--name=[^ ]*\/\([^ ]*\).*/\1/p')
cat "$work/props/\$dev" 2>/dev/null
STUB
    chmod +x "$work/bin/udevadm"

    cat > "$work/bin/mount" <<STUB
#!/bin/sh
echo "mount \$*" >> "$work/calls"
rc=\$("$work/bin/next" "$work/mount_rc")
if [ "\$rc" != 0 ]; then cat "$work/mount_err" >&2; fi
exit "\$rc"
STUB
    chmod +x "$work/bin/mount"

    cat > "$work/bin/umount" <<STUB
#!/bin/sh
echo "umount \$*" >> "$work/calls"
rc=\$("$work/bin/next" "$work/umount_rc")
if [ "\$rc" != 0 ]; then cat "$work/umount_err" >&2; fi
exit "\$rc"
STUB
    chmod +x "$work/bin/umount"

    cat > "$work/bin/sync" <<STUB
#!/bin/sh
echo "sync" >> "$work/calls"
STUB
    chmod +x "$work/bin/sync"

    # dd runs between the two JSON writes, so it is also where the test
    # captures the first JSON and advances the clock (to uptime_after; 1.00 s
    # unless a test says otherwise).
    cat > "$work/bin/dd" <<STUB
#!/bin/sh
echo "dd \$*" >> "$work/calls"
cp "$work/run/volumes/"[0-9]*.json "$work/first.json" 2>/dev/null
cp "$work/uptime_after" "$work/uptime"
rc=\$("$work/bin/next" "$work/dd_rc")
if [ "\$rc" = 0 ]; then
    for a in "\$@"; do case "\$a" in of=*) : > "\${a#of=}" ;; esac; done
fi
exit "\$rc"
STUB
    chmod +x "$work/bin/dd"

    # The helper serialises its verbs with util-linux `flock 9`. Linux CI has
    # the real one; macOS does not, so stand in with the same system call:
    # flock(2) on the inherited descriptor locks the open file description
    # the helper shares, so the lock outlives this process exactly as the
    # real flock(1)'s does.
    if ! command -v flock >/dev/null 2>&1; then
        cat > "$work/bin/flock" <<'STUB'
#!/usr/bin/env perl
use Fcntl qw(:flock);
open(my $fh, '>&=', $ARGV[-1]) or die "flock: fd $ARGV[-1]: $!";
flock($fh, LOCK_EX) or die "flock: $!";
STUB
        chmod +x "$work/bin/flock"
    fi
}

teardown() { rm -rf "$work"; }

# props KNAME SIZE_SECTORS KEY=VALUE...
props() {
    kname=$1; sectors=$2; shift 2
    mkdir -p "$work/sys/$kname"
    echo "$sectors" > "$work/sys/$kname/size"
    : > "$work/props/$kname"
    for kv in "$@"; do echo "$kv" >> "$work/props/$kname"; done
}

run_ctl() {
    PATH="$work/bin:$PATH" \
    SEGNO_USB_RUN_DIR="$work/run" \
    SEGNO_USB_MEDIA_DIR="$work/media" \
    SEGNO_USB_SYSFS="$work/sys" \
    SEGNO_USB_DEV_DIR="$work/dev" \
    SEGNO_USB_UPTIME_FILE="$work/uptime" \
    SEGNO_USB_PROBE_BYTES="${PROBE_OVERRIDE:-16777216}" \
        "$SHELL_UNDER_TEST" "$SCRIPT" "$@" 2>"$work/stderr"
}

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "  ok   $label"
        pass=$((pass + 1))
    else
        echo "  FAIL $label"
        echo "       expected: $expected"
        echo "       actual:   $actual"
        [ -s "$work/stderr" ] && sed 's/^/       | /' "$work/stderr"
        fail=$((fail + 1))
    fi
}

volume() { cat "$work/run/volumes/$1.json" 2>/dev/null; }
calls() { cat "$work/calls"; }
has() { [ -e "$1" ] && echo yes || echo no; }

VFAT_PROPS="ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=vfat ID_FS_LABEL=SEGNO_USB ID_FS_LABEL_ENC=SEGNO\\x20USB ID_FS_UUID=1A2B-3C4D ID_SERIAL=SanDisk_Ultra_4C530001"
# shellcheck disable=SC2086
vfat_props() { props sda1 62521344 $VFAT_PROPS; }

echo "attach: a vfat partition"
setup
vfat_props
run_ctl attach sda1; rc=$?
check "exits 0" 0 "$rc"
check "the JSON written BEFORE the probe has no rate yet" \
    '{"generation":1,"kname":"sda1","fingerprint":"SanDisk_Ultra_4C530001-1A2B-3C4D","label":"SEGNO USB","fsType":"vfat","mountPoint":"'"$work"'/media/1-SEGNO_USB","sizeBytes":32010928128,"status":"mounted","readOnly":false,"writeBytesPerSecond":null,"failureReason":null,"eject":null}' \
    "$(cat "$work/first.json")"
check "the final JSON carries the measured rate (16 MiB in 1.00 s)" \
    '{"generation":1,"kname":"sda1","fingerprint":"SanDisk_Ultra_4C530001-1A2B-3C4D","label":"SEGNO USB","fsType":"vfat","mountPoint":"'"$work"'/media/1-SEGNO_USB","sizeBytes":32010928128,"status":"mounted","readOnly":false,"writeBytesPerSecond":16777216,"failureReason":null,"eject":null}' \
    "$(volume 1)"
check "mounts with the vfat option string" \
    "mount -t vfat -o rw,nosuid,nodev,noatime,flush,utf8=1,uid=0,gid=0,fmask=0022,dmask=0022 $work/dev/sda1 $work/media/1-SEGNO_USB" \
    "$(grep '^mount' "$work/calls")"
check "probes with a fsync'd 16 MiB write into the mount point" \
    "dd if=/dev/zero of=$work/media/1-SEGNO_USB/.segno-probe bs=1048576 count=16 conv=fsync" \
    "$(grep '^dd' "$work/calls")"
check "the probe file is removed" no "$(has "$work/media/1-SEGNO_USB/.segno-probe")"
check "the mount point exists" yes "$(has "$work/media/1-SEGNO_USB")"
check "nothing but <gen>.json is left under volumes/" "1.json" "$(ls -A "$work/run/volumes")"
check "status prints the volume array" "[$(volume 1)]" "$(run_ctl status)"
teardown

echo "attach: labels are sanitised for the mount point, never for the JSON"
setup
vfat_props
run_ctl attach sda1
props sdb1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=exfat \
    'ID_FS_LABEL=Gigs/2026_ñ' 'ID_FS_LABEL_ENC=Gigs/2026\x20\xc3\xb1' ID_FS_UUID=ABCD-EF01 ID_SERIAL=Kingston_1
run_ctl attach sdb1
props sdc1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=exfat \
    ID_FS_UUID=0000-0001 ID_SERIAL=NoName_2
run_ctl attach sdc1
check "a slash, a space and a two-byte character each become underscores" \
    "$work/media/2-Gigs_2026___" "$(volume 2 | sed -n 's/.*"mountPoint":"\([^"]*\)".*/\1/p')"
check "the JSON label keeps the decoded text" 'Gigs/2026 ñ' \
    "$(volume 2 | sed -n 's/.*"label":"\([^"]*\)".*/\1/p')"
check "an empty label falls back to the kernel name" \
    "$work/media/3-sdc1" "$(volume 3 | sed -n 's/.*"mountPoint":"\([^"]*\)".*/\1/p')"
check "exfat uses its own option string" \
    "mount -t exfat -o rw,nosuid,nodev,noatime,uid=0,gid=0,fmask=0022,dmask=0022 $work/dev/sdb1 $work/media/2-Gigs_2026___" \
    "$(grep '^mount.*sdb1' "$work/calls")"
teardown

echo "attach: generations are per boot and never reused"
setup
vfat_props
run_ctl attach sda1
run_ctl detach sda1
run_ctl attach sda1
check "the same fingerprint replugged is generation 2" 2 \
    "$(volume 2 | sed -n 's/.*"generation":\([0-9]*\).*/\1/p')"
check "generation 1 is gone" no "$(has "$work/run/volumes/1.json")"
teardown

echo "attach: ntfs goes through ntfs3"
setup
props sda1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=ntfs \
    ID_FS_LABEL=WIN ID_FS_LABEL_ENC=WIN ID_FS_UUID=0123456789ABCDEF ID_SERIAL=WD_1
run_ctl attach sda1
check "ntfs mounts with the ntfs3 driver and its option string" \
    "mount -t ntfs3 -o rw,nosuid,nodev,noatime,uid=0,gid=0 $work/dev/sda1 $work/media/1-WIN" \
    "$(grep '^mount' "$work/calls")"
check "ext4 mounts with rw,nosuid,nodev,noatime" "mount -t ext4 -o rw,nosuid,nodev,noatime $work/dev/sdb1 $work/media/2-sdb1" \
    "$(props sdb1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=ext4 ID_FS_UUID=u ID_SERIAL=s; run_ctl attach sdb1; grep '^mount.*sdb1' "$work/calls")"
teardown

echo "attach: a read-write mount that fails is retried read-only once"
setup
vfat_props
printf '1\n0\n' > "$work/mount_rc"
printf 'mount: /dev/sda1: WARNING: source write-protected, mounted read-only.\nsecond line\n' > "$work/mount_err"
run_ctl attach sda1; rc=$?
check "exits 0" 0 "$rc"
check "the retry drops rw and flush" \
    "mount -t vfat -o ro,nosuid,nodev,noatime,utf8=1,uid=0,gid=0,fmask=0022,dmask=0022 $work/dev/sda1 $work/media/1-SEGNO_USB" \
    "$(grep '^mount' "$work/calls" | sed -n 2p)"
check "status is readOnly, readOnly true, the first stderr line kept, no probe" \
    '{"generation":1,"kname":"sda1","fingerprint":"SanDisk_Ultra_4C530001-1A2B-3C4D","label":"SEGNO USB","fsType":"vfat","mountPoint":"'"$work"'/media/1-SEGNO_USB","sizeBytes":32010928128,"status":"readOnly","readOnly":true,"writeBytesPerSecond":null,"failureReason":"mount: /dev/sda1: WARNING: source write-protected, mounted read-only.","eject":null}' \
    "$(volume 1)"
check "no probe ran on a read-only volume" "" "$(grep '^dd' "$work/calls")"
teardown

echo "attach: both mounts failing records mountFailed"
setup
vfat_props
printf '32\n' > "$work/mount_rc"
printf 'mount: wrong fs type, bad option, bad superblock on /dev/sda1\n' > "$work/mount_err"
run_ctl attach sda1; rc=$?
check "exits 0" 0 "$rc"
check "two mount attempts, then nothing" 2 "$(grep -c '^mount' "$work/calls")"
check "mountFailed with mount's first stderr line and no mount point" \
    '{"generation":1,"kname":"sda1","fingerprint":"SanDisk_Ultra_4C530001-1A2B-3C4D","label":"SEGNO USB","fsType":"vfat","mountPoint":null,"sizeBytes":32010928128,"status":"mounted","readOnly":false,"writeBytesPerSecond":null,"failureReason":"mount: wrong fs type, bad option, bad superblock on /dev/sda1","eject":null}' \
    "$(volume 1 | sed 's/"status":"mountFailed"/"status":"mounted"/')"
check "the status really is mountFailed" mountFailed "$(volume 1 | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
check "the empty mount point directory is removed" no "$(has "$work/media/1-SEGNO_USB")"
teardown

echo "attach: unsupported and blank media never reach mount"
setup
props sda1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=hfsplus \
    ID_FS_LABEL=Mac ID_FS_LABEL_ENC=Mac ID_FS_UUID=m ID_SERIAL=Apple_1
run_ctl attach sda1
props sdb1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=crypto ID_FS_TYPE=crypto_LUKS \
    ID_FS_UUID=c ID_SERIAL=Vault_1
run_ctl attach sdb1
props sdc 2000 ID_BUS=usb DEVTYPE=disk ID_SERIAL=Blank_1
run_ctl attach sdc
check "hfsplus is unsupported with its type" \
    '{"generation":1,"kname":"sda1","fingerprint":"Apple_1-m","label":"Mac","fsType":"hfsplus","mountPoint":null,"sizeBytes":512000,"status":"unsupported","readOnly":false,"writeBytesPerSecond":null,"failureReason":null,"eject":null}' \
    "$(volume 1)"
check "LUKS is unsupported with its type" crypto_LUKS "$(volume 2 | sed -n 's/.*"fsType":"\([^"]*\)".*/\1/p')"
check "a blank disk records fsType none" none "$(volume 3 | sed -n 's/.*"fsType":"\([^"]*\)".*/\1/p')"
check "a blank disk has an empty label and a bare serial fingerprint" '"label":"","fsType":"none"' \
    "$(volume 3 | sed -n 's/.*\("label":"[^"]*","fsType":"[^"]*"\).*/\1/p')"
check "mount was never called" "" "$(grep '^mount' "$work/calls")"
teardown

echo "detach: a mounted volume"
setup
vfat_props
run_ctl attach sda1
: > "$work/calls"
run_ctl detach sda1; rc=$?
check "exits 0" 0 "$rc"
check "sync, then one non-lazy umount" "sync
umount $work/media/1-SEGNO_USB" "$(calls)"
check "the mount point is removed" no "$(has "$work/media/1-SEGNO_USB")"
check "the JSON is deleted" no "$(has "$work/run/volumes/1.json")"
teardown

echo "detach: the device is already gone"
setup
vfat_props
run_ctl attach sda1
: > "$work/calls"
printf '32\n0\n' > "$work/umount_rc"
run_ctl detach sda1; rc=$?
check "exits 0" 0 "$rc"
check "a lazy umount follows the failed one" "sync
umount $work/media/1-SEGNO_USB
umount -l $work/media/1-SEGNO_USB" "$(calls)"
check "the JSON is deleted" no "$(has "$work/run/volumes/1.json")"
teardown

echo "detach: an ejected volume being unplugged is not a failure"
setup
vfat_props
run_ctl attach sda1
printf '{"generation":1,"request":"r1"}' > "$work/run/requests/r1.json"
run_ctl serve-requests
: > "$work/calls"
printf '32\n' > "$work/umount_rc"
printf 'umount: %s/media/1-SEGNO_USB: not mounted.\n' "$work" > "$work/umount_err"
run_ctl detach sda1; rc=$?
check "exits 0 although both umounts fail" 0 "$rc"
check "the mount point is removed" no "$(has "$work/media/1-SEGNO_USB")"
check "the JSON is deleted" no "$(has "$work/run/volumes/1.json")"
check "detach of an unknown device also exits 0" 0 "$(run_ctl detach sdz9; echo $?)"
teardown

echo "serve-requests: a successful eject"
setup
vfat_props
run_ctl attach sda1
: > "$work/calls"
printf '{"generation":1,"request":"7f3a"}' > "$work/run/requests/7f3a.json"
run_ctl serve-requests; rc=$?
check "exits 0" 0 "$rc"
check "sync, then a NON-lazy umount" "sync
umount $work/media/1-SEGNO_USB" "$(calls)"
check "the JSON reads ejected with the outcome" \
    '{"generation":1,"kname":"sda1","fingerprint":"SanDisk_Ultra_4C530001-1A2B-3C4D","label":"SEGNO USB","fsType":"vfat","mountPoint":"'"$work"'/media/1-SEGNO_USB","sizeBytes":32010928128,"status":"ejected","readOnly":false,"writeBytesPerSecond":16777216,"failureReason":null,"eject":{"request":"7f3a","ok":true,"reason":null}}' \
    "$(volume 1)"
check "the request is gone" "" "$(ls -A "$work/run/requests")"
teardown

echo "serve-requests: the kernel says busy"
setup
vfat_props
run_ctl attach sda1
printf '32\n' > "$work/umount_rc"
printf 'umount: %s/media/1-SEGNO_USB: target is busy.\n' "$work" > "$work/umount_err"
printf '{"generation":1,"request":"b1"}' > "$work/run/requests/b1.json"
run_ctl serve-requests; rc=$?
check "exits 0 (the refusal is data, not a unit failure)" 0 "$rc"
check "status stays mounted, eject records busy" \
    '"status":"mounted","readOnly":false,"writeBytesPerSecond":16777216,"failureReason":null,"eject":{"request":"b1","ok":false,"reason":"busy"}}' \
    "$(volume 1 | sed -n 's/.*\("status".*\)/\1/p')"
check "the mount point still exists" yes "$(has "$work/media/1-SEGNO_USB")"
check "the request is gone" "" "$(ls -A "$work/run/requests")"
printf 'umount: something else went wrong\n' > "$work/umount_err"
printf '{"generation":1,"request":"b2"}' > "$work/run/requests/b2.json"
run_ctl serve-requests
check "any other umount failure records error" '"ok":false,"reason":"error"' \
    "$(volume 1 | sed -n 's/.*\("ok":[a-z]*,"reason":[^}]*\)}.*/\1/p')"
teardown

echo "serve-requests: unknown generations and dotfiles"
setup
vfat_props
run_ctl attach sda1
: > "$work/calls"
printf '{"generation":9,"request":"old"}' > "$work/run/requests/old.json"
printf '{"generation":1,"request":"tmp"}' > "$work/run/requests/.tmp.json.tmp"
run_ctl serve-requests; rc=$?
check "exits 0" 0 "$rc"
check "an unknown generation is deleted and ignored" no "$(has "$work/run/requests/old.json")"
check "nothing was unmounted for it" "" "$(calls)"
check "the dotfile is neither served nor deleted" yes "$(has "$work/run/requests/.tmp.json.tmp")"
check "the volume is untouched" '"status":"mounted"' "$(volume 1 | sed -n 's/.*\("status":"[a-zA-Z]*"\).*/\1/p')"
teardown

echo "attach: concurrent attaches never share a generation"
# systemd starts one mount unit per partition in parallel. A slow udevadm
# lines the attaches up on the generation counter; without the lock some of
# these rounds end with one record overwriting the other.
setup
cat > "$work/bin/udevadm" <<STUB
#!/bin/sh
sleep 0.2
dev=\$(printf '%s\n' "\$*" | sed -n 's/.*--name=[^ ]*\/\([^ ]*\).*/\1/p')
cat "$work/props/\$dev" 2>/dev/null
STUB
props sda1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=vfat \
    ID_FS_LABEL=ONE ID_FS_LABEL_ENC=ONE ID_FS_UUID=1 ID_SERIAL=Dual_1
props sda2 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=vfat \
    ID_FS_LABEL=TWO ID_FS_LABEL_ENC=TWO ID_FS_UUID=2 ID_SERIAL=Dual_1
props sda3 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=vfat \
    ID_FS_LABEL=THREE ID_FS_LABEL_ENC=THREE ID_FS_UUID=3 ID_SERIAL=Dual_1
bad_rounds=0
for round in 1 2 3 4 5 6 7 8 9 10; do
    rm -rf "$work/run" "$work/media"; mkdir -p "$work/run" "$work/media"
    run_ctl attach sda1 & first=$!
    run_ctl attach sda2 & second=$!
    run_ctl attach sda3 & third=$!
    wait "$first" "$second" "$third"
    records=$(ls "$work/run/volumes" | tr '\n' ' ')
    knames=$(cat "$work/run/volumes/"*.json | sed -n 's/.*"kname":"\([^"]*\)".*/\1/p' | sort | tr '\n' ' ')
    if [ "$records" != "1.json 2.json 3.json " ] || [ "$knames" != "sda1 sda2 sda3 " ]; then
        bad_rounds=$((bad_rounds + 1))
        echo "       round $round: records [$records] knames [$knames]"
    fi
done
check "ten rounds of three parallel attaches: generations 1, 2 and 3, one record each" 0 "$bad_rounds"
teardown

echo "probe: uptime fractions with a leading zero are decimal, not octal"
# /proc/uptime prints two fraction digits; 08 and 09 are not octal numbers,
# so read as written they are arithmetic errors, and the rate comes out null
# or wildly wrong.
setup
vfat_props
printf '100.08 400.00\n' > "$work/uptime"
printf '101.09 400.00\n' > "$work/uptime_after"
run_ctl attach sda1
check "100.08 -> 101.09 is 101 cs: 16 MiB x 100 / 101" "$((16777216 * 100 / 101))" \
    "$(volume 1 | sed -n 's/.*"writeBytesPerSecond":\([a-z0-9]*\).*/\1/p')"
teardown
setup
vfat_props
printf '100.50 400.00\n' > "$work/uptime"
printf '101.09 400.00\n' > "$work/uptime_after"
run_ctl attach sda1
check "100.50 -> 101.09 is 59 cs: 16 MiB x 100 / 59" "$((16777216 * 100 / 59))" \
    "$(volume 1 | sed -n 's/.*"writeBytesPerSecond":\([a-z0-9]*\).*/\1/p')"
teardown

echo "attach: labels that are not UTF-8, or carry control bytes, stay valid JSON"
# A FAT label written on Windows is in an OEM codepage; udev escapes the
# bytes that are not UTF-8 (`MÚSICA` with Ú as 0xE9). Decoding those back to
# raw bytes made the record invalid UTF-8, and the app dropped the volume.
setup
props sda1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=vfat \
    ID_FS_LABEL=M_SICA 'ID_FS_LABEL_ENC=M\xe9SICA' ID_FS_UUID=1 ID_SERIAL=Win_1
run_ctl attach sda1
props sdb1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=vfat \
    ID_FS_LABEL=A_B 'ID_FS_LABEL_ENC=A\x01B\x09C\x0dD' ID_FS_UUID=2 ID_SERIAL=Ctl_1
run_ctl attach sdb1
props sdc1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=vfat \
    ID_FS_LABEL=_ 'ID_FS_LABEL_ENC=\xc3\xb1\xc3\xe2\x82\xac\xf0\x9f\x8e\xb8\xc0\xaf' ID_FS_UUID=3 ID_SERIAL=Mix_1
run_ctl attach sdc1
# Strict: the bytes must decode as UTF-8 and the text must parse as JSON.
label_of() {
    python3 -c 'import json, sys; print(json.loads(open(sys.argv[1], "rb").read().decode("utf-8"))["label"], end="")' \
        "$work/run/volumes/$1.json" 2>&1
}
check "0xE9 alone is not UTF-8: it stays as \\xe9 text, and the record parses" 'M\xe9SICA' "$(label_of 1)"
check "control bytes are written as \\u00XX escapes" '"label":"A\u0001B\u0009C\u000dD"' \
    "$(volume 2 | sed -n 's/.*\("label":"[^"]*"\).*/\1/p')"
check "and parse back to the bytes" "$(printf 'A\001B\tC\rD')" "$(label_of 2)"
check "valid sequences decode, invalid bytes between them do not (ñ, lone C3, €, 🎸, overlong C0 AF)" \
    'ñ\xc3€🎸\xc0\xaf' "$(label_of 3)"
teardown

echo "serve-requests: an eject leaves every other byte of the record alone"
setup
props sda1 1000 ID_BUS=usb DEVTYPE=partition ID_FS_USAGE=filesystem ID_FS_TYPE=vfat \
    ID_FS_LABEL=TAB 'ID_FS_LABEL_ENC=A\x09B\x0dC\x22D\x5cE' ID_FS_UUID=1 ID_SERIAL=Tab_1
run_ctl attach sda1
before=$(volume 1)
printf '{"generation":1,"request":"e1"}' > "$work/run/requests/e1.json"
run_ctl serve-requests
check "only status and eject change" \
    "$(printf '%s' "$before" | sed 's/"status":"mounted"/"status":"ejected"/; s/"eject":null}/"eject":{"request":"e1","ok":true,"reason":null}}/')" \
    "$(volume 1)"
check "the label still reads TAB and CR as escapes" '"label":"A\u0009B\u000dC\"D\\E"' \
    "$(volume 1 | sed -n 's/.*\("label":"A[^,]*"\),"fsType".*/\1/p')"
printf '{"generation":1,"request":"x/y"}' > "$work/run/requests/bad.json"
run_ctl serve-requests
check "a request id outside [A-Za-z0-9._-] is dropped unserved" '"request":"e1"' \
    "$(volume 1 | sed -n 's/.*\("request":"[^"]*"\).*/\1/p')"
check "and deleted" no "$(has "$work/run/requests/bad.json")"
teardown

echo "probe: failures are null, never errors"
setup
vfat_props
printf '1\n' > "$work/dd_rc"
run_ctl attach sda1; rc=$?
check "attach still exits 0" 0 "$rc"
check "a failed probe records null and the volume stays mounted" \
    '"status":"mounted","readOnly":false,"writeBytesPerSecond":null' \
    "$(volume 1 | sed -n 's/.*\("status":"[a-zA-Z]*","readOnly":[a-z]*,"writeBytesPerSecond":[a-z0-9]*\).*/\1/p')"
check "the probe file is not left behind" no "$(has "$work/media/1-SEGNO_USB/.segno-probe")"
mkdir -p "$work/media/x"
printf '0\n' > "$work/dd_rc"
printf '100.00 1\n' > "$work/uptime"
check "probe on its own prints the rate" 16777216 "$(run_ctl probe "$work/media/x")"
PROBE_OVERRIDE=1000 check "a non-MiB size is written as one block" \
    "dd if=/dev/zero of=$work/media/x/.segno-probe bs=1000 count=1 conv=fsync" \
    "$(: > "$work/calls"; PROBE_OVERRIDE=1000 run_ctl probe "$work/media/x" >/dev/null; grep '^dd' "$work/calls")"
teardown

echo "units: the mount namespace stays shared with the app"
setup
check "no unit narrows the mount namespace" "" \
    "$(grep -l -E '^(PrivateMounts|ProtectSystem|PrivateTmp|MountFlags)=' "$FILES"/segno-usb-*.service "$FILES"/segno-usb-*.path "$FILES/segno.service" 2>/dev/null)"
check "segno.service says why" yes \
    "$(grep -q 'mount namespace' "$FILES/segno.service" && echo yes || echo no)"
check "the mount template is bound to its device unit" yes \
    "$(grep -q '^BindsTo=dev-%i.device' "$FILES/segno-usb-mount@.service" && echo yes || echo no)"
check "the eject path unit queues on request files, not on any file (a dotfile cannot wedge it)" \
    "PathExistsGlob=/run/segno/usb/requests/*.json" \
    "$(grep -E '^(PathExistsGlob|DirectoryNotEmpty|PathExists|PathChanged|PathModified)=' "$FILES/segno-usb-eject.path")"
check "the blank-media udev rule is restricted to whole disks" yes \
    "$(grep -B1 'ID_FS_USAGE}!="filesystem"' "$FILES/98-segno-usb-storage.rules" | grep -q 'DEVTYPE}=="disk"' && echo yes || echo no)"
check "every rule also fires on change (a card into a plugged reader)" "0 3" \
    "$(grep -c '^ACTION=="add",' "$FILES/98-segno-usb-storage.rules") $(grep -c '^ACTION=="add|change".*ID_BUS}=="usb"' "$FILES/98-segno-usb-storage.rules")"
check "an empty reader slot is not ready for systemd, so pulling a card stops its unit" yes \
    "$(grep -A2 '^ACTION=="add|change".*DEVTYPE}=="disk", \\$' "$FILES/98-segno-usb-storage.rules" | tr -d '\n' | grep -q 'ATTR{size}=="0".*SYSTEMD_READY}="0"' && echo yes || echo no)"
teardown

echo
echo "usb-ctl: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
