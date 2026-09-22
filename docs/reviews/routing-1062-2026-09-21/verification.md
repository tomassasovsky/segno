# PCB routing verification — 2026-09-21

Scope: complete the console and ring power-rail routing for #1062 / PR #1066.
Starting revision: `89eb3ed16a44c8c452fd867bc1a6ab4b121ffc8a`.

The unfinished local console reroute had two missing connections. Its component
and pad geometry matched the committed layout, so the completed committed
tracks and vias were retained and the power rail widened. The ring's local
power-rail widening was retained and verified. Relative to the starting commit,
the only track changes are widths: all 42 console `+5V` segments are 0.70 mm,
and all 22 ring `+5V_LED` segments are 0.65 mm. Their routes, vias, component
positions and pad/net assignments are unchanged. Copper zones were refilled.

| Check | Console | Ring |
| --- | --- | --- |
| KiCad 10.0.4 DRC, all severities, filled zones | 0 violations, 0 unconnected | 0 violations, 0 unconnected |
| Exact circuit netlist parity | 202 pins; no missing, extra or mismatched pins | 63 pins; no missing, extra or mismatched pins |
| Manufacturing files | 12 files; ZIP matches tracked loose exports | 10 files; ZIP integrity verified |
| Actual power rail width | 0.70 mm | 0.65 mm |
| Top and bottom 3D views | Inspected | Inspected |

Existing circuit self-tests, console placement self-tests, routed console fab
checks and power-width self-tests pass. Independent DRC repeats on the saved
final boards also pass. The unchanged STEP models retain identical populated
geometry: copper widths are not included in those mechanical exports.

The routing scripts were not run as a full rip-up/re-route: that would discard
completed routing. Completion used the existing routes, widened the console
rail, refilled both boards, ran the final checks, then exported new CAM files.

Delivery archives:

- `hardware/kicad/out_console/segno_console_board_gerbers.zip`:
  `ac6084fd5ed795a7151a52ff8650a85c350ace9ef387f4b5cdf19c83482aeaed`
- `hardware/kicad/fab/segno_pedal_ring_gerbers.zip`:
  `d8902e46c96576eb7294d9281375e564a27fcf082a2242ada464bccf31e956d5`

Both boards retain 2 layers, 1.6 mm FR-4, 1 oz copper, purple solder mask and
white silkscreen. The dated delivery folder includes board views, DRC reports
and archive checksums. These replace the prior order-file revisions; no files
were added to `fab/manufactured`, because no order was placed.

These checks establish routing and file consistency. Full-load voltage/thermal
measurements, physical assembly fit and v3 firmware validation remain open.
The PR retains `autonomy:blocked-verify` and is not merged. Screen power
switching is a separate proposed follow-up in the
[screen power brainstorm](../../brainstorm/2026-09-21-screen-power-switching-brainstorm-doc.md).
