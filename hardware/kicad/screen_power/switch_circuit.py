"""Hand-soldered screen-power circuit.

One normally-open power relay switches AUX to both screens. Its contact is the
only path between the input and the screen outputs, so an unenergized board is
open in both directions. A logic-level MOSFET sinks the coil; a bidirectional
TVS sits directly across that coil. Every board load, including the coils and
the control supply, is downstream of the board's own input fuse.
The USB host's VBUS never reaches a panel; it only qualifies its AUX-powered relay.
"""
import builtins
import csv
import json
from pathlib import Path
import skidl as s

HERE = Path(__file__).resolve().parent
AXIAL = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
TO92 = "Package_TO_SOT_THT:TO-92_Inline_Wide"
# The input uses a replaceable 5 x 20 mm cartridge and separate holder.
# Four soldered radial output fuses keep the hand assembly compact and cheap.
INPUT_FUSE_FP = "screen_power:Fuseholder_Schurter_OGN_0031.8201"
BRANCH_FUSE_FP = "screen_power:Fuse_Bel_0697H_P5.08mm"
# Vishay 100 nF / 50 V / X7R disc, 5 mm lead spacing, on a reserved envelope.
FILM_FP = "Capacitor_THT:C_Disc_D7.5mm_W4.4mm_P5.00mm"


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

    def resistor(ref, value, a, b, power=False, group="Control"):
        footprint = (AXIAL)
        spelling = {"1k": "1K", "100k": "100K", "4.7k": "4K7", "22k": "22K",
                    "5.6k": "5K6", "2.4k": "2K4", "10k": "10K"}
        if power:
            mpn = ("PR01000101000FA100")
        else:
            mpn = ("MFR-25FBF52-" + spelling[value])
        part("Device", "R", ref, value + (" 1W 1%" if power else " 1%"), footprint,
             {1: a, 2: b}, mpn, group)

    def bypass(ref, rail, group="Control"):
        part("Device", "C", ref, ("100nF 50V X7R"), FILM_FP,
             {1: rail, 2: "GND"}, ("K104K10X7RF53H5"), group)

    def fuse(ref, value, mpn, a, b, group="Control"):
        footprint = INPUT_FUSE_FP if ref == "F1" else BRANCH_FUSE_FP
        part("Device", "Fuse", ref, value, footprint, {1: a, 2: b}, mpn, group)

    def header(ref, value, rail, control=False, group="Control"):
        part("Connector_Generic", "Conn_01x02", ref, value,
             "Connector_JST:JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical" if control else "Connector_JST:JST_VH_B2P-VH_1x02_P3.96mm_Vertical",
             {1: rail, 2: "GND"}, "B2B-XH-A(LF)(SN)" if control else "B2P-VH(LF)(SN)", group)

    # J1 pin 1 is the raw input. Only F1's input terminal shares that net, so
    # every capacitor, coil, control feed and contact load sits behind the fuse.
    header("J1", "AUX 5V INPUT", "AUX_5V_IN")
    fuse("F1", "8A time-lag", "0001.2513", "AUX_5V_IN", "AUX_5V")
    header("J2", "GPIO17 / GND", "PI_GPIO17", control=True)
    resistor("R1", "1k", "PI_GPIO17", "CONTROL_BASE")
    # Shunt weak pull-ups on a released GPIO while retaining ample Q1 drive.
    resistor("R2", "4.7k", "CONTROL_BASE", "GND")
    part("Transistor_BJT", ("2N3904"), "Q1", ("2N3904"),
         (TO92),
         ({1: "GND", 2: "CONTROL_BASE", 3: "CONTROL_SINK"}),
         ("2N3904BU"))
    # The AUX-referenced buffer drives gates only. R7 discharges them when
    # the buffer is unpowered; an externally fed closed power contact can
    # sustain AUX, so GPIO17 must still be low for commanded shutdown.
    resistor("R5", "5.6k", "CONTROL_SINK", "BUFFER_BASE")
    resistor("R6", "100k", "AUX_5V", "BUFFER_BASE")
    # 10k holds Q5's larger gate down firmly and discharges it quickly.
    resistor("R7", "10k", "DATA_ENABLE", "GND")
    part("Transistor_BJT", ("2N3906"), "Q2", ("2N3906"),
         (TO92),
         ({1: "AUX_5V", 2: "BUFFER_BASE", 3: "DATA_ENABLE"}),
         ("2N3906BU"))
    # Low-side coil driver. Its drain is the only conductor between the coil
    # and ground, so a released gate de-energizes the contact.
    part("Transistor_FET", "Q_NMOS_GDS", "Q5", ("IRLZ44N"),
         ("screen_power:TO-220-3_IRLZ44N"),
         ({1: "DATA_ENABLE", 2: "POWER_COIL_LOW", 3: "GND"}),
         ("IRLZ44NPBF"))
    # Bidirectional clamp directly across the coil: it bounds the driver's
    # drain excursion without the slow release a plain freewheel diode gives.
    part("Device", "D_TVS", "D3", ("P6KE6.8CA"),
         ("Diode_THT:D_DO-15_P10.16mm_Horizontal"),
         {1: "POWER_COIL_LOW", 2: "AUX_5V"}, ("P6KE6.8CA"))
    # Pin 8 is coil positive and pin 1 coil negative; 3 and 4 are the single
    # normally open contact. Terminals 2, 5, 6 and 7 do not exist on the 1a
    # model. The contact is the whole power switch: there is no body diode
    # and no gate network across it.
    part("screen_relay", "G6C-1117P-US", "K1", ("G6C-1117P-US"),
         ("screen_power:Relay_Omron_G6C-1117P-US"),
         {8: "AUX_5V", 1: "POWER_COIL_LOW", 4: "AUX_5V", 3: "SWITCHED_5V"},
         ("G6C-1117P-US DC5"))
    # The passive discharge costs 0.25 W at 5 V and needs no timing/driver path.
    resistor("R8", "100R", "SWITCHED_5V", "GND", power=True)
    bypass("C1", "AUX_5V")
    part("Device", "C_Polarized", "C2", "220uF 10V", "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm",
         {1: "AUX_5V", 2: "GND"}, "EEU-FR1A221")

    for ch in (1, 2):
        n, pre, group = ch * 100, f"S{ch}", f"Screen {ch}"
        host, coil = f"HOST{ch}_5V", f"{pre}_DATA_COIL_LOW"
        # Five contacts per USB lead: the cable's shield drain is terminal 5 of
        # the same keyed housing, so a lead unplugs whole with no soldered
        # tether. Terminals 4 and 5 are both board ground.
        for offset, value, rail, side in ((1, "PI USB / XH5", host, "UP"),
                                         (2, "TOUCH / XH5", pre+"_TOUCH_5V", "DN")):
            part("Connector_Generic", "Conn_01x05", f"J{n+offset}", value,
                 "Connector_JST:JST_XH_B5B-XH-A_1x05_P2.50mm_Vertical",
                 {1: rail, 2: pre+f"_{side}_N", 3: pre+f"_{side}_P", 4: "GND",
                  5: "GND"},
                 "B5B-XH-A(LF)(SN)", group)
        header(f"J{n+3}", f"SCREEN {ch} POWER", pre+"_MAIN_5V", group=group)
        # Time-lag branch fuses: the contact makes into the screens' own
        # capacitance without a gate ramp, so the branches need pulse margin.
        for offset, value, rail, mpn in [(1, "4A time-lag", pre+"_MAIN_5V", "0697H4000-02"),
                                        (2, "800mA time-lag", pre+"_TOUCH_5V", "0697H0800-02")]:
            fuse(f"F{n+offset}", value, mpn, "SWITCHED_5V", rail, group)
        # AUX supplies the coil, including during USB suspend. Host VBUS only
        # drives a 10k/100k presence divider, independently of GPIO enable.
        # TE 108-98001 terminal assignment: each changeover set is driven from
        # the middle terminal. Set A is common 3 with break 2 / make 4; set B is
        # common 6 with break 7 / make 5. The host side therefore lands on the
        # commons and the screen side on the makes, so an unpowered coil leaves
        # both data lines open. Terminals 2 and 7 stay unconnected.
        part("Relay", "IM03", f"K{n+1}", "IM02TS",
             "screen_power:Relay_DPDT_AXICOM_IMSeries_Pitch5.08mm_D0.90mm",
             {1: "AUX_5V", 8: coil, 3: pre+"_UP_N", 4: pre+"_DN_N",
              6: pre+"_UP_P", 5: pre+"_DN_P"}, "1-1462037-3", group)
        part("Transistor_FET", "2N7000", f"Q{n+1}", "TN0702",
             (TO92),
             ({1: "GND", 2: "DATA_ENABLE", 3: pre+"_RELAY_STACK"}),
             "TN0702N3-G", group)
        part("Transistor_FET", "2N7000", f"Q{n+2}", "TN0702",
             TO92, {1: pre+"_RELAY_STACK", 2: pre+"_HOST_PRESENT", 3: coil},
             "TN0702N3-G", group)
        resistor(f"R{n+1}", "10k", host, pre+"_HOST_PRESENT", group=group)
        resistor(f"R{n+2}", "100k", pre+"_HOST_PRESENT", "GND", group=group)
        part("Diode", ("1N4007"), f"D{n+1}", ("1N4007"),
             ("Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal"),
             {1: "AUX_5V", 2: coil}, ("1N4007G"), group)
        # Do not retain a host-side reservoir that delays VBUS-loss detection.
        bypass(f"C{n+1}", "AUX_5V", group)
        part("Device", "C_Polarized", f"C{n+2}", "150uF 10V", "Capacitor_THT:CP_Radial_D5.0mm_P2.00mm",
             {1: pre+"_TOUCH_5V", 2: "GND"}, "EEU-FR1A151", group)

    for i in range(1, 5):
        part("Mechanical", "MountingHole", f"H{i}", "M3", "MountingHole:MountingHole_3.5mm", {}, "NPTH", "Mechanical")
    for i, name in enumerate(("AUX_5V_IN", "GND", "HOST1_5V", "HOST2_5V", "S1_TOUCH_5V", "S2_TOUCH_5V"), 1):
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
        writer.writerows({key: row[key] for key in writer.fieldnames}
                         for row in records)
        # Holder hardware has no extra electrical component or phantom pads.
        # These records deliberately live only in the purchasing BOM.
        writer.writerows([
            dict(ref="F1_HOLDER", value="5x20 input fuse holder",
                 footprint=INPUT_FUSE_FP, mpn="0031.8201",
                 group="Fuse holders", quantity=1),
        ])
    if schematic:
        from schematic import write_schematic
        write_schematic(builtins.default_circuit, out, variant)
