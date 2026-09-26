"""Round the corners of a board's routed signal copper.

The hand-routed power paths already turn on arcs; their generators draw them
that way. Everything an autorouter hands back turns on mitres, and on these
boards that is most of the copper. This pass replaces each mitred corner with
a tangent circular arc, cut into chords, on the routed tracks only:

- locked tracks are left alone, so every hand-routed and checked path keeps
  the exact geometry its own guard demands;
- a chain ends wherever copper branches, so no junction is disturbed;
- the endpoints of every chain stay where they are, so nothing moves off a pad
  or a via;
- the radius is half the track width plus a millimetre, clamped per corner to
  the legs it has to sit on, so a short leg simply gets a smaller arc.

An arc does add copper on the inside of its turn: the inner edge is tangent to
both legs' inner edges, so between those tangent points it bulges into the void
the mitre left. It is a small effect - about 0.03 mm at these widths - but it
can eat a 0.23 mm clearance, so every rounded chain is measured against the
copper around it before it is accepted. A chain that cannot hold the clearance
it started with is retried at half the radius, then a quarter, and failing that
is left exactly as the router drew it.

Run it after the session import and before the refill, e.g.

    python3 round_routes.py out_console/segno_console_board.kicad_pcb
"""
import argparse
import math
from pathlib import Path
import re
import uuid

RADIUS_MARGIN = 1.0     # inner edge radius the arcs aim for
STEPS = 4               # chords per corner; 0.006 mm off the true circle
SKIP_NETS = ()          # nets whose exact geometry matters (coupled pairs)
RULE = 0.2              # clearance the result has to keep
TRIES = (1.0, 0.5, 0.25)


def arc(centre, frm, to, steps=STEPS):
    radius = math.dist(centre, frm)
    first = math.atan2(frm[1]-centre[1], frm[0]-centre[0])
    last = math.atan2(to[1]-centre[1], to[0]-centre[0])
    if last-first > math.pi:
        last -= math.tau
    if first-last > math.pi:
        last += math.tau
    return [(centre[0]+radius*math.cos(first+(last-first)*i/steps),
             centre[1]+radius*math.sin(first+(last-first)*i/steps))
            for i in range(steps+1)]


def rounded(points, radius):
    out = [points[0]]
    last = len(points)-3
    for i, corner in enumerate(points[1:-1]):
        before, after = points[i], points[i+2]
        v1 = (before[0]-corner[0], before[1]-corner[1])
        v2 = (after[0]-corner[0], after[1]-corner[1])
        l1, l2 = math.hypot(*v1), math.hypot(*v2)
        if not l1 or not l2:
            continue
        u1, u2 = (v1[0]/l1, v1[1]/l1), (v2[0]/l2, v2[1]/l2)
        angle = math.acos(max(-1, min(1, u1[0]*u2[0]+u1[1]*u2[1])))
        if angle > math.pi-1e-9 or angle < 1e-9:
            out.append(corner)
            continue
        tangent = min(radius/math.tan(angle/2),
                      l1 if i == 0 else l1/2, l2 if i == last else l2/2)
        r = tangent*math.tan(angle/2)
        t1 = (corner[0]+u1[0]*tangent, corner[1]+u1[1]*tangent)
        t2 = (corner[0]+u2[0]*tangent, corner[1]+u2[1]*tangent)
        bisector = (u1[0]+u2[0], u1[1]+u2[1])
        bl = math.hypot(*bisector)
        if bl < 1e-9:
            out.append(corner)
            continue
        out += arc((corner[0]+bisector[0]/bl*(r/math.sin(angle/2)),
                    corner[1]+bisector[1]/bl*(r/math.sin(angle/2))), t1, t2)
    out.append(points[-1])
    out = [(round(x*1_000_000)/1_000_000, round(y*1_000_000)/1_000_000)
           for x, y in out]
    return [q for i, q in enumerate(out)
            if i == 0 or math.dist(q, out[i-1]) > 1e-9]


def number(value):
    return f'{round(value * 1_000_000) / 1_000_000:.6f}'.rstrip('0').rstrip('.')


def segments(text):
    """(span, start, end, width, layer, net, locked) per segment, in order."""
    out = []
    for m in re.finditer(r'^\t\(segment\n(?:\t\t\([^\n]*\)\n)+\t\)\n', text,
                         re.M):
        block = m.group(0)

        def pair(key):
            got = re.search(r'\(%s ([-\d.]+) ([-\d.]+)\)' % key, block)
            return (round(float(got.group(1)), 6), round(float(got.group(2)), 6))
        out.append(dict(span=m.span(), a=pair('start'), b=pair('end'),
                        w=float(re.search(r'\(width ([\d.]+)\)', block).group(1)),
                        layer=re.search(r'\(layer "([^"]+)"\)', block).group(1),
                        net=re.search(r'\(net "([^"]+)"\)', block).group(1),
                        locked='(locked yes)' in block))
    return out


