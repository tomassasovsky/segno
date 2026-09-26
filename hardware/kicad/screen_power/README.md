<!-- cspell:words preorder Axicom Mbps energization Digi typec mrico kilohm -->
<!-- cspell:words overvoltage derate autosuspend overmolds fanouts onsemi Nexperia Omron derating autoroutes pulldowns -->
<!-- cspell:words SUP SUM Rds backfeed Micro pulldown Vgs Littelfuse Lumberg MMBT DMODEL stackup microstrip heatsinks eleUniverse ATOF PXCN FHAC overcurrent -->
# Screen power and touch switch

Revision L retains the **two-layer, 68 × 76 mm** hand-soldered board, **3 mm
rounded corners**, purple solder mask and white silkscreen. The screen supply
and both USB touch paths switch off together under GPIO17 control. The ring
and console retain their separate power branch.

A small through-hole negative gate supply now turns the existing power
MOSFETs on with substantial voltage margin after normal fuse and harness
losses. It adds no external module, Pi ribbon or power rail. The two relay
drivers also change to parts specified for lower gate voltage. There is no
added active startup-current limiter: the
[startup assessment](../../../docs/reviews/screen-power-rev-l-1072/startup.md)
finds useful pulse margin in the existing power devices.

U1 and U2 share both pin rows and a body centerline. Their final alignment
retains the stock courtyards and nearby capacitor positions; see the
[alignment verification](../../../docs/reviews/screen-u2-alignment-1072/verification.md).

The board has **44 populated through-hole components plus four M3 holes**.
Both outer copper layers have filled GND pours. All eight cable headers
retain their positions and matching orientation: vertical pin rows, pin 1
at the bottom and retaining wall on the left, viewed from the component side.
Cables enter perpendicular to the board. Mounting centers remain (4, 4),
(64, 4), (4, 72) and (64, 72) mm. The 3.5 mm unplated holes have 4.25 mm
copper keepouts on both faces for M3 heads/washers up to 7 mm diameter.

