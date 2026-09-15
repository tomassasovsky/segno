# Segno Transfer — Test Quality Review

## Scope and revision

Reviewed all new files under `apps/segno_transfer`, the Mac workflow, and the September 15 recording-downloader brainstorm/plan, against `origin/master` **848f1337251989f849c7851f72b6126b5c1712ea**. This refresh includes the appliance-tool correction, strengthened transfer/cancellation tests, and the owner's added full-file preview with seeking.

The scoped implementation remains untracked. Current file hashes are recorded in `/tmp/segno-transfer-review-final-source.json`; aggregate SHA-256 **b9e45559226b6ee2eba7499b62635f995a6af37140b323b2a60bb547de122178** (ordered relative path, NUL, bytes, NUL). The final refresh changes only the corrected bad-length test fixture and spelling directives in README/plan; all production-file hashes remain identical to the preceding reviewed snapshot. Source changes after this snapshot require a focused review refresh. No application implementation edits, appliance connections, or device operations were performed by this reviewer. Mutation experiments used an independent copy under `/tmp`.

The stack is Swift Package Manager, SwiftUI/AppKit, AVFoundation, Foundation/CryptoKit, XCTest, and Python `unittest`. No third-party Swift test framework is present. Native GUI behavior is accepted as author-only product validation for this first companion, per the clarified review scope; the report does not represent it as CI UI coverage or infer an observable defect solely from the absence of automated view tests.

## Coverage summary

- **Swift: 18 passed**, zero failures, independently with coverage enabled; `/tmp/segno-transfer-review-swift-final.log`.
- Final corrected-fixture normal run: **18 Swift passed**, zero failures (7 AppModel, 2 PreviewPlayer, 9 Transfer), completed at 13:54:51 and reported by the parent from session `23472`; that run has retained tool output rather than a file log. The independent coverage run above preceded this test-fixture-only correction.
- **Python: 13 passed**, zero failures, independently with tracing enabled; `/tmp/segno-transfer-review-python-final.log`.
- Swift command: `swift test --enable-code-coverage --scratch-path /tmp/segno-transfer-review-build --package-path apps/segno_transfer`.
- Python command: `python3 -m trace --count --summary --missing --coverdir /tmp/segno-transfer-python-final-coverage --module unittest discover -s apps/segno_transfer/Tests/RemoteTests -v`.
- Swift data: `/tmp/segno-transfer-review-build/arm64-apple-macosx/debug/codecov/SegnoTransfer.json`.
- No Swift-specific numerical coverage threshold is configured. Existing Dart package thresholds do not automatically apply to this separate target.

| Production file | Reported line coverage | Evidence |
| --- | ---: | --- |
| `AppModel.swift` | 84.12% | Seven state tests, including active batch cancellation and preview failure |
| `PreviewPlayer.swift` | 72.41% | Actual AVFoundation playback, pause/seek/stop, invalid audio |
| `Models.swift` | 76.34% | Catalog/model decoding and input validation |
| `SSHClient.swift` | 79.20% | Real local child processes and cancellation |
| `TransferRepository.swift` | 93.62% | Catalog, verification, exclusive publication, cleanup, bad-length cases |
| `Resources/appliance.py` | 75.3% | Python in-process trace; command-line subprocess execution is additional coverage |
| `ContentView.swift` | 0% | Author native GUI inspection; no CI UI tests |
| `PreviewControls.swift` | 0% | Author native GUI inspection; no CI UI tests |
| `SegnoTransferApp.swift` | 0% | Native composition and termination flow not automated |

LLVM's SwiftUI/generic instrumentation expands overlapping line regions; percentages above are the runner's per-file figures. Python tracing does not include child interpreters, so the JSON command-line and Swift transport scenarios execute additional helper code outside that percentage. Six of nine implementation files receive automated execution in these measurements. The GUI and entrypoint files have no corresponding automated tests; that is a declared coverage limit under the clarified scope, not an unresolved finding on its own.

## Findings

**Critical: 0 | Important: 0 | Suggestion: 0.** No actionable test-quality findings remain under the clarified review scope.

## Resolved findings and test quality

### Bad-length regression fixture — resolved with mutation proof

The final fixture distinguishes download and hash requests. Its hash response is valid JSON containing the matching SHA-256 of the exact short or oversized payload. A failure can no longer be caused by unrelated JSON decoding.

Independently copied the corrected test into the existing isolated `/tmp/segno-transfer-length-mutation` package, where the repository exact-length guard and both SSH output-size guards remain disabled. The corrected test fails **four assertions**: both bad-length operations fail to throw and publish files when no file should be published. Log: `/tmp/segno-transfer-length-mutation-corrected.log`. This demonstrates that the test detects removal of the required validation. The original ineffective fixture had passed the same mutation (`/tmp/segno-transfer-length-mutation.log`). The actual worktree was untouched.

