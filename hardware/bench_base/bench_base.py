#!/usr/bin/env python3
"""
Bench base for the Segno console v3 electronics (#1358). A bench part, not an
enclosure part: it lifts the boards off the table so nothing under them shorts
or snags, and keeps the leads between them short.

Three tiles that join with dovetails, each well inside an Ender 3 V3 bed
(220 x 220):

  console  the console board v3 (Pico 2) on four M3 standoffs
  pi       the Raspberry Pi 5 on its N07 NVMe board, and the screen power board
  power    the SparkFun STUSB4500 PD trigger on four M3 standoffs and the two
           20 V -> 5 V bucks in corrals

    y (back)
    ^  +-----------+
    |  |  pi    PI |------+    The free edges are where the plugs go: the Pi's
    |  |  screen   |      |    HDMI and USB-C to the back, its USB and Ethernet
    |  |  power    |power |    to the left, the Pico's USB to the left, the PD
    |  +-----------+      |    board's USB-C to the right.
    |  | console   |      |
    |  +-----------+------+
    +-------------------------> x

WHERE THE NUMBERS COME FROM
    The console board's and the screen power board's outlines, mounting holes
    and pads are read from board_geometry.json, which extract_boards.py writes
    from their KiCad layouts. What hangs under them is measured off kicad-cli
    STEP exports of the same layouts (see HEIGHTS below). The Pi 5 is the
    official mechanical drawing (the same 58 x 49 hole rectangle as
    segno_enclosure.PI_HOLES); the NVMe board is the GeeekPi N07 the enclosure
    uses (PI_N07_H there). The PD board is SparkFun's own Eagle file; the bucks
    are the enclosure model's BUCK_BODY.

Outputs (./out): one STEP + STL per tile (print pose: floor on the bed), an
assembly STEP with the boards as reference slabs, and an SVG top view.
Run:  ../enclosure/.venv/bin/python bench_base.py
"""
from __future__ import annotations

import json
import math
import os

import cadquery as cq

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
GEOM = json.load(open(os.path.join(HERE, "board_geometry.json")))
CONSOLE, SCREEN = GEOM["console"], GEOM["screen_power"]

# ----------------------------------------------------------------------------
# PRINTER AND HARDWARE
# ----------------------------------------------------------------------------
BED = (220.0, 220.0)          # Ender 3 V3
BED_MARGIN = 8.0              # left free on every side for the skirt and the clips
FLOOR_T = 4.0                 # floor thickness; the dovetails are this tall too
TILE_R = 4.0                  # radius on the tile corners that are not on a seam

# M3 heat-set inserts, the repo's one size (MANUFACTURING.md: "M3 5x5 throughout,
# pilots 4.5"). The screw goes in from above through the board.
INSERT_PILOT_D = 4.5
INSERT_PILOT_DEPTH = 6.0      # insert length + 1 for the melt
BOSS_D = 9.0                  # 2.25 mm of wall around the pilot
BOSS_PAD_CLR = 0.2            # boss top to the nearest pad other than its own hole's

# Dovetails between tiles. They slide together vertically, so the tiles drop in.
DT_NECK, DT_HEAD, DT_DEPTH = 8.0, 12.0, 7.0
DT_CLR = 0.15                 # per side, on the socket
SEAM_GAP = 0.1                # each tile stops this far short of a seam

# ----------------------------------------------------------------------------
# HEIGHTS UNDER THE BOARDS (mm below the PCB's back face)
# ----------------------------------------------------------------------------
# From kicad-cli STEP exports of the layouts board_geometry.json was read from
# (its "revision"), 2026-10-18. Neither board has a part on its back; what hangs
# under them is leads.
#
# Console board: the deepest is the JST-VH power headers at 2.11, and an
# untrimmed VH pin stands up to about 4 proud.
CONSOLE_BACK_DEPTH = 4.0
CONSOLE_STANDOFF_H = 10.0     # floor top to the board's back face
# Screen power board: Q5's TO-220 leads are modelled untrimmed at 8.14; the next
# deepest is F1's fuse holder at 2.38.
SCREEN_BACK_DEPTH = 8.2
SCREEN_STANDOFF_H = 12.0
SCREEN_BOSS_D = 8.0           # its holes have a 4.25 copper keepout (screen_power/README)

