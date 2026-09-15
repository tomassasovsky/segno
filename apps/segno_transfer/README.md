# Segno Transfer

<!-- cspell:words hashlib -->

A native Mac app for downloading performance recordings from a Segno appliance.
Requires macOS 14 or later. The app is separate from the Segno instrument runtime.

## Use

1. Open **Segno Transfer** and enter the appliance's address. Both devices need
   to be on a network where the Mac can reach the appliance.
2. Click **Connect**. The newest performance's main recording is selected.
3. Select performances in the left column. Click a performance to choose its
   main recording, individual inputs, loops, dry tracks, or tracks with effects.
4. Edit **Save as** for each selected file and choose a destination using **Change**.
5. Click **Download**. **Show in Finder** reveals the verified copies.

Click the **Play** button beside any audio file to hear it before downloading.
Playback streams small sections over the existing connection and starts before
the whole file transfers. Use Play/Pause and the timeline to seek anywhere; the
app fetches the requested section. A buffering message appears when more audio
is needed. Closing the preview or quitting stops its reads. Listening does not
change the download selection or add a copy to the chosen folder.

Streaming uses SSH transport integrity and checks that each section belongs to
the listed source version. **Download** still retrieves and verifies a complete
copy with SHA-256 before saving it.

The app remembers the connection and download folder on this Mac. Source files
are never renamed or deleted. Existing download names receive a numbered suffix.
Cancelled/failed files stay selected for retry; completed files are deselected.
Only complete WAV containers in finalized captures are offered. Raw capture PCM,
DAW project files and metadata are not standalone audio downloads.

## Connection

Segno Transfer uses the Mac's `/usr/bin/ssh`, SSH configuration, keys and key
agent. **Connection settings** exposes the username, recording folder and an
optional key path. The default recording root is `/data/Documents/exports`.
The helper uses Python 3, jq and sha256sum, all present on the current appliance.
It does not require Python's json or hashlib packages, which the minimal image
does not ship.
The read-only helper runs through SSH without installing a service or changing
the appliance.

The host must already be trusted by SSH. For a new Mac/appliance pairing, first
connect using SSH to verify its identity and unlock the key if necessary.
Password entry and first-time pairing are not provided by this version.

## Build and check

```sh
python3 -m unittest discover -s apps/segno_transfer/Tests/RemoteTests -v
swift test --package-path apps/segno_transfer
swift format lint --strict --recursive apps/segno_transfer/Sources apps/segno_transfer/Tests/TransferCoreTests apps/segno_transfer/Package.swift
bash apps/segno_transfer/build-app.sh
```

The build produces `apps/segno_transfer/dist/Segno Transfer.app` for the build
Mac's architecture. Copy the whole app bundle to Applications or another folder.
It is signed locally, without Apple notarization or an App Store distribution.
Build on the intended architecture when preparing another Mac's copy.

## Design and boundaries

SwiftUI views → `AppModel` → `RecordingRepository` → OpenSSH client. Tests run the
real read-only helper against temporary recording fixtures through a local
process substitute, with additional state tests and transfer-failure cases.
Audio transfer and hashing use bounded memory and run outside the UI thread.
Files are published with an exclusive rename only after length and SHA-256
verification. The app never interprets a failed transfer as a completed file.

The Mac companion uses native window controls and spacing. Its layout and the
reason for differing from appliance geometry are recorded in `segno-ui.pen`.
Its terminology follows the instrument's main performance/input/loop concepts.
Offline-rendered tracks can be musically incomplete even when their WAV
container is complete; this utility preserves their bytes rather than rendering
or certifying the mix. Transfers and source hashing use appliance disk/network
resources; audio-under-transfer stress testing is a separate validation.

Tracked in #1056; see the September 15 brainstorm and implementation plan.
