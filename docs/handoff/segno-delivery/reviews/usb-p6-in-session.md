Model: Claude Opus (subagent), in-session

# Review of #1177 Part 6 (`claude/usb-storage-1177-p6`): recorder Save to, takes on a USB drive, and the guard table

**Branch:** 4e9de66b5, one commit on P5 (79e44868a), which is on the P4 follow-up (1dfb6a8ca) and trunk 890f04936.

## Scope

35 files, +1902/−21:
- `StorageRepository` as an `ActiveOperationSource`, with `enter` at `acquire` and `eject`;
- `PerformanceRepository.arm(root:, scope:)`;
- `RecordingDestinationCubit`;
- `StorageDestinationPicker`, `ConnectUsbSheet` and `RecordingSaveTo`;
- the recorder's recording lease, `volumeLost`, and the armed readout naming the drive;
- `run_segno`'s late-bound source;
- the toasts, goldens and plan.

Checked against the USB plan's Part 6, recording plan D8 and Part 11, pen 48 (`w70bn`: `cH9UX`, `FwjUV`) and the Connect USB tile (`m5XyVv`), read through the pencil MCP from the main checkout's `segno-ui.pen`, not saved. Worked in a temporary worktree, removed afterwards.

## Runs

| Suite | Result |
| --- | --- |
| App suite | 3517 passed, 65 skipped (`save_to_*` and `connect_usb_sheet` goldens matched) |
| `storage_repository` `--coverage` | 83/83, lcov **381/381** |
| `performance_repository` | 137/137 |
| `operation_guards` | 71/71 |
| `dart analyze --fatal-infos lib test packages` | no issues |
| `bloc lint` | 0 issues in 886 files |

Two probes with temporary tests, removed afterwards: the guard-table eject on drive B, and the recording lease when `arm` throws. Findings 1 and 3.

## Verified correct (traced)

1. **Leases are guard-registered.**
   - `acquire` (non-recording purposes) checks `transfer` at the destination's scope with `enter(...).release()`, synchronously before it registers the lease. `eject` checks `eject` at `removable(gen)` after the local `EjectRefused` and `stillEjecting` checks and before filing anything.
   - `activeOperations` reports every non-recording lease as `transfer` and the eject in flight or unanswered as `eject`. It is recomputed on each read, so it is never stale.
   - Tests:
     - a copy onto a volume a take records on is refused;
     - an eject is refused by a capture on that volume and by a restart;
     - nothing is filed on a refusal.
