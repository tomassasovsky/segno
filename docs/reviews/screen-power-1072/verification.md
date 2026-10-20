# Screen-power prototype verification

<!-- cspell:words unassembled -->

The completed prototype CAD implements the owner's corrected assembly and
connection requirements: the hand carrier has no surface-mount pads, the
factory board remains separate, and console J25 provides a two-wire GPIO17/GND
connection to either screen board. The existing Pi ribbon stays in place.

## Verified deliverables

| Check | Hand | Factory |
| --- | --- | --- |
| Native electrical and board rules, all reported severities | Zero findings | Zero findings |
| Unconnected items | Zero | Zero |
| Circuit, native schematic and physical pad parity | Pass | Pass |
| USB physical continuity, layer, width and length difference | Pass | Pass |
| Console control copper continuity | Pass | Pass |
| Deliberate USB-power bridge, USB cut and control cut | Rejected | Rejected |
| SMD footprint and disguised SMD pad | Rejected | Not applicable |
| Final export manifest and archive validation | Pass | Pass |

The hand board contains 56 footprints: 167 plated through-hole pads, four
non-plated mounting pads, and zero SMD pads. Its two USB-C source modules are
purchased preassembled. The factory board contains 72 footprints. Both are
130 by 120 mm, with four copper layers and two continuous inner ground planes.

The combined validation completed at 2026-09-22 02:32:45 UTC. Its source and
board hashes are recorded in
[validation.json](../../../hardware/kicad/screen_power/validation.json).
Each subsequently exported package includes its own fresh passing validation
and hashes of all inputs and outputs. Native routed PCB hashes:

| Board | SHA-256 |
| --- | --- |
| Hand | `0362adac5630fb1871472aeded0f62d113e94ccb73a770ef520a6ec007d757b3` |
| Factory | `d047ab2bc52f89caec3ef808c306aa1cff9b533ac3ffef7bfe16c130e9def464` |
| Console with J25 | `d4a735337159ee083228dbfa23bc4f16c329b2a44fe26847d5a04fc99004b360` |

The console change preserves all 65 previous footprints and all 681 previous
tracks/vias. The added connector uses nine tracks and two vias for GPIO17;
ground joins the existing plane. Its rule checks and deliberate-fault tests
pass. See [console evidence](raw/console-control-validation.md).

Final top and bottom board renders were visually inspected for both variants.
Some connectors and hand components have no matching 3D model; the previews
and STEP files are consequently partial mechanical representations. Native
footprints, BOMs and assembly drawings remain the assembly references.

## Independent review and failure paths

The five roles cover architecture, test quality, conventions, simplicity and
PR readiness. Authorship exclusions are explicit in each raw report; a role's
own implementation is covered by another reviewer. See the
[consolidated review](review.md).

Independent temporary regeneration reproduced component records, BOMs,
physical net membership, pad placement at the router's coordinate resolution,
and exact critical USB/clock routing. Additional fault tests exercised relay
pin/coil separation, flyback polarity, attachment-output load, pad drill types,
cleanup geometry and failed package publication. Publication preserves the
previous package across the six tested success/failure cases; it is not a
claim of process-crash consistency or concurrent-export support.

Python parsing, shell syntax and scoped source whitespace checks pass. Native
STEP/netlist output contains exporter-generated whitespace, and CSV files use
standard CRLF line endings; these formats were retained as emitted. The complete
repository Markdown spelling check passed for 354 files, and the subsequently
added consolidated review passed separately. No Dart, Flutter, audio-engine or
firmware implementation changed.

## Remaining acceptance

These are unassembled prototypes. CAD validation does not establish actual
USB operation, HDMI residual-power behavior, panel inrush, fuse response,
temperatures, relay life, impedance or enclosure fit. The hand relay coil's
host-current draw also needs appliance suspend/resume validation. GPIO startup
and shutdown sequencing is specified but not implemented. The full physical
acceptance matrix is in the
[assembly guide](../../../hardware/kicad/screen_power/README.md).

Issue #1072 remains `autonomy:blocked-verify`. No production readiness,
remote CI, current-head PR merge gate or completed bench test is claimed.
