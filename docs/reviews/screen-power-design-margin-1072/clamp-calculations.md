<!-- cspell:words precharged precharge -->

# Rejected gate-clamp proposal: calculation record

25 September 2026. **Not adopted: release of Q5 while enabled remains
unclosed.** The proposal needs a redesign or a defensible release bound;
it is not simply waiting for a resistor choice. No validator, circuit or
manufacturing source was changed to adopt it. The existing Rev K power
stage remains unchanged, and this note is not a release approval.

Historical proposal evaluated below: Q1 TN0702N3-G; Q5 2N3906BU with emitter at COMMON_SOURCE,
collector at POWER_GATE and base through R9 to DATA_ENABLE. R1/R2 remain
1 kΩ/100 kΩ; R3/R4 remain 4.7 kΩ/330 kΩ. R5/R6 are 1 kΩ, R7 is proposed
as 470 Ω, R9 as 10 kΩ, and R8 as 100 Ω / 1 W. All resistors are 1%.
Later consideration of R7 = 560 Ω and R9 = 15 kΩ did not close Q5's
enabled-state release; these were not adopted values either. Numerical
results below retain their explicitly stated historical resistor values.

The calculation envelope is 4.8–5.25 V at loaded J1 and 4.25 A screen-stage
planning current. It does not establish the external buck's actual voltage.
Six amperes remains a comparison, not the required screen load.

## Static drive, conditional on Q5 releasing

The [TN0702 datasheet, p. 2](https://ww1.microchip.com/downloads/en/DeviceDoc/TN0702-N-Channel-Enhancement-Mode-Vertical-DMOS-FET-Data-Sheet-20005941A.pdf)
specifies 5 Ω maximum at VGS = 2 V and 25 °C. Using twice that resistance
at elevated temperature is an explicit engineering estimate, not a
guaranteed 2 V hot-resistance specification.

With a 2.4 V GPIO high and 100 nA gate leakage, the resistor corner gives
2.3757 V at Q1's gate. A conservative simultaneous sink bound is
`5.25/(0.99*4700) + 5.25/(0.99*1000) = 6.431 mA`, or 64.31 mV across
the estimated 10 Ω Q1. This overestimates steady current by omitting the
diode and junction drops.

Using the existing 15 mΩ power-FET resistance, estimated hot factor 1.7,
and worst-case R3/R4 divider gives:

`|VGS| = (4.8 - 4.25*0.015*1.7 - 0.06431) * 326700/(326700+4747)`

The result is **4.561 V**. It is valid only if Q5 does not supply significant
opposing collector current into POWER_GATE while enabled.

Using 0.95 V Q2 base-emitter drop and 1 V D1 drop gives Q2 base current
of at least **1.799 mA** under the same model. Proposed R7 requires up to
**11.285 mA**, including a 2 µA gate-leakage allowance: forced beta 6.27.
R8's worst-case dissipation is **0.2784 W**, below half its 1 W rating.

## Reasons this proposal was not adopted

1. The [2N3906BU saturation specifications](https://www.onsemi.com/download/data-sheet/pdf/pzt3906-d.pdf)
   are 0.25 V at 10 mA collector / 1 mA base, and 0.4 V at 50 mA / 5 mA.
   R7 = 470 Ω demands more than 10 mA. Using the conservative 0.4 V
   allowance gives DATA_ENABLE = 4.4 V at minimum J1, below the 4.5 V
   gate condition used for the existing 2N7000 relay-driver calculation.
   R7 = 560 Ω would reduce maximum demand to 9.472 mA and permit the
   0.25 V calculation at reference conditions. Neither saturation value
   is a guaranteed all-temperature bound.
2. Q5's emitter is close to AUX_5V, while its base is driven from Q2's
   saturated collector. At light load Q5 can retain approximately
   Q2's saturation voltage as positive emitter-base bias. A positive
   0.25–0.4 V bias is not a datasheet-guaranteed cutoff condition for a
   hot PNP transistor. The 4.561 V gate result must not silently assume
   zero Q5 collector current. Its release needs either a circuit change
   or an explicitly justified leakage/current bound.

## Off-state mechanism

With DATA_ENABLE low, Q5 sources gate charge from COMMON_SOURCE. This is
the correct reference for a precharged output with AUX absent. Its base
current also raises DATA_ENABLE through R7. Even taking Q5 VBE as zero,
the divider gives **0.2402 V** for 470 Ω or **0.2837 V** for 560 Ω, using
5.25 V and resistor tolerances. These values exclude additional device
leakage, which must be budgeted separately.

The clamp's base-drive margin must cover Q1's published 100 µA leakage
at 125 °C plus other leakage paths, including D1 under output precharge.
The GPIO gate pull-down remains necessary for an unplugged or unpowered Pi.
This circuit adds no active current limit. Retaining R3 avoids the proposed
22 Ω gate-drive path, but does not establish startup SOA, exact rise time,
or compatibility with an undocumented buck hiccup characteristic.
