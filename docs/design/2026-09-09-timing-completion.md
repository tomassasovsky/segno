# Timing completion

Issue 919. This is the owner-authorized browser design pass for the remaining
timing cases. It extends the accepted timing-source and sparse-capture studies;
it does not implement or validate native audio, MIDI hardware, or appliance
storage.

## Musical cycle and recorded material

Sync and Band now use the timing source's stored musical length and the session
beat clock. Its musical position is independent of its audible speed, direction,
Once setting, and Follow tempo setting. Those playback controls remain usable
while another Auto take records. If Once stops the source during a take, the
musical cycle continues until that take reaches its requested finish boundary.

An Auto take starts when requested. Finishing queues the next musical cycle end.
For example, starting two beats into a 16-beat source and finishing at the next
cycle end creates a 16-beat timeline with 14 recorded beats and two leading
silent beats. Changing the source to Double speed or Reverse does not move that
finish or rewrite either recording. Compatible shorter fixed recordings retain
their existing behavior. Multi still distinguishes a capture's material from
its established loop timeline.

Independent playback uses its recorded/imported seconds. A source recorded as
eight beats in four seconds still plays in four seconds when the session changes
from 120 to 60 BPM and Follow is off; the eight-beat musical cycle then lasts eight
seconds. The source tempo readout is derived from recorded duration rather than a
fixture-only constant.

Every newly captured layer stores `seconds`, measured from real elapsed time
for that pass. Its `beats` and `regions` describe musical placement. External
tempo changes and first-take inference cannot reconstruct or overwrite the
recorded seconds. The host materializes recorded-file descriptors from
`layer.seconds`. Existing source descriptors remain attached to the same audio.

The cycle starts from zero when playback or recording begins from an idle
transport. It freezes while the transport is stopped. This also preserves an
explicit Song Position while waiting for Continue. A confirmed playing-source
handoff stops playback and resets its cycle; it never stretches or restarts
recordings.

## Clearing the timing source

Clear on the current Sync/Band timing source, while other recorded tracks remain,
opens the existing Timing source screen in a clear-and-replace mode. Only
recorded successors whose retained loop lengths are compatible can be used.
Playing audio requires the explicit **Stop, clear and switch** confirmation.
Stopped audio applies directly after selecting a successor. Back cancels the
request, and failed storage leaves the request available for retry.

Track pedals choose their numbered tracks in the displayed A/B bank. BANK changes
the bank, STOP confirms, and MODE cancels to Stage. The optional timing review
uses track pedals 1/2/3 for half/current/double and STOP or MODE to keep the current
timing. Captured actions carry the dialog revision and exact choice; a held
contact cannot act after bank changes, cancellation or reopening the dialog.

Clearing the last recorded track or Clear all explicitly stores no timing source.
The next first recording establishes it again. Clearing and the chosen source
are one published history entry. Undo restores the source and recorded content;
later independent mixer or FX changes survive. A later manual source change is
not overwritten by replaying older source metadata.

## First take timing review

The existing automatic estimate still chooses 1–64 whole bars and 30–300 BPM by
the smallest proportional distance from the selected tempo, with fewer bars
winning exact ties. It applies only to the first Auto take with click off and an
internal clock. If no candidate fits, the selected tempo and measured duration
remain unchanged.

After a successful estimate, **Review tempo** opens an optional review of the
current, half, and double bar counts. Invalid alternatives are absent. This is
not an interruption at the end of recording. A correction changes counted beats
and tempo together, preserves captured seconds and file identity, and adds its
own Undo entry. Failed storage preserves the previous estimate. Newer audio,
changed meter, manual tempo, or external clock selection makes a stale estimate
unavailable. **Keep current timing** dismisses the current review for this run;
the saved estimate remains inspectable after reload.

## Loss, failed publication, and immediate silence

Actual external clock loss finishes active capture at detection. The partial
take retains its measured seconds and sparse musical window. The capture ends
stopped and playable; other tracks follow the chosen Keep playing / Stop loops
policy. Queued arms are canceled, so reconnecting does not unexpectedly record.

If publication fails, the take stays frozen in memory at the measured endpoint.
It does not keep accumulating seconds and is not silently rearmed. **Stop**
retries saving the retained material; **Undo** retains an exact Redo candidate.
The same rule handles failed automatic fixed-length and overdub-pass saves
without repeating publication indefinitely. An unsaved in-memory take cannot
survive closing or reloading the browser; the persistent last successful content
and history remain intact.

The persistent Stage cue identifies a held take and offers Save; STOP and Undo
remain available from the pedals. Frozen material participates in session,
device, mode, clock, backup, update, restart and restore guards. New loop and
session changes cannot discard it. The session publication adapter rechecks this
guard, so an earlier opened action cannot bypass it. The prototype stays running
if Restart's existing Finish Audio step cannot save the retained take.

