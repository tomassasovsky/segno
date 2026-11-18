#!/usr/bin/env bash
# Build + run the effects aliasing bench (#1540): how much each nonlinear
# kind aliases at 48 kHz against 96 kHz, and what 2x oversampling would
# cost. NOT part of the test gate.
#
# Links the real engine sources, so the kernels are the ones that ship, plus
# the Signalsmith Stretch C shim the render paths call. The source list and
# the per-OS link flags mirror bench_fx_cpu.sh and run_native_tests.sh; keep
# them in sync with those and with src/CMakeLists.txt.
#
# Usage: ./bench_alias.sh [--case NAME] [--level DBFS] [--list]
#        ./bench_alias.sh --render NAME [--rate HZ] IN.f32 OUT.f32
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
echo "== building bench_alias ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_alias" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_alias.c $ENGINE_OBJS "$OUT_DIR/le_stretch.o" \
  $LIBS -o "$OUT_DIR/bench_alias"
echo "binary: $(pwd)/$OUT_DIR/bench_alias" >&2

"./$OUT_DIR/bench_alias" "$@"
