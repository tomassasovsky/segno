Model: Claude Opus (subagent), in-session

# Review of the #1177 P4 follow-up (`claude/usb-storage-1177-p4-followup`): one directory sync, a no-replace rename, the atomic request take, synced parents, still-ejecting

**Branch:** 1dfb6a8ca, two commits on trunk 890f04936: 369afe0be (engine) and 1dfb6a8ca (storage, helper, client).

## Scope

The whole follow-up: 26 files.

- **Engine:**
  - `le_sync_dir` removed with every route to it (`AudioEngine`, Native and Mock `syncDirectory`, `PerformanceRepository.syncDirectory`, four fakes);
  - `le_fs_rename_noreplace` added;
  - `StorageIo.renameWithoutReplacing` / `RenameOutcome`.
- **Storage:** `StorageRepository` takes a `StorageIo`, and gains the no-replace publish, synced parents, the once-per-directory sweep, `_unanswered`/`stillEjecting`, and `cancelEject → Future<bool>`.
- **Helper:** the `.taking-` claim.
- **Client:** comment only.
- **Plan:** the matching updates.

Checked against the P4 delta review's four lows (usb-p4-in-session) and the P1 consolidation plan (recording-p1-in-session). Worked in a temporary worktree, removed afterwards.

## Runs

| Suite | Result |
| --- | --- |
| `run_usb_ctl_tests.sh` under `bash`, `dash`, `sh` | 99/99 each |
| `run_native_tests.sh` | ALL PASSED; `test_fs_sync_dir` (now with the file case) and `test_fs_rename_noreplace` |
| `storage_repository` `--coverage` | 80/80, lcov **357/357** |
| `usb_storage_client` | 33/33 |
| `segno_engine` (with `SEGNO_ENGINE_LIB`) | 378/378 |
| `performance_repository` | 135/135 |
| `dart analyze --fatal-infos lib test packages` | no issues |

- On the P6 head, which stacks on this: app suite 3517 passed / 65 skipped, `bloc lint` clean.
- **10 mutations of `storage_repository.dart`, all killed:**
  - no parent sync; no directory sync;
  - `nameTaken` treated as success; `unsupported` without the claim;
  - the cap reporting `timeout`;
  - unanswered not read as ejecting; unanswered never cleared;
  - sweep on every copy;
  - a re-eject filing again;
  - `transferInFlight` ignoring unanswered.

## Verified correct (traced)

1. **Consolidation (rule 4) done.**
   - `git grep le_sync_dir` finds nothing.
   - `le_fs_sync_dir` (EINTR retry, `O_DIRECTORY`) is the only directory sync. It reaches Dart only through `StorageIo.syncDirectory`, which throws.
   - `StorageRepository` takes an optional `StorageIo`, defaulting lazily to `NativeStorageIo()` on the first copy, so watching and measuring drives never loads the library. The composition roots no longer pass a sync function.
   - The P1 review's merge plan is followed step by step, including moving the "a file is refused" case into `test_fs_sync_dir`.
2. **`le_fs_rename_noreplace`.**
   - **Linux:** `syscall(SYS_renameat2, AT_FDCWD, …, RENAME_NOREPLACE)`. EINVAL or ENOSYS gives `LE_ERR_UNSUPPORTED` (filesystem or kernel without the flag). Any other errno gives `LE_ERR_DEVICE`, with the errno passed out.
     - Since 4.9 the VFS enforces `RENAME_NOREPLACE` itself for every filesystem whose `rename` accepts the flag. vfat, exfat, ntfs3 and ext4 all do.
     - On case-insensitive vfat the target lookup finds `Take.wav` for `take.wav`, so a case-only collision is EEXIST too.
   - **macOS:** `renamex_np(RENAME_EXCL)`, with ENOTSUP or EINVAL meaning unsupported.
   - **Windows:** `MoveFileExW(…, 0)`. Without `MOVEFILE_REPLACE_EXISTING` it refuses a taken name; `ERROR_ALREADY_EXISTS` and `ERROR_FILE_EXISTS` map to EEXIST.
   - **Dart:** `ok` → `renamed`, `unsupported` → `unsupported`, `device` + EEXIST (17 on all three) → `nameTaken`, anything else → `FileSystemException` with the OS error. The native test covers success, EEXIST with both files untouched, and ENOENT. CI's Ubuntu job covers the Linux branch.
