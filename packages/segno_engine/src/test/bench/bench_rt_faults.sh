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
STD="-std=gnu11 -O2 -DNDEBUG -I src/core -I src/midi -I src/miniaudio \
  -I third_party/rnnoise/include -I third_party/rnnoise/src"
LIBS="-lpthread -lstdc++ -lm -ldl -Wl,-z,now"

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
$CXX -std=c++17 -O2 -DNDEBUG -c src/stretch/le_stretch.cpp -o "$OUT_DIR/le_stretch_rt.o"
echo "== building bench_rt_faults ==" >&2
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_rt_faults.c $ENGINE_SRC "$OUT_DIR/le_stretch_rt.o" \
  $LIBS -o "$OUT_DIR/bench_rt_faults"
echo "binary: $(pwd)/$OUT_DIR/bench_rt_faults" >&2