Use only the archive identified by the
[current three-board manufacturing record](../../../docs/reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
Older screen archives are superseded; Revision I remains withdrawn because
its relay commons were wired incorrectly. The corrected common contacts 3/6 and
normally open contacts 4/5 are retained and independently checked.
No pre-PCB prototype build or additional owner measurements are prerequisites
for this revision. The design assessment and fabrication checks are distinct
from operation of the assembled boards; USB compliance and shutdown timing
have not been physically qualified. Issue: [#1072](https://github.com/tomassasovsky/segno/issues/1072).

## Wiring

| Connector | Function |
| --- | --- |
| J1, JST VH 2-pin | Dedicated buck AUX input through the required inline fuse below. Pin 1 = +5 V; pin 2 = ground. Use the existing nominal **5 V** buck. The new gate driver is assessed at **4.5–5.25 V at J1**, allowing supply-path losses; that lower corner is not a claim that either screen operates down to 4.5 V. Do not assume the buck is adjustable. |
| J2, JST XH 2-pin | Console J25 control. Pin 1 = BCM GPIO17; pin 2 = ground. One two-wire cable, numbered pins connected 1:1. |
| J101 / J201, JST XH 4-pin | USB-A male to XH cable from each Pi USB 2.0 host port; channels 1 / 2. |
| J102 / J202, JST XH 4-pin | Direct XH-to-USB-C male cable to UPERFECT (channel 1), and XH-to-Micro-B male cable to APROTII (channel 2). |
| J103 / J203, JST VH 2-pin | Screen power outputs. Pin 1 = switched +5 V; pin 2 = ground. Feed the separate screen power leads; final cable termination remains to be selected. |

The existing Pi-to-console ribbon stays directly connected. Console J25 takes
GPIO17 from physical Pi pin 11. This board has no 40-pin header and takes no
screen power from Pi GPIO. GPIO high enables both channels; low, disconnected,
or an unpowered Pi defaults them off. The Pi, board, HDMI and screens share ground. The four-pin XH cables have
no separate shield terminal; their actual shield termination must be checked.

### What “off” means

With AUX still powered, a low or disconnected GPIO17 turns off the shared
screen supply and opens both USB data paths. The main power connectors and
USB-touch VBUS all come from that switched supply; Pi host VBUS does not
feed the screens. An electrically unpowered Pi therefore defaults the board
off even if the dedicated screen buck remains powered.

A software-halted Pi that still has input power must explicitly release or
lower GPIO17. The board follows this signal; it does not detect Linux shutdown
or missing HDMI. The appliance now includes a dedicated GPIO owner and Weston
start/stop hooks: enable before display probing, then drive low before stopping
HDMI. Its five-second discharge wait is provisional until measured on both
screens. These changes are locally tested, not deployed to the inspected Pi.
On 2026-09-22 the
owner confirmed that both actual displays go fully dark with their power and
touch USB disconnected and HDMI left connected, following the Pi-on test.
This closes the HDMI-only visual check for this setup; GPIO-controlled cutoff
and shutdown timing still need assembled-device validation.

### XH USB cable contract

The committed PCB footprint is
`Connector_JST:JST_XH_B4B-XH-A_1x04_P2.50mm_Vertical`, with
**B4B-XH-A(LF)(SN)** board headers and XHP-4 mating housings. It is a
2.50 mm pitch, shrouded friction-retained connector with 1.10 mm nominal finished PCB holes.
The seller labels its compatible-style housing “XH2.54”; the PCB follows the
[JST XH drawing](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf), not that
rounded marketplace name. Verify sample fit without forcing the plug.

All four headers use the following pin map. Read the numbered PCB pads and
bottom-side labels, not wire colors or a mirrored view of the cable housing.

| PCB pin | Signal | Input J101/J201 | Output J102/J202 |
| --- | --- | --- | --- |
| 1 | +5 V | Pi VBUS; relay coil only | Fused switched touch supply |
| 2 | D− | Host data | Screen data |
| 3 | D+ | Host data | Screen data |
| 4 | GND | Common ground | Common ground |

The owner selected these ready-made cable variants on 2026-09-22:

- 2 × [USB-A male to XH4](https://www.ebay.com/itm/287533571271?var=589439154168),
  selector `USB M to XH2.54 4P`, one-piece pack, 30 cm.
- 1 × [USB-C male to XH4](https://www.ebay.com/itm/287533571271?var=589439372198),
  selector `typec to XH2.54 4P`, one-piece pack, 25 cm, for J102.
- 1 × [Micro-USB male to XH4](https://www.ebay.com/itm/287533571271?var=589439372190),
  selector `mrico to XH2.54 4P`, one-piece pack, 30 cm, for J202.

These replace the touch cables. The two separate main-power leads remain:
one USB-C lead to UPERFECT and one Micro-USB lead to APROTII, connected to
J103/J203 via the larger two-pin VH harness. Do not buy two extra XH data
cables for the main-power paths. The owner reports 28 AWG conductors in the
selected USB cables. At 30 cm, typical 0.213 ohm/m conductor resistance gives
about 0.128 ohm round-trip: 64 mV / 32 mW at the touch-path design budget of
500 mA, versus 0.383 V / 1.15 W at a 3 A main-power load, excluding connectors.
These are estimates, not measured cable ratings; source:
[Alpha Wire conductor table](https://www.belden.com/-/media/Project/AlphaWire/AlphaWire/2023-Master-Catalog/2023-MasterCat-English-20230609.pdf?rev=08a9584660404c8dad92412e1b961875).
The host lead's VBUS feeds about 34 mA of relay load. Screen touch current must
be measured with both screen connectors attached; a screen may join the
supplies internally, and the 750 mA fuse is not an active 500 mA limiter.

Before connecting equipment, measure each cable's pin-to-contact continuity
and check for shorts. Re-pin a housing to the documented map if necessary.
The seller has not documented the USB-C source-side CC resistor, shield
termination, controlled-impedance pair or 480 Mbps qualification. Check that
the USB-C plug has the proper legacy-source configuration (56 kilohm Rp to
VBUS); test both plug orientations. A sink-configured or charge-only cable
is unsuitable. Four XH contacts do not carry a separate CC signal, so this
configuration belongs inside the cable's USB-C plug. USB speed, shield behavior,
voltage drop and cable temperature remain prototype acceptance checks.

### Separate main-power harness

The new output connectors provide ordinary 5 V. They do not implement USB PD
or USB-C current advertisement. Reuse the **existing working power connection**
to each screen; preserve any USB-C attachment/current-signaling parts in that
connection. Do not attach an arbitrary bare USB-C receptacle to the two pins.
Each main-power lead must be at most **30 cm**, with **20 AWG or larger
conductors for both +5 V and ground** and terminations rated for **3 A**. At
the PCB, use VHR-2N housings with SVH-41T-P1.1 contacts within their 20–16 AWG
crimp range. The existing screen-end termination must meet these conditions;
its wire gauge is not yet recorded. APROTII power pads may be used only
after checking polarity, cable rating, strain relief and the screen's pad layout.

Never connect a direct Pi-to-display touch cable around this board: that would
restore the observed alternate power path. Upstream USB VBUS only feeds its own
relay coil and bypass capacitor, and never connects to a screen supply.

### Required AUX branch protection

Fit one **Littelfuse 028707.5PXCN, 7.5 A / 32 VDC ATOF fuse**, in a
**FHAC0001ZXJ** covered inline holder. The
[holder datasheet](https://www.littelfuse.com/assetdocs/littelfuse-fuse-holder-ato-fhac-datasheet-rd1?assetguid=272e0b1a-a576-4173-8740-c1eb469efd79)
specifies **20 A and 16 AWG leads**. Wire **AUX positive split → fuse near the
buck → J1 pin 1**; connect ground directly to **J1 pin 2**. Use 16 AWG for
both conductors, insulate and strain-relieve splices, and identify both black
holder leads as positive. Console/ring power stays on its separate branch.

The [fuse's typical derating table](https://www.littelfuse.com/assetdocs/littelfuse-datasheet-287-atof?assetguid=43dcdce8-8ca2-426f-8998-7e566f048d40)
allows 6 A at 65 °C and 5 A at 85 °C; final terminals and wiring affect this.
Specified maximum opening times are 600 s at 10.125 A, 50 s at 12 A and 5 s
at 15 A. These do not establish clearing from a nominal 10 A source.

The retained [eleUniverse B0GGHN97TK buck](https://www.amazon.com/dp/B0GGHN97TK)
advertises overcurrent, short-circuit and thermal protection without thresholds
or response curves. The added fuse provides supplementary harness coverage
upstream of the board's four branch fuses. It is not an active current limiter
or a guarantee of MOSFET survival, startup coordination or isolation after a
shorted switch. The existing assembled qualification still applies.

## Circuit and limits

Q3/Q4 are common-source, opposed P-channel MOSFETs. R4 (22 kΩ) pulls their
gates to the joined sources when disabled, blocking either direction while
off. They conduct both ways when enabled. They do not provide active reverse
current, reverse polarity or overvoltage protection.

U1 (LMC7660IN) produces a small negative gate supply from AUX. U2 (TLP627M)
level-shifts Q1's on/off signal: its emitter connects to the negative supply
and its collector pulls POWER_GATE through R3 (4.7 kΩ). The optocoupler is
used for level shifting; the system still shares ground. GPIO never connects
to the negative rail. U1 pins 1, 6 and 7 stay unconnected; **do not ground LV**.
C3/C4 are nonpolar 10 µF capacitors. D2's cathode band faces GND and clamps
positive excursions of the negative rail during power transitions.

Q1 switches U2's AUX-powered LED and Q2's base network. The former D1 is
removed because U2 separates the gate network from this buffer. Q2 enables
the two TN0702 relay drivers. Each IM02TS coil uses its own Pi USB VBUS and
opens both data lines when released; host VBUS never feeds a screen.

- Shared screen planning load: **4.25 A**, including both main feeds, both
  touch feeds and the approximately 0.05 A bleeder. This is conservative
  budgeting from the available screen readings, not a measured simultaneous
  maximum or a current limit. The previous 6 A expansion allowance is retired.
- Each main branch retains its 4 A Littelfuse 251 fuse and **3 A lead ceiling**;
  each touch branch retains its 750 mA fuse and **500 mA lead ceiling**. These
  ceilings are not additive guarantees. Screens may internally join their
  main and touch inputs. Keep both specified main-power leads connected;
  the thin touch lead is not a replacement for either main supply lead.
- Fuses protect against sustained faults; they do not impose those current
  ceilings or guarantee MOSFET survival from an unspecified buck current limit.
- There is no controlled soft start. The documented SOA assessment covers
  bounded startup sensitivities without claiming an exact surge waveform,
  capacitance limit or screen-current ramp.
- R8 is a 100 Ω, 1 W bleeder: approximately 0.25 W at 5 V. Shutdown delay
  depends on actual screen energy storage; the software's five-second wait
  remains provisional until normal operation is checked on the assembly.
- Each host relay coil draws about 34 mA. At 4.75 V host VBUS, minimum coil
  resistance and an explicit doubled-hot TN0702 resistance estimate,
  calculated coil voltage is **4.575 V**, above TE's **3.38 V initial pickup
  limit at 23°C**. That comparison does not establish a hot pickup guarantee.
  The maximum 5.25 V host supply is 1.167 times the 4.5 V coil rating, within
  TE's negligible-contact-load continuous coil curve through 85°C ambient.
- Q3/Q4 have electrically live, different drain tabs. Keep them clear of one
  another, metal mounting hardware and the enclosure. No shared uninsulated
  heatsink is permitted. The normal screen-load estimates need no heatsinks.

The [gate-drive assessment](../../../docs/reviews/screen-power-rev-l-1072/gate-drive.md)
records exact pin mappings, leakage budgets, sequencing and source limits.

## Placement and routing

USB inputs sit on the left edge and touch outputs on the right, with both
rows of vertical XH plugs accessible from above. The two
relay channels follow this signal flow. Main power and GPIO control occupy the top section. The power transistors
feed a straight front-side trunk, with each output fuse beside its branch. Connector courtyards and M3
holes are checked, but cable overmolds, latch access, screwdriver access and
vertical transistor clearance still need an enclosure fit check.

The nominal 1.6 mm, two-layer stack uses 35 µm outer copper and a 1.53 mm
FR-4 core, with nominal relative permittivity 4.4. USB pairs use **B.Cu**,
**0.85 mm width / 0.16 mm gap**, without data vias. KiCad 10's coupled-microstrip
calculator estimates **89.64 Ω differential** at 1 GHz for this nominal geometry.
This calculation omits solder mask and finite adjacent copper. JLCPCB lists controlled-impedance service for four or more layers; this
two-layer board does not order that service. The Gerber job omits the
`ImpedanceControlled` field; it makes no impedance-control declaration.
The estimate is a design target, not a promised
manufactured impedance or USB compliance result. Ordinary thickness and trace
tolerances, and the published two-layer material value of 4.5, still require
actual-link qualification. See [JLCPCB capabilities](https://jlcpcb.com/capabilities/pcb-capabilities). Connector and relay pad
fanouts necessarily separate the traces and remain local discontinuities.

Both conductors now use mirrored rounded fanouts. The coupled sections extend
slightly toward the terminals so rounding shortens, rather than lengthens,
the uncoupled ends. Width, minimum pair gap, length matching and the actual
filled ground beneath the bends are checked on the native board.

Filled F.Cu ground extends beneath the pairs and their fanouts. Routing
keepouts protect that return path, and the B.Cu pour stays back from the
coupled sections. Ground stitching links the outer pours. Validation samples
the actual front-side fill beneath the center and both edges of every USB
track at 0.1 mm intervals, excluding only 1.35 mm around its through-hole
terminals. Native DRC separately verifies ground connectivity.

The shared rail runs along the right edge at 4.5 mm width. The Q3 pin 3 to
Q4 pin 3 bridge and the Q4 pin 2 to F101 input feed each use a uniform
2.5 mm width with rounded bends, including their pin approaches. Neither
connection has a neck or taper. The front fuse branches remain 3 mm, main
outputs 2 mm and touch-power connections 0.8 mm. The AUX input from J1 to
Q3 pin 2 uses a uniform 2.0 mm front-layer route with rounded bends. This
retains 0.29 mm between its track cap and the adjacent 2.5 mm source route;
making both traces 2.5 mm would leave only 0.04 mm at the 2.54 mm pin pitch.
The [uniform-width assessment](../../../docs/reviews/screen-power-rev-l-1072/uniform-power-width.md)
records current capacity, copper loss and pad clearance for the three revised
runs at the 4.25 A screen planning load.

A filled bus outline gives the four fuse branches rounded joins and corners,
with 1 mm to the lower mounting keepout. Small AUX branch fillets round the
capacitor junctions; they do not carry a required power path on their own.
Validation removes every zone before proving the minimum
power-path widths, so a filled overlay cannot hide a missing or thin trace.
Both outer GND pours remain filled on the delivered board. The remaining
signal routes also use rounded bends. A native KiCad finishing pass preserves
pad/via contacts, branch connections, fixed power copper and track keepouts;
USB geometry stays under its paired route generator.

The 1.5 mm C2 feed and three dedicated shared-power stitching vias are retained.
C1 sits clear of the full mated VH housing, with a deliberate 0.8 mm
local supply route. The revised capacitor models use the actual BOM body
sizes; the maximum envelopes were checked separately. The gate-supply components occupy the rearranged control area. USB copper retains
paired bottom-layer routing, no data vias and a checked front-side GND return.
The [three-board audit](../../../docs/reviews/pcb-finish-all-three-1072/audit.md)
contains the current CAD and export evidence. C4 is aligned with U1 pin 5;
connector positions and the rest of the component placement are retained.

These choices follow [TI's USB layout guidance](https://www.ti.com/lit/an/slla414/slla414.pdf)
(short pairs, continuous return planes, through-hole connector signals on the
bottom) and [Sierra Circuits' placement guidance](https://www.protoexpress.com/blog/component-placement-guidelines-pcb-design-assembly/)
(connector anchors, functional grouping and signal flow).

## Sources and assembly

- [Vishay SUP70101EL through-hole MOSFET](https://www.vishay.com/docs/77632/sup70101el.pdf).
- Relay drivers: **Microchip TN0702N3-G**, TO-92 S1/G2/D3;
  [DS20005941A](https://www.microchip.com/content/dam/mchp/documents/APID/ProductDocuments/DataSheets/TN0702-N-Channel-Enhancement-Mode-Vertical-DMOS-FET-Data-Sheet-20005941A.pdf)
  specifies 2.5 Ω maximum at 3 V gate drive (25°C). Do not substitute the
  former 2N7000 without rechecking its lower-supply drive margin.
- [TE/Axicom IM02TS, part 1-1462037-3](https://www.te.com/en/product-1-1462037-3.html):
  standard non-latching 4.5 V through-hole relay. TE data sheet 108-98001 gives
  the coil limits and the non-latching terminal assignment in top view.
  Coil 1+/8−; commons **3/6**; normally open **4/5**; unused normally closed
  **2/7**. Revision I incorrectly used the normally closed terminals as commons.
  The project footprint derives from KiCad IMSeries with drills enlarged from 0.70 to
  **0.90 mm**; allowing JLCPCB's −0.08 mm finished-hole tolerance leaves
  0.82 mm, above TE's 0.75 mm minimum.
- [Littelfuse 251 fuse dimensions, derating and solder limits](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688).
  Follow the axial fuses’ 350 ± 5 °C / 5 s soldering limit; they are not reflow rated.
- [JST VH harness](https://www.jst.com/wp-content/uploads/2021/08/eVH.pdf)
  and [JST XH control harness](https://www.jst.com/wp-content/uploads/2021/01/eXH.pdf).

`hand/bom.csv` lists every populated component. `external_bom.csv`
lists the required input fuse and holder, harness housings, contacts, existing
cables and mounting hardware.
All 44 populated components have bundled STEP models; the four bare mounting
holes have no separate solid body. Custom models are simplified dimensioned
assembly models, not vendor CAD. See [model sources and limitations](models/README.md).
The exported `native/` folder keeps model paths portable; open its hand project
in KiCad. Use `top.png`, `perspective.png`, and `assembly.pdf` together to inspect
components and labels; `F-copper.svg` and `B-copper.svg` show the actual routing.

See [the complete component cost estimate](COSTS.md) for all 44 populated
parts, dated supplier prices and external wiring allowances.

## Measured USB topology and screen loads

Read from the running appliance on 2026-09-22, with both screen touch cables
connected and both devices identified as touchscreens by udev:

| Screen path | USB device | Negotiated speed |
| --- | --- | --- |
| UPERFECT, mapped to HDMI-A-1 | SiS HID Touch Controller, `0457:0819` | 12 Mbps behind a `1a40:0101` hub at **480 Mbps** |
| APROTII, mapped to HDMI-A-2 | WCH USB2IIC_CTP_CONTROL, `1a86:e5e3` | **12 Mbps**, directly attached |

The owner confirmed both touch leads plug directly into the Pi; the UPERFECT
hub is therefore in the screen/cable assembly. The switch must preserve its
480 Mbps upstream link. Reading only the touch controller speed would miss
this requirement. USB descriptor power figures are not measured screen loads.
No appliance settings were changed during this read-only inspection.

Available screen/charger readings imply about **2.2 A** from their current
fields, or **3.2 A** from the power fields at 5 V. Those fields are inconsistent
and do not establish a simultaneous measured bound. Allowing a conservative
extra 1 A for touch, if not already included, plus the 0.05 A bleeder gives
**3.25–4.25 A** through each MOSFET.

Using a deliberately conservative **1.7 × 15 mΩ per MOSFET**, 60°C ambient
and an assumed upright thermal resistance of 75°C/W gives **0.27–0.46 W per
device**, and estimated junction temperatures of **80–95°C** at 3.25–4.25 A.
These are engineering estimates, not measured temperatures. The datasheet's
40°C/W mounting arrangement differs from this upright assembly. The
[startup assessment](../../../docs/reviews/screen-power-rev-l-1072/startup.md)
keeps steady heating and pulsed SOA assumptions separate.

At 4.5 V J1, 4.25 A shared load, resistor tolerances and 1 V optocoupler drop,
calculated gate drive is **6.11 V**. Allowing a larger 2 V optocoupler drop
still gives **5.29 V**, above the 4.5 V condition for the 15 mΩ resistance
specification. The negative supply therefore closes the previous gate-drive
margin issue; it cannot compensate for voltage lost along the screen's actual
power path. Retain the specified short, thick main-power leads.

Normal pills, full-white 40-LED ring and console total about 3.358 A from
AUX. With the conservative 4.25 A screen budget, that is **7.608 A** against
the retained nominal 10 A supply. This does not make 10 A a guaranteed
instantaneous surge ceiling or permit every LED and load to be expanded.

## First assembly

No separate pre-PCB build is required. After soldering:

1. Check supply polarity, shorts, cable pin order and insulated live tabs.
   Re-pin the purchased XH leads if necessary before attaching the Pi/screens.
2. Connect both main-power leads and both touch paths through this board.
   Verify both screens start and touch works, including the large screen's
   480 Mbps hub path and both USB-C plug orientations.
3. Check GPIO high/on and low/off, then normal Pi shutdown with HDMI attached.
   Both panels must go dark before HDMI stops; adjust the existing software
   wait if the actual discharge time needs it.
4. Check the assembled fit and ordinary operation at maximum brightness.
   Keep the upright MOSFET tabs away from enclosure metal. The DIP lead rows
   may need forming to 7.62 mm; TO-92 outer leads use 2.54 mm pitch.

The owner already confirmed both screens go dark with HDMI alone attached.
That establishes the HDMI-only visual behavior, not operation through the new
PCB. Native DRC and calculations cannot establish USB compliance, exact
shutdown timing or the thermal behavior of the final closed enclosure.

## Rebuild and verification

Use KiCad 10 CLI and its bundled Python, SKiDL 2.3 with KiCad symbol paths,
and Freerouting 1.9.0. Set `SKIDL_PYTHON`, `KICAD_PYTHON`, `KICAD_CLI` and
`FREEROUTING_JAR` for the local installation, then run `build.sh`.
The generator writes the schematic/netlist, places from `layout.py`, manually
routes critical paths and autoroutes remaining low-current nets. `finish.py`
adds the stack and labels; `cleanup.py` removes verified redundant tails.

Run `check.py hand --self-test --output validation.json` with KiCad Python.
It checks native ERC/DRC, full schematic/netlist/PCB parity, actual USB and
console GPIO connectivity, circuit boundaries, assembly types and drive margins.
Revision J adds an independent relay contact-state check and fault injection
for the disconnected-common error; verification results are in the
[Revision L record](../../../docs/reviews/screen-power-rev-l-1072/verification.md).
Fault injection checks that missing, disabled or unresolved 3D models,
broken USB/control copper, missing USB ground reference, extra copper layers,
a host power bridge,
undersized relay lead holes, accidental hand-assembly SMD parts, undersized power copper, unsupported relay
drivers, wrong resistor tolerances and excessively weak pulldowns are rejected.
Revision L also rejects reversed optocoupler/clamp wiring, a grounded LV pin,
negative-rail connections to GPIO, inadequate optical drive, the obsolete
330 kΩ gate pull-up and polarized pump capacitors. `export.py` publishes
Gerbers, drills, BOMs, positions, drawings, models and renders only after a
fresh successful check and unchanged input hashes.
