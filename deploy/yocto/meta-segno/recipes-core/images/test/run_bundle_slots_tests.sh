#!/usr/bin/env bash
# RAUC bundle slot guard — rootfs + firmware must ship together on wrynose.
#
# Without bitbake: asserts segno-update-bundle.bb declares both slots.
# With a built bundle: BUNDLE=/path/to/file.raucb bash "$0" also runs
#   rauc info --no-verify
# and checks compatible + slot list.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../../../.." && pwd)
bundle_bb="$root/deploy/yocto/meta-segno/recipes-core/images/segno-update-bundle.bb"

pass=0
fail=0

check() {
    local name=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL: $name (want=$want got=$got)" >&2
        fail=$((fail + 1))
    fi
}

echo "recipe declares rootfs + firmware slots"
grep -qE 'RAUC_BUNDLE_SLOTS.*firmware' "$bundle_bb" && slot=yes || slot=no
grep -q 'RAUC_SLOT_firmware' "$bundle_bb" && fw=yes || fw=no
check "RAUC_BUNDLE_SLOTS includes firmware" yes "$slot"
check "RAUC_SLOT_firmware is set" yes "$fw"

if [ -n "${BUNDLE:-}" ]; then
    echo "inspecting built bundle: $BUNDLE"
    if ! command -v rauc >/dev/null 2>&1; then
        echo "WARN: rauc not installed — skipping rauc info (recipe checks still ran)"
    else
        info=$(rauc info --no-verify "$BUNDLE")
        compat=$(printf '%s\n' "$info" | sed -n 's/^Compatible:[[:space:]]*//p' | head -1)
        echo "$info" | grep -qi 'rootfs' && has_rootfs=yes || has_rootfs=no
        echo "$info" | grep -qi 'firmware' && has_firmware=yes || has_firmware=no
        check "bundle has compatible string" yes "$([ -n "$compat" ] && echo yes || echo no)"
        if [ -n "${COMPATIBLE:-}" ]; then
            check "compatible matches COMPATIBLE" "$COMPATIBLE" "$compat"
        fi
        check "bundle lists rootfs slot" yes "$has_rootfs"
        check "bundle lists firmware slot" yes "$has_firmware"
    fi
else
    echo "no BUNDLE set — skipping rauc info (recipe-only mode)"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
