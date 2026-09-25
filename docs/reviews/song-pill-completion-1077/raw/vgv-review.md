# VGV code review — Song queue completion (#1077)

## Summary

No outstanding actionable findings in the inspected Song queue and forty-pixel ring implementation. The native audio thread owns queue acceptance, cancellation, replacement, boundary transfer and progress; Dart forwards and projects those facts, and the firmware renders the supplied completion without inventing timing. The final reviewed gesture fix also prevents Mute-mode Rec/Play from queuing every Song section in succession. Software checks do not close the separate assembled-board and ring-fit acceptance gate.

Review date: September 24, 2026 (local project date). The working tree contains older uncommitted PCB, screen-power and PD work; those historical changes were excluded from this review. No implementation or CAD files were edited by this reviewer.

## Critical — must fix

None outstanding.

## Important — should fix

None outstanding.

## Suggestions

None retained; no concrete issue warranted a style-only finding.

## Reviewed scope

- Native queue changes in `engine.c`, `engine_commands.c`, `engine_core.h`, `engine_private.h`, `engine_process.c`, `engine_snapshot.c` and `segno_engine_api.h`, plus the new boundary/cancellation tests.
- Snapshot fields and regenerated FFI layout, repository forwarding and transport equality.
- Song track gestures, Rec/Play and parked resume integration, frame projection and control invariants.
- Protocol 7 queue fields, null sentinel and progress validation in the C and Dart codecs and model.
- Console 2.1 queued-pill rendering, physical eight-pixel orientation, held STOP/UNDO and BANK indication; the single 40-pixel ring and private link revision 2.

Read the task plan, project instructions, build/test guidance, tracking contract, lint configuration and established implementation patterns. The reviewed stack is C/C++ firmware/native processing with immutable Dart state and Bloc/Cubit application control.

## Review observations

The public play change revalidates requests on the audio thread. Queue state is callback-owned, and target/progress publication uses one atomic value. Handoff happens after the source's last mixed frame and resets the target before its first frame; the old per-frame state snapshot prevents advancing a newly started target on the same frame. Stop, clear, record/arm, relevant undo-to-empty, configure and shutdown paths invalidate stale requests. No allocation, blocking I/O or locking was added to the callback path.

The new FFI fields are appended to the native structure and represented in the generated Dart structure. Immutable snapshot and transport comparisons include both queue fields, allowing progress-only changes to be observed. Presentation control continues to call the repository; it does not access native bindings directly. The projection maps actual queued progress to the defined wire range, hides queue metadata outside the intended interaction mode, and retains the ordinary post-handoff playing indication.

The canonical protocol moved to revision 7 with a 21-byte STATE payload. Both codecs reject an out-of-range target, completion 255, and completion without a target. Private ring message lengths derive from the canonical state size and its revision was incremented. Pixel coverage stays below full completion until the app confirms the real handoff. Physical group order and local fill direction are tested independently of the symmetric brightness curve.

One integration problem was identified during review and corrected before this report: the old generic Mute Rec/Play path sent play for every content track, which would successively replace a Song queue and select the last track. The revised Song branch leaves running/queued playback alone and resumes one remembered, selected or available section when parked. Focused tests cover running, queued, stopped and selected-section cases. This is resolved and is not an outstanding finding.

## Simplicity assessment

- No unnecessary new abstraction or speculative framework identified.
- The existing audio command queue, repository/state flow and shared pedal protocol are reused.
- The one shared Song gesture helper now serves the track and parked-resume paths with one unmute/play rule.
- No justified lines-to-remove estimate: the added state and failure checks support the requested behavior.
- Complexity verdict: proportionate to sample-boundary scheduling and cross-device rendering.

## Testing assessment

Independently reran against the inspected tree:

- `bash firmware/test/run_tests.sh`: all eight suites passed, including 58 C/Dart fixtures, the actual console/ring sketches with simulated I/O, partial/full/cancelled queue rendering, physical direction, bank/mode filtering, host expiry and all 40 ring pixels.
- The focused `control_cubit_test.dart`, `control_projection_test.dart` and `invariants_test.dart` Flutter run: all 215 tests passed, including the final Rec/Play regression fixes.

Inspected native tests assert actual output samples across the boundary in both source/target channel orders, completion progression, replacement/cancellation and invalidation. Parent/native agent owns the full native, sanitizer, telemetry-disabled, analyzer and real MCU build validation; this report does not claim to have independently rerun those longer checks.

Source changed during review in `control_cubit.dart`, `engine_commands.c`, `engine_process.c` and `segno_engine_api.h`; the parent was notified and the deltas were re-read. The final native delta preserves non-Song public play validation behavior and updates Song API comments. The focused control tests cover the final gesture implementation; native-agent validation remains authoritative for the final C revision. Physical timing, diffuser appearance, replacement-ring pinout and power margin still require the new hardware.
