"""Validate delivered screen-power boards with KiCad's Python and CLI.

Usage: python3 check.py [hand] [--output report.json] [--self-test]
KICAD_CLI may select another KiCad 10 executable. Reports describe CAD checks,
not hardware qualification. No generated board or schematic is modified.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import pcbnew as p

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from netlist import parse_netlist
from models import check_models

CLI = os.environ.get(
    "KICAD_CLI", "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
)
# Keep owners alive while SWIG pad/track wrappers are used by later checks.
_BOARDS = []


def load_board(path):
    board = p.LoadBoard(str(path))
    _BOARDS.append(board)
    return board


def net_name(name):
    return str(name).lstrip("/")


def semantic_nets(nets):
    """Ignore only nonphysical flags and explicitly unconnected terminals."""
    result = {}
    for raw, nodes in nets.items():
        name = net_name(raw)
        if name == "NC" or name.startswith("unconnected-("):
            continue
        physical = {node for node in nodes if not node[0].startswith("#FLG")}
        if physical:
            if name in result:
                raise ValueError(f"Ambiguous normalized net name: {name}")
            result[name] = physical
    return result


def pin_map(nets):
    result = {}
    for name, nodes in nets.items():
        for node in nodes:
            if node in result:
                raise ValueError(f"Pin {node} occurs in multiple nets")
            result[node] = name
    return result


def fail(errors, code, detail):
    errors.append({"check": code, "detail": detail})


def check_pad_map(board, components, expected, errors):
    actual = {}
    refs = []
    for fp in board.GetFootprints():
        ref = fp.GetReference()
        refs.append(ref)
        wanted = components.get(ref)
        if wanted and fp.GetFPIDAsString().split(":")[-1] != wanted[1]:
            fail(errors, "footprint", f"{ref}: footprint differs from generated netlist")
        for pad in fp.Pads():
            number = pad.GetNumber()
            name = net_name(pad.GetNetname())
            if not number:
                if name:
                    fail(errors, "pad_map", f"{ref}: unnumbered pad carries {name}")
                continue
            key = (ref, number)
            wanted_net = expected.get(key, "")
            if name != wanted_net:
                fail(errors, "pad_map", f"{ref}.{number}: {name!r}, expected {wanted_net!r}")
            if name:
                actual[key] = name
    if len(refs) != len(set(refs)):
        fail(errors, "components", "Duplicate PCB references")
    if set(refs) != set(components):
        fail(errors, "components", f"Missing {sorted(set(components)-set(refs))}; extra {sorted(set(refs)-set(components))}")
    missing = sorted(set(expected) - set(actual))
    if missing:
        fail(errors, "pad_map", f"Missing connected PCB pads: {missing}")


def check_contract(variant, pins, nets, errors):
    """Check independent pin-level power and touch supply boundaries."""
    def require(ref, mapping):
        for pin, name in mapping.items():
            actual = pins.get((ref, str(pin)))
            if actual != name:
                fail(errors, "circuit_contract", f"{ref}.{pin}: {actual!r}, required {name}")
    def nodes(name, expected):
        if nets.get(name) != expected:
            fail(errors, "supply_boundary", f"{name}: unexpected terminals {nets.get(name)}")
    require("J1", {1:"AUX_5V", 2:"GND"})
    require("J2", {1:"PI_GPIO17", 2:"GND"})
    nodes("PI_GPIO17", {("J2","1"),("R1","1")})
    require("R1", {1:"PI_GPIO17",2:"CONTROL_BASE"})
    require("R2", {1:"CONTROL_BASE",2:"GND"})
    require("Q1", ({1:"GND",2:"CONTROL_BASE",3:"CONTROL_SINK"}))
    require("R3", {1:"GATE_SINK",2:"POWER_GATE"})
    require("R4", {1:"POWER_GATE",2:"COMMON_SOURCE"})
    require("R5", {1:"CONTROL_SINK",2:"BUFFER_BASE"})
    require("R6", {1:"AUX_5V",2:"BUFFER_BASE"})
    require("R7", {1:"DATA_ENABLE",2:"GND"})
    require("R8", {1:"SWITCHED_5V",2:"GND"})
    require("R9", {1:"AUX_5V",2:"GATE_LED"})
    require("R10", {1:"GATE_LED",2:"CONTROL_SINK"})
    require("U1", {2:"PUMP_CAP_PLUS",3:"GND",4:"PUMP_CAP_MINUS",5:"NEG_5V",8:"AUX_5V"})
    if any(("U1", pin) in pins for pin in ("1", "6", "7")):
        fail(errors, "pump_controls", "U1 NC, LV and OSC must remain unconnected at 5V")
    require("U2", {1:"GATE_LED",2:"CONTROL_SINK",3:"NEG_5V",4:"GATE_SINK"})
    require("C3", {1:"PUMP_CAP_PLUS",2:"PUMP_CAP_MINUS"})
    require("C4", {1:"GND",2:"NEG_5V"})
    require("C5", {1:"AUX_5V",2:"GND"})
    require("D2", {1:"GND",2:"NEG_5V"})
    nodes("NEG_5V", {("U1","5"),("U2","3"),("C4","2"),("D2","2")})
    nodes("GATE_SINK", {("U2","4"),("R3","1")})
    nodes("GATE_LED", {("U2","1"),("R9","2"),("R10","1")})
    nodes("PUMP_CAP_PLUS", {("U1","2"),("C3","1")})
    nodes("PUMP_CAP_MINUS", {("U1","4"),("C3","2")})
    require("Q2", ({1:"AUX_5V",2:"BUFFER_BASE",3:"DATA_ENABLE"}))
    for ref, drain in (("Q3","AUX_5V"),("Q4","SWITCHED_5V")):
        require(ref, {1:"POWER_GATE",2:drain,3:"COMMON_SOURCE"})
    nodes("COMMON_SOURCE", {("Q3","3"),("Q4","3"),("R4","2")})
    nodes("POWER_GATE", {("Q3","1"),("Q4","1"),("R3","2"),("R4","1")})
    nodes("CONTROL_SINK", {("Q1","3"),("R5","1"),("U2","2"),("R10","2")})
    for ch in (1,2):
        n=100*ch; pre=f"S{ch}"; host=f"HOST{ch}_5V"; coil=f"{pre}_DATA_COIL_LOW"
        for offset, rail, side in ((1,host,"UP"),(2,pre+"_TOUCH_5V","DN")):
            require(f"J{n+offset}", {1:rail,2:pre+f"_{side}_N",3:pre+f"_{side}_P",4:"GND"})
        require(f"J{n+3}", {1:pre+"_MAIN_5V",2:"GND"})
        require(f"F{n+1}", {1:"SWITCHED_5V",2:pre+"_MAIN_5V"})
        require(f"F{n+2}", {1:"SWITCHED_5V",2:pre+"_TOUCH_5V"})
        require(f"K{n+1}", {1:host,8:coil,3:pre+"_UP_N",6:pre+"_UP_P",4:pre+"_DN_N",5:pre+"_DN_P"})
        if any((f"K{n+1}",pin) in pins for pin in ("2","7")):
            fail(errors,"relay_contacts",f"K{n+1}: normally closed and unused terminals must be unconnected")
        require(f"Q{n+1}", ({1:"GND",2:"DATA_ENABLE",3:coil}))
        require(f"D{n+1}", {1:host,2:coil})
        nodes(host, {(f"J{n+1}","1"),(f"K{n+1}","1"),(f"D{n+1}","1"),(f"C{n+1}","1")})
        for side, j, terminals in (("UP",n+1,{"P":6,"N":3}),("DN",n+2,{"P":5,"N":4})):
            for polarity, pin in (("P",3),("N",2)):
                nodes(f"{pre}_{side}_{polarity}",{(f"J{j}",str(pin)),(f"K{n+1}",str(terminals[polarity]))})


def check_relay_contacts(raw_nets, errors):
    """Exercise the IM contact mechanism against actual netlist connectivity.

    TE 108-98001 / KiCad IM00: off closes 3-2 and 6-7; energized closes
    3-4 and 6-5. Physical terminals are graph vertices, so absent pins and
    grouped no-connect markers never become a shared artificial net.
    """
    wiring = {}
    for raw, nodes in raw_nets.items():
        physical = [node for node in nodes if not node[0].startswith("#FLG")]
        for node in physical:
            wiring.setdefault(node, set())
        name = net_name(raw)
        if name == "NC" or name.startswith("unconnected-(") or not physical:
            continue
        for node in physical[1:]:
            wiring[physical[0]].add(node)
            wiring[node].add(physical[0])
    endpoints = {(f"J{100*ch+side}", pin) for ch in (1, 2)
                 for side in (1, 2) for pin in ("2", "3")}
    for node in endpoints | {(f"K{100*ch+1}", str(pin))
                             for ch in (1, 2) for pin in range(2, 8)}:
        wiring.setdefault(node, set())
    for energized in itertools.product((False, True), repeat=2):
        graph = {node: set(neighbors) for node, neighbors in wiring.items()}
        for ch, enabled in enumerate(energized, 1):
            relay = f"K{100*ch+1}"
            for common, throw in (("3", "4" if enabled else "2"),
                                  ("6", "5" if enabled else "7")):
                a, b = (relay, common), (relay, throw)
                graph[a].add(b); graph[b].add(a)
        for ch, pin in itertools.product((1, 2), ("2", "3")):
            source, target = (f"J{100*ch+1}", pin), (f"J{100*ch+2}", pin)
            reached, pending = set(), [source]
            while pending:
                node = pending.pop()
                if node not in reached:
                    reached.add(node)
                    pending.extend(graph[node] - reached)
            expected = {source, target} if energized[ch-1] else {source}
            actual = reached & endpoints
            if actual != expected:
                fail(errors, "relay_behavior", f"Coils {energized}, {source}: reached {sorted(actual)}, required {sorted(expected)}")
    return {"coil_states_checked": 4, "upstream_paths_checked": 16,
            "off_contacts": [[3, 2], [6, 7]], "on_contacts": [[3, 4], [6, 5]]}


def relay_contact_self_test(raw_nets):
    baseline = []
    check_relay_contacts(raw_nets, baseline)
    results = {"relay_contact_baseline_passes": not baseline}
    mutations = {
        "relay_old_host_pins_detected": {"2": "3", "3": "2", "6": "7", "7": "6"},
        "relay_wrong_throw_detected": {"2": "4", "4": "2", "5": "7", "7": "5"},
        "relay_polarity_swap_detected": {"4": "5", "5": "4"},
    }
    for name, mapping in mutations.items():
        changed = {net: [(ref, mapping.get(pin, pin) if ref == "K101" else pin)
                         for ref, pin in nodes] for net, nodes in raw_nets.items()}
        issues = []; check_relay_contacts(changed, issues)
        results[name] = not baseline and bool(issues)
    changed = {net: list(nodes) for net, nodes in raw_nets.items()}
    # Join actual connector nets, independent of their generated names.
    first = next(net for net, nodes in changed.items() if ("J101", "2") in nodes)
    second = next(net for net, nodes in changed.items() if ("J201", "2") in nodes)
    if first != second:
        changed[first].extend(changed.pop(second))
    issues = []; check_relay_contacts(changed, issues)
    results["relay_cross_channel_detected"] = not baseline and bool(issues)
    changed = {net: list(nodes) for net, nodes in raw_nets.items()
               if net_name(net) != "NC" and not net_name(net).startswith("unconnected-(")}
    changed["NC"] = [(f"K{100*ch+1}", pin) for ch in (1, 2) for pin in ("2", "7")]
    issues = []; check_relay_contacts(changed, issues)
    results["relay_no_connects_isolated"] = not baseline and not issues
    return results


def check_console_control(errors, board_path=None):
    """Check the actual main-board output, including its routed physical pads."""
    _, raw = parse_netlist(HERE.parent / "console_board.net")
    nets = semantic_nets(raw)
    pins = pin_map(nets)
    if pins.get(("J2", "11")) != "PI_GPIO17" or pins.get(("J25", "1")) != "PI_GPIO17" or pins.get(("J25", "2")) != "GND":
        fail(errors, "console_control", "Console J25 must carry physical Pi pin 11 / GPIO17 on 1 and GND on 2")
    board = load_board(board_path or HERE.parent / "out_console/segno_console_board.kicad_pcb")
    required = {("J2", "11"): "PI_GPIO17", ("J25", "1"): "PI_GPIO17", ("J25", "2"): "GND"}
    actual = {(f.GetReference(), pad.GetNumber()): net_name(pad.GetNetname())
              for f in board.GetFootprints() for pad in f.Pads() if (f.GetReference(), pad.GetNumber()) in required}
    if actual != required:
        fail(errors, "console_control", "Console PCB pads disagree with the two-wire harness")
    connected = board.GetConnectivity()
    connected.Build(board)
    terminals = {(f.GetReference(), pad.GetNumber()): pad for f in board.GetFootprints()
                 for pad in f.Pads() if (f.GetReference(), pad.GetNumber()) in required}
    if ("J2", "11") in terminals and ("J25", "1") in terminals:
        reached = {item.m_Uuid.AsString() for item in connected.GetConnectedItems(terminals[("J2", "11")])}
        if terminals[("J25", "1")].m_Uuid.AsString() not in reached:
            fail(errors, "console_control", "Console GPIO17 copper does not connect J2.11 to J25.1")


def check_geometry(board, errors, variant):
    from layout import CORNER_RADIUS, DIMENSIONS
    w, h = DIMENSIONS[variant]
    r = CORNER_RADIUS
    if board.GetCopperLayerCount() != 2:
        fail(errors, "geometry", "Board must have exactly two copper layers")
    edges = [d for d in board.GetDrawings() if d.GetLayer() == p.Edge_Cuts]
    expected = {frozenset((a, b)) for a, b in (
        ((r, 0), (w-r, 0)), ((w, r), (w, h-r)),
        ((w-r, h), (r, h)), ((0, h-r), (0, r)))}
    actual = {frozenset((tuple(round(p.ToMM(v), 5) for v in (d.GetStart().x, d.GetStart().y)),
                         tuple(round(p.ToMM(v), 5) for v in (d.GetEnd().x, d.GetEnd().y))))
              for d in edges if d.GetShape() == p.SHAPE_T_SEGMENT}
    arcs = [d for d in edges if d.GetShape() == p.SHAPE_T_ARC]
    centers = {(round(p.ToMM(a.GetCenter().x), 5), round(p.ToMM(a.GetCenter().y), 5)) for a in arcs}
    endpoints = [tuple(round(p.ToMM(v), 5) for v in (point.x, point.y))
                 for d in edges for point in (d.GetStart(), d.GetEnd())]
    if (len(edges) != 8 or actual != expected or len(arcs) != 4
            or centers != {(r, r), (w-r, r), (r, h-r), (w-r, h-r)}
            or any(abs(p.ToMM(a.GetRadius())-r) > 0.00001
                   or abs(abs(a.GetArcAngle().AsDegrees())-90) > 0.0001 for a in arcs)
            or any(endpoints.count(point) != 2 for point in endpoints)):
        fail(errors, "geometry", f"Edge.Cuts must be the closed {w} × {h} mm outline with R{r} corners")
    zones = [z for z in board.Zones() if not z.GetIsRuleArea()]
    ground = [z for z in zones if net_name(z.GetNetname()) == "GND"]
    if {z.GetLayer() for z in ground} != {p.F_Cu, p.B_Cu}:
        fail(errors, "ground_planes", "Both outer layers need GND pours")
    power_layers = {"AUX_5V": {p.F_Cu}, "COMMON_SOURCE": {p.F_Cu},
                    "SWITCHED_5V": {p.F_Cu, p.B_Cu}}
    for zone in zones:
        net,layer=net_name(zone.GetNetname()),zone.GetLayer()
        if zone.GetZoneName()=="POWER_FILLET":
            allowed=net=="AUX_5V" and layer==p.F_Cu
        else:
            allowed=(net=="GND" or (zone.GetZoneName()=="POWER_TAPER"
                     and layer in power_layers.get(net,set())))
        if layer not in (p.F_Cu,p.B_Cu) or not allowed:
            fail(errors,"ground_planes","Only outer GND pours, approved power tapers and AUX front branch fillets are allowed")
    if any(not z.GetFilledPolysList(z.GetLayer()).OutlineCount() for z in zones):
        fail(errors, "ground_planes", "All GND pours and power overlays must be filled")
    for track in board.GetTracks():
        if not isinstance(track, p.PCB_VIA) and track.GetLayer() not in (p.F_Cu, p.B_Cu):
            fail(errors, "ground_planes", "Copper exists outside the two outer layers")


def check_relay_holes(board, errors):
    # TE 108-98001 minimum PCB drill is 0.75 mm for standard THT IM.
    for fp in board.GetFootprints():
        if fp.GetReference() not in ("K101", "K201"):
            continue
        for pad in fp.Pads():
            if pad.GetAttribute() != p.PAD_ATTRIB_PTH or min(pad.GetDrillSize().x, pad.GetDrillSize().y) < p.FromMM(.75+.08):
                fail(errors,"relay_assembly",f"{fp.GetReference()}.{pad.GetNumber()}: IM02TS requires at least 0.75 mm after -0.08 mm hole tolerance")


def check_mounting_clearance(board, errors):
    """A metal fastener can short copper well outside the drilled hole."""
    holes=[f for f in board.GetFootprints() if f.GetReference().startswith('H')]
    for hole in holes:
        c=next(iter(hole.Pads())).GetPosition()
        for t in board.GetTracks():
            a,b=t.GetStart(),t.GetEnd()
            dx,dy=b.x-a.x,b.y-a.y
            length2=dx*dx+dy*dy
            u=max(0,min(1,((c.x-a.x)*dx+(c.y-a.y)*dy)/length2)) if length2 else 0
            clearance=p.ToMM(math.hypot(c.x-a.x-u*dx,c.y-a.y-u*dy)-t.GetWidth()/2)
            if clearance < 4.20:
                fail(errors,'mounting_clearance',f'{hole.GetReference()}: {t.GetNetname()} copper only {clearance:.3f} mm from M3 center')


def check_usb_headers(board, errors):
    """Verify the chosen cable interface against JST's XH drawing."""
    for fp in board.GetFootprints():
        if fp.GetReference() not in ("J101", "J102", "J201", "J202"):
            continue
        pads = {pad.GetNumber(): pad for pad in fp.Pads()}
        if set(pads) != {"1", "2", "3", "4"}:
            fail(errors, "usb_header", f"{fp.GetReference()}: expected four XH terminals")
            continue
        for number, pad in pads.items():
            if pad.GetAttribute() != p.PAD_ATTRIB_PTH or min(pad.GetDrillSize().x, pad.GetDrillSize().y) < p.FromMM(.9):
                fail(errors, "usb_header", f"{fp.GetReference()}.{number}: XH requires at least 0.9 mm plated holes")
        for a, b in (("1", "2"), ("2", "3"), ("3", "4")):
            delta = pads[a].GetPosition() - pads[b].GetPosition()
            if abs(math.hypot(delta.x, delta.y) - p.FromMM(2.5)) > 1:
                fail(errors, "usb_header", f"{fp.GetReference()}: XH pitch must be 2.50 mm")


