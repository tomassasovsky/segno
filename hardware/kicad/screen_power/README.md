<!-- cspell:words overvoltage derate autosuspend overmolds fanouts onsemi Nexperia Omron derating autoroutes pulldowns -->
<!-- cspell:words SUP SUM Rds backfeed Micro pulldown Vgs Littelfuse Lumberg MMBT DMODEL stackup -->
# Screen power and touch switch

Revision B removes the external USB-C evaluation modules and the native USB-C
source controllers. Both versions use the same discrete circuit: one shared
5 V switch, two fused power outputs, and two switched USB touch paths.
The APROTII can stay lit from touch alone, so disconnecting only its separate
power lead is insufficient.

**Status: both revision B boards pass native ERC and DRC with zero violations
and zero unconnected items. Revision A is superseded.**
CAD validation does not establish thermal performance, USB compliance, screen
compatibility, enclosure fit, or shutdown timing. Issue: [#1072](https://github.com/tomassasovsky/segno/issues/1072).

| Version | Board | Assembly |
| --- | --- | --- |
| Hand | 72 × 84 mm | 41 through-hole components including mounting holes; no SMD parts or external electronic modules. |
| Factory | 72 × 74 mm | Same circuit, with surface-mount transistors, resistors, and small capacitors; connectors, relays, fuses and bulk capacitors remain through-hole. |

Both have four M3 mounting holes, 4 mm from the corners. Compared with the
130 × 120 mm revision A carriers, board area falls 61.2% for hand assembly
and 65.8% for factory assembly. This excludes the two external modules that
revision A hand assembly also required.

## Wiring

| Connector | Function |
| --- | --- |
| J1, JST VH 2-pin | Dedicated buck AUX input. Pin 1 = +5 V; pin 2 = ground. **5.0–5.25 V measured at this connector under load**, target 5.1 V. |
| J2, JST XH 2-pin | Console J25 control. Pin 1 = BCM GPIO17; pin 2 = ground. One two-wire cable, numbered pins connected 1:1. |
| J101 / J201, USB-B | One shielded USB 2.0 A-to-B cable from each Pi host port. |
| J102 / J202, USB-A | Existing display touch cable: UPERFECT channel 1; APROTII Micro-B channel 2. |
| J103 / J203, JST VH 2-pin | Screen power outputs. Pin 1 = switched +5 V; pin 2 = ground. Feed the existing screen power leads/adapters. |

The existing Pi-to-console ribbon stays directly connected. Console J25 takes
GPIO17 from physical Pi pin 11. This board has no 40-pin header and takes no
screen power from Pi GPIO. GPIO high enables both channels; low, disconnected,
or an unpowered Pi defaults them off. The Pi, board, HDMI, USB shields and
screens share ground.

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

Q2 drives the two touch-relay MOSFET gates. Each G6K-2P-RF DC5 relay opens both
D+ and D− when disabled. Its coil uses its own Pi host VBUS, so loss of that host
supply releases that channel's contacts. This is not galvanic isolation. The
RF rating is not proof of USB compliance; USB operation must be tested on the
actual screens and cables.

- Shared design load: up to **6 A combined**, provisional until thermal tests.
  The SUP70101EL/SUM70101EL pair dissipates up to 1.08 W at 6 A using the
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
- Each host relay coil draws about 21 mA while enabled. USB suspend compliance
  is not established; test appliance USB autosuspend and wake behavior.
- The hand power-transistor footprint uses 1.4 mm finished holes and at least
  0.25 mm annulus for the selected part's maximum rectangular leads.
- TO-220 tabs are electrically live drains. Prevent contact with each other,
  the enclosure and mounting hardware. Do not fit an uninsulated shared heatsink.
- Provide suitable protection upstream of J1 and appropriately rated wiring.
  The on-board fuses do not protect the shared input cable or the entire switch.

## Placement and routing

USB inputs face the left edge and touch outputs face the right edge. The two
relay channels follow this signal flow. Main power enters at the top; the
power transistors are grouped there and each output fuse sits beside its branch.
GPIO control occupies the gap between channels. Connector courtyards and M3
holes are checked, but cable overmolds, latch access, screwdriver access and
vertical transistor clearance still need an enclosure fit check.

The four-layer, nominal 1.6 mm stack uses continuous inner ground planes.
USB pairs run on **B.Cu**, directly from the through-hole connector pins, with
no data vias, 0.26 mm traces and a 0.16 mm coupled gap. Pad fanouts necessarily
separate the traces. Ask the fabricator to confirm 90 Ω differential impedance
for the documented JLC04161H-7628 stack. Shared power uses 4.5 mm trunks with
3 mm portions, 2 mm main branches and short 1.5 mm transistor-pin necks.
Copper current capacity and temperature rise remain physical acceptance items.

These choices follow [TI's USB layout guidance](https://www.ti.com/lit/an/slla414/slla414.pdf)
(short pairs, continuous return planes, through-hole connector signals on the
bottom) and [Sierra Circuits' placement guidance](https://www.protoexpress.com/blog/component-placement-guidelines-pcb-design-assembly/)
(connector anchors, functional grouping and signal flow).

## Sources and assembly

- [Vishay SUP70101EL through-hole MOSFET](https://www.vishay.com/docs/77632/sup70101el.pdf)
  and [SUM70101EL factory MOSFET](https://www.vishay.com/docs/77605/sum70101el.pdf).
- Hand relay drivers: **onsemi 2N7000**, exact bulk MPN, TO-92 S1/G2/D3;
  [NDS7002A/D data sheet](https://www.onsemi.com/download/data-sheet/pdf/nds7002a-d.pdf)
  specifies 5.3 Ω maximum at 4.5 V. Do not substitute 2N7000BU, whose guaranteed
  gate-drive conditions differ. Factory: Nexperia **2N7002,215**;
  [2N7002 data sheet](https://assets.nexperia.com/documents/data-sheet/2N7002.pdf).
- [Omron G6K RF relay](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g6k_2f_rf.pdf).
- [Littelfuse 251 fuse dimensions, derating and solder limits](https://www.littelfuse.com/assetdocs/fuse-251-datasheet?assetguid=f47a0bb7-8ede-4679-9646-7114c3787688).
  The selected axial fuses are not reflow rated; arrange a separate insertion
  and soldering step for factory assembly. Follow their 350 ± 5 °C / 5 s limit.
- [JST VH harness](https://www.jst.com/wp-content/uploads/2021/08/eVH.pdf)
  and [JST XH control harness](https://www.jst.com/wp-content/uploads/2021/01/eXH.pdf).

Variant `bom.csv` files list every populated component. `external_bom.csv`
lists harness housings, contacts, existing cables and mounting hardware.
The STEP/render model set is incomplete for custom parts; absence of a model
must not be interpreted as empty mechanical space. Use the assembly drawing
and manufacturer dimensions, especially the USB-B sockets and RF relays.

## Physical acceptance before release

1. Check polarity, continuity, short circuits, protective fuses and insulated
   live tabs; initially power from a current-limited bench supply.
2. Test GPIO high, low, floating and Pi unpowered. Power the output with AUX
   absent and GPIO low to check off-state reverse blocking and D1 isolation.
3. Measure voltage drop and temperature at each rated load, simultaneous
   startup, hot ambient and actual cable lengths. Record inrush and fuse behavior.
4. Verify both touch devices enumerate, operate and reconnect reliably through
   the relays; test USB unplug/replug, suspend, wake, reboot and brownout.
5. Leave HDMI attached. Disable GPIO and measure both screen rails until the
   panels go fully dark; check residual HDMI power and the observed APROTII
   touch-only backfeed condition. Verify fault behavior if main/touch join.
6. Implement and test early GPIO shutdown before HDMI stops, allowing the
   **measured** discharge time. Hardware alone does not establish that the blue
   no-signal frame is eliminated; startup/shutdown integration is still required.

## Rebuild and verification

Use KiCad 10 CLI and its bundled Python, SKiDL 2.3 with KiCad symbol paths,
and Freerouting 1.9.0. Set `SKIDL_PYTHON`, `KICAD_PYTHON`, `KICAD_CLI` and
`FREEROUTING_JAR` for the local installation, then run `build.sh [hand|factory|all]`.
The generator writes the schematic/netlist, places from `layout.py`, manually
routes critical paths and autoroutes remaining low-current nets. `finish.py`
adds the stack and labels; `cleanup.py` removes verified redundant tails.

Run `check.py all --self-test --output validation.json` with KiCad Python.
It checks native ERC/DRC, full schematic/netlist/PCB parity, actual USB and
console GPIO connectivity, circuit boundaries, assembly types and drive margins.
Fault injection checks that broken USB/control copper, a host power bridge,
accidental hand-assembly SMD parts, undersized power copper, unsupported relay
drivers, wrong resistor tolerances and excessively weak pulldowns are rejected. `export.py` publishes
Gerbers, drills, BOMs, positions, drawings, models and renders only after a
fresh successful check and unchanged input hashes.
