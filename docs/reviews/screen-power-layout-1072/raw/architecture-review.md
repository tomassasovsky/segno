<!-- cspell:words Omron SUP SUM Littelfuse onsemi Nexperia derating PNP NPN Wurth Lumberg MOSFETs MMBT NPTH VGS VCE GPIO17 -->

# Architecture Review — Discrete screen switch circuit

## Scope and verdict

Baseline: `c275f94a`. Reviewed the replacement circuit on 2026-09-22 in
`hardware/kicad/screen_power/switch_circuit.py`, its dispatcher/custom symbols,
both generated component records and BOMs, and both native schematic
hierarchies/netlists. This is the circuit review requested while the compact
boards are being laid out. It does not approve unfinished placement, routing,
exports, or the still-superseded documentation. No implementation was edited.

**Open findings: Critical 0, Important 0, Suggestion 0.** The earlier
shared-collector reverse-blocking defect is resolved by D1. No further
concrete electrical blocker was found in the reviewed circuit. Physical
qualification remains required; this is not a claim that the screens or USB
paths have been tested.

The architecture is now the same for both assemblies: one opposed P-channel
MOSFET pair switches the existing AUX supply, four axial fuses feed two main
power outputs and two touch outputs, and two RF relays disconnect USB data.
There are no evaluation modules, native Type-C source controllers, USB
isolators, power relays, or clocks in this circuit. The hand component list
uses only through-hole parts and NPTH mounting holes. Factory assembly uses
surface-mount support parts and TO-263 power devices with the retained
through-hole connectors, RF relays, fuses, and electrolytics.

## Layer separation and native representation

`circuit.py` supplies the shared symbol setup and dispatches to
`switch_circuit.py`; the latter owns electrical connectivity and component
selection. Assembly differences remain in the part/footprint/pin mapping,
not duplicated electrical topologies. It hands the circuit to the schematic
writer and emits netlists, component records, and BOMs. No application-layer
or circular dependency was found in this reviewed path.

Fresh KiCad native schematic ERC with all severities enabled returned zero
violations for each variant. Independently exporting each native schematic
and comparing it with the generated netlist matched all **41 physical
component records and 27 connected nets per variant**, including the
hand/factory transistor pin-order differences. Unconnected relay contacts and
power-flag pseudo-components were excluded from that physical-net comparison.
These observations establish representation parity, not electrical performance.

## Resolved finding: isolate the dead AUX branch

Location: `hardware/kicad/screen_power/switch_circuit.py:71` through the D1/Q2
buffer network.

The earlier proposal connected the MOSFET gate sink and the AUX-referenced PNP
base network directly. With AUX absent and an externally powered output,
that branch pulled the gate below the common sources and defeated off-state
reverse blocking. The actual circuit has **D1 cathode at CONTROL_SINK and
anode at BUFFER_SINK**. It still conducts PNP base current into an enabled Q1,
but prevents a charged common-source/gate node from feeding the dead AUX base
network. This orientation is present in both independently exported native
netlists. The source-local gate pull-up is now **330 kΩ**, not the proposed
1 MΩ. The original finding is closed for the reviewed circuit.

