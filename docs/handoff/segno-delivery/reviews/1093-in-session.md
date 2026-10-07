Model: Claude Opus (subagent), in-session
Base: 06633b2b537efba4c59108e38764e58c0b2c542e (claude/midi-formats-1026)
Head: 42e5e849ec21bc5cd6a6feae0251a96923556ba7 (codex/shared-mixer-control-catalogue)

# PR #1093 review: shared Mixer control targets

Read-only. Read AGENTS.md and docs/plan/2026-10-01-shared-mixer-controls.md at head. I traced the production diff (lib/, packages/controller_repository/lib) against the base. Nothing was built or run.

## Introduced defects

### 1. A topology change on one Mixer target cancels a whole MIDI proposal after FX was already applied, leaving the FX value latched (medium)
- `lib/control/cubit/control_midi.dart:657-661` adds `!_mixOriginsCurrent(origins)` to `cancelled()`. `origins` covers every Mixer target in the proposal.
- Line 666 applies FX through `writeExternalFx`. Line 672 awaits `settleFxRecipes(cancelled: cancelled)`. Lines 676 and 754 return before `recordAccepted()` (694/755) and `_midiEngine.settle` (696/757).
- Trigger: a momentary note mapping with {FX param P, InputPan(2)}. Press the note. While the FX settle awaits its callback, link inputs 2/3 in the Mixer. Ordinary submits are not blocked, because the controller is not yet inside `runExclusive`. `_syncControllerTopology` bumps InputPan(2) and `cancelled()` becomes true.
- Impact: P is audibly at its held value, but it was never recorded or settled. The engine treats the row as refused, so it emits no release ("refused press never creates a held action or release"). P stays latched until the next press/release cycle. The plan says the opposite: "Unrelated topology changes do not cancel work for surviving owners."
- Same shape at ingress, line 381: `if (!_mixOriginsCurrent(origins[event]!)) continue;` drops the whole MIDI event, including a note-off, so `prepare` never sees the release for the mapping's non-Mixer rows.
- Smallest fix: keep `cancelled()` for session and close only. Filter out the operations whose own origin changed (`invalidateTargets` already forgets those rows), and never skip `prepare` at ingress.

### 2. TrackVolume endpoints silently change audible gain for pedal setups already on master (medium, accepted-behaviour change)
- On master, `TrackVolumeTarget` is offered to External expression mappings (`control_value_resolver.dart` on master, line 69) and writes linear gain (`setVolume(clamped)`).
- Head `control_value_target.dart:158` (`toDomain`) now routes TrackVolume through the log fader law. A saved mapping with toe=1.0 changes from 0 dB to +6.02 dB, and its midpoint from -6 dB to -27 dB, with no migration.
- New mappings have the same issue. The defaults `ExpressionMapping(toe = 1)` (`external_expression.dart:54`) and MIDI `high: 1` (`midi_controls_page.dart:918`) put every new volume assignment at +6 dB at full travel.
- The plan describes the target as "still-unmerged", but that is only true of the MIDI path. The tests were rewritten through `fromDomain` to keep their old physical expectations, so they hide the change.
- Smallest fix: AGENTS.md rules out migrations, so state the change in the PR body for the owner's acceptance. Make the default high/toe for gain targets `fromDomain(1)` (unity).

### 3. Gain law and target projections duplicated across files: the repeated `||` chains the owner has objected to (low)
- `mix_settings_coordinator.dart:299` `_readValue` is a copy of `control_value_resolver.dart:156` `_readMixValue`.
- The `TrackVolume || LaneVolume || MonitorVolume` / pan-group chains are repeated in `toDomain`, `fromDomain` and `relativeStep` (`control_value_target.dart:158/173/185`). They appear again in `control_value_readout.dart:12-21`, which also casts with `as MixValueTarget`.
- `_commit` (`mix_settings_coordinator.dart`, release filter) re-implements part of `valueTargetResolves` against the candidate.
- `mix_value_scale.dart:6,9` redefines `kMeterFloorDb` and `kSignalMaxGain`, and leaves `kSignalMaxGain` dead.
- Smallest fix: give `MixValueTarget` one `read(snapshot)` and one `write(snapshot, v)` and use them in both places. Put the scale on the subtype, as a `gain`/`placement`/`linear` scale field, instead of grouping by `||`. Reuse the existing constants.

