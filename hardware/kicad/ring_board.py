"""SKiDL generator for the Segno pedal RING/ENCODER base board.

Hosts an off-the-shelf **24-LED WS2812 5050 NeoPixel ring module** (O65.5 OD /
O52.3 ID / 3.2 thick), the rotary encoder, and a **Seeed XIAO RP2350 module**
that owns both of them locally. The link back to the console board is **three
conductors** -- +5V, GND and one half-duplex data line.

## Why the MCU is here at all (#987)

It is not about part count, it is about cable length. The console board lives at
BOARD_U = 560 under the 16" screen; this board lives at COL_U = 119.6 on the
sloped faceplate (`segno_enclosure.py`). That is 440 mm in u alone -- call it
550-650 mm of harness once it climbs the face. The old design sent a 5 V WS2812
edge and a raw EC11 quadrature pair down that run, on eight conductors, through
a box carrying ~12 A across two switching bucks.

Now the WS2812 timing is generated 20 mm from the LEDs and the quadrature never
leaves this PCB. What crosses the box is one 115200-baud line with a 10 k
pull-up. The conductor count is a side effect:

    8 conductors  ->  3      (+5V, GND, RING_LINK)

## The console board is UNCHANGED (this is load-bearing)

No copper moves on console_board.py. Its J6 is still an 8-way JST-XH; this
board's J1 is a 3-way, and the cable is populated on three of the eight
positions. `RING_PINMAP` in console_board.py is the map, and RING_CONTRACT gates
it. The asymmetry that makes this work: J6 pin 5 (RING_DATA) is behind the
74AHCT125 with /OE tied low, so it can only ever be DRIVEN by the console --
useless as a link. Pins 6/7/8 are direct RP2350 GPIO (GP13/14/15) each with a
10 k pull-up to the console's own 3V3, which is exactly the network a half-
duplex open-drain line wants. The link takes pin 6; pins 5/7/8 and the console's
AHCT gate B are left in place, driving nothing.

## Levels: the historical fault is now structurally impossible

ring_board's old 10 k encoder pull-ups went to THIS board's 5 V rail while the
far end of the cable had become a 3.3 V RP2350 -- 1.4 V over GP13/GP14's
absolute maximum, continuously, and nothing caught it (see RING_LEVELS in
console_board.py). The pull-ups then moved to the console board so they would
track whatever MCU was really on the other end.

They come back here, because the MCU is now here: 10 k to the XIAO's own
3V3_OUT. The pull-up and the input it feeds are on the same board and the same
rail, so they cannot disagree. RING_LEVELS survives, re-pointed from the three
encoder pins to the one line that still crosses the cable into a Pico input.

**RP2350 erratum E9** (A2 silicon) latches an input HIGH when it is configured
with a PULL-DOWN. Nothing here uses one: the encoder lines are pulled UP (R1-R3
below), RING_LINK is pulled up by the console's existing 10 k, and the WS2812
line is an output. Do not add a pull-down to this board without re-reading E9.

## The board grew to O80 and the M3 holes moved inboard (owner call)

The O68 disc could not hold this. Its usable back is an ANNULUS -- r>~11 (clear
of the encoder body at the centre) out to the rim -- and the three M3 holes sat
at exactly **r=22**, in the middle of it, so every large part had to dodge them
angularly. The XIAO ended up **0.85 mm** from the encoder's courtyard with the
encoder's own traces squeezing through that gap.

Two changes fix it, both cheap:

- **Outline O68 -> O80.** The enclosure has far more room here than the ring
  window suggests: measured off `segno_enclosure.py`, the binding neighbour is
  the 7" screen's BEZEL at r=58.6 (so O117 would still fit), with the row-1
  pedal slots 60 mm clear the other way. O80 leaves ~18 mm of margin.
- **M3 holes r=22 -> r=16**, at theta 90/210/330. They were at r=22 only so the
  screw HEADS clear the ring's inner edge at r=26.15 -- moving them further IN
  satisfies that just as well, and the faceplate is solid metal at r=16 (the
  window is the r=25.75..33.5 annulus), so a standoff has something to land on.
  The new angles also dodge J2's wire pads (r~12.3, theta -108..-72), which the
  old -101/36/163 triangle sat on top of.

Nothing in the enclosure had to change: it models no bosses for this board, and
RING_OD/RING_ID (the faceplate window) are untouched -- the ring module and the
encoder bush still sit exactly where they did.

Result: an uninterrupted ~19 mm-wide annulus (r20..r39) all the way round, and
the XIAO now sits **4.4 mm** off the encoder instead of 0.85.

## Why the 5 V pins went from four to one

Four ways (two pairs) were sized for 24 LEDs x 60 mA = 1.44 A all-white. Over
~1.2 m of 26 AWG loop (~0.16 R) that is a 0.23 V drop on one pair, 0.12 V on
two. The firmware caps ring brightness well under all-white -- the comet only
ever lights part of the ring -- so one pair carries it with margin, and JST-XH
is rated ~3 A per contact either way. If a bench measurement of the CAPPED worst
case ever lands above ~0.7 A, the answer is a second pair (J6 pins 2/4 are still
there), not a thinner cap. GND sits BETWEEN +5V and RING_LINK on J1 so the
return is not the neighbour of the signal.

Everything on this board is a module or through-hole. The XIAO and the ring are
pre-assembled modules soldered down by their pads; nothing fine-pitch is
hand-placed.

Run (from hardware/kicad/):
    python ring_board.py     # KICAD_SYMBOL_DIR may override the symbol path
"""
import os
import sys

