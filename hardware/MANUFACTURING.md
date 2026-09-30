# Segno console — manufacturing package

Current revision: 2026-09-30 integration of #1088 (base, rear I/O in the wall,
power group, rail prints), #1070 (screen mounts) and the #1075 console strip
ring. The digital preparation is complete and matches the parts the owner has
already printed: the mirrored 15.6-inch stands, the closed-deck 7-inch tower
(no reprint: the ring moved down the slope instead, #1090), the 2.4 mm-wall front collars, the solid
CLEAR/BANK collars and the tall eight-LED pills of #1074 (PR #1084).

Matías welds all four base corners and closes all corner reliefs, including the
two indicated upper edges, with his chosen 5356 filler. There is no spot
welding anywhere. Exterior welds finish flush without thinning the parent sheet.

The populated Fusion clone ("VAMP console (populated) - 1067 tabs + seat
flanges") holds this revision; the full generator and 154 enclosure tests pass
against its formed base. Fabrication release remains on hold for Dinacut's
tooling acceptance and the independent #1019 structural/load assessment. Use
[the release review](enclosure/RELEASE_REVIEW.md) for the evidence and the
open items.

[Internal supplier drafts](enclosure/SHOP_REVIEW.md) cover Dinacut, a separate
welder and a separate painter. Dinacut drills every deferred hole after folding
and before welding (owner call 2026-09-30, #1090). No supplier message or cutting authorization is implied here.

CAD, drawings and vendor archives come from
[segno_enclosure.py](enclosure/segno_enclosure.py). For an authorized order,
regenerate and verify the complete package, then freeze the exact files sent
in the order's release record. ZIPs are generated artifacts, not tracked source.
A partial run retains earlier metal archives; those are not the new revision.

## 1. Metal fabrication and separate finishing

The metal handoff is **one `enclosure/out/segno_sheetmetal.zip`**, containing
exactly **12 files: STEP, DXF and individual PDF for each of four parts**.
Shipping filenames include material, bare thickness and quantity. They retain
these canonical part stems:

| Part | Qty | Material | Notes |
|---|---|---|---|
| `segno_base` | 1 | 2.0 mm 1100-H14 aluminium | One folded blank; weld all four corners and close all corner reliefs, including the two indicated upper edges, after forming. Every rear connector is cut straight into its rear wall (#1088). |
| `segno_faceplate` | 1 | 2.0 mm 1100-H14 aluminium | Removable sloped lid, 853.8 mm wide (2 mm past each side wall) along the slope; over the last 40 mm before the rear bend it narrows to 849.8 mm, so the rear lap is flush with the rear wall. Nine front clearances (laser pilot, drilled out after folding) and nine rear CUT slots. |
| `segno_ring_disc` | 1 | 2.0 mm 1100-H14 aluminium | Flat encoder disc; straight laser bore, no chamfer. |
| `segno_beam` | 1 | **1.6 mm cold-rolled steel** | Full-width support beam, seven floor fixings; grade to confirm. Fold both wall ears before the long folds. The ears are unbolted locators: no hole in them or in the side walls (#1090). |

`PART_SPECS` supplies these quantities and materials to the drawings and
archive manifest. The 2.0 mm material identification follows the Alcast
1100-H14 certificate, lot 26E0269; confirm the job stock. The certificate does
not identify the steel grade. There is no separate rear I/O panel since #1088.

There are no rear corner brackets or their ten base rivet holes. The metal
archive excludes assembly, README, drafts, purchased hardware, printed parts
and removed brackets/posts. Purchased shims and front/rear washer references
remain internal assembly aids. Labels stay on individual pedal tiles.

### Work sequence

1. **Dinacut:** cut, fold, drill and deburr, without chamfering, tapping or
   painting. The nine front stations on the lid and on the body are cut as
   Ø1.0 laser pilots only, because they sit inside the V12 die zone and a
   full-size hole would distort in the fold. After folding, and before the base
   goes to the welder, drill them out to Ø2.5 (body) and Ø4.5 (lid).
   Confirm stock, tool access, inside radii and bend development before final
   files. The source uses K=0.33, R2 for aluminium and R1.6 for the steel beam;
   follow each part's fold order and drawn-face orientation. Confirm tool access,
   fold sequence and the sharp developed profile of the revised angular corner
   reliefs before cutting. Preserve the #1019 beam, rails, prop and fixing layout.
2. **Matías, separate welder:** weld all four base corners and close all their
   reliefs, including the two indicated upper edges, using the accepted 5356
   filler. Finish the exterior flush without reducing parent-sheet thickness;
   retain squareness and free lid seating. The lid remains removable and is
   not welded. The former 0.00–0.10 mm riveted-seam requirement is retired.
   This accepted scope does not constitute a qualified weld procedure or load
   assessment.
3. **Bare fit check after welding (owner, before paint):** seat the lid
   freely on the welded base and check face alignment, the 0.70–1.50 mm front
   gap and that all nine front screws start without forcing. Correct the metal
   before coating; nothing is drilled at this step. Run the #1019 first-article
   proof test (release review) at the same time.
4. **Separate painter:** coat the welded base and the other parts separately,
   smooth matte black RAL 9005, without texture. Coat all faces, seats, edges,
   holes and slots, with 0.06–0.10 mm local film per face. Protect only identified
   electrical-bond contacts. Remove electronics, printed parts, shims, felt and
   adhesives before treatment.
5. **Owner after coating:** clean paint-narrowed body pilots back to their
   existing Ø2.5 metal bore without moving the axes, then tap **32 M3 threads:
   18 lid and 14 screen-support threads**. Fit shims, felt and hardware to the
   measured coated assembly. No new drilling, clearance enlargement or
   corrective seat machining is planned after paint.

### Four-corner preparation being synchronized

Follow the supplied joint example: 0.5 mm nominal bare joint gap, 1.0 mm overlap
and angular corner relief, developed with Ri2 mm and K0.33. These are joint
geometry targets, not a new tight production tolerance. The rear web width is
847.821682 mm; the return width remains 849.8 mm. Confine their transition to
the bend band, retaining the return's full width outside that band. Verify the
actual folded result and lid seating in both native models and the resulting
flat-pattern parity; a nominal sketch alone does not establish the preparation.

The welding scope and filler choice are settled. Dinacut's acceptance of tool
access, fold sequence and the sharp developed profile remains pending before
cutting. Do not issue the previous two-corner archive as this four-corner revision.

### Drawings and tolerances

Shop-facing instructions and title blocks are Spanish. Part stems and layer
names remain the identifiers used in the matching files. `CUT` and `VENT` both
cut through; the floor has no vents, while side/rear openings remain. `DRILL`
is the finished diameter, drilled after folding and before welding; the laser
cuts only the Ø1.0 pilot at the same centre, on `CUT`. `BEND` is reference only: do not
cut, score or engrave it. `MASK` identifies electrical-bond coating protection,
never a cutting contour.

The **currently implemented** general block is a project table, not an
ISO 2768-m designation: hole position ±0.15 mm, hole diameter ±0.10 mm, round
M3/M4/floor/front-lid clearances +0.10/−0.00 mm, bend angle ±1°, flat exterior
size ±0.30 mm and dimensions across one fold ±0.50 mm. Specific callouts below
control where they differ. A proposed general laser capability of ±0.20 mm
has not been applied indiscriminately to connector and mounting fits.

### Lid fit and front drilling

The source uses **1.10 mm nominal bare front clearance**. The **0.70–1.50 mm
bare acceptance band is measured after welding and any metal correction**;
it includes forming/fixture effects and is not guaranteed by generic bend
limits. Check one common, freely seated lid pose across all nine stations.
Correct face alignment before coating: parallel shim packs cannot correct a
wedge between the lip and wall.

Only the **nine front lid clearances and nine matching body pilots** are
`DRILL`. Each has a Ø1.0 laser pilot on `CUT` at its centre; the drawing
stations (A at the bare floor underside, B at the bare left-wall interior) are
for checking. Nominal front axis height is 6.455 mm above A. After folding and
before welding, drill the body pilots out to Ø2.5 and the lid's nine front
passages to **Ø4.50 +0.10/−0.00**. The parts are drilled separately, not as a
fitted pair: the Ø4.5 clearance on an M3 leaves 0.75 mm of float for the fold
and weld stack.
Leave all body pilots untapped. The nine rear body pilots remain CUT; the
lid's rear openings are **10 ×6 mm CUT slots, length along lap depth**, each
dimension ±0.20 mm. Do not transfer-drill the retired rear round-hole pattern.

Use nine front M3 OD7 washers. The rear reference is nine **OD12 / ID3.2 /
1.0 mm M3 washers**, with procurement limits and actual seating still to
confirm. The [fit calculation](../docs/reviews/dinacut-fit-calculations.md)
checks slot passage under simultaneous axial/transverse offsets and coating;
it does not qualify angular washer bearing, clamp torque or screw engagement.
The rear washer may leave part of the slot visible. Verify the actual bearing
and lid removal before releasing this fastening detail.

From the accepted bare band, coating alone predicts **0.357–1.488 mm** front
shim space. Fit nine deburred solid stainless packs, OD6.90–7.00 / ID4.0–4.2 mm,
to the actual cured gaps without pulling the faces together. The nominal
1.10 mm STEP pack is not an order thickness. Verify bearing and parallelism,
number packs 1–9 and retain only outside their bearing faces and bores. Fit
felt/seals to measured gaps without lifting the lid off its seats. No shim or
adhesive enters the coating oven.

### Functional openings

All dimensions are mm. Finished ranges assume the stated local film on each
opposed wall. They do not establish positional fit of a complete screw pattern.
Keep connector centres and purchased fixing pitches fixed. Retained functional callouts override the general block.

| Opening | Before painting | Predicted finished range |
|---|---:|---:|
| Metal M3 clearances, except front lid | Ø3.60 +0.10/−0.00 | Ø3.40–3.58 |
| Nine front lid clearances | Ø4.50 +0.10/−0.00 | Ø4.30–4.48 |
| Nine rear lid slots, length ×width | 10.00 ×6.00, each ±0.20 | 9.60–10.08 ×5.60–6.08 |
| Metal M4 clearances | Ø4.60 +0.10/−0.00 | Ø4.40–4.58 |
| Ø4.80 floor clearances where called out | Ø4.80 +0.10/−0.00 | Ø4.60–4.78 |
| Pill lens apertures | 60.40 ×6.40, R3.20; +0.10/−0.00 | 60.20–60.38 ×6.20–6.38 |
| Ring lens aperture | Ø67.40 +0.10/−0.00 | Ø67.20–67.38 |
| Selected fuse | Ø12.30 ±0.10 | Ø12.00–12.28 |
| Power switch | Ø19.80 ±0.10 | Ø19.50–19.78 |
| MIDI NYS325 | Ø15.50 +0.10/−0.00 | Ø15.30–15.48 |
| PD coupler and two CTRL D-flange sockets | Ø24.40 +0.10/−0.00 | Ø24.20–24.38 |
| USB four flats | 22.80 ×22.80 ±0.10 | 22.50–22.78 across each pair |
| Same USB concentric circle | Ø24.80 ±0.10 | Ø24.50–24.78 |
| Disc outside diameter | Ø50.70 ±0.20 | Ø50.62–51.10 |
| Disc straight bore | Ø8.70 ±0.20 | Ø8.30–8.78 |

The USB contour is the intersection of the four flats and concentric circle.
PD/CTRL/MIDI local ligaments must measure at least **1.20 mm bare**, including
actual hole-position error; qualify the complete barrel/fixing pattern and local
cutting process on the 2.0 mm rear wall. Check these connector fits with the
actual parts and a representative painted coupon. This is not an
electronics-equipped enclosure trial.

All connectors are cut straight into the 2.0 mm rear wall (#1088); there is no
separate I/O panel. The two CTRL jacks stay Neutrik NJ6FD-V, each fitted in the
D-size zinc flange plate from the MEIRIYFA listing (Amazon B0G5FZNH49): Ø24
hole, flange 26 × 31 mm, two Ø3.4 fixings at ±9.5 / ±12 mm, top-left and
bottom-right seen from the front. The wall is cut to that diagonal, and the PD
coupler takes the same one (owner check against the part, 2026-09-30). The plate screws on from outside, so
the 2.0 mm wall does not limit the NJ6FD-V's 1.20–1.50 mm clamp range.
Verify the selected power/fuse hardware and all complete M3/M4 mounting
patterns after coating; a screw fitting one bare hole is insufficient.

The disc is laser-cut and deburred without a chamfer, coated on every surface;
its bore centre has ±0.20 mm X/Y tolerance relative to the outside-circle
centre. The owner's EC11 washer measures ID7.25 / OD11.85 mm. Let the disc
settle in the printed holder before tightening the original washer/nut, and
verify actual printed clearance, retention, push-button action and knob rotation.
The bore is a clearance fit, not a locating feature.

The steel beam retains its 1.2 mm nominal normal bare lid gap, seven
depth-slotted floor fixings (one per interior pedal gap, #1088). Its two wall
ears are unbolted locators (#1090): no screw heads on the side walls.
Fit it after separate coating, then select felt from the measured finished gap.
Preserve the #1019 rails, central prop and support heights; earlier numerical
load estimates are not a rating of the current welded assembly.

### Digital package checks

Follow [FUSION_MODELS.md](enclosure/FUSION_MODELS.md) for both native documents.
Base and lid formed exports must match the current complete CUT/VENT/DRILL
geometry, with saved/reopened geometry and occurrence checks. The beam, rear
panel and disc also need source/native agreement. Run the full generator and
applicable tests, inspect changed PDFs, and verify exact archive membership
and file contents before recording completion. The packager requires both
STEP and PDF output and rejects missing, empty or stale artifacts; failed
staging preserves the previous archive. Old metal archives are retired only
after the complete replacement succeeds.

`segno_assembly.step` and purchased shim/front-washer/rear-washer STEPs are
internal references. Printing, pedal-tile and painting archives remain separate.
The painter's handoff is `enclosure/out/segno_pintura.zip`; do not send a closed
assembly to the coating process. Digital checks do not release the outstanding
stock/tooling, welded-fit, coating, hardware or #1019 structural gates.

## 2. 3D printing (FDM)

Send **`enclosure/out/segno_3dprint.zip`** (STEP + STL for each part).

The fully coated console uses 0.15 mm normal relief on the collar hard rims
and the sled's outer rim, plus 0.20 mm additional screen setback. Floor fixing
axes remain fixed. Print the revised collars and matching sled variants,
seven-inch tower and both large-screen stands from one matching revision;
previous bare-fit prints are
not qualified against the newly coated seats. The separate mini-console is
unchanged by these console paint allowances.

**Every printed part is BLACK PETG at ≥40% infill.** One filament, so a reprint of any part matches the rest; ASA is no longer offered as an alternative. Three parts are exceptions and all three are optical, not a second material preference: the ten pedal-LED diffusers and the encoder ring diffuser are WHITE translucent because they are the lenses the LEDs shine through, and the ten pedal tiles are a black body with white lettering printed in one filament change, because an all-black tile has no legend.

| Part | Qty | Material | Notes |
|---|---|---|---|
| `segno_platform_front_ring` | 8 | **BLACK PETG**, ≥40% infill | Front-row collar, paired with the separate sled below. Four chassis screws clamp collar, sled and base together. |
| `segno_platform_mid_ring` | 2 | **BLACK PETG**, ≥40% infill | Taller CLEAR/BANK collar. Four bottom inserts anchor it to the base; four separate deck screws retain its dedicated mid sled. |
| `segno_platform_sled` | 8 | **BLACK PETG**, ≥40% infill | Front-row sled. Bolt the pedal to it on the bench, then lower the complete unit into the front collar. |
| `segno_platform_mid_sled` | 2 | **BLACK PETG**, ≥40% infill | CLEAR/BANK sled with a separate 60 ×36 mm lower insert pattern; use only with the matching short-screw mid collar. |
| `tall_pill_base` + `tall_pill_diffuser` (#1074, PR #1084, `hardware/pill_light_mask/`) | 10 each | carrier **BLACK PLA**, lens **WHITE PLA** | The pill diffusers the owner printed: an eight-LED 144/m strip on a full 2 mm glue bed, 5 mm of air, a 0.8 mm white roof. The lens nose enters the unchanged 60 × 6 mm faceplate slot from inside and ends flush; four 0.2 mm pads set the glue line under the sheet; the carrier reaches 8.13 mm below the sheet underside. Checked in the populated Fusion clone at all ten stations: nothing touches the beam, its felt or the collars. Remove the temporary bench collar before fitting under the metal. The older `segno_led_diffuser` is superseded; do not mix parts from the two sets. |
| `segno_pedal_tile_*` | 10 | **BLACK PETG body + WHITE lettering**, one filament change (exception to the all-black rule: an all-black tile has no legend) | Pedal name tiles, one per pedal, dropping into the WTB-006 top pad's window. **TRAPEZOID**, 54.36 (back) / 53.76 (toe) × 19.90 × 2.20 — the pad is a wedge in plan, and the window keeps a 5 mm wall each side at every station, so the tile's sides run parallel to the pad's. Both widths are derived from the pad measured in the Cherub Fusion doc (window 54.46 / 53.86, less 0.05/side). **Fit the WIDE edge toward the cable end**; it carries the top of the glyphs, so the wrong way round reads upside down. The pad is a uniform 2.2 slab on a case top tilted to match, so the window is a parallel-sided pocket in depth and the tile is flat in Z. **Print FACE-DOWN with a filament change at z = 0.4**: the glyphs stand proud of the body, so face-down they are the first 0.4 mm off the bed — print that in white, swap to black, flip. One extruder. The letters finish flush with the pad and the black field sits 0.4 mm below it, out of the scuff line. Text is generated from the same `PEDALS`/`SILK_SYMBOLS` pedal-label schedule, so REC/PLAY and STOP carry the dot+plus+triangle and square rather than words. |
| `segno_floor_rail_front_a_*` / `segno_floor_rail_front_b_*` | 8 | **BLACK PETG**, ≥40% infill | Front floor rails (issue #1019), 201.79 mm, four screws. **Every segment of a rail is the same part** — eight of this one; the rear rail has two exceptions, below — because the rail span comes from the pedal pitch, so each segment is exactly two pedals wide and the screw pattern repeats. **Print flat, channel side up**: the channel needs no support and the floor face is the bed face. Each carries a 19.05 × 3.2 mm self-adhesive SOLID neoprene strip (3/4" × 1/8") pressed into its 18.85 × 1.5 mm channel — 0.2 mm under size on purpose, so the walls hold it and the adhesive is not in the load path. **Not grit tape**: this gets dragged across floors. The strip stands 1.7 mm proud and is the only thing touching the ground. Ends are **square** with a 1 mm corner break and the segments **butt**, so the strip is a plain scissors cut that fills the channel corner to corner. **Fit the rails first, then press the strip in** — the M3 heads sink into counterbores inside the PETG, above the channel roof, so the strip runs over them unbroken and never needs punching. 2,385 mm of strip for the set. |
| `segno_floor_rail_rear_1` / `_4` | 2 | as above | Rear floor rails, 201.79 mm, two screws at 64.75 and 110.75 mm from the low-u end, so both go on the same way round. The rail sits at v 343.25; at 21 mm wide it clears the screen-stand pilots by 3.5 mm each side. |
| `segno_floor_rail_rear_2` / `_3` | 1 each | as above | **Their own prints** (#1088): the power group stands on the rail between them. Segment 2 has its screws at 21.75 and 64.75 mm from the low-u end, ahead of BUCK_AUX, and three blind Ø8.4 × 2.6 mm pockets in its floor face at 91.24, 145.14 and 162.94 mm; segment 3 keeps the standard screws and has one pocket at 14.55 mm. The pockets take the buck bolts' M4 button heads. **Bolt the bucks before fitting these two segments**, heads from below. Print floor face down, like the others; the pockets need no support. |
| `segno_lid_prop` | 1 | **BLACK PETG**, ≥40% infill | Mid-field lid prop (issue #1019). A pure compression column, which is why it is printed rather than another shop part number. It stands in the one clear lane between BANK's pedestal and the 16in module body — 31.5 mm wide, so the 24 mm column has 3.7 mm each side and there is no room to improvise on the bench. Two M4 into the floor through the tongue; the top face is already cut to the 12.5° slope, so print it **tongue-down, flat on the bed** and let the sloped face be the top surface. Fit felt on that face to the measured gap after coating, the same rule as the steel beam. Its load qualification remains part of the independent #1019 hold. |
| `segno_ring_diffuser` | 1 | **WHITE translucent** (exception to the all-black rule: it is a lens) | Ø67-window lens and disc holder for the selected PR #990 Ring 24 on its 2.54 mm pin strip. The open-bottom cavity has eight 1.2 mm ribs in verified component gaps, a 0.25 mm shelf and a 1.05 mm lens roof. Nominal minimum PCB clearance is **0.135 mm**, LED clearance 0.332 mm; qualify one actual print and its light diffusion before ordering a set. Orient and dry-fit it as described below before gluing. |
| `console_ring_{diffuser,cup,encoder_retainer,encoder_spacer,centre_cap}` (#1075, `hardware/strip_ring/out_console/`) | 1 each | diffuser and cup **WHITE PLA**, the rest **BLACK** | **Alternative to `segno_ring_diffuser`, pending the owner's bench light test** of the strip ring. A 34-LED strip on the cup wall, LEDs facing in; the cup's roof is glued to the faceplate underside and the lens sits flush in the unchanged Ø67 window. Three snap arms on the cup click under the Ø80 carrier's edge (0.3 mm play; the encoder nut still sets its height), so the carrier needs no screws (#1090). The v3 carrier hangs 7 mm deeper than with the Ring 24 (J3 unfitted, strip on J2); since the ring moved to v 215.0 (#1090) it clears the printed 7-inch tower with 1.5 mm of air. Its printed centre cap replaces the aluminium `segno_ring_disc`, so **do not order the disc if this ring is chosen**. Check the knob grips the shaft: it enters 8.0 mm. |
| `segno_screen7_tower` | 1 | **BLACK PETG**, ≥40% infill | 7-inch screen support tower (#762, closed deck #1070). One piece, closed wedge box, six M3 to the floor through Ø5.5 float holes. The deck is closed: four internal front-to-back ribs carry it, and each cell's ceiling is a 45° gable, so **print it flange-down with no support** (there is no way to get support out of a closed box). The openings are the connector notch on the edge facing the console centre, where the module's HDMI, micro-USB and backlight switch are. The strip-ring notch of #1075 is gone again: the ring moved 14.16 mm down the slope (#1090), so **the tower already printed is the current part**; a generator gate keeps the carrier clear of it. |
| `segno_screen16_stand_L` | 1 | **BLACK PETG**, ≥40% infill | Left 15.6-inch stand (#1070). |
| `segno_screen16_stand_R` | 1 | **BLACK PETG**, ≥40% infill | Right 15.6-inch stand: **the exact mirror of `_L`** (either print `_R`, or print `_L` mirrored in the slicer). The halves butt at the screen centre and the splice below joins them. |
| `segno_screen16_splice` | 1 | **BLACK PETG**, ≥40% infill | Flat plate between the deck ribs at the 15.6-inch screen centre. Four M3×12 up into heat-set inserts, two in each half. |
| `segno_screen7_shim_{0p2,0p4,0p8,1p6}` | 1 each | **BLACK PETG**, 100% infill | Height shims under the 7-inch tower: the tower's whole underside (flange ring and rib feet) with the same float holes. The kit is binary, so any stack from 0 to 3.0 mm in 0.2 mm steps is available. **Nominal is 0.2 + 0.8 = 1.0 mm**: the tower is built 1.0 mm short of the lid, so the stack trims it -1.0 to +2.0 mm. Print the 0.2 as a single first layer and check it with calipers; a first layer squashed to 0.15 is a 0.05 mm height error. |
| `segno_screen16_shim_{0p2,0p4,0p8,1p6}` | 2 each | **BLACK PETG**, 100% infill | The same kit for the 15.6-inch stands, one set per stand. The flange outline is not symmetric; for the right stand **turn each shim over**. |

**Setting the screen height.** Fit each stand on the nominal 0.2 + 0.8 stack,
close the lid and check the glass against the lid underside around the aperture.
Add shims under a stand whose glass sits low, and take them out under one that
holds the lid off its seats. The 15.6-inch stand has one stack per tower, so
left and right can be set separately to level the panel. In-plane, every floor
screw has ±1.25 mm of float (M3 in a Ø5.5 hole under a Ø9 washer): centre
the image in the aperture before torquing. The 15.6-inch monitor is screwed
FIXED to its stands (Ø4.8 clearance for M4); join the two halves with the splice
first, then move the whole platform.

**Ring-holder orientation and fit.** The ribs make this part rotationally
indexed. Use the [top-view alignment reference](enclosure/reference/ring24_orientation.svg):
holder +X points toward the 15.6-inch screen, with the PCB/encoder in the
selected Fusion orientation. The view from underneath is mirrored. Present the
complete Ring 24 board upward from below before gluing the holder; all eight
ribs must enter unoccupied gaps between LEDs and small components. Do not glue
the holder at an arbitrary rotation or force the PCB against its shelf. Fit the
finished 50.62–51.10 mm disc, verify the real header stack and unobstructed
insertion/removal, then check nut clamping, holder retention and light diffusion.
The minimum nominal PCB gap is small enough that printer and purchased-part
variation must be checked on the actual assembly; CAD alone does not qualify it.

Console collar update, September 9: the front and rear light-baffle walls are
2.4 mm thick, growing outward to an overall depth of 118.47 mm. The sled bore,
pedal seating heights and metal-base fixing positions retain their previous
dimensions. The front collar and front sled keep their existing mounting.
The tall CLEAR/BANK collar now has four blind Ø4.5 ×6 mm insert pockets opening
at its bottom face, at local X = ±48.685 mm, Y = ±22.1875 mm. Four
separate Ø3.7 mm deck holes at X = ±30 mm, Y = ±18 mm connect it to the dedicated
mid sled. The metal holes and mini-console are unchanged.

Console collar update, September 12 (issue #1037), integrated September 15:
the CLEAR/BANK collar is solid between its floor and its deck. It replaces
the 3 mm shell and open underside cavity with material that the slicer fills
at the selected infill. Four Ø12 mm driver bores remain, open at the floor
and ending at the deck underside. Each accepts the Ø6 ×3 mm screw head and
Ø8 mm straight driver. CAD volume increases from 165.9 to 420.9 cm³ per
collar; use the slicer's estimate for filament consumption.


Console cable-slot update, September 9: the measured cable feature is
7.6 mm wide ×11.45 mm high. The rear opening is centred and 8.6 mm wide,
with 0.5 mm clearance on each side. Its lower edge sits 6.95 mm above the
bare pedal underside (the sled top). The approximate 6 mm top and 8.5 mm
bottom measurements imply positions 1.05 mm apart on the 24.9 mm case;
the hole clears both with at least 0.5 mm around an assumed stadium-shaped
fitting. The opening is a closed vertical stadium, 8.6 ×13.5 mm overall,
with R4.3 mm ends and 4.9 mm straight sides. Thread the cable end through
before lowering the pedal/sled. Square fitting corners are not qualified by
this profile; check the actual cable/strain relief in the first print before
batching. The mini retains its existing cable notch.

Conditional connector check: a standard JST XHP-2 female housing envelope
7.3 ×5.7 mm, centred while threaded through the hole, clears by 0.628 mm in
both collars. Dimensions come from [JST's XH drawing](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf#page=4).
The owner's description does not uniquely identify the housing; check the
actual plug, latch and cable routing before printing a batch.

PETG starting profile for these collars and sleds: 0.20 mm layers, 40% gyroid,
six perimeters with a 0.4 mm nozzle, and six top/bottom solid layers. Print
collars base-down and sleds flat-bottom-down. The tall CLEAR/BANK collar has
four Ø12 mm driver-bore roofs to bridge instead of a large underside ceiling.
Inspect and avoid unnecessary support inside those bores and the collars'
or sleds' blind insert pockets. Keep a brim optional
according to actual corner adhesion. The first-print archive,
`enclosure/out/segno_first_prints_STL.zip`, contains four STLs: one front collar,
one mid collar, one front sled and one mid sled. Print one of each at 100% scale
and test both assemblies with the actual M3 Ø5 ×5 mm inserts, screws and cable
before batching. These settings and CAD clearance checks do not establish an
assembled stomp-load rating.

For CLEAR/BANK, install the inserts, bolt the pedal to its sled on the bench
and close the pedal case. Thread the cable through the closed stadium opening,
seat the sled, then drive four M3×12 screws upward through the 8 mm deck via
the four Ø12 mm driver bores. Use a straight driver long enough to reach
through the 30.3 mm bores, with the screw held on its tip. Mount that complete
module to the bottom metal base with four separate M3 screws, using the
confirmed rail-inclusive length from the hardware schedule below. To service
the sled joint, release the base screws and remove the complete module first;
the deck screws are not
accessible while the module is attached to the base. This replaces the long
through-screw arrangement without adding faceplate fixings.

The Cherub WTB-006 uses side through-screws. Install these on the bench before
putting the pedal/sled assembly in the collar; the enclosure does not provide
clearance to withdraw the full-width screw sideways after assembly.

FDM tiles stay the prototype / fit-check path. Production nameplates are the
2-ply pack in the next section.

## 2b. 2-ply engraved plastic (pedal name tiles)

Send **`enclosure/out/segno_pedal_tiles.pdf`** to a 2-ply laser shop
(1:1, red cut / black fill). The zip also carries the DXF if they ask for
CAM. **Not metal, not vinyl, not a 3D print.**

| Part | Qty | Material | Notes |
|---|---|---|---|
| `segno_pedal_tiles` | 10 | **2.0 mm 2-ply** (black cap / white core) | Same trapezoid as the FDM tiles: 54.36 (back) / 53.76 (toe) × 19.90. 2.0 mm is the closest standard stock to the 2.2 mm pad pocket — the tile sits 0.2 mm recessed. **CUT** = outline (through-cut). **ENGRAVE** = filled glyphs (burns the black cap so the white core reads). Glyphs are geometry, never TEXT — do not substitute a font. **Fit the WIDE edge toward the cable end**; it carries the top of the glyphs. REC/PLAY and STOP use the transport symbols engraved on the pedal tiles. Dimensions are nominal: the 0.05 mm per-side clearance is already in the part; the shop applies kerf compensation and must not enlarge the outline. |

Regenerate with `segno_enclosure.py` (or `--tiles-only`). The zip is a
per-quote artifact, same freshness gate as the other vendor packs (#236).

## 3. PCBs

| Board | Files | Qty | Notes |
|---|---|---|---|
| **Console board v3** (`console_board.py`, #990) | `kicad/out_console/segno_console_board_gerbers.zip` (run `route_console_board.sh` to produce) + `kicad/fab/segno_console_board_bom.csv` | 1 | Hardware work in progress: Pico 2, MIDI front end, sensed CTRL jacks, ring-board link and PD header. The ring-link and PD firmware are unfinished; this is not the v2 board running release 137. See the [integration record](../docs/APPLIANCE_INTEGRATION.md). |
| Encoder ring carrier (v3, #987) | the v3 XIAO ring carrier, Ø80, from `codex/console-v3-runtime-publication` (its `hardware/kicad/fab/segno_pedal_ring_gerbers.zip`, the September 24 export with the J1/J3/J4 hole allowances; see `kicad/RING_ASSEMBLY.md` there). **The zip of the same name in this checkout is the older #990 export; do not order from it** | 1 | The board the populated Fusion console carries (`ring_board_v3`). Fit the Ring 24 at J3 for the Ring 24 ring, or leave J3 empty and plug the 34-LED strip into J2 for the console strip ring. The Ø68 package on master is an older revision; do not order it for the console. |
| LED puck (single WS2812B) | `led_strip/segno_led_strip_gerbers.zip` | 0 | **NOT ORDERED for the console.** Owner call 2026-08-28: the indicators are eight-LED segments cut from a **144 LEDs/m bare IP20 strip**, and the diffuser channel is sized for that (**12 mm wide, 0.53 thick**, 56.96 long), not for this 16×8 board. The design is kept because it is finished and the footprint may suit another build — but ordering it will not fit the current diffuser. |


## 4. Pedal labels

The individual pedal tiles carry every pedal label. No full-face adhesive
overlay or separate overlay supplier package is required.

## 5. Purchased parts

Full list with links: **`segno_console_shopping_list.md`**; the console board's
parts are `kicad/fab/segno_console_board_bom.csv`. Headlines:

- 10× Cherub WTB-006 footswitches; 15.6" 5V USB-C touch panel; APROTII 7" monitor
- Raspberry Pi 5 + Active Cooler
- 5V bucks: **eleUniverse 8–36V→5V 10A IP67** (Amazon B0GGHN97TK) **×2** —
  BUCK_PI + BUCK_AUX, fed 20 V from the USB-C PD inlet (#754); the 9 V brick
  is gone
- 1× **encoder knob, Ø50 × 18, Ø6 bore, black aluminium, plain (un-knurled) barrel** —
  the ring window and `segno_ring_diffuser` are sized around this Ø50. `out/segno_encoder_knob.step`
  is a REFERENCE model of it for the assembly, deliberately **not** in the 3D-print pack.
  Check one thing with calipers before the faceplate is cut: the model assumes a Ø22 × 4.5
  underside relief clearing the EC11 nut. If the real knob's underside is solid it will sit
  ~3 mm proud of where the model puts it.
- 1× NeoPixel **Ring 24** — 65.5 mm OD / 52.3 mm ID / 3.2 mm thick (the ring the owner has;
  the faceplate window and `segno_ring_diffuser` are cut for THESE numbers, not the Ring 16's 44.5 mm)
- Cabling per **`segno_wiring.md`** (HDMI ×2, USB, the 20 V PD feed + 5 V buck
  runs, the 2×20 keyed ribbon, JST looms)

### Console hardware schedule — one ten-pedal console

Quantities below cover the current collar-and-sled assembly. Screw lengths are
measured under the head. A nominal length is not a substitute for checking the
finished stack, actual insert depth and screw-tip clearance. Rows marked
**measure before ordering** have no released screw length.

| Joint | Quantity and hardware | Length / assembly requirement |
|---|---|---|
| Pedal sled inserts | **80 M3 heat-set inserts**, 5.0 mm long ×5.0 mm OD | Eight front sleds and two dedicated mid sleds, each with four inserts from above and four from below. Printed pilots are Ø4.5 ×6.0 mm deep; fit-test the selected insert in the printed material. The two sled variants have different lower patterns. |
| CLEAR/BANK collar inserts | **8 M3 heat-set inserts**, 5.0 mm long ×5.0 mm OD | Four from below per tall collar, in Ø4.5 ×6.0 mm blind pockets in its solid floor. These are additional to the 80 sled inserts, giving 88 inserts across the console's pedal platforms and sleds. |
| Front-row collars and sleds → base | **32 M3 screws; confirm length before ordering** | Four per pedal, driven upward from under the base. Include any shared floor-rail bearing stack, coating, washer and insert recess in the length check. The earlier M3×8 estimate excluded the rail stack; verify engagement and head clearance on the current assembly. |
| CLEAR/BANK collars → base | **8 M3 screws; confirm length before ordering** | Four per collar into its bottom inserts. Include the actual floor-rail/metal/coating stack where present. The earlier M3×6 estimate is not a released length for the revised support arrangement; check engagement and blind screw-tip clearance. |
| CLEAR/BANK sleds → collars | **8 M3×12 screws**, nominal | Four per sled on a 60 ×36 mm pattern, driven upward through the 8 mm deck before mounting the module to the base. Nominal insertion is 4.0 mm before any washer or insert recess. Each screw head and straight driver fit inside a Ø12 mm bore, 30.3 mm deep; use a long driver with the screw held on its tip. Check the actual hardware and remove the complete module for service. |
| Pedals → sleds | **40 M3 screws; measure before ordering** | Four per pedal, driven from inside the opened pedal into the sled's top inserts. Remove the lower rubber pad. Measure the real pedal base thickness, head-bearing surface and permitted insertion; close the supplied pedal case on the bench before lowering it into the collar. Reuse the pedal's original case fasteners. |
| Lid → base | **18 M3 ISO 7380-1 button-head screws, 9 front OD7 washers and 9 rear OD12 / ID3.2 / 1 mm washer references** | Nine front plus nine rear, into owner-tapped M3 pilots. M3×8 is a nominal reference; confirm length, engagement and screw-tip clearance against the revised shim/washer stack. Rear washer procurement and angular seating remain conditional. No clinch nuts. |
| Front lid lip → base, between painted bearing faces | **9 fitted solid-metal shim packs**, layer quantity depends on finished gaps | Stainless, OD6.90–7.00 / ID4.0–4.2 mm. Fit after coating with the lid freely seated; nominal 1.10 mm STEP thickness is reference only. Check face alignment and bearing, then record thicknesses and stations 1–9. Use edge-only retention, without coating removal or adhesive in the bearing stack. |
| Support-beam foot → base | **7 M4 screws, 7 nuts and washer sets; measure before ordering** | The beam's foot, through depth-slotted holes, one at the centre of each interior pedal gap (#1088). Bare metal stack is **3.6 mm**; add both parts' coating, washers and the selected nut. Nuts are under the floor. Check that the ends and hardware remain above the neoprene floor-contact plane. |
| Support-beam ears → side walls | **2 M4 screws, 2 nuts and washer sets; measure before ordering** | One per end, from outside the wall into the beam's rearward ear, whose hole is slotted vertically. Bare stack is 2.0 Al + 1.6 steel = **3.6 mm**. The steel beam receives appropriate pretreatment separately and bolts into the painted body. |
| Screen stands → base | **14 M3 screws and 14 M3 DIN 9021 washers (Ø9); confirm length before ordering** | Six for the 7-inch tower and four for each 15.6-inch stand. Each passes a Ø9 washer, **5 mm of printed flange, 0–3.0 mm of shims** (1.0 nominal) and the 2 mm base's M3 threads. The flange holes are Ø5.5 float holes, so the washer is what bears. M3×10 covers the full shim range; verify engagement and tip clearance after coating. |
| 15.6-inch stand splice | **4 M3×12 screws and 4 M3 heat-set inserts** (the sleds' 5.0 mm long ×5.0 mm OD) | Two per half, up through the 6 mm splice plate into Ø4.5 ×6.0 mm blind pilots in the 10 mm deck. Blind from below on purpose: the deck's top face sits 0.3 mm off the monitor, with no room for a head. |
| 15.6-inch monitor → stands | **2 M4×16 screws and 2 M4 DIN 125 washers (4.3 × 9 × 0.8); measure the thread depth before ordering** | One horizontal pair at 75 mm pitch, up from under the deck. The holes are **fixed** Ø4.8 clearance (#1070); the monitor no longer adjusts on the stand. The spliced stand pair moves as one platform on its ±1.25 mm floor float holes instead. Stack under the monitor: washer 0.8 + deck 10 + gap 0.3 = 11.1 mm, so M4×16 engages about 4.9 mm. The reference model's 6 mm blind holes were not measured, so check the monitor's real thread depth first. |
| 7-inch monitor → tower | **4 M3×8 screws and 4 M3 heat-set inserts** (5.0 mm long ×5.0 mm OD, the sleds' insert) | One per tab, through the module's Ø3.1 tabs (1.7 mm) into Ø4.5 ×6.0 mm pilots in Ø10.5 bosses (#1070). Below the insert there is a Ø3.4 clearance, so a longer screw passes rather than self-tapping. Set each insert flush with the boss top: a proud insert holds the glass off the lid. |
| Console board → base | **4 M3 female/female standoffs, 15 mm body length, plus 8 M3 screws; measure screw lengths before ordering** | Four floor-side and four board-side screws. Include any washers in the length check and preserve the specified H1 electrical bond. If the supplied standoffs are male/female, replace the four floor-side screws with the matching nuts instead; the installed height stays 15 mm. |
| N07 / Raspberry Pi → base | **4 M2.5 female/female standoffs, 12 mm body length; 4 M2.5 male/female extenders, 6 mm body length; 8 M2.5 screws** | Four screws secure the lower standoffs from below and four secure the Pi from above. The extenders pass through the N07 board into the lower standoffs. Confirm the supplied kit's thread lengths and avoid bottoming in its blind threads. **35.3 mm risers are not used.** Retain the N07 kit's separate SSD-retaining hardware. |
| Buck converters → base | **4 M4 ISO 7380 button-head screws (in from below), 4 nuts, 4 Ø12 mm ear washers; measure before ordering** | Two fixing points per converter, through its Ø6.5 ±0.3 ears. The heads sit under the floor inside the rear rail's pockets (#1088), so nothing else may stack under them. Measure actual ear thickness, washer-bearing area, insulation if required and tool access. The approximate housing STEP does not qualify these washers. Check the completed underside stack against the fitted rails and neoprene. |
| PD, CTRL and MIDI connectors → rear wall | **10 M3 fixing sets**, each screw plus matching nut as required by the purchased part | Two for the PD coupler, two for each CTRL D-flange socket and two for each MIDI socket, through the 2.0 mm painted rear wall. Confirm the real flange thickness, screw-head style, washers and whether matching fasteners are supplied before choosing lengths. |
| Other rear connectors | **2 USB bulkhead retaining nuts; 1 power-button nut; 1 fuse-holder nut** | Use the matching hardware supplied for each purchased connector. The USB apertures must follow the owner's verified four-flat profile; verify all finished openings against the purchased parts. |
| Floor rails → base | **Fixings for 12 printed rail segments; lengths and bearing stacks to confirm** | Preserve shared pedestal fixing stations and the rear rail's eight dedicated anchors from the matching source/native revision. Keep heads within the printed counterbores and all hardware above the neoprene floor-contact plane. Fit rails before the strips; check actual fastener retention and access. The former 15 rubber feet are not ordered. |
| Central lid prop → base | **2 M4 fixing sets; measure before ordering** | Use the existing two floor stations. Include printed tongue thickness, coating, washers and nut in the stack; verify underside clearance. Fit top felt after measuring the finished lid gap. |
| Encoder / ring assembly | **1 matching EC11 bushing nut and washer; supplied knob retaining hardware** | The EC11 nut clamps the centre disc into the holder; the holder's outer land is glued to the faceplate underside. Verify this assembled retention and the knob's underside relief. Fusion deliberately uses the owner's PR #990 Ø80 board without mounting holes, as recorded in `enclosure/FUSION_MODELS.md`; the checked-in Ø68/three-hole PCB is a different revision. Reconcile the electronics order with that chosen revision; no three-M3-screw set is implied for the native assembly. |
| Chassis bonding | **1 M6 stud fixing set**, with the nuts, locking washers, lugs and straps required by the agreed bonding arrangement | Select the complete stack and its length against the actual lug arrangement and verify continuity. The connector shells sit on the painted rear wall and reach chassis ground through the board (H1); there is no rear-panel bond since #1088. Do not add parallel grounding connections by assumption. |

The split CLEAR/BANK joints add eight screws and eight inserts to the previous
console mounting arrangement. No long through-screws are required.

Before releasing the remaining lengths, measure the front chassis, mid chassis
and mid deck screw stacks, pedal bases, monitor threads, 7-inch tower insert
fit, converter ears, floor rails and
selected standoff threads. Confirm the ring-board retention and chassis-bonding
hardware as assembled. All hardware below the base must clear the supporting
surface with the actual rails and neoprene fitted.

**Mini-console hardware is a separate order.** None of its inserts, sled
retention screws or lid screws is included in the ten-pedal console quantities
above. Derive that order from its own current tray/sled/lid revision; the old
combined “8 pedestal inserts +3 lid inserts” allowance is not a console BOM.

For the current two-pedal mini, print **one tray, one lid and two sleds** from
the same revision. Each sled now has **two retention screws**, 60 mm apart on
its depth centre-line; an old central-hole tray does not match the new sled.
The assembled reference includes both sleds. Keep its order separate:

| Mini joint | Quantity | Fit requirement |
|---|---|---|
| Pedal → sled | **8 M3 screws and 8 M3 heat-set inserts** | Four from above per pedal. Remove the lower pad; confirm the actual pedal-base thickness and screw-head clearance before ordering screw length. |
| Sled → tray | **4 M3 retention screws and 4 M3 heat-set inserts** | Two from below per sled at local depth ±30 mm, width 0. Printed insert pilots are Ø4.5 ×6.0 mm, leaving a 1.0 mm roof. Use/test 5.0 mm-long ×5.0 mm-OD inserts. M3×10 is nominal: the 6.176 mm head-seat stack leaves 3.824 mm insertion without an extra washer; measure actual grip and blind clearance. |
| Lid → tray | **3 M3 screws and 3 M3 heat-set inserts** | Two rear and one front anchor. Confirm each actual screw reach and the tilted insert fit; do not use the sled screw length for the taller lid anchors. |

That is **15 inserts total** for the mini, with its screw lengths qualified
by joint. Its two Ø8.5 recessed head/driver pockets per sled remain accessible
from below and keep the screw heads above the table. Remove both retention
screws before lifting a sled; do not force a rod into its blind insert. Verify
simultaneous screw fit, seating, anti-rotation and repeated removal on one
printed pair before printing or ordering the full mini set.
The sled's toe relief is required to clear the sloped lid; retain all six blind
insert pilots and their opposite-face roofs. The current lid has its two rear
registration tabs between the diffusers and 8.5 mm-wide rear insert bosses at
the unchanged anchor axes. A Ø5 insert leaves 1.75 mm of material on each side
of those bosses: qualify insertion and tightening in the chosen print material.
Check both pill diffusers against the lid tabs/bosses and the actual electronics
before gluing. The old lid and unrelieved sled are not interchangeable with this
verified assembly.

## 6. Reference (do not send to vendors)

- `enclosure/out/segno_assembly.step` — full folded assembly
- `segno_enclosure_design.md`, `segno_wiring.md` — design + wiring
- Fusion cloud docs: "VAMP sheet metal" (native sheet-metal validation) and
  "VAMP console (populated)" (full visual assembly)
