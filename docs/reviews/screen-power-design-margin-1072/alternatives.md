<!-- cspell:words PDIP Digi overcurrent NPBF Infineon Omron undervoltage -->

# Screen power design-margin alternatives

Research record, 25 September 2026, issue #1072. This note records options;
**it does not adopt a power-stage change or approve manufacturing files**.

The owner wants one PCB order, an entirely through-hole assembly, two copper
layers, the selected XH cable interfaces, and no prototype or pre-PCB tests.
The 40-LED ring remains on its separate power path. The screen-stage planning
load is 4.25 A; the former conditional 6 A allowance is not a new requirement.
The design work must address margins without returning a prototype checklist
to the owner. Normal checks after assembling the purchased boards remain
distinct from a requirement to build a prototype before ordering.

## Integrated protected switches

**MIC2545A-1YN**, PDIP-8, is the strongest stocked through-hole integrated
candidate examined. It operates from 2.7–5.5 V and provides a charge pump,
controlled turn-on, adjustable current limiting and thermal shutdown.
MIC2549A adds a thermal-shutdown latch. The switches block reverse current
when disabled, but conduct bidirectionally when enabled.
[Microchip DS20006921A, pp. 3–4 and 13–16](https://www.microchip.com/content/dam/mchp/documents/APID/ProductDocuments/DataSheets/MIC2545A-49A-Programmable-Current-Limit-High-Side-Switch-DS20006921.pdf)

The nominal 3 A setting does not guarantee a 3 A load. Using the specified
184–276 V current-limit factor and 78.7 Ω ±1% gives **2.315–3.542 A**. This
resistor also stays above the stated 76.8 Ω lower boundary. One part per
screen therefore does not cover a 2.5 A screen-plus-touch allocation. The
50 mΩ maximum resistance is specified at 5 V; typical low-voltage curves
must not be promoted to guaranteed bounds.

Three devices feeding the two main inputs and shared touch feed can become
interconnected inside the screens. Four devices can still be interconnected
within each screen. No manufacturer-supported parallel arrangement was
verified, so adding devices does not by itself close the current margin.

[DigiKey lists MIC2545A-1YN](https://www.digikey.com/en/products/detail/microchip-technology/MIC2545A-1YN/3879237)
in stock at approximately US$6.07 for one in the research snapshot. Small-
quantity authorized stock was **not verified** for MIC2549A-1YN; this is not
a claim that the part is discontinued or universally unavailable.

## External MOSFET drivers and circuit breakers

| Candidate | Useful improvement | Unclosed tradeoff |
| --- | --- | --- |
| MIC5014YN, PDIP-8 | Specifies at least 4 V gate enhancement above its supply over 3–30 V and operating temperature. This removes the present dependency on almost the entire 5 V rail appearing across a P-channel gate. | Requires different N-channel power devices and an audited reverse-blocking connection. It supplies gate drive, not active current limiting or external-FET thermal protection. A 4 V guarantee does not justify a MOSFET resistance specification requiring 4.5 V. |
| LTC1422IN8#PBF, PDIP-8 | Charge pump, programmable ramp and overcurrent circuit breaker. | Published numerical gate-enhancement and trip specifications use a 5 V test condition. It trips rather than regulating current; startup still requires a stated load-capacitance envelope and MOSFET safe-operating-area analysis. Small-quantity authorized stock was not verified. |
| LTC1153CN8#PBF / LTC1153IN8#PBF, PDIP-8 | Charge pump and automatic retry after an overcurrent trip; manufacturer reference circuits cover capacitive startup. | The 75–125 mV sense threshold gives a wide trip window. Gate enhancement is specified at 5 V, without a numerical minimum row at 4.5 V. Hold-up, gate discharge, supply loss and restart need explicit design. Small-quantity supply was not established. |

Primary sources: [MIC5014/5, DS20006767A, pp. 3–4](https://ww1.microchip.com/downloads/aemDocuments/documents/APID/ProductDocuments/DataSheets/MIC5014-5-Low-or-High-Side-MOSFET-Drivers-DS20006767.pdf),
[LTC1422, pp. 2 and 6–9](https://www.analog.com/media/en/technical-documentation/data-sheets/1422fb.pdf),
[LTC1153, pp. 2–3, 5 and 9–12](https://www.analog.com/media/en/technical-documentation/data-sheets/lt1153.pdf).
The MIC5014 primary PDF was inspected directly. LTC1153 details here were
cross-checked against a teammate's page-referenced primary-source extract.
ADI lists the LTC1422 PDIP variants as
[in production](https://www.analog.com/en/products/ltc1422.html).
The teammate found an indexed Rochester in-stock indication for LTC1153,
but no readable current quantity or price; that is not a confirmed supply
commitment and not evidence of discontinuation.

For comparison, LTC1422's 44–64 mV threshold with 9 mΩ ±1% gives a calculated
**4.840–7.183 A** trip window at the specified test condition. A provisional
10 mF load-capacitance envelope and 100 ms ramp would add about 0.55 A at
5.5 V. The capacitance is an engineering assumption, not an observed screen
value. These calculations alone do not prove startup, hot SOA or fault
survival; turn-off must include discharge of any intentional gate capacitor.

### MIC5014 and opposed N-channel pair: not adopted

The bounded follow-up found **IRL3705NPBF**, a TO-220 part with maximum
18 mΩ resistance at 4 V gate drive and 25 °C. Two devices at 4.25 A give
153 mV drop and 0.650 W total loss. Doubling the resistance as an explicit
hot estimate gives 306 mV and 1.30 W; this is not a guaranteed hot rating.
[Infineon IRL3705N datasheet, pp. 1–3](https://www.infineon.com/assets/row/public/documents/24/49/infineon-irl3705n-ds-en.pdf)
[DigiKey's research snapshot](https://www.digikey.com/en/products/detail/infineon-technologies/IRL3705NPBF/812272)
listed 6,981 pieces at US$2.41 each; stock and price can change.

IRL2505PBF specifies a lower 13 mΩ at 4 V, but Infineon marks it
[discontinued](https://www.infineon.com/part/IRL2505?intc=reco), and current
small-quantity stock was not verified. IRL1404's low-resistance guarantee
starts at 4.3 V, above MIC5014's 4 V floor.
[IRL2505 datasheet, p. 2](https://www.infineon.com/assets/row/public/documents/24/49/infineon-irl2505-datasheet-en.pdf),
[IRL1404 datasheet, p. 2](https://www.infineon.com/assets/row/public/documents/non-assigned/49/infineon-irl1404-datasheet-en.pdf)

The direct common-source pair is rejected as a completed replacement.
MIC5014 limits both Source and Input pins to V+ in its absolute ratings.
During AUX collapse, an output charged while the pair was on can leave the
common-source node above V+ until it discharges. An active Pi can likewise
drive a direct input above an unpowered V+. The manufacturer examples do
not establish this opposed-pair supply-loss behavior, and no unpowered
gate-discharge guarantee was found. IRL2505 and IRL3705N also have ±16 V
gate ratings, below the driver's 17 V upper clamp specification. The
published maximum turn-on time uses a 1 nF test load; it does not establish
the two-FET startup ramp. Additional protection and sequencing would need
a complete circuit review, so this research does not authorize a swap.
[MIC5014/5 datasheet, pp. 3–4 and 7–12](https://ww1.microchip.com/downloads/aemDocuments/documents/APID/ProductDocuments/DataSheets/MIC5014-5-Low-or-High-Side-MOSFET-Drivers-DS20006767.pdf)

## Power relay

Omron **G5RL-1A-E-HR DC5** removes semiconductor gate-drive and linear-mode
SOA concerns. Its normally open contact also provides an uncomplicated
unpowered disconnect. However, the 16 A / 24 V DC rating is resistive; the
100 A inrush approval examined is at 240 V AC and cannot be relabelled a
5 V DC capacitive-load guarantee. Initial contact resistance is specified
up to 100 mΩ: at 4.25 A that corresponds to **0.425 V drop and 1.81 W**.
The 70% pickup specification is at 23 °C coil temperature and alone does
not prove hot pickup from a low 5 V supply. The package is also substantially
larger than the existing switching devices.
[Omron G5RL datasheet, pp. 1–3 and approvals](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g5rl.pdf)

These are concrete reasons not to adopt this relay merely because its
headline current rating is high. They do not establish that every power
relay is unsuitable.

## Minimal driver adjustment: not adopted

Replacing Q1 with a low-threshold **TN0702** is a provisional way to reduce
the present bipolar driver's on-state voltage loss. It retains the existing
power MOSFETs and offers a static gate-margin improvement. Hot off-state
leakage must be checked against the gate pull-up: the change cannot inherit
the old resistor assumptions without calculation. Reducing R3 improves
gate pull-down and switching speed, but also increases startup charging
current; it is not free extra margin. No final resistor values or TN0702
adoption are recorded here.

The subsequent TN0702 plus PNP gate-clamp proposal was also not adopted.
Its clamp-off behavior improved, but the clamp's release while enabled
remained unbounded by the cited transistor specifications. Changing a
resistor does not by itself close that issue. The historical calculations
and rejection are recorded in [clamp-calculations.md](clamp-calculations.md).
The existing Rev K power stage remains unchanged; neither note approves
an order revision.

An inverting charge pump with isolated or level-shifted control was also
considered as a way to retain the P-channel pair. It would add supply and
control sequencing to audit and would not provide active current limiting.
No complete circuit or component selection was adopted.

The decision must distinguish a switch that remains safely driven during
a 4.5 V brownout from a claim that the nominal-5 V screens operate below
that voltage after fuse, switch and cable losses. None of these alternatives
establishes an undocumented screen undervoltage rating.
