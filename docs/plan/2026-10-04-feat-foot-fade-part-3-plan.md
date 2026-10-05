# Complete shared Fade controls and foot surface

Tracking: #1026, human merge gate. Implementation already authorized; no merge or
deployment authority. Parent: [Foot Fade](2026-10-04-feat-foot-fade-plan.md).
Dependencies: Parts 1 and 2. Read the parent's accepted behavior and exact ownership first.

## Work

Connect the completed native/durable feature to existing ControlAction/value
catalogues and selected/fixed/all actions plus normalized duration mappings.
Use existing CTRL/MIDI/external/screen ingress, one contact ledger and hold policy.
One pure typed role table and stateless semantic adapter owns mode-specific meaning;
Control owns temporary selection, repository owns audio, settings owns duration.

Extract only the private Mixer pedal contact shell for immediate Mixer/Fade reuse.
Compose accepted Fade view, bank/all-eight times, inheritance/edit/reset, progress,
LEDs and separate Mixer attenuation cue; add localized labels and pickers together.
Expose mode entry only with this complete view. No framework or dead factory action.

Files: interaction mode, ControlAction/value targets/resolvers, Control routing,
foot_fade model/actions/view, shared contact widget with Mixer consumer, Tracks
composition, Mixer cue and English/Spanish localizations.

## Observable verification

Exercise real Custom/CTRL/MIDI entry, selected/fixed/all actions, normalized
values, bank-following pending hold, consumed release, stale ownership, physical/
screen overlap, duration edit applying on next gesture only, normal Rec/Play,
Stop/Exit/Power, truthful LEDs and visible retry. Widget tests assert real dispatch
and visibility, not another copy of native sample arithmetic. Render accepted
layouts and record a full integrated journey; physical/listening proof separate.

```success-criteria
GOAL: Complete complete shared fade controls and foot surface without changing unrelated accepted behavior.
SUCCESS CRITERIA:
- The concrete behavior and failure cases above pass through the real owning layer. | verify: manual inspect bound automated result summary and independent review for this part.
- Changed code passes the repository's applicable formatter, analyzer, Bloc lint, native/FFI and coverage gates. | verify: manual run the parent plan and PROGRESS commands on frozen source for affected packages.
- Existing public app remains working; no incomplete destination is exposed. | verify: manual run the actual affected app/ingress regressions.
NON-GOALS:
- Other playback transforms, generic frameworks, unrelated owners or repeated unchanged verification.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/dart analyze --fatal-infos lib test packages
```

Resolve dependencies before explicit-file formatting. Use the working Flutter SDK
from PROGRESS. Native edits require native suite, ASAN, telemetry-disabled, C++
shim and matched FFI bindings/symbol proof. Freeze source before aggregate checks;
independent bug/VGV/test/simplicity reviews and current-head CI remain required.
Author screenshots and test seams are not appliance/listening validation.
