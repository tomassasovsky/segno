<!-- cspell:words XIAO NeoPixel Seeed VBUS HASL -->
# White ring PCB — order verification, 24 September 2026

The ring carrier was missing from the initial two-board order folder. It is
now the third design. The owner selected white solder mask to reduce coloured
reflections around the LEDs; both faces use white mask and black silkscreen.
The stackup helper preserves that selection for the canonical ring filename.

Two independent reviews covered physical assembly and the circuit/firmware
interface. They identified tight J1 and module-support holes, now enlarged:
J1 0.95 → 1.10 mm; J3/J4 1.00 → 1.25 mm. J1 retains its existing pads with
0.30 mm nominal minimum annulus; J3/J4 retain 1.90 mm pads with 0.325 mm annulus.
Both local module-support footprints are updated. This does not change the
holes in the purchased LED module; choose pins that fit that module.
[JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf),
[header pin tolerance example](https://www.we-online.com/components/products/datasheet/61304011121.pdf),
[JLCPCB tolerances](https://jlcpcb.com/capabilities/pcb-capabilities).

The exact board comparison permits only four colour fields, twelve drills and
regenerated filled-zone polygons. All authored tracks, vias, placements, pad
copper, net assignments and outline remain unchanged. KiCad's zone refill can
re-tessellate polygon vertices; those filled polygons are excluded from the
authored-geometry equality check, and the resulting board passes DRC.

- KiCad 10.0.4, refilled zones, all DRC severities: zero violations and zero
  unconnected items.
- Exact circuit netlist parity: 13 nets and 63 connected pads.
- Fresh generator ERC: zero electrical errors and warnings. All six deliberate
  circuit-fault controls pass.
- Console J6 to ring J1: +5 V, GND, console TX/ring RX, ring TX/console RX,
  pin-for-pin. Firmware and Seeed variant match D0 LED, D1/D2 encoder,
  D3 button, D10 TX and D9 RX.
- White-mask pad-opening separation is at least 0.54 mm, above JLC's stated
  0.13 mm requirement. All 20 vias are tented.
- Native top and bottom renders were inspected with components visible.
  The purchased LED module's colour is independent of the carrier mask.

The programming instructions now require disconnecting J1 before attaching
the XIAO USB cable. Its VBUS pad is directly connected to USB power; the
existing diode blocks USB-to-AUX flow, but does not isolate the opposite
direction. This is a service connection rule, not an additional fabrication
change. Stale three-wire and missing-firmware prose in the generator is fixed.
[Seeed schematic](https://files.seeedstudio.com/wiki/XIAO-RP2350/res/Seeed-Studio-XIAO-RP2350-v1.0.pdf).

Order five bare PCBs, 80 mm diameter, two-layer FR4, 1.6 mm, 1 oz, white/black,
lead-free HASL. The new ZIP supersedes older ring exports. Assembly validation
remains separate from first-fabrication readiness; no order has been placed.

Final native PCB SHA256:
`3f3c358761979b5cbe2cf3301113f75ef2e8fb3a259d4150858d79a3a0f3ce02`.
Upload `segno-ring-white-gerbers.zip`, SHA256:
`e79e97d122088814b1ee34b1e33ecbe281fb9ee7a6f27c9b05a437ad16fccc74`.
The ZIP has ten files, each verified against its loose manufacturing export.
It is identical to the updated canonical `fab/segno_pedal_ring_gerbers.zip`.
