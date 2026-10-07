Model: Claude Opus (subagent), in-session

# Review of claude/library-1178-p7 (53c7978be): Library Part 7 (#1178), Library > Audio, USB export and the re-homed DAW export

**Branch:** `origin/claude/library-1178-p7`, head 53c7978be, one commit on 60d1a112b (Part 6b). 55 files, +6157/-489.

**Scope:**
- The full diff `60d1a112b..53c7978be`.
- Plan Part 7, D12 and D13, and §2 item 11 (Part 7 as built).
- The guard table (`packages/operation_guards`).
- The `RemovableVolumes` port contract.
- AGENTS.md conventions.
- The owner rules.
- **Design:** `segno-ui.pen`, read through the pencil MCP without saving: 18/01 `bx7vK`, and 20/07 `KGCxw`, 20/08 `iYJSm`, 20/09 `DFfXS`, 20/10 `m5XyVv`, 20/11 `M734SS` and 20/12 `ee8o6`. I compared these against the eight new `library_audio_*` goldens.

As asked, data safety on Delete and Replace came first.

## Runs

Everything ran in a scratch worktree at 53c7978be, removed afterwards. `SEGNO_ENGINE_LIB` came from `build_test_lib.sh`, and `SEGNO_SCREENSHOT_FONT_DIR` was set to the SDK material fonts.

