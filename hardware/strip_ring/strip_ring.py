"""Strip-fed console ring enclosure (#1075). Units mm; encoder datum unchanged.

The optical chamber clears the populated PCB. An independent centre cap closes
the face above the encoder retainer, with the entire knob above the face.
No imports from, or writes to, the production enclosure generator.
"""

from pathlib import Path
from math import pi, degrees, cos, sin, radians
import zipfile
import cadquery as cq

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
COUNT = 40
PITCH = 1000 / 144
CUT_LENGTH = COUNT * PITCH
SEAM = 4.0
# Width/density are owner-confirmed. Thickness and package dimensions are the
# existing enclosure's nominal strip model; check the actual tape before glue.
STRIP_W, FPC_T, LED_H, LED_SIDE = 12.0, 0.53, 1.6, 5.0
ADHESIVE = 0.2
NEUTRAL_R = (CUT_LENGTH + SEAM) / (2 * pi)
BACK_R = NEUTRAL_R + FPC_T / 2
GLUE_R = BACK_R + ADHESIVE
CUP_R = GLUE_R + 1.6
SHIELD_INNER_R = CUP_R + 0.2
SHIELD_R = SHIELD_INNER_R + 1.2
LIGHT_LIFT = 7.0
FACE_Z = 2.0 + LIGHT_LIFT
KNOB_BOTTOM = FACE_Z + 0.5
STRIP_TOP = -2.4 + LIGHT_LIFT
STRIP_BOTTOM = STRIP_TOP - STRIP_W
CUP_BOTTOM = STRIP_BOTTOM - 1.6
SHIELD_BOTTOM = CUP_BOTTOM - 1.8
# Electronics and base stay fixed while the optical chamber moves upward.
BASE_TOP = -19.2
BASE_THICKNESS = 3.6
BASE_BOTTOM = BASE_TOP - BASE_THICKNESS
# Three of the same M3 x 5 / Ø7 flat-head-underneath SSD screws as the cap.
# 2.6 mm head pockets plus 1 mm bearing webs keep the bench surface flat.
BASE_HEAD_FLOOR_Z = BASE_BOTTOM + 2.6
BASE_SCREWS = [(43.5*cos(radians(a)), 43.5*sin(radians(a))) for a in (30, 150, 270)]
LENS_R, LENS_BORE_R = 33.4, 25.85
SEAT_R, SEAT_HOLE_R = 25.9, 9.25
BOARD_REFERENCE = HERE / "reference" / "controller_without_ring.step"
CAP_SCREWS = [(-18, 0), (18, 0)]
# M3 x 5 under-head length, flat-under-head SSD screws with Ø7 mm heads.
# A 2.6 mm deep pocket accommodates a head up to 2.4 mm tall plus 0.2 recess.
CAP_HEAD_FLOOR_Z = FACE_Z - 2.6
CAP_SEAT_Z = CAP_HEAD_FLOOR_Z - 1.0


def annulus(ro, ri, z0, z1):
    return (cq.Workplane("XY").workplane(offset=z0).circle(ro).circle(ri)
            .extrude(z1 - z0).val())


def box(dx, dy, dz, xyz):
    return cq.Workplane("XY").box(dx, dy, dz).translate(xyz).val()


def wire_slot():
    """A downward exit in the 4 mm seam, away from every LED and strip end."""
    return box(12, 2.8, 5.0, (46, 0, SHIELD_BOTTOM + 2.5))


def diffuser():
    # 0.8 mm optical roof, 0.8 mm inner/outer walls, hidden seating flange.
    lens = annulus(LENS_R, LENS_BORE_R, -1.2, 2.0)
    lens = lens.fuse(annulus(35.4, LENS_BORE_R, -1.2, 0))
    lens = lens.cut(annulus(32.6, 26.65, -1.21, 1.2))
    # Bevel the chamber entrance so the outer lip does not intercept the
    # inward/upward light path before it reaches the optical roof.
    entrance = (cq.Workplane("XZ")
                .polyline([(32.6, -1.21), (33.41, -1.21), (32.6, -0.40)])
                .close().revolve().val())
    lens = lens.cut(entrance)
    lens = lens.translate((0, 0, LIGHT_LIFT))
    # The longer inner wall reflects inward light above the PCB. The centre
    # floor and retaining plate remain at their original encoder mounting height.
    neck = annulus(26.65, LENS_BORE_R, -4.2, LIGHT_LIFT)
    floor = annulus(SEAT_R, SEAT_HOLE_R, -1.0, 1.0)
    return lens.fuse(neck, floor).clean()


def cup():
    # Flat roof beneath the black cover, white inside for reflected light. The lid's
    # hidden flange rests on the inner shelf with 0.25 mm radial clearance.
    roof = annulus(CUP_R, 35.65, LIGHT_LIFT-1.2, LIGHT_LIFT)
    shelf = annulus(36.2, 34.4, LIGHT_LIFT-2.0, LIGHT_LIFT-1.2)
    wall = annulus(CUP_R, GLUE_R, CUP_BOTTOM, LIGHT_LIFT)
    # The shield carries the tape's bottom ledge. Keeping it separate lets the
    # cup print roof-down without a wide unsupported overhang at the other end.
    return roof.fuse(shelf, wall).cut(wire_slot()).clean()


