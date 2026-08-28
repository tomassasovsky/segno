# Segno console — manufacturing package

Everything needed to build one console, grouped by vendor. All enclosure
outputs regenerate from `enclosure/segno_enclosure.py` (run it before quoting —
it also refreshes the vendor quote zips below, so they can never go stale).

The zips are **not tracked in git** (#236): they are per-quote artifacts,
rebuilt with a freshness gate by `build_quote_packages()`. **On each real
vendor order, freeze the record**: regenerate, let the freshness gate pass,
send, then attach the exact zips sent to a git tag / GitHub Release for that
order. The tag is the immutable record of what the vendor received; the
working tree never is.

## 1. Sheet metal (laser cut + bend + powder coat)

Send **`enclosure/out/segno_sheetmetal.zip`** (DXF flat patterns + PDF drawings
for every part) plus **`enclosure/out/segno_sheetmetal_step.zip`** (3D reference
STEPs incl. the folded assembly). The zip carries **metal only** — the printed
overlay is a separate package (section 4).

| Part | Qty | Material | Notes |
|---|---|---|---|
| `segno_base` | 1 | 2.0 Al | ONE folded blank: floor + 4 walls + rear transition. Weld-free (corner brackets rivet). |
| `segno_faceplate` | 1 | 2.0 Al | Sloped lid, full-width blank. Fold conventions in the drawing NOTE (chirality matters). |
| `segno_rear_panel` | 1 | 2.0 Al | Dismountable I/O sub-panel (#751); flat, no bends. |
| `segno_corner_bracket_rear` | 2 | 2.0 Al | Internal L-brackets; ONE part serves both corners (left = flipped). |
| `segno_ring_disc` | 1 | 2.0 Al | Encoder LED-ring centre disc. |
| `segno_post` | 2 | **1.6 CR steel** | Faceplate support posts — **1.6 mm cold-rolled STEEL**, not the 2.0 Al of the shell. |

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
  **not** translated: layer names (`CUT`, `BEND`, `VENT`, `MASK`, `NOTE`,
  `ENGRAVE`, `SILK`) and part stems (`segno_base`, …), because they are the
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

Material: **2.0 mm 5052-H32 aluminium**, K-factor 0.33, R2 tooling (bend notes
on each drawing). `segno_post` is the exception: **1.6 mm cold-rolled steel**.
Finish: black powder coat, outside faces.

**Lid-seam threads (18x M3).** The Ø2.5 pilots on the base front wall and rear
transition are laser-cut, **tapped M3 after bending**, and the threads must be
**masked before coating or chased after it** — powder in a 2 mm-deep thread
binds the screw, and there are only ~4 threads to lose. (The old note here said
"front-lip M4": wrong on both counts since the #762 seam conversion — the lip
carries Ø3.4 *clearance* holes, the base carries the taps, and the size is M3.)

**Lid-to-base fit — READ THIS BEFORE FOLDING THE LID.** In CAD the lid's front
lip lands *flat* against the front wall: lid-to-base minimum distance measures
**0.0000 mm**. Both faces are outside faces and **nothing is masked** (owner
call: coat everything), so as drawn the joint is roughly 0.16 mm of interference
before any tolerance.

The fix is a **fit, not a dimension**: fold the front lip slightly open so that,
**after coating**, the lip inner face clears the front wall outer face by
**0.3 mm** — tight, but it slips on without force. Check it against the finished
base before setting the fold. The same note is on the lid drawing.

## 2. 3D printing (FDM)

Send **`enclosure/out/segno_3dprint.zip`** (STEP + STL for each part).

| Part | Qty | Material | Notes |
|---|---|---|---|
| `segno_platform_front` | 8 | **BLACK** PETG/ASA, ≥40% infill | Pedal pedestal TUB, 115.4×88.8 (deck 13.2, walls to ~37 with sloped top ~0.3 under the faceplate; deck raised for flush-at-rim seating, issue #373 — pedal case top flush with the slot's upper rim, pad above the metal). Perimeter strips outside the slot opening are relief-shaved to the same under-plate plane. Wall inner faces tucked 0.4 behind the slot cut line, so from above only faceplate shows and the reveal reads as a dark channel. Full-height boss drop-in channels in the side walls; 12-wide rear cable notch. Heat-set pilots Ø4.5 from below — the taller deck now takes the standard **M3 5×5 inserts** (4 per pedestal; short M3×3 no longer needed); 1.2-deep pad pocket in the deck. |
| `segno_platform_mid` | 2 | **BLACK** PETG/ASA, ≥40% infill | Tall CLEAR/BANK tub (deck 57.3, walls to 81.1 — row 2 rearward for label-top alignment #366, deck raised for flush-at-rim seating #373), hollow with boss columns — standard **M3 5×5 inserts** (4 per pedestal) + the same pocket, channels, notch and perimeter relief. |
| `segno_led_diffuser` | 6 | **White PLA** | Pill lens, pushes into the faceplate slot from inside. One per *mappable* pedal — TRACK1-4, CLEAR, BANK. REC/PLAY, STOP, UNDO and MODE have no LED: they are fixed transport, so there is nothing to indicate. |
| `segno_pedal_tile_*` | 10 | **BLACK + WHITE** PLA/PETG | Pedal name tiles, one per pedal, dropping into the WTB-006 top pad's window. **TRAPEZOID**, 54.75 (back) / 54.15 (toe) × 19.90 × 2.20 — the pad is a wedge in plan, and the window keeps a 5 mm wall each side at every station, so the tile's sides run parallel to the pad's. **Fit the WIDE edge toward the cable end**; it carries the top of the glyphs, so the wrong way round reads upside down. The pad is a uniform 2.2 slab on a case top tilted to match, so the window is a parallel-sided pocket in depth and the tile is flat in Z. **Print FACE-DOWN with a filament change at z = 0.4**: the glyphs stand proud of the body, so face-down they are the first 0.4 mm off the bed — print that in white, swap to black, flip. One extruder. The letters finish flush with the pad and the black field sits 0.4 mm below it, out of the scuff line. Text is generated from the same `PEDALS`/`SILK_SYMBOLS` source as the faceplate legends, so REC/PLAY and STOP carry the dot+plus+triangle and square rather than words. |
| `segno_ring_diffuser` | 1 | **White PLA** | Annular lens for the encoder LED ring. Cut for the **Ring 24** (Ø67 window); its back-plate radii are hardcoded, not derived — re-derive them with any window resize. |

The Cherub WTB-006 has **no base screws** (one horizontal through-screw per
side): retention = the deck pocket + gravity + foot pressure, **PROVISIONAL**.
The old `rc20_pad` `asp1_pad` casting master targeted the retired ASP-1 pedal
and no longer matches any pedal in this design.

## 3. PCBs

| Board | Files | Qty | Notes |
|---|---|---|---|
| **Console board v2** (`console_board.py`, #747) | `kicad/out_console/segno_console_board_gerbers.zip` (run `route_console_board.sh` to produce) + `kicad/fab/segno_console_board_bom.csv` | 1 | **The console's control board** — Pico 2, MIDI front end, all pedal/panel headers. |
| Main board (`segno_pedal_main`, THT) | `kicad/fab/segno_pedal_main_gerbers.zip` + `_bom.csv` + `_cpl.csv` | 1 | The manufactured V1 — **standalone pedal product only**; the console does not use it. LCSC part map: `kicad/fab/segno_combined_bom_lcsc.csv`. |
| Encoder ring PCB | `kicad/fab/segno_pedal_ring_gerbers.zip` | 1 | Shared by both products. **Ø68 now (was Ø60): re-cut for the Ring 24 (#794)** — a Ø65.5 ring overhung the old board by 2.75 mm all round, and the three M3 holes moved from r=26 in to r=22 so their heads clear the ring's inner edge at r=26.15. **Existing standalone-pedal units built to the Ø60 board have a different hole pattern.** The ring **pin-mounts on J3**, whose four pads sit under its IN/+5V/GND/OUT solder points — coordinates lifted from Adafruit's published board file for the Ring 24, not measured by hand. **J2** remains a flying-wire alternative on the same nets (5V/GND/DIN). R1/R2 (the 5 V encoder pull-ups) are deleted — do not stuff them; bias comes from the MCU side on both products. |
| LED puck (single WS2812B) | `led_strip/segno_led_strip_gerbers.zip` | 6 | 16×8 mm, castellated; or buy off-the-shelf WS2812B modules instead (see `led_strip/README.md`). One per *mappable* pedal — the four fixed-transport pedals carry none. |


## 4. Printed overlay

Send **`enclosure/out/segno_overlay.zip`** (`segno_overlay.dxf` + `.pdf`) to a
label/overlay printer → die-cut adhesive vinyl/polycarbonate top overlay,
846 × 406.6 mm, black field, white legends, die-cut apertures. Replaces all
silkscreen on the metal.

**Not a metal part.** It used to ride inside `segno_sheetmetal.zip` with a title
block reading "2.0 mm 5052-H32 Al, qty 1" — 0.34 m² of aluminium cut and powder
coated for nothing, roughly a third of the metal spend. It now has its own
package and its own material string.

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
- Heat-set inserts: **M3 5×5 throughout** (5.0 long × 5.0 OD, pilots Ø4.5), brass —
  40× console pedestals (4 per pedestal) + 8× mini-console pedestals + 3× mini lid.
  (Short M3×3 obsolete since the #373 deck raise gave the front pedestals full pilot depth.)
- Fasteners: 40× M3×8 (platform bolts, from below), 18× M3×8 (lid seam: front
  lip + rear lap, into hand-tapped Ø2.5 pilots — NO clinch nuts anywhere; the
  old "PEM M4 nuts per drawing" line is obsolete, no drawing carries PEM holes
  or masks any more), 10× Ø3.2 pop rivets (corner brackets), 4× M2.5×35.3 Pi
  risers (stack or turn — 35.3 mm is derived, see `PI_RISER_H`), 4× M3×12 +
  standoffs 15 mm (console board), 4× M4 (buck ears — two bricks, two ears
  each), 4× M4 (support post feet)
- Cabling per **`segno_wiring.md`** (HDMI ×2, USB, the 20 V PD feed + 5 V buck
  runs, the 2×20 keyed ribbon, JST looms)

## 6. Reference (do not send to vendors)

- `enclosure/out/segno_assembly.step` — full folded assembly
- `segno_enclosure_design.md`, `segno_wiring.md` — design + wiring
- Fusion cloud docs: "Segno sheet metal" (native sheet-metal validation) and
  "Segno console (populated)" (full visual assembly + exploded storyboard)
