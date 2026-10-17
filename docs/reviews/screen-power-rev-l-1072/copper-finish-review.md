# Copper finish review

**Historical checkpoint — superseded artwork.** The [all-three-board audit](../pcb-finish-all-three-1072/audit.md) and its [archive manifest](../pcb-finish-all-three-1072/manufacturing-zips.json) identify the current rounded boards and exports. The hashes and fabrication counts below describe the earlier checkpoint only. Circuit and power calculations remain applicable where their geometry and components are unchanged.

25 September 2026. Diagnosis covers the console, ring carrier and Revision L
screen-power board. Coordinates below are native KiCad millimeters.

Diagnosis and corrected native-artwork review are complete for all three
boards. The owner's rounded-corner and uniform-width requests are reflected
in the reviewed geometry below. Fresh manufacturing-package verification
remains separate: this record does not approve replacement Gerber files or
supersede the publication hold in [verification.md](verification.md).

## Reviewed starting boards

| Board | SHA-256 before this cleanup |
| --- | --- |
| Console | `9b9854170d005b1721c22a0b0e70114da0d0ab5ff08946c4cbfc255fc76b46c0` |
| Ring carrier | `c14247f8c6ecf4498af8158de2b28fd5a9f19a3dc75e795a232f1a032a9c7be1` |
| Screen power | `53a3a19d9598feac3f9622b5945d709a394ee10cfb09c81ac7841f46a78624d6` |

## Display seams and actual copper

Filled polygons encode some internal clearances by traversing a connecting
edge and then returning over exactly the same edge. These zero-width seams
can appear as thin lines in previews; they remove no copper area. Native
contours and Gerber region coordinates confirm this on the inspected boards.
They need no rerouting.

For example, the console's long horizontal seam from `(108.450499, 154.330472)`
to `(191.049500, 154.330472)` occurs in both copper layers and retraces exactly.
The ring's front seam from `(53.350499, 19.768713)` to
`(55.649500, 19.768713)` also retraces exactly in the shipped Gerber.

## Console: preserve useful ground copper

The inspected ground-clearance contours needed no correction. The owner's
rounded-corner request is applied to the power-bar outline without
removing useful ground copper or changing the supply path. The real
0.272 mm ground corridor beside the ring supply, around `(140.78, 127.98)` to
`(146.38, 133.58)`, connects useful front ground copper. Removing that corridor
in a geometric check splits the front fill and separates about 467 mm² of
ground. Preserve it. Other inspected 0.33–0.40 mm ground strips are
manufacturable; narrowness alone is not a reason to remove them.

H1 is the sole grounded mounting pad. H2–H4 are intentionally isolated chassis
pads, so their circular clearances must remain. Preserve the 1.7 mm ring feed,
four parallel transition vias, 5 mm two-sided pill supply bar and connector
ground spokes.

Claude's `2e4b30a5` correction adds native 1 mm corner fillets to the front
and rear +5V bar. Actual filled copper has rounded ends. The nominal 5 mm
bar, 0.3 mm thermal gaps and 1.2 mm thermal spokes remain unchanged. At the
middle of the bar the rear copper retains its full 5 mm width; the front
retains the same pre-existing 4.8402 mm span around local clearances.

Independent comparison confirms unchanged tracks, vias, footprints, pad
assignments, model transforms, pad thermal overrides, outline and stack.
The entire ground-corridor neighborhood at `(138, 126)`–`(148, 135)` is
geometrically identical before and after the fillets. Ground-fill region
counts are unchanged. Native DRC reports zero violations and unconnected
items, and the ring-feed/return guard passes.

Reviewed native board SHA-256:
`a57759950c14ab9606613dac89d51b9021e7824b80055f0e3daaa5ce571b377b`.

## Ring carrier: corrected copper reviewed

The starting front +5V rail contained a real 0.925 mm gap between the old 0.65 mm branch
at `y=20` and the new 1.5 mm branch at `y=22`. It ended in an acute clearance
tip at approximately `(45.6143, 20.325)`. The supply remained electrically
connected, but redundant overlapping routes left an untidy copper shape.

A second old 0.65 mm branch from U2.14 through `(33.0967, 22.5233)` and
`(32.19, 22.5233)` protruded about 0.0983 mm below the new rail.

Claude's `255a47cf` correction removes both obsolete branches. C5.1 now joins
the rail vertically at `(39, 22)` and U2.14 at `(35.62, 22)`. Each T junction
has two visible 0.6 mm concave fillets; actual filled-copper inspection confirms
that the old slot, acute tip and projecting ledge are gone. The separate
zero-width polygon seams require no change.

Independent review of the refilled native board found:

- All eight feed and tap segments match the durable
  [generator](../../../hardware/kicad/ring_power.py), allowing only its existing
  1 nm coordinate-conversion difference. Both fillet outlines match exactly.
- Changed tracks are confined to front `+5V_LED`. The 1.5 mm rail is split at
  the two tap junctions without changing its path or width. The continuity
  guard passes without relying on the fillet zones, and all seven deliberate
  power/return faults are rejected.
- All three 0.4 mm drilled return vias remain at their original positions
  inside J2's ground pad. Footprints, pad assignments, models, outline,
  two-layer 1 oz stack and white solder mask are unchanged.
- Native KiCad DRC reports zero violations and zero unconnected items.

Reviewed native board SHA-256:
`3c92dcfd2ab2644ca74f7d82226db84476becbd7fb897ca701ff593ed604a0f2`.
Reviewed `ring_power.py` SHA-256:
`bb939ac21e490a836e967aba3d026be55b9313a94cde549dd9299c509d5e582c`
(includes the subsequent comment-only correction).
The ring copper findings are resolved for these files. Manufacturing-package
refresh and parity remain a separate gate.

## Screen power: uniform curved supply paths

Two starting-board locations contained real pointed ground-fill ends: under Q3 at
approximately `(44.318, 11.506)`, and opposing rear tips below F101's power
transition at `(46.648, 25.720)` and `(48.706, 25.748)`.

The final correction retains a rounded local front cutback at
`(43.15, 10.35)`–`(44.5, 11.9)`. The rear feed now meets F101 on its own
terminal row, with all three via disks fully inside its copper, removing
the original facing tips without a rear cutback. Each final ground fill
remains one connected polygon. Global fill settings are unchanged.

The Q4.3-to-Q3.3 bridge and rear Q4.2-to-F101.1 feed now have a uniform
2.5 mm width, rounded bends and no necks or taper zones. Native copper
clears neighboring pads by at least 0.3375 mm. The other broad fuse and
main-output branches also have rounded bends. All 178 broad critical
segments survive routing and cleanup with identical coordinates and widths.
Independent copies with every zone and via deleted retain the required
2.5 mm shared paths, 3 mm fuse distribution and 2 mm main outputs.

The 4.5 mm distribution spine has rounded outside corners and six explicit
inside fillets at its branch joins. Copper clears H4's reserved 4.25 mm
radius by 1.00 mm, leaving a real 0.7945 mm front ground corridor beneath
the bus. All 40 USB segments remain unchanged and all 5,452 ground-reference
samples pass. Native ERC/DRC reports zero findings and unconnected items;
all 52 control checks pass. See the [final layout review](final-layout-review.md)
for mechanical checks and source hashes.

Reviewed native board SHA-256:
`d3577772b4945f93652789e109fd232b479cfc8d119dcb67e499da51d39fa5cf`.

## Corrected-artwork result

No unresolved copper-finish findings remain on the three native-board hashes
above. This closes the geometry review. Fresh Gerber/drill export, archive
parity and the final publication record remain separate gates; a later
native-board change requires renewed review.
