<!-- cspell:words preorder Axicom Mbps energization Digi typec mrico kilohm -->
<!-- cspell:words overvoltage derate autosuspend overmolds fanouts onsemi Nexperia Omron derating autoroutes pulldowns -->
<!-- cspell:words SUP SUM Rds backfeed Micro pulldown Vgs Littelfuse Lumberg MMBT DMODEL stackup microstrip heatsinks -->
# Screen power and touch switch

Revision I is a **two-layer, 68 × 76 mm** hand-soldered board with **3 mm
rounded corners**, purple solder mask and white silkscreen. The extra 4 mm
of width gives the shared power rail its own strip beyond the USB connectors.
The control section stays at the upper left, power enters above the screen
outputs, and both USB channels run straight across the board.

All eight cable headers have vertical pin rows, pin 1 at the bottom and
their keyed retaining wall on the left when viewed from the component side.
The control and Pi USB headers share the left column; AUX input and screen
outputs share the right column. These are top-entry connectors: cables plug
in perpendicular to the board. Revision H rotates the four two-pin headers
to match the four USB headers and reroutes their connections.

The circuit uses one shared 5 V switch, two fused main-power outputs and two
switched USB touch paths. The current revision uses pin-compatible 4.5 V
IM02TS relays to improve pickup margin on the Pi's 5 V USB supply. The APROTII can stay lit from touch alone, so both
its main feed and touch supply must turn off.

