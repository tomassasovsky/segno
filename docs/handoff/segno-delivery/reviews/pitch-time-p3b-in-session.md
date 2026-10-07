Model: Claude Opus (subagent), in-session

# Review of PR #1226 (origin/claude/pitch-time-1179-p3b, 50fc651f9): feat(looper): step, install and bypass Transpose through receipts

## Scope

- **The commit:** one commit, `50fc651f9`, on top of Part 3a's head `0725bb619`. It touches 18 files; 191 production lines, excluding tests and helpers.
- **What it adds:**
  - segno_engine: `AudioEngine.transposeStep`, `installTranspose` and `setTransposeBypass` (native through a shared `_admit` helper, the mock, the four fakes); `TransposePitch = ({int stored, int effective})` on `TrackSnapshot`; `EngineSnapshot.transposeBypass`.
  - looper_repository: `transposeTrack`, `installTranspose` and `setTransposeBypass` through `_requestReceipt`, `Track.transpose` and `LooperState.transposeBypass`.
  - Tests: `transpose_native_test.dart` and `transpose_receipt_test.dart`.
- **Reviewed against:**
  - plan Part 3b (`plan:988-1020`, including its "As built" note) and Part 6b;
  - AGENTS.md and the owner rules;
  - the pen's Transpose screens (k5GTy, FJ8Ys), read through the pencil MCP and not saved.

## Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | conflicts in `segno_engine_api.h` and the regenerated bindings only: the trunk's `LE_ERR_NOT_FOUND`/`LE_ERR_TRUNCATED` (#1198) sit where this stack adds `LE_ERR_TRANSFORMED`. Both are kept by hand, then ffigen is re-run. A rebase chore, not a defect. |
| `flutter test` packages/segno_engine (SEGNO_ENGINE_LIB from this head) | +380, all passed |
| `flutter test` packages/looper_repository (same lib; includes the native case) | +816, all passed |
| `flutter test` at the app root | +3469 ~56, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues found (after `pub get` in every package of the scratch worktree) |
| `bloc lint lib test packages` | 0 issues, 884 files analysed |
| Native suites | as for 3a's head, which this Dart-only commit does not change: plain, ASAN and telemetry-off ALL PASSED x5 |

## Verified correct (traced)

- **Receipts.**
  - All three repository calls go through `_requestReceipt`. An admission refusal completes at once and nothing is posted; otherwise each completes with the callback's own result.
  - The native case asserts that queue acceptance is not the outcome (`completed` is false before the pump).
  - `EngineResult.capacity` at the ±12 limit reaches Dart, and the stored pitch stays 12.
- **Truthful projection.**
  - `Track.transpose` carries stored and effective as one record.
  - The native case walks the whole cycle:
    - a step reads `(stored: 1, effective: 0)` until the worker's render lands, then `(1, 1)`;
    - bypass reads `(1, 0)` with `transposeBypass` true;
    - un-bypassing sounds the cached render again.
  - A pending render therefore never claims a pitch (rule 3).
- **Guards.**
  - `record()` returns `EngineResult.transformed` on a transposed track and leaves it PLAYING.
  - An empty track's step is `invalid`.
  - Bypassed, a punch-in records (OVERDUBBING), the plan's rule.
- **Mock and fakes.**
  - The mock refuses step and install (it never holds material), models bypass with a receipt, and resets both at configure.
  - The four fakes take configurable admissions and results.
  - `dart analyze` over lib, test and packages is clean, so no exhaustive switch was missed.
- **No app surface changes.**

## Findings

### High

None.

### Medium

None.

### Low

**L1. The plan's "record-refusal notice" for Transpose is neither built nor moved.**

- **What the plan says:** Part 3b (`plan:994-995`) lists "the record-refusal notice".
- **What was built:** the "As built" note records that the refusal is only the return value of `record`.
- **Why it matters:**
  - For Speed, the same item was moved into Part 6a's text and success criteria (2b delta).
  - Part 6b's criteria name "a refused step shows one notice" and, on hardware, "the overdub refusal", but no app-side notice for a punch-in refused with `transformed` on a transposed track.
  - Until it is added there, a refused punch-in on a transposed track has no notice planned anywhere.
- **Fix:** add it to Part 6b's text and its first success criterion, as was done for 6a.

**L2. A cap refusal reads exactly like a pending render.**

- **What happens:** the "As built" note says the projection cannot tell a render waiting from one the cap refused (`LE_CACHE_REASON_BUDGET`); both read `effective` 0, and 6b decides whether to show the difference.
- **Why it matters:** with a 192 MiB cap, and since Part 4a-ii also spends that cap on stretch renders for every following track, a refused track can sit at "pending" indefinitely. That is a silent failure on the face (rule 3).
- **Fix:** make "show refused distinctly" a 6b success criterion rather than an open choice, or add the Dart query here.

## Notes

- `TransposePitch` is filled from two separately loaded native atomics. A torn read shows the previous buffer's state, which is still truthful, unlike the Speed factor's tear (2b delta L-D1).

Verdict: Approve (L1 and L2 are plan-text items for Part 6b).
