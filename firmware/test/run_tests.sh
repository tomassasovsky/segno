#!/usr/bin/env bash
# Builds the console sketch's CTRL behavior test and pedal-link contract test:
# the latter runs the console board firmware's
# pedal_link.c against the golden fixtures packages/pedal_repository generates
# from the Dart codec. Regenerate the fixtures after changing golden_frames.dart:
#   (cd packages/pedal_repository && flutter test tool/generate_golden_fixtures.dart)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CC="${CC:-cc}"
CXX="${CXX:-c++}"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/segno_firmware_tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
"$CC" -std=c99 -Wall -Wextra -Werror -O1 \
  -o "$OUT/pedal_link" \
  "$ROOT/firmware/libraries/SegnoPanel/src/pedal_link.c" \
  "$ROOT/firmware/test/test_pedal_link.c"
"$OUT/pedal_link" "$ROOT/packages/pedal_repository/test/fixtures"
"$CC" -std=c99 -Wall -Wextra -Werror -O1 -c \
  "$ROOT/firmware/libraries/SegnoPanel/src/pedal_link.c" -o "$OUT/pedal_link.o"
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  -I "$ROOT/firmware/test/stubs" -I "$ROOT/firmware/libraries/SegnoPanel/src" \
  "$ROOT/firmware/test/test_console_ctrl.cpp" "$OUT/pedal_link.o" \
  -o "$OUT/console_ctrl"
"$OUT/console_ctrl"
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  -I "$ROOT/firmware/test/stubs" -I "$ROOT/firmware/libraries/SegnoPanel/src" \
  "$ROOT/firmware/test/test_console_presence.cpp" -o "$OUT/console_presence"
"$OUT/console_presence"
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  -I "$ROOT/firmware/test/stubs" -I "$ROOT/firmware/libraries/SegnoPanel/src" \
  "$ROOT/firmware/test/test_console_pd.cpp" "$OUT/pedal_link.o" -o "$OUT/console_pd"
"$OUT/console_pd"
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  -I "$ROOT/firmware/libraries/SegnoPanel/src" \
  "$ROOT/firmware/test/test_ring_link.cpp" -o "$OUT/ring_link"
"$OUT/ring_link"
for sketch_test in console_panel ring_board; do
  "$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
    -I "$ROOT/firmware/test/stubs" -I "$ROOT/firmware/libraries/SegnoPanel/src" \
    "$ROOT/firmware/test/test_${sketch_test}.cpp" "$OUT/pedal_link.o" -o "$OUT/$sketch_test"
  "$OUT/$sketch_test"
done
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  -I "$ROOT/firmware/test/stubs" "$ROOT/firmware/test/test_pill_chain.cpp" \
  -o "$OUT/pill_chain"
"$OUT/pill_chain"
