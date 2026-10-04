# Monitor mute admission review

Issue #1125. Base `623a5a7ba7ff595e60917c5ee9c4ece667c6389d`
(input-volume correction #1126). Reviewed working head: the four exact source
hashes below, plus the implementation plan and this report. Human merge gate.

## Result

Independent source reviews report no unresolved actionable findings after the
corrections below. The additional requested Claude review remains pending its
usage-limit reset. Therefore the combined review gate is incomplete; this report
does not authorize `review:clean`, readiness, or merge. Remote CI must also pass
on the published head.

## Scope and behavior

Only MonitorCubit, LooperRepository and their existing tests change. Running
monitor mute is published only after native admission; invalid identities never
reach native state. Valid stopped-engine intent remains available for restart.
Monitor emits and saves accepted values; failed admission and storage report an
error and preserve failed completion for awaiting callers. Existing confirmed
monitor-envelope persistence retains failed writes for explicit retry.

Saved active mute is admitted before enabling or routing a monitor during
Monitor restore, startup replay, and defined Session monitor application.
When restoring an input with mute off, mode and routing precede clearing mute. A refused
startup stops the engine and preserves intent for retry. Omitted Session
monitors are disabled before clearing mute. Existing Session failure handling remains.

Production delta: 55 added, 17 removed, net 38 lines in two files. No new state
owner, timer, queue, storage format, dependency, native or generated API change.
Track/lane mute persistence remains separate in #1127.

## Independent review and resolved findings

VGV and bug-focused review covered the complete diff, removed behavior, immediate
callers, admission, restore, Session failure, restart and error paths. Separate
architecture, test-quality, simplicity and readiness roles reviewed the same
frozen files. The final source hashes and aggregate results bind their evidence.

- MUT-1: The initial implementation observed but consumed mute/save errors.
  It now reports and rethrows. Tests assert the returned Future fails while
  refused state stays unchanged and accepted storage failure remains retryable.
- MUT-2: Restore enabled a saved muted source before mute admission. Monitor,
  startup and defined Session replay now admit mute first. Tests prove refusal
  makes no enable mutation; Monitor restore also makes no route mutation.
- MUT-3: Unconditional mute-first ordering could clear mute before restoring Off
  or replacing a route. Desired active mute remains first; clearing mute now
  follows mode and routing. Four regressions observe intermediate engine state
  after each command, proving silence for Off and the correct destination for On.

The stronger tests failed against the earlier candidate before the fixes. Review
corrections were rechecked independently. No unrelated cleanup was included.

## Validation on final frozen source

- Focused repository, Monitor and existing persistence suites: 454 passed,
  zero skipped. Real application owners use the existing AudioEngine test seam.
- Full app: 3,014 passed, 49 conditional skips; coverage 27,247 / 29,522
  (92.2939%, required 90%), using the workflow's actual exclusions.
- Full LooperRepository: 737 passed, zero skipped; coverage 4,564 / 4,765
  (95.7817%, required 95%).
- Strict analysis of `lib test packages`: clean. Four explicitly formatted
  files: unchanged. Bloc lint positively scanned 793 files with zero issues.
- Diff check passed. All four source hashes were unchanged through final checks.
- Compared 612 native/build/binding inputs to prior native verification: unchanged.
  The same immutable test library was used; existing native sanitizer and
  telemetry-disabled evidence was reused, not represented as newly executed.

No UI or Pen geometry changes are part of this correction. Conditional app
skips are not visual proof. Native admission is not an invented callback receipt;
these command-order and persistence tests do not prove physical appliance audio.

## Reviewed source hashes

| Path | SHA-256 |
| --- | --- |
| `lib/audio_setup/cubit/monitor_cubit.dart` | `40eaf31c84964bae761bdd87cc7f0671a45571e35033099bbcf9dbba06ec087a` |
| `packages/looper_repository/lib/src/looper_repository.dart` | `0e1baa9edde289f3175a233b1a89683a9606159d719f1dfb82af808b0d127ccf` |
| `packages/looper_repository/test/looper_repository_test.dart` | `f614a72297b79f5465630173539b51ea670eff4fb56af9c7826b569cd4eb1cca` |
| `test/audio_setup/cubit/monitor_cubit_test.dart` | `f97bda11742728a45dc070aa14ecc587e8906921218534b6615cfaefbbb8dd7c` |
