Model: Claude Opus (subagent), in-session
Base: origin/claude/foot-fade-controls-1147 (merge-base ddd9d8594)
Head: 5525397370dae4b72263ae6cdd6d5f03e66e064f (claude/fade-duration-targets-1148)

# PR #1156 review: Fade durations as MIDI/CTRL value targets

Scope: read-only review of the production diff (FadeSettings, ControlCubit external and MIDI dispatch, resolver, availability, catalogue, labels, readout, l10n), plus the Session coordinator, SessionCubit load/retry and AppRuntime shutdown at head. I also read AGENTS.md, issue #1148 and `docs/design/mapping-parameter-targets.js` (`fadeSeconds`, `trackFadeSeconds`).

Checked and clean:
- **live vs confirmed.** Held writes persist only `releasedMilliseconds ?? milliseconds` (`fade_settings.dart:149-154`). Session capture reads `_fade.confirmed` (`session_settings_coordinator.dart:104`). Gestures, the view and the readouts read `live` (`foot_fade_actions.dart:20`, `foot_fade_view.dart:29`, `control_availability_view.dart:34`).
- **Queued writes across Save and Load.** Controller writes are admitted during the exclusive scope and queue behind it on `_tail` (`fade_settings.dart:283-286`). A write queued behind Load is refused by the `_lifetime++` in `installSession` (`fade_settings.dart:297`, check at 142). A write queued behind Save applies after the snapshot. Either way, nothing rolls back after the owner accepts a write.
- **Ordinary-edit priority.** It is per address: Default is keyed `null`, and the revision is bumped only after a successful commit (`fade_settings.dart:192`).
- **Inherited-track override creation.** `_with` (`fade_settings.dart:199-218`) creates the override.
- **Lifetime retirement.** `control_cubit.dart:3561-3568` supersedes all 9 Fade addresses when the lifetime changes.
- **`_ownerOriginCurrent` refactor.** All value-target families are disjoint `final`/`sealed` classes (`control_value_target.dart`), and the switch's `_ => true` matches the old fall-through for `null` and `FxBindingTarget`. The refactor preserves behaviour at all four sites (`control_midi.dart:616, 671`; `control_cubit.dart:848, 868`).
- **Provider.** `FadeSettings` is provided at the app root (`app.dart:552`), so `controlAvailability(context)` resolves on every route.
- **Mapping is exact.** `500 + round(clamp(v)*59)*500` equals the catalogue's `round((0.5 + v*29.5)/0.5)*0.5` for v ≥ 0. `fromDomain` is `(ms-500)/29500`, the relative step `1/59` equals `step/(max-min)`, and the readout uses `toStringAsFixed(1)`. No 7-bit or 14-bit MIDI value lands on a .5 rounding tie (59 does not divide 127 or 16383).
- **Repeated defects from #1094-#1096.** None reappear. There is no storage rollback after acceptance. `flush` still throws on `needsRecovery`. Timeouts do not stop audio (FadeSettings has no engine).

## Introduced defects

### 1. A MIDI cleanup release is dropped while FadeSettings needs recovery, and the Held value stays live after Retry (Low-Medium)
- `control_midi.dart:1245-1250`: `_controlValueResolves(cleanup: true)` exempts fixed scopes (ClickMode, CountIn, valid RecordTiming) so that "their rejected release stays owed". Fade targets are also fixed scopes: Default plus 8 slots that resolve even for an empty track (`control_value_resolver.dart:202`). They are not in that list.
- While `needsRecovery` is true, `_footFadeActions.durations` is null (`foot_fade_actions.dart:20`), so the target does not resolve. At `control_midi.dart:660-664` an ending op then calls `_dropMidiHolder` and marks the op accepted. The release is discarded rather than owed, and `prepareShutdown` does not see a `ControlCleanupPending`.
- `FadeSettings.recover()` (`fade_settings.dart:258-273`) does not touch `_live` when `_loaded` is true.
- **Trigger:**
  1. A Fade value is Held via MIDI.
  2. Another Fade write fails storage, and its checkpoint restore also fails (`_persist`, 230-241), so `_repair` stays set.
  3. The device disconnects, or the mapping is retired, before Retry.
- **Impact:**
  - After Retry, `live` keeps the Held duration with no holder left to release it. The next Fade gesture and the readouts use the Held time until an ordinary edit, a new controller write at that address, a Session load or a restart.
  - `confirmed` and storage stay correct, so there is no durable corruption.
  - External is less exposed: `_externalNumericReleases` keeps the owed release and `_retryExternalReleases` writes it later.
- **Smallest fix:** add `target is FadeValueTarget` to the cleanup exemption at `control_midi.dart:1248-1250`, so the release stays owed like the other fixed scopes. Add one dispatch test: hold, force `needsRecovery`, cleanup, Retry, then flush, and assert `live == confirmed`.

## Optional notes
- **Failed install keeps a stale Held value.** `installSession` bumps `_lifetime` before `_persist(incoming)` (`fade_settings.dart:297-299`). If the save fails but the checkpoint restore succeeds, `needsRecovery` is false and `_live` still holds the outgoing Session's Held value, whose release is now refused by the lifetime check. Boot recovery and Retry re-install and clear it, so the impact is minimal. Setting `_live = _confirmed` next to `_lifetime++` would close it in one line.
- **Step can persist a value derived from Held.** `step` derives from `live` (`fade_settings.dart:114-121`). A foot step during a hold therefore persists Held±0.5 s and bumps the revision, so the hold's Release is refused. The PR states this behaviour ("gestures using live"), and the Decay UI does the same, but it is the one path where a value derived from Held reaches storage. Mention it in the doc comment.
- **Momentary holds detach inherited tracks.** A momentary hold on an inherited track permanently creates a Custom override at the Released value. This matches the catalogue (`put` on any write) and Decay, but users may not expect it from a momentary binding.
- **Default edits do not refresh inherited tracks.** A Default ordinary edit emits no `ordinaryChanges` for inherited tracks whose effective value changed, so MIDI pickup and feedback for `trackFadeSeconds/<n>` are not refreshed. Decay behaves the same way.
- **Pre-existing, from #1149: malformed record.** A malformed stored record (`_read`, `fade_settings.dart:93-100`) has no repair path. `recover()` re-reads the same bytes and fails forever, so the Fade targets stay unavailable.
- **Spanish readout.** The `es` readout uses "4.0 s" with a decimal point, which matches the catalogue's `toFixed(1)`.

Verdict: mergeable after the one-line cleanup-exemption fix for finding 1; no other traced defects.
