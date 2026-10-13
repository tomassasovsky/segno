# Tall pill with a flush panel lens and supported LEDs

For [#1074](https://github.com/tomassasovsky/segno/issues/1074): an eight-LED,
144/m WS2812B strip, confirmed by the owner to be **12 mm wide**. The strip is
bonded to a full solid bed. The same lens and LED carrier work first with a
removable black bench collar, then under the manufactured sheet metal.

**This corrected set replaces the earlier flat, recessed bench cap. Do not mix
parts from the two sets.** The original 60 × 6 mm panel cutout and 68 × 14 mm
mounting footprint are preserved. All added depth goes inside the enclosure.

The owner printed the revised pill and reported much better light on
2026-09-23. For mounting it behind the existing printed pedal cradles before
the metal enclosure arrives, use the [angled friction-fit cradle housing](PLATFORM_MOUNT.md).
Its two black parts reuse the white lens; the bottom is an integral LED
carrier with retaining walls. Use fit revision 2 with deeper platform grips
and a friction closure. It replaces the rejected snap housings and fits the
pinned 2.4 mm rear-wall reference. The revised housing still needs a physical
fit trial. The three-part bench/panel set below is a separate mounting option.

## Preview the animation

Open [simulator.html](simulator.html) directly in a modern browser. It includes
breathing, steady-on and off states, a shared peak at LEDs four and five,
adjustable end falloff, colour, brightness, cycle length and diffusion. It
works without a server or device connection. Its visual blending is illustrative;
it does not establish filament transmission or predict measured brightness.

## Print three parts

| Part | File | Material and print orientation |
|---|---|---|
| Carrier with full glue bed | [Base STL](out/tall_pill_base.stl) | Black PLA; flat floor down |
| Flush lens and mounting flange | [Diffuser STL](out/tall_pill_diffuser.stl) | White PLA; wide flange down, narrow lens up |
| Temporary bench collar | [Mask STL](out/tall_pill_mask.stl) | Black PLA; bezel face down |

The STLs already have the correct orientation and their lowest face at Z=0.
Start with a 0.4 mm nozzle and 0.2 mm layers. Check the sliced preview:

- The 2 mm floor must be solid beneath the entire strip and its end pads.
- The white optical face is 0.8 mm, or four solid layers. Its first layer is a
  **4.2 mm bridge across the narrow dimension** of the lens cavity. Set bridge
  paths across that short span, not along the roughly 58 mm length. Keep support
  out of the optical cavity; this short bridge must be checked on the first print.
- Four seating pads stand 0.2 mm above the mounting flange. Preserve these pads;
  they control the flush height and glue space under the metal.
- The carrier walls are 0.7 mm and carry no PCB weight; its full floor does that.
  The black collar walls are 1.6 mm. Confirm the slicer includes every thin wall.

The carrier and collar need no supports in their supplied orientations. Unlike
the old short holder, there are no lips gripping or suspending the LED strip.

In **OrcaSlicer**, with the supplied diffuser's long axis along X, use
**Strength → Advanced → Bridge infill direction → External: 90°**. Leave
**Relative bridge angle** and **Align infill direction to model** off. Zero
means automatic; it can choose the long span. Re-slice and check the first roof
layer at **Z=2.8 mm** with 0.2 mm layers: the bridge strokes must cross the short
gap. Recheck after rotating the model. This direction was verified in OrcaSlicer
2.4.1's generated diffuser paths. A later two-wall slice still showed
insufficient support beneath the bridge ends. Reducing the diffuser to one wall
was suggested but not applied or verified by the agent. Check anchoring to the
previous layer; direction alone does not establish a printable bridge.
See [OrcaSlicer's bridge direction settings](https://www.orcaslicer.com/wiki/print_settings/strength/strength_settings_advanced).

[Bench assembly STEP](out/tall_pill_assembly.step) shows the three assembled
parts. [Sheet-metal reference STEP](out/tall_pill_panel_reference.step) replaces
the collar with a local coupon of the actual panel thickness and opening. These
assembly files are references, not combined objects to slice. Individual STEP
files are alongside the STLs.

## How the flush mounting works

The white lens has a **59.8 × 5.8 mm nose** that enters the existing **60 × 6 mm
slot** from underneath. Its wider **68 × 14 mm flange** stays behind the sheet.

The mounting flange is the Z=0 datum. Four pads project to Z=0.2, defining the
sheet underside and the existing 0.2 mm adhesive space. The 2 mm sheet therefore
ends at Z=2.2; the lens face also ends at Z=2.2. The face is **nominally flush**,
not recessed or intentionally proud. Keep adhesive off the seating-pad tops so
excess glue cannot lift the sheet away from the stops.

The temporary collar has the same 2 mm bezel and opening, seating on the same
pads. Once the metal is ready, remove the collar and mount the **same lens and
carrier** from inside the enclosure. There is no spacer above the metal and no
new sheet-metal cutout to manufacture.

Print tolerances, paint, sheet thickness, and adhesive application still affect
real flushness. Dry-fit the lens in the finished metal before bonding. This CAD
set does not change the existing Fusion documents or the production metal files.

## Dimensions

- Bench assembly with collar: **71.7 × 17.7 × 10.13 mm**.
- Installed lens/carrier footprint: **68 × 14 mm**, matching the original part.
- Depth below the sheet underside: **8.13 mm**; the lens face is flush above it.
- Solid glue bed: **2 mm**; supports the complete nominal 55.56 × 12 mm strip,
  including end pads and cut-length allowance up to 56.96 mm.
- Strip adhesive allowance: **0.2 mm**. A thick glue mound reduces the air gap.
- Nominal LED-to-optical-roof air gap: **5 mm**; white optical roof: **0.8 mm**.
- Mounting flange: **1.2 mm**; carrier cavity: **66.6 × 12.6 mm**.
- Collar slip clearance: **0.25 mm per side** around the carrier/flange.
- Wire exits: **8 mm wide** at each end. The carrier slots are open upward;
  the collar covers their upper portion and leaves exits below the LED plane.

## Assemble now, mount later

1. Solder and electrically test the strip. Dry-fit it in the carrier, centered
   along the bed. The complete back of the flexible PCB rests on the floor.
2. Bond that flat back with a thin adhesive layer suitable for the backing and
   PLA. Its existing adhesive may be used if it sticks securely to the bed.
3. Route the wires past the end pads and down through the floor reliefs. Secure
   the outgoing cable separately so pulling it cannot load the solder pads;
   the openings provide clearance, not strain relief.
4. Set the white flange on the carrier rim, keeping its narrow nose upward.
   The flange remains vertically clear of the LED packages even if shifted;
   it never locates itself against the PCB edge.
5. Lower the black collar over the assembly. For the first test, use small tape
   tabs beneath the base and up the outer collar, clear of the wire exits. The
   parts are a slip fit and do not latch together. After checking the light,
   bond the lens flange to the carrier rim; keep the outer collar removable.
6. When the metal arrives, remove the collar, insert the lens through the slot
   from inside, and seat all four pads against the sheet underside. Bond the
   flange beneath the sheet while keeping glue off the pad tops and optical face.

The first print has confirmed improved light; sliding fit, glue adhesion,
wire clearance, and corner leakage have not all been individually confirmed.
Inspect the corners and outlets in dim light. CAD geometry cannot establish
real opacity or replace these physical checks.

## Regenerate and check

Run from the repository checkout using the enclosure Python environment
with CadQuery, NumPy, SciPy, Matplotlib and VTK installed:

```sh
cd hardware/pill_light_mask
../enclosure/.venv/bin/python tall_pill.py
../enclosure/.venv/bin/python check_geometry.py
../enclosure/.venv/bin/python preview.py
```

Checks cover valid solids, STEP round trips, full floor support, part/PCB
clearances, light paths, cables, assembly and removal, print orientation, the
bounded short roof bridge, seating-pad contact, zero interference with the
panel, and matching lens/panel upper planes. Physical verification remains
pending under `autonomy:blocked-verify` on #1074.
