Model: Claude Opus (subagent), in-session

# Review of PR #1185, Library Part 1 (#1178)

**Branch:** `claude/library-1178-p1`, head 0365abff2, base `claude/segno-integration` at c3714abc2.

**Scope:**
- `git diff origin/claude/segno-integration...origin/claude/library-1178-p1` (one commit);
- the PR body;
- the plan's §3 decisions and Part 1;
- the plan review (`1178-plan-review/review.md`).

**Setup:** I worked in a temporary detached worktree with the native test library built and `SEGNO_ENGINE_LIB` exported, and removed it afterwards.

**Runs at the head:**

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `flutter test test/session test/app test/looper` | +1364 ~6, all passed (native-backed Session tests ran) |
| `session_repository flutter test --coverage` | +146, all passed |
| `bloc lint lib test packages` | 0 issues in 828 files |

Coverage by file:

| File | Coverage |
| --- | --- |
| `session_repository.dart` | 98.6% (489/496) |
| `session.dart` | 95.3% |
| `session_id.dart`, `session_name.dart`, `session_summary.dart`, `session_preview.dart` | 100% |
| `session_exception.dart` | 33.3% (pre-existing `toString` lines) |

## Verified correct (traced)

1. **Existing installs list, load, rename, duplicate and delete unchanged.**
   - A legacy root-level bundle `sessions/<slug>/` is a bundle because it has a manifest. Its id is the directory basename, and with no manifest `name` the display name is that basename, which is what the dialog showed before (`_summaryOf`, `_displayName`).
   - Every legacy slug is a valid id: `sessionSlug` keeps only `[A-Za-z0-9 _-]`.
   - Load: `open(id)` → `bundlePathOf(id)` → `root/<slug>`. The header shows `session.name ?? id`.
   - Rename is metadata-only and never moves the directory, so a legacy bundle keeps its path.
   - Duplicate copies beside the source under a new id and rewrites `name`. Delete removes the located bundle.
   - `formatVersion` stays 11, and `Session.fromJson` ignores an absent `name`.
   - Tests cover this: "a legacy bundle lists under its directory name" and "names a legacy bundle without moving it".
2. **No stored pointer breaks.**
   - The current session is runtime-only (`SessionState` doc: never persisted). There is no boot-time "last session" pointer anywhere (searched `lib` and `packages/*/lib` for `lastSession`, `bundlePath`, `sessionSlug` and session names).
   - The power-off gate reads only whether `currentSessionName` is null.
   - Pedal and MIDI bindings travel inside the manifest (`pedalBindings`) and reference no session.
   - Performance captures live in a separate `exports/` root.
3. **Interrupted saves.**
   - `save` writes the layer WAVs, then the manifest, then the mixdown. A new bundle interrupted before its manifest is a manifest-less directory holding layer WAVs, which is excluded from both the catalog and the folder chips (`_isInterruptedSave`).
   - A real bundle always has a manifest, so it can never be hidden; an undecodable manifest still lists, flagged `unreadable`.
   - An interrupted *re-save* still lists under its old manifest, with partly rewritten layers. That is pre-existing: save is not transactional, which is E7-19.
4. **Re-based exports.**
   - `exportStems` copies each lane's `layers[undoCount]`. `SessionLane.liveIndex == undoCount` (`session.dart:42-46,132`), the same buffer the old live export wrote, under the same `track{c}_lane{l}_L0.wav` names.
   - `exportMixdown` copies `mixdown.wav`, and throws for an empty session, which has none.
   - The removed live-rig cubit exports had no caller in any view at the base. Only their l10n strings and outcomes existed.
5. **Deleting `mixdown.wav` on an empty mix** (review E5). This happens only when this save's mix is empty; a non-empty re-save overwrites the file.
6. **Path safety.**
   - Folder and display names go through `sessionSlug`, so `.`, `/` and `..` cannot survive.
   - Ids are checked by `isValidSessionId` (no separators, not `.` or `..`).
   - `moveSession` requires an existing folder and is a no-op when the bundle is already there. Moving the current session keeps its id, and `bundlePathOf` relocates it.
