"""pcbnew layout generator for the Segno CONSOLE board v3 (issue #747; v3: #987 ring link, CTRL ring sense).

Consumes `console_board.net` -- the SKiDL netlist is the single source of truth for
what connects to what -- and emits a placed, routed, poured, DRC-clean board plus a
JLCPCB-ready gerber zip.

Run (from hardware/kicad/, with KiCad's own Python, which is the one that has pcbnew):
    /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 console_board_pcb.py

Modelled on hardware/led_strip/ledstrip_pcb.py, which already does the
place -> pour -> DRC -> kicad-cli -> zip pipeline for the LED strip.

PLACEMENT DRIVES ROUTING
------------------------
No autorouter. The board is laid out so routing is nearly trivial: every connector
sits in the SAME left-to-right order as the Pico pads it serves, so each fan-out
diverges without crossing and routes on one layer. Ordering is a gate, not a hope --
_check() proves no signal net has to cross another before a single track is drawn.

GND is not routed at all: it is a pour on both layers, and every GND pad gets its
own via BESIDE it -- never on it, since a via on a plated hole is a second drill hit
at the same coordinate and a via in an SMD pad starves the joint.
"""
import json
import math
import os
import shutil
import subprocess
import sys

import pcbnew

from netlist import parse_netlist

FromMM, ToMM = pcbnew.FromMM, pcbnew.ToMM
HERE = os.path.dirname(os.path.abspath(__file__))
NETLIST = os.path.join(HERE, "console_board.net")
OUT = os.path.join(HERE, "out_console")
BOARD_PATH = os.path.join(OUT, "segno_console_board.kicad_pcb")   # ROUTED: the
# deliverable, written only by the routing pipeline. build() does NOT touch it --
# it writes PLACED_PATH, and route_console_board.sh copies that over BOARD_PATH
# before importing the session. Placement used to write the deliverable directly,
# so running the generator on its own quietly replaced a routed, DRC-clean board
# with an unrouted one, and the next thing to read it (a fab check, a commit) was
# looking at a different board than the one that passed.
PLACED_PATH = os.path.join(OUT, "console.placed.kicad_pcb")       # PLACED only
KICAD_CLI = "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
KICAD_FP = "/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints"
LOCAL_FP = os.path.join(HERE, "segno.pretty")

ORIGIN = (100.0, 60.0)          # board origin on the KiCad page
# 99.5 square, and the number is the whole point: every prototype fab prices
# 2-layer boards in a cheap tier that stops at 100 x 100 mm, and 115 mm of width was
# over it for no structural reason -- the enclosure bay is 342 x 193, so nothing
# mechanical wanted those 15 mm.
#
# 99.5 rather than 100.0 because Edge.Cuts is drawn with a 0.1 mm line, so a 100.0
# outline measures 100.1 across the OUTSIDE of it. Most fabs quote from the line
# centre and would not care; the half millimetre costs nothing here and means no
# CAM operator has to make that call on our behalf.
#
# The width is now set by ONE thing: the footswitch row. Ten JST XH at an 8.5 mm
# courtyard plus the 0.8 mm keepout is 92.2 mm of the 100, which is why the pitch
# below is at its floor and why the row is the first thing to check if this board
# ever has to get smaller again. (It cannot, without giving up one connector per
# pedal.) Everything else fits inside that with room: the widest other row is
# J3 + the module + U1 + the ribbon, at 80.5 mm.
BW, BH = 99.5, 99.5             # see FLOORPLAN below
EDGE_R = 3.0                    # corner radius
MOUNT_INSET = 5.0               # mounting-hole centres, in from each corner.
# The holes are NOT synthesised here any more: H1..H4 come out of the netlist like
# every other part, because one of them carries GND. A chassis bond is a connection,
# so it belongs in the netlist, and placing them from PLACEMENT below means the
# auto-placer sees them before it looks for slots -- which is what stopped a passive
# landing on H2 back when they were added afterwards.

# Widths per the pcb-layout skill (IPC-2152 rule of thumb): ~1.0 mm for
# power/ground, ~0.6 mm for signal. The first cut used 0.35/0.8, which is
# under-sized on both counts -- the +5V rail feeds 22 WS2812s as well as logic.
# ONE width, 0.6 mm, and it is what the board actually gets: Freerouting takes the
# width from the DSN netclass, so this constant only reaches copper via the GND
# stubs. There used to be a TRACK_PWR = 1.0 beside it "for +5V/+3V3" -- it was read
# by _route(), the straight-line router that was retired when Freerouting took over,
# so the rails have been 0.6 mm all along while a constant said otherwise.
#
# 0.6 mm is the right answer anyway, and this is the arithmetic rather than a shrug.
# Worst case on +5V is 26 WS2812s flat out (16 ring + 10 indicators) at 60 mA =
# 1.56 A, plus ~60 mA of Pico and AHCT logic. IPC-2152 gives a 0.6 mm external trace
# in 1 oz copper about 2 A for a 10 degC rise, so the margin is ~20%, and the IR drop
# over the ~60 mm from J3 to J6/J7 is 1.6 A x 0.049 ohm = 81 mV -- a WS2812 chain
# entering at 4.92 V. Verified after routing by MIN_PWR_TRACK_W in export().
TRACK_W = 0.6                   # every routed track, signal and rail alike
VIA_D, VIA_DRILL = 0.8, 0.4
CLEARANCE = 0.25

# Silkscreen, as the FAB sees it. JLCPCB will not print a line thinner than
# 0.15 mm or text shorter than 0.8 mm -- below that it thins, breaks, or is dropped
# outright, and you find out when the boards arrive. KiCad's own defaults are looser
# (m_MinSilkTextThickness is 0.08), so its DRC is no help here and _check() carries
# the rule instead.
#
# The stroke is h/5, not the h/6 this used: at h/6 every one of the 58 reference
# designators came out at 0.133 mm, i.e. under the floor, on a board that had
# otherwise passed every check we had.
FAB_MIN_SILK_STROKE = 0.15
FAB_MIN_SILK_HEIGHT = 0.8
SILK_STROKE_RATIO = 1.0 / 5.0

# How the ground pours meet a pad. THERMAL, for the reason spelled out in
# _pour_gnd(); it is a named constant so --selftest can put it back to FULL and
# prove the gate that forbids that still bites.
PAD_CONNECTION = pcbnew.ZONE_CONNECTION_THERMAL

# MIDI IN's opto barrier: the DIN side of U2 must not share copper or a pour with
# anything else, or the isolation the H11L1 exists for is undone.
ISOLATION_GAP = 2.0


def P(x, y):
    return pcbnew.VECTOR2I(FromMM(ORIGIN[0] + x), FromMM(ORIGIN[1] + y))


# ---- FLOORPLAN --------------------------------------------------------------
# Two rules decide this layout, and neither is "make it look tidy".
#
# 1. THE PIN MAP IS HALF THE FLOORPLAN. The module's pads 1..20 are one physical
#    row and 21..40 the other, so console_board.py's GPIO choice decides which side
#    of the module a connector can sit on. Row B (up) carries CTRL, LINK, IND and
#    the expansion pins; row A (down) carries the ten footswitches and the ring.
#
# 2. CONNECTORS ARE GROUPED BY WHERE THEIR CABLE GOES, not by what they do
#    electrically. Five headers -- POWER, MIDI IN, MIDI OUT, CTRL 1, CTRL 2 -- all
#    terminate on the rear panel, so they sit together along the top edge IN THE
#    PANEL'S OWN LEFT-TO-RIGHT ORDER (gated below against rear_io_stations.json).
#    One harness, one edge, no crossings. Before this they were split between the
#    top band and the right column, so the rear-panel loom left the board twice.
#
#   y  8   J8 PWR  J5 MIDI-IN  J4 MIDI-OUT  J20 CTRL1  J21 CTRL2
#   y 14   D1, in the opto pocket between J5 and U2 -- it clamps U2's LED
#   y 21   (the rest of their passives; J22 EXP beside U2). Shoulder to shoulder at
#          99.5 mm wide: R5, R10 and D1 are all hand-placed, because the spiral
#          cannot find 12.3 mm of axial anywhere in range once the band is this full
#   y 46   J3 | [======== PICO (rot 90) ========]  U1  | J2 (Pi ribbon, right edge,
#   y 63                R11 R12 R13 R1        R2 (upright)  and 59.5 mm of it)
#   y 69                J6 RING      J7 LEDS
#   y 75   [=========== debounce caps ===========]  (kept HIGH: they are the middle
#          hop of every switch net, and pushing them down with the headers below put
#          SW_BANK over the 42 mm hop limit exactly)
#   y 85   [======== ten footswitch headers ======]
#   y 95   title block, between the two bottom mounting holes
REAR_PANEL_ORDER = ["J8", "J5", "J4", "J20", "J21"]   # = the panel's own order

