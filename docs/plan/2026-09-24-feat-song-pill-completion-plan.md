# Song queue completion and 40-LED ring

Tracking: [#1077](https://github.com/tomassasovsky/segno/issues/1077).

The owner approved the completion simulation on September 24: the queued pill
fills left to right over the current loop's remaining time. The next loop
automatically transfers playback. The new ring is one 40-LED ring. This work
targets the v3 console and independent ring controller; the installed v2 stays
on its separate firmware.

## Implementation

1. Extend Song play requests in `packages/segno_engine/src/core/` using the
   existing audio command queue and per-track loop clock. Queue one stopped
   target, cancel a repeated target/current source, replace with another target,
   and commit at the source's next wrap. Stop/clear/capture invalidates stale
   queues. Publish target and normalized progress together in the snapshot.
2. Regenerate `packages/segno_engine/lib/src/generated/segno_engine_bindings.dart`.
   Pass the snapshot through `EngineSnapshot`, `LooperRepository` and
   `TransportState`. In `lib/control/`, route Song playback track presses to play
   and project the actual queued completion. Other interaction modes retain
   their meanings.
3. Extend `packages/pedal_repository` and the canonical
   `firmware/libraries/SegnoPanel/src/pedal_link.*` contract to protocol 7:
   STATE byte 19 is target + 1 (zero means none), byte 20 is completion 0..254
   with denominator 255. A missing queue requires zero completion. Regenerate
   golden fixtures. The MCU cannot invent or commit an audio handoff.
4. Render that progress on the target's eight local left-to-right LEDs with the
   approved center-bright curve and physical harness mapping. Update console
   firmware to 2.1 and the private ring link to version 2. Drive all 40 pixels
   on the single ring with the existing 128/255 brightness cap. Carry the
   previously accepted BANK/held STOP/UNDO indication into this v3 target.
5. Run native, Dart, firmware and real MCU compilation checks; independently
   review the intended software changes and document physical limits.

## Success Criteria

```success-criteria
GOAL: The new firmware shows actual Song queue completion and drives one 40-LED ring.

SUCCESS CRITERIA:
- A mid-loop queue transfers playback only at the source's next wrap, and cancellation/replacement/stop/clear never leave a stale handoff | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Song playback gestures and snapshot projections carry the correct queued target and completion without changing other modes | verify: flutter test test/control
- Dart and C decode the same queued/cancelled state frames; the actual console sketch fills the correct eight pixels and the ring addresses all 40 | verify: bash firmware/test/run_tests.sh
- Both new-board targets compile against the pinned MCU dependencies | verify: arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build && arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:seeed_xiao_rp2350 firmware/ring_board --output-dir firmware/ring_board/build
- The assembled v3 pills and single 40-LED ring match the simulation during real playback | verify: manual fit the new ring, run matched app/firmware, queue/cancel/replace tracks and observe a loop-boundary handoff and shutdown darkness

NON-GOALS:
- Flashing v3 firmware onto the old v2 console.
- Redesigning the ring PCB around an unspecified replacement ring's mechanical dimensions.
- Implementing a standalone animation timer that claims an audio transition happened.

VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && flutter test test/control && bash firmware/test/run_tests.sh && arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build && arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:seeed_xiao_rp2350 firmware/ring_board --output-dir firmware/ring_board/build
```

Use the working absolute Flutter SDK path locally. Native validation also runs
with AddressSanitizer and callback telemetry disabled; Dart analysis, formatting,
Bloc lint and focused tests cover all changed packages. Physical timing, diffuser
appearance, the purchased ring's connector/pinout and power margin still require
the new assembly. Existing unrelated CAD and production artifacts are preserved.
