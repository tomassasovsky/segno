"""Through-hole screen carrier with external assembled Type-C source modules.

Each screen has separate RF data and touch-power relays. The data coil uses
only that USB host's VBUS; the power coil uses AUX. Their low-side drivers must
remain separate to avoid an electrical power path between those supplies.
"""

import builtins
import csv
import json
from pathlib import Path

import skidl as s

HERE = Path(__file__).resolve().parent
AXIAL = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
TO92 = "Package_TO_SOT_THT:TO-92_Inline_Wide"


def build_hand(schematic=False):
    s.reset()
    out = HERE / "hand"
    out.mkdir(exist_ok=True)
    nets, records = {}, []

    def net(name):
        if name not in nets:
            nets[name] = s.Net(name)
        return nets[name]

    def part(lib, name, ref, value, footprint, pins, mpn, group="Control", quantity=1):
        p = s.Part(lib, name, ref=ref, value=value, footprint=footprint, tag=ref)
        for number, signal in pins.items():
            p[str(number)] += net(signal) if signal else builtins.NC
        for pin in p.pins:
            if not pin.nets:
                pin += builtins.NC
        p.MPN = mpn
        records.append(dict(ref=ref, value=value, footprint=footprint, mpn=mpn,
                            group=group, quantity=quantity,
                            pins={str(k): v for k, v in pins.items() if v}))
        return p

    def resistor(ref, value, a, b, group="Control", power=False):
        code = "5K6" if value == "5.6k" else value.upper()
        mpn = "PR01000101000FA100" if power else "MFR-25FBF52-" + code
        part("Device", "R", ref, value + (" 1W 1%" if power else " 1%"),
             AXIAL, {1: a, 2: b}, mpn, group)

    def bypass(ref, rail, group):
        part("Device", "C", ref, "100nF 63V",
             "Capacitor_THT:C_Rect_L7.2mm_W2.5mm_P5.00mm", {1: rail, 2: "GND"},
             "MKS2C031001A00KSSD", group)

    def connector(ref, count, value, family, pins, group="Control"):
        stem = f"B{count}P-VH" if family == "VH" else f"B{count}B-XH-A"
        pitch = "3.96" if family == "VH" else "2.50"
        part("Connector_Generic", f"Conn_01x{count:02d}", ref, value,
             f"Connector_JST:JST_{family}_{stem}_1x{count:02d}_P{pitch}mm_Vertical",
             pins, stem + "(LF)(SN)", group)

    def flag(name, ref):
        p = s.Part("power", "PWR_FLAG", ref=ref, tag="flag-" + name)
        p[1] += net(name)

    connector("J1", 2, "AUX 5V INPUT", "VH", {1: "AUX_5V", 2: "GND"})
    connector("J2", 2, "SCREEN CONTROL", "XH", {1: "PI_GPIO17", 2: "GND"})
    resistor("R1", "1k", "PI_GPIO17", "DISPLAY_ENABLE")
    resistor("R2", "10k", "DISPLAY_ENABLE", "GND")
    part("Transistor_BJT", "2N3904", "Q1", "2N3904", TO92,
         {1: "GND", 2: "DUMP_BASE", 3: "DISCHARGE"}, "2N3904BU")
    resistor("R3", "10k", "DISPLAY_ENABLE", "DUMP_BASE")
    resistor("R4", "100k", "DUMP_BASE", "GND")
    resistor("R5", "10k", "AUX_5V", "DISCHARGE")
    flag("AUX_5V", "#FLG1")
    flag("GND", "#FLG2")

    for channel in (1, 2):
        n, pre, group = channel * 100, f"S{channel}", f"Screen {channel}"
        host, main, touch = f"HOST{channel}_5V", f"{pre}_MAIN_5V", f"{pre}_TOUCH_5V"
        ufp, base, enable = f"{pre}_UFP_N", f"{pre}_ATTACH_BASE", f"{pre}_TOUCH_EN"
        data_coil, power_coil = f"{pre}_DATA_COIL_LOW", f"{pre}_POWER_COIL_LOW"
        part("screen_power", "USB_B_Host", f"J{n+1}", "PI USB",
             "screen_power:USB_B_Lumberg_2411_06_Horizontal",
             {1: host, 2: f"{pre}_UP_N", 3: f"{pre}_UP_P", 4: "GND", "SH": "GND"},
             "2411 06", group)
        part("Connector", "USB_A", f"J{n+2}", "TOUCH",
             "Connector_USB:USB_A_Wuerth_614004134726_Horizontal",
             {1: touch, 2: f"{pre}_DN_N", 3: f"{pre}_DN_P", 4: "GND", "SH": "GND"},
             "614004134726", group)
        connector(f"J{n+3}", 2, "EVM 5V", "VH", {1: "AUX_5V", 2: "GND"}, group)
        connector(f"J{n+4}", 4, "EVM CONTROL", "XH",
                  {1: "DISPLAY_ENABLE", 2: ufp, 3: main, 4: "GND"}, group)
        flag(main, f"#FLG{n}")
        flag(touch, f"#FLG{n+1}")

        # An absent /UFP wire leaves the PNP off. Its emitter-base resistor
        # also gives the transistor a defined state when the module is absent.
        # Keep /UFP sink demand below its 1 mA VOL test condition, including
        # the PNP base path through R102/R202.
        resistor(f"R{n+1}", "100k", "AUX_5V", ufp, group)
        resistor(f"R{n+2}", "5.6k", ufp, base, group)
        resistor(f"R{n+3}", "100k", "AUX_5V", base, group)
        resistor(f"R{n+4}", "100k", enable, "GND", group)
        part("Transistor_BJT", "2N3906", f"Q{n+2}", "2N3906", TO92,
             {1: "AUX_5V", 2: base, 3: enable}, "2N3906BU", group)

        part("Transistor_FET", "IRLZ44N", f"Q{n+3}", "IRLZ44NPBF",
             "Package_TO_SOT_THT:TO-220-3_Vertical",
             {1: enable, 2: power_coil, 3: "GND"}, "IRLZ44NPBF", group)
        part("Transistor_FET", "2N7000", f"Q{n+4}", "2N7000", TO92,
             {1: "GND", 2: enable, 3: data_coil}, "2N7000", group)
        part("screen_power", "G6K-2P-RF", f"K{n+1}", "G6K-2P-RF DC5",
             "screen_power:Relay_DPDT_Omron_G6K-2P-RF",
             {1: host, 8: data_coil, 3: f"{pre}_UP_N", 4: f"{pre}_DN_N",
              6: f"{pre}_UP_P", 5: f"{pre}_DN_P", "SH": "GND"},
             "G6K-2P-RF DC5", group)
        part("Relay", "G5LE-1", f"K{n+2}", "G5LE-1 DC5",
             "Relay_THT:Relay_SPDT_Omron-G5LE-1",
             {1: touch, 2: "AUX_5V", 3: f"{pre}_TOUCH_FUSED",
              4: f"{pre}_TOUCH_DUMP", 5: power_coil}, "G5LE-1 DC5", group)
        for offset, supply, low in [(1, host, data_coil), (2, "AUX_5V", power_coil)]:
            part("Diode", "1N4007", f"D{n+offset}", "1N4007",
                 "Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal",
                 {1: supply, 2: low}, "1N4007-E3/54", group)
        # One footprint holds TWO clips; the removable cartridge is in the
        # external BOM. Placement files still contain one F-reference.
        part("Device", "Fuse", f"F{n+1}", "0.8A fast / two clips",
             "Fuse:Fuseholder_Clip-5x20mm_Littelfuse_111_Lateral_P18.80x5.00mm_D1.17mm_Horizontal",
             {1: "AUX_5V", 2: f"{pre}_TOUCH_FUSED"}, "01110501Z", group, quantity=2)
        resistor(f"R{n+5}", "100R", main, f"{pre}_MAIN_DUMP", group, power=True)
        part("Transistor_FET", "2N7000", f"Q{n+1}", "2N7000", TO92,
             {1: "GND", 2: "DISCHARGE", 3: f"{pre}_MAIN_DUMP"}, "2N7000", group)
        resistor(f"R{n+6}", "100R", f"{pre}_TOUCH_DUMP", "GND", group, power=True)
        bypass(f"C{n+1}", host, group)
        bypass(f"C{n+2}", "AUX_5V", group)
        part("Device", "C_Polarized", f"C{n+3}", "150uF 10V",
             "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm",
             {1: touch, 2: "GND"}, "EEU-FR1A151", group)

    for i in range(1, 5):
        part("Mechanical", "MountingHole", f"H{i}", "M3",
             "MountingHole:MountingHole_3.2mm_M3", {}, "NPTH", "Mechanical")
    s.ERC()
    if s.erc_logger.error.count:
        raise RuntimeError("Hand carrier electrical rules failed")
    s.generate_netlist(file_=str(out / "screen_power_hand.net"))
    (out / "components.json").write_text(json.dumps(records, indent=2) + "\n")
    with (out / "bom.csv").open("w") as f:
        writer = csv.DictWriter(f, fieldnames=["ref", "value", "footprint", "mpn", "group", "quantity"])
        writer.writeheader()
        writer.writerows({key: p[key] for key in writer.fieldnames} for p in records)
    if schematic:
        from schematic import write_schematic
        write_schematic(builtins.default_circuit, out, "hand")
