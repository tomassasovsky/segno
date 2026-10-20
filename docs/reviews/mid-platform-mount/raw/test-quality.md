# Test quality review — mid platform mounting

Scope: the approved two-joint CLEAR/BANK mounting change, the dedicated mid
sled, updated print-package selection and affected Python CAD regressions.
Reviewed against the captured pre-change source and test baseline. No
implementation, export or Fusion changes were made by this reviewer.

## Coverage and execution

- Stack: Python `unittest`, CadQuery/OpenCascade, generated STEP round trips
  and independent assembly datums. Dart state-management/UI conventions do not
  apply to this CAD-only change.
- Final complete validation passed: 56 tests in 73.636 seconds, including the
  additional assembly-validator regression reviewed below. The final run
  supersedes the intermediate 55-test result.
- The initial complete run executed 55 tests in 74.048 seconds. Its only
  failure was the previous print-archive expectation of 36 members: adding
  the dedicated mid sled correctly produces 38.
- The expectation was corrected and explicit assertions now require both
  STEP and STL files for the front and mid sleds. The reviewer independently
  reran the exact previously failing test on that revision: one test passed
  in 2.729 seconds. The other 54 tests passed in the complete run; their
  implementation and test assertions were unchanged by this correction.
- Earlier focused validation reported 22 passing geometry tests. The new
  test module supplies six behavior tests; existing coating, floor-support
  and collar tests exercise the new mid variant in the wider assembly.
- No CAD-specific coverage percentage or threshold is configured. No numerical
  coverage claim is made, and the unrelated Flutter coverage gates were not
  applied to Python geometry.
- Whitespace validation passed for the affected test paths.

## Behavior checked

- Real cylindrical faces prove four blind, bottom-facing insert pilots on
  the unchanged base axes, with complete circumferential area and the intended
  depth. Positive solid probes prove that the old long passages are filled
  and that the insert pilots have intact roofs and supporting column walls.
- Independent hardware envelopes check M3×6 screw reach through bare and
  coated base stacks, plus screw-tip clearance. These are nominal geometric
  engagement checks, not a prediction of thread strength.
- The separate 60 ×36 mm deck pattern is checked against fixed approved
  datums. M3×12 shaft and head envelopes clear the assembled parts, the head
  contacts an intact bearing annulus, and a straight Ø8 mm driver envelope
  reaches the underside. A deliberately displaced shaft must collide with
  material, preventing an empty-cavity false positive.
- The dedicated mid sled keeps its top pedal-insert pattern and closed lower
  pilots. Actual Ø5 mm insert envelopes retain surrounding material and do
  not intersect the top inserts. Boolean differences outside the old/new
  lower-pocket regions must be zero, protecting the seating outline, toe
  relief and pedal interface.
- Seated and lifted sled poses verify insertion/removal clearance and final
  contact. Both row variants retain their dimensions and 0.2 mm sliding fit.
- Existing closed-stadium and wall-thickness assertions still cover both
  collar heights. Coating-extreme and floor-obstacle checks now place the
  dedicated mid sled at the independently captured CLEAR/BANK transforms.
- Source/export evidence independently confirms unchanged front collar and
  front sled geometry, and confines tall-part differences to the approved
  mounting bores. Native comparison evidence was inspected as supporting
  integration evidence, not presented as a substitute for source tests.
- The final assembly-validator regression executes the real
  `_fold_from_dxf.build()` path with only the unrelated metal/electronics
  builders stubbed. All ten generated collars and ten generated sleds are
  compared to the real STEP exports in both Boolean directions, using frozen
  assembly positions and row heights. The constructors and row-selection
  logic under review remain real. This catches stale front-only sled
  selection, old collar walls, wrong heights and wrong rotations. The author
  also reported a mutation that forced front sleds into every row and failed
  specifically for sleds 8 and 9; this reviewer inspected the test and final
  passing full-run log without duplicating execution.

## Test design quality

The tests generate and re-import real STEP solids; they do not mock geometry
or reproduce generator helper results as expected values. Shared temporary
exports are cleaned up. Fixed dimensional requirements are explained in
comments and checked through faces, volumes, clearances and contact rather
than source-text assertions. Checks for remaining material complement the
empty-volume checks, so simply deleting material cannot satisfy the principal
mounting assertions.

The updated manufacturing pipeline test retains the established archive
exclusions and adds explicit membership checks for the new printable part.
The initial stale count was identified and resolved during this review.

## Limits and verdict

No unresolved actionable test-quality findings. The checked geometry supports
the stated bench-assembly and module-removal sequence. Generic insert fit,
printed tolerances, support removal, tightening retention and loaded PETG
performance still require the intended first-print verification; these tests
do not claim to qualify those physical properties.
