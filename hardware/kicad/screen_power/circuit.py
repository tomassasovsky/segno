"""Two screen-power variants. Run with the repository's SKiDL environment.

Native KiCad symbols provide pin numbers and ERC types. The factory circuit
integrates the USB and source ICs; hand_circuit contains the through-hole carrier.
"""

import argparse
import builtins
import csv
import json
import os
from pathlib import Path

import skidl as s
from simp_sexp import Sexp

HERE = Path(__file__).resolve().parent
SYMBOLS = Path(os.environ.get(
    "KICAD_SYMBOL_DIR",
    "/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols",
))
s.set_default_tool(s.KICAD9)
s.lib_search_paths[s.KICAD9].extend([str(SYMBOLS), str(HERE)])


def require_physical_footprint(part):
    if not part.ref.startswith("#FLG"):
        raise ValueError(f"Missing footprint: {part.ref}")


s.empty_footprint_handler = require_physical_footprint


def custom_symbols():
    """Manufacturer pin maps, including every ground and the unexported LDOs."""
    definitions = {
        "ADuM3165BRSZ": [
            ("VBUS1", "power_in"), ("GND1", "power_in"),
            ("VDD1", "power_out"), ("GND1", "power_in"),
            ("XI1", "input"), ("XO1", "output"),
            ("GND1", "power_in"), ("UD+", "bidirectional"),
            ("UD-", "bidirectional"), ("GND1", "power_in"),
            ("GND2", "power_in"), ("DD+", "bidirectional"),
            ("DD-", "bidirectional"), ("PGOOD", "output"),
            ("GND2", "power_in"), ("GND2", "power_in"),
            ("GND2", "power_in"), ("VDD2", "power_out"),
            ("GND2", "power_in"), ("VBUS2", "power_in"),
        ],
        "TPS25221DBVR": [("IN", "power_in"), ("GND", "power_in"),
                          ("EN", "input"), ("~{FAULT}", "open_collector"),
                          ("ILIM", "passive"), ("OUT", "power_out")],
    }
    symbols = []
    # USB_B marks its ground as power_out. Two host ports share ground here;
    # derive a local symbol with a passive ground, leaving VBUS power_out.
    library = Sexp((SYMBOLS / "Connector.kicad_sym").read_text().replace(
        '(property "Datasheet" ""', '(property "Datasheet" "~"'))
    usb = next(x for x in library if isinstance(x, list) and str(x[0]) == "symbol" and x[1] == "USB_B")
    usb[1] = "USB_B_Host"
    for child in usb:
        if isinstance(child, list) and str(child[0]) == "symbol":
            child[1] = child[1].replace("USB_B_", "USB_B_Host_")
            for pin in child:
                if isinstance(pin, list) and str(pin[0]) == "pin":
                    if any(isinstance(v, list) and str(v[0]) == "number" and v[1] == "4" for v in pin):
                        pin[1] = "passive"
    usb = Sexp(usb)
    usb.add_quotes(lambda item: item[0] in ("symbol", "property", "name", "number"))
    symbols.append(usb.to_str())
    # The RF relay has the G6K contact numbering plus four case-ground leads.
    # The normal G6K footprint is not interchangeable with this RF package.
    relay_library = Sexp((SYMBOLS / "Relay.kicad_sym").read_text().replace(
        '(property "Datasheet" ""', '(property "Datasheet" "~"'))
    relay = next(x for x in relay_library if isinstance(x, list)
                 and str(x[0]) == "symbol" and x[1] == "G6K-2")
    relay[1] = "G6K-2P-RF"
    for child in relay:
        if isinstance(child, list) and str(child[0]) == "symbol":
            child[1] = child[1].replace("G6K-2_", "G6K-2P-RF_")
    relay_pins = next(child for child in relay if isinstance(child, list)
                      and str(child[0]) == "symbol" and child[1] == "G6K-2P-RF_1_1")
    relay_pins.append(Sexp('''(pin passive line (at -15.24 0 0) (length 2.54)
          (name "CASE" (effects (font (size 1 1))))
          (number "SH" (effects (font (size 1 1)))))'''))
    relay = Sexp(relay)
    relay.add_quotes(lambda item: item[0] in ("symbol", "property", "name", "number"))
    symbols.append(relay.to_str())
    for name, pins in definitions.items():
        half = len(pins) // 2
        height = (half + 1) * 2.54
        body = []
        for i, (label, kind) in enumerate(pins):
            left = i < half
            y = height / 2 - 2.54 * (i + 1 if left else len(pins) - i)
            x, angle = (-10.16, 0) if left else (10.16, 180)
            body.append(f'(pin {kind} line (at {x} {y} {angle}) (length 2.54) '
                        f'(name "{label}" (effects (font (size 1.0 1.0)))) '
                        f'(number "{i+1}" (effects (font (size 1.0 1.0)))))')
        symbols.append(f'''(symbol "{name}" (in_bom yes) (on_board yes)
          (property "Reference" "U" (at 0 {height/2+2.54} 0)
            (effects (font (size 1.27 1.27))))
          (property "Value" "{name}" (at 0 {-height/2-2.54} 0)
            (effects (font (size 1.27 1.27))))
          (symbol "{name}_0_1" (rectangle (start -7.62 {height/2})
            (end 7.62 {-height/2}) (stroke (width 0.254) (type default))
            (fill (type background))))
          (symbol "{name}_1_1" {''.join(body)}))''')
    (HERE / "screen_power.kicad_sym").write_text(
        '(kicad_symbol_lib (version 20231120) (generator "kicad_symbol_editor")\n'
        + '\n'.join(symbols) + ')\n')


