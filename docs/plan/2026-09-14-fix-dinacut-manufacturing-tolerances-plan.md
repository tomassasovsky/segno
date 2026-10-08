# Dinacut fabrication scope and tolerances — #1025

Status, 2026-09-15: owner-authorized preparation of the four-corner welded
revision is digitally complete: native models 159 / 387, synchronized exports,
full generator and 133 tests passing.
Fabrication release remains separate and is not authorized.
Baseline: `claude/sheet-metal-enclosure-analysis-6c2aa4`, `43c94a27`.
The quoted revision was `c95be92b`. Do not work from master or restore that older geometry.

## Current approved scope — September 15

The owner authorized preparing the design and complete matching files now so
they can be ready when Dinacut confirms the remaining fabrication details.
This extends the September 14 rear-only design to all four base corners.
It supersedes every rear-only or front-unwelded instruction in the historical
plan below; it does not authorize cutting or supplier messages.

Matías confirmed that the four-corner work includes closing all corner reliefs
and the two indicated upper edges. The owner accepted that scope, Matías's
5356 filler selection, and an exterior flush finish without reducing the
parent-sheet thickness. Those choices are settled; do not request their
confirmation again. The lid remains removable and unwelded.

Prepare the joints from the supplied example with a 0.5 mm nominal bare gap,
1.0 mm overlap and angular relief, using Ri2 mm and K0.33 development. These
nominals describe the preparation, not a newly imposed tight shop tolerance.
The rear web is 847.821682 mm wide; the return stays 849.8 mm wide. Its width
transition belongs only within the bend band, preserving the return outside
that band. Confirm the actual formed corner geometry rather than inferring
it from the flat alone.

Current implementation sequence and acceptance:

1. Validate the changed relief and overlap with genuine native sheet-metal
   folds before updating both production components. Preserve all unrelated
   geometry, load supports, fixing stations and occurrence placements.
2. Synchronize the generator and both Fusion models; verify complete native
   flat-pattern parity, folded corner dimensions, relief closure access and
   free lid seating. Save/reopen and repeat the geometry/placement checks.
3. Regenerate and review matching STEP, DXF and individual part PDFs. Keep
   the established five-part, 15-file metal archive and exclude these internal
   notes. Record completion only from the new revision's actual evidence;
   the September 14 versions and 126-test result do not prove this revision.
4. Before cutting, obtain Dinacut's acceptance of tool access, fold sequence
   and the sharp developed profile. The approved material and filler choices
   are not reopened. Final front fitting/drilling still follows all welding
   and precedes separate coating; its provider remains to be agreed.

The separate #1019 structural hold remains open. Do not treat the accepted
welding scope or native fold success as a load qualification. Smooth matte
black coating, owner tapping after paint and the existing lid-fit/hardware
qualification requirements remain unchanged.

## September 14 planning and implementation record — historical

The dated evidence and original sequence below are retained for traceability.
They describe the two-rear-corner revision; the September 15 scope above
controls the current four-corner preparation.

Original plan review, 2026-09-14: independent simplicity, repository-conventions and
plan-splitting reviews completed with no unresolved actionable findings. The
conventions review required save/reopen verification in Fusion; task 4 and its
acceptance criterion now include it, and the reviewer confirmed resolution.
No split was recommended. The baseline generator's `_check()` geometry assertions
passed during planning; no geometry was changed and no manufacturing artifacts
were regenerated. This records the earlier riveted-plan review, not review of
the subsequent welded-corner implementation or fabrication approval.

Implementation evidence, 2026-09-14: the approved welded direction is now in
both saved/reopened models and the matching five-part archive. All 126 tests
and the full generator pass. The implemented fit candidate is rear 10×6 mm
slots / OD12 washers, disc OD50.70 / bore8.70, and front bare nominal1.10 mm
with conditional acceptance0.70–1.50 mm. The calculations below preserve their
planning history; the current source and [release review](../../hardware/enclosure/RELEASE_REVIEW.md)
record actual dimensions and remaining physical/supplier holds. Broader global
laser tolerance relaxation was not implemented because the existing connector
and insert patterns do not all support it.

## Outcome and decision

The owner approved replacing both rear corner brackets and their rivets with
welded rear corners, and synchronizing the source, Fusion models and exports.
Dinacut's reported cut-and-fold price is now close to the July price; welding
is a separate contact and cost, not included in that comparison. Obtain the
final written scope and price without promising an amount.

