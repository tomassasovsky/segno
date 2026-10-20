<!-- cspell:words NOPB VOUT -->
# Rev L gate-drive design assessment

This note reviews the proposed gate-margin change independently of the PCB
implementation. It does not certify subsequently generated artwork. Keep the
opposed SUP70101EL-GE3 pair, two-layer construction, through-hole parts and
existing screen connectors. Screen planning load remains 4.25 A; the 40-LED
ring has its own power branch. This change adds gate-voltage margin, not an
active current limiter. Undocumented screen capacitance alone does not make
another startup-limiting circuit a release requirement.

## Circuit and pin contracts

- LMC7660IN/NOPB: pin 8 AUX_5V, 3 GND, 2 CAP_PLUS, 4 CAP_MINUS,
  5 NEG_5V. Leave 1, 6 (LV) and 7 (OSC) unconnected. Grounding LV at this
  supply voltage is explicitly prohibited. Fit a local 100 nF input bypass.
- Fit 10 µF Panasonic ECE-A1EN100U bipolar capacitors between pins 2–4 and
  between GND–NEG_5V. Both are 25 V, 5 mm diameter, 11 mm body height,
  2 mm lead pitch. Bipolar output capacitance tolerates the small positive
  clamp excursion without reverse-biasing a polarized electrolytic.
