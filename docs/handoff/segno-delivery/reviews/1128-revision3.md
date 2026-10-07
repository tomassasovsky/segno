## Scope and method

Read-only review of base `a24b7777` → head `e3fa66f3` (`manifest.json`), the whole `change.diff`, `before/`, and the frozen `source/` tree: `lib/app/view/app.dart`, `lib/app/app_toasts.dart`, `lib/app/view/control_settings_notices.dart`, `lib/looper/view/tracks_commands.dart`, `lib/looper/view/tracks_view.dart`, `lib/looper/view/looper_page.dart`, `lib/session/cubit/session_cubit.dart` (+ state), `lib/app/fx_chain_persistence.dart`, `lib/audio_setup/cubit/monitor_cubit.dart`, `lib/session/view/sessions_manager_dialog.dart`, `lib/app/application/app_runtime.dart`, the `en`/`es` ARBs, and `test/app/view/app_test.dart`. Nothing executed; no runtime or hardware claim is made. Confirmed in-scope: 4 code/test files + 2 docs, no owner, schema or native change.

## Result: bounded clean, one minor actionable test gap

### R1 — suppression is exactly scoped

`app.dart:902-906` suppresses Monitor Retry on `persistence.sessionTransitionActive || session.state.bootRecoveryRequired`. `sessionTransitionActive` (`fx_chain_persistence.dart:38`) is `_sessionLoadRequested || _sessionBootBarrier != null`; `reserveSessionLoad()` is reached only via `_run(..., reserveSessionLoad: true)`, used solely by `loadNamed` (`session_cubit.dart:363`), and `beginSessionLoad()` only inside it (`:261`). `save`, `saveAs`, exports, rename, delete, duplicate and `refreshSessions` never set either flag, so they cannot suppress Monitor Retry — asserted at `app_test.dart:1092`.

Re-arming is complete. Every clear of the transition flag is followed by a `SessionCubit` emit, which the new unconditional `BlocListener<SessionCubit, SessionState>` (`app.dart:1237`) turns into a reconcile: `cancelSessionLoad()` (`:350`, `:359`) always rethrows into `_performRun`'s failure emit; `completeSessionBoot()` (`:338`, `:381`) is followed by the success emit; `reserveSessionLoad()` is followed by `emit(working)` (`:513`). The only emit-free exits are `_closing`/`isClosed`, i.e. teardown. So a suppressed Monitor notice always returns when the Session obligation ends — the `cancel=true` case at `app_test.dart:1045-1057` exercises exactly that and then restores mask `8` from the pre-session settings.

### R2 — the competing/inert notice

The replacement is genuinely reachable, not just registered. `ToastificationWrapper` sits above `materialApp` (`app.dart:1293-1299`), so the toast overlay is above every in-app route, including the `sessions_manager` dialog — which is why this surface works where the removed `ScaffoldMessenger` Snackbar did not.

Removing the boot Snackbar loses no reachable feedback. `TracksView`'s listener fires only on a *status change* (`tracks_view.dart:126-131`), so repeat `bootPersistence` refusals (`session_cubit.dart:477-487`) never produced a Snackbar even before; the single `working→failure` transition that did is now carried by the notice. `message == null` early-returns at `tracks_commands.dart:396`, and the deleted explicit `Duration(seconds: 4)` equals Material's default, so unrelated Session outcomes are unchanged. No test or doc still asserts the old Snackbar.

Failed Retry retains its debt: `retryLoadedSession`'s `_SessionBootException` path (`session_cubit.dart:391`) leaves `_sessionBootRecovery` and `_pendingLoaded*` intact, `retry()` returns `false`, and the re-emitted `failure` re-presents one toast (`showAppToast` dismisses the prior item first, so `find.text('Retry').hitTestable()` stays singular — `app_test.dart:1125`).

No inert Retry. `session.state.bootRecoveryRequired` and `fxPersistence.sessionBootRecoveryRequired` are set together (`:321-336`) and cleared together (`completeSessionBoot` then the success emit, with no intervening await that user input could enter), so `retryLoadedSession`'s `StateError('no loaded session needs boot recovery')` guard cannot be reached from the notice.

