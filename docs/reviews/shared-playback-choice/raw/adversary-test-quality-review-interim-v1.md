# M3.13 independent interim review — test quality

Status: **interim; not a merge gate or final-head approval**. Authors were still editing. No test, analyzer, formatter, build, native rebuild or Git mutation was run by this reviewer in this pass. The independent 50-case harness and frozen oracle remain unexecuted.

Base: `f186bb952d1d000522c5e8e55226bc2ee0931538`. Scope includes tracked changes and untracked Dart product/tests. The 85-path read snapshot is [adversary-interim-source-v1.json](adversary-interim-source-v1.json), SHA-256 `bd274b0fa9ab499fd3973c4ef3319c21c510aae919d061e9ae0cb95cddada2e7`. Earlier 82-path read snapshot SHA-256: `25ef2cb127303c2b7a8eceb73ccf2ba68037d69a6ea59bcb0daae0bd7752f362`. Snapshots are observations of moving source, not an atomic candidate freeze. The unrelated controller-package `build/**` analysis exclusion is preserved but is not approved by this review.

The reviewer read changed app composition/bootstrap/toasts, Playback owner/port, repository receipt/restart/session code, Settings checkpoints, Control MIDI/External dispatch, typed catalogue/resolver/labels, mapping editors, ordinary Playback UI, Session mapping/gate, and corresponding changed/new tests. Generated localization output is not independently reviewed. Findings below do not use author test success narratives as behavioral authority.

## Perspective completed: test quality

**Execution/coverage: not run and not measured by this reviewer.** Root reserved execution until freeze and slot release. Test inspection cannot substitute for green execution or final-head CI.

The new scalar tests distinguish absent/false, discarded writes and malformed values. Repository receipt tests exercise matching bits before drainage, inheritor masks, all-Custom no-command changes, partial admission, durable restart, and cancellation. Owner transaction tests cover blocked reads, malformed last slot, held projection, callback wait, wrong bits, autonomous timeout, compensation failure, shared queue order and close drain. Source dispatch tests use actual Control and owner/repository with a controllable AudioEngine and actual MIDI/External paths. Those fake-engine tests do not prove real native receipt or audible Once behavior; the independently prepared real-native probes address that separate gap.

Root integration fixtures inspect real Session Save As/Save bundle output with native snapshots, and App power-off pending ordinary writes, refusal/Retry/Keep playing, held cleanup and late MIDI ingress. These are meaningful behavior assertions. Save output does not establish full live-Control Session Load; inherited M5 remains a stated limit. The deleted direct repository-forwarding Bloc assertion is superseded by the new actual Bloc → owner → storage flush/reset fixture.

The later snapshot adds ordinary native-free editor journeys: button endpoints initialized from accepted Loop/Once, draft-only Save/Cancel, Escape rollback, unavailable row repair preserving endpoints, expression full range, MIDI range editing and reversed-range repair. New screenshot fixtures depend on screenshot fonts and are author render evidence, not ordinary CI proof. Their assertions are not counted as a substitute for the user-journey tests.

The two initial findings expose coverage gaps in combinations: malformed startup plus independent native recovery, and device replacement during the **first** delayed read (the earlier stale-write test loads successfully first). A regression for each is necessary. A1's added source test was inspected after the repair; no pass is claimed. Final 50 independent cases and negative control still await authorization.
