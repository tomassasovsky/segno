## Simplification Analysis

<!-- cspell:words PPID -->

### Core Purpose

Publish the owner-approved free Apple Silicon companion with a disk image, installation guide, license and checksum, while making app termination finish the streaming work it owns.

### Scope and revision

- Final source review recorded: 2026-09-15T17:56:40+00:00.
- Committed HEAD: `158395fe2c6fa949276a8b821863e5f449def94a` plus the final uncommitted shutdown correction, regression test and matching README/progress updates.
- Packaging comparison base: `d8261ca22f67c91331c3a7c91ea615c3bcf22b40`; full companion branch comparison base: `origin/master` = `848f1337251989f849c7851f72b6126b5c1712ea`.
- Reviewed source/design/document fingerprint: `28034e4dd8ae829c1c57e688ffe2f54987e5c0d015f7e9a001262ebe15034061`. A final commit must retain these source blobs, or the changed scope needs another refresh.
- Packaging scope: build/package scripts, GitHub release workflow, installation guide, release notes, README and tracking-document additions.
- Bounded bug-focused scope: complete current AppModel, PreviewPlayer, RemoteAudioLoader, AppDelegate, PreviewControls and ContentView paths; repository/client cancellation, process and temporary-file ownership; removed full-file preview behavior; packaging/publication boundaries. Prior review evidence was reused only after checking current source and digests.
- No implementation edits, installed-app actions or appliance actions were performed by this reviewer. Process experiments ran in an isolated command-line build with local fake SSH and muted playback.
- User authorization explicitly permits free GitHub distribution and excludes paid signing/notarization. Overall current-head review/CI consolidation and publication remain with the coordinating task.

### Unnecessary Complexity Found

None.

### Code to Remove

None identified. Estimated additional LOC reduction: 0.

### Simplification Recommendations

Keep the current packaging structure. One native-tool script owns one staging directory and exit trap; one CI job validates/packages and one tag-only job publishes. No paid service, installer framework, update framework or generic release abstraction is introduced.

The shutdown fix uses the smallest ownership extension that handles previews already closed or replaced: each stop cancels immediately, a cleanup task retains that loader until workers finish, and accepted termination awaits the accumulated work. Keeping only the latest loader would miss earlier cleanup; waiting on the main actor would make closing unresponsive. The retained chain therefore has a concrete purpose.

### YAGNI Violations

None. Package contents, architecture/version checks and the clean generated app bundle serve the approved release. Streaming cleanup serves the verified process-exit defect. No document removal or paid signing/notarization is proposed.

### Resolved shutdown defect

The initial review at committed head 158395fe found that quitting during active streaming could exit before the SSH worker finished cancellation and deferred cleanup. A local process-level reproduction left a live child with PPID 1 plus its exact download.part and stderr files. The previous synchronous stop path only cancelled tokens; it could not run worker cleanup after process exit.

The final correction resolves the actual ownership boundary:

- PreviewPlayer.stop still cancels synchronously, then retains each stopped loader in a chain of cleanup tasks. The chain includes loaders from previews closed or replaced immediately before quit.
- RemoteAudioLoader.waitForReads waits for worker completion from a detached task, so repository/client termination, child reaping and temporary-file defers finish without blocking the main actor.
- AppModel.finishForTermination marks the model busy, stops the preview and awaits that cleanup chain. New transfer/preview actions cannot start during this final wait.
- AppDelegate returns terminateLater for every accepted quit with an initialized model. It waits for existing model operations to end, awaits final preview cleanup, and only then replies to the application's termination request.

Independent before/after evidence:

- `/tmp/segno-release-quit-before.json`: original process exits with a live orphan and both captured temporary files present.
- `/tmp/segno-release-quit-after-active.json`: corrected active-streaming quit exits with the child reaped and both captured files absent.
- `/tmp/segno-release-quit-after-closed.json`: closing first and immediately quitting produces the same clean result.

