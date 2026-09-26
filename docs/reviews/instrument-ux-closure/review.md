# Instrument UX closure: consolidated review

September 9, 2026 · Issue 919 · Local HTML prototype delivery.

All eight original UX findings are implemented. Five independent roles reviewed
the scoped working files. No unresolved actionable finding remains. This is not
a production or merge approval; no branch, commit, PR or remote publication was
part of this task. The final verification manifest records source and Pen hashes.

## Scope and evidence

Catalogue, runtime, instrument UI and its host integration; instrument additions
to the shared MIDI, built-in pedal, external-switch, expression and dispatch
modules; eight instrument verification suites. Unrelated dirty files were excluded.
Dart/native checks are inapplicable to this HTML/JavaScript-only implementation.
Browser contacts are simulated; they do not prove physical hardware behavior.

| Role | Result | Evidence |
| --- | --- | --- |
| Architecture | Clean after corrections | [Report](raw/architecture.md) |
| Test quality | Clean; preserved a missing host-wiring browser check | [Report](raw/test-quality.md) |
| Conventions | Clean after field navigation and feedback fixes | [Report](raw/conventions.md) |
| Readiness | Syntax, whitespace, assets and browser journeys pass | [Report](raw/readiness.md) |
| Simplicity | Two suggestions applied by coordinator | [Report](raw/simplicity.md) |

## Finding dispositions

| ID | Finding | Final disposition |
| --- | --- | --- |
| INST-01 | Held Press could start only at release when paired with Hold | Fixed: incompatible pairs disabled and Save guarded in shared editors |
| INST-02 | Encoder draft lost on incoming MIDI and never reached synthesis | Fixed: temporary audible model overlay, preserved through renders; Cancel restores |
| INST-03 | Selecting another sound during an encoder edit could crash | Fixed: navigation cancels the draft before changing the selected surface |
| INST-04 | A sustained voice prevented a latched note from retriggering | Fixed: latch tests active gates separately from sustained voices |
| INST-05 | Held MIDI target on Released or Program Change produced no note | Fixed: momentary Note/CC plus Press required, with visible explanation |
| INST-06 | Saved/default unavailable sound did not initially offer repair | Fixed: availability checked when opening Add or Sound and before playback |
| INST-07 | MIDI channel/range fields were missing encoder traversal/editing | Fixed: focus, turn, confirm and cancel cover those fields |
| INST-08 | Direct note entry displayed 60 but had an undefined encoder draft | Fixed: draft initialized in both note-editing paths |
| INST-09 | Audio startup failure was invisible | Fixed: feedback explains the failure; successful retry clears it |
| INST-10 | Numeric blur replaced the dialog and swallowed Add/Done clicks | Fixed: numeric updates preserve the DOM; one-click paths pass both browsers |
| INST-11 | MIDI byte decoding duplicated the host boundary | Removed: host normalizes bytes once; instrument entry accepts that event shape |
| INST-12 | Drum completion calculated and scheduled twice | Removed: one duration and one completion schedule after assembling all sources |

Test-quality review also added a real host-wiring journey: save built-in and
external assignments in their existing editors, then exercise host contact
entrypoints and inspect instrument voices/sustain. It complements isolated
runtime and shared-controller contracts.

## Final checks

The runtime suite and all 12 shared-controller contracts pass. Complete journeys,
built-in/external host wiring, normal recording integration, note mappings,
sustain and management pass in Chrome and Firefox. These cover negative paths,
persistence, asynchronous ownership, controller retirement and draft cancellation.
The coordinator reran the full eight-suite set after review fixes, then reran
the complete journey after making sparse parameter drafts use catalogue defaults.

Pen geometry, screenshots, save confirmation and exact artifact hashes are
recorded in `docs/design/virtual-instrument-previews/verification.json`.
Native hosting, physical audio/MIDI delivery, real loop-audio capture and actual
sound-pack installation remain production work.

Final design-author check: the geometry exporter omitted native select and
number values. It now captures their displayed values and the select chevron.
The MIDI channel, lower/upper notes and direct note-entry values were restored
in Pen and visually rechecked; both affected screens have no clipped text.
All eight references are saved and the section is marked accepted.
