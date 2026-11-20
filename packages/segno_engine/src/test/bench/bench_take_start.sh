#!/usr/bin/env bash
# Build and run the take-start bench (#1914): what starting and closing a
# take costs the audio callback, with no sound card (bench_take_start.c).
#   ./bench_take_start.sh [--rate HZ] [--period N] [--record S] [--takes N] [--no-racks]
# OUT_DIR, CC, CXX and EXTRA_CFLAGS as for bench_fx_parallel.sh.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
CXX=${CXX:-c++}
OUT_DIR="${OUT_DIR:-build/bench}"
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
echo "== building bench_take_start ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_take_start" $CC $STD ${EXTRA_CFLAGS:-}
run_queue
# shellcheck disable=SC2086
$CC $STD ${EXTRA_CFLAGS:-} src/test/bench/bench_take_start.c $ENGINE_OBJS "$OUT_DIR/le_stretch.o" \
  $LIBS ${STATIC:+-static} -o "$OUT_DIR/bench_take_start"
case "$OUT_DIR" in
  /*) BIN="$OUT_DIR/bench_take_start" ;;
  *) BIN="$(pwd)/$OUT_DIR/bench_take_start" ;;
esac
echo "binary: $BIN" >&2

"$BIN" "$@"
