> **Screen-board correction, 25 September 2026:** This is a historical report. Its screen relay-pinout approval is superseded: IM02TS commons are 3/6, NC contacts are 2/7, and NO contacts are 4/5. Revision I Gerbers are withdrawn. Use the [corrected Revision J record](../../screen-power-rev-j-1072/verification.md). Console and ring findings are unaffected.

# VGV code review — screen power revision C

<!-- cspell:words Axicom IM03TS SKiDL pcbnew CadQuery SWIG fanout DPDT -->

## Summary

Reviewed the revision C working diff against `a2a6a1f4` on 2026-09-22. No material
code or CAD convention issue remains after correcting the native schematic revision
labels and completing the narrow documentation spelling cleanup.
This is prototype design review, not approval of USB performance, thermal behavior,
manufacturing, or a future committed merge head.

## Scope and independence

This is a Python/SKiDL, KiCad 10, Bash and STEP-model change. Reviewed all changed
Python code, the new model generator and validator, relevant generated circuit
artifacts, local relay footprint, assembly documentation and source/export flow.
No Flutter, state-management, UI, audio callback, firmware, or FFI rule applies to
this diff. No new formatter or lint policy was imposed on the hardware directory.

The reviewer authored portions of the original general checker and publication
helper in an earlier revision. Those unchanged baseline implementations are not
independently re-approved here. The revision C additions were authored by other
agents and were reviewed independently. The original console modification is
outside this revision C diff.

## Critical — must fix

None.

## Important — should fix

None.

## Suggestions

None. The two documentation files now use narrow local vocabulary allowances;
the explicit CSpell run checks both files and reports zero issues.

## Regressions and conventions

The old relay's custom symbol generation and local footprint are removed rather
than retained as a supported alternate. Native `Relay:IM03` now supplies the relay
symbol; a local KiCad-derived footprint changes the drill diameter while retaining
its numbering and geometry. The circuit, independent pin contract, explicit USB
routing, generated component records and native boards use the same selected part.
The review directly inspected K101/K201 on both boards: coil terminals 1/8,
commons 2/7, switched outputs 4/5, unconnected 3/6, and eight 0.80 mm holes agree
with the declared circuit contract and the separate manufacturer architecture review.

The existing two-wire GPIO17/GND interface and separate host-VBUS coil supplies
remain intact. Board dimensions and the shared discrete power architecture are
unchanged from revision B. The layout changes simplify the main power path and
keep explicit USB pairs separate from general routing. No compatibility layer,
extra electronic module, clock, or USB source controller was reintroduced.

The native schematic title was initially still `B prototype` while PCB and README
identified revision C. The owner corrected `schematic.py` and regenerated all twelve
sheets; the review verified that every current sheet now says `C prototype`.
This resolved mismatch is not counted as a current finding. The final finishing
delta places the two bulk-capacitor reference labels below their bodies, separately
from the touch connector labels; its source was also reviewed.

## Layer separation and dependencies

Circuit definition, placement, critical routing, finishing, validation and export
retain distinct responsibilities. `models.py` is a small dependency-free validator
shared by the checker and exporter. It does not import model generation or mutate
CAD. `model_geometry.py` uses CadQuery for five original assembly models and is
separate from normal board generation; opening the native design or rebuilding
the PCB does not require CadQuery.

The model assignment path preserves library transforms, resolves bundled assets
relative to the project, and fails for missing files. Native package copying keeps
the model and local-library directory relationships intact. Model files, source
attribution and license files are included in the input hash set and portable
package. There is no new unchecked source path outside the export's stability test.
The existing publication transaction is unchanged by this diff.

The new component geometry is explicitly documented as simplified assembly data,
with cited nominal dimensions and limits. It does not claim to establish cable
clearance, mating fit, material compliance, or worst-case enclosure dimensions.
Generated CAD and STEP files are intentional deliverables for this hardware task,
not accidental application build output.

## Testing assessment

- All fourteen non-cache Python modules pass compilation. Bash build syntax and
  changed-source whitespace checks pass.
- Direct model checks on both final boards report 37 populated component assignments
  with no model errors. Bare mounting holes are explicitly exempt.