from skidl import (
    Part, Net, generate_netlist, ERC, POWER, set_default_tool, KICAD8,
    lib_search_paths,
)

set_default_tool(KICAD8)

from builtins import default_circuit          # noqa: E402  (set up by skidl)

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

# EVERY ref on this board is PINNED, none are left to SKiDL's auto-counter. The
# counter numbers parts in declaration order, so inserting one part renumbers
# every later one -- which silently re-points a layout that is already placed and
# routed against the old numbering. It already bit once here: the auto-numbered
# netlist called the 470uF "C2" while the fabbed board calls it C1.
# console_board.py's ref-block note is the same rule; its PIN_REFS gate is the
# same guard as REFS below.
# Horizontal axials, lying flat. They were briefly vertical (P2.54) to survive
# the O68 disc, which could not fit four flat DIN0207 bodies within reach of the
# pins they serve. O80 has the room, and flat parts are easier to place by hand
# and read on the silkscreen -- so they went back to the usual footprint.
def R(value, ref):
    return Part("Device", "R", value=value, ref=ref,
                footprint="Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal")


def C(value, ref, fp="Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"):
    return Part("Device", "C", value=value, ref=ref, footprint=fp)


# ---- nets ------------------------------------------------------------------

gnd = Net("GND")
v5 = Net("+5V_LED")      # harness 5 V -- feeds the ring DIRECTLY (no diode drop)
v5_mcu = Net("+5V_MCU")  # same rail through D1, into the XIAO's VBUS
v3v3 = Net("+3V3")       # the XIAO's own 3V3_OUT -- encoder pull-ups only
ring_link = Net("RING_LINK")     # half-duplex link to the console (its GP13)
ring_data_3v3 = Net("RING_DATA_3V3")  # XIAO -> level shifter
ring_data_5v = Net("RING_DATA_5V")    # level shifter -> series R
ring_data = Net("RING_DATA")     # -> module DIN
ring_dout = Net("RING_DOUT")     # module DOUT (spare; for chaining a 2nd ring)
encA = Net("ENC_A")      # LOCAL now -- these three never leave the board
encB = Net("ENC_B")
encSW = Net("ENC_SW")