### 4. Getter with side effects creates hidden SessionCubit → coordinator → ControlCubit calls (low)
- `durableSnapshot` (`mix_settings_coordinator.dart:190`), `_submit` (`final _ = durableSnapshot;`, line 359) and `controllerOrigins` all run `_syncControllerTopology`. That method calls `onInvalidatedValues` (line 186) synchronously.
- So `SessionCubit.save` (`session_cubit.dart:212,214`) and every Mixer UI submit can make ControlCubit drop holders and emit (`_resetMidiDecoders` → `_publishMidi`) in the middle of their own call stack.
- `lib/app/mix_settings_coordinator.dart:4-5` now imports the control feature's binding model and resolver. The app-level mix owner now depends on the feature that depends on it.
- Smallest fix: sync only from the `looperState` subscription (line 112) and admission. Make `durableSnapshot` pure. Move `MixValueTarget` and the scale next to the mix model, or into a package both features import.

### 5. Any Mixer-target invalidation resets every MIDI decoder and every expression baseline (low)
- `_invalidateMixTargets` (`control_midi.dart:894-914`) runs `_expressionRaw.clear()` and `_resetMidiDecoders()` on every removal, for example on linking a pair.
- An unrelated half-received 14-bit/NRPN message is dropped, and the next reading of every expression pedal is swallowed as a new baseline.
- Smallest fix: reset only the jacks and devices whose mappings contain the invalidated keys.

### 6. MonitorVolume is offered as a Mixer target with no ordinary surface (low, design)
- `control_value_resolver.dart:100` offers `MonitorVolumeTarget` for every input. At head, nothing in `lib/` displays or edits monitor gain: `MonitorCubit.setVolume` has no caller outside tests.
- A controller can persist monitor gain at 0 or at +6 dB, with no Mixer control to see it, reset it, or establish "ordinary-edit priority".
- Fix: drop the target until the Mixer surface exists (AGENTS.md "grow in layers"), or confirm it against the pen.

## Preexisting debt (extended here, not introduced)
- Each controller value runs a full exclusive durable commit (persistence read and write, plus native settle) per MIDI message, with no coalescing. While a commit runs, Mixer UI edits are refused as `superseded`. This was true of TrackVolume before and now covers 8 target kinds.
- `onOrdinaryValues` and `onInvalidatedValues` are single-slot mutable callbacks on a shared object. A second ControlCubit overwrites them, and closing it nulls them for the live one.
- `_externalInvalidatedMix` is never cleared on session change (`control_cubit.dart` `_retireExternal`). It only grows. I found no harmful trigger.

## Optional tests
- A MIDI mapping {FX, InputPan} with a pair link during the FX settle: expect P to release (would catch #1).
- Dispatch tests build endpoints with `fromDomain` and assert the physical value, which is a round-trip oracle. The literal-vector test in `control_value_target_test.dart` is independent. Add the same literal vectors (0.5 → 0.0447, 0.9088 → 1.0) to one MIDI and one External dispatch test.

## Nits
- `binding_labels.dart:31`: the change from 0-based to 1-based lane numbering is a correct fix, but it is unrelated scope in a 73-file PR.
- `control_value_readout.dart:3` imports a looper view file (`input_setup_tab.dart`) into the control view.
- The `mix` parameter of `chainsFromLooper` and `settingsFromLooper` is optional and falls back to the live, unprojected snapshot. Make it required.
- `availableMixValueTargets()` and the set diff run on every `looperState` emission.

Verdict: request changes (one medium correctness defect, one unannounced audible behaviour change).
