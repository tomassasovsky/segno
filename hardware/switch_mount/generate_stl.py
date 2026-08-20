"""Generate STL and STEP models for the MX switch footswitch box.

Install CadQuery, then run this file:

    pip install cadquery
    python generate_stl.py
"""

from pathlib import Path

import cadquery as cq

# ── Tunable parameters ────────────────────────────────────────────

SW_BODY_W    = 15.6      # MX switch body width  (X)
SW_BODY_L    = 15.6      # MX switch body length (Y)
SW_BODY_H    = 6.6       # height of body below the plate clips
PIN_CLEARANCE = 4.0      # extra depth below body for pins + solder
                          # set to 0 for minimum box height (6.5 mm)

SLOT_W       = 14.0      # MX plate slot width  (standard)
SLOT_L       = 14.0      # MX plate slot length (standard)
PLATE_T      = 1.5       # top plate thickness

WALL         = 3.0       # side wall thickness
GAP          = 0.4       # clearance around switch body in cavity
                          # reduce to 0.2 for a tighter snap fit

OUTER_W      = 67.2      # total box width — sized to fit pedal interior
                          # change this to match YOUR pedal's inner width

CABLE_D      = 7.0       # cable-exit hole diameter (front wall, centred)

# ── Derived ───────────────────────────────────────────────────────
INNER_W = SW_BODY_W + 2 * GAP
INNER_L = SW_BODY_L + 2 * GAP
INNER_H = SW_BODY_H + PIN_CLEARANCE

OUTER_L = INNER_L + 2 * WALL
OUTER_H = PLATE_T + INNER_H

CX = OUTER_W / 2
CY = OUTER_L / 2
cavity_x = CX - INNER_W / 2
cavity_y = CY - INNER_L / 2

# ── Geometry helpers ──────────────────────────────────────────────

def box(width, length, height, x=0, y=0, z=0):
    """Create a non-centred box translated from the origin."""
    return (
        cq.Workplane("XY")
        .box(width, length, height, centered=(False, False, False))
        .translate((x, y, z))
    )


# ── Build the box ─────────────────────────────────────────────────

model = box(OUTER_W, OUTER_L, OUTER_H)
model = model.cut(box(INNER_W, INNER_L, INNER_H, cavity_x, cavity_y))
model = model.cut(
    box(
        SLOT_W,
        SLOT_L,
        PLATE_T + 0.1,
        CX - SLOT_W / 2,
        CY - SLOT_L / 2,
        OUTER_H - PLATE_T - 0.05,
    )
)

cable_hole = (
    cq.Workplane("XY")
    .circle(CABLE_D / 2)
    .extrude(WALL + 0.2)
    .rotate((0, 0, 0), (1, 0, 0), -90)
    .translate((CX, -0.1, OUTER_H / 2))
)
model = model.cut(cable_hole)

shape = model.val()
assert shape.isValid(), "Generated geometry is invalid"

bounding_box = shape.BoundingBox()
assert abs(bounding_box.xlen - OUTER_W) < 0.001
assert abs(bounding_box.ylen - OUTER_L) < 0.001
assert abs(bounding_box.zlen - OUTER_H) < 0.001

# ── Export ────────────────────────────────────────────────────────

output_directory = Path(__file__).resolve().parent
stl_path = output_directory / "switch_box.stl"
step_path = output_directory / "switch_box.step"

print("Generating switch_box.stl and switch_box.step …")
cq.exporters.export(model, str(stl_path))
cq.exporters.export(model, str(step_path))

print(f"""
Done.
  Outer size   : {OUTER_W} W × {OUTER_L:.1f} L × {OUTER_H:.1f} H  mm
  Plate slot   : {SLOT_W} × {SLOT_L} mm  (standard MX, top face)
  Cavity depth : {INNER_H:.1f} mm  (open at bottom)
  Cable hole   : ⌀{CABLE_D} mm on front wall

Stack height inside pedal:
  Box {OUTER_H:.1f} mm + stem 13.5 mm = {OUTER_H + 13.5:.1f} mm total
  Pre-travel before lid contacts stem: {22.6 - (OUTER_H + 13.5):.1f} mm

Print with TOP FACE DOWN on the bed (no supports needed).

Files:
  {stl_path}
  {step_path}
""")
