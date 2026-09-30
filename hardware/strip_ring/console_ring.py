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

Why 34 LEDs: owner's call, 2026-09-30 (#1090). 34 was first forced by the 7in
module (42.9 from the axis at ENC_V 229.16). Since the ring moved to ENC_V 215.0
the module is 57.0 away and a 40-LED cup (r 46.9) would also fit, but at 34 the
LEDs sit 3 mm from the lens instead of 9.6: in the light model one LED lights
~22 deg of the ring instead of ~32, and the ring is ~1.7x brighter at the same
drive, so the comet's head reads sharper. The cup's outer wall is at r 40.3.

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

# Carrier snap hold (#1090). The v3 carrier has no screw holes: RING_ASSEMBLY.md
# says it snap-mounts. Three arms hang from the cup's roof, outside the strip
# wall, and click a 45-degree lead-in catch under the board edge. They only stop
# the board dropping, swinging or turning: the EC11 nut still sets its height, so
# the catch sits CLIP_PLAY below the board and the arms clear its edge radially.
PCB_R, PCB_T = 40.0, 1.6           # v3 carrier: Ø80 Edge.Cuts circle, 1.6 mm FR4
PCB_BOTTOM = CARRIER_TOP - PCB_T
CLIP_ANGLES = (30.0, 150.0, 270.0)  # deg from +x; the strip seam and its wires are at 0
CLIP_W = 6.0                       # tangential arm width
CLIP_GAP = 0.12                    # arm inner face off the cup wall's outer face
CLIP_T = 1.0                       # arm thickness (radial): ~0.6 % strain over its length
CLIP_PLAY = 0.3                    # catch below the board's underside
CLIP_CATCH_R = 39.0                # catch reaches in to here: 1.0 mm under the board edge
CLIP_CATCH_H = 1.2                 # catch height; its underside is the 45-degree lead-in
CARRIER_PARTS_R = 37.4             # outermost underside part (D1), measured in Fusion
TOWER_CLEAR_R = 41.5               # segno_enclosure.S7T_RING_CLEAR_R (tower gate)

# Hard limits this variant exists to meet (Fusion clone, 2026-09-30, ENC_V 215.0):
SCREEN7_CLEAR_R = 57.0             # 7in module's nearest point to the axis
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


def _sector(ro, ri, z0, z1, deg_c, width):
    span = degrees(width / ((ro + ri) / 2.0))
    w = (cq.Workplane("XZ").polyline([(ri, z0), (ro, z0), (ro, z1), (ri, z1)]).close()
         .revolve(span, (0, 0, 0), (0, 1, 0)).val())
    return w.rotate((0, 0, 0), (0, 0, 1), deg_c - span / 2.0)


def carrier_clip(deg_c):
    """One snap arm: a bridge off the roof, a flexing arm down past the carrier,
    and the catch under the board edge with its lead-in on the underside."""
    r_in = CUP_R + CLIP_GAP
    r_out = r_in + CLIP_T
    z_top = PCB_BOTTOM - CLIP_PLAY
    z_bot = z_top - CLIP_CATCH_H
    bridge = _sector(r_out, CUP_R - 0.4, UNDER - 1.2, UNDER, deg_c, CLIP_W)
    arm = _sector(r_out, r_in, z_bot, UNDER - 1.2, deg_c, CLIP_W)
    span = degrees(CLIP_W / r_in)
    catch = (cq.Workplane("XZ")
             .polyline([(r_in + 0.01, z_top), (CLIP_CATCH_R, z_top),
                        (CLIP_CATCH_R, z_top - 0.2), (r_in + 0.01, z_bot)])
             .close().revolve(span, (0, 0, 0), (0, 1, 0)).val()
             .rotate((0, 0, 0), (0, 0, 1), deg_c - span / 2.0))
    return bridge.fuse(arm, catch)


def cup():
    """Roof glued to the faceplate underside; the diffuser's flange rests on the
    inner shelf; the wall carries the strip down to just above the carrier; three
    arms snap the carrier in place."""
    roof = annulus(CUP_R, 35.65, UNDER - 1.2, UNDER)
    shelf = annulus(36.2, 34.4, UNDER - 2.0, UNDER - 1.2)
    wall = annulus(CUP_R, GLUE_R, STRIP_BOTTOM, UNDER)
    body = roof.fuse(shelf, wall)
    for a in CLIP_ANGLES:
        body = body.fuse(carrier_clip(a))
    return body.clean()


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


