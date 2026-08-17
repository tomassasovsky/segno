"""SKiDL generator for the Segno CONSOLE board v2 (issue #747).

The 10-pedal console's control board. Lies flat on the bottom plate beside the
Raspberry Pi 5 and links to it over a short KEYED 2x20 ribbon. Carries a
**Pico 2 (RP2350)** module, the MIDI front end, and a JST header for every pedal
and every rear-panel connector.

Run (from hardware/kicad/):
    ./.venv/bin/python console_board.py            # netlist + gates
    ./.venv/bin/python console_board.py --selftest # prove the gates bite

Why this board exists
---------------------
The Pi 5's four USB-A ports are exactly consumed -- two touchscreens, two rear
panel couplers -- and a hub is ruled out, so the old Pro Micro could not have one.
Its only hardware UART was already the DIN-5 pair (main_board.py:98), so MIDI moves
to the Pi and the MCU gets a UART of its own. See
docs/brainstorm/2026-08-17-console-board-v2-brainstorm-doc.md.

An MCU still has to exist: rpi_ws281x drives the legacy PWM/PCM+DMA peripherals and
does NOT support Pi 5, whose I/O moved to RP1. firmware/led_driver/ already offloads
WS2812 timing to an RP2040 for exactly that reason.

THE PICO DELETED THE LEVEL-SHIFTING PROBLEM
-------------------------------------------
segno_wiring.md section 2b specifies a 1k8/3k3 divider and an AHCT gate on the MCU
link. That was written for a **Pro Micro at 5 V** against a Pi that is not 5 V
tolerant. The RP2350 is **3.3 V, the same as the Pi**, so the link is a direct
wire in both directions -- no divider, no buffer, nothing to get wrong.

The 74AHCT125 is still here, but for the three places that genuinely cross 3.3 -> 5:
  * MIDI OUT   -- the Pi's 3.3 V TX cannot drive a 5 V MIDI current loop
  * ring data  -- WS2812 wants a 5 V logic high
  * indicator data -- same
MIDI IN needs no shifter at all: the H11L1 is a Schmitt LOGIC-output opto, so run
it from 3.3 V and it feeds the Pi directly.

Ref-designator blocks (allocated up front -- main_board.py had to pin ref="C16" to
stop a late addition renumbering C1..C15 and invalidating a started layout):
    J1  Pico 2          J2  Pi ribbon      J3  power in     J4  MIDI OUT
    J5  MIDI IN         J6  ring/encoder   J7  indicators   J8  power button
    J9  SWD             J10..J19 footswitches               J20/J21 CTRL 1/2
    U1  74AHCT125       U2  H11L1
"""
import json
import os
import sys

from skidl import (
    Part, Net, generate_netlist, ERC, POWER, set_default_tool, KICAD8,
    lib_search_paths,
)

set_default_tool(KICAD8)

_SYMBOL_DIRS = [
    os.environ.get("KICAD_SYMBOL_DIR", ""),
    r"C:\Program Files\KiCad\10.0\share\kicad\symbols",
    r"C:\Program Files\KiCad\9.0\share\kicad\symbols",
    "/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols",   # KiCad 8+ macOS
    "/Applications/KiCad.app/Contents/SharedSupport/symbols",         # older macOS layout
    "/usr/share/kicad/symbols",
]
for _d in _SYMBOL_DIRS:
    if _d and os.path.isdir(_d):
        lib_search_paths[KICAD8].append(_d)

HERE = os.path.dirname(os.path.abspath(__file__))
STATIONS_JSON = os.path.join(HERE, "..", "enclosure", "out", "rear_io_stations.json")

R_FP = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
C_FP = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"
JST = "Connector_JST:JST_XH_B%dB-XH-A_1x%02d_P2.50mm_Vertical"


def R(value, **kw):
    return Part("Device", "R", value=value, footprint=R_FP, **kw)


def C(value, fp=C_FP, **kw):
    return Part("Device", "C", value=value, footprint=fp, **kw)


def jst(n, ref, value):
    return Part("Connector_Generic", "Conn_01x%02d" % n,
                footprint=JST % (n, n), ref=ref, value=value)


# ---- nets -------------------------------------------------------------------

