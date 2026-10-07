Model: Claude Opus (subagent), in-session

# Review of `claude/backing-1200-p4` (8f9bcba92): feat(backing): backing_repository, the managed asset store and the player (#1200 Part 4)

## Scope

- **Head:** `8f9bcba92`, two commits on P3 `3f42d99d0`: `510cba959` and `8f9bcba92`. 15 files, +1,933 lines.
- **The new package `packages/backing_repository`:**
  - `BackingAssetStore`: content-addressed `Backing tracks/<16 hex>/<name>` plus `info.json`, the full `sha256:` digest, a probe at import, and resolve re-digesting before every load;
  - `BackingRepository`: tokens to digests, load and stage generations, one NOT_READY retry, a re-decode when the rate changes under a decode, epoch replay and reload, the interface-changed notice, a 20 Hz poll only while busy;
  - the models;
  - a CI job.
- **Reviewed against:**
  - the plan at `519107563`: D2, D7, D10, Part 4 and its build record;
  - AGENTS.md;
  - the owner rules.
- **Pen:** not read. This part has no UI.

## Runs

- `backing_repository`: 35 tests, all passed, with coverage. P5's head runs 38.
- `segno_engine`: 404 passed.
- `dart analyze --fatal-infos lib test packages`: clean.
- `bloc lint lib test packages`: 0 issues.
- **Probe test** (`repro/store_repair_probe_test.dart`, run in the package and then removed): import, corrupt the managed copy, resolve, re-import the original, resolve again. The result is in M1.
- **Merge:** like the whole stack, the head conflicts mechanically with trunk `890f04936` (see P3 L3).

## Verified correct (traced)

**Import never leaves a half asset.**
- Import runs these steps: digest the source, copy into `<id>/<name>`, probe the copy (no PCM kept), check the copy's digest against the source's, write `info.json` as `.part`, then rename and sync the directory.
- Any failure deletes the asset directory.
- An unreadable `info.json` lists the asset as damaged, never as available.
- Directories that do not look like 16-hex ids are ignored, so a stray folder never lists.

**Identity is checked at load.** `resolve` re-digests the bytes before every load, and a mismatch is `damaged` (D7). An id-prefix match with a different full digest is `missing`, never matched by name.

**Load lifecycle.**
- A later `load`, `stop`, `clear` or `dispose` bumps the generation.
- A decode that finishes after that is disposed. Its failure is not reported, because `current()` gates it.
- The engine's token is recorded only on an ok hand-over.
- A rate change under a decode (`invalid` with `audio.sampleRate != _rate`) decodes once more, then gives up as `busy`.

**Restarts.**
- The epoch is compared on every `refresh`. The settings are replayed (End, level, pan, output, and in P5 the click pan).
- A file the engine no longer holds is reloaded stopped, and so is the stage.
- A file kept by a retained reopen is not decoded again.
- The notice is sent only when something was playing (D10).

**Token pruning keeps a token the engine has not applied yet.** Pruning is by age (16), never by what the engine reports.

## Findings

### Medium

**M1. Re-importing the original does not repair a damaged managed copy, so a damaged asset has no recovery path.**
- **Where:** `backing_asset_store.dart:97-100`. When the asset directory exists and `info.json` names the same digest and the file exists (`available`), `import` returns the existing asset without checking the stored bytes.
- **Reproduced:**
  1. Import `Song.wav`.
  2. Overwrite the managed copy (bit rot, a stray write).
  3. `resolve` → `BackingFailure(damaged)`.
  4. Re-import the original from the USB drive: it returns the existing asset, with no copy.
  5. `resolve` → `damaged` again.
- **Failure scenario:**
  - A prepared item shows "Couldn't play …: damaged". The performer does the obvious thing and adds the file again from the drive. Nothing changes, and the item stays unplayable.
  - #1198's Part 15 repair row ("Find audio", matched by this plan's digest) imports the found file. It hits the same early return, so it cannot repair either.
  - This breaks rule 2: no recovery path.
- **Fix:** before returning `existing`, digest its file (`_digester(existing.path) == hex`). On a mismatch, fall through to the replace path, which deletes the directory and copies afresh. Add the probe above as a test.

### Low

**L1. The single NOT_READY retry waits a fixed 25 ms, which can be shorter than the transit it waits for.**
- **Where:** `backing_repository.dart:150-157`, with `retryDelay` defaulting to 25 ms.
- **Mechanism:** NOT_READY lasts until the callback has applied the post and the 5 ms fade has finished and returned the buffer. That is up to two device blocks: about 43 ms at 1024 frames and 48 kHz.
- **Scenario:** a second NOT_READY becomes `BackingFailure(busy)`. The decode (seconds, at 96 kHz) is thrown away and the performer is told the file could not play.
- **Fix:** wait one `bufferFrames / sampleRate` period plus the ramp from the snapshot, or retry a bounded number of times, for example five at 10 ms.

