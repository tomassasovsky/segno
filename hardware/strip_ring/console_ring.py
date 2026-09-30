"""34-LED strip ring for the CONSOLE (#1075, #1088). Units mm.

The standalone ring (strip_ring.py, PR #1083) is a bench prototype with its own
printed top cover, sleeve and bottom. Inside the console the 2 mm aluminium
faceplate is the cover and the case is the enclosure, so this variant keeps
only what sits between the faceplate and the ring carrier:

  diffuser   white; lens flush with the faceplate top in the Ø67 window, hidden
             flange under the faceplate, inner neck and the encoder seat;
  cup        white; its roof is glued to the faceplate underside, its wall
             carries the strip, LEDs facing in;
  retainer, spacer, centre cap
             the standalone encoder stack unchanged, cap flush with the face.

Why 34 LEDs: at 40 the strip's back is at r 45.1 and the 7in screen module's
lower edge sits ~42.9 from the encoder axis under the faceplate (measured in
the populated Fusion clone). 34 LEDs put the cup's outer wall at r 40.3.

Frame: z = 0 is the faceplate TOP at the encoder axis, +z outward, the axis at
the origin. The faceplate underside is z = -FACEPLATE_T. The standalone ring's
frame is this one shifted by its FACE_Z (9.0); every z below is the
standalone's number minus 9 unless stated.

Carrier: the v3 XIAO ring carrier (Ø80) without its Ring24 module, the strip
plugged into J2. It sits LIGHT_LIFT (7.0) deeper than today's Ring24 stack, the
same lift as the standalone, so the strip's LED faces clear the PCB. Its top
components stay inside r 26.65 or below the chamber (checked in Fusion against
the v3 STEP: ~1 mm3 of grazing each). The EC11 nut clamps the retainer on the
diffuser's seat and the carrier hangs from the encoder, as in the standalone.
"""

from math import pi, degrees
from pathlib import Path
import cadquery as cq

HERE = Path(__file__).resolve().parent
OUT = HERE / "out_console"

COUNT = 34
PITCH = 1000 / 144                 # owner's 144/m strip
SEAM = 4.0
STRIP_W, FPC_T, LED_H, LED_SIDE = 12.0, 0.53, 1.6, 5.0
ADHESIVE = 0.2
NEUTRAL_R = (COUNT * PITCH + SEAM) / (2 * pi)
BACK_R = NEUTRAL_R + FPC_T / 2
GLUE_R = BACK_R + ADHESIVE
CUP_R = GLUE_R + 1.6
LED_FACE_R = NEUTRAL_R - FPC_T / 2 - LED_H

FACEPLATE_T = 2.0
UNDER = -FACEPLATE_T               # faceplate underside = the cup's glue plane
LIGHT_LIFT = 7.0
# The standalone's passive-board datum, carried over: PCB top 7.085 below its
# face-7 plane. The v3 carrier uses the same EC11 footprint, so the same 3.5 mm
# spacer sets the same encoder height.
CARRIER_TOP = -16.085
STRIP_BOTTOM = CARRIER_TOP + 0.085  # the strip edge stands just clear of the PCB
STRIP_TOP = STRIP_BOTTOM + STRIP_W
LENS_R, LENS_BORE_R = 33.4, 25.85  # = the console's RING_OD/RING_ID less clearance
SEAT_R, SEAT_HOLE_R = 25.9, 9.25
CAP_SCREWS = [(-18, 0), (18, 0)]
CAP_HEAD_FLOOR_Z = -2.6
CAP_SEAT_Z = CAP_HEAD_FLOOR_Z - 1.0
KNOB_BOTTOM = 0.5

# Hard limits this variant exists to meet (Fusion clone, 2026-09-30):
SCREEN7_CLEAR_R = 42.9             # 7in module's nearest point to the axis
WINDOW_R = 33.7                    # coated Ø67 window in the faceplate


def annulus(ro, ri, z0, z1):
    return (cq.Workplane("XY").workplane(offset=z0).circle(ro).circle(ri)
            .extrude(z1 - z0).val())


def diffuser():
    lens = annulus(LENS_R, LENS_BORE_R, UNDER - 1.2, 0.0)
    lens = lens.fuse(annulus(35.4, LENS_BORE_R, UNDER - 1.2, UNDER))
    lens = lens.cut(annulus(32.6, 26.65, UNDER - 1.21, -0.8))
    entrance = (cq.Workplane("XZ")
                .polyline([(32.6, UNDER - 1.21), (33.41, UNDER - 1.21), (32.6, UNDER - 0.40)])
                .close().revolve().val())
    lens = lens.cut(entrance)
    neck = annulus(26.65, LENS_BORE_R, -13.2, UNDER)
    floor = annulus(SEAT_R, SEAT_HOLE_R, -10.0, -8.0)
    return lens.fuse(neck, floor).clean()