# ----------------------------------------------------------------------------
# THE RASPBERRY PI 5 AND ITS NVMe BOARD
# ----------------------------------------------------------------------------
# Raspberry Pi 5, official mechanical drawing: 85 x 56, M2.5 holes 3.5 in from
# the edge without the USB and Ethernet jacks, 58 x 49 apart. Frame: origin at
# the corner by the PCIe connector, x along the 85 edge toward the USB and
# Ethernet jacks, y up from the edge with USB-C and both micro-HDMI ports.
PI_W, PI_H = 85.0, 56.0
PI_HOLES = [(3.5, 3.5), (61.5, 3.5), (3.5, 52.5), (61.5, 52.5)]
# The GeeekPi N07 (B0CWD266XR, 52Pi EP-0211) the appliance boots from: a
# bottom board on the same four holes, HAT-sized (65 x 56.5). The enclosure
# stacks it riser -> N07 -> 6 mm M2.5 male/female extender -> Pi (PI_N07_H in
# segno_enclosure.py), the extender's male end threading down through the N07
# into the riser. Here the bosses are those risers: each carries an M2.5
# heat-set insert, with the pilot running on below it so a male end longer than
# the insert (the N07 kit's 12+4 pillars, or a 6+6 extender) still goes home.
N07_W, N07_H = 65.0, 56.5
N07_TO_PI = 6.0               # the enclosure's 6 mm male/female extender
PI_BOSS_D, PI_BOSS_H = 7.0, 10.0  # air under the N07, as under the console board
PI_INSERT_D = 3.2             # pilot for an M2.5 x 4 heat-set insert (3.5 OD)
PI_PILOT_DEPTH = 8.0          # insert 4 + room for up to 6 mm of male thread past the N07
PI_EDGE_GAP = 3.0             # Pi's port edges in from the tile's free edges

# ----------------------------------------------------------------------------
# THE POWER BOARDS
# ----------------------------------------------------------------------------
# SparkFun Power Delivery Board, USB-C (STUSB4500), from SparkFun's Eagle file
# github.com/sparkfun/Power_Delivery_Board-USB-C Hardware/SparkFun_STUSB4500_USB-PD.brd:
# 35.56 x 33.02 overall, four STAND-OFF holes (3.302 drill, #4 screw, takes M3)
# at 3.175 in from each corner. USB-C (J1) on the x = 0 edge, screw terminal
# (J5, VOUT) on the opposite edge. Its back carries only header and terminal leads.
PD_W, PD_H = 35.56, 33.02
PD_HOLES = [(3.175, 3.175), (32.385, 3.175), (3.175, 29.845), (32.385, 29.845)]
PD_STANDOFF_H = 8.0
PD_BOSS_D = 8.5

# The bucks: eleUniverse 8-36 V -> 5 V 10 A potted brick (Amazon B0GGHN97TK),
# BUCK_BODY in ../enclosure/segno_enclosure.py: 63.8 x 57.7 x 22.1 including the
# ears. The ear spacing there is still provisional, so the base does not drill
# for them: each brick sits in a corral that is open in the middle of every
# side for the leads and the ears.
BUCK_BODY = (63.8, 57.7, 22.1)
BUCK_CLR = 0.6
CORRAL_T, CORRAL_H, CORRAL_GAP = 2.4, 6.0, 24.0

# ----------------------------------------------------------------------------
# LAYOUT (global frame: x right, y away from you, z up from the bed)
# ----------------------------------------------------------------------------
COL_W = 118.0                 # the left column: console and pi tiles
A_D, B_D = 118.0, 154.0       # their depths
C_W, C_D = 80.0, 192.0        # power tile

TILES = {
    "console": (0.0, 0.0, COL_W, A_D),
    "pi":      (0.0, A_D, COL_W, A_D + B_D),
    "power":   (COL_W, 0.0, COL_W + C_W, C_D),
}

