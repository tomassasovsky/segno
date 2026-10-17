<!-- cspell:words onsemi Axicom precharged Yageo WIMA KSSD derating Littelfuse backfeed overcurrent overvoltage Mbps -->
# Complete screen-power electrical and datasheet audit

Date: 25 September 2026. Reviewer: independent Codex circuit-audit agent.
Baseline: `9a5798be6c4ea9b0aae2a88fe7168b6751cab441`.

This reviews the complete populated screen-power circuit, rather than only the
Revision K routing changes. It does not repeat or adopt the old Claude review's
unqualified heatsink, fuse-clearing, or safe-operating-area claims.

## Verdict and scope

No further incorrect pin assignment, reversed component, missing required
circuit connection, or component-rating violation was found **within the
documented conditional operating envelope**. The circuit is coherent: one
GPIO-controlled, reverse-blocking-when-off 5 V switch feeds all four screen
power branches, while two host-powered signal relays disconnect USB data.

This is not an unconditional production qualification. In particular, the
present calculations assume **5.0–5.25 V at J1 under load** and do not establish
operation over an ordinary 5 V ±5% supply range. That narrower range is already
explicit in the board README. The retained fixed buck, cables, USB link,
installed temperature, startup transient, and deployed shutdown behavior have
not been qualified as an assembled system. These are existing acceptance
boundaries, not newly imposed owner tests before buying bare prototype PCBs.

Critical findings: **0**. Important findings: **0**. Suggestions: **0**.
The numerical supply boundary and corrected aggregate budget below must remain
visible in any broader readiness conclusion.

Reviewed source: `switch_circuit.py`, `hand/bom.csv`, `external_bom.csv`,
`hand/components.json`, the native schematic hierarchy and library symbols,
native PCB pad assignments, custom component footprints, README, and the
GPIO owner/Weston service interface. Copper geometry and manufacturing export
sign-off belong to the separate final routing/fabrication reviews.

The initial circuit review used native PCB snapshot
`037d462c64196cca1d697975325be9b979a5360783949ed89c62c441ebef3032`.
The first completed Revision K build was checked at native PCB SHA-256
`0a48bfad57602856e0b1558a10f9856250cba5859e3e14df5796b197419b1813`.
The final build, including the two remaining approach tapers, was independently
rechecked at native PCB SHA-256
**`d35484d551cf8f526f62c4356accbff0492c28999beb0e8830801c39f00c83da`**.
The following final-snapshot evidence supersedes both earlier routing snapshots.

## Independent native-circuit evidence

KiCad exported the actual native schematic as XML. An independent XML reader
compared it with the actual PCB pads, generated component records, and BOM;
it did not call the repository's circuit-contract checker.

- All **41 references** (37 populated components and four holes), **96
  connected pins**, and **27 electrical nets** agreed.
- Native schematic MPN fields agreed with every BOM row.
- Native symbol functions agree with the physical transistor/diode pin maps
  below; no inferred top/bottom mirror was used to establish pin numbers.
- A separate contact graph, driven by the manufacturer relay diagram, checked
  all four two-coil combinations and all **16 upstream USB paths**. Enabled
  channels reach only their matching downstream data terminal; disabled
  channels reach no downstream terminal. No polarity swap or channel crossover
  was found.

This establishes circuit correspondence; clean ERC/DRC alone would not establish
that the circuit is sensible, as the withdrawn relay design demonstrated.

### Final Revision K routing recheck

A fresh XML export of the completed Revision K native schematic again agreed
with the final native PCB, generated records and BOM: 41 references, 96
connected pins and 27 nets. Values, exact MPNs, footprint names and all pad nets
agreed. The independent four-state/16-path relay graph passed again. The circuit
generator, component records and populated BOM are unchanged from the audited
baseline; no supply/control topology or part substitution was introduced.

All eight `POWER_TAPER` zones are filled, single-outline regions on the same
nets and layers as their underlying tracks: front copper has one `AUX_5V`,
two `COMMON_SOURCE` and four `SWITCHED_5V` tapers; bottom copper has one
`SWITCHED_5V` taper. Each uses priority 20 and 0.05 mm minimum fill thickness.

