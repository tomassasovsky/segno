Model: Claude Sonnet (subagent), in-session retry; the original headless run was rate-limited

# Independent review: Segno PR #1116 (secondary display window owner)

Base `5ae3da75d135301ee908e82ef51afb039be9a3fa`, head `6646086a5be2e7c9135b4f01fd0464e316154082`.

## Verdict

No actionable defects in the introduced code. The new `WaveformDisplayController` preserves the behavior that moved out of `_AppViewState`, and it fixes a real race that the old code had. Four low-severity observations follow. None blocks merge. I did not read any author review document before forming this verdict.

## Scope reviewed

- `change.diff` in full: `lib/app/view/app.dart`, new `lib/visualizer/application/waveform_display_controller.dart`, `test/app/view/app_test.dart`, new `test/visualizer/application/waveform_display_controller_test.dart`, and the plan and review docs. For the docs I read only the headings and what the diff output showed.
- Head sources for `waveform_window_service.dart` (real and Noop), `WaveformWindowCubit`, `app.dart` provider tree, `initState`, `build` and listeners, `AppLog`, and `ControlState`.
- Removed code from the diff: the timers, frame gate, readout gate, `_onWindowReady`, `_syncWindow`, `_sameReadoutFacts` and `_readoutOf`.

## Traced paths (all behaved correctly)

1. **Open and close serialization.** `_requestTransition` allows one `_syncWindow` at a time (`waveform_display_controller.dart:143-157`). The loop re-reads `_intent` and `_enabled` each pass (`:159-189`). A failed platform call consumes only the intent it attempted (`finally`, `:182-186`). `whenComplete` re-queues only if a newer intent arrived. This removes the old race where `close()` ran concurrently with an in-flight `open()`, which the real service permits (`waveform_window_service.dart:154-190`). I found no self-retry loop.
2. **Disposal.** `_close()` runs its synchronous part up to the first `await` (`:297-301`). It sets `_closed`, cancels the startup timer, stops delivery, and nulls `onWindowReady`. `close()` is idempotent through `_closing`. The failure stream closes only after `_transition` settles, and no `_failures.add` can follow, because each add is guarded by `!_closed` or a re-check after the awaited call (`:160, :174`). `_AppViewState.dispose` cancels its failure subscription first and logs any teardown error. Children unmount before the parent, so the view disposes before `_AppState` tears down the runtime.
3. **Stale delivery after disable.** `setEnabled(false)` calls `_stopDelivery` synchronously (`:139`). That clears the poll, the readout timer and the frame gate, drops pending and last-sent frames and the readout cache, and bumps `_delivery` and `_readoutRevision`. Late rejections are discarded by the `_running`, `delivery`, cursor, name and identity checks (`:239-244`).
4. **Context staleness.** Every input to `WaveformDisplayContext` has a listener: `ControlCubit` (cursor, mode, bank), `TracksCubit` (name), `PowerOffCubit` (goodbye), and `AudioSetupCubit` (connectivity, with an equivalent `listenWhen`). `_pushReadout` compares the context by value, so a context change is picked up within one 33 ms tick. A cursor or name change requests a frame at once, which replaces the old tick-time label comparison. `_sendFrame` reads cursor and name together, so a frame never mixes two selections.
5. **Readout gate parity.** `_sameReadoutFacts` and `_readoutOf` are copied unchanged apart from reading name, default flag, mode, bank, deviceLost and goodbye from the context. The old identity checks on `tracks`, `control`, `audio` and `powerOff` become value equality of the context. That is equivalent or stricter and cheaper.
6. **Startup.** `start()` runs only after `load()`, and a delay keeps `_ready` false. Preference changes during the delay or before `start()` only record `_enabled` (`:134-141`), matching the old `_windowStartupReady` guard. A persisted-false preference still calls `close()` at startup, as before. I traced the `load()` emission against the listener ordering: the listener fires before `start()`, so there is no redundant intent bump at launch.
7. **Failure reporting.** The `singleDisplay` and `openFailed` events keep the old toast, banner and `reportOpenFailed` effects. A superseded open emits no failure (`:174`), so a stale failure cannot be reported after a newer intent.
8. **Platform admission.** `open()` throwing used to escape unhandled. It now maps to `openFailed` (`:170-173`). I kept the service's own `_controller` and static-state semantics out of scope, as the brief requires.

