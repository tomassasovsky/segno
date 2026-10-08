# VGV Code Review

## Summary

No actionable convention, regression, or simplicity findings in the extra-feet source unit reviewed. This is a Python/CadQuery and ezdxf generator change inside a larger Flutter/Dart monorepo; Flutter state-management and presentation-layer rules do not apply to these files. The change follows the enclosure generator’s existing function, constant, unittest, temporary-output and independent-datum conventions. This source review is not a structural certification, production release, review of the whole existing working diff, or verification of the native/export work still in progress.

## Scope and revision

Compared the current generator and process documentation against `/tmp/segno-extra-feet/before`, and reviewed the new `hardware/enclosure/tests/test_floor_supports.py` in full. Included the latest removal of the obsolete `foot_relief_xy()` function and its centre-only assertion. Reviewed `AGENTS.md`, the relevant progress/tracking contracts, root dependency/lint manifests, current enclosure tests and generator callers. No dedicated Python lint configuration or enclosure CI job was found in the inspected files.

Reviewed source SHA-256: `5d2ffe266fedf7f2f185d6a8a37b44fa80ca1bffd8d9cf9b40cecd3052de810a`.
Reviewed new test SHA-256: `15051537f943dfa36f34c1867273e202b37babf51fd16e33fb1b44fee95ac8f4`.

## Critical — must fix

None.

## Important — should fix

None.

## Suggestions

None.

## Regression and convention assessment

- `base_foot_xy()` remains the one coordinate source consumed by the cut DXF, generator pedestal-head clearance assertion and preview. Its unchanged zero-argument interface retains the original four stations and supplies the eleven approved additions.
- The front/rear paired rows derive from the existing pedal stations, while the three middle supports follow the accepted obstacle-aware arrangement. No configuration framework, compatibility path or new dependency was introduced.
- A repository-wide caller search found no remaining live use of the removed centre-only `foot_relief_xy()` API. The replacement checks the full assumed head radius against each pedestal footprint and also rejects every case previously rejected by a centre-in-footprint test.
- The new foot dimensions replace the preview’s separate obsolete corner layout and height. The preview uses its existing bottom-plate-to-render transform and puts the wider cone face against the base underside.
- The documentation distinguishes 32 untapped body pilots from 18 lid clearance holes and washers. It preserves the owner’s post-paint tapping, separate painting shop, and mechanical foot-hardware qualification requirements.
- Removed material comments overstated load capacity without an established temper or assembled boundary conditions. Their replacements correctly describe the load path and keep geometric clearance evidence separate from structural capacity.

## Simplicity assessment

No unnecessary abstractions or speculative extensibility found. No removable lines identified in the scoped change. The obsolete centre-only helper has already been removed; the remaining coordinate and clearance logic is direct and consistent with nearby generator code.

## Testing assessment

Independently ran the focused `test_floor_supports.py` unittest suite with the established enclosure Python environment: all five tests passed. The suite regenerates actual CUT geometry, verifies the fifteen unique stations and preserved original four, checks head and underside hardware envelopes against independently placed real solids, includes ventilation and inter-foot clearances, and exercises rejected board/tower positions. Bounding-box shortcuts are used only as safe distance lower bounds, and the rear-left tower hollow is checked against actual geometry.

These are nominal geometry regressions, not tests of rubber compliance, material yield, screw retention, assembled load distribution, or real stomp forces. Those limitations are explicit in the test module and current process documentation. Dart, Bloc, UI tests and application-layer coverage are not applicable to this CAD-only unit. Full generator/native/export validation remains the parent task’s responsibility.