The source approaches widen from 1.9 to 3 mm over 1.0/1.5 mm; the four branch
joins widen from 3 to 4.5 mm over 2.75/3.5 mm. The final two transitions widen
from 1.9 to 3 mm: AUX front copper from (45.5, 11) to (47, 11), and switched
bottom copper from (31, 10.3) to (31, 12). Their filled native polygons agree
with those endpoints and widths. The source bridge uses 3 mm tracks through
both diagonal bends and its middle span. No taper carries a different supply
or relies on a floating copper island. The tapers add copper to already
continuous routed paths. The generator's revised explicit net-to-layer
allowlist permits these eight regions while still requiring both GND pours.

An independent KiCad geometric-connectivity pass removed **every zone, every
via and every track below the relevant threshold** from disposable in-memory
board copies, then checked these 12 paths:

| Minimum retained track width | Physically connected paths |
| --- | --- |
| 1.9 mm | J1.1→Q3.2; Q3.3→Q4.3; Q4.2→each of F101.1/F102.1/F201.1/F202.1 |
| 1.5 mm | J1.1→C2.1 |
| 0.8 mm | J1.1→C1.1; F102.2→J102.1; F202.2→J202.1 |
| 2.0 mm | F101.2→J103.1; F201.2→J203.1 |

All passed without taper or ground zones, so a polygon cannot conceal a
broken/narrow routed connection in this result. A second disposable-board
check removed F101's input pad, all zones, all tracks below 1.9 mm and all vias
except the shared-power vias with at least 0.45 mm drills. Q4.2 still reached
F201.1 through the dedicated parallel transition. This proves the bypass does
not depend on the fuse barrel. These are geometric checks, not an IPC-2152
thermal qualification of traces or plated barrels.

Fresh native DRC with every severity, all track errors and refilled zones
returned **zero violations and zero unconnected items**. The native file hash
remained the exact Revision K value above. No circuit or generator-architecture
regression was found. Placement/models and the final fabrication export have
their own review evidence; this recheck does not replace them.

## Exact component and connection review

