---
name: stale-hygiene
description: Classify open GitHub issues and PRs as done, duplicate, superseded, stale, or active, and draft closing comments with evidence. Use when the user asks for a triage, backlog cleanup, or stale-issue sweep. Drafts only; never closes, relabels, or comments without per-item approval.
---

# Stale hygiene

Produce a triage report the user can approve item by item. This skill never
closes, relabels, comments on, or deletes anything by itself.

## 1. Collect

```sh
gh issue list --state open --limit 500 --json number,title,labels,updatedAt,body
gh pr list --state open --limit 200 --json number,title,headRefName,baseRefName,updatedAt,body,closingIssuesReferences
```

Narrow to the scope the user named (an area label, an age, an epic) before
classifying.

## 2. Classify each item

Every class except `active` and `stale` needs evidence: a link a reader can
open.

| Class | Meaning | Required evidence |
|-------|---------|-------------------|
| `done` | The work landed but the issue stayed open | Merged PR number or commit SHA on `master` that delivers the scope (`gh pr list --state merged --search`, `git log --grep`) |
| `duplicate` | Another issue covers the same scope | `Duplicate of #N`, naming the issue that keeps the history (usually the older one or the one with the PRs) |
| `superseded` | A later decision or issue replaced it | The issue, PR, or doc section that replaced it |
| `stale-pr` | Open PR whose branch is merged, abandoned, or replaced | The replacing PR, or the merge that already contains its commits |
| `stale` | No activity and no evidence either way | None. Flag for the user; never propose closing it |
| `active` | Live branch, recent commits, or an Active threads row | None |

If the evidence is partial (a PR delivered some of the scope), classify the
item `active` or `stale` and say what remains. Do not round it up to `done`.

## 3. Report

Write the report to a temporary file outside the repo and show it to the
user. One row per item: number, title, class, evidence, and the exact comment
you would post. Draft comments state the evidence, for example:

> Delivered by #1234 (merged 2026-09-30, commit abc1234). Closing as done.

> Duplicate of #1178, which carries the Library work and its PRs.

Also list label drift you noticed (a `stage:*` label that lags its PRs), and
rows to add or remove in the Active threads table in `docs/PROGRESS.md`.

## 4. Apply only what the user approves

Act only on the items the user approves, one `gh` call per item, posting
exactly the drafted comment. Never batch-close by query. If the user approves
"all done items", re-check each item's evidence before closing it.
