# Consolidated local design review

September 9, 2026 · Issue 919 · No PR, push or merge performed.

## Outcome

All five independent roles report zero unresolved actionable findings in their
stated scopes: [conventions](raw/vgv-review.md),
[architecture](raw/architecture.md), [test quality](raw/test-quality.md),
[simplicity](raw/simplicity.md), and [readiness](raw/pr-readiness.md).
The reports distinguish each reviewer's authored work from independent review.
The coordinator reconciled the fixes across reviewers; this is not a claim of
whole-project CI, production parity or hardware validation.

## Findings resolved

| ID | Problem | Resolution and evidence |
| --- | --- | --- |
| NC-01 | USB copies retained the originating drive identity. | Destination metadata, per-drive names and final identity checks; normal-host two-drive/race/rollback/reload checks pass in Chrome and Firefox, independently rechecked. |
| NC-02 | Unknown USB capacity appeared as zero. | Preserve unavailable state through formatting; browser checks the visible label. |
| NC-03 | A missing previously selected USB drive blocked selecting Internal. | Recorder preference publication is an internal metadata transaction; normal-host regression passes. |
| NC-04 | Storage's View transfer opened the wrong page during USB recording. | Opens the running recorder; browser navigation assertion passes. |
| NC-05 | Render recipes could reapply printed Pre and omitted rack channel processing. | Post-only runnable effects with effective placement and input/output/pan state; both-browser test verifies inclusion, source immutability and changed-plan detection. |
| NC-06 | Imported Follow-off duration ignored Multiply/Divide. | Scale original seconds by the current/original loop span; real import/edit/Save/reload proves 24 → 48 → 24 → 12 seconds. |
| NC-07 | An obsolete second render API contradicted the shared policy. | Removed duplicate function/tests and moved the remaining preview caller onto the shared policy; existing standalone tests and bounds pass. |
| NC-08 | A failed Cut take disappeared on New loop/session/restart. | Frozen capture participates in all relevant pending-work guards and final session publication checks. Independent 0.63-second recovery reproduction passes both browsers. |
| NC-09 | Frozen audio became invisible after the temporary notice. | Persistent Save held take cue plus physical Stop retry. |
| NC-10 | Tests missed saved capture-tap metadata and actual audio-node disposal. | Added finalized/catalogue/reload assertions and observable node-stop assertions. Independent injected regressions now fail. |

The old Bounce test assumed the prior settings-first startup and a pedal-map
Tracks page. It now uses the accepted normal Tracks entry and actual physical
pedal API. It also follows the accepted audio-edit history: later Play does not
block audio Undo. The full Bounce workflow passes both browsers without weakening
source/overwrite/grouped recovery or layout checks.

## Evidence limits

Original FX contracts and usable factory audio remain externally blocked, as
recorded in the [delivery](../../design/2026-09-09-non-production-completion.md).
That source limitation is not hidden by a clean bounded code review. Native
production is explicitly excluded. Pen and video are coordinator-owned visual
evidence; their saved artifact checks are recorded in the delivery manifest.

The raw reports bind the substantive source revision by hashes. A final
cache-fingerprint-only host update has a separate readiness addendum, preserving
the substantive review evidence while making current assets reload reliably.
