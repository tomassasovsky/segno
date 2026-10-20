# Review — codex/sheetmetal-release-fixes

Current corner result: **0 unresolved findings; all five bounded reviews complete**.
VGV, architecture, test quality, simplicity and readiness reviews completed. Both Fusion
documents passed preservation and full flat-pattern parity checks after
save/reopen at versions 130 / 342. Earlier converter and panel checks remain
valid; their artifact hashes are historical snapshots superseded by the final
corner package verification.

Initial review: 3 findings (1 critical, 1 important, 1 suggestion), all resolved
and re-reviewed by five independent roles. A September 5 user report exposed
an additional converter replacement regression that the initial review and
name-based live checks missed. The correction and its evidence are below.

Reviewed the working change against `1d14d701`, including new exporter, native
exports, tests and manufacturing documentation. Initial finding locations below
refer to the first review; raw reports contain the follow-up evidence.

## Findings index

| ID | Severity | Rule | Location | Finding | Status |
|---|---|---|---|---|---|
| FINDING-01 | Critical | `vgv/incomplete-verification` | `hardware/enclosure/fusion_export_formed.py:65` | Verify actual folds and formed drilling before certifying native exports | Resolved |
| FINDING-02 | Important | `tests/incomplete-assembly-placement-coverage` | `hardware/enclosure/tests/test_manufacturing_fit.py:99` | Verify every metal part's assembly placement | Resolved |
| FINDING-03 | Suggestion | `simplicity/redundant-geometry` | `hardware/enclosure/segno_enclosure.py:4755` | Construct the monitor case once and reuse the fused solid | Resolved |
| FINDING-04 | Critical | `cad/wrong-component-verification` | `hardware/enclosure/FUSION_MODELS.md` | Remove obsolete converters and verify the actual replacement solids | Resolved |
| FINDING-05 | Important | `vgv/table-column-spacing` | `hardware/enclosure/segno_enclosure.py` | Separate material and decimal-size columns in the paint table | Resolved |
| FINDING-06 | Critical | `cad/hidden-component-export` | `hardware/enclosure/fusion_export_formed.py` | Export hidden parts with their bodies temporarily visible | Resolved |
| FINDING-07 | Critical | `vgv/incomplete-verification` | `hardware/enclosure/flat_pattern_check.py` | Reject disconnected cutting contours before comparing flat material | Resolved |
| FINDING-08 | Important | `tests/missing-integration-failure-test` | `hardware/enclosure/tests/test_manufacturing_fit.py` | Test generator rejection of an incorrect native flat | Resolved |

## Resolutions

**FINDING-01.** Matching sketches and feature counts could accept the wrong
bend angle or drilled-hole location. The handoff now carries authoritative
sheet rules, signed fold angles/source lines, and formed hole axes/radii/spans.
Fusion checks actual native feature parameters and full cylindrical through-hole
faces before export. Negative regressions reject wrong gauge, angle, direction,
source line, hole location, radius and blind-hole depth. Native verification
passed. Reported by [VGV](raw/vgv-review.md) and
[architecture](raw/architecture-review.md); both re-reviews have zero findings.

**FINDING-02.** The eight-part test initially checked only base, lid and posts.
It now also checks bracket seats and rivet axes against the base, rear-panel
seat and four mounting axes, and ring/shaft registration to the lid aperture.
A deliberately displaced bracket fails the checks. The
[test re-review](raw/test-quality-review.md) passed.

**FINDING-03.** Simplified the measured monitor to one case extrusion minus
the display and reused the fused case/block solid. Geometry remained equivalent
and existing contact checks passed. The
[simplicity re-review](raw/code-simplicity-review.md) passed.

[PR readiness](raw/pr-readiness-review.md) found no defects. Author-written
Python/Markdown/SVG passes whitespace checks and Python compilation. Exporter
whitespace is left intact in native STEP data. Unchanged generated outputs were
restored only after geometric/content comparison, including pixel-identical
pedal PDFs; no unrelated source was changed.

**FINDING-04.** The old nested converter occurrences survived proxy deletion.
Fusion renamed the new blocks `buck_10a (1)`, and name-based placement/clearance
checks matched the old nine-body components. They were moved outside the
enclosure; a no-overlap result therefore proved nothing about the intended
replacement. Explicit Remove features now remove both obsolete instances and
both plain blocks. Two `buck_converter_10a` references contain recognizable
housings with the supplier envelope and hole pattern. Casing, fins and ear
thickness are approximate visualization geometry; an independent full block
remains the conservative clearance reference. The new regression reads both
STEP files and checks their solids, dimensions, hole axes and open ear space.
The latter is a shape regression, not qualification of the Ø12 washers.

