#!/usr/bin/env bash
# Runs the null test and the binding test (with the editors) from a build
# tree against a built or installed Segno.vst3 that carries its pedal faces.
#
#   bash packages/segno_engine/vst3/test/run_bundle_tests.sh <build tree> <Segno.vst3>
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
build="$1"
bundle="$2"
"$build/segno_vst3_null_test" "$bundle"
"$build/segno_vst3_binding_test" "$bundle" "$here/faces/faces.json" \
  "$here/test/value_texts.json" --editors
