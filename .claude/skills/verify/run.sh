#!/bin/bash
# Path-aware verify loop. Picks the gates the current diff actually needs,
# runs them, and prints one PASS/FAIL/SKIP line per gate plus the failures.
#
# Usage: run.sh [base-ref]   (default: origin/master)
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT" || exit 1
BASE=${1:-origin/master}

# Bare `flutter`/`dart` are hook-blocked in this repo; use the SDK by path.
FLUTTER_BIN=${SEGNO_FLUTTER_BIN:-/Users/Tomas/development/flutter/bin}
FLUTTER="$FLUTTER_BIN/flutter"
DART="$FLUTTER_BIN/dart"

git rev-parse --verify --quiet "$BASE" >/dev/null || {
  echo "base ref '$BASE' not found -- fetch it, or pass one that exists" >&2
  exit 2
}

# Committed changes vs the base, plus anything still dirty in the tree.
CHANGED=$( { git diff --name-only "$BASE"...HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u )
[ -n "$CHANGED" ] || { echo "no changes vs $BASE -- nothing to verify"; exit 0; }

touched() { echo "$CHANGED" | grep -qE "$1"; }

LOG=$(mktemp -d)
RESULTS=""
FAILED=0
UNVERIFIED=0

record() { RESULTS="${RESULTS}$1\t$2\t$3\n"; }

gate() { # gate <name> <logfile> <cmd...>
  local name=$1 log=$2; shift 2
  printf '  running %s ...\n' "$name" >&2
  if "$@" >"$log" 2>&1; then
    record "PASS" "$name" ""
  else
    record "FAIL" "$name" "$log"
    FAILED=1
  fi
}

# Two different things wear the word "skip", and collapsing them is how a
# verify run reports success having verified nothing:
#   skip  -- the gate does not apply to this diff. A real answer.
#   unrun -- the gate applies but a fixable local condition stopped it (no
#            `pub get`, no `bloc` CLI). NOT a pass; the run ends non-zero.
skip()  { record "SKIP" "$1" "$2"; }
unrun() { record "UNRUN" "$1" "$2"; UNVERIFIED=$((UNVERIFIED + 1)); }

# Every Dart gate needs a resolved package graph. Without one, `analyze` invents
# tens of thousands of phantom errors and `format` rewrites the whole repo, so
# skip them loudly rather than reporting noise as a failure.
UNRESOLVED=""
[ -f .dart_tool/package_config.json ] || UNRESOLVED="no .dart_tool/package_config.json -- run \`$FLUTTER pub get\` first"

# Nothing Dart-shaped moved, so neither analysis nor formatting can have
# regressed -- the same predicate the test gates use.
DART_TOUCHED=1
touched '\.(dart|arb)$|^pubspec\.(yaml|lock)$|^assets/' || DART_TOUCHED=0

# --- static analysis --------------------------------------------------------
if [ "$DART_TOUCHED" = 0 ]; then
  skip "dart analyze" "no Dart/arb/asset changes"
elif [ -z "$UNRESOLVED" ]; then
  gate "dart analyze" "$LOG/analyze" "$DART" analyze
else
  unrun "dart analyze" "$UNRESOLVED"
fi

# --- format: CI gates this --------------------------------------------------
if [ "$DART_TOUCHED" = 0 ]; then
  skip "dart format" "no Dart/arb/asset changes"
elif [ -z "$UNRESOLVED" ]; then
  gate "dart format --set-exit-if-changed" "$LOG/format" \
    "$DART" format --set-exit-if-changed --output=none \
    lib test packages/*/lib packages/*/test
else
  unrun "dart format" "$UNRESOLVED"
fi

# --- bloc lint: carries rules dart analyze does not -------------------------
# Notably, a cubit method returning anything but void fails here and passes
# `dart analyze`. Some worktree layouts make it silently analyse zero files and
# exit 64; a zero-file run is unverified, not green, so report it as a skip.
if [ "$DART_TOUCHED" = 0 ]; then
  skip "bloc lint" "no Dart/arb/asset changes"
elif command -v bloc >/dev/null 2>&1; then
  BL="$LOG/bloclint"
  bloc lint lib test packages >"$BL" 2>&1
  BL_RC=$?
  # 64 is EX_USAGE -- a genuinely broken invocation reports it too, so do not
  # take the code alone as proof of the known no-op. Only a run that actually
  # says it checked nothing is a no-op; a bare 64 is a failure.
  if grep -qiE "analyzed 0 |no files" "$BL"; then
    unrun "bloc lint" "checked 0 files (exit $BL_RC) -- known worktree no-op; must be run from the main checkout"
  elif [ $BL_RC -eq 0 ]; then
    record "PASS" "bloc lint" ""
  else
    record "FAIL" "bloc lint" "$BL"
    FAILED=1
  fi
else
  unrun "bloc lint" "bloc CLI not on PATH (dart pub global activate bloc_tools)"
fi

# --- Dart/Flutter tests: when any Dart or asset/l10n input moved -------------
# NOTE: a root `flutter test` runs the ROOT app's test/ dir ONLY. It does not
# descend into packages/*. CI knows this and gives six packages their own job
# (see the comments on `daw-export` and the five repository jobs in
# .github/workflows/main.yaml), so a change confined to one of those packages
# passes a root-only run here and fails CI. Each gets its own gate below,
# fired only when that package moved so the common case stays cheap.
if ! touched '\.(dart|arb)$|^pubspec\.(yaml|lock)$|^assets/'; then
  skip "flutter test" "no Dart/arb/asset changes"
elif [ -n "$UNRESOLVED" ]; then
  unrun "flutter test" "$UNRESOLVED"
else
  gate "flutter test (root app)" "$LOG/test" "$FLUTTER" test
fi

# The packages CI tests in their own job. daw_export is pure Dart (`dart test`);
# the rest are Flutter packages. Coverage floors stay CI's job -- this gate
# answers "do the tests pass", not "is the floor still met".
# Packages the six CI jobs path-depend on. looper_repository and
# session_repository both `path: ../segno_engine`, so "packages/<pkg>/ unchanged"
# is true of a package's own files and false of its inputs -- and CI, which runs
# all six unconditionally, would catch the break that a path-only predicate
# skips here.
PKG_DEPS='^packages/(segno_engine|wav_codec)/'

pkg_test() { # pkg_test <package-dir> <runner>
  local pkg=$1 runner=$2 name="test ($1)"
  if ! touched "^packages/$pkg/" && ! touched "$PKG_DEPS"; then
    skip "$name" "unchanged"
  elif [ ! -f "packages/$pkg/.dart_tool/package_config.json" ]; then
    unrun "$name" "unresolved -- run \`$FLUTTER pub get\` in packages/$pkg"
  else
    gate "$name" "$LOG/test_$pkg" bash -c "cd 'packages/$pkg' && '$runner' test"
  fi
}
pkg_test daw_export "$DART"
pkg_test looper_repository "$FLUTTER"
pkg_test session_repository "$FLUTTER"
pkg_test performance_repository "$FLUTTER"
pkg_test pedal_repository "$FLUTTER"
pkg_test controller_repository "$FLUTTER"

# --- native engine: only when engine sources moved --------------------------
if touched '^packages/segno_engine/src/'; then
  gate "native engine tests" "$LOG/native" bash packages/segno_engine/src/test/run_native_tests.sh
else
  skip "native engine tests" "no packages/segno_engine/src changes"
fi

# --- ffigen freshness: the API header and the bindings must move together ----
if touched '^packages/segno_engine/src/core/segno_engine_api\.h$'; then
  if touched '^packages/segno_engine/lib/src/generated/segno_engine_bindings\.dart$'; then
    record "PASS" "ffigen bindings in step" ""
  else
    cat > "$LOG/ffigen" <<'MSG'
segno_engine_api.h changed but the generated bindings did not.

  cd packages/segno_engine
  dart run ffigen --config ffigen.yaml
  dart format lib/src/generated/segno_engine_bindings.dart

The format step is required: ffigen emits a different style than the repo's, so
skipping it turns a small API change into whole-file churn.
MSG
    record "FAIL" "ffigen bindings in step" "$LOG/ffigen"
    FAILED=1
  fi
else
  skip "ffigen bindings in step" "segno_engine_api.h unchanged"
fi

# --- firmware contract + protocol-copy drift gate ---------------------------
if touched '^firmware/|^hardware/firmware/|pedal_protocol\.'; then
  gate "firmware contract + drift gate" "$LOG/firmware" bash firmware/test/run_tests.sh
else
  skip "firmware contract + drift gate" "no firmware / pedal-codec changes"
fi

# --- appliance bundle shell suites (CI's flash-pedal-tests job) -------------
# Globbed rather than listed, so a suite added to that directory is gated here
# the moment it exists -- the enumerated list in main.yaml is the thing that
# goes stale, and this is the copy nobody would remember to update.
BT=deploy/yocto/meta-segno/recipes-segno/segno-bundle/test
if ! touched '^deploy/yocto/meta-segno/recipes-segno/segno-bundle/'; then
  skip "appliance bundle tests" "no segno-bundle changes"
else
  for suite in "$BT"/run_*_tests.sh; do
    [ -f "$suite" ] || continue
    sname=$(basename "$suite" .sh)
    sname=${sname#run_}
    gate "appliance: ${sname%_tests}" "$LOG/$sname" bash "$suite"
  done
  # Twice on purpose: the appliance's /bin/sh is busybox ash, so these have to
  # hold under a strict POSIX shell too. A bash-only pass here would report
  # green on exactly the breakage this suite exists to catch.
  if command -v dash >/dev/null 2>&1; then
    gate "appliance: reconcile-staged (dash)" "$LOG/reconcile_dash" \
      env TEST_SHELL=dash bash "$BT/run_reconcile_staged_tests.sh"
  else
    unrun "appliance: reconcile-staged (dash)" \
      "dash not installed (brew install dash) -- CI runs this pass"
  fi
fi

# --- agent hooks: they run unattended on every session ----------------------
# A misfiring PreToolUse guard blocks work repo-wide and a stray `dart format`
# rewrites the tree, so these are not "just scripts".
if touched '^\.claude/hooks/'; then
  gate "agent hook tests" "$LOG/hooks" bash .claude/hooks/test/run_hook_tests.sh
else
  skip "agent hook tests" "no .claude/hooks changes"
fi

# --- report -----------------------------------------------------------------
echo
echo "verify vs $BASE"
printf "%b" "$RESULTS" | awk -F'\t' '{printf "  %-7s %-34s %s\n", $1, $2, ($1=="PASS" ? "" : $3)}'

if [ $FAILED -eq 1 ]; then
  echo
  echo "failures:"
  printf "%b" "$RESULTS" | awk -F'\t' '$1=="FAIL" {print $2"\t"$3}' | while IFS=$'\t' read -r name log; do
    echo
    echo "--- $name ---"
    [ -f "$log" ] && tail -25 "$log"
  done
  echo
  echo "(full logs under $LOG)"
  echo
  printf "%b" "$RESULTS" | awk -F'\t' '{printf "  %-7s %-34s %s\n", $1, $2, ($1=="PASS" ? "" : $3)}'
  exit 1
fi

if [ $UNVERIFIED -gt 0 ]; then
  echo
  echo "UNVERIFIED -- $UNVERIFIED gate(s) apply to this diff but could not run."
  echo "Fix the reasons above and re-run. This is not a pass."
  exit 3
fi

echo
echo "all applicable gates passed"
