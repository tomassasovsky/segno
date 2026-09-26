# Close the eight instrument UX findings

The owner authorized the complete prototype pass. Production Linux hosting and
physical-device validation remain outside this design task. The source is the
eight-item instrument UX review; this plan does not change accepted Tracks,
FX, ten-pedal layout or normal recording behavior.

## Implementation order

1. Add a small instrument catalogue and runtime, separate from the page. Notes,
   sustain and audio paths belong to a stable instrument identity. Selection
   only chooses what is edited. Initial keyboard and drum examples use separate
   MIDI channels; new instruments start without an enabled controller binding.
2. Use the shared MIDI port inventory and receiver. Add All/specific channel,
   note-range split, activity, offline/reconnect feedback, pitch bend, modulation
   and pressure. Disconnect releases only that device's notes. No automatic
   replay on reconnect. Overlapping routes explicitly show layered instruments.
3. Expose instrument parameters and note/chord/sustain trigger targets in the
   existing MIDI, external pedal and built-in custom pedal assignment pickers.
   Instruments links to those editors and shows saved bindings; remove the
   duplicate CTRL 1 foot-assignment editor. Existing press/hold/latch ownership
   and release behavior remain authoritative.
4. Keep computer mappings separate. Show/edit base shortcuts, let users disable
   or remove them, and let remaps receive target notes directly from MIDI or
   choose notes by name/number, with the touch keyboard as an alternative.
5. Add compact state feedback: input activity, held/sustained notes, controller
   disabled/disconnected, live monitoring off, mixer mute and no output route.
   Leave recording in Tracks; add a direct link to its existing input setup.
6. Give the catalogue a defined synthesized target sound set, family-specific
   controls and artwork, audition/apply/cancel, and unavailable-pack repair via
   install/retry or choose another sound. Recovery and storage failures preserve
   the saved patch. Audition is temporary and excluded from session persistence.
7. Exercise the complete journeys in Chrome/Firefox, update Pen from browser
   geometry, save and verify the file. Run five independent quality reviews and
   resolve findings before reporting completion.

Files: instrument runtime/catalogue modules; virtual-instruments.js/.css;
fx-ux-prototype.html; shared MIDI, pedal and parameter catalogues; existing
instrument checks plus a complete-controller journey suite. Add focused runtime
tests for simultaneous sources and lifecycle behavior.

## Success Criteria

```success-criteria
GOAL: Close all eight instrument UX review findings in the shared HTML prototype.

SUCCESS CRITERIA:
- Keyboard and pads play fixed instruments across selection/navigation; sustain, disconnect and panic release the correct voices | verify: node docs/design/verify_instrument_runtime.cjs
- MIDI, expression and foot assignments use the shared saved targets and trigger instruments through normal dispatch | verify: node docs/design/verify_instrument_complete_journeys.cjs
- Source-specific mappings, whole MIDI range, target-note learn, audition/cancel and unavailable-pack recovery survive save/recall and failed writes | verify: node docs/design/verify_instrument_complete_journeys.cjs
- Main Tracks recording and shared instrument input routes remain usable | verify: node docs/design/verify_virtual_instruments.cjs
- All revised Pen references match browser geometry, have readable text and are saved | verify: manual inspect the grouped instrument frames and verify the saved file changed

NON-GOALS:
- Native Linux instrument hosting, production sample content, physical audio/MIDI proof
- Changes to accepted Tracks, FX or ten-pedal layout

VERIFICATION COMMAND: node docs/design/verify_instrument_runtime.cjs && node docs/design/verify_instrument_complete_journeys.cjs && node docs/design/verify_virtual_instruments.cjs
```

Risks to verify: shared-controller overlaps, nested draft cancellation, restoring
sessions while notes are held, disappeared targets, pending audio starts,
short-press versus hold release, and audition leaking into saved sessions.

## Delivery

All seven implementation steps are complete at prototype level. The owner
accepted the revised instrument UX. Eight local suites pass, including six
browser suites in Chrome and Firefox; all five independent reviews are
consolidated with no unresolved actionable finding. The eight Pen screens
are aligned, marked accepted and saved with on-disk verification. Native
select/number field values were added to the geometry exporter after the
visual pass caught their omission. See the
[delivery manifest](../design/virtual-instrument-previews/verification.json)
and [consolidated review](../reviews/instrument-ux-closure/review.md).
