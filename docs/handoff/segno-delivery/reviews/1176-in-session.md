Model: Claude Opus (subagent), in-session

# Review of PR #1176 (Part 2c), with the 2a and 2b deltas

## Setup and runs

- Heads:

  | Branch | Head |
  | --- | --- |
  | `p2c` | 9f79f2c15 |
  | `p2b` | 33c60cdb8 |
  | `p2` | 72414ce0c |

- I worked in a temporary detached worktree under the scratchpad and removed it afterwards.
- I built the native test library with `bash tool/build_test_lib.sh` and exported `SEGNO_ENGINE_LIB`.

Runs at the 2c head:

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` (scratch worktree) | 0 issues in 820 files |
| `flutter test test/looper test/app test/control test/session`, native-backed included | +2178 ~6, all passed |
| `looper_repository flutter test` | +780, all passed |

**Correction to my 2a and 2b reviews.** Those runs did not export `SEGNO_ENGINE_LIB`, so the native-backed Session persistence tests were skipped there; this explains the ~111 skips. At 2a03ec1a9, with the library exported, `record_start_persistence_test` "unconfirmed pair cannot overwrite the previous session file" **fails**: it expects a Save refusal, but the Save succeeds. The 2a delta below fixes that test.

---

## Diff 1: 2c (`p2b...p2c`)

### Verified correct (traced)

1. **The Decay send-back fix.** `DecayFamily.request` now captures `priorDurable` before any send and restores it on refusal. A held temporary value can no longer become durable. The comment records why send-back results are not checked.
2. **The length and timing receipts.**
   - Timing keeps its `prior+2` revision fence. Its verdict is: exact vector match means accepted; result failure with the prior vector still intact means refused; anything else is uncertain (`looper_repository.dart:1143-1199`).
   - Length keeps its snapshot match (`:1297-1355`). It accepts a vector that has landed and differs from the prior one, even while a take is capturing. An unchanged vector during capture reads as refused (decision 25).
   - `_lengthChangeMode` is set around the startup replay (`:2394-2396`) and around Retry (`:1373-1375`). The remembered mode is therefore re-sent on every start, and an owed vector cannot loop forever.
3. **The shared `captureLocked`** (`:415`) is `_intendRunning && any track recording or overdubbing`.
   - Length's lock used to read the stale snapshot while stopped. Now an edit while stopped only stages a value, and no capture can begin until `startEngine` replays the staged vector, so nothing slips through.
   - The length and timing sends refuse admission while locked.
4. **The removed gates.**
   - **`startEngine` length/timing gates:** they existed only because uncertainty stopped audio. Now the owed vector replays at start.
   - **`_requestMix` refusal on owed timing:** it guarded against an engine left in an unknown state after a stop. That situation can no longer occur.
   - **What still guards a fresh take:** Record still refuses on unsettled or owed timing (decision 24) and on an owed Count-in pair.
   - **What else stays:** the session-boot and Mixer fences.
5. **Multi entry.**
   - `RecordSettings.setLooperMode` retires the live overrides to `owner.durable.trackOverrides`, as 2b's `setLooperMode(trackOverrides: retired)` did.
   - `supersededBy` then advances all eight track revisions and emits supersede events.
   - A held track release that arrives after Multi entry is therefore superseded, and no held temporary value leaks into the overrides.
6. **`checkpointOf(durable, address, stored)` for timing's tuple.** It replaces only the written address within the tuple read for this write. Writes are serialized, so a write to another address cannot lose an update. A rollback restores the exact tuple. Other addresses keep their stored preference, not a Session-recalled durable value.
7. **`LooperPersistFlush` removal.**
   - It awaited only the length and timing writes plus an FX flush.
   - The length and timing writes now go through the owners, so `prepareShutdown`'s `owners.flush()` drains them.
   - `fxPersistence.flush()` still runs directly in `prepareShutdown`.
   - No `lib` code calls repository length or timing setters outside the families. Mode changes go through `RecordOptionsCubit`, which is provided app-wide (`app.dart:631`). The only call site is `loop_mode_page.dart`.
8. **Bootstrap.** Length is staged, then timing, after the four 2b families and before `_tryAutoStartEngine`. That is the old order. An unreadable value falls back to defaults (decision 22). An unconfirmed startup replay is owed (decision 23).
9. **Part 1 lessons, re-probed for timing and length** (probe files since deleted):

   | Probe | Result |
   | --- | --- |
   | T1 | Timing Retry cancelled by a stop: recoveryRequired, still owed; after a restart, flush applied and the engine holds the value |
   | T2 | A stale timing release at track 2 is superseded; one at track 5 applies |
   | T3 | A timing timeout is reported once; an edit inside the owed replay window applies |
   | T4 | A Session recalled while timing is unreadable wins over Retry (live `{3: quarter}`) |
   | L1 | Length Retry cancelled by a stop keeps 8 owed; a restart lands it |
   | L2 | A length timeout is reported once |

   `app_test` covers notice dismissal for length and timing.
10. **Test changes.**
    - The flips in `length_receipt_test`, `record_timing_receipt_test` and `recording_settings_test` follow decisions 22-26.
    - The receipt failure streams no longer carry admission refusals. The owner reports those, and no `lib` caller bypasses the owners.
    - The new tests assert concrete values: the published lengths, the capture lock while running and stopped, and the Mixer edit while timing is owed.

### Findings

**1. Medium: decision 27 is not implemented. Save captures an unconfirmed length vector.**

- **Where:** `lib/session/application/session_settings_coordinator.dart:71`.
- **Cause:**
  - `capture` refuses only when `!_looper.lengthSettingsSettled`.
  - By the time `capture` runs, `SettingsOwners.runExclusive` has already awaited each family's `settle()` (`settings_owner.dart:331-336`).
  - A pending length receipt that ends uncertain is therefore already settled, and owed, when the check runs.
  - The check passes, and `capture` records the owed vector.
- **Trigger** (fake engine): free mode; withhold the length publication and the command fence; call `setTrackRecordLength(channel: 2, bars: 4)`; run `coordinator.runExclusive(() => coordinator.capture(...))`.
- **Reproduced:**
  - At 2c: the edit returns recoveryRequired, the vector is owed, and capture **succeeds** with `trackLengthPresetOverrides = {2: 4}`.
  - At 2b, same probe: the Save is refused with `Bad state: Record length is not confirmed`.
- **Impact:**
  - A Session file can record a length vector the engine never confirmed.
  - That is a regression against 2b. It contradicts the PR's own decision 27 ("Session capture still waits for a pending length receipt and fails if it does not confirm, as before").
  - Nothing tests decision 27.
- **Smallest fix:** after the settle in `capture`, add `if (_looper.lengthRecoveryRequired) throw StateError('length settings did not settle before session save');`. Also stub `lengthRecoveryRequired` to false in `test/session/cubit/session_cubit_test.dart`'s mock repository.
- **Verified:** with that change the probe refuses the Save. The `test/session` and `test/app/application` suites pass, except four `session_cubit_test` cases that fail only because the mock lacks the stub.

**2. Low (recorded decision; tension with rule 1): Retry over one malformed timing key erases every valid timing setting.**

- **Where:** `RecordTimingFamily.repair` (`settings_families.dart:1202`), together with the per-address `_repairStorage` loop.
- **Trigger:** stored `looper.quantize = true`, `tempo.quantize_div = 2`, `track_record_timing.4 = 99` (bad), `track_record_timing.6 = bar`. Press Retry.
- **Reproduced:**
  - Before: `{looper.quantize: true, tempo.quantize_div: 2, track_record_timing.4: 99, track_record_timing.6: 2}`.
  - After: `{}`. Live is Immediately with no overrides.
- **Impact:**
  - An existing install loses its default gate and division and every valid track override, to repair a single bad key.
  - The values are only logged.
  - Decision 22 records this, but the reader validates each override separately, so only the bad key needs to go.
- **Smallest fix:** repair per key. Drop the invalid overrides and any invalid default scalar, and keep the rest.

### Notes

- **The decision 15/27 split.** For Count-in, capture deliberately saves the owed, unconfirmed pair (see diff 2). For length, the PR intends to refuse. If the owner wants one rule for both, write it down.
- **A second FX flush is gone.** `LooperPersistFlush` gave shutdown a second `fxPersistence.flush()` after the bloc's earlier events had started. Shutdown now flushes FX once, earlier. FX edits whose bloc handler awaits before it schedules a save are no longer caught by a later flush. This is marginal; I did not reproduce it.
- **Length and timing are not in the shared contract suite** (`settings_owner_test.dart:650-654`). My probes T1-T4 and L1-L2 show the behaviour is right. Adding them to `contract(...)` would pin it.

**Verdict for 2c:** Request changes, for Finding 1 (a small fix). Finding 2 needs an owner call or a per-key repair.

---

## Diff 2: 2a delta (`2a03ec1a9..72414ce0c`)

- **The change.** One test-only commit (`72414ce0c`) changes `record_start_persistence_test` "an unconfirmed pair is never saved". It now expects Save to succeed while Count-in is unavailable, and asserts that the saved bundle holds the confirmed pair (0, false) and that the manifest bytes are unchanged.
- **With the native library:**
  - It passes at `p2`.
  - The old version fails at 2a03ec1a9 (Expected not success, Actual success). The update follows decision 15; it does not weaken a working assertion.
- **What the test covers.** A Sound edit refused at storage, where the write throws and its rollback fails. The engine never receives it, durable stays (0, false), and Save writes (0, false). Correct.
- **What it does not cover.** A Sound or Count-in edit whose **receipt is uncertain**. Then `durable` is the owed, requested pair.
  - Probe (fake engine, receipt withheld, `setCountInBars(4)`): the edit returns recoveryRequired, the engine holds 1, and capture writes `(4, false)`.
  - So Save can write a pair the engine never confirmed. It is the value storage holds and the next restart replays, which is decision 15 as recorded.
  - The test name "an unconfirmed pair is never saved" overclaims. "Save keeps the stored pair while Count-in is unavailable" would be accurate.

**Verdict for the 2a delta:** Approve. It is test-only and correct for its scenario. Rename the test, or add the receipt-uncertain case, so the name stops overclaiming.

---

## Diff 3: 2b delta (`git range-diff 2a03ec1a9..b52ef2156 72414ce0c..33c60cdb8`)

- **The original commit is unchanged.** `b52ef2156 = 0a5ff4cb3`: the range-diff shows no change in the Decay and Loop/Once commit. `git diff b52ef2156 0a5ff4cb3` contains only the inherited 2a test change.
- **One new commit, test only.** `33c60cdb8` changes eight test files, `SettingsOwners(tempo.owners)` → `SettingsOwners([...tempo.owners, ...playback.owners])`, in the Session persistence suites and `looper_page_test`. Production already registered both (`app_runtime.dart`).
- **Why it was needed.** The suites are native-backed, and so were skipped in my 2b run. Without this wiring, the Playback owners would have been outside Session exclusion in those tests.

**Verdict for the 2b delta:** Approve. Only test registry wiring changed.

---

## Delta review (f0de50446)

**Scope:**
- `git diff 91870e731..origin/claude/settings-owner-1159-p2c`: commits 85505a09b, 2d89a2b2f and f0de50446.
- `git show cfab821dd`.

**Setup:** I reviewed in a temporary detached worktree, with `SEGNO_ENGINE_LIB` built and exported, and removed the worktree afterwards.

**The rebase.** `git range-diff 72414ce0c..9f79f2c15 cfab821dd..91870e731` shows all four earlier commits as `=` (0a5ff4cb3→9ff2d0ad7, 33c60cdb8→6a3d7d144, 26c03aa9b→2dbbcd501, 9f79f2c15→91870e731). The rebase changed no patch.

**Runs at f0de50446:**

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `flutter test test/looper test/app test/session test/control` | +2225 ~6, all passed; the two new native Session tests ran, they were not skipped |
| `looper_repository` | +780, all passed |
| `settings_repository` | +198, all passed |

### Verified (traced and probed)

1. **The Save rule (decision 30, which supersedes 27).**
   - `capture` no longer checks length (`session_settings_coordinator.dart:67-73`). The registry's `runExclusive` settles each family before the operation. Save therefore waits for a pending receipt, then writes each family's durable requested value. That includes a value owed after an uncertain receipt, which the engine never confirmed. This is now the stated rule for every family, and it matches Count-in (decision 15).
   - **Recall goes through a receipt.** `_applySession` sends each value with the setter and then requires its settle to succeed (`_requireSessionSetting`). An owed value saved to a file is re-applied with a confirmed receipt, or the load fails.
   - **The new native tests really withhold the receipt.** They cancel the pump timer (`pump.cancel()`), so the unpumped native engine consumes no command. They assert `recoveryRequired`, an owed value, and the durable vector or pair. The saved bundle holds the requested value (`{2: 4}` and `(4, false)`). After Retry and a move to another value, `loadNamed` brings back 4 with nothing owed and the receipt settled.
   - **Nothing else in capture lost a guard.** The mix settle and flush and the FX settle remain. Owner writes cannot run during the operation because the registry holds every owner. A restart replay that started mid-capture would replay the same durable value.
2. **The per-key timing storage** (2d89a2b2f).
   - **Same keys, no migration.** The family reads the same keys as before: `looper.quantize`, `tempo.quantize_div` and `track_record_timing.N`. The new per-key readers validate exactly what `_validateRecordTimingCheckpoint` did (division 0..5, overrides 0..6, no rules across keys).
   - Probe K1 loads an existing install `{quantize: true, div: 3, track 2: 2, track 6: 0}` as quarter with `{2: bar, 6: immediately}`, without rewriting the store.
   - **Atomicity.** A track write writes only its own key. Probe K4: setting track 5 adds `track_record_timing.5: 3` and leaves every other key untouched.
   - The default write is two verified scalar writes. In probe K3 the division write fails: the outcome is recoveryRequired with the store unchanged, and after Retry the store is exactly the original.
   - **Exact repair.** Probe K2: a bad `track_record_timing.4 = 99` alongside valid keys is the only key removed by Retry, and the gate, division and other overrides survive. `app_test`'s malformed case now asserts that only the unreadable key goes and that the default stays quarter.
3. **The 44 new contract cases** (f0de50446). These are the shared `contract(...)` suite (9 cases) plus `unreadable(...)` (2 cases) for each of length at default, length at track 3 (Free mode), timing at default and timing at track 3. Each asserts literal oracles: the store keys, the fake engine's published presets or timing, the repository restart intent, zero stops, Retry and restart landing the owed value, one report per timeout, and Session recall winning over Retry. The `refuseLength`/`refuseTiming` hooks drive real admission refusals. Adding length and timing to the suite closes the coverage gap from my earlier review.
4. **The `session_cubit_test` mock.**
   - `SettingsOwners([])` becomes `SettingsOwners([_LengthOwner(looper)])`. The fake reproduces what the registry does: it waits for a pending length receipt whatever its result, then runs the operation.
   - The test still asserts that Save waits (`verifyNever(save)` before the receipt completes). The `accepted=false` branch flips from failure to success with `defaultLengthPresetBars: 8` saved, following decision 30.
   - The wait under test now lives in the fake, so this test proves the coordinator routes through the registry. The real waiting is covered by the owner suites.
5. **cfab821dd (2a).** Test-only. It renames the test to "a Sound edit refused at storage leaves the stored pair, and Save keeps it while Count-in is unavailable", which now describes exactly what it tests.

### Findings

None.

### Notes

- **The new per-key repository API has no direct unit tests.** `readRecordTimingGateCheckpoint`, `readRecordTimingDivisionCheckpoint`, `readRecordTimingOverrideCheckpoint` and the three matching `restore*` methods are not tested in `packages/settings_repository` (still 198 tests). The contract suite, `app_test` and my probes cover them indirectly. A small test of range rejection and exact-absence round-trips would pin the package API.
- **The default-timing write is no longer one call.** It is two sequential verified writes. A failure between them leaves a mixed stored default only until the owner's rollback or the owed checkpoint restores it, which probe K3 confirmed. That is acceptable, but worth knowing.

**Delta verdict:** Approve. Decision 30 is implemented as stated, and an owed value is saved and then recalled through a receipt. The timing storage keeps the same keys, writes per key and repairs exactly. The new contract cases are real, and the 2a rename is accurate.
