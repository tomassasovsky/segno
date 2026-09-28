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
from silkscreen import finish_footprint

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


def ground_outline(width, height):
    """Tangent pour ends where the board edge meets each washer clearance.

    The circular hardware keepouts remain independent DRC rules. This contour
    only removes their otherwise pointed intersections with the pour boundary;
    0.75 mm end fillets join a 4.55 mm clearance arc without thin copper tips.
    """
    edge, centre, clearance, radius = .3, 4., 4.55, .75
    tangent = centre + math.sqrt((clearance + radius)**2
                                - (centre - edge - radius)**2)
    small_top = (tangent, edge + radius)
    a = (centre + (tangent-centre)*clearance/(clearance+radius),
         centre + (edge+radius-centre)*clearance/(clearance+radius))
    b = (a[1], a[0])
    def arc(c, r, start, end, count):
        return [(c[0]+r*math.cos(start+(end-start)*i/count),
                 c[1]+r*math.sin(start+(end-start)*i/count))
                for i in range(count+1)]
    theta = math.atan2(a[1]-small_top[1], a[0]-small_top[0])-math.tau
    sector = arc(small_top, radius, -math.pi/2, theta, 20)
    a0 = math.atan2(a[1]-centre, a[0]-centre)
    a1 = math.atan2(b[1]-centre, b[0]-centre)
    sector += arc((centre,centre), clearance, a0, a1, 48)[1:]
    start = math.atan2(b[1]-tangent, b[0]-edge-radius)
    sector += arc((edge+radius,tangent), radius, start, -math.pi, 20)[1:]
    return ([(width-x,y) for x,y in sector]
            + [(width-x,height-y) for x,y in reversed(sector)]
            + [(x,height-y) for x,y in sector]
            + list(reversed(sector)))



def trim_control_corner_pour(board):
    """Round the two dead-end GND wedges between H1 and the control trace.

    These front-only pour exclusions carry 0.4 mm tangent caps. Their centres
    touch both the 4.55 mm washer contour and the local control clearance; the
    closure lies in already-clear space. Tracks, vias, pads and the rear plane
    remain allowed, so this removes only the visually pointed ground ends.
    """
    radius=.4
    for x,closing_x,upper in ((8.5195,9.02,True),(8.0347,8.7,False)):
        y=4+(-1 if upper else 1)*math.sqrt((4.55+radius)**2-(x-4)**2)
        angle=math.atan2(4-y,4-x)
        outline=[(x+radius*math.cos(angle*i/40),
                  y+radius*math.sin(angle*i/40)) for i in range(41)]
        closing_y=3.5 if upper else 4.3
        outline += [(7.8,closing_y),(closing_x,closing_y),(closing_x,y)]
        area=p.ZONE(board);area.SetLayer(p.F_Cu);area.SetIsRuleArea(True)
        area.SetZoneName('GROUND_TIP_CLEARANCE')
        area.SetDoNotAllowTracks(False);area.SetDoNotAllowVias(False)
        area.SetDoNotAllowZoneFills(True);area.SetDoNotAllowPads(False)
        area.SetDoNotAllowFootprints(False)
        poly=area.Outline();poly.NewOutline()
        for at in outline:
            v=point(*at);poly.Append(v.x,v.y)
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
    ds.m_MinSilkTextHeight = p.FromMM(1.0)
    ds.m_MinSilkTextThickness = p.FromMM(0.15)
    ds.m_SilkClearance = p.FromMM(0.15)
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
                 .95 if name == "TO-92_Inline_Wide" else None)
        if drill:
            for pad in fp.Pads():
                pad.SetDrillSize(point(drill, drill))
        # Every populated component has a bundled model. Keep model placement
        # from the library, but resolve files relative to this project.
        shield_pad = (ref in ("TP101", "TP102", "TP201", "TP202") and
                      name == "TestPoint_THTPad_D2.0mm_Drill1.0mm")
        if not ref.startswith("H") and not shield_pad:
            models = list(fp.Models())
            if not models:
                model = p.FP_3DMODEL()
                model.m_Filename = name + ".step"
                models = [model]
            fp.Models().clear()
            for model in models:
                filename = Path(model.m_Filename).name
                # The other footprints already name a bundled model file; only
                # the parts whose exact body differs from the library preview
                # are redirected here.
                if ref == "C2":
                    filename = "Panasonic_EEUFR1A221.step"
                elif ref in ("C102", "C202"):
                    filename = "Panasonic_EEUFR1A151.step"
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
        finish_footprint(fp)
        fp.Reference().SetTextSize(point(1.0, 1.0))
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
        for at in ground_outline(W, H):
            v = point(*at); outline.Append(v.x, v.y)
        board.Add(zone)
    trim_control_corner_pour(board)
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
