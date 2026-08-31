#!/usr/bin/env bash
# Wiring tests for the HDMI HPD force-on (#821).
#
# A TV sleep/wake drops HPD for about a second. Without the kernel `D` flag
# weston disables HDMI-A-1, kiosk-shell never remaps the main surface, and the
# next click SIGSEGVs the compositor. Whether that sequence is gone is
# device-gated. What CANNOT be shown on a device once and then trusted is the
# wiring, because every way of breaking it is silent:
#
#   - drop the `D` from CMDLINE:append and the image follows HPD again.
#   - leave `video=HDMI-A-*:1920x1080@60` (no D) next to the new spec and
#     which one wins is kernel-version-dependent (#741).
#   - drop 0002 from SRC_URI and click-to-activate still SIGSEGVs if HPD
#     gets through.
#   - keep 0002 in SRC_URI but lose the null-guard hunk, same crash.
#
# So this asserts the kas cmdline, the weston recipe inventory, and the
# patch contents statically.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KAS="$here/../../../../kas-segno-common.yml"
BB="$here/../weston_%.bbappend"
PATCH="$here/../files/0002-segno-kiosk-shell-guard-stale-pointer-focus.patch"
PATCH_NAME=$(basename "$PATCH")
INI="$here/../../weston-init/files/weston.ini"

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

bb_block() {
    awk -v start="$1" '
        index($0, start) == 1 { inblock = 1 }
        inblock { print; if ($0 !~ /\\$/) exit }
    ' "$BB"
}

strip_comments() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d'; }

in_src_uri() {
    bb_block 'SRC_URI' | strip_comments |
        grep -qE "(^|[[:space:]\"])file://$1(\"|[[:space:]]|$)" &&
        echo yes || echo no
}

# The kiosk-console CMDLINE:append line (not comments).
cmdline() {
    grep -E '^[[:space:]]*CMDLINE:append' "$KAS"
}

echo "the kernel cmdline force-enables both HDMI connectors"
check "kas file is where the test expects" yes \
    "$([ -f "$KAS" ] && echo yes || echo no)"
check "HDMI-A-1 is 1920x1080@60D" yes \
    "$(cmdline | grep -qF 'video=HDMI-A-1:1920x1080@60D' && echo yes || echo no)"
check "HDMI-A-2 is 1920x1080@60D" yes \
    "$(cmdline | grep -qF 'video=HDMI-A-2:1920x1080@60D' && echo yes || echo no)"
# A leftover `...@60` (no D) next to the D spec is #741 again: two video=
# args for the same connector, and HPD-follow may still win.
check "no HDMI-A-1 video= without D" yes \
    "$(cmdline | grep -qE 'video=HDMI-A-1:1920x1080@60([^D]|$)' && echo no || echo yes)"
check "no HDMI-A-2 video= without D" yes \
    "$(cmdline | grep -qE 'video=HDMI-A-2:1920x1080@60([^D]|$)' && echo no || echo yes)"

echo "weston.ini comments still name the cmdline that actually ships"
check "weston.ini quotes HDMI-A-1 ...@60D" yes \
    "$(grep -qF 'video=HDMI-A-1:1920x1080@60D' "$INI" && echo yes || echo no)"
check "weston.ini quotes HDMI-A-2 ...@60D" yes \
    "$(grep -qF 'video=HDMI-A-2:1920x1080@60D' "$INI" && echo yes || echo no)"

echo "the recipe ships the kiosk-shell click guard"
check "SRC_URI still names the vc4 cursor patch" yes \
    "$(in_src_uri 0001-segno-vc4-cursor-planes-broken.patch)"
check "SRC_URI names the kiosk-shell guard patch" yes \
    "$(in_src_uri "$PATCH_NAME")"
check "patch file exists" yes \
    "$([ -f "$PATCH" ] && echo yes || echo no)"
check "patch guards a NULL view->surface" yes \
    "$(grep -qF 'if (!view || !view->surface)' "$PATCH" && echo yes || echo no)"
check "patch targets kiosk_shell_activate_view" yes \
    "$(grep -qF 'kiosk_shell_activate_view' "$PATCH" && echo yes || echo no)"

echo "patch applies cleanly to weston 14.0.1 (bitbake rejects fuzz)"
WESTON_TAR="https://gitlab.freedesktop.org/wayland/weston/-/releases/14.0.1/downloads/weston-14.0.1.tar.xz"
WESTON_SHA="a8150505b126a59df781fe8c30c8e6f87da7013e179039eb844a5bbbcc7c79b3"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
if ! curl -fsSL "$WESTON_TAR" -o "$tmpdir/weston-14.0.1.tar.xz"; then
    echo "  FAIL could not fetch weston 14.0.1 tarball"
    fail=$((fail + 1))
else
    actual_sha=$(shasum -a 256 "$tmpdir/weston-14.0.1.tar.xz" | awk '{print $1}')
    check "weston tarball sha256" "$WESTON_SHA" "$actual_sha"
    tar -xJf "$tmpdir/weston-14.0.1.tar.xz" -C "$tmpdir"
    patch_out=$(patch -p1 --dry-run --verbose -d "$tmpdir/weston-14.0.1" < "$PATCH" 2>&1 || true)
    check "patch applies without fuzz" yes \
        "$(printf '%s' "$patch_out" | grep -qE 'fuzz|offset' && echo no || echo yes)"
    check "patch hunk succeeds" yes \
        "$(printf '%s' "$patch_out" | grep -q 'Hunk #1 succeeded' && echo yes || echo no)"
fi

echo
echo "hdmi-hpd: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ALL PASSED"
