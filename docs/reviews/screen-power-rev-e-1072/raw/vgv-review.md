# VGV/conventions review — screen-power revision E

## Summary

No actionable findings in the hand-only revision E changes. The change follows the approved scope: it removes the factory assembly and its branches, compacts the existing through-hole design, preserves the circuit and connector contracts, and refreshes the native project and documented expectations. This assessment concerns local prototype CAD and its Python/shell generation workflow. It does not establish hardware readiness or authorize merge/publication.

## Scope and method

Reviewed the current `hardware/kicad/screen_power` source, generated hand project, assembly guide, plan, and progress section. Used the preserved revision D snapshot for the immediate revision E comparison rather than attributing earlier revision C/D work to this change. Read the applicable AGENTS and tracking contracts, the build/test guidance, the VGV reviewer role, and the build review output contract. The modified subsystem uses Python/SKiDL, KiCad, and shell; Dart/Flutter architecture and widget-test requirements do not apply.

The review covered deletion and caller regressions first, followed by source responsibilities, naming, error propagation, validation behavior, documentation consistency, and unnecessary remaining factory paths. No remaining active factory branch or caller was found in the current screen-power pipeline. Historical revision documents are intentionally retained.

## Findings

Critical: 0. Important: 0. Suggestion: 0.

## Evidence

- Independently parsed the revision D and revision E netlists. All 41 component records, including four bare mounting holes, match. All 27 raw net mappings match. `hand/bom.csv` and `hand/components.json` are byte-identical to the revision D snapshot.
- All screen-power Python files parse successfully. `build.sh` passes shell syntax validation. Scoped `git diff --check` produced no findings.
- The default circuit/placement/check interfaces now choose only the hand assembly; router/export choice lists no longer accept factory. Removed factory pin mappings and device alternatives do not change the selected through-hole circuit.
- Circuit definition, placement, critical routing, finishing, verification, and export remain separate modules. The layout update follows the existing readable explicit coordinate convention instead of adding a speculative placement framework.
- The build still performs generation, native placement, critical-route checks, remaining routing, cleanup, fault-injection checks, and export in order, with shell errors propagated. The exporter still validates fresh inputs and rejects source changes during export before replacing the previous complete package.
- Hand-assembly checks now run unconditionally. Sixteen deliberate fault injections remain required, including physical USB/control breaks, thin power paths, host-power bridges, component/tolerance errors, model failures, wrong connector pitch, and surface-mount contamination. These check real CAD behavior instead of merely matching source text.
- The inspected validation report dated `2026-09-22T13:58:39.692429+00:00` has zero native ERC/DRC findings and all 16 negative controls detected. Root is refreshing final validation and exports after the final bottom-label adjustment; this earlier report is not presented as proof for a later file hash.
- README, plan, and progress clearly state hand-only 64 × 76 mm prototype scope, unchanged pin maps, separate power harness selection, and outstanding assembled-device validation. They do not claim that CAD proves screen shutdown, USB performance, thermal limits, or enclosure/cable fit.

## Simplicity assessment

The deleted assembly removes duplicated component choices, factory-specific placement/routing, extra checks/process orchestration, and unused models. Keeping the existing `hand` project folder and hand-only command parameter does not create an obsolete factory compatibility path. A few redundant parentheses remain after conditional removal, but they are unambiguous and do not warrant a review finding or unrelated formatting churn.

## Testing assessment and limitations

The existing checks cover relevant emitted artifacts and use negative controls for failure behavior. No additional implementation-mirroring unit tests are needed for these coordinate and hand-only changes. Independent review did not rebuild shared artifacts while root was updating final exports. Final source/board/package hash consistency belongs in the fresh verification record. Actual USB eye/functional tests, power/thermal tests, cable fit, and shutdown sequencing remain explicitly pending hardware tasks.

## Reviewed source snapshot

- `switch_circuit.py`: `f16947d0f827eb3104052753d66c4abe6a573326b679634ff5029668bff95091`
- `layout.py`: `6d14b858b666f674e445155f298ceeb2e7f7f44744b8fc94fa4e5a6f5f648d58`
- `route_critical.py`: `a4894ff576b2d0a55d3454b47a7923a0a093d3aa1d9fc443926baa9272c18b91`
- `finish.py`: `6c2a3ef75db86a25959dfb248122f1a879c91934453c6506752e706238730894`
- `check.py`: `171438070053088094b4b7930b414e64b9f69de8ef566903fcb2463b57053fa5`
- `export.py`: `ee2ddad3c3c58a63fa4ec5ba796de5bd9f286b91910acbb7ac08cbe7a30168f5`
