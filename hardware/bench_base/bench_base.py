#!/usr/bin/env python3
"""
Bench base for the Segno console v3 electronics (#1358). A bench part, not an
enclosure part: it lifts the boards off the table so nothing under them shorts
or snags, and keeps the leads between them short and tidy.

Three tiles that join with dovetails, each well inside an Ender 3 V3 bed
(220 x 220):

  A  console   the console board v3 (Pico 2) on four M3 standoffs
  B  ring      the ring carrier (XIAO RP2350), on a tube and a crown of teeth
  C  power     the SparkFun STUSB4500 PD trigger on four M3 standoffs and the
               two 20 V -> 5 V bucks in corrals

    y (back)
    ^  +-----------+------+
    |  |  B ring   |  C   |    A and B are the boards column; C runs along
    |  +-----------+ power|    their right edge. The free edges are where the
    |  | A console |      |    USB plugs go: the Pico's on A's left, the XIAO's
    |  |           |      |    on B's left, the PD board's USB-C on C's right.
    |  +-----------+------+
    +-------------------------> x

WHERE THE NUMBERS COME FROM
    Board outlines, mounting holes, back-side courtyards and every through-hole
    pad are read from board_geometry.json, which extract_boards.py writes from
    the two KiCad layouts. Part heights under the boards are measured off a
    kicad-cli STEP export of the same layouts (see HEIGHTS below) and the owner's
    calipers. The PD board is SparkFun's own Eagle file; the bucks are the
    enclosure model's BUCK_BODY.

THE RING CARRIER HAS NO MOUNTING HOLES
    It snap-mounts (ring_board.py). On the bench it wears the 34-LED cup, whose
    three snap arms wrap its edge 120 degrees apart, at whatever angle the cup
    was turned to. So the cradle cannot depend on the board's angle. It holds the
    board in two places that are clear at EVERY angle:

      a tube under the encoder, in the ring of free board between the encoder's
          pads and the nearest other part (sized from the layout);
      a crown of 18 teeth round the rim, each a ledge under the board's edge and
          a post beside it. The cup's arms drop into the gaps between the teeth,
          which stops the board turning when the knob is twisted; 18 teeth puts a
          gap every 20 degrees, and 120 is a multiple of 20, so when one arm finds
          a gap all three do.

    Two teeth are left out on the free left edge for the XIAO's USB-C plug.
    J1's lead leaves through any gap.

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
CONSOLE, RING = GEOM["console"], GEOM["ring"]

# ----------------------------------------------------------------------------
# PRINTER AND HARDWARE
# ----------------------------------------------------------------------------
BED = (220.0, 220.0)          # Ender 3 V3
BED_MARGIN = 8.0              # left free on every side for the skirt and the clips
FLOOR_T = 4.0                 # floor thickness; the dovetails are this tall too
TILE_R = 4.0                  # tile corner radius on the free (non-seam) corners

# M3 heat-set inserts, the repo's one size (MANUFACTURING.md: "M3 5x5 throughout,
# pilots 4.5"). The screw goes in from above through the board.
INSERT_PILOT_D = 4.5
INSERT_PILOT_DEPTH = 6.0      # insert length + 1 for the melt
BOSS_D = 9.0                  # 2.25 mm of wall around the pilot

# Dovetails between tiles. They slide together vertically, so the tiles drop in.
DT_NECK, DT_HEAD, DT_DEPTH = 8.0, 12.0, 7.0
DT_CLR = 0.15                 # per side, on the socket
SEAM_GAP = 0.1                # each tile stops this far short of a seam

# ----------------------------------------------------------------------------
# HEIGHTS UNDER THE BOARDS (mm below the PCB's back face)
# ----------------------------------------------------------------------------
# Heights come from kicad-cli STEP exports of the layouts board_geometry.json was
# read from (its "revision"), 2026-10-17.
#
# Console board: every part is on the front. Its back carries only through-hole
# leads; the deepest in the STEP export is the JST-VH power headers at 2.11, and
# an untrimmed VH pin stands up to about 4 proud. 10 mm of air leaves room for a
# probe tip.
CONSOLE_BACK_DEPTH = 4.0
CONSOLE_STANDOFF_H = 10.0     # floor top to the board's back face

# Ring carrier: C1 8.09, J1 7.09 unplugged, C2-C5 5.19, U1 (XIAO) 4.36, U2 3.77,
# D1 3.29, R1-R5 2.59, the encoder's pins 2.41.
# The owner's calipers: 8.5 with C1 bent over and lying on the board, a little
# more at J1 with its lead plugged in. J1 is vertical on the back, so the lead
# leaves it pointing at the floor and has to bend before it can run sideways.
RING_BACK_DEPTH = 8.5         # measured, C1 lying down
RING_J1_PLUGGED = 11.0        # J1 with the XHP housing in it (model 7.09 + the plug)
RING_LEAD_BEND = 8.0          # room for 26 AWG crimped leads to turn horizontal
RING_LIFT = 22.0              # floor top to the ring board's back face

# C1 is bent over and lying on the board. Which way depends on who soldered it,
# so it is checked as an annulus: its pads sit at r 25.2..27.1 and a 8 x 11.5
# can laid straight outward with its lead bend ends at about r 39.
RING_C1_REACH_R = 39.0

# Per-part depth under the ring board, from the same STEP export, for the
# interference check in check().
RING_PART_DEPTH = {"C1": RING_BACK_DEPTH, "J1": RING_J1_PLUGGED, "C2": 5.19, "C3": 5.19,
                   "C4": 5.19, "C5": 5.19, "U1": 4.36, "U2": 3.77, "D1": 3.29,
                   "R1": 2.59, "R2": 2.59, "R3": 2.59, "R4": 2.59, "R5": 2.59}
SOLDER_JOINT = 1.5            # a through-hole joint, under any pad

# The cup's snap arms (strip_ring/console_ring.py on the enclosure line, #1090):
# three at 120 degrees, from r 40.4 outward, hanging 1.5 under the board. Two
# versions exist and either may be on the bench: 6.0 wide with the catch in to
# r 39.0 (64d152b9e), and 8.0 wide with the catch in to r 39.4 (the snap-relief
# rework, claude/console-ring-snap-reliefs-1075). The crown is sized for the
# wider one; the catch radius does not matter, as the arms sit in the gaps.
CUP_ARM_W = 8.0
CUP_ARM_PITCH = 120.0
CUP_ARM_OUT_R = 41.4          # arm's outer face at board level, both versions
CUP_WALL_R = 40.28            # the cup wall's outer face; it stops 0.085 over the board

# The tube under the encoder. Its walls sit in the free ring between the encoder's
# pads (inside) and the nearest other pad or courtyard (outside), each kept
# clear of them; the radii are worked out from the layout in ring_tube().
TUBE_CLR = 0.4
TUBE_MIN_WALL = 1.2           # three perimeters of a 0.4 nozzle

# The crown. TEETH at a 20 degree pitch; each tooth TOOTH_W wide (tangential)
# and, in section, a post from the floor to LIP_ABOVE over the board's front
# face, with a ledge reaching in under the board's edge to LEDGE_R.
TEETH = 18
TOOTH_W = 3.0
LEDGE_R = 39.4                # board support from here out to the edge (r 40)
POST_R = 40.3                 # inner face of the posts: 0.3 of play round the board,
                              # so the arms (from r 40.4) sit wholly inside the posts' reach
CROWN_OUT_R = 44.5
LIP_ABOVE = 0.0               # post top flush with the board's front face: the cup's
                              # wall (r 40.28) comes down to 0.085 over it
CROWN_BASE_H = 2.0            # ring tying the teeth together at the floor

# The XIAO's USB-C, from ring_board.py: Seeed's footprint puts the shell 12.59
# past the module centre, and the module sits on a radius with that end at the
# rim. The plug comes in radially from there, under the board, so the crown
# leaves out the teeth within USB_OPEN/2 of the free edge.
XIAO_USB_REACH = 12.59
USB_PLUG_HALF_W = 7.0         # half the plug overmold's width, plus slack
USB_PLUG_DEPTH = 8.0          # overmold, below the board's back face
USB_OPEN = 30.0
USB_ANGLE = 180.0             # global: the free left edge of tile B

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
COL_W = 118.0                 # the boards column, tiles A and B
A_D, B_D = 118.0, 100.0       # tile depths
C_W, C_D = 80.0, 192.0        # power tile

TILES = {
    "console": (0.0, 0.0, COL_W, A_D),
    "ring":    (0.0, A_D, COL_W, A_D + B_D),
    "power":   (COL_W, 0.0, COL_W + C_W, C_D),
}

# Console board: centred on tile A, KiCad's top edge (the rear-panel loom: POWER,
# MIDI, CTRL) to the back and the footswitch row to the front, so the Pico's
# USB end (left) faces the free left edge.
CONSOLE_X0 = (COL_W - CONSOLE["outline"]["w"]) / 2.0
CONSOLE_Y0 = (A_D - CONSOLE["outline"]["h"]) / 2.0

# Ring carrier: centred on tile B. Its angle is set when it is put down, with
# the XIAO's USB-C pointing at the gap in the crown on the free left edge.
RING_C = (COL_W / 2.0, A_D + B_D / 2.0)

# Power tile: the two bricks long-side across, then the PD board turned so its
# USB-C faces the free right edge.
BUCK_CENTRES = {"BUCK PI": (COL_W + C_W / 2.0, 38.0),
                "BUCK AUX": (COL_W + C_W / 2.0, 110.0)}
PD_ROT = 180.0
PD_C = (COL_W + C_W - 4.0 - PD_W / 2.0, 168.0)

# Tile corners that are not on a seam, rounded.
ROUND = {"console": [(0.0, 0.0)],
         "ring": [(0.0, A_D + B_D), (COL_W, A_D + B_D)],
         "power": [(COL_W + C_W, 0.0), (COL_W + C_W, C_D)]}

# Dovetails: (tile carrying the tab, tile with the socket, seam, position along it)
JOINTS = [("ring", "console", ("y", A_D), 30.0),
          ("ring", "console", ("y", A_D), 88.0),
          ("power", "console", ("x", COL_W), 30.0),
          ("power", "console", ("x", COL_W), 88.0),
          ("power", "ring", ("x", COL_W), 155.0)]


# ----------------------------------------------------------------------------
# frames
# ----------------------------------------------------------------------------
def console_xy(u, v):
    """Console board KiCad (u, v), y down -> global (x, y)."""
    return CONSOLE_X0 + u, CONSOLE_Y0 + CONSOLE["outline"]["h"] - v


def _ring_radii(box):
    """(nearest, farthest) distance from the ring board's centre to a KiCad box."""
    r = RING["outline"]["w"] / 2.0
    x0, y0, x1, y1 = box[0] - r, box[1] - r, box[2] - r, box[3] - r
    nx, ny = min(max(0.0, x0), x1), min(max(0.0, y0), y1)
    return (math.hypot(nx, ny),
            max(math.hypot(x, y) for x in (x0, x1) for y in (y0, y1)))


