# Output setup proposal

The owner accepted input setup and asked to continue to the next flow. Output
setup is the subsequent proposal, not yet accepted. It lives in Settings → Audio
routing → Output setup, with Output names in the header. The same header action
is available while choosing output routes.

## Controls

Main output (physical outputs 1–2) and Monitor output (3–4) are the two sample
stereo destinations. Each has independent level, balance, stereo/mono and mute.
Names are appliance aliases; renaming preserves routing and FX identity, and the
name appears in Routing, FX and expression destination labels. Save/Cancel and
the existing touch/encoder keyboard apply. Aliases survive session recall.

Level runs from silence to unity (0–100%) in this proposal. Mute does not change
the stored level; unmuting restores it. Balance favours Left or Right without
collapsing stereo. Mono proposes an attenuated L+R sum sent to both jacks; Balance
is disabled and shown centred. Returning to Stereo restores the prior balance.
The native mix law and real hardware channel inventory remain implementation work.

Level and balance use direct sliders, double tap for unity/centre, and encoder
press/turn/press with Back to cancel. Output mute is explicitly labelled and has
its own selected state. Output level and balance share the parameter values used
by expression and external-button value mappings. Output mute and format are not
yet offered by those mapping pickers.

Output setup applies to all signals routed to that destination, after its output
FX. It does not rewrite recordings, alter source routing, start/stop tracks or
change the independent live-input Mixer levels. Settings other than physical
aliases belong to the session and carry into New Loop.

## Performance capture boundary — proposal

Capture the performance mix after output FX but before final destination level,
balance/mono and mute, so adjusting the PA or monitor during a performance does
not alter or interrupt the saved performance. This tap point is a new proposal to
review, not a claim about the Looper X engine or a previously approved requirement.
The current silent prototype does not process audio at either tap.

## Verification and reference

`verify_output_setup.cjs` passes in Chrome and Firefox for independent controls,
mute without lost level, retained balance across Mono, touch resets, encoder
commit/cancel, shared output names, cold reload, session recall and atomic write
failures. All six browser layouts are checked. Input routing/setup, Mixer and
expression regression suites also pass. [Browser/native gallery](output-setup-previews/index.html).

The six matching Pen screens are saved and exported at full size. Native checks
cover 165 text nodes and 579 elements without alignment or containment errors.
The gallery manifest records the saved design hash and verification results.

Looper X's extracted `OutputSetup.qml` and `Output.qml` expose physical outputs
with their own level controls. Segno's named stereo destinations, explicit mute,
software mono output and capture boundary are design proposals for this product.
Meters are fixed review samples; no live audio metering, DSP or device validation
is implied by these browser or Pen checks.
