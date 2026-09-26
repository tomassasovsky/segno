# Loading and saving appliance audio

Status: interactive proposal, ready for owner review. Loading and saving are
implemented as silent fixtures in the main prototype and native Pen screens.
The owner authorized this proposal; the slice has not been accepted. The preparation list and foot-operated Backing flow are now testable. Real file
operations, audible preview and hardware dispatch are not implemented.

[Current behavior, evidence and next proposal](../design/2026-09-07-audio-library-ux.md)
is the detailed record for this slice under the appliance UX programme (919).

## What We're Building

One appliance audio browser for material already stored internally and material
on a connected USB drive. Backing playback needs this preparation flow before
its performance controls. Linux appliance use drives the design.

## Why This Approach

A shared browser keeps file selection, preview and storage locations consistent.
The Backing track flow can open it with its destination already known; track
imports can reuse it later without adding a separate library of the same files.

## Key Decisions

- Owner-provided source locations: USB drive and internal disk.
- Proposed preparation: browse, preview, then load the chosen audio as a backing
  track. Do not start full playback merely by selecting a file.
- Proposed default: importing USB audio copies it to internal storage, making
  it available without the drive. Direct playback from removable storage is not
  yet a requirement or an accepted alternative.
- Save audio selects recorded tracks and writes one named WAV to Saved audio on
  Internal or USB. It is a proposed audio export, distinct from saving a session.
  The resulting file appears in the same browser and can be used as backing.
- The library has no fixed slot count. The proposed player loads one file at a
  time, initially stopped; selecting or loading does not start playback.
- Preparation may use touch or encoder. Foot-entered performance must select
  prepared material and complete playback/Exit without requiring touch.

## Prepared Audio by Foot — Interactive Proposal

Keep the growing file library separate from a small, ordered preparation list
for a performance. The list has no artificial eight-item limit; the four track
pedals address four visible entries and Bank pages through more. Removing a list
entry would not delete the audio file. Selecting a different entry would queue
it without interrupting the playing one. An explicit Play action would perform
the change. This is a Segno proposal, not a verified Looper X setlist feature,
and it is now wired into the prototype foot controls. The main design record
documents preparation, playback, end-of-file and reload behavior.

## Remaining Decisions and Implementation Boundaries

- Production session recall scope and backing output/transport coupling.
- Preview output and level, production format support and real copy recovery.
- Export duration when loop lengths differ; handling tails, output processing,
  mute/fade and speed; distinguish audio export from editable session saving.
- Appliance storage limits and USB removal during actual file writes.

Folder browsing, progress/cancel, filename collisions, simulated storage failure
and missing media are now testable. Library is reached from normal Tracks;
the loaded Backing view returns to that same browser with Choose audio.
