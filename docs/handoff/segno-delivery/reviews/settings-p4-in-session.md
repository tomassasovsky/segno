# Review: PR #1191, settings owner Part 4 (claude/settings-owner-1159-p4 @ 6005fc7ff)

Model: Claude Opus (subagent), in-session
Base: claude/settings-owner-1159-p3 @ 5479f42bf
Scope: `git diff origin/claude/settings-owner-1159-p3...origin/claude/settings-owner-1159-p4` (30 files, +560/-50), the PR body, the plan's "Part 4 as built" section, decisions 42-46 and open decisions 1 and 3.

## Runs (scratch worktree, SEGNO_ENGINE_LIB exported)

- `dart analyze --fatal-infos lib test packages`: no issues.
- `bloc lint lib test packages`: 0 issues, 828 files analyzed.
- `flutter test test/appliance test/app test/control test/looper test/session`: +2338 ~6, all passed.
- `packages/looper_repository flutter test`: +799, all passed.

### Mutations (each reverted after its run)

| Mutation | Result |
|---|---|
| M1: `powerOffAnyway` ignores `retryFailed` | killed |
| M2: anyway still flushes | killed (2 tests) |
| M3: anyway skips the take gate | killed |
| M4: dialog offers anyway before a Retry | killed |
| M5: owner flush ignores `_unreadable` | **survives** |
| M6: owner flush ignores `_owedRollback` | killed (10 tests) |
| M7: `deferred` ignores owed | killed (11 tests) |
| M8: Mixer flush reverted to the old form | killed |
| M9: expression path back on `takeLocked` | killed |
| M10: MIDI parameter path back on `takeLocked` | killed (2 tests) |
| M11: External queue back on `takeLocked` | killed |
| M12: retire-all on looper state back on `takeLocked` | **survives** |
| M13: seed ignores the audio config | killed |
| M14: seed ignores the key | killed (10 tests) |
| M15: `decodeEndpoint` returns its input unchanged | killed (2 tests) |
| M16: `mappingTop` is full travel | killed (12 tests) |
| M17: MIDI load does not decode | killed |
| M18: Retry throws when `owners.recover()` fails | **survives** |
| M19: Retry throws when `mix.recover()` fails | killed |
| M20: Lane volume dropped from `mappingTop` | **survives** |

## Verified correct (traced)

- **Power-off gating, decision 42.**
  - `inputLocked` is closing or a Session transition, and `takeLocked` is that plus `power.state.isUiUp`, so `inputLocked` is a strict subset.
  - Four sites moved to `inputLocked`: expression samples, the queued External write, MIDI parameter writes, and the retire-all on looper state.
  - Everything that can start a take still reads `takeLocked`: `recPlay`, `trackPressed` in record mode, `_onPress`, `_pressBinding`, `_fireCustomAction`, `_armGesture`, `_togglePerformanceRecordAccepted`, External switch contacts (control_cubit.dart:442), MIDI action rows (control_midi.dart:585), foot fade and foot mixer, `LooperBloc` and `PerformanceRecorderCubit`.
  - The queued External write cannot start a take. Actions are accepted at entry under `takeLocked`, and the queue applies only FX activations and parameters.
  - Count-in, a quantized arm (`track.pending`), capture and perf-arm states all make `powerOffGate` refuse at press time. Every commit (`saveAndPowerOff`, `powerOffWithoutSaving`, `retryPowerOff`, `powerOffAnyway`) re-reads a fresh snapshot through `_prepareCommit`, so a take that started behind the confirm dialog is refused.
- **No continuous write after the flush or the goodbye.**
  - `flushMidiConfiguration(retireControls: true)` sets `_haltInputSuspended` before anything else.
  - External raw input (control_cubit.dart:402) and MIDI input (control_midi.dart:461) are gated by `_controlInputSuspended` at entry.
  - The flush then awaits `_midiWrites` and `_externalTail`, followed by the FX, Mixer and owner flushes in `prepareShutdown`, so work queued before the suspension drains first.
  - The suspension clears only when `takeLocked` is false. It therefore holds through `flushFailed` and goodbye, which covers the Power off anyway path. That path is reachable only after two flushes that both set the suspension.
