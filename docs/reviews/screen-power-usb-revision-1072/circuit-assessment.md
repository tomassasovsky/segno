# USB relay power revision: circuit assessment

Baseline: `355882d8`. This is the circuit author's bounded design assessment,
not an independent review or an assembled USB compliance result. The screen
order hold remains until the revised native board and publication gates pass.

## Circuit change

Each IM02TS coil now draws from AUX, including during USB suspend. A second
TN0702 in series with its existing low-side driver requires that channel's
host VBUS to be present. The existing AUX/GPIO buffer still supplies
DATA_ENABLE. Each host feeds only a 10k/100k sense divider; it has no coil,
bypass capacitor, or screen-power connection. The data contacts and existing
screen power switch are unchanged.

| Ref, each channel | Physical pin connections |
|---|---|
| Q101 / Q201, existing TN0702 | 1 source = GND; 2 gate = DATA_ENABLE; 3 drain = S1/S2_RELAY_STACK |
| Q102 / Q202, new TN0702 | 1 source = S1/S2_RELAY_STACK; 2 gate = S1/S2_HOST_PRESENT; 3 drain = S1/S2_DATA_COIL_LOW |
| R101 / R201, new 10k 1% | 1 = HOST1/HOST2_5V; 2 = S1/S2_HOST_PRESENT |
| R102 / R202, new 100k 1% | 1 = S1/S2_HOST_PRESENT; 2 = GND |
| K101 / K201 | 1 = AUX_5V; 8 = S1/S2_DATA_COIL_LOW; contacts unchanged |
| D101 / D201 | 1 cathode = AUX_5V; 2 anode = S1/S2_DATA_COIL_LOW |
| C101 / C201 | 1 = AUX_5V; 2 = GND |
| TP101 / TP102 / TP201 / TP202 | 1 = GND; bare shield-drain solder pads beside the corresponding USB cable connector |

Added purchased parts: two TN0702N3-G, two MFR-25FBF52-10K and two
MFR-25FBF52-100K. The four shield pads use
`TestPoint:TestPoint_THTPad_D2.0mm_Drill1.0mm`; records retain them with quantity
zero and omit them from the purchasing BOM. They are not separate components.
The native layout and cable assembly must preserve the data pairs and connect
cable shield drains to these GND pads.

