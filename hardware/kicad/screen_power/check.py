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
    if variant == "hand":
        from hand_checks import check_contract as hand_contract
        return hand_contract(pins, nets, errors)
    def require(ref, mapping):
        for number, name in mapping.items():
            got = pins.get((ref, str(number)))
            if got != name:
                fail(errors, "circuit_contract", f"{ref}.{number}: {got!r}, required {name}")

    require("J1", {1: "AUX_5V", 2: "GND"})
    require("J2", {1: "PI_GPIO17", 2: "GND"})
    if nets.get("PI_GPIO17") != {("J2", "1"), ("R1", "1")}:
        fail(errors,"pi_isolation","GPIO17 must connect only the control connector and series resistor")
    if any(name.startswith("PI_PIN_") for name in nets) or any(ref=="J3" for ref,_ in pins):
        fail(errors,"control_interface","Obsolete 40-pin pass-through remains in the circuit")
    require("R1", {1: "PI_GPIO17", 2: "DISPLAY_ENABLE"})
    require("R2", {1: "DISPLAY_ENABLE", 2: "GND"})
    require("Q1", {1: "DUMP_BASE", 2: "GND", 3: "DISCHARGE"})
    require("R3", {1: "DISPLAY_ENABLE", 2: "DUMP_BASE"})
    require("R4", {1: "DUMP_BASE", 2: "GND"})
    require("R5", {1: "AUX_5V", 2: "DISCHARGE"})
    for ch in (1, 2):
        n, pre = ch * 100, f"S{ch}"
        host, touch, main = f"HOST{ch}_5V", f"{pre}_TOUCH_5V", f"{pre}_MAIN_5V"
        require(f"J{n+1}", {1: host, 2: f"{pre}_UP_N", 3: f"{pre}_UP_P", 4: "GND", "SH": "GND"})
        require(f"J{n+2}", {1: touch, 2: f"{pre}_DN_N", 3: f"{pre}_DN_P", 4: "GND", "SH": "GND"})
        require(f"U{n+1}", {1: host, 2: "GND", 3: f"{pre}_VDD1", 4: "GND",
                5: f"{pre}_XI", 6: f"{pre}_XO", 7: "GND", 8: f"{pre}_UP_P",
                9: f"{pre}_UP_N", 10: "GND", 11: "GND", 12: f"{pre}_DN_P",
                13: f"{pre}_DN_N", 15: "GND", 16: "GND", 17: "GND",
                18: f"{pre}_VDD2", 19: "GND", 20: touch})
        host_nodes = {(f"J{n+1}", "1"), (f"U{n+1}", "1"),
                      (f"C{n+1}", "1"), (f"D{n+1}", "5")}
        if nets.get(host) != host_nodes:
            fail(errors, "host_isolation", f"{host} must feed only the upstream USB section")
        for j, side, rail in ((1, "UP", host), (2, "DN", touch)):
            require(f"D{n+j}", {1: f"{pre}_{side}_P", 6: f"{pre}_{side}_P",
                    3: f"{pre}_{side}_N", 4: f"{pre}_{side}_N", 2: "GND", 5: rail})
        for j, rail in enumerate((host, f"{pre}_VDD1", f"{pre}_VDD2", touch), 1):
            require(f"C{n+j}", {1: rail, 2: "GND"})
        require(f"U{n+2}", {2: f"{pre}_UFP_N", 3: "GND", 4: f"{pre}_TOUCH_EN", 5: "AUX_5V"})
        require(f"U{n+3}", {1: "AUX_5V", 2: "GND", 3: f"{pre}_TOUCH_EN", 5: f"{pre}_ILIM", 6: touch})
        require(f"R{n+1}", {1: "AUX_5V", 2: f"{pre}_UFP_N"})
        require(f"R{n+2}", {1: f"{pre}_TOUCH_EN", 2: "GND"})
        require(f"R{n+3}", {1: f"{pre}_ILIM", 2: "GND"})
        require(f"C{n+9}", {1: touch, 2: "GND"})
        for j, rail in enumerate((main, touch)):
            require(f"R{n+4+j}", {1: rail, 2: f"{pre}_DUMP{j}"})
            require(f"Q{n+1+j}", {1: "DISCHARGE", 2: "GND", 3: f"{pre}_DUMP{j}"})
        require(f"U{n+4}", {2: "AUX_5V", 3: "AUX_5V", 4: "AUX_5V", 5: "AUX_5V",
                6: "DISPLAY_ENABLE", 7: "AUX_5V", 8: "AUX_5V", 9: f"{pre}_REF_RTN",
                10: f"{pre}_REF", 11: f"{pre}_CC1", 12: "GND", 13: f"{pre}_CC2",
                14: main, 15: main, 19: f"{pre}_UFP_N", 21: "GND"})
        require(f"R{n+6}", {1: f"{pre}_REF", 2: f"{pre}_REF_RTN"})
        require(f"J{n+3}", {"A9": main, "B9": main, "A12": "GND", "B12": "GND",
                "A5": f"{pre}_CC1", "B5": f"{pre}_CC2", "SH": "GND"})


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


