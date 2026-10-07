# Resume Segno delivery

<!-- cspell:words xhigh -->

Use `docs/plan/2026-09-30-feat-agentic-delivery-plan.md` as the operating plan.
The user authorized efficient Codex subagent coordination, with explicit models,
efforts and escalation. Use Codex subagents, not Orca or new sidebar tasks.
On October 1 the user authorized running the full workflow repeatedly through
completion with one consolidated review. Read `RUN.md` in this directory for
the execution boundary and continuation checkpoint.

Read `AGENTS.md`, the build/test section of `docs/PROGRESS.md`, and
`docs/TRACKING.md`. Refresh GitHub state and available model/effort choices.
Accepted product behavior is in `docs/handoff/segno-app/accepted-behavior.md`
and the latest linked design decisions. The old implementation handoff is
historical; it does not override UART/CTRL authority or later approvals.

Read `CHECKPOINT.md` before dispatching work. The timing reconstruction
(#1061 / PR #1014) is now published and verified; do not restart it. Continue
from the current M1 candidate and its explicit open findings, then advance
through M2–M7. Preserve any pending merge and working edits; never reset, abort
or repeat it. Use the existing managed checkout, not the dirty owner checkout.
Complete local checks and independent review before explicit-path staging and
publication. Push to obtain remote CI; publication is not merge readiness.
After pushing, establish CI and review evidence for that exact PR head before
marking it ready. Absent or pending CI remains an unmet gate.

Coordinator: GPT-6 Sol high. Scout/verifier: GPT-6 Luna high. Ordinary builder
and reviewer: GPT-6 Sol high. Native audio, storage atomicity and critical
review: GPT-6 Astra high. Bounded hard-failure escalation: GPT-6 Astra xhigh.
If a model is unavailable, report that and select a supported alternative
explicitly; do not claim a different model ran.

At most three subagents and two builders; one writer per shared native,
session, FFI or action contract. Give each worker its own explicit checkout,
exact revision, bounded file ownership, acceptance tests and return format.
Only the coordinator integrates and publishes. No recursive delegation.

Use focused tests while editing, frozen-candidate integration checks, and the
required independent review roles. Preserve all existing issue autonomy and
human merge gates. Store durable evidence with exact revision/fingerprint.
Missing CI or hardware proof stays missing. Do not weaken tests or guess
unknown effect definitions to report completion.

Adversarial review is mandatory: an independent reviewer tries to falsify the
accepted behavior before reading the author's success narrative. Use Sol high
for UI-only changes and Astra high for native, session, storage, controller or
shared-state changes. Require reproducible failures or concrete source paths,
then repair and independently recheck. No unresolved actionable finding may be
waived. The adversary uses a rotating worker slot, not extra concurrency.

Prevent circular validation: freeze expected outcomes from accepted behavior
before editing; derive expected samples/state independently of production
helpers; establish regression failure sensitivity where feasible. Round-trip
tests, mocks and regenerated goldens are not sufficient alone. Keep one failure
table with one owner per root cause. Rerun only after relevant changes or new
evidence, investigate flakes rather than rerunning until green, and reuse checks
only with matching source/build/environment fingerprints. Use `dart analyze --fatal-infos` and inspect the diagnostic summary: a zero
exit code without that option can still report unresolved lint findings.
Deliver when all required gates pass; do not invent further test cycles or
waive existing bugs.

After two distinct failed repairs, escalate the reproducer and patch rather
than restarting. Ask the user only for a new product choice, missing required
input, hardware access, or an existing human approval boundary. Continue other
ready work when one item waits.

Save concise checkpoints: delivered, verified, remaining gate, next slice.
Collect routine reviews into the final package; request input only for a new
product decision or essential external dependency. Continue directly in this
chat under `RUN.md`; the heartbeat is paused at the user's request. No separate
Goal is required or currently activated.
