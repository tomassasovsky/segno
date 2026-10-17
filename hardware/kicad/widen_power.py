#!/usr/bin/env python3
"""Grow a routed power net to the widest track the finished layout will take.

WHY THIS EXISTS, AND WHY IT IS NOT A NETCLASS WIDTH
---------------------------------------------------
Both routing scripts hand Freerouting a width per class and take back whatever
it routes. Raising that width does not widen the same board -- it poses the
router a different problem and it comes back with a different route. That is the
whole content of route_ring_board.sh's old "0.55 is a CEILING, not a preference:
0.65 and 0.80 each leave a clearance violation": at 0.65 the ROUTER's answer had
a violation in it. The board itself had room the whole time. Measured on the
committed routes, +5V_LED on the ring board clears 0.762 mm and +5V on the
console board clears 0.803 mm, against 0.55 and 0.60 as routed.

The room comes from the DSN clearance both scripts deliberately inflate. They
route at 0.3 mm and check at 0.2 mm, for the rounding headroom Freerouting eats;
what the router does not eat is 0.1 mm per side, which is 0.2 mm of track width
sitting unused on every power segment on the board.

So this runs AFTER the session import, on the geometry that was actually routed
and is about to be DRC'd, and takes that headroom back. The route is untouched:
same segments, same endpoints, same layers, same vias. Only (width ...) changes.

It must run BEFORE the zone refill. A wider track needs the pour to retreat from
it, and the pour only retreats when it is refilled.

CLEARANCE IS MEASURED, NOT ASSUMED. Every power segment is checked against every
foreign-net item that shares its layer -- tracks, pads, vias -- and against the
board outline. Zones are skipped on purpose: they refill around whatever this
leaves behind.

PADS ARE MEASURED AS THE SHAPES THEY ARE. The first version of this took every
pad as a circle of its largest dimension, on the reasoning that overstating a
pad can only make the answer safer. Safer, and useless: the console board has 42
pads at 3.2 x 1.6 mm, and a circle of r=1.6 around a pad that is 0.8 mm tall
invents 0.8 mm of obstruction on its long sides. The console came back claiming
0.246 mm of allowed width where the real figure is 0.803 -- so the widening did
nothing, and the width gate then failed the fab step over it. A conservative
model that always says no is not conservative, it is broken.

So: rect, roundrect and trapezoid are measured as their bounding box (a superset
of the last two, so still safe), oval as a stadium, circle as a circle, and
anything else -- custom pads, of which this board has ten -- as a bounding circle
big enough to contain its primitives. Pad ORIENTATION is read too, which the
first version also dropped: 183 of this board's pads carry one. It is absolute in
the board file, not relative to the footprint, which two instances of
R_Axial_DIN0207 at 0 and 90 degrees settle: the pad angles follow the footprint
while the pad POSITIONS stay in the footprint's own unrotated frame.

The model is still not KiCad's, and it does not have to be, because it is not the
gate. Every approximation left in it points the same way -- it can refuse width
that was in fact available, never grant width that is not. The gate is the DRC
both scripts already run afterwards, on the widened copper, at full severity.

NOT pcbnew, which is what the rest of this pipeline uses. The edit is one token
per segment on a file that is already being rewritten by regex two steps earlier
(route_ring_board.sh patches the DSN the same way), and both scripts already
shell out to plain python3 for the work that is data rather than board surgery.
The deciding reason is that this has to be testable without a KiCad install --
see --selftest, which is the only part of either routing script that can run in
CI or on a machine that is not the one Mac with KiCad on it.

The result is one minimum width for the net, limited by available clearance.
Existing wider hand-routed branches stay wide: the 40-pixel feed must not be
shrunk to the width of the lower-current module and logic branches. The ceiling
is printed so a pinched segment holding the remaining tracks back is visible.

    python3 widen_power.py BOARD.kicad_pcb --net +5V_LED --target 0.65
    python3 widen_power.py --selftest
"""

import argparse
import math
import re
import sys

