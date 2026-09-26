# Test Quality Review — recording, render, and sound completion

Date: 2026-09-09

## Scope and independence

Reviewed the September 9 browser-prototype recording, selected-render, and sound-behavior delta against the coordinator's saved pre-pass baseline. Existing large files were reviewed only at the changed seams: recorder destination/capture tap and checkpoint publication; shared Bounce/Save render planning; storage capacity and transfer navigation; sound-example playback lifecycle; and the corresponding host adapters. The new selected-render and sound modules were read in full. Audio Library review is limited to the common-render integration; its separate destination-identity implementation has another independent reviewer.

The reviewer authored the timing-completion implementation, timing tests, frozen-capture guards, Stage cue, and primary/first-take foot routing. Those changes are explicitly excluded from this independent verdict. Whole-file hashes identify the checked revision; they do not widen the reviewed scope. Unrelated existing working-tree changes, Pen/video work, Dart, engine, firmware, and hardware behavior are excluded. This is local browser design evidence, not native recording or appliance validation.

## Coverage summary

- Independent Node run: **18 passed, 0 failed, 0 skipped** across `verify_selected_render_policy.cjs` and `verify_performance_recording_model.cjs`.
- Independent final host journey: `verify_recording_completion_browser.cjs` **passed in Chrome and Firefox** with no page errors.
- Node coverage for the three instrumented model modules: **97.64% lines, 90.37% branches, 93.94% functions**. No separate JavaScript-prototype coverage threshold is configured in this repository.
- Per-module coverage: performance-recording model 100% lines / 90.48% branches; selected-render policy 88.46% / 89.74%; sound-behavior audio 100% / 90.91%. The uncovered selected-render lines 22–24 render controls exercised by the browser journey. These browser checks do not supply numeric line coverage.
- VM-loaded recorder-study coverage was not emitted by Node's coverage reporter. Its behavioral checks ran; no numerical study or whole-host coverage claim is made.

| Reviewed unit or integration | Behavioral evidence |
| --- | --- |
| Performance recording model and study | Existing 12 model/study cases exercise multipart allocation, validation, recovery, quota/publication refusal, retry, and discard accounting. The new host journey covers USB selection, stable drive identity, disconnect during finalize, slow writes, low/unknown capacity, exact checkpoint recovery, and capture-tap persistence. |
| Selected-render policy | Six render/audio cases include common cycles with fractional lengths, explicit duration, independent sources, Once ending in silence, selected processing/level, optional shared FX, and invalid/capturing sources. |
| Sound audio model and study | Model assertions distinguish the resulting heard/recorded samples. Browser assertions cover Play, explicit Stop, changing the selected example, automatic completion, and Back navigation. |
| Bounce and Save render adapters | Policy tests establish a shared recipe; the browser saves an explicitly chosen render duration with shared Mix FX and verifies the resulting recipe and seconds. |
| Recorder host/storage seams | Normal storage URL exercises USB/internal ownership, exact retry, reload metadata, unavailable capacity, switching settings away from a missing old drive, and View transfer navigation. |

No newly introduced unit in the bounded scope lacks behavioral tests. Existing modules are not counted as wholly re-covered by this delta.

## Test patterns and assertions

The design studies use Node's built-in test/assert modules and the established Playwright browser harness. Seeded cases call real model/study or host actions. Controlled clocks drive checkpoints and completion rather than relying on wall-clock sleeps. Browser resources are closed in `finally`; fatal errors produce nonzero exit status.

The important assertions check durable asset metadata, exact preserved multipart descriptors, catalogue ownership, reload state, rendered audio samples, and actual browser audio-source disposal. The tests do not duplicate the common-cycle calculation to derive their expected answer. Browser persistence checks use the normal storage URL; the Save render and sound demonstration sections use explicit review fixtures and make no normal-session persistence claim.

## Verified mutation checks and resolved gaps

All mutations were injected into temporary copies/browser resource overrides. Reviewed product sources were not edited during review.

