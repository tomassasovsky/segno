Model: Claude Opus (subagent), in-session

# Review of origin/claude/multiply-divide-1168-p2 (5b1b9f527): feat(session): save and recall length edits with their own image lengths

## Scope

- Commit `5b1b9f527`, stacked on #1212 at `1baf012b1`. This review covers `git diff 1baf012b1 5b1b9f527`: 29 files, +1220/-206.
- Reviewed against:
  - the plan's Part 2 section and its build notes;
  - accepted behaviour section 2.10 and section 6.9-6.10 (recall restores audio, layers and history; recovery keeps Undo/Redo dependencies and established spans);
  - AGENTS.md;
  - the owner rules.
- Part 2 has no UI, so pen section 16 does not apply.

## Runs

All runs were made in a fresh worktree at `5b1b9f527`.

| Run | Result |
|---|---|
| `run_native_tests.sh`, 3 runs, separate TMPDIR each | ALL PASSED x3. The new tests ran: `test_length_session_round_trip`, `test_length_finalize_lineage`, `test_length_division_recall` and `test_reopen_keeps_length_history`. |
| TSAN races binary | exit 0 |
| segno_engine | +388, all passed |
| looper_repository | +811, all passed, including the actual-native round trip in `length_native_test` |
| session_repository | +193, all passed |
| App suite, after `flutter gen-l10n` | +3321, ~202 skipped, 2 failed: `fx_chain_persistence_test:229` and `monitor_cubit_test:2318`. |

On the two app failures:
- Neither file is touched by this PR.
- Both pass 3 out of 3 when re-run alone on this head.
- The full run took 12:41, against 4:47 on P1, while the machine was loaded. I read them as timing flakes, not regressions.

## Verified correct (traced)

- **The lineage rule is one rule in three places.** `le_hist_len_at` (export), `le_engine_finalize_history` and `TrackHistory.lengthMalformation` (Dart) agree: an image is as long as the nearest LENGTH entry at or nearer live on its stack names, else as long as live. I hand-traced it on both stacks:
  1. Record, overdub, Double and overdub give `[B0, LEN(B1, L), D]`, with D1 live.
  2. Undo three times gives redo `[D1, LEN(D, 2L), B1]`, with B0 live.
  3. Export reports 2L, 2L and L for the redo images. Finalize's walk outward from live accepts exactly those and nothing else.
  - `test_length_finalize_lineage` refuses a wrong undo-side layer, a wrong redo-side layer, a map on a layer, a map beyond the cap, a wrong image count, NULL arrays and a short staged slot. Every one of these refuses before anything is published.
- **Export.**
  - `export_history` gains `starts[]`.
  - `export_layer` with `max_frames` 0 is a size query that returns the image's own length, and it still refuses a slot shorter than its entry.
  - `NativeAudioEngine.exportLayer` sizes each ordinal through that query.
- **Save is coherent.**
  - `SessionRepository.save` waits for `commandsSettled`.
  - `_capture` then reads `snapshot()`, which drains and runs `le_length_collect`, before `exportHistory`.
  - So an applied edit is always filed before it is exported. A save can never pair the new live image with a stack that lacks its LENGTH entry, which would have broken the lineage.
- **Read refuses before any side effect.**
  - `SessionRepository.read` checks every lane's WAV lengths against its lineage, and checks that the lanes of one track carry identical lengths, before the bundle is returned.
  - This throws `SessionCorruptLayers`; the session_repository tests cover it.
  - `fromJson` already requires identical histories across lanes.
- **Finalize.**
  - It files LENGTH entries with their `len` and `start` (negative values allowed, bounded by ±`max_loop_frames`).
  - It publishes the live length on every lane through `le_track_set_len`.
  - It checks `pool_cap[s] >= lens[s]` for each image and each lane.
  - `import_layer`'s `a_len` is now only the "staged" marker; finalize overrides it.
