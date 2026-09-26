# Whole-session USB backup and restore

Status: revised Library design accepted by the owner on 2026-09-08. Backup packages, media bytes,
USB transfer, verification and capacity are simulated. This does not write files
to an actual drive or prove production recovery.

## Paths

Library → Sessions → Internal → select a session → Back up to USB. This
starts the copy directly. Progress and Cancel replace the selected session's
footer actions until the copy finishes; success is a short notification. There
is no separate backup page, repeated eight-track preview, or success screen.
A matching name opens a compact Keep both / Replace / Cancel dialog. The previous
backup remains intact until the replacement finishes successfully.

In the same Library, choose USB. Backups use full-width rows: name, saved date,
and one summary of recorded tracks, effects and backing files. Select a row and
Restore to Library. It adds a new session and copies its audio internally, then
selects that entry under Internal. Existing playback and the current session are
unchanged. Open session uses the accepted playback-stop confirmation.

The owner rejected the first standalone backup page because its oversized track
preview repeated little useful information. That page and its success screens
are removed. This accepted revision keeps backup and restore in Library.

Selecting, backing up or restoring does not stop existing playback. Recording must
finish before starting a copy so the source is a complete take. Other active
transfers and eject operations prevent starting a conflicting copy. Storage and
Power share the same transfer state. Cancel removes the pending operation, and a
USB disconnect cancels immediately even when the same drive reconnects quickly.
Retry is explicit. Failed or cancelled operations publish no partial session or
backup; failed replacement preserves the earlier backup.

## Package and session boundaries

The package contains one session snapshot plus every prepared, selected backing,
and imported-track audio asset referenced by that snapshot. An unavailable source
asset blocks backup. Restore validates the package and required media before
publishing the new session. Restored media receives independent internal IDs;
prepared order and imported-track references are rewritten to those copied files.
The existing session snapshot retains effect parameters, channels, loop timing,
layers, lengths, routing, pedal/expression/MIDI assignments and musical state.

This is a session backup, not a clone of the appliance. Device configuration,
physical port names, Wi-Fi, display calibration, installed software and the global
preset library follow their existing appliance/library ownership. They are not
overwritten by a session restore. Restored sessions reopen stopped, as established
in the accepted Session Library flow.

## Validation and production work

Chrome and Firefox verify Library entry, cancellation, replacement failure,
disconnect/reconnect, independent media references, intact ongoing playback,
normal session opening, persistence, corrupted packages, missing drives, recording
and transfer guards, encoder scrolling and six bounded screen layouts. Session
Library, Storage, Power and Updates regression checks cover the shared paths.

The Pen section groups the revised Library flow alongside the accepted Session Library references.
Browser and Pen agreement is design evidence only. Production work must copy
actual audio/layers, validate package compatibility and checksums, calculate real
space needs, stage writes, flush them durably, publish atomically, and recover from
power loss. A physical restore onto another appliance must be tested before
claiming portable recovery. Older backup formats have no promised compatibility.

Bulk backup, a complete appliance image, stems and DAW export remain separate.
The next media UX gap is backing-track seek, end and repeat behavior.
