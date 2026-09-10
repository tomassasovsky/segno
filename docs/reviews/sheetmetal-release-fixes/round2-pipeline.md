# Manufacturing pipeline review, round 2

## Result

One new actionable validation defect was reproduced and fixed: an inward
out-and-back CUT spur could be healed away by OpenCascade while remaining in the
laser DXF. No additional unresolved pipeline finding was reproduced in the
reviewed source and current six metal drawings. The final holder/disc follow-up
and final file verification below also completed without another finding.

## P2 — Reject cutting segments discarded by face healing (fixed)

Location: `hardware/enclosure/flat_pattern_check.py:33–41`.

The previous validator required a closed wire and a valid face, but those checks
accepted the points `(0,0),(100,0),(100,100),(50,100),(50,50),(50,100),(0,100)` as a
100 × 100 mm square. The input has 500 mm of cutting path, including a doubled
50 mm inward slit; the healed face has only 400 mm of boundary. Thus the
validation discarded two cutting segments that remain in the actual DXF.

Reproduced through the real publisher in an isolated copy of the current output:
a 5 mm inward/outward spur added to the rear-panel outer CUT polyline passed
`validate_cut_contours()` and `build_quote_packages(with_step=True,
with_pdf=False)`. The published metal ZIP contained the modified DXF bytes
unchanged. This is a reproducible guard defect, not a claim that the current
shop drawings contained such a spur. The current six metal drawings were clean.

Fix: after making the valid face, require its outer boundary length to preserve
the sum of every original curve's length, within 0.000001 mm. This detects the
actual loss during OCC healing without introducing another geometry library.
A regression inserts an inward/outward slit into a freshly generated support
post CUT outline, calls the real package builder, and proves it rejects the
contour before replacing previous vendor archives.

The change is confined to `flat_pattern_check.py` and
`tests/test_manufacturing_pipeline.py`; no shared CAD output or native model was
changed by this agent. The coordinator authorized this fix during the initially
read-only pass.

## Verification

- Independently reran all 23 pre-existing manufacturing tests: passed in
  18.430 seconds. After the added regression, all 24 tests passed in 30.706
  seconds. Command: `python -m unittest discover -s hardware/enclosure/tests -v`
  using the enclosure CAD environment.
- Regenerated every DXF writer into scratch. CUT, VENT, DRILL and BEND geometry
  exactly matched every corresponding current output, including the overlay.
  All six emitted metal cutting files passed the strengthened contour check.
- Rebuilt the Fusion handoff JSON into scratch: exactly equal to the current
  `out/fusion_formed_input.json`.
- Rechecked complete final native flats: base 107 registered reference holes,
  0/0 mm² missing/extra; rear bracket 5 holes, 0/0 mm²; lid 10 holes,
  0.008358020637/0.008358020636 mm². The lid values are below the established
  0.01 mm² limit and retain the documented 0.000273 mm front-drill residue.
  Its opposite-face view remains explicit; the comparator does not search for
  a mirrored candidate.
- Checked all six existing vendor archives: no bad CRC, duplicate names or
  differing loose-file bytes across 86 members. Archive SHA-256 values matched
  the coordinator's full-review verification record at the start of this pass.
- Independently parsed all 20 current PDFs with Poppler `pdfinfo`: no parse
  failures. Base and lid each have 2 pages, the painter reference 4, and each
  remaining drawing 1. This supplements the generator's own page counters; it
  is not a new visual-layout review.
- The five recorded source SHA-256 values matched at review start. The guard
  and regression deliberately change two of them; the final evidence record
  must be refreshed for the final revision.
- Additional negative contour probes rejected doubled traversal, partial
  overlap, open/zero-length paths and touching lobes; the previously accepted
  spur is now rejected. Existing tests also cover duplicate/nested/outside/
  crossing/touching holes, wrong units, unauthorized face mirroring, stale
  native records, modified STEP/flat bytes, altered final-flat geometry,
  missing ZIP members, staged ZIP write failure and invalid/failed paint PDFs.
