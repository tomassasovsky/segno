Model: Claude Opus (subagent), in-session

# Review of origin/claude/pitch-time-1179-p4a3 (646fa6511, stacked on 4a-ii): feat(looper): set Follow tempo and Pitch through settings receipts

## Scope

- **The commit:** one commit, `646fa6511`, on top of 4a-ii (`508e2a9e7`). It touches 18 files (+1013/-5).
- **What it adds:**
  - segno_engine: `AudioEngine.setFollowTempo` / `setPitchMode` (native, mock, four fakes); `TempoFollowState` and `PitchMode`; `EngineSnapshot.recordedTempoBpm`, `followTempo`, `tempoFollow` and `pitchMode`; `TrackSnapshot.followTempoOverride`, `pitchModeOverride` and `pitchEffectiveCents`.
  - looper_repository: two `SettingsReceipt` families (`_followTempo`, `_pitchMode`) over a shared `_InheritIntent` and `_sendInherit`; the `LooperState` and `Track` projections; restart replay; session-load reset.
  - Tests: `tempo_follow_settings_test.dart` (fakes) and `tempo_follow_native_test.dart` (the real engine).
- **Reviewed against:**
  - plan Part 4a's Dart seam and the 4a-iii "As built" note;
  - the One Shot settings-receipt precedent;
  - the pen's 07/04-06 (Defaults: Follow On, Pitch Unchanged);
  - AGENTS.md and the owner rules.

## Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | conflicts in `segno_engine_api.h` and the bindings only, inherited from the stack (the trunk's `LE_ERR_NOT_FOUND`/`TRUNCATED` next to `LE_ERR_TRANSFORMED`); a rebase chore |
| `flutter test` packages/segno_engine (SEGNO_ENGINE_LIB from this head) | +382, all passed |
| `flutter test` packages/looper_repository (same lib; includes the native case) | +821, all passed |
| `flutter test` at the app root | +3469 ~56, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues found (after `pub get` in every package of the scratch worktree) |
| `bloc lint lib test packages` | 0 issues, 886 files analysed |
| Native suites | unchanged from 4a-ii (Dart-only commit): plain, ASAN and telemetry-off ALL PASSED x5 |

## Verified correct (traced)

- **Only the diff is sent.**
  - `_sendInherit` reads the published default and the eight overrides from one snapshot.
  - It posts only what differs: the default first, then each track, with null to inherit.
  - A vector the engine already holds sends nothing and is accepted at once.
- **Owed until Retry.**
  - If the first post is refused, nothing is sent and the refusal is returned.
  - If a later post is refused after earlier ones were admitted, the vector is owed (`uncertain`).
  - Once every admitted request has a callback result, the vector is accepted only if all are OK; otherwise it is owed.
  - `recover*` re-requests while running and stages while stopped, the One Shot precedent.
  - The fake test covers the refusal, the failed receipt and the Retry.
- **Replayed on start.**
  - Both families are replayed in the common start path (`looper_repository.dart:2672-2681`), right after One Shot, which also serves `_reopenEngine`.
  - A refused replay rolls the start back through `stopEngine` like every other family.
  - A stopped engine stages the vector, and the next start replays it (tested).
  - This matters because the engine treats Follow and Pitch as material: `le_engine_reset_material` resets them at configure, so a cleared reopen drops them and only the replay restores them.
- **Projection.**
  - `LooperState.defaultFollowTempo`/`defaultPitchMode` and `Track.followTempoOverride`/`pitchModeOverride` are the repository's accepted settings, as for One Shot.
  - `recordedTempoBpm`, `tempoFollow` and `pitchEffectiveCents` are the engine's.
  - The native case drives Follow on, a `followsSpeed` override, a retime to 90 (master 21333, -498 cents), then Unchanged until the stretch lands (0 cents), with the recorded tempo staying 120.
- **Fail-safe decoding.**
  - `TempoFollowState.fromCode` maps an unknown code to `busy` (locked), never to `retimes`.
  - `PitchMode.fromCode` maps anything but 1 to the default.
- **Defaults.** The intent starts at Follow off and Pitch Unchanged, matching 4a's engine defaults (E15). Part 4b flips Follow with the page.
- **Session load.** It clears an owed vector but keeps the settings (labelled). Whether a Session carries them is Part 4b's.

## Findings

### High

None in this commit. The engine findings it exposes are 4a's H1 and M1-M3 and 4a-ii's M1-M2, reviewed there.

### Medium

None.

### Low

**L1. `Track.followTempoOverride` shows the accepted setting while the engine may hold another.**

- **Example:** during an owed vector, the projection shows the intent's previous accepted value, not what the engine applies.
- **Why it matters:** this matches One Shot, but Follow is the one setting whose effect is large (the next tempo change retimes or does not). `tempoFollow` already carries the engine's verdict.
- **Fix:** in Part 4b, show `followTempoRecoveryRequired` beside the setting, so an owed vector is never read as applied.

## Notes

- **Track count.** The literal `8` for the track count follows the file's existing One Shot code (`looper_repository.dart:7915-7964`).
- **Retry API.** `settleFollowTempo` and `settlePitchMode` are `Future`s, and `recover*` returns synchronously; the same shape as One Shot.

Verdict: Approve.

## Delta review (32922f796)

Model: Claude Opus (subagent), in-session

### Scope

A rebase only: `git range-diff 646fa6511^! 32922f796^!` reports the commit identical (`=`). It now sits on 4a-ii's `5d5318fb7` and trunk `890f04936`.

### Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | clean |
| `flutter test` packages/segno_engine (SEGNO_ENGINE_LIB from this head) | +383, all passed |
| `flutter test` packages/looper_repository (same lib) | +829, all passed |
| App suite, `dart analyze`, `bloc lint` | see the 4b review; 4b's head contains this commit unchanged |

### Findings

None. The earlier L1 (the projection showing an owed vector as applied) is addressed by 4b: `PlaybackOptions` projects null while the owner is not ready.

Verdict: Approve.
