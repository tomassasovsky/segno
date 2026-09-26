<!-- cspell:words microstrip fanouts antipads -->
# Screen power revision G: two copper layers

Issue: #1072. The owner required two layers, hand soldering and purple solder
mask. This revision replaces the four-layer revision F fabrication package.

The board is 68 × 76 mm with R3 corners, 37 populated through-hole components
and four M3 mounting holes. The 4 mm wider right edge carries the shared
4.5 mm power rail outside the USB paths. The right-hand holes move from
x = 60 to x = 64 mm. Circuit, BOM and connector pin assignments are unchanged.
The four non-polar fuses turn 180 degrees to face the relocated supply rail.

F.Cu and B.Cu are the only copper layers; both have filled ground pours.
USB uses 0.85 mm bottom traces with a 0.16 mm coupled gap and no data vias.
Front-side routing keepouts protect the reference copper beneath the pairs
and their fanouts. The relay drive paths are explicitly routed through the
contact-column gap so they do not cut that reference. Stitching joins the
outer ground pours. Main power paths use no vias.

KiCad 10.0.4's coupled-microstrip calculator gives 89.6448 ohms differential
at 1 GHz for 1.53 mm dielectric height, relative permittivity 4.4, 35 µm copper,
0.85 mm traces and a 0.16 mm gap. This is a nominal analytical estimate,
without solder mask or finite neighboring copper. The fabricator must confirm
the stack and finished geometry. Through-hole connector and relay fanouts
remain local discontinuities; USB compliance has not been established.

Validation comprises the complete rebuild, native ERC/DRC, schematic-netlist-
PCB pin parity, minimum continuous power width, no USB vias, matched pairs,
all 37 component models, through-hole assembly checks and 18 fault-injection
checks. Filled front ground is sampled every 0.1 mm beneath the center and
both edges of each data track, with only a 1.35 mm terminal exclusion for
through-hole antipads. Native DRC checks ground connectivity separately.
See [validation.json](validation.json) for measured geometry and input hashes.

The accompanying console label revision removes the bottom screen pinout text
and adds `SCREEN` on top. Its tracks, vias, zones and component positions are
preserved. See [console verification](../console-screen-label-1072/verification.md).

The board remains a prototype. Impedance, touch operation through the selected
cables and relays, voltage drop, inrush, thermal behavior and enclosure fit
require physical qualification. Early GPIO shutdown before HDMI teardown
also remains to be implemented and tested. KiCad checks do not establish
that the blue no-signal screen has been eliminated.
