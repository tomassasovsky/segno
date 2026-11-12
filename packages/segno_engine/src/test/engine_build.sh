# engine_build.sh — sourced, not run: the portable engine's source list and a
# parallel, cached compile for the scripts that build it outside CMake
# (run_native_tests.sh, run_pitch_oracle.sh, the benches, the test library).
# The caller has already changed into packages/segno_engine. (#1771)
#
# ENGINE_SRC is the one copy of the engine's C sources these scripts link:
# every engine TU (core/ incl. the miniaudio backend, the platform/ seams,
# the miniaudio impl) plus the pure DSP TUs that sit outside the engine*.c
# glob on purpose (halfband.c, the synth_*.c instrument voices, #1197) and
# src/midi/le_midi_clock.c and le_clock_follow.c, which ARE engine
# dependencies (engine_process.c calls le_midi_clock_advance every block)
# despite living in midi/. It mirrors src/CMakeLists.txt's library sources
# minus the other MIDI TUs; keep the two in sync.
ENGINE_SRC="src/core/engine*.c src/core/lockfree_ring.c src/core/loop_clock.c \
  src/core/tempo_grid.c \
  src/core/halfband.c \
  src/core/synth_voice.c src/core/synth_patch.c \
  src/core/audio_ring.c src/core/rt_alloc.c src/core/perf_drain.c src/core/perf_checkpoint.c src/core/perf_log_ring.c src/core/layer_staging_ring.c src/core/json_read.c src/core/perf_render.c src/core/plugin_disabled.c \
  src/platform/engine_*.c src/miniaudio/miniaudio_impl.c src/midi/le_midi_clock.c \
  src/midi/le_clock_follow.c"

# How many compiles (and, in run_native_tests.sh, test processes) run at once:
# one per CPU unless BUILD_JOBS says otherwise.
BUILD_JOBS="${BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

# ccache when it is installed, so a TU that has not changed is not compiled
# again: locally across runs, in CI within one job (its cache is not kept
# between CI runs, #1787). CCACHE= turns it off.
if [ -z "${CCACHE+set}" ]; then
  CCACHE="$(command -v ccache || true)"
fi

BUILD_QUEUE=()

# queue_compile OBJ COMPILER FLAGS... SRC: queues `COMPILER FLAGS -c SRC -o OBJ`.
queue_compile() {
  local obj=$1
  shift
  local n=$#
  local src=${!n}
  mkdir -p "$(dirname "$obj")"
  # Each word quoted, so run_commands' eval hands the compiler exactly the
  # words it was given here.
  # shellcheck disable=SC2086
  BUILD_QUEUE+=("$(printf '%q ' $CCACHE "${@:1:n-1}" -c "$src" -o "$obj")")
}

# engine_objects VAR DIR COMPILER FLAGS...: queues each TU of ENGINE_SRC,
# compiled with COMPILER FLAGS into DIR, and sets VAR to the objects in
# ENGINE_SRC order. Linking them in that order gives the binary the
# one-command build (`$CC FLAGS main.c $ENGINE_SRC ...`) gave, which also
# compiles each TU on its own.
engine_objects() {
  local var=$1 dir=$2
  shift 2
  local objs="" src obj
  # shellcheck disable=SC2086
  for src in $ENGINE_SRC; do
    obj="$dir/$(engine_object_name "$src")"
    objs="$objs $obj"
    queue_compile "$obj" "$@" "$src"
  done
  printf -v "$var" '%s' "${objs# }"
}

# engine_object_name SRC: the file engine_objects writes SRC's object to.
engine_object_name() {
  printf '%s.o' "$(printf '%s' "$1" | tr '/' '_')"
}

# run_queue: runs the queued compiles BUILD_JOBS at a time and empties the
# queue; fails if any compile fails.
run_queue() {
  [ "${#BUILD_QUEUE[@]}" -gt 0 ] || return 0
  printf '%s\0' "${BUILD_QUEUE[@]}" | run_commands
  BUILD_QUEUE=()
}

# run_commands: runs the NUL-separated shell commands on stdin (each word
# already quoted for the shell), BUILD_JOBS at a time; fails if any of them
# fails. Their output goes straight through.
run_commands() {
  xargs -0 -n 1 -P "$BUILD_JOBS" bash -c 'eval "$0"'
}
