#!/usr/bin/env bash
#
# Contract gate for the macOS RNNoise wiring (#942).
#
# CMake and run_native_tests.sh already compile vendored RNNoise. The macOS
# SPM/CocoaPods targets cannot see those sources unless each TU has a
# forwarder inside the SPM package directory (CocoaPods compiles those same
# files via the podspec glob) and the public header is on the include path.
# CI does not `flutter build macos`, so a missing forwarder only shows up on
# a Mac — this script is the Linux-runnable stand-in.
#
# Run: bash packages/segno_engine/tool/test/run_macos_rnnoise_wiring_tests.sh
set -uo pipefail

readonly HERE="$(cd "$(dirname "$0")" && pwd)"
readonly PLUGIN="$(cd "$HERE/../.." && pwd)"
readonly CMAKE="$PLUGIN/src/CMakeLists.txt"
readonly NATIVE_TESTS="$PLUGIN/src/test/run_native_tests.sh"
readonly PODSPEC="$PLUGIN/macos/segno_engine.podspec"
readonly PACKAGE="$PLUGIN/macos/segno_engine/Package.swift"
readonly SPM_SRC="$PLUGIN/macos/segno_engine/Sources/segno_engine"
readonly CLASSES="$PLUGIN/macos/Classes"
readonly RNNOISE_INC="$PLUGIN/third_party/rnnoise/include"
readonly RNNOISE_SRC="$PLUGIN/third_party/rnnoise/src"
# Portable RNNoise TU count: CMake, run_native_tests.sh, and the SPM
# forwarders must all stay at this size (x86 RTCD TUs are not compiled).
readonly EXPECTED_TUS=10

fails=0
pass() { echo "  ok   -- $1"; }
fail() { echo "  FAIL -- $1"; fails=$((fails + 1)); }

echo "== macOS RNNoise wiring =="

cmake_tus="$(perl -ne 'print "$1\n" if /SEGNO_RNNOISE_DIR\}\/src\/([A-Za-z0-9_]+\.c)"/' "$CMAKE" | sort -u)"
native_tus="$(perl -ne 'print "$1\n" while /third_party\/rnnoise\/src\/([A-Za-z0-9_]+\.c)/g' "$NATIVE_TESTS" | sort -u)"
n_tus="$(printf '%s\n' "$cmake_tus" | grep -c . || true)"
n_fwd="$(find "$SPM_SRC" -maxdepth 1 -name 'rnnoise_*.c' | wc -l | tr -d ' ')"
n_classes="$(find "$CLASSES" -maxdepth 1 -name 'rnnoise_*.c' | wc -l | tr -d ' ')"

if [ "$n_tus" -eq "$EXPECTED_TUS" ] && [ "$cmake_tus" = "$native_tus" ] && [ "$n_tus" -eq "$n_fwd" ]; then
  pass "CMake and native-test TU sets match ($n_tus) and SPM has that many forwarders"
else
  fail "RNNoise TU sets drifted: CMake=$n_tus SPM=$n_fwd expected=$EXPECTED_TUS (sets must be identical)"
fi

if [ "$n_classes" -eq 0 ]; then
  pass "no Classes/rnnoise_*.c wrappers (CocoaPods uses the SPM glob)"
else
  fail "Classes/rnnoise_*.c would duplicate-compile with the podspec SPM glob ($n_classes files)"
fi

fwd_name() {
  local tu="$1"
  case "$tu" in
    rnnoise_*) echo "$tu" ;;
    *) echo "rnnoise_$tu" ;;
  esac
}

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

while IFS= read -r tu; do
  [ -n "$tu" ] || continue
  fwd="$(fwd_name "$tu")"
  file="$SPM_SRC/$fwd"
  if [ ! -f "$file" ]; then
    fail "SPM forwarder $fwd missing"
    continue
  fi
  if ! grep -q 'pragma GCC visibility push(hidden)' "$file"; then
    fail "SPM forwarder $fwd missing hidden-visibility pragma"
    continue
  fi
  resolved="$(resolve_include "$file" || true)"
  if [ -z "$resolved" ]; then
    fail "SPM forwarder $fwd #include does not resolve to a file"
    continue
  fi
  base="$(basename "$resolved")"
  if [ "$base" = "$tu" ]; then
    pass "SPM forwarder $fwd includes $tu"
  else
    fail "SPM forwarder $fwd includes $base, expected $tu"
  fi
done <<< "$cmake_tus"

# Expand the podspec RNNoise glob from macos/ (the podspec directory). A
# string grep would still pass if the glob never matched a file.
rel_glob="$(perl -ne 'print "$1" if /source_files.*'\''(segno_engine\/Sources\/segno_engine\/rnnoise_\*\.c)'\''/' "$PODSPEC")"
n_glob=0
if [ -n "$rel_glob" ]; then
  for f in "$PLUGIN/macos"/$rel_glob; do
    [ -f "$f" ] || continue
    n_glob=$((n_glob + 1))
  done
fi
if [ -n "$rel_glob" ] && [ "$n_glob" -eq "$EXPECTED_TUS" ]; then
  pass "podspec glob $rel_glob expands to $n_glob files under macos/"
else
  fail "podspec RNNoise glob must expand to $EXPECTED_TUS files under macos/ (got $n_glob)"
fi

