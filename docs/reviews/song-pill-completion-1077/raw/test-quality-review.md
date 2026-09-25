# Test quality review — Song queue and current-board 40-pixel strip

Reviewed September 24, 2026. Final target is the existing console in
`live-ten-pills`; the new-board/XIAO firmware is outside this review's final
scope. No production code or unrelated hardware artifacts were edited by this
reviewer.

## Coverage summary

No missing test file or unresolved test-quality finding was identified in the
intended implementation. The review covers native queue handling, Dart snapshot
and transport models, repository projection, control gestures, protocol 7,
the actual current-board sketch and its physical output buffers.

The coordinator supplied the test runs; this review inspected their logs and
source without duplicating full suites. Earlier equivalent native/app changes
were exercised in the screen-power worktree. The core, control and selected
test files were compared byte for byte after transplantation into the final
worktree. The unrelated PD protocol extension was excluded from the final
current-board target.

Observed final-target evidence:

- Pedal package: 209 tests passed; 534/547 covered lines, 97.62%, above its 96%
  gate. This is the current-board target without the unrelated PD extension.
- Looper repository: 390 tests passed, 11 skipped; 1850/1898 covered lines,
  97.47%, above its 95% gate.
- The new real-native-library corpus test passed, with no skip, in
  the retained integration-test log. The observed run executes the first queue,
  half-wait Rec/Play, cancellation, requeue and boundary handoff assertions.
- Engine Dart package in the earlier worktree: 244 tests passed, 30 skipped.
  That initial run did not
  enable native-library-dependent tests; its Dart coverage alone does not
  measure native audio behavior.
- Initial unfiltered app run: 2257 passed, 34 skipped, 52 failed author-only
  screenshot comparisons. This was a failing run. `dart_test.yaml` explicitly
  identifies that screenshot set as dependent on local fonts/macOS baselines;
  a later run excluding that tag must be reported as such.
- Coordinator reported the final current-board Pico 2 build and four firmware
  suites passing with 49 shared protocol fixtures.

The final package results are retained in the retained pedal-test log and
the retained looper-test log. Their coverage counts were independently
tallied from the current target's LCOV files. The coordinator retains
responsibility for attaching the remaining full validation results to the
consolidated verification report. A clean source-quality review does not replace
those runs.

## Native behavior

The six new native tests use real recorded tracks rather than fabricated
private queue state. Most importantly, the boundary test records distinguishable
sample values and verifies the actual output sample immediately before and
after a wrap, for both source/target iteration orders. It detects a gap,
overlap, early switch or accidentally advanced target.

Additional tests cover remaining-time progress, replacement, repeated-target
and current-source cancellation, stop/clear/undo/capture invalidation, configure
and lifecycle stop, cancellation before a queued command is drained, unrelated
cancellation, invalid targets, one-shot sections, legacy simultaneous sections,
unchanged Free-mode playback and performance-log timestamps. State assertions
support the audible/log assertions; they do not merely repeat the implementation.

## Dart integration and gestures

`EngineSnapshot` and `TransportState` test defaults, native sentinel conversion,
new fields and equality. The repository test verifies that queue progress and
cancellation change transport without spuriously changing tracks. Projection
tests pin concrete wire values, active/inactive banks, queued-target color,
cancellation, handoff and hidden-mode behavior. Invariant tests include deliberate
negative cases rather than asserting only the valid production projection.

Control tests use the project's established Mocktail/Flutter test patterns.
They cover queue/cancel/replace/current-source dispatch, empty/stopped targets,
muted targets, Rec/Play while running, stop/resume, selected-section startup,
bank-B footswitch routing and preserved Record/FX gestures. These command-boundary
tests are appropriate alongside the actual native tests.

The new first corpus test in `test/fuzz/control_sequence_fuzz_test.dart` closes
the cross-layer seam with `PumpedNativeEngine`, the real repository poll,
`ControlCubit`, `PedalRepository` and the real wire codec. Its frame assertion
reads the fake transport's decoded output, not a hand-built projected frame.
Fixture preconditions explicitly assert two 256-frame takes, one playing and
one stopped. Both are parked after capture finalization before starting the
source, so a capture-stop operation cannot silently leave the target playing.
Zero-frame settling drains work without advancing audio. The test distinguishes
half the remaining 192 frames from half a fresh 256-frame loop, then checks
cancel/requeue, unaffected Rec/Play, the last pre-boundary frame and the committed
playing state. The test self-skips without `SEGNO_ENGINE_LIB`; the observed
targeted run used the rebuilt library and passed rather than skipping.

## Protocol and current-board firmware

Dart tests pin bytes 19/20, first/last tracks, progress 0/127/254 and cleared
queue semantics. Both language implementations reject invalid targets,
premature completion and progress without a target. Golden fixtures are shared
across the Dart and C implementations. The final C tests add explicit decoded
Song semantics, every valid target/progress combination, obsolete-length
rejection and malformed-field rejection. This avoids relying solely on a
symmetric encode/decode round trip.

The actual console sketch is compiled into `test_console_pill.cpp`; only
Arduino I/O and LED drivers are substituted. Queue frames pass through the
production UART parser and loop. Assertions inspect the transmitted physical
pixel buffer at empty, partial, half and almost-complete progress, including
the reversed front-row harness, inactive banks, other modes, cancellation,
confirmed completion, goodbye, timeout, corrupt traffic and reconnection.
Advancing device time without a new frame must leave the fill unchanged.

The ring tests pin the existing GP12 output and GP13/14/15 encoder wiring,
40 transmitted pixels, the 96 brightness cap, quarter/full-revolution timing,
half/full/zero gain, goodbye and timeout. Bounds-checked fake pixel access and
all-pixel assertions make retaining a 24-pixel count observable. The existing
crowded-pill tests independently assert the 6000-channel software ceiling and
ensure repeated renders cannot compound dimming.

The combined-current assertion is explicitly a planning model. It verifies
software channel ceilings; it does not measure LED current, copper temperature,
real UART interrupt behavior or the assembled strip. The MCU compile and later
device checks retain those separate responsibilities.

## Resolved review observation

During the in-progress transplant the current-board C test briefly lacked the
new Song semantic and malformed-field assertions. The coordinator added them;
this reviewer re-read the final additions and found the gap closed. No unrelated
PD checks were carried into the final target.

The first real-library corpus run exposed a separate test-seam omission:
`PumpedNativeEngine.snapshot()` reconstructs the native snapshot while supplying
its synthetic live-device flags, and initially omitted the two new Song queue
fields. The production `NativeAudioEngine.snapshot()` already used
`EngineSnapshot.fromNative` correctly. The coordinator added both field forwards
to the pump; this reviewer verified that the change preserves the native values
without inventing progress or queue state. The corrected corpus test passes and
now prevents that omission from recurring unnoticed.

## Verdict

**0 Critical, 0 Important, 0 Suggestions.** The intended test design passes the
quality review. Final execution evidence and physical device validation remain
distinct from this source review; do not describe the initial unfiltered app
run or unexecuted/skipped tests as passing.
