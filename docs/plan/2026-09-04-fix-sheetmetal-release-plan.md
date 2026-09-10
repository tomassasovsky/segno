# Sheet-metal release corrections

Based on the September 4 manufacturing audit and drawing branch `1d14d701`.
The owner authorized the corrections and confirmed that the shop has not begun
cutting or bending. Work is associated with the existing hardware issue #762;
physical fit and shop process acceptance remain owner/shop checks.

## Scope and order

### Accepted support follow-up — September 8

Keep 1050 aluminium and add screw-on feet. The owner accepted approximately
one addition per two pedals at the front and rear, with three or four middle
supports. The selected fit-checked layout retains four original feet and adds
four front, four rear and three staggered near CLEAR/BANK and the steel posts
(15 total). Update the generated base, both native bases, populated foot solids,
matching STEP/DXF exports and the sheet-metal-only archive. Preserve all other
geometry, and compare the new native base against the old with only these eleven
bores removed. Correct stale process notes to 32 owner-tapped M3 pilots after
painting, comprising 18 lid and 14 screen-support holes.

The owner measured sustained scale readings of 15–20 kg and a displayed maximum
of 35 kg, and weighs 70 kg. Use 200 N sustained and a provisional 700 N static
screening case; neither establishes the true stomp peak or a product rating.
Material temper, actual foot/fastener dimensions, floor contact and assembled
load performance remain unverified. Do not release cutting on fit checks alone.

1. Recover the measured September 1 monitor geometry without reverting the
   September 4 layout. Correct support-post floor datum, bend envelope and felt
   clearance; regenerate the post and affected mount stations.
2. Separate front drilling after bending from laser contours. Reconcile tapping
   after coating, finished fit and mask instructions in generator and shop guide.
3. Synchronize both Fusion assemblies and supply truthful formed references.
4. Regenerate drawings and packages; run geometry, document and package checks,
   inspect rendered sheets, then obtain independent build reviews.
5. Record the supplied buck dimensions, connector finished thickness and supplier
   bend/fit checks. An unanswered physical measurement is not release approval.

Primary files: `hardware/enclosure/segno_enclosure.py`,
`hardware/enclosure/FUSION_MODELS.md`, `hardware/MANUFACTURING.md`, and generated
`hardware/enclosure/out/` artifacts. CAD checks must cover the parts in their
assembled positions, rather than only bounding boxes.

## Success Criteria

```success-criteria
GOAL: Correct the manufacturing blockers that can be verified digitally and identify the remaining physical release checks.

SUCCESS CRITERIA:
- Generator geometry and document/package assertions pass | verify: hardware/enclosure/.venv/bin/python hardware/enclosure/segno_enclosure.py
- Post and monitor solid/contact regression checks pass | verify: hardware/enclosure/.venv/bin/python -m unittest discover -s hardware/enclosure/tests
- Both Fusion documents agree with the changed geometry and post felt clearance | verify: manual inspect native solids, measured contact planes and targeted BRep intersections in both documents
- Updated shop sheets are legible and describe the actual cut/drill/coating operations | verify: manual render and inspect every changed PDF page
- Remaining physical measurements and supplier acceptance are explicit | verify: manual check release record against the owner image and shop responses

NON-GOALS:
- Publishing or ordering parts without a completed release decision
- Cosmetic pedal legend changes, PCB revisions, or unrelated application work

VERIFICATION COMMAND: hardware/enclosure/.venv/bin/python hardware/enclosure/segno_enclosure.py && hardware/enclosure/.venv/bin/python -m unittest discover -s hardware/enclosure/tests
```

The virtual environment may be reused from another checkout; commands run with
this worktree's source and outputs. Final hardware release still requires a
first-piece assembly and coating-fit check.

## Accepted follow-up — 2026-09-05

The owner approved the proposed 1.2 mm aluminium rear panel with 0.06–0.10 mm
coating per face, updates to both Fusion documents and shop drawings, and
preparation of bend/corner questions for the shop. Preserve the panel outline,
all holes and the outer seating face. Check the nominal coating range in the
generator; measure 1.20–1.50 mm finished at the real CTRL jacks before assembly.

Acceptance: eight enclosure regressions pass; the native panel remains one
healthy solid in each saved/reopened document; all other occurrences preserve
geometry and placement; revised PDFs are rendered and inspected. The Spanish
shop review form records stock/tooling, bend development, actual corner relief
and finished-fit questions. Preparing it does not authorize sending an order
or release the unresolved corner detail for cutting.

### Owner clarification — separate suppliers and text only

