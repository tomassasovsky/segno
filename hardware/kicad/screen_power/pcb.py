"""Place components for the hand-soldered screen-power board.

Run with KiCad's Python. The placed board never overwrites a routed deliverable.
Low-priority remaining connections may subsequently use Freerouting.
"""
import argparse
import json
import math
import os
from pathlib import Path
import sys

import pcbnew as p

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from netlist import parse_netlist

FPDIR = Path(os.environ.get("KICAD_FOOTPRINT_DIR", "/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints"))
from layout import CORNER_RADIUS, DIMENSIONS, place_components


def point(x, y):
    return p.VECTOR2I(p.FromMM(x), p.FromMM(y))


def xy(position):
    return (p.ToMM(position.x), p.ToMM(position.y))


def set_outline(board, variant):
    """Use tangent corner arcs, matching the console board's outline method."""
    w, h = DIMENSIONS[variant]
    r = CORNER_RADIUS
    for item in list(board.GetDrawings()):
        if item.GetLayer() == p.Edge_Cuts:
            board.RemoveNative(item)
    for start, end in [((r, 0), (w-r, 0)), ((w, r), (w, h-r)),
                       ((w-r, h), (r, h)), ((0, h-r), (0, r))]:
        line = p.PCB_SHAPE(board, p.SHAPE_T_SEGMENT)
        line.SetStart(point(*start)); line.SetEnd(point(*end))
        line.SetLayer(p.Edge_Cuts); line.SetWidth(p.FromMM(0.05))
        board.Add(line)
    for center, start, end in [((r, r), (0, r), (r, 0)),
                               ((w-r, r), (w-r, 0), (w, r)),
                               ((w-r, h-r), (w, h-r), (w-r, h)),
                               ((r, h-r), (r, h), (0, h-r))]:
        arc = p.PCB_SHAPE(board, p.SHAPE_T_ARC)
        arc.SetCenter(point(*center)); arc.SetStart(point(*start)); arc.SetEnd(point(*end))
        arc.SetLayer(p.Edge_Cuts); arc.SetWidth(p.FromMM(0.05))
        board.Add(arc)


def protect_mounting_hardware(board, width, height):
    # Keep copper clear of M3 screw heads and washers up to 7 mm OD,
    # including hole/bolt eccentricity. The NPTH drill alone is insufficient.
    for cx, cy in ((4, 4), (width-4, 4), (4, height-4), (width-4, height-4)):
        for layer in (p.F_Cu, p.B_Cu):
            area = p.ZONE(board)
            area.SetLayer(layer); area.SetIsRuleArea(True)
            area.SetDoNotAllowTracks(True); area.SetDoNotAllowVias(True)
            area.SetDoNotAllowZoneFills(True)
            area.SetDoNotAllowPads(False); area.SetDoNotAllowFootprints(False)
            outline = area.Outline(); outline.NewOutline()
            for i in range(64):
                angle = i*math.tau/64
                v = point(cx+4.25*math.cos(angle), cy+4.25*math.sin(angle))
                outline.Append(v.x, v.y)
            board.Add(area)


def build(variant):
    W, H = DIMENSIONS[variant]
    out = HERE / variant
    components, nets = parse_netlist(out / f"screen_power_{variant}.net")
    board = p.BOARD()
    ds = board.GetDesignSettings()
    ds.SetCopperLayerCount(2)
    ds.m_MinClearance = p.FromMM(0.15)
    ds.m_TrackMinWidth = p.FromMM(0.15)
    ds.m_ViasMinSize = p.FromMM(0.6)
    ds.m_MinThroughDrill = p.FromMM(0.3)
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
        # Nominal drills include JLCPCB's -0.08 mm finished-hole tolerance.
        # Larger XH/VH holes also ease hand insertion into rigid FR-4.
        drill = (1.10 if name.startswith("JST_XH_") else
                 1.80 if name.startswith("JST_VH_") else
                 .95 if name == "TO-92_Inline_Wide" else
                 .90 if name in ("DIP-8_W7.62mm", "DIP-4_W7.62mm") else None)
        # The TLP627M's maximum rectangular lead diagonal is 0.695 mm;
        # 0.90 mm DIP drills retain insertion room at the hole tolerance.
        if drill:
            for pad in fp.Pads():
                pad.SetDrillSize(point(drill, drill))
        # Every populated component has a bundled model. Keep model placement
        # from the library, but resolve files relative to this project.
        if not ref.startswith("H"):
            models = list(fp.Models())
            if not models:
                model = p.FP_3DMODEL()
                model.m_Filename = name + ".step"
                models = [model]
            fp.Models().clear()
            for model in models:
                filename = Path(model.m_Filename).name
                if ref == "C2":
                    filename = "Panasonic_EEUFR1A221.step"
                elif ref in ("C102", "C202"):
                    filename = "Panasonic_EEUFR1A151.step"
                elif ref in ("C3", "C4"):
                    filename = "Panasonic_ECEA1EN100U.step"
                elif ref in ("C1", "C5", "C101", "C201"):
                    filename = "WIMA_MKS2C031001A00KSSD.step"
                elif ref == "R8":
                    filename = "Vishay_PR01_P10.16mm.step"
                if not (HERE / "models" / filename).is_file():
                    raise ValueError(f"3D model missing for {ref}: {filename}")
                model.m_Filename = "${KIPRJMOD}/../models/" + filename
                fp.Add3DModel(model)
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

    set_outline(board, variant)
    protect_mounting_hardware(board, W, H)
    for layer in [p.F_Cu, p.B_Cu]:
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
    parser.add_argument("variant", choices=["hand"], nargs="?", default="hand")
    build(parser.parse_args().variant)
