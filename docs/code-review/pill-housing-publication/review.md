# Publication review

Review date: 2026-09-25. Base: `bedcecf2733dbde1cdddf96530e5c1749a72b710`.
Implementation head: `1e0dcda4768ff60e84fe33c7560cbba5ac7bc8e4`.

The accompanying SHA-256 manifest pins every published hardware source and
artifact. This report and its check results are an evidence-only follow-up;
the final PR head is attested separately after that commit. No older prototype
review is treated as review of this publication.

## Review coverage

The author read all new source and instructions, traced generated outputs
against their inputs, and checked line-by-line behavior, removed behavior,
cross-file interfaces, reuse, simplicity, efficiency, fix depth and project
conventions. A separate reviewer completed the full scope independently.
No reviewer failed or remained outstanding. No actionable findings remain.

The independent review covered both model generators and checkers, preview
scripts, provenance, print instructions and simulator. Pinned platform hashes
and the historical source-generator hash match their recorded revisions.
Its isolated simulator execution checked startup, on/off, pause, zero
brightness and symmetric falloff. The author additionally exercised the
standalone browser page: breathing, steady on, off, pause, changing colour,
zero brightness, uniform endpoints and the centre-bright curve. No browser
errors or warnings were reported; the steady-on rendering was inspected.

## Validation

Both complete CAD checkers passed against the delivered files. See
`bench-geometry.json` and `fit-geometry.json`. These cover the continuous LED
floors, diffuser support/capture, friction contacts and entry, deep platform
grips, insertion/removal and loading with wires attached, both pinned cradle rows,
STEP/STL/assembly agreement, fit samples and sampled 0.2 mm print layers.
Negative controls reject missing walls, grip ribs, shallow jaws and closed
wire tunnels. The sample and full black parts match the final fit revision 2.
The preview was inspected. The regenerated print pack has 14 members, valid
CRC and byte-for-byte agreement with the current source files. Python syntax,
JavaScript syntax, whitespace and scoped Markdown spelling checks passed.

## Limits and preserved work

Geometry checks do not establish printed retention, insertion force, rocking,
wear, creep or pedal movement. The measured 0.25 mm play drove the tighter
revision; that revision still needs a print trial. The diffuser's two-wall
bridge anchoring concern remains open. A one-wall suggestion was not applied
or verified. The simulator is illustrative, not an optical/material model.
These remain physical gates under #1074 `autonomy:blocked-verify`.

Earlier snap-housing exports, earlier fit reviews and machine-specific slicer
projects are preserved locally and excluded here. The separate bench/panel
mount remains an explicitly documented alternative, sharing the current white
lens; it is not the superseded platform mount. Firmware belongs to its separate
publication. No firmware, PCB, production metal or Fusion files changed.
