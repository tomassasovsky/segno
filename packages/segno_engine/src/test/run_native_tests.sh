#!/usr/bin/env bash
# run_native_tests.sh — build + run the native engine and MIDI unit tests.
#
# The portable engine has no audio-device dependency in these tests, so they
# compile and run on any of the desktop OSes with the host toolchain. This is
# the gate for any refactor of the engine sources: every binary must pass.
#
# It works in three phases, each spread over every CPU (#1771): compile each
# TU once per flag set (through ccache when it is installed), link the test
# binaries, then run them side by side, each in a TMPDIR of its own. The core
# suite runs as SEGNO_CORE_SHARDS processes, each taking every n-th entry of
# its main (SHARD in test_engine_core.c). A run prints one line as each test
# starts and ends, then each test's whole output; on GitHub Actions the
# passing ones fold into groups and a failing one prints last, unfolded.
# BUILD_JOBS sets how many compiles and tests run at once.
#
# The engine sources are ENGINE_SRC in engine_build.sh, which must match
# src/CMakeLists.txt's add_library list (minus the MIDI TUs, which the engine
# test does not link).
set -euo pipefail
cd "$(dirname "$0")/../.."   # src/test -> packages/segno_engine
. src/test/engine_build.sh

OUT="${TMPDIR:-/tmp}"
CC="${CC:-gcc}"
CXX="${CXX:-c++}"
# Extra compile/link flags, e.g. EXTRA_CFLAGS="-fsanitize=address -g" for the
# CI ASAN job, or EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" for the callback
# telemetry gate-off job (#722) — both of which CI runs on every PR that
# touches native code (native-tests-asan / native-tests-telemetry-off in
# .github/workflows/main.yaml). The TSAN job (native-tests-tsan, #739) also
# comes through here, but with NATIVE_TESTS_ONLY=races so only the
# concurrency binaries are built. The gate-off run MUST stay green:
# assertions that can only hold with the instrument compiled in are wrapped in
# CHECK_TIMING in test_engine_core.c, and everything outside it is asserted in
# both builds. SCOPE: only the engine + MIDI suites take these flags — the
# Darwin-only plugin scan/slot builds further down do not, so a sanitized run
# does NOT cover the plugin host C++.
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
# gnu11 (not strict c11) matches the shipped build (CMake C_STANDARD 11 with
# extensions on) and exposes the POSIX symbols the Linux MIDI backend needs
# (clock_gettime / CLOCK_MONOTONIC; strict c11 also triggers ALSA's struct
# timespec redefinition). Include path mirrors src/CMakeLists.txt: every src
# subdir holding headers, so the sources' flat `#include "x.h"` resolves.
STD="-std=gnu11 -I src/core -I src/midi -I src/miniaudio"

# The C++ runtime joins ENGINE_LIBS for the one C++ engine TU (src/stretch/
# le_stretch.cpp, the Signalsmith Stretch shim, #1179).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ENGINE_LIBS="-lole32 -lwinmm -lstdc++ -lm"; MIDI_LIBS="-lwinmm -lm" ;;
  Darwin) ENGINE_LIBS="-framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreFoundation -lpthread -lc++ -lm"
          MIDI_LIBS="-framework CoreMIDI -framework CoreFoundation -lm" ;;
  # Linux: miniaudio dlopen()s its backends; -z now mirrors the shipped
  # library's BIND_NOW (src/CMakeLists.txt), so the audio-thread fault test
  # (test_engine_rt_memory.h) runs with the binding the appliance has.
  *) ENGINE_LIBS="-lpthread -lstdc++ -lm -ldl -Wl,-z,now"; MIDI_LIBS="-lasound -lpthread -lm" ;;
esac
# MIDI_LIBS carries -lm (C1, D15): the midi test binary also links
# src/core/tempo_grid.c (le_midi_clock.c's PPQN math depends on
# le_grid_div_frames), which pulls in <math.h>. Linux's `ld` does NOT
# auto-resolve transitive shared-library symbols, so omitting it there is a
# hard link failure.

