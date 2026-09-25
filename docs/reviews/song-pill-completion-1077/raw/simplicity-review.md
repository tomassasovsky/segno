# Song completion simplicity review

Reviewed the current working implementation of issue #1077 on 2026-09-24 in
`codex/screen-power-board-1072`, with
`docs/plan/2026-09-24-feat-song-pill-completion-plan.md` as the scope. The older
PCB, power-control and PD-monitor changes are outside this review. No
implementation files, devices, or commits were changed by this review.

## Simplification Analysis

### Core Purpose

Queue one Song section for the playing section's next loop boundary, cancel or
replace that request, expose its actual progress, and render that progress on
the target pill's eight LEDs. The separate ring controller must drive one
40-pixel ring with the existing animation. The display must never claim a
handoff before the audio engine commits it.

### Unnecessary Complexity Found

No actionable unnecessary abstraction, speculative feature, or removable
compatibility layer was found in the scoped implementation.

- The native queue extends the existing audio command ring and per-track
  clocks. It adds one source, one target and the original remaining wait,
  rather than another scheduler or a second time base. The packed atomic
  publication keeps the target and its progress coherent without adding a
  lock or shared mutable UI state.
- Queue validation at command processing, the source wrap and publication
  protects different state transitions. Explicit stop/clear/capture
  cancellation keeps obsolete requests from surviving edits. Control-side
  checks provide immediate API rejection; callback checks remain necessary
  because commands are asynchronous.
- Source selection and stopping all playing sections at commit cover a
  reachable state after recording successive Song sections. This does not
  introduce a migration or a separate older-version implementation.
- The Dart changes pass two fields through the existing snapshot and
  repository model, then project them. The control layer forwards the same
  play operation for queue/cancel/replace; it does not duplicate the engine's
  queue state machine. The small Song branches avoid applying Multi's
  whole-content resume behavior to section playback.
- The firmware computes coverage from the received progress and a fixed
  eight-pixel gradient. It does not add a timer to estimate the remaining
  loop or infer when audio has switched. The physical harness mapping and
  left-to-right pixel mapping each have one representation.
- The two-byte STATE extension and private-link version change reuse the
  current framing and size constants. The 40-pixel ring reuses the existing
  renderer by changing the pixel count, without adding a ring abstraction or
  a second strip.

### Code to Remove

None identified. Estimated justified LOC reduction: 0.

### Simplification Recommendations

No implementation changes recommended. Keep the audio queue ownership,
paired snapshot publication, protocol checks and explicit queue invalidation.
They implement observable requirements and failure behavior.

### YAGNI Violations

None requiring action in this scope. No historical documentation removal is
proposed.

### Validation and Limits

Reviewed the native queue commands, callback handoff, snapshot/API fields,
Dart snapshot and repository forwarding, control gestures and projections,
protocol 7 encoding/decoding, actual console fill renderer, private UART
version 2, ring pixel count, and focused tests for those paths. The native
tests cover both channel iteration orders, actual output samples across the
boundary, cancellation/replacement, invalidation, recording, one-shot mode,
multiple playing sections, other-mode behavior, and committed event logging.

Independently ran `bash firmware/test/run_tests.sh`: all eight suites passed,
including 58 Dart/C protocol fixtures, queue fill in the production sketch,
host-to-ring forwarding, ring rendering/expiry, and the pill-chain diagnostic.
This review did not rerun the full native/Dart checks or real MCU compilation;
their execution remains with the coordinating validation work. The additional
real-FFI integration test being added by the coordinator was not part of this
reviewed snapshot.

Host validation does not prove the assembled diffuser appearance, physical
pixel orientation, purchased ring pinout, or power margin. Those physical
acceptance requirements remain unchanged.

### Final Assessment

Total potential justified LOC reduction: 0%. Complexity score: low to medium,
appropriate to the existing real-time and transport boundaries. Recommended
action: already minimal for the required behavior. No actionable simplicity
findings.