# Console board: centred on its tile, KiCad's top edge (the rear-panel loom:
# POWER, MIDI, CTRL) to the back and the footswitch row to the front, so the
# Pico's USB end (left) faces the free left edge and J2 (the Pi ribbon) the Pi.
CONSOLE_X0 = (COL_W - CONSOLE["outline"]["w"]) / 2.0
CONSOLE_Y0 = (A_D - CONSOLE["outline"]["h"]) / 2.0

# Pi: in the back-left corner of its tile, turned 180 degrees, so the USB-C and
# micro-HDMI edge faces the back and the USB and Ethernet end the left.
PI_ROT = 180.0
PI_C = (PI_EDGE_GAP + PI_W / 2.0, A_D + B_D - PI_EDGE_GAP - PI_H / 2.0)

# Screen power board: in front of the Pi, KiCad's top edge to the back like the
# console board. Its cables all leave its headers upward.
SCREEN_X0 = (COL_W - SCREEN["outline"]["w"]) / 2.0
SCREEN_Y0 = A_D + 7.0

# Power tile: the two bricks long side across, then the PD board turned so its
# USB-C faces the free right edge.
BUCK_CENTRES = {"BUCK PI": (COL_W + C_W / 2.0, 38.0),
                "BUCK AUX": (COL_W + C_W / 2.0, 110.0)}
PD_ROT = 180.0
PD_C = (COL_W + C_W - 4.0 - PD_W / 2.0, 168.0)

# Dovetails: (tile carrying the tab, tile with the socket, seam, position along it)
JOINTS = [("pi", "console", ("y", A_D), 30.0),
          ("pi", "console", ("y", A_D), 88.0),
          ("power", "console", ("x", COL_W), 30.0),
          ("power", "console", ("x", COL_W), 88.0),
          ("power", "pi", ("x", COL_W), 155.0)]


# ----------------------------------------------------------------------------
# frames
# ----------------------------------------------------------------------------
def console_xy(u, v):
    """Console board KiCad (u, v), y down -> global (x, y)."""
    return CONSOLE_X0 + u, CONSOLE_Y0 + CONSOLE["outline"]["h"] - v


def screen_xy(u, v):
    """Screen power board KiCad (u, v), y down -> global (x, y)."""
    return SCREEN_X0 + u, SCREEN_Y0 + SCREEN["outline"]["h"] - v


def _turned(c, w, h, rot, px, py):
    a = math.radians(rot)
    dx, dy = px - w / 2.0, py - h / 2.0
    return (c[0] + dx * math.cos(a) - dy * math.sin(a),
            c[1] + dx * math.sin(a) + dy * math.cos(a))


def pi_xy(px, py):
    """Pi frame (see PI_W) -> global."""
    return _turned(PI_C, PI_W, PI_H, PI_ROT, px, py)


def pd_xy(px, py):
    """PD board Eagle frame (y up, origin bottom-left) -> global."""
    return _turned(PD_C, PD_W, PD_H, PD_ROT, px, py)


def _box_dist(x, y, box):
    x0, y0, x1, y1 = box
    dx = max(x0 - x, 0.0, x - x1)
    dy = max(y0 - y, 0.0, y - y1)
    return math.hypot(dx, dy)


def _bbox(points):
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def footprints():
    """Each board's outline in global (x0, y0, x1, y1); the bucks' corrals."""
    cw, ch = CONSOLE["outline"]["w"], CONSOLE["outline"]["h"]
    sw, sh = SCREEN["outline"]["w"], SCREEN["outline"]["h"]
    hw = BUCK_BODY[0] / 2 + BUCK_CLR + CORRAL_T
    hh = BUCK_BODY[1] / 2 + BUCK_CLR + CORRAL_T
    return {
        "console": (CONSOLE_X0, CONSOLE_Y0, CONSOLE_X0 + cw, CONSOLE_Y0 + ch),
        "screen power": (SCREEN_X0, SCREEN_Y0, SCREEN_X0 + sw, SCREEN_Y0 + sh),
        "pi": _bbox([pi_xy(0, 0), pi_xy(PI_W, PI_H)]),
        "pd": _bbox([pd_xy(0, 0), pd_xy(PD_W, PD_H)]),
        **{name: (cx - hw, cy - hh, cx + hw, cy + hh)
           for name, (cx, cy) in BUCK_CENTRES.items()},
    }


