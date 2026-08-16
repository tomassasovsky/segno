#!/usr/bin/env python
"""1:1 PAPER GAUGE for the pedal's base screw holes (issue #716).

The fit-test jig is internally consistent with its own assumptions -- rows
80.000 apart, spans 54.050/53.000, rear row 4.000 off the boss axis, all
verified against the exported STEP. So when the jig still does not agree with
the pedal, no amount of CAD iteration will find it: the error is in the
SPEC -> PEDAL mapping, and closing that loop needs a measurement that does not
route through any of my assumptions.

Hence rulers, not targets. Print this at 100% (Actual Size), lay the pedal on
it BASE UP with the anti-slip pad off, and read four things off the printed
scales:

  1. does the case back edge sit on the BACK EDGE line while the two side screw
     bosses land in their drawn circles?  If not, the datum chain is wrong --
     the case depth (109.87) or the screw-axis inset (23.24) this repo carries
     does not describe your pedal, and every "from the back edge" number I have
     quoted is built on sand.
  2. LONGITUDINAL ruler, zeroed on the BACK EDGE: where does each hole row fall?
  3. TRANSVERSE ruler at each row, zeroed on the CENTRE-LINE: where does each
     hole fall?  Reading both sides separately also settles whether the pattern
     is symmetric, which I assumed and never checked.
  4. the SCALE CHECK bar must measure exactly 100.00 mm. If it does not, the
     print scaled and every other reading is worthless.

Report those numbers as they read and the constants follow directly -- no
convention to guess at (centre-to-centre vs edge-to-edge), no direction to
infer, no datum to trust on faith.

    python _pedal_base_gauge.py        # -> out/segno_pedal_base_gauge.pdf (+ .dxf)
"""

from __future__ import annotations

import os

from segno_enclosure import (
    OUT,
    PEDAL_BASE_HOLE_D,
    PEDAL_D,
    PEDAL_SCREW_BACK,
    PEDAL_SCREW_BOSS_D,
    PEDAL_SCREW_SPAN,
    PEDAL_TOE_W,
    PEDAL_W,
    pedal_base_holes,
    pedal_half_width,
)

# --- sheet --------------------------------------------------------------------
SHEET_W, SHEET_H = 210.0, 297.0        # A4 portrait, mm
# pedal frame -> sheet: +X (toward the case BACK) maps to sheet +Y, so the pedal
# lies along the sheet's long axis with its back edge toward the top.
ORG_X, ORG_Y = 105.0, 195.06           # puts the back edge at sheet y=250

HAIR, THIN, BOLD = 0.25, 0.5, 1.1      # line weights, mm
TICK_MINOR, TICK_MAJOR = 1.6, 3.2      # ruler tick lengths, mm
RULER_REACH = 35.0                     # transverse half-length: stops short of the
                                       # Ø10 boss circles at 41.6, which the old 42
                                       # ran straight through
LONG_RAIL = 52.0                       # longitudinal ruler, left of the centre-line
TEXT_RIGHT = 158.0                     # right-hand label column: clear of the Ø10
                                       # boss circles, which reach 151.6. Sheet ends
                                       # at 210, so ~30 monospace chars at 2.8 mm


def _sheet(px, py):
    """pedal frame -> sheet frame."""
    return ORG_X + py, ORG_Y + px


