<!-- cspell:words datasheets -->
# Revision L independent electrical review

Comparison base: `7dcdc944`. The reviewed target was the uncommitted Revision L
electrical implementation, identified by the source hashes below. This review
covered `switch_circuit.py`, the electrical portions of `check.py`,
`hand_checks.py`, the generated netlist, the gate-drive/startup assessments and
the documented power budget.

**Result: no actionable findings in this bounded review.** This is not a
review of the final PCB layout, manufacturing exports or assembled behavior,
and does not establish a clean review of the complete PR head.

## Independent checks

Pin assignments and component limits were checked against the primary
[TI LMC7660](https://www.ti.com/lit/ds/symlink/lmc7660.pdf),
[Toshiba TLP627M](https://toshiba.semicon-storage.com/info/docget.jsp?did=163903&prodName=TLP627M),
[Vishay SUP70101EL](https://www.vishay.com/docs/77632/sup70101el.pdf) and
[Microchip TN0702](https://www.microchip.com/content/dam/mchp/documents/APID/ProductDocuments/DataSheets/TN0702-N-Channel-Enhancement-Mode-Vertical-DMOS-FET-Data-Sheet-20005941A.pdf)
datasheets. The generated netlist matches the independent circuit contracts.
GPIO low/floating, AUX loss and charged-output states were traced; removal of
D1 does not connect the negative supply to the Pi control input.

The numerical checks reproduce 6.110 V minimum modeled gate drive, or
5.289 V with the 2 V optocoupler stress allowance, versus the 4.5 V resistance
specification. Modeled maximum gate drive is 8.682 V and the specified
85°C optocoupler dark current produces 0.444 V gate bias. Pump loading,
control drive, relay pickup and the 7.608 A AUX planning total are consistent
with their documented assumptions.

The Vishay page 5 thermal plot was inspected independently. Approximately
0.009 normalized impedance at 26 ms and 0.017 at 100 ms correspond to
0.36°C/W and 0.68°C/W using the datasheet's 40°C/W mounting condition. The
startup assessment correctly keeps those estimates distinct from the assumed
upright steady thermal model. These calculations do not establish an exact
screen inrush peak or measured enclosure temperature.

## Negative controls

The unchanged netlist passed the contract and numerical checks. Thirteen
independent temporary, in-memory mutations were then correctly rejected:

| Mutation | Rejection |
| --- | --- |
| R4 changed to 330 kΩ | Off-state leakage margin |
| R9 changed to 24 kΩ | Optical drive margin |
| R10 changed to 1 kΩ | Optical drive margin |
| U1 changed to ICL7660 | Unsupported driver model |
| C4 changed to a polarized 10 µF capacitor | Unsupported capacitor model |
| Q101 changed to 2N7000 | Unsupported relay-driver model |
| R3 changed to 100 kΩ | Gate-drive margin |
| U1 LV pin connected to GND | Pump control contract |
| D2 anode and cathode swapped | Circuit and supply-boundary contracts |
| U2 collector and emitter swapped | Circuit and supply-boundary contracts |
| U2 emitter connected to GPIO17 | Circuit and supply-boundary contracts |
| U1 pin 2 connected to PUMP_CAP_MINUS | Circuit and supply-boundary contracts |
| Q101 source and drain swapped | Circuit contract |

These checks did not modify circuit, CAD or manufacturing files. They
supplement the repository's own fault-injection suite; they do not replace
the complete final-board validation.

## Reviewed source snapshots

SHA-256 values, relative to `hardware/kicad/screen_power/`:

| File | SHA-256 |
| --- | --- |
| `switch_circuit.py` | `9869038ee6a4a3c8d7459db4d09ee7e4bdb20d54c6102d3a10e4fd16c95164ec` |
| `check.py` | `de981ff059470939e8a0747096f84e4c750eaad4ce7b9adad00537e28a6121f5` |
| `hand_checks.py` | `92e6f017791bd62e2accb6adf20ade2c4ad0ea7652942574c6d03fb5ae35e655` |