def check_usb(board, errors, variant="hand"):
    """Check physical connectivity, not just matching net labels."""
    from layout import USB_WIDTH
    connectivity = board.GetConnectivity()
    connectivity.Build(board)
    lengths = {}
    for ch, side, polarity in itertools.product((1, 2), ("UP", "DN"), ("P", "N")):
        name = f"S{ch}_{side}_{polarity}"
        tracks = [t for t in board.GetTracks() if net_name(t.GetNetname()) == name]
        pads = [pad for fp in board.GetFootprints() for pad in fp.Pads()
                if net_name(pad.GetNetname()) == name]
        if not tracks or len(pads) != 2:
            fail(errors, "usb_connectivity", f"{name}: missing tracks or expected physical endpoints")
        elif pads:
            reached = {item.m_Uuid.AsString() for item in connectivity.GetConnectedItems(pads[0])}
            reached.add(pads[0].m_Uuid.AsString())
            if any(pad.m_Uuid.AsString() not in reached for pad in pads):
                fail(errors, "usb_connectivity", f"{name}: physically disconnected USB pads")
        length = 0
        for track in tracks:
            if isinstance(track, p.PCB_VIA):
                fail(errors, "usb_geometry", f"{name}: data via is prohibited")
                continue
            if track.GetLayer() != p.B_Cu or abs(p.ToMM(track.GetWidth()) - USB_WIDTH) > 0.00001:
                fail(errors, "usb_geometry", f"{name}: data must use {USB_WIDTH} mm B.Cu tracks")
            length += p.ToMM(track.GetLength())
        lengths[name] = round(length, 6)
    for ch, side in itertools.product((1, 2), ("UP", "DN")):
        name = f"S{ch}_{side}"
        skew = abs(lengths[name + "_P"] - lengths[name + "_N"])
        if skew > 2:
            fail(errors, "usb_skew", f"{name}: {skew:.3f} mm exceeds 2 mm")
    return lengths


