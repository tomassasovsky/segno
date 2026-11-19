#!/usr/bin/env bash
#
# Checks the app's line coverage against its floor when its suite ran in
# shards (#1771): each `app-tests` job in main.yaml runs part of the tests
# and keeps its own lcov file, and this merges them and judges the whole.
#
#   bash tool/check_app_coverage.sh MIN "EXCLUDES" LCOV...
#
# A line counts as covered when any shard ran it. The figure is the one
# `very_good test --min-coverage MIN --exclude-coverage EXCLUDES` printed for
# the unsharded run: hit lines over found lines, summed over every file whose
# path matches none of the space-separated EXCLUDES globs. A glob's `**/`
# matches any directories in front, as package:glob's does.
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: $0 MIN \"EXCLUDES\" LCOV..." >&2
  exit 2
fi
min=$1
excludes=$2
shift 2

# One line per file: path, found, hit, then its uncovered lines.
merged=$(awk -F'[:,]' '
  /^SF:/ { file = substr($0, 4); files[file] = 1; next }
  /^DA:/ { key = file SUBSEP $2; seen[key] = 1; if ($3 > 0) hit[key] = 1 }
  END {
    for (key in seen) {
      split(key, part, SUBSEP)
      found[part[1]]++
      if (key in hit) covered[part[1]]++
      else missed[part[1]] = missed[part[1]] " " part[2]
    }
    for (f in files) printf "%s\t%d\t%d\t%s\n", f, found[f], covered[f], missed[f]
  }' "$@" | sort)

total_found=0 total_hit=0 uncovered=""
# The globs are patterns, not paths: no pathname expansion when the list is
# split (from the repo root, `**/bootstrap.dart` would become
# lib/bootstrap.dart and stop matching deeper files).
set -f
while IFS=$'\t' read -r file found hit lines; do
  [ -n "$file" ] || continue
  skip=0
  for glob in $excludes; do
    # shellcheck disable=SC2053  # the right side is a pattern on purpose
    if [[ $file == $glob ]]; then skip=1; break; fi
  done
  [ "$skip" = 0 ] || continue
  total_found=$((total_found + found))
  total_hit=$((total_hit + hit))
  if [ -n "$lines" ]; then
    sorted=$(printf '%s\n' $lines | sort -n | paste -sd, -)
    uncovered+="$file: $sorted"$'\n'
  fi
done <<< "$merged"
set +f

if [ "$total_found" = 0 ]; then
  echo "no coverage lines found in $*" >&2
  exit 1
fi
if [ -n "$uncovered" ]; then
  # Folded on GitHub Actions, as very_good's --show-uncovered list is long.
  [ -z "${GITHUB_ACTIONS:-}" ] || echo "::group::uncovered lines"
  printf 'uncovered lines:\n%s' "$uncovered"
  [ -z "${GITHUB_ACTIONS:-}" ] || echo "::endgroup::"
fi
awk -v hit="$total_hit" -v found="$total_found" -v min="$min" \
  -v shards="$#" 'BEGIN {
  coverage = 100 * hit / found
  printf "coverage: %.2f%% (%d of %d lines, from %d lcov files), floor %.2f%%\n",
    coverage, hit, found, shards, min
  if (coverage < min) {
    printf "Expected coverage >= %.2f%% but actual is %.2f%%.\n", min, coverage
    exit 1
  }
}'
