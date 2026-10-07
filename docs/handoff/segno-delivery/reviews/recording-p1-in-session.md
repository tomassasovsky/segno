Model: Claude Opus (subagent), in-session

# Review of PR #1220: #1198 Part 1, SHA-256 digests of bytes and file ranges, and directory sync

**Branch:** `claude/recording-1198-p1` at 616b8b694 (one commit), base `claude/segno-integration`.

## Scope

- 14 files, +869/−31:
  - `src/core/engine_digest.{c,h}`;
  - three ABI entries in `segno_engine_api.h` (`le_digest_bytes`, `le_digest_file`, `le_fs_sync_dir`);
  - generated bindings;
  - `engine_library.dart` (the library opener, moved out of `native_audio_engine.dart`);
  - `storage_io.dart` (`StorageIo`, `NativeStorageIo`);
  - the CMake, SPM and CocoaPods forwarders;
  - the native and Dart tests.
- Reviewed against plan `docs/plan/2026-10-06-feat-recording-recovery-plan.md` (branch `claude/recording-recovery-plan-1198` at 69972aa2f): D4 (checkpoint checksum), D5 (`le_fs_sync_dir`), D6 (one hash implementation, `le_digest_file`, `Isolate.run`) and Part 1.
- Also read for consolidation: #1195's `le_sync_dir` (`claude/usb-storage-1177-p4` at a10cd2387).

## Runs

