#!/usr/bin/env bash
# Build + run the instrument voice CPU bench (#1197 Part 1). NOT part of the
# test gate; CI builds and smoke-runs it (native-tests) and runs the arm64
# proxy assertions (native-bench-arm64). See
# docs/plan/2026-10-06-feat-instruments-plan.md Part 1 and
# docs/plan/2026-10-06-instruments-spike-findings.md.
#
# Links the real engine sources (the `engine` scenario measures
# le_engine_process as shipped) plus the instrument voice TUs. The source list
# is ENGINE_SRC (src/test/engine_build.sh); the per-OS link flags mirror
# run_native_tests.sh — keep them in sync. The engine's render paths call the stretch
# shim (C++), so the binary links it and the C++ runtime.
#
# Usage: ./bench_instruments.sh [--smoke] [--seconds N] [--patch-seconds N]
#          [--loop-seconds N] [--rate HZ] [--period FRAMES] [--budget-us N]
#          [--assert] [--proxy]
#   --smoke   short runs, no assertions (CI)
#   --assert  Pi 5 thresholds (refused without --proxy on anything but a
#             Cortex-A76); --proxy relaxes to the arm64 CI proxy thresholds
# The binary lands in packages/segno_engine/build/bench/ (git-ignored) so a
# CI job can upload it as an artifact for the appliance.
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
echo "== building bench_instruments ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_instruments" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_instruments.c $ENGINE_OBJS "$OUT_DIR/le_stretch.o" $LIBS \
  -o "$OUT_DIR/bench_instruments"
echo "binary: $(pwd)/$OUT_DIR/bench_instruments" >&2

"./$OUT_DIR/bench_instruments" "$@"