**L2. `EngineResult.invalid` reads as "damaged" for refusals that are not about the file.** `BackingFailureReason.fromEngine` maps `invalid` to `damaged`, so a full command ring (`le_push_cmd`) or a foreign payload is reported as a damaged file. A rate change is handled separately. Map the hand-over's `invalid` to `busy`, and keep `damaged` for decoder and digest results.

**L3. Every refresh takes a full engine snapshot just to learn the rate.** `_rate` is `_metering.snapshot().sampleRate`, read on every refresh: 20 Hz while playing, and several times per action. The snapshot is the whole `le_engine_get_snapshot` copy. Use `BackingState`, or cache the rate and refresh it on the epoch change.

**L4. Concurrent imports of the same bytes share one directory.** Two `import` calls for one digest (a double tap, or `Add to prepared` and `Use as backing` together) both pass the existence check and copy into the same `<id>/` directory. If one fails, its cleanup deletes the directory under the other. Callers serialise today only by UI flow. Serialise `import` per digest inside the store, for example with a map of in-flight futures.

## Notes

- **The fake copier has no path check.** The store builds `<id>/<name>` from a name the caller can pass. P5's internal copier refuses `.` and `..` segments, so the shipped path is safe.
- **The plan's Part 4 test list is covered,** including the `Backing tracks` directory never being listed as a capture (`performance_repository_test.dart` in this package).

Verdict: Request changes (M1).

## Delta review (908da2250, PR #1243)

Model: Claude Opus (subagent), in-session

### Scope

- **Stack:** rebased onto trunk `890f04936`. P4 is now `bc6eaff7a`, `4cfa84de8` and `908da2250`, on P3 `6c805c42d`.
- **The fix commit `908da2250`** (6 files, +167/−16) answers M1 and L1 to L4:
  - the store re-digests an existing copy before reusing it;
  - imports of one digest are serialised;
  - NOT_READY is retried up to 8 times, 10 ms apart;
  - a hand-over refusal maps through `ofHandover`, never to `damaged`;
  - the engine rate is cached, and re-read on an epoch change, while it reads 0, and on an `invalid` hand-over.
- **P3 changes I did not review in full:** P3's `6c805c42d` also answers P3 L1 and L2. The mock now keeps its buffers on a retained reopen, and a `NativeFinalizer` guards a dropped decode. I only noted them here.

### Runs

- `backing_repository`: 37 passed and 1 skipped with no library. With `SEGNO_ENGINE_LIB` set on the P5 head (this commit plus P5's repository changes), 41 passed, including the native repository test.
- The first review's probe (`repro/store_repair_probe_test.dart`), re-run on `908da2250`:
  - `resolve` after rot gives `damaged`;
  - the re-import copies again (2 copier calls);
  - `resolve` after the re-import gives OK.

  The damaged copy is repaired.
- On the P5 and P6 heads:
  - `dart analyze --fatal-infos lib test packages`: clean;
  - `bloc lint lib test packages`: 0 issues.
- `git merge-tree` against the current trunk `787d51db6`: the stack conflicts (see the reply).

### Verified correct (traced)

- **M1, the repair.** An existing copy is reused only when `_digester(existing.path) == hex`. Otherwise it is deleted and copied afresh, so re-importing the original repairs it. The new test also pins that an intact copy is still reused without a copy.
- **L4, serial imports.**
  - `_importing[hex]` chains each import after the previous one for the same digest, through an error-swallowing `then`, so one failure does not fail the next.
  - The entry is removed only if it is still the same future.
  - The new test runs three concurrent imports (two names) and expects one copy, one digest and the first name.
- **L1, the retries.** Up to 8 retries at 10 ms give 80 ms. That covers the transit, two device blocks: 43 ms at 1024 frames and 48 kHz. Each wait re-checks `current()` and `_disposed`, and disposes the decode when superseded.
- **L2, the reason.** `ofHandover` maps `capacity` to `noMemory`, `notRunning` to itself, and everything else to `busy`. A decode that succeeded can no longer read as `damaged`.
- **L3, the rate.**
  - The rate is read once at construction, re-read while it reads 0, re-read on every epoch change in `_refresh`, and re-read on an `invalid` hand-over before deciding to re-decode.
  - Any rate change needs a configure, which bumps the epoch. The one window before the next refresh is covered by the `invalid` re-read.

### Findings

#### Low

**L5. The retry window still assumes small device blocks.**
- 80 ms covers two blocks up to about 1,700 frames at 44.1 kHz.
- An interface run at 2048 frames or more (two blocks are 93 ms at 44.1 kHz) can still exhaust the retries, report `busy`, and throw the decode away.
- The appliance does not run that large, so this is a corner.
- **Fix:** derive the wait from the snapshot's `bufferFrames` and rate, which are already read on restarts, for example `max(10 ms, 2.5 blocks / 8)`.

### Verdict

Approve. M1 and L1 to L4 are resolved, and the repair is verified with the original probe.
