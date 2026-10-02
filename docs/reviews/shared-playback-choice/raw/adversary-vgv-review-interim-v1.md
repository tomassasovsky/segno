# M3.13 independent interim review — VGV conventions

Status: **interim; not a merge gate or final-head approval**. Authors were still editing. No test, analyzer, formatter, build, native rebuild or Git mutation was run by this reviewer in this pass. The independent 50-case harness and frozen oracle remain unexecuted.

Base: `f186bb952d1d000522c5e8e55226bc2ee0931538`. Scope includes tracked changes and untracked Dart product/tests. The 85-path read snapshot is [adversary-interim-source-v1.json](adversary-interim-source-v1.json), SHA-256 `bd274b0fa9ab499fd3973c4ef3319c21c510aae919d061e9ae0cb95cddada2e7`. Earlier 82-path read snapshot SHA-256: `25ef2cb127303c2b7a8eceb73ccf2ba68037d69a6ea59bcb0daae0bd7752f362`. Snapshots are observations of moving source, not an atomic candidate freeze. The unrelated controller-package `build/**` analysis exclusion is preserved but is not approved by this review.

The reviewer read changed app composition/bootstrap/toasts, Playback owner/port, repository receipt/restart/session code, Settings checkpoints, Control MIDI/External dispatch, typed catalogue/resolver/labels, mapping editors, ordinary Playback UI, Session mapping/gate, and corresponding changed/new tests. Generated localization output is not independently reviewed. Findings below do not use author test success narratives as behavioral authority.

## Perspective completed: VGV conventions

Dart/Flutter monorepo, Bloc/Cubit, Equatable, mocktail/bloc_test and very_good_analysis are the established stack. The new pure port is required at composition rather than optional ownerless fallback. UI renders accepted owner state and changes drafts; storage and callback settlement stay below presentation. Existing ordinary write routes are replaced rather than preserved as compatibility aliases. Per-field startup readiness, explicit nullable membership, immutable copied snapshots, and disposal of new streams/subscriptions were checked.

The two startup findings in [the bug report](adversary-bug-review-interim-v1.md) block a clean implementation assessment until verified repaired. No independent convention blocker was established. Formatting/analyzer/Bloc lint are **not run in this read-only pass**; final mechanical results must be bound after authors finish.
