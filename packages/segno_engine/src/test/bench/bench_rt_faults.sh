#!/usr/bin/env bash
# Build the audio-thread fault bench (#900, #906, #1367). NOT part of the test
# gate: it needs the console's real sound card. CI's native-bench-arm64 job
# builds it and uploads the binary for the appliance; build it on any Linux
# host the same way.
#
# Links the real engine sources (the source list and link flags mirror
# run_native_tests.sh and src/CMakeLists.txt, including BIND_NOW).
#
# On the console, with the app stopped (the bench needs the sound card):
#   systemctl stop segno.service
#   ./bench_rt_faults --seconds 300                 # the app as shipped: no forks
#   ./bench_rt_faults --seconds 300 --period 32     # the 333 us deadline
#   ./bench_rt_faults --seconds 120 --fork-ms 50    # the backstop, forced forks
#   ./bench_rt_faults --seconds 120 --trace-late    # which action came before
#                                                    # each late period (#1410)
#   ./bench_rt_faults --seconds 120 --fx-types 3,7,6  # FX flips without the
#                                                    # octaver (le_fx_type ids)
#   systemctl start segno.service
# Exit status 0: with no forks, no page fault and no late period on the
# callback thread and no xrun of any kind in the window (each one is an
# audible dropout, wherever the time went); with forks, at most
# --max-faults-per-fork (16) faults per fork (its stack and alsa-lib/miniaudio
# pages; see bench_rt_faults.c), with late periods and xruns reported only. A
# window with fewer than half its expected periods fails either way (an empty
# window proves nothing). --warmup must be less than --seconds; the window is
# the time between them.
# The bench sets SEGNO_ALSA_PERIODS=8 like segno-kiosk-launch, unless the
# environment already sets it.
# --list prints the device ids for --playback / --capture.
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
queue_compile "$OUT_DIR/le_stretch_rt.o" $CXX -std=c++17 -O2 -DNDEBUG src/stretch/le_stretch.cpp
echo "== building bench_rt_faults ==" >&2
engine_objects ENGINE_OBJS "$OUT_DIR/obj/bench_rt_faults" $CC $STD
run_queue
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_rt_faults.c $ENGINE_OBJS "$OUT_DIR/le_stretch_rt.o" \
  $LIBS -o "$OUT_DIR/bench_rt_faults"
echo "binary: $(pwd)/$OUT_DIR/bench_rt_faults" >&2
