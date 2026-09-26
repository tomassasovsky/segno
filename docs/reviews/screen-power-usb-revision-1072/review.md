# Screen-power USB correction — Revision M

**In progress: screen-board ordering remains on hold.** The console and ring
native boards are outside this change. Existing screen archives contain the
previous host-powered coil circuit and must not be ordered.

The source now powers each relay coil from AUX and uses two series switches
to require both GPIO enable and that channel's host VBUS. Four bare solder
pads support separate cable shield drains while retaining the XH4 connectors.
The PCB remains two-layer and hand-soldered, with its existing outline,
mounting holes and cable anchors.

The regenerated schematic has zero KiCad ERC violations. Source contracts,
24 distinct ideal switching states and 13 new USB fault controls pass. Native placement,
routing, complete validation and updated manufacturing exports are pending.
No current native-board release is claimed by these source checks.

- [Circuit assessment and margins](circuit-assessment.md)
- [Cable construction, pin maps and optional donors](cable-assessment.md)
- [Coated-field impedance assessment](impedance-assessment.md)
- [Component costs](../../../hardware/kicad/screen_power/COSTS.md)

The accepted USB geometry target is 0.78 mm width / 0.23 mm gap at the
existing 1.01 mm center pitch. Claude's cloud placement/routing pass will
apply it while retaining paired paths, smooth bends and front-side ground
returns. The two-layer fabrication service does not guarantee impedance;
calculations do not replace assembled operation or full USB qualification.

## Independent source review disposition

The circuit was reviewed with DeepSeek through OpenCodeGo, in addition to
independent architecture, conventions, test-quality and simplicity roles.
Native release review remains pending until routing and exports exist.

| Finding | Disposition |
| --- | --- |
| Tolerance gate accepted 11%/91% as 1% | Fixed both parsers; added positive/negative regressions, including the intended component-error check. |
| Duplicate relay pickup calculation | Removed the duplicate; channel margin calculation is now the sole numerical source. |
| Old native validation output is still present | Expected intermediate state; it must be replaced by the complete 75-control native run before any release. The order hold remains. |
| Hot restart and supply-floor wording | The 60°C model remains an estimate; README and wiring now explicitly require 4.75 V at J1 for normal assessed operation. The 4.5 V figure applies only to MOSFET gate drive. No 85°C hot-restart guarantee is claimed. |
| Suspend axis duplicates retained-VBUS states | Removed the duplicate axis. The model reports 24 distinct states and 48 coil paths; suspend is explicitly DC-identical when VBUS remains present. |
| Pi input pull-up can enable the buffer | Explicitly documented: shutdown must drive GPIO low or release it without a pull-up. The existing external pull-down does not override every internal pull-up. |
| Hot gate leakage | Retained as a stated sensitivity, not an all-temperature guarantee. The reviewer's claim that arbitrary unspecified leakage cannot operate the relay is not adopted. |

[Raw DeepSeek report](raw/deepseek-circuit-review.md) records its exact review
scope and limitations. Its “worst fault” wording for host current is narrower
in the accepted assessment: the resistor bounds a nonnegative sensing node,
not arbitrary component failures or shorts around that resistor.
