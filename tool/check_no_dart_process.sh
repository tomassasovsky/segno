#!/usr/bin/env bash
#
# Fails when app code starts a program through dart:io, which forks the app.
#
# On the appliance a fork() of the app copies its page tables and
# write-protects every private page, and the real-time audio thread stalls
# for milliseconds behind it (#1367). The app starts its helpers with
# packages/spawn_process (posix_spawn) instead. The rule must hold for every
# call, not most of them: while any dart:io child runs, the Dart VM's
# exit-code thread waits for any child and takes the exit status of the
# programs spawn_process started (see packages/spawn_process/lib/spawn_process.dart).
#
# Checked, in lib/ and packages/*/lib, outside comment lines:
#   - Process.run, Process.start and Process.runSync;
#   - path_provider's getApplicationDocumentsDirectory and
#     getDownloadsDirectory, which run `xdg-user-dir` with Process.runSync on
#     Linux. lib/session_directory.dart calls the first on other platforms
#     only.
#
# Usage: tool/check_no_dart_process.sh (from the repository root)
set -euo pipefail

cd "$(dirname "$0")/.."

status=0

report() {
  local what="$1" matches="$2"
  # Drop lines whose code part is a comment (`//`, `///`).
  matches=$(printf '%s\n' "$matches" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  if [ -n "$matches" ]; then
    echo "error: $what (use package:spawn_process, see #1367):"
    printf '%s\n' "$matches"
    status=1
  fi
}

report "dart:io Process forks the app" \
  "$(grep -rnE --include='*.dart' '\bProcess\.(run|start|runSync)\b' lib packages/*/lib || true)"

report "path_provider runs xdg-user-dir with Process.runSync on Linux" \
  "$(grep -rnE --include='*.dart' '\b(getApplicationDocumentsDirectory|getDownloadsDirectory)\b' lib packages/*/lib \
    | grep -v '^lib/session_directory.dart:' || true)"

if [ "$status" -eq 0 ]; then
  echo "no dart:io process starts in lib/ or packages/*/lib"
fi
exit "$status"