def ops():
    """Every mark on the gauge, as backend-neutral primitives."""
    o = []
    L = lambda p0, p1, w=THIN, ls="-": o.append(
        {"k": "line", "p0": p0, "p1": p1, "w": w, "ls": ls})
    C = lambda p, r, w=THIN, ls="-": o.append(
        {"k": "circle", "p": p, "r": r, "w": w, "ls": ls})
    T = lambda p, s, h=3.0, ha="left", va="bottom", rot=0: o.append(
        {"k": "text", "p": p, "s": s, "h": h, "ha": ha, "va": va, "rot": rot})

    back, toe = PEDAL_D/2.0, -PEDAL_D/2.0

    # --- title + scale check -------------------------------------------------
    T((105.0, SHEET_H - 11.0), "SEGNO -- pedal BASE screw-hole gauge (issue #716)",
      4.0, "center")
    y = SHEET_H - 26.0
    L((55.0, y), (155.0, y), BOLD)
    for x in (55.0, 155.0):
        L((x, y - 3.0), (x, y + 3.0), BOLD)
    T((105.0, y + 4.5), "SCALE CHECK -- this bar must measure exactly 100.00 mm",
      3.0, "center")
    T((105.0, y - 5.5), "if not, reprint at 100% / Actual Size -- no 'fit to page'",
      2.6, "center", "top")

    # --- case outline, back edge, centre-line --------------------------------
    yb, yt = pedal_half_width(back), pedal_half_width(toe)
    for a, b in (((back, yb), (back, -yb)), ((back, -yb), (toe, -yt)),
                 ((toe, -yt), (toe, yt)), ((toe, yt), (back, yb))):
        L(_sheet(*a), _sheet(*b), THIN)
    # right-hand labels: the rear row and the screw axis are only 4 mm apart, so
    # each tag gets a vertical slot and a leader back to its own feature
    def TAG(feature_px, s, off):
        fy = _sheet(feature_px, 0)[1]
        T((TEXT_RIGHT, fy + off), s, 2.8, "left", "center")
        L((TEXT_RIGHT - 1.0, fy + off), (TEXT_RIGHT - 6.0, fy), HAIR)

    L(_sheet(back, -LONG_RAIL - 4.0), _sheet(back, yb + 8.0), BOLD)
    TAG(back, "BACK EDGE = 0", 0.0)
    L(_sheet(back + 6.0, 0.0), _sheet(toe - 6.0, 0.0), THIN, "-.")
    T(_sheet(toe - 3.0, 0.0), "CENTRE-LINE = 0 on the cross rulers",
      2.8, "center", "top")
    T(_sheet(toe - 11.0, 0.0), "TOE", 4.0, "center", "top")

    # --- screw axis + boss circles: the datum cross-check ---------------------
    sx = back - PEDAL_SCREW_BACK
    L(_sheet(sx, -PEDAL_SCREW_SPAN/2.0 - 8.0),
      _sheet(sx, PEDAL_SCREW_SPAN/2.0 + 8.0), BOLD, "--")
    for s in (-1, 1):
        C(_sheet(sx, s*PEDAL_SCREW_SPAN/2.0), PEDAL_SCREW_BOSS_D/2.0, THIN)
    TAG(sx, "SCREW AXIS -- step 2", -6.0)

    # --- longitudinal ruler, zeroed on the BACK EDGE -------------------------
    L(_sheet(back, -LONG_RAIL), _sheet(toe, -LONG_RAIL), THIN)
    for i in range(0, int(PEDAL_D) + 1):
        px = back - i
        if px < toe:
            break
        major = i % 5 == 0
        t = TICK_MAJOR if major else TICK_MINOR
        L(_sheet(px, -LONG_RAIL), _sheet(px, -LONG_RAIL - t), THIN if major else HAIR)
        if i % 10 == 0:
            T(_sheet(px, -LONG_RAIL - t - 1.0), str(i), 2.6, "right", "center")
    T(_sheet((back + toe)/2.0, -LONG_RAIL - 13.0),
      "mm from the BACK EDGE", 3.0, "center", "bottom", 90)

    # --- the current hypothesis, and a cross ruler at each row ---------------
    rows = {}
    for (hx, hy), tag in zip(pedal_base_holes(), ("rear", "rear", "front", "front")):
        rows.setdefault(tag, (hx, []))[1].append(hy)
    for tag, (hx, hys) in rows.items():
        # rear row ticks point toe-ward, front row ticks point back-ward: both
        # then run into open case, never into the screw axis or the toe label
        d = -1.0 if tag == "rear" else 1.0
        L(_sheet(hx, -RULER_REACH), _sheet(hx, RULER_REACH), THIN)
        for i in range(-int(RULER_REACH), int(RULER_REACH) + 1):
            major = i % 5 == 0
            t = TICK_MAJOR if major else TICK_MINOR
            L(_sheet(hx, i), _sheet(hx + d*t, i), THIN if major else HAIR)
            if i % 10 == 0 and i != 0:
                T(_sheet(hx + d*(t + 1.0), i), str(abs(i)), 2.6, "center",
                  "top" if d < 0 else "bottom")
        TAG(hx, f"{tag.upper()} ROW {back - hx:.2f}?", 6.0 if tag == "rear" else 0.0)
        for hy in hys:                       # where I think the hole is
            C(_sheet(hx, hy), PEDAL_BASE_HOLE_D/2.0, BOLD)
            for r in (2.0, 4.0):
                C(_sheet(hx, hy), r, HAIR, ":")
        # clear of the ruler ticks (3.2) and of the +/-10 tick numbers
        T(_sheet(hx + d*13.0, 0.0), f"span {2*max(hys):.2f} c/c?", 2.6, "center")

    # --- instructions --------------------------------------------------------
    lines = [
        "PEDAL BASE UP, PAD OFF. Case back edge on the BACK EDGE line, centred.",
        "",
        "1  SCALE CHECK bar reads exactly 100.00 mm?  If not, reprint at 100%.",
        "2  With the back edge on its line, do BOTH screw bosses sit inside the",
        "   drawn circles?  If NOT, say so and by how much: the case depth and",
        "   screw inset this repo carries do not describe your pedal, and every",
        "   'from the back edge' figure I have quoted is on the wrong datum.",
        "3  LONG ruler: each hole row reads ____ mm from the back edge.",
        "   (I believe 19.24 and 99.24.)",
        "4  CROSS ruler: read EACH hole separately, LEFT and RIGHT, from the",
        "   centre-line.  Reading both sides settles whether the pattern is",
        "   symmetric -- I assumed it is and never checked.",
        "   (I believe 27.025 each side rear, 26.50 each side front.)",
        "5  When you said '4 mm back from the screw line', was that line the screw",
        "   AXIS / centre, or an EDGE of the Ø10 boss?  An edge is 5 mm off axis,",
        "   which would move the whole pattern by 5 mm and look exactly like this.",
        "",
        "Report the readings as they read.  Centre-to-centre vs edge-to-edge does",
        "not matter as long as you say which -- the rulers make it explicit.",
    ]
    for i, s in enumerate(lines):
        T((12.0, 104.0 - i*5.0), s, 2.9 if i else 3.1)

    for op in o:                             # nothing may fall off the sheet
        pts = [op["p"]] if op["k"] != "line" else [op["p0"], op["p1"]]
        for px, py in pts:
            assert 0.0 <= px <= SHEET_W and 0.0 <= py <= SHEET_H, \
                f"GAUGE: {op['k']} at ({px:.1f}, {py:.1f}) falls off the sheet"
    return o