- The new fault cases operate on loaded native PCB objects: clear a model assignment,
  point it at a missing file, disable it, or shrink a relay drill to 0.70 mm. Every
  new mutation is detected on both variants. These exercise actual artifact state.
- Existing host-power, copper-continuity, current-path width, component selection,
  resistor-tolerance and default-off tests remain enabled. The hand-only assembly
  checks remain required.
- An independently invoked complete checker run passed the hand variant. Factory
  checks and all mutations also completed, but its final stability guard rejected
  the concurrent schematic edit. This was an expected invalidation, not a clean
  final snapshot. Final stable native validation and packaging remain the owner's
  separately recorded gate; this review does not reuse the old revision B report.
- Model coverage checks require assigned, enabled, resolvable STEP files and
  positive scale. Documentation correctly states that this does not parse solids
  or validate exact component geometry. Native export and physical acceptance are
  separate checks.

New tests are meaningful for the new behavior. State-management and UI test coverage
are not applicable to these hardware-generator changes. The documented initial
relay pickup calculation is limited to its stated conditions; hot re-enable,
USB hub operation, suspend behavior and physical assembly qualification remain open.

## Simplicity assessment

- Additional removable lines: no material reduction identified in the changed scope.
- Unnecessary abstractions: none. Small model primitives and paired-route fanout
  helpers serve repeated current geometry; they do not form an extensibility framework.
- YAGNI violations: none. Both requested assemblies remain in one circuit description.
- Complexity verdict: already proportionate to the required design and export checks.

## Current verdict

Critical: 0. Important: 0. Suggestion: 0.

No code restructuring is recommended. Final packages and physical qualification
are outside this review's clean-source conclusion; retain the task's hardware
verification boundary.

## Reviewed snapshot

Paths are relative to `hardware/kicad/screen_power/`.

| File | SHA-256 |
| --- | --- |
| `check.py` | `2b7cb9a6f6e026a0507ff1f37f8f9f9d1f2dd1cd21379a22f370c9c5460598ce` |
| `circuit.py` | `f2caa9fc85d1a49da12db9b8a7983941dbab10557ca8b37712c14c02a2ec5a56` |
| `export.py` | `bb9c58f14b24b4a3b73aedb6287b4dfe3f8f2dcc27126ef36e0ede416f43dc88` |
| `finish.py` | `aa1319fd1522fab4ddec706ac657e278524ce63ab9a271e61b36265da575e798` |
| `layout.py` | `9dd59c2ef3e48122e67ad23db7c28aaab2dbdef28c4880fc25ed7cc5ae9f6f4b` |
| `model_geometry.py` | `15099e257dffef2e6322cc8220acba075d0399b7d67baeb8565de1de9e8e1d5a` |
| `models.py` | `3a49e950a8323db0a4fb9b73273ba7039b286eb79383243f4d95f9fa8dbf6db6` |
| `pcb.py` | `53c447790b59b356cfb335a346c6ed50442aaa649d5d0c3d7f4a57bb48700229` |
| `route_critical.py` | `bd2bfc156f33e1c1b5579735c915ddb3e6ebfe3df9b36e23a86e499326a815bb` |
| `schematic.py` | `3c6957d9e812ef290c6bca991a60c88510f30dcf10a67a99b9a187ebee32367f` |
| `switch_circuit.py` | `566d0e2d9f44398c8d558bffa4647d5ca0c4cc399b2482963c7a4fb52145061b` |
| `README.md` | `02d5170857187f07f879187c0a6f11170f2ae0027fdfeb99a73e405018c8810f` |
| `models/README.md` | `e399e8fdf0126e7abb030b245f7d77677ea576df9323cde5ed36807f6f14ffcd` |
| `screen_power.pretty/Relay_DPDT_AXICOM_IMSeries_Pitch5.08mm_D0.80mm.kicad_mod` | `e6b67fc4b372092910d1653aa1ac33db1f50d5abb0cbb8431edfd421dea21c0d` |
| `hand/screen_power_hand.kicad_pcb` | `46147c735ef80895d5ba7d03902f341b344e454fb179a952a7042f5f864504ba` |
| `factory/screen_power_factory.kicad_pcb` | `03cf17f025481bdc051d3265fd3b02c7fbd5cc18e910eabb21192db47f4879cf` |
