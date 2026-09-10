#!/usr/bin/env bash
# build_test_lib.sh — build the engine as a shared library for device-free
# Dart tests (the sequence fuzzer's PumpedNativeEngine).
#
# Compiles the SAME engine source set as run_native_tests.sh into a shared
# lib and prints its absolute path. Consumers export it:
#
#   export SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)"
#   flutter test --tags fuzz
#
# The lib lands under build/test_lib/ inside this package (git-ignored via the
# top-level build/ ignore). Mirrors run_native_tests.sh's toolchain choices.
set -euo pipefail
cd "$(dirname "$0")/.."   # tool -> packages/segno_engine

CC="${CC:-gcc}"
# Include path and TU set mirror run_native_tests.sh — keep the two in sync.
# The vendored RNNoise headers and the restore_*.c TUs joined the engine after
# this script was last touched, so it had stopped compiling: every consumer
# saw "SEGNO_ENGINE_LIB not set" and skipped, silently.
STD="-std=gnu11 -O2 -fPIC -I src/core -I src/midi -I src/asio -I src/miniaudio \
  -I third_party/rnnoise/include -I third_party/rnnoise/src"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) EXT="dll";   LIBS="-lole32 -lwinmm -lm" ;;
  Darwin)               EXT="dylib"; LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lm" ;;
  *)                    EXT="so";    LIBS="-lpthread -lm -ldl" ;;
esac

OUT_DIR="build/test_lib"
OUT="$OUT_DIR/segno_engine_test.$EXT"
mkdir -p "$OUT_DIR"

# Engine TU set mirrors run_native_tests.sh / src/CMakeLists.txt (no MIDI TUs:
# the pump surface doesn't need them and they drag in platform MIDI deps) --
# EXCEPT src/midi/le_midi_clock.c (C1, D15), which IS an engine dependency
# (engine_process.c calls le_midi_clock_advance every block) despite living
# in midi/ per the plan's file placement; keep in sync with the other two.
# shellcheck disable=SC2086
$CC $STD -shared \
  src/core/engine*.c src/core/lockfree_ring.c src/core/loop_clock.c \
  src/core/tempo_grid.c \
  src/core/restore_declip.c src/core/restore_halfband.c \
  src/core/audio_ring.c src/core/perf_drain.c src/core/perf_log_ring.c src/core/layer_staging_ring.c src/core/json_read.c src/core/perf_render.c src/core/plugin_disabled.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c src/midi/le_midi_clock.c \
  third_party/rnnoise/src/denoise.c third_party/rnnoise/src/rnn.c \
  third_party/rnnoise/src/pitch.c third_party/rnnoise/src/kiss_fft.c \
  third_party/rnnoise/src/celt_lpc.c third_party/rnnoise/src/nnet.c \
  third_party/rnnoise/src/nnet_default.c \
  third_party/rnnoise/src/parse_lpcnet_weights.c \
  third_party/rnnoise/src/rnnoise_data.c \
  third_party/rnnoise/src/rnnoise_tables.c \
  $LIBS -o "$OUT" 1>&2

# The one machine-readable line: the built library's absolute path.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) cygpath -w "$(pwd)/$OUT" ;;
  *) echo "$(pwd)/$OUT" ;;
esac