# What to build and run: NATIVE_TESTS_ONLY, a comma-separated list of
#   races  the concurrency binaries (all the TSAN job runs);
#   core   the core suite's shards; with SEGNO_CORE_PART=k/n only the shards
#          whose index is k modulo n, so n jobs run the suite between them;
#   rest   everything else: the effects matrix and equivalence, the pitch
#          oracle, the decoder fuzz driver and the MIDI suite.
# Unset, it is all three. (The ASan job runs as such parts, #1771.)
WANT_CORE=0 WANT_REST=0 WANT_RACES=0
for part in $(printf '%s' "${NATIVE_TESTS_ONLY:-races,core,rest}" | tr ',' ' '); do
  case "$part" in
    races) WANT_RACES=1 ;;
    core) WANT_CORE=1 ;;
    rest) WANT_REST=1 ;;
    *) echo "NATIVE_TESTS_ONLY takes races, core and rest (got $part)" >&2; exit 2 ;;
  esac
done
CORE_PART="${SEGNO_CORE_PART:-0/1}"
CORE_PART_K=${CORE_PART%/*} CORE_PART_N=${CORE_PART#*/}
if ! [ "$CORE_PART_N" -ge 1 ] 2>/dev/null || ! [ "$CORE_PART_K" -ge 0 ] 2>/dev/null ||
    [ "$CORE_PART_K" -ge "$CORE_PART_N" ]; then
  echo "SEGNO_CORE_PART must be k/n with 0 <= k < n" >&2
  exit 2
fi
WINDOWS=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;; esac
CORE_SHARDS="${SEGNO_CORE_SHARDS:-$((BUILD_JOBS * 2 * CORE_PART_N))}"

# Every entry of the core suite's main must go through SHARD, or the shards
# would each run it (a bare call is not lost, but runs once per shard). The
# one direct call is the SEGNO_FADE_STAGING_TESTS_ONLY local tool's.
bare=$(awk '/^int main\(void\) \{/ { inmain = 1; next }
  inmain && /^}/ { exit }
  inmain && /_TESTS_ONLY"\)\) \{/ { skip = 1; next }
  inmain && /^[ \t]+[a-z_0-9]+\(\);$/ { if (skip) { skip = 0; next } print }
  { skip = 0 }' src/test/test_engine_core.c)
if [ -n "$bare" ]; then
  echo "test_engine_core.c main() calls these without SHARD(...):" >&2
  echo "$bare" >&2
  exit 1
fi

OBJ="$OUT/segno_native_obj"
F0="$STD $EXTRA_CFLAGS"
F1="$STD $EXTRA_CFLAGS -DLE_NATIVE_TESTS"

echo "== compiling (${BUILD_JOBS} at a time${CCACHE:+, through ccache}) =="
# The stretch shim (#1179) is the only C++ TU in the portable engine: the C
# ABI over the vendored Signalsmith Stretch. It cannot take the C flags
# (gnu11 is C-only), so it is compiled with $CXX and linked into every engine
# binary. Mirrors src/CMakeLists.txt's stretch/le_stretch.cpp entry and
# tool/build_test_lib.sh — keep in sync.
STRETCH_OBJ="$OBJ/le_stretch.o"
queue_compile "$STRETCH_OBJ" $CXX -std=c++17 -O2 $EXTRA_CFLAGS src/stretch/le_stretch.cpp
if [ "$WANT_RACES" = 1 ] || [ "$WANT_REST" = 1 ]; then
  engine_objects E0 "$OBJ/e0" $CC $F0
fi
# The test hooks build (LE_NATIVE_TESTS): the core suite and the recipe
# ownership test.
if [ "$WANT_CORE" = 1 ] || [ "$WANT_RACES" = 1 ]; then
  engine_objects E1 "$OBJ/e1" $CC $F1
fi
if [ "$WANT_RACES" = 1 ]; then
  for t in test_engine_races test_plugin_runtime_races test_fx_tables_races \
      test_instrument_races test_midi_sink_races test_perf_drain_races \
      test_backing_races test_fx_workers_races; do
    queue_compile "$OBJ/$t.o" $CC $F0 "src/test/$t.c"
  done
  queue_compile "$OBJ/test_fx_recipe_plugins.o" $CC $F1 src/test/test_fx_recipe_plugins.c
