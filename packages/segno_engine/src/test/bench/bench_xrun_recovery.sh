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
$CXX -std=c++17 -O2 -DNDEBUG -c src/stretch/le_stretch.cpp -o "$OUT_DIR/le_stretch_xr.o"
echo "== building bench_xrun_recovery ==" >&2
# shellcheck disable=SC2086
$CC $STD src/test/bench/bench_xrun_recovery.c $ENGINE_SRC "$OUT_DIR/le_stretch_xr.o" \
  $LIBS -o "$OUT_DIR/bench_xrun_recovery"
echo "binary: $(pwd)/$OUT_DIR/bench_xrun_recovery" >&2
