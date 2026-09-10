# Simplicity review: closed stadium cable hole

Scope: the current cable-hole change against `/tmp/segno-cable-hole/before`, limited to `hardware/enclosure/segno_enclosure.py`. This is a local CAD change, not a review of the full branch or a production release.

## Core purpose

Replace each console collar's open-top cable slot with a closed vertical stadium, 8.6 mm wide and 13.5 mm tall with R4.3 ends. Preserve the existing bottom datum and the integrated mini enclosure's exit.

## Unnecessary complexity

None found. The existing measurement constants are reused. One upper-bound calculation completes the vertical clearance envelope; the existing console/mini distinction directly selects the requested closed profile or the unchanged mini slot. CadQuery's standard `slot2D` provides the exact stadium without a custom profile abstraction or a new dependency.

## Code to remove

None. The comments explain the material datum and the assumption that the measured fitting has a stadium profile. They are relevant to interpreting the nominal clearance and do not claim an unmeasured rectangular fitting will pass.

## Recommendations and YAGNI

No actionable findings. There are no speculative options, compatibility layers or duplicated geometry generators in this change. Estimated useful line reduction: 0.

## Assessment

Complexity: low. The scoped implementation is already minimal. The physical cable and connector still require a first-print fit check; this assessment makes no strength or production qualification claim.