**Revision I is ready for first fabrication; assembled operation is unverified.**
The September 24 [first-fabrication decision](../../../docs/reviews/pcb-completion-1072/first-fabrication.md)
supersedes the earlier blanket measurement hold. No additional owner measurements
are prerequisites for buying the bare PCBs. The pre-order audit corrected
lead-hole fit, metal-fastener clearance and a separate console ADC power-domain
fault. Earlier exports are superseded.
CAD validation does not establish thermal performance, USB compliance, screen
compatibility, enclosure fit, or shutdown timing. Issue: [#1072](https://github.com/tomassasovsky/segno/issues/1072).

The board has **37 populated through-hole components plus four M3 mounting
holes**, with no surface-mount parts or external electronic modules. Both
outer copper layers, `F.Cu` and `B.Cu`, have filled GND pours. There are no
inner copper layers. Select purple solder mask and white silkscreen when ordering.
The mounting holes are at (4, 4), (64, 4), (4, 72) and (64, 72) mm; the two
right-hand holes move with the wider edge. Revision I uses 3.5 mm unplated
holes and 4.25 mm copper/track/via keepouts on both faces, allowing M3 hardware
with a maximum 7 mm washer/head diameter. It reroutes the lower power branch
above this clearance. Older revision packages, including
the removed factory variant, are historical only.

## Wiring

| Connector | Function |
| --- | --- |
| J1, JST VH 2-pin | Dedicated buck AUX input. Pin 1 = +5 V; pin 2 = ground. The provisional electrical check assumes **5.0–5.25 V here under load**. The retained fixed 5 V buck has not been shown to meet that floor after wiring drop; verify this during assembled validation. Do not assume it is adjustable. |
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
The exact existing buck-to-screen connector arrangement remains to be confirmed
before specifying the final power harness. APROTII power pads may be used only
after checking polarity, cable rating, strain relief and the screen's pad layout.

Never connect a direct Pi-to-display touch cable around this board: that would
restore the observed alternate power path. Upstream USB VBUS only feeds its own
relay coil and bypass capacitor, and never connects to a screen supply.

## Circuit and limits

Q3/Q4 are common-source, back-to-back P-channel MOSFETs. Their gates pull up
to their joined sources through R4 (330 kΩ), blocking conduction in either
direction **while off**. They conduct both ways while enabled; this is not an
ideal-diode controller or an overvoltage/reverse-polarity protection circuit.
Q1 pulls the gates down through R3 (4.7 kΩ). D1 isolates this gate-control node
from Q2's base network when AUX is absent and a screen-side rail is powered.

Q2 drives the two touch-relay MOSFET gates. Each TE/Axicom IM02TS relay opens both
D+ and D− when disabled. Its coil uses its own Pi host VBUS, so loss of that host
supply releases that channel's contacts. This is not galvanic isolation. TE specifies 0.33 dB insertion loss at 900 MHz
for this part. That supports its selection for the prototype, but does not
establish differential USB performance. The 480 Mbps hub path needs
an eye/signal-integrity check and functional tests with the actual cables.

- Shared design load: up to **6 A combined**, provisional until thermal tests.
  The SUP70101EL pair dissipates up to 1.08 W at 6 A using the
  specified 25 °C maximum 15 mΩ per device at −4.5 V gate drive. Hot resistance
  and cable/copper losses increase the drop. Do not infer a rated 6 A assembly
  from the transistor's headline current rating.
- Each main branch uses a 4 A Littelfuse 251 fuse; design for 3 A continuous at
  the reference ambient and derate further with temperature. Each touch branch
  uses a 750 mA fuse for a nominal 500 mA load. These are overload fuses, not
  active current limiters. Check actual screen inrush against fuse I²t and
  upstream protection. A screen internally joining its two power ports may
  feed a fault through both branches; test that specific fault path.
- There is no controlled soft start. Measure turn-on inrush, buck droop,
  simultaneous screen startup and MOSFET heating before enclosure installation.
- R8 is a permanent 100 Ω, 1 W bleeder on the switched rail: about 0.25 W at
  5 V. Discharge time depends on the connected screens' capacitance and residual
  inputs. No fixed shutdown delay is established by the PCB design.
- Each host relay coil draws about 34 mA while enabled. At 4.75 V host VBUS,
  minimum coil resistance and maximum driver resistance, initial coil voltage
  is calculated as 4.565 V, above TE's 3.38 V initial pickup limit at 23 °C.
  That limit excludes pre-energization. Coil self-heating and ambient temperature
  raise pickup voltage: measure actual coil voltage and verify quick hot
  re-enabling at minimum USB voltage and maximum enclosure temperature.
  At the maximum 5.25 V host supply, the coil sees at most 1.167 times its
  rated voltage, within TE's standard 140 mW, negligible-contact-load
  continuous coil curve through 85 °C ambient. That is a coil-heating limit,
  not a guarantee of hot pickup. No full-temperature operating envelope is
  established by the initial pickup calculation. USB suspend compliance
  is not established; test appliance USB autosuspend and wake behavior.
- The power-transistor footprint uses 1.4 mm finished holes and at least
  0.25 mm annulus for the selected part's maximum rectangular leads.
- TO-220 tabs are electrically live drains. Prevent contact with each other,
  the enclosure and mounting hardware. Do not fit an uninsulated shared heatsink.
- Provide suitable protection upstream of J1 and appropriately rated wiring.
  The on-board fuses do not protect the shared input cable or the entire switch.

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
two-layer board does not order that service. The Gerber job accordingly sets
`ImpedanceControlled` to false. The estimate is a design target, not a promised
manufactured impedance or USB compliance result. Ordinary thickness and trace
tolerances, and the published two-layer material value of 4.5, still require
actual-link qualification. See [JLCPCB capabilities](https://jlcpcb.com/capabilities/pcb-capabilities). Connector and relay pad
fanouts necessarily separate the traces and remain local discontinuities.

Filled F.Cu ground extends beneath the pairs and their fanouts. Routing
keepouts protect that return path, and the B.Cu pour stays back from the
coupled sections. Ground stitching links the outer pours. Validation samples
the actual front-side fill beneath the center and both edges of every USB
track at 0.1 mm intervals, excluding only 1.35 mm around its through-hole
terminals. Native DRC separately verifies ground connectivity.

The shared rail runs along the right edge at 4.5 mm width. The MOSFET feed and
fuse branches use 3 mm copper, with short 1.5 mm device-pin necks, 2 mm main
outputs and 0.8 mm touch-power connections. Through-hole fuse pads transfer
power between faces without power vias. Copper current capacity and temperature
rise remain physical acceptance items.

These choices follow [TI's USB layout guidance](https://www.ti.com/lit/an/slla414/slla414.pdf)
(short pairs, continuous return planes, through-hole connector signals on the
bottom) and [Sierra Circuits' placement guidance](https://www.protoexpress.com/blog/component-placement-guidelines-pcb-design-assembly/)
(connector anchors, functional grouping and signal flow).

## Sources and assembly

- [Vishay SUP70101EL through-hole MOSFET](https://www.vishay.com/docs/77632/sup70101el.pdf).
- Relay drivers: **onsemi 2N7000**, exact bulk MPN, TO-92 S1/G2/D3;
  [NDS7002A/D data sheet](https://www.onsemi.com/download/data-sheet/pdf/nds7002a-d.pdf)
  specifies 5.3 Ω maximum at 4.5 V. Do not substitute 2N7000BU, whose guaranteed
  gate-drive conditions differ.
- [TE/Axicom IM02TS, part 1-1462037-3](https://www.te.com/en/product-1-1462037-3.html):
  standard non-latching 4.5 V through-hole relay. TE data sheet 108-98001 gives
  the coil limits on page 3 and top-view pinout on page 4. Coil 1+/8−;
  commons 2/7; normally open 4/5; unused normally closed 3/6. The project
  footprint derives from KiCad IMSeries with drills enlarged from 0.70 to
  **0.90 mm**; allowing JLCPCB's −0.08 mm finished-hole tolerance leaves
  0.82 mm, above TE's 0.75 mm minimum.
- [Littelfuse 251 fuse dimensions, derating and solder limits](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688).
  Follow the axial fuses’ 350 ± 5 °C / 5 s soldering limit; they are not reflow rated.
- [JST VH harness](https://www.jst.com/wp-content/uploads/2021/08/eVH.pdf)
  and [JST XH control harness](https://www.jst.com/wp-content/uploads/2021/01/eXH.pdf).

`hand/bom.csv` lists every populated component. `external_bom.csv`
lists harness housings, contacts, existing cables and mounting hardware.
All 37 populated components have bundled STEP models; the four bare mounting
holes have no separate solid body. Custom models are simplified dimensioned
assembly models, not vendor CAD. See [model sources and limitations](models/README.md).
The exported `native/` folder keeps model paths portable; open its hand project
in KiCad. Use `top.png`, `perspective.png`, and `assembly.pdf` together to inspect
components and labels; `F-copper.svg` and `B-copper.svg` show the actual routing.

See [the complete component cost estimate](COSTS.md) for all 37 populated
parts, the 22 September supplier snapshot and external wiring allowances.

## Measured USB topology and part cost

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

The former G6K-2P-RF relay was listed at
[US$25.10 each](https://www.digikey.com/en/products/detail/omron-electronics-inc-emc-div/G6K-2P-RF-DC5/5864630).
The selected IM02TS was listed at
[US$5.10 each, 2,000 in stock at DigiKey](https://www.digikey.com/en/products/detail/te-connectivity-potter-brumfield-relays/IM02TS/1633979)
on 2026-09-22: US$10.20 for both, about US$40.00 less per board. Shipping and
local taxes are excluded; availability must be checked when ordering.
The lower price does not remove the physical USB acceptance gate.

Q3 and Q4 are power MOSFETs, not the expensive relays. The
[SUP70101EL-GE3 was listed at US$4.70 each](https://www.digikey.com/en/products/detail/vishay-siliconix/SUP70101EL-GE3/7622840).
At 3 A combined, their calculated pair loss is 0.27 W; at 6 A it is 1.08 W,
or 0.54 W per part, using 15 mΩ each at 25 °C. Resistance rises as they heat.
These are dissipation calculations, not measured temperatures. The datasheet's
40 °C/W junction-to-ambient figure uses a specified board mounting condition;
it does not establish this enclosed assembly's temperature or heatsink need.
Start the prototype without heatsinks and measure Q3/Q4 at maximum screen
brightness in the warmed enclosure. At 3 A combined, the calculated loss is
0.135 W per device; at 6 A, 0.54 W per device at 25 °C, increasing with heat.
If cooling is required, keep the electrically live drain tabs isolated:
a shared metal heatsink must not join them and bypass the switch.

## Physical acceptance before release

1. Check polarity, continuity, short circuits, protective fuses and insulated
   live tabs; initially power from a current-limited bench supply.
2. Test GPIO high, low, floating and Pi unpowered. Power the output with AUX
   absent and GPIO low to check off-state reverse blocking and D1 isolation.
3. Measure voltage drop and temperature at each rated load, simultaneous
   startup, hot ambient and actual cable lengths. Record inrush and fuse behavior.
4. Verify both touch devices enumerate, operate and reconnect reliably through
   the relays; test USB unplug/replug, suspend, wake, reboot and brownout.
   Measure relay coil voltage and confirm hot re-enable at the lowest USB
   voltage and highest intended enclosure temperature.
5. Leave HDMI attached. Disable GPIO and measure both screen rails until the
   panels go fully dark; check residual HDMI power and the observed APROTII
   touch-only backfeed condition. Verify fault behavior if main/touch join.
6. Validate the implemented GPIO startup/shutdown service on the assembled
   system, allowing the **measured** discharge time before HDMI stops. The
   present five-second software wait is provisional; host tests do not prove
   that the blue no-signal frame is eliminated on the actual panels.

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
Fault injection checks that missing, disabled or unresolved 3D models,
broken USB/control copper, missing USB ground reference, extra copper layers,
a host power bridge,
undersized relay lead holes, accidental hand-assembly SMD parts, undersized power copper, unsupported relay
drivers, wrong resistor tolerances and excessively weak pulldowns are rejected. `export.py` publishes
Gerbers, drills, BOMs, positions, drawings, models and renders only after a
fresh successful check and unchanged input hashes.

## First assembly and acceptance

The bare PCB can be ordered under the first-fabrication decision above. The
following checks apply to its assembly and system acceptance:

1. **HDMI-only visual check passed (owner report, 2026-09-22).** With the Pi
   on, both displays go fully dark when power and touch USB are removed while
   HDMI remains connected. GPIO-controlled cutoff and discharge timing remain
   separate assembled-board checks; no residual current measurement is claimed.
2. On arrival, verify every purchased XH cable with continuity testing before
   applying power: mating fit, pin order, shorts and USB-C source configuration.
   Qualify the actual UPERFECT 480 Mbps hub path; a 12 Mbps touch controller
   behind that hub does not reduce the upstream requirement.
3. Establish loaded AUX and screen voltages, both-input current sharing,
   simultaneous startup current/droop, and warm relay restart. The existing
   fixed buck also supplies the console and LEDs. Typical-device simulations
   cannot establish its current-limit response or a safe fuse/current budget.
4. Print `fit-template-1to1.pdf` at 100%, with page fitting disabled. Confirm
   mounting centers are 60 mm apart horizontally and 68 mm vertically before
   using the print. Check the actual harness bend/fastener clearance in the
   enclosure. Form the outer TO-92 leads for the 2.54 mm PCB pitch without
   stressing the package. Revised nominal holes: XH 1.10 mm, VH 1.80 mm,
   relay 0.90 mm and TO-92 0.95 mm; do not replace them with library defaults.
5. Install the matching v3 console/ring firmware and appliance GPIO service
   on the assembled hardware, then validate the complete system. Source
   implementations and host tests do not prove operation on the actual boards.
   Cutting power before HDMI stops still needs measured discharge timing.

Some measurements can use the existing displays and reusable components
before PCBs are bought. Final USB, heating and assembly validation require
the actual assembly; neither simulation nor a breadboard proves its USB path.
The [publication record](../../../docs/reviews/hardware-publication-1072/verification.md)
identifies the current files, checks and retained design alternatives. CAD
checks establish fabrication geometry; they do not establish assembled behavior.
