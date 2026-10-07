Model: Claude Opus (subagent), in-session

# Review of PR #1165 (head 5ae5f4809, base c9b420d4)

Scope: `git diff origin/claude/fade-duration-targets-1148...origin/claude/settings-owner-1159-p1`, the plan sections 2, 3 Part 1 ("Part 1 as built"), 5 and 7, issue #1159.

Runs at the PR head:
- `dart analyze --fatal-infos lib test packages`: no issues.
- `flutter test test/looper/application test/app test/control`: +1302 ~86, all passed.
- `packages/looper_repository flutter test`: +725 ~44, all passed.
- `pub get` produced no file churn (`git status` clean).
- `bloc lint lib test packages` exits 64 "No files found" inside a git worktree, so it could not be run here. I checked the changed cubit methods by hand instead: `TempoCubit.setClickVolume` and `setClickMode` both return `Future<void>`.

## Verified correct (traced)

1. **Defect 1 (timeout).** `SettingsReceipt._uncertain` (`packages/looper_repository/lib/src/settings_receipt.dart:184-191`) records the owed value and never stops the engine. Both Click gates are gone from `startEngine` (`looper_repository.dart:2522-2530`). `recoverClickMode`/`recoverClickVolume` (`looper_repository.dart:7618-7622, 7687-7691`) no longer stop. Reconnect reaches `_clickVolume.replay()`/`_clickMode.replay()` (`:2546, :2605`).
   - Mutation check: I restored stop-on-uncertainty through the receipts' `publish` hook. 5 app cases and 11 repository cases then failed.
2. **Defect 2 (flush).** `cancel()` no longer writes `_lastResult` (`settings_receipt.dart:122-127`). `SettingsOwner.flush` reads only the current flags (`lib/looper/application/settings_owner.dart:159-171`).
   - Mutation check: I restored the history-derived flush and set `_lastResult = notReady` on cancel. The app_runtime_test flush case then failed.
3. **Defect 3 (storage).** `_repairStorage` re-reads before it writes (`settings_owner.dart:406-415`), so a transient read is not overwritten. The repair goes through the verified writer and logs the old value.
   - Mutation check: with no repair write, 4 app cases failed.
4. **Defect 4 (rollback after accept).** An accepted receipt commits without a lifetime re-check (`settings_owner.dart:355-365`).
   - Mutation check: with a rollback when `!current()`, exactly 3 cases failed. This matches the PR table.
5. **Absent Hear click key.** It still loads First recording, in the family (`lib/looper/application/settings_families.dart:107-109`) and in bootstrap (`lib/app/audio_bootstrap.dart:69-71`). Owner rule 1 holds.
6. **Session capture.** It reads `owner.durable` (`lib/session/application/session_settings_coordinator.dart:97-98`). That getter is `_owed ?? _restart` (`settings_receipt.dart:62`), which is the value an uncertain write leaves in storage.
7. **Writes across a Session load.**
   - A write captured before a Session load is superseded through the lifetime fence (`settings_owner.dart:283-287, 331, 342`).
   - A write whose receipt is cancelled by the load rolls storage back. `_retireEngineLifetime` cancels the receipt (`looper_repository.dart:855-857`), and `_rollback` follows (`settings_owner.dart:372-380`).
   - Session replacement clears owed values (`looper_repository.dart:3887-3888`).
8. **`ControlCubit` fences.** `ControlCubit` still reads `clickModeCaptureLocked`/`clickModeSettled` from the repository (`lib/control/cubit/control_cubit.dart:1299-1300`). They now map to the receipt's `settled` (`looper_repository.dart:7559`) and the unchanged capture-lock getter (`:7565-7571`), so the release-eligibility tuple still changes when a receipt completes. An ordinary write still bumps `_revision` only when it is applied (`settings_owner.dart:358-361`), so `control_midi.dart:1362` stays exact for writes that were applied. Finding 2 covers the coalescing gap.
9. **Layering.**
   - `settings_receipt.dart` is not exported from the package barrel.
   - `settings_families.dart` imports only repository packages.
   - The two views that now import `looper_repository` for `kMaxClickGain` follow an existing pattern: 46 view files already import it.
