# Audio routing and input setup

Input naming was accepted for now, followed by approval of input setup including
Pan, stereo Balance and recording trim on 2026-09-07. The surrounding routing
views remain the current proposal. This is a silent interaction prototype;
it does not process or measure audio.

## Paths

Settings → Audio routing provides four tasks:

- Input setup: choose a physical input, choose Separate mono or Stereo pair,
  adjust Pan/Balance and recording trim.
- Recording inputs: choose one of eight tracks, then the inputs it records.
- Output routing: choose a live input, recorded track, backing track or click,
  then the outputs that receive it.
- [Output setup](2026-09-07-output-setup-ux.md): the subsequent proposal for
  output level, Balance, Mute and Stereo/Mono.

Input names is a header action on Input setup and Recording inputs; the output
tabs provide Output names. Each numbered input jack
has a name editor with Save and Cancel, touch keyboard and encoder access.
Names are appliance aliases, survive reload and session changes, and appear in
Routing, FX, Mixer and expression destination labels. The underlying jack IDs,
routing choices and recorded audio are unchanged by a rename. An unsuccessful
write keeps the old name and the editable draft.

## Input setup

Adjacent physical inputs pair as 1/2, 3/4, and so on through 17/18. The lower-numbered
jack is Left; the other is Right. Both identities stay visible. Selecting either
member for recording selects both. Linking includes the partner wherever either
was selected; unlinking keeps both recording selections as separate mono inputs.
Existing recordings and FX chains are never rewritten. Pairing cannot change
while an affected track is armed, recording or overdubbing.

A mono input has Pan. A stereo pair has one shared Balance that attenuates one
side relative to the other, preserving its left/right identity. Unlinking restores
the former mono pan values. Input positioning affects the target live signal and
new recordings; existing loop playback retains its recorded image. Expression
position mappings share these values and are labelled Balance for linked inputs.
Per-jack live routing and FX destinations remain available; stereo capture does
not silently merge output sends or effect chains.

Recording trim is software gain on the capture branch, proposed from −24 to +12 dB
in half-decibel steps, with unity at 0 dB. Stereo members retain individual trim.
It changes new recorded audio, including what is committed after Pre processing;
it does not change Mixer live level or existing loops. This is distinct from an
audio interface's analog preamp. Source clipping must be corrected at the source
or preamp; decreasing software trim cannot repair it.

Pan/Balance and trim edit directly by touch. Encoder press enters adjustment,
turn adjusts, another press commits, and Back cancels. Double tap centres
Pan/Balance or resets trim to unity. UI meter samples and clipping examples are
simulated. Physical gain ranges, the pan law and actual meter taps require engine
and appliance validation.

Pairing, trim and position belong to the saved session setup and carry into New
Loop. Input names remain appliance-wide. Session recall restores routing and
recording choices with these input settings.

## Recording and output routing

Track input choices affect future captures; they do not reinterpret which inputs
are present in an existing recording. While a track captures, its source selection
is locked with a reason. Other tracks remain configurable. No selected input is
a valid explicit empty choice.

Live inputs, recorded tracks, backing and click each have independent output
selections: Main output (1–2), Monitor output (3–4), both or neither in this study.
These pairs are prototype examples, not a verified hardware output inventory.
A recording-only track route never implicitly becomes a live input route.

Hear live shares Off/Auto/On with FX. Auto follows armed or capturing tracks that
use the input. Muting that input in Mixer remains effective and is named in this
view. Output routing alone never starts playback or opens monitoring. No outputs
selected is explained directly. Settings persist atomically; failed storage writes
leave the previous setup active.

## Reference and verification

The extracted Looper X `InputSetup.qml`, `InputPair.qml` and `Input.qml` show
adjacent stereo pairs, both physical identities, independent input meters and a
shared pair-position control. [Research features](../research/sheeran-looper-x-1.0.2/features.md)
distinguishes source evidence from native-engine unknowns. Segno's eighteen-input
support, recording-trim scope and session/naming rules are explicit product choices.

Chrome and Firefox pass `verify_audio_routing.cjs`, `verify_input_names.cjs`,
`verify_input_setup.cjs` and the Mixer regression suite. Checks exercise routing,
Auto, locks, eighteen-input scrolling, rename cancellation and sharing, stereo
selection, Pan/Balance, touch reset, encoder commit/cancel, clipping, cold reload,
session recall and atomic write failures. Geometry checks cover all seventeen
browser views. [Browser and Pen gallery](audio-routing-previews/index.html).

The seventeen matching Pen screens are saved and exported at full size. Native
checks cover 624 text nodes and 1,375 elements with no alignment or containment
errors; all 22 current-UX sections remain separate without overlap. The gallery
manifest records the saved design hash and verification results.

Output setup follows this accepted input slice: output names, balance, level and
mute. That subsequent proposal is separate from this acceptance.