def check_usb_reference(board, errors):
    """Sample actual filled F.Cu under each B.Cu trace, including fanouts.

    The 1.35 mm terminal exclusion covers the through-hole pad and its
    unavoidable antipad. It does not exempt crossings elsewhere on a route.
    Native DRC separately checks GND connectivity and fabrication clearance.
    """
    from pcb import point, xy
    planes = [z.GetFilledPolysList(p.F_Cu) for z in board.Zones()
              if not z.GetIsRuleArea() and z.GetLayer() == p.F_Cu
              and net_name(z.GetNetname()) == "GND"]
    names = {f"S{ch}_{side}_{pol}" for ch in (1, 2)
             for side in ("UP", "DN") for pol in ("P", "N")}
    checked = 0
    for name in sorted(names):
        pads = [xy(pad.GetPosition()) for fp in board.GetFootprints()
                for pad in fp.Pads() if net_name(pad.GetNetname()) == name]
        missing = []
        for track in board.GetTracks():
            if net_name(track.GetNetname()) != name or isinstance(track, p.PCB_VIA):continue
            a, b = xy(track.GetStart()), xy(track.GetEnd())
            length = math.dist(a, b)
            if not length:continue
            nx, ny = -(b[1]-a[1])/length, (b[0]-a[0])/length
            steps = max(1, math.ceil(length/.1))
            for i in range(steps+1):
                for offset in (-p.ToMM(track.GetWidth())/2, 0, p.ToMM(track.GetWidth())/2):
                    at = (a[0]+(b[0]-a[0])*i/steps+nx*offset,
                          a[1]+(b[1]-a[1])*i/steps+ny*offset)
                    if any(math.dist(at, pad)<1.35 for pad in pads):continue
                    checked += 1
                    if not any(plane.Contains(point(*at)) for plane in planes):missing.append(at)
        if missing:
            fail(errors, "usb_reference", f"{name}: {len(missing)} samples lack F.Cu GND; first at {missing[0]}")
    return {"samples": checked, "interval_mm": .1, "terminal_exclusion_mm": 1.35,
            "sample_offsets": "centerline and both copper edges"}


