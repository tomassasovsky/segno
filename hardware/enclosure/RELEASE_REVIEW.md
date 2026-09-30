# Manufacturing release review

## Integrated revision - 2026-09-30 (#1088, #1070, #1075, #1067)

One line now carries everything the owner has chosen or printed:

- **Base (#1067, #1088):** the #1025 base again (no lid-seat flanges, no rear
  tabs, no spot welding), four fusion-welded corners, seven M4 beam screws, the
  lid overhang tapering to flush at the back, and every rear connector cut into
  the 2.0 mm rear wall (no I/O panel). CTRL jacks are NJ6FD-V in MEIRIYFA
  D-flange plates. The earth stud is centred between the vents and PD_IN.
- **Power group (#1088):** screen-power board, both bucks and the PD board behind
  CLEAR/BANK at the owner's placement. Rear rail segments 2 and 3 are their own
  prints, pocketing the buck bolt heads.
- **Screen mounts (#1070):** mirrored 15.6in stands with splice and shims; the
  base's right-stand holes moved to the mirrored positions; the closed-deck 7in
  tower, unchanged from the one printed (the ring moved down the slope instead
  of notching it, #1090).
- **Console strip ring (#1075):** 34 LEDs, an alternative to the Ring24 holder.
- **Printed parts on hand:** mirrored stands, closed-deck tower (current), 2.4 mm-wall front collars, solid
  CLEAR/BANK collars, tall eight-LED pills (#1074).

Evidence:

- The full generator and all 154 enclosure tests pass; the console ring's own
  four tests pass. Master is merged in.
- The populated Fusion clone ("VAMP console (populated) - 1067 tabs + seat
  flanges") matches: base CUT edited in place (plate 4,986.9663 cm2, healthy),
  formed base re-exported and verified by `fusion_export_formed.py`, and the
  generator's flat-pattern parity passes against it.
- Interference in the clone: the power group only touches what it bolts to
  (Q5's untrimmed model leg reaches the floor; trim it); the strip ring only
  meets the faceplate at its glue faces; the tall pills touch nothing at any of
  the ten stations; both 15.6in stands' flange holes sit within 0.1 mm of the
  base holes (±1.25 float).

Open before cutting metal (owner):

1. **Dinacut** accepts the tooling, fold sequence and developed profile of the
   four-corner base.
2. **#1019** structural hold: the owner's call, with the numbers and the
   first-article proof test below.
3. ~~Post-weld fitting/drilling provider~~ settled (#1090): Dinacut drills the
   nine front stations from Ø1.0 laser pilots after folding, before welding.
4. ~~PD coupler diagonal~~ settled (#1090): the owner found the cut flipped
   against the part; it now takes the CTRL plates' diagonal (top-left /
   bottom-right seen from behind).
5. **Ring choice** after the bench light test: Ring24 holder + aluminium centre
   disc, or the 34-LED strip ring (no disc; check the knob grips the shaft
   8 mm in). Either way the ring now sits at v 215.0 (owner drag, #1090).
6. **Screen-power USB host leads** are about 40-45 cm from the Pi to the board,
   longer than the 30 cm the #1072 review assessed.

Settled since: **CTRL presence contact is tip-normal (TN).** J20/J21 pin 4 goes
to each NJ6FD-V's tip-normal lug. The netlist, the v2 soldering guide and the
firmware on master all say TN; only the unmerged PR #1082's README and sketch
comment say ring-normal. Electrically both would read "high = empty" on this
board (the tip sits on a 10k pull-up, the ring on its 1k bias), but TN opens
last as a plug goes in, which is the "ignore a plug until it is seated"
behaviour the netlist describes.

**Beam ears unbolted** (owner call 2026-09-30): no M4 through the side walls,
so no screw heads show there. The ears still locate the beam across the width
and stop either wall bowing inward past 0.5 mm; the FE model never counted the
ties, so the numbers below are unchanged.

### #1019 decision package

Nonlinear shell FE (`_stomp_fea_beam.py`, re-run on this revision with its seven
beam bolts), 1 kN on the worst pedal station:

| Case | Floor peak | Deflection | Util. vs yield | Worst station |
|---|---|---|---|---|
| no beam | 95 MPa | 3.28 mm | 1.00 | BANK |
| beam, 7 bolts, slotted (as drawn) | 139 MPa | 2.98 mm | 1.46 | CLEAR |
| beam, 7 bolts, plain holes | 175 MPa | 2.89 mm | 1.85 | CLEAR |

All stay under the RC-600 calibration point (util 2.00, a shipping product run
through the same model). The beam costs 0.46 of floor margin and raises the
faceplate's weakest point on the band from 47 kg to 475 kg. The model does not
represent the welds; welded corners are stiffer than the riveted brackets it
was calibrated against, so this is not optimistic on that account. It is still
a model: the proof test below is what rates the real part.

**First-article proof test** (welded base, bare metal, before paint):

1. Assemble without electronics: beam bolted (7 × M4, slotted, snug),
   rails with the neoprene strip, all ten printed collars. The M3 pilots
   are still untapped (tapping comes after paint), so seat the lid freely and
   hold it with four spring clamps, two on the front lip and two on the rear
   lap: less restraint than 18 screws, so the test errs on the safe side.
   (The front stations are drilled by now, but the pilots are untapped.)
   Stand it on a flat hard floor.
2. Mark four stations: CLEAR, BANK, the centre front-row pedal and an end
   front-row pedal. At each, measure the lid top height against a straightedge
   laid across both side walls (feeler gauge or dial gauge).
3. Load each station through a Ø60 mm hard puck with 100 kg of weights
   (about 1 kN) for 60 s. Unload and measure again.
4. Pass: residual set ≤ 0.2 mm at every station, no crease or dent, no crack at
   the welds or the beam ears, front lid gap still 0.70–1.50 mm at all nine
   stations. Then 20 ordinary stomps on each tested station, and look again.
5. Fail: stop, record the station and the set, and do not send to paint.

Also open, not blocking the cut: the `VAMP console (populated)` original and the
`VAMP sheet metal` document still hold the September 15 revision; promote the
clone (or port its edits) before treating the originals as current. Fastener
lengths marked "measure before ordering" stay open until the parts are in hand.

## Printed-platform synchronization - 2026-09-15 (#1037)

The second-row CLEAR/BANK collars now use the solid version with four driver
bores in the generator, STEP/STL, printing archive and saved/reopened Fusion
models (sheet metal 160 / populated 388). All metal output bytes and all native
placements are preserved. The 134-test suite passes, followed by seven passing
mounting tests after strengthening the material probe. This update does not
clear the #1019 structural/load hold or the fabrication/fit conditions below.
See [verification](reference/solid_mid_platform_verification.json).

## Corner preparation - preceding saved state, 2026-09-15

The owner authorized preparing the welder's joint detail while Dinacut confirms
its tooling. This is a prepared design, not authorization to manufacture.
The September 14 geometry/evidence below is historical where superseded here.

The base now uses four angular corner reliefs, a nominal 0.50 mm root gap and
1.00 mm projected overlap, following the supplied joint example. These are CAD
nominals, not a new request for unusually tight shop tolerances. The rear web
widens through its upper bend to retain the complete return and lid seating.
The agreed weld scope is all four base corners, their lower relief openings and
the two upper rear-return/side joints; filler 5356 was selected by the welder.
Finish the exterior flush without thinning the sheet or weakening the joint.
The lid stays removable. No other component, fixing pattern or placement changes.

Both cloud documents are saved as **VAMP sheet metal 159 / populated 387**.
Both bases have five healthy native folds and measure **945.049614091 cm³**.
All 42 / 434 occurrence placements and unrelated body geometry, visibility and
feature health were preserved. Both saved designs were closed and reopened;
the temporary export state was discarded and the saved documents left open.
See the current [verification record](reference/welder_corner_preparation_verification.json)
for reopened geometry/flat comparisons, hashes and the remaining release holds.

The full generator and **133 tests across 15 modules pass**. The base drawing
and changed painter instructions were rendered and visually reviewed.
The mass consistency check is now 50 ppm: independent surface integration and
face/boundary comparisons qualified the small translation/integration
discrepancy on the curved reliefs. The STEP reimport is not an identical mesh. This is not a manufacturing tolerance. Solid
validity, one-body, 0.005 mm bounds, source hashes, forming data and the full
0.01 mm² flat-profile checks remain independent requirements.

Dinacut must confirm the angular reliefs, bending access/sequence and real
radius/deduction before cut approval. Any changed tooling assumption requires
rechecking and regenerating this prepared set. Fit and the nine front drilling
stations are resolved after welding and before the separate painter. The
independent **#1019 load/strength hold remains open**. Supplier confirmation
alone does not release fabrication.

## September 14 revision - historical evidence; fabrication still held

The owner authorized #1025's welded rear-corner direction and revised
manufacturing tolerances. Work starts from `43c94a27` on
`claude/sheet-metal-enclosure-analysis-6c2aa4`. Digital checks are complete; **fabrication release is not granted**. No files or messages have been sent for
this revision. The independent **#1019 structural/load hold remains open**;
the changed corner restraint and welding effects belong in that assessment.

This section supersedes the riveted process, dimensions, package counts and
release checklist in the dated history below. Earlier saved/native and test
results establish only their recorded revisions.

### Current manufacturing contract

Dinacut cuts, folds and deburrs; a separate welder joins the two rear vertical
corners. Remove both rear brackets and all ten associated base rivet holes.
Confirm weld-joint preparation and distortion control before final cutting
files. Fit and match-drill the **nine front lid/body stations after welding
and before painting**; the provider of this operation is pending. Do not add
an electronics trial, development prototype or second manufacture to the quote.

The metal package contains **five distinct parts, quantity one each**:

| Part | Material and bare thickness |
|---|---|
| Base | 1100-H14 aluminium, 2.0 mm |
| Faceplate | 1100-H14 aluminium, 2.0 mm |
| Ring disc | 1100-H14 aluminium, 2.0 mm |
| Rear panel | Aluminium, **1.2 mm**; alloy/temper to confirm |
| Support beam | Cold-rolled steel, 1.6 mm; grade to confirm |

One reviewed metal archive must contain exactly **15 files**: one STEP, DXF
and individual PDF per part, with material/thickness/quantity in filenames.
No README, supplier drafts, assembly, purchased hardware, printed parts, old
brackets or posts belong in it. Required missing, empty or stale files must
stop publication. [Supplier drafts](SHOP_REVIEW.md) stay outside the archive.

Use the separate painter for **smooth matte black RAL 9005, without texture**,
on all faces, seats, edges and clearance passages. The design allowance is
0.06–0.10 mm locally per face; protect defined electrical-bond contacts only.
After painting the owner cleans the Ø2.5 body pilots and cuts **32 M3 threads:
18 lid and 14 screen-support threads**. Shims and felt are fitted after coating.
No new holes, enlarged clearance passages or corrective seat machining are
assigned to the owner after paint.

### Fit candidates and unresolved qualification

The current rear candidate is **nine CUT slots, 10 mm along depth ×6 mm wide**,
with OD12 M3 washers; the front remains **nine Ø4.5 passages with OD7 washers**.
The rear slot calculation allows simultaneous ±2.567 mm axial and ±0.800 mm
transverse displacement, size ±0.20 mm, paint 0.10 mm per wall and 3° screw
tilt through the lid, leaving 0.317 mm radial clearance. With candidate purchased
washer OD11.8–12.2 / ID3.20–3.40 mm, the conservative narrow-side bearing bridge
is 1.80 mm and planar bearing area is at least 45.289 mm². The washer does
**not** cover the entire slot at maximum offset. These calculations do not
qualify nonparallel bearing, screw engagement or the actual purchased washer.
Resolve local metal seating/alignment before coating.

The front candidate is **1.1 mm nominal bare**, accepted at **0.70–1.50 mm
including forming and fixture errors**. Applying the coating allowance alone
gives approximately **0.357–1.488 mm** painted clearance. This is not a full
welded-assembly tolerance guarantee: verify the actual fit, wedge contact and
shim bearing. Final slot/washer specifications and shim range remain pending
that qualification.

Use a clearly identified project/shop tolerance table. The proposed custom
rows are not the ISO 2768-m table. A general ±0.20 mm laser capability does
not automatically apply to every connector, disc or purchased-hardware fit;
keep necessary functional exceptions until their complete painted and positional
budgets are checked. Statistical RSS is not a worst-case clearance guarantee.

### Current evidence and remaining gates

The saved geometry was reopened in **VAMP sheet metal 158 / populated 386**.
All changed features are healthy, all 42 / 434 final occurrence positions
survive reopening, and unrelated control-area/electronics/support positions
remain unchanged. Both bases measure **945.325929644 cm³**, both lids
**403.112692575 cm³**, and both discs **3.918822676 cm³**. Both rear bracket
pairs and ten rivet holes per base are removed. The new slots, real washer
bodies and nominal shims exist in both documents.

Reopened base/lid exports match the verified native solids at every face and
vertex (coordinates compared at 0.00001 mm). Both reopened base flats remain
below 0.000619 mm² missing / 0.000310 mm² extra; the populated lid flat has
zero missing/extra area. The source-document lid has no persistent flat;
its solid matches the populated lid. Correcting the old front-drill residue
and using slot-end datums kept the full-profile tolerance unchanged.

The full generator reports ALL PASS. **126 regressions across 14 modules
pass**, including rejected misplaced drilling, stale/partial archives and the
simultaneous slot/washer tolerance envelope. Five single-part metal PDFs were
rendered and visually reviewed. The archive contains exactly 15 STEP/DXF/PDF
files for five metal parts; material, gauge and quantity are in every name.
Timestamp-only STEP/PDF changes were restored after exact normalized comparison,
and archives were rebuilt and checked against the retained bytes. No print or
purchased-hardware references appear in the metal archive.

Detailed evidence: [digital verification](reference/welded_revision_verification.json)
and [fit calculations](../../docs/reviews/dinacut-fit-calculations.md). A digital
pass does not qualify the physical welded enclosure or the purchased joints.

Before fabrication release, resolve the post-weld fit/drilling provider,
welder preparation and distortion allowance, stock/tooling and local coating
capability, actual washer/joint and functional fits, and the independent #1019
hold. These are not authorization for another manufacturing run or a promise
that revised tolerances lower the quote.

## September 6–9 release reviews — historical evidence only

All status claims, manufacturing instructions, quantities and versions in the
following dated records apply only to those earlier revisions. The current
contract and pending gates above take precedence.

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

### Historical manufacturing contract — pre-weld revision

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
extra machining PDF page are retired. Use the plain text drilling datums and
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

### Historical release checklist — pre-weld revision

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
