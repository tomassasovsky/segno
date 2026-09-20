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
board outline. Pads are treated as circles of their largest dimension, which
overstates a rectangular pad and so can only make the answer safer. Zones are
skipped on purpose: they refill around whatever this leaves behind.

That model is deliberately cruder than KiCad's, and it is allowed to be, because
it is not the gate. It can only ever refuse width that was in fact available; it
cannot grant width that is not. The gate is the DRC both scripts already run
afterwards, on the widened copper, at full severity.

NOT pcbnew, which is what the rest of this pipeline uses. The edit is one token
per segment on a file that is already being rewritten by regex two steps earlier
(route_ring_board.sh patches the DSN the same way), and both scripts already
shell out to plain python3 for the work that is data rather than board surgery.
The deciding reason is that this has to be testable without a KiCad install --
see --selftest, which is the only part of either routing script that can run in
CI or on a machine that is not the one Mac with KiCad on it.

The result is ONE width for the net, the narrowest the layout allows, because a
series rail is only as good as its tightest section and a rail that changes width
six times is a rail nobody can reason about. The ceiling is printed alongside it,
so a single pinched segment holding the whole net back is visible rather than
silent.

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


def _point_to_seg(p, a, b):
    (px, py), (ax, ay), (bx, by) = p, a, b
    dx, dy = bx - ax, by - ay
    span = dx * dx + dy * dy
    t = 0.0 if span == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / span))
    return math.dist(p, (ax + t * dx, ay + t * dy))


def _seg_to_seg(a, b, c, d):
    return min(_point_to_seg(a, c, d), _point_to_seg(b, c, d),
               _point_to_seg(c, a, b), _point_to_seg(d, a, b))


class Board:
    def __init__(self, text):
        self.text = text
        self.segments = []   # (start, end, net, layer, x1, y1, x2, y2, width)
        self.pads = []       # (net, layers, cx, cy, radius)
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
            rot = math.radians(-float(at.group(3) or 0))
            for pi, pj in _blocks(fp, 'pad'):
                pad = fp[pi:pj]
                pa = re.search(r'\(at ([-\d.]+) ([-\d.]+)', pad)
                sz = re.search(r'\(size ([\d.]+) ([\d.]+)\)', pad)
                if not (pa and sz):
                    continue
                px, py = float(pa.group(1)), float(pa.group(2))
                gx = fx + px * math.cos(rot) - py * math.sin(rot)
                gy = fy + px * math.sin(rot) + py * math.cos(rot)
                layers = set()
                for lay in re.findall(r'"([*FB]\.Cu)"', pad):
                    layers |= {'F.Cu', 'B.Cu'} if lay == '*.Cu' else {lay}
                # Largest half-dimension: a circle that contains the pad.
                self.pads.append((_net_of(pad), layers, gx, gy,
                                  max(float(sz.group(1)), float(sz.group(2))) / 2))
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
                for k in range(len(pts) - 1):
                    self.outline.append((*pts[k], *pts[k + 1]))

    def headroom(self, net):
        """Widest uniform width for `net`, per segment: [(gap, allowed, ...)]."""
        out = []
        for (_i, _j, n, layer, x1, y1, x2, y2, w) in self.segments:
            if n != net:
                continue
            a, b = (x1, y1), (x2, y2)
            gap, who = float('inf'), None
            for (_a, _b, n2, l2, p1, q1, p2, q2, w2) in self.segments:
                if n2 == net or l2 != layer:
                    continue
                d = _seg_to_seg(a, b, (p1, q1), (p2, q2)) - w / 2 - w2 / 2
                if d < gap:
                    gap, who = d, 'track %s' % n2
            for (n2, layers, cx, cy, r) in self.pads:
                if n2 == net or layer not in layers:
                    continue
                d = _point_to_seg((cx, cy), a, b) - w / 2 - r
                if d < gap:
                    gap, who = d, 'pad %s' % (n2 or 'no-net')
            for (n2, cx, cy, r) in self.vias:
                if n2 == net:
                    continue
                d = _point_to_seg((cx, cy), a, b) - w / 2 - r
                if d < gap:
                    gap, who = d, 'via %s' % (n2 or 'no-net')
            for (p1, q1, p2, q2) in self.outline:
                d = _seg_to_seg(a, b, (p1, q1), (p2, q2)) - w / 2
                if d < gap:
                    gap, who = d, 'board edge'
            out.append((gap, w, who, layer, math.dist(a, b)))
        return out

    def set_width(self, net, width):
        """Rewrite (width ...) on every segment of `net`. Returns count."""
        edits = []
        for (i, j, n, _layer, *_rest) in self.segments:
            if n == net:
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


