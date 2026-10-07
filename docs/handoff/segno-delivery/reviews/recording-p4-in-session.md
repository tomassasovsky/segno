Model: Claude Opus (subagent), in-session

# Review of `claude/recording-1198-p4`: #1198 Part 4, durable two-slot checkpoints and the Internal mirror

## Scope

- **Branch:** `claude/recording-1198-p4` at 200c44a07, one commit (23 files, +1264/−51), on top of P3's a74bde1d8.
- **PR:** none exists yet. One is needed, against `claude/recording-1198-p3`.
- **Autonomy:** per the plan's §6, `merge-gate`, plus `blocked-verify` for the power-cut criterion. The HARDWARE criterion (20-minute takes on Internal, exFAT and FAT32 with checkpoints running; a power cut at minute 10) is not verifiable here.
- **What the part contains:**
  - `perf_checkpoint.c`/`.h` (the slot writer);
  - the checkpoint thread and the published-progress block in `perf_drain.c`;
  - `mirror_dir` and `checkpoint_ms` on `le_perf_target`;
  - `perf_checkpoint_failures` on the snapshot;
  - Dart `PerfTarget.mirrorDir`/`checkpointMs` (default 5000) and `perfFailedCheckpoints`;
  - the manifest-format doc.
- **Reviewed against:** plan D4 and Part 4 (`claude/recording-recovery-plan-1198` 3223c726e), AGENTS.md and the owner rules.

## Runs

| Suite | Result |
| --- | --- |
| Native, plain ×3 (own TMPDIR each) | green |
| Native TSAN races | green |
| Native ASan | green |
| Native, telemetry off | green |
| `segno_engine` with `SEGNO_ENGINE_LIB` | 384/384 |
| `performance_repository` | 132/132 |
| `session_repository` | 189/189 |
| `wav_codec` | 7/7 |
| App suite | 3475 passed, 56 skipped, 0 failed |
| Scoped `dart analyze --fatal-infos` | clean |
| `bloc lint lib test packages` | 0 issues |

**Cross-format probe** (`scratchpad/rvp2/p4-slot_probe.c`):

- A real take on the P4 engine (two streams, 1000-frame parts) left a final slot (sequence 1, three sealed parts per stream).
- #1227's Dart `TakeCheckpoint.fromSlot`, with a real SHA-256 in place of its tests' FNV stub, parses it: 2 streams, 3 parts each, all sealed.
- A one-byte flip fails the checksum.
- So the native writer and the Dart reader agree on the covered bytes (everything before `"checksum"`, indentation included), the part numbering and the field types.

**Disk-full probe** (`scratchpad/rvp2/p4-full_probe.c`):

- **Setup:** a 4 MB FAT image mounted with `hdiutil` as the capture volume, an Internal mirror and sidecar, `checkpoint_ms` 1000, and a paced 48 kHz producer until the volume fills.
- **Result:** Finding 1.

**Mutations:**

- **Killed (3):**
  - progress published before the flush (`test_perf_checkpoint_never_ahead_of_the_flush`, the on-every-stop test);
  - flipping to the other slot after a failed write (`test_perf_checkpoint_failure_keeps_the_other_slot`);
  - no checkpoint request after a self-stop (the on-every-stop test).
- **Survived (1):** skipping every data `fdatasync`. That is expected: durability is invisible without a power cut, and it falls under the HARDWARE criterion.

## Verified correct (traced)

1. **Lock scope.**
   - `progress_lock` is held only for a struct copy: in `le_pd_publish_progress` (`perf_drain.c:1855`), on the drain thread, and in `le_pd_checkpoint` (`:1887`), on the checkpoint thread.
   - `write_lock` is held across the whole checkpoint write (syncs and slots), but the drain never takes it. Only the checkpoint thread and the test hook do, and they nest `write_lock` then `progress_lock`, so there is no lock-order inversion.
   - The drain never waits on a device sync.
   - The sealed list and the layer manifest are append-only, and the counts published under the lock give the checkpoint thread a happens-before edge to every entry below them, so reading those entries without the lock is safe. TSAN is clean.
