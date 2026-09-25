# Song queue Dart integration — implementation evidence

Scope: new v3 firmware handoff path. No live-device writes, firmware flash, CAD edits, commits or changes to the v2 live ten-pill checkout were performed by this implementation task.

## Implemented

- Native `song_queued_track` maps to nullable `EngineSnapshot.songQueuedTrack`; `song_queue_progress` maps to `songQueueProgress`. Both participate in snapshot equality/hash and project directly into `TransportState` without copying transport progress onto individual tracks.
- Song/Mute track gestures use the existing repository `play` command, so queue, cancel, replacement and loop-boundary timing stay in the native engine. A stopped muted target is unmuted before requesting it; pressing the current muted source does not unmute it merely to cancel a queue.
- Song Rec/Play while already running does not expand to every stopped section. Stop latches the current section, and Rec/Play resumes only that section. Without a prior stop, a parked Song starts the selected playable section, falling back to the first content section if selection is empty.
- Pedal projection now supplies the actual looper mode. Only Song/Mute exposes queue metadata. Its target is green while waiting, and progress is the engine's fraction quantized to 0..254. Bank changes do not change the logical target. After handoff, the engine's stopped/playing states extinguish the old source and light the new section.
- Control invariants explicitly allow a queued section to be green before sounding and require queue metadata to match engine truth. Multi mute/exclusion rules and Record/FX gestures retain their existing meanings.
- MockAudioEngine remains unchanged: it already simulates neither loop playback nor transport; its new queue fields stay at the model's null/zero defaults. Actual timing/cancellation is verified by the native implementation's tests, not a newly invented mock clock.

## Files owned and changed

- `packages/segno_engine/lib/src/engine_snapshot.dart`
- `packages/segno_engine/test/engine_snapshot_test.dart`
- `packages/looper_repository/lib/src/models/transport_state.dart`
- `packages/looper_repository/lib/src/looper_repository.dart`
- `packages/looper_repository/test/models/transport_state_test.dart` (new)
- `packages/looper_repository/test/looper_repository_test.dart`
- `lib/control/control_projection.dart`
- `lib/control/cubit/control_cubit.dart`
- `lib/control/invariants.dart`
- `test/control/control_projection_test.dart`
- `test/control/control_cubit_test.dart`
- `test/control/invariants_test.dart`

Generated bindings, native engine and pedal protocol changes belong to the coordinating agents. Flutter silently added local build/platform exclusions to two package analysis configuration files during tests; those unrelated additions were removed exactly.

## Observed validation

- Complete targeted app projection, cubit and invariants suites passed: 211 tests before the final three Rec/Play regression cases and bank-dispatch case.
- Final focused Song gesture group passed: 8 tests, including all final control changes. Log: `/tmp/song-dart-focused-tests.log`.
- Engine snapshot suite passed: 84 tests, including native queue sentinel/progress mapping and equality.
- Looper repository and new transport-model suites passed: 287 tests, including advancing/cancelling queue projection while preserving unchanged track values.
- Scoped Dart analyzer: no issues.
- Bloc lint: 0 issues, 604 files analyzed. The tool rejects every path containing a hidden directory component, so its first direct worktree scan correctly failed with “No files found”; the successful run used a temporary non-hidden symlink to the exact same files, with the repository's normal analysis configuration and package locks. Log: `/tmp/song-dart-bloc-lint.log`.
- Explicit edited-file formatting and `git diff --check` passed.

Parent is running the final full application/package suites and coverage after this handoff. This is implementation evidence, not an independent clean-review declaration or a hardware qualification claim.
