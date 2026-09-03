#!/usr/bin/env bash
# Builds and runs the pedal-link contract test: the console board firmware's
# pedal_link.c against the golden fixtures packages/pedal_repository generates
# from the Dart codec. Regenerate the fixtures after changing golden_frames.dart:
#   (cd packages/pedal_repository && flutter test tool/generate_golden_fixtures.dart)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CC="${CC:-cc}"
OUT="${TMPDIR:-/tmp}/segno_pedal_link_test.$$"
"$CC" -std=c99 -Wall -Wextra -Werror -O1 \
  -o "$OUT" \
  "$ROOT/firmware/console_board/pedal_link.c" \
  "$ROOT/firmware/test/test_pedal_link.c"
trap 'rm -f "$OUT"' EXIT
"$OUT" "$ROOT/packages/pedal_repository/test/fixtures"
