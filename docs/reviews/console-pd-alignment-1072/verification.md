# Console PD connector alignment — issue #1072

PD J23 moved 0.8 mm down to align with RING J6 and screen-control J25.
All three connector pad rows are now at board-local Y = 69.0 mm, with the
same orientation. The placement generator and both placed/routed KiCad boards
carry this correction. The PD label and its J23 reference move with it.

The SDA and SCL terminal segments extend to the relocated pads, and the
ground stub and its via move with the ground pad. Two adjacent STOP/UNDO
traces take short 45-degree detours around the moved SCL pad. They retain
their original 0.6 mm widths and layers; no extra vias are introduced.
No other component, connector, mounting hole or circuit connection changes.

## Observed checks

- The generator's full placement/label checks pass. Actual saved-board
  footprint spacing and routed fabrication checks pass.
- Native KiCad 10.0.4 DRC passes with zero violations and zero unconnected
  items after refilling the planes, on both the source and packaged boards.
- Source netlist and routed pad assignments remain identical. The screen
  board's full CAD checks also pass against the updated console, including
  the physical GPIO17 route and the matching J25/J2 pin map.
- The component/BOM records and all other footprint positions are unchanged;
  [validation](validation.json) records the exact geometry and copper changes.
- Python compilation, documentation spelling and scoped whitespace checks pass.
- Author top/bottom render inspection confirms the common connector row and
  clear PD label. Native Gerbers/drills and the STEP assembly are refreshed.

The full placement-only gate, when additionally applied to a saved routed
board, reports the same existing R18/J25 label assertion before and after
this change. This is separate from the passing generator check, actual
footprint-spacing check and native KiCad silkscreen rules; no passing result
is claimed for that extra saved-board label check.

The new console package supersedes the earlier console-with-screen-control
package. Its PCB model paths point to the 15 bundled model files; this is the
only difference between the source and packaged PCB. The screen revision F
PCB and ring board are unchanged. Existing hardware and Pi shutdown
qualification requirements remain open.
