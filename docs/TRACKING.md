# Tracking system — how work is tracked in this repo

One place to answer "what's done / in-flight / blocked / next" without reading
prose or reverse-engineering git. **Jira is the status layer; `docs/` stay the
deep intent.** Each Jira issue is a thin skin over work that already lives in
the repo and links to its brainstorm/plan doc.

This file is the contract. **Any session — human or agent — keeps it current.**

## Where the work lives

- **Jira project `SEG` ("Segno.")** on <https://aquiles-team.atlassian.net>
  (cloudId `8bd5ad29-9876-4571-adbf-07b7eeba3260`). Every piece of the owner's
  work is a `SEG-N` issue: a Task or a Bug, or an Epic with those under it.
- Agents read and write it through the Atlassian MCP connector:
  `searchJiraIssuesUsingJql` to find issues, `createJiraIssue`,
  `editJiraIssue`, `transitionJiraIssue` and
  `addOrEditJiraIssueComment`. With no Atlassian connector in the session,
  stop and tell the owner; do not track work anywhere else.
- **GitHub Issues are the public intake only.** Outside contributors file bugs
  and requests there, because the Jira project is private. Triage moves each
  one into Jira: create the `SEG` issue with a link to the GitHub issue,
  comment the key on GitHub, and close the GitHub issue.
- Issue numbers written `#N` in `docs/`, commit messages and PRs before
  2026-11-21 are GitHub issues. The open ones moved to Jira that day;
  `docs/tracking/github-to-jira.md` maps each number to its key.

## The board

The board's columns say where the work stands for the owner. Sprints are two
weeks; the owner plans each one from the backlog.

| Column      | Means                                                        |
|-------------|--------------------------------------------------------------|
| To Do       | In the backlog or the sprint, not started                    |
| In Progress | An agent session is working on it                            |
| Needs me    | Waiting on the owner; the issue's `needs-*` label says why   |
| Done        | Merged, or closed with a reason in a comment                 |

Move an issue by the column it goes to: `listJiraIssueTransitions` names the
transition that leads there. Transition ids are not written down here because
they change when the board's columns change.

Agents pick work from the active sprint first. An issue goes to **Needs me**
the moment its gate is reached: the plan is committed (`needs-plan-approval`),
the PR is ready to merge (`needs-merge`), or the build is green and waits for a
check on the console (`needs-hardware`).

## The pipeline (agent stages)

The agent's own progress is a `stage-*` label on the issue. It is for agents;
the owner reads the column.

```
brainstorm → plan → plan-review → build → in-review (PR: CI + code-review) → merged (Done)
```

| Stage label        | Advanced by                    | Proof artifact                     |
|--------------------|--------------------------------|------------------------------------|
| `stage-brainstorm` | `brainstorm` skill             | `docs/brainstorm/*.md` committed   |
| `stage-plan`       | brainstorm lands               | `docs/plan/*.md` committed         |
| `stage-plan-review`| `plan-technical-review` skill  | review notes / approval            |
| `stage-build`      | branch pushed / first commit   | branch + commits                   |
| `stage-in-review`  | PR opened naming `SEG-N`       | PR + `gh pr checks`                |
| (Done)             | PR merges                      | the agent moves the issue to Done  |

**Rule:** a branch is named `<agent>/<topic>-SEG-N`, and the PR title ends with
`(SEG-N)`. The PR body says `Closes SEG-N` for the PR that completes the issue,
and `Refs SEG-N` for stacked parts that leave work behind. One issue never has
two open PRs that both close it. Jira does not close issues from a PR, so the
agent that merges (or sees the merge) moves the issue to Done.

## The gate labels — which call needs the owner

Each issue carries exactly one gate label. It's a *ceiling*, not a mandate.
Decide it with three questions, in order:

1. **Can it be verified end-to-end here?** (native C tests + Dart tests + `analyze`
   + the `/code-review` skill can prove it). If **no** → `needs-hardware`
   (device-gated: "green in CI" ≠ "works"). Park until on-hardware.
