# Changing loop mode with recorded audio

Status: owner accepted after the live walkthrough on 2026-09-07. Compatible
changes, Cancel, explicit stop-and-switch and incompatible choices were reviewed.
Implemented in the main interactive study. Production audio and
complete mode scheduling remain separate work under the appliance UX programme.
The accepted five-card layout and Wave view are preserved.

## Path and behavior

Settings → Loop settings → Loop mode.

- With no recordings, choose any of the five modes.
- With recorded audio, each card checks the actual track durations. A short
  reason replaces the description of an unavailable mode.
- When loops are stopped, a compatible choice applies immediately.
- During playback, choosing a different compatible mode opens **Switch to [mode]?**
  with **Cancel** and **Stop loops and switch**. Selecting the candidate changes
  nothing. Cancel is the initial encoder focus; Back/Escape also cancels.
- Confirming stops recorded loops, retains the audio and selects the new mode.
  Return to Stage to start playback. Live monitoring and backing playback are
  not stopped by this operation.
- During recording or overdubbing, finish the take first. A queued action must
  finish or be cancelled before switching. These guards are rechecked at commit.
- The page stays open after switching, with focus on the newly selected mode.

No implicit repetition, trimming, stretching, padding or deletion takes place.
Length editing remains in the accepted Multiply and Divide flows. This replaces
both the old blanket content-lock fixture and the earlier repetition proposal.

## Compatibility used by this study

| Target | Existing recorded audio |
|---|---|
| Multi | All populated tracks have equal durations. |
| Sync | Each duration is an integer multiple or division of the primary track duration. |
| Song | Independently sized sections are retained. |
| Band | Durations follow the same primary relationship used for Sync; the rhythm track is retained. |
| Free | Independent durations are retained. |

For Sync and Band, use the existing populated primary track. If there is none,
use the first populated track, ordered by track number. Empty tracks do not
participate in compatibility checks. An empty session has no recorded primary track. Invalid or unknown populated-track lengths
block a new mode until they are available. Selecting the current mode is a no-op.

Checks use beat durations, not the rounded bar readout. Small floating-point
comparison tolerance does not resize or rewrite recordings. For example, 2-, 4-
and 1-bar recordings can enter Sync, while Multi stays unavailable. With 3-, 4-
and 2-bar recordings and Track 1 as primary, Multi, Sync and Band are unavailable;
Song and Free remain available.

These are explicit Segno target rules informed by the recovered mode descriptions.
The extracted Looper X source exposes `modePossible` and a recording guard, but
its native compatibility matrix was not recovered. The exact rules above are
not presented as verified Looper X behavior.

## State and recovery

A mode change preserves track content, layers, edit history, pitch, tempo-follow
settings, FX, monitoring and pedal assignments. It is configuration, so it does
not insert an entry into the accepted audio-edit Undo history. Switch back through
these same cards to restore a prior mode when compatible.

Stopping for a change resets loop playheads. A change while already stopped
preserves stopped state. A failed browser-storage write restores the old mode,
primary and playing/stopped flags, retains the dialog and offers a retry. Nothing
is represented as saved until that write succeeds. The transport handoff clears
stale external-Continue resume bookkeeping without clearing audio history.

## Validation and limits

`verify_loop_mode_changes.cjs` covers the compatibility matrix, exact duration
checks, primary selection, touch and encoder, confirmation and cancellation,
recording/queued guards, the ordinary Settings path, failed-save rollback,
reload and screen bounds in Chrome and Firefox. `verify_loop_journeys.cjs`
regresses the existing setup controls in both browsers. The transport model and
two-display recording journey also pass, including audio-history preservation
across a mode handoff.

This is a silent interaction prototype. It does not prove audio rendering,
real-time atomic storage or complete Song/Band/Sync scheduling after the switch.
Production work must implement those relationships and prove their timing on
Linux; the UI definition is not constrained to the present engine.

Pen's Loop setup section contains the empty-session choice, existing-audio
compatibility example and playback confirmation. The former locked example is
replaced in place. The additional confirmation lives in the same labeled group.

[Try during playback](fx-ux-prototype.html?review=loop-mode-playing) ·
[Try unequal lengths](fx-ux-prototype.html?review=loop-mode-incompatible) ·
[Browser and Pen review images](loop-mode-previews/index.html).

Reference: [Looper X looping modes](../research/sheeran-looper-x-1.0.2/features.md#f02--five-looping-modes)
and [design authority](2026-09-06-loop-setup-ux.md#design-authority).
