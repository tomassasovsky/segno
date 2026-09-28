# Console PI PWR placement — issue #1072

PI PWR J9 now sits immediately to the left of the Pi ribbon J2, on the
same Y = 69 mm connector row as PD J23, RING J6 and screen-control J25.
The rear-panel PWR BTN connector J8 stays in its original position.
The board outline, holes, connector types and circuit are unchanged.

R2 lies horizontally below U1 to make room for J9. R18 moves 0.15 mm left
to clear the existing PI PWR label. Existing reference labels were repositioned
to clear the new layout; no label text was added. The generator and saved
board now both pass the placement and label checks, including the earlier
R18/J25 and R22/RING label clearance assertions.

The two floating button nets still connect J8 pin 1 to J9 pin 1 and J8 pin 2
to J9 pin 2. Neither joins console ground. Each uses two 0.8/0.4 mm vias and
0.4 mm copper; the route lengths are 128.20 and 159.69 mm. These slow button
signals cross the board so the Pi harness can leave beside the ribbon.
The placement budget accounts for that requested connector position; the
42 mm hop limit remains unchanged for the other locally constrained signals.

The indicator buffer/output and two receive UART nets were rerouted around
R2. Their 0.4 mm traces carry logic signals. All power copper, the screen
control route and all other signal copper preserve their previous geometry.
One ground stitching via beneath the new R2 pad was removed before refilling
both ground pours. All other component positions are unchanged from the
PD-aligned board. Native object identifiers are not used to establish copper
preservation; the comparison checks net, layer, endpoints, width and count.

Validation of the saved source PCB and portable package:

- Full-severity KiCad DRC: zero violations and zero unconnected items.
- Complete connected-pad/net parity with the console netlist; unused pads
  remain unconnected.
- Generator and saved-board placement, label and fabrication checks pass.
- Floating button wiring and unchanged J8/J2 positions verified numerically.
- PD, RING, SCREEN and PI PWR connector-row alignment verified numerically.
- Screen revision F CAD checks and all 16 deliberate-fault checks pass against
  this console PCB, including the GPIO17 interface.
- Native top and bottom renders inspected with every component model present.
- Portable native copy differs only in bundled model paths. Gerbers, drills,
  STEP, assembly PDF, BOM and package hashes regenerated from this revision.

The ring's J6 and J1 JST XH connectors are rated **3 A with 22 AWG wire**.
Use 22 AWG +5V and GND leads with SXH-001T-P0.6 contacts. The conservative
24-LED full-white budget is **1.44 A**, plus controller consumption, so one
ring fits the connector rating. This is a design calculation, not a measured
load. A second ring requires revisiting the connectors and copper.
Source: [JST XH datasheet](https://www.jst-mfg.com/product/pdf/eng/eXH.pdf).

The assembly remains an untested prototype. Physical fit, voltage drop,
temperature and the screen-board qualification checks remain pending.
Shutdown-before-HDMI software has not been implemented by this layout change.