def pd_xy(px, py):
    """PD board Eagle frame (y up, origin bottom-left) -> global."""
    a = math.radians(PD_ROT)
    dx, dy = px - PD_W / 2.0, py - PD_H / 2.0
    return (PD_C[0] + dx * math.cos(a) - dy * math.sin(a),
            PD_C[1] + dx * math.sin(a) + dy * math.cos(a))


def _box_dist(x, y, box):
    x0, y0, x1, y1 = box
    dx = max(x0 - x, 0.0, x - x1)
    dy = max(y0 - y, 0.0, y - y1)
    return math.hypot(dx, dy)


# ----------------------------------------------------------------------------
# the ring carrier's cradle
# ----------------------------------------------------------------------------
def ring_tube():
    """(inner, outer) radius of the tube under the encoder, from the layout."""
    enc = max(_ring_radii(p["box"])[1] for p in RING["pth_pads"] if p["ref"] == "ENC1")
    # A courtyard already carries its own margin round the part, so the tube may
    # meet it; a pad gets TUBE_CLR for the solder fillet.
    rest = [_ring_radii(p["box"])[0] - TUBE_CLR for p in RING["pth_pads"] if p["ref"] != "ENC1"]
    rest += [_ring_radii(p["courtyard"])[0] for p in RING["back_parts"]]
    ri, ro = enc + TUBE_CLR, min(rest)
    assert ro - ri >= TUBE_MIN_WALL, (
        f"TUBE: only {ro - ri:.2f} mm between the encoder's pads (r {enc:.2f}) and "
        f"the nearest part (r {min(rest):.2f})")
    return ri, ro


