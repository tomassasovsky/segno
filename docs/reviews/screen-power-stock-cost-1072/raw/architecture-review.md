<!-- cspell:words unreviewed -->
<!-- cspell:words WIMA -->
# Architecture Review

**Status: source-level delta review complete; no actionable architecture
findings.** Reviewed the working change against
`9f01b49572249e544c84097b574c02f25de851a7` and rechecked the source updates
listed below on 28 September 2026. The earlier obsolete-sheet finding is
closed by direct verification. This verdict covers the recorded source
snapshot; final native geometry, fabrication exports and reviewed PR-head
identity remain separate gates. Cosmetic copper finishing was still underway.

## Detected stack and scope

The affected implementation is Python/SKiDL/KiCad hardware generation and
verification, with CadQuery assembly models and an independent NumPy/SciPy/
Shapely DC analysis. No Flutter, Bloc, native audio engine or firmware code
is changed. No new application package or runtime layer is introduced.

Reviewed the circuit, schematic, placement, critical routing, finishing,
component/model assets, BOM records, validation and publication dependencies.
The final delta includes `check_power`, deliberate-fault coverage, the actual
filled-GND analysis, updated input/load budgets, source-hash discovery and
the ring's local zone-only finishing hook. This review did not run the full
CAD checks, electrical analysis or production export on behalf of their
assigned verification owners.

## Layer Separation

- New violations: **0**.
- `switch_circuit.py` remains the electrical authoring source for references,
  pins, values, MPNs and quantities. The same authored circuit produces the
  netlist, component records and native schematic; placement does not carry a
  second electrical circuit definition.
- `schematic.py` converts that circuit into the seven native sheets and the
  project-local symbol cache. The custom root relay symbol is a generation
  input; the portable native hierarchy resolves through the generated
  `screen_symbols` library.
- `pcb.py` consumes the generated netlist and assets. `layout.py` owns positions
  and reference placement. `route_critical.py` owns critical copper and its
  keepouts; `finish.py` owns board identity, labels and the documented stack.
- The router's constant-width conductors remain distinct from cosmetic zone
  overlays. `check_power` independently strips overlays, narrow conductors and
  signal vias before proving minimum-width connectivity; its expectations do
  not import route widths from the implementation being tested.
- The three-via transition check verifies both annular landings and continuity
  after removal of the first fuse's plated pad. This checks the intended
  parallel transition instead of merely counting via objects.
- The independent GND model reads the filled board in a KiCad subprocess and
  solves geometry in a separate scientific-Python process. It neither saves
  the board nor becomes a hidden input to the circuit generator.
- Ring finishing is a focused function in the existing ring-power module,
  invoked before the normal refill. Named zones make repeated invocation
  idempotent; fixed-anchor assertions expose when its local exclusions need
  reconsideration. No alternate circuit or compatibility mode was introduced.

## State Management Assessment

- **Circuit/BOM state: correct.** F1 owns the two electrical pads of its
  physical holder footprint; `F1_HOLDER` is a separate purchasing row without
  phantom electrical pads. Record checks require exactly that split and reject
  the abandoned branch-clip alternatives.
- **Load allocation: consistent in the reviewed source.** The circuit analysis
  uses 4.25 A screen allocation, a separate 60 mA bleeder allowance, 4.31 A
  switched/contact allocation and 4.46 A total input allowance. The independent
  return-path model carries the same allocations. The 20 mV copper figure
  remains an explicit engineering allowance supported by a separate geometric
  analysis, not a number presented as a direct datasheet guarantee.
- **Reverse-feed behavior: explicit.** Q2's source comment now states that an
  externally powered closed contact can sustain AUX until GPIO is released;
  it no longer implies unconditional source-loss isolation.
- **Historical alternatives: separated.** Removed pump/opto/PMOS parts and
  obsolete models are absent from the active circuit; historical fuse studies
  are marked as superseded rather than exposed as build variants.

### Closed finding: obsolete gate-driver sheet

The earlier Important finding at `schematic.py:55` is resolved. Direct checks
confirmed that `hand/gate_drive.kicad_sch` no longer exists and the generated
root references `relay_drive.kicad_sch`. The active schematic inventory exactly
matches the root plus its six referenced children:

