# Architecture Review — screen-power Revision M source

Reviewed 26 September 2026 against `355882d848477537cb491b8ab9180123eb7f8971` in the publication-review worktree. Scope is the in-progress source and regenerated circuit/schematic delta. Placement, routing, the final native board and a replacement manufacturing package are explicitly pending and are not approved by this report.

## Stack and boundaries

This change uses Python, SKiDL 2.3, KiCad 10 `pcbnew`/CLI, a shared standard-library KiCad netlist reader, and Freerouting for noncritical copper. It is a hardware-generation pipeline, not a Flutter feature. Application presentation, bloc and repository rules are inapplicable to these files.

The examined flow is:

1. `circuit.py` configures the SKiDL interpreter and invokes `switch_circuit.py`.
2. `switch_circuit.py` owns electrical connections, part choices, component records and purchased-part BOM output. Its optional schematic output delegates serialization to `schematic.py`.
3. `pcb.py` consumes the generated netlist through the shared interpreter-neutral parser, delegates physical positions to `layout.py`, and writes a separate placed board. `route_critical.py` owns critical geometry; router, finishing and cleanup stages follow it.
4. `check.py` independently states the required electrical contract, compares board pads and native schematic netlists, checks physical rules and margins, and records source hashes. `models.py` remains a separate reusable portable-model check.
5. `export.py` runs fresh validation before producing exports, hashes inputs, refuses publication if inputs change, and replaces the package only after completion.

No changed import reverses these dependencies, and no cycle was introduced. The existing split between the SKiDL and KiCad Python runtimes is preserved.

## Layer separation

Violations found: **0**.

- Relay supply and presence-detection decisions live in `switch_circuit.py`, not in PCB presentation or export code.
- The new resistor group parameter supplies component metadata without coupling the circuit to schematic or physical coordinates.
- The schematic writer classifies the added channel resistors and shield pads on their touch sheets while retaining the source net connections.
- Bare shield pads remain electrical components in the netlist and component records, but are excluded from the purchased-part BOM. Their stock KiCad footprint already has `exclude_from_pos_files` and `exclude_from_bom` attributes.
- The four model exceptions are limited to exact shield references and the expected bare-pad footprint. Populated components retain the existing model-coverage requirements.

## State and validation assessment

The added validation is appropriately divided between a declarative pin contract, a discrete state/path model, and separate numerical drive/current bounds. The state model is explicitly described as ideal switches plus directed body diodes, not an analog or timing simulation. The contract also constrains host-VBUS terminals, presence-divider terminals and the series-driver node, preventing the state abstraction from being the sole authority for wiring.

I independently ran the focused checks against the regenerated Revision M netlist with KiCad Python:

- 58 physical footprint records: 50 populated parts, four mounting holes and four bare shield pads.
- 54 BOM rows: populated parts plus the existing mounting-hardware rows; none of the four shield pads appears in the purchase BOM.
- Circuit contract and numerical USB-presence checks: no errors.
- 48 supply/GPIO/host/suspend combinations, 96 coil-path checks: no errors.
- All 12 USB power baseline/fault controls passed, including old host-powered coils, gate bypass, crossed host detection, missing divider terminals, weak/shorted resistor values, reversed driver body diodes, wrong shield net and a retained host reservoir.
- `git diff --check`: passed at review time.

The first-assembly and full USB qualification limitations remain stated. CAD state checks do not establish relay switching time, actual cable behavior, a USB eye diagram or manufactured-board performance.

## Package structure and source of truth

No new package, runtime dependency or alternative build path was added. The existing `build.sh` remains the single ordered generation/validation/export entrypoint. The generated native circuit and schematic derive from the same electrical source, while the required electrical contract is stated separately in the checker. Export validation and input-change detection are unchanged and are not bypassed for this revision.

The README, BOM and system power-budget changes consistently describe AUX-powered coils and low-current host detection in the examined snapshot. Their final release identifiers and physical assertions must be reconciled with the completed native board when it is generated; the pending stage is not a defect in this source review.

## Reviewed source identities

| File | SHA-256 at focused validation |
| --- | --- |
| `switch_circuit.py` | `652502f1006b5019752c874b08ff431b5e8bc24cea1dcbf52d50cc513fd23a7e` |
| `check.py` | `fe34381a9c40925678e8442c03e7c2f7072cd3773eaa026fed49c02d9c8c4f83` |
| `pcb.py` | `c8f2f0c50dee11ce991e081f552d66bb980ca8d55c423a58b8c20a5535cdcf5f` |
| `schematic.py` | `a776793ec1552925ad8bb4960f0aadbfe69618d7fed4a7540e35d5fb7b700ecb` |
| `models.py` | `05a76f9c593b361abd51384cf8095b4c864792fd5e229721dea9fec2e11b069a` |
| `finish.py` | `45ae91bea58fcd5d00cea6fa68661797619338ec31d604b279240c46c0e71f5f` |

## Verdict

No actionable architecture findings in the examined source delta. This report does not mark the final native release or the full PR clean. Final placement/routing, fresh whole-board checks, portable-package validation and exact-head review remain required after the native Revision M board exists.
