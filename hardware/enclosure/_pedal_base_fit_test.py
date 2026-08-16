#!/usr/bin/env python
"""Fit-test jig for the pedal's BASE screw holes (issue #716).

Before the four base-hole positions get committed to the real pedestal decks as
heat-set insert bores, this proves them on a throwaway print. The jig carries
nothing but the two features that have to agree with the pedal:

  PINS     four Ø2.7 locating pins on the PEDAL_BASE_* pattern. They stand
           5.2 mm proud, which is the 2.2 mm anti-slip pad plus 3.0 mm of
           engagement in the hole -- the pad stays ON, exactly as it does on
           the real pedestal.
  COLUMNS  one per side at the horizontal shell screw, each split by a vertical
           channel the 10 mm boss drops into, cut ALL THE WAY DOWN to the plate
           so nothing can stop the boss short. Same idiom (and the same
           SKIRT_BOSS_CH_* numbers) as the tub side walls in
           build_mini_console; here they stand alone so they can be judged.

Pass = the pedal drops onto all four pins and both bosses land in their
channels with the case sitting flat. Fail = it rocks, sits proud, or a boss
lands on a prong instead of in the slot.

The scribed outline is the case footprint, and it is a TRAPEZOID: the WTB-006
is a wedge in plan as well as in height, 76.35 wide at the back tapering to
73.08 at the toe over its 109.87 length. Scribing the widest section as a
rectangle would leave a correctly-placed pedal looking inset at the toe --
which is exactly the misreading the line is there to prevent. Every clearance
in this file is likewise taken from pedal_half_width() at the station it
applies to, never from PEDAL_W. The engraved arrow points to the TOE.

    python _pedal_base_fit_test.py
    python _print_check.py out/segno_pedal_base_fit_test.stl
"""

from __future__ import annotations

import os

import cadquery as cq

from segno_enclosure import (
    OUT,
    PEDAL_BASE_HOLE_D,
    PEDAL_BASE_SPAN_FRONT,
    PEDAL_BASE_SPAN_REAR,
    PEDAL_BODY_H,
    PEDAL_D,
    PEDAL_PAD_BACK_INSET,
    PEDAL_PAD_D,
    PEDAL_PAD_T,
    PEDAL_PAD_W,
    PEDAL_SCREW_BOSS_D,
    PEDAL_SCREW_SPAN,
    PEDAL_SCREW_Z,
    PEDAL_TOE_W,
    PEDAL_W,
    SKIRT_BOSS_CH_HALF,
    SKIRT_BOSS_CH_W,
    SKIRT_BOSS_CH_X,
    pedal_base_holes,
    pedal_half_width,
)

# --- jig parameters -----------------------------------------------------------
PLATE_T      = 2.4    # solid, prints flat-down: full bed contact, no feet, no
                      # bridging. The failure that killed the first mini tray
                      # (#539) was a floor standing on pads; this has none.
                      # 12 layers at 0.2 -- 40% off the old 4.0 and most of the
                      # print time, since the plate is nearly all of the volume.
                      # Not thinner: this plate is the measurement DATUM, and a
                      # gauge that curls reports a placement error that is
                      # really its own. _print_check.py is the arbiter.
PLATE_MARGIN = 5.0    # plate edge past the outermost feature
CORNER_R     = 4.0    # square corners peel first
BOT_CHAM     = 0.6    # kills elephant foot

PIN_CLR   = 0.5       # pin Ø under the hole Ø -- drops in by hand, no play worth
                      # reading as a placement error
PIN_D     = 3.5       # user's call 2026-08-16, and it is what fixes the hole Ø:
                      # a 3.5 pin cannot enter the 3.2 hole first described, so
                      # PEDAL_BASE_HOLE_D is now the INFERRED 4.0. The assert
                      # below keeps the two from drifting apart again.
PIN_LEAD  = 0.5       # top chamfer -> Ø2.5 tip, so a near-miss still starts
# The hole DEPTH is the one number nobody has measured. A pin longer than the
# hole is deep bottoms out and holds the pedal proud -- which reads exactly like
# a placement error, i.e. it would poison the very result this jig exists to
# produce. So assume little and engage little: a placement test only needs the
# pin to ENTER.
HOLE_DEPTH_MIN = 4.0
PIN_ENGAGE     = 3.0
PIN_H          = PEDAL_PAD_T + PIN_ENGAGE        # 5.2: through the pad, then in

