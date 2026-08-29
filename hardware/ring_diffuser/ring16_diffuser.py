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
        take this part -- print --skirt-only instead, and read SKIRT_CLR: that
        variant has nothing holding it on but the fit, and the default fit is a
        slip fit.

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
SKIRT_CLR  = 0.20   # radial SLIP fit over the ring OD. The hooks are what hold
                    # the cap on, so the shroud is deliberately loose.
                    # --skirt-only has no hooks and nothing else to hold it: at
                    # 0.20 it drops on and drops off again. A shroud that grips a
                    # O44 bore by friction alone is not something CAD settles --
                    # FDM runs +-0.1..0.2 there, which straddles both "will not go
                    # on" and "falls off" -- so dial it in with --clr on the
                    # printer that will make it (start ~0.05) rather than trusting
                    # this number.
SKIRT_DROP = 1.0    # how far the shroud reaches below the PCB top -- the WISH.
                    # _geom() clamps it to PCB_T, because --skirt-only is for a
                    # ring lying FLAT and a hem past its back face lands on the
                    # bench and lifts the cap off. Clamped rather than asserted:
                    # this is a module constant with no flag, so on a --pcb 0.8
                    # ring an assert would be a dead end with no way out but
                    # editing the source.

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
    skirt_drop = min(SKIRT_DROP, PCB_T)       # see SKIRT_DROP
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
        "skirt_drop": skirt_drop,
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
    assert len(gaps) >= N_ARMS, (
        f"{len(gaps)} pad gap(s) for {N_ARMS} fingers -- a cap with fewer hooks "
        f"than asked for cannot stay on. Pass every pad on YOUR ring to --pads, "
        f"or lower --arms deliberately")
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
    # No fingers in --skirt-only, so do not ask arm_angles() about them: it
    # asserts there are enough pad gaps for N_ARMS, and refusing to build the
    # HOOKLESS variant over a shortage of hooks is exactly backwards -- that
    # variant is the documented fallback for rings the hooks cannot take.
    angles = [] if SKIRT_ONLY else arm_angles()
    _check(g, angles)

    # the diffusing face: ONE solid disc across the whole ring, pierced only by
    # the bush hole. This is the face that goes on the bed.
    part = _tube(g["r_enc"], g["r_skirt_o"], g["roof_z0"], g["roof_z1"])

    # outer shroud over the LED band and the PCB edge. It goes on full-circle here
    # and the relief slots take 6 x SLOT_W out of it further down, so the finished
    # rim is not light-tight -- the slots are what let the fingers flex at all.
    part = part.union(_tube(g["r_skirt_i"], g["r_skirt_o"],
                            -g["skirt_drop"], g["roof_z0"]))

    if SKIRT_ONLY:
        solid = part.val()
        _check_clearances(solid, g, [])
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

    # ...and take the SHROUD back to ARM_T inside those sectors. Without this the
    # finger is only ARM_T thick below the shroud's hem: above
    # that the union with the SKIRT_T shroud makes it 1.2, i.e. the root -- where
    # bending strain is highest -- is a third thicker than the number _check()
    # reasons about. ARM_T is documented as the constant that sets the snap
    # strain, so the geometry is made to agree with that rather than the other
    # way round. _check_clearances() re-measures it off the finished solid.
    part = part.cut(_tube(g["r_skirt_i"] + ARM_T, g["r_skirt_o"] + 1,
                          g["arm_bot"] - 1, g["roof_z0"]).intersect(sectors))

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
    _check_clearances(solid, g, angles)
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


def _check_clearances(solid, g: dict, angles: list[float]) -> None:
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

    # 3. the ring's own space: PCB (z -PCB_T..0) and LEDs (z 0..LED_H).
    #    The last two radii are the point of this probe: everything inboard of
    #    the barb tip is trivially clear, so sampling only there would pass even
    #    with the barbs revolved straight through the LED band. r just inside the
    #    PCB edge catches a barb at the wrong height; r just inside the shroud
    #    bore catches a shroud that has eaten its own clearance.
    for r in (RING_ID / 2 + 0.6, (RING_OD + RING_ID) / 4, RING_OD / 2 - 0.6,
              RING_OD / 2 - 0.1, g["r_skirt_i"] - 0.05):
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

    # 5. the finger really is ARM_T thick where it bends. _check()'s strain is a
    #    uniform-cantilever formula, so it is only true if the root is ARM_T --
    #    and the root is where the shroud wants to make it SKIRT_T. Measured just
    #    under the roof, which is the highest-moment section.
    z_root = g["roof_z0"] - 0.3
    for a in angles:
        assert _occupied(solid, g["r_skirt_i"] + ARM_T - 0.1, a, z_root), \
            f"finger at {a:.0f} deg is thinner than ARM_T at its root"
        assert not _occupied(solid, g["r_skirt_i"] + ARM_T + 0.1, a, z_root), (
            f"finger at {a:.0f} deg is thicker than ARM_T at its root -- the "
            f"strain _check() reports is not the strain the part will see")


