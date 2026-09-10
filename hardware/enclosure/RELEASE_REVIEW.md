# Manufacturing release review — 2026-09-06

September 9 supplier material correction: the provided Alcast certificate is
for 1100-H14, 2.00 mm, lot 26E0269 (yield minimum 95 MPa, reported 127 MPa).
It supersedes the assumption that the offered 2 mm stock is 1050. Job-stock
traceability and the separate 1.2 mm rear-panel material remain to be confirmed.
Existing 1050 generator/drawing callouts have not yet been reissued. This closes
the certificate's alloy/temper identification, not assembled strength or cutting
release. See [material review](../../docs/reviews/material-certificate/review.md).

Closed stadium cable-hole update, September 9: current native versions are
sheet-metal 143/populated 358, saved/reopened and checked against source.
The two collar openings are 8.6 ×13.5 mm with R4.3 ends; thread the cable
before seating the pedal. All 50 tests pass and print artifacts agree.
This supersedes the open-top cable-slot revision described below. See
[verification](../../docs/reviews/cable-hole/verification.json).

September 9 cable-opening follow-up: current native saves are sheet-metal 141
and populated 355, saved/reopened and verified. Both console collars now have
an 8.6 mm centred rear slot with a raised bottom and open top for cable
insertion. All 50 enclosure tests pass. Matching collar STEP/STL files and the
printing archive are current; metal-shop outputs are byte-identical. See
[cable-opening verification](../../docs/reviews/cable-opening/verification.json).
Earlier version/test counts below record their respective revisions.

Current September 8 status: extra floor supports are implemented and digitally
verified (15 feet total; native sheet-metal139/populated352;45 passing tests).
The current sheet-metal-only archive contains7 STEP+7 DXF files. Earlier
five-archive counts below describe historical packages and are not the current
shop handoff. The previous local geometry verdict does not establish stomp
capacity. The all-temper strip sensitivity screen flags unresolved bending;
assembled structural assessment and load validation remain open. Do not release
cutting yet. See [verification](../../docs/reviews/extra-feet/verification.json)
and [temper comparison](../../docs/reviews/extra-feet/temper-screening.json).


**Status: local source, export, drawing and native-model checks pass. Physical
supplier and assembly acceptance remains required before production release.** The owner rejected the faceplate overlay and broad fit-surface
masking. The current process supersedes the previous masked-seat package.
Nothing has been sent to either supplier, and neither cutting nor bending has
started. Work continues from `fix/drawing-legibility-1001` at `1d14d701`, with
local corrections on `codex/sheetmetal-release-fixes`.

The September 7 owner-finishing process-note update is recorded in
[the current process verification](../../docs/reviews/sheetmetal-release-fixes/owner-finishing-verification.json).
The owner measured the EC11 washer ID7.25/OD11.85. The disc now uses a straight
Ø8.50 laser bore without chamfer; the revised fit and current file evidence are
recorded in [the straight-disc verification](../../docs/reviews/sheetmetal-release-fixes/straight-disc-verification.json).
Current saves are sheet-metal138/populated351; all40 enclosure tests pass.

## Current manufacturing contract

Complete cutting, forming, fitting, hole locating/drilling and
deburring in one shop visit. Deliver untapped and unriveted. The owner
rivets before the separate painter, then cleans paint from the Ø2.5 body pilots
and manually cuts all 32 M3 body threads after painting: 18 for the lid and
14 for the screen supports.
Paint all visible/hidden faces, seats, edges and clearance-bore walls **smooth
matte black RAL 9005, without texture,60–100 µm locally**. The working exception
protects defined electrical-bond contacts only; the M3 threads are cut afterward. Broad collar/screen/seat/lap/shim masks,
general-bore masks and encoder-disc interface masks are superseded.

The individual pedal tiles retain the labels. The overlay files/package and
extra machining PDF page are retired. Use the plain-text drilling datums and
fit table in [MANUFACTURING.md](../MANUFACTURING.md) and the short Spanish
[supplier drafts](SHOP_REVIEW.md). Seven distinct fabricated metal parts make
eight pieces; nine purchased shim packs and eighteen purchased head washers
make 35 reference-assembly solids. Standalone shim/washer STEPs are excluded
from per-part archives; their occurrences are inside `segno_assembly.step`. The intended
full delivery now contains **five ZIPs /88 members**. All five archives passed exact member/content checks after full regeneration.

