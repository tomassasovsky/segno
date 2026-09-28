# VGV code review — screen power revision N

## Summary

Source and pipeline review, including the final source delta on 28 September 2026, against committed baseline `9f01b49572249e544c84097b574c02f25de851a7`. No unresolved actionable source finding. The revision N source and local ring ground-fill finish are covered by the file identities below. **Final native validation, fresh copper-model results and final manufacturing exports remain a separate release gate.** This source review does not establish manufacturing readiness or fresh Claude approval; the latter service did not complete a new approval.

The stack in scope is Python, SKiDL 2.3, KiCad 10 and the existing Freerouting bridge. No Dart, Flutter, FFI, real-time audio or runtime state-management files are changed; their framework-specific VGV rules are not applicable to this hardware change. I read AGENTS.md, the build/test section of PROGRESS.md, TRACKING.md, the VGV role and review reporting contract.

## Critical — must fix before merge

None identified in the reviewed source snapshot.

## Important — should fix

None in the reviewed source delta. Outstanding final evidence is listed separately below.

## Suggestions

None. The existing formatting and file organization are retained; a broad stylistic refactor would obscure a hardware substitution without improving its verification.

## Regressions, callers and portability

- Traced `build.sh` through circuit, schematic, placement, critical routes, router export/import, finishing, cleanup, validation and fabrication export. Changed helpers retain their caller contracts.
- The removed pump, optocoupler and opposing PMOS stage are intentionally replaced, not kept behind a fallback. The obsolete gate-drive child sheet has already been removed; the root schematic uses `relay_drive.kicad_sch`.
- `circuit.py` already appends the screen-power directory to SKiDL's symbol search path. The new root `screen_relay.kicad_sym` therefore resolves without a user-installed symbol library. `schematic.py` embeds the generated definition and writes the existing project-local `screen_symbols` library, which the portable export copies together with its library tables.
- Exact MPN and footprint checks tie the purchased fuse, holder, relay, driver and clamp to generated records. The holder is a purchasing accessory and does not create a phantom electrical symbol or duplicate footprint. Bare shield pads are not purchasing items. Excluding the four H* mounting-hole records, the BOM contains 42 electrical parts plus the separate F1 holder: 43 purchased screen-board units.
- Pin contracts now cover the raw input net, fused load boundary, power contact, coil driver, clamp and all switched branches. Removed charge-pump references/nets are explicitly rejected.
- USB contact, VBUS-presence and default-off checks remain active. The source records the closed relay's bidirectional behavior and does not claim reverse blocking during an asserted enable.
- Model generation removes obsolete package outputs and maps replacement bodies through bundled STEP paths. `models.py` and the exporter still reject unresolved, hidden or non-STEP model files in the portable package.
- Export remains fail-closed and staged: it runs fresh validation, checks source hashes before publishing, and retains the previous package if preparation fails. Root-level custom symbol definitions were added to both source hashing and the independent fabrication verifier's input discovery.
- The independent USB comparison includes arc midpoint geometry and all fixed connector/data-relay/shield/mounting anchors, allowing only J1.1's deliberate raw-input net rename.

## Verification performed

Using KiCad's Python, without modifying generated board/schematic inputs:

- Parsed every screen-power Python module with `ast.parse`.
- Parsed the current generated netlist and ran the new circuit contract, numerical budget, power-relay state and USB-relay state checks: zero errors in all four.
- Re-ran the combined relay-contact, power-source and USB-source controls after the final source delta: all **51/51** passed with zero contract, numerical, power-state or USB-state errors. The earlier 32 power-source and 13 USB-source checks remain included.
- Confirmed exactly seven active schematic sheets: root control, shared power, relay drive, and power/touch for each of two screens. `gate_drive.kicad_sch` is absent, and the obsolete `fit_report.py` helper has been removed.
- Confirmed the native title revision is N and `finish.py` consistently regenerates the revision N identity.
- Parsed the new ring and finite-difference ground-model modules and checked `route_ring_board.sh` with `bash -n`.
- Loaded the ring into memory and applied `finish_ground_edges` twice without saving: both resulting named zone outlines were identical, and all track/via geometry tuples remained unchanged. The new route-script hook runs before the existing zone refill and final validation.

These checks validate source contracts and local mutation behavior. The independent geometry record reports 564 unchanged ring track/via items, 73 unchanged pads, unchanged back ground contours and 3.2204 mm² removed from two front-ground dead ends. This review does not turn those observations into USB compliance, measured thermal behavior or assembled-hardware approval.

## Final source delta

- `pcb.ground_outline` replaces pointed mounting-clearance intersections with sampled tangent arcs while retaining separate hardware keepout rules. It changes the ground-zone boundary, not the board outline, component placement or copper layer count.
- `ring_power.finish_ground_edges` checks the two retained anchor positions, replaces only its own named rule areas and forbids zone fill while explicitly allowing tracks, vias, pads and footprints. Repeated application is stable. Its location-specific implementation matches this fixed board and is preferable to a generalized geometry abstraction.
- `finish.py` now regenerates revision N and the reviewed component/connector legends without reintroducing extra labels. The earlier M-stamping item is resolved.
- Removed AUX and rear-landing stubs do not add alternate runtime modes or compatibility branches. The explicit power-path guard retains width, connectivity and independent via-bypass requirements.
- Inline cspell entries are scoped technical names and symbols. The cost table's bounded disable/enable pair covers exact manufacturer codes; it does not disable linting globally.
- The ground-return model extracts actual filled geometry through KiCad, uses wholly covered cells instead of center-only occupancy, subtracts drilled voids after copper unions, models finite plated barrels, checks required-return connectivity and reports solver residuals. It records copper/plating/temperature assumptions, board and model hashes, and rejects an input board changed during the run. Its sheet network and reciprocal worst-load allocation are consistent with the stated DC sensitivity scope. The independent test-quality role separately exercised connected, material-scaling and subcell-slit controls; this review inspected those results and their model identity rather than claiming to have authored or rerun that independent fixture.