2. **Does it need a judgment the owner owns?** Direction/product/architecture/
   licensing → `needs-plan-approval` (stop after the plan; the owner approves
   direction). Taste on the *result* (UX/visual) → `needs-merge`.
3. **Reversible + narrow blast radius?** No (irreversible/outward/wide) →
   `needs-merge`. Yes → `agent-merges`.

| Label                  | Agent does                              | Owner touches it        |
|------------------------|-----------------------------------------|-------------------------|
| `agent-merges`         | brainstorm → build → green → **merge**   | never (audit after)     |
| `needs-merge`          | build → green → stop                     | merges                  |
| `needs-plan-approval`  | brainstorm → plan → stop                 | approves direction      |
| `needs-hardware`       | build → green in CI, but can't prove it  | validates on hardware   |

Areas are labels too: `area-console`, `area-engine`, `area-fx`, `area-pedal`,
`area-appliance`, `area-enclosure`, `area-design`, `area-session`,
`area-updates`, `area-infra`. Priority is Jira's own field.

**Escalation is always allowed:** if an `agent-merges` item turns out to need an
architecture/direction call, stop, relabel it `needs-plan-approval` and move it
to Needs me rather than pushing through.

## The merge gate — "clean = CI AND no correctness findings"

A PR is only mergeable when **both** are green. Two PR labels on GitHub track it:

- `ci:red` → `ci:green` — from `gh pr checks`.
- `review:pending` → `review:clean` — after the `/code-review` skill runs and
  reports **no correctness findings**.

Only when both are green does the PR get `ready-to-merge`. CI green alone is not
enough.

How the review runs:

- **Once, when the work is complete**, not after every fix. Fix what it finds,
  then run it a second time at most. Two rounds is the cap.
- **Correctness findings block the merge.** A correctness finding is wrong
  behaviour: a bug, a crash, data loss, a broken contract, or something wrong
  on screen.
- **Cleanup findings do not block.** Reuse, simplification, efficiency,
  altitude and style findings go into the PR body under "Follow-ups", or into
  a follow-up Jira issue when they are worth doing. The review mode reports
  several findings every time, so "comes back empty" is not the bar.
- If correctness findings remain after the second round, the PR stays at
  `review:pending` and the agent reports them instead of starting a third
  round.

## Keeping it current (agent responsibilities each session)

- Starting a session? Run the session bootstrap in `AGENTS.md`. It lists the
  open Jira issues and the open PRs before anything is opened.
- Starting a thread? Find its issue first; open one only when no open issue
  covers the scope. Set one `stage-*` and one gate label, move it to In
  Progress, comment the branch name on it, and add the thread to **Active
  threads** in `docs/PROGRESS.md`.
- Stage changed, merged, or parked? Update the issue's labels and column and
  the thread's **Active threads** row. The PR that closes the issue removes
  its row.
- Opening a PR? Set `stage-in-review` on the issue, put `(SEG-N)` in the title
  and `Closes SEG-N` in the body, and add `ci:*` + `review:pending` to the PR.
- After running `/code-review` on a PR: set `review:clean` when no correctness
  findings remain (or leave `pending` and report them). List the cleanup
  findings under "Follow-ups" in the PR body. If `ci:green` too, add
  `ready-to-merge`, and move the issue to Needs me unless it is
  `agent-merges`.
- Finished a part of an Epic? Move that Task to Done.
- Merged? Move the issue to Done and comment the merge
  commit on it.

## Auto-merge (ON)

Agents **merge `agent-merges` PRs** with `gh pr merge --squash` the moment they
reach `ready-to-merge` (CI green AND no correctness findings from
`/code-review`), then move the issue to Done. No owner click for that class.
Everything else still ends on the owner's merge — those labels *mean* "the
owner owns this call" (taste, blast radius, direction).

To pause auto-merge on a specific issue, relabel it `needs-merge`.