# IPC-2221B external conductor: I = k * dT^0.44 * A^0.725, A in mil^2, k = 0.048.
# Both boards are 1 oz outer copper (board_stackup.py: 0.035 mm), which is
# 1.378 mil. IPC-2152 would allow more -- it is the newer, measurement-based
# standard and it credits the ground pour either side as a heat spreader -- but
# 2221 is the conservative one and it is the one this repo now quotes everywhere.
IPC_K_EXTERNAL = 0.048
MIL_PER_MM = 1.0 / 0.0254
OZ_MIL = 1.378


def ampacity(width_mm, delta_t=10.0, oz=1.0):
    """IPC-2221B current for an external trace, amps."""
    area = width_mm * MIL_PER_MM * OZ_MIL * oz
    return IPC_K_EXTERNAL * (delta_t ** 0.44) * (area ** 0.725)


# ---------------------------------------------------------------------------
# s-expression scanning. The board is read as text rather than through pcbnew
# because this has to run in CI and on a machine without a KiCad install, and
# because the edit is one token per segment -- pcbnew would be a heavier
# dependency for a narrower result.
# ---------------------------------------------------------------------------

def _blocks(text, tag):
    """Yield (start, end) of every balanced (tag ...) block in text."""
    for m in re.finditer(r'\(' + re.escape(tag) + r'[\s\n]', text):
        i = m.start()
        depth = 0
        for j in range(i, len(text)):
            if text[j] == '(':
                depth += 1
            elif text[j] == ')':
                depth -= 1
                if depth == 0:
                    yield i, j + 1
                    break


def _net_of(block):
    m = re.search(r'\(net "([^"]*)"\)', block)
    return m.group(1) if m else None


def _rotate(x, y, angle_deg):
    """KiCad board frame: +angle is counter-clockwise on screen, and screen Y
    points down, so the matrix turns the other way."""
    a = math.radians(-angle_deg)
    ca, sa = math.cos(a), math.sin(a)
    return x * ca - y * sa, x * sa + y * ca


def _unrotate(x, y, angle_deg):
    a = math.radians(-angle_deg)
    ca, sa = math.cos(a), math.sin(a)
    return x * ca + y * sa, -x * sa + y * ca


def _point_to_box(p, hw, hh):
    return math.hypot(max(0.0, abs(p[0]) - hw), max(0.0, abs(p[1]) - hh))


def _ccw(a, b, c):
    return (c[1] - a[1]) * (b[0] - a[0]) - (b[1] - a[1]) * (c[0] - a[0])


def _crosses(a, b, c, d):
    return (_ccw(a, c, d) > 0) != (_ccw(b, c, d) > 0) and \
           (_ccw(a, b, c) > 0) != (_ccw(a, b, d) > 0)


def _seg_to_box(a, b, hw, hh):
    """Distance from segment a-b to the axis-aligned box +/-hw, +/-hh. 0 if they
    touch or overlap. Both shapes are convex, so the closest pair is a vertex of
    one against the other -- which is what the two loops below cover."""
    if (abs(a[0]) <= hw and abs(a[1]) <= hh) or (abs(b[0]) <= hw and abs(b[1]) <= hh):
        return 0.0
    corners = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
    for i in range(4):
        if _crosses(a, b, corners[i], corners[(i + 1) % 4]):
            return 0.0
    d = min(_point_to_box(a, hw, hh), _point_to_box(b, hw, hh))
    for c in corners:
        d = min(d, _point_to_seg(c, a, b))
    return d


def _point_to_seg(p, a, b):
    (px, py), (ax, ay), (bx, by) = p, a, b
    dx, dy = bx - ax, by - ay
    span = dx * dx + dy * dy
    t = 0.0 if span == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / span))
    return math.dist(p, (ax + t * dx, ay + t * dy))


def _seg_to_seg(a, b, c, d):
    return min(_point_to_seg(a, c, d), _point_to_seg(b, c, d),
               _point_to_seg(c, a, b), _point_to_seg(d, a, b))


