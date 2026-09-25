<!-- cspell:words XIAO NeoPixel Seeed VBUS castellations HASL UF2 Taiyo -->
# Ring carrier — first fabrication

This is the new XIAO ring/encoder carrier. J3 and J4 are alternative direct
footprints for purchased 24-LED and 16-LED modules; J2 exposes +5 V, GND, DIN
and DOUT for the selected external 40-LED strip in its own housing. The current
old console drives its strip through a passive encoder assembly instead.
Keep those hardware generations and their firmware pin maps separate.

The ring carrier is an 80 mm circular, two-layer FR4 board, 1.6 mm thick with
1 oz copper. Order **white solder mask and black silkscreen**, lead-free HASL,
tented vias and five individual boards. No stencil, assembly, controlled
impedance, edge plating or castellated-hole service is needed.

White replaces the earlier purple finish to reduce coloured reflections
around the LEDs. The purchased NeoPixel module retains its own board colour.
See [Taiyo's discussion of white masks for LEDs](https://www.taiyo-america.com/index.php/media-resources/news/solder-mask-led-applications-formulation-101/).

The September 25 full-white export supersedes the September 24 ZIP. It adds
a dedicated 1.5 mm power feed to J2 and three parallel ground-return vias,
retaining the two-layer, 1 oz construction and all component positions.
The console feed is upgraded with it. See the
[40-pixel verification](../../docs/reviews/ring40-full-white-1072/verification.md).
The retained hole allowances include 1.10 mm
holes for J1's JST XH pins and 1.25 mm holes at J3/J4 for the loose module
support pins. Keep these allowances when updating footprints.

## Assembly

- Connect the selected 40-LED strip to J2: 1 = +5 V, 2 = GND, 3 = DIN;
  leave DOUT disconnected. Use 22 AWG supply/return leads and strain relief.
  Alternatively fit one 24-LED module at J3 or one 16-LED module at J4, with
  firmware matching that LED count. Populate only one LED option.
- Match the loose support pins to the purchased ring's own holes. Its holes
  still constrain the pin stock even though the carrier now has more allowance.
- Solder the XIAO RP2350 module to U1's castellated pads. Discrete parts are
  through-hole. The encoder is ALPS EC11E18244AU, and the level shifter is a
  74AHCT125 in DIP-14. Observe diode and electrolytic polarity.
- J1 connects straight through to console J6: 1 = +5 V, 2 = GND,
  3 = console TX to ring RX, 4 = ring TX to console RX. Use 22 AWG for power
  and ground with the specified JST XH contacts.
- The carrier snap-mounts; it has no screw mounting holes.

The 40-pixel full-white design budget is 2.4 A for LED channels plus a 40 mA
idle allowance. The console connector allows a further 200 mA ring-controller
budget. Existing firmware brightness and animations are unchanged; the PCB
does not depend on their limit. The shared 10 A AUX supply is not sized for
all 120 LEDs and both screens at their simultaneous maximum. See the
[system power budget](../segno_wiring.md).

## Programming

Unplug **J1 before connecting the XIAO USB cable**. Remove USB before reconnecting
J1. D1 prevents USB from powering the AUX harness, but it does not prevent live
AUX power from reaching a connected USB host. See the
[Seeed schematic](https://files.seeedstudio.com/wiki/XIAO-RP2350/res/Seeed-Studio-XIAO-RP2350-v1.0.pdf).

Install the separate ring UF2 using XIAO BOOTSEL. Its source is
`firmware/ring_board`; the console's SWD updater does not program this module.
No USB cable is needed on the ring during normal operation.

The electrical checks, firmware pin map and KiCad DRC pass. Actual encoder,
LED and assembled-system behavior will be checked on the first assembled board.
No further owner measurements are required before bare-PCB fabrication.
