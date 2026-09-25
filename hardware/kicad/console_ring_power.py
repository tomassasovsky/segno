"""Hand-routed 40-LED ring supply and its fabrication guard.

The 2.4 A LED channels, 0.04 A LED idle and 0.2 A controller use a 1.7 mm
external trace on 1 oz copper. Even at 20% width loss, the conservative
IPC-2221 10 C estimate is about 2.99 A, above the 2.64 A load. Four parallel
0.5 mm drill vias carry the only layer transition; the logic rail is separate.
"""

import pcbnew


WIDTH = 1.7
VIA_DIAMETER = 0.9
VIA_DRILL = 0.5
CENTER = (141.8, 136.9)
BACK_PATH = (
    (105.4, 113.0), (102.0, 116.4), (102.0, 137.0),
    (104.4, 139.4), (104.4, 145.4), (106.5, 147.5),
    (139.0, 147.5), (141.8, 144.7), CENTER,
)
FRONT_PATH = (CENTER, (141.8, 134.0), (146.8, 129.0), (148.75, 129.0))
VIA_CENTERS = tuple(
    (CENTER[0] + dx, CENTER[1] + dy)
    for dx in (-0.55, 0.55) for dy in (-0.55, 0.55)
)
GROUND_SPOKES = {"J3": 1.2, "J24": 1.2, "J6": 0.8}
ANCHORS = {
    ("J3", "1"): (105.4, 110.88),
    ("J24", "3"): (105.4, 116.88),
    ("J6", "1"): FRONT_PATH[-1],
}


def _point(xy):
    return pcbnew.VECTOR2I(*(pcbnew.FromMM(v) for v in xy))


def _xy(point):
    return point.x, point.y


def _segment_key(a, b, layer):
    return layer, frozenset((_xy(a), _xy(b)))


def _required_tracks():
    for layer, points in ((pcbnew.B_Cu, BACK_PATH), (pcbnew.F_Cu, FRONT_PATH)):
        for a, b in zip(points, points[1:]):
            yield a, b, layer, WIDTH
    # Each short 0.8 mm spoke carries one quarter of the ring current.
    for xy in VIA_CENTERS:
        for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
            yield CENTER, xy, layer, 0.8


def stitch_keepouts(origin):
    """Board-local boxes keep automatically placed ground vias off the supply."""
    margin = 1.5  # trace/via copper radii plus clearance
    return [(min(a[0], b[0]) - origin[0] - margin,
             min(a[1], b[1]) - origin[1] - margin,
             max(a[0], b[0]) - origin[0] + margin,
             max(a[1], b[1]) - origin[1] + margin)
            for a, b, _, _ in _required_tracks()]


def _pads(board):
    return {(fp.GetReference(), pad.GetNumber()): pad
            for fp in board.GetFootprints() for pad in fp.Pads()}


def _check_anchors(pads):
    for key, xy in ANCHORS.items():
        assert key in pads and pads[key].GetNetname() == "+5V", (
            f"RING_POWER: {key} must remain on +5V")
        assert _xy(pads[key].GetPosition()) == _xy(_point(xy)), (
            f"RING_POWER: {key} moved; redesign the hand-routed supply")


def install(board):
    """Install before DSN export so signal routing respects the power path."""
    pads = _pads(board)
    _check_anchors(pads)
    net = board.FindNet("+5V")
    for a, b, layer, width in _required_tracks():
        track = pcbnew.PCB_TRACK(board)
        track.SetStart(_point(a))
        track.SetEnd(_point(b))
        track.SetLayer(layer)
        track.SetWidth(pcbnew.FromMM(width))
        track.SetNet(net)
        track.SetLocked(True)  # DSN exports this as type fix.
        board.Add(track)
    for xy in VIA_CENTERS:
        via = pcbnew.PCB_VIA(board)
        via.SetPosition(_point(xy))
        via.SetWidth(pcbnew.FromMM(VIA_DIAMETER))
        via.SetDrill(pcbnew.FromMM(VIA_DRILL))
        via.SetViaType(pcbnew.VIATYPE_THROUGH)
        via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
        via.SetNet(net)
        via.SetLocked(True)
        board.Add(via)
    for (ref, _), pad in pads.items():
        if ref in GROUND_SPOKES and pad.GetNetname() == "GND":
            pad.SetLocalThermalSpokeWidthOverride(
                pcbnew.FromMM(GROUND_SPOKES[ref]))


