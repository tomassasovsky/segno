## VGV Code Review

### Summary

No unresolved VGV convention findings in the complete reviewed companion revision, including full-file preview playback and seeking. The native SwiftUI design remains appropriately small and layered: views dispatch actions; AppModel coordinates selection and transfers through the repository; TransferCore owns SSH and verified file publication; PreviewPlayer owns native local-file playback and observable playback state. The preview does not alter the selected download set or publish files into the chosen download folder. This is a source convention review, with live acceptance and the product merge gate tracked separately.

### Reviewed scope and revision

- Review refreshed: 2026-09-15T16:52:11+00:00.
- Base: `origin/master` = `848f1337251989f849c7851f72b6126b5c1712ea`.
- New companion source/tests/workflow/planning documents remain untracked; `segno-ui.pen` and `docs/PROGRESS.md` are modified. No commit SHA identifies the new source yet.
- Reviewed source fingerprint: `a3dcbc34b7f930991bce826d5bbbed2b05894d4f433b8a727bcff46fc13e63f0` (SHA-256 of the sorted per-file digest manifest below).
- The initial full-package review is refreshed for the complete preview delta: PreviewPlayer, PreviewControls, AppModel preparation/cleanup/progress guards, ContentView integration, quit handling, tests, README, planning/progress documents and design changes.
- TransferCore, the positional SSH protocol and the appliance jq/sha256sum helper remain in scope. The previous redundant Cocoa-error handler has been removed.
- No implementation edits, live UI calls, appliance operations, merge actions or label changes were performed by this reviewer.
- These role conclusions are limited to the recorded files. The product merge gate in #1056 remains in force.

### Critical — Must Fix Before Merge

None.

### Important — Should Fix

None.

### Suggestions — Nice to Have

None.

### Convention assessment

- Native main-actor ObservableObject state and SwiftUI bindings are appropriate for this separate macOS application. No Flutter Bloc machinery is required. Recording values use immutable fields; connection settings remain a value type.
- Presentation does not execute SSH, decode remote manifests, verify hashes or publish completed files. The repository protocol remains a meaningful AppModel test seam, while local subprocess fixtures exercise real helper/file behavior.
- PreviewControls renders published playback state and dispatches play/pause/seek/close actions. AVPlayer, its item, duration loading and observers are contained in PreviewPlayer rather than embedded in view rendering.
- AppModel.preparePreview reuses the same source-version, length and checksum validation as a kept download. It creates one private temporary directory and removes it on failure, cancellation, replacement, connection change or close. Application termination invokes closePreview; quitting during preparation first waits for cancellation/cleanup.
- Preview preparation keeps the normal selected set, names, chosen destination and completed download list intact. It uses the shared busy gate, so a new preview cannot overlap an active transfer/preparation. Ordinary local playback can continue while an independent kept download runs.
- Duration is validated before playback; expected errors are published in model/player state. Seeking clamps its target. Player observations use weak owner captures and current-item identity checks; stop removes the periodic observer, notification observer and KVO observation before clearing the current item and published state.
- Progress callbacks check both the current operation token and busy state before updating presentation. Cancelled or superseded operation callbacks therefore do not reintroduce a stale footer after completion or a later operation.
- No production force unwrap, debug logging, unsupported lint suppression, generated-code mismatch or dependency on the Flutter instrument runtime was found.
- The native app bundle still embeds its helper explicitly. The dedicated macOS workflow now installs jq/coreutils for fixture execution before helper tests, formatting, Swift tests and app packaging.

### Design and documentation assessment

The design source was parsed and compared with origin/master again. All 491 pre-existing top-level children are unchanged and none are removed; only the two companion nodes are added, now containing preview references. Other top-level fields are unchanged. README and September 15 documents explain the whole-file preparation delay, play/pause/seek controls, temporary-copy cleanup, existing SSH trust, and the distinction between a complete WAV and a musically complete render. The progress note accurately keeps local delivery separate from product approval. This new English-language native package has no localization generator or alternate-language catalog whose generated parity could drift.

### Simplicity Assessment

- Required removal: 0 lines.
- Unnecessary abstractions: none.
- YAGNI violations: none; the user explicitly requested full-length listening with seeking before keeping a recording.
- Complexity verdict: appropriate for the current scope. PreviewPlayer earns its role by owning observable playback state and resource lifetimes; it uses the system player rather than introducing a separate decoding or streaming framework.

### Testing Assessment

- New state units have tests: AppModel and PreviewPlayer both have corresponding XCTest coverage.
- PreviewPlayerTests exercise a generated valid WAV through real AVFoundation, position advancement, pause, seek, stop/reset, and invalid-audio rejection. The reviewer additionally observed end/restart behavior using the actual wrapper.
- AppModel coverage verifies failed preview preparation preserves the download selection and destination and presents the failure without a preview. Existing model tests also cover success, retry, custom naming and cancellation after one completed file.
- Transfer tests check short/oversized successful process exits, signal-resistant cancellation, stale files, mismatch cleanup, exclusive collision naming, and operation with Python json/hashlib imports unavailable. Python tests verify finite metadata isolation and JSON preservation of quoted/Unicode/newline filenames.
- Automated AppModel coverage of successful preview replacement and temporary-directory removal remains partial; those exact UI/file lifecycle behaviors are assigned to live acceptance. This report does not imply full numerical coverage or an automated SwiftUI interaction suite.

