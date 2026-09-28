<!-- cspell:words Schurter Omron IRLZ NPBF backfeed -->
# Screen-power Revision N and copper-finish review

**Review complete: no unresolved actionable findings.** Native and fabrication
checks passed; the independent role verdicts and bug-focused gate below
record their exact scope and identities.
Baseline: `9f01b49572249e544c84097b574c02f25de851a7`, PR #1080, issue #1072.
No order, merge, flashing or deployment is authorized or performed.

## Intended result

The screen board replaces its unavailable power MOSFET pair, charge pump and
optocoupler with one normally open Omron G6C power relay. IRLZ44NPBF switches
only the relay coil, with a P6KE6.8CA clamp. F1 is a removable Schurter SPT 8 A
cartridge in an OGN holder. Four lower-cost Bel branch fuses remain soldered.
The existing independent host detectors and USB relay paths remain intact.
The board remains 68 × 76 mm, two layers, with hand-soldered components and
the purchased XH cable interfaces.

The fresh Mouser US quote contains 53 part lines and 168 units, all available
for the requested quantities. Parts are $68.59, estimated tariffs $9.48 and
estimated shipping $8.49: **$86.56 before sales tax**. The first quote was
$105.86; fitting removable holders to all five fuses would have cost $97.62.
Only the main fuse is removable in the selected design. Existing equipment
and reusable parts are excluded as documented in the shopping list. The
quote is not an order or inventory reservation; final shipping depends on
the Miami delivery address. Prices and quantities were rechecked unchanged
on 28 September 2026.

## Review and evidence boundaries

- Claude's completed September 27 reviews cover the preceding design. Two
  new authoring attempts stalled without a new verdict; no fresh Claude
  approval is claimed for Revision N. Placement/routing was completed locally
  with native KiCad after that service failure.
- The completed [DeepSeek review](deepseek-bounded-review.md) covered a bounded
  component/circuit packet. Its verified findings are resolved; it did not
  inspect final native copper or manufacture a board.
- Independent architecture, VGV, simplicity, test-quality and readiness
  reports are in `raw/`. The [bug-focused gate](../../code-review/pcb-stock-cost-1072/review.md)
  covers the new delta against the preceding reviewed hardware and the final
  native/export identities.
- The [coil budget](holder-coil-budget.md) and
  [actual filled-copper model](ground-return-assessment.md) separate
  manufacturer ratings from engineering sensitivities. The final model
  binds the corrected native board; nominal copper losses are 13.158 and
  12.760 mV at 0.15/0.10 mm meshes, with 15.366 mV in the thinner-material
  sensitivity, below the retained 20 mV allowance.

## Material limits retained

The input bound is 4.46 A, including 4.25 A screens, 60 mA bleeder and 150 mA
control/coil allowance. Normal pills, console and the unrestricted full-white
40-pixel ring bring the AUX planning total to 7.818 A. The ring retains its
separate direct AUX harness; all 120 pixels at full white are outside this
allocation.

The design does not claim active inrush limiting, capacitive contact endurance,
a guaranteed hot/aged contact resistance, measured enclosure temperature,
screen-end minimum voltage or USB certification. A closed K1 contact is
bidirectional: external output power can sustain AUX until GPIO17 is low.
An unpowered Pi defaults the board off; a powered but software-halted Pi
must release or lower GPIO17. These are documented circuit and operating
conditions, not new purchases or a requirement for a separate pre-PCB build.

## Final copper and fabrication evidence

The screen [copper audit](screen-copper-finish-audit.md) removes an AUX tap
stub, a redundant via-landing extension, sharp concave power junctions and
pointed ground ends at the mounting-hole clearances. Track minimum widths
and electrical clearances remain unchanged. The [console/ring audit](copper-finish-audit.md)
removes two small dead-end front-ground fingers on the ring, retaining all
564 track/via items, 73 pads and the rear plane. Console copper is unchanged.
Intentional thermal-relief gaps and pad shapes remain.

| Board | Final native SHA-256 |
|---|---|
| Screen Rev N | `e72850b26ae9076011bc368b69d3f1f1edce758be878bf5fb0decc4f415c5a2f` |
| Ring | `c53eb16d7531f2c891dc5854faaf40fc1414ebcb2747d0101740e6a35bd1d9ca` |
| Console | `c23df586f211bb439081ca951dd23dc54ba21f6d89eb3d373bd6f196749f326d` |

All three final native DRC reports show zero violations and zero unconnected
items. Screen ERC is also zero. [Screen validation](screen-native-validation.json)
passes all 103 injected-fault controls, source/schematic/netlist/native/BOM
parity, physical models, widths, layer transitions and ground-reference checks.
The independently pinned [USB baseline](preserved-usb-final.json) confirms all
292 USB copper items and 18 anchors are unchanged.

Independent fabrication comparison passes [175 console/ring assertions](console-ring-fabrication-verification.json)
and [415 screen assertions](screen-fabrication-verification.json), including
fresh KiCad copper/mask/legend/outline/drill comparison, archive inventory,
source hashes and loose/package/archive identity. The screen package has all
models and seven active schematic sheets; the obsolete gate-drive sheet is
removed. The generated assembly drawing and final top/bottom 3D views were
inspected. The ring's selected-assembly STEP is unchanged because only ground
fill changed; footprints, models, holes and placement remain identical.

The [manufacturing manifest](../pcb-finish-all-three-1072/manufacturing-zips.json)
identifies the three current ZIPs and superseded identities. It replaces the
screen Rev M archive and earlier ring fill. Prior release folders stay
historical. This evidence accepts the reviewed bare-board data; assembled
operation, enclosure fit under actual wiring and current-head full CI remain
separate. No claim of universal USB compliance or fault-free hardware follows
from these design checks.