def crown_angles():
    """Global angles of the teeth that are fitted."""
    pitch = 360.0 / TEETH
    out = []
    for i in range(TEETH):
        a = (i + 0.5) * pitch   # half a pitch off: the USB edge falls between two teeth
        if abs((a - USB_ANGLE + 180.0) % 360.0 - 180.0) > USB_OPEN / 2.0:
            out.append(a)
    return out


# ----------------------------------------------------------------------------
# geometry
# ----------------------------------------------------------------------------
def _cyl(x, y, d, z0, h):
    return cq.Workplane("XY").workplane(offset=z0).center(x, y).circle(d / 2.0).extrude(h)


def _boss(x, y, h, d=BOSS_D):
    """A standoff with a heat-set insert pilot in its top."""
    b = _cyl(x, y, d, FLOOR_T - 0.01, h + 0.01)
    b = b.faces(">Z").edges().chamfer(0.4)
    return b.cut(_cyl(x, y, INSERT_PILOT_D, FLOOR_T + h - INSERT_PILOT_DEPTH,
                      INSERT_PILOT_DEPTH + 0.1))


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


# Which tile edges are seams, and which corners are free and get rounded.
SEAMS = {"console": ("x1", "y1"), "ring": ("y0", "x1"), "power": ("x0",)}


