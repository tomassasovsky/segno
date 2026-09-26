<!-- cspell:words DeepSeek OpenCodeGo fanout -->
# Screen-power USB correction — Revision M

**Revision M native CAD and manufacturing files pass.** Use
[the current three-board manufacturing record](../pcb-finish-all-three-1072/manufacturing-zips.json)
and its `screen-power-rev-m` archive. The retained Revision L screen ZIP is
withdrawn. Console and ring boards and their archive hashes are unchanged.
This is acceptance of the bare-board CAD and manufacturing data; assembled
operation and complete USB compliance have not been qualified.

Each relay coil now draws from AUX. Two series switches require both GPIO
enable and that channel's host VBUS, while the Pi supplies only its low-current
presence divider. Four separate bare GND pads terminate the USB cable shields,
retaining the purchased XH4 interfaces. The board remains two-layer,
68 × 76 mm with 3 mm corners, and hand-soldered throughout.

Claude Cloud authored the initial placement and critical routing. Local Claude
iterations and bounded Claude-authored patches closed actual native copper,
courtyard and label findings. The remaining low-priority nets were routed
through the existing constrained pipeline and rounded afterward. All eight
connector anchors, mounting holes, U1/U2 alignment, Q3/Q4 positions and the
350 existing high-current segments were retained. The source bridge and drain
feeder remain 2.5 mm wide; the AUX input remains 2.0 mm wide.

## Verification

| Check | Observed result |
| --- | --- |
| Native KiCad 10.0.4 PCB DRC | 0 errors, warnings, exclusions or unconnected items |
| Native schematic ERC and netlist/pad parity | 0 findings; physical pin contracts pass |
| Complete fault-detection suite | 75/75, including all 13 USB revision controls |
| Switching-state model | 24 distinct states and 48 coil paths |
| Assembly models | All 50 fitted through-hole components; four bare shield pads and four mounting holes |
| USB pairs | 0.78 mm width / 0.23 mm nominal gap; original center lines retained, no data vias, less than 0.001 mm pair skew |
| USB return copper | 6,264 filled-front-ground samples pass at trace centers and both edges |
| Power geometry | Required widths, uniform runs, dedicated power vias and mounting keepouts pass |
| Manufacturing package | 412 independent assertions; all 12 freshly exported manufacturing files match the published ZIP |
| Console and ring | Unchanged native/ZIP hashes; separate 175-assertion fabrication verification and 11/7 power fault controls remain valid |

[Full 75-control native report](../../../hardware/kicad/screen_power/validation.json)
and [independent CAM comparison](fabrication-verification.json) identify their
exact production inputs. The full control report is separate from the packaged
validation, which intentionally reruns readiness without the mutation suite.
The [final layout review](../../code-review/screen-power-usb-revision-1072/layout-review.md)
and [source delta review](../../code-review/screen-power-usb-revision-1072/delta-review.md)
record independent inspection.

The top, bottom and perspective renders, enlarged assembly drawing and full-size
fit template were inspected. All seven schematic pages retain the exact drawing
content and geometry of the previously inspected Revision M schematic. Shield
pad decorative circles were removed because their stock ink-to-mask gap failed
the independent 0.15 mm check; pad, mask, drill and courtyard geometry remain.
Functional connector labels and pin maps are retained on the finished board.

- [Circuit assessment and margins](circuit-assessment.md)
- [Cable construction, pin maps and optional donors](cable-assessment.md)
- [Local shield-drain fit](shield-drain-fit.md)
- [Coated-field impedance assessment](impedance-assessment.md)
- [Component costs](../../../hardware/kicad/screen_power/COSTS.md)

## Release bounds

The coated-field estimate is approximately 90.8 ohms for the documented stack.
Ordinary two-layer fabrication does not guarantee differential impedance; the
relay, XH transitions and finished cable assembly still require real USB
qualification. Cable construction, USB-C attachment, loaded voltage, warm relay
restart, shutdown behavior and enclosure fit retain the documented first-assembly
checks. The local shield-drain study establishes short accessible paths within
its component and cable-size bounds, not a complete enclosure harness approval.

Normal assessed operation requires at least 4.75 V at J1. The corrected AUX
planning budget is 7.708 A with the 40-pixel ring at full white and normal pill
operation. Board parts total approximately US$44.95 before shipping and tax.
No additional owner measurement campaign or pre-PCB prototype is required to
release these bare-board files. Whole-PR CI is not green on this stacked PR;
no ready-to-merge label, order, merge or device deployment is implied.

## Independent source review disposition

The circuit was reviewed with DeepSeek through OpenCodeGo, in addition to
independent architecture, conventions, test-quality and simplicity roles.
The completed native delta review closes the placement and routing findings;
whole-PR CI and assembled acceptance remain separate gates.

| Finding | Disposition |
| --- | --- |
| Tolerance gate accepted 11%/91% as 1% | Fixed both parsers; added positive/negative regressions, including the intended component-error check. |
| Duplicate relay pickup calculation | Removed the duplicate; channel margin calculation is now the sole numerical source. |
| Old native validation output is still present | Replaced by the complete rebuilt Revision M native board and its current 75/75-control report. Independent source-hash and fresh-CAM comparison pass. |
| Hot restart and supply-floor wording | The 60°C model remains an estimate; README and wiring now explicitly require 4.75 V at J1 for normal assessed operation. The 4.5 V figure applies only to MOSFET gate drive. No 85°C hot-restart guarantee is claimed. |
| Suspend axis duplicates retained-VBUS states | Removed the duplicate axis. The model reports 24 distinct states and 48 coil paths; suspend is explicitly DC-identical when VBUS remains present. |
| Pi input pull-up can enable the buffer | Explicitly documented: shutdown must drive GPIO low or release it without a pull-up. The existing external pull-down does not override every internal pull-up. |
| Hot gate leakage | Retained as a stated sensitivity, not an all-temperature guarantee. The reviewer's claim that arbitrary unspecified leakage cannot operate the relay is not adopted. |

[Raw DeepSeek report](raw/deepseek-circuit-review.md) records its exact review
scope and limitations. Its “worst fault” wording for host current is narrower
in the accepted assessment: the resistor bounds a nonnegative sensing node,
not arbitrary component failures or shorts around that resistor.