**Cut all sound** always silences recorded players and cancels queues. It tries
to finish capture, freezes any unsaved material for retry, and cancels a pending
source-clear request. The host separately stops backing and resets illustrative
effect tails. A storage failure does not defeat this immediate sound command.

Song Position uses standard MIDI sixteenth-note units: the selected external
source's integer 0–16383 becomes quarter-note beats via `value / 4`. It is accepted
only with Follow Play / Stop enabled and a stopped transport with no active
capture or queued action. Continue resumes from that position; Start resets to
zero. A playing or recording transport refuses the seek with a visible reason.
Generic MIDI Learn does not treat Song Position as an assignable control.

## Host adapter contract

`createStageTransportStudy` adds `primaryClearRequested(index)`. Its published
clock metadata may contain `tempo`, `primaryTrack`, or both. Hosts apply only
present fields, including an explicit `primaryTrack: null`; they must not erase
tempo when only the source changes.

- `resolvePrimaryClear(successorIndex)` and `cancelPrimaryClear()` service the
  existing chooser. `primaryUI.openClear(trackId)` takes a track ID; its `clear`
  callback translates the chosen ID to an index, and `cancelClear` cancels the
  transport request.
- `adjustFirstTiming(bars)` and `dismissFirstTiming()` service the optional
  review. `snapshot().firstTakeTiming` provides the track, current bar count,
  tempo, captured seconds, and eligible `halfBars` / `doubleBars` values.
- `clockLost({keepPlaying})` is called for both external-loss policies.
  `cutSound()` is an immediate-silence command; the caller also leaves the source
  chooser and stops backing / tails.
- `songPosition(beats)` receives a validated selected-source SPP position.
- `snapshot().timingCycle` exposes the source index, stored beat span and musical
  position. `primaryClear` exposes the source and valid successor indices.
  `frozenRecoveries` exposes retained track indices, measured seconds and beats
  for a persistent recovery cue, separate from the temporary notice.

## Review and video entry points

Use `fx-ux-prototype.html?canvas=actual&review=<scene>` for isolated demonstrations.
These scenes execute the same transport commands and a review clock; storage
verification uses the normal URL instead.

| Scene | Visible state and next action |
| --- | --- |
| `timing-primary-speed` | Double-speed primary; Auto take queued to its musical cycle. Let it finish and inspect Wave. |
| `timing-primary-reverse` | Reversed primary with the same musical-cycle completion. |
| `timing-primary-once` | Once primary; let its audible playback end while the queued take completes. |
| `timing-primary-independent` | Primary Follow tempo disabled; the capture still uses the explicit session cycle. |
| `timing-primary-clear` | Real Clear request in the successor chooser. Choose Track 2, then Stop, clear and switch. Undo restores the source. |
| `timing-first-review` | Stopped 3.5-second first take, inferred as two bars; choose one bar and inspect unchanged seconds. |
| `timing-first-correction` | One-bar correction already applied to that same 3.5-second take; Undo restores two bars. |
| `timing-clock-loss` | Recovered sparse take after loss; inspect Wave, then Undo / Redo without a new capture. |

The existing `timing-count-in`, `timing-first-take`, `timing-cycle-queued` and
`timing-cycle-complete` scenes remain available. The walkthrough should perform
the listed interactions, not merely hold on the scene's initial image. The
coordinator owns video capture and matching editable Pen frames.

## Verification

`verify_timing_completion.cjs` covers the new musical cycle, source-clear
transaction, real-seconds measurement, clock-loss failure/retry, SPP,
first-estimate correction, and Cut sound. Existing timing, capture recovery,
primary chooser and transport checks exercise the neighboring accepted behavior.

`verify_timing_completion_browser.cjs` uses Chrome and Firefox, a fake clock,
normal-host dispatch, actual `Storage.prototype.setItem` failure, recorded-file
identity and seconds, reload, primary clearing, optional review, selected-source
MIDI loss, SPP and Continue. Browser captures are written to
`timing-completion-previews/`.

Final observed checks on September 9:

- The six focused Node files report 127 passing tests, including the existing
  transport and ten reconciliation acceptance contracts.
- The new completion browser suite passes Chrome and Firefox on normal storage
  URLs. It covers real quota failure, reload, physical foot routing and stale
  contacts, frozen New loop / session refusal, failed Restart, persistent cue,
  exact Stop retry, external clock loss, and SPP.
- The existing recording-timing browser suite also passes both browsers after
  replacing its obsolete playback-refusal expectations with the completed
  musical-cycle behavior.
- Twelve actual 1920×1080 captures cover six states in both browsers. The first
  review, source chooser and held-take states were inspected; the held-take
  column message was shortened to avoid clipping.
- An independent reviewer reproduced the original 0.63-second frozen-lifecycle
  failure and verified the repaired New loop, session, Restart and Stop paths in
  Chrome and Firefox.