- **Power off anyway, decision 43.**
  - `retryFailed` is set only by `_halt(retry: true)`. Every `_set` resets it, as do Keep playing, a fresh press, and the flushing phase.
  - `powerOffAnyway` requires `flushFailed` and `retryFailed`, and it re-runs the take gate.
  - The dialog passes `onPowerOffAnyway` only when `retryFailed` is set.
  - `_halt(flush: false)` skips only `_flush`. Goodbye, the mark hold and `_powerOff` still run.
  - M1-M4 are all killed.
- **Flush rule, decision 44.**
  - `SettingsOwner.flush` now fails on `!_initialized`, `_unreadable` or `_owedRollback`. An owed receipt reports `applied` with `deferred: true`.
  - The owed case is safe. `_write` keeps the written checkpoint only when `_family.durable == durable` ("storage already holds the value Retry re-requests"), and `SettingsReceipt.restart` returns `_owed`, so the next start replays what storage holds.
  - `MixSettingsCoordinator.flush` awaits the drain and returns `_recovery ?? _applied`. In that coordinator, `_recovery` is set only by a failed `_rollback` or a failed `recover` restore.
  - The owed Mixer case keeps storage at the candidate (mix_settings_coordinator.dart, `!settled.isOk && mixRecoveryRequired`).
  - A `storageFailed` edit leaves storage and the engine both on the old value. Letting it through matches the rule, because the edit was refused and reported, so nothing is owed.
  - In `prepareShutdown`, Retry ignores the results of `mix.recover()` and `owners.recover()` and lets the flushes decide. A failed rollback still blocks: `mix.flush` returns `_recovery`, and owner flush checks `_owedRollback`, which M6 kills.
- **Hear click, decision 45.**
  - `_seedFreshInstallHearClick` runs first inside `runExclusive`, before the families stage. `run_segno.dart:185` awaits it before `App`, so the owner's `load()` reads the seeded key.
  - It writes through `restoreClickModeCheckpoint`, the verified scalar writer. On any error it logs and writes nothing.
  - An existing install always has a saved audio config. `_firstRunAutoStart` saves one after any successful open, and the Audio setup cubit saves one on an interactive start.
  - The install that lacks one has never opened audio and so has never played a click. Seeding Off there changes nothing the user has heard.
  - A config that cannot be read throws and is not seeded, and an invalid key throws and is not seeded. Both keep the old behaviour, which is fail-safe.
  - `loadAudioConfig` keys have not been renamed since 87af47602.
- **Decision 46 scope.**
  - `mappingTop` and `decodeEndpoint` are the identity for every target except `TrackVolumeTarget` and `LaneVolumeTarget`. Monitor volume, Master gain and FX params keep a literal 1.0, which the new test pins for Monitor volume.
  - External switch parameters (`active` and `inactive`) are not decoded.
  - MIDI decodes once, at `_loadMidiConfiguration`. Expression decodes in `ExpressionMapping.fromJson`, including an absent toe, which used to default to 1.
  - A re-saved mapping persists the decoded unity value, as decision 46 states. This is downgrade-safe: an older build reads the stored unity travel (0.9088) through the same law, so it also plays unity.
- **Tests.**
  - The flipped assertions match the decisions and keep their scenarios: the Hear click matrix, click_dispatch "blocks only takes", the Record length and timing owed flushes (which still assert `ready == false` and recovery still required), and the three 0.0 dB readouts.
  - The perf-arm lock fix (`await pumpEventQueue()`) is real. Before it, the test read `armedDirectory` before the queued arm could run.
- **Layering.** `AppRuntime` composes the predicates, and `PowerOffCubit` still calls no other cubit. No cubit method returns a value (bloc lint is clean).

## Findings

### 1. Medium: a +6 dB top authored on a level fader works until restart, then silently becomes unity (rule 3)

Decision 46 and open decision 1 accept that "+6 dB [becomes] unreachable for authors who meant it." The build does not make it unreachable; it makes it non-durable.

