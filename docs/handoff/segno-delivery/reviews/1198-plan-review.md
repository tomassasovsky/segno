Model: Claude Opus (subagent), in-session

# Review of PR #1205: docs(plan): recording to USB, long recordings, atomic publication and recovery

## Scope

- Plan: `origin/claude/recording-recovery-plan-1198` at `0f5a5195c`, `docs/plan/2026-10-06-feat-recording-recovery-plan.md` (issue #1198, 20 parts). The diff is that one file.
- Checked against:
  - the code on the plan's base, and `origin/claude/segno-integration` at `56033baf0`;
  - the Library plan and code on `origin/claude/library-1178-p3` (`2d88d96ce`), including the in-flight save-back fix proposed in `library-p3-in-session/review.md` finding 1;
  - the USB plan on `origin/claude/usb-storage-1177-p4`;
  - `docs/handoff/segno-app/accepted-behavior.md` (AB);
  - AGENTS.md and the owner rules.
- Pen: `segno-ui.pen`, group `01 CURRENT UX`, read through the pencil MCP and not saved. All 33 screen ids cited in the plan resolve, and their copy was compared.
- Linux kernel sources (current master), read for the FAT and exFAT claims: `fs/fat/file.c`, `fs/fat/namei_vfat.c`, `fs/exfat/file.c`, `fs/libfs.c`.

## Runs

- `git merge-tree` of the branch against trunk `56033baf0`: clean. CI on PR #1205 is all green.
- `npx cspell --config .github/cspell.json` on the plan: 0 issues.
- The plan is documentation only, so no Dart or native suite exercises it. I traced the cited code paths instead, as listed below.
- Pencil MCP: text dumps of D9QbI2, vjohm, E7kQV, Xcpyh, dgedL, owAnd, X4UXKN, yzmtU, T8ACW, cH9UX, FwjUV, HWH3p, Z3V6Z, HfLgr, DEY0v, KNzYO, l3bgeK, K48Hse, v7zSCN, gtG0I, qLXt5, iEuYw, TNFh0, I8foz, UOyKO, D3Rij, WZvK8, GwDUd, v5FPjK, b28GI1, w9WB8, sra8u and LaqVi.

## Verified correct (traced)

- **D3 arithmetic.** `(2,000,000,000 − 84) / 6` = 333,333,319 frames, which is 1:55:44 at 48 kHz. A full part is 1,999,999,998 bytes. Part 5's 10,499,999,552 frames for 63e9 bytes is right (31 parts plus 166,666,663 frames). Part 2's 6084 / 6084 / 3084-byte parts are right.
- **Sample oracles.** `le_f32_to_native` / `le_write_le_int` (`engine_convert.c:58-75`) scale by 8388608, clamp to 8388607 and round half away from zero. That gives exactly the bytes Parts 2 and 5 assert:
  - 0.5 → `00 00 40`
  - −1.0 → `00 00 80`
  - 1.0 and 2.0 → `FF FF 7F`
  - −0.25 → `00 00 E0`
- **First-drop protocol (Part 3).**
  - The drop sites are `perf_push_master` (`engine_process.c:4133-4139`) and `perf_tap_monitor_frame` (`:4288-4293`). Each ring push is all-or-nothing per frame.
  - `perf_frame_base` already exists per block (`:6353-6354`), so `base + f` needs only the frame index passed into the two helpers.
  - The audio thread is the single writer, its store is sequenced before the release add of `a_perf_frames` (`:6875-6879`), and the drain reads `elapsed` with acquire. So when the drain sees a drop, it also sees every frame before it.
  - No ring dropped before F, so each ring's first F frames are exactly frames 0..F−1, and truncating every stream at F is sample-aligned.
  - The extra audio-thread work is one relaxed load and at most one store per take. That is RT-safe.
- **Ring memory is prefaulted off the audio thread.** `le_audio_ring_alloc` mmaps with `MADV_DONTFORK` and memsets the buffer on the arming thread (`audio_ring.c:28-74`). An 8 s ring adds no audio-thread faults (see L6 for its size).
- **fsync on FAT and exFAT persists what D4 needs.**
  - vfat: `fat_file_fsync` runs `simple_fsync_noflush` (data plus the inode metadata, which on FAT is the directory entry's size and start cluster), then `mmb_sync` of the FAT table, then a device flush.
  - exFAT: `exfat_file_fsync` syncs the whole block device and flushes.
  - Both filesystems wire `.fsync` for directories, so `le_fs_sync_dir` (open with `O_DIRECTORY`, then `fsync`) works on USB.
- **Boot salvage scope.** `findUnfinalized` (`performance_repository.dart:601-618`) only considers directories with `performance.json`, and `recoverCapture` is `_finalize`. Part 2's "keep `_finalize` working" covers crash salvage between Parts 2 and 8.
- **Pen ids and copy.**
  - Every id resolves, and the quoted strings match: `52:45:49 remaining`, `5 file parts · One take`, `1. 1:55:44`, the yzmtU, HWH3p and dgedL copy, `Range positions are kept…`, `5 routes updated` and `3 assignments updated`.
  - The pen's HfLgr ("Same duration and format") does conflict with AB 6.10 as D7 says. AB 6.10 ("Same name is not enough", exact identity) is the later and stricter rule.
- **AB 6.9 reading.** AB 6.9 lists "expression ranges, musical MIDI assignments" as recalled, so §8 Q2 and #1206 read it correctly. The Library plan's §6 reads it the other way (see L1).

## Findings

### High

**H1. 24-bit parts hard-clip the master; D3's "the master is post-limiter" is false.**
- **Where:**
  - D3 "Encoding" ("Float samples are clamped to [-1, 1] … No dither: the master is post-limiter");
  - Part 2;
  - Part 8 legacy conversion.
- **Fact:**
  - The capture tap is in `output_bus_frame` (`engine_process.c:4175-4206`), whose own comment says it "Runs after every source summed onto the outputs, before the global master gain and limiter". The limiter is in `master_bus_frame` (`:4233-4251`), which runs after the bus loop (`:6771-6777`).
  - The captured master is therefore an unbounded float sum of tracks, live inputs, the click and (with #1200) the backing. Captured inputs are post-FX monitor signals, also unbounded.
- **Failure:**
  - Four loops peaking at −3 dBFS plus a live input sum to about +6 dBFS.
  - The listener hears the limiter shape it; today's float `master.pcm` keeps the overs.
  - Under D3 every over becomes a run of `FF FF 7F` / `00 00 80`: hard clipping that was never heard, with no flag (rule 3).
  - Part 8 then converts legacy float `.pcm` captures to 24-bit and deletes the float originals, destroying existing headroom (rule 1).
- **Fix (owner call, since AB 6.7's baseline says 24-bit):** choose one:
  - (a) write IEEE-float parts (format tag 3, 4 bytes per sample). This changes the part duration the pen shows: 1:55:44 becomes about 1:26:48 at 48 kHz stereo.
  - (b) keep 24-bit but put a capture-path limiter identical to the master limiter, at its ceiling, on the tap, and say so on the page.

  In either case:
  - count clipped samples per stream into the manifest and surface them;
  - never convert a legacy float `.pcm` to 24-bit without a clip scan. Keep float parts when any sample exceeds ±1.0.
- **Criterion to add:** a pumped master at amplitude 1.5 produces a defined, flagged result.

**H2. Same-boot recovery after a USB pull trusts on-disk sizes and can admit stale data.**
- **Where:** D4 "What recovery trusts", Part 8 `recoverCapture`, Part 10.
- **Fact:**
  - The same-boot rule ("every whole frame present in every stream … because the page cache survived") is applied by boot id.
  - A pulled stick is the same boot, but its page cache did not survive: the volume is remounted fresh, and the files are whatever writeback had reached the device.
  - FAT and exFAT have no ordering between data and metadata writeback. A directory entry's size can be on the stick before the data clusters it covers.
- **Failure:**
  - Record to USB, pull at 1:00, reinsert, press Save recovered audio.
  - The open part's size reaches to about 1:00, but its last seconds of clusters hold stale content: old deleted audio, or noise at full scale.
  - Part 8 floors that to whole frames, digests it, seals it and finalizes it as good audio.
  - The pen copy for this exact state (HWH3p) promises the opposite: "The saved checkpoint can be recovered. Audio after it may be unavailable."
- **Fix:**
  - Trust present frames only when the destination stayed mounted for the whole take: Internal, or a removable volume whose `generation` is unchanged since arm.
  - Any take whose volume generation changed, and any recovery driven by a mirror, trusts only the checkpoint.
  - Add a Part 8 or Part 10 criterion: a fake volume detach and re-attach in the same boot truncates to the checkpoint.

### Medium

**M1. tmp + rename on vfat and exFAT is not an atomic replace; checkpoints on the stick rely on it.**
- **Where:** D4 (checkpoint every 5 s), D5 ("Performance takes publish the same way"), Part 4, Part 10 (finalize on the drive).
- **Fact (from `fs/fat/namei_vfat.c`):**
  - vfat's rename over an existing file rewrites the target's directory entry to point at the source's clusters (`vfat_sync_ipos`), then removes the source entry (`fat_remove_entries`).
  - The replaced file's clusters are freed when its inode is evicted.
  - There is no journal.
- **Failure:**
  - In the milliseconds between the rename and the directory fsync, the drain (allocating clusters continuously) can be handed the just-freed clusters. Its PCM writeback can reach the device before the new directory entry does.
  - A power cut there leaves `checkpoint.json` pointing at PCM bytes.
  - exFAT's rename over an existing file writes the renamed entry and deletes the target's entries as separate steps (`__exfat_rename`), so an interruption can leave two entries with the same name.
  - The window is small but recurs every 5 s for hours, and it sits under the plan's stated guarantee ("at most the last 5 s are lost").
- **Fix:**
  - On removable volumes do not rename over anything. Use two fixed checkpoint slots (`checkpoint-a.json` / `checkpoint-b.json`) rewritten in place, each with a sequence number and a CRC, and recover from the newest valid one.
  - Make the Internal mirror (ext4, where tmp + fsync + rename + directory fsync is sound) the authoritative checkpoint for USB takes when it exists.
  - Write the finalized manifest on a removable volume the same way, or add a CRC that the reader checks.

**M2. Remaining time and the 60 s warning ignore captured inputs and the removable reserve.**
- **Where:** D2 "Warning", Part 9 (`recordingTimeRemaining`; criterion pinned at 288000 B/s), USB P4.
- **Fact:**
  - USB P4's criterion says "a removable destination applies no reserve".
  - The drain's budget (Part 3) counts every stream plus `reserve_bytes` plus 1 MiB.
- **Failure A:** master plus two captured stereo inputs at 48 kHz is 864,000 B/s.
  - The page shows three times the real remaining time.
  - `nearlyFull` turns on about 20 s before the stop instead of 60 s.
- **Failure B:** on USB with the master only, the drain stops while the UI still reads about 1:01 remaining (17 MiB / 288,000 B/s). The warning never appears before the stop.
- **Bandwidth requirement:** USB P6's picker uses `requiredBytesPerSecond` = the master rate × 2, so a stick too slow for the master plus inputs is offered.
- **Fix:**
  - One function (Part 5's `RecordingFormat`, extended to the frozen set of streams) computes remaining frames: every stream's bytes per frame, a header per part, the reserve and the allowance.
  - The drain's budget, the page and the picker's `requiredBytesPerSecond` all use it (rule 4).
  - Add criteria with inputs captured and with a removable destination.

**M3. Two atomicity mechanisms for one bundle (rule 4): the Library save-back swap against D5/Part 7.**
- **Where:**
  - Part 7;
  - the Library p3 save-back fix in progress (sibling `<id>.saving/`, rename `<id>` → `<id>.old`, rename `.saving` into place, delete `.old`; `library-p3-in-session/review.md` finding 1).
- **Problems:**
  - The swap's names are not D5's staging names (`.<id>.part/`, `.<id>.deleting/`), so Part 7's sweep does not know them.
  - Between the swap's two renames `<id>` does not exist. A crash there leaves `<id>.old` and `<id>.saving`, and the session vanishes from the catalog: the Library's interrupted-save rule hides such directories, and Part 7's sweep would delete or ignore them rather than restore them.
  - The swap also rewrites every layer on each save, needing twice the session's space mid-save. D5's allocation check ("sum the bytes of the layers it must add") does not model that.
- **Fix:**
  - Part 7 states that it replaces the swap.
  - Until Part 7 lands, the swap uses names the sweep recognises.
  - The sweep gains the rule: `<id>` absent and `<id>.old` present → if `<id>.saving` holds a complete, parseable manifest, rename it in; otherwise restore `<id>.old`.
  - Add a criterion for a crash between the two renames.

**M4. A held USB take whose drive is gone blocks power-off and update.**
- **Where:**
  - D8 (restart row: "finish the take first, then refuse");
  - D9;
  - Part 10 (the capture guard is held while the take is held);
  - Part 12 ("if that fails the shutdown stops on the existing failure face with Retry and no discard shortcut").
- **Failure:**
  - Pull the stick mid-take. The take is held, waiting for the drive, with Save disabled.
  - Power off or Install and restart cannot finish the take, so the UI refuses until that exact stick returns.
  - Yet the take does not need to block: its mirror is durable on Internal, and Part 10 already says boot salvage "skips mirrors whose drive is absent and leaves them".
- **Second contradiction:** the sessionApply row says "finish the take first", while D9 says "A held take survives Open, New loop and restart".
- **Fix:**
  - A held take does not count as an active capture for restart or sessionApply.
  - A take held waiting for a drive needs only its mirror to be durable.
  - Add criteria for both.

**M5. A power cut with the stick still attached has no recovery path.**
- **Where:** Part 10 (`pendingUsbTakes()` lists mirrors "whose bundle is absent from every mounted volume"), and boot salvage (which scans only `exportsRoot`).
- **Failure:**
  - After a power cut with the stick in place, the bundle is present on a volume that mounts asynchronously after the app starts.
  - Neither path offers it.
  - The fault-matrix row "Power cut mid-take → parts recovered" has only a HARDWARE line, no mechanism and no unit criterion.
- **Fix:**
  - At start and on every volume event, each mirror without a finalized bundle becomes `Held(interrupted)`.
  - Bundle present → Save enabled; absent → waiting for the drive.
  - Add criteria for both.

**M6. On FAT the drain sleeps about 100 ms every cycle; D4 keeps the per-cycle sidecar "as it is".**
- **Fact:**
  - `fat_file_release` (`fs/fat/file.c`), on a mount with the `flush` option and a file opened for writing, calls `fat_flush_inodes` and then `io_schedule_timeout(HZ/10)`.
  - USB P1 mounts vfat with `flush`.
  - The drain rewrites `performance.json` by open/write/close plus rename every 250 ms (`perf_drain.c:1283-1299`) and opens and closes each staged layer file.
- **Failure:** on FAT32 every drain cycle sleeps at least 100 ms plus synchronous metadata writes, and does four renames a second in the bundle directory for the whole take. That is the opposite of "the drain cycle never waits on the device". The 8 s ring may absorb it, but it is not measured.
- **Fix:**
  - On a removable target, write the live sidecar only at the checkpoint cadence, or into the Internal mirror directory.
  - Add a criterion counting sidecar writes per minute.
  - Run Part 4's hardware check on FAT32 with `flush`, not exFAT only.

**M7. Library contract changes beyond `listCaptures` are not recorded.**
- **Gaps:**
  - The Library plan's Part 7 `dawPackageFiles` lists `master.wav` and every `live-input-N.wav`.
  - Library D10 says the audition voice "plays its master.wav".
  - From Part 2 on, neither file exists.
- **Fix:**
  - Record in D3 and Part 8 that the DAW package is the ordered `master-NNN.wav` / `input-<n>-NNN.wav` parts.
  - Record that audition reads part 1 through a bounded reader.
- **Rule 4:** after this plan there are three WAV readers: the Library's Part 6b (Dart), this plan's Part 5 `readFrames`, and #1200's native miniaudio decoder. Pick one bounded reader. dr_wav reads 24-bit parts.

**M8. Backing repair rows fall between this plan and #1200.**
- **Pen:** 36 b28GI1, w9WB8, sra8u and LaqVi all draw `Evening lights.wav · Prepared audio · Backing track · Find audio`.
- **The gap:** D7 and Part 15 defer backing rows "with E7-8". #1200 D9 defers backing repair to E7-16, which is this plan. Neither builds the row.
- **Fix:** assign the row to Part 14/15, matching by #1200's asset identity after #1200 Part 5, and record it in both plans.

**M9. Retention (Q1): the default leaves no way to free space.**
- **Facts:**
  - The Library plan's Part 7 has no delete for recordings.
  - #1200 states there is no audio Delete in the accepted design.
- **Failure:**
  - With the 30-day prune stopped, recovered takes and converted legacy captures accumulate on Internal without bound.
  - Once free space drops under the 1 GiB reserve, Part 9 refuses to arm.
  - The only remedy in the app (export to USB) copies and frees nothing.
- **Recommendation to the owner:** stop the prune only together with a Delete for recordings (Library > Audio, confirm, guard-checked). Otherwise take the stated alternative: keep the prune and show the expiry date on the row. Rule 2 favours the first, and it needs that one extra action.

### Low

- **L1. #1206 now exists.**
  - Update §8 Q2 and Part 18 ("no issue exists for E7-6"), and add #1206 to the §6 table as Part 18's dependency.
  - The Library plan's §6 says global controller assignments are "Correct per 6.9", which contradicts AB 6.9 and this plan.
  - #1206 changes what Open does to existing assignments and settles a disagreement between two plans. I would label it `autonomy:plan-gate`, not `merge-gate`.
  - My answer to Q2: yes, it needs its own plan. Part 18 stays blocked on it, and nothing else in this plan should wait for it.
- **L2. Recovery across a rollover.** When a part rolled over after the last checkpoint, recovery must drop parts the checkpoint does not list, and re-truncate and re-patch a part sealed after the checkpoint. D4 says only "truncates each stream's open part". Add a criterion.
- **L3. Arming at exactly the reserve.** Arm refusal at `free < reserve` lets free = reserve + 1 arm and immediately produce a held take of 0 frames. Refuse below reserve + allowance + headers + a few seconds.
- **L4. Space for legacy conversion.** It requires 0.75 × the whole bundle free (about 28.5 GB for #1078's 38 GB). Converting stream by stream, and deleting each `.pcm` once its parts and an interim manifest are durable, needs only the largest stream.
- **L5. Ring size.** An 8 s ring rounds up to a power of two: 8 MiB per stream at 96 kHz, not "6 MB". `LE_MAX_MONITORED_INPUTS` is 32 (`segno_engine_api.h:670`), so up to 33 rings, 264 MiB, are memset at arm. Cap the total (shrink `ring_seconds` as the stream count grows) or state the bound.
- **L6. Guard matrix: capture against transfer on the same volume.** capture × transfer is "allow" even when the transfer writes to the capture's stick. A backup or export there competes for bandwidth and will likely end the take as `slow_storage`. Refuse writing transfers to the capture's volume.
- **L7. Pen gaps.**
  - Write the HfLgr deviation back into the pen (repo rule: a deviation updates the pen).
  - Part 13 does not mention 20/03 `E7kQV` (Recording by foot) or cH9UX's `Hear an example`.
- **L8. Wording.** D2's 16 MiB removable floor is "room for the checkpoint, mirror and manifest", but the mirror lives on Internal.
- **L9. NTFS.** USB P1 mounts NTFS read-write (ntfs3), and the hardware matrix covers FAT32 and exFAT only.
- **L10. Size.** 20 parts and about 9,700 lines span four separable areas: capture, publication, connection repair and guards. Track them as sub-issues so the board shows progress.

## Notes

- Dependency order is sound otherwise:
  - the capture chain 1 → 2 → {3, 4} → 8 → 9 → {10, 12, 13};
  - the publication chain 1 → 6 (#1196, still OPEN) → 7 → 14.
- Part 9 deletes `_stopForLowDisk`, which USB P6 routes `volumeLost` through. Part 9 must re-route `volumeLost` to `held(volumeLost)`; its criteria imply this but do not say it.
- A builder branch for this plan's Part 1 already exists (`claude/recording-1198-p1`) while the plan is in review. Part 1 (SHA-256 and directory fsync) is unaffected by these findings.
- I did not repeat the "drain never waits on the device" claim as a finding. In current kernels `simple_fsync_noflush` takes no inode lock, so the checkpoint's fsync does not block the drain's `write()`. M6 is a separate, verified wait.

Verdict: Request changes (H1, H2 and M1-M9 need plan edits; H1 and Q1 need owner decisions).
