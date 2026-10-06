# Plan: one settings-transaction owner for the seven owned setting families

Tracking: #1159 (under #1026), `autonomy:merge-gate`. Part 1 is built on
branch `claude/settings-owner-1159-p1`, on top of PR #1156's head
(`claude/fade-duration-targets-1148`); Parts 2-4 are planned. Sections 1-2 and
Parts 2-4 cite `file:line` against `origin/codex/fade-clear-history` (PR #1145
head) unless marked `@1156`; the Part 1 as-built notes name files only.

Owner decisions applied (issue #1026, 2026-10-05): consolidate the seven
families onto one owner and fix the four repeated defects once; the power-off
dialog blocks only recording; "Power off anyway" after a failed Retry; Hear
click with no saved value stays Off on existing installs; track-volume mappings
top out at unity by default.

## 1. What the stack already fixed, and what it did not

PR #1111 moved every family out of its Cubit into application objects:
`TempoSettings` (Click volume, Hear click, Count-in/Sound start;
`lib/looper/application/tempo_settings.dart`, 1,466 lines), `PlaybackSettings`
(Decay, Loop/Once; 891), `RecordSettings` (Record length and loop mode; 592),
`RecordTimingSettings` (511) and `FadeSettings` (194). Cubits are thin adapters
(`lib/looper/cubit/tempo_cubit.dart`, 49 lines) and `ControlCubit` receives the
owners through `*Control` interfaces (`lib/app/application/app_runtime.dart:69-86`).
The Cubit-to-Cubit findings (#1094-6, #1095-3, #1096-5, #1097-9, #1098-7,
#1099-7) are resolved, except that `LooperBloc` still forwards five events to
the owners and tracks their futures for `LooperPersistFlush`
(`lib/looper/bloc/looper_bloc.dart:726-770, 833-841, 867-872`).

What remains is five copies of one transaction, each with its own bugs:

- Defect 1, timeout stops audio and ends reconnect. `_failMix`
  (`packages/looper_repository/lib/src/looper_repository.dart:900-903`),
  `_failTiming` (:1371-1381), `_failLength` (:1567-1575), `_failRecordStart`
  (:7546-7556), `_failClickMode` (:7695-7706), the Click volume expire and
  mismatch paths (:7788-7792, :7806-7811) and `_failOneShot` (:8149-8157) call
  `stopEngine()`, which clears `_intendRunning` and stops reconnect polling
  (:2969-2983); `startEngine` refuses while any family is in recovery
  (:2545-2555). Retry stops a running engine (:1403, :7578, :7728) or refuses
  while running (:1595, :8188). `TempoSettings._recoverFailedClick` blocks start
  and stops (`tempo_settings.dart:1419-1423`). The deadline is 500 ms (:8432).
- Defect 2, flush reports history. `flushDecay` returns `_last`
  (`playback_settings.dart:773-779`), `flushOneShot` returns `_lastOneShot`
  (:532-546), `flushRecordLength` returns `_last` (`record_settings.dart:449-462`).
  A cancelled Once receipt leaves `_lastOneShotResult = notReady` (:8160-8167),
  so `oneShotSettingsSettled` stays false (:8124-8127) and `_restoreOnce`
  reports recovery while stopped (`playback_settings.dart:244-251`).
- Defect 3, fail-closed storage with no repair. Readers throw `FormatException`
  (`settings_repository.dart:840-847, 913-924, 991-998, 1020-1026, 1895-1925,
  1965-1984`; Fade via `FadeDurations.fromJson`, `fade_settings.dart:63-67`).
  Bootstrap stops the engine and returns `recoveryConfig: null` for any family
  failure (`lib/app/audio_bootstrap.dart:31-220`). Every `recover*` re-runs the
  same read (`tempo_settings.dart:407-409, 791-793`; `playback_settings.dart:602-604,
  818-820`; `record_settings.dart:514-516`; `record_timing_settings.dart:472-474`;
  `fade_settings.dart:134-148`). Every `run*Exclusive` throws while
  uninitialized (`tempo_settings.dart:878-898`, `playback_settings.dart:827-843`,
  `record_settings.dart:521-534`, `record_timing_settings.dart:479-491`,
  `fade_settings.dart:38-41`), so Session Save/Load fail, and `prepareShutdown`
  throws on every flush failure (`app_runtime.dart:214-248`).
- Defect 4, storage rolled back after the engine accepted. A lifetime check
  after a successful settle throws `superseded` and the catch restores the
  checkpoint: `_writeMode` (`tempo_settings.dart:277-279, 297`),
  `_writeRecordStart` (:661-663, 681), `_writeClickVolume` (:1368-1369),
  `_writeOneShot` (`playback_settings.dart:470-476, 494`), `RecordSettings._write`
  (:382-384, 412), `RecordTimingSettings._write` (:327-331, 353).

## 2. The shared owner

### 2.1 Repository half: `SettingsReceipt`

New `packages/looper_repository/lib/src/settings_receipt.dart`, one instance per
family, replacing the seven `_Pending*` classes and their `_cancel*`, `_fail*`,
`settle*`, `recover*`, `*Settled`, `*RecoveryRequired` and `*Failures` members.
`_ReceiptObservation` (:8430) moves in unchanged. Surface: `settled`,
`recoveryRequired`, `lastResult`, `failures`, `settle()`, `recover()`. The
family supplies `request(intent)` (native command plus expected revision or
match predicate), `accept(intent, restart)` (today's `_acceptTiming`,
`_acceptLength`, `_acceptOneShot`) and `matchesPrior(snapshot)`.
`_retireEngineLifetime` (:871-889) and `_observeSettingsReceipts` (:2197-2211)
iterate a list.

Fixed once here:

- Timeout never stops the engine. On expiry the receipt is uncertain:
  `recoveryRequired`, recovery intent = the requested durable vector (the
  accepted restart cache is kept underneath it), one failure published,
  reconnect supervision untouched. The command ring is FIFO, so Retry
  re-issues the durable vector as a new receipt that lands after any late one;
  reconnect reconfigures (discarding the queue, :2333-2340) and replays the owed
  vector in place of the restart cache, so uncertainty resolves itself with
  storage and engine agreeing.
  `startEngine` drops the seven family gates (:2549-2554), keeping only the
  session-boot and Mixer fences.
- `recover()` never stops: running, it re-requests the recovery intent;
  stopped, it stages it.
- Cancel completes the waiter with `notReady` and leaves `lastResult` alone.
- One capture-lock getter guarded by `_intendRunning` (Record length reads the
  stale snapshot while stopped, :520-524; timing does not, :1215-1216).
- `_requestMix` stops refusing on `recordTimingRecoveryRequired` (:825).
- Family settle predicates stay family code: Record length accepts a match on
  the pending vector even when capture began after it landed, and refuses
  cleanly only when the prior vector is intact (today :1537-1565 stops the
  engine mid-take).

No C change: the revision fences for Hear click, Count-in and timing and the
snapshot matches for the rest are kept.

### 2.2 Application half: `SettingsOwner` and families

New `lib/looper/application/settings_owner.dart` and
`settings_families.dart`. `SettingsOwner<A, V, C>` is generic over address
(`int?` channel or unit), domain value and storage checkpoint. A family
provides `validate(A, V?)`, `readCheckpoint() -> C` (may throw
`FormatException`), `writeCheckpoint(C)` (verified), `withDurable(C, A, V?)`,
`repair(C?) -> C` (what Retry writes for invalid storage: an absent track key,
`(0, false)` for the pair, Off for Hear click, the default Fade record),
`request(A, V live, V durable)` (may complete without a receipt, which is how
Decay and Fade join), `receipt` (optional), `live()`, `durable()` and
`captureLocked()`. Normalized-travel conversion stays on the targets in
`lib/control/binding/control_value_target.dart`.

Contract, identical for every family:

- Lifetime is `(sessionRevision, mixGeneration)` (`tempo_settings.dart:115-118`).
  Per-address revisions are bumped by ordinary writes and supersede events and
  cleared on lifetime change.
- `set(address, value)` is ordinary: latest-wins per address while a
  transaction is in flight (today every `setClickVolume` call queues a read,
  write and settle, `tempo_settings.dart:1249-1255`), bumps the revision, emits one
  `OrdinaryChange(address, value?, superseded)`. `setController(address, value,
  {lifetime, revision, released})` is origin-fenced; `released != null` is Held
  (live `value`, durable `released`). Controller writes coalesce per address, so
  a sweep costs at most one storage write per in-flight receipt.
- Storage and Session capture receive durable; readouts receive live.
- Every write awaits `receipt.settle()` before admission (today a write within
  one poll of a replay is refused, `record_timing_settings.dart:317-328` with
  `looper_repository.dart:1263-1265`).
- Commit-on-accepted: read checkpoint, write durable, request, settle. `ok`
  means committed: publish and return `applied` with no lifetime re-check.
  `rejected`/`invalid` rolls storage back. Uncertain keeps the durable value in
  storage, because the recovery intent is that vector.
- `flush()` drains, settles and derives the outcome from current flags only.
- Readiness is `initialized && !recoveryPending`; the owner's own in-flight
  write does not flip it (today `_modeReady` includes `!_modeApplying`,
  `tempo_settings.dart:129-133`; `_startReady` includes `!_startApplying`,
  :461-465), and looper-state handling is never skipped behind `_applying`
  (`playback_settings.dart:118`).
- Load: an invalid checkpoint makes only this family unavailable; the engine
  starts. A lifetime change while uninitialized does not fake initialization
  (today `playback_settings.dart:120-134` publishes ready after a failed restore).
- `recover()`: repair invalid storage through the verified writer and log the
  old value; restore an owed rollback checkpoint; `receipt.recover()`; re-run
  the restore. Never stops audio.
- One failure stream and one report path (today a timeout reports twice,
  `tempo_settings.dart:33-47` and :695-705).
- `SettingsOwners.runExclusive` acquires every family in a fixed order,
  replacing the nested `run*Exclusive`
  (`lib/session/application/session_settings_coordinator.dart:45-58`).

### 2.3 Where it lives

Repository: `packages/looper_repository`. Application: `lib/looper/application`.
Model: `lib/looper/model/owned_setting.dart` with one `SettingOutcome` (all
seven status enums are already identical, for example `click_mode.dart:26`).
Control owns its port, `lib/control/binding/owned_value_control.dart`
(`origin`, `originCurrent`, `writeController(target, normalized, released,
origin)`, `read`, `resolves`, `ordinaryChanges`, `eligibilityKey`); `AppRuntime`
implements it over the registry and the target conversions, the inversion
`takeLocked` already uses (`app_runtime.dart:85`). Neither `lib/looper/application`
nor `lib/control` imports the other. The registry is built in
`lib/app/run_segno.dart` beside `MixSettingsCoordinator` (:141) and passed to
`AppRuntime` like `mix` (`app_runtime.dart:113-114`), so bootstrap stages all
families with one `owners.load()` before `startEngine` instead of six copies
(`audio_bootstrap.dart:36-205`), and the runtime no longer replays them twice.

### 2.4 Family mapping

| Family | Address | Value | `C` | Native | Family-only code |
|---|---|---|---|---|---|
| Click volume | unit | `double` 0..2 | `double?` | `setClickVolume`, gain match | range check; literal `2` at :7755 becomes `kMaxClickGain` |
| Hear click | unit | `ClickMode` | `int?` | `setClickMode`, revision fence | default rule (Part 4) |
| Count-in/Sound | unit | pair | `(int?, bool?)` | `setRecordStartSettings`, revision fence | interlock (`record_start.dart:14-15`), edit kind |
| Overdub decay | `int?` | `int` 0..100 | `int?` | `setOverdubFeedback`, no receipt | `setDecayRestartIntent` (:340) |
| Loop/Once | `int?` | `bool` | `bool?` | `setOneShotMask`, bit match | mask grouping (:8071-8100) |
| Record length | `int?` and mode | `int` 0..64, `LooperMode` | `int?` | preset/mode commands | Multi retirement, `_editable` (`record_settings.dart:291-294, 362-367`) |
| Record timing | `int?` | `RecordTiming` | 10-scalar tuple | revision fence | division memory (:300-306) |
| Fade | `int?` | `int` ms | JSON record | none | `installSession` under exclusion |

Mixer stays on `MixSettingsCoordinator`: it is a vector edit with device-keyed
JSON persistence, reset and solo coalescing and `rollbackExclusive` for session
load (`lib/app/mix_settings_coordinator.dart:423-495, 697-712`), and already has
latest-wins coalescing and a current-state flush (:715-716). It gets Defect 1's
fix because `_failMix` becomes a `SettingsReceipt`. Its own findings
(#1093-3/4/5/6) go to a Mixer issue.

Fade joins. PR #1156 gave `FadeSettings` this exact contract (lifetime,
revisions, ordinary stream, `setControllerDuration`, live versus confirmed;
`fade_settings.dart@1156:26-67, 131-154`), a sixth copy. Fade is the family
with no native command, and Decay needs that case anyway. If #1156 merges
first, Part 2 deletes its copy; otherwise #1156 rebases onto Part 1.

## 3. Parts

### Part 1: `SettingsReceipt`, `SettingsOwner`, Click volume, Hear click

Status: built (branch `claude/settings-owner-1159-p1`).

Lands both halves and migrates the two unit-address families
(`tempo_settings.dart:84-412, 798-1445`). Deletes their repository copies
(:7585-7840), `_PendingClickMode` (:100-119) and `_PendingClickVolume`
(:8397-8411). Count-in stays in `TempoSettings` until Part 2. Two temporary
adapters keep `ControlCubit` dispatch untouched. Estimate: +750 / -950.

```success-criteria
GOAL: One receipt and one owner carry Click volume and Hear click with the four defects fixed; no other family changes behavior.
SUCCESS CRITERIA:
- A write with the device absent (fake engine accepts commands, never publishes) leaves reconnect armed, never calls engine stop, and startEngine is not refused; a late receipt or reconnect ends in applied. | verify: (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test test/settings_receipt_test.dart) && /Users/Tomas/development/flutter/bin/flutter test test/looper/application/
- flush() after a capture-locked refusal, a cancelled receipt while stopped, and a superseded write returns applied, and prepareShutdown completes. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app/application/app_runtime_test.dart
- With tempo.click_mode = 9 stored, audio starts, Hear click reads unavailable, recover() rewrites the key (asserted on the store fake), Session capture and prepareShutdown(retry: true) succeed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app/audio_bootstrap_test.dart test/looper/application/
- When the fake engine publishes the receipt and the lifetime bumps before the owner resumes, the store equals the repository restart intent and the new value. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/application/settings_owner_test.dart
- Twenty rapid ordinary Click volume writes cause at most two store writes; the last wins. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/application/settings_owner_test.dart
- click_dispatch_test and click_mode_dispatch_test pass with construction-only edits. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/
NON-GOALS:
- Other families, dispatch shape, power-off UI, defaults, Mixer internals, native code.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test)
```

#### Part 1 as built

Repository half. `packages/looper_repository/lib/src/settings_receipt.dart`
holds `SettingsReceipt<T>` and `ReceiptObservation` (moved unchanged apart from
being public inside the package; the receipt is not exported). A family supplies
one `send(value)` that enqueues its native command and returns a check that
reads the receipt as accepted, refused or uncertain. The receipt owns the live
and restart values, the owed value after uncertainty, `settle`, `cancel`,
`recover`, `replay` (startup and reconnect) and `reset` (Session replacement).
`LooperRepository` keeps two receipts, `_clickMode` (revision fence) and
`_clickVolume` (gain match), plus thin public wrappers that the families and
`ControlCubit` already read (`setClickMode`, `settleClickMode`,
`clickModeSettled`, `clickModeCaptureLocked`, and the Click volume
equivalents). `blockStartForClickRecovery`, `clearClickRecoveryStartBlock`, the
two Click gates in `startEngine`, every `stopEngine` call on Click uncertainty
and the stop in both Retry paths are gone. `_retireEngineLifetime` cancels the
receipts from a list, `_observeSettingsReceipts` polls their observers, and
`kMaxClickGain` now lives in the repository package (the literal `2` is gone).

Application half. `lib/looper/application/settings_owner.dart` holds
`SettingsFamily<V, C>` and `SettingsOwner<V, C>`;
`lib/looper/application/settings_families.dart` holds `ClickVolumeFamily`,
`HearClickFamily` and the two temporary adapters `ClickVolumeOwnerControl` and
`ClickModeOwnerControl`; `lib/looper/model/owned_setting.dart` holds
`SettingOutcome`, `SettingStatus` and `SettingLifetime`. `TempoSettings`
constructs both owners, exposes them (`clickVolumeOwner`, `clickModeOwner`) and
their adapters (`clickVolumeControl`, `clickModeControl`), and projects them
into `TempoState`; it keeps Count-in and the tempo grid. `TempoCubit`,
`AppRuntime.prepareShutdown`, the two `app.dart` toasts and
`SessionSettingsCoordinator` call the owners directly.
`SettingsRepository.saveClickVolume` and `loadClickVolume` were removed
(unused); the Hear click reader's `FormatException` now carries the stored
value for the repair log.

Decisions taken under the owner rules (2026-10-05):

1. Uncertain receipt (recorded decision; resolves open decision 2): storage
   keeps the requested durable value and Retry re-requests it. Storage follows
   the owed value: a failed write keeps its durable value only when it equals
   what the receipt owes, and otherwise rolls back.
2. A restart or reconnect replays the owed value instead of the older restart
   cache, so reconnect ends in applied with storage, repository and engine
   agreeing (rules 2 and 4).
3. Unreadable storage: Retry first re-reads; a transient failure that now reads
   cleanly is not overwritten. Data that stays unreadable is replaced through
   the verified writer and the old value is logged: Hear click is repaired to
   Off, Click volume by removing the key (unity). Rules 1, 2 and 5.
4. An absent Hear click key still loads First recording, in the owner and in
   bootstrap; changing that default is Part 4 (rule 1).
5. Bootstrap no longer stops audio when the stored Hear click is unreadable
   (the engine starts with the repository's Off and only Hear click is
   unavailable) or when its startup replay is unconfirmed (the receipt owes the
   choice). An engine that refuses to admit the startup replay still fails the
   start, unchanged.
6. Click volume readouts are unavailable while a recovery is owed, as Hear click
   readouts already were; the recovery toast is the notice (rules 3 and 4).
   Click volume also loads independently of the tempo grid now, and a write
   issued before load starts the load, as Hear click did.
7. A receipt cancelled by a stop or reconnect mid-write rolls storage back and
   reports superseded: the restart cache never took the value.
8. Session replacement clears both receipts' owed values (Hear click already
   did; Click volume now does too), and Session exclusion no longer refuses
   while Click volume or Hear click is unavailable: capture uses the
   repository's durable value. Count-in still refuses until Part 2.
9. Review of PR #1165: the owed value stays owed until a receipt is accepted
   (or a stopped engine stages it), so a cancelled Retry, a refused Retry or
   a start that fails after the replay keeps it. A fenced controller write
   cannot replace a waiting ordinary choice; it is superseded. The load is
   pinned to the session it started in, so Retry after a recalled Session
   repairs storage without replacing the Session's value. The receipt's
   failure stream is synchronous, so a write's timeout is reported once.
10. Delta review of PR #1165: a write waits for a restart replay of an owed
    value instead of being refused before it settles; only a value still
    owed after the settle refuses it. When a replay resolves an owed value
    without Retry, the owner signals `recovered` and the app dismisses the
    Click or Hear click recovery notice, the way it dismisses Fade's.

Deviations from the plan text:

- `SettingsOwner` has no address parameter `A` and `repair()` takes no
  argument: both Part 1 families are unit-address and an unreadable unit key
  has no partial checkpoint. Part 2 adds the address with the first channel
  family.
- No `SettingsOwners` registry and no construction in `run_segno.dart`:
  `TempoSettings` builds the two owners until Part 2 moves bootstrap,
  shutdown and Session exclusion onto the registry. `owned_value_control.dart`
  is Part 3.
- An ordinary write bumps the revision when it is applied, as before, not
  when it is admitted; controller writes keep their origin fence, and a newer
  write of either kind replaces one still waiting (latest wins, the replaced
  caller gets superseded). This keeps `ControlCubit`'s revision checks exact.
- The two transaction suites became `test/looper/application/settings_owner_test.dart`
  (the contract runs per family, then family cases); the two repository Click
  receipt suites became `packages/looper_repository/test/settings_receipt_test.dart`;
  `settings_receipt_lifetime_test.dart` keeps its cases with the stop
  assertions flipped. The dispatch suites changed only in construction and
  accessor paths (`tempo.durableClickVolume` became
  `tempo.clickVolumeOwner.durable`, and so on); no scenario or expected value
  changed. Tests that pinned the defects flipped: bootstrap stopping on a bad
  Hear click key, Retry leaving a malformed key in place, a Click readout during
  recovery, and every stop on Click uncertainty.
- Items of 2.1 that belong to other families wait for Part 2: one capture-lock
  getter for Record length and timing, `_requestMix` refusing on timing
  recovery, the Record length settle predicate, and the five remaining
  `startEngine` recovery gates.
- Size: production +1,306 / -1,275 lines against the +750 / -950 estimate.
  About 95 lines on each side are `ReceiptObservation` moving files; the rest
  of the overshoot is the owner and adapters in formatted Dart with API docs,
  and the larger deletion is `TempoSettings` (-873 / +75).

### Part 2: remaining families, bootstrap, shutdown, Session

Migrates Count-in/Sound start, Decay, Loop/Once, Record length and mode,
Record timing and Fade. Deletes `PlaybackSettings`, `RecordTimingSettings`, the
transaction halves of `RecordSettings` and `TempoSettings`, the repository
copies (:1130-1620, :7400-7585, :8040-8230), the six bootstrap stages, the
seven flush and seven recover blocks in `prepareShutdown` (`app_runtime.dart:176-248`)
in favour of `owners.flush()` and `owners.recover()`, the eight `_show*Failure`
toasts (`lib/app/view/app.dart:297-540`) in favour of one family-keyed notice,
the `LooperBloc` forwarding, and the nested exclusives in
`SessionSettingsCoordinator`. Pages keep their Cubit adapters
(`playback_options_cubit.dart:23`) and stop adding Bloc events
(`loop_playback_page.dart:64, 78`, `loop_length_page.dart:111`,
`looper_mode_change.dart:80`). Family fixes carried: Record length accepts a
post-apply capture; Multi entry emits supersede for all eight track targets
(today ordinary values for tracks that had an override,
`record_settings.dart:390-395`, which `ControlCubit` records as priority,
`control_cubit.dart:253-258`, so the owed release is never retried and
`flushMidiConfiguration` throws `ControlCleanupPending`, `control_midi.dart:40-42`);
Decay's failed restore reports unavailable instead of stopping
(`playback_settings.dart:195-197`); Play fences on `!settled` only
(`looper_repository.dart:3320`); Session JSON validates `countInBars` and override
keys at decode (`session.dart:795, 804-813`; only `_readTrackLevels` checks) so a
bad session is refused before `_awaitCleared` (:3993). Estimate: +750 / -2,900.

```success-criteria
GOAL: All seven families and Fade run on the shared owner; the duplicated transaction, bootstrap, shutdown and toast code is gone; behavior outside the four defects and the listed fixes is unchanged.
SUCCESS CRITERIA:
- The four Part 1 defect cases pass for every family through one parameterized suite with literal store and engine oracles. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/application/settings_owner_test.dart && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A record started after a length vector lands but before the poll is accepted with zero engine stops; a latched track-length hold released after entering Multi completes power-off. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/record_length_dispatch_test.dart test/looper/application/
- A stored pair (count_in_bars 2, auto_record true) starts audio; Retry repairs it to (0, false) in the store. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app/audio_bootstrap_test.dart test/looper/application/
- Session JSON with countInBars 3 or override key "8" is refused before the rig is cleared. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session/
- All seven dispatch suites and the Session persistence suites pass with construction-only edits. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/ test/session/
- No `_restore(Decay|Once|Length|RecordStart|ClickMode)`, `flush(Decay|OneShot|RecordLength|RecordTiming|ClickMode|RecordStart)` or `_Pending(Timing|LengthSettings|RecordStart|ClickMode|ClickVolume|OneShot)` remains in lib or packages. | verify: manual grep on the branch head.
NON-GOALS:
- Dispatch collapse, power-off UI, defaults, Mixer internals, native code.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
```

### Part 3: Control dispatch collapse

Adds `sealed class OwnedValueTarget extends ControlValueTarget` with
`relativeStep`, `coerce(double)` and a family key; the seven families extend
it. Replaces: the eight-type `||` chains (`control_cubit.dart:670-677, 784-791,
904-911`; `control_midi.dart:801-808`) with `is OwnedValueTarget`; the
`_midiStep` and `_coerceMidiValue` chains (`control_midi.dart:510-523, 1159-1182`);
the eight-field `_ControlOrigins` and six `_*OriginCurrent` helpers
(`control_cubit.dart:48-63`, `control_midi.dart:1300-1400`) with
`({mix, owned})` and the port's `originCurrent`; the seven External blocks
(`control_cubit.dart:1053-1270`) and seven MIDI blocks (`control_midi.dart:955-1110`)
with one `_writeOwnedValue` that resolves Released once; the seven constructor
subscriptions (`control_cubit.dart:180-270`) with one listener; the
`_releaseEligibility` tuple (`control_cubit.dart:1289-1307`) with
`eligibilityKey`; the seven snapshot parameters threaded through
`readValueTarget` and `valueTargetResolves` at eight call sites
(`control_value_resolver.dart:157-211`; `control_availability.dart`,
`expression_catalogue.dart`, `control_availability_view.dart`, `control_midi.dart`)
with one readout object; and the per-family `is X && snapshot == null` guards in
`midi_controls_page.dart` and `external_pedal_page.dart`. Two bounded #1093
fixes, each tested: `cancelled()` keeps session and close only and drops
per-target work through `originCurrent` (`control_midi.dart:416, 821-824`;
`control_cubit.dart:716-723`), and `_invalidateValueTargets` resets only the
jacks and devices mapping an invalidated target (`control_midi.dart:1447-1448`).
`_ownerOriginCurrent` on #1156 (`control_midi.dart@1156:1378`) is the seed.
Estimate: +180 / -760.

```success-criteria
GOAL: Dispatch handles every owned family through one target type, one origin record and one write helper; behavior is preserved except the two #1093 fixes.
SUCCESS CRITERIA:
- All seven dispatch suites and the literal-vector target tests pass with construction-only edits. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/
- A MIDI mapping {FX param, InputPan} with a pair link during the FX settle releases the FX value; an unrelated pair link keeps another jack's expression baseline. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/foot_mixer_dispatch_test.dart test/control/external_dispatch_test.dart
- No family type name appears in control_cubit.dart or control_midi.dart; the one exhaustive conversion switch lives in the app-layer port. | verify: manual grep on the branch head.
NON-GOALS:
- Owner internals, Mixer coalescing, MonitorVolume removal, new targets.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
```

### Part 4: owner-decided behavior changes

- Power-off blocks only recording. `takeLocked` is `power.state.isUiUp || ...`
  (`app_runtime.dart:140-141`) and gates expression (`control_cubit.dart:512`),
  queued External writes (:715) and MIDI parameter writes
  (`control_midi.dart:574, 598`). Split it: `takeLocked` keeps Rec, overdub and
  perf-arm; continuous writes gate on `_haltInputSuspended`, set when the flush
  starts (`control_midi.dart:17`).
- "Power off anyway". `PowerOffCubit` adds a `flushFailedRetried` phase from
  `retryPowerOff` (`power_off_cubit.dart:80-84, 119-126`); `_FlushFailedBody`
  (`power_off_dialog.dart:93-146`) shows a third button in that phase that runs
  goodbye and `_powerOff` without a flush. Two l10n strings (en, es).
- Hear click default. `_firstRunAutoStart` (`audio_bootstrap.dart:677`, entered
  when `loadAudioConfig()` is null, :231-233) writes `tempo.click_mode = 2`
  through the verified writer; the owner's absent-key default becomes Off,
  replacing `saved ?? 2` (`tempo_settings.dart:179`) and `?? recFirst`
  (`audio_bootstrap.dart:68`). Existing installs stay Off and no key is written.
- Unity top for volume mappings. New gain endpoints default to `fromDomain(1.0)`
  instead of `1` (`midi_controls_page.dart:959`, `ExpressionMapping` toe default);
  existing mappings are an open decision (section 6).
Estimate: +130 / -30.

```success-criteria
GOAL: The three owner decisions are implemented as stated, with existing-install cases proven.
SUCCESS CRITERIA:
- With the confirm dialog open, an expression sweep and a MIDI parameter write land while Record, overdub and perf-arm are refused. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/ test/appliance/power_off/
- After the initial flush and one Retry fail, the dialog offers Power off anyway, which fires the power-off closure without a successful flush; it is absent before the first Retry. | verify: /Users/Tomas/development/flutter/bin/flutter test test/appliance/power_off/
- Fresh setup stores click mode 2; an install with a saved audio config and no click key reports Off and the store still has no key. | verify: /Users/Tomas/development/flutter/bin/flutter test test/app/audio_bootstrap_test.dart test/looper/application/
- A new MIDI or expression volume mapping at full travel reads 0 dB (literal oracle: gain 1.0). | verify: /Users/Tomas/development/flutter/bin/flutter test test/control/
NON-GOALS:
- Other defaults; a Mixer surface for monitor gain.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
```

## 4. Test migration

Part 1 has done this for Click volume and Hear click (see Part 1 as built);
the rest of this section describes Parts 2 and 3.

The seven transaction suites (`test/looper/application/*_transaction_test.dart`,
3,276 lines) and the owner suites (`tempo_settings_test.dart` 743,
`playback_settings_test.dart` 335, `record_settings_test.dart` 346) drive the
concrete owner over `LooperRepository(engine: FakeAudioEngine)` and an in-memory
`SettingsRepository` (`click_volume_transaction_test.dart:62-68`). They become one
parameterized `settings_owner_test.dart` (contract cases run per family) plus a
short file per family for conversion, validation and family-only rules. Cases
that pin a defect flip: the bootstrap assertion that a bad click key stops audio
(`test/app/audio_bootstrap_test.dart`, #1099 cites :216), "raw data survives
retry" in `record_start_transaction_test.dart` (#1100-1), and any case asserting
`stopEngine` on timeout. The six repository receipt suites
(`packages/looper_repository/test/*_receipt_test.dart`, about 1,040 lines) and
`settings_receipt_lifetime_test.dart` collapse into one parameterized
`settings_receipt_test.dart` keeping the family settle-predicate cases. The seven
dispatch suites (`test/control/*_dispatch_test.dart`, about 3,500 lines) are the
regression net and change only in construction; the native-backed cases
(`count_in_dispatch_test.dart:626-667`) stay. The seven `test/helpers/
fake_*_control.dart` become one fake port.

Independent oracles: engine stop count on the fake, not a repository flag;
reconnect proven by feeding a device-present enumeration and observing
`startEngine` on the fake; store contents read from the `KeyValueStore` fake,
never through `SettingsRepository`; power-off proven by the injected `powerOff`
closure firing.

## 5. Findings ledger

Fixed by the shared owner (Parts 1-2): #1094-1/2/3, #1095-1/2 and its
stop-on-refusal nit, #1096-1/2/6/7, #1097-1/2/3/5/6/7/8, #1098-1/2/3/4/5,
#1099-1/3/4/5 and the `_modeRevision` nit, #1100-1/3/4/5/7 and the `_startReady`
nit, the #1094 Mixer-timeout debt. Part 2 outside the owner: #1096-3, #1100-6
(decode), the `LooperBloc` remainder of #1095-3/#1096-5/#1097-9/#1098-7. Part 3:
#1093-1, #1093-5, #1094-7, #1095-4, #1096-4, #1097-9, #1098-6, #1099-6, the readout
chain of #1093-3. Part 4: #1093-2, #1094-4, #1094-5, #1099-2.

Already resolved at the head: Cubit-to-Cubit edges (#1111); current-state flush
for timing, Hear click, Count-in and Click volume
(`record_timing_settings.dart:390-420`, `tempo_settings.dart:330-353, 714-737,
849-875`).

Deferred: #1093-3 (Mixer `_readValue` copy, `mix_value_scale` constants) and
#1093-4 (`durableSnapshot` runs `_syncControllerTopology`,
`mix_settings_coordinator.dart:259-261, 429`) are Mixer-internal; one follow-up
issue. #1093-6 (MonitorVolume offered with no surface,
`control_value_resolver.dart:139`) is a product call. #1097-4 (a session's loop
mode is no longer persisted; mode refusals read as Record length) is shipped
behavior needing owner acknowledgement in the Part 2 PR body. #1100 native nits
are C changes outside this plan. #1098's `ControlCleanupPending` debt is correct
once Multi entry can no longer strand a release.

