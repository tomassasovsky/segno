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


def vector(point):
    return pcb.VECTOR2I(*(round(v * 1_000_000) for v in point))


def point(value):
    # The SWIG millimetre conversion can truncate a saved coordinate by 1 nm.
    return round(value.x / 100) * 100, round(value.y / 100) * 100


def pad(board, ref, number):
    return next(p for f in board.GetFootprints() if f.GetReference() == ref
                for p in f.Pads() if p.GetNumber() == number)


def install(board):
    """Add the fixed feed and return vias to a board before signal routing."""
    assert point(pad(board, "J1", "1").GetPosition()) == point(vector(FEED[0]))
    assert point(pad(board, "J2", "1").GetPosition()) == point(vector(FEED[-1]))
    for a, b in zip(FEED, FEED[1:]):
        track = pcb.PCB_TRACK(board)
        track.SetStart(vector(a))
        track.SetEnd(vector(b))
        track.SetWidth(pcb.FromMM(WIDTH))
        track.SetLayer(pcb.F_Cu)
        track.SetNet(board.FindNet("+5V_LED"))
        track.SetLocked(True)
        board.Add(track)
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
