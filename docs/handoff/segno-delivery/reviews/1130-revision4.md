## Review: Segno PR 1130 (Foot Mixer), base `0292450` → head `5bad078`

One complete bounded pass. Read `source/AGENTS.md`, all of `change.diff` (5,400 lines, every hunk), and the current source of every changed file plus the direct callers and repository/settings methods they depend on. No commands run; no runtime or hardware evidence claimed.

---

### Finding 1 — Inputs readout is fed from `MonitorCubit`'s cache, which never tracks monitor level (functional, user-visible)

**Path/line**
- `source/lib/looper/view/foot_mixer_view.dart:32-37` — the view projects from `context.select<MonitorCubit, Map<int, InputMonitor>>((c) => c.state.inputs)`.
- `source/lib/control/foot_mixer_actions.dart:39` — dispatch projects the *same* function from `repository.allMonitors()`.
- `source/packages/looper_repository/lib/src/looper_repository.dart:5167-5178` (`setMonitorVolume`) and `:619-660` (`applyMixSettings`) — neither calls `_monitorChanged`; `_monitorChanged` is only reached from mode/output/mute/FX setters (`:5146`, `:5159`, `:5191`, `:6560`, `:6660`, `:6991`, `:7147`).
- `source/lib/audio_setup/cubit/monitor_cubit.dart:273-310` — `_readMonitor` (the only sync path) runs off `monitorChanges`.

**Trigger** Enter Mixer → Inputs → select a channel → tap Clear/Undo or turn the encoder (also any External/MIDI `MonitorVolumeTarget` write).

**Impact** The gain write lands in the repository/mix, but no `monitorChanges` announce fires, so `MonitorCubit.state.inputs[i].volume` keeps the value it was last synced to. `foot_mixer_selected_gain`, `foot_mixer_gain_bar`, the per-slot percent `detail`, the 0/100% ends and the `canIncrease`/`canDecrease` → `Limit · Hold reset` hint all come from that stale value, so the screen does not move while the live gain does. It catches up only when an unrelated structural monitor change announces (e.g. a mute hold re-reads volume at `monitor_cubit.dart:289`), which makes the number jump. The Tracks domain is unaffected — track gain rides the polled `LooperState` through `LooperBloc`. This directly contradicts the matrix items "readable selected level" and "External/MIDI changes update foot readout via repository truth".

