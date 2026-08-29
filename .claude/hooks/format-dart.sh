#!/bin/bash
# PostToolUse hook (Edit|Write): keep edited Dart files in canonical
# `dart format` style so formatting never shows up as review noise
# (ffigen regens and hand edits alike).
#
# What this hook does NOT do: it only ever sees Edit and Write. Edits made
# through the shell (sed, python3, a heredoc) never reach it and land
# unformatted, so `dart format --set-exit-if-changed` in
# .claude/skills/verify/run.sh is what actually catches those. A clean session
# here is not evidence that formatting is handled.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

FILE=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0

case "$FILE" in
  *.dart) ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0

# Match verify/run.sh: bare `dart` is hook-blocked in this repo, and a second
# SDK earlier on PATH would format with a different dart_style than CI.
DART=${SEGNO_FLUTTER_BIN:-/Users/Tomas/development/flutter/bin}/dart
[ -x "$DART" ] || DART=$(command -v dart) || exit 0

# Format through a buffer and write back only on a completely clean run.
#
# The hazard this exists for: `dart format` keeps trailing commas only because
# `formatter: trailing_commas: preserve` reaches it through
# analysis_options.yaml's `include: package:very_good_analysis/...`, and a
# `package:` include resolves only through a `.dart_tool/package_config.json`.
# In a worktree that has not had `pub get`, the include silently fails, the
# formatter falls back to `trailing_commas: automate`, and one edit collapses
# every trailing comma in the file. `dart format` still exits 0 while doing it
# -- the only signal is a "Package resolution error" warning on stderr.
#
# So: ANY stderr, or any non-zero exit, means do not write. That covers the
# unresolved worktree, a truncated or half-written package_config.json from an
# interrupted `pub get`, a config that resolves but is missing
# very_good_analysis, and a file with a syntax error (exit 65, empty stdout --
# writing that back would truncate the file). Asking the formatter is strictly
# better than trying to predict it from the filesystem: an earlier version of
# this hook looked for package_config.json beside the nearest pubspec.yaml,
# which no `packages/*` in this repo has, so it silently skipped all 20
# sub-packages -- including the ffigen bindings named above -- even though the
# root config resolves them fine.
OUT=$(mktemp) || exit 0
ERR=$(mktemp) || { rm -f "$OUT"; exit 0; }
trap 'rm -f "$OUT" "$ERR"' EXIT

"$DART" format --output=show --summary=none "$FILE" >"$OUT" 2>"$ERR"
RC=$?
[ $RC -eq 0 ] || exit 0
[ -s "$ERR" ] && exit 0
[ -s "$OUT" ] || exit 0

cmp -s "$OUT" "$FILE" || cat "$OUT" >"$FILE"
exit 0
