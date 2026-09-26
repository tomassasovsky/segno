# Three performance demos for the remaining shared behavior

September 8, 2026. **Proposal for review, except explicitly accepted decisions below.** The recording-recovery slice is now [implemented in the prototype](2026-09-08-capture-recovery-ux.md); this does not close its production or remaining decision gates.
The accepted UI pass remains accepted. These eight contracts consolidate the
[reference follow-up](../research/segno-looper-x-comparison/2026-09-08-recheck/reference-closure-pass.md)
into three tasks. Settled gestures stay accepted; unaccepted recommendations
below are not product approvals. The owner authorized developing concrete recovery prototypes for review.

The next three proposals are now interactive in the
[shared-behavior gallery](shared-behavior-previews/index.html):
[recording timing](2026-09-08-recording-timing-proposal.md),
[processing consequences](2026-09-08-processing-behavior-proposal.md), and
[session field ownership](2026-09-08-session-field-ownership.md). Recording and
recall use the main prototype; processing uses a separate symbolic comparison
tool and does not change the host's render behavior. Eight matching Pen frames
are grouped in sections 38 and 39. These implementations provide evidence for
the choices below; they do not turn those choices into approvals or close the
183-row audit's production/reference gates.

The defining-take proposal uses duration and the current tempo to choose whole
bars, not audio beat detection. Sync/Band Auto currently refuses transformed
primary playback before recording; extending that timebase and explicit primary
handoff remain open. Performance capture explicitly compares both sides of final
output level/mute, rather than adopting the recommendation below silently.

## 1. Record a phrase and add another part

**Demo:** Set 120 BPM, 4/4 and four bars. Record with click on, then off: both
takes end after eight seconds. Change to Auto and finish manually. Next, keep a
four-bar primary playing in Sync, request an Auto close during bar three, and
see the scheduled end at bar four. Compare starting from silence with adding a
part to an already running loop.

**1 — First take and clock.** Preserve the accepted independence of fixed length
from audible click, the selected Record → Play/Overdub outcome, and hundredths
BPM. Recommend fixed bars use the selected clock; Auto ends manually, with
click-on retaining tempo and inferring bars, and click-off inferring tempo/bars
for the defining take. Never silently re-infer an existing musical grid. The
exact inference/ambiguity rule still needs a demonstrated musical result.

