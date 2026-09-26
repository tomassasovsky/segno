"""Hand-soldered screen-power circuit.

Opposed P-channel MOSFETs switch AUX while blocking either direction when off.
The USB host's VBUS never reaches a panel; it powers only its signal relay coil.
"""
import builtins
import csv
import json
from pathlib import Path
import skidl as s

HERE = Path(__file__).resolve().parent
AXIAL = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
TO92 = "Package_TO_SOT_THT:TO-92_Inline_Wide"


def build_switch(variant, schematic=False):
    s.reset()
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
        footprint = (AXIAL)
        spelling = {"1k": "1K", "100k": "100K", "4.7k": "4K7", "22k": "22K",
                    "5.6k": "5K6", "2.4k": "2K4", "10k": "10K"}
        if power:
            mpn = ("PR01000101000FA100")
        else:
            mpn = ("MFR-25FBF52-" + spelling[value])
        part("Device", "R", ref, value + (" 1W 1%" if power else " 1%"), footprint,
             {1: a, 2: b}, mpn)

    def bypass(ref, rail, group="Control"):
        part("Device", "C", ref, ("100nF 63V"),
             ("Capacitor_THT:C_Rect_L7.2mm_W2.5mm_P5.00mm"),
             {1: rail, 2: "GND"}, ("MKS2C031001A00KSSD"), group)

    def header(ref, value, rail, control=False, group="Control"):
        part("Connector_Generic", "Conn_01x02", ref, value,
             "Connector_JST:JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical" if control else "Connector_JST:JST_VH_B2P-VH_1x02_P3.96mm_Vertical",
             {1: rail, 2: "GND"}, "B2B-XH-A(LF)(SN)" if control else "B2P-VH(LF)(SN)", group)

    header("J1", "AUX 5V INPUT", "AUX_5V")
    header("J2", "GPIO17 / GND", "PI_GPIO17", control=True)
    resistor("R1", "1k", "PI_GPIO17", "CONTROL_BASE")
    resistor("R2", "100k", "CONTROL_BASE", "GND")
    part("Transistor_BJT", ("2N3904"), "Q1", ("2N3904"),
         (TO92),
         ({1: "GND", 2: "CONTROL_BASE", 3: "CONTROL_SINK"}),
         ("2N3904BU"))
    # A small negative supply gives the P-FETs ample enhancement even after
    # fuse/harness drop. The optocoupler level-shifts the control signal;
    # the Pi and the relay drivers never connect to the negative rail.
    part("Regulator_SwitchedCapacitor", "LMC7660", "U1", "LMC7660IN",
         "Package_DIP:DIP-8_W7.62mm",
         {2: "PUMP_CAP_PLUS", 3: "GND", 4: "PUMP_CAP_MINUS",
          5: "NEG_5V", 8: "AUX_5V"}, "LMC7660IN/NOPB")
    # Pins 1, 6 (LV) and 7 (OSC) intentionally remain unconnected. LV must
    # not be grounded on this 5V supply. Both caps are nonpolar so power
    # sequencing cannot reverse-bias a polarized output reservoir.
    for ref, a, b in (("C3", "PUMP_CAP_PLUS", "PUMP_CAP_MINUS"),
                      ("C4", "GND", "NEG_5V")):
        part("Device", "C", ref, "10uF 25V bipolar",
             "Capacitor_THT:C_Radial_D5.0mm_H11.0mm_P2.00mm",
             {1: a, 2: b}, "ECE-A1EN100U")
    bypass("C5", "AUX_5V")
    part("Device", "D_Schottky", "D2", "BAT85S",
         "Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal",
         {1: "GND", 2: "NEG_5V"}, "BAT85S-TAP")
    part("Isolator", "TLP627", "U2", "TLP627M",
         "Package_DIP:DIP-4_W7.62mm",
         {1: "GATE_LED", 2: "CONTROL_SINK", 3: "NEG_5V", 4: "GATE_SINK"},
         "TLP627M(E")
    resistor("R9", "2.4k", "AUX_5V", "GATE_LED")
    resistor("R10", "10k", "GATE_LED", "CONTROL_SINK")
    resistor("R3", "4.7k", "GATE_SINK", "POWER_GATE")
    resistor("R4", "22k", "POWER_GATE", "COMMON_SOURCE")
    # Pull-up belongs to the joined sources, not AUX, to keep both FETs off
    # when a powered panel is connected to an unpowered AUX input.
    for ref, drain in [("Q3", "AUX_5V"), ("Q4", "SWITCHED_5V")]:
        part("Transistor_FET", "Q_PMOS_GDS", ref, ("SUP70101EL"),
             ("screen_power:TO-220-3_SUP70101EL"),
             {1: "POWER_GATE", 2: drain, 3: "COMMON_SOURCE"},
             ("SUP70101EL-GE3"))
    # U2 now separates the power-gate network from this AUX-referenced
    # buffer, so the former D1 backfeed-blocking diode is unnecessary.
    resistor("R5", "5.6k", "CONTROL_SINK", "BUFFER_BASE")
    resistor("R6", "100k", "AUX_5V", "BUFFER_BASE")
    resistor("R7", "100k", "DATA_ENABLE", "GND")
    part("Transistor_BJT", ("2N3906"), "Q2", ("2N3906"),
         (TO92),
         ({1: "AUX_5V", 2: "BUFFER_BASE", 3: "DATA_ENABLE"}),
         ("2N3906BU"))
    # The passive discharge costs 0.25 W at 5 V and needs no timing/driver path.
    resistor("R8", "100R", "SWITCHED_5V", "GND", power=True)
    bypass("C1", "AUX_5V")
    part("Device", "C_Polarized", "C2", "220uF 10V", "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm",
         {1: "AUX_5V", 2: "GND"}, "EEU-FR1A221")

    for ch in (1, 2):
        n, pre, group = ch * 100, f"S{ch}", f"Screen {ch}"
        host, coil = f"HOST{ch}_5V", f"{pre}_DATA_COIL_LOW"
        for offset, value, rail, side in ((1, "PI USB / XH4", host, "UP"),
                                         (2, "TOUCH / XH4", pre+"_TOUCH_5V", "DN")):
            part("Connector_Generic", "Conn_01x04", f"J{n+offset}", value,
                 "Connector_JST:JST_XH_B4B-XH-A_1x04_P2.50mm_Vertical",
                 {1: rail, 2: pre+f"_{side}_N", 3: pre+f"_{side}_P", 4: "GND"},
                 "B4B-XH-A(LF)(SN)", group)
        header(f"J{n+3}", f"SCREEN {ch} POWER", pre+"_MAIN_5V", group=group)
        for offset, value, rail, mpn in [(1, "4A fast", pre+"_MAIN_5V", "0251004.MXL"),
                                        (2, "750mA fast", pre+"_TOUCH_5V", "0251.750MXL")]:
            part("Device", "Fuse", f"F{n+offset}", value, "screen_power:Fuse_Littelfuse_251_P12.70mm",
                 {1: "SWITCHED_5V", 2: rail}, mpn, group)
        # IM02TS is the pin-compatible 4.5 V coil option. The lower pickup
        # threshold improves warm restart margin on the Pi's 5 V USB supply.
        # TE 108-98001 terminal assignment: each changeover set is driven from
        # the middle terminal. Set A is common 3 with break 2 / make 4; set B is
        # common 6 with break 7 / make 5. The host side therefore lands on the
        # commons and the screen side on the makes, so an unpowered coil leaves
        # both data lines open. Terminals 2 and 7 stay unconnected.
        part("Relay", "IM03", f"K{n+1}", "IM02TS",
             "screen_power:Relay_DPDT_AXICOM_IMSeries_Pitch5.08mm_D0.90mm",
             {1: host, 8: coil, 3: pre+"_UP_N", 4: pre+"_DN_N",
              6: pre+"_UP_P", 5: pre+"_DN_P"}, "1-1462037-3", group)
        part("Transistor_FET", "2N7000", f"Q{n+1}", "TN0702",
             (TO92),
             ({1: "GND", 2: "DATA_ENABLE", 3: coil}),
             "TN0702N3-G", group)
        part("Diode", ("1N4007"), f"D{n+1}", ("1N4007"),
             ("Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal"),
             {1: host, 2: coil}, ("1N4007-E3/54"), group)
        bypass(f"C{n+1}", host, group)
        part("Device", "C_Polarized", f"C{n+2}", "150uF 10V", "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm",
             {1: pre+"_TOUCH_5V", 2: "GND"}, "EEU-FR1A151", group)

    for i in range(1, 5):
        part("Mechanical", "MountingHole", f"H{i}", "M3", "MountingHole:MountingHole_3.5mm", {}, "NPTH", "Mechanical")
    for i, name in enumerate(("AUX_5V", "GND", "HOST1_5V", "HOST2_5V", "S1_TOUCH_5V", "S2_TOUCH_5V"), 1):
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