- `screen_power_hand.kicad_sch`
- `relay_drive.kicad_sch`
- `shared_power.kicad_sch`
- `screen1_power.kicad_sch`
- `screen1_touch.kicad_sch`
- `screen2_power.kicad_sch`
- `screen2_touch.kicad_sch`

Thus the exporter's schematic glob cannot pick up that removed active sheet.
The preceding reviewed manufacturing archive is historical evidence, not the
new Revision N export. Verification of the newly published archive remains
pending. The unused `fit_report.py` helper is also absent, with no active
source/build reference left behind.

## Dependency Direction

- New violations: **0**.
- Direction remains circuit definition → generated netlist/schematic/BOM →
  placement/routing → independent verification → staged publication.
- Repeated exact MPN and width expectations in validation are independent
  requirements, not another authoring source. Sharing them with the generator
  would weaken the protection against an incorrect substitution.
- Both the checker and the independent fabrication verifier discover root
  `*.kicad_sym` inputs, so the custom relay symbol participates in provenance.
- The USB-preservation verifier compares explicit baseline geometry, including
  arc midpoints, rather than importing routing decisions from the generator.
- The GND analysis records both board and model hashes, checks board stability
  during its run, and documents that copper/filled-zone changes require a new
  analysis. Native exports therefore still need to be matched to the final
  analysis snapshot after the ongoing cosmetic changes.
- The existing delayed `layout → pcb.point` helper import and `pcb → layout`
  relationship predates this change. No new initialization failure or circular
  package dependency was introduced; an unrelated module rewrite is not
  requested.

## Package Structure

- **Screen-power source:** complete for the reviewed architecture scope.
- The unused fit helper and removed hardware/model paths were deleted; there
  is no unnecessary new package or retained factory-assembly alternative.
- `models/README.md` now lists the eight active custom models, new holder/relay/
  radial-fuse assets, current KiCad models and the limitations of the previews.
  It no longer presents removed DIP/WIMA/SU-A models as fitted assets.
- Scientific dependencies for the independent analysis are documented with
  versions in its assessment. They are not imposed on the SKiDL generation or
  KiCad production runtime.
- Export retains fresh verification and staged replacement with rollback.
  This source review does not claim that the new export has already completed.

## Verification and remaining mechanical gates

- Re-read the repository instructions, build/test guidance and tracking
  contract, and followed the architecture-review role and output contract.
- Parsed all current screen-power Python source modules, including the completed
  critical router and checker, plus ring-power and independent GND-model code;
  syntax parsing passed. Reviewed the added module dependencies.
- Independently compared the root sheet references with every active child
  schematic; inventory matched exactly, and the obsolete files were absent.
- Reviewed fault-injection implementation, including missing/narrow routes,
  overlays, nonuniform widths, transition-via failures, wrong parts and
  assembly geometry. Execution results belong to the separate test-quality
  and native-check evidence, not this architecture verdict.
- Final copper cleanup, DRC/ERC, visual/mechanical review, refreshed GND-model
  results, CAM/native manifests and exact PR-head review identity remain
  publication gates. No ordering, merging, flashing or deployment was performed.

## Reviewed source snapshot

Paths below are repository-relative. SHA-256 values identify the source read
for this final architecture delta, not an unreviewed later modification.

| Source | SHA-256 |
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
| `hardware/kicad/screen_power/models/README.md` | `d0e92a4e4b52d4d99ea2820f088a42c9839f0dbeb8d3ebb13f355b657b6d00b7` |
| `docs/reviews/screen-power-stock-cost-1072/ground-return-model.py` | `cf609b252a0139638f99be15fe1b1e82e3e51e2a9051c8c49a869c60ee509528` |
| `hardware/kicad/ring_power.py` | `2379a6da321e5f1eff7b7ab54198fd075fd2cff5f71adaeccbc9f64245000ff6` |
| `hardware/kicad/route_ring_board.sh` | `d577bcffd0cec82f7d76445143e7daafa0c4e294abe8100f9b8d50a328a68fb7` |

## Verdict

**Architecture is clean for this source snapshot.** Zero unresolved findings.
The earlier orphaned-sheet finding is verified closed. Final native/CAM and
mechanical verification remains pending and is not implied by this result.
