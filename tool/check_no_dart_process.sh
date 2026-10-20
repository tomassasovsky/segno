#!/usr/bin/env bash
#
# Fails when app code, or a package the app runs, starts a program through
# dart:io, which forks the app.
#
# On the appliance a fork() of the app copies its page tables and
# write-protects every private page, and the real-time audio thread stalls
# for milliseconds behind it (#1367). The app starts its helpers with
# packages/spawn_process (posix_spawn) instead. The rule must hold for every
# call, not most of them: while any dart:io child runs, the Dart VM's
# exit-code thread waits for any child and takes the exit status of the
# programs spawn_process started (see packages/spawn_process/lib/spawn_process.dart).
#
# Checked in lib/ and packages/*/lib, outside comment lines:
#   - Process.run, Process.start and Process.runSync;
#   - path_provider's getApplicationDocumentsDirectory and
#     getDownloadsDirectory, which run `xdg-user-dir` with Process.runSync on
#     Linux (lib/session_directory.dart calls the first on other platforms
#     only), and direct use of xdg_directories or PathProviderLinux.
#
# Checked in the lib/ of every package the app depends on at run time (not
# dev dependencies), from .dart_tool/package_config.json, so `flutter pub
# get` must have run: Process.run, Process.start and Process.runSync. A
# package may call them only when it is in ALLOWED below, with the reason
# the app never reaches the call.
#
# Usage: tool/check_no_dart_process.sh (from anywhere, after flutter pub get)
set -euo pipefail

cd "$(dirname "$0")/.."
repo=$(pwd)

# Runtime dependencies allowed to contain a dart:io process start.
#   sky_engine: the Dart SDK libraries themselves: dart:io's own Process
#   implementation (process_patch.dart) and the VM service, which a release
#   build does not start. The app's own calls into dart:io are the ones the
#   in-repo check forbids.
#   xdg_directories: getUserDirectory runs `xdg-user-dir`. The app reaches it
#   only through path_provider_linux's documents and downloads lookups,
#   which the in-repo check forbids too.
ALLOWED="sky_engine xdg_directories"

status=0
process_start='\bProcess\.(run|start|runSync)\b'

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
  "$(grep -rnE --include='*.dart' "$process_start" lib packages/*/lib || true)"

report "path_provider runs xdg-user-dir with Process.runSync on Linux" \
  "$(grep -rnE --include='*.dart' \
    '\b(getApplicationDocumentsDirectory|getDownloadsDirectory|PathProviderLinux)\b|package:xdg_directories/' \
    lib packages/*/lib | grep -v '^lib/session_directory.dart:.*getApplicationDocumentsDirectory' || true)"

config=.dart_tool/package_config.json
if [ ! -f "$config" ]; then
  echo "error: $config is missing; run flutter pub get first"
  exit 1
fi

# `- name version [deps]` lines of the runtime dependency tree.
runtime=$(dart pub deps --no-dev --style=compact | sed -n 's/^- \([a-z0-9_]*\) .*/\1/p' | sort -u)
scanned=0
for name in $runtime; do
  root=$(jq -r --arg n "$name" '.packages[] | select(.name == $n) | .rootUri' "$config")
  [ -n "$root" ] || continue
  case "$root" in
    file://*) dir=${root#file://} ;;
    *) dir="$repo/.dart_tool/$root" ;;
  esac
  dir=$(cd "$dir" 2>/dev/null && pwd) || continue
  # The repo's own packages are checked above.
  case "$dir/" in "$repo"/*) continue ;; esac
  [ -d "$dir/lib" ] || continue
  scanned=$((scanned + 1))
  matches=$(grep -rnE --include='*.dart' "$process_start" "$dir/lib" \
    | sed "s|^$dir/|$name/|" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  [ -n "$matches" ] || continue
  if printf '%s\n' $ALLOWED | grep -qx "$name"; then
    echo "allowed: $name starts processes (see ALLOWED in this script)"
    continue
  fi
  report "runtime dependency $name starts a process through dart:io" "$matches"
done

if [ "$status" -eq 0 ]; then
  echo "no dart:io process starts in lib/, packages/*/lib or the $scanned runtime dependencies outside them"
fi
exit "$status"
