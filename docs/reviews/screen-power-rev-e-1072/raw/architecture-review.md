<!-- cspell:words Mbps -->

# Revision E architecture review

## Scope and method

Reviewed the current hand-soldered screen-power board and its generation, validation, and export pipeline in `hardware/kicad/screen_power/`, with the current README, implementation plan, and progress contract. The comparison baseline was the saved revision D `screen_power` tree, not the older revision B Git baseline. Reviewed on 2026-09-22.

This is Python-generated native KiCad hardware, so the architecture role was applied to circuit boundaries, source ownership, and the CAD pipeline. Flutter state-management and presentation/data layering checks do not apply to these changes. No implementation files were changed and no concurrent rebuild was run.

Native PCB SHA-256 inspected: `7e6945bc12ae4bfd6896cca5e681d7dc1f6c30030c1ed014c0675416dadeacc7`.

## Layer separation

Violations found: 0.

- `switch_circuit.py` remains the circuit definition and writes the netlist, component records, BOM, and schematic inputs. Comparing revision D and E `hand/components.json` gave exact semantic equality for all 41 records: 37 populated parts and four mounting holes. The hand-only extraction preserves the existing transistor pinouts, diode orientation, relay contacts, connector maps, values, and MPNs.
- `layout.py` owns the board outline and placement. `pcb.py` creates the native board, assigns the netlist pads, and adds inner ground zones. `route_critical.py` owns the deliberate USB and high-current paths. `router.py` routes the remaining nets while preserving the USB traces. `finish.py` owns stack and annotation; its final label-only spacing adjustment does not alter the circuit or routing.
- `check.py` independently checks circuit contracts against generated nets, compares a fresh native schematic export, checks board pads and physical connections, and checks the upstream console control output. `export.py` depends on a fresh successful check before preparing a portable package. The pipeline keeps placement artifacts distinct from the finished routed board.

## Electrical boundary assessment

No introduced violations found.

- The common-source Q3/Q4 pair remains between `AUX_5V` and `SWITCHED_5V`, with both gate pull-up and source connection retained. D1 still isolates the control node from the AUX-powered buffer when AUX is absent. GPIO low/floating behavior and reverse-blocking assumptions were not changed by the hand-only extraction.
- The Pi host VBUS nets still serve only the respective relay coil, flyback diode, and local bypass capacitor. They do not join the screen power rails. Each screen retains separate main and touch fuses, and both data conductors use normally open relay contacts; unused normally closed terminals remain unconnected.
- The XH4 contracts remain pin 1 VBUS, pin 2 D−, pin 3 D+, pin 4 ground. The power VH2 contracts remain pin 1 +5 V and pin 2 ground. J2 remains the existing GPIO17/ground link from console J25. No ribbon intercept or additional GPIO path was introduced.
- A separate read-only native PCB inspection confirmed four copper layers, 41 footprints, 37 populated components, no surface-mount pads, no data vias, and no tracks on either inner layer. Native Q3/Q4, J1/J2, USB, power, and relay pad maps match the intended circuit boundaries.
- The revised critical routes preserve the defined copper widths and bottom-layer pair construction. The current build's validation inspected during review reported matched 20.7959 mm host sections and 26.5959 mm screen sections, and zero ERC/DRC findings or unconnected items. The board hash in that validation matched the board at the time of inspection. Final annotation-only export validation is being refreshed by the coordinating agent.

## Dependency direction

Direction violations: 0.

The build flow remains circuit → placement → critical routing → remaining routing → finish/cleanup → checks → export. The checker and exporter read design inputs and native CAD; they do not create an alternate circuit definition or silently select an obsolete factory assembly. Hand-only command-line choices, build dispatch, model inventory, and current export outputs are consistent with the owner's instruction. Empty SMD position/stencil exports and unused SMD credit files have been removed from the active export path.

The exporter stages a complete package before replacement, checks the portable model paths, records input and output hashes, and rejects input changes during export. No reverse dependency from delivered artifacts into source generation was introduced.

## Package structure and release limits

Structure is coherent for the existing small CAD pipeline. No extra architecture or application dependency was introduced.

The README and plan clearly retain the prototype boundary: actual cable pinout and fit, USB-C configuration, 480 Mbps behavior, thermal/current/inrush performance, enclosure access, relay hot restart, and early GPIO shutdown timing still require physical/integration verification. The revision does not claim that a green CAD result proves those properties or that the blue-screen symptom is already qualified. The unresolved main-power harness is explicitly documented. Historical C/D evidence is not treated as current E validation.

## Verdict

Architecture is clean within the authorized revision D-to-E hand-only compaction scope. No actionable architecture regressions were found. This conclusion is a source/CAD review, not hardware release or manufacturing approval.
