# Simplicity review — screen power revision N

Date: 28 September 2026. Baseline: `9f01b49572249e544c84097b574c02f25de851a7`.
Scope: the working diff and new source for the main-input-holder-only relay
redesign in `2026-09-27-screen-power-stock-cost-1072-plan.md`, including the
final local copper cleanup on the screen and ring boards.

**Final simplicity coverage:** no actionable finding in the source identified
below. The final delta review supersedes the preliminary result. Screen native
SHA-256 is `5335675f9e678028ac6e6aaf61e86330f338137fd15b8a1ff9f16fced52fa6de`;
ring native SHA-256 is
`c53eb16d7531f2c891dc5854faaf40fc1414ebcb2747d0101740e6a35bd1d9ca`.
This role assesses implementation simplicity; fabrication identity, complete
electrical review and hardware qualification remain separate gates.

## Simplification Analysis

### Core Purpose

Replace the unavailable, expensive screen power stage with one normally-open
relay and its coil driver; add a removable input fuse while keeping four
inexpensive soldered branch fuses. Preserve the two USB switching channels,
hand assembly, existing board interfaces and the established fabrication
verification path.

### Unnecessary Complexity Found

No actionable addition of unnecessary abstraction, duplicate implementation
path or speculative feature was found in this snapshot.

- The circuit source contains a single relay-based power stage. The removed
  charge pump, optocoupler, opposed power MOSFETs and their support parts are
  not retained behind a variant or fallback.
- The schematic generator uses the new `relay_drive` page. The obsolete
  generated `gate_drive` page is deleted in the diff.
- The model generator removes the old axial-fuse, bipolar-capacitor and film
  capacitor construction paths. Removed parts' otherwise unused bundled
  models and their DIP license record are deleted.
- The five-fuse helper is small and used by both the input and branch fuses.
  The separate `F1_HOLDER` purchase record avoids adding phantom electrical
  terminals merely to represent the holder in the BOM.
- Explicit current paths, bend coordinates and narrow local control routes
  remain in the established routing module. A new generic routing framework
  would add indirection without helping this fixed board.
- The new state, BOM, exact-part and lead-fit checks are tied to concrete
  redesign risks. They should not be removed to reduce the checker size.
  Independent expected MPNs and pin maps intentionally duplicate design
  facts so a source error cannot change its own expected result.
- Mutation helpers consolidate repeated native-board loading and validation
  without removing the missing-copper, narrow-run, via-bypass, clamp, fuse
  and wrong-part fault cases.
- The USB snapshot verifier has a distinct purpose: it compares the new
  board with the preserved native baseline, including arc midpoint geometry.
  It is not redundant with checking the new board against its own sources.
- The temporary `fit_report.py` diagnostic is removed. No additional
  standalone placement checker is retained in the production source.
- The broad source-file discovery replaces a manually maintained Python
  filename list and includes the new local symbol library in release identity.
  Generated SKiDL cache files remain excluded.
- The final AUX junction fillets derive their boundaries from actual route
  polygons, with assertions that the three intended junctions still exist.
  This directly serves the requested smooth copper while retaining the
  separately checked constant-width track backbone.
- The four screen corner cutbacks share one calculated outline. The two ring
  exclusions are local zone-fill corrections in the existing power module,
  guarded by their retained anchor positions and reapplied idempotently.
  Neither introduces a second route representation or a generic smoothing
  framework.
- The ground-return model uses established geometry and sparse-matrix
  libraries to assess actual copper. Its extraction subprocess separates the
  KiCad runtime from the numerical dependencies. The mesh and material inputs
  serve the documented sensitivity runs rather than speculative variants.

### Code to Remove

None recommended. Estimated additional LOC reduction: **0**.

Historical engineering evidence under `docs/` is retained. Explicitly marked
superseded calculations are not treated as active build alternatives.

### Simplification Recommendations

Keep the existing module boundaries.
Do not introduce a shared generic CAD framework or reduce independent fault
coverage as part of this cost reduction. No additional refactor is required
by this review.

