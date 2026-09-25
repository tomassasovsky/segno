# VGV code review — Song completion on the current console (#1077)

## Summary

No outstanding actionable findings in the final reviewed target. This report applies to the current v2 console firmware 1.10: one 40-pixel ring on GP12 with brightness 96, the existing GP13/GP14/GP15 encoder connections, and the 80-pixel pill chain on GP18. It supersedes the earlier report's new-board target assumptions. The shared Song implementation keeps queue timing in the native engine and forwards the resulting state through the established repository and control layers. No device was accessed or flashed during this review.

## Critical — must fix

None outstanding.

## Important — should fix

None outstanding.

## Suggestions

None retained. Minor stylistic preferences do not establish an actionable defect.

## Scope and conventions

Read the current checkout's `AGENTS.md`, build/test guidance and tracking contract. Reviewed the final shared native queue/snapshot implementation, generated FFI fields, repository forwarding, control gestures/projections/invariants, queue-only C/Dart protocol 7, and current-board firmware changes. Historical unrelated CAD and PD work are outside this target and were not edited or used as proof.

The stack remains native C processing, C++ Arduino firmware and immutable Dart repository/control state under the project's existing Bloc/Cubit conventions. No presentation-to-native dependency or application state moved into firmware.

## Correctness and regression observations

- The engine accepts and revalidates Song requests on its command queue, latches the source clock, publishes target/progress together, and commits at the source's next sample boundary. The stopped target starts at zero; the frame's old track-state snapshot prevents advancing it prematurely.
- Cancellation includes source/target stop, clear, undo-to-empty, capture/arm and lifecycle reset. Song cancel-arm requests enter the native queue even before a preceding play has been published, closing the stale control-snapshot race. Unrelated disarm does not cancel another section's queue.
- The final One Shot guard prevents a second old section from emitting a duplicate stop after the same-frame Song handoff already stopped it. Tests inspect log counts and exact event frames.
- The shared snapshot, repository and transport equality fields preserve progress-only updates. Generated structure fields match the appended native fields.
- Song Rec/Play no longer loops through every content track. Running/queued playback is left alone; parked playback starts only one remembered, selected or available section. The earlier integration finding is resolved in this target too.
- Protocol 7 has the same queue target sentinel and 0..254 completion range on both sides. Invalid targets, completion 255 and progress without a target are rejected. This checkout adds no PD message or independent-ring UART requirement.
- Current-board firmware retains its actual pin map and encoder path. The queued fill uses logical track/bank addressing and the physical left-to-right pixel map; it does not advance from device time. Cancellation, confirmed completion, goodbye and link expiry restore the appropriate app-owned indication.
- The ring uses all 40 pixels with the 96 cap. The pill current limiter computes from desired colors each render rather than repeatedly dimming stored output. Power figures remain a documented planning model, not a measured electrical guarantee.

## Simplicity assessment

No unnecessary abstraction or speculative framework identified. The implementation reuses the existing engine command queue, immutable snapshots, repository flow and pedal frame. New firmware logic stays within rendering and input forwarding. The scope is proportionate to the requested queue completion and current-board ring change.

## Testing assessment

Independently reran in this final target:

- `bash firmware/test/run_tests.sh`: all four suites passed, including 49 C/Dart golden fixtures, existing CTRL tests, the actual current-console sketch's queued-pill/ring behavior, and the pill diagnostic.
- Pedal codec and state-frame Flutter tests: all 44 tests passed.

The console sketch tests cover partial progress, no local completion, physical direction, both banks, mode filtering, cancellation, completed playback, corrupt frames, expiry, forty-pixel output and the brightness cap. The ring/pill current model is tested as arithmetic only; these tests do not measure the assembled supply.

Rechecked the shared source against the previously inspected Song implementation. Its control changes differ only by formatting; the final native cancellation and duplicate-stop-log corrections were read directly. The earlier focused control run passed 215 tests. Parent-owned validation supplies the full native/sanitizer/build checks and the newly added real C/FFI-to-pedal corpus run; this reviewer inspected that corpus but does not claim an independent execution of it here.

No actionable missing-disposal, mutable-state, layering, protocol-parity or callback allocation/locking issue was found. Physical appearance, ring wiring and actual power margin remain device acceptance items. This report makes no deployment or manufacturing approval claim.
