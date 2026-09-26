> **Screen-board correction, 25 September 2026:** This is a historical report. Its screen relay-pinout approval is superseded: IM02TS commons are 3/6, NC contacts are 2/7, and NO contacts are 4/5. Revision I Gerbers are withdrawn. Use the [corrected Revision J record](../screen-power-rev-j-1072/verification.md). Console and ring findings are unaffected.

# Hardware publication — 25 September 2026

This publication records the current screen-power revision I, console connector
and ADC supply corrections, white ring carrier and Pi GPIO17 lifecycle service.
It is stacked on the console full-power routing work in #1066 and closes #1072.

The screen board is hand-soldered only: 37 through-hole components, two copper
layers with ground pours, 68 × 76 mm, 3 mm corners and purple mask. USB uses
the selected four-pin XH leads; main power uses separate VH connections. The
shared switch interrupts main power and both USB-touch paths. The Pi service
turns GPIO17 off before orderly compositor shutdown and waits a provisional
five seconds. That timing still needs assembled-system validation.

The white ring carrier retains direct 24/16-LED module footprints and J2 wire
pads for an external strip. The selected 40-LED strip uses its own mechanical
housing. The old console drives a passive encoder assembly; the new carrier
uses a XIAO, so these generations require different firmware pin maps. New-v3
firmware and PD diagnostics are being preserved separately. Historical local
completion reports include those changes and are not proof they are in this PR.

## Observed publication checks

- Screen native ERC/DRC, schematic/netlist/PCB parity and assembly checks pass;
  all 24 deliberate fault cases are rejected.
- Console routed-board fabrication gates and all 15 layout fault controls pass.
  Fresh full-severity KiCad DRC reports zero violations and zero unconnected items.
- Ring fresh full-severity DRC reports zero violations and zero unconnected items.
- GPIO lifecycle host suite: 12 tests pass.
- Three manufacturing ZIPs have every member matched to its loose export;
  paths, hashes and member counts are in [the manifest](manufacturing-zips.json).

No board geometry was changed during publication. The published ZIPs preserve
the previously reviewed manufacturing data; documentation corrections remove
the obsolete blanket pre-order measurement hold. The September 24
[first-fabrication decision](../pcb-completion-1072/first-fabrication.md) remains
in effect: no additional owner measurements are prerequisites for buying bare
PCBs. No order or device flash is part of this publication.

Assembly validation remains open for cable polarity, USB operation, warm power
behavior, mounting/harness fit and screen cutoff before HDMI loss. The owner's
HDMI-only darkness test passed. Issue #1072 retains `autonomy:blocked-verify`;
local CAD/test evidence is not remote CI or a complete current-head code review.
