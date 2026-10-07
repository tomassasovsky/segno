Model: Claude Opus (subagent), in-session

# Review of claude/library-1178-p8 (1d296cf34): Library Part 8 (#1178), back up a session to USB and restore a backup

**Branch:** `origin/claude/library-1178-p8`, head 1d296cf34, one commit on 0274c5423 (Part 7 with its fixes). 34 files, +2436/-22. There is no PR yet.

**Scope:**
- The full diff `0274c5423..1d296cf34`.
- Plan Part 8 and §2 item 12 (Part 8 as built).
- The guard table.
- The `RemovableVolumes` port.
- AGENTS.md conventions.
- The owner rules.
- **Design:** `segno-ui.pen` section 34 (`eKooF`), read through the pencil MCP without saving:
  - `Backup in Library`;
  - `Inline copy progress`;
  - `USB session list`;
  - `Matching backup name`;
  - `Restored session selected`;
  - `Retry an interrupted copy`.

  I compared these against the six new `library_backup_*` goldens.

## Runs

Everything ran in a scratch worktree at 1d296cf34, removed afterwards. `SEGNO_ENGINE_LIB` and `SEGNO_SCREENSHOT_FONT_DIR` were set.

| Check | Result |
| --- | --- |
| Whole app suite | +3714 ~8 -1. The one failure is p6b's timing test "a preview never seen playing ends after five polls"; alone, the file passes (+41) |
| `session_repository` | +273, all passed |
| `performance_repository` | +164, all passed |
| `operation_guards` | +71, all passed |
| `segno_engine` | +388, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` | 0 issues in 897 files |
| `git merge-tree` onto the trunk 787d51db6 | conflicts in 5 engine files, inherited from the p6a merge underneath (p6a review, Finding 1) |

**Probe** (appended to `session_backup_test.dart`, reverted). With a `transfer` guard on `GuardScope.internal(item: bundlePathOf('s-a'))`, exactly what `_runBackup` holds:
- `guards.blockers(sessionWrite, same item)` returns 1.
- But `moveSession('s-a', folder: 'Folder')` succeeds, and `deleteSession('s-a')` succeeds: the bundle is gone.
- In the other order, a `transfer` entering while a `sessionWrite` (a save) holds the item is allowed.

**Mutations** (each reverted):

| Mutation | Result |
| --- | --- |
| The backup's guard on the bundle removed | caught |
| The export's staging and recovery mutations (Part 7 delta) | caught, and they cover the backup's path too |

## Verified correct (traced)

1. **One staging protocol.**
   - A backup is an `AudioExportPlan` package named after the session id, copied through `AudioExporter`, so it inherits Part 7's staging, swap, rollback and `recoverFolder`.
   - `Replace` keeps the old backup aside until the commit point.
   - `Keep both` writes `<id> (2)/`.
   - A lost drive, a full or read-only one, a cancel or a guard refusal leaves the drive as it was, and opens the interruption tile with `Retry` under the same choice. Tests cover each.
2. **What a backup holds.** `bundleFiles` lists every file recursively, with the manifest last and `session.json.tmp` left out. That includes foreign files and an older schema's `session.v<N>/` originals, so a restore is the same bundle.
3. **The listing.** `listBackups` skips hidden directories (a staging copy) and directories without a manifest, and reads summaries leniently (an unreadable one lists as unreadable), newest first. A missing root lists nothing.
4. **Restore** follows Duplicate's rules:
   - a fresh id reserved at the root;
   - everything but the manifest copied;
   - the manifest, renamed, written last through a flushed temp file and a rename;
   - the copy removed on any failure;
   - a `sessionWrite` guard on the new bundle, refused during a shutdown;
   - nothing reaches the engine;
   - a name the catalog carries becomes `<name> (2)` and up, as 34 `Restored session selected` draws it.
5. **Pen 34 conformance.**
   - The footer copy row: "Backing up Evening loop…", the progress bar and `Cancel`.
   - `A backup has this name`: Cancel, Keep both, Replace.
   - `Backup interrupted`: "USB drive disconnected. Nothing was changed.", with Cancel and Retry.
   - The USB list's `Session` / `Saved` header, the rows, "Adds a new session to Library.", and `Restore to Library`.
   - The restored session selected, with `Open session`.

   The departures are listed in plan item 12.

## Findings

### 1. High: a session being backed up can be deleted or moved; its Delete takes no guard, and Manage stays enabled during the backup

- **Where:**
  - `session_repository.dart` `deleteSession`, `moveSession`, `renameSession` and `duplicateSession`, none of which enter a guard;
  - `session_cubit.dart` `deleteSession`;
  - `library_cubit.dart` `_runBackup`, whose comment reads "a save, rename or delete of the session waits too".
- **Mechanism:**
  - The backup's `transfer` guard on the bundle refuses only operations that ask the table. In the session repository only `save` and `restoreFrom` enter `sessionWrite`.
  - Delete, Move and Rename never ask, so the table's new `sessionWrite`×`transfer` refusal (Part 7) does nothing for sessions.
  - The probe confirms it: the guard is held, `blockers()` reports it, and `deleteSession` still removes the bundle.
- **Trigger:** the same "back up, then free the space" sequence as Part 7's F1, and here it needs no reopened Library.
  - The inline progress replaces only the footer, so the heading's `Manage` stays enabled (the `library_backup_progress` golden shows it).
  - Select a session that is not open, `Back up to USB`, then while it copies, `Manage`, `Delete`, confirm.
  - The bundle is deleted.
  - The backup's next `copyFile` fails on the missing source.
  - Its rollback removes the staged copy.
  - The session exists nowhere.
  - A `Move` instead fails the backup with "could not back up", a false failure.
- **Fix:**
  - `deleteSession`, `moveSession`, `renameSession` (and `duplicateSession` on its target) enter `sessionWrite` on the bundle path, as `save` does.
  - The Library disables `Manage`'s Delete and Move with the blocker's purpose while it is held (`GuardRegistry.blockers`), as the Audio card now does for a recording.
  - Add a cubit test that runs Delete during a held backup.

### 2. Medium: a backup can start while a save is rewriting the same bundle, and copy half of it

- **Where:** `guard_registry.dart` `_table`. The `transfer` row has `allow` in its `sessionWrite` column. Part 7 changed only the reverse cell.
- **Mechanism:**
  - A write-back holds `sessionWrite` on the bundle across its async staging write and then swaps `<id>` for `<id>.saving` (Part 3).
  - A backup that enters during that time is allowed (probe). It then reads `bundleFiles` and copies `$bundle/<file>` one by one, so it can take the manifest and layers from different saves, or fail on a layer the new save no longer has.
- **Trigger:**
  - a Save from the stage (Cmd+S) or Manage, followed by `Back up to USB` while it writes; or
  - the D7 preservation save of an Open started from another Library.
- **Fix:** make `transfer`×`sessionWrite` `_i` as well, so the backup is refused ("busy") while the save writes. Add a test.

### 3. Medium: Restore copies the whole backup synchronously on the UI isolate

- **Where:** `session_repository.dart` `restoreFrom`, which calls `_copyDirSync` (`File.copySync` per file) and is called from `LibraryCubit.restore`.
- **Impact:**
  - A session is all of its layers' history. For example, 8 tracks with 4 layers of 60 s at 48 kHz is about 370 MB.
  - Read from a USB 2 FAT drive, the UI isolate is blocked for many seconds: no frames, no footswitch handling, no progress, no Cancel.
  - The audio thread keeps running, but the console looks hung.
  - The copied layers are also not flushed (`copySync`). Only the manifest is. So after a power cut, the restored session can list with short layers.
- **Fix:** run the copy off the UI isolate (`Isolate.run`, or the port's `copyFile` with progress, as the backup does), flush each layer, and show the copy's progress like the backup's.

### 4. Low: Restore takes no lease or guard on the drive it reads

- **Where:** `restoreFrom` reads `${mount}/Segno/Sessions/<id>` directly, not through `RemovableVolumes`.
- **Impact:** the Storage page can offer Eject during a restore without naming it, unlike every other Library copy. Today the synchronous copy (Finding 3) hides this; fixing Finding 3 exposes it.
- **Fix:** hold a `transfer` on the drive's generation, and a read lease if the port offers one, for the copy.

### 5. Low: a backup is of the last save, but the UI does not say so

- **Where:** `_runBackup`, which copies `bundlePathOf(id)`.
- **Impact:** on the open session with unsaved changes, `Back up to USB` copies the saved bundle, and "Backed up to USB." reads as if the live loop was backed up (rule 3).
- **Fix:** offer "Save and back up", or add "Backs up the last save" to the line when the open session has changed (the D7 fingerprint already knows).

### 6. Low: restored names break the catalog's own name rule

- **Where:** `_freeRestoredName` writes `<name> (2)` into the manifest.
- **The inconsistency:** `sessionSlug`, which every other naming path enforces, turns `(` and `)` into spaces. A restored "Evening loop (2)" therefore cannot be typed back by Rename (it becomes "Evening loop 2"). And the collision check of Save as, Duplicate and Rename compares slugged input against stored names that the slug can never produce.
- **Fix:** either allow parentheses in `sessionSlug` (it was the pen's choice), or use `<name> 2`. Pin it with a test.

## Notes

- The swap's FAT metadata-order caveat (Part 7 delta, D-1) applies to backups.
- The golden `library_backup_restored` shows the restored row with "3 tracks" and a preview card reading "no tracks". That is the fixture's preview, not the code. A matching fixture would make the golden a better check.
- The trunk conflicts are p6a's and will clear with its rebase.

**Verdict:** Request changes.
- Finding 1 is the same data loss as Part 7's F1, reachable on the same page.
- Findings 2 and 3 are Medium.
