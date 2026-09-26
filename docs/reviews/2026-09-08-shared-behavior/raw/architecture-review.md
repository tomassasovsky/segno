# Architecture Review

No unresolved Critical, Important or Suggestion findings remain for the reviewed local prototype revision.

## Scope and independence

Reviewed the shared-behavior plan, the transport/host/Loop delta against the supplied pre-change snapshot, the timing scenes and tests, and the new session ownership model, Library dependency flow, host projection/publication, and tests. The later Speed refusal propagation and STOP/MODE dependency-dialog integration are included. Other working-tree edits and processing comparison files are excluded.

This reviewer authored the processing comparison, which is outside this review. This reviewer also authored the earlier session recovery model, capture recovery tests and original read-only publication observer. Their execution here is regression evidence; this is not an independent approval of those authored files. The timing changes and session ownership implementation were authored by other agents.

The checkout is a Flutter/Bloc/native monorepo, but this authorized slice is plain JavaScript design studies using injected host callbacks, node:test/VM harnesses and Playwright. No Dart or native package, dependency manifest, generated binding, real-time callback or production audio path changed in this scope. Existing prototype conventions apply; no new package or framework layer is warranted.

## Layer separation and dependency direction

No layer or dependency-direction violations were found in this scope. `session-field-ownership.js` is a pure capture/projection unit with no DOM, storage, timers, controller dispatch or host import. The Library renders the resulting issues and owns its pending lifecycle through injected callbacks. The existing prototype host remains the composition boundary: it supplies candidate target identities and current inventories, creates one stored rig, and publishes before releasing old live contacts. There is no model-to-host dependency or cycle.

Timing policy stays in the transport study. Loop and performance controls request a playback change through one transport guard; the scheduler decides after processing elapsed time. Timing scenes drive the real prototype transport instead of maintaining a second timing implementation. The tiny clock-publication extension is implemented at the existing edit-state boundary in the real host and harness.

## State management and caller assessment

- **Transport:** stopped-start count-in, primary cycle capture and first-take inference are represented by the existing pending/take/journal state. Candidate construction precedes publication; failed inference/Stop publication retains the active capture and reports retry. Recomputing the primary after the previous take closes removes a stale-state dependency. The primary playback guard flushes due scheduler events before inspecting capture.
- **Ownership model:** capture/project return independent copies and do not modify either incoming rig. Current physical settings and catalogues remain current; saved musical associations preserve exact IDs. `sessionRequirements` describes a dependency rather than configuring hardware. Missing availability evidence does not certify a connection.
- **Session host:** incoming FX IDs are checked against the incoming snapshot; it does not use the old session's module identity or allocate a replacement ID to claim resolution. Fades and momentary MIDI/external parameter values are materialized into outgoing musical state. Successful publication releases gestures and switches before replacing live state; a failed write does neither.
- **Library pending state:** Retry checks current inventories and confirms that the original saved entry still exists unchanged. Media repairs can remain a draft while controls are unavailable. Cancel, Back and unrelated navigation retire the pending recall. New Loop and metadata saves can proceed when controls were already absent from the current setup, without silently certifying a recalled session.
- **Hardware interaction:** the existing STOP/MODE confirmation ownership now includes dependency dialogs. Retry remains blocked while required controls are unavailable; MODE returns to Stage without publishing; reconnecting then retrying opens the intended saved entry.

## Package structure and complexity

The two-function ownership unit has a single responsibility and executable model and host/browser coverage. No new package is introduced, so a new manifest, repository layer, service locator or state-management framework would add unnecessary indirection to the existing design-study architecture. The changed prototype seams remain isolated from the production presentation → bloc → repository → engine structure.

The earlier stale-primary handoff and guard-before-tick problems are resolved. Unsupported capture timebases are visibly refused and documented as a remaining proposal decision, so this review does not mistake symbolic beat timing for a real audio render timebase.

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