def chains(segs):
    """Polylines of same net/layer/width, broken at branches."""
    out = []
    for key in sorted({(s['net'], s['layer'], s['w']) for s in segs}):
        group = [s for s in segs if (s['net'], s['layer'], s['w']) == key]
        ends = {}
        for s in group:
            ends.setdefault(s['a'], []).append(s)
            ends.setdefault(s['b'], []).append(s)
        seen = set()
        for s in group:
            if id(s) in seen:
                continue
            chain = [s]
            seen.add(id(s))
            for forward in (True, False):
                node = s['b'] if forward else s['a']
                while len(ends.get(node, [])) == 2:
                    nxt = [t for t in ends[node] if id(t) not in seen]
                    if not nxt:
                        break
                    t = nxt[0]
                    seen.add(id(t))
                    node = t['b'] if t['a'] == node else t['a']
                    chain.append(t) if forward else chain.insert(0, t)
            # Order the points by the node chain[0] shares with chain[1];
            # starting from chain[0]['a'] regardless puts the first segment in
            # backwards whenever the walk began in the other direction, which
            # silently folds a polyline over itself.
            if len(chain) == 1:
                points = [chain[0]['a'], chain[0]['b']]
            else:
                shared = ({chain[0]['a'], chain[0]['b']}
                          & {chain[1]['a'], chain[1]['b']}).pop()
                points = [chain[0]['b'] if chain[0]['a'] == shared
                          else chain[0]['a'], shared]
                for t in chain[1:]:
                    points.append(t['b'] if t['a'] == points[-1] else t['a'])
            out.append((chain, points))
    return out


def _pad_outline(pad_at, size, shape, angle, ratio, n=36):
    hx, hy = size[0]/2, size[1]/2
    theta = math.radians(-angle)
    cos, sin = math.cos(theta), math.sin(theta)
    local = []
    if shape in ('circle', 'oval') and abs(hx-hy) < 1e-9:
        local = [(hx*math.cos(i/n*math.tau), hy*math.sin(i/n*math.tau))
                 for i in range(n)]
    else:
        r = min(ratio*min(hx*2, hy*2), hx, hy) if ratio else 0
        if shape == 'oval':
            r = min(hx, hy)
        for sx, sy in ((1, 1), (-1, 1), (-1, -1), (1, -1)):
            for k in range(9):
                a = math.atan2(sy, sx)+(k-4)/4*math.pi/4
                local.append((sx*(hx-r)+r*math.cos(a), sy*(hy-r)+r*math.sin(a)))
    return [(pad_at[0]+x*cos-y*sin, pad_at[1]+x*sin+y*cos) for x, y in local]


def _read(text, pos=0):
    """Minimal s-expression reader: lists, strings and bare tokens."""
    while text[pos] in ' \t\r\n':
        pos += 1
    if text[pos] == '(':
        out, pos = [], pos+1
        while True:
            while text[pos] in ' \t\r\n':
                pos += 1
            if text[pos] == ')':
                return out, pos+1
            item, pos = _read(text, pos)
            out.append(item)
    if text[pos] == '"':
        pos, buf = pos+1, []
        while text[pos] != '"':
            if text[pos] == '\\':
                pos += 1
            buf.append(text[pos])
            pos += 1
        return ''.join(buf), pos+1
    first = pos
    while text[pos] not in ' \t\r\n()"':
        pos += 1
    token = text[first:pos]
    try:
        return (float(token) if '.' in token or 'e' in token.lower()
                else int(token)), pos
    except ValueError:
        return token, pos


def _find(node, key):
    return [c for c in node if isinstance(c, list) and c and c[0] == key]


def _first(node, key):
    got = _find(node, key)
    return got[0] if got else None


def obstacles(text):
    """Foreign copper to measure against: every pad, via and segment."""
    root, _ = _read(text)
    out = []
    for via in _find(root, 'via'):
        at, size = _first(via, 'at'), _first(via, 'size')
        net = _first(via, 'net')
        out.append(dict(net=net[-1] if net else '', layers={'F.Cu', 'B.Cu'},
                        poly=[(at[1], at[2])], grow=size[1]/2, closed=False))
    for s in segments(text):
        out.append(dict(net=s['net'], layers={s['layer']}, poly=[s['a'], s['b']],
                        grow=s['w']/2, closed=False, span=s['span']))
    for fp in _find(root, 'footprint'):
        at = _first(fp, 'at')
        base, rot = (at[1], at[2]), (at[3] if len(at) > 3 else 0)
        theta = math.radians(rot)
        for pad in _find(fp, 'pad'):
            local, size = _first(pad, 'at'), _first(pad, 'size')
            net, ratio = _first(pad, 'net'), _first(pad, 'roundrect_rratio')
            names = set(_first(pad, 'layers')[1:])
            on = ({'F.Cu', 'B.Cu'} if any('*' in n for n in names)
                  else {n for n in names if n.endswith('.Cu')})
            if not on:
                continue
            spot = (base[0]+local[1]*math.cos(theta)+local[2]*math.sin(theta),
                    base[1]-local[1]*math.sin(theta)+local[2]*math.cos(theta))
            out.append(dict(
                net=net[-1] if net else '', layers=on, grow=0.0, closed=True,
                poly=_pad_outline(spot, (size[1], size[2]), pad[3],
                                  (local[3] if len(local) > 3 else 0)+rot,
                                  ratio[1] if ratio else 0)))
    return out