def _plate(name):
    x0, y0, x1, y1 = TILES[name]
    g = {k: SEAM_GAP if k in SEAMS[name] else 0.0 for k in ("x0", "x1", "y0", "y1")}
    gx0, gx1, gy0, gy1 = x0 + g["x0"], x1 - g["x1"], y0 + g["y0"], y1 - g["y1"]
    p = (cq.Workplane("XY").center((gx0 + gx1) / 2.0, (gy0 + gy1) / 2.0)
         .rect(gx1 - gx0, gy1 - gy0).extrude(FLOOR_T))
    for cx, cy in ROUND[name]:
        p = p.edges(cq.selectors.NearestToPointSelector((cx, cy, FLOOR_T / 2.0))).fillet(TILE_R)
    return p


def _text(solid, txt, x, y, size, angle=0.0):
    """Engrave a label 0.6 mm into the floor top."""
    t = (cq.Workplane("XY").workplane(offset=FLOOR_T - 0.6)
         .transformed(rotate=(0, 0, angle))
         .text(txt, size, 1.0, combine=False, halign="center", valign="center")
         .translate((x, y, 0)))
    return solid.cut(t)


def console_features():
    h = CONSOLE_STANDOFF_H
    parts = [_boss(*console_xy(hl["x"], hl["y"]), h) for hl in CONSOLE["holes"]]
    return parts


def _sector(profile, deg_c, width_mm, r_ref):
    """Revolve an (r, z) profile through width_mm (at r_ref) centred on deg_c,
    about the ring's centre."""
    span = math.degrees(width_mm / r_ref)
    return (cq.Workplane("XZ").polyline(profile).close()
            .revolve(span, (0, 0, 0), (0, 1, 0))
            .rotate((0, 0, 0), (0, 0, 1), deg_c - span / 2.0)
            .translate((RING_C[0], RING_C[1], 0)))


