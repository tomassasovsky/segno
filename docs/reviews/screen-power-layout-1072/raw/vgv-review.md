<!-- cspell:words floorplans micrometres micrometre -->
# VGV Code Review

## Summary

No actionable project-convention findings in screen-power revision B relative to `c275f94a`. The implementation replaces the former EVM/native USB-C designs with one shared discrete circuit and keeps electrical generation, placement, critical routing, finalization, validation and export in separate modules. Both assembly variants regenerate consistently. The existing console J25 work is unchanged. Current progress, plan and assembly documentation agree on revision B and retain the physical verification gate. This is not a merge recommendation; `autonomy:blocked-verify` remains applicable.

## Critical — Must Fix Before Merge

None.

## Important — Should Fix

None.

## Suggestions — Nice to Have

None.

## Scope and method

Reviewed applicable AGENTS.md, build/test and tracking instructions, the revised circuit and layout modules, routing bridge and critical routing, validation and fault injection, finalization/cleanup/export behavior, custom symbols/footprints, BOMs, current README, progress document and implementation plan. The repository's Flutter/Bloc conventions were considered in scope selection: this change is exclusively hardware/CAD and related documentation, with no application state-management, presentation or native-engine code changes.

Read-only examination of the live worktree was supplemented with circuit and placement generation in isolated temporary copies. No implementation or delivered board was modified by this review. The parent task owns final package export and its artifact manifest verification.

## Regressions and scope preservation

- No changes since the review base were found in the existing console generator, netlist, or routed/manufacturing output directory. This preserves the previously added J25 GPIO17/GND control connector and existing console routing.
- `hand_circuit.py` and `hand_layout.py` are removed. Both variants now use `switch_circuit.py` and `layout.py`; active source does not retain alternate EVM/native USB-C paths or call the deleted modules.
- Both generated component sets contain 41 references, including four mounting holes. Their BOM rows match `components.json` exactly in reference, value, footprint, MPN, group and quantity. No ADuM, TPS25810/TPS25221, EVM or native USB-C source components remain in these active assemblies.
- Hand assembly contains 37 through-hole populated components plus four mounting holes and no surface-mount pads. Factory assembly contains 20 SMD components, 17 through-hole components and four holes, consistent with the documented assembly distinction.
- Shared screen switching does not alter the existing Pi-to-console ribbon, add a 40-pin intermediate connection, or draw screen power from the Pi GPIO header.

## Modularity and simplicity

The shared electrical definition is appropriate because both variants intentionally implement the same topology; package-specific transistor pin maps and footprint choices remain explicit at component creation. Placement is centralized without retaining separate obsolete floorplans. Critical power and USB routing remains separate from the low-current router bridge. `hand_checks.py` is narrowed to its remaining independent responsibility: enforcing through-hole assembly.

The implementation reuses SKiDL, KiCad footprints, existing netlist parsing, native ERC/DRC and KiCad connectivity rather than introducing competing representations of copper connectivity. The custom fuse footprint addresses the selected package and uses an explicit manufacturer-derived description. Validation removes narrow routes on in-memory copies before checking broad power connectivity, which tests the required behavior rather than matching source text.

## Reproducibility and source/output consistency

Independent circuit generation in a temporary copied tree succeeded for both variants using the project's SKiDL environment:

- Generated netlists are semantically identical to the delivered netlists.
- `components.json`, `bom.csv`, `screen_symbols.kicad_sym` and `sym-lib-table` are byte-identical.
- The root schematic and all five child schematic sheets are byte-identical, including the new shared-power sheet.

Independent placement generation also succeeded for both variants. Component values, footprint identities, rotations, sides, pad sizes/drills/attributes and net assignments agree with the routed boards. The only coordinate differences are the three radial capacitors, by 0.012–0.021 micrometres, consistent with the documented 0.1-micrometre DSN coordinate quantization. These are not component-placement drift or unreproducible edits.

The refreshed `validation.json` reports both variants CAD-ready with no errors. Every recorded source SHA-256 matches the current file, including the board, revised circuit/layout/check modules, generated schematic/netlist data and console interface inputs. Thus the old revision A evidence and deleted-module hashes no longer remain in the current validation report.

## Documentation

The current README, progress entry and existing plan path now consistently describe revision B: 72 × 84 mm hand assembly, 72 × 74 mm factory assembly, one shared power switch, two fused main outputs, separately fused touch rails and two RF USB-data relays. The plan expressly supersedes revision A; it does not leave the old EVM design as an active alternative.

The wiring guide distinguishes ordinary switched 5 V from a new USB-C source port and preserves the need to identify the actual existing power harness. It also distinguishes CAD checks from assembled thermal, USB, fuse, enclosure, residual HDMI-power and shutdown-timing validation. Startup/shutdown integration remains explicitly unimplemented. No completed screen shutdown behavior is inferred from clean CAD.

## Simplicity assessment

- Lines that could be removed: no material unnecessary implementation identified.
- Unnecessary abstractions: none identified.
- YAGNI violations: none identified.
- Complexity verdict: appropriately modular and materially simpler than the superseded two-circuit revision.

## Testing assessment

The current source-matched validation report records zero native ERC/DRC findings and unconnected items for both boards, full schematic/netlist/PCB parity, physical USB and console-control continuity, USB geometry/skew, power-path width/connectivity, numerical drive margins and assembly checks.

Fault injection passes for cut console control copper, cut USB copper, host-power remapping, narrowed main-power copper, wrong relay voltage, wrong driver model, wrong resistor tolerance and weak pulldown. Hand assembly additionally rejects both an SMD-marked footprint and an SMD pad inside an otherwise through-hole footprint. These are meaningful failure paths for the actual checks.

Software state-management and UI tests are not applicable. Physical screen/USB behavior, thermal/inrush/protection performance and shutdown ordering remain outside this review and require the documented hardware/device evidence. Final manufacturing export was still owned by the parent task when this review concluded; this report does not certify an unfinished package export.
