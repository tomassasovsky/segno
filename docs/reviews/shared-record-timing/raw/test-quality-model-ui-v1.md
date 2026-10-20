# Test quality: model/UI and FFI snapshot regression

Base: `8749688c51912f808c3f36d4eb5bca665ede3ade`. Revision: the 21 exact working-tree hashes listed in `vgv-model-ui-v1.md`, verified before and after review with no drift. This is a bounded cross-author review of the model/UI producer and the new real-FFI snapshot test. The reviewer authored the runtime and does not certify that runtime here. One reviewer performed VGV, architecture, simplicity, and test-quality roles sequentially, using the complete corresponding workflow-agents role definitions; these are four perspectives, not four independent people.

Authority: repository AGENTS, build/tracking contract, and `docs/plan/2026-10-03-shared-record-timing.md`. No tests or product edits were performed during this review. Aggregate execution, coverage, native gates, current-head CI, saved design verification and final whole-change review are separate coordinator gates. No merge-ready claim is made.

## Result

No actionable test-quality findings in the bound scope. No existing behavior assertion was deleted or weakened. This is a source-quality conclusion, not a fresh execution or coverage result.

Pure target tests assert exact canonical JSON keys, strict malformed/extra fields, track8 rejection, NaN rejection, clamp endpoints, one-step spacing and the literal0.249/0.25 boundary. The enum roundtrip loop is supplemented by these independent expectations. Resolver/catalogue tests assert all nine fixed scopes, absent owner behavior, explicit Immediately versus inherited Bar, and capture identity retention with a disabled reason.

UI tests use real RecordTimingCubit and SettingsRepository with a repository seam whose accepted tuple/readback are coherent. External button current/current and expression/MIDI0/1 defaults are asserted after actual Save. Saved configuration before Save remains unchanged. The tests check displayed musical labels and verify Add/Save does not invoke a timing transaction. Expression tests cover a Multi track, capture-disabled editing without deleting authored0.2/0.8 endpoints, and repair followed by keyboard preview/Escape/Save retaining exact0.2/0.8. Existing general draft cancellation and editor lifecycle tests remain present.

The root-authored `record_timing_snapshot_test.dart` addresses a distinct FFI race: a real callback publishes a different tuple immediately before the first standalone native track read. The first returned Dart snapshot must retain the old revision/default/all-eight override vector `[-1,0,6,-1,-1,-1,-1,-1]`; the next must contain the new revision/default/vector `[4,-1,0,5,-1,-1,-1,-1]`. It asserts that interleaving actually occurred, checks actual receipt results, and does not calculate expected vectors with the production normalization helper. Removing the full-snapshot override in the Dart bridge would mix the new track values into the first result and fail these literal assertions. Resource disposal and one-shot callback clearing are explicit.

That test intentionally skips without SEGNO_ENGINE_LIB. The current workflow was traced: its native-backed job requires a nonempty built library and runs the entire segno_engine package, so the regression is durable CI coverage rather than only a local optional test. The two screenshot generators still require author fonts; they are visual evidence and are not counted as ordinary CI assertions.

Limitations: this reviewer ran no tests and did not reproduce producer logs. The coordinator must bind observed whole-app/package coverage and CI to the final source. Runtime writer tests, native preflight F2 and flush F1 are not independently certified here because this reviewer authored them.
