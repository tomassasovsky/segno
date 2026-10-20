# VGV Code Review

## Summary

The Python/CadQuery changes follow the existing generator structure and use the existing CAD libraries rather than adding a new abstraction layer. The corrected converter dimensions, support-post geometry, manufacturing operations and shop-facing documentation agree with the stated plan. The rear-panel thickness and physical shop checks remain explicitly held. The new native-export verification needs one correction before the package can rely on it as a source-of-truth check.

## Critical — Must Fix Before Merge

- **hardware/enclosure/fusion_export_formed.py:65–74 — Verify the actual formed geometry against the handoff.** The exporter compares imported flat sketches and counts native folds, but it never compares the native fold angles, direction or bend-line attachment with the generator's bend table. `FRONT_DRILL_AFTER_FORMING` is accepted whenever it contains nine circles, without comparing their centres, radii or actual cutting result. A healthy component with a changed fold angle or nine misplaced drilled holes therefore passes the pre-export checks and receives the current flat hash. The downstream volume and bounds tests compare that STEP against measurements recorded from the same wrong native body, so they do not restore the missing comparison. In addition, sheet rule values are hardcoded to T2/R2/K0.33 even though shop acceptance may require a new generator value.
  - Why: The new verification can certify a mismatched formed reference as matching the laser and bending source; it can also block a legitimate shop-calibrated rule change despite a matching generator and model.
  - Fix: Put the expected rule, fold definitions and formed drill geometry in the handoff, compare them with native feature/solid geometry before assigning its hash, and add negative tests proving that changed fold angles/directions, misplaced drills and changed rules cannot be certified accidentally.

## Important — Should Fix

None beyond the verification issue above.

## Suggestions — Nice to Have

None. Broad style changes to the established generator would obscure these manufacturing corrections.

## Simplicity Assessment

- Lines that could be removed: no actionable removal identified.
- Unnecessary abstractions: none identified in the new implementation.
- YAGNI violations: none identified.
- Complexity verdict: the native export and manifest have a concrete purpose; complete their verification rather than adding another parallel source of truth.

## Testing Assessment

- New code with tests: five meaningful geometry and package regressions, all passed independently during review.
- Test quality: covers real solids, floor and pad contact, supplier mounting holes, deferred drilling, stale exports and assembly membership; exporter rejection behavior needs the negative cases described above.
- State management test coverage: not applicable to this Python/CAD change.
- UI component test coverage: not applicable.
- Validation: `MPLCONFIGDIR=/tmp/segno-vgv-mpl <CAD venv>/bin/python -m unittest discover -s hardware/enclosure/tests` passed five tests in 2.945 seconds; the scoped source/document diff whitespace check passed.

## Scope and Limits

Reviewed the tracked diff against `1d14d701ee9f6c3ad304a63fc60a79e3681afbd1`, plus the untracked exporter, tests, formed manifest, release record and plan. The repository's Dart/Flutter layer conventions do not apply to these changes; no application or firmware files were changed. No Fusion operations or full output regeneration were performed during this independent review. This review does not establish physical material, coating, tooling, cable access or first-piece fit acceptance. The existing release hold correctly preserves those distinctions.

## Re-review addendum — verification corrected

The original Critical finding is resolved in the current source. The generator now includes authoritative sheet-rule values, signed fold angles and their source BEND lines, and the nine formed-hole axes/radii/through-thickness spans in its handoff. The exporter reads the actual native fold features and cylindrical hole surfaces, validates them against that handoff before exporting, and records the captured values in the manifest. Sheet rules are compared with generated values rather than hardcoded numbers.

Independently checked all three stored native captures against the current handoff: base, faceplate and corner bracket all passed. The six regression tests passed in 3.236 seconds, including rejection of incorrect rules, bend angles/directions, source lines, hole positions/radii and blind-hole spans. The assembly test also now checks bracket and rear-panel hole registration and ring seating, with a displaced-bracket negative case. No unresolved actionable findings remain from this review. No live Fusion operation or full artifact regeneration was performed during re-review; physical manufacturing release conditions remain as documented.

## Re-review addendum — converter reference correction, September 5

Reviewed only `_buck_reference_solid`, `build_buck_reference_step` and the new converter regression. The visible housing uses the authoritative 63.7 ×57.6 ×22 mm envelope, 53.9 mm mounting pitch and Ø6.5 mm holes, while clearly describing the undimensioned cover, ear thickness and fins as visual approximations. The separate full envelope remains the conservative collision reference. This is a direct use of existing CadQuery operations, with no unnecessary configuration or compatibility path.

The new test checks a valid single solid, exact overall dimensions, its floor datum, containment in the conservative envelope, mounting-hole axes and space above the low mounting ears. That last probe usefully rejects the previous full-height block. It is a Ø9 mm access probe, not proof that the specified Ø12 mm washers fit the real casting; hardware access remains a physical check because the casting details are approximate.

All seven geometry regressions passed independently in 3.778 seconds. No actionable source findings were found in this limited delta. No live Fusion operation was performed: removal of stale occurrences, exact instance count and final assembly placements require the author's corrected native CAD verification and are not inferred from these generator tests.
