# Record performance

Status: proposal for owner review. Tracked under the appliance UX programme (#919).
The prototype defines the intended product behavior. It does not capture audio.

## Journey

Library → Audio → Record performance opens a recorder for **Main output**.
Start recording begins immediately. An elapsed-time display and red recording
state identify an active take. Outside this page, the existing top bar carries a
compact recording indicator that returns to the recorder. There is no added
bottom bar and no duplicated timer on the recorder page.

The intended recording contains the sound routed to Main output: monitored live
inputs, recorded tracks, their effects, output effects and backing audio. Anything
not routed there is absent. Click is included if routed there; this slice does not
introduce separate click routing. This is a continuous performance capture, distinct
from Save audio's render of selected loop tracks.

Stop recording finishes the file and leaves loops and backing audio playing.
The user may navigate and perform while recording or saving. Saved recordings
appear in Internal → Performances, with the current session name and a numbered
take. View recording selects that exact file. It can use the existing preview,
prepared-list, backing and track-import journeys.

## Foot controls

Record performance is assignable as Press or Hold in Pedals. It directly starts
or stops the recorder without entering a touchscreen-only page. Press and Hold
remain mutually exclusive. The accepted Mode defaults remain Mute on press and
Custom on hold. The review fixture assigns the custom Stop pedal to recording;
this is a demonstration, not a new default assignment.

A press assignment reads Record performance before capture and Stop recording
while active. Its configured LED color stays lit while recording, then goes dark.
Saving disables retriggering. When a recording needs recovery, the same assignment
saves the recoverable take. Exit restores track controls without stopping capture.

## Saving and interruption

- Start commits an active-take descriptor before showing Recording. Failure leaves
  the recorder ready, with a storage error; it does not claim capture started.
- Finalization writes the new Audio Library entry and clears the active descriptor
  together. A failed save keeps the pending recording for retry and does not add
  a duplicate or incomplete Library entry.
- An interrupted take shows its available duration, Save recovered audio and
  Discard recording. Copy explicitly says the take may be incomplete. Discard
  requires confirmation; Cancel and Back keep the recording.
- A storage failure during capture ends that capture while loops continue.
- New Loop and session recall are blocked while recording, saving or unresolved
  recovery. Browsing and session naming remain available. Take naming retains
  the session identity captured at Start.
- Recorder state and the Audio file catalogue are global. Session snapshots do
  not contain the recorder or rewind take numbering when recalled.

## Prototype evidence and implementation boundary

The browser stores metadata checkpoints every five simulated seconds. On reload,
it recovers the last committed duration, never the elapsed downtime. This cadence
is a test mechanism, not a promised appliance loss boundary. Real capture needs
an engine-supported durable boundary, truthful available/lost audio reporting,
output routing, finalization, disk-full handling and on-device interruption tests.
No audio bytes, waveform or power-loss durability are proved by this study.

The recorder proposals follow the Library capture/recovery home in the appliance
roadmap (S07) and keep continuous capture distinct from exports (S08). Existing
capture architecture is implementation evidence, not a restriction on this UX.
This is not a claim that Looper X exposes the same recorder interface.

`verify_performance_recording.cjs` exercises the full lifecycle in Chrome and
Firefox: encoder Start, foot entry and Start/Stop, continuing loop/backing playback,
session guards, atomic storage errors/retry, checkpoint recovery, explicit discard,
Library reuse and catalogue retention across session changes. Shared session,
Audio Library and pedal-performance regression suites also pass in both browsers.

[Browser and native Pen gallery](performance-recording-previews/index.html).
Pen section 20 groups Ready, Recording, Foot recording, Saved, Recovery and Save
failure as proposals. The geometry audit covers those screens and the three Audio
browser screens that gained the recorder entry.

## USB export follow-up

The owner requested and approved [Export to USB](2026-09-07-audio-usb-export-ux.md)
from each selected internal recording. It preserves the original and handles
matching filenames, cancellation, missing media and storage errors. The six export
states now share the Record performance section in Pen.
