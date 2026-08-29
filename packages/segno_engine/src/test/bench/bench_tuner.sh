#!/usr/bin/env bash
# Build + run the tuner callback-cost benchmark (NOT part of the test gate).
#
# Links the real engine sources, so the numbers are what le_engine_process
# actually costs on this machine with the tuner armed and disarmed. The source
# list and the per-OS link flags mirror bench_devices.sh / run_native_tests.sh —
# keep them in sync with those and with src/CMakeLists.txt.
#
# Usage: ./bench_tuner.sh [--sr N] [--frames N] [--blocks N]
#                         [--tracks N --lanes N]
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
OUT="${TMPDIR:-/tmp}"
# No -I src/asio: master deleted that directory and dropped the flag from
# run_native_tests.sh. Clang ignores a missing -I silently, so carrying it here
# would just re-introduce a dead path on merge.
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/miniaudio \
  -I third_party/rnnoise/include -I third_party/rnnoise/src"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIBS="-lole32 -lwinmm -lm" ;;
  Darwin) LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lm" ;;
  *) LIBS="-lpthread -lm -ldl" ;;   # Linux: miniaudio dlopen()s its backends
esac

ENGINE_SRC="src/core/engine*.c src/core/lockfree_ring.c src/core/loop_clock.c \
  src/core/tempo_grid.c \
  src/core/restore_declip.c src/core/restore_halfband.c \
  src/core/audio_ring.c src/core/perf_drain.c src/core/perf_log_ring.c \
  src/core/layer_staging_ring.c src/core/json_read.c src/core/perf_render.c \
  src/core/plugin_disabled.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c src/midi/le_midi_clock.c \
  third_party/rnnoise/src/denoise.c third_party/rnnoise/src/rnn.c \
  third_party/rnnoise/src/pitch.c third_party/rnnoise/src/kiss_fft.c \
  third_party/rnnoise/src/celt_lpc.c third_party/rnnoise/src/nnet.c \
  third_party/rnnoise/src/nnet_default.c \
  third_party/rnnoise/src/parse_lpcnet_weights.c \
  third_party/rnnoise/src/rnnoise_data.c \
  third_party/rnnoise/src/rnnoise_tables.c"

echo "== building tuner bench =="
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_tuner.c $ENGINE_SRC $LIBS \
  -o "$OUT/segno_tuner_bench.exe"

"$OUT/segno_tuner_bench.exe" "$@"