gnd = Net("GND")
v5 = Net("+5V")            # logic: Pico VSYS + the AHCT125
v5led = Net("+5V_LED")     # WS2812 ring + indicators, starred back to the buck on
                           # its own pair so LED transients stay off the MCU rail
v3v3 = Net("+3V3")         # from the Pi ribbon -- the MIDI front end is the Pi's,
                           # so it runs on the Pi's rail and works whenever the Pi
                           # is up, regardless of the MCU
link_tx = Net("LINK_TX")   # Pico -> Pi   (3V3 both ends: direct)
link_rx = Net("LINK_RX")   # Pi   -> Pico (3V3 both ends: direct)
midi_tx = Net("MIDI_TX")   # Pi uart0 TX -> AHCT125 -> DIN OUT
midi_rx = Net("MIDI_RX")   # opto (3V3) -> Pi uart0 RX
midi_out_buf = Net("MIDI_OUT_BUF")
pwr_btn = Net("PWR_BTN")   # rear button -> straight through to a Pi GPIO
swclk, swdio = Net("SWCLK"), Net("SWDIO")
ring_data, ring_buf, ring_out = Net("RING_DATA"), Net("RING_DATA_BUF"), Net("RING_DATA_OUT")
ind_data, ind_buf, ind_out = Net("IND_DATA"), Net("IND_DATA_BUF"), Net("IND_DATA_OUT")
encA, encB, encSW = Net("ENC_A"), Net("ENC_B"), Net("ENC_SW")
ctrl1, ctrl2 = Net("CTRL1_TIP"), Net("CTRL2_TIP")
ctrl_ref = Net("CTRL_REF")  # 3V3 through 1k -- see the CTRL block for why

# ---- J1: Pico 2 (RP2350) ----------------------------------------------------
# KiCad's own Module:RaspberryPi_Pico_Common_THT -- its description states it
# "supports Raspberry Pi Pico 2". Nothing vendored, nothing hand-drawn.
# Pad numbers are the module's physical pins:
#   1 GP0  2 GP1  3 GND  4 GP2  5 GP3  6 GP4  7 GP5  8 GND  9 GP6  10 GP7
#  11 GP8 12 GP9 13 GND 14 GP10 15 GP11 16 GP12 17 GP13 18 GND 19 GP14 20 GP15
#  21 GP16 22 GP17 23 GND 24 GP18 25 GP19 26 GP20 27 GP21 28 GND 29 GP22 30 RUN
#  31 GP26 32 GP27 33 AGND 34 GP28 35 ADC_VREF 36 3V3_OUT 37 3V3_EN 38 GND
#  39 VSYS 40 VBUS
PICO_GND_PADS = (3, 8, 13, 18, 23, 28, 33, 38)
PICO = {  # GPIO number -> module pad
    0: 1, 1: 2, 2: 4, 3: 5, 4: 6, 5: 7, 6: 9, 7: 10, 8: 11, 9: 12,
    10: 14, 11: 15, 12: 16, 13: 17, 14: 19, 15: 20, 16: 21, 17: 22,
    18: 24, 19: 25, 20: 26, 21: 27, 22: 29, 26: 31, 27: 32, 28: 34,
}
ADC_GPIO = (26, 27, 28)          # the only ADC-capable pins on the module header

pico = Part("Connector_Generic", "Conn_01x40",
            footprint="Module:RaspberryPi_Pico_Common_THT", ref="J1", value="Pico2")
for _p in PICO_GND_PADS:
    pico[_p] += gnd
pico[39] += v5                   # VSYS: 5 V in, onboard reg makes 3V3
pico[40].do_erc = False          # VBUS -- USB only, unused
pico[30].do_erc = False          # RUN  -- BOOTSEL/RUN not brought out
pico[35].do_erc = False          # ADC_VREF -- left on the module's own reference
pico[36].do_erc = False          # 3V3_OUT -- the board takes 3V3 from the Pi instead
pico[37].do_erc = False          # 3V3_EN -- internal pull-up

# Spare GPIO, brought out to nothing on purpose. ERC would otherwise report each
# as an unconnected pin, and a wall of expected warnings is how a REAL one gets
# missed -- so the exemptions are named here rather than tolerated in the log.
# main_board.py does the same for its unused AHCT gates and MIDI IN's DIN pin 2.
SPARE_GPIO = (17, 18, 19, 20, 21, 22, 28)
for _gp in SPARE_GPIO:
    pico[PICO[_gp]].do_erc = False

