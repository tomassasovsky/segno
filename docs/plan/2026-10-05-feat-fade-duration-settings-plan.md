# Durable Fade duration settings

Tracking: #1137, parent #1026, human merge gate. Implementation is authorized;
root owns commit and publication. Base: #1134 / PR #1136, `800ce2ea`.
Parent: [Foot Fade](2026-10-04-feat-foot-fade-plan.md), bounded from
[Part 2](2026-10-04-feat-foot-fade-part-2-plan.md).

Persist the setup used by the next Fade gesture, including Session save/load and
explicit storage recovery. The public app stays usable without exposing an
unfinished Fade destination. Existing native Fade receipts and render behavior
are unchanged.

## Implementation boundaries

1. Add an immutable duration snapshot in `packages/settings_repository/lib/src/`
   and export it from `lib/settings_repository.dart`. Use integer milliseconds:
   Default 4000, valid 500 through 30000 inclusive in 500 increments, and sparse
   overrides keyed only by channels 0–7. Reject malformed values; never round or
   coerce. Explicit overrides equal to Default retain membership. Removing an
   override restores inheritance; resetting Default preserves overrides.

2. Extend `packages/settings_repository/lib/src/settings_repository.dart` with
   one JSON record and the existing serialized storage boundary. Absent local
   data means the declared default; malformed present data is a load failure.
   Provide exact checkpoint read (bytes/absence), verified write and verified
   checkpoint restore operations. A setter that writes and then throws is a
   failure. The writer alone sequences those operations and retains repair debt;
   SettingsRepository holds no recovery cache or second confirmed snapshot.
   Do not nest work onto the same serialized tail while awaiting it.

3. Add the small storage-only writer `lib/looper/application/fade_settings.dart`.
   It owns the confirmed snapshot, ordered edit admission, load, flush, close and
   explicit recovery. Derive each admitted edit from the preceding confirmed
   snapshot; publish only after verified storage success. On failure restore and
   verify the exact prior checkpoint. If repair fails, the writer retains that
   owed checkpoint and refuses dependent writes/capture until explicit recovery.
   Failed work must not strand the tail. Session exclusion and close reject new edits,
   while draining earlier admitted work. Expose the effective confirmed duration
   for later gesture callers. No engine subscriptions, native commands, receipts,
   replay, reconnect caches, timers or mapping holder ledger belong here.

4. Compose this writer in `lib/app/application/app_runtime.dart` and the existing
   `lib/session/application/session_settings_coordinator.dart` exclusive scope.
   Capture drains prior writes and reads the confirmed vector. The Session-held
   install operation must execute inside that scope without re-enqueueing behind
   itself. Wire startup load, shutdown flush/recovery and ordered close. Reuse
   `lib/app/view/app.dart` and `control_settings_notices.dart` for existing
   persistent notice/Retry behavior, with localized copy; presentation owns no
   duration business state. Power dismissal and disposal retain existing rules.

5. Add primitive duration fields to the existing Session models/codecs in
   `packages/session_repository/lib/src/models/session.dart` and
   `lib/src/session_repository.dart`; convert through `lib/session/session_mapping.dart`.
   Bump exact Session schema 9 to 10, require both fields and strictly decode the
   complete vector. Keep SessionRepository independent of SettingsRepository.
   No legacy fallback or passive duration copy in SessionRig/LooperRepository.

6. Extend `lib/session/cubit/session_cubit.dart` at its current pending-load and
   boot boundaries. Validate incoming duration before disarm, storage changes or
   audio mutation; retain it alongside the existing pending Session image after
   successful rig application. Persist existing FX boot settings first, then the
   incoming duration vector, before bindings and complete-boot release. This
   preserves the existing FX boot recovery guard if duration persistence fails.
   Retry reuses that retained incoming vector through the same writer, within the
   existing exclusive scope; it never recaptures outgoing/current preferences.
   The accepted incoming operation settles any necessary storage repair and then
   installs incoming settings. An ordinary Retry cannot restore an outgoing
   checkpoint over an accepted Session. Pre-apply failure leaves durations alone;
   post-apply failure keeps the existing launch/binding block and pending image.