The process is Dinacut cut/fold/deburr, separate welding of the two rear corners,
final front drilling after welding, then the separate painter. Confirm who will
perform that drilling; returning to Dinacut is a proposal, not an agreed service.
Remove the complete prototype with electronics, repeated development trials
and dimensional-record requirements. Final shims, felt and tapping remain the
owner's assembly work; there are no rear corner brackets or rivets in this direction.

The front gap and shim range remain pending the final fit calculation. Evaluate
approximately 0.2–1.5 mm after coating instead of the old 0.50–0.60 mm bare
shop gap; neither range is a newly agreed supplier acceptance requirement.
Keep no visible faceplate screws. If the calculation needs a larger visible
gap, new owner machining, or a different fastening scheme, return that specific
result for a direction decision before adopting it. Rear slot and washer sizes
also remain candidates until the budget includes the welded assembly.

The subsequent implementation approval satisfies the handoff's #1025 plan gate
for this direction. It authorizes the CAD/source/export work and verification;
it does not authorize sending files or cutting metal. Issue #1019 still
independently blocks fabrication release. Include the changed rear-joint
restraint and welding effects in the relevant structural reassessment.

## What the evidence changes

The handoff reconciles USD 165.74 in July with USD 382.05 in September:
USD 204.93 rate increases + 7.55 disc billing error + 7.03 new post − 3.20 other
geometry changes = USD 216.31 increase. This is the supplied quote analysis,
not a newly audited invoice. A lower new price is not guaranteed.

The baseline `hardware/enclosure/SHOP_REVIEW.md` contained the expensive scope:
prototype, trial development, presentation with pedals and screens, tight
centering/gaps, transfer drilling, matched delivery, and a dimensional record.
Baseline DXF notes repeat those operations. Merely deleting the PDF tolerance block would
not remove this work or make the existing round holes align.

Current branch corrections:

- The floor now has three rows of PETG/neoprene rails, and one full-width 1.6 mm
  steel beam replaces seven posts. Preserve these changes and their floor/side
  fixings. The reported old 360 N result is not a rating of this current geometry.
- Active 2.0 mm material identification is already 1100-H14. The 1.2 mm rear
  panel's alloy/temper remains unconfirmed. Active supplier messages must match
  the beam and welded corners; obsolete post and rivet instructions are removed.
- Current drawings specify ±0.5° bends. ±1° is a proposed relaxation to evaluate.
- The suggested 4.5 × 7.0 mm rear slot with a Ø9 washer is not verified. At
  1.83 mm screw displacement its far end is 5.33 mm from the screw center, outside
  the washer's 4.5 mm radius. Full coverage and adequate clamping are separate
  requirements; neither follows from the washer's name alone.

