#!/usr/bin/env bash
# Build + run the pitch kinds' oracle alone (test_pitch_oracle.c, #1755):
# the pitch kinds against their kernels before #1755, bit for bit.
# run_native_tests.sh runs it with the rest; CI's arm64 job runs it through
# this script with CC=clang, the console's compiler, the one the NEON paths
# build under. The source list is ENGINE_SRC (engine_build.sh); the link
# flags mirror run_native_tests.sh; keep them in sync.
#
# Usage: [CC=clang CXX=clang++] ./run_pitch_oracle.sh [--ci] [--input F]
set -euo pipefail
cd "$(dirname "$0")/../.."   # src/test -> packages/segno_engine

CC=${CC:-cc}
CXX=${CXX:-c++}
OUT="${TMPDIR:-/tmp}"
# -fmath-errno: Linux's default, and on macOS it keeps Clang from fusing a
# sinf and a cosf into Apple's sincos in one copy and not the other.
STD="-std=gnu11 -O2 -fmath-errno -DLE_NATIVE_TESTS -I src/core -I src/midi -I src/miniaudio"
case "$(uname -s)" in
  Darwin) LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lc++ -lm" ;;
  *) LIBS="-lpthread -lstdc++ -lm -ldl" ;;
esac
. src/test/engine_build.sh   # ENGINE_SRC, engine_objects, queue_compile

queue_compile "$OUT/segno_oracle_stretch.o" $CXX -std=c++17 -O2 src/stretch/le_stretch.cpp
engine_objects ENGINE_OBJS "$OUT/obj/run_pitch_oracle" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/test_pitch_oracle.c src/test/pitch_ref/pitch_ref.c \
  $ENGINE_OBJS "$OUT/segno_oracle_stretch.o" $LIBS -o "$OUT/segno_pitch_oracle.exe"
"$OUT/segno_pitch_oracle.exe" "$@"
