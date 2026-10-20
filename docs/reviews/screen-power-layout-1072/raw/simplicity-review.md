<!-- cspell:words floorplan -->
# Screen-power revision B simplicity review

## Scope and evidence

Reviewed the working revision B changes against `c275f94a`: the README and external harness BOM, shared circuit and layout generators, critical routing, symbol generation, board generation, validation, and manufacturing export integration. The layout and routing were still undergoing validation during this review. This report does not certify the final copper, fabrication package, USB performance, thermal behavior, or enclosure fit.

Inspected the generated component records independently: both variants contain 41 component records, neither includes a TPS25810, ADuM3165, or EVM, and both J2 connectors map pin 1 to `PI_GPIO17` and pin 2 to `GND`. The hand records contain no surface-mount footprint. Also verified that the two branches identified below have identical Python syntax trees.

## Simplification Analysis

### Core Purpose

Switch both screens' main and touch power off under the existing console GPIO control, also disconnecting USB data, with a fully through-hole assembly option and a smaller factory assembly of the same circuit.

### Unnecessary Complexity Found

- **Suggestion — remove the identical routing branches.** `hardware/kicad/screen_power/route_critical.py:72` tests for the first channel's main fuse, but both branches create exactly the same `SWITCHED_5V` segment with the same width and layer. The apparent exception makes future routing changes harder to follow without representing a physical distinction. Replace the entire conditional with one `track(...)` call. Preserve the preceding through-hole channel-two exception, which represents a distinct route.

### Code to Remove

- `hardware/kicad/screen_power/route_critical.py:72`: remove the redundant `if`/`else` and repeated call. Estimated reduction: 3 lines.

### Simplification Recommendations

1. Collapse the identical fuse-branch routing calls into one statement. This keeps the actual geometric exceptions visible and changes no generated copper.

The shared circuit is an appropriate simplification. Hand and factory differences are limited to package, pin mapping, component selection, and placement where their physical assemblies differ. Keeping the manufacturing pipeline separate from the electrical circuit and floorplan is justified; no further abstraction is needed.

### Obsolete Paths and YAGNI

No active obsolete EVM/source-controller path remains in the reviewed revision B generators or component records. The dedicated old hand circuit and layout modules are deleted. The shared symbols no longer include the removed factory isolator and load-switch definitions. References to revision A in the README explain the superseded design and do not preserve a compatibility path.

The two USB relay paths, opposed power MOSFETs, gate pull-up, isolation diode, fuses, and discharge resistor each serve a stated current requirement. Removing them as a component-count optimization would change the electrical contract; no such removal is recommended by this review.

### Practical Assembly Assessment

The source and BOM consistently retain through-hole components for hand assembly, one two-wire J25-to-J2 control harness, three power mating housings, and conventional USB cables. The documentation identifies the separately soldered fuses, live TO-220 tabs, incomplete custom-part 3D models, and the need to preserve the existing screen power connector/signaling arrangement. These are explicit assembly boundaries rather than hidden external electronic modules. The remaining physical fit, harness confirmation, inrush, thermal, and USB tests are already documented; this review adds no speculative replacement circuit or release claim.

### Final Assessment

Complexity score: Low. Recommended action: one minor simplification. Potential reduction: 3 source lines, about 3.6% of the current critical-routing generator. No critical or important simplicity findings were established. No merge or manufacturing-release recommendation is made.

The redundant branch was removed in the final revision; no suggestion remains open.
