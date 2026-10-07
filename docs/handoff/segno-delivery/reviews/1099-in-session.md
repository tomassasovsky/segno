Model: Claude Opus (subagent), in-session
Base: 3025840dd212a86ee1b23c21b6980f0ac4866e20 (codex/shared-record-timing)
Head: 505fbcad19303b78396035c807409ee5a706f132 (codex/shared-hear-click)

# PR #1099 review: shared Hear click

Read-only. I read AGENTS.md and docs/plan/2026-10-03-shared-hear-click.md at the head, and traced the native receipt, LooperRepository, TempoCubit, ControlCubit (External and MIDI), bootstrap, App shutdown and Session wiring. Nothing was built or run. Line numbers refer to the head.

As traced, these match the plan: the native single-flight receipt (`engine_commands.c`, `engine_process.c`, raw-post rejection in `engine.c`), the four-choice table, refusal advancing the revision, Released-into-Settings for Held writes, Session Save of `clickModeRestartIntent`, and the ordinary-revision fence. `flushClickMode` checks `wasSettled`, so a cancelled receipt does not repeat #1096 F1.
Dispatch tests use a real `PumpedNativeEngine` and literal enum oracles, so they are independent of the code under test.

## Introduced defects

### 1. A device stop or start after the receipt settles rolls Settings back while the repository keeps the new mode (Low-Medium)
- Location: `lib/looper/cubit/tempo_cubit.dart:389-411`.
- What happens:
  - The repository poll timer accepts the receipt and sets `_clickMode` and `_clickModeRestart` (`looper_repository.dart:7106-7118`).
  - `_writeMode` resumes only on `settleClickMode`'s next 10 ms poll.
  - If `stopEngine` or `startEngine` runs in that window, `mixGeneration` changes (`_cancelMix`, :819; :2455). Triggers: the Audio setup Stop/Start buttons, or a reconnect tick in `_attemptReconnect`.
  - `current()` then fails, a `superseded` refusal is thrown (:391), and the catch block restores the old checkpoint (:409).
- Impact: the engine and Loop Tempo page show the new mode, but Settings holds the old one, so the next boot reverts it. No ordinary event is emitted, so Control never records ordinary priority.
- This is the same shape as #1096 F2, repeated in new code.
- Smallest fix: once `settleClickMode()` returns ok, treat the write as committed. Return `applied`, or return `superseded` without the storage rollback.

### 2. Silent behaviour change for existing installs: absent key moves from Off to First recording (Low; needs owner acknowledgment)
- Old behaviour: `loadClickMode() ?? 0` gave Off (base `settings_repository.dart:799`).
- New behaviour: `audio_bootstrap.dart:39-41` and `tempo_cubit.dart:291` use `?? 2`.
- The PR body says "default a new setup", but any existing appliance that routed the click and never touched Hear click is affected too. It now hears the click on first recordings and on every count-in, because non-Off modes sound during count-in.
- The plan accepts the default, so state the existing-install effect in the PR body.

### 3. Hear click shows as unavailable during every edit, its own edits included (Low)
- `_modeReady` (`tempo_cubit.dart:241-245`) is false while `_modeApplying`. Every looper-state emission during a write publishes `clickModeReady: false` (:763), so `clickModeSnapshot` is null.
- Effects: the Loop Tempo choice disables and flashes "unavailable" (`loop_tempo_page.dart:235-247`); the editors drop the destination; a concurrent controller press is dropped (`control_midi.dart:676-682`).
- Fix: keep the snapshot non-null while the owner's own transaction is in flight. Readiness should reflect recovery or initialization, not the queue.

## Inherited-pattern repeats

### 4. A malformed or unreadable `tempo.click_mode` blocks audio, Session and power-off, and nothing can repair it (Medium; repeat of #1095 F2)
- `audio_bootstrap.dart:38-53`: any read exception stops start with `recoveryConfig: null`, so no reconnect supervision. The test asserts this behaviour (`test/app/audio_bootstrap_test.dart:216`). A transient storage read error at boot blocks audio the same way.
- The base mapped bad values to Off permissively.
- Downstream effects:
  - `_restoreClickMode` throws again on every Retry (`tempo_cubit.dart:267`, `:520`).
  - The Loop Tempo choice stays disabled, because the snapshot is null.
  - `runClickExclusive` refuses Session Save and Load.
  - `flushClickMode` and Retry block soft power-off permanently (`app.dart:854-857`).
