# Screen-power USB correction — Revision M

**In progress: screen-board ordering remains on hold.** The console and ring
native boards are outside this change. Existing screen archives contain the
previous host-powered coil circuit and must not be ordered.

The source now powers each relay coil from AUX and uses two series switches
to require both GPIO enable and that channel's host VBUS. Four bare solder
pads support separate cable shield drains while retaining the XH4 connectors.
The PCB remains two-layer and hand-soldered, with its existing outline,
mounting holes and cable anchors.

The regenerated schematic has zero KiCad ERC violations. Source contracts,
48 ideal switching states and 13 new USB fault controls pass. Native placement,
routing, complete validation and updated manufacturing exports are pending.
No current native-board release is claimed by these source checks.

- [Circuit assessment and margins](circuit-assessment.md)
- [Cable construction, pin maps and optional donors](cable-assessment.md)
- [Coated-field impedance assessment](impedance-assessment.md)
- [Component costs](../../../hardware/kicad/screen_power/COSTS.md)

The accepted USB geometry target is 0.78 mm width / 0.23 mm gap at the
existing 1.01 mm center pitch. Claude's cloud placement/routing pass will
apply it while retaining paired paths, smooth bends and front-side ground
returns. The two-layer fabrication service does not guarantee impedance;
calculations do not replace assembled operation or full USB qualification.
