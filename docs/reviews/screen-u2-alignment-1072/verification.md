# Screen U1/U2 alignment

26 September 2026, issue #1072. This correction follows published revision
`2c27234ecf7825d67c812584bc7b82e39455fa38`. U2 was 1 mm below U1.
Both packages now share pin rows at **y=11.63 and 19.25 mm**, with their
body centers at **y=15.44 mm**.

| Item | Previous pin-1 position, mm | Final pin-1 position, mm | Rotation |
| --- | --- | --- | --- |
| U1 | (14.60, 19.00) | (14.60, 19.25) | 90° |
| U2 | (25.60, 20.00) | (25.60, 19.25) | 90° |

Moving U2 alone upward by 1 mm would overlap its stock courtyard with Q4's
by 0.110 mm. Instead, U1 moves down 0.25 mm and U2 moves up 0.75 mm.
No courtyard was trimmed and no DRC exception was added. References follow
their packages: U1 at (17.94, 10.07), U2 at (30.77, 15.45).

Claude Cloud supplied the placement/source change in `2547d7db`; local KiCad
replayed the affected critical copper using the existing routing generator.
The source has identical executable statements to Claude's patch, with its
comments shortened to verified facts. A claim that every capacitor connection
shortened was discarded: the C4 reservoir and C5 bypass legs each gain 0.25 mm,
while both C3 pump-capacitor legs shorten by 0.25 mm. The capacitors remain fixed.

## Geometry and electrical preservation

Independent measurements of the actual stock courtyard polygons give these
final minimum separations:

| Pair | Courtyard gap, mm |
| --- | --- |
| U2 to Q4 | 0.140 |
| U1 to C3 | 0.152509 |
| U1 to R1 | 0.310 |
| U1 to U2 | 0.350 |

Maximum body envelopes retain 0.965 mm between the two ICs and a conservative
0.925 mm between U2 and Q4. The closest moved copper pad pair, U2.3/Q4.1,
retains 0.880 mm. Both moved footprints clear every other stock courtyard.

Only the two IC placements, their references and their incident routes change.
Forty-three old critical front segments are replaced by 43 regenerated
segments in both the routed and placed boards. U2.2's rear termination follows
its pad; its newly exposed corner receives the existing 1 mm inside-radius
rounding. All other footprints, pads, models, vias, board outline, zone outlines,
USB traces and high-current power paths are preserved. Refilling leaves one
connected ground outline on each copper face.

The LMC7660 pins 1, 6 and 7 remain deliberately unconnected. Pin 8 retains
AUX_5V; the charge-pump capacitor, ground and negative-output nets retain their
original pin mapping. No component value, circuit, connector or wiring changes.

## Verification and current files

- Native KiCad DRC: zero violations and zero unconnected items, including
  stock courtyard rules; screen ERC and schematic/netlist/PCB mapping pass.
- All 56 existing screen fault controls pass in
  [native validation](screen-native-validation.json).
- The [source/native comparison](geometry-review.json) verifies the bounded
  copper replacement and exact preservation of unrelated geometry. No exposed
  two-segment turn exceeds 12 degrees; rerunning the finishing helper changes
  no geometry. Both local copper faces and the
  silkscreen alignment were visually inspected.
- Independent [circuit review](scoped-circuit-result.json) verifies all eight
  incident front paths and the [zone-free control return](control-component-result.json).
  [USB review](usb-review.json) finds identical segments and terminal topology,
  0.160 mm minimum pair gap and all 6,268 final ground-reference samples passing.
- The [screen package verification](screen-fabrication-verification.json)
  passes 409 assertions against fresh native exports, including exact archive
  membership, drill/pad mapping and stable source/artifact hashes.
- Console/ring artwork and ZIPs are byte-identical to the published baseline;
  [fresh verification](console-ring-fabrication-verification.json) passes
  175 assertions against the current source inventory.

A final [release consistency review](release-consistency.json) passes 313
read-only checks with no stale source, package, archive, preview or delivery
pointer. The [layout review](layout-review.md) records the final geometry scope.

The [current three-board archive manifest](../pcb-finish-all-three-1072/manufacturing-zips.json)
identifies the manufacturing ZIPs and verification reports. Screen-board native
SHA-256: `3b00298277874b1018c55876766d4e771c1fca0e59393271a3e98df1743a80af`.
Placed-board SHA-256: `c14921ed198b39ea02ae1413d99dc5b53f258d42e8076e0640f4d6744b51b63a`.

The [populated close-up](alignment-populated.png) and
[copper/silkscreen close-up](alignment-copper-silkscreen.png) show the alignment.

This is a placement and fabrication-file correction. Existing assembled-board
qualification limits and the whole-PR review/CI gates remain unchanged. No
manufacturing order, merge or device deployment was performed.