fi
if [ "$WANT_CORE" = 1 ]; then
  queue_compile "$OBJ/test_engine_core.o" $CC $F1 src/test/test_engine_core.c
fi
if [ "$WANT_REST" = 1 ]; then
  # The effects matrix and the pitch oracle are built -O2 (as the shipped
  # library is) whatever the suite's own flags, -O2 last so it wins. The
  # oracle adds -fmath-errno, Linux's default, also on macOS, where without
  # it Clang may fuse a sinf and a cosf into Apple's sincos in one copy and
  # not the other.
  F2="$STD $EXTRA_CFLAGS -O2"
  F3="$STD $EXTRA_CFLAGS -O2 -fmath-errno -DLE_NATIVE_TESTS"
  if [ "$WINDOWS" = 0 ]; then
    engine_objects E2 "$OBJ/e2" $CC $F2
    queue_compile "$OBJ/bench_fx_matrix.o" $CC $F2 src/test/bench/bench_fx_matrix.c
  fi
  engine_objects E3 "$OBJ/e3" $CC $F3
  queue_compile "$OBJ/test_pitch_oracle.o" $CC $F3 src/test/test_pitch_oracle.c
  queue_compile "$OBJ/pitch_ref.o" $CC $F3 src/test/pitch_ref/pitch_ref.c
  # The decoder fuzz driver takes FUZZ_CFLAGS on top (the ASan job passes
  # UBSan here), engine included.
  F4="$STD $EXTRA_CFLAGS ${FUZZ_CFLAGS:-}"
  if [ -n "${FUZZ_CFLAGS:-}" ]; then
    engine_objects E4 "$OBJ/e4" $CC $F4
  else
    E4=$E0
  fi
  queue_compile "$OBJ/fuzz_backing_decode.o" $CC $F4 src/test/fuzz_backing_decode.c
  for src in src/test/test_midi_core.c src/midi/midi.c src/midi/midi_backend_linux.c \
      src/midi/midi_backend_apple.c src/midi/le_midi_clock.c src/midi/le_clock_follow.c \
      src/core/tempo_grid.c; do
    queue_compile "$OBJ/midi/$(engine_object_name "$src")" $CC $F0 "$src"
  done
fi
run_queue

echo "== linking =="
L=()
lnk() { local exe=$1; shift; L+=("$CC $* -o $OUT/$exe"); }
if [ "$WANT_RACES" = 1 ]; then
  # The telemetry race tests (#739) build from the header-only telemetry alone.
  lnk segno_race_tests.exe $F0 "$OBJ/test_engine_races.o" -lpthread -lm
  # Real installer and DSP, with a minimal fake host.
  lnk segno_plugin_runtime_race_tests.exe $F0 "$OBJ/test_plugin_runtime_races.o" \
    "$OBJ/e0/$(engine_object_name src/core/engine_plugin.c)" \
    "$OBJ/e0/$(engine_object_name src/core/engine_fx.c)" \
    "$OBJ/e0/$(engine_object_name src/core/rt_alloc.c)" -lpthread -lm
  # Two threads prepare the process's first octaver at once (#1410). Its own
  # binary, since the tables are built once per process.
  lnk segno_fx_tables_race_tests.exe $F0 "$OBJ/test_fx_tables_races.o" \
    "$OBJ/e0/$(engine_object_name src/core/engine_fx.c)" \
    "$OBJ/e0/$(engine_object_name src/core/rt_alloc.c)" -lpthread -lm
  # Real engine admission, callback publication and retirement with a
  # deterministic plugin host, so the test hooks build without the disabled
  # plugin stub.
  plugin_stub="$OBJ/e1/$(engine_object_name src/core/plugin_disabled.c)"
  RECIPE_OBJS=""
  for o in $E1; do [ "$o" = "$plugin_stub" ] || RECIPE_OBJS="$RECIPE_OBJS $o"; done
  lnk segno_fx_recipe_tests.exe $F1 "$OBJ/test_fx_recipe_plugins.o" $RECIPE_OBJS \
    "$STRETCH_OBJ" $ENGINE_LIBS
  # A control thread posting note pairs against a hot-looping drain (#1197);
  # the MIDI input sink against the real engine (#1228 Part 1; it needs no OS
  # MIDI backend, so the TSAN job's missing libasound does not matter); the
  # drain thread rolling parts (#1198); the backing player's buffer handoff
  # (#1200); the effects workers.
  for t in instrument midi_sink perf_drain backing fx_workers; do
    lnk "segno_${t}_race_tests.exe" $F0 "$OBJ/test_${t}_races.o" $E0 \
      "$STRETCH_OBJ" $ENGINE_LIBS
  done
