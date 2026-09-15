## Test Quality Review

### Scope and revision

Independent review of the complete intended diff against `origin/master` (`848f1337251989f849c7851f72b6126b5c1712ea`) in `the isolated review checkout`. The tree is the pending integration of the original accepted Tracks slice (`ec3e25f0f5b2b76d8193d9ee437832460df6cfbd`) into that master. This report gives no credit from the later, separately reviewed integration tip.

Read AGENTS.md, the build/test guidance in docs/PROGRESS.md, docs/TRACKING.md, the slice-1 implementation ledger, test-quality role instructions, and both production and test changes. Stack: Flutter/Dart with flutter_test, bloc_test, Mocktail, fake_async and native C/C++ behavioral harnesses. No implementation or Git-ref edits by this reviewer.

### Coverage Summary

- Full root, package, analyzer and native validation are being run by the implementation owner for this exact reconstructed tree. No completed current-head aggregate result or coverage percentage was available when this report was written. Earlier ledger results are historical evidence, not certification of this tree.
- CI thresholds observed: root 90%, looper_repository 95%, pedal_repository 96%. Relevant exclusions remain workflow-defined; no threshold was reduced for this review.
- Changed production concerns have corresponding tests: TracksCubit/view switching; track columns, meters, progress, stage top/footer/scale; selected-track readout and window protocol; repository crown/cache/projection; track models; native crown/snapshot changes. No missing new standalone unit was found.
- Three behavioral gaps remain at native and app integration boundaries despite the existing test files.

### State Management and Repository Test Quality

**Pass with the boundary gaps below.**

- Native crown tests use actual recording/finalize, explicit handoff, clear, undo/redo, clear restoration, device reconfiguration and non-defining finalize. Assertions distinguish an unfinished first take from a completed recording and verify that a later lower-numbered recording does not steal the crown.
- Repository tests independently exercise crown resolution, a one-time pending crown, absence of re-crowning after restart, transport publication, and missing/out-of-range designations. These tests do not mock the crown-resolution function.
- `readTrackWaveform` tests inspect returned samples as well as reads. They cover the full sweep beyond a content change, the completion call, once-per-lap refresh, stopped retention, capture rereads, clearing/forgetting, same-facts replacement after an empty poll, a multiple whose master wraps before the track, and Free mode with no master loop. Call-count assertions express the intended cross-engine read budget and are supported by observable sample assertions.
- `Track` model tests retain live position in full equality while keeping it out of steady properties, and cover progress, recording progress suppression, layer counts and arm-code decoding.
- Tracks view switching uses the real cubit through widget interactions and verifies that playback commands and track selection remain unchanged. Existing focused state-management tests use bloc_test.

### UI Component Test Quality

**Pass with one app-boundary gap below.**

- Queued cue tests discriminate Record, Play, Overdub, Sound, grid and Band section cues using the published trigger rather than record-settings guesses. A tap on a cue reaches the ordinary tile action, and no-pending renders no cue.
- Crown tests cover every looper mode, no crown in an empty state, selection/bank independence, and absence of a crown mutation when its readout is tapped.
- Meter tests cover independently subscribed progress, missing channels, stopped meter behavior and clip-cap timing. Stage tests cover track/wave switching, shared scales, bar counts, footer tempo/count-in/output clipping, and bank browsing without selection changes.
- Selected-track readout tests cover state, muted state, crown, default-name localization, tempo/function/bank, empty/unknown state, lost-device echo, narrow display layout, and the intentionally non-interactive face.
- Window delivery tests retain meaningful failure, retry, superseded delivery, readiness announcement and frame-rate gating assertions. The service tests inspect serialized waveform payloads, but they cannot identify whether App chose the correct source samples.
- UART startup/lifecycle behavior is retained from current master: the real PedalRepository with FakePedalLink receives a HELLO before the Sessions-manager test; its actual button events close the manager. App tests retain stable fallback repository identity, startup window delay, preference changes during startup, and delayed-open cancellation on unmount. Those are bounded local lifecycle tests, not evidence of real UART wiring or appliance performance.

### Findings

#### Important — Assert the selected waveform payload at the App boundary

**Location:** `test/app/view/app_test.dart:138`

The recording window service accepts `samples` but stores only progress and label. The added selected-track waveform test checks read and push counts, while the same-name cursor test uses a fixture with one recorded track and moves the cursor to an absent track. Consequently the tests do not prove that App sends the selected track’s sample buffer and phase: a wrong-channel or mixed-output sample payload could survive the suite. The repository and channel-service unit tests do not connect those two responsibilities.

**Fix:** Record a copy of each waveform sample payload in the test service. Mount an App with two recorded tracks whose waveform buffers and per-track positions differ from each other and from the master output, switch between them (including equal names), and assert delivered samples and progress. Select an empty track and assert an empty payload and zero progress.

#### Important — Assert the new snapshot fields through native-to-Dart projection

**Location:** `packages/segno_engine/test/engine_snapshot_test.dart:165`

The existing tests named “projects every native track field” and “projects scalar fields and the supplied tracks” neither set nor assert `position_frames`, `pending_trigger`, or `output_peak`. The only new outputPeak assertion in this file is a structural field-name golden. Higher layers construct Dart snapshots directly and native tests stop at C snapshots, so dropping or swapping these new fields in `fromNative` would evade both halves. Equality-only differences for these fields are also untested at the engine snapshot boundary, where omitted equality participation could suppress updates.

**Fix:** Populate distinct, non-default native values and assert the corresponding TrackSnapshot/EngineSnapshot fields; include unarmed trigger `-1`. Add equality tests that differ only in each new field and retain equal-instance hash agreement. These should exercise the real generated structs and projection methods.

#### Important — Exercise the new native playhead contract in the nontrivial clock modes

**Location:** `packages/segno_engine/src/test/test_engine_core.c:20312`

`test_snapshot_track_position_and_output_peak` verifies a plain one-loop playing track, a recording write head and an empty track. No other test asserts the newly published `position_frames`. The public contract additionally promises a multiple’s segment offset, a Sync division’s folded phase, Free/Song private-clock position, and holding the last position while stopped. Replacing the publication with master phase or dropping `seg_base` would preserve the current simple-case test while breaking the selected waveform and track progress in those modes.

**Fix:** Extend the existing native multiple, Sync division and Free/Song scenarios with independently expected position_frames values that differ from master phase, and verify stopped-position retention. Reuse the existing deterministic clock/audio patterns so assertions pin the actual read index rather than reimplementing its formula.

### Anti-pattern assessment

No tautological or assertion-free new test was found. The identified App test-double omission is the main false-confidence risk: call counts prove scheduling, not the payload’s identity. Existing source-field goldens serve a separate declaration-level telemetry boundary and are not a substitute for field projection assertions. This report does not treat screenshot approval or historical green tests as behavioral proof of this reconstructed head.

### Verdict

**Fix the three Important test gaps before marking this head’s test-quality review clean.** Current-head validation results must be attached separately; real hardware and remote CI remain outside this report’s claims.
