# Recording recovery in the performance view

September 8, 2026. The established Multi-cycle behavior is accepted. Active
Clear All and the additional recovery cases below are implemented proposals for
review. This is a silent interaction prototype, not native audio recovery.

## Try it

- [Partial take ready for Redo](fx-ux-prototype.html?review=stage-recovery-multi&simulate=1):
  Track 1 is a four-bar loop. Track 2's one-bar take has been undone. Hold Undo
  for Redo; its audio returns at its recorded position inside four bars, and
  Track 1 continues playing.
- [Recovered take in Wave](fx-ux-prototype.html?review=stage-recovery-multi-restored&simulate=1):
  the blank portion is silence, not repetitions of the short phrase.
- [Clear All during recording](fx-ux-prototype.html?review=stage-recovery-clear&simulate=1):
  hold Clear while Track 3 records. Track 1 is playing, Track 2 is stopped,
  and Track 4 is queued. The fixture runs once opened, so clear before the
  capture completes to exercise that case.
- [Clear All ready for Undo](fx-ux-prototype.html?review=stage-recovery-clear-cleared&simulate=1):
  tap Undo once to recover the whole operation.
- [Recovered group](fx-ux-prototype.html?review=stage-recovery-clear-restored&simulate=1):
  Track 1 plays again; Tracks 2 and 3 are stopped. Track 3 retains its captured
  audio, and Track 4's canceled arm remains idle.

Use the prototype's footswitch simulator for these gestures. Review URLs prepare
isolated examples through the same recording commands and history used in normal
performance. They do not change the user's saved rig. The browser regressions
also exercise the ordinary URL with persisted state and failed storage writes.

[Browser and Pen references](capture-recovery-previews/index.html).

## Behavior

Recorded content and loop duration are separate. A later take in Multi inherits
the established cycle. Its recorded regions preserve their start position,
including a capture that crosses the cycle boundary. Unwritten regions stay
silent. Redo restores playback at the shared cycle position; it neither changes
mode nor restarts the other tracks. Wave and the selected-track display show
the same regions. Multiply repeats those regions, Divide retains the chosen
portion, and Undo restores their previous placement and duration together.

Clear All freezes nonempty takes at the clear boundary, cancels pending arms and
creates one grouped edit. Undo returns completed tracks to their previous
playing or stopped state. A formerly recording or overdubbing track returns
stopped, with captured audio available. It never resumes microphone capture.
Earlier per-track edits remain in history; subsequent fader, mute and FX changes
are preserved. Newer audio edits must be undone before an older group can be
restored. Restoring a group restores musical phase, not elapsed wall-clock time.

State and history are prepared and saved together before live content changes.
If publication fails, the existing audio, recording, queue and history remain;
the user can retry. A zero-audio take or canceled arm does not invent a playable
layer. Redo that would play audio stays pending while the audio device is
unavailable. Song and Band recovery prepares their required section stops in the
same saved operation; Band retains its primary track.

Two additional cases remain proposals: without an established cycle, a partial
defining take keeps its exact captured duration; with a compatible fixed
Sync/Band recording window already chosen, partial audio stays inside that
window. Automatic Sync/Band close and sample-clock policy remain separate work.

## Evidence and limits

The 21-case `verify_capture_recovery.cjs` suite exercises regions, wrapped capture, silence,
per-pass decay, interrupted overdub, Clear All, failure/retry, persisted history,
offline Redo, length edits and Song/Band publication. The existing transport and
ten-case audio-state reconciliation suites also pass. Chrome and Firefox cover
the ordinary performance route, failed writes, reload, group recovery, later
mix/FX preservation and matching main/small-display waveforms.

The visual waveform uses reference audio samples masked by captured-region
metadata. Meter values and audio remain simulated. Native PCM preservation,
real-time resource reservation, sample-accurate phase, durable power-loss
recovery and hardware testing remain implementation gates. This slice does not
settle the other shared clock, processing or ownership proposals.

See the [shared behavior record](2026-09-08-shared-behavior-proposal.md),
[production audio plan](../plan/2026-09-08-audio-state-parity-plan.md) and
[review evidence](../reviews/2026-09-08-capture-recovery/review.md).
