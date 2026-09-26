# Timing-source handoff and reversible preset audition

**Owner accepted — September 9, 2026.** The demonstrated layout and behavior
are locked in, including the revised connection summary where applicable.
See the [acceptance record](2026-09-09-recovery-expansion-delivery.md).
Native audio and hardware verification remain separate.

September 8, 2026. Local prototype work under issue 919 and the approved
[recovery expansion plan](../plan/2026-09-08-recovery-expansion-plan.md).
These are silent browser interactions; they do not claim native audio behavior.

## Reference and decisions

The local Looper X reference shows a primary track in Sync and Band, with
recorded lengths following multiples or divisions of that track. Its preset
browser loads on row selection and encoder navigation. Its Done action has no
demonstrated rollback of the earlier unsaved sound. See
[mode evidence](../research/sheeran-looper-x-1.0.2/features.md) and
[UX26](../research/sheeran-looper-x-1.0.2/ux-paths.md#ux26--audition-effect-presets).

Segno adds an explicit timing-source handoff and Keep/Cancel for a preset trial.
The owner accepted the bounded first version: same-rack, same-family presets
with compatible existing controls, retaining rack bypass and showing its status.
Incompatible layouts remain visible with a reason. Replacing processors or
retargeting assignments by guess is outside this workflow.

## Timing source

Loop settings in Sync and Band contains Timing source. A compact crown marks
the current timing source in the Stage Tracks, Wave and Mixer views. The selection screen
shows the current track and the recorded loop lengths. Empty tracks, unavailable
lengths and incompatible ratios cannot be selected. A recording or queued
action blocks the handoff. The first recorded track is the default until a
valid explicit source is chosen; a later lower-numbered recording does not
replace it.

A compatible stopped selection saves directly. If any track is playing, the
confirmation says Stop and switch. It rechecks the current state, stops playback
and changes the source only after saving succeeds. Cancel, stale conditions or
a failed save leave the current source and recordings intact. Playback remains
stopped after a confirmed handoff; it is not restarted implicitly.

Compatibility uses the established loop timeline, not the amount of captured
audio. A sparse take that contains two recorded beats within an eight-beat loop
still has an eight-beat timing cycle. This selection never resizes a loop,
stretches audio, moves regions or discards edit history.

`primary-track-study.js` provides the pure current-source/availability helpers
and the page/confirmation state. The host supplies fresh context and the atomic
commit. `loop-ux-study.js` adds the existing-menu entry through `primarySummary`.
The page is `loop-primary`; actions are `primary:open`,
`primary:choose:<encoded track id>`, `primary:confirm` and `primary:cancel`.

## Try preset

The rack editor opens Try preset with factory and personal sounds from the
current family. Touching a row or moving encoder focus to it applies temporary
values to the rack. The overlay shows whether the rack is enabled or bypassed;
that state stays as it was. Repeated rendering or focus on the already selected
row does not reset live control changes made during the trial.

The model retains one exact original rack and channel scope across every trial.
It changes parameter values through exact module names and parameter keys while
retaining existing module IDs, order, rack placement and activation rule. A
preset with different effects or controls is unavailable rather than silently
remapping expression or MIDI targets.

Keep publishes the currently tried sound through the host storage boundary.
A failed save retains the trial and its original baseline for retry or Cancel.
Cancel, Back, leaving the editor, or beginning capture restores the previous
rack and channel values. Reload before Keep returns the saved baseline. Reload
after Keep restores the chosen sound. Saving a reusable preset remains the
separate Save preset action in the editor.

`preset-audition-study.js` exposes compatibility/candidate helpers, the reversible
session and the overlay controller. The host supplies `read`, `preview`,
`restore` and `publish`. Its `persisted(rig)` projection substitutes the original
rack/channel scope before ordinary saving or session capture. This also excludes
MIDI-driven changes to trial controls from persisted setup. Other setup changes
remain current. The host must apply normal released-contact persistence rules
after this projection, cancel before navigation/capture, and materialize stable
module IDs before beginning a trial.

The UI opens with `{rackId, presets, opener}`. Optional preset `origin` labels
identify Factory and My presets. The host calls `focused(actionId)` for deliberate
encoder movement, not generic render-time focus restoration. Actions are
`audition:choose:<index>`, `audition:keep` and `audition:cancel`.

## Verification

Focused state/controller checks:

```sh
node --test docs/design/verify_primary_track.cjs docs/design/verify_preset_audition.cjs
```

Normal-storage Chrome and Firefox author journey:

```sh
node docs/design/verify_primary_audition_browser.cjs
```

The focused suite passed 28 tests. Chrome and Firefox passed the integrated
normal-storage journey; the captures were visually inspected. These are local
author checks, not native engine or CI evidence.

The model/controller suite checks loop ratios and captured-duration separation,
recording/queue guards, current-source no-op, confirmation cancellation, stale
revalidation, failure/retry, exact FX rollback, channels, stable target IDs,
MIDI persistence projection and touch/encoder behavior. The browser suite checks
the real command bridge, storage failure, first-recording ownership and reload,
and saves captures under `primary-audition-previews/`.

The host provides review scenes `primary-stopped`, `primary-playing` and
`preset-audition-active`. Native Pen references and final combined verification
are coordinated in the parent recovery expansion pass.

## Input grouping integration

Pairing inputs now groups their saved physical port identities through the
port-repair model. Splitting restores each member's original jack. Both steps
keep output routing and recording trim, and failed storage publication restores
the previous grouping, bindings and recording-input selections together. A pair
that does not match the current interface's declared left/right group is refused.

`node docs/design/verify_input_binding_grouping_browser.cjs` passed Chrome and
Firefox using a deliberately remapped first pair on physical jacks 3/4, failed
pairing and splitting writes, retry/reload and an incompatible-pair refusal.

The main display captures use the actual 1920×1080 screen inside its lab wrapper.
Bounds assertions cover timing options and preset-dialog labels/buttons; the
editor header fits within the display without a markup change.
