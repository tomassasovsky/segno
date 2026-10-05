# Monitor mute admission and restore recovery review

Issue #1125. Base `623a5a7ba7ff595e60917c5ee9c4ece667c6389d`.
The original admission correction was published at `05900df`; the recovery
correction below is bound to its final source manifest. Human merge gate.

## Result

Independent bug, architecture, simplicity and test-quality reviews are clean.
The full app run and static checks pass on the frozen correction. Claude's
adversarial review confirmed the Retry repair, then exposed competing recovery
notices during Session replacement. The presentation correction below is
verified locally and independently reviewed; its Claude re-review remains pending.
No readiness or merge claim is made.

## Behavior and ownership

Running monitor mute is published only after native admission. Invalid input
identities do not reach native state; valid stopped-engine intent remains
available for restart. Admission and storage errors remain observable.

Saved active mute is admitted before enabling or routing a monitor. When the
saved mute is off, destination settings precede clearing mute. A refused startup
stops the engine and preserves intent for retry. Existing Session failure
handling remains in charge of Session recovery.

MonitorCubit now exposes incomplete saved-monitor restore through its existing
state. Failed attempts retire so the persistent application notice can retry
without reconstructing the app. In-flight attempts deduplicate; completed
restore remains idempotent. The same existing mix exclusion boundary orders
restore against Session replacement.

An attempt checks ownership after awaited work and before further publication.
Close or successful Session projection wins over an old completion. Session
reservation prevents admission; if a same-session reservation is canceled,
incomplete startup remains visibly retryable. This does not roll back already
accepted native commands or cancel a storage write already in progress.

The application only presents the existing Retry notice. It reconciles initial
state, requests a frame for an asynchronous failure while idle, and removes the
notice when a Session projection recovers independently. Shutdown suppression
and notice identity remain shared. There is no new recovery coordinator,
queue, timer, engine reset, persistence schema or native API.

## Verified findings and corrections

- MUT-1: Report and rethrow refused mute/save operations to awaiting callers.
- MUT-2: Admit saved active mute before enabling its input. Tests observe the
  refused command and absence of subsequent enable/routing mutation.
- MUT-3: Restore destination before clearing mute, preserving Off/nondefault
  routing behavior. Tests inspect intermediate engine state.
- REC-1: Failed restore was memoized permanently. Explicit Retry now starts a
  fresh attempt while incomplete repository state remains nonauthoritative.
- REC-2: A deferred notice could wait indefinitely for another frame while the
  app was idle. Reconciliation now requests that frame explicitly.
- REC-3: Canceling a Session reservation could leave initial restore incomplete
  without a Retry action. Both reservation-before-load and mid-attempt cases
  now preserve a reachable explicit recovery path.

The original Claude review's enable-before-route startup concern predates this
PR; it is recorded separately. Its proposed already-clear mute shortcut would not
repair saved-true refusal or saved-data read failure, so it was not adopted.
Track/lane scalar persistence and the later input scalar-save correction are
separate slices. Cross-slice preservation is verified after restacking rather
than pulled backward into this branch.

## Validation

- Full app: 3,037 passed, 49 conditional skips, no failures; coverage
  27,310 / 29,584 (92.3134%, required 90%).
- Focused restore/App/notice checks: 178 passed, six inherited skips. The final
  strengthened restore file passed 17 cases; these overlap, not additive counts.
- Strict analysis of `lib test packages`, explicit formatting, and diff checks
  pass. Bloc lint positively scanned 794 files with no issues.
- The 11-path source manifest SHA-256 is
  `46397e5ddbdf891a492dc8231a0429893873141eebd826f2f9dbcc70d47fd08a`.
  All source hashes remained unchanged through the aggregate. Independent
  production and test reviews bind those same bytes.
- All 612 native/build/binding inputs match the earlier immutable native
  verification. No native suite was rerun for this Dart-only correction.
  The unchanged repository's prior 737 passing tests remain separate evidence.

The correction has no native source changes. Existing native sanitizer,
telemetry-disabled and symbol evidence may be reused only after confirming
unchanged inputs. Conditional app skips and source reviews are not physical
appliance, audio or visual validation. The notice reuses accepted components;
no Pen geometry or design departure is introduced.

## Session notice follow-up

Adversarial review of `a24b7777` confirmed the restore ownership correction but
identified a misleading Monitor Retry during a Session reservation or failed
boot-settings save. A composed widget test also proved that the existing Session
Retry Snackbar was not reachable above the actual Sessions dialog.

The App now suppresses Monitor Retry while that exact Session obligation owns
recovery, and presents the existing Session retry operation through the shared
recovery notice. Session emissions reconcile the existing Monitor failure fact;
an aborted load makes Monitor Retry available again. One presentation scheduling
flag coalesces same-frame notices. Ordinary Session outcomes retain their
existing Snackbars. No persistence, engine or recovery-owner behavior changes.

Three regressions failed before the correction. The final tests use the real
App, Session and Monitor owners with controlled I/O failures. They tap Retry
above the open Sessions dialog, fail and retry again, test Power suppression and
return, and observe saved routing plus Monitor projection after success.

- Full app: 3,040 passed, 49 conditional skips, no failures; coverage
  27,388 / 29,602 (92.5208%, required 90%).
- Strict analysis, explicit formatting and diff checks pass. Bloc lint
  positively scanned 794 files with no issues.
- Four source/test paths stayed frozen through verification; manifest SHA-256
  `9d0e3199a02bad8dabe09c95a09e6983ebc7b33389c9e7ee34e42850a9104dee`.
- Independent bug, architecture, test-quality and simplicity review found no
  actionable defect in those same four frozen files and their relevant callers.
- This follow-up changes only application presentation and composed App tests.
  Native and repository behavior retain their earlier evidence; the full app
  run is new evidence, not a rerun claim for those unchanged lower layers.