def _sample_arc(p1, pm, p2, n=24):
    """Points along the arc through p1, pm, p2. Falls back to the two chords when
    the three points are collinear and there is no circle to find."""
    (x1, y1), (xm, ym), (x2, y2) = p1, pm, p2
    d = 2 * (x1 * (ym - y2) + xm * (y2 - y1) + x2 * (y1 - ym))
    if abs(d) < 1e-9:
        return [p1, pm, p2]
    ux = ((x1 ** 2 + y1 ** 2) * (ym - y2) + (xm ** 2 + ym ** 2) * (y2 - y1)
          + (x2 ** 2 + y2 ** 2) * (y1 - ym)) / d
    uy = ((x1 ** 2 + y1 ** 2) * (x2 - xm) + (xm ** 2 + ym ** 2) * (x1 - x2)
          + (x2 ** 2 + y2 ** 2) * (xm - x1)) / d
    r = math.hypot(x1 - ux, y1 - uy)
    a1 = math.atan2(y1 - uy, x1 - ux)
    am = math.atan2(ym - uy, xm - ux)
    a2 = math.atan2(y2 - uy, x2 - ux)
    # Go the way round that passes through the midpoint.
    sweep = (a2 - a1) % (2 * math.pi)
    if not (0 <= (am - a1) % (2 * math.pi) <= sweep):
        sweep -= 2 * math.pi
    return [(ux + r * math.cos(a1 + sweep * k / n),
             uy + r * math.sin(a1 + sweep * k / n)) for k in range(n + 1)]


class Pad:
    """A pad as the shape it is, in the board frame. `kind` is 'box' (rect and
    the shapes a box contains), 'stadium' (oval) or 'disc' (circle, and the
    bounding circle anything unrecognised falls back to)."""

    def __init__(self, net, layers, cx, cy, rot, kind, hw, hh, r=0.0):
        self.net, self.layers = net, layers
        self.cx, self.cy, self.rot = cx, cy, rot
        self.kind, self.hw, self.hh, self.r = kind, hw, hh, r

    def distance(self, a, b):
        """Shortest distance from the pad's copper to segment a-b, never below 0."""
        if self.kind == 'disc':
            return max(0.0, _point_to_seg((self.cx, self.cy), a, b) - self.r)
        la = _unrotate(a[0] - self.cx, a[1] - self.cy, self.rot)
        lb = _unrotate(b[0] - self.cx, b[1] - self.cy, self.rot)
        return max(0.0, _seg_to_box(la, lb, self.hw, self.hh) - self.r)


def _pad_shape(net, layers, cx, cy, rot, shape, sx, sy, block):
    hw, hh = sx / 2, sy / 2
    if shape == 'circle':
        return Pad(net, layers, cx, cy, rot, 'disc', 0, 0, r=max(hw, hh))
    if shape == 'oval':
        # A stadium: a box shrunk by the end radius, then inflated by it again.
        r = min(hw, hh)
        return Pad(net, layers, cx, cy, rot, 'stadium', hw - r, hh - r, r=r)
    if shape in ('rect', 'roundrect', 'trapezoid'):
        # The box CONTAINS a roundrect and a trapezoid, so using it for those is
        # the safe direction.
        return Pad(net, layers, cx, cy, rot, 'box', hw, hh)
    # Custom, or a shape a later KiCad invents. Its primitives can reach past
    # (size), so the fallback circle has to reach past it too.
    reach = max(hw, hh)
    for prim in ('gr_poly', 'gr_line', 'gr_circle', 'gr_arc', 'gr_rect'):
        for i, j in _blocks(block, prim):
            body = block[i:j]
            wid = re.search(r'\(width ([\d.]+)\)', body)
            pad_w = float(wid.group(1)) / 2 if wid else 0.0
            for x, y in re.findall(r'\(xy ([-\d.]+) ([-\d.]+)\)', body):
                reach = max(reach, math.hypot(float(x), float(y)) + pad_w)
            for x, y in re.findall(r'\((?:start|mid|end|center) ([-\d.]+) ([-\d.]+)\)', body):
                reach = max(reach, math.hypot(float(x), float(y)) + pad_w)
    return Pad(net, layers, cx, cy, rot, 'disc', 0, 0, r=reach)


