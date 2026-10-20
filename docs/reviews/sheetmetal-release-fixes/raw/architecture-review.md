## Architecture Review

Reviewed the working tree against `1d14d701ee9f6c3ad304a63fc60a79e3681afbd1`, including the new native-export script, reference/cache manifest, regression tests, plan and release record. The changed stack is Python, CadQuery/OpenCascade, ezdxf and the Autodesk Fusion API. The repository's Flutter presentation and state-management layers are unaffected. No Fusion operations or output regeneration were performed by this review.

### Layer Separation

- Import/layer violations found: 0.
- The existing enclosure generator owns dimensions, flat geometry, generated part geometry and vendor packaging. The Fusion-only exporter stays behind a serialized file handoff and does not force the normal generator or tests to import `adsk`.
- Supplier references and assumed cable clearance are kept outside the fabricated-part packages. The native formed assembly contains the intended metal parts.

### State Management Assessment

- Generator/file handoff: one important source-of-truth issue at `hardware/enclosure/fusion_export_formed.py:65` (producer at `hardware/enclosure/segno_enclosure.py:5244`). The export gate validates hard-coded T2/R2/K0.33 and only the number of folds, while the authoritative generator hashes bend angles, directions and sheet-rule values. It does not compare the actual native fold parameters with those authoritative values. The deferred formed-drill gate similarly counts nine circles without checking their positions, axes or radii.
- Concrete failure: leave the CUT/BEND/DRILL sketches unchanged and edit a healthy Fold feature from the specified angle to 1 degree. The current exporter sees the same sketch curves, rule and feature count, then writes a new native STEP and signs it with the current flat checksum. The downstream volume/bounds checks compare that STEP with measurements of the same wrong native solid, so those checks cannot establish agreement with the bend table.
- Reproduction: ran the unmodified exporter through a temporary fake Fusion API whose components had the expected sketches and counts but whose `bendLines[].bendAngle.value` was 1 degree for every fold. It printed `Verified formed exports: segno_base, segno_faceplate, segno_corner_bracket_rear` and wrote the manifest. This is a boundary-level reproduction of the uninspected parameters; it is not a claim that the currently saved Fusion models are wrong.
- Fix: include the current sheet rule and per-fold geometry/angle/direction in the serialized handoff, verify the corresponding native feature definitions before writing the manifest, and check the formed-drill dimensions and axes against the intended stations. Keep feature-to-source checks insensitive to the documented different native fold ordering.

### Dependency Direction

- Import cycles or reversed package dependencies: 0.
- Clean dependency flow: generator geometry → DXF/handoff → Fusion export → formed STEP/manifest → generator assembly/package validation.
- The issue above is an incomplete validation boundary within this flow, not an argument for adding another package or an abstract CAD service.

### Package Structure

- Existing enclosure module: no unnecessary package/dependency added.
- Native export helper: appropriately separate because it runs inside Fusion; the normal Python path remains usable without Fusion installed once the verified native sources are present.
- Test directory: covers measured fits, manufacturing layers, stale cache detection and eight-part assembly. The parent reported the five regression tests passing; this reviewer did not rerun the geometric suite while the parent was verifying outputs.
- Physical release holds are clearly distinguished from digital validation in `RELEASE_REVIEW.md`. The unanswered rear-panel gauge choice does not need to be resolved to prepare and review the local implementation.

### Verdict

Fix one important handoff-validation issue before using the exporter as the stated geometry verification gate. No other actionable architecture findings.

### Re-review addendum

The handoff-validation finding is resolved in the revised implementation.

- `write_formed_input()` now serializes the authoritative T/R/K rule, each signed bend angle tied to its source BEND line, and front-hole X/Z/radius/through-depth stations.
- `_native_forming()` reads native `FoldFeature.bendLines`, their actual angle parameters and centered-line setting. It reads the formed holes from world-context cylindrical faces instead of trusting the deferred sketch count. The area filter excludes partial cylindrical corner reliefs.
- `_validate_forming()` compares these measurements before any STEP or manifest output is written. Matching folds by source geometry allows the documented native modeling order to differ from the shop bend sequence.
- Independently ran `test_native_verification_rejects_wrong_rules_bends_and_drilling`; it passed. This accepts the captured native measurements and rejects seven mutations covering sheet thickness, bend angle/direction/source, hole position/radius and a blind-hole span. No output regeneration or Fusion operation was performed by the reviewer.
- The Fusion imports now occur inside Fusion-dependent functions, allowing the pure validation boundary to be exercised directly in the existing test environment without a fake application.

Updated verdict: architecture review clean for the reviewed correction; zero unresolved findings. Physical fabrication-release holds remain as documented and are outside this digital validation verdict.