Use short plain-text questions for the metal shop and a separate painter.
Withdraw the additional shop-review PDF; the technical part drawings remain.
Resolve the known base DXF/formed-STEP corner discrepancy within the design
before cutting authorization. Shop replies establish available stock/tooling
and coating process; they do not replace our file-consistency check.

## Accepted corner completion — 2026-09-05

The owner authorized resolving the full corner detail, verifying the final
base's unfolded geometry against the laser and deferred-drill contours,
synchronizing both native documents, regenerating outputs and repeating fit
checks. Keep existing supplier messages short and separate; do not send them.

Candidate validated by exact planar comparison: Ø6.5 reliefs, 0.15 mm front
end trims, and rear edge regrowth of 2.50 mm (removing the previous 0.01 mm
excess per side). Record the final unfolded-contour comparison as an enforced
generator check, not only an author observation. Preserve all other assembly
occurrences and verify the saved/reopened files. Shop stock/tooling and the
physical prototype remain separate checks after the digital work.

Completed: source and saved/reopened native versions 130 / 342 agree, both
flat comparisons have zero differing area, other occurrences retain geometry
and placement, all ten tests pass, and revised drawings and six vendor bundles
are verified. Evidence is in the corner sections of the consolidated review
and its native/artifact JSON captures. Shop and physical release conditions
remain explicitly open.

## Console collar print follow-up — September 9

Resolve the owner's thin front/rear wall concern by growing both console collars
outward from 0.85 to 2.4 mm. Keep the bore, sled, screw axes, pedal heights and
mini-console unchanged. Check the cable opening, insert/shaft alignment, coated
lid, screens, posts, LEDs, floor hardware and vents. Synchronize both native
documents and the two printed STEP/STL pairs and current printing archive.

Completed locally: 49 enclosure tests pass; sheet-metal 140/populated 353 saved
and reopened; unaffected occurrence preservation and native/source geometry
verified. See [evidence](../reviews/collar-thickness/verification.json). Physical
fit and stomp-load qualification remain outside these digital checks.

## Console cable-opening follow-up — September 9

Use the owner's pad-free cable measurement with 0.5 mm clearance per side.
Narrow both console collars to an 8.6 mm centred rear slot and raise its bottom
to 6.95 mm above the bare case underside, covering both approximate vertical
positions. Preserve the open top for assembled pedal/sled insertion. Preserve
all other geometry and placements; regenerate the two print pairs and archive,
synchronize both native documents, and verify measured-envelope clearance and
its continuous insertion path. The mini and metal-shop package are unchanged.

Completed locally: 50 enclosure tests pass; sheet-metal 141/populated 355 are
saved/reopened with exact native/source collar parity. Matching print files
and archive are verified. [Evidence](../reviews/cable-opening/verification.json).

## Closed stadium cable-hole correction — September 9

The owner confirmed that the cable can be threaded through before the pedal
is seated, then requested a stadium border. Replace the open slot with a
closed vertical stadium, 8.6 ×13.5 mm overall, R4.3 mm ends and 4.9 mm straight
sides. Keep the 6.95–20.45 mm vertical bounds above the bare pedal underside.
The clearance calculation assumes a stadium-shaped 7.6 ×11.45 mm fitting;
actual fitting/connector passage needs a first-print check. Preserve all other
geometry, synchronize both Fusion documents and printed artifacts, and verify
the exact profile, surrounding bridge and padded fitting envelopes.

Completed locally: 50 tests pass; sheet-metal 143/populated 358 saved/reopened
with exact source/native collar parity. The four print files and printing
archive agree. [Evidence](../reviews/cable-hole/verification.json). Conditional
XHP-2 connector screening also clears at 0.628 mm nominal minimum gap; this
does not identify the user's connector or replace an actual fit check.

## Accepted short-screw mounting — September 9

The owner approved separating the two tall CLEAR/BANK platform joints while
retaining their bottom-base attachment. Replace the four tall through-bores
with bottom-facing M3 Ø5 ×5 insert pockets, retaining the metal-hole axes.
Add four deck clearances at local X ±30 / Y ±18 mm and a dedicated mid sled
with matching lower inserts. Target M3×6 at the base and M3×12 through the
8 mm deck. Assemble and service the upper joint on the bench. Preserve front
parts, mini-console parts, seating, cable stadium and all metal geometry.

Verify blind pocket roofs, insert envelopes, short screws and driver access,
seating and preserved geometry; synchronize both Fusion documents and the
STEP/STL exports. Refresh the first-print archive with front and mid variants
and no extra documents. Run the enclosure tests and independent reviews.
Physical PETG insert fit, actual hardware and assembled load qualification
remain first-print checks; digital fit does not qualify stomp strength.
