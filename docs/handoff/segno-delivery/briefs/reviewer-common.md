# Common brief for Segno adversarial reviewers

Repo: tomassasovsky/segno, a Flutter floor-console looper with a native C real-time engine. The working trunk is origin/claude/segno-integration.

## Where to work
- Check out the branches under review in temporary git worktrees under the scratchpad /private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy--claude-worktrees-chatgpt-tasks-review-fe30c8/f74678c2-31ab-4130-bbb0-2e6605cb052c/scratchpad/. Remove them at the end.
- Never touch /Users/Tomas/Documents/Work/opensource/loopy/.claude/worktrees/chatgpt-tasks-review-fe30c8 or another agent's worktree.
- Do not push, open PRs or post comments.

## What to review against
- The plan named in your task.
- AGENTS.md.
- The design: the main checkout's pen, /Users/Tomas/Documents/Work/opensource/loopy/segno-ui.pen, group "01 CURRENT UX". Read it only through the pencil MCP with that exact filePath, and never save it.
- The owner rules:
  1. preserve installs;
  2. fail safe with a recovery path;
  3. no silent behaviour changes;
  4. consolidate over duplicate;
  5. drop uncertain native state with a notice.

## How to review
- Be adversarial. Trace the real code paths, run the suites, and try mutations to find untested behaviour.
- Rank findings High, Medium or Low. For each give file:line, a concrete failure scenario, and a suggested fix.
- Separate findings from notes.
- Verify any claim before you make it. A wrong finding costs more than a missed nit.

## Tools
- Use /Users/Tomas/development/flutter/bin/flutter and /Users/Tomas/development/flutter/bin/dart. Bare `flutter test` and `dart test` are hook-blocked.
- Export SEGNO_ENGINE_LIB from `bash packages/segno_engine/tool/build_test_lib.sh`.
- For the native suites, mkdir a TMPDIR per run.

## Output
- Write each review to ~/.codex/segno-delivery/evidence/claude-published-review/<name>-in-session/review.md.
  - The first line is "Model: Claude Opus (subagent), in-session".
  - Then a heading "# Review of <PR or branch>: <title>", Scope, Runs, "Verified correct (traced)", Findings, and Notes.
- For a delta review of a file that already exists, append a "## Delta review (<head>)" section instead.
- End each review with a verdict line: Approve, or Request changes.
- Reply with the file paths, the verdicts, and the findings in one line each.
