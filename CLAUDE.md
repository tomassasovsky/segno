# CLAUDE.md

Guidance for any agent session in this repo. Keep it lean — it loads into every session.

## Engineering principles

How to make design and implementation calls in this repo lives in
**`AGENTS.md`** at the repo root — read it before designing anything.

## Build / test / environment

Canonical build, test, and environment gotchas live in **`docs/PROGRESS.md`** —
read its "How to build / test" section first (test runner, hand-authored FFI
plugin, macOS dylib loading, flavor schemes). They will bite otherwise.

### Verify loop — run these before declaring any change done

**`/verify` runs the applicable subset of the list below for you**, picking
gates from what the diff touches and printing one PASS / FAIL / SKIP / UNRUN
line each. Prefer it over running these by hand: it knows the SDK path, the
per-package test jobs CI runs that a root `flutter test` does not, and the
difference between "this gate does not apply" and "this gate could not run".
`/ship` then takes verified work to a PR that satisfies `docs/TRACKING.md`.

- Dart/Flutter tests: `/Users/Tomas/development/flutter/bin/flutter test`
  (bare `flutter test`/`dart test` are hook-blocked; the very_good MCP test
  tool is broken in this env)
- Native engine tests: `bash packages/segno_engine/src/test/run_native_tests.sh`
- Pedal firmware contract + protocol-copy drift gate (required when anything
  under `firmware/` or `hardware/firmware/` or the pedal codec changes):
  `bash firmware/test/run_tests.sh`
- Static analysis: `dart analyze` must come back clean
- Bloc lint: `bloc lint lib test packages` must come back clean. CI runs this
  as the `Bloc Lint` step of the reusable `flutter_package.yml`, and it carries
  rules `dart analyze` does **not** — a cubit method returning anything but
  void fails here and passes there
- Formatting is automatic — a PostToolUse hook runs `dart format` on every
  `.dart` file edited through `Edit`/`Write`, so never hand-format or commit
  format-only churn. It does **not** see edits made through the shell (`sed`,
  `python3`, a heredoc); `/verify`'s `dart format --set-exit-if-changed` gate
  is what catches those
- Pushes must go through the gh credential helper —
  `git -c credential.helper='!gh auth git-credential' push`. A PreToolUse hook
  denies the bare form, which can hang on osxkeychain and strand the branch
  with no error anyone sees

### Two reviewers worth calling explicitly

Neither is dispatched automatically:

- **`native-boundary-review`** — for any diff under `packages/segno_engine/src`,
  `firmware/`, `hardware/firmware/`, or the generated bindings. It looks for the
  portability, generation and hand-copy failures that a green macOS CI run and
  `dart analyze` cannot see.
- **`design-conformance`** — for any console/tray/settings surface, before the
  PR. It checks the shipped UI against `segno-ui.pen`, the design of record, and
  says for each divergence whether the code drifted or the design moved.

## Work tracking (required)

Work is tracked as **GitHub Issues on a pipeline board**. Full contract:
**`docs/TRACKING.md`**. The pipeline is:

```
brainstorm → plan → plan-review → build → in-review (PR: CI + code-review) → merged
```

**Before starting _substantive_ work** — a feature, a multi-step change, anything
entering brainstorm/plan, or work spanning multiple files or sessions:

1. Find its existing issue, or **create one** if none exists.
2. Label it with one `stage:*` (pipeline position) + one `autonomy:*` (below).
3. Keep the `stage:*` label (or board Status) current as it moves.

**Trivial one-line fixes do NOT need an issue** — go straight to a PR. Don't
flood the board with ceremony for one-liners.

**On every PR:**
- Put `Closes #N` in the body so the merge auto-closes the issue.
- Label `stage:in-review`, the right `autonomy:*`, and the gate labels `ci:*` + `review:pending`.
- A PR is mergeable **only when CI is green AND `/code-review` comes back clean.**
  When both hold, add `ready-to-merge`.

### Autonomy — which gate needs a human (one label per issue, a ceiling not a mandate)

- `autonomy:auto` — verifiable here + reversible + narrow → take to green and **merge it** (`gh pr merge --squash`) once `ready-to-merge` (CI green + `/code-review` clean). No human click.
- `autonomy:merge-gate` — verifiable but taste / blast-radius → build, human merges.
- `autonomy:plan-gate` — needs a direction / architecture / licensing call → stop after the plan.
- `autonomy:blocked-verify` — hardware / device-gated; "green in CI" ≠ "works".

Decide with three questions in order: (1) verifiable end-to-end here? no →
`blocked-verify`. (2) needs a judgment you own? direction → `plan-gate`, taste on
the result → `merge-gate`. (3) reversible + narrow? no → `merge-gate`, yes → `auto`.

**Escalation is always allowed:** if an `auto` item turns out to need a design
call, stop and relabel it `plan-gate` rather than pushing through.
