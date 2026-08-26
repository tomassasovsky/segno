# Closing the FX v3 console redesign epic (#442)

Status: **restructuring recommendation, not a build plan.** The epic's
remaining scope is fully externalized into trackers of their own, so the one
reason the last board sweep kept it open no longer holds.

## Current state (verified 2026-08-25 against master + issue history)

The 2026-08-09 and 2026-08-20 sweeps on #442 confirmed everything else
shipped through the console IA rebuild (#498, closed): drawer rail + domain
tabs (#515–#594, rail finalized #626), the 7" permanent readout (#487),
Signal as one rail destination with four stage tabs (#578, old surface
removed in #594), monitor tri-state (#576), the tuner (#577/#579/#582,
closed #482), and pedal assignment on console (#485 → Control domain #538).

The 2026-08-20 sweep trimmed the remaining scope to exactly two items and
kept the epic open **only because item 2 had no tracker of its own**:

1. Part 3, named racks — tracked as **#535** (open, `stage:plan`, plan doc
   `docs/plan/2026-08-25-feat-named-racks-plan.md`).
2. Custom pedal mode + protocol v4 — since given its own tracker, **#763**
   (open, `stage:brainstorm`), which also absorbed the untracked
   switch-behavior scope cut from the old FX screen redesign.

Both facts re-verified today: #763 exists and states it is "the second
surviving scope item of epic #442"; `pedal_codec.dart` still speaks v3 with
mode value 3 reserved-and-rejected (the cost lives in #763 now, where it
belongs). The part-9 hardening tail belongs to engine epic #351's lineage
and is tracked by #417. Nothing else in the epic body or comments is
unshipped and untracked.

## Decision for the owner

**Should #442 close now?**

- **Option A — close it, with a closing record.** Every surviving scope item
  has a dedicated tracker (#535, #763) that names #442 as its origin, so
  nothing loses its only tracker — the condition the 2026-08-20 sweep set
  for keeping it open is satisfied in reverse. The epic's plan (PR #480) and
  decision records D1–D7 stay linkable from the closed issue.
- **Option B — keep it open as a passive umbrella** until #535 and #763 both
  land. Costs a permanent `stage:plan` P1 row on the board that no one will
  ever build *as #442*; the board reads one more open epic than there is
  work.

**Recommendation: Option A.** The repo's own precedent is #351: an epic
closes when its remaining tails have their own trackers, even while those
tails are open. A closing comment should pin the two successor issues and
note that D1–D7 (racks scope, frozen-copy inheritance, migration, FX-mode
track chains, auto-follows-armed, tuner slot, 7" rigidity) remain the
binding decision record for both successors.

## Implementation outline

1. Post the closing comment on #442: shipped list (one line), successors
   #535 + #763, pointer to PR #480's D1–D7.
2. Close #442. No label surgery needed beyond the close.

## Verification plan

Board-level only: `gh issue view 442` shows CLOSED with the closing record;
#535 and #763 remain open and each references #442.

## Acceptance criteria

- #442 closed with a comment enumerating successors and the decision record.
- No scope item from the 2026-08-20 sweep left without an open tracker.

## Non-goals

- Building anything. #535 has its own plan; #763 is still in brainstorm and
  needs its product-direction call (what the custom mode binds to) before a
  plan exists.
- Re-litigating D1–D7. They are pinned in PR #480 and carried by reference.