PICO_X, PICO_Y = 43.0, 46.0
PLACEMENT = {
    "J1":  (PICO_X, PICO_Y, 90),   # Pico 2, rot 90 so the pad rows lie horizontal.
                                   # x 43 is pinned from the RIGHT, not chosen: U1 is
                                   # 9.8 mm wide and has to fit between this module
                                   # and the ribbon's 10 mm column, which leaves the
                                   # module's right edge at 70. That costs SW_BANK
                                   # its margin -- 40.7 mm of the 42 mm hop limit --
                                   # and it is the tightest number on the board.
                                   # Its USB end points LEFT and nothing is reserved
                                   # for a cable: VSYS takes +5V from J3, the Pi
                                   # flashes it cold over SWD (J9), and control is
                                   # the UART on GP16/17. USB is bench-only.

    # top edge: the rear-panel loom, in the panel's order, on an even 16 mm pitch.
    # The row stops at x 83.5 rather than running to the edge: the ribbon's column
    # starts at 84.5 and comes up to y 10.2, so the last two headers would sit on
    # top of it. The corner mounting holes cap the other end the same way.
    "J8":  (18.1, 8.0, 0),
    "J23": (16.5, 69.0, 0),        # I2C to the PD trigger, under the module's
                                   # left end between 5V IN and EXP: GP0/GP1 are
                                   # pads 1/2, a 12 mm hop up. (The pocket beside
                                   # C30 is the USB-C cable corridor -- USB_CLEAR.)
    "J9":  (23.1, 30.0, 0),        # flying lead to the Pi 5's own J2 button pads
                                   # (NOT a header pin -- no GPIO wakes a Pi 5;
                                   # see PWR_BTN in console_board.py)
    "J5":  (34.0, 8.0, 0),         # MIDI IN  -- 2 leads: DIN pins 4 and 5 only.
                                   # Pin 2 is left OFF at a receiver by MIDI 1.0;
                                   # bonding the shield here would short out the
                                   # isolation U2 exists to provide.
    "J4":  (50.0, 8.0, 0),         # MIDI OUT -- 3 leads: DIN pins 4, 5 and 2.
    # 4-way since v3 (tip, ring, sleeve, tip-normal for presence): 2.5 mm
    # wider each, so the pair slides left to keep 0.8 mm to MIDI OUT on one
    # side and to the ribbon's column on the other.
    "J20": (63.4, 8.0, 0),         # CTRL 1, over GP26 = pad 31
    "J21": (77.7, 8.0, 0),         # CTRL 2, over GP27 = pad 32
    "U2":  (34.0, 21.0, 0),        # H11L1, directly under its own jack, in its own
                                   # ISOLATION_GAP pocket

    # CTRL divider + anti-alias, hand-placed under their own two jacks. All five
    # anchor within a few mm of each other, so the spiral packs the first ones in
    # and leaves the last with no legal slot -- and these are signal-path parts, so
    # they should hug the pins they serve rather than land wherever there is room.
    "R8":  (63.0, 16.0, 0), "R7": (77.0, 16.0, 0),
    # The two MIDI OUT series resistors, likewise by hand. R3 spans U1's gate-C
    # output to the jack -- a 46 mm reach -- so anchored to either end it is 48 mm
    # from the other. A series part belongs BETWEEN its endpoints, not beside one.
    "R3":  (66.9, 31.0, 0), "R4": (50.0, 16.0, 0),
    "R6":  (71.4, 25.0, 0),
    "C13": (55.9, 21.0, 0), "C14": (66.0, 21.0, 0), "R9": (76.9, 21.0, 0),
    # R10 and R5 are hand-placed for the same reason the rest of this band is: at
    # 100 mm wide the band is full, and the spiral cannot find 12.3 mm of axial
    # anywhere within its search radius. They are the two MIDI IN parts, so they
    # belong beside U2 and its jack rather than wherever a gap happened to be.
    "R10": (57.0, 27.0, 0), "R5": (35.0, 29.5, 0),
    # D1 clamps the opto's LED, so it is a MIDI IN part and belongs in the pocket
    # with U2, R5 and J5 -- between the DIN jack and the opto. Left to the spiral it
    # landed 15 mm away, straight across the only lane from J8 down to J9, and the
    # router could not get PWR_BTN through at all. The isolation gate could not
    # object: D1 shares the DIN-side nets, so it is exempt by construction.
    "D1":  (34.0, 14.4, 0),

    # left edge: power in and its reservoir
    "J3":  (5.5, 62.0, 90),       # 5 V in, beside VBUS/VSYS (pads 40/39)
    "C31": (6.7, 20.0, 0),        # 100uF  on +5V
    "C30": (6.7, 33.0, 0),        # 470uF bulk on +5V (the WS2812 reservoir)

    # right: the buffer, then the ribbon on the edge itself
    "U1":  (76.0, 44.0, 0),        # 74AHCT125, sat LOW on purpose. Its ring input is
                                   # pin 5; RING_DATA comes off the module's row A
                                   # (the bottom row), so with U1 up at y 34 that one
                                   # net had to climb 18 mm THROUGH the link / IND /
                                   # EXP / CTRL bundle that crosses the same gap, and
                                   # it was the only net that would never route. At
                                   # y 44 pin 5 comes down to meet it. Pin 2 (IND,
                                   # from row B) is still within 2 mm of its own row.
    "J2":  (89.5, 42.0, 180),      # Pi ribbon, ON THE EDGE, and rotated 180 so its
                                   # PIN 1 is at the FRONT end (-v in the enclosure).
                                   # The Pi's header has pin 1 at its SD-card end,
                                   # which the enclosure puts at -v as well: two
                                   # vertical headers facing each other across a gap
                                   # need pin 1 at the SAME end, or the ribbon has to
                                   # fold back on itself to mate -- and that fold is
                                   # what drapes it over the Pi's cooler intake.
                                   # A 40-way ribbon leaving
                                   # mid-board folds straight back over everything;
                                   # here the cable clears the board immediately.
    "J22": (46.3, 26.0, 0),        # expansion, 2x4: GP12/15/19/22/28 since v3
                                   # (GP20/21 became the ring senses). Where it
                                   # was on v2 -- the bench preferred it here.
                                   # Not on the top edge: its GP28 pin is pad 34,
                                   # near the module's LEFT end, while GP19/22
                                   # are pads 25/29 toward the right -- from the
                                   # top-right corner that ADC lead ran 61 mm.
                                   # Sat here it reaches both ends of its span.

    # under the module: series resistors, then the ring/LED pair
    # Both series resistors stand UPRIGHT in the channel beside U1 rather than lying
    # under the module. Laid out flat at y 61 the gate-B output had a 38 mm reach
    # across the busiest corner of the board and would not route at all. R1 sits
    # BELOW the corridor, not in it: at y 51 it plugged the very channel RING_DATA
    # needs to reach U1, and simply moved which of the two nets failed.
    # The right column, stacked so nothing sits in the RING_DATA corridor
    # (x 80.5..88): left to the spiral, C11 lands against the opto and R2 lands in
    # the corridor, and the one net that has to climb from row A to U1's input has
    # nowhere to go.
    "C11": (80.0, 31.0, 0),        # +5V decoupling for U1
    "C20": (24.0, 21.0, 0),        # +3V3 decoupling for U2
    # The ring link's two pull-ups, on this board's 3V3 (they used to live on
    # ring_board.py tied to its 5 V rail, 1.4 V over the RP2350's absolute
    # maximum). R13, R1 and R15 -- the third pull-up, the ring-data series part
    # and its pull-down -- retired with the ring-data path in v3 (#987); their
    # slots stay open and their designators stay unused.
    # On the slim band under the module's row A with R20/R16 (they were at
    # y 63): the row below is then R21/R22's and the row below that J23's.
    "R11": (19.4, 59.6, 0), "R12": (32.2, 59.6, 0),
    # The CTRL rings' sense resistors (v3), in the row R13 and R15 left empty
    # when the ring-data path went. 50-60 mm from the jacks they serve, and
    # exempt from the hop gate for it (SLOW_SENSE_NETS); the column beside U2
    # that would have put them under the jacks is the expansion header's.
    "R19": (45.0, 63.0, 0), "R20": (48.0, 59.6, 0),
    # The presence series parts (v3, switched jacks), same reasoning and the
    # same exemption: the row under R11/R12, left of R19.
    "R21": (17.0, 63.0, 0), "R22": (30.0, 63.0, 0),
    "R2":  (79.5, 63.0, 90),        # 330R, U1 gate A -> J7 pin 2 (indicators)

    # The five review-fix resistors. ALL hand-placed: the passive bands were
    # already at capacity (R5/R10/D1 above went by hand for the same reason) and
    # the spiral found no slot for the first of these it tried. Slot geography,
    # learned the expensive way: the SE field sits under the footswitch labels'
    # fixed row at y 80.1, which prints across anything parked there (the row is
    # a placement keepout in build() now, so the spiral at least knows); the
    # U1-south pocket must keep its x 69..73 column open or the search-placed
    # 'LEDS' label loses the one window it can print in (above J7, reached at
    # d~5.5); and the channel east of the ribbon fits three uprights, of which
    # R14 and R17 stand there today. Assignment is by spur cost -- each part
    # sits nearest its OWN net, because the RATSNEST budget below counts every
    # millimetre of these.
    "R14": (96.9, 59.85, 90),      # 100k midi_tx pull-DOWN, upright east of the
                                   # ribbon, level with J2 pin 8: 11 mm from it;
                                   # the GND leg lands in the pour
    "R17": (96.9, 45.0, 90),       # 10k link_tx series, upright east of the
                                   # ribbon: 11 mm from J2 pin 21, 29 mm from
                                   # the Pico's GP16 pad
    "R18": (71.6, 63.0, 0),        # 10k link_rx series, flat in the R12..R2 slot;
                                   # both legs within 28 mm
    "R16": (61.5, 59.6, 0),        # 100k ind_data pulldown, in the slim band
                                   # the same band: 22 mm from U1 pin 2; its GND
                                   # leg lands in the pour
    "J6":  (52.5, 69.0, 0),        # ring link (4-way since v3), under pads 19/20
    "J7":  (71.0, 69.0, 0),        # indicators -- x matches J9 above

    # The four M3 holes, one per corner. H1 is the chassis bond (see console_board.py):
    # top-left, the corner nearest the rear-panel loom and diagonally away from the
    # ribbon, so an ESD strike on a footswitch lead reaches the case rather than
    # travelling the 40-way into the Pi.
    "H1":  (MOUNT_INSET, MOUNT_INSET, 0),
    "H2":  (BW - MOUNT_INSET, MOUNT_INSET, 0),
    "H3":  (BW - MOUNT_INSET, BH - MOUNT_INSET, 0),
    "H4":  (MOUNT_INSET, BH - MOUNT_INSET, 0),
}
# footswitches J10..J19 along the bottom, left-to-right in GPIO order -- that
# ordering is what keeps the fan-out from crossing (gated in _check)
FSW_Y = 85.0
FSW_X0, FSW_X1 = 8.0, 92.0     # THE constraint on the board's width. An 84 mm span
                               # of centres is the floor -- ten 8.5 mm JSTs plus the
                               # 0.8 mm keepout is 92.2 mm of outline, and the row is
                               # centred in the 100, leaving 3.75 mm each side. The
                               # row cannot shrink without giving up one connector
                               # per pedal, so a smaller board means a different
                               # bench story, not a tighter layout.
                               # y 85 on the 99.5 board: the row's courtyard bottom
                               # lands at ~88.4 and the corner holes' 6.4 mm pads
                               # start at 91.3 -- 2.9 mm clear, which DRC checks.
CAP_Y = 75.0                   # the debounce cap row, one cap directly above its
                               # own switch -- see _place_debounce_caps()


def fsw_x(i):
    return FSW_X0 + (FSW_X1 - FSW_X0) * i / 9.0


for _i in range(10):
    PLACEMENT["J%d" % (10 + _i)] = (fsw_x(_i), FSW_Y, 0)

PWR_NETS = {"+5V", "+3V3"}
MIN_PWR_TRACK_W = 0.6           # see the TRACK_W note: 1.56 A of WS2812 needs it
# Copper, mask, paste, silk, outline -- the layers a fab needs and nothing else.
# Paste is in the list because the boards that were actually manufactured were
# built from a set that carried it (43 front stencil apertures); leaving it out
# here made the script emit a set the committed gerbers did not match.
FAB_LAYERS = ("F.Cu,B.Cu,F.Mask,B.Mask,F.Paste,B.Paste,"
              "F.Silkscreen,B.Silkscreen,Edge.Cuts")
# The board's own via geometry. Router-inserted vias are checked against it because
# they arrive from Freerouting, not from _via(), and defaulted to 0.6/0.3 once.
MIN_VIA_D, MIN_VIA_DRILL = 0.8, 0.4
POUR_NET = "GND"


# Passives are NOT in the table above. Hand-placing 26 resistors and capacitors
# is a table that silently drifts from the netlist the first time a part is added.
# Instead they are placed BY the netlist: each one lands next to whichever placed
# part it shares the most nets with, in the nearest free slot. Deterministic
# (sorted iteration, first-fit outward spiral), and _check()'s overlap gate proves
# the result rather than trusting it.
KEEPOUT = 0.8                   # margin around every footprint, mm. Also covers
                                # the body overhanging its outermost pads.
GRID = 1.0                      # placement search step
STITCH_STEP = 12.0              # GND stitching via pitch


# ---- board -----------------------------------------------------------------

def _outline(board):
    pts = [(EDGE_R, 0), (BW - EDGE_R, 0), (BW, EDGE_R), (BW, BH - EDGE_R),
           (BW - EDGE_R, BH), (EDGE_R, BH), (0, BH - EDGE_R), (0, EDGE_R)]
    segs = [(pts[0], pts[1]), (pts[2], pts[3]), (pts[4], pts[5]), (pts[6], pts[7])]
    for a, b in segs:
        s = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_SEGMENT)
        s.SetStart(P(*a)); s.SetEnd(P(*b))
        s.SetLayer(pcbnew.Edge_Cuts); s.SetWidth(FromMM(0.1))
        board.Add(s)
    for cx, cy, sa, ea in ((EDGE_R, EDGE_R, (0, EDGE_R), (EDGE_R, 0)),
                           (BW - EDGE_R, EDGE_R, (BW - EDGE_R, 0), (BW, EDGE_R)),
                           (BW - EDGE_R, BH - EDGE_R, (BW, BH - EDGE_R), (BW - EDGE_R, BH)),
                           (EDGE_R, BH - EDGE_R, (EDGE_R, BH), (0, BH - EDGE_R))):
        a = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_ARC)
        a.SetCenter(P(cx, cy)); a.SetStart(P(*sa)); a.SetEnd(P(*ea))
        a.SetLayer(pcbnew.Edge_Cuts); a.SetWidth(FromMM(0.1))
        board.Add(a)


