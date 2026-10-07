# Secondary display ownership review

Issue #1115. Base: `5ae3da75d135301ee908e82ef51afb039be9a3fa` (#1114).
Human merge gate retained. Additional Claude review remains pending.

Independent Codex review read the complete four-file implementation, removed
App behavior, context listeners, platform service callers and existing display
tests. Root reviewed the same production changes and regression evidence. All
four frozen source hashes match. No actionable source findings remain in that
review; this is not a completed combined review gate.

Preflight found that a failed platform window close could recursively retry its
own transition and prevent owner disposal from finishing. The correction retires
the attempted intent even on failure, observes transition errors, always closes
the failure stream and handles final disposal errors at the App boundary. Five
owner regressions fail before the fix. A real App unmount regression also fails
before the disposal error handler. The earlier AppRuntime handler is unchanged.

Existing tests retain selected-track waveform identity, event-driven playback position
cadence, trailing delivery, readout deduplication, retry, readiness replay,
startup preference/delay and shutdown presentation. The new owner serializes
window transitions and follows the latest enable/disable intent. No second
playback position clock, generic framework, native API or dependency is added.

Validation: 105 focused tests pass with six conditional skips; the full app
passes 2,869 tests with six skips and 92.172% CI-filtered coverage.
Strict analysis, explicit formatting and a 789-file Bloc scan pass. App shrinks
by 364 lines to 1,236; the extracted owner and failure handling yield seven net
additional production lines across the two files.

The requested read-only Claude attempt ended at its session limit without a
verdict. It is recorded as incomplete, not clean. Keep review pending until that
additional review is complete; current-head CI is a separate gate. No appliance
window, forced process-exit or skipped screenshot guarantee is claimed.
