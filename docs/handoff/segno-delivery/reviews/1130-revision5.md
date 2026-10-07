## Scope reviewed

Full `change.diff` (11 files) plus enclosing code and callers:

- **Production:** `lib/looper/view/foot_mixer_view.dart`, `lib/looper/view/tracks_commands.dart`, `lib/looper/view/tracks_view.dart`, `lib/control/cubit/control_cubit.dart`, `lib/app/app_toasts.dart`.
- **Supporting reads (unchanged):** `control_foot_mixer.dart`, `foot_mixer_actions.dart`, `control/model/foot_mixer.dart`, `audio_setup/cubit/monitor_cubit.dart`, `app/monitor_mute.dart`, `app/mix_settings_coordinator.dart`, `app/fx_chain_persistence.dart`, `packages/looper_repository/lib/src/looper_repository.dart` (`monitorChanges`, `allMonitors`, `_acceptMix`, `_requestMix`, `setMonitorMute`, `setMonitorVolume`), `app/audio_bootstrap.dart`, `shortcuts_help_sheet.dart`.
- **Tests:** the four changed files, plus every other tree that mounts `FootMixerView`/mixer mode (`test/screenshots/tracks_screenshots_test.dart`, `test/looper/view/tracks_view_test.dart`, `test/app/view/app_test.dart`) to check provider/stub breakage.
- **Docs:** both review/plan edits.

**Limits:** static reading only — no execution, no goldens rendered, no coverage or suite verification, no hardware/runtime evidence. Test-count, coverage and process claims in `review.md` are unverifiable here. I did not read the source-hash manifest.

## Independent verification of the four prior findings

**F1 — display source (real; correctly fixed).** `MonitorCubit._readMonitor` parks announces in `_heldReads` while `!_restored` (`monitor_cubit.dart:281-284`), and `_restored` is set only by `_followRepository`/`projectFromRepository` (`:250-255`, `:434-440`). A refused restore emits `restoreFailed: true` with the old (empty) `inputs` (`:121`, `:141`, `:151`) and never flips `_restored`, so the cache stays blank while the Mixer's writes land in the repository (`FootMixerActions.step/reset` → `MixSettingsCoordinator`; `toggleMute` → `applyMonitorMute` → `repository.setMonitorMute`). The pre-change `context.select<MonitorCubit,…>` therefore rendered 100%/unmuted over accepted repository values. The fix reads the same source as dispatch (`foot_mixer_actions.dart:39` vs `foot_mixer_view.dart:32`). Rebuild coverage is complete for what the surface shows: volume via `_acceptMix`'s `changedMonitors.forEach(_monitorChanged)` (`looper_repository.dart:692-730`), mute via `setMonitorMute` (`:5191`), mode/mask/chain via `:5149/:5159/:6660`; track-domain gain still arrives through the `LooperBloc` selector. `monitorChanges` is a **broadcast** controller (`:255`), so the second listener alongside `MonitorCubit` is legal, and `_ControllerStream` equality keeps `StreamBuilder` from resubscribing per rebuild. Initial paint is correct because `allMonitors()` is read synchronously in the builder. No second cache, no restore bypass, no new owner.

**F2 — keyboard catch-all (real; correctly fixed).** `Shortcuts` is itself a `Focus` in the chain *above* `TracksView`'s node (`tracks_view.dart:180-182`), so the old `return KeyEventResult.handled` for any non-Tab/non-`S` key ran before the ancestor `ActivateIntent` binding and before the modifier block — focused Exit/Settings could not be activated and `Cmd/Ctrl+Z/Y/S/Shift+C` were swallowed. The new ordering (`tracks_commands.dart:196-235`) restores modifier routing, ignores Enter/Space so `InkWell`'s `ActivateIntent` action can fire, and still returns `handled` for every other plain key, keeping digits and transport isolated (`keyS` alone falls through to settings; Tab is handled earlier at `:180`).

**F3 — obsolete arm (real; safe to delete).** `_onPress` returns into `_onMixerPress` before the track-button switch (`control_cubit.dart:2503-2506`), and `trackPressed` has exactly one production caller (`:2586`), so the `channel % 4` arm was unreachable; the live path resolves slots through `role.slot` + `FootMixerActions.select` against the current page. `selectFootMixerSlot` keeps its `_mixerEditable` guard, so no persistence guard was lost either way.

