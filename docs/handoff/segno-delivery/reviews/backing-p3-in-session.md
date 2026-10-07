Model: Claude Opus (subagent), in-session

# Review of `claude/backing-1200-p3` (3f42d99d0): feat(engine): Dart seam for the backing voice and the shared audio-file decoder (#1200 Part 3)

## Scope

- **Head:** `3f42d99d0`, two commits on P2 `e06bb06a2`: `d5e705d0b` and `3f42d99d0`. 14 files, +1,960 lines, all Dart.
- **The seam itself:**
  - `BackingControl`, composed into `AudioEngine`;
  - `EngineResult.tooLong`;
  - `backing.dart`: the state value, the enums, `AudioFileInfo`, `AudioProbe`, `DecodedAudio` with explicit ownership, and the engine-free `AudioDecoder`;
  - `NativeAudioDecoder`, which decodes in `Isolate.run` and hands the native buffer back by address;
  - `MockAudioDecoder`;
  - the `NativeAudioEngine` FFI calls, and `PumpedNativeEngine.pump(output:)`;
  - the `MockAudioEngine` voice;
  - the four `AudioEngine` test fakes.
- **Reviewed against:**
  - the plan at `519107563`: Part 3 and its build record;
  - the native contract (`segno_engine_api.h`) at the same head;
  - AGENTS.md;
  - the owner rules.
- **Pen:** not read. This part has no UI.

## Runs

**Dart.**
- `segno_engine` suite against a freshly built test library: 404 tests, all passed, including `backing_test.dart` and `native_backing_test.dart`.
- `looper_repository`: 806 passed.
- `session_repository`: 189 passed.
- `performance_repository`: 130 passed.
- `dart analyze --fatal-infos lib test packages`: clean. The first run reported 389 errors, all in `storage_repository`, whose `package_config` this fresh worktree had not resolved. A per-package `pub get` cleared them, so that was the environment, not the PR.
- `bloc lint lib test packages`: 0 issues.

**Native.** The suites on the P2 head this part stacks on are recorded in the P2 delta. P3's native change is one header comment.

**Merge.** `git merge-tree` against the current trunk `890f04936` conflicts mechanically in:
- `segno_engine_api.h`: the `le_result` list. The backing's -12 sits beside #1198's -18 and -19, both within the ledger.
- `engine_private.h`;
- the generated bindings.

This affects the whole stack (L3).

## Verified correct (traced)

**Ownership crosses the FFI exactly once.**
- `DecodedAudio` is `owned` until one of two things happens:
  - `markTransferred()`, which `NativeAudioEngine` calls only after `le_engine_backing_load` or `_stage_next` returned ok;
  - `dispose()`, which frees through the payload once and is a no-op after a transfer.
- `_ownedBuffer` refuses audio that is not owned, and audio from a non-native payload. That matches the native registry's "already owned" refusal.

**The decode runs off the calling isolate.**
- `_decodeHere` and `_probeHere` open the library inside the worker isolate.
- They return only plain values (the buffer's address, frames, info and the peak list) and free every scratch allocation in `finally`.
- The native buffer is process-wide heap, so freeing it with the main isolate's bindings is sound.

**Refusals carry their reason.**
- `EngineException(EngineResult.unsupported | invalid | tooLong | capacity)` map one-to-one onto the P2 codes.
- -12 maps to `tooLong`. -5, the whitelist's `UNSUPPORTED`, maps to `unsupported`.

**State and settings.**
- `backingState()` maps every field of `le_backing_state`.
- The enums keep the native order; `backing_test.dart` asserts it.
- The setters are direct stores, so they need no ring.

**`pump(output:)`.** It copies at most the block's frames into the caller's list, so a native test reads what the engine played. `native_backing_test.dart` uses it to assert that the decoded samples, and not some other buffer, reach the routed outputs, and that End = Next frees the finished file.

## Findings

### Low

**L1. The mock's backing diverges from the native engine in two places.**
- **Retained reopen:** `MockAudioEngine.reopen` calls `start()`, which releases the loaded and staged buffers and bumps the epoch, even when the outcome is `retained`. Native `le_engine_reopen_configured` keeps both buffers on a retained reopen (P1 `test_backing_lifetimes`).
- **Stopped device:** every mock call goes through `_requireRunning()` and returns `notRunning` on a configured but stopped engine (load, stage, clear, transport, seek). Native accepts them whenever the engine is configured: `le_backing_post_buffer` and `le_push_cmd` check `a_configured`.
- **Scenario:** a repository test on the mock can never exercise "the device was lost; the owner loads or clears while stopped", nor "the reopen kept the file". P4 works around the second with a hand-made epoch bump (`engine.extraEpoch++`). That covers the repository but leaves the mock claiming rules it does not keep. The P3 success criterion says "the mock obeys the same rules".
- **Fix:**
  - On a retained reopen, keep `_backingCur` and `_backingNext`, stop at 0, and bump the epoch.
  - Gate the backing calls on "started at least once" rather than running.
  - Add one mock test for each.

**L2. No native finalizer guards a dropped `DecodedAudio`.**
- **Where:** `DecodedAudio` (`backing.dart`). A caller that loses the object without calling `dispose()` leaks up to 691 MB of native heap. For example:
  - an exception between `decode` and `backingLoad`;
  - a `StateError` thrown by `_checkAlive()` after the engine was disposed: `backingLoad` throws before transferring, and P4's `_install` does not catch `StateError`.
- **Fix:** attach a `NativeFinalizer` over `le_backing_buffer_free` in `NativeDecodedAudioPayload`. Detach it on transfer and on dispose. The explicit protocol stays primary; the finalizer only bounds the damage of a missed path.

**L3. The stack no longer merges into trunk `890f04936`.**
- The conflicts are in `segno_engine_api.h` (the `le_result` list, beside #1198's -18 and -19), in `engine_private.h`, and in the bindings. All are adjacent edits, with no numbering collision.
- **Fix:** rebase P1 upward and regenerate the bindings at each step.

## Notes

- **The NOT_READY retry moved to Part 4,** as the build record says. P3's `backingLoad` returns `notReady` as is, which is the right layer.
- **`backingSeek(int)` narrows to `int32` at the FFI.** 15 minutes at 192 kHz is 172.8 M frames, so the narrowing is unreachable.

Verdict: Approve.
