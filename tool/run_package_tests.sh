#!/usr/bin/env bash
#
# Runs the packages' own test suites, each against its coverage floor, the
# way the Very Good workflows ran them one job per package (#1771): `very_good
# test` for the Flutter packages and `very_good dart test` for the pure Dart
# ones, with test optimization, randomized order and the floor below. The
# root `build` job already formats and analyzes every package (its
# format_directories and analyze_directories glob packages/*), so this runs
# only the tests.
#
# Run it from anywhere after `very_good packages get --recursive` at the
# root. PACKAGE_TEST_JOBS sets how many packages test at once: half the CPUs
# by default, so a suite gets about the CPU it had in a job of its own (with
# four at once on four CPUs, session_repository's 8-track Free-mode
# round-trip, 16 s on an idle runner, ran past its 30 s timeout). The list runs
# longest first. Every package's output prints when all are done, the failed
# ones last.
#
# A floor is pinned AT the value measured when the package's job was added:
# never rounded up (a blind 100 blocks every later part) and never silently
# lowered (raise-only). Notes on the floors that are below 100:
#   touch_calibration_client: the factory's return of the real helper, which
#     only the appliance has installed.
#   brightness_client: the two factories, which pick the real client only on
#     the appliance.
#   spawn_process: its macOS branches and the libc failures a test cannot
#     provoke; the tests force the EPIPE and ECHILD paths (#1457), so the
#     figure is 89.3% on every run.
# Native-library tests (fuzz-tagged) self-skip here; the `fuzz` job runs them
# against the engine it builds.
set -euo pipefail
cd "$(dirname "$0")/.."

# package  runner  floor
PACKAGES="
session_repository    flutter 89
looper_repository     flutter 95
performance_repository flutter 99
controller_repository flutter 82
spawn_process         dart    88
daw_export            dart    100
usb_storage_client    dart    100
touch_calibration_client dart 98
backing_repository    flutter 95
storage_repository    flutter 100
instrument_repository flutter 100
pedal_repository      flutter 96
fx_catalogue          flutter 100
brightness_client     dart    80
operation_guards      flutter 100
cpu_load_repository   flutter 100
"

CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
JOBS="${PACKAGE_TEST_JOBS:-$(( CPUS > 1 ? CPUS / 2 : 1 ))}"
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/segno_package_tests.XXXXXX")"
export LOGS

test_package() {   # test_package NAME RUNNER FLOOR
  local name=$1 runner=$2 floor=$3 start=$SECONDS status=passed
  local -a cmd
  if [ "$runner" = flutter ]; then
    cmd=(very_good test -j 4 --optimization)
  else
    cmd=(very_good dart test -j 4 --platform vm --no-check-ignore --optimization)
  fi
  cmd+=(--coverage --min-coverage "$floor" --report-on lib --show-uncovered
    --test-randomize-ordering-seed random)
  echo "== $name started =="
  if ! (cd "packages/$name" && "${cmd[@]}") >"$LOGS/$name.log" 2>&1; then
    status=FAILED
    : >"$LOGS/$name.failed"
  fi
  echo "== $name $status in $((SECONDS - start)) s =="
}
export -f test_package

# shellcheck disable=SC2086
printf '%s\n' $PACKAGES | xargs -n 3 -P "$JOBS" bash -c 'test_package "$0" "$1" "$2"'

failed=""
for name in $(printf '%s\n' "$PACKAGES" | awk 'NF { print $1 }'); do
  if [ -e "$LOGS/$name.failed" ]; then
    failed="$failed $name"
    continue
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$name (passed)"; else echo "== $name (passed) =="; fi
  cat "$LOGS/$name.log"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::endgroup::"
done
for name in $failed; do
  echo "== $name FAILED; its output: =="
  cat "$LOGS/$name.log"
done
if [ -n "$failed" ]; then
  echo "FAILED:$failed" >&2
  exit 1
fi
echo "== all package suites passed =="
