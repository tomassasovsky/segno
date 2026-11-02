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
  src/core/synth_voice.c src/core/synth_patch.c \
  src/core/audio_ring.c src/core/rt_alloc.c src/core/perf_drain.c src/core/perf_checkpoint.c src/core/perf_log_ring.c \
  src/core/layer_staging_ring.c src/core/json_read.c src/core/perf_render.c \
  src/core/plugin_disabled.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c src/midi/le_midi_clock.c src/midi/le_clock_follow.c \
  third_party/rnnoise/src/denoise.c third_party/rnnoise/src/rnn.c \
  third_party/rnnoise/src/pitch.c third_party/rnnoise/src/kiss_fft.c \
  third_party/rnnoise/src/celt_lpc.c third_party/rnnoise/src/nnet.c \
  third_party/rnnoise/src/nnet_default.c \
  third_party/rnnoise/src/parse_lpcnet_weights.c \
  third_party/rnnoise/src/rnnoise_data.c \
  third_party/rnnoise/src/rnnoise_tables.c"

echo "== building the stretch shim ==" >&2
$CXX -std=c++17 -O2 -DNDEBUG -c src/stretch/le_stretch.cpp -o "$OUT_DIR/le_stretch.o"
echo "== building bench_alias ==" >&2
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_alias.c $ENGINE_SRC "$OUT_DIR/le_stretch.o" \
  $LIBS -o "$OUT_DIR/bench_alias"
echo "binary: $(pwd)/$OUT_DIR/bench_alias" >&2

"./$OUT_DIR/bench_alias" "$@"
