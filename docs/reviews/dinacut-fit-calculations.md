# Dinacut lid fit calculations — #1025

Calculated 2026-09-14 from the placed native STEP geometry at `43c94a27` and
the revised source. The selected geometry is nine rear **10 × 6 mm CUT slots**
(long axis along the lap), **12 OD / 3.2 ID / 1 mm rear washers**, and a
**1.10 mm nominal bare front gap**, accepted at **0.70–1.50 mm** after welding.
These are conditional geometric checks, not a guarantee from generic bend
tolerances or a qualification of welded/clamped parts. They do not establish
that the revised Fusion documents have been saved or exported.

## Rear passage and bearing

All dimensions below are millimetres. One common rigid lid pose must satisfy
every station; individual holes cannot each be independently recentered.

| Screening input | Bound |
| --- | ---: |
| Bare slot length / width | 10 / 6, each ±0.20 |
| Paint on each slot wall | 0.06–0.10 |
| Minimum finished opening | 9.60 × 5.60 |
| M3 screw major diameter used | 3.00 |
| Screw-axis mismatch to lid normal | at most 3° |
| Axial screw offset at **both** lid faces | ±2.567 |
| Transverse screw offset at **both** lid faces | ±0.800 |
| Washer purchase acceptance used in calculation | OD 11.8–12.2; ID 3.2–3.4 |

The tilted screw section is bounded by a circle of radius
`1.5 / cos(3°) = 1.502059`. Eroding the minimum coated stadium by that circle
leaves **0.317386 mm radial passage margin** at the simultaneous offset corner.
The 2 mm lid adds `2 tan(3°) = 0.104816 mm` of axis travel between faces; requiring
the offset bounds at both faces includes this travel. An earlier 7 × 4.5 slot
does not pass the simultaneous 1.83 mm axial / 0.80 mm transverse / coating case.

The actual outer lap is a rectangle. Relative to the nominal rear screw row,
its straight depth limits are −12.635445 and +11.971583; world X limits are
−1.9 and 847.9. Nine screw stations run from X 18.428571 to 827.571429 at a
101.142857 pitch. Allowing an independent 0.40 row-location error and 0.30
flat-edge error gives these conservative results:

| Result with the offset and washer bounds above | Minimum |
| --- | ---: |
| Washer bridge beyond the slot side at its transverse centreline | 1.800 mm |
| Planar bearing area, lower bound | 45.289 mm² |
| Washer-to-lap depth-edge land | 2.405 mm |
| Outermost washer-to-side-edge land | 12.529 mm |
| Bare slot-end ligament to depth edge | 6.172 mm |
| Gap between adjacent washers | 86.943 mm |

The area bound subtracts the entire maximum bare slot and washer bore from the
minimum washer disc, even where these voids overlap. It therefore underestimates
available metal. The entire washer disc remains on the flat lap within the
stated edge assumptions. The washer **does not cover the complete slot
perimeter**: the conservative far-end coverage deficit is 2.037 mm. Some slot
can remain visible with black base metal beneath it. Bearing and complete
coverage are separate requirements.

