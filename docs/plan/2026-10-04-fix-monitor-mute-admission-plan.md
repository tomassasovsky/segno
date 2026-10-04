# Preserve monitor mute truth on refusal

Issue #1125, prerequisite of Foot Mixer #1123. Human merge gate.
Base: live-input gain correction #1126.

## Reproduced problem

When native input mute refuses a command, the repository currently remembers and
announces the requested value anyway. Monitor presentation then shows it and the
confirmed-envelope writer saves it. A behavioral probe with real repository,
Monitor, Settings and FX-persistence owners observed applied mute false while
repository, presentation and saved mute were true. An accepted-command control
passes. Correct this existing flow before adding another consumer.

## Bounded implementation

1. In `packages/looper_repository/lib/src/looper_repository.dart`, validate the
   monitor input and request native admission before publishing changed running
   intent. A refusal leaves remembered mute and change notifications untouched.
   Preserve valid stopped-engine intent and its existing restart replay. Do not
   invent a rollback transaction: one input command has one admission result.
2. In `lib/audio_setup/cubit/monitor_cubit.dart`, check the returned result before
   emitting success or saving. Refusal retains the prior view and produces an
   observed error through the existing owner/presentation path. A deliberate
   retry must remain possible. Awaiting callers retain failed completion on
   admission or storage refusal. Accepted mute continues through
   `FxChainPersistence.saveConfirmed`, including its existing held-FX projection,
   retained failures from `saveConfirmed`/`flush`, and Monitor’s `addError`
   observation path. Reuse these mechanisms; do not add an error stream.
3. Handle and test ignored refusal in Monitor restore (`_applyMonitor`),
   Session monitor reset/application, and direct native startup replay. Use each
   caller’s existing failure mechanism; do not report a completed restore when
   mute admission failed. Admit saved active mute before enabling or routing an
   input. When clearing mute, apply mode and routing first, including explicit
   Off state. Omitted Session monitors remain disabled before mute is cleared.
   Audit other immediate setter callers for false success after refusal. Keep the fix limited to monitor-mute admission and reporting;
   do not rewrite Session restoration, add a new cache, timer, queue, settings
   envelope, adapter or Foot Mixer destination.

Existing storage failure must not be converted into durable success. If the
current persistence owner already reports and retains that failure, prove and
reuse it. If not, report the concrete missing lifetime boundary before expanding
this slice. Whole-track and individual-lane mute persistence are a separate
correction because they have different storage and transport callers.

## Verification

Promote the red probe into normal behavioral tests. Use the existing AudioEngine
seam and real repository/application owners; preserve a passing admission control.

- Refusal: applied, intended, presented and saved mute remain unchanged; no
  rejected change announcement. A later unrelated envelope save remains correct.
- Accepted retry: all owners agree and saved intent restores on engine restart.
- Invalid input identity: no native call or cached entry.
- Stopped engine: valid intent can be saved and replayed after start.
- Failed storage: live accepted mute remains true, failure is observed, and an
  explicit retry/flush preserves it without claiming premature durability.
- Teardown or device/session replacement cannot publish a stale success.

Focused tests belong in existing repository, Monitor and FX-persistence suites.
Run the full affected package/application gates once source is frozen, strict
analysis, explicit formatting and positively scanned Bloc lint. Independently
review correctness, architecture, test quality and simplicity. Native DSP and
FFI are unchanged; reuse source-bound engine proof only after comparing hashes.
Physical appliance/controller tests and additional Claude review stay separate.

## Success Criteria

```success-criteria
GOAL: A refused live-input mute never appears or persists as accepted, while valid mute retains the existing save and restart behavior.

SUCCESS CRITERIA:
- Accepted, refused, invalid and stopped-engine monitor writes retain truthful repository intent and announcements. | verify: flutter test packages/looper_repository/test/looper_repository_test.dart
- Monitor presentation and storage follow accepted admission; refusal and retry are observable. | verify: flutter test test/audio_setup/cubit/monitor_cubit_test.dart
- Confirmed-envelope storage failures remain recoverable and preserve unrelated held effects. | verify: flutter test test/app/fx_chain_persistence_test.dart
- Changed application and package code pass strict static checks. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages

NON-GOALS:
- Track mute persistence, new Foot Mixer controls, new persistence owners, native DSP, protocol changes, migration, deployment or merging.

VERIFICATION COMMAND: flutter test packages/looper_repository/test/looper_repository_test.dart test/audio_setup/cubit/monitor_cubit_test.dart test/app/fx_chain_persistence_test.dart && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

Use the repository SDK and worktree lint instructions. Commands above are required
checks, not execution evidence. Bind the final report to the reviewed source and
record conditional skips and limits explicitly.
