# Segno console — manufacturing package

Engineering package for one console, grouped by vendor. **Manufacturing release
is on hold** pending shop forming acceptance and first-piece fit; see
`enclosure/RELEASE_REVIEW.md`. The owner approved a 1.2 mm rear panel on
2026-09-05. Short text drafts for the separate metal shop and painter are in
`enclosure/SHOP_REVIEW.md`; no review PDF is intended for either supplier. Enclosure CAD, part drawings and vendor quote bundles
regenerate from `enclosure/segno_enclosure.py` (run it before quoting —
it also refreshes the vendor quote zips below and checks their freshness).
The base uses Ø6.5 mm reliefs, 0.15 mm front-end trims and tight rear vertical
joint lines, with 0.05 mm nominal bare gap on the straight portions. The
generator requires the current source to match the verified native flat before
producing the formed assembly.

The zips are **not tracked in git** (#236): they are per-quote artifacts,
rebuilt with a freshness gate by `build_quote_packages()`. **On each real
vendor order, freeze the record**: regenerate, let the freshness gate pass,
send, then attach the exact zips sent to a git tag / GitHub Release for that
order. The tag is the immutable record of what the vendor received; the
working tree never is.

## 1. Metal shop (laser cutting, bending and assembly operations)

Send **`enclosure/out/segno_sheetmetal.zip`** (DXF flat patterns + PDF drawings
for every part) plus **`enclosure/out/segno_sheetmetal_step.zip`** (3D reference
STEPs incl. the folded assembly). The cutting package contains the seven unique
made metal parts. The assembly also shows nine **purchased front shim packs**
for fitting reference; these are not additional laser-cut or painted parts.
Labels are carried by the individual pedal tiles; there is no faceplate overlay.

| Part | Qty | Material | Notes |
|---|---|---|---|
| `segno_base` | 1 | 2.0 Al | ONE folded blank: floor + 4 walls + rear transition. Weld-free (corner brackets rivet). |
| `segno_faceplate` | 1 | 2.0 Al | Sloped lid, full-width blank. Fold conventions in the drawing NOTE (chirality matters). |
| `segno_rear_panel` | 1 | **1.2 Al** | Flat I/O sub-panel. Owner-approved 1.2 mm stock plus 0.06–0.10 mm coating per face; nominal finished 1.32–1.40 mm. Measure actual finished thickness at CTRL jacks: 1.20–1.50 mm required by NJ6FD-V. |
| `segno_corner_bracket_rear` | 1 | 2.0 Al | Right rear internal L-bracket; use its handed upper profile and STEP placement. |
| `segno_corner_bracket_rear_mirrored` | 1 | 2.0 Al | Left rear internal L-bracket; cut its separate file and mount inverted as shown in STEP. |
| `segno_ring_disc` | 1 | 2.0 Al | Encoder LED-ring centre disc. |
| `segno_post` | 7 | **1.6 CR steel** | Faceplate support posts — **1.6 mm cold-rolled STEEL**, not the 2.0 Al of the shell. |

(The old `segno_screen_bracket` ×8 row is gone deliberately: the screens mount
on printed stands anchored to the base floor (#762), not on sheet brackets.)

This table is the source of truth for quantity and material: `PART_SPECS` in
`segno_enclosure.py` carries the same numbers onto every PDF title block, and the
generator asserts it. Before #775 the drawing writer defaulted both, so every
sheet claimed "2.0 mm 5052-H32 Al, qty 1" — including the steel post, ×2.

### Reading the drawings

- **The sheets are written in SPANISH** (issue #778). The parts are fabricated in
  Argentina and the shop floor reads Spanish, so every instruction a fabricator
  acts on — part notes, bend tables and their footnotes, the layer legend, title
  blocks, mask callouts, the tolerance block — is Spanish. What is deliberately
  **not** translated: layer names (`CUT`, `BEND`, `VENT`, `DRILL`, `MASK`, `NOTE`,
  `ENGRAVE`) and part stems (`segno_base`, …), because they are the
  identifiers inside the DXFs and the zips and are how a printed sheet is paired
  to its file; numbers, units, `Ø ± °` and standard designations (5052-H32, M3,
  K-factor, R2). The title block prints the Spanish part name **and** the stem.
- **Every sheet-metal drawing carries a general tolerance block**
  (`TOLERANCIAS (salvo indicación contraria)`): hole position ± 0,15 mm, hole
  diameter ± 0,10 mm, bend angle ± 0,5°, outside/flat dimensions ± 0,3 mm, and
  dimensions measured across a fold ± 0,5 mm. The last row is the honest one: a
  dimension that crosses a bend stacks deduction, springback and gauge scatter,
  and ± 0,3 mm is not holdable across the base's five folds.
- **Every sheet with folds carries a bend table**: line position, length, fold
  rotation, included angle, direction relative to the drawn face, inside radius
  and the development deduction the flat was built with. The base's five rows are
  printed **in fold order** — transition first while the blank is flat, then
  front and rear walls, then the two sides (their punch has to fit between the
  already-standing walls). The transition fold is **65.556° rotation / 114.444°
  included**, neither 90 nor 180; guess it and the lid's rear lap and its nine M3
  pilots all land in the wrong plane.
- **`CUT` and `VENT` are one and the same operation — both cut clean through.**
  `VENT` is 127 louvres, ~18 425 mm² and ~5.6 m of cut path. It must be in the
  quote; the alternative is a sealed box with a Raspberry Pi 5 inside it.
- **`BEND` lines are fold references only** (`no cortar, no marcar, no rayar ni grabar`).
  There are 3 380 mm of them on the base alone.
- **`MASK` is a no-paint coating mask, never a cut** — red dash-dot, and every
  ring carries its own `NO CORTAR` callout. The Ø20 ring on the base is the M6
  earth-stud bonding land: cut it and the base is scrap and the safety earth is
  gone.

Material: **2.0 mm 1100-H14 aluminium** for base, lid, brackets and ring disc
(Alcast certificate, lot 26E0269 -- the stock was ordered as 1050 and is not);
**1.2 mm aluminium, alloy and temper to be confirmed by the shop**, for the flat
rear panel; **1.6 mm cold-rolled steel** for the posts. The development assumes K=0.33, R2 for folded aluminium and
R1.6 for the posts. The shop must confirm stock temper, gauge and actual bend
development with its tools.
**Current source, exports and native metal models have passed local checks.**
The fully coated fit revision supersedes the earlier broad masking scheme.
See [the release review](enclosure/RELEASE_REVIEW.md) for exact evidence and
remaining supplier/physical acceptance requirements; local checks alone do not
qualify the fabrication and coating processes.

**One metal-shop visit, then a separate painter.** Complete cutting, bending,
bare fitting, every hole location/drilling and deburring at the shop.
Deliver a matched, untapped and unriveted lid/body set with checked bare dimensions.
The owner installs the ten corner rivets before taking the enclosure to the painter,
then manually taps all 32 M3 body pilots after painting: 18 for the lid and
14 for the screen supports.
The owner fits purchased shim packs, felt and seals after coating, then assembles;
Before tapping, clean any paint-narrowed body pilots back to Ø2.5 without moving
the axes or enlarging the underlying metal hole. This pilot cleanup and tapping
are the owner-approved post-paint machining; no other hole changes are planned. The painter
coats all faces, seating surfaces, edges and clearance-hole walls. The working
exception protects defined electrical-bond lands only; the body pilots have no
threads until the owner taps them after coating. No broad seat, collar,
screen, shim-land, disc-edge or general-bore masks remain.

**Lid-seam drilling and threads (18 M3).** Laser only `CUT` and `VENT`.
The nine base-front pilots and all eighteen lid clearances remain `DRILL`,
located after forming and bare assembly, before coating; the rear base Ø2.5
pilots remain CUT. Center/square the bare lid within **±0.15 mm front and rear**,
check the actual pedals, both screens and their current supports, then remove
components to machine the empty chassis. Use temporary hard spacers to hold
the **0.50–0.60 mm bare front gap**, without pulling the lip out of position.

Plain-text drilling datums, viewed from the musician's side: **A is the bare
floor underside; B is the bare left side-wall interior**, measured on straight
faces clear of radii and burrs. Nine front axes from B toward the right, in mm:
**18.34 /119.48 /220.63 /321.77 /422.91 /524.05 /625.20 /726.34 /827.48**,
**±0.10 mm**. Height is **6.455 ±0.10 mm above A**, 0.50 mm below the superseded
front pattern; axes are normal to the front wall. Match-drill Ø2.5 through the
bare front pair. Transfer each rear body pilot with a short guided punch from
inside; confirm access before cutting. Separate the lid, finish **all eighteen
lid holes to Ø4.50 (+0.10/−0.00) before painting** and deburr. Leave the 18 lid
body pilots and 14 screen-support pilots Ø2.5 untapped for the owner to clean
and tap all 32 M3 holes after painting. The lid clearance holes are not tapped.
Coated lid holes must finish **Ø4.30–4.48**. Use an **OD 7 mm M3 washer** under
each head. The enlarged lid bores are sized for the calculated coated seating
shift; this is not permission to move the body thread axes. Complete all other
specified machining in the same visit. No extra machining PDF page is required.

**Pre-coating openings and finished fits.** All numbers are mm. These specific
ranges supersede the old blanket nominal +0.10/−0.00 finished-opening rule.
The finished predictions assume **0.06–0.10 mm local film on each opposed wall**.
Keep the connector centres, supplier fixing pitch and rear-panel/window datum
positions frozen; increasing a cut size must not re-spread the connector row.

| Opening | Before painting | Required finished range |
|---|---:|---:|
| Metal M3 clearances, except lid | Ø3.60 +0.10/−0.00 | Ø3.40–3.58 |
| All eighteen lid clearances | Ø4.50 +0.10/−0.00 | Ø4.30–4.48 |
| Metal M4 clearances | Ø4.60 +0.10/−0.00 | Ø4.40–4.58 |
| Foot clearances | Ø4.80 +0.10/−0.00 | Ø4.60–4.78 |
| Pill lens apertures | 60.40×6.40, R3.20; +0.10/−0.00 | 60.20–60.38 ×6.20–6.38 |
| Ring lens aperture | Ø67.40 +0.10/−0.00 | Ø67.20–67.38 |
| CTRL and selected fuse | Ø12.30 ±0.10 | Ø12.00–12.28 |
| Power switch | Ø19.80 ±0.10 | Ø19.50–19.78 |
| MIDI NYS325 | Ø15.50 +0.10/−0.00 | Ø15.30–15.48 |
| PD coupler | Ø24.40 +0.10/−0.00 | Ø24.20–24.38 |
| USB four flats | 22.80 ×22.80 ±0.10 | 22.50–22.78 across each pair |
| Same USB concentric circle | Ø24.80 ±0.10 | Ø24.50–24.78 |

The USB contour is the intersection of four flats with that concentric circle,
not a rectangle with tangent corner fillets. Rivet bores stay Ø3.3 because the
brackets are riveted before coating; M3 tap pilots and printed holes are not
changed by the clearance table. Check every actual screw pattern with the
mating part, including a gauge that represents the finished opening after paint.
This includes every complete M3/M4 floor, support and foot pattern with its
actual hardware; a screw fitting a bare hole does not establish coated fit.
General ±0.15 mm position tolerance alone does not guarantee a minimum-clearance
multi-hole fit. Use the specific drilling/pattern requirements where they govern.

At the PD connector, retain **at least 1.20 mm of measured bare metal between
the main bore and either fixing bore**, with undamaged edges, after all fitting;
this local acceptance overrides general diameter/position tolerances. Confirm
both M3 fasteners and the actual coupler barrel fit together. The nominal
geometry leaves 1.205 mm at diameter maxima before position error, so inspection
of the actual local web is mandatory. The shop must qualify its cutting process
on the actual 1.2 mm stock and a representative coupon before the panel. This
is a specific accepted geometry subject to shop validation, not a universal
laser rule: [SendCutSend's DFM guidance](https://sendcutsend.com/wp-content/uploads/2025/11/5.2.pdf)
explains that hole-to-edge limits depend on geometry and tested process.

For CTRL, the [Neutrik drawing](https://www.neutrik.com/media/8599/download/nj6fd-v-2.pdf?v=1)
requires **at least Ø12.00** and **1.20–1.50 mm finished panel thickness**;
Ø12.10 was a project maximum, now superseded. Verify both actual caps latch
and retain at the finished thickness. The [REAN NYS325 drawing](https://www.rean-connectors.com/media/14524/download/NYS325.pdf?v=1)
specifies a Ø15±0.20 barrel, so the wider finished MIDI opening accommodates that
variation. Power/fuse are still subject to the actual selected connector/nut
check; the source's generic product envelopes are not an exact SKU tolerance.

**Front support after painting.** Fit nine flat, deburred stainless **solid-metal
shim packs, OD 6.90–7.00 mm and ID 4.0–4.2 mm**, between the actual painted front
faces. Purchase suitable dimensions; do not rely on a washer trade name to
establish bore or thickness. Select solid layers after full cure to leave
**0.00–0.02 mm residual at each station**, without lifting or shifting the lid.
The nominal 0.50 mm CAD pack is only an assembly reference, not a purchase
thickness. Do not reuse the former pre-fitted bare packs or remove coating from
the bearing lands. Number packs 1–9 and record their measured thicknesses.
Use edge-only retention outside the bearing faces and bore, keeping each pack
with the base when the lid lifts off. No adhesive between shim layers or on the
lid. No shims or retention adhesive enter pretreatment or the oven. Qualify
clamping and coating durability using the actual painted joint; steel screw
torque tables do not qualify M3 threads in 2 mm 1100-H14 aluminium.

**Encoder disc: laser cut, no chamfer.** Bare outside diameter **51.20±0.05**
and straight through-hole **Ø8.50±0.05**. Deburr without a specified bevel;
coat the bore and all faces. Finished bore is **Ø8.25–8.43**, outside diameter
**51.27–51.45** under the stated film range. This replaces the earlier Ø7.50
bore and C0.60 underside chamfer; no secondary chamfer operation is required.

The owner identified an EC11-E15 encoder and measured its washer at **ID7.25 /
OD11.85 mm**. With a modeled Ø7 bushing, conservative opposite bore/washer
movement leaves at least **0.87 mm** radial coverage around the largest finished
hole (0.75 mm on the largest bare hole). The smallest finished bore clears the
modeled Ø8 root when centered. Center the disc in the holder before tightening
the original washer/nut; the enlarged bore is a clearance hole, not a locating
fit. Keep the existing thickness, encoder/knob positions and fastening stack.
Check actual clamping, push-button action and free knob rotation during assembly.

**Separate coating handoff.** Finish is **smooth matte black powder coat,
RAL 9005, without texture**, **60–100 µm on every coated face and clearance
bore wall**. Confirm pretreatment, local film control and a representative
coated fit coupon before the actual parts. Protect defined electrical-bond
contacts; the untapped M3 pilots are cleaned and tapped by the owner afterward. Coat all
other hidden and visible seats and edges; no screen/collar/shim masking map is
needed. Do not coat the metal assembly closed: removable parts are separated,
while the permanently riveted brackets remain assembled. Remove all electronics,
printed supports, shims and adhesive before treatment. The painter gauges the
finished sizes/profile and the CTRL-panel thickness; an exterior flat-face
film measurement alone does not establish coating inside the holes.

**Finished assembly acceptance.** Center the coated lid within **±0.15 mm at
both front and rear**, test all eighteen screws together, and require free
removal/re-seating with no forced deformation. The fully coated front gap must
be **0.15–0.60 mm**; fit each shim to that measured gap. Seat the current printed
collars and screen supports on the coated floor; their revised relief/setback
accounts for the paint instead of preserving bare contact patches. Fit felt
at the post pads and the selected seals only after measuring finished gaps;
none may lift the lid from its seats. Owner cleanup includes restoring paint-narrowed body pilots to Ø2.5 and cutting
all 32 M3 body threads (18 lid and 14 screen-support fixings). No other planned hole enlargement or paint removal from
functional seats follows coating. Fit/coupon failure returns for correction
before release rather than becoming an unplanned owner machining operation.

Keep the straight rear vertical joints at **0.00–0.10 mm bare gap**, nominal
**0.05 mm**, before riveting/coating. Preserve square walls and the required
corner/bend reliefs, **0.30–0.40 mm normal bare ridge clearance**, and
**0.20–0.40 mm vertical bare bracket-top clearance** in the specified seam region.
Confirm tools and trial-bend development before cutting the full set.

**Buck converters.** Supplier dimensions are 63.7 ×57.6 ×22.0 mm, mounting
pitch 53.9 mm, with the hole line 31.3/26.3 mm from the short-axis edges. Mount
with wires forward (-v) and the hole line 2.5 mm rearward of the body centre.
Both converter bodies are centred at v=365 mm, 6 mm rearward of the former
position, clearing the screen stand flange. Their Ø6.5 ±0.3 mm ears use M4 hardware with Ø12 mm washers; the base holes
remain M4 clearance. The dimension source is `enclosure/reference/buck_dimensions.png`.

**Support posts and monitor.** The posts use true R1.6 bends in 1.6 mm steel,
with 1.2 mm nominal normal clearance to the bare lid and a calculated
0.925–1.163 mm after the specified coating on all relevant surfaces. Measure the finished assembled gap and fit the felt without lifting
the lid off its coated seats. Their foot-hole row is at v=148.997 mm. The 15.6-inch monitor
reference uses the measured 354 ×209 mm body, 14.7 mm maximum depth and the
75 mm pair of mounting holes; use the regenerated left/right stands with it.

**Formed references.** The STEP package contains all seven unique made parts and
an assembly with **eight made metal pieces, nine purchased shim packs and
eighteen purchased head washers (35 solids)**. The shim occurrences are named
`PURCHASED_FITTED_FRONT_SHIM_PACK_1` through `_9`; their separate reference STEP
is not in the per-part supplier package. The eighteen
`PURCHASED_M3_WASHER_FRONT_1`/`_REAR_1` through `_9` occurrences likewise appear
only in the assembly; `segno_lid_washer_reference.step` is outside fabrication,
printing and painting archives. The five archives still contain 88 members.
The base, lid and rear corner brackets come
from verified native Fusion folds, tied to the current DXF geometry and sheet
rules. See `enclosure/FUSION_MODELS.md` to regenerate them after geometry changes.

## 2. 3D printing (FDM)

Send **`enclosure/out/segno_3dprint.zip`** (STEP + STL for each part).

The fully coated console uses 0.15 mm normal relief on the collar hard rims
and the sled's outer rim, plus 0.20 mm additional screen setback. Floor fixing
axes remain fixed. Print the revised collars and matching sled variants,
seven-inch tower and both large-screen stands from one matching revision;
previous bare-fit prints are
not qualified against the newly coated seats. The separate mini-console is
unchanged by these console paint allowances.

| Part | Qty | Material | Notes |
|---|---|---|---|
| `segno_platform_front_ring` | 8 | **BLACK** PETG/ASA, ≥40% infill | Front-row collar, paired with the separate sled below. Four chassis screws clamp collar, sled and base together. |
| `segno_platform_mid_ring` | 2 | **BLACK** PETG/ASA, ≥40% infill | Taller CLEAR/BANK collar. Four bottom inserts anchor it to the base; four separate deck screws retain its dedicated mid sled. |
| `segno_platform_sled` | 8 | **BLACK** PETG/ASA, ≥40% infill | Front-row sled. Bolt the pedal to it on the bench, then lower the complete unit into the front collar. |
| `segno_platform_mid_sled` | 2 | **BLACK** PETG/ASA, ≥40% infill | CLEAR/BANK sled with a separate 60 ×36 mm lower insert pattern; use only with the matching short-screw mid collar. |
| `segno_led_diffuser` | 10 | **White PLA** | Pill lens on a 4 mm shoulder, pushes into the faceplate slot from inside; **the shoulder is GLUED to the faceplate underside**, so keep that face clean. 68 × 14 × 6.33. **Print LENS-DOWN** — the lens face is then the bed face, with no layer lines across the light; a TEXTURED bed frosts it for free. ⚠️ Lens-down also makes the shoulder a **4.1 mm-per-side unsupported step** onto the glue face, and the retaining lips cantilevers over open air; **slice it before printing ten** and decide whether that face takes support (support marks land on the glue seat) or the part goes on its side instead. An **8-LED, 55.56 mm segment of 144 LEDs/m bare IP20 12 mm strip** snaps into the channel on the back: **bow it slightly, drop it past the lips, let it flatten**. Its own adhesive is useless — the LEDs face the lens, which turns the tape to face away into the console. The strip is the spring; nothing printed flexes. Grip 0.4 mm per edge; both ends open for the 3 wires. One per pedal — all ten since #930 restored the four transport pills #792 had removed.
| `segno_pedal_tile_*` | 10 | **BLACK + WHITE** PLA/PETG | Pedal name tiles, one per pedal, dropping into the WTB-006 top pad's window. **TRAPEZOID**, 54.36 (back) / 53.76 (toe) × 19.90 × 2.20 — the pad is a wedge in plan, and the window keeps a 5 mm wall each side at every station, so the tile's sides run parallel to the pad's. Both widths are derived from the pad measured in the Cherub Fusion doc (window 54.46 / 53.86, less 0.05/side). **Fit the WIDE edge toward the cable end**; it carries the top of the glyphs, so the wrong way round reads upside down. The pad is a uniform 2.2 slab on a case top tilted to match, so the window is a parallel-sided pocket in depth and the tile is flat in Z. **Print FACE-DOWN with a filament change at z = 0.4**: the glyphs stand proud of the body, so face-down they are the first 0.4 mm off the bed — print that in white, swap to black, flip. One extruder. The letters finish flush with the pad and the black field sits 0.4 mm below it, out of the scuff line. Text is generated from the same `PEDALS`/`SILK_SYMBOLS` pedal-label schedule, so REC/PLAY and STOP carry the dot+plus+triangle and square rather than words. |
| `segno_ring_diffuser` | 1 | **White PLA** | Ø67-window lens and disc holder for the selected PR #990 Ring 24 on its 2.54 mm pin strip. The open-bottom cavity has eight 1.2 mm ribs in verified component gaps, a 0.25 mm shelf and a 1.05 mm lens roof. Nominal minimum PCB clearance is **0.135 mm**, LED clearance 0.332 mm; qualify one actual print and its light diffusion before ordering a set. Orient and dry-fit it as described below before gluing. |

**Ring-holder orientation and fit.** The ribs make this part rotationally
indexed. Use the [top-view alignment reference](enclosure/reference/ring24_orientation.svg):
holder +X points toward the 15.6-inch screen, with the PCB/encoder in the
selected Fusion orientation. The view from underneath is mirrored. Present the
complete Ring 24 board upward from below before gluing the holder; all eight
ribs must enter unoccupied gaps between LEDs and small components. Do not glue
the holder at an arbitrary rotation or force the PCB against its shelf. Fit the
finished 51.27–51.45 mm disc, verify the real header stack and unobstructed
insertion/removal, then check nut clamping, holder retention and light diffusion.
The minimum nominal PCB gap is small enough that printer and purchased-part
variation must be checked on the actual assembly; CAD alone does not qualify it.

Console collar update, September 9: the front and rear light-baffle walls are
2.4 mm thick, growing outward to an overall depth of 118.47 mm. The sled bore,
pedal seating heights and metal-base fixing positions retain their previous
dimensions. The front collar and front sled keep their existing mounting.
The tall CLEAR/BANK collar now has four blind Ø4.5 ×6 mm insert pockets opening
at the bottom of its columns, at local X = ±48.685 mm, Y = ±22.1875 mm. Four
separate Ø3.7 mm deck holes at X = ±30 mm, Y = ±18 mm connect it to the dedicated
mid sled. The metal holes and mini-console are unchanged.


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
collars base-down and sleds flat-bottom-down. Support the tall CLEAR/BANK
collar's hollow underside ceiling; inspect and avoid unnecessary support
inside the collars' or sleds' blind insert pockets. Keep a brim optional
according to actual corner adhesion. The first-print archive,
`enclosure/out/segno_first_prints_STL.zip`, contains four STLs: one front collar,
one mid collar, one front sled and one mid sled. Print one of each at 100% scale
and test both assemblies with the actual M3 Ø5 ×5 mm inserts, screws and cable
before batching. These settings and CAD clearance checks do not establish an
assembled stomp-load rating.

For CLEAR/BANK, install the inserts, bolt the pedal to its sled on the bench
and close the pedal case. Thread the cable through the closed stadium opening,
seat the sled, then drive four M3×12 screws upward through the 8 mm deck from
the collar's open underside. Mount that complete module to the bottom metal
base with four separate M3×6 screws. To service the sled joint, release the
base screws and remove the complete module first; the deck screws are not
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
| **Console board v2** (`console_board.py`, #747) | `kicad/out_console/segno_console_board_gerbers.zip` (run `route_console_board.sh` to produce) + `kicad/fab/segno_console_board_bom.csv` | 1 | **The console's control board** — Pico 2, MIDI front end, all pedal/panel headers. |
| Main board (`segno_pedal_main`, THT) | `kicad/fab/segno_pedal_main_gerbers.zip` + `_bom.csv` + `_cpl.csv` | 1 | The manufactured V1 — **standalone pedal product only**; the console does not use it. LCSC part map: `kicad/fab/segno_combined_bom_lcsc.csv`. |
| Encoder ring PCB | **Console procurement revision must be frozen before ordering** | 1 | The populated Fusion console uses the owner-selected **Ø80 PR #990 assembly**. The Ø68 `kicad/fab/segno_pedal_ring_gerbers.zip` in this checkout belongs to another revision and is **not approved here for this console**. Select the matching board/holder files and physically verify the EC11 nut, washer and glued holder stack before electronics procurement. This sheet-metal review does not release PCB fabrication. |
| LED puck (single WS2812B) | `led_strip/segno_led_strip_gerbers.zip` | 0 | **NOT ORDERED for the console.** Owner call 2026-08-28: the indicators are eight-LED segments cut from a **144 LEDs/m bare IP20 strip**, and the diffuser channel is sized for that (**12 mm wide, 0.53 thick**, 56.96 long), not for this 16×8 board. The design is kept because it is finished and the footprint may suit another build — but ordering it will not fit the current diffuser. |


## 4. Pedal labels

The individual pedal tiles carry every pedal label. No full-face adhesive
overlay or separate overlay supplier package is required.

## 5. Purchased parts

Full lists with links: **`segno_console_shopping_list.md`** (console) and
**`segno_pedal_shopping_list.md`** (board THT parts). Headlines:

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
| CLEAR/BANK collar inserts | **8 M3 heat-set inserts**, 5.0 mm long ×5.0 mm OD | Four from below per tall collar, in Ø4.5 ×6.0 mm blind pockets in the column feet. These are additional to the 80 sled inserts, giving 88 inserts across the console's pedal platforms and sleds. |
| Front-row collars and sleds → base | **32 M3×8 screws**, nominal | Four per pedal, driven upward from under the base. Bare stack to the insert is 2.000 +2.043 = **4.043 mm**, giving 3.957 mm nominal insertion before coating, washers and insert recess. Confirm engagement and head clearance on the finished assembly. |
| CLEAR/BANK collars → base | **8 M3×6 screws**, nominal | Four per collar, driven upward through the existing holes in the 2 mm bottom metal base into the collar's bottom inserts. Nominal bare insertion is 4.0 mm, reduced by coating, any washer and insert recess. Check the finished stack, head clearance and blind screw-tip clearance. |
| CLEAR/BANK sleds → collars | **8 M3×12 screws**, nominal | Four per sled on a 60 ×36 mm pattern, driven upward through the 8 mm deck before mounting the module to the base. Nominal insertion is 4.0 mm before any washer or insert recess. Screw heads and straight driver access are in the open underside cavity. Check the actual hardware and remove the complete module for service. |
| Pedals → sleds | **40 M3 screws; measure before ordering** | Four per pedal, driven from inside the opened pedal into the sled's top inserts. Remove the lower rubber pad. Measure the real pedal base thickness, head-bearing surface and permitted insertion; close the supplied pedal case on the bench before lowering it into the collar. Reuse the pedal's original case fasteners. |
| Lid → base | **18 M3×8 ISO 7380-1 button-head screws and 18 OD 7 mm M3 washers**, screw length nominal | Nine front plus nine rear, into the base's tapped M3 pilots. Verify the final coated fit, thread engagement and screw-tip clearance. No clinch nuts. |
| Front lid lip → base, between painted bearing faces | **9 fitted solid-metal shim packs**, individual-layer quantity depends on finished gaps | Flat stainless, OD 6.90–7.00 mm, ID 4.0–4.2 mm. Fit after coating to 0.00–0.02 mm residual with the lid seated; nominal 0.50 mm STEP thickness is reference only. Record thicknesses and stations 1–9; edge-only retention, no coating removal or adhesive in the bearing stack. |
| Rear corner brackets → base | **10 Ø3.2 mm blind rivets** | Five per bracket. Select material, head and grip range with the shop for the approximately **4 mm bare stack** of two 2 mm aluminium sheets. Owner installs before coating; shop supplies matched holes and checks setting-tool access. |
| Support-post feet → base | **4 M4 screws, 4 nuts and washer sets; measure before ordering** | Two per post. Bare metal stack is **3.6 mm**; add both parts' coating, washers and the selected nut. Nuts are under the floor. Check that the ends and hardware remain above the feet's floor-contact plane. |
| Screen stands → base | **14 M3 screws and 14 bearing washers; confirm length before ordering** | Six for the 7-inch tower and four for each 15.6-inch stand. All flange holes pass through **5 mm of printed material** into M3 threads in the 2 mm base. M3×8 is a candidate with a thin washer; verify full engagement after coating without the tips touching the supporting surface. |
| 15.6-inch stand splice | **2 M3 screws, 2 nuts and bearing washers; measure before ordering** | The two printed halves have clearance holes and need nuts, not heat-set inserts. Measure the actual lap and washer stack and verify access below the bridge. |
| 15.6-inch monitor → stands | **2 M4 screws and 2 Ø12 mm bearing washers; measure before ordering** | One horizontal pair at 75 mm pitch. The stand has Ø9.3 float holes. Measure the monitor's real blind-thread depth and allowed insertion, plus the printed bearing stack; the reference model's 6 mm blind holes do not establish the purchased monitor's limit. Verify washer support at the chosen adjusted position. |
| 7-inch monitor → tower | **4 M3 screws and 4 compatible threaded inserts; measure before ordering** | The current tower has **Ø4.0 ×5.0 mm counterbores** above Ø2.6 pilots. These are different from the sled's Ø4.5 pilots: do not order the sled's Ø5 inserts for this joint without a validated fit. Select/test the insert and screw against the actual tabs and available depth; source comments suggesting M3×8 are not a measured fastener stack. |
| Console board → base | **4 M3 female/female standoffs, 15 mm body length, plus 8 M3 screws; measure screw lengths before ordering** | Four floor-side and four board-side screws. Include any washers in the length check and preserve the specified H1 electrical bond. If the supplied standoffs are male/female, replace the four floor-side screws with the matching nuts instead; the installed height stays 15 mm. |
| N07 / Raspberry Pi → base | **4 M2.5 female/female standoffs, 12 mm body length; 4 M2.5 male/female extenders, 6 mm body length; 8 M2.5 screws** | Four screws secure the lower standoffs from below and four secure the Pi from above. The extenders pass through the N07 board into the lower standoffs. Confirm the supplied kit's thread lengths and avoid bottoming in its blind threads. **35.3 mm risers are not used.** Retain the N07 kit's separate SSD-retaining hardware. |
| Buck converters → base | **4 M4 screws, 4 nuts, 4 Ø12 mm ear washers and floor-side washer sets; measure before ordering** | Two fixing points per converter, through its Ø6.5 ±0.3 ears. Measure actual ear thickness, washer-bearing area, insulation if required and tool access. The approximate housing STEP does not qualify these washers. Check the completed underside stack against the foot height. |
| Rear I/O panel → base | **4 M3 screws, 4 nuts and washer sets; measure before ordering** | Bare sheet stack is **3.2 mm**, plus coating and washers. One specified PANEL_BOND joint must make electrical contact at its masked land; preserve that joint when selecting hardware. |
| PD and MIDI connectors → rear panel | **6 M3 fixing sets**, each screw plus matching nut as required by the purchased part | Two for the PD coupler and two for each of the two MIDI sockets. Confirm the real flange thickness, screw-head style, washers and whether matching fasteners are supplied before choosing lengths. |
| Other rear connectors | **2 NJ6FD-V caps; 2 USB bulkhead retaining nuts; 1 power-button nut; 1 fuse-holder nut** | Use the matching hardware supplied for each purchased connector. The USB apertures must follow the owner's verified four-flat profile; verify all finished openings against the purchased parts. The CTRL caps require the specified finished panel thickness. |
| Rubber feet → base | **15 mechanical foot-fixing sets; measure before ordering** | Four original corner feet plus eleven additions: four front, four rear and three staggered near CLEAR/BANK and the steel posts. Screws enter from inside through Ø4.80 pre-coating floor holes. The clearance review assumes Ø18 ×5 mm feet and top screw/washer envelopes no larger than Ø9 ×5 mm. Check the actual retention method and screw-tip recess; the modeled washer insert does not establish a thread. Fit before installing the screen supports, check access, and verify loaded floor contact. This count does not imply equal load sharing or a strength rating. |
| Encoder / ring assembly | **1 matching EC11 bushing nut and washer; supplied knob retaining hardware** | The EC11 nut clamps the centre disc into the holder; the holder's outer land is glued to the faceplate underside. Verify this assembled retention and the knob's underside relief. Fusion deliberately uses the owner's PR #990 Ø80 board without mounting holes, as recorded in `enclosure/FUSION_MODELS.md`; the checked-in Ø68/three-hole PCB is a different revision. Reconcile the electronics order with that chosen revision; no three-M3-screw set is implied for the native assembly. |
| Chassis bonding | **1 M6 stud fixing set**, with the nuts, locking washers, lugs and straps required by the agreed bonding arrangement | Select the complete stack and its length against the actual lug arrangement and verify continuity. Keep the defined rear-panel bond; do not add parallel grounding connections by assumption. |

The split CLEAR/BANK joints add eight screws and eight inserts to the previous
console mounting arrangement. No long through-screws are required.

Before releasing the remaining lengths, measure the front chassis, mid chassis
and mid deck screw stacks, pedal bases, monitor threads, 7-inch tower insert
fit, converter ears, feet and
selected standoff threads. Confirm the ring-board retention and chassis-bonding
hardware as assembled. All hardware below the base must clear the supporting
surface with the actual feet fitted.

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
- Fusion cloud docs: "Segno sheet metal" (native sheet-metal validation) and
  "Segno console (populated)" (full visual assembly + exploded storyboard)
