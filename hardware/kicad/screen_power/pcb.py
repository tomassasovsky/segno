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
from layout import DIMENSIONS, place_components


def point(x, y):
    return p.VECTOR2I(p.FromMM(x), p.FromMM(y))


def xy(position):
    return (p.ToMM(position.x), p.ToMM(position.y))


def build(variant):
    W, H = DIMENSIONS[variant]
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

    place_components(variant, place, fps)
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
