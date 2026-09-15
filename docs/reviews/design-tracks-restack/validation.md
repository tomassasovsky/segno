# Tracks reconstruction validation

Date: 2026-09-15. Base: master `848f1337`. Original first-slice parent:
`ec3e25f0`. This record covers only the reconstructed Tracks, selected-track
display and crown slice. It does not certify later branches in the stack.

## Local evidence

The final full app suite passed **2,250 tests**, with six existing skipped
legacy toast/banner tests. The 20 package suites passed **1,575 tests** in
total, using the final reruns for changed packages rather than double-counting
earlier executions. No source changes followed these results.

- All 20 package suites passed in their own package directories. The changed
  engine and looper packages were then rerun with the final native library:
  276 and 431 tests passed respectively, including the native-dependent tests.
- Fatal Dart analysis passed with no issues. Bloc lint scanned 598 files with
  no issues, and formatting checked 597 files with no changes. Temporary
  test-generated analyzer exclusions were removed before the final checks.
- Repository Markdown spelling and whitespace/conflict checks passed.
- Normal native tests, AddressSanitizer, telemetry-disabled tests and the
  ThreadSanitizer race suite all passed. Native configurations used separate
  temporary directories so concurrent runners could not overwrite binaries.
- The non-Clang C++ atomics-shim compile passed with the public engine header
  included inside C linkage and the standard-library minimum function in scope.
- Bindings were regenerated and formatted. All 146 dynamically resolved
  symbols exist in the full macOS host library; the symbol-checker tests passed.
  The smaller device-free test library is not used as a full symbol inventory.
- The control-center and Settings screenshot suite passed all 49 tests.
  Changed display copy, current UART controller state, and compact/full-size
  layout checks are author validation, separate from remote CI.

## Coverage gates

Coverage uses the existing workflow exclusions and floors; none was lowered.

| Suite | Covered / measured lines | Coverage | Required |
| --- | --- | --- | --- |
| Root app | 15786 / 16863 | 93.61% | 90% |
| Looper repository | 1934 / 1980 | 97.68% | 95% |
| Session repository | 491 / 546 | 89.93% | 89% |
| Performance repository | 450 / 450 | 100% | 99% |
| Pedal repository | 512 / 524 | 97.71% | 96% |
| Controller repository | 286 / 317 | 90.22% | 82% |
| DAW export | 421 / 421 | 100% | 100% |

## Boundaries

An intermediate full app run exposed a wall-clock race in an unchanged
knob-save test. Eight debounce tests now use a controlled clock while
preserving all 20 original verification statements. The full test file passed
104 tests, independent review found no assertion or cleanup regression, and
the final aggregate run above includes that repair. Six existing root skips
are legacy App toast/banner tests
whose old widget-key assertions do not match the toast overlay (tracked in
#453); they are not counted as passing tests.

No appliance deployment, firmware flashing, physical two-display test, real
pedal timing or interface-level audio measurement was performed. Linux and
Windows builds remain remote CI checks. The human merge gate is unchanged.
