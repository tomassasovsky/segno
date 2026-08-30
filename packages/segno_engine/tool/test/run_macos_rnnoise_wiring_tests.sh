#!/usr/bin/env bash
#
# Contract gate for the macOS RNNoise wiring (#942).
#
# CMake and run_native_tests.sh already compile vendored RNNoise. The macOS
# SPM/CocoaPods targets cannot see those sources unless each TU has a
# forwarder inside the package directory and the public header is on the
# include path. CI does not `flutter build macos`, so a missing forwarder
# only shows up on a Mac — this script is the Linux-runnable stand-in.
#
# Run: bash packages/segno_engine/tool/test/run_macos_rnnoise_wiring_tests.sh
set -uo pipefail

readonly HERE="$(cd "$(dirname "$0")" && pwd)"
readonly PLUGIN="$(cd "$HERE/../.." && pwd)"
readonly CMAKE="$PLUGIN/src/CMakeLists.txt"
readonly PODSPEC="$PLUGIN/macos/segno_engine.podspec"
readonly PACKAGE="$PLUGIN/macos/segno_engine/Package.swift"
readonly CLASSES="$PLUGIN/macos/Classes"
readonly SPM_SRC="$PLUGIN/macos/segno_engine/Sources/segno_engine"

fails=0
pass() { echo "  ok   -- $1"; }
fail() { echo "  FAIL -- $1"; fails=$((fails + 1)); }

echo "== macOS RNNoise wiring =="

# The CMake target_sources list is the source of truth (same list
# run_native_tests.sh mirrors). Extract the portable TUs; CMake names
# each file twice (sources + hidden-visibility properties), so unique.
tus="$(perl -ne 'print "$1\n" if /SEGNO_RNNOISE_DIR\}\/src\/([A-Za-z0-9_]+\.c)"/' "$CMAKE" | sort -u)"
n_tus="$(printf '%s\n' "$tus" | grep -c . || true)"
if [ "$n_tus" -ge 1 ]; then
  pass "CMake lists $n_tus RNNoise TUs"
else
  fail "CMake target_sources should list RNNoise TUs"
fi

fwd_name() {
  local tu="$1"
  case "$tu" in
    rnnoise_*) echo "$tu" ;;
    *) echo "rnnoise_$tu" ;;
  esac
}

# Resolve the first #include "..." in $1 relative to that file and require
# it to exist — a wrong ../ count still greps clean.
included_exists() {
  local file="$1"
  local rel
  rel="$(perl -ne 'if (/#include\s+"([^"]+)"/) { print $1; exit }' "$file")"
  [ -n "$rel" ] && [ -f "$(cd "$(dirname "$file")" && pwd)/$rel" ]
}

check_forwarder() {
  local label="$1" file="$2" tu="$3"
  if [ ! -f "$file" ]; then
    fail "$label forwarder $(basename "$file") missing"
    return
  fi
  if ! grep -q 'pragma GCC visibility push(hidden)' "$file"; then
    fail "$label forwarder $(basename "$file") missing hidden-visibility pragma"
    return
  fi
  if included_exists "$file"; then
    pass "$label forwarder $(basename "$file") resolves to $tu"
  else
    fail "$label forwarder $(basename "$file") #include does not resolve to a file"
  fi
}

while IFS= read -r tu; do
  [ -n "$tu" ] || continue
  fwd="$(fwd_name "$tu")"
  check_forwarder "CocoaPods" "$CLASSES/$fwd" "$tu"
  check_forwarder "SPM" "$SPM_SRC/$fwd" "$tu"
done <<< "$tus"

# HEADER_SEARCH_PATHS is the CocoaPods include root; a comment-only mention
# of the same strings must not pass. Match the assignment line, not the
# earlier comment that also names the key.
hs="$(grep "'HEADER_SEARCH_PATHS'" "$PODSPEC" || true)"
if printf '%s' "$hs" | grep -q 'third_party/rnnoise/include' && \
   printf '%s' "$hs" | grep -q 'third_party/rnnoise/src'; then
  pass "podspec HEADER_SEARCH_PATHS includes rnnoise include + src"
else
  fail "podspec HEADER_SEARCH_PATHS missing rnnoise include and/or src"
fi

# engine_restore.c is C: the -I flags must live inside cSettings, not only
# cxxSettings (which would re-break the original compile).
csettings="$(perl -0777 -ne 'if (/cSettings:\s*\[(.*?)cxxSettings:/s) { print $1 }' "$PACKAGE")"
if printf '%s' "$csettings" | grep -Fq -- '-I\(rnnoiseIncludeDir)' && \
   printf '%s' "$csettings" | grep -Fq -- '-I\(rnnoiseSrcDir)'; then
  pass "Package.swift cSettings pass -I for RNNoise (C TUs, not just C++)"
else
  fail "Package.swift must put RNNoise -I in cSettings (engine_restore.c is C)"
fi

if [ -f "$SPM_SRC/include/rnnoise.h" ] && included_exists "$SPM_SRC/include/rnnoise.h"; then
  pass "SPM include/rnnoise.h forwards the public header"
else
  fail "SPM include/rnnoise.h missing or does not resolve to the public header"
fi

# Reproduce the reported clang error. The pre-fix Apple include roots
# (src/core, src/midi, src/miniaudio — what the podspec shipped before
# #942) must fail on rnnoise.h; adding the RNNoise dirs must get past it.
# -E stops after preprocess so we do not need the engine's link set.
CC="${CC:-cc}"
restore="$PLUGIN/src/core/engine_restore.c"
inc_old="-I$PLUGIN/src/core -I$PLUGIN/src/midi -I$PLUGIN/src/miniaudio"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/segno_rnnoise_pp.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

if ! $CC -std=gnu11 -E $inc_old "$restore" >"$tmp/without.i" 2>"$tmp/without.err"; then
  if grep -q "rnnoise.h" "$tmp/without.err"; then
    pass "engine_restore.c without rnnoise -I fails on rnnoise.h (the macOS bug)"
  else
    fail "engine_restore.c without rnnoise -I failed, but not on rnnoise.h"
  fi
else
  fail "engine_restore.c without rnnoise -I should fail to preprocess"
fi

if $CC -std=gnu11 -E $inc_old \
    -I"$PLUGIN/third_party/rnnoise/include" \
    -I"$PLUGIN/third_party/rnnoise/src" \
    "$restore" >"$tmp/with.i" 2>"$tmp/with.err"; then
  pass "engine_restore.c with rnnoise -I preprocesses"
else
  fail "engine_restore.c with rnnoise -I should preprocess; $(cat "$tmp/with.err")"
fi

if [ "$fails" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
fi
echo "$fails FAILED"
exit 1
