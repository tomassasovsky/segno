# VGV source-convention review

Reviewed authored source changes against `ffaa9552` on 2026-09-25 using the
VGV reviewer definition and build reporting contract. Scope: `check.py`,
`model_geometry.py`, and `pcb.py`, with generated native/model assignments
checked for consistency. Final protection documentation/readiness has a separate
owner. Critical: 0; Important: 0; Suggestion: 0.

## Regressions and architecture

No signatures, dependencies, existing public fields, or tests were removed.
The existing gate-drive acceptance calculation is algebraically unchanged;
its shared divider is reused for two clearly labeled informational supply
scenarios. Hardware validation still reports assembled qualification as not
performed. No nominal buck voltage is promoted into a verified loaded-board
supply floor.

Responsibilities remain in their established files: the numerical validator
reports circuit assumptions, the CadQuery source creates a component envelope,
and the PCB generator selects the appropriate bundled model. The new model uses
the existing save/add helpers and naming convention. No new runtime package,
configuration layer, alternative board variant, or application dependency was
introduced. Flutter presentation/state-management rules do not apply to these
Python CAD utilities.

R8's model selection follows the existing capacitor override pattern and fails
closed if its file is absent. The final native PCB has exactly one changed model
path relative to the baseline; the electrical and manufacturing geometry is
otherwise identical. The old generic resistor model remains used by other
references, so keeping it does not preserve an obsolete compatibility path.

## Validation and conventions

All three Python sources parse successfully. The independently executed
project-native validation passes ERC/DRC and all 36 fault controls. Required
input-voltage boundaries were independently calculated and checked on both
sides; R8-specific missing/disabled/unassigned models were independently
rejected. The report at `test-quality.md` records numerical evidence and exact
source hashes. No repository Python formatter/linter requirement was found for
this scoped utility change; added code follows the surrounding conventions.

The model is described as simplified maximum-envelope assembly geometry rather
than vendor CAD. Its constants are identified with a manufacturer drawing and
the informational calculations identify their component assumptions. No
unsupported certification or assembled-performance claim is added by these
source changes.

## Verdict

Source changes meet the applicable project conventions. Mechanical envelope
verification and final documentation/publication validation are separate review
scopes. This verdict does not authorize manufacture or merge independently of
those gates.