class Board:
    def __init__(self, text):
        self.text = text
        self.segments = []   # (start, end, net, layer, x1, y1, x2, y2, width)
        self.pads = []       # Pad
        self.vias = []       # (net, cx, cy, radius)
        self.outline = []    # (x1, y1, x2, y2)
        self._scan()

    def _scan(self):
        t = self.text
        for i, j in _blocks(t, 'segment'):
            blk = t[i:j]
            st = re.search(r'\(start ([-\d.]+) ([-\d.]+)\)', blk)
            en = re.search(r'\(end ([-\d.]+) ([-\d.]+)\)', blk)
            w = re.search(r'\(width ([\d.]+)\)', blk)
            ly = re.search(r'\(layer "([^"]+)"\)', blk)
            if not (st and en and w and ly):
                continue
            self.segments.append((i, j, _net_of(blk), ly.group(1),
                                  float(st.group(1)), float(st.group(2)),
                                  float(en.group(1)), float(en.group(2)),
                                  float(w.group(1))))
        for fi, fj in _blocks(t, 'footprint'):
            fp = t[fi:fj]
            at = re.search(r'\(at ([-\d.]+) ([-\d.]+)(?: ([-\d.]+))?\)', fp)
            if not at:
                continue
            fx, fy = float(at.group(1)), float(at.group(2))
            frot = float(at.group(3) or 0)
            for pi, pj in _blocks(fp, 'pad'):
                pad = fp[pi:pj]
                head = re.match(r'\(pad "([^"]*)"\s+(\S+)\s+(\S+)', pad)
                pa = re.search(r'\(at ([-\d.]+) ([-\d.]+)(?: ([-\d.]+))?\)', pad)
                sz = re.search(r'\(size ([\d.]+) ([\d.]+)\)', pad)
                if not (head and pa and sz):
                    continue
                # Position is in the footprint's own UNROTATED frame; the pad's
                # own angle is already absolute. Two R_Axial_DIN0207 at 0 and 90
                # degrees settle it: same pad positions, pad angle follows the
                # footprint.
                dx, dy = _rotate(float(pa.group(1)), float(pa.group(2)), frot)
                prot = float(pa.group(3) or 0)
                layers = set()
                for lay in re.findall(r'"([*FB]\.Cu)"', pad):
                    layers |= {'F.Cu', 'B.Cu'} if lay == '*.Cu' else {lay}
                self.pads.append(_pad_shape(_net_of(pad), layers, fx + dx, fy + dy,
                                            prot, head.group(3),
                                            float(sz.group(1)), float(sz.group(2)),
                                            pad))
        for i, j in _blocks(t, 'via'):
            blk = t[i:j]
            at = re.search(r'\(at ([-\d.]+) ([-\d.]+)\)', blk)
            sz = re.search(r'\(size ([\d.]+)\)', blk)
            if at and sz:
                self.vias.append((_net_of(blk), float(at.group(1)), float(at.group(2)),
                                  float(sz.group(1)) / 2))
        for tag in ('gr_line', 'gr_arc'):
            for i, j in _blocks(t, tag):
                blk = t[i:j]
                if 'Edge.Cuts' not in blk:
                    continue
                pts = [(float(a), float(b)) for a, b in
                       re.findall(r'\((?:start|mid|end) ([-\d.]+) ([-\d.]+)\)', blk)]
                if tag == 'gr_arc' and len(pts) == 3:
                    # Two chords through the midpoint cut the corner off a big
                    # arc, and the ring board's whole outline is arcs. Sample it.
                    pts = _sample_arc(*pts, n=24)
                for k in range(len(pts) - 1):
                    self.outline.append((*pts[k], *pts[k + 1]))

    def headroom(self, net, edge_bias=0.0):
        """Widest uniform width for `net`, per segment: [(gap, allowed, ...)]."""
        out = []
        for (_i, _j, n, layer, x1, y1, x2, y2, w) in self.segments:
            if n != net:
                continue
            a, b = (x1, y1), (x2, y2)
            mid = ((x1 + x2) / 2, (y1 + y2) / 2)
            gap, who = float('inf'), ('none', '-', mid)
            for (_a, _b, n2, l2, p1, q1, p2, q2, w2) in self.segments:
                if n2 == net or l2 != layer:
                    continue
                d = _seg_to_seg(a, b, (p1, q1), (p2, q2)) - w / 2 - w2 / 2
                if d < gap:
                    gap, who = d, ('track', n2, mid)
            for pad in self.pads:
                if pad.net == net or layer not in pad.layers:
                    continue
                d = pad.distance(a, b) - w / 2
                if d < gap:
                    gap, who = d, ('pad', pad.net or 'no-net', (pad.cx, pad.cy))
            for (n2, cx, cy, r) in self.vias:
                if n2 == net:
                    continue
                d = _point_to_seg((cx, cy), a, b) - w / 2 - r
                if d < gap:
                    gap, who = d, ('via', n2 or 'no-net', (cx, cy))
            for (p1, q1, p2, q2) in self.outline:
                # Scored against the EDGE rule, not the copper one: both boards
                # set min_copper_edge_clearance to 0.5 against a 0.2 mm track
                # clearance, and charging the edge only 0.2 would hand back width
                # that DRC then refuses. edge_bias converts it to the same scale
                # as the copper gaps so one min() can rank them together.
                d = _seg_to_seg(a, b, (p1, q1), (p2, q2)) - w / 2 - edge_bias
                if d < gap:
                    gap, who = d, ('edge', 'board outline', mid)
            out.append((gap, w, who, layer, math.dist(a, b)))
        return out

    def set_width(self, net, width):
        """Grow narrower segments of `net`, preserving wider power branches."""
        edits = []
        for (i, j, n, _layer, *_rest) in self.segments:
            if n == net and _rest[-1] < width:
                edits.append((i, j))
        if not edits:
            return 0
        # Back to front, so earlier offsets stay valid.
        for i, j in sorted(edits, reverse=True):
            blk = self.text[i:j]
            new = re.sub(r'\(width [\d.]+\)', '(width %s)' % _fmt(width), blk, count=1)
            self.text = self.text[:i] + new + self.text[j:]
        return len(edits)


