# External pedals — target UX study

The main prototype now contains **Settings → Pedals → External pedals**.
Choose CTRL 1 or CTRL 2, then Expression, Single switch, or Dual switch.
This extends the accepted pedal layout A. It is a browser interaction study;
production controller, audio and physical-jack support are separate work.

## Accepted design

The owner approved and locked this flow after reviewing multi-control mapping,
individual knob values, and the removal of external button choices from FX
Activation. External pedals is the sole editor for external assignments.
Expression mapping retains the previously approved interaction.

## Owner decisions and visual revisions

- External pedals include expression pedals, single buttons and dual buttons.
- A dual pedal can put Tracks 5 and 6 directly underfoot while the built-in
  pedals remain on Bank A. Track assignments are absolute; changing the bank
  never retargets them.
- Expression pedals can drive several controls, each with independent heel and
  toe values. Fixed destinations are the initial behavior. Follow-selection
  requires an explicit future choice; it must never be implicit.
- The handmade expression SVG was rejected. The original Looper X image was
  then rejected for low resolution and visible Headrush branding. Neither is
  used in the current UI. All three external-pedal illustrations are generic,
  unbranded, high-resolution generated assets. They depict a pedal category,
  not a guaranteed physical product or the Segno faceplate.
- The dual pedal uses one shared enclosure illustration with a selectable area
  over each physical button. The hardware artwork stays still; selection and
  contact indicators are separate UI layers.

## Setup and expression behavior

Save commits both ports as one draft. Cancel restores the saved configuration.
Back leaves a subview first; leaving External pedals discards unsaved edits.
Unrelated FX saves never commit this draft. Selecting another type retains its
other assignments but only the saved active type receives events.

Expression setup offers a source-position readout and calibration beside a
list of controls. Add control chooses a destination, then a parameter. Current
destinations cover live inputs, individual recorded tracks and input parts,
the recorded mix, and output buses. Each assignment names its destination and
parameter. The selected row exposes Heel and Toe directly. Double tap resets
an endpoint; encoder editing supports finish and cancel. Multiple assignments
scroll with the centered, nonfocusable overflow indicator.

Calibration captures both physical ends and accepts reversed travel. The
prototype's minimum span is 10% of normalized raw travel. This threshold is a
study assumption, not a validated electrical requirement. Use calibration
stages the result; Save commits it. Unplugging during capture discards those
partial readings. Movement during calibration does not dispatch assignments.

Saved assignments drive the prototype's actual normalized FX parameter values
and simulated destination volume/pan values. Saving or connecting does not
jump to the current pedal position; subsequent movement applies the saved
range. Disconnect holds the last controlled value. Native physical units,
pickup/smoothing and multiple-controller arbitration still need specification.

Bindings use rack identity, module identity and parameter key. Reordering a
module keeps its assignment. A removed target remains visible as Unavailable,
with Change control and Remove; it cannot silently target a replacement.

## External switches

Each button has its own hardware type and assignments:

| Hardware | Controls | Event rule |
|---|---|---|
| Momentary | Press, Hold | With Hold assigned, a short release runs Press; reaching the hold threshold runs Hold once and consumes release. With no Hold, Press runs on contact closure. |
| Latching | On change | Each changed contact state triggers the selected action once. Duplicate states do nothing. There is no inferred hold duration. |

The prototype uses the same proposed 800 ms threshold as the performance study.
Pending gestures are cancelled on disconnect, focus loss and configuration
save. A contact already down must be released before accepting another press.
An active momentary FX gesture releases its original logical assignment even
if the bank or screen changes.

The action picker distinguishes entering FX mode from triggering one of the
eight FX assignments. It also offers Mute, Custom, Exit, Next bank, and fixed
Track 1–8. Its brief descriptions explain the action at selection time. The
current list deliberately contains only these defined functions; other
custom-pedal function contracts remain separate work.

| Assignment | Target contract | Browser study evidence |
|---|---|---|
| Track 1–8 | Send the normal track-pedal press to that absolute track ID, using the configured recording sequence and timing. Do not change bank or merely select a track. | Emits a fixed track-press intent in `rig.lastTrackPedalEvent`. Track transport/audio execution is not implemented by this study. |
| Mute / Custom / FX | Enter that foot-operated control mode. | Changes the same performance model used by Stage. |
| Exit | Restore normal track controls. | Returns the performance model to Tracks without resetting assignments. |
| Next bank | Toggle the built-in bank. | Changes the shared bank state; absolute track/FX bindings remain fixed. |
| FX A1–B4 | Trigger the named logical assignment, retaining its configured toggle/momentary rules. | Uses the main prototype's logical FX down/up path. A latching change is a pulse; it does not sustain a momentary target. |

An external pedal's contact light represents the received contact state. It is
separate from the selection outline and from the effect's toggle state. These
illustrated LEDs do not imply that an arbitrary third-party pedal's LEDs can
be driven by Segno.

## Direct FX state sources

Expression mapping remains unchanged after the owner's positive review.
External button actions and FX activation are separate consumers of the same
source; no external control must borrow an A1–B4 assignment. The first proposal
put external buttons in the FX Activation picker; the owner rejected that
placement. That picker now contains only the eight built-in FX assignments.
Editing an existing external activation opens its selected button and control
in External pedals.