- `run_native_tests.sh` (scratch TMPDIR): ALL PASSED, including `test_sha256_known_answers`, `test_digest_file_ranges` and `test_fs_sync_dir`.
- `packages/segno_engine` `flutter test` with `SEGNO_ENGINE_LIB` from `build_test_lib.sh`: 375/375. The five `storage_io_test` cases ran; none was skipped.
- App suite: 3341 passed, 49 skipped. `dart analyze --fatal-infos packages/segno_engine lib`: no issues.
- **Independent SHA-256 check.** A C harness linked only `engine_digest.c` and was compared with Python `hashlib` (not with the code's own vectors):
  - 945 messages: every length 0-299, plus 511/512/513, 1023-1025, 4095-4097, 65535-65537, 100000 and 1 MiB, each as random bytes, all-0xFF and all-zero. Each was hashed both one-shot (`le_digest_bytes`) and streamed through `le_sha256_update` in random chunks of 0-149 bytes, plus a trailing zero-length update. **0 mismatches.** This covers every padding branch: `block_len` 55, 56, 63 and 64 after the 0x80, and the two-block spill.
  - 404 file-range checks on a 300000-byte random file (random offset and length, or `UINT64_MAX`), plus four out-of-range refusals: **0 mismatches**, and every refusal was `LE_ERR_DEVICE`.
  - A sparse file of 2^32 + 4097 bytes: a 4 KiB range starting past 4 GiB, and the whole file through `UINT64_MAX`, both equal `hashlib`. This exercises 64-bit offsets, `fseeko`, and the length field above 2^35 bits. 11.5 s for 4.3 GB on this Mac.

## Verified correct (traced)

1. **The compression function** matches FIPS 180-4 §4.1.2 (σ0/σ1 rotations 7/18/>>3 and 17/19/>>10, Σ0 2/13/22, Σ1 6/11/25, Ch, Maj), §4.2.2 (all 64 K constants), §5.3.3 (H0) and §6.2 (message schedule, big-endian word load, state update). `le_rotr32` is never called with n = 0, so there is no undefined shift.
2. **Padding** (§5.1.1): 0x80, zeros to 56 mod 64, a 64-bit big-endian bit length. When the 0x80 lands past byte 56 a second block is emitted. The streaming context gives the same answer however the input is cut (my random-chunk run; the native test does the same with a 1..211 step).
3. **`le_digest_file`** opens with `fopen("rb")` and requires `S_ISREG` via `fstat` (a directory, FIFO or device is refused). It refuses `offset > size` and any explicit length past the end, rather than hashing what is there. `UINT64_MAX` means "to the end". It reads in 64 KiB chunks and treats a short `fread` (the file shrank, or a read error) as a refusal. Every path closes the `FILE*`.
4. **`le_fs_sync_dir`** uses `open(O_RDONLY | O_DIRECTORY | O_CLOEXEC)` and `fsync`, with an EINTR retry and a fallback when `O_DIRECTORY` is missing. On Windows it reports only whether the directory exists, so a missing path fails the same way everywhere.
5. **Engine-free and isolate-safe.** No globals and no engine handle. `NativeStorageIo` opens the library in whichever isolate constructs it; the `Isolate.run` test proves this. `openSegnoEngineLibrary` is a straight move of `_openLibrary` with the same `SEGNO_ENGINE_LIB` override, so `NativeAudioEngine` is unchanged.
6. **Dart surface.** `digestFile` returns null (never a digest) for a negative offset or length, an empty path, a short file, a missing file or a directory. `syncDirectory` throws `FileSystemException`, so a caller cannot report a publication as durable by ignoring a bool. `digestBytes` throws `EngineException` on an invalid argument, which is unreachable from Dart.
7. **Build wiring.** `src/CMakeLists.txt` lists the TU, the SPM and CocoaPods forwarders exist, and `run_native_tests.sh`/`build_test_lib.sh` pick it up through the `engine*.c` glob. `engine_digest.h` is included only from `.c` files and test code, never from `engine_private.h`, so it stays out of the VST3 C++ translation units (the PROGRESS.md rule). CI's fuzz job builds the library and runs `packages/segno_engine` tests, so the `@Tags(['fuzz'])` file runs there.

## Consolidation with #1195's `le_sync_dir` (rule 4)

#1195 adds `le_sync_dir(path)` for the same job. Today that means two exported C functions, two native tests, and two Dart routes:
- #1195: `AudioEngine.syncDirectory` → `NativeAudioEngine`/`MockAudioEngine` → four fake engines → `PerformanceRepository.syncDirectory` → `StorageRepository`.
- #1220: `StorageIo.syncDirectory`.

**Keep this PR's `le_fs_sync_dir` and `StorageIo.syncDirectory`.** Reasons:
- It is the better implementation: EINTR retry, an `O_DIRECTORY` fallback, and a uniform missing-path failure on Windows.
- It lives in the engine-free TU. `le_sync_dir` sits in `perf_drain.c` beside `le_volume_space` only by proximity.
- Its Dart surface needs no engine. It is usable from a background isolate, and it does not widen `AudioEngine` (which every fake has to implement) for something that is not about the engine.
- It throws instead of returning a bool, and #1195's `StorageRepository` today ignores the bool (usb-p4 delta, Finding 3).
- It is the name the recording plan (D5) already specifies.

**How to merge** (land #1220 first, since it is self-contained, then rebase #1195; the same steps apply the other way round):
1. Delete `le_sync_dir` from `perf_drain.c` and `segno_engine_api.h`, and regenerate the bindings. Move `test_sync_dir`'s one extra case (a regular file is refused, `LE_ERR_DEVICE`) into `test_fs_sync_dir`, which lacks it. Then delete `test_sync_dir`.
2. Delete `syncDirectory` from `AudioEngine`, `NativeAudioEngine` and `MockAudioEngine`, the overrides in the four fake engines (`test/helpers/fake_audio_engine.dart`, `packages/looper_repository/test/helpers/fake_audio_engine.dart`, `packages/performance_repository/test/helpers/fake_performance_engine.dart`, `packages/session_repository/test/helpers/fake_session_engine.dart`), and `PerformanceRepository.syncDirectory`.
3. Have `StorageRepository` take a `StorageIo` (or `void Function(String)`). `run_segno` passes `NativeStorageIo()`; `App`'s fallback passes the same. In `copyFile`, a `FileSystemException` from the sync becomes `StorageFailure.io`. The harness's recording fake becomes a `StorageIo` fake.
4. Follow-up, same rule: `le_volume_space` is also engine-free and reaches `StorageRepository` through `PerformanceRepository.volumeSpace`. Moving its Dart surface to `StorageIo.volumeSpace` would leave the storage service depending on `StorageIo` alone. The C function can stay in `perf_drain.c` or move to this TU.

## Findings

### 1. Low: `le_digest_file` cannot tell "missing" from "damaged", and the plan's panels need the difference

- **Where:** `engine_digest.c:191-231` returns `LE_ERR_DEVICE` for open failure, non-regular file, short file and read error alike. `NativeStorageIo.digestFile` maps all of them to `null`.
- **Scenario:** Parts 14 and 15 (Open inspection, recovery panels) distinguish a missing layer from one that is present but does not match. A caller that only has `digestFile` must `stat` first, which reopens the race this API was meant to close (the file can go between the two calls), and it cannot tell a read error (EIO on a failing stick) from a truncated file.
- **Fix:** return distinct codes, for example `LE_ERR_NOT_FOUND` for ENOENT and `LE_ERR_INVALID` for "shorter than the range", with `LE_ERR_DEVICE` kept for I/O. Surface them as a small sealed result in Dart, or as a typed exception from a `digestFileOrThrow`. If the codes cannot change, document that callers must `stat` and accept the race.

### 2. Low: `digestBytes` copies the whole buffer into native memory

- **Where:** `storage_io.dart:63-80`: `malloc` of `bytes.length`, then `setAll`.
- **Scenario:** D6 digests layers already in memory (`le_engine_export_layer` output). A 10-minute mono 96 kHz float layer is about 230 MB, so the digest briefly holds about 460 MB. On the Pi alongside the engine's own buffers, that is the RSS spike Part 8's 200 MB criterion is written against.
- **Fix:** hash in chunks: a fixed 1 MiB native buffer, with `le_sha256_update` exported (or an `le_digest_begin/update/end` trio). Alternatively, take the bytes from a native allocation the exporter already owns.

## Notes

- **The tests lean on the standard's vectors, as the commit says, but only five of them.** My 1349 cross-checks above found nothing; consider adding a few odd lengths around 55/56/64 and a random-chunk stream to the native test, so a future "optimisation" of `le_sha256_update` is caught there rather than in recovery.
- **32-bit `off_t`.** `fseeko` and `fstat` use `off_t`. On a 32-bit Linux build without `_FILE_OFFSET_BITS=64`, a file over 2 GiB fails `fstat` with EOVERFLOW, so it is refused (safe, but no digest). The appliance images are aarch64, so this is only relevant if a 32-bit target returns. A `#define _FILE_OFFSET_BITS 64` at the top of the TU removes the question.
- **macOS `fsync` does not flush the drive's cache** (`F_FULLFSYNC` does). It only matters on the dev host, and the appliance is Linux.
- **No `FakeStorageIo` ships with the package.** Every consumer will write its own; one in `segno_engine` (like `MockAudioEngine`) would serve both #1195's harness and the recording parts.

**Verdict:** Approve. The SHA-256 is correct against 1349 independent checks, including a >4 GiB file, and the file and directory functions behave as documented. Do the consolidation with #1195 before both land (keep `le_fs_sync_dir`/`StorageIo`). Findings 1 and 2 are low and belong with their first consumers (Parts 8 and 14).

## Delta review (be8955676)

Model: Claude Opus (subagent), in-session

**Scope:** the follow-up PR, `claude/recording-1198-p1-followup` at be8955676: one commit on the trunk at 097e1ef68, which already contains #1220 (616b8b694) and #1195 (a10cd2387). 7 files, +377/−49: `engine_digest.c`, `segno_engine_api.h` (two result codes, the incremental API), the bindings, `storage_io.dart`, the barrel export, and the native and Dart tests. The commit's own diff is reviewed here; the wider `616b8b694..be8955676` range also carries trunk work (Peel history, Reverse, P4) that is not part of this PR. Worked in a temporary worktree, removed afterwards.

**Runs:**
- `run_native_tests.sh` (scratch TMPDIR): ALL PASSED, including `test_sha256_known_answers` (now with the boundary lengths and the incremental stream), `test_digest_file_ranges` and `test_fs_sync_dir`.
- `packages/segno_engine` `flutter test` with `SEGNO_ENGINE_LIB`: 377/377, `storage_io_test` included and not skipped.
- `dart analyze --fatal-infos packages/segno_engine`: no issues.
- **Independent check of the exported incremental API.** A C harness linked only `engine_digest.c` and drove `le_digest_begin`/`le_digest_update`/`le_digest_end` in random 0-299-byte pieces, compared with Python `hashlib`. 532 messages (every length 0-259, plus 1023-1025, 64 KiB, 1 MiB and 1 MiB+1; random and zero bytes): **0 mismatches.**
- **Result codes through the real function:**

  | Case | Code |
  | --- | --- |
  | a regular file, whole | the digest |
  | a missing file | `-18` NOT_FOUND |
  | `<file>/x` (ENOTDIR) | `-18` NOT_FOUND |
  | `<missing dir>/x` | `-18` NOT_FOUND |
  | offset 3, length 7 of 9 bytes | `-19` TRUNCATED |
  | offset 10 of 9 bytes | `-19` TRUNCATED |
  | a directory | `-4` DEVICE |
  | mode 000 (EACCES) | `-4` DEVICE |

### Verified correct (traced)

1. **NOT_FOUND versus TRUNCATED versus DEVICE.**
   - `fopen` failing with ENOENT or ENOTDIR (POSIX), or ENOENT (`_wfopen` on Windows), is `LE_ERR_NOT_FOUND`. Any other open failure, a non-regular file, and an `fread` short with `ferror` set are `LE_ERR_DEVICE`.
   - An offset past the end, a length past the end, and an `fread` short at EOF without `ferror` (the file shrank under the read) are `LE_ERR_TRUNCATED`.
   - `errno` is read straight after the failing call, before anything else can overwrite it. Every path closes the `FILE*`.
   - That is the split Parts 14 and 15 need: missing, damaged, or unreadable on a failing drive, with no separate `stat` to race. The plan at 57a5324b8 (Part 14) now says so.
2. **No code collision.** I grepped `segno_engine_api.h` on every `origin/claude/*` branch for `LE_ERR_* = -1x`: -18 and -19 appear only here. -10, -12 and -14..-17 are taken elsewhere, and -11 and -13 are unused on any branch, so the commit's "from this plan's range of the numbering ledger" holds as far as the branches show.
3. **The sealed `FileDigest`.**
   - The four variants are `FileDigested(sha256)`, `FileMissing`, `FileTruncated` and `FileUnreadable`, all `final class`. `FileDigested` has value equality, so the Dart tests compare against literal digests.
   - The `switch` maps 0 and the two new codes and sends everything else to `FileUnreadable`, so a future code cannot be mistaken for a digest.
   - Bad arguments (empty path, negative offset or length) now throw `ArgumentError` instead of returning null. That is right: they are caller bugs, not file states.
   - There is no consumer outside the package on trunk (`git grep` in `lib` and `packages/*/lib`), so changing the return type breaks nothing.
4. **The incremental API and the 1 MiB window.**
   - `le_digest_begin(state, state_bytes)`, `le_digest_update` and `le_digest_end` wrap the internal context, with `_Static_assert(sizeof(le_sha256_ctx) <= LE_DIGEST_STATE_BYTES)`. The context is 112 bytes on 64-bit and the reservation is 128. The state is `calloc<Uint64>`, so it is 8-byte aligned as the header asks.
   - `digestBytes` allocates `min(length, 1 MiB)` once (1 byte for an empty input) and copies one window at a time with `setRange(0, n, bytes, at)`. The window loop covers `[0, length)` exactly: the last window is short, and an empty input runs zero updates and then `end`, giving the empty digest.
   - Peak native memory for a 230 MB layer is now 1 MiB instead of 230 MB. Both the state and the window are freed in `finally`.
   - The Dart test crosses the window two and a half times, and also hits a buffer exactly one window long, each against the file digest of the same bytes.
5. **`_FILE_OFFSET_BITS 64`** is defined before any system header, and only when not on Windows and not already set. My earlier note is addressed.
6. **More oracles:** the native test now has lengths 55, 56, 63, 64, 65, 119 and 120, plus a 5000-byte uneven-piece stream, as literal hex from `hashlib`. My earlier note is addressed.

### Earlier findings

| # | Now |
| --- | --- |
| 1 Low: missing versus damaged indistinguishable | **Fixed.** |
| 2 Low: `digestBytes` copied the whole buffer | **Fixed.** |
| Note: few vectors | **Fixed.** |
| Note: 32-bit `off_t` | **Fixed.** |
| Note: no `FakeStorageIo` | Open (still a note). |
| Consolidation with #1195's `le_sync_dir` | **Open, and now on trunk** (Finding 1 below). |

### Findings

#### 1. Medium (rule 4): both directory syncs are now on trunk, and no open branch removes either

- **Where:** `origin/claude/segno-integration` now carries both `le_sync_dir` (`perf_drain.c`, used by `AudioEngine.syncDirectory` → `PerformanceRepository.syncDirectory` → `StorageRepository`) and `le_fs_sync_dir` (`engine_digest.c`, used by `StorageIo.syncDirectory`). The native run at this head prints both `test_sync_dir` and `test_fs_sync_dir`.
- I diffed every `usb-storage-1177-*` and `recording-1198-*` branch against trunk: none removes `le_sync_dir`. USB P5 (#1217) builds the composition root on `performance.syncDirectory`, which entrenches the engine route.
- **Fix:** the merge plan in this file's first review still applies. Keep `le_fs_sync_dir` and `StorageIo`; delete `le_sync_dir` and its `AudioEngine`, mock, fake and `PerformanceRepository` routes; move the "a regular file is refused" case into `test_fs_sync_dir`; and have `StorageRepository` take a `StorageIo`.
- This follow-up PR is the natural place, since it already touches the API header and the bindings. Otherwise, do it in a dedicated PR before P5 lands, so P5 is built on the surviving route.

#### 2. Low: `LE_DIGEST_STATE_BYTES` is a C macro, and the Dart side depends on ffigen emitting it

- **Where:** `storage_io.dart` uses `LE_DIGEST_STATE_BYTES` from the generated bindings.
- **Risk:** ffigen emits it today, which is why the test passes. A future macro form that ffigen cannot evaluate (for example `sizeof(...)`) would drop the constant silently, and the next regeneration would fail to compile. The C side stays correct, because `le_digest_begin` refuses a short `state_bytes`.
- **Fix:** none needed now. Leave a comment at the `#define` that it must remain a literal for ffigen, or export an `le_digest_state_bytes()` getter.

### Notes

- **Directories and EACCES read as "unreadable"**, never "missing" or "damaged". That is right for recovery: a permissions problem is neither a lost take nor a corrupt one.
- **The Windows path** maps only ENOENT to NOT_FOUND. A missing parent directory there gives ENOENT too, so behaviour matches POSIX in practice.

**Verdict:** Approve this PR. NOT_FOUND/TRUNCATED, the sealed `FileDigest` and the 1 MiB incremental window are correct and independently checked. Finding 1 is not this PR's regression, but rule 4 is now violated on trunk and needs an owner: this PR, or one before #1217.
