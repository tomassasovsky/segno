#!/usr/bin/env bash
# Build + run the effects matrix (#1547): every kind at every sample rate and
# buffer size, against its factory-preset settings. The full run; the native
# tests run its CI subset (--ci). Usage at the top of bench_fx_matrix.c.
#
# Links the real engine sources, so the kernels are the ones that ship, plus
# the Signalsmith Stretch C shim the render paths call. The source list and
# the per-OS link flags mirror bench_alias.sh and run_native_tests.sh; keep
# them in sync with those and with src/CMakeLists.txt.
#
# Usage: ./bench_fx_matrix.sh [--kind NAME] [--detail] [--jobs N] [--ci]
# The binary lands in packages/segno_engine/build/bench/, which is not
# tracked.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
CXX=${CXX:-c++}
OUT_DIR="build/bench"
mkdir -p "$OUT_DIR"
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/miniaudio"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIBS="-lole32 -lwinmm -lstdc++ -lm" ;;
  Darwin) LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lc++ -lm" ;;
  *) LIBS="-lpthread -lstdc++ -lm -ldl" ;;   # Linux: miniaudio dlopen()s its backends
esac

. src/test/engine_build.sh   # ENGINE_SRC, engine_objects, queue_compile

echo "== building the stretch shim ==" >&2
queue_compile "$OUT_DIR/le_stretch.o" $CXX -std=c++17 -O2 -DNDEBUG src/stretch/le_stretch.cpp
echo "== building bench_fx_matrix ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_fx_matrix" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_fx_matrix.c $ENGINE_OBJS "$OUT_DIR/le_stretch.o" \
  $LIBS -o "$OUT_DIR/bench_fx_matrix"
echo "binary: $(pwd)/$OUT_DIR/bench_fx_matrix" >&2

"./$OUT_DIR/bench_fx_matrix" "$@"
