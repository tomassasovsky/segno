"""Round the corners of a board's routed copper, using KiCad's own geometry.

The hand-routed power paths already turn on arcs; their generators draw them
that way. Everything an autorouter hands back turns on mitres, and on these
boards that is most of the copper. This pass replaces each mitred corner with a
tangent circular arc, cut into chords, on the routed tracks only.

Run it with KiCad's Python, after the session import and before the refill:

    kipython round_routes.py out_console/segno_console_board.kicad_pcb
    kipython round_routes.py hand/screen_power_hand.kicad_pcb \\
        --skip S1_UP_P,S1_UP_N,S1_DN_P,S1_DN_N,S2_UP_P,S2_UP_N,S2_DN_P,S2_DN_N

Everything it measures comes from pcbnew: PAD.GetEffectiveShape gives a custom
pad its real outline and a rotated pad its real orientation, and SHAPE.Collide
answers the clearance question the DRC engine itself asks. An earlier version of
this script rebuilt all of that from the board file by hand and got J1 pin 2's
1.6 x 3.2 mm body back as 3.2 x 1.6, because a pad's serialised angle is already
absolute and it added the footprint's rotation on top; forty console pad
outlines were wrong by up to 1.2 mm, and custom pads came out as their anchor.
None of that arithmetic is here any more.

What it will not touch:

- locked tracks, so every hand-routed and checked path keeps the exact geometry
  its own guard demands, and arcs, which are already round;
- any net named with --skip: a matched pair's geometry is its own generator's
  business, and rounding one side of a pair independently is a coupling change;
- a chain's endpoints, and every anchor along it. A chain is cut at each pad or
  via its copper lands in, and at every junction that is not simply two tracks
  of this net, this layer and this width meeting end to end - so at every width
  change, locked junction and layer transition as well. Those are the points
  where the rest of the net joins this run: they end a chain, chain ends never
  move, and the pass re-checks every one of them on the finished board;
- a vertex that turns by less than MIN_TURN degrees. No chord this script emits
  turns by more than CHORD_TURN, which is half of that, so a second run over its
  own output finds nothing to do.

An arc does add copper on the inside of its turn: the inner edge is tangent to
both legs' inner edges, so between those tangent points it bulges into the void
the mitre left. It is a small effect - about 0.03 mm at these widths - but it
can eat a 0.23 mm clearance, so every corner is measured against the copper
around it, including the copper this pass has already laid down. The rule is per
corner: the arc may not come closer to foreign copper than the mitre it
replaces, or than RULE, whichever is smaller. A corner that cannot hold that at
a 1 mm inside radius is retried at 0.7, 0.5 and on down to 0.05 mm, and the
radius is capped by the legs themselves, so a tight corner gets a small
deliberate radius rather than none. Only a corner with no room at all for the
smallest radius stays a mitre, and every one of those is printed with its
coordinates and the reason.
"""
import argparse
import math
from pathlib import Path

import pcbnew as pcb

INSIDE = (1.0, 0.7, 0.5, 0.35, 0.25, 0.15, 0.1, 0.05)   # mm, inner-edge radii
FLOOR = 0.05            # mm, the smallest inside radius worth a chord
CHORD_TURN = 6.0        # degrees a single chord may turn
MIN_TURN = 12.0         # a vertex that turns less than this is left alone
RULE = 0.2              # mm clearance the result has to keep
STEP = 1000             # nm, how finely the clearance floor is measured
CELL = 1_000_000        # nm, cell of the lookup grid
COPPER = (pcb.F_Cu, pcb.B_Cu)


def iu(value):
    return int(round(value * 1e6))


def mm(value):
    return value / 1e6


def point(spot):
    return (int(spot.x), int(spot.y))


def vector(spot):
    return pcb.VECTOR2I(int(round(spot[0])), int(round(spot[1])))


def bounds(item):
    box = item.GetBoundingBox()
    return (box.GetLeft(), box.GetTop(), box.GetRight(), box.GetBottom())


