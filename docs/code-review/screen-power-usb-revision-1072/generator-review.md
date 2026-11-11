<!-- cspell:words onsemi checkpointed Littelfuse DPDT AXICOM -->
# Screen-power accumulated generator review

Reviewed 26 September 2026. PR #1080 merge base `5fd9f8bf6856673d07b27054d0b98dd7ba719561` against head `00060494b9af330cb2fbe7834fe9bae04bac65c0`. The head includes the working-source changes inspected during this review.

## Result

No actionable bug was established in the assigned generator/circuit/packaging scope. This is a completed bounded review angle, not a complete PR approval or a fabrication release. Revision M native placement and routing remain explicitly pending, and final artifacts must be rebuilt and verified against the final source.

## Scope and angles completed

Read AGENTS.md, PROGRESS.md build/test guidance, TRACKING.md and the code-review skill. The full screen-power implementation is new relative to the stated merge base. Inspected the circuit generator, schematic serializer, component/model loading, board shell generation, router import/export bridge, finishing/cleanup, electrical and geometric checkers, negative controls, build entrypoint, manufacturing export and atomic publication, source hashing, independent fabrication verifier, BOM and assembly/wiring instructions. The Revision M source utilities were also inspected.

`layout.py` and `route_critical.py` were excluded as requested while Claude authors the pending physical revision. Lifecycle/systemd work, console/ring implementation, shared route/silkscreen implementation internals, rendered assembly inspection and physical qualification are outside this angle. Their integration boundaries were read where the screen-board pipeline calls them.

Completed a line-by-line scan of the assigned executable source, caller tracing, removed-behavior inspection, failure-path review, generated-output checks, dependency/simplicity assessment and source/artifact identity review. No obsolete circuit fallback or validation suppression was introduced. Duplicate initial-pickup calculations and the duplicate suspend dimension were removed without removing the per-channel margin guard or any distinct electrical state.

## Circuit and purchasing checks