All 18 lid clearances become **Ø4.50(+0.10/−0.00) before paint**, finishing
**Ø4.30–4.48**. Front axes move **0.50 mm lower**, to **6.455 mm above the bare
floor underside**; horizontal stations stay fixed. Use 18 **OD 7 mm M3 head
washers**. Capture the matched bare pair at±0.15 mm front/rear centering and
0.50–0.60 mm front gap, then verify the coated pair at the same centering limit
and **0.15–0.60 mm finished front gap**, without pulling it into place.

After cure, the owner selects nine solid stainless shim packs **OD 6.90–7.00,
ID 4.0–4.2 mm**, to the actual painted gap at each station, leaving
**0.00–0.02 mm residual**. Number 1–9, record thicknesses and retain only at
edges outside the bearing stack. The nominal 0.50 mm CAD pack is not a purchase
thickness, and the former bare-fitted packs are obsolete. Fit felt/seals to
measured finished gaps. No shims/adhesive enter the oven; no new machining or
paint removal from seats is planned after coating, apart from the approved
body-pilot cleanup and M3 tapping. Qualify the actual painted
joint's clamping and coating durability.

Compensated metal M3/M4/foot bores and rear connector profiles have explicit
precoat and finished ranges in the manufacturing table. The connector row,
fixing pitches and rear-panel/window datums remain fixed. The PD local web
must measure **at least 1.20 mm** after all precoat work, and the actual barrel
and two fasteners must pass together. This is a shop-qualified detail on the
1.2 mm panel, not a blanket laser capability. The old general 1.5 mm nominal
ligament check does not replace measuring the accepted local web. A coupon
must establish the cutting and coating process before the full panel.

Encoder disc: bare **OD51.20±0.05**, straight bore **Ø8.50±0.05**, no chamfer.
Coat every face and the bore; finished OD51.27–51.45 and bore8.25–8.43.
The measured ID7.25/OD11.85 washer covers the largest finished bore with0.87 mm
minimum radial overlap under conservative opposing clearance offsets. Center
the disc before clamping with its existing washer/nut. Physical retention and
button/knob operation remain assembly checks. Earlier chamfer/bore instructions
are superseded. Ring/pill apertures and printed supports remain unchanged.

The tight riveted rear joint remains **0.05 mm nominal bare**, accepted at
**0.00–0.10 mm before riveting/coating**. Preserve square walls, required
corner reliefs, **0.30–0.40 mm bare normal ridge clearance** and
**0.20–0.40 mm bare vertical bracket-top clearance** in the seam region.

## Required before releasing the full set

1. Local source/export checks are complete: all 40 enclosure tests pass, the
   full generator reports ALL PASS, and five archives contain the verified
   88 members. All eight changed PDFs (11 pages) were rendered and visually
   reviewed. Saved/reopened Fusion sheet-metal137 and populated350 have no
   empty components or new warnings; mini13 is unchanged. See the exact
   [verification record](../../docs/reviews/sheetmetal-release-fixes/full-coat-verification.json).
2. Confirm the job uses the certified 2 mm 1100-H14 stock, obtain separate
   1.2 mm rear-panel alloy/temper evidence, and reissue obsolete 1050 callouts.
   Confirm steel grade/gauge, R2/R1.6 tools,
   K 0.33 development, deep-wall/segmented-punch access and the acute post bend.
   Make a trial bend. Confirm rear guided-punch access and all machining in
   the one visit. Select ten Ø3.2 rivets for the actual approximately 4 mm grip,
   7 mm centre-to-edge distance and available setting-tool access.
3. Verify actual purchased components with a finished-profile gauge/coupon:
   both CTRL caps and 1.20–1.50 mm finished panel thickness, USB profile/nuts,
   PD/MIDI complete fixing patterns and local material, power/fuse hardware,
   converter ears/washers, monitors/adapters and the encoder/knob stack.
   The modeled Ø22×4.5 mm knob underside relief is still an assumption.
   Resolve the hardware schedule's unqualified screw lengths and insert fits.
   Check all patterns together with their final paint allowance, including every
   M3/M4 floor, support and foot mounting pattern; a screw fitting a bare hole
   does not establish final assembly.