def check_power(board_path, errors, variant):
    """Require continuous copper at the specified minimum power-path width.

    Remove every zone, thin control branch and single signal via on fresh
    copies. KiCad then proves the tracks connect the physical pads without
    relying on a filled overlay to bridge a missing or undersized track.
    This checks copper geometry, not its thermal/current rating.
    """
    paths=[(2.0,("J1","1"),("Q3","2")),(2.5,("Q3","3"),("Q4","3")),
           (1.5,("J1","1"),("C2","1")),(.8,("J1","1"),("C1","1"))]
    for ch in (1,2):
        n=ch*100
        paths += [(2.5,("Q4","2"),(f"F{n+i}","1")) for i in (1,2)]
        paths += [(2.0,(f"F{n+1}","2"),(f"J{n+3}","1")),
                  (.8,(f"F{n+2}","2"),(f"J{n+2}","1"))]
    for minimum in sorted({path[0] for path in paths}):
        board=load_board(board_path)
        for zone in list(board.Zones()):board.RemoveNative(zone)
        selected=[path for path in paths if path[0]==minimum]
        terminals={}
        for fp in board.GetFootprints():
            for pad in fp.Pads():
                key=(fp.GetReference(),pad.GetNumber())
                if key not in terminals or pad.GetSize().x*pad.GetSize().y > terminals[key].GetSize().x*terminals[key].GetSize().y:
                    terminals[key]=pad
        for item in list(board.GetTracks()):
            if isinstance(item,p.PCB_VIA) or item.GetWidth()<p.FromMM(minimum)-1:
                board.RemoveNative(item)
        connectivity=board.GetConnectivity();connectivity.Build(board)
        for _,a,b in selected:
            reached={item.m_Uuid.AsString() for item in connectivity.GetConnectedItems(terminals[a])}
            if terminals[b].m_Uuid.AsString() not in reached:
                fail(errors,"power_copper",f"{a} → {b}: no continuous {minimum} mm copper path")
    board=load_board(board_path)
    # These main runs have a uniform-width contract. AUX's capacitor branches
    # remain 1.5/0.8 mm; R4/R8 use 0.25 mm branches on their power nets. The
    # front distribution bus and fuse feeds retain their wider copper.
    # Each entry gives the largest branch excluded, then the main-run width.
    uniform_runs={("AUX_5V",p.F_Cu):(1.5,2.0),
                  ("COMMON_SOURCE",p.F_Cu):(.25,2.5),
                  ("SWITCHED_5V",p.B_Cu):(.25,2.5)}
    for track in board.GetTracks():
        if isinstance(track,p.PCB_VIA):continue
        rule=uniform_runs.get((net_name(track.GetNetname()),track.GetLayer()))
        if rule and track.GetWidth()>p.FromMM(rule[0])+1 and abs(track.GetWidth()-p.FromMM(rule[1]))>1:
            fail(errors,"uniform_power_width",f"{net_name(track.GetNetname())} {track.GetLayerName()}: power run must stay {rule[1]} mm wide")
    for zone in list(board.Zones()):
        key=(net_name(zone.GetNetname()),zone.GetLayer())
        branch_fillet=key==("AUX_5V",p.F_Cu) and zone.GetZoneName()=="POWER_FILLET"
        if (not zone.GetIsRuleArea()
                and key in uniform_runs and not branch_fillet):
            fail(errors,"uniform_power_taper",f"{net_name(zone.GetNetname())} {zone.GetLayerName()}: uniform power run must not have a taper overlay")
        board.RemoveNative(zone)
    terminals={(fp.GetReference(),pad.GetNumber()):pad
               for fp in board.GetFootprints() for pad in fp.Pads()}
    tracks=[t for t in board.GetTracks() if not isinstance(t,p.PCB_VIA)
            and net_name(t.GetNetname())=="SWITCHED_5V" and t.GetWidth()>=p.FromMM(2.5)-1]
    connectivity=board.GetConnectivity();connectivity.Build(board)
    required={terminals[key].m_Uuid.AsString() for key in (("Q4","2"),("F201","1"))}
    dedicated=set()
    for via in board.GetTracks():
        if (not isinstance(via,p.PCB_VIA) or net_name(via.GetNetname())!="SWITCHED_5V"
                or via.GetViaType()!=p.VIATYPE_THROUGH or via.GetDrillValue()<p.FromMM(.45)-1):
            continue
        # A via must land inside wide copper on each face, and belong to the
        # physical device-to-distribution path; spare or dangling vias do not count.
        c=via.GetPosition();layers=set()
        for track in tracks:
            a,b=track.GetStart(),track.GetEnd();dx,dy=b.x-a.x,b.y-a.y
            length2=dx*dx+dy*dy
            u=max(0,min(1,((c.x-a.x)*dx+(c.y-a.y)*dy)/length2)) if length2 else 0
            if math.hypot(c.x-a.x-u*dx,c.y-a.y-u*dy)<=track.GetWidth()/2:
                layers.add(track.GetLayer())
        reached={item.m_Uuid.AsString() for item in connectivity.GetConnectedItems(via)}
        if {p.F_Cu,p.B_Cu}<=layers and required<=reached:
            dedicated.add(via.m_Uuid.AsString())
    if len(dedicated)<3:
        fail(errors,"power_vias",f"Shared SWITCHED_5V transition needs 3 connected through vias with at least 0.45 mm drills; found {len(dedicated)}")
    # Prove the added vias actually bypass the fuse barrel. A via on a top
    # island can otherwise reach both endpoints by returning to the bottom
    # feeder and crossing the original F101 plated pad.
    fuse=next(fp for fp in board.GetFootprints() if fp.GetReference()=="F101")
    fuse.RemoveNative(terminals.pop(("F101","1")))
    for item in list(board.GetTracks()):
        if ((isinstance(item,p.PCB_VIA) and item.m_Uuid.AsString() not in dedicated)
                or (not isinstance(item,p.PCB_VIA) and item.GetWidth()<p.FromMM(2.5)-1)):
            board.RemoveNative(item)
    connectivity=board.GetConnectivity();connectivity.Build(board)
    reached={item.m_Uuid.AsString() for item in connectivity.GetConnectedItems(terminals[("Q4","2")])}
    if terminals[("F201","1")].m_Uuid.AsString() not in reached:
        fail(errors,"power_via_bypass","Qualifying SWITCHED_5V vias do not provide a continuous 2.5 mm Q4.2 to F201.1 path without the F101.1 barrel")


def resistor_value(components, ref):
    text = components[ref][2]
    match = re.match(r"^(\d+(?:\.\d+)?)\s*([kKMmR]?)", text)
    if not match:
        raise ValueError(f"Unrecognized resistor value {ref}: {text}")
    return float(match[1]) * {"": 1, "R": 1, "k": 1000, "K": 1000,
                             "M": 1000000, "m": 0.001}[match[2]]


