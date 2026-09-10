# One metal-shop visit before coating — 2026-09-06

The owner requires the enclosure to leave the metal shop with all metalwork
finished, then go to a separate painter. The process now locates and finishes
all holes, taps all threads, completes chamfers/deburring, fits/rivets the corners
and fits nine numbered shim packs before coating. The bare test assembly uses
the actual pedals, screens and supports. Remove all electronics before machining.
Deliver a matched lid/body set, recorded shim thicknesses, separately bagged
packs and a map/photos of the actual hidden bearing footprints.

Masking preserves the established fit: both sidewall/lid seats, both rear-lap
contact faces, both hidden shim lands, all ten paired collar floor/lid contacts,
and both screen support chains at the floor and hidden glass/bezel-to-lid lands.
Shim mask references are 7 ×7 mm squares, centered on actual holes and clipped
to existing hidden metal. Screen rectangles are locating envelopes, not filled
mask templates. Keep visible exterior surfaces and aperture cut walls coated;
exclude the exposed rear return tail from the rear mating mask. Finished threads,
functional holes, electrical lands and the encoder disc interfaces remain masked.
No printed supports, electronics, shims or retention adhesive enter the oven.

The owner removes masks and light residue, reinstalls the numbered packs,
applies edge-only retention adhesive, fits felt and assembles. No planned new
hole location, drilling, reaming or tapping remains after coating. If parts do
not seat freely, investigate masking residue or manufacturing error; do not
pull the lid into position with screws or enlarge holes as an assembly step.

## Checked effects

- The masked seats retain the bare lid pose. Front air clearance outside shim
  lands is expected to be 0.30–0.48 mm with 60–100 µm coating per face.
- All ten native collar placements lie within their reference mask envelopes,
  with at least 0.793 mm margin below the lid and 0.493 mm at the floor. Both
  ends need masks: coating both contacts otherwise produces interference.
- Both screens also need paired masks. Their bare glass-to-lid gaps are only
  0.000037 mm and 0.013386 mm. Tower bosses remain 7.296 mm clear; there is no
  separate tower-tab mask requirement.
- The steel posts remain coated. Their expected finished felt gap is
  0.805–0.963 mm; select felt from the actual gap without lifting the lid.
- Conservatively raising modeled electronics by 0.10 mm preserves at least
  2.290 mm clearance to the screen stands. Unmodeled wiring and hardware still
  require physical checking.

The complete generator and all 34 enclosure regressions passed. Nine revised
PDFs (14 pages) were rendered and visually inspected. All 39 STEP files, nine
native forming-cache files and the forming-input JSON preserve their reviewed
pre-change bytes. Existing Fusion versions remain sheet metal135, populated348
and mini13; no native geometry or component positions changed in this correction.
The dimensional changes from the earlier reviews remain preserved.

Independent [pipeline review](prepaint-pipeline-review.md) and source review found no unresolved actionable findings.
See [geometry and datum review](prepaint-fit-review.md) and
[measured geometry evidence](prepaint-geometry-proof.json).

Evidence: [final verification](prepaint-verification.json),
[display contacts](prepaint-display-proof.json),
[electronics clearance](prepaint-electronics-proof.json), and
[screen mask reference bounds](prepaint-mask-bounds.json).

## Release limits

This is a checked manufacturing sequence, not a physical qualification. The
metal shop must accept stock, tooling, rivets, machining access and actual-part
dry fitting. The separate painter must accept the transferred mask map,
finished dimensions and smooth matte black RAL 9005 coating with no texture,
verified against a sample. Print tolerances, coating leakage/edge beads and
coating-cycle distortion still require actual inspection. Final assembly and
load/retention checks remain as listed in the release review. No supplier
message or package was sent, and no commit, push or remote review state changed.
