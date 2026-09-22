<!-- cspell:words unassembled SSOP RVCR WQFN PGOOD ILIM MMBT BRSZ Abracon YAGEO DRNPO Lumberg stackups EDID pulldowns backfeed DMODEL Omron Littelfuse IRLZ NPBF -->

# Screen power and touch board

This board switches both displays' main power and USB touch power from the
existing 5 V BUCK_AUX supply. The hand version disconnects USB data with relays;
the factory version uses ADuM3165B USB isolators. Neither routes Pi USB VBUS
to a display. This addresses the observed APROTII behavior: its direct touch
cable alone can keep the screen lit.

**Status: both corrected boards pass native ERC and PCB DRC with zero
violations or unconnected items. The hand carrier has 56 through-hole
components and no SMD pads.** This
guide does not establish production readiness, USB compliance, panel
compatibility, enclosure fit, or successful shutdown timing. The physical
acceptance matrix below must be completed for the assembled variant.

Issue: [#1072](https://github.com/tomassasovsky/segno/issues/1072).
Design intent: [implementation plan](../../../docs/plan/2026-09-21-feat-screen-power-board-plan.md).
`circuit.py` selects the variant; `hand_circuit.py` defines the hand circuit.
`hand/bom.csv` and `factory/bom.csv` cover parts on the respective boards.
[external_bom.csv](external_bom.csv) covers modules, harness parts, and cables.

## Choose one variant

| Variant | Main-power sources | Assembly |
| --- | --- | --- |
| `hand/` | Two separately mounted, preassembled TI TPS25810EVM-745 modules | Every component fitted to the carrier is through-hole: relays, transistors, axial resistors/diodes, fuse clips, capacitors, and connectors. No surface-mount components need user soldering. |
| `factory/` | Two TPS25810RVCR controllers and USB-C receptacles on the board | Includes WQFN exposed pads and thermal vias; arrange stencil/reflow assembly. Through-hole connectors and radial capacitors still need an agreed assembly process. |

Both carriers are 130 × 120 mm with four M3 mounting holes. The hand-version
EVMs are external modules connected by harnesses; there is no invented EVM
socket or mounting footprint. Measure the purchased modules and USB plug
clearances before committing the enclosure.

## Connections common to both variants

Use channel 1 for the UPERFECT main display and channel 2 for the APROTII 7-inch
display. The two circuits are identical; this is a harness-labeling convention.

| Board connector | Connection |
| --- | --- |
| J1, JST VH 2-pin | Dedicated BUCK_AUX branch: pin 1 = regulated +5 V, pin 2 = GND. Do not feed it from Pi 5 V or the console board's power output. |
| J2, JST XH 2-pin `SCREEN CTRL` | Console J25: pin 1 = BCM GPIO17 signal, pin 2 = GND; connect numbered pins 1:1. |
| J101, USB-B | Ordinary USB 2.0 A-to-B data cable from the first Pi USB 2.0 host port. |
| J201, USB-B | Ordinary USB 2.0 A-to-B data cable from the second Pi USB 2.0 host port. No hub. |
| J102, USB-A `TOUCH` | USB 2.0 A-to-C data cable to the UPERFECT **touch** input. |
| J202, USB-A `TOUCH` | USB 2.0 A-to-Micro-B data cable to the APROTII **touch** input. |

USB-A and USB-B contact numbers are 1 = VBUS, 2 = D−, 3 = D+, 4 = GND; shields
connect to GND. Upstream VBUS is `HOST1_5V` or `HOST2_5V`. Downstream VBUS is
`S1_TOUCH_5V` or `S2_TOUCH_5V`. Never join these rails or bypass the board with a
direct Pi-to-panel touch cable. Use data-capable touch cables, not charge-only
cables or USB-A-to-A leads.

Keep the existing Pi-to-console 40-pin ribbon connected directly as before.
The console's added **J25** brings **BCM GPIO17** from Pi physical pin 11 to
J25 pin 1; J25 pin 2 is GND. One short two-wire lead connects console J25 to
screen-board J2, pin 1 to pin 1 and pin 2 to pin 2. The screen board has no
40-pin header or Pi power-pin connection. Its J2 signal passes through
R1 = 1 kΩ; R2 = 10 kΩ pulls `DISPLAY_ENABLE` low if the lead is removed.
This connection does not replace the Pi's existing power button.

Both board headers are JST **B2B-XH-A(LF)(SN)**, 2 positions at 2.50 mm pitch.
For the one installed screen-board variant, make one 22 AWG two-wire lead with
two **XHP-2** housings and four **SXH-001T-P0.6** crimp contacts. Confirm
numbered continuity and signal/ground polarity before power-up; housing keying
alone does not establish the wire order. This lead carries GPIO and ground,
not display power. [JST XH drawing](https://www.jst.com/wp-content/uploads/2021/01/eXH.pdf).

The board, Pi, display cables, shields, and AUX supply share ground.
**The complete instrument is not galvanically isolated.** HDMI already
provides another ground connection.

## Factory main-power outputs

Factory J103 powers the UPERFECT through a compliant C-to-C cable rated for
3 A. Factory J203 powers the APROTII's separate Micro-B **power** input through
a compliant C-to-Micro-B cable. These are native 5 V USB-C source ports with
attachment detection and 3 A advertisement; they do not negotiate higher PD
voltages. Cable and panel ratings still apply, especially at Micro-B.

On each six-contact receptacle: A9/B9 = switched main +5 V, A12/B12 = GND,
A5 = CC1, B5 = CC2, shield = GND. There are no USB data contacts on these
power-only receptacles. Both CHG inputs on each TPS25810 are high; its 100 kΩ
reference resistor connects REF to REF_RTN, not directly to board GND.
[TI TPS25810 data sheet](https://www.ti.com/lit/ds/symlink/tps25810.pdf).

## Hand-version EVM assembly and wiring

Apply this configuration to **each** TPS25810EVM-745. `EVM J…` below refers to
the module, not the carrier. Disconnect all supplies while changing wiring.
Use the module pin-1 marks and confirm continuity against the
[TI EVM schematic](https://www.ti.com/lit/pdf/slvuai0).

| EVM jumper | Required setting |
| --- | --- |
| J1, status LED power | Open. |
| J2, J5, J9, supply selectors | Shunt pins 2–3 on all three. |
| J6, enable selector | Remove shunt; carrier drives pin 2. |
| J8 and J11, current advertisement | Shunt pins 1–2 on both: 3 A. |
| J13 and J14, CC simulation | Open. |
| J15, charging-signature helper | Open. |
| J4, barrel input | Unused; do not connect another supply. |

| Carrier connection, per channel | EVM destination |
| --- | --- |
| J103/J203 pin 1, AUX +5 V | Split to J10-1 IN1, J10-2 IN2, and J12-1 AUX. |
| J103/J203 pin 2, power GND | J12-2 GND. |
| J104/J204 pin 1, `DISPLAY_ENABLE` | J6-2 EN. |
| J104/J204 pin 2, `/UFP` | TP8; fit a soldered, strain-relieved wire at this normally unpopulated pad. |
| J104/J204 pin 3, switched main rail | J7-1 OUT, for the carrier's discharge path. |
| J104/J204 pin 4, control GND | J7-2 GND. |

**Solder a separate 100 kΩ resistor directly between EVM J6-2 and J6-3 on each
module. This is mandatory.** It must remain attached to the EVM when its control
harness is removed. A resistor on the carrier cannot hold a disconnected
module's EN low. Insulate and secure the added leads; do not refit the J6 shunt.

Each screen's main power exits its EVM's J3 USB-C receptacle. Use C-to-C for the
UPERFECT and C-to-Micro-B for APROTII power, exactly as for the factory variant.
The carrier's small XH control harness carries only control and discharge
current; it is not the display's main-power feed. Its J7 connection is an
intentional switched discharge load, not an EVM test load to leave enabled.

Use VHR-2N housings with SVH-41T-P1.1 contacts for the VH power connections.
Use 16 AWG for the shared AUX input and suitably rated short EVM branches;
the contact accepts 20–16 AWG. Use XHP-4 housings with SXH-001T-P0.6 contacts
and 22 AWG wire for the two control harnesses. Provide secure, insulated EVM
header connections and strain relief. These are bespoke harnesses specified by
the table, not unspecified jumper-wire kits. [JST VH](https://www.jst.com/wp-content/uploads/2021/08/eVH.pdf),
[JST XH](https://www.jst.com/wp-content/uploads/2021/01/eXH.pdf).

## Hand-version relays, fuse, and discharge

Fit the exact relay models and coil voltages below. The RF relay's orientation
mark and coil polarity matter; its PCB-terminal footprint differs from the
surface-mount versions. The two coil circuits must stay separate.

| Hand references | Parts and role |
| --- | --- |
| K101/K201 | Omron **G6K-2P-RF DC5**: normally open contacts connect both USB data wires only while the channel is enabled and its Pi USB VBUS is present. |
| K102/K202 | Omron **G5LE-1 DC5**: common contact supplies touch VBUS; normally open contact takes fused AUX; normally closed contact discharges touch through R106/R206. |
| Q102/Q202 | **2N3906BU** PNP attachment detectors. A released or missing EVM `/UFP` lead keeps both channel drivers off. |
| Q104/Q204; Q103/Q203 | **2N7000** data-coil drivers; **IRLZ44NPBF** touch-power-coil drivers. |
| D101/D201; D102/D202 | **1N4007-E3/54** flyback diodes; cathode bands face the corresponding host or AUX supply. |
| F101/F201 | Each footprint takes **two Littelfuse 01110501Z clips**, plus one removable **Eaton BK/GMA-800-R** 800 mA cartridge. Buy four clips total from the hand BOM and two cartridges from the external BOM. |
| R105/R205; R106/R206 | **100 Ω, 1 W** main and touch discharge resistors. Q101/Q201 are **2N7000** main-discharge switches; Q1 is the **2N3904BU** global inverter. |
| C103/C203 | **EEU-FR1A151**, 150 µF, 10 V; 5 mm diameter, 2 mm lead pitch. Observe polarity. |

Each USB-B VBUS supplies only its own RF relay coil and local bypass capacitor.
The power-relay coil takes AUX. Losing host VBUS opens USB data even if GPIO17
remains high. Touch power may remain on from AUX until GPIO17 goes low or the
main port detaches. Separate low-side MOSFETs keep these coil supplies apart.

Omron characterizes the RF relay at 1 GHz; this supports investigating USB
480 Mbit/s operation, but does not establish USB compliance or performance of
the finished board. Verify the actual touch controllers and any internal USB
hub, including enumeration, sustained use, contact bounce, and repeated power
cycles. The carrier adds no USB isolator, crystal, or semiconductor ESD array.
[Omron RF relay data sheet](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g6k_2f_rf.pdf).

The RF coil draws about **21 mA per Pi USB port** while energized. This exceeds
the generic USB suspend-current allowance: this design is for the fixed Segno
appliance, with no USB certification or general-purpose adapter claim. Verify
the Pi's USB runtime-power settings and suspend/resume behavior. The two AUX
power-relay coils add about **159 mA nominal** together, before source-controller
and control-circuit consumption.
[RF coil ratings](https://omronfs.omron.com/en_US/ecb/products/pdf/en-g6k_2f_rf.pdf),
[power-relay ratings](https://components.omron.com/us-en/system/files/2025-01/datasheet_pdf/K100-E1.pdf).

The **800 mA fuse is overload protection, not a current limiter**. Eaton permits
up to two minutes to open at 1.6 A. Use these outputs for the specified touch
devices, with a 500 mA operating-load target; the fuse does not enforce that
target or limit startup current. Its position before the relay's normally open
contact leaves the normally closed 100 Ω discharge path working even with the
cartridge removed. A panel's internally shared power rails can still bypass
this fuse through the main cable. Validate fault current, voltage drop, and the
complete harness protection.
[Eaton fuse data sheet](https://www.eaton.com/content/dam/eaton/products/electronic-components/resources/data-sheet/eaton-gma-time-delay-glass-tube-fuses-data-sheet.pdf),
[Littelfuse clip drawing](https://www.littelfuse.com/assetdocs/littelfuse_fuse_clip_111_datasheet?assetguid=b1ca8750-5406-48d2-b921-b86728e90adf).

When GPIO17 goes low, the source modules turn off, the RF data contacts open,
the touch-power contacts return to their discharge position, and the main
MOSFET discharge paths turn on. Relay release and panel discharge take time;
measure that interval before setting the shutdown delay.

## Factory power behavior and limits

Each factory channel has two paths from AUX: TPS25810 supplies main power,
and TPS25221 supplies touch VBUS and downstream ADuM VBUS2. The source's
`/UFP` signal is pulled up locally and inverted by SN74LVC1G14 to enable the
touch branch. A missing attachment signal or controller disable turns this
entire downstream domain off. ADuM PGOOD is unconnected; it does not gate its
own supply. Pi USB VBUS powers only the upstream isolator.

Each TPS25221 uses 80.6 kΩ ±1% at ILIM: calculated branch limits are 604 mA
minimum, 682 mA nominal, and 752 mA maximum. That allows 500 mA for touch plus
69 mA for the downstream isolator. Each output has 150 µF bulk capacitance.
Reverse blocking is specified while the limiter is disabled; do not assume
it while enabled. [TPS25221 data sheet](https://www.ti.com/lit/ds/symlink/tps25221.pdf).

A panel may internally join main and touch power. Its other cable can bypass
an individual branch's limiter and feed a fault backwards. The calculated
combined limiting envelope is up to 4.39 A per panel, not a safe continuous
rating or a bound on every transient. Verify the complete panel, harness,
and upstream protection combination.

Allow up to 138 mA on AUX and 138 mA across the two Pi USB supplies for the
factory isolators at worst-case busy high speed, plus source-controller overhead.
Four 100 Ω / 0.75 W discharge resistors and 2N7002 MOSFETs drain the main and
touch rails when enable is low. The MMBT3904 inverter accepts the Pi's 3.3 V
control signal. Measure discharge time with the actual panels and cables.

## Shared power behavior

| Condition | Intended result |
| --- | --- |
| GPIO low, released, or two-wire control lead absent | Both main sources and both touch branches off; USB data detached. |
| GPIO high and valid main-port Type-C attachment | Corresponding main and touch branches on; touch data connects when that Pi USB host is powered. |
| Pi USB cable absent, GPIO still high | No USB host connection; AUX can still power that screen. |
| Pi USB powered, AUX absent | No USB-fed panel power; hand data relay remains open. |
| AUX powered, Pi USB absent | No board path from AUX into Pi USB VBUS; hand data relay remains open. |

`/UFP` detects the Type-C connection, **not voltage arriving at the panel**.
For C-to-Micro-B, the Rd resistor is in the C plug: removing only the Micro-B
end can leave `/UFP` asserted and touch power on. The panel may then draw through
touch. The factory branch limits current; the hand branch has only the slower
overload fuse described above. Test both ends of each cable separately.

The existing **10 A AUX buck budget is already tight** with both displays and
LEDs. Include the chosen variant's added load and measure total draw with all
approved instrument loads. The external AUX branch needs protection selected
for the measured load and weakest harness component; neither carrier has a
shared input fuse. Keep screen current off the console's power connector, and
do not attach another panel supply. Internally joined panel rails can bypass
either variant's individual branch protection.

## Factory USB, clock, and assembly details

| ADuM3165BRSZ pins | Connection |
| --- | --- |
| 1 VBUS1 | Own Pi USB VBUS, with 100 nF bypass. |
| 3 VDD1; 18 VDD2 | Separate 100 nF capacitors only; not external 3.3 V supplies. |
| 5 XI; 6 XO | Crystal pads 1 and 3 respectively. |
| 8 UD+; 9 UD− | Upstream USB data. |
| 12 DD+; 13 DD− | Downstream touch data. |
| 14 PGOOD | No connection. |
| 20 VBUS2 | Touch-limiter output, with 100 nF bypass. |
| 2, 4, 7, 10, 11, 15, 16, 17, 19 | Common GND. |

The isolator handles either supply starting first and automatically supports
USB low, full, and high speed. With downstream power absent, it removes the
USB attachment. Keep local bypass returns toward pins 2/10 and 11/19, not solely
the other ground pins. [ADuM3165/3166 data sheet](https://www.analog.com/media/en/technical-documentation/data-sheets/adum3165-adum3166.pdf).

Both channels use Abracon **ABM8-24.000MHZ-10-B1U-T**, 24 MHz, CL = 10 pF.
Crystal case pads 2/4 are grounded. Each XI/XO node has an 8 pF C0G load
capacitor, YAGEO **CC0805DRNPO9BN8R0**. These are starting values based on the
ADI evaluation circuit; verify frequency and startup/resume on the actual
board. [Abracon data](https://abracon.com/Resonators/abm8.pdf),
[ADI UG-2038](https://www.analog.com/media/en/technical-documentation/user-guides/eval-adum3165-3166-ug-2038.pdf),
[YAGEO part sheet](https://yageogroup.com/download/specsheet/CC0805DRNPO9BN8R0).

Each USB port has USBLC6-2SC6 ESD protection: pins 1/6 = D+, 3/4 = D−,
2 = GND, 5 = that port's local VBUS. Upstream clamps must never use AUX or
touch VBUS. [ST data sheet](https://www.st.com/resource/en/datasheet/usblc6-2.pdf).
Observe the SSOP pin-1 mark, electrolytic polarity, and each connector's pin-1
mark. C109/C209 use 5 mm diameter / 2 mm pitch; C111/C211 use
6.3 mm / 2.5 mm pitch.

Both variants' J101/J201 use the active **Lumberg 2411 06** USB-B connector and
the project-local
`screen_power:USB_B_Lumberg_2411_06_Horizontal` footprint. Do not substitute the
obsolete 2411 02: its shield-hole positions differ. The 2411 06 drawing specifies
a 16.30 mm deep × 12.00 mm wide body, up to 14.50 mm across its flared tabs,
and 10.90 ±0.20 mm seated height. No verified STEP model is bundled for this
connector, so a board render does not show its enclosure clearance. The local
footprint uses the manufacturer's 0.92 mm signal holes and 2.30 mm shell holes.
[Lumberg dimensioned drawing](https://downloads.lumberg.com/datenblaetter/en/2411_06.pdf).

## Fabrication requirements

Use four layers and the intended **JLC04161H-7628** 1.6 mm stackup: 1 oz outer
copper, 0.5 oz inner copper, and approximately 0.21 mm dielectric between each
outer layer and its neighboring ground plane. USB pairs target **90 Ω
differential impedance** over uninterrupted ground. Have the fabricator
confirm the stackup and pair geometry against the final files; do not silently
substitute another stackup. A routed pair and a clean DRC do not themselves
prove its impedance. [JLCPCB stackups](https://jlcpcb.com/impedance).

Factory WQFN thermal pads and vias require fabricator/assembler agreement on
solder-paste and via treatment. Check the final assembly drawing, BOM, component
positions, board outline, holes, and cable clearances together before ordering.

## Software timing contract — not implemented here

GPIO17 must become high early enough for the displays to power up and provide
EDID before the Pi's display stack settles. Validate cold boot and HDMI
rediscovery; a late userspace enable can leave the wrong mode or no display.
Touch must enumerate on cold boot and after every power cycle.

During orderly shutdown, save the session and finish any goodbye screen, then
drive GPIO17 low **before HDMI video stops or the display stack is torn down**.
Allow the measured rail-discharge interval before losing video. Pi USB VBUS
presence is not a run signal, and a final-halt `gpio-poweroff` action alone is
too late to establish this ordering. Pi service/boot integration and deployment
are subsequent work; this PCB cannot enforce software timing by itself.

HDMI remains directly connected. Its +5 V/EDID path must be tested on the
actual panels with main and touch disabled. If it sustains a visible screen,
that observed path still needs a solution. No black-screen or blue-screen-free
shutdown result is claimed before this test.

## Bench acceptance matrix

All rows are **pending**. Start with unpowered inspection and a current-limited
5 V bench source; use a controlled fault load for protection tests. Record
scope captures, currents, voltages, temperatures, cable identities, and the
assembled variant. For the factory board, avoid loading the oscillator with
the measurement probe.

| Test | Acceptance evidence |
| --- | --- |
| Unpowered harness and board | Correct polarity; console J25-1 reaches Pi physical pin 11 and screen J2-1; J25-2 reaches GND and J2-2; existing Pi-to-console ribbon remains direct; no Pi VBUS/AUX/output shorts; EVM jumpers and both local EN pulldowns correct. |
| AUX on, GPIO low/released/control lead removed | Both main and touch outputs discharge; screens remain dark with USB and HDMI attached. |
| Pi USB only; AUX only | No unintended panel power from Pi USB; no AUX backfeed at either Pi USB VBUS contact. Test each host port independently. |
| Normal cold boot | Correct EDID/video modes and both touch devices enumerate without reconnecting cables. |
| Repeated enable cycles and USB suspend/resume | Reliable touch re-enumeration and no latched USB error. Hand: verify relay switching and Pi runtime-power policy despite the 21 mA host-coil load. Factory: verify oscillator startup/resume. |
| Both touch devices active during disable | Clean detach and measured discharge complete before HDMI disappears. |
| Orderly Pi shutdown | Save completes, enable drops before video loss, neither panel shows the blue no-signal screen. Capture GPIO, screen rails, and visible behavior together. |
| Hand control harness or `/UFP` wire removed | A disconnected EVM EN remains low from its local 100 kΩ; missing `/UFP` keeps the touch branch off. |
| Main-cable removal at each end | Type-C detach disables touch; separately record the C-to-Micro-B case where removing only Micro-B leaves Rd attached and touch may remain on. |
| USB host unplug/replug; AUX cycle with Pi alive | Correct detach/re-enumeration, no Pi back-power or disturbance of the other USB channel. |
| HDMI attached while both switched supplies are off | No visible display sustained by HDMI power. |
| Maximum brightness plus other AUX loads | Total supply, contact and cable currents, panel voltages, and temperatures remain within verified limits. |
| Controlled output fault and internally shared panel rails | Protection and wiring tolerate both feed paths. Hand: verify fuse opening time, inrush, and discharge with cartridge removed. Factory: verify limiter behavior. Neither branch protection alone covers reverse-fed cable current. |
| Mechanical assembly | Carrier, separate EVMs, standoffs, plugs, cable bend radii, and service access fit the enclosure. |

## Reproduce and validate

Use KiCad 10.0.4 with its matching symbols/footprints, SKiDL 2.3.0 under Python
3.12, Java, and Freerouting 1.9.0. Run these commands from this directory:

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
bash build.sh all
```

`build.sh` accepts `hand` or `factory` to rebuild just that variant. It generates
native schematics and netlists, places parts, routes critical circuits explicitly,
reserves both ground planes, routes the remaining signals, and requires clean
checks before exporting. Rebuilding replaces that variant's generated CAD files.
KiCad and Freerouting paths default to the documented macOS installation layout;
set `KICAD_PYTHON`, `KICAD_CLI`, `SKIDL_PYTHON`, and `FREEROUTING_JAR` to use
other installations. `KICAD_SYMBOL_DIR`, `KICAD_FOOTPRINT_DIR`, and
`KICAD10_3DMODEL_DIR` select matching library directories.

The corrected through-hole carrier and factory board both pass native
schematic/netlist/PCB parity and all electrical and routing checks. The hand
USB pairs have at most 0.719 mm external trace skew; the factory pairs have
at most 1.536 mm. Console J25 is physically connected to Pi GPIO17 and ground.
Physical USB behavior and impedance remain separate bench/fabricator checks.

To verify the existing routed files without regenerating the layout:

```sh
"$KICAD_PYTHON" check.py all --self-test --output validation.json
"$KICAD_PYTHON" export.py hand
"$KICAD_PYTHON" export.py factory
```

Set `KICAD_PYTHON` to the Python executable bundled with KiCad, or one that can
import the matching `pcbnew`. The verification checks all native ERC/DRC
severities, missing connections, circuit-to-schematic-to-pad parity, USB copper
continuity/polarity/width/skew, ground planes, and control/power contracts.
The self-check deliberately bridges host power, cuts USB copper, and cuts
the console control route. For the hand board it also injects an SMD
footprint and an SMD pad hidden inside a through-hole footprint. Every
injected fault must be rejected.

Each ignored `fabrication/` directory contains Gerbers/drills and a ZIP,
schematic and assembly PDFs, placement CSVs, BOMs, STEP,
board renders, a fresh validation report, and a SHA-256 manifest. Exports reject
source changes during generation. KiCad's available STEP models do not cover
every part: connectors and the RF relay may be absent. Use the footprint
courtyards and manufacturer drawings for these parts; STEP is not a complete
enclosure-fit model. Board fabrication still requires the stackup/impedance and
physical acceptance gates above.

## KiCad library attribution

Symbols and footprints originate from the KiCad library community. The local
`USB_B_Host` symbol is derived from KiCad `Connector:USB_B`, with its ground pin
changed to passive for ERC. Generated schematic caches also contain KiCad
symbols. The local Lumberg 2411 06 footprint derives from KiCad's
`USB_B_Lumberg_2411_02_Horizontal`: signal-pad centers are retained, shell-pad
centers and signal drills follow the 2411 06 drawing, body/courtyard outlines
are updated, and the obsolete connector's STEP reference is removed.
The hand RF relay symbol and footprint follow Omron's G6K-2P-RF terminal
and PCB-hole drawings, with bottom-view numbering converted to the PCB top view.
Source: [KiCad symbols](https://gitlab.com/kicad/libraries/kicad-symbols)
and [KiCad footprints](https://gitlab.com/kicad/libraries/kicad-footprints).
The library material is licensed under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) with the
[KiCad libraries exception](https://www.kicad.org/libraries/license/).
Retain those terms and attribution when redistributing library collections;
the exception permits their use in electronic designs and generated design
files. Manufacturer data sheets are reference sources, not copied library CAD.
