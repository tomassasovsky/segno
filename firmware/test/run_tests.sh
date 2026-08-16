#!/usr/bin/env bash
# run_tests.sh - builds and runs the pedal-protocol host contract test
# (test_pedal_protocol.c) against BOTH in-repo protocol copies:
#
#   * firmware/segno_pedal/pedal_protocol.{h,c}            (primary)
#   * hardware/firmware/segno_pedal_32u4/pedal_protocol.{h,c}  (32u4 mirror)
#
# The two copies must stay byte-for-byte identical (each sketch #includes its
# own local copy) -- this script is the drift gate [R9][R10]: it first diffs
# the copies for a clear failure message, then compiles and runs the contract
# test against each, so CI and the local verify loop run the identical check.
#
# It ALSO compares the two .ino sketches' colour-mapping functions, which are
# hand-maintained in parallel and had no gate at all before #693.
#
# Run from anywhere; the script cd's to the repo root so the default golden
# fixtures path (packages/pedal_repository/test/fixtures) resolves.
set -euo pipefail

cd "$(dirname "$0")/../.."

PRIMARY=firmware/segno_pedal
MIRROR=hardware/firmware/segno_pedal_32u4

for f in pedal_protocol.h pedal_protocol.c; do
  if ! diff -u "$PRIMARY/$f" "$MIRROR/$f"; then
    echo "FAIL: $PRIMARY/$f and $MIRROR/$f have drifted." >&2
    echo "The two protocol copies must be byte-for-byte identical;" >&2
    echo "edit the primary copy and re-copy it into the mirror." >&2
    exit 1
  fi
done

# ---- sketch colour-mapping drift gate ---------------------------------------
#
# The protocol diff above says NOTHING about the two .ino sketches, and until
# #693 nothing did: a change applied to one sketch and forgotten in the other
# passed this script cleanly. That is the drift most likely to happen, because
# every colour decision has to be hand-applied twice.
#
# The sketches are not byte-comparable by design -- different boards, pin maps
# and LED buffers (g_leds[kModeLed] vs g_ind[kIndMode]). But their pure colour
# mapping functions carry no board-specific identifiers and MUST agree, or the
# two pedals render different colours for the same wire frame. Compare those
# token-for-token, ignoring comments and layout (the sketches are formatted
# differently on purpose: the 32u4 copy packs its switch arms onto one line).
#
# Scope note: this covers the colour VOCABULARY, not the render sites that use
# it. Those genuinely differ per board and are not mechanically comparable.
PRIMARY_INO="$PRIMARY/segno_pedal.ino"
MIRROR_INO="$MIRROR/segno_pedal_32u4.ino"

# Print one brace-matched `static CRGB <fn>(...)` definition from a sketch.
extract_fn() {
  awk -v fn="$2" '
    !inside && $0 ~ ("^static (const )?CRGB " fn "\\(") { inside = 1 }
    inside {
      print
      opens = gsub(/\{/, "{")
      closes = gsub(/\}/, "}")
      depth += opens - closes
      if (opens > 0) seen = 1
      if (seen && depth == 0) exit
    }
  ' "$1"
}

# Comments and whitespace carry no meaning here; everything else does.
normalize() { sed 's://.*::' | tr -d '[:space:]'; }

for fn in ledColor globalColor modeColor scaled; do
  p="$(extract_fn "$PRIMARY_INO" "$fn" | normalize)"
  m="$(extract_fn "$MIRROR_INO" "$fn" | normalize)"
  if [ -z "$p" ]; then
    echo "FAIL: could not find $fn() in $PRIMARY_INO." >&2
    echo "The drift gate greps for '^static CRGB $fn(' -- if the signature" >&2
    echo "changed, update extract_fn's pattern rather than dropping the check." >&2
    exit 1
  fi
  if [ "$p" != "$m" ]; then
    echo "FAIL: $fn() has drifted between the two sketches." >&2
    echo "  $PRIMARY_INO: $p" >&2
    echo "  $MIRROR_INO: $m" >&2
    echo "Both pedals must map the same wire value to the same colour." >&2
    exit 1
  fi
done

# The ring's idle glow is a bare constant rather than a function, and it is
# exactly the kind of value that gets tuned in one copy only.
for sym in kRingIdleGlow; do
  p="$(grep -h "^static const CRGB $sym" "$PRIMARY_INO" | normalize)"
  m="$(grep -h "^static const CRGB $sym" "$MIRROR_INO" | normalize)"
  if [ -z "$p" ] || [ "$p" != "$m" ]; then
    echo "FAIL: $sym differs (or is missing) between the two sketches." >&2
    echo "  $PRIMARY_INO: ${p:-<missing>}" >&2
    echo "  $MIRROR_INO: ${m:-<missing>}" >&2
    exit 1
  fi
done

echo "== sketch colour mapping: primary and 32u4 mirror agree =="

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

for tree in "$PRIMARY" "$MIRROR"; do
  echo "== contract test against $tree =="
  gcc -std=c11 -Wall -I "$tree" \
    firmware/test/test_pedal_protocol.c "$tree/pedal_protocol.c" \
    -o "$BUILD_DIR/pedal_protocol_tests"
  "$BUILD_DIR/pedal_protocol_tests"
done

echo "run_tests.sh: both protocol copies pass"
