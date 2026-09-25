<!-- cspell:words autorouter misassignment -->

# Revision E test-quality review

## Scope and evidence

Reviewed the revision D to E changes in `hardware/kicad/screen_power`, the
hand-only 64 × 76 mm layout, its documented acceptance criteria, and the
current validation pipeline. This is KiCad/Python CAD work; application unit
test conventions and application coverage thresholds do not apply.

The observed end-to-end build completed circuit generation, native schematic
generation, placement, critical routing, remaining routing, cleanup, validation
and prototype export. I did not rebuild or modify production artifacts while
the author was generating the final package.

The final `validation.json` in this review directory, generated at
2026-09-22T14:37:16.785722+00:00, reports:

- Zero ERC and DRC findings, warnings, exclusions and unconnected items.
- All 16 deliberate fault injections detected.
- Model coverage for all 37 populated components.
- Equal lengths within each USB pair: 20.7959 mm upstream and 26.5959 mm
  downstream on both channels.
- Board SHA-256: `7e6945bc12ae4bfd6896cca5e681d7dc1f6c30030c1ed014c0675416dadeacc7`.

An independent parse of the pre-compaction and current netlists found exact
equality of all 41 component records, including four mounting holes, and all
27 net records. The circuit is unchanged by this layout-only revision.

## Coverage assessment

The checks exercise delivered artifacts rather than only generator internals:

- Fresh native ERC/DRC and schematic netlist export validate the saved project.
- Component, footprint and pad parity checks detect missing parts, changed
  footprints and mismatched net assignments.
- Independent pin-level circuit contracts constrain the shared switch,
  two-wire control, USB host supply isolation, relay contacts and fused outputs.
- Native geometric connectivity verifies actual USB and console control
  copper. Power checks remove undersized traces and vias from temporary board
  copies before proving minimum-width physical paths.
- USB geometry checks require bottom copper, the specified trace width,
  no data vias and bounded pair skew. The explicit pair router retains the
  coupled gap and restores critical USB tracks after autorouter import.
- Through-hole validation checks every footprint and pad, including the
  power transistor drill and annulus requirements. Factory removal makes this
  check and its negative controls unconditional for the only supported board.
- XH pitch, relay drills and model availability checks retain their negative
  controls after the compaction.
- Source hashes detect changes during validation; export runs a fresh check,
  checks portable model resolution and declines publication if inputs changed.

The fault injections cover wrong XH pitch; absent, missing and disabled models;
undersized relay and power-transistor drills; footprint and pad SMD attributes;
USB and console-control cuts; undersized power copper; a host supply
misassignment; unsupported relay/driver choices; resistor tolerance; and an
ineffective pulldown. These are meaningful failure-path checks, not assertions
that duplicate the placement generator.

No `power_states.py` exists in either the previous or current revision. The
relevant current checks are `check_contract()` and `numerical_checks()` in
`check.py`. They establish topology and stated numerical margins, not a
transient circuit simulation or measured hardware behavior.

## Limits and verdict

Line-coverage measurement is not part of the existing CAD runner. Requiring a
separate unit-test file for each unchanged generator would not improve the
evidence for this reversible layout change. The physical acceptance matrix
correctly retains cable fit and pinout, USB performance, off-state behavior,
thermal performance, inrush, fuse coordination and actual shutdown timing.
Those gates remain unperformed and the report does not imply otherwise.

No actionable test-quality findings for this revision. The available checks
meet the local CAD/prototype verification scope; this is not hardware release
or merge approval.
