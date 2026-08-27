#!/usr/bin/env bash
#
# Fail a build when the two halves of the engine bundle disagree about the FFI
# boundary: a symbol the generated Dart bindings will `dlsym` that the built
# libsegno_engine.so does not export.
#
# Why this exists
# ---------------
# An FFI lookup is resolved lazily, at first call, and a miss raises a Dart
# exception rather than failing to link. A bundle whose libapp.so looks up
# entry points its libsegno_engine.so never defines therefore compiles clean,
# packages clean, installs clean, and only breaks on the device when the code
# path runs. That is not hypothetical: on 2026-08-25 the appliance logged 548
# `Failed to lookup symbol 'le_perf_volume_free_bytes'` exceptions off a
# periodic timer, from a bundle whose Dart half was newer than its .so half.
# Nothing in the build had anything to say about it. This script is that voice.
#
# Usage:
#   check_ffi_symbols.sh <libsegno_engine.so> [bindings.dart]
#
#   <libsegno_engine.so>  The BUILT shared object that ships in the bundle,
#                         e.g. build/linux/arm64/release/bundle/lib/libsegno_engine.so
#   [bindings.dart]       Defaults to the generated bindings in this package.
#
# Environment:
#   NM  Symbol reader to use (default: nm, then llvm-nm). Must accept
#       `-D --defined-only` and print GNU-style "<addr> <type> <name>" lines.
#
# Exit status: 0 when every looked-up symbol is exported, 1 otherwise (and on
# any condition that would stop it from checking honestly -- see "fail closed").
set -euo pipefail

readonly SELF="$(basename "$0")"
die() { echo "$SELF: error: $*" >&2; exit 1; }

# --- Resolve inputs -----------------------------------------------------------
so="${1:-}"
[ -n "$so" ] || die "usage: $SELF <libsegno_engine.so> [bindings.dart]"
[ -f "$so" ] || die "shared object not found: $so"

# Default to the generated bindings that sit two levels up from tool/.
readonly PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bindings="${2:-$PKG_ROOT/lib/src/generated/segno_engine_bindings.dart}"
[ -f "$bindings" ] || die "bindings not found: $bindings"

# --- Pick a symbol reader -----------------------------------------------------
# macOS ships llvm-nm as `nm` and it reads aarch64 ELF fine, so the same script
# serves the Mac wrapper and the Linux CI job. NM is also the seam the unit
# tests use to feed canned symbol tables in without needing a compiler.
nm_bin="${NM:-}"
if [ -z "$nm_bin" ]; then
  if command -v nm >/dev/null 2>&1; then nm_bin=nm
  elif command -v llvm-nm >/dev/null 2>&1; then nm_bin=llvm-nm
  else die "no symbol reader found; install binutils or set NM"
  fi
fi

# --- Extract what Dart will look up -------------------------------------------
# ffigen emits, for every bound function:
#
#     late final _le_fooPtr =
#         _lookup<ffi.NativeFunction<...>>('le_foo');
#
# ...but `dart format` reflows long generic argument lists, so the call tail
# appears in at least two shapes -- `>('le_foo')` and a wrapped
# `>(\n  'le_foo',\n)` with a trailing comma. Matching only the first shape
# silently skips the second (16 of 144 symbols at time of writing), so the
# pattern deliberately stops at the opening quote and cares about neither the
# comma nor the closing paren. `(?:(?!_lookup<).)*?` keeps one match from
# running past the next binding and swallowing it whole.
extract_lookups() {
  perl -0777 -ne '
    my @m = /_lookup<(?:(?!_lookup<).)*?>\(\s*'"'"'([A-Za-z_][A-Za-z0-9_]*)'"'"'/gs;
    print "$_\n" for @m;
  ' "$1"
}

# The count of `_lookup<` occurrences is the ground truth for how many bindings
# exist. If the extractor returns a different number, ffigen's output shape has
# drifted out from under the pattern above and this script is now checking less
# than it claims to. That is the one failure mode a gate must never have, so it
# is fatal rather than a warning: fail closed, never silently under-check.
count_lookup_sites() { grep -o '_lookup<' "$1" | wc -l | tr -d ' '; }

# LC_ALL=C throughout: `comm` compares bytes, but `sort` under a UTF-8 locale
# collates by language rules that can ignore punctuation -- and every symbol here
# is full of underscores. Sorting in one order and comparing in another makes
# `comm` disagree with its own inputs and report nonsense, quietly. Pin both.
wanted="$(extract_lookups "$bindings" | LC_ALL=C sort -u)"
n_wanted="$(printf '%s\n' "$wanted" | grep -c . || true)"
n_sites="$(count_lookup_sites "$bindings")"

[ "$n_sites" -gt 0 ] || die "no _lookup< sites in $bindings -- is this the generated bindings file?"
[ "$n_wanted" -eq "$n_sites" ] || die \
  "extractor drift: $n_sites _lookup< sites but $n_wanted symbol names parsed out of
  $bindings
  ffigen's emitted shape has changed. Fix the pattern in $SELF before trusting
  this gate -- it is currently blind to $((n_sites - n_wanted)) binding(s)."

# --- Extract what the .so actually exports ------------------------------------
# --defined-only drops the U (undefined) imports, leaving exported text/data
# including weak symbols, which dlsym resolves just as happily. Versioned names
# ("foo@@VER") are trimmed to the bare name.
exported="$(
  "$nm_bin" -D --defined-only "$so" 2>/dev/null \
    | awk 'NF { print $NF }' \
    | sed 's/@.*//' \
    | LC_ALL=C sort -u
)"
[ -n "$exported" ] || die \
  "$nm_bin read no exported symbols out of $so
  Either the file is not an ELF shared object or $nm_bin cannot read it."

# --- Compare ------------------------------------------------------------------
missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$wanted") <(printf '%s\n' "$exported"))"

if [ -n "$missing" ]; then
  n_missing="$(printf '%s\n' "$missing" | grep -c .)"
  {
    echo "$SELF: FFI symbol skew -- $n_missing of $n_wanted looked-up symbol(s) are not exported."
    echo
    echo "  bindings: $bindings"
    echo "  library:  $so"
    echo
    echo "  Missing from the library:"
    printf '%s\n' "$missing" | sed 's/^/    /'
    echo
    echo "  These resolve at first call, so this bundle would build, install and"
    echo "  run -- then throw at runtime on whatever path reaches them first."
    echo "  The .so is stale relative to the Dart bindings: rebuild the native"
    echo "  engine from the same tree and re-stage the bundle."
  } >&2
  exit 1
fi

echo "$SELF: OK -- all $n_wanted looked-up symbols are exported by $(basename "$so")"
