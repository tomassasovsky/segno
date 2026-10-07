Model: Claude Opus (subagent), in-session

# Review of claude/library-1178-p3: Library Part 3 (#1178), Manage, folders and automatic names

**Branch:** `origin/claude/library-1178-p3`, head 2d88d96ce, one commit on fffdc7fca (Part 2 head). 32 files, +1669/-384.

**Scope:**
- The full diff `fffdc7fca..2d88d96ce`.
- Plan Part 3, D2, D4, D5, D6, and §2 item 6 (Part 3 as built, the builder's listed departures).
- AGENTS.md conventions.
- The owner rules.

**Design:** `segno-ui.pen`, read through the pencil MCP without saving:
- 19/01 `HPb9F`;
- 19/04 `cPmYI`;
- 19/05 `lb1U1`.

I compared these against the four new goldens (`library_manage`, `library_move`, `library_rename`, `library_save_failed`) and the three regenerated ones.

## Runs

All in scratch worktrees under the session scratchpad, removed afterwards. `SEGNO_ENGINE_LIB` came from `build_test_lib.sh`, and `SEGNO_SCREENSHOT_FONT_DIR` was set to the SDK material fonts.

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` | 0 issues in 838 files |
| `flutter test` (whole app, goldens included) | +3416 ~8, all passed |
| `session_repository flutter test` | +162, all passed |
| `git merge-tree --write-tree origin/claude/segno-integration` (56033baf0) `origin/claude/library-1178-p3` | **CONFLICT** in `.github/cspell.json` (see Finding 2) |
| Trial merge, cspell taken as a union: `dart analyze` | **2 errors** in `test/session/record_start_persistence_test.dart:379,388` (Finding 2) |
| Trial merge after a mechanical fix of those two lines, with the engine lib rebuilt from the merged tree: `flutter test` | +3408 ~56, all passed |

**Probe** (a throwaway test, deleted afterwards): a real `SessionRepository.save` write-back that fails at the manifest.
- Setup: `session.json` is made read-only, and the second rig has a different layer length.
- The save threw `PathAccessException`.
- `track0_lane0_L0.wav` changed from 60 to 76 bytes (4 to 8 frames).
- The manifest still described the old 4-frame take. See Finding 1.

**Mutations** (each reverted). Every one was caught:

| Mutation | Result |
| --- | --- |
| Drop the cubit's delete-current refusal | 1 failure |
| `Delete` enabled on the open session in the sheet | 1 failure |
| Drop the Save-as reselect | 1 failure |
| Drop the `failedSessionId` gate on the 19/05 line | 2 failures |
| Drop Manage's busy gate | 1 failure |
| Bypass `_asSaveFailure` | 2 failures |

## Verified correct (traced)

1. **Automatic names (D4).**
   - With no current id, `save()` goes to `_saveNew(null)` and runs inside `runExclusive`: `nextAutomaticName('New loop')`, then `newSessionId`, then the write, then the `savedAs` outcome with the new current id and name.
   - A failed write releases the reservation; the test verifies `releaseSessionId`.
   - `saveAsRequested`, `onSessionState` and `session_name_prompt.dart` are gone (`! grep -rn saveAsRequested lib` passes).
   - The quick-Save toast says `Saved as New loop N`, tested.
   - The power-off flow's own Save-as stays, as the plan says.
2. **Save as.** It refuses a name another session carries exactly, before reserving an id. The new identity becomes current and the old bundle is untouched (same `_saveNew` path).
3. **Delete protection (D6).**
   - `deleteSession` refuses `currentSessionId == id` with `currentSessionProtected` before touching the repository.
   - The sheet dims `Delete` on the open session.
   - During boot recovery, every catalog action is refused by `_performRun`'s boot fence, so the pending, already-applied session cannot be deleted either.
   - The removed `clearCurrentSession` path means no action can null the pointer any more.
4. **Selection never points at a gone session.**
   - After every success, `LibraryView._reselect` does one of three things:
     - after `savedAs`, it selects the new current session;
     - it keeps a selection that is still in the catalog, and re-reads it, so a rename re-reads the preview;
     - otherwise it falls back to the current session, or clears.
   - `clearSelection` bumps the request counter, so a stale read cannot land (tested).
   - The heading reads its name from the catalog, and `Manage` is disabled when the summary is missing.
5. **Move and Rename keep the identity.**
   - Move is a `renameSync` of the bundle directory with the id unchanged. `bundlePathOf` relocates the current session for its next save.
   - Rename rewrites the manifest's name atomically. The header follows only for the open id (cubit tests for both).
   - Moving into an empty minted-id reservation is refused, because `_isFolder` excludes it.
6. **Every failure is visible.**
   - Name refusals are answered inside the keyboard sheet, which stays open: invalid, taken, or refused by the cubit.
   - Every other failed catalog action lands on the 19/05 line.
   - Open refusals stay on their preview card (`failedSessionId` gate, tested).
   - Boot recovery stays with the app-wide notice.
   - The Tracks SnackBar maps `saveFailed` and `currentSessionProtected` too, for Cmd+S at the stage.
7. **Busy gating.** `Manage` and `New folder` are inert while `SessionStatus.working` (tested). This is what keeps catalog mutations from overlapping a save in the UI (see Notes).
8. **Pen geometry.**
   - These match 19/01, 19/04 and 19/05:
     - `New folder` is 144 × 64 at local x 565 beside the 556 search, with a 22 pt label, as the pen draws it;
     - `Manage` is 137 × 64, right-aligned in the 962-wide heading;
     - in 19/05 the layout shortens from 820 to 760, and the line sits at 64/916, 1792 × 33, at 23 pt.
   - The 19/05 colour (`rec` instead of `#efbea0`) is listed.
9. **VGV.**
   - Folders moved from `LibraryCubit` to `SessionState` (one owner for the catalog).
   - Widget classes are extracted, and no widget takes pixel parameters beyond the existing `LoopOutlinedButton` API.
   - Every new string exists in both ARBs.
   - Cubit methods return `Future<void>`.

## Findings

### 1. Medium: "Nothing was changed" is false for a failed write-back, the most likely save failure, and the saved session can be left damaged

- **Where:**
  - `session_cubit.dart:138-165` (`save` → `_asSaveFailure` → `saveFailed`), with the copy in `app_en.arb` `librarySaveFailed`;
  - the write order in `packages/session_repository/lib/src/session_repository.dart:949` and `:967`.
- **What happens:** a write-back to the open session overwrites the bundle's layer WAVs in place, then writes `session.json` in place (`writeAsString`, not a temp file and rename), then the mixdown.
- **Trigger:**
  - On the appliance, the disk fills during Save (or Manage > Save).
  - Any layer write after the first, or the manifest write, fails.
- **Reproduced (probe):**
  - After the failure the bundle holds the new 8-frame layer under the old 4-frame manifest. If the manifest write itself is what fails mid-way, the manifest is truncated, so the session lists as unreadable and cannot be opened.
  - The Library and the stage toast both say "Could not save your current loop. Nothing was changed."
- **Impact:** rule 3, and rule 2's recovery path.
  - The player is told the saved session is intact when it is not.
  - Reopening it later fails, or plays layers that do not match their lengths.
  - The builder listed this ("not true of bundle audio, because save is not transactional"). I do not accept it as a deviation: the sentence is a safety claim, and it is wrong in exactly the case it is shown for.
  - For Save as and the automatic save it is true, because a new reserved directory that fails is a hidden interrupted save, and the catalog and pointer are unchanged.
- **Fix, either of:**
  - **Make the write-back safe** (preferred; the E7-19 shape, but small):
    - write the layers and the manifest into a sibling `<id>.saving/` directory;
    - fsync it;
    - rename the old bundle to `<id>.old`, rename the new one into place, then delete `.old`.

    `_isInterruptedSave` and the minted-id rules already hide such siblings if the names are chosen to match.
  - **Or, until then, split the copy by path:**
    - keep the pen's sentence for a failed save to a new identity;
    - for a failed write-back, say something true, for example "Could not save your current loop. The saved copy may be incomplete; your loop is still here."

    `_SessionRefusal` can carry which path failed.

  Add a real-repository test (read-only manifest, as in the probe) that pins whichever behaviour is chosen. Today the only saveFailed tests mock `repository.save`, so the plan's success criterion ("every bundle on disk unchanged") is asserted nowhere.

### 2. Medium: p3 does not merge onto the current trunk: one textual conflict and one compile break

- **Textual conflict:** `git merge-tree` against `origin/claude/segno-integration` (56033baf0) conflicts in `.github/cspell.json`. Part 1 (0365abff2) and the #1177 merges both append words at the same place. A union resolves it, but the result needs a hand-fixed comma: a naive union is not valid JSON.
- **Semantic break:**
  - Trunk's f3f5b0b2c ("refactor(settings): Fade, Mixer and Session decode on the shared owner") added a loop to `test/session/record_start_persistence_test.dart:368-392` that calls `sessions.bundlePath('Bad')` and `session.loadNamed('Bad')`. Part 1 removed both.
  - The merged tree fails `dart analyze` with 2 `undefined_method` errors, so CI on the merge would be red.
- **Fix:**
  - Rebase the stack (p1..p3) onto the trunk and resolve cspell as a union.
  - Change the two lines to `sessions.bundlePathOf(await idOf('Bad'))` and `session.open(await idOf('Bad'))`; the `idOf` helper already exists at `:69`.
  - With exactly that change, and the engine test lib rebuilt from the merged tree, the whole merged suite passes (+3408 ~56).

### 3. Low: on a selected session that is not open, Manage offers Save and Save as under that session's name, but they act on the open session

- **Where:** `library_manage.dart:48-80`. The sheet's title is `summary.name`. `Save` calls `session.save()` and `Save as` calls `session.saveAs`, both on the live rig (plan D5).
- **Trigger:** select `Evening loop` while `New loop 2` is open, as the `library_manage` golden itself shows, then tap Manage, then Save.
- **Impact:**
  - The sheet titled "Evening loop" writes `New loop 2`, and the toast says only "Session saved".
  - A player who expects the selection to be saved, or overwritten, is wrong either way, and nothing tells them (rule 3).
  - No data is lost, because the open session is the one saved.
- **Fix:** offer `Save` and `Save as` only when the selection is the open session, or there is no open session. Otherwise, label them with the open session's name ("Save New loop 2"). Add a widget test for the non-current case.

### 4. Low: the 19/05 line keeps a stale failure, including failures from outside the Library, until the next session action

- **Where:** `library_page.dart:157` (`libraryFailureOf` reads `SessionCubit.state`, which keeps the failure until any later action).
- **Triggers:**
  - Cmd+S at the stage fails, and the player opens the Library minutes later: the line says "Could not save your current loop" before they have done anything there.
  - A refused delete, or "That did not work. Try again.", stays under the layout through selecting rows, searching, and closing and reopening the Library.
- **Judgement on the listed deviation:**
  - For a save failure the stale line is arguably still true until a save succeeds.
  - For the other two messages it is not, and they describe an action the player may not remember making.
- **Fix:** show only failures of actions started while this Library page is open. For example, record the `SessionState` (or an action counter) at page creation, and drop the line on the next row selection for non-save failures. Add a test that opens the Library onto an existing failure state.

### 5. Low: folders cannot be deleted (or renamed), so a mistyped folder is permanent

- **Where:** no UI calls `SessionRepository.deleteFolder`, which already exists and is safe (it refuses while any child directory holds anything).
- **Impact:**
  - Plan D2 says "an empty folder persists until deleted from Manage".
  - A chip created by a typo, or an emptied folder, can never be removed on the appliance, which has no file browser. That is a recovery-path gap (rule 2), though not a data risk.
- **Judgement on the listed deviation:** "Manage acts on a session" explains the missing row, but it does not justify leaving no way to delete a folder at all.
- **Fix:** a `Delete folder` row for an *empty* folder, either in the Move sheet or on a long press of its chip, using the repository's existing refusal. Or record it in the plan as an explicit Part 3b with an issue.

## Notes

- **The other listed departures:**
  - *English automatic name in every locale.* Acceptable: a name is data, and keeping one prefix stops `New loop 2` and `Nuevo loop 2` from coexisting. Record in the pen note that the Spanish UI shows a `Nuevo loop` button beside `New loop N` names.
  - *Options sheet for Manage and Move.* Acceptable.
  - *Delete confirmation.* Acceptable.
  - *Manage on unreadable sessions.* Acceptable.
  - *`rec` colour for 19/05.* Acceptable.
  - *The shared keyboard sheet instead of 19/04's own.* Acceptable as consolidation (rule 4), but understated. The shared sheet is a different, much smaller layout (title about 18 pt against the pen's 30, keys about 16 against 26, `Save` against `Done`), not just a different button row. The write-back to the pen should say so.
