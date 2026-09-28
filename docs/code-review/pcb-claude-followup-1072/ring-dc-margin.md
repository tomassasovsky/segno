<!-- cspell:words Seeed IOVDD Rext Reff VSEL SGMICRO -->
# Ring encoder DC pull-up margin — 2026-09-27

Verdict: no stronger pull-up or PCB change is indicated. This is a bounded DC-input check, not a new all-load regulator qualification or transient analysis.

## Actual circuit and runtime

Current hardware `hardware/kicad/ring_board.py:79,146,287–299` connects R2/R3/R4 (10 kΩ) to the XIAO's own +3V3 output. Encoder contacts close directly to board GND; C2/C3/C4 are 10 nF. The current separate runtime's `firmware/ring_board/ring_board.ino:102–104` enables INPUT_PULLUP on D1/D2/D3 and does not subsequently substitute pull-downs. Seeed's schematic maps those pins to GP27, GP28 and GP5; +3V3 is also the MCU IOVDD rail.

The prior full ring review already read E9 and did not establish a pulled-up encoder defect. This recheck independently confirms the reason.

## E9 is not a high-state sink-current penalty

The [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf), E9 pp.1366–1368, describes A2's excess leakage as sourcing current in the undefined input region. Its representative 120 µA is not a maximum sink current. The manufacturer explicitly says an enabled pull-up pulls the input to IOVDD and removes the condition. Applying 120 µA × 10 kΩ as a high-state voltage loss would have the wrong current direction. Closed mechanical contacts also provide the low-impedance ground needed to escape that region; they are not a UART source behind the console's series R18.

For ordinary input leakage, Table 1436 (pp.1339–1340) gives IIN ≤1 µA, VIH =2.0 V for 3.3 V IOVDD, and internal RPU =32–86 kΩ. These limits cover both the standard and FT inputs used here.

## Calculation and regulator evidence

Taking an explicit ±5% resistor sensitivity (the generic BOM does not require a tighter tolerance): Rext,max=10.5 kΩ. With the weakest listed internal pull-up, Reff=10.5 kΩ ||86 kΩ=9.357513 kΩ. A 1 µA adverse ordinary leakage loses at most 9.358 mV; ignoring the internal pull-up altogether increases this only to 10.5 mV. Nominal input is consequently ≥3.29064 V, leaving 1.29064 V against the 2.0 V high threshold.

The [Seeed XIAO RP2350 v1.0 schematic](https://files.seeedstudio.com/wiki/XIAO-RP2350/res/Seeed-Studio-XIAO-RP2350-v1.0.pdf), physical PDF page 4, shows SGM6029CYG/TR, 249 kΩ ±1% VSEL resistor, 0.47 µH inductor and the +3V3 output. Physical page 5 shows the same rail on MCU IOVDD and the header. This is an onboard regulated rail, not an assumed copy of the AUX rail.

[SGMICRO SGM6029](https://www.sg-micro.com/product/SGM6029) publishes 2% output accuracy over temperature and the C variant's 1.8–3.3 V selection. Its linked datasheet Rev. A.1, electrical table on p.5, conditions the ±2% accuracy entry on PWM and IOUT=0 mA; do not label it a complete loaded-module floor. At that documented accuracy corner, 3.3×0.98−0.009358=3.224642 V, leaving 1.224642 V. Even without crediting the internal pull-up, the margin is 1.2235 V. This calculation does not invent a ±5% regulator specification, and the VSEL resistor tolerance must not be added as though it were a feedback-divider gain error.

The specific alleged need to strengthen the 10 kΩ encoder pulls is closed by the manufacturer's E9 behavior and the roughly 10 mV ordinary DC leakage loss. A failure of the board's nominal 3.3 V regulator large enough to erase over 1.2 V of margin would be a separate supply-failure condition; replacing these pull-ups cannot qualify such a condition. No edits or new owner measurements are requested.
