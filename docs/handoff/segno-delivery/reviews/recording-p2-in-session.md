Model: Claude Opus (subagent), in-session

# Review of PR #1245: #1198 Part 2, the drain writes ordered float WAV parts

## Scope

- **Branch:** `claude/recording-1198-p2` at c76adf96c, base `claude/segno-integration` at 097e1ef68. Two commits:
  - f08f829fc, the cherry-pick of #1238's eb8fe6055 (`engine_wav.c`, `le_fx_frozen_chain`/`le_fx_print`). Its tree diff against eb8fe6055 is empty.
  - c76adf96c, Part 2 itself: 40 files, +2196/−582 overall.
- **Reviewed against:**
  - plan `docs/plan/2026-10-06-feat-recording-recovery-plan.md` (D2, D3, Part 2, Part 8, §6) on `claude/recording-recovery-plan-1198`;
  - AGENTS.md and the five owner rules.
- **Consumer search.** I looked for every reader of `master.wav`, `live-input-N.wav`, `master.pcm` and `input-N.pcm` in these places:
  - the trunk;
  - every open Library branch (`library-1178-p3-lows`, `-p4`, `-p5`, `-p6a`);
  - the render branches (#1238, #1241);
  - the backing, USB, settings and session-migration branches;
  - `apps/segno_transfer`, `packages/daw_export`, `perf_render.c`, the recorder cubit and the docs.

## Runs

| Suite | Result |
| --- | --- |
| Native, plain, 3 runs (own TMPDIR each) | 3/3 green; every binary prints ALL PASSED |
| Native TSAN races (`NATIVE_TESTS_ONLY=races`, `-fsanitize=thread`), including the new `test_perf_drain_races.c` | green, no TSAN reports |
| Native ASan | green |
| Native, telemetry off | green |
| `segno_engine` with `SEGNO_ENGINE_LIB` | 376/376 |
| `performance_repository` | 131/131 |
| `session_repository` | 189/189 |
| `wav_codec` | 7/7 |
| App suite with `SEGNO_ENGINE_LIB` | 3468 passed, 56 skipped, 1 failed (see below) |
| `dart analyze --fatal-infos lib test packages/segno_engine packages/performance_repository packages/session_repository packages/wav_codec` | no issues |
| `bloc lint lib test packages` | 0 issues in 881 files |
| FFI symbols (manual `nm -gU` against every `le_*` the bindings name; `check_ffi_symbols.sh` expects ELF) | every engine symbol present, including `le_perf_arm`; only the `le_midi_*` symbols are missing, which the test library leaves out by design |

- **The one app failure is unrelated.** `foot_mixer_dispatch_test.dart` "Custom saved hold enters Mixer" failed while the native suites ran beside it. It passed 3/3 in isolation, and P2 does not touch control.
  - `test/session/midi_persistence_test.dart` is also timing-sensitive under load. It failed intermittently on both this branch and P11 while other suites ran, and passed 18/18 idle on trunk, P2 and P11.

**Probes and mutations** (all reverted; the worktree is clean):

1. **Legacy bundle through boot salvage** (a temporary Dart test). The bundle is an unfinalized sidecar plus `master.pcm`.
   - On trunk: finalized, `master.wav` written, moved to `recovered/`.
   - On P2: finalized with **no WAV**, moved to `recovered/`, and deleted by the 30-day prune with its `master.pcm` (Finding 2).
2. **A disk that stays full after a short write** (a native probe on the write-budget seam). `master-001.wav` is 96 bytes, but its header declares 92 (RIFF + 8 = 84 + data = 92). The sidecar says `bytes: 92` (Finding 3).
3. **Native mutations, all survived** (Finding 7):
   - zero-filled frames left out of the part digest;
   - the high byte of the `sgno` part index zeroed;
   - the open part's overs left out of the live take total;
   - the final pass not sealing after a failed write.
4. **Dart mutation, survived.** The crash-seal frame width hard-coded to stereo (`frameBytes = 8`). Nothing tests a mono master (Finding 7).
5. **Trial merges with #1238.** P2 then #1238, and #1238 then P2, onto 097e1ef68: both conflict in the same five files. #1241 stacked on #1238 conflicts the same way (Finding 4).

## Verified correct (traced)

1. **Header parity with Part 5.** Native `kPerfPartHeaderFixture` and #1227's `_nativeHeader` (`packages/wav_codec/test/recorded_part_test.dart`) are the same 84 bytes:
   - RIFF size `0x4C`;
   - `fmt ` 16 with tag 3, 2 channels, 48000, byte rate 384000, block align 8, 32 bits;
   - `sgno` 32 with take id 00..0f, stream 0 and part 1;
   - 12 zero bytes;
   - `data` 0.

   `test_perf_part_header_matches_fixture` compares the drain's real file with that literal. #1227's `RecordedPartHeader.decode` accepts every header this drain writes, including an open part's zero sizes (it does not check the RIFF size).
2. **Rollover.** `le_pd_append` (`perf_drain.c:1168`) splits each popped block, and each zero-fill chunk, at `le_pd_part_capacity`. It seals lazily, so a part that fills exactly at stop gets no empty successor, and the next part continues the stream with no gap.
   - The roll-over test checks 8084/8084/4084 bytes, the patched RIFF and data sizes, the indexes, and each digest against both `le_digest_file` and the engine's output.
   - The zero-fill test checks whole frames across 10-frame parts.
3. **Short-write accounting is unchanged in frame bytes.** `le_pd_whole_frames_landed` still credits whole frames and rewinds a torn tail. `le_pd_append` digests and counts overs only over landed frames, and credits the writer with `le_wav_note_frames`. The existing desync tests pass against parts.
4. **The final pass seals before the last sidecar** (`perf_drain.c:1704`), on every stop path:
   - disarm;
   - device change;
   - disk-full self-stop (the loop breaks into the final pass).
5. **Sealed parts are listed per stream in index order** with sha256 and overs, followed by the open part. The byte-exact sidecar test pins the new keys. The `performance.json` parser in `perf_render.c` is a real JSON parser (`le_json_parse`), so the new keys and the nested `parts` objects cannot confuse the renderer's `layers` lookups.
6. **The live sidecar can live elsewhere.** With `live_sidecar_dir` set, the take directory gets only parts and `events.log` (tested).
7. **Real-time safety.** Nothing on the audio thread changed: `engine_process.c` is not in the diff. The rings are still allocated and prefaulted control-side at arm.
   - The default stays 2 s (rule 1). The repository passes `ringSeconds: 0`, and the sidecar of the exact-bytes test reads `ring_seconds: 2`.
   - The arm now computes the input mask once and reuses it for counting and allocation, so a monitor toggled between the two loops can no longer desync them.
   - The drain's new per-sample work (SHA-256 and the overs scan) is off the audio thread.
8. **Steady-state drain cycles still allocate nothing** (the #722 allocation test passes). Rollover allocates (an `fdopen` FILE and its buffer) once per 2 GB part, which is outside the steady state.
9. **Crash-seal in Dart** (`performance_repository.dart:1156`) touches only files named like parts whose RIFF size reads 0. It floors to whole frames from the `fmt ` channel count, truncates, and patches offsets 4 and 80. A sealed part and a non-part file are left alone (tested).
10. **Untouched consumers.** I checked these by reading the code; the native and Dart suites cover them too:
    - `daw_export` (`manifest_reader.dart` reads only `stems/` and `loops/`);
    - `.als` and `fx-chains.txt` re-export (`_writeDawExports`);
    - the offline performance render (`perf_render.c` reads `performance.json`, `events.log`, `loops/` and layer files);
    - the completion sheet (reads `capture_frames`).

## What the removal of `master.wav` / `live-input-N.wav` breaks

| Consumer | Where | After P2 |
| --- | --- | --- |
| **Segno Transfer** (released Mac companion, `transfer-v0.1.0`) | `apps/segno_transfer/Sources/TransferCore/Resources/appliance.py:110`, `:92`; `Models.swift:72-73`, `:89`; `AppModel.swift:74` | **Broken for every new take.** See Finding 1. |
| Boot salvage of legacy bundles | `performance_repository.dart:986` (`_finalize`), `:881` (prune) | **Regressed.** See Finding 2. |
| Boot salvage of new bundles | `_sealOpenParts` | Works (tested). |
| DAW export (`packages/daw_export`, `project.als`, `fx-chains.txt`) | `manifest_reader.dart:181-203`, `fx_chains.dart` | Unaffected: it reads stems, loops and the manifest only. |
| `dawPackageFiles` | — | Exists on no branch. It is a Library Part 7 contract, still written against `master.wav` in the Library plan (Finding 5). |
| Library `listCaptures`, audition | — | Not built on any branch. `library-1178-p6a`'s audition plays session audio, not captures. The Library plan still names `master.wav` (Finding 5). |
| `SessionRepository.exportStems` | `session_repository.dart:934` | Unaffected: it exports session layers, not captures. |
| Re-export | `PerformanceRecorderCubit.reExport` → `_writeDawExports` | Unaffected. |
| Performance render | `perf_render.c` | Unaffected, and it never read the capture PCM. |
| Open branches | `backing-1200-p1` (#1222) `perf_drain.c` | Adds a `backing_in_master` sidecar key and a comment naming `master.pcm`. That conflicts with P2's sidecar block and the byte-exact sidecar test, and the comment goes stale. |

**Rule 1 answer.** A trunk merge breaks one shipped feature, Segno Transfer, and regresses legacy salvage. The fix for both is small and does not depend on any Library change, so this part should **carry the adapters**, not wait for Library Part 7.

## Findings

### 1. High: Segno Transfer can no longer list any take recorded after this change

- **Where:**
  - `apps/segno_transfer/Sources/TransferCore/Resources/appliance.py:110`: `if not any(f["path"] == "master.wav" for f in files): raise ValueError("Main recording is not ready.")`;
  - `:92` sorts `master.wav` first;
  - `Models.swift:72-73` names `master.wav` "Main recording" and `live-input-*` "Live input";
  - `Models.swift:89` gives `master.wav` the take's own file name;
  - `AppModel.swift:74` `selectMain` selects `master.wav`.
- **Scenario:** after an appliance build with P2, the player records a take and opens Segno Transfer. The take is counted under "unavailable", because the catalog raises "Main recording is not ready." for every bundle without `master.wav`. The same applies to every crash-salvaged new take in `recovered/`.
  - Segno Transfer is a released product (README links `transfer-v0.1.0`). It is the documented way to get recordings off the console.
  - `appliance.py` ships inside the Mac app and runs over SSH ("never installed on the device", line 1). An appliance OTA therefore cannot repair it: every installed copy of the Mac app stays broken until the user installs a new Transfer release.
  - Rule 1 is broken (a shipped feature stops working), and so is rule 3 (it fails with a generic "unavailable" count).
- **Fix, in this PR:**
  - `appliance.py`: accept `master-001.wav` as the main recording (main = the `master-NNN.wav` parts in order), and keep `master.wav` for legacy takes.
  - `Models.swift`: role "Main recording · Part N" for `master-NNN.wav` and "Live input n · Part N" for `input-<n>-NNN.wav`; suggested name `<take> · Part 001.wav`, which is plan D3's export name.
  - `AppModel.selectMain`: select every master part.
  - Tests: extend `test_appliance.py` and the Swift model tests with a parts bundle. Sealed parts already pass `wav_complete`; open parts (RIFF size 0) are correctly excluded mid-take.
- **Release order:** cut a Transfer release before any appliance build that contains P2, and record that order in the plan's Part 2.
  - If the owner prefers to wait, Part 2 must not reach the integration trunk until the Transfer update lands.

### 2. High: boot salvage now "finalizes" legacy raw captures without audio, and the 30-day prune then deletes them

- **Where:** `performance_repository.dart:986`. `_finalize` now only calls `_sealOpenParts`, which ignores `master.pcm` and `input-N.pcm` (regex at `:1149`). It still stamps `finalized: true`, `_recoverSilently` moves the bundle to `recovered/`, and `_pruneRecovered` (`:881`, `recoveredRetention` 30 days at `:125`) deletes it.
- **Probe** (a temporary test, removed). Unfinalized sidecar plus a 16-byte `master.pcm`, then `runBootRecovery()`:
  - On trunk: moved to `recovered/` with `[master.wav, performance.json, master.pcm, .recovered-at]`.
  - On P2: moved with `[performance.json, master.pcm, .recovered-at]`, no WAV.
  - On both, the bundle is gone after the clock advances 31 days. On trunk the user had a playable `master.wav` for those 30 days. On P2 they have nothing playable, and Transfer lists nothing (Finding 1).
- **Worst case is #1078's 38 GB capture.**
  - On trunk its finalize fails (the whole-file read), so it stays in place, unfinalized, for the next boot. That is what Part 8's HARDWARE criterion ("the 38 GB capture on the appliance (#1078) recovers into parts") depends on.
  - On P2's first boot it is stamped finalized, moved, put through a render, and **deleted 30 days later with its only copy of the audio**.
  - It also no longer matches Part 8's legacy route, which keys on an unfinalized bundle with `master.pcm` and no parts. Part 8 also keeps `recovered/` bundles as they are.
  - Rules 1 and 2 are broken.
- **Fix:** in `_finalize`, when a bundle has `master.pcm` (or any `input-N.pcm`) and no `master-001.wav`, do not finalize it here.
  - Either keep today's legacy conversion for files small enough to read (rule 1: unchanged behaviour for existing installs),
  - or return before stamping, so the bundle stays unfinalized in place for Part 8's bounded legacy conversion.

  Add the probe above as a test, plus one asserting a large legacy bundle is left unfinalized and in place.

### 3. Medium: a part sealed after a short write keeps its torn tail past the declared data

- **Where:** `le_wav_seal` (`engine_wav.c:103-127`), called from `le_pd_seal_part` (`perf_drain.c:1137`). On a short write, `le_pd_whole_frames_landed` rewinds the stream position over the torn bytes, but they stay in the file unless a later write overwrites them. The seal patches the sizes but does not truncate.
- **Probe:** the write budget set to 12 bytes (one stereo frame plus 4 torn) and never healed. The result:
  - self-stop with `disk_full`;
  - `master-001.wav` is 96 bytes, while the header and the sidecar's `bytes` say 92.
- **Consequences:**
  - Segno Transfer's `wav_complete` (RIFF + 8 must equal the size) hides the part.
  - The plan's Part 8 check, "verify each sealed part's size", fails on exactly the takes the disk-full rule produces.
  - `le_digest_file(path, 84, UINT64_MAX)`, the call the plan's criterion uses, digests 4 bytes the sidecar's sha256 does not cover.
  - The existing short-write tests heal the disk before the final pass, so none of them sees this.
- **Fix:** after patching, truncate the file to `header_bytes + data_bytes` (`ftruncate(fileno(f), …)` or `_chsize_s` on Windows). Do it in `le_wav_seal`, so every writer gets it, or in `le_pd_seal_part`. Add the never-healed variant of `test_perf_ring_short_write_does_not_desync_file` and assert file size = 84 + data.

### 4. Medium: the cherry-pick conflicts with #1238 (and #1241) in five files, whichever lands first

- **Trial merges onto 097e1ef68.** In either order, P2 and `render-1202-p1` (88390a548) conflict in `src/CMakeLists.txt`, `engine_cache.c`, `engine_cache.h`, `engine_wav.c` and `engine_wav.h` (add/add). `render-1202-p2` (#1241) conflicts the same way.
- **Cause:**
  - #1238's second commit adds `engine_render.c`, `le_cache_reserve` and `le_render_worker_*` next to the shared hunks;
  - P2's own commit changes `engine_wav.c` (`open(... O_CLOEXEC)`/`_O_NOINHERIT`, `le_wav_note_frames`).
- **Risk:** the resolutions are a union. Taking "theirs" for `engine_wav.c` would drop the close-on-exec open, which no test covers, so CI stays green. Dropping `le_wav_note_frames` or the render seams fails to link, so those would be caught.
- **Fix:** land #1238 first, rebase P2 on it, drop f08f829fc, and keep the `engine_wav.c` change as P2's own commit. Alternatively, move the O_CLOEXEC and `le_wav_note_frames` change into #1238 now, so both branches carry an identical file.

### 5. Low: the Library plan still specifies `master.wav` and `live-input-N.wav` for Part 7 and a hardware check

- **Where:** `docs/plan/2026-10-06-feat-library-sessions-plan.md` on trunk and on every Library branch:
  - `:82-83` and `:412` describe the bundle contents;
  - `:388`: "For a performance recording the same voice plays its `master.wav`";
  - `:441`: `dawPackageFiles`;
  - `:925-928`: `dawPackageFiles(path)` listing `master.wav`, every `live-input-N.wav`, …;
  - `:916`: Listen hardware check "master.wav is silent where the preview was".
- **Scenario:** the recording plan's D3 and §6 say Library Part 7 takes D3's contract (parts, audition from part 1, multi-part export), but the Library plan a builder will read says the opposite. Nothing built breaks today.
- **Fix:** amend the Library plan in this PR or before Library Part 7 starts. Change the four places above to the part names, and the `:916` check to "the master parts are silent where the preview was".

### 6. Low: the ring cap and the ring-seconds input disagree with the plan

- **Where:** `le_perf_ring_seconds_granted` (`engine_commands.c:4529-4543`) and the arm validation (`:4589`).
  - **Over the cap.** With 32 captured inputs at 96 kHz, the 2 s floor gives 33 rings of 2^19 samples, which is 66 MiB. That is over the plan criterion "33 captured streams at 96 kHz with ring_seconds 8 arm with total ring memory at most 64 MiB". The test (`test_engine_core.c:10868`) codifies the overrun.
    - The plan's "never below 2" and "at most 64 MiB" cannot both hold, so one of them has to give, and the plan should say which.
  - **Reported in the wrong place.** D2 (review L5) says the snapshot reports the granted seconds. Only the sidecar does.
  - **Below the floor.** `ring_seconds = 1` is accepted and granted as 1 s, below the 2 s floor: the loop only lowers values above 2.
  - **Slow for huge requests.** A huge request (`INT32_MAX`) decrements one second per iteration, about 2^31 rounds of 33 `next_pow2` calls on the arm caller's thread.
  - **Silent truncation in Dart.** `PerfTarget.ringSeconds` is not range-checked, so a value past 32 bits truncates silently.
- **Fix:**
  - Clamp `ring_seconds` to `[2, 8]` (or refuse outside it).
  - Compute the granted seconds directly rather than by decrement.
  - Add `perf_ring_seconds` to `le_snapshot`.
  - Settle the 66 MiB case in the plan: either allow the floor to exceed the cap, or cap the input count.

### 7. Low: behaviour the tests do not pin (mutations survived)

- Digest over zero-filled frames: `le_pd_append` digests `kZeros`. Making it skip them changes no test, so a gap part's sha256 is unverified.
- `sgno` part index high byte (`perf_drain.c`, `out[19]`): zeroing it passes.
- The live sidecar's take `overs` includes the open parts: removing the master's open overs passes.
- "Attempted even after a failed write" (`perf_drain.c:1704`): changing it to seal only on success passes.
- Dart crash-seal with a mono master: `frameBytes` hard-coded to 8 passes.
- **Fix:** one zero-fill digest assertion in `test_perf_zero_fill_crosses_part_boundaries`; one part-index > 255 header check (small `part_bytes`, many frames); a mid-take sidecar overs check; seal-after-disk-full header sizes (pairs with Finding 3); a mono `writeOpenPart` case.

### 8. Low: `le_perf_target` leaves out three fields the plan defines, without saying so

- **Where:** `segno_engine_api.h:2966`. The plan's struct has `mirror_dir`, `reserve_bytes` and `checkpoint_ms`, "stored here and used by Parts 3 and 4". The built struct has none of them, and neither the PR body nor the plan records the change. Parts 3 and 4 will each change the FFI struct again.
- **Fix:** record the deviation in the plan's Part 2 (or add the three fields now as inert).

### 9. Low: stale text that now describes the wrong files

- `docs/design/performance-event-log-format.md:13` still names `master.pcm` and `input-<N>.pcm`.
- `perf_drain.c:490`, `:524`, `:528`, `:1056`, `:1263` and `:1674` still say `master.pcm`.
- `performance_recorder_cubit.dart:100-123` (`finalizeHeadroomBytes`, `stopFloorFor`) still says finalize writes "a full second copy". It no longer does.
  - The floor itself still stops a take at about half the free space. That is unchanged behaviour, which is right under rule 1 until Part 3 replaces it, but the doc should say so.

### 10. Low: the parts-list overflow seals a part and then leaves it unlisted

- **Where:** `le_pd_seal_part` (`perf_drain.c:1137-1150`) calls `le_wav_seal` (closing and patching the file) **before** checking `sealed_count >= LE_PD_MAX_PARTS`. So the 513th part is sealed on disk but missing from `parts`, and the take stops as `disk_full`.
  - That is the opposite of the comment ("rather than leave a part unlisted"), and the stop reason misleads (rule 3).
  - It needs about 1 TB per take, so it is unreachable today.
- **Fix:** check the count first and refuse to roll over, or stop with its own reason.

## Notes

- **Crash-salvaged sidecars stay stale until Part 8.** `_sealOpenParts` patches the file but not the sidecar, so the finalized `parts` entry for a part that was open still shows the last cycle's frames and no sha256. A part opened after the last sidecar write is not listed at all. Part 8's checkpoint recovery owns this; its tests should include a part missing from the sidecar.
- **Two Dart readers of the part header (rule 4).** `_sealOpenParts` parses the header by hand, and `PerfTarget.partHeaderBytes` duplicates #1227's `RecordedPartHeader.headerBytes`. Once Part 5 lands, Part 8 should use `RecordedPartHeader` and drop both.
- **Part regex limit.** `_partFile` accepts exactly three index digits. That is fine with `LE_PD_MAX_PARTS` 512, but it must change if that limit grows past 999.
- **This PR also ships the #1238 refactor.** f08f829fc moves the wet cache's print onto `le_fx_print` (291 lines in `engine_cache.c`). It is byte-identical to #1238's commit, and the native suites cover it here, but P2 carries that change if it lands first.
- **SHA-256 and overs cost is small.** 3 streams at 96 kHz is about 2.3 MB/s, and 33 streams is about 25 MB/s, well within one core even with a portable SHA-256 on the Pi. Worth one measurement on the appliance with a long take.
- **Pre-existing app-suite flakes,** both timing-sensitive under parallel load:
  - `test/session/midi_persistence_test.dart` ("Released mix values from MIDI owner"; it fails on `setCountInBars(0)` at line 88);
  - `test/control/foot_mixer_dispatch_test.dart` ("Custom saved hold enters Mixer").

  Both pass idle on trunk, P2 and P11.

**Verdict:** Request changes. Findings 1 and 2 break a shipped feature and existing installs' audio on a trunk merge. Both fixes are small and belong in this part: the Transfer adapter plus its release order, and leaving legacy raw bundles unfinalized (or converting them as before). Finding 3 (truncate on seal) and Finding 4 (land order with #1238) should be settled before merge. The rest are low.

## Delta review (51696d5f3)

Model: Claude Opus (subagent), in-session

**Scope:** `c76adf96c..51696d5f3`, three commits:

- **4dc5fdf64:** Segno Transfer 0.2.0 lists parts.
- **3f1a7408a:** legacy captures keep their audio; the 30-day prune is removed.
- **51696d5f3:** seal to the exact size, bound the ring request, `perf_ring_seconds` on the snapshot, the overflow check moved before rollover, tests for the earlier lows, and the stale text fixed.

The branch is still based on trunk 097e1ef68. The plan on `claude/recording-recovery-plan-1198` (d978a989b, 3223c726e) records Part 2 as built.

**Runs:**

| Suite | Result |
| --- | --- |
| Native, plain ×3 (own TMPDIR each) | green |
| Native TSAN races | green |
| Native ASan | green |
| Native, telemetry off | green |
| `segno_engine` with `SEGNO_ENGINE_LIB` | 380/380 |
| `performance_repository` | 130/130 |
| `session_repository` | 189/189 |
| `wav_codec` | 7/7 |
| App suite with the library | 3469 passed, 56 skipped, 0 failed |
| Scoped `dart analyze --fatal-infos` | no issues |
| Segno Transfer, Python (`test_appliance.py`) | 17/17 |
| Segno Transfer, `swift test` | 27/27, including both new tests |
| Segno Transfer, `swift format lint --strict` (the CI step) | clean |

- **My five earlier surviving native mutations, re-run, are now all killed:**
  - zero-fill left out of the digest;
  - part-index high byte;
  - the open part's overs in the live total;
  - sealing only when the take did not fail;
  - plus a new one: no truncate on seal.
- **The mono Dart crash-seal is pinned** by the new "floors a mono part" test.

### Earlier findings

| # | Now |
| --- | --- |
| H1 Segno Transfer | **Fixed in code, release still pending.** See below. |
| H2 legacy captures | **Fixed.** |
| M3 torn tail on seal | **Fixed.** |
| M4 cherry-pick vs #1238 | **Still open, and wider.** See new Finding 1. |
| L5 Library plan says `master.wav` | **Still open:** trunk's Library plan has 6 `master.wav` references. |
| L6 ring cap and input | **Fixed and recorded.** A request is 0..8, refused outside. Granted seconds are in `le_snapshot.perf_ring_seconds` and `EngineSnapshot.perfRingSeconds`. The 66 MiB floor case and a request of 1 are documented in the API header and the plan. |
| L7 mutations | **Fixed.** All five now die. |
| L8 struct fields | **Recorded** in the plan ("no field before its behaviour"). |
| L9 stale text | **Fixed** in `perf_drain.c`, the event-log doc and the recorder cubit. |
| L10 parts-list overflow | **Fixed for listing:** the check now runs before rollover, so every part on disk is sealed and listed. The stop still reads `disk_full`; see the notes. |

**H1, Segno Transfer.** I checked:

- **`appliance.py`:**
  - the catalog accepts `master.wav` or `master-001.wav` as the main recording;
  - `is_main` sorts the master parts first;
  - an open part (RIFF size 0) is still hidden by `wav_complete`;
  - a take with only input parts is still "not ready".
- **`Models.swift`:**
  - `mainPart` accepts exactly `master-NNN.wav` with NNN ≥ 001, and rejects `000`, two or four digits, and subpaths (tested);
  - roles are "Main recording · Part N" and "Live input n · Part N";
  - the suggested name is `<take> · Part NNN.wav`;
  - `master.wav` takes keep "Main recording" and `<take>.wav`.
- **`AppModel.selectMain`** selects every main part (tested: two master parts, 140 bytes).

Two gates remain before an appliance build with this part ships:

- **Transfer 0.2.0 is not released.** `gh release list` shows only `transfer-v0.1.0`. `segno-transfer.yaml` releases on a `transfer-v*` tag and checks the plist version, which is 0.2.0. The plan records the order. The tag has to be pushed before any appliance build with this part, and nothing in CI enforces that.
- `apps/segno_transfer/README.md:11` still links the `transfer-v0.1.0` release.

**H2, legacy captures.** `_finalize` now handles a bundle with `master.pcm` or `input-N.pcm` and no `master-001.wav` in two ways:

- it converts the bundle exactly as before;
- if any raw file is over `legacyConvertMaxBytes` (1 GiB), it returns before stamping, so the bundle stays unfinalized in place.

`_pruneRecovered`, `recoveredRetention` and `pruneSanityFloor` are gone. Tests cover:

- conversion through a live disarm;
- crash recovery with a WAV that is still there 400 days later;
- a sparse 1 GiB + 4 file that is left unfinalized, not moved and not converted.

Consequences, acceptable until Part 8:

- A large legacy bundle is re-listed by `findUnfinalized` on every boot. It costs one sidecar parse and a brief `recovering` state.
- The `.boot-recovery` marker stays inside it.
- Conversions up to 1 GiB per file still read the whole file synchronously on the UI isolate, as trunk always did.

**M3, truncate on seal.** `le_wav_seal` now runs `ftruncate` (or `_chsize_s` on Windows) to `header_bytes + data_bytes` after the size patch. My torn-tail probe's case is now a test (`file_size == 84 + 8`). Both the no-truncate mutation and the "seal only when the take did not fail" mutation fail it.

### New findings

#### 1. Medium: landing order with #1238, which has since grown, and with the current trunk

- **What #1238 changed.** `claude/render-1202-p1` (1ac22cb9b) has merged trunk 890f04936 and fixed its review findings. Its `engine_wav.c` now contains P2's close-on-exec open and `le_wav_note_frames`, byte for byte. It adds:
  - the odd-chunk refusal;
  - `le_wav_flush`;
  - `le_wav_publish` returning 2 when the file was published but the directory sync failed;
  - `le_wav_patch_sizes` (repair an unsealed file, cut it to a trusted length, fsync).

  It does **not** have P2's truncate in `le_wav_seal`.
- **Trial merges onto 51696d5f3.**
  - **Against current trunk (890f04936)** alone, P2 conflicts in four files: `performance_repository.dart`, its test, the generated bindings, and `test_engine_fade.h`. That is P11's guards merged into the repository plus trunk drift. A trunk merge is needed in any case.
  - **Against #1238's head,** it conflicts in nine: those four plus `CMakeLists.txt`, `engine_cache.c`, `engine_cache.h`, `engine_wav.c` and `engine_wav.h`.
- **What the rebase needs:**
  - land #1238 first, then rebase P2 on it and drop f08f829fc;
  - take #1238's `engine_wav.c` and `engine_wav.h` whole, and re-apply only the truncate block in `le_wav_seal`, with `<sys/types.h>` already included there;
  - take #1238's `engine_cache.*` and `CMakeLists.txt`;
  - resolve `performance_repository.dart` against trunk's `guards` parameter (P11) beside `PerfTarget` and the legacy path;
  - regenerate the bindings with ffigen, then run `dart format`.
- **Rule 4.** Once #1238 lands, P2 has two repairers of the same unsealed-part layout: the Dart `_sealOpenParts` and the native `le_wav_patch_sizes`. Part 8 should keep one (the native one also fsyncs), and the plan's Part 8 should name it.

### Notes

- **Overflow reason.** A take that would outgrow the 512-entry parts list now stops before rolling over, with every part listed. It still reports `disk_full` (`LE_PERF_STOP_WRITE_FAILED`), which is wrong but needs about 1 TB per take.
- **Input part order in Transfer.** Input parts sort by plain string order, so `input-10-001.wav` lists before `input-2-001.wav`. That is cosmetic.

**Verdict:** Approve, conditional on the landing steps:

- push `transfer-v0.2.0` before any appliance build that contains this part;
- land #1238 first, then rebase this part with the resolutions in Finding 1.

Every earlier High and Medium is fixed in code and pinned by a test, except the landing order. L5 (the Library plan) is still a one-line plan edit.
