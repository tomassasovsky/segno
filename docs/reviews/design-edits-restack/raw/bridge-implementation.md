# Dart history recovery bridge implementation

This is an implementation note, not an independent review. This agent authored the bridge and its tests; another reviewer must inspect the resulting changes.

## Scope

- Added `AudioEngine.historyModeGate({required int channels, required bool redo})` through the existing `LooperTransport` interface. The argument is a track bitmask, and grouped callers preflight the whole group before executing members in ascending channel order.
- Added `EngineResult.modeMismatch` for native `-7` and `EngineResult.notReady` for native `-8`. Refused recovery retains history; mode incompatibility and temporary pending work remain distinguishable.
- `NativeAudioEngine` checks handle lifetime, forwards the complete mask and the direction as `0`/`1`, and maps the native result. The mock and session/performance test engines return `ok` because they model no incompatible history.
- Root and looper-repository test fakes expose configurable `nextHistoryModeGate`, `nextUndoResult`, and `nextRedoResult` fields, all initially `ok`. Their `historyModeGateCalls` records retain each mask and direction; the repository fake also records the query in its existing ordered `calls` log.
- Regenerated and formatted the FFI bindings after the native author saved the declaration and result codes. Native implementation, repository recovery behavior, and UI notices belong to other authors.

## Verification

- All 247 non-fuzz `segno_engine` tests passed, including 67 focused result/mock tests.
- `dart analyze` from `packages/segno_engine` reported no issues.
- Final root analysis reported no issues after the parent's in-progress repository lint was corrected.
- Bloc lint reported zero issues across 599 files.
- Explicit formatting checks covered all 11 changed bridge/test/helper Dart files; no formatting changes were required. `git diff --check` passed.
- Real FFI regression tests were added to `pumped_native_engine_test.dart`: full group mask versus individual masks, distinct undo/redo results, repeated non-consuming queries, refused undo/redo retaining history and PCM for Free-mode retry, pending mode acknowledgement, and disposed-handle rejection. All **35 tests** in the full file passed against a freshly built native library. Log: `/tmp/segno-edits-bridge-ffi.txt`. The disposed-handle expectation was corrected to the existing `EngineException(invalid)` contract after the first run; no production change was needed.
- Regenerated the bindings again after the final native policy documentation, then rebuilt the native library after the grouped-redo and defining-capture guards stabilized. All **35 real FFI tests** passed again. The pending-mode test uses a real cleared 750-frame take, verifies the wait before mode acknowledgement, and successfully recovers it after acknowledgement; a empty-history no-op is not used as the fixture.
- After the native author's final sibling-cancellation fix, regenerated bindings for its public comment and rebuilt once more. The full engine package passed **282 tests with coverage and no skips**, including all 35 real FFI cases. The library was handed to the coordinator and the independent bridge reviewer; it will not be overwritten during aggregate runs. Its final SHA-256 is `afeaa61afbdfc8cb4a020ea5395a52770cd64875bd7a8f41675f7c7a5a5a178b`.

## Evidence limits

The prior independent review checkpoints predate this bridge and do not certify it. No remote CI or real-device claim is made. No commits or Git refs were changed by this agent.

The separate bridge/simplicity reviewer subsequently reran the four history FFI tests and an additional public-Dart sibling-cancellation regression against the final library: all five passed. That reviewer owns the independent bridge assessment.
