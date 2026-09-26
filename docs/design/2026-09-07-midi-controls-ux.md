# MIDI controls and Learn

Status: reviewed positively by the owner on 7 September 2026. This is an
interactive UX reference, not production MIDI I/O or audio-engine delivery.
Part of the existing appliance redesign programme.

## Journey

Settings → MIDI controls → choose controller → Add mapping → move the physical
control → Add control → choose a destination and parameter, or a performance
action → Save. Each mapping has one source message and multiple targets.

The device remains visible while editing. Learn records the selected device,
message type, channel and number. It ignores unsupported messages and note-off
while learning. An existing binding leads to **Edit existing mapping**, preserving
its targets. Cancel and Back discard the draft. Save is disabled until the source
and at least one target are present. A failed save preserves the draft and the
previous saved mapping.

The source list distinguishes USB and DIN and keeps disconnected devices visible.
Mappings can be disabled without deleting them. Missing effect targets are shown
as missing controls; a removed target never silently binds to a different effect.

## Control behavior

| Source | Mapping behavior |
|---|---|
| Absolute CC knob/fader | From and To ranges per target. Ranges may run in either direction. Values take over when the controller reaches or crosses the current value, avoiding an initial jump. |
| Note or CC button | Momentary or Toggle. Each parameter has Released/Held or Off/On values; each action can trigger on Pressed or Released. |
| Program change | Run assigned actions and set assigned parameter values on each message. No release is implied. |

Targets reuse the expression-control catalogue and shared performance actions.
The prototype includes mixer volume/pan/balance, exposed FX parameters, selection
of an absolute track, bank change and the available performance commands. Action
names and parameter context identify the target without requiring the user to
interpret raw internal keys.

Touch uses the established sliders. Double-tap restores an endpoint to its default
range boundary. Encoder press starts editing, turn adjusts, press finishes;
Escape restores the value from before that encoder edit. All mapping edits remain
pending until Save.

Learn and editing pause dispatch from the controller being configured. Entering
an edit releases its active momentary parameter changes. Disabling, deleting or
disconnecting a mapping also releases momentary changes. Disconnect does not
synthesize a performance action. Reconnecting retains assignments, clears contact
state, and waits for new input; continuous controls need to take over again.
Toggle values remain at their last value, but the controller latch restarts Off
when its runtime is reset. Temporary held values are stored as Released, so a
reload or session restore cannot strand a momentary effect value.

## References and boundary

The extracted Looper X source places MIDI in Global Settings. Its internal
control-surface bindings are not a verified external MIDI implementation; see
[architecture evidence](../research/sheeran-looper-x-1.0.2/architecture.md)
and [global-settings evidence](../research/sheeran-looper-x-1.0.2/evidence.md#e06).
The Learn flow here is a Segno design, not a claim that Looper X has the same UI.

The next design slice is external synchronization: clock source, clock send/follow,
transport follow and clock loss. Relative encoders, high-resolution MIDI,
enumerated targets, complete mapping coverage and real port discovery remain
implementation/design gaps. This proposal does not substitute browser simulation
for Linux device validation.

## Review and verification

- [Interactive simulator](midi-controls-preview.html): an example Delay Mix
  mapping, a CC knob, Note button, Program change and connection toggle.
- [Main prototype](fx-ux-prototype.html?review=midi-list).
- [Browser/Pen comparison](midi-controls-previews/index.html), section 26 in Pen.
- `verify_midi_controls.cjs`: Chrome and Firefox; Learn filtering and timeout,
  multiple targets, pickup, button states, Program changes, duplicate binding,
  save/cancel, encoder cancel, slider reset, reconnect, durable mappings,
  released-state persistence and failed-save retention.
- The existing pedal-performance and two-display recording journey are regression
  checks for the shared action dispatcher and session lifecycle.
