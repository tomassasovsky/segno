#!/usr/bin/env bash
# Build + run the device-enumeration benchmark (NOT part of the test gate).
#
# Links the real engine sources so `--mode real` measures what actually ships
# on this platform, including the per-OS le_platform_enumerate_devices seam.
# The source list is ENGINE_SRC (src/test/engine_build.sh); the per-OS link
# flags mirror run_native_tests.sh — keep them in sync.
#
# Usage: ./bench_devices.sh [--iters N] [--mode real|ma-lean|ma-full|ctx|all]
#   SEGNO_ALSA_ONLY=1 ./bench_devices.sh   # appliance path on the Pi
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
OUT="${TMPDIR:-/tmp}"
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/miniaudio"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIBS="-lole32 -lwinmm -lstdc++ -lm" ;;
  Darwin) LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lc++ -lm" ;;
  *) LIBS="-lpthread -lstdc++ -lm -ldl" ;;   # Linux: miniaudio dlopen()s its backends
esac

. src/test/engine_build.sh   # ENGINE_SRC, engine_objects, queue_compile

CXX="${CXX:-c++}"
echo "== building device bench =="
# The engine's one C++ unit, the stretch shim (#1179).
queue_compile "$OUT/le_stretch_dev.o" $CXX -std=c++17 -O2 -DNDEBUG src/stretch/le_stretch.cpp
engine_objects ENGINE_OBJS "$OUT/obj/bench_devices" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_devices.c $ENGINE_OBJS "$OUT/le_stretch_dev.o" \
  $LIBS -o "$OUT/segno_device_bench.exe"

"$OUT/segno_device_bench.exe" "$@"
