#!/usr/bin/env bash
# Full trunk verification in the main session worktree.
set -u
W=/Users/Tomas/Documents/Work/opensource/loopy/.claude/worktrees/chatgpt-tasks-review-fe30c8
S=/private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy--claude-worktrees-chatgpt-tasks-review-fe30c8/f74678c2-31ab-4130-bbb0-2e6605cb052c/scratchpad
FL=/Users/Tomas/development/flutter/bin
cd "$W"
git log --oneline -1
nat() { mkdir -p "$S/tv_$1"; TMPDIR="$S/tv_$1" EXTRA_CFLAGS="$2" bash packages/segno_engine/src/test/run_native_tests.sh > "$S/tv_$1.log" 2>&1; echo "$1=$? passed=$(grep -c 'ALL PASSED' $S/tv_$1.log)"; }
nat native ""
nat asan "-fsanitize=address -g"
nat tele "-DLE_CALLBACK_TELEMETRY=0"
export SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh 2>/dev/null)"
$FL/flutter pub get >/dev/null 2>&1
for d in packages/*/; do [ -f "$d/pubspec.yaml" ] && (cd "$d" && $FL/flutter pub get >/dev/null 2>&1); done
git checkout -q -- 'packages/*/analysis_options.yaml' 2>/dev/null
$FL/dart analyze --fatal-infos lib test packages > $S/tv_analyze.log 2>&1; echo "analyze=$?"; tail -1 $S/tv_analyze.log
$FL/flutter test > $S/tv_app.log 2>&1; echo "app=$?"; tail -1 $S/tv_app.log
for p in looper_repository segno_engine session_repository usb_storage_client storage_repository performance_repository operation_guards; do
  [ -d packages/$p ] || continue
  (cd packages/$p && $FL/flutter test > $S/tv_$p.log 2>&1; echo "$p=$?"; tail -1 $S/tv_$p.log)
done
bash deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_usb_ctl_tests.sh > $S/tv_usbctl.log 2>&1; echo "usbctl=$?"; tail -1 $S/tv_usbctl.log
$FL/dart format --output=none --set-exit-if-changed lib test packages > $S/tv_format.log 2>&1; echo "format=$?"
git checkout -q -- 'packages/*/analysis_options.yaml' 2>/dev/null
git status --short | head
