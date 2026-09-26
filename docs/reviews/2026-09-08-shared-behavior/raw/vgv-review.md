# VGV Code Review

No unresolved Critical, Important or Suggestion findings remain for the reviewed local prototype revision.

## Scope and independence

Reviewed the shared-behavior plan, the transport/host/Loop delta against the supplied pre-change snapshot, the timing scenes and tests, and the new session ownership model, Library dependency flow, host projection/publication, and tests. The later Speed refusal propagation and STOP/MODE dependency-dialog integration are included. Other working-tree edits and processing comparison files are excluded.

This reviewer authored the processing comparison, which is outside this review. This reviewer also authored the earlier session recovery model, capture recovery tests and original read-only publication observer. Their execution here is regression evidence; this is not an independent approval of those authored files. The timing changes and session ownership implementation were authored by other agents.

The checkout is a Flutter/Bloc/native monorepo, but this authorized slice is plain JavaScript design studies using injected host callbacks, node:test/VM harnesses and Playwright. No Dart or native package, dependency manifest, generated binding, real-time callback or production audio path changed in this scope. Existing prototype conventions apply; no new package or framework layer is warranted.

## Regressions, conventions and simplicity

The transport changes reuse the existing scheduler, journal and host publication callback. The added clock argument is carried by both the harness and actual host, so inferred tempo, track content and history publish together. The host constructs the stored candidate before touching live state; a failed write leaves capture, musical state, tempo and history available for retry. Stop publishes the inferred take as stopped.

Count-in shares one deadline across a stopped Start/Stop-all request, respects signature pulses, and is bypassed for external receive or already running music. Sync/Band Auto retains its leading region and closes on a whole primary cycle. Established Multi recovery, sparse length transforms, grouped Clear All and earlier history regressions remain green.

The session module uses an explicit musical allowlist and copies its inputs. It replaces saved musical values over current physical/global state, keeps exact dependency IDs, and returns unresolved requirements without guessing a replacement. The Library owns the pending request and cancellation, while the host owns current inventories and atomic storage. No obsolete compatibility/migration branch, new dependency, speculative settings page, recurring job or undisposed resource was added.

New behavioral tests exercise cancellation, stale source mutation/removal, unavailable controls, publication failure, retries and reload through public model/host seams. Browser tests use normal storage-enabled URLs for behavior and reserve review fixtures for reference captures. Existing assertions were not weakened to accommodate a changed result.

## Resolved during review

- A second Sync/Band recording started while the defining take was still open could miss the primary established by that same command. `start` now closes the earlier take before recomputing its base and primary; both mode regressions preserve the new cycle.
- Auto capture previously counted session beats against a sped, reversed or Once primary without representing that timebase. The draft now refuses unsupported primary playback before capture, also covering independent tempo following. Existing audio is preserved, and the limitation is explicitly documented.
- The initial playback guard could approve a Speed/Reverse change just before the host tick started a queued Auto take. The guard now advances the scheduler before checking; the host and Loop Once/Follow/inherit paths share it. Exact due-start and due-finish regressions pass.

## Verification

Commands ran from the repository root with the bundled Node runtime. Browser commands used the installed Playwright modules through `NODE_PATH` and the local Chrome executable through `ATLAS_CHROME`; these are local prototype checks, not CI.

```sh
node --test docs/design/verify_recording_timing.cjs docs/design/verify_session_field_ownership.cjs docs/design/verify_capture_recovery.cjs docs/design/media-parity-study.test.cjs docs/design/session-recovery-study.test.cjs docs/design/session-recovery-model.test.cjs
node docs/design/verify_audio_state_reconciliation.cjs
node docs/design/verify_stage_transport.cjs
node docs/design/verify_recording_timing_browser.cjs
node docs/design/verify_session_field_ownership_browser.cjs
```

- Combined Node suite: **136/136 pass**: 62 timing, 16 ownership/lifecycle, 21 capture recovery, and 37 media/session recovery cases.
- Existing reconciliation: **10 acceptance contracts pass**. Existing transport script: **pass**.
- Final timing browser suite: **Chrome and Firefox pass**, including stopped/running count-in, Sync Auto cue and leading silence, primary Speed/Reverse/Once/Follow refusal and inherited-setting refusal, inferred-tempo storage failure/retry and reload, with 1920 × 1080 bounds assertions.
- Final ownership browser suite: **Chrome and Firefox pass**, including normal-URL musical/current-physical contrast, incoming FX target identity, touch/encoder and STOP/MODE dependency Retry/Cancel, media repair followed by control checks, failed storage/retry/reload, released held values and offline New Loop/save.
- The final timing run loaded the exact test source and changed only its screenshot output directory to a temporary review directory in memory. All test and geometry assertions executed unchanged. This avoided competing with the suite author's repository image export. No implementation or test source was edited by this reviewer.
- Independently reproduced the due-start race before its fix by advancing only the harness clock, then invoking the playback guard. Final Sync and Band refuse the change after flushing the queued start; the permanent tests now also check a due finish becomes eligible.

