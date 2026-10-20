# Shared Click volume

Click volume joins the shared MIDI and External pedal control catalogue.
It uses the same owner as the existing touch sliders: 100% is unity and 200%
is the maximum. Button endpoints start at the current level; expression and
MIDI retain the full range. Saving an assignment does not change the sound.

Momentary values stay temporary. Session saves and engine restarts retain the
Released value, unless a later ordinary or non-held change replaces it. Changes
are accepted only after storage and native publication succeed. Recovery keeps
old transactions separate from replacement sessions and devices.

Shutdown closes controller input, settles pending changes and retires held
values before proceeding. A failure keeps Segno on with Retry and Keep playing.
The recovery message does not assume that every failure stopped audio.

The [plan](../../plan/2026-10-01-shared-click-volume.md) defines this slice.
The [verification](verification.md), [source binding](source.json),
[review](review.md) and [design binding](design.json) record the completed local
gates. Published-head CI and human merge approval remain separate.
Click mode, tempo, count-in and remaining loop controls follow separately.
