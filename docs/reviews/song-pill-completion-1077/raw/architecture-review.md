## Architecture Review

Scope: issue #1077, the final Song queue implementation and the existing v2 console target described in `docs/plan/2026-09-24-feat-song-pill-completion-plan.md`. The firmware target is 1.10, extending the verified 1.9 ten-pill implementation. This review covers the native engine, C/FFI snapshot, repository and controls, protocol 7, eight-pixel pills, and the single 40-pixel ring. It does not review unrelated hardware changes or authorize a device update.

### Layer Separation

- Violations found: 0.
- The native callback owns Song scheduling and the audible handoff. The app issues commands and projects the native snapshot; neither the app nor the MCU invents a completion timer.
- Snapshot fields pass through `EngineSnapshot`, `LooperRepository`, immutable `TransportState`, control projection, and `PedalStateFrame`. Presentation continues to use the repository boundary; no reverse data-to-presentation dependency was introduced.
- The final `PumpedNativeEngine.snapshot()` correction forwards both Song fields from its native snapshot. This preserves the same published state in the device-free integration harness as in production `NativeAudioEngine`.
- Clean files: all checked files in the intended Song/ring scope.

### State Management Assessment

- Native Song queue: correct. Source, target, and initial remaining time belong to the audio thread; public commands enter through the existing command ring and are revalidated when drained. The additional callback work uses bounded track loops and scalar arithmetic, with no new allocations, blocking I/O, locks, or ownership transfers.
- Atomic publication: correct. Target and progress share one packed atomic value, and snapshot construction reads it once. This avoids pairing a target from one publication with progress from another. Lifecycle resets follow the existing stopped-callback ownership contract.
- Audible handoff: correct. The current source's final sample is rendered before its wrap commits the target. The target starts at frame zero on the following sample; cached per-frame track state does not advance a newly started target prematurely. Handoff logging reflects committed audio changes rather than queue requests.
- Final native corrections: correct. DISARM cancels the queue only when it concerns its source or target, so an unrelated control disarm does not discard a valid transition. The One Shot stop checks the live stopped state after a Song handoff, preventing a second stop event for an old section already stopped during that same frame. Native regression tests cover both cases, including equal boundary timestamps and one stop event per old section.
- Queue lifecycle: correct. Repeat source/target requests cancel; another eligible target replaces the pending target. Stop, clear, capture, mode change, and invalidated content prevent a stale handoff. Capture guards preserve recording/overdub behavior. Song idle play selects one section without changing the other modes' transport behavior.
- Dart controls: correct. Track selection in Song/play requests the native transition. REC/PLAY preserves an already running Song section and pending transition, while parked Song playback resumes one section. Repository equality and copy paths carry the queue fields, and projection validates Song mode, interaction mode, target range, and content before emitting queue feedback.
- Protocol: correct. The old-board C and Dart codecs agree on protocol 7 and the 21-byte STATE payload. Bytes 19 and 20 carry target-plus-one and progress; absent target has zero progress, and 255 is not a valid pending progress value. There is no PD status or new-board UART-ring dependency in this target.
- Old-board firmware: correct. Firmware 1.10 retains GP12 for the direct ring, GP13/14/15 for the encoder, and GP18 for the 80-pixel pill chain. Its physical group order and first-eight reversed local directions remain intact. The ring contains 40 pixels with brightness cap 96. Queue coverage is applied before the unchanged 6000-channel-sum pill limiter, so feedback cannot bypass the budget. MCU queue progress depends only on incoming engine progress. Goodbye and timeout blank all 80 pill pixels and all 40 ring pixels.

### Dependency Direction

- Direction violations: 0.
- The existing native engine → engine data model → repository → controls → pedal state/codec flow is preserved.
- The integration test uses the real C FFI engine, repository, control state, and wire codec through the existing test transport. It does not introduce a production dependency on the test harness.
- No circular dependency, direct presentation-to-native access, new package, or speculative abstraction was introduced in this scope.

### Package Structure

- `segno_engine`: changes remain with engine commands, callback processing, snapshot, generated bindings, and the existing test adapter.
- `looper_repository`: owns the domain transport state and forwards native observations without duplicating scheduling.
- `pedal_repository`: owns state serialization and protocol validation; queue fields remain presentation-independent data.
- Application control: gesture decisions and projection remain in the existing control layer.
- Firmware: the existing v2 board sketch remains the hardware owner. Direct ring driving and DMA pill driving retain their established separation.

### Validation and Final Delta

- Independently ran `bash firmware/test/run_tests.sh` in this target checkout: all four suites passed, including the 49-fixture protocol contract, console controls, real-frame 80-pixel console behavior, and standalone pill behavior.
- Inspected the new deterministic Song corpus through the real native engine and production repository/control/codec path. It verifies initial zero progress, halfway progress over the remaining source time, REC/PLAY preserving the queue, repeat-target cancellation, requeue reset, no early handoff, and the exact final-frame handoff with corresponding LED state. After the test adapter's two missing snapshot fields were added, the coordinator's final captured run reports one test passed with the expected real control events. This test was not merely skipped for an absent native library.
- Compared the shared native and Dart implementation with the final separately reviewed new-board worktree: the shared native core, snapshots, repository, control projection, cubit, and invariants matched byte for byte. The old-board firmware and protocol remain deliberately scoped to its actual pins and peripherals.
- Inspected the native regression additions for invalidation, capture, exact wrap timing, queue publication, and duplicate One Shot stop prevention. Broader native, analyzer, and integration gates remain recorded by the coordinating review; this report does not substitute a source inspection for their execution.
- The electrical figure remains a planning estimate, not a measured current or a power-supply certification. Actual hardware installation and visual acceptance are outside this read-only review. The plan correctly calls for blanking all 40 ring pixels before downgrading to a 24-pixel firmware.

Reviewed source SHA-256 identities:

| File | SHA-256 |
| --- | --- |
| `firmware/console_board/console_board.ino` | `0fc5b6362e4fca913daf5f5f61350a01a89b3c877e434fe1d91249b1bf796da0` |
| `packages/segno_engine/src/core/engine_process.c` | `34256f38c464a6abf4a61c5635a1cbff5324963e72951da2ca9b4f6b52cac3b0` |
| `packages/segno_engine/lib/src/native_audio_engine.dart` | `13bb17f0004dacbcabf514be39b363f4fb013f78503ea1f752b63a75c99d46a7` |
| `test/fuzz/control_sequence_fuzz_test.dart` | `ba36987fe6436cf68ce7e723db3a1d3446566747f4275bfb2bf8d167c22b5522` |

### Verdict

Architecture is clean for the reviewed final old-board target. Critical: 0; Important: 0; Suggestion: 0.
