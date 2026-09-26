# Revision L screen-power startup and thermal assessment

<!-- cspell:words NOPB PDIP -->

Date: 2026-09-25. Issue: #1072.

## Decision and scope

The proposed negative gate supply gives the existing opposed SUP70101EL
MOSFETs adequate operating gate voltage. The calculations below support their
use with these screens without adding active current limiting. This is a
bounded engineering assessment, not a measured inrush waveform or a guarantee
of surviving an indefinitely shorted output. It does not introduce a
pre-fabrication prototype or measurement requirement.

This assessment covers the Revision L circuit definition: LMC7660IN/NOPB
PDIP inverter, TLP627M through-hole optocoupler, 4.7 kΩ gate resistor, 22 kΩ
gate-to-common-source pull-up, BAT85 positive-excursion clamp, and two 10 µF
nonpolar Panasonic ECE-A1EN100U pump/reservoir capacitors. The original
AUX-powered USB enable buffer remains; its relay drivers become TN0702N3-G.
Final schematic, board and manufacturing-file parity are separate checks.

## Evidence and assumptions

- The owner observed less than 10 W during large-screen startup and up to 9 W
  during its image sweep; the small screen reached 4 W during startup and
  6 W during its sweep. The displayed current and wattage were not mutually
  precise. These observations support the operating budget but do not capture
  microsecond or millisecond peaks.
- Use 4.25 A as the conservative combined screen planning current. It is not
  a newly required measured limit. A 3.25 A case is also shown below.
- AUX is the retained nominal 5 V / 10 A buck. Its rating is not a guaranteed
  instantaneous current clamp. Output capacitors can supply brief additional
  current, and its overload timing is unspecified.
- Assume local enclosure air no hotter than 60 °C. For steady upright
  MOSFETs without heat sinks, use 75 °C/W per device as an engineering allowance.
  This is distinct from Vishay's 40 °C/W PCB-mounted datasheet condition.
- The 1.7 multiplier on the 15 mΩ maximum resistance at 4.5 V gate drive is
  a conservative hot-resistance allowance, not a second guaranteed maximum.
- Capacitance cases are sensitivities. Only the board's approximately 0.3 mF
  of downstream capacitance is known; 1–10 mF explores added screen input
  capacitance without asserting what the screens contain.

## Steady conduction

Use the existing 4.5 V resistance specification even though the new gate drive
is stronger; do not substitute the 10 V specification.

```text
R_hot = 0.015 Ω × 1.7 = 0.0255 Ω per MOSFET
P_each = I² × R_hot
T_j_estimate = 60 °C + P_each × 75 °C/W
```

| Combined screen current | Loss per MOSFET | Pair voltage drop | Estimated junction |
| --- | --- | --- | --- |
| 3.25 A | 0.269 W | 0.166 V | 80.2 °C |
| 4.25 A | 0.461 W | 0.217 V | 94.5 °C |

These figures support operation without heat sinks at the planning load. They
exclude fuse, connector and cable losses. The 60 °C assumption means air
around the devices, including heating from nearby parts. A 100 °C initial
junction is used for the pulse comparison below, above the steady estimate.

