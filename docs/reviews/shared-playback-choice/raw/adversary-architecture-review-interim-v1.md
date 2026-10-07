# M3.13 independent interim review — architecture

Status: **interim; not a merge gate or final-head approval**. Authors were still editing. No test, analyzer, formatter, build, native rebuild or Git mutation was run by this reviewer in this pass. The independent 50-case harness and frozen oracle remain unexecuted.

Base: `f186bb952d1d000522c5e8e55226bc2ee0931538`. Scope includes tracked changes and untracked Dart product/tests. The 85-path read snapshot is [adversary-interim-source-v1.json](adversary-interim-source-v1.json), SHA-256 `bd274b0fa9ab499fd3973c4ef3319c21c510aae919d061e9ae0cb95cddada2e7`. Earlier 82-path read snapshot SHA-256: `25ef2cb127303c2b7a8eceb73ccf2ba68037d69a6ea59bcb0daae0bd7752f362`. Snapshots are observations of moving source, not an atomic candidate freeze. The unrelated controller-package `build/**` analysis exclusion is preserved but is not approved by this review.

The reviewer read changed app composition/bootstrap/toasts, Playback owner/port, repository receipt/restart/session code, Settings checkpoints, Control MIDI/External dispatch, typed catalogue/resolver/labels, mapping editors, ordinary Playback UI, Session mapping/gate, and corresponding changed/new tests. Generated localization output is not independently reviewed. Findings below do not use author test success narratives as behavioral authority.

## Perspective completed: architecture

No new package dependency direction violation was found. Presentation reaches Settings and audio through the existing repositories/owners. One application-owned PlaybackOptionsCubit implements the narrow Decay and OneShot ports. Control retains the shared accepted-source ledger; the new owner does not introduce a competing holder arbiter. Repository live/restart vectors are primitive data and keep app types out of the package. Session receives explicit durable snapshot functions and one Playback exclusivity function.

The shared queue's initialization reads run outside it; one Session gate awaits both initializations before queue acquisition. The gate's operation reads durable data directly, so it does not wait for a field setter on its own queue. Ordinary track flush tracks admitted owner Futures. New OneShot receipt timers cancel on settlement, replacement and disposal. No native API/header/FFI or real-time callback implementation changed, so no new callback allocation/locking path was introduced.

The startup-validation and first-initialization lifetime holes are localized ownership defects, documented in [the bug report](adversary-bug-review-interim-v1.md). Repair them within the current owner; no second Playback owner, global registry, new persistence blob, or generalized settings framework is warranted. Architecture approval remains interim pending repair re-review.
