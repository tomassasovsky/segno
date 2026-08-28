#!/usr/bin/env python3
"""
TEMPORARY snap-on diffuser for the 16-pixel WS2812 NeoPixel ring.

A bench part, not an enclosure part. It clips onto the **ring module itself** --
no faceplate, no standoffs, no glue. The top face is SOLID right across; the
only opening is a O7 hole for the EC11's threaded bush to poke through. Purpose:
make a bare Ring 16 read as a soft lit face instead of 16 point sources while
there is no panel in front of it.

This is NOT the console ring window. That one is a O67/O51.5 annulus cut in the
faceplate over a **Ring 24** (RING_OD / RING_ID in ../enclosure/segno_enclosure.py,
issues #791/#794) with the diffuser glued to the faceplate underside.

WHY THE FACE CAN BE SOLID
    The encoder's own top face sits only ~0.5 mm above the LEDs (ENC_FACE_RISE),
    so nothing in the middle is tall enough to need clearing -- only the bush
    itself carries on upward. That is what lets the roof span the ring's bore
    instead of stopping at it, and it is the one measurement this whole shape
    rests on. _check_clearances() asserts the roof clears the encoder's body.

HOW IT HOLDS ON
    Three cantilever fingers hang off the roof, run down past the ring's outer
    edge and hook under the PCB. The ring's four solder pads (JP1-JP4) sit on
    the BACK at r ~ 21 mm, so the fingers are clocked into the gaps between them
    -- a finger landing on a soldered wire would not seat. Those four angles are
    lifted from `segno.pretty/ModuleMountPads_4.kicad_mod`, which was extracted
    from Adafruit's own board file for this ring, so they are geometry, not a
    guess. _check() asserts the clearance.

    ==> The ring must have ~1.7 mm of air under it for the hooks (it does when
        pin-mounted or on standoffs). A ring sitting flat on a surface cannot
        take this part -- print --skirt-only for a friction shroud instead.

FIT
    Defaults are the genuine Adafruit Ring 16 (product 1463): O44.45 / O31.75.
    Clones sold as "NeoPixel Ring 16" are often much larger (68 mm+), and one of
    those will not go on. MEASURE the ring's outer diameter first; if it is not
    44.5, re-run with --od/--id/--pads and print that instead.

Outputs (./out): STEP (CAD, editable) + STL (print) + SVG preview views.
Run:  ../enclosure/.venv/bin/python ring16_diffuser.py
      ../enclosure/.venv/bin/python ring16_diffuser.py --enc 7.2
"""
from __future__ import annotations

import argparse
import math
import os

import cadquery as cq

# ----------------------------------------------------------------------------
# THE RING (mm) -- measure yours before printing; --od/--id override these.
# ----------------------------------------------------------------------------
RING_OD = 44.45    # Adafruit Ring 16, 1.75"
RING_ID = 31.75    # 1.25"
PCB_T   = 1.60     # ring PCB thickness (the hooks grab this edge)
LED_H   = 1.60     # WS2812 5050 standing proud of the PCB

# Back-side solder pads JP1..JP4, from ModuleMountPads_4 (Adafruit board file):
# DIN 124 deg, +5V 214 deg, GND 304 deg, DOUT 79 deg, all at r ~ 21.0. Wires or
# pins live here, so no hook may land on one.
PAD_ANGLES = (79.0, 124.0, 214.0, 304.0)

# ----------------------------------------------------------------------------
# THE ENCODER in the middle (mm)
# ----------------------------------------------------------------------------
# The EC11's body face is barely proud of the LEDs -- owner-measured on the real
# assembly, 2026-08-28. Everything above that plane is just the bush.
ENC_FACE_RISE = 0.5     # encoder top face above the LED tops   # MEASURED
ENC_BODY_D    = 17.0    # 12 x 12 body, across the diagonal (clearance envelope)
ENC_D         = 7.0     # bush clearance hole through the roof
# NOTE ON ENC_D: the console faceplate uses 7.2, not 7.0 -- "M7 thread; 7.0 was
# nominal-tight, the vendor STEP shows the thread OD needs the 0.2" (D_ENC in
# ../enclosure/segno_enclosure.py, #762). 7.0 is what was asked for here and an
# FDM hole tends to print under nominal, so if it will not pass the bush, that
# is the reason: re-run with --enc 7.2.