The manufacturer's catalog lists **Hirosugi FFW-0312-10**, a steel flat washer
with nominal ID 3.2, OD 12 and thickness 1 mm. This establishes an actual
catalog option for the reference geometry; its OD/ID tolerances, local supply,
finish and load suitability still need confirmation before purchase. It is
not described here as a DIN 9021 M3 washer.
[Hirosugi FFW catalog](https://hirosugi.co.jp/shop/g/gFFW-0306-03/).

## What the tolerance numbers mean

The fixed-floor/main-lid calculation rotates the two base folds and the lid
lap fold about their **actual native bend-cylinder axes**, then intersects the
base pilot axis with both lid surfaces. For three independent ±1° errors, the
certified continuous envelope is **−1.588491 to +1.560971 mm** along the lap.
First-order contributions per degree are 1.398614, 0.104715 and 0.069813 mm;
their RSS is 1.404265 mm, while their worst-direction sum is 1.573143 mm.
The old approximate 94.4 mm lever / 1.83 mm RSS is not used. Existing ±0.5°
drawings give a corresponding exact envelope of −0.790288 to +0.783251 mm.

One conservative fixed-pose screening allocation is
`1.588491 forming + 0.800 coordinates + 0.177656 coating = 2.566147 mm`,
rounded outward to 2.567. The 0.800 relative coordinate bound allows two
independent ±0.40 coordinates, covering the stations beyond 400 mm. This
allocation has **no additional independent development allowance**. If the
shop gives finished flange/hole coordinates that already include angle and
development effects, use those dimensional envelopes instead of adding the
fold model again. For example, two qualified ±0.80 finished along-lap
coordinates give ±1.60 relative error, or 1.777656 including this coating bound.

The governing conditional acceptance is that, in one unforced seated pose,
every rear screw axis stays inside **±2.567 depth / ±0.800 width at both sheet
faces**, while retaining the reported edge distances. A generic statement
of ±1° bends and broad flange tolerances does not establish that acceptance.
Welding fixture control, finished seating geometry and front clearance must
be compatible. Slot travel is in-plane freedom; it does not remove lap-angle
mismatch, twist or a competing hard contact.

## Front gap, coating and final drilling

The three-contact section model solves one rigid lid translation and pitch
against the two main-seat points and rear lap. The main and rear seats constrain
fore/aft motion; the lid cannot slide freely while all three contacts remain
seated. Independent ±0.80 mm seat-normal errors can move the front by
**±2.511 mm**. Consequently, the 0.70–1.50 bare gap is a **measured assembled
acceptance band after welding/correction**, not a consequence of those generic
dimensional tolerances.

For independent opposed paint films of 0.12–0.20 mm at the three contacts,
the exact rigid-pose model gives front motion of −0.108013 to +0.143120 mm.
Adding the local front opposed films gives a coating-only finished shim-space
range of **0.356880–1.488013 mm** from the accepted bare band. The rear coating
shift used above is bounded by 0.177656 mm. This is a section calculation,
not a proof of full-width flatness or elastic contact.

Retain the nine front Ø4.5 post-form drilling stations. After all base welding,
check/correct the unforced bare lid seating and front gap in a simple metal-only
fixture, then establish the front hole registration before coating. No
electronics trial assembly is required for this operation. After coating, fit
solid metal shims to the actual local gaps without pulling the front wall or
lip together with screws. Preserve the #1019 beam, rails and intended lid
support heights throughout this operation.

An ordinary parallel shim pack only corrects thickness. Independent ±1°
front folds could leave 2° between the faces, a **0.244445 mm wedge across
7 mm**. The retained fit operation must verify/correct face alignment, or
qualify a locally fitted angled solid shim where needed. Do not claim that
parallel packs cure that angle. Similarly, rear passage at 3° does not prove
that a flat washer and screw head can bear correctly at 3°. Actual seating,
thread engagement, clamp load, coating compression and removal remain physical
checks; no weld size or procedure is inferred from this calculation.

## Exact geometry change for the native lid update

Changing only `LIP_BARE_CLEAR` from 0.50 to 1.10 produces these source deltas:

| Quantity | Old | New | Change |
| --- | ---: | ---: | ---: |
| Front fold line / `LID_FRONT_FL` | 12.082987548 | 11.949990067 | −0.132997481 |
| `LID_FRONT_EXTRA` | 0.512136273 | 1.126699801 | +0.614563528 |
| Main-content flat offset | 12.595123822 | 13.076689869 | +0.481566047 |
| Rear fold line | 419.231324866 | 419.712890913 | +0.481566047 |
| Rear slot row / `SEAM_LAP_V` | 432.724304437 | 433.205870484 | +0.481566047 |
| Blank rear edge | 444.695887311 | 445.177453358 | +0.481566047 |

Blank width, `FP_V`, rear lap length, base pilot row and fold angles stay the
same. In the native lid flat sketch, move the front bend line by −0.132997481,
translate main-content loops and all rear geometry by +0.481566047 along
local depth, and extend the rear outline accordingly. Keep the flat front
tip at zero. Replace the nine rear round holes with the CUT stadium contours.
The front DRILL reference stays at flat Y 6.455420; rebuild/check the formed
front registration so its world Z remains 6.455420.

If the existing native local frame is retained, the compensating lid occurrence
translation is **world Y −0.470154207, Z −0.104215542 mm**, with no X change.
This keeps the main lid content and rear seam fixed in the assembly while the
front lip moves **0.600 mm forward**. It is not an instruction to shift the
whole populated stack: main-content hardware remains at its existing world
positions; front external hardware follows the lip, and the nominal front
shim becomes 1.10 mm thick. Recheck the actual native planes and dependencies
after rebuilding rather than applying the matrix without verification.

## Evidence and limits

`hardware/enclosure/lid_fit.py` contains the section calculations.
`tests/test_lid_tolerance_budget.py` checks the native reference axes,
continuous fold bound, independent solid screw passage and washer bearing,
and exact contact equations. `tests/test_rear_joint_fits.py` checks the emitted
stadium contours, retained front drills, emitted washer solid, actual native
lap perimeter and the revised front-plane screening. **All 12 tests passed**
with the current source on 2026-09-14.

Run from `hardware/enclosure` with the configured CAD Python environment:

```text
python -m unittest tests.test_lid_tolerance_budget tests.test_rear_joint_fits
```

These tests do not qualify a welder, establish acceptable clamp torque or
replace the retained metal fit/seating check. They also do not certify later
Fusion edits or an exported supplier package; those have separate checks.
