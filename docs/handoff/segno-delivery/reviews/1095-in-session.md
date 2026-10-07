Model: Claude Opus (subagent), in-session
Base: 8b740c093b7ae84fb36c19fac88914246d6278b3 (codex/shared-click-volume)
Head: f186bb952d1d000522c5e8e55226bc2ee0931538 (codex/shared-overdub-decay)

# PR #1095 review: shared overdub decay across controller mappings

Scope: production code under lib/ and packages/*/lib at the head, against AGENTS.md and docs/plan/2026-10-01-shared-overdub-decay.md. Read-only; nothing was built or run.

The core transaction looks correct as traced: value targets, the 0/.5/1 conversion, the per-address revision fence, Use default supersession through the MIDI engine and External invalidation, Released projection into restart intent, durable session capture, and the Mixer → Click → Decay lock order. Dispatch tests use the real PlaybackOptionsCubit and real LooperRepository over a fake native engine, so they are independent of the code under test.

## Introduced defects

### 1. A failed startup restore is erased by the next engine start or reconnect (medium)
`lib/looper/cubit/playback_options_cubit.dart:142-158`, together with `:183-243`.

**Trigger:** At boot, `_restoreDecay` fails. Either `readDecayCheckpoint` throws (a store error, or a FormatException for an out-of-range value at `packages/settings_repository/lib/src/settings_repository.dart:1761-1767`), or native refuses at `:218-232`, which itself calls `stopEngine()`. Afterwards the user starts the device from audio setup, or the reconnect supervisor reopens it (`packages/looper_repository/lib/src/looper_repository.dart:1770-1772`). Either path bumps `mixGeneration`. `_onLooperState` then takes the lifetime branch, sets `_last = applied` (`:155`), and publishes `decayReady: true` (`:158`), adopting repository values that were never restored. In the read-failure case bootstrap also failed, so those values are 0 with no overrides.

**Impact:**
- The saved default and overrides are silently not applied.
- `flushDecay` now reports success, so power-off proceeds.
- The next session save captures 0 and no overrides as durable intent.
- This contradicts the plan ("Startup failure must remain visible and block successful flush").

The branch is right for a session replacement, which supplies complete rig intent. It is wrong for a change in `mixGeneration` alone.

**Smallest fix:** Keep a `_restored` flag, set only by a successful `_restoreDecay` or by a change of `sessionRevision`. In the lifetime branch, publish `ready: _restored && replayOk` and set `_last = applied` only when `_restored` is true. Alternatively, re-run `_restoreDecay` on a change of `mixGeneration` alone while unrestored.

### 2. An out-of-range decay scalar now blocks audio start, session save and power-off (low; high consequence)
`lib/app/audio_bootstrap.dart:35-62` and `settings_repository.dart:1765`.

**Trigger:** Any persisted `looper.overdub_decay` or `track_overdub_decay.N` value outside 0..100, or not an int. Before this PR, `saveTrackOverdubDecay` stored the unclamped `event.percent`, and loads clamped through the repository. Now validation throws, and the docstring states malformed values "are not repaired".

**Impact:**
- Every boot skips auto-start, with `recoveryConfig: null`, so the recovery supervisor never opens the device.
- Decay stays unavailable.
- `runDecayExclusive` throws (`playback_options_cubit.dart:477-479`), so every session save and load fails.
- Power-off Retry can never succeed: `app.dart:638` calls `recoverDecay` → `_restoreDecay`, which throws again.
- No path in the app can rewrite the bad key.

**Smallest fix:** Keep the failure scoped to Decay: log it, start the engine, and leave Decay unavailable. Add one explicit repair action on Retry that rewrites the offending scalar via `restoreDecayCheckpoint` (for example, removing it as Use default). This is an explicit user repair, not a silent fallback.

## Ownership, layering, duplication (owner objections likely)

### 3. LooperBloc now depends on PlaybackOptionsCubit only to forward one call
`lib/looper/bloc/looper_bloc.dart:753-764, 888, 924`, `lib/looper/view/looper_page.dart:42`, `lib/app/view/app.dart:412`.

The handler wraps `setTrackOverdubDecay` and tracks `_decayWrites` so that `LooperPersistFlush` can wait on them. That duplicates `flushDecay`, which power-off already awaits at `app.dart:654`. `loop_playback_page.dart:85-94` already calls PlaybackOptionsCubit directly for the default scope.

**Fix:** Have the page call `context.read<PlaybackOptionsCubit>().setTrackOverdubDecay(...)` for the track scope too. Then delete the event handler, `_decayWrites`, the flush wait and the constructor parameter. The plan said "retain the event", but that only preserves a new Bloc-to-Cubit edge.

ControlCubit taking `DecayControl` (`control_cubit.dart:411,445`) follows the TempoCubit→Control precedent from #1094, so treat it as existing debt.

### 4. Repeated type chains and copied dispatch blocks
A third `|| target is DecayValueTarget` was added at four sites:
- `control_cubit.dart:571-573`
- `control_cubit.dart:680-682`
- `control_cubit.dart:741-743`
- `control_midi.dart:684-686`

The `switch` at `control_cubit.dart:936-939` repeats the family a fifth time.

The External decay write block (`control_cubit.dart:905-931`) and the MIDI one (`control_midi.dart:807-837`) copy the adjacent Click blocks (`control_cubit.dart:886-903`, `control_midi.dart:789-806`). Only the owner call and the origin check differ.

**Fix:**
- Add one getter on `ControlValueTarget`, such as `hasReleasedEndpoint`.
- Add one helper, such as `_writeOwnedValue(target, value, released, origins) → Future<bool>`, that switches once on the owner family.

The UI has the same pattern:
- `clickVolume:` and `decaySnapshot:` are threaded together through nine resolver calls in `midi_controls_page.dart` and `external_pedal_page.dart`.
- The pair of `if (target is ClickVolumeTarget && … == null) return; if (target is DecayValueTarget && … == null) return;` guards appears at `midi_controls_page.dart:921-928`, `external_pedal_page.dart:595-602` and `:1199-1209`.

One `ValueOwners` record passed to the resolver would collapse each future owner to a single field.

## Preexisting debt (not introduced; the same as Click)
- **Storage on every controller step.** Every controller step does a verified scalar read and write before the native write, serialized on the owner queue (`playback_options_cubit.dart:326-340`). Expression sweeps on appliance flash queue up and lag audibly. Click (`tempo_cubit.dart:636-647`) does the same.
- **Historical outcome in flush.** `flushDecay` returns the last historical outcome (`:421-427`), as `flushClickVolume` does. A refusal that rolled back cleanly still fails the first power-off attempt; Retry clears it.
- **No post-operation recovery around session load.** `runDecayExclusive` has no post-operation recovery, unlike `runClickVolumeExclusive`. A partial `applySession` failure leaves partial decay in the restart intent. This is the inherited session-load defect the PR body acknowledges.

## Optional tests
- Make `_restoreDecay` fail, then bump `mixGeneration` (stop and start). Assert that `decayReady` stays false and that `flushDecay` is not `applied`. This catches finding 1.
- Boot with `track_overdub_decay.3 = 150`. Assert that the engine still starts and that Retry can repair the key, if fix 2 is taken.

## Nits
- `_restoreDecay` stops the audio engine when one preference write is refused natively (`playback_options_cubit.dart:220-222`). Reporting Decay as unavailable would be enough.
- `PlaybackOptionsCubit` publishes the live held value while the engine is stopped (deferred), but the next start replays Released. The readout briefly shows a value that will not be heard.