| Check | Result |
| --- | --- |
| Whole app suite | +3661 ~8, all passed |
| `performance_repository` | +160, all passed |
| `session_repository` | +263, all passed |
| `segno_engine` Dart | +386, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` | 0 issues in 892 files |

**Probes** (`test/library/zz_probe_p7_test.dart`; throwaway, deleted afterwards). They use the real `AudioExporter`, the real `PerformanceRepository` and the suite's `FakeDrive`.

| Probe | What it did | Result |
| --- | --- | --- |
| A | `Replace` of a 3-part export over an earlier 3-part export; the second copy fails | Part 001: **gone** (old replaced, new removed by the cleanup); Parts 002 and 003: the old export |
| B | `Replace` of a 2-part export over an earlier 3-part export | succeeds; the old `Part 003` stays beside the two new parts |
| C | A cut between `_place`'s two renames is simulated: `.segno-export.old` holds the old package, `.segno-export` the new, no target. Then a `Replace` export of another package into the same folder | the drive holds only `Other/master.wav`: the old package **and** the finished new one were deleted |
| D | A finished 2-part take; the export is held after part 1; `deleteCapture` is called | the delete **succeeds** (no refusal); the export then fails on part 2, its cleanup removes part 1, and the drive is empty. **The take exists nowhere** |

**Mutations** (each reverted):

| Mutation | Result |
| --- | --- |
| Delete without the finalized-sidecar check | caught |
| Delete while busy (arm, finalize, render) | caught |
| Delete outside the root or the recovered area | caught |
| Delete with no guard | caught |
| Delete guard kind changed | survives (the kind is not pinned; only the shutdown refusal is) |
| Loose export without its cleanup | caught |
| No space check | caught |
| Stale staging kept | caught |
| `_place` without its put-back on a failed rename | **survives** |

## Verified correct (traced)

1. **Listing.** `listCaptures` reads the exports root and `recovered/`. It skips the take being recorded and every unfinalized sidecar, any bundle still carrying the recovery marker, unreadable sidecars, and loose files. It lists newest first by the arm-time slug, then by name (tested).
   - `performanceSlugTime` rejects a slug whose fields do not round-trip, so `perf-20261332-...` dates to null, not next year.
   - Recovered takes are marked in the row and on the card, as the owner decided.
2. **Parts.** `CapturePart.fromJson` refuses a negative or missing field, an index below 1, and a file name with a path separator, so a sidecar cannot point an export or a delete outside its bundle. Parts sort by stream, then index. A malformed `parts` list lists the take with no audio rather than a guess. A pre-#1198 take reads as its `master.wav` and `live-input-<n>.wav`.
3. **The Delete preconditions.** `deleteCapture` refuses:
   - a directory whose parent is not the root or `recovered/`;
   - `recovered/` itself;
   - an unfinalized take;
   - any arm, finalize or render in flight;
   - a shutdown, through the guard.

   Each is pinned by a test that fails under mutation. The page asks first. The cubit stops Preview before deleting and re-lists afterwards.
4. **Export mechanics.**
   - Every byte goes through the port's `copyFile` under `withWriteLease(purpose)`.
   - Free space is checked against the whole export before the first byte.
   - `ask` reports a taken name (20/09) before anything is written.
   - `Keep both` picks one `<name> (n)` that is free for every target, so a multi-part take keeps one name across its parts.
   - A package is assembled in `.segno-export` and renamed into place.
   - Without `Replace`, a failure, a cancel or a lost drive removes what was placed (tested for `full`, `volumeLost`, `readOnly`, `io` and cancel).
   - Internal storage is only read.
5. **The DAW export re-home.**
   - `writeDawProject` is the one writer, called by `_finishRender` (still caught there on `FileSystemException`, #640), by `DAW project` and by the package export.
   - `reExport`, `isReExporting` and `reExportFailed` are gone, and `grep -rn reExport lib` is empty.
   - The completion sheet's re-export button and banner are removed with their tests.
6. **Preview** plays the first main-output part through the audition voice. A start that lands after a new selection is stopped (request counter). Preview is stopped on folder change, selection, export and close.
7. **The 20/08 to 20/12 flow.**
   - Progress with `Cancel` (20/08). The cancel is honoured between files, and what was placed is removed.
   - `Already on USB` with `Cancel` / `Keep both` / `Replace file` (20/09).
   - `Connect a USB drive` with `Try again` (20/10).
   - "Not enough space. Free up storage and try again." on the card (20/11).
   - `Exported to USB` with "Your internal recording is kept." (20/12).

   Both ARBs carry every string.

## Findings

### 1. High: Delete is not fenced against a USB export reading the same take, and the take can end up nowhere

- **Where:**
  - `performance_repository.dart`, `deleteCapture`, which enters `GuardKind.sessionWrite` on `GuardScope.internal(item: dir)`;
  - `guard_registry.dart` `_table`, where the sessionWrite row has `allow` in the `transfer` column;
  - `library_audio_cubit.dart` `_run` and `close`.
- **Mechanism:**
  - An export holds only the port's write lease, a `transfer` on the *removable* scope. Nothing marks the internal take as being read.
  - The table lets a `sessionWrite` commit during any `transfer`.
  - `LibraryAudioCubit` belongs to the page, and its `close()` stops Preview but neither cancels nor waits for a running export. So the export continues after the Library is left, by Back, Stage or the footswitch, and a reopened Library has a fresh cubit that knows nothing of it.
- **Trigger:** this is the natural "export, then free the space" sequence.
  - Export a multi-part take or a DAW package.
  - Leave the Library while it copies, then come back.
  - Select the same take, Delete, confirm.
- **Reproduced:** probe D.
  - The delete is accepted.
  - The export fails on the next file, because the source is gone.
  - Its cleanup removes what it had already copied.
  - The recording exists neither internally nor on the drive.
  - Under `Replace` the cleanup also removes the files it had replaced (Finding 2), so the player's earlier copy goes too.
- **Is `sessionWrite` right?** No, as it is used. It does what the plan says (refuses during a shutdown and over the same bundle), but no operation that reads a take ever enters a guard on it, so "the same item" never matches anything an export does.
  - **The minimal fix:** an export enters a guard on the internal item it reads, for example `GuardKind.transfer` on `GuardScope.internal(item: capture.path)`, held for the whole copy, and the `sessionWrite` row refuses a `transfer` on the same item (`_i` in that column).
  - That also protects session bundles when Part 8's backup reads them.
  - A dedicated `recordingDelete` kind would work as well. It would need the same column, and adds a row the table must then keep consistent.
  - Either way, disable Delete with the export's purpose while the guard is held (`blockers()` gives the reason), and pin it with a test that runs `deleteCapture` during a held export.

### 2. Medium: `Replace` on a loose (WAV) export is not all or nothing, and leaves stale parts behind

- **Where:** `audio_export.dart` `_runLoose`, with its cleanup `for (final path in placed) File(path).deleteSync()`.
- **The failure:** each part is copied with `onConflict: replace`, so it is renamed over the old file at once.
  - If a later part fails, or the player cancels, the cleanup deletes the parts already placed, and those were the *replacements*.
  - Probe A: the drive is left with no Part 001 at all, and the old Parts 002 and 003.
  - The doc and plan item 11 promise "all or nothing on the drive".
- **The stale parts:** when the new export has fewer parts than the one it replaces (probe B: 2 over 3), the old `Part 003` stays beside the new parts. A DAW import of the folder then takes a part from another recording.
- **Impact:** the player's earlier export is partly destroyed by a failed or cancelled Replace (rule 2). The internal take is untouched, so this is not unrecoverable unless Finding 1 also happens.
- **Fix:**
  - Stage loose files as packages are: copy every part into the hidden staging directory.
  - Then, under `Replace`, move each existing target aside, rename every new part into place, and only then delete what was moved aside. On a failure, put the moved files back.
  - For multi-part takes, consider exporting a directory (`<name>/Part 001.wav ...`), so Replace becomes the existing package swap and no stale part can stay.
  - Add tests for a failed and a cancelled Replace that check the old files are byte-identical.

### 3. Medium: a package Replace cut between its two renames is never put back, and the next Replace into that folder deletes it

- **Where:** `audio_export.dart` `_place` and `_runPackage`.
- **The cut:** `_place` moves the existing package to the fixed name `<folder>/.segno-export.old`, renames the staging into place, then deletes the aside. An unplug or power loss between the two renames is the expected USB hazard, and on FAT/exFAT neither rename is journaled. It leaves:
  - the old package in `.segno-export.old`;
  - the new one in `.segno-export`;
  - no `<name>` directory.
- **What follows:**
  - Nothing ever renames the aside back.
  - The next package export into the same folder deletes `.segno-export` at its start. If it is a Replace, `_place` also deletes `.segno-export.old` (probe C), whatever package it held.
  - Both copies of the first package are then gone from the drive, and the player saw neither go.
  - The put-back on a failed second rename is untested: a mutation removing it survives.
- **Fix:**
  - Name the aside after its target (`.segno-export-<name>.old`).
  - At the start of an export into a folder, put any aside whose target is missing back under its name before doing anything else.
  - Never delete an aside except right after its own successful swap.
  - Add a test for the put-back.
  - Note that dot-prefixed directories are not hidden on Windows, where a FAT drive will show `.segno-export`. That is harmless once the leftovers are handled.

### 4. Medium: `DAW package` and `DAW project` run while the take's render is still writing its stems, and report success

- **Where:**
  - `library_audio_cubit.dart` `_planFor` (the package) and `writeProject`;
  - `performance_repository.dart` `dawPackageFiles`.
- **Mechanism:**
  - `_finalize` writes `finalized: true` into the sidecar and then starts the offline render (`renderBegin`).
  - The render writes `stems/dry/*.wav` and `stems/wet/*.wav` straight to their final names (`perf_render.c` `le_pr_write_wav`, `fopen(path, "wb")`, no temp file).
  - `listCaptures` lists the take as soon as the sidecar is finalized, and neither export path checks `renderProgress`. `deleteCapture` does check it, so the hazard is known.
- **Trigger:** stop a performance, open Library > Audio, export the take as a DAW package.
- **Impact:** the drive gets stems that are missing, or whose WAV header claims more data than the file holds, under a Live Set that points at them. The flow ends on "Exported to USB" (rule 3).
- **Fix:**
  - While `!renderProgress.done` for that take, show the take as rendering, and disable `DAW project` and the package choice (the plain WAV parts are final and can still go).
  - Or refuse with a line, as Delete does.
  - Add a test with a render in progress.

### 5. Medium: the Library presents recovered takes as kept, but the 30-day prune still deletes them at boot

- **Where:**
  - `performance_repository.dart`, `recoveredRetention = Duration(days: 30)` and `_pruneRecovered`, run by `runBootRecovery`;
  - plan item 11: "Removing the 30-day prune is #1198 Part 2's change".
- **Impact:**
  - On this stack, a take marked `Recovered` in the Library disappears at the first boot after 30 days, with no notice.
  - Before this part, recovered takes were invisible, so the loss went unnoticed. Now they are listed beside the others as the owner's "kept, no automatic delete", and then vanish (rules 2 and 3).
- **Fix:** do not merge Part 7 ahead of #1198 Part 2, or remove the prune here. Until then, at least show the date it will be removed.

### 6. Low: Delete removes the take in place, so a failure or power cut part-way leaves half a take

- **Where:** `deleteCapture`, `Directory(dir).deleteSync(recursive: true)`.
- **Impact:**
  - The order of a recursive delete is the directory's. A cut, or a file the delete cannot remove, can leave the sidecar with some parts gone, so the take lists at full length and fails on Preview and export.
  - Or it leaves parts without a sidecar, hidden but still taking space that nothing reclaims.
- **Fix:** rename the take to a hidden `.<name>.deleting` first (atomic on ext4), then delete it. Have the listing skip that suffix, and have boot recovery finish such deletes.

### 7. Low: a session export that fails while building its files leaks its scratch directory

- **Where:** `library_audio_cubit.dart` `_planFor` and `_run`.
- **Mechanism:** the scratch directory is created inside `_planFor`, but `_run` only learns it from `_planFor`'s return value. If `exportStems` or `exportMixdown` throws (for example on a full disk), the half-written scratch directory under `Directory.systemTemp` is never deleted.
- **Impact:** on the appliance this is presumably tmpfs, so RAM, though I did not verify it on the device. Each failed retry leaks another copy of the stems.
- **Fix:** create the scratch directory in `_run` and pass it in, or clean up inside `_planFor` on failure.

### 8. Low: `DAW project` writes `project.als` in place, and the package reuses whatever is there

- **Where:** `daw_project_export.dart`, which uses `writeAsBytes` and `writeAsString` straight to the final names.
- **Impact:** a failure part-way (a full disk) leaves a truncated `project.als`. `hasDawProject` then reads true, and the package export regenerates only when the file is missing, so it copies the broken Live Set.
- **Fix:** write to a temp file and rename, as the session manifest does.

### 9. Low: pen departures not recorded

- **What item 11 lists:** the folder level, the search, the USB location and the missing `Show on USB`.
- **What it does not list:**
  - 18/01 and 20/07 draw `Prepared audio`, `Save audio` and `Record performance` in the title row; the build has none.
  - The card's `Add to prepared`, `Use as backing` and `Use in loop` are absent, and `DAW project` and `Delete` are added.
- **Fix:** list them, with the issue each belongs to (backing, #1200), and write the departures back into the pen's `c/` notes.

## Notes

- **Free space:** the check is against the whole export, with nothing credited for the bytes a `Replace` frees. It is conservative, so a Replace that would fit can be refused as full.
- **FAT32:** a pre-#1198 `master.wav` over 4 GB fails mid-copy on FAT32, after the space check passed, and is reported only as "export failed". The volume's `fsType` is known, so this could be refused up front with its own line.
- **Re-reads on every Audio tab load:** `load()` calls `mixdownOf` once per session, and each call runs `_rootPath()`, which is the swap recovery scan. That is one directory walk per session. It is fine at today's sizes, but a single catalog read could return the mixdowns.
- **The delete guard's purpose** is `capturePurpose`, the same string a recording's guard shows. A refusal of another operation would name "recording" for a delete.

**Verdict:** Request changes.
- Finding 1 (High) and Findings 2 and 3 (Medium) are data safety on Delete and Replace, the stated priority.
- Finding 4 is a silently incomplete export.
- Finding 5 is a merge-order condition on #1198 Part 2.

---

## Delta review (0274c5423, PR #1265)

Model: Claude Opus (subagent), in-session (a direct review, no sub-agents)

**Scope:**
- 0d573c84c: Part 7 rebased onto the fixed p6b. The range-diff is p6b's API only: `stillWanted` and `stopListening`.
- 0274c5423: the fixes for F1 to F4 and the Lows. F5 is recorded as a merge-order dependency on #1198 Part 2 (#1245).

**Runs:** a scratch worktree at 1d296cf34 (p8, which contains this commit; p8 changes neither the exporter, the audio cubit nor the guard table), removed afterwards.

| Check | Result |
| --- | --- |
| Whole app suite | +3714 ~8 -1. The one failure is p6b's timing test (see the p6b delta) |
| `operation_guards` | +71, all passed |
| `performance_repository` | +164, all passed |
| `dart analyze` | No issues |
| `bloc lint` | 0 issues |
| `git merge-tree` onto the trunk 787d51db6 | conflicts in 5 engine files (bindings, `engine.c`, `segno_engine_api.h`, `run_native_tests.sh`, `test_engine_core.c`). These come from the p6a merge underneath (p6a review, Finding 1), not from Part 7 |

**Mutations** (each reverted). All are caught:

| Mutation | Result |
| --- | --- |
| The table's `sessionWrite`×`transfer` back to `allow` | caught by the guard test and by the card's disabled Delete |
| The export's take guard removed | caught |
| `earlier` parts not moved aside under Replace | caught |
| `recoverFolder` not run | caught (rerun alone; the full-suite run was hidden behind the timing flake) |
| The commit marker kept | caught |
| The rollback's put-back removed | caught |
| The DAW package allowed during a render | caught |
| `_finishDeletes` dropped | caught |

## Earlier findings: status

- **F1 (High), fixed.**
  - A recording's export enters `transfer` on `GuardScope.internal(item: capture.path)` for the whole copy, released in `finally`.
  - The `sessionWrite` row now refuses a `transfer` on the same item (`_i`).
  - `deleteCapture` uses the same path, so a Delete from any Library, including one opened after the export began, is refused, and the card disables Delete and names the export.
  - `GuardRegistry` is now provided app-wide.
- **F2 and F3 (Medium), fixed.** There is one staging-and-swap path for loose files and packages:
  - stage in `.segno-export-<name>/`;
  - write the target list into `.segno-export-<name>.old/.targets` (flushed);
  - move what is replaced, and under Replace every `earlier` part (a `RegExp.escape`d `^<name>( · Part \d{3})?\.wav$`), aside;
  - rename the staged entries in;
  - delete `.targets` (the commit point);
  - drop the aside.

  On the failure paths:
  - Any failure before the commit point rolls back. Placed targets are removed only if they are no longer staged, and the aside goes back to every free slot.
  - `recoverFolder` runs first in every export, and rolls back an aside that still has its list.
  - Tests check that a failed or cancelled Replace leaves the earlier export byte for byte, that no stale part stays, and that a cut is put back.
- **F4 (Medium), fixed.** `DAW project` and the DAW package are refused with `stillRendering` while the engine's render slot is busy. The plain parts may still go.
- **F5:** documented as a dependency (#1245). That is acceptable as long as the merge order is enforced.
- **Lows, fixed:**
  - A Delete renames the take to a hidden `.<name>.deleting` first. The listing skips dot-entries, and boot finishes a cut one (tested).
  - The scratch directory is created and removed in `_run`.
  - `project.als` and `fx-chains.txt` are written via a flushed temp file and a rename.
  - The pen departures and the merge order are in plan item 11.

## Findings

### D-1. Low: on FAT, the swap's commit relies on metadata order the filesystem does not keep

- **Where:** `audio_export.dart` `_swap`. Nothing fsyncs the folder between the last rename into place and the deletion of `.targets`, or between the commit and the deletion of the aside.
- **Why it matters:** vfat has no journal, and the kernel writes dirty directory blocks back in any order.
- **Trigger:** an unplug or power loss a few seconds after "Exported to USB", without Eject, can persist the `.targets` deletion while the renames into place are still pending.
- **What recovery then does:** it sees no list, deletes the aside (the earlier export) and the staging directory (the new one).
- **Impact:** this is rare, and Eject syncs. But it is exactly the cut the protocol is meant to survive.
- **Fix:** an `fsync` of the folder after the renames into place and before the commit, and again after the commit before dropping the aside. `syncDirectory` from `session_repository` does this (`fsync` on a directory is implemented by vfat).

### D-2. Low: the render check misses the moment between finalize and render start

- **Where:** `library_audio_cubit.dart` uses `_performance.rendering` (`!renderProgress.done`) only.
- **The gap:** `_finalizeArmed` writes `finalized: true` and then calls `renderBegin` after an `await`. In that window the take lists as finished and the render is not yet busy.
- **Fix:** use the same predicate `deleteCapture` uses (`_finalizesInFlight > 0 || !renderProgress.done`), exposed by the repository.

**Verdict (delta):** Approve. F1 to F4 are fixed and each is pinned by a test that fails under mutation. The two Lows can follow. The trunk conflicts are p6a's rebase.
