<!-- cspell:words unassembled onsemi Nexperia pulldown pulldowns DRC ERC SKiDL SHA GPIO MPN -->
# Screen-power revision B verification — #1072

Revision B supersedes the 130 × 120 mm revision A carriers at `c275f94a`.
It removes the external USB-C evaluation modules and native USB-C source
controllers. The hand and factory variants now share a discrete 5 V switch
and two RF touch-data relays. Existing console J25 and routed console/ring
outputs are unchanged by this revision.

## Measured result

| Property | Revision A hand | Revision B hand | Revision A factory | Revision B factory |
| --- | --- | --- | --- | --- |
| Board dimensions | 130 × 120 mm | 72 × 84 mm | 130 × 120 mm | 72 × 74 mm |
| Board area | 15,600 mm² | 6,048 mm² | 15,600 mm² | 5,328 mm² |
| Area reduction | — | 61.2% | — | 65.8% |
| Populated board footprints, including four mounting holes | 56 | 41 | 72 | 41 |
| External electronic modules | 2 | 0 | 0 | 0 |
| Longest USB trace | 38.624 mm | 28.551 mm | 39.433 mm | 28.551 mm |
| Largest USB pair mismatch | 0.719 mm | 0.696 mm | 1.536 mm | 0.696 mm |
| USB data vias | 0 | 0 | 0 | 0 |

There are 37 electronic components and four mounting-hole footprints on each
new board. The hand version has no surface-mount footprints or pads. Its
through-hole components include exact onsemi 2N7000 relay drivers. The factory
version uses the documented Nexperia SMD equivalents and a 3 mm source-to-source
power link. Ground return planes remain on both inner layers; all USB data
tracks are on bottom copper.

## Observed checks

`hardware/kicad/screen_power/validation.json` records fresh KiCad 10 native
ERC and DRC for both variants: zero errors, warnings, exclusions or unconnected
items. It includes full native schematic/netlist/PCB pad parity, USB copper
continuity and pair lengths, console GPIO17 copper continuity, four-layer
geometry, assembly type and independent electrical contracts.

The physical power-path check removes undersized copper and signal vias from
fresh board copies and asks KiCad to establish the required connections.
Factory common-source copper must remain connected at 3 mm; the hand design's
short transistor-pin necks require at least 1.5 mm. Main output branches need
2 mm and touch output branches 0.8 mm. This verifies geometry, not thermal
performance or a certified current rating.

All eleven hand and eight factory deliberate fault checks pass: USB/control
cuts, a host-power bridge, narrowed main power copper, unsupported relay or
driver, wrong resistor tolerance and a weak pulldown are detected. The hand
checks additionally reject an SMD footprint, a surface-mount pad and an
undersized power-transistor lead hole. The selected TO-220 footprint has
1.4 mm finished holes and at least 0.25 mm annulus, checked against maximum
manufacturer lead dimensions. The test
reviewer also independently narrowed the common-source track and confirmed
rejection in both variants.

Python compilation, shell syntax and changed-file whitespace checks pass.
Changed prose is checked with the repository spelling configuration and the
worktree-ignore bypass. The conventions reviewer regenerated the circuit in
an independent temporary copy and verified matching netlists, BOMs, component
records and native sheets. The later schematic pagination change moves only
flags and mounting holes to the shared-power sheet and was re-exported and
visually checked before final ERC/parity verification.

## Visual and export review

The native top renders and schematic PDF pages were inspected. Component
courtyards have no overlaps. USB connectors face opposite edges, with relays
between them; the main switch is by the power input and branch fuses by outputs.
The power-source sheet holds mechanical/flag symbols so the root's control
circuit and sheet links do not overlap. The custom USB/RF/fuse parts do not all
have supplied 3D models: the assembly drawing and manufacturer dimensions
remain authoritative for those components.

Both `hand/fabrication/` and `factory/fabrication/` packages were rebuilt only
after fresh native checks. Each includes Gerbers and drills, schematics and
assembly PDF scaled to the page in black and white, exact-part BOM, external harness BOM, position files, STEP,
top/bottom renders, validation and a SHA-256 manifest. Every output hash and
Gerber ZIP member is checked before the desktop copy is delivered. The final
source hashes are recorded in each manifest; hashes, rather than an earlier
review result, identify the files being delivered.

## Independent review

The five required build roles are recorded under `raw/`: architecture, test
quality, conventions, simplicity and readiness. Their fixes include the
isolating driver diode, source-local gate pull-up, supported-component and
resistor-tolerance guards, physical power-width checks, pulldown leakage
bounds, and the wider factory source link. The redundant fuse-routing branch
suggestion was also resolved. The cleanup reviewer exercised 16 independent
native geometry cases for removal of a narrower router tail contained wholly
inside a wider trace.

## Qualification boundary

These are unassembled prototype designs. Actual power-harness connector
wiring still requires confirmation; existing USB-C attachment signaling must
be preserved where present. Thermal/current capability, fuse/inrush behavior,
USB operation and suspend, residual HDMI power, cable ratings and enclosure
fit remain physical acceptance items. Early GPIO disable before HDMI teardown
still needs device software integration and measured timing. No successful
blue-screen elimination or USB compliance is inferred from CAD. Issue #1072
remains `autonomy:blocked-verify`; nothing has been merged or deployed.
