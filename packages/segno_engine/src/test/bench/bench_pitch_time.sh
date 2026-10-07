#!/usr/bin/env bash
# Build + run the pitch/time CPU bench (#1179 Part 1). NOT part of the test
# gate; CI builds and smoke-runs it (native-tests) and runs the arm64 proxy
# assertions (native-bench-arm64). See docs/plan/2026-10-06-feat-pitch-time-core-plan.md
# Part 1 and docs/plan/2026-10-06-pitch-time-spike-findings.md.
#
# Links the real engine sources (so `baseline` measures le_engine_process as
# shipped) plus the Signalsmith Stretch C shim. The source list and the per-OS
# link flags mirror run_native_tests.sh — keep them in sync with it and with
# src/CMakeLists.txt.
#
# Usage: ./bench_pitch_time.sh [--smoke] [--seconds N] [--loop-seconds N]
#          [--rate HZ] [--period FRAMES] [--budget-us N] [--assert] [--proxy]
#   --smoke   one second per scenario, two-second loops, no assertions (CI)
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
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/miniaudio \
  -I third_party/rnnoise/include -I third_party/rnnoise/src"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) LIBS="-lole32 -lwinmm -lstdc++ -lm" ;;
  Darwin) LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lc++ -lm" ;;
  *) LIBS="-lpthread -lstdc++ -lm -ldl" ;;   # Linux: miniaudio dlopen()s its backends
esac

ENGINE_SRC="src/core/engine*.c src/core/lockfree_ring.c src/core/loop_clock.c \
  src/core/tempo_grid.c \
  src/core/restore_declip.c src/core/restore_halfband.c \
  src/core/audio_ring.c src/core/perf_drain.c src/core/perf_checkpoint.c src/core/perf_log_ring.c \
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

echo "== building the stretch shim ==" >&2
$CXX -std=c++17 -O2 -DNDEBUG -c src/stretch/le_stretch.cpp -o "$OUT_DIR/le_stretch.o"
# The counting global operator new the memory scenario reads (bench only).
$CXX -std=c++17 -O2 -DNDEBUG -c src/test/bench/bench_alloc.cpp -o "$OUT_DIR/bench_alloc.o"
echo "== building bench_pitch_time ==" >&2
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_pitch_time.c $ENGINE_SRC "$OUT_DIR/le_stretch.o" \
  "$OUT_DIR/bench_alloc.o" $LIBS -o "$OUT_DIR/bench_pitch_time"
echo "binary: $(pwd)/$OUT_DIR/bench_pitch_time" >&2

"./$OUT_DIR/bench_pitch_time" "$@"
