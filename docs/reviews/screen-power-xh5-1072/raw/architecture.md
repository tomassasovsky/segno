# Architecture Review

Status: architecture source-role closeout complete for the exact source hashes
below, including the Revision O placement, critical-routing and finishing
delta. Final low-speed native routing, fabrication evidence and publication
remain separate coordinator-owned gates; this report does not approve an
unexported manufacturing archive.

Review date: 2026-09-28. Baseline:
`add2748edce2c274e931e7fc3c524d1695d1ea2c` (Revision N). Scope is the working
Revision O delta for issue #1072 and the approved
`docs/plan/2026-09-28-screen-power-xh5-1072-plan.md`.

## Layer Separation

- Violations found: 0 in the stable sources inspected.
- `switch_circuit.py` remains the authority for the circuit graph, physical
  component records, purchasing BOM and connector identity. It now creates
  four `Conn_01x05` parts with the B5B-XH-A footprint and MPN. Terminals 1–4
  retain their previous nets; terminal 5 is GND.
- `schematic.py` serializes the same SKiDL graph. `pcb.py` consumes the
  generated netlist and places library footprints. Neither adds an alternative
  electrical definition for the shield connection.
- `check.py` independently pins the connector MPN, footprint, exact five-pad
  numbering, grounded terminals 4/5, single-row pitch and absent TP references.
  Keeping these acceptance rules independent of the generator is appropriate:
  generated artifacts can agree with one another while all being wrong.
- The schematic sheet/BOM special cases and the board/model exceptions for
  the removed shield pads are gone. Old B4/TP identifiers retained in fault
  controls exercise rejection; they do not retain an old generation path.
- The export path still checks native inputs and hashes their sources before
  publishing a staged package. No new export or rendering layer is introduced.

## State Management Assessment

Flutter/Dart state management and presentation conventions do not apply to this
Python/SKiDL/KiCad hardware-generation change. Review instead traced the
generated circuit, netlist, BOM, footprint/model selection and independent
acceptance checks.

A read-only semantic comparison of `hand/components.json` against Revision N
found exactly four changed records (J101/J102/J201/J202), exactly four removed
records (TP101/TP102/TP201/TP202), and no additions. Every other component
record, including every power-stage part and main-power VH connector, is
identical. Each changed connector retains terminals 1–4 and adds only the
GND terminal 5 alongside the XH5 value/footprint/MPN changes.

## Dependency Direction

- Direction violations introduced: 0 in the stable sources inspected.
- No dependency manifest changed. The implementation uses the existing SKiDL,
  KiCad Python, shared netlist parser and model-validation utilities.
- The new connector uses the established KiCad footprint/model library rather
  than introducing a custom connector abstraction or another CAD dependency.
- The B4 STEP model is removed and the B5 STEP model carries upstream model
  identity and attribution. The generic `JST_XH*` attribution entry covers it.

## Package Structure

- `hardware/kicad/screen_power`: existing responsibilities remain coherent;
  no package or speculative configuration was added.
- Active circuit, component records, BOM and harness documents agree on four
  XHP-5 plugs, twenty USB crimp contacts, pin 5 as shield, and separate main
  power on VH. Unknown donor dimensions and assembled qualification remain
  explicit requirements rather than implied verified facts.
- Stale active wiring references to selected 28 AWG donor leads were reported
  during review and corrected by the coordinator. Reinspection confirms the
  wiring now states the 500 mA allocation and unknown donor dimensions.
- The obsolete quantity-zero bare-pad exception was reported and removed.
  Reinspection confirms that every component record now requires one instance
  and the expected purchasing references include every record plus F1_HOLDER.
  A coherent quantity-zero record/BOM fault is part of the existing independent
  selection checks. The coordinator reports 35/35 power-source checks passing;
  this reviewer verified the corrective source without repeating that run.

## Verification and Limits

- Read AGENTS.md, the PROGRESS build/test section, TRACKING.md, the approved
  plan and the requested architecture/review-agent instructions.
- Inspected the stable source delta and its calling/build/export boundaries;
  parsed the five stable Python sources with Python AST parsing.
- Compared generated component records semantically against the named base.
- Did not run generators, modify implementation, modify the unrelated local
  `.kicad_pro` override, run hardware tests or claim assembled qualification.
- Independently inspected the completed placement, critical-routing and
  finishing source delta during closeout, plus its unchanged build, router,
  cleanup and export callers. Final low-speed native output, strict-project
  verification and manufacturing artifacts were not complete at closeout and
  are not claimed as verified here.