Power/lifetime identity is preserved: the new notice is an ordinary `ControlSettingsNotice` with both `retry` and `needsRecovery`, so `setPowerVisible`/`dispose` treat it exactly as `monitorRestore`. Re-presentation uses `needsRecovery` (debt only), not the `status == failure` show-gate, so a debt with a Retry in flight still re-presents on return — `app_test.dart:1110-1118`.

The `_restoreNoticeScheduled` flag is sound: it is cleared at the start of the callback, the callback reads live owner state, and the first request always reaches `ensureVisualUpdate()` (`app.dart:924`), so a frame is always scheduled. Because the pre-change code's duplicate callbacks would have read the same final state, the flag is pure de-duplication with no behavioral change; the `hasScheduledFrame` oracle at `app_test.dart:1194` still holds.

### Test oracles are real

The new tests use the real `App`, `SessionCubit`, `MonitorCubit` and `FxChainPersistence` with I/O refused at the store (`_MonitorRestoreStore.setString`) and at `SessionRepository.read`. They tap through the actual dialog, and their key oracles are hit-testable, not log-shaped: `find.descendant(of: find.byKey(Key(AppToastId.sessionBootRecovery)), matching: find.text('Retry')).hitTestable()` (`:1102-1108`), bare `find.text('Retry').hitTestable()` as a *singleton* (`:1109`, `:1125`) proving no competing notice, `find.byKey(Key('sessions_manager'))` still open (`:1123`), `engine.snapshot().isRunning` false (`:1097`), `monitor.state.inputs` empty during debt (`:1099`, `:1122`), and the durable `await settings.loadMonitorOutput(0) == 16` after success (`:1134`). The English-string `findsNothing` assertion at `:1037` matches `app_en.arb:5766` exactly and is asserted positively at `:1156`, so it is not vacuous.

## Finding (minor, actionable)

**`test/app/view/app_test.dart:1100` — no oracle for the new notice's localized text.**
Trigger: the boot-recovery notice is now the *only* surface for `SessionError.bootPersistence`, and its title is a newly wired key. The test proves a toast with id `app_sessionBootRecovery_error` carries a tappable Retry, but never asserts what it says. Impact: wiring `sessionBootRecoveryTitle`/`Body` to the wrong key (or an empty/placeholder string) passes every test here, and `test/l10n/app_localizations_test.dart` has no key-level coverage. Smallest sound correction — one line beside `:1100`:

```dart
expect(find.text('Session settings need recovery'), findsOneWidget);
```

matching the `monitorRestore` convention at `:1156` and `app_en.arb:194`.

## Hypothesis (not reachable on this head)

`app.dart:880` — `if (monitor.isClosed) return;` now also gates the new Session branch, so a closed `MonitorCubit` would leave the Session notice neither shown nor dismissed, with no Snackbar left as a fallback. I could not reach it: `MonitorCubit` is created by a provider inside `_AppState.build` (`:706-715`), a strict ancestor of `_AppView`, so the cubit and the `mounted` guard retire together. If a future change decouples those lifetimes this becomes a real hole; the guard is already redundant, since `needsMonitorRecovery()` checks `!monitor.isClosed` itself (`:903`), so deleting the early return and letting the monitor branch fall through to its `dismiss` is both smaller and stricter.

## Preexisting, not introduced

- `ControlSettingsNotices._present`'s `identical(_recoveries[notice.id], notice)` check (`control_settings_notices.dart:91`) can leave a stale entry when a notice is re-shown while its Retry is awaiting; the following reconcile's `dismiss` cleans it up. Shared with `monitorRestore` before this change.
- `FxChainPersistence.close()` (`:416-420`) clears `_sessionLoadRequested` and the barrier but not `_sessionBootRecovery`, so `sessionBootRecoveryRequired` stays true after close. Post-teardown only.
- `retrySessionBoot`'s `'session changed before boot-settings recovery'` guard (`:95`) is terminal for the retained image. Unchanged by this diff.

No other introduced defect found in the four frozen files or their callers within the stated bounds.
