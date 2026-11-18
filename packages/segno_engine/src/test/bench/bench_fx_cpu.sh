#!/usr/bin/env bash
# Build + run the built-in effects CPU bench (#915). NOT part of the test gate;
# CI builds and smoke-runs it (native-tests).
#
# Links the real engine sources, so the numbers are what le_engine_process
# costs as shipped, plus the Signalsmith Stretch C shim the render paths call.
# The source list is ENGINE_SRC (src/test/engine_build.sh); the per-OS link
# flags mirror run_native_tests.sh; keep them in sync.
#
# Usage: ./bench_fx_cpu.sh [--smoke] [--paced] [--racks] [--table]
#          [--only KIND,KIND...] [--rate HZ]
#          [--period FRAMES]
#          [--blocks N] [--cpu N] [--kind octaver|psola|eq|comp|transient|
#          hpgate|doubler|chorus|wah|overdrive|distortion|vinyl|degrade|lpf|
#          spring|drive|filter|delay|tremolo|echo|reverb|dubverb|ambverb|
#          whammy|pumper|slicer|lpflfo|modedelay|drumdelay|dubdelay|dualoct|
#          ampcab|mod|roomverb|smarttune]
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
echo "== building bench_fx_cpu ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_fx_cpu" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_fx_cpu.c $ENGINE_OBJS "$OUT_DIR/le_stretch.o" \
  $LIBS -o "$OUT_DIR/bench_fx_cpu"
echo "binary: $(pwd)/$OUT_DIR/bench_fx_cpu" >&2

"./$OUT_DIR/bench_fx_cpu" "$@"
