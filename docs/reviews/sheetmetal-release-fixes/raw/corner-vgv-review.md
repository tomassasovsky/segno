# VGV Code Review — corner reconciliation

## Summary

The corner changes use the existing generator parameters and retain the distinction between laser contours and deferred drilling. Replacing the original base CUT-sketch equality with a comparison against the real unfolded body is appropriate for a base whose outline changes through later trim features. The new flat comparison catches the documented relief, end-trim, moved-hole and missing-drill regressions, and all nine existing tests pass. One verification gap must be closed: outside cutting contours are silently discarded before the material comparison.

## Critical — Must Fix Before Merge

- **hardware/enclosure/flat_pattern_check.py:44 — Reject cutting contours outside the selected sheet.** `_profile` selects the largest contour as material and subtracts every other contour as a hole. An additional contour entirely outside that material has no Boolean effect and is silently ignored; the subsequent one-face assertion therefore still passes. I added a closed 10 ×10 mm square on CUT at x=1200..1210, y=0..10 to a temporary copy of the current source DXF. `compare_base_flat` accepted it with 107 matched reference holes, 0.0 mm² missing and 0.0 mm² extra area. Because the exporter now intentionally skips original base CUT-sketch equality, this leaves no check against that unintended extra laser contour.
  - Why: The new certification can claim all CUT geometry matches the native flat even when the laser file contains an extra disconnected contour.
  - Fix: Reject contours with no area intersection with the selected connected sheet, or classify material/holes explicitly, while allowing the documented corner-relief circles that partly overlap the outer contour. Add this outside-contour negative test alongside the current relief/trim/hole mutations.

## Important — Should Fix

None beyond the verification issue above.

## Suggestions — Nice to Have

None.

## Simplicity Assessment

The standalone comparison helper has one clear responsibility and relies on the existing ezdxf and CadQuery dependencies. The four proper rotations and hole registration serve the known Fusion export frame differences without allowing mirroring. The fix should stay in this existing profile-validation step; no new abstraction or alternate geometry path is needed.

## Testing Assessment

- Nine regression tests passed independently in 7.580 seconds.
- Current flat comparison reports zero missing/extra area for the actual corrected source/native pair.
- Negative tests meaningfully exercise Ø6.0 versus Ø6.5 reliefs, the 0.15 mm front trim, a moved mounting hole and omitted deferred drilling.
- Independent outside-contour mutation reproduced the false pass described above.
- Scoped source whitespace check passed.
- State management and UI component testing are not applicable to this Python/CAD delta.

## Other checks and scope

The base native-flat file is checksum-bound in the manifest and verified by `_formed_record` before building the metal assembly. Forming checks and VENT/BEND/DRILL sketch comparisons remain active when base CUT-sketch equality is skipped. STEP export now restores occurrence/body visibility in `finally`, including a failed export path. These changes follow the existing CAD workflow and do not add compatibility behavior.

This review is limited to the corner implementation and its new verification/export/test paths. No live Fusion operations, implementation edits or full-output regeneration were performed. Updated documentation, final reopened-native evidence, workshop process acceptance and physical fitting remain the author's active work and are not inferred from the green unit suite.

## Re-review addendum — outside-contour rejection corrected

The Critical finding above is resolved. `_profile` now requires every subtractive contour to have a positive-area intersection with the outer profile before the Boolean subtraction. This rejects the detached 10 ×10 mm CUT square while preserving the actual corner-relief circles that partly cross the perimeter. The exact reproduced case is now a negative regression expecting the explicit outside-sheet error.

Re-read the fix and new regression, then ran the current complete suite: all ten tests passed in 11.567 seconds, including the unchanged real source/native comparison and the detached-contour rejection. Scoped whitespace validation passed. No unresolved actionable findings remain from this bounded VGV review. Native save/reopen persistence and physical shop verification remain separate evidence; no live Fusion operations were performed during re-review.