def _load_fp(board, lib, name, ref, x, y, rot, by_centre=True):
    """Place a footprint so (x, y) is the CENTRE of its extent.

    A footprint's origin is wherever its author put it -- pad 1 on an axial
    resistor, a corner on the Pico (whose pads run 0..17.78 x 0..48.26). Placing
    by origin means every coordinate in PLACEMENT silently means something
    different, which is how the Pico ended up straddling the footswitch row.
    """
    path = LOCAL_FP if lib == "segno" else os.path.join(KICAD_FP, lib + ".pretty")
    fp = pcbnew.FootprintLoad(path, name)
    if fp is None:
        raise SystemExit(f"footprint not found: {lib}:{name} (looked in {path})")
    fp.SetReference(ref)
    board.Add(fp)
    fp.SetPosition(P(0.0, 0.0))
    if rot:
        fp.SetOrientationDegrees(rot)
    cw, ch = _courtyard_size(lib, name)
    if abs((rot % 180.0) - 90.0) < 1.0:
        cw, ch = ch, cw
    _SIZE[ref] = (cw, ch)
    if by_centre:
        off = _centre(fp)
        fp.SetPosition(P(x - off[0], y - off[1]))
    else:
        fp.SetPosition(P(x, y))
    return fp


def _pad(fp, padname):
    for p in fp.Pads():
        if p.GetNumber() == str(padname):
            return p
    return None


def _pad_xy(fp, padname):
    p = _pad(fp, padname)
    if p is None:
        return None
    pos = p.GetPosition()
    return (ToMM(pos.x) - ORIGIN[0], ToMM(pos.y) - ORIGIN[1])


VIA_KEEPOUT = VIA_D / 2.0 + CLEARANCE     # via centre -> anything else it must clear


def _drill_keepout(fps):
    """Every pad on the board as a box a via centre may not enter.

    Boxes come from the pad's own bounding box, which is in board coordinates and
    already accounts for the footprint's rotation -- GetSize() does not, and a
    rotated module's pads then read as keepouts of the wrong shape.
    """
    out = []
    for fp in fps.values():
        for p in fp.Pads():
            b = p.GetBoundingBox()
            out.append((ToMM(b.GetLeft()) - ORIGIN[0] - VIA_KEEPOUT,
                        ToMM(b.GetTop()) - ORIGIN[1] - VIA_KEEPOUT,
                        ToMM(b.GetRight()) - ORIGIN[0] + VIA_KEEPOUT,
                        ToMM(b.GetBottom()) - ORIGIN[1] + VIA_KEEPOUT))
    return out


def _via_free(x, y, boxes):
    if not (1.0 <= x <= BW - 1.0 and 1.0 <= y <= BH - 1.0):
        return False
    return not any(x0 <= x <= x1 and y0 <= y <= y1 for x0, y0, x1, y1 in boxes)


def _claim_via(x, y, boxes):
    """Reserve a via's own footprint so the next one cannot land on top of it."""
    r = VIA_D + CLEARANCE
    boxes.append((x - r, y - r, x + r, y + r))


def _track(board, net, layer, width, a, b):
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(P(*a)); t.SetEnd(P(*b))
    t.SetWidth(FromMM(width)); t.SetLayer(layer)
    t.SetNet(net)
    board.Add(t)


def _via(board, net, x, y):
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(P(x, y))
    v.SetWidth(FromMM(VIA_D)); v.SetDrill(FromMM(VIA_DRILL))
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    v.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    v.SetNet(net)
    board.Add(v)


def _stitch_grid(board, net, fps, boxes):
    """A coarse via grid tying the B.Cu pour together.

    Routing on B.Cu chops the pour into islands, and an island with no via back to
    the net reads as "unconnected" -- four of them did. Per-pad vias alone are not
    enough because they sit where the copper is busiest. Vias go in BEFORE the DSN
    export so Freerouting treats them as obstacles and routes around them.

    `boxes` carries the drill keepout: every pad, plus every via already placed. The
    lattice walks a fixed pitch with no idea what is under it, so without that it
    will happily drop a via down a plated hole.
    """
    keep = list(boxes) + [_bbox_mm(fp) for fp in fps.values()]
    n = 0
    y = STITCH_STEP
    while y < BH - STITCH_STEP / 2:
        x = STITCH_STEP
        while x < BW - STITCH_STEP / 2:
            if _via_free(x, y, keep):
                _via(board, net, x, y)
                _claim_via(x, y, keep)
                n += 1
            x += STITCH_STEP
        y += STITCH_STEP
    return n


# 12 mm, and deliberately no finer. The lattice is the COARSE half of the stitching:
# it ties the open areas, and _stitch_gnd() ties everything that matters near a pad,
# which is where a pour actually fragments. Tightening the lattice instead was tried
# -- 8 mm, 49 lattice vias -- and it is the wrong lever twice over: it cannot place a
# via near a connector anyway (every point inside a footprint is skipped), so it did
# not fix the starved thermals at J6, and the extra obstacles in the open middle cost
# the router SWCLK, which it then left unrouted. Ties belong beside the pads that
# need them, not spread evenly over the board.


def _pour_gnd(board, net, layer=pcbnew.B_Cu):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(net)
    z.SetLocalClearance(FromMM(CLEARANCE))
    z.SetMinThickness(FromMM(0.2))
    # Thermal relief, NOT a solid tie. This was solid on the strength of "every
    # part here is through-hole and hand-soldered, so the usual wave/reflow thermal
    # argument is moot" -- which stopped being true the moment the Pico became a
    # surface-mount module. Its nine GND pads now sit in a plane on their own layer,
    # and a solid tie wicks the iron's heat straight into that plane: cold joints on
    # the one part that is painful to rework.
    #
    # The original reason for going solid was five "starved_thermal" errors from
    # spokes too narrow to form, which is a symptom of leaving the widths at their
    # defaults rather than a reason to abandon relief -- so they are set explicitly.
    z.SetPadConnection(PAD_CONNECTION)
    z.SetThermalReliefGap(FromMM(0.3))
    z.SetThermalReliefSpokeWidth(FromMM(0.4))
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    # Delete every fragment not joined to the pour's main body. A dense 2-layer
    # F.Cu pour always breaks up around the routing, and raising a minimum-area
    # threshold only moves the complaint to the next pad -- it was chased from C14
    # to C5 to U1 that way. A fragment cannot carry a return current anywhere, and
    # nothing depends on it: _stitch_gnd() already drops a via on every GND pad, so
    # each one reaches the B.Cu plane on its own.
    o = z.Outline()
    o.NewOutline()
    for x, y in ((0.3, 0.3), (BW - 0.3, 0.3), (BW - 0.3, BH - 0.3), (0.3, BH - 0.3)):
        o.Append(P(x, y).x, P(x, y).y)
    z.SetIsFilled(False)
    board.Add(z)
    return z


def _ref_key(ref):
    """J2 before J10, so the placement order does not depend on string sorting."""
    head = ref.rstrip("0123456789")
    return (head, int(ref[len(head):] or 0))


def _silk_items(board, fps):
    """-> [(item, text, (x0, y0, x1, y1))] for everything on the front silkscreen.

    Board drawings AND every footprint's own reference and value. The gate used to
    read GetDrawings() alone, which is the 21 labels this file draws and none of the
    58 designators the library footprints bring with them -- so "J1" sat across R3
    with every check green.
    """
    out = []
    items = [t for t in board.GetDrawings() if t.GetClass() == "PCB_TEXT"]
    for fp in fps.values():
        items += [fp.Reference(), fp.Value()]
    for t in items:
        if not t.IsOnLayer(pcbnew.F_SilkS) or not t.IsVisible():
            continue
        b = t.GetBoundingBox()
        out.append((t, t.GetText(),
                    (ToMM(b.GetLeft()) - ORIGIN[0], ToMM(b.GetTop()) - ORIGIN[1],
                     ToMM(b.GetRight()) - ORIGIN[0], ToMM(b.GetBottom()) - ORIGIN[1])))
    return out


def _silk_art(board):
    """The segno mark (Bravura, SMuFL U+E047) and JetBrains Mono legends as
    FILLED silkscreen polygons, front and back. The outlines live in
    silk_art.py (generated from the fonts -- see its docstring); this only
    turns them into PCB_SHAPE polys. The two art strips were chosen from a
    pad+silk occupancy scan of the finished board (>=1 mm clear of every pad
    on their own side), so they add no DRC noise. BACK_ART is mirrored about
    the board's x centre so it reads correctly looking AT the back."""
    from silk_art import FRONT_ART, BACK_ART

    def emit(polys, layer, mirror=False):
        for outer, holes in polys:
            sps = pcbnew.SHAPE_POLY_SET()
            def chain(pts):
                c = pcbnew.SHAPE_LINE_CHAIN()
                for x, y in pts:
                    xx = BW - x if mirror else x
                    c.Append(FromMM(ORIGIN[0] + xx), FromMM(ORIGIN[1] + y))
                c.SetClosed(True)
                return c
            oi = sps.AddOutline(chain(outer))
            for h in holes:
                sps.AddHole(chain(h), oi)
            sps.Fracture()
            sh = pcbnew.PCB_SHAPE(board)
            sh.SetShape(pcbnew.SHAPE_T_POLY)
            sh.SetPolyShape(sps)
            sh.SetFilled(True)
            sh.SetWidth(0)
            sh.SetLayer(layer)
            board.Add(sh)

    emit(FRONT_ART, pcbnew.F_SilkS)
    emit(BACK_ART, pcbnew.B_SilkS, mirror=True)


def _silk(board, text, x, y, h=1.2):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(text)
    t.SetPosition(P(x, y))
    t.SetLayer(pcbnew.F_SilkS)
    t.SetTextSize(pcbnew.VECTOR2I(FromMM(h), FromMM(h)))
    t.SetTextThickness(FromMM(h * SILK_STROKE_RATIO))
    board.Add(t)
    return t


def _text_box(t):
    """(x0, y0, x1, y1) of a text item as RENDERED, in board-local mm.

    Character-count estimates are close enough to place by and not to check by:
    they put every footswitch label within 0.07 mm of its own designator, which
    reads as a comfortable gap here and as 14 silk_overlap errors in KiCad.
    """
    b = t.GetBoundingBox()
    return (ToMM(b.GetLeft()) - ORIGIN[0], ToMM(b.GetTop()) - ORIGIN[1],
            ToMM(b.GetRight()) - ORIGIN[0], ToMM(b.GetBottom()) - ORIGIN[1])


_CY = {}          # (lib, name) -> (w, h) of the UNROTATED courtyard, measured once
_SIZE = {}        # ref -> (w, h) after this instance's rotation