# ----------------------------------------------------------------------------
# THE DIFFUSER (mm)
# ----------------------------------------------------------------------------
AIR_GAP    = 3.0    # LED top -> roof underside. More = softer, taller part.
ROOF_T     = 1.0    # white PLA, ~5 layers at 0.2 -- the diffusing membrane
SKIRT_T    = 1.2    # outer shroud wall (kills side glare off the LED band)
SKIRT_CLR  = 0.20   # radial slip fit over the ring OD
SKIRT_DROP = 1.0    # how far the continuous shroud reaches below the PCB top

N_ARMS       = 3
ARM_W        = 7.0    # finger width, arc mm (narrow = flexes, wide = stiff)
ARM_T        = 0.9    # finger radial thickness -- this sets the snap strain
SLOT_W       = 1.2    # relief slot each side of a finger, arc mm
HOOK_ENGAGE  = 0.50   # how far the barb reaches under the PCB
HOOK_TIP     = 0.30   # flat on the barb tip (a knife edge will not print)
ARM_ANGLE_MARGIN = 5.0  # min degrees between a finger edge and a solder pad

SKIRT_ONLY = False   # True = no hooks, friction shroud only (ring lying flat)

STRAIN_LIMIT = 0.030  # PLA: fine for a hand-fitted part cycled a few times

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


# ----------------------------------------------------------------------------
# derived geometry
# ----------------------------------------------------------------------------
def _geom() -> dict:
    r_skirt_i = RING_OD / 2 + SKIRT_CLR
    hook_p = SKIRT_CLR + HOOK_ENGAGE          # barb protrusion off the wall
    roof_z0 = LED_H + AIR_GAP                 # roof underside, z=0 is PCB top
    hook_top = -PCB_T                         # barb meets the PCB's back face
    # retention face 45 deg up-and-out, flat tip, lead-in 45 deg down-and-out
    return {
        "r_skirt_i": r_skirt_i, "r_skirt_o": r_skirt_i + SKIRT_T,
        "r_enc": ENC_D / 2,
        "hook_p": hook_p, "roof_z0": roof_z0, "roof_z1": roof_z0 + ROOF_T,
        "hook_top": hook_top,
        "arm_bot": hook_top - 2 * hook_p - HOOK_TIP,
        "enc_face_z": LED_H + ENC_FACE_RISE,
        "arm_ang": math.degrees(ARM_W / r_skirt_i),
        "slot_ang": math.degrees(SLOT_W / r_skirt_i),
    }


def arm_angles() -> list[float]:
    """Clock N_ARMS fingers into the widest gaps between the solder pads."""
    pads = sorted(a % 360 for a in PAD_ANGLES)
    gaps = []
    for i, a in enumerate(pads):
        b = pads[(i + 1) % len(pads)]
        width = (b - a) % 360 or 360.0
        gaps.append((width, (a + width / 2) % 360))
    gaps.sort(reverse=True)                      # widest gap first
    return sorted(centre for _, centre in gaps[:N_ARMS])


# ----------------------------------------------------------------------------
def _pie(r: float, z0: float, z1: float, a_start: float, a_width: float):
    """Solid pie slice, r about the Z axis, spanning [a_start, a_start+a_width]."""
    s = cq.Solid.makeCylinder(r, z1 - z0, cq.Vector(0, 0, z0),
                              cq.Vector(0, 0, 1), a_width)
    return cq.Workplane("XY").newObject([s.rotate((0, 0, 0), (0, 0, 1), a_start)])


def _tube(r_i: float, r_o: float, z0: float, z1: float):
    return (cq.Workplane("XY", origin=(0, 0, z0))
            .circle(r_o).circle(r_i).extrude(z1 - z0))