- **Catalog mutations are not serialized with saves.** Only `save`/`saveAs` run inside `_captureSettings.runExclusive`; `rename`, `move`, `delete`, `duplicate` and `createFolder` do not. Today only the Library's busy gate keeps them apart. A rename landing during a write-back of the same session would be overwritten by the save's `name`, captured before (header new, disk old). No current UI path overlaps them, since the footswitch dismisses the Library and power-off is modal. Running every catalog mutation under the same `runExclusive` would make the cubit the authority instead of the view.
- **A failed catalog action does not re-list.** After a partial `deleteSync(recursive: true)` failure, the row stays listed until the next refresh. Re-listing in the failure branch of `_performRun` would close this.
- **Stale comment:** `tracks_commands.dart:216` still says Cmd+S "falls back to Save-As via the view's session listener".
- **An id-shaped folder name** (`s-20261006-120000`) passes the sheet's pre-check, is refused by `createFolder` with `ArgumentError`, and shows the generic "That did not work". Answering it in the sheet as an invalid name would be clearer.
- **Duplicate on the open session** copies the last *saved* bundle, not the live rig (D5, as designed). A player with unsaved changes may expect otherwise. Consider a subtitle ("Copies the saved version").
- **Plan file names:** the plan names `library_manage_sheet.dart` and `library_manage_sheet_test.dart`. The build uses `library_manage.dart`, and its tests live in `library_page_test.dart`. Harmless; update the plan text.