During finalization, six tests briefly retained the old refusal-message regex and the new browser Follow case skipped its return to Loop settings. Both test defects were reported, fixed by their owners and rerun successfully. No earlier failing result is presented as final evidence.

## Limits

These are silent, local design prototypes. Tempo inference is duration-based whole-bar interpretation, not beat detection. The Normal speed / Forward / Loop / Follow tempo requirement is an explicit temporary prototype limit pending a capture-timebase decision, not accepted permanent product policy. Primary reassignment/deletion, real sample-clock behavior, native DSP, actual controller detection and appliance storage recovery remain outside this review. Session ownership and physical-connection refusal remain proposals; the capture-tap choice is not settled by these changes. This report does not certify Pen reconciliation, CI, merge readiness or device behavior.

## Reviewed source hashes

| File | SHA-256 |
| --- | --- |
| `docs/plan/2026-09-08-shared-behavior-prototypes-plan.md` | `3c69745d943882f44e498322da0b96dd4f6506b5d5e4980e020c71efe91d4738` |
| `docs/design/stage-transport-study.js` | `ad1022a28f7672385062d961610b75b6a118bb41ca6be48419216af3d99dd20d` |
| `docs/design/fx-ux-prototype.html` | `4419343fd04a62b457678e46706b0163a750fa0b39c54eb511dedeef9480b28a` |
| `docs/design/loop-ux-study.js` | `114752c4276e18d552cc3a8dd2a88ece47d2fd45844cb5bc67352c59e6d6b167` |
| `docs/design/speed-performance-study.js` | `eff0ea1c8cd3234c6f89573bc09d183f6be1c988f71861edd86791621b56667a` |
| `docs/design/recording-timing-scenes.js` | `c4d7dd9d309e498f5284fc506c8c6872a1144f22993274bb802c8b23459bba50` |
| `docs/design/verify_recording_timing.cjs` | `a51e9b05464292caea6079e05b79684c501ce1ec722b7b86977c8429c878230e` |
| `docs/design/verify_recording_timing_browser.cjs` | `37dd189a23969c456265be95c4f2f2f3048b78651a19548bf4d3f324124d9988` |
| `docs/design/session-field-ownership.js` | `d89e7d1d7d6f83075e4da2f838c4512548e2f07288c42fb4e6971bc9192f1932` |
| `docs/design/session-library-study.js` | `5b29dac1756d6ade5d0d0537d9e05e1eccdcc78e5fc81c61d5ac0a2ec07cdf37` |
| `docs/design/session-library-study.css` | `675a3d3ba039fa9b61ad4cce3a255b8bda1a2c85c2e8b3c56d9e34de9ffa1b9c` |
| `docs/design/verify_session_field_ownership.cjs` | `74705dbd128afd4c2d59d30e40a56fcb87b6f2060aa3df03fdc1d9084ac972b4` |
| `docs/design/verify_session_field_ownership_browser.cjs` | `d0974567e41e905da7b8eaed7b3ecea099f05eaae0ac454224348f72c326d132` |
| `docs/design/audio-state-test-harness.cjs` | `7e3839b2bc783e043199961feeff2a32120615778302fadb8dffe4a831d26e15` |
| `docs/design/verify_capture_recovery.cjs` | `de76c06837e5f98073eeae7ac60f2a0893510e8fa67907142d8e646f89d2d591` |
| `docs/design/media-parity-study.test.cjs` | `9698374d0b22375c12c464c3b8b5acd34f43b84c5b6a6c1d1d6371efc35f2cd2` |
| `docs/design/session-recovery-study.test.cjs` | `59461775911185d19ad36ddb4ce120187de1c4690ec308e9c0ac54d68560d1ea` |
| `docs/design/session-recovery-model.test.cjs` | `7b42b59c507225143f4b5a0dfb4f69a7a13337bd13bfdca7e85a0af1d94d4153` |
| `docs/design/2026-09-08-recording-timing-proposal.md` | `f7662ccade0e764893b0893ec3f5b39a64dd30987fea022e59f81afd0c8a82bd` |
| `docs/design/2026-09-08-session-field-ownership.md` | `52f29d31783a38ef7c8a65217f55219d056dfb842d5eb6f7d74d668c74d2aabe` |
