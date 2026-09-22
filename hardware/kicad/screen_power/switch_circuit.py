"""One discrete screen-power circuit with through-hole and factory assemblies.

Opposed P-channel MOSFETs switch AUX while blocking either direction when off.
The USB host's VBUS never reaches a panel; it powers only its RF relay coil.
"""
import builtins
import csv
import json
from pathlib import Path
import skidl as s

HERE = Path(__file__).resolve().parent
AXIAL = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
TO92 = "Package_TO_SOT_THT:TO-92_Inline_Wide"
SOT23 = "Package_TO_SOT_SMD:SOT-23"


def build_switch(variant, schematic=False):
    s.reset()
    hand = variant == "hand"
    out = HERE / variant
    out.mkdir(exist_ok=True)
    nets, records = {}, []

    def net(name):
        if name not in nets:
            nets[name] = s.Net(name)
        return nets[name]

    def part(lib, symbol, ref, value, footprint, pins, mpn, group="Control"):
        obj = s.Part(lib, symbol, ref=ref, value=value, footprint=footprint, tag=ref)
        for pin, name in pins.items():
            obj[str(pin)] += net(name) if name else builtins.NC
        for pin in obj.pins:
            if not pin.nets:
                pin += builtins.NC
        obj.MPN = mpn
        records.append(dict(ref=ref, value=value, footprint=footprint, mpn=mpn,
                            group=group, quantity=1,
                            pins={str(k): v for k, v in pins.items() if v}))
        return obj

    def resistor(ref, value, a, b, power=False):
        footprint = AXIAL if hand else ("Resistor_SMD:R_2512_6332Metric" if power else "Resistor_SMD:R_0805_2012Metric")
        spelling = {"1k": "1K", "100k": "100K", "4.7k": "4K7", "330k": "330K", "5.6k": "5K6"}
        if power:
            mpn = "PR01000101000FA100" if hand else "CRCW2512100RFKEG"
        else:
            mpn = ("MFR-25FBF52-" + spelling[value]) if hand else ("RC0805FR-07" + spelling[value] + "L")
        part("Device", "R", ref, value + (" 1W 1%" if power else " 1%"), footprint,
             {1: a, 2: b}, mpn)

    def bypass(ref, rail, group="Control"):
        part("Device", "C", ref, "100nF 63V" if hand else "100nF 50V",
             "Capacitor_THT:C_Rect_L7.2mm_W2.5mm_P5.00mm" if hand else "Capacitor_SMD:C_0805_2012Metric",
             {1: rail, 2: "GND"}, "MKS2C031001A00KSSD" if hand else "GRM21BR71H104KA01L", group)

    def header(ref, value, rail, control=False, group="Control"):
        part("Connector_Generic", "Conn_01x02", ref, value,
             "Connector_JST:JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical" if control else "Connector_JST:JST_VH_B2P-VH_1x02_P3.96mm_Vertical",
             {1: rail, 2: "GND"}, "B2B-XH-A(LF)(SN)" if control else "B2P-VH(LF)(SN)", group)

    header("J1", "AUX 5V INPUT", "AUX_5V")
    header("J2", "GPIO17 / GND", "PI_GPIO17", control=True)
    resistor("R1", "1k", "PI_GPIO17", "CONTROL_BASE")
    resistor("R2", "100k", "CONTROL_BASE", "GND")
    part("Transistor_BJT", "2N3904" if hand else "MMBT3904", "Q1", "2N3904" if hand else "MMBT3904",
         TO92 if hand else SOT23,
         {1: "GND", 2: "CONTROL_BASE", 3: "CONTROL_SINK"} if hand else {1: "CONTROL_BASE", 2: "GND", 3: "CONTROL_SINK"},
         "2N3904BU" if hand else "MMBT3904,215")
    resistor("R3", "4.7k", "CONTROL_SINK", "POWER_GATE")
    resistor("R4", "330k", "POWER_GATE", "COMMON_SOURCE")
    # Pull-up belongs to the joined sources, not AUX, to keep both FETs off
    # when a powered panel is connected to an unpowered AUX input.
    for ref, drain in [("Q3", "AUX_5V"), ("Q4", "SWITCHED_5V")]:
        part("Transistor_FET", "Q_PMOS_GDS", ref, "SUP70101EL" if hand else "SUM70101EL",
             "screen_power:TO-220-3_SUP70101EL" if hand else "Package_TO_SOT_SMD:TO-263-3_TabPin2",
             {1: "POWER_GATE", 2: drain, 3: "COMMON_SOURCE"},
             "SUP70101EL-GE3" if hand else "SUM70101EL-GE3")
    # Block a charged output from pulling the FET gates toward a dead AUX
    # supply through the PNP base network when the GPIO is low.
    part("Diode", "1N4148" if hand else "1N4148W", "D1", "1N4148" if hand else "1N4148W",
         "Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal" if hand else "Diode_SMD:D_SOD-123",
         {1: "CONTROL_SINK", 2: "BUFFER_SINK"}, "1N4148-TAP" if hand else "1N4148W-7-F")
    resistor("R5", "5.6k", "BUFFER_SINK", "BUFFER_BASE")
    resistor("R6", "100k", "AUX_5V", "BUFFER_BASE")
    resistor("R7", "100k", "DATA_ENABLE", "GND")
    part("Transistor_BJT", "2N3906" if hand else "MMBT3906", "Q2", "2N3906" if hand else "MMBT3906",
         TO92 if hand else SOT23,
         {1: "AUX_5V", 2: "BUFFER_BASE", 3: "DATA_ENABLE"} if hand else {1: "BUFFER_BASE", 2: "AUX_5V", 3: "DATA_ENABLE"},
         "2N3906BU" if hand else "MMBT3906,215")
    # The passive discharge costs 0.25 W at 5 V and needs no timing/driver path.
    resistor("R8", "100R", "SWITCHED_5V", "GND", power=True)
    bypass("C1", "AUX_5V")
    part("Device", "C_Polarized", "C2", "220uF 10V", "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm",
         {1: "AUX_5V", 2: "GND"}, "EEU-FR1A221")

    for ch in (1, 2):
        n, pre, group = ch * 100, f"S{ch}", f"Screen {ch}"
        host, coil = f"HOST{ch}_5V", f"{pre}_DATA_COIL_LOW"
        part("screen_power", "USB_B_Host", f"J{n+1}", "PI USB",
             "screen_power:USB_B_Lumberg_2411_06_Horizontal",
             {1: host, 2: pre+"_UP_N", 3: pre+"_UP_P", 4: "GND", "SH": "GND"}, "2411 06", group)
        part("Connector", "USB_A", f"J{n+2}", "TOUCH",
             "Connector_USB:USB_A_Wuerth_614004134726_Horizontal",
             {1: pre+"_TOUCH_5V", 2: pre+"_DN_N", 3: pre+"_DN_P", 4: "GND", "SH": "GND"}, "614004134726", group)
        header(f"J{n+3}", f"SCREEN {ch} POWER", pre+"_MAIN_5V", group=group)
        for offset, value, rail, mpn in [(1, "4A fast", pre+"_MAIN_5V", "0251004.MXL"),
                                        (2, "750mA fast", pre+"_TOUCH_5V", "0251.750MXL")]:
            part("Device", "Fuse", f"F{n+offset}", value, "screen_power:Fuse_Littelfuse_251_P12.70mm",
                 {1: "SWITCHED_5V", 2: rail}, mpn, group)
        part("screen_power", "G6K-2P-RF", f"K{n+1}", "G6K-2P-RF DC5",
             "screen_power:Relay_DPDT_Omron_G6K-2P-RF",
             {1: host, 8: coil, 3: pre+"_UP_N", 4: pre+"_DN_N",
              6: pre+"_UP_P", 5: pre+"_DN_P", "SH": "GND"}, "G6K-2P-RF DC5", group)
        part("Transistor_FET", "2N7000" if hand else "2N7002", f"Q{n+1}", "2N7000" if hand else "2N7002",
             TO92 if hand else SOT23,
             {1: "GND", 2: "DATA_ENABLE", 3: coil} if hand else {1: "DATA_ENABLE", 2: "GND", 3: coil},
             "2N7000" if hand else "2N7002,215", group)
        part("Diode", "1N4007" if hand else "1N4148W", f"D{n+1}", "1N4007" if hand else "1N4148W",
             "Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal" if hand else "Diode_SMD:D_SOD-123",
             {1: host, 2: coil}, "1N4007-E3/54" if hand else "1N4148W-7-F", group)
        bypass(f"C{n+1}", host, group)
        part("Device", "C_Polarized", f"C{n+2}", "150uF 10V", "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm",
             {1: pre+"_TOUCH_5V", 2: "GND"}, "EEU-FR1A151", group)

    for i in range(1, 5):
        part("Mechanical", "MountingHole", f"H{i}", "M3", "MountingHole:MountingHole_3.2mm_M3", {}, "NPTH", "Mechanical")
    for i, name in enumerate(("AUX_5V", "GND", "S1_TOUCH_5V", "S2_TOUCH_5V"), 1):
        flag = s.Part("power", "PWR_FLAG", ref=f"#FLG{i}", tag="flag-"+name)
        flag[1] += net(name)
    s.ERC()
    if s.erc_logger.error.count:
        raise RuntimeError("Screen switch electrical rules failed")
    s.generate_netlist(file_=str(out / f"screen_power_{variant}.net"))
    (out / "components.json").write_text(json.dumps(records, indent=2)+"\n")
    with (out / "bom.csv").open("w") as stream:
        writer = csv.DictWriter(stream, fieldnames=["ref", "value", "footprint", "mpn", "group", "quantity"], lineterminator="\n")
        writer.writeheader()
        writer.writerows({key: row[key] for key in writer.fieldnames} for row in records)
    if schematic:
        from schematic import write_schematic
        write_schematic(builtins.default_circuit, out, variant)
