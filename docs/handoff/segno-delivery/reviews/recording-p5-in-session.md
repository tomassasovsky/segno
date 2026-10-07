Model: Claude Opus (subagent), in-session

# Review of PR #1227: #1198 Part 5, the part format in Dart

No earlier in-session review of #1227 exists under `claude-published-review/`, so this file starts with the requested delta. Earlier in this session I compared #1227's header fixture with Part 2's native header and found them byte-identical (see `recording-p2-in-session`).

## Delta review (abe7e6f4a)

Model: Claude Opus (subagent), in-session

**Scope:** abe7e6f4a, "drop the sample readers the engine's decoder replaces". 5 files, +8/−155, all in `packages/wav_codec`:

- `readRecordedPartFrames` is removed from `recorded_part.dart`.
- `maxFrames` is removed from `WavCodec.decodeFloat32`.
- Their tests are removed.
- The library doc now says that samples for playback, preview and recovery come from the engine's `le_backing_decode_file`.

The branch is still based on 56033baf0, an older trunk.

**Runs:**

| Suite | Result |
| --- | --- |
| `wav_codec` | 19/19 |
| `wav_codec` coverage | 188/189 lines; the one miss is the pre-existing `closeSync` in `RecordedPartWriter.create`'s catch |
| `performance_repository` | 144/144 |
| `segno_engine` | 370/370 |
| `session_repository` | 122/122 |
| App suite | 3341 passed, 49 skipped, 0 failed |
| Scoped `dart analyze --fatal-infos` | clean |

**Cross-format probe.** A real final slot written by P4's native checkpoint writer (200c44a07) parses with this branch's `TakeCheckpoint.fromSlot` under a real SHA-256 (the package's own tests use an FNV stub). The result: 2 streams, 3 sealed parts each, and a one-byte flip rejected. The Dart reader and the native writer agree.

### Verified correct

1. **Nothing else used either removed API.** I searched for `readRecordedPartFrames` and `decodeFloat32(... maxFrames ...)` across every remote `claude/` branch for the Library, recording, render, backing, USB, session and trunk work: no hits outside `packages/wav_codec`. The removal breaks no caller, on trunk or on an open branch.
2. **Rule 4.** The removal matches the plan's one-decoder decision (D3 "one Dart WAV reader" was revised to the engine's `le_backing_decode_file`; plan text at 3223c726e). `wav_codec` keeps the writer, the header model and `decodeFloat32` for whole stems and mixdowns.

### New findings

#### 1. Low: the plan's Part 5 success criteria still require the removed readers

- **Where:** plan Part 5 (3223c726e). The criterion still reads "readRecordedPartFrames returns the same floats exactly; decodeFloat32(maxFrames: 10) of a 1000-frame file returns 10 frames".
- **The gap:** the "As built" note above it says they are "removed unless a non-decoding use remains", but the criterion was not updated. A checker following the plan would fail this PR.
- **Fix:** drop those two clauses from the criterion, keeping the byte-exact writer and overs check.

#### 2. Low: the decoder the doc names is not on the trunk yet

- **Where:** the library doc now points readers at `le_backing_decode_file`, which exists only on the backing branches (`claude/backing-1200-p2` onward, #1223). It is not on `claude/segno-integration`.
- **Risk:** until #1223 lands, the trunk has no bounded reader for a part. Part 8 (recovery, the legacy conversion) and the Library's audition depend on it.
- **Fix:** state #1223 as a dependency of Part 8 in the plan's §6 table, so Part 8 does not start or land before the decoder does.

**Verdict:** Approve. The removal is safe on every branch, the suites are green, and the Dart slot reader is proven against the native writer. The two findings are plan edits.
