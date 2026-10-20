"""Validate delivered screen-power boards with KiCad's Python and CLI.

Usage: python3 check.py [hand] [--output report.json] [--self-test]
KICAD_CLI may select another KiCad 10 executable. Reports describe CAD checks,
not hardware qualification. No generated board or schematic is modified.
"""

import argparse
import csv
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
from silkscreen import mask_clearance_problems
from models import check_models

CLI = os.environ.get(
    "KICAD_CLI", "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
)
# Keep owners alive while SWIG pad/track wrappers are used by later checks.
_BOARDS = []
USB_HEADER_REFS = ("J101", "J102", "J201", "J202")
USB_HEADER_FOOTPRINT = "Connector_JST:JST_XH_B5B-XH-A_1x05_P2.50mm_Vertical"
OBSOLETE_SHIELD_REFS = ("TP101", "TP102", "TP201", "TP202")


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
    require("J1", {1:"AUX_5V_IN", 2:"GND"})
    require("F1", {1:"AUX_5V_IN", 2:"AUX_5V"})
    nodes("AUX_5V_IN", {("J1","1"),("F1","1")})
    require("J2", {1:"PI_GPIO17", 2:"GND"})
    nodes("PI_GPIO17", {("J2","1"),("R1","1")})
    require("R1", {1:"PI_GPIO17",2:"CONTROL_BASE"})
    require("R2", {1:"CONTROL_BASE",2:"GND"})
    require("Q1", {1:"GND",2:"CONTROL_BASE",3:"CONTROL_SINK"})
    require("R5", {1:"CONTROL_SINK",2:"BUFFER_BASE"})
    require("R6", {1:"AUX_5V",2:"BUFFER_BASE"})
    require("R7", {1:"DATA_ENABLE",2:"GND"})
    require("R8", {1:"SWITCHED_5V",2:"GND"})
    require("Q2", {1:"AUX_5V",2:"BUFFER_BASE",3:"DATA_ENABLE"})
    require("Q5", {1:"DATA_ENABLE",2:"POWER_COIL_LOW",3:"GND"})
    require("K1", {8:"AUX_5V",1:"POWER_COIL_LOW",4:"AUX_5V",3:"SWITCHED_5V"})
    require("D3", {1:"POWER_COIL_LOW",2:"AUX_5V"})
    require("C1", {1:"AUX_5V",2:"GND"})
    require("C2", {1:"AUX_5V",2:"GND"})
    nodes("CONTROL_SINK", {("Q1","3"),("R5","1")})
    nodes("CONTROL_BASE", {("R1","2"),("R2","1"),("Q1","2")})
    nodes("BUFFER_BASE", {("R5","2"),("R6","2"),("Q2","2")})
    nodes("DATA_ENABLE", {("Q2","3"),("R7","1"),("Q5","1"),("Q101","2"),("Q201","2")})
    nodes("POWER_COIL_LOW", {("K1","1"),("Q5","2"),("D3","1")})
    nodes("AUX_5V", {("F1","2"),("K1","8"),("K1","4"),("D3","2"),
          ("Q2","1"),("R6","1"),("C1","1"),("C2","1"),
          ("K101","1"),("K201","1"),("D101","1"),("D201","1"),
          ("C101","1"),("C201","1")})
    nodes("SWITCHED_5V", {("K1","3"),("R8","1"),("F101","1"),
          ("F102","1"),("F201","1"),("F202","1")})
    obsolete_refs={"Q3","Q4","U1","U2","C3","C4","C5","D2","R3","R4","R9","R10"}
    obsolete_nets={"POWER_GATE","COMMON_SOURCE","NEG_5V","GATE_SINK","GATE_LED","PUMP_CAP_PLUS","PUMP_CAP_MINUS"}
    if obsolete_refs & {ref for ref,_ in pins} or obsolete_nets & set(nets):
        fail(errors,"obsolete_power_stage","Removed pump/opto/PMOS stage remains connected")
    if set(OBSOLETE_SHIELD_REFS) & {ref for ref, _ in pins}:
        fail(errors, "usb_shield", "Separate shield pads must be replaced by XH pin 5")
    for ch in (1,2):
        n=100*ch; pre=f"S{ch}"; host=f"HOST{ch}_5V"; coil=f"{pre}_DATA_COIL_LOW"
        for offset, rail, side in ((1,host,"UP"),(2,pre+"_TOUCH_5V","DN")):
            require(f"J{n+offset}", {1:rail,2:pre+f"_{side}_N",3:pre+f"_{side}_P",4:"GND",5:"GND"})
        require(f"J{n+3}", {1:pre+"_MAIN_5V",2:"GND"})
        require(f"F{n+1}", {1:"SWITCHED_5V",2:pre+"_MAIN_5V"})
        require(f"F{n+2}", {1:"SWITCHED_5V",2:pre+"_TOUCH_5V"})
        require(f"C{n+2}", {1:pre+"_TOUCH_5V",2:"GND"})
        nodes(pre+"_MAIN_5V", {(f"F{n+1}","2"),(f"J{n+3}","1")})
        nodes(pre+"_TOUCH_5V", {(f"F{n+2}","2"),(f"J{n+2}","1"),(f"C{n+2}","1")})
        require(f"K{n+1}", {1:"AUX_5V",8:coil,3:pre+"_UP_N",6:pre+"_UP_P",4:pre+"_DN_N",5:pre+"_DN_P"})
        if any((f"K{n+1}",pin) in pins for pin in ("2","7")):
            fail(errors,"relay_contacts",f"K{n+1}: normally closed and unused terminals must be unconnected")
        require(f"Q{n+1}", {1:"GND",2:"DATA_ENABLE",3:pre+"_RELAY_STACK"})
        require(f"Q{n+2}", {1:pre+"_RELAY_STACK",2:pre+"_HOST_PRESENT",3:coil})
        require(f"R{n+1}", {1:host,2:pre+"_HOST_PRESENT"})
        require(f"R{n+2}", {1:pre+"_HOST_PRESENT",2:"GND"})
        require(f"D{n+1}", {1:"AUX_5V",2:coil})
        require(f"C{n+1}", {1:"AUX_5V",2:"GND"})
        nodes(host, {(f"J{n+1}","1"),(f"R{n+1}","1")})
        nodes(pre+"_HOST_PRESENT", {(f"R{n+1}","2"),(f"R{n+2}","1"),(f"Q{n+2}","2")})
        nodes(pre+"_RELAY_STACK", {(f"Q{n+1}","3"),(f"Q{n+2}","1")})
        nodes(coil, {(f"K{n+1}","8"),(f"Q{n+2}","3"),(f"D{n+1}","2")})
        for side, j, terminals in (("UP",n+1,{"P":6,"N":3}),("DN",n+2,{"P":5,"N":4})):
            for polarity, pin in (("P",3),("N",2)):
                nodes(f"{pre}_{side}_{polarity}",{(f"J{j}",str(pin)),(f"K{n+1}",str(terminals[polarity]))})