def cup():
    """Roof glued to the faceplate underside; the diffuser's flange rests on the
    inner shelf; the wall carries the strip down to just above the carrier."""
    roof = annulus(CUP_R, 35.65, UNDER - 1.2, UNDER)
    shelf = annulus(36.2, 34.4, UNDER - 2.0, UNDER - 1.2)
    wall = annulus(CUP_R, GLUE_R, STRIP_BOTTOM, UNDER)
    return roof.fuse(shelf, wall).clean()


def encoder_retainer():
    plate = annulus(25.6, 4.25, -8.0, -7.0)
    for x, y in CAP_SCREWS:
        plate = plate.fuse(cq.Solid.makeCylinder(5, CAP_SEAT_Z + 7.0, cq.Vector(x, y, -7.0)))
        plate = plate.cut(cq.Solid.makeCylinder(1.25, CAP_SEAT_Z + 8.02, cq.Vector(x, y, -8.01)))
    return plate.clean()


def centre_cap():
    cap = annulus(25.6, 4.25, -1.0, 0.0)
    cap = cap.fuse(annulus(25.6, 24.2, -7.0, -1.0))
    for x, y in CAP_SCREWS:
        cap = cap.fuse(cq.Solid.makeCylinder(5, -1.0 - CAP_SEAT_Z, cq.Vector(x, y, CAP_SEAT_Z)))
        cap = cap.cut(cq.Solid.makeCylinder(1.7, -CAP_SEAT_Z + .02, cq.Vector(x, y, CAP_SEAT_Z - .01)))
        cap = cap.cut(cq.Solid.makeCylinder(3.7, -CAP_HEAD_FLOOR_Z + .01, cq.Vector(x, y, CAP_HEAD_FLOOR_Z)))
    return cap.clean()


def spacer():
    return annulus(8, 5, -11.5, -8.0)


def led_strip():
    """Reference only: FPC and 34 LED packages, seam on +x."""
    gap = degrees(SEAM / NEUTRAL_R)
    fpc = (cq.Workplane("XZ")
           .polyline([(NEUTRAL_R - FPC_T / 2, STRIP_BOTTOM), (BACK_R, STRIP_BOTTOM),
                      (BACK_R, STRIP_TOP), (NEUTRAL_R - FPC_T / 2, STRIP_TOP)])
           .close().revolve(360 - gap, (0, 0), (0, 1)).val()
           .rotate((0, 0, 0), (0, 0, 1), gap / 2))
    r = NEUTRAL_R - FPC_T / 2 - LED_H / 2
    leds = [cq.Workplane("XY").box(LED_H, LED_SIDE, LED_SIDE)
            .translate((r, 0, (STRIP_TOP + STRIP_BOTTOM) / 2)).val()
            .rotate((0, 0, 0), (0, 0, 1), degrees((SEAM / 2 + (i + .5) * PITCH) / NEUTRAL_R))
            for i in range(COUNT)]
    return fpc, leds


def parts():
    return {"diffuser": diffuser(), "cup": cup(), "encoder_retainer": encoder_retainer(),
            "centre_cap": centre_cap(), "encoder_spacer": spacer()}


def check():
    """The limits this variant exists for; raises on any breach."""
    assert CUP_R + 0.5 <= SCREEN7_CLEAR_R - 2.0, (
        f"cup r {CUP_R:.2f} leaves under 2 mm to the 7in module at r {SCREEN7_CLEAR_R}")
    assert LENS_R < WINDOW_R, "lens does not pass the coated window"
    assert 35.4 > WINDOW_R + 1.0, "diffuser flange does not reach under the faceplate"
    assert LED_FACE_R > 36.2, "LED faces foul the cup's diffuser shelf"
    assert STRIP_TOP <= UNDER - 2.0, "strip top reaches the shelf/roof"
    assert STRIP_BOTTOM > CARRIER_TOP, "strip stands on the carrier's components"
    for name, shape in parts().items():
        assert shape.isValid() and len(shape.Solids()) == 1, name
    return {"leds": COUNT, "neutral_r": NEUTRAL_R, "led_face_r": LED_FACE_R,
            "cup_r": CUP_R, "chamber_mm": LED_FACE_R - LENS_R}


def export():
    OUT.mkdir(exist_ok=True)
    info = check()
    asm = cq.Assembly(name="strip_ring_console_34")
    for name, shape in parts().items():
        cq.exporters.export(shape, str(OUT / f"console_ring_{name}.step"))
        cq.exporters.export(shape, str(OUT / f"console_ring_{name}.stl"),
                            tolerance=0.03, angularTolerance=0.1)
        asm.add(shape, name=name, color=cq.Color("ivory" if name in ("diffuser", "cup") else "black"))
    fpc, leds = led_strip()
    asm.add(fpc, name="strip_backing_reference", color=cq.Color("white"))
    asm.add(cq.Compound.makeCompound(leds), name=f"{COUNT}_leds_reference", color=cq.Color("gold"))
    asm.save(str(OUT / "console_ring_assembly.step"))
    for path in OUT.glob("*.step"):
        path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")
    return info


if __name__ == "__main__":
    print(export())
