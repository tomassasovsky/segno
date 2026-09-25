# Song completion: final old-board simplicity review

Reviewed issue #1077 on 2026-09-24 in
the `codex/live-ten-pills` checkout, against the revised
`docs/plan/2026-09-24-feat-song-pill-completion-plan.md`. This report covers the
current v2 console target: firmware 1.10, protocol 7, ten eight-pixel pills and
one continuous 40-pixel strip formed into a ring. The separate v3 PCB, PD
monitor, screen-power service and private ring UART are outside this target.
No source, device, or commit was changed by this review.

## Simplification Analysis

### Core Purpose

Queue one stopped Song section for the playing section's next loop boundary,
cancel or replace that request, and show its actual remaining-time completion
on the selected pill. Drive the single 40-pixel ring through the current
console's existing output while retaining its encoder and other controls.
The display must not infer an audio handoff from an independent timer.

### Unnecessary Complexity Found

No actionable unnecessary abstraction, speculative feature, or removable
compatibility layer was found in this final target.

- The engine reuses the existing audio command queue and per-track clocks.
  Source, target and the original remaining wait are sufficient for the new
  behavior. One packed atomic value publishes target and progress together
  without locks or a second scheduler.
- Control-side validation and callback validation cover different moments
  in the asynchronous command lifecycle. Queue cancellation on stop, clear,
  capture and lifecycle changes prevents stale requests. The final one-shot
  guard avoids logging a second stop for a section already stopped by an
  earlier source handoff in the same frame.
- Dart forwards the two snapshot fields through existing models. Song
  gestures call the existing play operation; the engine owns queue,
  replacement, cancellation and the actual transition. Projection derives
  LED state rather than maintaining another queue in the UI.
- The firmware calculates partial-pixel coverage directly from the received
  completion byte and established eight-pixel curve. Harness order and local
  left-to-right addressing each have one representation. Existing idle
  breathing is separate from completion and cannot commit a Song handoff.
- The pill renderer's two passes implement the existing whole-chain current
  ceiling: first collect desired colors, then apply one proportional limit.
  Recomputing from desired colors prevents repeated dimming. A fresh 80-pixel
  buffer is justified by this global constraint; no general rendering
  framework is introduced.
- The target retains ring GP12, encoder GP13/14/15 and pills GP18. Ring count
  and brightness are fixed at 40 and 96/255. The v3 ring transport and PD
  protocol were not copied into the old-board implementation.
- The integration corpus uses the existing real-FFI harness, repository,
  control and wire-codec path instead of adding another testing framework.
  It checks the remaining 192 frames of a 256-frame loop, cancellation,
  requeue, REC/PLAY neutrality and the actual boundary transition.

### Code to Remove

None identified. Estimated justified LOC reduction: 0.

### Simplification Recommendations

No implementation changes recommended. Retain the single engine-owned queue,
paired snapshot publication, protocol validation, current limiter and explicit
invalidation. These serve current behavior rather than hypothetical extension.

### YAGNI Violations

None requiring action in this scope. No historical document removal is proposed.

### Validation and Review Boundary

Reviewed the final old-board sketch and C protocol, Dart codec, native
queue/snapshot/control implementation, final one-shot logging guard, test
corpus, firmware tests and CI library changes. Confirmed the native queue,
snapshot/API, repository forwarding and control files are byte-identical to
the completed implementation in the other checkout; reviewed the target
firmware differences separately.

Independently ran `bash firmware/test/run_tests.sh` in this checkout. All four
suites passed: 49 cross-language protocol fixtures, CTRL behavior, the real
80-pixel console sketch including queue fill and 40-pixel ring, and the pill
diagnostic. The tests cover link loss, goodbye, invalid traffic, banks,
orientation, physical button events, partial coverage and the software output
budget. The FFI corpus was inspected; its execution and full native/Dart/build
validation remain part of the coordinator's verification record.

The software output ceiling is not a measured electrical rating. This review
does not establish physical diffuser appearance, audible switching, strip
pinout, thermal behavior or installed firmware/app handshake.

### Final Assessment

Total potential justified LOC reduction: 0%. Complexity score: low to medium,
appropriate to the existing audio and hardware boundaries. Recommended action:
already minimal for the required behavior. No actionable simplicity findings.
