#!/usr/bin/env python3
"""
Terminal-end SHROUD for the console's 5 V supply (issues #754, #755).

The console runs off ONE external 5 V supply. The cheap way to get 100 W at 5 V
is an open-frame metal-cased unit (S-100 / LRS-100 class) rather than a sealed
brick, because every sealed 5 V/15 A brick on the market terminates its output in
a 5.5x2.1 barrel rated about a third of the supply's own output.

That unit needs a secondary enclosure -- but NOT a box around it:

  * Its steel case is already the primary enclosure. Wrapping it in plastic
    duplicates that and traps the ~15 W it dissipates at full load.
  * The only genuinely exposed hazard is the screw TERMINAL BLOCK, and on this
    class of supply that block is on ONE END FACE (AC L/N/E, then V-/V+).
  * So the part is a single end cap: it shrouds that face, carries the fused
    IEC C14 inlet and the GX20-4 output, and leaves every vent clear.

SAFETY, and none of this is optional:

  * The supply's metal chassis MUST be bonded to the IEC earth pin. A printed
    box earths nothing. Run green/yellow from the inlet's earth tab to the
    supply's earth screw -- that is the FIRST wire you fit and the last you
    remove.
  * Mains and DC do not share a channel in here. The divider rib is structural
    to that, not decoration; MAINS_DC_GAP is gated below.
  * PETG is not flame-retardant. It is defensible ONLY because it is a secondary
    shroud over a steel case. Do not reuse this part as a primary enclosure for
    anything mains-powered.

==> Every dimension tagged  # MEASURE  is a fit dimension against a supply that
    has not been bought yet. Clone case sizes and screw positions vary. Measure
    the real unit, set them, re-run, and only then print.

Outputs (./out):  STEP (CAD, editable) + STL (print).
Run:  ../enclosure/.venv/bin/python psu_shroud.py
"""
from __future__ import annotations
import os
import cadquery as cq

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# ---------------------------------------------------------------------------
# THE SUPPLY  -- S-100 / LRS-100 class, 5 V 20 A 100 W.  ALL # MEASURE.
# ---------------------------------------------------------------------------
CASE_W      = 99.0    # across the terminal end face        # MEASURE
CASE_H      = 38.0    # case height                         # MEASURE
CASE_L      = 199.0   # overall length (context only)       # MEASURE
SCREW_DX    = 88.0    # side-screw spacing across the case  # MEASURE
SCREW_DZ    = 20.0    # side-screw height above the base    # MEASURE
SCREW_INSET = 12.0    # side screw, back from the terminal face  # MEASURE
SCREW_D     = 4.2     # M4 clearance into the case's own tapped holes

# Terminal block: the thing being shrouded. Depth is what sets how far the cap
# has to stand off the end face -- screw heads, ring terminals and the wire's
# first bend all live in here.
TERM_H      = 22.0    # block height on the end face        # MEASURE
TERM_DEPTH  = 16.0    # block + screw heads proud of the face  # MEASURE
WIRE_BEND   = 18.0    # room past the terminals for 16 AWG to turn
CASE_OVERLAP = 16.0   # how far the cap swallows the case before the end face.
                      # Without this the skirt butts against the case instead of
                      # gripping it, and the side screws land in fresh air --
                      # which is exactly what the first version did.

# ---------------------------------------------------------------------------
# CONNECTORS
# ---------------------------------------------------------------------------
# Fused IEC C14, snap-in. The fuse that used to live on the console's rear panel
# comes HERE: at 5 V/12 A the console-side station could not be fused sensibly
# (5x20 holders stop at 6.3-10 A), whereas on the mains side the same protection
# is ~0.5 A and entirely ordinary.
IEC_W       = 27.5    # snap-in cutout width                # MEASURE (datasheet varies)
IEC_H       = 19.5    # snap-in cutout height               # MEASURE
IEC_FILLET  = 1.5

GX20_D      = 20.5    # GX20-4 panel hole, matches D_GX20 in segno_enclosure.py
GX20_NUT_D  = 26.0    # nut/flange clearance around it

# ---------------------------------------------------------------------------
# PRINT + SAFETY
# ---------------------------------------------------------------------------
WALL         = 3.0    # PETG, 0.4 nozzle: 3.0 is a clean 7-8 perimeters and
                      # stiff enough that the IEC's snap tabs have something to
                      # bite. Also the finger-safety barrier, so not thinner.