# ---- pin assignment ---------------------------------------------------------
GPIO = {
    "LINK_TX": 0, "LINK_RX": 1,
    "SW_RECPLAY": 2, "SW_STOP": 3, "SW_UNDO": 4, "SW_MODE": 5,
    "SW_TRACK1": 6, "SW_TRACK2": 7, "SW_TRACK3": 8, "SW_TRACK4": 9,
    "SW_CLEAR": 10, "SW_BANK": 11,
    "IND_DATA": 12, "RING_DATA": 13,
    "ENC_A": 14, "ENC_B": 15, "ENC_SW": 16,
    "CTRL1_TIP": 26, "CTRL2_TIP": 27,
}
FSW_ORDER = ["RECPLAY", "STOP", "UNDO", "MODE", "TRACK1",
             "TRACK2", "TRACK3", "TRACK4", "CLEAR", "BANK"]

pico[PICO[GPIO["LINK_TX"]]] += link_tx
pico[PICO[GPIO["LINK_RX"]]] += link_rx
pico[PICO[GPIO["IND_DATA"]]] += ind_data
pico[PICO[GPIO["RING_DATA"]]] += ring_data
pico[PICO[GPIO["ENC_A"]]] += encA
pico[PICO[GPIO["ENC_B"]]] += encB
pico[PICO[GPIO["ENC_SW"]]] += encSW
pico[PICO[GPIO["CTRL1_TIP"]]] += ctrl1
pico[PICO[GPIO["CTRL2_TIP"]]] += ctrl2

# ---- J10..J19: footswitches -- 100nF debounce + one 2-pin JST per pedal ------
sw_nets = {}
for _i, _name in enumerate(FSW_ORDER):
    n = Net("SW_" + _name)
    pico[PICO[GPIO["SW_" + _name]]] += n
    C("100nF")[1, 2] += n, gnd
    j = jst(2, "J%d" % (10 + _i), "FSW_" + _name)
    j[1] += n
    j[2] += gnd
    sw_nets[_name] = n

# ---- U1: 74AHCT125 quad buffer -- the three real 3V3 -> 5V crossings ---------
buf = Part("74xx", "74AHCT125", value="74AHCT125N",
           footprint="Package_DIP:DIP-14_W7.62mm", ref="U1")
buf[14] += v5
buf[7] += gnd
C("100nF")[1, 2] += v5, gnd
buf[1] += gnd; buf[2] += midi_tx; buf[3] += midi_out_buf       # gate A: MIDI OUT
buf[4] += gnd; buf[5] += ring_data; buf[6] += ring_buf          # gate B: ring
buf[10] += gnd; buf[9] += ind_data; buf[8] += ind_buf           # gate C: indicators
buf[13] += v5                                                    # gate D: unused,
buf[12] += gnd                                                   # /OE high, input low
buf[11].do_erc = False
R("330")[1, 2] += ring_buf, ring_out
R("330")[1, 2] += ind_buf, ind_out

# ---- J4/J5: DIN-5 MIDI, terminating on the PI's uart0 -----------------------
j_mout = jst(3, "J4", "MIDI_OUT")
R("220")[1, 2] += midi_out_buf, j_mout[1]      # DIN pin 5
R("220")[1, 2] += v5, j_mout[2]                # DIN pin 4
j_mout[3] += gnd                               # DIN pin 2 (shield) -- OUT only

j_min = jst(2, "J5", "MIDI_IN")
opto = Part("Isolator", "H11L1", footprint="Package_DIP:DIP-6_W7.62mm", ref="U2")
R("220")[1, 2] += j_min[1], opto[1]            # DIN pin 4
opto[2] += j_min[2]                            # DIN pin 5
# MIDI 1.0: the IN jack's pin 2 (shield) is NOT connected at the receiver, which is
# why J5 is a 2-pin header and not a 3-pin one -- the isolation is the point.
Part("Device", "D", value="1N4148",
     footprint="Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal",
     ref="D1")[1, 2] += opto[1], opto[2]