- The MIDI range slider and the expression toe slider both reach exactly 1.0 on Track and Lane volume. The readout shows "+6.0 dB".
- The MIDI high endpoint's double-tap reset still writes 1 (midi_control_cards.dart:426). Since this PR, that is +6 dB rather than the default top.
- Repointing keeps endpoints. Moving a full-travel mapping from any other target onto a level fader carries 1.0 along (`MidiMappingDraft.repointing`; external_pedal_page.dart:616-620).
- In session the mapping drives +6 dB, because `setPedalSetup` and the MIDI save keep the object as authored. Decoding happens only on load.
- After a restart, the same stored 1.0 decodes as unity.

Probe, a throwaway test that was deleted afterwards:

```
ExpressionMapping(target: TrackVolumeTarget(0), toe: 1) -> toJson -> fromJson
authored toe=1.0 domain=2.0; reloaded toe=0.9088 domain=1.0
```

The performer hears +6 dB, saves, powers off, and gets 0 dB with no notice.

Fix, in either of two ways:
- (a) Apply `decodeEndpoint` when the draft or setup is built as well as on load, so the slider snaps to unity at full travel and the double-tap reset uses `mappingTop`. This makes +6 dB unreachable, as the decision says.
- (b) Keep +6 dB reachable by marking mappings this build writes (an extra field older builds ignore) and decode a literal 1.0 only on unmarked mappings.

Option (a) is the smaller change and matches the decision text. Either way, the double-tap reset should use `mappingTop`.

### 2. Low-Medium: after a failed rollback, the "Power off anyway" copy states the wrong outcome

With decision 44, an owed value no longer fails the flush. What still fails it:
- unreadable storage;
- MIDI or External cleanup that is still pending;
- an FX save failure;
- Session boot recovery;
- a failed rollback, for an owner or the Mixer. This is now the main path to the dialog.

In the failed-rollback case, storage holds the refused value, or is indeterminate if the first write threw. The engine holds the previous accepted value, or is stopped for the Mixer.

"Power off anyway" then boots with the value the user was told was not applied. The copy, "the last unsaved change is lost", promises the opposite.

For unreadable storage, nothing is lost: the family comes up unavailable again and Retry repairs it to its default.

Open decision 3 assumed that "the unsaved setting lives in the engine only". That is no longer the case for most of the paths that reach this button.

Fix: copy that does not promise which value survives, for example "the last setting change may not be kept as shown". Alternatively, leave an "unclean power-off" marker that the next start reports, which is rule 5.

This is an owner call on wording, but the current sentence is inaccurate for the main path to the button.

### 3. Low: the encoder (master output gain) is still take-locked while the power dialog is up

`encoderTurned` (control_cubit.dart:2213) returns on `_takeLocked()`. Decision 42 locks takes, footswitches, MIDI actions and External switch contacts, and leaves continuous values running. The encoder is a continuous value: master gain, or the foot mixer gain step. It cannot start a take, yet it freezes behind the dialog, unlike a MIDI CC or expression on the same Master gain target. The new external_dispatch test shows a MIDI CC moving master gain behind the dialog.

The current behaviour is fail-safe, but it contradicts the decision as written.

If it moves, the gate must be `_inputLocked() || _controlInputSuspended`, not `_inputLocked()` alone. The encoder has no entry-level suspension check, and its `_onOrdinaryFxWrite` would otherwise land after `fxPersistence.flush()`.

Either move it, or name the encoder in decision 42 as deliberately locked.

### 4. Low: the decision-critical branches have no tests (surviving mutations)

- **M5.** Dropping `_unreadable != null` from `SettingsOwner.flush` passes the full looper/application and app/application suites. Unreadable storage blocking power-off is a stated requirement of decision 44 and of this review's brief, and it is the case Retry exists to repair. Add an owner-matrix check: load with an unreadable key, then `flush()` returns `recoveryRequired`.
- **M20.** Dropping `LaneVolumeTarget` from `mappingTop` passes everything. Decision 46 names Lane volume explicitly. Add one Lane volume decode assertion beside the Track volume one.
- **M18.** No test covers an owner whose Retry cannot land an owed value while power-off still goes ahead. The Mixer twin exists ("a Retry that cannot land an owed vector still lets power-off go ahead"). Add the owner version, so the removed `throw StateError('... still needs recovery')` cannot come back unnoticed.
- **M12.** Restoring `takeLocked` on the looper-state retire-all passes. With the dialog up, any looper state event would retire held External values. Pin this in the "power-off dialog open" check: hold an External value, emit a looper state, and confirm the hold survives.