def ring_features():
    z_back = FLOOR_T + RING_LIFT
    z_front = z_back + RING["thickness"]
    ri, ro = ring_tube()
    tube = (cq.Workplane("XY").workplane(offset=FLOOR_T - 0.01).center(*RING_C)
            .circle(ro).circle(ri).extrude(RING_LIFT + 0.01))
    foot = (cq.Workplane("XY").workplane(offset=FLOOR_T - 0.01).center(*RING_C)
            .circle(ro + 3.0).circle(ri).extrude(3.0))
    parts = [tube.union(foot)]
    base = (cq.Workplane("XY").workplane(offset=FLOOR_T - 0.01).center(*RING_C)
            .circle(CROWN_OUT_R).circle(LEDGE_R).extrude(CROWN_BASE_H + 0.01))
    # the base ring is left out at the USB opening too, so the plug's cable lies flat
    span = USB_OPEN - math.degrees(TOOTH_W / CROWN_OUT_R)
    base = base.cut(_sector([(LEDGE_R - 1, FLOOR_T - 1), (CROWN_OUT_R + 1, FLOOR_T - 1),
                             (CROWN_OUT_R + 1, FLOOR_T + 5), (LEDGE_R - 1, FLOOR_T + 5)],
                            USB_ANGLE, math.radians(span) * CROWN_OUT_R, CROWN_OUT_R))
    parts.append(base)
    # Tooth section: post from the floor to over the board, ledge in under the
    # board's edge, its underside at 45 degrees so it prints without support.
    ledge_t = 0.4
    tooth = [(POST_R, FLOOR_T), (CROWN_OUT_R, FLOOR_T), (CROWN_OUT_R, z_front + LIP_ABOVE),
             (POST_R, z_front + LIP_ABOVE), (POST_R, z_back), (LEDGE_R, z_back),
             (LEDGE_R, z_back - ledge_t), (POST_R, z_back - ledge_t - (POST_R - LEDGE_R))]
    r_mid = (LEDGE_R + CROWN_OUT_R) / 2.0
    for a in crown_angles():
        parts.append(_sector(tooth, a, TOOTH_W, r_mid))
    return parts


def power_features():
    parts = []
    for px, py in PD_HOLES:
        parts.append(_boss(*pd_xy(px, py), PD_STANDOFF_H, PD_BOSS_D))
    iw, ih = BUCK_BODY[0] + 2 * BUCK_CLR, BUCK_BODY[1] + 2 * BUCK_CLR
    for cx, cy in BUCK_CENTRES.values():
        ring_ = (cq.Workplane("XY").workplane(offset=FLOOR_T - 0.01).center(cx, cy)
                 .rect(iw + 2 * CORRAL_T, ih + 2 * CORRAL_T).rect(iw, ih)
                 .extrude(CORRAL_H + 0.01))
        cut = (cq.Workplane("XY").workplane(offset=FLOOR_T).center(cx, cy)
               .rect(CORRAL_GAP, ih + 4 * CORRAL_T).extrude(CORRAL_H + 1)
               .union(cq.Workplane("XY").workplane(offset=FLOOR_T).center(cx, cy)
                      .rect(iw + 4 * CORRAL_T, CORRAL_GAP).extrude(CORRAL_H + 1)))
        parts.append(ring_.cut(cut))
    return parts


def build():
    """The three tiles, as {name: solid}, in their assembled positions."""
    feats = {"console": console_features(), "ring": ring_features(),
             "power": power_features()}
    tiles = {}
    for name in TILES:
        t = _plate(name)
        for f in feats[name]:
            t = t.union(f)
        tiles[name] = t
    for tab, sock, seam, at in JOINTS:
        axis, s = seam
        x0, y0, _, _ = TILES[sock]
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
    tiles["ring"] = _text(tiles["ring"], "XIAO USB", RING_C[0] - CROWN_OUT_R - 3.0,
                          RING_C[1], 3.2, 90.0)
    for label, (cx, cy) in BUCK_CENTRES.items():
        tiles["power"] = _text(tiles["power"], label, cx, cy, 6.0)
    px, py = pd_xy(PD_W / 2.0, PD_H / 2.0)
    tiles["power"] = _text(tiles["power"], "PD", px, py, 6.0)
    return {k: v.val() for k, v in tiles.items()}


# ----------------------------------------------------------------------------
# checks
# ----------------------------------------------------------------------------
def _annulus(r0, r1, z0, z1):
    return (cq.Workplane("XY").workplane(offset=z0).center(*RING_C)
            .circle(max(r1, r0 + 0.01)).circle(max(r0, 0.001)).extrude(z1 - z0))


