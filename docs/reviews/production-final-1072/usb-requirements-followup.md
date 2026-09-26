# USB requirements follow-up — 26 September 2026

This review applies to hardware revision `a50de8e375a5649a21b3ad5b744d0849a98f114d`.
**Hold the screen-power PCB order pending correction of the host USB suspend
current.** This supersedes the earlier screen-board order acceptance. Console
and ring fabrication findings are unchanged. No PCB copper or ZIP has changed.

## Verified design defect

Each IM02TS relay coil takes approximately 34 mA from its Pi USB port while
GPIO17 enables the board. `switch_circuit.py` connects K101/K201 pin 1 to
HOST1_5V/HOST2_5V; Q101/Q201 gates use DATA_ENABLE, derived from AUX and GPIO17.
USB bus suspend leaves VBUS present and does not lower this GPIO. The coil
therefore continues drawing current during suspend.

The ordinary USB suspend budget is 2.5 mA. The coil alone exceeds it; correct
operation during active use does not establish compliance. This finding was
independently checked against the current circuit source and native board.
Source: [Microchip USB power rules](https://developerhelp.microchip.com/xwiki/bin/view/applications/usb/power-delivery/battery-charging/),
Summary of Rules. The [USB-IF electrical test specification, v1.08](https://www.usb.org/sites/default/files/USB2%20Electrical%20Compliance%20Specification%20v1.08.pdf)
also requires suspend support in EL_39.

The corrective direction is AUX-powered coils with a separate low-current
VBUS-presence detector for each host port, combined with the existing GPIO
enable. Merely moving the coil wire to AUX would lose the host-absent data
disconnect and is insufficient. The revised circuit, component margins,
default-off behavior, no-backfeed behavior and routing need validation before
new fabrication files are released. This change has not been implemented.

## What the existing layout proves

- Both channels have 23.526702/23.526703 mm upstream D+/D- copper and
  26.178136 mm downstream copper per conductor, including bends. Each mismatch
  is below 0.001 mm. Cable and internal relay paths are excluded.
- All data tracks use B.Cu, 0.85 mm width and no data vias; the coupled sections
  have a 0.16 mm gap. Filled F.Cu ground beneath the routes is checked, with
  documented terminal exclusions. These are useful layout checks, not an
  electrical channel test.
- Nominal differential impedance is calculated at 89.64 ohms. Solder mask,
  finite adjacent copper, connector/relay transitions and manufacturing
  tolerances are not fully modeled. The two-layer order has no controlled
  impedance guarantee.
- Host VBUS has no PCB connection to the screen supply. Data polarity and
  relay contact pin assignments are checked.

## Remaining USB qualification limits

The large screen has a 480 Mbps upstream hub, despite its 12 Mbps touch
controller. The small screen attaches at 12 Mbps. Both speeds must remain
usable through the final assembly.

The [USB cable requirements](https://www.usb.org/sites/default/files/CabConn20.pdf)
include differential impedance of 90 ohms +/-15%, attenuation, delay/skew,
shielding, continuity and mechanical performance. PCB layout recommendations
are separately described by [TI](https://www.ti.com/lit/an/slla414/slla414.pdf).
Matched copper does not qualify the complete connector-relay-cable channel.
No complete-channel eye diagram, loss/reflection characterization or assembled
link test exists. TE relay RF data alone is not a USB qualification.

The selected XH cable seller has not established twisted-pair construction,
shield termination, 480 Mbps performance or the USB-C plug's legacy-source
56 kilohm Rp configuration. A correct pin order and 28 AWG marking do not prove
those properties. USB-C attachment requirements supplement USB 2.0; they are
not fulfilled by the four PCB contacts themselves.

The Pi and screen controllers implement enumeration and USB protocol. The
interposer must preserve attach/detach, reset, speed negotiation and
suspend/resume behavior. Passing CAD DRC does not verify those behaviors,
VBUS transients or complete-system electrical compliance.
