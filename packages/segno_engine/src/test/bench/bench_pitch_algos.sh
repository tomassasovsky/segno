#!/usr/bin/env bash
# Build + run the pitch-shifter comparison (#887 part 9). NOT part of the test gate;
# CI runs it on the arm64 bench job.
#
# Links the real engine sources and drives fx_apply_chain (the chain runner
# le_engine_process calls per lane) and the Signalsmith Stretch C shim the
# render paths call, so the kernels are the shipped ones.
# The source list is ENGINE_SRC (src/test/engine_build.sh); the per-OS link
# flags mirror run_native_tests.sh; keep them in sync.
#
# Usage: ./bench_pitch_algos.sh [--smoke] [--paced]
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
echo "== building bench_pitch_algos ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_pitch_algos" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_pitch_algos.c $ENGINE_OBJS "$OUT_DIR/le_stretch.o" \
  $LIBS -o "$OUT_DIR/bench_pitch_algos"
echo "binary: $(pwd)/$OUT_DIR/bench_pitch_algos" >&2

"./$OUT_DIR/bench_pitch_algos" "$@"