- Opposed P-channel Q3/Q4 use G1/D2/S3, joined sources and gates, with a source-referenced default-off pull-up. The negative driver terminates through the optocoupler; it does not directly connect GPIO to the negative rail. [Vishay SUP70101EL](https://www.vishay.com/docs/77632/sup70101el.pdf).
- Q1/Q2 ordering numbers select through-hole E/B/C parts consistent with the shared TO-92 footprint and pin maps. The onsemi documents explicitly include the selected BU suffixes. [2N3904BU](https://www.onsemi.com/download/data-sheet/pdf/pzt3904-d.pdf), [2N3906BU](https://www.onsemi.com/download/data-sheet/pdf/pzt3906-d.pdf).
- TN0702 is S1/G2/D3, matching both series relay switches. U1 uses the specified charge-pump terminals and leaves LV open at 5 V. U2 is anode1/cathode2/emitter3/collector4, consistent with its level-shifting connection. [Microchip TN0702](https://www.microchip.com/content/dam/mchp/documents/APID/ProductDocuments/DataSheets/TN0702-N-Channel-Enhancement-Mode-Vertical-DMOS-FET-Data-Sheet-20005941A.pdf), [TI LMC7660](https://www.ti.com/lit/ds/symlink/lmc7660.pdf), [Toshiba TLP627M](https://toshiba.semicon-storage.com/info/docget.jsp?did=163903&prodName=TLP627M).
- Inspected the cached manufacturer drawing for IM02TS terminal assignment and hole layout in component-side view. Coil 1+/8−, common 3/6 and normally open 4/5 agree with the custom footprint, generator and independently exercised relay-contact model. The normally closed terminals 2/7 remain physically unconnected. [TE IM02TS](https://www.te.com/en/product-1-1462037-3.html).
- Polarized capacitor supply/ground assignments, flyback cathodes, negative-rail clamp orientation, two-wire GPIO harness and four-pin VBUS/D−/D+/GND cable mapping agree across current source, schematic, component records and wiring documentation. The four separate shield pads are GND features and are excluded from purchased parts.
- Purchase BOM and costs cover the same 50 populated references; mechanical holes and bare shield pads are distinguished. External fuse/holder, 16 AWG feed, VH power terminations and XH contact conductor ranges are documented. Cable CC, actual shielding and assembled USB behavior remain explicit qualification limits, not claims established by a four-pin connector or netlist.

## Executed checks

- Disposable SKiDL regeneration: parsed components and every raw net matched the committed netlist; component records, BOM and all schematic bytes reproduced. Circuit ERC reported no errors or warnings. Environment/library search and generation warnings remained visible and were not misrepresented as circuit ERC results.
- Independent native KiCad schematic netlist export: all 58 physical component definitions and semantic net memberships matched the generator output.
- Source pin contracts, numerical calculations and all 13 new USB fault controls passed. The current state model covers 24 distinct AUX/GPIO/host combinations and 48 coil paths; suspend is correctly described as unchanged relay logic with coil energy supplied by AUX.
- Current full validator against the intentionally retained Revision L native board returned `cad_ready: false` with one component-set error and nine pad-map errors. This is the expected hold: the production checker detects the pending Revision M additions/rewiring instead of silently approving stale native copper.
- Atomic package publication was exercised in temporary directories for success, failure while copying, failure installing the prepared package with successful rollback, and failure of both installation and rollback. Successful replacement installs the new complete package; normal failures preserve the previous package; rollback failure leaves its previous-package backup available and reports its location.
- Scoped Python syntax/AST checks and committed whitespace checks passed. No implementation edits were made by this reviewer.

## Validation and artifact-boundary assessment

Validation checks physical pad nets against independently specified circuit contracts and generated schematic/netlist parity. Relay state/contact tests exercise connectivity and directed body diodes rather than only labels. Power-path checks remove overlays and insufficient copper before using native connectivity. Fresh native ERC/DRC failure, unresolved or disabled models, unsupported physical assembly, missing sources, or a changing input snapshot prevent readiness.

Export snapshots production inputs before validation, constructs a complete package separately, hashes delivered artifacts and source inputs, checks that the inputs are unchanged, and only then installs the prepared package. The manifest intentionally excludes its own recursive hash. The separate CAM verifier discovers the input inventory independently, rejects duplicate JSON keys and package symlinks, compares all manifest bytes and source hashes, and regenerates Gerbers/drills independently while normalizing only known timestamp fields. The validation-versus-export documentation-only hash difference is explicitly accounted for.

No new release package was produced or independently CAM-verified during this review because the Revision M native board is not complete. The existing retained package is not evidence for the revised source.

## Material limitations

The electrical state model is an ideal-switch proof with separate DC estimates, not analog transient simulation. Thermal/restart allowances and upright MOSFET heat estimates retain their documented assumptions. No assembled timing, short-circuit coordination, high-speed USB eye/impedance, shield construction or enclosure test was performed. All copper in the retained native board consists of segmented tracks, so the present straight-segment reference sampling matches that representation; future use of native track arcs would require corresponding geometry support.

Independent full-PR review completion, final physical layout review and green CI on the final head are still separate gates. This report alone must not set `review:clean`, `ready-to-merge` or a manufacturing-ready claim.

## Reviewed working-source identity

The following hashes identify the actual files inspected, including changes that were uncommitted at assignment and later checkpointed. They are review evidence, not a replacement for the final manufacturing manifest.

| File | SHA-256 |
| --- | --- |
| `hardware/kicad/screen_power/check.py` | `b68482bb0bd5350531708bda32114d4c0f38c3f8074dbea83a5087ed01a5539d` |
| `hardware/kicad/screen_power/circuit.py` | `5fb3b82bc4f65d7a3bd8ed4abbdba5ffd497cf17e5acc1ffc4ae6eb00957083f` |
| `hardware/kicad/screen_power/cleanup.py` | `250a4ca530796cded61d5d1b660b5d01d1ceff215e0ff44b1265c5a3e19ad93b` |
| `hardware/kicad/screen_power/export.py` | `533651f48a44ecd498c3993e362eb75aaabda1d3d982343b86d88eb718c9f105` |
| `hardware/kicad/screen_power/finish.py` | `22a083c3e1447f7ff5eed84573363e83b716f84c0898ec5ba980a0eb3ce9c63c` |
| `hardware/kicad/screen_power/hand_checks.py` | `92e6f017791bd62e2accb6adf20ade2c4ad0ea7652942574c6d03fb5ae35e655` |
| `hardware/kicad/screen_power/model_geometry.py` | `37b7e49ece74315e77e22654cca75c0bf3113b33001c297ee5f2679da280b288` |
| `hardware/kicad/screen_power/models.py` | `05a76f9c593b361abd51384cf8095b4c864792fd5e229721dea9fec2e11b069a` |
| `hardware/kicad/screen_power/pcb.py` | `c8f2f0c50dee11ce991e081f552d66bb980ca8d55c423a58b8c20a5535cdcf5f` |
| `hardware/kicad/screen_power/router.py` | `37f7cfeac163f80c62a940455b88ea82d4aaec6cb28ea7eea566330795d4cdf7` |
| `hardware/kicad/screen_power/schematic.py` | `a776793ec1552925ad8bb4960f0aadbfe69618d7fed4a7540e35d5fb7b700ecb` |
| `hardware/kicad/screen_power/switch_circuit.py` | `652502f1006b5019752c874b08ff431b5e8bc24cea1dcbf52d50cc513fd23a7e` |
| `hardware/kicad/screen_power/build.sh` | `58c506aaf72675b578f0ad8d7f533877cd2e77b72d9adecd32742643637a6424` |
| `hardware/kicad/screen_power/requirements.txt` | `798e9198f14f2f59acd0cfc3379d64e653314b0e31686caf35097b934f73183d` |
| `hardware/kicad/screen_power/external_bom.csv` | `0381a3f6d5dd4d14d762caabd7251d0696b5a0df5cd89a2824c3d4469ff9322e` |
| `hardware/kicad/screen_power/README.md` | `1515b6451c0aaee1d5f696ac71449202f5a155114630eb4e81ae13d16697be3d` |
| `hardware/kicad/screen_power/COSTS.md` | `da747f673787ef5371141c60024f7bb23c7d77f1c9ef829fc5c85302ee383acb` |
| `hardware/kicad/screen_power/models/README.md` | `c01eebb4cde240416c982427698398da1e166dd69ab5c92f9ce9d03d6824eaad` |
| `hardware/kicad/screen_power/screen_power.pretty/Fuse_Littelfuse_251_P12.70mm.kicad_mod` | `5cd7846fabf79a82b81e8503f8f203e5e40516b349994e894de65137ee79156f` |
| `hardware/kicad/screen_power/screen_power.pretty/Relay_DPDT_AXICOM_IMSeries_Pitch5.08mm_D0.90mm.kicad_mod` | `03f2a2db83addf26f1d2de9c093092cd830871df07a22e9de8aa33b5ccecbc0e` |
| `hardware/kicad/screen_power/screen_power.pretty/TO-220-3_SUP70101EL.kicad_mod` | `9a0eb2bca361f1dfe18d98bbb3e31cea11a32677c154518ec6cf85b90b29fccd` |
| `docs/reviews/screen-power-rev-l-1072/verify_fabrication.py` | `9334570852d447ba818b2e15b548bcfedaa9cb0a2489ee76d869ddd1be196e7e` |
| `docs/reviews/screen-power-usb-revision-1072/verify-circuit-source.py` | `cac1ed9627e9c26e73ffbbfa00492284ffa5ac6e0690b89298d9cbcf60db7259` |
| `docs/reviews/screen-power-usb-revision-1072/impedance-model.py` | `885546038498869f7d1e7df3d52151b9e29f3e7ab91d6febf1bfedf8e8135e04` |
| `docs/reviews/screen-power-usb-revision-1072/impedance-kicad-driver.cpp` | `b5973cc49e1f9ad43a684639a1dac409daebd8632b80b8f538c06f514d3e3096` |