def check_part_records(components, records, bom_rows, errors):
    """Bind analog assumptions and the fitted population to exact purchased MPNs."""
    by_ref = {row["ref"]: row for row in records}
    bom = {row["ref"]: row for row in bom_rows}
    if len(by_ref) != len(records) or len(bom) != len(bom_rows):
        fail(errors, "bom_identity", "Duplicate component or BOM references")
    if set(by_ref) != set(components):
        fail(errors, "bom_identity", "Component records and netlist inventory differ")
    expected = {
        "Q1":"2N3904BU", "Q2":"2N3906BU", "Q5":"IRLZ44NPBF",
        "K1":"G6C-1117P-US DC5", "D3":"P6KE6.8CA", "F1":"0001.2513",
        "R1":"MFR-25FBF52-1K", "R2":"MFR-25FBF52-4K7",
        "R5":"MFR-25FBF52-5K6", "R6":"MFR-25FBF52-100K",
        "R7":"MFR-25FBF52-10K", "R8":"PR01000101000FA100",
        "C1":"K104K10X7RF53H5", "C2":"EEU-FR1A221",
        "J1":"B2P-VH(LF)(SN)", "J2":"B2B-XH-A(LF)(SN)",
    }
    for ch in (1, 2):
        n = ch * 100
        for prefix, offset, mpn in (
            ("J",1,"B5B-XH-A(LF)(SN)"), ("J",2,"B5B-XH-A(LF)(SN)"),
            ("J",3,"B2P-VH(LF)(SN)"), ("F",1,"0697H4000-02"),
            ("F",2,"0697H0800-02"), ("K",1,"1-1462037-3"),
            ("Q",1,"TN0702N3-G"), ("Q",2,"TN0702N3-G"),
            ("R",1,"MFR-25FBF52-10K"), ("R",2,"MFR-25FBF52-100K"),
            ("D",1,"1N4007G"), ("C",1,"K104K10X7RF53H5"),
            ("C",2,"EEU-FR1A151")):
            expected[f"{prefix}{n+offset}"] = mpn
    for ref, mpn in expected.items():
        if by_ref.get(ref, {}).get("mpn") != mpn:
            fail(errors, "bom_identity", f"{ref}: calculations/assembly require {mpn}")
    footprints = {"F1":"screen_power:Fuseholder_Schurter_OGN_0031.8201",
                  "Q5":"screen_power:TO-220-3_IRLZ44N",
                  "K1":"screen_power:Relay_Omron_G6C-1117P-US"}
    footprints.update({ref:"screen_power:Fuse_Bel_0697H_P5.08mm"
                       for ref in ("F101","F102","F201","F202")})
    footprints.update({ref:USB_HEADER_FOOTPRINT for ref in USB_HEADER_REFS})
    if set(OBSOLETE_SHIELD_REFS) & (set(components) | set(by_ref) | set(bom)):
        fail(errors, "bom_identity", "Separate shield pads are obsolete; USB shields use XH pin 5")
    for ref, footprint in footprints.items():
        if by_ref.get(ref, {}).get("footprint") != footprint:
            fail(errors, "bom_identity", f"{ref}: selected part requires {footprint}")
    for ref, row in by_ref.items():
        native = components.get(ref)
        if native and (row["value"] != native[2] or row["footprint"].split(":")[-1] != native[1]):
            fail(errors, "bom_identity", f"{ref}: record value/footprint differs from netlist")
        if int(row["quantity"]) != 1:
            fail(errors, "bom_identity", f"{ref}: every component record requires one fitted instance")
        got = bom.get(ref, {})
        if any(str(got.get(key)) != str(row[key]) for key in ("value", "footprint", "mpn", "quantity")):
            fail(errors, "bom_identity", f"{ref}: purchase BOM differs from fitted component record")
    wanted = set(by_ref) | {"F1_HOLDER"}
    if set(bom) != wanted:
        fail(errors, "bom_identity", "BOM must contain fitted parts and exactly the input-holder accessory")
    holder = bom.get("F1_HOLDER", {})
    if (holder.get("mpn") != "0031.8201" or str(holder.get("quantity")) != "1"
            or holder.get("footprint") != "screen_power:Fuseholder_Schurter_OGN_0031.8201"
            or holder.get("group") != "Fuse holders"):
        fail(errors, "bom_identity", "F1 requires one separate 0031.8201 holder purchase")
    return {"fitted_components":sum(int(row["quantity"]) for row in records if not row["ref"].startswith("H")),
            "input_holder_accessories":1, "branch_fuses":"soldered Bel 0697H; no separate clips"}