**Second effect, same cause** While `MonitorCubit` has not restored (`restoreFailed` — the exact state this PR's final correction exists for), `_restored` is false, `_readMonitor` only parks the input in `_heldReads` (`:281-284`), and `state.inputs` is empty. Every Inputs slot then renders as unmuted / 100% / `Hear live off` regardless of repository truth: a mute accepted through `applyMonitorMute` is invisible, and the hint reads `Hold · Mute` while `FootMixerActions.toggleMute` (`foot_mixer_actions.dart`, `muted: !repository.monitorMuted(...)`) will *unmute* on the next hold. The audio toggles; the caption says the opposite.

**Direction** Feed the Inputs facts from the same `repository.allMonitors()` the dispatcher uses (publish the projection from `ControlCubit`, or read `LooperRepository` in the view) — the plan's own rule that "all captions and LED roles derive from the same semantic projection used by dispatch" is satisfied for the *function* but not for its inputs.

---

### Finding 2 — The Mixer key branch swallows modifier combos and Material-button activation

**Path/line** `source/lib/looper/view/tracks_commands.dart:174-189` (inserted ahead of the `event is! KeyDownEvent` guard and of the explicit `return KeyEventResult.ignored; // let OS / menu shortcuts through` at `:236`). The handler is installed at `source/lib/looper/view/tracks_view.dart:180-182` as an ancestor `Focus` of the whole body, including `FootMixerView`.

**Trigger** Mixer mode on desktop: press ⌘Q/⌘W/⌘Z/⌘⇧C, or Tab to `foot_mixer_exit` or the Settings button and press Enter/Space.

**Impact** `if (key != tab && key != keyS) return handled;` claims *every* other key, down and up, including modifier combos. Flutter dispatches from the focused node upward and stops at the first `handled`, so (a) the documented pass-through for OS/menu accelerators is bypassed while the Mixer surface is up, and (b) the root `WidgetsApp` `Shortcuts` → `ActivateIntent` never fires, so `IconButton.outlined` (`foot_mixer_exit`) and the Settings `OutlinedButton` take focus, draw a focus ring, and do nothing on Enter/Space. The ten pedals (`_MixerPedal.onKeyEvent`) and the Tracks/Inputs `LoopChoiceButton` (`loop_settings_widgets.dart:33-44`, `LoopFocusable`) handle Enter/Space in their own nodes, so those still work — and Escape/M/S give alternatives — which bounds this to a degraded-a11y/desktop issue rather than a dead end. No test exercises this branch at all.

**Direction** Limit the swallow to unmodified keys and let Enter/Space and `isMetaPressed || isControlPressed` fall through (the latter already has the correct behaviour ten lines below).

---

### Finding 3 — Unreachable Mixer arm in `trackPressed`, with a wrong slot mapping (minor)

**Path/line** `source/lib/control/cubit/control_cubit.dart:2082-2083` (`case InteractionMode.mixer: selectFootMixerSlot(channel % 4);`).

**Trigger** None in production: `_onPress` returns at `:2503-2506` before reaching `trackPressed` in Mixer, and both tile paths break in Mixer (`track_column.dart:395-397`, `wave_track_row.dart:106-108`). Only tests/public API reach it.

**Impact** Dead code today; if a future caller reached it, `channel % 4` is the *normal bank's* slot index, not the Mixer page's, so it would select a channel from whatever page is visible rather than the one pressed. Per AGENTS ("simplest implementation that fully meets the current requirements"), this arm should be `break;` like the Custom arm beside it.

---

### Finding 4 — Toast id convention (minor)

**Path/line** `source/lib/looper/view/tracks_view.dart:54` and `:130` use the literal `'footMixerFailure'`; every other id is a registered constant in `source/lib/app/app_toasts.dart:12-35` (`app_*_*`). Also, the error toast is dismissed only in `_TracksViewState.dispose`, so after Exit it lingers for the remainder of its 5 s auto-close.

---

### Test observations (independent outcomes / simplification)

- `test/control/foot_mixer_dispatch_test.dart:25-28` — `_Clock.pump` is `Future.delayed`, i.e. **real** wall-clock sleeps of 801–900 ms in roughly seven cases, where the neighbouring control suite drives a fake clock (`test/control/external_dispatch_test.dart` uses `r.clock.elapse`). Outcomes stay deterministic (the 800 ms hold timer's deadline precedes the delayed future's), but it adds several seconds of sleeping and departs from the established idiom.
- The new `handleKey` Mixer branch (Finding 2) has **no** test.
- `test/looper/view/foot_mixer_view_test.dart` mocks `ControlCubit` wholesale and hand-writes `MonitorState`; `test/looper/view/tracks_view_test.dart` pages and labels only. No test joins Control's gain write to the on-screen readout, which is why Finding 1 is invisible to the suite. `test/screenshots/tracks_screenshots_test.dart` has to call `projectFromRepository()` by hand to make `MonitorCubit` mirror `allMonitors` — itself a symptom of the same split.
- Not weakened: `test/theme/mode_pair_test.dart` keeps distinctness for the four physical modes and *pins* `mixer == custom` with a stated wire reason; `test/pedal/view/pedal_plate_test.dart` keeps its original assertions and only parameterises the mode. `test/audio_setup/cubit/monitor_cubit_test.dart` additions (shared vs. cubit caller, refused storage + retry, retained failed full save, FX/mute overlap through `close`) and the `audio_routing_test.dart` mute-off/durable-value additions are genuine strengthenings.

---

### Checked and found sound (no finding)

- `_GainEdit` (`mix_settings_coordinator.dart:93-156`): the saturating-step composition `clamp(base + net, low, high)` with `low`/`high` tracking the images of 0 and `ceiling` is mathematically correct for every ordering I traced, including the off-grid pair (`offLow`/`offHigh` over `[0, ceiling-1]`, fraction preserved — 98 % +5 % stays 98 %, then −5 % gives 93 %), endpoint reversals, `net` bounding, absolute-then-relative merge (`_submit:450-457`, slider/reset value as base plus net), relative-then-absolute replacement, and `reset` retiring only preceding `trackLevel` entries (`:447-449`). `moves()` gating of `ordinaryEdits`/commit (`:526-555`) correctly leaves a pure no-op's Held/Released claim intact while an equal-valued real edit still claims ordinary priority. Encoder bursts coalesce through the same pending map without unbounded growth.
- Contact identity: `_pressedButtons` as `Map<PedalButton, Object>` with a singleton `_physicalContact`, identity-qualified release (`:2456`) and cancel (`:2353-2355`); physical-first and screen-first overlap, stale tokens, per-pointer/per-key origin in `_MixerPedalState`, and unmount/disable cancellation all hold. `setMode` → `_invalidateGestures()` (`:3074-3097`) cancels pending Mixer holds on Exit and entry; `_cancelMixerHolds` covers domain and session/`mixGeneration` change; a hold consumed on entry cannot re-fire (`_HoldGesture` retires `_onTap`).
- Isolation from normal transport: selection/paging never touch `cursor`/`activeBank`; `projectFrame` keeps `selectedTrack`/`activeBank` and maps Mixer to the existing `PedalMode.custom` wire value; `_physicalButtonMask`'s Mixer arm (`control_projection.dart:239-244`) lights exactly the selected slot and does not leak `activeBank` through BANK; `projectTrackLed` dark + the two invariant exclusions are consistent; `bootDefaults` excludes `mixer`; `toggleMode` routes Mixer → record.
- Shared persistence: `saveMonitorMuteConfirmed` reuses the single `FxAddress(stage: input)` queue; the `muteOnly && (existing?.muteOnly ?? true)` rule (`fx_chain_persistence.dart:378`) correctly promotes a scalar mute into any outstanding full-envelope save in both orders, including through `close()` via inherited `completeOnClose`; `_drain`'s new input branch writes live `monitorMuted` and leaves the lane path unchanged.
- Monitor Retry interaction: after the mute save lands, `_restoreInput` re-reads the new durable mute (`loadMonitorMute`) and `loadMonitorVolume` reads the live `mix_settings` document, so a newly accepted mute survives Retry and gain is not clobbered by the restore's `setMixSettings` push. The remaining ordering hazard — pressing Retry while a mute save is still in flight, after which the restore re-applies the stale saved mute and the pending write records it — is the shared `MonitorCubit`/`FxChainPersistence` path that `setMute` already had before this PR, not something the Foot Mixer path introduces; flagging it as context, not as a finding.

---

### Completeness and limitations

Covered: `AGENTS.md`; every hunk of `change.diff`; current source for `mix_settings_coordinator.dart`, `fx_chain_persistence.dart`, `monitor_mute.dart`, `track_mute.dart`, `monitor_cubit.dart`, `control_cubit.dart` + `control_foot_mixer.dart` + `control_state.dart`, `foot_mixer_actions.dart`, `control/model/foot_mixer.dart`, `control_projection.dart`, `invariants.dart`, `interaction_mode.dart`, `foot_mixer_view.dart`, `tracks_view.dart`, `tracks_commands.dart`, `track_column.dart`, `wave_track_row.dart`, `pedal_plate.dart`, the two theme files, plus direct callers/dependencies: `app_toasts.dart`, `settings_page.dart`, `output_routing_tab.dart`, `loop_settings_widgets.dart`, `pedal_button.dart`, and the `LooperRepository`/`SettingsRepository` methods the new code calls.

Not done: nothing was executed — no tests, analyzer, formatter or Bloc lint; the coverage, pass-count and hash figures in `docs/code-review/foot-mixer-performance/review.md` are unverified author claims. The five new golden PNGs and the updated picker golden were not opened. `packages/looper_repository/test/foot_mixer_monitor_isolation_test.dart` was read but requires `SEGNO_ENGINE_LIB` and real native audio to mean anything; no DSP, LED, firmware or appliance behaviour is asserted here. Upstream #1128/#1129 internals were read only at their interaction points with this change, as scoped. Findings 1 and 2 are derived from the source and from documented Flutter dispatch/announce semantics, not from an observed run.
