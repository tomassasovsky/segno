<!-- cspell:words unswitched derating Mbps -->
# Screen-board connection and power acceptance matrix

25 September 2026. This records the assembly contract and available evidence
for #1072. Final native Revision K board SHA-256:
`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`.

The [subsequent Claude follow-up](../screen-power-claude-fixes-1072/verification.md)
adds a specified inline screen fuse/holder and R8 assembly model; this is the
original K audit. Current assembly instructions supersede its unspecified
upstream-protection entry below.

It does not certify assembled operation or replace manufacturing-export
correspondence checks. The detailed independent audit is in
[raw/system-wiring-audit.md](raw/system-wiring-audit.md); the complete wiring
instructions are in [hardware/segno_wiring.md](../../../hardware/segno_wiring.md).

## Connections

| Connection | Required wiring | Acceptance |
| --- | --- | --- |
| AUX buck → screen J1 | 1 = +5 V, 2 = GND; dedicated short 16 AWG pair, VHR-2N and SVH-41T-P1.1 contacts. | Screen current bypasses the console PCB; upstream branch protection is an assembly requirement. |
| Console J25 → screen J2 | 1 = GPIO17, 2 = GND; 22 AWG XH2, pin-for-pin. Existing Pi ribbon remains direct. | Only two control wires; no screen load on GPIO or ribbon 5 V. |
| Pi USB 2.0 → J101/J201 | Two USB-A-to-XH4 leads: 1 VBUS, 2 D−, 3 D+, 4 GND. | Native map checked. Host VBUS feeds only its relay coil and bypass capacitor. |
| J102/J202 → screen touch | USB-C to UPERFECT; Micro-B to APROTII. Same four-pin map; pin 1 is now fused switched VBUS. | Native data map checked. Purchased leads still require correct pin order, USB-C source-role configuration and reliable enumeration. |
| J103/J203 → screen main power | 1 = switched fused +5 V, 2 = GND. Each lead ≤30 cm, both conductors 20 AWG or larger, terminations rated 3 A. PCB end uses VHR-2N/SVH-41T-P1.1 within its 20–16 AWG range. | Retain the known-working USB-C/Micro-B screen termination and any CC/plug electronics; existing lead gauge is not yet recorded. |
| Pi HDMI → both screens | Existing HDMI connections. | Owner reports both screens fully dark with power and touch removed while HDMI remains attached. |
| Console J6 → ring J1 | Straight XH4: +5 V, GND, console-to-ring, ring-to-console. Power/ground 22 AWG. | Separate ring path; current does not pass through screen MOSFETs. One 40-pixel strip or one alternative ring module. |

Never leave direct Pi-to-screen touch or unswitched buck-to-screen power in
parallel. Keep each main-power return intact; GPIO/USB grounds are not substitute
power returns. A screen may internally join its main and touch supplies: both
are switched here, but current sharing and fault current can involve both
branch fuses. The 28 AWG touch leads are not main-power leads. An unspecified
charge-only cable does not establish a suitable USB-C attachment configuration.

## Power boundary

| Quantity | Design allowance or evidence |
| --- | --- |
| Shared screen-board load | Conditional 6.000 A total, including both main feeds, both touch feeds and the approximately 0.05 A bleeder. |
| Individual branches | Main ≤3 A each; touch ≤0.5 A each at reference conditions. These limits are not additive; fuses are not active limiters. |
| Full-white 40-pixel ring | 2.400 A LED channels +0.040 A pixel idle +0.200 A controller/buffer =2.640 A through the ring connector. |
| Full-white ring plus normal pills and screen allowance | 9.358 A AUX total; 0.642 A nominal margin below the retained 10 A buck. Bleeder counted once. |
| All 120 pixels at unrestricted white plus screen allowance | 13.660 A; outside the retained AUX supply budget. |
| Reported screen readings | Large: about 1.3–1.4 A, up to 9 W steady and below 10 W startup. Small: about 0.8 A, up to 6 W steady and 4 W startup. Inconsistent fields are not a precise combined peak measurement. |
| Expected-load planning bracket | 3.25–4.25 A through the screen switch, including a conservative extra 1 A touch allowance and bleeder; approximately 6.61–7.61 A AUX with the full-white ring and normal pills. |
| 20 V inlet at full design allowances | 71.79 W delivered by both bucks; approximately 79.8–84.5 W input at assumed 85–90% efficiency, or 3.99–4.22 A. Retain the 20 V /5 A /100 W contract; actual efficiency, fuse/holder derating and transients are not qualified. |
| Voltage assumption | Switch calculations use 5.0–5.25 V at J1. A fixed nominal 5 V buck plus wiring loss does not guarantee that floor. Screen terminals also lose switch, fuse, copper, connector and cable voltage. |

The selected standard VH connector's 10 A claim requires 16 AWG; use it for
both screen J1 and console J3 feeds. The selected XH ring connection's 3 A
rating requires 22 AWG. Match contact crimp range and insulation diameter.
[JST VH](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf),
[JST XH](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).

## What is checked and what first assembly establishes

| Behavior | Evidence/status |
| --- | --- |
| Connector nets and relay contacts | Independent inspection established the intended map. Final Revision K validation retains native-pad/schematic/netlist parity, relay-state behavior and physical USB/power connectivity; 36/36 checks pass with zero ERC/DRC findings. |
| Boot and orderly shutdown sequence | GPIO owner requests low initially; Weston enables before probing and requests off before normal termination. Independent host suite: 12/12 tests pass. Software was not deployed by this review. |
| Screen cutoff | Both main and touch supplies share the switched rail; data opens through the relays. HDMI-only darkness was reported by the owner. Actual GPIO cutoff timing still belongs to first assembly. |
| Discharge interval | Five-second software wait is provisional. It is not proof that every screen is dark before HDMI stops. A hung Pi is not detected by this board. |
| USB touch | UPERFECT requires its 480 Mbps upstream hub link; APROTII is 12 Mbps. Cable continuity, USB-C orientation and reliable reconnect need the actual assembly; no USB compliance claim. |
| Current, temperature and faults | Budgets support the intended prototype. Actual loaded voltage, warm operation, startup and fuse coordination remain unqualified. No particular heatsink fit or guaranteed operating temperature follows from this matrix. |

These are the existing first-assembly boundaries, not additional owner
measurements required before buying the bare PCBs. The completed 5 V screen
tests need not be repeated to establish that those screens can run on 5 V.