def check(board):
    """Refuse exports if routing or editing weakened the critical supply."""
    pads = _pads(board)
    _check_anchors(pads)
    tracks = {}
    vias = {}
    for item in board.GetTracks():
        if item.GetNetname() != "+5V":
            continue
        if item.GetClass() == "PCB_VIA":
            vias[_xy(item.GetPosition())] = item
        else:
            key = _segment_key(item.GetStart(), item.GetEnd(), item.GetLayer())
            tracks[key] = max(tracks.get(key, 0), item.GetWidth())
    for a, b, layer, width in _required_tracks():
        key = _segment_key(_point(a), _point(b), layer)
        assert tracks.get(key, 0) >= pcbnew.FromMM(width), (
            f"RING_POWER: missing or narrowed {width} mm supply segment {a} -> {b}")
    for xy in VIA_CENTERS:
        via = vias.get(_xy(_point(xy)))
        assert via is not None and via.GetDrill() >= pcbnew.FromMM(VIA_DRILL), (
            f"RING_POWER: missing or undersized parallel power via at {xy}")
        assert via.IsOnLayer(pcbnew.F_Cu) and via.IsOnLayer(pcbnew.B_Cu), (
            f"RING_POWER: power via at {xy} must join both copper layers")
    # The route begins inside the filled, two-sided input-to-pill busbar.
    for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
        zones = [z for z in board.Zones()
                 if z.GetNetname() == "+5V" and z.IsOnLayer(layer)]
        assert any(z.GetFilledPolysList(layer).Contains(_point(BACK_PATH[0]))
                   for z in zones), "RING_POWER: supply does not reach the input busbar"
    for (ref, _), pad in pads.items():
        if ref in GROUND_SPOKES and pad.GetNetname() == "GND":
            width = pad.GetLocalThermalSpokeWidthOverride()
            assert width is not None and width >= pcbnew.FromMM(GROUND_SPOKES[ref]), (
                f"RING_POWER: {ref} ground thermal spokes are undersized")


def self_test(path):
    """Inject realistic copper faults; every one must stop fabrication."""
    def segment(board):
        key = _segment_key(_point(BACK_PATH[0]), _point(BACK_PATH[1]), pcbnew.B_Cu)
        return next(t for t in board.GetTracks() if t.GetClass() != "PCB_VIA"
                    and _segment_key(t.GetStart(), t.GetEnd(), t.GetLayer()) == key)

    def via(board):
        return next(t for t in board.GetTracks() if t.GetClass() == "PCB_VIA"
                    and _xy(t.GetPosition()) == _xy(_point(VIA_CENTERS[0])))

    faults = (
        ("narrow supply", lambda b: segment(b).SetWidth(pcbnew.FromMM(0.7))),
        ("open supply", lambda b: b.RemoveNative(segment(b))),
        ("wrong supply net", lambda b: segment(b).SetNet(b.FindNet("GND"))),
        ("missing parallel via", lambda b: b.RemoveNative(via(b))),
        ("small via drill", lambda b: via(b).SetDrill(pcbnew.FromMM(0.3))),
        ("weak return thermal", lambda b: _pads(b)[("J6", "2")]
         .SetLocalThermalSpokeWidthOverride(pcbnew.FromMM(0.4))),
        ("moved ring connector", lambda b: _pads(b)[("J6", "1")]
         .SetPosition(_point((148.75, 130.0)))),
    )
    check(pcbnew.LoadBoard(path))
    for name, inject in faults:
        board = pcbnew.LoadBoard(path)
        inject(board)
        try:
            check(board)
        except AssertionError as error:
            assert str(error).startswith("RING_POWER:"), str(error)
        else:
            raise AssertionError(f"RING_POWER: failed to detect {name}")
    print(f"RING_POWER: clean board and {len(faults)} injected faults passed")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("board")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(args.board)
    else:
        check(pcbnew.LoadBoard(args.board))
        print("RING_POWER: PASS")
