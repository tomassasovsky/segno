"""SKiDL generator for the Segno pedal RING/ENCODER base board.

Hosts an off-the-shelf **24-LED WS2812 5050 NeoPixel ring module** (O65.5 OD /
O52.3 ID / 3.2 thick) plus the rotary encoder and the link to the main board.
Everything on this board is THROUGH-HOLE -- no SMD to hand-solder, and the LED
ring is a pre-assembled module, so there are no WS2812s on this PCB at all.

The board was a Ring 16 design until 2026-08-22 (#794). Fitting the Ring 24 took
three mechanical changes, all in segno_pedal_ring.kicad_pcb: the outline grew
O60 -> O68 (the ring is O65.5 and overhung a O60 board by 2.75 mm all round), the
three M3 holes moved from r=26 in to r=22 so their heads clear the ring's inner
edge at r=26.15, and RING1's documentation footprint became NeoPixel_Ring24.

Run (from hardware/kicad/):
    python ring_board.py     # KICAD_SYMBOL_DIR may override the symbol path
"""
import os

from skidl import (
    Part, Net, generate_netlist, ERC, POWER, set_default_tool, KICAD8,
    lib_search_paths,
)

set_default_tool(KICAD8)

_SYMBOL_DIRS = [
    os.environ.get("KICAD_SYMBOL_DIR", ""),
    r"C:\Program Files\KiCad\10.0\share\kicad\symbols",
    r"C:\Program Files\KiCad\9.0\share\kicad\symbols",
    "/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols",
    "/Applications/KiCad.app/Contents/SharedSupport/symbols",
    "/usr/share/kicad/symbols",
]
for _d in _SYMBOL_DIRS:
    if _d and os.path.isdir(_d):
        lib_search_paths[KICAD8].append(_d)

# ---- THT footprint helpers -------------------------------------------------

def R(value):
    return Part("Device", "R", value=value,
                footprint="Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal")


def C(value, fp="Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"):
    return Part("Device", "C", value=value, footprint=fp)


# ---- nets ------------------------------------------------------------------

gnd = Net("GND")
v5 = Net("+5V_LED")
ring_data = Net("RING_DATA")     # data from main board -> module DIN
ring_dout = Net("RING_DOUT")     # module DOUT (spare; for chaining a 2nd ring)
encA = Net("ENC_A")
encB = Net("ENC_B")
encSW = Net("ENC_SW")

# ---- 8-pin link to the main board (mirrors main board J6 RING header) -------
#   1,2 = +5V_LED   3,4 = GND   5 = RING_DATA   6 = ENC_A   7 = ENC_B   8 = ENC_SW
j1 = Part("Connector_Generic", "Conn_01x08",
          footprint="Connector_JST:JST_XH_B8B-XH-A_1x08_P2.50mm_Vertical", ref="J1")
j1[1, 2] += v5
j1[3, 4] += gnd
j1[5] += ring_data
j1[6] += encA
j1[7] += encB
j1[8] += encSW

# ---- 4-pin header to the NeoPixel module (3 wires used: 5V/GND/DIN) ---------
#   1 = +5V_LED   2 = GND   3 = DIN (<- RING_DATA)   4 = DOUT (spare)
j2 = Part("Connector_Generic", "Conn_01x04",
          footprint="segno:WirePads_1x04",   # flat FRONT solder pads (wires to module)
          ref="J2", value="NEOPIXEL")
j2[1] += v5
j2[2] += gnd
j2[3] += ring_data
j2[4] += ring_dout

# 4 distributed THT pads under the RING 16's In/+5V/GND/Out pads (Adafruit
# JP1/JP3/JP4/JP2), for pin-mounting that module instead of flying-wiring it.
#
# THESE DO NOT FIT THE RING 24. They sit on a O42.1 circle, which is inside the
# Ring 24's O52.3 bore -- the pads land in open air. Connect the Ring 24 through
# J2 instead (WirePads_1x04, same nets, three wires: 5V/GND/DIN). They are kept,
# not deleted, because they are on the right nets, cost nothing, still serve a
# Ring 16 build, and removing them would mean re-routing four nets for no
# functional gain. Giving the Ring 24 its own pad circle needs the four pad
# centres measured off the physical part -- see #794.
j3 = Part("Connector_Generic", "Conn_01x04",
          footprint="segno:ModuleMountPads_4", ref="J3", value="RINGPINS")
j3[1] += ring_data   # DIN
j3[2] += v5          # +5V
j3[3] += gnd         # GND
j3[4] += ring_dout   # DOUT (spare; soldered for mechanical support)

# bulk cap at the module power entry (24 LEDs, ~1.44 A all-white worst case; the
# comet only ever lights part of the ring, so the real draw is far lower) -- THT
# radial electrolytic.
# ESR grade in the VALUE because the value is what a BOM prints and the grade is
# load-bearing: a general-purpose 470uF in the same can runs ~0.5 ohm, and the
# ring's amp-scale frame edges x that ESR is real ripple on the LEDs' own VDD.
# Same rule as the console board's C30.
Part("Device", "C_Polarized", value="470uF 16V low-ESR <=0.15R",
     footprint="Capacitor_THT:CP_Radial_D8.0mm_P3.50mm")[1, 2] += v5, gnd

# ---- EC11 rotary encoder (A,B,C common, S1,S2 switch) ----------------------
enc = Part("Device", "RotaryEncoder_Switch",
           footprint="segno:RotaryEncoder_EC11",   # vendored EC11 (LCSC C202365) + 3D model
           ref="ENC1")
enc["A"] += encA
enc["B"] += encB
enc["C"] += gnd
enc["S1"] += encSW
enc["S2"] += gnd
# pull-ups + RC de-bounce (encoders bounce). Powered from +5V_LED, so the encoder
# is live only in standalone/9V mode -- same as the LED ring.
# NO pull-ups here. They used to be 10k to this board's 5 V rail, which was right
# when the cable's far end was main_board.py's 5 V Pro Micro and wrong the moment it
# became a 3.3 V Pico: they drove GP13/GP14 1.4 V past absolute maximum, continuously.
# The console board now pulls ENC_A/ENC_B/ENC_SW up to ITS OWN 3V3, so the pull-up
# always matches whatever MCU is actually on the other end.
C("100nF")[1, 2] += encA, gnd
C("100nF")[1, 2] += encB, gnd

for _n in (gnd, v5):
    _n.drive = POWER

ERC()
generate_netlist()