COL_H         = 20.0  # column top, above the plate face
COL_SIDE_CLR  = 1.0   # inner face off the case side wall AT THE COLUMN STATION.
                      # Measured against pedal_half_width, not PEDAL_W/2: the case
                      # is a wedge in plan, so a clearance quoted off the back-edge
                      # width flatters itself by ~0.35 mm here and by ~1.6 at the
                      # toe. Nothing on this jig stands near the toe, but the
                      # number should still mean what it says.
COL_PRONG     = 7.0   # material fore and aft of the boss channel
COL_WEB       = 3.5   # outer wall joining the two prongs behind the channel
COL_CH_Z0     = 0.0   # channel runs ALL THE WAY DOWN to the plate face, same as
                      # the tray's tub walls. A plinth under the boss (this was
                      # 5.0) buys stiffness the outer web and the gusset already
                      # provide, and it puts a floor under the one feature whose
                      # free travel the test depends on -- if the pattern is off
                      # and the pedal sits down-and-forward, a plinth stops the
                      # boss early and the jig reports its own obstruction.
COL_GUSSET    = 3.0   # 45deg ramp, outer face only (the inner face is the
                      # pedal's clearance and must stay flat)

SCRIBE_W = 1.0        # engraved line width
SCRIBE_D = 0.5        # ...and depth

COL_Y_IN  = pedal_half_width(SKIRT_BOSS_CH_X) + COL_SIDE_CLR   # 38.829
COL_Y_OUT = SKIRT_BOSS_CH_HALF + COL_WEB         # 45.825
COL_X_LEN = SKIRT_BOSS_CH_W + 2*COL_PRONG        # 28.0
PLATE_HW  = COL_Y_OUT + COL_GUSSET + PLATE_MARGIN
PLATE_HD  = PEDAL_D/2.0 + PLATE_MARGIN

# boss centre height above the PLATE FACE: the pedal stands on its pad
BOSS_Z = PEDAL_PAD_T + PEDAL_SCREW_Z             # 12.30


def _check():
    """The jig is only worth printing if it cannot itself be the reason a good
    pedal fails to seat."""
    holes = pedal_base_holes()
    assert len(holes) == 4, "PINS: expected four base holes"
    assert max(abs(hy) for _, hy in holes) + PIN_D/2.0 < COL_Y_IN - 0.5, \
        "PINS: a pin lands under a column"
    assert BOSS_Z - PEDAL_SCREW_BOSS_D/2.0 >= COL_CH_Z0 + 1.0, \
        f"COLUMN: boss bottom {BOSS_Z - PEDAL_SCREW_BOSS_D/2.0:.2f} sits on the channel floor"
    assert BOSS_Z + PEDAL_SCREW_BOSS_D/2.0 <= COL_H - 1.0, \
        "COLUMN: too short to capture the boss"
    assert COL_Y_IN > pedal_half_width(SKIRT_BOSS_CH_X), "COLUMN: inner face pinches the case"
    assert SKIRT_BOSS_CH_HALF > PEDAL_SCREW_SPAN/2.0, "COLUMN: channel too shallow for the boss tip"
    assert COL_Y_OUT + COL_GUSSET <= PLATE_HW - 1.0, "PLATE: gusset runs off the edge"
    assert PIN_ENGAGE >= 2.0, "PINS: too little engagement past the anti-slip pad to prove entry"
    assert PIN_ENGAGE <= HOLE_DEPTH_MIN - 0.5, \
        "PINS: pin can bottom out in the hole and hold the pedal proud"
    assert max(abs(hx) for hx, _ in holes) + PIN_D/2.0 < PLATE_HD, "PINS: a pin runs off the plate"
    assert PIN_D <= PEDAL_BASE_HOLE_D - 0.3, (
        f"PINS: Ø{PIN_D} pin cannot enter a Ø{PEDAL_BASE_HOLE_D} hole -- the pin "
        "diameter and the hole diameter have drifted apart, fix the measurement")


