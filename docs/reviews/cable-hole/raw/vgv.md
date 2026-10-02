# VGV correctness review

Scope: only the closed cable-hole delta in `hardware/enclosure/segno_enclosure.py` and its corresponding collar regressions, compared with the captured pre-change files under `/tmp/segno-cable-hole/before/`. The rest of the existing manufacturing branch is outside this review. This is a Python/CadQuery geometry generator; Dart presentation and state-management rules do not apply to these changes.

## Result

No actionable findings. This report covers the user's final vertical stadium profile, superseding the intermediate rectangular hole. The change replaces the console collar's open upper slot with the closed stadium requested by the user. The assembly assumption is that the free cable end is threaded through before seating the pedal and sled. It does not establish fit for an unmeasured connector, a rectangular fitting or a physical PETG print.

## Correctness evidence

- The two approximate measured vertical positions are 7.45–18.90 mm and 8.50–19.95 mm above the bare metal case underside. Their union with 0.5 mm clearance at both ends is 6.95–20.45 mm, making the hole 13.50 mm high.
- The measured width of 7.60 mm plus 0.50 mm per side gives the specified 8.60 mm opening.
- The final stadium has R4.30 mm semicircular ends and a 4.90 mm straight center section. A measured 7.60 × 11.45 mm stadium expanded normally by 0.50 mm fits at both candidate heights. The new source explicitly states the profile assumption; square bounding-box corners do not receive the same clearance.
- Both source-generated collars remain valid single solids. Independent before/after CadQuery subtraction shows zero removed volume and 92.8097180 mm³ of added material per collar. This is the upper bridge and rounded-end corner material; the existing lower opening limit, outside envelope, screw locations and sled bore are retained.
- Independently extracted through-wall voids measure 2.40 × 8.60 × 13.50 mm. Their 240.5473156 mm³ volume matches the analytical vertical stadium area multiplied by the wall thickness.
- The sloped wall leaves a minimum 2.3850241 mm of material above the hole at its inner rear face. The bridge is thicker toward the outer rear face, so the opening is fully closed through the wall thickness.
- Independently generated mini and unsledded reference collars have zero bidirectional volume difference before/after. The console-only condition retains their existing openings.
- There are no signature, import, dependency or export-path changes.

## Testing assessment

The updated STEP-level tests build an independent capsule from cylinders and a box, verify exact bidirectional agreement with the through-wall void, check material on all four sides and in the rounded-end bounding corners, and cover both possible measured stadium positions expanded by 0.5 mm on every side. Existing checks for wall thickness, mounting bores and sled fit remain. Replacing the vertical-drop sweep is appropriate because the user explicitly changed the assembly sequence. Suite execution and native/artifact publication are handled separately by the implementation owner.

## Simplicity assessment

The change adds one derived upper limit and uses CadQuery's existing slot primitive for the console cut. The integrated mini retains its separate rectangular exit. No new abstraction, dependency, configuration interface or obsolete compatibility route is introduced. No simplification findings.

Critical: 0. Important: 0. Suggestions: 0.