## 6. Open product decisions

1. Existing volume mappings carry a literal top of 1.0
   (`midi_controls_page.dart:959`), which the fader law maps to +6 dB. "Unity for
   existing mappings" needs a stored-data migration (AGENTS.md forbids) or a
   decode rule that a literal 1.0 top means unity, which makes +6 dB unreachable
   for authors who meant it. Part 4 ships the new-mapping default only.
2. Resolved 2026-10-05: an uncertain receipt keeps the requested durable value
   in storage and Retry re-requests it (section 2.1; Part 1 as built).
3. "Power off anyway" copy: the unsaved setting lives in the engine only and is
   lost on restart; the owner's words are needed.
4. Building the owner registry in `run_segno.dart` before `App` (section 2.3)
   removes the double startup replay but moves construction out of `AppRuntime`.

## 7. Risks

Riskiest step: Part 2 deletes about 1,100 lines of repository receipt code
across six families and rewrites bootstrap, `prepareShutdown` and Session
exclusion in one PR, touching startup order, Save/Load and power-off at once.
Mitigation: Part 1 proves the core on two families first; dispatch suites stay
untouched as the net; split Part 2 into 2a (repository receipts) and 2b
(bootstrap, shutdown, toasts, Bloc) if the diff passes about 3,000 lines. Second
risk: PR #1156 and Part 2 both rewrite `fade_settings.dart`; fix the order
before either merges.
