"""Flush panel lens, supported LED carrier, and removable bench collar (mm).

Z=0 is the mounting flange. Four 0.2 mm pads touch the sheet underside;
the lens face and the outside of the 2 mm sheet are both at Z=2.2.
"""

from pathlib import Path
import sys

import cadquery as cq

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "enclosure"))
import segno_enclosure as enclosure

OUT = HERE / "out"
LENGTH = enclosure.LED_SLOT_W + 2 * enclosure.LED_INS_FLANGE
WIDTH = enclosure.LED_SLOT_H + 2 * enclosure.LED_INS_FLANGE
STRIP_LENGTH = enclosure.LED_STRIP_SEG
STRIP_WIDTH = enclosure.LED_STRIP_W
BASE_T = 2.0
ADHESIVE_T = 0.2  # Allowance for the thin adhesive layer under the strip.
AIR_GAP = 5.0
FACE_T = 0.8
MOUNT_GAP = 0.2  # Positive pads control the existing enclosure glue-line datum.
PANEL_T = enclosure.T
FACE_TOP = MOUNT_GAP + PANEL_T
FACE_UNDER = FACE_TOP - FACE_T
LED_TOP = FACE_UNDER - AIR_GAP
BED_TOP = LED_TOP - enclosure.LED_STRIP_OA - ADHESIVE_T
BASE_BOTTOM = BED_TOP - BASE_T
FLANGE_T = 1.2
CAP_WALL = 0.8
CARRIER_WALL = 0.7  # The tray walls locate the PCB; the full floor carries it.
FIT_CLEARANCE = 0.25  # Per side; a removable slip fit, not a snap connection.
MASK_WALL = 1.6
MASK_TOP = FACE_TOP
LENS_LENGTH = enclosure.LED_SLOT_W - enclosure.LED_INS_CLR
LENS_WIDTH = enclosure.LED_SLOT_H - enclosure.LED_INS_CLR
WIRE_WIDTH = 8.0
WIRE_TOP = BASE_BOTTOM + 3.5  # Below the LED emitting plane.
WIRE_FLOOR = BASE_BOTTOM + 0.6
WIRE_START = enclosure.LED_CH_L / 2 + 0.5  # Outside even the long-cut strip.


def stadium(length, width, bottom, height):
    return cq.Workplane("XY").workplane(offset=bottom).slot2D(
        length, width
    ).extrude(height)


def wire_relief(bottom, top):
    """End openings; leave the entire strip footprint supported underneath."""
    end = LENGTH / 2 + FIT_CLEARANCE + MASK_WALL + 1
    cuts = cq.Workplane("XY")
    for direction in (-1, 1):
        block = cq.Workplane("XY").box(
            end - WIRE_START, WIRE_WIDTH, top - bottom
        ).translate((direction * (end + WIRE_START) / 2, 0, (top + bottom) / 2))
        cuts = cuts.add(block)
    return cuts


def build():
    # The tray and its full-depth glue bed are ONE part, with no gripping lips.
    # Wire slots remain open at the top; the removable collar masks those ends.
    base = stadium(LENGTH, WIDTH, BASE_BOTTOM, -FLANGE_T - BASE_BOTTOM)
    base = base.cut(stadium(
        LENGTH - 2 * CARRIER_WALL, WIDTH - 2 * CARRIER_WALL,
        BED_TOP, -FLANGE_T - BED_TOP + 0.1,
    )).cut(wire_relief(WIRE_FLOOR, -FLANGE_T + 0.1))

    # The flange remains behind the metal; only the narrow nose enters its slot.
    cap = stadium(LENGTH, WIDTH, -FLANGE_T, FLANGE_T).union(
        stadium(LENS_LENGTH, LENS_WIDTH, 0, FACE_TOP)
    )
    cap = cap.cut(stadium(
        LENS_LENGTH - 2 * CAP_WALL, LENS_WIDTH - 2 * CAP_WALL,
        -FLANGE_T - 0.1, FACE_UNDER + FLANGE_T + 0.1,
    ))
    for x in (-18, 18):
        for y in (-5.4, 5.4):
            pad = cq.Workplane("XY").center(x, y).rect(8, 1.2).extrude(MOUNT_GAP)
            cap = cap.union(pad)

    # The collar's 2 mm bezel takes the metal's place for testing on the bench.
    cavity_l = LENGTH + 2 * FIT_CLEARANCE
    cavity_w = WIDTH + 2 * FIT_CLEARANCE
    mask = stadium(
        cavity_l + 2 * MASK_WALL, cavity_w + 2 * MASK_WALL,
        BASE_BOTTOM, MASK_TOP - BASE_BOTTOM,
    ).cut(stadium(cavity_l, cavity_w, BASE_BOTTOM - 0.1, MOUNT_GAP - BASE_BOTTOM + 0.1))
    mask = mask.cut(stadium(
        enclosure.LED_SLOT_W, enclosure.LED_SLOT_H,
        MOUNT_GAP - 0.1, PANEL_T + 0.2,
    )).cut(wire_relief(BASE_BOTTOM - 0.1, WIRE_TOP))
    return {"base": base.val(), "diffuser": cap.val(), "mask": mask.val()}


def panel_reference():
    """Local coupon of the actual 2 mm sheet and 60 × 6 mm through-cut."""
    return cq.Workplane("XY").workplane(offset=MOUNT_GAP).rect(90, 32).extrude(
        PANEL_T
    ).cut(stadium(enclosure.LED_SLOT_W, enclosure.LED_SLOT_H, 0, FACE_TOP + 0.1)).val()


def print_orientation(name, solid):
    # Carrier floor and diffuser flange go down. The narrow optical roof bridges
    # 4.2 mm across its width; its optical face never touches support material.
    if name == "mask":
        solid = solid.rotate((0, 0, 0), (1, 0, 0), 180)
    return solid.translate((0, 0, -solid.BoundingBox().zmin))


def export(parts):
    OUT.mkdir(exist_ok=True)
    assembly = cq.Assembly(name="tall_pill")
    for name, solid in parts.items():
        cq.exporters.export(solid, str(OUT / f"tall_pill_{name}.step"))
        cq.exporters.export(
            print_orientation(name, solid),
            str(OUT / f"tall_pill_{name}.stl"),
            tolerance=0.03, angularTolerance=0.1,
        )
        color = (0.92, 0.92, 0.88) if name == "diffuser" else (0.10, 0.10, 0.12)
        assembly.add(solid, name=name, color=cq.Color(*color))
    assembly.export(str(OUT / "tall_pill_assembly.step"))
    panel_assembly = cq.Assembly(name="flush_panel_reference")
    for name in ("base", "diffuser"):
        panel_assembly.add(parts[name], name=name, color=cq.Color(
            *((0.92, 0.92, 0.88) if name == "diffuser" else (0.1, 0.1, 0.12))
        ))
    panel_assembly.add(panel_reference(), name="sheet_metal_reference", color=cq.Color(0.55, 0.59, 0.64))
    panel_assembly.export(str(OUT / "tall_pill_panel_reference.step"))
    # OpenCascade adds trailing spaces to STEP entity lines.
    for path in OUT.glob("tall_pill_*.step"):
        path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")


if __name__ == "__main__":
    export(build())
    print(f"Exported three printable parts and assembled STEP to {OUT}")
