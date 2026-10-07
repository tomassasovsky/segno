# Common brief for Segno builders

Repo: tomassasovsky/segno, a Flutter floor-console looper with a native C real-time engine. The working trunk is origin/claude/segno-integration; fetch it first.

## Where to work
- Work only in a git worktree you create under the scratchpad /private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy--claude-worktrees-chatgpt-tasks-review-fe30c8/f74678c2-31ab-4130-bbb0-2e6605cb052c/scratchpad/ (or in your own agent worktree).
- Never touch /Users/Tomas/Documents/Work/opensource/loopy/.claude/worktrees/chatgpt-tasks-review-fe30c8, the main checkout, or another agent's worktree.

## Read first
- AGENTS.md;
- docs/PROGRESS.md "How to build / test";
- the plan for your issue under docs/plan/.

## Design source
- The design source is the main checkout's pen, /Users/Tomas/Documents/Work/opensource/loopy/segno-ui.pen, group "01 CURRENT UX".
- Read it only through the pencil MCP: load mcp__pencil__execute and mcp__pencil__read_skill with ToolSearch, and read the skill's execute.md first. Always pass that exact filePath.
- Never edit or save the pen. Record any departure from it in the plan's write-back list.

## Owner rules for open points
1. Preserve existing installs' behaviour.
2. Fail safe, keep audio running, and leave a recovery path.
3. No silent behaviour changes.
4. Consolidate over duplicate.
5. Drop uncertain native state with a notice.

Decide by these rules and record each decision in the plan. Report only genuine product-direction questions.

## Verify before reporting
- `dart analyze --fatal-infos lib test packages` must be clean. Use /Users/Tomas/development/flutter/bin/dart and /Users/Tomas/development/flutter/bin/flutter. Bare `flutter test` and `dart test` are hook-blocked.
- Run the full app suite plus each touched package's suite, with SEGNO_ENGINE_LIB exported from `bash packages/segno_engine/tool/build_test_lib.sh`.
- Native changes: run `bash packages/segno_engine/src/test/run_native_tests.sh` three times, one run at a time, each in its own TMPDIR (mkdir it first):
  - plain;
  - `EXTRA_CFLAGS="-fsanitize=address -g"`;
  - `EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0"`.
- After any change to segno_engine_api.h, run `dart run ffigen --config ffigen.yaml` from packages/segno_engine, then format the bindings.
- `dart format` changes nothing.
- Bloc lint is a no-op inside .claude/worktrees. Run `bloc lint lib test packages` from a scratch worktree under the scratchpad.
- Each new behaviour gets a test that fails with its fix reverted. Restore files byte-for-byte after mutating them.

## Commits and pushing
- Conventional commits with `Refs #N` or `Closes #N`. No AI attribution anywhere. No emojis.
- Never run a bare `git stash`.
- Push with `git -c credential.helper='!gh auth git-credential' push -u origin <branch>`.
- Do not open PRs and do not post comments. The main session does that.

## Final report
Report the branch and head, what was built, deviations, the verification numbers, and anything you could not verify.