## Notes

- The PR's claim that "17 tests fail with their fix reverted" is consistent with the killed mutations above. I did not reproduce the exact count.
- During the Saving phase of "Save & power off", continuous writes now run alongside the Session capture. Before this PR they were take-locked. This is the same exposure as an ordinary Save while a pedal sweeps, so I did not treat it as a finding.
- A torn first-run `saveAudioConfig` would make `loadAudioConfig` return null on the next boot, because sample rate is written before buffer frames. The seed would then treat the device as fresh. This only happens on a device that has just opened audio for the first time, so the risk is negligible.
- The scratch worktree was removed. Nothing was committed, pushed or posted.

Verdict: request changes. Finding 1 is a silent change across restart (rule 3) in decision 46's own territory. Finding 2's copy is inaccurate for the main path to the button. Findings 3 and 4 are small.

## Delta review (b8e8b33e4)

Scope: `git diff 6005fc7ff..origin/claude/settings-owner-1159-p4`, one commit, 17 files (+229/-32), including decisions 47-49 in the plan.

### Runs (scratch worktree, SEGNO_ENGINE_LIB exported)

- `dart analyze --fatal-infos lib test packages`: no issues.
- `bloc lint lib test packages`: 0 issues, 828 files.
- `flutter test test/appliance test/app test/control`: +1323 ~6, all passed.
- `packages/looper_repository flutter test`: +799, all passed.

### Mutations (each reverted after its run)

| Mutation | Result |
|---|---|
| D1: MIDI draft factory does not settle endpoints | killed |
| D2: `_saveMidiConfiguration` does not decode | killed (3 tests) |
| D3: `ExpressionMapping` constructor does not decode heel | killed |
| D4: double-tap reset writes 1 | survives; equivalent (see below) |
| D5: encoder without `_controlInputSuspended` | killed |
| D6: encoder back on `_takeLocked` | killed |
| M12 (was surviving) | now killed |
| M18 (was surviving) | now killed |
| M20 (was surviving) | now killed (3 tests) |
| M5: owner flush without the `_unreadable` check | survives; equivalent (see below) |
| M5b: owner flush without `!_initialized` | survives |

D4 is equivalent for level faders. `onRange` reaches `withRange`, then `_copy`, then the factory, which applies `_settled`, so a reset to 1 becomes unity anyway. On every other target `mappingTop` is 1.

### Earlier findings

1. **Fixed.** A literal 1.0 is now unity wherever a mapping is built:
   - the MIDI draft factory, which every `_copy` goes through (`withRange`, `repointing`, `withControl`);
   - the MIDI save, which plays, shows and stores the decoded set;
   - the `ExpressionMapping` constructor, which covers `copyWith`, the repoint at external_pedal_page.dart:616, and `fromJson`.

   The decode is idempotent: the unity travel value 0.9088 is not 1, so decoding it again does nothing. The decode is the identity on every other target. Probe: Master gain toe 1.0 stays 1.0.

   A probe confirmed that authored, played and reloaded values now agree. MIDI slider at 1.0 gives 0.9088 = 0.00 dB, and an expression toe of 1.0 gives the same.

2. **Fixed** (decision 47). The copy is "Segno could not confirm your last change was saved. Retry again, or power off anyway." It no longer says which value survives.

3. **Fixed** (decision 49). The encoder gate is now `_inputRetired || _inputLocked() || _controlInputSuspended`.
   - The test turns the encoder behind the dialog and then checks it is frozen after `flushMidiConfiguration(retireControls: true)`. D5 and D6 kill it.
   - The encoder stays frozen through goodbye. The suspension clears only when `takeLocked` is false, and goodbye keeps the power UI up.
   - It also stays frozen on the Power off anyway path. Every first flush begins with `flushMidiConfiguration(retireControls: true)`, so the suspension is already set before Retry and anyway.