Read-only calculations on the baseline formed STEP, holding the floor and main
lid plane nominal, project three independent ±1° fold errors onto the rear lap:
1.3986, 0.1047 and 0.06981 mm/degree. Their finite corner envelope is
−1.5885…+1.5610 mm, before cut position, development, coating and assembly
restraint variations. This does not reproduce the handoff's 1.83 mm RSS.
Statistical RSS is not a worst-case fit guarantee for one enclosure; use bounded
stack-up first. [Autodesk's tolerance-analysis explanation](https://help.autodesk.com/cloudhelp/2027/ENU/INVTOL/files/GUID-2950624D-0A05-47E7-B207-97FC55C5D327.htm)
distinguishes those methods.

For illustration, a minimum 4.5 × 7.0 bare slot painted 0.10 mm per wall has
4.30 × 6.80 mm clear opening. M3 travel is ±1.90 mm only on its centerline;
at 0.45 mm transverse offset it falls to ±1.719 mm. Existing coating-seat motion
adds −0.17766…+0.07076 mm. These are screening calculations, not final dimensions.
There is local room to investigate a Ø12 washer, but its bore, thickness, grip,
thread engagement, neighboring hardware and angular seating need verification.
These calculations predate the welded-corner direction and do not include a
confirmed welding-distortion allowance.

The proposed tolerance rows also are not ISO 2768-m. For example, that class's
general linear limits above 400 through 1000 mm are ±0.8 mm, rather than the
suggested hole-position ±0.4 or flat-outer ±0.3. It is not a datum-based position
specification. Prefer a clearly named project/shop tolerance table with explicit
definitions instead of an inaccurate blanket standard label.
[ISO scope](https://www.iso.org/obp/ui/?_escaped_fragment_=iso:std:7748:en),
[published ISO 2768-1 table](https://www.eurotools.eu/sub/eurotools.eu/images/downloads/General_Tolerance_Standard_ISO-2768-1pdf.pdf?17247513=).

## Implementation sequence

### 1. Establish one manufacturing allowance and fit budget

Use `hardware/enclosure/segno_enclosure.py`,
`tests/test_manufacturing_fit.py`, `hardware/MANUFACTURING.md`, and
`hardware/enclosure/HANDOFF_1019.md` as the starting evidence. Record the exact
baseline revision and current native manifest; inspect both Fusion documents
before changing them. Reuse existing CAD, coating and test helpers.

Prepare a short, bare-metal project tolerance table for the shop to confirm:

| Feature | Candidate allowance to analyze |
| --- | --- |
| Laser hole/slot size and disc outline | ±0.20 mm; confirm applicability beyond the disc discussed in the audio |
| Hole-center coordinates from stated datums | ±0.20 mm through 400 mm; ±0.40 mm above 400 mm |
| Flat outer dimensions | ±0.30 mm through 1000 mm; ±0.50 mm above 1000 mm |
| Bend angle | ±1.0° |
| Dimension from one bend | ±0.30 mm |
| Dimension across two or more bends | ±0.80 mm |

Define each measurement datum and how tolerances apply; do not add a coordinate
and center-distance allowance twice for the same error. Distinguish general
outer dimensions from the disc's individually toleranced functional diameter.
These are design inputs for review with Dinacut, not claimed shop commitments.
Request actual die opening, inside radius and bend deduction for each material
and thickness before freezing developments. The existing K=0.33 / Ri=2.0 mm
aluminum assumptions are not proven by "the radius is okay." For steel, use
the beam's own radius and bend sequence. Price any unavoidable tighter feature
separately; do not reintroduce a blanket precision requirement.

Build bounded fit budgets for the full assembly: actual screw axes intersecting
both lap surfaces, laser position/size, bends, sheet thickness, development,
weld distortion, flatness, coating, washer float and allowed rigid assembly
movement. Define
restraints/contact assumptions explicitly. Evaluate a common assembly pose for
all nine rear and nine front stations, including the ends of the wide enclosure;
independently centering each hole is not a fit proof. Use analytical bounds or
an extremum search justified for the geometry, not random samples alone.

Evaluate every interface whose assumptions change with the new table: complete
M3/M4 patterns, rails and beam connections, welded corners, screens, rear
connectors,
disc/printed pocket/encoder washer, and front shims. With unchanged nominals,
±0.20 mm size plus 60–100 µm coating can reduce a CTRL/fuse opening to 11.90 mm
against a modeled Ø12 requirement, and reduce the disc's pocket clearance to
0.05 mm radially before print variation. The PD web can fall below its existing
1.20 mm minimum. Those conflicts require geometry or a justified specific
allowance, not a note deletion. Include PETG print variation and purchased-part
dimensions in the applicable budgets; leave unsupported dimensions visibly open.

### 2. Change the minimum geometry needed to fit

Depends on task 1 establishing a feasible budget.

- Rear lap: replace the nine faceplate DRILL circles at `SEAM_LAP_V` with CUT
  stadium slots along the **local lap depth direction**. Select the final slot
  size and dimensioned washer together from the budget, rather than freezing
  4.5 × 7.0 / Ø9 now. Check coated travel in both directions simultaneously,
  washer bearing and desired coverage, head seating, end ligaments, screw
  length/thread engagement, access, bend-tool clearance and every neighbor.
  Keep the rear base pilots on CUT if the resulting geometry remains outside
  the confirmed tooling's deformation zone. If slots cannot absorb the agreed
  envelope without forcing the lap, redesign that interface before deleting its
  fitting instruction. A slot does not correct nonparallel seating surfaces.
- Front: retain nine final drilling stations after folding and rear welding:
  nine Ø2.5 base pilots plus nine lid
  clearances, sized from the revised fit budget. The current 3.38 mm land is
  inside the proposed V12 tooling region. Describe this as one limited
  front drilling operation after welding and before painting, with temporary
  lid/body alignment as necessary,
  not "no matching whatsoever." Price it explicitly. A shop jig or transfer
  process must preserve the validated assembly pose without pedals/screens.
  Confirm the provider before promising this operation in the order.
- Rear/side corners: remove both brackets, their rivets and attachment holes
  from source, Fusion models, BOMs and exports. Replace only the two rear
  vertical corner joints with welded joints; keep the front and removable lid
  unwelded. Remove the old 0.00–0.10 mm dry-joint acceptance ceiling. Confirm
  joint preparation, access and distortion control with the separate welder
  before freezing the cut development. Do not invent a weld size, process,
  filler or gap, and do not treat the old 0.05 mm nominal gap as an approved
  welding requirement. Preserve bend relief and verify the rear flap clears
  the finished weld and the lid seats without forced walls.
- Front lip: prove the proposed finished-gap target across coating, seating and
  folds. Adjust nominal clearance only as needed to make assembly feasible;
  choose solid shims from the measured finished gap. No deformation of the
  walls or new owner hole relocation is an assumed adjustment method. Confirm
  that shims and available screws work throughout the resulting range.
- Disc/connectors/other affected fits: adjust only the interfaces that fail
  task 1; preserve purchased hardware and functional minimum lands. If the
  disc's metal dimensions can solve its fit, leave the printed pocket alone.
  Otherwise identify any affected first-print file before changing it.

Update the shared generator geometry and dimensions, assembly hardware/BOM,
applicable printed mating parts, and both Fusion documents together. Preserve
the beam, three rail rows, vents, pedal/screen placements and existing load path.
If a required fit correction changes structural geometry, rerun the relevant
#1019 analysis; a tolerance-cost change must not silently invalidate that work.

### 3. Replace conflicting process instructions

Depends on the demonstrated fit in task 2.

Update `TOLERANCE_ROWS`, per-part DXF/PDF notes, `SHOP_REVIEW.md`,
`hardware/MANUFACTURING.md`, and current instructions in `FUSION_MODELS.md`.
Keep historical review evidence dated; do not rewrite previous results as new
verification. Replace active references to posts and obsolete hole/gap limits.

The Dinacut draft must say: one set, correct materials/thicknesses/quantities,
cut CUT/VENT only, BEND reference only, deburr without chamfering and deliver
untapped. Its scope is cutting and folding; welding is a separate provider.
The front DRILL operation follows welding and precedes painting, with its
provider and price still to be confirmed. Remove requirements for
a full prototype with components, a repeated complete set, rear transfer-punch
fitting, a dimensional record, and precision joint shimming by the shop. Request
any additional fitting as a separate hourly line. Keep essential dimensions and
minimum material lands explicit without contradictory override prose.

The separate welder joins the two rear corners before final front drilling and
painting. The owner selects shims/felt after coating and cleans/taps the
existing M3 pilots after
paint as already authorized. No extra cutting, relocating or enlarging clearance
holes after painting is planned. Keep smooth matte black RAL 9005, no texture,
and the existing full-coating fit basis. Remove stale finished dimensions from
the painter draft until the revised fit calculation establishes them.
Coupon/physical fit checks needed for qualification remain owner
validation, rather than an unpriced complete assembly operation at Dinacut.

### 4. Synchronize and verify a sheet-metal-only draft package

Depends on tasks 2–3. Deliver one coherent revision; do not hand off notes that
describe slots while the attached STEP or DXF still contains round holes.

- Make the rear panel's **1.2 mm** thickness unmistakable in its part filename,
  drawing and order quantity. Confirm its alloy/temper separately from the
  certified 2.0 mm 1100-H14 stock. State the actual beam steel specification.
- Remove both obsolete rear bracket parts and their rivets from the current
  fabrication and painting lists. Retire their flat and formed deliverables;
  native provenance and package checks must describe the current part set.
- Set real DXF modelspace extents using existing ezdxf facilities. Compute
  rectangular blank dimensions from manufacturing contours separately from
  annotation extents, so text cannot enlarge the quoted blank. Verify the
  disc's billed dimensions use its diameter, not circumference.
- Create one fabrication archive with the current sheet-metal STEP, DXF and
  individual part PDFs requested in this handoff. Include the new beam for an
  explicit quote. Exclude printed parts, purchased hardware, obsolete brackets
  and posts,
  populated assembly exports, README/message files and unrelated PDFs. Keep
  `SHOP_REVIEW.md` as a draft outside that archive. Retire superseded duplicate
  fabrication archives in the package writer; preserve the separate print and
  painting deliverables. The previous July files are not a geometry baseline.
- Use the existing formed-export sequence: `segno_enclosure.py --no-step`,
  update both Fusion documents, run `fusion_export_formed.py` inside Fusion
  with the populated document active, then the full generator. Preserve the
  native freshness/manifest gate. Verify real cuts and bodies, not bounding
  boxes alone. Save and reopen both Fusion documents, then re-query actual
  geometry, occurrence placements and native-flat parity. Record the reopened
  document identities/versions; transient in-memory checks are not persistence
  evidence.
- Compare regenerated DXF geometry against the baseline; restore only unrelated
  timestamp/GUID noise. Keep genuine dimensional changes and their matching
  native manifests. Do not stage unrelated work or blindly stage ignored
  `_*.py` files. Prefer extending the existing test modules.

## Verification and acceptance

Run from `hardware/enclosure/` with the project's existing CAD Python environment
active. Worktree test discovery needs explicit module names. These are future
implementation acceptance commands, not claims of tests run for this plan.

```success-criteria
GOAL: Produce a coherent enclosure package with welded rear corners, agreed fabrication allowances and final front drilling after welding and before painting.

SUCCESS CRITERIA:
- A common assembly pose accepts all front/rear screws, with coating, washer bearing and access, without forced walls; the revised disc, connectors, shims and mount patterns retain their required fit/lands throughout the declared bounds. | verify: python -m unittest tests.test_manufacturing_fit
- Adopted rear slots are actual closed through-cuts; front DRILL remains reference-only; removed corner brackets, rivets and their attachment holes are absent from the current geometry and package; every native flat matches its generator counterpart; the archive contains only current sheet-metal DXF/STEP/part-PDF files with unambiguous quantity, thickness and finite extents. Stale or missing exports block archive replacement. | verify: python -m unittest tests.test_manufacturing_pipeline
- Existing rail, beam, screen, pedal and sled behavior remains valid; any change to structural assumptions has a corresponding updated #1019 assessment. | verify: python -m unittest tests.test_coated_supports tests.test_floor_rails tests.test_floor_supports tests.test_lid_prop tests.test_mid_platform_mount tests.test_mini_sled_retention tests.test_platform_baffles tests.test_screen7_adjustment
- A complete generation passes its geometry/export checks. | verify: python segno_enclosure.py --report && python segno_enclosure.py
- Both saved Fusion documents show the same revised metal geometry and hardware placement as the generated exports, with real bodies and cuts and healthy bends after reopening. | verify: manual save and reopen both documents; re-query geometry, through-cuts, placements and native-flat parity; verify provenance and record the reopened versions in the release review.
- Supplier-facing notes and the revised quote agree on one set, materials, ordinary tolerances, Dinacut cut/fold/deburr, a separate welder for the two rear corners, final front drilling after welding and before separate painting, no threading/riveting, a separately priced beam and optional additional fitting; the rear-panel thickness and disc billing are corrected. | verify: manual compare the final manifest and short drafts against the returned scopes/prices and shop tooling/tolerance confirmation; confirm the drilling provider and weld preparation.
- Finished assembly accepts hardware and opens/reseats without forced walls, paint removal at supports, or unplanned owner machining. | verify: manual assemble the actual coated parts with hardware and selected shims; record fit before declaring production validation complete.

NON-GOALS:
- Authorize cutting, contact suppliers, promise a quote amount, or close #1019's structural/release gate.
- Weld the front or removable lid, change the finish, expose faceplate screws, or redesign the existing load-support scheme.
- Demand a second complete prototype or component-fit service as part of the ordinary cutting quote.

VERIFICATION COMMAND: python -m unittest tests.test_manufacturing_fit tests.test_manufacturing_pipeline tests.test_coated_supports tests.test_floor_rails tests.test_floor_supports tests.test_lid_prop tests.test_mid_platform_mount tests.test_mini_sled_retention tests.test_platform_baffles tests.test_screen7_adjustment && python segno_enclosure.py --report && python segno_enclosure.py
```

Extend these tests to evaluate the new allowance envelope and failure cases;
passing the old tighter-envelope tests is not sufficient. Inspect the generated
part PDFs visually after changes. Physical validation follows authorized
fabrication; distinguish "ready to request a revised quote" from "built and fit
verified." Cost success is a returned quote that removes the repeated-fit
premium and explains the current beam cost, not an assumed return to July rates.

## Delivery and remaining dependencies

Keep this as one coordinated manufacturing change under the current approval.
Calculations, fit geometry, process notes, native exports and package selection depend on one
another; intermediate output must remain internal. Package hygiene can be
reviewed independently within the change but does not justify issuing mixed
revisions. Record the final current-state evidence in `RELEASE_REVIEW.md` and
link this plan in the #1025 tracking workflow when implementation lands.

Unresolved dependencies are Dinacut's agreed tolerances/tooling and 1.2 mm
material; the welder's joint preparation, distortion allowance and price; the
provider for final front drilling; final slot/washer dimensions and front-gap/
shim range; separate coating and physical fit checks; and #1019. The welded
corner direction is approved; its fabrication details are not established by
that approval. This planning document does not itself certify a manufacturing
revision as ready for cutting.