def _selfcheck():
    """A gauge that is itself mis-drawn is worse than no gauge: it would produce
    confident readings that are wrong. So verify the marks against the same
    source the jig uses, in sheet millimetres."""
    o = ops()
    lines = [x for x in o if x["k"] == "line"]
    circles = [x for x in o if x["k"] == "circle"]
    back_y = _sheet(PEDAL_D/2.0, 0)[1]

    bar = [l for l in lines if abs(l["p0"][1] - l["p1"][1]) < 1e-9
           and abs(abs(l["p1"][0] - l["p0"][0]) - 100.0) < 1e-9
           and l["p0"][1] > SHEET_H - 40.0]
    assert bar, "GAUGE: no 100.00 mm scale-check bar on the sheet"

    # every longitudinal tick must stand exactly its own label distance off the
    # back edge -- the whole point of the ruler
    for i in (0, 10, 50, 100):
        want = back_y - i
        assert any(abs(l["p0"][1] - want) < 1e-9 and
                   abs(l["p0"][0] - (ORG_X - LONG_RAIL)) < 1e-9 for l in lines), \
            f"GAUGE: no longitudinal tick at {i} mm from the back edge"

    # drawn hole circles must be exactly where the jig puts its pins
    want = {(round(_sheet(hx, hy)[0], 6), round(_sheet(hx, hy)[1], 6))
            for hx, hy in pedal_base_holes()}
    got = {(round(c["p"][0], 6), round(c["p"][1], 6)) for c in circles
           if abs(c["r"] - PEDAL_BASE_HOLE_D/2.0) < 1e-9}
    assert want == got, f"GAUGE: drawn holes {got} != jig pattern {want}"
    return len(o)


