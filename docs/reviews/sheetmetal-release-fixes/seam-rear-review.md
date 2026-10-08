# Rear seam correction: final independent review

The current rear ridge and bracket correction has no unresolved actionable
finding within this review's scope. Numeric evidence, recorded transforms,
STEP hashes, hole-axis measurements and drawing hashes are in
[seam-rear-proof.json](seam-rear-proof.json).

The base's source-derived side extension removes the former 2.18 mm ridge
opening without changing the lid, return flange, bends or corner reliefs.
Its nominal R1.70 arc clears the lid's inside bend by 0.30 mm; independent
native geometry measures 0.299727 mm. Bare fitting to 0.30–0.40 mm normal
clearance overrides general tolerances. With the specified coating and seated
lid translation, the new top retains approximately 0.220 mm minimum clearance
and the fixed return tip 0.100 mm. The updated blank width is 1041.218 mm.
The existing 5.519205 mm³ of side/lap contact films is unchanged; old-only and
new-only contact-region subtraction are both zero.

The two handed brackets preserve the original five rivet stations and world
bottom height of 4 mm. Their profiled tops rise to 87 mm while clearing the
rear inside radius. Minimum nominal vertical top clearance is 0.201659 mm;
actual native outer-edge samples across the seam give approximately
0.219–0.303 mm. The specified 0.20–0.40 mm vertical fitting interval applies
before riveting/coating and only across the rear-seam depth. The former tall
unbacked opening is replaced by a controlled small corner relief.

The review caught a Fusion fold-frame change that initially put both brackets
through the rear wall despite healthy features. The final recorded occurrence
matrices compensate that frame change. Both documents' actual exported
brackets, placed using their recorded matrices, are valid single solids and
have zero base/lid interference. Their nearest lid clearance is 2.457870 mm.
Their world bounds agree with Fusion within 0.000001 mm, and the two documents
agree after converting their coordinate frames. All ten bracket holes were
matched to the nearby physical base holes: existing axis offsets are
0.010841 mm on rear legs and 0.010000 mm on side legs, not exact coaxiality.
The changed profiles preserve these original positions. All four bracket
native flats have zero missing/extra area and five matched reference holes.

The current populated snapshot has 423 occurrences, 973 bodies and no empty
visible leaf occurrences. The bracket STEP/native volume difference is
0.047360 mm³, within the pipeline's 0.05 mm³ minimum cross-kernel tolerance;
it is recorded explicitly rather than rounded to zero.

Fresh renders of page 1 of `segno_base.pdf` (2-page file) and the complete
one-page `segno_corner_bracket_rear.pdf` and
`segno_corner_bracket_rear_mirrored.pdf` passed visual review. Their geometry,
handed labels, quantities, dimensions, bend tables and fitting instructions
are legible, without clipping or overlap.

Physical fitting before riveting and coating, finished free seating of the
lid, and the visible-seam check remain required manufacturing operations.
This review covers the rear correction and its interfaces; root's separate
front-joint, full pipeline and saved/reopened-document checks cover the rest
of the release.
