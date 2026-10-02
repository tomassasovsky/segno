# Repeat manufacturing review — 2026-09-05

Base/head: `1d14d701ee9f6c3ad304a63fc60a79e3681afbd1`, from
`fix/drawing-legibility-1001`. Reviewed the local working changes, including
untracked manufacturing sources, references and outputs, on
`codex/sheetmetal-release-fixes`. Exact reviewed source and output hashes are in
`docs/reviews/sheetmetal-release-fixes/round2-verification.json`.
No commit, push, merge, supplier communication or remote gate change occurred.

## Subsequent seam finding

The owner's later seam inspection reopened manufacturing release. See
`docs/reviews/sheetmetal-release-fixes/seam-review.md`: rear-ridge closure and
front screw-joint clamping remain unresolved. The result below records the
preceding pass and is not the current overall manufacturing verdict.

## Result (preceding pass)

**Clean within the reviewed digital scope.** All three independent reviewers
completed their final pass with no unresolved actionable findings. All reproduced
findings below are fixed and verified on the recorded final working revision.

## Reproduced findings corrected

1. **P1 — Ring24/holder interference.** The selected pin-strip stack overlapped
   its printed holder in 40 real component bodies, totalling approximately
   731.56 mm³. The corrected open-bottom PCB/LED cavities and eight ribs retain
   one connected holder, its original visible lens and board/encoder positions.
   Check all 73 board bodies and bottom-up insertion; no sealed lower bridge.
2. **P2 — Coated disc outside diameter.** A maximum coating film closed the
   nominal holder clearance. Specify finished OD 51.40–51.50 mm, overriding
   general contour tolerance, and mask/finish the outer edge in both shop texts.
3. **P2 — Lid lateral registration.** Seating alone allowed the lid to shift
   sideways before match-drilling. Center and square its front/rear edge
   midpoints within ±0.15 mm and check actual pedal clearance before capture.
4. **P2 — Retraced cutting segments.** OpenCascade could heal away a doubled
   slit while its DXF remained unsafe for CAM. Preserve every cutting segment's
   length through face construction; the package regression rejects the slit
   without replacing prior archives.
5. **P3 — Stale bend references.** Generate the 5.128 mm front drill-to-bend
   distance and 12.666 mm pedal-edge ligament from current geometry.
6. **P3 — Overstated coated post gap.** Account for coating at the post foot and
   lid seats. State the approximately 1 mm finished target, measure the actual
   gap and fit felt without lifting the lid; nominal local film extremes are
   0.925–1.163 mm.

## Final verification

- Complete generator and 26 regression tests pass. New negative cases cover the
  old ring clash, trapped insertion, disc-edge coating and retraced laser slit.
- Populated Fusion saved/reopened at 344; sheet metal remains 131. Existing
  holder ID/body retained. Three added features are healthy; all 414 other
  populated occurrences and all 18 metal-source occurrences are unchanged.
  Populated totals: 415 occurrences, 964 bodies, zero empty leaves.
- Source/native holder solids are valid, one connected body each, with zero
  missing/extra volume. Minimum nominal PCB axial gap is 0.134601 mm; the
  physical printed fit remains an explicit acceptance condition.
- Expanded printed-part native sweep: 1,056 candidate pairs, no Boolean
  failures. Remaining physical contacts are measured 0.000139 mm sled seats,
  0.004513 mm tower tab seats and 0.007803 mm tile/rubber fit residues. The 24
  ring_comet bodies are visual light effects. These are explicitly disposed,
  not falsely reported as zero numerical intersections.
- Six laser files pass topology checks. Fresh final-flat comparisons preserve
  base/bracket 0/0 mm² and lid 0.008358 mm² each way within the 0.01 mm² gate.
- All six archives / 86 members match exact final loose bytes and pass CRC
  checks. All 20 PDFs parse. Five changed PDFs / ten pages were rendered and
  inspected independently by the coordinator and geometry reviewer. The holder
  orientation SVG was also rendered and inspected.
- Forty-six unchanged STEP/PDF files were restored only after proving all
  non-date bytes identical to this pass's starting output. Real changes remain.

## Review completeness and limits

Independent geometry, purchased-interface and pipeline reviewers covered the
complete assigned diff and surrounding code, removed guards, cross-file data,
source/native consistency, assembly and insertion, coating stacks, drawing
operations, negative validation cases and archive publication. The coordinator
reproduced the important findings and reviewed the fixes and final artifacts.
No reviewer or required digital check is missing after final closure.

This is a digital manufacturing review, not physical release acceptance. Shop
stock/tooling/trial bends, exact rivet selection, purchased-part and fastening
measurements, actual printed-holder fit/retention, smooth matte RAL 9005 sample,
and first-piece dry/coated assembly remain open as described in
`hardware/enclosure/RELEASE_REVIEW.md`. Structural, electrical, thermal and PCB
qualification are outside this review. Existing purchased-reference feature
history warnings were preserved and disclosed; manufactured features are
healthy. The selected Ø80 PR #990 board is not the checkout's Ø68 Gerber package.

Raw reviews: [geometry](round2-geometry.md), [interfaces](round2-interfaces.md), [pipeline](round2-pipeline.md).