BENCH_PLATE = 120.0                # square faceplate stand-in (fits a 220 mm bed)
BENCH_LEG_H = 34.0                 # under the plate: clears the carrier's underside
                                   # parts (down to about z -26) with the bench below
BENCH_WINDOW_R = 33.5              # the faceplate's Ø67 window, bare


def bench_faceplate():
    """BENCH STAND-IN for the faceplate (print BLACK, #1090): a 2 mm plate with
    the real Ø67 window on four legs, so the console ring can be lit and judged
    at its real optics (34 LEDs, 3 mm chamber) before the ring choice is made.
    Printed plate-down, the bed face is the visible face. The cup's roof glues
    (or tapes) to the plate's underside exactly as it will to the metal; the
    sides are open between the legs, so the carrier's cable leaves freely."""
    h = FACEPLATE_T
    plate = (cq.Workplane("XY").box(BENCH_PLATE, BENCH_PLATE, h, centered=(True, True, False))
             .translate((0, 0, -h)))
    plate = plate.cut(cq.Workplane("XY").workplane(offset=-h - 0.1).circle(BENCH_WINDOW_R).extrude(h + 0.2))
    leg = 8.0
    for sx in (-1, 1):
        for sy in (-1, 1):
            plate = plate.union(cq.Workplane("XY").box(leg, leg, BENCH_LEG_H, centered=(True, True, False))
                                .translate((sx * (BENCH_PLATE - leg) / 2.0, sy * (BENCH_PLATE - leg) / 2.0,
                                            -h - BENCH_LEG_H)))
    solid = plate.val()
    assert solid.isValid() and len(plate.solids().vals()) == 1
    assert (BENCH_PLATE - 2 * leg) / 2.0 > CUP_R + 2.0, "bench legs foul the cup"
    return solid


def print_pose(name, shape):
    """Bed orientation, as the standalone ring prints them: the visible or glue
    face down for the diffuser, cup and cap, everything else as modelled."""
    if name in ("diffuser", "cup", "centre_cap"):
        shape = shape.rotate((0, 0, 0), (1, 0, 0), 180)
    return shape.translate((0, 0, -shape.BoundingBox().zmin))


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
    assert STRIP_BOTTOM > CARRIER_TOP, "strip edge reaches below the carrier PCB top"
    assert CUP_R + CLIP_GAP + CLIP_T < TOWER_CLEAR_R, "snap arms reach the 7in tower's clearance"
    assert CUP_R + CLIP_GAP > PCB_R + 0.2, "snap arms grip the board edge radially"
    assert CLIP_CATCH_R < PCB_R - 0.8, "catch overlaps the board edge by too little"
    assert CLIP_CATCH_R > CARRIER_PARTS_R + 1.0, "catch reaches the carrier's underside parts"
    for a in CLIP_ANGLES:
        assert min(abs(a), abs(360 - a)) > 15, "a snap arm sits on the strip seam"
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
        cq.exporters.export(print_pose(name, shape), str(OUT / f"console_ring_{name}.stl"),
                            tolerance=0.03, angularTolerance=0.1)
        asm.add(shape, name=name, color=cq.Color("ivory" if name in ("diffuser", "cup") else "black"))
    bench = bench_faceplate()
    cq.exporters.export(bench, str(OUT / "console_ring_bench_faceplate.step"))
    cq.exporters.export(print_pose("bench", bench.rotate((0, 0, 0), (1, 0, 0), 180)),
                        str(OUT / "console_ring_bench_faceplate.stl"),
                        tolerance=0.03, angularTolerance=0.1)
    fpc, leds = led_strip()
    asm.add(fpc, name="strip_backing_reference", color=cq.Color("white"))
    asm.add(cq.Compound.makeCompound(leds), name=f"{COUNT}_leds_reference", color=cq.Color("gold"))
    asm.save(str(OUT / "console_ring_assembly.step"))
    for path in OUT.glob("*.step"):
        path.write_text("\n".join(line.rstrip() for line in path.read_text().splitlines()) + "\n")
    return info


if __name__ == "__main__":
    print(export())
