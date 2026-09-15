## Simplification Analysis

<!-- cspell:words renamex EEXIST -->

### Core Purpose

Use the Mac's existing SSH access to browse complete appliance audio, listen to a whole recording with seeking, choose and name files to keep, and produce verified local copies without changing source recordings or replacing existing destination files.

### Reviewed scope and revision

- Review refreshed: 2026-09-15T16:52:11+00:00.
- Base: `origin/master` = `848f1337251989f849c7851f72b6126b5c1712ea`.
- New companion source/tests/workflow/planning documents remain untracked; `segno-ui.pen` and `docs/PROGRESS.md` are modified. No commit SHA identifies the new source yet.
- Reviewed source fingerprint: `a3dcbc34b7f930991bce826d5bbbed2b05894d4f433b8a727bcff46fc13e63f0` (SHA-256 of the sorted per-file digest manifest below).
- The initial full-package review is refreshed for the complete preview delta: PreviewPlayer, PreviewControls, AppModel preparation/cleanup/progress guards, ContentView integration, quit handling, tests, README, planning/progress documents and design changes.
- TransferCore, the positional SSH protocol and the appliance jq/sha256sum helper remain in scope. The previous redundant Cocoa-error handler has been removed.
- No implementation edits, live UI calls, appliance operations, merge actions or label changes were performed by this reviewer.
- These role conclusions are limited to the recorded files. The product merge gate in #1056 remains in force.

### Unnecessary Complexity Found

None unresolved.

### Code to Remove

None. Estimated additional LOC reduction: 0.

### Resolution of Previous Suggestion

The unreachable NSCocoaErrorDomain catch around renamex_np has been removed. TemporaryDownload.publish now has one native exclusive-rename check, a direct EEXIST retry, and a POSIX error throw for other failures. The original non-overwrite guarantee and numbered-suffix behavior remain intact. The prior suggestion is resolved and is not returned as an active finding.

### Simplification Recommendations

No additional simplification is needed for the approved behavior. Keep the current focused separation and do not replace it with a generic streaming, transport, caching or playback framework.

### YAGNI Violations

None. Full-file preview and seeking were explicitly requested. It reuses verified downloads into a temporary folder instead of adding another transfer implementation, appliance service or remote playback protocol. The private preview copy is replaced/removed directly; there is no persistent cache index, speculative format conversion or cross-platform layer. No document removal is proposed.

### Complexity That Earns Its Place

- PreviewPlayer is a small owner for AVPlayer's state, duration, time observer, completion observer and error observation. PreviewControls remains a focused native view. Inlining these into ContentView would obscure required resource lifetime behavior.
- AppModel owns one current preview directory and coordinates its creation/removal around the existing repository call. It preserves normal download selection and destination state without duplicating that state.
- The second cancellation check after asynchronous duration loading and observer identity guards address actual asynchronous boundaries. They are appropriate safeguards rather than speculative fallback paths.
- The repository protocol has a real test implementation. SSH executable injection enables real subprocess/helper/filesystem verification while avoiding live appliance access in tests.
- Byte count, source version, checksum, WAV validation and atomic exclusive rename enforce distinct requested invariants. Removing one merely because another exists would weaken behavior.
- The jq emitter is longer than an unavailable Python JSON library call, but using already-installed appliance tools is a verified deployment requirement. The CI fixture dependencies now explicitly match it.
- The scoped view decomposition and package split are sufficient. No extra coordinator, generic view factory, state framework or package is warranted.

### Verification and limits

- Independently reran the configured Swift formatting lint over package source, Swift tests and manifest after the preview observer guards; it passed with no diagnostics.
- Independently compiled the actual current PreviewPlayer source with an isolated, muted AVFoundation probe, without opening the application or connecting to the appliance. A 2.17-second WAV played to its end (`duration=2.17`, `position=2.17`, `isPlaying=false`), and the next Play restarted it (`position=0.400187796`, `isPlaying=true` after 0.6 seconds). This checks the actual native playback wrapper, not a source-text assertion or replacement implementation.
- The coordinating task reports 18 Swift and 13 Python tests passing before the final observer-identity guard cleanup. Those suite results were not independently rerun by this role and are not represented as final-head CI results.
- The coordinating task also reports a real two-file download with custom names, matching source hashes, and correct Finder reveal. These are reported coordination results, not appliance/UI actions performed by this reviewer.
- Live preview acceptance is being exercised separately by the coordinating task. No claim is made here about audible quality, appliance audio under transfer load, Apple notarization, or CI/merge readiness.

### Final Assessment

- Critical: 0; Important: 0; Suggestion: 0.
- Total potential LOC reduction: 0% identified.
- Complexity score: Low.
- Recommended action: Already minimal for the approved download and full-file preview scope.

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
