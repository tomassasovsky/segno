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
STD="-std=gnu11 -O2 -fPIC -I src/core -I src/midi -I src/miniaudio"

# The C++ runtime is linked for the one C++ engine TU (src/stretch/
# le_stretch.cpp, #1179), compiled separately below.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) EXT="dll";   LIBS="-lole32 -lwinmm -lstdc++ -lm" ;;
  Darwin)               EXT="dylib"; LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lc++ -lm" ;;
  *)                    EXT="so";    LIBS="-lpthread -lstdc++ -lm -ldl" ;;
esac
CXX="${CXX:-c++}"

OUT_DIR="build/test_lib"
OUT="$OUT_DIR/segno_engine_test.$EXT"
mkdir -p "$OUT_DIR"

# The engine TUs are ENGINE_SRC (src/test/engine_build.sh), compiled in
# parallel and through ccache when it is installed. Nothing but the path
# below may reach stdout, so the build's output goes to stderr.
. src/test/engine_build.sh
queue_compile "$OUT_DIR/le_stretch.o" $CXX -std=c++17 -O2 -fPIC src/stretch/le_stretch.cpp
engine_objects ENGINE_OBJS "$OUT_DIR/obj" $CC $STD
run_queue 1>&2
# shellcheck disable=SC2086
$CC $STD -shared "$OUT_DIR/le_stretch.o" $ENGINE_OBJS $LIBS -o "$OUT" 1>&2

# The one machine-readable line: the built library's absolute path.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) cygpath -w "$(pwd)/$OUT" ;;
  *) echo "$(pwd)/$OUT" ;;
esac