After native recompute, all 413 unaffected occurrences retain their transforms,
body counts, volumes and world bounds. There are exactly two converter solids,
no empty leaf components, correct floor seats and four converter holes coaxial
with the base. The fresh full-envelope sweep checks 1344 body pairs, with zero
overlaps. This replaces the earlier invalid converter result.

The populated document was saved, allowed to finish cloud processing, closed
and reopened as **version 340**. All checks above passed again in the reopened
document; the assembly and isolated housings were visually inspected. The
[native verification capture](converter-verification.json) records the exact
counts, bounds, hole centres and STEP checksum. Follow-up source reviews are
recorded in the VGV, test-quality and simplicity reports, plus
[architecture](raw/converter-architecture-review.md) and
[PR readiness](raw/converter-pr-readiness-review.md). These reviewers assess the
implementation and evidence; live Fusion verification was performed by the author.

## Validation and limits

- Full generator: geometry, drawing and package assertions pass; all six vendor
  bundles generated, including seven STEP files for eight metal pieces.
- Eight enclosure tests pass, including failure cases and native-capture checks.
- Both Fusion documents saved; changed metal features healthy. Bare front gap
  0.500001 mm; post normal gap 1.2 mm; native post unfold matches the DXF.
- Thirteen changed PDF pages rendered and inspected: base/lid flat plus formed
  drilling pages, four other metal sheets, overlay and four coating pages.
  Eleven unchanged pedal PDFs also compared pixel-for-pixel with the base.
- The earlier 118-pair sweep included incorrectly selected converters, and the
  1338-pair converter sweep is withdrawn. The corrected evidence above checks
  the actual replacement identities, geometry and full clearance envelopes.
  Base/lid contact films remain approximately 5.52 mm³, so coating fit still
  requires a first set.

This is local engineering verification, not remote CI or physical manufacturing
approval. The remaining release conditions are in
[RELEASE_REVIEW.md](../../../hardware/enclosure/RELEASE_REVIEW.md).

## Rear-panel follow-up — 2026-09-05

The owner approved changing the rear panel from 1.5 to 1.2 mm aluminium, with
0.06–0.10 mm coating per face. Material and drawing metadata derive from the
current gauge; the paint table now preserves a decimal place so 1.2 mm is not
rounded to 1 mm. A nominal-thickness guard rejects stock/coating combinations
outside the NJ6FD-V range. The new regression proves the nominal combination
and rejects undersized/oversized alternatives; all eight tests pass.

Both native panels were edited in place. The outer wall seat and hole pattern
remain fixed; the inner face moves 0.3 mm rearward. After saving and reopening
sheet-metal version **129** and populated version **341**, each panel is a
healthy single 1.2 mm solid. All other 17 / 414 occurrences retain component
identity, body count, volume, bounds and placement. See
[panel verification](panel-verification.json). The native assembly was visually
inspected with the lid hidden, as in the owner's inspection state.

The full generator passed geometry, drawing/package and freshness gates.
Following the final paint-table formatting correction, the geometry and
DXF/package checks passed again, the paint PDF retained all four pages, and
archive membership and every member's bytes were verified against final files.
Only rear-panel DXF/PDF/STEP, metal assembly STEP and paint quote changed from
the preceding converter repair; unchanged generated files were restored after
content/geometry comparison, including pixel comparison of PDF pages.
The converter STEP checksum still matches the saved converter proof.
[Artifact checksums and package verification](panel-package-verification.json).

Rendered and inspected seven pages: rear-panel drawing (one), paint quote
(four), and new Spanish shop review form (two). The form explicitly requests
stock/tooling, bend-development and corner-detail acceptance; it documents the
Ø6.0 cutting-relief versus Ø6.5 native modeling-relief discrepancy and asks for
an agreed dimensioned detail before cutting. Physical finished thickness, jack
retention, first-set assembly and prototype load/transport checks remain open.

**FINDING-05 — resolved (Important, vgv/table-column-spacing).** Decimal sizes
filled the paint table's 20-character size field and ran into the material
column. Widened the field and matching header/totals to 25 characters. The
regenerated PDF was re-read and visually inspected by author and VGV reviewer;
all material and size columns have a clear gap.