| Parts / exact BOM selection | Datasheet and connection finding |
| --- | --- |
| Q3, Q4: Vishay **SUP70101EL-GE3** | Datasheet page 1 front/top package view gives G1/D2/S3; tab is drain. Q3 drain goes to AUX, Q4 drain to the switched rail, sources join, and gates join. Both body diodes point from their respective drain toward the common-source node. Off-state opposition is correct; neither diode alone makes an AUX-to-screen or screen-to-AUX path. See the [Vishay datasheet, pp. 1–2 and 7](https://www.vishay.com/docs/77632/sup70101el.pdf). |
| Q1: onsemi **2N3904BU** | E1 is ground, B2 receives GPIO through R1, C3 is the common control sink. The exact bulk part is listed in the ordering table. E/B/C matches the package drawing and native footprint. [onsemi, pp. 1–2 and ordering table](https://www.onsemi.com/download/data-sheet/pdf/2n3904-d.pdf). |
| Q2: onsemi **2N3906BU** | E1 is AUX, B2 is pulled up to AUX by R6 and pulled down through R5/D1/Q1, C3 drives DATA_ENABLE. Native E/B/C mapping matches the marked-face package view. Its job is to lift relay-driver gates above the Pi's 3.3 V. [onsemi, printed pp. 1–3](https://www.onsemi.com/download/data-sheet/pdf/2n3906-d.pdf). |
| Q101, Q201: onsemi **2N7000**, exact MPN | TO-92 S1/G2/D3 matches ground/DATA_ENABLE/coil-low. These are not arbitrary 2N7000-family substitutions: the cited exact device specifies 5.3 Ω maximum at 4.5 V gate drive and 75 mA at 25 °C. The two gates consume negligible DC current. [onsemi NDS7002A/D, pp. 1–3 and 7](https://www.onsemi.com/download/data-sheet/pdf/nds7002a-d.pdf). |
| K101, K201: TE/Axicom **1-1462037-3 / IM02TS** | Manufacturer top-view drawing: coil 1+/8−, commons 3/6, NC 2/7, NO 4/5. Host D−/D+ use 3/6; screen D−/D+ use 4/5; 2/7 are separately unconnected. The 5.08 mm row spacing and 3.2/2.2/2.2 mm lead sequence match the rotated footprint. Selected coil is non-latching, 4.5 V, 145 Ω ±10%. [Manufacturer 108-98001 Rev. K, pp. 5–6](https://www.farnell.com/datasheets/477186.pdf). |
| D1: Vishay **1N4148-TAP** | Cathode/pad 1 is CONTROL_SINK; anode/pad 2 is BUFFER_SINK. This permits Q1 to pull down Q2's base while blocking an output-precharged gate node from leaking into the dead AUX/base circuit. About sub-mA forward current and roughly 5 V reverse stress are comfortably below its ratings. Cathode band matches the footprint. [Vishay, pp. 1–2](https://www.vishay.com/docs/81857/1n4148.pdf). |
| D101, D201: Vishay **1N4007-E3/54** | Cathode/pad 1 is host VBUS; anode/pad 2 is coil-low. Correct flyback polarity. About 34 mA coil current is small relative to the rectifier rating; no fast repetitive switching is required. Coil current recirculates locally when the driver opens. [Vishay, pp. 1–2](https://www.vishay.com/docs/88503/1n4001.pdf). |
| R1–R7: Yageo **MFR-25FBF52** with the BOM's resistance suffixes | Exact coding is 0.25 W, 1%, bulk, 100 ppm/°C. Values are 1 kΩ, 100 kΩ, 4.7 kΩ, 330 kΩ, 5.6 kΩ, 100 kΩ, 100 kΩ. Even applying the full relevant rail to each resistance gives less than 12 mW in R1 and 6 mW in R3; others are lower. Ratings and axial dimensions are suitable. [Yageo MFR, pp. 2–3](https://yageogroup.com/content/datasheet/asset/file/YAGEO-MFR_DATASHEET). |
| R8: Vishay **PR01000101000FA100** | The code specifies 100 Ω, 1%, 1 W; it is not a 10 Ω part. Connected from switched power to ground. Worst stated rail/tolerance power is 5.25²/99 = **0.278 W**, below its 1 W/70 °C rating. [Vishay PR01, pp. 1–3](https://www.vishay.com/docs/28729/pr010203.pdf). |
| C1, C101, C201: WIMA **MKS2C031001A00KSSD** | 100 nF, ±10%, 63 V, nonpolar, 5 mm lead pitch and 7.2 × 2.5 mm body match the BOM/footprint. C1 bypasses AUX; each other capacitor bypasses only its own host supply. [WIMA MKS 2, printed pp. 34–35 and part-number table](https://www.wima.de/wp-content/uploads/media/e_WIMA_MKS_2.pdf). |
| C2: Panasonic **EEU-FR1A221** | 220 µF/10 V, positive to AUX and negative to GND; 6.3 mm body/2.5 mm pitch match. This capacitor is upstream of the MOSFETs. [Panasonic part data](https://industrial.panasonic.com/ww/products/pt/aluminum-cap-lead/models/EEUFR1A221). |
| C102, C202: Panasonic **EEU-FR1A151** | 150 µF/10 V, positive to each fused touch rail, negative to GND; 5 mm body/2 mm pitch match. These capacitors draw their charging current from AUX, not Pi USB. [Panasonic part data](https://industrial.panasonic.com/ww/products/pt/aluminum-cap-lead/models/EEUFR1A151). |
| F101/F201: **0251004.MXL**; F102/F202: **0251.750MXL** | 4 A main and 750 mA touch fuses are after the shared switch. Nominal cold resistances are 20.4 mΩ / 175 mΩ and nominal melting I²t values 2.45 / 0.153 A²s. The manufacturer's 25% continuous derating supports 3 A main and conservatively 0.5 A touch at reference temperature, with further ambient derating. Hand soldering is appropriate. [Littelfuse 251, pp. 1–3](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688). |
| J1/J103/J203: JST **B2P-VH(LF)(SN)** | Correct 3.96 mm family and VHR-2N / SVH-41T-P1.1 mates. The 10 A connector figure requires the manufacturer's 16 AWG standard-header arrangement; it is not a universal wire rating. [JST VH, pp. 1–3](https://www.jst-mfg.com/product/pdf/eng/eVH.pdf). |
| J2 and four USB headers: JST **B2B-XH-A(LF)(SN)** / **B4B-XH-A(LF)(SN)** | Correct 2.50 mm XH pitch and mating families. J2 is GPIO/GND. All four USB headers are VBUS, D−, D+, GND, in numbered-pad order; host VBUS and downstream VBUS remain separate nets. Signal-current budgets are below the family's 3 A/22 AWG rating, but marketplace housing quality is not certified by the PCB. [JST XH, pp. 1–4](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf). |

Native power-device holes are 1.4 mm; relay holes are 0.9 mm. TO-92 parts
require forming the outer leads for the 2.54 mm board pitch. The TO-220
assembly orientation must follow the footprint, not the global left/right
appearance of the rendered board: Q3 and Q4 have opposite rotations. The
two metal tabs carry **different live drains** and cannot share an uninsulated
heatsink or touch the enclosure.

## Supply sequencing and failure paths

| State | Expected circuit behavior / limitation |
| --- | --- |
| AUX on; Pi unpowered, GPIO low, or control disconnected | R2 keeps Q1 off, R4 returns both power gates to common source, R6 keeps Q2 off, and R7 lowers relay-driver gates. Screen supply and data turn off. The assumed leakage allowance is adequate at the documented model condition; it is not an all-temperature measured leakage guarantee. |
| AUX and Pi on; GPIO high; both USB hosts powered | Q1 turns on power and Q2; both relay coils energize from their respective hosts. All four output feeds come from AUX. |
| One host USB plug removed or its VBUS lost | Its relay releases and disconnects both data conductors; the other channel is independent. Main screen power stays on while GPIO is high. This is appropriate host-data loss behavior, not automatic HDMI-loss detection. |
| AUX absent; Pi/GPIO high | Q2 cannot provide a sustained positive DATA_ENABLE supply, so relay drivers turn off. No host VBUS path feeds AUX or screens. |
| AUX absent; output precharged; GPIO low | Q4's body diode can raise the common source, but R4 follows that node and Q3 blocks reverse flow. D1 blocks the otherwise possible base-network pull-down. No low-impedance route to Pi GPIO exists. |
| Output externally powered while GPIO high | Enabled MOSFET channels conduct bidirectionally. The design deliberately does not provide reverse blocking when on; an independent live screen source must not be connected in parallel. |
| GPIO high→low | Relays open and both output supplies decay. R8 discharges the shared switched node through intact fuses. Screen capacitance/backfeed determines darkness time; the PCB does not establish the five-second software wait. |
| Software halt with Pi input still present | Requires the GPIO owner and stop hooks to drive low before HDMI stops. The PCB cannot infer Linux halt. Existing service source implements this intent; its installation and actual system behavior remain device acceptance items. |
| Main or touch branch fault | Its fuse can interrupt sufficient fault current. Internally joined screen power ports can also feed the fault through the other branch. A fuse is not a precise current limiter; a current-limited buck may not provide enough overcurrent for rapid clearing. |
| Input harness or shared-rail fault | The four branch fuses do not protect this upstream wiring. Use the protected input harness specified in the external BOM. Reverse polarity/overvoltage and semiconductor-short faults are not protected by this switch topology. |

The GPIO circuit draws approximately 2.4–2.7 mA at 3.3 V. With the checker's
conservative 2.4 V GPIO-high and 0.95 V base-junction assumptions, base drive is
at least **1.426 mA**, while the combined worst initial sink demand is below
**2.08 mA**. Q1 has ample forced-gain margin. Q2 supplies about 53 µA DC plus
small gate-charging pulses, with approximately 0.49 mA minimum calculated base
drive. RP1 has selectable 2/4/8/12 mA drive; the normal 4 mA setting is adequate
for this load. [Raspberry Pi RP1 peripheral documentation, GPIO pads](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf).

The relay's diode-clamped release is specified up to 5 ms at its stated test
condition, not instantaneous. Initial cold coil voltage is about
`4.75 × 130.5 / (130.5 + 5.3) = 4.565 V`, above the 3.38 V pickup value.
Hot pickup remains distinct from the continuous-coil voltage limit: resistance
and pickup demand rise with temperature, while the driver's on-resistance also
rises. The existing README correctly does not promise the full −40…85 °C
relay range for the assembled circuit. [TE data, pp. 23–24](https://www.farnell.com/datasheets/477186.pdf).

## Voltage, heat, startup, and total-power boundaries

The MOSFET's 15 mΩ maximum resistance is specified at **−4.5 V** gate drive,
not at its threshold. Using the existing conservative 0.2 V Q1 saturation
drop, 1% resistor extremes and estimated hot resistance `15 mΩ × 1.7`:

`|Vgs| = (V_J1 − I × 0.0255 − 0.2) × 326700 / (326700 + 4747)`.

| Shared switch current | Estimated lower gate drive with 4.75 V at J1 | J1 voltage needed for this model to reach 4.5 V gate drive |
| --- | --- | --- |
| 2.25 A | 4.428 V | 4.823 V |
| 3.25 A | 4.403 V | 4.848 V |
| 4.25 A | 4.378 V | 4.874 V |
| 6.00 A | 4.334 V | 4.918 V |

Below that gate condition, typical curves suggest conduction continues, but
the stated worst-case resistance calculation no longer establishes the loss.
**Do not turn this into a claim that the circuit fails at 4.75 V, or that it
is guaranteed there.** A nominal 5 V buck and a 5.0 V minimum at J1 are different
requirements. Input connector/wire drop must be inside the system budget.
VH positive and return contacts alone allow 0.12 V drop at 6 A using the initial
10 mΩ/contact limit, and 0.24 V at the post-test 20 mΩ/contact limit.

At adequate gate drive, the existing thermal bracket—60 °C local ambient,
75 °C/W effective thermal resistance per upright transistor, and resistance
temperature coefficient approximated from a typical curve—gives roughly
**0.20–0.36 W per MOSFET and 75–87 °C junction** for 3.25–4.25 A. At 6 A it
gives approximately **0.81 W and 121 °C** per MOSFET. These are estimates,
not layout-qualified temperatures. They support leaving out a heatsink for the
expected screen load, not promising heatsink-free 6 A operation in any enclosure.
The ring uses another power path. [Vishay electrical/thermal data, pp. 1–6](https://www.vishay.com/docs/77632/sup70101el.pdf).

The board adds 300 µF downstream of the switch. At 5.25 V this stores about
4.13 mJ; the screens add unknown capacitance and active startup loads. R3 slows
gate charging but is not a specified current-limited soft-start controller.
Capacitance energy cannot simply be divided equally between the two MOSFETs,
and a cool-running steady-state estimate cannot prove startup safe operating
area. Existing owner observations constrain sustained display power, but the
charger readout does not resolve short inrush peaks. No new destructive or
oscilloscope procedure is required of the owner to finish the CAD review.

The **6 A** shared switch allowance includes R8 and all four output branches.
At 5 V, external screens/touch together must therefore stay within about
5.95 A. Independent 3 A main and 0.5 A touch branch ceilings cannot be added
and called a supported 7 A shared load.

For the unchanged shared 10 A AUX supply, the recorded normal-pill/full-white
ring allowance totals **9.358 A**, when the 50 mA bleeder is counted once inside
the screen board's 6 A total. The old 9.408 A figure double-counted it, which
was conservative. All 80 pill LEDs plus the 40 ring LEDs at full white would
instead total approximately **13.66 A** with that screen allowance and logic
overheads. Full-white permission for the ring is not permission for all pills
to run white simultaneously at that worst-case screen load. This arithmetic
checks the existing system budget; it does not qualify the buck's enclosed
continuous rating or transient response.

## Wiring and acceptance conclusions

The two-wire control lead remains console J25→screen J2, numbered pins 1:1.
Both Pi touch leads must pass through the board; bypassing it recreates the
observed alternate screen-power path. Main feeds use the VH power connectors
and suitable power wire. The 28 AWG XH leads are touch-data/limited-touch-power
connections and should not be repurposed as 3 A screen power leads.

The cable samples still determine contact mapping, USB-C legacy-source Rp,
shield termination and actual USB performance. Four XH terminals cannot carry
a separate CC/shield conductor. The selected USB-C lead must implement its
source configuration inside the plug; its undocumented construction is not
established by a schematic pin map. UPERFECT includes a 480 Mbps hub, so a
successful 12 Mbps-controller-only argument would be insufficient. The relay's
RF insertion-loss number does not constitute USB compliance evidence.

No speculative electronic module or surface-mount redesign is warranted by
this circuit audit. The necessary next evidence is the final routed-board
parity/fabrication review followed by the already-defined first-assembly checks;
the circuit report must not be presented as assembled-system qualification.
