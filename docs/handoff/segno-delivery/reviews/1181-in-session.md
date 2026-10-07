Model: Claude Opus (subagent), in-session

# Review of PR #1181, Part 2d (head f3f5b0b2c, base f0de50446)

**Scope:**
- `git diff f0de50446..origin/claude/settings-owner-1159-p2d` (one commit);
- `gh pr view 1181`;
- the plan's "Part 2d as built" section and decisions 31-37.

**Setup:** I worked in a temporary detached worktree under the scratchpad, built the native test library and exported `SEGNO_ENGINE_LIB`, then removed the worktree.

**Runs at the head:**

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` | 0 issues in 820 files |
| `flutter test test/looper test/app test/session test/control` | +2229 ~6, all passed |
| `looper_repository` | +781, all passed |
| `session_repository` | +122, all passed |

**Grep criterion:** no `_restore(Decay|Once|Length|RecordStart|ClickMode)`, no `flush(Decay|OneShot|RecordLength|RecordTiming|ClickMode|RecordStart)` and no `_Pending(Timing|LengthSettings|RecordStart|ClickMode|ClickVolume|OneShot|Mix)` remain in `lib` or `packages/*/lib`.

## Verified correct (traced)

1. **Fade on the shared owner.**
   - `FadeFamily` (`settings_families.dart`) holds `_live` and `_durable`, and `request` sets them. Gestures read `FadeSettings.live`, which is `owner.live`, exactly as before; Fade never had a native command.
   - Steps carry a fresh edit tag (`edit: relative ? Object() : null`), so they are never coalesced (decision 35). Absolute edits coalesce per address.
   - The record is read and written whole. `checkpointOf` writes back the stored bytes when the durable value is unchanged, so the defaults never materialize a key.
   - Repair writes the declared defaults, as Retry did before.
2. **`installSession`** (`settings_owner.dart`).
   - It requires the owner's `_exclusive` count, which the registry's `runExclusive` now maintains.
   - It writes the Session value to every storage address (Fade has one, the whole record).
   - On a write failure it rolls back, or owes, the stored value and rethrows.
   - It then makes the value both live and durable, which retires any held value, and marks the owner initialized. The Session revision already moved the lifetime, so earlier controller work is superseded.
3. **Removed Fade `runExclusive` and `flush`.** Session exclusion is now Mixer then the registry, and Fade is in the registry. Admitted Fade writes run before the operation because the operation queues behind them. `prepareShutdown`'s `owners.flush()` and `owners.recover()` include Fade. The compiler confirms nothing else called the removed APIs.
4. **The Mixer on `SettingsReceipt`.**
   - The `accepted` hook runs `_acceptMix` on both the staged path and the accepted path, so the caches still adopt every accepted vector.
   - `pending` exposes the in-flight `_MixIntent`. Image settlement mutates that same object (value and restart are the same instance), so the published images survive into acceptance or into the owed value.
   - `startEngine` adopts the current caches unless a vector is owed, then replays (`looper_repository.dart:2424`). Session replacement resets the owed value.
   - A startup timeout or refusal owes the vector, and audio keeps running.
   - Bootstrap (`audio_bootstrap.dart:316-327`) still fails the start when its own replay settle is not ok, and the owed vector replays at the next start. That is not a dead end.
5. **Session decode (decision 37). No existing install can lose a file.**
   - `Session.fromJson` accepts only `formatVersion == 11`, which was introduced 2026-10-05 (a921bd9a9 and 19a6faa8d). Older files were already refused with `SessionUnsupportedVersion` before this PR.
   - Every v11 writer validates its values. Count-in comes from the owner or repository pair, validated to `{0,1,2,4}` since bc19d65e4 (2026-10-03). Per-track maps come from repository caches whose setters reject channels outside 0-7.
   - Back to the first count-in UI (47428104a, 2026-07-23), every UI path offered only 0, 1, 2 and 4, and `LE_MAX_TRACKS` has always been 8.
   - A bad file used to fail during apply, after the rig was cleared. Refusing it at read time is a pure improvement.
6. **Decision 34 (Save captures Fade's durable value).** While Fade is unavailable, that value is the in-memory defaults, which is also what Retry repairs to. This is consistent with decision 30.
7. **Layering and Bloc.** No new cubit methods. `FadeSettings` and `MixSettingsCoordinator` stay in the application and app layers. `bloc lint` is clean.

## Findings

### 1. High: a Mixer edit made while a vector is owed stores the new candidate, but Retry lands the old owed vector

- **Where:** `lib/app/mix_settings_coordinator.dart:580-690` (`_commit`). The early return at `:663` keeps storage whenever `_repository.mixRecoveryRequired` is true. It does not check that the repository owes *this* candidate.
- **Trigger:**
  1. Mixer publication is withheld.
  2. `setTrackPan(.4)` returns recoveryRequired; storage holds candidate 1 (.4) and the repository owes .4.
  3. Second edit: `setTrackPan(.8)`. `_commit` writes storage (candidate 2, .8). `applyMixSettings` is refused with notReady because the receipt refuses requests while a value is owed. Since `mixRecoveryRequired` is true, `_commit` returns recoveryRequired **without rolling storage back**.
  4. Publication resumes and the user presses Retry. It re-sends the owed .4 and reports applied.
- **Reproduced** (probe M1, added to `mix_settings_coordinator_test` and then removed):
  - After the second edit: recoveryRequired, `durable=candidate 2`, stored pan 0.8, `restores=0`.
  - After Retry: **applied**, engine pan **0.4**, storage pan **0.8**.
- **Impact:**
  - Storage and engine disagree with no notice; the engine flips to .8 at the next boot.
  - This is reached through the natural recovery path. An autonomous owe (Finding 2) has no notice, so the user's first sign of trouble comes from touching a mix control, and that touch performs step 3.
  - It is the same defect class as Part 1 finding 1.
  - At the base, a timeout stopped the engine; later edits were staged into the caches and storage agreed.
- **Smallest fix:** at the top of `_commit`, return `recoveryRequired` without touching storage while `_repository.mixRecoveryRequired` is true. That matches how the owners refuse writes while a value is owed. The alternative is to keep storage only when the owed vector equals the candidate.
- **Verified:** with that 6-line guard, the probe stores nothing new (candidate 1, .4), Retry lands .4, and `test/app`, `test/control`, `test/session` and `test/audio_setup` all pass.

### 2. Medium: an autonomous Mixer owe silently refuses every new take (decision 36)

- **Where:**
  - `looper_repository.dart:2778` refuses a fresh take while `_mix.recoveryRequired`.
  - Uncertainty reaches only the repository's `mixSettingsFailures` stream, and nothing in `lib` listens to it.
  - The Mixer notice in `app.dart` is fed only by `MixSettingsCoordinator.failures`, which emits only for the coordinator's own writes.
- **Trigger:** a reconnect or restart whose mix replay is unconfirmed (publication withheld for longer than 500 ms).
- **Reproduced** (probe M2): `mixRecoveryRequired=true`, audio running, `record()` returns **notReady**, coordinator notices **0**, while `coordinator.recoveryRequired` is true.
- **Impact:**
  - The pedal's Record does nothing, and there is no toast and no Retry.
  - Recovery exists, but the user has to find it: touch a mix control (which then hits Finding 1), use power-off Retry, or wait for a device reconnect.
  - At the base audio stopped, also with no notice. This PR keeps audio running, but turns Record into the silent failure.
  - Decision 36 assumes a Mixer notice ("the Mixer notice says audio was stopped only when it was"), but none fires for this path.
- **Smallest fix:** have `MixSettingsCoordinator` listen to `repository.mixSettingsFailures`. When `mixRecoveryRequired` is true and no coordinator operation is running, `_report` a `recoveryRequired` outcome, which shows the existing Retry notice.

### 3. Medium: after a device restart, a held Fade duration stays live and its release is refused (decision 33)

- **Where:**
  - Fade's fence is now the shared lifetime, which includes `mixGeneration`. A device restart therefore changes it.
  - `ControlCubit` reacts (`control_cubit.dart:3562-3567`) by superseding every Fade claim, and an origin-fenced release is refused.
  - Fade has no restart replay. Nothing retires `FadeFamily._live`, unlike the receipt families, where `startEngine` replays the restart value. Decay sets `_overdubDecay = _restart` at start.
- **Trigger:**
  1. A pedal holds Default at 5 s (Released 1 s).
  2. The device restarts or reconnects.
  3. The pedal is released.
- **Reproduced** (probe F1, at the FadeSettings level):
  - Head: `liveAfterRestart=5000`, `released=false`, `live=5000`, `confirmed=1000`. Every later gesture uses the temporary 5 s.
  - Base f0de50446, same probe: `released=true`, `live=1000`.
- **Impact:** after any reconnect during a Fade hold, the held duration persists in live until the next Fade edit, a Session load or an app restart.
- **Smallest fix (either):**
  - When Fade's owner sees a lifetime change, retire `live` to `durable`, for example a `retireLive` hook that `_sync` calls for a family with no receipt.
  - Or fence Fade on the Session revision only, as before.

## Notes

- **Decision 31's wording.** "Queues behind and applies after" holds for Session Save. For Session *load*, a queued Fade edit carries the old lifetime and is superseded, and `_edit` treats superseded as success, so the edit is dropped silently. It used to be refused with an error. That may be the right outcome, but the decision text overstates it.
- **Decision 32 is visible on close without power-off.** An in-flight Fade write at `close()` is now rolled back. `prepareShutdown` flushes first, so power-off is safe. A plain app close loses an edit that was in flight; it used to complete. This matches the other owners since Part 1.
- **Test edits.**
  - `app_runtime_test` "real Session save waits for an admitted duration edit and captures it" dropped `expectLater(fade.setDefault(8000), throwsStateError)`. Its replacement behaviour (the edit queues and applies after the save) is asserted in `fade_settings_test` ("Session capture waits for admitted edits; a later edit applies after it", 6000 then 8000).
  - The Fade test "refuses without a write during recovery" became "a write before load starts the load", matching the shared contract.
  - Nothing tests a Fade controller write while the stored record is unreadable. Fade is not in the shared contract suite; adding `contract(_fade)` would pin it, together with Finding 3.
- **No hidden data loss from decision 37:** see item 5. The refusal only affects files no released writer could produce.

**Verdict:** Request changes. Finding 1 (High) breaks the "storage and engine agree" guarantee for the Mixer and has a verified 6-line fix. Findings 2 and 3 are reproduced regressions with small fixes.

---

## Delta review (98a093cf7)

**Scope:** `git diff f3f5b0b2c..origin/claude/settings-owner-1159-p2d`, one commit. Production changed in four files: `mix_settings_coordinator.dart` (+40), `settings_families.dart` (+33), `settings_owner.dart` (+6) and the plan. Tests changed in 26 files, including 24 mock stubs.

**Setup:** I worked in a temporary detached worktree with `SEGNO_ENGINE_LIB` built and exported, and removed it afterwards.

**Runs at 98a093cf7:**

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `flutter test test/looper test/app test/session test/control test/audio_setup test/pedal test/screenshots` | +2611 ~49, all passed |
| `looper_repository` | +781, all passed |
| `bloc lint` | 0 issues in 820 files |

### My three findings, re-probed

| Probe | Result at 98a093cf7 | Verdict |
| --- | --- | --- |
| M1: second Mixer edit while owed | The second edit is refused with recoveryRequired and **no** storage write (1 candidate, `durable=candidate 1`). Retry is applied with engine pan **0.4** and storage pan **0.4**. | Fixed |
| M2: unconfirmed restart replay | The vector is owed and `record()` returns notReady. The coordinator emits **one** `recoveryRequired` notice. | Fixed |
| F1: held Fade across a device restart | `liveAfterRestart=1000`; the stale release is refused harmlessly; live 1000, confirmed 1000. | Fixed |

### Regression hunt

- **Can the Mixer guard block Retry or an edit that equals the owed value?**
  - `recover()` takes the owed path straight to `recoverMixSettings` and `settleMixSettings`. The rollback recovery and `rollbackExclusive` call `_rollback`, not `_commit`. Only the controller write path (`:345`) and the ordinary drain (`:577`) reach `_commit`, so the guard never blocks Retry; M1 confirms Retry lands.
  - An edit equal to the owed value is refused with recoveryRequired, and storage already holds that value. Retry is the path, so nothing is lost.
- **Does `_owedReported` clear, so a later owe is reported again?**
  - `_report` sets it whenever it emits a recoveryRequired outcome while a vector is owed. The `looperState` listener clears it once nothing is owed.
  - Probe P1 counts the notices:

    | Event | Notices emitted |
    | --- | --- |
    | Coordinator edit that ends uncertain | 1 (the autonomous `_reportOwed` is suppressed, so no double) |
    | Record press while owed | 0 more |
    | Second edit, refused | 1 more (it reports its own refusal, same toast id) |
    | After Retry, a new owed restart replay | 1 more |
- **Do the 24 mock stubs hide anything?**
  - They stub `mixSettingsFailures` to an empty stream, and in two places `mixRecoveryRequired` to false. This is what a coordinator built on a mock repository needs.
  - Those widget and page suites never exercise an owed mix. The owed paths are covered on a real `LooperRepository` in `mix_settings_coordinator_test`, which has two new tests matching M1 and M2.
- **Can `retireLive` run mid-gesture, or discard a value that should survive a restart?**
  - It runs only from `_sync` on a lifetime change, and only when the owner is not `_busy`. A Fade write in flight finishes first. Its post-write `_sync` then retires, so a held value written just before a restart cannot outlive it.
  - A gesture reads `live` when the command is issued. Retiring changes only the next gesture.
  - The held value is discarded on a device restart even if the pedal is still physically down. Decision 33 states this explicitly, and it matches the receipt families, whose restart replay lands the durable value.
  - For every receipt family `retireLive` is a no-op. On a Session load, `installSession` sets live and durable to the Session's value right after.
- **Does decision 31's wording match the behaviour?** Yes. After a Save, a queued Fade edit applies (pinned by `fade_settings_test`: 6000, then 8000). After a load, it is superseded with no notice, as the wording now says.

### Note

- **`MixSettingsCoordinator.flush()` returns applied while the repository owes a mix.** It returns `_recovery ?? _applied` and does not look at `mixRecoveryRequired`, so a plain power-off proceeds. Storage holds the owed vector (decision 38) and the next start replays it, so nothing is lost. This differs from the owners, whose `flush` reports recoveryRequired while a value is owed. It is already the case at f3f5b0b2c and is not introduced here. Worth an owner call.

**Delta verdict:** Approve. All three findings are fixed, and no regressions turned up.