def shield():
    wall = annulus(SHIELD_R, SHIELD_INNER_R, BASE_TOP, LIGHT_LIFT)
    base = annulus(SHIELD_R, 41.0, BASE_TOP, CUP_BOTTOM - 0.2)
    ledge = annulus(GLUE_R - 0.2, 42.4, CUP_BOTTOM - 0.2, STRIP_BOTTOM)
    body = wall.fuse(base, ledge)
    for x, y in BASE_SCREWS:
        body = body.cut(cq.Solid.makeCylinder(1.25, 4.4,
                                             cq.Vector(x,y,BASE_TOP)))
    # The strip seam opens down INSIDE the case; the outer black wall stays
    # continuous. Only the rear cable outlet reaches the outside.
    internal_slot = wire_slot().intersect(cq.Solid.makeCylinder(
        46.5, 30, cq.Vector(0,0,-25)))
    return body.cut(internal_slot).cut(cable_outlet()).clean()


def cable_outlet():
    return box(8, 16, 3, (0, 46, BASE_TOP+1.5))


def top_cover():
    """Opaque printed faceplate covering every white surface outside the lens."""
    return annulus(SHIELD_R, 33.5, LIGHT_LIFT, FACE_Z)


def encoder_retainer():
    """Nut-clamped lower plate with two through M3 pilot posts for the cap."""
    plate = annulus(25.6, 4.25, 1, 2)
    for x,y in CAP_SCREWS:
        plate = plate.fuse(cq.Solid.makeCylinder(5, CAP_SEAT_Z-2,
                                                cq.Vector(x,y,2)))
        plate = plate.cut(cq.Solid.makeCylinder(1.25, CAP_SEAT_Z-1+.02,
                                               cq.Vector(x,y,.99)))
    return plate.clean()


def centre_disc():
    """Removable opaque face cap, level with the diffuser and outer cover.

    Two M3 x 5 screws bear on 1 mm webs beneath flat-bottom head pockets.
    The peripheral skirt also bears on the retainer; the knob is not a fastener.
    """
    cap = annulus(25.6, 4.25, FACE_Z-1, FACE_Z)
    cap = cap.fuse(annulus(25.6, 24.2, 2, FACE_Z-1))
    for x,y in CAP_SCREWS:
        cap = cap.fuse(cq.Solid.makeCylinder(5, FACE_Z-1-CAP_SEAT_Z,
                                            cq.Vector(x,y,CAP_SEAT_Z)))
        cap = cap.cut(cq.Solid.makeCylinder(1.7, FACE_Z-CAP_SEAT_Z+.02,
                                           cq.Vector(x,y,CAP_SEAT_Z-.01)))
        cap = cap.cut(cq.Solid.makeCylinder(3.7, FACE_Z-CAP_HEAD_FLOOR_Z+.01,
                                           cq.Vector(x,y,CAP_HEAD_FLOOR_Z)))
    return cap.clean()


def cap_screws():
    """M3 x 5 / Ø7 x 2.4 mm head envelopes, reference only (never print)."""
    screws = []
    for x,y in CAP_SCREWS:
        shank = cq.Solid.makeCylinder(1.5, 5, cq.Vector(x,y,CAP_HEAD_FLOOR_Z-5))
        head = cq.Solid.makeCylinder(3.5, 2.4, cq.Vector(x,y,CAP_HEAD_FLOOR_Z))
        screws.append(shank.fuse(head).clean())
    return screws


def bottom_cover():
    floor = cq.Solid.makeCylinder(SHIELD_R, BASE_THICKNESS, cq.Vector(0,0,BASE_BOTTOM))
    # A shallow locating rim overlaps the housing ledge and hides the joint.
    lip = annulus(40.8, 39.6, BASE_TOP, -16.8)
    floor = floor.fuse(lip).cut(cable_outlet())
    for x,y in BASE_SCREWS:
        floor = floor.cut(cq.Solid.makeCylinder(1.7, BASE_THICKNESS+.02,
                                               cq.Vector(x,y,BASE_BOTTOM-.01)))
        floor = floor.cut(cq.Solid.makeCylinder(3.7, 2.61,
                                               cq.Vector(x,y,BASE_BOTTOM-.01)))
    return floor.clean()


def base_screws():
    """Three upward M3 x 5 / Ø7 x 2.4 head envelopes, never print."""
    screws = []
    for x,y in BASE_SCREWS:
        shank = cq.Solid.makeCylinder(1.5, 5, cq.Vector(x,y,BASE_HEAD_FLOOR_Z))
        head = cq.Solid.makeCylinder(3.5, 2.4, cq.Vector(x,y,BASE_HEAD_FLOOR_Z-2.4))
        screws.append(shank.fuse(head).clean())
    return screws


