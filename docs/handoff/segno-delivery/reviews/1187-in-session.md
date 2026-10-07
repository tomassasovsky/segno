Model: Claude Opus (subagent), in-session

# Review of PR #1187: #1177 Part 2, `le_volume_space`

**Branch:** `claude/usb-storage-1177-p2` at 9c5d21335, base `claude/segno-integration`.

**Setup:** I worked in a temporary worktree and removed it afterwards.

**Runs:**

| Check | Result |
| --- | --- |
| Native suite, plain (`TMPDIR=<scratch>/nat_plain`) | ALL PASSED; `test_volume_space` ran |
| Native suite, ASAN (`EXTRA_CFLAGS=-fsanitize=address -g`, `TMPDIR=<scratch>/nat_asan`, run separately) | ALL PASSED |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `console_facts_client` | +19 |
| `performance_repository` | +130 |
| App `test/performance test/system test/app` | +523 ~9, all passed |

## Verified correct (traced)

1. **Thread.** `le_volume_space` is a synchronous FFI call from `NativeAudioEngine.volumeSpace`. Its two callers are the recorder cubit's free-space check (`performance_recorder_cubit.dart:408,414`, on the Dart main isolate) and the console-facts `diskSpace` closure in `run_segno.dart`. It never runs on the audio thread, and it touches no engine state.
2. **No 64-bit overflow.** `(uint64_t)f_blocks * f_frsize` and `f_bavail * f_frsize` are computed in 64 bits, and the Windows path uses `ULARGE_INTEGER`. Dart reads `Uint64` into a signed `int`, which overflows only above 9.2 EB.
3. **Both outputs are zeroed on entry and on failure.** A missing path returns `LE_ERR_DEVICE`, and the test asserts both outputs are 0.
4. **Every caller is updated.**
   - No `le_perf_volume_free_bytes`, `volumeFreeBytes`, `freeSpaceBytes(` (as a repository method), `parseDfKP` or `_dfDiskSpace` remains in `lib` or `packages`.
   - The fakes (`fake_audio_engine`, `fake_performance_engine`, `fake_session_engine`, mock) implement `volumeSpace`.
   - The recorder's check is unchanged: it compares `volumeSpace(path)?.freeBytes`, the same `f_bavail * f_frsize` figure as before, against the same threshold.
5. **No fork is left on the path.** The `df` `Process.run` is deleted from `local_console_facts_client.dart`, and `diskSpace` is now required with no default. No `Process.run` or `Process.start` remains in the console-facts client, the performance repository or the recorder cubit.
6. **The oracle test follows review edit 9.** `total` is checked exactly against `f_blocks * f_frsize`, `free` within 64 MiB, and `total >= free`.

## Findings

### 1. Low: P2 breaks the repo's own FFI-symbol checker test

- **Where:** `packages/segno_engine/tool/test/run_check_ffi_symbols_tests.sh:70-75`. The "historical skew" case removes `le_perf_volume_free_bytes` from the symbol list and expects the checker to fail and name it. That symbol no longer exists in the bindings, so nothing is removed and the checker passes.
- **Reproduced:** `bash tool/test/run_check_ffi_symbols_tests.sh` reports `FAIL -- historical skew should fail loudly; rc=0` and `1 check(s) failed`. The same script passes at the base, and P2 does not touch it.
- **Impact:** CI does not run this test (`main.yaml` runs only `check_ffi_symbols.sh`), so nothing goes red. But the skew detector's own test is now broken, and the comment in `check_ffi_symbols.sh:14` names a symbol that is gone.
- **Smallest fix:** use `le_volume_space` as the removed symbol in case 2 (and update the comment), or pick any other stable symbol.

## Notes

- **`statvfs` can block.** On a USB mount whose device has just been yanked, or a network mount, `statvfs` can block the UI isolate for a while. That is not audio-unsafe. Part 5 should call it only on page open and on volume events, as review edit 11 says.

**Verdict:** Approve. Finding 1 is a one-line test fix that can land with this PR.

## Delta review (1d8490cea)

Model: Claude Opus (subagent), in-session

**Scope:** `git diff b7b291d71..origin/claude/usb-storage-1177-p2`.
- Case 2 of `run_check_ffi_symbols_tests.sh` now removes `le_volume_space` and expects the checker to name it.
- The comment in `check_ffi_symbols.sh` names the current entry point.

**Run:** `bash tool/test/run_check_ffi_symbols_tests.sh` reports "all checks passed", where it previously reported `FAIL -- historical skew should fail loudly; rc=0`.

**Finding 1:** fixed. Nothing else changed.

**Verdict:** approve.