def build():
    g = _geom()
    angles = arm_angles()
    _check(g, angles)

    # the diffusing face: ONE solid disc across the whole ring, pierced only by
    # the bush hole. This is the face that goes on the bed.
    part = _tube(g["r_enc"], g["r_skirt_o"], g["roof_z0"], g["roof_z1"])

    # outer shroud, continuous, over the LED band and the PCB edge
    part = part.union(_tube(g["r_skirt_i"], g["r_skirt_o"],
                            -SKIRT_DROP, g["roof_z0"]))

    if SKIRT_ONLY:
        solid = part.val()
        _check_clearances(solid, g)
        return solid

    # fingers: the shroud carried down past the PCB inside the arm sectors only
    sectors = None
    for a in angles:
        w = _pie(g["r_skirt_o"] + 1, g["arm_bot"] - 1, g["roof_z0"],
                 a - g["arm_ang"] / 2, g["arm_ang"])
        sectors = w if sectors is None else sectors.union(w)

    arms = _tube(g["r_skirt_i"], g["r_skirt_i"] + ARM_T,
                 g["arm_bot"], g["roof_z0"]).intersect(sectors)
    part = part.union(arms)

    # the barbs, revolved as one profile then kept only on the fingers
    r_tip = g["r_skirt_i"] - g["hook_p"]
    z_a = g["hook_top"]
    z_b = z_a - g["hook_p"]                       # 45 deg retention face
    z_c = z_b - HOOK_TIP                          # flat tip
    z_d = z_c - g["hook_p"]                       # 45 deg lead-in
    # NOTE: revolve()'s axis is in the WORKPLANE's own coordinates. On "XZ",
    # local +y IS global +z, so the axis is (0,1,0). Passing (0,0,1) revolves
    # about global -Y instead and yields a ZERO-VOLUME solid -- which then makes
    # the intersect below hand back the whole pie sectors. Silent, and the STL
    # still looks plausible. _check_clearances() is the trap for that class of
    # bug; this comment is the reason it exists.
    barb = (cq.Workplane("XZ")
            .moveTo(g["r_skirt_i"], z_a)
            .lineTo(r_tip, z_b).lineTo(r_tip, z_c)
            .lineTo(g["r_skirt_i"], z_d).close()
            .revolve(360, (0, 0, 0), (0, 1, 0)))
    assert barb.val().Volume() > 1.0, "barb revolve degenerated"
    part = part.union(barb.intersect(sectors))

    # relief slots each side of every finger -- without these the "cantilever"
    # is just a hoop and nothing flexes
    for a in angles:
        for side in (-1, 1):
            c = a + side * (g["arm_ang"] + g["slot_ang"]) / 2
            cutter = _pie(g["r_skirt_o"] + 2, g["arm_bot"] - 2, g["roof_z0"],
                          c - g["slot_ang"] / 2, g["slot_ang"])
            part = part.cut(cutter)

    solid = part.val()
    _check_clearances(solid, g)
    return solid


# ----------------------------------------------------------------------------
def _occupied(solid, r: float, a_deg: float, z: float) -> bool:
    """Is (r, angle, z) inside the printed part?"""
    from OCP.BRepClass3d import BRepClass3d_SolidClassifier
    from OCP.TopAbs import TopAbs_IN, TopAbs_ON
    a = math.radians(a_deg)
    c = BRepClass3d_SolidClassifier(solid.wrapped)
    c.Perform(cq.Vector(r * math.cos(a), r * math.sin(a), z).toPnt(), 1e-6)
    return c.State() in (TopAbs_IN, TopAbs_ON)


