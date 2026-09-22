# Console screen-control implementation validation

This records author validation, not an independent review or hardware approval.

The console adds J25, a two-pin JST XH B2B-XH-A vertical header. Pin 1 is
`PI_GPIO17`, connected only to physical pin 11 of the existing J2 Pi ribbon.
Pin 2 is GND. The existing ribbon still connects the Pi and console directly;
the screen-power board receives a separate two-wire control cable.

J25 is centered at board-local (68, 69) mm, rotation 0 degrees. With the console
origin at (100, 60) mm, pad 1 is at (166.75, 129) mm and pad 2 at (169.25, 129) mm.
Its function and numbered pinout are printed on the back. The C7 reference,
J6 reference, and RING label move to the positions selected by the layout
generator to make the new header and both functions clear.

## Preserved geometry and connections

- All 65 original footprints retain their exact position and orientation.
- Every original pad retains its number and position. The only original pad
  connection change is J2 pin 11, previously unused, becoming `PI_GPIO17`.
- All 681 original tracks and vias retain their UUID, net, layer, endpoints,
  width, and drill dimensions exactly.
- The added route has nine 0.6 mm segments, totaling 48.523506 mm, and two
  0.8 mm diameter / 0.4 mm drill vias. Existing ground pours connect J25 pin 2.
- The generated netlist adds only J25, its ground pin, and the GPIO17 pair.
  Every previous component and net membership is otherwise unchanged. Pi
  supply pins 2 and 4 remain unused. The ring-board files are unchanged.

## Observed checks

- SKiDL electrical checks: zero errors or warnings.
- Circuit gates and all 19 negative controls pass, including moving screen
  enable to the wrong physical Pi pin.
- Layout gates and all 11 existing negative controls pass.
- Routed-board fabrication and netlist/pad checks pass.
- Fresh KiCad 10.0.4 DRC: zero violations and zero unconnected items.
- Python compilation and Git whitespace checks pass.
- Both edited console Markdown documents pass the repository spelling check.
- Top and bottom renders were visually inspected for connector clearance and
  readable pin identification.

The validated routed-board SHA-256 is
`d4a735337159ee083228dbfa23bc4f16c329b2a44fe26847d5a04fc99004b360`.

## Updated deliverables

The circuit and layout generators, console netlist, placed and routed PCB,
console BOM, DRC report, nine Gerber layers, two drill files, Gerber job, STEP
model, and current 12-file manufacturing archive were refreshed. The wiring
reference and console soldering guide describe J25. Historical manufactured
archives were preserved. Manufacturing and installed-device validation remain
outside these CAD checks.