**F4 — toast identifier (consistency, not a behavior bug).** The old literal was used symmetrically at show and dismiss and nowhere else (no remaining `'footMixerFailure'` occurrences anywhere in `source/`); emission (`tracks_view.dart:130`) and disposal (`:54`) now share `AppToastId.footMixerFailure`.

## Test oracles (composed, not nominal)

`app_test.dart:1006-1091` is a genuine reproduction/control pair: with `refuseRead = true` it asserts `monitor.state.inputs` is **empty** and `restoreFailed` true while the readout tracks `.95/.40/.98` and `repository.monitorVolume(0)` agrees — pre-fix this showed `100%`. It also drives `MixSettingsCoordinator.setControllerValues` (the external/MIDI owner) and checks the ceiling caption and refused over-step. The mute test adds the `monitorMuted` + `loadMonitorMute` + caption triple. `tracks_view_test.dart:348-432` uses a real `ControlCubit` and real `Focus.requestFocus`, so activation can only pass via the ancestor `Shortcuts`; the ancestor-`Focus` probe genuinely proves `Ctrl/Cmd+Q` passthrough and the `verifyNever` pair proves transport isolation. `foot_mixer_dispatch_test.dart:171-186` is discriminating: pre-change, `trackPressed(0)` would have moved `footMixer.channel` to 0. All other trees that mount the view already provide `RepositoryProvider<LooperRepository>` and stub `monitorChanges`/`allMonitors` (`tracks_screenshots_test.dart:152-158,230`), so no untouched test loses its provider.

## Findings

**1. Low — `lib/looper/view/tracks_commands.dart:231-233`.** Enter/Space return `ignored` unconditionally in Mixer, including when the `TracksView` node itself holds primary focus (it is `autofocus: true`, `tracks_view.dart:181`, and nothing inside the Mixer is focused on entry). Trigger: enter Mixer by pedal/`M`, press Space without tabbing. Impact: the key leaves the app unhandled, which is exactly the condition this map's own contract avoids ("Plain keys are consumed (so macOS does not beep)", `:160-161`); no functional loss otherwise. Minimal repair, using the node already passed in:

```dart
if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
  return node.hasPrimaryFocus
      ? KeyEventResult.handled   // nothing focused to activate
      : KeyEventResult.ignored;  // let the focused control activate
}
```

That keeps the F2 fix intact (a focused button means `hasPrimaryFocus` is false) and preserves the no-beep contract.

## Optional (not defects)

- `tracks_commands.dart:161-173` still documents "Every mode: `M` cycle mode · `S` settings · `G` signal · `F` fullscreen · `Space` play/pause all · `C` clear all · `A` arm", which is false in Mixer (`M` exits; `G/F/Space/C/A`/digits are blocked). The comment carries an explicit sync contract with `shortcuts_help_sheet.dart`, which has no Mixer rows at all. Inaccurate before this change too, but this change is where the Mixer key policy was rewritten.
- Reordering also means `?` (Shift+`/`) now opens the shortcuts legend over the Mixer, where the legend documents none of the Mixer's keys. Harmless; worth a deliberate decision.
- `foot_mixer_view_test.dart` always stubs `monitorChanges` as an empty stream, so the widget-level test covers the repository *read* but never the stream-driven rebuild; that coverage lives only in `app_test`. An added emission case there would localize a regression.

## Preexisting / out of scope

- Enter on a focused control is still swallowed in **record/mute/FX/custom** modes by the final catch-all (`tracks_commands.dart:346`) — the same mechanism as F2, untouched by this correction.
- Monitor gain's durable home is the device-scoped `MixSettingsPersistence` image, while `MonitorCubit._restoreInput` reads `settings.loadMonitorVolume` (`monitor_cubit.dart:403`), a key written only by the one-time v3 migration (`monitor_migration.dart:177`; `FxChainPersistence` never persists volume). Whether a Retry/restore can therefore push `volume ?? 1.0` (`:424`, `:178-195`) over a newer accepted gain depends on bootstrap ordering I did not trace — **unverified**, belongs to the #1126/#1128 restore owners, and is unchanged by this diff (the F1 fix only makes live values visible).

## Verdict

No actionable defects in the correction's substance: F1–F4 are each real and each repaired at the right layer, with ownership, guards, ingress and notice identity preserved. One low-severity refinement (finding 1) plus the documentation drift above.