fi
if [ "$WANT_CORE" = 1 ]; then
  lnk segno_core_tests.exe $F1 "$OBJ/test_engine_core.o" $E1 "$STRETCH_OBJ" $ENGINE_LIBS
fi
if [ "$WANT_REST" = 1 ]; then
  if [ "$WINDOWS" = 0 ]; then
    lnk segno_fx_matrix.exe $F2 "$OBJ/bench_fx_matrix.o" $E2 "$STRETCH_OBJ" $ENGINE_LIBS
  fi
  lnk segno_pitch_oracle.exe $F3 "$OBJ/test_pitch_oracle.o" "$OBJ/pitch_ref.o" $E3 \
    "$STRETCH_OBJ" $ENGINE_LIBS
  lnk segno_fuzz_decode.exe $F4 "$OBJ/fuzz_backing_decode.o" $E4 "$STRETCH_OBJ" $ENGINE_LIBS
  midi_objs=""
  for src in src/test/test_midi_core.c src/midi/midi.c src/midi/midi_backend_linux.c \
      src/midi/midi_backend_apple.c src/midi/le_midi_clock.c src/midi/le_clock_follow.c \
      src/core/tempo_grid.c; do
    midi_objs="$midi_objs $OBJ/midi/$(engine_object_name "$src")"
  done
  lnk segno_midi_tests.exe $F0 $midi_objs $MIDI_LIBS
fi
printf '%s\0' "${L[@]}" | run_commands

# --- Run ---------------------------------------------------------------------
# Each test gets a TMPDIR of its own, so two processes never share a scratch
# file. Longest first, so the slowest one starts at once.
RUN_DIR="$OUT/segno_native_runs"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
TESTS=()
add_test() { TESTS+=("$1" "$2"); }
CORE_RUN=()   # the core shards this run takes
if [ "$WANT_CORE" = 1 ]; then
  for ((i = CORE_PART_K; i < CORE_SHARDS; i += CORE_PART_N)); do
    CORE_RUN+=("$i")
    add_test "core-$i-of-$CORE_SHARDS" \
      "SEGNO_TEST_TOTAL_SHARDS=$CORE_SHARDS SEGNO_TEST_SHARD_INDEX=$i $OUT/segno_core_tests.exe"
  done
fi
if [ "$WANT_REST" = 1 ]; then
  # Every effect kind at every sample rate and block size (#1547), one setting
  # a kind (--ci); the full run over every factory setting is the bench,
  # src/test/bench/bench_fx_matrix.sh. Its known failures are listed in the
  # source and do not fail the run; a new one, or a listed one past its
  # ceiling, does. It needs the POSIX bench helpers, so not on Windows.
  if [ "$WINDOWS" = 0 ]; then
    add_test fx-matrix "$OUT/segno_fx_matrix.exe --ci"
    # Every kind against the reference engine's render (#1755): the kernels
    # are made cheaper without changing their sound. The full run is the
    # bench, src/test/bench/bench_fx_equiv.sh. The telemetry gate does not
    # reach the effects, so its job leaves this to the plain one.
    case "$EXTRA_CFLAGS" in
      *LE_CALLBACK_TELEMETRY=0*) ;;
      *) add_test fx-equiv "CC='$CC' FX_EQUIV_OUT='$OUT/segno_fx_equiv' bash src/test/bench/bench_fx_equiv.sh --ci" ;;
    esac
  fi
  # The pitch kinds against their kernels before #1755 (test_pitch_oracle.c,
  # test/pitch_ref/pitch_ref.c): every case must render bit-identically on the
  # live kernels and the frozen ones.
  add_test pitch-oracle "$OUT/segno_pitch_oracle.exe --ci"
  # The app's audio-file decoder over whole-file mutations of every accepted
  # and refused format (#1200): a bounded, fixed-seed run in every
  # configuration, so the ASan job fuzzes it on every run. SEGNO_FUZZ_ITERATIONS
  # and SEGNO_FUZZ_SEED widen a local run.
  add_test fuzz-decode "$OUT/segno_fuzz_decode.exe"
