# Console connector for the screen-power board — issue #1072

<!-- cspell:words XHP SXH -->

The owner requested the required connectors on the console. The existing
#1072 working design already includes J25, its route and its BOM entry.
This delivery verifies that implementation and refreshes a separate console
package; it does not add a duplicate connector or change the console circuit.

## Interface

J25 is a two-pin through-hole JST XH, **B2B-XH-A(LF)(SN)**, with 2.50 mm pitch.
It sits beside the lower part of the Pi ribbon connector. Its numbered
solder-side label is `SCREEN 1=GPIO17 2=GND`.

| Console | Screen board | Connection |
| --- | --- | --- |
| J25 pin 1 | J2 pin 1 | BCM GPIO17, Pi physical pin 11 via console ribbon J2 |
| J25 pin 2 | J2 pin 2 | Common ground |

Use one short 22 AWG two-wire lead, two XHP-2 housings and four
SXH-001T-P0.6 contacts. Wire by numbered pins and check continuity before
connection. The existing Pi ribbon stays direct.

Screen-power J1 receives its own branch from the dedicated AUX buck. The
screen current does not pass through console J3 or J25. No new USB connector
or screen-power distribution connector is required on the console.

## Verification and delivery

- Source netlist, routed pads and actual copper connectivity agree on
  Pi J2 pin 11 to console J25 pin 1; J25 pin 2 is ground.
- The matching screen revision F input is J2 pin 1 GPIO17 and pin 2 ground.
- Existing console fabrication checks and fresh KiCad 10.0.4 DRC pass, with
  zero violations and zero unconnected items.
- J25 has a through-hole footprint, a resolving 3D model and a BOM entry.
- The source PCB, placement, tracks, component records and netlist are
  unchanged. Its SHA-256 remains
  `d4a735337159ee083228dbfa23bc4f16c329b2a44fe26847d5a04fc99004b360`.
- Fresh Gerbers/drills, STEP assembly, assembly PDF and top/bottom populated
  renders accompany the native KiCad PCB/project and BOM. The native package
  bundles all 15 referenced component-model files; only their paths differ
  from the source PCB. The package also passes DRC.

[Validation and package hashes](validation.json) identify the exact source
and exported files. The author inspected the populated views and J25 label.
No new independent review is claimed for this packaging-only delivery.

The board remains a prototype. Actual harness fit, enclosure clearance and
electrical behavior still need physical validation. Early GPIO startup and
shutdown-before-HDMI software remain outstanding, as recorded in the
[screen-board guide](../../../hardware/kicad/screen_power/README.md).