## Findings

### Introduced, low severity (optional)

**L1. A re-enable during an in-flight open closes and recreates a window that opened successfully.**
- Location: `waveform_display_controller.dart:138, 174-175`. The test that fixes the behavior is `waveform_display_controller_test.dart`, "disable and re-enable while opening follow only the latest intent" (`opens == 2`).
- Trigger: `setEnabled(false)` then `setEnabled(true)` while `open()` is pending (up to the 10 s readiness wait). `_intent` changed, so the successful open is followed by `close()` and a second `open()`.
- Impact: the real service tears down and recreates the OS window, so the second screen flashes. The old code had a worse race here, so this is not a regression. It is also rare, because it needs a double toggle within the open window, or a redundant `setEnabled` call, which the current listener does not produce. Even an identical-value `setEnabled` bumps `_intent`.
- Smallest correction, only if the flash matters: after `open()` returns, close only when `!_enabled || _closed`. If still enabled, call `_startDelivery()` and let the loop re-check. Update the test to expect one open.

**L2. Rationale comments were dropped in the move.**
- Location: `_sameReadoutFacts` and `_readoutOf` (`:313-370`).
- The removed text explained why `peak` and the positions must stay in `Track` equality. It also said any fact added to `_readoutOf` must be added to the gate, with the app readout tests as the safety net. That invariant is now unstated, while the gate and the projection sit in the same file. This is a maintenance cost, not a defect. Restore a short comment on `_sameReadoutFacts`.

**L3. Two new branches have no direct unit test.**
- `open()` throwing should produce `WaveformDisplayFailure.openFailed`. A single-display `setEnabled(true)` should emit `singleDisplay`. The existing app tests cover the `opened == false` path and the single-display banner end to end, but not the new exception path. The controller test only listens to `failures` for stream closure.
- Fix: a fake window whose `open` throws, and an assertion on the emitted event.

**L4. Disable followed by a failed `close()` leaves the window open until a newer intent.**
- Location: `:163-164`, with the error logged at `:146-152`.
- Delivery is stopped, but the OS window may remain, and nothing retries until the next toggle. The old code threw an unhandled error here, so this is not a regression. The author's test deliberately asserts "attempts once", and that is a defensible design. Mentioned for completeness.

### Pre-existing, out of scope

- `DesktopMultiWindowWaveformService.open()` returns `true` whenever `_controller != null` (`waveform_window_service.dart:155`). After a readiness timeout the controller stays set, so "Try again" reports success without readiness. This path was the same before the PR.
- `onWindowReady` is a process-wide static handler (`:96-104`). If a replacement view ever initializes before the old one disposes, the old `onWindowReady = null` clobbers the new handler. The old code had the same pattern, and `_AppView` is not re-keyed.
- `AudioSetupCubit`, which is lazily provided, is now created in `initState` rather than at first `build`. This is the same frame, and I found no dependency on creation order.

### Unconfirmed hypotheses

- Cost of the new `ControlCubit`, `TracksCubit` and `PowerOffCubit` listeners, which build a context on every emit even when the window is disabled. `ControlState` appears discrete, with no streaming fields, so I expect this to be negligible, but I did not measure it.

## Test quality

- The controller tests are behavior-oriented: observable window opens and closes, frames, readouts, timer counts through `fakeAsync`, stream closure, and error leakage through `runZonedGuarded`. They would catch the self-retry loop and the late-failed-frame replay. The app disposal test checks the log content and `onWindowReady == null`, not just that no exception was thrown.
- The gap is L3.

## Limits

- Static reading only. I did not build, run tests or analysis, and did not validate hardware or the OS window. I did not exercise the real `desktop_multi_window` native behavior. I treated its documented `open` and `close` idempotence as an assumption, and the controller does not depend on it beyond double-close tolerance.
- The PR's claimed test counts and coverage figures are unverified by me.
