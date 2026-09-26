# #1033 The Pedals setup map draws a rounded rectangle where the design has a footswitch [open]

The Pedals setup map (part 4c, PR #1028) draws each footswitch as a rounded rectangle with a pad block and a nameplate block. The accepted design draws the real switch: `Hardware / Segno pedal face` in `segno-ui.pen` is a tapered metal body under a four-stop gradient, two side hinges, left and right rolled edges, a textured rubber pad carrying thirty round grips, a trapezoid nameplate and a raised label.

The faceplate simulator (`lib/pedal/view/pedal_plate.dart`) draws its switches the same simplified way, so nothing in the app shows the hardware shape.

## Why it happened

Two things, both worth writing down.

The pencil MCP elides every path's `geometry` as `"..."`, even for a single node, so the pen's outlines cannot be read through it. That was never said out loud; the simplification was made and recorded only in a source comment on `PedalSetupCap`, which is exactly what the "a shipped departure from the pen is a design change, write it back into the pen" rule exists to prevent.

And the art was in the repository the whole time. `docs/design/pedal-hardware-widget.js` builds the same face parametrically — the body, pad, hinge, edge and nameplate outlines as path constants, thirty grips on a 6 by 5 grid at `x = 42 + (col - 2) * 11.6373`, `y = 39.47 + row * 12`, and a selected variant that brightens the metal and its stroke. `docs/design/pedal-hardware/README.md` names it and points at the Pen counterpart. Neither was read during 4c.

## Scope

- Port the face to a painter in the app: body and gradient, hinges, rolled edges, rubber pad, thirty grips, nameplate, and the selected and disabled variants the study already models.
- Draw it in `PedalSetupCap` in place of the current blocks.
- Keep the legend as app text rather than the manufacturing ink outlines in `docs/design/pedal-hardware/labels.json`. Those exist for TRACK1 through TRACK4 only, because that is what the silkscreen carries; the map names the channel the active bank drives, which on bank B reads TRACK 5 through TRACK 8. The useful affordance wins over the exact ink.
- No new dependency. The six face outlines are short enough to transcribe directly into `Path` calls, and the grips are circles.

## Not in scope

The faceplate simulator. It has its own millimetre geometry from the enclosure model and its own reasons; moving it onto the same painter is worth doing but is not this change.

Follow-up to #1026.
