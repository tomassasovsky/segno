# Segno Transfer implementation

<!-- cspell:words hashlib -->

Issue: #1056. Base: master. Scope: standalone Mac companion under
`apps/segno_transfer`; appliance source and capture lifecycle stay outside this change.

## Tasks

1. Add a Swift package with a Foundation/CryptoKit transfer core, a SwiftUI app,
   and behavior tests. Embed a read-only Python helper executed through OpenSSH;
   inspect finalized manifests and complete WAVs without loading audio into memory.
2. Add connection settings, searchable performance rows, per-file checkboxes,
   editable download names, folder chooser, progress, cancellation and Finder reveal.
   Download through private temporary files, reject stale files, verify SHA-256,
   and create final filenames without overwriting existing content.
3. Add a repeatable app-bundle build, macOS CI, usage documentation, and a companion
   layout/rationale in `segno-ui.pen`. Keep machine-specific settings out of Git.
4. Add streaming previews with AVFoundation resource loading and bounded SSH
   byte-range reads. Preserve source-version checks, cancel obsolete reads, and
   show buffering while waiting for audio. Remove full-file preview preparation.
5. Verify failure cases automatically and connect/download on the real appliance.
   Inspect the native UI and run the five independent build-review roles. Deliver
   the local `.app`; retain the product merge gate.

## Success Criteria

```success-criteria
GOAL: A Mac user can select and name verified copies of appliance performance audio without using a terminal.

SUCCESS CRITERIA:
- Listing excludes incomplete audio and rejects unsafe or stale source paths | verify: python3 -m unittest discover -s apps/segno_transfer/Tests/RemoteTests -v
- Downloads verify bytes, preserve existing files, and handle failure/cancellation | verify: swift test --package-path apps/segno_transfer
- A complete preview supports play, pause and seeking, without altering download selection | verify: swift test --package-path apps/segno_transfer
- The Mac app opens successfully | verify: bash apps/segno_transfer/build-app.sh
- Connect, select files, rename, download and reveal work with the real appliance | verify: manual launch the app, connect, select two audio files, edit names, download, compare hashes, and reveal in Finder
- Native window remains responsive and cancellation leaves no completed partial file | verify: manual cancel an active transfer and reconnect
- Streaming starts before a full-file transfer and seeking reads an unread section | verify: swift test --package-path apps/segno_transfer --filter StreamingTests
- Preview streams from the real appliance and closes cleanly | verify: native Play, pause, distant seek, resume and close; inspect the download folder

NON-GOALS:
- Changing or deleting source recordings; audio conversion; firmware installation

VERIFICATION COMMAND: python3 -m unittest discover -s apps/segno_transfer/Tests/RemoteTests -v && swift test --package-path apps/segno_transfer && bash apps/segno_transfer/build-app.sh
```

## Limits to verify

The owner requested streaming after using the initial full-file preview. Use
AVFoundation's [resource loader](https://developer.apple.com/documentation/avfoundation/avurlasset/resourceloader)
to serve requested WAV byte ranges through authenticated SSH, in sections of at
most 1 MiB. Follow Apple's
[incremental response contract](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingdatarequest/requestsalldatatoendofresource)
and cancel obsolete requests when seeking, replacing or closing a preview.
The native player controls its forward buffer. No service or open port is added
to the appliance. Each range validates the source version and exact byte count;
complete downloads retain SHA-256 verification. No full preview copy is saved.

SSH authentication uses the user's configured Mac keys/agent and verified host
identities. The helper uses the appliance's minimal Python 3, jq and sha256sum;
it must not depend on unshipped Python json/hashlib modules. Remote
hashing and transfers add storage/network load; real-time audio stress testing
is separate from successful file transfer. WAV completeness proves its container,
not the musical completeness of offline stems.
