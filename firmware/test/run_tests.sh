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
  "$ROOT/firmware/console_board/pedal_link.c" \
  "$ROOT/firmware/test/test_pedal_link.c"
"$OUT/pedal_link" "$ROOT/packages/pedal_repository/test/fixtures"
"$CC" -std=c99 -Wall -Wextra -Werror -O1 -c \
  "$ROOT/firmware/console_board/pedal_link.c" -o "$OUT/pedal_link.o"
"$CC" -std=c99 -Wall -Wextra -Werror -O1 -c \
  "$ROOT/firmware/console_board/pd_trigger.c" -o "$OUT/pd_trigger.o"
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 -I "$ROOT/firmware/console_board" \
  "$ROOT/firmware/test/test_pd_trigger.cpp" "$OUT/pd_trigger.o" -o "$OUT/pd_trigger"
"$OUT/pd_trigger"
RING_INC=(-I "$ROOT/firmware/test/stubs" -I "$ROOT/firmware/libraries/SegnoRing/src")
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  "${RING_INC[@]}" \
  "$ROOT/firmware/test/test_console_ctrl.cpp" "$OUT/pedal_link.o" "$OUT/pd_trigger.o" \
  -o "$OUT/console_ctrl"
"$OUT/console_ctrl"

"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  "${RING_INC[@]}" \
  -I "$ROOT/firmware/console_board" \
  "$ROOT/firmware/test/test_console_pill.cpp" "$OUT/pedal_link.o" "$OUT/pd_trigger.o" \
  -o "$OUT/console_pill"
"$OUT/console_pill"

"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  "${RING_INC[@]}" -I "$ROOT/firmware/ring_board" \
  "$ROOT/firmware/test/test_ring_board.cpp" -o "$OUT/ring_board"
"$OUT/ring_board"

"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  "${RING_INC[@]}" \
  "$ROOT/firmware/test/test_ring_link.cpp" -o "$OUT/ring_link"
"$OUT/ring_link"

"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  "${RING_INC[@]}" \
  "$ROOT/firmware/test/test_console_bridge.cpp" "$OUT/pedal_link.o" "$OUT/pd_trigger.o" \
  -o "$OUT/console_bridge"
"$OUT/console_bridge"

# The ring updater against the Pi's update engine, which lives with the
# appliance recipe that ships it (segno-ring-flash).
RING_FLASH="$ROOT/deploy/yocto/meta-segno/recipes-segno/segno-console-board/files"
"$CC" -std=c99 -Wall -Wextra -Werror -O1 \
  -I "$ROOT/firmware/console_board" -I "$ROOT/firmware/libraries/SegnoRing/src" \
  -c "$RING_FLASH/ring_flash.c" -o "$OUT/ring_flash.o"
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
  "${RING_INC[@]}" -I "$ROOT/firmware/console_board" -I "$RING_FLASH" \
  "$ROOT/firmware/test/test_ring_update.cpp" "$OUT/pedal_link.o" "$OUT/pd_trigger.o" "$OUT/ring_flash.o" \
  -o "$OUT/ring_update"
"$OUT/ring_update"