## Verdict

Generator and routing-source architecture are consistent with the approved
XH5 migration. Unresolved actionable architecture findings: **0**. This
completes the source role at the hashes below, not the final native-board,
fabrication or assembled-device qualification gates. Reinspect a later change
to any listed source before applying this verdict to it.


## Placement, Routing and Export Closeout

- `layout.py` owns the two output-plug ordinates through `POWER_PLUG_Y`;
  `finish.py` consumes the same values for the corresponding legends. USB
  header origins and data-relay placement remain unchanged. Q5, R7, R5 and R6
  move only through the existing placement function, not through an export
  patch or separate undocumented native-board transform.
- `route_critical.py` derives endpoints from each placed pad, verifies same-net
  endpoints in its join helpers, and adjusts the existing fixed-width power
  and coil paths around the longer headers. The critical paths remain locked;
  neither their declared widths nor the USB pair generator was weakened.
  Final physical clearance and ground-return performance need the native
  checks and numerical evidence rather than an architecture inference.
- The established build order remains circuit → placement → critical paths →
  constrained low-current routing → finishing → rounded low-current turns →
  cleanup → independent checks → export. `router.py` restores full-precision
  USB copper after SES import; finishing and rounding explicitly exclude the
  eight USB data nets. No second authority for their geometry was added.
- `check.source_hashes` includes all screen source Python, native inputs,
  shared routing/silkscreen helpers, custom footprints and models. `export.py`
  verifies before export, stages outputs away from the previous package and
  checks those input hashes again before publication. The new source files
  participate in these existing boundaries automatically.
- Project serialization in finishing and cleanup is pre-existing. The local
  project override was not modified by this review; release checking must use
  the strict tracked project in a staging copy, as arranged by the coordinator.
- Parsed all eleven Python sources listed below with `ast.parse`. Repeated
  semantic component-record comparison: 46 remaining quantity-one records,
  exactly four changed USB headers and four removed shield pads, no other
  changed component records. No package/dependency manifest was changed.

## Reviewed Source Identities

Paths below are relative to `hardware/kicad/screen_power/`. These identities
cover the source-role verdict; they are not manufacturing-output identities.

| Source | SHA-256 |
| --- | --- |
| `check.py` | `710d3338539c5adaa29772745c4defb32a55c9169fad2e22f971f0f2190f794b` |
| `switch_circuit.py` | `5e57a93f50c19db41cf1f736c355b5eb2e2b066ceee0d23f38f9d76b11f10083` |
| `schematic.py` | `ea1bafa3f74fa7f62fe056744117a227fb3b0d599be30b72104afa27b9596aaa` |
| `models.py` | `3a49e950a8323db0a4fb9b73273ba7039b286eb79383243f4d95f9fa8dbf6db6` |
| `pcb.py` | `8d5cd800d4897b65dfe6ba16f45a4f581ab09f4b7be6ccdb06dcc42a610d8d4f` |
| `layout.py` | `db565369bdd15123f820ab8da278cc872dd4d1fe1cb247f67d4455addc84f9db` |
| `route_critical.py` | `122349034a52435cc863c7703c7cba790e9b39021e042fb9197b8b13f98805b1` |
| `finish.py` | `402676c0d4904665d2817cc0ea0fc1ebdbdb6a70ce6c77b01354cf1813905cb5` |
| `build.sh` | `58c506aaf72675b578f0ad8d7f533877cd2e77b72d9adecd32742643637a6424` |
| `router.py` | `37f7cfeac163f80c62a940455b88ea82d4aaec6cb28ea7eea566330795d4cdf7` |
| `cleanup.py` | `250a4ca530796cded61d5d1b660b5d01d1ceff215e0ff44b1265c5a3e19ad93b` |
| `export.py` | `533651f48a44ecd498c3993e362eb75aaabda1d3d982343b86d88eb718c9f105` |

The final comment-only `route_critical.py` cleanup was independently re-read.
It removes stale numeric prose about a pad corridor and a corner sweep; all
reviewed route coordinates, widths, layers and flow calls remain unchanged.
The source identity above includes that cleanup. No new findings.

Final visual closeout also inspected the two silk-only source edits: the Q5
reference moves to `(8.5, 20.3)` and CTRL moves to `(7.5, 18.4)` horizontally,
clearing R7's body. These edits affect reference/legend text placement only;
no circuit, component placement or routing source changed. The source hash
map includes both edits. No architecture or simplicity findings.
