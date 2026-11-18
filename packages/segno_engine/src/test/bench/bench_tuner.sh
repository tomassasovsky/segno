#!/usr/bin/env bash
# Build + run the tuner callback-cost benchmark (NOT part of the test gate).
#
# Links the real engine sources, so the numbers are what le_engine_process
# actually costs on this machine with the tuner armed and disarmed. The source
# list is ENGINE_SRC (src/test/engine_build.sh); the per-OS link flags mirror
# bench_devices.sh / run_native_tests.sh — keep them in sync.
#
# Usage: ./bench_tuner.sh [--sr N] [--frames N] [--blocks N]
#                         [--tracks N --lanes N]
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
OUT="${TMPDIR:-/tmp}"
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/miniaudio"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIBS="-lole32 -lwinmm -lm" ;;
  Darwin) LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lm" ;;
  *) LIBS="-lpthread -lm -ldl" ;;   # Linux: miniaudio dlopen()s its backends
esac

. src/test/engine_build.sh   # ENGINE_SRC, engine_objects, queue_compile

echo "== building tuner bench =="
engine_objects ENGINE_OBJS "$OUT/obj/bench_tuner" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_tuner.c $ENGINE_OBJS $LIBS \
  -o "$OUT/segno_tuner_bench.exe"

"$OUT/segno_tuner_bench.exe" "$@"
