#!/usr/bin/env bash
# Build + run the multi-core effects spike (#1515). NOT part of the test gate;
# CI builds and smoke-runs it (native-tests).
#
# Links the real engine sources, so a chain job is what le_engine_process
# costs as shipped, plus the Signalsmith Stretch C shim the render paths call.
# The source list and the per-OS link flags mirror bench_fx_cpu.sh; keep them
# in sync with it. STATIC=1 links statically (for copying to the console);
# EXTRA_CFLAGS="-fsanitize=thread -g" checks the handoff under TSAN.
#
# Usage: ./bench_fx_parallel.sh [--chains N] [--workers 0..3] [--sweep]
#          [--max-chains N] [--seconds S] [--rate HZ] [--period FRAMES]
#          [--cpu N] [--worker-cpus A,B,C] [--wait futex|spin]
#          [--hog-cpu N] [--engine-jobs] [--smoke]
# The binary lands in packages/segno_engine/build/bench/, which is not
# tracked.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
CXX=${CXX:-c++}
OUT_DIR="${OUT_DIR:-build/bench}"
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
echo "== building bench_fx_parallel ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_fx_parallel" $CC $STD ${EXTRA_CFLAGS:-}
run_queue
# shellcheck disable=SC2086
$CC $STD ${EXTRA_CFLAGS:-} src/test/bench/bench_fx_parallel.c $ENGINE_OBJS "$OUT_DIR/le_stretch.o" \
  $LIBS ${STATIC:+-static} -o "$OUT_DIR/bench_fx_parallel"
case "$OUT_DIR" in
  /*) BIN="$OUT_DIR/bench_fx_parallel" ;;
  *) BIN="$(pwd)/$OUT_DIR/bench_fx_parallel" ;;
esac
echo "binary: $BIN" >&2

"$BIN" "$@"
