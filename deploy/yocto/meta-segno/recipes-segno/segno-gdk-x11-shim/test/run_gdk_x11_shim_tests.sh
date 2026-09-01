#!/usr/bin/env bash
# Tests for segno-gdk-x11-shim (#975) — the library that lets the prebuilt
# (Ubuntu-built) Flutter GTK embedder load on an image whose GTK3 has no X11
# backend.
#
# What is pinned here, and why each half matters:
#
#   1. Wiring (runs everywhere): the pieces that make the shim reach the app
#      agree with each other — the symbol contract file, the LD_PRELOAD line in
#      segno-kiosk-launch, and the image install. Any one of these drifting
#      reproduces the build-106 blank console with every CI gate green.
#
#   2. Behaviour (Linux toolchain; CI always runs it): the shim compiles clean,
#      exports EXACTLY the contract, and — the load-bearing property — its
#      GTypes answer "no" when a real GObject instance is type-checked against
#      them. That "no" is what keeps the embedder's GDK_IS_X11_* guards from
#      ever entering an X11 code path on Wayland.
#
# The bundle-build side of the same contract (embedder needs ⊆ shim exports)
# is enforced by deploy/rpi/build/check-gdk-x11-symbols.sh, not here — this
# suite has no libflutter_linux_gtk.so to inspect.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC="$here/../files/gdk_x11_shim.c"
CONTRACT="$here/../files/exported-symbols.txt"
LAUNCH="$here/../../segno-bundle/files/segno-kiosk-launch"
IMAGE_BB="$here/../../../recipes-core/images/segno-kiosk-image.bb"

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

finish() {
    echo
    echo "gdk-x11-shim: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || exit 1
    echo "ALL PASSED"
    exit 0
}

echo "wiring: the contract, the launcher, and the image agree"
contract_syms=$(grep -v '^#' "$CONTRACT" | grep -v '^$' | sort)
check "contract lists 4 symbols" 4 "$(echo "$contract_syms" | grep -c .)"
check "every contract symbol is implemented in the shim source" yes \
    "$(ok=yes; while read -r s; do grep -q "$s(" "$SRC" || ok=no; done <<<"$contract_syms"; echo $ok)"
check "segno-kiosk-launch preloads the shim" yes \
    "$(grep -q '^export LD_PRELOAD=/usr/lib/libsegno-gdk-x11-shim.so$' "$LAUNCH" && echo yes || echo no)"
check "segno-kiosk-image installs segno-gdk-x11-shim" yes \
    "$(grep -q 'segno-gdk-x11-shim' "$IMAGE_BB" && echo yes || echo no)"

if [ "$(uname -s)" != "Linux" ]; then
    echo
    echo "  SKIP behaviour tests: need a Linux ELF toolchain (CI runs them)"
    finish
fi

echo
echo "behaviour: compiled shim exports the contract and answers IS_X11 with no"
work=$(mktemp -d "${TMPDIR:-/tmp}/gdk-x11-shim-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

gcc -Wall -Wextra -Werror -shared -fPIC $(pkg-config --cflags glib-2.0) \
    "$SRC" -o "$work/shim.so" $(pkg-config --libs gobject-2.0) 2>"$work/cc.err"
check "compiles with -Werror" 0 "$?"
[ -s "$work/cc.err" ] && sed 's/^/       | /' "$work/cc.err"

exports=$("${NM:-nm}" -D --defined-only "$work/shim.so" | awk '$2 == "T" {print $3}' | grep '^gdk_x11_' | sort)
check "exports exactly the contract" yes \
    "$([ "$exports" = "$contract_syms" ] && echo yes || echo no)"

cat > "$work/harness.c" <<'EOF'
#include <glib-object.h>
#include <stdio.h>
#include <string.h>

extern GType gdk_x11_display_get_type(void);
extern GType gdk_x11_screen_get_type(void);
extern void* gdk_x11_display_get_xdisplay(void* display);
extern const char* gdk_x11_screen_get_window_manager_name(void* screen);

int main(void) {
    GType td = gdk_x11_display_get_type();
    GType ts = gdk_x11_screen_get_type();
    if (td == 0 || ts == 0 || td == ts) { puts("BAD types"); return 1; }
    /* second call must return the same registered type, not re-register */
    if (gdk_x11_display_get_type() != td) { puts("BAD not idempotent"); return 1; }

    /* The property the whole design rests on: a real (non-X11) GObject fails
     * the instance check, so GDK_IS_X11_DISPLAY / _SCREEN answer no. */
    GObject* o = g_object_new(G_TYPE_OBJECT, NULL);
    if (G_TYPE_CHECK_INSTANCE_TYPE(o, td)) { puts("BAD display check"); return 1; }
    if (G_TYPE_CHECK_INSTANCE_TYPE(o, ts)) { puts("BAD screen check"); return 1; }
    g_object_unref(o);

    if (strcmp(gdk_x11_screen_get_window_manager_name(NULL), "unknown") != 0) {
        puts("BAD wm name"); return 1;
    }
    if (gdk_x11_display_get_xdisplay(NULL) != NULL) { puts("BAD xdisplay"); return 1; }
    puts("HARNESS OK");
    return 0;
}
EOF
gcc -Wall -Werror $(pkg-config --cflags glib-2.0) "$work/harness.c" "$work/shim.so" \
    -o "$work/harness" $(pkg-config --libs gobject-2.0)
check "harness compiles" 0 "$?"
# get_xdisplay logs a CRITICAL by design (g_return_val_if_reached); keep it off
# the test output but do not let it kill the run.
out=$("$work/harness" 2>"$work/harness.err")
check "IS_X11 checks answer no; stubs behave" "HARNESS OK" "$out"
check "the never-call stub logged its critical" yes \
    "$(grep -q "gdk_x11_display_get_xdisplay" "$work/harness.err" && echo yes || echo no)"

finish