fi
# The race binaries run in every configuration (their handshakes are
# functional properties TSAN cannot check); the TSAN job runs only these.
if [ "$WANT_RACES" = 1 ]; then
  for t in fx_workers instrument midi_sink perf_drain backing fx_recipe; do
    case "$t" in
      fx_recipe) add_test "$t" "$OUT/segno_fx_recipe_tests.exe" ;;
      *) add_test "$t-races" "$OUT/segno_${t}_race_tests.exe" ;;
    esac
  done
  add_test telemetry-races "$OUT/segno_race_tests.exe"
  add_test plugin-runtime-races "$OUT/segno_plugin_runtime_race_tests.exe"
  add_test fx-tables-races "$OUT/segno_fx_tables_race_tests.exe"
fi
[ "$WANT_REST" = 1 ] && add_test midi "$OUT/segno_midi_tests.exe"

run_test() {   # run_test NAME COMMAND — one test, its output to NAME.log
  local name=$1 cmd=$2 status=passed rc=0 times
  mkdir -p "$RUN_DIR/$name"
  echo "== $name started =="
  # Wall and CPU seconds: CPU well under wall times the CPUs running means
  # the test waited, on a lock, a sleep or a busy machine.
  local TIMEFORMAT='%0R s, CPU %0U s user + %0S s system'
  { time TMPDIR="$RUN_DIR/$name" bash -c "$cmd" >"$RUN_DIR/$name.log" 2>&1 || rc=$?; } 2>"$RUN_DIR/$name.time"
  times=$(cat "$RUN_DIR/$name.time")
  if [ "$rc" != 0 ]; then
    status=FAILED
    : >"$RUN_DIR/$name.failed"
  fi
  echo "== $name $status in $times =="
}
export -f run_test
export RUN_DIR
echo "== running $((${#TESTS[@]} / 2)) tests, ${BUILD_JOBS} at a time =="
printf '%s\0' "${TESTS[@]}" | xargs -0 -n 2 -P "$BUILD_JOBS" bash -c 'run_test "$0" "$1"'