opto[6] += v3v3                                # 3V3, so its output feeds the Pi direct
opto[5] += gnd
C("100nF", ref="C20")[1, 2] += v3v3, gnd
R("10k")[1, 2] += v3v3, opto[4]
opto[4] += midi_rx

# ---- J20/J21: CTRL 1/2 -- one jack takes an expression pedal OR a switch -----
# tip -> ADC with a 10k pull-up; ring -> 3V3 THROUGH 1k. That 1k matters: a TS plug
# shorts ring to sleeve, so a hard 3V3 on the ring would be a dead short to GND
# every time someone plugs in a footswitch. With it, a pot reads mid-scale and a
# switch reads rail-to-rail, and firmware can tell them apart.
R("1k")[1, 2] += v3v3, ctrl_ref
for _ref, _net in (("J20", ctrl1), ("J21", ctrl2)):
    j = jst(3, _ref, "CTRL_TRS")
    j[1] += _net                               # tip   = wiper / switch
    j[2] += ctrl_ref                           # ring  = pot top, current-limited
    j[3] += gnd                                # sleeve
    R("10k")[1, 2] += v3v3, _net
    C("10nF")[1, 2] += _net, gnd               # anti-alias / debounce

# ---- J6/J7: ring+encoder and the indicator chain ----------------------------
# J6's pin order is NOT free: it must match ring_board.py's J1, which main_board.py
# already mirrors by hand. This board is the third copy, so _check() gates it.
RING_PINOUT = ["+5V_LED", "+5V_LED", "GND", "GND", "RING_DATA_OUT",
               "ENC_A", "ENC_B", "ENC_SW"]
j_ring = jst(8, "J6", "RING_ENC")
j_ring[1, 2] += v5led
j_ring[3, 4] += gnd
j_ring[5] += ring_out
j_ring[6] += encA
j_ring[7] += encB
j_ring[8] += encSW

j_ind = jst(3, "J7", "INDICATORS")
j_ind[1] += v5led
j_ind[2] += ind_out
j_ind[3] += gnd

# ---- J8: rear power button -- passed STRAIGHT through to a Pi GPIO ----------
# Not via the MCU: a clean shutdown has to work when the MCU is wedged or
# mid-reflash, which is exactly when it is wanted.
j_btn = jst(2, "J8", "PWR_BTN")
j_btn[1] += pwr_btn
j_btn[2] += gnd

# ---- J9: SWD, so the Pi can reflash the MCU without opening the case ---------
# Three flying wires to the Pico's debug pads. Those pads are deliberately NOT in
# the footprint: neither KiCad's nor ncarandini's THT variant carries them, and a
# guessed pad offset is a respin.
j_swd = jst(3, "J9", "SWD_TO_PICO")
j_swd[1] += swclk
j_swd[2] += gnd
j_swd[3] += swdio

# ---- J3: power in, 5 V from the external potted buck ------------------------
# Four pins so the LED pair is a SEPARATE run back to the buck -- that is what
# makes the +5V/+5V_LED split real rather than cosmetic.
# No series Schottky: V1's guards a barrel jack a user can plug anything into;
# this is a keyed internal JST, and a diode would burn ~0.4 W of LED headroom.
j_pwr = jst(4, "J3", "5V_IN")
j_pwr[1] += v5
j_pwr[2] += gnd
j_pwr[3] += v5led
j_pwr[4] += gnd
C("470uF", fp="Capacitor_THT:CP_Radial_D10.0mm_P5.00mm", ref="C30")[1, 2] += v5led, gnd
C("100uF", fp="Capacitor_THT:CP_Radial_D6.3mm_P2.50mm", ref="C31")[1, 2] += v5, gnd

