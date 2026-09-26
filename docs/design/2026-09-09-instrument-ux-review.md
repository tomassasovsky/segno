# Virtual instruments: closure of the complete journey review

September 9, 2026 · Issue 919 · Instrument UX accepted by the owner.
HTML prototype, not native appliance implementation.

The eight gaps found in the initial review are implemented in the main prototype.
Selection now edits an instrument; fixed controller routes decide what plays.
The separate instrument foot editor has been removed. Normal Tracks recording,
shared input FX, monitoring, output routes and session ownership are retained.

| Original finding | Implemented correction | Evidence |
| --- | --- | --- |
| Selection changed what played | Per-instrument voice ownership and audio buses; fixed routes, splits and layers; new inputs start with controllers disabled | Runtime, complete journeys |
| Duplicate foot setup | Notes/chords and sustain appear in built-in, external and MIDI action pickers; bindings and links are shown in Instruments | Shared contracts, hardware journeys |
| Placeholder MIDI connection | Shared port inventory, All/specific channel, note range, reconnect identity and independent device release | Complete journeys, runtime |
| Missing expressive/parameter path | Family parameters use shared expression/MIDI targets; incoming bend, modulation and channel pressure affect synthesis | Runtime, complete journeys |
| Incomplete playing feedback | Notes, sustain, controller state and monitoring/mute/output reasons appear beside the playing surface | Browser references, complete journeys |
| Inefficient remapping | Explicit editable base computer mappings; source Learn, target chord Learn, direct MIDI-note entry and optional touch keyboard | Note mappings, complete journeys |
| No audition before applying | Temporary candidate audition, Apply/Cancel, independent other instruments; preview excluded from saved definitions | Runtime, complete journeys |
| Undefined catalogue/recovery | Nineteen specified Segno synthesis patches in seven families, distinct artwork and meaningful family parameters; unavailable sound repair/retry/choose another | Runtime, complete journeys, Pen references |

## Interaction rules

- Example keys receive USB channel 1; example drums receive channel 10. These are
  prototype examples, not claimed defaults of a particular controller.
- MIDI notes retain incoming pitch and velocity. Explicit remaps add fixed
  source routes; the displayed touch-keyboard octave never constrains MIDI.
- Computer mappings are saved rows, including the default A–K layout. Removing
  a row removes that shortcut. Computer and MIDI editors remain separate.
- Sustain contributions are independent. Repeated strikes keep earlier sustained
  voices. A latched note can rearticulate while an earlier strike still rings.
- Held Press requires Hold=None. A Held MIDI action requires a momentary Note/CC
  source triggered on Press. Invalid pairs explain the conflict and cannot save.
- Removing or disabling a control retires its latch. Disconnect releases only
  that device; reconnect never replays old notes. Cut all sound releases every
  instrument. Selection and ordinary navigation preserve playing voices.
- Encoder sound drafts remain audible through unrelated MIDI renders; confirm
  saves and Escape restores. Switching editors discards an unfinished draft.
  Channel and note-range fields also support encoder editing.
- Missing current/default sounds offer repair immediately. Failed installation
  and failed state writes preserve the chosen sound and saved setup.

## Verification

Local checks: `verify_instrument_runtime.cjs`,
`verify_instrument_shared_controls.cjs`, `verify_instrument_complete_journeys.cjs`,
`verify_instrument_hardware_journeys.cjs`, `verify_virtual_instruments.cjs`,
`verify_instrument_note_mappings.cjs`, `verify_instrument_sustain.cjs`, and
`verify_instrument_management.cjs`. Browser suites run in Chrome and Firefox.

Independent architecture, test-quality, conventions, simplicity and readiness
reports are under `docs/reviews/instrument-ux-closure/`. The final verification
manifest records the current artifact hashes and Pen save evidence.

Native instrument hosting, physical MIDI/audio devices, sample-pack installation
and recording actual instrument audio on the appliance remain production work.
The browser uses audible Segno synthesis; audio routing and captured loop content
remain the existing simulated prototype model.

## Reference basis

[Ableton routing and I/O](https://www.ableton.com/en/manual/routing-and-i-o/)
provides established separation of note input and Remote controls.
[Novation Launchkey overview](https://userguides.novationmusic.com/hc/en-gb/articles/27613107564306-Launchkey-61-hardware-overview)
confirms keys, pads and other controls can coexist on one controller. No specific
Launchkey generation or device layout is assumed.
