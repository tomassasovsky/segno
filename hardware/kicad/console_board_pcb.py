"""pcbnew layout generator for the Segno CONSOLE board v2 (issue #747).

Consumes `console_board.net` -- the SKiDL netlist is the single source of truth for
what connects to what -- and emits a placed, routed, poured, DRC-clean board plus a
JLCPCB-ready gerber zip.

Run (from hardware/kicad/, with KiCad's own Python, which is the one that has pcbnew):
    /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 console_board_pcb.py

Modelled on hardware/led_strip/ledstrip_pcb.py, which already does the
place -> pour -> DRC -> kicad-cli -> zip pipeline for the LED strip.

PLACEMENT DRIVES ROUTING
------------------------
No autorouter. The board is laid out so routing is nearly trivial: every connector
sits in the SAME left-to-right order as the Pico pads it serves, so each fan-out
diverges without crossing and routes on one layer. Ordering is a gate, not a hope --
_check() proves no signal net has to cross another before a single track is drawn.

GND is not routed at all: it is a solid B.Cu pour, and every GND pad gets a via.
"""
import math
import os
import re
import shutil
import subprocess
import sys

import pcbnew

FromMM, ToMM = pcbnew.FromMM, pcbnew.ToMM
HERE = os.path.dirname(os.path.abspath(__file__))
NETLIST = os.path.join(HERE, "console_board.net")
OUT = os.path.join(HERE, "out_console")
BOARD_PATH = os.path.join(OUT, "segno_console_board.kicad_pcb")
KICAD_CLI = "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
KICAD_FP = "/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints"
LOCAL_FP = os.path.join(HERE, "segno.pretty")

ORIGIN = (100.0, 60.0)          # board origin on the KiCad page
BW, BH = 115.0, 96.0            # see FLOORPLAN below
EDGE_R = 3.0                    # corner radius
MOUNT_D, MOUNT_INSET = 3.2, 5.0  # M3 clearance, from each corner

# Widths per the pcb-layout skill (IPC-2152 rule of thumb): ~1.0 mm for
# power/ground, ~0.6 mm for signal. The first cut used 0.35/0.8, which is
# under-sized on both counts -- the +5V_LED rail feeds 22 WS2812s.
TRACK_W = 0.6                   # signal
TRACK_PWR = 1.0                 # +5V / +5V_LED / +3V3
VIA_D, VIA_DRILL = 0.8, 0.4
CLEARANCE = 0.25

# MIDI IN's opto barrier: the DIN side of U2 must not share copper or a pour with
# anything else, or the isolation the H11L1 exists for is undone.
ISOLATION_GAP = 2.0


def P(x, y):
    return pcbnew.VECTOR2I(FromMM(ORIGIN[0] + x), FromMM(ORIGIN[1] + y))


# ---- FLOORPLAN --------------------------------------------------------------
# Two rules decide this layout, and neither is "make it look tidy".
#
# 1. THE PIN MAP IS HALF THE FLOORPLAN. The module's pads 1..20 are one physical
#    row and 21..40 the other, so console_board.py's GPIO choice decides which side
#    of the module a connector can sit on. Row B (up) carries CTRL, LINK, IND and
#    the expansion pins; row A (down) carries the ten footswitches and the ring.
#
# 2. CONNECTORS ARE GROUPED BY WHERE THEIR CABLE GOES, not by what they do
#    electrically. Five headers -- POWER, MIDI IN, MIDI OUT, CTRL 1, CTRL 2 -- all
#    terminate on the rear panel, so they sit together along the top edge IN THE
#    PANEL'S OWN LEFT-TO-RIGHT ORDER (gated below against rear_io_stations.json).
#    One harness, one edge, no crossings. Before this they were split between the
#    top band and the right column, so the rear-panel loom left the board twice.
#
#   y  8   J8 PWR   J5 MIDI-IN  J4 MIDI-OUT  J20 CTRL1  J21 CTRL2   J22 EXP
#   y 20   (their passives; U2's isolated pocket sits under J5). This band is 23 mm
#          deep, not 18: eleven axials belong here and at 18 mm R4 had no slot.
#   y 42   J3 | [========= PICO (rot 90) =========]  U1        | J2 (Pi ribbon,
#   y 57                    R1  R2                   J9        |  right edge)
#   y 64                    J6 RING   J7 LEDS
#   y 70   [============ debounce caps ============]
#   y 78   [========= ten footswitch headers ======]
REAR_PANEL_ORDER = ["J8", "J5", "J4", "J20", "J21"]   # = the panel's own order

