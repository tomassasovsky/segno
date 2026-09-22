"""Validate delivered screen-power boards with KiCad's Python and CLI.

Usage: python3 check.py [hand|factory|all] [--output report.json] [--self-test]
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
    hand = variant == "hand"
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
    require("Q1", {1:"GND",2:"CONTROL_BASE",3:"CONTROL_SINK"} if hand else {1:"CONTROL_BASE",2:"GND",3:"CONTROL_SINK"})
    require("R3", {1:"CONTROL_SINK",2:"POWER_GATE"})
    require("R4", {1:"POWER_GATE",2:"COMMON_SOURCE"})
    require("D1", {1:"CONTROL_SINK",2:"BUFFER_SINK"})
    require("R5", {1:"BUFFER_SINK",2:"BUFFER_BASE"})
    require("R6", {1:"AUX_5V",2:"BUFFER_BASE"})
    require("R7", {1:"DATA_ENABLE",2:"GND"})
    require("R8", {1:"SWITCHED_5V",2:"GND"})
    require("Q2", {1:"AUX_5V",2:"BUFFER_BASE",3:"DATA_ENABLE"} if hand else {1:"BUFFER_BASE",2:"AUX_5V",3:"DATA_ENABLE"})
    for ref, drain in (("Q3","AUX_5V"),("Q4","SWITCHED_5V")):
        require(ref, {1:"POWER_GATE",2:drain,3:"COMMON_SOURCE"})
    nodes("COMMON_SOURCE", {("Q3","3"),("Q4","3"),("R4","2")})
    nodes("POWER_GATE", {("Q3","1"),("Q4","1"),("R3","2"),("R4","1")})
    nodes("CONTROL_SINK", {("Q1","3"),("R3","1"),("D1","1")})
    for ch in (1,2):
        n=100*ch; pre=f"S{ch}"; host=f"HOST{ch}_5V"; coil=f"{pre}_DATA_COIL_LOW"
        for offset, rail, side in ((1,host,"UP"),(2,pre+"_TOUCH_5V","DN")):
            require(f"J{n+offset}", {1:rail,2:pre+f"_{side}_N",3:pre+f"_{side}_P",4:"GND","SH":"GND"})
        require(f"J{n+3}", {1:pre+"_MAIN_5V",2:"GND"})
        require(f"F{n+1}", {1:"SWITCHED_5V",2:pre+"_MAIN_5V"})
        require(f"F{n+2}", {1:"SWITCHED_5V",2:pre+"_TOUCH_5V"})
        require(f"K{n+1}", {1:host,8:coil,3:pre+"_UP_N",6:pre+"_UP_P",4:pre+"_DN_N",5:pre+"_DN_P","SH":"GND"})
        if any((f"K{n+1}",pin) in pins for pin in ("2","7")):
            fail(errors,"relay_contacts",f"K{n+1}: normally closed contacts must be unconnected")
        require(f"Q{n+1}", {1:"GND",2:"DATA_ENABLE",3:coil} if hand else {1:"DATA_ENABLE",2:"GND",3:coil})
        require(f"D{n+1}", {1:host,2:coil})
        nodes(host, {(f"J{n+1}","1"),(f"K{n+1}","1"),(f"D{n+1}","1"),(f"C{n+1}","1")})
        for side, j, terminals in (("UP",n+1,{"P":6,"N":3}),("DN",n+2,{"P":5,"N":4})):
            for polarity, pin in (("P",3),("N",2)):
                nodes(f"{pre}_{side}_{polarity}",{(f"J{j}",str(pin)),(f"K{n+1}",str(terminals[polarity]))})


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
    from layout import DIMENSIONS
    w, h = DIMENSIONS[variant]
    if board.GetCopperLayerCount() != 4:
        fail(errors, "geometry", "Board must have four copper layers")
    edges = [d for d in board.GetDrawings() if d.GetLayer() == p.Edge_Cuts]
    expected = {frozenset((a, b)) for a, b in (
        ((0, 0), (w, 0)), ((w, 0), (w, h)),
        ((w, h), (0, h)), ((0, h), (0, 0)))}
    actual = {frozenset((tuple(round(p.ToMM(v), 5) for v in (d.GetStart().x, d.GetStart().y)),
                         tuple(round(p.ToMM(v), 5) for v in (d.GetEnd().x, d.GetEnd().y))))
              for d in edges if d.GetShape() == p.SHAPE_T_SEGMENT}
    if len(edges) != 4 or actual != expected:
        fail(errors, "geometry", f"Edge.Cuts must be the closed {w} × {h} mm rectangle")
    zones = [z for z in board.Zones() if not z.GetIsRuleArea()]
    if {z.GetLayer() for z in zones} != {p.In1_Cu, p.In2_Cu} or any(
            net_name(z.GetNetname()) != "GND" for z in zones):
        fail(errors, "ground_planes", "Copper zones must be GND on In1.Cu and In2.Cu only")
    for track in board.GetTracks():
        if not isinstance(track, p.PCB_VIA) and track.GetLayer() in (p.In1_Cu, p.In2_Cu):
            if net_name(track.GetNetname()) != "GND":
                fail(errors, "ground_planes", "A signal/power track interrupts an inner ground layer")


def check_usb(board, errors, variant="factory"):
    """Check physical connectivity, not just matching net labels."""
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
            if track.GetLayer() != p.B_Cu or abs(p.ToMM(track.GetWidth()) - 0.26) > 0.00001:
                fail(errors, "usb_geometry", f"{name}: data must use 0.26 mm B.Cu tracks")
            length += p.ToMM(track.GetLength())
        lengths[name] = round(length, 6)
    for ch, side in itertools.product((1, 2), ("UP", "DN")):
        name = f"S{ch}_{side}"
        skew = abs(lengths[name + "_P"] - lengths[name + "_N"])
        if skew > 2:
            fail(errors, "usb_skew", f"{name}: {skew:.3f} mm exceeds 2 mm")
    return lengths


def check_power(board_path, errors, variant):
    """Require continuous copper at the specified minimum power-path width.

    Strip thin control branches and single signal vias on fresh board copies;
    KiCad's geometric connectivity then proves a path between physical pads.
    This checks copper geometry, not its thermal/current rating.
    """
    paths=[(1.5,("J1","1"),("Q3","2")),(3 if variant=="factory" else 1.5,("Q3","3"),("Q4","3"))]
    for ch in (1,2):
        n=ch*100
        paths += [(1.5,("Q4","2"),(f"F{n+i}","1")) for i in (1,2)]
        paths += [(2.0,(f"F{n+1}","2"),(f"J{n+3}","1")),
                  (.8,(f"F{n+2}","2"),(f"J{n+2}","1"))]
    for minimum in sorted({path[0] for path in paths}):
        board=load_board(board_path)
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


def resistor_value(components, ref):
    text = components[ref][2]
    match = re.match(r"^(\d+(?:\.\d+)?)\s*([kKMmR]?)", text)
    if not match:
        raise ValueError(f"Unrecognized resistor value {ref}: {text}")
    return float(match[1]) * {"": 1, "R": 1, "k": 1000, "K": 1000,
                             "M": 1000000, "m": 0.001}[match[2]]


def numerical_checks(variant, components, errors):
    r = {i: resistor_value(components,f"R{i}") for i in range(1,9)}
    if any(value<=0 for value in r.values()):
        fail(errors,"resistor_model","Control resistances must be positive")
        return {}
    if any("1%" not in components[f"R{i}"][2] for i in r):
        fail(errors,"resistor_model","Drive margins require 1% resistors")
    hand=variant=="hand"
    models={"Q1":"2N3904" if hand else "MMBT3904", "Q2":"2N3906" if hand else "MMBT3906",
            "D1":"1N4148" if hand else "1N4148W"}
    for ch in (1,2):
        n=100*ch
        models.update({f"Q{n+1}":"2N7000" if hand else "2N7002",f"K{n+1}":"G6K-2P-RF DC5",
                       f"D{n+1}":"1N4007" if hand else "1N4148W"})
    for ref,model in models.items():
        if components[ref][2]!=model:
            fail(errors,"driver_model",f"{ref}: calculations require {model}")
    # A conservative 1uA off-state leakage budget at each pulled node;
    # elevated-temperature and assembled-device leakage still require testing.
    if any(r[i]*1.01*1e-6 >= .5 for i in (4,6,7)):
        fail(errors,"default_off","Pull resistances exceed the 1uA / 0.5V leakage budget")
    # Defined operating envelope: AUX 5.0–5.25V at the board, 6A maximum
    # combined design load. Hot resistance factor is an estimate, not a rating.
    v_source_min = 5.0 - 6*.015*1.7
    gate_min = (v_source_min-.2)*(r[4]*.99)/(r[4]*.99+r[3]*1.01)
    base_min = (2.4-.95)/(r[1]*1.01)-.95/(r[2]*.99)
    sink_peak = 5.25/(r[3]*.99)+5.25/(r[5]*.99)
    pnp_base_min = (5.0-.95-1.0-.2)/(r[5]*1.01)-.95/(r[6]*.99)
    pnp_load_max = 5.25/(r[7]*.99)+2e-6
    bleed_max = 5.25**2/(r[8]*.99)
    if gate_min < 4.5 or base_min < sink_peak/10 or pnp_base_min < pnp_load_max/10:
        fail(errors,"driver_margin","Insufficient gate or transistor drive in the stated envelope")
    if bleed_max > .5 or "1W" not in components['R8'][2]:
        fail(errors,"discharge","Bleeder must dissipate below 0.5W in its 1W part")
    model = "SUP70101EL" if variant=="hand" else "SUM70101EL"
    for ref in ("Q3","Q4"):
        if components[ref][2] != model:
            fail(errors,"power_device",f"{ref}: calculations require {model}")
    for ch in (1,2):
        if components[f"F{ch*100+1}"][2] != "4A fast" or components[f"F{ch*100+2}"][2] != "750mA fast":
            fail(errors,"fuse_rating","Unexpected branch fuse rating")
    return {"aux_input_min_V":5.0,"aux_input_max_V":5.25,"combined_design_load_A":6,
            "gate_min_V_with_estimated_hot_Rds":gate_min,"hot_Rds_factor_is_estimate":1.7,
            "gpio_assumed_minimum_high_V":2.4,"gpio_base_min_mA":base_min*1000,
            "collector_peak_mA":sink_peak*1000,"bleeder_max_W":bleed_max,
            "pair_loss_at_6A_25C_max_Rds_W":2*6**2*.015,
            "relay_initial_coil_min_V":4.75*(237*.9)/(237*.9+5.3),
            "host_relay_coil_nominal_mA":5000/237,
            "main_continuous_fuse_design_A":3,"touch_continuous_fuse_design_A":.5,
            "thermal_inrush_USB_suspend_and_fault_coordination":"require physical testing"}


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


def self_test(board_path, components, expected, temp, variant="factory"):
    results = {}
    console = load_board(HERE.parent / "out_console/segno_console_board.kicad_pcb")
    for item in list(console.GetTracks()):
        if net_name(item.GetNetname()) == "PI_GPIO17":
            console.RemoveNative(item)
    cut_console = temp / "cut-console-control.kicad_pcb"
    console.Save(str(cut_console))
    console_errors = []
    check_console_control(console_errors, cut_console)
    results["console_control_cut_detected"] = any(e["check"] == "console_control" for e in console_errors)
    if variant == "hand":
        from hand_checks import check_through_hole
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
    if variant=="hand":
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
    results["wrong_relay_detected"]=numeric_mutation("K101","G6K-2P-RF DC24")
    results["wrong_driver_detected"]=numeric_mutation("Q101","BS170")
    results["wrong_tolerance_detected"]=numeric_mutation("R3","4.7k 20%")
    results["weak_pulldown_detected"]=numeric_mutation("R7","100M 1%")
    narrowed=load_board(board_path)
    for track in narrowed.GetTracks():
        if not isinstance(track,p.PCB_VIA) and net_name(track.GetNetname())=="S1_MAIN_5V":
            track.SetWidth(p.FromMM(.15))
    narrow_path=temp/"narrow-power.kicad_pcb";narrowed.Save(str(narrow_path))
    power_errors=[];check_power(narrow_path,power_errors,variant)
    results["narrow_power_detected"]=any(e["check"]=="power_copper" for e in power_errors)
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
    return results


def source_hashes(folder, board_path):
    paths = {HERE / name for name in ("check.py", "circuit.py", "pcb.py", "route_critical.py", "schematic.py", "finish.py", "router.py", "export.py", "cleanup.py", "build.sh", "screen_power.kicad_sym", "switch_circuit.py", "layout.py")}
    paths.update(HERE.glob("hand_*.py"))
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
        check_geometry(board, errors, variant)
        summary["usb_track_lengths_mm"] = check_usb(board, errors, variant)
        check_power(board_path, errors, variant)
        if variant == "hand":
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
                if native_components != components:
                    fail(errors, "native_parity", "Native schematic components differ from generated netlist")
                for name in sorted(set(expected) | set(native)):
                    if expected.get(name) != native.get(name):
                        fail(errors, "native_parity", f"{name}: missing {sorted(expected.get(name, set())-native.get(name, set()))}; extra {sorted(native.get(name, set())-expected.get(name, set()))}")
            if run_self_test:
                summary["self_test"] = self_test(board_path, components, pins, temp, variant)
                required_faults = ["wrong_relay_detected", "wrong_driver_detected", "wrong_tolerance_detected", "weak_pulldown_detected", "narrow_power_detected", "host_power_bridge_detected", "usb_cut_detected", "console_control_cut_detected"]
                if variant == "hand":
                    required_faults += ["smd_footprint_detected", "smd_pad_detected", "power_lead_hole_detected"]
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
    parser.add_argument("variant", choices=("hand", "factory", "all"), nargs="?", default="all")
    parser.add_argument("--board", type=Path, help="Explicit board input; requires one variant")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.board and args.variant == "all":
        parser.error("--board requires hand or factory")
    if args.variant == "all":
        # Native connectivity/self-test wrappers can invalidate KiCad SWIG type
        # registrations before the next board is loaded. Isolate each variant.
        results = []
        with tempfile.TemporaryDirectory(prefix="screen-power-all-") as directory:
            for variant in ("hand", "factory"):
                destination = Path(directory) / f"{variant}.json"
                command = [sys.executable, str(Path(__file__).resolve()), variant,
                           "--output", str(destination)]
                if args.self_test:
                    command.append("--self-test")
                try:
                    process = subprocess.run(command, capture_output=True, text=True, timeout=480)
                    if process.returncode not in (0, 1) or not destination.is_file():
                        raise RuntimeError(f"Variant process exited {process.returncode} without a valid report")
                    child = json.loads(destination.read_text())
                    result, = child["variants"]
                    if result["variant"] != variant or bool(child["cad_ready"]) != (process.returncode == 0):
                        raise ValueError("Variant report disagrees with process result")
                    results.append(result)
                except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as exc:
                    results.append({"variant": variant, "cad_ready": False,
                                    "hardware_qualification": "not performed",
                                    "errors": [{"check": "variant_process", "detail": str(exc)}]})
    else:
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