def ring_keepout_solids():
    """What must stay empty round the ring carrier, as solids. The board can sit
    at any angle, so every part is swept round the centre into the annulus it
    could occupy: its courtyard to its depth, its solder joints, C1 lying, and
    the cup's catches under the edge. The USB-C plug is fixed in the opening."""
    z_back = FLOOR_T + RING_LIFT
    out = []
    for p in RING["back_parts"]:
        r0, r1 = _ring_radii(p["courtyard"])
        if p["ref"] == "C1":
            r1 = max(r1, RING_C1_REACH_R)
        depth = RING_PART_DEPTH.get(p["ref"])
        assert depth, f"RING: no depth for {p['ref']}; measure it and add it to RING_PART_DEPTH"
        out.append((p["ref"], _annulus(r0, r1, z_back - depth, z_back)))
    # Solder joints all have the same depth, so their annuli merge into a few.
    spans = sorted(_ring_radii(pd["box"]) for pd in RING["pth_pads"])
    merged = [list(spans[0])]
    for r0, r1 in spans[1:]:
        if r0 <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], r1)
        else:
            merged.append([r0, r1])
    for r0, r1 in merged:
        out.append((f"solder joints r {r0:.1f}..{r1:.1f}",
                    _annulus(r0, r1, z_back - SOLDER_JOINT, z_back)))
    u1 = next(p for p in RING["back_parts"] if p["ref"] == "U1")
    r = RING["outline"]["w"] / 2.0
    usb_r = math.hypot(u1["x"] - r, u1["y"] - r) + XIAO_USB_REACH
    a = math.radians(USB_ANGLE)
    plug = (cq.Workplane("XY").workplane(offset=z_back - USB_PLUG_DEPTH)
            .center(RING_C[0] + math.cos(a) * (usb_r + 15.0), RING_C[1] + math.sin(a) * (usb_r + 15.0))
            .rect(30.0, 2 * USB_PLUG_HALF_W).extrude(USB_PLUG_DEPTH))
    out.append(("USB-C plug", plug))
    return out


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

    # Console: the standoff tops touch nothing but their own hole's pad, and the
    # leads clear the floor.
    assert CONSOLE_STANDOFF_H >= CONSOLE_BACK_DEPTH + 3.0, "CONSOLE: leads reach the floor"
    for hl in CONSOLE["holes"]:
        for pd in CONSOLE["pth_pads"]:
            if pd["ref"] == hl["ref"]:
                continue
            d = _box_dist(hl["x"], hl["y"], pd["box"])
            assert d > BOSS_D / 2.0 + 0.3, (
                f"CONSOLE: the {hl['ref']} standoff lands {d:.2f} from {pd['ref']}.{pd['pad']}")
    for hl in CONSOLE["holes"]:
        x, y = console_xy(hl["x"], hl["y"])
        x0, y0, x1, y1 = TILES["console"]
        assert x0 + BOSS_D / 2 < x < x1 - BOSS_D / 2 and y0 + BOSS_D / 2 < y < y1 - BOSS_D / 2

    # Ring: depth, the tube, the crown against the cup's arms, the USB opening.
    assert RING_LIFT >= RING_BACK_DEPTH + 3.0, "RING: C1 reaches the floor"
    assert RING_LIFT >= RING_J1_PLUGGED + RING_LEAD_BEND, "RING: no room for J1's lead to bend"
    for nm, solid in ring_keepout_solids():
        v = tiles["ring"].intersect(solid.val()).Volume()
        assert v < 1e-3, f"RING: the ring tile runs {v:.2f} mm3 into {nm}"
    pitch = 360.0 / TEETH
    assert abs(CUP_ARM_PITCH / pitch - round(CUP_ARM_PITCH / pitch)) < 1e-9, (
        "RING: the arms' pitch is not a multiple of the teeth's, so they cannot all seat")
    r_arm = LEDGE_R               # the narrowest place an arm's catch can meet a tooth
    gap = math.radians(pitch) * r_arm - TOOTH_W * r_arm / ((LEDGE_R + CROWN_OUT_R) / 2.0)
    assert gap >= CUP_ARM_W + 1.0, f"RING: a {gap:.2f} gap between teeth does not take a {CUP_ARM_W} arm"
    assert POST_R > RING["outline"]["w"] / 2.0 and POST_R < CUP_ARM_OUT_R, (
        "RING: the posts must clear the board edge and reach in past the arms' outer face")
    # The interference check above has the board centred; it can also slide
    # `slop` toward any tooth. Nothing under it may then reach a ledge, C1 lying
    # outward included, and every arm must still overlap the posts radially.
    edge = max([_ring_radii(p["courtyard"])[1] for p in RING["back_parts"]] + [RING_C1_REACH_R])
    slop = POST_R - RING["outline"]["w"] / 2.0
    assert edge + slop < LEDGE_R, f"RING: a part at r {edge:.2f} can slide onto a ledge"
    overlap = CUP_ARM_OUT_R - (POST_R + slop)
    assert overlap >= 0.6, f"RING: an arm can slide to {overlap:.2f} of overlap with the posts"
    assert POST_R > CUP_WALL_R or LIP_ABOVE <= 0.085, "RING: the posts' tops hit the cup wall"
    # The opening must pass the plug at every angle the arms can seat at, i.e.
    # anywhere within half a pitch either way.
    fitted = crown_angles()
    lo = max(a for a in fitted if a < USB_ANGLE)
    hi = min(a for a in fitted if a > USB_ANGLE)
    half_tooth = math.degrees(TOOTH_W / 2.0 / POST_R)
    clear = (hi - lo) - 2 * half_tooth
    plug = 2 * math.degrees(math.asin(USB_PLUG_HALF_W / POST_R))
    assert clear - plug >= pitch, (
        f"RING: the {clear:.1f} deg opening leaves the {plug:.1f} deg plug no room to turn a pitch")
    ri, ro = ring_tube()
    msgs.append(f"ring tube r {ri:.2f}..{ro:.2f}, {len(fitted)} teeth, arm gap {gap:.2f}, "
                f"USB opening {clear:.1f} deg for a {plug:.1f} deg plug")

    # Power: the bosses sit inside the PD outline's ears, the corrals clear each other.
    for px, py in PD_HOLES:
        assert 0 < px < PD_W and 0 < py < PD_H
    (_, y1), (_, y2) = BUCK_CENTRES.values()
    assert abs(y2 - y1) >= BUCK_BODY[1] + 2 * (BUCK_CLR + CORRAL_T) + 4.0, "POWER: corrals overlap"
    pd_y0 = min(pd_xy(*h)[1] for h in PD_HOLES) - PD_BOSS_D / 2.0
    assert pd_y0 > y2 + BUCK_BODY[1] / 2 + BUCK_CLR + CORRAL_T + 4.0, "POWER: PD board on the buck"
    return msgs