def _check_clearances(solid, g: dict) -> None:
    """Sample the volumes the part MUST NOT occupy, and the ones it must.

    Booleans fail quietly in CAD -- a degenerate operand gives you a solid that
    exports, renders and is wrong. These probes are the acceptance test.
    """
    probe = range(0, 360, 10)
    top = g["roof_z1"]

    # 1. the bush passage: clear from under the fingers all the way out the top
    for r in (0.0, g["r_enc"] * 0.5, g["r_enc"] - 0.3):
        for a in probe:
            for z in (g["arm_bot"] - 0.5, 0.0, g["roof_z0"] + ROOF_T / 2, top - 0.1):
                assert not _occupied(solid, r, a, z), (
                    f"material at r={r:.1f} a={a} z={z:.1f} blocks the bush")

    # 2. the encoder BODY: nothing of ours below its top face inside its envelope.
    #    This is the assumption the solid roof rests on -- if the encoder were
    #    taller than the roof, the middle could not be closed at all.
    assert g["roof_z0"] > g["enc_face_z"] + 0.5, (
        f"roof underside {g['roof_z0']:.2f} does not clear the encoder face "
        f"{g['enc_face_z']:.2f} -- raise AIR_GAP")
    for r in (ENC_BODY_D / 2 * f for f in (0.25, 0.5, 0.75, 0.98)):
        for a in probe:
            for z in (g["arm_bot"] - 0.5, -1.0, 0.5, g["enc_face_z"]):
                assert not _occupied(solid, r, a, z), (
                    f"material at r={r:.1f} a={a} z={z:.1f} fouls the encoder body")

    # 3. the ring's own space: PCB (z -PCB_T..0) and LEDs (z 0..LED_H)
    for r in (RING_ID / 2 + 0.6, (RING_OD + RING_ID) / 4, RING_OD / 2 - 0.6):
        for a in probe:
            for z in (-PCB_T + 0.2, -0.4, 0.3, LED_H - 0.2, LED_H + 0.2):
                assert not _occupied(solid, r, a, z), (
                    f"material at r={r:.1f} a={a} z={z:.1f} sits where the ring is")

    # 4. the face really is solid: over the LED band AND across the bore, all
    #    the way round, with only the bush hole missing
    z_mid = g["roof_z0"] + ROOF_T / 2
    for r in (g["r_enc"] + 0.4, RING_ID / 4, RING_ID / 2,
              (RING_OD + RING_ID) / 4, RING_OD / 2):
        for a in probe:
            assert _occupied(solid, r, a, z_mid), \
                f"hole in the face at r={r:.1f} a={a}"


def _check(g: dict, angles: list[float]) -> None:
    """Fit rules that a print cannot recover from."""
    assert RING_ID < RING_OD, "bore/OD are inconsistent"
    assert ENC_D < RING_ID - 4.0, "bush hole is not comfortably inside the bore"
    assert ENC_D > 6.0, "an EC11 bush is M7 -- a hole under 6 mm cannot pass it"

    # the LED band must be under the roof, not under the shroud wall
    r_led = (RING_OD + RING_ID) / 4
    assert g["r_skirt_i"] > r_led + 2.5, \
        f"LED centres r={r_led:.2f} are not clear of the shroud"

    if SKIRT_ONLY:
        return

    # no finger may land on a back-side solder pad
    for a in angles:
        for p in PAD_ANGLES:
            d = abs((a - p + 180) % 360 - 180)
            assert d > g["arm_ang"] / 2 + ARM_ANGLE_MARGIN, (
                f"finger at {a:.1f} deg is only {d:.1f} deg from the pad at "
                f"{p:.1f} deg -- it would seat on a solder joint")

    # the fingers must enclose the centre, or the cap rocks off
    seq = sorted(angles)
    spans = [(seq[(i + 1) % len(seq)] - a) % 360 for i, a in enumerate(seq)]
    assert max(spans) < 180.0, \
        f"fingers span {max(spans):.0f} deg with nothing opposite -- it will rock off"

    # snap strain: the finger has to open by hook_p to clear the ring OD
    L = g["roof_z0"] - (g["hook_top"] - g["hook_p"] / 2)   # root -> engagement
    strain = 3 * g["hook_p"] * ARM_T / (2 * L ** 2)
    assert strain < STRAIN_LIMIT, (
        f"snap strain {strain:.1%} over {STRAIN_LIMIT:.0%} -- thin ARM_T, "
        f"shorten HOOK_ENGAGE or raise the roof")
    assert HOOK_ENGAGE < PCB_T / 2, "barb reaches more than half across the PCB edge"


