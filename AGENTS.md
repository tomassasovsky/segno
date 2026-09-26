# AGENTS.md

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

## Session context

- Read the "How to build / test" section of `docs/PROGRESS.md` before changing
  code. It is the source for environment gotchas and validation commands.
- Read `docs/TRACKING.md` for the issue, stage, autonomy, and merge contract.
  Preserve decisions and authorization already established in the task.
- The skills and workflow inventory is in `docs/CODEX_WORKFLOWS.md`. Use
  `$segno-context` for relevant private project history; verify dated facts
  against the current checkout and device state.
- Write plainly, without emojis or assistant co-author attribution.
- After compaction, re-read these instructions and the relevant progress and
  tracking sections before continuing. Update durable project documentation
  when work lands; do not put private machine details into this repository.

## Build and verification

- Resolve dependencies in a fresh checkout before formatting. Use explicit
  source directories or edited file paths; never run `dart format .` from the
  repository root, where it can traverse nested worktrees and generated code.
- Dart/Flutter tests use the working SDK command:
  `/Users/Tomas/development/flutter/bin/flutter test`. The Very Good MCP test
  parser is broken in this environment. Use the CLI; do not recreate the old
  Claude CLI-blocking hook.
- Native engine tests: `bash packages/segno_engine/src/test/run_native_tests.sh`.
  See `docs/PROGRESS.md` for sanitizer, telemetry-disabled, and C++ shim checks.
- Changes under `firmware/` or `packages/pedal_repository` require the pedal
  link contract test: `bash firmware/test/run_tests.sh`.
- After changing `packages/segno_engine/src/core/segno_engine_api.h`, run
  `dart run ffigen --config ffigen.yaml` from `packages/segno_engine`, then
  `dart format lib/src/generated/segno_engine_bindings.dart`.
- macOS development requires `--flavor development -t lib/main_development.dart`.
  Use `$run` for the app or enclosure viewer. Appliance-only behavior still
  needs device validation; a desktop launch or green CI does not prove it.
- Run the applicable analyzer, formatter, tests, coverage and other checks
  defined in `.github/workflows/`. Format shell-edited Dart files explicitly;
  the Codex patch hook cannot observe arbitrary shell writes.
- `dart analyze` and `bloc lint lib test packages` must both pass for Dart
  changes. Bloc lint enforces rules the analyzer does not. Verify it scanned
  the intended files; ignored worktree paths can produce a false no-op.
- UI work follows `segno-ui.pen`. Write intentional design departures back to
  the design source, save it, and verify the on-disk change. Consult
  `hardware/enclosure/FUSION_MODELS.md` before changing Fusion models.

## Tracking and review

Substantive work needs a GitHub issue with one `stage:*` and one `autonomy:*`
label. Trivial one-line fixes skip the issue. Follow `docs/TRACKING.md` within
the task's existing authorization; an unavailable external service does not
prevent preparing and verifying local work.

PRs link their issue with `Closes #N`, carry `stage:in-review`, the appropriate
`autonomy:*`, and `ci:*` plus `review:pending`. The bug-focused merge gate is
`$code-review`; `$review` adds the VGV architecture, test, and simplicity roles.
Use `$workflow-agents` for the role definitions those workflows require.

Set `review:clean` only after a complete review of the current PR head with no
unresolved actionable findings. Set `ready-to-merge` only when CI is also green
on that head. A push invalidates earlier review evidence. Merge `autonomy:auto`
work with `gh pr merge --squash` when the established authority and both gates
permit it. Respect `merge-gate`, `plan-gate`, and `blocked-verify` decisions;
do not ask again for approval already given.

## Code Review Rules

- Preserve presentation → bloc → repository → data boundaries. Presentation
  must not import data clients directly; `AudioEngine` is the test seam.
- Check real-time callback changes for allocation, blocking I/O, locks, and
  thread/ownership violations. Trace callers and removed invariants.
- Check C/FFI symbol parity and generated bindings when native APIs change.
- Verify behavior, including failure paths, instead of adding tests that only
  match source text. Keep author-only screenshot validation distinct from CI.
- Review only the intended changes. Preserve unrelated edits, generated CAD
  artifacts, and other agents' work; stage explicit paths before committing.