10. **Flipped tests, each checked against the base.** None weakens an assertion. Each flips a pinned defect or an owner decision recorded in the plan, or it strengthens the assertion.
    - `settings_receipt_lifetime_test`: the stop count changed from `hasLength(1)` to `isEmpty`. This is defect 1.
    - `timing_ownership_cubit_test`: `clickReady` changed from false to true. This is decision 6.
    - `app_test:975`: `confirmedClickVolume` changed from 1 to null. This is decision 6.
    - `app_test:1764`: a malformed key is now repaired, with an exact store assertion. This is decision 3.
    - `audio_bootstrap_test`:
      - The malformed cases now start audio Off, with the start, stop and request counts asserted. This is decision 5.
      - The admission-refused case still asserts that startup fails.
      - The unconfirmed case asserts the owed value and the restart intent.

## Findings

### 1. High: Retry or a restart replay that does not complete loses the owed value

**Where:** `packages/looper_repository/lib/src/settings_receipt.dart`.
- `replay()` (`:87-94`) and `recover()` (`:98-106`) set `_owed = null` before the receipt lands.
- `cancel()` (`:122-127`) does not restore the owed value.
- The non-startup refusal branch of `_settle` (`:172-176`) does not restore it either.

**Trigger.** Start from a value that is owed after a timeout: storage 1.5, restart cache 0.5. Any of these loses it:
- (a) Retry is pressed, then a stop, reconnect or Session load retires the lifetime within the 500 ms receipt window.
- (b) `startEngine` replays the owed Click volume, then a later startup stage refuses admission and `startEngine` calls `stopEngine()`. The later stages are timing, Record start, Hear click, length and Once (`looper_repository.dart:2546-2641`).
- (c) The device drops again during the reconnect replay (`_attemptReconnect`, `:2318-2320`).
- (d) The callback refuses a Hear click Retry.

**Reproduced** in a worktree-only probe that reuses the `settings_owner_test` rig:
- (a) `owner.recover()` returns **applied**, and `owner.ready` is true. `clickVolumeRecoveryRequired` is false and `clickVolumeRestartIntent` is 0.5, while the store holds 1.5. The next `startEngine` plays 0.5.
- (b) After a failed start caused by `refuseMode`, owed=false and restart=0.5. The next start plays 0.5 and the store holds 1.5.

**Impact.**
- Storage and engine disagree silently. The owner reports ready, Retry reports success, the toast clears and `prepareShutdown` passes.
- The engine then flips to the stored value at the next app boot.
- This breaks the PR's central claim that "a restart or reconnect replays the owed value… storage, repository and engine agreeing". It applies to both families, and to every family that later moves onto `SettingsReceipt` in Part 2.

**Smallest fix.** Keep `_owed` until the receipt is accepted. Verified: probes (a) and (b) then pass, and the app and repository suites stay green.
- In `replay()` and `recover()`, drop the pre-clear and set `_owed = null` only when `result.isOk && _pending == null` (the stopped/staged path).
- Add `_owed = null;` to the `accepted` branch of `_settle`.

### 2. Medium: coalescing lets a fenced controller write replace a waiting ordinary Hear click choice

**Where:** `SettingsOwner._admit` (`lib/looper/application/settings_owner.dart:262-280`) together with the revision fence in `_write` (`:283-287`).

**Trigger.**
1. A pedal hold captures `(lifetime, revision r)`.
2. Ordinary choice A (Record) is in flight; its receipt is not yet published.
3. The user taps B (Play+Rec), which waits.
4. The pedal release `setController(off, revision: r)` arrives and replaces B as the waiting write, so B returns superseded.
5. A applies and bumps the revision to r+1, so the release is superseded too.

**Reproduced.**
- PR head: A=applied, B=superseded, release=superseded. Final value is **Record**; the store holds 1.
- Same sequence on the base (`setClickMode`/`setControllerClickMode`): A=applied, B=applied, release=superseded. Final value is **Play+Rec**; the store holds 3.

**Impact.**
- The user's latest Hear click choice is dropped. `app.dart` shows nothing for superseded, so the user gets no notice.
- If the in-flight item does not bump the revision (a load, Retry or refused write), the stale release itself applies over B. That is the case the origin fence exists to prevent.
- Click volume has no revision fence and is unaffected.

**Smallest fix.** In `_admit`, when the waiting write is ordinary and the incoming write carries a `revision`, complete the incoming write as superseded and keep the ordinary one. The waiting ordinary write will bump that revision when it applies. Verified: the probe passes and the app suites stay green.

### 3. Medium: Retry after a recalled Session overwrites the Session's value with the repaired preference

**Where:** `SettingsOwner.recover` re-runs `_restore()` (`settings_owner.dart:218-220`). `_restore` captures the *current* session revision (`:418`), so the "a recalled session is newer authority" check at `:446` passes, and it requests the stored value.