### YAGNI Violations

None found in the reviewed changes. Existing single-variant APIs that were
not introduced by this diff are outside this review's change scope.

### Coverage and Verification

Read the repository instructions, build/test guidance, tracking contract,
implementation plan and the complete changed Python hunks for the circuit,
schematics, placement, routing, model generator and circuit/native checks.
Read the new USB preservation and ground-return tools in full. Checked the
active Python sources for obsolete power-stage identifiers and distinguished
generated, ignored SKiDL caches from committed build sources. The final pass
also covered the changed relay shutdown explanation, labels, bleeder
placement, explicit power feed and via positions, three AUX fillets, screen
ground outline, ring cutbacks and their build integration. The removed
placement diagnostic is absent on disk.

AST parsing passed for the thirteen Python files below. Shell syntax passed
for `route_ring_board.sh`. Independently matched the frozen native hashes and
read the final native validation report: no errors, **103/103** self-tests
passed, with its tested board and checker hashes matching this
snapshot. This role inspected that existing validation result rather than
rerunning it. No rebuilding, layout edit, DRC run, export, stock query,
firmware action or production-readiness assertion was performed by this role.

| Reviewed source | SHA-256 |
| --- | --- |
| `hardware/kicad/screen_power/switch_circuit.py` | `72c0c706f7298d194569806b32284a39cfc7b02fa3d36c6b1a3faadc5e12b163` |
| `hardware/kicad/screen_power/schematic.py` | `5d4356322e5d0f190c92d1af7712cb81b6f745068332f335d14eed9e3f9e5b17` |
| `hardware/kicad/screen_power/pcb.py` | `d4db56c2412406ebf920c8d1722b34609a33b8306d710611cd5fbf4d6237335f` |
| `hardware/kicad/screen_power/layout.py` | `6e94a961db8a0847ccf647fc2cacab0fe910985cb9bcff7d4175fe22182c5742` |
| `hardware/kicad/screen_power/route_critical.py` | `3c266e0f7c65929dabf300215e09c8b7862bc343ef0e33f1eb805b6a6c2787dd` |
| `hardware/kicad/screen_power/model_geometry.py` | `b448d868aa12ddf28f510d90d8f27c431a3c4cc9e41360d621cb7632c593890c` |
| `hardware/kicad/screen_power/check.py` | `67d4be849c73d427cad1deefe5f4f013ef7336a31ad96bcab78c216861f8d8f9` |
| `hardware/kicad/screen_power/hand_checks.py` | `22587020dcc0eb8752515aea0cec7394579709fe5a017ea0edd604335799a842` |
| `hardware/kicad/screen_power/finish.py` | `773db3f89ec5b67df9c43bab298e57dfa62a6c98cb5026ec894a8b09d4706417` |
| `hardware/kicad/ring_power.py` | `2379a6da321e5f1eff7b7ab54198fd075fd2cff5f71adaeccbc9f64245000ff6` |
| `hardware/kicad/route_ring_board.sh` | `d577bcffd0cec82f7d76445143e7daafa0c4e294abe8100f9b8d50a328a68fb7` |
| `docs/reviews/screen-power-stock-cost-1072/ground-return-model.py` | `cf609b252a0139638f99be15fe1b1e82e3e51e2a9051c8c49a869c60ee509528` |
| `docs/reviews/screen-power-stock-cost-1072/verify_preserved_usb.py` | `2bd6853f7e298a1d249c39665aa4168c9e8ead8fffc2f183790d236fc6eff0f8` |
| `docs/reviews/screen-power-rev-l-1072/verify_fabrication.py` | `8e9d752e63a3eed6c0956abfbc9acdcfb5b19801647096424fefa5788c137440` |

### Final Assessment

Critical: **0**. Important: **0**. Suggestion: **0**.

Total potential LOC reduction: **0%**. Complexity score: **Medium**, mainly
the necessary domain checks and explicit routing geometry. Recommended
action: **Already minimal for the reviewed requirements.**
