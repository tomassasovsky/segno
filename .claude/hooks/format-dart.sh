#!/bin/bash
# PostToolUse hook (Edit|Write): keep edited Dart files in canonical
# `dart format` style so formatting never shows up as review noise
# (ffigen regens and hand edits alike).
#
# Only formats when the file resolves to a package config. `dart format` keeps
# trailing commas because `formatter: trailing_commas: preserve` reaches it
# through analysis_options.yaml's `include: package:very_good_analysis/...`,
# and that include resolves only through a `.dart_tool/package_config.json`
# found by walking up from the file. With none, the include silently fails,
# the formatter falls back to collapsing trailing commas, and edits in an
# unresolved worktree turn into a repo-wide reformat. Sub-packages without
# their own `.dart_tool` resolve through the root's, as they do for dart.
set -uo pipefail

FILE=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0

case "$FILE" in
  *.dart) ;;
  *) exit 0 ;;
esac

[ -f "$FILE" ] || exit 0
command -v dart >/dev/null 2>&1 || exit 0

# Same lookup dart does: the nearest ancestor with .dart_tool/package_config.json.
DIR=$(CDPATH='' cd -- "$(dirname -- "$FILE")" && pwd -P) || exit 0
until [ -f "$DIR/.dart_tool/package_config.json" ]; do
  [ "$DIR" = / ] && exit 0
  DIR=$(dirname "$DIR")
done

# A config that exists but does not resolve (truncated by an interrupted
# `pub get`) still collapses commas; dart exits 0 and only warns on stderr.
# So format into a buffer and write back only on a clean, non-empty run.
OUT=$(mktemp) || exit 0
ERR=$(mktemp) || { rm -f "$OUT"; exit 0; }
trap 'rm -f "$OUT" "$ERR"' EXIT
dart format --output=show --summary=none "$FILE" >"$OUT" 2>"$ERR" || exit 0
[ -s "$ERR" ] && exit 0
[ -s "$OUT" ] || exit 0
cmp -s "$OUT" "$FILE" || { cat "$OUT" >"$FILE"; } 2>/dev/null
exit 0
