# Mapping parity correction

The silent prototype now distinguishes direct commands from performance-mode
entry. MIDI and External pedals share the same assignment catalogue and dispatch
contract. Direct commands resolve their selected, fixed or all-track target once
when triggered, preserving the current performance page, transform selection and
bank. This is a design implementation; there is no new native audio processing,
controller firmware, appliance validation or Flutter integration.

## Behavior

- MIDI Control On/Off pauses learned control dispatch across devices. Existing
  mappings remain editable. Disabling, editing or disconnecting releases held
  parameter and FX contacts; re-enabling requires fresh input and pickup.
- Learn captures only the chosen physical device. Receive channel can be 1–16
  or Omni. Omni expands channel matching within that device. Overlapping Omni
  and channel-specific mappings are conflicts, including when either is disabled.
  Simultaneous Omni contacts remain held until every matching channel releases.
- Each learned input can address multiple direct actions and parameters. Controls
  retain independent ranges, reversible range direction, pickup, On/Off and
  Held/Released endpoints. Program messages trigger per message. Release-triggered
  actions are pulses; an FX press action follows the source contact.
- Direct speed choices are ½×, 1×, 2×, 4× and 8×. Pitch steps are ±1 semitone,
  limited to ±12; a grouped step rejects the whole group at a limit. Double/half
  length and Peel use the same helpers as their foot modes. Capturing blocks a
  group transform; original-only tracks block grouped Peel. Empty tracks are
  ignored by audio transforms. Length edits also update the transport duration.
- Clear all uses the transport's grouped recovery operation. It must never be
  implemented by dispatching eight separate Clear commands.
- Track N pedal selects a fixed track and advances Record / Play. Select track N
  only changes selection. Both are explicit choices, with the same meaning from
  MIDI and external switches. The guide's “Select Track (Global FS)” labels do
  not completely specify this distinction; Segno's two choices avoid relying on
  an ambiguous label. The reference-equivalent footswitch rows use Track N pedal.
- Click and Backing expose Volume and Pan. Loop exposes tempo, click behavior,
  count-in, fade duration and playback/length/quantize defaults. Each track
  exposes decay, playback once, follow tempo, preserve pitch, record length,
  record timing and fade duration. Mapping values are normalized; storage uses
  the same physical units as touch and foot controls. Multi's per-track length
  stays locked to the shared default. Capture and external-clock tempo guards
  also apply to mappings. A nonzero count-in restores pedal-triggered recording.
- Decay remains Segno's accepted inverse of feedback: 0 keeps earlier layers,
  100 replaces. Mapping the reference's feedback values therefore requires an
  inverted endpoint range. Fade is 0.5–30 seconds in 0.5-second steps, consistent
  with the accepted foot fade control; the reference's unexplained CC0–99 is
  not treated as a physical time scale.

External rack activation assignments still belong to External pedals. No
external source choices are added back into the FX activation picker.

## Host integration

Load `mapping-parameter-targets.js` and `mapping-action-dispatch.js` after
`pedal-action-catalogue.js` and before the main application script.

Create the shared typed target provider before constructing expression/MIDI UIs:

```js
const mappingParameters = window.createMappingParameterTargets({
  read: () => rig,
  tracks: () => trackNames,
  trackLabel,
  recording: () => Object.values(captureState)
    .some(value => ['recording', 'overdubbing'].includes(value)),
  externalClock: () => syncUI?.external() || false,
  beforeTempoChange: () => stageTransport.tick(),
});
```

Append `mappingParameters.destinations()` to `expressionDestinations()`. In the
base mix-target loop, skip Click, Backing and Loop: those destinations use the
new typed targets. Append `mappingParameters.targets()` after the existing mix
and FX descriptor targets. Expression's destination tabs need `sources` (Click
& backing) and `loop` (Loop); the external switch picker includes those groups.
All three mapping surfaces then see the same target objects.

The new parameters use `rig.expressionMix.Click/Backing`, `rig.fadeSeconds`,
`rig.trackFadeSeconds`, `rig.loopSettings.playback/trackPlayback`,
`lengthTiming/trackLengthTiming` and `audioTempo/trackAudioTempo`. No second
persisted mix or loop model is introduced.

Pass the MIDI setting callbacks with the existing transactional storage policy:

```js
readSettings: () => rig.midiControlSettings,
writeSettings: value => {
  const old = rig.midiControlSettings;
  rig.midiControlSettings = copy(value);
  save();
  if (!review && !storageOK) {
    rig.midiControlSettings = old;
    return false;
  }
  return true;
},
```

Pass `soloState.toggle` to `createPedalPerformanceStudy`:

```js
toggle: i => {
  const values = rig.soloTracks ||= Array(8).fill(false);
  values[i] = !values[i];
  save();
},
```

Replace the old `dispatchSwitch` body with the shared dispatcher. It can be
initialized after all UIs, since the earlier constructors receive the forwarding
function without invoking it:

```js
const mappingDispatch = window.createMappingActionDispatch({
  selected: () => Math.max(0, trackNames.indexOf(soundTrack)),
  trackCount: () => trackNames.length,
  selectTrack: i => stageTransport.command('Select', i),
  trackPedal: i => {
    stageTransport.command('Select', i);
    stageTransport.command('Record / Play', i);
  },
  bank: () => { bank = 1 - bank; save(); render(); },
  fx: (i, token) => {
    logicalPedalDown(i, token);
    return () => logicalPedalUp(token);
  },
  direct: action => performanceUI.direct(action),
  invoke: label => performanceUI.invoke(label),
  transport: action => stageTransport.command(action),
  tapTempo: () => loopUI.action('loop:tap'),
  backing: action => audioUI.performanceCommand(action),
  session: action => sessionUI.command(action),
  available: () => connected && !powerUI?.locked(),
  feedback: message => notify(message),
});
function dispatchSwitch(action, token) {
  return mappingDispatch.dispatch(action, token);
}
```

The dispatcher propagates only release callbacks. Direct transformation results
are `{handled, changed, reason?}`; unknown operations have `handled: false`.
Refused capture/limit changes have `handled: true, changed: false` with a reason.
Known operations are `mute`, `solo`, `reverse`, `fade`, `pitch-step`, `pitch-reset`,
`speed`, `multiply`, `divide`, `undo-length`, `peel`, `restore-peel`, `clear`,
`undo`, `redo`. Transform helpers do not enter modes or mutate their selections.

Host-owned requirements: `stageTransport.command('Start / Stop all')`,
`stageTransport.command('Clear all')` with grouped history, and session
previous/next/save with foot-operable refusal/confirmation. Selecting a catalogue
entry alone does not prove those callbacks. These integrations and the main HTML
belong to the coordinator.

## Production integration plan

1. Define typed `ControlTarget` and `PerformanceAction` values in the controller
   repository. Use stable track IDs, explicit selected/all scopes and musical
   units. Presentation dispatches through Bloc/repository; it must not import
   MIDI clients or native audio clients. Keep source configuration global and
   musical target values session-owned. Preserve device identity across reconnect.
2. Implement a source lifecycle that normalizes MIDI Note/CC/Program and physical
   contacts into press/release/value events. Persist global enable and channel
   policy, validate overlapping bindings atomically, aggregate Omni contacts and
   release held targets on disable, source loss and rebinding. Test repeated CC,
   Note Off, simultaneous channels, reconnect and save failure. Do not persist a
   temporary held value as the resting parameter state.
3. Route all touch, built-in, external and MIDI actions to one command handler.
   Share capture guards, scheduling, transport selection, solo set and grouped
   recovery. Direct commands must not change the current performance mode.
   Transformation history must become one coherent audio edit history before
   claiming general Undo across recording, Peel, Clear, length and Bounce.
4. Add native per-track decay, pan, solo projection, fades and backing/click mix
   as required. Use immutable command payloads or the existing real-time-safe
   command seam; no allocation, locks, blocking I/O or file operations in the
   callback. Implement DSP before claiming the browser's symbolic edits are
   audible. Verify all affected C/FFI symbols and generated bindings.
5. Apply settings and mappings on session recall in one validated transaction.
   Device-owned MIDI/external assignment configuration remains on the appliance.
   Round-trip all new target values and handle absent FX targets explicitly.
6. Validate native/controller failure paths and Dart analyze/Bloc lint/coverage;
   then test physical MIDI DIN/USB, exact-device reconnect, multiple channels,
   expression calibration, source removal during held FX, both pedal banks and
   both displays on the appliance. Listening and timing tests remain separate
   from the prototype's browser assertions.

