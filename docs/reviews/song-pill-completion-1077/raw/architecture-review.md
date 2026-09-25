# Architecture Review

Scope: issue #1077, the Song next-loop handoff, engine-to-pill completion
state and single 40-LED ring. Existing PCB, screen-power, PD and unrelated
firmware changes were not treated as new work in this review.

## Layer Separation

Violations found: 0.

The new state follows the existing native engine → FFI snapshot → looper
repository → immutable transport state → control projection → pedal
repository/codec path. Control gestures call the repository's existing play
operation. Presentation does not import native clients or own a second queue.
The MCU receives completion data and has no timer or command that can claim
an audio handoff has happened.

Checked files include the native engine command, process, lifecycle and
snapshot implementations; native API and generated bindings; Dart
`EngineSnapshot`, `TransportState`, `LooperRepository`; the control cubit,
projection and invariants; Dart/C pedal codecs; and both MCU targets.

## State Management and Real-time Ownership

The engine retains source, target and initial remaining-frame count on the
audio thread. Public play calls validate available atomic state and enqueue
through the existing command ring; the callback revalidates before accepting
or committing. No new callback allocation, lock, blocking I/O or unbounded
operation was introduced. Queue validation is bounded by the fixed track
count, and publication performs one fixed-width integer calculation per block.

Target and normalized completion are packed into one atomic 32-bit value.
The snapshot decodes both from the same load, so they cannot describe two
different queued requests. Mutable private queue fields are not read from
Dart or the control thread. Lifecycle clearing follows the existing stopped
callback ownership contract for configuration and device shutdown.

Queue cancellation and replacement remain engine operations. Repeating the
target or requesting a playing section cancels; a new stopped target replaces
the queue against the current source's next wrap. Starting from idle resets
only the requested Song section instead of invoking whole-rig unpark.
Stop/clear of either endpoint, undo-to-empty, arm/record activity, mode reset,
configuration and device stop invalidate the queue. Callback validation also
rejects stale endpoint states and active captures.

The source's final sample is mixed before wrap commits the handoff. The
target starts at position zero for the following frame. The pre-mix state
array prevents the target clock being advanced by the rest of the old frame,
independently of source/target channel ordering. Performance logs record
committed STOP/PLAY at the audible boundary rather than recording queued or
cancelled requests as immediate playback.

## Dart Behavior and Dependency Direction

Direction violations: 0.

Transport and snapshot fields are immutable and participate in equality,
allowing changed progress to propagate normally. Song playback gestures use
play for queue/cancel/replace; Multi mute membership is not reused as queue
state. Song Rec/Play resumes one section while parked and does not expand a
running song to all stopped sections. Record and FX gesture meanings remain
separate.

The pure projection shows only a valid Song playback queue and derives its
0–254 wire completion from the engine fraction. It does not predict the
handoff. The corresponding invariant checks the projected target, completion
and green queue indication against engine state. No new packages, reverse
dependencies or persistence layers were introduced.

## Protocol and Firmware

Protocol 7 consistently uses a 21-byte STATE payload. Dart and C agree on
target encoding (zero means none; 1–8 identify tracks) and reject completion
255 or nonzero completion without a target. Generated FFI bindings include
the new native snapshot fields with matching types and placement.

Console firmware 2.1 renders completion on the logical target in the visible
bank. It applies the approved centre curve to partial left-to-right coverage,
then uses the physical harness map, including the reversed front row. Queue
rendering is gated by Song and playback mode. Only a later engine state can
replace the partial fill with normal playback indication. Cancellation,
goodbye and the existing host lease do not leave independent animation state.

The private ring link is version 2 with payload and frame capacities derived
from the canonical STATE length. Both peers use the same codec and framing.
The ring target addresses 40 pixels and scales its existing arc/comet behavior
through `RING_N`, retaining the 128 brightness cap and link-loss darkness.

## Verification Evidence

This reviewer independently ran `bash firmware/test/run_tests.sh`: all eight
suites passed, including 58 C/Dart protocol fixtures, actual console queue
rendering and 40-pixel ring behavior. Native tests were inspected for exact
audio output across the boundary in both channel orders, cancel/replace,
endpoint invalidation, capture protection, lifecycle reset, one-shot behavior,
Free-mode non-regression and committed performance-log timestamps. Dart
tests were inspected for gesture routing and snapshot/projection semantics.
The coordinator owns the broader native, Dart and real-MCU build run; this
report does not claim those were independently rerun here.

Mechanical compatibility of the purchased 40-LED ring and assembled-device
timing/current remain physical verification, as stated by the plan. Host
checks do not establish those properties.

## Reviewed Source Identity

- Native process SHA-256:
  `c2b5158ed64fd21caf6bd3b26945b412d10b8c22e6c7cc6460ba8502e1e665cd`
- Native snapshot SHA-256:
  `9b2961ffa5f55b3a65cb5e14e9816d3d36e2e440bec898c4bf2c3c74177b4acb`
- Control cubit SHA-256:
  `38b58942e236d8ed04569f842aad0276c3a8c0646be8764944355148ffea574a`
- Control projection SHA-256:
  `5f1f201adba1af615515d61bca70ff8789ef77fe925d219038d7c2db47a453ee`
- Console sketch SHA-256:
  `1dfd5e6d1ba50add8c054d447d91726b9e7b58949762e7472978b7ca56695a27`
- Ring sketch SHA-256:
  `cc8da87ec32c35927af05018b5dc5afe03bc3e461c45679b2a808febf4e9506e`

## Verdict

Architecture and scoped correctness review are clean. No Critical,
Important or Suggestion findings. No implementation or device changes were
made by this review.