Vishay specifies 15 mΩ at VGS = −4.5 V, ±20 V maximum gate voltage,
175 °C maximum junction temperature, and 190 nC maximum gate charge under
its stated test conditions. Its pulse SOA and thermal-impedance plots are on
page 5. [SUP70101EL datasheet, pages 1–2 and 5](https://www.vishay.com/docs/77632/sup70101el.pdf).

## Gate transition and supply sequencing

At the low input corner, the following deliberately conservative calculation
includes one hot MOSFET's source drop, resistor tolerances, a 90% negative
conversion allowance, and a 1.2 V optocoupler drop:

```text
J1 = 4.5 V; I = 4.25 A
V_source = 4.5 − 4.25 × 0.0255 = 4.391625 V
|V_negative| = 0.90 × 4.5 = 4.05 V
R_gate_max = 4747 Ω; R_pullup_min = 21780 Ω
|V_GS_final| = (4.391625 + 4.05 − 1.2) × 21780 / 26527
             = 5.946 V
```

At the point where gate drive reaches 4.5 V, the same calculation leaves
approximately 0.371 mA net gate current after the pull-up current. Charging
both full 190 nC figures with that current gives approximately 1.02 ms.
Allowing roughly 1–2 ms is a conservative transition estimate for an already
established negative rail, not a guaranteed timing maximum. Gate charge is
used rather than treating typical input capacitance as a complete switching
model. Source movement and the optocoupler's delay also affect the waveform.

The inverter runs whenever AUX is present, so normal boot establishes its
negative rail before the Pi's userspace service raises GPIO17. With 10 µF
capacitors, the nominal switching frequency and output-resistance model imply
millisecond-scale settling. If AUX returns while GPIO17 is already high,
conduction can begin before that settling finishes. There is no separate
rail-ready interlock or specified maximum inverter startup time; the slower
pulse sensitivities below provide margin for this case.

The LMC7660 operates across this input range with LV left open. Its full-range
voltage-conversion condition, output-resistance figures and capacitor circuit
support the lightly loaded negative supply. Leave the oscillator at its normal
frequency. The BAT85 clamp and nonpolar capacitors address positive excursions
during sequencing; they do not add soft-start or current limiting.
[TI LMC7660 datasheet, pages 2–3 and 6](https://www.ti.com/lit/ds/symlink/lmc7660.pdf).

The TLP627M has substantial collector-current margin at 1 mA LED drive for
this steady gate load below 1 mA. Its switching figures are typical, so they
are not used as a hard upper time limit.
[Toshiba TLP627M datasheet, pages 3–4](https://toshiba.semicon-storage.com/info/docget.jsp?did=163903&prodName=TLP627M).

The 4.5 V calculation establishes gate-drive margin. It does not certify the
screens' minimum connector voltage after every downstream loss.

## Startup capacitance sensitivity

Use a 5.25 V charging endpoint and an illustrative 2 A net capacitor-charging
current while the entire 4.25 A operating load is already present. This is a
deliberately slow charging scenario, not a current-control feature of the
board. It makes the screen branch draw 6.25 A and, with the existing 3.358 A
console/ring allocation, the AUX load 9.608 A.

For a linear voltage ramp, conservatively assign all pass-stage dissipation
to the downstream MOSFET:

```text
t = C × V / I_charge
E_capacitor_charging_loss = ½ × C × V²
E_total_pass_stage = ½ × C × V² × (1 + I_operating / I_charge)
```

| Total switched capacitance | Charge time | Capacitor charging loss | Total pass-stage energy |
| --- | --- | --- | --- |
| 0.3 mF | 0.79 ms | 4.1 mJ | 12.9 mJ |
| 1 mF | 2.63 ms | 13.8 mJ | 43.1 mJ |
| 5 mF | 13.1 ms | 68.9 mJ | 215 mJ |
| 10 mF | 26.3 ms | 138 mJ | 431 mJ |

The slowest row starts at 32.8 W and falls as the output rises. Replacing
that falling power with a constant 32.8 W rectangle is conservative. Reading
Vishay's normalized transient plot gives roughly 0.3–0.4 °C/W at 26 ms under
its 40 °C/W mounting condition: about 10–13 °C rise for that rectangle.

As a separate, more severe sensitivity, 10 A at the full 5.25 V for 100 ms is
52.5 W. The plot gives approximately 0.68 °C/W at 100 ms, or 36 °C rise:
approximately 136 °C from a 100 °C initial junction. Both examples also sit
comfortably inside the low-voltage pulse SOA; allow for the higher initial
temperature rather than using its 25 °C case-temperature curve unchanged.

These plotted pulse estimates use the manufacturer's mounting condition;
the 75 °C/W upright steady model cannot silently replace the plot's thermal
network. As a rough sensitivity only, scaling the 26 ms result by 75/40 gives
approximately 18–25 °C rise, still well below the available temperature
headroom. Applying that same rough scaling to the separate 100 ms stress
example gives about 67 °C rise, or 167 °C from a 100 °C initial junction.
That much smaller margin is another reason not to treat the stress example
as an upright-device fault-survival rating. Short pulses are dominated more by die/package thermal storage
than by the final steady board-to-air resistance. This supports the design
judgment without claiming a measured upright transient response.

## Conclusion

The corrected drive removes the known steady gate-voltage deficiency and
has useful startup margin for the observed screen loads across the stated
capacitance sensitivities. These results support proceeding with this design
without a new active current limiter or pre-PCB build requirement. Retain
the specified fuse and harness protections. Do not describe the buck as an
instantaneous 10 A limiter, claim an exact screen inrush peak, or extend this
assessment to indefinite overloads, damaged capacitors, or repeated hard
shorts.
