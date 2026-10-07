Model: Claude Opus (subagent), in-session

# Review of PR #1195: #1177 Part 4, `packages/storage_repository`

**Branch:** `claude/usb-storage-1177-p4` at 79d37ea97, base `claude/segno-integration`.

**Scope:**
- Reviewed 79d37ea97 only, against the plan's §2.3, §4 (fault matrix) and Part 4: 15 files, +2041 lines.
- Parts 2 and 3, merged in at 3dbb98421, are not re-reviewed here. Their delta reviews are in the 1187 and 1188 files.
- Read for API fit: `lib/library/application/removable_volumes.dart` on `origin/claude/library-1178-p2`.

**Setup:** a temporary worktree, removed afterwards.

**Runs:**
- `packages/storage_repository` `flutter test --coverage`: 39/39 passed. lcov shows **256/256 lines** across the 7 lib files.
- `packages/usb_storage_client` `flutter test`: 30/30 passed.
- `dart analyze --fatal-infos` on both packages, `packages/segno_engine` and `lib`: no issues.
- No `Process.` in either package's lib.
- The P1 helper tests (79/79 under bash, dash and sh) are recorded in the 1186 delta review.
- Housekeeping: running `flutter test` in this package rewrote `analysis_options.yaml` locally, adding `analyzer: exclude: build/**`. That is a tool side effect, not part of the PR. I reverted it each time.

## Verified correct (traced)

1. **Volumes.**
   - Each listener gets its own controller, seeded in `onListen`, so no change between subscribing and the first event is missed.
   - The list is sorted by generation, an ejected record stays listed, and the repository's own `ejecting` status overrides the record's while its eject is in flight.
2. **Leases versus eject versus pull** (single isolate, no await between check and set).
   - `eject` checks the holders, then `_eject`, then the record, then sets `_eject`, all synchronously. `acquire` refuses a generation that is being ejected. So an acquire cannot slip into an eject that has started.
   - When a record vanishes, every lease on that generation completes `volumeLost` and is released. A later acquire is refused, and a replug is a new generation.
   - A pull before the request id is known still settles: `_settleEject` runs again once the id arrives and reports `removed`.
   - An answer to an older request id is ignored.
3. **copyFile, normal and single-writer failure paths.**
   - Sequence: the relative path is validated (no empty, `.` or `..` segments, not absolute), then a `copy` lease is taken, then the bytes go to `<target>.part`, then `RandomAccessFile.flush()` (which is fsync(2) in the Dart VM on Linux), then a check that the lease was not lost, then `renameSync`.
   - Every `FileSystemException` deletes the part and is classified: ENOSPC → `full`, EROFS → `readOnly`, lost lease or pulled-drive errno plus record gone → `volumeLost`, anything else → `io`.
   - `NameConflict` is thrown before anything is written.
   - Keep both handles `.hidden` and extension-less names. A case-insensitive filesystem is handled for free, because `existsSync` asks the filesystem itself, so vfat and exFAT report `Take.wav` as taken.
4. **Space.**
   - Internal is measured at the nearest existing ancestor of the exports root.
   - A removable volume is measured only when mounted or read-only.
   - `recordingTimeRemaining` = `max(0, free − reserve) ~/ bytesPerSecond`, with a 1 GiB reserve on Internal only. It returns null when the space is unknown and throws on a non-positive rate. The plan's exact oracle, (64 GiB − 1 GiB) ~/ 288000, is tested.
5. **The eject timeout itself** withdraws a request the helper has not consumed, and the fake test proves it. The remaining gap is Finding 1.
6. **Mutations.** I applied 12. Ten were caught:
   - no lost-check before rename;
   - no part discard;
   - no grace;
   - acquire ignores ejecting;
   - negative usable time;
   - timeout keeps the request;
   - hidden-name split;
   - no parent mkdir;
   - lost leases not completed;
   - reserve on removable.

   The two survivors are in Finding 6.

## Findings

### 1. Medium: a timeout or cancel cannot tell a withdrawn request from one the helper already took, and writes can then land in RAM

- **Where:** `eject` `onTimeout`, `cancelEject`, and `UsbStorageClient.cancelEject`, which swallows "already gone".
- **What happens:**
  - `serve_one` deletes the request file first, and only then runs `sync` and `umount`. A cancel or timeout after that point deletes nothing.
  - The repository still reports `failed('timeout')` or `cancelled` and clears `_eject`.
  - Moments later the helper unmounts and the record turns `ejected`.
