# PR readiness review — final screen-power prototypes

<!-- cspell:words ADuM TPS GPIO pcbnew SKiDL Freerouting CSpell unassembled -->

Review date: 2026-09-22 UTC. This report replaces the earlier review of the
superseded 40-pin interface and hand SMD board.

## Scope and stack

The current change consists of Python/SKiDL circuit and layout sources, KiCad 10
native CAD, Bash build orchestration, assembly documentation, and the bounded
console J25 addition. The hand carrier has 56 through-hole components and two
external assembled source modules. The integrated factory board has 72 components.
Both use GPIO17/GND on the two-pin J2 control input.

No Dart, Flutter, audio-engine, or firmware implementation changed in this scope.
Those unrelated suites were not run. The hardware directory has no configured
Python/Bash formatter or linter; the review used the existing generator conventions,
Python compilation, shell syntax, CAD rules, file integrity, and CSpell.

This reviewer authored the general checker, console J25 change, overlap helper in
`cleanup.py`, package-publication helper in `export.py`, and portions of the project
documentation. This report does not claim independent implementation approval of
those portions. Their mechanical outputs were checked here; separate assigned
reviewers cover implementation correctness. That distinction also applies to the
repeated console-preservation measurement below.

## Formatting and static analysis

- Fourteen Python files, including the two changed console generators, passed
  compilation using KiCad's Python without creating source-tree caches.
- `build.sh` passed Bash syntax checking.
- CSpell checked the README, plan, progress document, console wiring reference,
  and console soldering guide: five files, zero issues.
- Git whitespace checks passed for the changed source and documentation. The
  native KiCad console STEP export contains exporter-generated trailing spaces;
  its canonical CAD output was preserved rather than hand-reformatted.
- Final rule reports contain zero errors, warnings, exclusions, and unconnected
  items for both variants. No static-analysis finding remains in this scope.

## CAD and build evidence

The owner completed generation, placement, explicit critical routing, general
routing, plane fill, cleanup, and native validation for both corrected variants.
The final `validation.json` was generated at 2026-09-22 02:32:45 UTC. Its recorded
source inputs all match the final files. Both variants pass:

- Native schematic component/net parity against the circuit netlist.
- Physical PCB pad/net parity, supply boundaries, and two-wire control contract.
- Four-layer board geometry, inner ground planes, USB continuity, front-layer
  width, absence of data vias, and differential length difference checks.
- Fresh DRC and ERC with zero findings and zero missing copper connections.
- Deliberate host-power bridge, USB trace cut, and console-control trace cut probes.
- The hand variant additionally rejects an SMD footprint and an SMD pad.

A direct native-board inspection found 56 hand footprints, zero SMD footprints,
and zero SMD pads. Both board J2 connectors have pin 1 `PI_GPIO17`, pin 2 `GND`,
and neither contains the obsolete J3 ribbon connector.

The final console board still matches its recorded validated hash. A repeated
comparison with the pre-J25 board confirms all 681 original tracks/vias retain
UUID, net, layer, endpoints, width, and drill, and all 65 existing footprints retain
position, orientation, and footprint identity. Only J25 and eleven GPIO17 copper
items were added. Console physical J2.11 and J25.1 carry `PI_GPIO17`; J25.2 is GND.
See [console validation](console-control-validation.md) for the original author
record and source-generator checks. Existing ring-board outputs are unchanged.

## Final package integrity and provenance

The owner signaled source stability and completion of both exports before this
inspection. Every manifest-listed output file was checked against its SHA-256;
every recorded source input matches the final working file. Each manifest's board
hash matches its native PCB. Each package's freshly generated validation also
matches the current source and reports clean DRC/ERC.

| Variant | Manifest outputs | Source inputs | ZIP entries | SMD placement rows |
| --- | --- | --- | --- | --- |
| hand | 28 | 35 | 15 | 0 |
| factory | 28 | 35 | 15 | 54 |

Both ZIPs pass the archive integrity check. Their entry names exactly match the
corresponding Gerber/drill directory, and every uncompressed entry matches the
standalone file byte-for-byte. Required copper/outline layers, drill files, BOMs,
external BOM, assembly instructions, both placement files, schematic PDF, assembly
PDF, STEP model, and top/bottom renders are present and nonempty. The hand SMD
placement table has only its header, consistent with its through-hole contract.

Package validation timestamps are 02:33:25 UTC for hand and 02:33:46 UTC for factory
on 2026-09-22. The package manifests preserve source and output hashes; these are
prototype packages, not evidence of manufacturing or installed-device acceptance.

## Failure handling

The build stops on command failure. Router exchange files use a temporary directory
with an exit cleanup trap. Intermediate routing checks permit only the explicitly
unfinished connection classes; final rules must pass before export.

The exporter verifies the design afresh, prepares a complete package separately,
and rejects source changes during export. Publication preserves the previous
package until the replacement is ready and rolls back a failed rename. The
separate test-quality review and [publication validation](export-publication-validation.md)
record injected copy/rename failures and retained prior-package evidence. This
report checks the final package results without claiming independent authorship
review of that publication helper.

## Debug artifacts and commit hygiene