def _check(g: dict, angles: list[float]) -> None:
    """Fit rules that a print cannot recover from."""
    assert RING_ID < RING_OD, "bore/OD are inconsistent"
    assert ENC_D < RING_ID / 2.0, (
        f"bush hole O{ENC_D} is more than half the O{RING_ID} bore -- there is no "
        f"face left to diffuse through, and the roof probes would report it as a "
        f"hole in the face rather than as this")
    assert ENC_D < RING_ID - 4.0, "bush hole is not comfortably inside the bore"
    assert SKIRT_CLR >= 0.0, (
        f"--clr {SKIRT_CLR} is negative: the shroud would be smaller than the ring "
        f"and the barb wire degenerates with an OCC error that says nothing")
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
    # ...and three is the floor. With one finger the span list is [0] and with two
    # it is [d, 360-d]; the first passes the test below vacuously, which is how a
    # one-hook cap got built. Two hooks give a hinge, not a mount.
    assert len(seq) >= 3, (
        f"{len(seq)} finger(s): a cap needs at least 3 to sit flat. --arms 1 or 2 "
        f"builds something that pivots off")
    spans = [(seq[(i + 1) % len(seq)] - a) % 360 for i, a in enumerate(seq)]
    assert max(spans) < 180.0, (
        f"fingers span {max(spans):.0f} deg with nothing opposite -- it will rock "
        f"off. Evenly spaced pads do this to an odd finger count: try --arms 4")

    # Snap strain. The finger opens by HOOK_ENGAGE, NOT by hook_p: the barb tip
    # sits at r_skirt_i - hook_p, which is RING_OD/2 - HOOK_ENGAGE once SKIRT_CLR
    # cancels, so the clearance is already air and nothing has to flex through it.
    # Using hook_p read 0.7 of deflection for a 0.5 reality -- conservative, but it
    # also made the published strain move whenever --clr moved, which is nonsense.
    # Uniform-cantilever formula, so it is only true while the finger is ARM_T
    # thick at the root -- build() cuts the shroud back to keep that so, and
    # _check_clearances() probe 5 measures it off the solid.
    L = g["roof_z0"] - (g["hook_top"] - g["hook_p"] / 2)   # root -> engagement
    strain = 3 * HOOK_ENGAGE * ARM_T / (2 * L ** 2)
    assert strain < STRAIN_LIMIT, (
        f"snap strain {strain:.1%} over {STRAIN_LIMIT:.0%} -- thin ARM_T, "
        f"shorten HOOK_ENGAGE or raise the roof")
    assert HOOK_ENGAGE < PCB_T / 2, "barb reaches more than half across the PCB edge"


def report() -> None:
    g = _geom()
    angles = [] if SKIRT_ONLY else arm_angles()
    L = g["roof_z0"] - (g["hook_top"] - g["hook_p"] / 2)
    strain = 3 * HOOK_ENGAGE * ARM_T / (2 * L ** 2)
    bottom = -g["skirt_drop"] if SKIRT_ONLY else g["arm_bot"]
    print(f"  ring            O{RING_OD} / O{RING_ID} x {PCB_T} PCB")
    print(f"  part            O{2 * g['r_skirt_o']:.2f} outer, "
          f"solid face with a O{ENC_D} bush hole, "
          f"{g['roof_z1'] - bottom:.2f} tall")
    print(f"  face            {ROOF_T} mm, {AIR_GAP} mm over the LEDs, "
          f"{g['roof_z0'] - g['enc_face_z']:.2f} mm over the encoder body")
    if not SKIRT_ONLY:
        print(f"  fingers         {len(angles)} at "
              f"{', '.join(f'{a:.0f}' for a in angles)} deg "
              f"(pads at {', '.join(f'{p:.0f}' for p in PAD_ANGLES)} deg)")
        print(f"  snap            {HOOK_ENGAGE} mm engagement, "
              f"{strain:.1%} strain, needs "
              f"{-g['arm_bot'] - PCB_T:.2f} mm of air under the ring")


