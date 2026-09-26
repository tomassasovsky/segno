# Export recordings to USB

Accepted by the owner on 2026-09-07, after requesting USB export for performance
recordings and approving the proposed action and failure behavior. This is a
prototype UX decision; no real device file transfer is implemented here.

## Path and behavior

Library → Audio → Internal → Performances → select a recording → Export to USB.
The same contextual action is available for other selected internal audio files,
including prepared audio. It copies the finished file without rendering the loop
again, preserving its duration, format and capture provenance. The internal copy,
prepared order, loaded backing audio and loop playback remain unchanged.

Export uses the file's existing folder and name on USB: performance captures go
to Performances, saved loop audio to Saved audio. No extra destination form is
needed for this slice. A matching filename offers Cancel, Keep both or Replace
file; Keep both appends a number. Nothing is silently overwritten.

Progress shows the selected file and Internal → USB destination, with Cancel.
Completion offers Show on USB and Done. Done returns to the original internal
selection; Show on USB selects the exported copy. The existing audio browser
provides both touch and encoder access.

## Failure and recovery

- No drive: show Connect a USB drive, retaining the internal recording. Retry is
  available after connection.
- Removal during transfer cancels the pending export immediately. Reconnecting
  cannot silently resume a transfer onto a different drive.
- Full storage or failed persistence leaves both catalogues unchanged and allows
  retry from the selected internal recording.
- Source or destination changes during the simulated transfer are checked before
  committing. A conflicting change requires a new export attempt.
- Successful export and catalogue update are one prototype write. Cancel leaves
  no completed output entry and never removes the source.

Real USB ownership, file copying, atomic replacement, flushing before completion,
partial-file cleanup and safe eject remain appliance implementation and hardware
validation work. The browser's file descriptors do not prove audio-byte durability.

## Verification

`verify_audio_export.cjs` passes in Chrome and Firefox for normal export, Cancel,
Keep both/Replace, absent and disconnected/reconnected media, disk-full retry,
encoder navigation, storage exceptions, reload and all six layouts. Shared Audio
Library and performance-recording regression suites also pass in both browsers.

The six export states are grouped with Record performance in Pen section 20.
[Browser/native gallery](audio-export-previews/index.html).

Next recommended design slice: input and output routing, beginning with which
inputs each loop track records, then where live inputs, loops, backing audio and
click are heard. This is a recommendation, not another accepted design decision.
