# Publication review

Review date: 2026-09-25. Base: `bedcecf2733dbde1cdddf96530e5c1749a72b710`.
Implementation head: `b1070880bff3c42ccbbbcfd1fc31c9b0f957701f`.

The accompanying SHA-256 manifest pins every published hardware source and
artifact. This report, its check results and a firmware handoff clarification are a
documentation-only follow-up;
the final PR head is attested separately after that commit. No older prototype
review is treated as review of this publication.

## Review coverage

The author read all new source and instructions, traced generated outputs
against their inputs, and checked line-by-line behavior, removed behavior,
cross-file interfaces, reuse, simplicity, efficiency, fix depth and project
conventions. A separate reviewer completed the full scope independently.
No reviewer failed or remained outstanding. No actionable findings remain.

The independent review traced all optical, encoder, screw, wire and removal
interfaces and checked the print orientations, supports and packaging. Both
historical PCB/STEP hashes and encoder blobs match their pinned revisions.
All ten retained solids in each normalized PCB reference match the translated
historical export with zero geometric subtraction differences. The thirteen
omitted solids are tiny lettering only. Both previews agree with the source
and colour guide and were inspected by the author and independent reviewer.

## Validation

The complete geometry checker passed; see `geometry-results.txt`. It checked
all eight solids and closed, bed-oriented meshes, the 65-body assembly, both
smaller passive PCBs, optical clearances, cap and base hold-down, flat bearing
webs, blind pilots, screw clearances, nut/tool access, push envelope and
continuous board withdrawal. Negative controls reject the old obstructed
LED height, recessed knob, missing posts, thin web and open-ended pilot.
The regenerated print pack has 20 members, valid CRC and byte-for-byte
agreement with the current source files. Python syntax, whitespace and scoped
Markdown spelling checks passed. CAD checks used CadQuery 2.8.0, NumPy 2.4.6,
SciPy 1.18.0, Matplotlib 3.11.0 and VTK 9.6.2 in the existing CAD environment.

## Limits and preserved work

Actual screw-head height, printed-thread retention, knob grip and push travel,
strip dimensions/bend/adhesion, solder/wires, opacity and optical performance
remain unverified. The 8 mm shaft insertion is a gross envelope, not measured
D-bore engagement. These remain #1075 `autonomy:blocked-verify` gates.

Earlier ring revisions and printer-specific projects are preserved locally.
The #1063 Ring24 flush-lens work describes the production sheet-metal stack,
which this standalone strip enclosure does not replace. The old ring-lens
worktree's uncommitted seven-LED pill/deeper-rail trial is superseded by the
later eight-LED solid-bed design and excluded. No firmware, PCB, production
metal or Fusion files changed. Firmware publication owns the 40-pixel mapping.
