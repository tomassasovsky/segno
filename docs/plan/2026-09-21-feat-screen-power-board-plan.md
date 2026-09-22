<!-- cspell:words PGOOD autorouting deassert unassembled EDID Omron Littelfuse IRLZ NPBF RVCR WQFN -->

# Screen power and touch board — #1072

Issue: https://github.com/tomassasovsky/segno/issues/1072

The owner approved an additional PCB and requested both a through-hole hand
version and a factory-assembled version. The APROTII 7-inch display has separate
micro-USB power and touch inputs and remains lit with only its touch cable
connected to a Pi USB 2.0 port. The UPERFECT main display uses separate USB-C
power and touch inputs. Both touch paths therefore belong in this design.

## Circuit and interfaces

Both variants use two TPS25810 5 V USB-C source channels fed by a dedicated
BUCK_AUX branch. Each port supports native attachment detection and 3 A
advertisement. USB-B inputs take ordinary Pi A-to-B cables, USB-A outputs
serve touch, and the separate power cables are C-to-C for UPERFECT and
C-to-Micro-B for APROTII. No hub is added. Grounds remain common through the
board and HDMI; the complete instrument is not galvanically isolated.

### Through-hole hand version

Every component the user fits to the carrier is through-hole. Two separately
mounted, preassembled TI TPS25810EVM-745 modules provide main power. Their
jumper settings, secure harnesses, and mandatory 100 kΩ EN pull-down resistors
on the modules are specified in the assembly guide. No EVM dimensions or
mounting holes are inferred.

Each channel uses an Omron G6K-2P-RF DC5 RF relay for both USB data wires and
an Omron G5LE-1 DC5 relay for touch power. The RF coil takes only its own Pi
USB VBUS, so missing host power opens the data contacts. The power coil takes
AUX. Separate 2N7000 and IRLZ44NPBF low-side drivers share a 2N3906 attachment
detector controlled by the module's active-low `/UFP`. A missing attachment
lead leaves both drivers off. Host and AUX coil supplies never join.

Touch power passes through an Eaton BK/GMA-800-R 800 mA cartridge and the
power relay's normally open contact. Each fuse position uses two Littelfuse
01110501Z through-hole clips. This fuse provides overload protection, not a
500 mA electronic current limit: it can take two minutes to open at 1.6 A.
The normally closed contact discharges touch through 100 Ω / 1 W independently
of the cartridge. Each main rail has a separate 2N7000 and 100 Ω / 1 W
controlled discharge path. There are no ADuM devices, crystals, or surface-mount
ESD arrays on this carrier.

Omron's 1 GHz RF data supports investigating 480 Mbit/s USB transmission but
does not prove USB compliance. Validate both actual touch controllers and
any internal hub. Each energized data coil draws about 21 mA from its host,
above the generic USB suspend allowance. This is a fixed-appliance design;
verify Pi runtime-power settings and suspend/resume instead of claiming a
certified general-purpose USB adapter. Source links and exact part references
are in the [assembly guide](../../hardware/kicad/screen_power/README.md).

### Factory version

The integrated factory board uses TPS25810RVCR controllers and USB-C
receptacles. Each `/UFP` signal drives SN74LVC1G14 and a TPS25221 touch limiter,
also supplied by AUX. Its output powers downstream ADuM3165B VBUS2 and touch
VBUS. Pi USB VBUS supplies only the upstream isolator. Controller disable
releases `/UFP` and turns off the downstream domain. ADuM PGOOD is unused.

Calculated touch-branch limits are 604–752 mA, allowing 500 mA for touch plus
69 mA worst-case downstream isolator consumption. Both isolators use
ABM8-24.000MHZ-10-B1U-T crystals and 8 pF load capacitors. Assembly requires
surface-mount work, including WQFN thermal pads. Startup and resume need
physical verification.

### Shared limits

A panel joining its two inputs internally can bypass either variant's
individual branch protection through the other cable. The factory's calculated
combined limiting envelope is up to 4.39 A per panel; this number does not
apply to the hand board's fuse. Verify the complete harness, fault response,
and upstream protection. Retain the existing 10 A AUX supply budget.

Main-port attachment normally gates touch, but removing only the Micro-B end
of a C-to-Micro-B cable can leave its C-plug Rd attached and touch powered.
Test disconnection at both ends. The GPIO shutdown command remains necessary.