7. **Tests.**
   - The real-engine persistence suites swap `bundlePath(name)` for `bundlePathOf(await idOf(name))`, where `idOf` is a `singleWhere` on the catalog. That swap is mechanical, and `singleWhere` also asserts the name is unique.
   - In `session_cubit_test`, the export tests went with the removed production code, and the `loadNamed` tests were renamed to `open` with the same bodies.
   - Expected paths changed from `/root/New` to `/root/new`, following the id-based `bundlePathOf`.
   - No assertion was weakened.
8. **Layering.** The application layer imports the repository package only. `SessionPreview` and `SessionSummary` live in `session_repository`. No cubit method returns non-void.

## Findings

### 1. Low: `newSessionId` ignores existing non-bundle directories, so a save can land in a folder or an in-flight save

- **Where:** `session_repository.dart:389-399`. `newSessionId` checks `_locate`, which only finds directories that have a manifest.
- **Reproduced (probe L1):** a user folder `s-20261006-120000` holds bundle `s-gig`. With the clock at that second, `newSessionId()` returns `s-20261006-120000`, and `bundlePathOf` resolves to the folder itself.
- **Trace of a Save As at that point:** the save writes its layer WAVs and manifest into the folder. The folder becomes a bundle, so `listSessions` stops descending into it and `s-gig` disappears from the catalog. Deleting the new session would then `deleteSync(recursive: true)` `s-gig` as well.
- **The same hole, traced:** a Save As that has written its layers but not yet its manifest does not reserve its id. A Duplicate in the same second (catalog actions are not serialized with `runExclusive`) mints the same id and copies into the in-flight directory.
- **Why Low:** both cases need the same wall-clock second, or a folder named exactly like an id.
- **Smallest fix:** treat any existing directory at the root, or one level down, as taken in `newSessionId`, and create the target directory before returning (or create it with an exclusive check).

### 2. Low: `deleteFolder` deletes interrupted saves inside the folder, against D2

- **Where:** `session_repository.dart:744-755`. The check refuses only when a child has a manifest, then `deleteSync(recursive: true)` removes everything else.
- **Reproduced (probe L3):** folder `Gigs/s-x/track0_lane0_L0.wav` (an interrupted save). `deleteFolder('Gigs')` removes it.
- **Impact:** plan D2 says an interrupted save is "left in place (rule 2; cleaning it up is E7-19's transaction work)".
- **Smallest fix:** also refuse (`SessionFolderNotEmpty`) when a child is an interrupted save, or any non-empty directory.

### 3. Low (recorded decision; note for rule 1): a case-insensitive name collision now refuses saves the appliance used to accept

- **Reproduced (probe L4):** with a legacy bundle `Song`, `duplicateSession('Song', 'song')` throws `SessionNameCollision`. Save As and Rename now behave the same way.
- **What changed:** before, on Linux (the appliance, case-sensitive ext4), `song` was a distinct directory and the save succeeded. On macOS it already collided on disk.
- **Impact:** no data is lost, and existing pairs that differ only by case both still list and load. This is the PR's stated decision; it is recorded here only because it is a new refusal for existing installs.

## Notes

- **Rename is no longer atomic.** It used to be a directory `rename`; now it is a non-atomic `writeAsStringSync` of the manifest (`_rewriteManifestName`, `:649`). A power cut mid-write on the appliance leaves an unreadable manifest. The session still lists, flagged unreadable, and its WAVs are intact, but it can no longer be opened. Write `manifest.json.tmp` and then rename it. Save's manifest write has the same shape, but that is pre-existing.
- **Listing now parses every manifest on the UI isolate** (`_summaryOf`). It used to only stat them. Chain strings can carry base64 plugin state, and `listSessions` runs several times per action: after the action, in `_requireFreeName` and in `nextAutomaticName`. Consider reading summaries in `Isolate.run` once the catalog grows.
- **`deleteSession` on the current session still clears the pointer** rather than refusing (D6). The plan puts the D6 refusal in Part 3, so this is not a Part 1 defect.

**Verdict:** Approve with follow-ups. No data loss for existing installs, and every hunted path is sound. Fix the three Lows (Findings 1 and 2 are a few lines each), either here or in Part 2/3.

---

# Delta review (76096cfde)

**Scope:** `git diff 0365abff2..origin/claude/library-1178-p1` (one commit, "fix(session): reserve ids, keep interrupted saves and rename atomically"), checked against the findings above.

**Setup:** my own agent worktree, detached at the Part 2 head 4d9074a27, which contains this commit unchanged. `SEGNO_ENGINE_LIB` was built with `build_test_lib.sh` and exported from a scratch script. A throwaway probe test (deleted afterwards) reproduced the hunted cases against a real temp root.