- **Division recall.** `LE_CMD_COMMIT_SESSION` now runs `le_restore_multiple_or_divisor`. `test_length_division_recall` shows a saved 8-of-16 Sync track recalls as divisor 2 and plays phase-locked for two primary cycles. The saved base is `snapshot.masterLengthFrames`, which is the same base the length verdict uses.
- **Round trip.** Double, Last half and Undo are saved and recalled. The stacks come back with their lengths and maps, and Redo of the half continues at `(3 - 8) mod 8` in the kept half. An odd 7-frame Last half (start 3) also survives the round trip and keeps the playhead's phase.
- **Reopen.**
  - A retained track keeps both stacks byte-identical, and Redo and Undo still restore the lengths and the master.
  - An edit posted but not applied at the loss drops only its track: mask 0x2, `length_pending` and the pin cleared, and the sibling untouched.
  - After the reopen, the dropped track records again.

## Findings

### Medium

**P2-M1. Schema 13 with no migration step: on this branch, every saved schema-12 session becomes unreadable.**
- Where: session.dart:857 sets `formatVersion = 13`, and :763 refuses any `version != formatVersion`.
- Neither this branch nor `origin/claude/segno-integration` has `sessionMigrationSteps`. The #1196 chain is still open as PR #1211.
- Effect: if this PR merges into the trunk before #1211, every session saved by the current trunk (schema 12, which Peel P2 already shipped to the integration line) is refused on open. The refusal is fail-safe, but the user loses access to their saved work. That breaks owner rule 1 (preserve installs).
- The builder records this as a landing step: the identity step plus the converted fixture.
- Suggested fix: hold the merge behind #1211, rebase onto it, and add the identity step for this schema number with the chain fixture in this PR.

### Low

**P2-L1. Commit still turns any live length below base into divisor 2.**
- Where: engine_process.c, the commit loop through `le_restore_multiple_or_divisor`. That function picks n = 4 only when `len * 4 == base`, and n = 2 otherwise.
- Effect: a bundle whose live length is below base but not exactly base/2 or base/4 is recalled as a division. Possible causes are a hand-edited manifest or a base and layer that drifted apart. The mixer's read `lbuf[seg_base + trk_pos]` is unbounded, so a length below base/2 reads past its slot on the audio thread.
- This is narrower than before: the old k = 1 path read up to `base` for any length below base. But it is still open.
- Suggested fix: refuse such a live length in `SessionRepository.read`, alongside the lineage check, and defensively in the commit. A live length must be a whole multiple of `baseLengthFrames` or exactly base/2 or base/4.

**P2-L2. A torn image saves as an empty WAV instead of failing the save.**
- Where: native_audio_engine.dart, `exportLayer`.
- The size query returns `LE_ERR_INVALID` for a slot shorter than its entry, and `if (frames <= 0) return Float32List(0)` turns that into an empty layer.
- Effect: the save succeeds, and the next read refuses the whole bundle on lineage.
- Suggested fix: throw when the result is negative, so the save fails at capture.

**P2-L3. Stale field comment.**
- Where: session.dart:251. `SessionTrack.lengthFrames` is still documented as "`multiple` × the base length".
- A saved division has `multiple` 1 and `lengthFrames` = base/2. The recall never reads this field, so only the comment is wrong.

## Notes

- **Deviations from the plan text.** Judged acceptable:
  - `starts[]` instead of `lens[]` in `export_history`: the lengths come from the images, and the map cannot be derived from them;
  - finalize takes `lens` plus the image count instead of `live_len`;
  - the lineage is checked in `read` rather than in `fromJson`: lengths live in the WAVs, and the check still precedes every side effect;
  - Session entries take the form `{kind, skipped, start}`.
- **Free/Song.** Session import is still declined by the commit. This is an existing gap and a stated non-goal, so length edits made in Free/Song cannot round-trip yet.
- **Inherited from P1.** The M2 owner question in the P1 delta (whole-beat sub-bar loops) also changes what a recalled sole track may be. A Session saving a 2-beat loop would need the beat-grid field.

## Verdict

Request changes. The one blocking item is P2-M1: land after #1211 with the identity migration step and fixture. The code itself is sound and well tested.