PICO_X, PICO_Y = 53.5, 46.0
PLACEMENT = {
    "J1":  (PICO_X, PICO_Y, 90),   # Pico 2, rot 90 so the pad rows lie horizontal.
                                   # x 50, not 45: the switch row cannot start left
                                   # of x 12 without clipping a mounting hole, so the
                                   # module has to meet it rather than the other way
                                   # round -- at 45 the skew put SW_BANK on the
                                   # 42 mm hop limit exactly.
                                   # Its USB end points LEFT and nothing is reserved
                                   # for a cable: VSYS takes +5V from J3, the Pi
                                   # flashes it cold over SWD (J9), and control is
                                   # the UART on GP16/17. USB is bench-only.

    # top edge: the rear-panel loom, in the panel's order
    # Even 17.5 mm pitch, centred on x 57.5 -- the BOARD centre -- the same centre line as the switch row
    # below. These were at 14/30/47/64/81: three different gaps, group off-centre.
    "J8":  (22.5, 8.0, 0),         # POWER    -> J2 pin 5 (GPIO3, wakes the Pi)
    "J5":  (40.0, 8.0, 0),         # MIDI IN  -- 2 leads: DIN pins 4 and 5 only.
                                   # Pin 2 is left OFF at a receiver by MIDI 1.0;
                                   # bonding the shield here would short out the
                                   # isolation U2 exists to provide.
    "J4":  (57.5, 8.0, 0),         # MIDI OUT -- 3 leads: DIN pins 4, 5 and 2.
    "J20": (75.0, 8.0, 0),         # CTRL 1, over GP26 = pad 31
    "J21": (92.5, 8.0, 0),         # CTRL 2, over GP27 = pad 32
    "U2":  (40.0, 21.0, 0),        # H11L1, directly under its own jack, in its own
                                   # ISOLATION_GAP pocket

    # CTRL divider + anti-alias, hand-placed under their own two jacks. All five
    # anchor within a few mm of each other, so the spiral packs the first ones in
    # and leaves the last with no legal slot -- and these are signal-path parts, so
    # they should hug the pins they serve rather than land wherever there is room.
    "R8":  (73.5, 16.0, 0), "R7": (88.5, 16.0, 0),
    # The two MIDI OUT series resistors, likewise by hand. R3 spans U1's gate-C
    # output to the jack -- a 46 mm reach -- so anchored to either end it is 48 mm
    # from the other. A series part belongs BETWEEN its endpoints, not beside one.
    "R3":  (76.0, 31.0, 0), "R4": (57.5, 16.0, 0),
    "R6":  (81.0, 25.0, 0),
    "C13": (64.0, 21.0, 0), "C14": (75.0, 21.0, 0), "R9": (87.0, 21.0, 0),

    # left edge: power in and its reservoir
    "J3":  (10.0, 62.0, 90),       # 5 V in, beside VBUS/VSYS (pads 40/39)
    "C31": (10.0, 20.0, 0),        # 100uF  on +5V
    "C30": (10.0, 33.0, 0),        # 470uF  on +5V_LED

    # right: the buffer, then the ribbon on the edge itself
    "U1":  (93.0, 44.0, 0),        # 74AHCT125, sat LOW on purpose. Its ring input is
                                   # pin 5; RING_DATA comes off the module's row A
                                   # (the bottom row), so with U1 up at y 34 that one
                                   # net had to climb 18 mm THROUGH the link / IND /
                                   # EXP / CTRL bundle that crosses the same gap, and
                                   # it was the only net that would never route. At
                                   # y 44 pin 5 comes down to meet it. Pin 2 (IND,
                                   # from row B) is still within 2 mm of its own row.
    "J2":  (107.0, 40.0, 0),       # Pi ribbon, ON THE EDGE. A 40-way ribbon leaving
                                   # mid-board folds straight back over everything;
                                   # here the cable clears the board immediately.
    "J22": (53.5, 26.0, 0),        # expansion. Not on the top edge: its GP28 pin is
                                   # pad 34, near the module's LEFT end, while GP19..
                                   # GP22 are pads 25..29 toward the right -- from
                                   # the top-right corner that ADC lead ran 61 mm.
                                   # Sat here it reaches both ends of its own span.

    # under the module: series resistors, then the ring/LED pair
    # Both series resistors stand UPRIGHT in the channel beside U1 rather than lying
    # under the module. Laid out flat at y 61 the gate-B output had a 38 mm reach
    # across the busiest corner of the board and would not route at all. R1 sits
    # BELOW the corridor, not in it: at y 51 it plugged the very channel RING_DATA
    # needs to reach U1, and simply moved which of the two nets failed.
    # The right column, stacked so nothing sits in the RING_DATA corridor
    # (x 80.5..88): left to the spiral, C11 lands against the opto and R2 lands in
    # the corridor, and the one net that has to climb from row A to U1's input has
    # nowhere to go.
    "C11": (93.0, 31.0, 0),        # +5V decoupling for U1
    "C20": (25.0, 21.0, 0),        # +3V3 decoupling for U2
    "R1":  (68.0, 62.0, 0),       # 330R, U1 gate B -> J6 pin 5 (ring data)
    "R2":  (93.0, 57.0, 0),        # 330R, U1 gate C -> J7 pin 2 (indicators)
    "J6":  (63.5, 69.0, 0),        # ring/encoder, under pads 16/17/19/20
    "J7":  (82.0, 69.0, 0),        # indicators -- x matches J9 above
}
# footswitches J10..J19 along the bottom, left-to-right in GPIO order -- that
# ordering is what keeps the fan-out from crossing (gated in _check)
FSW_Y = 84.0
FSW_X0, FSW_X1 = 15.5, 99.5   # centred on the module's footswitch pads (4..15,
                               # x 45.5..73.4) so no lane crosses another. Starts at
                               # 12, not 6: KiCad's courtyard check is stricter than
                               # the pad extents this script compares, and J10 was
                               # clipping the corner mounting hole. The span
                               # is 84 mm, which is the floor: ten 8.5 mm JSTs plus
                               # the 0.8 mm keepout. It ends at 89 rather than 92 so
                               # the LAST debounce cap, which sits 8 mm higher than
                               # its switch, still clears the Pi ribbon.
CAP_Y = 76.0                   # the debounce cap row, one cap directly above its
                               # own switch -- see _place_debounce_caps()


def fsw_x(i):
    return FSW_X0 + (FSW_X1 - FSW_X0) * i / 9.0


for _i in range(10):
    PLACEMENT["J%d" % (10 + _i)] = (fsw_x(_i), FSW_Y, 0)

PWR_NETS = {"+5V", "+5V_LED", "+3V3"}
POUR_NET = "GND"


# Passives are NOT in the table above. Hand-placing 26 resistors and capacitors
# is a table that silently drifts from the netlist the first time a part is added.
# Instead they are placed BY the netlist: each one lands next to whichever placed
# part it shares the most nets with, in the nearest free slot. Deterministic
# (sorted iteration, first-fit outward spiral), and _check()'s overlap gate proves
# the result rather than trusting it.
KEEPOUT = 0.8                   # margin around every footprint, mm. Also covers
                                # the body overhanging its outermost pads.
GRID = 1.0                      # placement search step
STITCH_STEP = 12.0               # GND stitching via pitch


# ---- netlist ---------------------------------------------------------------

def _sexpr(text):
    """Minimal s-expression reader -> nested lists of str.

    A regex is not good enough here and the failure is silent: KiCad writes the
    netlist MULTI-LINE, so a pattern anchored on "(net (code N) (name ...)" never
    finds the next net and every net swallows the nodes of all those after it.
    That parses cleanly, produces plausible-looking output, and shorts the whole
    board together. Parse the parens properly instead.
    """
    tok = re.findall(r'\(|\)|"(?:[^"\\]|\\.)*"|[^\s()]+', text)
    pos = 0

    def read():
        nonlocal pos
        out = []
        while pos < len(tok):
            t = tok[pos]; pos += 1
            if t == "(":
                out.append(read())
            elif t == ")":
                return out
            else:
                out.append(t[1:-1] if t.startswith('"') else t)
        return out

    return read()


def _find(node, key):
    return [n for n in node if isinstance(n, list) and n and n[0] == key]


def _val(node, key, default=None):
    got = _find(node, key)
    return got[0][1] if got and len(got[0]) > 1 else default


def parse_netlist(path):
    """-> (components{ref: (lib, fpname, value)}, nets{name: [(ref, pad)]})."""
    root = _sexpr(open(path).read())
    top = root[0] if root and isinstance(root[0], list) else root
    comps, nets = {}, {}
    for section in _find(top, "components"):
        for comp in _find(section, "comp"):
            ref = _val(comp, "ref")
            fp = _val(comp, "footprint")
            if ref and fp and ":" in fp:
                lib, name = fp.split(":", 1)
                comps[ref] = (lib, name, _val(comp, "value", ""))
    for section in _find(top, "nets"):
        for net in _find(section, "net"):
            name = _val(net, "name")
            nodes = [(_val(n, "ref"), _val(n, "pin")) for n in _find(net, "node")]
            if name and nodes:
                nets[name] = nodes
    return comps, nets


# ---- board -----------------------------------------------------------------

