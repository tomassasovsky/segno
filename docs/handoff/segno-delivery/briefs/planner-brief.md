Repo: tomassasovsky/segno, a Flutter floor-console looper with a native C real-time engine. Work only in a temporary git worktree you create under /private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy--claude-worktrees-chatgpt-tasks-review-fe30c8/f74678c2-31ab-4130-bbb0-2e6605cb052c/scratchpad/ from origin/claude/segno-integration (the working trunk; fetch first). Never touch /Users/Tomas/Documents/Work/opensource/loopy/.claude/worktrees/chatgpt-tasks-review-fe30c8.

Read first:
- AGENTS.md;
- docs/PROGRESS.md "How to build / test";
- docs/handoff/segno-app/accepted-behavior.md;
- docs/handoff/segno-app/implementation-map.md;
- the gap inventory at /private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy--claude-worktrees-chatgpt-tasks-review-fe30c8/f74678c2-31ab-4130-bbb0-2e6605cb052c/scratchpad/gap-inventory.md.

THE DESIGN SOURCE is the 107 MB pen at /Users/Tomas/Documents/Work/opensource/loopy/segno-ui.pen, group "01 CURRENT UX". Read it ONLY through the pencil MCP tools (load them with ToolSearch "select:mcp__pencil__execute,mcp__pencil__read_skill"; read the skill's execute.md first) and ALWAYS pass that exact filePath. Never use the 11 MB pen committed in git. Never edit or save the pen.

Owner decisions:
- The settings tray and the Bluetooth page are retired.
- DAW export is kept, re-homed under Library > Audio.
- Computer-facing USB gadget mode is out of scope.

Standing rules for open points:
1. Preserve existing installs' behaviour.
2. Fail safe, keep audio running, and always leave a recovery path.
3. No silent behaviour changes.
4. Consolidate over duplicate.
5. Drop uncertain native state with a notice.

Flag only genuine product-direction questions.

Write a plan in the repo's plan style: see docs/plan/2026-10-05-feat-stem-history-replay-plan.md and docs/plan/2026-10-05-feat-engine-reopen-plan.md on the trunk. Ground every claim in file:line, and name the pen screens the work must match. Split it into independently mergeable parts of about 700 production lines or fewer. Each part needs a success-criteria block with verify commands, using /Users/Tomas/development/flutter/bin/flutter and bash packages/segno_engine/src/test/run_native_tests.sh, and native tests with literal oracles where native work is involved. Mark which criteria need physical hardware.

Save the plan to docs/plan/<name>.md on a new branch, commit with "docs(plan): ..." and "Refs #<issue>" and no attribution, and push it with: git -c credential.helper='!gh auth git-credential' push -u origin <branch>. Do NOT open PRs or post comments. Remove your worktree at the end.

Reply with: the branch, the plan path, the parts with sizes and dependencies, the decisions taken, and any genuine questions.

Additional owner decisions since this brief was first written:
- Build both pen section 10 proposals: the Pending Hold cue, and FX Toggle/Hold per pedal.
- Saved v7 sessions are migrated on open (#1196). Every new session schema bump must add its migration step to that chain.
- Fable is unavailable. Do not request it.
- The trunk now also has: settings consolidation (#1159), Reverse P1, Peel P1, pitch/time P1, USB storage P1 to P3 (with P4 to P5 in flight), and Library P1 to P3 (in review).
