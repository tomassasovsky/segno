#!/usr/bin/env bash
# Regression test for task_runner_timeout_guard.cc (#1299). Linux only; needs a
# C++ compiler and the GLib development package.
#
# Builds the embedder's task-runner scheduling as a stand-in
# libflutter_linux_gtk.so, then runs the same harness twice: without the guard
# it must reproduce the leak, with it at most one timeout may stay attached and
# every task must run. The harness lands a post in the race window on every
# dispatch, so the result does not depend on thread timing.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

cxx="${CXX:-c++}"
glib="$(pkg-config --cflags --libs glib-2.0)"

# shellcheck disable=SC2086
"$cxx" -std=c++17 -O2 -fPIC -shared -o "$out/libflutter_linux_gtk.so" \
  "$here/fake_task_runner.cc" $glib
# shellcheck disable=SC2086
"$cxx" -std=c++17 -O2 -o "$out/unguarded" \
  "$here/task_runner_timeout_guard_test.cc" \
  -L"$out" -lflutter_linux_gtk $glib
# Linked the way the runner's CMakeLists links the app.
# shellcheck disable=SC2086
"$cxx" -std=c++17 -O2 -o "$out/guarded" \
  "$here/task_runner_timeout_guard_test.cc" "$here/../task_runner_timeout_guard.cc" \
  -L"$out" -lflutter_linux_gtk $glib -ldl \
  -Wl,--export-dynamic-symbol=g_timeout_add

export LD_LIBRARY_PATH="$out"
"$out/unguarded" --expect-orphans
"$out/guarded" --expect-guarded
