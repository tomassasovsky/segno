<!-- cspell:words unreviewed -->
<!-- cspell:words IRLZ NPBF Schurter upsize -->
<!-- cspell:words fanout -->
<!-- cspell:words preorder Axicom Mbps energization Digi typec mrico kilohm -->
<!-- cspell:words overvoltage derate autosuspend overmolds fanouts onsemi Nexperia Omron derating autoroutes pulldowns -->
<!-- cspell:words SUP SUM Rds backfeed Micro pulldown Vgs Littelfuse Lumberg MMBT DMODEL stackup microstrip heatsinks eleUniverse ATOF PXCN FHAC overcurrent -->
# Screen power and touch switch

**Revision P** removes two obsolete ground-fill exclusions beside mounting
hole H1, restoring its smooth ground-copper contour. All tracks, pads,
placements and electrical connections remain unchanged. It retains each
USB cable's shield through a fifth XH contact,
so the complete cable disconnects at its plug. It retains Revision N's
through-hole power relay and removable main fuse. The four branch fuses
remain soldered to keep cost and size down.

The design retains the **two-layer, 68 × 76 mm** outline, **3 mm rounded
corners**, purple solder mask and white silkscreen. GPIO17 controls the
screen supply and both USB touch paths. Console and ring power use their
separate AUX branch. No extra Pi ribbon or USB-C module is needed.

There are **42 populated electrical references plus the F1 holder** and four
M3 mounting holes. The separate shield-drain solder pads have been removed.
The board has eight cable headers and two USB relays.
Headers have vertical pin rows, pin 1 at the bottom and retaining walls on
the left, viewed from the component side. Cables enter from above. Mounting
centers are (4, 4), (64, 4), (4, 72) and (64, 72) mm. The 3.5 mm unplated
holes have 4.25 mm copper keepouts for M3 heads/washers up to 7 mm diameter.

The USB host-presence circuit and AUX-powered data relays are retained.
Each USB shield joins board ground through XH pin 5. Host VBUS only senses connection;
it supplies neither relay coils nor screens. The selected power and fuse
changes are described in the
[implementation plan](../../../docs/plan/2026-09-27-screen-power-stock-cost-1072-plan.md)
and [fuse/coil assessment](../../../docs/reviews/screen-power-stock-cost-1072/holder-coil-budget.md).