The ownership chain is model/store → one writer → existing application and
Session consumers. New Loop, Clear and material removal retain duration setup.
There is no new public page, mapping target, native API or transport owner.

## Behavior evidence

- Model/store tests prove endpoints, rejection, inheritance, equal-valued Custom
  membership, exact record/absence restoration, write-then-throw, mismatching
  readback and failed repair followed by explicit Retry. Reuse KeyValueStore seams.
- Writer tests gate storage to prove confirmed-only publication, ordered edits,
  refusal after reservation/close, non-stranded failure recovery and drain-on-close.
- Session codec and composed owner tests prove required fields/schema rejection
  before side effects, save waiting for admitted edits, refusal of later edits,
  retained incoming-vector boot failure/retry and release only after completion.
  Reuse existing Session failure journeys instead of duplicating every permutation.
- One matched actual-native fixture starts a 4s Fade, persists an 8s duration
  while moving, and proves the original rate remains until an explicit retrigger
  using the new effective duration. Inspect amount/target/rate and literal known
  PCM output, with Mixer gain and history unchanged. The edit issues no command.
- Runtime/notice tests cover startup failure, Retry, shutdown and disposal using
  the existing presentation mechanism. Ordinary storage recovery and accepted
  incoming Session completion are deliberately distinct schedules.

Resolve dependencies before explicit-path formatting. After focused behavior
success, freeze source before aggregate checks and independent reviews. Run the
affected package and app coverage gates, strict analyzer and a positive Bloc scan.
Reuse the already matched native library only after verifying unchanged native
inputs/library identity; no native rebuild/matrix solely for this Dart slice.
Preserve initial failure logs. Use at most two test processes across this task.

## Scope and risks

This is one independently usable settings/Session journey. Stationary coefficient
capture/install, reconnect, native Clear/history, mapping actions and Fade UI stay
in the remaining accepted parts. Do not add a generic transaction framework or
copy PlaybackSettings/native replay machinery. If implementation predicts over
roughly 600 production lines or hundreds of unrelated Session fixture edits, stop
for a concrete simplification/split review before growing the change.

The principal risks are self-wait inside Session exclusion, publishing an
unconfirmed write, accepting a mutated store after failure, and recovering the
wrong Session vector. Validate these schedules at real owner boundaries. Existing
tests and desktop-native evidence do not prove appliance/listening behavior.

```success-criteria
GOAL: Persist confirmed Fade duration setup through edits, Session operations and explicit recovery without changing active Fade behavior.
SUCCESS CRITERIA:
- Exact duration rules and sparse override identity round-trip without coercion or migration. | verify: (cd packages/settings_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test).
- Failed ordinary writes restore exact prior bytes/absence or retain explicit repair debt; unconfirmed data never becomes effective. | verify: manual inspect bound write-then-throw, mismatching readback and failed-repair test results.
- Session capture drains admitted edits, rejects later edits, and incoming boot Retry completes the retained incoming vector before releasing existing guards. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session.
- Duration edits do not change an active native fade; the next explicit gesture uses the newly confirmed duration. | verify: manual inspect matched actual-native behavioral test results, literal output and native image observations.
- Startup, Retry, shutdown and close use one writer and existing notices, with no incomplete public destination. | verify: manual inspect Runtime/notice tests and independent current-source review.
- Applicable format, analyzer, Bloc and coverage gates pass on frozen source. | verify: manual inspect bound aggregate evidence and positive Bloc file count.
NON-GOALS:
- Native algorithm/API changes, stationary Fade Session images, reconnect/history, gesture mappings, new UI destinations or compatibility migrations.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/dart analyze --fatal-infos lib test packages
```