The harness used the actual player, loader, repository and SSH client with a local fake SSH child. Its final stop-plus-awaited-cleanup sequence matches the corrected model termination flow, which was also traced directly. Test-owned children and explicitly captured temporary files were cleaned after evidence collection. The finding is resolved; it is not returned as an active finding.

### Packaging and user-flow assessment

- package-app.sh verifies the app's local signature, requires arm64 and a three-component version, stages the app with an Applications symlink, installation guide and project license, creates/verifies a compressed disk image, then writes SHA256SUMS. One exit trap removes staging on success/failure.
- build-app.sh removes only its generated dist app before copying new output and verifies the new signature. It does not modify the installed app.
- The workflow packages the tested build, checks tag/app version equality, transfers DMG/checksum artifacts to a publishing job that depends on successful validation, verifies the existing tag and uses latest=false. Write permission is limited to that release job.
- Companion transfer-v tags do not match the appliance workflow's v* trigger. GitHub currently lists macos-15 as arm64, consistent with the package architecture gate: [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
- INSTALL.txt, release notes and README state Apple Silicon/macOS 14 requirements, local signing without notarization and existing SSH setup. Their first-launch Open Anyway path matches [Apple's instructions](https://support.apple.com/en-us/102445). No paid signing requirement or global security-disable instruction is added.
- License and corresponding source-tag links are included. This verifies packaging contents and user guidance; it does not claim legal certification.

### Verification evidence and limits

- Independent shell syntax and tracked diff whitespace checks passed. Strict Swift formatting passed after the shutdown correction. No actionlint pass is claimed because that executable was unavailable.
- `/tmp/segno-release-package-negative-check.log`: observed 9 actual-script packaging/version checks pass, covering missing/modified app, wrong architecture/version, image creation/verification failures and mismatched tags.
- `/tmp/segno-release-local-dmg-verification.json`: observed positive disk-image evidence for version 0.1.0, macOS 14, valid signature, app/helper identity, installation/license identity and the /Applications shortcut. Final artifact rebuilding/signature/checksum checks remain the coordinating task's delivery responsibility.
- `/tmp/segno-release-shutdown-tests.log`: observed 25 Swift tests passing. The final strengthened shutdown regression and all four streaming tests pass in `/tmp/segno-release-shutdown-regression.log`.
- The new regression holds cleanup for two closed loaders, releases the newer first, and requires shutdown to keep waiting for the older one. The independent test review's mutation log `/tmp/segno-shutdown-test-mutation-corrected.log` shows the regression fails when the previous-loader wait is removed. The test verifies required cleanup ordering, not source text.
- The coordinating task reports 14 Python tests passing; this correction leaves the helper unchanged. The process-level shutdown evidence above was independently reproduced by this reviewer.
- No installed-app operation, quarantined first launch or appliance operation was performed. Hosted CI, final public assets and consolidated review labels are not certified by this bounded source report.

### Final Assessment

- Critical: 0; Important: 0; Suggestion: 0.
- Total potential LOC reduction: 0% identified.
- Complexity score: Low for packaging; appropriate bounded ownership for shutdown.
- Recommended action: Keep the implementation. No further simplification is required for the approved scope.

### Reviewed source digest manifest

```text
41b41a96c36927775d6e00e7a1841ac7e43c5c6904bba439b7ca23c349ed94cd  .github/workflows/segno-transfer.yaml
36ac59b964e6b6ec731c43e46e87b63a6e49b415a6df5236b5744bcd89e0bc39  apps/segno_transfer/.gitignore
0180809f94522a26ab41ff7efae602a3ce712eefe92b5bfd3f6b3efafd949411  apps/segno_transfer/INSTALL.txt
aff7bfcd4aff87258a04844b49823c03d65da2e9b94699722976105d2f337a38  apps/segno_transfer/Package.swift
232f25d7be3a66462ed91b4bce21c553f5c85d4eec1af7368f674b43117d7ec3  apps/segno_transfer/README.md
95bde5cc4522b1175ef67c69b2efd66c69e3c297b3a79a123784c690bfe2223e  apps/segno_transfer/RELEASE_NOTES.md
36f6d39efc03edad968d166ef5960055ed8c0cb1aafa7f5172e59e17d37a773e  apps/segno_transfer/Sources/SegnoTransfer/AppModel.swift
f9b9af1e5ca3beb632cb5fe2509c4721a34068e3965352039461471c6ec75b57  apps/segno_transfer/Sources/SegnoTransfer/ContentView.swift
8ecf1643c61e310f46f812fd5e9ce31165ae90ac36c836ea46ac2cd15882b1ad  apps/segno_transfer/Sources/SegnoTransfer/PreviewControls.swift
4afeda54c96c915213e39b0776b6e10655f6ed552e9e52f875d67717ba3fdf12  apps/segno_transfer/Sources/SegnoTransfer/PreviewPlayer.swift
52d6d5819acd94de699f71c2ff96bbf7efdba9e6e8c8e66e409e0cb161966fb0  apps/segno_transfer/Sources/SegnoTransfer/RemoteAudioLoader.swift
5c7d64438735260894dfc52684a522c6ee7d78cde4355bd23bf72d23d986ddbb  apps/segno_transfer/Sources/SegnoTransfer/SegnoTransferApp.swift
f0e53b4da94c8eae3938dde4fcd7020000ee487dfbcf669edf0d3bd25eed65b3  apps/segno_transfer/Sources/TransferCore/Models.swift
89d9ce4a97c4bfb3e187fb6b9959bccc60b25967e52d0b33569a805208ca629b  apps/segno_transfer/Sources/TransferCore/Resources/appliance.py
12d1afb76385503034e8f86d892ce9e68760ebed355bfa9b0d7ef3a128605c06  apps/segno_transfer/Sources/TransferCore/SSHClient.swift
4427fbc92cbb8cbc8b01c42f4175d72657d6efc3f108f54172e4861cf3b829c8  apps/segno_transfer/Sources/TransferCore/TransferRepository.swift
f1740bcd2c1436c261bfa810343a05fa8e998b17533e39b46b8fccb7cefd2b7a  apps/segno_transfer/Tests/RemoteTests/test_appliance.py
5f25358a7f0121b65569e219d2bdc02ad3ec1fdfffab26e5f250d85b5feb5a55  apps/segno_transfer/Tests/TransferCoreTests/AppModelTests.swift
d4821ce53e49d264a7f9dba39dcfc34ba6910669e6736194b83315a7e5f0a54d  apps/segno_transfer/Tests/TransferCoreTests/PreviewPlayerTests.swift
22d9d54717992941731e0a22dfd8e7d09160e05a60be767f119b852815cc02f4  apps/segno_transfer/Tests/TransferCoreTests/StreamingTests.swift
2c3c8232fbd502ef93915f0d7265979b81b06875a5294e08f0afc96383df9466  apps/segno_transfer/Tests/TransferCoreTests/TransferTests.swift
15fb9cce843b3e1e266c85996068ba54b2ca8169ebc5590502f40b2ff651b8ae  apps/segno_transfer/build-app.sh
f1f009fa0efe9ac53801b2a0d200fd2d73ae898392b10d4c6c57e947a449650e  apps/segno_transfer/package-app.sh
cac560f9a915ab4335a337826f1da600492b6e582cb7b56e23ff54daf8ccbaf5  docs/PROGRESS.md
bd5e7fb4b5dcd1c55467a0394f948565114129755b5919b1fbde2c9743f723bf  docs/brainstorm/2026-09-15-recording-downloader-brainstorm-doc.md
35560d997edef1313df208d2690b00155d9737a0e6f4c54ea51013449f3184e1  docs/plan/2026-09-15-feat-recording-downloader-plan.md
a42c5b9721df607ffefbf10e5c44447eb23fca74bc0dccf37c3b9b38e398f9f6  segno-ui.pen
```
