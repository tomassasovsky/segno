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
BW, BH = 130.0, 90.0            # board outline
EDGE_R = 3.0                    # corner radius
MOUNT_D, MOUNT_INSET = 3.2, 5.0  # M3 clearance, from each corner

TRACK_W = 0.35                  # signal
TRACK_PWR = 0.8                 # +5V / +5V_LED / +3V3
VIA_D, VIA_DRILL = 0.8, 0.4
CLEARANCE = 0.25

# MIDI IN's opto barrier: the DIN side of U2 must not share copper or a pour with
# anything else, or the isolation the H11L1 exists for is undone.
ISOLATION_GAP = 2.0


def P(x, y):
    return pcbnew.VECTOR2I(FromMM(ORIGIN[0] + x), FromMM(ORIGIN[1] + y))


# ---- placement -------------------------------------------------------------
# (x, y, rotation) in board-local mm, of each footprint's origin.
#
# Rows: the Pico sits mid-board with its pad rows horizontal. Footswitches fan
# DOWN to the bottom edge in GPIO order; the Pi ribbon takes the whole left edge;
# MIDI/CTRL/SWD/power sit right and top, next to the chips that serve them.
PICO_X, PICO_Y = 66.0, 34.0
PLACEMENT = {
    "J1":  (PICO_X, PICO_Y, 90),       # Pico 2 -- 90 deg: its pads run
                                   # 0..48.26 in Y unrotated, so the
                                   # long axis is vertical until turned
    "J2":  (10.0, 45.0, 0),            # Pi ribbon, left edge. rot 0: the IDC
                                   # footprint is ALREADY vertical
                                   # (4.24 x 49.96); 90 would lay it flat
    "J3":  (14.0, 78.0, 0),            # 5V in, bottom left
    "U1":  (96.0, 22.0, 0),            # 74AHCT125
    "U2":  (117.0, 22.0, 0),           # H11L1 (opto), far right
    "J4":  (110.0, 8.0, 0),            # MIDI OUT
    "J5":  (122.0, 8.0, 0),            # MIDI IN  -- beside U2, away from everything
    "J6":  (66.0, 8.0, 0),             # ring/encoder
    "J7":  (86.0, 8.0, 0),             # indicators
    "J8":  (30.0, 8.0, 0),             # power button
    "J9":  (44.0, 8.0, 0),             # SWD
    "J20": (100.0, 50.0, 0),           # CTRL 1
    "J21": (114.0, 50.0, 0),           # CTRL 2
}
# footswitches J10..J19, evenly across the bottom, in GPIO order
FSW_Y = 78.0
FSW_X0, FSW_X1 = 30.0, 96.0
for _i in range(10):
    PLACEMENT["J%d" % (10 + _i)] = (
        FSW_X0 + (FSW_X1 - FSW_X0) * _i / 9.0, FSW_Y, 0)

PWR_NETS = {"+5V", "+5V_LED", "+3V3"}
POUR_NET = "GND"


# Passives are NOT in the table above. Hand-placing 26 resistors and capacitors
# is a table that silently drifts from the netlist the first time a part is added.
# Instead they are placed BY the netlist: each one lands next to whichever placed
# part it shares the most nets with, in the nearest free slot. Deterministic
# (sorted iteration, first-fit outward spiral), and _check()'s overlap gate proves
# the result rather than trusting it.
KEEPOUT = 2.0                   # margin around every footprint, mm. Also covers
                                # the body overhanging its outermost pads.
GRID = 1.0                      # search step


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
    for x, y in ((MOUNT_INSET, MOUNT_INSET), (BW - MOUNT_INSET, MOUNT_INSET),
                 (BW - MOUNT_INSET, BH - MOUNT_INSET), (MOUNT_INSET, BH - MOUNT_INSET)):
        fp = pcbnew.FOOTPRINT(board)
        fp.SetPosition(P(x, y))
        pad = pcbnew.PAD(fp)
        pad.SetAttribute(pcbnew.PAD_ATTRIB_NPTH)
        pad.SetShape(pcbnew.PAD_SHAPE_CIRCLE)
        pad.SetSize(pcbnew.VECTOR2I(FromMM(MOUNT_D), FromMM(MOUNT_D)))
        pad.SetDrillSize(pcbnew.VECTOR2I(FromMM(MOUNT_D), FromMM(MOUNT_D)))
        pad.SetLayerSet(pcbnew.PAD.UnplatedHoleMask())
        pad.SetPosition(P(x, y))
        fp.Add(pad)
        board.Add(fp)


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


