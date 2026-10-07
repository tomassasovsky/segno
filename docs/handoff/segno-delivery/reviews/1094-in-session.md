Model: Claude Opus (subagent), in-session
Base: 42e5e849ec21bc5cd6a6feae0251a96923556ba7 (codex/shared-mixer-control-catalogue)
Head: 8b740c093b7ae84fb36c19fac88914246d6278b3 (codex/shared-click-volume)

# PR #1094 review: shared Click volume assignments

Read-only review. Nothing was built or run. Line numbers refer to the PR head.

## Introduced defects

**1. [High] A Click edit while the audio device is unplugged stops the engine, blocks restart and disables reconnect.**
`looper_repository.dart:6525-6531` admits the command whenever `_intendRunning` is true. During device loss the engine stays configured but the callback is stopped (see the "running-but-disconnected" comment at `engine.c:902-913`). `le_push_cmd` succeeds, so `commandsSettled` never becomes true. After 500 ms, `settleClickVolume` (`:6583-6585`) calls `blockStartForClickRecovery()` and then `stopEngine()`, and `stopEngine` calls `_stopReconnectPolling()` (`:2319`).
*Trigger:* unplug the pinned interface, then touch the Click slider or move a MIDI, expression or pedal control mapped to Click.
*Impact:* the reconnect poll is gone. `AudioRecoveryCubit`'s `startEngine` (`audio_recovery_cubit.dart:87`) returns `notReady` because start is blocked. Even after Retry, audio stays stopped. Before this PR the edit was a plain push that the reconnect replayed.
*Fix:* while the device is absent or reconnecting, treat the edit like a stopped edit: update `_clickVolume`/`_clickRestartVolume`, return ok with no pending receipt, and let `startEngine` replay the restart value. At minimum, do not set the start block on a timeout that happens during reconnect.

**2. [Medium] Touch drags are not coalesced.**
`tempo_cubit.dart:582-588` places every `onChanged` call (`click_volume_section.dart:35`, `audio_routing_card.dart:59`) into a FIFO (`_queueClick`, `:211-218`). Each queued edit reads a checkpoint, saves and reads back the value, and waits at least one 10 ms settle poll. The sliders show the accepted `state.clickVolume`, so:
- the Material slider lags while dragging;
- `ConsoleValueBar` jumps back to an old value on release and then steps through every queued value;
- the sound lags further behind the longer the drag lasts;
- each drag frame costs one storage write.

`MixSettingsCoordinator` coalesces drags explicitly ("a drag cannot accumulate event waiters", `mix_settings_coordinator.dart:97-101`).
*Fix:* keep one pending latest ordinary value and drain it the way `_submit`/`_drain` do.

**3. [Medium] `flushClickVolume` reports old history, so power-off can be blocked with nothing pending.**
`tempo_cubit.dart:239` returns `_lastClickOutcome`. Every `_reportClick` (`:268-276`) sets that value, including `superseded` at `:703-710` and refusals that were already rolled back cleanly. The toast ignores `superseded` (`app.dart:68`), but `app.dart:601-603` throws on it and the dialog moves to `flushFailed`.
It gets worse when the earlier write was superseded because `stopEngine` cancelled its receipt. `_cancelClickVolume` leaves `_lastClickVolumeResult = notReady` (`looper_repository.dart:6564`), so `clickVolumeSettled` stays false while the engine is stopped. Retry's `recoverClickVolume` then refuses at `tempo_cubit.dart:285-295` every time. Power-off cannot complete until the user leaves the dialog and edits Click.
*Fix:* make the flush report the current state (queue drained, `!_clickRecoveryPending`, `clickReady`), not the last result. Make `_cancelClickVolume` keep the prior confirmed result. Note that `click_volume_transaction_test.dart:319-336` currently encodes "a refusal blocks flush".

**4. [Low-Med] Silent change: all continuous controller input is off while the power-off UI is up.**
`control_cubit.dart:388` (expression), `:584` (queued External writes) and `control_midi.dart:543` (MIDI parameter writes) now return early on `_takeLocked()`. That callback is `PowerOffCubit.state.isUiUp` (`app.dart:632,673`), which is already true in the confirm, refuse and saveAs phases. While the confirm dialog is open, expression pedals and MIDI faders do nothing on any target, not just Click. The doc at `control_cubit.dart:148-149` still says only Rec, overdub and perf-arm are suppressed.
*Fix:* gate on `_haltInputSuspended`, which is set only once the flush starts. If the wider lock is intended, record it as accepted behaviour.

**5. [Low] Silent change: power-off has no way out when storage fails persistently.**
`app.dart:579-604` now throws on monitor, looper and Mixer flush failures. Before this PR those were logged and skipped. `power_off_cubit.dart:125` then offers only Retry or Keep playing. If `/data` is read-only or full, the soft power key can never halt the appliance, so the user has to pull power, which is worse than losing one setting. The plan requires this only for Click.
*Fix:* restore log-and-continue for the non-Click owners, or add "Power off anyway" after a failed Retry.

## Ownership, layering and duplication

**6. One Cubit depends on another.** `ControlCubit` takes `TempoCubit` through `ClickVolumeControl`, subscribes to its stream and calls its methods (`control_cubit.dart:180-186`, `app.dart:622`). Control views `watch<TempoCubit>()` (`midi_controls_page.dart:462`, `external_pedal_page.dart:508,531,990`). `TempoCubit` grew a durable transaction owner (+486 lines: checkpoint, rollback, recovery, failure stream, start block) that copies `MixSettingsCoordinator`. In the repository, `settleClickVolume` and `_PendingClickVolume` copy `settleMixSettings` (`looper_repository.dart:6571` vs `:672`). The plan approved TempoCubit as the owner, so this is a direction call for the owner. The established pattern is a non-Bloc `ClickVolumeCoordinator` in `lib/app`, provided once and used by both TempoCubit and ControlCubit. That would also remove the `initState` construction.

**7. Repeated `is` chains and copied blocks.** `target is MixValueTarget || target is ClickVolumeTarget` appears at `control_cubit.dart:546,653,705` and `control_midi.dart:662`, plus the `_midiStep` pair at `:483-484`. The code that picks the Released value is copied four times: `control_cubit.dart:814-820` vs `:849-855`, and `control_midi.dart:733-742` vs `:766-775`. The two MIDI copies take the holder from different places (`_midiHolderKeys[rowKey]` vs `entry.value.holder`). The External Click arm also lacks the Mixer's refused-release retry (`:828-839`).
*Fix:* add one sealed intermediate target type (for example `OwnedValueTarget` with `relativeStep`) and one `_releasedFor(target, held, holder)` helper.

## Preexisting debt
- When the Mixer settle times out, `settleMixSettings` also calls `stopEngine()` (`looper_repository.dart:686`). That kills reconnect polling during device loss in the same way as finding 1, but without a start block.

## Optional tests
- Fake engine with publishing off and the device marked lost: a Click write must leave reconnect armed and start unblocked.
- Twenty rapid `setClickVolume` calls should cause at most two saves, and the final value should win.
- Power-off flush after a superseded write, and after a stop that cancelled a pending receipt.

## Nits
- `origins.click ?? _clickVolume.clickVolumeLifetime` (`control_cubit.dart:857`, `control_midi.dart:779`) silently swaps the lifetime fence for the current lifetime. Make it non-null whenever a Click target is present.
- The literal `2` at `looper_repository.dart:6510` duplicates `kMaxClickGain` and `LE_MAX_GAIN`.
- Tests use literal oracles (for example `.25`, `1.5`, `closeTo(.4)`), not the production `toDomain`. That is good.