### Active cancellation — resolved

`testCancellationRestoresControlsAndKeepsSelection` now selects three files, holds the second repository job, and waits for a locked start counter to reach two before cancelling. It verifies one completed download, two retained selections, deselection of the completed performance, retention of the cancelled/unattempted performance, cancelled status, and return to idle. This now exercises active work instead of cancelling before the scheduled task starts.

### Resistant transport cancellation — resolved

The new process fixture installs `SIGTERM` ignore before producing output. Cancellation begins only after that output is observed. The test completes within its five-second bound and checks that the destination contains no temporary or completed file. The production call waits for child termination before returning, so a completed test establishes that this child no longer runs; it cannot merely report a cancelled state while leaving its writer active.

### Native GUI test requirement — clarified scope

The earlier missing-view-tests finding is withdrawn under the task's clarified validation contract. The author reports native CUA evidence for connecting to the appliance, selecting two files, assigning custom local names, changing the destination, downloading, independently comparing source SHA-256 values, and revealing copies in Finder. Those are author-only checks, not checks independently repeated by this reviewer or run in CI. The parent subsequently reports native AX inspection of a real 8:26 preview paused at 2:31 with its seek bar, and replacement removing the first 53 MB preview directory while retaining the active private copy. The user's active preview state was preserved. This evidence must not be reported as automated rendered-state coverage.

### Appliance compatibility and malformed metadata — corrected with meaningful tests

The helper now uses the image's minimal Python plus `jq` and `sha256sum`. `testWorksWithMinimalAppliancePython` intercepts Python imports to reject `json` and `hashlib`, then runs the actual embedded helper for catalog, download, and hash verification. It produces a correctly named complete WAV through the real repository. This directly protects the deployment failure found by the author's appliance test.

Python tests now execute the actual helper entrypoint and decode its real JSON for empty catalog, quotes/Unicode/newlines in recording names, and malformed numeric metadata alongside a healthy recording. The latter proves one bad recording does not prevent listing healthy ones. Existing tests continue to cover traversal, symlinks, stale versions, raw PCM exclusion, unfinished/corrupt captures, truncated audio, recovered folders, and hashes of exact bytes.

The workflow explicitly installs `jq` and `coreutils`, exposes the latter's command names, then runs Python tests, Swift formatting, Swift tests, and an actual app bundle build on macOS. Fixture tools are therefore declared instead of depending on accidental runner contents.

### Preview playback — meaningful behavior tests

`PreviewPlayerTests` writes an actual two-second stereo WAV with AVFoundation, loads its duration, starts muted playback, waits for observed position advancement, pauses, seeks to 1.5 seconds, waits for the real player callback, and stops/reset-checks the player. Invalid bytes fail without starting playback. This exercises the platform player, rather than a fake whose properties mirror the implementation.

Independent mutation proof: removed the actual `AVPlayer.seek` invocation in the `/tmp` copy and reran the playback test. It failed, observing approximately 0.23 seconds instead of 1.5 seconds; log `/tmp/segno-transfer-seek-mutation.log`. Thus the seeking assertion detects a real playback regression rather than only checking the eagerly assigned model property.

`AppModelTests` also verifies a failed preview preserves the download selection and destination, surfaces the error, and clears preview state. The app's preview preparation reuses the same verified-download repository covered by transfer tests.

### General quality

Tests use isolated temporary fixtures, per-test cleanup, isolated UserDefaults suites, an injected repository for state tests, and actual helper/child-process execution for transport tests. Assertions verify file bytes, preservation of an existing destination, numbered exclusive publication, status/selection transitions, and playback observations. No source-text matching, mocked unit under test, tautological assertions, or unnecessary external dependency was introduced.

## Limits

- Native view rendering, folder/Finder dialogs, startup resource packaging, and quit confirmation are author/manual checks rather than CI tests.
- Preview replacement/close/app-exit temporary-folder cleanup is inspected in the implementation but is not independently asserted end to end by the current model tests; the parent separately reports real-preview replacement removing its previous temporary directory. Closing or quitting was not repeated here while the user retained an active preview.
- Playback-end notifications, AVPlayer late-status errors, transport inactivity timeout, and disk-full failures are not all covered by injected regressions. The tests establish the listed paths, not exhaustive operating-system failure coverage.
- The muted playback test proves timing and seeking, not audible quality. Appliance audio-under-transfer stress is outside this companion's file-copy validation.
- This local review does not claim green hosted CI on a committed final SHA or replace the product merge gate.

## Verdict

**No unresolved findings.** The original substantive gaps are resolved, the bad-length test now detects a deliberately broken implementation, and the preview test detects removal of real seeking. The reported normal final suite passes all 18 Swift tests. Native GUI/device evidence remains author-only and the coverage limitations above remain explicit. No verified implementation bug was found in this refresh; this review does not itself grant product merge approval.