# ----------------------------------------------------------------------------
# tiles
# ----------------------------------------------------------------------------
EPS = 1e-6


def _touches(name, x, y):
    """True if (x, y) lies on or in a tile other than `name`."""
    return any(x0 - EPS <= x <= x1 + EPS and y0 - EPS <= y <= y1 + EPS
               for other, (x0, y0, x1, y1) in TILES.items() if other != name)


def _seams(name):
    """The edges of a tile that another tile shares, worked out from TILES."""
    x0, y0, x1, y1 = TILES[name]
    out = set()
    for other, (ox0, oy0, ox1, oy1) in TILES.items():
        if other == name:
            continue
        ys = min(y1, oy1) - max(y0, oy0) > EPS
        xs = min(x1, ox1) - max(x0, ox0) > EPS
        out |= {k for k, hit in (("x0", ys and abs(ox1 - x0) < EPS), ("x1", ys and abs(ox0 - x1) < EPS),
                                 ("y0", xs and abs(oy1 - y0) < EPS), ("y1", xs and abs(oy0 - y1) < EPS))
                if hit}
    return out


def _plate(name):
    x0, y0, x1, y1 = TILES[name]
    seams = _seams(name)
    g = {k: SEAM_GAP if k in seams else 0.0 for k in ("x0", "x1", "y0", "y1")}
    gx0, gx1, gy0, gy1 = x0 + g["x0"], x1 - g["x1"], y0 + g["y0"], y1 - g["y1"]
    p = (cq.Workplane("XY").center((gx0 + gx1) / 2.0, (gy0 + gy1) / 2.0)
         .rect(gx1 - gx0, gy1 - gy0).extrude(FLOOR_T))
    # Round the corners no other tile meets.
    for (cx, cy), (rx, ry) in (((gx0, gy0), (x0, y0)), ((gx1, gy0), (x1, y0)),
                               ((gx1, gy1), (x1, y1)), ((gx0, gy1), (x0, y1))):
        if not _touches(name, rx, ry):
            p = p.edges(cq.selectors.NearestToPointSelector((cx, cy, FLOOR_T / 2.0))).fillet(TILE_R)
    return p


def _dovetail(seam, at, sign, grow=0.0):
    """Trapezoid tab across a seam. sign = +1 grows toward +axis."""
    n, hd = DT_NECK / 2.0 + grow, DT_HEAD / 2.0 + grow
    d = DT_DEPTH + grow
    axis, s = seam
    pts = [(-n, -0.5), (n, -0.5), (hd, d), (-hd, d)]
    if axis == "y":
        poly = [(at + p, s + sign * q) for p, q in pts]
    else:
        poly = [(s + sign * q, at + p) for p, q in pts]
    z0 = -0.1 if grow else 0.0
    h = FLOOR_T + (0.2 if grow else 0.0)
    return cq.Workplane("XY").workplane(offset=z0).polyline(poly).close().extrude(h)


# ----------------------------------------------------------------------------
# features
# ----------------------------------------------------------------------------
def _cyl(x, y, d, z0, h):
    return cq.Workplane("XY").workplane(offset=z0).center(x, y).circle(d / 2.0).extrude(h)


def _boss(x, y, h, d=BOSS_D):
    """A standoff with a heat-set insert pilot in its top."""
    b = _cyl(x, y, d, FLOOR_T - 0.01, h + 0.01)
    b = b.faces(">Z").edges().chamfer(0.4)
    return b.cut(_cyl(x, y, INSERT_PILOT_D, FLOOR_T + h - INSERT_PILOT_DEPTH,
                      INSERT_PILOT_DEPTH + 0.1))


def _pi_boss(x, y):
    """A riser under one of the N07's holes, with an M2.5 insert pilot."""
    b = _cyl(x, y, PI_BOSS_D, FLOOR_T - 0.01, PI_BOSS_H + 0.01)
    b = b.faces(">Z").edges().chamfer(0.4)
    return b.cut(_cyl(x, y, PI_INSERT_D, FLOOR_T + PI_BOSS_H - PI_PILOT_DEPTH,
                      PI_PILOT_DEPTH + 0.1))