def widen(path, net, target, min_clearance, guard, dry_run):
    board = Board(open(path).read())
    rows = board.headroom(net)
    if not rows:
        sys.exit("no routed segments on net %s -- run this AFTER the session import" % net)

    routed = min(w for _gap, w, _who, _l, _len in rows)
    required = min_clearance + guard
    allowed = min(2 * ((gap + w / 2) - required) for gap, w, _who, _l, _len in rows)
    chosen = min(target, allowed)

    print("   %s: %d segments routed at %.2f mm" % (net, len(rows), routed))
    print("   layout allows %.3f mm (keeping %.2f mm: the %.2f mm rule plus %.2f mm of guard)"
          % (allowed, required, min_clearance, guard))
    if chosen <= routed:
        print("   no headroom above the routed width -- left alone")
        return 0
    tight = min(rows)
    print("   tightest segment: %.3f mm to %s on %s (%.1f mm long)"
          % (tight[0], tight[2], tight[3], tight[4]))
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

    def case(name, text, expect_allowed=None, expect_width=None, target=0.65):
        fd, p = tempfile.mkstemp(suffix='.kicad_pcb')
        os.write(fd, text.encode())
        os.close(fd)
        try:
            b = Board(open(p).read())
            rows = b.headroom('+5V_LED')
            allowed = min(2 * ((g + w / 2) - 0.25) for g, w, _o, _l, _n in rows)
            if expect_allowed is not None and abs(allowed - expect_allowed) > 1e-6:
                failures.append("%s: allowed %.4f, expected %.4f" % (name, allowed, expect_allowed))
            if expect_width is not None:
                import contextlib, io
                with contextlib.redirect_stdout(io.StringIO()):
                    widen(p, '+5V_LED', target, 0.2, 0.05, False)
                got = float(re.search(r'\(width ([\d.]+)\)', open(p).read()).group(1))
                if abs(got - expect_width) > 1e-6:
                    failures.append("%s: wrote %.4f, expected %.4f" % (name, got, expect_width))
        finally:
            os.unlink(p)

    # A neighbour 1.0 mm away on the SAME layer: edge-to-edge gap is
    # 1.0 - 0.275 - 0.15 = 0.575, so the centreline has 0.575 + 0.275 = 0.850 of
    # half-space and 0.25 must stay -- 2 * 0.600 = 1.200 mm allowed. Target wins.
    case('same layer, roomy', _STUB % {'y': 1.0, 'layer': 'F.Cu'},
         expect_allowed=1.2, expect_width=0.65)

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

    # A foreign PAD constrains, and it is measured from its largest dimension:
    # a 2.0 x 0.5 pad centred 1.5 mm off is a circle of r=1.0, so gap
    # 1.5 - 0.275 - 1.0 = 0.225, half-space 0.500, allowed 2 * 0.250 = 0.500.
    pad_board = '''(kicad_pcb
\t(segment
\t\t(start 0 0)
\t\t(end 10 0)
\t\t(width 0.55)
\t\t(layer "F.Cu")
\t\t(net "+5V_LED")
\t)
\t(footprint "x"
\t\t(at 5 0)
\t\t(pad "1" smd rect
\t\t\t(at 0 1.5)
\t\t\t(size 2.0 0.5)
\t\t\t(layers "F.Cu")
\t\t\t(net "GND")
\t\t)
\t)
)
'''
    case('pad as its largest dimension', pad_board, expect_allowed=0.5)

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
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not (a.board and a.net and a.target):
        ap.error('board, --net and --target are required')
    widen(a.board, a.net, a.target, a.min_clearance, a.guard, a.dry_run)
    return 0


if __name__ == '__main__':
    sys.exit(main())