- Read the complete generator publication flow and cross-file callers,
  signature construction, native sketch/rule/fold/drill validation, native
  visibility restoration and flat export, flat comparison, eight-part metal
  assembly builder, all metal DXF writers, metadata and drawing gates, paint
  BOM/area calculations and both manufacturing test modules.

The existing paint-failure and partial-generation fixes remain closed: PDF
failures propagate; drawing checks finish before archive staging; missing or
stale members are preflighted; ZIP contents are staged before publication;
`--no-step` withholds metal/STEP/painting/printing archives. Replacements are
atomic per ZIP, as documented, rather than a transaction spanning all final
filenames.

## Native scope and limits

This agent did not operate Fusion. The coordinator reviewed both native
assemblies and their actual fit. A queried concern about suppressed fold
features was closed by native evidence: suppressed features return health state
3, whereas the exporter requires healthy state 0; current metal features were
all state 0. No suppression bypass was reproduced or reported as a finding.

CAD equality and these tests do not certify a supplier's tooling, coating
sample or inspection execution. Those physical confirmations remain the
coordinator's release process. This report assesses the inspected pipeline and
files, not an unconditional manufacturing guarantee.

## Reproduction evidence

Isolated evidence: the local scratch workspace (not a release artifact).

- `probe.py`, `probe-results.json`: new contour probes and archive integrity.
- `spur.py`, `spur.log`, `spur_shape.py`: original real-package acceptance and
  observed OCC path loss.
- `parity.py`, `parity.log`, `parity-after-spur.log`: fresh source/file and
  native-flat checks.
- `tests.log`, `tests-after-spur.log`: complete observed test outputs.

## Final holder/disc follow-up and publication verification

Reviewed the final `build_ring_diffuser_step()` changes, the independent
`reference/ring24_interface.json` fixture and both new fit tests. No actionable
issue was found. The fixture covers 41 selected native Ring24 component
positions/heights and preserves the measured centre offset. The tests check
one valid connected holder, minimum nominal clearance above 0.13 mm, bottom
insertion, and counterexamples for both the old solid lens and a lower bridge
that would trap the PCB despite clearing its final position. The disc test
checks the 51.40–51.50 mm finished diameter and demonstrates interference when
0.10 mm radial coating is left on an uncontrolled nominal disc.

The new open-bottom relief and eight ribs keep the existing
`segno_ring_diffuser.step`/`.stl` deliverable and quantity one. The exact package
set remains six ZIPs and 86 members. Source notes, the disc DXF/drawing and
painter BOM now require a controlled finished disc outside diameter and masking
of its outer edge. The coordinator ran all **26 tests** on this finalized
source (33.388 seconds), completed the full generator with all assertions
passing, and visually inspected the five changed PDFs. This agent independently
reviewed the new source/tests and checked the final files; it did not repeat
that unchanged full test run or claim the coordinator's visual review as its
own.

After the coordinator's explicit generator-complete signal, normalized only
export-date differences against **this round's**
the output backup made at the start of this repeat review. For 46 STEP/PDF files, stripping only the
STEP `FILE_NAME` timestamp or PDF CreationDate/ModDate fields made the old and
new bytes exactly equal; these files were restored byte-for-byte. Five other
files were already identical. The six real content changes were retained:
base, lid, post, ring-disc and painter PDFs, plus the holder STEP. Other file
types were not normalized. All archives were staged and repacked in their
existing member order with the existing ZipInfo metadata and final loose-file
bytes.

Final independent verification passed: all six archives have unique expected
members, valid CRCs and exact byte equality with their 86 loose files; all six
metal CUT/VENT paths pass the strengthened guard; cached STEP/flat hashes and
all three native-flat comparisons pass with the same areas listed above; all
20 PDFs parse in Poppler. No source or native geometry was changed during this
normalization and final check.

Machine-readable final evidence, including every source/archive/member SHA-256:
the source/archive/flat/PDF sections of `round2-verification.json`. Normalization proof and
complete restored-file list:
the `export_date_normalization` section of `round2-verification.json`. The coordinator will incorporate
these exact final bytes into the durable round-2 manifest.