3. **Publish without a placeholder.**
   - `ask` and `keepBoth` publish through `renameWithoutReplacing`. `nameTaken` means `NameConflict` for `ask` and the next suffix for `keepBoth`.
   - The exclusive-create claim survives only behind `unsupported`.
   - So the old Low 2 window (an empty file at the final name) is gone on every filesystem the appliance mounts.
4. **Synced parents.** `_createDirectories` walks up while nothing is at the path and returns the directories it is about to create, deepest first. After the publish, the file's own directory is synced, then each created directory's parent, bottom up. A sync that throws reaches the `on FileSystemException` branch and is classified as `io` (the bytes are fsynced and the file is in place, but "copied" is not claimed).
5. **The sweep** runs once per directory per process (`_sweptDirectories`). It still spares `_liveParts`.
6. **Still ejecting after the cap.**
   - After `ejectServedTimeout` a taken, unanswered request is recorded in `_unanswered` and the eject completes `failed('stillEjecting')`.
   - While it is there, the volume reads `ejecting`, `acquire` refuses (`volumeLost`), `transferInFlight` is true (shutdown waits), and a second `eject` answers `stillEjecting` without filing.
   - It clears when the record names that request (either answer), turns `ejected`, or goes.
   - The old Low 4 window, a writer let into a drive that is still unmounting, is closed.
