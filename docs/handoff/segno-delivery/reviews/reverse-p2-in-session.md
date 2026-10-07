Model: Claude Opus (subagent), in-session

# Review of origin/claude/reverse-1162-p2 (5a9803915): save and recall a track's playback direction (#1162 Part 2)

## Scope

- **Branch:** `origin/claude/reverse-1162-p2` at `5a9803915`, one commit on trunk `68ed3f957`; 14 files, +300/-3.
- **Reviewed against:**
  - `docs/plan/2026-10-05-feat-foot-reverse-plan.md` (section 2, Part 2 and "Part 2 as built");
  - AGENTS.md;
  - the owner rules.
- **Covered:**
  - schema 13 and the strict `SessionTrack.reversed` decode;
  - capture in `SessionRepository.save`;
  - `rigFromBundle` → `SessionRigTrack.reversed`;
  - recall via `installReverse` in `_importSessionAudio`, and the commit check;
  - the native `test_reverse_reopen_keeps_direction`.
- **Also traced, though landed by Part 1:**
  - the reopen and material-reset native code (`le_engine_reset_material`, `le_engine_reset_runtime`, `le_engine_reopen_settle`, `le_reopen_drop_track` → `le_transform_reset`);
  - `LE_CMD_REVERSE` install acceptance;
  - `LE_CMD_COMMIT_SESSION`;
  - the arm-time direction fact and `perf_render.c`.