def _outline(board):
    pts = [(EDGE_R, 0), (BW - EDGE_R, 0), (BW, EDGE_R), (BW, BH - EDGE_R),
           (BW - EDGE_R, BH), (EDGE_R, BH), (0, BH - EDGE_R), (0, EDGE_R)]
    segs = [(pts[0], pts[1]), (pts[2], pts[3]), (pts[4], pts[5]), (pts[6], pts[7])]
    for a, b in segs:
        s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_SEGMENT)
        s.SetStart(P(*a)); s.SetEnd(P(*b))
        s.SetLayer(pcbnew.Edge_Cuts); s.SetWidth(FromMM(0.1))
        board.Add(s)
    for cx, cy, sa, ea in ((EDGE_R, EDGE_R, (0, EDGE_R), (EDGE_R, 0)),
                           (BW - EDGE_R, EDGE_R, (BW - EDGE_R, 0), (BW, EDGE_R)),
                           (BW - EDGE_R, BH - EDGE_R, (BW, BH - EDGE_R), (BW - EDGE_R, BH)),
                           (EDGE_R, BH - EDGE_R, (EDGE_R, BH), (0, BH - EDGE_R))):
        a = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_ARC)
        a.SetCenter(P(cx, cy)); a.SetStart(P(*sa)); a.SetEnd(P(*ea))
        a.SetLayer(pcbnew.Edge_Cuts); a.SetWidth(FromMM(0.1))
        board.Add(a)


def _mounting_holes(board):
    """Real library footprints, not hand-built FOOTPRINT objects.

    A bare pcbnew.FOOTPRINT() has no library id, and the Specctra DSN exporter
    silently refuses the whole board when it meets one -- ExportSpecctraDSN
    returned False here while succeeding on segno_pedal_main.kicad_pcb, which is
    what pinned it down. A library part also brings a courtyard and silk for free.
    """
    out = {}
    for i, (x, y) in enumerate((
            (MOUNT_INSET, MOUNT_INSET), (BW - MOUNT_INSET, MOUNT_INSET),
            (BW - MOUNT_INSET, BH - MOUNT_INSET), (MOUNT_INSET, BH - MOUNT_INSET))):
        out["H%d" % (i + 1)] = _load_fp(board, "MountingHole", "MountingHole_3.2mm_M3",
                                        "H%d" % (i + 1), x, y, 0)
    return out


def _load_fp(board, lib, name, ref, x, y, rot, by_centre=True):
    """Place a footprint so (x, y) is the CENTRE of its extent.

    A footprint's origin is wherever its author put it -- pad 1 on an axial
    resistor, a corner on the Pico (whose pads run 0..17.78 x 0..48.26). Placing
    by origin means every coordinate in PLACEMENT silently means something
    different, which is how the Pico ended up straddling the footswitch row.
    """
    path = LOCAL_FP if lib == "segno" else os.path.join(KICAD_FP, lib + ".pretty")
    fp = pcbnew.FootprintLoad(path, name)
    if fp is None:
        raise SystemExit(f"footprint not found: {lib}:{name} (looked in {path})")
    fp.SetReference(ref)
    board.Add(fp)
    fp.SetPosition(P(0.0, 0.0))
    if rot:
        fp.SetOrientationDegrees(rot)
    cw, ch = _courtyard_size(lib, name)
    if abs((rot % 180.0) - 90.0) < 1.0:
        cw, ch = ch, cw
    _SIZE[ref] = (cw, ch)
    if by_centre:
        off = _centre(fp)
        fp.SetPosition(P(x - off[0], y - off[1]))
    else:
        fp.SetPosition(P(x, y))
    return fp


def _pad_xy(fp, padname):
    for p in fp.Pads():
        if p.GetNumber() == str(padname):
            pos = p.GetPosition()
            return (ToMM(pos.x) - ORIGIN[0], ToMM(pos.y) - ORIGIN[1])
    return None


def _track(board, net, layer, width, a, b):
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(P(*a)); t.SetEnd(P(*b))
    t.SetWidth(FromMM(width)); t.SetLayer(layer)
    t.SetNet(net)
    board.Add(t)


def _via(board, net, x, y):
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(P(x, y))
    v.SetWidth(FromMM(VIA_D)); v.SetDrill(FromMM(VIA_DRILL))
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    v.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    v.SetNet(net)
    board.Add(v)


def _stitch_grid(board, net, fps):
    """A coarse via grid tying the B.Cu pour together.

    Routing on B.Cu chops the pour into islands, and an island with no via back to
    the net reads as "unconnected" -- four of them did. Per-pad vias alone are not
    enough because they sit where the copper is busiest. Vias go in BEFORE the DSN
    export so Freerouting treats them as obstacles and routes around them.
    """
    boxes = [_bbox_mm(fp) for fp in fps.values()]
    n = 0
    y = STITCH_STEP
    while y < BH - STITCH_STEP / 2:
        x = STITCH_STEP
        while x < BW - STITCH_STEP / 2:
            if not any(b[0] <= x <= b[2] and b[1] <= y <= b[3] for b in boxes):
                _via(board, net, x, y)
                n += 1
            x += STITCH_STEP
        y += STITCH_STEP
    return n


# 12 mm, not 18: with SOLID pad ties the pads themselves bridged the pour, so a
# coarse grid was enough. Thermal relief deliberately stops them doing that, which
# left an F.Cu region with no path home. Relief and stitch pitch are one decision,
# not two.


def _pour_gnd(board, net, layer=pcbnew.B_Cu):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(net)
    z.SetLocalClearance(FromMM(CLEARANCE))
    z.SetMinThickness(FromMM(0.2))
    # Thermal relief, NOT a solid tie. This was solid on the strength of "every
    # part here is through-hole and hand-soldered, so the usual wave/reflow thermal
    # argument is moot" -- which stopped being true the moment the Pico became a
    # surface-mount module. Its nine GND pads now sit in a plane on their own layer,
    # and a solid tie wicks the iron's heat straight into that plane: cold joints on
    # the one part that is painful to rework.
    #
    # The original reason for going solid was five "starved_thermal" errors from
    # spokes too narrow to form, which is a symptom of leaving the widths at their
    # defaults rather than a reason to abandon relief -- so they are set explicitly.
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(FromMM(0.3))
    z.SetThermalReliefSpokeWidth(FromMM(0.4))
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_AREA)
    # Drop slivers under 3 mm2. A fragment that small reaches one pad and goes
    # nowhere -- it cannot carry a return, and it fails DRC as a starved thermal
    # because a single spoke lands on an island. Every GND pad already has its own
    # via to the plane on the other layer, so nothing is lost by removing them.
    z.SetMinIslandArea(int(FromMM(3.0)) * int(FromMM(1.0)))
    o = z.Outline()
    o.NewOutline()
    for x, y in ((0.3, 0.3), (BW - 0.3, 0.3), (BW - 0.3, BH - 0.3), (0.3, BH - 0.3)):
        o.Append(P(x, y).x, P(x, y).y)
    z.SetIsFilled(False)
    board.Add(z)
    return z


def _silk(board, text, x, y, h=1.2):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(text)
    t.SetPosition(P(x, y))
    t.SetLayer(pcbnew.F_SilkS)
    t.SetTextSize(pcbnew.VECTOR2I(FromMM(h), FromMM(h)))
    t.SetTextThickness(FromMM(h / 6.0))
    board.Add(t)


