#!/bin/sh
# check-gdk-x11-symbols.sh — gate: the Flutter GTK embedder must not need more
# gdk_x11_* symbols than the appliance shim provides (#975).
#
# The appliance image builds GTK3 without its X11 backend (EGL-only libepoxy,
# #970), and segno-gdk-x11-shim supplies the gdk_x11_* symbols the prebuilt
# embedder resolves at load time. That only holds while the embedder's needs
# stay inside the shim's exports. A Flutter upgrade that references one more
# gdk_x11_* symbol would build, install, pass every CI gate, and then kill the
# app on the device before first frame — exactly the blank-console failure of
# build 106. Gate it here, where the .so materialises, because after this point
# nothing else looks.
#
# Usage: check-gdk-x11-symbols.sh <path/to/libflutter_linux_gtk.so>
#
# Environment:
#   NM  Symbol reader (default: nm, then llvm-nm). Must accept -D.
set -eu

so="${1:?usage: check-gdk-x11-symbols.sh <libflutter_linux_gtk.so>}"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
contract="$here/../../yocto/meta-segno/recipes-segno/segno-gdk-x11-shim/files/exported-symbols.txt"

[ -r "$so" ] || { echo "error: $so: not readable" >&2; exit 1; }
[ -r "$contract" ] || { echo "error: $contract: not readable" >&2; exit 1; }

nm_bin="${NM:-}"
if [ -z "$nm_bin" ]; then
    if command -v nm >/dev/null 2>&1; then nm_bin=nm
    elif command -v llvm-nm >/dev/null 2>&1; then nm_bin=llvm-nm
    else echo "error: neither nm nor llvm-nm on PATH (set NM=)" >&2; exit 1
    fi
fi

need=$("$nm_bin" -D --undefined-only "$so" | awk '{print $NF}' \
    | grep '^gdk_x11_' | sort -u || true)
have=$(grep -v '^#' "$contract" | grep -v '^$' | sort -u)

missing=""
for sym in $need; do
    echo "$have" | grep -qx "$sym" || missing="$missing $sym"
done

if [ -n "$missing" ]; then
    echo "error: the embedder needs gdk_x11_* symbols the shim does not provide:" >&2
    for sym in $missing; do echo "    $sym" >&2; done
    echo "On the appliance this loads as 'undefined symbol' and the app dies" >&2
    echo "before first frame. Add the symbol(s) to gdk_x11_shim.c AND to" >&2
    echo "$contract" >&2
    echo "— safely: the shim's job is to make every IS_X11 check answer no," >&2
    echo "never to hand back fake X11 handles." >&2
    exit 1
fi

count=$(printf '%s\n' "$need" | grep -c . || true)
echo "==> gdk_x11 symbol check: $count undefined gdk_x11_* symbol(s), all covered by the shim"