- The plan's "persistent Retry" has nothing to retry.
- Fix: scope the failure to Hear click and let audio start. Then give Retry an explicit repair: offer the four choices, or `restoreClickModeCheckpoint(null)`.

### 5. A Hear click edit while the pinned device is absent ends reconnect supervision (Medium; repeat of #1094 F1)
- `_requestClickMode` (`looper_repository.dart:7060-7103`) posts while the callback is stopped. After 500 ms, `_failClickMode` sets recovery and calls `stopEngine()` (:7146).
- That clears `_intendRunning` and the reconnect timer. `startEngine` then refuses (`clickModeRecoveryRequired`, :2446).
- Touch, MIDI and both External routes all reach this path. Retry repairs the state but does not restart audio.
- Fix as proposed in #1094: stage the change as stopped intent while `_isReconnecting`.

### 6. Copy-paste family machinery, now a seventh owned family (Maintainability; repeat of #1094 F7, #1095 F4, #1096 F4)
- `_supersedeClickModeClaims` (`control_midi.dart:1387`) is a copy of `_supersedeRecordTimingClaims`.
- The External and MIDI write blocks (`control_cubit.dart:1148-1173`, `control_midi.dart:1031-1062`) copy the Record-timing blocks.
- The `is …ValueTarget` chain now lists seven types at four sites.
- `clickModeCaptureLocked` (:7030) duplicates `recordTimingCaptureLocked` (:1140).
- The repository receipt machinery copies the timing receipt (around 150 lines).

### 7. Cubit-to-Cubit dependency extended (repeat of #1094 F6)
- ControlCubit takes TempoCubit as `ClickModeControl`.
- The Control views call `context.watch<TempoCubit>()`.
- TempoCubit (1,180 lines) now owns two durable transactions.

## Preexisting debt (exposure widened)
- Repair stops audio and never restarts it. `recoverClickMode` stops a running engine (:7171-7176). This happens in the deferred-during-capture case or from the Retry toast mid-playback. Record timing behaves the same way.
- `clickModeCaptureLocked` builds a full native snapshot on every call. TempoCubit (:764) and Control's eligibility tuple both call it on every looper emission, so each emission costs two extra snapshots. `_last` would suffice for UI and eligibility.
- Every expression jitter on a Hear click mapping runs a storage checkpoint and a native receipt, even when the choice is unchanged. During capture, each one also raises a refusal toast.

## Optional tests
- Finding 1: bump `mixGeneration` after the receipt settles but before `_writeMode` resumes. Assert that the Settings checkpoint equals `clickModeRestartIntent`.
- Finding 4: boot with `tempo.click_mode = 4`. Assert that audio starts and that a user-reachable repair succeeds.
- Finding 5: with a fake engine whose publishing is off and whose device is lost, make a Hear click edit. Reconnect must stay armed.

## Nits
- `_modeRevision = 0` on a lifetime change (`tempo_cubit.dart:752`) is unnecessary, since the lifetime is already compared. Because the reset is deferred while `_modeApplying` is true, an origin captured in that window can be superseded spuriously.
- While stopped, the repository projects the Held `_clickMode`, but restart replays Released. The readout shows a value that will not be heard (same as the #1095 nit).

Verdict: request changes. Finding 1 is a reachable divergence between persistence and the engine. Finding 4 is a reachable no-audio, no-power-off dead end. Finding 2 needs owner acknowledgment.

- F1 Low-Med: post-receipt lifetime bump rolls Settings back under an accepted mode (tempo_cubit.dart:389-411).
- F2 Low: absent-key default to First also changes existing routed installs, including count-in (audio_bootstrap.dart:39-41).
- F3 Low: readiness flickers off during own writes; editors drop the target (tempo_cubit.dart:241,763).
- F4 Medium (repeat #1095 F2): malformed or unreadable key blocks audio, Session and power-off with no repair (audio_bootstrap.dart:38-53).
- F5 Medium (repeat #1094 F1): edit during device loss kills reconnect (looper_repository.dart:7146).
- F6 Maint (repeat): seventh copy of the family machinery.
- F7 Arch (repeat): ControlCubit to TempoCubit dependency extended.