def build(variant, schematic=False):
    if variant == "hand":
        from hand_circuit import build_hand
        return build_hand(schematic)
    s.reset()
    out = HERE / variant
    out.mkdir(exist_ok=True)
    nets, records = {}, []

    def net(name):
        if name not in nets:
            nets[name] = s.Net(name)
        return nets[name]

    def part(lib, name, ref, value, footprint, pins, mpn="", group=""):
        p = s.Part(lib, name, ref=ref, value=value, footprint=footprint, tag=ref)
        for number, signal in pins.items():
            p[str(number)] += net(signal) if signal else builtins.NC
        # No implicit unconnected pins: NC unused status/connector contacts.
        for pin in p.pins:
            if not pin.nets:
                pin += builtins.NC
        p.MPN = mpn or value
        records.append(dict(ref=ref, value=value, footprint=footprint,
                            mpn=mpn or value, group=group,
                            pins={str(k): v for k, v in pins.items() if v}))
        return p

    def r(ref, value, a, b, mpn, power=False, group=""):
        return part("Device", "R", ref, value,
                    "Resistor_SMD:R_" + ("2010_5025Metric" if power else "0805_2012Metric"),
                    {1: a, 2: b}, mpn, group)

    def c(ref, value, a, b="GND", mpn="C0805C104K5RAC", group=""):
        return part("Device", "C", ref, value, "Capacitor_SMD:C_0805_2012Metric",
                    {1: a, 2: b}, mpn, group)

    def connector(ref, count, value, family, pins, mpn, group=""):
        return part("Connector_Generic", f"Conn_01x{count:02d}", ref, value,
                    f"Connector_JST:JST_{family}_B{count}{'P-VH' if family == 'VH' else 'B-XH-A'}_"
                    f"1x{count:02d}_P{'3.96' if family == 'VH' else '2.50'}mm_Vertical",
                    pins, mpn, group)

    connector("J1", 2, "AUX 5V INPUT", "VH", {1: "AUX_5V", 2: "GND"}, "B2P-VH(LF)(SN)")
    connector("J2", 2, "SCREEN CONTROL", "XH", {1: "PI_GPIO17", 2: "GND"},
              "B2B-XH-A(LF)(SN)", "Control")
    r("R1", "1k", "PI_GPIO17", "DISPLAY_ENABLE", "RC0805FR-071KL")
    r("R2", "10k", "DISPLAY_ENABLE", "GND", "RC0805FR-0710KL")
    # A 5 V LVC Schmitt input cannot guarantee recognition of Pi 3.3 V.
    # A saturated NPN provides the off-state discharge command without a
    # powered logic input or a path from AUX into the Pi.
    part("Transistor_BJT", "MMBT3904", "Q1", "MMBT3904,215",
         "Package_TO_SOT_SMD:SOT-23", {1: "DUMP_BASE", 2: "GND", 3: "DISCHARGE"})
    r("R3", "10k", "DISPLAY_ENABLE", "DUMP_BASE", "RC0805FR-0710KL")
    r("R4", "100k", "DUMP_BASE", "GND", "RC0805FR-07100KL")
    r("R5", "10k", "AUX_5V", "DISCHARGE", "RC0805FR-0710KL")
    # Power flags declare the externally supplied rails; no Pi5V/AUX bridge.
    for i, name in enumerate(["GND", "AUX_5V"]):
        flag = s.Part("power", "PWR_FLAG", ref=f"#FLG{i+1}", tag=f"flag-{name}")
        flag[1] += net(name)

    for channel in (1, 2):
        n = channel * 100
        pre = f"S{channel}"
        group = f"Screen {channel}"
        sw, touch = f"{pre}_MAIN_5V", f"{pre}_TOUCH_5V"
        host = f"HOST{channel}_5V"
        attached, touch_en = f"{pre}_UFP_N", f"{pre}_TOUCH_EN"
        for ref, symbol, fp, rail, dp, dm, mpn in [
            (f"J{n+1}", "USB_B", "USB_B_Lumberg_2411_06_Horizontal", host,
             f"{pre}_UP_P", f"{pre}_UP_N", "2411 06"),
            (f"J{n+2}", "USB_A", "USB_A_Wuerth_614004134726_Horizontal", touch,
             f"{pre}_DN_P", f"{pre}_DN_N", "614004134726"),
        ]:
            part("screen_power" if symbol == "USB_B" else "Connector",
                 "USB_B_Host" if symbol == "USB_B" else symbol,
                 ref, "PI USB" if symbol == "USB_B" else "TOUCH",
                 f"{'screen_power' if symbol == 'USB_B' else 'Connector_USB'}:{fp}",
                 {1: rail, 2: dm, 3: dp, 4: "GND", "SH": "GND"}, mpn, group)
        part("screen_power", "ADuM3165BRSZ", f"U{n+1}", "ADuM3165BRSZ",
             "Package_SO:SSOP-20_5.3x7.2mm_P0.65mm", {
                 1: host, 2: "GND", 3: f"{pre}_VDD1", 4: "GND",
                 5: f"{pre}_XI", 6: f"{pre}_XO", 7: "GND",
                 8: f"{pre}_UP_P", 9: f"{pre}_UP_N", 10: "GND",
                 11: "GND", 12: f"{pre}_DN_P", 13: f"{pre}_DN_N",
                 15: "GND", 16: "GND", 17: "GND", 18: f"{pre}_VDD2",
                 19: "GND", 20: touch,
             }, group=group)
        for j, rail in enumerate([host, f"{pre}_VDD1", f"{pre}_VDD2", touch]):
            c(f"C{n+j+1}", "100nF", rail, group=group)
        crystal_fp = "Crystal:Crystal_SMD_3225-4Pin_3.2x2.5mm"
        part("Device", "Crystal_GND24", f"Y{n+1}", "24MHz 10pF", crystal_fp,
             {1: f"{pre}_XI", 2: "GND", 3: f"{pre}_XO", 4: "GND"},
             "ABM8-24.000MHZ-10-B1U-T", group)
        c(f"C{n+5}", "8pF C0G", f"{pre}_XI", mpn="CC0805DRNPO9BN8R0", group=group)
        c(f"C{n+6}", "8pF C0G", f"{pre}_XO", mpn="CC0805DRNPO9BN8R0", group=group)
        for j, side, rail in [(1, "UP", host), (2, "DN", touch)]:
            part("Power_Protection", "USBLC6-2SC6", f"D{n+j}", "USBLC6-2SC6",
                 "Package_TO_SOT_SMD:SOT-23-6", {1: f"{pre}_{side}_P", 6: f"{pre}_{side}_P",
                 3: f"{pre}_{side}_N", 4: f"{pre}_{side}_N", 2: "GND", 5: rail}, group=group)
        part("74xGxx", "SN74LVC1G14DBV", f"U{n+2}", "SN74LVC1G14DBVR",
             "Package_TO_SOT_SMD:SOT-23-5", {2: attached, 3: "GND", 4: touch_en, 5: "AUX_5V"}, group=group)
        c(f"C{n+7}", "100nF", "AUX_5V", group=group)
        r(f"R{n+1}", "10k", "AUX_5V", attached, "RC0805FR-0710KL", group=group)
        r(f"R{n+2}", "10k", touch_en, "GND", "RC0805FR-0710KL", group=group)
        part("screen_power", "TPS25221DBVR", f"U{n+3}", "TPS25221DBVR",
             "Package_TO_SOT_SMD:SOT-23-6", {1: "AUX_5V", 2: "GND", 3: touch_en,
              5: f"{pre}_ILIM", 6: touch}, group=group)
        r(f"R{n+3}", "80.6k 1%", f"{pre}_ILIM", "GND", "RC0805FR-0780K6L", group=group)
        c(f"C{n+8}", "100nF", "AUX_5V", group=group)
        part("Device", "C_Polarized", f"C{n+9}", "150uF 10V",
             "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm", {1: touch, 2: "GND"}, "EEU-FR1A151", group)
        for j, rail in enumerate([sw, touch]):
            r(f"R{n+4+j}", "100R 0.75W", rail, f"{pre}_DUMP{j}",
              "CRCW2010100RFKEF", power=True, group=group)
            part("Transistor_FET", "2N7002", f"Q{n+j+1}", "2N7002",
                 "Package_TO_SOT_SMD:SOT-23", {1: "DISCHARGE", 2: "GND", 3: f"{pre}_DUMP{j}"},
                 "2N7002,215", group)
        part("Interface_USB", "TPS25810RVC", f"U{n+4}", "TPS25810RVCR",
             "Package_DFN_QFN:Texas_RVC0020A_WQFN-20-1EP_3x4mm_P0.5mm_EP1.6x2.6mm_ThermalVias", {
                 2: "AUX_5V", 3: "AUX_5V", 4: "AUX_5V", 5: "AUX_5V",
                 6: "DISPLAY_ENABLE", 7: "AUX_5V", 8: "AUX_5V",
                 9: f"{pre}_REF_RTN", 10: f"{pre}_REF", 11: f"{pre}_CC1",
                 12: "GND", 13: f"{pre}_CC2", 14: sw, 15: sw, 19: attached, 21: "GND",
             }, group=group)
        r(f"R{n+6}", "100k 1%", f"{pre}_REF", f"{pre}_REF_RTN", "RC0805FR-07100KL", group=group)
        part("Connector", "USB_C_Receptacle_PowerOnly_6P", f"J{n+3}", "SCREEN POWER 5V 3A",
             "Connector_USB:USB_C_Receptacle_GCT_USB4125-xx-x_6P_TopMnt_Horizontal", {
                 "A9": sw, "B9": sw,
                 "A12": "GND", "B12": "GND",
                 "A5": f"{pre}_CC1", "B5": f"{pre}_CC2", "SH": "GND",
             }, "USB4125-GF-A", group)
        c(f"C{n+10}", "100nF", "AUX_5V", group=group)
        # Radial bulk avoids ceramic DC-bias uncertainty at the source input.
        part("Device", "C_Polarized", f"C{n+11}", "220uF 10V",
             "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm", {1: "AUX_5V", 2: "GND"}, "EEU-FR1A221", group)
        part("Device", "C", f"C{n+12}", "10uF 25V X7R",
             "Capacitor_SMD:C_1210_3225Metric", {1: sw, 2: "GND"}, "GRM32ER71E106KA12L", group)
    for i in range(1, 5):
        part("Mechanical", "MountingHole", f"H{i}", "M3",
             "MountingHole:MountingHole_3.2mm_M3", {}, "NPTH", "Mechanical")
    s.ERC()
    if s.erc_logger.error.count:
        raise RuntimeError("Electrical rules failed")
    s.generate_netlist(file_=str(out / f"screen_power_{variant}.net"))
    (out / "components.json").write_text(json.dumps(records, indent=2) + "\n")
    with (out / "bom.csv").open("w") as f:
        writer = csv.DictWriter(f, fieldnames=["ref", "value", "footprint", "mpn", "group"])
        writer.writeheader()
        writer.writerows({k: p[k] for k in writer.fieldnames} for p in records)
    if schematic:
        from schematic import write_schematic
        write_schematic(builtins.default_circuit, out, variant)


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("variant", choices=["hand", "factory"])
    args.add_argument("--schematic", action="store_true")
    options = args.parse_args()
    custom_symbols()
    build(options.variant, options.schematic)