def check_power_relay_states(pins, errors):
    """Ideal G/D/S and normally-open contact proof, including body diode.

    The open contact isolates both directions. A closed contact is bidirectional:
    an external output source may sustain AUX until GPIO releases the relay.
    This is a stable-state circuit check, not a mechanical timing simulation.
    """
    required = [("Q5", str(i)) for i in (1,2,3)] + [("K1", str(i)) for i in (1,3,4,8)]
    if any(key not in pins for key in required):
        fail(errors, "power_relay_state", "Missing driver/contact terminal")
        return {}
    checked = 0
    for aux, gpio in itertools.product((False, True), ("low", "high", "floating")):
        voltage = {"GND":0, "AUX_5V":4.5854 if aux else 0,
                   "DATA_ENABLE":4.1854 if aux and gpio == "high" else 0}
        gate, drain, source = (pins[("Q5", str(i))] for i in (1,2,3))
        graph = {source:{drain}}  # N-channel body diode conducts S -> D.
        if voltage.get(gate, 0) - voltage.get(source, 0) >= 4:
            graph.setdefault(drain, set()).add(source)
        reached, pending = set(), [pins[("K1", "1")]]
        while pending:
            node = pending.pop()
            if node not in reached:
                reached.add(node); pending.extend(graph.get(node, set()) - reached)
        closed = voltage.get(pins[("K1", "8")], 0) > 3.5 and "GND" in reached
        if closed != (aux and gpio == "high"):
            fail(errors, "power_relay_state", f"AUX={aux}, GPIO={gpio}: power coil state is {closed}")
        a, b = pins[("K1", "3")], pins[("K1", "4")]
        bridge = a == b or closed and {a,b} == {"AUX_5V", "SWITCHED_5V"}
        if bridge != (aux and gpio == "high"):
            fail(errors, "power_relay_state", f"AUX={aux}, GPIO={gpio}: power contact state is {bridge}")
        checked += 1
    return {"aux_gpio_states":checked, "open_contact_bidirectional_isolation":True,
            "externally_powered_output_caveat":"Already-closed contact can sustain AUX while GPIO remains high",
            "release_timing":"not guaranteed to precede or follow USB relays"}

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
    power_layers = {"AUX_5V_IN": {p.F_Cu}, "AUX_5V": {p.F_Cu},
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


def check_silkscreen(board, errors):
    """Inspect printed ink, including footprint fields and library outlines."""
    items = [("board", item) for item in board.GetDrawings()]
    for footprint in board.GetFootprints():
        items.extend((footprint.GetReference(), item) for item in
                     [*footprint.GetFields(), *footprint.GraphicalItems()])
    for owner, item in items:
        if item.GetLayer() not in (p.F_SilkS, p.B_SilkS):
            continue
        if isinstance(item, (p.PCB_TEXT, p.PCB_FIELD)):
            if not item.IsVisible() or not item.GetShownText(False).strip():
                continue
            if item.GetTextHeight() < p.FromMM(1.0):
                fail(errors, "silk_text_height", f"{owner} {item.GetShownText(False)}: visible text is below 1.0 mm")
            if item.GetTextThickness() < p.FromMM(.15):
                fail(errors, "silk_text_stroke", f"{owner} {item.GetShownText(False)}: visible text stroke is below 0.15 mm")
        elif isinstance(item, p.PCB_SHAPE) and not item.IsSolidFill():
            if item.GetWidth() < p.FromMM(.15):
                fail(errors, "silk_outline_stroke", f"{owner}: unfilled silkscreen outline is below 0.15 mm")


def check_silkscreen_rules(settings, errors):
    """Keep the fresh CLI DRC's printing limits at least as strict as the ink checks."""
    rules = settings.get("rules", {})
    for name, minimum in (("min_text_height", 1.0),
                          ("min_text_thickness", .15),
                          ("min_silk_clearance", .15)):
        actual = rules.get(name)
        if not isinstance(actual, (int, float)) or not math.isfinite(actual) or actual < minimum:
            fail(errors, "silk_rules", f"Project {name} must be at least {minimum} mm")
    if settings.get("rule_severities", {}).get("silk_over_copper") not in ("warning", "error"):
        fail(errors, "silk_rules", "Project must report silkscreen-to-pad clearance violations")


def check_silk_mask_clearance(board, errors):
    for detail in mask_clearance_problems(board):
        fail(errors, "silk_mask_clearance", detail)


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
    """Verify the five-contact cable interface against JST's XH drawing."""
    headers = []
    for fp in board.GetFootprints():
        ref = fp.GetReference()
        if ref in OBSOLETE_SHIELD_REFS:
            fail(errors, "usb_header", f"{ref}: obsolete separate shield pad")
        if ref not in USB_HEADER_REFS:
            continue
        headers.append(ref)
        # Native footprints are customized copies (hand-solder drills, silk
        # and bundled models), not links to unchanged stock-library items.
        # The source/netlist/BOM checks above retain the qualified identity.
        if str(fp.GetFPID().GetLibItemName()) != USB_HEADER_FOOTPRINT.split(":", 1)[1]:
            fail(errors, "usb_header", f"{ref}: requires {USB_HEADER_FOOTPRINT}")
        terminals = list(fp.Pads())
        pads = {pad.GetNumber(): pad for pad in terminals}
        if len(terminals) != 5 or set(pads) != {"1", "2", "3", "4", "5"}:
            fail(errors, "usb_header", f"{ref}: expected exactly five XH terminals")
            continue
        for number, pad in pads.items():
            if pad.GetAttribute() != p.PAD_ATTRIB_PTH or min(pad.GetDrillSize().x, pad.GetDrillSize().y) < p.FromMM(.9):
                fail(errors, "usb_header", f"{ref}.{number}: XH requires at least 0.9 mm plated holes")
        for number in ("4", "5"):
            if net_name(pads[number].GetNetname()) != "GND":
                fail(errors, "usb_header", f"{ref}.{number}: ground and shield contacts must connect to GND")
        for a, b in itertools.combinations(range(1, 6), 2):
            delta = pads[str(a)].GetPosition() - pads[str(b)].GetPosition()
            if abs(math.hypot(delta.x, delta.y) - p.FromMM((b-a)*2.5)) > 1:
                fail(errors, "usb_header", f"{ref}: XH terminals must form one row at 2.50 mm pitch")
                break
    if sorted(headers) != sorted(USB_HEADER_REFS):
        fail(errors, "usb_header", "Expected one each of J101, J102, J201 and J202")


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
    paths = [(4.0,("J1","1"),("F1","1")),
             (5.0,("F1","2"),("K1","4")),
             (1.0,("F1","2"),("C2","1")),
             (1.0,("F1","2"),("C1","1")),
             (1.0,("F1","2"),("K1","8")),
             (3.5,("K1","3"),("F101","1"))]
    for ch in (1,2):
        n=ch*100
        paths += [(3.0,("K1","3"),(f"F{n+i}","1")) for i in (1,2)]
        paths += [(2.5,(f"F{n+1}","2"),(f"J{n+3}","1")),
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
    # Only the capacitor/coil/control taps may narrow these main feeds.
    # The front switched net has a separate 4.5 mm spine and 3 mm branches;
    # the 3.5 mm rear relay feeder is uniform from contact to first fuse.
    uniform_runs={("AUX_5V_IN",p.F_Cu):(0,4.0),
                  ("AUX_5V",p.F_Cu):(1.0,5.0),
                  ("SWITCHED_5V",p.B_Cu):(.25,3.5)}
    for track in board.GetTracks():
        if isinstance(track,p.PCB_VIA):continue
        rule=uniform_runs.get((net_name(track.GetNetname()),track.GetLayer()))
        if rule and track.GetWidth()>p.FromMM(rule[0])+1 and abs(track.GetWidth()-p.FromMM(rule[1]))>1:
            fail(errors,"uniform_power_width",f"{net_name(track.GetNetname())} {track.GetLayerName()}: power run must stay {rule[1]} mm wide")
    from layout import POWER_BUS_X
    spine = [t for t in board.GetTracks() if not isinstance(t, p.PCB_VIA)
             and net_name(t.GetNetname()) == "SWITCHED_5V" and t.GetLayer() == p.F_Cu
             and abs(p.ToMM(t.GetStart().x)-POWER_BUS_X) < .00001
             and abs(p.ToMM(t.GetEnd().x)-POWER_BUS_X) < .00001
             and t.GetLength() > p.FromMM(1)]
    if not spine or any(abs(t.GetWidth()-p.FromMM(4.5)) > 1 for t in spine):
        fail(errors, "power_spine", "The front switched distribution spine must retain its uniform 4.5 mm copper")
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
            and net_name(t.GetNetname())=="SWITCHED_5V"
            and t.GetWidth()>=p.FromMM(3.0 if t.GetLayer()==p.F_Cu else 3.5)-1]
    connectivity=board.GetConnectivity();connectivity.Build(board)
    required={terminals[key].m_Uuid.AsString() for key in (("K1","3"),("F201","1"))}
    dedicated=set()
    for via in board.GetTracks():
        if (not isinstance(via,p.PCB_VIA) or net_name(via.GetNetname())!="SWITCHED_5V"
                or via.GetViaType()!=p.VIATYPE_THROUGH or via.GetDrillValue()<p.FromMM(.45)-1):
            continue
        # The complete via annulus must land in the 3 mm front tap and
        # 3.5 mm rear trunk, and belong to the
        # physical device-to-distribution path; spare or dangling vias do not count.
        c=via.GetPosition();layers=set()
        for track in tracks:
            a,b=track.GetStart(),track.GetEnd();dx,dy=b.x-a.x,b.y-a.y
            length2=dx*dx+dy*dy
            u=max(0,min(1,((c.x-a.x)*dx+(c.y-a.y)*dy)/length2)) if length2 else 0
            if math.hypot(c.x-a.x-u*dx,c.y-a.y-u*dy)+via.GetWidth()/2<=track.GetWidth()/2+1:
                layers.add(track.GetLayer())
        reached={item.m_Uuid.AsString() for item in connectivity.GetConnectedItems(via)}
        if {p.F_Cu,p.B_Cu}<=layers and required<=reached:
            dedicated.add(via.m_Uuid.AsString())
    if len(dedicated)<3:
        fail(errors,"power_vias",f"Shared SWITCHED_5V transition needs 3 connected vias with at least 0.45 mm drills and full annuli inside 3.0 mm F / 3.5 mm B copper; found {len(dedicated)}")
    # Prove the added vias actually bypass the fuse barrel. A via on a top
    # island can otherwise reach both endpoints by returning to the bottom
    # feeder and crossing the original F101 plated pad.
    fuse=next(fp for fp in board.GetFootprints() if fp.GetReference()=="F101")
    fuse.RemoveNative(terminals.pop(("F101","1")))
    for item in list(board.GetTracks()):
        if ((isinstance(item,p.PCB_VIA) and item.m_Uuid.AsString() not in dedicated)
                or (not isinstance(item,p.PCB_VIA) and item.GetWidth()<p.FromMM(3.0)-1)):
            board.RemoveNative(item)
    connectivity=board.GetConnectivity();connectivity.Build(board)
    reached={item.m_Uuid.AsString() for item in connectivity.GetConnectedItems(terminals[("K1","3")])}
    if terminals[("F201","1")].m_Uuid.AsString() not in reached:
        fail(errors,"power_via_bypass","Qualifying SWITCHED_5V vias do not provide a continuous 3.0 mm K1.3 to F201.1 path without the F101.1 barrel")


def resistor_value(components, ref):
    text = components[ref][2]
    match = re.match(r"^(\d+(?:\.\d+)?)\s*([kKMmR]?)", text)
    if not match:
        raise ValueError(f"Unrecognized resistor value {ref}: {text}")
    return float(match[1]) * {"": 1, "R": 1, "k": 1000, "K": 1000,
                             "M": 1000000, "m": 0.001}[match[2]]


def usb_power_margins(components, errors):
    """DC design bounds; hot resistance/leakage allowances are estimates."""
    channels = {}
    for ch in (1, 2):
        n = ch * 100
        try:
            series, pull = (resistor_value(components, f"R{n+i}") for i in (1, 2))
        except (KeyError, ValueError) as exc:
            fail(errors, "usb_sense_components", str(exc))
            continue
        if (series, pull) != (10000, 100000) or any(
                re.findall(r"[\d.]+%", components[f"R{n+i}"][2]) != ["1%"] for i in (1, 2)):
            fail(errors, "usb_sense_components", f"Channel {ch}: require 10k/100k 1% sense divider")
        if min(series, pull) <= 0 or not all(math.isfinite(v) for v in (series, pull)):
            continue
        # TN0702: 2.5 ohm maximum at VGS=3 V, 25 C. Use twice that
        # resistance per FET as an explicit hot engineering allowance.
        driver_hot = 5.0
        coil_low = 145 * .9
        peak = 5.25 / (coil_low + 2 * driver_hot)
        ratio = pull * .99 / (pull * .99 + series * 1.01)
        # 1 uA gate-leakage sensitivity exceeds the 100 nA 25 C rating.
        leakage_drop = 1e-6 * (series * 1.01 * pull * 1.01) / (series * 1.01 + pull * 1.01)
        upper_gate_min = 4.4 * ratio - leakage_drop - peak * driver_hot
        bottom_gate_min = 4.75 - .100 - .0446 - .020 - .4
        current_max = 5.5 / ((series + pull) * .99) + 1e-6
        # Even if the sense node sinks to ground, the series resistor alone
        # bounds the host's DC load, independent of a hot gate-leakage model.
        grounded_node_max = 5.5 / (series * .99)
        absent_gate = 1e-6 * pull * 1.01
        # TE initial pickup is specified at 23 C without pre-energization;
        # this numerical guard does not establish hot restart.
        coil_feed = 4.75 - .100 - .0446 - .020
        coil_min = coil_feed * coil_low / (coil_low + 2 * driver_hot)
        # Previous adverse model: 150 K/W winding-to-air, 60 C local air,
        # 5.25 V preheating, minimum winding R23; not a vendor hot guarantee.
        hot_temperature = 60.0
        for _ in range(40):
            hot_resistance = coil_low * (1 + .00393 * (hot_temperature - 23))
            hot_temperature = 60 + 150 * 5.25**2 / hot_resistance
        hot_pickup = 3.38 * (1 + .00393 * (hot_temperature - 23))
        hot_voltage = coil_feed * hot_resistance / (hot_resistance + 2 * driver_hot)
        if (min(upper_gate_min, bottom_gate_min) < 3 or grounded_node_max >= .0025
                or absent_gate >= .25 or coil_min < 3.38 or hot_voltage < hot_pickup):
            fail(errors, "usb_power_margin", f"Channel {ch}: presence/drive/suspend margin failed")
        channels[str(ch)] = {
            "host_valid_min_V":4.4, "host_budget_max_V":5.5,
            "host_divider_max_mA_with_1uA_allowance":current_max*1000,
            "host_grounded_sense_node_bound_mA":grounded_node_max*1000,
            "host_absent_gate_V_at_1uA_allowance":absent_gate,
            "upper_Vgs_min_at_host_4p4V":upper_gate_min,
            "upper_Vgs_min_at_host_4p75V":4.75*ratio-leakage_drop-peak*driver_hot,
            "bottom_Vgs_min_V":bottom_gate_min,
            "coil_feed_after_input_fuse_holder_copper_V":coil_feed,
            "coil_initial_min_V_at_J1_4p75V":coil_min,
            "coil_hot_winding_C_model":hot_temperature,
            "coil_hot_pickup_margin_V_model":hot_voltage-hot_pickup,
            "coil_initial_pickup_margin_23C_V":coil_min-3.38,
            "coil_peak_mA_with_hot_driver_estimate":peak*1000,
            "coil_max_mA_ignoring_driver_drop":5.25/coil_low*1000,
            "coil_voltage_at_125C_zero_gate_Idss_benchmark":145*1.1*1.4*100e-6,
            "hot_coil_resistance_factor_estimate":1.4,
            "hot_driver_ohms_each_estimate":driver_hot,
            "gate_leakage_allowance_uA_estimate":1,
        }
    return channels


def check_usb_power_states(pins, components, errors):
    """Ideal switch/body-diode state proof, not an analog/timing simulation.

    Derive paths from actual S/G/D pin nets, including source-to-drain body
    diodes. A reversed off FET can therefore no longer hide behind AND logic.
    """
    required = [(f"{kind}{100*ch+i}", str(pin)) for ch in (1,2)
                for kind, i, numbers in (("R",1,(1,2)),("R",2,(1,2)),
                                         ("Q",1,(1,2,3)),("Q",2,(1,2,3)),
                                         ("K",1,(1,8))) for pin in numbers]
    if any(key not in pins for key in required):
        fail(errors,"usb_relay_state","Missing physical terminal in relay qualification circuit")
        return {}
    states = paths = 0
    for aux, gpio, host1, host2 in itertools.product(
            (False,True), ("low","high","floating"), (False,True), (False,True)):
        voltages = {"GND":0, "AUX_5V":4.75 if aux else 0,
                    "HOST1_5V":4.4 if host1 else 0, "HOST2_5V":4.4 if host2 else 0,
                    "DATA_ENABLE":4.1854 if aux and gpio=="high" else 0}
        for ch in (1,2):
            n=100*ch
            series,pull=(resistor_value(components,f"R{n+i}") for i in (1,2))
            if min(series,pull)<=0:return {}
            high,gate=pins[(f"R{n+1}","1")],pins[(f"R{n+1}","2")]
            # A rail short is a fixed voltage, not a divider output.
            if gate not in voltages:
                voltages[gate]=voltages.get(high,0)*pull/(series+pull)
        graph={}
        def edge(a,b):graph.setdefault(a,set()).add(b)
        for ch,i in itertools.product((1,2),(1,2)):
            ref=f"Q{100*ch+i}"
            source,gate,drain=(pins[(ref,str(pin))] for pin in (1,2,3))
            edge(source,drain)  # intrinsic N-channel body diode
            if voltages.get(gate,0)>=3:
                edge(drain,source)
        for ch,host in ((1,host1),(2,host2)):
            relay=f"K{100*ch+1}"
            pending=[pins[(relay,"8")]];reached=set()
            while pending:
                node=pending.pop()
                if node not in reached:
                    reached.add(node);pending.extend(graph.get(node,set())-reached)
            actual=voltages.get(pins[(relay,"1")],0)>3 and "GND" in reached
            wanted=aux and gpio=="high" and host
            if actual!=wanted:
                fail(errors,"usb_relay_state",f"{relay}: AUX={aux}, GPIO={gpio}, hosts={host1,host2}: coil={actual}, required={wanted}")
            paths+=1
        states+=1
    return {"supply_gpio_host_states":states,"coil_paths_checked":paths,
            "model":"ideal switches with directed body diodes; numerical drive checked separately",
            "suspend_behavior":"relay may stay on; its energy comes from AUX, not host VBUS"}


def numerical_checks(variant, components, errors):
    """Reproducible design sensitivities, not measured hardware guarantees."""
    refs=(1,2,5,6,7,8)
    r={i:resistor_value(components,f"R{i}") for i in refs}
    if any(value<=0 or not math.isfinite(value) for value in r.values()):
        fail(errors,"resistor_model","Control resistances must be positive")
        return {}
    if any(re.findall(r"[\d.]+%",components[f"R{i}"][2]) != ["1%"] for i in refs):
        fail(errors,"resistor_model","Drive margins require 1% resistors")
    models={"Q1":"2N3904","Q2":"2N3906","Q5":"IRLZ44N",
            "K1":"G6C-1117P-US","D3":"P6KE6.8CA","F1":"8A time-lag",
            "C1":"100nF 50V X7R","C2":"220uF 10V"}
    for ch in (1,2):
        n=100*ch
        models.update({f"Q{n+1}":"TN0702",f"Q{n+2}":"TN0702",f"K{n+1}":"IM02TS",
                       f"D{n+1}":"1N4007",f"F{n+1}":"4A time-lag",
                       f"F{n+2}":"800mA time-lag",f"C{n+1}":"100nF 50V X7R",
                       f"C{n+2}":"150uF 10V"})
    for ref,model in models.items():
        if components.get(ref,(None,None,None))[2]!=model:
            fail(errors,"driver_model",f"{ref}: calculations require {model}")
    if r != {1:1000,2:4700,5:5600,6:100000,7:10000,8:100}:
        fail(errors,"resistor_model","Control values must match the exact purchased resistor MPNs")
    if r[7]!=10000 or any(r[i]*1.01*1e-6>=.5 for i in (6,7)):
        fail(errors,"default_off","Require 10k gate discharge and leakage below 0.5V")
    weak_source=50000+r[1]*.99;pull=r[2]*1.01
    weak_pull_base=3.63*pull/(weak_source+pull)+1e-6*weak_source*pull/(weak_source+pull)
    if weak_pull_base>=.35:
        fail(errors,"gpio_weak_pull","Released GPIO exceeds 0.35V under the 3.63V/50k weak-source model")
    aux_min,aux_max,load,input_load=4.75,5.25,4.25,4.46
    fuse_drop,holder_ohms,copper_drop,driver_drop=.100,.010,.020,.005
    fused_min=aux_min-fuse_drop-input_load*holder_ohms-copper_drop
    gate_min=fused_min-.4
    base_min=(2.4-.95)/(r[1]*1.01)-.95/(r[2]*.99)
    sink_peak=aux_max/(r[5]*.99)
    pnp_base_min=(fused_min-.95-.2)/(r[5]*1.01)-.95/(r[6]*.99)
    pnp_load_max=aux_max/(r[7]*.99)+5e-6
    gate_charge_current=10*pnp_base_min-pnp_load_max
    gate_slew=48e-9/gate_charge_current if gate_charge_current>0 else math.inf
    bleed_max=aux_max**2/(r[8]*.99)
    pickup_100C=3.5*(1+.004*(100-23))
    pickup_voltage=aux_min-fuse_drop-.150*holder_ohms-copper_drop-driver_drop
    loaded_voltage=fused_min-driver_drop
    if (base_min<sink_peak/10 or pnp_base_min<pnp_load_max/10 or gate_min<4
            or gate_slew>.001 or pickup_voltage<pickup_100C or loaded_voltage<pickup_100C):
        fail(errors,"driver_margin","GPIO, gate drive or relay pickup model failed")
    if bleed_max>.5 or "1W" not in components['R8'][2]:
        fail(errors,"discharge","Require 1W bleeder with less than 0.5W dissipation")
    # Direct bidirectional TVS clamp: no series ordinary flyback diode.
    drain_clamp=aux_max+10.5
    if drain_clamp>=55 or aux_max>=16:
        fail(errors,"coil_clamp","Drain or gate voltage exceeds selected IRLZ44N rating")
    main_pulse=.010*aux_max**2/(2*.016)
    rm,rt=.050,.130
    rp=rm*rt/(rm+rt)
    touch_panel=.010*aux_max**2/(2*rp)*(rm/(rm+rt))**2
    local_pulse=.000180*aux_max**2/(2*rt)
    touch_bound=(math.sqrt(touch_panel)+math.sqrt(local_pulse))**2
    return {"aux_input_min_V":aux_min,"aux_input_max_V":aux_max,"combined_design_load_A":load,
            "aux_voltage_reference":"J1 terminals before F1; relay assessment, not screen voltage guarantee",
            "total_input_design_A":input_load,"input_fuse_working_drop_V":fuse_drop,
            "input_holder_total_ohms":holder_ohms,"copper_drop_budget_V":copper_drop,
            "power_relay_pickup_min_V":pickup_voltage,"power_relay_loaded_min_V":loaded_voltage,
            "power_relay_winding_max_C_assumption":100,"power_relay_pickup_100C_model_V":pickup_100C,
            "power_relay_hot_pickup_margin_V":pickup_voltage-pickup_100C,
            "power_relay_loaded_pickup_stress_margin_V":loaded_voltage-pickup_100C,
            "power_relay_actual_pickup_state":"NO contact open: no screen load before contact make",
            "bleeder_design_A":.06,"switched_rail_design_A":load+.06,
            "power_relay_contact_loss_W_at_initial_30mohm":(load+.06)**2*.030,
            "power_relay_driver_hot_loss_W_model":.050**2*.070,
            "drain_clamp_upper_V_model":drain_clamp,"gate_min_V":gate_min,
            "gate_charge_time_s_for_48nC_model":gate_slew,
            "gpio_base_min_mA":base_min*1000,"gpio_weak_pull_base_max_V":weak_pull_base,
            "gpio_weak_pull_is_design_envelope_not_RP1_guarantee":True,
            "collector_peak_mA":sink_peak*1000,"bleeder_max_W":bleed_max,
            "usb_presence_and_relay_margins":usb_power_margins(components,errors),
            "main_continuous_fuse_design_A":3,"touch_continuous_fuse_design_A":.5,
            "fuse_60C_factor_working_from_Bel_family_graph":.9,
            "fuse_derated_continuous_main_A":4*.9,"fuse_derated_continuous_touch_A":.8*.9,
            "main_10mF_typical_R_pulse_A2s":main_pulse,"main_fraction_typical_melting":main_pulse/81,
            "touch_joined_10mF_plus_180uF_pulse_A2s":touch_bound,"touch_fraction_typical_melting":touch_bound/2.3,
            "fuse_pulse_scope":"ideal-step sensitivities; no guaranteed minimum or repetitive clearing claim",
            "fuse_DC_scope":"Bel 0697H: 4A 72VDC, 800mA 100VDC; both 200A interruption at 72VDC",
            "branch_fuse_working_drop_V":{"main_at_3A":.080,"touch_at_0p5A":.150},
            "branch_drop_scope":"rated-current maxima used as working allowances; not manufacturer hot maxima",
            "fuse_overload_max_test_seconds":{"2x":60},
            "fault_scope":"No guaranteed cable insulation temperature or buck current-limit dynamics",
            "startup":"relay hard make; bounded capacitance/pulse model, no active current limiter",
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


USB_POWER_FAULTS = (
    "usb_power_baseline_passes", "host_coil_supply_detected",
    "presence_gate_bypass_detected", "cross_host_presence_detected",
    "missing_presence_pulldown_detected", "missing_presence_series_detected",
    "weak_presence_pulldown_detected", "short_presence_series_detected",
    "upper_driver_body_diode_detected", "lower_driver_body_diode_detected",
    "host_reservoir_detected",
    "presence_tolerance_suffix_detected",
) + tuple(f"{ref}_{fault}_detected" for ref in USB_HEADER_REFS
          for fault in ("wrong_shield_net", "missing_shield_pin")) + tuple(
    f"{ref}_obsolete_shield_pad_detected" for ref in OBSOLETE_SHIELD_REFS)

USB_HEADER_FAULTS = ("usb_header_baseline_passes", "wrong_xh_pitch_detected",
                     "missing_native_shield_pin_detected", "duplicate_xh_terminal_detected",
                     "wrong_native_shield_net_detected", "four_pin_xh_footprint_detected",
                     "obsolete_native_shield_pad_detected")


def usb_header_self_test(board_path):
    """Mutate native connector geometry/nets independently of netlist parity."""
    baseline = []
    check_usb_headers(load_board(board_path), baseline)
    results = {"usb_header_baseline_passes": not baseline}
    if baseline:
        return {name: False for name in USB_HEADER_FAULTS}
    for name in USB_HEADER_FAULTS[1:]:
        altered = load_board(board_path)
        header = next(f for f in altered.GetFootprints() if f.GetReference() == "J101")
        shield = next(pad for pad in header.Pads() if pad.GetNumber() == "5")
        if name == "wrong_xh_pitch_detected":
            shield.SetPosition(shield.GetPosition() + p.VECTOR2I(0, p.FromMM(.04)))
        elif name == "missing_native_shield_pin_detected":
            header.RemoveNative(shield)
        elif name == "duplicate_xh_terminal_detected":
            shield.SetNumber("4")
        elif name == "wrong_native_shield_net_detected":
            shield.SetNet(next(pad for pad in header.Pads() if pad.GetNumber() == "1").GetNet())
        elif name == "four_pin_xh_footprint_detected":
            header.SetFPID(p.LIB_ID("Connector_JST", "JST_XH_B4B-XH-A_1x04_P2.50mm_Vertical"))
        elif name == "obsolete_native_shield_pad_detected":
            obsolete = p.FOOTPRINT(altered)
            obsolete.SetReference("TP101")
            altered.Add(obsolete)
        issues = []
        check_usb_headers(altered, issues)
        results[name] = not baseline and any(e["check"] == "usb_header" for e in issues)
    return results


def usb_power_self_test(variant, pins, components):
    def inspect(wiring, parts):
        nets={}
        for terminal,name in wiring.items():nets.setdefault(name,set()).add(terminal)
        issues=[]
        check_contract(variant,wiring,nets,issues)
        usb_power_margins(parts,issues)
        check_usb_power_states(wiring,parts,issues)
        return issues
    baseline=inspect(pins,components)
    results={"usb_power_baseline_passes":not baseline}
    for name,changes,required_check in (
            ("host_coil_supply_detected",{("K101","1"):"HOST1_5V"},"supply_boundary"),
            ("presence_gate_bypass_detected",{("Q102","2"):"DATA_ENABLE"},"usb_relay_state"),
            ("cross_host_presence_detected",{("R101","1"):"HOST2_5V"},"usb_relay_state"),
            ("missing_presence_pulldown_detected",{("R102","2"):None},"usb_relay_state"),
            ("missing_presence_series_detected",{("R101","1"):None},"usb_relay_state"),
            ("upper_driver_body_diode_detected",{("Q102","1"):"S1_DATA_COIL_LOW",("Q102","3"):"S1_RELAY_STACK"},"usb_relay_state"),
            ("lower_driver_body_diode_detected",{("Q101","1"):"S1_RELAY_STACK",("Q101","3"):"GND"},"usb_relay_state"),
            ("host_reservoir_detected",{("C101","1"):"HOST1_5V"},"supply_boundary")):
        changed=dict(pins)
        for pin,net in changes.items():
            if net is None:changed.pop(pin)
            else:changed[pin]=net
        issues=inspect(changed,components)
        results[name]=not baseline and any(e["check"]==required_check for e in issues)
    for ref in USB_HEADER_REFS:
        for fault, net in (("wrong_shield_net", "HOST1_5V"), ("missing_shield_pin", None)):
            changed = dict(pins)
            if net is None:
                changed.pop((ref, "5"), None)
            else:
                changed[(ref, "5")] = net
            results[f"{ref}_{fault}_detected"] = not baseline and any(
                e["check"] == "circuit_contract" for e in inspect(changed, components))
    for ref in OBSOLETE_SHIELD_REFS:
        changed = dict(pins)
        changed[(ref, "1")] = "GND"
        results[f"{ref}_obsolete_shield_pad_detected"] = not baseline and any(
            e["check"] == "usb_shield" for e in inspect(changed, components))
    for name,ref,value in (("weak_presence_pulldown_detected","R102","100M 1%"),
                           ("short_presence_series_detected","R101","0R 1%"),
                           ("presence_tolerance_suffix_detected","R101","10k 91%")):
        changed=dict(components);changed[ref]=(*components[ref][:2],value)
        results[name]=not baseline and any(e["check"]=="usb_sense_components"
                                           for e in inspect(pins,changed))
    return results



def power_source_self_test(variant, pins, components):
    def inspect(wiring, parts):
        nets = {}
        for terminal, name in wiring.items():
            nets.setdefault(name, set()).add(terminal)
        issues = []
        check_contract(variant, wiring, nets, issues)
        numerical_checks(variant, parts, issues)
        check_power_relay_states(wiring, issues)
        return issues
    baseline = inspect(pins, components)
    results = {"power_source_baseline_passes":not baseline}
    for name, ref, value in (
        ("wrong_relay_detected","K101","IM06TS"),
        ("wrong_driver_detected","Q101","BS170"),
        ("wrong_tolerance_detected","R5","5.6k 20%"),
        ("wrong_tolerance_suffix_detected","R5","5.6k 11%"),
        ("weak_pulldown_detected","R7","100M 1%"),
        ("weak_gpio_pulldown_detected","R2","100k 1%"),
        ("excess_gpio_shunt_detected","R2","22R 1%"),
        ("weak_buffer_pullup_detected","R6","1M 1%"),
        ("weak_buffer_drive_detected","R5","100k 1%"),
        ("wrong_power_relay_detected","K1","G6C-2117P-US"),
        ("wrong_power_driver_detected","Q5","IRFZ44N"),
        ("unidirectional_coil_clamp_detected","D3","P6KE6.8A"),
        ("wrong_input_fuse_detected","F1","6.3A time-lag"),
        ("wrong_touch_fuse_detected","F102","1A time-lag"),
        ("weak_bleeder_rating_detected","R8","100R 0.25W 1%")):
        changed = dict(components); changed[ref] = (*components[ref][:2], value)
        results[name] = not baseline and bool(inspect(pins, changed))
    for name, changes in (
        ("input_fuse_bypass_detected",{("J1","1"):"AUX_5V"}),
        ("power_driver_body_diode_detected",{("Q5","2"):"GND",("Q5","3"):"POWER_COIL_LOW"}),
        ("switched_coil_supply_detected",{("K1","8"):"SWITCHED_5V"}),
        ("power_contact_bypass_detected",{("K1","3"):"AUX_5V"}),
        ("wrong_power_relay_pins_detected",{("K1","3"):"POWER_COIL_LOW",("K1","1"):"SWITCHED_5V"}),
        ("gpio_aux_bridge_detected",{("Q2","1"):"PI_GPIO17"}),
        ("wrong_coil_clamp_net_detected",{("D3","2"):"SWITCHED_5V"}),
        ("raw_aux_load_detected",{("C2","1"):"AUX_5V_IN"})):
        changed = dict(pins); changed.update(changes)
        results[name] = not baseline and bool(inspect(changed, components))
    records = json.loads((HERE / variant / "components.json").read_text())
    with (HERE / variant / "bom.csv").open() as stream:
        bom = list(csv.DictReader(stream))
    baseline = []; check_part_records(components, records, bom, baseline)
    results["bom_baseline_passes"] = not baseline
    for name, ref, key, value in (
        ("wrong_bom_power_relay_detected","K1","mpn","G6C-2117P-US DC5"),
        ("wrong_bom_fuse_detected","F101","mpn","BK1/S506-4-R"),
        ("wrong_bom_clamp_detected","D3","mpn","P6KE6.8A"),
        ("wrong_bom_branch_footprint_detected","F102","footprint","Fuse:Axial")):
        changed = [dict(row) for row in records]
        next(row for row in changed if row["ref"] == ref)[key] = value
        issues = []; check_part_records(components, changed, bom, issues)
        results[name] = not baseline and any(e["check"] == "bom_identity" for e in issues)
    # Keep every generated record consistent with the wrong connector so only
    # the independent part-selection contract can reject these faults.
    for name, key, value in (
        ("four_pin_xh_purchase_detected", "mpn", "B4B-XH-A(LF)(SN)"),
        ("four_pin_xh_record_detected", "footprint", "Connector_JST:JST_XH_B4B-XH-A_1x04_P2.50mm_Vertical"),
        ("unpopulated_component_detected", "quantity", 0)):
        changed_records = [dict(row) for row in records]
        changed_bom = [dict(row) for row in bom]
        changed_components = dict(components)
        for rows in (changed_records, changed_bom):
            next(row for row in rows if row["ref"] == "J101")[key] = value
        if key == "footprint":
            changed_components["J101"] = (*value.split(":", 1), components["J101"][2])
        issues = []
        check_part_records(changed_components, changed_records, changed_bom, issues)
        results[name] = not baseline and any(e["check"] == "bom_identity" for e in issues)
    for name, changed in (
        ("missing_input_holder_purchase_detected",[row for row in bom if row["ref"] != "F1_HOLDER"]),
        ("duplicate_input_holder_purchase_detected",bom + [dict(bom[-1])]),
        ("obsolete_branch_clip_purchase_detected",bom + [{"ref":"BRANCH_CLIPS","mpn":"3521","quantity":"8"}])):
        issues = []; check_part_records(components, records, changed, issues)
        results[name] = not baseline and any(e["check"] == "bom_identity" for e in issues)
    return results


def self_test(board_path, components, expected, temp, variant="hand"):
    _, raw_nets = parse_netlist(HERE / variant / f"screen_power_{variant}.net")
    results = relay_contact_self_test(raw_nets)
    results.update(usb_header_self_test(board_path))
    results.update(usb_power_self_test(variant,expected,components))
    results.update(power_source_self_test(variant, expected, components))
    for name, kind, check_name in (
            ("small_silk_text_detected", "reference", "silk_text_height"),
            ("thin_silk_text_detected", "label", "silk_text_stroke"),
            ("thin_silk_outline_detected", "outline", "silk_outline_stroke")):
        altered = load_board(board_path)
        baseline = []
        check_silkscreen(altered, baseline)
        if kind == "reference":
            item = next(f for f in altered.GetFootprints() if f.GetReference() == "K1").Reference()
            item.SetTextHeight(p.FromMM(.99))
        elif kind == "label":
            item = next(t for t in altered.GetDrawings() if isinstance(t, p.PCB_TEXT)
                        and t.GetLayer() in (p.F_SilkS, p.B_SilkS)
                        and t.IsVisible() and t.GetShownText(False).strip())
            item.SetTextThickness(p.FromMM(.14))
        else:
            footprint = next(f for f in altered.GetFootprints() if f.GetReference() == "Q5")
            item = next(t for t in footprint.GraphicalItems() if isinstance(t, p.PCB_SHAPE)
                        and t.GetLayer() in (p.F_SilkS, p.B_SilkS) and not t.IsSolidFill())
            item.SetWidth(p.FromMM(.14))
        issues = []
        check_silkscreen(altered, issues)
        results[name] = not baseline and any(e["check"] == check_name for e in issues)
    settings = json.loads(board_path.with_suffix(".kicad_pro").read_text())["board"]["design_settings"]
    baseline = []
    check_silkscreen_rules(settings, baseline)
    settings["rules"]["min_silk_clearance"] = .14
    issues = []
    check_silkscreen_rules(settings, issues)
    results["weak_silk_clearance_rule_detected"] = not baseline and any(e["check"] == "silk_rules" for e in issues)
    altered = load_board(board_path)
    baseline = []
    check_silk_mask_clearance(altered, baseline)
    terminal = next(pad for fp in altered.GetFootprints() if fp.GetReference() == "J1"
                    for pad in fp.Pads() if pad.GetNumber() == "1")
    opening = p.SHAPE_POLY_SET()
    terminal.TransformShapeToPolygon(opening, p.F_Cu, terminal.GetSolderMaskExpansion(p.F_Cu),
                                     100, p.ERROR_OUTSIDE)
    box = opening.BBox()
    # A valid-width native line with a 0.10 mm ink-to-mask gap. This is outside
    # the aperture, so an overlap-only test cannot detect the intended fault.
    x, y = box.GetCenter().x, box.GetTop() - p.FromMM(.175)
    line = p.PCB_SHAPE(altered, p.SHAPE_T_SEGMENT)
    line.SetLayer(p.F_SilkS)
    line.SetWidth(p.FromMM(.15))
    line.SetStart(p.VECTOR2I(x-p.FromMM(.3), y))
    line.SetEnd(p.VECTOR2I(x+p.FromMM(.3), y))
    altered.Add(line)
    issues = []
    check_silk_mask_clearance(altered, issues)
    results["short_silk_mask_gap_detected"] = not baseline and any(
        e["check"] == "silk_mask_clearance" for e in issues)
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
    for ref,old_drill in [('J101',.95),('J2',1.0),('J1',1.7),('Q1',.8),('H1',3.2),('K1',1.1),('F1',1.3),('F101',.8),('Q5',1.2)]:
        altered=load_board(board_path)
        fp=next(f for f in altered.GetFootprints() if f.GetReference()==ref)
        next(iter(fp.Pads())).SetDrillSize(p.VECTOR2I(p.FromMM(old_drill),p.FromMM(old_drill)))
        hole_errors=[];check_through_hole(altered,hole_errors)
        results[f'{ref}_hole_tolerance_detected']=any(e['check']=='hole_tolerance' for e in hole_errors)
    for ref in ("F1", "K1", "Q5", "F101"):
        altered = load_board(board_path)
        footprint = next(f for f in altered.GetFootprints() if f.GetReference() == ref)
        terminal = next(iter(footprint.Pads()))
        terminal.SetPosition(terminal.GetPosition() + p.VECTOR2I(p.FromMM(.2), 0))
        issues = []; check_through_hole(altered, issues)
        results[f"{ref}_pin_pitch_detected"] = any(e["check"] == "part_geometry" for e in issues)
    altered = load_board(board_path)
    footprint = next(f for f in altered.GetFootprints() if f.GetReference() == "K1")
    origin = footprint.GetPosition()
    for terminal in footprint.Pads():
        at = terminal.GetPosition()
        terminal.SetPosition(p.VECTOR2I(2*origin.x-at.x, at.y))
    issues = []; check_through_hole(altered, issues)
    results["mirrored_power_relay_detected"] = any(
        e["check"] == "part_geometry" and "mirrored" in e["detail"] for e in issues)
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
    device=next(f for f in altered.GetFootprints() if f.GetReference()=="Q5")
    next(iter(device.Pads())).SetDrillSize(p.VECTOR2I(p.FromMM(1.1),p.FromMM(1.1)))
    hole_errors=[];check_through_hole(altered,hole_errors)
    results["power_lead_hole_detected"]=any(e["check"]=="hand_assembly" for e in hole_errors)
    # Mutate a whole run so neighboring round end caps cannot disguise a
    # narrowed neck. Every test starts from the same unmodified native board.
    def power_fault(name, mutate, code, detail=None):
        altered = load_board(board_path)
        changed = mutate(altered)
        target = temp / f"{name}.kicad_pcb"; altered.Save(str(target))
        issues = []; check_power(target, issues, variant)
        results[name] = bool(changed) and any(
            e["check"] == code and (detail is None or detail in e["detail"]) for e in issues)
    def narrow(net, layer, above, width):
        def mutate(board):
            changed = 0
            for item in board.GetTracks():
                if (not isinstance(item,p.PCB_VIA) and net_name(item.GetNetname()) == net
                        and (layer is None or item.GetLayer() == layer)
                        and item.GetWidth() > p.FromMM(above)+1):
                    item.SetWidth(p.FromMM(width)); changed += 1
            return changed
        return mutate
    for name, net, layer, above, width, detail in (
        ("narrow_power_detected","S1_MAIN_5V",None,0,.15,"J103"),
        ("narrow_raw_feed_detected","AUX_5V_IN",p.F_Cu,0,3.99,"J1"),
        ("narrow_aux_main_detected","AUX_5V",p.F_Cu,1,4.99,"K1"),
        ("narrow_bulk_feed_detected","AUX_5V",p.F_Cu,0,.25,"C2"),
        ("narrow_coil_feed_detected","AUX_5V",p.F_Cu,0,.25,"K1"),
        ("narrow_switched_feed_detected","SWITCHED_5V",p.B_Cu,.25,3.49,"F101"),
        ("narrow_switched_taps_detected","SWITCHED_5V",p.F_Cu,.25,2.99,"F201")):
        power_fault(name,narrow(net,layer,above,width),"power_copper",detail)
    def remove_run(net, layer, width=None):
        def mutate(board):
            victims=[t for t in board.GetTracks() if not isinstance(t,p.PCB_VIA)
                     and net_name(t.GetNetname())==net and t.GetLayer()==layer
                     and (width is None or abs(t.GetWidth()-p.FromMM(width))<=1)]
            for item in victims:board.RemoveNative(item)
            return len(victims)
        return mutate
    power_fault("missing_aux_main_detected",remove_run("AUX_5V",p.F_Cu,5),"power_copper","K1")
    power_fault("missing_bus_under_overlay_detected",remove_run("SWITCHED_5V",p.F_Cu,4.5),"power_copper","F201")
    def narrow_spine(board):
        victims=[t for t in board.GetTracks() if not isinstance(t,p.PCB_VIA)
                 and net_name(t.GetNetname())=="SWITCHED_5V" and t.GetLayer()==p.F_Cu
                 and abs(t.GetWidth()-p.FromMM(4.5))<=1]
        for item in victims:item.SetWidth(p.FromMM(4.49))
        return len(victims)
    power_fault("narrow_spine_detected",narrow_spine,"power_spine")
    for net, width, name in (("AUX_5V_IN",4,"nonuniform_raw_middle_detected"),
                             ("AUX_5V",5,"nonuniform_aux_middle_detected")):
        def widen_middle(board, net=net, width=width):
            terminals={(pad.GetPosition().x,pad.GetPosition().y) for fp in board.GetFootprints()
                       for pad in fp.Pads() if net_name(pad.GetNetname())==net}
            middle=[t for t in board.GetTracks() if not isinstance(t,p.PCB_VIA)
                    and net_name(t.GetNetname())==net and t.GetLayer()==p.F_Cu
                    and abs(t.GetWidth()-p.FromMM(width))<=1
                    and all((end.x,end.y) not in terminals for end in (t.GetStart(),t.GetEnd()))]
            if middle:max(middle,key=lambda t:t.GetLength()).SetWidth(p.FromMM(width+.5))
            return bool(middle)
        power_fault(name,widen_middle,"uniform_power_width")
    for net,layer,width,name in (("AUX_5V_IN",p.F_Cu,4,"raw_taper_detected"),
                                 ("SWITCHED_5V",p.B_Cu,3.5,"switched_taper_detected"),
                                 ("AUX_5V",p.F_Cu,5,"aux_taper_detected")):
        def overlay(board, net=net, layer=layer, width=width):
            routes=[t for t in board.GetTracks() if not isinstance(t,p.PCB_VIA)
                    and net_name(t.GetNetname())==net and t.GetLayer()==layer
                    and abs(t.GetWidth()-p.FromMM(width))<=1]
            if not routes:return False
            track=max(routes,key=lambda t:t.GetLength());a,b=track.GetStart(),track.GetEnd()
            dx,dy=b.x-a.x,b.y-a.y;length=math.hypot(dx,dy)
            zone=p.ZONE(board);zone.SetLayer(layer);zone.SetNet(board.GetNetsByName()[net])
            zone.SetZoneName("POWER_TAPER");zone.SetAssignedPriority(20)
            poly=zone.Outline();poly.NewOutline()
            for at,taper_width,sign in ((a,width,1),(b,width+1,1),(b,width+1,-1),(a,width,-1)):
                poly.Append(round(at.x-sign*dy/length*p.FromMM(taper_width)/2),
                            round(at.y+sign*dx/length*p.FromMM(taper_width)/2))
            board.Add(zone);return True
        power_fault(name,overlay,"uniform_power_taper")
    for fault in ("missing","small_drill","disconnected"):
        def alter_vias(board, fault=fault):
            changed=0
            for via in list(board.GetTracks()):
                if not isinstance(via,p.PCB_VIA) or net_name(via.GetNetname())!="SWITCHED_5V":continue
                changed+=1
                if fault=="missing":board.RemoveNative(via)
                elif fault=="small_drill":via.SetDrill(p.FromMM(.3))
                else:via.SetPosition(p.VECTOR2I(p.FromMM(-10),p.FromMM(-10)))
            return changed
        power_fault(f"{fault}_power_vias_detected",alter_vias,"power_vias")
    def isolate_front_stitch(board):
        # Leave the front stitch pad and all three vias attached to the rear
        # feeder. Remove its outward front connection; the fuse barrel alone
        # must not make this appear to be a redundant current transition.
        victims=[t for t in board.GetTracks() if not isinstance(t,p.PCB_VIA)
                 and net_name(t.GetNetname())=="SWITCHED_5V" and t.GetLayer()==p.F_Cu
                 and abs(t.GetWidth()-p.FromMM(3))<=1]
        if not victims:return False
        # Removing all tap routes preserves via geometry but breaks their
        # onward copper independently of the F101 barrel.
        for item in victims:board.RemoveNative(item)
        return True
    power_fault("redundant_power_vias_detected",isolate_front_stitch,"power_via_bypass")
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
    paths = {path for path in HERE.glob("*.py") if not path.name.endswith("_sklib.py")}
    paths.update(HERE.glob("*.kicad_sym"))
    paths.add(HERE / "build.sh")
    paths.update(path for path in (HERE / "models").rglob("*") if path.is_file())
    paths.add(HERE / "external_bom.csv")
    paths.update((HERE / "screen_power.pretty").glob("*.kicad_mod"))
    paths.add(HERE.parent / "netlist.py")
    paths.add(HERE.parent / "round_routes.py")
    paths.add(HERE.parent / "silkscreen.py")
    paths.add(HERE.parent / "console_board.net")
    paths.add(HERE.parent / "out_console/segno_console_board.kicad_pcb")
    paths.add(board_path)
    paths.add(board_path.with_suffix(".kicad_pro"))
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
        summary["power_relay_states"] = check_power_relay_states(pins, errors)
        records = json.loads((folder / "components.json").read_text())
        with (folder / "bom.csv").open() as stream:
            summary["part_identity"] = check_part_records(components, records, list(csv.DictReader(stream)), errors)
        summary["relay_contact_behavior"] = check_relay_contacts(raw_nets, errors)
        summary["usb_relay_power_states"] = check_usb_power_states(pins, components, errors)
        check_geometry(board, errors, variant)
        check_silkscreen(board, errors)
        check_silk_mask_clearance(board, errors)
        project_settings = json.loads(board_path.with_suffix(".kicad_pro").read_text())["board"]["design_settings"]
        check_silkscreen_rules(project_settings, errors)
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
                required_faults = ["wrong_relay_detected", "wrong_driver_detected", "wrong_tolerance_detected", "wrong_tolerance_suffix_detected", "weak_pulldown_detected", "narrow_power_detected", "host_power_bridge_detected", "usb_cut_detected", "console_control_cut_detected"]
                required_faults += list(USB_POWER_FAULTS)
                required_faults += list(USB_HEADER_FAULTS)
                required_faults += ["weak_gpio_pulldown_detected", "excess_gpio_shunt_detected"]
                required_faults += ["relay_hole_detected", "model_unassigned_detected", "model_missing_detected", "model_disabled_detected", "wrong_xh_pitch_detected"]
                required_faults += ["smd_footprint_detected", "smd_pad_detected", "power_lead_hole_detected", "four_layers_detected", "missing_usb_reference_detected"]
                required_faults += [f'{ref}_hole_tolerance_detected' for ref in ('J101','J2','J1','Q1','H1','K1','F1','F101','Q5')]
                required_faults += list(power_source_self_test(variant, pins, components))
                required_faults += [f"{ref}_pin_pitch_detected" for ref in ("F1","K1","Q5","F101")]
                required_faults += ["mirrored_power_relay_detected"]
                required_faults += ['fastener_short_detected']
                required_faults += ["small_silk_text_detected", "thin_silk_text_detected",
                                    "thin_silk_outline_detected", "weak_silk_clearance_rule_detected",
                                    "short_silk_mask_gap_detected"]
                required_faults += ["relay_contact_baseline_passes", "relay_old_host_pins_detected",
                                    "relay_wrong_throw_detected", "relay_polarity_swap_detected",
                                    "relay_cross_channel_detected", "relay_no_connects_isolated",
                                    "narrow_raw_feed_detected", "narrow_bulk_feed_detected",
                                    "narrow_coil_feed_detected", "narrow_switched_feed_detected",
                                    "narrow_switched_taps_detected", "narrow_spine_detected", "missing_bus_under_overlay_detected",
                                    "nonuniform_raw_middle_detected", "raw_taper_detected", "switched_taper_detected",
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
