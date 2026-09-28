<!-- cspell:words DeepSeek opencode AHCT XIAO ACZ GPIO RP2350 -->
# DeepSeek adversarial review: ring carrier

**Verdict: clean with the documented operating bounds. No confirmed normal
operation circuit, net/pad mapping or critical route defect remains.**

This is a completed external, read-only adversarial review using
`opencode-go/deepseek-v4-flash`. The reviewer had file read/search and web-fetch
access, with shell execution and writes denied. It inspected the actual circuit,
netlist, BOM, native-derived geometry and evidence rather than only a component
proposal. Initial claims were checked against the design and primary sources;
incorrect findings were returned to the reviewer for correction.

The circuit/native baseline is commit
`44edd9483518768506533a3b6fe30e85d6d530c4`. Manufacturing and programming prose
was corrected during the review; the native board bytes remained unchanged.
The conclusion is a bounded paper review, not measured thermal behavior, USB
certification, assembled-device qualification or a guarantee against all faults.

Board SHA-256:
`c53eb16d7531f2c891dc5854faaf40fc1414ebcb2747d0101740e6a35bd1d9ca`.

## Observed coverage

- Complete ring source/netlist and native pad/net summary; encoder and ring
  power contracts, console integration, selected assembly and harness.
- All 358 targeted native supply, ground, UART and LED data route records.
  Individual encoder and unused data-output route geometry was not reread
  segment by segment; the source, pad map, routing summary and DRC cover it.
- Current ring/console fabrication parity evidence and manufacturing hashes,
  voltage/return bounds and the corrected programming instructions.
- Primary text for the exact TI AHCT125, Same Sky ACZ11 revision 1.08,
  WS2812B reference, JST XH/VH and the relevant RP2350 electrical/errata
  sections. The RP2350 extract's final 22 lines were not read by this model;
  the important electrical/errata portions were read. The full SoC data sheet
  was not the review scope.

The selected encoder's current direct primary PDF download succeeded even
though the web-fetch interface had returned 404. Its extracted text is identical
to the previously reviewed May 7, 2026, revision 1.08 text. The new PDF byte hash
is recorded in the provenance index; a changed file hash alone is not a changed
mechanical specification.

## Findings and adjudication

| Initial claim | Verified outcome |
| --- | --- |
| USB-powered XIAO drives through an AHCT positive input clamp while its supply is off | Retracted against TI's actual input limits and leakage table, including VCC = 0. The generic CMOS clamp assumption was wrong for the selected part. |
| Floating DIN can demand an unbudgeted full-white ring load | The overload claim was retracted: the 2.44 A strip allocation is already included in the 7.818 A AUX budget. Normal controller and strip supplies share the same AUX split. |
| Programming leaves the separately fed strip powered while J1 is disconnected | Assembly instructions now explicitly turn AUX off before unplugging J1 and keep the strip off during programming. The reviewer read and accepted the corrected sequence. |
| Ground-offset and loaded-buck-floor assumptions are measurements | They are not measurements. They remain explicit harness/operating bounds rather than a newly discovered circuit defect. |

The reviewer called the 100 kOhm R5 bias a “hard ground” when discussing RP2350
E9. That phrase is not accepted: a 100 kOhm pull-down is not a short or a
universal workaround for the A2 leakage erratum. Normal LED operation actively
drives the data pin. The review does not assert a guaranteed arbitrary reset or
fault-state data level from R5 alone.

## Limits and distributed coverage

The XIAO primary schematic is a raster PDF whose text extraction is empty.
DeepSeek therefore did **not** independently establish its internal diode paths
from the drawing. ACZ11 mechanical/pad drawing geometry likewise remains a
visual-primary check for Claude/Codex. This report does not claim those diagram
checks for DeepSeek simply because the project already contains them.

No assembled encoder test, castellation inspection, strip measurement,
closed-enclosure thermal test or loaded-buck measurement was performed. The
voltage-margin assessment is a calculated envelope. The 40-pixel full-white
ring is included; simultaneous full white on all 120 pixels and both screens
is outside the 10 A supply budget.