- **Probe** (fake client):

  | Path | Reported outcome | What actually happens |
  | --- | --- | --- |
  | Timeout | `EjectFailed(timeout)` | A writer acquires the volume (allowed: `_eject` is null and the status is still mounted). The late answer then turns the status to `ejected`, yet the lease shows `isLost=false`, `held=true`, `transferInFlight=true`. |
  | Cancel | `EjectCancelled()` | The volume is then `ejected`. |

- **Impact:**
  - The user is told the eject failed or was cancelled, and then the drive is ejected anyway.
  - Worse: the helper leaves the mount-point directory in place until detach. A writer that started in the gap keeps writing into `/run/media/segno/<gen>-…` on the tmpfs and is told it succeeded. Nothing fails it, because leases are failed only when a record disappears, not when it turns `ejected`.
- **How likely:** the 1186 delta made this more reachable. With the new lock, serve can wait behind another drive's probe, and `sync` waits on every drive's dirty data, so 20 s is reachable with slow sticks.
- **Smallest fix:**
  - (a) `cancelEject` returns whether it deleted the request.
  - (b) When it did not, keep `_eject` alive and wait for the record's answer. Use a second, longer bound, and say "still ejecting" instead of failing.
  - (c) In `_onRecords`, fail every lease on a volume whose status left `mounted`/`readOnly` (the `ejected` case), not only on one that vanished.
  - (d) Test: answer after the timeout, and answer after the cancel.

### 2. Medium: concurrent copies to the same name share one `.part` and can corrupt a published file

- **Where:** `copyFile`, `_resolveTarget` and the part name `'$target.part'`.
- **What happens:**
  - Name resolution only checks existence. Two copies in flight to the same relative path, for example an export and a backup, or a batch copied concurrently, resolve the same target (`take (2).wav` under Keep both) and open the **same** `.part`.
  - The later copy truncates the file and renames it into place. The earlier copy keeps writing through its open descriptor into the inode that now has the published name, and then its own rename fails.
- **Probe:** the second copy published `take (2).wav` intact and reported success. After the first copy's late writes, **1000 of its 2000 bytes differ** from its source. The first copy reported `StorageIo(No such file or directory)`.
- **Related:** `ask` and `keepBoth` are check-then-rename. rename(2) silently replaces a file another writer created in between, and Dart has no `RENAME_NOREPLACE`.
- **Smallest fix:**
  - Serialize copies per resolved target inside the repository, or keep an in-memory set of reserved targets and resolve against it.
  - Use a unique part name, for example `.<name>.<random>.part`. The dot also hides it; see Finding 3.
  - Test two overlapping copies to one name.

### 3. Low-Medium: crash safety stops at the file

- **No directory fsync.**
  - The part is fsynced, but the rename, and the directory entry of a new `.part`, are not made durable.
  - On ext4 (Internal) a power cut within the commit interval (about 5 s) after `copyFile` returned can leave only `<name>.part` with the full bytes, and no final name.
  - On vfat and exFAT, where `flush` writes metadata soon but not synchronously, a pull without eject has the same window.
  - Dart cannot fsync a directory. Either route it through the engine (an `le_fsync_dir` FFI next to `le_volume_space`), or document that only an eject (which runs `sync`) makes a USB copy durable, and have Part 5 and Part 6 say so.
- **Stale parts are never swept.** A crash or power cut mid-copy leaves `take.wav.part` under a visible name. The Library will list it, and so will the user's computer. Use a dotfile part name and sweep stale parts.
- **`replace` on FAT and exFAT is not crash-atomic.** FAT has no journal, so a pull at the rename can lose the old file too. The `ConflictPolicy.replace` doc ("the old file stays whole until the new one is complete") holds only while nothing crashes. Qualify the doc.

### 4. Low: the 2 s volume-loss grace can misclassify in both directions

- **A real pull reported as `io`.** The grace assumes detach is prompt. After the 1186 fix, detach waits on the helper lock, so a pull during another drive's attach probe (16 MiB with fsync, several seconds on a slow stick) removes the record after more than 2 s. The copy then reports `io` instead of "USB drive disconnected".
- **A source error waits the grace and is blamed on the destination.** ENOENT or EIO from the **source** (a deleted source file, or a source stick pulled during an import to another stick) goes through the destination's grace.
  - Probe: a missing source took **2003 ms** and became `StorageIo(No such file or directory)`.
  - Classify by which side failed: wrap the read and the write separately in `_copyChunks`.
