# M3.12 Decay — five quality perspectives

One independent reviewer completed the five requested perspectives over the current intended Decay source and changed/new Dart tests. This is not five independent agents and does not replace root's final bug-focused review. No actionable in-scope finding remains. PR readiness is explicitly incomplete pending publication and exact-head CI.

## Scope and binding

Base `8b740c093b7ae84fb36c19fac88914246d6278b3`; product freeze v1 SHA-256 `3dfbd25ca44dab2b4f204dc8a1b9ab105a76b7f3b3a8fdfb23a4817dbecb3d02`. All 25 intended product files were read, including the new pure port, call sites, removed paths and native/repository surroundings. Changed/new Dart tests were read completely, including the final External expression provider correction and five import-order changes. `five-perspective-source-binding.json` binds 76 product/test/plan/workflow/config paths plus the five role reference hashes; SHA-256 `fca48e766b219d45206dbbedf10e9941ed07457c6167f4e34be947747f4bb422`.

The original and final test diffs are retained as `review-test-diff.txt` and `review-test-diff-final.txt`. Test fixtures changed during this review under the coordinator's separate ownership; final deltas were reread. Product hashes remained frozen. No native API, generated FFI, firmware, dependency or workflow threshold change belongs to this slice. The pre-existing local `packages/controller_repository/analysis_options.yaml` build-directory exclusion is outside the approved product manifest and was preserved, not endorsed as a new gate change. Pen and screenshot artifacts are coordinator/author visual evidence, not independently visually certified here.

## VGV conventions — completed, no actionable finding

Presentation reads the shared PlaybackOptions owner and sends intents; it does not access Settings storage or an audio client directly. The required DecayControl seam is narrow and explicit. Typed DecayAddress, immutable DecaySnapshot and DecayOutcome express address/membership, accepted values and failure states. Zero remains a real value rather than an unavailable sentinel. The App creates one owner, supplies it to both Control and ordinary UI paths, and closes Control before the owner.

Storage recovery is visible through the established toast/failure path; expected refusals use outcomes. Streams, queued writes and close are covered by lifecycle logic and independent close execution. Localized labels distinguish Loop controls from FX destination kinds without expanding the global FX enum. Existing large Control/App files were assessed by changed responsibility and callers, not flagged solely by size. `git diff --check` passed. This reviewer did not rerun the coordinator's full analyzer/bloc/coverage gates and makes no independent claim about their counts.

## Architecture — completed, no actionable finding

PlaybackOptionsCubit is the single Decay transaction owner. Its `_write` serializes checkpoint/write/readback/native publication and compares captured lifetime/revision across waits. It owns separate live and durable projections; LooperRepository stores only primitive confirmed restart intent. SettingsRepository owns exact scalar checkpoints and serialized verified restore without importing app state. The pure port prevents controllers from depending on the concrete PlaybackOptions implementation.

Use default travels as nullable ordinary intent, not a fabricated effective numeric value. Control checks per-address origins before admission and after real acceptance; `_supersedeDecayClaims` removes only that address. Pure MIDI row supersession preserves source toggle/contact state and detaches stale proposals. Ordinary writes and source claims therefore share one owner without a second hidden persistence authority.

Session capture nests existing Mixer, Click and Decay locks in one order. LooperPersistFlush waits the separately tracked ordinary Decay writes. App shutdown cuts ingress first, recovers only on explicit Retry, repeats retirement for owed cleanup and checks final owner flush before halt. Startup validates all nine values before applying; restart includes all eight nullable track overrides. No callback blocking, allocation or lock is added to native real-time code; existing immediate atomic setters remain the acceptance boundary.

## Test quality — completed, meaningful coverage with explicit limits

Added repository/settings tests cover exact absence/zero, restart projection, refusal and malformed input. Owner tests cover pending storage, mutate-then-throw compensation, recovery blocking, independent Once readiness and stale replacement failures. Shared-dispatch tests exercise source order, ordinary/reset intent and retained cleanup. App/Looper tests verify persistence barriers and visible failure/Retry behavior. Session tests inspect actual saved bundles where a native library is provided. UI journeys assert authored ranges and absence of audio preview, rather than relying solely on screenshots.

Some author dispatch tests use FakeAudioEngine, and inherited UI fixtures use an unavailable FakeDecayControl for unrelated controls. Those are appropriate seam tests but are not native DSP proof. The independent 51-case run adds real owner/repository/native behavior, actual PCM and Session file output. The successful isolated inverse-law negative control proves the sample checks detect the intended mapping error. Initial independent fixture errors and their corrections are fully disclosed in `independent-execution.md`; they are not product regressions or silently discarded runs.

Author-only screenshots require fonts and are separate from ordinary CI. Native-gated Session tests skip without SEGNO_ENGINE_LIB. Root reported a first aggregate with 20 External expression provider errors, corrected the shared-owner fixture and reran it; this reviewer inspected that final provider delta. Root's aggregate and coverage are separate evidence, not inflated into this reviewer's independent test count. Full live-Control Session Load/M5 and the omitted oracle permutations remain open limits rather than assumed passes.

## Simplicity — completed, no actionable finding

The change extends the existing Playback owner, scalar Settings keys and shared dispatch ledger. It adds no compatibility target, session schema, generic inheritance engine, callback-receipt poller or future control family. A narrow public port and per-address revision are justified by the existing independent Control and ordinary UI consumers and the equal-value reset race. Separate restart intent is necessary to prevent temporary Held values replaying at startup. Serial exact-checkpoint compensation is necessary because storage can mutate before throwing.

No speculative abstraction or removable duplicate owner was identified. The separate expression destination enum resolves an actual non-FX destination requirement without widening the FX contract. Further generalization across Mixer/Click/Decay would obscure their different receipt and persistence semantics and is not required by this slice.

## PR readiness — review completed; final gate pending

The local product snapshot has no actionable finding in this review and passes the independent 51-case suite plus meaningful N1 sensitivity. `git diff --check` is clean. Required-constructor fixtures and the final expression provider correction were inspected without relaxing product behavior or thresholds. The approved plan is present; root owns the final portable evidence, tracking, intended staging, Pen verification and publication.

This is an uncommitted frozen snapshot review, not current published-head CI approval. The coordinator must bind the final commit, complete required workflow checks and root's bug-focused gate, and preserve existing human/device authorization boundaries. No `review:clean`, `ready-to-merge` or merge assertion is made here. Any later product delta requires review of that delta; unchanged evidence can be reused only with exact hash correspondence.
