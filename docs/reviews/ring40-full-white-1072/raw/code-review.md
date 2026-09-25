# Bug-focused review — 40-LED full-white power

Base: `f8d6f889ba51bf1a8cb5e29b6f00fd852465ee2d`; target: final working-tree
implementation including both new helpers. The final source/native hashes are in
[independent-artifact-parity.json](independent-artifact-parity.json).
No implementation was edited by this reviewer. This is the scoped follow-up to
the earlier full hardware review.

## Completed review angles

Read all changed generator/helper/router hunks and their surrounding callers.
Traced the ring supply from J1 to J2 and the console feed from the input copper
bar to J6, including returns and the board-to-board pin contract. Reviewed removed
behavior, minimum-width enforcement, wider-branch preservation, state ownership,
import direction, fixed route anchors, locked copper and export failure paths.
No runtime or firmware brightness setting participates in the hardware guards.

Independent checks on the final saved boards:

- Both native full-severity DRCs, including all track errors: zero violations and
  zero unconnected items.
- Console routed-board fabrication gate passes on the actual saved board.
- Ring and console critical-path self-tests pass; each rejects seven deliberately
  injected faults in loaded copper or its power contract.
- Pure-Python width-helper self-tests pass, including preserving a wider branch.
- Python compilation and shell syntax checks pass for the changed entrypoints.
- Native ring comparison confirms unchanged footprint values, placements,
  orientations, pad geometry and net assignments. Copper changes add the direct
  supply and return connections and move the DOUT route clear of them.
- Ring J1 and J2 ground pads connect through the same principal rear ground area;
  three new 0.4 mm drilled barrels connect the front wire pad to that plane.
- Both boards have two copper layers; the ring stack records 0.035 mm copper on
  both outer layers. Existing direct-module branches remain available as alternatives.
- Dedicated positive-feed lengths are approximately 22.64 mm on the ring and
  93.95 mm on the console, at 1.5 mm and 1.7 mm respectively. These paths bypass
  the lower-current logic branches.
- Console J3/J24 ground thermal overrides are 1.2 mm; J6 is 0.8 mm. Four parallel
  0.5 mm drilled power vias, with individual spokes, carry its layer transition.
- The console export checks DRC success before deleting or plotting outputs;
  the ring script rejects all reported violations and unconnected items before
  its critical-path guard and export.

## Final manufacturing correspondence

Verified all 12 console and 10 ring archive members against their loose exports
byte for byte. Independently regenerated every specified Gerber/drill/job file
from each native board into separate temporary directories. All matched after
removing only creation-date fields/comments; coordinates, apertures, drills,
layer/material settings and geometry were not normalized. The screen ZIP is
unchanged. Full hashes are in the linked independent parity record:

- Console ZIP: `88960bd4d96e7f06e7c9a60fb59f99a8735a10ec35e0865b3b64e40c7efab2eb`.
- Ring ZIP: `d27aff2c3694b6c0f48cedd2f0bf6e9b38093dabef02558c775b456732f006ef`.
- Screen ZIP: `25370578cbb1184f6d2bc1913c88746ff87ce91809779c7878d62f4af735a878`.

## Ratings and limits

The design budgets 2.4 A for LED channels, 0.04 A for pixel idle and 0.2 A for the
ring controller: 2.64 A through the console connector. With 20% negative width
tolerance, the conservative IPC-2221 external 1 oz, 10 degree C estimate is
approximately 2.73 A for the ring feed and 2.99 A for the console feed.
JST's primary XH datasheet confirms 3 A with AWG22 and 0.010/0.020 ohm maximum
initial/after-environment contact resistance.
[JST XH datasheet](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).

These are design estimates, not measured PCB or enclosure temperature. Specified
wire gauge and mating contacts, the actual strip, soldering and strain relief
remain assembly requirements. The 24/16-LED module footprints are alternatives
to the strip, not additional simultaneous loads. The 10 A AUX supply is not
qualified for unrestricted white on all 120 LEDs plus both screens; the updated
system budget retains normal pill rendering while allowing a full-white ring.

## Findings and completeness

No actionable findings. All requested bug-review angles and final export/source
matching are complete for the recorded revision. This report does not declare
remote CI green, review unrelated firmware, or remove the physical-validation
gate. A later implementation or CAD change requires a delta review.
