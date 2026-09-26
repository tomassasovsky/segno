# Storage and safe USB eject

Status: owner accepted on 2026-09-07. This is the interactive prototype. Capacity,
drive identity and unmount operations are simulated; no real disks are accessed.

Settings → Storage shows Internal and USB drive capacity. Open library and Browse
lead to the existing Audio Library at the corresponding location. Low internal
space has a short warning. Capacity figures are illustrative, not measurements.

Eject is available for an idle USB drive. It stops USB preview and changes to
Ejecting with Cancel. Cancellation keeps the drive mounted. Safe to remove appears
only after successful completion; failed eject retains the connection and offers
retry. Unexpected disconnect cancels pending work, and reconnect cannot allow a
late eject callback to remove the newly connected drive.

A file transfer involving USB disables Eject and offers View transfer. The transfer
can continue while Storage is open; new USB transfers and previews cannot start
while eject is pending. Library, import, export and Storage share the same USB
availability. Prepared backing audio remains an internal copy; internal capture,
loop playback and saved files are unchanged by eject.

This follows the Looper X Storage capacity/eject pattern documented in
[the extracted feature inventory](../research/sheeran-looper-x-1.0.2/features.md#f12--storage-and-usb-transfer).
Segno keeps the earlier accepted internal-copy rule instead of moving its active
session onto removable media.

Chrome and Firefox checks cover shared media state, eject/cancel/failure/retry,
late completion, background transfer protection, encoder access and canvas bounds.
Existing audio save, USB export and track import checks also pass after integration.
The six native Pen references are grouped under Storage & safe eject.

Production needs actual capacity/health, mount identity, atomic file writes,
filesystem synchronization and OS unmount acknowledgement before Safe to remove.
Filesystem support, extra USB drives, recording-time estimates, formatting and
Library deletion/trash are separate unfinished flows. This slice does not claim
that low-space cleanup or whole-session backup is complete.