def write_pdf(path):
    """Exact 1:1. figsize is the true sheet size and the axes span the sheet in
    mm, so one data unit prints as one millimetre -- no bbox_inches, which would
    crop and therefore rescale."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig = plt.figure(figsize=(SHEET_W/25.4, SHEET_H/25.4))
    ax = fig.add_axes([0, 0, 1, 1]); ax.set_axis_off()
    ax.set_xlim(0, SHEET_W); ax.set_ylim(0, SHEET_H); ax.set_aspect("equal")
    for op in ops():
        if op["k"] == "line":
            (x0, y0), (x1, y1) = op["p0"], op["p1"]
            ax.plot([x0, x1], [y0, y1], color="black",
                    linewidth=op["w"]*72/25.4, linestyle=op["ls"], solid_capstyle="butt")
        elif op["k"] == "circle":
            ax.add_patch(plt.Circle(op["p"], op["r"], fill=False, color="black",
                                    linewidth=op["w"]*72/25.4, linestyle=op["ls"]))
        else:
            ax.text(op["p"][0], op["p"][1], op["s"], fontsize=op["h"]*72/25.4,
                    ha=op["ha"], va=op["va"], rotation=op["rot"], color="black",
                    family="monospace")
    fig.savefig(path)
    plt.close(fig)
    return path


def write_dxf(path):
    """Same marks as CAD, so the gauge can also be measured on screen."""
    import ezdxf
    doc = ezdxf.new("R2018", setup=True); doc.units = 4
    doc.layers.add("GAUGE", color=7)
    msp = doc.modelspace()
    for op in ops():
        if op["k"] == "line":
            msp.add_line(op["p0"], op["p1"], dxfattribs={"layer": "GAUGE"})
        elif op["k"] == "circle":
            msp.add_circle(op["p"], op["r"], dxfattribs={"layer": "GAUGE"})
        else:
            msp.add_text(op["s"], height=op["h"],
                         dxfattribs={"layer": "GAUGE", "rotation": op["rot"]}
                         ).set_placement(op["p"])
    doc.saveas(path)
    return path


def main():
    n = _selfcheck()
    os.makedirs(OUT, exist_ok=True)
    base = os.path.join(OUT, "segno_pedal_base_gauge")
    write_pdf(base + ".pdf"); write_dxf(base + ".dxf")
    print(f"  self-check       {n} marks, rulers and holes agree with the jig")

    print("Pedal BASE screw-hole gauge (issue #716) -- 1:1, A4 portrait")
    print(f"  sheet            {SHEET_W:.0f} x {SHEET_H:.0f} mm, scale-check bar 100.00 mm")
    print(f"  datum drawn      back edge, centre-line, screw axis at "
          f"{PEDAL_SCREW_BACK:.2f} with Ø{PEDAL_SCREW_BOSS_D:.1f} bosses "
          f"{PEDAL_SCREW_SPAN:.2f} apart")
    print(f"  case outline     {PEDAL_W:.2f} back -> {PEDAL_TOE_W:.2f} toe "
          f"over {PEDAL_D:.2f}")
    print("  rulers           longitudinal 0..110 from the back edge;")
    print(f"                   transverse +/-{RULER_REACH:.0f} from the centre-line at each row")
    print("  hypothesis shown rows at 19.24 / 99.24, spans 54.05 / 53.00 c/c")
    print(f"\n  out/{os.path.basename(base)}.pdf (+ .dxf)")


if __name__ == "__main__":
    main()