The [Microchip TN0702 datasheet](https://www.microchip.com/content/dam/mchp/documents/APID/ProductDocuments/DataSheets/TN0702-N-Channel-Enhancement-Mode-Vertical-DMOS-FET-Data-Sheet-20005941A.pdf)
confirms the TO-92 S1/G2/D3 pinout, maximum 2.5 ohm on-resistance at 3 V gate
voltage and 25°C, and 100 nA gate-leakage limit at 25°C. The 5 ohm hot-driver
allowance and 1 µA gate-leakage sensitivity below are engineering estimates,
not manufacturer guarantees over every temperature and operating condition.

## DC bounds and operating states

Calculations use AUX 4.75–5.25 V, host VBUS 4.4–5.5 V, resistor tolerances of
1%, and the relay's 145 ohm ±10% coil. Each FET is assigned 5 ohm for the
bounded hot-drive estimate.

| Quantity | Calculated result |
|---|---:|
| Normal host sense load at 5.5 V, including 1 µA allowance | 0.05151 mA per port |
| Host load with sense node at GND, 10k resistor at −1% | 0.55556 mA per port |
| Upper FET minimum gate-to-source at host 4.4 V | 3.79665 V |
| Upper FET minimum gate-to-source at host 4.75 V | 4.11425 V |
| Lower FET minimum gate-to-source | 4.35 V |
| Host-absent gate sensitivity at 1 µA leakage | 0.101 V |
| Initial coil voltage at AUX 4.75 V | 4.41192 V |
| Initial margin over 3.38 V pickup at 23°C | 1.03192 V |
| Both coils' maximum AUX allocation, ignoring driver drop | 80.46 mA |

The series resistor alone bounds this board's positive DC host load below
2.5 mA, even if the sense node is pulled to GND. This bound does not depend on
a hot gate-leakage assumption. The insulated MOSFET gate provides no intended
AUX-to-host DC power path; ordinary device leakage and transient capacitive
coupling remain, so this is not a zero-leakage claim or a single-fault isolation
rating. The 4.25 A switched-screen load is unchanged. Allocate **0.100 A** from AUX
for both coils and the board's retained controls/pump, making the screen
board's input planning load **4.35 A**. At 5.25 V, even treating transistor
and LED junction drops as zero, R9/R5/R6/R7 together draw at most 3.316 mA;
the positive gate-drive branch adds at most 0.398 mA. Including the maximum
80.46 mA coils leaves 15.826 mA of the allowance for pump input/losses and
leakage. A deliberately loose 10 mA allowance for those remaining loads
still totals below 94.18 mA. The [TI LMC7660 datasheet](https://www.ti.com/lit/ds/symlink/lmc7660.pdf)
specifies 400 µA no-load supply current at temperature extremes; the existing
negative-rail load estimate is below 0.5 mA. This is a steady-state budget;
reservoir charging remains part of the separate startup assessment.

The relay closes only with AUX present, GPIO high and its own host present.
GPIO low or floating leaves the existing buffer off. Host loss turns the upper
FET off; AUX loss removes coil energy. The correctly oriented body diodes
cannot sustain an off coil's path to GND. During suspend with VBUS retained,
the contact may remain closed while coil power comes from AUX. There is no
suspend detector or new USB device in this topology.

The existing flyback diodes retain coil suppression. Removing the former host
100 nF bypass leaves only the sense/FET input capacitance on VBUS; no added
reservoir intentionally delays host-loss detection. Exact release/attach
transients are not established by the DC calculation or the ideal state model.

## Temperature and restart bound

The [TE IM02TS primary datasheet](https://www.te.com/commerce/DocumentDelivery/DDEController?Action=srchrtrv&DocFormat=pdf&DocLang=English&DocNm=108-98001&DocType=Data+Sheet&PartCntxt=1-1462037-3)
gives 3.38 V initial pickup at 23°C, 145 ohm ±10% coil resistance and thermal
resistance below 150 K/W. Its temperature/operating-voltage curves matter:
room-temperature pickup alone does not prove a hot restart.

For a deliberately adverse restart estimate, preheat the minimum-resistance
coil continuously from 5.25 V, ignore driver loss while heating, use 150 K/W
and copper's 0.00393/K coefficient, then restart from 4.75 V through 10 ohm
total driver resistance. Solving coil self-heating at 60°C local air gives
85.44°C winding temperature and 162.52 ohm resistance. Scaling the pickup
voltage by the same copper factor gives 4.2094 V required against 4.4747 V
available: about 0.265 V margin. This supports the existing 60°C local-air
design envelope as an engineering calculation, not a tested thermal rating.
The corresponding 85°C local-air corner has no positive modeled margin;
this assessment does not claim hot restart throughout the relay's entire
catalog ambient range.

The TN0702 100 µA drain-leakage value at 125°C applies at zero gate bias. With
an estimated 1.4 coil-resistance multiplier it corresponds to about 22 mV
across the coil, far below nominal release voltage. It is only a zero-gate
benchmark: it does not certify leakage with a positively biased gate or prove
all transient off states.

## Verification and remaining gates

A disposable SKiDL build of the revised source completed with zero ERC errors
and zero ERC warnings. Source/netlist pin contracts, numerical checks and the
48-case state sweep passed. The sweep evaluates AUX presence, GPIO high/low/
floating, each host independently and suspend; it checks 96 coil paths using
actual pin nets and directed source-to-drain body diodes. It is an ideal
switch model, with analog drive assessed separately.

All 13 new mandatory USB control results passed: clean baseline; old host-powered
coil; presence-gate bypass; crossed host sensing; missing pull-down; missing
series resistor; weak pull-down; shorted series resistor; reversed upper and
lower driver pins; wrong shield net; a restored host reservoir; and a misleading 91% tolerance suffix. The gate
bypass, crossed sensing and reversed-pin mutations must fail the state model,
not merely a matching pin table. All 61 existing results remain mandatory. An additional legacy-resistor
11% suffix control brings the complete required native suite to 75.
Independent test review found the original substring tolerance acceptance;
both tolerance gates now compare the complete tolerance field, and the
regressions require those misleading suffixes to fail.

This run also confirmed that shield pads are present in component records,
excluded from the purchasing BOM, and the new resistors belong to their
screen groups. AST parsing and the scoped whitespace check passed.

Source snapshots for this assessment:

- `switch_circuit.py`: `652502f1006b5019752c874b08ff431b5e8bc24cea1dcbf52d50cc513fd23a7e`
- `check.py`: `c7f09c4dc5df279cbf89780729f0cec15987fda8109aa0d770b8c3a7cb32f747`

Independent circuit review, new native placement/routing, complete native
checks and refreshed CAM remain pending. This correction removes the known
host-powered-coil suspend-current defect. It does not certify the complete
USB channel, cable/shield implementation, signal eye, attachment timing, ESD,
or assembled operation. The [USB-IF mandatory suspend-current update](https://compliance.usb.org/index.asp?UpdateFile=Electrical)
and [USB 2.0 electrical compliance specification](https://www.usb.org/sites/default/files/USB2%20Electrical%20Compliance%20Specification%20v1.08.pdf)
remain broader requirements than this bounded DC correction.