# ----------------------------------------------------------------------------
# export
# ----------------------------------------------------------------------------
def _reference_boards():
    z_c = FLOOR_T + CONSOLE_STANDOFF_H
    w, h = CONSOLE["outline"]["w"], CONSOLE["outline"]["h"]
    console = (cq.Workplane("XY").workplane(offset=z_c)
               .center(CONSOLE_X0 + w / 2.0, CONSOLE_Y0 + h / 2.0)
               .rect(w, h).extrude(CONSOLE["thickness"]))
    for hl in CONSOLE["holes"]:
        x, y = console_xy(hl["x"], hl["y"])
        console = console.cut(_cyl(x, y, hl["drill"], z_c - 1, 4))
    ring = _cyl(*RING_C, RING["outline"]["w"], FLOOR_T + RING_LIFT, RING["thickness"])
    pd = (cq.Workplane("XY").workplane(offset=FLOOR_T + PD_STANDOFF_H).center(*PD_C)
          .rect(PD_W, PD_H).extrude(1.6))
    bucks = [cq.Workplane("XY").workplane(offset=FLOOR_T).center(cx, cy)
             .rect(BUCK_BODY[0], BUCK_BODY[1]).extrude(BUCK_BODY[2]).val()
             for cx, cy in BUCK_CENTRES.values()]
    return {"console_board_v3": console.val(), "ring_carrier": ring.val(),
            "stusb4500_pd": pd.val(), "bucks": cq.Compound.makeCompound(bucks)}


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
    colours = {"console": "gray30", "ring": "gray40", "power": "gray50"}
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
            open(p, "w").write("\n".join(l.rstrip() for l in txt) + "\n")
    print(f"wrote {len(tiles)} tiles (STEP + STL), the assembly and a top view in {OUT}")


def main():
    tiles = build()
    for m in check(tiles):
        print(" ", m)
    export(tiles)


if __name__ == "__main__":
    main()