**Runs (at 4d9074a27, which includes 76096cfde):**

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `flutter test test/library test/session test/looper` | +1027, all passed |
| `session_repository flutter test` | +157, all passed |
| `bloc lint lib test packages` (scratch `git worktree add` under the scratchpad, removed after) | 0 issues in 836 files |

## Earlier findings: status

1. **Finding 1 (id reuse): fixed.**
   - `_reserveId` checks and creates in one synchronous block, so no other catalog call in the isolate can run between them.
   - `_isTaken` counts any entry at the root or one level down, whether bundle, folder, interrupted save or reservation.
   - The probe reproduced the old case: a folder `s-20261006-120000` holding `s-gig` now makes the next id `-2`, and `s-gig` still lists.
   - Duplicate reserves beside its source.
   - Tests cover reservation, a folder or interrupted save named like an id, and a same-second Save as plus Duplicate.
2. **Finding 2 (`deleteFolder` removing an interrupted save): fixed.**
   - The method refuses while any child directory is non-empty, and it lists with `followLinks: false`.
   - Both tests are sound, including the one where a folder holding only empty directories is still deletable.
3. **Finding 3 (case-insensitive collisions): fixed as decided (rule 1).**
   - Name collisions are now case-sensitive in `_requireFreeName`, in the `SessionCubit.saveAs` pre-check, and in the old dialog's (and Part 2's new) `promptSaveAs`.
   - `nextAutomaticName` still skips case-insensitively, which never refuses anything.
   - `createFolder` collides on the directory itself, so it follows the file system. That is consistent.
4. **Note (rename not atomic): fixed.**
   - The manifest is written to `session.json.tmp` with `flush: true` (an fsync), then renamed over `session.json`.
   - On failure the temp file is deleted and the error is rethrown.
   - The hard-link test is a good proof that the file is replaced rather than rewritten in place.

## Regression hunt

- **A reservation leaking an empty directory that lists as a folder.**
  - Every refusal path in `saveAs` goes through `releaseSessionId`:
    - the `StateError` for "session changed before save";
    - `bundlePathOf`;
    - a capture failure.
  - A save that has written anything, even a partial first WAV, leaves an interrupted save. That is hidden and kept, per D2.
  - Remaining leaks:
    - a crash or power cut after `newSessionId` but before the first layer file exists (the window covers `_awaitLayersSettled`, `_capture` and the first encode);
    - a Duplicate whose `_copyDirSync` throws before any file lands. Duplicate has no release path.
  - See D1 below.
- **`releaseSessionId` deleting a real bundle.**
  - It cannot. It only touches `<root>/<id>`, only when `listSync()` is empty, and uses a non-recursive `deleteSync`, which fails on a non-empty directory; that failure is caught.
  - The probe confirmed a manifest written into the reservation survives release.
  - It also cannot hit a user folder: `_isTaken` guarantees the id named no existing entry when it was reserved, and `createFolder` refuses an existing name afterwards.
- **Races between the check and the create.**
  - None in-isolate: `_reserveId` is synchronous from the `_isTaken` scan through `createSync`.
  - In `duplicateSession`, the name check (`await _requireFreeName`) is still separate from the reservation. That is a display-name race, not a directory race, and `saveAs` runs under `runExclusive`.
  - The repository is not multi-process.
- **Rename temp-file leftovers.**
  - A power cut between the temp write and the rename leaves `session.json.tmp` in the bundle (probe P3).
  - It is harmless:
    - bundle detection reads only `session.json`;
    - the next rename overwrites it;
    - Duplicate copies it, but then writes its own temp over it and renames it, so the copy ends clean (probe: `copy tmp: false`).
  - The source keeps it until its next rename.

## Findings

### D1. Low: a reservation interrupted by a crash, or a failed Duplicate, leaves a permanent empty `s-…` directory that shows as a folder chip

- **Where:** `session_repository.dart:405-410` (`_reserveId` creates the directory) and `:744` (Duplicate reserves with no release on failure). `_isFolder` treats an empty directory as a folder.
- **Trigger:**
  - Power is cut or the app is killed during a Save as, after `newSessionId` and before the first `writeAsBytes` creates a layer file.
  - Or `_copyDirSync` throws before copying any file.
