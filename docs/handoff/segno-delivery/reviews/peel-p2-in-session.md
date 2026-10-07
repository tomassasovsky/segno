Model: Claude Opus (subagent), in-session

# PR #1194: feat(session): persist audio history kinds so Peel survives save and recall

Branch `claude/peel-1164-p2` at 15ec99e6d, reviewed as
`git diff 1587909c2..origin/claude/peel-1164-p2` (Part 1 at 1587909c2 is in the
trunk). The PR targets `claude/segno-integration`, which is now at 31aab2fdc.
Plan: `docs/plan/2026-10-05-feat-foot-peel-plan.md` §1.2, §2, Part 2. This PR
closes finding 2 of the #1180 review.

## What I ran

| Check | Result |
| --- | --- |
| `run_native_tests.sh`, plain, own `TMPDIR` | ALL PASSED |
| `run_native_tests.sh`, `EXTRA_CFLAGS="-fsanitize=address -g"`, own `TMPDIR` | ALL PASSED, no ASAN reports |
| `leaks --atExit` on `segno_core_tests.exe` with `SEGNO_PEEL_TESTS_ONLY=1` | 0 leaks, 0 bytes (the #1173 640 B leak from the Part 1 review is gone) |
| `build_test_lib.sh`, `SEGNO_ENGINE_LIB` exported: `packages/session_repository` | 123 passed |
| same: `packages/looper_repository` (`peel_native_test.dart` runs, not skipped) | 803 passed |
| same: root `test/session` (after `flutter gen-l10n` in the fresh worktree) | 134 passed |
| Local merge of the PR into trunk 31aab2fdc (one conflict, resolved by keeping both sides): native plain, session_repository, looper_repository, root `test/session` | ALL PASSED; 129 / 805 / 136 passed |
| 6 mutations (below) | 5 caught, 1 survived (finding 1) |
| 4 probes in a local test header (below) | 1 defect window reproduced (finding 1); the rest confirm correctness |

Nothing was committed, pushed or posted. The probes and the merge lived only in
my worktree and were removed afterwards.

## Verified correct

- **Schema 11 never shipped, so 11 → 12 with current-schema decode strands no
  real Session.**
  - `origin/master` (bedcecf27) is at `formatVersion = 7`, and its decode
    accepts any version up to 7.
  - On the trunk, v8 first appears at 919e337d2 (2026-09-10), v10 brings the
    current-only decode at a921bd9a9, and v11 arrives at 19a6faa8d (2026-10-05).
    `git merge-base --is-ancestor` says none of the v8–v11 commits is in
    `origin/master`.
  - The last successful `appliance-release` run is #142, built from master
    bedcecf27 on 2026-09-19. The two runs from the integration branch (#143 and
    #144 on 2026-10-06) were both cancelled. The last `appliance-profile-bundle`
    run was on 2026-09-05.
  - So no appliance holds a v8–v12 bundle. A v11 file can only come from a
    dev-host run of the trunk during the last day.
  - No other remote branch claims 12. I scanned every `origin/*` branch: all are
    at 11 except this one, and the Reverse Session part has not been written yet.
  - No other code reads the session version. The Fade-level and Fade-duration
    fields of v10/v11 round-trip unchanged. Settings use their own storage
    (`control_midi.dart` has its own `version: 1`).
  - The pre-existing v7 issue is a separate note below.
- **Slot assignment in `le_engine_finalize_history` mirrors
  `le_layer_slot_for_ordinal` and `le_engine_export_history`.**
  - Undo entries take images `0..u-1` and the live image takes `u`.
  - Redo entries follow in export order (top-down). Each image-bearing entry
    takes the next image, and a PEEL marker takes slot -1.
  - Mutation M1 (give a marker an image) and mutation M4 (export the redo side
    bottom-up) are both caught.
- **A marker's slot -1 never reaches array indexing.**
  - Outside `track_select_slot`'s `used` scan, the only code that reads a redo
    slot is the redo-from-empty branch (`engine_commands.c:2591`).
  - That branch needs EMPTY with `empty_len > 0`. Finalize sets `empty_len = 0`,
    and commit makes the track STOPPED.
  - Undo-to-empty always files a LAYER on top of the redo stack.
- **A redo-side CLEAR "with an image of its own" is sound with
  `le_restore_clear`'s design.**
  - In the live engine, `le_restore_clear` pushes the CLEAR entry whole and
    publishes `e.slot` live. So the redo-side CLEAR names the slot that was live
    at restore time: it aliases a slot rather than owning one.
  - Redoing it calls `le_clear_track`, which builds a new restore point from
    `a_live` and drops the redo branch. `le_engine_history_mode_gate` and
    `le_engine_redo_reclears` read only `kind`. Nothing reads the redo entry's
    slot or payload.
  - On reload the entry therefore needs no payload. Its own slot holds a
    duplicate image that is never read, and the slot is freed by the next edit.
  - Pool cap, probe P1: 300 passes, then Clear and Undo, gives undo 253 (two
    outstanding shadows pin two slots), 255 images ≤ 256, and every ordinal
    exports. The duplicate image cannot push a reachable history past
    `LE_POOL_SLOTS`.
  - Probe P2: Peel, Clear, Undo (restore), Undo (undo the peel), then save and
    recall. The sequence redo, redo, undo, undo, undo gives
    `1.5, EMPTY, 1.5, 2.0, 1.5` on both the live engine and the recalled one.
- **`a_peel_depth` publication.** Finalize stores `le_peel_depth(t)`, which the
  PR now shares through `engine_core.h`, so the rebuilt PEEL and PROCESSED
  entries publish the right depth. Mutation M2 (store `undo_count`) is caught.
  The undo and redo depths are raw counts, which is what the repository's
  post-commit check compares (`undoDepth == undoCount`, `redoDepth == entries`).
- **Multi-lane.** The torn check walks `images` slots on every active lane at
  one `a_len`, and the live image is published on every lane. The strict test
  covers a 2-lane torn length and a 2-lane success.
- **The torn-check gap the builder noted is real but unreachable from Dart.**
  - Finalize checks only that a slot is allocated and long enough, so a stale
    slot left over from earlier material passes as staged.
  - In Dart, `_checkHistory` enforces `layers.length == images` on every lane.
    `SessionRepository.read` decodes all of a lane's layers or throws.
    `applySession` stages every ordinal of every lane, or throws before
    `finalizeHistory`.
  - The gap pre-dates this PR (`finalize_layers` had it). A staged-slot bitmask
    would close it if another caller ever appears.
- **Capture and import are symmetric.**
  - Capture exports the history, then `imageCount` images per lane.
  - Import stages the same ordinals and finalizes with lane 0's history.
  - Decode rejects lanes of one track whose histories differ.
  - `undoCount`/`redoCount` now count entries, not images. The only consumer
    outside the session code is the post-import check, and it compares entries.
  - `SessionRigLane.redoCount` is derived as `history.length - undoCount`.
  - Native `exportHistory` queries the count with zero capacity, then throws if
    the count changed. `HistoryKind.values[k]` throws on an unknown kind, so a
    future kind fails a save loudly instead of corrupting it.
- **Reopen (#1158).** `test_reopen_keeps_peel_history` shows a retained track
  keeps `[L, PEEL]` and its marker, Undo restores the peeled layer, and both
  markers re-peel down to the original. A track finalized but never committed
  is dropped with depth 0. The stacks are material, and no reopen code iterates
  the redo stack.
- **#1173 provenance.**
  - `le_engine_finalize_history` calls `le_forget_slot_images` before
    `le_publish_live_image(…, 0)`, and `le_engine_import_layer` forgets the
    images too.
  - The layered leg of `test_history_import_during_capture_fails_truthfully` now
    runs through `finalize_history` and passes.
  - A redo-marker re-peel after an import stages its target through
    `le_stage_source_image`, the same path an Undo uses.
- **`finalize_layers` is fully removed.**
  - No reference remains outside historical plan docs.
  - The bindings expose only `le_engine_finalize_history` and
    `le_engine_export_history`.
  - The native engine, the mock and all four fakes are updated: looper, session,
    performance and the root `test/helpers` fake.
- **The PR's tests pass for the right reasons.** M1 is caught by the slot -1
  assertions in three tests (strict, round trip, reopen). M2 is caught by the
  depth assertions. M3 (allow a CLEAR on the undo side in finalize) is caught by
  the strict test. M4 is caught by the export-order assertion. D1 (capture counts
  every entry as an image) is caught by both new `session_repository_test`
  cases. D2 survives; see finding 1.

## Findings

### 1. Capture splits the raw history by the gated published undo depth, and a mismatch silently drops the whole track from the save — Low (data loss in a narrow window; the guard is untested)

- **Where.** `packages/session_repository/lib/src/session_repository.dart:653-661`:
  ```dart
  final undoCount = track.undoDepth;          // published a_undo_depth
  final redoCount = track.redoDepth;
  final history = _engine.exportHistory(i);   // raw undo_stack + redo_stack
  if (history.length != undoCount + redoCount) continue;
  ```
  `a_undo_depth` is not the raw count. `le_publish_undo_depth` holds it at 0
  while a content-giving command is in flight, and `depth_republish` restores
  it only at a later drain.
- **Trigger.** Save right after an Undo that restores a Clear:
  1. `le_engine_get_snapshot` drains while the restore is still unapplied, so
     the republish is skipped.
  2. The callback then applies the restore before the snapshot's per-track
     loads (`engine_snapshot.c:93-99`).

  Probe P4 reproduces the state the loads then read. After the Undo, the audio
  side applies the restore with no control-side drain in between, giving
  `a_state = PLAYING, len = 4, a_undo_depth = 0, a_redo_depth = 1` while
  `undo_count = 2, redo_count = 1`.
- **Impact.**
  - The track is captured with history length 3 against depths 0 + 1, so
    `continue` drops it. The save reports success without that track, and a
    re-save over an existing bundle loses it.
  - With Part 1 the same window was worse: the live image was saved as
    `undo_stack[0]`. Part 2 turns that corruption into an omission.
  - Owner rule 5 asks for a clear notice when state is dropped.
  - Mutation D2 (delete the guard) passes all 123 `session_repository` tests, so
    nothing pins this branch. Without the guard the save would write a manifest
    that its own strict decode rejects, which would make the whole session
    unopenable.
- **Fix.** Pick one:
  - Split the history by the raw count. For example,
    `le_engine_export_history` returns `undo_count` through an out parameter, so
    capture never mixes the gated depth with the raw stacks.
  - Or treat a mismatch like any other capture failure: re-take the snapshot
    once, then fail the save with an error instead of `continue`.

  Add a `FakeSessionEngine` case whose seeded history disagrees with its depths.
  The same silent `continue` applies to a lane whose image export comes back
  short, at `:676-680`, which pre-dates this PR.

### 2. The PR conflicts with the current trunk — Low (mechanical)

- **Where.** `packages/segno_engine/src/core/engine_core.h`. Reverse Part 1
  (`ac4d5ca3a`, now in the trunk) added `le_effective_reversed` at the spot
  where this PR adds `le_hist_kind_entry` and `le_peel_depth`.
- **Impact.** The PR cannot merge as it stands. The fix is a both-add
  resolution. I resolved it locally by keeping both functions. The merged tree
  passes the plain native suite and the session_repository (129),
  looper_repository (805) and root `test/session` (136) suites. No other
  conflict exists, and no trunk code still uses the removed API.
- **Fix.** Rebase onto 31aab2fdc, keep both blocks, and re-run CI.

### 3. "Strict" finalize and decode accept histories the live engine cannot produce — Low (only crafted or corrupt files)

- **Where.** `le_engine_finalize_history` (`engine_session.c:279-297`) and
  `_checkHistory` (`session.dart`).
- **Trigger and impact.**
  - Probe P3a: undo `[PROCESSED]`, redo `[marker, LAYER]` finalizes OK. Redo
    then returns `LE_ERR_INVALID` forever, with `redo_count` stuck at 1, so the
    LAYER image beneath the marker can never be redone.
  - Probe P3b: a CLEAR above a LAYER on the redo side finalizes OK. The live
    engine only ever has one CLEAR, as the deepest redo entry (the redo stack is
    empty when `le_restore_clear` pushes it). A redo of the CLEAR here re-clears
    and discards the LAYER image beneath it.
  - An undo-side PEEL whose `skipped` exceeds the run of PEELs beneath it is
    accepted. Undo then re-inserts its LAYER in a non-chronological position.
  - `session_test.dart`'s `peelHistory` fixture puts `clear` mid-redo, so the
    tests enshrine a shape the engine cannot produce.
  - None of this corrupts PCM or slot ownership. It does contradict the PR's
    "strict" claim and §2's "rejects malformed history".
- **Fix.** In both validators:
  - allow at most one `clear`, and only as the last entry;
  - require each undo-side PEEL's `skipped` to be at most the PEEL run directly
    beneath it;
  - accept a redo marker only when a peelable LAYER will be reachable when the
    marker is reached. Simulating the redo walk is at most 256 steps.

  Otherwise, narrow the "strict" wording to what is actually checked.

### 4. `session-bundle-format.md` still describes a v7 presence-keyed format — Low (docs)

- **Where.** `docs/design/session-bundle-format.md` on the branch, plus
  `session_exception.dart:56`.
  - Line 5 says the document "describes the **v7** schema and how legacy
    bundles migrate".
  - The "Manifest schema (v7)" heading now sits over a `history` example marked
    v12.
  - "Backward compatibility" claims presence-keyed decode of v1–v7 and
    "`> v7` → `SessionUnsupportedVersion`".
  - The doc says "Writing is always the current version (v7)", and the History
    list stops at v7.
  - The `SessionCorruptLayers` doc comment still says
    `undoCount + 1 + redoCount`.
- **Impact.** The PR edits this file and leaves it contradicting the code, which
  decodes the current schema only and counts images by kind.
- **Fix.**
  - Retitle the doc to v12 and state the current-only rule.
  - Replace the compatibility table, or mark it as historical.
  - Add entries v8–v12 to the History list, with v12 = `history`.
  - Update the exception's doc comment.

### 5. `SessionLane` can be built in a shape its own decoder rejects — Low (API shape)

- **Where.** `session.dart` `SessionLane({... this.history = const [],
  this.undoCount = 0, this.redoCount = 0})`.
- **Trigger.** Any producer that sets `undoCount`/`redoCount` but leaves the
  default history writes a manifest that `_checkHistory` rejects. Today the only
  producer is `_capture`, which passes all three.
- **Inconsistency.** `SessionRigLane` derives `redoCount` from `history`, while
  `SessionLane` stores it twice.
- **Fix.** Make `history` required and derive `redoCount` (the JSON can keep
  the field and cross-check it), mirroring `SessionRigLane`.

### Note (pre-existing, not this PR): appliance sessions are already unopenable on the trunk

The trunk has rejected every version other than the current one since
a921bd9a9 (v10). Appliances run master, whose bundles are v7 or older. Once the
trunk lands on master, every session saved on an appliance stops opening. That
conflicts with owner rule 1, and it is not caused or worsened by this PR (v12
only moves the number). AGENTS.md says "do not preserve backward
compatibility", so this needs an explicit owner call, recorded on an issue,
before the trunk merges to master: a one-shot v7 → current migration, or an
accepted loss with a notice.

## Mutations

| ID | Mutation | Result |
| --- | --- | --- |
| M1 | finalize gives a redo PEEL marker an image (`slot = image++`) | caught (3 tests) |
| M2 | finalize publishes `a_peel_depth = undo_count` | caught |
| M3 | finalize accepts a CLEAR on the undo side | caught |
| M4 | `le_engine_export_history` lists the redo side bottom-up | caught |
| D1 | capture uses `total = undoCount + 1 + redoCount` | caught (2 tests) |
| D2 | capture drops the `history.length != undo + redo` guard | **survived** (finding 1) |

## Probes (local only)

- P1: Clear-restore image count at maximum depth: 255 images ≤ 256 (safe).
- P2: Clear over Peel, saved and recalled: the Undo/Redo sequences are
  identical.
- P3: finalize accepts the unreachable shapes in finding 3.
- P4: the published undo depth lags the raw stack after a restore is applied
  (finding 1).

## Verdict

**Approve after a rebase, with one small follow-up.**

The core of the PR is correct and closes #1180 finding 2:

- the strictness of `le_engine_finalize_history` as specified;
- slot assignment, markers, and the redo-side CLEAR;
- peel-depth publication;
- capture and import symmetry;
- composition with reopen and #1173.

Saved histories with markers, PROCESSED and CLEAR entries recall with identical
Undo/Redo/Peel behaviour. The schema bump strands no shipped Session, because
schema 11 never left the trunk and no appliance build has carried anything
past v7.

Before merging:

- Rebase over Reverse Part 1 (finding 2).
- Preferably fix finding 1 in this PR: split by the raw count, or fail the save
  loudly, and add the missing test. It is a one-to-two-line change, and the
  `continue` drops a user's track without notice.

Findings 3–5 are low-risk tightenings and documentation that can follow. The
v7 note needs an owner decision before the trunk reaches master.

## Delta review (531addc0d)

Model: Claude Opus (subagent), in-session.

### Scope

The commits since 15ec99e6d:

- fd9c45b2e: the capture split and the validators;
- 1f29a3a0f: the docs and the plan's record of decisions;
- 531addc0d: the regenerated bindings;
- two merges of the trunk, 10b4c3ac6 and 491bb7147.

The trunk has since moved to 7a9fdcbd9, a UI-only commit. 531addc0d merges into it cleanly, so finding 2, the conflict, is resolved.

### Runs

| Check | Result |
| --- | --- |
| `run_native_tests.sh`, plain, own `TMPDIR` | ALL PASSED |
| same, `EXTRA_CFLAGS="-fsanitize=address -g"` | ALL PASSED, 0 ASAN reports |
| `SEGNO_ENGINE_LIB` exported: `segno_engine` / `session_repository` / `looper_repository` / `performance_repository` | 371 / 133 / 805 / 130 passed |
| root `test/session` | 136 passed |
| `dart analyze` | No issues |
| cspell on `session-bundle-format.md` and the plan | 0 issues |
| Dart mutations (below) | 6 of 7 caught; the survivor is equivalent |
| Native mutations, `SEGNO_PEEL_TESTS_ONLY=1` (below) | 4 of 4 caught |

### Earlier findings

- **Finding 1 (capture split by the gated depth): fixed.**
  - `le_engine_export_history` now reads `t->undo_count` into a new out parameter in the same call that copies the entries (`engine_session.c:167-180`). `NativeAudioEngine.exportHistory` returns one `TrackHistory` (entries plus that raw split), and an entry count that changes between the two calls throws instead of truncating.
  - `_capture` takes the split and the image count from that value. The silent `continue` is gone, because the mismatch can no longer arise.
  - The new test "save splits the history by the raw undo count while the published undo depth reads 0" seeds `publishedUndoDepth: 0` against 2 raw undo entries. It catches the real regression: a mutation that builds the lane's history with `undoCount: track.undoDepth` fails it.
  - One mutation survives, and it is equivalent. `final undoCount = track.undoDepth` changes only which ordinal is probed for an empty live buffer. Every ordinal is still exported by index, so the output is identical.
  - The short-image `continue` (`layerPcm.length != total`) is still there, as before this PR. The plan now records it as a rule-5 follow-up.
- **Finding 3 (validators): fixed, with two recorded deviations that I accept.**
  - Both `le_engine_finalize_history` and `TrackHistory.malformation`, which decode runs, now refuse:
    - a CLEAR anywhere but the last redo entry;
    - a `skipped` outside `[0, 256)`;
    - an undo-side PEEL whose `skipped` exceeds the PEEL run beneath it;
    - a redo marker that finds no LAYER when the redo walk reaches it.
  - The walk matches the engine: it is `le_peel_target` (skip PEELs, then require LAYER, so it stops at CLEAR or PROCESSED) followed by `le_peel_apply` (remove the target, push PEEL). The `sim[2*LE_POOL_SLOTS]` buffer cannot overflow, because the walk's depth only grows on image-bearing entries, which the 256-image cap bounds first.
  - Deviation 1, the bottom-run exception, matches the engine. `le_undo_swap` clamps `insert = p - skipped` to 0 because "pool eviction removes the lowest entries first". `test_peel_pool_eviction` leg 2 produces that shape live, so refusing it would make a real save unopenable.
  - Deviation 2, the marker's `skipped` is unchecked beyond the range, is sound. A redo of a marker recomputes the target and `skipped` (`engine_commands.c:2627-2631`) and never reads the stored value.
  - Mutations. Dart: clear-anywhere, no run bound, no bottom exception and no redo walk were each caught by `session_test.dart`. Native: N1–N4, the same four, were each caught by `test_peel_finalize_history_shapes` (lines 1168/1170, 1176/1178, 1195, 1185).
  - The `peelHistory` fixture no longer puts a CLEAR mid-redo.
- **Finding 4 (docs): fixed.**
  - `session-bundle-format.md` now names v12 and the current-only rule. It lists every refusal, keeps the presence-keyed table under "Historical", adds v8–v12 to History, and points to #1196 for migration.
  - The `SessionCorruptLayers` comment is current.
  - Nit: the History entries for v8 and v9 describe only the slice history (`allTracksChain`, `outputChains`). The trunk's own v8 (9264ccd9f: track settings into session maps, required `undoCount`/`redoCount`, `syncTempo`/`recDub` as session settings) is listed only in #1196's plan table. A link to that table would make this doc complete.
- **Finding 5 (`SessionLane` shape): fixed.**
  - `history` is a required `TrackHistory`, and `undoCount`/`redoCount` are getters on it.
  - The JSON still writes `redoCount`, and decode cross-checks it with `storedRedoCount`. Removing the check is caught.
  - Equality and hash use the `TrackHistory` value.
  - `SessionRigLane` carries the same type.

### New findings

None in the delta.

### Interaction with #1196 (PR #1211)

- **Merge conflicts.** Each branch merges into the trunk cleanly, but the two conflict with each other in three files:
  - `session_exception.dart`: keep `SessionUnconvertible` and this PR's `SessionCorruptLayers` comment.
  - `test/app/application/app_runtime_test.dart` and `test/session/cubit/session_cubit_test.dart`: take #1211's `open` stubs and add `history: TrackHistory.none` to each `SessionLane` (four sites).
- **Without a conversion step.** Once both land, 20 of #1211's 28 migration tests fail: every older bundle ends at the strict v12 decode with "no step 11".
- **With the step.** #1211 needs an 11→12 step that gives every lane `history` = `undoCount + redoCount` entries of `{kind: layer, skipped: 0}` and leaves the counts and `layers` unchanged. That is this PR's plan text and exactly what v11 recall did. With that step on a local merge:
  - every v7–v10 conversion passes;
  - so does the native apply of the converted v7 master bundle through this PR's stricter `finalize_history`.

  The rest is test data: move v11 to the intermediate list and add a v12 fixture written by this branch's `save`. The exact code is in #1211's review, `1196-in-session/review.md`.
- **Order of landing.** If this PR lands first, the step belongs in #1211's rebase. If #1211 lands first, this PR must add the step and the v12 fixture, because #1211's coverage test fails until it does.

### Verdict (delta)

**Approve.** Findings 1, 3, 4 and 5 are fixed and pinned by tests. Finding 2 is resolved by the merges. The only remaining work is the 11→12 conversion step, whichever of this PR and #1211 lands second.
