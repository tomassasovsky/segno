# Accepted recovery and performance flows

All six authorized slices are implemented in the main silent prototype and
saved as fifteen editable Pen references. The owner accepted all six flows on
September 9, 2026, including the simplified Review connections popup and their
recorded walkthrough. This settles the demonstrated layouts and interactions
under issue 919. Native appliance implementation and measured limits remain
separate.

[Watch the six-flow recording](recovery-expansion-previews/walkthrough.html) ·
[Open the review gallery](recovery-expansion-previews/index.html) ·
[Plan](../plan/2026-09-08-recovery-expansion-plan.md) ·
[Verification and independent review](../reviews/2026-09-08-recovery-expansion/review.md)

| Flow | Entry | What to try |
| --- | --- | --- |
| Recorded audio recovery | Library → session → Open | Find the original or an intact backup, cancel the pending repair, then apply it. Sparse recordings retain their position and silence within the established loop. |
| Physical connection repair | Library → session → Open → Replace | Choose compatible current ports and review affected routes. Stereo channel roles and logical names remain intact. |
| Appliance backup | Settings → Storage → Appliance backup | Back up sessions, recordings, backing audio, presets and settings; inspect a package before restoring it. |
| Timing track | Settings → Loop settings → Timing source | In Sync or Band, choose a compatible track. During playback, cancel or explicitly stop and switch. |
| Preset audition | Effects → rack → Try preset | Compare compatible family presets. Keep saves; Cancel, leaving the editor or beginning capture restores the original sound. |
| Long recordings | Library → Audio → Record performance | Review a multipart take, a low-storage stop and unavailable capacity. All parts remain one Library recording. |

Repairs stay pending until their final action. Current device/media availability
is rechecked then. Cancel and ordinary failed writes preserve the current setup;
an appliance-store rollback failure is reported separately. Successful appliance
restore blocks old-state input and timers immediately, then restarts into Tracks.

Preset trials preserve rack bypass, placement, routing and stable control IDs.
This version accepts the same family and compatible processor/control layout;
different layouts remain visible with an explanation. The silent prototype
changes parameter state but cannot demonstrate the resulting sound.

The accepted long-recording design uses stereo 24-bit PCM, 2 GB parts, a 1 GB
reserve and a warning at 60 seconds remaining as its prototype baseline. These
are design values, not measured device limits. Remaining time uses simulated capacity and the frozen recording
format. Failed checkpoints preserve the last durable metadata; confirmed
discard releases its allocation only after saving succeeds.

The 3:27 walkthrough records actual browser interactions with visible taps and
short captions. Its six chapter buttons support jumping between flows. It shows
Cancel and successful outcomes; the long-recording chapter explicitly labels
simulated time advancement. It has no audio track.

## Evidence

- 143 combined model/controller tests pass.
- Chrome and Firefox pass all six journeys, including cancellation, changed
  dependencies, failed writes, retry and reload. Stereo grouping and existing
  recording, Library and earlier repair journeys also pass.
- Five independent review roles report no unresolved actionable findings in
  their declared non-authored scopes.
- Pen sections 42–47 contain fifteen 1920 × 1080 references. All 494 text
  positions and fifteen encoder focus outlines pass native alignment checks.
  Every new native render was visually inspected; section frames do not overlap.
- Recording QA caught compressed port-choice reason labels. The scoped layout
  correction passes Chrome and Firefox, and its corrected Pen reference is
  saved. The video player passes chapter seeking and narrow-viewport checks.

## Still outside this delivery

Real audio bytes and checksums, USB/filesystem transactions, native interface
identity, disk capacity, power-loss recovery and hardware validation are not
implemented by this browser pass. The remaining downstream-tail and recording
tap policies are not settled implicitly. The full product audit is not closed
by these six prototypes.

Details: [recorded recovery](2026-09-08-recorded-audio-recovery.md),
[appliance backup](2026-09-08-appliance-backup.md),
[timing and audition](2026-09-08-primary-and-preset-proposals.md),
[ports and recording](2026-09-08-audio-ports-and-long-recording.md).

The connection review now shows “For” and “Use connection” side by side, plus
a route count. Exact affected routes remain on the replacement picker. The
matching Pen reference and second video chapter include this refinement.