Both selected isolation diodes specify 25 nA reverse leakage at 20 V and
25°C; their actual reverse stress here is approximately 5 V. This is a useful
room-temperature check, not a guarantee over the full semiconductor
junction-temperature range. Verify hot off-state leakage and shutdown delay
on the assembled board. [Vishay 1N4148](https://www.vishay.com/docs/81857/1n4148.pdf),
[Diodes 1N4148W](https://www.diodes.com/datasheet/download/1N4148W.pdf).

## Supply and control states

| Condition | Result supported by circuit connectivity |
| --- | --- |
| GPIO low or control lead absent | R2 holds Q1 off; R4 brings both power gates to their common sources; R6/R7 hold the data drivers off. |
| AUX and GPIO high | Q1 pulls the power gates low and sinks the PNP base through D1; Q2 raises DATA_ENABLE. Each data relay additionally needs its own host VBUS. |
| Either host VBUS absent | That relay releases; the other host rail cannot power its coil. |
| AUX absent, GPIO low, output charged or externally powered | D1 isolates the dead AUX buffer branch; R4 restores the opposed pair's off state after the turn-off interval. |
| AUX absent, GPIO high, output externally powered | The commanded-on power pair can conduct backward. It is bidirectional when enabled, not an ideal-diode controller. |

J2 pin 1 is GPIO17 and pin 2 is ground, matching the established console J25
interface. The existing Pi-to-console ribbon stays unchanged. All grounds are
common; neither the RF relays nor the power switch provide system galvanic
isolation. Host VBUS has exactly four physical endpoints per channel: USB-B
pin 1, relay coil pin 1, flyback cathode, and its 100 nF capacitor. No panel
power or AUX rail is connected to that host net. The coil drain and flyback
anode are separate for each channel.

Q3/Q4 are correctly wired gate 1, drain 2, source 3, with joined sources and
external drains on AUX/SWITCHED_5V. Opposed body diodes support blocking in
both directions when off. Both exposed power-device tabs are drain, therefore
different nets; the hand devices must not share an uninsulated heatsink or
touch tabs. Both selected Vishay devices specify 15 mΩ maximum at −4.5 V gate
drive and 25°C. [Vishay SUP](https://www.vishay.com/docs/77632/sup70101el.pdf),
[Vishay SUM](https://www.vishay.com/docs/77605/sum70101el.pdf).

## Driver and dissipation checks

The following are explicit circuit calculations, not measured results:

- With a conservative assumed 2.4 V GPIO high, 0.95 V Q1 base drop and 1%
  resistor extremes, Q1 receives about 1.426 mA base current after its
  pull-down. Its gate-sink transient plus PNP branch is approximately 2 mA
  or less; the steady load is smaller. The selected NPN pin maps correctly
  differ between TO-92 and SOT-23.
- At AUX = 5.0 V, allowing 0.85 V PNP base drop, 1.0 V D1 drop, 0.2 V Q1
  saturation and resistor tolerance still leaves about 0.513 mA PNP base
  current. DATA_ENABLE's steady load is only about 53 μA plus tiny gate
  leakage. Allowing 0.25 V PNP saturation gives approximately 4.75 V gate
  drive. [onsemi 2N3904](https://www.onsemi.com/download/data-sheet/pdf/2n3904-d.pdf),
  [onsemi 2N3906](https://www.onsemi.com/pub/Collateral/2N3906-D.PDF),
  [Nexperia MMBT3904](https://assets.nexperia.com/documents/data-sheet/MMBT3904.pdf),
  [Nexperia MMBT3906](https://assets.nexperia.com/documents/data-sheet/MMBT3906.pdf).
- The 2N7000 and selected 2N7002 each specify 5.3 Ω maximum at 4.5 V gate
  drive. With host VBUS = 4.75 V and a 237 Ω coil at its −10% tolerance,
  the coil receives about 4.635 V, above its 4.0 V initial pickup limit.
  Actual temperature, cable drop and release delay still need checking.
  [onsemi 2N7000](https://www.onsemi.com/download/data-sheet/pdf/nds7002a-d.pdf),
  [Nexperia 2N7002](https://assets.nexperia.com/documents/data-sheet/2N7002.pdf),
  [Omron RF relay](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g6k_2f_rf.pdf).
- At 5.0 V board input, 6 A through the pair and 15 mΩ per device, the
  common source is 4.91 V. Using 0.2 V Q1 saturation and worst-direction
  1% R3/R4 tolerances gives approximately 4.643 V gate drive. Pair loss is
  1.08 W. An illustrative 1.7× resistance increase gives 4.580 V drive and
  1.836 W loss. That multiplier is a scenario, not a guaranteed thermal bound.
- The permanent 100 Ω / 1 W bleeder dissipates at most about 0.278 W at
  5.25 V and its −1% resistance tolerance. It provides discharge without
  another switching stage, but an open branch fuse can isolate that branch
  from the shared bleeder.

The operating requirement remains **5.0–5.25 V at the PCB input**, nominally
5.1 V. Cable and fuse drops belong in the measured panel-voltage budget.
Neither the shared pair nor the fuse ratings establish a proven 10 A
continuous board rating. Actual copper and enclosure temperature determine
thermal acceptance; the data-sheet thermal mounting condition is not a
substitute for that evaluation.

## Exact through-hole coil-driver selection

Use **onsemi 2N7000** for hand Q101/Q201. The name without a suffix is an exact
orderable MPN: the current NDS7002A/D Rev. 11 ordering table lists it as a
TO-92 bulk part. The same primary sheet explicitly gives source 1, gate 2,
drain 3 and 5.3 Ω maximum at 4.5 V / 75 mA. Identify the manufacturer as
onsemi when purchasing; the generic family name alone does not guarantee
that other manufacturers or variants have the same low-voltage specification.
[onsemi ordering and electrical specifications](https://www.onsemi.com/download/data-sheet/pdf/nds7002a-d.pdf).

Do not substitute onsemi 2N7000BU on the basis of its similar name. Its
separate current data sheet specifies maximum on-resistance at 10 V only,
so it does not preserve this calculation. The factory part remains
Nexperia 2N7002,215, whose 4.5 V specification was checked independently.
[onsemi 2N7000BU/TA](https://www.onsemi.com/download/data-sheet/pdf/2n7000ta-d.pdf).

## Protection and USB limitations

The implemented 0251004.MXL main fuses and 0251.750MXL touch fuses are axial
Littelfuse 251 parts. Their 125 VDC/300 A interrupt ratings cover the intended
low-voltage source; 200% rated current opens them within one second. Their
nominal cold resistance is respectively 0.0204 Ω and 0.175 Ω. Standard 25%
continuous derating gives 3 A and 562.5 mA at the reference temperature before
hot derating. These are provisional fuse choices, not active current limits
or proof of actual panel load. The new local footprint represents the
7.11 × 2.80 mm maximum body envelope at 12.7 mm pitch, with 1.0 mm drills
for 0.64 mm leads. Factory assembly must fit these after reflow; their data
sheet prohibits convection/IR reflow. [Littelfuse 251](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688).

A panel joining main and touch power internally can bypass the touch fuse
through its main input. Keep this complete-harness limitation explicit. The
MOSFET network has no regulated current limit or specified soft-start;
measure startup demand and fuse pulse margin. Do not treat intrinsic gate
charge or R3 alone as a controlled ramp. [TI discrete load switches](https://www.ti.com/lit/an/slva716/slva716.pdf).

The RF relay energized contact paths are correctly 3–4 and 6–5; coil polarity
is pin 1 positive / pin 8 negative, contacts 2/7 are unconnected, and shield
leads are ground. Its RF rating supports the part choice but does not prove
USB compliance. The roughly 21 mA energized coil load per host is an explicit
fixed-appliance USB suspend limitation. Only one actual touch controller has
been observed at 12 Mbit/s; do not assume both panels have that speed.

Bench acceptance must include both real panels, both touch cables, host/AUX
power-loss combinations, external output power with GPIO low, hot leakage,
inrush, fuse behavior, temperature, enumeration/reconnection, and HDMI
back-power. Shutdown software must lower GPIO before HDMI video stops and
allow the measured turn-off/discharge interval. That software and those
physical measurements are not implemented or proven by this circuit review.

## Layout follow-up

No compact dimensions or routing are approved here. Retained connector
courtyards, plug access, the tall upright USB-A bodies, separate power tabs,
thermal copper, and through-hole solder access still constrain placement.
Place each RF relay immediately behind its USB pair and keep its return plane
continuous. Keep the fused power paths short and sized for the intended
current. The final board must receive a fresh geometry, copper, and native
DRC review; the previous 130 × 120 mm board's green results do not apply.

## Reviewed artifact identity

SHA-256 values below bind this circuit review. A later circuit or schematic
change needs a delta review. Paths are relative to `hardware/kicad/screen_power/`.

| Artifact | SHA-256 |
| --- | --- |
| `switch_circuit.py` | `0325f73e5b86a738e0117c0172c062fca61a4d0c72bb6c89bafd0b10aa79ff8d` |
| `circuit.py` | `ce15ced01c26339f13e00f35b7a2e6d99158e33707b51cf0f906c090e423797a` |
| `schematic.py` | `a544106dbac30b7547f2f7c7afeb6975382ef6776477e09fd7de9f401a609af0` |
| `hand/screen_power_hand.net` | `59b108bac3816dfc3eb582419ffb601452d30051dfe55c107a01e70418a977df` |
| `hand/components.json` | `348f003adfd456f20f59f97ea018351370ec7f525567b966b6bf54d299174040` |
| `factory/screen_power_factory.net` | `39ff08737b87779568610f9f8bfb7d9188408fe1df15d82eef410ca3fb535a9d` |
| `factory/components.json` | `ae742c97ce85b0d5239d0d66d40d0dc0112f55a9b89c99ae0700b21dd60e522b` |
