"""Hand-route and verify the 40-pixel strip's dedicated power feed.

Run with KiCad's Python. The 24/16-pixel module branches retain their existing
0.65 mm tracks; the external strip uses J2 and has a separate 1.5 mm feed.
The routing script installs this feed BEFORE routing the remaining signals.
"""
import argparse
import math
from pathlib import Path
import re

import pcbnew as pcb

WIDTH = 1.5
FEED = ((52, 20), (47, 20), (45, 22), (32.19, 22), (32.19, 24))
RETURN_VIAS = ((34.23, 24), (35.23, 24), (34.73, 23.5))
# The 0.65 mm module/logic branches tap that rail instead of running their own
# long narrow leg beside it. J1's old leg left a 0.925 mm slot above the rail
# and an acute tip at its end, and U2.14's old diagonal ledged 0.0983 mm over
# the rail's lower edge; both are what the strip's +5V looked wrong at. Each
# branch now drops straight into the rail from its own pad, and the two inside
# corners where it lands carry a true 0.6 mm fillet. The fillet is a small
# locked overlay, not more track: a union of tracks is bounded by convex arcs
# and straight lines only, so no arrangement of them can round a T-junction.
TAP_WIDTH = 0.65
RAIL_Y = 22
FILLET = 0.6
# C5 and U2 pin 14 each drop straight down into the rail. The two taps, the
# rail between them and the pocket's own 0.65 mm copper do enclose about
# 8.9 mm2 of bare board, which is the geometry the owner wants: two plain
# vertical taps with rounded bases read better than one tap and a dog-leg
# across the pocket, and the enclosed area is not an electrical fault - the
# strip's current takes the 1.5 mm rail either way.
TAPS = (("C5", "1", 39, 18.5), ("U2", "14", 35.62, 20))
# Centreline radius for the rail's own bends: a 1 mm radius on the inner edge.
BEND = WIDTH / 2 + 1


def vector(point):
    return pcb.VECTOR2I(*(round(v * 1_000_000) for v in point))


def point(value):
    # The SWIG millimetre conversion can truncate a saved coordinate by 1 nm.
    return round(value.x / 100) * 100, round(value.y / 100) * 100


def pad(board, ref, number):
    return next(p for f in board.GetFootprints() if f.GetReference() == ref
                for p in f.Pads() if p.GetNumber() == number)


def arc(centre, frm, to, steps=12):
    """Chords along the circular arc frm -> to about centre.

    A polygon cannot hold a curve, so the fillet is drawn as chords; twelve to
    the quarter turn keep the deviation from the circle under 2 um at the 0.6 mm radius.
    """
    radius = math.dist(centre, frm)
    first = math.atan2(frm[1] - centre[1], frm[0] - centre[0])
    last = math.atan2(to[1] - centre[1], to[0] - centre[0])
    if last - first > math.pi:
        last -= math.tau
    if first - last > math.pi:
        last += math.tau
    return [(centre[0] + radius * math.cos(first + (last - first) * i / steps),
             centre[1] + radius * math.sin(first + (last - first) * i / steps))
            for i in range(steps + 1)]


def tap_outline(x):
    """Fillet overlay where the tap at x lands on the rail.

    The polygon's visible boundary is the tap edge, a quarter circle tangent to
    both, and the rail edge; its other sides run inside the tap and the rail,
    where they add nothing to the copper the eye sees.
    """
    half, lip = TAP_WIDTH / 2, RAIL_Y - WIDTH / 2
    top = lip - FILLET
    return (arc((x - half - FILLET, top),
                (x - half, top), (x - half - FILLET, lip))
            + [(x - half - FILLET, RAIL_Y), (x + half + FILLET, RAIL_Y)]
            + arc((x + half + FILLET, top),
                  (x + half + FILLET, lip), (x + half, top)))


def feed_nodes():
    """FEED with the tap landings inserted, so every junction is an endpoint.

    The copper is the same straight rail either way; splitting it there keeps
    the connectivity graph honest for anything that walks segment ends, this
    file's own continuity check included.
    """
    out = []
    for a, b in zip(FEED, FEED[1:]):
        out.append(a)
        if a[1] == b[1] == RAIL_Y:
            for _, _, x, _ in sorted(TAPS, key=lambda t: t[2],
                                     reverse=a[0] > b[0]):
                if min(a[0], b[0]) < x < max(a[0], b[0]):
                    out.append((x, RAIL_Y))
    out.append(FEED[-1])
    return out


