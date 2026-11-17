#!/usr/bin/env bash
# Builds Segno.vst3, its null test and its binding test (Release, clang) and
# runs them: every plugin against the engine's offline render, bit for bit,
# and every control of the editors' layout against its plugin's parameters.
# CI runs this on Linux in the native-tests job; on the Mac, install.sh
# --test does the same against the installed bundle.
#
#   bash packages/segno_engine/vst3/test/run_null_test.sh [null test args]
#
# The build tree is packages/segno_engine/build/vst3-test (or VST3_TEST_OUT).
# It holds no pedal faces, so no plugin opens an editor.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
build="${VST3_TEST_OUT:-$here/../build/vst3-test}"
CC="${CC:-clang}" CXX="${CXX:-clang++}" \
  cmake -S "$here" -B "$build" -DCMAKE_BUILD_TYPE=Release -DSEGNO_VST3_FACES= >/dev/null
cmake --build "$build" --parallel
"$build/segno_vst3_binding_test" "$build/Segno.vst3" "$here/faces/faces.json" \
  "$here/test/value_texts.json"
"$build/segno_vst3_null_test" "$build/Segno.vst3" "$@"