## Remaining release evidence

1. Obtain the stable native `check.py hand --self-test` result with all 103 required controls passing, zero native ERC/DRC errors and exact schematic/netlist/PCB parity. The final run was still owned by the CAD/guard authors at this source review; I have not claimed its outcome here.
2. Refresh the nominal and thinner-material ground results against the final copper. At review time, saved results identified board `53cdf6ab90619885a0872c31d25b3eb12729e2b84486431a84982f9b234bf29b`, while the current native file identified `fec52dc30e760c8440f319aa9fee6909ed209c9ef66af97378235c2341868db4`. Mounting-plane contours and AUX geometry changed, so the existing silkscreen-only exception is insufficient. The parent was notified to rerun this as part of its final artifact gate.
3. Complete final copper/assembly inspection, USB preservation, export, source-to-package verification and manufacturing-manifest reconciliation on the same resulting board. No stale fabrication package is accepted here as the revision N result.

## Simplicity assessment

The smaller power-stage circuit removes the bespoke charge-pump and optocoupler path. New checks remain in the established validation layer; the accessory BOM row is a direct representation rather than a generalized purchasing abstraction. Added fault injections are relevant to physical pin, fuse and assembly mistakes. No speculative runtime interface or backward-compatibility layer was introduced. No deletions or abstractions are recommended from this pass.

## Testing assessment

The observed source tests are meaningful negative controls over connectivity, analog component assumptions and purchasing identity. Baseline-pass assertions prevent an already-failed design from giving false-positive mutation coverage. The final 103-control native result and export identity remain separate evidence requirements. State-management/UI coverage is not applicable.

## Working-file identities

These hashes identify the reviewed source delta, not a committed final head. Final native/CAM results need their own matching identities. The deleted `fit_report.py` is intentionally absent.

| File | SHA-256 |
| --- | --- |
| `hardware/kicad/screen_power/switch_circuit.py` | `72c0c706f7298d194569806b32284a39cfc7b02fa3d36c6b1a3faadc5e12b163` |
| `hardware/kicad/screen_power/schematic.py` | `5d4356322e5d0f190c92d1af7712cb81b6f745068332f335d14eed9e3f9e5b17` |
| `hardware/kicad/screen_power/pcb.py` | `d4db56c2412406ebf920c8d1722b34609a33b8306d710611cd5fbf4d6237335f` |
| `hardware/kicad/screen_power/layout.py` | `6e94a961db8a0847ccf647fc2cacab0fe910985cb9bcff7d4175fe22182c5742` |
| `hardware/kicad/screen_power/route_critical.py` | `90c7b499fec1eacc53b9c28de8dcf1c8ad2d316ab52f3fd4345f540603da988f` |
| `hardware/kicad/screen_power/finish.py` | `773db3f89ec5b67df9c43bab298e57dfa62a6c98cb5026ec894a8b09d4706417` |
| `hardware/kicad/screen_power/check.py` | `67d4be849c73d427cad1deefe5f4f013ef7336a31ad96bcab78c216861f8d8f9` |
| `hardware/kicad/screen_power/hand_checks.py` | `22587020dcc0eb8752515aea0cec7394579709fe5a017ea0edd604335799a842` |
| `hardware/kicad/screen_power/model_geometry.py` | `b448d868aa12ddf28f510d90d8f27c431a3c4cc9e41360d621cb7632c593890c` |
| `hardware/kicad/screen_power/screen_relay.kicad_sym` | `9ad2b49991728ec0265e8205326d9b51ab7765473b4dfc9f40b86176309d9a8c` |
| `hardware/kicad/screen_power/hand/screen_power_hand.net` | `a2babbc713e40d174ed5da4fcdc820188d4dec55b8b883314455ad03bc482041` |
| `hardware/kicad/screen_power/hand/components.json` | `62a33f065cdab8122422b8bce8debb4253109e461ca3a06aea495b4e4634b8a0` |
| `hardware/kicad/screen_power/hand/bom.csv` | `6eacbf2638a6a266c283c80f0363420e860604300ad33e35c548bd4b83e63110` |
| `hardware/kicad/ring_power.py` | `2379a6da321e5f1eff7b7ab54198fd075fd2cff5f71adaeccbc9f64245000ff6` |
| `hardware/kicad/route_ring_board.sh` | `d577bcffd0cec82f7d76445143e7daafa0c4e294abe8100f9b8d50a328a68fb7` |
| `docs/reviews/screen-power-stock-cost-1072/ground-return-model.py` | `cf609b252a0139638f99be15fe1b1e82e3e51e2a9051c8c49a869c60ee509528` |
| `docs/reviews/screen-power-rev-l-1072/verify_fabrication.py` | `8e9d752e63a3eed6c0956abfbc9acdcfb5b19801647096424fefa5788c137440` |
| `docs/reviews/screen-power-stock-cost-1072/verify_preserved_usb.py` | `2bd6853f7e298a1d249c39665aa4168c9e8ead8fffc2f183790d236fc6eff0f8` |