def rounded(points, radius=BEND):
    """The same centreline, with a tangent arc at each corner.

    Chords, not arc items: the Specctra export flattens an arc to its chord.
    Collinear points pass through untouched, so the tap landings stay real
    endpoints of the rail. The first and last leg may spend their whole length
    on a tangent; an interior leg keeps half of it for its other end.
    """
    points = [q for i, q in enumerate(points)
              if i == 0 or math.dist(q, points[i-1]) > 1e-9]
    if len(points) < 3:
        return list(points)
    out = [points[0]]
    last = len(points) - 3
    for i, corner in enumerate(points[1:-1]):
        before, after = points[i], points[i + 2]
        v1 = (before[0] - corner[0], before[1] - corner[1])
        v2 = (after[0] - corner[0], after[1] - corner[1])
        l1, l2 = math.hypot(*v1), math.hypot(*v2)
        u1, u2 = (v1[0] / l1, v1[1] / l1), (v2[0] / l2, v2[1] / l2)
        angle = math.acos(max(-1, min(1, u1[0] * u2[0] + u1[1] * u2[1])))
        if angle > math.pi - 1e-9:
            out.append(corner)
            continue
        tangent = min(radius / math.tan(angle / 2),
                      l1 if i == 0 else l1 / 2,
                      l2 if i == last else l2 / 2)
        r = tangent * math.tan(angle / 2)
        t1 = (corner[0] + u1[0] * tangent, corner[1] + u1[1] * tangent)
        t2 = (corner[0] + u2[0] * tangent, corner[1] + u2[1] * tangent)
        bisector = (u1[0] + u2[0], u1[1] + u2[1])
        bl = math.hypot(*bisector)
        out += arc((corner[0] + bisector[0] / bl * (r / math.sin(angle / 2)),
                    corner[1] + bisector[1] / bl * (r / math.sin(angle / 2))),
                   t1, t2, steps=8)
    out.append(points[-1])
    out = [(round(x * 1_000_000) / 1_000_000, round(y * 1_000_000) / 1_000_000)
           for x, y in out]
    return [q for i, q in enumerate(out)
            if i == 0 or math.dist(q, out[i - 1]) > 1e-9]


def install(board):
    """Add the fixed feed, its taps and the return vias before signal routing."""
    assert point(pad(board, "J1", "1").GetPosition()) == point(vector(FEED[0]))
    assert point(pad(board, "J2", "1").GetPosition()) == point(vector(FEED[-1]))

    def wire(a, b, width):
        track = pcb.PCB_TRACK(board)
        track.SetStart(vector(a))
        track.SetEnd(vector(b))
        track.SetWidth(pcb.FromMM(width))
        track.SetLayer(pcb.F_Cu)
        track.SetNet(board.FindNet("+5V_LED"))
        track.SetLocked(True)
        board.Add(track)

    nodes = rounded(feed_nodes())
    for a, b in zip(nodes, nodes[1:]):
        wire(a, b, WIDTH)
    for ref, number, x, y in TAPS:
        assert point(pad(board, ref, number).GetPosition()) == point(
            vector((x, y))), "TAP: %s.%s moved" % (ref, number)
        wire((x, y), (x, RAIL_Y), TAP_WIDTH)
        zone = pcb.ZONE(board)
        zone.SetLayer(pcb.F_Cu)
        zone.SetNet(board.FindNet("+5V_LED"))
        zone.SetZoneName("TAP_FILLET")
        zone.SetAssignedPriority(20)
        zone.SetMinThickness(pcb.FromMM(0.05))
        zone.SetIslandRemovalMode(pcb.ISLAND_REMOVAL_MODE_ALWAYS)
        zone.SetPadConnection(pcb.ZONE_CONNECTION_FULL)
        zone.SetLocked(True)
        outline = zone.Outline()
        outline.NewOutline()
        for spot in tap_outline(x):
            corner = vector(spot)
            outline.Append(corner.x, corner.y)
        board.Add(zone)
    existing = {point(t.GetPosition()) for t in board.GetTracks()
                if t.GetClass() == "PCB_VIA" and t.GetNetname() == "GND"}
    for location in RETURN_VIAS:
        if point(vector(location)) in existing:
            continue
        via = pcb.PCB_VIA(board)
        via.SetPosition(vector(location))
        via.SetWidth(pcb.FromMM(0.8))
        via.SetDrill(pcb.FromMM(0.4))
        via.SetLayerPair(pcb.F_Cu, pcb.B_Cu)
        via.SetNet(board.FindNet("GND"))
        via.SetLocked(True)
        board.Add(via)