- **Reproduced (probe P1):** with no release, `listFolders()` returns `[s-20261006-120000]`.
- **Impact:**
  - A folder named like an id appears in Part 2's chips and stays there until someone deletes it (folder delete arrives in Part 3).
  - While a Save as is in flight, the reservation also lists as a folder for that moment. Part 2 reads folders only when the Library opens, so this needs the Library to open mid-save.
  - No data is lost.
- **Fix:** make the reservation not look like a folder. Either option works:
  - have `_isFolder`/`listFolders` skip an empty directory whose name matches the minted-id pattern `^s-\d{8}-\d{6}(-\d+)?$`;
  - or create the reservation with a marker file that `_isInterruptedSave` recognises, which also keeps it out of the catalog and out of `deleteFolder`.

  Wrap Duplicate's copy in the same release-on-failure as `saveAs`.

## Notes

- `session.json.tmp` left by a power cut is never cleaned up in the source bundle. It is harmless today. Part 8's Back up to USB will copy it unless it filters it out; deleting a stale temp file at the next save would close that.
- `deleteFolder` still deletes loose files directly in the folder (for example `.DS_Store`), as before. That is acceptable; D2 is about interrupted saves.
- Save's own manifest write is still written in place with `writeAsString` (pre-existing, E7-19). Atomic replacement now covers rename and duplicate only.

**Verdict (delta):** Approve. All three earlier findings and the atomicity note are fixed and tested, and no hunted regression loses data. D1 is a cosmetic leak on a crash path; fix it in Part 2 or Part 3.

---

## Delta review (12b90fcba)

**Scope:** `git diff 76096cfde..12b90fcba` (one commit, "fix(session): keep reservations out of the folders and clean up a failed duplicate"), checked against delta finding D1 above.

**Setup:** a detached scratch worktree at 12b90fcba under the session scratchpad (removed afterwards); `SEGNO_ENGINE_LIB` built with `build_test_lib.sh`.

**Runs at 12b90fcba:**

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `session_repository flutter test` | +161, all passed |
| `flutter test test/session` (native-backed) | +132, all passed |

Mutations against `session_catalog_test.dart`, each reverted afterwards. Every one was caught:

| Mutation | Result |
| --- | --- |
| `_isFolder` no longer excludes reservations | 2 failures |
| `createFolder` accepts an id-shaped name | 1 failure |
| Duplicate's catch no longer deletes the target | 1 failure |
| `_isReservation` ignores whether the directory is empty | 1 failure |

## Earlier finding D1: status

**Fixed.**
- `_isReservation` (`session_repository.dart:349`) treats an *empty* directory whose name matches `^s-\d{8}-\d{6}(-\d+)?$` as a reservation. `_isFolder` excludes it, so neither an in-flight Save as nor a reservation left by a crash shows a chip.
- A directory with an id's name that holds something still counts as a folder (tested), so an existing folder never vanishes.
- `createFolder` refuses an id-shaped name before it touches the disk, so a user folder can never be mistaken for a reservation once it is emptied.
- The minted-id pattern is case-sensitive. A user folder `S-20261006-120000` is allowed and still lists. On the case-insensitive macOS file system, `_isTaken` still sees it as taken, so no id can share it.
- A Duplicate whose copy or name rewrite throws now deletes its reserved target recursively. That is safe:
  - the target was created empty by `_reserveId` in the same synchronous block;
  - `_isTaken` guaranteed that no entry had that name;
  - so everything inside it is the copy's own.
- The source is untouched (tested with an unreadable layer file).
- A leftover reservation still counts as taken for new ids (tested), so a crash leftover can never be reused as a bundle directory that already exists.

## Regression hunt

- **`_locate` and `listSessions` with a reservation present.** A root-level empty reservation is walked as a would-be folder with no children, which is harmless. `_locate` never matches it, because it has no manifest.
- **`deleteFolder` on a reservation.** It is a no-op (`!_isFolder`). Reservations cannot be selected as folders in the UI.
- **`moveSession` into an id-shaped name.** This needs `_isFolder`, so a move into an empty reservation is refused ("no such folder"). Correct.
- **The new test relies on `chmod 000`.** It is skipped only on Windows. CI's `flutter_package.yml` runs on GitHub-hosted Ubuntu as a non-root user, so it holds there. Under root (a container runner) the file would stay readable and the test would fail.

