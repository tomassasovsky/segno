Model: Claude Sonnet (subagent), in-session; no earlier Claude verdict exists for this packet
Base e160b677ae222a6ef8558c321e3e5cc0504496dc, head 623a5a7ba7ff595e60917c5ee9c4ece667c6389d (PR #1126)

# Verdict

No defect in the core change: the linear 0-100% mapping, the coordinator/repository/snapshot/Session/Settings admission bounds and the Session-load reordering are correct as traced. Three consequence findings sit at the edges of the new fail-closed read. None is a correctness error in the accepted-range logic. Two are Medium and need an owner decision or a small guard. No blocker for the stated scope if the owner accepts finding 1.

# Findings (introduced by the diff)

## 1. Medium (owner decision): one stale gain in 1..2 makes the whole mix blob unreadable, with no in-app recovery
- Path: `packages/settings_repository/lib/src/settings_repository.dart:1472-1475` (`_readMixSettings` now throws FormatException for any `monitorLevels` entry >1). `_readMixSettings` is the shared reader for every mix path: `loadMixSettings` (:1565), `loadMonitorVolume`, `saveMonitorVolume` (:1158), and `replaceMixSettings` (:1582), which reads the blob at the end to preserve other devices' setups even though it overwrites `monitorLevels` wholesale.
- Trigger: any install whose stored `mix_settings` holds a monitor gain in (1, 2]. That was legal and reachable before (old clamp 0..2).
- Impact: track, lane, pan, trim and output levels stored in the same blob also become unreadable. `audio_bootstrap.dart:230` fails startup and the FormatException handler at the call site (audio_bootstrap.dart ~:211) stops it, so the engine does not start. Every later edit via `SettingsMixPersistence.write` -> `replaceMixSettings` also throws, so the player cannot overwrite the bad value from the UI. The only repair is outside the app (delete the key). On the appliance that is no audio after upgrade.
- AGENTS.md says do not migrate, and the plan accepts rejection. If that is deliberate, this is by-design. The smallest correction that keeps "no migration" is to make the repair path possible: `replaceMixSettings` should not fail on a bad `monitorLevels` it is about to replace (parse the monitor map leniently there, or validate in `loadMixSettings`/`loadMonitorVolume` only). Alternatively record explicitly that field devices need a manual reset.

## 2. Medium: after a failed Monitor load, edits overwrite the saved monitor state with repository defaults
- Path: `lib/audio_setup/cubit/monitor_cubit.dart:112-116` now swallows the load failure into `addError`. `_restored` is only set at :199/:386, so it stays false and the repository keeps defaults. Edits are not gated: `setMode`/`setOutputMask`/`setMute` (:398-430) call `_persistMonitor` -> `FxChainPersistence._saveMonitor` (`lib/app/fx_chain_persistence.dart:390-408`), which writes the repository's mode, output mask, mute and FX chain for that input.
- Trigger: any bad stored gain (the new, deliberately reachable case from finding 1), then the user changes one control on an input.
- Impact: that input's saved output mask, mute and FX chain are replaced by defaults, silently and permanently. This is the exact "defaults saved over good settings" hazard the code already guards against in `_readMonitor` (:166-176 comment). The PR makes the restore failure a normal path but does not extend that guard.
- Smallest correction: gate monitor edits (or `_saveMonitor` for the input stage) on a successful restore, e.g. refuse in the setters while `!_restored && loadFailed`, plus a test that edits after a failed load leave stored keys unchanged. The new cubit test only proves no repository mutation during load, not this.

## 3. Low: legacy v3 monitor migration now throws on historical gains >1 and boot does not catch it
- Path: `lib/app/monitor_migration.dart:177` `saveMonitorVolume(input, volume)` receives lane-0 volume from legacy keys (range was up to 2). `saveMonitorVolume` now throws ArgumentError for >1 (`_validateMonitorLevels`, settings_repository.dart ~:1680-1695). It is awaited unguarded at `lib/app/run_segno.dart:172`, before any error handling and before the v3 done-flag is saved.
- Trigger: an unmigrated install with a legacy monitor gain in (1, 2]. Also any pre-existing bad blob makes the migration's `_readMixSettings` throw FormatException.
- Impact: app launch fails on every start (flag never set). Narrow, because it affects only installs that never ran v3, but it is a new hard-crash path from changed validation.
- Smallest correction: `volume.clamp(0.0, 1.0)` in the v3 fold (legitimate there: it converts old-range data), or drop the obsolete migrations per AGENTS.md.

# Verified correct (no finding)
- `control_value_target.dart:204-222`: `toDomain` clamps normalized to 0..1 and returns it; `fromDomain` clamps. Track/lane laws untouched. Relative step is shared 0.02 (:230), unchanged. Readout uses the same `toDomain` (control_value_readout.dart:26), so 0/0.5/1 read 0/50/100%.
- Coordinator ordinary edit rejects out-of-range instead of clamping (mix_settings_coordinator.dart:836-847). The controller path `_withValue` goes through `toDomain`, so Held and Released values (`low.clamp`) stay in 0..1 and the durable projection is linear. `MixSettingsSnapshot.isValid` (:134-142) and `LooperRepository.setMonitorVolume` (:5119) both reject >1, so all three admission points agree; `applyMixSettings` and `applySession` (:3767-3774) validate before building `restoredMix`, so no partial rig mutation on a bad session.
- `SessionMonitor.fromJson` validates at decode, and `loadNamed` also checks `candidate.isValid`; `listSessions` only stats the manifest (session_repository.dart:324-337), so an old bundle with gain >1 fails only on load, not in the catalogue.
- `loadNamed` reorder (session_cubit.dart:232-247): read/decode/validate now precede `disarmAndFinalize`. `rigFromBundle` and `isValid` depend only on the bundle, not on state mutated by disarm, so the move is safe. A bad bundle no longer stops a running performance capture. Later failures after disarm are unchanged pre-existing behavior.
- Bootstrap pre-read (`audio_bootstrap.dart:230`) covers both first-run and saved-config branches before `startEngine`; the second read at :414 is the device-scoped one. Error stays within the existing FormatException handler.
- No native code, allocation or FFI change; I made no claim about native behavior.

# Pre-existing / out of scope
- Stale doc comments still say `0..LE_MAX_GAIN` for monitor volume: `packages/performance_repository/lib/src/models/performance_chains.dart:194`, `packages/performance_repository/lib/src/models/performance_manifest.dart:208` is about playback (fine), `lib/looper/view/signal_graph/signal_style.dart:15` ("quiet take/input can be boosted"). Documentation only.
- `_validMonitorLevels` uses key < 32 while the snapshot uses `kMaxChannels`; unchanged from before.
- Settings `_readMixSettings` can throw TypeError on shape-corrupt JSON, which `audio_bootstrap` does not catch (only FormatException); pre-existing.

# Test-quality notes (optional)
- Good independent observables: Settings tests assert stored bytes unchanged; bootstrap test asserts `startCalls == 0` and unchanged blob; repository tests assert no engine calls and unchanged snapshot/generation/revision.
- Session cubit test for bad gain feeds a pre-built `Session` through a mock `read`, so it exercises the `isValid` guard, not `SessionMonitor.fromJson` (covered separately in session_test). Acceptable, but the ordering guarantee is only mock-verified.
- Missing: migration with legacy gain >1 (finding 3); monitor edit after a failed load leaving stored keys unchanged (finding 2); a test showing mix writes recover (or intentionally fail) when the blob has a bad monitor gain (finding 1).
- The added `docs/code-review/live-input-gain/review.md` states a pending Claude gate; it will be stale once this review lands.

# Scope, completeness, limits
Reviewed: all of change.diff (22 Dart files plus the review and plan docs) and the head sources of every touched path, plus callers traced in source/: coordinator, MonitorCubit, FxChainPersistence, SettingsRepository, audio_bootstrap, run_segno, monitor_migration, SessionCubit, session_mapping, SessionRepository, LooperRepository admission and applySession. Read AGENTS.md. I did not read author review documents before forming this verdict (the diff contains one; I did not rely on it). Limits: read-only, no execution, so no test, analysis or runtime result is asserted; the source tree is a subset (native vendor and some callers/tests absent); engine-side behavior of the 0..1 gains was not inspected; no hardware validation claimed. Findings 1 and 2 follow from code paths I traced but were not reproduced.