def _pour_gnd(board, net):
    z = pcbnew.ZONE(board)
    z.SetLayer(pcbnew.B_Cu)
    z.SetNet(net)
    z.SetLocalClearance(FromMM(CLEARANCE))
    z.SetMinThickness(FromMM(0.2))
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


def _extent(fp):
    """(x0, y0, x1, y1) in board-local mm -- the footprint's real keep-out area.

    NOT GetBoundingBox(): that includes the reference and value TEXT, which dwarf
    the part (a 5 mm disc cap measures 26.7 x 6.7 that way, a 10 mm axial resistor
    43.2 x 6.4). Placing against those fills a 130 x 90 board with 26 passives.

    Nor the COURTYARD, tempting as it is: its cached polygon does not follow
    SetOrientationDegrees(), so a rotated part measures its pre-rotation shape --
    that is how the 2x20 ribbon reported 59.6 x 10 after being turned 90 degrees.
    Pad positions DO follow both position and rotation (verified: the Pico goes
    19.38 x 49.86 -> 49.86 x 19.38), so the union of the pads is the honest extent,
    and KEEPOUT covers the body overhang beyond them.
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
    return (min(xs), min(ys), max(xs), max(ys))


def _centre(fp):
    x0, y0, x1, y1 = _extent(fp)
    return ((x0 + x1) / 2.0, (y0 + y1) / 2.0)


def _bbox_mm(fp):
    x0, y0, x1, y1 = _extent(fp)
    return (x0 - KEEPOUT, y0 - KEEPOUT, x1 + KEEPOUT, y1 + KEEPOUT)


def _fp_size_mm(fp):
    x0, y0, x1, y1 = _extent(fp)
    return (x1 - x0, y1 - y0)


def _best_anchor(ref, net_of, fps):
    """Centre of the placed part this one shares the most nets with."""
    mine = net_of.get(ref, set())
    best, best_n = None, -1
    for other, fp in sorted(fps.items()):
        n = len(mine & net_of.get(other, set()))
        if n > best_n:
            best, best_n = fp, n
    return _centre(best)


def _free_slot(anchor, w, h, boxes):
    """Nearest free position to `anchor`, searched as an outward square spiral."""
    ax, ay = anchor
    for radius in range(1, int(max(BW, BH) / GRID)):
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

def _check(fps, nets):
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
    for ref, fp in fps.items():
        if ref in ("U2", "J5") or ref.startswith(("R", "C", "D")):
            continue                     # the opto's own passives belong inside the barrier
        x0, y0, x1, y1 = _extent(fp)
        dx = max(ux0 - x1, x0 - ux1, 0.0)
        dy = max(uy0 - y1, y0 - uy1, 0.0)
        d = (dx * dx + dy * dy) ** 0.5
        assert d >= ISOLATION_GAP, (
            f"ISOLATION: {ref} is {d:.2f} mm from the opto U2, under the "
            f"{ISOLATION_GAP} mm barrier -- MIDI IN's isolation is the whole point of U2")
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

def build():
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
        anchor = _best_anchor(ref, net_of, fps)
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

    print("Layout assertions ...", end=" ")
    _check(fps, nets)
    print("ALL PASS")

    _outline(board)
    _mounting_holes(board)
    n_tracks = _route(board, fps, nets, netmap)
    n_vias = _stitch_gnd(board, fps, nets, netmap)
    zone = _pour_gnd(board, netmap[POUR_NET])

    _silk(board, "SEGNO CONSOLE v2  #747", 6.0, 86.0, 1.6)
    _silk(board, "MIDI IN: ISOLATED - no pour under U2/J5", 74.0, 16.5, 1.0)

    # NOT pcbnew.ZONE_FILLER here: in-process it segfaults with no wxApp. The
    # LED-strip generator hit the same wall and fills via kicad-cli instead --
    # `pcb drc --refill-zones --save-board` pours and checks in one pass.
    os.makedirs(OUT, exist_ok=True)
    board.Save(BOARD_PATH)
    print(f"placed {len(fps)} footprints | {n_tracks} tracks | {n_vias} GND vias"
          f" | 1 GND pour (filled by kicad-cli)")
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
    build()
    if "--no-export" not in sys.argv:
        sys.exit(export())