def _text(solid, txt, x, y, size, angle=0.0):
    """Engrave a label 0.6 mm into the floor top."""
    t = (cq.Workplane("XY").workplane(offset=FLOOR_T - 0.6)
         .transformed(rotate=(0, 0, angle))
         .text(txt, size, 1.0, combine=False, halign="center", valign="center")
         .translate((x, y, 0)))
    return solid.cut(t)


def features():
    """{tile: [solids to add to it]}"""
    out = {name: [] for name in TILES}
    for hl in CONSOLE["holes"]:
        out["console"].append(_boss(*console_xy(hl["x"], hl["y"]), CONSOLE_STANDOFF_H))
    for hl in SCREEN["holes"]:
        out["pi"].append(_boss(*screen_xy(hl["x"], hl["y"]), SCREEN_STANDOFF_H, SCREEN_BOSS_D))
    for px, py in PI_HOLES:
        out["pi"].append(_pi_boss(*pi_xy(px, py)))
    for px, py in PD_HOLES:
        out["power"].append(_boss(*pd_xy(px, py), PD_STANDOFF_H, PD_BOSS_D))
    iw, ih = BUCK_BODY[0] + 2 * BUCK_CLR, BUCK_BODY[1] + 2 * BUCK_CLR
    for cx, cy in BUCK_CENTRES.values():
        corral = (cq.Workplane("XY").workplane(offset=FLOOR_T - 0.01).center(cx, cy)
                  .rect(iw + 2 * CORRAL_T, ih + 2 * CORRAL_T).rect(iw, ih)
                  .extrude(CORRAL_H + 0.01))
        gaps = (cq.Workplane("XY").workplane(offset=FLOOR_T).center(cx, cy)
                .rect(CORRAL_GAP, ih + 4 * CORRAL_T).extrude(CORRAL_H + 1)
                .union(cq.Workplane("XY").workplane(offset=FLOOR_T).center(cx, cy)
                       .rect(iw + 4 * CORRAL_T, CORRAL_GAP).extrude(CORRAL_H + 1)))
        out["power"].append(corral.cut(gaps))
    return out


def build():
    """The three tiles, as {name: solid}, in their assembled positions."""
    feats = features()
    tiles = {}
    for name in TILES:
        t = _plate(name)
        for f in feats[name]:
            t = t.union(f)
        tiles[name] = t
    for tab, sock, seam, at in JOINTS:
        axis, s = seam
        # the tab grows from its own tile into the socket tile
        sign = -1 if (axis == "y" and TILES[tab][1] >= s) or \
                     (axis == "x" and TILES[tab][0] >= s) else 1
        tiles[tab] = tiles[tab].union(_dovetail(seam, at, sign))
        tiles[sock] = tiles[sock].cut(_dovetail(seam, at, sign, grow=DT_CLR))
        # first-layer relief: the squashed first layers on the tab would bind
        relief = _dovetail(seam, at, sign, grow=DT_CLR + 0.3)
        relief = relief.intersect(cq.Workplane("XY").workplane(offset=-1).rect(1e3, 1e3).extrude(1.4))
        tiles[sock] = tiles[sock].cut(relief)
    # Labels, engraved 0.6 into the floor top.
    tiles["console"] = _text(tiles["console"], "SEGNO CONSOLE V3", COL_W / 2.0,
                             CONSOLE_Y0 / 2.0, 5.0)
    sx, sy = screen_xy(SCREEN["outline"]["w"] / 2.0, SCREEN["outline"]["h"] / 2.0)
    tiles["pi"] = _text(tiles["pi"], "SCREEN POWER", sx, sy, 5.0)
    px, py = pi_xy(PI_W / 2.0, PI_H / 2.0)
    tiles["pi"] = _text(tiles["pi"], "PI 5: HDMI TO THE BACK", px, py, 3.5)
    for label, (cx, cy) in BUCK_CENTRES.items():
        tiles["power"] = _text(tiles["power"], label, cx, cy, 6.0)
    px, py = pd_xy(PD_W / 2.0, PD_H / 2.0)
    tiles["power"] = _text(tiles["power"], "PD", px, py, 6.0)
    return {k: v.val() for k, v in tiles.items()}