def report() -> None:
    g = _geom()
    angles = arm_angles()
    L = g["roof_z0"] - (g["hook_top"] - g["hook_p"] / 2)
    strain = 3 * g["hook_p"] * ARM_T / (2 * L ** 2)
    bottom = -SKIRT_DROP if SKIRT_ONLY else g["arm_bot"]
    print(f"  ring            O{RING_OD} / O{RING_ID} x {PCB_T} PCB")
    print(f"  part            O{2 * g['r_skirt_o']:.2f} outer, "
          f"solid face with a O{ENC_D} bush hole, "
          f"{g['roof_z1'] - bottom:.2f} tall")
    print(f"  face            {ROOF_T} mm, {AIR_GAP} mm over the LEDs, "
          f"{g['roof_z0'] - g['enc_face_z']:.2f} mm over the encoder body")
    if not SKIRT_ONLY:
        print(f"  fingers         {N_ARMS} at "
              f"{', '.join(f'{a:.0f}' for a in angles)} deg "
              f"(pads at {', '.join(f'{p:.0f}' for p in PAD_ANGLES)} deg)")
        print(f"  snap            {HOOK_ENGAGE} mm engagement, "
              f"{strain:.1%} strain, needs "
              f"{-g['arm_bot'] - PCB_T:.2f} mm of air under the ring")


def warn_off_spec() -> None:
    """PAD_ANGLES belong to the Adafruit Ring 16 and to nothing else."""
    if abs(RING_OD - 44.45) < 0.6 and abs(RING_ID - 31.75) < 0.6:
        return
    print(f"  ! O{RING_OD}/O{RING_ID} is not the Adafruit Ring 16, so the solder "
          f"pads are NOT at {', '.join(f'{p:.0f}' for p in PAD_ANGLES)} deg.\n"
          f"    Read the real angles off the back of YOUR ring and pass --pads, "
          f"or a finger will seat on a solder joint.")


def export(solid, name: str = "segno_ring16_diffuser") -> None:
    os.makedirs(OUT, exist_ok=True)
    base = os.path.join(OUT, os.path.basename(name))
    cq.exporters.export(solid, base + ".step")
    cq.exporters.export(solid, base + ".stl")
    for view, d in (("top", (0, 0, 1)), ("front", (0, -1, 0.15)),
                    ("iso", (1, -1, 0.8))):
        svg = f"{base}_{view}.svg"
        cq.exporters.export(
            solid, svg,
            opt={"projectionDir": d, "showAxes": False,
                 "strokeWidth": 0.3, "width": 640, "height": 480},
        )
        # cadquery emits width/height but no viewBox, so the drawing CLIPS
        # instead of scaling in anything that resizes it (a browser, a README).
        with open(svg) as fh:
            body = fh.read()
        if "viewBox" not in body:
            with open(svg, "w") as fh:
                fh.write(body.replace('height="480.0"',
                                      'height="480.0"\n   viewBox="0 0 640 480"', 1))
    print(f"wrote {os.path.basename(name)}.step / .stl (+ 3 SVG views) in {OUT}")


def main() -> None:
    global RING_OD, RING_ID, PCB_T, AIR_GAP, SKIRT_ONLY, PAD_ANGLES, ENC_D
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    p.add_argument("--od", type=float, help="measured ring outer diameter")
    p.add_argument("--id", type=float, dest="bore", help="measured ring bore")
    p.add_argument("--pcb", type=float, help="ring PCB thickness")
    p.add_argument("--gap", type=float, help="air gap over the LEDs")
    p.add_argument("--enc", type=float, help="bush hole diameter (7.2 if 7.0 binds)")
    p.add_argument("--pads", type=float, nargs="+", metavar="DEG",
                   help="back-side solder-pad angles on YOUR ring (deg)")
    p.add_argument("--skirt-only", action="store_true",
                   help="no hooks: friction shroud, for a ring lying flat")
    p.add_argument("--name", default="segno_ring16_diffuser")
    a = p.parse_args()
    if a.od:
        RING_OD = a.od
    if a.bore:
        RING_ID = a.bore
    if a.pcb:
        PCB_T = a.pcb
    if a.gap:
        AIR_GAP = a.gap
    if a.enc:
        ENC_D = a.enc
    if a.pads:
        PAD_ANGLES = tuple(a.pads)
    SKIRT_ONLY = a.skirt_only
    report()
    warn_off_spec()
    export(build(), a.name)


if __name__ == "__main__":
    main()
