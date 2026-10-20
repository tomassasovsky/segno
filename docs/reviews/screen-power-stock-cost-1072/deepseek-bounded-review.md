<!-- cspell:words Omron Schurter datasheets deepseek opencode overvoltage -->
# DeepSeek bounded electrical review and adjudication

28 September 2026. Model: `opencode-go/deepseek-v4-flash`, read-only packet
review with tools disabled. This is an electrical/procurement review, not
native placement, USB compliance or fabrication approval.

The completed retry read the full packet (end marker acknowledged). Its
three reported candidates were checked against the actual source and primary
datasheets:

| Candidate | Adjudication |
| --- | --- |
| Power contact might be rated only 1 A | Rejected. Exact Omron G6C-1117P-US DC5 is SPST-NO, rated 10 A at 30 VDC resistive. The 4.25 A allocation is below this. The packet omitted the rating; capacitive endurance remains a separate stated limit. |
| USB relay flyback diodes missing | Rejected. D101/D201 are already 1N4007G, cathodes at AUX and anodes at the respective coil low sides; source and regenerated netlist include both. |
| Branch-fuse quote still lists old Bel input fuse | Confirmed and fixed. The current quote/plan/BOM use Schurter 0001.2513 plus OGN 0031.8201. Old input-fuse assessment is marked superseded. |

The reviewer additionally requested confirmation of the IM02 continuous
coil-voltage limit. The [independent primary-datasheet assessment](im02-coil-upper-voltage.md)
finds no overvoltage defect at 5.25 V maximum AUX / 60 °C local air. Nominal
4.5 V is not the maximum continuous rating.

Several arithmetic explanations in the model's response were incorrect,
although its quoted final numbers matched existing calculations: USB pickup
uses 3.38 V and a 62.439 °C rise from the 23 °C reference, not the response's
3.15 V and 84 °C expression; strong GPIO base drive must be evaluated with
the base-emitter junction conducting; charge in mA·s cannot be compared to
fuse melting I²t in A²·s. Those model explanations are not accepted evidence.
The source guard and reports retain the actual equations and bounded pulse
sensitivities.

Primary contact evidence: [Omron K018-E1, page 3](https://components.omron.com/us-en/system/files/2026-03/datasheet_pdf/K018-E1.pdf).
Flyback source: `hardware/kicad/screen_power/switch_circuit.py`, channel loop
for D101/D201. Current procurement: [Mouser US combined quote](https://www.mouser.com/en/price-availability/Edit?bomId=8d557212-bfa8-4ecd-9a90-89cffde392b4).

The first high-reasoning attempt returned no verdict and was stopped. The
completed fresh low-variant retry produced the findings above. A same-session
closeout attempt timed out with no response. A fresh, shorter adjudication
then completed and withdrew the three component/topology candidates and
the coil-voltage concern. It also retracted its earlier arithmetic narration.
Its remaining two requests were to preserve the unqualified capacitive-make
endurance caveat and correct that narration; both are explicitly covered in
this record and the current design documents. They do not require new parts.

This is a completed bounded electrical/procurement closeout with no remaining
new design defect in its stated scope. It provides **no native-layout or
fabrication approval**. Final independent native review remains required.
