# FX readiness and reentrant settlement review

Issue #1105, part of #1026. Reviewed October 4, 2026 against
`b143c31378a2083ffa83738f7ab0c0654d7fd38c`. Human merge gate retained.

## Scope and review

Two files isolate the previously repaired readiness getter, history drain and
explicit settlement behavior, plus two regression tests. The coordinator reviewed
the complete extraction and traced polling, Clear/Undo, target admission, boot
settlement and persistence callers. The getter and both methods match the
independently reviewed integration source. Prior source/adversarial review is
reused for those exact mechanisms; no new independent extraction review is
claimed.

Readiness compares exact callback revisions without submitting work or retiring
state. Explicit settlement drains history after its existing lifetime checks,
and repository polling still advances queued work. Target admission retires
confirmed receipts, so removing mutation from the getter does not strand a
target. History remains bounded by lane coordinates.

The history loop copies keys but obtains each value from the live map. A nested
drain can service another lane without leaving a stale outer-loop value to
submit again. Existing receipt fences, refusal retention and notifications remain
unchanged. No second queue, recursion flag, timer or general framework is added.

## Regression evidence

Both cases failed before their respective fixes during the architecture audit.
The first observes that reading readiness submits no recipe, then verifies
explicit settlement applies the empty chain. The second deliberately re-enters
settlement from a lane callback and requires exactly two submissions and two
ordered notifications for two lanes, with both final chains empty. Expected
results are not calculated through production helpers.

The isolated repository suite passes 686 tests with 12 native-conditional skips.
Strict package analysis, explicit two-file formatting and the positive Bloc scan
pass. The full app passes 2,676 tests with 124 conditional skips and
91.075% filtered coverage; repository coverage is 95.012%. The two
source hashes remained unchanged during validation.
Earlier native/import/owner changes in the integration checkout are not included.

No unresolved actionable finding remains in this bounded review. Hardware and
remote current-head CI are separate gates. A clean source review does not grant
merge authority or certify the entire repository's unrelated transaction code.
