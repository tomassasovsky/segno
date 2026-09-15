# Segno Transfer streaming — Test Quality Review

<!-- cspell:words coverdir hashlib -->

## Scope and revision

Reviewed the entire streaming delta from **f6c309244058a5856e9a558e210d352707c711cd**, including the new `RemoteAudioLoader.swift` and `StreamingTests.swift`, modified player/model/controls, range repository/helper/SSH transport, all affected tests, and the updated README, progress, brainstorm and plan. Read the existing Mac CI workflow and Swift package configuration. The revised design remains native-GUI author acceptance, outside automated view testing.

The final reviewed source is a working diff on that base. Scoped file hashes are recorded in `/tmp/segno-streaming-review-final-source.json`; aggregate SHA-256 **a77777d88a886ce66779cb8c5896fbef152dace228467b672161f6e93852fe4e** (ordered relative path, NUL, file bytes, NUL). This includes the final pre-prepare cancellation guard, permanent model regression, and the final drag/pending-seek correction. Only PreviewControls.swift and PreviewPlayer.swift changed after the preceding complete streaming review. Implementation remained read-only in the working checkout; the isolated regression used `/tmp/segno-streaming-cancel-repro`. No appliance connections, installed-app interactions, or device operations were performed by this reviewer.

## Findings

**Critical: 0 | Important: 0 | Suggestion: 0.** The one verified cancellation race discovered during this review was corrected and is covered by a regression test. No unresolved actionable test-quality findings remain.

## Coverage summary

The stack remains Swift Package Manager/XCTest, real AVFoundation, Foundation/CryptoKit, and Python `unittest`; no UI test or mocking framework was added.

- Independent full Swift suite with coverage: **23 passed**, zero failures; `/tmp/segno-streaming-review-swift.log`.
- Independent Python suite: **14 passed**, zero failures; `/tmp/segno-streaming-review-python.log`.
- Independent exact-source early-cancellation regression after correction: **1 passed**; `/tmp/segno-streaming-early-cancel-fixed.log`.
- Read author full-suite log `/tmp/segno-streaming-final-swift.log`: **24 passed**, zero failures, including the permanent immediate-cancellation test, before the final player/control drag correction.
- Read author focused final-player log `/tmp/segno-streaming-seek.log`: **5 passed**, zero failures (2 local PreviewPlayer + 3 real Streaming tests), after that correction, ended 14:20:37. The earlier independent coverage percentages are from the 23-test run and are not recomputed figures for the final control delta.

Commands:

```sh
swift test --enable-code-coverage --scratch-path /tmp/segno-streaming-review-build --package-path apps/segno_transfer
python3 -m trace --count --summary --missing --coverdir /tmp/segno-streaming-python-coverage --module unittest discover -s apps/segno_transfer/Tests/RemoteTests -v
```

Coverage data: `/tmp/segno-streaming-review-build/arm64-apple-macosx/debug/codecov/SegnoTransfer.json`.

| Changed production file | Reported line coverage | Automated evidence |
| --- | ---: | --- |
| `RemoteAudioLoader.swift` | 92.86% | Three real-player streaming scenarios |
| `PreviewPlayer.swift` | 81.22% | Local playback tests plus streaming/cancel/disconnect |
| `AppModel.swift` | 85.22% | State tests; final guard additionally verified in isolated regression |
| `TransferRepository.swift` | 94.74% | Exact range, invalid/stale/short response, plus complete-download regressions |
| `SSHClient.swift` | 80.15% | Actual local subprocess/helper input/output and cancellation |
| `Resources/appliance.py` | 70.9% | In-process Python trace, excluding child-interpreter execution |
| `PreviewControls.swift` | 0% | Native-GUI author validation; no CI rendered-state tests |

No numerical Swift coverage threshold is configured. LLVM's reported line regions are not a manual physical-line count. Python command-line range tests and the Swift subprocess tests execute helper code outside the in-process tracing percentage. Every changed service/state unit has automated behavior coverage; the only changed UI component without a corresponding automated test is `PreviewControls.swift`, under the accepted native-GUI author-validation boundary. Unchanged `ContentView.swift` and app-entrypoint/native-quit paths likewise remain outside CI UI coverage.

## Streaming behavior and assertion quality

### Playback begins before the full file is fetched

`StreamingTests.testPlaybackStartsBeforeFullTransferAndSeeksToUnreadAudio` supplies a generated 600-second stereo WAV through the real `RemoteAudioLoader` to the real `AVPlayer`. The fixture synthesizes only requested ranges and never allocates a whole 230 MB file. The test waits until the player's observed clock advances beyond 0.1 seconds, then asserts less than 10% of the file has been requested. This measures playable streaming rather than merely asserting that a player was told to start.

The test confirms the 450-second region is absent from initial requests, seeks there, waits until the actual clock advances beyond 450.1 seconds, and verifies new high-offset requests. Assigning the model's seek position alone cannot satisfy the advancing-clock assertion. Each requested range must be at most 1 MiB, and aggregate reads remain below 20% at the end. These assertions would reject full-file preparation and nonfunctional distant seeking without mirroring the resource-loader implementation.

### Stop, preparation cancellation, and disconnect

