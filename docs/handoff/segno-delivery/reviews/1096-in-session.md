Model: Claude Opus (subagent), in-session
Base: f186bb952d1d000522c5e8e55226bc2ee0931538 (codex/shared-overdub-decay)
Head: 2cf6c3adfc19b0e229717fe4b6d1748267b0c17a (codex/shared-playback-choice)

# PR #1096 review: shared Loop/Once playback choices

Scope: read-only review of the production diff (control binding/resolver/catalogue, ControlCubit external + MIDI dispatch, PlaybackOptionsCubit, LooperRepository receipts/replay/applySession, SettingsRepository checkpoints, bootstrap, App shutdown, LooperBloc, Session mapping, endpoint widgets). Read AGENTS.md and docs/plan/2026-10-01-shared-playback-choice.md at head. No native source changed. Target identities, the 0/.49/.5/1 conversion, non-finite refusal, Custom-false membership, Use default supersession, Held/Released durable split and session capture all match the plan. Exact-head CI is green.

## Introduced defects

### 1. A cancelled Once receipt leaves Playback unusable while stopped (Medium)
- `packages/looper_repository/lib/src/looper_repository.dart:7002-7010`: `_cancelOneShot` sets `_lastOneShotResult = notReady` and records no recovery intent. Only a later successful request clears it. `stopEngine()` (2400) reaches it through `_cancelMix` (719-721).
- Trigger: `startEngine` queues the startup Once replay (2107) and then stops itself on a later refusal: decay at 2133, mix at 2143, FX re-instantiation at 2156/2182/2209/2219/2226, or the startup mix receipt at 712. Any stop within the receipt window of an ordinary or controller write does the same.
- Impact:
  - `PlaybackOptionsCubit._restoreOnce` (`lib/looper/cubit/playback_options_cubit.dart:296-303`) reads `prior = notReady` and reports `recoveryRequired`. That toast cannot be dismissed. Its Retry button calls `recoverOneShot` (604-611), which calls `_restoreOnce` again and gets the same answer for as long as the engine is stopped. `_oneShotInitialized` stays false, so even a later successful start does not publish readiness (419) until the user presses Retry again.
  - If the cubit was already initialized, `_syncOneShot` (425-426) silently sets `oneShotReady=false`. Loop/Once is then disabled, and `runPlaybackExclusive` (880-887) refuses Session Save and Load, until audio restarts.
  - This contradicts the plan's rule "While stopped, accept coherent deferred intent". The cancelled intent was never accepted, and the restart intent still holds the last confirmed vector, so nothing is actually uncertain.
- Smallest fix: make `_cancelOneShot` complete the waiter with `notReady` and leave `_lastOneShotResult` alone. Add a repository test (start → pending → `stopEngine()` → `oneShotSettingsSettled` is true) and a cubit test (failed start, then `load()` initializes while stopped).

### 2. Storage is rolled back after the repository already accepted the write (Low-Medium)
- `playback_options_cubit.dart:525-531, 546-552`: `_writeOneShot` awaits `settleOneShot()` and only then re-checks `current()`. A device restart or stop that bumps `mixGeneration` after the receipt has settled throws `superseded`, and the catch block restores the Settings checkpoint to its old value.
- By that point `_settlePendingOneShot` (looper_repository.dart:389-392) has already moved the new value into the live state and the restart intent. The restart replays the new value and `_syncOneShot` publishes it.
- Trigger: the receipt is settled by the repository timer, and an engine stop or start (AudioSetup/Recovery, reconnect supervisor, Stop) runs before `settleOneShot`'s next 10 ms poll returns. The window is narrow but reachable.
- Impact: the screen and engine show the new value, but Settings holds the old one, so it reverts on the next launch. No ordinary-change event is emitted either, so Control's ordinary priority is never recorded. Decay avoids this because its setter and its restart-intent update run synchronously with no await in between.
- Smallest fix: once `settleOneShot()` returns ok, treat the write as committed. Publish and return `applied`, or return `superseded` without the storage rollback.