def check(board, source):
    """Trace an adequately wide, via-free path between the actual power pads."""
    start, finish = pad(board, "J1", "1"), pad(board, "J2", "1")
    assert start.GetNetname() == finish.GetNetname() == "+5V_LED", "STRIP_POWER: wrong pad net"
    graph = {}
    for track in board.GetTracks():
        if (track.GetClass() != "PCB_TRACK" or track.GetLayer() != pcb.F_Cu
                or track.GetNetname() != "+5V_LED"
                or track.GetWidth() < pcb.FromMM(WIDTH)):
            continue
        a, b = point(track.GetStart()), point(track.GetEnd())
        graph.setdefault(a, set()).add(b)
        graph.setdefault(b, set()).add(a)
    reached, pending = set(), [point(start.GetPosition())]
    while pending:
        node = pending.pop()
        if node not in reached:
            reached.add(node)
            pending.extend(graph.get(node, set()) - reached)
    assert point(finish.GetPosition()) in reached, "STRIP_POWER: no continuous 1.5 mm feed to J2"

    ground = pad(board, "J2", "2")
    assert ground.GetNetname() == "GND", "STRIP_RETURN: wrong pad net"
    # Three 0.4 mm barrels share the return. Their holes lie inside the wire
    # pad; this is hand soldered and requires no filled-via assembly service.
    center = ground.GetPosition()
    radius = min(ground.GetSize().x, ground.GetSize().y) / 2
    vias = [t for t in board.GetTracks() if t.GetClass() == "PCB_VIA"
            and t.GetNetname() == "GND" and t.TopLayer() == pcb.F_Cu
            and t.BottomLayer() == pcb.B_Cu and t.GetDrill() >= pcb.FromMM(0.4)
            and math.hypot(t.GetPosition().x - center.x,
                           t.GetPosition().y - center.y) + t.GetDrill() / 2 <= radius]
    assert len(vias) >= 3, "STRIP_RETURN: fewer than three ground barrels at J2"
    copper = re.findall(r'\(layer "[FB]\.Cu"\s*\(type "copper"\)\s*\(thickness ([\d.]+)\)', source)
    assert len(copper) == 2 and all(float(v) >= 0.035 for v in copper), "STRIP_POWER: copper below 1 oz"


def selftest(path):
    source = path.read_text()
    check(pcb.LoadBoard(str(path)), source)

    def feed(board):
        return next(t for t in board.GetTracks() if t.GetClass() == "PCB_TRACK"
                    and t.GetNetname() == "+5V_LED" and t.GetWidth() == pcb.FromMM(WIDTH))

    def ground_via(board):
        return next(t for t in board.GetTracks() if t.GetClass() == "PCB_VIA"
                    and point(t.GetPosition()) == point(vector(RETURN_VIAS[0])))

    cases = (
        ("removed feed", lambda b: b.RemoveNative(feed(b)), "STRIP_POWER"),
        ("thin feed", lambda b: feed(b).SetWidth(pcb.FromMM(0.65)), "STRIP_POWER"),
        ("broken layer transition", lambda b: feed(b).SetLayer(pcb.B_Cu), "STRIP_POWER"),
        ("wrong supply", lambda b: pad(b, "J2", "1").SetNet(b.FindNet("+3V3")), "STRIP_POWER"),
        ("missing return barrel", lambda b: b.RemoveNative(ground_via(b)), "STRIP_RETURN"),
        ("wrong return net", lambda b: ground_via(b).SetNet(b.FindNet("RING_DATA")), "STRIP_RETURN"),
    )
    for name, mutate, expected in cases:
        board = pcb.LoadBoard(str(path))
        mutate(board)
        try:
            check(board, source)
        except AssertionError as error:
            assert str(error).startswith(expected), (name, str(error))
        else:
            raise AssertionError("fault accepted: " + name)
    try:
        check(pcb.LoadBoard(str(path)), source.replace("(thickness 0.035)", "(thickness 0.018)"))
    except AssertionError as error:
        assert str(error).startswith("STRIP_POWER")
    else:
        raise AssertionError("half-ounce copper accepted")
    print("40-pixel power path: PASS; 7 deliberate faults rejected")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("board", type=Path)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        selftest(args.board)
    else:
        board = pcb.LoadBoard(str(args.board))
        if args.install:
            install(board)
            board.Save(str(args.board))
        check(board, args.board.read_text())
        print("40-pixel power path: PASS")