def check_geometry(board, errors):
    if board.GetCopperLayerCount() != 4:
        fail(errors, "geometry", "Board must have four copper layers")
    edges = [d for d in board.GetDrawings() if d.GetLayer() == p.Edge_Cuts]
    expected = {frozenset((a, b)) for a, b in (
        ((0, 0), (130, 0)), ((130, 0), (130, 120)),
        ((130, 120), (0, 120)), ((0, 120), (0, 0)))}
    actual = {frozenset((tuple(round(p.ToMM(v), 5) for v in (d.GetStart().x, d.GetStart().y)),
                         tuple(round(p.ToMM(v), 5) for v in (d.GetEnd().x, d.GetEnd().y))))
              for d in edges if d.GetShape() == p.SHAPE_T_SEGMENT}
    if len(edges) != 4 or actual != expected:
        fail(errors, "geometry", "Edge.Cuts must be the closed 130 × 120 mm rectangle")
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
        if not tracks or len(pads) != (2 if variant == "hand" else 4):
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
            if track.GetLayer() != p.F_Cu or abs(p.ToMM(track.GetWidth()) - 0.26) > 0.00001:
                fail(errors, "usb_geometry", f"{name}: data must use 0.26 mm F.Cu tracks")
            length += p.ToMM(track.GetLength())
        lengths[name] = round(length, 6)
    for ch, side in itertools.product((1, 2), ("UP", "DN")):
        name = f"S{ch}_{side}"
        skew = abs(lengths[name + "_P"] - lengths[name + "_N"])
        if skew > 2:
            fail(errors, "usb_skew", f"{name}: {skew:.3f} mm exceeds 2 mm")
    return lengths


def resistor_value(components, ref):
    text = components[ref][2]
    match = re.match(r"^(\d+(?:\.\d+)?)\s*([kKMmR]?)", text)
    if not match:
        raise ValueError(f"Unrecognized resistor value {ref}: {text}")
    return float(match[1]) * {"": 1, "R": 1, "k": 1000, "K": 1000,
                             "M": 1000000, "m": 0.001}[match[2]]


def numerical_checks(variant, components, errors):
    limits = {}
    for ch in (() if variant == "hand" else (1, 2)):
        ref = f"R{ch*100+3}"
        resistance = resistor_value(components, ref) / 1000
        low = 56850 / (resistance * 1.01) ** 1.033
        nominal = 55960 / resistance ** 1.004
        high = 52640 / (resistance * 0.99) ** 0.97
        limits[ref] = {"minimum_mA": low, "nominal_mA": nominal, "maximum_mA": high}
        if "1%" not in components[ref][2] or low < 569 or high > 800:
            fail(errors, "touch_current", f"{ref}: cannot guarantee 569–800 mA current-limit envelope")
    resistors = [resistor_value(components, f"R{i}") for i in range(1, 5)]
    # Two 100 kΩ pulldowns are mandatory off-board EVM assembly parts.
    external = [100000, 100000] if variant == "hand" else []
    enable, drive = [], []
    for factors in itertools.product((0.99, 1.01), repeat=4 + len(external)):
        r1, r2, r3, r4, *pulls = [a*b for a, b in zip(resistors + external, factors)]
        for vbe in (0.5, 0.95):
            ven = (2.4/r1 + vbe/r3) / (1/r1 + 1/r2 + 1/r3 + sum(1/r for r in pulls))
            enable.append(ven)
            drive.append((ven-vbe)/r3 - vbe/r4)
    if variant == "hand":
        from hand_checks import numerical_checks as hand_numerical
        limits = hand_numerical(components, errors)
    collector = 5.5 / (resistor_value(components, "R5") * 0.99)
    if min(enable) <= 1.17 or min(drive) < collector / 10:
        fail(errors, "gpio_margin", "Conservative GPIO high cannot guarantee source enable and NPN saturation")
    return {("hand_relay_checks" if variant == "hand" else "touch_current_limits"): limits, "gpio_assumed_minimum_high_V": 2.4,
            "enable_minimum_V": min(enable), "base_drive_minimum_mA": min(drive)*1000,
            "collector_maximum_mA": collector*1000,
            "hand_external_EN_pulldowns_ohms": external}


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
    paths = {HERE / name for name in ("check.py", "circuit.py", "pcb.py", "route_critical.py", "schematic.py", "finish.py", "router.py", "export.py", "cleanup.py", "build.sh", "screen_power.kicad_sym")}
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
        check_geometry(board, errors)
        summary["usb_track_lengths_mm"] = check_usb(board, errors, variant)
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
                required_faults = ["host_power_bridge_detected", "usb_cut_detected", "console_control_cut_detected"]
                if variant == "hand":
                    required_faults += ["smd_footprint_detected", "smd_pad_detected"]
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