## Findings

### D2. Low: an interrupted Duplicate (power cut or kill) can still leave a listed half-copy under the source's name

- **Where:** `session_repository.dart:743` and `:757-767`.
  - `_copyDirSync` copies the source's files in `listSync` order, which on ext4 is hash order. `session.json` can land before any layer WAV.
  - The `name` rewrite happens only after the whole copy.
- **Trigger:** the appliance loses power mid-copy. The new catch block runs only for a thrown error, not for a crash.
- **Impact:**
  - The reserved directory holds the source's manifest and some of its WAVs. It is a bundle, so it lists under the **source's name**, beside the source.
  - Opening it fails, or loads with missing layers.
  - Rule 2 has no data loss here (the source is intact), but the catalog shows two same-named rows, one of them broken.
- **Fix:** skip `session.json` in the copy. After the WAVs land, write the renamed manifest into the target with the same temp-file-and-rename `_rewriteManifestName` uses, reading from the source. A crash mid-copy then leaves a manifest-less directory holding layer WAVs, which D2 already treats as an interrupted save: hidden and kept.

## Notes

- If `deleteSync` in the new catch block itself throws, that error replaces the original copy error. This is cosmetic; consider catching the cleanup failure and rethrowing the original.
- Reservations left by a crash are now invisible, and nothing cleans them up. That is consistent with D2 (E7-19 owns cleanup).

**Verdict (delta):** Approve. D1 is fixed and every new branch is pinned by a test that fails under mutation. D2 is a crash-path Low and can ride with Part 3 or E7-19.

---

## Delta review (6ee864857)

Model: Claude Opus (subagent), in-session

**Scope:** the stack was rebased onto trunk 56033baf0. `git range-diff c3714abc2..12b90fcba 56033baf0..6ee864857` shows:
- 3d799d74a: Part 1's first commit, changed only in the `.github/cspell.json` union (trunk words kept, Part 1 words appended, valid JSON);
- 84c799e01 and 47385b0c4: identical (`=`);
- 6ee864857: new, the D2 fix plus the trunk test port that p3 review Finding 2 asked for.

**Runs:** scratch worktrees at 9c646c2de (p3) and cd721f202 (p5), removed afterwards. `SEGNO_ENGINE_LIB` came from `build_test_lib.sh`.

| Check | Result |
| --- | --- |
| `session_repository flutter test` at p3 (9c646c2de) | +178, all passed |
| `session_repository flutter test` at p5 (cd721f202) | +185, all passed |
| Whole app suite at p5, fonts set | +3493 ~8 -17. The 17 are the trunk's control-row goldens; the same 17 fail at 56033baf0 (see the p2 delta) |
| `dart analyze --fatal-infos lib test packages` at p5 | No issues |

## Earlier finding D2: status

**Fixed.**
- `duplicateSession` (`session_repository.dart:745-767`) now does three things in order:
  - copies the source with `skip: {session.json, session.json.tmp}`;
  - writes the renamed manifest from the *source's* manifest into the target through `_writeManifestNamed` (temp file, flush, rename);
  - only then reports the manifest path to the new `debugOnDuplicateWrite` hook.
- A power cut at any point before the final rename leaves one of two things. Both are hidden by `_isInterruptedSave` or `_isReservation` and are never listed under the source's name:
  - a manifest-less directory of layer WAVs;
  - that directory with a `session.json.tmp` in it.
- The new test records, at every write, whether the copy's manifest exists. Every entry before the last is false, and the last is true, so it pins the order.
- `skip` applies only at the top level. Nested directories copy in full, which is correct: the manifest lives only at the top.
- The `record_start_persistence_test.dart` port (`bundlePathOf(await idOf('Bad'))`, `session.open(await idOf('Bad'))`) is exactly the change p3 Finding 2 proposed. The merged tree analyses clean.

## Findings

None.

## Notes

- The copied WAVs are written with `copySync`, which does not fsync. Only the manifest is flushed. On ext4 with delayed allocation, a power cut shortly after a Duplicate can leave the manifest durable while a copied WAV is still short. Opening that copy would then fail on the short layer. The source is untouched. The write-back in Part 3 flushes every file. Duplicate could do the same with a flush per copied file (read the bytes, then `writeAsBytesSync(flush: true)`).

**Verdict (delta):** Approve.