_CY = {}          # (lib, name) -> (w, h) of the UNROTATED courtyard, measured once
_SIZE = {}        # ref -> (w, h) after this instance's rotation


def _courtyard_size(lib, name):
    """Courtyard w/h of a pristine, unrotated, unplaced copy.

    Measured from its own fresh load rather than from the placed instance,
    because the cached courtyard polygon is INCONSISTENT: it follows
    SetOrientationDegrees() for some footprints (the Pico) and not others (the
    2x20 IDC). Reading it once at rotation 0 and rotating by hand is the only
    version that gives the same answer every time.
    """
    key = (lib, name)
    if key not in _CY:
        b = pcbnew.BOARD()
        path = LOCAL_FP if lib == "segno" else os.path.join(KICAD_FP, lib + ".pretty")
        fp = pcbnew.FootprintLoad(path, name)
        w = h = 0.0
        if fp is not None:
            b.Add(fp)
            fp.SetPosition(pcbnew.VECTOR2I(0, 0))
            try:
                cb = fp.GetCourtyard(pcbnew.F_CrtYd).BBox()
                w, h = ToMM(cb.GetWidth()), ToMM(cb.GetHeight())
            except Exception:
                pass
        _CY[key] = (w, h)
    return _CY[key]


def _extent(fp):
    """(x0, y0, x1, y1) in board-local mm -- the footprint's real keep-out area.

    Three traps, each of which yields plausible numbers:
      * GetBoundingBox() includes the reference and value TEXT -- a 5 mm disc cap
        measures 26.7 x 6.7 that way, a 10 mm axial resistor 43.2 x 6.4.
      * The cached COURTYARD follows rotation for some footprints and not others.
      * PADS follow rotation reliably but are smaller than the courtyard, and DRC
        judges courtyards -- so a pads-only gate passes boards DRC then rejects.

    So: pads give the CENTRE (always rotation-correct), a pristine load gives the
    courtyard SIZE, and the rotation is applied here. Gate and DRC now agree.
    """
    xs, ys = [], []
    for pad in fp.Pads():
        pos, sz = pad.GetPosition(), pad.GetSize()
        xs += [ToMM(pos.x - sz.x // 2) - ORIGIN[0], ToMM(pos.x + sz.x // 2) - ORIGIN[0]]
        ys += [ToMM(pos.y - sz.y // 2) - ORIGIN[1], ToMM(pos.y + sz.y // 2) - ORIGIN[1]]
    if not xs:
        pos = fp.GetPosition()
        c = (ToMM(pos.x) - ORIGIN[0], ToMM(pos.y) - ORIGIN[1])
        return (c[0], c[1], c[0], c[1])
    cx, cy = (min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    cw, ch = _SIZE.get(fp.GetReference(), (0.0, 0.0))
    return (cx - max(w, cw) / 2.0, cy - max(h, ch) / 2.0,
            cx + max(w, cw) / 2.0, cy + max(h, ch) / 2.0)


def _centre(fp):
    x0, y0, x1, y1 = _extent(fp)
    return ((x0 + x1) / 2.0, (y0 + y1) / 2.0)


def _bbox_mm(fp):
    x0, y0, x1, y1 = _extent(fp)
    return (x0 - KEEPOUT, y0 - KEEPOUT, x1 + KEEPOUT, y1 + KEEPOUT)


def _fp_size_mm(fp):
    x0, y0, x1, y1 = _extent(fp)
    return (x1 - x0, y1 - y0)


def _best_anchor(ref, net_of, fps, nets):
    """Where a passive wants to be: on the pads of its most SPECIFIC net.

    Counting shared nets and taking the winner does not work -- GND, +3V3 and +5V
    touch nearly every part, so every passive ties on the rails and the tie breaks
    alphabetically, which is how R7 (the CTRL reference divider) ended up 80 mm from
    the two jacks it serves. A 2-pad signal net says far more about where a part
    belongs than a 40-pad rail, so nets are scored by 1/len and the anchor is the
    CENTROID OF THE PADS of the best one, not the centre of some whole footprint.
    """
    mine = net_of.get(ref, set()) - POURED_NETS
    best, best_score, pool = None, 0.0, []
    for name in sorted(mine):
        nodes = nets.get(name, ())
        placed = [(r, pd) for r, pd in nodes if r in fps]
        if not placed:
            continue
        score = 1.0 / len(nodes)
        if score < best_score - 1e-9:
            continue
        pts = []
        for r, pd in placed:
            for pad in fps[r].Pads():
                if pad.GetNumber() == str(pd):
                    pts.append((ToMM(pad.GetPosition().x) - ORIGIN[0],
                                ToMM(pad.GetPosition().y) - ORIGIN[1]))
        if not pts:
            continue
        # A series part (R1: U1 -> ring header) belongs BETWEEN its neighbours, so
        # equally-specific nets are pooled rather than decided alphabetically --
        # picking one put R1 hard against U1 and 51 mm from the J6 it feeds.
        if score > best_score + 1e-9:
            best_score, pool = score, []
        pool.append((sum(x for x, _ in pts) / len(pts),
                     sum(y for _, y in pts) / len(pts)))
        best = (sum(x for x, _ in pool) / len(pool),
                sum(y for _, y in pool) / len(pool))
    if best is None:                       # rails-only part (bulk caps): fall back
        for other, fp in sorted(fps.items()):
            if net_of.get(ref, set()) & net_of.get(other, set()):
                return _centre(fp)
        return (BW / 2.0, BH / 2.0)
    return best


# How far a passive may be pushed from its anchor before the placement is simply
# wrong. Unbounded, the spiral walks until it finds ANY hole: two footswitch
# debounce caps ended up 40 mm away on the far side of the Pi ribbon, which no gate
# caught because each was still within a hop of its own net. Failing loudly here is
# the point -- it means "make room", not "put it anywhere".
MAX_SLOT_R = 28.0


def _free_slot(anchor, w, h, boxes):
    """Nearest free position to `anchor`, searched as an outward square spiral."""
    ax, ay = anchor
    for radius in range(1, int(MAX_SLOT_R / GRID) + 1):
        cands = []
        for i in range(-radius, radius + 1):
            cands += [(ax + i * GRID, ay - radius * GRID),
                      (ax + i * GRID, ay + radius * GRID),
                      (ax - radius * GRID, ay + i * GRID),
                      (ax + radius * GRID, ay + i * GRID)]
        cands.sort(key=lambda c: (c[0] - ax) ** 2 + (c[1] - ay) ** 2)
        for cx, cy in cands:
            x0, y0 = cx - w / 2 - KEEPOUT, cy - h / 2 - KEEPOUT
            x1, y1 = cx + w / 2 + KEEPOUT, cy + h / 2 + KEEPOUT
            if x0 < 1.0 or y0 < 1.0 or x1 > BW - 1.0 or y1 > BH - 1.0:
                continue
            if any(not (x1 <= b[0] or b[2] <= x0 or y1 <= b[1] or b[3] <= y0) for b in boxes):
                continue
            return (cx, cy)
    return None


# ---- gates -----------------------------------------------------------------

# The ratsnest budget. Sum, over every routed net, of the minimum spanning tree
# through its pads -- i.e. the shortest total copper that could possibly connect
# the board as placed. It is the one number that says whether a floorplan is
# efficient or merely tidy, and it is why the pin map and this table have to move
# together. GND is excluded: it is a pour, not a net of tracks.
#
# Measured 1581 mm on the layout below, on a 115x95 board. For scale, the first
# floorplan measured 2495 mm and needed 160x100.
#
# It is NOT the minimum achievable: packing the five rear-panel headers together in
# the panel's own order costs about 180 mm, most of it PWR_BTN, because POWER is
# leftmost on the panel while the Pi ribbon it lands on is at the right edge. That
# is a trade taken deliberately. The whole rear loom is then one flat bundle
# leaving one edge in one order, which is worth more on a hand-wired console than
# 180 mm of copper carrying a button press. Do not "optimise" it back.
#
# The budget is the measurement plus ~10%,
# so a placement that drifts back toward "connectors in neat rows regardless of
# which pad they serve" fails here rather than at the autorouter.
#
# ~500 mm of that total is the ten SW_* nets, and it is NOT a defect to be
# optimised away. The module's footswitch pads span 28 mm; ten 8.5 mm JSTs cannot
# span less than 84 mm side by side, so the fan-out is geometric. Staggering them
# into two rows would buy ~150 mm and cost the one property that matters on a
# hand-wired board: pedal 1..10 reading left to right, unambiguously, at the bench.
# These are debounced switch lines -- 60 mm of trace is electrically free. Keep the
# straight ordered row.
MAX_RATSNEST_MM = 1740.0
POURED_NETS = {"GND"}

# The ratsnest total is a GLOBAL number, and --selftest proved it cannot see a
# single connector moving to the wrong end of the board: shifting J6 back across
# the module cost ~100 mm, which any sane budget absorbs. So there is a second,
# LOCAL gate. Every pad on a signal net must be within MAX_HOP_MM of the nearest
# other pad on that net -- i.e. no part is stranded away from what it wires to.
#
# Measured worst hops on the layout below: 38 mm (SW_TRACK3, the geometric
# footswitch fan-out) and 30 mm (MIDI_RX, which has to cross J2's body). 42 mm is
# the larger plus ~10%. Rails are exempt: +5V/+3V3/+5V_LED touch parts at both ends
# of the board by definition, and are carried by wide traces and the pour.
MAX_HOP_MM = 42.0
RAIL_NETS = {"+3V3", "+5V", "+5V_LED"}


def worst_hops(fps, nets):
    """-> [(distance_mm, net, ref, pad)] worst first, signal nets only."""
    pads = {}
    for ref, fp in fps.items():
        for pad in fp.Pads():
            pads[(ref, pad.GetNumber())] = (ToMM(pad.GetPosition().x),
                                            ToMM(pad.GetPosition().y))
    out = []
    for name, nodes in nets.items():
        if name in POURED_NETS or name in RAIL_NETS:
            continue
        # Nets landing on J2 are exempt. J2's position is not a routing choice --
        # a 40-way ribbon has to exit at a board edge, and no edge on a 140 mm board
        # is within 42 mm of the module. Every signal on it is slow (MIDI is 31.25
        # kbaud, the link a UART, SWD a flashing port, PWR_BTN a switch), so trace
        # length is not the binding constraint; where the cable goes is. The rest of
        # the board is still checked, and so are these nets' OTHER ends.
        if any(r == "J2" for r, _p in nodes):
            continue
        here = {n: pads[n] for n in nodes if n in pads}
        if len(here) < 2:
            continue
        for node, pt in here.items():
            d = min(math.dist(pt, q) for m, q in here.items() if m != node)
            out.append((d, name, node[0], node[1]))
    out.sort(reverse=True)
    return out


def ratsnest_mm(fps, nets, per_net=False):
    """Total MST length over all routed nets, in mm."""
    pads = {}
    for ref, fp in fps.items():
        for pad in fp.Pads():
            pads.setdefault((ref, pad.GetNumber()), (ToMM(pad.GetPosition().x),
                                                     ToMM(pad.GetPosition().y)))
    out, total = {}, 0.0
    for name, nodes in nets.items():
        if name in POURED_NETS:
            continue
        pts = [pads[n] for n in nodes if n in pads]
        if len(pts) < 2:
            continue
        # Prim's, O(n^2) -- the biggest net here has 8 pads.
        reached, rest, length = [pts[0]], list(pts[1:]), 0.0
        while rest:
            d, i, j = min((math.dist(a, b), bi, ai)
                          for ai, a in enumerate(reached)
                          for bi, b in enumerate(rest))
            length += d
            reached.append(rest.pop(i))
        out[name] = length
        total += length
    return (total, out) if per_net else total


_QUIET = False


def _check(fps, nets, board=None):
    """Prove the layout is sane BEFORE any copper is drawn.

    The load-bearing one is CROSSING: this board has no autorouter, and routing is
    only trivial because every fan-out preserves left-to-right order. If an
    ordering ever breaks, two tracks cross on one layer and the board is quietly
    wrong -- so it is checked, not assumed.
    """
    # every placed footprint is inside the outline, with room for the edge
    for ref, fp in fps.items():
        x0, y0, x1, y1 = _extent(fp)
        assert 0.5 <= x0 and x1 <= BW - 0.5 and 0.5 <= y0 and y1 <= BH - 0.5, (
            f"PLACE: {ref} spans ({x0:.1f},{y0:.1f})..({x1:.1f},{y1:.1f}), outside "
            f"the {BW:.0f}x{BH:.0f} outline")

    # footprints must not overlap each other
    refs = sorted(fps)
    for i, a in enumerate(refs):
        for b in refs[i + 1:]:
            ax0, ay0, ax1, ay1 = _extent(fps[a])
            bx0, by0, bx1, by1 = _extent(fps[b])
            if not (ax1 <= bx0 or bx1 <= ax0 or ay1 <= by0 or by1 <= ay0):
                raise AssertionError(
                    f"PLACE: {a} and {b} overlap -- footprints cannot share copper area")

    # the footswitch fan-out must preserve order, or its tracks cross
    order = []
    for i in range(10):
        ref = "J%d" % (10 + i)
        pad = _pad_xy(fps[ref], "1")
        sig = [n for n, nodes in nets.items() if (ref, "1") in nodes]
        assert len(sig) == 1, f"CROSSING: {ref} pin 1 is on {sig}, expected exactly one net"
        pico_pad = [p for r, p in nets[sig[0]] if r == "J1"]
        assert len(pico_pad) == 1, f"CROSSING: {sig[0]} does not land on exactly one Pico pad"
        order.append((pad[0], _pad_xy(fps["J1"], pico_pad[0])[0], ref, sig[0]))
    order.sort()
    xs = [o[1] for o in order]
    assert xs == sorted(xs), (
        "CROSSING: the footswitch JSTs are not in the same left-to-right order as "
        "the Pico pads they serve, so their fan-out tracks cross on one layer. "
        "Order seen: " + ", ".join("%s->%.1f" % (o[2], o[1]) for o in order))

    # the opto's DIN side must be isolated: no other footprint within ISOLATION_GAP
    ux0, uy0, ux1, uy1 = _extent(fps["U2"])
    # Only parts that actually SHARE A NET with the opto or its jack belong inside
    # the barrier. Exempting every ref beginning R/C/D -- as this did -- waved
    # through every resistor and capacitor on the board, so the gate could not fail
    # for the most likely mistake there is: parking an unrelated passive in the moat.
    # The barrier is the DIN SIDE specifically: U2 pins 1 and 2, and J5. Not every
    # net U2 touches -- its pins 5 and 6 are GND and +3V3, i.e. the whole board, so
    # keying off "shares a net with U2" exempts everything and the gate dies.
    din_side = {("U2", "1"), ("U2", "2")}
    inside = {"U2", "J5"}
    for n, nodes in nets.items():
        if n in POURED_NETS or n in RAIL_NETS:
            continue
        if any(nd in din_side or nd[0] == "J5" for nd in nodes):
            inside.update(r for r, _p in nodes)
    for ref, fp in fps.items():
        if ref in inside:
            continue
        x0, y0, x1, y1 = _extent(fp)
        dx = max(ux0 - x1, x0 - ux1, 0.0)
        dy = max(uy0 - y1, y0 - uy1, 0.0)
        d = (dx * dx + dy * dy) ** 0.5
        assert d >= ISOLATION_GAP, (
            f"ISOLATION: {ref} is {d:.2f} mm from the opto U2, under the "
            f"{ISOLATION_GAP} mm barrier -- MIDI IN's isolation is the whole point of U2")
    # the placement must actually be efficient, not just legal
    total, per = ratsnest_mm(fps, nets, per_net=True)
    worst = sorted(per.items(), key=lambda kv: -kv[1])[:3]
    if not _QUIET:
        print("\n  ratsnest %.0f mm on %.0fx%.0f (%.0f cm2), budget %.0f mm ... "
              % (total, BW, BH, BW * BH / 100.0, MAX_RATSNEST_MM), end="")
    for t in (board.GetDrawings() if board else []):
        if t.GetClass() == "PCB_TEXT" and t.IsOnLayer(pcbnew.F_SilkS):
            b = t.GetBoundingBox()
            x0, y0 = ToMM(b.GetLeft()) - ORIGIN[0], ToMM(b.GetTop()) - ORIGIN[1]
            x1, y1 = ToMM(b.GetRight()) - ORIGIN[0], ToMM(b.GetBottom()) - ORIGIN[1]
            for ref, fp in fps.items():
                fx0, fy0, fx1, fy1 = _extent(fp)
                if not (x1 < fx0 or fx1 < x0 or y1 < fy0 or fy1 < y0):
                    raise AssertionError(
                        f"SILK: '{t.GetText()}' is printed across {ref} -- silkscreen "
                        "over a pad or a body is unreadable and can foul the solder mask")
            assert 0 <= x0 and x1 <= BW and 0 <= y0 and y1 <= BH, (
                f"SILK: '{t.GetText()}' spans ({x0:.1f},{y0:.1f})..({x1:.1f},{y1:.1f}), "
                f"off the {BW:.0f}x{BH:.0f} outline -- it will not be printed")

    xs = [(_extent(fps[r])[0] + _extent(fps[r])[2]) / 2.0
          for r in REAR_PANEL_ORDER if r in fps]
    assert xs == sorted(xs), (
        "REAR_ORDER: the rear-panel headers are not in the panel's own left-to-right "
        f"order {REAR_PANEL_ORDER} (they sit at {[round(x, 1) for x in xs]}) -- the "
        "loom would have to cross itself between the board and the panel")
    ys = [(_extent(fps[r])[1] + _extent(fps[r])[3]) / 2.0
          for r in REAR_PANEL_ORDER if r in fps]
    assert max(ys) - min(ys) < 2.0, (
        "REAR_ORDER: the rear-panel headers are not on one edge -- the whole point "
        "is that this loom leaves the board once, from one place")

    # A solid pad tie is defensible on an all-through-hole board and wrong the
    # moment anything is surface-mount: an SMD pad tied straight into a plane wicks
    # the iron's heat away and cold-joints. That transition is exactly what happened
    # here and nothing caught it, so it is checked rather than remembered.
    smd = [r for r, fp in fps.items()
           if any(p.GetAttribute() == pcbnew.PAD_ATTRIB_SMD for p in fp.Pads())]
    if smd and board:
        for z in board.Zones():
            assert z.GetPadConnection() != pcbnew.ZONE_CONNECTION_FULL, (
                f"THERMALS: the {z.GetNetname()} pour ties pads solid, but "
                f"{sorted(smd)[:3]} are surface-mount -- SMD pads need thermal "
                "relief or they cannot be hand-soldered reliably")

    # Keep the corridor off the module's USB end clear. USB is not needed in normal
    # operation, but a board that makes it physically impossible to plug in is a
    # different claim -- and the 5 V inlet was sitting directly in front of the
    # socket. The module's USB is at its LEFT end (it is rotated 90 deg), so the
    # corridor is everything left of it within the connector's own height.
    px0, py0, _px1, py1 = _extent(fps["J1"])
    ucy = (py0 + py1) / 2.0
    usb = (0.0, ucy - 6.0, px0, ucy + 6.0)
    for ref, fp in fps.items():
        if ref == "J1":
            continue
        x0, y0, x1, y1 = _extent(fp)
        if not (x1 < usb[0] or usb[2] < x0 or y1 < usb[1] or usb[3] < y0):
            raise AssertionError(
                f"USB_CLEAR: {ref} sits in the corridor off the module's USB end "
                f"(x<{usb[2]:.0f}, y {usb[1]:.0f}..{usb[3]:.0f}) -- a cable could "
                "never be plugged in")

    hops = worst_hops(fps, nets)
    if hops:
        d, name, ref, pad = hops[0]
        assert d <= MAX_HOP_MM, (
            f"HOP: {ref} pad {pad} is {d:.0f} mm from the nearest other pad on "
            f"{name} (limit {MAX_HOP_MM:.0f} mm) -- that part is placed away from "
            "what it wires to. Move it, or move the pin map.")
    assert total <= MAX_RATSNEST_MM, (
        f"RATSNEST: {total:.0f} mm of minimum copper, budget {MAX_RATSNEST_MM:.0f} mm. "
        f"The placement is wasting space -- longest nets: "
        + ", ".join(f"{n} {v:.0f}mm" for n, v in worst))

    return True


# ---- route -----------------------------------------------------------------

def _route(board, fps, nets, netmap):
    """Straight pad-to-pad on F.Cu for signals; GND is poured, not routed."""
    routed = 0
    for name, nodes in sorted(nets.items()):
        if name == POUR_NET:
            continue
        pts = []
        for ref, pad in nodes:
            if ref in fps:
                xy = _pad_xy(fps[ref], pad)
                if xy:
                    pts.append(xy)
        if len(pts) < 2:
            continue
        width = TRACK_PWR if name in PWR_NETS else TRACK_W
        # chain them in x order so a multi-point net is a bus, not a star
        pts.sort()
        for a, b in zip(pts, pts[1:]):
            _track(board, netmap[name], pcbnew.F_Cu, width, a, b)
            routed += 1
    return routed


def _stitch_gnd(board, fps, nets, netmap):
    """Every GND pad gets a via into the B.Cu pour."""
    n = 0
    for ref, pad in nets.get(POUR_NET, []):
        if ref not in fps:
            continue
        xy = _pad_xy(fps[ref], pad)
        if xy:
            _via(board, netmap[POUR_NET], xy[0], xy[1])
            n += 1
    return n


# ---- build / export --------------------------------------------------------




# Function labels, the way segno_pedal_main does it: every connector on that board
# says what it is (REC / STOP / TRK1 / RING / LEDS / MIDI OUT / 9V), because the
# thing that gets wired at the bench is a header, not a reference designator. Refs
# alone are useless with ten identical 2-pin JSTs in a row.
LABELS = {
    "J10": "REC",  "J11": "STOP", "J12": "UNDO", "J13": "MODE", "J14": "TRK1",
    "J15": "TRK2", "J16": "TRK3", "J17": "TRK4", "J18": "CLR",  "J19": "BANK",
    "J2":  "PI",     "J3":  "5V IN",    "J20": "CTRL 1", "J21": "CTRL 2",
    "J22": "EXP",    "J4":  "MIDI OUT", "J5":  "MIDI IN",
    "J6":  "RING",   "J7":  "LEDS",     "J8":  "PWR BTN",
}
SILK_H = 1.0
# Pinned label rows. A GROUP of labels reads as tidy only if it sits on one side at
# one y; left to the search below, the rear-panel row came out "above, right, above,
# right, right" and REC sat left of its header while its nine neighbours sat above.
# Each was individually legal and collectively a mess. The search stays as the
# fallback for the handful of one-off headers.
LABEL_ROW = dict(
    [(r, 3.0) for r in ("J8", "J5", "J4", "J20", "J21")]
    + [("J%d" % (10 + i), 79.2) for i in range(10)]
)
SILK_PAD = 0.5


def _labels(board, fps):
    """Put each label in the nearest free spot around its connector.

    Hand-tuned offsets do not survive: every time the floorplan moved, another
    label landed on a part, and the silk gate rejected the board. So the labels are
    placed the same way the passives are -- try the four sides at increasing
    distance, take the first gap that is actually empty.
    """
    taken = [_extent(fp) for fp in fps.values()]
    for t in board.GetDrawings():
        if t.GetClass() == "PCB_TEXT" and t.IsOnLayer(pcbnew.F_SilkS):
            bb = t.GetBoundingBox()
            taken.append((ToMM(bb.GetLeft()) - ORIGIN[0], ToMM(bb.GetTop()) - ORIGIN[1],
                          ToMM(bb.GetRight()) - ORIGIN[0], ToMM(bb.GetBottom()) - ORIGIN[1]))

    def free(x0, y0, x1, y1):
        if x0 < 0.5 or y0 < 0.5 or x1 > BW - 0.5 or y1 > BH - 0.5:
            return False
        return all(x1 + SILK_PAD < bx0 or bx1 + SILK_PAD < x0 or
                   y1 + SILK_PAD < by0 or by1 + SILK_PAD < y0
                   for bx0, by0, bx1, by1 in taken)

    for ref in sorted(LABELS):
        if ref not in fps:
            continue
        text = LABELS[ref]
        if ref in LABEL_ROW:
            x0, _y0, x1, _y1 = _extent(fps[ref])
            _silk(board, text, (x0 + x1) / 2.0, LABEL_ROW[ref], SILK_H)
            continue
        w, h = 0.72 * SILK_H * len(text), SILK_H * 1.4
        px0, py0, px1, py1 = _extent(fps[ref])
        cx, cy = (px0 + px1) / 2.0, (py0 + py1) / 2.0
        spot = None
        for d in [i * 0.5 for i in range(2, 24)]:
            for x, y in ((cx, py0 - d), (cx, py1 + d), (px1 + d + w / 2, cy),
                         (px0 - d - w / 2, cy)):
                if free(x - w / 2, y - h / 2, x + w / 2, y + h / 2):
                    spot = (x, y)
                    break
            if spot:
                break
        assert spot, f"SILK: nowhere free to print '{text}' next to {ref}"
        _silk(board, text, spot[0], spot[1], SILK_H)
        taken.append((spot[0] - w / 2, spot[1] - h / 2,
                      spot[0] + w / 2, spot[1] + h / 2))


def _debounce_caps(nets):
    """-> {cap_ref: (x, y, rot)}, each 100nF sat directly above the switch it debounces.

    Left to the auto-placer these scattered: seven landed in the channel, C8 was
    pushed below the footswitch row entirely, and the row looked arbitrary because it
    was. The pairing comes from the netlist rather than from C-numbering, so it stays
    correct if console_board.py ever builds the switches in a different order.
    """
    out = {}
    for i in range(10):
        j = "J%d" % (10 + i)
        for name, nodes in nets.items():
            if not name.startswith("SW_"):
                continue
            refs = {r for r, _p in nodes}
            if j not in refs:
                continue
            caps = sorted(r for r in refs if r.startswith("C"))
            assert len(caps) == 1, (
                f"DEBOUNCE: {name} has {caps} on it, expected exactly one cap")
            out[caps[0]] = (fsw_x(i), CAP_Y, 0)
            break
    assert len(out) == 10, f"DEBOUNCE: paired {len(out)} caps to switches, expected 10"
    return out


def _selftest():
    """Flip each layout gate and fail unless it bites. Same contract as
    console_board.py --selftest: a gate nobody has ever seen fail is a comment."""
    import copy
    saved = copy.deepcopy(PLACEMENT)
    # Each control names the gate it is meant to prove. A control that trips some
    # OTHER gate proves nothing about its own, and two of these silently did exactly
    # that after the floorplan moved -- so the expected message is checked, not read.
    cases = [
        ("ring series resistor stranded", "HOP:", {"R1": (60.0, 91.0, 0)}),
        ("part pushed off the outline", "outside the", {"J2": (112.0, 40.0, 0)}),
        # Move a NON-isolated part up against the opto rather than moving the opto:
        # displacing U2 also displaces the anchors of its own passives, and the
        # placer then fails before the isolation gate is ever reached.
        ("opto barrier inside ISOLATION_GAP", "ISOLATION:", {"R7": (30.0, 28.0, 0)}),
        # the exact mistake that was shipped: the 5 V inlet parked in front of USB
        ("part blocking the USB corridor", "USB_CLEAR:", {"J3": (10.0, 46.0, 90)}),
        ("footswitch fan-out out of order", "CROSSING:",
         {"J10": (FSW_X1, FSW_Y, 0), "J19": (FSW_X0, FSW_Y, 0)}),
    ]
    ok = True
    for name, want, mutate in cases:
        PLACEMENT.clear(); PLACEMENT.update(saved); PLACEMENT.update(mutate)
        try:
            build(quiet=True)
            print("  NO BITE    %s  <-- gate is dead" % name)
            ok = False
        except (AssertionError, SystemExit) as exc:
            msg = str(exc).replace("\n", " ")
            if want in msg:
                print("  bites      %-38s %s" % (name, msg[:52]))
            else:
                print("  WRONG GATE %-38s wanted %s, got: %s" % (name, want, msg[:40]))
                ok = False
    PLACEMENT.clear(); PLACEMENT.update(saved)
    return ok


def build(quiet=False):
    comps, nets = parse_netlist(NETLIST)
    board = pcbnew.BOARD()

    ds = board.GetDesignSettings()
    ds.SetCopperLayerCount(2)
    # 0.1in headers leave less mask web than KiCad's 0.25 mm default wants, which
    # is ~100 "solder_mask_bridge" errors on a board that is mostly headers. Every
    # fab bridges these; JLCPCB's own rule is 0.25 mm only for fine-pitch SMD.
    # Setting it to 0 stops the rule hiding the violations that actually matter.
    try:
        ds.m_SolderMaskMinWidth = 0
    except Exception:
        pass

    netmap = {}
    for name in sorted(nets):
        ni = pcbnew.NETINFO_ITEM(board, name)
        board.Add(ni)
        netmap[name] = ni

    fps = {}
    for ref, (lib, name, _val) in sorted(comps.items()):
        if ref in PLACEMENT:
            x, y, rot = PLACEMENT[ref]
            fps[ref] = _load_fp(board, lib, name, ref, x, y, rot)

    for ref, (x, y, rot) in _debounce_caps(nets).items():
        lib, name, _v = comps[ref]
        fps[ref] = _load_fp(board, lib, name, ref, x, y, rot)

    # Mounting holes go in BEFORE the occupancy list is built, or the auto-placer
    # cannot see them and drops a passive straight onto one (R5 landed on H2).
    fps.update(_mounting_holes(board))

    # everything else follows the netlist
    boxes = [_bbox_mm(fp) for fp in fps.values()]
    net_of = {}
    for nname, nodes in nets.items():
        for r, _pad in nodes:
            net_of.setdefault(r, set()).add(nname)
    for ref, (lib, name, _val) in sorted(comps.items()):
        if ref in fps:
            continue
        fp = _load_fp(board, lib, name, ref, 0.0, 0.0, 0, by_centre=False)
        w, h = _fp_size_mm(fp)
        off = _centre(fp)                # origin -> extent-centre offset
        anchor = _best_anchor(ref, net_of, fps, nets)
        pos = _free_slot(anchor, w, h, boxes)
        if pos is None:
            raise SystemExit(f"PLACE: no free slot for {ref} near {anchor}")
        fp.SetPosition(P(pos[0] - off[0], pos[1] - off[1]))
        boxes.append(_bbox_mm(fp))
        fps[ref] = fp

    # attach nets to pads
    for name, nodes in nets.items():
        for ref, pad in nodes:
            if ref not in fps:
                continue
            for p in fps[ref].Pads():
                if p.GetNumber() == str(pad):
                    p.SetNet(netmap[name])

    _outline(board)

    # _silk() takes the text CENTRE, not its left edge -- the title was at x 6,
    # i.e. hanging 10 mm off the left of the board, and at y 86 on an 82 mm board.
    # It has never actually been printable. Gated below now.
    _labels(board, fps)
    _silk(board, "SEGNO CONSOLE v2  #747", 30.0, 93.0, 1.6)
    _silk(board, "MIDI IN: ISOLATED", 90.0, 93.0, 1.0)

    if quiet:
        global _QUIET
        _QUIET = True
        try:
            _check(fps, nets, board)
        finally:
            _QUIET = False
        return
    print("Layout assertions ...", end=" ")
    _check(fps, nets, board)
    print("ALL PASS")
    # No straight-line routing any more. It produced 37 crossings and 22 shorts:
    # pad-to-pad lines cannot dodge obstacles. The board is exported to Specctra
    # DSN and routed by Freerouting (see route_console_board.sh), per the repo's
    # pcb-layout skill. Placement quality is what makes that autoroute good --
    # "better placement in, cleaner autoroute out" -- which is why the ordering
    # and isolation gates above matter more now, not less.
    n_tracks = 0
    n_vias = _stitch_gnd(board, fps, nets, netmap)
    n_vias += _stitch_grid(board, netmap[POUR_NET], fps)
    # Poured on BOTH layers, not just B.Cu. With one pour, B.Cu routing chopped the
    # plane into pieces and three islands were left with no path back to the main
    # body -- DRC reported them as unconnected, which they were. A second pour on
    # F.Cu gives every island a route home through the stitching grid that is
    # already there, and it is what the layout guidance asks for anyway: a
    # continuous low-impedance return directly beneath each signal.
    zone = _pour_gnd(board, netmap[POUR_NET], pcbnew.B_Cu)
    _pour_gnd(board, netmap[POUR_NET], pcbnew.F_Cu)


    # NOT pcbnew.ZONE_FILLER here: in-process it segfaults with no wxApp. The
    # LED-strip generator hit the same wall and fills via kicad-cli instead --
    # `pcb drc --refill-zones --save-board` pours and checks in one pass.
    os.makedirs(OUT, exist_ok=True)
    board.Save(BOARD_PATH)
    print(f"placed {len(fps)} footprints | {n_tracks} tracks | {n_vias} GND vias"
          f" | 2 GND pours (filled by kicad-cli)")
    return board


def export():
    # DRC first: it is what pours the zone (--refill-zones --save-board), so
    # plotting before it would ship gerbers with an empty ground plane.
    drc = subprocess.run([KICAD_CLI, "pcb", "drc", "--refill-zones", "--save-board",
                          "--severity-error", "--exit-code-violations", BOARD_PATH],
                         capture_output=True, text=True)
    tail = [ln for ln in drc.stdout.splitlines() if ln.strip()][-4:]
    print("DRC:", " | ".join(tail) if tail else "(clean)")

    gerber_dir = os.path.join(OUT, "gerbers")
    shutil.rmtree(gerber_dir, ignore_errors=True)
    os.makedirs(gerber_dir)
    subprocess.run([KICAD_CLI, "pcb", "export", "gerbers",
                    "--no-protel-ext", "-o", gerber_dir + "/", BOARD_PATH],
                   check=True, capture_output=True)
    subprocess.run([KICAD_CLI, "pcb", "export", "drill",
                    "--format", "excellon", "--excellon-separate-th",
                    "-o", gerber_dir + "/", BOARD_PATH],
                   check=True, capture_output=True)
    zip_base = os.path.join(OUT, "segno_console_board_gerbers")
    shutil.make_archive(zip_base, "zip", gerber_dir)
    print(f"wrote {zip_base}.zip")

    return drc.returncode


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        print("Negative controls:")
        sys.exit(0 if _selftest() else 1)
    build()
    if "--no-export" not in sys.argv:
        sys.exit(export())