4. **Fixed.** M12, M18 and M20 are now killed.

### M5: is the builder's equivalence claim right?

Yes. I traced every assignment of the two flags in settings_owner.dart.

- `_unreadable` is set only in `_restore`, when the startup read fails and the Session revision is unchanged. That path returns before `_initialized = true`.
- Each place that sets `_initialized = true` either clears `_unreadable` or cannot run while it is set:
  - `installSession` (lines 382-384) clears `_unreadable`.
  - The `_restore` success path (line 688) runs only after a successful read. The only re-run comes from `recover()`, after `_repairStorage` has cleared `_unreadable`.
  - The `_sync` path (line 720) needs a Session recall during the read, and in that case `_restore` never sets `_unreadable`.
- So `_unreadable != null` implies `!_initialized`. M5 is equivalent, and the two new flush assertions in settings_owner_test pin the unreadable cases end to end.

M5b survives as well: dropping `!_initialized` passes, because in the tested unreadable cases both flags are set. That leads to N1.

### Decision 48 and the owner's "log law, top = unity"

Consistent.
- The law itself is unchanged, and the default top of a new mapping is unity.
- For existing installs, only a stored literal 1.0 on Track or Lane volume changes meaning (decision 46). Any other stored value, including anything in (0.9088, 1), plays as before.
- External switch `active` and `inactive` values are not decoded. external_dispatch pins this with "an External switch value keeps its authored +6 dB".
- The automatic saves (a latching-switch `_enqueuePedalSetup`, MIDI enable or disable) can persist mappings the user never edited, but only as their already-decoded in-memory form. That is the rewrite decision 46 accepted, and it means the same thing in this build and in an older one.
- Opening the editor (`MidiMappingDraft.of`) changes nothing, because loaded mappings are already decoded.

### New findings

- **N1 (Low, not from this delta; for awareness).** `!_initialized` blocks power-off in one case where storage does hold the replay value.
  - The case: the startup restore receipt was uncertain, so the family owes the stored value and `_restore` returns before setting `_initialized` (settings_owner.dart:665-667).
  - Decision 44's rationale ("an owed value never blocks") would let this through. The plan's list ("not initialized, unreadable, or a failed rollback") blocks it.
  - The effect is fail-safe: Retry re-requests the value, and Power off anyway follows if it still fails. Only a boot whose own replay went unanswered can reach it.
  - Either note it in decision 44 or narrow the condition. M5b shows no test pins `!_initialized` on its own.
- **N2 (Low, UX, owner call already recorded in decision 48).** On a level fader the top endpoint jumps down at full travel.
  - Probe: MIDI slider 0.98 is +4.70 dB, 0.99 is +5.36 dB, 0.999 is +5.95 dB, and 1.0 is 0.00 dB. The expression toe behaves the same.
  - Dragging to the end, or pressing the keyboard step from 0.99, sends the readout from about +5.9 dB to 0.0 dB.
  - It is consistent and durable now, so this is not a defect. If it reads oddly on the device, cap the slider just under 1.0 on level faders.
- **N3 (nit, Spanish).** "Segno no pudo confirmar que tu último cambio se guardó."
  - After a negated "confirmar que", where the outcome is uncertain, standard usage takes the subjunctive: "…que tu último cambio se haya guardado."
  - The rest is correct and matches the file's tú register ("Reintenta", "Vuelve a intentarlo").
  - The English is fine.

The scratch worktree was removed. Nothing was committed, pushed or posted.

Delta verdict: approve. All four findings are fixed, and the claimed tests fail with their fixes reverted. M5 is genuinely equivalent. N1 and N2 are low and owner-facing; N3 is a one-word copy nit.

---

<!-- The sections above review PR #1191 (settings-owner #1159 Part 4), an
earlier PR that used this directory. The review below is a separate review
of PR #1232 (#1199 Part 4). -->

Model: Claude Opus (subagent), in-session

