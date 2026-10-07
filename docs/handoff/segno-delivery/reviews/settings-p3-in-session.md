Model: Claude Opus (subagent), in-session

# Review of PR #1231: refactor(settings): retire the old Settings page and the boot-default mode (#1199 Part 3)

## Scope

- Branch `claude/settings-1199-p3` at `a586a895c`: `13b483025` (the part) plus
  a merge of Part 2 at `ccb828632`. Reviewed as the diff `ccb828632..a586a895c`
  (46 files, +125 / -9607).
- Deletes the old `SettingsPage` and its sections, the already-dead Wi-Fi and
  Bluetooth pages, `host_page_chrome.dart`, `SignalKnob`, `setup_surface.dart`,
  the pedal assignment page and plate, `audio_device_picker.dart`, the
  boot-default mode (`setDefaultMode`, `defaultMode`, `bootDefaults`,
  `fromToken`, `bootDefaultFromToken`, `load/saveDefaultInteractionMode`), and
  107 strings. Adds the one-time Mute notice (D4, owner decision).
- Against plan Part 3, AGENTS.md and the owner rules (especially 3, no silent
  behaviour change).

## Runs

- Full app suite with `SEGNO_ENGINE_LIB` from a scratchpad worktree:
  `+3405 ~56: All tests passed!` (`app_exit=0`).
- `packages/settings_repository`: `+201: All tests passed!`.
- `dart analyze --fatal-infos lib test`: no issues. `bloc lint lib test
  packages` from the scratchpad worktree: 0 issues, 872 files.
- Removed-string sweep (script): computed the 107 keys removed from
  `app_en.arb` against `ccb828632`, then searched every `.dart` file in `lib`
  (outside `l10n`), `test`, `packages`, `integration_test`, `test_driver` and
  `apps` for an `l10n.` / `strings.` / `AppLocalizations.of(...)` read of any
  of them: 0 hits. Both ARB files are consistent: no `app_es` key missing from
  `app_en`, no orphan `@` metadata, every new key has metadata.
- Deleted-symbol sweep outside what the analyzer covers: `integration_test/`,
  `test_driver/`, `apps/`, `macos/`, `linux/`, `docs/PROGRESS.md`,
  `AGENTS.md`, `README.md`: no reference to `SettingsPage`, `SettingsSection`,
  `settings_close_button`, `audioSettings_*` keys, `setDefaultMode`,
  `PedalAssignmentPage`, `WifiPage`, `BluetoothPage`, `setup_surface` or
  `pedal_plate`.
- Mutations (each reverted), all killed: notice for any stored token (not just
  `mute`); boot into the retired mode again; key not removed after the read;
  the app listener does nothing.
- `git merge-tree` with Part 4 (`13838933b`): conflicts in `app_toasts.dart`,
  the two ARB files and `app_test.dart` (both sides append), and
  modify/delete on `host_page_chrome.dart` and `lib/bluetooth/bluetooth.dart`
  (both parts delete). All additive or delete-both, as the build record says.

## Verified correct (traced)

- The notice is honest about who changed: on the base, a stored token went
  through `bootDefaultFromToken`, which coerced everything except `record` and
  `mute` (including the legacy `play`, for which no shim exists anywhere in
  `lib` or `packages`) to Record. So only `mute` installs boot differently
  now, and only they are told.
- `SettingsRepository.takeRetiredDefaultInteractionMode` reads and removes the
  key; the second start sees `null` (package test and app test).
- `ControlCubit._restore` always ends in `setMode(InteractionMode.record)`.
  `ControlState.retiredBootMode` is set once and never cleared; the app's
  `BlocListener` fires on the null-to-value transition only, so the toast
  cannot repeat within a run. The app test proves the listener is subscribed
  before the restore emits (`AppRuntime.start` runs the loads together).
- Nothing deleted is reachable: the analyzer is clean over `lib` and `test`,
  and the non-Dart sweep above is clean. The Settings home (Part 2) is the
  only entry for every former entry point.
- The token-adoption allowlist loses exactly the entries for deleted files.

## Findings

### Low

**L1. The key is removed before the notice is guaranteed.**
`control_cubit.dart:1186` takes (reads and deletes) the stored mode, but the
state that carries `retiredBootMode` is emitted only after the pedal setup
load and the `_inputRetired || _closing || isClosed` check (`:1191-1202`). If
the app is shutting down during that window, or `loadPedalSetup` throws
anything other than `FormatException`, the key is gone and the notice never
shows, which is the silent change rule 3 forbids. Narrow window. Fix: read
first and remove only after the emit (or after the toast), for example
`loadRetiredDefaultInteractionMode` plus `clearRetiredDefaultInteractionMode`
called from the listener.

**L2. Merging with Part 4 must drop the Bluetooth strings this part keeps.**
This part leaves `bluetoothDiscoverable*`, `bluetoothAdvertise*`,
`bluetoothScan*` and `bluetoothEmptyDevices` in both ARB files, because the
tray's Bluetooth body still reads them here; Part 4 deletes them. In the
P3 x P4 merge the conflict hunks hold them on this side, so the resolver has
to take Part 4's side or they become dead strings.

## Notes

- Some strings were already unread before this part and survive it (for
  example `bluetoothIntro`, `bluetoothAliasLabel`, `bluetoothPoweredLabel`,
  `bluetoothScanSubtitle`). Not this part's job, but a later sweep could
  catch them.
- D5 (desktop record-offset field) and D13 (desktop separate devices) are
  realised here by deletion, as the plan records.
- The full suite took 2:09; nothing flaky was seen on this branch.

Verdict: Approve (L1 and L2 are small; L2 is a merge instruction).
