<!-- cspell:words floorplan pulldowns Axicom -->
<!-- cspell:words backfeed pulldown -->
# Screen power and touch board — #1072

Issue: https://github.com/tomassasovsky/segno/issues/1072

The owner has selected **hand-soldered assembly only** and authorized the
revision E compaction. Revision E keeps the revision D circuit and selected
JST XH data connectors, removes factory-only assembly paths, and reduces the
hand board from 72 × 84 mm to 64 × 76 mm. The existing two-wire control
connection and separate screen power feeds remain. The owner subsequently
requested revision F: 3 mm corner radii, preserving the mounting holes and
all component/copper positions, plus a complete component cost estimate.
The owner then required two copper layers. Revision G uses a 68 × 76 mm
outline to keep a broad edge power rail clear of the USB ground reference,
with purple solder mask and the same through-hole parts.

The APROTII 7-inch display stays lit with only its direct Pi USB touch cable
connected. Both the separate screen feeds and alternate touch power paths
therefore need switching before HDMI stops.

## Accepted design

- One common-source, back-to-back P-channel MOSFET pair switches the existing
  5 V AUX supply for both screens. A source-referenced gate pull-up defaults
  off. A diode isolates the PNP relay-control branch when AUX is absent.
- J103/J203 are fused two-pin 5 V outputs for the existing screen power leads
  or adapters. Preserve any existing USB-C attachment/current-signaling parts;
  this board does not add new USB-C source ports. Final harness connector
  details still need confirmation against the existing installation.
- Each touch channel has a four-pin JST XH host input and display output,
  and a TE/Axicom IM02TS relay opening D+ and D−. Its host VBUS powers only that relay's coil;
  its display VBUS comes from the switched AUX supply through a separate fuse.
- Console J25 connects GPIO17 and ground to J2 with two wires. The existing
  Pi-to-console ribbon stays directly connected. The screen board has no
  40-pin connector or Pi power feed.
- The 68 × 76 mm board has 37 populated through-hole parts plus four M3 holes,
  with no surface-mount parts or modules. Retain soldering access, component
  courtyards, mounting-hole clearance and connector access while shrinking.
- USB inputs face left and outputs face right, with one relay in each path.
  Power switching sits by the input, fuses beside outputs, and control between
  channels. Two layers use filled outer GND pours. USB pairs use bottom copper
  at the through-hole connectors, without data vias, and protected front-side
  ground underneath.

The [assembly guide](../../hardware/kicad/screen_power/README.md) is the exact
source for pin maps, manufacturer parts, current/gate margins, fuse limitations,
stackup, assembly and physical acceptance. The circuit source and floorplan remain separate.

## Implementation and verification

1. Verify exact component pinouts, gate-drive conditions and land patterns.
2. Generate the native schematic, netlist and BOM; preserve console J25.
3. Place connector anchors and functional groups, then manually route USB
   and high-current paths before routing low-current connections.
4. Require zero native ERC/DRC violations and unconnected items, full circuit
   parity, through-hole-only hand assembly, physical USB/control continuity,
   and sufficiently wide continuous power paths.
5. Exercise broken-copper, undersized-power, inappropriate-component,
   tolerance and weak-pulldown negative controls. Review schematic/PCB drawings
   and run the independent build review roles before refreshing packages.
6. Assemble and measure the actual screen/USB/HDMI behavior, thermal margins,
   inrush, fuse coordination, cable and enclosure fit. Keep the issue at
   `autonomy:blocked-verify` until that evidence exists.

## Success criteria

```success-criteria
GOAL: Deliver a compact hand-soldered PCB design that switches both screen power feeds and prevents Pi touch VBUS from bypassing screen enable.

SUCCESS CRITERIA:
- The native board passes ERC/DRC, component/pad parity and power/USB/control checks, with no SMD pads in the hand assembly. | verify: KiCad-Python hardware/kicad/screen_power/check.py hand --self-test
- Deliberate USB/control cuts, thin power copper, host-power bridges, unsupported drivers/relays, incorrect resistor tolerance and weak pulldowns are detected. | verify: KiCad-Python hardware/kicad/screen_power/check.py hand --self-test
- Both actual touch controllers enumerate and operate reliably after switching, boot, unplugging and suspend/wake. | verify: manual prototype matrix in the assembly guide.
- GPIO low/floating opens touch data and removes screen power; an externally powered screen output cannot feed a dead AUX input while disabled. | verify: manual measure each rail and control pin in the documented supply-loss states.
- Neither touch nor HDMI keeps a display visible after disable, and power is removed before HDMI disappears. | verify: manual capture both screen rails, GPIO and shutdown video on the actual Pi.
- Voltage drop, inrush, temperature and protection remain within actual component and cable limits, including panel-internal joined power inputs. | verify: manual load, startup, fault and hot-enclosure tests.

NON-GOALS:
- New USB-C source ports, USB PD, USB hubs or new power modules.
- Changes to selected bucks or completed ring routing. The subsequent
  pre-order audit authorizes correcting the console ADC power-domain defect
  and component-fit margins as well as J25.
- Claims that CAD proves screen compatibility, USB certification or shutdown timing.

VERIFICATION COMMAND: KiCad-Python hardware/kicad/screen_power/check.py hand --self-test
```

## Current status

Revision H verification is recorded in
[revision H verification](../reviews/screen-power-rev-h-1072/verification.md).
Revision I and the corrected console supersede those packages following
the [completion review](../reviews/pcb-completion-1072/verification.md). Fabrication
remains on hold while cable, power and shutdown behavior are unmeasured. On
2026-09-22 the owner confirmed both screens go fully dark with power/touch USB
disconnected and HDMI retained during the requested Pi-on test. This closes
the HDMI-only visual check, not GPIO cutoff or shutdown timing. No hardware
performance is inferred from CAD checks.

Boot enable and shutdown integration are implemented and locally tested:
GPIO falls after app stop and before HDMI teardown, with a provisional five-second
wait. The implementation has not been deployed; measure actual screen discharge
and validate the assembled system before release. Full results are in the
[completion review](../reviews/pcb-completion-1072/verification.md).


## Authorized completion after the pre-order audit — 22 September 2026

The owner's “fix everything” instruction authorizes the remaining firmware and
appliance implementation, preserving the hardware acceptance gate:

- Replace console v2 ring wiring with the actual v3 PIO UART link and add the
  XIAO RP2350 ring firmware. Preserve rendering, handle loss/reconnection, and
  drive all ten seven-pixel pills without blocking input reception.
- Correct RP2350 E9-sensitive CTRL presence reads. Add bounded, read-only
  STUSB4500 status with unknown voltage explicitly represented; no NVM changes
  or inferred 100 W readiness.
- Hold Pi GPIO17 through a dedicated libgpiod owner. Power screens before Weston
  probes them; lower the GPIO and wait before stopping Weston on halt, reboot,
  update or restart. A five-second discharge wait is provisional until measured.
- Improve the relay's guaranteed pickup margin using a pin-compatible 4.5 V
  part. Preserve the board's placement, routing, two layers and hand assembly.
- Validate native firmware behavior, compile both real board targets, test the
  GPIO service and systemd integration, and run the five build review roles.

Files: firmware console/ring targets and shared library; pedal repository codec
and status; appliance release/build recipes; segno-bundle GPIO helper/unit and
Weston drop-in; screen component definitions, checks, generated artifacts and
assembly/cost documentation. No existing hardware is flashed in this work.
