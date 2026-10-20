# M3.13 independent interim review — code simplicity

Status: **interim; not a merge gate or final-head approval**. Authors were still editing. No test, analyzer, formatter, build, native rebuild or Git mutation was run by this reviewer in this pass. The independent 50-case harness and frozen oracle remain unexecuted.

Base: `f186bb952d1d000522c5e8e55226bc2ee0931538`. Scope includes tracked changes and untracked Dart product/tests. The 85-path read snapshot is [adversary-interim-source-v1.json](adversary-interim-source-v1.json), SHA-256 `bd274b0fa9ab499fd3973c4ef3319c21c510aae919d061e9ae0cb95cddada2e7`. Earlier 82-path read snapshot SHA-256: `25ef2cb127303c2b7a8eceb73ccf2ba68037d69a6ea59bcb0daae0bd7752f362`. Snapshots are observations of moving source, not an atomic candidate freeze. The unrelated controller-package `build/**` analysis exclusion is preserved but is not approved by this review.

The reviewer read changed app composition/bootstrap/toasts, Playback owner/port, repository receipt/restart/session code, Settings checkpoints, Control MIDI/External dispatch, typed catalogue/resolver/labels, mapping editors, ordinary Playback UI, Session mapping/gate, and corresponding changed/new tests. Generated localization output is not independently reviewed. Findings below do not use author test success narratives as behavioral authority.

## Perspective completed: code simplicity

No removal or abstraction request is justified beyond the concrete correctness repairs. The bounded bool address/port and shared endpoint widget serve current default/track targets and all three mapping editors. A separate generalized settings transaction framework would add indirection without reducing the different receipt semantics of Decay and Once. The shared Playback queue is simpler than two nested queues and avoids a compatibility gate alias.

Live and restart vectors, checkpoint membership, revision fences and pending identity are necessary for current Held, Use default, restart and stale-failure requirements; none was classified as speculative state. The default's empty inheritor mask correctly avoids unnecessary native work. Native bool support is reused without new FFI or DSP. No speculative tempo/count-in/length/instrument target was added.

No actionable YAGNI finding or safely removable LOC estimate was established. Overall complexity is material because asynchronous persistence and receipt ownership are material; correctness repairs should remain local rather than trigger a broad rewrite. Final disposition awaits the two startup repairs and final binding.