Keep the existing Pi-to-console 40-pin ribbon unchanged. Add console J25, a
keyed JST B2B-XH-A(LF)(SN) two-pin header: pin 1 is GPIO17 from Pi physical
pin 11, and pin 2 is ground. Connect it to matching screen-board J2 with one
22 AWG two-wire lead, numbered pins 1:1. The selected hand or factory board
uses two XHP-2 housings and four SXH-001T-P0.6 contacts for this one lead.
There are no 40-pin headers on the screen board and no Pi power connection
to AUX. Its series resistor and pull-down resistor make DISPLAY_ENABLE active
high and default off if the control lead is absent. The console revision is
limited to this control connector and its routing; its existing ribbon
connection remains in place.

Four-layer boards provide an uninterrupted ground reference for the USB pairs.
Power copper and USB pairs are routed deliberately before any low-priority
autorouting. Manufacturing notes specify the intended 90-ohm differential
impedance and require the fabricator to confirm its stackup.

## Implementation order

1. Verify manufacturer pin maps, recommended circuits and package land patterns.
   Record sources and exact orderable parts in `hardware/kicad/screen_power/`.
2. Add the console J25 control output and regenerate its circuit/netlist/BOM.
   Generate both screen-board circuits, native KiCad schematics, netlists and
   BOMs. Verify GPIO17/GND polarity across console J25 and screen J2,
   power-domain separation, and fail-off connections.
3. Place and route both screen-board variants and the bounded console change;
   check connectivity and all reported DRC items.
   Inspect schematics and board renders; export Gerbers, drills, exact-part BOMs,
   component-position files and assembly drawings for the applicable parts.
4. Document EVM jumpers, relay/fuse assembly, cable wiring, protection limits,
   and the software timing contract. The service must deassert the GPIO after
   save/goodbye and before
   display teardown. Neither Pi USB VBUS nor final-halt gpio-poweroff is the
   control signal. Device software deployment is a subsequent integration step.
5. Run independent design/review roles; resolve findings, record results and
   leave the issue at `autonomy:blocked-verify` until physical checks pass.

## Success Criteria

```success-criteria
GOAL: Deliver both buildable screen-power PCB designs with USB touch power unable to bypass the screen enable signal.

SUCCESS CRITERIA:
- The hand carrier contains only through-hole components; both variants have native schematics, PCBs, BOMs and fabrication exports with matching component/pad connectivity and no reported DRC violations or unconnected pads. | verify: KiCad-Python hardware/kicad/screen_power/check.py all --self-test
- Pi VBUS, AUX input and each switched output remain separate; console J25 and screen J2 carry GPIO17 on pin 1 and GND on pin 2; both enables default low with the control lead absent. | verify: KiCad-Python hardware/kicad/screen_power/check.py all --self-test
- Both screens and touch controllers turn on reliably and enumerate after repeated switching, including boot and reboot. | verify: manual assemble a prototype, connect both specified panels, and repeat the documented boot/switch matrix.
- Missing control or attachment leads leave touch disabled; missing host VBUS opens the hand data relay; supply removal causes no Pi back-power. | verify: manual disconnect each harness and supply separately, including the documented case where removing only the Micro-B end leaves its C plug attached.
- Neither touch nor HDMI sustains a visible screen after disable, and shutdown shows no blue screen. | verify: manual capture the screen rails, GPIO and display shutdown together on the actual Pi and panels.
- Current, connector voltage and temperature remain within the recorded component and cable limits. | verify: manual test both displays at maximum brightness with other approved AUX loads; measure hand-fuse fault response and confirm the NC discharge path still works without its cartridge.

NON-GOALS:
- Changing the already selected bucks, ring PCB routing, or console circuitry beyond the GPIO17/GND control connector and its routing.
- Adding a USB hub or changing HDMI signal routing without evidence it is needed.
- Claiming an unassembled design proves shutdown timing, display compatibility or enclosure fit.

VERIFICATION COMMAND: KiCad-Python hardware/kicad/screen_power/check.py all --self-test
```

## Validation status

Both corrected screen boards pass fresh native ERC/DRC with zero findings
and unconnected items, matching native schematic/netlist/PCB connectivity,
and successful fault-injection checks. The hand carrier has 56 components
with no surface-mount pads. Console J25 preserves all existing routes and its
GPIO17 copper continuity is checked. Physical acceptance remains pending;
earlier packages are superseded by the corrected through-hole/two-wire outputs.

## Remaining physical risks

The 10 A AUX buck's combined screen/LED budget was already tight. Measure
voltage drop and total draw including the hand relay coils or factory USB
isolators. Neither branch protection covers every panel-internal reverse feed.
HDMI +5 V remains connected and must be tested for visible panel back-power.
The Pi must enable screens early enough for EDID/touch discovery and disable
them before losing video. Board placement, plugs, and separately mounted hand
modules require enclosure measurements. USB touch behavior, relay switching,
factory oscillator startup, and the hand host-coil suspend load need device
validation; no USB compliance or successful shutdown is claimed from CAD.
