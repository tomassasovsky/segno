# Rear seam: rebuilt VSM base review

The fresh VSM base is geometrically acceptable to replace the base whose
serialized flat-pattern asset could not initialize. This review applies to
the exact draft STEP and native-snapshot hashes in
[rear-closure-rebuild-proof.json](rear-closure-rebuild-proof.json).

The rebuilt STEP is valid and contains one solid. Its native flat matches the
current source, including all 107 reference holes, with zero missing or extra
area. Both rear straight seams measure 0.050000196–0.050002072 mm at heights
10, 45 and 80 mm. All 107 full cylindrical bores retain the same radii, and
all 10 rivet centers are unchanged. The greatest other bore-center movement
is 0.000011321 mm at the nine rear tap pilots, with an axis-angle change of
0.0000008 rad.

The total lid/base intersection changes from 5.519205387 to 5.747939432 mm³.
The change is confined to the existing rear lap seating film: its maximum
normal thickness increases from 0.000252686 to 0.000273549 mm. Both side-seat
films remain 0.000266180 mm thick. These remain submicron seating residues.
The rebuilt base has zero intersection with either rear bracket.

Both solids have 393 matching cylindrical surfaces. Directed exact
point-to-shape checks include every vertex and selected edge/face samples:
1,526 points in one direction and 1,522 in the other. The greatest observed
deviation is 0.002141415 mm at the rear floor bend reliefs. Elsewhere, the
greatest listed deviations are approximately 0.000020863 mm. This is a sampled
deviation result, not an exact global Hausdorff bound. Whole-solid cut
differences returned invalid shapes with impossible volumes; those results
were rejected and are retained as failed checks in the raw evidence.

The source transition-fold angle is 65.55604521958347°
(1.1441688336680205 rad). The old textual recipe used 65.556° rounded
(1.1441680444374027 rad). That difference explains the minute change in rear
lap seating. The reviewed draft preserves the intended fit; no geometry
change is required on manufacturing grounds. Future rebuilds should use the
source angle directly.

The supplied saved/reopened snapshot pairs preserve every occurrence and
warning record exactly. Reopened native flats again match all 107 holes with
zero missing or extra area. Their derived caches were then saved. Final
readback in `accepted-pop.json` and `accepted-vsm.json` confirms revisions
348 and 135 reopened with `modified=false` and occurrence/warning records
exactly equal to their respective final saved snapshots. This resolves the
earlier intermediate readback at revisions 347 and 134.

No actionable geometry regression was found in this rebuild scope. Actual
bare rear-seam fit remains 0–0.10 mm before riveting, with the chassis square
and upper seats unforced.
