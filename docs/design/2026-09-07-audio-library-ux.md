# Audio Library and Save audio

Status: proposal ready for review, not owner accepted. This slice develops the
owner's Internal/USB preparation requirement under UX programme 919. It is in the
main prototype and the Audio library & backing section of `segno-ui.pen`.

[Interactive library](fx-ux-prototype.html?review=audio-library),
[Save audio](fx-ux-prototype.html?review=audio-save), and
[browser/native comparison gallery](audio-library-previews/index.html).

## Loading audio

Normal Tracks has one Library entry. The browser has Internal and USB locations,
folder navigation, a scrollable file list and a preview panel. Selecting a file
does not audition or load it. Preview is explicit, and choosing another file or
leaving the browser stops that preview. Audition pauses the backing player in
this proposal; a separate preview output and its level still need design.

Use as backing loads the selected audio, stopped. The single player has Play,
Pause, Stop and Choose audio. Replacing a playing file asks for confirmation;
browsing alone leaves it playing. The old file stays loaded until the new load
or copy succeeds. A failed or cancelled operation leaves it intact.

USB loading copies the audio to Internal / Backing tracks before loading it.
The copy remains usable without the USB drive. Importing the same fixture again
reuses its copy; another file with the same name receives a numbered name.
The eventual storage implementation needs stable asset identities and an atomic
copy operation. The fixture's identity field is not a production deduplication
design.

## Saving audio

Save audio selects the recorded tracks to combine. Empty tracks and active
recordings cannot be selected. Choose Internal or USB, enter a name, then save
one WAV in Saved audio. A completed bounce is simply another recorded track
available to this flow. It does not require a second export interface.

The naming overlay supports touch, encoder and a physical keyboard. Cancel
preserves the draft; an empty name disables Done. A name collision offers Cancel,
Rename or Replace file. The success view offers Show in library and Use as
backing. Selecting the latter for a file saved on USB uses the same internal-copy
path as other USB audio.

The proposal says that selected tracks and their effects are included. Live
inputs and output effects are excluded from the fixture recipe. Actual render
duration, tails and treatment of playback processing must be specified before
DSP implementation; the fixture duration does not settle how different loop
lengths should combine. Saving audio does not save an editable session.

## Prepared audio and performance

The library has no artificial slot limit; physical storage remains the real
constraint. One backing file can play at a time. Prepared audio is an ordered list for performance, separate from the file
browser. Add to prepared copies USB files internally when necessary. Use as
backing also prepares the file, so it is immediately reachable by foot. The
numbered list has Move up and Move down beside its Performance order heading.
Select a recording, then move it; it stays visible and keeps its selection as
its position changes. Encoder focus remains on the move action, or changes to
the available direction at a boundary. Changes are saved immediately and affect
the pages of four in performance. Remove only removes an entry from this list;
it leaves both the file and any playing audio intact.

The following foot controls are now testable in the main prototype. They remain
a proposal awaiting owner review:

| Pedal | Proposed Backing action |
|---|---|
| Track 1–4 | Select one prepared item from the current page. Keep the current audio playing until Play is pressed. |
| Bank | Page through four prepared items at a time, independently of the track bank. |
| Record / Play | Play a newly selected item; otherwise pause or resume the loaded item. |
| Stop | Stop backing audio and return it to the beginning. |
| Undo / Clear | Select the previous / next prepared item. |
| Mode / Exit | Return to normal Tracks while retaining backing playback. |

The performance screen distinguishes the playing file from a selected choice.
Record / Play reads Play selected when they differ. The list has independent
pages of four; Next/Previous selection moves between pages as needed. Unused
pedals on the last page are disabled. The ninth-item fixture exercises the third
page. At the end of a file, playback stops and resets to the beginning, without
auto-next. Backing Stop leaves recorded tracks unchanged. Exit keeps the loaded
file, playback and selection.

Enter through an assigned Backing track Press/Hold action in Custom controls,
or use Perform after preparing the list. The review fixture assigns Backing
track to Custom Stop; this does not change the accepted Mode defaults. The
complete entry/select/play/exit path works without touch. Browser reload recalls
the prepared order and loaded file, stopped. Production session recall scope,
output routing and transport coupling remain open.

## Reference and deliberate additions

The extracted [Looper X feature inventory](../research/sheeran-looper-x-1.0.2/features.md)
documents file management, saving and the separate Backing player (F09–F12),
including selection/preview, load states, Play/Pause, Stop, waveform/seek and
permitted previous/next navigation. It does not establish an editable prepared
list. That list and copy-on-import are Segno proposals. USB and internal storage
are explicit owner requirements.

## Verification and limits

`node docs/design/verify_audio_library.cjs` passes in Chrome and Firefox:

- Browse and preserve scroll position; selecting never starts preview.
- Load stopped, explicitly replace playing audio, and retain the old load on
  cancellation or failure.
- Import from USB, cancel a copy, disconnect during a copy, and use an internal
  copy after unplugging.
- Name, save, replace, reveal and recall files; reject insufficient space,
  changed recording sources and failed browser storage writes.
- Navigate folders with encoder focus; cancel filename edits; present unreadable
  files and disconnected USB without an enabled load action.
- Keep visible controls within the 1920 × 1080 canvas in eight review states.

The Bounce regression also passes in both browsers. Fifteen native preparation, performance and import screens have
matching element bounds and fitted text alignment. The scoped native check
reports no text alignment or element size errors; the expanded
section has no clipped screens. Pen is saved and its on-disk hash is recorded
in the gallery manifest. The three normal Tracks
reference screens include the Library entry. Native screenshots and their
manifest are in the comparison gallery.

`node docs/design/verify_backing_performance.cjs` passes in Chrome and Firefox:
preparation/order/removal, independent paging, selection without interruption,
Play/Pause/resume/Stop, foot entry, Exit, end-of-file, reload and screen bounds.

This is a silent interaction model. Files, audio waveforms and operation progress
are fixtures. Backing performance advances a simulated clock; it does not decode
or play audio. No actual
file is read, copied or rendered. Browser reload restores the fixture catalogue
and loaded file, stopped. Production filesystem integrity, audio routing,
decoding, hardware dispatch and physical touchscreen validation remain open.

Reorder refinement: the owner could not discover the original controls in the
preview panel. Move controls now belong to the list heading, numbered rows show
the resulting order, and Remove from prepared stays with the file details.
Chrome and Firefox verify an encoder move, visible selection at list boundaries
and the changed pedal positions across a four-item page boundary.

The owner accepted this reorder refinement and requested the next item. The
[track-import proposal](2026-09-07-track-import-ux.md) adds Use in loop to the
same file browser; it is a separate proposal with its own implementation limits.
