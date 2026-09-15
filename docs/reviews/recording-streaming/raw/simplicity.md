## Simplification Analysis

<!-- cspell:words AVURL -->

### Core Purpose

Start listening before an entire appliance recording transfers, seek to arbitrary positions by fetching the required sections, and stop obsolete network reads when the preview closes, changes or fails. Preserve the existing verified-download workflow for copies the user chooses to keep.

### Scope and revision

- Review recorded: 2026-09-15T17:22:45+00:00.
- Base commit: `f6c309244058a5856e9a558e210d352707c711cd`. HEAD still equals that base; the streaming delta is uncommitted.
- Current delta fingerprint: `26034ca8639824da6b0a701bf755c2c38fa670b2a45c5978be014af0c0043e4a` (SHA-256 of the sorted per-file digest manifest below).
- Reviewed all 17 changed/new files: the remote loader, AppModel/player/control changes, repository read operation, SSH stdin helper transport, appliance range helper, Swift/Python test changes, README, progress/planning documents and companion design changes.
- Final review includes AppModel's cancellation check before player preparation and its immediate-cancellation regression test.
- Native SwiftUI/Foundation/AVFoundation conventions apply. The Flutter instrument's state framework is not imposed on this separate Mac companion.
- No implementation edits, installed-app operations, appliance operations, merge actions or label changes were performed by this reviewer. Test work used an isolated scratch copy.
- This is a source-role review of the recorded delta. #1056's product merge gate and live UI acceptance remain separate.

### Unnecessary Complexity Found

None unresolved.

### Code to Remove

None identified. The obsolete full-file preview preparation and directory bookkeeping have already been removed; no additional LOC reduction is required.

### Simplification Recommendations

Keep the current focused implementation. The streaming change adds one native resource-loader adapter and one repository range method, reuses the existing SSH process lifecycle, and removes the old preview-copy workflow. No further generic transport or cache layer is warranted for the approved behavior.

### YAGNI Violations

None. Streaming is an explicit owner request. The code does not add an appliance service, extra listening port, encoding pipeline, full-file preview cache, persistence schema or speculative transport fallback. No document removal is proposed.

### Complexity That Earns Its Place

- The AVFoundation delegate adapter is necessary to bridge native requested ranges to the existing authenticated SSH interface. It exposes one read closure and does not create a second repository architecture.
- One serial queue owns mutable request state; a separate two-operation worker queue prevents blocking that delegate queue while keeping concurrent processes bounded. Collapsing those queues would either block cancellation/resource callbacks or lose the concurrency limit.
- The per-request CancellationToken and matching check reject late responses from cancelled AVFoundation requests. The early AppModel cancellation check handles a different boundary before the preparation task starts; both are necessary.
- The response-size, range-limit and source-version checks protect separate invariants at their actual boundaries. They are not redundant with the full-file SHA-256 path, which continues to serve saved downloads.
- The 15-second inactivity limit for short range reads is supplied through the existing SSH timeout mechanism; it does not introduce another process runner.
- Moving the helper to stdin removes the appliance command-size constraint directly. It keeps a single helper and protocol rather than splitting or installing scripts on the appliance.
- Buffering and failure state remain in PreviewPlayer. The native player supplies timeline/buffer behavior, so the application does not implement its own media scheduler or buffering algorithm.
- Optional local AVURLAsset preparation remains a small native-player test seam; it is not an AppModel full-file preview fallback.

### Final Assessment

- Critical: 0; Important: 0; Suggestion: 0.
- Total potential LOC reduction: 0% identified.
- Complexity score: Low to moderate, appropriate for the native streaming bridge.
- Recommended action: Already minimal for the requested streaming and seeking behavior.

### Verification evidence and limits

- Current delta passed `git diff --check` and the configured strict Swift formatting lint over package source, Swift tests and manifest.
- An independent scratch probe reproduced the initial cancellation race: preparePreview followed immediately by cancel still reached one repository read. Evidence: `/tmp/segno-stream-vgv-cancel.log`.
- The same probe against the final corrected AppModel passed: zero reads and idle completion in 0.015 seconds. Evidence: `/tmp/segno-stream-vgv-cancel-fixed.log`. Only the corrected source file was refreshed in the scratch copy between those runs; the probe was unchanged.
- New checked-in StreamingTests use actual AVFoundation resource loading over generated WAV range data. They assert playback before a full transfer, a distant seek into unread content, bounded request sizes, blocked-read cancellation, and connection-failure stop behavior. These tests were inspected; full suite execution remains with the coordinating/test task and was not duplicated here.
- The provided `/tmp/segno-streaming-live-result.json` was read. Its 388,628,012-byte appliance file began playback after 2,162,222 bytes in 3.244 seconds; the distant seek took 2.673 seconds; stop was true after 5,307,950 bytes total. This is coordinating-task evidence from the actual appliance probe, not a device operation independently performed by this reviewer.
- Native GUI acceptance was still underway when this report was written. The report does not certify audible quality, stress-free simultaneous appliance recording, final CI results, or merge readiness.

### Final drag-and-seek refresh

The final two-file UX correction is appropriately small. PreviewControls keeps one local drag flag/value so native clock updates cannot compete with a pointer gesture, and commits the seek on release. Outside a drag, binding changes still seek immediately. PreviewPlayer keeps one UUID to distinguish asynchronous seek completions and clears it on stop; older completions are rejected using that UUID and the current item.

These guards address the observed timeline behavior without adding a generic gesture controller or separate buffering model. No simplification is required. Only PreviewControls.swift and PreviewPlayer.swift changed from the preceding reviewed fingerprint; all other recorded digests are unchanged. Strict Swift format and diff checks pass. Focused real playback/stream reruns remain coordinating-task evidence until their results are supplied.

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