csettings="$(perl -0777 -ne 'if (/cSettings:\s*\[(.*?)cxxSettings:/s) { print $1 }' "$PACKAGE")"
if printf '%s' "$csettings" | grep -Fq -- '-I\(rnnoiseIncludeDir)' && \
   printf '%s' "$csettings" | grep -Fq -- '-I\(rnnoiseSrcDir)'; then
  pass "Package.swift cSettings pass -I for RNNoise (C TUs, not just C++)"
else
  fail "Package.swift must put RNNoise -I in cSettings (engine_restore.c is C)"
fi

if grep -Fq 'appendingPathComponent("rnnoise/include")' "$PACKAGE" && \
   grep -Fq 'appendingPathComponent("rnnoise/src")' "$PACKAGE"; then
  pass "Package.swift -I dirs are rnnoise/include and rnnoise/src"
else
  fail "Package.swift must append rnnoise/include and rnnoise/src onto third_party"
fi

# Expand the podspec HEADER_SEARCH_PATHS assignment into absolute -I flags.
export PODS_TARGET_SRCROOT="$PLUGIN/macos"
header_dirs="$(perl -ne '
  if (/\x27HEADER_SEARCH_PATHS\x27\s*=>\s*\x27(.*)\x27/) {
    my $v = $1;
    $v =~ s/\$\(PODS_TARGET_SRCROOT\)/$ENV{PODS_TARGET_SRCROOT}/g;
    while ($v =~ /"([^"]+)"/g) { print "$1\n" }
  }
' "$PODSPEC")"
inc_all=""
inc_old=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  if [ ! -d "$d" ]; then
    fail "podspec HEADER_SEARCH_PATHS dir does not exist: $d"
    continue
  fi
  abs="$(cd "$d" && pwd)"
  inc_all="$inc_all -I$abs"
  case "$d" in
    *rnnoise*) ;;
    *) inc_old="$inc_old -I$abs" ;;
  esac
done <<< "$header_dirs"

CC="${CC:-cc}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/segno_rnnoise_pp.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

preprocess_restore() {
  local label="$1" src="$2" without="$3" with="$4"
  if ! $CC -std=gnu11 -E $without "$src" >"$tmp/${label}_without.i" 2>"$tmp/${label}_without.err"; then
    if grep -q "rnnoise.h" "$tmp/${label}_without.err"; then
      pass "$label without rnnoise -I fails on rnnoise.h (the macOS bug)"
    else
      fail "$label without rnnoise -I failed, but not on rnnoise.h"
    fi
  else
    fail "$label without rnnoise -I should fail to preprocess"
  fi
  if $CC -std=gnu11 -E $with "$src" >"$tmp/${label}_with.i" 2>"$tmp/${label}_with.err"; then
    pass "$label with rnnoise -I preprocesses"
  else
    fail "$label with rnnoise -I should preprocess; $(cat "$tmp/${label}_with.err")"
  fi
}

preprocess_restore "CocoaPods engine_restore.c" \
  "$CLASSES/engine_restore.c" "$inc_old" "$inc_all"

spm_without="-I$SPM_SRC/include"
spm_with="-I$SPM_SRC/include -I$RNNOISE_INC -I$RNNOISE_SRC"
preprocess_restore "SPM engine_restore.c" \
  "$SPM_SRC/engine_restore.c" "$spm_without" "$spm_with"

nnet="$SPM_SRC/rnnoise_nnet.c"
denoise="$SPM_SRC/rnnoise_denoise.c"

# CocoaPods compiles the globbed wrapper with HEADER_SEARCH_PATHS, not a
# synthetic -I pair. $inc_all is the extracted podspec set.
if $CC -std=gnu11 -c $inc_all "$nnet" -o "$tmp/nnet_pods.o" 2>"$tmp/nnet_pods.err"; then
  pass "podspec-glob rnnoise_nnet.c compiles with HEADER_SEARCH_PATHS -I"
else
  fail "podspec-glob rnnoise_nnet.c should compile with HEADER_SEARCH_PATHS; $(cat "$tmp/nnet_pods.err")"
fi

if $CC -E -dM - </dev/null 2>/dev/null | grep -q '__SSE2__'; then
  if $CC -std=gnu11 -c -I"$RNNOISE_INC" \
      "$nnet" -o "$tmp/nnet_nosrc.o" 2>"$tmp/nnet_nosrc.err"; then
    fail "on SSE2, rnnoise_nnet.c without src/ -I should fail (x86 common.h lookup)"
  else
    pass "on SSE2, rnnoise_nnet.c without src/ -I fails (x86 common.h lookup)"
  fi
fi

if $CC -std=gnu11 -c -I"$RNNOISE_INC" -I"$RNNOISE_SRC" \
    "$denoise" -o "$tmp/denoise.o" 2>"$tmp/denoise.err"; then
  if nm "$tmp/denoise.o" | grep -q 'rnnoise_create' && \
     nm "$tmp/denoise.o" | grep -q 'rnnoise_process_frame'; then
    pass "SPM rnnoise_denoise.c object defines rnnoise_create and rnnoise_process_frame"
  else
    fail "SPM rnnoise_denoise.c object missing rnnoise_create / rnnoise_process_frame"
  fi
else
  fail "SPM rnnoise_denoise.c should compile; $(cat "$tmp/denoise.err")"
fi

if [ "$fails" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
fi
echo "$fails FAILED"
exit 1