The [manufacturing record](../../../docs/reviews/pcb-finish-all-three-1072/manufacturing-zips.json)
identifies the verified manufacturing archives and their board hashes. Use
those archives rather than exporting an unreviewed working copy. Revision I
remains withdrawn because of incorrect
USB relay common connections. The corrected commons 3/6 and normally open
contacts 4/5 remain unchanged. No pre-PCB prototype or further owner
measurements are required. Design review cannot establish assembled USB
compliance, exact shutdown timing or enclosure temperature.
Issue: [#1072](https://github.com/tomassasovsky/segno/issues/1072).

## Wiring

| Connector | Function |
| --- | --- |
| J1, JST VH 2-pin | Dedicated AUX input: pin 1 = +5 V, pin 2 = ground. Use the existing nominal 5 V buck. The assessed coil-drive envelope requires **4.75–5.25 V at J1**, before onboard F1 and its holder; this is not a guarantee of either screen's minimum operating voltage. |
| J2, JST XH 2-pin | Console J25 control. Pin 1 = BCM GPIO17; pin 2 = ground. One two-wire cable, numbered pins connected 1:1. |
| J101 / J201, JST XH 5-pin | USB-A male donor tails from each Pi USB 2.0 host port; channels 1 / 2. |
| J102 / J202, JST XH 5-pin | USB-C male donor tail to UPERFECT (channel 1), and Micro-B male donor tail to APROTII (channel 2). |
| J103 / J203, JST VH 2-pin | Screen power outputs. Pin 1 = switched +5 V; pin 2 = ground. Feed the separate screen power leads; final cable termination remains to be selected. |

The existing Pi-to-console ribbon stays directly connected. Console J25 takes
GPIO17 from physical Pi pin 11. This board has no 40-pin header and takes no
screen power from Pi GPIO. GPIO high enables both channels; low, disconnected,
or an unpowered Pi defaults them off. The Pi, board, HDMI and screens share ground.
Each USB plug carries VBUS, D−, D+, ground and shield together; see the cable
contract below.

### What “off” means

With AUX still powered, a low or disconnected GPIO17 turns off the shared
screen supply and opens both USB data paths. The main power connectors and
USB-touch VBUS all come from that switched supply; Pi host VBUS does not
feed the screens. An electrically unpowered Pi therefore defaults the board
off even if the dedicated screen buck remains powered.

A software-halted Pi that still has input power must explicitly release or
lower GPIO17. R2 is 4.7 kΩ, 1%, to shunt weak pull-ups on a released signal.
The assessed weak-source case is at most 3.63 V through at least 50 kΩ:
Including resistor tolerances and a 1 µA injected-leakage allowance, Q1's
unloaded base stays below 0.314 V, within the 0.35 V base-bias design budget.
This is a design envelope, not a guaranteed RP1 pull-resistor specification;
leave the internal pull disabled. An actively driven high still enables the
board. The board follows this signal; it does not detect Linux shutdown
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
`Connector_JST:JST_XH_B5B-XH-A_1x05_P2.50mm_Vertical`, with
**B5B-XH-A(LF)(SN)** board headers and **XHP-5** mating housings. It is a
2.50 mm pitch, shrouded friction-retained connector with 1.10 mm nominal finished PCB holes.
Use the exact five-position parts in the
[JST XH drawing](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).
The active harness is assembled from suitable existing USB donor cables;
the earlier ready-made four-pin cable selection is superseded.

All four headers use the following pin map. Read the numbered PCB pads and
bottom-side labels, not wire colors or a mirrored view of the cable housing.

| PCB pin | Signal | Input J101/J201 | Output J102/J202 |
| --- | --- | --- | --- |
| 1 | +5 V | Pi VBUS; low-current host detection only | Fused switched touch supply |
| 2 | D− | Host data | Screen data |
| 3 | D+ | Host data | Screen data |
| 4 | GND | Common ground | Common ground |
| 5 | Shield | Cable shield to board GND | Cable shield to board GND |

One USB-A-to-USB-C donor and one USB-A-to-Micro-B donor can supply the four
touch tails, retaining their factory USB plugs and overmolds. Use shielded
USB 2.0 high-speed data cables with an intact controlled pair, not charge-only
leads. Establish conductor size and insulation diameter from the exact cable
specification or the exposed donor; neither is known for the owner's existing
cables. The owner confirmed that the available cables physically reach their
installed destinations. This closes the earlier reach concern; it does not
establish wire gauge, insulation diameter, shielding or USB performance.
Measure and cut the completed tails to the retained assessed
length limits: **30 cm per host tail, 25 cm for the USB-C touch tail and
30 cm for the Micro-B touch tail**, including service slack. If a measured
route exceeds a limit, resolve placement or assess the longer complete USB
channel before accepting the harness; the connector change does not establish
enclosure fit.

Use four XHP-5 housings and **20 new contacts**, five per cable. The specified
**SXH-001T-P0.6** contact accepts 28–22 AWG conductors and **0.9–1.9 mm
insulation outside diameter**. Both limits must hold, including at pin 5.
Use matching crimp tooling and inspect contact retention and insulation support.
Do not force an unsuitable donor wire into this contact or fold strands to
make it fit. A different conductor/insulation range needs a documented compatible
termination before assembly.

The two separate main-power leads remain: one USB-C lead to UPERFECT and one
Micro-B lead to APROTII, connected to J103/J203 through the larger two-pin VH
harness. The XH touch cables carry a **500 mA design allocation**, not the
screen's main power.
The host lead's VBUS feeds approximately 50 µA of presence-sensing load at
the upper 5.5 V host corner. AUX supplies the relay coils. Screen touch current must
be measured with both screen connectors attached; a screen may join the
supplies internally, and the 800 mA fuse is not an active 500 mA limiter.

Before connecting equipment, measure each cable's pin-to-contact continuity,
including USB shell to pin 5, and check for shorts. Retain the USB-C donor's
proper legacy-source configuration (56 kilohm Rp to VBUS) inside its plug;
test both plug orientations. XH pin 5 is shield, not CC. An unknown plug's
current advertisement must not be inferred from wire colors or connector shape.
USB speed, voltage drop and cable temperature remain first-assembly acceptance
checks. Factory cable certification does not certify a cut cable and PCB channel.

Keep each cable's foil/braid and twisted data pair intact up to the shortest
practical fanout. Terminate the shield at **pin 5 in the same removable plug**.
Use a short insulated drain termination within the contact's conductor and
insulation ranges; if the bare drain cannot be crimped correctly, join it to
a short suitable insulated wire and insulate the joint. Keep this shield
breakout at most **10 mm** as a construction target and secure the cable jacket
so pulling the cable does not load the individual contacts. The five-pin plug's
local fanout fit must be checked with the actual donor; the old side-solder-pad
fit assessment does not establish it. Keep pin 4 as the dedicated power return;
do not use foil or loose braid for load current. No shield wire is separately
soldered to the PCB: unplugging the XH housing disconnects all five conductors.
See the [current harness notes](../../../docs/reviews/screen-power-ground-cleanup-1072/harness.md)
for quantities, procurement and inspection details.

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
restore the observed alternate power path. Upstream USB VBUS feeds only its own 10 kΩ/100 kΩ host-presence detector,
and never connects to a screen supply. The coil and its bypass use AUX.

### Required AUX branch protection

F1 is a **Schurter SPT 0001.2513, 8 A time-delay 5 × 20 mm cartridge** in an
**OGN 0031.8201** PCB holder. It sits immediately after J1, ahead of every
capacitor, coil, control circuit and power contact feed. Replace the fuse
with power disconnected. The holder is soldered once; the cartridge is
removable. No separate inline holder is included in this design or shopping
list. The four downstream Bel fuses are soldered components.

Wire the AUX positive split directly to J1 pin 1 and ground to J1 pin 2.
Keep this incoming pair short (15 cm one-way design target), **16 AWG**,
insulated, secured and protected from abrasion. F1 does **not** protect a
short in this incoming cable or the short J1-to-F1 trace. The retained buck's
advertised protection has no public threshold/response curve, and the
upstream 20 V T5A fuse does not establish 5 V fault-clearing behavior. This
is supplementary downstream protection, not an active current clamp or a
promise of prompt clearing from a nominal 10 A supply. Console/ring remain
on their separate AUX branch.

## Circuit and limits

The normally open **K1, Omron G6C-1117P-US DC5**, switches the shared screen
rail. Its contact is rated **10 A at 30 VDC resistive**, with 30 mΩ initial
maximum contact resistance. Coil pins are **8 positive / 1 negative**;
contact pin **4 = fused AUX**, **3 = SWITCHED_5V**. Do not substitute the
similarly named two-pole G6C-2117. The chosen part's coil is 5 V, 125 Ω
±10%, approximately 40 mA. Its release opens the supply in both directions;
while closed, a voltage applied at a screen output can feed back into AUX
until GPIO17 goes low. This is not instantaneous reverse-current protection
on loss of the buck supply.

Q1/Q2 buffer GPIO17 into DATA_ENABLE. **Q5, IRLZ44NPBF**, switches K1's coil:
pin 1 gate = DATA_ENABLE, pin 2 drain = POWER_COIL_LOW, pin 3 source = GND.
**D3, P6KE6.8CA**, is a bidirectional TVS across that coil. Q5 carries only
coil current and requires no heatsink; its drain tab is electrically live
and must clear metal hardware. R7 is 10 kΩ and holds the gate rail low when
disabled. The former Q3/Q4, charge pump, optocoupler and negative supply are
removed.

Each USB relay coil is powered from fused AUX through two series TN0702
switches. Q101/Q201 require DATA_ENABLE; Q102/Q202 require their own host
VBUS through a 10 kΩ/100 kΩ divider. Both conditions must be true for that
channel's data contacts to close. **D101/D201, 1N4007G**, clamp coil flyback:
cathode to AUX, anode to the corresponding coil low side. Each coil also
has a local 100 nF bypass. USB contact pins remain coil 1+/8−, commons 3/6,
normally open 4/5 and unused normally closed 2/7.

- Shared switched-screen planning load: **4.25 A** for both main
  feeds and both touch feeds. A separate 60 mA bleeder allowance and
  150 mA coil/control allowance bring the J1 bound to **4.46 A**. These are conservative
  allocations from the available readings, not measured simultaneous maxima.
- Main branches F101/F201 use **Bel 0697H4000-02, 4 A**; their lead ceiling
  remains **3 A**. Touch branches F102/F202 use **0697H0800-02, 800 mA**;
  their lead ceiling remains **500 mA**. Branch ceilings are not additive
  guarantees. Keep both main-power leads connected: screens may join main
  and touch inputs internally, so a thin touch cable is not a replacement
  for a main-power lead. Do not upsize the touch fuses.
- Fuses are not electronic current limits. Their nominal melting integrals
  do not guarantee clearing before every possible partial fault heats a
  wire or a contact. Retain the short, protected harness construction.
- There is no active inrush control. The relay-contact assessment includes
  bounded capacitor-energy sensitivities; screen capacitance and actual
  surge waveform are unknown. A 10 A resistive contact rating alone does
  not establish capacitive-load endurance.
- R8 is a 100 Ω, 1 W bleeder (approximately 0.25 W at 5 V). The software's
  five-second shutdown wait remains provisional until assembled operation
  establishes actual screen discharge time.
- Host detection draws approximately **50 µA** per port at 5.5 V. Even its
  10 kΩ series resistor alone bounds sensing current below 0.556 mA for a
  nonnegative gate node. This is not whole-screen suspend certification.

The [fuse/coil budget](../../../docs/reviews/screen-power-stock-cost-1072/holder-coil-budget.md)
uses 100 mV for F1, at most 10 mΩ for the complete holder path, a 20 mV
copper target and a 5 mV Q5 allowance. K1 picks up before the screen load is
connected: at less than 150 mA pre-contact current, the 100 °C winding
sensitivity leaves **45.5 mV** pickup margin. The deliberately simultaneous
4.46 A / 100 °C loaded case leaves only **2.4 mV** above the same pickup model;
this is not substantial margin or a guaranteed holding threshold. The
100 °C winding ceiling at 60 °C local air is an engineering envelope, not a
manufacturer guarantee of self-heating. The
[filled-copper assessment](../../../docs/reviews/screen-power-stock-cost-1072/ground-return-assessment.md)
records the calculated positive and ground-return losses for the final native
board, including a thinner-copper sensitivity. It is not a measured guarantee.

TE's standard 140 mW continuous operating-voltage curve permits the
5.25 / 4.5 = 1.167 nominal-voltage ratio at the negligible data-contact load
through 85 °C local air. Its upper thermal limit already includes coil
self-heating; this does not replace the separate hot-pickup lower-bound check.

The retained IM02 hot-coil model gives 4.3196 V at the coil against an
estimated 4.2094 V pickup requirement, **110.2 mV margin**, including the
fuse and holder. Fuse hot resistance, aged contacts, exact enclosure heating,
and the screen-end connector losses remain outside manufacturer-guaranteed
bounds. The 4.75 V J1 floor is a relay-drive condition; do not advertise it
as proof that the complete screen power path stays above an unknown screen
minimum voltage.

## Placement and routing

USB inputs sit on the left edge and touch outputs on the right. Both rows
of vertical XH plugs remain accessible from above. F1 and K1 occupy the
shared power section; the four compact branch fuses sit near their outputs.
The [revision review](../../../docs/reviews/screen-power-stock-cost-1072/review.md)
records native clearance, body, copper and fabrication checks. Leave access
above F1 to remove its cartridge with power disconnected; mated housings
and upright parts also require enclosure headroom.

The nominal 1.6 mm, two-layer stack uses 35 µm outer copper and a 1.53 mm
FR-4 core, with nominal relative permittivity **4.5**. The revised target is
**0.78 mm width / 0.23 mm gap**, on B.Cu without data vias. It preserves the
1.01 mm center pitch. A converged quasi-static field calculation including
nominal solder mask estimates **90.8 Ω differential**. This corrects the
preceding uncoated calculator estimate, which did not capture the coating's
effect. See the [reproducible impedance assessment](../../../docs/reviews/screen-power-usb-revision-1072/impedance-assessment.md)
for material assumptions, independent checks and sensitivity bounds.

JLCPCB's [controlled-impedance service](https://jlcpcb.com/capabilities/pcb-capabilities)
starts at four layers. This two-layer order does not use it, and published
ordinary fabrication tolerances do not guarantee a USB impedance band. The
Gerber job therefore omits `ImpedanceControlled`. The calculation is a design
target, not measured impedance or a complete-channel compliance result.
Connector and relay pad
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

Power routing uses constant widths and rounded bends. Validation removes
zones before checking required power paths, so a filled overlay cannot hide
a missing or narrow trace. The filled-copper assessment includes the shared
positive feed and actual ground return. The existing eight USB data nets,
their widths, pair spacing and return paths require verification after any
connector or nearby component movement.

These choices follow [TI's USB layout guidance](https://www.ti.com/lit/an/slla414/slla414.pdf)
(short pairs, continuous return planes, through-hole connector signals on the
bottom) and [Sierra Circuits' placement guidance](https://www.protoexpress.com/blog/component-placement-guidelines-pcb-design-assembly/)
(connector anchors, functional grouping and signal flow).

## Sources and assembly

- [Omron G6C power relay](https://components.omron.com/us-en/system/files/2026-03/datasheet_pdf/K018-E1.pdf).
- [Schurter SPT cartridge](https://www.schurter.com/pdf/english/typ_SPT_5x20.pdf) and [OGN holder](https://www.schurter.com/en/datasheet/typ_ogn.pdf).
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
- [Bel 0697H branch fuses](https://www.belfuse.com/media/datasheets/products/circuit-protection/ds-cp-0697h-series.pdf):
  5.08 mm lead pitch, 0.6 ±0.1 mm lead diameter; use the specified assembly
  process limits. The -02 tape pitch is not the PCB lead pitch.
- [JST VH harness](https://www.jst.com/wp-content/uploads/2021/08/eVH.pdf)
  and [JST XH control/data harness](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).

`hand/bom.csv` lists all electrical references and a separate F1_HOLDER
purchasing row. The holder and cartridge share one PCB footprint.
`external_bom.csv` lists harness housings, contacts, donor cable assemblies and
mounting hardware. Populated footprints use bundled STEP models. The four
mounting holes are bare PCB features without separate bodies. Custom models are simplified dimensioned
assembly models, not vendor CAD. See [model sources and limitations](models/README.md).
The exported `native/` folder keeps model paths portable; open its hand project
in KiCad. Use `top.png`, `perspective.png`, and `assembly.pdf` together to inspect
components and labels; `F-copper.svg` and `B-copper.svg` show the actual routing.

See [component costs](COSTS.md) for the refreshed full Mouser US quote and
matching shared cart: all 55 lines / 192 units available at the check,
$88.24 before tax including selected UPS Ground shipping. Final address and
tax are not entered, and stock availability does not guarantee dispatch timing.

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
extra 1 A for touch, if not already included, gives about **3.2–4.2 A**
for the screens. The allocation rounds this up to **4.25 A**, then adds a
separate 60 mA bleeder bound: **4.31 A** through the power contact. Its
30 mΩ initial maximum gives 0.129 V drop and 0.557 W contact dissipation; coil dissipation
is additional. Initial contact resistance is not a guaranteed aged/hot
maximum. These figures do not establish the exact temperature of the
assembled relay or screens' minimum voltage.

Normal pills, unrestricted full-white 40-LED ring and console total about
3.358 A from AUX. Together with the screen-board allowance of 4.46 A this is
**7.818 A** against the retained nominal 10 A buck. The ring remains on its
separate direct AUX branch. This does not authorize all 120 LEDs at full
white simultaneously or turn the nominal buck rating into a surge limit.

## First assembly

No separate pre-PCB build is required. After soldering:

1. Check supply polarity, shorts, cartridge seating, cable pin order and live-tab clearance.
   Verify the five-pin donor harness map, contact retention and shell-to-pin-5
   continuity before attaching the Pi/screens.
2. Connect both main-power leads and both touch paths through this board.
   Verify both screens start and touch works, including the large screen's
   480 Mbps hub path and both USB-C plug orientations.
3. Check GPIO high/on and low/off, then normal Pi shutdown with HDMI attached.
   Both panels must go dark before HDMI stops; adjust the existing software
   wait if the actual discharge time needs it.
4. Check the assembled fit and ordinary operation at maximum brightness.
   Keep Q5's drain tab away from enclosure metal and retain access to F1.
   TO-92 outer leads use the specified 2.54 mm pitch.

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
The source-circuit checks cover independent host presence, GPIO defaults,
relay contact states, coil clamps, exact BOM parts and protection boundaries.
Native checks separately cover schematic/netlist/PCB parity, ERC/DRC,
power widths, USB connectivity, pair lengths and filled ground reference,
mounting holes, model resolution and hand-solderable assembly geometry.
Mutation tests must reject broken connections, incorrect contact/coil pins,
undersized holes, thin power paths, unsupported substitutions and unsafe
GPIO pull networks. See the final revision review for observed results;
a successful source-only check is not native-board approval.

`export.py` publishes Gerbers, drills, BOMs, positions, drawings, models and
renders only after fresh successful checks and unchanged input hashes.
