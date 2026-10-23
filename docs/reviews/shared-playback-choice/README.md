# Shared Playback: Loop or Once

MIDI, External buttons and expression pedals can choose Loop or Once for Loop
defaults and fixed Tracks 1–8, including empty tracks. Touch controls use the
same confirmed owner. Once stops a track at its pass boundary in all five modes;
audio, length, pitch and history remain unchanged.

An explicit Loop stays Custom. Use default removes only that override and
supersedes older held cleanup. Save and restart retain authored Released values
while Held values remain live. Startup and recovery require actual engine
confirmation and valid stored choices. Shutdown drains pending edits before
powering off.

The [plan](../../plan/2026-10-01-shared-playback-choice.md),
[verification](verification.md), [source binding](source.json),
[design binding](design.json) and [review](review.md) define this slice.
Published-head CI and human merge approval remain separate. Other shared loop
controls and the inherited live-controller session-load defect remain later work.
