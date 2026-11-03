#!/usr/bin/env bash
#
# Contract gate for the macOS forwarder wiring.
#
# The macOS SPM and CocoaPods targets cannot see the engine sources under
# ../src unless each translation unit has a forwarder inside the package
# directory whose relative #include resolves. CMake and run_native_tests.sh
# compile the sources directly, and CI does not `flutter build macos`, so a
# missing or broken forwarder only shows up on a Mac: this script is the
# Linux-runnable stand-in. It also checks that the TUs outside the engine*.c
# glob stay listed in every build that links the engine.
#
# Run: bash packages/segno_engine/tool/test/run_macos_forwarder_wiring_tests.sh
set -uo pipefail

readonly HERE="$(cd "$(dirname "$0")" && pwd)"
readonly PLUGIN="$(cd "$HERE/../.." && pwd)"
readonly CMAKE="$PLUGIN/src/CMakeLists.txt"
readonly NATIVE_TESTS="$PLUGIN/src/test/run_native_tests.sh"
readonly SPM_SRC="$PLUGIN/macos/segno_engine/Sources/segno_engine"
readonly CLASSES="$PLUGIN/macos/Classes"

fails=0
pass() { echo "  ok   -- $1"; }
fail() { echo "  FAIL -- $1"; fails=$((fails + 1)); }

# Resolve the first #include "..." in $1 relative to that file; print the
# resolved path or nothing.
resolve_include() {
  local file="$1"
  local rel
  rel="$(perl -ne 'if (/#include\s+"([^"]+)"/) { print $1; exit }' "$file")"
  [ -n "$rel" ] || return 1
  local resolved
  resolved="$(cd "$(dirname "$file")" && pwd)/$rel"
  [ -f "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/segno_forwarders.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# The Signalsmith Stretch C shim (#1179) is the portable engine's one C++ TU.
# CMake compiles src/stretch/le_stretch.cpp directly; the macOS SPM and
# CocoaPods targets each need a forwarder whose relative #include resolves,
# and the shim's own include of the vendored header must resolve from src/stretch.
echo "== macOS stretch shim wiring =="
if grep -q 'stretch/le_stretch.cpp' "$CMAKE"; then
  pass "CMake lists stretch/le_stretch.cpp"
else
  fail "CMake does not list stretch/le_stretch.cpp"
fi
if grep -q 'le_stretch.cpp' "$NATIVE_TESTS"; then
  pass "run_native_tests.sh compiles the stretch shim"
else
  fail "run_native_tests.sh does not compile the stretch shim"
fi
for fwd in "$SPM_SRC/le_stretch.cpp" "$CLASSES/le_stretch.cpp"; do
  if [ -f "$fwd" ]; then
    if target="$(resolve_include "$fwd")" && [ "$(basename "$target")" = "le_stretch.cpp" ]; then
      pass "$(basename "$(dirname "$fwd")")/le_stretch.cpp forwards to src/stretch/le_stretch.cpp"
    else
      fail "$fwd does not resolve to src/stretch/le_stretch.cpp"
    fi
  else
    fail "forwarder $fwd missing"
  fi
done
if target="$(resolve_include "$PLUGIN/src/stretch/le_stretch.cpp")" && [ -n "$target" ]; then
  : # the first include is le_stretch.h; check the vendored header separately
fi
if [ -f "$PLUGIN/third_party/signalsmith-stretch/signalsmith-stretch.h" ] && \
   grep -q '"../../third_party/signalsmith-stretch/signalsmith-stretch.h"' "$PLUGIN/src/stretch/le_stretch.cpp"; then
  pass "le_stretch.cpp reaches the vendored header relatively"
else
  fail "le_stretch.cpp must include ../../third_party/signalsmith-stretch/signalsmith-stretch.h"
fi
CXX="${CXX:-c++}"
if $CXX -std=c++17 -c "$SPM_SRC/le_stretch.cpp" -o "$tmp/le_stretch_spm.o" 2>"$tmp/le_stretch_spm.err"; then
  pass "SPM le_stretch.cpp forwarder compiles with no search path"
else
  fail "SPM le_stretch.cpp forwarder should compile; $(cat "$tmp/le_stretch_spm.err")"
fi

# The pure C TUs outside the engine*.c glob are listed explicitly: the
# instrument voices (#1197) and the decoder's half-band decimator. Every
# build that compiles the engine must list them, and the macOS SPM and
# CocoaPods targets each need a forwarder that resolves.
echo "== macOS explicit TU wiring =="
readonly BUILD_TEST_LIB="$PLUGIN/tool/build_test_lib.sh"
# The two CPU benches link the real engine sources too: a TU missing from one
# breaks that bench's CI step as soon as an engine*.c file calls into it.
readonly BENCH_PITCH_TIME="$PLUGIN/src/test/bench/bench_pitch_time.sh"
readonly BENCH_INSTRUMENTS="$PLUGIN/src/test/bench/bench_instruments.sh"
for tu in synth_voice.c synth_patch.c halfband.c; do
  for list in "$CMAKE" "$NATIVE_TESTS" "$BUILD_TEST_LIB" "$BENCH_PITCH_TIME" \
              "$BENCH_INSTRUMENTS"; do
    if grep -q "core/$tu" "$list"; then
      pass "$(basename "$list") lists core/$tu"
    else
      fail "$(basename "$list") does not list core/$tu"
    fi
  done
  for fwd in "$SPM_SRC/$tu" "$CLASSES/$tu"; do
    if [ -f "$fwd" ] && target="$(resolve_include "$fwd")" && \
       [ "$target" -ef "$PLUGIN/src/core/$tu" ]; then
      pass "$(basename "$(dirname "$fwd")")/$tu forwards to src/core/$tu"
    else
      fail "forwarder $fwd missing or not resolving to src/core/$tu"
    fi
  done
done

# engine_instruments.c (#1197 Part 2a) rides the engine*.c glob in the test
# scripts, so only CMake and the two macOS forwarders list it.
if grep -q "core/engine_instruments.c" "$CMAKE"; then
  pass "CMakeLists.txt lists core/engine_instruments.c"
else
  fail "CMakeLists.txt does not list core/engine_instruments.c"
fi
for fwd in "$SPM_SRC/engine_instruments.c" "$CLASSES/engine_instruments.c"; do
  if [ -f "$fwd" ] && target="$(resolve_include "$fwd")" && \
     [ "$target" -ef "$PLUGIN/src/core/engine_instruments.c" ]; then
    pass "$(basename "$(dirname "$fwd")")/engine_instruments.c forwards to src/core/engine_instruments.c"
  else
    fail "forwarder $fwd missing or not resolving to src/core/engine_instruments.c"
  fi
done

if [ "$fails" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
fi
echo "$fails FAILED"
exit 1