def hull(points, grow):
    return (int(min(p[0] for p in points)-grow), int(min(p[1] for p in points)-grow),
            int(max(p[0] for p in points)+grow), int(max(p[1] for p in points)+grow))


def overlaps(one, other):
    return not (one[0] > other[2] or one[2] < other[0]
                or one[1] > other[3] or one[3] < other[1])


class Index:
    """Copper by layer on a 1 mm grid, with replaced copper struck out.

    Shapes go in, not board items: a shape is what Collide takes, and holding
    the shape here is also what keeps it alive, since pcbnew hands out a fresh
    object each time GetEffectiveShape is called.
    """

    def __init__(self):
        self.cells = {}
        self.dead = set()

    def add(self, layer, shape, net, box, spots=()):
        """File a shape, with the points its own copper is anchored at.

        Those points are what a mid-run junction is found by: the end of a
        branch, or the centre of a pad or via, that lands on a track between its
        own two ends.
        """
        for cx in range(box[0]//CELL, box[2]//CELL+1):
            for cy in range(box[1]//CELL, box[3]//CELL+1):
                self.cells.setdefault((layer, cx, cy), []).append(
                    (shape, net, box, tuple(spots)))

    def retire(self, shapes):
        self.dead.update(id(shape) for shape in shapes)

    def near(self, layer, box, net, same=False):
        """Shapes of a foreign net around here, or - with same - of this net.

        A rule area and the board outline have no net at all, so they are
        foreign to everything and never count as copper of one's own.
        """
        return [shape for shape, _spots in self.items(layer, box, net, same)]

    def items(self, layer, box, net, same=False):
        """near(), with each shape's own anchor points beside it."""
        out, seen = [], set()
        for cx in range(box[0]//CELL, box[2]//CELL+1):
            for cy in range(box[1]//CELL, box[3]//CELL+1):
                for shape, owner, other, spots in self.cells.get((layer, cx, cy), ()):
                    if (owner == net) != same or id(shape) in self.dead:
                        continue
                    if id(shape) in seen or not overlaps(box, other):
                        continue
                    seen.add(id(shape))
                    out.append((shape, spots))
        return out


def keepouts(board):
    """Rule areas that forbid tracks, board level and footprint level.

    A keepout is not copper, so nothing collides with it in the connectivity
    sense, but a track may not enter it - and a corner rounded blind will walk
    into one, since the arc bulges towards the inside of its turn. They go into
    the same index as foreign copper, with no net, and are measured by the same
    rule: no closer than the mitre was, or than RULE.
    """
    out = []
    for zone in list(board.Zones()) + [z for fp in board.GetFootprints()
                                       for z in fp.Zones()]:
        if zone.GetIsRuleArea() and zone.GetDoNotAllowTracks():
            out.append(zone)
    return out


def collect(tracks, pads, edges, areas):
    """The board as shapes: every track, via, pad, board edge and track keepout.

    Edge.Cuts goes in with no net, so copper is held off the outline by the same
    rule as off foreign copper - rounding pushes a corner outwards as well as
    inwards. The second return value maps each item to the shapes filed for it,
    so the copper this pass replaces can be struck out again.
    """
    index, filed = Index(), {}
    for item in list(tracks) + list(pads):
        if item.GetClass() == 'PCB_TRACK' or item.GetClass() == 'PCB_ARC':
            spots = (point(item.GetStart()), point(item.GetEnd()))
        else:                                  # a pad or a via: its own centre
            spots = (point(item.GetPosition()),)
        for layer in COPPER:
            if not item.IsOnLayer(layer):
                continue
            shape = item.GetEffectiveShape(layer)
            filed.setdefault(id(item), []).append(shape)
            index.add(layer, shape, item.GetNetCode(), bounds(item), spots)
    for edge in edges:
        try:
            shape = edge.GetEffectiveShape()
        except Exception:                      # a drawing pcbnew cannot flatten
            continue
        for layer in COPPER:
            index.add(layer, shape, None, bounds(edge))
    for zone in areas:
        outline = zone.Outline()
        for layer in COPPER:
            if zone.IsOnLayer(layer):
                index.add(layer, outline, None, bounds(zone))
    return index, filed


def holds(shapes, others, gap):
    for shape in shapes:
        for other in others:
            if shape.Collide(other, gap):
                return False
    return True


def slack(shapes, others, cap):
    """The largest clearance up to cap this copper holds, to STEP nm."""
    if not holds(shapes, others, 0):
        return -1
    if holds(shapes, others, cap):
        return cap
    low, high = 0, cap
    while high - low > STEP:
        middle = (low + high) // 2
        if holds(shapes, others, middle):
            low = middle
        else:
            high = middle
    return low


def turn(a, b, c):
    """How far a run deflects at b, in degrees; 0 is dead straight."""
    first = (b[0]-a[0], b[1]-a[1])
    second = (c[0]-b[0], c[1]-b[1])
    one, two = math.hypot(*first), math.hypot(*second)
    if not one or not two:
        return 0.0
    cosine = (first[0]*second[0] + first[1]*second[1]) / (one*two)
    return math.degrees(math.acos(max(-1.0, min(1.0, cosine))))


def chords(centre, frm, to, steps):
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


def corner(before, spot, after, radius, room):
    """(centreline radius, chords) for one rounded corner, or None.

    The tangent is capped by the room each leg can spare, so the arc is the
    largest one that actually fits between this corner and its neighbours.
    """
    back = (before[0]-spot[0], before[1]-spot[1])
    forth = (after[0]-spot[0], after[1]-spot[1])
    one, two = math.hypot(*back), math.hypot(*forth)
    if not one or not two:
        return None
    u1, u2 = (back[0]/one, back[1]/one), (forth[0]/two, forth[1]/two)
    angle = math.acos(max(-1.0, min(1.0, u1[0]*u2[0] + u1[1]*u2[1])))
    if angle < 1e-9 or angle > math.pi - 1e-9:
        return None
    tangent = min(radius/math.tan(angle/2), room[0], room[1])
    actual = tangent*math.tan(angle/2)
    bisector = (u1[0]+u2[0], u1[1]+u2[1])
    length = math.hypot(*bisector)
    if length < 1e-9:
        return None
    reach = actual/math.sin(angle/2)
    steps = max(3, int(math.ceil(math.degrees(math.pi-angle)/CHORD_TURN)))
    return actual, chords((spot[0]+bisector[0]/length*reach,
                           spot[1]+bisector[1]/length*reach),
                          (spot[0]+u1[0]*tangent, spot[1]+u1[1]*tangent),
                          (spot[0]+u2[0]*tangent, spot[1]+u2[1]*tangent), steps)


def chord_track(board, model, a, b):
    """One chord of the run that model belongs to, not yet on the board."""
    out = pcb.PCB_TRACK(board)
    out.SetStart(vector(a))
    out.SetEnd(vector(b))
    out.SetWidth(model.GetWidth())
    out.SetLayer(model.GetLayer())
    out.SetNet(model.GetNet())
    return out


def shapes_for(board, model, points, layer):
    """Tracks for a polyline in this run's width, and their shapes."""
    made = [chord_track(board, model, a, b) for a, b in zip(points, points[1:])]
    return made, [item.GetEffectiveShape(layer) for item in made]


def graph(tracks):
    """Endpoint degree per (net, layer), over every track and arc there is."""
    out = {}
    for item in tracks:
        if item.GetClass() == 'PCB_VIA':
            continue
        ends = out.setdefault((item.GetNetCode(), item.GetLayer()), {})
        for end in (point(item.GetStart()), point(item.GetEnd())):
            ends[end] = ends.get(end, 0) + 1
    return out


def landings(tracks, pads):
    """Pad and via shapes by layer: the copper a run may not be pulled off."""
    out = {layer: [] for layer in COPPER}
    for item in list(tracks) + list(pads):
        if item.GetClass() == 'PCB_TRACK' or item.GetClass() == 'PCB_ARC':
            continue
        for layer in COPPER:
            if item.IsOnLayer(layer):
                out[layer].append((item.GetEffectiveShape(layer),
                                   item.GetNetCode(), bounds(item)))
    return out


def along(a, b, spot):
    """(how far along a -> b a point falls, how far off the line it is), in nm."""
    dx, dy = b[0]-a[0], b[1]-a[1]
    length = math.hypot(dx, dy)
    if not length:
        return 0.0, math.dist(a, spot)
    return (((spot[0]-a[0])*dx + (spot[1]-a[1])*dy)/length,
            abs((spot[0]-a[0])*dy - (spot[1]-a[1])*dx)/length)


def split_junctions(board, candidates, index, filed, margin=2000):
    """Give every mid-run junction a node of its own, and return the new list.

    The endpoint degree of the copper graph cannot see a junction that is not an
    endpoint: a branch leaving a run between two of its nodes, or a pad whose
    body overlaps it there, is connected through copper and through nothing
    else. Rounding shortens the legs beside a corner, so a branch landing
    0.2 mm from that corner is exactly what the arc walks out from under - which
    is how one T-junction became two copper islands. Splitting the run at the
    contact first leaves the same copper with one more endpoint, and the chain
    walk then stops there like at any other anchor.
    """
    out, nodes = [], []
    for item in candidates:
        a, b = point(item.GetStart()), point(item.GetEnd())
        layer, net = item.GetLayer(), item.GetNetCode()
        length = math.dist(a, b)
        if length <= 2*margin:                 # nothing to split it into
            out.append(item)
            continue
        own = {id(shape) for shape in filed.get(id(item), ())}
        mine = item.GetEffectiveShape(layer)
        cuts = []
        for other, spots in index.items(layer, bounds(item), net, same=True):
            if id(other) in own or not other.Collide(mine, 0):
                continue
            for spot in spots:
                # The point has to be in this run's own copper: that is what
                # tells a branch landing on it apart from copper that merely
                # crosses it on the way somewhere else.
                if spot in (a, b) or not mine.Collide(vector(spot), 0):
                    continue
                reach = along(a, b, spot)[0]
                if margin < reach < length-margin:
                    cuts.append(reach)
        kept = []
        for reach in sorted(cuts):
            if not kept or reach-kept[-1] > margin:
                kept.append(reach)
        cuts = kept
        if not cuts:
            out.append(item)
            continue
        ux, uy = (b[0]-a[0])/length, (b[1]-a[1])/length
        walk = [a] + [(int(round(a[0]+ux*c)), int(round(a[1]+uy*c)))
                      for c in cuts] + [b]
        pieces = [chord_track(board, item, p, q) for p, q in zip(walk, walk[1:])]
        index.retire(filed.get(id(item), ()))
        board.Remove(item)
        for piece in pieces:
            board.Add(piece)
            shape = piece.GetEffectiveShape(layer)
            filed[id(piece)] = [shape]
            index.add(layer, shape, net, bounds(piece),
                      (point(piece.GetStart()), point(piece.GetEnd())))
        out += pieces
        nodes += [(net, layer, spot) for spot in walk[1:-1]]
    return out, nodes


def sits_in(spots, node, net, layer):
    """Is this point inside a pad or via of its own net?"""
    where = vector(node)
    for shape, owner, box in spots[layer]:
        if owner != net or not overlaps((node[0], node[1], node[0], node[1]), box):
            continue
        if shape.Collide(where, 0):
            return True
    return False


def runs(tracks, stop):
    """Polylines of same net/layer/width copper, broken at every anchor."""
    out, groups = [], {}
    for item in tracks:
        groups.setdefault((item.GetNetCode(), item.GetLayer(),
                           item.GetWidth()), []).append(item)
    for key in sorted(groups):
        group = groups[key]
        ends = {}
        for item in group:
            ends.setdefault(point(item.GetStart()), []).append(item)
            ends.setdefault(point(item.GetEnd()), []).append(item)
        held = {node: stop(node, key[0], key[1]) for node in ends}
        seen = set()
        for item in group:
            if id(item) in seen:
                continue
            chain = [item]
            seen.add(id(item))
            for forward in (True, False):
                node = point(item.GetEnd() if forward else item.GetStart())
                while len(ends.get(node, ())) == 2 and not held[node]:
                    following = [t for t in ends[node] if id(t) not in seen]
                    if not following:
                        break
                    step = following[0]
                    seen.add(id(step))
                    a, b = point(step.GetStart()), point(step.GetEnd())
                    node = b if a == node else a
                    if forward:
                        chain.append(step)
                    else:
                        chain.insert(0, step)
            # Order the points by the node the first two segments share. Taking
            # chain[0]'s own start regardless puts that segment in backwards
            # whenever the walk began in the other direction, which folds the
            # polyline over itself and fabricates a hairpin.
            if len(chain) == 1:
                spots = [point(chain[0].GetStart()), point(chain[0].GetEnd())]
            else:
                first = (point(chain[0].GetStart()), point(chain[0].GetEnd()))
                shared = (set(first) & {point(chain[1].GetStart()),
                                        point(chain[1].GetEnd())}).pop()
                spots = [first[1] if first[0] == shared else first[0], shared]
                for step in chain[1:]:
                    a, b = point(step.GetStart()), point(step.GetEnd())
                    spots.append(b if a == spots[-1] else a)
            spots = [p for i, p in enumerate(spots) if i == 0 or p != spots[i-1]]
            out.append((chain, spots))
    return out


def process(board, skip=()):
    tracks = list(board.GetTracks())
    pads = [pad for fp in board.GetFootprints() for pad in fp.Pads()]
    edges = [d for d in board.GetDrawings() if d.GetLayer() == pcb.Edge_Cuts]
    areas = keepouts(board)
    index, filed = collect(tracks, pads, edges, areas)
    candidates = [t for t in tracks
                  if t.GetClass() == 'PCB_TRACK' and not t.IsLocked()
                  and t.GetNetCode() and t.GetNetname() not in skip]
    # Mid-run junctions become nodes before anything is measured, so the graph
    # below sees them and the chain walk stops at them.
    candidates, cut = split_junctions(board, candidates, index, filed)
    tracks = list(board.GetTracks())
    degree = graph(tracks)
    spots = landings(tracks, pads)
    known = {}

    def blocked(node, net, layer):
        key = (node, net, layer)
        if key not in known:
            known[key] = (degree.get((net, layer), {}).get(node, 0) != 2
                          or sits_in(spots, node, net, layer))
        return known[key]

    anchors = {(t.GetNetCode(), t.GetLayer(), end) for t in candidates
               for end in (point(t.GetStart()), point(t.GetEnd()))
               if blocked(end, t.GetNetCode(), t.GetLayer())} | set(cut)
    chains = runs(candidates, blocked)
    tally, sharp, added, retired, touched = {}, [], 0, 0, 0
    for chain, points in chains:
        model = chain[0]
        net, layer, width = model.GetNetCode(), model.GetLayer(), model.GetWidth()
        if len(points) < 3:
            continue
        own = {id(shape) for item in chain for shape in filed.get(id(item), ())}
        out, changed = [points[0]], False
        for i, spot in enumerate(points[1:-1]):
            before, after = points[i], points[i+2]
            deflection = turn(before, spot, after)
            if deflection < MIN_TURN:
                out.append(spot)
                continue
            # A tangent may spend a whole end leg but only half an interior one,
            # so two corners on one leg can never eat into each other.
            room = (math.dist(before, spot) / (1 if i == 0 else 2),
                    math.dist(spot, after) / (1 if i == len(points)-3 else 2))
            cap = min(room)*math.tan(math.radians(180-deflection)/2)
            radii = [width/2 + iu(r) for r in INSIDE if width/2 + iu(r) <= cap]
            if not radii and cap >= width/2 + iu(FLOOR):
                radii = [cap]                  # tight, but still a real radius
            if not radii:
                sharp.append((net, layer, spot, deflection,
                              'the legs have no room for a %.2f mm inside radius'
                              % FLOOR))
                out.append(spot)
                continue
            first = corner(before, spot, after, radii[0], room)
            if first is None:
                out.append(spot)
                continue
            # One neighbourhood for every attempt: a smaller radius sits inside
            # the region the largest one spans.
            others = index.near(layer, hull(first[1]+[spot],
                                            width + iu(RULE) + CELL), net)
            chosen = None
            for radius in radii:
                made = (first if radius == radii[0]
                        else corner(before, spot, after, radius, room))
                if made is None or made[0] < width/2 + iu(FLOOR):
                    continue
                actual, curve = made
                mitre = shapes_for(board, model, [curve[0], spot, curve[-1]],
                                   layer)[1]
                floor = min(iu(RULE), slack(mitre, others, iu(RULE)))
                if floor < 0:
                    break                      # the mitre itself overlaps: hands off
                arc = shapes_for(board, model, curve, layer)[1]
                if not holds(arc, others, floor):
                    continue
                # Whatever this corner's copper touches, it has to go on
                # touching: a pad or a branch can overlap a corner without
                # reaching its centreline, so a point test does not see it and
                # the arc would quietly let go of it. The copper that goes is
                # exactly the mitre, so what the mitre touches is what to check.
                mates = [s for s in index.near(
                    layer, hull([curve[0], spot, curve[-1]], width), net, True)
                    if id(s) not in own and any(s.Collide(m, 0) for m in mitre)]
                if all(any(s.Collide(a, 0) for a in arc) for s in mates):
                    chosen = (actual, curve)
                    break
            if chosen is None:
                sharp.append((net, layer, spot, deflection,
                              'no clearance for an inside radius down to %.2f mm'
                              % FLOOR))
                out.append(spot)
                continue
            actual, curve = chosen
            out += [(int(round(x)), int(round(y))) for x, y in curve]
            inside = round(mm(actual - width/2), 3)
            tally[inside] = tally.get(inside, 0) + 1
            changed = True
        out.append(points[-1])
        out = [p for i, p in enumerate(out) if i == 0 or p != out[i-1]]
        if not changed:
            continue
        made, shapes = shapes_for(board, model, out, layer)
        for item in chain:
            index.retire(filed.get(id(item), ()))
            board.Remove(item)
            retired += 1
        for item, shape in zip(made, shapes):
            board.Add(item)
            index.add(layer, shape, net, bounds(item))
            added += 1
        touched += 1
    live = set()
    for item in board.GetTracks():
        if item.GetClass() == 'PCB_VIA':
            continue
        for end in (point(item.GetStart()), point(item.GetEnd())):
            live.add((item.GetNetCode(), item.GetLayer(), end))
    lost = sorted(anchors - live)
    if lost:
        raise SystemExit('round_routes: %d anchor(s) no longer have copper '
                         'ending on them, e.g. %s' % (len(lost), lost[:4]))
    return dict(added=added, retired=retired, touched=touched, tally=tally,
                sharp=sharp, chains=len(chains), anchors=len(anchors))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('boards', nargs='+', type=Path)
    parser.add_argument('--skip', default='',
                        help='comma separated nets to leave exactly as they are')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    skip = {net for net in args.skip.split(',') if net}
    for path in args.boards:
        board = pcb.LoadBoard(str(path))
        result = process(board, skip=skip)
        if not args.dry_run:
            board.Save(str(path))
        radii = ', '.join('%g mm x%d' % item
                          for item in sorted(result['tally'].items(),
                                             reverse=True))
        print('%s: rounded %d corners on %d of %d routed chains, %d segments '
              'into %d chords; inside radius %s; %d anchors held%s'
              % (path.name, sum(result['tally'].values()), result['touched'],
                 result['chains'], result['retired'], result['added'],
                 radii or 'none', result['anchors'],
                 ' (dry run)' if args.dry_run else ''))
        for net, layer, spot, deflection, why in result['sharp']:
            print('   left as a mitre: net %d, layer %d, (%.4f, %.4f), turns '
                  '%.1f degrees - %s' % (net, layer, mm(spot[0]), mm(spot[1]),
                                         deflection, why))


if __name__ == '__main__':
    main()
