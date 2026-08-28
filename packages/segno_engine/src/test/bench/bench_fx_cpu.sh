#!/usr/bin/env bash
# Build + run the per-callback engine CPU benchmark (NOT part of the test gate).
#
# Links the real engine sources so the timings are what actually ships. The
# source list and the per-OS link flags mirror bench_devices.sh /
# run_native_tests.sh — keep them in sync with those and with src/CMakeLists.txt.
#
# Usage: ./bench_fx_cpu.sh [--blocks N] [--mode all|oct1|oct4|oct4lanes|lanes1|lanes8]
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
OUT="${TMPDIR:-/tmp}"
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/asio -I src/miniaudio"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIBS="-lole32 -lwinmm -lm" ;;
  Darwin) LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lm" ;;
  *) LIBS="-lpthread -lm -ldl" ;;   # Linux: miniaudio dlopen()s its backends
esac

ENGINE_SRC="src/core/engine*.c src/core/lockfree_ring.c src/core/loop_clock.c \
  src/core/tempo_grid.c \
  src/core/audio_ring.c src/core/perf_drain.c src/core/perf_log_ring.c \
  src/core/layer_staging_ring.c src/core/json_read.c src/core/perf_render.c \
  src/core/plugin_disabled.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c src/midi/le_midi_clock.c"

echo "== building fx cpu bench =="
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_fx_cpu.c $ENGINE_SRC $LIBS \
  -o "$OUT/segno_fx_cpu_bench.exe"

"$OUT/segno_fx_cpu_bench.exe" "$@"