# ----------------------------------------------------------------------------
# checks
# ----------------------------------------------------------------------------
def _check_bosses(board, boss_d, standoff_h, back_depth):
    """A board's standoffs touch no pad but their own hole's, and lift the
    board clear of its leads."""
    name = board["source"].split("/")[-1]
    assert standoff_h >= back_depth + 3.0, f"{name}: the leads reach the floor"
    for hl in board["holes"]:
        for pd in board["pth_pads"]:
            if pd["ref"] == hl["ref"]:
                continue
            d = _box_dist(hl["x"], hl["y"], pd["box"])
            assert d > boss_d / 2.0 + BOSS_PAD_CLR, (
                f"{name}: the {hl['ref']} standoff lands {d:.2f} from {pd['ref']}.{pd['pad']}")


def check(tiles):
    """Refuse to export a base that does not fit the boards or the bed."""
    msgs = []
    for name, s in tiles.items():
        assert s.isValid(), f"{name}: invalid solid"
        assert len(s.Solids()) == 1, f"{name}: {len(s.Solids())} solids, expected 1"
        bb = s.BoundingBox()
        assert max(bb.xlen, bb.ylen) <= BED[0] - 2 * BED_MARGIN, (
            f"{name}: {bb.xlen:.1f} x {bb.ylen:.1f} does not fit the bed with "
            f"{BED_MARGIN} mm of margin")
        msgs.append(f"{name:8s} {bb.xlen:6.1f} x {bb.ylen:6.1f} x {bb.zlen:5.1f}")

    _check_bosses(CONSOLE, BOSS_D, CONSOLE_STANDOFF_H, CONSOLE_BACK_DEPTH)
    _check_bosses(SCREEN, SCREEN_BOSS_D, SCREEN_STANDOFF_H, SCREEN_BACK_DEPTH)
    for px, py in PD_HOLES:
        assert 0 < px < PD_W and 0 < py < PD_H

    # Every board on the tile it is meant for, none overlapping another, with
    # room between them.
    home = {"console": "console", "screen power": "pi", "pi": "pi", "pd": "power",
            "BUCK PI": "power", "BUCK AUX": "power"}
    fps = footprints()
    for name, (x0, y0, x1, y1) in fps.items():
        tx0, ty0, tx1, ty1 = TILES[home[name]]
        assert tx0 + 1.0 <= x0 and x1 <= tx1 - 1.0 and ty0 + 1.0 <= y0 and y1 <= ty1 - 1.0, (
            f"{name} hangs off its tile")
    names = list(fps)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            ax0, ay0, ax1, ay1 = fps[a]
            bx0, by0, bx1, by1 = fps[b]
            gap = max(bx0 - ax1, ax0 - bx1, by0 - ay1, ay0 - by1)
            assert gap >= 4.0, f"{a} and {b} are {gap:.1f} apart"
    # The N07 sits under the Pi on the same holes, inside its outline, and the
    # riser keeps a wall round its insert.
    assert N07_W <= PI_W and N07_H <= PI_H + 0.5
    assert PI_BOSS_D - PI_INSERT_D >= 3.0 and PI_PILOT_DEPTH < PI_BOSS_H + FLOOR_T - 1.0

    # The Pi's ports face free edges: USB-C and HDMI (its y = 0 edge) and USB
    # and Ethernet (its x = PI_W edge) each within PI_EDGE_GAP of a tile edge no
    # other tile shares.
    tx0, ty0, tx1, ty1 = TILES["pi"]
    seams = _seams("pi")
    for nm, (ax, ay), (bx, by) in (("USB-C and HDMI", (0, 0), (PI_W, 0)),
                                   ("USB and Ethernet", (PI_W, 0), (PI_W, PI_H))):
        (gx0, gy0), (gx1, gy1) = pi_xy(ax, ay), pi_xy(bx, by)
        edges = {"x0": abs(gx0 - tx0) + abs(gx1 - tx0), "x1": abs(gx0 - tx1) + abs(gx1 - tx1),
                 "y0": abs(gy0 - ty0) + abs(gy1 - ty0), "y1": abs(gy0 - ty1) + abs(gy1 - ty1)}
        k = min(edges, key=edges.get)
        assert edges[k] <= 2 * PI_EDGE_GAP + 1e-6 and k not in seams, (
            f"PI: the {nm} edge does not face a free edge of its tile")

    (_, y1), (_, y2) = BUCK_CENTRES.values()
    assert abs(y2 - y1) >= BUCK_BODY[1] + 2 * (BUCK_CLR + CORRAL_T) + 4.0, "POWER: corrals overlap"
    return msgs


