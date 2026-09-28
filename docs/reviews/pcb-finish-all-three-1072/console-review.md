# Console placement and copper finish review

The accepted combined native board is
`27e690947142c2a31af171c4e2fc82c74b66183d790098299b0fb33b412b75aa`.
Its placement, local copper correction and remaining routing finish pass the
bounded checks below. Final CAM, whole-PR review and CI evidence remain
separate; these checks do not qualify an assembled board.
[Geometry evidence](console-geometry.json) records the source, placed-board,
pre-rounding candidate and combined native fingerprints.

## Placement and source agreement

C20 moves to local center `(43.75, 19.6)` beside U2's supply pin. Its courtyard
has **2.045 mm** clearance to U2, **0.510 mm** to R4 and **0.500 mm** to J22.
The existing 2.0 mm isolation requirement remains enforced. The supply route
from U2 pin 6 to C20 is 5.16 mm; the former route was about 17.5 mm.

The ground stitch goes east to native `(146.55, 79.6)`, using a 0.6 mm stub
and a 0.8 mm via with a 0.4 mm drill. The local supply routes clear this stitch;
the unused old J22 supply stub is removed. C20, U2 and R4 references and the
EXP label follow the clean source placement. The Pico supply branch rejoins
the original diagonal at `(155.77, 78.15)`, preserving its 0.6 mm width and
external endpoints. Models, pad nets and drills are preserved. The mounting
JSON is unchanged.

A fresh placed-source build passes all existing placement and silkscreen
guards. The generator's 15 negative controls pass. Independent native
comparisons confirm exact source agreement for rear power-zone outlines and
settings, C20 pads/model/drills, affected references and the ground stitch.
Four disposable faults are rejected: missing blend, displaced blend origin,
displaced C20 and retained old ground stitch.

## Filled copper

The real **0.05 mm** slot beside J24 is closed, with **0.22 mm** of measured
bar/track overlap. The rear bar uses an explicit rounded boundary: a touching
same-net overlay no longer disables its corner smoothing. The blend uses
board-local coordinates, and its hidden closure is buried inside existing
copper.

The actual union of filled zones, pads and tracks has no internal hole at the
join. A contour check records a maximum **9.56 degree** turn between meaningful
polygon chords. The identical check rejects the earlier candidate's **48.12
degree** cutoff. The measurement excludes fill edges shorter than 0.005 mm;
it does not mistake zero-width polygon seams for physical slots.

The remaining main-feed miter is rounded at the existing 1.0 mm inner radius.
Independent native-shape measurement across its eight chords finds **0.221441
mm** minimum clearance to `IND_DATA_OUT`, above the 0.20 mm rule. The shape
approximation is 10 nm, or 0.00001 mm. The obsolete corner exception and its
unsupported clearance comment are removed.

A 1.7 µm intermediate jog on the front logic-power branch becomes one
0.7 mm segment; both external endpoints remain unchanged. The full ring feed
remains 1.7 mm wide, with its connector anchors and four parallel 0.5 mm drill
power vias preserved.

## Local correction result

Native DRC reports **zero violations at all severities and zero unconnected
items**. All **11** existing ring-supply fault controls pass without weakened
selectors or limits. The semantic comparison changes only C20's placement;
other pad locations, models, drills, net names, outline, stack and two-layer
construction remain unchanged. Track changes are confined to the reviewed
`+5V`, `+3V3`, `+3V3_PICO` and C20 ground routes.

## Accepted combined result

The [independent rounding review](rounding-review.md) verifies the combined
native hash above after 329 additional corners are rounded. No remaining
routed corner is reported, and a second pass is byte-identical. All 91 locked
tracks and every route at least 1 mm wide remain exact; the general pass
changes only 0.4, 0.6 and 0.7 mm routes. Footprint, pad, model, via, zone-outline,
stack and board-outline metadata are unchanged from the local correction.

Fresh native DRC remains **zero/zero**, and all **11** power fault controls
pass. C20, reference, rear-zone and ground-stitch source parity remains exact.
Both filled copper faces were reviewed. The old slot remains fully closed,
overlap is 0.220 mm, and the fillet still has no internal hole or sharp cutoff.
Rounding the adjacent data route increases the final bend clearance to
**0.276252 mm**. The earlier 0.221441 mm result above identifies the input
candidate, not the final data contour.

The imported source and native hashes were checked against the reviewed
fingerprints. Final manufacturing-package and whole-PR approval remain
separate gates; no assembled electrical or thermal qualification is claimed.