def _seg_point(p, a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]
    l2 = dx*dx+dy*dy
    u = 0 if not l2 else max(0, min(1, ((p[0]-a[0])*dx+(p[1]-a[1])*dy)/l2))
    return math.dist(p, (a[0]+u*dx, a[1]+u*dy))


def _seg_gap(a, b, c, d):
    def cross(o, p, q):
        return (p[0]-o[0])*(q[1]-o[1])-(p[1]-o[1])*(q[0]-o[0])
    d1, d2 = cross(c, d, a), cross(c, d, b)
    d3, d4 = cross(a, b, c), cross(a, b, d)
    if ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)):
        return 0.0
    return min(_seg_point(a, c, d), _seg_point(b, c, d),
               _seg_point(c, a, b), _seg_point(d, a, b))


def clearance(points, width, layer, net, around):
    """Smallest gap from this polyline's copper to foreign copper nearby."""
    best = 9e9
    for other in around:
        if other['net'] == net or layer not in other['layers']:
            continue
        edges = list(zip(other['poly'], other['poly'][1:]
                         + (other['poly'][:1] if other['closed'] else [])))
        if not edges:
            edges = [(other['poly'][0], other['poly'][0])]
        for a, b in zip(points, points[1:]):
            for c, d in edges:
                best = min(best, _seg_gap(a, b, c, d)-width/2-other['grow'])
                if best < -1:
                    return best
    return best


def nearby(around, points, margin=3.0):
    x0 = min(p[0] for p in points)-margin
    x1 = max(p[0] for p in points)+margin
    y0 = min(p[1] for p in points)-margin
    y1 = max(p[1] for p in points)+margin
    out = []
    for it in around:
        xs = [p[0] for p in it['poly']]
        ys = [p[1] for p in it['poly']]
        if max(xs) >= x0 and min(xs) <= x1 and max(ys) >= y0 and min(ys) <= y1:
            out.append(it)
    return out


def wire(net, layer, a, b, width):
    return (f'\t(segment\n\t\t(start {number(a[0])} {number(a[1])})\n'
            f'\t\t(end {number(b[0])} {number(b[1])})\n'
            f'\t\t(width {number(width)})\n'
            f'\t\t(layer "{layer}")\n\t\t(net "{net}")\n'
            f'\t\t(uuid "{uuid.uuid4()}")\n\t)\n')


def process(path, dry_run=False, report=False):
    text = path.read_text()
    segs = segments(text)
    routed = [s for s in segs if not s['locked'] and s['net'] not in SKIP_NETS]
    around = obstacles(text)
    drop, added, corners, kept, held = [], '', 0, 0, 0
    for chain, points in chains(routed):
        turns = sum(1 for a, b, c in zip(points, points[1:], points[2:])
                    if abs(math.pi-abs(math.atan2(c[1]-b[1], c[0]-b[0])
                                       - math.atan2(b[1]-a[1], b[0]-a[0]))) > 1e-9)
        if len(points) < 3 or not turns:
            kept += 1
            continue
        net, layer, w = chain[0]['net'], chain[0]['layer'], chain[0]['w']
        close = [it for it in nearby(around, points)
                 if it.get('span') not in {s['span'] for s in chain}]
        floor = min(RULE, clearance(points, w, layer, net, close))
        curved = None
        for share in TRIES:
            attempt = rounded(points, (w/2+RADIUS_MARGIN)*share)
            if clearance(attempt, w, layer, net, close) >= floor-1e-9:
                curved = attempt
                break
        if curved is None:
            held += 1
            continue
        corners += turns
        drop += [s['span'] for s in chain]
        added += ''.join(wire(net, layer, a, b, w)
                         for a, b in zip(curved, curved[1:]))
    for span in sorted(drop, reverse=True):
        text = text[:span[0]] + text[span[1]:]
    spot = re.search(r'^\t\(zone\n', text, re.M)
    cut = spot.start() if spot else text.rindex('\n)')
    text = text[:cut] + added + text[cut:]
    if added.count('(') != added.count(')'):
        raise SystemExit('generated copper is unbalanced')
    if not dry_run:
        path.write_text(text)
    locked = sum(1 for s in segs if s['locked'])
    print(f'{path.name}: rounded {corners} corners on '
          f'{len(drop)} routed segments into {added.count("(segment")} chords; '
          f'{locked} locked segments, {kept} straight runs and {held} chains '
          'with no room left as they were'
          + (' (dry run)' if dry_run else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('boards', nargs='+', type=Path)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    for board in args.boards:
        process(board, args.dry_run)


if __name__ == '__main__':
    main()
