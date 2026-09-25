# Screen-power revision E verification — issue #1072

<!-- cspell:words Mbps autorouting -->

The owner authorized retaining hand-soldered assembly only and compacting the
screen-power board. Revision E is a completed, locally checked prototype CAD
design. Physical qualification remains pending; this is not a production release.

## Layout and scope

| Item | Revision D hand board | Revision E |
| --- | --- | --- |
| Outline | 72 × 84 mm | 64 × 76 mm |
| Board area | 6048 mm² | 4864 mm² (19.6% smaller) |
| Populated parts | 37 through-hole | 37 through-hole |
| Mounting | Four M3 holes | Four M3 holes, 4 mm from corners |
| Host USB trace length, each conductor | 24.7959 mm | 20.7959 mm |
| Screen USB trace length, each conductor | 29.5959 mm | 26.5959 mm |

Total PCB USB conductor length per path is 12.9% shorter. Each pair remains
matched, on bottom copper with no data vias, 0.26 mm tracks and a 0.16 mm
coupled gap above inner ground planes. Actual impedance and 480 Mbps USB
performance still require qualification with the selected stackup and cables.
The front copper carries the manually routed 4.5 mm shared power trunk,
2 mm main branches, 0.8 mm touch branches and short 1.5 mm transistor necks.

The upper control section is compacted, the input connector is at the upper
right, and two repeated channel blocks put Pi inputs on the left and screen
power/touch outputs on the right. Four-pin XH data connectors and two-pin VH
power connectors keep their existing pin maps. Component records and the BOM
are identical to revision D, including part numbers and pin-to-net assignments.
Console and ring routing are unchanged. The existing Pi ribbon stays direct;
console J25 supplies GPIO17 and GND to screen J2 through a two-wire lead.

The factory design, assembly branches and six unused surface-mount models are
removed. Only the hand board is generated. Exports no longer include an empty
SMD placement file or solder-paste stencil. Historical C/D review documents
and previously delivered packages remain historical evidence.

## Observed local verification

- Complete source → schematic → placement → critical routing → autorouting →
  cleanup → check → export build completed using KiCad 10.0.4.
- Native KiCad ERC: zero findings. Native DRC: zero findings and zero
  unconnected items, with errors, warnings and exclusions included.
- The native schematic, source netlist and finished PCB have exact pin/net
  parity. Board checks also cover host/screen supply separation, physical USB
  connectivity, minimum-width power paths and console control continuity.
- All 16 deliberate fault injections were detected, including a cut USB route,
  a cut console control trace, narrow power copper, a host power bridge,
  surface-mount parts/pads and insufficient through-hole drills.
- All 37 populated parts have resolving STEP assignments. All 13 retained
  STEP model files contain valid solids. Custom models are documented
  assembly envelopes, not manufacturer-certified component models.
- Python source compilation, shell syntax and scoped diff whitespace checks pass.
- Author visual inspection covers top, bottom and perspective populated views,
  connector labels, USB routing and component spacing. Mating cable assemblies
  and enclosure fit are not proven by the bare-board render.

[Validation](validation.json) records native reports, numerical assumptions,
measured track lengths, fault results and exact source SHA-256 hashes.
[Model parsing](model-solids.json) records the retained component model solids.
Independent review is recorded in [the consolidated review](review.md).

The hand-only package contains a portable native KiCad project, component models,
Gerbers/drills, BOMs, STEP assembly, schematic and assembly PDFs, copper plots,
and populated images. Its manifest binds every exported file to the inputs.
The package verification record is [package verification](package-verification.json).

## Remaining physical and system work

Final thick-wire main-power harness termination remains to be selected. The
selected 28 AWG XH USB leads are for the touch paths, not full screen power.
Check sample mating fit, pin polarity, shield termination, USB-C source-side
configuration and both USB-C plug orientations before device use. The UPERFECT
path needs 480 Mbps qualification because its 12 Mbps touch controller sits
behind a high-speed hub.

Both screens' startup current, voltage drop, temperature, fuse coordination,
suspend/wake, hot relay re-enable and HDMI residual power still need device
checks. No assembled-board measurements were performed. Early-boot GPIO enable
and shutdown-before-HDMI software remain outstanding under issue #1072,
which remains `autonomy:blocked-verify`.

See the [wiring and assembly notes](../../../hardware/kicad/screen_power/README.md)
for the connector map, selected cable variants and electrical limits.