## Verification

`node docs/design/verify_mapping_parity.cjs` passes seven behavior contracts:
64 reference dispatch paths, fixed/selected/all targeting, typed units and
inheritance, atomic transform guards, exact-device Learn/Omni conflicts,
global enable, release cleanup and inverted pickup. Browser integration results
are appended after the coordinator installs the main HTML bridge.

## Reference row disposition

Evidence: supplied User Guide 1.0.0 printed pages 47–48 and the recheck
`midi-controls.csv`. This table records product equivalence, not fixed MIDI
wire-number compatibility. The guide's CC3 range 0–60 conflicts with its actions
above 60; Segno's Learn system does not implement that contradictory table as a
reserved protocol. Source FX scale ambiguities belong to the FX descriptor record.

| Variable CC | Reference | Segno disposition |
|---|---|---|
| 3 | Pedal Actions | Equivalent direct command catalogue via Learn; reserved CC3 value dispatch is an accepted protocol difference. |
| 7 | Main Level | Equivalent existing input/output/track mix target via exact-device Learn. |
| 9 | Phones Level | Blocked on appliance Phones disposition; generic output gain does not prove independent Phones control. |
| 14 | Track 1 Volume | Equivalent existing input/output/track mix target via exact-device Learn. |
| 15 | Track 2 Volume | Equivalent existing input/output/track mix target via exact-device Learn. |
| 20 | Track 3 Volume | Equivalent existing input/output/track mix target via exact-device Learn. |
| 21 | Track 4 Volume | Equivalent existing input/output/track mix target via exact-device Learn. |
| 22 | Track 1 Pan | Equivalent existing input/output/track mix target via exact-device Learn. |
| 23 | Track 2 Pan | Equivalent existing input/output/track mix target via exact-device Learn. |
| 24 | Track 3 Pan | Equivalent existing input/output/track mix target via exact-device Learn. |
| 25 | Track 4 Pan | Equivalent existing input/output/track mix target via exact-device Learn. |
| 26 | Backing Track Volume | Equivalent typed Backing Volume target. |
| 27 | Backing Track Pan | Equivalent typed Backing Pan target. |
| 28 | Click Track Volume | Equivalent typed Click Volume target. |
| 29 | Click Track Pan | Equivalent typed Click Pan target. |
| 85 | Output 1 Volume | Equivalent existing input/output/track mix target via exact-device Learn. |
| 86 | Output 2 Volume | Equivalent existing input/output/track mix target via exact-device Learn. |
| 87 | Output 3 Volume | Equivalent existing input/output/track mix target via exact-device Learn. |
| 88 | Output 4 Volume | Equivalent existing input/output/track mix target via exact-device Learn. |
| 89 | Input 1 Pan | Equivalent existing input/output/track mix target via exact-device Learn. |
| 90 | Input 2 Pan | Equivalent existing input/output/track mix target via exact-device Learn. |
| 91 | Input 3 Pan | Equivalent existing input/output/track mix target via exact-device Learn. |
| 92 | Input 4 Pan | Equivalent existing input/output/track mix target via exact-device Learn. |
| 93 | Expression Pedal | Accepted difference: MIDI controls destinations directly, including multiple ranges, rather than forwarding to an expression source. |
| 94 | Fade Rate | Equivalent default Fade duration, plus per-track overrides; Segno seconds replace the undocumented source CC scale. |
| 95 | Track 1 Feedback (Decay) | Equivalent Track 1 Overdub decay; reverse endpoints to translate feedback into accepted inverse decay vocabulary. |
| 96 | Track 2 Feedback (Decay) | Equivalent Track 2 Overdub decay; reverse endpoints to translate feedback into accepted inverse decay vocabulary. |
| 97 | Track 3 Feedback (Decay) | Equivalent Track 3 Overdub decay; reverse endpoints to translate feedback into accepted inverse decay vocabulary. |
| 98 | Track 4 Feedback (Decay) | Equivalent Track 4 Overdub decay; reverse endpoints to translate feedback into accepted inverse decay vocabulary. |