# ---- 3-pin link to the console board ---------------------------------------
#   1 = +5V_LED   2 = GND   3 = RING_LINK
# Lands on console J6 pins 1, 3 and 6 -- see RING_PINMAP in console_board.py,
# which is the single copy of that mapping and the thing RING_CONTRACT checks.
# GND is deliberately the MIDDLE pin: the LED return is a pulsed amp-scale
# current and it should not run next to the one signal in the cable.
j1 = Part("Connector_Generic", "Conn_01x03",
          footprint="Connector_JST:JST_XH_B3B-XH-A_1x03_P2.50mm_Vertical", ref="J1")
j1[1] += v5
j1[2] += gnd
j1[3] += ring_link

# ---- U1: Seeed XIAO RP2350 --------------------------------------------------
# Modelled as the 30-pad module it is, exactly the way main_board.py modelled the
# Pro Micro: a Conn_01x30 over a vendored footprint, with the pad map stated
# here. The map is NOT guessed -- it is read from Seeed's own symbol library
# (Seeed_Studio_XIAO_Series.kicad_sym), the same source the footprint came from:
#
#   1..11 D0..D10   12 3V3_OUT  13 GND  14 VBUS
#   15..22 D11..D18 23 SWDIO 24 SWDCLK 25 EN 26 GND 27 BOOT 28 3V3_OUT
#   29 VBAT  30 GND
#
# Pads 1-14 are the two castellated SIDE rows (1..7 one side, 8..14 the other);
# 15-30 are UNDERSIDE pads and need copper keepout under the module even where
# unconnected.
#
# WHY RP2350 AND NOT RP2040: the console board is a Pico 2. Same architecture
# means one pico-sdk platform target, one PIO dialect and one erratum list across
# the whole product -- which is what #983 collapsed the firmware to. The RP2040
# XIAO's one advantage, a dedicated VIN pad for external supply, is cancelled by
# D1 below (needed on either part).
#
# PIN CHOICE IS A FLOORPLAN, same rule as console_board.py's. Everything the
# CABLE touches (VBUS, GND, RING_LINK) is on pads 11-14, one end of one side, so
# J1's three wires land together instead of crossing the module. The encoder and
# the LED line take the opposite row, facing the parts they drive.
#
# No hardware-UART constraint applies to RING_LINK: it is a single-wire
# half-duplex line and is a PIO UART at both ends, so the XIAO's D-number ->
# GP-number mapping does not bind the netlist. The firmware needs that mapping;
# the board does not.
XIAO = Part("Connector_Generic", "Conn_01x30",
            footprint="segno:XIAO_RP2350_SMD", ref="U1", value="XIAO-RP2350")
XIAO[1] += ring_data_3v3   # D0  -> level shifter in
XIAO[2] += encA            # D1
XIAO[3] += encB            # D2
XIAO[4] += encSW           # D3
XIAO[11] += ring_link      # D10 -> J1 pin 3
XIAO[12] += v3v3           # 3V3_OUT -- encoder pull-up rail, nothing else
XIAO[13] += gnd
XIAO[14] += v5_mcu         # VBUS, fed through D1
XIAO[26] += gnd            # underside GND pads: the return path for the module
XIAO[30] += gnd

# Spare pads, exempted BY NAME rather than tolerated in the ERC log -- a wall of
# expected warnings is how a real one gets missed (console_board.py's rule).
# SWDIO/SWDCLK/EN/BOOT (23/24/25/27) are deliberately among them: bench recovery
# is the module's own USB-C and its BOOT/RESET buttons, so bringing them out
# would be copper for a path nothing uses.
XIAO_SPARE = (5, 6, 7, 8, 9, 10,            # D4..D9
              15, 16, 17, 18, 19, 20, 21, 22,   # D11..D18
              23, 24, 25, 27, 28, 29)           # SWDIO SWDCLK EN BOOT 3V3 VBAT
for _p in XIAO_SPARE:
    XIAO[_p].do_erc = False

