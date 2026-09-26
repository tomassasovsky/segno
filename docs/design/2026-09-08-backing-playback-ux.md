# Backing playback: position and end behavior

Status: interactive proposal, not yet owner accepted. Extends the accepted backing
performance layout; audio remains simulated. Part of the appliance UX program.

The player retains its loaded/selected distinction. Selecting a recording does
not interrupt the one playing. Play loads the selection; otherwise it toggles
Play/Pause. Stop resets to the beginning. Exit preserves playback.

## Position

The progress bar is now a direct seek slider. Touch moves the loaded recording's
position without changing its playing/paused state. Encoder press starts a draft,
turn adjusts by seconds, press commits and Back cancels without seeking. Double
tap resets to the beginning. Changing the loaded recording discards its seek draft.

Hold Previous to jump back ten seconds; hold Next to jump forward ten seconds.
The tap actions still select the previous/next recording. A hold consumes the
press so it never also changes selection. Seeking clamps to the file boundaries.
It applies to the loaded recording, even when a different recording is selected.

## At end

Stop, Repeat and Next share one selector. Stop is the default. Repeat starts the
same recording again; Next plays the following file in the current prepared
order. Next stops after the last prepared file; it never wraps to the first.
A failed automatic load stops and reports the problem.

Hold Bank cycles Stop → Repeat → Next. Tap Bank still pages through four prepared
recordings. This makes all player functions available without touch. The selected
end behavior is session-owned and survives save, recall, backup and restore.
Playback itself always starts stopped after reload.

Automatic Next updates the visible selection/page when it was following the
loaded recording. A different pending manual selection stays selected until Play.
Loop playback, recording and mix settings are unaffected by backing controls.

## Validation

`verify_backing_playback.cjs` covers touch position, isolated holds, encoder
cancel/commit, repeat, automatic Next, last-file stop, pending selection, page
following, session recall and failed setting writes in Chrome and Firefox.
`verify_backing_performance.cjs` retains preparation, USB copy, reorder, selection,
Play/Pause/Stop, Exit, cold reload and layout checks.
