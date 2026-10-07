Model: Claude Opus (subagent), in-session

# Review of PR #1218: feat(settings): open Device, Network, Displays, Storage and Updates as pages (#1199 Part 1)

## Scope

- Branch `origin/claude/settings-1199-p1` at `179e72bb3`, one commit on
  `origin/claude/segno-integration` at `56033baf0`.
- Interim Device, Network, Displays, Storage, Updates and About pages in
  `LoopSettingsFrame` (`lib/settings/`), `_pushOnce` in
  `lib/app/segno_navigator.dart`, `editDisplayBrightness`, the trimmed
  Recording tab, and the re-pointed device-lost banner, engine-stopped
  banner, audio-recovery toast and update toast.
- Against plan Part 1 and its success criteria, AGENTS.md and the owner
  rules.

## Runs

- Full app suite with `SEGNO_ENGINE_LIB` (built by
  `packages/segno_engine/tool/build_test_lib.sh`) in a scratch worktree:
  `+3357 ~49: All tests passed!`.
- `dart analyze --fatal-infos lib test`: no issues.
- `bloc lint lib test packages` from the scratch worktree under the
  scratchpad: 0 issues, 855 files analyzed (not the gitignored-worktree
  no-op).
- Merge check with USB P5 (`origin/claude/usb-storage-1177-p5` at
  `a3de62da3`): `git merge-tree` reports no textual conflict. A scratch merge
  then ran `test/settings`, the settings screenshots, `test/storage` and
  `test/system`: 3 failures (finding M2).
- Mutations (applied on P2, which contains P1's code unchanged; each
  reverted):
  - audio-recovery toast action back to `openSegnoSettings`: survived
  - Displays `resetValue` removed: survived
  - `openUpdateSettings` stops dismissing the update toast: survived
  - `isSegnoUpdatesSettingsOpen` always false: killed
  - `_pushOnce` duplicate guard removed: killed
  - `editDisplayBrightness` failure toast silenced: killed

## Verified correct (traced)

- Every body the pages host reads only app-wide providers (`AudioSetupCubit`,
  `RecordOptionsCubit`, `TempoCubit`, `ConsoleFactsCubit`, `UpdateCubit`,
  `DisplayBrightnessCubit`, `RefreshRateCubit` and so on are provided in
  `app.dart`), so the pages work over the root navigator. The only
  `SettingsTrayCubit` readers left are the tray panels themselves.
- `StorageSystemTab` and `AboutSystemTab` load `ConsoleFactsCubit` in
  `initState`; `WifiTrayBody` loads and scans on mount; the Network page owns
  and closes its `WifiCubit` (tested).
- `_pushOnce`: the guard is taken before any await (so a catalogue load in
  flight counts as open) and released in `finally`. Dropping
  `openPedalSetup`'s extra `_externalPedalsOpen = false` is safe: Stage's
  `popUntil(isFirst)` completes the External pedals route's own push future,
  whose `finally` releases its name.
- `openSegnoSettings` (still the old page here) checks the guard before
  writing `_openSettingsSection`, so a second call cannot clear the section
  of the open page.
- Update toast suppression covers the new route; the update toast action
  opens `segno/settings/updates` (tested in `app_test.dart`).
- Device-lost banner and engine-stopped banner open Device (tested).
- `editDisplayBrightness` is shared by the tray popover and the page; the
  failure toast is on the app overlay.
- Brightness writes per drag frame, as the tray capsule already did; no new
  process-spawn cost.

## Findings

### Medium

**M1. The audio-recovery toast's route change is untested.**
`lib/app/view/app.dart:1005` now opens Device, which is the fix for the
engine-stopped case the plan describes. Changing it back to
`openSegnoSettings()` passes the whole of `test/app/view/app_test.dart`.
This is the recovery path when the interface disappears (rule 2), and it is
one of Part 1's listed success criteria. Fix: a test that raises the
audio-recovery toast, taps its action, and expects
`segno/settings/device` on the navigator.