- Normal stop checks that no new reads appear after a bounded settling period.
- Closing during preparation waits until the fixture has actually entered a blocked read, then stops the player. Preparation must complete with failure and zero duration within a bounded interval. This covers an active cancellation rather than cancelling before a task starts.
- Disconnect during distant seeking begins from real advancing playback, makes subsequent range reads fail, seeks to unread audio, then requires a visible player error and stopped playback. The error crosses the actual loader/player boundary.
- Existing local-preview tests still prove decoded duration, playback advancement, pause, seek, stop/reset, and invalid-audio rejection. Playback is muted; these tests do not claim audible quality.

The range fixture records requests under a lock and has explicit bounded readiness/settling waits. It is a data-source substitute, not a mock of the player or loader under test. No source-text matching or tautological assertions were introduced.

## Repository and appliance contracts

The new repository tests use the actual helper through a local process substitute. They compare exact beginning, middle, and end byte ranges with source bytes, then modify the source and require a stale-selection failure. Invalid requests include negative offset, zero length, over-1-MiB length, crossing EOF, and `Int64.max`; a successful-exit short response is separately rejected.

The Python range test invokes the helper as a subprocess, verifies exact output bytes for valid ranges, and asserts both nonzero status and empty stdout for invalid ranges. This exercises the CLI boundary instead of duplicating `run()` logic in the test. The helper-input change is exercised by actual stdin delivery and by the existing minimal-appliance test that rejects Python `json`/`hashlib` imports.

Complete-download tests continue to cover SHA-256 verification, existing-file preservation, exclusive numbered publication, stale source rejection, partial failure, ordinary/forced cancellation, and bad lengths. The earlier corrected bad-length fixture still returns a matching hash for its bad payload, preserving the regression quality established in the previous review.

The existing Mac workflow discovers the new tests automatically through `swift test` and continues installing helper fixture tools before Python/Swift checks and the app bundle build.

## Resolved review finding: immediate cancellation could start a new read

The initial streaming model scheduled preparation, but checked its operation token only after `previewPlayer.prepare`. Calling `preparePreview()` and `cancel()` synchronously could stop the old/empty player before that task began. The task then started a new loader despite its already-cancelled operation token.

An independent test in `/tmp/segno-streaming-cancel-repro/Tests/TransferCoreTests/EarlyPreviewCancelTests.swift` reproduced the issue: one repository read began and the model remained busy after immediate cancellation. The source was otherwise the reviewed worktree snapshot. Log: `/tmp/segno-streaming-early-cancel.log`.

The final guard checks cancellation before preparation. The same independent blocked-read regression now passes in approximately 0.33 seconds, with no read started; log `/tmp/segno-streaming-early-cancel-fixed.log`. The tested `AppModel.swift` hash **eeab71b5123975eb025cbd4558087c97ec70c15abbd7e4ef06a0e608e6cad077** exactly matches the corrected working-checkout file.

The permanent `AppModelTests.testImmediatePreviewCancellationDoesNotStartReading` checks a locked repository read counter remains zero, selection is unchanged, no preview/error remains, the model returns to idle, and status says the preview was cancelled. This directly protects the verified race. The existing failed-preview test also proves selection/destination preservation and that preview preparation does not call full-file download.

## Final drag and pending-seek correction

Reviewed the final two-file delta independently. `PreviewControls` keeps its own drag position while editing and commits the chosen value when dragging ends; ordinary non-drag binding changes still invoke seeking. Playback time updates therefore no longer overwrite the actively dragged thumb. `PreviewPlayer` suppresses periodic position writes while a seek is pending. Each seek captures the current item and a new UUID; completion can clear pending state and publish the actual player position only if both still match. `stop()` resets pending state, so old completions cannot modify a closed/replaced preview.

No verified issue was found in this delta. The five real-player tests pass on this source. In particular, the streaming test still requires observed clock progression beyond 450.1 seconds after seeking to 450, so assigning 450 and suppressing every future clock update cannot make it pass. Native dragging itself remains an author-only interaction check and was still in progress when the parent supplied the focused-test result; no automated drag-gesture coverage is claimed.

## Author-only live evidence and limits

Read `/tmp/segno-streaming-live-result.json`, supplied by the parent. The author's real-appliance run reports a 388,628,012-byte recording beginning playback in **3.24 seconds after 2,162,222 bytes**, a seek taking **2.67 seconds**, and stopping after **5,307,950 total bytes**. The recorded ranges are each at most 1 MiB and include the distant seek region. These measurements support the real streaming claim, but are author evidence rather than an appliance operation independently repeated by this reviewer.

Native GUI buffering text, play/pause/seek controls, replacement and quit behavior remain author-only acceptance checks. No mandatory new UI testing framework is inferred for this narrow companion. Coverage does not establish all AVFoundation timing/error branches, buffering under every network condition, the full SSH inactivity-timeout path, or audio-under-transfer stress on the appliance. Streaming relies on SSH transport integrity and source-version/exact-range checks; complete downloads retain their separate SHA-256 verification.

## Verdict

**The reviewed streaming delta passes the test-quality gate with no unresolved findings.** Automated tests establish playback before full transfer, distant seeking into unread data, bounded range sizes, cancellation and failure propagation. The discovered immediate-cancellation race is independently reproduced, corrected, and covered. Keep final committed-head CI and native product acceptance separate from this local test review.