failed=""
for ((i = 0; i < ${#TESTS[@]}; i += 2)); do
  name=${TESTS[i]}
  if [ -e "$RUN_DIR/$name.failed" ]; then
    failed="$failed $name"
    continue
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$name (passed)"; else echo "== $name (passed) =="; fi
  cat "$RUN_DIR/$name.log"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::"
done
for name in $failed; do
  echo "== $name FAILED; its output: =="
  cat "$RUN_DIR/$name.log"
done
# Every shard this run took must have run to its end and taken its entries
# of main: entry p belongs to shard p mod CORE_SHARDS. With every part, that
# is every entry, each once.
if [ "$WANT_CORE" = 1 ]; then
  ran=$(cat "$RUN_DIR"/core-*.log | sed -n 's/^shard [0-9]* of [0-9]*: \([0-9]*\) of \([0-9]*\) entries$/\1 \2/p' |
    awk '{ ran += $1; total = $2; n++ } END { print n, ran, total }')
  read -r shards_seen entries_ran entries_total <<<"$ran"
  expected=0
  for i in "${CORE_RUN[@]}"; do
    expected=$((expected + (entries_total - i + CORE_SHARDS - 1) / CORE_SHARDS))
  done
  if [ "$shards_seen" != "${#CORE_RUN[@]}" ] || [ "$entries_ran" != "$expected" ]; then
    echo "core shards: $shards_seen of ${#CORE_RUN[@]} reported, $entries_ran of their $expected entries ran" >&2
    failed="$failed core-shard-coverage"
  fi
fi
if [ -n "$failed" ]; then
  echo "FAILED:$failed" >&2
  exit 1
fi
echo "== all $((${#TESTS[@]} / 2)) native tests passed =="

# --- Plugin scan tests (macOS only) ----------------------------------------
# Plugin hosting is macOS-first (SEGNO_ENABLE_PLUGINS). This compiles the scan
# ABI + backends against the vendored VST3/CLAP SDKs and exercises the
# per-candidate failed-entry guard with a controlled fixture (no real plugin
# install needed). Skipped on Windows/Linux until the ports (parts 8–9), and
# with rest not selected.
if [ "$(uname -s)" = "Darwin" ] && [ "$WANT_REST" = 1 ]; then
  echo "== building plugin scan tests =="
  CXX="${CXX:-clang++}"
  PLUGIN_INC="-Ithird_party/vst3sdk -Ithird_party/clap/include -Isrc/core -Isrc/host"
  # shellcheck disable=SC2086
  $CXX -std=c++17 -DSEGNO_ENABLE_PLUGINS $PLUGIN_INC \
    src/test/test_plugin_scan.cpp \
    src/host/plugin_scan.cpp src/host/scan_vst3.cpp src/host/scan_clap.cpp \
    third_party/vst3sdk/pluginterfaces/base/coreiids.cpp \
    -framework CoreFoundation \
    -o "$OUT/segno_plugin_scan_tests.exe"
  "$OUT/segno_plugin_scan_tests.exe"

  # Slot lifecycle / adapter / sanitize, driven end-to-end through the real
  # fx_apply_chain (engine_fx.c — the self-contained DSP island) with a stub
  # host. C engine TUs and C++ host TUs are compiled separately, then linked.
  echo "== building plugin slot tests =="
  P3="$OUT/segno_p3_obj"
  mkdir -p "$P3"
  CENGINE_INC="-Isrc/core -Isrc/midi -Isrc/miniaudio -Isrc/host"
  clang -std=gnu11 -DSEGNO_ENABLE_PLUGINS $CENGINE_INC \
    -c src/test/test_plugin_slot.c -o "$P3/test.o"
  clang -std=gnu11 -DSEGNO_ENABLE_PLUGINS $CENGINE_INC \
    -c src/core/engine_fx.c -o "$P3/engine_fx.o"
  clang -std=gnu11 -DSEGNO_ENABLE_PLUGINS $CENGINE_INC \
    -c src/core/rt_alloc.c -o "$P3/rt_alloc.o"
  clang -std=gnu11 -DSEGNO_ENABLE_PLUGINS $CENGINE_INC \
    -c src/core/engine_plugin.c -o "$P3/engine_plugin.o"
  # shellcheck disable=SC2086
  for cxx in slot host_clap host_vst3 plugin_scan scan_vst3 scan_clap; do
    $CXX -std=c++17 -DSEGNO_ENABLE_PLUGINS $PLUGIN_INC \
      -c "src/host/$cxx.cpp" -o "$P3/$cxx.o"
  done
  # The host-owned editor NSWindow (ObjC++, part 6) — links AppKit/Foundation.
  $CXX -std=c++17 -DSEGNO_ENABLE_PLUGINS $PLUGIN_INC \
    -c src/host/native_window_controller.mm \
    -o "$P3/native_window_controller.o"
  $CXX -std=c++17 -DSEGNO_ENABLE_PLUGINS -Ithird_party/vst3sdk \
    -c third_party/vst3sdk/pluginterfaces/base/coreiids.cpp -o "$P3/coreiids.o"
  $CXX -std=c++17 -DSEGNO_ENABLE_PLUGINS -Ithird_party/vst3sdk \
    -c third_party/vst3sdk/public.sdk/source/vst/vstinitiids.cpp \
    -o "$P3/vstinitiids.o"
  # GUI IIDs (IPlugView / IPlugFrame) for the editor view interfaces (part 6).
  $CXX -std=c++17 -DSEGNO_ENABLE_PLUGINS -Ithird_party/vst3sdk \
    -c third_party/vst3sdk/public.sdk/source/common/commoniids.cpp \
    -o "$P3/commoniids.o"
  # shellcheck disable=SC2086
  $CXX "$P3"/*.o -framework CoreFoundation -framework AppKit \
    -framework Foundation \
    -o "$OUT/segno_plugin_slot_tests.exe"
  "$OUT/segno_plugin_slot_tests.exe"
fi