2. **Sync order.** `le_pcp_write` makes the data durable first, then the directory, then the slot:
   - sealed parts are synced once each, in order, resuming where a failure stopped;
   - every open part and `events.log` is synced every time;
   - new layer files are synced once each;
   - the take directory is synced.

   Any data-sync failure skips the slot entirely (`if (!ok) return 0`), so a slot never names data that was not synced.

   The slot is then rewritten in place (`O_TRUNC`, write with an EINTR retry, `fsync`), and the directory is synced the first time each slot file is created. The mirror slot is written second, from the same bytes, followed by a mirror directory sync. No `rename` touches the take directory (the interposer test).
3. **Torn-slot fallback.**
   - `sequence` and `next_slot` advance only after the take's own slot is written, so a failed write is retried on the same slot and the other slot keeps the last good sequence. A truncate that tears the slot only damages the one being replaced.
   - A failed mirror write counts as a failure but does not undo the take's slot.
   - Readers take the valid slot with the higher sequence. The tests flip a byte; the Dart reader in #1227 does the same and agrees with this format (probe above).
4. **Final checkpoints on every stop path:**
   - **disarm** (`le_perf_drain_stop` joins the drain's final pass, then sets `cp_stop` and joins the checkpoint thread, which writes on its way out, `:2372`);
   - **self-stop** (the drain thread requests `cp_now` after its final pass, `:2228`, so the stop is durable before any disarm);
   - **device change** (the same `le_perf_drain_stop` path).
5. **`perf_checkpoint_failures`** is reset at arm and incremented on any failed sync or slot write, and a failure never stops the take.

   The progress copy on the drain thread is a stack struct (about 1.3 KB), and the 1 MiB slot buffer is allocated once per take, so the drain cycle stays allocation-free (the existing allocator test passes).

## Findings

### 1. High: after a failed write, the checkpoints claim audio the volume never received

- **Where:** three places, which compound.
  - **(a) Progress is published even when the cycle failed.** `le_pd_publish_progress(d)` (`perf_drain.c:2126`) runs unconditionally after the flush block. When a write failed earlier in the cycle, `ok` is 0 and the flush is never attempted, yet the progress publishes `pf->part_frames` and `pf->written`, which include frames still sitting in the stdio buffer.
  - **(b) A failed seal is still listed as sealed.** `le_pd_seal_part` (`:1278`, from P2) appends the part to the sealed list with its frames and SHA-256 even when `le_wav_seal` failed (its `fflush` returns ENOSPC). The checkpoint then lists the part as sealed with a digest over bytes that never reached the file.
  - **(c) The open parts are published at the start** (`:2331`) with their 84-byte headers still in the stdio buffer, before any flush. That is mostly harmless, but it contradicts the "only after the flush" contract.
- **Probe (real ENOSPC, a 4 MB FAT image, mirror on Internal, interval 1 s).** The take stopped with reason 3 (`disk_full`), `perf_checkpoint_failures` 0.

  | | master | input 0 |
  | --- | --- | --- |
  | On the stick | 2,123,860 bytes = 265,472 frames, RIFF size 0, data size 0 (unsealed) | 1,994,836 bytes = 249,344 frames, unsealed |
  | Both checkpoint slots (sequence 9 and 10, stick and mirror) | sealed, 278,272 frames, 2,226,260 bytes, with a `sha256` | the same |
  | Sidecar | `capture_frames: 278272`, both parts listed sealed with `sha256` | the same |

  So the record recovery trusts claims 12,800 and 28,928 frames the files do not hold, and digests that cannot verify. The streams on disk are also unequal, which contradicts "every stream ends at the same frame". The doc this part adds says "`frames` per part is what the device is known to hold".
- **Why it matters:**
  - D4 makes the checkpoint the record recovery trusts. The mirror is authoritative for a USB take (Part 10), and for a pulled stick or a power cut recovery trusts only the checkpoint.
  - The criterion "a checkpoint never names more frames than the drain had flushed" is tested only on the success path.
  - A write failure (ENOSPC from another writer, EIO, a pulled stick) is exactly the case where recovery reads the checkpoint. Part 8 will either truncate a file "to" more frames than it has, or reject the take because its digests fail. Rules 2 and 3 are both broken.
- **Fix:**
  - Keep a per-stream "flushed" count (open part index, frames and overs, and for the take a sealed count) updated only after a successful `le_pd_flush`, and publish only that.
  - In `le_pd_seal_part`, list the part as sealed only when `le_wav_seal` returned 1. Otherwise leave it as the open part, at its last flushed frames, for recovery to measure.
  - Publish the start-time progress with zero frames, or only after the first successful flush.
  - Add the never-healed variant of the short-write test with checkpoints on, asserting that the newest slot's frames ≤ the bytes on disk, and that no `sha256` is given for a part whose seal failed. The sidecar's `capture_frames` should take the same flushed count.

### 2. Low: the TSAN job never exercises the drop path

- **Where:** `drop_race` in `test_perf_drain_races.c`, carried from P3.
  - Under `-fsanitize=thread` the producer reaches only about 25k to 120k frames/s (60k to 310k frames in 2.5 s). All six runs, on P3 and on P4 alike, ended with `first drop 18446744073709551615` (no drop) and reason 1.
  - The plain, ASan and telemetry-off runs do drop at many mid-cycle frames, so the functional check holds. But the memory-ordering check of the drop store against the drain's acquire is never run under TSAN.
- **Fix:** under TSAN, configure the race at a low rate (for example 8000 Hz) or with smaller rings, so the slower producer still overflows. Or assert in the TSAN build that at least one run dropped.

### 3. Low: a disarm now waits on the device

- **Where:** `le_perf_drain_stop` joins the checkpoint thread after its final checkpoint, and that checkpoint syncs every open part and the directory, all on the caller's thread. The caller is `le_perf_disarm`, reached from the app's isolate through FFI.
- **Impact:** on Internal storage, with checkpoints every 5 s, there is at most about 5 s of dirty data, so the wait is short. On a slow stick (Part 10) it can take seconds.
- **Fix:** record the expected wait in the plan's Part 10. Or, since the self-stop path already writes its final checkpoint on its own thread, let the disarm request the final checkpoint and join it from the repository off the UI isolate.

### 4. Low: the comment on the file sync says the opposite of the code, and an aborted arm leaves slots in the mirror

- **The comment.** `le_pcp_sync_file`'s comment says "A file that is not there is not an error here", but a failed `open` returns 0, which fails the whole checkpoint. The code is the safe choice; fix the comment.
- **The aborted arm.** When the drain thread fails to start after the checkpoint thread did, `cp_stop` makes the checkpoint thread write a checkpoint of a take that never started into `capture_dir` and `mirror_dir`. The repository deletes the capture directory but knows nothing of the mirror. Skip the write when the drain never ran.

## Notes

- **Slot format compatibility.** The slot format matches #1227's `TakeCheckpoint` (probe above). On macOS `boot_id` is uppercase hex (`kern.bootsessionuuid`), on Linux lowercase. Part 8 should compare them as given, never normalised against a different source.
- **macOS durability.** On macOS `fsync` does not flush the drive cache (`F_FULLFSYNC` would). Under the appliance-only decision that only affects the development host. Worth a line in the manifest doc.
- **Mirror lag.** The mirror is written after the stick's slot, so after a failure between the two it can lag by one sequence. D4's "mirror wins" then picks the older, consistent record, which is safe.
- **Default checkpoint interval.** `PerfTarget.checkpointMs` defaults to 5000, so every production take now syncs every 5 s on Internal. The plan wants that, and the HARDWARE criterion (no zero-fill and no overrun with checkpoints running) is the check that it does not reintroduce #710's stall.

**Verdict:** Request changes for Finding 1. The checkpoint must name only what was flushed, and never list a part whose seal failed as sealed. A PR against `claude/recording-1198-p3` is needed.
