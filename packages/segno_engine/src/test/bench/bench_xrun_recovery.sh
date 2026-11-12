#!/usr/bin/env bash
# Build the xrun recovery bench (#1516). NOT part of the test gate: it needs
# the console's real sound card. Build it on any Linux host the same way.
#
# Links the real engine sources (the source list and link flags mirror
# run_native_tests.sh and src/CMakeLists.txt, including BIND_NOW).
#
# On the console, with the app stopped (the bench needs the sound card):
#   systemctl stop segno.service
#   ./bench_xrun_recovery --playback :2,0 --capture :2,0     # 48 kHz / 32
#   ./bench_xrun_recovery --playback :2,0 --capture :2,0 \
#       --rate 96000 --period 64                             # 96 kHz / 64
#   ./bench_xrun_recovery --playback :2,0 --capture :2,0 \
#       --duty 1 --stalls 5,20,100,250 --repeats 1           # solid stalls
#   systemctl start segno.service
# (--list prints the device ids.) Each run overloads the callback thread for
# 10 s, eight times: a SCHED_FIFO spinner on its CPU, above it and below the
# sound card's IRQ thread, takes 95 % of every period, the way a too-heavy
# effects chain does. Exit status 0: after every overload the duplex loop is
# processing audio again with playback RUNNING (and every solid stall longer
# than twice the ring was counted as an xrun).
# The bench sets SEGNO_ALSA_PERIODS=8 like segno-kiosk-launch, unless the
# environment already sets it.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # src/test/bench -> packages/segno_engine

CC=${CC:-cc}
CXX=${CXX:-c++}
OUT_DIR="build/bench"
mkdir -p "$OUT_DIR"
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/miniaudio"
LIBS="-lpthread -lstdc++ -lm -ldl -Wl,-z,now"

. src/test/engine_build.sh   # ENGINE_SRC, engine_objects, queue_compile

echo "== building the stretch shim ==" >&2
queue_compile "$OUT_DIR/le_stretch_xr.o" $CXX -std=c++17 -O2 -DNDEBUG src/stretch/le_stretch.cpp
echo "== building bench_xrun_recovery ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_xrun_recovery" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_xrun_recovery.c $ENGINE_OBJS "$OUT_DIR/le_stretch_xr.o" \
  $LIBS -o "$OUT_DIR/bench_xrun_recovery"
echo "binary: $(pwd)/$OUT_DIR/bench_xrun_recovery" >&2