def _fmt(mm):
    return ('%.6f' % mm).rstrip('0').rstrip('.')


def widen(path, net, target, min_clearance, guard, edge_clearance, dry_run, explain):
    board = Board(open(path).read())
    rows = board.headroom(net, edge_bias=max(0.0, edge_clearance - min_clearance))
    if not rows:
        sys.exit("no routed segments on net %s -- run this AFTER the session import" % net)

    routed = min(w for _gap, w, _who, _l, _len in rows)
    required = min_clearance + guard
    allowed = min(2 * ((gap + w / 2) - required) for gap, w, _who, _l, _len in rows)
    chosen = min(target, allowed)

    print("   %s: %d segments routed at %.2f mm" % (net, len(rows), routed))
    print("   layout allows %.3f mm (keeping %.2f mm: the %.2f mm rule plus %.2f mm of guard;"
          " board edge %.2f mm)" % (allowed, required, min_clearance, guard, edge_clearance))

    # Whenever the target is missed, say WHAT stopped it. A bare "no headroom" is
    # the one output nobody can act on, and this measures a route it has never
    # seen -- if the answer looks wrong, this list is the evidence for saying so.
    if chosen < target or explain:
        print("   what is holding it, tightest first:")
        for gap, w, who, layer, length in sorted(rows)[:explain or 5]:
            print("      %6.3f mm to %-22s %-5s  seg %5.1f mm at (%.2f, %.2f) -> allows %.3f"
                  % (gap, who[0], who[1], length, who[2][0], who[2][1],
                     2 * ((gap + w / 2) - required)))

    if chosen <= routed:
        print("   no headroom above the routed width -- left alone")
        return 0
    print("   -> %.2f mm, %.2f A at a 10 C rise (IPC-2221, 1 oz external), was %.2f A"
          % (chosen, ampacity(chosen), ampacity(routed)))
    if dry_run:
        print("   (dry run: nothing written)")
        return 0
    n = board.set_width(net, chosen)
    open(path, 'w').write(board.text)
    print("   widened %d segments -- REFILL ZONES before DRC" % n)
    return n


# ---------------------------------------------------------------------------
# Selftest. Every control here has to bite on a board built to defeat it; a
# widener that silently does nothing is the failure mode that ships.
# ---------------------------------------------------------------------------