# ---- D1: series Schottky into the module's VBUS -----------------------------
# The XIAO's 5 V pad IS its USB VBUS rail. Plug USB in on the bench while the
# harness is live and two 5 V sources fight; a series Schottky makes the harness
# feed strictly one-way and costs ~0.35 V, leaving the module's LDO ~4.65 V --
# far above what it needs for 3V3.
# It sits ONLY in the module's feed. The WS2812 ring taps v5 ahead of it, because
# a diode drop on the LED rail is what raises the WS2812's own VIH threshold and
# it is already the tight number (see U2).
d1 = Part("Device", "D_Schottky", value="1N5819",
          footprint="Diode_THT:D_DO-41_SOD81_P10.16mm_Horizontal", ref="D1")
d1["A"] += v5
d1["K"] += v5_mcu

# ---- U2: 74AHCT125 -- the 3V3 -> 5 V crossing the WS2812 needs ---------------
# WS2812B wants VIH >= 0.7 x VDD = 3.5 V on a 5 V rail; the RP2350 drives 3.3 V.
# That gap is why the console board carries an AHCT125, and the same part answers
# it here -- SAME part number as console_board.py's U1, so the BOM does not grow
# a second logic family. Dropping the LED rail with a diode instead was the
# alternative and is rejected: at 1.44 A it burns over a watt in a DO-201 and
# leaves ~0.3 V of margin, against a part already proven on the other board.
# Only gate A is used. The other three are parked the way console_board.py parks
# its spare gate: /OE high, input low, output ERC-exempt.
buf = Part("74xx", "74AHCT125", value="74AHCT125N",
           footprint="Package_DIP:DIP-14_W7.62mm", ref="U2")
buf[14] += v5
buf[7] += gnd
C("100nF", "C5")[1, 2] += v5, gnd
buf[1] += gnd; buf[2] += ring_data_3v3; buf[3] += ring_data_5v   # gate A: ring
buf[4] += v5; buf[5] += gnd; buf[6].do_erc = False               # gate B unused
buf[10] += v5; buf[9] += gnd; buf[8].do_erc = False              # gate C unused
buf[13] += v5; buf[12] += gnd; buf[11].do_erc = False            # gate D unused
R("330", "R1")[1, 2] += ring_data_5v, ring_data

# ---- 4-pin header to the NeoPixel module (3 wires used: 5V/GND/DIN) ---------
#   1 = +5V_LED   2 = GND   3 = DIN (<- RING_DATA)   4 = DOUT (spare)
j2 = Part("Connector_Generic", "Conn_01x04",
          footprint="segno:WirePads_1x04",   # flat FRONT solder pads (wires to module)
          ref="J2", value="NEOPIXEL")
j2[1] += v5
j2[2] += gnd
j2[3] += ring_data
j2[4] += ring_dout

# 4 distributed THT pads directly under the RING 24's IN/+5V/GND/OUT solder
# points, so the module can be pin-mounted instead of flying-wired (parallel to
# J2 -- same nets, either method works).
#
# The coordinates are NOT eyeballed and not measured off a photo: they are lifted
# from Adafruit's own board file for the part -- github.com/adafruit/
# Adafruit-NeoPixel-Ring, "Adafruit NeoPixel Ring 24 B.brd" -- with Y negated for
# KiCad's downward Y. The signal per pad is read from that file's netlist too
# (JP1=IN via R1, JP2=OUT off LED24's DOUT, JP3=VDD, JP4=GND), because JP
# numbering is not a signal order and must not be assumed to carry across ring
# sizes. The same extraction reproduces the OLD ModuleMountPads_4's Ring 16 pads
# exactly, which is how the method was checked before trusting it here.
#
# That file also confirms the ring is O65.53 / O52.32 -- the fitted part.
j3 = Part("Connector_Generic", "Conn_01x04",
          footprint="segno:ModuleMountPads_Ring24", ref="J3", value="RINGPINS24")
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
Part("Device", "C_Polarized", value="470uF 16V low-ESR <=0.15R", ref="C1",
     footprint="Capacitor_THT:CP_Radial_D8.0mm_P3.50mm")[1, 2] += v5, gnd

