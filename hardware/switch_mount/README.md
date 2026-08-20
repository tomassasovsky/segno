# Akko V3 Fairy Silent — Footswitch Enclosure

## What this is

A 3D-printable mount that holds an **Akko V3 Fairy Linear Silent** (MX-compatible) keyboard switch inside a generic sustain pedal / footswitch case. The goal was to replace a noisy clicky button with a quieter MX silent switch.

## Files

| File | Description |
|------|-------------|
| `switch_box.stl` | The printable enclosure |
| `switch_box.step` | Editable solid model for CAD software |
| `switch_mount.scad` | Parametric OpenSCAD source (first design iteration, for reference / further editing) |
| `generate_stl.py` | CadQuery source that generates both enclosure formats |

## Enclosure dimensions

- **Outer size**: 67.2 mm (W) × 22.4 mm (L) × 12.1 mm (H)
- **MX plate slot**: 14 × 14 mm on the top face (standard MX plate spec)
- **Cable hole**: ⌀7 mm, centred on the front wall
- **Interior cavity**: open at the bottom for pin/solder access

## Height stack inside the pedal

| Component | Height |
|-----------|--------|
| Box | 12.1 mm |
| MX switch stem above plate (unactuated) | +13.5 mm |
| **Total from pedal floor to stem tip** | **25.6 mm** |

> ⚠️ The pedal interior height is 22.6 mm. At 12.1 mm box height the stem is **3 mm too tall** for the lid to close flat. To fix this, set `PIN_CLEARANCE = 0` in `generate_stl.py` and re-run — this drops the box to 6.5 mm (total stack 20 mm, 2.6 mm of lid pre-travel before it hits the stem).

## How the switch mounts

No modding required. The switch **snaps straight into the 14 × 14 mm slot** from the top, exactly like snapping into a keyboard plate. The two clips on the switch housing grip the slot edges and hold it in place.

## Assembly order

1. Solder two wires to the switch pins (accessible from the open bottom of the box before the switch is inserted).
2. Snap the switch into the slot from the top — stem pointing up.
3. Route the cable out through the ⌀7 mm hole on the front wall.
4. Place the box inside the pedal case. The 67.2 mm width is sized to sit snug side-to-side.
5. The switch stem contacts the pedal lid/rocker when you press down.

## Print settings

| Setting | Value |
|---------|-------|
| Material | PETG or ABS (PLA fine for light use) |
| Layer height | 0.2 mm |
| Infill | 40 %+ |
| Supports | **None needed** |
| Orientation | **Top face DOWN** on the bed |

## Regenerating / tweaking the STL

Install Python 3 and run:

```bash
pip install cadquery
python generate_stl.py
```

This writes `switch_box.stl` and `switch_box.step` beside the generator.

Key parameters at the top of `generate_stl.py`:

| Parameter | Current value | Effect |
|-----------|--------------|--------|
| `OUTER_W` | 67.2 mm | Width — match your pedal interior |
| `PIN_CLEARANCE` | 4.0 mm | Space below switch body; set to 0 for minimum height |
| `CABLE_D` | 7.0 mm | Cable hole diameter |
| `GAP` | 0.4 mm | Clearance around switch body; reduce for tighter snap fit |

## MX switch pin wiring

The switch has two electrical pins. Polarity doesn't matter — it's a normally-open contact. Wire it like a standard momentary button: tip and sleeve of a mono TS jack.