FLOOR        = 3.0
MAINS_DC_GAP = 12.0   # clear air between the mains channel and the DC channel
FIT          = 0.4    # slip fit over the case (PETG, 0.4 nozzle)
CORNER_R     = 3.0
VENT_SLOT    = (18.0, 3.0)   # slots in the cap's own roof: the supply breathes
VENT_COLS    = 6             # through its case, but the cap must not become a
VENT_MARGIN  = 8.0           # pocket over the terminals


def _cavity_depth():
    """Case overlap + the terminal block + room for the wire to turn."""
    return CASE_OVERLAP + TERM_DEPTH + WIRE_BEND


def build():
    """The end cap, printed open-face-down (the face that slips over the case)."""
    inner_w = CASE_W + 2 * FIT
    inner_h = CASE_H + 2 * FIT
    depth = _cavity_depth()
    outer_w = inner_w + 2 * WALL
    outer_h = inner_h + 2 * WALL
    outer_d = depth + FLOOR

    # Shell: a box with the case-side face open.
    cap = (cq.Workplane("XY")
           .box(outer_w, outer_d, outer_h, centered=(True, False, False))
           .edges("|Y").fillet(CORNER_R))
    cavity = (cq.Workplane("XY")
              .box(inner_w, depth + 1.0, inner_h, centered=(True, False, False))
              .translate((0, -0.5, WALL)))
    cap = cap.cut(cavity)

    # The supply's case slides in this far; the cap lands on nothing but the
    # case sides, so the terminal face is never loaded.
    face = cq.Workplane("XZ", origin=(0, outer_d, 0))

    # IEC inlet, mains side (left of centre).
    iec_x = -(inner_w / 4.0)
    iec_z = WALL + inner_h / 2.0
    iec = (cq.Workplane("XZ", origin=(iec_x, outer_d + 1.0, iec_z))
           .rect(IEC_W, IEC_H).extrude(-(WALL + 2.0)))
    cap = cap.cut(iec)

    # GX20 output, DC side (right of centre).
    gx_x = inner_w / 4.0
    gx = (cq.Workplane("XZ", origin=(gx_x, outer_d + 1.0, iec_z))
          .circle(GX20_D / 2.0).extrude(-(WALL + 2.0)))
    cap = cap.cut(gx)

    # Divider rib: mains channel one side, DC the other. It lives ONLY in the
    # wire zone past the terminal block -- running it the full depth would drive
    # it into the block itself -- and it is fused to the cavity floor, roof and
    # back face so it prints as one body. (v1 floated it 1 mm off the floor,
    # which _print_check caught as a second loose solid and an island.)
    rib_y0 = CASE_OVERLAP + TERM_DEPTH
    rib = (cq.Workplane("XY")
           .box(WALL, depth - rib_y0, inner_h, centered=(True, False, False))
           .translate((0, rib_y0, WALL)))
    cap = cap.union(rib)

    # Side screw holes into the supply's own tapped case holes.
    for sx in (-SCREW_DX / 2.0, SCREW_DX / 2.0):
        hole = (cq.Workplane("YZ", origin=(sx - WALL - 1.0, SCREW_INSET, WALL + SCREW_DZ))
                .circle(SCREW_D / 2.0).extrude(2 * (WALL + 1.0)))
        cap = cap.cut(hole)

    # Vents, so the cap is not a sealed pocket over the terminal block.
    # They run the LONG way along the print's Z: laid the other way each slot's
    # top edge is an 18 mm bridge in a vertical wall and the slicer asks for
    # support (which _print_check flagged as 6 patches). Turned 90 deg, every
    # slot tops out over a 3 mm span and bridges itself.
    sl, sw = VENT_SLOT
    n = VENT_COLS
    pitch = (inner_w - 2 * VENT_MARGIN - sw) / (n - 1)
    y0 = CASE_OVERLAP + TERM_DEPTH * 0.5      # over the terminal zone, not the case
    for i in range(n):
        sx = -inner_w / 2.0 + VENT_MARGIN + sw / 2.0 + i * pitch
        slot = (cq.Workplane("XY", origin=(sx, y0, outer_h - WALL - 1.0))
                .rect(sw, sl).extrude(WALL + 2.0))
        cap = cap.cut(slot)
    return cap