The contradiction is explicit: the later audio plan repeats the reference's
fixed-bars + click-off manual closure/inferred tempo, whereas the accepted length
study deliberately separates click audibility from closure. **Recommendation:
keep the accepted fixed-bar behavior.** Propose external fixed length follow the
received grid, without local inference. On clock loss, retain the partial take
and stop its capture; the exact loss/restart boundary needs review and frame tests.
[Accepted length study](2026-09-06-loop-setup-ux.md#length-and-quantization-current-proposal),
[conflicting clock plan](../plan/2026-09-08-audio-state-parity-plan.md#3-mode-relative-clocks-first-take-inference-and-once).

**2 — Primary and legal close.** Preserve Multi's equal durations, Sync/Band's
integer multiple/division relationship, Song/Free's independent lengths and
compatible-only mode changes. Recommend Auto Sync/Band close at the next full
primary cycle; an explicitly chosen valid shorter length closes at its own
boundary. Show the boundary before it happens. Propose primary reassignment only
while stopped, after checking all tracks; clearing the primary requires an
explicit valid successor or leaves the clear unapplied. No automatic resize or
silent reassignment. **Choice:** approve this cycle-based Auto close and explicit
primary handoff; exact representable divisions still need a sample-clock policy.
[Accepted compatibility](2026-09-07-loop-mode-transitions-ux.md).

**3 — Count-in.** Preserve Off/1/2/4 bars and the accepted Sound/count-in
exclusivity. Recommend count-in for an explicit record, overdub or play action
that starts a stopped transport under internal clock. Adding a part while the
transport runs uses its existing execution grid, without a new count-in.
External receive uses no local count-in in this proposal. **Choice:** count-in
for all three stopped-start actions, or first-record-only scope.
[Recording and timing](2026-09-06-loop-setup-ux.md).

Rows: LX-009/030/031/033/041/043/044/163; LX-038's approved fine-BPM UI stays intact.

## 2. Recover a take without losing the rest of the performance

**Demo:** In Multi, Track 1 contains four bars. Cancel Track 2's initial take
after one bar with Undo, then request Redo: the restored track still spans four
bars, with one bar of captured sound and silence in the unwritten portion.
Separately, Clear
All while one track plays, another captures and a third is armed. Change a fader
after the clear, then Undo once. Demonstrate a failed recovery write and retry. No new recovery dialog is needed.

**4 — Partial initial-take Redo in Multi: accepted September 8.** The owner
clarified that recorded content duration and loop duration are distinct. Once a
four-bar Multi cycle exists, recording only one bar on another track leaves that
track four bars long. Preserve the captured audio's position within the cycle;
unwritten portions are silent. Do not repeat the short phrase to fill the cycle
or stretch its audio. Undo still empties the track and retains the take; Redo
restores it into that established cycle and starts playback, without restarting
capture, changing modes or stopping the other tracks. No recovery dialog is
needed for this case.

The earlier proposal to stop the loops and recover in Free is superseded. It
incorrectly treated captured audio duration as the required loop duration. This
decision concerns partial capture within an already established Multi cycle;
it does not authorize resizing unrelated imports, completed loops or other
modes. Recovery when no cycle has yet been established is demonstrated as a separate proposal: retain its exact captured duration. The established-cycle rule above now passes model and Chrome/Firefox interaction checks.

**5 — Clear All during capture or arm.** Preserve one grouped Undo/Redo, earlier
histories, and only the playing/stopped state that Clear All changed. Later fader
and FX edits survive; elapsed wall-clock time never rewinds. Recommend freezing
nonempty partial audio at Clear, canceling pending arms, and committing only
after recovery storage is reserved. Undo returns former playing tracks to play,
stopped tracks to stop, and formerly capturing tracks to stopped/playable;
canceled arms remain idle. Restore shared tracks from one saved group phase
anchor and independent tracks from their saved local phases. A partial Multi
take retains the established cycle with silence in unwritten portions, as
accepted above; active Clear All still needs its own recovery decision. The prototype also demonstrates exact captured duration without a cycle and retention of an already chosen fixed Sync/Band window; these extensions remain proposals.
**Choice:** accept this active-capture exception to “restore the previous state,”
or revise the stopped/playable recovery rule shown in the prototype. Never resume a microphone recording
merely because Undo restored history.

Failed publication keeps the old playable state. Newer audio edits on affected
tracks must be undone first; group recovery cannot overwrite them. A zero-audio
canceled take creates no playable recovery entry in this proposal.
[Accepted Undo/Redo and remaining phase cases](../brainstorm/2026-09-07-undo-redo-brainstorm-doc.md),
[shared history plan](../plan/2026-09-08-audio-state-parity-plan.md#2-one-recorded-content-history-and-atomic-group-recovery).

Rows: LX-054/055. The same dependency protection applies to accepted grouped Bounce.

## 3. Hear the intended sound and reopen the session safely

**Demo:** Send a live voice and recorded guitar through an output reverb. Stop
the guitar and hear what remains. Bounce two selected tracks, then compare that
file with Record performance. Finally, reopen session A after changing a physical
controller and an input alias in session B; repair A's missing connection and
cancel once before applying it.

**6 — Live, capture and playback processing.** Preserve printed Pre, draining
Post/output tails on ordinary Stop, independent live monitoring, copied input
recipes for new parts, and true output FX over every routed source. Recording
trim affects new capture, not live Mixer level. Recommend Track Mono average
left/right before whole-track processing, so a subsequent stereo effect can
widen it. **Choice:** this placement versus mono at the final track output.
Also demonstrate the proposed tail distinction: Clear stops new track feed and
allows downstream tails; Mute immediately silences that track including its
Post tail, while already mixed output tails may drain. Bypass passes dry signal
and stops feeding new wet signal while the existing tail drains. An explicit
all-sound cut ends tails. Ordinary Stop behavior is already settled; these other
actions are not. [Accepted FX direction](2026-09-06-fx-ux-design.md#owner-direction-recording-placement-tails-and-output-effects),
[accepted input scope](2026-09-07-audio-routing-ux.md#input-setup).

**7 — Bounce, audition, export and capture.** Preserve Bounce's source/destination
selection, Keep/Clear sources, Wrap/Cut tails and grouped recovery. Recommend
Bounce render the selected recorded tracks with their processing and levels,
regardless of transport, Mute or Solo; exclude live inputs and shared output FX.
Use a neutral destination to avoid processing the sound twice. Two- and three-bar
sources span six bars; independent-time/Once material needs an explicit duration,
not an unbounded calculated cycle. Wrap folds the tail into that duration; Cut
ends it there, with actual rendering/processor limits still to prove.

Recommend performance capture record Main after its output FX and final level,
including routed live/backing/click. Selected-track exports use their declared
render scope. Preset audition snapshots the exact prior instance; Cancel restores
it. **Choice:** selected-track Bounce/export versus the current audible Main mix
as distinct recording products. The accepted Bounce controls did not approve
all hidden rendering rules, and the performance recorder is still a proposal.
[Bounce acceptance and audio limits](2026-09-07-bounce-performance-ux.md),
[performance capture proposal](2026-09-07-performance-recording-ux.md).

**8 — Session and physical ownership.** Preserve accepted session recall of
musical pedal/expression assignments, colors, monitoring, track labels, FX and
routing, plus input pairing/trim/position. Keep aliases appliance-wide and always
release held contacts. Recommend physical identity, calibration, device
capabilities and controller hardware configuration remain global; saved musical
bindings refer to stable session targets. Global preset/audio catalogues do not
rewind when an older session opens. Missing hardware remains visibly unresolved
until a compatible replacement is explicitly applied; merely selecting a device
must not remap ports or load the session.

**Choice:** approve this field split, with a restore preview that separates
musical content from physical setup. Full appliance backup includes both scopes,
but adopting another appliance's physical configuration/calibration needs an
explicit restore choice. The later plan's broad device-global source assignments
conflict with accepted session mappings; the prototype's broad rig snapshots can
also overwrite later physical settings. Neither is a safe default for broader
session repair. [Accepted session boundaries](2026-09-07-session-library-ux.md#state-boundaries),
[accepted input ownership](2026-09-07-audio-routing-ux.md#input-setup),
[conflicting field inventory](../plan/2026-09-08-audio-state-parity-plan.md#state-ownership-and-the-restore-contract).

Rows: LX-059/074/080/109/116/139/145/180; these choices constrain LX-181's broader recovery.

The next review can use these three proposed review scenarios and record only deviations
from the recommendations. Recovery that changes a loop mode, replaces physical
settings or commits a different sound must wait for its specific decision.
Until then, missing-dependency review can preserve identity, expose the affected
scope and support Cancel without silently changing the live rig. FX physical
units, usable factory audio, measured renderer limits and appliance proof remain
separate evidence gates.