- **Suggestion:** tie the grace to the record (wait up to N s, or until a volume-list event without the generation) rather than a fixed 2 s, or lengthen it.

### 5. Low: unwritable volumes are offered recording time

- `space` and `recordingTimeRemaining` answer for a `readOnly` volume. Probe: **16:34:12 on a read-only stick**.
- They also answer for a volume being ejected.
- The picker (Part 6) will refuse through `acquire`, but a readout that claims hours of recording on a drive that cannot take a byte contradicts "unknown capacity cannot claim available time".
- Fix: return null (or zero) unless `_checkWritable` would pass.

### 6. Low: test honesty. The 100% is real, but the crash-safety core is not pinned

- Line coverage is 256/256, and the CI job is `min_coverage: 100`.
- Two mutations survive all 39 tests:
  - deleting `await out.flush()`, the fsync, from the real copy;
  - deleting the abort poll in the real copy. The pre-rename lost check hides this one, so the copy still reports `volumeLost`, but only after writing every byte.
- The PR body's "every behaviour is mutation-proven" overstates this. Add a test seam for the sync, for example an injected `syncFile`, and a test that the real copy stops writing within one chunk of the loss.

### 7. Low: API fit with the Library's `RemovableVolumes` port (library-1178-p2)

The shapes match:
- the `volumes`, `current`, `space`, `withWriteLease` and `copyFile` signatures;
- the `RemovableVolume` fields and the six statuses;
- the `StorageDestination` factory and subclass names;
- `ConflictPolicy`, `NameConflict`, the `StorageFailure` factories and subclass names;
- the `VolumeSpace` field names.

The swap "one commit, no behaviour change" will still break:
- **`StorageFailure.toString`.** The port's variants describe themselves ("the destination is full", "read-only", "not supported", "drive 3 was removed"), and `test/library/application/removable_volumes_test.dart` asserts that. P4's Equatable default gives `StorageFull()`, `StorageReadOnly()` and so on. Add the port's `toString` overrides here, since the UI and logs will print them.
- **`WriteLease` shape.** The port's is a `const` Equatable value (`target`, `purpose`). P4's is stateful and needs `onRelease`. The Library tests construct `const WriteLease(...)`.
- **Docs.** The port's `VolumeSpace.freeBytes` says "after any reserve the service keeps", but P4's `space()` applies none. Align the docs.
- **Type modifiers.** The port uses `final class` subclasses; P4 uses plain `class`.
- **Nominal typing.** `StorageRepository` cannot nominally implement the app's interface, because a package cannot import `lib/`. The swap needs a small adapter. That is fine, but the port's comment promises otherwise.

## Notes

- **A user file named `<name>.part` is destroyed.** Probe: `take.wav.part` was overwritten and renamed into `take.wav`. The dotfile part name in Finding 2 avoids this.
- **A directory at the target name ends as `io` "Is a directory"**, because `File.existsSync` is false for a directory. Use `FileSystemEntity.typeSync(path) != notFound` both for the conflict and for Keep both candidates.
- **`requestEject`'s own I/O error escapes untyped.** `eject` lets a raw `FileSystemException` out, instead of `EjectOutcome.failed('error')`.
- **Startup race (Part 5 wiring):** until the client's first list arrives, `acquire` on a drive that is present is refused as `volumeLost`.
- **`withWriteLease` returns early by design.** It returns `volumeLost` while `body` is still running, as documented. A body that recreates its directories with `recursive: true` after detach removed the mount point would write onto the `/run` tmpfs. The callers in Part 6 should stop on the first failure.
- **`statvfs` can block.** It is synchronous on the UI isolate; see the P2 review note. `space()` should only be called on page open and on volume events.

**Verdict:** request changes, for Findings 1 and 2. Both are medium and small to fix. Findings 3-7 are low and can follow in Part 5. The coverage claim is accurate as line coverage, but overstated as mutation-proof (Finding 6).

## Delta review (a10cd2387)

Model: Claude Opus (subagent), in-session

**Scope:** `git log 79d37ea97..a10cd2387`, first-parent: a04184bbb (1 GB reserve), 74ad8aace (`le_sync_dir`), 060ea8f1f (eject, parts, claim, sweep, grace, port fit, client backoff), 3f94c9e67 (helper lock), a10cd2387 (P3 test de-flake), plus merges of P1-P3 and the trunk. Also checked against the two P1 lows in 1186-in-session/review.md (bounded lock, `sync -f`, `9>&-`). Worked in a temporary worktree at a10cd2387, removed afterwards.

