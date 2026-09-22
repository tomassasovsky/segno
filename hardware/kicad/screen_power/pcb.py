"""Place components for both screen-power board variants.

Run with KiCad's Python. The placed board never overwrites a routed deliverable.
Low-priority remaining connections may subsequently use Freerouting.
"""
import argparse
import json
import os
from pathlib import Path
import sys

import pcbnew as p

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from netlist import parse_netlist

FPDIR = Path(os.environ.get("KICAD_FOOTPRINT_DIR", "/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints"))
W, H = 130, 120


def point(x, y):
    return p.VECTOR2I(p.FromMM(x), p.FromMM(y))


def xy(position):
    return (p.ToMM(position.x), p.ToMM(position.y))


def build(variant):
    out = HERE / variant
    components, nets = parse_netlist(out / f"screen_power_{variant}.net")
    board = p.BOARD()
    ds = board.GetDesignSettings()
    ds.SetCopperLayerCount(4)
    ds.m_MinClearance = p.FromMM(0.15)
    ds.m_TrackMinWidth = p.FromMM(0.15)
    ds.m_ViasMinSize = p.FromMM(0.6)
    ds.m_MinThroughDrill = p.FromMM(0.2 if variant == "factory" else 0.3)
    ds.m_SolderMaskMinWidth = p.FromMM(0.08)
    ds.m_SolderMaskExpansion = p.FromMM(0.025)
    for nc in board.GetAllNetClasses().values():
        nc.SetClearance(p.FromMM(0.15))
        nc.SetTrackWidth(p.FromMM(0.25))
        nc.SetViaDiameter(p.FromMM(0.6))
        nc.SetViaDrill(p.FromMM(0.3))
    netmap = {}
    for name in nets:
        ni = p.NETINFO_ITEM(board, name)
        board.Add(ni)
        netmap[name] = ni
    pin_nets = {item: name for name, nodes in nets.items() for item in nodes}
    fps = {}

    def place(ref, x, y, angle=0, centre=True):
        lib, name, value = components[ref]
        library = HERE / (lib + ".pretty") if lib == "screen_power" else FPDIR / (lib + ".pretty")
        fp = p.FootprintLoad(str(library), name)
        if fp is None:
            raise ValueError(f"Footprint missing: {ref} {lib}:{name}")
        fp.SetReference(ref)
        fp.SetValue(value)
        fp.SetOrientationDegrees(angle)
        if centre:
            box = fp.GetBoundingBox(False, False)
            pos = box.GetCenter()
            fp.SetPosition(point(x, y) - pos)
        else:
            fp.SetPosition(point(x, y))
        board.Add(fp)
        for pad in fp.Pads():
            name = pin_nets.get((ref, pad.GetNumber()))
            if name:
                pad.SetNet(netmap[name])
        fp.Reference().SetTextSize(point(0.85, 0.85))
        fp.Reference().SetTextThickness(p.FromMM(0.15))
        fp.Value().SetVisible(False)
        fps[ref] = fp
        return fp

    if variant == "hand":
        from hand_layout import place_components
        place_components(place, fps)
    else:
        place("J1", 65, 47)
        place("J2", 65, 20)
        place("R1", 53, 40)
        place("R2", 58, 40)
        place("Q1", 64, 40)
        place("R3", 74, 40)
        place("R4", 80, 40)
        place("R5", 86, 40)
        for i, loc in enumerate([(5, 5), (125, 5), (5, 115), (125, 115)], 1):
            place(f"H{i}", *loc)

        # The factory version uses an isolated USB interface for each screen.
        for channel, x in [(1, 38), (2, 93)]:
            n = channel * 100
            place(f"U{n+1}", x, 78, centre=False)
            place(f"J{n+1}", x - 10.75, 103.7125, 270, centre=False)
            place(f"J{n+2}", x + 12, 108.5, 90)
            place(f"D{n+1}", x - 13, 88, 90)
            place(f"D{n+2}", x + 10, 88, 90)
            place(f"Y{n+1}", x - 11, 77, 270)
            place(f"C{n+1}", x - 5, 72, 180)
            place(f"C{n+2}", x - 6.5, 76.45, 180)
            place(f"C{n+3}", x + 6.5, 76.45)
            place(f"C{n+4}", x + 5, 72)
            place(f"C{n+5}", x - 12.15, 71.5, 90)
            place(f"C{n+6}", x - 9.85, 82, 270)
            fps[f"Y{n+1}"].Reference().SetPosition(point(x-17, 77))
            fps[f"Y{n+1}"].Reference().SetTextAngle(p.EDA_ANGLE(0, p.DEGREES_T))
            fps[f"C{n+1}"].Reference().SetPosition(point(x-5, 69.8))
            place(f"U{n+2}", x + 2, 57)
            place(f"R{n+1}", x - 3, 54)
            place(f"C{n+7}", x + 2, 53)
            place(f"R{n+2}", x + 7, 57, 90)
            place(f"U{n+3}", x + 2, 65)
            place(f"C{n+8}", x - 2, 62, 90)
            place(f"R{n+3}", x + 7, 65, 90)
            place(f"C{n+9}", x + 15, 69)
            dump_x = 15 if channel == 1 else 115
            place(f"Q{n+1}", dump_x, 43)
            place(f"Q{n+2}", x + 21, 62)
            place(f"R{n+4}", dump_x, 37, 270)
            place(f"R{n+5}", x + 21, 55, 90)
            xpower = 17 if channel == 1 else 113
            place(f"J{n+3}", xpower, 4, 180)
            place(f"U{n+4}", xpower, 16, centre=False)
            place(f"C{n+10}", xpower - 5, 14, 90)
            place(f"C{n+11}", xpower, 26, 0 if channel == 1 else 180)
            place(f"C{n+12}", xpower + 6, 12, 90)
            place(f"R{n+6}", xpower + 3, 21)
    assert set(fps) == set(components), set(components) - set(fps)

    for a, b in [((0, 0), (W, 0)), ((W, 0), (W, H)), ((W, H), (0, H)), ((0, H), (0, 0))]:
        line = p.PCB_SHAPE(board)
        line.SetShape(p.SHAPE_T_SEGMENT); line.SetStart(point(*a)); line.SetEnd(point(*b))
        line.SetLayer(p.Edge_Cuts); line.SetWidth(p.FromMM(0.05)); board.Add(line)
    for layer in [p.In1_Cu, p.In2_Cu]:
        zone = p.ZONE(board)
        zone.SetLayer(layer); zone.SetNet(netmap["GND"])
        zone.SetLocalClearance(p.FromMM(0.2)); zone.SetMinThickness(p.FromMM(0.15))
        zone.SetPadConnection(p.ZONE_CONNECTION_THERMAL)
        zone.SetThermalReliefGap(p.FromMM(0.25)); zone.SetThermalReliefSpokeWidth(p.FromMM(0.5))
        zone.SetIslandRemovalMode(p.ISLAND_REMOVAL_MODE_ALWAYS)
        outline = zone.Outline(); outline.NewOutline()
        for at in [(0.3, 0.3), (W-0.3, 0.3), (W-0.3, H-0.3), (0.3, H-0.3)]:
            v = point(*at); outline.Append(v.x, v.y)
        board.Add(zone)
    # Leave critical routing to the explicit geometry below, never autoroute USB.
    placed = out / f"screen_power_{variant}.placed.kicad_pcb"
    board.Save(str(placed))
    coords = {ref: {pad.GetNumber(): list(xy(pad.GetPosition())) for pad in fp.Pads() if pad.GetNumber()}
              for ref, fp in fps.items()}
    (out / "pad_positions.json").write_text(json.dumps(coords, indent=2) + "\n")
    print(f"Placed {len(fps)} components: {placed}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("variant", choices=["hand", "factory"])
    build(parser.parse_args().variant)