| Action data/note | Reference | Segno direct choice / accepted difference |
|---|---|---|
| 0 | Start/Stop/All | Start / Stop all (`command:start-stop-all`) |
| 1 | FX 1 Toggle | FX A1 (`fx:0`) |
| 2 | FX 2 Toggle | FX A2 (`fx:1`) |
| 3 | FX 3 Toggle | FX A3 (`fx:2`) |
| 4 | FX 4 Toggle | FX A4 (`fx:3`) |
| 6 | Tap Tempo | Tap tempo (`command:tap-tempo`) |
| 15 | All Tracks Half Length | All tracks · Keep first half (`direct:divide:all:first`) |
| 16 | All Tracks Double Length | All tracks · Double length (`direct:multiply:all`) |
| 17 | All Tracks Half Speed | Half speed (`direct:speed:0.5`) |
| 18 | All Tracks Double Speed | Double speed (`direct:speed:2`) |
| 19 | Mute Track 1 | Track 1 · Mute (`direct:mute:0`) |
| 20 | Mute Track 2 | Track 2 · Mute (`direct:mute:1`) |
| 21 | Mute Track 3 | Track 3 · Mute (`direct:mute:2`) |
| 22 | Mute Track 4 | Track 4 · Mute (`direct:mute:3`) |
| 23 | Mute All Tracks | All tracks · Mute (`direct:mute:all`) |
| 24 | Clear All Tracks | Clear all tracks (`command:clear-all`) |
| 25 | Track 1 Reverse | Track 1 · Reverse (`direct:reverse:0`) |
| 26 | Track 2 Reverse | Track 2 · Reverse (`direct:reverse:1`) |
| 27 | Track 3 Reverse | Track 3 · Reverse (`direct:reverse:2`) |
| 28 | Track 4 Reverse | Track 4 · Reverse (`direct:reverse:3`) |
| 29 | All Tracks Reverse | All tracks · Reverse (`direct:reverse:all`) |
| 30 | Track 1 Fade | Track 1 · Fade (`direct:fade:0`) |
| 31 | Track 2 Fade | Track 2 · Fade (`direct:fade:1`) |
| 32 | Track 3 Fade | Track 3 · Fade (`direct:fade:2`) |
| 33 | Track 4 Fade | Track 4 · Fade (`direct:fade:3`) |
| 34 | All Tracks Fade | All tracks · Fade (`direct:fade:all`) |
| 35 | Track 1 Half-Step Up | Track 1 · Pitch +1 semitone (`direct:pitch-step:0:1`) |
| 36 | Track 2 Half-Step Up | Track 2 · Pitch +1 semitone (`direct:pitch-step:1:1`) |
| 37 | Track 3 Half-Step Up | Track 3 · Pitch +1 semitone (`direct:pitch-step:2:1`) |
| 38 | Track 4 Half-Step Up | Track 4 · Pitch +1 semitone (`direct:pitch-step:3:1`) |
| 39 | Track 1 Half-Step Down | Track 1 · Pitch −1 semitone (`direct:pitch-step:0:-1`) |
| 40 | Track 2 Half-Step Down | Track 2 · Pitch −1 semitone (`direct:pitch-step:1:-1`) |
| 41 | Track 3 Half-Step Down | Track 3 · Pitch −1 semitone (`direct:pitch-step:2:-1`) |
| 42 | Track 4 Half-Step Down | Track 4 · Pitch −1 semitone (`direct:pitch-step:3:-1`) |
| 43 | All Tracks Half-Step Up | All tracks · Pitch +1 semitone (`direct:pitch-step:all:1`) |
| 44 | All Tracks Half-Step Down | All tracks · Pitch −1 semitone (`direct:pitch-step:all:-1`) |
| 49 | Track 1 Clear | Track 1 · Clear (`direct:clear:0`) |
| 50 | Track 2 Clear | Track 2 · Clear (`direct:clear:1`) |
| 51 | Track 3 Clear | Track 3 · Clear (`direct:clear:2`) |
| 52 | Track 4 Clear | Track 4 · Clear (`direct:clear:3`) |
| 53 | Track 1 Peel | Track 1 · Peel (`direct:peel:0`) |
| 54 | Track 2 Peel | Track 2 · Peel (`direct:peel:1`) |
| 55 | Track 3 Peel | Track 3 · Peel (`direct:peel:2`) |
| 56 | Track 4 Peel | Track 4 · Peel (`direct:peel:3`) |
| 57 | B. Track Rewind | Rewind backing (`backing:rewind`) |
| 58 | B. Track Stop | Stop backing (`backing:stop`) |
| 59 | B. Track Play/Pause | Play / Pause backing (`backing:play`) |
| 60 | B. Track Fast Forward | Fast forward backing (`backing:forward`) |
| 63 | B. Track Prev Track | Previous backing track (`backing:previous`) |
| 64 | B. Track Next Track | Next backing track (`backing:next`) |
| 65 | Load Previous Loop | Load previous session (`session:previous`) |
| 66 | Load Next Loop | Load next session (`session:next`) |
| 68 | Solo Track 1 | Track 1 · Solo (`direct:solo:0`) |
| 69 | Solo Track 2 | Track 2 · Solo (`direct:solo:1`) |
| 70 | Solo Track 3 | Track 3 · Solo (`direct:solo:2`) |
| 71 | Solo Track 4 | Track 4 · Solo (`direct:solo:3`) |
| 72 | Select Track 1 (Global FS1) | Track 1 pedal; separate Select track command performs selection only. (`track:0`) |
| 73 | Select Track 2 (Global FS2) | Track 2 pedal; separate Select track command performs selection only. (`track:1`) |
| 74 | Select Track 3 (Global FS3) | Track 3 pedal; separate Select track command performs selection only. (`track:2`) |
| 75 | Select Track 4 (Global FS4) | Track 4 pedal; separate Select track command performs selection only. (`track:3`) |
| 76 | Rec/Dub/Play (Global FS5) | Record / Play (`command:record-play`) |
| 77 | Stop All (Global FS6) | Stop (`command:stop`) |
| 78 | Mode (Global FS7) | Mute mode entry. Accepted Segno Mode Press Mute / Hold Custom replaces physical reference emulation. (`mode:mute`) |
| 79 | Function (Global FS8) | Custom mode entry. Accepted Segno Mode Press Mute / Hold Custom replaces physical reference emulation. (`mode:custom`) |

