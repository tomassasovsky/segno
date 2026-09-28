<!-- cspell:words fanout -->

# Rounded USB and buffer-supply review

26 September 2026, issue #1072. The scoped source and native geometry review
passes. This is layout evidence; final manufacturing-package verification is
separate, and these calculations do not constitute measured USB compliance.

The applied [source](../../../hardware/kicad/screen_power/route_critical.py)
has SHA-256 `cbcc9e5cafb4c0577889beb1bb5d0c70b2fa7555982ee3701b9ff2e8982ee547`.
The final [native board](../../../hardware/kicad/screen_power/hand/screen_power_hand.kicad_pcb)
is `c06e6b35438b2fc7208cdc50feeebee92e6c01a56a00dadd280f697d1e49d79b`.
The [numerical record](usb-review.json) separates the independently reviewed
candidate from the final native board after the shared rounding pass.

## USB geometry

The eight data routes retain their terminal coordinates, **0.85 mm B.Cu width**,
**0.16 mm minimum copper-edge gap**, and zero data vias. Mirrored circular
corners replace the previous angular fanout paths. Straight coupled intervals extend
from x=11–27.6 to 10.6–28.15 on the host side and from x=35–52 to 34.6–52.4 on
the screen side; measured uncoupled lengths become shorter, not longer.

| Path on either channel | Length per conductor | Pair length difference | Actual centerline radius | Minimum inside radius |
| --- | --- | --- | --- | --- |
| Host to relay | 23.526702 mm | 0.000000951 mm | 0.768198–1.000 mm | 0.343198 mm |
| Relay to screen | 26.178136 mm | below 0.000000001 mm | 1.000 mm | 0.575 mm |

The requested radius is 1 mm; the short host-side relay exit clamps one corner
to 0.768198 mm. Every inside radius remains positive. The sub-nanometer nominal
pair difference is integer-coordinate/chord quantization, not a fabrication
accuracy claim. Coupling profiles were sampled at no more than 0.01 mm along
each path; conductor lengths and minimum gaps use the saved native segments.

The source emits a front-layer track/via keepout capsule under every USB
segment. All **292 capsules** exactly match the generated source and protect
the reference corridor beneath the **292 data segments**. The final filled
front ground passes **6,268 samples** at 0.1 mm intervals on each centerline
and both copper edges, excluding the existing 1.35 mm terminal regions.
These checks preserve the existing two-layer USB routing assumptions; they do
not model the connectors, cables or complete high-speed channel.

## Nearby buffer supply

The Q2.1→R6.1 AUX_5V branch changes from five angular 0.25 mm B.Cu segments to
28 segments following three circular bends. Each has a 1.125 mm centerline
radius and a 1 mm inside radius. The terminal pads and net are unchanged.
This is the low-current buffer pull-up branch; the 2.0 mm input and 2.5 mm
MOSFET power paths are untouched.

## Scope and preservation

Against the immediately preceding native board `cf7cfa57…`, the reviewed
candidate `2f48c776…` replaces exactly 40 USB segments, five AUX B.Cu segments
and 40 USB reference capsules. Every unselected track/via, complete footprint
block, board graphic, stack/setup block, other zone outline and setting, and
non-ground filled copper remains unchanged. Candidate selected tracks and
capsules exactly match a fresh replay of the route source. Native DRC on that
candidate reports zero violations and zero unconnected items.

After the separately [reviewed shared rounding pass](rounding-review.md), the
final board's USB segments, terminals and net data remain exactly identical
to that candidate. The geometry and ground checks were rerun on the final
`c06e6b35…` board and pass with no errors. The broader all-three review and
manufacturing status remain in [the audit](audit.md).