**Verdict:** Request changes.
- Fix Finding 1, either the transactional write-back or a truthful split of the copy, with a real-repository test.
- Fix Finding 2 by rebasing onto the trunk; it is mechanical.
- Findings 3 to 5 are small and can land with this part or as tracked follow-ups.

Everything hunted on data safety otherwise holds:
- delete protection;
- reservation release;
- id stability across move and rename;
- reselection after every action;
- busy gating.

---

## Delta review (9c646c2de)

Model: Claude Opus (subagent), in-session

**Scope:**
- 9a14f9aa8: Part 3 rebased onto the new Part 2 on trunk 56033baf0. `git range-diff` reports `=` against 2d88d96ce.
- 9c646c2de: the review fixes. That is the transactional write-back (Medium 1), the honest Save rows (Low 3), page-scoped failures (Low 4), Rename and Delete folder (Low 5), and the id-shaped folder name answered in the sheet.
- Medium 2 (rebase and the `record_start_persistence_test` port) landed in p1's 6ee864857 and is reviewed there.

**Runs:** scratch worktrees at 9c646c2de, cd721f202 (p5) and 56033baf0 (trunk), all removed afterwards.

| Check | Result |
| --- | --- |
| `session_repository flutter test` at 9c646c2de | +178, all passed |
| Whole app suite at p5, fonts set | +3493 ~8 -17. The 17 are the trunk's control-row goldens, identical at 56033baf0 |
| `session_repository flutter test` at p5 | +185, all passed |
| `dart analyze --fatal-infos lib test packages` and `bloc lint lib test packages` at p5 | No issues; 0 issues in 859 files |

