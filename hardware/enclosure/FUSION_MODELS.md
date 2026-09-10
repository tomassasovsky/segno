# The Fusion 360 models — how to change anything without wrecking them

**Process update, 2026-09-07:** the shop delivers matched parts untapped and
unriveted. The owner rivets before painting, then cleans Ø2.5 body pilots and
cuts all 32 M3 body threads after painting: 18 for the lid and 14 for the screen
supports. This supersedes earlier instructions
to tap at the shop/protect existing body threads. Geometry is unchanged.

The console lives in TWO cloud documents (Fusion Team, Default Project), edited
through the Fusion MCP (`localhost:27182`, `fusion_mcp_execute` with a script
defining `def run(_context: str)`). This file is the contract for changing them.
It was earned the hard way on 2026-08-18 (#753); every rule here broke something
once.

The fully coated revision has passed local source/export and native-model
verification. Current saved versions and evidence are recorded in
[the release review](RELEASE_REVIEW.md). Earlier dated results below apply only
to their recorded revisions. Physical supplier and assembly acceptance remains
required before production release.

## The two documents

| doc | role | frame (world) |
|---|---|---|
| **VAMP sheet metal** | source parts: base, faceplate, brackets, rear_panel | x = 84.8 − u/10 (MIRRORED), y = height, z = depth |
| **VAMP console (populated)** | the full machine, the one that gets reviewed | x = u/10 (DIRECT), y = depth = v/10, z = height |

`u`, `v` are the enclosure generator's mm coordinates (`segno_enclosure.py`:
u along the 850 width from the left wall, v along the 423 depth from the front).

Populated-doc browser hygiene: root holds only the chassis (`VAMP sheet
metal`, `base`, `faceplate`, `rear_panel`, `vent_foam`) plus identity-placed
grouping components — `pedals` (10), `platforms` (20), `feet` (60 since #1019: 20 floor supports plus
the 40 pedestal feet, all one `foot_uxcell_18x15x5` component),
`fasteners` (18 native ISO 7380-1 screws and 18 M3 Ø7 washers), `lid_stack` (screens, the
switched-off legacy `encoder`, texts (switched off), logo, support posts, and
`diffusers` = the ten `led_diffuser_*` pills; the old `led_strips` bar
component was deleted 2026-09-04), `electronics`
(Pi, NVMe, console board, bucks, standoffs). Groups are at identity, so
members keep world = local of the old root placement (`moveToComponent`
preserves world transforms; verified delta 0). The canonical-transforms
table below still applies per occurrence; only `fullPathName` gained a
prefix.

**The populated frame is proven by the mounts**: `base_foot_xy()` equals the
foot occurrences' translations exactly, and the platforms, Pi/N07 stack and
board mount holes all agree. If a placement disagrees with a generator mount
table, the placement is wrong, not the table.

### Canonical occurrence transforms (4×4 row-major, cm)

| component | populated | VAMP sheet metal |
|---|---|---|
| base | `[1,0,0,0 \| 0,1,0,0 \| 0,0,1,0.2]` | `[-1,0,0,84.8 \| 0,0,1,0.2 \| 0,1,0,0]` |
| faceplate (lid) | `[1,0,0,-0.19 \| 0,c,-s,-1.4829540425030463 \| 0,s,c,1.1184681604973878]` | `[-1,0,0,84.99 \| 0,s,c,1.1184681604973878 \| 0,c,-s,-1.4829540425030463]` |
| rear_panel (inside mount, **1.2 mm**, owner-approved 2026-09-05) | `[1,0,0,62.5286 \| 0,0,-1,41.771 \| 0,1,0,4.69]` | `[-1,0,0,22.2714 \| 0,1,0,4.69 \| 0,0,-1,41.771]` |
| console_board_v4 (KiCad STEP) | `[1,0,0,36.225 \| 0,1,0,38.575 \| 0,0,1,1.7]` | — |

`c`/`s` = cos/sin of `SLOPE_ANGLE` (12.498241812070852°) at full precision —
rounded values fail `transform2` validation (the rotation must be exactly orthogonal).

- The base's `+0.2` z puts its underside at world z=0. The reference rubber feet
  extend below it to their floor-contact plane at z=-5 mm.
  There is **no y/depth offset** — an earlier `+0.2` there put the whole shell
  2 mm rearward of every mount.
- **Lid seat:** the underside plane is `-s*y + c*z = 12.12889 mm`
  in the populated frame, referenced to the floor bottom. The front wall outer
  face is at y = -1.910841 mm; the revised lip inner face is at -2.410842 mm.
  This gives **0.500 mm nominal bare clearance**. Fabrication acceptance is
  0.50–0.60 mm bare. All enclosure faces and clearance bores are coated.
  Independent 60–100 µm films at the side/rear seats permit approximately
  0.157–0.588 mm front gap; accept 0.15–0.60 mm on the actual painted assembly. Fit nine
  purchased metal shim packs Ø6.9–7.0 / ID 4.0–4.2 to those gaps after coating.
  All 18 lid bores are Ø4.5 (+0.10/−0) before coating and use M3 Ø7 washers.
  The nine front axes are 0.50 mm lower, world Z 6.455420 mm; rear axes are fixed.
  Protect only identified electrical ground contacts; the owner cleans and taps
  the 32 body pilots after painting. Solve the bare
  lid placement from actual planes; the STEP remains the bare reference.
  The blank gains `LID_FRONT_EXTRA` ahead of the controls, and its lip is
  shortened to keep its tip at floor-bottom height. The control stations and
  rear seam keep their existing positions. Native base/lid intersection is
  about 5.52 mm³ of contact films at the side/lap seats, not a broad clash.
  Use solid intersections for interference and `preciseBoundingBox` for extents.
