# Screen power revision H: consistent connector orientation

Issue: #1072. All eight cable headers now use 90-degree placement, vertical
pin rows and pin 1 at the bottom in the component-side view. The keyed
retaining walls face left. Native KiCad models confirm the housing direction
for both JST XH and JST VH. All are top-entry connectors.

J1, J2, J103 and J203 rotate to match the four USB headers. The control and
Pi headers share x = 7 mm; AUX and screen headers share x = 56 mm. The four
fuses move 2 mm left for the wider rotated VH housings. R1, R2 and R3 move
0.25 mm right for control-header assembly clearance. Input and main-output
power traces are rerouted at their existing widths. Ground stitching moves
clear of the shifted fuse pads, and a local stitch joins the control ground
pocket. Existing labels are spaced clear of pads and one another.

The two-layer, 68 × 76 mm board, R3 corners, purple mask, 37 through-hole
components, circuit, purchased connector families and numbered pin maps
remain unchanged. Both copper faces retain filled ground pours. The USB
track geometry is exactly preserved from revision G, and the console PCB
is unchanged. See [connector-orientation.json](connector-orientation.json)
for measured pad positions and the checked board hash.

Validation: native ERC/DRC, schematic/netlist/PCB parity, continuous power
width, USB connectivity and grounded reference beneath the data traces,
all component models and 18 fault-injection checks. There are zero DRC
violations and zero unconnected items. The final render was inspected for
housing direction and label clearance. See [validation.json](validation.json).

This package supersedes revision G. Physical USB, thermal, wiring and shutdown
tests remain pending as documented in the assembly guide; this orientation
change does not establish those results.
