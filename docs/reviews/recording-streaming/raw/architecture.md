# Architecture Review — Recording streaming

## Scope and exact state

- Reviewed only the streaming delta from base/checkout HEAD
  `f6c309244058a5856e9a558e210d352707c711cd`.
- The delta is uncommitted and includes 15 modified files plus the new
  `RemoteAudioLoader.swift` and `StreamingTests.swift`. Existing companion
  behavior was traced only where affected by this change.
- Seventeen-file inventory: `/tmp/segno-transfer-streaming-seek-review-snapshot.txt`.
  Inventory SHA-256:
  `26034ca8639824da6b0a701bf755c2c38fa670b2a45c5978be014af0c0043e4a`.
- Applied the workflow-agents Architecture role and build review instructions,
  with the Segno engineering/tracking rules. No implementation edits or
  appliance/UI operations were performed.

## Layer Separation

- Violations found: 0. All changed source files are clean.
- SwiftUI controls still delegate to app state and the player. `AppModel`
  snapshots the selected recording and connection, then supplies a repository
  read closure to the resource loader. The loader does not know SSH details.
- `RecordingRepository.read` owns bounded byte retrieval. `TransferRepository`
  validates requests, calls `SSHClient`, and checks exact returned length.
  The remote helper owns source validation and file access.
- AVFoundation and its loading delegate remain in the native app module.
  The transfer core has no reverse dependency on presentation. The Flutter
  instrument runtime, engine callbacks, and appliance services remain outside
  the implementation.

## State Management Assessment

### Loading, seeking, and cancellation — correct

- Loader state is confined to one serial delegate queue. Pending requests hold
  their own cancellation tokens and remain strongly referenced until finished
  or cancelled. Two worker operations at most perform blocking reads away from
  the delegate/main queues.
- Each response is at most 1 MiB. The adapter uses the current/requested offset
  and remaining resource length, and supports both a requested byte count and
  requests through the end of the resource. Successful chunks are delivered
  incrementally; requests finish on completion, cancellation, or error.
- This follows Apple's documented [incremental end-of-resource contract](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingdatarequest/requestsalldatatoendofresource)
  and [asynchronous loading lifetime contract](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate/resourceloader(_:shouldwaitforloadingofrequestedresource:)).
- Obsolete requests cancel their token. Responses verify both request identity
  and token state before reaching the player. Closing/replacing stops the
  loader, finishes pending requests, cancels queued operations, and cancels
  asset loading. In-flight SSH reads observe cancellation and reap the process;
  the main thread does not wait for their network completion.
- Initial preparation remains serialized by the app busy state. The final
  source checks cancellation before invoking asynchronous player preparation
  and again afterward. The added immediate-cancellation regression requires
  zero reads and unchanged selection. This closes the preparation-start race
  independently reproduced by the test reviewer; the correction was traced here.
- Playback no longer creates or verifies a complete temporary preview file.
  Short-lived range response files retain the existing owned cleanup path.
  Selection, download destination, and complete-download publication remain
  independent of streaming.

### Player lifecycle and errors — correct

- The player retains its asset and loader, rejects completion from a replaced
  asset, and removes all time/status/playback observers on stop.
- Buffering reflects native playback status. Observer callbacks verify the
  current player item; loader error callbacks verify the current asset.
- A range failure directly pauses the player, stops all loader work, and exposes
  an error. This avoids relying on the native player to convert every loader
  failure into an item-status failure. Playback controls cannot restart a failed
  item; choosing a new preview creates a fresh asset and loader.
- Close, replacement, connection change, preparation cancellation, and normal
  app termination reach the appropriate stop path. The existing busy-quit
  cancellation path continues to work with streaming preparation.

### Range bounds and source trust — correct

- Repository checks reject negative offsets, empty/oversized reads, and ranges
  past the catalog length without overflow-prone addition. The appliance repeats
  the bounds checks against the opened file size and requires an exact read.
- The existing finalized-manifest, complete-WAV, path, and source-version checks
  apply to the new read action. Before/after version checks and nonzero-exit
  handling prevent stale or changed-source responses reaching playback.
- Preview trusts authenticated SSH transport integrity and source versions.
  Complete downloads retain their separate full-file SHA-256 verification.
  Documentation accurately distinguishes these guarantees.
- The helper now travels through SSH stdin. The remote command contains only
  the interpreter and individually quoted positional arguments, retaining
  host-key verification and existing authentication. Every request opens its
  own helper input handle; concurrent reads cannot share a file offset.
- Catalog, hash, and download test substitutes use the new argument order and
  stdin transport. The short-command assertion exercises the actual helper
  execution path, including minimal appliance Python behavior.

## Dependency Direction

- Direction violations: 0. Native presentation/player code depends on the
  transfer core; the core does not depend on AVFoundation or UI code.
- Existing Apple frameworks and the repository seam are reused. No external
  package, new daemon, port, or appliance installation requirement was added.

## Package Structure

- The new loader and streaming tests have focused responsibilities in existing
  targets. The package manifest, app resource packaging, and dedicated workflow
  discover them without new configuration.
- The old complete-preview preparation path was removed. Documentation and the
  design source now describe streaming, seeking, buffering, and cancellation.
  Structural comparison confirms only the companion frame/rationale changed;
  all other design nodes are unchanged.

## Validation and limits

- Independently passed the exact Swift formatter and compiler build with
  warnings treated as errors, including the final cancellation correction.
- Independently ran all three real, muted AVPlayer streaming tests: startup
  before full transfer, distant unread seeking, disconnect failure, bounded
  reads, stopped-read stability, and blocked preparation cancellation pass.
- Python compilation, shell syntax, tracked whitespace, artifact scan, and
  four-document spelling check pass. The test reviewer separately owns the
  immediate-cancellation regression and broader test/mutation evidence.
- Coordinator-supplied live evidence reports playback from a 388,628,012-byte
  appliance recording after 2,162,222 bytes in 3.24 seconds, with a distant seek
  in 2.67 seconds. This reviewer did not operate the appliance or native UI.
- This is a source review of the identified working snapshot, not committed-head
  CI, native visual acceptance, audio-under-transfer stress testing, or product
  merge approval. Current authorization is local app delivery only.

## Verdict

Architecture is clean. No unresolved Critical, Important, or Suggestion
findings in the streaming delta. Later source changes need an evidence refresh.

## Final drag and seek refresh

- The final snapshot changes only `PreviewControls.swift` and
  `PreviewPlayer.swift` from the preceding reviewed streaming implementation.
- During a slider drag, local view state holds the proposed position and
  playback clock updates cannot move the thumb. Release submits the final
  seek. Non-drag binding changes still seek immediately for accessibility.
- Each seek receives a unique identifier. While that seek is pending, player
  clock callbacks do not replace the requested position. Completion verifies
  both the current item and latest seek identifier, then uses the actual player
  time. A superseded seek or replaced item cannot complete the newer seek.
- Stop clears pending seek state along with the existing player/asset/loader
  lifecycle cleanup. Failed items reject further seek requests. No repository,
  remote protocol, source-version, or request-bound behavior changed.
- Independent exact Swift formatting, final compiler build with warnings
  treated as errors, and tracked whitespace checks pass. The three independent
  streaming tests recorded above ran before this two-file delta. The coordinator
  owns the focused playback rerun and final native dragging validation; those
  checks are not represented as independently executed here.
- No verified architecture or readiness finding was introduced. Both role
  counts remain zero for this final source snapshot.
