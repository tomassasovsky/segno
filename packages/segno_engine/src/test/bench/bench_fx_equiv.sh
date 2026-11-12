#!/usr/bin/env bash
# Build + run the effects equivalence check (#1755): every effect kind
# against the reference engine's render of the same input, bit-identical or
# within -120 dBFS (bench_fx_equiv.c says which). run_native_tests.sh runs
# its --ci subset; the full run is by hand.
#
# Builds two shared libraries from fx_equiv_shim.c and the effects island
# (engine_fx.c, rt_alloc.c, plugin_disabled.c): the reference from REF's
# packages/segno_engine/src (git archive), and the working tree's. REF is
# the trunk the optimisations started from, a commit on the trunk so it
# stays reachable. A PR that changes how a kind sounds on purpose lists the
# kind in k_moved (bench_fx_equiv.c); once it has landed, a later change
# moves REF to the trunk's commit and empties k_moved. After a history
# rewrite REF is the rewritten commit of the same tree. A clone without REF
# fetches it (a CI checkout is shallow).
#
# Usage: ./bench_fx_equiv.sh [--ci] [--kind NAME] [--jobs N] [--detail]
# The binaries land in packages/segno_engine/build/bench/fx_equiv/ (or
# FX_EQUIV_OUT), which is not tracked. CC and EXTRA_CFLAGS apply to all
# three builds, then FX_EQUIV_OPT (-O2; CI's arm64 job also runs clang at
# -O3, the appliance library's build).
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

REF=${FX_EQUIV_REF:-65f85a3b44969875da537a1a5182ca878b5e7f5b}
CC=${CC:-cc}
EXTRA_CFLAGS=${EXTRA_CFLAGS:-}
OPT=${FX_EQUIV_OPT:--O2}
OUT_DIR=${FX_EQUIV_OUT:-build/bench/fx_equiv}
mkdir -p "$OUT_DIR"

# FX_EQUIV_REF_SRC: REF's packages/segno_engine/src already extracted (a
# container without git); otherwise git archive extracts it.
if [ -n "${FX_EQUIV_REF_SRC:-}" ]; then
  REF_SRC=$FX_EQUIV_REF_SRC
else
  if ! git cat-file -e "$REF^{commit}" 2>/dev/null; then
    echo "== fetching the reference $REF ==" >&2
    if ! git fetch --quiet --depth 1 origin "$REF"; then
      echo "bench_fx_equiv: the reference $REF is not on origin; move REF" \
        "to a trunk commit (the header says how)" >&2
      exit 1
    fi
  fi
  rm -rf "$OUT_DIR/ref"
  mkdir -p "$OUT_DIR/ref"
  # The island and the headers it includes.
  git archive "$REF" -- src/core src/midi src/host/plugin_slot.h \
    src/miniaudio/miniaudio.h | tar -x -C "$OUT_DIR/ref"
  REF_SRC=$OUT_DIR/ref/src
fi

case "$(uname -s)" in
  Darwin) LIB_FLAGS="-shared"; HARNESS_LIBS="-lpthread -lm" ;;
  *) LIB_FLAGS="-shared -Wl,-Bsymbolic"; HARNESS_LIBS="-ldl -lpthread -lm" ;;
esac
# -fmath-errno, Linux's default, also on macOS, where without it Clang may
# fuse a sinf and a cosf into Apple's sincos in one library and not the
# other (the pitch kinds' rebuild under ASan, #1764).
STD="-std=gnu11 -DNDEBUG -fPIC -fmath-errno"
ISLAND="core/engine_fx.c core/rt_alloc.c core/plugin_disabled.c"

build_lib() { # build_lib SRC_DIR OUT
  local dir=$1 out=$2 files=""
  for f in $ISLAND; do files="$files $dir/$f"; done
  # shellcheck disable=SC2086
  $CC $STD $EXTRA_CFLAGS $OPT -I "$dir/core" -I "$dir/midi" -I "$dir/miniaudio" \
    $LIB_FLAGS \
    src/test/bench/fx_equiv_shim.c $files -lpthread -lm -o "$out"
}

echo "== building the reference effects ($REF) ==" >&2
build_lib "$REF_SRC" "$OUT_DIR/libfx_ref.so"
echo "== building the working tree's effects ==" >&2
build_lib src "$OUT_DIR/libfx_new.so"
echo "== building bench_fx_equiv ==" >&2
# shellcheck disable=SC2086
$CC $STD $EXTRA_CFLAGS -O2 -I src/core -I src/midi -I src/miniaudio \
  src/test/bench/bench_fx_equiv.c $HARNESS_LIBS -o "$OUT_DIR/bench_fx_equiv"

"$OUT_DIR/bench_fx_equiv" "$OUT_DIR/libfx_ref.so" "$OUT_DIR/libfx_new.so" "$@"