def numerical_checks(variant, components, errors):
    r = {i: resistor_value(components,f"R{i}") for i in range(1,11)}
    if any(value<=0 for value in r.values()):
        fail(errors,"resistor_model","Control resistances must be positive")
        return {}
    if any("1%" not in components[f"R{i}"][2] for i in r):
        fail(errors,"resistor_model","Drive margins require 1% resistors")
    models={"Q1":"2N3904", "Q2":"2N3906", "U1":"LMC7660IN",
            "U2":"TLP627M", "D2":"BAT85S",
            "C3":"10uF 25V bipolar", "C4":"10uF 25V bipolar"}
    for ch in (1,2):
        n=100*ch
        models.update({f"Q{n+1}":"TN0702",f"K{n+1}":"IM02TS",
                       f"D{n+1}":("1N4007")})
    for ref,model in models.items():
        if components[ref][2]!=model:
            fail(errors,"driver_model",f"{ref}: calculations require {model}")
    # TLP627M specifies 20uA dark current at 85C. The smaller R4 keeps
    # that below 0.5V gate bias; other pulled nodes retain a 1uA allowance.
    dark_gate = r[4]*1.01*20e-6
    if dark_gate >= .5 or any(r[i]*1.01*1e-6 >= .5 for i in (6,7)):
        fail(errors,"default_off","Off-state leakage exceeds the 0.5V pull-up/down budget")
    # The 4.5V floor is a gate-driver design corner, not a screen-voltage
    # guarantee. 4.25A covers the documented screen planning load. Retain
    # the conservative -4.5V Rds rating despite the higher actual drive.
    aux_min, aux_max, load = 4.5, 5.25, 4.25
    hot_rds = .015*1.7
    v_source_min = aux_min - load*hot_rds
    gate_divider = (r[4]*.99)/(r[4]*.99+r[3]*1.01)
    negative_min = .9*aux_min
    gate_min = (v_source_min+negative_min-1.0)*gate_divider
    # A 2V optocoupler stress allowance is twice its 25C saturation spec.
    gate_stress = (v_source_min+negative_min-2.0)*gate_divider
    gate_max = 2*aux_max*(r[4]*1.01)/(r[4]*1.01+r[3]*.99)
    # Compare with TI's 10k / >=90% conversion test condition. The diode
    # hot allowance and catalog capacitor leakage are engineering budgets,
    # not manufacturer hot maxima. Additional voltage margin remains if
    # the negative rail sags further: see gate-drive.md.
    pump_load = (aux_min+negative_min)/((r[3]+r[4])*.99)+50e-6+2*10.5e-6
    pump_reference = negative_min/10000
    led_min = (aux_min-.2-1.4)/(r[9]*1.01)-1.4/(r[10]*.99)
    base_min = (2.4-.95)/(r[1]*1.01)-.95/(r[2]*.99)
    sink_peak = aux_max/(r[9]*.99)+aux_max/(r[5]*.99)
    pnp_base_min = (aux_min-.95-.2)/(r[5]*1.01)-.95/(r[6]*.99)
    pnp_load_max = 5.25/(r[7]*.99)+2e-6
    bleed_max = 5.25**2/(r[8]*.99)
    if (gate_stress < 4.5 or gate_max >= 20 or led_min < .001
            or base_min < sink_peak/10 or pnp_base_min < pnp_load_max/10
            or pump_load > pump_reference):
        fail(errors,"driver_margin","Insufficient gate or transistor drive in the stated envelope")
    if bleed_max > .5 or "1W" not in components['R8'][2]:
        fail(errors,"discharge","Bleeder must dissipate below 0.5W in its 1W part")
    model = ("SUP70101EL")
    for ref in ("Q3","Q4"):
        if components[ref][2] != model:
            fail(errors,"power_device",f"{ref}: calculations require {model}")
    for ch in (1,2):
        if components[f"F{ch*100+1}"][2] != "4A fast" or components[f"F{ch*100+2}"][2] != "750mA fast":
            fail(errors,"fuse_rating","Unexpected branch fuse rating")
    # TE 108-98001: initial pickup at 23 C, without pre-energization.
    # This does not qualify a warm coil or an elevated enclosure temperature.
    # TN0702 is specified at 3V drive. Double its 2.5ohm 25C maximum
    # for the same explicitly estimated hot margin used in this review.
    relay_coil_min = 4.75*(145*.9)/(145*.9+2*2.5)
    if relay_coil_min < 3.38:
        fail(errors,"relay_pickup","IM02TS initial coil voltage is below its 3.38V operate threshold")
    return {"aux_input_min_V":aux_min,"aux_input_max_V":aux_max,"combined_design_load_A":load,
            "aux_voltage_reference":"J1 gate-driver assessment; not a screen input-voltage guarantee",
            "gate_min_V_with_estimated_hot_Rds":gate_min,"hot_Rds_factor_is_estimate":1.7,
            "gate_V_with_2V_opto_stress_allowance":gate_stress,"gate_max_V":gate_max,
            "off_gate_V_at_opto_85C_dark_current":dark_gate,
            "opto_LED_min_mA":led_min*1000,
            "pump_engineering_load_uA":pump_load*1e6,"pump_10k_test_load_uA":pump_reference*1e6,
            "pump_hot_leakage_budget_is_estimate":True,
            "gpio_assumed_minimum_high_V":2.4,"gpio_base_min_mA":base_min*1000,
            "collector_peak_mA":sink_peak*1000,"bleeder_max_W":bleed_max,
            "pair_loss_at_planning_load_hot_estimate_W":2*load**2*hot_rds,
            "upright_junction_C_at_60C_75C_per_W_estimate":60+load**2*hot_rds*75,
            "relay_initial_coil_min_V":relay_coil_min,
            "relay_initial_pickup_margin_23C_V":relay_coil_min-3.38,
            "relay_coil_rated_V":4.5,
            "relay_coil_max_applied_over_rated_ratio":5.25/4.5,
            "relay_hot_restart":"measure coil voltage and qualify hot re-enable on first assembly",
            "host_relay_coil_nominal_mA":5000/145,
            "main_continuous_fuse_design_A":3,"touch_continuous_fuse_design_A":.5,
            "startup":"bounded SOA assessment in rev-l-1072/startup.md; no active current limiter",
            "assembled_qualification":"not performed; CAD and calculations do not establish USB compliance"}


