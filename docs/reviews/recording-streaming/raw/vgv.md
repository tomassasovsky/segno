## VGV Code Review

### Summary

No unresolved VGV convention findings in the final streaming delta. The native resource loader reads bounded sections through the repository, keeps request state on a serial queue, and delivers player state through the main actor. Whole-file preview preparation is removed. The kept-download path retains its source checks, complete SHA-256 verification and atomic publication. One immediate-cancellation race was independently reproduced during review and is resolved in the final source with a regression test.

### Scope and revision

- Review recorded: 2026-09-15T17:22:45+00:00.
- Base commit: `f6c309244058a5856e9a558e210d352707c711cd`. HEAD still equals that base; the streaming delta is uncommitted.
- Current delta fingerprint: `26034ca8639824da6b0a701bf755c2c38fa670b2a45c5978be014af0c0043e4a` (SHA-256 of the sorted per-file digest manifest below).
- Reviewed all 17 changed/new files: the remote loader, AppModel/player/control changes, repository read operation, SSH stdin helper transport, appliance range helper, Swift/Python test changes, README, progress/planning documents and companion design changes.
- Final review includes AppModel's cancellation check before player preparation and its immediate-cancellation regression test.
- Native SwiftUI/Foundation/AVFoundation conventions apply. The Flutter instrument's state framework is not imposed on this separate Mac companion.
- No implementation edits, installed-app operations, appliance operations, merge actions or label changes were performed by this reviewer. Test work used an isolated scratch copy.
- This is a source-role review of the recorded delta. #1056's product merge gate and live UI acceptance remain separate.

### Critical — Must Fix Before Merge

None unresolved.

### Important — Should Fix

None.

### Suggestions — Nice to Have

None.

### Regressions and removal assessment

- The removed private full-preview directory, complete preview download, cleanup bookkeeping and file-URL preparation are replaced by requested-range streaming. No compatibility copy or silent full-download fallback remains in AppModel.
- RecordingRepository gains one read operation. The implementation and test fixture conformances are updated. Existing download success, failure, byte-count, checksum and collision tests remain present; fixture command parsing is updated for the stdin transport.
- SSHClient now supplies the bundled helper through a fresh input file handle rather than an oversized inline command. The quoted positional fields remain separate, and batch authentication/known-host validation are retained.
- The source delta does not modify the Flutter app, native instrument callback, firmware, exported C API or generated bindings.

### Architecture, state and lifecycle assessment

- Views render playback state and dispatch actions. They do not implement range selection, SSH transport or decode/publish rules. AppModel passes the repository operation into RemoteAudioLoader; the loader has no dependency on concrete SSHClient internals.
- RemoteAudioLoader owns AVFoundation's resource request lifecycle. Its pending-request map, stop flag, failure handler and resource callbacks are confined to its serial dispatch queue. Blocking reads run in an OperationQueue limited to two concurrent operations.
- Each repository call requests at most 1 MiB. Repository and appliance both validate the requested interval; the repository rejects short responses. The helper validates the listed source version before and after reading. Preview relies on authenticated SSH integrity and source-version checks; saved downloads continue to receive complete SHA-256 verification.
- Cancellation removes the matching request token. Stop cancels pending tokens, finishes unfinished requests, clears tracking and cancels queued worker operations. Results are applied only while their request/token still match, so obsolete reads cannot supply a replacement request.
- PreviewPlayer retains the asset/loader for the current preview, cancels both loading and reads on stop/replacement, and guards asynchronous observer/failure updates with current-asset or current-item identity. Observer invalidation and published-state reset remain explicit.
- A loader failure pauses playback, stops outstanding reads and presents an error; the controls disable further Play while that error persists. Buffering is driven by the native player's time-control state, not guessed from bytes received.
- AppModel checks cancellation before starting asynchronous player preparation as well as afterward. The first check closes the verified race where immediate cancellation occurred before the preparation task started.
- No new unsafe optional dereference requiring an actionable fix was found. The loader's URL unwrap uses a fixed valid scheme/path plus a generated UUID; no user-provided value enters that construction. The new types add no lint suppression or framework dependency.

### Tests and documentation

- StreamingTests covers the new stateful loader/player path with real AVFoundation and a synchronized range fixture. It tests observable progress and requested byte intervals rather than source text.
- Range tests exercise the actual helper process for beginning, interior and ending slices, stale versions, negative/oversized/out-of-bounds intervals and short responses. The helper-command size assertion is combined with actual subprocess execution and output assertions.
- AppModel's new immediate-cancellation test requires zero repository reads, unchanged selection, no preview/error and a cancelled status. The failed-stream test also ensures the full-download operation was never invoked.
- The changed Swift test methods preserve existing kept-download behavior checks. Test fixture shared counters and disconnection state use locks where worker threads access them.
- The new preview UI adds buffering/error state only; its labels and controls remain consistent with the existing native companion. No generated/localization artifacts are changed.
- Design JSON comparison against the base found changes only to `sgt-companion` and `sgt-rationale`, with no added/removed nodes or unrelated top-level changes. The design and docs now describe range streaming and cancellation, while retaining the distinction between preview integrity and complete saved-download verification.

### Simplicity Assessment

- Required removal: 0 additional lines.
- Unnecessary abstractions: none.
- YAGNI violations: none; the owner explicitly requested streaming.
- Complexity verdict: appropriate for integrating system AVFoundation loading with the existing SSH interface. Serial ownership and bounded worker concurrency serve concrete resource/lifecycle requirements.

### Testing Assessment