A direct scan of all 50 intended new text source/CAD files found no private home
paths, temporary-path references, or conflict markers. Source scans found no
TODO/FIXME/HACK placeholders, debugger hooks, test skips, or secrets. Status output
is deliberate CLI feedback. Ignored interpreter caches, SKiDL cache files, rule
scratch files, and fabrication directories are not source deliverables.

Native schematics, netlists, BOMs, local symbol/footprint definitions, and placed
and routed PCBs are intentional versioned hardware artifacts requested by the
owner. The generated-file exception is specific to those design deliverables.
STEP/PDF/render/ZIP exports for the new screen variants stay in ignored fabrication
folders. Existing tracked console manufacturing artifacts follow the repository's
current hardware convention. KiCad library attribution is recorded alongside the
local definitions.

The screen-power changes are still working-tree changes on top of routing baseline
`5fd9f8bf`; there is no new screen-power commit to assess. Existing inherited commits
and their earlier merge are outside this bounded review. An earlier root-level `circuit.erc` scratch file has been removed; no root scratch
file remains in the final status.
The review makes no claim about future committed-head CI or merge readiness.

## Auto-fixable items

None remain in the intended implementation/package scope. Stage explicit intended
paths, excluding generated scratch files and ignored local package outputs.

## Verdict

Critical: 0. Important: 0. Suggestion: 0.

Ready for the prototype-design PR within the reviewed scope. Keep
`autonomy:blocked-verify`: both variants remain unassembled, actual-panel behavior
and USB qualification are unproven, and early-boot/shutdown software integration
is specified but not implemented. The documented physical acceptance matrix covers
relay behavior, suspend current, fuse response, HDMI back-power, timing, AUX
capacity, temperature, impedance, and enclosure fit. This is not manufacturing,
deployment, or merge approval.

## Final artifact hashes

Paths below are relative to `hardware/kicad/screen_power/`.

| File | SHA-256 |
| --- | --- |
| `hand/fabrication/manifest.json` | `0ef127e33af22101e9e2d8ce63964d9aed3fb0e019c85a81ebecd3da7897c5a0` |
| `hand/screen_power_hand.kicad_pcb` | `0362adac5630fb1871472aeded0f62d113e94ccb73a770ef520a6ec007d757b3` |
| `hand/fabrication/screen_power_hand_prototype_gerbers.zip` | `5e729a35ab13e9d27b16a1fee967a2f70e6704630e2aaf9e32f336c09c9d2e65` |
| `factory/fabrication/manifest.json` | `2ce544d3f00a46cdcc6abfad7beddce6c87edc9bdc543ef4bb01523469d585a9` |
| `factory/screen_power_factory.kicad_pcb` | `d047ab2bc52f89caec3ef808c306aa1cff9b533ac3ffef7bfe16c130e9def464` |
| `factory/fabrication/screen_power_factory_prototype_gerbers.zip` | `a17ca476248375afd033da1d0b9e92664cb2a1e6cb1ee91a960621497e386c8a` |
| `build.sh` | `ae5821c708b0aefd5192e126bc61fded08f7c0b98a59a5caa575077408fbbcb5` |
| `circuit.py` | `bb71e31c515d9a5321870b7772169f9069f94d811099d2f4470eccf48916a627` |
| `hand_circuit.py` | `7bd76765d3f9dbbf1710068330dcc0946a7fae0c8c3f1381e82d7d2a319b71e6` |
| `pcb.py` | `369f6083485dff8439ceb4f454cbf6c1d44be3bb069c8f63e50d98db1fa8dbeb` |
| `hand_layout.py` | `d1b241a5ade4c3f3d367b091d642b671e7b3e01e3841c02a2231c005ad8052e1` |
| `route_critical.py` | `bab5cb5c65301095e6783ba40d494d94fa12b6ce3d189fdcdccd69bae525680b` |
| `router.py` | `3209b6af268eb1d1e6c108d5486fb0325c13b89872475d5badd5ca338ec81f63` |
| `finish.py` | `dc2dc4b7c91e6071b5318296c12719c61ebaeeca856e95f0a2c44914f0cb1d55` |
| `check.py` | `7ea4ff595c8f09deb551ab4f899e4594b31cdd66bb94e3a6265a4b2ce237c697` |
| `hand_checks.py` | `084d5dcdd63addb2ebfa6b21364909a3ddb32d674b31ef8bfdd9dbd5089239a6` |
| `schematic.py` | `6087ef98670b9e1973780487f2b2db58e119f3eb5b1f3a78324c748371f8dbb2` |
| `cleanup.py` | `5e50d23156b182ea79efc09164ad884eae662e835441acb9bf29072c31745bcb` |
| `export.py` | `21711b1eb73ea15f5a12a9c4e028e08d7e26d1c684afc8f3153d7cb96a6e7965` |
| `README.md` | `30cc8ec91021bc2db2852be8fe0338936ee9fec472d5e01110c095a19b55ecd7` |
| `external_bom.csv` | `c38bc9b1ae8bba54bd35bf862ce650102c573e509254215f6a74a80c58019f55` |
| `validation.json` | `e9b0379a4e0c95dbdfe4844859b1275b59ec646916835a9436c0175806f9d9d0` |
| `../out_console/segno_console_board.kicad_pcb` | `d4a735337159ee083228dbfa23bc4f16c329b2a44fe26847d5a04fc99004b360` |