def spacer():
    return annulus(8, 5, -2.5, 1.0)


def parts():
    return {"diffuser": diffuser(), "cup": cup(), "shield": shield(),
            "encoder_spacer": spacer(), "encoder_retainer": encoder_retainer(),
            "top_cover": top_cover(),
            "centre_disc": centre_disc(), "bottom_cover": bottom_cover()}


def led_strip():
    """Curved FPC with individually rigid LED packages, seam along +X.

    No sideways flex: strip width runs vertically, PCB thickness radially.
    The cut is halfway between LEDs; pitch follows the neutral FPC surface.
    """
    gap_angle = degrees(SEAM / NEUTRAL_R)
    fpc = (cq.Workplane("XZ")
           .polyline([(NEUTRAL_R - FPC_T / 2, STRIP_BOTTOM),
                      (BACK_R, STRIP_BOTTOM), (BACK_R, STRIP_TOP),
                      (NEUTRAL_R - FPC_T / 2, STRIP_TOP)])
           .close().revolve(360 - gap_angle, (0, 0), (0, 1)).val()
           .rotate((0, 0, 0), (0, 0, 1), gap_angle / 2))
    led_r = NEUTRAL_R - FPC_T / 2 - LED_H / 2
    leds = []
    for i in range(COUNT):
        angle = degrees((SEAM / 2 + (i + 0.5) * PITCH) / NEUTRAL_R)
        leds.append(box(LED_H, LED_SIDE, LED_SIDE,
                        (led_r, 0, (STRIP_TOP + STRIP_BOTTOM) / 2))
                    .rotate((0, 0, 0), (0, 0, 1), angle))
    return fpc, leds


def controller():
    return cq.importers.importStep(str(BOARD_REFERENCE)).val()


def knob():
    # Purchased 50 x 18 mm push-on D-bore knob, now wholly above the face.
    # The circular cavity is only a shaft-clearance envelope: actual bore depth,
    # D-flat dimensions and gripping length are unmeasured, not certified here.
    k = cq.Solid.makeCylinder(25, 18, cq.Vector(0, 0, KNOB_BOTTOM))
    return k.cut(cq.Solid.makeCylinder(3.1, 8.5, cq.Vector(0, 0, KNOB_BOTTOM)))


def print_pose(name, shape):
    if name in ("diffuser", "cup", "centre_disc"):
        shape = shape.rotate((0, 0, 0), (1, 0, 0), 180)
    return shape.translate((0, 0, -shape.BoundingBox().zmin))


def export():
    OUT.mkdir(exist_ok=True)
    assembly = cq.Assembly(name="strip_ring_prototype")
    for name, shape in parts().items():
        assert shape.isValid() and len(shape.Solids()) == 1, name
        cq.exporters.export(shape, str(OUT / f"strip_ring_{name}.step"))
        cq.exporters.export(print_pose(name, shape),
                            str(OUT / f"strip_ring_{name}.stl"),
                            tolerance=0.03, angularTolerance=0.1)
        assembly.add(shape, name=name, color=cq.Color(
            "ivory" if name in ("diffuser", "cup") else "black"))
    fpc, leds = led_strip()
    assembly.add(fpc, name="strip_backing_reference", color=cq.Color("white"))
    assembly.add(cq.Compound.makeCompound(leds), name="40_leds_reference",
                 color=cq.Color("gold"))
    assembly.add(controller(), name="controller_reference", color=cq.Color("purple"))
    assembly.add(knob(), name="50mm_knob_reference", color=cq.Color("black"))
    for i,screw in enumerate(cap_screws()):
        assembly.add(screw, name=f"cap_screw_{i+1}_reference", color=cq.Color(.64,.67,.71))
    for i,screw in enumerate(base_screws()):
        assembly.add(screw, name=f"base_screw_{i+1}_reference", color=cq.Color(.64,.67,.71))
    assembly.export(str(OUT / "strip_ring_assembly.step"))
    for path in OUT.glob("*.step"):
        # OpenCascade pads STEP entity lines with spaces; keep CAD diffs clean.
        path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")


def pack():
    prefix = "strip-ring-all-m3/"
    with zipfile.ZipFile(OUT / "strip_ring_all_m3_print_pack.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for part in parts():
            color = "WHITE" if part in ("diffuser", "cup") else "BLACK"
            stem = f"strip_ring_{part}"
            z.write(OUT / f"{stem}.stl", prefix+f"{color}/{stem}.stl")
            z.write(OUT / f"{stem}.step", prefix+f"STEP/{stem}.step")
        for name in ("strip_ring_assembly.step", "strip_ring_preview.png", "strip_ring_print_colours.png"):
            z.write(OUT / name, prefix+name)
        z.write(HERE / "README.md", prefix+"README.md")


if __name__ == "__main__":
    export()
