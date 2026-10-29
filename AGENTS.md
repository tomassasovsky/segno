# AGENTS.md

Instructions for every agent session in this repo. Claude Code reads this file
through `CLAUDE.md`. The repo is the only source of truth: build and status live
in `docs/PROGRESS.md`, the tracking contract in `docs/TRACKING.md`, and work
items in GitHub Issues.

## Session bootstrap (mandatory)

Do this at the start of every session, before brainstorming, planning, or
editing anything substantive.

1. Read `docs/PROGRESS.md`: **Active threads** and **How to build / test**,
   plus the status section for the area you are about to touch.
2. Read `docs/TRACKING.md`.
3. List what is already open:
   ```sh
   gh issue list --state open --limit 200
   gh pr list --state open --limit 200
   ```
   When the request names a specific feature, bug, or area, also search for it:
   ```sh
   gh issue list --state all --search "<keywords>"
   gh pr list --state all --search "<keywords>"
   ```
4. Find or open the issue:
   - An open issue already covers the scope: work under it. Update its
     `stage:*` label and comment with your branch. Do not open another issue.
   - An open issue covers part of the scope: comment there. Open a new issue
     only for the part it does not cover, and link the two.
   - A closed issue covers it and the work regressed or was never finished:
     reopen it, or open a follow-up that links it.
   - Nothing covers it: open one with exactly one `stage:*` and one
     `autonomy:*` label (definitions in `docs/TRACKING.md`).
   - A trivial one-line fix needs no issue. Go straight to a PR.
5. Check that the thread is free. If an open PR already references the issue
   (`gh pr list --state open --search "<N>"`; branch names carry the issue
   number), continue that PR or ask the user. Do not start a parallel one.

## Sibling repos

The design file and the hardware have their own repositories:

- [`tomassasovsky/segno-design`](https://github.com/tomassasovsky/segno-design)
  holds the design's history and studies. For UI work, clone it next to the
  main checkout, at `../segno-design` (worktrees find it there too), and run
  its `tool/setup.sh` once. CI's `design` job checks the app against the
  segno-design commit in `.github/segno-design.sha`; a change that needs a
  newer study updates that file. Locally the same checks read whatever your
  clone has checked out, so check out that commit to reproduce CI.
- [`tomassasovsky/segno-hardware`](https://github.com/tomassasovsky/segno-hardware)
  holds the boards, the enclosure and the printed parts. The firmware and the
  pedal link contract stay here under `firmware/`. A change to a board's pin
  map or to the link needs a PR in each repository, linked to each other.

## Design source

The UI design is the Penpot file **segno-ui** in project **Segno** on the
self-hosted Penpot at http://192.168.50.122:9001 (VM 100, home network only,
inside the VM's nightly backup). Each page is one design area, and the `c/`
notes on a screen card record the reasoning behind that screen.
`segno-ui.pen` in segno-design is the frozen last pen.dev version, kept for
history: do not edit it, and do not use Pencil or the pencil MCP tools. Code
comments, plans and reviews that cite pen frames (`segno-ui.pen`, "the
pen's", `AREA / name`) mean the same frames in the Penpot file.

- **A UI change updates the design.** Edit the Penpot file, then open a PR in
  segno-design that refreshes the snapshot (`tool/penpot-snapshot`, then
  commit `penpot/`), and link the two PRs to each other. A shipped departure
  from the design is a design change: write it into the Penpot file
  (geometry and a `c/` note) in the same pair of PRs, never only in the app.
- **Agents edit through Penpot's MCP server**, configured in Claude Code as
  `penpot` (user scope). It works only while a browser tab logged in to the
  server has the file open with the MCP plugin connected (the toolbar's MCP
  button). Writes apply only to the active page, so call
  `penpot.openPage(page)` before editing a page. With no such tab, ask the
  owner to open one; do not fall back to another tool.
- **API access** (snapshots, imports) uses the owner's access token in
  `~/development/penpot-server/.penpot-token`. Never print or commit it.

## Parallel work

- One issue is one thread. Each thread gets its own branch in its own git
  worktree. Never run two threads in one checkout, and never run two sessions
  on one thread.
- Name branches `<agent>/<topic>-<N>`, adding `-p<K>` for stacked parts
  (`claude/library-1178-p6a`).
- PR bodies reference the issue. The PR that completes it says `Closes #N`;
  stacked part PRs that leave work behind say `Refs #N`. Do not write
  `Closes #N` when another open PR already closes #N.
- Keep the **Active threads** table in `docs/PROGRESS.md` current in your
  branch: add a row when a thread starts, update it when its stage changes,
  and remove it in the PR that closes the issue (or when the work is parked).
  The issue labels remain authoritative where the two disagree.
- Ending a session with work unfinished: push the branch and leave a comment
  on the issue saying what is done, what is next, and anything the next
  session must know.

## Verify loop

Run the full suites once, before pushing. While iterating, run only the tests
for the code you touched (`flutter test <paths>`), and leave the rest to CI,
which runs everything on every push. Do not rerun the full Flutter suite after
each small fix.

Run these before calling a change done:

- Dart/Flutter tests: run `flutter test` through the absolute path in
  `docs/PROGRESS.md` "How to build / test". Bare `flutter test` and
  `dart test` are hook-blocked, and the very_good MCP test tool is broken
  here.
- Native engine tests: `bash packages/segno_engine/src/test/run_native_tests.sh`
- Pedal link contract test, required when anything under `firmware/` or
  `packages/pedal_repository` changes: `bash firmware/test/run_tests.sh`
- `dart analyze` must be clean.
- UI changes: delete `test/screenshots/goldens/` (ignored, so no stale PNG
  survives), render the screenshot suites with
  `flutter test --tags screenshots --update-goldens test/screenshots` (same
  absolute `flutter` path), and compare the new PNGs against the Penpot
  file. CI renders them too and uploads the `screenshots` artifact.
- `bloc lint lib test packages` must be clean. CI runs it as the `Bloc Lint`
  step, and it enforces rules `dart analyze` does not (a cubit method
  returning anything but void fails here and passes there).
- Formatting is automatic: a PostToolUse hook runs `dart format` on every
  edited `.dart` file that has a `.dart_tool/package_config.json` in its
  directory or an ancestor (it skips unresolved checkouts). Do not
  hand-format or commit format-only churn.
- Push with `git -c credential.helper='!gh auth git-credential' push`. A
  PreToolUse hook denies a bare `git push`, which hangs on the macOS keychain
  credential helper in the agent sandbox.

## Tracking

Pipeline stages, autonomy labels, the merge gate (CI green and no correctness
findings from `/code-review`, run once at the end and at most twice), and
auto-merge rules are defined in `docs/TRACKING.md`. Follow it as
written. If an `autonomy:auto` item turns out to need a design call, relabel
it `autonomy:plan-gate` and stop.

Stale-issue triage is a separate procedure:
`.claude/skills/stale-hygiene/SKILL.md`. It drafts and never closes on its own.

## Engineering principles

- Do not preserve backward compatibility. Remove obsolete paths instead of
  adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current
  requirements. Avoid speculative abstractions, configuration, and
  indirection.
- Grow the system in layers. Start from the smallest version that works end
  to end, and add each new capability on top of a product that already
  works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Study how established products solve the problem before designing a
  solution. Adopt their proven patterns and conventions rather than
  inventing an approach from scratch.
- Prefer established, well-maintained libraries when they reduce overall
  complexity or improve reliability. Do not reimplement common
  functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own
  implementation or adding packages. Do not assume a library lacks a
  capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap
  that only works for now and is meant to be replaced later.
