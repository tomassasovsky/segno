# Rear straight-seam closure: independent geometry review

Scope: replace the existing 0.610840885 mm rear/side straight opening with the user-approved tight visible riveted joint line. No welding, coating process change, part relocation, hole relocation, or other seam re-audit. This records the source delta and verified native geometry; actual shop fit remains necessary.

## Accepted geometry

At T=2 mm, RI=2 mm, K=.33, the native rear wall inside face is nominal Y=BD+DEV90-T=418.910840885 mm. Set the side's free edge to that datum minus g=.05 mm, Y=418.860840885 mm, extending each side .560840885 mm. Require actual bare dry fit 0–.10 mm before riveting, with the chassis square and its upper seating curve unforced. The result intentionally retains a joint line. It is not a welded or sealed cosmetic seam.

Recompute the existing R2 upper corner and R3.25 lower relief intersections from that new Y. Do not move holes, bends, the return flange, brackets, lid, or the separate .30 mm ridge-clearance profile. The lower relief remains part of the perimeter; do not fill it to hide the joint line.

The source old/new CUT difference consists of two added planar faces, 45.844646050179 mm² each, and zero removed area. Their T2 extrusions add 91.689292100354 mm³ per side. The CUT topology validator passes. The exact six-edge native replay wires, including start/mid/end for the R2 and R3.25 arcs, are in rear-closure-candidate-proof.json. World-to-base local is Z minus2 mm.

The new vertical free edge runs worldZ5.157860248 to85.456907977. Its upper R2 tangent to the fixed return underside is (Y417.688446774,Z87.277640932). Source planar mapping is safe because the entire actual delta lies above worldZ5.08456110, past the side bend tangent. The lower corner relief remains clear of the rear/floor bend region.

## Static collision and curve checks

Both exact added T2 solids are valid. Each has zero Boolean intersection volume against the frozen native base, native lid, and both native rear brackets. Candidate union in OCC with1e-5 mm boolean tolerance produces one valid solid. Existing base/lid contact volume is unchanged at5.519205387 mm³; this review does not reinterpret that prequalified submicron seating residue.

The nominal .05 mm figure applies to the straight vertical seam, not uniformly along the upper seating fillet. Against the actual native rear inner R2 bend, the straight-edge gap at its upper endpoint is .049873082 mm. The new side R2 arc approaches the intended return underside seat continuously: sample nearest clearance .049870 at0°, .018619 at45°, .004570 at60°, .000739 at64°, and approximately .000001 mm at the top tangency65.556°. No added material intersects the native return. Full samples and native/source arc centers are in corner-clearance.json.

This assembly is fitted and riveted before painting. Powder thickness must not be added twice as though these already-fixed contacting surfaces were independently painted loose parts. No claim is made that powder alone hides or seals the joint line.

## Final native result

The correction was replayed as two source-derived planar Join extrusions in the unfolded blank before its first fold. The existing five folds and following offsets/holes/ridge features recomputed. This avoids forming a new side/return connection by joining already folded contacting sheets. The same base component/body identities and placements remain in both native documents.

Independent verification against actual updated native snapshots and STEP exports:

- Both sides in both documents measure .050000196 mm at worldZ10, .050001134 mm atZ45, and .050002072 mm atZ80. The small gradient is the existing native fold-angle precision.
- Each base remains one sheet-metal solid with16 healthy features,704 faces and1965 edges. Both exported solids are valid.
- Both native flats match the complete current source CUT/VENT/DRILL profile:107 reference holes,0 missing area and0 extra area.
- All10 base Ø3.3 rivet-cylinder axis/radius keys are exactly unchanged. The upper R2 and lower R3.25 radii are preserved. Both bracket intersections are zero. Existing lid/base contact remains5.519205388 mm³.
- A bounding-box scan of every visible populated body finds only the existing base and lid near the added material. The exact added-material solids intersect neither; no other component can intersect the additions.
- VAMP sheet metal retains27 occurrences/27 bodies with no other changes. The populated design retains423 occurrences/973 bodies; other occurrence matrices differ only by at most1.066e-14, body bounds by2.274e-13 mm, and other body volumes by0. Existing41 populated warning entries are unchanged; this correction creates no new warnings. Both base placements and identities remain exact.

No actionable geometry regression was found within this correction scope. Raw inputs, hashes, dimensions, preservation results and flat/collision results are condensed in rear-closure-geometry-proof.json. Actual bare fit0–.10 mm before riveting is still the fabrication acceptance; the CAD nominal cannot by itself guarantee forming accuracy. Final regenerated package/source-cache validation and save/reopen are handled separately by the parent task.

## Primary references

Autodesk describes the sheet-metal rule Gap value as the separation used for flange miter/rip/seam features and treats corner relief independently: https://help.autodesk.com/cloudhelp/ENU/Fusion-Sheet-Metal/files/SM-RULES-REF.htm

Autodesk University, Steve Olson, Essential Skills for Sheet Metal Modeling in Fusion360, page15: touching flange faces can blend and prevent flattening, so a small positive modeling separation is required. His example's .001 value is not used here as a universal fabrication tolerance: https://static.au-uw2-prd.autodesk.com/Class_Handout_MFG468245_Steve_Olson.pdf

Protocase describes a fully sealed seam as a welding and grinding operation before finishing, supporting the distinction from a close mechanical joint: https://www.protocase.com/resources/faq.php
