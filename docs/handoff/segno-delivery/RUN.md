# Authorized delivery campaign

Authorized October 1, 2026: run the full reviewed agentic delivery workflow
repeatedly so the user can review the result once. This extends execution
through M0-M7, not product scope or merge/deployment authority.

The user subsequently chose direct continuation in this chat. The heartbeat
`complete-segno-implementation` is paused; do not reactivate it without a new
request. The implementation/test/review/repair loop and consolidated review
remain authorized.

## Operating boundary

- Use the plan and `START.md`, with native Codex agents and their specified
  model/effort profiles. Maintain one coordinator, at most three workers and
  two builders, exclusive shared-file ownership and no recursive delegation.
- Each continuation resumes the last proven checkpoint; inspect live workers
  and processes before dispatch. Never duplicate an active slice or its tests.
- Complete and independently review each vertical slice, then advance without
  asking the user to approve routine implementation or review findings.
- Keep the PR stack and a combined integration candidate. Verified slices may
  await one final human review. At most two unverified slices may be in flight.
  Do not merge existing human-gated PRs or relabel them as auto to progress.
- Continue independent work when a slice needs unavailable hardware, external
  evidence or a new decision. Collect non-blocking limits for final review.
  Ask only when the missing input actually prevents useful authorized work.
- Preserve accepted decisions, UART/CTRL ownership and pending timing work.
  Never reset or abort that merge, copy unrelated owner changes, weaken tests,
  invent effect definitions, flash devices, deploy or change spending limits.
- Use independent behavioral expectations, adversarial review, bounded repair
  attempts and checks tied to the tested source. Do not repeat unchanged work
  without a new hypothesis, changed dependency or specific unresolved risk.

## Claude adversarial review

Authorized October 3, 2026: use Claude in addition to the native Codex reviewers.
Run bounded, independent read-only reviews through Claude Code; this does not
authorize Orca, a scheduler, implementation by the reviewer, or additional
merge/deployment authority. Count these reviewers within the existing worker
limit. Prefer the Fable alias with extra-high effort for architecture and
difficult failure-path reviews; Opus at high effort is an allowed fallback when
existing account access permits it. Record the actual resolved model with each
result. Never change billing or spending limits to obtain review access.

Give Claude the exact source revision, current-change binding, accepted behavior
and bounded scope before sharing author findings. Ask it to challenge ownership,
complexity, failure handling and the tests' assumptions. Require file/line,
trigger, impact, correction and an independent regression for each finding;
separate inherited debt and hypotheses from introduced defects. The coordinator
must verify and deduplicate results. A failed or incomplete Claude review cannot
count as clean, and unchanged source is not repeatedly reviewed without cause.
Cross-model review supplements the current-head CI and code-review gates.

## Checkpoint contract

At the end of each run, update the existing slice evidence and a compact
`CHECKPOINT.md` beside this file: current slice, checkout/branch, exact source
identity, active process/worker ownership, completed checks, open failure IDs,
and the next concrete action. GitHub remains the status authority; the
checkpoint is a resumption pointer, not a competing feature status database.
Keep private machine details and raw logs out of public project documents.

## Completion

Prepare one review package containing the runnable integrated app, a recorded
walkthrough of implemented journeys when capture is available, a map from
accepted requirements to implementation/evidence, the reviewed PR stack, and
any precise remaining hardware/source/CI limits. Finish all work verifiable in
the available environment; do not claim those external limits are solved.

Finish when the consolidated package is ready for the user's review. If no
useful authorized work remains until a concrete external change, report the
precise blocker and resume condition. Do not keep
replaying unchanged blockers or mark incomplete implementation complete.

This campaign runs directly in the chat, without a scheduler or separate Goal.
