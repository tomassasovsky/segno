# Shared Mixer control assignments

MIDI and External pedals now offer the same eight Mixer control families:
track, lane and live-monitor gain; track and input pan; linked-input balance;
and output level and balance. Assignment ranges display the actual units.
Gain follows the existing Mixer fader, while pan and balance show left,
center and right. Adding a mapping starts from the current value without
changing the sound. Missing targets remain available for repair.

One confirmed Mixer transaction applies controller values and their saved
Released values. Overlapping sources, ordinary Mixer edits, session capture
and source retirement use the shared control owner. Removing an input pair
invalidates that pair's old assignment without cancelling unrelated queued
track or effect changes.

The [plan](../../plan/2026-10-01-shared-mixer-controls.md) defines the scope.
[Source manifest](source.json) binds the intended product, test and design files.
[Verification](verification.md) separates behavioral, visual and hardware
evidence. [Review](review.md) records repaired findings and remaining limits.
The [bug-focused gate](../../code-review/shared-mixer-controls/review.md)
binds the intended changes against the preceding MIDI revision.

Loop and click controls are the next slice. Performance, backing and
instrument targets follow their real domain owners. This change does not
declare the entire shared catalogue complete or validate physical pedals.

Local gates pass: 2,525 ordinary app tests, 30 controller package tests,
required coverage, static checks and 52 independent adversarial probes.
Published-head CI and human merge remain separate gates.