**Trigger.**
1. `tempo.click_mode = 9` makes Hear click unavailable at startup.
2. The player loads a Session with Hear click set to Play+Rec. The engine plays Play+Rec.
3. The player presses Retry on the toast, or power-off Retry calls `prepareShutdown(retry: true)`.

**Reproduced.**
- PR head: `recover()` returns applied. Live and durable both become **Off** and the store holds 0, so the next Session Save captures Off.
- Base: `recoverClickMode()` returns recoveryRequired, the live value stays Play+Rec and the store keeps 9.
- Click volume follows the same path: the repair removes the key and unity is applied over the Session's gain. Traced, not run.

**Impact.**
- Pressing Retry changes the loaded Session's audible Hear click or Click gain, and changes what the next Save stores.
- The new repair step makes this happen on every malformed key. On the base it was only reachable through a transient read.

**Smallest fix.** Pin the session that the load belongs to: `_loadSession ??= _repository.sessionRevision` in `_restore`. A re-run after a recall then initializes without applying. Verified: the probe keeps Play+Rec with the store repaired to 0, and the app, control and session suites stay green.

### 4. Low: a timeout during an owner write is reported twice

**Where:** The receipt's failure stream is an async broadcast (`settings_receipt.dart:56`). `SettingsOwner._onReceiptFailure` (`settings_owner.dart:477-488`) suppresses events only while `_busy`. On the uncertain path `_write` returns synchronously after `settle()` resumes (`:366-371`). The `finally` block clears `_busy` before the stream event is delivered.

**Trigger:** `owner.set(1.5)` with publication withheld, then a 510 ms wait.

**Reproduced:** `owner.failures` emits `[recoveryRequired, recoveryRequired]`.

**Impact:**
- The Click toast is presented twice under the same id, and the error is logged twice.
- This contradicts the plan's "one failure stream and one report path (today a timeout reports twice)".

**Smallest fix:** Use `StreamController<EngineResult>.broadcast(sync: true)` for the receipt's failures. The family is the only listener. This fix is untested.

## Notes

- **Deleted coverage without a successor.**
  - `click_mode_transaction_test` "obsolete failed initialization adopts an accepted replacement session". The behaviour is kept at `settings_owner.dart:424-431` but is no longer tested.
  - `click_volume_transaction_test` "ordinary accepted same-value edit removes durable held projection". It still holds by trace, but is no longer tested.
- **Mutation counts** (app suites, plus the repository package for defect 1):
  - Defect 1: 5 app cases and 11 repository cases. The mutation also changed two other-family startup tests.
  - Defect 2: 1 app case. The PR claims 3; the other two may live elsewhere.
  - Defect 3: 4 app cases.
  - Defect 4: 3 cases.
- **Design consequence, not counted as a finding.** A held Click volume high (for example 1.5) keeps sounding while a recovery is owed. `ClickVolumeTarget` is not in the cleanup allow-list at `control_midi.dart:1241-1249`, and the receipt refuses requests while a value is owed. On the base the engine stopped instead. Retry restores the Released value.

**Verdict:** Request changes. Finding 1 breaks the PR's core guarantee that storage, repository and engine agree after uncertainty. Findings 2 and 3 are regressions against the base that a player can hear.

---

## Delta review (2cda4ac63)

Scope: `git diff 5ae5f4809..2cda4ac63`, which touches:
- `settings_receipt.dart`, 19 lines changed;
- `settings_owner.dart`, +10;
- tests;
- the plan, which gains decision 9.

I reviewed it in a temporary detached worktree at 2cda4ac63 and removed that worktree afterwards.

**Runs at 2cda4ac63:**
- `dart analyze --fatal-infos lib test packages`: clean.
- App suites (`test/looper/application test/app test/control`): +1314 ~86, all passed.
- `looper_repository`: +727 ~44, all passed.
- `pub get`: no churn.

### Original findings, re-probed

All four are fixed. Each probe now gives the correct result:

| Finding | Probe | Result at 2cda4ac63 |
| --- | --- | --- |
| 1 | A1: Retry, then a stop inside the receipt window | Retry → recoveryRequired; owed=true; restart=1.5; next start plays 1.5 |
| 1 | A2: a later startup stage refuses | owed=true; restart=1.5; next start plays 1.5 |
| 2 | B: stale release vs. a waiting ordinary choice | A applied, B applied, release superseded; value Play+Rec; store 3 (same as base) |
| 3 | C: Retry after a recalled Session | live and durable Play+Rec; store repaired to 0 |
| 4 | D: write timeout | one report |

