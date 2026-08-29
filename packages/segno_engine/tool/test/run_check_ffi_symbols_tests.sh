#!/usr/bin/env bash
#
# Tests for tool/check_ffi_symbols.sh -- the Dart<->native FFI skew gate.
#
# The gate compares two lists: symbols the generated bindings look up, and
# symbols the built .so exports. Producing a genuinely skewed ELF would mean
# compiling an old engine tree for aarch64, which needs Docker and minutes; the
# NM seam exists so these tests can hand the script a canned symbol table
# instead and run anywhere in under a second. The .so argument still has to be a
# real file, so the tests point at any real one and vary only what NM reports.
#
# Run: bash packages/segno_engine/tool/test/run_check_ffi_symbols_tests.sh
set -uo pipefail

readonly HERE="$(cd "$(dirname "$0")" && pwd)"
readonly CHECK="$HERE/../check_ffi_symbols.sh"
readonly BINDINGS="$HERE/../../lib/src/generated/segno_engine_bindings.dart"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { echo "  ok   -- $1"; }
fail() { echo "  FAIL -- $1"; fails=$((fails + 1)); }

# A stand-in for the .so: the script only needs the path to exist, because a
# stub NM decides what it "exports".
readonly FAKE_SO="$tmp/libsegno_engine.so"
echo "not really an ELF" > "$FAKE_SO"

# Build a stub NM that reports the given symbols in GNU `nm -D` format.
# Usage: make_nm <name> <symbol>...
make_nm() {
  local name="$1"; shift
  local path="$tmp/$name"
  {
    echo '#!/usr/bin/env bash'
    for sym in "$@"; do
      printf 'echo "000000000003345c T %s"\n' "$sym"
    done
  } > "$path"
  chmod +x "$path"
  echo "$path"
}

# Every symbol the real bindings look up -- the "matched bundle" baseline.
all_symbols() {
  perl -0777 -ne '
    my @m = /_lookup<(?:(?!_lookup<).)*?>\(\s*'"'"'([A-Za-z_][A-Za-z0-9_]*)'"'"'/gs;
    print "$_\n" for @m;
  ' "$BINDINGS"
}

echo "== check_ffi_symbols.sh =="

# --- 1. A matched bundle passes ----------------------------------------------
# Word-splitting is safe and intended here: every symbol is a C identifier.
# (`mapfile` would be tidier but is bash 4+; the dev machine ships bash 3.2.)
nm_all="$(make_nm nm_all $(all_symbols))"
n_all="$(all_symbols | wc -l | tr -d ' ')"
if NM="$nm_all" "$CHECK" "$FAKE_SO" >/dev/null 2>&1; then
  pass "matched bundle passes ($n_all symbols)"
else
  fail "matched bundle should pass"
fi

# --- 2. The historical skew is caught ----------------------------------------
# Exactly the 2026-08-25 appliance failure: a .so predating #808, missing the
# storage-accounting entry point the Dart half already calls on a timer.
nm_skew="$(make_nm nm_skew $(all_symbols | grep -v '^le_perf_volume_free_bytes$'))"
out="$(NM="$nm_skew" "$CHECK" "$FAKE_SO" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'le_perf_volume_free_bytes'; then
  pass "historical skew (#808 symbol absent) fails and names the symbol"
else
  fail "historical skew should fail loudly; rc=$rc"
fi

# --- 3. A wholesale stale .so is caught --------------------------------------
nm_few="$(make_nm nm_few le_version le_engine_create)"
if ! NM="$nm_few" "$CHECK" "$FAKE_SO" >/dev/null 2>&1; then
  pass "wholesale stale library fails"
else
  fail "wholesale stale library should fail"
fi

# --- 4. Fail closed: unreadable library is an error, not a pass --------------
# A silent pass here is the worst outcome -- it would greenlight every bundle.
nm_empty="$(make_nm nm_empty)"
out="$(NM="$nm_empty" "$CHECK" "$FAKE_SO" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no exported symbols'; then
  pass "unreadable library fails closed"
else
  fail "empty symbol table must not pass; rc=$rc"
fi

# --- 5. Fail closed: extractor drift is fatal --------------------------------
# If ffigen's emitted shape changes so the pattern stops matching some bindings,
# the gate would quietly check a subset. Simulate by adding a _lookup< site the
# pattern cannot resolve to a name.
drifted="$tmp/drifted.dart"
cp "$BINDINGS" "$drifted"
printf '\n// synthetic drift\nlate final x = _lookup<ffi.NativeFunction<ffi.Void Function()>>(someName);\n' >> "$drifted"
out="$(NM="$nm_all" "$CHECK" "$FAKE_SO" "$drifted" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'extractor drift'; then
  pass "extractor drift fails closed"
else
  fail "extractor drift must be fatal; rc=$rc"
fi

# --- 6. Both ffigen call shapes are extracted --------------------------------
# `dart format` wraps long generic lists, so the lookup tail appears both as
# >('le_foo') and as >(\n  'le_foo',\n). Missing the second shape would skip
# real bindings while still reporting a clean run.
shapes="$tmp/shapes.dart"
cat > "$shapes" <<'DART'
late final _aPtr = _lookup<ffi.NativeFunction<ffi.Void Function()>>('le_inline');
late final _bPtr =
    _lookup<ffi.NativeFunction<ffi.Void Function()>>(
      'le_wrapped',
    );
DART
nm_one="$(make_nm nm_one le_inline)"
out="$(NM="$nm_one" "$CHECK" "$FAKE_SO" "$shapes" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'le_wrapped'; then
  pass "wrapped (trailing-comma) lookup shape is checked too"
else
  fail "wrapped lookup shape must be extracted; rc=$rc"
fi

# --- 7. A bindings file with no lookups says so ------------------------------
# Regression: `grep -o` exits 1 on no match, so under set -e + pipefail this
# used to abort with rc=1 and *no output whatsoever* -- fail-closed, but the
# diagnostic explaining why was unreachable. Silent red in CI is expensive.
nolookups="$tmp/nolookups.dart"
echo "class Foo {}" > "$nolookups"
out="$(NM="$nm_all" "$CHECK" "$FAKE_SO" "$nolookups" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no _lookup< sites'; then
  pass "bindings file with no lookups explains itself"
else
  fail "zero-lookup bindings must fail *with* a diagnostic; rc=$rc out=[$out]"
fi

# --- 8. A glob matching two libraries is named, not misread ------------------
# CI invokes this with build/linux/*/debug/bundle/lib/libsegno_engine.so. A
# stale sibling arch dir would put the second match in $2, where it would be
# read as the bindings file and fail far from its cause.
out="$("$CHECK" "$FAKE_SO" "$FAKE_SO" "$FAKE_SO" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'at most 2 arguments'; then
  pass "over-expanded glob is reported as such"
else
  fail "extra arguments must be named; rc=$rc"
fi

# --- 9. Missing inputs are errors --------------------------------------------
if ! "$CHECK" "$tmp/does-not-exist.so" >/dev/null 2>&1; then
  pass "missing library is an error"
else
  fail "missing library should error"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