def _pedal_stand_in():
    """The pedal as the jig has to see it, SEATED: bottom pad, case, the two side
    screw bosses, and the four base holes bored out. Same frame as
    pedal_base_holes(), z=0 at the plate face.

    The case is the real PLAN TRAPEZOID (PEDAL_W at the back, PEDAL_TOE_W at the
    toe), so the gate reports the clearance that actually exists rather than a
    conservative box. Height stays prismatic at PEDAL_BODY_H, the back (tall)
    figure: the case also slopes down toward the toe, but nothing on this jig
    reaches anywhere near the top, so the extra is free margin."""
    ped = (cq.Workplane("XY")
           .box(PEDAL_PAD_D, PEDAL_PAD_W, PEDAL_PAD_T, centered=(True, True, False))
           .translate((PEDAL_D/2.0 - PEDAL_PAD_BACK_INSET - PEDAL_PAD_D/2.0, 0, 0)))
    xb, xt = PEDAL_D/2.0, -PEDAL_D/2.0
    yb, yt = pedal_half_width(xb), pedal_half_width(xt)
    ped = ped.union(cq.Workplane("XY")
                    .polyline([(xb, yb), (xb, -yb), (xt, -yt), (xt, yt)]).close()
                    .extrude(PEDAL_BODY_H).translate((0, 0, PEDAL_PAD_T)))
    for s in (-1, 1):                       # side screw bosses, out to the head
        ped = ped.union(cq.Workplane("XZ").circle(PEDAL_SCREW_BOSS_D/2.0)
                        .extrude(s*PEDAL_SCREW_SPAN/2.0)
                        .translate((SKIRT_BOSS_CH_X, 0, BOSS_Z)))
    for hx, hy in pedal_base_holes():       # the holes the pins go into, bored to
        ped = ped.cut(cq.Workplane("XY")    # the ASSUMED depth, not to the pin
                      .circle(PEDAL_BASE_HOLE_D/2.0)
                      .extrude(PEDAL_PAD_T + HOLE_DEPTH_MIN)
                      .translate((hx, hy, 0)))
    return ped


def _assembly_gate(jig):
    """The one question this print exists to answer, asked in CAD first: with the
    pedal sitting on the plate face, does ANY of the jig occupy space the pedal
    already owns? Pins live in bored holes, bosses in their channels, the case
    between the column inner faces -- so the honest answer is zero."""
    clash = jig.val().intersect(_pedal_stand_in().translate((0, 0, PLATE_T)).val())
    vol = sum(s.Volume() for s in clash.Solids())
    assert vol < 1.0, (
        f"SEAT: jig and seated pedal overlap by {vol:.1f} mm3 -- the pedal cannot "
        "drop on, so the print would fail for a reason that is not the measurement")