4. Agree the painter's smooth matte sample and local 60–100 µm bore/edge film,
   and confirm the electrical-contact protection. Gauge finished parts
   against the listed ranges; exterior flat-film measurement alone is not
   sufficient. Complete painted dry assembly, all 18 screws, removable lid,
   numbered shims, felt/seals and cap retention after the owner cleans/taps the
   body pilots; no other post-paint machining is planned.

Foot-load stiffness, tapped-thread durability, painted-joint retention, glued
ring retention, transport retention, thermal behavior and cable motion require
physical prototype qualification before repeat production. This review is not
a PCB, electrical-safety or structural qualification. The populated assembly's
selected Ø80 PR #990 ring board differs from this checkout's Ø68 Gerbers; electronics
procurement must use the matching revision. The preserved purchased-pedal
history warning is also not a substitute for actual pedal-to-sled fastening fit.

## Earlier verified revisions — historical evidence

The following records remain valid only for their recorded source/file hashes.
They do not release the fully coated changes above, and their masked-seat,
pre-fitted-shim, old disc/bore and six-archive instructions are superseded.

- [Prepaint process review](../../docs/reviews/sheetmetal-release-fixes/prepaint-process-review.md):
  the previous masked-seat process passed 34 regressions, generator/file checks
  and drawing review. It retained 39 STEP files and its native cache bytes.
- [Tight rear-joint review](../../docs/reviews/sheetmetal-release-fixes/rear-closure-review.md):
  saved/reopened sheet-metal 135 and populated 348; rear joints 0.050001 mm,
  native base flats 107 holes with zero missing/extra material, handed brackets
  matched. The lid's0.008358 mm² comparison residue was explicitly bounded.
- [Seam review](../../docs/reviews/sheetmetal-release-fixes/seam-review.md) and
  [seam verification](../../docs/reviews/sheetmetal-release-fixes/seam-fix-verification.json):
  integrated corner-relief perimeter, handed brackets and purchased support
  references; prior nominal/bare shim dimensions are now superseded.
- [Repeat review](../../docs/reviews/sheetmetal-release-fixes/round2-review.md):
  repaired the real Ring 24/holder clashes and validated the laser spur-path and
  publication-failure guards. Its archive counts/fit dimensions are historical.
- [Screen/mini verification](../../docs/reviews/sheetmetal-release-fixes/sled-screen-verification.json):
  preserved the seven-inch display's0.50 mm forward correction and the separate
  mini's two underside retention screws per sled, corrected toe relief, tabs
  and rear bosses. The current paint allowance adds a console-only screen
  setback/printed support revision. The standalone mini is unchanged; use its
  matching tray/lid/sled revision and separate hardware order.

Freeze the exact replacement package only after these checks and supplier
acceptance, and identify it so an earlier package cannot be fabricated by mistake.

## September 9 printed collar correction

The two console collar variants now use 2.4 mm front/rear light-baffle walls.
Both Fusion documents are saved/reopened at 140/353, and source/native collar
solids match. All 49 enclosure tests pass; two STEP/STL pairs and the 36-member
printing ZIP were updated. Sleds, mini-console and metal-shop files are unchanged.
This resolves the two-line wall concern; first-print insert fit and the existing
assembled structural/material/shop acceptance remain open.
[Evidence](../../docs/reviews/collar-thickness/verification.json).

## Short-screw mid-platform follow-up — September 9

Local printed-part update: tall CLEAR/BANK collars now use independent base and
sled joints. Print `segno_platform_mid_ring` with `segno_platform_mid_sled`; the
front row retains `segno_platform_front_ring` and `segno_platform_sled`. Candidate
hardware is four M3×6 base screws and four M3×12 deck screws per mid module,
with M3 Ø5 ×5 inserts in both lower interfaces. The platform/sled set now needs
88 inserts total; eight are the new collar inserts. Check actual under-head
length, insert recess, PETG fit and engagement on the first prints.

Fusion sheet-metal v144 and populated v360 are saved/reopened and match source
solids exactly. Unchanged-part/pose, native warning, STEP and closed STL checks
are recorded in [the mounting evidence](../../docs/reviews/mid-platform-mount/).
All 56 enclosure tests pass (73.636 s). The first-print ZIP has exactly four
STL parts, one of each variant; the full
print archive includes the new STEP/STL pair. The metal-shop archive is unchanged.
At the mounting review, the assumed 1050 temper was unresolved; the supplier
certificate correction above supersedes that identity question for the listed
2 mm lot. Assembled stomp performance and other physical release checks remain
open; this mounting update is not a production load approval.
