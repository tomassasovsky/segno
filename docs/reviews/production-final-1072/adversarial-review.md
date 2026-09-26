<!-- cspell:words DeepSeek TLP Toshiba Littelfuse onsemi Mbps datasheets -->
# Adversarial review disposition

The review input was hardware head `d32bca8b24c543b907ee1f104ebf8b04f6fa6947`.
OpenCode Go / DeepSeek v4.1 Flash read the current circuit sources, BOMs and
design assessments. Its first attempt exhausted the reasoning allowance
without returning findings; a continuation completed the review. It had no
native artwork, current runtime or independent geometry checker, and did not
fetch primary datasheets. Its output was treated as hypotheses, not authority.

| Claim | Verified disposition |
| --- | --- |
| 120 LEDs at full white overload AUX | True for that different load; already explicitly excluded. The requested unrestricted 40-pixel ring plus normal pills is 7.608 A. All 120 pixels at flat white is 11.91 A and remains outside the 10 A supply budget. No scope change or new PCB defect. |
| A2 RP2350 presence input can stick high | Valid for the hardware branch's old firmware. The actual runtime in PR #1082 at `92af127d` includes the manufacturer's input-enable workaround. Assembly documentation now names that dependency instead of implying the code is on this branch. No resistor change required. |
| 4 A / 750 mA fuses do not enforce 3 A / 500 mA operating allocations | Correct and already documented. They provide supplementary fault protection, not active limiting or a guaranteed clearing time for every partial overload. No normal-load overheating was demonstrated. Proper main-power leads are mandatory; do not power a screen through its touch cable alone. |
| 2.64 A is close to the XH 3 A rating | Within the manufacturer's 22 AWG rating. Its 85 °C maximum includes current-induced rise; this operating boundary is now explicit. A later independent worst-corner voltage calculation did find insufficient end-to-end headroom in the long straight-through harness. The corrected near-ring star feed sends LED current directly to the strip; J1 carries only the controller. See the voltage-margin addendum. |
| HDMI may keep a screen alive | The owner already tested both actual screens: main and touch unplugged, HDMI attached, fully dark. This closes that visual check for this setup; it does not measure all leakage currents. |
| Main/touch VBUS may be joined inside a screen | Retained assembly constraint. Both proper main feeds must be connected; branch fuses do not define current sharing. The board switches both paths. |
| Relay/XH path lacks a measured 480 Mbps eye | Correct qualification limit. Routing/ground checks cannot certify USB compliance. No specific new geometry defect was demonstrated. |
| CTRL tip lacks series transient protection | A robustness limit for external voltage/ESD, not a proven fault for the specified passive expression/switch pedals. Normal contact sequences remain within ground and Pico 3V3 bias. |
| TLP627M(E is malformed | Rejected: Toshiba's official orderable-parts table uses exactly `TLP627M(E`, without a closing parenthesis. |

DeepSeek also called Q3/Q4 pin 1 source, 2 gate, 3 drain. This is incorrect:
the Vishay SUP70101EL footprint is G1/D2/S3 and the independently checked
source, schematic and native board use that correct map. That claim was not
used to change the circuit.

Primary evidence is in the [screen review](screen-circuit-review.md) and
[system review](system-power-console-ring-review.md), including manufacturer
links. Toshiba's exact ordering name is on its
[TLP627M product page](https://toshiba.semicon-storage.com/us/semiconductor/product/isolators-solid-state-relays/detail.TLP627M.html).

Claude Cloud was also launched independently on the exact current head. It
confirmed the head, inspected the new circuit/checker and flagged stale
`screen_power/validation.json` provenance. The canonical report is refreshed
by this release; the previous alignment package had separate current reports.
The cloud account then exhausted usage credits before returning a final
engineering verdict. Manufacturer-domain access also failed there. This is
an **incomplete external review**, not a pass. Claude's separate silk author
produced a draft approach before the same limit; the local implementation is
independently checked against actual ink and mask geometry. No cloud review
completion or approval is claimed.