# ----------------------------------------------------------------------------
# export
# ----------------------------------------------------------------------------
def _slab(x0, y0, x1, y1, z, t=1.6):
    return (cq.Workplane("XY").workplane(offset=z).center((x0 + x1) / 2.0, (y0 + y1) / 2.0)
            .rect(x1 - x0, y1 - y0).extrude(t))


def _reference_boards():
    fps = footprints()
    pi_foot = FLOOR_T + PI_BOSS_H
    n07 = _bbox([pi_xy(0, 0), pi_xy(N07_W, N07_H)])
    bucks = [_slab(cx - BUCK_BODY[0] / 2, cy - BUCK_BODY[1] / 2, cx + BUCK_BODY[0] / 2,
                   cy + BUCK_BODY[1] / 2, FLOOR_T, BUCK_BODY[2]).val()
             for cx, cy in BUCK_CENTRES.values()]
    return {
        "console_board_v3": _slab(*fps["console"], FLOOR_T + CONSOLE_STANDOFF_H).val(),
        "screen_power": _slab(*fps["screen power"], FLOOR_T + SCREEN_STANDOFF_H).val(),
        "n07_nvme": _slab(*n07, pi_foot).val(),
        "raspberry_pi_5": _slab(*fps["pi"], pi_foot + 1.6 + N07_TO_PI).val(),
        "stusb4500_pd": _slab(*fps["pd"], FLOOR_T + PD_STANDOFF_H).val(),
        "bucks": cq.Compound.makeCompound(bucks),
    }


def _svg(shape, path, w=720, h=640):
    cq.exporters.export(shape, path, opt={"projectionDir": (0, 0, 1), "showAxes": False,
                                          "strokeWidth": 0.25, "width": w, "height": h,
                                          "showHidden": False})
    body = open(path).read()
    if "viewBox" not in body:      # cadquery writes no viewBox, so it clips when scaled
        needle = f'height="{float(h)}"'
        assert needle in body, "cadquery changed its SVG attribute formatting"
        open(path, "w").write(body.replace(needle, f'{needle}\n   viewBox="0 0 {w} {h}"', 1))


def export(tiles):
    os.makedirs(OUT, exist_ok=True)
    asm = cq.Assembly(name="segno_bench_base")
    colours = {"console": "gray30", "pi": "gray40", "power": "gray50"}
    for name, s in tiles.items():
        base = os.path.join(OUT, f"segno_bench_base_{name}")
        bb = s.BoundingBox()
        posed = s.translate((-bb.center.x, -bb.center.y, -bb.zmin))   # bed pose
        cq.exporters.export(posed, base + ".step")
        cq.exporters.export(posed, base + ".stl", tolerance=0.02, angularTolerance=0.1)
        asm.add(s, name=f"tile_{name}", color=cq.Color(colours[name]))
    for name, s in _reference_boards().items():
        asm.add(s, name=f"reference_{name}", color=cq.Color("darkgreen"))
    asm.save(os.path.join(OUT, "segno_bench_base_assembly.step"))
    _svg(cq.Compound.makeCompound(list(tiles.values())),
         os.path.join(OUT, "segno_bench_base_top.svg"))
    # cadquery's STEP writer stamps the time; strip trailing spaces like the other
    # generators so a rerun on unchanged geometry diffs only in that header line.
    for f in os.listdir(OUT):
        if f.endswith(".step"):
            p = os.path.join(OUT, f)
            txt = open(p).read().splitlines()
            open(p, "w").write("\n".join(line.rstrip() for line in txt) + "\n")
    print(f"wrote {len(tiles)} tiles (STEP + STL), the assembly and a top view in {OUT}")


def main():
    tiles = build()
    for m in check(tiles):
        print(" ", m)
    export(tiles)


if __name__ == "__main__":
    main()