All 64 action rows have explicit dispatch destinations. Twenty-eight variable rows have equivalent controls or accepted differences. Independent Phones is the one variable row that still requires the appliance hardware disposition; it must not be marked closed solely by this mapping implementation.

## Integrated validation, 2026-09-08

The coordinator's main HTML bridge is installed. The new browser suite
`verify_mapping_parity_browser.cjs` passed in Chrome and Firefox with no page
errors. It verifies exact-device Learn, Omni conflicts, global enable, typed
mix/loop targets, mute/solo/reverse/pitch/length/Peel/speed/fade dispatch,
selection versus Track-pedal transport, one-Undo grouped Clear-all recovery,
Custom and external assignment execution and expression destination access.

Custom's hardcoded unimplemented Multi/Song/Sync/Band shortcuts are removed.
Its grouped catalogue shares the completed direct commands and retains the
accepted defaults. Pass `assignedAction: dispatchSwitch` to the performance
constructor. Assignment contact release follows the built-in gesture lifecycle;
Mode remains the fixed foot-operated Exit.

The existing `verify_midi_controls.cjs` also passed in both browsers: pickup,
multiple targets, momentary/toggle/Program, conflicts, cancellation, encoder,
persistence, held-value serialization and storage-failure recovery. Fresh browser
contexts and private browser storage preserve the user's current prototype.
The generated picker screenshots in `mapping-parity-previews/` were inspected;
External category changes now reveal and focus the first command instead of
retaining a prior category's scroll position.


## Shared audio edit correction and final host contract

The September 8 state audit exposed disconnected recording, length, Peel and
Bounce histories. The corrected prototype now stores one chronological journal
in `rig.editHistory`, with per-track Undo/Redo and common numeric IDs for grouped
edits. `stage-transport-study.js` owns capture, partial-pass cancellation, Clear,
grouped Clear all, length, Peel, Bounce and Import recovery. No history is invented
from the layers visible when a session loads.

Length and Peel recovery buttons act only when that kind of edit is next. They
cannot skip newer recorded-content edits. General Undo always follows the same
sequence regardless of function or bank. Bounce and Clear all require their entry
to be next on every affected track. A new edit invalidates the associated Redo
branch; faders, FX, selection, direction and pitch do not add content history.
Recovery restores only fields the operation changed, preserving later unrelated
mix/FX edits. The source file stays managed by Library when an import is undone.