def cli_run(args, errors, label):
    try:
        result = subprocess.run([CLI, *map(str, args)], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        fail(errors, label, str(exc))
        return None
    return result


def rule_check(kind, source, destination, errors):
    args = ["pcb" if kind == "drc" else "sch", kind, "--format", "json",
            "--severity-all", "--exit-code-violations", "--output", destination]
    if kind == "drc":
        args += ["--all-track-errors", "--refill-zones"]
    result = cli_run([*args, source], errors, kind)
    if not destination.exists():
        fail(errors, kind, "No fresh rule report produced" + (f": {result.stderr[-1000:]}" if result else ""))
        return {}
    report = json.loads(destination.read_text())
    findings = []

    def visit(value):
        if isinstance(value, dict):
            if "severity" in value and "description" in value:
                findings.append(value)
            else:
                for child in value.values():
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(report)
    counts = {severity: sum(f.get("severity") == severity for f in findings)
              for severity in ("error", "warning", "exclusion")}
    counts["unconnected"] = len(report.get("unconnected_items", []))
    counts["findings"] = len(findings)
    if findings or counts["unconnected"] or (result and result.returncode):
        fail(errors, kind, f"Fresh {kind.upper()} failed: {counts}; exit {result.returncode if result else 'unavailable'}")
    return {"counts": counts, "report": report}


def self_test(board_path, components, expected, temp, variant="hand"):
    _, raw_nets = parse_netlist(HERE / variant / f"screen_power_{variant}.net")
    results = relay_contact_self_test(raw_nets)
    altered = load_board(board_path)
    header = next(f for f in altered.GetFootprints() if f.GetReference() == "J101")
    terminal = next(pad for pad in header.Pads() if pad.GetNumber() == "2")
    terminal.SetPosition(terminal.GetPosition() + p.VECTOR2I(0, p.FromMM(.04)))
    header_errors = []
    check_usb_headers(altered, header_errors)
    results["wrong_xh_pitch_detected"] = any(e["check"] == "usb_header" for e in header_errors)
    for fault in ("unassigned", "missing", "disabled"):
        altered = load_board(board_path)
        fp = next(f for f in altered.GetFootprints() if f.GetReference() == "K101")
        model = list(fp.Models())[0]
        fp.Models().clear()
        if fault != "unassigned":
            if fault == "missing":
                model.m_Filename = "${KIPRJMOD}/missing-model.step"
            else:
                model.m_Show = False
            fp.Add3DModel(model)
        model_errors = []
        check_models(altered, HERE / variant, model_errors)
        results[f"model_{fault}_detected"] = any(e["check"] == "model_coverage" for e in model_errors)
    altered = load_board(board_path)
    relay = next(f for f in altered.GetFootprints() if f.GetReference() == "K101")
    next(iter(relay.Pads())).SetDrillSize(p.VECTOR2I(p.FromMM(.80),p.FromMM(.80)))
    hole_errors = []
    check_relay_holes(altered,hole_errors)
    results["relay_hole_detected"] = any(e["check"] == "relay_assembly" for e in hole_errors)
    console = load_board(HERE.parent / "out_console/segno_console_board.kicad_pcb")
    for item in list(console.GetTracks()):
        if net_name(item.GetNetname()) == "PI_GPIO17":
            console.RemoveNative(item)
    cut_console = temp / "cut-console-control.kicad_pcb"
    console.Save(str(cut_console))
    console_errors = []
    check_console_control(console_errors, cut_console)
    results["console_control_cut_detected"] = any(e["check"] == "console_control" for e in console_errors)
    from hand_checks import check_through_hole
    for ref,old_drill in [('J101',.95),('J2',1.0),('J1',1.7),('Q1',.8),('H1',3.2),('U1',.8),('U2',.8)]:
        altered=load_board(board_path)
        fp=next(f for f in altered.GetFootprints() if f.GetReference()==ref)
        next(iter(fp.Pads())).SetDrillSize(p.VECTOR2I(p.FromMM(old_drill),p.FromMM(old_drill)))
        hole_errors=[];check_through_hole(altered,hole_errors)
        results[f'{ref}_hole_tolerance_detected']=any(e['check']=='hole_tolerance' for e in hole_errors)
    altered=load_board(board_path)
    t=p.PCB_TRACK(altered);t.SetStart(p.VECTOR2I(p.FromMM(64),p.FromMM(68)))
    t.SetEnd(p.VECTOR2I(p.FromMM(64),p.FromMM(69)));t.SetWidth(p.FromMM(3));t.SetLayer(p.F_Cu)
    t.SetNet(altered.GetNetsByName()['SWITCHED_5V']);altered.Add(t)
    mounting_errors=[];check_mounting_clearance(altered,mounting_errors)
    results['fastener_short_detected']=any(e['check']=='mounting_clearance' for e in mounting_errors)
    for mode in ("footprint", "pad"):
        altered = load_board(board_path)
        component = next(f for f in altered.GetFootprints() if f.GetReference() == "R1")
        if mode == "footprint":
            component.SetAttributes(component.GetAttributes() | p.FP_SMD)
        else:
            next(iter(component.Pads())).SetAttribute(p.PAD_ATTRIB_SMD)
        assembly_errors = []
        check_through_hole(altered, assembly_errors)
        results[f"smd_{mode}_detected"] = any(e["check"] == "hand_assembly" for e in assembly_errors)
    altered=load_board(board_path)
    device=next(f for f in altered.GetFootprints() if f.GetReference()=="Q3")
    next(iter(device.Pads())).SetDrillSize(p.VECTOR2I(p.FromMM(1.1),p.FromMM(1.1)))
    hole_errors=[];check_through_hole(altered,hole_errors)
    results["power_lead_hole_detected"]=any(e["check"]=="hand_assembly" for e in hole_errors)
    def numeric_mutation(ref,value):
        changed=dict(components)
        changed[ref]=(*components[ref][:2],value)
        issues=[];numerical_checks(variant,changed,issues)
        return bool(issues)
    results["wrong_relay_detected"]=numeric_mutation("K101","IM06TS")
    results["wrong_driver_detected"]=numeric_mutation("Q101","BS170")
    results["wrong_tolerance_detected"]=numeric_mutation("R3","4.7k 20%")
    results["weak_pulldown_detected"]=numeric_mutation("R7","100M 1%")
    results["weak_gate_pullup_detected"]=numeric_mutation("R4","330k 1%")
    results["weak_opto_drive_detected"]=numeric_mutation("R9","100k 1%")
    results["wrong_pump_detected"]=numeric_mutation("U1","ICL7660")
    results["polarized_pump_cap_detected"]=numeric_mutation("C4","10uF 25V polarized")
    # Check partial-power failure paths against independent pin contracts.
    # These mutations are electrical misconnections, not text-only matches.
    for name, replacements in (
            ("reversed_negative_clamp_detected", {("D2","1"):"NEG_5V",("D2","2"):"GND"}),
            ("pump_lv_grounded_detected", {("U1","6"):"GND"}),
            ("opto_output_reversed_detected", {("U2","3"):"GATE_SINK",("U2","4"):"NEG_5V"}),
            ("negative_gpio_bridge_detected", {("U2","3"):"PI_GPIO17"})):
        changed = dict(expected)
        changed.update(replacements)
        changed_nets = {}
        for terminal, name_net in changed.items():
            changed_nets.setdefault(name_net, set()).add(terminal)
        issues = []
        check_contract(variant, changed, changed_nets, issues)
        results[name] = bool(issues)
    narrowed=load_board(board_path)
    for track in narrowed.GetTracks():
        if not isinstance(track,p.PCB_VIA) and net_name(track.GetNetname())=="S1_MAIN_5V":
            track.SetWidth(p.FromMM(.15))
    narrow_path=temp/"narrow-power.kicad_pcb";narrowed.Save(str(narrow_path))
    power_errors=[];check_power(narrow_path,power_errors,variant)
    results["narrow_power_detected"]=any(e["check"]=="power_copper" for e in power_errors)
    for ref,number,width,name in (("Q3","2",1.5,"narrow_fet_neck_detected"),
                                  ("C2","1",.25,"narrow_bulk_feed_detected")):
        altered=load_board(board_path)
        terminal=next(pad for fp in altered.GetFootprints() if fp.GetReference()==ref
                      for pad in fp.Pads() if pad.GetNumber()==number)
        changed=False
        for track in altered.GetTracks():
            if isinstance(track,p.PCB_VIA):continue
            # Adjacent round end caps can still touch a pad when only its
            # terminal segment is narrowed. Narrow the complete target run.
            selected=(track.GetWidth()<=p.FromMM(1.5) if ref=="C2" else
                      track.GetLayer()==p.F_Cu and track.GetWidth()>p.FromMM(1.5)+1)
            if net_name(track.GetNetname())==net_name(terminal.GetNetname()) and selected:
                track.SetWidth(p.FromMM(width));changed=True
        target=temp/f"{name}.kicad_pcb";altered.Save(str(target))
        issues=[];check_power(target,issues,variant)
        results[name]=changed and any(e["check"]=="power_copper" and ref in e["detail"] for e in issues)
    for net,layer,ref,branch_width,width,name in (
            ("COMMON_SOURCE",p.F_Cu,"Q3",.25,2.49,"narrow_common_source_detected"),
            ("SWITCHED_5V",p.B_Cu,"Q4",.25,2.49,"narrow_switched_feed_detected"),
            ("AUX_5V",p.F_Cu,"Q3",1.5,1.99,"narrow_aux_main_detected")):
        altered=load_board(board_path);changed=False
        for track in altered.GetTracks():
            if (not isinstance(track,p.PCB_VIA) and net_name(track.GetNetname())==net
                    and track.GetLayer()==layer and track.GetWidth()>p.FromMM(branch_width)+1):
                track.SetWidth(p.FromMM(width));changed=True
        target=temp/f"{name}.kicad_pcb";altered.Save(str(target))
        issues=[];check_power(target,issues,variant)
        results[name]=changed and any(e["check"]=="power_copper" and ref in e["detail"] for e in issues)
    altered=load_board(board_path)
    main=[t for t in altered.GetTracks() if not isinstance(t,p.PCB_VIA)
          and net_name(t.GetNetname())=="AUX_5V" and t.GetLayer()==p.F_Cu
          and t.GetWidth()>p.FromMM(1.5)+1]
    for track in main:altered.RemoveNative(track)
    target=temp/"missing-aux-main.kicad_pcb";altered.Save(str(target))
    issues=[];check_power(target,issues,variant)
    results["missing_aux_main_detected"]=bool(main) and any(
        e["check"]=="power_copper" and "Q3" in e["detail"] for e in issues)
    altered=load_board(board_path)
    bus=[t for t in altered.GetTracks() if not isinstance(t,p.PCB_VIA)
         and net_name(t.GetNetname())=="SWITCHED_5V" and t.GetLayer()==p.F_Cu
         and abs(t.GetWidth()-p.FromMM(4.5))<=1]
    overlay=any(not z.GetIsRuleArea() and net_name(z.GetNetname())=="SWITCHED_5V"
                and z.GetLayer()==p.F_Cu and z.GetFilledPolysList(p.F_Cu).OutlineCount()
                for z in altered.Zones())
    for track in bus:altered.RemoveNative(track)
    target=temp/"missing-bus-under-overlay.kicad_pcb";altered.Save(str(target))
    issues=[];check_power(target,issues,variant)
    results["missing_bus_under_overlay_detected"]=bool(bus) and overlay and any(
        e["check"]=="power_copper" and "F201" in e["detail"] for e in issues)
    for net,width,name in (("COMMON_SOURCE",2.5,"nonuniform_power_middle_detected"),
                           ("AUX_5V",2.0,"nonuniform_aux_middle_detected")):
        altered=load_board(board_path)
        terminals={(pad.GetPosition().x,pad.GetPosition().y) for fp in altered.GetFootprints()
                   for pad in fp.Pads() if net_name(pad.GetNetname())==net}
        middle=[t for t in altered.GetTracks() if not isinstance(t,p.PCB_VIA)
                and net_name(t.GetNetname())==net and t.GetLayer()==p.F_Cu
                and abs(t.GetWidth()-p.FromMM(width))<=1
                and all((end.x,end.y) not in terminals for end in (t.GetStart(),t.GetEnd()))]
        if middle:max(middle,key=lambda t:t.GetLength()).SetWidth(p.FromMM(3))
        target=temp/f"{name}.kicad_pcb";altered.Save(str(target))
        issues=[];check_power(target,issues,variant)
        results[name]=bool(middle) and any(e["check"]=="uniform_power_width" for e in issues)
    for net,layer,width,name in (("COMMON_SOURCE",p.F_Cu,2.5,"common_taper_detected"),
                                 ("SWITCHED_5V",p.B_Cu,2.5,"switched_taper_detected"),
                                 ("AUX_5V",p.F_Cu,2.0,"aux_taper_detected")):
        altered=load_board(board_path)
        routes=[t for t in altered.GetTracks() if not isinstance(t,p.PCB_VIA)
                and net_name(t.GetNetname())==net and t.GetLayer()==layer
                and abs(t.GetWidth()-p.FromMM(width))<=1]
        if routes:
            track=max(routes,key=lambda t:t.GetLength());a,b=track.GetStart(),track.GetEnd()
            dx,dy=b.x-a.x,b.y-a.y;length=math.hypot(dx,dy)
            zone=p.ZONE(altered);zone.SetLayer(layer);zone.SetNet(altered.GetNetsByName()[net])
            zone.SetZoneName("POWER_TAPER");zone.SetAssignedPriority(20)
            poly=zone.Outline();poly.NewOutline()
            for at,taper_width,sign in ((a,width,1),(b,3,1),(b,3,-1),(a,width,-1)):
                poly.Append(round(at.x-sign*dy/length*p.FromMM(taper_width)/2),
                            round(at.y+sign*dx/length*p.FromMM(taper_width)/2))
            altered.Add(zone)
        target=temp/f"{name}.kicad_pcb";altered.Save(str(target))
        issues=[];check_power(target,issues,variant)
        results[name]=bool(routes) and any(e["check"]=="uniform_power_taper" for e in issues)
    for fault in ("missing", "small_drill", "disconnected"):
        altered=load_board(board_path)
        changed=False
        for via in list(altered.GetTracks()):
            if not isinstance(via,p.PCB_VIA) or net_name(via.GetNetname())!="SWITCHED_5V":continue
            changed=True
            if fault=="missing":altered.RemoveNative(via)
            elif fault=="small_drill":via.SetDrill(p.FromMM(.3))
            else:via.SetPosition(p.VECTOR2I(p.FromMM(-10),p.FromMM(-10)))
        target=temp/f"{fault}-power-vias.kicad_pcb";altered.Save(str(target))
        issues=[];check_power(target,issues,variant)
        results[f"{fault}_power_vias_detected"]=changed and any(e["check"]=="power_vias" for e in issues)
    altered=load_board(board_path)
    net=altered.GetNetsByName()["SWITCHED_5V"]
    for via in list(altered.GetTracks()):
        if isinstance(via,p.PCB_VIA) and net_name(via.GetNetname())=="SWITCHED_5V":
            altered.RemoveNative(via)
    # All three vias touch the bottom feeder and wide top copper, but the
    # top island has no onward connection to the distribution bus.
    for x in (39,40.1,41.2):
        via=p.PCB_VIA(altered);via.SetPosition(p.VECTOR2I(p.FromMM(x),p.FromMM(20)))
        via.SetWidth(p.FromMM(.9));via.SetDrill(p.FromMM(.45))
        via.SetViaType(p.VIATYPE_THROUGH);via.SetLayerPair(p.F_Cu,p.B_Cu)
        via.SetNet(net);altered.Add(via)
    island=p.PCB_TRACK(altered);island.SetStart(p.VECTOR2I(p.FromMM(39),p.FromMM(20)))
    island.SetEnd(p.VECTOR2I(p.FromMM(41.2),p.FromMM(20)));island.SetWidth(p.FromMM(3))
    island.SetLayer(p.F_Cu);island.SetNet(net);altered.Add(island)
    target=temp/"redundant-power-vias.kicad_pcb";altered.Save(str(target))
    issues=[];check_power(target,issues,variant)
    results["redundant_power_vias_detected"]=({e["check"] for e in issues}=={"power_via_bypass"})
    board = load_board(board_path)
    fp = next(fp for fp in board.GetFootprints() if fp.GetReference() == "J101")
    pad = next(pad for pad in fp.Pads() if pad.GetNumber() == "1")
    pad.SetNet(board.GetNetsByName()["AUX_5V"])
    wrong = temp / "wrong-host-power.kicad_pcb"
    board.Save(str(wrong))
    errors = []
    check_pad_map(load_board(wrong), components, expected, errors)
    results["host_power_bridge_detected"] = any(e["check"] == "pad_map" for e in errors)
    board = load_board(board_path)
    baseline = []
    check_usb(board, baseline, variant)
    if any(e["check"] == "usb_connectivity" for e in baseline):
        results["usb_cut_detected"] = False
        results["detail"] = "USB connectivity must pass before a cut can demonstrate regression detection"
        return results
    candidates = sorted((t for t in board.GetTracks()
                         if t.GetNetname() == "S1_UP_P" and not isinstance(t, p.PCB_VIA)),
                        key=lambda t: t.GetLength(), reverse=True)
    results["usb_cut_detected"] = False
    for candidate in candidates:
        cut = load_board(board_path)
        victim = next(t for t in cut.GetTracks() if t.m_Uuid.AsString() == candidate.m_Uuid.AsString())
        start, end = victim.GetStart(), victim.GetEnd()
        victim.SetEnd(p.VECTOR2I((start.x + end.x) // 2, (start.y + end.y) // 2))
        target = temp / "cut-usb.kicad_pcb"
        cut.Save(str(target))
        errors = []
        check_usb(load_board(target), errors, variant)
        if any(e["check"] == "usb_connectivity" for e in errors):
            results["usb_cut_detected"] = True
            break
    altered = load_board(board_path)
    altered.GetDesignSettings().SetCopperLayerCount(4)
    layer_errors = []; check_geometry(altered, layer_errors, variant)
    results["four_layers_detected"] = any(e["check"] == "geometry" for e in layer_errors)
    altered = load_board(board_path)
    for zone in list(altered.Zones()):
        if not zone.GetIsRuleArea() and zone.GetLayer() == p.F_Cu:altered.RemoveNative(zone)
    ground_errors = []; check_usb_reference(altered, ground_errors)
    results["missing_usb_reference_detected"] = any(e["check"] == "usb_reference" for e in ground_errors)
    return results


def source_hashes(folder, board_path):
    paths = {HERE / name for name in ("check.py", "circuit.py", "pcb.py", "route_critical.py", "schematic.py", "finish.py", "router.py", "export.py", "cleanup.py", "build.sh", "switch_circuit.py", "layout.py")}
    paths.update(HERE.glob("hand_*.py"))
    paths.update(HERE / name for name in ("models.py", "model_geometry.py"))
    paths.update(path for path in (HERE / "models").rglob("*") if path.is_file())
    paths.add(HERE / "external_bom.csv")
    paths.update((HERE / "screen_power.pretty").glob("*.kicad_mod"))
    paths.add(HERE.parent / "netlist.py")
    paths.add(HERE.parent / "console_board.net")
    paths.add(HERE.parent / "out_console/segno_console_board.kicad_pcb")
    paths.add(board_path)
    for pattern in ("*.net", "*.kicad_sch", "*.kicad_sym", "*.kicad_pro", "*.kicad_dru", "*-lib-table", "components.json", "bom.csv"):
        paths.update(folder.glob(pattern))
    return {os.path.relpath(path,HERE): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths) if path.exists()}


def validate(variant, board_override=None, run_self_test=False):
    folder = HERE / variant
    base = folder / f"screen_power_{variant}"
    board_path = Path(board_override).resolve() if board_override else base.with_suffix(".kicad_pcb")
    errors = []
    summary = {"variant": variant, "board": os.path.relpath(board_path,HERE), "errors": errors,
               "hardware_qualification": "not performed"}
    before = source_hashes(folder, board_path)
    summary["source_sha256"] = before
    try:
        for path in (board_path, base.with_suffix(".net"), base.with_suffix(".kicad_sch")):
            if not path.is_file():
                raise FileNotFoundError(path)
        components, raw_nets = parse_netlist(base.with_suffix(".net"))
        expected = semantic_nets(raw_nets)
        pins = pin_map(expected)
        board = load_board(board_path)
        check_pad_map(board, components, pins, errors)
        check_contract(variant, pins, expected, errors)
        summary["relay_contact_behavior"] = check_relay_contacts(raw_nets, errors)
        check_geometry(board, errors, variant)
        check_mounting_clearance(board, errors)
        check_relay_holes(board, errors)
        check_usb_headers(board, errors)
        summary["model_coverage"] = check_models(board, folder, errors)
        summary["usb_track_lengths_mm"] = check_usb(board, errors, variant)
        summary["usb_ground_reference"] = check_usb_reference(board, errors)
        check_power(board_path, errors, variant)
        from hand_checks import check_through_hole
        check_through_hole(board, errors)
        check_console_control(errors)
        summary["numerical_checks"] = numerical_checks(variant, components, errors)
        with tempfile.TemporaryDirectory(prefix=f"screen-power-check-{variant}-") as directory:
            temp = Path(directory)
            summary["drc"] = rule_check("drc", board_path, temp / "drc.json", errors)
            summary["erc"] = rule_check("erc", base.with_suffix(".kicad_sch"), temp / "erc.json", errors)
            exported = temp / "native.net"
            result = cli_run(["sch", "export", "netlist", "--format", "kicadsexpr",
                              "--output", exported, base.with_suffix(".kicad_sch")], errors, "native_export")
            if result is None or result.returncode or not exported.is_file():
                fail(errors, "native_export", "Fresh schematic netlist export failed")
            else:
                native_components, native_raw = parse_netlist(exported)
                native = semantic_nets(native_raw)
                check_relay_contacts(native_raw, errors)
                if native_components != components:
                    fail(errors, "native_parity", "Native schematic components differ from generated netlist")
                for name in sorted(set(expected) | set(native)):
                    if expected.get(name) != native.get(name):
                        fail(errors, "native_parity", f"{name}: missing {sorted(expected.get(name, set())-native.get(name, set()))}; extra {sorted(native.get(name, set())-expected.get(name, set()))}")
            if run_self_test:
                summary["self_test"] = self_test(board_path, components, pins, temp, variant)
                required_faults = ["wrong_relay_detected", "wrong_driver_detected", "wrong_tolerance_detected", "weak_pulldown_detected", "narrow_power_detected", "host_power_bridge_detected", "usb_cut_detected", "console_control_cut_detected"]
                required_faults += ["relay_hole_detected", "model_unassigned_detected", "model_missing_detected", "model_disabled_detected", "wrong_xh_pitch_detected"]
                required_faults += ["smd_footprint_detected", "smd_pad_detected", "power_lead_hole_detected", "four_layers_detected", "missing_usb_reference_detected"]
                required_faults += [f'{ref}_hole_tolerance_detected' for ref in ('J101','J2','J1','Q1','H1','U1','U2')]
                required_faults += ["weak_gate_pullup_detected", "weak_opto_drive_detected",
                                    "wrong_pump_detected", "polarized_pump_cap_detected",
                                    "reversed_negative_clamp_detected", "pump_lv_grounded_detected",
                                    "opto_output_reversed_detected", "negative_gpio_bridge_detected"]
                required_faults += ['fastener_short_detected']
                required_faults += ["relay_contact_baseline_passes", "relay_old_host_pins_detected",
                                    "relay_wrong_throw_detected", "relay_polarity_swap_detected",
                                    "relay_cross_channel_detected", "relay_no_connects_isolated",
                                    "narrow_fet_neck_detected", "narrow_bulk_feed_detected",
                                    "narrow_common_source_detected", "narrow_switched_feed_detected",
                                    "missing_bus_under_overlay_detected", "nonuniform_power_middle_detected",
                                    "common_taper_detected", "switched_taper_detected",
                                    "narrow_aux_main_detected", "missing_aux_main_detected",
                                    "nonuniform_aux_middle_detected", "aux_taper_detected",
                                    "missing_power_vias_detected", "small_drill_power_vias_detected",
                                    "disconnected_power_vias_detected", "redundant_power_vias_detected"]
                if not all(summary["self_test"].get(k) for k in required_faults):
                    fail(errors, "self_test", "A deliberate fault was not detected")
    except (OSError, ValueError, AssertionError, KeyError, StopIteration, RuntimeError) as exc:
        fail(errors, "validation_exception", f"{type(exc).__name__}: {exc}")
    if source_hashes(folder, board_path) != before:
        fail(errors, "source_changed", "Input files changed during validation; rerun on a stable revision")
    summary["cad_ready"] = not errors
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variant", choices=("hand",), nargs="?", default="hand")
    parser.add_argument("--board", type=Path, help="Explicit hand-soldered board input")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    results = [validate(args.variant, args.board, args.self_test)]
    report = {"generated_at": datetime.now(timezone.utc).isoformat(),
              "kicad_version": p.GetBuildVersion(), "cad_ready": all(r["cad_ready"] for r in results),
              "hardware_qualification": "not performed", "variants": results}
    if args.output:
        args.output.write_text(json.dumps(report, indent=2).replace(str(HERE) + "/", "") + "\n")
    for result in results:
        print(f"{result['variant']}: {'CAD CHECKS PASS' if result['cad_ready'] else 'NOT READY'}")
        for error in result["errors"]:
            print(f"  {error['check']}: {error['detail']}")
        if "self_test" in result:
            print("  self-test:", json.dumps(result["self_test"], sort_keys=True))
    return 0 if report["cad_ready"] else 1


if __name__ == "__main__":
    sys.exit(main())