- **Schema:** I judged only the schema number and the shape of the bump, per the brief. Peel P2 (#1194) takes 12; the migration chain is #1196.

## Runs

All runs used my own worktree at `5a9803915`, with a fresh TMPDIR per native run.

| Run | Result |
|---|---|
| Native plain | ALL PASSED x5, rc 0 |
| Native ASAN (`-fsanitize=address -g`) | ALL PASSED x5, rc 0 |
| Native `-DLE_CALLBACK_TELEMETRY=0` | ALL PASSED x5, rc 0 |
| App `flutter test` | +3339 ~49, all passed |
| `packages/looper_repository` (with `SEGNO_ENGINE_LIB` from `build_test_lib.sh`) | +806, all passed; both new `reverse_native_test` cases ran, none skipped |
| `packages/session_repository` | +126, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues found |
| `bloc lint lib test packages` | 0 issues |

`test_reverse_reopen_keeps_direction` ran in all three native builds.

### Composition

- The branch merges cleanly into the current trunk `56033baf0` and with Part 3 `c6a101a7b`.
- On a trunk + P3 + P2 merge commit:
  - analyze and bloc lint are clean;
  - the app suite passed (+3372 ~49);
  - looper_repository passed (+807);
  - session_repository passed (+126).

### Mutations and probes

All of these ran in a separate probe worktree.

1. **No install loop.** Skipping the `installReverse` loop makes the actual-native recall test fail with "session import commit was refused" (the commit check fires). Killed.
2. **No install loop and no commit check.** The recall test fails on the expected samples. Killed.
3. **Commit check removed only.** Removing `actual.reversed == track.reversed` leaves every test passing. Survived (Low 3).
4. **Reopen resets direction.** Resetting `reversed`/`a_reversed` in `le_engine_reset_runtime` makes `test_reverse_reopen_keeps_direction` fail on `snap.reversed == 1` and on the `len-1` samples. Killed.
5. **Recall failure probes.** Four probe tests in `session_import_publication_test.dart`, against the actual native engine. All four passed, so the behaviour is correct but the branch does not test it (Low 1):
   - a refused second install: the load throws, nothing commits, all tracks EMPTY and forward, and a following forward or reversed recall is exact;
   - `stopEngine` while the install receipt is held: the next load's track is forward;
   - a newer `applySession` superseding while the install is held: the second rig wins and reads forward, with the second rig's PCM;
   - a receipt timeout: the load throws, nothing commits, and the next load is forward.
6. **Native probes** in `test_engine_reverse.h`:
   - **Reversed take dropped by reopen.** A reversed take still in its trailing seam fold (`seam_capture > 0`) is dropped by a retained reopen and comes back EMPTY and forward. This passed (Low 2).
   - **Recalled reversed track, armed while playing.** It renders reversed in the stem sample-exactly across the wrap: 1500 frames, 0 mismatches.
   - **Recalled or reopened reversed track, stopped at arm, played later.** The stem reads backward from `len-1` (999, 998, …). It is offset from the live output by the time spent stopped. The forward control case (`probe_recalled_forward_renders`) shows the identical offset, so this is a property of my minimal arm manifest and the renderer, not of direction. See Notes.

## Verified correct (traced)

- **Schema shape.**
  - `formatVersion` 11 → 13 is a single constant.
  - `Session.fromJson` still rejects any `version != formatVersion` before side effects.
  - `SessionTrack.fromJson` requires `reversed is bool` and rejects a missing value, `null`, `0`, `1`, `'true'` or other strings.
  - The field is serialized and is part of `==` and `hashCode`.
  - No legacy decode was added, as AGENTS.md requires.
- **Capture.**
  - `session_repository.dart:711` reads `track.reversed` from the same detached snapshot track as `fadeAmount`.
  - The fake engine exposes `reversed`.
  - A saved bundle round-trips `[true, false]`.
- **Recall order** in `_importSessionAudio`:
  1. imports;
  2. finalize, then wait for `commandsSettled`;
  3. Fade installs;
  4. Reverse installs, only for reversed tracks (the imported material is already forward, because Clear and finalize run `le_transform_reset`);
  5. `commitSession`;
  6. the settle check.
  - `requireCurrent()` brackets each install.
  - A refused install throws `StateError`. The existing catch clears every rig track, which resets direction through `le_transform_reset`, or stops the engine.
  - A superseded load does not clean up, but the next load's Clear sits behind the stale install in the FIFO command ring, so it resets direction. Probe 5 confirms this.
- **Native install on imported EMPTY material.** `LE_CMD_REVERSE` with `install` accepts the imported EMPTY track that has a length (`engine_process.c`, the `accepted` expression). `LE_CMD_COMMIT_SESSION` then calls `le_reset_track_playback`, which parks the origin, so Play reads `len-1` first. The Dart actual-native test checks the first three summed samples exactly.
- **Retained reopen** keeps `tr->reversed` and `a_reversed`, which only `le_engine_reset_material` touches. `le_engine_reset_runtime` clears only the turn window, the in-flight counters and `playback_offset`, so the origin is parked. A dropped take resets direction through `le_reopen_drop_track` → `le_transform_reset` (probe 6).
- **Lifetime.** The new actual-native test proves that undo to empty, redo from empty, Clear and Clear Undo all read forward through `Track.reversed`.
- **New Loop.** There is no New Loop symbol in `lib` or the repositories. The reset is inherited through Clear and material resets, as the plan says.
- **Stems.** Session load disarms the performance capture first (`session_cubit.dart:22`). A reversed recalled track therefore enters a capture only through the arm-time fact: `LE_CMD_PERF_ARM` logs `LE_PLOG_REVERSE` with the exact read index for every reversed track. `perf_render.c` replays it, so a recalled reversed track renders reversed (probe 6).
- **Session files** store the forward PCM plus the flag. Nothing pre-renders the reverse into the saved stems, so a recall followed by a toggle back to forward is exact.

## Findings

### Low 1. The recall failure paths for Reverse have no test

**Where:** `packages/looper_repository/lib/src/looper_repository.dart:4401-4414`.

**What is missing.** Fade's install has three such tests in `session_import_publication_test.dart`: a refusal that clears a partial vector, retirement during install, and a timed-out install. Reverse has none. Its only recall test is the success path in `reverse_native_test.dart`.

**Why it matters.** The behaviour is correct today (probe 5), but nothing pins it. The looper_repository `FakeAudioEngine` makes it worse: `installReverse` returns `invalid` unconditionally (`test/helpers/fake_audio_engine.dart:202-205`), so any future fake-engine recall test with a reversed track fails the load for a reason unrelated to the test.

**Suggested fix.** Add the four probes as tests. Their shape is in this review's runs (`refusedReverseChannel`, `holdReverse` and `reversePosted` hooks on `_ImportEngine`, and a `reversed` set on `_rig`).

### Low 2. The reopen test's comment claims a case it does not assert

**Where:** `packages/segno_engine/src/test/test_engine_reverse.h:819-822`.

**What is wrong.** The comment says "A reversed take that a reopen drops comes back EMPTY and forward". The test body only covers the retained, playing track. The plan's Part 2 criterion also says "a dropped take comes back forward".

**Status.** The behaviour holds: probe 6 reverses a take inside its trailing seam fold, reopens, and gets EMPTY with `reversed == 0`.

**Suggested fix.** Add that probe as the second half of the test.

### Low 3. The direction clause of the commit check is never exercised

**Where:** `looper_repository.dart:4438`.

**What happens.** Removing `actual.reversed == track.reversed` passes the whole suite (mutation 3). The other clauses of the check do have coverage.

**Why it is only Low.** It is defence in depth. With the install receipt already confirmed, nothing between the receipt and the commit can flip direction except a material reset, which the length and state clauses would also catch.

**Suggested fix.** Add one test in which the fake or actual engine publishes a forward track despite an OK receipt, and assert that the load fails and the rig is cleared.

### Low 4. `SessionRigTrack.reversed` defaults to false instead of being required

**Where:** `packages/looper_repository/lib/src/models/session_rig.dart:78`.

**What happens.** `fadeAmount` beside it is `required`. With an optional default, any future rig builder that forgets direction compiles and silently recalls forward. Today `session_mapping.dart` is the only production builder.

**Suggested fix.** Make it `required`, which touches the test rigs, consistent with `SessionTrack.reversed`.

### Low 5. Stale schema text

- The plan's sections 2, Part 2 and decision 7 (`docs/plan/2026-10-05-feat-foot-reverse-plan.md:297, 441, 540`) still say schema 12, or 11 → 12. Only the new "as built" note says 13.
- `Session.formatVersion`'s doc comment (`session.dart:859`) still reads "stores per-track settings and all FX stages" and does not mention direction.
- **Suggested fix:** update both, or point them at the as-built note.

## Schema number and bump shape

- **Number.** 13 is right if Peel P2 lands first with 12, as stated. If Reverse P2 lands first, it must take 12 and Peel must take 13. Whichever lands second has to rebase both the constant and `session_test.dart`, which asserts the literal `13` twice: "the schema that carries direction is version 13" and "serializes the manifest version (v13)".
- **Shape.** A single constant bump with a strict required field is consistent with v11 (Fade) and with AGENTS.md's no-legacy-decode rule.
- **The 12 → 13 migration default must be `reversed: false` for every track.**
  - Before v13 no Session could record direction. Part 1's runtime Reverse was not saved, so every v12-or-earlier file has always recalled forward.
  - `false` therefore reproduces exactly what those files load as today (owner rules 1 and 3).
  - The default belongs in the #1196 migration step, keyed on the file's version. The v13 decoder should stay strict: it should not treat a missing key as false.
- **Sequencing (rule 1).**
  - Until #1196 lands, any build carrying this bump refuses every saved v11 or v12 Session.
  - `SessionUnsupportedVersion` maps to `sessionErrorUnsupportedVersion`, whose copy says the file was saved by a *newer* Segno and asks the player to update. That is wrong for an older file.
  - This behaviour predates this branch (every bump has it), but this branch should not reach the appliance ahead of #1196's 11 → 12 → 13 chain.

## Notes

- **Stems for a track stopped at arm.** For a track that is stopped when the capture arms and played later, the stem with a minimal `armSnapshot` manifest plays the loop from the arm frame rather than from the Play frame. This happens identically for forward and reversed tracks, so it is a renderer or manifest property outside this branch. A real manifest carries the arm snapshot's track state, which my probe omitted. The direction-specific claim, that a recalled reversed track renders reversed with the arm-logged index, holds.
- **Session recall keeps the direction but not the origin.** Play starts at `len-1`. This is the plan's default, and it is one of the three open product questions it flags.
- **`installReverse` reuses the shared receipt table.** A stale receipt is drained by `_drainReceipts` on the next admission, as Fade's are.

Verdict: Approve (Low items only; land after Peel P2 takes 12, and keep it off the appliance until #1196 migrates v11/v12 Sessions with `reversed: false`)