# ---- J2: the Pi ribbon (2x20, SHROUDED and KEYED) ---------------------------
# Reversed, a 2x20 puts 5 V onto GND pins -- specify a shrouded header with a
# polarising notch and a keyed IDC socket. Cheapest mistake on the board to
# design out. Only ~11 of the 40 ways carry anything; the rest are the Pi's own
# pins and are left alone.
#   Pi pin 2,4  = 5V        1,17 = 3V3      6,9,14,20,25,30,34,39 = GND
#   Pi pin 8    = GPIO14 TXD (uart0)        10 = GPIO15 RXD (uart0)
#   Pi pin 7    = GPIO4      (uart2 TX)     29 = GPIO5    (uart2 RX)
#   Pi pin 5    = GPIO3  -- the power button pin: GPIO3 is the one that can WAKE
#                           the Pi from halt, which a plain GPIO cannot
#   Pi pin 18   = GPIO24 SWCLK              22 = GPIO25 SWDIO
PI_HDR = {
    2: v5, 4: v5, 1: v3v3, 17: v3v3,
    6: gnd, 9: gnd, 14: gnd, 20: gnd, 25: gnd, 30: gnd, 34: gnd, 39: gnd,
    8: midi_tx, 10: midi_rx,
    7: link_rx,     # Pi uart2 TX -> Pico RX  (3V3 -> 3V3, direct)
    29: link_tx,    # Pi uart2 RX <- Pico TX  (3V3 -> 3V3, direct)
    5: pwr_btn,
    18: swclk, 22: swdio,
}
j_pi = Part("Connector_Generic", "Conn_02x20_Odd_Even",
            footprint="Connector_IDC:IDC-Header_2x20_P2.54mm_Vertical",
            ref="J2", value="PI_RIBBON")
for _pin in range(1, 41):
    if _pin in PI_HDR:
        j_pi[_pin] += PI_HDR[_pin]
    else:
        j_pi[_pin].do_erc = False

# ---- gates ------------------------------------------------------------------

STATION_HEADERS = {          # rear-panel station -> the header that terminates it
    "POWER": "J8", "MIDI_IN": "J5", "MIDI_OUT": "J4",
    "CTRL_1": "J20", "CTRL_2": "J21",
}
STATION_NOT_ON_BOARD = {     # ...and the ones that deliberately never touch it
    "9V_DC": "goes to the external buck, not this board",
    "FUSE": "in series with the 9 V input, upstream of everything here",
    "USB3_1": "passes through to a Pi USB port",
    "USB3_2": "passes through to a Pi USB port",
}


def _check(strict_stations=True):
    """Prove the pin budget and the connector set before any copper is laid."""
    used = {}
    for name, gp in GPIO.items():
        assert gp in PICO, f"PIN_MAP: {name} -> GP{gp} is not on the module header"
        assert gp not in used, f"PIN_MAP: GP{gp} is assigned to both {used[gp]} and {name}"
        used[gp] = name
    for name, gp in GPIO.items():
        if name.startswith("CTRL"):
            assert gp in ADC_GPIO, (
                f"PIN_MAP: {name} needs an ADC pin so an expression pedal reads as a "
                f"voltage, but GP{gp} is not one of {ADC_GPIO}")
        else:
            assert gp not in ADC_GPIO, (
                f"PIN_MAP: {name} squats on ADC pin GP{gp}; only {len(ADC_GPIO)} exist "
                "and CTRL needs two")
    for gp in SPARE_GPIO:
        assert gp not in used, (
            f"PIN_MAP: GP{gp} is listed as spare but {used[gp]} uses it -- an ERC "
            "exemption on a live pin hides a real unconnected-pin warning")
    assert len(FSW_ORDER) == 10, f"PIN_MAP: {len(FSW_ORDER)} footswitches, expected 10"

    # the ring header is the THIRD hand-copy of a pinout held together by a comment
    assert RING_PINOUT == ["+5V_LED", "+5V_LED", "GND", "GND", "RING_DATA_OUT",
                           "ENC_A", "ENC_B", "ENC_SW"], (
        "RING_CONTRACT: J6 no longer matches ring_board.py's J1 -- 1,2=+5V_LED "
        "3,4=GND 5=RING_DATA 6=ENC_A 7=ENC_B 8=ENC_SW")
    for _i, _want in enumerate(RING_PINOUT, start=1):
        got = {n.name for n in j_ring[_i].nets}
        assert _want in got, f"RING_CONTRACT: J6 pin {_i} carries {got}, expected {_want}"

    # the Pi's power-button pin must be the one that can wake it from halt
    assert 5 in PI_HDR and PI_HDR[5] is pwr_btn, (
        "PWR_BTN: the button must land on Pi header pin 5 (GPIO3) -- it is the only "
        "pin that wakes the Pi from halt; any other GPIO gives shutdown but not wake")

    # nothing may drive the Pi at more than 3V3
    for n in (link_tx, link_rx, midi_rx, pwr_btn, swclk, swdio):
        assert v5 not in n.nets and v5led not in n.nets, (
            f"PI_LEVELS: {n.name} touches a 5 V rail -- Pi GPIO is not 5 V tolerant")

    if strict_stations:
        assert os.path.exists(STATIONS_JSON), (
            f"REAR_IO_COVER: {STATIONS_JSON} is missing -- run segno_enclosure.py "
            "--report first; the board's connector set is checked against it")
        with open(STATIONS_JSON) as fh:
            declared = [s["ref"] for s in json.load(fh)["stations"]]
        for ref in declared:
            assert ref in STATION_HEADERS or ref in STATION_NOT_ON_BOARD, (
                f"REAR_IO_COVER: the panel declares {ref} but this board neither "
                "terminates it nor says why not")
        for ref in STATION_HEADERS:
            assert ref in declared, (
                f"REAR_IO_COVER: the board terminates {ref}, which the panel no "
                "longer has")
    return True


