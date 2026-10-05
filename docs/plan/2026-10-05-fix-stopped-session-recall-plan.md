# Stopped Session recall prerequisite

Tracking: #1134, stage:build, autonomy:merge-gate. Prerequisite for the
[durable Fade slice](2026-10-04-feat-foot-fade-part-2-plan.md); no merge authority.

Session recall must establish imported tracks stopped while the device callback
continues processing. The current native commit starts playback before mix/FX
restore finishes, and the later boot-settings barrier only prevents device
restart. Change the existing commit contract to STOPPED and extend the existing
repository Session admission predicate through boot persistence. Reuse the current
Play command, Session block and failure/retry owners; add no transport option.

Before disarm, storage writes or destructive mutation, refuse audio-bearing loads
without a processing device. Preserve empty/settings-only loads. On accepted
loads, keep controls blocked through complete boot persistence and bindings;
release on success, retain on boot failure, and cancel the block when apply fails.

Files: native Session commit and API documentation; AudioEngine documentation and
generated bindings; LooperRepository preflight/reservation/confirmation;
SessionCubit preflight/block lifetime; corresponding fakes and behavior tests.
Performance render reconstructs material directly and has no import/commit caller.

Verify real native silent recall and first explicit-play PCM, loaded master/grid,
callback publication and cleanup failures, boot-storage delay/failure/retry,
unavailable-device refusal before side effects, and settings-only restore.
Update fixtures that intentionally need playing material with explicit Play;
do not weaken PCM or phase assertions. Run applicable native normal/ASAN/
telemetry-disabled, C++ shim, FFI generation/symbol parity, Dart tests/coverage,
strict analyzer, formatter and positive Bloc lint. Freeze after focused checks
before independent review and aggregate validation. No Fade duration, reconnect,
Clear-history, UI, deployment or device-validation work belongs to this slice.
