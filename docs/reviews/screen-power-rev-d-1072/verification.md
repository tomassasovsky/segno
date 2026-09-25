# Screen-power revision D verification — issue #1072

Revision D commits both PCB variants to four vertical, through-hole JST XH
four-pin connectors in place of the four USB sockets. The owner selected the
ready-made direct USB-A, USB-C and Micro-USB cable options on 2026-09-22.
The design is CAD verified; assembled hardware qualification remains pending.

## Connector and circuit change

J101, J102, J201 and J202 use the stock KiCad
`Connector_JST:JST_XH_B4B-XH-A_1x04_P2.50mm_Vertical` footprint and
B4B-XH-A(LF)(SN) headers: 2.50 mm pitch and 0.95 mm plated drills.
All four use pin 1 VBUS, pin 2 D−, pin 3 D+, pin 4 ground, with numbered
bottom-side labels. The four sockets' separate shield pads are removed;
the purchased four-wire cables' shield termination remains a sample check.
The native schematics use passive four-pin connector symbols, with explicit
host-supply flags replacing the USB-B symbol's power-output declarations.

The separate main-power connectors J1/J103/J203 remain JST VH two-pin.
The two-wire GPIO17/GND connection to console J25, relay circuit, fuses,
power switch, board outlines and mounting holes are unchanged from revision C.
Console and ring files were not changed.

The four USB pairs on each board are manually routed in straight lanes with
symmetric fanouts. Tracks remain 0.26 mm on B.Cu with a 0.16 mm coupled gap,
no data vias and continuous inner ground planes. Host sections are 24.7959 mm;
screen sections are 29.5959 mm. Paired lengths agree within 0.000001 mm of
reported geometry. This does not establish actual 90-ohm impedance or USB
compliance. The wide front-side power trunk is retained.

## Observed verification

| Check | Hand | Factory |
| --- | --- | --- |
| Native KiCad ERC findings | 0 | 0 |
| Native KiCad DRC findings | 0 | 0 |
| Unconnected items | 0 | 0 |
| Populated parts with resolving STEP assignments | 37 | 37 |
| Passed deliberate fault injections | 16 | 13 |

[Validation](validation.json) records exact source hashes, native schematic /
netlist / PCB parity, pin-level supply boundaries, physical USB connectivity,
minimum power-copper connectivity, console control continuity, assembly checks
and numerical drive margins. A new XH check rejects wrong pitch or inadequate
through holes; fault injection confirms a 2.54 mm spacing error is detected.
The hand variant has no surface-mount pads or components.

All 19 bundled STEP files parse into valid solids with positive volume;
see [model parsing](model-solids.json). The XH4 model comes from KiCad's
Connector_JST library with attribution retained. The unused custom USB socket
models, footprint and symbol generator were removed. Three custom assembly
models remain: relay, fuse and VH connector.

Author inspection covered both top renders, hand perspective and bottom
pin labels / routing. Exports include portable native projects, schematics,
assembly drawings, populated images, STEP, copper plots, BOMs and Gerbers.
All 76 listed package files and 68 source hashes per variant were checked
against their manifests after export. This is local author verification;
revision C's independent review reports do not cover these subsequent changes.

## Cable purchase and physical boundary

The purchase list is two USB-A male to XH4 cables, one USB-C male to XH4,
and one Micro-USB male to XH4. Keep one separate main-power lead per screen.
The owner reports 28 AWG conductors. These data cables are not specified for
the screens' full power loads. Touch current, voltage drop and temperature
must be measured with both power and touch connected; the screen may join
its supply inputs internally. A fuse is not an active current limiter.

The seller's “XH2.54” label does not change the chosen 2.50 mm JST footprint.
Check actual mating fit, continuity/polarity, shield termination and USB-C
source configuration before connecting equipment; re-pin the housing if its
wire order differs. The UPERFECT path still requires 480 Mbps despite its
12 Mbps touch controller. Test both Type-C plug orientations and reconnect,
suspend, wake, hot relay restart, inrush and simultaneous screen startup.
Thermal behavior, fault coordination, HDMI residual power and enclosure fit
remain physical gates. Early GPIO enable / shutdown-before-HDMI software
remains outstanding under issue #1072 (`autonomy:blocked-verify`).

The [assembly README](../../../hardware/kicad/screen_power/README.md) is the
wiring authority and includes the exact selected cable variants and links.
