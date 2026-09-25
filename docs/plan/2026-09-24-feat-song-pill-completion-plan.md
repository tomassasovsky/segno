# Song queue completion and 40-LED strip ring

Tracking: [#1077](https://github.com/tomassasovsky/segno/issues/1077).

The owner approved the completion simulation and clarified the target is the
current old v2 console. Firmware 1.10 extends the working 1.9 ten-pill version,
retaining its pins and controls. The ring is one continuous 40-pixel WS2812B
strip bent into a ring, with data out disconnected.

## Implementation

1. Use the existing real-time Song play command to queue a stopped section and
   transfer playback at the playing section's next wrap. Repeating the target
   or source cancels; another target replaces it. Stop, clear and capture cancel
   stale queues. Publish target and completion as one coherent snapshot value.
2. Pass the snapshot through the native bindings, repository and control state.
   Song/Mute track gestures queue sections. REC/PLAY does not replace a queue;
   after a stop it resumes one section. Other modes retain their controls.
3. Update Dart and C to protocol 7, STATE 21 bytes: byte 19 is target + 1 (zero
   none), byte 20 is completion 0..254 with denominator 255. No queue requires
   zero completion. The MCU never infers an audio handoff from elapsed time.
4. Fill the queued eight-pixel pill left to right over remaining loop time,
   retaining the approved centre curve, harness order and 6000-channel budget.
   Drive 40 ring LEDs on GP12 with brightness capped at 96/255; encoder remains
   GP13/14/15 and the 80 pill LEDs use GP18 PIO/DMA.
5. Build and verify matched app, native library and old-board firmware. Retain
   rollback artifacts; blank all 40 pixels before any downgrade to 1.9.

## Success criteria

- Native audio changes at the next source wrap, with cancellation, replacement,
  lifecycle invalidation and actual-event logging covered by native tests.
- Actual C FFI, repository, controls and wire codec agree on remaining-time
  progress, cancellation and handoff in the integration corpus.
- Dart/C fixtures agree; the real sketch lights the intended local LEDs and
  addresses all 40 ring pixels without locally committing playback.
- Pico 2 firmware and a matching ARM64 application compile successfully.
- On-device firmware/app handshake succeeds. Physical appearance and audible
  switching remain a hardware observation; automated tests cannot establish it.

## Validation

Run native tests normally, with AddressSanitizer, and telemetry disabled; check
C++ atomics inclusion and regenerate bindings. Run changed package tests,
ordinary app tests, real-library integration, analysis and Bloc lint. Screenshot
fixtures are author-only and separate from normal application checks. Run all
four firmware suites and a real Pico 2 compile using the pinned LED libraries.

The conservative combined LED/logic current model is about 1.634 A, below the
old board's approximately 1.65 A trace planning budget. This is a software output
ceiling and engineering estimate, not a measurement or an electrical rating.
No PCB or mechanical redesign is included.

## Approved sustained ring fade follow-up

The owner confirmed the 40-pixel strip is fitted, refined the ring simulation,
and authorized trying its sustained fade on the current old board. Firmware
1.11 retains protocol 7 and the installed app. It uses a physical-output comet
profile with a 192 peak, 30 lit positions including the head, and a 1100 ms turn.
The first 17 positions retain at least half peak. Circular interpolation must
match the approved preview without a second brightness-gamma pass.

Keep startup, volume and breathing output unchanged; preserve stopped-position
and colour restoration, all pill behavior, and all pin assignments. Replace the
per-pixel ring driver dimmer with an explicit 11520 total-channel output budget,
retaining the earlier combined-current ceiling. Verify shape, interpolation,
wrap, lifecycle and current limits in host firmware tests and compile for Pico 2.
Retain the currently installed 1.10 firmware and marker, verify the unchanged
app, arm independent recovery, program and verify 1.11, then check its protocol 7
handshake and fresh audio/app startup before disarming recovery. Actual diffuser
appearance remains the owner's on-pedal check.