Choose a physical button, then Controls. Add control chooses a destination and
an effect activation or individual parameter. Each button can have any number
of mapped controls. Select a row to edit its behavior; extra rows scroll with
a centered, nonfocusable indicator. Actions retains Press/Hold and hardware
type separately. A rack activation binds to the source and one condition:

- Momentary On/Off is its logical toggle state; Held/Released is current contact.
  With no Hold action, closure toggles On/Off immediately. With a Hold action,
  only a completed short Press toggles it; executing Hold does not also toggle.
- Latching On/Off follows its contact state. Held/Released is unavailable because
  the physical contact does not report foot-down duration.
- One button can activate any number of racks, including opposing conditions,
  while its Press or Hold can also target a track or mode.
- On/Off persists in the rig independently of the eight built-in FX switches.
  Held is transient and ends on release, disconnect or cancelled input.
- A removed second button or a jack changed to Expression makes its FX binding
  unavailable; an inverse Off/Released condition must not turn a missing source
  into an active effect. The binding remains stored for correction.

[Review multiple external controls](fx-ux-prototype.html?review=external-controls&simulate=1).
Browser checks exercise all four conditions, apply a different external source,
verify disconnect release, and reload the persisted source and toggle state.
Physical switch hit targets use measured source-image centers and matching image
aspect ratios. Button labels sit directly below each switch, with the excess
20-pixel gap removed in response to review.

## Knob values from buttons

The same control picker includes the normalized FX parameters exposed to
expression pedals, plus destination volume and pan. A selected parameter has
two direct value sliders:

- On / Off: each completed press toggles between the two chosen values.
- Held / Released: foot down applies Held; release applies Released. It does
  not wait for the long-Hold action threshold. Latching hardware cannot offer
  this behavior because it does not report foot-down duration.

For example, Delay Mix can be 65% On and 20% Off. The Held / Released choice
uses those same two stored values for a temporary change. Released is an
explicit chosen value, not a snapshot of whatever another controller last set.
A button can change several knobs and activate several effects in one gesture.
Expression and button events use the same parameter targets; the most recent
received event wins in this browser study. Production controller arbitration
remains to be specified.

Sliders use the approved controls, including encoder adjustment/cancel and
reset to the parameter default on double tap. Initial endpoints both use the
current parameter value, so adding a mapping does not invent a sound change.
Editing or saving endpoints does not dispatch a value. Saved bindings react to
the next relevant state transition; they write the actual prototype parameter.
Disconnect, cancelled input, or focus loss ends Held and applies Released.
Missing parameters are shown as Unavailable and skipped during dispatch.

[Review button parameter values](fx-ux-prototype.html?review=external-controls-knob&simulate=1).

FX activation rules remain owned by the rack. The external editor stages only
changed rules until Save; it does not keep a competing activation store. Numeric
bindings live with their external button alongside its action assignments.
Both kinds share the External pedals Save/Cancel transaction across both ports.
Removing an activation binding returns that rack to Always on without changing
its bypass flag. Removing a numeric binding stops future updates and leaves the
last parameter value intact. Assignment changes made here do not alter saved
expression ranges or the eight built-in FX assignments.

## Hardware and implementation follow-ups

The console source in `hardware/kicad/console_board.py` describes each CTRL jack
as an expression-or-single-switch connection: tip is sensed; ring supplies a
reference through a resistor. It does not independently sense a conventional
dual pedal's second contact. Supporting a dual TRS pedal therefore needs a
hardware/firmware design and bench validation. The target UI remains available.
No board, firmware or production application code changed in this study.

Also outstanding: jack-type detection and manual override behavior in the real
device, switch polarity, electrical calibration and noise handling, MIDI
controller discovery/learn, session-versus-rig ownership, optional
follow-selection, transport dispatch, and physical validation on both displays.
The roles of the 7-inch and 15.6-inch displays are still undecided.

## Review and verification

- [Expression range](fx-ux-prototype.html?review=expression&simulate=1)
- [Multiple controls](fx-ux-prototype.html?review=external-controls&simulate=1)
- [Button parameter values](fx-ux-prototype.html?review=external-controls-knob&simulate=1)
- [Single switch](fx-ux-prototype.html?review=external-single&simulate=1)
- [Dual switch](fx-ux-prototype.html?review=external-dual&simulate=1)
- [Tracks 5 and 6](fx-ux-prototype.html?review=external-tracks&simulate=1)
- [Latching switch](fx-ux-prototype.html?review=external-latching&simulate=1)
- [Screen gallery](expression-previews/index.html)

`verify_expression_journeys.cjs` covers range inversion, calibration, fan-out,
save/cancel, encoder and double-tap behavior, independent ports, disconnect,
module identity, missing targets and scrolling. `verify_external_switches.cjs`
covers type selection, per-button and per-port isolation, exclusive Press/Hold,
latching edges, cancellation, persistence, encoder and absolute track targets
across bank changes. `verify_external_controls.cjs` covers multi-control
activation and parameter values, source ownership, Save/Cancel isolation,
encoder editing, release/disconnect behavior and persistence. All three run in
Chrome and Firefox. These are author-side
browser checks, not appliance or audio-engine validation.

Twelve study screens are in `segno-ui.pen`; the four existing pedal-setup screens
also include the External pedals entry. Native text fitting is checked against
the browser rectangles. Asset prompts and tool provenance are recorded in
[external-pedal-art/generation.json](external-pedal-art/generation.json).
