"""SKiDL generator for the Segno CONSOLE board v2 (issue #747).

The 10-pedal console's control board. Lies flat on the bottom plate beside the
Raspberry Pi 5 and links to it over a KEYED 2x20 ribbon -- about 500 mm of it, not
the "short" cable this line used to claim: the board sits under its five rear-panel
stations on the left of the plate and the Pi sits under the 16" screen on the right,
which is 477 mm centre to centre. See board_mounts() in segno_enclosure.py. Carries a
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
import tempfile

import netlist
from skidl import (
    Pin,
    Part, Net, generate_netlist, ERC, POWER, set_default_tool, KICAD8,
    lib_search_paths,
)

set_default_tool(KICAD8)

# SKiDL puts the active circuit in builtins rather than exporting it, and the
# POLARITY gate below wants EVERY part, not a list this file remembers to update.
from builtins import default_circuit          # noqa: E402  (set up by skidl)

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
# 2.50 mm lead pitch, not 5.00. Commodity "104" discs and MLCCs ship on 2.5 mm
# spacing; the 5 mm land would have meant splaying the leads on all 16 of them, or
# hunting an unusual part. Changing the board is cheaper than changing the BOM.
# (C30 is the opposite case and keeps its 10 mm / 5 mm land -- order a 470uF at
# 25 V or 35 V, since the common 16 V part is 8 x 11.5 mm on 3.5 mm pitch and will
# not physically fit.)
C_FP = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P2.50mm"
JST = "Connector_JST:JST_XH_B%dB-XH-A_1x%02d_P2.50mm_Vertical"


def R(value, **kw):
    return Part("Device", "R", value=value, footprint=R_FP, **kw)


def C(value, fp=C_FP, **kw):
    return Part("Device", "C", value=value, footprint=fp, **kw)


def CP(value, fp, **kw):
    """An ELECTROLYTIC. Polarised symbol, not just a polarised footprint.

    C30/C31 were built with Device:C -- the non-polarised symbol -- on CP_Radial
    footprints. The board was right (pad 1 is + on those footprints, and pin 1 went
    to +5V), but nothing DECLARED the part as polarised, so nothing could ever check
    it: reorder the two pins in a future edit and you get a 470uF electrolytic
    backwards across a 5 V rail, which vents at power-on and no gate here would have
    said a word. ring_board.py already used C_Polarized, so this was an oversight.
    """
    return Part("Device", "C_Polarized", value=value, footprint=fp, **kw)


def jst(n, ref, value):
    return Part("Connector_Generic", "Conn_01x%02d" % n,
                footprint=JST % (n, n), ref=ref, value=value)


# ---- nets -------------------------------------------------------------------

gnd = Net("GND")
v5 = Net("+5V")            # logic: Pico VSYS + the AHCT125
# ONE 5 V rail. There used to be a second, "+5V_LED", on the theory that giving the
# WS2812s their own pair back to the supply kept their IR drop out of the logic
# rail. Both rails come off the same 8-36V->5V 10A buck, so it was never redundancy
# or headroom -- and the benefit it did have was half undone on this board anyway,
# because GND is a single pour: the feeds were separated and the returns were not.
# J3 keeps four ways, but as two PARALLEL pairs, which buys the thing that is
# actually scarce: JST XH is rated ~3 A per contact and the LED chain alone
# approaches that.
#
# The ring board is unaffected. It declares its own single supply as Net("+5V_LED")
# locally (ring_board.py:46); two netlists joined by a cable do not have to agree on
# net NAMES, only on pin order -- which is what RING_CONTRACT gates, by reading
# ring_board.net and mapping the two names onto each other (see RING_ALIASES).
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
            footprint="Module:RaspberryPi_Pico_SMD_HandSolder", ref="J1", value="Pico2")
# Conn_01x40 is the 40 castellated ways. The SMD footprint ALSO carries the three
# debug pads (D1/D2/D3 along the module's bottom edge), which no generic connector
# symbol has, so they are added to the part by hand -- otherwise SWD has nothing to
# attach to and silently falls back to needing a header.
pico.add_pins(Pin(num="D1", name="SWCLK", func=Pin.types.BIDIR),
              Pin(num="D2", name="GND", func=Pin.types.PASSIVE),
              Pin(num="D3", name="SWDIO", func=Pin.types.BIDIR))
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
# GP19 is the only pin left with nothing on it. The other six spares now go to the
# expansion header J22 rather than being quietly ERC-exempted into thin air -- an
# unpopulated 2x5 costs a footprint and nothing else, and it is the difference
# between "add a feature" and "respin the board".
SPARE_GPIO = (0, 1)
# All five are row-B pads, so ONE header reaches all of them -- GP0/GP1 are row A
# (the far end of the module) and would have made J22 straddle the whole thing, so
# they stay spare instead. Same rule the other connectors are gated on.
EXPANSION_GPIO = (19, 20, 21, 22, 28)
for _gp in SPARE_GPIO:
    pico[PICO[_gp]].do_erc = False

# ---- pin assignment ---------------------------------------------------------
GPIO = {
    # THE PIN MAP IS A FLOORPLAN. The module's pads 1..20 are one physical row and
    # 21..40 the other, so a GPIO number decides where on the board a connector can
    # physically sit. Each connector's signals are therefore kept inside ONE row and
    # adjacent, and the row is chosen to face the part it talks to:
    #
    #   row A, left  ..  centre ......................  right
    #   pads 1        4 --------- 15                16 17  19 20
    #                 the ten footswitches           J6: ring + encoder
    #   row B, left  ..  centre ......................  right
    #   pads 40 39               32 31                 23   22 21
    #   VBUS VSYS <- J3          CTRL2/1                IND  LINK_RX/TX -> J2
    #
    # LINK is on GP16/17, not GP0/1: both are UART0 TX/RX pairs electrically, but
    # GP16/17 are pads 21/22 -- the end nearest the Pi ribbon J2, which is what the
    # link actually talks to. On GP0/1 (pads 1/2) it left the module at the far end
    # and crossed the whole board. Same for IND_DATA on GP18: it is one of the three
    # signals U1 buffers, and U1 sits off the module's right end.
    "LINK_TX": 16, "LINK_RX": 17,
    "SW_RECPLAY": 2, "SW_STOP": 3, "SW_UNDO": 4, "SW_MODE": 5,
    "SW_TRACK1": 6, "SW_TRACK2": 7, "SW_TRACK3": 8, "SW_TRACK4": 9,
    "SW_CLEAR": 10, "SW_BANK": 11,
    "RING_DATA": 12, "ENC_A": 13, "ENC_B": 14, "ENC_SW": 15,
    "IND_DATA": 18,
    "CTRL1_TIP": 26, "CTRL2_TIP": 27,
}

# Which pads each UART instance can reach on RP2350. Moving LINK to a "spare-
# looking" GPIO is a one-character edit that silently costs the link its hardware
# UART, so the pairing is gated rather than trusted to the comment above.
UART_PINS = {0: ({0, 12, 16, 28}, {1, 13, 17, 29}),
             1: ({4, 8, 20, 24}, {5, 9, 21, 25})}
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
# THE FIRMWARE OWNS HALF OF THIS CIRCUIT. There is no external pull-up: each
# footswitch is a bare contact to GND with a 100nF cap, and the idle-high level
# comes from the RP2350's INTERNAL pull-up. Forget to enable it and all ten inputs
# float with a capacitor on them, which reads as noise, not as "always released".
#
# It also sets the timing: the internal pull-up is ~50-80k, so with 100nF the
# RELEASE edge is an RC of ~5-8 ms while the press is instant (the switch shorts
# the cap to ground). That asymmetry is why the debounce wants to trigger on the
# leading edge -- the slow side is the one that does not matter.
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
# WHICH GATE carries which signal is a layout decision, not an arbitrary one: on a
# DIP-14 pins 1-7 are one side and 8-14 the other, so a gate's input pin decides
# which side of the package that signal has to arrive from. IND_DATA and RING_DATA
# come off the module (to U1's left) and MIDI_TX comes off the Pi ribbon (to its
# right), so they take gates whose inputs face the right way. Wired the other way
# round, IND_DATA had to travel around the package and was the one net on the board
# the autorouter could not finish.
buf[1] += gnd; buf[2] += ind_data; buf[3] += ind_buf            # gate A: indicators
buf[4] += gnd; buf[5] += ring_data; buf[6] += ring_buf          # gate B: ring
buf[10] += gnd; buf[9] += midi_tx; buf[8] += midi_out_buf       # gate C: MIDI OUT
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
# ANTI-parallel with the opto's LED, and read that twice: KiCad's Device:D numbers
# pin 1 as K and pin 2 as A, so this line -- which looks like "same direction as the
# LED" -- is the correct reverse clamp. MIDI_CLAMP in _check() asserts it by PIN
# NAME so the next reader does not have to trust the numbering.
d_clamp = Part("Device", "D", value="1N4148",
               footprint="Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal", ref="D1")
d_clamp[1, 2] += opto[1], opto[2]
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
for _ref, _net in (("J20", ctrl1), ("J21", ctrl2)):
    j = jst(3, _ref, "CTRL_TRS")
    j[1] += _net                               # tip   = wiper / switch
    # ONE 1k PER JACK, not one shared between them. Shared, a TS plug in either
    # jack -- which is the normal way to use a footswitch, and the exact case the
    # resistor exists for -- shorts ring to sleeve and drags the OTHER jack's pot
    # top to ground, so an expression pedal there reads a constant. Two pedals also
    # loaded each other's full scale. Separate resistors, separate nets.
    # TWO RAILS, ON PURPOSE-ENOUGH. The pot's top comes from the PI's 3V3 (this
    # whole board's 3V3 does), while the ADC reading it references the PICO's own
    # rail: "ADC_VREF is the ADC power supply (and reference) voltage, and is
    # generated on Pico 2 by filtering the 3.3 V supply" (Pico 2 datasheet). So the
    # measurement is the ratio of two different regulators, which is not ideal.
    #
    # It is left alone deliberately. The same datasheet puts an inherent ~30 mV
    # (~1%) offset on ADC_VREF from its own 200R filter, drifting with temperature
    # and sample rate, plus SMPS ripple in PFM mode -- so rail mismatch is one error
    # among several of the same size, and every one of them is absorbed by the
    # calibration an expression pedal needs anyway (pot travel varies far more).
    # The 1k below also keeps the top of travel at 3.3 x 10k/11k = ~3.0 V against a
    # ~3.27 V reference, so the sweep cannot clip at the top whichever rail is high.
    #
    # Firmware notes: enable the RP2350's INTERNAL pull-ups (the encoder and these
    # jacks lose their bias if the Pi is down while the console is up), and consider
    # driving the module's GPIO23 high to force the SMPS into PWM mode while
    # sampling, which the datasheet says "can greatly reduce the inherent ripple".
    _ref_net = Net(_ref + "_REF")
    R("1k")[1, 2] += v3v3, _ref_net
    j[2] += _ref_net                           # ring  = pot top, current-limited
    j[3] += gnd                                # sleeve
    R("10k")[1, 2] += v3v3, _net
    C("10nF")[1, 2] += _net, gnd               # anti-alias / debounce

# ---- J6/J7: ring+encoder and the indicator chain ----------------------------
# J6's pin order is NOT free: it is one end of an 8-way cable whose other end is
# ring_board.py's J1. There is no hand-written copy of that pinout here to drift
# from it -- _check() reads ring_board.net and compares the two connectors pin by
# pin. The two netlists do NOT have to agree on net NAMES (see the rail note
# above), only on which conductor each pin carries, so the alias table below is
# the entire contract between the boards. Anything not aliased must match exactly.
RING_NET = os.path.join(HERE, "ring_board.net")
RING_ALIASES = {          # ring_board.py's name -> this board's name
    "+5V_LED": "+5V",     # that board still declares its own single supply locally
    "RING_DATA": "RING_DATA_OUT",   # here it is the AHCT125's buffered output
}
j_ring = jst(8, "J6", "RING_ENC")
j_ring[1, 2] += v5
j_ring[3, 4] += gnd
j_ring[5] += ring_out
# The encoder pull-ups live HERE, at 3V3, and ring_board.py's two 10k to its 5 V
# rail are deleted. Those were correct when the other end of this cable was a 5 V
# Pro Micro (main_board.py); against an RP2350 they sat 1.4 V over the 3.6 V
# absolute maximum on GP13/GP14, continuously, whenever the console was powered.
# Nothing caught it: PI_LEVELS guards the Pi, and no gate could see across into a
# second generator's netlist. PICO_LEVELS below now does.
R("10k")[1, 2] += v3v3, encA
R("10k")[1, 2] += v3v3, encB
R("10k")[1, 2] += v3v3, encSW      # ring_board.py never had one on the switch
j_ring[6] += encA
j_ring[7] += encB
j_ring[8] += encSW

j_ind = jst(3, "J7", "INDICATORS")
j_ind[1] += v5
j_ind[2] += ind_out
j_ind[3] += gnd

# ---- J8: rear power button -- passed STRAIGHT through to a Pi GPIO ----------
# Not via the MCU: a clean shutdown has to work when the MCU is wedged or
# mid-reflash, which is exactly when it is wanted.
j_btn = jst(2, "J8", "PWR_BTN")
j_btn[1] += pwr_btn
j_btn[2] += gnd

# ...and passed straight through to the Pi 5's own power-button pads. On a Pi 5 an
# external button cannot be a GPIO: RP1 and the SoC are unpowered until the PMIC
# brings them up, so nothing on the 40-way can wake the machine. Raspberry Pi break
# the function out as two solder pads (J2, beside the RTC battery connector) and
# that is the only thing that works. This header is a 2-pin flying lead to them.
j_pi_btn = jst(2, "J9", "PI_PWR_PADS")
j_pi_btn[1] += pwr_btn
j_pi_btn[2] += gnd

# ---- SWD: straight onto the module's own debug pads, no connector -----------
# The THT footprint does not carry the debug pads, so v1 of this board broke SWD
# out to a 3-pin header (J9) and three flying wires. The SMD_HandSolder footprint
# DOES carry them -- its description is "surface-mount footprint with debug pads
# for hand soldering, supports Raspberry Pi Pico 2 (non-W)" -- as pads D1/D2/D3
# along the module's bottom edge. So the header, its wires and the space it took
# in the crowded right-hand column all go away.
#
# The trade: the module is now soldered down via its castellations rather than
# sitting on headers, so it is not swappable without a hot-air station. For a
# sealed console that is reflashed over SWD anyway, that is the right way round.
SWD_PADS = {"D1": swclk, "D2": gnd, "D3": swdio}
for _pad, _net in SWD_PADS.items():
    pico[_pad] += _net

# ---- J22: expansion -- the six GPIO that are otherwise doing nothing ---------
# Deliberately unpopulated by default. GP0/GP1 are a UART0 pair and GP20/GP21 a
# UART1 pair, so this header can carry a whole second serial device; GP28 is an
# ADC, so it can carry a third pedal input. Nothing on the board depends on it.
EXP_PINOUT = ["+3V3", "+5V", "GP19", "GP20", "GP21", "GP22", "GP28", "GND"]
j_exp = Part("Connector_Generic", "Conn_02x04_Odd_Even",
             footprint="Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical",
             ref="J22", value="EXPANSION")
j_exp[1] += v3v3
j_exp[2] += v5
for _i, _gp in enumerate(EXPANSION_GPIO, start=3):
    n = Net("EXP_GP%d" % _gp)
    pico[PICO[_gp]] += n
    j_exp[_i] += n
j_exp[8] += gnd

# ---- H1..H4: the mounting holes, which are a CIRCUIT, not just geometry ------
# They used to be bare NPTH -- no copper -- so the board floated inside an earthed
# metal chassis. That was never a decision; it was the default footprint. And the
# board does not float in practice anyway: two USB 3.0 panel couplers, two DIN-5
# chassis sockets and two D-series TRS jacks all bolt metal flanges through a metal
# panel, and the TRS sleeves ARE this board's GND. The choice is not whether the
# board touches the chassis, only whether it does so through a defined, short path
# or through whichever connector flange happens to have the best contact.
#
# So: ONE hard bond, at the corner nearest the rear-panel loom and diagonally away
# from the Pi ribbon. The other three holes get the same PLATED PAD and nothing
# else -- isolated copper, touching only their standoff.
#
# There are no components on those three. An earlier cut fitted each with a 10 nF
# 2 kV cap and a 1 M bleeder, DNF, so EMC testing could add an RF bond without a DC
# loop. The idea is sound and the parts were wrong: nothing fits those corners in
# through-hole, so they were SMD -- six surface-mount parts on a board that is
# hand-soldered through-hole on purpose, for a bond that may never be wanted. If it
# ever is, the pad is there and a leaded cap solders from it to the nearest ground
# via, which is a bench job on one board rather than a BOM line on every board.
CHASSIS_BOND_HOLE = "H1"
MOUNT_HOLES = ("H1", "H2", "H3", "H4")
MOUNT_FP = "MountingHole:MountingHole_3.2mm_M3_Pad"   # 6.4 mm pad, bare on BOTH
                                                      # faces: screw head above,
                                                      # standoff below
holes = {}          # ref -> the hole part, so the gate reads the PART, not a search
for _h in MOUNT_HOLES:
    _hole = Part("Mechanical", "MountingHole_Pad", ref=_h, footprint=MOUNT_FP,
                 value="M3 CHASSIS" if _h == CHASSIS_BOND_HOLE else "M3")
    holes[_h] = _hole
    if _h == CHASSIS_BOND_HOLE:
        _hole[1] += gnd
        continue
    # Deliberately connected to nothing. Named like the other exemptions on this
    # board rather than tolerated as a warning in the log.
    _iso = Net("CHASSIS_%s" % _h)
    _iso.do_erc = False          # isolated on purpose: a pad for a standoff, not a
    _hole[1] += _iso             # signal. A wall of expected warnings is how a real
    _hole[1].do_erc = False      # one gets missed -- see the SPARE_GPIO note above

# ---- J3: power in, 5 V from the external potted buck ------------------------
# Four pins, doubled up: 1+3 are both +5V and 2+4 are both GND. This used to be a
# separate LED pair; see the rail note at the top for why that was dropped.
# No series Schottky: V1's guards a barrel jack a user can plug anything into;
# this is a keyed internal JST, and a diode would burn ~0.4 W of LED headroom.
j_pwr = jst(4, "J3", "5V_IN")
j_pwr[1] += v5
j_pwr[2] += gnd
j_pwr[3] += v5          # pins 1/3 and 2/4 are PARALLEL, not two rails: XH is
j_pwr[4] += gnd         # ~3 A per contact and the LED chain alone nears that
CP("470uF", "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm", ref="C30")[1, 2] += v5, gnd
CP("100uF", "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm", ref="C31")[1, 2] += v5, gnd

# ---- J2: the Pi ribbon (2x20, SHROUDED and KEYED) ---------------------------
# Reversed, a 2x20 puts 5 V onto GND pins -- specify a shrouded header with a
# polarising notch and a keyed IDC socket. Cheapest mistake on the board to
# design out. Only ~11 of the 40 ways carry anything; the rest are the Pi's own
# pins and are left alone.
#   Pi pin 2,4  = 5V  -- DELIBERATELY NOT CONNECTED. Tying them to +5V puts the
#                        external buck in hard parallel with the Pi 5's own PMIC
#                        rail, with no ORing diode: whichever regulator sits higher
#                        back-feeds the other, bypassing the Pi's input protection.
#                        It also lands the whole WS2812 load on the Pi's 5 V header
#                        pin, which segno_console_shopping_list.md explicitly
#                        forbids. The Pi is powered from its own supply; this board
#                        is powered from J3. They share only GND and 3V3.
#                            1,17 = 3V3      6,9,14,20,25,30,34,39 = GND
#   Pi pin 8    = GPIO14 TXD (uart0)        10 = GPIO15 RXD (uart0)
#   Pi pin 24   = GPIO8  (uart3 TX)         21 = GPIO9    (uart3 RX)
#                        Firmware wants `dtoverlay=uart3-pi5` -- "Enable uart 3 on
#                        GPIOs 8-9. Pi 5 only." (raspberrypi/linux overlays README).
#                        NOT portable to a Pi 4, where GPIO8-9 is uart4. Mid-header
#                        on purpose; see PI_RESERVED.
#   Pi pin 5    = GPIO3  -- NOT the power button. GPIO3 wakes a Pi 4; on a Pi 5 the
#                           GPIO lives behind RP1 and power-on is the PMIC's job, so
#                           no GPIO can wake it. The Pi 5's button goes on the J2
#                           solder pads by the RTC connector -- hence J9 below.
#   Pi pin 18   = GPIO24 SWCLK              22 = GPIO25 SWDIO
# Physical pins that something ELSE on this Pi has already claimed. The console
# does not have a bare Pi: a GeeekPi N07 NVMe board lives under it, and it takes
# GPIO4 (pin 7) along with 5 V and grounds. Sharing a RAIL with it is fine -- rails
# are shared by definition -- so only SIGNAL pins are reserved here.
#
# The link UART sat on pin 7 until this was noticed, which would have been a board
# that assembles, passes every gate, and cannot talk to its own MCU.
# ...and the reading is POSITIONAL, so it could be counted from either end of the
# header. Taken from the near end it is pins 2/4/6 + 7/9; mirrored, it lands on
# 39/37/35 + 34/32. Both ends are therefore suspect until a meter says otherwise,
# which is why the link sits in the MIDDLE of the header now rather than at either
# end -- a choice that is right under both readings and costs nothing.
PI_RESERVED = {
    7: "GeeekPi N07 NVMe board (GPIO4), as observed from the near end",
    32: "possible N07 contact if the observation is counted from the far end",
    33: "possible N07 contact if the observation is counted from the far end",
}
# MIDI KEEPS GPIO14/15 (uart0, pins 8/10), by decision, even though they appear on
# the list of pins the NVMe module may want. There is nowhere else worth going: a
# Pi 5 has five hardware UART pairs, and once GPIO4/5, GPIO12/13 and GPIO14/15 are
# excluded the only ones left are GPIO8/9 -- which the link already has -- and
# GPIO0/1, which the HAT+ spec reserves for the ID EEPROM. Moving MIDI onto the
# Pico instead would work and was considered, but it reverses a settled decision
# (#747: MIDI terminates on the Pi's UART, because the Pi runs the looper).
#
# So the resolution is the module, not the board: if the N07 turns out to claim
# GPIO14/15 as well, swap the NVMe board for a PCIe-only one. That is a shopping
# decision on a part that is not yet committed, versus a respin of a board that is.
# Do not re-open this in review.
PI_HDR = {
    1: v3v3, 17: v3v3,
    6: gnd, 9: gnd, 14: gnd, 20: gnd, 25: gnd, 30: gnd, 34: gnd, 39: gnd,
    8: midi_tx, 10: midi_rx,
    # LINK sits MID-HEADER, on `dtoverlay=uart3-pi5` -- "Enable uart 3 on GPIOs 8-9.
    # Pi 5 only." Physical pins 24 and 21 are positions 11 and 12 of their rows, as
    # far from both ends as this header gets.
    #
    # It has moved twice. GPIO4/5 (uart2) was where the N07 was observed. GPIO12/13
    # (uart4) dodged that but sits at the FAR end -- and the observation was a count
    # of positions, which reads the same from either end, so the far end was no safer
    # than the near one. The middle is safe under both readings.
    #
    # GPIO8/9 are SPI0's CE0 and MISO. Nothing here uses SPI0: the screens are USB
    # and HDMI, the SSD is PCIe, and MIDI and the link are UARTs. If an SPI device
    # ever lands on this Pi, this is the pair it will want.
    24: link_rx,    # GPIO8, uart3 TX -> Pico RX  (3V3 -> 3V3, direct)
    21: link_tx,    # GPIO9, uart3 RX <- Pico TX  (3V3 -> 3V3, direct)
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
    "5V_DC": "the GX20 inlet: ONE 5 V supply feeds the Pi, both screens and this "
             "board (#754). It lands on J3, not here",
    "FUSE": "in series with the 5 V input, upstream of everything here",
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
    for gp in EXPANSION_GPIO:
        assert gp in PICO, f"PIN_MAP: expansion GP{gp} is not on the module header"
        assert gp not in used, (
            f"PIN_MAP: GP{gp} is on the expansion header AND used by {used[gp]} -- "
            "the header would fight the on-board function for the pin")
        used[gp] = "J22 expansion"
    # LINK must be a real hardware UART pair on ONE instance -- GP16 TX with GP29 RX
    # looks fine in a pin list and is two different UARTs.
    assert any(GPIO["LINK_TX"] in tx and GPIO["LINK_RX"] in rx
               for tx, rx in UART_PINS.values()), (
        f"LINK_UART: GP{GPIO['LINK_TX']}/GP{GPIO['LINK_RX']} is not a TX/RX pair on "
        f"one UART instance -- valid pairs are {UART_PINS}")

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

    # ...and both ends of a connector's signal group must sit in the same pad row,
    # or the connector cannot be placed near all of them. Row A is pads 1..20.
    for group in (("LINK_TX", "LINK_RX"),
                  ("RING_DATA", "ENC_A", "ENC_B", "ENC_SW"),
                  tuple("SW_" + n for n in FSW_ORDER)):
        rows = {PICO[GPIO[n]] <= 20 for n in group if n in GPIO}
        assert len(rows) == 1, (
            f"PAD_ROW: {group} straddles both pad rows of the module "
            f"({ {n: PICO[GPIO[n]] for n in group if n in GPIO} }) -- one connector "
            "carries them all, so it would have to reach around the module")
    exp_rows = {PICO[gp] <= 20 for gp in EXPANSION_GPIO}
    assert len(exp_rows) == 1, (
        f"PAD_ROW: J22's pins straddle both pad rows "
        f"({ {gp: PICO[gp] for gp in EXPANSION_GPIO} }) -- one header carries them all")

    # The two ends of the ring cable, compared against each other. This used to
    # assert a literal list against itself and never open ring_board.py at all,
    # while its message claimed it had -- so the day that board's encoder pull-ups
    # were deleted, nothing was watching the interface they sat on. The other end
    # is now READ.
    assert os.path.exists(RING_NET), (
        f"RING_CONTRACT: {RING_NET} is missing -- run ring_board.py; the other end "
        "of the ring cable is what J6 is checked against")
    ring_j1 = netlist.pin_map(RING_NET, "J1")
    assert sorted(int(p) for p in ring_j1) == list(range(1, 9)), (
        f"RING_CONTRACT: ring_board J1 has pins {sorted(ring_j1)}, expected 1..8 -- "
        "the cable is 8-way at this end")
    for _i in range(1, 9):
        _want = ring_j1[str(_i)]
        _want = RING_ALIASES.get(_want, _want)
        got = {n.name for n in j_ring[_i].nets}
        assert _want in got, (
            f"RING_CONTRACT: ring_board J1 pin {_i} carries {_want}, but J6 pin {_i} "
            f"carries {got} -- these are the two ends of one 8-way cable, so a pin "
            "that means different things at each end wires the encoder to the LEDs")

    assert len(EXP_PINOUT) == 8 and EXP_PINOUT[:2] == ["+3V3", "+5V"] \
        and EXP_PINOUT[-1] == "GND", (
            "EXPANSION: J22 must keep power on pins 1/2 and ground on pin 8 -- the "
            "pinout is silkscreened and anything plugged in trusts it")
    for _i, _gp in enumerate(EXPANSION_GPIO, start=3):
        assert EXP_PINOUT[_i - 1] == "GP%d" % _gp, (
            f"EXPANSION: J22 pin {_i} is labelled {EXP_PINOUT[_i - 1]} but wired to "
            f"GP{_gp}")

    # MIDI IN's clamp diode, by pin NAME. Reversed, the 1N4148 sits in parallel
    # with the opto's LED in the same direction, and its ~0.7 V forward drop shunts
    # the LED's ~1.4 V: almost no current reaches the phototransistor and MIDI IN is
    # dead. Nothing else on the board would notice -- ERC sees two connected pins
    # either way, and DRC sees copper. The trap is that Device:D is numbered K=1,
    # A=2, so the correct wiring reads backwards in the source.
    _led_a = {n.name for n in opto[1].nets}      # LED anode, fed via R5 from DIN 4
    _led_k = {n.name for n in opto[2].nets}      # LED cathode -> DIN 5
    _clamp_k = {n.name for n in d_clamp["K"].nets}
    _clamp_a = {n.name for n in d_clamp["A"].nets}
    assert _clamp_k == _led_a, (
        f"MIDI_CLAMP: D1's cathode is on {_clamp_k}, expected the opto's LED anode "
        f"{_led_a} -- a clamp in PARALLEL with the LED shunts it and MIDI IN "
        "receives nothing")
    assert _clamp_a == _led_k, (
        f"MIDI_CLAMP: D1's anode is on {_clamp_a}, expected the opto's LED cathode "
        f"{_led_k}")

    # Read off the PART, not off the SWD_PADS literal two lines above it. Asserting
    # against the dict that made the connections is a tautology, and it passed with
    # SWCLK and SWDIO swapped -- which is the mistake that actually happens, and
    # which bricks flashing rather than announcing itself.
    assert pico.footprint.endswith("RaspberryPi_Pico_SMD_HandSolder"), (
        f"SWD: J1 is on {pico.footprint}, which has no D1/D2/D3 debug pads -- SWD "
        "would need a header and three flying wires again")
    for _pad, _want in (("D1", "SWCLK"), ("D2", "GND"), ("D3", "SWDIO")):
        got = {n.name for n in pico[_pad].nets}
        assert _want in got, (
            f"SWD: the module's {_pad} pad carries {got}, expected {_want} -- the "
            "debug pad order is the module's, not ours, and swapping SWCLK/SWDIO "
            "leaves a board that cannot be flashed")

    # MIDI IN's clamp diode, by pin NAME. Reversed, the 1N4148 sits in parallel
    # with the opto's LED in the same direction, and its ~0.7 V forward drop shunts
    # the LED's ~1.4 V: almost no current reaches the phototransistor and MIDI IN is
    # dead. Nothing else on the board would notice -- ERC sees two connected pins
    # either way, and DRC sees copper. The trap is that Device:D is numbered K=1,
    # A=2, so the correct wiring reads backwards in the source.
    _led_a = {n.name for n in opto[1].nets}      # LED anode, fed via R5 from DIN 4
    _led_k = {n.name for n in opto[2].nets}      # LED cathode -> DIN 5
    _clamp_k = {n.name for n in d_clamp["K"].nets}
    _clamp_a = {n.name for n in d_clamp["A"].nets}
    assert _clamp_k == _led_a, (
        f"MIDI_CLAMP: D1's cathode is on {_clamp_k}, expected the opto's LED anode "
        f"{_led_a} -- a clamp in PARALLEL with the LED shunts it and MIDI IN "
        "receives nothing")
    assert _clamp_a == _led_k, (
        f"MIDI_CLAMP: D1's anode is on {_clamp_a}, expected the opto's LED cathode "
        f"{_led_k}")

    # Read off the PART, not off the SWD_PADS literal two lines above it. Asserting
    # against the dict that made the connections is a tautology, and it passed with
    # SWCLK and SWDIO swapped -- which is the mistake that actually happens, and
    # which bricks flashing rather than announcing itself.
    assert pico.footprint.endswith("RaspberryPi_Pico_SMD_HandSolder"), (
        f"SWD: J1 is on {pico.footprint}, which has no D1/D2/D3 debug pads -- SWD "
        "would need a header and three flying wires again")
    for _pad, _want in (("D1", "SWCLK"), ("D2", "GND"), ("D3", "SWDIO")):
        got = {n.name for n in pico[_pad].nets}
        assert _want in got, (
            f"SWD: the module's {_pad} pad carries {got}, expected {_want} -- the "
            "debug pad order is the module's, not ours, and swapping SWCLK/SWDIO "
            "leaves a board that cannot be flashed")

    # EXACTLY ONE hard bond from board ground to the chassis. Two would close a
    # mains-frequency loop through the Pi ribbon, which is the thing this scheme
    # exists to avoid; none would leave the board floating inside an earthed metal
    # case, relying on whichever connector flange happens to touch best. The other
    # holes are isolated pads, wired to nothing at all.
    _bonded = [h for h, p in holes.items() if gnd in p[1].nets]
    assert _bonded == [CHASSIS_BOND_HOLE], (
        f"CHASSIS_BOND: {_bonded or 'no hole'} is hard-bonded to GND, expected "
        f"exactly [{CHASSIS_BOND_HOLE}] -- two DC bonds close a hum loop through "
        "the ribbon, and zero leaves the board floating in an earthed metal box")
    for _h, _p in holes.items():
        if _h == CHASSIS_BOND_HOLE:
            continue
        _touching = {q.part.ref for n in _p[1].nets for q in n.get_pins()
                     if q.part.ref != _h}
        assert not _touching, (
            f"CHASSIS_BOND: {_h} is wired to {_touching} -- the other three holes "
            "are isolated pads. A second path to ground, through anything, is the "
            "loop this scheme exists to prevent")

    # The power button must NOT be on the 40-way at all. This gate used to assert
    # the opposite -- "the button must land on Pi header pin 5 (GPIO3)... the only
    # pin that wakes the Pi from halt" -- which is true of a Pi 4 and false of a
    # Pi 5, where the GPIO is behind RP1 and neither it nor the SoC is powered until
    # the PMIC wakes them. A gate can enforce a wrong belief just as firmly as a
    # right one; this one did, for the whole design.
    assert 5 not in PI_HDR, (
        "PWR_BTN: Pi header pin 5 (GPIO3) cannot wake a Pi 5 -- the button belongs "
        "on the Pi's own J2 solder pads, brought out as J9")
    assert {n.name for n in j_pi_btn[1].nets} == {"PWR_BTN"}, (
        "PWR_BTN: J9 must carry the button through to the Pi's J2 pads")

    # Every part with a POLARISED footprint must use a polarised symbol and sit the
    # right way round: pin 1 (+) on a positive rail, pin 2 (-) on ground. A reversed
    # electrolytic is the one assembly mistake on this board that fails loudly and
    # takes the rail with it, and DRC cannot see it -- copper is copper.
    for _p in default_circuit.parts:
        _fp = str(getattr(_p, "footprint", "") or "")
        if "CP_" not in _fp and "Polarized" not in _fp:
            continue
        assert "Polarized" in str(_p.name), (
            f"POLARITY: {_p.ref} has the polarised footprint {_fp.split(':')[-1]} but "
            f"the {_p.name} symbol -- nothing declares which end is positive, so "
            "nothing can check it")
        _plus = {n.name for n in _p[1].nets}
        _minus = {n.name for n in _p[2].nets}
        assert _plus & {"+5V", "+3V3"} and _minus == {"GND"}, (
            f"POLARITY: {_p.ref} has pin 1 (+) on {_plus} and pin 2 (-) on {_minus} "
            "-- an electrolytic backwards across a rail vents at power-on")

    # Nothing of ours may sit on a pin another board on this Pi has taken. Rails
    # are exempt: 3V3 and GND are shared by every HAT by definition, and sharing
    # them is the point.
    for _pin, _who in PI_RESERVED.items():
        _n = PI_HDR.get(_pin)
        assert _n is None or _n in (gnd, v3v3), (
            f"PI_RESERVED: Pi header pin {_pin} carries {_n.name}, but {_who} "
            "already uses it -- two drivers on one pin is a link that never comes up")

    # ...and the buck must not be paralleled with the Pi's own 5 V rail.
    for _pin in (2, 4):
        assert _pin not in PI_HDR, (
            f"PI_POWER: Pi header pin {_pin} is a 5 V SUPPLY pin. Connecting it ties "
            "the external buck to the Pi's PMIC rail with no ORing diode, and puts "
            "the WS2812 load on the Pi's 5 V pin -- which the shopping list forbids")

    # Nothing may drive the PICO over 3V3 either. There was no such gate: PI_LEVELS
    # guarded the Pi only, so the ring board's 5 V encoder pull-ups sat 1.4 V over
    # GP13/GP14's absolute maximum and every check on this board stayed green.
    for _pad, _name in ((PICO[GPIO[n]], n) for n in GPIO):
        for _n in pico[_pad].nets:
            assert v5 not in _n.nets, (
                f"PICO_LEVELS: {_name} (pad {_pad}) touches a 5 V rail -- RP2350 IO "
                "is 3.3 V and its absolute maximum is 3.6 V")

    # nothing may drive the Pi at more than 3V3
    for n in (link_tx, link_rx, midi_rx, pwr_btn, swclk, swdio):
        assert v5 not in n.nets, (
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
            "Pico 2 (RP2350) on Module:RaspberryPi_Pico_SMD_HandSolder\n"
            "\nPin map:\n" + "\n".join(lay) +
            "\n\nRails : +5V (logic AND WS2812, doubled contacts on J3) | "
            "+3V3 (from the Pi)\n"
            "Link  : 3V3 <-> 3V3, DIRECT -- the Pico is not 5 V, so no divider\n"
            "AHCT  : MIDI OUT, ring, indicators (the three real 3V3->5V crossings)\n")


def _selftest():
    """Flip each gate and fail unless every one of them bites. New to this repo --
    see the plan. Returns before generate_netlist() so a self-test run can never
    overwrite the committed netlist with a deliberately broken one."""
    global RING_NET
    cases = []

    def case(name, want, mutate):
        cases.append((name, want, mutate))

    def _dup_gpio():
        GPIO["SW_STOP"] = GPIO["SW_UNDO"]

    def _ctrl_off_adc():
        # SWAP rather than collide -- setting CTRL to an already-used pin trips the
        # duplicate check first and never reaches the ADC assertion, which would
        # leave that gate unproven.
        GPIO["CTRL1_TIP"], GPIO["SW_RECPLAY"] = GPIO["SW_RECPLAY"], GPIO["CTRL1_TIP"]

    def _ring_order():
        # The other board reorders ITS connector and this one does not follow. The
        # mutation therefore has to happen in ring_board.net -- a control that
        # edited a copy of the pinout held here would only prove that the copy
        # exists, which is exactly how this gate came to be dead.
        global RING_NET
        text = open(RING_NET).read()
        a, b = '(ref "J1")\n        (pin "6")', '(ref "J1")\n        (pin "7")'
        text = text.replace(a, "\0").replace(b, a).replace("\0", b)
        RING_NET = os.path.join(tempfile.gettempdir(), "ring_board.selftest.net")
        with open(RING_NET, "w") as fh:
            fh.write(text)

    def _swd_swap():
        # The one SWD mistake that gets made, and the reason the old gate was worth
        # nothing: a board that is electrically perfect and cannot be flashed.
        pico["D1"].disconnect(); pico["D3"].disconnect()
        pico["D1"] += swdio
        pico["D3"] += swclk

    def _second_bond():
        # The mistake this scheme exists to prevent: a second hole strapped to
        # ground "for a better connection", which closes a mains-frequency loop
        # through the ribbon and the Pi.
        holes["H3"][1].disconnect()
        holes["H3"][1] += gnd

    def _clamp_reversed():
        # The 1N4148 fitted the other way round: electrically parallel with the
        # opto's LED, which kills MIDI IN and looks perfectly fine everywhere else.
        d_clamp[1].disconnect(); d_clamp[2].disconnect()
        d_clamp[1] += opto[2]
        d_clamp[2] += opto[1]

    def _cap_backwards():
        # The 470uF reservoir fitted the other way round.
        c30 = next(p for p in default_circuit.parts if p.ref == "C30")
        c30[1].disconnect(); c30[2].disconnect()
        c30[1] += gnd
        c30[2] += v5

    def _reserved_pin():
        # The exact mistake this gate exists for: the link moved back onto a pin
        # the NVMe board underneath has already claimed.
        PI_HDR[7] = link_rx

    def _btn_pin():
        PI_HDR[5] = gnd

    def _fsw_count():
        FSW_ORDER.append("EXTRA")

    def _station():
        STATION_HEADERS["NOT_A_STATION"] = "J99"

    def _uart_split():
        # GP19 is on no UART at all and is the one pin still spare, so this reaches
        # the UART gate rather than tripping the duplicate or expansion checks that
        # run ahead of it.
        # GP1 is UART0's RX, never a TX, and is one of the two pins still spare --
        # so this reaches the UART gate instead of the duplicate or expansion checks.
        GPIO["LINK_TX"] = 1

    def _row_straddle():
        GPIO["ENC_SW"], GPIO["IND_DATA"] = GPIO["IND_DATA"], GPIO["ENC_SW"]

    def _exp_collide():
        GPIO["SW_STOP"] = EXPANSION_GPIO[0]

    # Each control names the gate it must trip. A control that trips some OTHER
    # gate proves nothing about its own and reads as a pass -- console_board_pcb.py
    # gained this check after two of its controls silently did exactly that, and
    # this side was catching a bare AssertionError and never asking which one.
    case("duplicate GPIO", "PIN_MAP:", _dup_gpio)
    case("expansion pin fighting an on-board function", "PIN_MAP:", _exp_collide)
    case("LINK on a pin with no UART", "LINK_UART:", _uart_split)
    case("connector group straddling both pad rows", "PAD_ROW:", _row_straddle)
    case("CTRL off an ADC pin", "PIN_MAP:", _ctrl_off_adc)
    case("ring board reorders its connector", "RING_CONTRACT:", _ring_order)
    case("SWCLK and SWDIO swapped on the debug pads", "SWD:", _swd_swap)
    case("a second mounting hole strapped to GND", "CHASSIS_BOND:", _second_bond)
    case("MIDI IN clamp diode reversed", "MIDI_CLAMP:", _clamp_reversed)
    case("reservoir electrolytic fitted backwards", "POLARITY:", _cap_backwards)
    case("link on a pin the NVMe board owns", "PI_RESERVED:", _reserved_pin)
    case("power button off GPIO3", "PWR_BTN:", _btn_pin)
    case("wrong footswitch count", "PIN_MAP:", _fsw_count)
    case("board terminates a station the panel lacks", "REAR_IO_COVER:", _station)

    ok = True
    ring_net_saved = RING_NET
    for name, want, mutate in cases:
        saved = (dict(GPIO), dict(PI_HDR), list(FSW_ORDER), dict(STATION_HEADERS))
        mutate()
        try:
            _check()
            print("  NO BITE    %s  <-- gate is dead" % name)
            ok = False
        except AssertionError as exc:
            msg = str(exc).replace("\n", " ")
            if want in msg:
                print("  bites      %-42s %s" % (name, msg[:56]))
            else:
                print("  WRONG GATE %-42s wanted %s, got: %s" % (name, want, msg[:40]))
                ok = False
        finally:
            GPIO.clear(); GPIO.update(saved[0])
            PI_HDR.clear(); PI_HDR.update(saved[1])
            FSW_ORDER[:] = saved[2]
            STATION_HEADERS.clear(); STATION_HEADERS.update(saved[3])
            RING_NET = ring_net_saved
            if mutate is _second_bond:
                holes["H3"][1].disconnect()
                holes["H3"][1] += Net("CHASSIS_H3")
            if mutate is _cap_backwards:
                _c30 = next(p for p in default_circuit.parts if p.ref == "C30")
                _c30[1].disconnect(); _c30[2].disconnect()
                _c30[1, 2] += v5, gnd
            if mutate is _clamp_reversed:
                d_clamp[1].disconnect(); d_clamp[2].disconnect()
                d_clamp[1, 2] += opto[1], opto[2]
            if mutate is _swd_swap:
                pico["D1"].disconnect(); pico["D3"].disconnect()
                pico["D1"] += swclk
                pico["D3"] += swdio
    return ok


if "--selftest" in sys.argv:
    print("Negative controls:")
    sys.exit(0 if _selftest() else 1)

print(report())
print("Board assertions ...", end=" ")
_check()
print("ALL PASS")

for _n in (gnd, v5, v3v3):
    _n.drive = POWER

ERC()
generate_netlist()
