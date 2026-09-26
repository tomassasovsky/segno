# Session Library and New Loop

Status: accepted by the owner on 2026-09-07 after testing the interactive flow.
The acceptance covers UX behavior and layout; appliance session persistence remains
implementation work.
Tracked under the appliance UX program, issue #919.

## The journey

Open **Library** from normal Tracks. **Sessions** and **Audio** share its header:
sessions preserve the instrument setup; Audio contains reusable files and prepared
backing audio. The session list shows the current session followed by recently
opened sessions. Selecting a row previews it without changing the current sound.
**Open session** loads that session and returns to Tracks. If audio is playing,
confirm before stopping it. Restored tracks and backing audio start stopped.

**New loop** preserves the current session before starting empty recorded tracks.
The touch/encoder confirmation names the session being kept and states that the
sound setup carries over. Cancel changes nothing. The same action is available
as **New loop** in custom pedal assignments. Its foot action saves and starts the
new loop directly, with no touch step. The existing Mode defaults stay unchanged.
A failed foot action retains the current session and can be retried by foot.

Automatic names make naming optional. Rename supports touch, physical typing and
encoder navigation. Renaming changes metadata only and does not interrupt playback.
There is no separate manual Save button in this proposal.

## State boundaries

| Item | New loop | Reopen session |
| --- | --- | --- |
| Recorded parts, overdub layers, length edits, imported-track descriptors | Empty | Restore the saved session |
| Audio-edit histories and bounce recipes | Empty | Restore the saved session's existing prototype histories |
| Input, track and output FX, placement, parameters, activation assignments | Keep | Restore |
| Tempo, signature, loop mode, recording and track defaults | Keep | Restore |
| Pedal/expression assignments, colors, track labels, monitoring configuration | Keep | Restore |
| Channel level/pan and input mute settings | Keep | Restore |
| Track mute, fade envelope, reverse, transpose and global speed | Reset | Restore stored settings; running fades are frozen at the captured level |
| Prepared backing order and loaded backing file | Keep, stopped | Restore, stopped |
| Playback, capture and held contacts | Stop/release | Stop/release |
| Global FX preset catalogue and internal/USB audio catalogue | Keep globally | Keep globally; do not rewind files to an earlier session |

The Library detail preview was revised and accepted on 2026-09-08. Only tracks
containing audio appear, with sample-derived waveform examples, proportional loop
length, bars, layers, mute and track-FX indicators. Muted audio is dimmed; active
current-session playback has a moving cursor. Longer previews scroll vertically
with a centered, non-focusable overflow arrow. Tiny occupancy marks remain in
the session list, where they act as a compact summary.

Listen has an isolated, simulated audition transport. It does not open the
session or change the running setup. It stops when leaving the preview, selecting
another session/location, or when recording/playback starts. Audition is blocked
during existing playback/capture and when the audio device is unavailable.

Waveforms reuse Stage's reference PCM peaks, not actual user recordings; real
audio audition and track-specific waveform projection remain production work.
No arrangement or scheduled entrances/returns are implied.
Archived setup snapshots do not contain the session library itself, so saving a
session does not recursively duplicate the library. Session switches write the
outgoing snapshot and destination together before replacing the active state.

## Failure and navigation rules

- Finish recording, overdubbing, arming or an audio transfer before switching.
- Recheck these conditions at the final action, not only when the dialog opens.
- A failed storage write leaves current audio, settings and the session list intact.
- Selecting, browsing, renaming or cancelling never loads a session implicitly.
- Loading a malformed session retains the current one and reports the failure.
- Cold reload preserves the stored setup and starts transport stopped.
- Session rows scroll vertically. Encoder movement reveals the focused row.
- No artificial session-slot limit is imposed by this prototype.

This explicitly revises the older roadmap's row-tap-to-load proposal: selection
now previews, and one named action loads. It matches the recently reviewed Audio
Library distinction between selection and playback. Renaming a session preserves
its identity; opening a session does not create another copy of that session.

## Reference and implementation boundary

Looper X's extracted NewLoopDialog and SaveWorkflow preserve save/discard/cancel
continuations and wait for file operations. See [E15–E16](../research/sheeran-looper-x-1.0.2/evidence.md#e15).
Segno's roadmap already calls for autosave/Scratch and faithful session recall in
S02 and S06. This proposal retains preservation-first behavior and removes the
need to name every new take before continuing.

Browser storage persists symbolic prototype state, including rack parameters,
track descriptors, existing separate edit histories and prepared backing lists.
No audio is decoded, recorded or written to appliance disk. This does not finish
S02/S06: atomic audio files, crash/power-loss recovery, unified Undo, media validation,
large-library storage and hardware behavior still require production implementation.
The existing track-import descriptor limitation remains; this journey preserves
that descriptor without pretending it is decoded track audio.

`verify_session_preview.cjs` additionally covers waveform diversity, saved metadata,
mute, independent audition, playback guards, empty sessions and long previews
in Chrome and Firefox.

## Review and validation

- Main entry: `fx-ux-prototype.html?review=session-library`.
- Variants: `session-new`, `session-saved`, `session-name`, `session-error`,
  `session-empty`.
- `verify_session_library.cjs`: New Loop, cancel, differing-session recall,
  rename without stopping playback, failed writes, recording guard, persistence,
  encoder navigation, custom-pedal entry and layout bounds in Chrome and Firefox.
- Existing Audio Library, backing-performance and track-import checks pass with
  the shared Library navigation.
- Native screens are in **19 Sessions · New loop & recall** inside Current UX.
  The six screens are accepted in the design source.
- Physical touch sizes and the two display roles still need hardware review.

Native verification: 658 text lines and 2,172 element sizes match their browser
geometry; no alignment or section-boundary errors. The check covers the six session
views plus updated Tracks and Audio Library navigation.