| Mutation | Initial result | Final result |
| --- | --- | --- |
| Replace exact common-cycle calculation with the longest selected duration | Rejected by the render model test: expected 12 seconds, received 6. | Rejected. |
| Hardcode the published recording asset's capture tap to before-final-controls | Earlier tests checked pending capture state but allowed the final metadata regression. | Coordinator added final asset, USB catalogue, reload, and default-tap assertions. Final browser suite rejects the mutant at line 10. |
| Remove the actual audio node stop call while still clearing the UI playing flag | Earlier browser checks accepted a stopped-looking UI while the audio source remained active. | Coordinator added observable AudioBufferSourceNode stop-call assertions for explicit Stop, choice change, and Back. Final suite rejects the mutant at line 26. |

Both verified test gaps are resolved. The final unmodified suite passes both browsers after the added assertions.

## Anti-patterns and recommendations

No unresolved tautological assertions, tests of substituted implementations, silent skips, or missing async completion checks were found in the bounded test delta. No further change is requested for this slice.

## Reproduction

Run from the repository root with the established Node and browser runtime:

```sh
node --test --experimental-test-coverage \
  --test-coverage-include='**/selected-render-policy.js' \
  --test-coverage-include='**/sound-behavior-audio.js' \
  --test-coverage-include='**/performance-recording-model.js' \
  --test-coverage-include='**/performance-recording-study.js' \
  docs/design/verify_selected_render_policy.cjs \
  docs/design/verify_performance_recording_model.cjs
node docs/design/verify_recording_completion_browser.cjs
```

The browser command expects the documented prototype server plus Playwright and Chrome environment configuration.

## Verdict

**Pass for the bounded local design slice.** Critical: 0; Important: 0; Suggestion: 0. No whole-audit, CI, native-audio, or merge-readiness claim is made.

## Checked file hashes

| File | SHA-256 |
| --- | --- |
| `docs/design/selected-render-policy.js` | `0c9dd6be59b07b31d467b470b12dc4a091a0bedf68bd94c925cb2e894b0e507b` |
| `docs/design/selected-render-policy.css` | `9fee2f48a23fbe55562b5ee4a6c456675d9180cd0ede903aeaadcbfb64a84f82` |
| `docs/design/sound-behavior-audio.js` | `f801e7883fe004e6dbc780dcd3cb7ae4847fa21ad87887faab7df1f8af75e678` |
| `docs/design/sound-behavior-study.js` | `a66d8a314b93cdaf2ff09b29d25513cef462c27573b8091ccdbf1861d5cee969` |
| `docs/design/sound-behavior-study.css` | `3164c6112edea4f6a0fb218c9624ff03a7ad8fc3c31a7c02a5b1e53c62139445` |
| `docs/design/performance-recording-model.js` | `e57e0694d46a70fd11ec50446541f3ddeef42ee5954f34914129139119a85856` |
| `docs/design/performance-recording-study.js` | `602952defaa2785fd9525b0b1f55332ade59bef7faef28e49926919958a380d6` |
| `docs/design/performance-recording-study.css` | `23920303eec7a9dda75fdf8766cc46f1f2b8458bff8ba9ff34f0eda2def53917` |
| `docs/design/bounce-performance-study.js` | `d9ad2d4382d6f2b47028021cfb0fe8d18c0ebf504031745f770f0851041bcbbb` |
| `docs/design/audio-library-study.js` | `c95a6e09ce50a02cdde226c6488c4f29ee234de280c475fafdc4b291f0dd770b` |
| `docs/design/storage-study.js` | `ecbd437d64ba0858007bce7ff0fcd3857e76123f7c7cb5f61a59627d176122f2` |
| `docs/design/midi-sync-study.js` | `3ed47aaee2328eb2aff1ebdb5869981c9e2530ed3a1546d090db478ac3bf039f` |
| `docs/design/fx-ux-prototype.html` | `483ac9fe67deb2eec9384487b3440e0c74019ec23b2507b3d0ffc57dad04997d` |
| `docs/design/verify_selected_render_policy.cjs` | `5c247ce8b578ebca0c67e34fd5ada1b50c250b4ea4972bc765e0363892390f74` |
| `docs/design/verify_performance_recording_model.cjs` | `33d8f9a7dadb4abbbe01eefad60655392098e1e91cd09d9ce064c4e595634cee` |
| `docs/design/verify_recording_completion_browser.cjs` | `0f56e01f5d4830414d2009046bb62eec8a8c798d1cef58466dfd444416563cfe` |
