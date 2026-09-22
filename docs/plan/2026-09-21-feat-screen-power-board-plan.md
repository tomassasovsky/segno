<!-- cspell:words floorplan pulldowns -->
<!-- cspell:words backfeed pulldown -->
# Screen power and touch board — #1072

Issue: https://github.com/tomassasovsky/segno/issues/1072

The owner approved both hand-soldered and factory-assembled versions, then
rejected the external USB-C source modules, the extra ribbon connection and
inefficient placement. **Revision B below replaces the earlier circuit plan.**

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
- Each touch channel has a USB-B host input, a USB-A display output, and an
  RF relay opening D+ and D−. Its host VBUS powers only that relay's coil;
  its display VBUS comes from the switched AUX supply through a separate fuse.
- Console J25 connects GPIO17 and ground to J2 with two wires. The existing
  Pi-to-console ribbon stays directly connected. The screen board has no
  40-pin connector or Pi power feed.
- Both variants use the same electrical topology. The 72 × 84 mm hand board
  has 41 through-hole components including holes, with no SMD parts or modules.
  The 72 × 74 mm factory board uses suitable SMD equivalents while retaining
  through-hole connectors, relays, fuses and bulk capacitors.
- USB inputs face left and outputs face right, with one relay in each path.
  Power switching sits by the input, fuses beside outputs, and control between
  channels. Four layers retain two continuous inner ground planes. USB pairs
  use bottom copper at the through-hole connectors, without data vias.

The [assembly guide](../../hardware/kicad/screen_power/README.md) is the exact
source for pin maps, manufacturer parts, current/gate margins, fuse limitations,
stackup, assembly and physical acceptance. Both board versions share the
circuit source; variant placement lives in one floorplan module.

## Implementation and verification

1. Verify exact component pinouts, gate-drive conditions and land patterns.
2. Generate both native schematics, netlists and BOMs; preserve console J25.
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
GOAL: Deliver compact hand and factory PCB designs that switch both screen power feeds and prevent Pi touch VBUS from bypassing screen enable.

SUCCESS CRITERIA:
- Both native boards pass ERC/DRC, component/pad parity and power/USB/control checks, with no SMD pads in the hand assembly. | verify: KiCad-Python hardware/kicad/screen_power/check.py all --self-test
- Deliberate USB/control cuts, thin power copper, host-power bridges, unsupported drivers/relays, incorrect resistor tolerance and weak pulldowns are detected. | verify: KiCad-Python hardware/kicad/screen_power/check.py all --self-test
- Both actual touch controllers enumerate and operate reliably after switching, boot, unplugging and suspend/wake. | verify: manual prototype matrix in the assembly guide.
- GPIO low/floating opens touch data and removes screen power; an externally powered screen output cannot feed a dead AUX input while disabled. | verify: manual measure each rail and control pin in the documented supply-loss states.
- Neither touch nor HDMI keeps a display visible after disable, and power is removed before HDMI disappears. | verify: manual capture both screen rails, GPIO and shutdown video on the actual Pi.
- Voltage drop, inrush, temperature and protection remain within actual component and cable limits, including panel-internal joined power inputs. | verify: manual load, startup, fault and hot-enclosure tests.

NON-GOALS:
- New USB-C source ports, USB PD, USB hubs or new power modules.
- Changes to selected bucks, completed ring routing or existing console circuitry beyond J25.
- Claims that CAD proves screen compatibility, USB certification or shutdown timing.

VERIFICATION COMMAND: KiCad-Python hardware/kicad/screen_power/check.py all --self-test
```

## Current status

Revision B passes native ERC/DRC and connectivity checks locally. Review and
export evidence is recorded in
[revision B verification](../reviews/screen-power-layout-1072/verification.md).
The earlier revision A packages are superseded. No hardware performance is
inferred from the CAD checks.

Early-boot enable and shutdown integration remain a subsequent device step:
disable GPIO after save/goodbye and before HDMI teardown, allowing the measured
screen discharge time. Final-halt control alone is too late for the stated goal.
