# Rear-panel follow-up: test-quality review

Reviewed on 2026-09-05. Scope is the approved rear-panel change from 1.5 to
1.2 mm, the 0.06–0.10 mm coating allowance per face, the nominal finished
thickness guard, and the affected metal-assembly assertions. The earlier seven
regressions and the remainder of the branch were not reopened as a new review.

## Coverage summary

- Test run: **Pass — all eight tests**, 3.950 seconds, exit status 0.
- Runner: the enclosure's Python `unittest` suite, using the established CAD
  virtual environment and the supplied `MPLCONFIGDIR` setting.
- Coverage percentage: not collected. The CAD environment has no `coverage`
  module; no enclosure coverage threshold or CAD coverage job is configured in
  the inspected CI workflows. Dart coverage thresholds do not apply to this
  Python/CadQuery change.
- Affected testable code is covered by
  `hardware/enclosure/tests/test_manufacturing_fit.py`. No new independently
  testable unit lacks coverage within this bounded change.

Command executed from the review worktree:

```sh
MPLCONFIGDIR=/tmp/segno-fab-audit/mpl \
  /Users/Tomas/Documents/Work/opensource/loopy/hardware/enclosure/.venv/bin/python \
  -m unittest discover -s hardware/enclosure/tests -v
```

## Regression quality

`test_rear_panel_allows_coating_within_ctrl_jack_range` exercises the real
geometry validation entrypoint with the accepted parameters. Its expected
1.32 mm minimum and 1.40 mm maximum are concrete finished dimensions derived
from the approved stock and coating specification. They would catch accidental
changes to either coating allowance or stock thickness.

The two negative subtests change only the stock parameter, allowing the actual
validator to reject both failure directions: 1.0 mm stock yields a minimum
below the jack range, and 1.5 mm stock yields a maximum above it. Matching the
specific finished-panel error prevents an unrelated downstream geometry
failure from satisfying the test. Context-managed parameter replacement
restores the value after each subtest.

The assembly regression imports and checks generated solids. The panel is
identified by its stable 402 by 76 mm outline, so selection remains valid after
the thickness change. The assertions independently require a 1.2 mm thickness,
the new inner face at depth 417.710841 mm, and the retained outer seating face
at 418.910841 mm. They therefore catch the important geometry regression of
changing thickness while moving the seating face. Existing checks still
require all four panel mounting axes to align with the base.

No mocks of the subject under test, assertion-free tests, or assertions that
merely compare an implementation result with itself were found. The test suite
uses the same standard-library `unittest`, temporary-directory and scoped
patch conventions as the existing enclosure tests. State-management and UI
testing patterns are not applicable to this scope.

## Native evidence and limits

The supplied `panel-verification.json` records saved-and-reopened native
documents at sheet-metal version 129 and populated-console version 341. It
reports a 1.2 mm panel, unchanged outer seat, healthy extrusion, and no changes
to the bounds, volume or placement of the other 17 and 414 occurrences. This
supports the native-edit verification independently of the generated STEP
regression. This reviewer inspected that recorded evidence and did not control
or re-query Fusion.

These tests establish nominal digital dimensions. They do not measure actual
stock or coating, establish cap retention, or validate shop tooling and corner
details. Those limitations are explicit in the implementation and native
evidence; passing tests do not constitute fabrication approval.

## Anti-patterns and recommendations

No actionable findings in the bounded change. Additional broad test changes
are not required for this dimensional update.

## Verdict

**All tests pass the quality bar for the rear-panel follow-up.** No critical,
important or suggestion findings.