### 3. One malformed session key now aborts Load after the live rig is cleared (Low, silent behaviour change)
- `looper_repository.dart:3258, 3525-3531`: `setOneShotSnapshot` returns `invalid` for any key outside 0-7, and `_requireSessionSetting` then throws. This happens after `_awaitCleared`, so the current rig is already wiped.
- The old per-channel loop ignored out-of-range keys.
- `packages/session_repository/lib/src/models/session.dart:791` decodes `trackOneShotOverrides` without the range check that `_readTrackLevels` (1180-1190) applies.
- Smallest fix: reject the out-of-range key at decode time, the same way track levels already do.

## Ownership, layering and duplication (the owner may object)

### 4. Copy-paste Decay/Once machinery (Maintainability)
- ControlCubit:
  - `_supersedeOneShotClaims` (`lib/control/cubit/control_midi.dart:1100`) is identical to `_supersedeDecayClaims` (1077) apart from the parameter type.
  - The OneShot dispatch blocks (`control_midi.dart:856-886`, `lib/control/cubit/control_cubit.dart:963-989`) repeat the Decay blocks (825-855, 936-962) line for line.
  - The `is MixValueTarget || ClickVolumeTarget || DecayValueTarget || OneShotValueTarget` lists now repeat at five sites.
- `OneShotLifetime` is the same record type as `DecayLifetime`, and `oneShotLifetime` has the same body as `decayLifetime` (`playback_options_cubit.dart:134, 369`).
- Bootstrap (`lib/app/audio_bootstrap.dart:64-90`) and `_restoreOnce` (283-327) each read and apply the same nine values, so the startup vector is applied twice while the engine is running.
- AGENTS.md asks for the simplest implementation. A shared helper keyed by `ControlValueTarget` (supersede, origin check, released resolution) would remove about 120 lines without the general framework the plan rules out.

### 5. Cubit-to-Cubit dependency (Preexisting pattern, extended)
- ControlCubit and LooperBloc now also depend on PlaybackOptionsCubit through the `OneShotControl` interface.
- The track toggle goes through LooperBloc, while the default toggle calls the cubit directly (`loop_playback_page.dart:56-67`).
- This matches #1095's Decay design, so it is not a new violation, but the asymmetric path is now repeated.

## Preexisting debt (exposure widened)

### 6. A receipt timeout stops the engine and ends reconnect supervision
- `_failOneShot` (looper_repository.dart:6991-7000) calls `stopEngine()`, which clears `_intendRunning` and stops reconnect polling.
- A pedal or MIDI Once press while a pinned interface is stalled therefore times out after 500 ms. Audio stays stopped and requires recovery instead of reconnecting automatically.
- Click already behaves this way, but Once adds far more controller-driven writes.
- Consider a stop path that does not end reconnect supervision.

### 7. `_applying` now spans awaits
- `playback_options_cubit.dart:294-335, 513-545`: `_applying` stays true for up to 500 ms, and `_onLooperState` ignores every looper-state event in that time, including Decay lifetime changes and `_syncOneShot`.
- The handler catches up on the next emission, but nothing guarantees another emission while the engine is stopped.

## Optional tests

- Finding 1: a startup replay cancelled by a later `startEngine` refusal, then cubit `load()`/`recoverOneShot()` while stopped.
- Finding 2: a lifetime bump between receipt settlement and `_writeOneShot` resuming. Assert that the Settings checkpoint equals the repository's restart intent.
- Session JSON with `trackOneShotOverrides` key `"8"`.
- Test oracles: repository fakes derive `TrackSnapshot.oneShot` from applied commands and gate on `commandsAreSettled`, which is independent enough. `FakeOneShotControl` only models the unavailable owner, so ControlCubit priority coverage depends on the real cubit in `one_shot_dispatch_test.dart`, which is acceptable.

## Nits

- `packages/segno_engine/lib/src/engine_snapshot.dart:676` is a 122-character reflowed doc line. Rewrap it.
- The `PlaybackOptions` and `PlaybackOptionsCubit` class docs (lines 10, 69) still say "explicit track decay membership" and "existing global Once preference". Both are stale.
- `SettingsRepository.loadDefaultOneShot`, `saveDefaultOneShot`, `loadTrackOneShot` and `saveTrackOneShot` (1840-1853) have no production callers left; only tests use them. AGENTS.md says to remove obsolete paths.

Verdict: request changes. Finding 1 is a reachable dead end in which Retry cannot succeed while stopped, and it also blocks Session Save/Load. Finding 2 is a narrow persistence divergence. Both have one-line-scale fixes.