## Delta review (5eb8517d3, PR #1244)

### Scope

- Head `5eb8517d3` merges P1 (`be963fd81`: the beat grid, and a trunk at schema 13 that carries the #1196 migration chain) into P2. On top of the merge it adds:
  - schema 14 with `_v13ToV14`;
  - the `v14_length_1168` fixture;
  - `loopBeats` in the Session;
  - the L1, L2 and L3 fixes.
- This delta covers `git diff be963fd81 5eb8517d3`, restricted to the P2 files.

### Runs

All runs were made in a fresh worktree at `5eb8517d3`.

| Run | Result |
|---|---|
| `run_native_tests.sh`, 3 runs, separate TMPDIR each | ALL PASSED x3 |
| TSAN races binary | exit 0 |
| segno_engine | +389, all passed |
| looper_repository | +821, all passed |
| session_repository | +252, all passed, including the migration chain over every fixture from v1 to v14 |
| App suite, after `flutter gen-l10n` | +3465, ~56 skipped, all passed |

### P2-M1 (schema without a migration step): fixed

- `sessionMigrationSteps` now chains `13: _v13ToV14`. The step sets `loopBeats = loopBars * tsNum` and records a note. That is correct, since every pre-14 grid was whole bars.
- `Session.fromJson` requires `loopBeats` at 14.
- `read` refuses a manifest whose `loopBars` disagrees with its beats: it must equal `beats / tsNum` when whole, else 0.
- Save writes the snapshot's beats when running, else the settings' beats.
- Recall passes `rig.gridBeats` to the commit.
- The v14 fixture holds two length edits and a 2-beat grid. The chain test opens v13 and v14 and checks the per-image lengths.
- A schema-13 install now converts on open with a notice, instead of being refused.

### L1: live length rule ("a whole multiple, or exactly base/2 or base/4")

The rule is applied in two places:
- `SessionRepository.read`, for Multi, Sync and Band (Free and Song keep independent lengths, and their commit is still declined);
- `le_engine_commit_session`, before posting, for every staged track, through `le_session_length_fits`.

The commit handler also skips such a track as a backstop.

**Judgement.** The rule is right for Sync and Band, and it closes the audio-thread over-read: every length it admits is either `k * base` (read within `k * base`) or an exact division (read within `base/n == len`).
- It is also stricter than the old floor-to-k recall for a non-exact multiple.
- I checked every shipped fixture against it. All pass, including `v7_master_full`, whose third track is 1200 frames on a 2400 base: a Sync half that the old k = 1 recall read past.
- So no fixture regresses, and that v7 session is now recalled correctly.

It deviates where your brief would be stricter, and I agree the brief is right there: in Multi, base/2 and base/4 should be refused.
- Multi admits only whole multiples (accepted behaviour section 2.9: "Multi requires equal spans").
- No live Multi rig can produce a division: Divide refuses a half-base with siblings, and a sole track re-clocks.
- But this rule lets a corrupt or hand-edited Multi bundle recall as a Sync division inside Multi. The read stays in bounds, so it is not a memory-safety risk; it is a mode-invariant break.

**L1-a (Low).** Pass the mode in:
- `read`: `looperMode == multi ? live % base == 0 : <current rule>`;
- the commit wrapper: refuse a division unless `a_looper_mode` is SYNC or BAND.

**Note.** The handler's `continue` backstop leaves a raw-posted track EMPTY with a staged nonzero `a_len`, the pair the host's depths-sane check rejects. It is reachable only through `le_engine_post_command`, which the wrapper now guards, so this is acceptable.

### L2 and L3: fixed

- **L2.** `exportLayer` throws a `StateError` naming the ordinal, track and lane when the size query returns a negative code. The save then fails at capture, instead of writing an empty WAV that the next read refuses.
- **L3.** The `SessionTrack.multiple` and `lengthFrames` comments now cover divisions, and say the recall takes each length from the WAV.

### Verdict (delta 5eb8517d3)

Approve. L1-a, making Multi refuse divisions on recall, is a recommended follow-up, not a blocker.