# Review of PR #1232: feat(appliance)!: retire Bluetooth from the app and the image (#1199 Part 4)

## Scope

- Branch `claude/settings-1199-p4` at `13838933b`: `95216f7bd` (the part), a
  merge of Part 1 at `9dcddac52`, and `13838933b` (the distro-feature fix).
  Reviewed as `9dcddac52..13838933b` (72 files, +305 / -4026).
- App: deletes `lib/bluetooth/`, `packages/bluetooth_client`,
  `packages/bluetooth_repository`, their wiring, the tray's Bluetooth tab and
  `NetworkTab`. Adds `ConsoleFactsClient.retiredBluetoothPairings()`,
  `SettingsRepository.load/saveBluetoothRetiredNoticeShown` and the one-time
  plural toast.
- Image: removes `bluez5` from the kiosk image and `segno-bundle` RDEPENDS,
  deletes `segno-bt-ctl`, `segno-bt-persist` and its unit and their two test
  scripts and CI steps, adds `DISTRO_FEATURES:remove = "bluetooth"` in
  `kas-segno-common.yml` and `PACKAGE_EXCLUDE += "bluez5"` as the guard.
  `/data/bluetooth` is left alone.
- Against plan Part 4 and D11, AGENTS.md and the owner rules.

## Runs

- Full app suite with `SEGNO_ENGINE_LIB`, first run: one failure,
  `test/control/foot_mixer_dispatch_test.dart: Custom saved hold enters Mixer
  and consumes its old release` (expected `mixer`, got `custom`). The file
  passed 3 of 3 times on its own, and a second full run was green:
  `+3463 ~56: All tests passed!`. This branch does not touch control code, so
  this is a timing flake under full-suite load (see Notes).
- `packages/console_facts_client`: `+23`; `packages/settings_repository`:
  `+202`; `test/app/view/app_test.dart`: `+119 ~6`. All passed.
- `dart analyze --fatal-infos lib test`: no issues. `bloc lint lib test
  packages` from a scratchpad worktree: 0 issues, 874 files.
- Every remaining appliance shell suite passed with a per-run `TMPDIR`
  (11 under `segno-bundle/test`, 3 under `images/test`). Every
  `bash <script>.sh` step in `.github/workflows/*.yaml` points at a file that
  exists.
- Upstream dependency sweep at the commits `kas-segno-common.yml` pins:
  - poky `packagegroup-base.bb`
  - meta-raspberrypi (cloned at `0f68e875`)
  - meta-openembedded `networkmanager_1.50.0.bb`
- Mutations (each reverted):
  - Killed:
    - acknowledgement never saved;
    - toast shown at count 0;
    - stored acknowledgement ignored;
    - device records counted without an `info` file;
    - adapter directory name not checked.
  - Survived: the toast text called with a hard-coded count of 1 (L1).

## Verified correct (traced)

### Image: nothing else pulls BlueZ back

- `bluetooth` leaves COMBINED_FEATURES, so `packagegroup-base` no longer
  depends on `packagegroup-base-bluetooth`, the only hard path to `bluez5`
  found (poky `packagegroup-base.bb:28`, `:61`, `:188-191`).
- NetworkManager's `bluez5` PACKAGECONFIG is enabled only by the distro
  feature (`networkmanager_1.50.0.bb:88`), and `networkmanager-bluetooth`
  depends on `bluez5` only under that PACKAGECONFIG (`:165`, `:292`). It
  rebuilds without Bluetooth DUN, which nothing in Segno uses.
- `pi-bluetooth` is pulled only by meta-raspberrypi's `bluez5_%.bbappend`
  (`RDEPENDS:${PN}:append:rpi = " pi-bluetooth"`), so it leaves with BlueZ.
- The `bluez-firmware-rpidistro-*` packages stay as
  `MACHINE_EXTRA_RRECOMMENDS` (`raspberrypi5.conf:9-13`,
  `raspberrypi4-64.conf:8-12`). They are firmware blobs that depend only on
  their licence package, not on `bluez5`, so they neither trip
  `PACKAGE_EXCLUDE` nor need the feature.