7. **The atomic take** in the helper:
   - `serve-requests` does `mv "$req" "$REQUESTS/.taking-<id>.json"` before reading. A failed `mv` (the app's delete won) skips the request.
   - The app cancels with `deleteSync` on `<id>.json`. rename(2) and unlink(2) on one name cannot both succeed, so exactly one side wins.
   - `serve_one` reads the `.taking-` file and removes it.
   - Stranded `.taking-*.json` files from a killed run are served first by the next run, which holds the lock.
   - The `*.json` serve glob and the path unit's `PathExistsGlob=…/*.json` both skip dotfiles.
   - The new tests play the cancel at the two critical moments, with a stub `rm` and a stub listing: before the take (nothing synced or unmounted) and after it (ejected, answer written).
8. **`cancelEject`** now returns whether it withdrew, and P5 uses that.

## Findings

### 1. Low: a request stranded in `.taking-` is only served when another request arrives, but the drive refuses new ejects

- **Where:** `segno-usb-ctl` `do_serve_requests` (the stranded-request loop); `segno-usb-eject.path` (`PathExistsGlob=/run/segno/usb/requests/*.json`); `StorageRepository.eject` (`_unanswered` → `stillEjecting` without filing).
- **Scenario:** the eject service is killed after the `mv` and before the answer (an OOM kill, a crash in `sed`, a stop). The request sits as `.taking-<id>.json`. The path unit does not fire on dotfiles, so nothing serves it again. Meanwhile the app has marked the drive unanswered, so another eject of that drive files nothing, and the only thing that would re-run the helper is an eject of a different drive.
- **Result:** the drive reads `Ejecting…` and shutdown says "Wait for the transfer" until the drive is pulled, with nothing telling the player that pulling is the way out.
- **Fix:** any one of these:
  - have `attach` and `detach` (which already take the lock) also serve stranded `.taking-` files;
  - let a re-eject of an unanswered drive file a fresh request (the helper then finds and answers the stranded one first);
  - after the cap, have the card say "Still ejecting. If it does not finish, unplug the drive."

### 2. Low: a sync failure after the publish reports `io` but leaves the file at its final name

- **Where:** `copyFile`: `_io.syncDirectory` throws after `_publish`. The `on FileSystemException` branch discards the part (already renamed away, so a no-op) and throws `StorageFailure.io`.
- **Scenario:** the Library or export tells the player the copy failed. A retry with `keepBoth` then writes `take (2).wav` beside a `take.wav` that holds the same, complete bytes.
- **Fix:** either say so (`StorageFailure.io` carrying the published path, so the caller can report "copied, but the drive did not confirm it"), or make retries idempotent for this case.
- **Also:** `StorageIo.syncDirectory` drops the errno, so a sync failing because the drive was pulled is classified `io`, not `volumeLost`. Carrying the errno (as `renameWithoutReplacing` does) would let `_classify` apply the pulled-drive rule.

## Notes

- **The lazy `NativeStorageIo`** means a build without the engine library (the macOS dev host before the plugin loads, or a test that injects nothing) fails on the first copy rather than at startup. That is acceptable, and the constructor doc says so.
- **Windows `MoveFileExW`** across volumes would need `MOVEFILE_COPY_ALLOWED`. Not relevant (the part is always in the target directory), but worth a comment.
- **The previous delta's four lows** are all addressed: the helper race by the atomic take, the placeholder window by the no-replace rename, the ignored sync result and unsynced parents by item 4, and the cap window by item 6.

**Verdict:** Approve. The consolidation and every earlier low are done and pinned. The two new findings are low.

## Delta review (79924ef02), PR #1266

Model: Claude Opus (subagent), in-session

**Scope:** `1dfb6a8ca..79924ef02`, five commits:

| Commit | Change |
| --- | --- |
| da0d1eca0 | eject × eject is per volume |
| 938c42ff8 | Spanish completeness test |
| 2f40c9975, 7523f95b1 | `writtenTo` |
| 79924ef02 | `GuardRegistry.addSource` |

The commits also add `le_fs_sync_dir_errno`. Worked in a temporary worktree, removed afterwards.

**Runs:**

| Suite | Result |
| --- | --- |
| App | 3465 passed, 56 skipped |
| `operation_guards` | 73/73, lcov 60/60 |
| `storage_repository` | 81/81, lcov 363/363 |
| `segno_engine` (with `SEGNO_ENGINE_LIB`) | 378/378 |
| `run_native_tests.sh` | ALL PASSED (`test_fs_sync_dir`, `test_fs_rename_noreplace`) |
| `dart analyze --fatal-infos lib test packages` | no issues |
| `bloc lint` | 0 issues in 870 files |

The Spanish completeness test passes. With one key deleted from `app_es.arb` it fails and names the key.

### Checked

1. **Spanish completeness test** (`test/l10n/arb_completeness_test.dart`).
   - It lists every non-`@` key of `app_en.arb` that is missing from `app_es.arb` and fails with the names, so the gap I flagged cannot recur silently.
   - It runs in the root suite, so CI runs it.
   - It does not compare placeholders. I checked by script: no key on the P6 head has an English/Spanish placeholder mismatch. It also does not catch a stale Spanish-only key. Both are fine for its purpose.
2. **eject × eject per volume.**
   - `_table[eject][eject]` is now `_v`, the `_d8` literal reads `v a a v v a a r`, and a new test checks that an eject on drive 1 does not hold an eject on drive 2, while a second eject on drive 1 is refused.
   - The plan's D8 (`claude/recording-recovery-plan-1198`) says "refuse (same volume)" in that cell, so plan, table and test agree.
   - The repository's own one-eject-in-flight rule still serializes requests inside the app.
3. **`GuardRegistry.addSource`** is idempotent (a source added twice is consulted once) and tested. It removes the need for the late-bound closure.
4. **`le_fs_sync_dir_errno`.**
   - The errno is captured before `close()` (`sync_errno = errno` right after the EINTR loop), so `close` cannot overwrite it.
   - An open failure passes its own errno. Windows reports ENOENT or ENOTDIR from the attributes check.
   - `le_fs_sync_dir` is a thin wrapper.
   - `NativeStorageIo.syncDirectory` throws `FileSystemException` with `OSError(errno)`, so `_classify` can apply the pulled-drive rule (EIO, ENOENT, ENXIO or ENODEV plus the record going) to a failed sync.
5. **`writtenTo`.** A sync that fails after the publish is classified like any write failure:
   - a pulled drive is still `volumeLost`;
   - anything else is `StorageIo(reason, writtenTo: <path>)`, whose `toString` says "copied to …, but the drive did not confirm it".
   - Callers can now tell "copied but unconfirmed" from "not copied", and a retry need not add `take (2).wav`. My earlier Low 2 is fixed.

### Still open

Earlier Low 1 is unchanged: a request stranded as `.taking-` is served only when another request arrives. It is mitigated: P5 at 6f3ac7cfd now tells the player to unplug the drive when an eject never answers (see usb-p5).

**Verdict:** Approve.