**M2. Semantic conflict with USB P5 (#1217): the Storage page tests break
after a clean merge.** USB P5 makes `StorageSystemTab` embed `StoragePage`,
which reads `StorageCubit`. `test/settings/view/destination_harness.dart`
(providers at `:178-196`) has no `StorageCubit`, so after merging P1 and USB
P5 three tests throw `ProviderNotFoundException`:
- `settings_destinations_test.dart: each destination Storage opens once...`
- `settings_destinations_test.dart: Storage and Updates Storage hosts the
  storage face`
- `settings_destinations_screenshots_test.dart: storage`

Production is fine (USB P5 provides `StorageCubit` app-wide in `app.dart`).
Whichever PR lands second goes red in CI. Fix: the second merger adds a
`StorageCubit` (over `UnsupportedUsbStorageClient`) to the harness and
regenerates `settings_storage.png` on the author's machine; record it in the
plan's build record now.

**M3. The brightness bar cannot be adjusted without touch.**
`lib/settings/view/displays_settings_page.dart:38` uses `ConsoleValueBar`,
which has no focus node, no arrow-key shortcuts and no semantic
increase/decrease actions. The tray's `BrightnessCapsule` has all three
(`brightness_capsule.dart:124-134`). Nothing is lost in this PR because the
capsule still exists, but Part 5 deletes it and then brightness becomes
touch-only for the encoder and screen-reader paths (#198). The bar also maps
its whole travel to 0..1, so the leftmost 10% is dead under the 0.1 floor.
Fix: either make the page's control keyboard and semantics adjustable over
`kMinDisplayBrightness..1`, or add that as a gating criterion on Part 5.

### Low

**L1. Double tap to reset brightness is untested.** Removing
`resetValue: kDefaultDisplayBrightness` passes `test/settings`; the plan's
criterion lists "a double tap sets 1.0".

**L2. `openUpdateSettings` dismissing the toast is untested.**
`segno_navigator.dart` (`openUpdateSettings`, first line) can be deleted
without a failure. It matters from Part 2 on, where the Updates tile opens
the page while the toast may be showing.

**L3. The update toast stays suppressed while About covers Updates.**
`isSegnoUpdatesSettingsOpen` is true whenever the Updates route is on the
stack, including under About, where the offer is not visible. Minor; About
is one Back away.

**L4. The Network page silently falls back to an unsupported radio.**
`network_settings_page.dart:24-28` catches `ProviderNotFoundException` and
builds `UnsupportedWifiClient`. The app always provides `WifiRepository`, so
in production this only hides a wiring mistake behind a "not supported"
body. Prefer a plain `context.read` and let tests inject the repository
through the existing `repository` parameter.

## Notes

- Plan departures in the build record (click level via `AudioRoutingCard`,
  `ConsoleValueBar` brightness, card-toned panel, About as its own route)
  are documented; M3 is the one with a downstream cost.
- The `segno_navigator_test.dart` named in the criteria was not created; the
  push-once / Back / Stage behaviour is covered in
  `test/settings/view/settings_destinations_test.dart` instead, which is
  fine.
- The five interim goldens look as the build record describes (checked
  Device, Displays and Updates by eye).

Verdict: Request changes (M1 and L1 are missing tests for the plan's own
criteria; M2 must be carried by whichever of #1218 and #1217 lands second;
M3 can be deferred to a Part 5 gate if the owner agrees).

## Delta review (9dcddac52)

Scope: `9dcddac52` (the fix) on top of `2441542c0` (merge of trunk
`097e1ef68`).

Runs:
- `dart analyze --fatal-infos lib test`: no issues. `bloc lint lib test
  packages` from a scratchpad worktree: 0 issues, 894 files.
- `test/settings test/audio_setup test/app/view/app_test.dart
  test/screenshots` with `SEGNO_ENGINE_LIB`: `+502 ~56: All tests passed!`.
  The full app suite was run on P2, which contains this commit unchanged:
  `+3508 ~56: All tests passed!`.
- Mutations on this head (each reverted), all killed: audio-recovery toast
  back to the old page; double tap no longer resets brightness;
  `openUpdateSettings` keeps the toast; `LoopSlider` loses its semantic
  increase; brightness mapped to raw travel (dead 10% back); Maximum loop
  length taken off the Device tab.

### Findings from the first round

- **M1 (recovery toast untested): resolved.** New `app_test` case drives the
  real toast with an absent pinned device and expects `DeviceSettingsPage`.
- **M2 (USB P5 Storage tests): resolved as a seam.** The harness spreads
  `extraProviders()` (`test/settings/view/destination_harness.dart:199`)
  from `test/settings/view/destination_extra_providers.dart`, so the P5 merge
  adds `StorageCubit` in one place. Every Storage path that builds the page
  (destination tests, screenshot test) goes through that harness. The merge
  still has to add the provider and regenerate `settings_storage.png`, as the
  file says.
- **M3 (brightness without keyboard): resolved.** `DisplayBrightnessRow`
  (`lib/settings/view/displays_settings_page.dart`) uses `LoopSlider` over
  `kMinDisplayBrightness..1`: Enter / arrows / Enter, Escape cancels,
  double tap returns to full, and `LoopSlider` now exposes `onIncrease` /
  `onDecrease` with `increasedValue` / `decreasedValue`
  (`loop_settings_widgets.dart:1081-1095`). The dead 10% is gone.
- **L1, L2: resolved** (tests added, mutations killed).
- **L3: not changed, accepted** in the build record.
- **L4: resolved** (plain `context.read`).

### New in this commit

- Maximum loop length moved to the Device tab as `MaxLoopLengthCard` (plan
  D3); the Recording tab keeps only the default multiple. The tray's Audio
  face shows the same card, and its goldens were regenerated.
- Note: `LoopSlider`'s new semantic actions apply to every Loop settings
  slider, which is an accessibility improvement app-wide.
- Merge with USB P5 at `a3de62da3`: the remaining textual conflicts
  (`app_runtime.dart`, `app.dart`, two runtime tests) come from the trunk
  moving under P5 (the same conflicts appear merging trunk `097e1ef68` with
  P5), not from this branch.

Verdict: Approve.