def report():
    lay = []
    for name, gp in sorted(GPIO.items(), key=lambda kv: kv[1]):
        lay.append("  GP%-3d pad %-3d %s" % (gp, PICO[gp], name))
    return ("Segno CONSOLE board v2 (#747)\n"
            "Pico 2 (RP2350) on Module:RaspberryPi_Pico_Common_THT\n"
            "\nPin map:\n" + "\n".join(lay) +
            "\n\nRails : +5V (logic) | +5V_LED (WS2812, own pair to the buck) | "
            "+3V3 (from the Pi)\n"
            "Link  : 3V3 <-> 3V3, DIRECT -- the Pico is not 5 V, so no divider\n"
            "AHCT  : MIDI OUT, ring, indicators (the three real 3V3->5V crossings)\n")


def _selftest():
    """Flip each gate and fail unless every one of them bites. New to this repo --
    see the plan. Returns before generate_netlist() so a self-test run can never
    overwrite the committed netlist with a deliberately broken one."""
    import copy
    cases = []

    def case(name, mutate):
        cases.append((name, mutate))

    def _dup_gpio():
        GPIO["SW_STOP"] = GPIO["SW_UNDO"]

    def _ctrl_off_adc():
        # SWAP rather than collide -- setting CTRL to an already-used pin trips the
        # duplicate check first and never reaches the ADC assertion, which would
        # leave that gate unproven.
        GPIO["CTRL1_TIP"], GPIO["SW_RECPLAY"] = GPIO["SW_RECPLAY"], GPIO["CTRL1_TIP"]

    def _ring_order():
        RING_PINOUT[4] = "ENC_A"

    def _btn_pin():
        PI_HDR[5] = gnd

    def _fsw_count():
        FSW_ORDER.append("EXTRA")

    def _station():
        STATION_HEADERS["NOT_A_STATION"] = "J99"

    case("duplicate GPIO", _dup_gpio)
    case("CTRL off an ADC pin", _ctrl_off_adc)
    case("ring pinout drift", _ring_order)
    case("power button off GPIO3", _btn_pin)
    case("wrong footswitch count", _fsw_count)
    case("board terminates a station the panel lacks", _station)

    ok = True
    for name, mutate in cases:
        saved = (dict(GPIO), list(RING_PINOUT), dict(PI_HDR),
                 list(FSW_ORDER), dict(STATION_HEADERS))
        mutate()
        try:
            _check()
            print("  NO BITE  %s  <-- gate is dead" % name)
            ok = False
        except AssertionError as exc:
            print("  bites    %-42s %s" % (name, str(exc).replace("\n", " ")[:58]))
        finally:
            GPIO.clear(); GPIO.update(saved[0])
            RING_PINOUT[:] = saved[1]
            PI_HDR.clear(); PI_HDR.update(saved[2])
            FSW_ORDER[:] = saved[3]
            STATION_HEADERS.clear(); STATION_HEADERS.update(saved[4])
    return ok


if "--selftest" in sys.argv:
    print("Negative controls:")
    sys.exit(0 if _selftest() else 1)

print(report())
print("Board assertions ...", end=" ")
_check()
print("ALL PASS")

for _n in (gnd, v5, v5led, v3v3):
    _n.drive = POWER

ERC()
generate_netlist()