# ---- EC11 rotary encoder (A,B,C common, S1,S2 switch) ----------------------
# Now a purely LOCAL circuit: 20 mm of trace to U1 instead of ~600 mm of harness.
enc = Part("Device", "RotaryEncoder_Switch",
           footprint="segno:RotaryEncoder_EC11",   # vendored EC11 (LCSC C202365) + 3D model
           ref="ENC1")
enc["A"] += encA
enc["B"] += encB
enc["C"] += gnd
enc["S1"] += encSW
enc["S2"] += gnd

# 10k to the XIAO's OWN 3V3_OUT, plus 100nF: RC = 1 ms, which is the timing the
# board has always had and which an EC11 needs. The RP2350's INTERNAL pull-ups
# are deliberately NOT used here, unlike console_board.py's footswitches: those
# are ~50-80k, which against 100nF is a 5-8 ms release edge. A stomp tolerates
# that; quadrature does not -- a fast spin puts edges ~25 ms apart and 8 ms of
# smear loses detents and direction.
R("10k", "R2")[1, 2] += v3v3, encA
R("10k", "R3")[1, 2] += v3v3, encB
R("10k", "R4")[1, 2] += v3v3, encSW
C("100nF", "C2")[1, 2] += encA, gnd
C("100nF", "C3")[1, 2] += encB, gnd
C("100nF", "C4")[1, 2] += encSW, gnd

# NOTE: RING_LINK gets NO pull-up on this board. The console's existing 10k to
# ITS 3V3 (console_board.py, the old ENC_A pull-up) is the one the open-drain
# line needs; a second one here would halve it to 5k and, being on a different
# board's rail, would re-create exactly the split-rail hazard RING_LEVELS exists
# to catch. There is no series resistor either -- the two boards share one supply
# through this cable, so there is no cross-domain window like the Pi link's.

# ---- gates -----------------------------------------------------------------
# This board grew an MCU, so it inherits the obligation that came with the one on
# the console board. RING_LEVELS (in console_board.py) reads this netlist, but it
# only ever looks at conductors that CROSS THE CABLE -- by construction it cannot
# see a 5 V part landing on a pin that never leaves this PCB. That is the same
# blind spot CONSOLE_LEVELS was written to close on the other board, and the
# encoder lines moved into it the moment they became local. Hence XIAO_LEVELS.

# Which pads are 3.3 V logic and which are power. Taken from the same Seeed symbol
# the footprint's descr quotes, not inferred: a pad's tolerance is the whole
# question here, so guessing it would defeat the gate.
XIAO_LOGIC_PADS = (frozenset(range(1, 12))        # D0..D10
                   | frozenset(range(15, 23))     # D11..D18
                   | frozenset({23, 24, 25, 27}))  # SWDIO SWDCLK EN BOOT
XIAO_POWER_PADS = {12: "3V3_OUT", 13: "GND", 14: "VBUS",
                   26: "GND", 28: "3V3_OUT", 29: "VBAT", 30: "GND"}
RAILS_5V = ("+5V_LED", "+5V_MCU")