**Runs:**
- `packages/storage_repository` `flutter test --coverage`: 60/60 passed, lcov **332/332** lines.
- `packages/usb_storage_client` `flutter test`: 33/33 passed.
- `packages/segno_engine` `flutter test` with `SEGNO_ENGINE_LIB` from `build_test_lib.sh`: 370/370 passed.
- `run_native_tests.sh` (scratch TMPDIR): ALL PASSED, `test_sync_dir` included.
- `run_usb_ctl_tests.sh` under `TEST_SHELL=bash`, `dash` and `sh`: 87/87 each.
- On the P5 head, which contains this one: `performance_repository` 130/130, app suite 3365 passed / 55 skipped, `dart analyze --fatal-infos` clean, `bloc lint` 0 issues.
- 17 mutations of `storage_repository.dart`; 16 killed, 1 survived (below).

### Verified correct (traced)

1. **Taken versus withdrawn.** `UsbStorageClient.cancelEject` now returns whether it deleted the request file (Linux: `deleteSync` succeeded; fake: the id was still pending; unsupported: false). On the 20 s timeout, `eject` withdraws an untaken request and fails `timeout`; a taken one keeps `_eject` set (volume reads `ejecting`, `acquire` refuses) and waits for the helper's answer for `ejectServedTimeout` (2 min) more. `cancelEject()` completes `cancelled` only when the client says it withdrew; otherwise the helper's answer stands. A user cancel racing the timeout's own cancel resolves either way to one consistent outcome (whichever delete wins). Mutations "timeout always fails", "no 2-minute cap" and "cancel ignores withdrawn" are each killed.
2. **Leases fail when the status leaves `mounted`.** `_onRecords` marks every removable lease lost when the next record is absent or not `mounted`, so the old Finding 1 window (a writer on a volume that turns `ejected`) is closed. Attach's two writes both carry `mounted`, so the probe landing does not fail a lease. Mutation killed.
3. **Unique parts and the claim.** Each copy writes `.<name>.<16 hex>.part` (`Random.secure`, 64 bits), so two copies to one name never share a descriptor; my old two-overlapping-copies probe is now a test and passes. For `ask` and `keepBoth`, `_claim` does `createSync(exclusive: true)` (O_EXCL, EEXIST on file, directory or link), then renames the part over the empty claim; a failed rename deletes the claim. A user's own `take.wav.part` is untouched; a directory at the name counts as taken. vfat and exFAT replace an existing target on rename, so renaming over the claim works there too.
4. **Sweep.** Only names matching `^\..+\.[0-9a-f]{16}\.part$` and not in this instance's `_liveParts` are deleted, and only in the directory being copied into. The recording plan's own `.part` names (D5) do not carry a 16-hex suffix, so they cannot match.
5. **`le_sync_dir`.** `open(O_RDONLY|O_DIRECTORY|O_CLOEXEC)` + `fsync`; a file is refused, a missing path is `LE_ERR_DEVICE`. Called after every publish.
6. **1 GB reserve.** `internalReserveBytes = 1000000000`. The pen's figures only work with decimal: (64e9 − 1e9) / 288000 = 218750 s = 60 h 45 min 50 s, which is what pen 31 prints ("60 hr 45 min"); a GiB reserve gives 60 h 41 min. The only consumer outside the package is P5's `StorageCubit` (low-space flag and the "1.0 GB reserved" note).
7. **`HeldLease`.** `WriteLease` is now a `const` Equatable value (`target`, `purpose`), matching the Library port; the live side (`lost`, `isLost`, `release`, `markLost`) is `HeldLease`. `markLost` and `release` are idempotent; `markLost` after release is a no-op. `withWriteLease` releases in `finally`.
8. **Grace and source errors.** `copyChunks` routes every source operation through `_fromSource`, so a missing or unreadable source is `io` at once (the 2003 ms wait is gone). The grace is now 10 s and ends on `held.lost`, not the clock.
9. **No time on unwritable volumes.** `recordingTimeRemaining` returns null for a removable volume that `_checkWritable` refuses (read-only, ejecting, ejected, unsupported). Mutation killed.
10. **Port fit.** `final class` everywhere, `toString`s in the port's words, `RemovableVolume.readable`, `space()` documents that free carries no reserve. Old Finding 7 is addressed.
11. **Client backoff.** An ended watch is restarted after 1 s, doubling to 30 s; any delivered event resets it; cancelling the last listener cancels the pending restart. `onListen` does not start a watch while a restart is pending. The tight log-and-relist loop is gone.
12. **Helper (P1 lows).** `take_lock bounded` (`flock -w 60`) for `attach` and `serve-requests`, with a log line and exit 1; `detach` still waits indefinitely. `sync -f "$mp"` replaces the global `sync` in `detach` and `serve_one`. `9>&-` is on `mount`, `umount` (both), `dd`, `udevadm` and `sync`. The suite proves no stub sees fd 9, the 1 s give-up, and that the request stays queued. A request the helper gave up on stays queued, so the app's 20 s timeout withdraws it and reports `timeout`; this is consistent.
13. **The P3 de-flake** (a10cd2387) does not hide a Linux bug. `logged.single` became "non-empty, and every line names `2.json`". The extra lines come only from a re-list that FSEvents triggers on macOS for files written just before the watch began; inotify does not report pre-existing files, and `_relist` drops the duplicate emit (`_sameList`), so `events` stays at one. The behaviour the old assertion guarded (the good records are never logged, and the malformed one is skipped without killing the stream) is still asserted. What it gives up is "exactly one read per list". A regression that read the directory twice on `onListen` would now pass. The exact form could be kept with the injected `watchDirectory` the "when the watch fails" group already uses. This is a note, not a finding.