Fractional imported durations use `durationBeats`; Multiply/Divide keep symbolic
retained/repeated regions without rounding audio to an integer array. Bounce uses
rational LCM of stored decimal beat values and refuses results above 1024 beats.
The one-beat minimum for Divide remains. These are silent descriptors, not DSP.

The final main HTML integration is applied by the coordinator:

```js
editState: {
  read: bounceTrack,
  write: applyBounceTracks,
  readHistory: () => rig.editHistory,
  writeHistory: value => { rig.editHistory = value; },
}
```

`bounceTrack` supplies the canonical `parts`, `length`, `layers`, `playing`,
`muted`, `pitch`, `reverse`, `mix`, `fade`, `fx`, `recipe` and `imported` state.
Empty tracks have zero duration and an empty layer list. `applyBounceTracks`
compares each canonical field and writes only changed fields; unchanged racks
retain their order. `imported` reads/sets/deletes `audioLibrary.trackImports[i]`,
so Undo/Clear actually releases Library's destination occupancy.

The unused transport `write`, length/Peel `write`, Bounce `commit/readHistory`,
`trackLength.history`, `trackLayers.removed` and `bounceHistory` paths are removed
from the active integration. Helpers receive `history: trackTransport` internally.
The stage exposes `edit(changes,label,metadata)`, `editPart(changes,key,label)`,
`recover(tracks,direction,labels)`, `canRecover`, `nextEdit`, and `events(label)`.
`edit` and `recover` return success booleans. Group recovery compares persisted IDs,
so JSON cloning does not break atomicity.

Import captures `beforeEdit` before changing the track, calls
`recordEdit(target,beforeEdit,'Import')`, then saves once. Its returned rollback
function restores the journal if that save fails, alongside the host restoring
its previous rig/content/tempo. It does not reset another track's playhead.
Session capture includes `editHistory`; a new session explicitly clears it.
Transport `reset()` clears running timers/queues and reloads the current session's
journal on demand without fabricating or deleting its Redo branch.

Song now plays one section. Band retains its primary bed and at most one other
section. Start/Stop all and MIDI Start/Continue obey those rules. Multi selected
resizes are refused if unequal lengths would result; compatible multi-track
transforms commit together. Sync/Band conversion and edits preserve audio lengths
and require the currently accepted integer multiple/division relationship.

The unresolved automatic-close policy for a new Sync/Band capture against an
existing primary remains explicit: choose a compatible fixed record length first.
An early REC/PLAY press waits for that boundary. Stop at an incompatible partial
boundary is refused with a continue/Undo notice. Undo can preserve that partial
capture for later recovery, but Redo cannot introduce an incompatible duration.
These restrictions and first-take inference/device-clock work remain in the audio
plan. Clear all still refuses active or queued capture; treatment of an in-flight
take is an accepted restoration requirement with an unresolved commit boundary.
No audio-engine or hardware readiness is claimed.

Validation after this correction:

- `verify_audio_state_reconciliation.cjs`: 10 behavioral contracts, including
  chronological interleaving, partial take/decay recovery, group ordering, JSON
  recall, Import rollback, fractional duration and mode guards.
- `verify_stage_transport.cjs`: existing capture/quantize/count-in/decay/Once/
  grouped recovery checks pass with the canonical adapter. General clock tests
  use Free; mode-specific acceptance is separate.
- `verify_mapping_parity.cjs`: seven mapping contracts pass.
- `verify_mapping_parity_browser.cjs`: Chrome and Firefox pass integrated MIDI,
  expression, Custom and external mappings with the shared history.
- `verify_audio_state_browser.cjs`: Chrome and Firefox cover the real host command
  bridge, history across reload, Import atomic storage failure, exact descriptor
  recovery, group Clear and Multi compatibility.

Encoder turns now honor descriptor `encoderStep`, while sliders retain `step`.
MIDI structural/navigation actions finish endpoint editing before controls are
removed or replaced; stale endpoint events cannot dereference a removed mapping.
The media agent independently rechecks that lifecycle and the older performance
journeys against the final integration.

The production work is specified in
[`2026-09-08-audio-state-parity-plan.md`](../plan/2026-09-08-audio-state-parity-plan.md):
canonical session transaction, native content revisions, mode clocks, buses/tails,
transforms, rendering/media, controller dispatch, and measurable device gates.