def _check():
    # XIAO_PADS: the ERC exemptions must not cover a pad that is actually in use.
    # console_board.py's rule, for the same reason -- an exemption on a live pin
    # hides a real unconnected-pin warning, and this module has 20 exempt pads to
    # hide one behind.
    assert XIAO_LOGIC_PADS.isdisjoint(XIAO_POWER_PADS), (
        "XIAO_PADS: a pad is listed as both logic and power")
    assert set(XIAO_LOGIC_PADS) | set(XIAO_POWER_PADS) == set(range(1, 31)), (
        "XIAO_PADS: the logic/power split does not cover pads 1..30 -- the map "
        "has drifted from the footprint's 30 pads")
    _used = {p for p in range(1, 31) if XIAO[p].nets}
    assert _used.isdisjoint(XIAO_SPARE), (
        f"XIAO_PADS: {sorted(_used & set(XIAO_SPARE))} are ERC-exempt but wired -- "
        "an exemption on a live pad hides a real unconnected-pin warning")

    # XIAO_LEVELS: nothing may bridge a 5 V rail to a 3.3 V pad of the module.
    # Same classification-free rule as the console board's: any TWO-PIN part
    # delivers the rail's DC whatever it calls itself, and the pin-count
    # arithmetic exempts the module, the encoder and the AHCT125 without naming
    # them. D1 is NOT exempted by name either -- it passes because its far end is
    # VBUS (pad 14), a power pad, which is the only reason a 5 V part may touch
    # this module at all.
    _protected = set()
    for _pad in XIAO_LOGIC_PADS:
        _protected |= {n.name for n in XIAO[_pad].nets}
    for _p in default_circuit.parts:
        if len(_p.pins) > 2:
            continue
        _touch = {n.name for _pin in _p.pins for n in _pin.nets}
        assert not (_touch & set(RAILS_5V) and _touch & _protected), (
            f"XIAO_LEVELS: {_p.ref} bridges a 5 V rail to "
            f"{sorted(_touch & _protected)} -- the XIAO's logic pads are RP2350 "
            "pins with a 3.6 V absolute maximum, and this is the exact shape that "
            "shipped on this board once already (10k to 5 V on an encoder line)")

    # LINK_BARE: RING_LINK carries the console's 10k pull-up and must meet nothing
    # else here. A second pull-up on THIS board's rail would halve it to 5k and
    # re-import the split-rail hazard; a series R would be the Pi link's problem
    # (cross-domain powering), which this cable does not have -- both boards come
    # up and go down on one supply through it.
    _link_nodes = {(p.ref, str(pin.num)) for p in default_circuit.parts
                   for pin in p.pins if "RING_LINK" in {n.name for n in pin.nets}}
    assert _link_nodes == {("J1", "3"), ("U1", "11")}, (
        f"LINK_BARE: RING_LINK touches {sorted(_link_nodes)}, expected exactly "
        "J1.3 and U1.11 -- the pull-up this line runs on lives on the console "
        "board, at the rail its GP13 belongs to")

    # POLARITY: two parts on this board are directional and fitting either one
    # backwards is silent at assembly. Same gate the console board runs on C30.
    _d1 = next(p for p in default_circuit.parts if p.ref == "D1")
    assert {n.name for n in _d1["A"].nets} == {"+5V_LED"}, (
        f"POLARITY: D1's anode is on {sorted(n.name for n in _d1['A'].nets)}, "
        "expected the harness rail -- reversed, the module never powers up")
    assert {n.name for n in _d1["K"].nets} == {"+5V_MCU"}, (
        f"POLARITY: D1's cathode is on {sorted(n.name for n in _d1['K'].nets)}, "
        "expected the module rail")
    _pol = [p for p in default_circuit.parts if p.name == "C_Polarized"]
    assert len(_pol) == 1, f"POLARITY: expected 1 electrolytic, found {len(_pol)}"
    assert {n.name for n in _pol[0][1].nets} & set(RAILS_5V), (
        f"POLARITY: the electrolytic's pin 1 (+) is on "
        f"{sorted(n.name for n in _pol[0][1].nets)}, not a 5 V rail")
    assert {n.name for n in _pol[0][2].nets} == {"GND"}, (
        f"POLARITY: the electrolytic's pin 2 (-) is on "
        f"{sorted(n.name for n in _pol[0][2].nets)}, expected GND")

    # REFS runs LAST on purpose. It is the broadest assertion here, so ahead of
    # the others it fires first for every control that adds a part and masks the
    # gate that control exists to prove -- --selftest reported exactly that
    # ("WRONG GATE") the first time it sat at the top.
    # REFS: the exact set, so nothing here is auto-numbered. A part added without
    # a ref would be silently numbered by the counter and could take a designator
    # the fabbed board has already assigned to something else -- which is the
    # failure that made pinning them worth doing (the 470uF was C1 in copper and
    # C2 in the netlist). Parts with no connections are skipped: --selftest's
    # controls are disconnected rather than deleted, and they are not the design.
    REFS = {"C1", "C2", "C3", "C4", "C5", "D1", "ENC1",
            "J1", "J2", "J3", "R1", "R2", "R3", "R4", "U1", "U2"}
    _live = {p.ref for p in default_circuit.parts
             if any(pin.nets for pin in p.pins)}
    assert _live == REFS, (
        f"REFS: the board's parts are {sorted(_live)}, expected {sorted(REFS)} -- "
        f"missing {sorted(REFS - _live)}, unexpected {sorted(_live - REFS)}. Every "
        "ref on this board is pinned so the counter cannot renumber a placed "
        "layout; a part declared without ref= breaks that.")