- No recipe in `meta-segno` mentions bluez or bluetooth any more except the
  explanatory comments. `kas-segno-rpi4.yml` and `kas-segno-rpi5.yml` do not
  re-add the feature. No image package found uses
  `REQUIRED_DISTRO_FEATURES = "bluetooth"`.
- `segno-bundle.bb`: the bt files are gone from `SRC_URI`, `RDEPENDS`,
  `SYSTEMD_SERVICE`, `FILES` and `do_install` consistently. No remaining unit
  orders itself against `bluetooth.service`.

### App: the notice cannot fire wrongly in any case I could construct

- **Counting:** `LocalConsoleFactsClient.retiredBluetoothPairings` counts only
  `<ADAPTER-MAC>/<DEVICE-MAC>/info` (uppercase, as BlueZ names them) and
  ignores `cache/`, `settings` and info-less directories. A missing or
  unreadable tree counts 0 (`FileSystemException` caught).
- **Non-appliance builds:** the unsupported and fake clients answer 0. The
  macOS dev host uses the local client but has no `/data/bluetooth`.
- **Once per install:** the acknowledgement is saved only after a toast is
  shown, and only when the count is above 0. An install with no pairings
  re-checks each start (cheap) and is never told.
- **After a fallback and a second update:** the acknowledgement lives in
  settings on `/data`, so the user is not told twice.
- **Data on disk:** the app runs as root (`segno.service` has no `User=`), so
  it can read the 700 directory. `/data/bluetooth` is not touched by anything
  in the new image.
- **Toast copy:** the toast is an ICU plural in both ARBs ("The device ..." /
  "The {count} devices ...").

### Leftover references

- Nothing in `lib`, `test`, `packages`, `apps`, `integration_test`,
  `pubspec.yaml` or `.github` references the deleted packages, cubits, pages
  or helpers.
- `bluez` and `bluetoothctl` stay in `.github/cspell.json` on purpose, for
  older documents.

## Findings

### Low

**L1. The toast's count is untested.** Replacing
`_l10n.bluetoothRetiredNotice(count)` with `bluetoothRetiredNotice(1)`
(`lib/app/view/app.dart`, in `_noticeRetiredBluetooth`, `:795`) passes every
test. The plan's criterion asks that the toast text contains "2" for two
pairings. Fix: assert the rendered text (or `find.textContaining('2')`) in
the "told once" app test.

**L2. A settings-store failure in the notice becomes an unhandled async
error.** `_noticeRetiredBluetooth` is started with `unawaited` from a
post-frame callback (`app.dart:787`). If `loadBluetoothRetiredNoticeShown` or
`saveBluetoothRetiredNoticeShown` throws, the error goes to
`PlatformDispatcher.onError` (`lib/bootstrap.dart:56`) as an uncaught error
rather than being handled where it happens. It only logs, but wrap the body
in a try/catch and treat a failed read as "do not show".

**L3. Bluetooth-era strings and descriptions remain.**
- Already unread before this part, and not removed here: `bluetoothIntro`,
  `bluetoothAliasLabel`, `bluetoothPoweredLabel`, `bluetoothScanSubtitle`.
- Stale descriptions still mention Bluetooth, for example the Back control
  on the "in-tray WiFi/Bluetooth expand panel" (`app_en.arb:1802`) and the
  Network rail entry described as "WiFi and Bluetooth as two tabs".
- Harmless; a follow-up sweep, or Part 5, which deletes the Network face,
  can take them.

## Notes

- Merge with Part 3: conflicts are additive or delete-both (see the P3
  review). The resolver must take this part's side for the Bluetooth strings
  Part 3 still carries.
- The `foot_mixer_dispatch_test` flake appeared once in one full run here,
  and not in the P2 (`+3508`) or P3 (`+3405`) full runs. It looks like a
  hold-timing test sensitive to load; worth tracking separately if it recurs.
- Not verifiable here: the Yocto build itself (sstate rebuild, manifest
  check) and the hardware criteria (`pidof bluetoothd` empty, phone scan,
  RAUC fallback reconnects). They stay on the plan's runner and device list.

Verdict: Approve.