def _check():
    """Gates. Each has a negative control noted -- change the named constant and
    the gate fires."""
    inner_w = CASE_W + 2 * FIT
    depth = _cavity_depth()

    # 1. Room past the terminal screws for the wire to turn. Written against
    #    WIRE_BEND, because the cavity is DEFINED as TERM_DEPTH + WIRE_BEND --
    #    phrasing it as "depth >= TERM_DEPTH + x" is a tautology that no value of
    #    TERM_DEPTH can ever break, which is exactly how it first got written.
    #    Control: WIRE_BEND below 12.
    assert WIRE_BEND >= 12.0, (
        f"WIRE_BEND: {WIRE_BEND:.1f} mm past the terminal screws will not let "
        "16 AWG turn -- the cap closes onto the wiring, not over it")

    # 2. Mains and DC cutouts must stay apart. Control: raise IEC_W or GX20_NUT_D.
    iec_right = -(inner_w / 4.0) + IEC_W / 2.0
    gx_left = inner_w / 4.0 - GX20_NUT_D / 2.0
    assert gx_left - iec_right >= MAINS_DC_GAP, (
        f"MAINS_DC: only {gx_left - iec_right:.1f} mm between the IEC cutout and "
        f"the GX20 flange, need {MAINS_DC_GAP:.0f} -- mains and DC would share air "
        "inside the cap")

    # 3. Both cutouts must fit the end face with a wall left. Control: CASE_H down.
    assert IEC_H + 2 * WALL <= CASE_H + 2 * FIT, (
        f"FACE_FIT: the IEC cutout ({IEC_H:.1f}) plus walls does not fit a "
        f"{CASE_H:.1f} mm case height")
    assert GX20_NUT_D + 2 * WALL <= CASE_H + 2 * FIT, (
        f"FACE_FIT: the GX20 flange ({GX20_NUT_D:.1f}) plus walls does not fit a "
        f"{CASE_H:.1f} mm case height")

    # 4a. The side screws must bite the CASE, so they have to sit inside the
    #     overlap -- not merely inside the cavity. Control: SCREW_INSET past
    #     CASE_OVERLAP.
    assert SCREW_INSET <= CASE_OVERLAP - 2.0, (
        f"SCREW_GRIP: screw inset {SCREW_INSET:.1f} is past the {CASE_OVERLAP:.1f} mm "
        "the cap overlaps the case -- it would screw into thin air, not the case")
    # 4b. ...and still inside the skirt. Control: SCREW_INSET beyond the cavity.
    assert 3.0 <= SCREW_INSET <= depth - 3.0, (
        f"SCREW_REACH: screw inset {SCREW_INSET:.1f} is not inside the cap's "
        f"{depth:.1f} mm skirt")

    # 5. Finger safety: the barrier over live terminals is the wall, so it does
    #    not get thinned for print time. Control: WALL below 2.0.
    assert WALL >= 2.0, (
        f"BARRIER: {WALL:.1f} mm wall over mains terminals is not a barrier")
    return True


def export(solid, name="segno_psu_shroud"):
    os.makedirs(OUT, exist_ok=True)
    step = os.path.join(OUT, name + ".step")
    stl = os.path.join(OUT, name + ".stl")
    cq.exporters.export(solid, step)
    cq.exporters.export(solid, stl, tolerance=0.01, angularTolerance=0.1)
    return step, stl


if __name__ == "__main__":
    _check()
    print("Geometry assertions ... ALL PASS")
    cap = build()
    # Print orientation: lay the CONNECTOR FACE on the bed so the cavity opens
    # upward. Printed as modelled it stands on its side and has to bridge the
    # whole cavity roof -- 3147 mm2 of unsupported start. This way the first
    # layer is the flat connector face, the skirt walls rise, and the only
    # overhangs left are the vent slots.
    cap = cap.rotate((0, 0, 0), (1, 0, 0), -90)
    bb = cap.val().BoundingBox()
    cap = cap.translate((0, 0, -bb.zmin))
    bb = cap.val().BoundingBox()
    print("cap envelope: %.1f x %.1f x %.1f mm  (bed 220x220: %s)" % (
        bb.xlen, bb.ylen, bb.zlen,
        "fits" if max(bb.xlen, bb.ylen) < 210 else "DOES NOT FIT"))
    s, t = export(cap)
    print("wrote", os.path.relpath(s), "+", os.path.relpath(t))