Bounded panel review reports: [VGV](raw/panel-vgv-review.md),
[architecture](raw/panel-architecture-review.md),
[test quality](raw/panel-test-quality-review.md),
[code simplicity](raw/panel-code-simplicity-review.md), and
[PR readiness](raw/panel-pr-readiness-review.md). These reviews assess source
and captured evidence; native checks and visual inspection were performed by
the author. No shop communication, order, production release, commit or push
was performed.

### Supplier handoff clarification — 2026-09-05

The owner declined the additional review PDF and confirmed separate metal and
painting shops. Replaced the long review form with two short text drafts in
`hardware/enclosure/SHOP_REVIEW.md`, removed the unused review PDF from outputs,
and updated the active handoff instructions. Historical PDF QA above records
what was checked before withdrawal. CAD, technical part drawings and coating
files were unchanged by this clarification. At that point, the base CUT/formed
STEP discrepancy remained a file-level blocker. It is resolved below.

## Corner completion — 2026-09-05

The owner authorized the full corner correction and digital release checks.
The source now uses Ø6.5 mm reliefs and 0.15 mm trims at each front-wall end.
Native rear regrowth changed from 2.51 to 2.50 mm, removing a 0.01 mm excess
at each end. The generated contours and both native final flat patterns now
agree over the whole part. Each comparison registers 107 reference hole
centres, with zero missing and zero extra area at a 0.01 mm² tolerance.
Deferred DRILL geometry participates in verification only; it is excluded
from laser cutting.

Both native bases were edited in place, saved, allowed to complete cloud
processing, closed and reopened as sheet-metal **130** and populated **342**.
All base features remain healthy. All 17 / 414 other occurrences preserve
identities, body counts, volumes, bounds, placements, visibility and appearances.
Base/post and base/bracket intersections remain zero; base/lid contact films
remain approximately 5.52 mm³. The reopened populated assembly was visually
inspected with the lid hidden, preserving the owner's inspection state.
See [saved native proof](corner-verification.json).

**FINDING-06.** Author testing caught an empty lid STEP although Fusion returned
export success: the lid was hidden. The exporter now temporarily shows each
part occurrence and body, and restores visibility in `finally`. The eight-part
assembly test passes after export and native preservation checks prove that
the lid remains hidden afterward.

**FINDING-07.** VGV reproduced a false pass by adding a detached 10×10 mm CUT
square outside the sheet. Treating all smaller profiles as holes silently
discarded that path. The comparator now rejects contours that do not intersect
the sheet while accepting the partially overlapping corner reliefs. The exact
reproduction is a negative regression; VGV re-review passed.

**FINDING-08.** Direct comparator tests did not protect its generator integration.
The new regression calls `_formed_record('segno_base')`, first rejecting an
altered flat checksum and then rejecting its wrong material geometry after
updating that checksum. Test-quality re-review passed.

All ten enclosure tests pass. The full generator passed geometry, drawing,
package and freshness checks. Both base drawing pages and all four paint
pages were rendered and visually inspected. Unchanged outputs were restored
only after exact content/pixel comparison. Lid and bracket STEP entity ordering
changed during native re-export, so those fresh verified exports are retained.
Final archives preserve
their membership and every member matches the final file bytes. The supplier
converter reference checksum remains unchanged. See
[final artifact and archive proof](corner-package-verification.json).

Bounded corner reports: [VGV](raw/corner-vgv-review.md),
[architecture](raw/corner-architecture-review.md),
[test quality](raw/corner-test-quality-review.md),
[simplicity](raw/corner-code-simplicity-review.md), and
[readiness](raw/corner-pr-readiness-review.md). Reviewers assess source and
captured evidence; live Fusion checks and visual QA are author verification.
Shop tooling/stock confirmation and first-set assembly, coating and loading
checks remain physical release conditions. No supplier message, order, commit,
push or production release was made.

## Smooth matte finish — 2026-09-05

The owner specified smooth matte black coating. Updated the generator finish
string, manufacturing specification and separate painter's text to smooth
matte black RAL 9005, with the existing sample-coupon confirmation, film
thickness and masking requirements. Regenerated only the coating PDF and
updated its seven-member painting ZIP. All four PDF pages were visually
inspected; extracted text changed only the finish wording and the three
masking pages are pixel-identical. Every other output remains byte-identical.
This narrow wording update was author-verified; no new geometry or test change
required another CAD review. The updated
[finish artifact checksums](finish-package-verification.json) supersede only
the coating PDF and painting ZIP hashes in the earlier corner capture.
