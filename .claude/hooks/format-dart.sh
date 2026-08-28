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

# `dart format` takes its trailing-comma behaviour from the language version in
# the enclosing package's `.dart_tool/package_config.json`. In a fresh worktree
# that has not had `pub get` yet, that file is missing, format silently falls
# back to a different default, and a one-file edit turns into a ~200-file
# reformat across the repo. Skip until the package is actually resolved.
DIR=$(cd "$(dirname "$FILE")" && pwd)
while [ "$DIR" != "/" ]; do
  if [ -f "$DIR/pubspec.yaml" ]; then
    [ -f "$DIR/.dart_tool/package_config.json" ] || exit 0
    break
  fi
  DIR=$(dirname "$DIR")
done

dart format "$FILE" >/dev/null 2>&1 || true
