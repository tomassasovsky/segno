---
name: ship
description: Open a PR that satisfies the docs/TRACKING.md contract — issue linkage, stage/autonomy/gate labels, and the CI pre-flight checks that are cheap locally and annoying to discover after the fact.
disable-model-invocation: true
---

# ship

Takes finished, verified work to an open PR that satisfies the tracking
contract in `docs/TRACKING.md`. Run `/verify` first — this skill assumes the
gates already pass and does not re-run them.

## 1. Pre-flight

```
bash .claude/skills/ship/precheck.sh "<proposed pr title>" [base-ref]
```

Checks the two CI gates that are cheap here and irritating in CI:

- **Semantic PR title** — CI runs `semantic_pull_request`, which checks the
  `type(scope): description` shape and nothing else. Lowercase subjects and no
  trailing period are house style, so precheck reports them as WARN, not FAIL —
  a local gate stricter than CI is one you learn to route around.
- **cspell over changed Markdown** — CI spell-checks `**/*.md` with
  `modified_files_only: false`, so one new word in a doc fails the run for
  everyone. Unknown-but-correct words go in `.github/cspell.json` under
  `"words"`, alphabetically.

Fix anything it reports before going further.

## 2. The issue

Substantive work needs an issue; trivial one-line fixes go straight to a PR
without one. If there is no issue yet, open one and label it with exactly one
`stage:*` and one `autonomy:*`.

Pick the autonomy label with the three questions from `docs/TRACKING.md`, in order:

1. **Verifiable end-to-end here?** No → `autonomy:blocked-verify` (hardware or
   device gated — "green in CI" is not "works").
2. **Needs a judgment you own?** Direction, architecture, or licensing →
   `autonomy:plan-gate` (stop after the plan). Taste on the *result* →
   `autonomy:merge-gate`.
3. **Reversible and narrow?** No → `autonomy:merge-gate`. Yes → `autonomy:auto`.

This is a ceiling, not a mandate. If an `auto` item turns out to need a design
call, stop and relabel it `plan-gate` rather than pushing through.

## 3. Commit and push

**Commit from a git worktree, not a shared checkout.** When two agents share one
checkout, `git add` sweeps up the other's in-flight edits — the result analyses
clean locally and fails CI with changes nobody meant to send. Stage explicit
paths, never `git add -A`.

`.claude/*` is gitignored except for the shared harness — `launch.json`,
`settings.json`, `hooks/`, `agents/` and `skills/` are negated, so plain
`git add` works there. Anything else under `.claude/` (`settings.local.json`,
scratch) stays ignored on purpose.

Push through the gh credential helper — the bare form hangs on osxkeychain here
and silently strands the branch. A `PreToolUse` hook denies it and reminds you:

```
git -c credential.helper='!gh auth git-credential' push -u origin <branch>
```

## 4. Open the PR

Body must contain `Closes #N` — the agent writes that line, not the human; it is
what auto-closes the issue on merge.

Labels at open: `stage:in-review`, the issue's `autonomy:*`, plus the two gate
labels `ci:red`(or `ci:green`) and `review:pending`.

## 5. Drive it to green

- `gh pr checks` → flip `ci:red` to `ci:green` when it passes.
- Run `/code-review`. Empty result → `review:clean`. Findings → leave
  `review:pending` and fix them.
- **Both** green → add `ready-to-merge`. CI alone is not enough.

## 6. Merge, or stop

- `autonomy:auto` → merge it yourself: `gh pr merge --squash`.
- `autonomy:merge-gate` and above → stop. The human clicks merge.

## Landing a stack

Squash-merging a stacked PR breaks its children's merge refs, so CI goes
*silently absent* on the child rather than failing. Deleting the parent branch
through the API closes the children outright. Re-target each child onto its new
parent before merging the one below it, and confirm checks actually ran.

## If the change touched design

A shipped departure from `segno-ui.pen` is a design change, not an
implementation detail: it belongs back in the pen with geometry and a `c/` note,
not recorded only in this PR body. The `design-conformance` subagent finds these.
