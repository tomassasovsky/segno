#!/usr/bin/env bash
# Tests for the RAUC hook that writes a boot slot (#989).
#
# Writing a partition needs a device; the DECISIONS do not, and they are the
# ones with teeth, because every one of them is only observable after a reboot:
#
#   * which rootfs the slot boots — wrong, and the console boots the copy the
#     update just replaced, or panics with no rootfs at all;
#   * the filesystem label — the disk layout labels these bootA / bootB and
#     RAUC's own handler would name them after the slot instead;
#   * refusing rather than guessing when the boot files are not what we expect.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$here/../files/segno-bundle-hook.sh"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/bundle-hook-test.XXXXXX")
    mkdir -p "$work/bin" "$work/slot" "$work/payload"
    : > "$work/calls"

    # The boot files the bundle carries, with the placeholder the image build
    # ships and the install is expected to resolve.
    printf 'console=tty1 root=XXX rootfstype=ext4 rootwait\n' > "$work/payload/cmdline.txt"
    printf 'dtoverlay=uart3-pi5\ngpio=25=pu\n' > "$work/payload/config.txt"
    tar -C "$work/payload" -cf "$work/boot.tar" .

    for tool in mkfs.vfat mount umount; do
        cat > "$work/bin/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >> "$work/calls"
STUB
        chmod +x "$work/bin/$tool"
    done

    # mount stands the slot dir in place of the hook's own mount point.
    cat > "$work/bin/mount" <<STUB
#!/usr/bin/env bash
echo "mount \$*" >> "$work/calls"
mp="\${!#}"
rmdir "\$mp" 2>/dev/null || true
ln -sfn "$work/slot" "\$mp"
STUB
    chmod +x "$work/bin/mount"
}

teardown() { rm -rf "$work"; }

run() {
    PATH="$work/bin:$PATH" \
    RAUC_SLOT_CLASS="${CLASS:-firmware}" \
    RAUC_SLOT_NAME="${NAME:-firmware.1}" \
    RAUC_SLOT_DEVICE="${DEVICE:-/dev/nvme0n1p3}" \
    RAUC_IMAGE_NAME="${IMAGE:-$work/boot.tar}" \
    bash "$HOOK" "${PHASE:-slot-install}" 2>"$work/log"
}

check() {
    local name=$1 cond=$2
    if eval "$cond"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $name"
        echo "  condition: $cond"
        echo "  calls: $(tr '\n' '; ' < "$work/calls" 2>/dev/null)"
        echo "  cmdline: $(cat "$work/slot/cmdline.txt" 2>/dev/null)"
        echo "  log: $(cat "$work/log" 2>/dev/null)"
    fi
}

# bootB (p3) boots rootB (p6), and is labelled the way the layout expects.
setup
DEVICE=/dev/nvme0n1p3 run; status=$?
check "bootB is written" '[ "$status" = 0 ]'
check "bootB points at rootB" 'grep -q "root=/dev/nvme0n1p6" "$work/slot/cmdline.txt"'
check "bootB keeps the layout label" 'grep -q "mkfs.vfat -n bootB /dev/nvme0n1p3" "$work/calls"'
check "the boot files arrive" 'grep -q "dtoverlay=uart3-pi5" "$work/slot/config.txt"'
check "no placeholder survives" '! grep -q "root=XXX" "$work/slot/cmdline.txt"'
teardown

# bootA (p2) boots rootA (p5).
setup
DEVICE=/dev/nvme0n1p2 run; status=$?
check "bootA points at rootA" 'grep -q "root=/dev/nvme0n1p5" "$work/slot/cmdline.txt"'
check "bootA keeps the layout label" 'grep -q "mkfs.vfat -n bootA /dev/nvme0n1p2" "$work/calls"'
teardown

# The Pi 4 images to an SD card, whose partitions are named the same way.
setup
DEVICE=/dev/mmcblk0p2 run
check "sd card layout works too" 'grep -q "root=/dev/mmcblk0p5" "$work/slot/cmdline.txt"'
teardown

# The rest of the command line survives: losing the console or rootwait is its
# own kind of unbootable.
setup
DEVICE=/dev/nvme0n1p3 run
check "the rest of the cmdline survives" 'grep -q "console=tty1 root=/dev/nvme0n1p6 rootfstype=ext4 rootwait" "$work/slot/cmdline.txt"'
teardown

# Boot files with no placeholder are not something to guess at.
setup
printf 'console=tty1 root=/dev/nvme0n1p5 rootwait\n' > "$work/payload/cmdline.txt"
tar -C "$work/payload" -cf "$work/boot.tar" .
DEVICE=/dev/nvme0n1p3 run; status=$?
check "a missing placeholder fails" '[ "$status" != 0 ]'
check "a missing placeholder is explained" 'grep -q "refusing to guess" "$work/log"'
teardown

# Boot files with no cmdline.txt at all are a broken bundle, not a slot to boot.
setup
rm "$work/payload/cmdline.txt"
tar -C "$work/payload" -cf "$work/boot.tar" .
DEVICE=/dev/nvme0n1p3 run; status=$?
check "missing cmdline.txt fails" '[ "$status" != 0 ]'
teardown

# A partition outside the layout is refused rather than formatted on a guess.
setup
DEVICE=/dev/nvme0n1p7 run; status=$?
check "an unknown partition is refused" '[ "$status" != 0 ]'
check "an unknown partition is not formatted" '! grep -q mkfs "$work/calls"'
teardown

# A missing image is a broken bundle; do not format a slot for it.
setup
IMAGE="$work/absent.tar" DEVICE=/dev/nvme0n1p3 run; status=$?
check "a missing image fails" '[ "$status" != 0 ]'
check "a missing image formats nothing" '! grep -q mkfs "$work/calls"'
teardown

# RAUC writes the rootfs itself; this hook must keep its hands off it.
setup
CLASS=rootfs DEVICE=/dev/nvme0n1p6 run; status=$?
check "the rootfs slot is left alone" '[ ! -s "$work/calls" ]'
check "the rootfs slot succeeds" '[ "$status" = 0 ]'
teardown

# Other hook phases are not this hook's business.
setup
PHASE=slot-post-install run; status=$?
check "other phases do nothing" '[ ! -s "$work/calls" ]'
check "other phases succeed" '[ "$status" = 0 ]'
teardown

echo "bundle-hook: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
