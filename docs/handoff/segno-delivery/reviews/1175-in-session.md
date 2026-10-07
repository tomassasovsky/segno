Model: Claude Opus (subagent), in-session

# Review of PR #1175, Part 2b (head b52ef2156, base claude/settings-owner-1159-p2 at 2a03ec1a9)

Scope: `git diff origin/claude/settings-owner-1159-p2...origin/claude/settings-owner-1159-p2b`, `gh pr view 1175`, and the plan's Part 2b block, "2b as built" section and decisions 16-21. I reviewed in a temporary detached worktree under the scratchpad and removed it afterwards.

Runs at the head:

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` (scratch worktree) | 0 issues in 820 files |
| `flutter test test/looper test/app test/control test/session` | +2067 ~111, all passed |
| `looper_repository flutter test` | +733 ~44, all passed |
| `pub get` | No churn |

## Verified correct (traced)

1. **The address parameter.**
   - A waiting write is replaced only by a write to the same address with the same edit (`settings_owner.dart:358-371`). The stale-release rule also applies only within one address.
   - Revisions are kept per address (`:495`) and cleared when the lifetime changes. A stale release whose ordinary write sits in an older waiting slot still fails the run-time fence (`:393`).
   - `durableAfter` (`:420`) takes only the written address from the new value, so a held track keeps its Released value when another address is edited.
   - The unit families keep their behaviour: they list `[null]` as their addresses, `durableAfter` returns the written value, and `revision` is `revisionOf(null)`.
   - Mutation checks:
     - Dropping `sameAddress` from the replacement rule fails "a write to another address never replaces a waiting one".
     - Making revisions global fails the per-address fence test and 3 Decay dispatch cases.
2. **Decay without a receipt** (`settings_families.dart:556-588`).
   - A request sends only the addresses that changed. Ordinary and controller writes change one address, so a refusal leaves nothing to send back. A multi-address send happens only for a restore or staging, and nothing can be held then: the owner is not yet ready, so no controller target resolves.
   - When a send-back is itself refused, the repository caches stay equal to what the engine admitted. The caches only change on an ok send, and the restored values are the stored ones, so storage, cache and engine still agree. A partial restore reports unavailable and Retry completes it.
   - The failure stream is empty, so a refusal is reported once, by the owner.
   - A refused admission in `startEngine` still fails the start, as for every family. A refused restore never stops audio.
3. **Loop/Once as whole-vector sends.**
   - `_sendOneShot` (`looper_repository.dart:7728-7766`) sends the whole vector in two grouped masks. The receipt accepts only when all eight callback bits match.
   - A refusal after the first group returns ok with an immediately uncertain check (`:7742`), so the vector is owed and audio is not stopped.
   - The startup replay (`:2584`) still fails the start if the first group is refused.
   - `adopt` (`:3895`) does exactly what Part 2a's `_trackOneShot.clear()` / `_restartTrackOneShot.clear()` did, after `reset()` has cleared the owed value. `_retireEngineLifetime` has already cancelled any pending receipt.
4. **The removed Once start gate.** In Part 2a it existed only because uncertainty stopped audio. The owed vector now replays at start. `oneShotSettingsSettled` lost its owed term, but nothing in `lib` reads it. Record and Play never checked Once. Nothing is left unguarded.
5. **Bootstrap.**
   - Count-in, Hear click, Decay and Loop/Once are staged in the old order (`audio_bootstrap.dart:44-51`), all before `_tryAutoStartEngine` opens the device. The engine is stopped, so each request takes the staging path.
   - Click volume has never been staged at bootstrap (Part 1 decision 6); it loads through its owner after start.
   - The typed `_stageOrLog<V, C>` is needed. `_readAll` builds a `Map<Object?, C>`, and under an erased list type that map fails the family's covariant parameter check at run time. Inside the owners the types stay concrete, so the registry is unaffected.
6. **Decision 19.** The `_reading` flag (`settings_owner.dart:642`) makes a family available as soon as a Session is recalled during its startup read. The later read then fails the session-pin check, so it restores nothing.
7. **LooperBloc.**
   - Removing `LooperTrackOverdubDecayChanged` and `LooperOneShotToggled` leaves no dead path; the compiler proves no dispatcher remains.
   - The Loop settings page writes through `PlaybackOptionsCubit` to the owners.
   - `LooperPersistFlush` no longer waits for these writes, but `prepareShutdown` calls `owners.flush()` after it, and that flush drains every queued write.
8. **Part 1 lessons, re-probed** (probe file since deleted):

   | Probe | Result |
   | --- | --- |
   | D1 | A Decay release with a stale track-2 revision is superseded, while one for track 5 applies |
   | D2 | Held track 2 at 90 (Released 10) plus a default edit to 40: live (40, {2: 90}), durable (40, {2: 10}), store `track_overdub_decay.2` = 10 |
   | D3 | A refused Decay edit is rejected and reported once; no stop; owner still ready |
   | O2 | Second Once group refused: recoveryRequired, owed, no stop, store keeps the value; Retry lands it |
   | O4 | A Once edit inside an owed replay window applies with no report |
   | X1 | Held Once track keeps Released `false` across a default edit |

   The contract suite also runs for Once at `defaults` and `track(3)`: owed until accepted, cancelled or refused Retry, failed start, timeout reported once, and Session recall over Retry, also for Decay. `app_test` covers notice dismissal for Once.
9. **Tests.**
   - The two inverted bootstrap tests follow decision 17. They now assert that audio opens with no stop, and they keep the old assertions that the prior intent and the bad stored value are intact.
   - The `decayReplayResult` assertion goes with decision 21.
   - In `app_test`, the Decay and Once stores now mutate and then throw, with compensation refused. That preserves the blocked-power-off scenario that decision 20 would otherwise turn into a clean rollback. New tests cover a compensated refusal permitting shutdown.
   - The deleted transaction suites are replaced by the per-family and per-address owner tests, which this mutation testing showed are not trivial.
10. **Layering.** `PlaybackOptionsCubit` methods return `Future<void>`; `bloc lint` is clean.

## Findings

None blocking.

## Notes

- **A latent hazard in Decay's send-back path** (`settings_families.dart:571-577`). After the undo loop, `setDecayRestartIntent(this.durable…)` re-reads the restart caches, which the undo just set to the prior *live* values. If a multi-address request were ever sent while one of those addresses was held (live ≠ durable), the held temporary value would become durable. No path reaches this today: holds exist only on a ready owner, whose writes change one address. The fix is to capture `durable` before the loop. Worth doing before Part 3 widens what can send multi-address writes.
- **Undo results are ignored.** By the reasoning in item 2 this is harmless today. A comment would stop a future reader from treating it as a mixed-engine bug.
- **Decision 20 changes shutdown, not stored data.** Power-off no longer blocks after a refused Decay or Once write whose rollback landed: storage and engine both hold the prior value, so nothing is owed. This is the Part 1 defect-2 fix applied to these families. Stored data and defaults for existing installs are unchanged.
- **Decision 17 for existing installs.** An unreadable Decay or Once value now opens audio with the repository's values, and the family is unavailable until Retry. Before, audio did not start.

**Verdict:** Approve. The address parameter, Decay without a receipt, whole-vector Once, the typed bootstrap staging and the Bloc removal are correct, and every Part 1 lesson holds for Decay and Once.