- New units with tests: RemoteAudioLoader is exercised through StreamingTests; PreviewPlayer and AppModel retain and extend their corresponding suites.
- Test quality: meaningful success, distant-seek, cancellation and failure assertions.
- State coverage: useful behavior coverage, without a claimed numerical percentage.
- Automated SwiftUI interaction coverage: not added; final native GUI acceptance belongs to the coordinating task.

### Verification evidence and limits

- Current delta passed `git diff --check` and the configured strict Swift formatting lint over package source, Swift tests and manifest.
- An independent scratch probe reproduced the initial cancellation race: preparePreview followed immediately by cancel still reached one repository read. Evidence: `/tmp/segno-stream-vgv-cancel.log`.
- The same probe against the final corrected AppModel passed: zero reads and idle completion in 0.015 seconds. Evidence: `/tmp/segno-stream-vgv-cancel-fixed.log`. Only the corrected source file was refreshed in the scratch copy between those runs; the probe was unchanged.
- New checked-in StreamingTests use actual AVFoundation resource loading over generated WAV range data. They assert playback before a full transfer, a distant seek into unread content, bounded request sizes, blocked-read cancellation, and connection-failure stop behavior. These tests were inspected; full suite execution remains with the coordinating/test task and was not duplicated here.
- The provided `/tmp/segno-streaming-live-result.json` was read. Its 388,628,012-byte appliance file began playback after 2,162,222 bytes in 3.244 seconds; the distant seek took 2.673 seconds; stop was true after 5,307,950 bytes total. This is coordinating-task evidence from the actual appliance probe, not a device operation independently performed by this reviewer.
- Native GUI acceptance was still underway when this report was written. The report does not certify audible quality, stress-free simultaneous appliance recording, final CI results, or merge readiness.

### Final drag-and-seek refresh

The native interaction correction is included in this review. PreviewControls owns only transient drag state: it displays the user's local value while editing and commits the seek when editing ends. Binding changes outside a drag continue to invoke seek immediately, preserving keyboard/accessibility updates. This is presentation interaction state, not misplaced transport logic.

PreviewPlayer owns a pending seek identity, suppresses periodic position updates while that seek is pending, and reconciles position from the native player when the matching completion arrives. Both the current item and seek UUID must still match before completion updates state. Stop resets the seek identity along with the asset/item and observer lifecycle. This prevents a prior seek completion from clearing a newer seek or updating a replaced preview. The change introduces no new data-layer dependency or feature scope.

The exact final delta from the preceding fingerprint is limited to PreviewControls.swift and PreviewPlayer.swift; all other recorded file digests are unchanged. Strict Swift format lint and diff whitespace validation passed after this change. Focused playback/stream test reruns are owned by the coordinating task; this role does not claim their result before it is supplied. No additional findings.

### Delta digest manifest

```text
c0bd741e83c7d3206f5ab856b9634eba9b5c0f614bfa0ab69900b781fbc2b88a  apps/segno_transfer/README.md
eeab71b5123975eb025cbd4558087c97ec70c15abbd7e4ef06a0e608e6cad077  apps/segno_transfer/Sources/SegnoTransfer/AppModel.swift
8ecf1643c61e310f46f812fd5e9ce31165ae90ac36c836ea46ac2cd15882b1ad  apps/segno_transfer/Sources/SegnoTransfer/PreviewControls.swift
eee06406b7c51e7faf91e91d9ebc84564ce50fa502f16c72c1b7d1b545532b7b  apps/segno_transfer/Sources/SegnoTransfer/PreviewPlayer.swift
7e29746dbb2138be931d731ad019cebe18fa548151df3e41ee4ec55e2e314dce  apps/segno_transfer/Sources/SegnoTransfer/RemoteAudioLoader.swift
89d9ce4a97c4bfb3e187fb6b9959bccc60b25967e52d0b33569a805208ca629b  apps/segno_transfer/Sources/TransferCore/Resources/appliance.py
12d1afb76385503034e8f86d892ce9e68760ebed355bfa9b0d7ef3a128605c06  apps/segno_transfer/Sources/TransferCore/SSHClient.swift
4427fbc92cbb8cbc8b01c42f4175d72657d6efc3f108f54172e4861cf3b829c8  apps/segno_transfer/Sources/TransferCore/TransferRepository.swift
f1740bcd2c1436c261bfa810343a05fa8e998b17533e39b46b8fccb7cefd2b7a  apps/segno_transfer/Tests/RemoteTests/test_appliance.py
5f25358a7f0121b65569e219d2bdc02ad3ec1fdfffab26e5f250d85b5feb5a55  apps/segno_transfer/Tests/TransferCoreTests/AppModelTests.swift
d4821ce53e49d264a7f9dba39dcfc34ba6910669e6736194b83315a7e5f0a54d  apps/segno_transfer/Tests/TransferCoreTests/PreviewPlayerTests.swift
45c64e3dc85e86685c7fc0f4f8af503ad4febd57bc27c1398d2e848862f5bf61  apps/segno_transfer/Tests/TransferCoreTests/StreamingTests.swift
2c3c8232fbd502ef93915f0d7265979b81b06875a5294e08f0afc96383df9466  apps/segno_transfer/Tests/TransferCoreTests/TransferTests.swift
2182f9baeb6ac51b58f68a545384f0d1a5a92dc82e1b17a8ced11c93887a39de  docs/PROGRESS.md
bd5e7fb4b5dcd1c55467a0394f948565114129755b5919b1fbde2c9743f723bf  docs/brainstorm/2026-09-15-recording-downloader-brainstorm-doc.md
e84ce63fd0ed0718501ddf7b938a8116cf72b928775590be8e171c9b296609bd  docs/plan/2026-09-15-feat-recording-downloader-plan.md
a42c5b9721df607ffefbf10e5c44447eb23fca74bc0dccf37c3b9b38e398f9f6  segno-ui.pen
```