### The new tests assert the fixes

Each fix test fails when its code is reverted to 5ae5f4809:
- **Old receipt:** 7 owner cases fail (cancelled Retry ×2, failed start ×2, single report ×2, refused Retry) and 2 receipt cases fail (cancelled Retry ×2).
- **Old owner:** 3 cases fail (stale release, recalled Session ×2).

The two restored tests ("an obsolete failed load adopts an accepted replacement Session" and "an ordinary same-value edit removes the held Released value") pass on both versions. They restore coverage rather than test a fix, and they assert concrete values: Off and ready; durable 0.25 then 1.5, store 1.5, ordinary `[1.5]`.

### Regression hunt (traced)

- **Owed never cleared.** `_owed` is cleared on an accepted receipt (`settings_receipt.dart` `_settle`), on stopped staging (`_admit` stopped path), and on Session `reset()`. A replay or Retry that is refused or uncertain keeps the value owed. That is the intended "replays until accepted" behaviour, not an endless loop: each start replays once.
- **Stopped staging clears too early.** It does not. The `_admit` stopped path is reachable with a value owed only from `recover()`, and `request()` refuses while a value is owed. `replay()` always runs with `_intendRunning == true`. Staging writes `_restart = owed`, which the next start replays.
- **The supersede rule drops a legitimate controller write.**
  - It differs from the base only when two things hold together: the write in flight does not bump the revision (a controller write, load or Retry), and the waiting ordinary write then fails to apply.
  - In every other order, the base also supersedes the newer controller write, because the waiting ordinary write bumps the revision when it applies.
  - Click volume carries no revision and is unaffected.
  - Not a finding.
- **`_loadSession` pinning.**
  - The pinned value is read only by `_restore`, and `_restore` re-runs only from `recover()` while the owner is uninitialized.
  - A device-lifetime change keeps `sessionRevision`. Probe G (an unreadable key, a stop/start, then Retry) repairs to Off and applies it.
  - `_repairStorage` runs regardless of the pin.
  - A later Session load correctly blocks applying the stored preference.
- **Sync failure stream re-entrancy.**
  - `_report` runs after the receipt state is final, in both `_settle` and `_uncertain`. The listener chain (owner `_report` → toast / `_changes` → `TempoSettings._syncFromRepository`) only reads getters and the engine snapshot. It never re-enters `_observeSettingsReceipts` or adds to the same controller.
  - Probe H (an autonomous restart-replay timeout while the owner is idle) reports exactly once.

### Delta findings

**5. Low: an edit during an owed value's restart replay is refused as a recovery.**

- **Where:** `SettingsOwner._write` checks `_recoveryPending` before it settles (`settings_owner.dart:294`). Since this delta, `_family.recoveryRequired` stays true while the replay of an owed value is in flight.
- **Trigger:**
  1. A Click write times out, so the value is owed.
  2. The engine restarts or reconnects. The replay is admitted, but its receipt has not been published yet.
  3. The user sets 0.75 within that window.
- **Reproduced (probe E):**
  - Inside the window, ready=false and owed=true.
  - The edit returns recoveryRequired and the owner emits a recovery failure.
  - Once the replay lands, ready=true with the value at 1.5 and the store at 1.5. The user's 0.75 is dropped.
  - At 5ae5f4809 the edit waited for the settle and applied.
- **Impact:**
  - The edit is lost, and a Click recovery toast with Retry appears. `app.dart` never dismisses Click recovery toasts on its own, so the toast stays although nothing is owed any more.
  - The window is normally one callback (milliseconds). When the device flaps it lasts up to 500 ms, but in that case the outcome is a recovery anyway.
- **Smallest fix:** make the pre-settle check consider only `!_initialized || _unreadable != null || _owedRollback != null`. The post-settle `_family.recoveryRequired` check at :318 still refuses a value that is genuinely owed.
- **Verified:** with that change, probe E gives applied with value 0.75, and the app suites plus all probes pass.

### Notes

- **Pre-existing in this PR, not introduced by the delta.** A Click or Hear click recovery toast is not dismissed when a reconnect replay resolves the owed value. Its Retry then succeeds trivially. Fade calls `_controlNotices.dismiss`; Click does not.

**Delta verdict:** Findings 1-4 are fixed and their tests are real. One Low regression (5) remains in a narrow replay window. Approve once 5 is fixed, or accept it as a known follow-up; nothing above it blocks merge.
