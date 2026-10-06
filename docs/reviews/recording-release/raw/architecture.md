# Architecture Review — Free companion release

## Scope and exact state

- Packaging base: `d8261ca22f67c91331c3a7c91ea615c3bcf22b40`.
- Checkout HEAD: `158395fe2c6fa949276a8b821863e5f449def94a`, plus the final
  uncommitted cleanup correction in four Swift source files and its test.
- Reviewed all eight packaging/delivery files, then reread the complete native
  app, transfer core, remote helper, tests, and affected callers from
  `origin/master` (`848f1337251989f849c7851f72b6126b5c1712ea`). Earlier full
  implementation reviews informed this fresh cross-file trace.
- Twenty-seven implementation/document/design files are recorded in
  `/tmp/segno-recording-release-cleanup-review-snapshot.txt`, inventory SHA-256
  `28034e4dd8ae829c1c57e688ffe2f54987e5c0d015f7e9a001262ebe15034061`.
  Historical review reports are evidence, excluded from that source fingerprint.
- Applied workflow-agents Architecture and build review instructions plus the
  bug-focused code-review angles. No implementation, publication, device, or UI
  operations were performed by this reviewer.

## Layer Separation

- Layer violations found: 0. Native views and app state use the repository seam;
  AVFoundation stays in the app module; the core uses Foundation/CryptoKit and
  SSH without importing presentation. The remote helper remains read-only.
- Packaging adds a delivery script around the existing app bundle. It adds no
  runtime dependency, appliance service, or paid signing integration.

## State Management Assessment

### Release and package lifecycle — correct

- Build creates a fresh generated bundle after successful compilation, includes
  the helper resource, signs locally, and verifies the signature.
- Packaging validates the signature, arm64 executable, and numeric three-part
  app version before creating its staging directory. It preserves the app via
  the native copy tool, adds an Applications link, installation guide, and exact
  root license, then creates/verifies the compressed disk image and checksum.
  Owned staging cleanup runs on exit.
- App version determines the disk-image filename. The workflow independently
  compares the release tag with the built app version before packaging/upload.
- Pull requests and ordinary branch runs cannot publish releases. Publication
  requires a companion tag and successful completion of the test/build/package
  job. Only the publication job receives contents-write permission.
- Named artifacts are downloaded from the same workflow run into the release
  directory; disk-image contents preserve app permissions and symlinks across
  artifact transfer. Fresh hosted jobs contain no old distribution output.
- The short release command uses quoted environment values, requires an existing
  tag, uses the checked-out release notes, and explicitly leaves the repository's
  latest-release designation unchanged.

### Full app source trace — shutdown defect resolved

**Resolved — Wait for streaming workers before terminating the app.**

- Rule: `incomplete-shutdown`.
- Original location at checkout HEAD: `apps/segno_transfer/Sources/SegnoTransfer/SegnoTransferApp.swift:47`;
  related cancellation-only stop in `RemoteAudioLoader.swift:57`.
- Trigger: quit while a preview has an active/blocked range request. Streaming
  has already cleared `model.busy`, so termination returns immediately.
- Impact: the player/loader stop path cancels tokens but does not await worker
  completion. Process termination can occur before SSH termination/reaping and
  owned temporary-file cleanup execute. The delivery reviewer reproduced an
  actual player/loader/repository/client run where the fake SSH child remained
  alive after the app process exited and was adopted by process 1.
- Evidence: inspected the independent reproduction result and current caller
  chain. No installed app or appliance was used in that reproduction. Exact
  temporary-file residue is not claimed by this report.
- Correction: app termination now always defers through the model's cleanup
  method. It first waits for any active app operation, then prevents new work,
  closes the current preview, and awaits cleanup before replying to AppKit.
- Player stop chains a detached cleanup task behind previous cleanup tasks,
  retaining already-retiring loaders. Each waits for its worker queue only after
  cancellation, off the main actor. Workers finish SSH termination/reaping and
  owned file cleanup before the awaited task completes. Cancelled callbacks
  cannot enqueue fresh reads because their pending entry/token is invalidated.
- The added regression closes two blocked previews, releases the newer one's
  cleanup first, and verifies shutdown still waits for the older read. It also
  verifies normal preview close remains responsive.
- The independent delivery reviewer reran the actual player/loader/repository/
  SSH process probe for active streaming quit and close-then-immediate-quit.
  Both now show no remaining child and no owned response/stderr files after
  the parent exits. This reviewer inspected both result artifacts and traced
  the final correction. The original finding is resolved.

### Other reviewed runtime boundaries

- Catalog/download/range/hash values remain individually quoted SSH arguments;
  helper source travels through stdin. Host trust and key authentication remain
  enabled. The shipped helper path matches app resource packaging.
- Catalog failure isolation, finite metadata, finalized captures, WAV bounds,
  safe paths, exact range bounds, and before/after source versions were reread.
  Range failures reach the loader and stop playback; late request and seek
  completions guard current identity. No additional verified issue was found.
- Complete downloads retain exact length, SHA-256, private staging, and exclusive
  publication. Failed/cancelled files are never intentionally published as
  completed copies. Existing filename collision and retry state remain coherent.
- The old complete-preview copy is removed; bounded streaming reuses the same
  repository/SSH boundary. No real-time instrument callback or FFI path changed.

## Dependency Direction and Package Structure

- Direction violations: 0. Existing targets discover the new files; no external
  Swift package or reverse dependency was introduced.
- The public repository uses standard hosted runners. GitHub documents both the
  free public-runner model and the arm64 `macos-15` label. Tag pushes bypass path
  filtering, so the branch path filter does not suppress companion releases.
  [GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).
- Artifact v7/v8 behavior is compatible: the default zipped upload preserves
  the named artifact, and a named download extracts directly into its requested
  directory. [Upload action](https://github.com/actions/upload-artifact),
  [download action](https://github.com/actions/download-artifact).
- Existing-tag and latest-release behavior follow the CLI contract.
  [GitHub release command](https://cli.github.com/manual/gh_release_create).
- The owner explicitly selected free distribution without Apple notarization.
  The installation guide accurately describes the app-specific first-launch
  exception documented by Apple. [Apple first-launch guidance](https://support.apple.com/en-us/102445).

## Validation and limits

- Independently passed configured Swift formatting, compiler build with warnings
  treated as errors, shell/Python syntax, YAML parsing, whitespace/artifact scan,
  and spelling across six product documents.
- Executed the actual workflow version-check block against the built app:
  matching tag passes; mismatched version and extra suffix fail.
- Independently verified the produced disk-image integrity and its SHA-256
  checksum. The coordinator's mounted-image evidence records signature validity,
  app/helper byte agreement, installation/license agreement, and Applications
  link. This reviewer did not launch the disk-image app.
- Final correction formatter and compiler checks pass independently. The
  coordinator reports 25 Swift and 14 Python tests passing, with the stronger
  four-test streaming sequence passing. The independent test reviewer owns the
  regression/mutation assessment.
- The rebuilt corrected image checksum is
  `d4f1dbdb63f0f31fed1e51e3c56ce22d45234fc77a8bf3d296e90b3374a77887`;
  this reviewer independently rechecked its checksum. Coordinator-supplied
  mounted-image verification again confirms signature and content agreement.
- Full runtime suites, native acceptance, and final hosted CI are separate
  evidence; this source review does not convert earlier results into a new
  current-head CI gate.

## Verdict

Packaging and the final source correction are clean for the fingerprinted
working snapshot. The confirmed shutdown finding is resolved; zero Critical,
Important, or Suggestion findings remain. Pin the eventual committed revision
and require matching CI before recording the PR's clean/ready labels.
