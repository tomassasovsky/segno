<!-- cspell:words unassembled unswitched fanout anbest USBFireWire ASCS AMCB ASCH AWG VBUS overmolds pigtail pigtails SXH XHP Qualtek UL2725 Mbps APROTII UPERFECT -->

# USB cable assessment for Rev M

2026-09-26. This is a cable and assembly decision, not a claim that an
unassembled USB link has passed signal-integrity or compliance testing.

Keep J101, J102, J201 and J202 as four-position JST XH connectors. Add one
nearby through-hole GND solder pad per connector for its cable shield.
This preserves the purchased connector type and provides a repair path if
an existing cable proves unsuitable. It does not require replacing every
purchased lead before ordering the PCB.

## Purchased cables and documented fallback

The existing eBay leads are two 300 mm USB-A tails, one 250 mm USB-C tail and
one 300 mm Micro-B tail. Their listing reports 28 AWG, but supplies no
manufacturer drawing establishing twisted-pair construction, shielding,
480 Mbps performance or the USB-C attachment resistor. These are unknown
properties, not evidence that the cables are defective. The existing
working Pi-to-screen USB cables are also possible donors if their actual
length, shielding, data pair and conductor sizes suit this assembly.

The documented replacement option is **one of each donor below**, cut into
four tails. These are alternatives to usable existing leads, not additional
mandatory purchases. Keep both original USB plug overmolds intact.

