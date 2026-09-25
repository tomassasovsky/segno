# Strip-fed console ring — all M3 SSD screws, smaller passive PCB

Alternative to the console Ring24 module, around the purchased **50 mm knob**.
Uses the owner's **144 LEDs/m, 12 mm wide, WS2812B GRB strip**. Related work:
[#1075](https://github.com/tomassasovsky/segno/issues/1075), flush stack
[#1063](https://github.com/tomassasovsky/segno/issues/1063).

The strip stands on edge around a continuous cylindrical glue bed, LEDs facing
inward. The white chamber reflects light toward a **0.8 mm white PLA face**;
a black outer housing, top cover, centre disc and removable bottom enclose it
without sheet metal. Only the diffuser annulus is exposed. This is an optical
prototype: improved uniformity, brightness and readable moving ring segments
must be judged with the actual strip. Strong mixing may blur the comet/position
display. The rendering shows geometry, not simulated light output.

## Corrected knob mounting

Use the current files in [`out/`](out/) or regenerate
**`strip_ring_all_m3_print_pack.zip`** using the commands below. All five screws now use the owner's
**M3 × 5 mm under-head length, Ø7 mm flat-under-head SSD screws**. It replaces
the previous pack that still required three M2 countersunk bottom screws. The
**centre disc, diffuser and outer cover share one flat face**. The entire 18 mm knob
body sits above that face with a nominal **0.5 mm running gap**.

An independent lower retaining plate still mounts the encoder at its existing
height. The visible centre disc is a removable cap supported on that plate;
**two M3 × 5 mm SSD screws with Ø7 mm, flat-under-head heads fasten it to integral
posts**. The Ø7.4 mm flat-bottom pockets are 2.6 mm deep, leaving **0.2 mm below
the face for heads up to 2.4 mm tall**. Actual head height still needs checking;
shorter heads sit deeper. The heads are hidden under the knob. The cap is held down
independently of the knob, and the encoder nut remains on its original thread.
The user confirmed a
**50 × 18 mm push-on D-bore knob** and allowed a higher position on its shaft.
At the proposed height, the shaft enters **8 mm from the knob's underside**.
The actual bore depth, entrance recess and gripping length were not supplied:
**8 mm is gross insertion, not verified gripping contact**. Dry-fit the purchased
knob and check secure rotation and push action before bonding the assembly.

The light chamber retains its **7 mm lift**, with the entire nominal LED face
**3.19 mm above the bare PCB**
in the inward light path for both smaller passive board layouts. Their
peripheral components sit beneath the covered centre, away from the optical
annulus. The encoder stays at its existing height.

## Interfaces and knob

- Ø67 mm panel opening; printed lens Ø66.8 mm, bore Ø51.7 mm.
- Lens flush with the **2 mm black printed top cover** and **1 mm black
  centre-cap face**. The cap's skirt reaches the separate lower retainer.
  No metal faceplate or centre disc is needed now.
- Existing #1063 encoder position: **3.5 mm spacer** and **1 mm retainer**,
  board dropped 2.5 mm.
- Ø50 × 18 mm push-on D-bore knob, with its **full 18 mm body above the face**.
  Its 0.5 mm running gap allows the modelled 0.4 mm push; check actual switch
  travel. The shaft and encoder are unchanged; the knob is fitted higher.

The standalone case is **Ø96.6 × 31.8 mm overall**, excluding the knob.
Its flat bottom rests on the bench. Its nominal gap to the screen-bezel boundary at radius
58.6 mm is 10.3 mm; that is a layout envelope check, not a complete current
Fusion assembly clearance certification. The owner is using the **older,
smaller passive encoder PCB**, with its 8-pin
console header. Both documented **Ø60 mm and Ø68 mm** layouts have been checked;
they share the same encoder and mounting height, so one print set fits either.
The preview uses the Ø68 mm board. Its three PCB mounting holes are not used:
the existing encoder nut clamps the assembly. Remove the old LED ring and its
mounting pins/posts before fitting the strip version.

## Print one set

If you already printed the previous **M3-cap** version, **replace the outer
housing (`strip_ring_shield.stl`) and bottom cover**. The other six print parts
are unchanged. Use the new pair together: the screw positions, pilot sizes and
locating rim have changed. If starting from scratch, print one of all eight parts.

The regenerated ZIP has **WHITE** and **BLACK** folders for the STLs, and a labelled
`strip_ring_print_colours.png` showing every part. Individual STEP files are
under `STEP`; the complete assembly is a reference, not one object to print.

The STL files are already oriented on the bed. Import them individually into
OrcaSlicer **without auto-orienting**. STEP files preserve assembly coordinates.
Use a 0.4 mm nozzle, 0.20 mm layers, at least 3 walls and 4 top/bottom layers.
Check Preview before printing; thin optical faces must be solid, with no sparse
infill or modifier holes. These settings are a starting point for the owner's PLA.

| File | Material | Orientation and supports |
| --- | --- | --- |
| `strip_ring_diffuser.stl` | White PLA | Visible face down on a smooth plate. **Supports required** under the recessed centre-disc floor and outer flange. Use build-plate-only supports; paint them under those two regions. Keep the visible annular face on the bed, free of supports. |
| `strip_ring_cup.stl` | White PLA | Broad panel-facing ring down; cylindrical glue wall grows upward. Use build-plate-only supports under the **1.25 mm inward lid shelf** at the centre opening. Paint only that small overhang. |
| `strip_ring_shield.stl` | Black PLA or PETG | Bottom rim down, open end up. Supports off; check the short 8 mm bridge above the rear cable outlet. |
| `strip_ring_top_cover.stl` | Black PLA or PETG | Flat down, supports off. Covers the entire top outside the light ring. |
| `strip_ring_centre_disc.stl` | Black PLA or PETG | Visible face down, skirt and screw pads upward. Paint build-plate-only supports **inside both screw-head pockets**, under their flat ceilings. Clean both bearing surfaces after removal. Print the 1 mm face, 1 mm bearing webs and local pads solid. |
| `strip_ring_encoder_retainer.stl` | Black PLA or PETG | Flat plate down, two posts upward. Supports off. Print the 1 mm plate and posts solid; keep their through pilot holes clear. |
| `strip_ring_bottom_cover.stl` | Black PLA or PETG | Flat underside down, locating rim up. Paint build-plate-only supports **inside the three screw-head pockets**, beneath their flat ceilings. Clean the bearing surfaces; print the 3.6 mm floor and 1 mm webs solid. |
| `strip_ring_encoder_spacer.stl` | Black PLA or PETG | Flat down, supports off. Reuse the existing **3.5 mm** spacer if already fitted. |

Use black filament that is opaque in a lighting trial; print the top and bottom
covers solid (top 2 mm, bottom 3.6 mm). The white cup and diffuser are the only
white parts.
Hardware:

- **Centre cap: two M3 × 5 mm SSD screws**, measured **under the head**, with
  **Ø7 mm flat-under-head heads no taller than 2.4 mm**. These are the owner's
  confirmed thread, length and head diameter; 2.4 mm is the design's height
  limit, not a measurement of the purchased screws. The cap has Ø3.4 mm clearance
  holes; Ø10 mm posts contain Ø2.5 mm through pilots. Nominal thread engagement
  is **4 mm**, with the tips **0.4 mm above the white floor**. Use the 5 mm length;
  a 3 mm screw would leave only 2 mm engagement. Do not substitute longer screws.
- **Bottom: three of the same M3 × 5 mm / Ø7 mm SSD screws.** Flat-bottom
  Ø7.4 × 2.6 mm pockets recess heads up to 2.4 mm tall by 0.2 mm. Each screw
  bears on a solid 1 mm web, passes through a Ø3.4 mm clearance hole and engages
  4 mm of a Ø2.5 mm blind pilot in the outer housing, with 0.4 mm tip reserve.
  The bottom is 1.2 mm thicker downward; the electronics and optical stack do
  not move. **No countersunk screws are used anywhere in this version.**

No inserts or extra nuts are required. Check the actual fit and tighten gently
by hand; printed thread strength is unverified. The head pockets need clean,
flat bearing surfaces. Keep the screws metal: all five
silver screw envelopes in the assembly are references, not print parts.

The diffuser needs supports because its centre-disc floor is recessed **8 mm**
behind the visible ring face. Its longer inner wall joins that floor to the
raised lens. Remove the supports and clean the flange seating surface before
checking flushness. Do not sand the optical face thinner. White PLA is sufficient
for this trial; transparent PETG is not required.

## Assemble and test

Before bonding anything, dry-assemble the encoder, retainer, centre cap and
knob as in steps 7–8. Confirm the purchased knob grips securely at the proposed
height and completes its push action with clearance. The rendering's internal
bore is only an illustrative clearance cavity; it is not a measurement of the
actual D-shaped hole. If the knob is loose or bottoms out before reaching the
intended gap, the measured bore is needed before accepting this print assembly.

1. Dry-fit the diffuser into the white cup. Its flange rests on the inner shelf;
   the two broad panel-facing surfaces should be level. Dry-fit the black sleeve
   over the cup with their wire notches aligned. The radial glue clearances are
   0.25 mm at the lid and 0.20 mm at the sleeve. Resolve fit before bonding.
2. Count **40 LEDs** and cut only at the strip's marked cut lines: nominal length
   **277.8 mm**. The extra **4 mm gap** between its ends is intentional. Confirm
   this length on the actual strip before cutting; density does not establish
   the manufacturer's cutting-pad tolerance.
3. Form the strip once into the curve with the LEDs facing inward, its 12 mm
   width vertical. Do not force a sideways bend. First check that it follows the
   wall without kinking or stressing a package. The nominal neutral bend radius
   is **44.85 mm**; the actual strip's rated bend radius is unknown.
4. With the black sleeve dry-fitted, bond the **full back** to the white
   cylindrical wall. Rest its lower edge on the black sleeve's continuous
   ledge. The model allows **0.20 mm total adhesive thickness**;
   foam tape is too thick. Check the actual tape/backing thickness first. Leave
   the two cut ends apart at the wire notch. Modelled FPC thickness is 0.53 mm
   and LED height 1.6 mm, taken from the existing enclosure reference, not a
   caliper measurement of this strip.
5. Route the three input wires down the **2.8 mm wide internal notch** at the seam. Insulate
   exposed cut pads and solder joints. Add a little adhesive strain relief at
   the internal routing after testing. DIN goes to the start indicated by the arrows;
   leave the end's DOUT unconnected. The electrical strip is a chain, not a loop.
6. Test light with the cup and diffuser seated, then glue their hidden mating
   ledge. Bond the black sleeve in place, aligned at the top; a 0.20 mm nominal
   glue gap remains underneath the white cup. Keep adhesive out of the light
   cavity. Bond the black **top cover** over the cup and housing, centred around
   the lens. Its underside sits at the top of the cup; a thin adhesive film
   avoids raising the cover above the lens. This is the opaque faceplate now.
7. Fit the encoder board from underneath, keeping the **3.5 mm spacer** between
   its shoulder and the **encoder retainer**. Seat this 1 mm lower plate on the
   white diffuser's centre floor, then fit the original washer/nut. Tighten
   gently. The retainer carries the mounting load; check it for flex or creep.
8. Lower the **centre disc/cap** over the shaft and align its two recessed
   holes with the retainer's posts. Its skirt and local screw pads seat on the
   retainer, bringing the face level with the light ring and outer cover.
   Fit the **two M3 × 5 mm SSD screws** and tighten gently until the cap is
   seated without movement. The heads must finish at least 0.2 mm below the face
   for the specified maximum 2.4 mm head height. Confirm
   the cap stays secure **with the knob still removed**. **Do not glue it.**
   Align the knob's D-bore with the shaft and fit the knob with **0.5 mm below
   its underside**, above the complete face. Check secure grip, free rotation
   and full push travel. The knob's whole body stays above the face; it has no
   cap-retaining function.
9. Bring the existing controller link cable out of the **8 × 3 mm rear outlet**.
   Keep the strip wires inside, connected to the controller. Route all wires clear
   of the screw pilots, component leads and base's locating rim. The outlet is
   for insulated wires; feed connectors before closing the base if too large.
   Fit a small piece of opaque soft foam around the wires to block light and
   prevent rubbing. Add internal strain relief; do not pull against solder pads.
10. Seat the bottom cover's locating rim and fit the **three M3 × 5 mm SSD screws**. Their
   heads should finish flush with or slightly below the flat bottom. The closest modelled component
   has about 2.5 mm of floor clearance; actual solder joints and wires need a
   dry-fit check. **Do not glue the bottom cover.**

The case is now closed underneath. For service, **unscrew the bottom cover**.
The opening clears both smaller board outlines. To remove the PCB, remove the
knob, undo the two cap screws, lift the cap, and remove the encoder nut, retainer
and spacer. Disconnect the console header and strip wires as needed, then lower
the board out. These passive boards have no USB connector. The LED strip stays
supported in the cup.

For the eventual metal enclosure, the diffuser still has the original Ø67 mm
window diameter. The visible faces are now coplanar, but the encoder is held
by a separate plate underneath the centre cap. This changes the original metal
mounting stack. This standalone print set substitutes black plastic for the
faceplate and centre disc.
Final integration is a later step; do not add sheet
metal over the printed top and assume the encoder stack will still fit.

## Electronics handoff — not changed by this prototype

This version uses **40 pixels instead of 24**. Firmware pixel count and angular
mapping must change before it becomes the operational console ring. The seam
has a longer LED-to-LED gap, so evaluate both a full ring and moving segments.
The existing brightness/current limit must be reviewed for the larger count;
do not run an unrestricted full-white test on the existing ring supply path.
Use the established current-limited strip test setup for the first optical
trial. No firmware, board wiring, or production enclosure files are modified
by these CAD outputs.

## What is verified

`check_geometry.py` checks actual solids and exported meshes: no open meshes,
one solid per printed part, matching STEP/STL volumes, part/strip/controller
clearance, retainer/cap bearing, coplanar faces, LED spacing, and board-removal
envelopes with the base removed. It also checks opaque roof coverage, the closed
floor, screw clearances, cable outlet and an unobstructed geometric ray from each LED toward
the underside of the optical roof. The full LED face must clear the populated
PCB, and the annular volume above it must be free of board components. A regression
check rejects the old obstructed LED elevation. It also rejects the recessed
knob and checks the complete knob body above the face, cap retention with the
knob absent, pilot-wall and flat bearing-web material, screw/head/tip clearance, tool
access, cap removal after screw removal and a 0.4 mm push envelope. A regression
control rejects a lower plate without the screw posts. The bottom fasteners
also require actual flat bearing webs, thread walls and solid blind-pilot ends;
negative controls reject a thinned web and a through-drilled pilot. These checks prove geometric
clearance, not brightness, actual switch travel, bore depth or push-on retention.

`reference/controller_without_ring.step` is the normalized historical **Ø68 mm
passive PCB**. `reference/controller_60mm_without_ring.step` is the smaller
manufactured revision; both are checked, so identification between them is not
required for this enclosure. `reference/provenance.json` records historical
source revisions, hashes, the unchanged EC11 model/footprint, common mounting
datum and missing-model limitations. The LED module and mounting posts are
absent from these references and must be removed physically. Cable plugs,
solder blobs, strain relief, seam light leakage and adhesive need a physical
check. The encoder stack uses the verified #1063 dimensions.

Regenerate with the enclosure's CadQuery environment (CadQuery, NumPy,
Matplotlib and VTK):

```sh
python hardware/strip_ring/strip_ring.py
python hardware/strip_ring/check_geometry.py
python hardware/strip_ring/preview.py
```

The preview command creates the PNG and ZIP. Print one prototype and check
strip adhesion/bend, wire fit, side leakage, seam shadow, brightness, colour
mixing and moving-segment legibility before making a set or installing it.

Design reference: Adafruit describes flexible NeoPixel strips as
[formable rather than repeatedly flexible](https://learn.adafruit.com/adafruit-neopixel-uberguide?view=all).
This informed the continuous support. It is not a bend-radius specification
for the owner's unbranded strip.

## Relationship to earlier prototypes

This standalone 40-LED housing is the current strip-ring trial. The earlier
#1063 flush lens used a Ring24 module with the manufactured sheet-metal stack;
that production design is not replaced or regenerated by this work. Its encoder
height is the reference for this prototype. The old ring-lens worktree also
contains an uncommitted seven-LED pill channel and a deeper rail-supported
diffuser experiment. Those pill changes were superseded by the later eight-LED
solid-bed pill design and are excluded from this publication. Historical local
prototypes and slicer projects remain preserved separately.
