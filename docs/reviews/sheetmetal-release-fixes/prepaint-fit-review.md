# Machining before coating: independent geometry review

Reviewed the current `hardware/enclosure/segno_enclosure.py` against the saved
source immediately before this process change. The reviewed source SHA-256 is
`1ffc2d27b839da7d1ad8740a75520f12c128c644785e5618cab67da44f301ba3`;
the baseline is `76c275a7ced8e8b4ae10d2b784da181b49859d2a6341c986bad7d1ff699c23f1`.
Repository HEAD was `1d14d701ee9f6c3ad304a63fc60a79e3681afbd1`, with working changes.
This is a bounded review of the revised operation and masking contract, not a
new audit of unrelated geometry or a statement that a physical first piece has
passed. No Fusion, implementation, or shared manufacturing outputs were edited.

No unresolved actionable finding remains in this reviewed scope. Two wording
corrections identified during review were incorporated and rechecked: masked
seats retain the bare lid position, and the metal shop must trial-fit the
pedals, screens and supports and record both ends of their hidden bearing paths.

## Verified geometry and drilling references

Independent scratch generation of all seven metal DXFs, from both source
revisions, produced exactly identical CUT/VENT/BEND/DRILL entities. This includes
326 manufacturing entities across all seven stems. Post height is unchanged.
New MASK and instruction entities do not change any cut or fold.

Measured the native formed base and lid at their accepted populated-348 poses.
Datum A is the bare floor bottom. At the bore height, bare datum B is the left
inside side plane at world X = 0.089159000 mm. The nine actual front axes are
6.955420469 mm above A, agreeing with the sheet's 6.955 mm within 0.000421 mm.
The nine listed X stations from B have at most 0.004874 mm rounding error.
Both errors are well inside the stated ±0.10 mm. Native lid and base front axes
coincide within 0.000000017 mm. No painted-datum offset remains.

All drilling, final clearance sizing, tapping, chamfering, deburring, dry fitting
and shim sizing occur at the metal shop. The painter protects completed bores,
threads and recorded hidden seats. The owner reinstalls numbered shim packs,
uses edge-only retention adhesive, selects felt and assembles; no planned
drilling, tapping or enlarging remains. The short guided rear transfer operation
still requires confirmation of the shop's tooling before fabrication.

## Mask coverage and faces

- Side support edges retain the full 2 mm bare bearing thickness. Matching
  5 mm lid bands lie on its underside, from developed V = 12.082988 to
  419.231325 mm. Actual end-of-bend contact traces control the mask boundary.
- The rear mating masks are on the opposite face from each flat drawing:
  base return V = 506.491176–530.434342 mm and lid lap V =
  420.752722–444.695887 mm. The base reference starts at
  `BD + HR_FLAT + KNUCKLE_CLEAR - DD_TR`, excluding the exposed knuckle/tail.
  These are actual-overlap references, not permission to leave a visible bare
  rear stripe.
- Checked all ten collars at their recorded native placements. Every lower
  footprint fits its base-inner-floor reference with at least 0.493472 mm
  margin; every upper rim fits its lid-underside reference with at least
  0.793472 mm margin. Both ends require masking: their nominal bare upper
  clearances are only 0.029571–0.029998 mm.
- Independently reconstructed both screen upper envelopes and all three floor
  support envelopes. The five emitted rectangles match their planar bounds to
  at most 0.000039 mm, solely rounding. They locate the actual hidden footprint
  map; they are not filled mask shapes. Window walls and visible outer faces
  retain coating. The seven-inch tower itself is 7.295524 mm below the lid;
  no tower-top/tab mask is needed.
- Each front 7 × 7 mm reference square covers the maximum Ø6 mm shim footprint
  with 0.5 mm registration margin where metal exists. Masking is on the two
  hidden opposing lands, opposite the drawn faces. The square extends
  0.360641 mm above the nominal front wall and is explicitly clipped to metal.
  The actual Ø6 shim retains 0.139359 mm nominal top-edge support margin,
  or 0.039359 mm at the permitted +0.10 mm drill-height limit. This mask
  annotation does not demand a new 7 mm bearing land or removal of visible paint.

## Coating stack and acceptance limits

With the bare lid pose retained, front clearance outside shim lands is
0.50–0.60 minus two 0.06–0.10 mm films: **0.30–0.48 mm**. Numbered bare-fitted
shim thicknesses remain valid; packs and adhesive stay out of the paint oven.

The painted steel posts still need felt selected from the actual finished gap.
For the specified film range, the nominal normal gap is
`1.2 - 2*t*cos(12.498241812°) - 2*t` = **0.804739–0.962844 mm**. This includes
film under the post foot and on both felt-facing surfaces; it does not invent
a coating-induced lid lift. The revised notes require measurement rather than
guaranteeing that reference 1 mm felt will fit without adjustment.

The mathematical coating stack now preserves the established bare assembly.
Actual printed-part height, forming variation, mask registration/leakage, paint
edge beads and coating-cycle distortion still require the specified physical
bare trial fit, painter inspection and freely seated final assembly. The screen
and collar clearances are too small to replace these checks with CAD assurance.
Do not pull an obstructed lid into place with screw torque.

Numerical measurements, per-part equality hashes, all ten collar checks and
all five screen-reference checks are in
[prepaint-geometry-proof.json](prepaint-geometry-proof.json). The checks use independently
read STEP cylinder/plane geometry and actual occurrence transforms; they do not
merely compare instruction strings. PDF rendering, full package verification,
and final source/native preservation are covered by the coordinating review.
