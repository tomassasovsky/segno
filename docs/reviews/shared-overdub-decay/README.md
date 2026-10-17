# Shared overdub decay

MIDI, External buttons and expression pedals can control overdub decay for
Loop defaults and fixed Tracks 1–8, including empty tracks. All surfaces use
the existing playback owner. Zero keeps previous layers; 100 percent replaces
them during overdub. Ordinary playback remains unchanged.

Explicit track zero stays Custom. Use default removes only that track's decay
override and supersedes older held cleanup. Saving or restarting while a control
is held retains its authored Released value. Storage failures refuse acceptance;
shutdown waits for pending edits and offers recovery before powering off.

The [plan](../../plan/2026-10-01-shared-overdub-decay.md),
[verification](verification.md), [source binding](source.json),
[design binding](design.json) and [review](review.md) define this bounded slice.
Published-head CI and human merge approval remain separate. Other shared loop
controls and the inherited live-controller session-load defect remain later work.
