# Audio files into loop tracks

Status: interactive proposal for review, following the owner's approval of the
prepared-list reorder refinement. Part of the appliance UX programme (919),
covering the roadmap's S14 empty-track audio import journey.

[Try the destination chooser](fx-ux-prototype.html?review=audio-track-import),
[selected destination](fx-ux-prototype.html?review=audio-track-import-selected),
and [full loop](fx-ux-prototype.html?review=audio-track-import-full).

## Journey

Use the existing Audio Library to browse Internal or USB and preview a file.
Use in loop opens a destination chooser with that file's name, waveform and
duration beside all eight tracks. Selecting a destination does not modify it.
Load into the named track is the explicit commit action; Cancel returns to the
same browser. Existing audio remains protected by limiting this flow to empty
tracks, as specified in the roadmap. Recording destinations are unavailable too.

The proposed import preserves the original duration, pitch and speed. It does
not silently stretch the file, trim it to a bar count or change the session's
tempo. The destination starts stopped. USB audio is copied into the loop's
managed storage, so unplugging afterward cannot remove the imported take.
This is separate from preparing a file for the independent Backing player.

A loading view supports cancellation. The result names the file and destination
and offers Choose more audio or Tracks. A full loop explains that no tracks are
empty. A disconnected drive, insufficient storage or a target that starts
recording during loading leaves the import unapplied. The destination is
rechecked immediately before the prototype commits its descriptor.

## Interaction evidence

`node docs/design/verify_track_import.cjs` passes in Chrome and Firefox:

- No write on selecting a target, and no partial result on cancelled loading.
- Imported descriptor preserves source duration, speed and stopped state.
- Already occupied and newly recording destinations cannot be overwritten.
- USB removal during loading fails; completed copied descriptors are retained.
- Insufficient space leaves the previous state intact.
- Encoder selects the first available destination; no-space focus lands on
  Cancel. The resulting assignment survives a normal browser reload.
- Source and destination controls fit the 1920 × 1080 canvas in four states.

The Audio Library and Backing performance regressions also pass in both browsers.
Prepared-list reordering remains available above its numbered list.

## Scope and implementation gaps

This is a silent preparation prototype. It persists a file/track assignment and
stopped-state descriptor in Audio Library state and uses it to protect that
destination on later imports. It does not decode a file or inject its audio into
the older symbolic beat fixtures used by the transform and Bounce studies.
Those studies therefore do not prove playback or editing of an imported take.

Production work must connect the importer to the shared track/audio model,
session recall and unified Undo/Redo; validate codecs, resampling and channel
handling; and make copying durable and atomic. The existing S14/S17 roadmap
separates original-speed import from later tempo-aware fitting. No extra fit
controls or tempo inference have been added to this proposal.

Four native Pen states accompany the chooser, selected target, full loop and USB
source. The current [audio gallery](audio-library-previews/index.html) groups
these with preparation and backing playback, retaining the earlier screens.

The Pen file is saved. The combined audio-flow check reports no errors in
466 text lines and 1,697 element bounds, with no clipped screens in the current
section grouping. Saved-file identity is recorded in the gallery manifest.