_STUB = '''(kicad_pcb
\t(segment
\t\t(start 0 0)
\t\t(end 10 0)
\t\t(width 0.55)
\t\t(layer "F.Cu")
\t\t(net "+5V_LED")
\t)
\t(segment
\t\t(start 0 %(y)s)
\t\t(end 10 %(y)s)
\t\t(width 0.30)
\t\t(layer "%(layer)s")
\t\t(net "RING_DATA")
\t)
)
'''


def selftest():
    import tempfile
    import os
    failures = []

    def case(name, text, expect_allowed=None, expect_width=None, target=0.65,
             expect_widths=None):
        fd, p = tempfile.mkstemp(suffix='.kicad_pcb')
        os.write(fd, text.encode())
        os.close(fd)
        try:
            b = Board(open(p).read())
            rows = b.headroom('+5V_LED', edge_bias=0.3)
            allowed = min(2 * ((g + w / 2) - 0.25) for g, w, _o, _l, _n in rows)
            if expect_allowed is not None and abs(allowed - expect_allowed) > 1e-6:
                failures.append("%s: allowed %.4f, expected %.4f" % (name, allowed, expect_allowed))
            if expect_width is not None or expect_widths is not None:
                import contextlib, io
                with contextlib.redirect_stdout(io.StringIO()):
                    widen(p, '+5V_LED', target, 0.2, 0.05, 0.5, False, 0)
                got = float(re.search(r'\(width ([\d.]+)\)', open(p).read()).group(1))
                if expect_width is not None and abs(got - expect_width) > 1e-6:
                    failures.append("%s: wrote %.4f, expected %.4f" % (name, got, expect_width))
                if expect_widths is not None:
                    widths = sorted({row[-1] for row in Board(open(p).read()).segments
                                     if row[2] == '+5V_LED'})
                    if widths != expect_widths:
                        failures.append("%s: widths %r, expected %r" % (name, widths, expect_widths))
        finally:
            os.unlink(p)

    # A neighbour 1.0 mm away on the SAME layer: edge-to-edge gap is
    # 1.0 - 0.275 - 0.15 = 0.575, so the centreline has 0.575 + 0.275 = 0.850 of
    # half-space and 0.25 must stay -- 2 * 0.600 = 1.200 mm allowed. Target wins.
    case('same layer, roomy', _STUB % {'y': 1.0, 'layer': 'F.Cu'},
         expect_allowed=1.2, expect_width=0.65)
    mixed = (_STUB % {'y': 1.0, 'layer': 'F.Cu'}).rstrip()[:-1] + '''
    (segment (start 0 10) (end 10 10) (width 1.5)
        (layer "F.Cu") (net "+5V_LED"))
    )'''
    case('preserve hand-routed high-current branch', mixed,
         expect_width=0.65, expect_widths=[0.65, 1.5])

    # Same neighbour on the OTHER layer cannot constrain anything.
    case('other layer ignored', _STUB % {'y': 1.0, 'layer': 'B.Cu'},
         expect_allowed=float('inf'))

    # Pull the neighbour in to 0.55 mm: gap 0.125, half-space 0.400, allowed
    # 2 * 0.150 = 0.300 -- BELOW the routed 0.55, so the width must not change.
    case('too tight to grow', _STUB % {'y': 0.55, 'layer': 'F.Cu'},
         expect_allowed=0.3, expect_width=0.55)

    # The ceiling, not the target, decides when the ceiling is lower. Neighbour
    # at 0.8: gap 0.375, half-space 0.650, allowed 2 * 0.400 = 0.800.
    case('ceiling below target', _STUB % {'y': 0.8, 'layer': 'F.Cu'},
         expect_allowed=0.8, expect_width=0.65)
    case('ceiling caps target', _STUB % {'y': 0.8, 'layer': 'F.Cu'},
         expect_width=0.8, target=1.5)

    # A foreign PAD constrains, and it is measured as the shape it is. A
    # 2.0 x 0.5 rect centred 1.5 mm off the track reaches to y=1.25, so the gap
    # is 1.5 - 0.25 - 0.275 = 0.975, half-space 1.250, allowed 2 * 1.000 = 2.000.
    # The circle model this replaced took r=1.0 and answered 0.500 -- it invented
    # 0.75 mm of pad that is not there, which is the whole bug it caused.
    def pad_board(shape='rect', size='2.0 0.5', at='0 1.5'):
        return '''(kicad_pcb
\t(segment
\t\t(start 0 0)
\t\t(end 10 0)
\t\t(width 0.55)
\t\t(layer "F.Cu")
\t\t(net "+5V_LED")
\t)
\t(footprint "x"
\t\t(at 5 0 %(frot)s)
\t\t(pad "1" smd %(shape)s
\t\t\t(at %(at)s)
\t\t\t(size %(size)s)
\t\t\t(layers "F.Cu")
\t\t\t(net "GND")
\t\t)
\t)
)
''' % {'shape': shape, 'size': size, 'at': at, 'frot': 0}

    case('rect pad measured as a rect', pad_board(), expect_allowed=2.0)
    # Same pad turned 90 degrees now points its 2.0 mm axis AT the track and
    # reaches to y=0.5: gap 1.5 - 1.0 - 0.275 = 0.225, allowed 2 * 0.250 = 0.500.
    case('pad orientation is read', pad_board(at='0 1.5 90'), expect_allowed=0.5)
    # A roundrect is measured as the box that contains it -- same answer as the
    # rect, never a looser one.
    case('roundrect takes the box', pad_board(shape='roundrect'), expect_allowed=2.0)
    # An oval is a stadium: 2.0 x 0.5 reaches to y=0.25 exactly as the rect does.
    case('oval as a stadium', pad_board(shape='oval'), expect_allowed=2.0)
    # A circle has no orientation and uses its radius: r=1.0, gap
    # 1.5 - 1.0 - 0.275 = 0.225, allowed 0.500.
    case('circle pad uses its radius', pad_board(shape='circle', size='2.0 2.0'),
         expect_allowed=0.5)

    # The board OUTLINE is charged the edge rule (0.5), not the copper rule, so
    # an edge 1.5 mm off the centreline leaves 1.5 - 0.275 = 1.225 of gap, minus
    # the 0.3 bias = 0.925, allowed 2 * (0.925 + 0.275 - 0.25) = 1.900.
    edge_board = '''(kicad_pcb
\t(segment
\t\t(start 0 0)
\t\t(end 10 0)
\t\t(width 0.55)
\t\t(layer "F.Cu")
\t\t(net "+5V_LED")
\t)
\t(gr_line
\t\t(start -5 1.5)
\t\t(end 15 1.5)
\t\t(layer "Edge.Cuts")
\t)
)
'''
    case('board edge charged the edge rule', edge_board, expect_allowed=1.9)

    # IPC-2221 arithmetic, against the numbers quoted in the scripts.
    for w, amps in ((0.50, 1.45), (0.55, 1.55), (0.60, 1.65), (0.65, 1.75), (0.70, 1.85)):
        got = ampacity(w)
        if abs(got - amps) > 0.01:
            failures.append("ampacity(%.2f) = %.3f, expected ~%.2f" % (w, got, amps))

    for f in failures:
        print("FAIL  " + f)
    print("selftest: %d checks failed" % len(failures))
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('board', nargs='?')
    ap.add_argument('--net', help='power net to widen, e.g. +5V_LED')
    ap.add_argument('--target', type=float, help='width to grow to, mm')
    ap.add_argument('--min-clearance', type=float, default=0.2,
                    help="the board's own clearance rule, mm (default 0.2)")
    ap.add_argument('--guard', type=float, default=0.05,
                    help='extra clearance kept on top of the rule, mm (default 0.05)')
    ap.add_argument('--edge-clearance', type=float, default=0.5,
                    help="the board's copper-to-edge rule, mm (default 0.5)")
    ap.add_argument('--explain', type=int, nargs='?', const=12, default=0,
                    metavar='N', help='list the N tightest constraints (default 12); '
                                      'the list is printed anyway when the target is missed')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not (a.board and a.net and a.target):
        ap.error('board, --net and --target are required')
    widen(a.board, a.net, a.target, a.min_clearance, a.guard, a.edge_clearance,
          a.dry_run, a.explain)
    return 0


if __name__ == '__main__':
    sys.exit(main())