- TLP627M(E: pin 1 LED anode from AUX through 2.4 kΩ; pin 2 cathode to
  CONTROL_SINK. Put 10 kΩ across pins 1–2. Output pin 3 emitter goes to
  NEG_5V; pin 4 collector goes through R3 = 4.7 kΩ to POWER_GATE.
  R4 = 22 kΩ connects POWER_GATE to COMMON_SOURCE. All resistors are 1%.
- BAT85S-TAP: anode NEG_5V, cathode GND. Its cathode band faces GND. This
  clamps positive output injection during supply transitions; it is not a
  series diode in the negative gate path.
- Retain Q1 2N3904BU, Q2 2N3906BU and their existing base networks. Remove
  D1 and BUFFER_SINK; connect R5 directly from CONTROL_SINK to BUFFER_BASE.
  The optocoupler removes the galvanic gate-to-control path that originally
  required D1 to block charged-output current into an unpowered AUX supply.
- Substitute TN0702N3-G for Q101/Q201: pin 1 source/GND, 2 gate/DATA_ENABLE,
  3 drain/coil low. This matches the existing S–G–D footprint assignment.
  Keep the relay flyback diodes.

The [TI LMC7660 datasheet, pp. 1–3 and 6](https://www.ti.com/lit/ds/symlink/lmc7660.pdf)
defines the pump connections and LV restriction. The
[Toshiba TLP627M datasheet, pp. 2–4](https://toshiba.semicon-storage.com/info/TLP627M_datasheet_en_20250708.pdf?did=163903&prodName=TLP627M)
defines the optocoupler pins; the latest independently checked document is
Rev. 3.0, July 2026, with the same relevant electrical limits.
[Panasonic's exact capacitor page](https://industrial.panasonic.com/ww/products/pt/aluminum-cap-lead/models/ECEA1EN100U)
provides its dimensions, bipolar construction and 10.5 µA catalog leakage.

## Gate and control margins

Use 4.5–5.25 V at J1 for this assessment. At 4.25 A, conservatively retain the
15 mΩ resistance specified at −4.5 V drive and multiply by 1.7 as an explicit
hot-resistance engineering estimate. The input MOSFET's source drop is then
0.1084 V. Do not substitute the better −10 V resistance specification just
because the new gate voltage is higher.

The minimum divider ratio is
`22k×0.99 / (22k×0.99 + 4.7k×1.01) = 0.82105`.
With NEG_5V = −4.05 V and optocoupler VCE = 1 V,
`|Vgs| = (4.5 − 0.1084 + 4.05 − 1) × 0.82105 = 6.110 V`.
Allowing an engineering stress case of 2 V optocoupler drop still gives
5.289 V. At that 2 V drop, the negative rail could fall to −3.089 V before
gate drive reached 4.5 V. The high-supply divider limit is under 8.682 V,
comfortably inside the MOSFET ±20 V gate rating.

The [SUP70101EL datasheet, pp. 1–2](https://www.vishay.com/docs/77632/sup70101el.pdf)
supplies the resistance and gate ratings. The 1.7 temperature multiplier is
an estimate, not a manufacturer maximum over all temperatures.

At the low supply corner, allowing Q1 VCE = 0.2 V and LED VF = 1.4 V,
LED current after the 10 kΩ shunt is at least 1.055 mA. The optocoupler's
1 V saturation specification uses 1 mA LED current and 10 mA collector
current; the gate network needs less than 0.4 mA. This is substantial
practical drive margin, not a newly invented full-temperature saturation
guarantee. Its specified 20 µA dark current at 85°C creates at most 0.444 V
across R4. The LED shunt also prevents ordinary Q1 off leakage from turning
into appreciable LED current. Retaining the bipolar Q1 avoids the previous
low-threshold MOSFET's much larger specified hot leakage.

Q1's GPIO base drive remains ample: with GPIO at 2.4 V, a conservative
VBE = 0.95 V and resistor tolerances, available base current is approximately
1.426 mA. Ignoring LED and Q2 base-junction voltage drops gives a conservative
3.157 mA upper bound on its combined LED/shunt and Q2-base collector load;
the available base current is more than four times the forced-beta-10 need.
[The exact 2N3904BU datasheet](https://www.onsemi.com/download/data-sheet/pdf/pzt3904-d.pdf)
supports its pinout and 0.2 V saturation reference at 10 mA/1 mA.

## Pump loading, including leakage

TI specifies at least 90% voltage conversion with a 10 kΩ load across
3–10 V. At 4.5 V, its 90% point is −4.05 V and 405 µA test load.
Using zero optocoupler drop and no source drop maximizes the gate-network
load: `8.55 V / (26.7k×0.99) = 323.46 µA`.

Allow 50 µA for the clamp's hot reverse leakage and count both capacitors'
10.5 µA catalog leakages as an additional conservative pump burden. Total
is 394.46 µA at the low corner; at 5.25 V it is 448.37 µA versus a 472.5 µA
10 kΩ test load. Flying-capacitor leakage is charge-transfer loss rather
than a literal DC resistor across NEG_5V; counting it here avoids omitting
that loss from the comparison.

These totals are an engineering loading check, **not an unconditional hot
guarantee**. The capacitor catalog leakage conditions do not establish a
hot maximum. Likewise the 50 µA diode allocation is an allowance:
[BAT85S curves, p. 2](https://www.vishay.com/docs/85513/bat85s.pdf)
show only a few µA near 5 V/85°C, but are typical curves. The diode's
2 µA table maximum applies at 25°C/25 V. The gate calculation deliberately
has voltage margin beyond the 90% operating point; do not claim that the
small remaining current-budget difference proves every leakage corner.

## Power states and remaining limits

With AUX present and GPIO low or disconnected, Q1 and the LED are off.
R4 returns both gates to their common source, including when the screen
output retains charge. NEG_5V remaining charged cannot actively enable the
MOSFETs through an unlit optocoupler. AUX absent with GPIO high does not
supply the LED from GPIO; its power feed is AUX, and there is no negative
rail connection to the Pi control input.

If AUX rises with GPIO already high, the LED may conduct before the pump
finishes starting. The gate initially has less enhancement and strengthens
as NEG_5V develops. The BAT85S carries positive injection that would otherwise
lift the unpowered pump output; R3+R4 limit its steady component below
0.2 mA at 5.25 V, while gate-capacitance transients are brief. Bipolar
reservoir capacitance tolerates the clamp excursion. No delay or regulated
screen-current ramp is claimed.

When GPIO goes low, the LED turns off and 22 kΩ pulls the gate back to
COMMON_SOURCE, much faster than the old 330 kΩ pull-up. When AUX disappears
while GPIO remains high, an already-conducting pair can briefly let stored
screen energy feed AUX and the control circuit during discharge. This is
not instantaneous active reverse-current protection; the passive discharge
and loss of control power eventually turn the pair off. A charged output
applied to an already-off board has no active gate-enabling path.

Normal startup withstand still needs assessment against the MOSFET SOA and
actual gate network. Neither a clean DRC nor this static calculation proves
a universal capacitive-load envelope, and neither establishes a reason by
itself to add an active current limiter.

## USB relay drivers

[TN0702 DS20005941A, pp. 2, 3 and 6](https://www.microchip.com/content/dam/mchp/documents/APID/ProductDocuments/DataSheets/TN0702-N-Channel-Enhancement-Mode-Vertical-DMOS-FET-Data-Sheet-20005941A.pdf)
specifies 2.5 Ω maximum at 3 V gate drive and the S1/G2/D3 pin contract.
Using 5 Ω as an explicit doubled hot estimate gives 0.15 V drop and 4.5 mW
at an illustrative 30 mA coil current. DATA_ENABLE near 4.25 V therefore
has ample drive margin. The specified 100 µA zero-gate leakage at 125°C
would develop only about 15 mV across a 150 Ω coil, far below pickup.
Use the existing actual coil and host-voltage corner calculations for final
pickup verification; this substitution does not change the USB contacts.

## Implementation cross-check

The subsequent bounded source review found no actionable circuit or numeric
defect in the implemented change. The generated netlist passed the independent
pin contract and numerical checks. The installed KiCad symbol definitions also
match the package contracts: LMC7660 CAP+/CAP−/VOUT are pins 2/4/5, the
Schottky symbol is K1/A2, and the reused MOSFET symbol is S1/G2/D3.

Temporary, in-memory negative controls correctly rejected a 330 kΩ gate
pull-up, 24 kΩ LED resistor, 1 kΩ LED shunt, the former 2N7000 relay driver,
a different pump, a polarized reservoir value, grounded LV, incorrect
optocoupler/clamp connections and a reversed relay MOSFET. The unmodified
baseline was clean before those mutations; no repository test or CAD artifact
was changed by this review. This was a source/netlist/numeric review, not a
fresh complete layout or manufacturing-release review.

Source snapshot SHA-256:

- `switch_circuit.py`: `9869038ee6a4a3c8d7459db4d09ee7e4bdb20d54c6102d3a10e4fd16c95164ec`
- `check.py`: `de981ff059470939e8a0747096f84e4c750eaad4ce7b9adad00537e28a6121f5`
