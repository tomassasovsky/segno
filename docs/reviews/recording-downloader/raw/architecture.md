# Architecture Review — Segno Transfer

## Reviewed scope and state

- Base and checkout HEAD: `848f1337251989f849c7851f72b6126b5c1712ea`
  (`origin/master`). The implementation remains untracked; no committed PR-head
  review is claimed.
- Reviewed all new app/core/helper source, tests, package/build/ignore files,
  dedicated workflow, September 15 brainstorm/plan, progress entry, and the
  appended design nodes, including the final full-recording preview.
- Current 22-file inventory: `/tmp/segno-transfer-preview-final-review-snapshot.txt`.
  Inventory SHA-256:
  `cac19af333b379dada786ec6009346c003001c7c1f04e0490fe0f8fedecf4586`.
- Applied the workflow-agents Architecture role and build review instructions,
  with the session's Segno rules and checkout tracking/build guidance.
- No implementation edits, appliance requests, UI operations, or unrelated
  reviews were performed. Live UI/device validation remains the coordinator's.

## Layer Separation

- Violations found: 0. All checked source files are clean.
- The approved native Mac companion uses SwiftUI/AppKit, Foundation, CryptoKit,
  AVFoundation, and system OpenSSH. It introduces no external Swift packages or
  dependency on the Flutter instrument runtime.
- Views bind to `AppModel`, which uses the `RecordingRepository` protocol.
  `TransferRepository` owns transfer, verification, and publication rules;
  `SSHClient` executes the bundled remote helper. The app entry point assembles
  these dependencies. Core code does not import presentation frameworks.
- `PreviewControls` delegates local playback state/actions to `PreviewPlayer`.
  `AppModel` obtains the verified temporary audio through the existing
  repository. AVFoundation playback remains in the Mac app module, separate
  from remote file access and the instrument engine.

## State Management Assessment

### App operation and transfer lifecycle — correct

- Main-actor observable state drives the UI. Blocking process, file transfer,
  and hashing work runs in detached tasks; progress returns to the main actor.
  A busy guard serializes operations; a lock-protected token cancels them.
- Downloads snapshot connection, destination, jobs, and names. Completed files
  are deselected; failed/cancelled files stay selected. Connection changes clear
  the catalog and selections. Progress callbacks verify their operation token
  and busy state before updating the current operation.
- Busy quit requests cancellation and waits for completion. The SSH subprocess
  is terminated and reaped before owned temporary transfer files are removed.
- Transfers use bounded audio memory, exact byte counts, SHA-256 verification,
  and exclusive final rename. Name collisions cannot replace existing files.
  Failure paths do not publish an unverified copy.

### Full-recording preview lifecycle — correct

- Preview preparation uses the same verified download path in a private
  temporary directory, retaining connection and source-version checks. It
  preserves selection, custom download names, and the chosen destination.
- Preparation is serialized with downloads/refresh, reports progress, and
  checks cancellation after transfer and after asynchronous asset loading.
  Failure/cancellation stops playback and removes the owned preview directory.
- Replacement stops the previous player before removing its file. Closing a
  prepared preview and normal application termination perform the same cleanup.
  Changing connection also clears any prepared preview.
- Duration loads asynchronously and must be finite and positive. Native player
  controls support play, pause, full-file seeking, end-of-file replay, and errors.
  Stop removes time/notification/KVO observers and releases the player item.
  Queued observer callbacks check the current item so an old item cannot update
  a replacement preview.
- The UI does not permit replacement while preparation is busy, and the close
  control appears only for a prepared preview. This preserves the preparation
  lifecycle assumptions in the current callers.
- Documentation and the updated design source explicitly describe preparation
  of a complete temporary copy, including delay for large recordings. This
  matches the user's requested full-length preview and seeking.

### Remote catalog and protocol — correct after correction

- The remote helper performs catalog/download/hash actions only. Individually
  quoted positional values preserve SSH command boundaries; known-host and key
  verification remain enabled. Traversal and linked source files are rejected.
- Catalogs require finalized capture metadata and a complete main WAV; each
  offered WAV is checked separately. The actual instrument finalization order
  and manifest fields were traced during the initial review. Documentation
  correctly distinguishes WAV container completeness from musical completeness
  of offline stems.
- The helper uses minimal Python plus the already-shipped jq and sha256sum
  tools. Existing appliance recipes declare jq/coreutils; no device packages or
  service are added. NUL-framed catalog fields preserve names without writing a
  custom JSON encoder. Source versions are checked before and after reads.
- The initial review independently reproduced one catalog failure-isolation bug:
  an overflowing capture frame value caused final serialization or arithmetic
  to abort listing healthy recordings. The current helper rejects non-finite
  or oversized metadata inside each recording's error boundary and catches
  overflow. The reviewer reran the complete helper with a healthy recording
  and both original overflow cases: success, healthy recording retained, two
  unavailable recordings. This issue is resolved; its regression is retained.

## Dependency Direction

- Direction violations: 0.
- `SegnoTransfer` depends on `TransferCore`; the core has no reverse dependency.
  Repository injection supports app-state tests, and process substitution
  exercises the real packaged helper protocol without an appliance.
- No new appliance daemon, installation path, engine API, FFI binding,
  real-time callback, or firmware dependency was introduced.

## Package Structure

- The single native package has focused app/core/resource/test targets, a
  macOS 14 floor, explicit embedded helper packaging, and no external packages.
- Dedicated CI checks helper behavior, Swift formatting, Swift behavior, and
  app packaging. Generated build/distribution/package-state files are ignored.
- Structural comparison against the base confirmed that existing design nodes
  are unchanged. The companion frame and rationale were appended and now show
  the playback controls, matching the approved native companion direction.

## Validation and limits

- Independently completed the source/protocol/lifecycle review and initial
  catalog-defect reproduction/resolution check.
- Refreshed Swift build with warnings treated as errors and exact configured
  formatter both pass. Python compilation and build-script syntax pass.
- Independently ran nine focused app-state/preview tests: all pass, including
  actual muted WAV playback, pause, seek, stop, invalid audio, failed preview
  selection preservation, cancellation, and retry state.
- The coordinator reports successful real two-file download, custom names,
  independent source-hash agreement, and Finder reveal. Those are supplied
  live-validation results; this reviewer did not operate the appliance or UI.
- This report does not claim live preview acceptance, audio-under-transfer
  stress validation, final-head CI, signing/notarization distribution approval,
  or product merge approval. The documented product merge gate is separate.

## Verdict

Architecture is clean for the identified untracked snapshot. No unresolved
Critical, Important, or Suggestion findings. The earlier corrupt-metadata
failure-isolation finding is resolved. Final commit/source revisions require a
bounded evidence refresh.

## Final mechanical/test refresh

The final snapshot differs only in three documentation spelling allow comments
and the short/oversized-transfer test fixture. The fixture now returns the
matching hash for its own invalid-sized payload, so a hash failure cannot hide
a missing length check. Production source is unchanged. The revised fixture was
read; its mutation execution remains the independent test reviewer's work.
Swift formatting and the four changed/new product Markdown files pass the
refreshed checks. Architecture findings remain zero.
