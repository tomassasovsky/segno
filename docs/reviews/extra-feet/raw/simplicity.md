# Extra-feet code simplicity review

## Scope and method

Reviewed `/tmp/segno-extra-feet/incremental.diff` against the supplied before
snapshot, then read the current source, new floor-support tests, and affected
process documentation. The larger working-tree diff contains earlier work and
was not treated as this change. Native edits, formed exports and the final shop
archive were still in progress and are outside this source review.

This was a static simplicity review. I did not rerun the CAD suite or assess
structural strength, material temper, actual purchased hardware, or production
readiness.

## Simplification Analysis

### Core Purpose

Retain four existing feet and add eleven useful floor supports; use one layout
for cutting and the preview; guard nominal hardware clearance; and correct
process prose to distinguish the 18 lid pilots from 14 screen-support pilots.

### Unnecessary Complexity Found

One non-blocking redundancy was introduced by the stronger head-clearance guard.

- `hardware/enclosure/segno_enclosure.py:1917` still calls `foot_relief_xy()` to
  reject foot centres inside a pedestal, immediately before the new test at
  line 1921 rejects the full head envelope against the same rectangles.
- For every centre inside the rectangle, the new calculation has `du = dv = 0`,
  so it necessarily fails the positive head-radius clearance condition. The old
  check therefore cannot reject an additional configuration.
- A repository-wide reference search found `foot_relief_xy()` has no callers
  other than that obsolete guard. Its optional row filter, coordinate transform,
  rounding, set construction, and sorting no longer serve the current design.
- Keep the finite head-envelope guard and its per-pedestal error. Remove the old
  centre-only guard and helper, and update the adjacent comment. No geometry or
  clearance coverage is lost.

### Code to Remove

- `hardware/enclosure/segno_enclosure.py:1917`: the centre-only check and its old
  explanatory comment, superseded by the new head-envelope check.
- `hardware/enclosure/segno_enclosure.py:3396`: `foot_relief_xy()`, once the sole
  call above is removed.
- Estimated reduction: approximately 28 lines, including obsolete comments and
  the helper docstring.

### Simplification Recommendations

1. Consolidate pedestal clearance on the new finite-radius guard.
   - Current: two passes over the same foot/pedestal pairs, with a specialised
     coordinate-reporting helper for the weaker condition.
   - Proposed: retain only the full-head clearance calculation and diagnostic.
   - Impact: one source of the clearance rule, about 28 fewer lines, no geometry
     change. Severity: Suggestion.

The remaining added source is appropriately small. The layout is derived from
existing pedal/post geometry without a new configuration or dependency layer.
The frozen middle depth is explicitly identified as an inspected fit station;
turning this into a general placement optimiser would add unjustified scope.
The renderer reuses the cutting layout and foot dimensions.

The new test helpers are proportionate to their purpose. Frozen expected
stations avoid deriving expected output from `base_foot_xy()`. Bounding-box
rejection reduces unnecessary solid distance work, while the hollow screen
tower case deliberately exercises exact geometry. The deliberately bad board
and tower stations confirm that the clearance checks can reject collisions.
Their separate clearance concerns should not be combined merely to shorten
the file.

### YAGNI Violations

The now-redundant centre-only helper is the only removal opportunity identified.
No new speculative abstraction, dependency, compatibility path, or unused
product feature was found. No documentation is recommended for removal.

### Final Assessment

- Critical findings: 0.
- Important findings: 0.
- Suggestions: 1.
- Potential reduction: about 28 lines; under 1% of the generator.
- Complexity score: Low.
- Recommended action: Minor simplification only; no source-level simplicity
  blocker identified in this incremental change.

This conclusion does not establish a force rating or release the enclosure for
manufacture. The documentation correctly keeps actual hardware, floor contact,
material temper and assembled load performance as unresolved qualifications.