def _selftest():
    """Each gate above, proved to bite. A gate nobody has seen fail is a gate that
    might already be dead -- which is precisely how RING_LEVELS on the other board
    spent months asserting a literal list against itself."""
    added = []

    def _pullup_5v():
        # The shipped mistake, replayed on the pads it can still reach.
        r = R("10k", "R99"); r[1, 2] += v5, encA; added.append(r)

    def _link_pullup():
        # Reasonable-looking and wrong: "make the link idle high locally".
        r = R("10k", "R98"); r[1, 2] += v3v3, ring_link; added.append(r)

    def _diode_backwards():
        d = next(p for p in default_circuit.parts if p.ref == "D1")
        d["A"].disconnect(); d["K"].disconnect()
        d["A"] += v5_mcu; d["K"] += v5

    def _exempt_live_pad():
        XIAO[5] += encA          # a spare, ERC-exempt pad quietly wired

    def _unpinned_part():
        # A part added the easy way, without ref= -- the counter names it and the
        # name it picks may already be on the fabbed board.
        r = Part("Device", "R", value="10k",
                 footprint="Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm"
                           "_P10.16mm_Horizontal")
        r[1, 2] += v3v3, gnd
        added.append(r)

    def _undo():
        for r in added:
            for pin in r.pins:
                pin.disconnect()
        added.clear()
        d = next((p for p in default_circuit.parts if p.ref == "D1"), None)
        if d is not None and {n.name for n in d["A"].nets} != {"+5V_LED"}:
            d["A"].disconnect(); d["K"].disconnect()
            d["A"] += v5; d["K"] += v5_mcu
        if XIAO[5].nets:
            XIAO[5].disconnect()

    cases = [
        ("ring board pulls a XIAO logic pad to 5 V", "XIAO_LEVELS:", _pullup_5v),
        ("a second pull-up added to the link",       "LINK_BARE:",   _link_pullup),
        ("series Schottky fitted backwards",         "POLARITY:",    _diode_backwards),
        ("an ERC-exempt pad quietly wired",          "XIAO_PADS:",   _exempt_live_pad),
        ("a part declared without a pinned ref",      "REFS:",        _unpinned_part),
    ]
    ok = True
    for name, want, mutate in cases:
        try:
            mutate()
            _check()
        except AssertionError as e:
            got = str(e).split("\n")[0]
            # A control that trips some OTHER gate proves nothing about its own and
            # would read as a pass -- console_board.py learned this the hard way,
            # so the expected prefix is checked, not merely "it raised".
            hit = got.startswith(want)
            print(f"  {'bites' if hit else 'WRONG GATE':<10} {name:<42} {got[:68]}")
            ok &= hit
        except Exception as e:                       # noqa: BLE001
            print(f"  {'ERROR':<10} {name:<42} {type(e).__name__}: {e}")
            ok = False
        else:
            print(f"  {'NO BITE':<10} {name:<42} (the gate is dead)")
            ok = False
        finally:
            _undo()
    # ...and the real design must still pass once every control is undone, or the
    # cleanup is what made the run green rather than the gates.
    _check()
    return ok


if "--selftest" in sys.argv:
    print("Negative controls:")
    sys.exit(0 if _selftest() else 1)

print("Board assertions ...", end=" ")
_check()
print("ALL PASS")

for _n in (gnd, v5, v5_mcu, v3v3):
    _n.drive = POWER

ERC()
generate_netlist()