def _courtyard_size(lib, name):
    """Courtyard w/h of a pristine, unrotated, unplaced copy.

    Measured from its own fresh load rather than from the placed instance,
    because the cached courtyard polygon is INCONSISTENT: it follows
    SetOrientationDegrees() for some footprints (the Pico) and not others (the
    2x20 IDC). Reading it once at rotation 0 and rotating by hand is the only
    version that gives the same answer every time.
    """
    key = (lib, name)
    if key not in _CY:
        b = pcbnew.BOARD()
        path = LOCAL_FP if lib == "segno" else os.path.join(KICAD_FP, lib + ".pretty")
        fp = pcbnew.FootprintLoad(path, name)
        w = h = 0.0
        if fp is not None:
            b.Add(fp)
            fp.SetPosition(pcbnew.VECTOR2I(0, 0))
            try:
                cb = fp.GetCourtyard(pcbnew.F_CrtYd).BBox()
                w, h = ToMM(cb.GetWidth()), ToMM(cb.GetHeight())
            except Exception:
                pass
        _CY[key] = (w, h)
    return _CY[key]


def _extent(fp):
    """(x0, y0, x1, y1) in board-local mm -- the footprint's real keep-out area.

    Three traps, each of which yields plausible numbers:
      * GetBoundingBox() includes the reference and value TEXT -- a 5 mm disc cap
        measures 26.7 x 6.7 that way, a 10 mm axial resistor 43.2 x 6.4.
      * The cached COURTYARD follows rotation for some footprints and not others.
      * PADS follow rotation reliably but are smaller than the courtyard, and DRC
        judges courtyards -- so a pads-only gate passes boards DRC then rejects.

    So: pads give the CENTRE (always rotation-correct), a pristine load gives the
    courtyard SIZE, and the rotation is applied here. Gate and DRC now agree.
    """
    xs, ys = [], []
    for pad in fp.Pads():
        pos, sz = pad.GetPosition(), pad.GetSize()
        xs += [ToMM(pos.x - sz.x // 2) - ORIGIN[0], ToMM(pos.x + sz.x // 2) - ORIGIN[0]]
        ys += [ToMM(pos.y - sz.y // 2) - ORIGIN[1], ToMM(pos.y + sz.y // 2) - ORIGIN[1]]
    if not xs:
        pos = fp.GetPosition()
        c = (ToMM(pos.x) - ORIGIN[0], ToMM(pos.y) - ORIGIN[1])
        return (c[0], c[1], c[0], c[1])
    cx, cy = (min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    cw, ch = _SIZE.get(fp.GetReference(), (0.0, 0.0))
    return (cx - max(w, cw) / 2.0, cy - max(h, ch) / 2.0,
            cx + max(w, cw) / 2.0, cy + max(h, ch) / 2.0)


def _centre(fp):
    x0, y0, x1, y1 = _extent(fp)
    return ((x0 + x1) / 2.0, (y0 + y1) / 2.0)


def _bbox_mm(fp):
    x0, y0, x1, y1 = _extent(fp)
    return (x0 - KEEPOUT, y0 - KEEPOUT, x1 + KEEPOUT, y1 + KEEPOUT)


def _fp_size_mm(fp):
    x0, y0, x1, y1 = _extent(fp)
    return (x1 - x0, y1 - y0)


def _best_anchor(ref, net_of, fps, nets):
    """Where a passive wants to be: on the pads of its most SPECIFIC net.

    Counting shared nets and taking the winner does not work -- GND, +3V3 and +5V
    touch nearly every part, so every passive ties on the rails and the tie breaks
    alphabetically, which is how R7 (the CTRL reference divider) ended up 80 mm from
    the two jacks it serves. A 2-pad signal net says far more about where a part
    belongs than a 40-pad rail, so nets are scored by 1/len and the anchor is the
    CENTROID OF THE PADS of the best one, not the centre of some whole footprint.
    """
    mine = net_of.get(ref, set()) - POURED_NETS
    best, best_score, pool = None, 0.0, []
    for name in sorted(mine):
        nodes = nets.get(name, ())
        placed = [(r, pd) for r, pd in nodes if r in fps]
        if not placed:
            continue
        score = 1.0 / len(nodes)
        if score < best_score - 1e-9:
            continue
        pts = []
        for r, pd in placed:
            for pad in fps[r].Pads():
                if pad.GetNumber() == str(pd):
                    pts.append((ToMM(pad.GetPosition().x) - ORIGIN[0],
                                ToMM(pad.GetPosition().y) - ORIGIN[1]))
        if not pts:
            continue
        # A series part (R1: U1 -> ring header) belongs BETWEEN its neighbours, so
        # equally-specific nets are pooled rather than decided alphabetically --
        # picking one put R1 hard against U1 and 51 mm from the J6 it feeds.
        if score > best_score + 1e-9:
            best_score, pool = score, []
        pool.append((sum(x for x, _ in pts) / len(pts),
                     sum(y for _, y in pts) / len(pts)))
        best = (sum(x for x, _ in pool) / len(pool),
                sum(y for _, y in pool) / len(pool))
    if best is None:                       # rails-only part (bulk caps): fall back
        for other, fp in sorted(fps.items()):
            if net_of.get(ref, set()) & net_of.get(other, set()):
                return _centre(fp)
        return (BW / 2.0, BH / 2.0)
    return best


# How far a passive may be pushed from its anchor before the placement is simply
# wrong. Unbounded, the spiral walks until it finds ANY hole: two footswitch
# debounce caps ended up 40 mm away on the far side of the Pi ribbon, which no gate
# caught because each was still within a hop of its own net. Failing loudly here is
# the point -- it means "make room", not "put it anywhere".
MAX_SLOT_R = 28.0


def _free_slot(anchor, w, h, boxes):
    """Nearest free position to `anchor`, searched as an outward square spiral."""
    ax, ay = anchor
    for radius in range(1, int(MAX_SLOT_R / GRID) + 1):
        cands = []
        for i in range(-radius, radius + 1):
            cands += [(ax + i * GRID, ay - radius * GRID),
                      (ax + i * GRID, ay + radius * GRID),
                      (ax - radius * GRID, ay + i * GRID),
                      (ax + radius * GRID, ay + i * GRID)]
        cands.sort(key=lambda c: (c[0] - ax) ** 2 + (c[1] - ay) ** 2)
        for cx, cy in cands:
            x0, y0 = cx - w / 2 - KEEPOUT, cy - h / 2 - KEEPOUT
            x1, y1 = cx + w / 2 + KEEPOUT, cy + h / 2 + KEEPOUT
            if x0 < 1.0 or y0 < 1.0 or x1 > BW - 1.0 or y1 > BH - 1.0:
                continue
            if any(not (x1 <= b[0] or b[2] <= x0 or y1 <= b[1] or b[3] <= y0) for b in boxes):
                continue
            return (cx, cy)
    return None


# ---- gates -----------------------------------------------------------------

# The ratsnest budget. Sum, over every routed net, of the minimum spanning tree
# through its pads -- i.e. the shortest total copper that could possibly connect
# the board as placed. It is the one number that says whether a floorplan is
# efficient or merely tidy, and it is why the pin map and this table have to move
# together. GND is excluded: it is a pour, not a net of tracks.
#
# Measured 1607 mm on the layout below (with the review-fix resistors
# R14..R18; it was 1458 before them). For scale, the same floorplan measured
# 1573 mm at 115x96 and the first one 2495 mm on 160x100 -- shrinking the
# outline SHORTENED the copper, because every fan-out got shorter.
#
# It is NOT the minimum achievable: packing the five rear-panel headers together in
# the panel's own order costs about 180 mm, most of it PWR_BTN, because POWER is
# leftmost on the panel while the Pi ribbon it lands on is at the right edge. That
# is a trade taken deliberately. The whole rear loom is then one flat bundle
# leaving one edge in one order, which is worth more on a hand-wired console than
# 180 mm of copper carrying a button press. Do not "optimise" it back.
#
# The budget is the measurement plus ~10%,
# so a placement that drifts back toward "connectors in neat rows regardless of
# which pad they serve" fails here rather than at the autorouter.
#
# Most of the growth from the five review-fix resistors is the two link series
# parts: the link's 25 mm diagonal crosses U1, so R17/R18 cannot sit on it and
# their legs detour around the package -- ~85 mm of minimum copper that is the
# price of bounding cross-domain current, not placement waste.
#
# ~500 mm of that total is the ten SW_* nets, and it is NOT a defect to be
# optimised away. The module's footswitch pads span 28 mm; ten 8.5 mm JSTs cannot
# span less than 84 mm side by side, so the fan-out is geometric. Staggering them
# into two rows would buy ~150 mm and cost the one property that matters on a
# hand-wired board: pedal 1..10 reading left to right, unambiguously, at the bench.
# These are debounced switch lines -- 60 mm of trace is electrically free. Keep the
# straight ordered row.
#
# v3 measured 1915 mm. The ~210 mm over v2 is the four CTRL sense nets (ring and
# presence, J20_REF/J21_REF/J20_TN/J21_TN and their GPIO ends): their series
# parts sit under the module, 50-60 mm from the jacks they serve, because the
# column beside U2 that would have put them under the jacks is the expansion
# header's. They are DC lines through 4.7k -- SLOW_SENSE_NETS, exempt from the
# hop gate for the same reason -- so that copper is a decision, not waste. The
# budget follows the measurement plus ~7%.
MAX_RATSNEST_MM = 2050.0
POURED_NETS = {"GND"}

# The ratsnest total is a GLOBAL number, and --selftest proved it cannot see a
# single connector moving to the wrong end of the board: shifting J6 back across
# the module cost ~100 mm, which any sane budget absorbs. So there is a second,
# LOCAL gate. Every pad on a signal net must be within MAX_HOP_MM of the nearest
# other pad on that net -- i.e. no part is stranded away from what it wires to.
#
# Measured worst hops on the layout below: 40.7 mm (SW_BANK) and 34.7 mm
# (SW_CLEAR), both the geometric footswitch fan-out. 42 mm is NOT that plus 10%
# any more -- it is 3% over the worst case, because the 100 mm outline pins the
# module's x (see J1) and SW_BANK pays for it. The limit stays where it is rather
# than being relaxed to fit: a fan-out that grows past it is a real problem, and
# the next mm has to come from the floorplan. Rails are exempt: +5V and +3V3 touch
# parts at both ends of the board by definition, and are carried by wide traces
# and the pour.
MAX_HOP_MM = 42.0
RAIL_NETS = {"+3V3", "+5V"}
# The CTRL ring-sense nets are exempt too, by decision: a ring is 3V3 through 1k
# that a footswitch pulls to ground, read through 4.7k into a GPIO's pull-up --
# DC, and slow even by footswitch standards -- so the trace can be as long as
# the board. That bought back the column beside U2 for the expansion header,
# whose position the bench preferred, and put R19/R20 in the row R13 and R15
# left empty under the module.
SLOW_SENSE_NETS = {"J20_REF", "J21_REF", "CTRL1_RING", "CTRL2_RING",
                   "J20_TN", "J21_TN", "CTRL1_PRESENT", "CTRL2_PRESENT"}


def worst_hops(fps, nets):
    """-> [(distance_mm, net, ref, pad)] worst first, signal nets only."""
    pads = {}
    for ref, fp in fps.items():
        for pad in fp.Pads():
            pads[(ref, pad.GetNumber())] = (ToMM(pad.GetPosition().x),
                                            ToMM(pad.GetPosition().y))
    out = []
    for name, nodes in nets.items():
        if name in POURED_NETS or name in RAIL_NETS or name in SLOW_SENSE_NETS:
            continue
        # Nets landing on J2 are exempt -- the WHOLE net, both ends; this
        # `continue` checks nothing about them. J2's position is not a routing
        # choice: a 40-way ribbon has to exit at a board edge, and no edge is
        # within 42 mm of the module wherever it sits. Every signal on it is slow
        # (MIDI is 31.25 kbaud, the link a UART, SWD a flashing port, PWR_BTN a
        # switch), so trace length is not the binding constraint; where the cable
        # goes is. The cost, named honestly: parts whose nets are all either
        # rails or J2-landing (R14 is one) have NO distance gate at all -- their
        # placement comments carry the arithmetic instead.
        if any(r == "J2" for r, _p in nodes):
            continue
        here = {n: pads[n] for n in nodes if n in pads}
        if len(here) < 2:
            continue
        for node, pt in here.items():
            d = min(math.dist(pt, q) for m, q in here.items() if m != node)
            out.append((d, name, node[0], node[1]))
    out.sort(reverse=True)
    return out


def ratsnest_mm(fps, nets, per_net=False):
    """Total MST length over all routed nets, in mm."""
    pads = {}
    for ref, fp in fps.items():
        for pad in fp.Pads():
            pads.setdefault((ref, pad.GetNumber()), (ToMM(pad.GetPosition().x),
                                                     ToMM(pad.GetPosition().y)))
    out, total = {}, 0.0
    for name, nodes in nets.items():
        if name in POURED_NETS:
            continue
        pts = [pads[n] for n in nodes if n in pads]
        if len(pts) < 2:
            continue
        # Prim's, O(n^2) -- the biggest net here has 8 pads.
        reached, rest, length = [pts[0]], list(pts[1:]), 0.0
        while rest:
            d, i, j = min((math.dist(a, b), bi, ai)
                          for ai, a in enumerate(reached)
                          for bi, b in enumerate(rest))
            length += d
            reached.append(rest.pop(i))
        out[name] = length
        total += length
    return (total, out) if per_net else total


_QUIET = False


def _check_place(fps):
    """The pure-geometry placement gates: on the board, and not on each other.

    A function of its own so build() can run it the moment placement finishes --
    BEFORE _outline()/_labels() -- and a displaced part fails with its true
    identity instead of as the label-placement symptom it causes downstream.
    _check() runs it again; the asserts are idempotent and the double cost is nil.
    """
    # every placed footprint is inside the outline, with room for the edge
    for ref, fp in fps.items():
        x0, y0, x1, y1 = _extent(fp)
        assert 0.5 <= x0 and x1 <= BW - 0.5 and 0.5 <= y0 and y1 <= BH - 0.5, (
            f"PLACE: {ref} spans ({x0:.1f},{y0:.1f})..({x1:.1f},{y1:.1f}), outside "
            f"the {BW:.1f}x{BH:.1f} outline")

    # footprints must not overlap each other
    refs = sorted(fps)
    for i, a in enumerate(refs):
        for b in refs[i + 1:]:
            ax0, ay0, ax1, ay1 = _extent(fps[a])
            bx0, by0, bx1, by1 = _extent(fps[b])
            if not (ax1 <= bx0 or bx1 <= ax0 or ay1 <= by0 or by1 <= ay0):
                raise AssertionError(
                    f"PLACE: {a} and {b} overlap -- footprints cannot share copper area")


def _check(fps, nets, board=None):
    """Prove the layout is sane BEFORE any copper is drawn.

    The load-bearing one is CROSSING: this board has no autorouter, and routing is
    only trivial because every fan-out preserves left-to-right order. If an
    ordering ever breaks, two tracks cross on one layer and the board is quietly
    wrong -- so it is checked, not assumed.
    """
    # Placement geometry first -- via _check_place, which build() also runs the
    # moment placement finishes, BEFORE the silk stage. A displaced part must
    # fail as the placement error it is: _labels() runs early and its own
    # "nowhere to print" assert used to fire first, so a bad coordinate reported
    # as a silkscreen symptom and a selftest control once proved the wrong gate.
    _check_place(fps)

    # the footswitch fan-out must preserve order, or its tracks cross
    order = []
    for i in range(10):
        ref = "J%d" % (10 + i)
        pad = _pad_xy(fps[ref], "1")
        sig = [n for n, nodes in nets.items() if (ref, "1") in nodes]
        assert len(sig) == 1, f"CROSSING: {ref} pin 1 is on {sig}, expected exactly one net"
        pico_pad = [p for r, p in nets[sig[0]] if r == "J1"]
        assert len(pico_pad) == 1, f"CROSSING: {sig[0]} does not land on exactly one Pico pad"
        order.append((pad[0], _pad_xy(fps["J1"], pico_pad[0])[0], ref, sig[0]))
    order.sort()
    xs = [o[1] for o in order]
    assert xs == sorted(xs), (
        "CROSSING: the footswitch JSTs are not in the same left-to-right order as "
        "the Pico pads they serve, so their fan-out tracks cross on one layer. "
        "Order seen: " + ", ".join("%s->%.1f" % (o[2], o[1]) for o in order))

    # the opto's DIN side must be isolated: no other footprint within ISOLATION_GAP
    ux0, uy0, ux1, uy1 = _extent(fps["U2"])
    # Only parts that actually SHARE A NET with the opto or its jack belong inside
    # the barrier. Exempting every ref beginning R/C/D -- as this did -- waved
    # through every resistor and capacitor on the board, so the gate could not fail
    # for the most likely mistake there is: parking an unrelated passive in the moat.
    # The barrier is the DIN SIDE specifically: U2 pins 1 and 2, and J5. Not every
    # net U2 touches -- its pins 5 and 6 are GND and +3V3, i.e. the whole board, so
    # keying off "shares a net with U2" exempts everything and the gate dies.
    din_side = {("U2", "1"), ("U2", "2")}
    inside = {"U2", "J5"}
    for n, nodes in nets.items():
        if n in POURED_NETS or n in RAIL_NETS:
            continue
        if any(nd in din_side or nd[0] == "J5" for nd in nodes):
            inside.update(r for r, _p in nodes)
    for ref, fp in fps.items():
        if ref in inside:
            continue
        x0, y0, x1, y1 = _extent(fp)
        dx = max(ux0 - x1, x0 - ux1, 0.0)
        dy = max(uy0 - y1, y0 - uy1, 0.0)
        d = (dx * dx + dy * dy) ** 0.5
        assert d >= ISOLATION_GAP, (
            f"ISOLATION: {ref} is {d:.2f} mm from the opto U2, under the "
            f"{ISOLATION_GAP} mm barrier -- MIDI IN's isolation is the whole point of U2")
    # the placement must actually be efficient, not just legal
    total, per = ratsnest_mm(fps, nets, per_net=True)
    worst = sorted(per.items(), key=lambda kv: -kv[1])[:3]
    if not _QUIET:
        print("\n  ratsnest %.0f mm on %.1fx%.1f (%.0f cm2), budget %.0f mm ... "
              % (total, BW, BH, BW * BH / 100.0, MAX_RATSNEST_MM), end="")
    silk = _silk_items(board, fps) if board else []
    # ...and it has to be PRINTABLE, which is a fab limit, not a KiCad one. KiCad's
    # own minimum stroke is 0.08 mm, so its DRC passed a board whose 58 designators
    # were all stroked at 0.133 mm -- under JLCPCB's 0.15 mm floor, where lines thin,
    # break, or are dropped and you find out when the boards arrive.
    for item, text, _box in silk:
        stroke, height = ToMM(item.GetTextThickness()), ToMM(item.GetTextHeight())
        assert stroke >= FAB_MIN_SILK_STROKE - 1e-9, (
            f"SILK_FAB: '{text}' is stroked at {stroke:.3f} mm, under the "
            f"{FAB_MIN_SILK_STROKE} mm the fab can print -- it will come out thin, "
            "broken, or not at all")
        assert height >= FAB_MIN_SILK_HEIGHT - 1e-9, (
            f"SILK_FAB: '{text}' is {height:.3f} mm tall, under the "
            f"{FAB_MIN_SILK_HEIGHT} mm the fab can print")
    for item, text, (x0, y0, x1, y1) in silk:
        for ref, fp in fps.items():
            fx0, fy0, fx1, fy1 = _extent(fp)
            if not (x1 < fx0 or fx1 < x0 or y1 < fy0 or fy1 < y0):
                raise AssertionError(
                    f"SILK: '{text}' is printed across {ref} -- silkscreen "
                    "over a pad or a body is unreadable and can foul the solder mask")
        assert 0 <= x0 and x1 <= BW and 0 <= y0 and y1 <= BH, (
            f"SILK: '{text}' spans ({x0:.1f},{y0:.1f})..({x1:.1f},{y1:.1f}), "
            f"off the {BW:.0f}x{BH:.0f} outline -- it will not be printed")
    # ...and not over each other either, which is a rule KiCad has and this did not:
    # the function label and the designator of all ten footswitches were printed one
    # on top of the other, 0.07 mm apart, and only DRC ever said so.
    for i, (_ia, ta, (ax0, ay0, ax1, ay1)) in enumerate(silk):
        for _ib, tb, (bx0, by0, bx1, by1) in silk[i + 1:]:
            if not (ax1 < bx0 or bx1 < ax0 or ay1 < by0 or by1 < ay0):
                raise AssertionError(
                    f"SILK: '{ta}' and '{tb}' are printed on top of each other -- "
                    "neither can be read at the bench")

    xs = [(_extent(fps[r])[0] + _extent(fps[r])[2]) / 2.0
          for r in REAR_PANEL_ORDER if r in fps]
    assert xs == sorted(xs), (
        "REAR_ORDER: the rear-panel headers are not in the panel's own left-to-right "
        f"order {REAR_PANEL_ORDER} (they sit at {[round(x, 1) for x in xs]}) -- the "
        "loom would have to cross itself between the board and the panel")
    ys = [(_extent(fps[r])[1] + _extent(fps[r])[3]) / 2.0
          for r in REAR_PANEL_ORDER if r in fps]
    assert max(ys) - min(ys) < 2.0, (
        "REAR_ORDER: the rear-panel headers are not on one edge -- the whole point "
        "is that this loom leaves the board once, from one place")

    # A solid pad tie is defensible on an all-through-hole board and wrong the
    # moment anything is surface-mount: an SMD pad tied straight into a plane wicks
    # the iron's heat away and cold-joints. That transition is exactly what happened
    # here and nothing caught it, so it is checked rather than remembered.
    smd = [r for r, fp in fps.items()
           if any(p.GetAttribute() == pcbnew.PAD_ATTRIB_SMD for p in fp.Pads())]
    if smd and board:
        for z in board.Zones():
            assert z.GetPadConnection() != pcbnew.ZONE_CONNECTION_FULL, (
                f"THERMALS: the {z.GetNetname()} pour ties pads solid, but "
                f"{sorted(smd)[:3]} are surface-mount -- SMD pads need thermal "
                "relief or they cannot be hand-soldered reliably")

    # Keep the corridor off the module's USB end clear. USB is not needed in normal
    # operation, but a board that makes it physically impossible to plug in is a
    # different claim -- and the 5 V inlet was sitting directly in front of the
    # socket. The module's USB is at its LEFT end (it is rotated 90 deg), so the
    # corridor is everything left of it within the connector's own height.
    px0, py0, _px1, py1 = _extent(fps["J1"])
    ucy = (py0 + py1) / 2.0
    usb = (0.0, ucy - 6.0, px0, ucy + 6.0)
    for ref, fp in fps.items():
        if ref == "J1":
            continue
        x0, y0, x1, y1 = _extent(fp)
        if not (x1 < usb[0] or usb[2] < x0 or y1 < usb[1] or usb[3] < y0):
            raise AssertionError(
                f"USB_CLEAR: {ref} sits in the corridor off the module's USB end "
                f"(x<{usb[2]:.0f}, y {usb[1]:.0f}..{usb[3]:.0f}) -- a cable could "
                "never be plugged in")

    hops = worst_hops(fps, nets)
    if hops:
        d, name, ref, pad = hops[0]
        assert d <= MAX_HOP_MM, (
            f"HOP: {ref} pad {pad} is {d:.0f} mm from the nearest other pad on "
            f"{name} (limit {MAX_HOP_MM:.0f} mm) -- that part is placed away from "
            "what it wires to. Move it, or move the pin map.")
    assert total <= MAX_RATSNEST_MM, (
        f"RATSNEST: {total:.0f} mm of minimum copper, budget {MAX_RATSNEST_MM:.0f} mm. "
        f"The placement is wasting space -- longest nets: "
        + ", ".join(f"{n} {v:.0f}mm" for n, v in worst))

    return True


# ---- route -----------------------------------------------------------------

def _stitch_gnd(board, fps, nets, netmap, boxes):
    """Every GND pad gets a via into the pours -- BESIDE it, never on it.

    Never on it, for two different reasons depending on the pad:

    A plated through-hole pad already reaches both layers -- that is what the
    plating is -- so a via at its centre connects nothing and just puts a second
    drill hit on the same coordinate. That was all 102 holes_co_located: every one
    of them is a via sitting on a PTH pad centre, and CAM either holds the order or
    drills the spot twice and breaks bits.

    A via in the middle of a SURFACE-MOUNT pad wicks solder to the far side and
    starves the joint -- and on the Pico those pads sit UNDER the module, so the cold
    joint is invisible and unreachable. It also silently undoes the thermal relief:
    KiCad applies a zone's pad-connection setting to PADS only and always ties a via
    solid, so the nine GND pads the relief was added for would be tied solid through
    the via in their middle.

    Beside EVERY GND pad, though, including the through-hole ones -- which is not
    just belt and braces. The blind lattice cannot drop a via anywhere near a
    connector, so the pour around a dense header is exactly where it fragments, and
    the fill then deletes the fragment as an island: J6's two ground pins came back
    starved_thermal with their only spoke reaching copper that was about to vanish.
    A via one pad-width away ties that region to the other layer's plane, so it is
    not an island in the first place.
    """
    n = 0
    for ref, pad in sorted(nets.get(POUR_NET, [])):
        if ref not in fps:
            continue
        p = _pad(fps[ref], pad)
        if p is None:
            continue
        xy = _pad_xy(fps[ref], pad)
        bb = p.GetBoundingBox()
        reach = max(ToMM(bb.GetWidth()), ToMM(bb.GetHeight())) / 2.0 + VIA_KEEPOUT
        # INWARD first: toward the middle of the part the pad belongs to. A pad's
        # fan-out leaves the footprint outward, so a via on the outward side sits in
        # the one lane the net has -- SW_TRACK3 stopped routing at all when a Pico
        # ground via landed in the footswitch fan-out. Under the part's own body
        # nothing is trying to get past.
        fx0, fy0, fx1, fy1 = _extent(fps[ref])
        inward = ((fx0 + fx1) / 2.0 - xy[0], (fy0 + fy1) / 2.0 - xy[1])
        dirs = sorted(((0, -1), (0, 1), (1, 0), (-1, 0)),
                      key=lambda d: -(d[0] * inward[0] + d[1] * inward[1]))
        spot = None
        for k in range(12):
            d = reach + k * 0.5
            for dx, dy in dirs:
                cand = (xy[0] + dx * d, xy[1] + dy * d)
                if _via_free(cand[0], cand[1], boxes):
                    spot = cand
                    break
            if spot:
                break
        if spot is None:
            raise SystemExit(
                f"STITCH: nowhere clear beside {ref} pad {pad} to land its GND via")
        _via(board, netmap[POUR_NET], spot[0], spot[1])
        # A stub from the pad to its via. The pour reaches the pad through thermal
        # spokes, but only where it actually fills; the stub is what makes the tie
        # unconditional, and it is on the pad's own layer so it never adds a
        # crossing.
        _track(board, netmap[POUR_NET], p.GetLayer(), TRACK_W, xy, spot)
        _claim_via(spot[0], spot[1], boxes)
        n += 1
    return n


# ---- build / export --------------------------------------------------------




# Function labels, the way the retired V1 board did it: every connector on that board
# says what it is (REC / STOP / TRK1 / RING / LEDS / MIDI OUT / 9V), because the
# thing that gets wired at the bench is a header, not a reference designator. Refs
# alone are useless with ten identical 2-pin JSTs in a row.
LABELS = {
    "J10": "REC",  "J11": "STOP", "J12": "UNDO", "J13": "MODE", "J14": "TRK1",
    "J15": "TRK2", "J16": "TRK3", "J17": "TRK4", "J18": "CLR",  "J19": "BANK",
    "J2":  "PI",     "J3":  "5V IN",    "J20": "CTRL 1", "J21": "CTRL 2",
    "J22": "EXP",    "J23": "PD",       "J4":  "MIDI OUT", "J5":  "MIDI IN",
    "J6":  "RING",   "J7":  "LEDS",     "J8":  "PWR BTN", "J9": "PI PWR",
}
SILK_H = 1.0
REF_H = 0.8          # designators, a size down from the function labels: there are
                     # 58 of them and they have to fit in the gaps the labels leave.
                     # This is exactly the fab's minimum printable height. 0.9 was
                     # tried for margin and does not fit: the designators stop
                     # finding gaps, which trades a printing risk for a legibility
                     # one. The STROKE is where the margin went instead -- h/5 puts
                     # it at 0.16 mm against a 0.15 floor
AUTOPLACE_REFS = True   # off = the designators stay where each library footprint
                        # left them, which is the board that shipped "J1" across R3
# Pinned label rows. A GROUP of labels reads as tidy only if it sits on one side at
# one y; left to the search below, the rear-panel row came out "above, right, above,
# right, right" and REC sat left of its header while its nine neighbours sat above.
# Each was individually legal and collectively a mess. The search stays as the
# fallback for the handful of one-off headers.
LABEL_ROW = dict(
    [(r, 3.0) for r in ("J8", "J5", "J4", "J20", "J21")]
    + [("J%d" % (10 + i), 80.1) for i in range(10)]
)
SILK_PAD = 0.5


def _labels(board, fps):
    """Put each label in the nearest free spot around its connector.

    Hand-tuned offsets do not survive: every time the floorplan moved, another
    label landed on a part, and the silk gate rejected the board. So the labels are
    placed the same way the passives are -- try the four sides at increasing
    distance, take the first gap that is actually empty.
    """
    taken = [_extent(fp) for fp in fps.values()]
    for t in board.GetDrawings():
        if t.GetClass() == "PCB_TEXT" and t.IsOnLayer(pcbnew.F_SilkS):
            bb = t.GetBoundingBox()
            taken.append((ToMM(bb.GetLeft()) - ORIGIN[0], ToMM(bb.GetTop()) - ORIGIN[1],
                          ToMM(bb.GetRight()) - ORIGIN[0], ToMM(bb.GetBottom()) - ORIGIN[1]))

    def free(x0, y0, x1, y1):
        if x0 < 0.5 or y0 < 0.5 or x1 > BW - 0.5 or y1 > BH - 0.5:
            return False
        return all(x1 + SILK_PAD < bx0 or bx1 + SILK_PAD < x0 or
                   y1 + SILK_PAD < by0 or by1 + SILK_PAD < y0
                   for bx0, by0, bx1, by1 in taken)

    for ref in sorted(LABELS):
        if ref not in fps:
            continue
        text = LABELS[ref]
        # Drawn first, then measured, then moved. Its rendered width is the only
        # one worth searching with, and it is also what has to go into `taken`:
        # the pinned rows below skipped that entirely, so all ten footswitch
        # designators were later placed straight on top of their own labels.
        t = _silk(board, text, 0.0, 0.0, SILK_H)
        tx0, ty0, tx1, ty1 = _text_box(t)
        w, h = tx1 - tx0, ty1 - ty0
        px0, py0, px1, py1 = _extent(fps[ref])
        if ref in LABEL_ROW:
            spot = ((px0 + px1) / 2.0, LABEL_ROW[ref])
        else:
            cx, cy = (px0 + px1) / 2.0, (py0 + py1) / 2.0
            spot = None
            for d in [i * 0.5 for i in range(2, 24)]:
                for x, y in ((cx, py0 - d), (cx, py1 + d), (px1 + d + w / 2, cy),
                             (px0 - d - w / 2, cy)):
                    if free(x - w / 2, y - h / 2, x + w / 2, y + h / 2):
                        spot = (x, y)
                        break
                if spot:
                    break
            assert spot, f"SILK: nowhere free to print '{text}' next to {ref}"
        t.SetPosition(P(*spot))
        taken.append(_text_box(t))

    # ...and the same treatment for the 58 reference designators, which the library
    # footprints drop wherever their author put them -- which is how "J1" came to be
    # printed across R3. They were invisible to every check here because the gate
    # walked board.GetDrawings() only, and a footprint's reference is not a drawing.
    for ref in sorted(fps, key=_ref_key) if AUTOPLACE_REFS else ():
        t = fps[ref].Reference()
        if not t.IsVisible() or not t.IsOnLayer(pcbnew.F_SilkS):
            continue
        # Level and shrunk. Rotation follows the footprint, so J1's designator was
        # standing on end beside a module whose own extent is 50 mm long.
        t.SetTextAngle(pcbnew.EDA_ANGLE(0, pcbnew.DEGREES_T))
        t.SetTextSize(pcbnew.VECTOR2I(FromMM(REF_H), FromMM(REF_H)))
        t.SetTextThickness(FromMM(REF_H * SILK_STROKE_RATIO))
        tx0, ty0, tx1, ty1 = _text_box(t)
        w, h = tx1 - tx0, ty1 - ty0
        px0, py0, px1, py1 = _extent(fps[ref])
        cx, cy = (px0 + px1) / 2.0, (py0 + py1) / 2.0
        # Four sides AND four corners. On a 115 mm board the sides were enough; at
        # 100 mm the passives band is shoulder to shoulder, and the only gaps left
        # are diagonal ones -- R8's designator had nowhere to go while the corner
        # above it was empty.
        spot = None
        for d in [i * 0.25 for i in range(2, 60)]:
            above, below = py0 - d - h / 2, py1 + d + h / 2
            right, left = px1 + d + w / 2, px0 - d - w / 2
            for x, y in ((cx, above), (cx, below), (right, cy), (left, cy),
                         (right, above), (left, above), (right, below), (left, below)):
                if free(x - w / 2, y - h / 2, x + w / 2, y + h / 2):
                    spot = (x, y)
                    break
            if spot:
                break
        assert spot, (
            f"SILK: nowhere free to print the reference '{ref}' -- the board is too "
            "tightly packed to be assembled by hand from its own silkscreen")
        t.SetPosition(P(*spot))
        taken.append(_text_box(t))


def _debounce_caps(nets):
    """-> {cap_ref: (x, y, rot)}, each 100nF sat directly above the switch it debounces.

    Left to the auto-placer these scattered: seven landed in the channel, C8 was
    pushed below the footswitch row entirely, and the row looked arbitrary because it
    was. The pairing comes from the netlist rather than from C-numbering, so it stays
    correct if console_board.py ever builds the switches in a different order.
    """
    out = {}
    for i in range(10):
        j = "J%d" % (10 + i)
        for name, nodes in nets.items():
            if not name.startswith("SW_"):
                continue
            refs = {r for r, _p in nodes}
            if j not in refs:
                continue
            caps = sorted(r for r in refs if r.startswith("C"))
            assert len(caps) == 1, (
                f"DEBOUNCE: {name} has {caps} on it, expected exactly one cap")
            out[caps[0]] = (fsw_x(i), CAP_Y, 0)
            break
    assert len(out) == 10, f"DEBOUNCE: paired {len(out)} caps to switches, expected 10"
    return out


def _selftest():
    """Flip each layout gate and fail unless it bites. Same contract as
    console_board.py --selftest: a gate nobody has ever seen fail is a comment."""
    import copy
    saved = copy.deepcopy(PLACEMENT)
    # Each control names the gate it is meant to prove. A control that trips some
    # OTHER gate proves nothing about its own, and two of these silently did exactly
    # that after the floorplan moved -- so the expected message is checked, not read.
    # A case moves parts (the PLACEMENT dict) and/or overrides a module constant --
    # the two pours and the designator placement are decisions, not coordinates, and
    # they need controls just as much.
    cases = [
        ("indicator series resistor moved off its own net", "HOP:",
         {"R2": (12.0, 13.0, 90)}, {}),
        # J2 again, the representative case: only hand-PLACEMENT parts can ever
        # be off-board (the spiral bounds its own slots), and those are exactly
        # the labelled connectors. This control briefly became H3 because the
        # displaced J2's label assert fired before the outline gate; build() now
        # runs _check_place() ahead of the silk stage, so the true gate answers.
        ("part pushed off the outline", "outside the", {"J2": (112.0, 40.0, 0)}, {}),
        # Move a NON-isolated part up against the opto rather than moving the opto:
        # displacing U2 also displaces the anchors of its own passives, and the
        # placer then fails before the isolation gate is ever reached. C20 is a
        # 5.6 mm disc, so this leaves ~1 mm of the 2 mm barrier and no overlap --
        # a control that overlaps trips PLACE and proves nothing about ISOLATION.
        ("opto barrier inside ISOLATION_GAP", "ISOLATION:", {"C20": (25.3, 21.0, 0)}, {}),
        # the exact mistake that was shipped: the 5 V inlet parked in front of USB
        ("part blocking the USB corridor", "USB_CLEAR:", {"J3": (10.0, 46.0, 90)}, {}),
        ("footswitch fan-out out of order", "CROSSING:",
         {"J10": (FSW_X1, FSW_Y, 0), "J19": (FSW_X0, FSW_Y, 0)}, {}),
        # The pours tie SMD pads solid. This gate ran BEFORE the pours existed, so it
        # looped over an empty board.Zones() and could not fail; the ordering is what
        # makes the control below meaningful rather than the assertion text.
        ("ground pours tying SMD pads solid", "THERMALS:", {},
         {"PAD_CONNECTION": pcbnew.ZONE_CONNECTION_FULL}),
        # ...and the designators left exactly where the library footprints put them,
        # which is the board that shipped with "J1" printed across R3.
        ("designators left where the footprints put them", "SILK:", {},
         {"AUTOPLACE_REFS": False}),
        # Silk too thin for the fab to print. The stroke follows the text size, so
        # the control moves the RATIO -- which is the number a future "make the
        # designators lighter" edit would reach for.
        ("silkscreen stroked below the fab minimum", "SILK_FAB:", {},
         {"SILK_STROKE_RATIO": 1.0 / 12.0}),
        # A label on a PINNED row grows into its neighbour. The pinned rows are
        # placed at a fixed spot rather than searched for a free one, so nothing
        # about the placement can refuse them -- only the gate can.
        ("a pinned label overrunning its neighbour", "SILK:", {},
         {"LABELS": dict(LABELS, J20="CTRL 1 EXPRESSION PEDAL INPUT JACK")}),
    ]
    ok = True
    for name, want, mutate, over in cases:
        PLACEMENT.clear(); PLACEMENT.update(saved); PLACEMENT.update(mutate)
        keep = {k: globals()[k] for k in over}
        globals().update(over)
        try:
            build(quiet=True)
            print("  NO BITE    %s  <-- gate is dead" % name)
            ok = False
        except (AssertionError, SystemExit) as exc:
            msg = str(exc).replace("\n", " ")
            if want in msg:
                print("  bites      %-38s %s" % (name, msg[:52]))
            else:
                print("  WRONG GATE %-38s wanted %s, got: %s" % (name, want, msg[:40]))
                ok = False
        finally:
            globals().update(keep)
    PLACEMENT.clear(); PLACEMENT.update(saved)
    return ok


def build(quiet=False):
    comps, nets = parse_netlist(NETLIST)
    board = pcbnew.BOARD()

    ds = board.GetDesignSettings()
    ds.SetCopperLayerCount(2)
    # The mask rule is ON, at the fab's own 0.25 mm. It was set to 0 -- i.e. off --
    # back when 0.1in headers produced ~100 "solder_mask_bridge" errors that drowned
    # out everything else. That is no longer true of this layout: re-enabled, DRC
    # comes back with zero. So the blind spot goes; a rule that currently passes is
    # worth more than one that was switched off for a board we no longer have.
    try:
        ds.m_SolderMaskMinWidth = FromMM(0.25)
    except Exception:
        pass

    netmap = {}
    for name in sorted(nets):
        ni = pcbnew.NETINFO_ITEM(board, name)
        board.Add(ni)
        netmap[name] = ni

    fps = {}
    for ref, (lib, name, _val) in sorted(comps.items()):
        if ref in PLACEMENT:
            x, y, rot = PLACEMENT[ref]
            fps[ref] = _load_fp(board, lib, name, ref, x, y, rot)

    for ref, (x, y, rot) in _debounce_caps(nets).items():
        lib, name, _v = comps[ref]
        fps[ref] = _load_fp(board, lib, name, ref, x, y, rot)

    # everything else follows the netlist
    boxes = [_bbox_mm(fp) for fp in fps.values()]
    # The pinned label rows are geometry, not folklore: LABEL_ROW fixes fifteen
    # labels at two y coordinates before the spiral ever runs, so the spiral must
    # see those strips as occupied. Without this, a part auto-placed near the top
    # or bottom edge passes placement and fails five gates later at SILK -- one
    # full pipeline run per lesson, which is how the slot-geography comments in
    # PLACEMENT got written.
    for _y in sorted({y for y in LABEL_ROW.values()}):
        boxes.append((0.0, _y - SILK_H, BW, _y + SILK_H))
    net_of = {}
    for nname, nodes in nets.items():
        for r, _pad in nodes:
            net_of.setdefault(r, set()).add(nname)
    for ref, (lib, name, _val) in sorted(comps.items()):
        if ref in fps:
            continue
        fp = _load_fp(board, lib, name, ref, 0.0, 0.0, 0, by_centre=False)
        w, h = _fp_size_mm(fp)
        off = _centre(fp)                # origin -> extent-centre offset
        anchor = _best_anchor(ref, net_of, fps, nets)
        pos = _free_slot(anchor, w, h, boxes)
        if pos is None:
            raise SystemExit(f"PLACE: no free slot for {ref} near {anchor}")
        fp.SetPosition(P(pos[0] - off[0], pos[1] - off[1]))
        boxes.append(_bbox_mm(fp))
        fps[ref] = fp

    # Placement geometry is judged HERE, the moment it exists -- a bad hand
    # coordinate must fail as PLACE, not surface later as a label with nowhere
    # to print (see _check_place's docstring).
    _check_place(fps)

    # attach nets to pads
    for name, nodes in nets.items():
        for ref, pad in nodes:
            if ref not in fps:
                continue
            for p in fps[ref].Pads():
                if p.GetNumber() == str(pad):
                    p.SetNet(netmap[name])

    _outline(board)
    _silk_art(board)

    # _silk() takes the text CENTRE, not its left edge -- the title was at x 6,
    # i.e. hanging 10 mm off the left of the board, and at y 86 on an 82 mm board.
    # It has never actually been printable. Gated below now.
    # Titles BEFORE the labels: _labels() treats whatever silk already exists as
    # occupied, so anything drawn after it is drawn on top of it.
    # No issue numbers. They were on the silk as "#747 #987" and are provenance
    # for whoever edits this file, not for whoever solders the board -- the
    # tracker is not something you can look up with a board in your hand, and
    # the numbers age worse than the board does. They live in this file's
    # docstring and in console_board_mount.json instead.
    # x 33, not 28: _silk() takes the text CENTRE, and the title has to clear
    # H4's pad at the left end of the bottom strip. Dropping the numbers only
    # shortens it inward from that centre, so the clearance can only improve;
    # the SILK gates below re-measure it as rendered either way.
    _silk(board, "SEGNO CONSOLE v3", 33.0, 95.5, 1.6)
    _silk(board, "MIDI IN: ISOLATED", 72.0, 95.5, 1.0)
    _labels(board, fps)

    # Poured on BOTH layers, not just B.Cu. With one pour, B.Cu routing chopped the
    # plane into pieces and three islands were left with no path back to the main
    # body -- DRC reported them as unconnected, which they were. A second pour on
    # F.Cu gives every island a route home through the stitching grid that is
    # already there, and it is what the layout guidance asks for anyway: a
    # continuous low-impedance return directly beneath each signal.
    #
    # BEFORE _check(), not after. THERMALS reads board.Zones(), so with the pours
    # created afterwards it looped over an empty list and could not fail: the gate
    # that exists to catch "SMD pads tied solid into a plane" would have waved
    # through exactly that.
    _pour_gnd(board, netmap[POUR_NET], pcbnew.B_Cu)
    _pour_gnd(board, netmap[POUR_NET], pcbnew.F_Cu)

    if quiet:
        global _QUIET
        _QUIET = True
        try:
            _check(fps, nets, board)
        finally:
            _QUIET = False
        return
    print("Layout assertions ...", end=" ")
    _check(fps, nets, board)
    print("ALL PASS")
    # No straight-line routing any more. It produced 37 crossings and 22 shorts:
    # pad-to-pad lines cannot dodge obstacles. The board is exported to Specctra
    # DSN and routed by Freerouting (see route_console_board.sh), per the repo's
    # pcb-layout skill. Placement quality is what makes that autoroute good --
    # "better placement in, cleaner autoroute out" -- which is why the ordering
    # and isolation gates above matter more now, not less.
    boxes = _drill_keepout(fps)
    n_vias = _stitch_gnd(board, fps, nets, netmap, boxes)
    n_vias += _stitch_grid(board, netmap[POUR_NET], fps, boxes)

    # NOT pcbnew.ZONE_FILLER here: in-process it segfaults with no wxApp. The
    # LED-strip generator hit the same wall and fills via kicad-cli instead --
    # `pcb drc --refill-zones --save-board` pours and checks in one pass.
    os.makedirs(OUT, exist_ok=True)
    board.Save(PLACED_PATH)
    write_mount_json()
    write_bom()
    print(f"placed {len(fps)} footprints | {n_vias} GND vias | "
          "2 GND pours (filled by kicad-cli)")
    return board


def write_bom():
    """A parts list, in the CSV shape the retired V1 board's BOM already used.

    The board had gerbers and no BOM. You cannot buy a board from gerbers alone --
    somebody has to order the parts, and "read them off the netlist" is how a build
    ends up with the wrong capacitor voltage.

    Two groupings, because the netlist's "value" means different things by part:
      * PASSIVES and ICs are grouped by value AND footprint -- the same 100nF at two
        lead pitches is two different purchases, and the same footprint at two
        capacitances certainly is.
      * CONNECTORS are grouped by FOOTPRINT, with their roles in the comment. Their
        value is a role name (FSW_STOP, MIDI_IN), so grouping by it lists the same
        13 identical 2-pin JSTs as 13 separate things to buy.

    Mounting holes are not in it. They are holes.
    """
    comps, _nets = parse_netlist(NETLIST)
    parts, conns = {}, {}
    for ref, (_lib, fp, val) in comps.items():
        if "MountingHole" in fp:
            continue
        (conns if ref.startswith("J") else parts).setdefault(
            fp if ref.startswith("J") else (val, fp), []).append((ref, val))

    rows = []
    for (val, fp), items in parts.items():
        rows.append((val, [r for r, _v in items], fp))
    for fp, items in conns.items():
        roles = ", ".join(v for _r, v in sorted(items, key=lambda i: _ref_key(i[0])))
        rows.append((roles, [r for r, _v in items], fp))

    path = os.path.join(HERE, "fab", "segno_console_board_bom.csv")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("Comment,Designator,Footprint,LCSC,Qty,Type\n")
        for comment, refs, fp in sorted(rows, key=lambda r: (-len(r[1]), r[2])):
            refs = sorted(refs, key=_ref_key)
            fh.write('"%s","%s",%s,,%d,Component\n'
                     % (comment or "?", ",".join(refs), fp, len(refs)))
    return path


def write_mount_json():
    """Publish the outline and the M3 pattern for the enclosure to drill against.

    The mirror image of rear_io_stations.json, which the enclosure writes and
    console_board.py reads. That one flows panel -> board because the panel owns
    where a connector sits; this one flows board -> panel because the BOARD owns
    where its own holes are, and the plate has to follow.

    It exists because the two drifted: the plate was drilling an 85 x 87 rectangle
    measured off the retired V1 board while this board put its holes on 89.5 x
    89.5, and nothing was watching. Neither part had been ordered, so it cost
    nothing -- once, and only because someone thought to look.
    """
    path = os.path.join(OUT, "console_board_mount.json")
    holes = {ref: PLACEMENT[ref][:2] for ref in ("H1", "H2", "H3", "H4")}
    payload = {
        "source": "console_board_pcb.py",
        "board": "segno console board v3 (#747, #987)",
        "outline_mm": [BW, BH],
        "hole_pattern_mm": [BW - 2 * MOUNT_INSET, BH - 2 * MOUNT_INSET],
        "hole_inset_mm": MOUNT_INSET,
        "hole_drill_mm": 3.2,
        "holes_mm": {ref: [round(x, 3), round(y, 3)] for ref, (x, y) in holes.items()},
        "chassis_bond_hole": "H1",   # see docs/design/console-grounding-and-bonding.md
    }
    os.makedirs(OUT, exist_ok=True)
    with open(path, "w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
    return path


def _drc_json(path, report):
    """Fill the zones, run DRC, and read the result back as a dict."""
    subprocess.run([KICAD_CLI, "pcb", "drc", "--refill-zones", "--save-board",
                    "--format", "json", "-o", report, "--severity-all", path],
                   capture_output=True, text=True)
    with open(report) as fh:
        return json.load(fh)


def prune_dangling_vias(path=BOARD_PATH, rounds=4):
    """Delete stitching vias that the FILL left connected to nothing, then re-fill.

    The stitching lattice is placed before Freerouting runs, because the vias have to
    be obstacles it routes around. Which of them end up useful is decided much later,
    by the fill: routing chops the pour into islands, ISLAND_REMOVAL_MODE_ALWAYS
    deletes the fragments, and any via that sat in one is left joined to nothing on
    either layer -- 31 of them. That cannot be predicted at placement time from
    geometry alone, so it is not predicted: the board is poured, KiCad is asked which
    vias are dangling, and those are removed.

    Deleting one can strand another (the island it was holding up may itself go), so
    this repeats until a pour comes back with none left.
    """
    report = os.path.join(OUT, "drc.json")
    for _round in range(rounds):
        drc = _drc_json(path, report)
        bad = {i["uuid"] for v in drc.get("violations", [])
               if v["type"] == "via_dangling" for i in v.get("items", [])}
        if not bad:
            return 0
        board = pcbnew.LoadBoard(path)
        doomed = [t for t in board.GetTracks()
                  if t.GetClass() == "PCB_VIA" and t.m_Uuid.AsString() in bad]
        for t in doomed:
            board.Remove(t)
        board.Save(path)
        print(f"   pruned {len(doomed)} dangling stitching vias")
    return len({i["uuid"] for v in _drc_json(path, report).get("violations", [])
                if v["type"] == "via_dangling" for i in v.get("items", [])})


def check_routed_board(path=None):
    """Fab gates that can only be asked of the ROUTED board. Raises SystemExit.

    Run from route_console_board.sh before it plots, and from export(). Neither the
    placement gates nor DRC cover these: DRC checks the board against its own rules,
    and these check the board against the FAB and against the current budget, which
    are constraints KiCad has never been told about.
    """
    _b = pcbnew.LoadBoard(path or BOARD_PATH)
    # REFUSE to plot an unrouted board. Running this module without --no-export
    # produced a JLCPCB-ready zip, "ALL PASS", "0 violations" and exit 0 from a board
    # with ZERO tracks and 80 unconnected items: build() stopped routing when that
    # moved to route_console_board.sh, and --exit-code-violations counts violations
    # only -- never unconnected_items. That is the one failure that reaches a fab.
    #
    # Tracks on a SIGNAL net, not just any track: the placed board now carries a stub
    # from every ground pad to its stitching via, so "has tracks" stopped being the
    # same question as "has been routed".
    if not [t for t in _b.GetTracks()
            if t.GetClass() != "PCB_VIA" and t.GetNetname() != POUR_NET]:
        raise SystemExit("FAB: board has no routed signals. Routing lives in "
                         "route_console_board.sh; run that.")
    # The rails, measured on the copper that is about to be plotted. Track width is
    # set in the DSN netclass, i.e. in route_console_board.sh -- three files away
    # from the current budget it has to satisfy -- and a constant here claiming
    # 1.0 mm sat next to rails that were 0.6 mm for the whole design. Numbers that
    # live somewhere else get checked HERE, on the real board, or not at all.
    thin = [(t.GetNetname(), ToMM(t.GetWidth())) for t in _b.GetTracks()
            if t.GetClass() != "PCB_VIA" and t.GetNetname() in PWR_NETS
            and ToMM(t.GetWidth()) < MIN_PWR_TRACK_W - 1e-9]
    if thin:
        raise SystemExit(
            f"FAB: {len(thin)} rail track(s) under {MIN_PWR_TRACK_W} mm, thinnest "
            f"{min(w for _n, w in thin):.2f} mm on {thin[0][0]} -- the WS2812 chain "
            "draws 1.56 A. Width comes from the DSN netclass in route_console_board.sh.")
    small = [(round(ToMM(t.GetWidth(pcbnew.F_Cu)), 3), round(ToMM(t.GetDrill()), 3))
             for t in _b.GetTracks() if t.GetClass() == "PCB_VIA"
             and (ToMM(t.GetWidth(pcbnew.F_Cu)) < MIN_VIA_D - 1e-9
                  or ToMM(t.GetDrill()) < MIN_VIA_DRILL - 1e-9)]
    if small:
        raise SystemExit(
            f"FAB: {len(small)} via(s) smaller than {MIN_VIA_D}/{MIN_VIA_DRILL} mm "
            f"(e.g. {small[0][0]}/{small[0][1]}) -- Freerouting takes via size from "
            "the DSN netclass; set it in route_console_board.sh")
    # THE BOARD IMPLEMENTS THE NETLIST. Everything else here checks the board
    # against fab limits or against itself; this is the only check that asks
    # whether the copper about to be plotted is the CIRCUIT that was designed.
    # DRC comes close -- a dropped connection shows up as unconnected -- but it
    # compares the board to its own internal ratsnest, which came from the same
    # import that could have gone wrong.
    _comps, _nets = parse_netlist(NETLIST)
    want = {(ref, str(pad)): name for name, nodes in _nets.items()
            for ref, pad in nodes}
    got, missing = {}, []
    for fp in _b.Footprints():
        for p in fp.Pads():
            if p.GetNumber():
                got[(fp.GetReference(), p.GetNumber())] = p.GetNetname()
    for node, name in sorted(want.items()):
        if node not in got:
            missing.append(f"{node[0]} pad {node[1]} ({name}) is not on the board")
        elif got[node] != name:
            missing.append(f"{node[0]} pad {node[1]} carries {got[node]!r}, "
                           f"the netlist says {name!r}")
    if missing:
        raise SystemExit("FAB: the board does not implement the netlist -- "
                         + "; ".join(missing[:4])
                         + (f" (+{len(missing) - 4} more)" if len(missing) > 4 else ""))
    # Silk that the fab will not print, checked on the plotted article rather than on
    # the objects build() happened to create.
    for fp in _b.Footprints():
        for t in (fp.Reference(), fp.Value()):
            if not (t.IsOnLayer(pcbnew.F_SilkS) and t.IsVisible()):
                continue
            if ToMM(t.GetTextThickness()) < FAB_MIN_SILK_STROKE - 1e-9:
                raise SystemExit(
                    f"FAB: {fp.GetReference()}'s '{t.GetText()}' is stroked at "
                    f"{ToMM(t.GetTextThickness()):.3f} mm, under the fab's "
                    f"{FAB_MIN_SILK_STROKE} mm")
    return _b


def export():
    check_routed_board()
    # DRC first: it is what pours the zone (--refill-zones --save-board), so
    # plotting before it would ship gerbers with an empty ground plane.
    drc = subprocess.run([KICAD_CLI, "pcb", "drc", "--refill-zones", "--save-board",
                          "--severity-all", "--exit-code-violations", BOARD_PATH],
                         capture_output=True, text=True)
    tail = [ln for ln in drc.stdout.splitlines() if ln.strip()][-4:]
    print("DRC:", " | ".join(tail) if tail else "(clean)")

    gerber_dir = os.path.join(OUT, "gerbers")
    shutil.rmtree(gerber_dir, ignore_errors=True)
    os.makedirs(gerber_dir)
    subprocess.run([KICAD_CLI, "pcb", "export", "gerbers", "--no-protel-ext",
                    "--layers", FAB_LAYERS, "-o", gerber_dir + "/", BOARD_PATH],
                   check=True, capture_output=True)
    subprocess.run([KICAD_CLI, "pcb", "export", "drill",
                    "--format", "excellon", "--excellon-separate-th",
                    "-o", gerber_dir + "/", BOARD_PATH],
                   check=True, capture_output=True)
    zip_base = os.path.join(OUT, "segno_console_board_gerbers")
    # make_archive truncates, unlike `zip -r`; see the note in route_console_board.sh
    shutil.make_archive(zip_base, "zip", gerber_dir)
    print(f"wrote {zip_base}.zip")

    return drc.returncode


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        print("Negative controls:")
        sys.exit(0 if _selftest() else 1)
    if "--check-routed" in sys.argv:
        check_routed_board()
        print("   fab checks on the routed board: PASS")
        sys.exit(0)
    if "--prune-vias" in sys.argv:
        # Post-fill, so it runs from route_console_board.sh after the SES import,
        # not from build(): nothing here can be known until the board is poured.
        sys.exit(1 if prune_dangling_vias() else 0)
    build()
    if "--no-export" not in sys.argv:
        sys.exit(export())
