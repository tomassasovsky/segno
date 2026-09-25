# Screen-power revision F verification — issue #1072

<!-- cspell:words DigiKey MOSFETs unassembled -->

Revision F adds four 3 mm radius corners to the hand-soldered screen-power
PCB and an itemized component cost estimate. It remains an unassembled
prototype; this revision does not implement Pi shutdown software or qualify
the hardware for production.

## CAD changes

The board retains its 64 × 76 mm overall dimensions, 37 populated through-hole
parts, four copper layers and four M3 mounting holes. Hole centers remain
(4, 4), (60, 4), (4, 72) and (60, 72) mm.

The outline now consists of four tangent straight edges and four quarter-circle
arcs. Both the placement source and routed board use the same generator. Ground
zones were refilled against the new outline. Board and schematic revision
labels read F.

[The geometry comparison](layout-parity.json) verifies identical footprint
positions, orientations, pad geometry and nets, tracks and vias against the
saved revision E files. The component records, BOM and circuit netlist are
byte-identical. Console and ring boards were not changed.

Routed board SHA-256:
`b1a404b92166151ec2b43589d48c5fb3be94028b295cf2be9c71cd7ab7630e91`.

## Observed verification

- KiCad 10.0.4 native ERC and DRC pass with zero findings and zero unconnected
  items, including warnings and exclusions.
- Pin/net parity, power separation, physical USB connectivity, power widths,
  console control continuity and all 37 populated component models pass.
- All 16 existing deliberate fault checks pass on revision F. Two additional
  outline probes reject a missing arc and a malformed arc.
- Python compilation, scoped whitespace checks and documentation spelling pass.
- Author visual inspection of top, bottom and perspective renders confirms
  the rounded edges, populated components and readable connector labels.
- Fresh Gerbers, drills, STEP assembly, populated renders, PDFs and the portable
  native KiCad project were regenerated from revision F. The cost estimate is
  included in the package and its source/output hashes.

Evidence: [CAD and fault checks](validation.json),
[outline fault probes](geometry-faults.json),
[package verification](package-verification.json).

Revision E's independent reviews remain evidence for that earlier revision.
This small outline/documentation revision received the author checks above;
no new independent review is claimed.

## Costs and power-off behavior

The [component estimate](../../../hardware/kicad/screen_power/COSTS.md) accounts
for every populated BOM reference: 37 parts, 21 unique ordering numbers,
**US$32.42** at published single-unit distributor prices checked on
22 September 2026. A US$23–48 external wiring and mounting allowance is
separate; bare PCB fabrication, shipping, taxes and assembly labor are excluded.
DigiKey currently has no immediate stock of the selected power MOSFETs;
their published price is an estimate, not an available basket.

With GPIO17 low or disconnected, the shared switched supply removes both
main-screen power and touch VBUS, and the relays disconnect USB data. Pi host
VBUS does not feed the screens. The dedicated screen buck may stay powered.

A software-halted Pi that still has input power needs GPIO17 explicitly
released or lowered before HDMI stops, with sufficient measured discharge
time. That software work remains outstanding. Residual HDMI power, cables,
USB operation, power/thermal behavior and enclosure fit still need actual
hardware checks. See the [board notes](../../../hardware/kicad/screen_power/README.md).
Issue #1072 remains `autonomy:blocked-verify`.
