# Architecture: model/UI

Base: `8749688c51912f808c3f36d4eb5bca665ede3ade`. Revision: the 21 exact working-tree hashes listed in `vgv-model-ui-v1.md`, verified before and after review with no drift. This is a bounded cross-author review of the model/UI producer and the new real-FFI snapshot test. The reviewer authored the runtime and does not certify that runtime here. One reviewer performed VGV, architecture, simplicity, and test-quality roles sequentially, using the complete corresponding workflow-agents role definitions; these are four perspectives, not four independent people.

Authority: repository AGENTS, build/tracking contract, and `docs/plan/2026-10-03-shared-record-timing.md`. No tests or product edits were performed during this review. Aggregate execution, coverage, native gates, current-head CI, saved design verification and final whole-change review are separate coordinator gates. No merge-ready claim is made.

## Result

No actionable architecture findings in the bound scope.

The dependency direction remains presentation → state/typed app binding → repository models. Binding targets depend on the pure timing address/snapshot and established RecordTiming enum. Repository and engine packages do not import widgets or app Cubits. The resolver is an app-side read adapter and contains no storage, engine writes or receipt interpretation. No new package or framework was added.

Cross-file trace: ControlValueTarget strict parsing → availableValueTargets/readValueTarget using the owner snapshot → expressionDestinations grouping/disabled reasons → External/MIDI pickers → local immutable draft replacements → existing Control configuration Save. Endpoints canonicalize actual edits to one of seven enum positions; cancellation intentionally bypasses canonicalization to restore the original draft double. Add/Save has no route to a timing write from these widgets.

The existing application owner is watched rather than constructed inside a picker. Snapshot null is availability, and captureLocked is a temporary edit restriction. The catalogue and callbacks both consult that authority. All nine fixed scopes remain independent of current live track count and Multi mode. Saved unknown/missing target rows remain on the existing repair path. The additional row-label special case removes repeated “Timing · Timing” without introducing a parallel catalogue.

FFI test architecture: only the binding read boundary is overridden. The callback, engine state, API command, publication and projected EngineSnapshot remain real. A one-shot hook clears itself before pumping, preventing recursive interleaving. Engine teardown is registered. This preserves AudioEngine as the production seam and tests the real bridge rather than replacing its result.

Scope limit: application owner lifetime, transaction recovery, native callback and session/shutdown implementation are covered by separate reviewers; they are traced only to establish the callers of this UI.
