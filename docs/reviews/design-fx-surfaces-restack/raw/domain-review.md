# M2.6 domain review, package subset

Base: `a52fe34d42a719624762f7756518a7e54cf7fd0c`; pending reconstructed original `95dcea0d81` merge. Exact current package file hashes are in `reviewed-package-files-final.json`; scope and amendments are bound in `final-binding.json`. This reviewer authored no implementation, repository tests or fixes. Private falsification probes are excluded from the implementation review.

## Verdict and completeness

No unresolved actionable finding in the reviewed native/package domain subset. This is not whole-candidate approval: app/UI callers remain under repair and require their final freeze; final aggregate/static/coverage, commit binding and current-head remote CI are separate gates.

Read the complete intended package production and test delta, including untracked `output_fx_recipe_test.dart` and the subsequently added preset-kind test, and traced repository recipe submission/confirmation, startup/reconnect, session reset before mutation, capture image ownership, relink and persistence codecs. Reviewed header/generated ABI and native delta separately in `../native-v1/review.md`. Reviewed manifest-driven asset loading, factory metadata parsing and module projection; no claim of individually visual-inspecting every artwork asset or recovered native DSP parity.

## Findings and closures

- Single-entry rack kind loss: explicit required persisted `isRack` now distinguishes identical stripped one-effect sounds. Equality and copy retain it; omission/non-boolean values refuse. Independent three-case probe pins exact encoded round trip and strict refusal. This closes the model defect only; source-kind derivation before stripping and reloaded UI grouping must still be reconciled at final app freeze.
- Malformed preset ingestion: one strict invalid channel tuple threw from `FxUserPreset.fromJson`, aborting all `decodeAll` rows and the Cubit's cached load future. Preserved `preset-kind-probe-v1.log` has two passes and one concrete failure. Current narrow `FormatException` catch drops that preset without weakening engine validation. The unchanged probe now has three passes in `preset-kind-probe-v2.log`. Neighboring valid rows remain available.
- Singleton compound channels and rack boundary ownership: the repaired group helpers retain input plus output writes and carry the original group boundary to the new first/last modules after reorder/removal. Independent pure-model cases pass; no duplicate open finding.

## Independent evidence

`independent_domain_test.dart` was written before reading new author output-chain tests; `probe-v1.log` reports four passes:

1. Rack boundary input, output, pan and level remain exact through module reorder/removal; source entries remain unchanged.
2. Singleton compound channel writes retain both sides; moving B from Pre[A,B]/Post[C,D] yields A,C,D,B with unchanged meaningful metadata; cross-stage reorder refuses.
3. Rack JSON preserves nested data; session output bus 15 round trips, invalid bus types/ranges and duplicates refuse.
4. Actual frozen pumped native engine, four outputs: bus 0 gain .25 and bus 1 gain .75 receive .2. Exact PCM is .25*tanh(.2) on output 0/1 and .75*tanh(.2) on output 2/3, tolerance 1e-6. Distinct pending destinations coexist; second same-destination edit refuses without changing remembered .75; exact acknowledgement settles; bus 16 refuses. Disabled empty output envelope remains represented.

Native pump SHA-256: `31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8`. The five unchanged C arithmetic/callback-partition probes already passed against it; no native rerun or rebuild was performed for the preset fixes. Stock-library tests do not claim real hosted-plugin execution.

Private probe files stayed outside the checkout test tree. The first domain probe command inadvertently allowed dependency resolution; before/after reconciliation shows no dependency, lock or config changes. Only the declared catalogue test and preset-model amendments changed package inputs during this review.

## Architecture and simplicity

Package dependencies remain one-way: looper domain consumes catalogue data and AudioEngine; catalogue contains bundle data/loading without repository or presentation dependencies. Output chains use existing per-target atomic recipe admission/acknowledgement rather than a second queue/compatibility layer. Removed master storage/addressing has a destination-keyed replacement, and retired serialized master addresses refuse instead of retargeting. Session output identity validation occurs before destructive application. Existing exact acknowledgement, deferred capture image ownership and reset behavior remain in the reviewed paths.

The flat entry list plus explicit rack identity avoids a second mutable ordering model. Pure group transforms centralize reorder/placement/boundary behavior. The explicit `isRack` fact is required because entry count and stripped rack identity cannot reconstruct saved kind. No actionable architecture violation or further simplification was found in this subset; no broad style refactor is requested.

## Test quality and observed gates

Author tests were inspected after independent expected outcomes/probes. Output recipe tests assert refusal, distinct target acknowledgement, restart and smaller-session reset. Independent real-engine PCM complements their fake. Rack tests assert exact identities/order and boundary values, not only helper inverses. Preset tests assert explicit kind and invalid-row isolation. Session/performance tests distinguish configured per-output chains from authoritative captured destination facts. Existing parameter no-reset assertions remain intact.

The capacity test amendment changes eight Post entries to `kTrackEffectMax` Post entries plus one Pre entry, retaining length, Pre count and Pre-first assertions. This restores the intended over-capacity fixture at 64; it does not weaken the boundary. Original package aggregate failure is preserved. The catalogue amendment adds display-name Overdrive lookup distinct from its OvDrive power alias, artwork existence and unknown-name refusal. No obsolete granular-call compatibility logs were added.

Observed root aggregate v1: six package suites passed; Looper failed only the obsolete eight-slot fixture. Root reports Looper v2 passed after capacity/kind amendments; final ingestion catch requires its current package revalidation. Do not reinterpret that earlier pass as evidence for changed input. Coverage thresholds and final strict analyzer/Bloc results are pending whole-candidate reconciliation. Native root normal, address-sanitized, telemetry-disabled, race and C++ shim gates passed unchanged native inputs; detailed native scope remains in the native report.

## Exact catalogue limits

Factory assets and the catalogue preserve extracted source identity and raw numeric values. Runtime `fxModuleEntry` projects supported modules into the four native parameter slots; active/persisted instances do not retain every unmapped factory numeric key. These are distinct claims. Root explicitly retains exact parameter schema/native DSP/full native-instance parity as mandatory M6, not completed M2.6 behavior.

The accepted reference completion document's precise open inventories are `unresolvedControls` (239 family/key control type/unit/domain/curve/enum/conditions), factory reset defaults for all 300 family/key identities, and `unresolvedSingles` (26 native Single FX schemas). The separate `unavailableFactoryAudio` inventory has 302 historical names and is a reference limitation; owner decision permits independent sound content. No inferred preset extrema or generic normalized controls certify those missing schemas. Asset/data source preservation does not close these gaps, and this review does not certify them.
