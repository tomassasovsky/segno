#!/bin/bash
# PostToolUse hook (Edit|Write): keep edited Dart files in canonical
# `dart format` style so formatting never shows up as review noise
# (ffigen regens and hand edits alike).
set -euo pipefail

FILE=$(jq -r '.tool_input.file_path // empty')

case "$FILE" in
  *.dart) ;;
  *) exit 0 ;;
esac

[ -f "$FILE" ] || exit 0
command -v dart >/dev/null 2>&1 || exit 0

# This hook only ever sees Edit/Write. Shell-scripted edits (sed, python3,
# heredocs) never reach it, so `dart format --set-exit-if-changed` in
# .claude/skills/verify/run.sh is the gate that actually catches those --
# do not read a green session here as "formatting is handled".
#
# The skip below is not paranoia. `dart format` keeps trailing commas only
# because `formatter: trailing_commas: preserve` reaches it through
# analysis_options.yaml's `include: package:very_good_analysis/...`, and a
# `package:` include resolves only via `.dart_tool/package_config.json`. In a
# fresh worktree that has not had `pub get` yet that file is missing, the
# include silently fails, the formatter falls back to `trailing_commas:
# automate`, and a one-file edit turns into a ~200-file reformat across the
# repo -- every trailing comma collapsed. Verified both ways: with the file
# present `f(\n a,\n b,\n)` survives; with it absent it becomes `f(a, b)`.
# Skip until the package is actually resolved.
DIR=$(cd "$(dirname "$FILE")" && pwd)
while [ "$DIR" != "/" ]; do
  if [ -f "$DIR/pubspec.yaml" ]; then
    [ -f "$DIR/.dart_tool/package_config.json" ] || exit 0
    break
  fi
  DIR=$(dirname "$DIR")
done

dart format "$FILE" >/dev/null 2>&1 || true