def build():
    _check()
    # --- plate ---------------------------------------------------------------
    jig = (cq.Workplane("XY").box(2*PLATE_HD, 2*PLATE_HW, PLATE_T,
                                  centered=(True, True, False))
           .edges("|Z").fillet(CORNER_R)
           .faces("<Z").chamfer(BOT_CHAM))

    # --- case footprint scribe + toe arrow -----------------------------------
    # A TRAPEZOID, not a rectangle. The scribe exists to be eyeballed against a
    # seated pedal, so drawing the case 3.27 mm wider at the toe than it really
    # is would make a correctly-placed pedal look inset down there -- the one
    # misreading this line is supposed to prevent.
    def _case_outline(inset):
        xb, xt = PEDAL_D/2.0 - inset, -(PEDAL_D/2.0 - inset)
        yb, yt = pedal_half_width(xb) - inset, pedal_half_width(xt) - inset
        return [(xb, yb), (xb, -yb), (xt, -yt), (xt, yt)]

    ring = (cq.Workplane("XY")
            .polyline(_case_outline(0.0)).close()
            .polyline(_case_outline(SCRIBE_W)).close()
            .extrude(SCRIBE_D).translate((0, 0, PLATE_T - SCRIBE_D)))
    arrow = (cq.Workplane("XY")
             .polyline([(-52.0, 0.0), (-46.0, 5.0), (-46.0, -5.0)]).close()
             .extrude(SCRIBE_D).translate((0, 0, PLATE_T - SCRIBE_D)))
    jig = jig.cut(ring).cut(arrow)

    # --- locating pins -------------------------------------------------------
    for hx, hy in pedal_base_holes():
        pin = (cq.Workplane("XY").circle(PIN_D/2.0).extrude(PIN_H)
               .faces(">Z").chamfer(PIN_LEAD)
               .translate((hx, hy, PLATE_T)))
        jig = jig.union(pin)

    # --- boss columns --------------------------------------------------------
    col_x0 = SKIRT_BOSS_CH_X - COL_X_LEN/2.0
    for s in (-1, 1):
        y0 = min(s*COL_Y_IN, s*COL_Y_OUT)
        col = (cq.Workplane("XY")
               .box(COL_X_LEN, COL_Y_OUT - COL_Y_IN, COL_H, centered=False)
               .translate((col_x0, y0, PLATE_T)))
        # drop-in channel: through the inner face, out past the boss tip
        ch_y0 = min(s*(COL_Y_IN - 1.0), s*SKIRT_BOSS_CH_HALF)
        col = col.cut(cq.Workplane("XY").box(
            SKIRT_BOSS_CH_W, SKIRT_BOSS_CH_HALF - (COL_Y_IN - 1.0), COL_H,
            centered=False).translate(
                (SKIRT_BOSS_CH_X - SKIRT_BOSS_CH_W/2.0, ch_y0, PLATE_T + COL_CH_Z0)))
        # outer-face gusset (the inner face is pedal clearance and stays flat)
        gus = (cq.Workplane("YZ")
               .polyline([(s*COL_Y_OUT, 0.0),
                          (s*(COL_Y_OUT + COL_GUSSET), 0.0),
                          (s*COL_Y_OUT, COL_GUSSET)]).close()
               .extrude(COL_X_LEN).translate((col_x0, 0.0, PLATE_T)))
        jig = jig.union(col).union(gus)
    _assembly_gate(jig)
    return jig


def main():
    jig = build()
    os.makedirs(OUT, exist_ok=True)
    base = os.path.join(OUT, "segno_pedal_base_fit_test")
    cq.exporters.export(jig.val(), base + ".step")
    cq.exporters.export(jig, base + ".stl", tolerance=0.05)

    print("Pedal BASE fit-test jig (issue #716)")
    print(f"  plate            {2*PLATE_HD:.2f} x {2*PLATE_HW:.2f} x {PLATE_T:.1f} mm")
    print(f"  pins             4x Ø{PIN_D:.1f} x {PIN_H:.1f} tall "
          f"(holes Ø{PEDAL_BASE_HOLE_D:.1f}, pad {PEDAL_PAD_T:.1f} eaten)")
    print("  hole pattern, from the case BACK edge / across the centre-line:")
    for (hx, hy), row in zip(pedal_base_holes(),
                             ("rear", "rear", "front", "front")):
        print(f"    {row:<5}  back {PEDAL_D/2.0 - hx:7.2f}   y {hy:+7.3f}")
    print(f"  spans            rear {PEDAL_BASE_SPAN_REAR:.2f}, "
          f"front {PEDAL_BASE_SPAN_FRONT:.2f}")
    print(f"  columns          x {SKIRT_BOSS_CH_X:+.3f} +/- {COL_X_LEN/2.0:.1f}, "
          f"y {COL_Y_IN:.3f}..{COL_Y_OUT:.3f}, {COL_H:.1f} tall")
    print(f"  boss centre      {BOSS_Z:.2f} above the plate face "
          f"(channel floor {COL_CH_Z0:.1f}, Ø{PEDAL_SCREW_BOSS_D:.1f} boss)")
    print(f"  case taper       {PEDAL_W:.2f} at the back edge -> {PEDAL_TOE_W:.2f} at the toe; "
          f"half-width {pedal_half_width(SKIRT_BOSS_CH_X):.3f} at the column")
    print(f"                   -> column clearance {COL_Y_IN - pedal_half_width(SKIRT_BOSS_CH_X):.2f}/side "
          f"(it would read {COL_Y_IN - PEDAL_W/2.0:.2f} against the back-edge width)")
    print(f"\n  out/{os.path.basename(base)}.step (+ .stl)")


if __name__ == "__main__":
    main()