### Earlier findings

| # | Then | Now |
| --- | --- | --- |
| 1 Medium: timeout/cancel after the helper took the request | open | **Fixed**, apart from a narrow helper-side window (new Finding 1). |
| 2 Medium: concurrent copies shared one `.part` | open | **Fixed.** |
| 3 Low-Medium: no directory fsync, stale parts, `replace` on FAT | open | **Fixed**, with two residues (new Findings 2 and 3). `replace` doc now qualifies FAT and exFAT. |
| 4 Low: grace misclassification | open | **Fixed.** |
| 5 Low: time offered on unwritable volumes | open | **Fixed.** |
| 6 Low: fsync and abort poll not pinned | open | **Fixed.** `copyChunks` is driven directly with an injected `sync`; dropping the fsync or the abort poll now fails a test. |
| 7 Low: port fit | open | **Fixed.** |
| Notes: `.part` collision, directory at the name, untyped request error | open | **Fixed** (dotfile parts, `typeSync`/O_EXCL, `failed('error')`). |
| 1186 delta Low: one stuck holder blocks every drive; fd 9 inheritance | open | **Fixed.** |

### Findings

#### 1. Low: the helper reads a request before it deletes it, so a cancel or timeout can still report "withdrawn" for an eject that then happens

- **Where:** `segno-usb-ctl` `serve_one`: `gen=$(json_get generation "$req")`, `id=$(json_get request "$req")`, then `rm -f "$req"`.
- **Scenario:** the app's 20 s timeout (or the user's Cancel) calls `deleteSync` after the helper has run the two `json_get` subprocesses but before its `rm`. The app's delete succeeds, so `cancelEject` returns true and the eject reports `timeout` or `cancelled`. The helper has the generation and id in shell variables, and `rm -f` ignores the missing file, so it syncs and unmounts anyway. The record then turns `ejected`, so leases fail correctly (Verified 2), but the user was told the eject failed or was cancelled and then sees "Safe to remove". In P5 the "Could not eject" notice then sits under a "Safe to remove" card (see the P5 review).
- **How likely:** a few milliseconds per request, and only when the 20 s timeout or a tap coincides with the helper starting. The bounded lock makes "the helper starts at about 20 s" more likely after a long probe.
- **Fix:** claim the request atomically before reading it: `mv "$req" "$REQUESTS/.taking-$(basename "$req")" 2>/dev/null || continue`, then read and delete the dotfile (the path unit's `*.json` glob ignores it). rename(2) and unlink(2) on one name are mutually exclusive, so exactly one of the app and the helper wins. Add a test that deletes the request between the claim and the read.

#### 2. Low: the claim puts an empty file under the final name for the rename window

- **Where:** `storage_repository.dart:561-613` (`_publish`, `_claim`, `_renameOntoClaim`).
- **Scenario:** between `createSync(exclusive: true)` and `renameSync`, the final name exists as a 0-byte file. A power cut or a pull in that window (no directory sync has run yet, and FAT writes the claim's directory entry independently of the rename) can leave a 0-byte `take.wav` and a hidden full part beside it. The sweep then deletes the part on the next copy into that directory, and the 0-byte file stays. That breaks the class doc's "never holds a half-written file under its final name" and loses the copy's bytes.
- **How likely:** microseconds per copy; only on `ask` and `keepBoth`.
- **Fix:** route the publish through the engine like the directory sync: `renameat2(..., RENAME_NOREPLACE)` (ext4, vfat and exFAT all accept the flag) returns EEXIST without a claim file, and falls back to the claim only where the flag is unsupported. If that is too much for now, at least have the sweep spare a part whose final name is a 0-byte file, and note the window in the doc.

#### 3. Low: the directory sync's answer is ignored, and new parent directories are never synced

- **Where:** `storage_repository.dart:515` (`_syncDirectory(directory.path);`, return value dropped) and `:510` (`directory.createSync(recursive: true)`).
- **Scenario A:** the fsync fails (EIO on a failing stick). `copyFile` still returns the path as if the rename were durable.
- **Scenario B:** a copy into a new `Segno/2026-10-06/` on a FAT stick syncs `2026-10-06/` but not `Segno/`, which holds the new directory's entry. A pull without eject can lose the whole directory, file included. ext4 Internal is covered in practice because its fsync commits the journal transaction that holds the mkdir.
- **Fix:** treat a false return as `StorageFailure.io` (the file is in place, but "copied" should not be claimed), and sync each directory `createSync` created, bottom-up. This is also the place to adopt #1220's `StorageIo.syncDirectory`, which throws instead of returning false (see the consolidation note).

#### 4. Low: after the 2-minute cap the volume reads writable while the helper may still be unmounting it

- **Where:** `eject` `ejectServedTimeout` branch, then `finally { _eject = null; }`.
- **Scenario:** a stuck `umount` outlasts 2 min. The eject reports `timeout` and `_eject` clears, so the status reads `mounted` and `acquire` succeeds. If the unmount then completes, a writer that started in between writes into the bare mount point on tmpfs until the record turns `ejected`, then gets `volumeLost`. That is honest, but what it wrote sits in RAM, and the helper's `rmdir` fails on the non-empty directory.
- **Fix:** after a taken eject times out, keep refusing `acquire` on that generation until the record answers or the drive goes (a `_servedButUnanswered` set), and report "still ejecting" rather than `timeout`.

### Notes

- **One surviving mutation, inherent:** replacing the O_EXCL claim with a check-then-create survives, because a single-isolate test cannot interleave a second writer between check and create. Not a gap worth a seam.
- **Consolidation (rule 4):** this branch adds `le_sync_dir` (perf_drain.c, `AudioEngine.syncDirectory`, `PerformanceRepository.syncDirectory`, four fakes and the mock). #1220 adds `le_fs_sync_dir` and `StorageIo.syncDirectory` for the same job. Keep #1220's; the recording-p1 review gives the merge plan.
- **The reserve change ripples into the recording plan.** `2026-10-06-feat-recording-recovery-plan.md` D2, D5, Part 3, Part 9 and its tests still say "1 GiB" while citing `StorageRepository.internalReserveBytes`. They should say 1 GB, and Part 9's criterion "64 GB free, 1 GiB reserve" should change with it. The recorder's own 500 MB arm refusal (unchanged, per the USB plan) is now a third threshold beside 1 GB; the USB plan already routes its alignment to E7-12.
- **A lock timeout on attach is silent.** `attach` exits 1 with a journal line, and no record is written, so the app shows nothing for a drive that is physically in. A `mountFailed` record with reason "busy, replug" would follow rule 5's "with a notice". Low, and rare (a 60 s stuck holder).
- **`_sweepStaleParts` lists the whole directory on every copy**, synchronously on the UI isolate. On a stick root with thousands of files this is noticeable. Sweep once per directory per session, or off-isolate.
- **Cosmetic:** `test_sync_dir` was inserted between `test_volume_space`'s doc comment and the function, so that comment now sits above the wrong test (`test_engine_core.c:9280`).

**Verdict:** Approve. Both mediums and every earlier low are fixed and pinned by tests; the four new findings are low and can follow in Part 5 or Part 6. The P3 de-flake is sound for the Linux target.
