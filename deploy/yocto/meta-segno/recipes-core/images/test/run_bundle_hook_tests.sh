#!/usr/bin/env bash
# Tests for the RAUC install hook that points a boot slot at its own rootfs.
#
# Writing a boot slot needs a device; deciding WHICH rootfs it should boot does
# not, and that decision is the one with teeth. Get it wrong and the console
# boots the slot the update just replaced, or panics with no rootfs at all —
# both after a reboot, on a unit that is no longer in front of anyone.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$here/../files/segno-bundle-hook.sh"

pass=0
fail=0

setup() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/bundle-hook-test.XXXXXX")
    mkdir -p "$work/bin" "$work/slot"
    printf 'console=tty1 root=XXX rootfstype=ext4 rootwait\n' > "$work/slot/cmdline.txt"

    # mount/umount stand in for the real thing: the hook is asserted on what it
    # writes, not on its ability to mount a filesystem.
    cat > "$work/bin/mount" <<STUB
#!/usr/bin/env bash
# args: -t vfat <device> <mountpoint>. The hook makes its own empty mount point,
# so stand the slot in its place rather than under it.
mp="\${!#}"
rmdir "\$mp" 2>/dev/null || true
ln -sfn "$work/slot" "\$mp"
STUB
    cat > "$work/bin/umount" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$work/bin/mount" "$work/bin/umount"
}

teardown() { rm -rf "$work"; }

run() {
    PATH="$work/bin:$PATH" \
    RAUC_SLOT_CLASS="${CLASS:-firmware}" \
    RAUC_SLOT_NAME="${NAME:-firmware.1}" \
    RAUC_SLOT_DEVICE="${DEVICE:-/dev/nvme0n1p3}" \
    bash "$HOOK" "${PHASE:-slot-post-install}" 2>"$work/log"
}

check() {
    local name=$1 cond=$2
    if eval "$cond"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $name"
        echo "  condition: $cond"
        echo "  cmdline: $(cat "$work/slot/cmdline.txt" 2>/dev/null)"
        echo "  log: $(cat "$work/log" 2>/dev/null)"
    fi
}

# bootB (p3) must boot rootB (p6) — three partitions apart, per the WIC layout.
setup
DEVICE=/dev/nvme0n1p3 run; status=$?
check "bootB points at rootB" 'grep -q "root=/dev/nvme0n1p6" "$work/slot/cmdline.txt"'
check "bootB leaves no placeholder" '! grep -q "root=XXX" "$work/slot/cmdline.txt"'
check "bootB succeeds" '[ "$status" = 0 ]'
teardown

# bootA (p2) must boot rootA (p5).
setup
DEVICE=/dev/nvme0n1p2 run; status=$?
check "bootA points at rootA" 'grep -q "root=/dev/nvme0n1p5" "$work/slot/cmdline.txt"'
teardown

# The Pi 4 images to an SD card, whose partitions are named the same way.
setup
DEVICE=/dev/mmcblk0p2 run; status=$?
check "sd card layout works too" 'grep -q "root=/dev/mmcblk0p5" "$work/slot/cmdline.txt"'
teardown

# The rest of the cmdline is untouched: it carries the console, the fstype and
# rootwait, and losing any of them is its own kind of unbootable.
setup
DEVICE=/dev/nvme0n1p3 run >/dev/null
check "the rest of the cmdline survives" 'grep -q "console=tty1 root=/dev/nvme0n1p6 rootfstype=ext4 rootwait" "$work/slot/cmdline.txt"'
teardown

# A slot with no placeholder is not something to guess at: refuse loudly rather
# than leave a slot that panics with no rootfs.
setup
printf 'console=tty1 root=/dev/nvme0n1p5 rootwait\n' > "$work/slot/cmdline.txt"
DEVICE=/dev/nvme0n1p3 run; status=$?
check "a missing placeholder fails" '[ "$status" != 0 ]'
check "a missing placeholder is explained" 'grep -q "refusing to guess" "$work/log"'
teardown

# Only the boot slots. The rootfs slot is written by RAUC itself.
setup
CLASS=rootfs DEVICE=/dev/nvme0n1p6 run; status=$?
check "the rootfs slot is left alone" 'grep -q "root=XXX" "$work/slot/cmdline.txt"'
check "the rootfs slot succeeds" '[ "$status" = 0 ]'
teardown

# Other hook phases are not this hook's business.
setup
PHASE=install-check run; status=$?
check "other phases do nothing" 'grep -q "root=XXX" "$work/slot/cmdline.txt"'
check "other phases succeed" '[ "$status" = 0 ]'
teardown

echo "bundle-hook: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
