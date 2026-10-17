# Revision O simplicity review

## Simplification Analysis

### Core Purpose

Replace J101/J102/J201/J202 with five-position JST XH connectors. Pins 1–4
retain their existing functions; pin 5 carries each cable shield to board
GND. Remove TP101/TP102/TP201/TP202 and their special cases while preserving
the power circuit, two-layer board, USB routing constraints and hand assembly.

Reviewed the working delta against
`add2748edce2c274e931e7fc3c524d1695d1ea2c`, using the approved Revision O plan.
This closes out the circuit, schematic, model, validator, placement,
critical-routing, finishing, BOM and documentation source roles at the exact
hashes below. Deferred low-speed native routing, finished-board checks and
publication remain coordinator-owned gates. The local project override was
excluded. Missing final Revision O publication artifacts are known pending
work, not findings in this pass.

### Unnecessary Complexity Found

None unresolved in the stable scope. The initial review identified the retired
zero-quantity filter at `hardware/kicad/screen_power/switch_circuit.py:184`.
The author removed it before closeout. All component records now flow to the
BOM, consistent with the independent validator's quantity-one contract; the
separate input fuse holder accessory remains.

### Code to Remove

None remaining. The author removed one obsolete conditional expression from
the BOM generator during this review.

### Simplification Recommendations

1. Keep the independent native, circuit and purchasing fault controls. Native
   geometry checks detect missing/duplicate terminals, incorrect pad geometry
   and footprint identity. The netlist checks cover all four shield contacts.
   The purchasing mutations deliberately keep generated records mutually
   consistent while violating the independently selected connector contract.
   These checks protect distinct boundaries and should not be collapsed into
   generator-derived expectations merely to shorten the validator.

### YAGNI Violations

No unresolved YAGNI violations were identified in the stable scope. No new
configuration mechanism, compatibility branch, dependency or general-purpose
abstraction was added for this change.

The removed shield-pad exceptions in `models.py`, `pcb.py` and `schematic.py`
are correctly deleted. References to the old pads and four-pin connector in
the validator are negative controls, not compatibility behavior. Historical
documents and references to four-pin parts still needed by other boards are
not obsolete active screen-board support paths.

### Validation and Limits

- Parsed the five stable changed Python sources with `ast.parse`; all pass.
- Inspected generated `hand/components.json`: 46 records, all quantity one,
  with none of the four removed shield-pad references.
- Verified the final unfiltered BOM projection equals the prior filtered
  projection and the generated purchase BOM; the holder accessory remains.
- Traced the generator, schematic grouping/BOM flags, model exemptions, native
  connector checks, circuit contract, part-record contract and new fault
  controls.
- Read the active wiring, harness BOM, component-cost and model instructions
  for unnecessary compatibility or duplicate assembly paths.
- Did not regenerate hardware or run a full native DRC/ERC pass during active
  authoring. This report is a simplicity review and does not establish the
  final manufacturing or assembled-device verification gate.

### Final Assessment

Total remaining potential LOC reduction: 0% identified.
Complexity score: Low for this delta.
Recommended action: Already minimal. Unresolved actionable simplicity
findings: **0**. The source role is complete at the listed hashes; final native
routing/fabrication and publication verification remain separate. Reinspect
any later source changes before applying this verdict to them.


### Placement and Routing Closeout

The new layout uses the existing one-board placement function and bounded
channel coordinates. Sharing `POWER_PLUG_Y` with finishing removes a real
label/placement drift risk without adding configuration. The four removed
shield-pad placements, visibility exceptions and decorative-ring removal are
deleted rather than retained as alternate supported behavior.

The routing change supplies new bends to the existing `flow`, `curve` and
fixed-width `track` helpers. It does not add another router, compatibility
path or post-export copper patch. The moved cathode and pin-one silk markers
are narrow native-footprint edits required by the actual fitted geometry;
a generic marker-placement framework would add complexity here.

Inspected the unchanged build, router, cleanup and export boundaries. Critical
and USB routing remain independent of deferred low-current routing, and final
checks/export still run after native finishing. Independent circuit, geometry,
BOM and source-immutability checks protect different failure modes; no check
removal is justified by this connector change. The existing final project
serialization is excluded from this source delta, and this reviewer preserved
the unrelated local project override.

Parsed all eleven listed Python sources and repeated the component-record
comparison during closeout. No new simplification issue emerged. Final native
DRC, filled-ground analysis and fabrication output are not inferred from a
clean simplicity review.

### Reviewed Source Identities

Paths are relative to `hardware/kicad/screen_power/`.

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
