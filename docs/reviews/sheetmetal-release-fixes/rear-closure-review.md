# Tight riveted rear joints — verified September 6, 2026

The remaining straight rear/side opening is corrected from 0.610842 mm to
0.050001 mm on both sides in both Fusion designs. The owner chose rivets and a
fine visible joint line. The canonical source extends each side 0.560840885 mm;
the upper R2 corners and Ø6.5 lower reliefs remain true arcs.

The source and shop notes require 0.00–0.10 mm bare dry fit before riveting and
coating, with square walls and no force. The separate ridge, bracket and front
shim requirements remain in place. Smooth matte black coating and separate
metal/painting suppliers remain the chosen process. No supplier was contacted.

## Digital verification

- Saved and reopened sheet metal135: 27 occurrences/27 bodies, zero warnings.
  Populated348: 423 occurrences/973 bodies, with the same41 historical reference
  warning rows. No empty leaves. All unrelated geometry, poses, appearances and
  visibility are preserved; earlier screen and standalone sled corrections remain.
- The populated base retains16 healthy native features. The sheet-metal source
  base was rebuilt from the current DXF after its old derived flat-pattern asset
  failed to load following saving. The replacement has12 healthy features and
  five folds. Its old component and broken flat asset were removed. All five
  source-document flats now load; its actual base flat exports after reopening.
- Both base flats match107 reference holes with zero missing/extra area.
  Nominal hole stations and radii remain unchanged. The VSM rebuild retains the
  former recipe’s45microdegree lap-angle rounding: rear pilot centers differ by
  at most0.0000114mm, while all ten rivet centers are unchanged. Both brackets remain clear. The rebuilt base
  retains the same three lid-contact regions: the maximum rear-lap contact depth
  is0.000274 mm, a numerical seating film. Physical free seating remains required.
- The complete generator and34 regression tests passed. Seven cutting geometries,
  four formed caches, six ZIPs/90members and21 parsed PDFs passed independent
  checks. Base and painting PDFs were rendered and inspected. Only the base,
  assembly representation, affected drawing/paint information and handoff changed
  substantively; other export changes are proven metadata/ordering differences.

## Evidence and limits

[Saved-model verification](rear-closure-verification.json),
[native measurements](rear-closure-native-measurements.json),
[source and package checks](rear-closure-files-verification.json),
[geometry review](rear-closure-geometry-review.md),
[interface preservation](rear-closure-interfaces-proof.json),
[rebuilt geometry review](rear-closure-rebuild-review.md),
[rebuilt seating contacts](rear-closure-rebuild-contact-proof.json),
[output-delta checks](rear-closure-output-delta-verification.json).

No unresolved actionable defect was found in this correction. This is not a
physical production qualification: shop stock/tooling, bare corner fit, actual
hardware/grip/fastener engagement, coating sample and final assembly/load checks
remain as listed in [the release review](../../../hardware/enclosure/RELEASE_REVIEW.md).
The prior0.61mm corner gap record and0.5–0.8mm fitting instruction are superseded.
