Model: Claude Opus (subagent), in-session

# Review of PR #1172, Part 2a (head 2a03ec1a9, base claude/settings-owner-1159-p1 at 4fdde224e)

**Scope:**
- `git diff origin/claude/settings-owner-1159-p1...origin/claude/settings-owner-1159-p2`;
- `gh pr view 1172`;
- the plan's Part 2, 2a, "2a as built" and decisions 11-15.

**Setup:** I worked in a temporary detached worktree under the scratchpad and removed it afterwards.

**Runs at the head:**
- `dart analyze --fatal-infos lib test packages`: no issues.
- `flutter test test/looper/application test/app test/control test/session`: +1420 ~111, all passed.
- `looper_repository flutter test`: +733 ~44, all passed.
- `bloc lint lib test packages`: 0 issues across 822 files. This worktree sits outside `.claude/worktrees`, so the linter could analyze it.
- `pub get` caused no churn.

## Verified correct (traced)

1. **Registry order and deadlocks.**
   - `SettingsOwners.runExclusive` acquires Click volume, then Hear click, then Count-in, each with `load()` and then its own `_queue` (`lib/looper/application/settings_owners.dart:18-24`).
   - Every exclusive caller nests in one order: fade, mix, owners, playback, record, timing (`session_settings_coordinator.dart:52-60`). There is no other `runExclusive` caller on the owners. `audio_bootstrap` uses only Mixer; `monitor_cubit` and `control_cubit` use only Mixer.
   - The Session load body under exclusion (`session_cubit.dart:235-300`) awaits no owner write, flush or recover.
   - `prepareShutdown` calls `owners.recover()` and `owners.flush()` outside any exclusive (`app_runtime.dart:189, 219`).
   - Result: no lock-order inversion and no self-wait.
2. **Edit-tag queueing.**
   - A same-tag write replaces only the newest waiting slot (`settings_owner.dart:326-331`). A different tag gets a new slot queued behind it (`:333-344`).
   - Each write computes its value from `_family.live` after `settle()` (`:378`), which is the last accepted pair. A queued Sound edit therefore composes with an earlier Count-in edit.
   - I traced every interleaving of Count-in and Sound slots, including replacement in the middle of a run. Each ends at the latest user intent in admission order.
   - Mutation check: with the tag check removed, "queued edits of different kinds both apply, in order" fails.
3. **Count-in receipt.**
   - The revision fence is `prior+1`, and only `_sendRecordStart` issues native pair commands (`looper_repository.dart:7396-7430`).
   - The verdict is "refused" only when the prior pair is intact; anything else is "uncertain".
   - `_recordStartEdit` is set and restored around one synchronous `request`. Replay and Retry therefore send `restore`.
   - Play refuses only while a receipt is pending (`:3259-3262`). It returns immediately rather than waiting, and the 500 ms deadline always settles the receipt, so it cannot deadlock.
   - A fresh take still refuses while a pair is owed (`:2976-2981`).
   - Mutation check: putting the owed-pair gate back on Play fails the repository test.
4. **The deleted `startEngine` gate.** `recordStartRecoveryRequired` existed only because Part 1 stopped audio on Count-in uncertainty. The pair now replays its owed value at start (`:2571`), and Session replacement resets it (`:3861`). Nothing else read the gate.
5. **Bootstrap `stageStored`.**
   - It runs once, from `run_segno.dart:185`, before `_tryAutoStartEngine` opens the device (`audio_bootstrap.dart:41-52`).
   - With the engine stopped, `request` takes the staging path, so an unreadable value leaves the repository's untouched default, (0, false). It cannot leave a stale pair.
   - The owners load after `AppRuntime` is built, so they do not race the staging.
6. **The unified notice.**
   - One subscription pair per registered owner (`app.dart:218-227`), keyed by `_ownedNotice` (`:322`), with the same three toast ids as before.
   - `recovered` dismisses the notice.
   - Every old source is gone: `recordStartFailures`, `_showRecordStartFailure` and the TempoSettings repository listener. Removing the API proves no caller is left.
7. **Part 1 lessons re-probed for Count-in** (my probes, now deleted):
   - **Q1:** a stale Count-in release behind a waiting Sound edit is superseded, and the final pair is (0, true).
   - **Q4:** a Count-in edit inside an owed restart replay applies, with no failure report.
   - **Q5:** an autonomous replay timeout reports exactly once.
   - **Q6:** an owed pair refuses Record and allows Play.
   - **Q7:** after a Session load, Retry keeps the Session's pair (4, false) and repairs storage to (0, false).
   - The contract suite also runs all three families. That covers the owed value kept until accepted and the failed start after a replay.
8. **Flipped tests** (`record_start_receipt_test`, `audio_bootstrap_test`, `app_test`, `count_in_session_shutdown_test`, `record_start_persistence_test`).
   - Each flip follows a recorded decision:
     - a timeout now owes the pair and keeps audio;
     - an unreadable pair starts audio with (0, false);
     - a malformed pair is repaired on Retry;
     - a refused admission still fails the start.
   - The dispatch and persistence suites change only construction and accessor paths.
   - The bootstrap test narrowed `store.values == before` to the two Count-in keys. The full map is no longer valid once audio starts, and the keys under test are still asserted exactly.
9. **Layering and Bloc.**
   - `audio_bootstrap` (composition) and `app.dart` import application-layer owners, the same way they already import `AppRuntime`.
   - `TempoCubit` methods still return `Future<void>`.
   - `bloc lint` is clean.

## Findings

None that block. I traced the six hunt areas and re-probed the Part 1 lessons for Count-in; nothing failed.

## Notes (not findings)

- **Stale-release rule edge.** The rule supersedes a revision-carrying controller write whenever the newest waiting write is ordinary (`settings_owner.dart:321`). Part 1 would instead have applied that controller write in one case only: the waiting ordinary write then fails to apply, for example because it came from an older lifetime or the engine refuses it. In every other order Part 1 also supersedes it. This now covers Count-in pedals too, but it is narrow, and the user's latest UI intent still wins.
- **Coverage moved, not lost.** `record_start_transaction_test` (756 lines) was deleted. These scenarios are now covered by the shared contract suite and the Count-in dispatch suite rather than by named tests:
  - "partial second scalar write restores complete checkpoint" (traced: `_rollback` rewrites both keys through `restoreRecordStartCheckpoint`, which verifies the read-back);
  - "device restart applies Released and refuses the retired lifetime";
  - "capture refusal retains Released until same-origin release succeeds".
- **Already present in Part 1.**
  - A held Count-in is not retired to its Released pair on `stopEngine`; only Click volume calls `retireLive`. While stopped, an ordinary Sound edit therefore computes from the held count-in. Part 1 did the same.
  - A pedal Count-in clears Sound start in its Released pair, and `count_in_session_shutdown_test` asserts this.
- **Existing installs.**
  - An unreadable or unconfirmed pair now starts audio with Count-in unavailable. Before this PR, audio did not start at all.
  - An owed pair refuses Record (with a recovery notice) instead of stopping audio.
  - Both are less restrictive than Part 1 and both are recorded decisions (12, 13 and 15). The absent-key default (1 bar, Sound off) is unchanged.

**Verdict:** Approve. The registry, the Count-in migration, bootstrap staging and the unified notice are correct, and all Part 1 lessons hold for Count-in.
