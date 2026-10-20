#!/bin/bash
# PostToolUse hook (Edit|Write): keep edited Dart files in canonical
# `dart format` style so formatting never shows up as review noise
# (ffigen regens and hand edits alike).
#
# Only formats inside a resolved package. `dart format` keeps trailing commas
# because `formatter: trailing_commas: preserve` reaches it through
# analysis_options.yaml's `include: package:very_good_analysis/...`, and that
# include resolves only through `.dart_tool/package_config.json`. In a worktree
# that has not had `pub get`, the include silently fails, the formatter falls
# back to collapsing trailing commas, and edits turn into a repo-wide reformat.
set -uo pipefail

FILE=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0

case "$FILE" in
  *.dart) ;;
  *) exit 0 ;;
esac

[ -f "$FILE" ] || exit 0
command -v dart >/dev/null 2>&1 || exit 0

# Walk up to the nearest pubspec.yaml; no-op unless that package is resolved.
DIR=$(cd "$(dirname "$FILE")" && pwd) || exit 0
while [ ! -f "$DIR/pubspec.yaml" ]; do
  [ "$DIR" = / ] && exit 0
  DIR=$(dirname "$DIR")
done
[ -f "$DIR/.dart_tool/package_config.json" ] || exit 0

dart format "$FILE" >/dev/null 2>&1 || true