### Verification and limits

- Independently reran the configured Swift formatting lint over package source, Swift tests and manifest after the preview observer guards; it passed with no diagnostics.
- Independently compiled the actual current PreviewPlayer source with an isolated, muted AVFoundation probe, without opening the application or connecting to the appliance. A 2.17-second WAV played to its end (`duration=2.17`, `position=2.17`, `isPlaying=false`), and the next Play restarted it (`position=0.400187796`, `isPlaying=true` after 0.6 seconds). This checks the actual native playback wrapper, not a source-text assertion or replacement implementation.
- The coordinating task reports 18 Swift and 13 Python tests passing before the final observer-identity guard cleanup. Those suite results were not independently rerun by this role and are not represented as final-head CI results.
- The coordinating task also reports a real two-file download with custom names, matching source hashes, and correct Finder reveal. These are reported coordination results, not appliance/UI actions performed by this reviewer.
- Live preview acceptance is being exercised separately by the coordinating task. No claim is made here about audible quality, appliance audio under transfer load, Apple notarization, or CI/merge readiness.

### Source digest manifest

```text
8be86e93e7905d30e7edf951dc17488f4a312ee78bbc71c50814b1379c9fe558  .github/workflows/segno-transfer.yaml
36ac59b964e6b6ec731c43e46e87b63a6e49b415a6df5236b5744bcd89e0bc39  apps/segno_transfer/.gitignore
aff7bfcd4aff87258a04844b49823c03d65da2e9b94699722976105d2f337a38  apps/segno_transfer/Package.swift
702bbe5088601a55c3ae3aef865492bae41851459729c0e89c455b1288f62060  apps/segno_transfer/README.md
9cc4fda3cf44eb7ea8d55c3825e4ed87bbee65ad1e6e16bbe8b15eb0580b6042  apps/segno_transfer/Sources/SegnoTransfer/AppModel.swift
f9b9af1e5ca3beb632cb5fe2509c4721a34068e3965352039461471c6ec75b57  apps/segno_transfer/Sources/SegnoTransfer/ContentView.swift
d0528f3632c89f4189073abb96d21a03c2dd95779503ba311465f012f6838e49  apps/segno_transfer/Sources/SegnoTransfer/PreviewControls.swift
e26dcafe1f7433f0584b45322f9cdc3aec4816b9412323331e9544b06a9129b7  apps/segno_transfer/Sources/SegnoTransfer/PreviewPlayer.swift
b89aeda2c9c4614718ae8c02fa7a7e18b9e75709285d0f6f73e55133221a9357  apps/segno_transfer/Sources/SegnoTransfer/SegnoTransferApp.swift
f0e53b4da94c8eae3938dde4fcd7020000ee487dfbcf669edf0d3bd25eed65b3  apps/segno_transfer/Sources/TransferCore/Models.swift
1b34cae8daf65c70c22f7dbf25899819c24514828fde631f63d7cb3da49a13ea  apps/segno_transfer/Sources/TransferCore/Resources/appliance.py
d203c8e242a4ec8abda9d2890edb846dbc174c071d02b8e91d54d778464ad518  apps/segno_transfer/Sources/TransferCore/SSHClient.swift
98781ee924f9104b80f557ab29278c2dfcbf06edf97b51d7cad95a15cbd6a6e8  apps/segno_transfer/Sources/TransferCore/TransferRepository.swift
9ed1988cbcd6dfc8533888f10d2cc9a446514e1b32294bedd89d8be4248634d5  apps/segno_transfer/Tests/RemoteTests/test_appliance.py
6a92c0538e8794f1af64603e296dbda9a8fafa1b9c554e26a98669e04a94051b  apps/segno_transfer/Tests/TransferCoreTests/AppModelTests.swift
f37c0116ac4810665aed64ad389b5806371967724097155959e5afdcc64f8de0  apps/segno_transfer/Tests/TransferCoreTests/PreviewPlayerTests.swift
59421771871794ddda7e570fc7e8e322beab49aa6ce99b30a027b81260deddd0  apps/segno_transfer/Tests/TransferCoreTests/TransferTests.swift
eb8b993be2039b78eb990dc71b79fa8e82e92265d0c5e911793041d60170a929  apps/segno_transfer/build-app.sh
a392926d322ff774ade5b50d5a54ca796a5abee3c05a6e4f32a989463fc339fe  docs/PROGRESS.md
9adc07ef1543c98d9ca7fac546c4b17155557403edaf9c161bc8c04511cc182c  docs/brainstorm/2026-09-15-recording-downloader-brainstorm-doc.md
6648eb17b579162f93100dcc0e88a04c66a31e9b3cb0588fcd1ac943f04bcd04  docs/plan/2026-09-15-feat-recording-downloader-plan.md
41fc4ee49f85ab16688d9ca9a851b04f5150f8b2ca7e3d0dd9aff06d4962b646  segno-ui.pen
```