| Donor | Manufacturer documentation | Tails obtained |
| --- | --- | --- |
| [USBFireWire RR-ASCS-36GC](https://www.usbfirewire.com/parts/rr-ascs-xxgc.html), 914 mm A to C | USB 2; 56 kΩ resistor; double shielding; 24 AWG power/ground and 28 AWG data pair; −30 to +80 °C; 20 mm minimum bend radius; 5 mm jacket | One A tail ≤300 mm and one C tail ≤250 mm |
| [USBFireWire RR-AMCB-72G](https://www.usbfirewire.com/parts/rr-amcb-xxg.html), 1829 mm A to Micro-B | USB 2; double shielding; 24 AWG power/ground and 28 AWG data pair; −30 to +80 °C; 20 mm minimum bend radius; 5 mm jacket | One A tail ≤300 mm and one Micro-B tail ≤300 mm |

The manufacturer lists the donors in stock at **US$17.50 + US$12.95 =
US$30.45**, before shipping and taxes, on the review date:
[A–C availability](https://www.usbfirewire.com/straightatoc.html) and
[A–Micro-B availability](https://www.usbfirewire.com/u_microb_cables_angled.html).
The longer Micro-B donor leaves trimming allowance; the 610 mm version is
unnecessarily tight for two nominal 300 mm tails including termination.

The straight donor pages describe USB 2 and a data pair, but do not publish
an eye diagram, twist pitch, impedance tolerance or a literal 480 Mbps
rating. Do not turn that into a claim of measured high-speed qualification.
The same manufacturer's [RR-ASCH-36GC angled A–C version](https://www.usbfirewire.com/parts/rr-asch-xxgc.html)
explicitly advertises 480 Mbps, 56 kΩ, double shielding, 24/28 AWG and
−30 to +80 °C. It is another source option only where the angled plug fits;
its wording does not certify the straight model or the modified harness.

A cheaper [Qualtek 3025010-03 donor drawing](https://www.qualtekusa.com/images/Cable%20Assemblies/PDF_2/3025010-03.pdf)
documents a shielded 28 AWG pair plus two 28 AWG conductors. Its drawing
provides no assembly operating-temperature range, so it is not the selected
fallback for the enclosure's 60 °C design condition. Do not substitute a
30 AWG data cable into the selected 28–22 AWG XH contacts.

## Pin map, shield and attachment

Use XHP-4 housings and SXH-001T-P0.6 contacts, with matching crimp tooling
and insulation sizes from the [JST XH specification](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).
Both the 24 AWG power conductors and 28 AWG data pair of the selected donors
fall within that contact's conductor range. Identify each conductor by its
USB contact, not by assumed wire colors or a mirrored connector view.

| XH cavity | Signal | USB-A pin | Micro-B pin | USB-C retained factory connection |
| --- | --- | --- | --- | --- |
| 1 | VBUS | 1 | 1 | VBUS group and existing 56 kΩ attachment pull-up |
| 2 | D− | 2 | 2 | D− |
| 3 | D+ | 3 | 3 | D+ |
| 4 | GND | 4 | 5 | GND group |
| Separate adjacent PCB pad | Shield | Shell | Shell | Shell |

Micro-B ID pin 4 stays unconnected. Preserve the Type-C plug's internal
connections: legacy A-to-C assembly uses 56 kΩ ±5% from CC to VBUS, with
shield and GND joined in the plugs. See USB Type-C specification
[Table 3-13, published copy hosted by TI](https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/1008/USB-Type_2D00_C-Specification-Release-1.3.pdf).
A C-to-C donor has a different attachment arrangement and is not a substitute.
The retained C plug's VBUS and pull-up are supplied by J102's switched touch
rail; do not reconnect either to the Pi's unswitched VBUS.

Keep foil/braid and pair twist to the connector fanout, aiming for ≤10 mm
of exposed pair and shield drain. This is an assembly target, not a USB
certification limit. Keep the drain short and broad where practical, sleeve
it against neighboring pads, and bond it to the adjacent GND pad. Retain a
separate pin-4 ground conductor; the shield is not the power return.
Strain-relieve the jacket independently of the four crimps and solder pad.
A cable with no shield cannot acquire one merely by adding a drain wire.
Repinning can correct the XH order but cannot correct an absent data pair,
shield or incorrect resistor hidden in a sealed C plug.

In Rev M, Pi VBUS is only the approximately 50 µA host-presence sense input.
The device-side touch feed remains limited by its separate 500 mA operating
allocation. Each screen's main supply continues through its separate
≤300 mm, 20 AWG-or-larger pair with 3 A-rated terminations. No donor data
cable replaces those main power leads.

## Touch-wire voltage drop

For a conservative 500 mA touch load, calculate both supply and return
conductors. The table uses nominal copper resistance at 20 °C of
0.2129 Ω/m for 28 AWG and 0.0842 Ω/m for 24 AWG, with a 0.00393/°C copper
coefficient. The 80 °C column is a calculation at the selected donors'
maximum published temperature, not a prediction that the cable reaches it.

| Device tail | Wire-loop drop at 20 °C | Wire-loop drop at 80 °C | Wire-loop loss at 80 °C |
| --- | --- | --- | --- |
| 250 mm, 28 AWG | 53.2 mV | 65.8 mV | 32.9 mW |
| 300 mm, 28 AWG | 63.9 mV | 78.9 mV | 39.5 mW |
| 250 mm, selected 24 AWG power pair | 21.1 mV | 26.0 mV | 13.0 mW |
| 300 mm, selected 24 AWG power pair | 25.3 mV | 31.2 mV | 15.6 mW |

The XH supply/return contact pair adds 20 mV at 500 mA using the JST
20 mΩ-per-contact after-environment bound. USB plug contacts, crimp quality,
PCB copper, fuse and switch losses remain additional; the table is not a
complete device-voltage guarantee. The upstream A tail does not carry the
device's 500 mA through its VBUS conductor. Main-power wire losses are a
separate calculation. These figures support short 28 AWG touch leads; they
do not establish the construction or fault-current rating of an unknown lead.

## What the PCB revision establishes

The four shield pads provide an intentional termination without adding USB
sockets, XH5 connectors or extension adapters. Construction and pinout can
be established during normal harness assembly, with the donor option ready
if the purchased lead is unsuitable. Ordinary first-assembly USB operation
remains a qualification of the assembled system, not a prerequisite
prototype campaign. Cutting any certified donor and adding XH/PCB sections
does not transfer certification to the result: the
[USB-IF cable program](https://www.usb.org/cable_connector) excludes assemblies
with a non-USB connector at one end. No complete-link certification is claimed.