def warn_off_spec(pads_given: bool) -> None:
    """PAD_ANGLES belong to the Adafruit Ring 16 and to nothing else.

    Silent once --pads is supplied: at that point the angles came off the ring in
    hand, which is exactly what the warning asks for. Shouting anyway trains
    people to ignore it.
    """
    if pads_given:
        return
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
    w, h = 640, 480
    for view, d in (("top", (0, 0, 1)), ("front", (0, -1, 0.15)),
                    ("iso", (1, -1, 0.8))):
        svg = f"{base}_{view}.svg"
        cq.exporters.export(
            solid, svg,
            opt={"projectionDir": d, "showAxes": False,
                 "strokeWidth": 0.3, "width": w, "height": h},
        )
        # cadquery emits width/height but no viewBox, so the drawing CLIPS
        # instead of scaling in anything that resizes it (a browser, a README).
        # The canvas comes from w/h above so the two cannot drift apart, and a
        # miss is raised: cadquery formats the attribute, and if that formatting
        # ever changes this would quietly go back to writing clipped SVGs.
        with open(svg) as fh:
            body = fh.read()
        if "viewBox" not in body:
            needle = f'height="{float(h)}"'
            assert needle in body, (
                f"{os.path.basename(svg)}: no {needle} to hang a viewBox on -- "
                f"cadquery changed its attribute formatting")
            with open(svg, "w") as fh:
                fh.write(body.replace(needle, f'{needle}\n   viewBox="0 0 {w} {h}"', 1))
    print(f"wrote {os.path.basename(name)}.step / .stl (+ 3 SVG views) in {OUT}")


def main() -> None:
    global RING_OD, RING_ID, PCB_T, AIR_GAP, SKIRT_ONLY, PAD_ANGLES, ENC_D
    global SKIRT_CLR, N_ARMS
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    p.add_argument("--od", type=float, help="measured ring outer diameter")
    p.add_argument("--id", type=float, dest="bore", help="measured ring bore")
    p.add_argument("--pcb", type=float, help="ring PCB thickness")
    p.add_argument("--gap", type=float, help="air gap over the LEDs")
    p.add_argument("--enc", type=float, help="bush hole diameter (7.2 if 7.0 binds)")
    p.add_argument("--pads", type=float, nargs="+", metavar="DEG",
                   help="back-side solder-pad angles on YOUR ring (deg)")
    p.add_argument("--clr", type=float,
                   help="radial clearance over the ring OD (0.20 slip; go ~0.05 "
                        "for a --skirt-only shroud that has to grip)")
    def _arms(v):
        n = int(v)
        if n < 3:
            raise argparse.ArgumentTypeError(
                "at least 3 -- fewer cannot hold a cap flat")
        return n
    p.add_argument("--arms", type=_arms,
                   help=f"number of snap fingers (default {N_ARMS}); a ring whose "
                        f"pads leave no {N_ARMS}-gap spread needs 4")
    p.add_argument("--skirt-only", action="store_true",
                   help="no hooks, for a ring lying flat -- see --clr, nothing "
                        "else holds it on")
    p.add_argument("--name", help="output base name (default "
                                  "segno_ring16_diffuser, or ..._skirt with "
                                  "--skirt-only)")
    a = p.parse_args()
    # `is not None`, not truthiness: 0.0 is a legitimate value for --gap and
    # --clr, and swallowing it silently builds a part nobody asked for.
    if a.od is not None:
        RING_OD = a.od
    if a.bore is not None:
        RING_ID = a.bore
    if a.pcb is not None:
        PCB_T = a.pcb
    if a.gap is not None:
        AIR_GAP = a.gap
    if a.enc is not None:
        ENC_D = a.enc
    if a.clr is not None:
        SKIRT_CLR = a.clr
    if a.arms is not None:
        N_ARMS = a.arms
    if a.pads:
        PAD_ANGLES = tuple(a.pads)
    SKIRT_ONLY = a.skirt_only
    # The two variants are DIFFERENT PARTS and must not share a base name: the
    # README says "print --skirt-only instead", and with one default that
    # sentence overwrites the hooked STEP/STL/SVGs in out/ with a hookless cap.
    name = a.name or ("segno_ring16_diffuser_skirt" if SKIRT_ONLY
                      else "segno_ring16_diffuser")
    report()
    warn_off_spec(bool(a.pads))
    export(build(), name)


if __name__ == "__main__":
    main()