**Probes** (throwaway tests, deleted afterwards):

1. **A catalog read during a write-back.**
   - Setup: save `s-a`, edit the take, start a second save, and call `listSessions()` once per event-loop turn until it finishes. 40 rounds.
   - Result: **32 of 40 saves failed** with `PathNotFoundException ... s-a.saving/track0_lane0_L0.wav`.
   - With `_staging.add` moved above `await dest.create(...)`: 0 of 40. See D-A.
2. **What `refreshSessions` emits after a failure.** `SessionState(status: failure, error: saveFailed).copyWith(sessions: [], folders: [])` maps through `libraryFailureOf` to `LibraryFailure.actionFailed`. See D-B.

**Mutations** (each reverted):

| Mutation | Result |
| --- | --- |
| `_swapIn` no longer renames `<id>.old` back when the second rename fails | **survives** (Notes) |

The builder's own set covers the rest of the transaction: in-place write-back, stage listed, retired kept, no put-back, foreign files dropped, in-flight stage removed, and stale stage kept. I did not repeat it.

## Earlier findings: status

1. **Medium, a failed write-back damaged the saved session: fixed.**

   `save` (`session_repository.dart:998-1043`) now writes a save over an existing bundle into `<id>.saving` and flushes every layer, manifest and mixdown write. It carries foreign top-level files over, then `_swapIn` swaps the bundles:
   - rename `<id>` to `<id>.old`;
   - rename `<id>.saving` to `<id>`;
   - delete `<id>.old`.

   `_rootPath()` runs `_recoverInterruptedSwaps` before every catalog call. Every crash point, traced:

   | Power cut | On disk | Next catalog read | Result |
   | --- | --- | --- | --- |
   | While the stage is written | `<id>` whole, `<id>.saving` partial | stage not in flight, deleted | previous save |
   | Stage complete, before rename 1 | `<id>`, `<id>.saving` | stage deleted | previous save (the new one is lost, never half-applied) |
   | Between rename 1 and rename 2 | `<id>.old`, `<id>.saving`, no `<id>` | `.old` renamed back, stage deleted; `listSync` order does not matter | previous save |
   | After rename 2 | `<id>` new, `<id>.old` | `.old` deleted | new save |
   | During the recursive delete of `.old` | `<id>` new, partial `.old` | deleted | new save |
   | During recovery itself | each step is one rename or a recursive delete beside a live `<id>` | repeated on the next read | converges |

   On ext4 (`/data`, the sessions root via `defaultSessionsRoot`) the files are fsynced before the renames. The journal commits renames in order, so after a power cut the disk holds one of the rows above, never a reordering.

   **Catalog listing during recovery:** recovery is synchronous inside `_rootPath`, before the listing. `listSessions`, `_isFolder` and the folder walk all skip both suffixes (`_isTransient`), so neither shows as a session or a chip.

   **A concurrent save and read:**
   - The swap itself is synchronous, so no read can see the moment between the renames.
   - The stage is protected by `_staging` only after `await dest.create()` returns. See D-A.
   - Saves never overlap, because every save path runs inside `_captureSettings.runExclusive`.

   **Foreign files:** `_carryForeignFiles` copies every top-level *file* that is not the manifest, its temp file, the mixdown or a layer. The test pins this. Directories are not carried (Notes).

   **Name safety:** `sessionSlug` has never allowed `.` (unchanged since 2d6252f73, #116), and minted ids hold none. So no existing install's bundle or folder can end in `.saving` or `.old` and be hidden or "recovered". Rule 1 holds.

   **vfat:** this does not apply to the appliance, because the sessions root is internal ext4 and USB is only an export target. On FAT it would not be safe:
   - Linux's `vfat_rename` adds the new directory entry before it removes the old one, with no journal.
   - A cut between the two can leave `<id>` and `<id>.old` sharing one cluster chain.
   - Recovery would then delete `.old` recursively, and with it the files `<id>` shares.

   Keep the sessions root off FAT, and say so in the bundle-format doc.

   The real-repository test `session_save_safety_test.dart` fails at every write in turn and checks that the bundle is byte-identical to the previous save. That asserts the plan's "every bundle on disk unchanged" at last.

2. **Medium, the rebase and the test port: fixed** (6ee864857, see the p1 delta). The stack now sits on 56033baf0, and analyze is clean.
3. **Low, Save rows on another session: fixed.** On a selection that is not open, the rows read `Save <open name>` and `Save <open name> as…`, or the current loop's label when there is no name. They are tested, and the `library_manage` golden is regenerated.
4. **Low, stale failures: partly fixed.**
   - The line is page-scoped through `_dismissed`, and a selection drops any failure but a failed save. Both are tested.
   - However, the page's own `refreshSessions` replaces the state the page opened on, so an earlier failure comes back as a different message. See D-B.
5. **Low, folders cannot be removed: fixed.**
   - A long press on a folder chip opens `Rename folder` and `Delete folder`. Delete is enabled only while no listed session is filed there, and asks first.
   - `SessionFolderNotEmpty` now has its own line: "That folder still holds sessions. Move them out first."
   - `renameFolder` refuses a taken name, an invalid name and an id-shaped name.
   - A chip whose folder went away puts the filter back to `All`.
   - The id-shaped folder-name note is fixed in both sheets.

## Findings

### D-A. Low: a catalog read while a write-back creates its stage deletes the stage, and the save fails

- **Where:** `session_repository.dart:1010-1013`. `await dest.create(recursive: true)` runs before `_staging.add(dest.path)`.
- **Mechanism:**
  - While the create is in flight, the directory already exists on disk, but it is not yet registered.
  - Any catalog call in that window runs `_recoverInterruptedSwaps` from `_rootPath()`, takes `<id>.saving` for a crash leftover, and deletes it. Calls in the window include `refreshSessions`, `readPreview`, `bundlePathOf` and `listFolders`.
  - The first layer write then throws `PathNotFoundException`.
- **Reproduced:** 32 of 40 saves failed in probe 1, and 0 of 40 with the add moved above the create.
- **Impact:**
  - No data is lost, because the previous save is untouched and the message "Nothing was changed" is true.
  - But a save fails for nothing. Triggers:
    - opening the Library right after Cmd+S (the page refreshes on open);
    - tapping a row (a preview read) while Manage > Save runs;
    - from Part 4 on, any Open whose preservation save meets the preview read the selection started. The Open is then refused.
- **Fix:**
  - Register the stage before creating it.
  - Move the add and the create inside the `try` whose `catch` removes it, so a failed create cannot leave a stale entry that blocks recovery of that path.
  - Add a test that runs `listSessions()` per event-loop turn during a write-back, as probe 1 does.

### D-B. Low: a failure from before the Library opened comes back as "That did not work. Try again." once the page refreshes

- **Where:**
  - `library_page.dart:67` and `:109` (`_dismissed`, compared with `identical`);
  - `library_page.dart:30` (the page calls `session.refreshSessions()` on create);
  - `session_cubit.dart:111` (`emit(state.copyWith(sessions: ..., folders: ...))`);
  - `session_state.dart:156` (`copyWith` resets `error`, `errorMessage`, `failedSessionId` and `outcome` to null whenever they are not passed).
- **Trigger:**
  - Cmd+S fails at the stage, or an Open is refused.
  - The player then opens the Library.
- **What happens:**
  - The first build records the failed state as dismissed, and the line is hidden.
  - The refresh then emits a new state with `status: failure`, `error: null` and `failedSessionId: null`.
  - That state is not identical to the dismissed one, and `libraryFailureOf` maps `error == null` to `actionFailed`.
- **Impact:**
  - The 19/05 line says "That did not work. Try again." about an action the player did not take here.
  - For a refused Open, the refusal that was confined to its preview card becomes a page-wide generic line.
- **Why the test misses it:** "a failure from before the Library opened is not shown" passes only because `refreshSessions` is mocked to emit nothing (`library_page_test.dart:107`).
- **Fix:**
  - Have `_refreshSessions` keep the failure fields (`error`, `errorMessage`, `failedSessionId`, `outcome`), or give `SessionState` a failure sequence number that the page records and compares instead of `identical`.
  - Make `libraryFailureOf` return null for `error == null`.
  - Test it with a real `SessionCubit` whose `refreshSessions` emits.

## Notes

- **The put-back is untested.** The second-rename failure branch in `_swapIn` (`:1166-1168`) can be deleted with all 178 tests still passing. Recovery on the next catalog read would put `<id>` back, but until then the open session's bundle is missing. A seam that fails the second rename would pin the stated behaviour.
- **Directories are not carried.** `_carryForeignFiles` copies files only (`:1141`). The format has no subdirectories today, but a later build that adds one would lose it on a re-save by this build. The old in-place save kept it. Copy directories recursively, or document the format as flat-only.
- **Rename durability:** the renames are not followed by an fsync of the parent directory. A power cut within the ext4 commit interval after a "Saved" can roll back to the previous save. That is safe, but it is not durable at the moment of the toast. An fsync of the parent directory after the swap would close it. Dart has no direct API for that, so it would go through FFI or the engine's C side.
- **Disk space:** a write-back now needs room for two copies of the bundle. On a nearly full disk, a save that the old in-place write managed now fails cleanly. Together with p4 Finding 1, this can block an Open.
- **A folder holding only an interrupted save:** it shows `Delete folder` enabled and "The folder is empty", then refuses with "That folder still holds sessions. Move them out first.", with nothing to move. This is the E7-19 cleanup gap, now reachable from the UI.
- **Catalog mutations are still not serialized with saves.** Rename, move and delete run outside `runExclusive` (earlier note). With the swap, a Move that lands during a write-back now fails the save cleanly instead of racing it, which is an improvement.

**Verdict (delta):** Approve.
- Medium 1 is fixed soundly for ext4, and every crash point is recoverable.
- Medium 2 and Lows 3 and 5 are fixed.
- D-A and D-B are Lows: D-A is a one-line reorder, and D-B is a few lines plus a real-cubit test. They can land here or with Part 4, which makes D-A more reachable.

---

## Delta review (19af70f8d, PR #1252 "the p3 lows")

Model: Claude Opus (subagent), in-session

**Scope:** one commit, 19af70f8d, on 097e1ef68. It addresses delta findings D-A and D-B above, the untested put-back, and the rename-durability note.

**Runs:** a scratch worktree at 19af70f8d, removed afterwards. `SEGNO_ENGINE_LIB` was set.

| Check | Result |
| --- | --- |
| `test/session test/library test/looper/view` | +649, all passed |
| `session_repository` | +192, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues. The first run reported unresolved `package:storage_repository` URIs; that was a missing `pub get` in that package in my worktree, not the PR |
| `git merge-tree` onto trunk 890f04936, and onto the current trunk 6eabf241d | **conflicts** in `lib/session/cubit/session_state.dart` and `packages/session_repository/lib/src/session_repository.dart` (Finding 1) |

**Mutations** (each reverted). All three are caught:

| Mutation | Result |
| --- | --- |
| Register the stage after `await dest.create` again | "catalog reads on every turn of a write-back never break it" fails |
| Drop the put-back of `<id>.old` when the second rename fails | "a write-back failing at any write leaves the previous save whole" fails |
| `_refreshSessions` no longer keeps the result fields | "every failure counts once, and a refresh keeps the last result as it was" fails |

## Earlier findings: status

- **D-A, fixed.**
  - `_staging.add(dest.path)` now runs before the stage is deleted and created, inside the `try` whose `catch` removes it, so a failed create leaves no stale entry.
  - The new test runs `listSessions()` on every event-loop turn during 20 write-backs. That is my probe made permanent.
- **D-B, fixed.**
  - `SessionState.failureCount` is incremented on every failure emit in `_performRun`; I checked all seven emits.
  - `_refreshSessions` keeps `outcome`, `error`, `errorMessage` and `failedSessionId`.
  - The page compares counts, not identity.
  - `libraryFailureOf(error: null)` is now null.
  - The test uses a real cubit refresh.
- **The put-back note, fixed.** `debugOnSaveWrite` is called between the two renames, and a test fails the second one and checks that `<id>` is back before any catalog read.
- **The durability note, fixed.**
  - `syncDirectory` fsyncs the parent directory after the swap and after a recovery put-back. It calls `open`, `fsync` and `close` from `DynamicLibrary.process()`.
  - Calling the variadic `open` through a two-argument signature is safe on Linux arm64 and x86-64 and on macOS arm64, because both arguments are fixed parameters passed in registers.
  - It does nothing on Windows and ignores a failed `fsync`, which the doc states.
  - The bundle-format doc now says to keep the sessions root off FAT.

## Findings

### 1. Medium: the PR does not merge onto the trunk; the conflict sits inside the swap

- **The base:** the PR is based on 097e1ef68. The trunk has since gained the schema-migration retire step (`_retire` and `_keepOriginals`, which move an older schema's originals into the new bundle before `<id>.old` is deleted) and the operation-guard fields in `SessionState`.
- **The conflict:** `git merge-tree 890f04936 19af70f8d` conflicts in both files. In `session_repository.dart` it is exactly where this PR adds `syncDirectory(target.parent.path)` after the second rename and the trunk calls `_retire(retired, live: target)`.
- **The right resolution:** keep both, in this order:
  1. the second rename;
  2. `syncDirectory(parent)`;
  3. `_retire`.

  Then check the trunk's recovery path for the same put-back sync.
- **Why Medium:** it is mechanical, but it is in the data-safety path, and Parts 4 to 7 (all on 890f04936) need the same `failureCount` emits in any failure path they add. Part 5's `newLoopNotSaved` and Part 4's `captureInProgress` go through `_SessionRefusal`, which this PR counts, so they are covered once merged.
- **Fix:** rebase onto the trunk, and rerun `session_save_safety_test.dart` on the merged tree.

## Notes

- `packages/storage_repository/analysis_options.yaml` gains `exclude: build/**`. That is unrelated to the PR's subject but harmless.

**Verdict:** Request changes, for the rebase only. The code is right and every fix is pinned by a test that fails under mutation.

---

## Delta review (7c605fb8e, PR #1252 after the rebase)

Model: Claude Opus (subagent), in-session

**Scope:**
- 163916f62: #1252 rebased onto the trunk. The range-diff against 19af70f8d shows:
  - `failureCount` added to the trunk's `busy` refusal;
  - `conversion` and `refusedBy` kept across the quiet refresh;
  - the swap's `syncDirectory` placed after the second rename and before `_retire`;
  - recovery's "`.old` beside a live bundle" now calls `_retire` instead of deleting;
  - the stray `storage_repository/analysis_options.yaml` change dropped.
- 7c605fb8e: a `debugOnDirectorySync` seam, plus a test that the root's fsync runs with `s-a` and `s-a.old` both present, before the retire.

**Runs:** a scratch worktree at 7c605fb8e, removed afterwards.

| Check | Result |
| --- | --- |
| `git merge-tree` onto the current trunk 787d51db6 | clean |
| `session_repository` | +249, all passed |
| `test/session test/library test/looper/view` | +686, -1 |
| The one failure | `decay_persistence_test` "Save As and Save keep explicit Released zero" failed in `setUp` (`setCountInBars(0)` not ok) while three suites ran in parallel. Alone, it and `click_persistence_test` pass (+9). A trunk test that is sensitive to load, not this PR |
| `dart analyze --fatal-infos` | No issues |

## Status of Finding 1 (the rebase): fixed

The order in `_swapIn` is:
1. the second rename;
2. `_syncDirectory(parent)`;
3. `_retire(retired, live: target)`.

The failed-second-rename branch also syncs after putting `<id>.old` back. A crash between the fsync and the retire leaves `<id>` and `<id>.old`, which the next catalog read retires, keeping the originals the trunk's `_retire` moves first. The new test pins the order: the fsync sees both entries, and the retire comes after.

## Findings

None.

**Verdict (delta):** Approve.