- **The lid stack moves together**: faceplate, ring_disc (both docs), plus in
  populated screen_16in/7in, the legacy `encoder`, texts, segno_logo, the ten
  pill diffusers, and the ROOT-level ring family (`ring_board_asm`,
  `neopixel_ring24`, `ring_holder24`, `encoder_knob_50x18_alu`,
  `ring_disc_51_5`, `ring_comet`). If the faceplate moves, every one of these
  gets the same delta. The ring family ALSO follows `ENC_V` on its own: it
  moved +7.5 mm along the plate on 2026-09-04 (219.66 -> 227.16, #930) and a
  further +2.0 mm for the LED_GAP 16 trial (-> 229.16); a plate move of d is a
  world delta of (0, c*d, s*d) in populated and (0, s*d, c*d) in VSM.
- **Support posts** (`faceplate_support_post:1`..`:7`, root): imported
  `out/segno_post.step`, with real concentric R1.6/R3.2 bends in 1.6 mm steel,
  converted to native sheet metal using T1.6/R1.6/K0.33. Place at
  `[1,0,0,(POST_U-POST_PW/2)/10 | 0,1,0,(_POST_VP-POST_FOOTL)/10 | 0,0,1,0.2]`.
  Since #1019 there is one per interior pedal gap, x = 10.45 / 20.564286 /
  30.678571 / 40.792857 / 50.907143 / 61.021429 / 71.135714 cm, y = 13.899694 cm.
  The last two moved 0.29 and 0.43 mm when `POST_U` stopped being two literals
  and became `FRONT_SCREW_U[1:-1]`. **`addExistingComponent` applies its matrix
  RELATIVE to the source component's own placement**, so a new post lands at
  x + 61.021429 unless you set `transform2` absolutely afterwards; do that, then
  `snapshots.add()`. The two foot holes
  per post are at world v = **148.996937 mm**, matching the base anchors.
  The top pad has **1.2 mm nominal normal bare clearance** to the lid, with
  approximately 0.925–1.163 mm after 60–100 µm coating on the floor, post foot/top
  and lid underside. The painted lid seats change the fitted pose: measure the finished gap and fit the felt
  without lifting the lid off its seats. Regenerated
  `post_felt:1` / `:2` use the same placements and model the bare 1.2 mm space.
  Native unfold gives **81.161489 ×30.142857 ×1.6 mm**, matching the DXF.
- **Mid-field lid prop** (`lid_prop:1`, root, populated only — it is a printed
  part, not a sheet-metal source): imported `out/segno_lid_prop.step`. Its local
  frame is x = depth, y = width, z = up with the origin on the floor TOP under
  the column axis, so it needs a real +90 deg rotation about z, not a swap —
  `[0,-1,0,PROP_U/10 | 1,0,0,_PROP_VP/10 | 0,0,1,0.2]`, det +1. Current
  x = 43.25, y = 23.2219636 cm. The STEP lands about 0.01 mm proud of z = 0.2;
  that is import tolerance, not a clash.
- **Base support bores** (`ISSUE_1019_SUPPORT_BORES` in both base components):
  the twelve M4 post/prop foot bolts and five floor-foot bores that #1019 added
  live in the `CUT` sketch, but are cut by their own extrude rather than added to
  `Extrude1`'s profile set. Four existing post-foot circles were moved in place,
  so `Extrude1` carries them as before. **The `VENT` sketch has to follow**: the
  generator drops any slot under a foot, so spreading the posts removed 21 slots
  from the bottom field (127 -> 106 on this flat). Leaving them makes the new
  bores break into open slots — visible as cylindrical faces whose bounding box
  is not centred on the bore. Delete those curves with the timeline marker rolled
  back to just after the sketch; deleting them with the marker at the end
  recomputes the whole model once per curve and takes tens of minutes.

- **FRONT_WALL_KNUCKLE_TRIM**: both base comps carry a cut (sketch of that
  name, offset plane at local z=0.8094) matching the generator's shortened
  front flap — the wall's square top corner cannot clear the lip-fold roll
  (#760). A future base rebuild gets this from the DXF automatically; do not
  delete the feature without rebuilding from a current flat.
- The panel outer face seats on the rear wall's inner face. At the current
  1.2 mm gauge it spans depth 417.710..418.910 mm. Its x centre is the
  `rear_panel_outline()` centre; its z centre is the drawing's centre plus
  DEV90. The owner approved 1.2 mm stock with 0.06–0.10 mm coating per face:
  nominal finished thickness is 1.32–1.40 mm. Measure the actual finished
  panel at the NJ6FD-V jacks within 1.20–1.50 mm before assembly.
- Board STEP mapping: world = (36.225 + kicad_x/10, 38.575 − kicad_y/10, ·) —
  note the **y flip**. Derived so the board's H1–H4 land exactly on the floor's
  `board_mounts()` drills.
- All transforms must have **det = +1** (no mirrors — Fusion rejects or mangles
  improper matrices silently).

## The lid (faceplate) rebuild recipe

Much simpler than the base — no wrap, two folds, one per call:

1. Keep the old component until its replacement passes checks. Import the
   current `out/segno_faceplate.dxf` into a new component at identity.
2. Extrude the CUT max-area profile **-0.2 cm**; convert its top face to sheet
   metal with T2/R2/K0.33. Select rules by numeric values, not duplicate names.
   Thickness and radius are `.value` properties; K is a scalar.
3. Fold the front lip at `LID_FRONT_FL` (12.082988 mm), rotation
   `-(90-SLOPE_ANGLE)` degrees, centered on its BEND line.
4. Fold the rear lap at `LID_FRONT_FL + LID_FRONT_EXTRA + FP_V`
   (419.231325 mm), rotation `-(SLOPE_ANGLE+TRANS_ANGLE)` degrees.
5. Solve the placement using the lip plane's larger local constant
   `k = c*y-s*z`: `ty=(-DEV90-LIP_BARE_CLEAR)/10-k`,
   `tz=(LID_UNDER_NORMAL/10+0.2+s*ty)/c` (cm). The current exact transform
   is in the table above; the lip tip is within 0.001 mm of floor bottom.
6. Add the nine front Ø4.5 mm holes after folding, using
   `FRONT_DRILL_AFTER_FORMING`, current drawing X stations and nominal world
   **z=6.455420 mm**. The construction may need the documented submicron
   native-kernel compensation; that does not change the shop datum of
   6.455±0.10 mm above the bare floor underside. Select only the circular
   profiles, never the entire face perimeter. Also make the nine rear Ø4.5
   holes from the current rear `DRILL` axes after folding. A fresh CUT extrusion
   does not make either deferred row. Retain an existing valid hole feature
   where its active geometry already matches; do not cut duplicate profiles.
   The eighteen bores are nominal bare references, not a final drilling jig.
   The shop locates them on the fitted bare pair before coating; all clearance
   walls and seating surfaces receive paint. The owner cleans and taps the body
   pilots after painting; only identified electrical ground contacts are protected.
7. Apply appearance, transform LAST and take a guarded snapshot. Check feature
   health, every final hole, flat parity and assembly fit before replacing an
   occurrence. Match all front fastener/shim reference axes to the lowered
   front row; place the eighteen purchased head washers from the actual lid faces.

## The base rebuild recipe (the ONLY supported way to change the base)

The base is generated: **change `segno_enclosure.py`, regenerate, then rebuild
the Fusion component from the new DXF**. Never sculpt the Fusion body by hand —
it will be thrown away on the next rebuild.

One MCP call per numbered step; fold steps ONE PER CALL (multi-attempt loops in
a single call have crashed Fusion):

1. Keep the old `base` until its replacement is verified. Create a new component at **identity**
   (never import into a transformed occurrence — the import bakes the inverse
   transform into the sketch) and `importManager.createDXF2DImportOptions(
   out/segno_base.dxf, comp.xYConstructionPlane)` → sketches CUT/BEND/VENT/DRILL/MASK.
2. Extrude the CUT sketch's max-area profile **−0.2 cm** (down; the flat's top
   face must end at z=0). Cut the VENT profiles −0.3.
   **Every cut extrude needs `ei.participantBodies = [body]`** or it throws
   "No target body found".
3. `body.convertToSheetMetal(top_face_at_z0, rule)` and set
   `comp.activeSheetMetalRule` — the rule must be **T=0.2, R=0.2, K=0.33 cm**
   ("Aluminio (mm) (Convert)"; both docs already carry it). Folding at any
   other radius mis-lands every flap: the flat is developed for exactly these
   numbers (`dev_deduct` in the generator).
4. One sketch `RELIEFS_AND_TRIMS`, one cut: the current DXF already has Ø6.5 mm
   reliefs at (0,0) (84.6,0) (0,41.9) (84.6,41.9) cm and 0.15 mm front-end
   trims. For the fold construction, trim the front ends to x=0.05/84.55 cm
   (0.5 mm from the nominal ends, not an additional 0.5 mm); trim the
   rear-block overhang back to the side bend lines
   +0.6 mm (rects x∈[−0.21,0.06] and [84.54,84.81], y∈[41.85,53.1]).
   These extra construction trims allow Fusion's fold checker to complete;
   regrow them in step 7 so the final unfolded perimeter agrees with the DXF.
   The Ø6.5 relief and net 0.15 mm front-end trim are fabrication geometry.
5. Folds, all `CenterFoldBendLinePositionType`, all POSITIVE angles, in this
   order: **left (x=0, 90°), right (x=84.6, 90°), lap (y=50.4045084367746,
   +1.1441688336680205 rad), rear (y=41.9, 90°), front (y=0, 90°) LAST**.
   (A front-wall hem was tried and REVERTED, #760: its bend zone would have
   swallowed the screw holes — the 10.1 wall minus two bend zones leaves ~2 mm
   of straight band. The wall is plain single-thickness; the front screws use
   Ø2.5 pilots drilled after forming and fit, then owner-tapped M3 after coating,
   with Ø4.5 clearance in the lip. The REAR lap
   seam uses the IDENTICAL joint — Ø2.5 tap pilots in the transition flange,
   Ø4.5 clearance in the lap, same 9 stations: PEM nuts were dropped so the
   whole lid fixes with ONE M3 tap and ONE screw SKU, M3×8 ×18.)
   Stationary face = the big planar z=0 face whose XY bbox contains the bend
   line's midpoint. Verify the bbox after every fold.
6. **Check the front fold's result bbox.** Its moving-side heuristic is
   unstable: sometimes the floor rotates instead of the lip and the body ends
   +90° about x (bbox ≈ (−0.19,−9.75,−0.2)..(84.79,0.19,42.08) instead of
   (−0.19,−0.19,−0.2)..(84.79,42.09,9.74)). The shape is still correct — apply
   the compensated occurrence transform instead (populated:
   `[1,0,0,0 | 0,0,1,0 | 0,−1,0,0.2]`) or delete/retry; fresh components have
   folded upright. Nothing you pass (face, line direction, trims) controls it.
7. Regrow the rear wrap and lip with **OffsetFacesFeatures** (same body, no
   patch bodies): the 6 planar end faces from the overhang trim
   (|normal.x|=1, face-centre x in 0.04..0.1 / 84.5..84.58, bbox.y > 35 when
   upright) offset **+0.250 cm**; the 2 lip-end slivers (x-centre 0.03..0.07 /
   84.53..84.57, bbox.y < 0.5, bbox.z < 1.2) offset **+0.035**.
   `createInput` takes a **Python list**, not an ObjectCollection.
8. Add the nine Ø2.5 mm `FRONT_DRILL_AFTER_FORMING` holes from the formed
   datums, using only the circular profiles and `participantBodies=[body]`.
   Apply appearance, then the occurrence transform, then a snapshot guarded by
   `hasPendingSnapshot`. All features must be healthy before replacing the old base.
9. Verify the world bbox and assembly fit. Export the actual base flat pattern
   and require `compare_flat_pattern` to pass against CUT/VENT/DRILL before saving.
   Reopen the saved document and repeat the geometry and preservation checks.

**Rear ridge closure, September 5 seam correction.** The old side contour
followed the rear return's underside plane before that return actually began,
leaving a 2.18 mm opening beneath the lid bend. The canonical correction is
`base_rear_ridge_profile()` in the generator: a line, concentric R1.70 arc,
line and tip clearance, with **0.30 mm bare normal clearance** to both the
lid's inside bend and the fixed return tip. The current flat includes it.
The existing bodies were updated in place with two source-derived joined
extrusions after their folds; this is a replay of the generated contour,
not an independent sculpted shape. Do not add these patches to a fresh body
whose imported flat already contains the closure.

For that replay, the helper's coordinates are `(world depth, world height,
outgoing arc bulge)` in mm. Subtract 2 mm from height for the canonical base's
local Z. Close the five-point wire and extrude +2 mm along local X on planes
`X=-DEV90` and `X=W-3*T+DEV90`. The arc's outgoing bulge is negative in the
depth/height frame; derive the native arc from it. Preserve all existing folds,
Ø6.5 corner reliefs and front-end trims, and check the final native flat against
the generated perimeter. The new flat width is **1041.218 mm**, including the
ridge arc's interior apex. The measured bare lid clearance is 0.299727 mm;
with the specified coating and seated lid translation, the new top retains
at least approximately 0.220 mm normal clearance and the fixed tip 0.100 mm.
Before coating, fit the ridge to **0.30–0.40 mm normal clearance** from both
the seated lid underside and fixed return tip; this functional fit overrides
general contour and bend tolerances. Preserve the new closure contour and
check the visible seam again with the coated lid seated freely.
The unchanged 5.519205 mm³ base/lid contact comprises two side-seat films and
one rear-lap film; old/new contact-region subtraction is zero in both directions.

The rear panel is the same recipe minus folds: import `out/segno_rear_panel.dxf`
at identity, extrude the max-area CUT profile **−0.12** (1.2 mm stock; the
flat panel stays a plain solid without a sheet-metal rule), set the transform (its x-centre = panel
outline centre — recompute!; depth 41.771 keeps the OUTER face on the wall's
inner face at 41.891), appearance, snapshot, save. The September 5 correction
adds `USB3_SUPPLIER_PROFILE` / `USB3_FOUR_FLAT_CLEARANCE` to the existing
component using the then-current 22.5 mm flats /Ø24.5 circle. That historical
size is superseded: the current bare profile is **22.80×22.80 mm clipped by
concentric Ø24.80, both ±0.10**, through 1.2 mm. Keep all connector stations
and fixing pitches fixed. A fresh current DXF includes this compensated contour
and needs no additional supplier-profile cut.

### Ring board (populated only)

`ring_board_asm` is the ring board of **PR #990** (unmerged on 2026-09-04,
owner's call to model it): Ø80 outline, no mounting holes, XIAO RP2350 on the
underside, the Ring 24 carried IN the STEP on a 2.54 mm pin strip. Export it
from that branch's `hardware/kicad/segno_pedal_ring.kicad_pcb` with
`kicad-cli pcb export step --subst-models` (the tracked `out_ring` STEP on
master is the Ø68 board). Placed at
`[1,0,0,8.3591 | 0,c,-s,25.8119 | 0,s,c,6.3401]`: the STEP's board centre is
KiCad (36, 36) for the Ø60, Ø68 and Ø80 outlines alike, so the transform
follows ENC_V only (+7.5 and +2.0 mm along the plate since 24.884 / 6.134).
Fusion keeps the component bodies of this export (73 solids); the standalone
`neopixel_ring24` is switched OFF because the board now carries the ring.
Both PCBs (`segno_console_board_PCB`, `segno_pedal_ring_PCB`) wear the local
appearance `PCB - purple` (74, 32, 112), a copy of Plastic - Matte (Black)
with its colour changed — the boards are purple.

**Ring holder, September 5 second review.** Keep this exact board/header stack
and every visible ring/encoder position. The old printed holder intersected
the Ring 24 PCB and LEDs. Its revised local reliefs are r25.8..33.1 at
z=-2..-0.25 and r26.35..32.3 at z=-2..1.35. Eight 1.2 mm radial ribs extend
r25.85..32.8, z=-0.25..1.35, at 7.5°, 82.5°, 112.5°, 187.5°, 232.5°, 262.5°,
292.5° and 322.5° counterclockwise from +X. They strengthen the disc seat
without trapping the PCB below a closed annular bridge. The 0.25 mm shelf,
1.05 mm roof and 0.50/1.10 mm inner/outer lens walls remain continuous.
The modeled minimum PCB clearance is 0.134601 mm and LED clearance 0.332242 mm;
do not describe these as 0.3 mm everywhere or treat them as physical qualification.
The fully coated metal disc has bare OD51.20±0.05 and straight laser bore
Ø8.50±0.05, without chamfer. Finished OD51.27–51.45 and bore8.25–8.43 preserve
fit with the unchanged holder and owner-measured ID7.25/OD11.85 washer. Center
the disc before clamping. Earlier chamfer profiles are historical.

The holder is now rotationally indexed to the ring's component gaps. Use
[`reference/ring24_orientation.svg`](reference/ring24_orientation.svg), a top
view (+Z), with +X toward the 15.6-inch screen. The actual board must dry-fit
upward from below in that orientation before the holder is glued. Check the
real PCB/header stack, finished disc, insertion, retained assembly and optical
diffusion on one print. `reference/ring24_interface.json` contains independent
numeric module envelopes for regression; the separate native review checks
all 73 board bodies. Do not substitute a flat-soldered Ring 24 or rotate the
selected board to avoid a holder error.

### Corner brackets (both docs)

There are two handed brackets, quantity one each:
`out/segno_corner_bracket_rear.dxf` for the upright right occurrence and
`out/segno_corner_bracket_rear_mirrored.dxf` for the turned-over left occurrence.
Build each with the lid recipe (import, extrude −0.2, convert, ONE 90° Center
fold at x = 1.2, positive angle). `corner_bracket_outline(mirrored=False/True)`
is the canonical free-edge profile; keep all five original hole coordinates.
The bend spans local Y=0..8.3 cm for the right hand and -0.3..8.0 cm for the left.
The old shared rectangular bracket stopped at world height 84 mm and left the
upper rear corner unbacked. Each new profile rises across its own bend to
world height 87 mm, with the rear-wall leg stopping at 85.34 mm to clear the
chassis inner radius. Both retain their original world bottom at 4 mm.

The current local frame after the fold has leg A (3 rivets) at Z=-2..0 mm
and leg B (2 rivets) at X=11.910841..13.910841 mm, with holes along local Y.
It differs from the previous rectangular bracket's frame; use the corrected
occurrence transforms below. Its local X bounds are 0..13.910841 mm.
Leg A goes on the REAR wall, leg B on the SIDE wall (the base drills 3 rivets
in the rear wall and 2 in each side wall, staggered). The holes remain
symmetric about the original 80 mm datum; the new upper-edge profile is handed:

| corner (populated) | transform 2 |
|---|---|
| left (x≈0), **turned over** | `[-1,0,0,1.40108408853628 \| 0,0,-1,41.69008408853628 \| 0,-1,0,8.40]` |
| right (x≈84.8), upright | `[1,0,0,83.19891591146372 \| 0,0,-1,41.69008408853628 \| 0,1,0,0.40]` |

Corresponding VSM transforms are left
`[1,0,0,83.39891591146372 | 0,-1,0,8.4 | 0,0,-1,41.69008408853628]`
and right
`[-1,0,0,1.60108408853628 | 0,1,0,0.4 | 0,0,-1,41.69008408853628]`.

Rivet holes land at (1.00, 41.79, 1.20/4.40/7.60) and (0.11, 40.90,
2.80/6.00) approximately on the left, mirrored on the right. The base and
bracket have Ø3.3 rivet holes. Their measured axis offsets are 0.010841 mm
on the rear leg and 0.010000 mm on the side leg, from the existing wall-seat
clearances. The new profiles preserve these stations; check actual registration
before riveting rather than describing the nominal axes as exactly coaxial.
**The bracket floats RI (2 mm) above the floor top, at z = 0.4**: a flat leg
on the wall's inner face bottoms out on the floor→wall bend's inside radius,
so resting it on the floor (what the first #992 correction did) puts its
bottom corner inside the base's fillet and every rivet 2 mm low. Check
bracket ∩ base = 0 after placing; on the floor it reads 0.018 cm³. Set the
two bracket transforms in a call of their own — imports in the same call
reset them.

**Guard the folded frame after a profile edit.** Fusion switched the stationary
leg even though the fold remained healthy. The old rectangular bracket had
local X=10.089159..24 mm and its three-hole leg vertical. The new three-feature
bracket has local X=0..13.910841 mm and its three-hole leg horizontal. Keeping
the old occurrence matrices would place it through the rear wall. The exact
new-local-to-old-local transform R rotates +90° about local Y, then translates
(12.0891591146372,0,11.9108408853628) mm. In Fusion cm:
`R=[0,0,1,1.20891591146372 | 0,1,0,0 | -1,0,0,1.19108408853628]`.
The current occurrence matrices are **old M multiplied by R**, preserving
world material and all rivet axes while retaining the new local frame.
Do not add a body MoveFeature as well; at a transformed occurrence its
coordinate interpretation did not produce the intended local compensation.
Verify all five bore axes and world bounds rather than relying on feature
health. Recreate any stale flat pattern using the unbent +Z face at local Z=0,
and require full source/flat parity for both hands.

Nominal analytic clearance of the new bracket top to the chassis is at least
**0.201659 mm vertically**. Across the rear-seam depth, the remaining upper
relief is **0.215628–0.300228 mm vertically**, rather than an exposed tall
opening. These are vertical free-edge clearances, not wall-normal gaps: the
existing approximately 0.01 mm riveted wall-seat separation is unchanged.
Rivet the fitted brackets before coating; confirm physical fit without
forcing the chassis and keep the lid removable. Before riveting/coating, fit
the top free edge to **0.20–0.40 mm vertical clearance** below the chassis
radius across the depth of the backed rear seam; this fit overrides general
tolerances. Do not apply that small limit to the side-leg top farther forward,
where its clearance grows beyond 1 mm and there is no exposed corner seam.

**Hole diameters can be edited in place.** When only a hole's diameter
changes (rivets Ø3.2 → Ø3.3, #993), set the sketch circle's `radius` on the
component's `CUT` sketch instead of rebuilding: the base's eleven-feature
chain (folds and offsets included) recomputed healthy in one call in both
docs, and so did the bracket's. Positions, not diameters, need the rebuild.

**Rear panel height.** Its z (populated) / y (VSM) is the rear-wall WINDOW
centre, `(2.54 + 6.84)/2 = 4.69` off the window's corner-radius centres, and
the four Ø2.5 pilots sit on the same line. The table carried 4.5 until the
#992 audit, which put the panel's mounting holes 2.0 mm under the pilots.
Nine root-level `M4 x 6` screws (the pre-#760 rear seam) were deleted in the
same pass: the seam is M3 x 8, all 18 in the `fasteners` group.

### Populated → VAMP sheet metal: one rotation for every transform

`T_vsm = F · T_pop` with `F = [-1,0,0,84.8 | 0,0,1,0 | 0,1,0,0]` (det +1: a
180° turn about the (0,1,1) axis, NOT a mirror — the x flip comes with the
y/z swap). Check: F applied to the populated faceplate row gives the VSM
canonical row in the table above. Use it instead of re-deriving VSM
placements by hand; the corner brackets, posts and mid collars in VSM were
placed this way on 2026-09-04.

## Hard-won API rules (each one cost a debugging session)

- **A script exception rolls back the ENTIRE call's transaction**, including
  earlier successful mutations in the same call. Keep calls small; a clean
  `return` commits.
- **Never `startEdit()` an EXISTING base feature from a script.** A body
  delete inside the edit threw "refers to a deleted Object" at `finishEdit`,
  and the rollback left the populated doc as a DIRECT design (`designType`
  0, every component's feature list empty); undo did not bring the history
  back. Recovery was close-without-save + reopen (2026-09-04). To change a
  base-feature body, build a NEW component with `baseFeatures.add()`,
  `startEdit` / `bodies.add(copy)` / `finishEdit`, and delete the old
  occurrence -- the pattern the felt caps use.
- **Occurrence transforms silently reset** when features are added to the
  component afterwards, and sometimes on fold delete/rollback. Build at
  identity, set the final transform LAST in its own call, then snapshot.
  Verify placement by reading `occ.bRepBodies` proxy bboxes (root space) —
  if the proxy bbox equals the component-local bbox, the transform is gone.
- `design.snapshots.add()` with nothing pending **throws** — always guard.
- Cross-doc body copies: `TemporaryBRepManager.get().copy(body)` →
  `baseFeatures.add()` + `startEdit`/`bodies.add`/`finishEdit` in the target.
  These are frozen BReps — fine for scaffolding, **not acceptable as the final
  state** (user rule: parts must be real sheet metal).
- `Combine` on bodies created in the same call's baseFeature fails with
  ALL_TOOL_BODY_REFERENCE_LOST.
- `addExistingComponent(comp, matrix)` drops the rotation part of the matrix —
  set `occ.transform2` explicitly afterwards.
- Sheet-metal rules CAN be edited through the API: copy a rule, then set
  `rule.thickness.value`, `rule.bendRadius.value` (cm), and `rule.kFactor`
  (scalar), before conversion. Conversion may replace the original rule
  object; inspect `component.activeSheetMetalRule` afterward.
- F3D component export/import can retain the right solid but lose OffsetFaces
  references. Check EVERY feature's health after import and after deleting the
  old occurrence. If references are invalid, rebuild from the DXF in that doc.
- Component edits and grouping can re-evaluate old placement snapshots. Apply
  final placements after all edits, take a guarded snapshot, then re-read the
  root-context proxies. Check actual transforms and solid intersections.
- The viewport often doesn't repaint from scripts; trust measured bboxes and
  point-containment probes over screenshots, and never trust a screenshot
  taken without `vp.refresh()`.
- One heavy operation per call. Fusion has crashed on long fold-retry loops;
  crash recovery reopens docs as "(~recovered)".
- The populated doc is HEAVY (800+ features). Features added to a fresh
  component compute incrementally — full-document parametric edits can freeze
  Fusion for minutes.

## Change playbooks

- **Anything on the base flat** (vents, punches, window, stations): edit the
  generator → `python segno_enclosure.py --no-step` → base rebuild recipe in
  BOTH docs; if the window/outline moved, panel rebuild too (its centre moves).
- **Rear-panel connectors**: `REAR_IO_STATIONS` / `rear_io_cutouts()` in the
  generator; screw patterns are sourced per part (see `REAR_IO_PROVENANCE`).
  Regenerate, rebuild both panels; the wall window follows the keep-outs
  automatically (`REAR_WIN_SIDE_CLR`).
- **Moving a component in the populated doc**: compute the target from the
  generator's mount tables (`board_mounts`, `pi_mount`, `buck_mounts`,
  `base_foot_xy`, `platform_foot_holes`), world = table/10 in the populated
  frame. Set transform + snapshot + verify proxy bbox.
- **The board model**: re-export the STEP from KiCad
  (`out_console/segno_console_board.step`), delete `console_board_v4`, import
  via `importManager.createSTEPImportOptions` + `importToTarget(root)`, rename,
  set the transform from the table.
- **Screens/decals**: the 16" screen carries a decal on its display slab —
  fragile; see the memory notes referenced in `docs/PROGRESS.md` before
  touching appearances (VSM saves can reset local appearances).

## Pedal name tiles (populated doc only)

Ten root-level `tile_*` components (`tile_REC_PLAY` ... `tile_BANK`), one per
pedal, each an **imported STEP** from `out/segno_pedal_tile_<LABEL>.step` — not
modelled here. The STEP carries two solids so the colours are per-body:

| solid | appearance |
|---|---|
| body (1.8 thick) | `Plastic - Matte (Black)` |
| glyphs (0.4 proud) | `Plastic - Matte (White)` |

**Placement.** x is the pedal's own `u/10` from `PEDALS`; the rotation is the
faceplate slope; and the tile centre sits **1.8444 cm forward of the pedal's
back edge** — note the Cherub component's origin IS its back edge, not its
centre, so compare against `occ.boundingBox.maxPoint.y`, never against
`PEDAL_ROW*_V`. Both rows agree on that offset. Row 1 lands at
`y = 10.2695, z = 4.1129`; row 2 (CLEAR, BANK) at `y = 26.6465934, z = 7.7430932`
(#796: row 2 is the row-1 transform plus the slope delta, see "Row 2" below).

```
[1,0,0,u/10 | 0,c,-s,y | 0,s,c,z]      c,s = cos,sin(1.4614 deg)
```

**Orientation is load-bearing (#922).** The tile is a TRAPEZOID — wide edge to
the pedal's cable end, which is +y in the populated frame, and which also
carries the top of the glyphs. Import at identity and the STEP's own +Y already
points that way; do not rotate it about z.

**The window it drops into lives in the OTHER doc.** `Top Pad` in "Cherub
WTB-006 Footswitch" carries sketch `PAD_WINDOW` + feature `PAD_WINDOW_CUT`, and
that sketch holds the pad's own side edges — so the pad's plan taper is measured
there, not inferred from the case. The window is a trapezoid keeping a 5 mm wall
at every station (54.459 back / 53.855 toe); the generator's `TILE_PAD_W_BACK` /
`TILE_PAD_W_TOE` are those pad widths, and the tiles follow. **Change one and you
must change both.** Three traps, all of which produce a confident wrong answer:

1. The sketch has **zero constraints and zero dimensions**, so points move freely
   and nothing warns you that the window no longer relates to the pad edges.
2. Editing it does **not** recompute the body — call `design.computeAll()` or you
   read the old geometry back and conclude the edit failed.
3. The populated doc **keeps serving the stale pad** after the pedal doc is
   saved. `canAdvanceToLatest` is False; the call that works is
   `app.activeDocument.updateAllReferences()`, and the doc must be saved first.
   Until you make it, tile-vs-window checks in the console verify green against a
   window that no longer exists in the source.

**Re-import recipe** (same shape as the board's, above): regenerate with the
generator, delete the ten `tile_*` occurrences, `importManager.createSTEPImportOptions`
+ `importToTarget(root)` per file, rename to `tile_<LABEL>`, re-apply the two
appearances, then set the transform and snapshot. Do it one tile per call — this
doc is heavy, and batching per-body operations is what froze it in #753.

## Row 2 (CLEAR/BANK) placement (#796)

Row 2 sits on the 16" aperture's front edge (generator `PEDAL_ROW2_V`, 235.550893).
Every row-2 member is placed as **its row-1 counterpart's transform plus the
slope delta** `(0, c*dv, s*dv)` with `dv = (PEDAL_ROW2_V - PEDAL_ROW1_V)/10 =
16.7746072` cm, i.e. world `(0, 16.3770934, 3.6301869)`:

| row-2 member | row-1 source |
|---|---|
| `pedals:1+Cherub WTB-006 Footswitch:9` / `:10` | `Footswitch:3` / `:4` |
| `platforms:1+platform_sled_v375:2` / `:10` | `platform_sled_v375:4` / `:5` |
| `tile_CLEAR:1` / `tile_BANK:1` | `tile_UNDO:1` / `tile_MODE:1` |
| `led_diffuser_CLEAR` / `_BANK` | see the diffuser origins below |

The mid pedestal collars are the exception: their HEIGHT follows the row's v,
so they are **re-imported, not moved**. `platform_mid_ring:1` and `:2` under `platforms` are `out/segno_platform_mid_ring.step` placed at
`[0,-1,0,u/10 | 1,0,0,22.996896045412427 | 0,0,1,0.2]` — the row-2 foot-hole centre
(`platform_foot_holes`, v 229.968960) over the floor top, with the same 90 deg turn
as the front collars (whose `y = 6.62` is the row-1 hole centre). Done
2026-09-04; the doc's row 2 had sat 3.96 mm too far back until then.

## LED pill diffusers (populated doc only)

Ten `led_diffuser_*` components under `lid_stack:1+diffusers:1` (current as of
2026-09-04: the 68 x 14 x 6.33 strip-channel part, one per pedal), each an
imported STEP of `out/segno_led_diffuser.step`. They replaced a `led_strips`
component that held six bars as BODIES and had gone stale by a whole revision;
that component is deleted, the strip now lives inside the diffuser channel.

**Placement.** x is the pedal's `u/10`; the rotation is `SLOPE_ANGLE`
(12.498241812070852 deg), not the pedal tilt the tiles use. Row 1 sits at
`ty = 13.619711, tz = 4.240818`; row 2 (CLEAR, BANK) at
`ty = 29.811307, tz = 7.829888` (LED_GAP = 16, the 2026-09-04 trial; at the
old LED_GAP = 12 they were 13.22919 / 4.154255 and 29.420786 / 7.743324).
These are the generator's numbers: the part
origin is on the plate's local z = -0.22 (underside minus a 0.2 mm glue line)
at the pill centre `v = PEDAL_ROW*_V + FSW_SLOT_D/2 + LED_GAP`, DXF
`y = v/10 + 1.21938` (the lip fold line), through the faceplate transform.

```
[1,0,0,u/10 | 0,c,-s,ty | 0,s,c,tz]
```

Those are ORIGIN values, not lens centres. To re-derive them from an existing
body, the lens is centred in x/y and spans z 0..0.24 cm, so
`ty = centre_y + sin(slope)*0.12` and `tz = centre_z - cos(slope)*0.12`.

**Appearance is state, not material.** TRACK1 and TRACK2 carry `LED pill - green`
(shown lit); the rest are `Plastic - Matte (White)`. Preserve that split across a
re-import or the render silently loses its meaning. **Set the appearance BEFORE
the transform**, in its own pass: a loop that set `transform2` and then
`body.appearance` left all ten at identity (2026-09-04) — the same reset the
faceplate recipe warns about.

**The first import into an empty component cannot be transformed.** Setting
`transform2` on it silently does nothing — no exception, the matrix just reads
back as identity, and retrying does not help. Every LATER import into the same
component accepts it normally. Work around it by importing the odd one out last,
or by importing a throwaway first. Related: transform overrides only apply to a
proxy obtained from the ROOT context, so use
`occ.createForAssemblyContext(<root-context parent>)` — setting it on the
occurrence straight out of `component.occurrences` throws
"transform overrides can only be set on Occurrence proxy from root component".

**A failed call can roll back further than that call.** The script error that
tripped the transform rule above restored a `led_strips` occurrence deleted by
the PREVIOUS, successful call — and moved it to a different parent — while
leaving that call's imports in place. Re-read the tree after any failure instead of assuming only
your own changes were undone.

## Vent blackout foam (populated doc only)

`vent_foam` component: four 3 mm black pads glued to the INSIDE of every
vented region so components aren't visible through the slots. World extents
(cm): left wall (0.01, 24.5, 0.7)–(0.31, 37.7, 7.7), right wall mirrored at
x 84.29–84.59 (both with a wedge-sloped top edge kept ≥3 mm under the wall
top), rear wall (2.5, 41.59, 1.7)–(39.9, 41.89, 7.7) — clear of the rear
panel, which starts at x ≈ 42.5 — and floor (25.6, 14.5, 0.2)–(57.6, 19.1,
0.5) between the pedal rows. Interference-checked against every other body
(0 collisions). Physical part: black speaker grille cloth or
open-cell air-filter foam, cut ~5 mm oversize per field and glued at the
PERIMETER only — the vents are the Pi 5's convection path, so no closed-cell
foam and no full-coverage adhesive backing (self-adhesive felt's continuous
glue film is near-airtight even though the felt itself breathes). Not in the
DXFs: it's a soft good cut with scissors, not a fab feature.

## Fabrication geometry must agree

The generated DXFs and final formed native geometry must agree. Intermediate
construction trims are acceptable only when restored to the final cutting
profile. On September 5 the source was corrected to Ø6.5 mm corner reliefs
and 0.15 mm front-end trims; native rear regrowth changed from 2.51 to 2.50 mm.
That revision’s actual base flats had zero missing or extra area against
CUT/VENT plus deferred DRILL. No model-only corner exception is permitted;
repeat the check for the current fully coated revision.
Changes that matter for fabrication belong in `segno_enclosure.py` and both
native documents. Shop tooling acceptance remains separate from digital parity.


## Verified formed STEP release workflow

1. Run `segno_enclosure.py --no-step` to generate the new flats and
   `out/fusion_formed_input.json`.
2. Synchronize BOTH Fusion documents. Check native rules, all feature health,
   post/lid normal gap, front-lip gap, hole registration and relevant component
   intersections. Rebuild in the target document if imported features lose refs.
3. With **VAMP console (populated)** active, run `fusion_export_formed.py` as a
   Fusion script. It compares operation sketches against the current handoff;
   the lid's exact CUT+DRILL union allows the deferred rear-drilling operation
   without changing the nominal geometry. The base's initial CUT sketch predates its
   construction trims, so its final CUT is checked by unfolding instead.
   Bracket CUT construction edges retained for feature history are excluded;
   every active CUT curve and each BEND reference must still match exactly.
   It checks each fold angle/direction/source line, sheet rules and actual
   front through-hole axes, radii and sheet spans, then exports base, lid and
   both handed brackets to `formed/`, with checksums and assembly placements.
   Each of these four native components occurs once. Temporarily
   show the occurrences and bodies during export and restore visibility after:
   Fusion can otherwise return success for an empty STEP of a hidden part.
4. Run the full generator. It rejects stale flats or altered native exports,
   compares all four checksummed native flats with complete CUT/VENT/DRILL geometry
   by planar Boolean subtraction, validates solids and bounds in OpenCascade,
   then builds the fabrication reference assembly: eight made metal pieces plus
   nine purchased shim packs and eighteen purchased head washers (**35 solids;
   seven unique fabricated part stems**). The post, flat rear panel, ring disc,
   nominal shim packs and washer references are generated directly. Shims and
   washers appear in the assembly only; neither standalone reference STEP is
   an additional laser, printing or painting archive member. The full package
   plan remains five ZIPs /88 members.
   Native/STEP volume agreement is checked to 10 ppm (minimum 0.05 mm³), with
   independent 0.005 mm bounds checks: an earlier approximately 936685 mm³ base
   export differed by 2.21 mm³ between the two kernels. Every release checks
   its current native volume. Regenerate all vendor packs in this run.
5. Render and inspect the changed drawings, run the enclosure tests and save
   both Fusion documents. Shop bend/tooling acceptance and first-piece fit are
   separate physical release checks.

The September 4 converter reference is the supplier's **63.7 ×57.6 ×22 mm**
envelope with **53.9 mm pitch**, Ø6.5 ±0.3 mm holes and a hole line 31.3 mm from
the wire-exit edge. It is rotated with its long axis along u and wires toward
-v. Body centres are (372.15,365) and (447.85,365) mm; hole rows are v=367.5.
`electronics:1+buck_converter_10a:1/:2` use translation-only transforms at those
centres and z=2 mm. Each contains one solid from `segno_buck_reference.step`.
The visible housing has approximate cover, ear and fin profiles, explicitly
labelled as a purchased reference. Only its overall envelope and mounting-hole
dimensions come from the supplier image. Use the separate uncut
`segno_buck_envelope.step` for conservative clearance checks; the approximate
housing cannot establish washer, screw-head or cable access.

**September 5 replacement regression:** deleting the old nested converter
occurrence proxies left the original components alive. Fusion renamed the new
blocks `buck_10a (1)`; name-based placement and interference checks then matched
the old nine-body components and moved them outside the enclosure. Explicit
Remove features now remove both obsolete instances and both plain blocks.
There are exactly two `buck_converter_10a` occurrences and no other converter
occurrences in the current assembly. For replacements, retain component
identity, re-query after reparenting, and verify the resulting count, local
geometry, world bounds and mount axes together. A correct transform or an
empty collision result alone does not prove a correct assembly. Recompute,
save and reopen before recording persistent CAD verification.

The measured 354 ×209 mm, 14.7 mm-deep monitor and regenerated stands use the
same floor-bottom/lid-underside datum. Its two mounting holes are 75 mm apart,
76.5 mm above the body bottom. Adapter clearance still needs a physical check.

## Previous full manufacturing pass — 2026-09-05 (historical)

The dimensions and masking process in this paragraph are superseded by the
fully coated disc and plain-text process above. At that revision the ring disc had a secondary **C0.5 (+0.10/−0.00) ×45° underside chamfer**,
where it meets the EC11 body; the laser through-hole remains Ø7.2. Both native
`ring_disc_51_5` components have `EC11_ROOT_CLEARANCE_C0_5_UNDERSIDE`, preserving
their component identities and placements. The straight bore remains 1.5 mm
long at nominal chamfer, and the bore/chamfer were masked. Do not apply that
retired masking instruction to the current disc.
The catalog encoder shoulder differs from the disc seat by approximately
0.00527 mm; evaluate this separately from the removed root-fillet interference.

The generator integrates corner reliefs into the base's closed perimeter,
checks cutting paths for overlap/duplicates, and verifies complete final native
flats for base, lid and both handed brackets. The known lid export is viewed from its
underside, opposite the source's exterior: its explicit view correction is
guarded by source-sketch geometry and signed fold checks; arbitrary mirror
matching is not allowed. Partial `--no-step` runs generate intermediate DXFs,
not metal or painting vendor archives. The current process uses plain-text
precoat machining instructions in `MANUFACTURING.md`, with compensated bores
and postcoat assembly; the old operation-sheet process is superseded.

The final documents were saved and reopened as sheet metal **131** and populated
**343**. Only the panel cutouts and disc chamfer changed in this full-review pass.
All 16 / 413 other occurrences retain their identities, geometry, placement,
visibility and appearances, and every leaf occurrence has bodies. Base/bracket
flat differences are zero; the lid has 0.008358 mm² missing/extra within the
0.01 mm² comparison tolerance, from a pre-existing 0.000273 mm drill-position
residue. Do not describe this as exact zero or move the whole lid to hide it.

## Previous repeated review — 2026-09-05 (historical)

That populated document was saved and reopened at **344**. The existing
`ring_holder24` component and its body were modified in place with two annular
cuts and eight radial ribs. Its volume is **4485.550372 mm³** and its three new
features are healthy (four body features including the original base feature).
The other **414 occurrences** retain their geometry,
placements, visibility and appearances. The sheet-metal document remains **131**;
this holder correction changes no metal geometry or selected board position.
Fresh source/native holder subtraction is zero in both directions. The former
40 Ring 24 contacts are removed, including a check of all 73 board bodies and
bottom-up insertion. The actual printed fit, angular indexing, retention and
light diffusion still require the checks described in the ring-holder section.

## Front support and head washers — current reference

Nine purchased solid-metal shim packs support the front M3 fasteners. The
shared native `front_shim_pack` component has one body named
`PURCHASED_FITTED_FRONT_SHIM_PACK`, with nine occurrences. Its current nominal
construction is `_front_shim_pack_solid()`: **OD 7.0 /ID 4.1 mm**, extruded +Z
by `LIP_BARE_CLEAR` =0.50 mm. This is a purchased assembly reference, not sheet
metal; no fabrication DXF or powder coating is required for the packs.

For each `u` in `FRONT_SCREW_U`, let `g=-DEV90-LIP_BARE_CLEAR`
=−2.410840885 mm and `h=FRONT_SCREW_Z+DEV90` =6.455420443 mm. Transforms
below are row-major, with translations in cm and implicit last row `[0,0,0,1]`:

- Populated: `[1,0,0,u/10 | 0,0,1,g/10 | 0,-1,0,h/10]`.
- Sheet metal: `[-1,0,0,(848-u)/10 | 0,-1,0,h/10 | 0,0,1,g/10]`.

Use the same component for all nine occurrences, preserving identity and
placement. Generated assembly names are `PURCHASED_FITTED_FRONT_SHIM_PACK_1`
through `_9`. The owner fits actual **OD 6.90–7.00 /ID 4.0–4.2 mm** stainless
packs after coating, to the measured painted gap, leaving **0.00–0.02 mm
residual** without lifting or shifting the lid. Number and retain the packs
with edge-only adhesive outside the bearing stack. The earlier OD 6/ID 3.5
bare-fitted/masked-land packs and their old axis height are superseded. No shim
or adhesive enters the coating oven. Qualify the actual coated bearing/clamping
joint; do not claim full planar annular contact merely from bounding boxes.

Eighteen M3 head washers are generated by `_lid_washer_solid()` as purchased
**OD 7 /ID 3.2 /0.5 mm** references. `_lid_washer_matrices(lid)` obtains each
bearing plane and bore axis from the current formed lid, so rear placement
follows the actual lap normal. Names are `PURCHASED_M3_WASHER_FRONT_1` through
`_9` and `PURCHASED_M3_WASHER_REAR_1` through `_9`. Verify these occurrences
against their holes and screw heads after native updates.

The assembly has **eight fabricated pieces +nine purchased shim packs
+eighteen purchased washers =35 solids**. Standalone
`segno_front_shim_pack_reference.step` and `segno_lid_washer_reference.step`
are outside supplier per-part archives; their occurrences are included in
`segno_assembly.step`. Neither belongs in the painting or 3D-print order.

### Saved seam correction — 2026-09-05 (historical)

That verification used **VAMP sheet metal 132** and **VAMP console
(populated)345**, both reopened from the saved cloud files. Populated contains
423occurrences/973bodies; sheet metal 27/27; no empty leaves. The now-empty
`VAMP sheet metal:1` bracket container was removed from the populated design.
Its final handed brackets are root occurrences. The original imported right
bracket history could not be edited in the populated document, so its verified
native sheet-metal component was transferred from VSM as an F3D component;
all three healthy extrusion/conversion/fold features were retained. The left
is a separate component copy with its own handed profile. Neither is a STEP
proxy or an empty component.

Set the final bracket occurrence transforms **after** flat-pattern regeneration:
Fusion can restore an earlier occurrence placement while rebuilding a derived
flat. Verify world bounds and the five rivet axes, save, then reopen and verify
again. The final exported native flats use the positive-Z face at localZ0,
with whole-source parity. The new base ridge features retain the base identity.
The nine front shim occurrences each carry the same one-solid reference body.
See `../../docs/reviews/sheetmetal-release-fixes/seam-fix-verification.json`
for that revision’s source/package hashes and saved-document checks. Previous 131/344
review counts are historical.


## Tight riveted rear joint — September 6, 2026

The selected rear/side faces still had a 0.610842 mm gap after the earlier
ridge correction. The owner chose rivets with a tight, visible joint line.
`BASE_REAR_SEAM_GAP = 0.05` now places each straight side edge at
`BD + DEV90 - T - BASE_REAR_SEAM_GAP = 418.860840885 mm` in the developed
depth datum, extending it 0.560840885 mm. The adjoining R2 upper corner and
R3.25 lower relief remain exact arcs derived from this endpoint.
The shop must dry-fit the straight vertical seams to **0.00–0.10 mm before
riveting and coating**, keeping the chassis square without force and preserving
the bend reliefs. This overrides general tolerances. The separate ridge and
bracket clearances remain as previously specified.

Fresh components use the current generated DXF and the base rebuild recipe.
For the existing bodies, replay the source addition **before the first fold**:
intersect the new outer CUT face with flat bands x=[-100,-3] and
x=[BW+3,BW+100], both y=[416,419] mm. Insert one sketch per band on XY after
`RELIEFS_AND_TRIMS`, before `Fold1`; reproduce its six exact line/arc edges and
Join-extrude -2 mm into the flat blank. The overlap with existing material is
intentional. Resume all five folds, end regrowth, front drilling and existing
ridge features. Restore occurrence poses last, then verify actual native flats.
The two features are `SOURCE_TIGHT_REAR_JOINT_LEFT/RIGHT`. Do not replay these
onto a fresh blank whose CUT already includes them. The populated base retains
its component/body identity, five folds and 16 healthy features. The sheet-metal
source subsequently required a fresh base rebuild because its old derived flat
asset failed to load after saving. A fresh blank includes both source contours
and needs only the 12 extrusion/conversion/fold/regrowth/drilling features.
The verified recovery used the former recipe angle 65.556° for the lap; the
current source specifies 65.55604521958347°. The 45microdegree rounding produces
at most 0.0000114 mm displacement of the nine rear pilot centers and remains
inside the forming-parity tolerance. Future rebuilds use the exact source angle
above. The rebuilt rear-lap seating film is at most 0.000274 mm deep.

For this earlier rear-joint revision, **sheet metal 135 / populated 348** were
saved, reopened and checked. The fully coated revision requires its own checks.
The actual straight-face minimum distance is **0.050001 mm** on both sides in
both documents. Native flats match 107 reference holes with zero missing or
extra area. Rivet axes and all other part geometry/poses are preserved. See
[the verification record](../../docs/reviews/sheetmetal-release-fixes/rear-closure-review.md).


## Seven-inch screen frontward correction — September 6, 2026

The owner requested the module **0.50 mm toward the front along the faceplate**
to correct upper-edge cropping. `S7C_FRONT_SHIFT` moves all four tab bosses and
the fit-jig pilots to y=54.75 / -60.25 mm in the local sloped frame; x remains
-76.80 / 80.30 mm. The tower shell, window, flange and six floor anchors stay
fixed. `S7C_MOD_BB` remains the original tower-shell datum, not the moved module
outline. Do not translate the complete tower and misalign the base holes.

Before the additional fully coated setback, `screen7_module:1` had translation (cm)
`(12.132142857143, 31.957719023312, 7.639889393306)` with its previous rotation.
This is world delta `(0, -0.488151324181, -0.108204827526)` mm; the decal follows
the unchanged module bodies. `screen7_tower:1` remains at
`(11.95714, 32.1676, 0.2)` cm. Its existing base feature holds the regenerated
one-piece tower. The exact source/native solid difference is zero both ways.

Reprint `segno_screen7_fit_test` and check the powered display with all four
mounting screws fitted. The vendor clear window and the screenshot decal are
not measurements of the actual illuminated pixel boundary. Nominal module/tab
seat contact is unchanged by the shift; confirm the physical insert and tab fit.


## Standalone mini-console sleds — September 6, 2026

The cloud `VAMP mini console` document was still a pre-sled reference. It is
now synchronized to the current printed tray/lid source and includes two shared
`mini_console_sled` occurrences. Each sled has two underside M3 insert pilots
at local `(depth,width)=(-30,0)/(30,0)` mm. Print one tray, one lid and two sleds
from this revision. The assembly STEP includes all four solids and is for
review; use the separate parts' supplied orientations for printing.

The mini frame is x across the tray, y rearward, z up. Tray width is
195.292857 mm. Sled occurrences rotate +90° about Z and translate to
`(47.075,66.198026484,10.876139372)` and
`(148.217857143,66.198026484,10.876139372)` mm. Pedal root rotations remain
`diag(-1,-1,+1)`; translations use the same x stations, y=121.133026484 and
z=17.876139372 mm. The lower rubber-pad occurrences are hidden because those
pads must be removed for metal-to-sled mounting. Purchased pedal geometry is
preserved; the simplified case reference does not establish its real screw holes.

The existing tray and lid component identities are preserved. The native lid
body is in its assembled world frame at identity, taken from the current
assembly STEP; the individual lid STEP retains its separate print orientation.
The two LED insert bodies match `segno_led_diffuser.step`. Their translations
are `(pedal_x,138.297150788,44.043433323)` mm with the faceplate's exact
12.498241812° slope, including 0.20 mm nominal glue clearance below the lid.
Do not reuse the old mini's rounded 12.5° slope or pre-sled pedal placements.


These earlier September 6 adjustments were saved/reopened as populated **346**
and mini **13**, with sheet-metal source **132**. The console has since changed
for full coating; these versions do not identify its current release. The mini
is unchanged by the fully coated console work. The mini's rear anchor
stations remain x=8.5 / Wt−8.5 mm; their lid bosses narrow to 8.5 mm in X,
leaving 1.75 mm nominal material around a Ø5 mm insert. Rear locating tabs are
at CX±8 mm. The sled toe follows the lid-clearance plane, while all four upper
and two lower blind insert pilots remain intact. All 27 native mini interface
checks pass after reopen; source regression tests include the closed lid,
current LED inserts and the board-pocket/USB-window envelope.

### Fully coated revision: native-edit checks

Capture occurrence transforms before rolling the timeline back: placement
features may not yet exist at the earlier timeline position. A world-to-local
conversion made after rollback displaced VSM front pilot circles off the sketch
plane; the corrected nine centers were checked against the actual cylindrical
faces, exported flat and saved/reopened document. Use root-context occurrence
proxies for nested placements, restore presentation before all matrices, and
add a pending position snapshot only after completing the placement batch.

New STEP imports require actual solid/topology parity checks, not just volume
or a plausible image. Keep component identities and every unrelated placement,
appearance and visibility value when updating a shared body.

Current fully coated save/reopen proof is **VAMP sheet metal137** and
**VAMP console (populated)350**; mini13 is unchanged. The S16 reference parent
retains identity rotation and translation in mm
`(0, 0.043281931010536845, -0.20897148058419218)`. Its child geometry contains
an existing +0.013710950912 mm Z offset; preserve the compensating parent
offset when applying the additional 0.20 mm normal coating setback. Exported
source/native solids agree and the reference monitor seats on both stands.

The mid collar's live Fusion volume/area were correct. CadQuery reading a
Fusion-exported STEP introduced duplicate internal cap faces even though the
live solid and source agreed. A geometrically equivalent body replacement was
verified and retained; do not alter the finished source shape to compensate for
this STEP-reader artifact. Distinguish live-body evidence from round-trip
reader behavior when diagnosing topology.

The straight-disc revision is saved/reopened at **sheet-metal138/populated351**.
Only the existing `ring_disc_51_5` BaseFeature body changed in each document;
component identity, pose and appearance remain. It is now a straight annulus
OD51.20/ID8.50/T2, without conical faces. The owner-measured washer ID7.25/OD11.85
provides coverage; center before tightening. Earlier versions/chamfer checks
remain historical, and all unrelated geometry is preserved.

## September 8 floor supports — current native state

Saved and reopened: sheet-metal139 and populated352. Both bases were rebuilt
from the current generated DXF using the documented recipe, retaining the
originals until flat-pattern and surface checks passed. Both final flats have
zero missing/extra area against CUT/VENT/DRILL. The rebuilt bases agree with the
prescribed T2/R2/K0.33 folds. Eleven Ø4.8 floor holes were added; no pedestal
clearance cuts were needed. The populated feet group has15 actual one-body
occurrences, including its four originals. All other components, placements and
appearances are preserved; no empty leaves or new warnings were introduced.

Direct old/new solid subtraction hit coincident-surface kernel errors, so that
check is not claimed as passed. Verification instead records full flat parity,
native surface and area accounting, volumes, bounds and prescribed bend checks.
The old sheet-metal document's return angle differed at sub-micron scale; its
new base uses the same source angle as the populated document.

All45 enclosure regressions pass. Current shop archive is only
`out/segno_sheetmetal_STEP_DXF.zip`:7 STEP and7 DXF, seven designs/eight metal
pieces. The feet are purchased parts and do not enter that archive. Older
multi-supplier archives are not the current handoff.

Strength remains unqualified. See the [extra-feet verification](../../docs/reviews/extra-feet/verification.json)
and [temper sensitivity screen](../../docs/reviews/extra-feet/temper-screening.json).
The nominal fit review assumes Ø18×5 feet and Ø9×5 top hardware. Verify actual
retention, access, foot contact and assembled load performance before release.

## Console collar thickness — September 9, 2026

Saved/reopened versions: sheet metal 140 and populated 353. Both console collar
variants now have 2.4 mm front/rear light-baffle walls and 118.47 mm overall depth.
The bore, sled, insert pockets, four chassis axes and seating heights stay fixed.
Source and the four exported STEP/STL files agree with the native collar solids.

Populated components under `platforms` are `platform_front_ring` (8 occurrences)
and `platform_mid_ring_24` (2). The sheet-metal document uses
`platform_front_ring_24` (8) and `platform_mid_ring_24` (2). Its earlier collar
references had stale pre-coating geometry and placement; they now share the
current source geometry and the mirrored populated-model poses. All other
occurrences retain geometry, placement, appearance and visibility. No new feature
warnings or empty leaf components were introduced.

When replacing a component previously moved into a group, `deleteMe()` on its
group occurrence can remove the historical move and restore the old occurrence
at the root. Inspect the root afterwards and remove that obsolete occurrence
too; a group count alone does not prove replacement. Set final transforms only
on occurrence proxies obtained through the root, after all geometry/appearance
changes, and verify the total occurrence count and saved/reopened state.

See [verification](../../docs/reviews/collar-thickness/verification.json) and
[clearance measurements](../../docs/reviews/collar-thickness/clearances.json).
The original mini-console and all sheet-metal output files are unchanged.

## Console cable opening — September 9, 2026

Saved/reopened versions: sheet metal 141 and populated 355. Both collar heights
now use an 8.6 mm centred open-top rear slot, beginning 6.95 mm above the bare
pedal underside (sled top). The reported 7.6 ×11.45 mm feature clears at both
positions implied by the approximate pad-free top/bottom offsets. The open top
preserves insertion of the assembled pedal, sled and attached cable.

Current populated names are `platform_front_ring (1)` (8 occurrences) and
`platform_mid_ring_24 (1)` (2). Sheet metal uses `platform_front_ring_24 (1)`
(8) and `platform_mid_ring_24 (1)` (2); Fusion retained the replacement suffix.

The two native variants match the current STEP source exactly in both Boolean
directions. All 442 other populated occurrences and 35 sheet-metal occurrences
retain geometry and placement. The user hid `pedals:1`, `tile_REC_PLAY:1` and
`base:1` during inspection; those visibility changes remain. No new feature
warnings. The selected collar/faceplate planes measure 0.179998 mm apart.
Only the two collar STEP/STL pairs and printing archive change; the sled, mini
and sheet-metal output files are untouched. All 50 enclosure tests pass.
See [verification](../../docs/reviews/cable-opening/verification.json).

## Closed stadium cable opening — September 9, 2026

Current saved/reopened versions: sheet metal 143 and populated 358. Both
console collars use a closed vertical stadium opening, 8.6 ×13.5 mm overall,
R4.3 mm ends and 4.9 mm straight sides. Lower/upper ends are 6.95/20.45 mm
above the bare pedal underside. Thread the cable end before seating the pedal.
This replaces the previous open-top slot; its rationale is superseded by the
owner's selected assembly sequence. Clearance assumes a stadium-shaped fitting.

Current component names in both documents: `platform_front_ring_stadium` (8)
and `platform_mid_ring_stadium` (2). All other geometry and placements are
preserved. During inspection the owner showed `pedals:1`, `tile_REC_PLAY:1`
and `base:1` again; those choices are retained. Feature warning sets are
unchanged. Only the two collar STEP/STL pairs and printing ZIP change.
All 50 tests pass; exact native parity and file evidence are in
[verification](../../docs/reviews/cable-hole/verification.json).

## Short-screw mid-platform mounting — September 9, 2026

Current saved/reopened versions: sheet-metal v144, populated v360. Each uses
`platform_mid_ring_short_screws` (2 occurrences). Populated additionally uses
`platform_mid_sled_short_screws` (2), replacing only the former tall
`platform_sled_v375:2` and `:10`; the eight front sled occurrences remain. The
sheet-metal document contains no sleds, as before. Front stadium collars remain.

The mid collar now has four bottom-facing Ø4.5 ×6 mm insert pockets at the
original base axes and four Ø3.7 deck bores on a 60 ×36 mm pattern. The new
`segno_platform_mid_sled` has matching lower inserts and the same top pattern,
outer geometry and seating height as the front `segno_platform_sled`. M3×6
base screws and M3×12 deck screws replace the former long combined joint.
Upper assembly/service is performed on the bench before anchoring the module.

Both native collar solids and the populated mid sled exactly match their
source STEP in two-way Boolean comparison. All placements and appearances are
preserved; 448 other populated and 43 other sheet-metal occurrences match their
baselines. Counts remain 452/1002 and 45/45 occurrences/bodies. Feature warnings
remain at eight pre-existing unique-component warnings in populated and zero
in sheet metal. No metal part, mini-console or sheet-metal archive changed.
See [the verification](../../docs/reviews/mid-platform-mount/final-verification.json).