2. **Leaving the recording lease unreported holds where the capture guard exists, but not for the whole lease.** The take enters `capture` at `removable(gen)` at its commit, and capture against transfer or eject on the same volume refuses both ways (#1221 at a7e961204 and later). Reporting the recording lease as `transfer` as well would make the take's own `enter(capture)` refuse itself. The gap is after the capture guard is released (Finding 4).
3. **The take on USB.**
   - `_armTarget` takes the `recording` lease (a refused lease or a missing mount point refuses the arm with `driveUnavailable` and its own toast).
   - It arms with `root: <mount>/Segno/Performances` and the volume's scope. It releases the lease when the arm is refused or does not arm (`armedDirectory == null`), and when the take is finalized (`done`).
   - A lease lost during the arm's own awaits stops the take as soon as it is armed.
   - `_onLeaseLost` ignores a stale lease.
   - The free-space floor measures the drive's mount point, because the take's directory does not exist yet.
4. **`volumeLost`.**
   - The lease's `lost` routes to `_stopEarly(volumeLost)`, the same single-stop path as a full disk (one `Finalizing`, tested).
   - The completion sheet and the toast say "the USB drive was disconnected. Your loops kept playing."
   - On a really pulled drive, `_finalize` finds no sidecar and returns without a write, so the repository does not stick in `finalizing`.
5. **`RecordingDestinationCubit`.**
   - Starts on Internal. Falls back to Internal when the chosen drive stops being mounted read-write.
   - Recomputes the remaining time on every volume event and choice (stereo 24-bit at the applied rate), and drops a stale result (`state.destination != destination`).
   - `awaitDrive` chooses an already-mounted drive at once; otherwise it chooses the next one to mount.
6. **The picker and sheet against pen 48.**
   - Copy matches: `Save to`, `Internal`, `USB drive` when no drive is connected (`cH9UX`), the drive's label in 700 while recording (`FwjUV` "SEGNO USB"), `Connect a USB drive` / `Your recording stays in Internal.` / `Cancel` / `Try again` (primary, 700) (`m5XyVv`).
   - Pills use the pen's 180x64 minimum with radius 7, filled and edged when chosen.
   - Read-only, unsupported and too-slow drives are disabled with a reason line. Ejecting and ejected drives are not offered.
   - The row locks to the chosen name while armed, finalizing or rendering.
   - The sheet pops once, on the first switch to a drive, and a cancel stops the wait.

## Findings

### 1. Medium: the Connect USB path chooses a drive the picker would refuse: unmeasured or too slow

- **Where:** `RecordingDestinationCubit._canRecordTo` checks only `mounted` and `mountPoint`. `awaitDrive` and `_onVolumes` (while awaiting) choose the first drive that passes it.
- **Scenario:** with no drive in, the player taps `USB drive` and the sheet waits; they plug a stick.
  - The helper writes the record before its write probe (by design), with `writeBytesPerSecond: null` and status `mounted`, so the cubit chooses the drive immediately and closes the sheet.
  - The probe then reports 1.2 MB/s, under `RecordingSaveTo`'s required 2 × 288000 B/s. The picker would have disabled that pill as too slow, but it is already the destination.
  - A take on it is exactly the slow-stick zero-fill risk (#710) the speed gate exists for. `Try again` takes the same path with a drive already plugged.
- **Related:** the picker treats a `null` measured rate as fast enough (`measured != null && measured < required`), so a drive whose probe is still running, or failed, is offered without a speed check.
- **Fix:**
  - Give the cubit the requirement (`requiredBytesPerSecond`, or the headroom rule).
  - Have `_canRecordTo` require a measured rate at or above it.
  - Treat `null` as "measuring" (disabled, with a line such as "Checking the drive…") rather than as fast.
  - Test: a drive that appears unmeasured is not chosen until its probe lands, and is never chosen if the probe is too slow.

### 2. Medium (owner rule: Spanish must be complete): eight more English-only strings

This branch adds eight keys to `app_en.arb` and none to `app_es.arb`, on top of P5's 33 (usb-p5 delta, Finding 1), so 41 are missing in all:

`perfStoppedVolumeLost`, `perfArmDriveUnavailable`, `saveTo`, `saveToUnsupported`, `saveToTooSlow`, `connectUsbTitle`, `connectUsbBody`, `connectUsbTryAgain`.

Add them in rioplatense Spanish, and add a test or CI check that `app_es.arb` has every key in `app_en.arb`.

### 3. Medium: a recording lease leaks when `arm` throws, which blocks eject and shutdown

- **Where:** `PerformanceRecorderCubit.toggleArm`. `_armTarget` takes the lease, then `await _performance.arm(...)` can throw (for example `Directory(dir).create` on the drive, or the arm-snapshot write). The release on `armedDirectory == null` is skipped, because it sits after the `await`.
- **Probe** (a temporary test, removed):
  - Put a file at `<mount>/Segno`, so the bundle directory cannot be created.
  - `toggleArm()` threw `FileSystemException`. `armedDirectory` was null. `storage.leases` still held `recording` on generation 1.
  - Choosing Internal and arming again did not release it: `_armTarget` returns early for Internal.
- **Impact:**
  - The drive reads "in use for recording", and Eject is disabled.
  - `transferInFlight` stays true, so power-off says "Wait for the transfer".
  - This lasts until a later take finishes or the app restarts, with nothing to wait for.
  - A full or read-only-on-error FAT stick is a realistic trigger. The exception also escapes `toggleArm` unhandled.
- **Fix:** wrap the arm in `try { … } catch { _releaseLease(); rethrow / emit a refusal }`, and release a stale lease at the start of every arm, Internal included. Add the probe as a test.

### 4. Low-Medium: an unreported recording lease leaves the table blind to the USB finalize

- **Where:** #1221's follow-up releases the `capture` guard as soon as `perfDisarm` succeeds. The recording lease is held until `done`. While `_finalize` runs, which on a USB take converts `master.pcm` and every input to WAV on the stick (minutes of writing for a long take), the guard table sees no operation on that volume.
- **Today** this is covered elsewhere: Eject is refused by the local lease check, and power-off by `transferInFlight` plus the recorder's `Finalizing` state.
- **The risk:** #1198 Part 12 is meant to make restart and update install go through the table. If an update restart relies on `enter(restart)` alone, it will be allowed mid-finalize and cut a USB take's WAV.
- **Fix (any one):**
  - The performance repository swaps `capture` for a `transfer` guard on the take's scope for the finalize, released in `finally`. This is the cleanest.
  - Keep `capture` until finalize completes for a removable scope.
  - `activeOperations` reports a recording lease as `transfer` once its take has disarmed.

### 5. Low: the pedal records to Internal whatever Save to says

- **Where:** `ControlCubit._togglePerformanceRecordAccepted` calls `_performance.arm(chains: …)` directly, with no root or scope. The plan's "as built" records this.
- **Scenario:** once #1198 Part 13 mounts `RecordingSaveTo`, the player sets Save to `SEGNO USB` and arms from the pedal. The take goes to Internal, holds no lease, and the drive stays ejectable. Nothing says the Save to choice was ignored (rule 3).
- **Today:** nothing mounts `RecordingSaveTo`, so no one can choose USB yet; that is why this is Low.
- **Fix (rule 4):** one arm path. The pedal calls the recorder cubit's arm (or a shared arm service that reads the destination and takes the lease), so both honour Save to.

### 6. Low: a chosen drive that goes falls back to Internal silently

- **Where:** `RecordingDestinationCubit._onVolumes` resets the destination to Internal when the chosen drive is pulled, ejected or remounted read-only.
- **Consequence:** the recorder's `driveUnavailable` toast fires only in the race where the drive goes between the cubit's event and the press. In the common case the next take arms on Internal with no notice.
- **Fix:** when the fallback happens, set a one-shot `fellBack` (with the drive's label), and show "SEGNO USB was removed. Save to is Internal." as a toast, or as a line under Save to. Pen 48 has no copy for this; write it back.

### 7. Low: the storage service's guard wiring has two gaps

- **`guards` is optional again** on `StorageRepository` ("null checks nothing"). That reintroduces the private-fallback pattern #1221 removed from every other owner (its earlier L4).
- **The source is registered only in one place.** It is attached only when `runSegno` builds the registry itself, through the `_LateOperations` closure. `main_mock` injects its own `GuardRegistry()` without the source, so in mock builds the table cannot see copies or ejects. `App`'s fallback repository is not a source of `widget.guards` either.
- **Fix:** let an owner register itself with `GuardRegistry.addSource(this)` in its constructor, and make `guards` required. That also removes the late-initialization closure.

### 8. Low: `acquire` can now throw `GuardRefused`, which `copyFile` and `withWriteLease` do not document or type

- **Where:** `copyFile` promises typed `StorageFailure`s. A refusal by a shutdown or a take now escapes as `GuardRefused`.
- **Fix:** catch it in `copyFile`/`withWriteLease` and map it to a `StorageFailure` variant (for example `busy(kind)`), or document it on both.
- **Related:** the Storage page shows any refused eject as "Could not eject. The drive is still connected. Try again." It should use the `operationBusy(kind)` words #1221 added.

## The question about eject on drive A refusing eject on drive B

**Confirmed, and it is a scope bug, but in D8 rather than in #1221's transcription.**

- **Probe:** drive 1's eject is taken by the helper and runs past the 2-minute cap (unanswered). An eject of drive 2 then throws `GuardRefused(GuardKind.eject, blocked by [eject @ removable(1)])`. Drive 1 still reads `ejecting`.
- **Where it comes from:** D8's eject row has "refuse" in the eject column, and #1221 transcribed it faithfully as `_r` (plain refuse) rather than `_v`.
- **Why per-volume is right:**
  - Two drives' ejects do not conflict. The helper already serializes its own work under its lock, with a bounded wait.
  - The repository's single in-flight `_eject` keeps one request in the app at a time anyway.
  - The only thing the global cell adds is the harmful case: an unanswered eject, which can last until drive A is pulled, blocks every other drive's eject indefinitely.
- **Fix:**
  - Change D8's eject/eject cell to "refuse (same volume)".
  - Change `_table[eject][eject]` to `_v`, and the `_d8` literal to `v a a v v a a r`.
  - Add a repository test that drive 2 ejects while drive 1 is unanswered.

## Notes

- **Pen 48:**
  - The remaining-time example is "60:45:49 remaining" while the plan's criterion now reads 60:45:50. 218750 s is 60:45:50 exactly with the 1 GB reserve, so the pen's last digit is the stale one: a write-back.
  - The pen has no tile for a drive with a reason line (read-only, unsupported, too slow) or for the `driveUnavailable` toast; those are write-backs too.
- **Not reachable yet:** `RecordingSaveTo` is not mounted anywhere until #1198 Part 13, so every take still goes to Internal. Findings 1, 5 and 6 bite then, which is the right time to fix them, but before Part 13 lands.
- **`volumeLost` on a real pull:** recovery of the take's parts is #1198 Parts 9 and 10, as the plan says. The completion state after a pull refers to a bundle that is no longer reachable; make sure the completion sheet offers no action on it.

**Verdict:** Request changes, for Findings 1, 2 and 3. The guard registration, the per-take lease and `volumeLost` are otherwise sound and well tested. The eject/eject cell should change in D8 and #1221.

## Delta review (2e0797ab0), PR #1267

Model: Claude Opus (subagent), in-session

**Scope:** P6 rebuilt on P5 at 6f3ac7cfd. The review commits are 51a5a1f99 (Spanish), 43c18fb61 (measured drives, lease release, finalize guard, fallback toast) and 2e0797ab0 (guards required, `busy`, the pedal noted in the plan). Worked in a temporary worktree, removed afterwards.

**Runs:**

| Suite | Result |
| --- | --- |
| App | 3524 passed, 65 skipped |
| `performance_repository` | 139/139, lcov 611/615 (CI floor 99%) |
| `operation_guards` | 73/73, lcov 60/60 |
| `storage_repository` | 86/86, but lcov **393/395** (Finding A) |
| `dart analyze --fatal-infos lib test packages` | no issues |
| `bloc lint` | 0 issues in 887 files |
| Spanish completeness test | passes; fails, naming the key, when one Spanish key is removed |

I also ran one probe (Finding B).

### Earlier findings

| # | Now |
| --- | --- |
| 1 Medium: unmeasured or too-slow drive chosen | **Fixed** (see below). |
| 2 Medium: eight Spanish keys | **Fixed.** All eight are present, plus the two new keys (`saveToMeasuring`, `saveToFellBack`); no key is missing and placeholders match. |
| 3 Medium: lease leaked on an arm throw | **Fixed for an arm that fails before it publishes**, as in my earlier probe. A new gap appears when the arm publishes and then throws; see Finding B. |
| 4 Low-Medium: table blind during the USB finalize | **Fixed.** A take on a drive keeps its `capture` guard through `_finalize`, released in `finally`; a take on Internal releases it first, as #1221 did. Restart and eject therefore stay refused while the WAVs are written to the drive. A `transfer` guard would refuse less (a device change has no reason to wait for file work), but this is correct and safe. |
| 5 Low: pedal ignores Save to | **Recorded.** The plan says the pedal must arm through the recorder before #1198 Part 13 mounts Save to. Acceptable while nothing mounts it. |
| 6 Low: silent fallback to Internal | **Fixed.** See below. |
| 7 Low: guard wiring gaps | **Fixed.** See below. |
| 8 Low: untyped `GuardRefused` | **Fixed.** See below. |

How each fix was checked:

- **Earlier 1, measured drives.** `RecordingDestinationCubit._canRecordTo` now requires a measured `writeBytesPerSecond` at or above twice the frozen rate (`headroom` lives in one place, on the cubit). `awaitDrive`, the awaiting path in `_onVolumes`, and `choose` all go through it. The picker shows an unmeasured drive as "<label> · checking the drive…", disabled. A drive that appears unmeasured is no longer chosen by the Connect USB sheet.
- **Earlier 6, fallback.** `fellBackFrom` is set for exactly the one state in which the chosen drive went. `App` listens and shows a warning toast: "SEGNO USB was removed. Save to is Internal." ("Se quitó SEGNO USB. Guardar en ahora es Interno."). An unnamed drive uses "Unnamed drive". `choose` and `awaitDrive` clear it.
- **Earlier 7, guard wiring.** `guards` is required on `StorageRepository`, which calls `guards.addSource(this)` in its constructor. The `_LateOperations` closure in `run_segno` is gone, and `main_mock`'s table and `App`'s fallback repository now see the storage service.
- **Earlier 8, `busy`.** A table refusal in `acquire` becomes `StorageFailure.busy(kind)` (`StorageBusy`), so `copyFile` and `withWriteLease` keep their typed contract. A refused eject shows `operationBusy(kind)` instead of "Could not eject".

### New findings

#### A. Medium: CI's `storage_repository` job requires 100% coverage, and this head has 393/395

- **Where:** `packages/storage_repository/lib/src/models/storage_failure.dart:92-93`. `StorageBusy.props` and `StorageBusy.toString` are never executed. `.github/workflows/main.yaml` runs the package with `min_coverage: 100`.
- **Effect:** the coverage step goes red, so the PR cannot reach `ready-to-merge`.
- **Fix:** in `models_test.dart`, assert `StorageFailure.busy(GuardKind.capture)` equals itself and differs from `busy(restart)` (this covers `props`), and check its `toString`.

#### B. Low-Medium: an arm that publishes and then throws drops the lease while the take records on the drive

- **Where:** `PerformanceRecorderCubit.toggleArm`'s new `on Object` around `_performance.arm(...)`, which releases the lease and emits `Idle(driveUnavailable)` for any throw on a USB target.
- **The path:** `PerformanceRepository._armGated` also throws after it has armed. If writing `arm-snapshot.json` fails, it sets `armed` and rethrows (`performance_repository.dart:492-495`); the failed-cancel paths do the same (`:523-524`, `:536`). The capture is then live on the drive.
- **Probe** (a temporary test with an engine whose `perfArm` puts a directory at `arm-snapshot.json.pending`):
  - `armedDirectory` was on the USB drive.
  - `storage.leases` was empty.
  - The cubit ended in `PerformanceRecorderArmed` with `volumeLabel: null`, after first emitting `Idle(driveUnavailable)`, which shows the "Recording didn't start" toast.
- **Consequences:**
  - The take records on the drive while the player was told it did not start.
  - The readout does not name the drive.
  - The Storage page shows no "in use for recording".
  - Pulling the drive does not end the take as `volumeLost`, because no lease is held. The drive is still protected from Eject by the capture guard.
- **Fix:** in the catch, keep the lease and rethrow (or let the status stream drive the state) when `_performance.armedDirectory != null`. Release and emit `driveUnavailable` only when nothing armed. Add the probe as a test.

### Notes

- **A probe that failed reads "checking" forever.** The helper writes `writeBytesPerSecond: null` when its probe fails, so such a drive reads "checking the drive…" indefinitely and can never be chosen. Refusing it is right. A distinct line ("couldn't be tested") would say why.
- **No way to unregister a source.** `addSource` has no matching `removeSource`, so a disposed `StorageRepository` stays a source of a table that outlives it. That is harmless (a disposed repository holds no leases), but `dispose` could unregister for tidiness.
- **With no engine rate**, the picker has no requirement and offers an unmeasured drive, while `choose` (requirement 0, but measured still required) refuses it silently. Only reachable before the engine starts.

**Verdict:** Request changes, for Finding A (CI coverage, a two-line test). Finding B should be fixed in the same pass. Every earlier finding is fixed or recorded.
