<!-- cspell:words autorouting floorplan -->

# Revision E code simplicity review

## Core purpose

Maintain one hand-soldered screen-power board, with the approved revision D circuit and harness pin maps, in a smaller 64 × 76 mm outline. Generate and validate native KiCad artifacts, then publish a consistent prototype package. Physical screen, cable, thermal and shutdown behavior remain separate acceptance work.

## Scope and evidence

Reviewed the revision E changes in `hardware/kicad/screen_power/` against the supplied revision D snapshot, concentrating on `layout.py`, `route_critical.py`, `switch_circuit.py`, `check.py`, `build.sh`, `export.py`, `finish.py`, `circuit.py`, `pcb.py`, `router.py`, and `cleanup.py`. Read the current assembly guide and implementation plan. The Git baseline also includes earlier approved revisions, so it was not treated as an isolated revision E diff.

Independent read-only comparisons found:

- The populated-component JSON and BOM are identical to revision D.
- Parsing both KiCad netlists with the repository's existing parser gives identical component records and net-to-pad membership.
- The factory folder is absent, and the top-level Python sources contain no factory-selection branch or factory literal.
- The build entry point now accepts no variant arguments and runs only the hand board. Lower-level argument parsers accept only `hand`.
- The export contains all-component positions without the former empty SMD placement file or paste Gerber.
- Across the seven principal changed generator/check/build files, revision E removes 101 lines overall. The geometry is specified directly, with two repeated channel placements; it does not add a layout framework or configuration hierarchy.

Read the current validation report: native ERC/DRC have zero findings and unconnected items; all 16 intentional fault checks pass; 37 populated parts have models. This review did not repeat the expensive shared build or modify CAD files.

## Unnecessary complexity found

No actionable new complexity was found. Factory-only part alternatives, geometry branches, and the isolated multi-variant check orchestration have been removed. Keeping `hand` in the native project/file names and passing that fixed identifier through existing stages does not provide an obsolete factory fallback.

The residual parentheses around some selected literal values are cosmetic. Removing them or refactoring every fixed variant argument would not materially improve this revision's behavior, and is not recommended as a condition of acceptance.

The existing stages serve different tool/runtime or verification responsibilities: circuit generation, placement, explicit critical copper, autorouting bridge, finishing, final validation, and export. Combining these solely to shorten the source would make the manufacturing workflow harder to inspect. The export's temporary staging and source-hash guard protect the concrete requirement that an interrupted or stale export must not replace a complete package.

## Code to remove

None required. The obsolete factory implementation and factory-only models are already removed. No documentation deletion is recommended.

## Simplification recommendations

No further simplification is required for this scope. Preserve the direct floorplan and one maintained board while resolving the documented physical prototype gates separately.

## YAGNI violations

None introduced by revision E. No additional modules, USB controllers, board variants, connector abstractions, or alternative Pi control routes were introduced.

## Final assessment

- Critical: 0
- Important: 0
- Suggestion: 0
- Additional recommended LOC reduction: 0
- Complexity: low for the physical requirements and KiCad toolchain
- Recommended action: accept this local revision from the simplicity perspective

This is a source/layout simplicity result, not hardware qualification or fabrication release. Cable fit, electrical USB operation, load/inrush/thermal measurements and device shutdown timing remain pending as documented.

## Reviewed artifact identity

Board SHA-256: `7e6945bc12ae4bfd6896cca5e681d7dc1f6c30030c1ed014c0675416dadeacc7`.

Validation timestamp: `2026-09-22T14:37:16.785722+00:00`.
